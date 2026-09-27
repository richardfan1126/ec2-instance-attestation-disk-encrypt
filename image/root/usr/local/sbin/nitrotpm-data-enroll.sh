#!/bin/bash
#
# nitrotpm-data-enroll.sh
# -----------------------
# Baked into the immutable AL2023 attestable image and run on EVERY boot by
# nitrotpm-data.service. It:
#
#   1. Discovers the EBS data volume by EXCLUSION -- the single NVMe namespace
#      whose controller model is "Amazon Elastic Block Store" that is NOT in use
#      by the running system (no holders, not mounted, no partition table). No
#      IMDS/AWS call, no baked volume id: enumeration-order-invariant.
#   2. First boot (volume has no LUKS header): luksFormat with a random bootstrap
#      key, enroll a TPM2 keyslot sealed to PCR4 + PCR12, then wipe the bootstrap
#      key so only the TPM-sealed slot remains.
#   3. Every boot: unseal from NitroTPM, create a filesystem only if absent, and
#      mount at /mnt/data.
#
# Idempotency is the `cryptsetup isLuks` guard plus RemainAfterExit -- no
# crypttab, no fstab, no self-disable (a self-disable cannot persist on a
# read-only root). On any refusal or unseal failure the volume is left LOCKED
# and a loud, structured breadcrumb is written to the journal -- on a
# zero-access image the serial console is the only diagnostic surface.
#
set -uo pipefail

MAPPER_NAME="data"
MAPPER_DEV="/dev/mapper/${MAPPER_NAME}"
MOUNT_POINT="/mnt/data"
EBS_MODEL="Amazon Elastic Block Store"

# Bounded stable-count wait: accept only a candidate count that has held steady
# across QUIET_WINDOW consecutive samples, and never past MAX_WAIT seconds.
# Waiting out a transient boot-disk topology and catching a racing second volume
# both need the count to be *stable*, not merely first-seen.
QUIET_WINDOW=3
MAX_WAIT=30

# Overridable only so the discovery logic can be exercised against a fake sysfs
# tree in test_nitrotpm_data.sh; defaults to the real block dir in production.
BLOCK_DIR="${BLOCK_DIR:-/sys/block}"

log() { echo "nitrotpm-data: $*" >&2; }

