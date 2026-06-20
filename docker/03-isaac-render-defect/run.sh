#!/usr/bin/env bash
# Standalone port of the inline run_render.sh from the OSMO `isaac-render-defect`
# task (sdg-and-crop) in
#   skills/physical-ai-defect-image-generation/assets/configs/structural_defect_generation.yaml
# OSMO templating is replaced by environment variables supplied by
# docker-compose.yaml:
#   ASSETS_IN        was {{input:0}}        (host USD asset tree, mounted ro)
#   FINAL_OUT        was {{output}}         (host output dir)
#   SCENE_FILENAME   was {{ scene_filename }}
#   MAX_IMAGE_COUNT / DEFECT_MODES / CROP_OFFSET  same as the OSMO environment: block
set -euo pipefail

ASSETS_IN="${ASSETS_IN:-/data/assets}"
FINAL_OUT="${FINAL_OUT:-/data/output}"
SCENE_FILENAME="${SCENE_FILENAME:-spark_lighting.usd}"
MAX_IMAGE_COUNT="${MAX_IMAGE_COUNT:-5}"
DEFECT_MODES="${DEFECT_MODES:-all}"
CROP_OFFSET="${CROP_OFFSET:-10}"

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

# Install Mike Farah yq into /tmp (paidf-simulation ships curl, no wget).
[ -x /tmp/yq ] || {
  curl -fsSL https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64 -o /tmp/yq
  chmod +x /tmp/yq
}
export PATH=/tmp:$PATH

# Stage to a writable tempdir owned by the container user (UID 1234 =
# isaac-sim). The mounted FINAL_OUT may be owned by a different host user and
# some pipeline sub-steps need a fully writable working dir; we mirror to
# $FINAL_OUT at the end via `cp -r`.
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

# If defect_modes is not the default "all", toggle the per-mode
# `defects.<mode>.enabled` flags from the requested subset.
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

# Persist resolved configs alongside the render output.
cp "$RENDER_YAML"   "$OUT/render_config.yaml"
cp "$PCBA_PATCHED"  "$OUT/pcba_target.yaml"

# ── Stage 1: Kit + sdg_pipeline.py (pose-defect render) ─────────────────────
/isaac-sim/kit/kit /isaac-sim/apps/isaacsim.exp.base.kit \
  --no-window --exec \
  "/workspace/paidf-simulation/scripts/sdg/standalone/sdg_pipeline.py \
   --config $RENDER_YAML --pcba-config $PCBA_PATCHED"

TRIGGERS=$(find "$OUT" -mindepth 1 -maxdepth 1 -type d -name 'trigger_*' | wc -l)
FRAMES=$(find "$OUT" -path '*/trigger_*/rgb_*.png' 2>/dev/null | wc -l)
[ "$TRIGGERS" -gt 0 ] && [ "$FRAMES" -gt 0 ] || {
  echo "ERROR: sdg_pipeline.py produced no frames under $OUT"; exit 1; }
echo "render complete: $FRAMES frames across $TRIGGERS trigger(s)"

# ── Stage 2: crop_components.py (per-component crops) ───────────────────────
python3 /workspace/paidf-simulation/scripts/postprocess/crop_components.py \
  --input  "$OUT/trigger_0000" \
  --output "$OUT/cropped" \
  --crops  rgb semantic_segmentation component_instance \
  --offset "${CROP_OFFSET}"

# crop_components.py emits per-mode subdirs for structural_defect:
#   $OUT/cropped/<mode>/rgb/*.png  (mode ∈ shift|tombstone|sideflip)
# so count recursively (mindepth 2 to skip $OUT/cropped/rgb if ever flat).
CROPS=$(find "$OUT/cropped" -mindepth 2 -path '*/rgb/*.png' 2>/dev/null | wc -l)
[ "$CROPS" -gt 0 ] || { echo "ERROR: crop_components.py produced no per-mode rgb crops under $OUT/cropped/"; ls -laR "$OUT/cropped" 2>/dev/null | head -40; exit 1; }
echo "crop complete: $CROPS per-component crops at $OUT/cropped/"
find "$OUT/cropped" -mindepth 1 -maxdepth 1 -type d -printf '  mode=%f\n' 2>/dev/null

# Mirror staged output to the host output mount. Use `cp -r` (not `cp -a`) —
# `-a` preserves timestamps via utime(), which can fail for a non-root container
# user against a host-owned mount. Files copy fine; we just don't carry over
# timestamps/perms (irrelevant downstream).
mkdir -p "$FINAL_OUT"
cp -r "$OUT"/. "$FINAL_OUT"/
echo "Mirrored $OUT to $FINAL_OUT"
