#!/usr/bin/env bash
# Standalone port of the inline run_infer.sh from the OSMO `anomaly-infer`
# task (infer-all-defects, use_usd2roi_day1=true branch) in
#   skills/physical-ai-defect-image-generation/assets/configs/texture_defect_generation_day1_real_alignment.yaml
#
# OSMO templating is replaced by environment variables supplied by
# docker-compose.yaml:
#   USD2ROI_IN          was {{input:0}}  (usd2roi-day1 task output, ro)
#   SUBMASK_BASE_IN     was {{input:1}}  (datasets/<usecase>/raw, ro)
#   PRETRAINED_SRC_IN   was {{input:2}}  (models/pretrained, ro)
#   CKPT_DATASET        was {{input:3}}  (models/<usecase> OR finetune output, ro)
#   OSMO_OUTPUT_ROOT    was {{output}}   (host output dir -> runs/<name>/anomaly)
#   EXP_NAME / ANOMALY_TYPES_JSON / CHECKPOINT_STEP / NUM_SDG /
#   DEFAULT_SPATIAL_DEPENDENCY / MODEL_SIZE — same as the OSMO environment: block
#   HF_TOKEN            was the credentials: hf-token injection
set -euo pipefail

USD2ROI_IN="${USD2ROI_IN:-/data/usd2roi}"
SUBMASK_BASE_IN="${SUBMASK_BASE_IN:-/data/submasks}"
PRETRAINED_SRC_IN="${PRETRAINED_SRC_IN:-/data/pretrained}"
CKPT_DATASET="${CKPT_DATASET:-/data/checkpoint}"
OSMO_OUTPUT_ROOT="${OSMO_OUTPUT_ROOT:-/data/output}"

EXP_NAME="${EXP_NAME:-anomaly-infer-real-alignment}"
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

# ─── Real-alignment staging — usd2roi day-1 output → canonical inference dataset ──
# usd2roi partitions ROIs by material via crop.class_dirs
# (crop/<MATERIAL>/{normal_img,cad_mask}/<NNNN>.png). Stage per material
# directly from disk — do NOT fan out from ANOMALY_TYPES_JSON, that would
# cross-pollinate IC vs passive_component crops.
REAL_ALIGN_STAGE=/tmp/usd2roi_day1_stage
rm -rf "$REAL_ALIGN_STAGE"

