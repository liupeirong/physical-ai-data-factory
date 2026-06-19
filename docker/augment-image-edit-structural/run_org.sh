#!/usr/bin/env bash
# Standalone port of the inline run_image_edit.sh from the OSMO
# `augment-image-edit` task in
#   skills/physical-ai-defect-image-generation/assets/configs/structural_defect_generation.yaml
# OSMO templating is replaced by environment variables supplied by
# docker-compose.yaml:
#   INPUT_DIR            was {{input:0}}  (isaac-render-defect output tree, mounted ro)
#                        (the dir that contains cropped/<mode>/rgb/<NNNN>.png)
#   OUTPUT_DIR           was {{output}}   (host output dir -> runs/<name>/structural_defect_edited)
#   IMAGE_EDIT_ENDPOINT  was {{ image_edit_endpoint }}
#   IMAGE_EDIT_MODEL     was {{ image_edit_model }}
#   HF_TOKEN             was the credentials: hf-token injection
set -euo pipefail

INPUT_DIR="${INPUT_DIR:-/data/input}"
OUTPUT_DIR="${OUTPUT_DIR:-/data/output}"

mkdir -p "$OUTPUT_DIR"

# structural_defect crop layout: $INPUT_DIR/cropped/<mode>/rgb/<NNNN>.png
# where mode ∈ {shift, tombstone, sideflip} (any subset enabled at render time).
RGB_COUNT=$(find "$INPUT_DIR/cropped" -mindepth 2 -path '*/rgb/*' \( -name '*.png' -o -name '*.jpg' \) 2>/dev/null | wc -l)
[ "$RGB_COUNT" -gt 0 ] || { echo "ERROR: no per-mode rgb crops under $INPUT_DIR/cropped/<mode>/rgb/"; ls -laR "$INPUT_DIR/cropped" 2>/dev/null | head -40; exit 1; }

# 1. Expand the cookbook's `data:` to the per-mode rgb tree and overlay the
#    endpoint URL / model from the environment (cookbook ships a localhost placeholder).
uv run python /tmp/build_batch_config.py \
  "$INPUT_DIR" "$OUTPUT_DIR" /tmp/augmentation_cookbook.yaml /tmp/augmentation_batch.yaml

# 2. Run the image-edit augmentation over every ROI in the expanded batch config.
uv run python /app/modules/cli.py --config /tmp/augmentation_batch.yaml

# 3. Sanity check — at least one restyled image emitted under <mode>/rgb/.
EMITTED=$(find "$OUTPUT_DIR" -mindepth 3 -path '*/rgb/*' \( -name '*.png' -o -name '*.jpg' \) 2>/dev/null | wc -l)
[ "$EMITTED" -gt 0 ] || { echo "ERROR: 0 image-edit images emitted"; exit 1; }
MODES=$(find "$OUTPUT_DIR" -mindepth 2 -maxdepth 2 -type d -name rgb -printf '%h\n' 2>/dev/null | xargs -n1 basename 2>/dev/null | sort -u | tr '\n' ' ')
echo "image-edit complete: $EMITTED images at $OUTPUT_DIR/<mode>/rgb/  modes: ${MODES}"
