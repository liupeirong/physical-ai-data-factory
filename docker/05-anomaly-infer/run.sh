#!/usr/bin/env bash
# Standalone port of the inline run_infer.sh from the OSMO `anomaly-infer`
# task (infer-all-defects) in
#   skills/physical-ai-defect-image-generation/assets/configs/texture_defect_generation_day0.yaml
# OSMO templating is replaced by environment variables supplied by
# docker-compose.yaml:
#   CLEAN_IN          was {{input:0}}  (augment-image-edit output, ro)
#   MASK_IN           was {{input:1}}  (usd2roi-replicator output, ro)
#   SUBMASK_BASE_IN   was {{input:2}}  (datasets/pcb/raw, ro)
#   PRETRAINED_SRC_IN was {{input:3}}  (models/pretrained, ro)
#   CKPT_DATASET      was {{input:4}}  (models/pcb OR finetune output, ro)
#   OSMO_OUTPUT_ROOT  was {{output}}   (host output dir -> runs/<name>/anomaly)
#   EXP_NAME / ANOMALY_TYPES_JSON / CHECKPOINT_STEP / NUM_SDG /
#   DEFAULT_SPATIAL_DEPENDENCY / MODEL_SIZE — same as the OSMO environment: block
#   HF_TOKEN          was the credentials: hf-token injection
set -euo pipefail

CLEAN_IN="${CLEAN_IN:-/data/clean}"
MASK_IN="${MASK_IN:-/data/mask}"
SUBMASK_BASE_IN="${SUBMASK_BASE_IN:-/data/submask}"
PRETRAINED_SRC_IN="${PRETRAINED_SRC_IN:-/data/pretrained}"
CKPT_DATASET="${CKPT_DATASET:-/data/checkpoint}"
OSMO_OUTPUT_ROOT="${OSMO_OUTPUT_ROOT:-/data/output}"

EXP_NAME="${EXP_NAME:-anomaly-infer}"
ANOMALY_TYPES_JSON="${ANOMALY_TYPES_JSON:-[[\"IC\",\"bridge\"],[\"passive_component\",\"excess_solder\"],[\"passive_component\",\"missing\"]]}"
CHECKPOINT_STEP="${CHECKPOINT_STEP:-14000}"
NUM_SDG="${NUM_SDG:-30}"
DEFAULT_SPATIAL_DEPENDENCY="${DEFAULT_SPATIAL_DEPENDENCY:-cad}"
MODEL_SIZE="${MODEL_SIZE:-2b}"

# Nest SDG output one level under {{output}} so convert_to_daft_format.py's
# default sibling path "<input>_daft_v3" lands inside the writable mount
# instead of unwritable /data.
OUTPUT_DIR="${OSMO_OUTPUT_ROOT}/inference"
mkdir -p "$OUTPUT_DIR"

SCRIPTS=/workspace/paidf-anomalygen/scripts/utilities
ls "$SCRIPTS/prep_testcase.sh" >/dev/null || {
  echo "ERROR: $SCRIPTS/prep_testcase.sh not in image"; exit 1;
}

# Resolve crop root. Task-chained inputs already root at crop/.
# usd2roi emits crop/<MATERIAL>/<cell>/{normal_img,cad_mask}/.
find_crop_root () {
  local base="$1"
  if [ -d "$base/crop" ] && find "$base/crop" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1 | grep -q .; then
    echo "$base/crop"; return 0
  fi
  local hit
  hit=$(find "$base" -maxdepth 5 -type d -name crop | head -1 || true)
  if [ -n "$hit" ]; then echo "$hit"; return 0; fi
  echo ""; return 1
}
CLEAN_BASE=$(find_crop_root "$CLEAN_IN") || true
MASK_BASE=$(find_crop_root "$MASK_IN") || true
echo "CLEAN_BASE=$CLEAN_BASE"
echo "MASK_BASE=$MASK_BASE"
[ -n "$CLEAN_BASE" ] && [ -d "$CLEAN_BASE" ] || { echo "ERROR: clean crop/<MAT>/<cell>/ tree not found under $CLEAN_IN"; exit 1; }
[ -n "$MASK_BASE" ]  && [ -d "$MASK_BASE" ]  || { echo "ERROR: cad_mask crop/<MAT>/<cell>/ tree not found under $MASK_IN"; exit 1; }

