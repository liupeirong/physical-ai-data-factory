# Source this before `docker compose up` to populate the env the compose reads.
#   source setup.sh && docker compose up --abort-on-container-exit
#
# These tasks are run one after another by hand, but the output of a previous
# task is usually the input of the next — as if they belong to one workflow run.
# That shared run is identified by a single TIMESTAMP.
#
# This task is the entry point of the
# texture_defect_generation_day1_real_alignment flow: it consumes the canonical
# pcb-assets bundle (USD tree + input_real_image/<board>.jpg) and writes the
# per-ROI aligned crops under runs/pcb-${TIMESTAMP}/usd2roi-day1, which the
# downstream finetune / anomaly-infer tasks read.
read -r -p "Run TIMESTAMP to use (e.g. 20260619_120000): " TIMESTAMP
[ -n "$TIMESTAMP" ] || { echo "ERROR: TIMESTAMP is required"; return 1 2>/dev/null || exit 1; }
export TIMESTAMP
export INPUT_ASSETS_DIR=/datadrive/dig/datasets/pcb/assets
export OUTPUT_DIR=/datadrive/dig/runs/pcb-${TIMESTAMP}/usd2roi-day1
export COOKBOOKS_DIR=/home/azureuser/dev/paidf-fork/skills/physical-ai-defect-image-generation/assets/cookbooks

# Per-board cookbook + matching real photo. Override BOARD alongside
# REAL_IMAGE_FILENAME when switching boards (e.g. board=1152819000 ships
# input_real_image/1152819000.jpg).
export BOARD=${BOARD:-0603_H100}
export SCENE_FILENAME=${SCENE_FILENAME:-spark_lighting.usd}
export REAL_IMAGE_FILENAME=${REAL_IMAGE_FILENAME:-input_real_image/0603_H100.jpg}

# The container user (UID 1234 = isaac-sim in paidf-simulation) writes to
# OUTPUT_DIR via the bind mount. Pre-create it world-writable so the container
# UID — which differs from the host user — can write without permission errors.
if [ ! -d "$OUTPUT_DIR" ]; then
  mkdir -p "$OUTPUT_DIR" && chmod 777 "$OUTPUT_DIR" \
    || { echo "ERROR: failed to create/chmod $OUTPUT_DIR (try: sudo mkdir -p $OUTPUT_DIR && sudo chmod 777 $OUTPUT_DIR)"; return 1 2>/dev/null || exit 1; }
fi
