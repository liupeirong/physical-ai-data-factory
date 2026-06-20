# Expand the augmentation cookbook's `data:` section to walk the per-cell tree
# from the usd2roi-replicator output, overlay endpoint URL/model from env, and
# keep all other cookbook fields (prompt, model params, letterbox,
# align_to_reference) verbatim. Output ends up at
# <output>/crop/<MATERIAL>/<cell>/<stem>.<ext> (flat per cell).
#
# Standalone port of the inline build_batch_config.py from the OSMO
# `augment-image-edit` task in assets/configs/good_image_generation.yaml.
import yaml, os, glob, sys, pathlib

input_dir, output_dir, cookbook_path, batch_cfg_path = sys.argv[1:]

with open(cookbook_path) as f:
    cfg = yaml.safe_load(f)

# Overlay endpoint from the environment (cookbook ships localhost placeholder).
endpoint = os.environ.get("IMAGE_EDIT_ENDPOINT", "").strip()
model = os.environ.get("IMAGE_EDIT_MODEL", "").strip()
if endpoint:
    cfg.setdefault("endpoints", {}).setdefault("image_edit", {})["url"] = endpoint
if model:
    cfg.setdefault("endpoints", {}).setdefault("image_edit", {})["model"] = model

# Derive sample output extension from the cookbook's single data entry
# so we round-trip (.jpg in cookbook -> .jpg outputs).
template = (cfg.get("data") or [{}])[0]
tpl_output = template.get("output", {})
video_tpl = tpl_output.get("video", "/tmp/{stem}.png")
ext = pathlib.Path(video_tpl).suffix or ".png"

# usd2roi emits crop/<MATERIAL>/<cell>/normal_img/<NNNN>.png
images = sorted(glob.glob(f"{input_dir}/crop/*/*/normal_img/*.png") +
                glob.glob(f"{input_dir}/crop/*/*/normal_img/*.jpg"))
assert images, f"No per-material/per-cell ROIs found under {input_dir}/crop/*/*/normal_img/"
# Dataset size is controlled at the upstream usd2roi-replicator stage via
# `crop_max_emit`. The image-edit task processes every ROI it's handed.

data = []
seen = set()
for img_path in images:
    parts = pathlib.Path(img_path).parts
    material = parts[-4]                       # IC | passive_component
    cell = parts[-3]                           # x*_y*
    stem = pathlib.Path(img_path).stem         # NNNN
    cell_out = f"{output_dir}/crop/{material}/{cell}"
    key = (material, cell)
    if key not in seen:
        os.makedirs(cell_out, exist_ok=True)
        seen.add(key)
    data.append({
        "inputs": {"rgb": img_path},
        "output": {
            "video":    f"{cell_out}/{stem}{ext}",
            "caption":  f"/tmp/cap_{material}_{cell}_{stem}.txt",
            "metadata": f"/tmp/meta_{material}_{cell}_{stem}.json",
        },
    })

cfg["data"] = data
with open(batch_cfg_path, "w") as f:
    yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True)
print(f"Batch config: {len(images)} ROIs across {len(seen)} material/cell dirs -> {batch_cfg_path}")