# Submask source resolution happens per (material, defect) pair below —
# checkpoints with multi-material taxonomies (e.g. the shipped PCBA checkpoint:
# IC+bridge, passive_component+excess_solder, passive_component+missing) can't
# use a single SUBMASK_BASE.
#
# Walk up to find the prepared URL root that contains the per-material mask trees.
resolve_dataset_root () {
  local base="$1"
  # If <base>/<material>/mask/<defect> patterns exist for any material, base is the root.
  if find "$base" -mindepth 3 -maxdepth 3 -type d -path "*/mask/*" | head -1 | grep -q .; then
    echo "$base"; return 0
  fi
  # Try one level deeper for manually uploaded content that preserved a wrapper dir.
  local nested
  nested=$(find "$base" -mindepth 1 -maxdepth 1 -type d | head -1 || true)
  if [ -n "$nested" ] && find "$nested" -mindepth 3 -maxdepth 3 -type d -path "*/mask/*" | head -1 | grep -q .; then
    echo "$nested"; return 0
  fi
  echo "$base"
}
SUBMASK_ROOT=$(resolve_dataset_root "$SUBMASK_BASE_IN")
echo "SUBMASK_ROOT=$SUBMASK_ROOT"

# Symlink pretrained checkpoints. Include sam2 + Qwen so text2roi AMP
# can reach SAM2 + Qwen3-VL via the pretrained tree.
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

# ── Stage per-material per-cell tree into canonical anomalygen layout ──
# usd2roi partitions ROIs by material via crop.class_dirs,
# so each cell only contains the components of its declared material. We
# walk the on-disk material dirs directly (don't fan out from
# anomaly_types_json — that would cross-pollinate IC vs passive_component).
# Composite <CELL>__<STEM> filenames keep clean_image and cad_mask in 1:1.
STAGE=/tmp/inference_stage
rm -rf "$STAGE"

