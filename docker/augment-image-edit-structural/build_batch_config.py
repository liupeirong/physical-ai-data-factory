# Adapter for the structural-defect crop layout (<input>/cropped/<mode>/rgb/<NNNN>.png).
# Mirrors the inline build_batch_config.py from the OSMO
# `augment-image-edit / image-edit` task in
#   skills/physical-ai-defect-image-generation/assets/configs/structural_defect_generation.yaml
# Keeps the per-mode prefix in the emitted filename so the restyled outputs
# preserve their defect class downstream.
import yaml, os, glob, sys, pathlib

input_dir, output_dir, cookbook_path, batch_cfg_path = sys.argv[1:]

with open(cookbook_path) as f:
    cfg = yaml.safe_load(f)

endpoint = os.environ.get("IMAGE_EDIT_ENDPOINT", "").strip()
model = os.environ.get("IMAGE_EDIT_MODEL", "").strip()
if endpoint:
    cfg.setdefault("endpoints", {}).setdefault("image_edit", {})["url"] = endpoint
if model:
    cfg.setdefault("endpoints", {}).setdefault("image_edit", {})["model"] = model

template = (cfg.get("data") or [{}])[0]
tpl_output = template.get("output", {})
video_tpl = tpl_output.get("video", "/tmp/{stem}.png")
ext = pathlib.Path(video_tpl).suffix or ".png"

# structural_defect crop layout: <input>/cropped/<mode>/rgb/<NNNN>.png
images = []
for mode_dir in sorted(glob.glob(f"{input_dir}/cropped/*/rgb")):
    mode = pathlib.Path(mode_dir).parent.name
    for p in sorted(glob.glob(f"{mode_dir}/*.png") + glob.glob(f"{mode_dir}/*.jpg")):
        images.append((mode, p))
assert images, f"No RGB crops under {input_dir}/cropped/<mode>/rgb/"

data = []
modes_seen = set()
for mode, img_path in images:
    stem = pathlib.Path(img_path).stem
    out_stem = f"{mode}__{stem}"
    os.makedirs(f"{output_dir}/{mode}/rgb", exist_ok=True)
    modes_seen.add(mode)
    data.append({
        "inputs": {"rgb": img_path},
        "output": {
            "video":    f"{output_dir}/{mode}/rgb/{stem}{ext}",
            "caption":  f"/tmp/cap_{out_stem}.txt",
            "metadata": f"/tmp/meta_{out_stem}.json",
        },
    })

cfg["data"] = data
with open(batch_cfg_path, "w") as f:
    yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True)
print(f"Batch config: {len(images)} RGB crops across {len(modes_seen)} mode(s) -> {batch_cfg_path}")
