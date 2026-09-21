## Context

NitroTPM is a TPM 2.0 device on Nitro-based EC2 instances, exposed to the guest as
`/dev/tpmrm0`. During UEFI measured boot, the firmware/Nitro extends Platform
Configuration Registers (PCRs); on an AL2023 Unified Kernel Image (UKI) layout,
**PCR4 measures the UKI** (kernel + initramfs + cmdline as one unit), so PCR4 is a
deterministic identity for "this AMI's boot content."

The demo runs on an **immutable attestable AL2023 AMI** built with KIWI-NG, forked
from AWS's `attestable-image-example`: systemd-boot + UKI, dm-verity over the whole
root (`verity_blocks="all"`, panic-on-corruption), an erofs read-only root with an
`overlayroot` whose write partition is disabled, and no cloud-init / sshd / ssm /
ec2-instance-connect. Two consequences drive the design:

1. The root filesystem is read-only and its overlay is **ephemeral** (zram) — any
   file written at runtime is gone on the next boot. All persistent OS config must
   be baked into the image at build time.
2. `nitro-tpm-pcr-compute` runs at build time (via KIWI's `editbootinstall` hook),
   emitting the reference PCR4/PCR7 as a build artifact.

The only persistent writable storage on the instance is the attached EBS data
volume. The demo binds a LUKS2 key on that volume to PCR4 using
`systemd-cryptenroll`. The sealed key lives in the LUKS2 header token on the data
volume; unseal is per-instance by nature (bound to that instance's NitroTPM
hierarchy), so the volume is not portable to other instances.

## Goals / Non-Goals

**Goals:**
- Prove OS-level encryption of an EBS data volume with the key sealed to NitroTPM.
- Auto-unlock across **reboot** with zero operator interaction.
- Demonstrate that changing the measured boot (PCR4) leaves the volume locked.
- Zero external dependencies at unlock time (no KMS, IAM, or network).
- Ship the full build recipe so the AMI is reproducible.

**Non-Goals:**
- AWS KMS or any remote key escrow (including the reference's `nitro-tpm-attest` +
  `kms --recipient` path).
- A recovery/passphrase keyslot — data loss on PCR change is acceptable.
- Surviving **stop/start** (AWS documents that this changes measurements; only
  reboot survival is in scope).
- Per-fleet or signed-PCR (PCR7 + signing key) semantics.

## Decisions

**Build an immutable attestable AMI with KIWI-NG (fork the AWS example).**
Reusing a stock AL2023 AMI would leave PCR4 unknown until runtime and would keep a
writable, mutable root. The KIWI recipe gives a read-only dm-verity root, a UKI
whose PCR4 is computed at build time, and zero operator access — a genuinely
attestable image. We ship the recipe (`appliance.kiwi`, `config.sh`,
`edit_boot_install.sh`, `root/` overlay) so the AMI is reproducible.

**Bake all persistent config; keep only TPM-bound state at runtime.**
Because the overlay root is ephemeral, `/etc/crypttab`, `/etc/fstab`, the mountpoint
`/mnt/data`, and the enrollment unit must all be baked into the image's `root/`
overlay at build time. The only thing that must happen at runtime is the part that
requires the per-instance TPM: `luksFormat` + `systemd-cryptenroll`, which writes
the sealed keyslot into the LUKS2 header **on the data volume** (persistent).

**One idempotent baked unit; no crypttab/fstab, no self-disable.**
A single systemd oneshot unit runs on every boot and does: if the data volume has no
LUKS header (`cryptsetup isLuks`), format it and enroll the TPM2 keyslot sealed to
PCR4 and wipe the bootstrap key; then `cryptsetup open` (TPM unseal) and mount at
`/mnt/data`. This replaces the earlier crypttab/fstab + self-disabling design:
self-disable can't persist on an immutable root and isn't needed — the `isLuks`
guard is the idempotency, and doing the open/mount in the same unit avoids fighting
the crypttab cryptsetup-generator ordering on a still-unformatted first boot.

**Replace cloud-init with a baked unit enabled via preset.**
No cloud-init/user-data exists on this image. The enrollment unit is baked in and
enabled with `systemctl preset` from `config.sh` — the same pattern the reference
uses for `set-hostname-imds.service`.

**Seal to PCR4 only.**
PCR4 = the UKI hash = the AMI's boot identity, and it is emitted at build time by
`nitro-tpm-pcr-compute`, so the tamper test can predict the expected value.
Alternatives: PCR7 (secure-boot signer) needs Secure Boot + a signing key — out of
scope; PCR0-3 are infra/firmware and can churn on stop/start. Binding extra volatile
PCRs only adds lockout risk for a reboot-only, per-instance demo.

**Use `systemd-cryptenroll`, not clevis or raw tpm2-tools.**
Native to systemd (present on AL2023), one command to enroll, stores the sealed key
in the LUKS2 header token. Laziest correct option.

**No recovery keyslot.**
The user accepts data loss. Enrolling only the TPM keyslot keeps the demo honest:
the sole way to unlock is a matching PCR4, so the tamper test proves the TPM gate
rather than being masked by a fallback.

**Mount at `/mnt/data`.**
The mountpoint directory is baked into the image (it cannot be created persistently
at runtime on a read-only root).

**Tamper test = change the UKI, not poke a file.**
dm-verity means tampering the root filesystem triggers a boot-time panic (won't boot
at all) rather than booting with a different PCR4. To prove PCR4 binding cleanly,
the tamper test changes the UKI/kernel cmdline (rebuild or re-register with a
different cmdline), which changes PCR4 so NitroTPM refuses to unseal on the same
instance.

## Risks / Trade-offs

- **KIWI-NG build complexity / scope increase** → Building the AMI is heavier than
  reusing a stock AMI. Accepted deliberately: reproducibility and a build-time-known
  PCR4 are worth it. Documented as a prerequisite (AL2023 builder + `kiwi-ng`).
- **Stop/start locks the volume out** → Explicit non-goal; README warns to use
  reboot, never stop/start. Data loss is acceptable, so the failure mode is tolerable
  but must be stated.
- **First-boot script reformats a volume with data** → Idempotency guard checks for
  an existing LUKS header (`cryptsetup isLuks`) before formatting; the unit refuses
  to touch an already-provisioned volume.
- **dm-verity changes the tamper story** → Root-fs tampering panics instead of
  yielding a different-PCR4 boot; the honest PCR4 test is a UKI/cmdline change.
- **Device naming drift** (`/dev/nvme1n1` vs `/dev/xvdb`) → Reference the data volume
  by a stable local identifier (`/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol...`),
  never a runtime AWS/IMDS lookup (that would put the network on the unlock path).
- **PCR4 semantics depend on the UKI layout** → Guaranteed here because the KIWI
  recipe produces a UKI via systemd-boot + `dracut uefi="true"`.

## Migration Plan

Greenfield demo; no rollback concerns. Teardown is terminating the instance,
deleting the data volume, and deregistering the AMI / deleting its snapshot.

## Open Questions

- Exact `/dev/disk/by-id/` string for the data volume on the chosen instance type
  (confirm against a real launch; the EBS volume id appears in the NVMe serial).
- Which systemd target the enrollment unit should order before (e.g.
  `local-fs.target` vs a `multi-user.target` want) so the mount is ready before any
  dependent workload — pin during implementation on a real boot.