# Materials declared by the checkpoint taxonomy (for sanity-check only).
ATM_MATS=$(python3 -c '
import json, sys
pairs = json.loads(sys.argv[1])
print("\n".join(sorted({m for m, _ in pairs})))
' "$ANOMALY_TYPES_JSON")
echo "anomaly_types_json materials: $(echo "$ATM_MATS" | tr "\n" " ")"

# Materials actually present on disk drive the staging loop.
DISK_MATS=$(find "$CLEAN_BASE" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
[ -n "$DISK_MATS" ] || { echo "ERROR: no material dirs under $CLEAN_BASE"; exit 1; }
echo "usd2roi-disk materials:        $(echo "$DISK_MATS" | tr "\n" " ")"

for MAT in $DISK_MATS; do
  mkdir -p "$STAGE/$MAT/clean_image" "$STAGE/$MAT/cad_mask" "$STAGE/$MAT/mask"
done

# augmentation preserves the input image resolution, so cad_mask
# + augmented clean share dimensions natively. Symlink cad_masks
# straight through — no per-image resize pass needed.
STAGED=0
for MAT in $DISK_MATS; do
  for cell_dir in "$CLEAN_BASE/$MAT"/x*_y*; do
    [ -d "$cell_dir" ] || continue
    CELL=$(basename "$cell_dir")
    MASK_CELL_DIR="$MASK_BASE/$MAT/$CELL/cad_mask"
    for clean_img in "$cell_dir"/*.png "$cell_dir"/*.jpg "$cell_dir"/*.jpeg; do
      [ -f "$clean_img" ] || continue
      STEM=$(basename "${clean_img%.*}")
      EXT="${clean_img##*.}"
      COMPOSITE="${CELL}__${STEM}"
      MASK_FILE=""
      if [ -d "$MASK_CELL_DIR" ] && [ -f "$MASK_CELL_DIR/${STEM}_cad_mask.png" ]; then
        MASK_FILE="$MASK_CELL_DIR/${STEM}_cad_mask.png"
      fi
      ln -sf "$clean_img" "$STAGE/$MAT/clean_image/${COMPOSITE}.${EXT}"
      [ -n "$MASK_FILE" ] && ln -sf "$MASK_FILE" "$STAGE/$MAT/cad_mask/${COMPOSITE}.png" || true
      STAGED=$((STAGED + 1))
    done
  done
done
echo "Staged $STAGED clean images across $(echo "$DISK_MATS" | wc -w) material(s)"
[ "$STAGED" -gt 0 ] || { echo "ERROR: no clean images staged"; exit 1; }

# Warn (don't fail) if anomaly_types_json mentions a material the usd2roi
# output doesn't carry — that pair will just have no SDG inputs.
for ATM in $ATM_MATS; do
  echo "$DISK_MATS" | grep -qx "$ATM" || \
    echo "WARN: anomaly_types_json material '$ATM' missing from $CLEAN_BASE/"
done

# Submasks: per (material, defect) pair, try <root>/<material>/mask/<defect>/
# first (canonical anomalygen layout) then <root>/<defect>/ (flat
# user upload).
while IFS=$'\t' read -r MAT DEFECT; do
  [ -n "$MAT" ] && [ -n "$DEFECT" ] || continue
  src=""
  for candidate in \
      "$SUBMASK_ROOT/$MAT/mask/$DEFECT" \
      "$SUBMASK_ROOT/$DEFECT"; do
    [ -d "$candidate" ] && { src="$candidate"; break; }
  done
  [ -n "$src" ] || { echo "ERROR: submask dir not found for $MAT+$DEFECT (tried $SUBMASK_ROOT/$MAT/mask/$DEFECT and $SUBMASK_ROOT/$DEFECT)"; exit 1; }
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

# Render defect_spec.jsonl (cad / text / free) — Day 0's cad_masks
# support cad mode by default since stage emits <MATERIAL>/cad_mask/<composite>.png.
python3 /tmp/render_defect_spec.py \
  --output "$STAGE/defect_spec.jsonl" \
  --pairs "$ANOMALY_TYPES_JSON" \
  --spatial-dependency "$DEFAULT_SPATIAL_DEPENDENCY"
echo "--- defect_spec.jsonl ---"
cat "$STAGE/defect_spec.jsonl"
echo "--- end defect_spec ---"

# cad mode also requires semantic_segmentation_labels.json at the dataset
# root — it maps cad_mask RGBA values to class IDs that AMP's CADParser
# uses to extract per-class connected components from each cad_mask.
#
# usd2roi emits ONE global labels JSON at crop/ root.
if [ "$DEFAULT_SPATIAL_DEPENDENCY" = "cad" ]; then
  GLOBAL_LABELS=$(find "$MASK_IN" -maxdepth 5 -name semantic_segmentation_labels.json -path '*/crop/*' 2>/dev/null | head -1)
  if [ -z "$GLOBAL_LABELS" ]; then
    echo "ERROR: spatial_dependency=cad but no semantic_segmentation_labels.json under $MASK_IN/crop/"
    exit 1
  fi
  cp "$GLOBAL_LABELS" "$STAGE/semantic_segmentation_labels.json"
  echo "Staged labels: $GLOBAL_LABELS"
fi

AMP_OUT=/tmp/amp_output
JSONL=/tmp/inference.jsonl
mkdir -p "$AMP_OUT"

echo "=== prep_testcase.sh (num_sdg=$NUM_SDG) ==="
bash "$SCRIPTS/prep_testcase.sh" \
    --name "${EXP_NAME}_infer" \
    --num-sdg "$NUM_SDG" \
    --dataset-dir "$STAGE" \
    --defect-spec "$STAGE/defect_spec.jsonl" \
    --amp-output-dir "$AMP_OUT" \
    --output-jsonl "$JSONL"

python3 "$SCRIPTS/validate_jsonl.py" "$WRAPPER" "$JSONL"

export IMAGINAIRE_OUTPUT_ROOT="${OUTPUT_DIR}/results"
mkdir -p "$IMAGINAIRE_OUTPUT_ROOT"
echo "=== run_sdg.sh (checkpoint_step=$CHECKPOINT_STEP, model_size=$MODEL_SIZE) ==="
bash "$SCRIPTS/run_sdg.sh" \
    --checkpoint_dir "$WRAPPER" \
    --step "$CHECKPOINT_STEP" \
    --input_jsonl "$JSONL" \
    --output_dir "$OUTPUT_DIR" \
    --model_size "$MODEL_SIZE" \
    --seed 0

bash "$SCRIPTS/verify_output.sh" "$JSONL" "$OUTPUT_DIR"
echo "=== Inference complete: $(ls "$OUTPUT_DIR/reconstructed_image/" 2>/dev/null | wc -l) images ==="
