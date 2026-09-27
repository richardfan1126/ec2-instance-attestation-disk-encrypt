#!/usr/bin/env bash
#
# Build the AL2023 attestable .raw image with KIWI-NG and confirm the build
# emitted pcr_measurements.json. Run inside the privileged kiwi-builder
# container (see .github/docker/Dockerfile.kiwi-builder).
#
#   build-kiwi-image.sh [DESCRIPTION_DIR] [OUTPUT_DIR]
#
# Defaults: DESCRIPTION_DIR=image  OUTPUT_DIR=build-output
#
set -euo pipefail

DESC="${1:-image}"
OUT="${2:-build-output}"

mkdir -p "$OUT"

kiwi-ng --color-output --loglevel 0 system build \
    --description "$DESC" \
    --target-dir "$OUT"

# The reference PCR measurements are produced by edit_boot_install.sh during the
# build. Its absence means the build did not run the editbootinstall hook.
if [ ! -f "$OUT/pcr_measurements.json" ]; then
    echo "ERROR: $OUT/pcr_measurements.json not produced by the build" >&2
    exit 1
fi

raw=$(find "$OUT" -maxdepth 1 -name '*.raw' | head -n1)
if [ -z "$raw" ]; then
    echo "ERROR: no .raw image produced in $OUT" >&2
    exit 1
fi

echo "Built raw image: $raw"
echo "PCR measurements: $OUT/pcr_measurements.json"
cat "$OUT/pcr_measurements.json"
