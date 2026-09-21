## ADDED Requirements

### Requirement: First-boot LUKS enrollment sealed to NitroTPM

On its first boot, the instance SHALL format the attached EBS data volume as LUKS2
and enroll a keyslot whose key is sealed to NitroTPM under PCR4, then remove the
bootstrap key so that only the TPM-sealed keyslot remains. Enrollment SHALL be
performed by a systemd unit baked into the immutable image (there is no cloud-init
or user-data). The unit SHALL be idempotent: it runs on every boot but reformats
only a volume that has no LUKS header, so an already-provisioned volume is never
destroyed.

#### Scenario: Fresh data volume is provisioned

- **WHEN** the enrollment unit runs and the target data volume has no LUKS header
- **THEN** the volume is formatted as LUKS2 with a random bootstrap key
- **AND** a TPM2 keyslot sealed to PCR4 is enrolled via `systemd-cryptenroll`
- **AND** the bootstrap key is removed, leaving only the TPM-sealed keyslot
- **AND** the volume is unlocked and mounted at `/mnt/data`

#### Scenario: Already-provisioned volume is left untouched

- **WHEN** the enrollment unit runs and the target data volume already has a LUKS header
- **THEN** the volume is not reformatted and no data is destroyed
- **AND** the unit unlocks the existing volume via NitroTPM and mounts it at `/mnt/data`

### Requirement: Automatic unlock on reboot

On every boot after enrollment, the baked unit SHALL unlock the data volume by
unsealing the key from NitroTPM using the PCR4 policy, with no operator interaction,
and SHALL mount the filesystem at `/mnt/data` before workloads that depend on it.

#### Scenario: Unchanged AMI unlocks the volume

- **WHEN** the instance reboots while booting the same unchanged AMI
- **THEN** NitroTPM releases the sealed key because PCR4 matches the sealing policy
- **AND** the data volume is unlocked and mounted at `/mnt/data`

### Requirement: Locked volume when measured boot changes

When the instance's measured boot changes such that PCR4 no longer matches the
sealing policy, NitroTPM SHALL refuse to release the key and the data volume SHALL
remain locked and unmounted. No fallback key is provided, so the data is
inaccessible.

#### Scenario: Changed UKI on the same instance is denied

- **WHEN** the UKI or kernel cmdline is changed and the same instance reboots
- **THEN** PCR4 differs from the value the key was sealed to
- **AND** NitroTPM refuses to unseal the key
- **AND** the data volume stays locked and is not mounted

### Requirement: No key material leaves the instance

The scheme SHALL NOT depend on AWS KMS, IAM, or any network service to unlock the
volume. The sealed key material SHALL reside only in the LUKS2 header on the data
volume, and the plaintext key SHALL exist only transiently in the instance during
unseal.

#### Scenario: Unlock works without network or AWS credentials

- **WHEN** the instance reboots with no network reachability and no AWS credentials
- **THEN** the data volume still unlocks from NitroTPM alone and mounts at `/mnt/data`

### Requirement: Reproducible attestable image with known reference PCR4

The demo SHALL ship a KIWI-NG image description that builds an immutable,
zero-operator-access AL2023 attestable AMI (systemd-boot UKI, dm-verity, erofs
read-only overlay root, no cloud-init / sshd / ssm / ec2-instance-connect), and the
build SHALL emit the reference PCR4/PCR7 measurements as a build artifact.

#### Scenario: Build produces the AMI inputs and reference measurements

- **WHEN** the KIWI-NG build runs against the shipped image description
- **THEN** a raw disk image with a systemd-boot UKI and a read-only dm-verity root is produced
- **AND** `nitro-tpm-pcr-compute` writes the reference PCR4/PCR7 to `pcr_measurements.json`
- **AND** the persistent config (mountpoint `/mnt/data` and the enrollment unit) is baked into the image
