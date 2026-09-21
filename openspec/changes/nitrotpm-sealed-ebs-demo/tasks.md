## 1. Project scaffolding

- [ ] 1.1 Create repo layout: `image/` (KIWI recipe), `image/root/` (baked overlay), `README.md`, `LICENSE`/`.gitignore`
- [ ] 1.2 Document prerequisites in README: an AL2023 builder with `kiwi-ng`, a NitroTPM-capable instance type, `--boot-mode uefi --tpm-support v2.0`

## 2. KIWI-NG attestable image recipe

- [ ] 2.1 Fork AWS `attestable-image-example` `appliance.kiwi`: systemd-boot UKI, `verity_blocks="all"` panic-on-corruption, erofs `overlayroot` with `overlayroot_write_partition="false"`, ignore cloud-init / openssh-server / amazon-ssm-agent / ec2-instance-connect
- [ ] 2.2 Ensure image packages include `cryptsetup`, `veritysetup`, `aws-nitro-tpm-tools`, `systemd-boot`, `dracut-kiwi-verity`, `dracut-kiwi-overlay`
- [ ] 2.3 Carry over `config.sh` (preset-enable our enrollment unit, cloud-init replacement pattern) and `edit_boot_install.sh` (build-time `nitro-tpm-pcr-compute` -> `pcr_measurements.json`) and `add-gpg-key.sh`
- [ ] 2.4 Verify `nitro-tpm-pcr-compute --version` on the builder is >= 1.1.0 (PCR12 support; latest 1.1.2) so the build emits the PCR12 reference (default all-zeros), not just PCR4/PCR7

## 3. Baked enrollment unit + mountpoint

- [ ] 3.1 Bake mountpoint dir `image/root/mnt/data` into the overlay
- [ ] 3.2 Add `image/root/usr/lib/systemd/system/nitrotpm-data.service` (oneshot, `RemainAfterExit`, ordered before dependent workloads / after the block device appears)
- [ ] 3.3 Enable the unit via `systemctl preset` in `config.sh`

## 4. Enrollment + unlock script

- [ ] 4.1 Write the enroll/unlock script (baked into `image/root/`): resolve the data volume by a stable `/dev/disk/by-id/` identifier (no IMDS/AWS call on the unlock path)
- [ ] 4.2 First-boot branch (`! cryptsetup isLuks`): `luksFormat` with a random bootstrap key, enroll TPM2 keyslot sealed to PCR4 + PCR12 via `systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=4+12` (`+` is the confirmed separator), remove the bootstrap key
- [ ] 4.3 Every-boot: `cryptsetup open` (TPM unseal), create the filesystem on first boot, mount at `/mnt/data`; exit cleanly (leave volume locked) if unseal fails
- [ ] 4.4 Confirm idempotency: on later boots the `isLuks` guard skips format/enroll and only opens+mounts

## 5. Build, register, launch

- [ ] 5.1 Document the `kiwi-ng system build` command and capturing `pcr_measurements.json` (reference PCR4/PCR12)
- [ ] 5.2 Document converting the raw image to an AMI and `aws ec2 register-image --boot-mode uefi --tpm-support v2.0`
- [ ] 5.3 Document launching the instance on a NitroTPM-capable type with a second EBS data volume attached; confirm NitroTPM in-guest (`/dev/tpmrm0`)

## 6. Demo walkthrough (README)

- [ ] 6.1 Document step: launch -> first boot enrolls -> reboot -> volume auto-unlocks and mounts at `/mnt/data` (with verification commands)
- [ ] 6.2 Document the tamper step: append a kernel cmdline on the same instance (UEFI boot variable or systemd-boot addon) and reboot, or `tpm2_pcrextend 12:...` without reboot; show PCR12 changed vs `pcr_measurements.json` (PCR4 unchanged) and the volume stays locked
- [ ] 6.3 Note the PCR4-only bypass this defends against (AWS GHSA-xrv8-2pf5-f3q7): an injected cmdline that disables integrity while keeping PCR4 constant
- [ ] 6.4 Document the reboot-only boundary and the explicit warning: do NOT stop/start (measurements change; data becomes unrecoverable by design)

## 7. Verification

- [ ] 7.1 Manual test on a real instance: reboot survives unlock (happy path), `/mnt/data` mounted
- [ ] 7.2 Manual test: append a cmdline (or `tpm2_pcrextend 12`) -> locked (negative path), confirm PCR12 delta via `tpm2_pcrread sha256:12` against the build reference while PCR4 is unchanged
- [ ] 7.3 Manual test: unlock works with the network detached / no AWS credentials (proves no KMS/IAM dependency)
