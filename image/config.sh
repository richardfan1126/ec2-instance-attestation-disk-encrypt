#!/bin/bash
# KIWI image configuration hook (runs in the image chroot at build time).

# Enable the set-hostname-imds service. This will set the hostname
# based on IMDS in place of cloud-init.
echo "enable set-hostname-imds.service" >> /usr/lib/systemd/system-preset/80-amzn-overrides.preset

# Enable the baked NitroTPM data-volume enroll/unlock unit the same way:
# there is no cloud-init/user-data on this image, so persistent config is
# baked in and enabled via preset.
echo "enable nitrotpm-data.service" >> /usr/lib/systemd/system-preset/80-amzn-overrides.preset

# Enable the read-only boot report (live PCR4/PCR12 + LUKS binding + mount
# state to the serial console) the same way.
echo "enable nitrotpm-data-report.service" >> /usr/lib/systemd/system-preset/80-amzn-overrides.preset

systemctl preset set-hostname-imds.service nitrotpm-data.service nitrotpm-data-report.service
