#!/bin/bash
# Dry-run variant of run_org.sh: does all the cheap host-side prep (cookbook
# expansion, sanity checks) but only ECHOes the heavy `uv run` model calls so
# the flow can be exercised on the placeholder ubuntu:24.04 image without a GPU
# or a live Qwen Image-Edit endpoint. Swap to run_org.sh on the real
# paidf-augmentation image (see docker-compose.yaml comments).
set -euo pipefail

INPUT_DIR="${INPUT_DIR:-/data/input}"
OUTPUT_DIR="${OUTPUT_DIR:-/data/output}"

mkdir -p "$OUTPUT_DIR"

# usd2roi-components ships crop/<MATERIAL>/<cell>/normal_img/<NNNN>.png
MAT_COUNT=$(find "$INPUT_DIR/crop" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
[ "$MAT_COUNT" -gt 0 ] || { echo "ERROR: no material subdirs under $INPUT_DIR/crop/"; exit 1; }

# 1. Expand the cookbook's `data:` to the per-cell tree and overlay the endpoint
#    URL / model from the environment (cookbook ships a localhost placeholder).
echo "uv run python /tmp/build_batch_config.py \
  \"$INPUT_DIR\" \"$OUTPUT_DIR\" /tmp/augmentation_cookbook.yaml /tmp/augmentation_batch.yaml"

# 2. Run the image-edit augmentation over every ROI in the expanded batch config.
echo "uv run python /app/modules/cli.py --config /tmp/augmentation_batch.yaml"

# 3. Sanity check — at least one restyled image emitted.
#    Disabled in the dry-run: the model calls above are only echoed, so no
#    images are actually produced. Re-enabled in run_org.sh (the real executor).
# EMITTED=$(find "$OUTPUT_DIR/crop" -mindepth 3 \( -name '*.png' -o -name '*.jpg' \) 2>/dev/null | wc -l)
# if [ "$EMITTED" -eq 0 ]; then
#   echo "ERROR: 0 image-edit images emitted"; exit 1
# fi
# CELLS=$(find "$OUTPUT_DIR/crop" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l)
# echo "image-edit complete: $EMITTED images across $CELLS material/cell dir(s)"