DISK_MATS=$(find "$USD2ROI_IN/crop" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
[ -n "$DISK_MATS" ] || { echo "ERROR: no material dirs under $USD2ROI_IN/crop/"; exit 1; }
echo "usd2roi-disk materials: $(echo "$DISK_MATS" | tr '\n' ' ')"

ATM_MATS=$(python3 -c '
import json, sys
pairs = json.loads(sys.argv[1])
print("\n".join(sorted({m for m, _ in pairs})))
' "$ANOMALY_TYPES_JSON")
echo "anomaly_types_json materials: $(echo "$ATM_MATS" | tr '\n' ' ')"

for MAT in $DISK_MATS; do
  mkdir -p "$REAL_ALIGN_STAGE/$MAT/clean_image" "$REAL_ALIGN_STAGE/$MAT/cad_mask" "$REAL_ALIGN_STAGE/$MAT/mask"
done

# Per-ROI mask candidate; usd2roi day-1 ships cad_mask/<NNNN>_cad_mask.png
# next to normal_img/ inside each material dir.
mask_candidate_for () {
  local clean_path="$1"
  local roi_dir
  roi_dir=$(dirname "$(dirname "$clean_path")")
  local stem
  stem=$(basename "${clean_path%.*}")
  for cand in \
      "$roi_dir/cad_mask/${stem}_cad_mask.png" \
      "$roi_dir/cad_mask/${stem}.png" \
      "$roi_dir/seg/${stem}.png" \
      "$roi_dir/ov_seg/${stem}.png" \
      "$roi_dir/semantic_segmentation/${stem}.png"; do
    [ -f "$cand" ] && { echo "$cand"; return 0; }
  done
  echo ""
}

STAGED=0
for MAT in $DISK_MATS; do
  for clean in "$USD2ROI_IN/crop/$MAT/normal_img"/*.png "$USD2ROI_IN/crop/$MAT/normal_img"/*.jpg; do
    [ -f "$clean" ] || continue
    STEM=$(basename "${clean%.*}")
    EXT="${clean##*.}"
    MASK=$(mask_candidate_for "$clean")
    ln -sf "$clean" "$REAL_ALIGN_STAGE/$MAT/clean_image/${STEM}.${EXT}"
    [ -n "$MASK" ] && ln -sf "$MASK" "$REAL_ALIGN_STAGE/$MAT/cad_mask/${STEM}.png" || true
    STAGED=$((STAGED + 1))
  done
done
echo "Real-alignment staged $STAGED ROI crops across $(echo "$DISK_MATS" | wc -w) material(s)"
[ "$STAGED" -gt 0 ] || { echo "ERROR: no ROI crops staged"; exit 1; }

for ATM in $ATM_MATS; do
  echo "$DISK_MATS" | grep -qx "$ATM" || \
    echo "WARN: anomaly_types_json material '$ATM' missing from $USD2ROI_IN/crop/"
done

# Submask resolution mirrors the manual-ROI staged-upload path (per-material first, flat fallback).
# Submask root resolution: look specifically for <root>/<mat>/mask/<defect>
# patterns at EXACT depth 3. Finding bare "mask/" at depth 3 doesn't mean
# we're at the right root — manually uploaded content can preserve a
# top-level wrapper dir, so <mat>/mask/<defect> may sit one level deeper.
resolve_submask_root () {
  local base="$1"
  if find "$base" -mindepth 3 -maxdepth 3 -type d -path "*/mask/*" 2>/dev/null | head -1 | grep -q .; then
    echo "$base"; return 0
  fi
  local nested
  nested=$(find "$base" -mindepth 1 -maxdepth 1 -type d | head -1 || true)
  if [ -n "$nested" ] && find "$nested" -mindepth 3 -maxdepth 3 -type d -path "*/mask/*" 2>/dev/null | head -1 | grep -q .; then
    echo "$nested"; return 0
  fi
  echo "$base"
}
SUBMASK_ROOT=$(resolve_submask_root "$SUBMASK_BASE_IN")
echo "SUBMASK_ROOT=$SUBMASK_ROOT"
while IFS=$'\t' read -r MAT DEFECT; do
  [ -n "$MAT" ] && [ -n "$DEFECT" ] || continue
  src=""
  for candidate in \
      "$SUBMASK_ROOT/$MAT/mask/$DEFECT" \
      "$SUBMASK_ROOT/$DEFECT"; do
    [ -d "$candidate" ] && { src="$candidate"; break; }
  done
  [ -n "$src" ] || { echo "ERROR: submask dir not found for $MAT+$DEFECT (tried $SUBMASK_ROOT/$MAT/mask/$DEFECT and $SUBMASK_ROOT/$DEFECT)"; exit 1; }
  dst="$REAL_ALIGN_STAGE/$MAT/mask/$DEFECT"
  mkdir -p "$dst"
  for f in "$src"/*.png "$src"/*.jpg "$src"/*.jpeg; do
    [ -f "$f" ] && ln -sf "$f" "$dst/$(basename "$f")" || true
  done
  count=$(ls "$dst" 2>/dev/null | wc -l)
  echo "Real-alignment submasks/$MAT+$DEFECT: $count files (from $src)"
  [ "$count" -gt 0 ] || { echo "ERROR: no submask files in $src"; exit 1; }
done < <(python3 -c 'import json,sys
for m,d in json.loads(sys.argv[1]): print(f"{m}\t{d}")' "$ANOMALY_TYPES_JSON")

# Render defect_spec.jsonl. Switch to `cad` only when usd2roi was rendered with
# colorize_semantic_segmentation (cad_mask pixel values map to class IDs) AND
# semantic_segmentation_labels.json exists; otherwise `free` is the safe choice.
python3 /tmp/render_defect_spec.py \
    --output "$REAL_ALIGN_STAGE/defect_spec.jsonl" \
    --pairs "$ANOMALY_TYPES_JSON" \
    --spatial-dependency "$DEFAULT_SPATIAL_DEPENDENCY"
echo "--- defect_spec.jsonl ---"
cat "$REAL_ALIGN_STAGE/defect_spec.jsonl"
echo "--- end defect_spec ---"

if [ "$DEFAULT_SPATIAL_DEPENDENCY" = "cad" ]; then
  set +o pipefail
  SEG_LABELS=$(find "$USD2ROI_IN" -maxdepth 5 -name "semantic_segmentation_labels.json" | head -1)
  set -o pipefail
  if [ -n "$SEG_LABELS" ]; then
    cp "$SEG_LABELS" "$REAL_ALIGN_STAGE/semantic_segmentation_labels.json"
    echo "Staged semantic_segmentation_labels.json from $SEG_LABELS"
  else
    echo "WARN: spatial_dependency=cad but no semantic_segmentation_labels.json found under $USD2ROI_IN — prep_testcase.sh may fail. Switch to DEFAULT_SPATIAL_DEPENDENCY=free."
  fi
fi

# Point downstream logic at the synthesized dataset. The existing prepared-dataset
# branch will detect defect_spec.jsonl at root and proceed unchanged.
INFERENCE_DATASET="$REAL_ALIGN_STAGE"
echo "Real-alignment: INFERENCE_DATASET=$INFERENCE_DATASET"

# Auto-discover nested layouts (NGC-shipped datasets nest under
# <dataset>/<versioned-subdir>/<TEXTURE>/clean_image; user-uploaded
# datasets are usually flat). On the staged dataset both names resolve trivially.
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

# The staged dataset always ships defect_spec.jsonl at root, so the prepared-dataset
# branch (Mode A) always runs here. Mode B (staged-upload fallback) is kept for
# parity with 06-anomaly-infer-manual-roi but is dead-code in this port —
# REAL_ALIGN_STAGE/defect_spec.jsonl is unconditionally written above.
set +o pipefail
USER_SPEC=$(find "$INFERENCE_DATASET" -maxdepth 3 -name "defect_spec.jsonl" | head -1)
set -o pipefail
[ -n "$USER_SPEC" ] || { echo "ERROR: REAL_ALIGN_STAGE/defect_spec.jsonl missing"; exit 1; }

AMP_OUT=/tmp/amp_output
JSONL=/tmp/inference.jsonl
mkdir -p "$AMP_OUT"

# Mode A: prepared dataset. Point prep_testcase at the dataset root directly —
# the canonical anomalygen layout (<TEXTURE>/{clean_image,cad_mask,mask,...} +
# defect_spec.jsonl + semantic_segmentation_labels.json) is what prep_testcase
# expects. Omit --clean-dir: when clean images live at
# <dataset_dir>/<TEXTURE>/clean_image/, clean_dir defaults to dataset_dir and
# per-texture lookup works correctly. Forcing --clean-dir to a per-texture path
# collapses the validator to flat-fallback and mixes clean images across textures.
DATASET_DIR_ARG=$(dirname "$USER_SPEC")
DEFECT_SPEC_ARG="$USER_SPEC"
CLEAN_DIR_ARG=()
echo "Prepared dataset: --dataset-dir=$DATASET_DIR_ARG"

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
