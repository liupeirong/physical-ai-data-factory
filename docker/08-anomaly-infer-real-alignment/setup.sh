# Source this before `docker compose up` to populate the env the compose reads.
#   source setup.sh && docker compose up --abort-on-container-exit
#
# Real-alignment inference — consumes the per-ROI crops produced by the
# usd2roi-day1 task (docker/07-usd2roi-day1) plus per-defect submask
# templates from datasets/<usecase>/raw. Chains with 07 via a shared
# TIMESTAMP: USD2ROI_DAY1_DIR points at where 07's setup.sh wrote
# (/datadrive/dig/runs/pcb-${TIMESTAMP}/usd2roi-day1).
#
# This spec is PCBA-only by design — the OSMO workflow it ports
# (texture_defect_generation_day1_real_alignment.yaml) is always-on for the
# usd2roi day-1 lane, and only pcb-assets ship a USD tree + input_real_image.
# For glass / metal_surface use 06-anomaly-infer-manual-roi instead.

read -r -p "Run TIMESTAMP to use (e.g. 20260619_120000): " TIMESTAMP
[ -n "$TIMESTAMP" ] || { echo "ERROR: TIMESTAMP is required"; return 1 2>/dev/null || exit 1; }
export TIMESTAMP

export USECASE=pcb

# ── Inputs ───────────────────────────────────────────────────────────────────
# Upstream usd2roi-day1 output (must match 07-usd2roi-day1/setup.sh OUTPUT_DIR).
export USD2ROI_DAY1_DIR=/datadrive/dig/runs/${USECASE}-${TIMESTAMP}/usd2roi-day1
# Per-defect submask templates (clean images come from the usd2roi crops above).
export SUBMASK_BASE_DIR=/datadrive/dig/datasets/${USECASE}/raw
# Shared models tree.
export PRETRAINED_DIR=/datadrive/dig/models/pretrained/pretrained
# Default to the shipped PCBA checkpoint; point at a finetune output to consume
# a freshly-trained run instead (must contain ag_config.yaml + iter_<step>.pt).
export CHECKPOINT_DIR=/datadrive/dig/models/${USECASE}

# Helper scripts (render_defect_spec.py + pick_best_step.sh).
export SCRIPTS_DIR=/home/azureuser/dev/paidf-fork/skills/physical-ai-defect-image-generation/scripts

# ── Output ───────────────────────────────────────────────────────────────────
# anomaly/ subdir of this usecase's run (matches the OSMO outputs.url shape).
export OUTPUT_DIR=/datadrive/dig/runs/${USECASE}-${TIMESTAMP}/anomaly

# The container user writes to OUTPUT_DIR via the bind mount. Pre-create it
# world-writable so the container UID — which differs from the host user —
# can write without permission errors.
if [ ! -d "$OUTPUT_DIR" ]; then
  mkdir -p "$OUTPUT_DIR" && chmod 777 "$OUTPUT_DIR" \
    || { echo "ERROR: failed to create/chmod $OUTPUT_DIR (try: sudo mkdir -p $OUTPUT_DIR && sudo chmod 777 $OUTPUT_DIR)"; return 1 2>/dev/null || exit 1; }
fi

# ── Run identity (was the OSMO `name` knob) ──────────────────────────────────
export EXP_NAME=anomaly-real-${USECASE}-${TIMESTAMP}

# ── Inference knobs (PCBA defaults match the workflow default-values) ────────
# PCBA shipped checkpoint iter.
export CHECKPOINT_STEP=14000
# Multi-material PCBA taxonomy (IC + passive_component). Override per submit.
export ANOMALY_TYPES_JSON='[["passive_component","excess_solder"],["passive_component","missing"]]'
# Total SDG entries across all defects.
export NUM_SDG=30
# free | text | cad. `cad` is the spec default — usd2roi day-1 emits a single
# global semantic_segmentation_labels.json at crop/ root that CADParser
# consumes natively. Fall back to `free` if (a) labels JSON is missing under
# crop/, (b) MI alignment moved cad_mask off the component, or (c) usd2roi was
# re-rendered without colorize_semantic_segmentation.
export DEFAULT_SPATIAL_DEPENDENCY=cad
export MODEL_SIZE=2b

# ── Hugging Face token (was the OSMO hf-token credential) ────────────────────
# Prefer exporting this in your shell rather than committing it here.
export HF_TOKEN=${HF_TOKEN:-}
