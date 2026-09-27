# NitroTPM-sealed EBS data volume on an attestable AL2023 AMI

A minimal, self-contained demo: an EBS **data** volume on an EC2 instance is
encrypted with LUKS2, and its key is **sealed to NitroTPM** under PCR4 + PCR12.
The volume unlocks automatically on reboot only while the instance keeps booting
the unchanged, measured AMI. If the measured boot (the UKI) or the kernel cmdline
changes, NitroTPM refuses to release the key and the data stays locked. No KMS,
no IAM, no network: the key never leaves the box.

The demo runs on an **immutable, zero-operator-access attestable AL2023 AMI**
built with KIWI-NG (forked from AWS's
[`attestable-image-example`](https://github.com/amazonlinux/kiwi-image-descriptions-examples)):
systemd-boot + UKI, dm-verity over the whole root (panic-on-corruption), an erofs
read-only root with an ephemeral overlay, and no cloud-init / sshd / ssm /
ec2-instance-connect. That makes PCR4 a build-time-known identity for the image
and removes the cloud-init / user-data trigger entirely.

## Repository layout

```
image/
  appliance.kiwi                 KIWI image description (forked, renamed)
  config.sh                      preset-enables set-hostname-imds + nitrotpm-data
  edit_boot_install.sh           build-time UKI -> pcr_measurements.json (PCR4+PCR12)
  add-gpg-key.sh                 AL2023 repo GPG key
  test_nitrotpm_data.sh          self-check for the data-volume discovery logic
  root/                          baked overlay copied into the image
    mnt/data/                    baked mountpoint (read-only root can't mkdir at runtime)
    usr/lib/systemd/system/nitrotpm-data.service
    usr/local/sbin/nitrotpm-data-enroll.sh    enroll + unlock (runs every boot)
.github/
  docker/Dockerfile.kiwi-builder privileged KIWI build environment
  scripts/build-kiwi-image.sh    kiwi-ng system build -> .raw + pcr_measurements.json
  workflows/build-attestable-image.yml   two-job build + AMI pipeline
```

## Prerequisites

- **Builder:** an AL2023 host (or the `kiwi-builder` container) with `kiwi-ng`
  and `aws-nitro-tpm-tools`. The build must run privileged (KIWI needs loop
  devices). Confirm the PCR tool emits PCR12:

  ```bash
  nitro-tpm-pcr-compute --version   # must be >= 1.1.0 (latest 1.1.2)
  ```

  1.1.0 added PCR12; an older tool emits only PCR4/PCR7 and the CI extract step
  fails the build.
- **Instance:** a NitroTPM-capable instance type, launched from the AMI
  registered with `--boot-mode uefi --tpm-support v2.0`, with a **second EBS
  data volume** attached. NitroTPM appears in-guest as `/dev/tpmrm0`.

## Build

```bash
sudo kiwi-ng --color-output --loglevel 0 system build \
  --description ./image \
  --target-dir ./build-output
```

This produces `build-output/*.raw` and `build-output/pcr_measurements.json`.
The measurements file carries the reference PCR4 + PCR12:

```json
{ "Measurements": { "HashAlgorithm": "SHA384 ...", "PCR4": "...", "PCR7": "...", "PCR12": "..." } }
```

(Or run the whole thing in CI — see below — which builds, extracts the PCRs,
publishes the raw image to GHCR, and registers the AMI.)

## Register the AMI

`register-image` needs the bits as an EBS snapshot. `coldsnap` uploads the raw
disk straight to a snapshot through the EBS direct APIs, block-for-block — it
never interprets the filesystem, so the erofs/dm-verity bytes (and therefore
PCR4) are preserved:

```bash
snap=$(coldsnap upload --wait build-output/*.raw)
aws ec2 register-image \
  --name al2023-nitrotpm-sealed-ebs \
  --architecture x86_64 \
  --boot-mode uefi --tpm-support v2.0 \
  --virtualization-type hvm --ena-support \
  --root-device-name /dev/xvda \
  --block-device-mappings "DeviceName=/dev/xvda,Ebs={SnapshotId=$snap,VolumeType=gp3,DeleteOnTermination=true}"
```

Do **not** use `import-image`: it injects drivers/agents into the guest, which
changes the root filesystem, the dm-verity roothash, and thus PCR4.
`coldsnap` / `import-snapshot` are pure block copies and do not.

## Launch and confirm NitroTPM

Launch the AMI on a NitroTPM-capable type with a second EBS volume attached.
There is no SSH/SSM on this image, so use the **EC2 serial console** to observe
boot. NitroTPM is present when `/dev/tpmrm0` exists in-guest.

## Demo walkthrough

1. **First boot** — `nitrotpm-data.service` runs. It discovers the data volume
   by exclusion (the single `Amazon Elastic Block Store` NVMe namespace not in
   use by the running system), sees no LUKS header, `luksFormat`s it, enrolls a
   TPM2 keyslot sealed to PCR4 + PCR12, wipes the bootstrap key, then unlocks and
   mounts it at `/mnt/data`.
2. **Reboot** — the same unchanged AMI produces the same PCR4 + PCR12, so
   NitroTPM releases the key and the volume auto-unlocks and mounts at
   `/mnt/data` with zero interaction.

Verify on the running instance (via serial console):

```bash
journalctl -u nitrotpm-data.service      # look for "OK: ... unlocked and mounted"
findmnt /mnt/data                         # mounted from /dev/mapper/data
cryptsetup luksDump /dev/<data-dev> | grep -A3 tpm2   # only the TPM2 token, no password slot
```

### Reference PCRs are a verification anchor, not a seal input

`pcr_measurements.json` (built PCR4 + PCR12) lets a human confirm a running
instance measured to the AMI that was built — compare it against the live PCRs.
It is **not** fed into the seal: `systemd-cryptenroll` binds to whatever PCRs are
live at first-boot enroll time. Enforcing the reference PCR4 locally is
impossible without circularity (PCR4 = hash(UKI), and the UKI's cmdline embeds
the dm-verity roothash that covers every root block, so any baked file containing
PCR4 would change PCR4). First-boot PCR4 trust therefore rests on immutability +
dm-verity + launching a chosen attestable AMI id.

### Why PCR4 + PCR12, not PCR4 alone

With Secure Boot off (our case), systemd-boot appends any cmdline it is handed.
An operator who can set a UEFI boot variable can inject a cmdline that disables
dm-verity **while leaving PCR4 unchanged** — the appended cmdline lands in
**PCR12**, not PCR4. Sealing to PCR4 alone is therefore bypassable (AWS advisory
[GHSA-xrv8-2pf5-f3q7](https://github.com/aws/nitrotpm-attestation-samples/security/advisories/GHSA-xrv8-2pf5-f3q7)).
Binding PCR4 + PCR12 — AWS's standard-boot validation set — closes it. PCR12 is
all-zeros on a clean boot and stable across reboots, so it adds no
spurious-lockout risk. (No live wrong-PCR tamper demo is shipped: it is not
cleanly reachable on a zero-access instance, and the lock is a property of the
seal policy, enforced by the TPM regardless.)

### Reboot only — never stop/start

**Reboot survives; stop/start does not.** A stopped/started instance gets fresh
NitroTPM state: the storage hierarchy the sealed keyslot lives under does not
persist across stop/start, so the TPM can no longer unseal the key and the
volume is unrecoverable (there is no recovery keyslot — data loss is accepted).
This is **not** a PCR change: PCR4/PCR12 recompute to the same values for the
same AMI. A reboot keeps the same TPM state and PCRs, so only reboot is
supported.

## Manual verification (on a real instance)

These require a live NitroTPM instance and are not automated here:

- **Reboot survival:** reboot the instance; confirm `/mnt/data` is still mounted
  and `journalctl -u nitrotpm-data.service` shows a clean unlock.
- **No AWS/network dependency:** detach the network / remove any credentials and
  reboot; the volume still unlocks from NitroTPM alone.

## CI pipeline

`.github/workflows/build-attestable-image.yml` builds the AMI in two jobs:

- **`build-and-publish`** (ubuntu-24.04): builds the `.raw` inside the privileged
  `kiwi-builder` container, extracts the reference **PCR4 + PCR12** (failing if
  PCR12 is absent — the guard that `aws-nitro-tpm-tools` is >= 1.1.0), then
  publishes the raw image + measurements to GHCR as a **digest-pinned OCI
  artifact** (ORAS, version + SHA-256 pinned) annotated with the PCRs, and
  generates a **SLSA build-provenance attestation** pushed to the registry.
- **`build-ami`** (`needs: build-and-publish`, `main`/dispatch only):
  authenticates to AWS via **OIDC** (no static keys), pulls the artifact by
  digest and `gh attestation verify`s the expected workflow, installs `coldsnap`
  from a version-keyed cache, `coldsnap upload`s the `.raw` to an EBS snapshot
  **on the runner** (no builder instance), and `register-image`s the AMI. The
  AMI id lands in the job summary and in `ami_build_result.json`.

### Required repository configuration

- **GHCR:** the default `GITHUB_TOKEN` with `packages: write` (job 1) /
  `packages: read` (job 2) — no extra secret.
- **AWS OIDC role:** repository variable `AWS_ROLE_ARN` (a role trusting the
  GitHub OIDC provider) and `AWS_REGION`. **No static AWS keys.** Scope the role
  to least privilege:
  - `ebs:StartSnapshot`, `ebs:PutSnapshotBlock`, `ebs:CompleteSnapshot`
  - `ec2:RegisterImage`, `ec2:DescribeSnapshots`
  - (+ a KMS grant only if the snapshot is encrypted with a CMK)
- No SSH / debug build path and no builder EC2 instance exist by design — the
  image is zero-operator-access and the raw→AMI step runs entirely on the runner.

### Verify / pull the published artifact yourself

The job summary prints the digest-pinned reference. To verify and pull:

```bash
gh attestation verify "oci://ghcr.io/<owner>/<repo>/attestable-raw@sha256:<digest>" \
  --repo <owner>/<repo> \
  --signer-workflow <owner>/<repo>/.github/workflows/build-attestable-image.yml

oras pull "ghcr.io/<owner>/<repo>/attestable-raw@sha256:<digest>" -o pulled/
# reference PCR4/PCR12 are OCI annotations on the manifest and inside pulled/pcr_measurements.json
```

## Teardown

Terminate the instance, delete the data volume, deregister the AMI, and delete
its snapshot.

## License

Apache License 2.0. Portions derived from
`amazonlinux/kiwi-image-descriptions-examples` (Apache-2.0). See `LICENSE`.
