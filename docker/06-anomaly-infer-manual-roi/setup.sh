# Source this before `docker compose up` to populate the env the compose reads.
#   source setup.sh && docker compose up --abort-on-container-exit
#
# Manual-ROI inference — runs against a pre-prepared inference dataset
# (no usd2roi/augment chain feeding it). Pick ONE usecase block below and
# uncomment it. The default block is `glass`.
#
# TIMESTAMP identifies the run output dir under runs/<usecase>-${TIMESTAMP}/.
# Reuse the TIMESTAMP of an earlier finetune run if you want to consume its
# checkpoint instead of the shipped one.

read -r -p "Run TIMESTAMP to use (e.g. 20260619_120000): " TIMESTAMP
[ -n "$TIMESTAMP" ] || { echo "ERROR: TIMESTAMP is required"; return 1 2>/dev/null || exit 1; }
export TIMESTAMP

# ── Pick ONE usecase block ──────────────────────────────────────────────────

# ── glass ───────────────────────────────────────────────────────────────────
export USECASE=glass
export INFERENCE_DATASET_DIR=/datadrive/dig/datasets/glass/raw
export CHECKPOINT_DIR=/datadrive/dig/models/glass
export ANOMALY_TYPES_JSON='[["Phone","oil"],["Phone","scratch"],["Phone","stain"]]'
export CHECKPOINT_STEP=9000

# ── metal_surface ───────────────────────────────────────────────────────────
# export USECASE=metal_surface
# export INFERENCE_DATASET_DIR=/datadrive/dig/datasets/metal_surface/raw
# export CHECKPOINT_DIR=/datadrive/dig/models/metal_surface
# export ANOMALY_TYPES_JSON='[["metal_surface","MT_Blowhole"],["metal_surface","MT_Break"],["metal_surface","MT_Crack"],["metal_surface","MT_Fray"],["metal_surface","MT_Uneven"]]'
# export CHECKPOINT_STEP=10000

# ── pcb (manual ROI — skips usd2roi/augment chain) ──────────────────────────
# export USECASE=pcb
# export INFERENCE_DATASET_DIR=/datadrive/dig/datasets/pcb/raw
# export CHECKPOINT_DIR=/datadrive/dig/models/pcb
# export ANOMALY_TYPES_JSON='[["IC","bridge"],["passive_component","excess_solder"],["passive_component","missing"]]'
# export CHECKPOINT_STEP=14000

# ── Shared paths (apply to every usecase) ───────────────────────────────────
export PRETRAINED_DIR=/datadrive/dig/models/pretrained/pretrained

# Helper scripts (render_defect_spec.py + pick_best_step.sh)
export SCRIPTS_DIR=/home/azureuser/dev/paidf-fork/skills/physical-ai-defect-image-generation/scripts

# Output dir — anomaly/ subdir of this usecase's run.
export OUTPUT_DIR=/datadrive/dig/runs/${USECASE}-${TIMESTAMP}/anomaly

# The container user writes to OUTPUT_DIR via the bind mount. Pre-create it
# world-writable so the container UID — which differs from the host user —
# can write without permission errors.
if [ ! -d "$OUTPUT_DIR" ]; then
  mkdir -p "$OUTPUT_DIR" && chmod 777 "$OUTPUT_DIR" \
    || { echo "ERROR: failed to create/chmod $OUTPUT_DIR (try: sudo mkdir -p $OUTPUT_DIR && sudo chmod 777 $OUTPUT_DIR)"; return 1 2>/dev/null || exit 1; }
fi

# ── Run identity (was the OSMO `name` knob) ─────────────────────────────────
export EXP_NAME=anomaly-${USECASE}-${TIMESTAMP}

# ── Shared inference knobs ──────────────────────────────────────────────────
# Total SDG entries across all defects.
export NUM_SDG=30
# free | text | cad — Mode B fallback only (Mode A uses the shipped defect_spec
# and ignores this knob). For glass/metal manual uploads keep `cad` only if
# you also supply per-MATERIAL cad_mask/ + semantic_segmentation_labels.json;
# otherwise switch to `free`.
export DEFAULT_SPATIAL_DEPENDENCY=cad
export MODEL_SIZE=2b

# ── Hugging Face token (was the OSMO hf-token credential) ───────────────────
# Prefer exporting this in your shell rather than committing it here.
export HF_TOKEN=${HF_TOKEN:-}
