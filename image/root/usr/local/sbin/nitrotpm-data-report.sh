#!/bin/bash
#
# nitrotpm-data-report.sh
# -----------------------
# Baked into the immutable AL2023 attestable image and run on EVERY boot by
# nitrotpm-data-report.service, ordered AFTER nitrotpm-data.service. It is a
# READ-ONLY diagnostic: it makes no changes, and always exits 0 so it never
# turns a boot "failed". Its whole job is to print, to the serial console (the
# only diagnostic surface on a zero-access image), enough evidence to verify a
# running instance without a shell:
#
#   1. Live PCR4 + PCR12, read straight from the kernel TPM sysfs interface
#      (/sys/class/tpm/tpmX/pcr-<bank>/<N>, kernel >= 5.12). NitroTPM's bank is
#      SHA384. Compare these against build-time pcr_measurements.json to confirm
#      the instance measured to the AMI that was built. No tpm2-tools needed.
#   2. The LUKS2 binding of the data volume (cryptsetup luksDump): the
#      systemd-tpm2 token (its "tpm2-hash-pcrs: 4+12" / "tpm2-pcr-bank: sha384")
#      and that only the TPM keyslot remains -- the bootstrap password slot was
#      wiped at enroll.
#   3. The mount state of /mnt/data.
#   4. A best-effort NitroTPM attestation probe (nitro-tpm-attest): the signed
#      document a remote verifier / KMS validates. Producing one confirms the
#      TPM attestation path is live end to end.
#
# The unit sets StandardOutput=journal+console, so everything here lands on
# ttyS0 as well as the journal.
#
set -uo pipefail

MAPPER_NAME="data"
MOUNT_POINT="/mnt/data"

log()  { echo "nitrotpm-data-report: $*"; }
rule() { echo "nitrotpm-data-report: ----------------------------------------"; }

# --- 1. Live PCR4 + PCR12 (kernel TPM sysfs) --------------------------------
# Prefer the SHA384 bank (NitroTPM's), fall back to SHA256, then give up
# gracefully. Iterate over every tpm chip so tpm0/tpmN naming doesn't matter.
report_pcrs() {
    local bank chip path found=0 pcr
    for bank in sha384 sha256; do
        for chip in /sys/class/tpm/tpm*/pcr-"$bank"; do
            [ -d "$chip" ] || continue
            found=1
            for pcr in 4 12; do
                path="$chip/$pcr"
                if [ -r "$path" ]; then
                    log "live PCR${pcr} (${bank}): $(cat "$path" 2>/dev/null | tr 'A-F' 'a-f')"
                else
                    log "live PCR${pcr} (${bank}): <unreadable at ${path}>"
                fi
            done
            # First chip that has this bank is enough.
            log "(compare against PCR4/PCR12 in build-time pcr_measurements.json; hex is case-insensitive)"
            return 0
        done
        [ "$found" = 1 ] && break
    done
    log "live PCRs: no /sys/class/tpm/tpm*/pcr-{sha384,sha256} interface found"
}

# --- 2. LUKS2 binding of the data volume ------------------------------------
report_luks() {
    local dev
    if [ ! -e "/dev/mapper/${MAPPER_NAME}" ]; then
        log "LUKS: /dev/mapper/${MAPPER_NAME} is not present -- volume is LOCKED (unseal did not run or was refused)"
        return 0
    fi
    # The backing block device of the opened mapping.
    dev=$(cryptsetup status "$MAPPER_NAME" 2>/dev/null \
              | awk '/^[[:space:]]*device:/ {print $2; exit}')
    if [ -z "${dev:-}" ] || [ ! -b "$dev" ]; then
        log "LUKS: could not resolve the backing device of ${MAPPER_NAME}"
        return 0
    fi
    log "LUKS: data volume ${dev} is OPEN as /dev/mapper/${MAPPER_NAME}"
    # Print the Keyslots + Tokens block (LUKS2 orders Keyslots, then Tokens,
    # then Digests) so a reader sees the systemd-tpm2 token, its bound PCRs, and
    # that no password keyslot survived the enroll-time wipe.
    cryptsetup luksDump "$dev" 2>/dev/null \
        | sed -n '/^Keyslots:/,/^Digests:/{/^Digests:/!p}' \
        | while IFS= read -r line; do echo "nitrotpm-data-report:   $line"; done
}

# --- 3. Mount state ----------------------------------------------------------
report_mount() {
    if findmnt -rn "$MOUNT_POINT" >/dev/null 2>&1; then
        log "mount: $(findmnt -rn -o TARGET,SOURCE,FSTYPE "$MOUNT_POINT")"
    else
        log "mount: ${MOUNT_POINT} is NOT mounted"
    fi
}

# --- 4. Best-effort NitroTPM attestation probe ------------------------------
# nitro-tpm-attest produces the signed document a remote verifier / KMS checks.
# We only confirm the path is live; we do not parse the document here.
report_attest() {
    local tool="/usr/bin/nitro-tpm-attest" doc bytes
    if [ ! -x "$tool" ]; then
        log "attestation: ${tool} not found (skipping live probe)"
        return 0
    fi
    if [ ! -e /dev/tpmrm0 ]; then
        log "attestation: /dev/tpmrm0 absent -- NitroTPM not exposed to the guest"
        return 0
    fi
    doc=$(mktemp) || { log "attestation: mktemp failed"; return 0; }
    if "$tool" >"$doc" 2>/dev/null && [ -s "$doc" ]; then
        bytes=$(wc -c <"$doc" 2>/dev/null)
        log "attestation: nitro-tpm-attest produced a signed document (${bytes} bytes); validate it off-box"
    else
        log "attestation: nitro-tpm-attest is installed; retrieve/validate a live document off-box (see 'nitro-tpm-attest --help')"
    fi
    rm -f "$doc"
}

main() {
    rule
    log "NitroTPM-sealed data-volume boot report"
    rule
    report_pcrs
    rule
    report_luks
    rule
    report_mount
    rule
    report_attest
    rule
    exit 0
}

main "$@"
