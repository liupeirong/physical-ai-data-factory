#!/usr/bin/env bash
# Standalone port of the inline finetune.sh from the OSMO `finetune-job /
# finetune` task in
#   skills/physical-ai-defect-image-generation/assets/configs/finetune.yaml
# OSMO templating is replaced by environment variables supplied by
# docker-compose.yaml:
#   PRETRAINED_SRC    was "{{input:0}}/pretrained"     (models/pretrained, ro)
#   DATASET_DIR       was "{{input:1}}"                (datasets/<usecase>/raw, ro)
#   OSMO_OUTPUT_ROOT  was {{output}}                   (host output dir -> runs/<name>/finetune)
#   EXP_NAME / USECASE / NUM_GPUS — same as the OSMO environment: block
#   HF_TOKEN          was the credentials: hf-token injection
#
# The per-usecase cookbook template is mounted at /tmp/ag_config_template.yaml
# by the compose file (was the OSMO `files: localpath` mount).
set -euo pipefail

PRETRAINED_SRC="${PRETRAINED_SRC:-/data/pretrained}"
DATASET_DIR="${DATASET_DIR:-/data/dataset}"
OSMO_OUTPUT_ROOT="${OSMO_OUTPUT_ROOT:-/data/output}"

EXP_NAME="${EXP_NAME:-finetune}"
USECASE="${USECASE:-pcb}"
NUM_GPUS="${NUM_GPUS:-1}"

OUTPUT_DIR="$OSMO_OUTPUT_ROOT"
mkdir -p "$OUTPUT_DIR"

# ── Pod-template preflight (training task) ─────────────────────
DSHM_GB=$(df -B1G /dev/shm | tail -1 | awk '{print $2}')
if [ "$DSHM_GB" -lt 16 ]; then
  echo "ERROR: /dev/shm is ${DSHM_GB}GiB; need >= 16 GiB (32 preferred) for torchrun shared-memory."
  exit 1
fi
# ───────────────────────────────────────────────────────────────

# Install Mike Farah yq into /tmp (image /usr/local/bin is non-writable;
# paidf-anomalygen ships wget, no curl).
[ -x /tmp/yq ] || {
  wget -q https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64 -O /tmp/yq
  chmod +x /tmp/yq
}
export PATH=/tmp:$PATH

TEMPLATE=/tmp/ag_config_template.yaml
[ -f "$TEMPLATE" ] || {
  echo "ERROR: $TEMPLATE not mounted — cookbook upload failed."
  echo "  Confirm assets/cookbooks/${USECASE}/ag_config.yaml exists and is mounted by docker-compose.yaml."
  exit 1
}

[ -d "$PRETRAINED_SRC" ] || {
  echo "ERROR: pretrained tree not at $PRETRAINED_SRC"
  ls -la "$(dirname "$PRETRAINED_SRC")" || true
  exit 1
}

# Per-item symlink-replace into the container's checkpoint dir.
# IMPORTANT: do NOT wipe the dir — SAM2 + Qwen3-VL ship baked
# there and are referenced by other tools in the image even
# though this task only runs torchrun.
cd /workspace/paidf-anomalygen
CONTAINER_CKPT_DIR=/workspace/paidf-anomalygen/checkpoints
mkdir -p "$CONTAINER_CKPT_DIR"
for item in NVDINOV2 nvidia google-t5 facebook C-RADIOv2_B.pth sam2 Qwen; do
  if [ -e "$PRETRAINED_SRC/$item" ]; then
    rm -rf "$CONTAINER_CKPT_DIR/$item"
    ln -s "$PRETRAINED_SRC/$item" "$CONTAINER_CKPT_DIR/$item"
  fi
done

[ -d "$DATASET_DIR" ] || {
  echo "ERROR: training dataset not at $DATASET_DIR"
  exit 1
}

DEFECT_SPEC="$DATASET_DIR/defect_spec.jsonl"
[ -f "$DEFECT_SPEC" ] || {
  echo "ERROR: $DEFECT_SPEC missing in raw dataset."
  echo "  Re-run setup/setup_${USECASE}.yaml (or setup/setup_metal.yaml for metal_surface) for datasets/${USECASE}/raw."
  exit 1
}

# anomalygen helper scripts (pinned by image digest).
SCRIPTS=/workspace/paidf-anomalygen/scripts/utilities
ls "$SCRIPTS/prep_testcase.sh" >/dev/null || {
  echo "ERROR: $SCRIPTS/prep_testcase.sh not in image — check digest."
  exit 1
}

# ─── Phase 1 Step 1: validate dataset structure ────────────
echo "=== Phase 1 Step 1: validate_dataset.py ==="
python3 "$SCRIPTS/validate_dataset.py" "$DATASET_DIR"

