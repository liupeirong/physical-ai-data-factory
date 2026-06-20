# Source this before `docker compose up` to populate the env the compose reads.
#   source setup.sh && docker compose up --abort-on-container-exit
#
# These tasks are run one after another by hand, but the output of a previous
# task is usually the input of the next — as if they belong to one workflow run.
# That shared run is identified by a single TIMESTAMP. Reuse the same TIMESTAMP
# the usd2roi-replicator task wrote under, so this task reads its output.
#
# INPUT_DIR points at the usd2roi-replicator output tree (the dir that directly
# contains crop/<MATERIAL>/<cell>/normal_img/); OUTPUT_DIR is the augment subdir
# of the same run.
read -r -p "Run TIMESTAMP to use (e.g. 20260619_120000): " TIMESTAMP
[ -n "$TIMESTAMP" ] || { echo "ERROR: TIMESTAMP is required"; return 1 2>/dev/null || exit 1; }
export TIMESTAMP
export INPUT_DIR=/datadrive/dig/runs/pcb-${TIMESTAMP}
export OUTPUT_DIR=/datadrive/dig/runs/pcb-${TIMESTAMP}/augment
export COOKBOOKS_DIR=/home/azureuser/dev/paidf-fork/skills/physical-ai-defect-image-generation/assets/cookbooks

# The container user writes to OUTPUT_DIR via the bind mount. Pre-create it
# world-writable so the container UID — which differs from the host user —
# can write without permission errors.
if [ ! -d "$OUTPUT_DIR" ]; then
  mkdir -p "$OUTPUT_DIR" && chmod 777 "$OUTPUT_DIR" \
    || { echo "ERROR: failed to create/chmod $OUTPUT_DIR (try: sudo mkdir -p $OUTPUT_DIR && sudo chmod 777 $OUTPUT_DIR)"; return 1 2>/dev/null || exit 1; }
fi

# Remote Qwen Image-Edit (OVSL2SL) endpoint + model. Point at a reachable
# endpoint (see references/nim/README.md to stand one up locally).
export IMAGE_EDIT_ENDPOINT=http://localhost:8000/v1
export IMAGE_EDIT_MODEL=nvidia/Qwen-Image-Edit-NVPCB-OVSL2SL

# Hugging Face token for the Qwen weights (was the OSMO hf-token credential).
# Prefer exporting this in your shell rather than committing it here.
export HF_TOKEN=${HF_TOKEN:-}
