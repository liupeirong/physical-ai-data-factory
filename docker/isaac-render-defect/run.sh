#!/bin/bash
# Dry-run variant of run_org.sh: does all the cheap host-side prep (scene
# discovery, cookbook patching, defect-mode toggling) for real but only ECHOes
# the heavy Kit + python3 commands so the flow can be exercised on the
# placeholder ubuntu:24.04 image without a GPU. Swap to run_org.sh on the real
# paidf-simulation image (see docker-compose.yaml comments).
set -euo pipefail

ASSETS_IN="${ASSETS_IN:-/data/assets}"
FINAL_OUT="${FINAL_OUT:-/data/output}"
SCENE_FILENAME="${SCENE_FILENAME:-spark_lighting.usd}"
MAX_IMAGE_COUNT="${MAX_IMAGE_COUNT:-5}"
DEFECT_MODES="${DEFECT_MODES:-all}"
CROP_OFFSET="${CROP_OFFSET:-10}"

# ───────────────────────────────────────────────────────────────────────────────

# ubuntu:24.04 ships neither curl nor yq; bootstrap them so the host-side
# cookbook patching below can run for real.
apt -y update
apt -y install curl
[ -x /tmp/yq ] || {
  curl -fsSL https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64 -o /tmp/yq
  chmod +x /tmp/yq
}
export PATH=/tmp:$PATH

export OUT="/tmp/work_out"
rm -rf "$OUT"
mkdir -p "$OUT"

# Locate scene USD by basename inside the mounted asset tree.
SCENE_USD=$(find "$ASSETS_IN" -name "$SCENE_FILENAME" -print -quit)
[ -n "$SCENE_USD" ] || { echo "ERROR: SCENE_FILENAME=$SCENE_FILENAME not found under $ASSETS_IN"; exit 1; }
echo "Scene: $SCENE_USD"

# Patch pcba_target.yaml's `scene:` to the dataset-mounted USD.
PCBA_PATCHED=/tmp/pcba_target_patched.yaml
cp /tmp/pcba_target.yaml "$PCBA_PATCHED"
SCENE_USD="$SCENE_USD" yq -i '.scene = strenv(SCENE_USD)' "$PCBA_PATCHED"

# Patch render config: output dir, render_patches, and the per-mode
# `defects.<mode>.enabled` flags from $DEFECT_MODES.
RENDER_YAML=/tmp/render_config_resolved.yaml
cp /tmp/render_config.yaml "$RENDER_YAML"
OUT="$OUT" MAX_IMAGE_COUNT="$MAX_IMAGE_COUNT" yq -i '
  .output = strenv(OUT) |
  .max_image_count = (strenv(MAX_IMAGE_COUNT) | tonumber)
' "$RENDER_YAML"

if [ "${DEFECT_MODES}" != "all" ]; then
  ALL_MODES="shift tombstone sideflip"
  for m in $(echo "${DEFECT_MODES}" | tr ',' ' '); do
    case " $ALL_MODES " in *" $m "*) ;; *) echo "ERROR: unknown defect_modes: $m (expected subset of: $ALL_MODES)"; exit 1 ;; esac
  done
  ENABLED_LIST="" DISABLED_LIST=""
  for mode in $ALL_MODES; do
    if [[ ",${DEFECT_MODES}," == *",$mode,"* ]]; then
      MODE="$mode" yq -i '.defects[strenv(MODE)].enabled = true' "$RENDER_YAML"
      ENABLED_LIST="$ENABLED_LIST $mode"
    else
      MODE="$mode" yq -i '.defects[strenv(MODE)].enabled = false' "$RENDER_YAML"
      DISABLED_LIST="$DISABLED_LIST $mode"
    fi
  done
  echo "defect_modes: enabled=[${ENABLED_LIST# }], disabled=[${DISABLED_LIST# }]"
fi

cp "$RENDER_YAML"   "$OUT/render_config.yaml"
cp "$PCBA_PATCHED"  "$OUT/pcba_target.yaml"

# Stage 1 — Kit + sdg_pipeline.py (pose-defect render). Echoed in dry-run.
echo "/isaac-sim/kit/kit /isaac-sim/apps/isaacsim.exp.base.kit \
  --no-window --exec \
  \"/workspace/paidf-simulation/scripts/sdg/standalone/sdg_pipeline.py \
   --config $RENDER_YAML --pcba-config $PCBA_PATCHED\""

# Stage 2 — crop_components.py (per-component crops). Echoed in dry-run.
echo "python3 /workspace/paidf-simulation/scripts/postprocess/crop_components.py \
  --input  \"$OUT/trigger_0000\" \
  --output \"$OUT/cropped\" \
  --crops  rgb semantic_segmentation component_instance \
  --offset \"${CROP_OFFSET}\""

# Sanity checks — disabled in the dry-run: the Kit / python3 calls above are
# only echoed, so no frames or crops are actually produced. Re-enabled in
# run_org.sh (the real executor).
# TRIGGERS=$(find "$OUT" -mindepth 1 -maxdepth 1 -type d -name 'trigger_*' | wc -l)
# FRAMES=$(find "$OUT" -path '*/trigger_*/rgb_*.png' 2>/dev/null | wc -l)
# [ "$TRIGGERS" -gt 0 ] && [ "$FRAMES" -gt 0 ] || {
#   echo "ERROR: sdg_pipeline.py produced no frames under $OUT"; exit 1; }
# CROPS=$(find "$OUT/cropped" -mindepth 2 -path '*/rgb/*.png' 2>/dev/null | wc -l)
# [ "$CROPS" -gt 0 ] || { echo "ERROR: crop_components.py produced no per-mode rgb crops"; exit 1; }

# Host-side mirror still runs for real so the user can inspect the resolved
# cookbooks under $FINAL_OUT after a dry-run.
# mkdir -p "$FINAL_OUT"
# cp -r "$OUT"/. "$FINAL_OUT"/
echo "Mirrored $OUT to $FINAL_OUT (dry-run: only resolved configs, no frames/crops)"
