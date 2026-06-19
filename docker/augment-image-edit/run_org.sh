#!/usr/bin/env bash
# Standalone port of the inline run_image_edit.sh from the OSMO
# `augment-image-edit` task in assets/configs/good_image_generation.yaml.
# OSMO templating is replaced by environment variables supplied by
# docker-compose.yaml:
#   INPUT_DIR            was {{input:0}}  (usd2roi-components tree, mounted ro)
#   OUTPUT_DIR          was {{output}}    (host output dir -> runs/<name>/augment)
#   IMAGE_EDIT_ENDPOINT  was {{ image_edit_endpoint }}
#   IMAGE_EDIT_MODEL     was {{ image_edit_model }}
#   HF_TOKEN             was the credentials: hf-token injection
set -euo pipefail

INPUT_DIR="${INPUT_DIR:-/data/input}"
OUTPUT_DIR="${OUTPUT_DIR:-/data/output}"

mkdir -p "$OUTPUT_DIR"

# usd2roi-components ships crop/<MATERIAL>/<cell>/normal_img/<NNNN>.png
MAT_COUNT=$(find "$INPUT_DIR/crop" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
[ "$MAT_COUNT" -gt 0 ] || { echo "ERROR: no material subdirs under $INPUT_DIR/crop/"; exit 1; }

# 1. Expand the cookbook's `data:` to the per-cell tree and overlay the endpoint
#    URL / model from the environment (cookbook ships a localhost placeholder).
uv run python /tmp/build_batch_config.py \
  "$INPUT_DIR" "$OUTPUT_DIR" /tmp/augmentation_cookbook.yaml /tmp/augmentation_batch.yaml

# 2. Run the image-edit augmentation over every ROI in the expanded batch config.
uv run python /app/modules/cli.py --config /tmp/augmentation_batch.yaml

# 3. Sanity check — at least one restyled image emitted.
EMITTED=$(find "$OUTPUT_DIR/crop" -mindepth 3 \( -name '*.png' -o -name '*.jpg' \) 2>/dev/null | wc -l)
[ "$EMITTED" -gt 0 ] || { echo "ERROR: 0 image-edit images emitted"; exit 1; }
CELLS=$(find "$OUTPUT_DIR/crop" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l)
echo "image-edit complete: $EMITTED images across $CELLS material/cell dir(s)"
