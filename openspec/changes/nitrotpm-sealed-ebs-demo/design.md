## Context

NitroTPM is a TPM 2.0 device on Nitro-based EC2 instances, exposed to the guest as
`/dev/tpmrm0`. During UEFI measured boot, the firmware/Nitro extends Platform
Configuration Registers (PCRs); on an AL2023 Unified Kernel Image (UKI) layout,
**PCR4 measures the UKI** (kernel + initramfs + the cmdline embedded at build time as
one binary), so PCR4 is a deterministic identity for "this AMI's boot content."
**PCR12 measures any kernel cmdline appended at boot** (systemd-boot appends what it
is handed); on a clean boot of the unmodified AMI nothing is appended, so PCR12 is
all-zeros. PCR4 + PCR12 is AWS's standard-boot (Secure Boot off) validation set for
an attestable AMI.

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
volume. The demo binds a LUKS2 key on that volume to PCR4 + PCR12 using
`systemd-cryptenroll`. The sealed key lives in the LUKS2 header token on the data
volume; unseal is per-instance by nature (bound to that instance's NitroTPM
hierarchy), so the volume is not portable to other instances.

## Goals / Non-Goals

**Goals:**
- Prove OS-level encryption of an EBS data volume with the key sealed to NitroTPM.
- Auto-unlock across **reboot** with zero operator interaction.
- Bind the key so that a changed measured boot (PCR4 or PCR12) leaves the volume locked.
- Zero external dependencies at unlock time (no KMS, IAM, or network).
- Ship the full build recipe so the AMI is reproducible.

**Non-Goals:**
- AWS KMS or any remote key escrow (including the reference's `nitro-tpm-attest` +
  `kms --recipient` path).
- A recovery/passphrase keyslot — data loss on PCR change is acceptable.
- Surviving **stop/start** (AWS documents that this changes measurements; only
  reboot survival is in scope).
- Per-fleet or signed-PCR (PCR7 + signing key) semantics.
- A live wrong-PCR tamper demonstration — the lock is a property of the seal policy,
  not something the demo actively triggers. It is not cleanly reachable on a
  zero-access instance (see the tamper-demo decision below).

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

**Seal to PCR4 + PCR12 (not PCR4 alone).**
PCR4 = the UKI hash = the AMI's boot identity. But with Secure Boot off (our case),
systemd-boot appends any cmdline it is handed, and an operator who can set a UEFI
boot variable / UefiData can inject a cmdline that disables dm-verity **while leaving
PCR4 unchanged** — the appended cmdline lands in PCR12, not PCR4. Sealing to PCR4
alone is therefore bypassable (AWS advisory GHSA-xrv8-2pf5-f3q7; `nitro-tpm-pcr-compute`
v1.1.0 added PCR12 for this reason). Binding **PCR4 + PCR12** is AWS's standard-boot
validation set and closes the bypass. PCR12 is all-zeros on a clean boot of the
unmodified AMI and is stable across reboots, so it adds no spurious-lockout risk.
Alternatives: PCR7 (secure-boot signer) needs Secure Boot + a signing key — out of
scope; PCR0-3 are infra/firmware and can churn on stop/start.

**Use `systemd-cryptenroll`, not clevis or raw tpm2-tools.**
Native to systemd (present on AL2023), one command to enroll, stores the sealed key
in the LUKS2 header token. Laziest correct option.

**No recovery keyslot.**
The user accepts data loss. Enrolling only the TPM keyslot keeps the demo honest:
a matching PCR4 + PCR12 is the sole unlock path, not masked by a fallback.

**Mount at `/mnt/data`.**
The mountpoint directory is baked into the image (it cannot be created persistently
at runtime on a read-only root).

**No live wrong-PCR demo; PCR12 stays in the seal policy regardless.**
We do not ship a test that makes an already-sealed instance boot with a changed PCR
and observes the lock. It is not cleanly demonstrable on this image: reaching an
already-sealed instance's boot inputs needs either an in-guest shell (which the
zero-access image deliberately lacks) or a stop/start / offline volume edit (which
rotates NitroTPM state and confounds the result — you cannot attribute the lock to
the PCR change vs. the state change). PCR4 in particular can never be isolated on a
single instance: changing it means a different AMI, hence a different instance/TPM.
The security property (a non-matching PCR4 or PCR12 leaves the volume locked) is
enforced by the TPM seal policy itself and holds without a live negative demo.

**Automate the build with a two-job GitHub Actions pipeline (mirror the reference).**
KIWI needs privilege, and `.raw` -> AMI needs AWS — two different environments, so
two jobs. Job 1 (`build-and-publish`) builds the `.raw` inside a Docker
`kiwi-builder` on the runner, extracts the reference PCRs, and publishes a
digest-pinned OCI artifact to GHCR (ORAS, pinned + checksum-verified) plus a SLSA
build-provenance attestation. Job 2 (`build-ami`, `needs` job 1) authenticates via
OIDC and turns the artifact into a registered AMI. This matches AWS's separation and
gives a reproducible, attestable supply chain end to end.

**Extract PCR4 + PCR12, not PCR4 + PCR7.**
The reference tracks PCR7 (Secure Boot). Our gate is PCR4 + PCR12 (Secure Boot off),
so the extraction step reads those from `pcr_measurements.json` and **fails the build
if PCR12 is missing** — which doubles as the guard that the bundled
`nitro-tpm-pcr-compute` is >= 1.1.0.