# Print the basename of every free EBS data-volume candidate, one per line.
# "Free" = EBS controller model, no holders, no partition table, not mounted.
# The in-use checks are the primary discriminator (the boot disk is mounted and
# has holders regardless of partition-probe timing); "no partitions" only
# confirms (an attestable boot disk is necessarily GPT-partitioned: UEFI needs
# an ESP and dm-verity needs a hash partition).
candidates() {
    local dev name model
    shopt -s nullglob
    for dev in "$BLOCK_DIR"/nvme*n*; do
        [ -d "$dev" ] || continue
        name=${dev##*/}
        # Skip partitioned devices (a partition child means the boot disk).
        local parts=("$dev/${name}p"*)
        [ ${#parts[@]} -gt 0 ] && continue
        # Skip devices with holders (in a DM / verity / overlay / RAID chain).
        if [ -d "$dev/holders" ] && [ -n "$(ls -A "$dev/holders" 2>/dev/null)" ]; then
            continue
        fi
        # Skip a directly-mounted device.
        findmnt -rn -S "/dev/$name" >/dev/null 2>&1 && continue
        # Must be an EBS namespace (excludes instance-store, which is also
        # whole-disk). `xargs` trims leading/trailing whitespace from the model.
        model=$(cat "$dev/device/model" 2>/dev/null) || continue
        model=$(printf '%s' "$model" | xargs)
        [ "$model" = "$EBS_MODEL" ] || continue
        echo "$name"
    done
    shopt -u nullglob
}

# Wait for a stable, non-zero candidate count; echo the final candidate list.
discover() {
    local waited=0 stable=0 last=-1 list count
    while [ "$waited" -lt "$MAX_WAIT" ]; do
        list=$(candidates)
        count=$(printf '%s' "$list" | grep -c .)
        if [ "$count" -eq "$last" ]; then
            stable=$((stable + 1))
        else
            stable=0
            last="$count"
        fi
        # Accept only a count that is both non-zero and has held steady.
        if [ "$count" -ge 1 ] && [ "$stable" -ge "$QUIET_WINDOW" ]; then
            printf '%s\n' "$list"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    # Timed out without a stable non-zero count: emit whatever the last sample
    # was (may be empty) so the caller can log the right refusal reason.
    candidates
    return 0
}

main() {
    local list count dev bootstrap
    list=$(discover)
    count=$(printf '%s' "$list" | grep -c .)

    # Require exactly one candidate. Refuse (mount nothing) on zero -- user error
    # on first boot, a detached/failing volume on reboot -- or on >=2 (ambiguous;
    # never guess which blank volume to format).
    if [ "$count" -eq 0 ]; then
        log "REFUSED: 0 EBS data-volume candidates after ${MAX_WAIT}s; leaving ${MOUNT_POINT} unmounted"
        exit 1
    fi
    if [ "$count" -ge 2 ]; then
        log "REFUSED: ${count} EBS data-volume candidates (ambiguous): $(printf '%s' "$list" | tr '\n' ' ')"
        exit 1
    fi

    dev="/dev/$(printf '%s' "$list" | head -n1)"
    log "selected data volume ${dev}"

    if ! cryptsetup isLuks "$dev"; then
        # First boot: format and enroll the TPM2 keyslot. This is the only
        # branch that writes to the volume; the exactly-one and isLuks guards
        # together bar a destructive mis-format.
        log "no LUKS header on ${dev}: formatting and enrolling TPM2 keyslot (PCR4+12)"
        bootstrap=$(mktemp)
        # shellcheck disable=SC2064
        trap "rm -f '$bootstrap'" EXIT
        head -c 64 /dev/urandom >"$bootstrap"

        if ! cryptsetup luksFormat --type luks2 --batch-mode --key-file "$bootstrap" "$dev"; then
            log "REFUSED: luksFormat failed on ${dev}"
            exit 1
        fi
        # `+` is the PCR separator. Requires nitro measured boot to expose PCR12.
        if ! systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=4+12 \
                --unlock-key-file="$bootstrap" "$dev"; then
            log "REFUSED: systemd-cryptenroll (TPM2 PCR4+12) failed on ${dev}"
            exit 1
        fi
        # Drop the bootstrap key: the TPM-sealed slot is the sole unlock path.
        if ! systemd-cryptenroll --wipe-slot=password "$dev"; then
            log "REFUSED: could not wipe bootstrap keyslot on ${dev}"
            exit 1
        fi
        rm -f "$bootstrap"
        trap - EXIT
    fi

    # Every boot: unseal from NitroTPM. systemd-cryptsetup reads the LUKS2 TPM2
    # token and unseals under the PCR4+12 policy -- this is the TPM open. A
    # non-matching PCR4/PCR12 (or lost TPM state after stop/start) fails here and
    # the volume stays locked.
    if [ ! -e "$MAPPER_DEV" ]; then
        if ! /usr/lib/systemd/systemd-cryptsetup attach "$MAPPER_NAME" "$dev" - tpm2-device=auto; then
            log "REFUSED: TPM unseal failed for ${dev} (PCR4/PCR12 mismatch, or NitroTPM state lost on stop/start); volume left locked"
            exit 1
        fi
    fi

    # Create the filesystem only when absent, so a provisioned volume is never
    # re-made even though this runs every boot.
    if ! blkid "$MAPPER_DEV" >/dev/null 2>&1; then
        log "no filesystem on ${MAPPER_DEV}: creating ext4"
        mkfs.ext4 -q "$MAPPER_DEV"
    fi

    mkdir -p "$MOUNT_POINT"
    if ! mountpoint -q "$MOUNT_POINT"; then
        if ! mount "$MAPPER_DEV" "$MOUNT_POINT"; then
            log "REFUSED: failed to mount ${MAPPER_DEV} at ${MOUNT_POINT}"
            exit 1
        fi
    fi
    log "OK: ${dev} unlocked and mounted at ${MOUNT_POINT}"
}

# Skip execution when sourced by test_nitrotpm_data.sh (which only exercises
# the pure discovery logic against a fake sysfs tree).
[ "${NITROTPM_DATA_LIB:-}" = "1" ] || main "$@"
