#!/bin/bash
set -euo pipefail

ASSETS_IN="${ASSETS_IN:-/data/assets}"
export OUT="${OUT:-/data/output}"
SCENE_FILENAME="${SCENE_FILENAME:-spark_lighting.usd}"

# ───────────────────────────────────────────────────────────────────────────────

apt -y update 
apt -y install curl
# Install Mike Farah yq into /tmp (paidf-simulation ships curl, no wget).
[ -x /tmp/yq ] || {
  curl -fsSL https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64 -o /tmp/yq
  chmod +x /tmp/yq
}
export PATH=/tmp:$PATH

mkdir -p "$OUT"

# 1. pcba_target.yaml ships in the cookbook (mounted at /tmp/pcba_target.yaml).
PCBA_YAML=/tmp/pcba_target.yaml
[ -f "$PCBA_YAML" ] || { echo "ERROR: $PCBA_YAML not mounted (cookbook volume)"; exit 1; }

# Locate scene USD by basename inside the mounted asset tree.
SCENE_USD=$(find "$ASSETS_IN" -name "$SCENE_FILENAME" -print -quit)
[ -n "$SCENE_USD" ] || { echo "ERROR: SCENE_FILENAME=$SCENE_FILENAME not found under $ASSETS_IN"; exit 1; }
echo "Assets: pcba_target=$PCBA_YAML scene=$SCENE_USD"

# Patch scene path in pcba_target.yaml so it points at the mounted USD.
PCBA_PATCHED=/tmp/pcba_target_patched.yaml
cp "$PCBA_YAML" "$PCBA_PATCHED"
SCENE_USD="$SCENE_USD" yq -i '.scene = strenv(SCENE_USD)' "$PCBA_PATCHED"

# 2. Resolve sentinels in SDG + crop cookbooks.
SDG_YAML=/tmp/day0_image_resolved.yaml
CROP_YAML=/tmp/day0_crop_resolved.yaml
cp /tmp/day0_image.yaml "$SDG_YAML"
cp /tmp/day0_crop.yaml  "$CROP_YAML"

OUT="$OUT" MAX_IMAGE_COUNT="${MAX_IMAGE_COUNT:--1}" yq -i '
  .output = strenv(OUT) |
  .max_image_count = (strenv(MAX_IMAGE_COUNT) | tonumber)
' "$SDG_YAML"
OUT="$OUT" yq -i '.output.dir = strenv(OUT)' "$CROP_YAML"

# Optional: override the cookbook's per-cell crop cap (max_emit).
if [ -n "${CROP_MAX_EMIT:-}" ]; then
  if [ "$CROP_MAX_EMIT" = "null" ]; then
    yq -i '.crop.max_emit = null' "$CROP_YAML"
  else
    CROP_MAX_EMIT="$CROP_MAX_EMIT" yq -i '.crop.max_emit = (strenv(CROP_MAX_EMIT) | tonumber)' "$CROP_YAML"
  fi
  echo "Patched crop.max_emit -> ${CROP_MAX_EMIT}"
fi

# Inject a safe horizontal_aperture default if neither YAML sets it
# (some Kit builds read CFG["horizontal_aperture"] unconditionally).
if ! grep -qE '^[^#]*horizontal_aperture:' "$SDG_YAML" "$PCBA_PATCHED" 2>/dev/null; then
  echo "" >> "$SDG_YAML"
  echo "# Camera aperture default (USD-authored value overridden when present)" >> "$SDG_YAML"
  echo "horizontal_aperture: 200.0" >> "$SDG_YAML"
  echo "Injected horizontal_aperture: 200.0 into $SDG_YAML"
fi

cp "$SDG_YAML"     "$OUT/day0_image.yaml"
cp "$CROP_YAML"    "$OUT/day0_crop.yaml"
cp "$PCBA_PATCHED" "$OUT/pcba_target.yaml"

# 3. Stage 1 — labelled scan_grid render (Kit). Invoke the base-app launcher
#    directly (the image ENTRYPOINT is bypassed, same as under OSMO).
echo "/isaac-sim/kit/kit /isaac-sim/apps/isaacsim.exp.base.kit \
  --no-window --exec \
  \"/workspace/paidf-simulation/scripts/sdg/standalone/sdg_pipeline.py \
   --config $SDG_YAML --pcba-config $PCBA_PATCHED"

# 4. Stage 2 — multi-cell ROI crop (pure python, no Kit).
echo "python3 /workspace/paidf-simulation/scripts/usd2roi/usd2roi_crop.py \
  --config \"$CROP_YAML"

