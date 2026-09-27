#!/bin/bash
#
# Self-check for the data-volume discovery-by-exclusion logic in
# nitrotpm-data-enroll.sh. Builds a fake sysfs block tree and asserts that
# candidates() selects exactly the free EBS namespace and nothing else.
#
#   ./test_nitrotpm_data.sh   (exit 0 = pass)
#
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
NITROTPM_DATA_LIB=1 source "$here/root/usr/local/sbin/nitrotpm-data-enroll.sh"

fake=$(mktemp -d)
trap 'rm -rf "$fake"' EXIT

mk() { # mk <name> <model> <partitioned:0|1> <held:0|1>
    local d="$fake/$1"
    mkdir -p "$d/device" "$d/holders"
    printf '%s\n' "$2" >"$d/device/model"
    [ "$3" = 1 ] && mkdir -p "$d/${1}p1"        # a partition child
    [ "$4" = 1 ] && : >"$d/holders/dm-0"        # a holder
    return 0
}

# Boot disk: EBS but GPT-partitioned and held by verity -> excluded twice over.
mk nvme0n1 "Amazon Elastic Block Store" 1 1
# Instance-store ephemeral: whole-disk but wrong model -> excluded.
mk nvme1n1 "Amazon EC2 NVMe Instance Storage" 0 0
# The data volume: EBS, whole-disk, no holders -> the one true candidate.
mk nvme2n1 "Amazon Elastic Block Store  " 0 0    # trailing space, must trim

BLOCK_DIR="$fake" got=$(candidates)

pass=1
[ "$got" = "nvme2n1" ] || { echo "FAIL: expected 'nvme2n1', got '$got'"; pass=0; }

# Second free EBS volume -> ambiguous: candidates() must now return two lines.
mk nvme3n1 "Amazon Elastic Block Store" 0 0
BLOCK_DIR="$fake" n=$(candidates | grep -c .)
[ "$n" -eq 2 ] || { echo "FAIL: expected 2 candidates when ambiguous, got $n"; pass=0; }

if [ "$pass" = 1 ]; then echo "PASS"; else exit 1; fi
