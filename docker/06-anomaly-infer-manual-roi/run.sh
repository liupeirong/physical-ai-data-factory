#!/usr/bin/env bash
# Standalone port of the inline run_infer.sh from the OSMO `anomaly-infer`
# task (infer-all-defects) in
#   skills/physical-ai-defect-image-generation/assets/configs/texture_defect_generation_day1_manual_roi.yaml
# OSMO templating is replaced by environment variables supplied by
# docker-compose.yaml:
#   INFERENCE_DATASET   was {{input:0}}  (datasets/<usecase>/raw, ro)
#   PRETRAINED_SRC_IN   was {{input:1}}  (models/pretrained, ro)
#   CKPT_DATASET        was {{input:2}}  (models/<usecase> OR finetune output, ro)
#   OSMO_OUTPUT_ROOT    was {{output}}   (host output dir -> runs/<name>/anomaly)
#   EXP_NAME / ANOMALY_TYPES_JSON / CHECKPOINT_STEP / NUM_SDG /
#   DEFAULT_SPATIAL_DEPENDENCY / MODEL_SIZE — same as the OSMO environment: block
#   HF_TOKEN            was the credentials: hf-token injection
set -euo pipefail

INFERENCE_DATASET="${INFERENCE_DATASET:-/data/inference}"
PRETRAINED_SRC_IN="${PRETRAINED_SRC_IN:-/data/pretrained}"
CKPT_DATASET="${CKPT_DATASET:-/data/checkpoint}"
OSMO_OUTPUT_ROOT="${OSMO_OUTPUT_ROOT:-/data/output}"

EXP_NAME="${EXP_NAME:-anomaly-infer-manual-roi}"
ANOMALY_TYPES_JSON="${ANOMALY_TYPES_JSON:-[[\"passive_component\",\"missing\"]]}"
CHECKPOINT_STEP="${CHECKPOINT_STEP:-14000}"
NUM_SDG="${NUM_SDG:-30}"
DEFAULT_SPATIAL_DEPENDENCY="${DEFAULT_SPATIAL_DEPENDENCY:-cad}"
MODEL_SIZE="${MODEL_SIZE:-2b}"
NUM_GPUS="${NUM_GPUS:-1}"

# Nest SDG output one level under {{output}} so convert_to_daft_format.py's
# default sibling path "<input>_daft_v3" lands inside the writable mount
# instead of unwritable /data.
OUTPUT_DIR="${OSMO_OUTPUT_ROOT}/inference"
mkdir -p "$OUTPUT_DIR"

SCRIPTS=/workspace/paidf-anomalygen/scripts/utilities
ls "$SCRIPTS/prep_testcase.sh" >/dev/null || {
  echo "ERROR: $SCRIPTS/prep_testcase.sh not in image"; exit 1;
}

# Auto-discover nested layouts (NGC-shipped datasets nest under
# <dataset>/<versioned-subdir>/<TEXTURE>/clean_image; user-uploaded
# datasets are usually flat).
resolve_dir () {
  local base="$1" ; shift
  for name in "$@"; do
    local hit
    hit=$(find "$base" -maxdepth 6 -type d -name "$name" | head -1 || true)
    if [ -n "$hit" ]; then echo "$hit"; return 0; fi
  done
  echo "$base"
}
CLEAN_DIR=$(resolve_dir "$INFERENCE_DATASET" clean_image clean_images)
SUBMASK_BASE=$(resolve_dir "$INFERENCE_DATASET" submasks mask masks)
echo "CLEAN_DIR=$CLEAN_DIR"
echo "SUBMASK_BASE=$SUBMASK_BASE"

# Symlink pretrained checkpoints. Per-item replace (preserve any baked items);
# include sam2 + Qwen so text2roi AMP can reach SAM2 + Qwen3-VL via the
# pretrained tree.
cd /workspace/paidf-anomalygen
CKPT_DEST=/workspace/paidf-anomalygen/checkpoints
mkdir -p "$CKPT_DEST"
set +o pipefail
PRETRAINED=$(find "$PRETRAINED_SRC_IN" -maxdepth 4 -type d -name pretrained | head -1)
set -o pipefail
# Allow PRETRAINED_SRC_IN to BE the pretrained dir, not just to contain one.
[ -n "$PRETRAINED" ] || PRETRAINED="$PRETRAINED_SRC_IN"
[ -d "$PRETRAINED" ] || { echo "ERROR: pretrained/ not found under $PRETRAINED_SRC_IN"; exit 1; }
for item in NVDINOV2 nvidia google-t5 facebook C-RADIOv2_B.pth sam2 Qwen; do
  if [ -e "$PRETRAINED/$item" ]; then
    rm -rf "$CKPT_DEST/$item"
    ln -s "$PRETRAINED/$item" "$CKPT_DEST/$item"
  fi
done

