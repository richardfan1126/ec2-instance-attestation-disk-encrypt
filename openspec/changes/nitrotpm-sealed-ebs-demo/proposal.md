## Why

We want a minimal, self-contained demo proving that an EBS data volume on an EC2
instance can be encrypted at the OS level (LUKS) with its key sealed to NitroTPM,
so the volume unlocks only while the instance keeps booting the unchanged AMI. If
the measured boot (the AMI's Unified Kernel Image) changes, the TPM refuses to
release the key and the data stays locked. No KMS, no IAM, no network dependency:
the key never leaves the box.

The demo is built on an **immutable attestable AL2023 AMI** produced with KIWI-NG
(following AWS's `attestable-image-example`): systemd-boot + UKI, dm-verity, an
erofs read-only overlay root, and zero operator access (no cloud-init, no SSH, no
SSM). This makes PCR4 a real, build-time-known identity for the image and removes
the cloud-init/user-data trigger entirely.

## What Changes

- Ship a KIWI-NG image description (forked from AWS's `attestable-image-example`)
  that builds an immutable, zero-operator-access AL2023 attestable AMI: UKI via
  systemd-boot, dm-verity (`verity_blocks="all"`, panic-on-corruption), erofs
  `overlayroot` with `overlayroot_write_partition="false"`, and no cloud-init /
  sshd / ssm-agent / ec2-instance-connect.
- Because the root filesystem is read-only and its overlay is ephemeral, **bake
  all persistent config into the image at build time**: the mountpoint `/mnt/data`,
  and a single systemd unit (enabled via `systemctl preset`, replacing cloud-init
  the same way the reference uses `set-hostname-imds`).
- Add one idempotent baked systemd unit that, on **every** boot: if the data
  volume has no LUKS header, `luksFormat`s it and enrolls a TPM2 keyslot sealed to
  **PCR4 + PCR12** via `systemd-cryptenroll`, wiping the bootstrap key; then unseals
  from NitroTPM and mounts it at `/mnt/data`. No `crypttab`/`fstab`, no self-disable —
  the `cryptsetup isLuks` guard is the idempotency. (PCR4 alone is bypassable with
  Secure Boot off via an injected cmdline that keeps PCR4 constant; PCR12 closes it —
  AWS advisory GHSA-xrv8-2pf5-f3q7.)
- Capture the build-time reference PCR4/PCR12 (`pcr_measurements.json` from
  `nitro-tpm-pcr-compute` >= 1.1.0) as a verification anchor to confirm a running
  instance measured to the AMI that was built (not an input to the seal).
- Add launch + build docs and a README walkthrough: build the AMI, register it
  `--boot-mode uefi --tpm-support v2.0`, launch with a data volume, reboot ->
  auto-unlock and mount at `/mnt/data`.
- Add a GitHub Actions pipeline that builds the AMI automatically (two jobs):
  - **Build + publish:** build the KIWI `.raw` inside a privileged Docker
    `kiwi-builder` on the runner, extract the reference **PCR4 + PCR12** from
    `pcr_measurements.json` (failing the build if PCR12 is absent), then publish the
    raw image + measurements to GHCR as a digest-pinned OCI artifact (ORAS, pinned +
    checksum-verified) and generate a SLSA build-provenance attestation
    (`actions/attest`, pushed to the registry).
  - **Build AMI:** authenticate to AWS via OIDC (`role-to-assume`, no static keys),
    pull the OCI artifact by digest (verifying the expected workflow), then, **on the
    runner itself**, `coldsnap upload` the `.raw` straight to an EBS snapshot (EBS direct
    APIs, no builder instance) and `register-image --boot-mode uefi --tpm-support v2.0`,
    emitting the AMI id. `coldsnap` is installed from a version-pinned cached binary.
  - Pin every action by commit SHA; scope `permissions` per job.

**Non-goals (explicit):** AWS KMS or any remote key escrow; a recovery/passphrase
keyslot (data loss is acceptable); surviving stop/start (reboot survival only);
per-fleet or signed-PCR (PCR7) semantics; an SSH / debug build path (the image is
zero-operator-access by design); a live wrong-PCR tamper demonstration (the lock is a
seal-policy property, not cleanly demonstrable on a zero-access instance).

## Capabilities

### New Capabilities
- `tpm-sealed-data-volume`: OS-level LUKS encryption of an EBS data volume whose key
  is sealed to NitroTPM under PCR4 + PCR12, auto-unlocked on reboot, and refused when
  the AMI's measured boot or kernel cmdline changes.
- `attestable-ami-build`: a GitHub Actions pipeline that builds the KIWI image,
  captures the reference PCR4 + PCR12, publishes a digest-pinned OCI artifact with a
  SLSA attestation, and registers the attestable AMI in AWS via OIDC.

### Modified Capabilities
<!-- None: greenfield demo project. -->

## Impact

- New project scaffolding: a KIWI-NG image description plus a baked enrollment
  unit/script; no existing code (greenfield repo).
- Build-time dependencies: KIWI-NG (`kiwi-ng`), run on an AL2023 builder; the
  recipe pulls `aws-nitro-tpm-tools`, `cryptsetup`, `veritysetup`, `systemd-boot`,
  `dracut-kiwi-verity`, `dracut-kiwi-overlay`.
- Runtime dependencies on the instance: `cryptsetup` and `systemd` (>= v248 for
  `systemd-cryptenroll --tpm2-device`), both baked in; NitroTPM 2.0 exposed as
  `/dev/tpmrm0`.
- Requires an EC2 instance launched from the built AMI registered with
  `--boot-mode uefi --tpm-support v2.0`, on a NitroTPM-capable instance type, with a
  second EBS volume attached.
- Immutable root: the only persistent writable storage is the LUKS-encrypted data
  volume; the OS root is read-only (erofs) with an ephemeral overlay.
- Per-instance scope: the sealed key is bound to that instance's NitroTPM; the volume
  is not portable to other instances.
- CI/build infrastructure: a GitHub Actions runner (Docker for the privileged KIWI
  builder), GHCR write access (`packages: write`), and an AWS OIDC role
  (`vars.AWS_ROLE_ARN`, `id-token: write`) scoped to the EBS direct APIs
  (`ebs:StartSnapshot`/`PutSnapshotBlock`/`CompleteSnapshot`, `ec2:RegisterImage`,
  `ec2:DescribeSnapshots`). The `.raw` -> snapshot -> AMI step runs on the runner via
  `coldsnap`; no builder instance, no Terraform.
