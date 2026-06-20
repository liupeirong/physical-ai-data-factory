read -r -p "Run TIMESTAMP to use (e.g. 20260619_120000): " TIMESTAMP
[ -n "$TIMESTAMP" ] || { echo "ERROR: TIMESTAMP is required"; return 1 2>/dev/null || exit 1; }
export TIMESTAMP
export INPUT_ASSETS_DIR=/datadrive/dig/datasets/pcb/assets
export OUTPUT_DIR=/datadrive/dig/runs/pcb-${TIMESTAMP}
export COOKBOOKS_DIR=/home/azureuser/dev/paidf-fork/skills/physical-ai-defect-image-generation/assets/cookbooks

# The container user (UID 1234 = isaac-sim in paidf-simulation) writes to
# OUTPUT_DIR via the bind mount. Pre-create it world-writable so the container
# UID — which differs from the host user — can write without permission errors.
if [ ! -d "$OUTPUT_DIR" ]; then
  mkdir -p "$OUTPUT_DIR" && chmod 777 "$OUTPUT_DIR" \
    || { echo "ERROR: failed to create/chmod $OUTPUT_DIR (try: sudo mkdir -p $OUTPUT_DIR && sudo chmod 777 $OUTPUT_DIR)"; return 1 2>/dev/null || exit 1; }
fi