# Locate the training config (ag_config.yaml) — shipped checkpoints
# keep it flat with iter_*.pt; freshly-trained outputs nest it under
# results/anomaly_gen/<NAME>/<JOB_NAME>/.
set +o pipefail
AG_CONFIG_PATH=$(find "$CKPT_DATASET" -name "ag_config.yaml" -maxdepth 8 | head -1)
set -o pipefail
[ -n "$AG_CONFIG_PATH" ] || { echo "ERROR: ag_config.yaml not found in checkpoint"; exit 1; }
AG_CONFIG_DIR=$(dirname "$AG_CONFIG_PATH")
echo "Training config: $AG_CONFIG_PATH"

# Wrapper: link model-weights iter_*.pt files into the canonical
# <wrapper>/checkpoints/model/iter_<step>.pt layout.
# Two source layouts:
#   Trainer output:  <JOB_NAME>/checkpoints/{model,optim,scheduler,trainer}/iter_<step>.pt
#                    — only model/ has the actual weights; the others are
#                    optimizer/scheduler/trainer state and must NOT be picked
#                    up (a name-collision overwrite would substitute optimizer
#                    state for model weights and break anomaly_embedding load).
#   Shipped:         flat iter_*.pt next to ag_config.yaml.
WRAPPER=/tmp/ag_ckpt_wrapper
rm -rf "$WRAPPER"
mkdir -p "$WRAPPER/checkpoints/model"
set +o pipefail
PT_FILES=$(find "$CKPT_DATASET" -maxdepth 10 -path "*/checkpoints/model/iter_*.pt")
if [ -z "$PT_FILES" ]; then
  PT_FILES=$(find "$AG_CONFIG_DIR" -maxdepth 1 -name "iter_*.pt")
fi
set -o pipefail
[ -n "$PT_FILES" ] || { echo "ERROR: no model iter_*.pt files found under $CKPT_DATASET"; exit 1; }
echo "$PT_FILES" | while read -r f; do
  ln -sf "$f" "$WRAPPER/checkpoints/model/$(basename "$f")"
