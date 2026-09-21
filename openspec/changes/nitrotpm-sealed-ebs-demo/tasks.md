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
- [ ] 4.2 First-boot branch (`! cryptsetup isLuks`): assert live PCR12 is all-zeros (refuse to enroll otherwise, guarding against a first boot with an injected cmdline), `luksFormat` with a random bootstrap key, enroll TPM2 keyslot sealed to PCR4 + PCR12 via `systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=4+12` (`+` is the confirmed separator), remove the bootstrap key
- [ ] 4.3 Every-boot: `cryptsetup open` (TPM unseal), create the filesystem on first boot, mount at `/mnt/data`; exit cleanly (leave volume locked) if unseal fails
- [ ] 4.4 Confirm idempotency: on later boots the `isLuks` guard skips format/enroll and only opens+mounts

## 5. Build, register, launch

- [ ] 5.1 Document the `kiwi-ng system build` command and capturing `pcr_measurements.json` (reference PCR4/PCR12)
- [ ] 5.2 Document converting the raw image to an AMI and `aws ec2 register-image --boot-mode uefi --tpm-support v2.0`
- [ ] 5.3 Document launching the instance on a NitroTPM-capable type with a second EBS data volume attached; confirm NitroTPM in-guest (`/dev/tpmrm0`)

## 6. Demo walkthrough (README)

- [ ] 6.1 Document step: launch -> first boot enrolls -> reboot -> volume auto-unlocks and mounts at `/mnt/data` (with verification commands)
- [ ] 6.1a Document that the reference `pcr_measurements.json` is a verification anchor (confirm the running instance's live PCR4 matches the built AMI), not an input to the seal; first-boot PCR4 trust rests on immutability + dm-verity
- [ ] 6.2 Document the tamper step: append a kernel cmdline on the same instance (UEFI boot variable or systemd-boot addon) and reboot, or `tpm2_pcrextend 12:...` without reboot; show PCR12 changed vs `pcr_measurements.json` (PCR4 unchanged) and the volume stays locked
- [ ] 6.3 Note the PCR4-only bypass this defends against (AWS GHSA-xrv8-2pf5-f3q7): an injected cmdline that disables integrity while keeping PCR4 constant
- [ ] 6.4 Document the reboot-only boundary and the explicit warning: do NOT stop/start (measurements change; data becomes unrecoverable by design)

## 7. Verification

- [ ] 7.1 Manual test on a real instance: reboot survives unlock (happy path), `/mnt/data` mounted
- [ ] 7.2 Manual test: append a cmdline (or `tpm2_pcrextend 12`) -> locked (negative path), confirm PCR12 delta via `tpm2_pcrread sha256:12` against the build reference while PCR4 is unchanged
- [ ] 7.3 Manual test: unlock works with the network detached / no AWS credentials (proves no KMS/IAM dependency)

## 8. CI: image build + publish job

- [ ] 8.1 Add `.github/docker/Dockerfile.kiwi-builder` (privileged KIWI-NG build env)
- [ ] 8.2 Add `.github/scripts/build-kiwi-image.sh` invoking `kiwi-ng system build` -> `build-output/*.raw` + `pcr_measurements.json`
- [ ] 8.3 Add `.github/workflows/build-attestable-image.yml` job `build-and-publish` (ubuntu-24.04): checkout, buildx, build kiwi-builder, run build script, upload raw + measurements artifact
- [ ] 8.4 Extract step: read PCR4 and PCR12 from `pcr_measurements.json`, fail if PCR12 is missing/null, write to job outputs + step summary
- [ ] 8.5 Install ORAS (pinned version + SHA-256 checksum verify) and push raw + measurements to GHCR with PCR4/PCR12 annotations; output a digest-pinned artifact reference
- [ ] 8.6 Generate SLSA build-provenance attestation (`actions/attest`, push-to-registry) for the pushed digest

## 9. CI: AMI build job (Path A)

- [ ] 9.1 Add `terraform/build-ami/` for an ephemeral builder instance (right-sized) + its IAM
- [ ] 9.2 Add `scripts/build-ami.py`: pull the OCI artifact by digest, verify the expected workflow, `dd` raw -> attached volume -> `create-snapshot` -> `register-image --boot-mode uefi --tpm-support v2.0`, emit `ami_build_result.json`
- [ ] 9.3 Add job `build-ami` (`needs: build-and-publish`, `main`/dispatch only): OIDC `configure-aws-credentials` with `vars.AWS_ROLE_ARN`, setup Terraform + uv, run `build-ami.py`
- [ ] 9.4 `if: always()` cleanup: `terraform destroy`, warn on failure for manual cleanup; upload `ami_build_result.json`

## 10. CI: hardening + docs

- [ ] 10.1 Pin every action by commit SHA; set least-privilege `permissions` per job (`build-and-publish`: packages/attestations/id-token write; `build-ami`: id-token write, packages read)
- [ ] 10.2 Document required repo config: GHCR access, the AWS OIDC role (`AWS_ROLE_ARN`), region var; no static AWS keys, no SSH/debug build path
- [ ] 10.3 Document the verify/pull instructions in the job summary (`gh attestation verify`, `oras pull`) and where the reference PCR4/PCR12 land
