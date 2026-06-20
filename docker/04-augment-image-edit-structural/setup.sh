# Source this before `docker compose up` to populate the env the compose reads.
#   source setup.sh && docker compose up --abort-on-container-exit
#
# Structural-defect variant of the augment-image-edit port. Reads the structural
# render+crop bundle written by the upstream `isaac-render-defect` docker task
# (cropped/<mode>/rgb/<NNNN>.png) and writes Qwen OVSL2SL-restyled RGBs into a
# `structural_defect_edited/` sibling of the same run.
#
# docker-compose.yaml for this folder is INTENTIONALLY ABSENT — it is
# byte-identical to docker/augment-image-edit/docker-compose.yaml. Symlink or
# copy it in before running:
#
#   ln -s ../augment-image-edit/docker-compose.yaml docker-compose.yaml
#   # or: cp ../augment-image-edit/docker-compose.yaml .
#
# Only the differing pieces live here:
#   setup.sh              — INPUT_DIR/OUTPUT_DIR for the structural flow
#   run.sh                — preflight + sanity checks for the cropped/<mode>/rgb/ layout
#   build_batch_config.py — walks cropped/<mode>/rgb/, emits <output>/<mode>/rgb/

read -r -p "Run TIMESTAMP to use (e.g. 20260619_120000): " TIMESTAMP
[ -n "$TIMESTAMP" ] || { echo "ERROR: TIMESTAMP is required"; return 1 2>/dev/null || exit 1; }
export TIMESTAMP
# INPUT_DIR is the upstream isaac-render-defect OUTPUT_DIR for this TIMESTAMP
# (it contains cropped/<mode>/rgb/<NNNN>.png plus trigger_NNNN/ and the
# resolved render_config.yaml / pcba_target.yaml snapshots).
export INPUT_DIR=/datadrive/dig/runs/pcb-structural-${TIMESTAMP}
export OUTPUT_DIR=/datadrive/dig/runs/pcb-structural-${TIMESTAMP}/structural_defect_edited
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
