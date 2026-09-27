## ADDED Requirements

### Requirement: Automated KIWI image build in CI

A GitHub Actions job SHALL build the KIWI `.raw` image inside a privileged Docker
builder on the runner and SHALL extract the reference PCR4 and PCR12 from the
build's `pcr_measurements.json`. The job SHALL fail if PCR12 is missing, so that a
`nitro-tpm-pcr-compute` older than 1.1.0 cannot silently produce an image without the
PCR12 reference.

#### Scenario: Build produces the raw image and both reference PCRs

- **WHEN** the build job runs on a push or manual dispatch
- **THEN** the KIWI `.raw` and `pcr_measurements.json` are produced by the Docker builder
- **AND** PCR4 and PCR12 are extracted and surfaced in the job summary
- **AND** the job fails if PCR12 is absent or null

### Requirement: Publish a digest-pinned OCI artifact with build provenance

The build job SHALL publish the `.raw` image and `pcr_measurements.json` to GHCR as an
OCI artifact using ORAS, annotated with the reference PCR4 and PCR12, and SHALL
generate a SLSA build-provenance attestation for the artifact pushed to the registry.
Downstream consumers SHALL be given a digest-pinned reference, not a mutable tag.

#### Scenario: Artifact is pushed and attested

- **WHEN** the image build succeeds
- **THEN** the raw image and measurements are pushed to GHCR via ORAS with PCR annotations
- **AND** a SLSA provenance attestation is produced and pushed to the registry
- **AND** the job outputs a digest-pinned artifact reference for the AMI job to consume

### Requirement: Automated AMI registration via OIDC

A second GitHub Actions job SHALL authenticate to AWS using an OIDC role (no static
credentials), pull the published artifact by its digest-pinned reference while
verifying the expected workflow, convert the `.raw` into an EBS snapshot by uploading it
through the EBS direct APIs with `coldsnap` running on the runner (no builder instance),
and register the AMI with `--boot-mode uefi --tpm-support v2.0`. The block-level upload
SHALL NOT interpret or modify the image, so the measured-boot layout (and thus PCR4) is
preserved.

#### Scenario: Artifact becomes a registered attestable AMI

- **WHEN** the AMI job runs after a successful build on `main` or manual dispatch
- **THEN** AWS access is obtained via the OIDC role with no static credentials
- **AND** the artifact is pulled by digest and the expected workflow is verified
- **AND** `coldsnap` uploads the `.raw` to an EBS snapshot on the runner without provisioning any builder instance
- **AND** the AMI is registered with UEFI boot mode and NitroTPM v2.0 support and its id is emitted

#### Scenario: No builder instance to leak

- **WHEN** the AMI job runs
- **THEN** no EC2 builder instance is provisioned and no Terraform teardown is required
- **AND** the OIDC role is scoped to the EBS direct APIs and `ec2:RegisterImage` only

### Requirement: CI supply-chain hardening

The pipeline SHALL pin every GitHub Action to a commit SHA, SHALL scope
`permissions` to the least privilege each job needs, and SHALL NOT include an SSH or
other operator-access build path, preserving the image's zero-operator-access
property.

#### Scenario: Workflow follows supply-chain constraints

- **WHEN** the workflow definition is reviewed
- **THEN** every `uses:` action is pinned to a commit SHA
- **AND** each job declares only the permissions it needs
- **AND** no build option enables SSH or other operator access in the image
