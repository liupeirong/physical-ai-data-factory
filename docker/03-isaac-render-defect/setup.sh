# Source this before `docker compose up` to populate the env the compose reads.
#   source setup.sh && docker compose up --abort-on-container-exit
#
# These tasks are run one after another by hand, but the output of a previous
# task is usually the input of the next — as if they belong to one workflow run.
# That shared run is identified by a single TIMESTAMP. The structural-defect
# render is the FIRST task in this flow, so this setup writes a fresh
# OUTPUT_DIR for ${TIMESTAMP}; a downstream augment-image-edit port for the
# structural flow would read this same dir as its INPUT_DIR.

read -r -p "Run TIMESTAMP to use (e.g. 20260619_120000): " TIMESTAMP
[ -n "$TIMESTAMP" ] || { echo "ERROR: TIMESTAMP is required"; return 1 2>/dev/null || exit 1; }
export TIMESTAMP
export INPUT_ASSETS_DIR=/datadrive/dig/datasets/pcb/assets
export OUTPUT_DIR=/datadrive/dig/runs/pcb-structural-${TIMESTAMP}
export COOKBOOKS_DIR=/home/azureuser/dev/paidf-fork/skills/physical-ai-defect-image-generation/assets/cookbooks

# The container user (UID 1234 = isaac-sim in paidf-simulation) writes to
# OUTPUT_DIR via the bind mount. Pre-create it world-writable so the container
# UID — which differs from the host user — can write without permission errors.
if [ ! -d "$OUTPUT_DIR" ]; then
  mkdir -p "$OUTPUT_DIR" && chmod 777 "$OUTPUT_DIR" \
    || { echo "ERROR: failed to create/chmod $OUTPUT_DIR (try: sudo mkdir -p $OUTPUT_DIR && sudo chmod 777 $OUTPUT_DIR)"; return 1 2>/dev/null || exit 1; }
fi

# Per-board cookbook selector (cookbooks/pcb/<BOARD>/{pcba_target,defect_image}.yaml).
export BOARD=0603_H100

# Defect-mode selector — "all" or a comma-separated subset of
# {shift, tombstone, sideflip}. The render config's defects.<mode>.enabled
# flags are patched at task start to match.
export DEFECT_MODES=all

# Stage-1 render cap (number of pose-defect frames). -1 = full scan_grid coverage.
export MAX_IMAGE_COUNT=5

# Stage-2 per-component crop offset (pixels of padding around each component).
export CROP_OFFSET=10
