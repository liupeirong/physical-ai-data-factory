#!/usr/bin/env bash
# Standalone port of the inline run.sh from the OSMO `usd2roi-day1` task
# (group `usd2roi-render-day1`) in
#   assets/configs/texture_defect_generation_day1_real_alignment.yaml
#
# OSMO templating is replaced by environment variables supplied by
# docker-compose.yaml:
#   ASSETS_IN            was {{input:0}}             (host USD asset tree, mounted ro)
#   OUT                  was {{output}}              (host output dir)
#   SCENE_FILENAME       was {{ scene_filename }}
#   REAL_IMAGE_FILENAME  was {{ real_image_filename }}
set -euo pipefail

ASSETS_IN="${ASSETS_IN:-/data/assets}"
export OUT="${OUT:-/data/output}"
SCENE_FILENAME="${SCENE_FILENAME:-spark_lighting.usd}"
REAL_IMAGE_FILENAME="${REAL_IMAGE_FILENAME:-input_real_image/0603_H100.jpg}"

# ── Preflight (same checks as the OSMO task) ───────────────────────────────────
if [ ! -f /usr/share/nvidia/nvoptix.bin ]; then
  echo "ERROR: /usr/share/nvidia/nvoptix.bin not mounted; Kit OptiX silently falls back to raw path tracing (noisy output)."
  echo "  Mount it via NVOPTIX_BIN in docker-compose.yaml."
  exit 1
fi
DSHM_GB=$(df -B1G /dev/shm | tail -1 | awk '{print $2}')
if [ "$DSHM_GB" -lt 16 ]; then
  echo "ERROR: /dev/shm is ${DSHM_GB}GiB; need >= 16 GiB (32 preferred) for Kit ray-tracer buffers."
  echo "  Raise shm_size in docker-compose.yaml."
  exit 1
fi
# ───────────────────────────────────────────────────────────────────────────────

# Install Mike Farah yq into /tmp (pod /usr/local/bin is non-writable;
# paidf-simulation ships curl, no wget).
[ -x /tmp/yq ] || {
  curl -fsSL https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64 -o /tmp/yq
  chmod +x /tmp/yq
}
export PATH=/tmp:$PATH

mkdir -p "$OUT"

# 1. Locate scene USD by basename inside the mounted asset tree.
SCENE_USD=$(find "$ASSETS_IN" -name "$SCENE_FILENAME" -print -quit)
[ -n "$SCENE_USD" ] || { echo "ERROR: SCENE_FILENAME=$SCENE_FILENAME not found under $ASSETS_IN"; exit 1; }

# 2. Locate real photo (path is relative to asset tree, or just a basename).
if [ -f "$ASSETS_IN/$REAL_IMAGE_FILENAME" ]; then
  REAL_IMG="$ASSETS_IN/$REAL_IMAGE_FILENAME"
else
  REAL_IMG=$(find "$ASSETS_IN" -name "$(basename "$REAL_IMAGE_FILENAME")" -print -quit)
fi
[ -n "$REAL_IMG" ] || { echo "ERROR: REAL_IMAGE_FILENAME=$REAL_IMAGE_FILENAME not found under $ASSETS_IN"; exit 1; }
echo "Scene: $SCENE_USD"
echo "Photo: $REAL_IMG"

# 3. Resolve cookbook sentinels (__SCENE__, __REAL_IMAGE__, __OUTPUT__).
CFG=/tmp/usd2roi_day1_resolved.yaml
cp /tmp/usd2roi_day1.yaml "$CFG"
SCENE_USD="$SCENE_USD" REAL_IMG="$REAL_IMG" OUT="$OUT" yq -i '
  .scene = strenv(SCENE_USD) |
  .real_image = strenv(REAL_IMG) |
  .output.dir = strenv(OUT)
' "$CFG"
cp "$CFG" "$OUT/usd2roi_day1.yaml"

# 4. Stage 1 — Kit ortho render (~5-7 min cold boot).
# The image's ENTRYPOINT is ignored when the entrypoint is overridden, so
# invoke Kit's base-app launcher directly.
/isaac-sim/kit/kit /isaac-sim/apps/isaacsim.exp.base.kit \
  --no-window --exec \
  "/workspace/paidf-simulation/scripts/usd2roi/usd2roi_render.py --config $CFG"

# 5. Stage 2 — cupy GPU MI registration (~15-30 s).
# min_mi exit-2 means the synth/real overlap is below threshold; surface clearly.
set +e
python3 /workspace/paidf-simulation/scripts/usd2roi/usd2roi_register.py --config "$CFG"
REG_EXIT=$?
set -e
if [ "$REG_EXIT" -ne 0 ]; then
  echo "ERROR: usd2roi_register.py exited $REG_EXIT (likely MI < min_mi)."
  echo "  See skills/physical-ai-defect-image-generation/references/troubleshooting.md (usd2roi day-1 MI alignment)."
  echo "  Common fixes: widen registration.sx/sy/rot ranges, lower min_mi,"
  echo "  re-check camera.translate + horizontal_aperture against the real photo."
  exit "$REG_EXIT"
fi

# 6. Stage 3 — CPU python per-ROI crop (seconds).
python3 /workspace/paidf-simulation/scripts/usd2roi/usd2roi_crop.py --config "$CFG"

# 7. Sanity check (the crop script emits flat normal_img/<NNNN>.png for day-1,
#    vs per-cell subdirs for day-0).
ROIS=$(find "$OUT/crop" -path "*/normal_img/*.png" 2>/dev/null | wc -l)
if [ "$ROIS" -eq 0 ]; then
  echo "ERROR: 0 ROI crops emitted under $OUT/crop"; exit 1
fi
echo "usd2roi-day1 complete: $ROIS ROI crops"
if [ -f "$OUT/aligned/params.json" ]; then
  echo "--- registration params ---"
  python3 -m json.tool "$OUT/aligned/params.json" || cat "$OUT/aligned/params.json"
  echo "--- end params ---"
fi