done
cp "$AG_CONFIG_PATH" "$WRAPPER/ag_config.yaml"
# Also surface any flat sidecars from the shipped-checkpoint layout
# (e.g. tokenizer files) at $WRAPPER root.
for f in "$AG_CONFIG_DIR"/*; do
  bname=$(basename "$f")
  [ "$bname" = "ag_config.yaml" ] && continue
  case "$bname" in
    iter_*.pt|*.ckpt|*.pt) ;;
    *) [ -e "$WRAPPER/$bname" ] || ln -sf "$f" "$WRAPPER/$bname" ;;
  esac
done
echo "Linked $(ls "$WRAPPER/checkpoints/model" | wc -l) checkpoint files into $WRAPPER"

# Auto-derive the inference step from validation KPIs for freshly-trained
# checkpoints (presence of valid/<STEP>/valid_kpi.csv); falls back to
# CHECKPOINT_STEP for shipped checkpoints. Per anomalygen contract
# (skills/anomalygen/references/finetune.md §"Best checkpoint selection"):
# pick the step with the peak average nn_score, not the final iter.
CHECKPOINT_STEP=$(bash /tmp/pick_best_step.sh "$CKPT_DATASET" "$CHECKPOINT_STEP")
echo "Inference checkpoint step: $CHECKPOINT_STEP"

python3 "$SCRIPTS/validate_checkpoint.py" "$WRAPPER" --step "$CHECKPOINT_STEP"

# Two operating modes for the inference inputs, picked by whether the
# prepared input ships a defect_spec.jsonl:
#
# A) Prepared anomalygen dataset (ships defect_spec.jsonl at root + nested
#    <TEXTURE>/{clean_image,mask,cad_mask}/ + optional
#    semantic_segmentation_labels.json). Used directly as --dataset-dir;
#    prep_testcase.sh auto-discovers clean images.
#
# B) Flat per-defect upload (<defect>/<submask>.png subdirs only).
#    Stage into the canonical layout and render a defect_spec from
#    ANOMALY_TYPES_JSON.
set +o pipefail
USER_SPEC=$(find "$INFERENCE_DATASET" -maxdepth 3 -name "defect_spec.jsonl" | head -1)
set -o pipefail

AMP_OUT=/tmp/amp_output
JSONL=/tmp/inference.jsonl
mkdir -p "$AMP_OUT"

if [ -n "$USER_SPEC" ]; then
  # Mode A: prepared URL artifact. Point prep_testcase at the URL root
  # directly — the canonical anomalygen layout
  # (<TEXTURE>/{clean_image,cad_mask,mask,...} + defect_spec.jsonl +
  # semantic_segmentation_labels.json) is already what prep_testcase expects.
  # Omit --clean-dir: when clean images live at
  # <dataset_dir>/<TEXTURE>/clean_image/, clean_dir defaults to dataset_dir
  # and per-texture lookup works correctly. Forcing --clean-dir to a
  # per-texture path collapses the validator to flat-fallback and mixes
  # clean images across textures.
  DATASET_DIR_ARG=$(dirname "$USER_SPEC")
  DEFECT_SPEC_ARG="$USER_SPEC"
  CLEAN_DIR_ARG=()
  echo "Mode A (prepared dataset): --dataset-dir=$DATASET_DIR_ARG"
  echo "--- defect_spec.jsonl ---"
  cat "$DEFECT_SPEC_ARG"
  echo "--- end defect_spec ---"
else
  # Mode B: stage user-uploaded flat submasks under the canonical anomalygen
  # layout. Walks anomaly_types_json (list of [material, defect] pairs) —
  # supports multi-material taxonomies like the shipped PCBA checkpoint
  # (IC + passive_component).
  STAGE=/tmp/inference_stage
  rm -rf "$STAGE"

  MATERIALS=$(python3 -c '
import json, sys
pairs = json.loads(sys.argv[1])
print("\n".join(sorted({m for m, _ in pairs})))
' "$ANOMALY_TYPES_JSON")
  echo "materials: $(echo "$MATERIALS" | tr "\n" " ")"
  for MAT in $MATERIALS; do
    mkdir -p "$STAGE/$MAT/mask"
  done

  # Submasks: per (material, defect), try <root>/<material>/mask/<defect>/
  # first (canonical anomalygen layout) then <root>/<defect>/ flat
  # (user upload).
  while IFS=$'\t' read -r MAT DEFECT; do
    [ -n "$MAT" ] && [ -n "$DEFECT" ] || continue
    src=""
    for candidate in \
        "$SUBMASK_BASE/$MAT/mask/$DEFECT" \
        "$SUBMASK_BASE/$DEFECT"; do
      [ -d "$candidate" ] && { src="$candidate"; break; }
    done
    [ -n "$src" ] || { echo "ERROR: submask dir not found for $MAT+$DEFECT (tried $SUBMASK_BASE/$MAT/mask/$DEFECT and $SUBMASK_BASE/$DEFECT)"; exit 1; }
    dst="$STAGE/$MAT/mask/$DEFECT"
    mkdir -p "$dst"
    for f in "$src"/*.png "$src"/*.jpg "$src"/*.jpeg; do
      [ -f "$f" ] && ln -sf "$f" "$dst/$(basename "$f")" || true
    done
    count=$(ls "$dst" 2>/dev/null | wc -l)
    echo "submasks/$MAT+$DEFECT: $count files (from $src)"
    [ "$count" -gt 0 ] || { echo "ERROR: no submask files in $src"; exit 1; }
  done < <(python3 -c 'import json,sys
for m,d in json.loads(sys.argv[1]): print(f"{m}\t{d}")' "$ANOMALY_TYPES_JSON")

  python3 /tmp/render_defect_spec.py \
    --output "$STAGE/defect_spec.jsonl" \
    --pairs "$ANOMALY_TYPES_JSON" \
    --spatial-dependency "$DEFAULT_SPATIAL_DEPENDENCY"

  DATASET_DIR_ARG="$STAGE"
  DEFECT_SPEC_ARG="$STAGE/defect_spec.jsonl"
  CLEAN_DIR_ARG=(--clean-dir "$CLEAN_DIR")
  echo "Mode B (staged): --dataset-dir=$STAGE"
  echo "--- defect_spec.jsonl ---"
  cat "$DEFECT_SPEC_ARG"
  echo "--- end defect_spec ---"
fi

# Phase 2: AMP routing + JSONL prep. n_seeds is auto-computed
# from num_sdg / total submasks; do NOT pass --seeds.
echo "=== prep_testcase.sh (num_sdg=$NUM_SDG) ==="
bash "$SCRIPTS/prep_testcase.sh" \
    --name "${EXP_NAME}_infer" \
    --num-sdg "$NUM_SDG" \
    --dataset-dir "$DATASET_DIR_ARG" \
    "${CLEAN_DIR_ARG[@]}" \
    --defect-spec "$DEFECT_SPEC_ARG" \
    --amp-output-dir "$AMP_OUT" \
    --output-jsonl "$JSONL"

# Phase 3: cross-check JSONL anomaly types against checkpoint.
python3 "$SCRIPTS/validate_jsonl.py" "$WRAPPER" "$JSONL"

# Phase 3: SDG. run_sdg.sh picks the right experiment for model_size.
export IMAGINAIRE_OUTPUT_ROOT="${OUTPUT_DIR}/results"
mkdir -p "$IMAGINAIRE_OUTPUT_ROOT"

echo "=== run_sdg.sh (checkpoint_step=$CHECKPOINT_STEP, model_size=$MODEL_SIZE, num_gpus=$NUM_GPUS) ==="
bash "$SCRIPTS/run_sdg.sh" \
    --checkpoint_dir "$WRAPPER" \
    --step "$CHECKPOINT_STEP" \
    --input_jsonl "$JSONL" \
    --output_dir "$OUTPUT_DIR" \
    --model_size "$MODEL_SIZE" \
    --num_gpus "$NUM_GPUS" \
    --seed 0

# Verify SDG output completeness before declaring success.
bash "$SCRIPTS/verify_output.sh" "$JSONL" "$OUTPUT_DIR"
echo "=== Inference complete: $(ls "$OUTPUT_DIR/reconstructed_image/" 2>/dev/null | wc -l) images ==="