NUM_SDG=$(find "$DATASET_DIR" -type f -path "*/mask/*/*" \
  \( -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" \) | wc -l)
[ "$NUM_SDG" -gt 0 ] || { echo "ERROR: no training masks under $DATASET_DIR/*/mask/"; exit 1; }
echo "Total training mask count (num_sdg): $NUM_SDG"

# ─── Phase 1 Step 2: AMP placement → validation.jsonl ──────
# n_seeds=1: each training mask AMP-placed onto a clean image
# exactly once. Writes mask PNGs to amp/ + a manifest jsonl
# whose paths are absolute (no sentinel rewrite needed — the
# paths inside refer to this same pod's filesystem).
VAL_DIR=/tmp/validation
rm -rf "$VAL_DIR"
mkdir -p "$VAL_DIR/amp"
VAL_JSONL="$VAL_DIR/validation.jsonl"

echo "=== Phase 1 Step 2: prep_testcase.sh (validation_${EXP_NAME}) ==="
bash "$SCRIPTS/prep_testcase.sh" \
    --name "validation_${EXP_NAME}" \
    --num-sdg "$NUM_SDG" \
    --dataset-dir "$DATASET_DIR" \
    --defect-spec "$DEFECT_SPEC" \
    --amp-output-dir "$VAL_DIR/amp" \
    --output-jsonl "$VAL_JSONL"

[ -s "$VAL_JSONL" ] || {
  echo "ERROR: prep_testcase.sh produced an empty validation.jsonl"
  exit 1
}
echo "validation.jsonl: $(wc -l < "$VAL_JSONL") rows"
echo "validation amp/:  $(find "$VAL_DIR/amp" -type f | wc -l) files"

# ── Render per-run training config from cookbook template ─────
# VAL_JSONL is in scope here (Phase 1 Step 2 just produced it).
CONFIG_FILE=/tmp/ag_config.yaml
NAME="$EXP_NAME" \
JOB_NAME="${EXP_NAME}_training_FP32_lr0.02_bs=2_2b_512x512" \
DATASET_DIR="$DATASET_DIR" \
VAL_JSONL="$VAL_JSONL" \
NVDINOV2_CKPT="checkpoints/NVDINOV2/nv_dinov2_classification_model.ckpt" \
  yq '
    .job.group = strenv(NAME) |
    .job.name  = strenv(JOB_NAME) |
    .dataloader_train.dataset.dataset_dir = strenv(DATASET_DIR) |
    .dataloader_val.dataset.input_data_path = strenv(VAL_JSONL) |
    .model.config.ag_config.mask_encoder.encoder_config.init_cfg.checkpoint = strenv(NVDINOV2_CKPT) |
    del(.trainer.early_stop)
  ' "$TEMPLATE" > "$CONFIG_FILE"
echo "Rendered $CONFIG_FILE from $TEMPLATE (NAME=$EXP_NAME)"

# Cookbook hygiene — runs after yq render so per-run overrides are seen.
# save_iter > max_iter is fatal (no checkpoint ever written).
# validation_iter > max_iter degrades pick_best_step.sh to latest-iter
# (still warn-only because "just train and pick latest" is legitimate).
# save_iter == max_iter is the shipped pattern — trainer saves at iter
# == max_iter, so don't warn on that case.
MAX_ITER=$(yq        '.trainer.max_iter        // 0' "$CONFIG_FILE")
SAVE_ITER=$(yq       '.checkpoint.save_iter    // 0' "$CONFIG_FILE")
VALIDATION_ITER=$(yq '.trainer.validation_iter // 0' "$CONFIG_FILE")
LOGGING_ITER=$(yq    '.trainer.logging_iter    // 0' "$CONFIG_FILE")

if [ "$SAVE_ITER" -gt 0 ] && [ "$MAX_ITER" -gt 0 ] && [ "$SAVE_ITER" -gt "$MAX_ITER" ]; then
  echo "ERROR: cookbook save_iter=$SAVE_ITER > max_iter=$MAX_ITER — no checkpoint will be saved." >&2
  echo "  Fix assets/cookbooks/${USECASE}/ag_config.yaml: set save_iter <= max_iter." >&2
  exit 1
fi

if [ "$VALIDATION_ITER" -gt 0 ] && [ "$MAX_ITER" -gt 0 ] && [ "$VALIDATION_ITER" -gt "$MAX_ITER" ]; then
  echo "WARN: cookbook validation_iter=$VALIDATION_ITER > max_iter=$MAX_ITER — no validation logs; pick_best_step.sh will fall back to latest trained iter (not best-by-nn_score)." >&2
fi

if [ "$LOGGING_ITER" -gt 0 ] && [ "$MAX_ITER" -gt 0 ] && [ "$LOGGING_ITER" -gt "$MAX_ITER" ]; then
  echo "WARN: cookbook logging_iter=$LOGGING_ITER > max_iter=$MAX_ITER — no progress logs will be emitted." >&2
fi

# Stage rendered config alongside the trainer code.
mkdir -p ag_configs
cp "$CONFIG_FILE" "ag_configs/${EXP_NAME}.yaml"

EXP="predict2_anomaly_gen_ddp_2b"
export IMAGINAIRE_OUTPUT_ROOT="${OUTPUT_DIR}/results"
mkdir -p "$IMAGINAIRE_OUTPUT_ROOT"
echo "=== torchrun ($EXP_NAME, $NUM_GPUS GPUs, experiment=$EXP) ==="
torchrun --nproc_per_node="$NUM_GPUS" --master_port=12341 \
  -m scripts.anomaly_gen.ag_train \
  --config=cosmos_predict2/configs/base/ag_config.py \
  --ag_config="ag_configs/${EXP_NAME}.yaml" \
  -- experiment="$EXP"
echo "=== Training complete ==="