**Raw -> AMI via an ephemeral Terraform builder instance (Path A).**
`register-image` needs the bits as an EBS snapshot. Path A provisions a throwaway
instance, `dd`s the `.raw` onto an attached volume, snapshots it, and calls
`register-image --boot-mode uefi --tpm-support v2.0`, then always `terraform destroy`s.
Chosen over `import-snapshot` (Path B) because it is proven for NitroTPM/UEFI and
fully controllable; Path B's raw+UEFI+`tpm-support` import path is unverified.

**Reference PCRs are a verification anchor, not a seal input.**
`pcr_measurements.json` (build-time PCR4 + PCR12) is used by a human to confirm a
running instance measured to the AMI that was built. It is deliberately **not** fed
into the seal: `systemd-cryptenroll` binds to the PCRs
that are live at first-boot enroll time. Enforcing the reference PCR4 locally is
impossible without circularity — PCR4 = hash(UKI), the UKI cmdline embeds the
dm-verity roothash, and the roothash covers every block of the erofs root, so any file
baked in that contains PCR4 changes the roothash and therefore PCR4 (chicken-and-egg).
Placing it on the ESP instead makes it mutable and unmeasured, so it could not be an
enforcement anchor anyway. First-boot PCR4 trust therefore rests on immutability +
dm-verity + launching a chosen attestable AMI id, which is acceptable for this demo.
This differs from the KMS reference, where the reference PCR is load-bearing (baked
into the KMS key policy so KMS enforces it).

**No enrollment-time PCR guard; seal to live PCRs at first boot (TOFU).**
The enroll step binds to whatever PCRs are live at first boot without pre-checking
them. A tampered first boot (PCR12 != 0) self-defeats: the key seals to that value
and then fails to unlock on the next clean boot, so the volume never becomes usable
under the tampered measurement. A dedicated `live PCR12 == 0` pre-check would only
move that failure from the next reboot to enroll time; it is dropped as unnecessary.
Add it back if first-boot integrity ever needs to fail fast instead of on the next
reboot.

**Supply-chain hardening kept from the reference.**
OIDC role-to-assume (no static AWS keys), every action pinned by commit SHA,
least-privilege `permissions` per job, digest-pinned artifact references (no
tag-movement TOCTOU), and expected-workflow verification when pulling the artifact in
job 2.

**Drop the `enable_ssh` debug toggle.**
The reference's SSH debug build directly contradicts our zero-operator-access image,
so it is omitted rather than carried as a disabled escape hatch.

## Risks / Trade-offs

- **KIWI-NG build complexity / scope increase** → Building the AMI is heavier than
  reusing a stock AMI. Accepted deliberately: reproducibility and build-time-known
  reference PCRs are worth it. Documented as a prerequisite (AL2023 builder + `kiwi-ng`).
- **Stop/start locks the volume out** → Explicit non-goal; README warns to use
  reboot, never stop/start. Data loss is acceptable, so the failure mode is tolerable
  but must be stated.
- **First-boot script reformats a volume with data** → Idempotency guard checks for
  an existing LUKS header (`cryptsetup isLuks`) before formatting; the unit refuses
  to touch an already-provisioned volume.
- **dm-verity makes PCR4 effectively immutable on a running instance** → Root-fs
  tampering panics instead of yielding a different-PCR4 boot, which is why PCR4 cannot
  be exercised on a single instance and PCR12 is the meaningful runtime gate the seal
  policy adds on top.
- **PCR4-only seal is bypassable** → With Secure Boot off, an injected cmdline
  disables integrity while PCR4 stays constant (AWS GHSA-xrv8-2pf5-f3q7). Mitigated by
  binding PCR12 as well; requires `nitro-tpm-pcr-compute` >= 1.1.0 to emit the PCR12
  reference (default all-zeros).
- **CI builder-instance leak** → Job 2 provisions a real EC2 instance; a failed
  `terraform destroy` leaves it (and its cost) running. Mitigated by `if: always()`
  cleanup and least-privilege; the README notes manual-cleanup as the fallback.
- **CI scope/cost** → A privileged Docker build plus an EC2 builder instance per run
  is heavier than the rest of the demo. Accepted because the user chose the full
  pipeline; documented as a prerequisite (GHCR, OIDC role, Terraform).
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
- Verify the AL2023 `aws-nitro-tpm-tools` rpm on the builder bundles
  `nitro-tpm-pcr-compute` >= 1.1.0 (PCR12 support landed in 1.1.0; latest is 1.1.2)
  via `nitro-tpm-pcr-compute --version`; upgrade if it only prints PCR4/PCR7.
  [`--tpm2-pcrs=4+12` syntax and the >=1.1.0 requirement are confirmed; only the
  bundled rpm version is still to check on the builder.]
- Builder instance type/size for Path A (the reference uses `c5.9xlarge` for a larger
  image; ours is smaller — right-size during implementation).
- If Path A ever proves too heavy, confirm whether `import-snapshot` + our own
  `register-image --tpm-support v2.0` (Path B) supports the raw+UEFI path before
  switching.
