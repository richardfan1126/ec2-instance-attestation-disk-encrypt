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
- Surviving **stop/start**. A stopped/started instance gets fresh NitroTPM state:
  the storage hierarchy the sealed keyslot lives under does not persist across
  stop/start, so the TPM can no longer unseal the key. Note this is *not* because
  the measurements change — PCR4/PCR12 recompute to the same values for the same
  AMI (AWS: "PCRs are recalculated after each reboot"); the lockout is TPM-state
  loss, not a PCR mismatch. (AWS's public docs do not spell out the stop/start TPM
  persistence boundary; this is observed TPM behavior.) Reboot keeps the same TPM
  state and the same PCRs, so only reboot survival is in scope.
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

**Identify the data volume by exclusion, not by a baked identifier.**
The image is immutable and has no user-data, so it cannot carry the volume-specific
`/dev/disk/by-id/...vol...` string (the EBS volume id is per-attachment, unknown at
build time). NVMe enumeration order is also not stable across reboots, so a fixed
`/dev/nvme1n1` is a latent bug. The baked unit therefore discovers the data volume at
runtime by exclusion: among NVMe namespaces, select the one whose controller model is
`Amazon Elastic Block Store` (this excludes instance-store ephemeral disks, which are
also whole-disk), that is **not in use by the running system** (not mounted, no
holders, not in root's device-mapper / verity / overlay chain), and — as confirmation —
has no partition table. This is enumeration-order-invariant and needs no extra image
package, no udev rule, and no IMDS/AWS call on the unlock path. This suits the
architecture where the OS/boot volume is stable and immutable while the sensitive data
lives on a completely separate EBS volume that never participates in boot.

**"Not in use" is the primary discriminator; "no partitions" only confirms.**
"No partition table" alone is unsafe: early in boot the boot disk's partitions may not
yet be probed, so it can transiently look whole-disk and be mis-selected — and then the
first-boot branch would reformat the root volume. Keying on "in use by the OS" has no
such window: by the time the unit runs (ordered after root is mounted) the boot disk is
mounted and has holders, so it is excluded regardless of partition-probe timing. The
partition-less check is kept as defense-in-depth. The invariant behind this is not
luck: UEFI measured boot requires an ESP (a partition) and dm-verity requires a hash
partition, so an attestable boot disk is necessarily GPT-partitioned — the same property
that makes PCR4 meaningful guarantees the boot disk is partitioned. (It is coupled to
this image's layout; revisit if the root layout ever changes.)

**Require exactly one candidate; otherwise refuse and mount nothing.**
Zero candidates (no data volume attached) and two-or-more (ambiguous) both fail the
unit without formatting anything. This doubles as the destructive-format guard alongside
`cryptsetup isLuks`: the unit never guesses which of several blank volumes to format.
The three independent guards before anything is written are: exactly-one (ambiguity),
`isLuks` (skip format/enroll), and a post-open `blkid` has-filesystem check (skip `mkfs`).

**Distinguish "absent" from "not-yet-arrived" with a bounded stable-count wait, biased
toward waiting.** There is no kernel signal for "all volumes are now present," and
`udevadm settle` only drains queued events (it does not wait for a device that has
emitted none). The scope decision (reboot survival, volumes attached at launch) largely
resolves this: attach-at-launch EBS devices are enumerated before userspace, so a
late-ordered unit sees them. The unit still gates on a **stable** candidate count (count
unchanged across a short quiet window) rather than the first sighting, which both waits
out the transient boot-disk topology and catches a racing second volume. Failure
asymmetry sets the bias: a false refuse (device was slow) leaves `/mnt/data` unmounted
and is recovered by a reboot, whereas acting on a partial view is worse (the catastrophic
mis-format is already barred by the in-use check, leaving only a contract violation on an
unsupported multi-volume config) — so the unit waits rather than acts when unsure. A
0-count means user error on first boot but a detached/failing volume on reboot (data at
stake), so reboot warrants the louder log, not a shorter wait.

**On a zero-access image, a refusal is only as visible as its log.** With no SSH/SSM, a
failed unit is not inspectable interactively; the only signals are whether `/mnt/data`
is mounted and the journal as seen on the EC2 serial console. The unit therefore writes
a loud, structured breadcrumb on every refuse (e.g. `REFUSED: 0 candidates after 30s`
vs `REFUSED: 2 candidates {...}`) so the serial console alone is enough to diagnose.

**Order the unit after the TPM and udev, before `multi-user.target`.**
The unit is `After=dev-tpmrm0.device systemd-udevd.service` and
`Before=multi-user.target`; the TPM device unit is nameable regardless of discovery, and
running before `multi-user.target` means `/mnt/data` is mounted once the box is "ready."
Because the mount is performed imperatively inside the oneshot (no fstab, no `.mount`
unit — the choice that avoids the crypttab-generator fight), there is no mount unit to
depend on: any future consumer of `/mnt/data` must order `After=nitrotpm-data.service`,
and `RequiresMountsFor=/mnt/data` will not help unless the unit is switched to
`systemd-mount`. For this demo, with no dependent workload, `Before=multi-user.target`
is sufficient. If real consumers ever appear, the alternative is a udev rule that
symlinks the discovered device to a stable name and ordering against that `.device`
unit — cleaner ordering, but udev silently masks a symlink collision, which would weaken
the two-volume refusal, so it is deferred.

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

**Raw -> AMI via `coldsnap` on the runner, no builder instance.**
`register-image` needs the bits as an EBS snapshot. `coldsnap` (awslabs) uploads a
local raw disk straight to an EBS snapshot through the EBS direct APIs
(`StartSnapshot` / `PutSnapshotBlock` / `CompleteSnapshot`) block-for-block; it never
interprets the filesystem, so the erofs/dm-verity bytes and therefore PCR4 are
preserved. Because it talks to the API over HTTPS with ambient credentials, it does
**not** need the snapshot volume attached to an instance, so it runs directly on the
GitHub runner under the job's OIDC role. The reference repo
(`ec2-instance-attestation-demo`) proves the end-to-end result: `coldsnap upload` ->
snapshot -> `register-image --boot-mode uefi --tpm-support v2.0` produced a working
attestable AMI (`RootDeviceName=/dev/xvda`, `Architecture=x86_64`, `EnaSupport`,
`VirtualizationType=hvm`). This drops the entire builder-instance apparatus the earlier
plan carried (VPC/subnet/SG, EC2 instance + instance profile, SSH, Terraform,
`terraform destroy`), and with it the builder-leak risk. It also beats the two
alternatives considered: `dd` onto an attached volume needs an instance, and
`import-snapshot` needs an S3 upload plus a `vmimport` service role and is async.
(`import-image` is disqualified outright: it modifies the guest — driver/agent
injection — which would change the root filesystem, the dm-verity roothash, and PCR4.
`import-snapshot` and `coldsnap` are pure block copies and do not.)

**Install `coldsnap` by caching the compiled binary; the compile does not justify an
instance.** `coldsnap` ships no prebuilt binaries (all GitHub releases have empty
assets; crates.io is source-only, latest 0.12.0), and `cargo install` is slow because
it builds the whole AWS Rust SDK (~5-15 min on a 2-core runner). The reference sidesteps
this only by compiling on a `c5.9xlarge` (36 vCPUs) — i.e. it pays for a large instance
to make a one-time-per-version compile fast. On the runner the cheaper fix is to cache
the built binary keyed on the pinned `coldsnap` version (`~/.cargo/bin/coldsnap`,
key `coldsnap-<os>-<version>`): compile once, restore instantly thereafter, near-100%
hit rate until the version is bumped. GitHub cache evicts entries unused for 7 days, so
a build gap means one slow run; acceptable for a demo. If guaranteed-fast-every-run is
ever needed, prebuild the binary once and store it as our own digest-pinned artifact
(GHCR/release asset, checksum-verified on download), fitting the existing OCI
supply-chain pattern — still no instance.

**Keep an instance only if upload throughput, not compilation, becomes the bottleneck.**
`coldsnap upload` from a GitHub-hosted runner crosses the internet into the region and
pushes 512 KiB blocks against the rate-limited EBS direct API. For a demo-sized image
(a few GB) this is minutes and fine. Only if the image grew large or builds got frequent
would an in-region instance's faster upload justify itself — and even then, not with the
reference's transport (inbound SSH :22 from `get_user_public_ip()`, an ephemeral
keypair). That model is a security smell and CI-fragile (in CI the "user IP" is the
runner's egress IP); a fallback instance would use an instance profile + `user-data` /
SSM, no inbound SSH.

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
  reboot, never stop/start. The cause is fresh NitroTPM state on stop/start (the
  sealed keyslot's storage hierarchy does not persist), not a PCR change — PCR4/PCR12
  recompute identically for the same AMI. Data loss is acceptable, so the failure mode
  is tolerable but must be stated with the correct mechanism.
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
- **`coldsnap` compile time on the runner** → No prebuilt binary exists, so a cold
  `cargo install` builds the whole AWS Rust SDK (~5-15 min on a 2-core runner).
  Mitigated by caching the built binary keyed on the pinned version (compile once);
  a >7-day build gap evicts the cache and costs one slow run. Optional escalation: a
  self-published digest-pinned binary artifact.
- **`coldsnap` upload throughput from the runner** → EBS direct API pushes are 512 KiB
  blocks over the internet into the region and are rate-limited. Fine for a demo-sized
  image (minutes); only a large or frequently-built image would warrant moving the
  upload onto an in-region instance (instance profile + `user-data`, never inbound SSH).
- **CI scope/cost** → A privileged Docker build (KIWI needs loop devices) is the
  heaviest CI piece; the AMI job is now just runner-side `coldsnap` + `register-image`,
  no EC2 builder instance. Documented as a prerequisite (GHCR, OIDC role).
- **Device naming drift** (`/dev/nvme1n1` order not stable across reboots) → The baked
  unit discovers the data volume by exclusion (the single EBS-model NVMe namespace not
  in use by the running system), never by a fixed name or an AWS/IMDS lookup, so it is
  enumeration-order-invariant with no network on the unlock path.
- **PCR4 semantics depend on the UKI layout** → Guaranteed here because the KIWI
  recipe produces a UKI via systemd-boot + `dracut uefi="true"`.

## Migration Plan

Greenfield demo; no rollback concerns. Teardown is terminating the instance,
deleting the data volume, and deregistering the AMI / deleting its snapshot.

## Open Questions

- Confirm on a real instance the exact NVMe controller model string
  (`/sys/block/nvme*n1/device/model` — casing / trailing whitespace) that the exclusion
  filter matches on, and that the KIWI boot disk is GPT-partitioned as expected.
  (Device discovery and unit ordering are otherwise decided above — discover the data
  volume by exclusion keyed on "not in use," order `After=dev-tpmrm0.device` /
  `Before=multi-user.target`.)
- Verify the AL2023 `aws-nitro-tpm-tools` rpm on the builder bundles
  `nitro-tpm-pcr-compute` >= 1.1.0 (PCR12 support landed in 1.1.0; latest is 1.1.2)
  via `nitro-tpm-pcr-compute --version`; upgrade if it only prints PCR4/PCR7.
  [`--tpm2-pcrs=4+12` syntax and the >=1.1.0 requirement are confirmed; only the
  bundled rpm version is still to check on the builder.]
- Confirm runner-side `coldsnap upload` throughput is acceptable for this image's size
  (the one open variable in the no-instance AMI job); if not, fall back to an in-region
  upload instance (instance profile + `user-data`, no inbound SSH). The `coldsnap` ->
  `register-image --boot-mode uefi --tpm-support v2.0` path itself is confirmed by the
  reference repo, so this is a performance check, not a feasibility one.
- Pin the `coldsnap` version and the cache strategy (cache `~/.cargo/bin/coldsnap` keyed
  on version vs. self-publishing a digest-pinned prebuilt binary) during implementation.
