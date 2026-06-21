# Source this before `docker compose up` to populate the env the compose reads.
#   source setup.sh && docker compose up --abort-on-container-exit
#
# These tasks are run one after another by hand, but the output of a previous
# task is usually the input of the next — as if they belong to one workflow run.
# That shared run is identified by a single TIMESTAMP. Reuse the TIMESTAMP that
# the rest of your run (usd2roi-replicator / augment-image-edit / anomaly-infer)
# uses so the produced checkpoint lands at a predictable path.
#
# This task is the standalone finetune lane: it consumes the canonical
# `datasets/<usecase>/raw` tree + `models/pretrained` tree and writes a trained
# checkpoint under runs/<usecase>-${TIMESTAMP}/finetune, which the downstream
# anomaly-infer tasks can read by pointing their CHECKPOINT_DIR at it.

read -r -p "Run TIMESTAMP to use (e.g. 20260619_120000): " TIMESTAMP
[ -n "$TIMESTAMP" ] || { echo "ERROR: TIMESTAMP is required"; return 1 2>/dev/null || exit 1; }
export TIMESTAMP

# ── Usecase selects the cookbook + the dataset/output paths ──────────────────
# pcb | glass | metal_surface — must match the cookbook dir under
# assets/cookbooks/<usecase>/ag_config.yaml.
export USECASE=${USECASE:-pcb}

# ── Input trees from the prepared DIG URL layout (setup/setup_<case>.yaml) ──
export PRETRAINED_DIR=/datadrive/dig/models/pretrained/pretrained
export DATASET_DIR=/datadrive/dig/datasets/${USECASE}/raw

# ── Cookbook template (rendered in-pod by yq) ───────────────────────────────
export COOKBOOKS_DIR=/home/azureuser/dev/paidf-fork/skills/physical-ai-defect-image-generation/assets/cookbooks

# ── Output dir ──────────────────────────────────────────────────────────────
export OUTPUT_DIR=/datadrive/dig/runs/${USECASE}-${TIMESTAMP}/finetune

# The container user writes to OUTPUT_DIR via the bind mount. Pre-create it
# world-writable so the container UID — which differs from the host user —
# can write without permission errors.
if [ ! -d "$OUTPUT_DIR" ]; then
  mkdir -p "$OUTPUT_DIR" && chmod 777 "$OUTPUT_DIR" \
    || { echo "ERROR: failed to create/chmod $OUTPUT_DIR (try: sudo mkdir -p $OUTPUT_DIR && sudo chmod 777 $OUTPUT_DIR)"; return 1 2>/dev/null || exit 1; }
fi

# ── Run identity (was the OSMO `name` knob) ─────────────────────────────────
export EXP_NAME=finetune-${TIMESTAMP}

# ── Torchrun knobs ──────────────────────────────────────────────────────────
# Number of GPUs visible to the container; must match the deploy.reservations
# block in docker-compose.yaml (override there as well when scaling).
export NUM_GPUS=${NUM_GPUS:-1}

# ── Hugging Face token (was the OSMO hf-token credential) ───────────────────
# Prefer exporting this in your shell rather than committing it here.
export HF_TOKEN=${HF_TOKEN:-}
