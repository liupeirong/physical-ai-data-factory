# Source this before `docker compose up` to populate the env the compose reads.
#   source setup.sh && docker compose up --abort-on-container-exit
#
# These tasks are run one after another by hand, but the output of a previous
# task is usually the input of the next — as if they belong to one workflow run.
# That shared run is identified by a single TIMESTAMP. Reuse the TIMESTAMP that
# usd2roi-replicator + augment-image-edit (and optionally finetune) wrote under
# so this task reads their outputs.
#
# CLEAN_INPUT_DIR  ← augment-image-edit OUTPUT_DIR (the dir that contains crop/)
# MASK_INPUT_DIR   ← usd2roi-replicator OUTPUT_DIR (the dir that contains crop/)
# OUTPUT_DIR       ← anomaly/ subdir of the same run

read -r -p "Run TIMESTAMP to use (e.g. 20260619_120000): " TIMESTAMP
[ -n "$TIMESTAMP" ] || { echo "ERROR: TIMESTAMP is required"; return 1 2>/dev/null || exit 1; }
export TIMESTAMP

# ── Input trees from earlier tasks ───────────────────────────────────────────
export CLEAN_INPUT_DIR=/datadrive/dig/runs/pcb-${TIMESTAMP}/augment
export MASK_INPUT_DIR=/datadrive/dig/runs/pcb-${TIMESTAMP}

# ── Input trees from the prepared DIG URL layout (setup/setup_pcb.yaml) ──────
export SUBMASK_INPUT_DIR=/datadrive/dig/datasets/pcb/raw
export PRETRAINED_DIR=/datadrive/dig/models/pretrained
# Default: shipped PCBA checkpoint (use_pretrained_checkpoint=true).
# To consume a freshly-trained finetune output instead, point this at
# /datadrive/dig/runs/pcb-${TIMESTAMP}/finetune (or wherever the finetune task
# wrote its results/anomaly_gen/<NAME>/<JOB_NAME>/ tree).
export CHECKPOINT_DIR=/datadrive/dig/models/pcb

# ── Helper scripts (render_defect_spec.py + pick_best_step.sh) ──────────────
export SCRIPTS_DIR=/home/azureuser/dev/paidf-fork/skills/physical-ai-defect-image-generation/scripts

# ── Output dir ──────────────────────────────────────────────────────────────
export OUTPUT_DIR=/datadrive/dig/runs/pcb-${TIMESTAMP}/anomaly

# The container user writes to OUTPUT_DIR via the bind mount. Pre-create it
# world-writable so the container UID — which differs from the host user —
# can write without permission errors.
if [ ! -d "$OUTPUT_DIR" ]; then
  mkdir -p "$OUTPUT_DIR" && chmod 777 "$OUTPUT_DIR" \
    || { echo "ERROR: failed to create/chmod $OUTPUT_DIR (try: sudo mkdir -p $OUTPUT_DIR && sudo chmod 777 $OUTPUT_DIR)"; return 1 2>/dev/null || exit 1; }
fi

# ── Run identity (was the OSMO `name` knob) ─────────────────────────────────
export EXP_NAME=anomaly-${TIMESTAMP}

# ── AnomalyGen inference knobs (defaults from texture_defect_generation_day0.yaml) ──
# Shipped PCBA checkpoint trains on these three (material, defect) pairs.
# Override to retarget the anomaly set.
export ANOMALY_TYPES_JSON='[["IC","bridge"],["passive_component","excess_solder"],["passive_component","missing"]]'
# Step to load (auto-picked from valid KPIs for freshly-trained checkpoints).
export CHECKPOINT_STEP=14000
# Total SDG entries across all defects.
export NUM_SDG=30
# free | text | cad — `cad` uses the cad_masks staged from the usd2roi tree
# and requires semantic_segmentation_labels.json under MASK_INPUT_DIR/crop/.
export DEFAULT_SPATIAL_DEPENDENCY=cad
export MODEL_SIZE=2b

# ── Hugging Face token (was the OSMO hf-token credential) ───────────────────
# Prefer exporting this in your shell rather than committing it here.
export HF_TOKEN=${HF_TOKEN:-}
