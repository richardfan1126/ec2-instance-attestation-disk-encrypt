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
    usr/lib/systemd/system/nitrotpm-data.service         enroll/unlock unit (output -> serial)
    usr/lib/systemd/system/nitrotpm-data-report.service  read-only boot report -> serial
    usr/local/sbin/nitrotpm-data-enroll.sh    enroll + unlock (runs every boot)
    usr/local/sbin/nitrotpm-data-report.sh    prints PCR4/12 + LUKS binding + mount to serial
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

There is **no interactive access** on this image — no sshd, no SSM, no
ec2-instance-connect, and the kernel cmdline sets `systemd.getty_auto=false`
(no login prompt) and `rd.shell=0` (no rescue shell). The **EC2 serial
console** is therefore **output-only**: you *watch* boot on it, you cannot type
commands. You cannot add a shell either — doing so changes the root filesystem,
the dm-verity roothash, and thus PCR4, and the TPM then refuses to release the
key. That is the point: the console being present is harmless because nothing
listens on it, and you can have a shell or the key, never both.

So verification is done from what the box *emits* (the baked boot report on the
serial console, below) and from *outside* the box (the off-box tests under
[Manual verification](#manual-verification-on-a-real-instance)) — not from an
in-guest shell.

## Demo walkthrough

1. **First boot** — `nitrotpm-data.service` runs. It discovers the data volume
   by exclusion (the single `Amazon Elastic Block Store` NVMe namespace not in
   use by the running system), sees no LUKS header, `luksFormat`s it, enrolls a
   TPM2 keyslot sealed to PCR4 + PCR12, wipes the bootstrap key, then unlocks and
   mounts it at `/mnt/data`.
2. **Reboot** — the same unchanged AMI produces the same PCR4 + PCR12, so
   NitroTPM releases the key and the volume auto-unlocks and mounts at
   `/mnt/data` with zero interaction.

Verify by **watching the EC2 serial console** during boot — there is no shell
to run commands in (see [Launch and confirm NitroTPM](#launch-and-confirm-nitrotpm)).
Two units write their output to the console (`StandardOutput=journal+console`,
so `/dev/console` == `ttyS0` per the kernel cmdline):

- `nitrotpm-data.service` prints its `nitrotpm-data:` breadcrumb — on success
  `OK: /dev/… unlocked and mounted at /mnt/data`, otherwise a `REFUSED: …`
  line naming exactly why the volume was left locked.
- `nitrotpm-data-report.service` then prints a read-only boot report:

  ```
  nitrotpm-data-report: live PCR4 (sha384): <hex>
  nitrotpm-data-report: live PCR12 (sha384): <hex>
  nitrotpm-data-report:   Keyslots:
  nitrotpm-data-report:     1: luks2                     # the TPM keyslot ...
  nitrotpm-data-report:   Tokens:
  nitrotpm-data-report:     0: systemd-tpm2              # ... bound by this token
  nitrotpm-data-report:           tpm2-hash-pcrs:   4+12 #     to PCR4 + PCR12
  nitrotpm-data-report:           tpm2-pcr-bank:    sha384
  nitrotpm-data-report:   mount: /mnt/data /dev/mapper/data ext4
  nitrotpm-data-report: attestation: nitro-tpm-attest produced a signed document (… bytes); validate it off-box
  ```

  There is **only one keyslot** and it is bound by the `systemd-tpm2` token — the
  bootstrap password slot was wiped at enroll. Compare the printed **live PCR4 /
  PCR12** against the build-time `pcr_measurements.json` (hex is case-insensitive)
  to confirm the instance measured to the AMI that was built.

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

These require a live NitroTPM instance and are not automated here. The first two
are observed on the serial console (no shell needed); the rest are proven from
outside the box.

- **Reboot survival (the core positive test):** reboot the instance and watch the
  serial console. The same AMI reproduces the same PCR4 + PCR12, so the TPM
  releases the key with zero interaction — you see `nitrotpm-data.service` reach
  `OK: … unlocked and mounted` and the boot report show `/mnt/data` mounted
  again. (Write a file to `/mnt/data` before the reboot if you want end-to-end
  proof the *data* survived; you'll read it back off-box in the next test.)
- **Seal integrity (negative test) — proves the data is actually protected:**
  stop the instance, detach the data volume, attach it to an ordinary instance,
  and try to open it:

  ```bash
  cryptsetup luksDump /dev/<dev>     # a systemd-tpm2 token, NO password keyslot
  cryptsetup open /dev/<dev> test    # MUST fail: no passphrase, and this box's
                                     # NitroTPM cannot unseal the other instance's key
  ```

  It cannot unlock — the sealed slot needs the original instance's NitroTPM state
  and matching PCRs, and there is no recovery passphrase. This is the test that
  demonstrates the protection holds. It needs no shell on the target instance.
- **No AWS/network dependency:** detach the ENI / remove any credentials and
  reboot; the boot report still shows a clean unlock — the key comes from
  NitroTPM alone, never KMS or the network.
- **Stop/start is unrecoverable (expected, not a bug):** stop/start (not reboot)
  the instance and watch the serial console — `nitrotpm-data.service` now prints
  `REFUSED: TPM unseal failed … (NitroTPM state lost on stop/start)`. Confirming
  this failure confirms the documented behavior; there is no recovery keyslot and
  the data is gone by design.

For deep interactive checks (`cryptsetup`/PCR poking by hand) build a **debug
variant** of the image with a getty or sshd added — validate the *logic* there,
accepting it has a **different PCR4** and is not the image you ship. The
production image is verified by the serial-console observations above plus the
off-box negative test.

> **Note:** the baked boot report (`nitrotpm-data-report.service`) is read-only
> and creates no inbound access, but adding it to the image is itself a change,
> so the built AMI has a **new reference PCR4** — the CI pipeline regenerates
> `pcr_measurements.json` from the UKI on every build, so the image stays
> self-consistent (it still matches *its own* measurements).

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
