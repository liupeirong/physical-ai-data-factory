# Docker tasks — host input/output folders

Standalone Docker Compose ports of the OSMO tasks. Each task reads its host
paths from the env vars exported by its `setup.sh` and mounts them into the
container via `docker-compose.yaml`.

Tasks chain together as one workflow run, identified by a single `TIMESTAMP`:
the output of one task is usually the input of the next.

```
usd2roi-replicator  →  augment-image-edit  →  finetune / anomaly-infer
```

| Task | Role | Host path (`setup.sh`) | Container mount (compose) |
|------|------|------------------------|----------------------------|
| **usd2roi-replicator** | Input (USD asset tree, read-only) | `/datadrive/dig/datasets/pcb/assets` (`INPUT_ASSETS_DIR`) | `/data/assets:ro` |
| **usd2roi-replicator** | Output (run results) | `/datadrive/dig/runs/pcb-${TIMESTAMP}` (`OUTPUT_DIR`) | `/data/output` |
| **augment-image-edit** | Input (usd2roi-components tree, read-only) | `/datadrive/dig/runs/pcb-${TIMESTAMP}` (`INPUT_DIR`) | `/data/input:ro` |
| **augment-image-edit** | Output (SL-restyled crops) | `/datadrive/dig/runs/pcb-${TIMESTAMP}/augment` (`OUTPUT_DIR`) | `/data/output` |

Notes:

- **usd2roi-replicator** also mounts per-board cookbook YAMLs from `COOKBOOKS_DIR`
  (`/home/azureuser/dev/paidf-fork/skills/physical-ai-defect-image-generation/assets/cookbooks`).
- **augment-image-edit** input is the **output of the `usd2roi-replicator` run**
  (same `TIMESTAMP`); output is the `augment/` subdir nested inside it. It also
  mounts the OVSL2SL augmentation cookbook from `COOKBOOKS_DIR` and calls a remote
  Qwen-Image-Edit endpoint (`IMAGE_EDIT_ENDPOINT`) rather than a local data folder.

## Executables / scripts invoked

Commands each task's `run_org.sh` runs (the actual pipeline steps), with their
parameters.

| Task | Command | Parameters |
|------|---------|------------|
| **usd2roi-replicator** | `/isaac-sim/kit/kit` (Stage 1, runs `sdg_pipeline.py` via `--exec`) | `/isaac-sim/apps/isaacsim.exp.base.kit --no-window --exec "sdg_pipeline.py --config $SDG_YAML --pcba-config $PCBA_PATCHED"` |
| **usd2roi-replicator** | `python3 usd2roi_crop.py` (Stage 2) | `--config $CROP_YAML` |
| **augment-image-edit** | `uv run python build_batch_config.py` | `$INPUT_DIR $OUTPUT_DIR /tmp/augmentation_cookbook.yaml /tmp/augmentation_batch.yaml` |
| **augment-image-edit** | `uv run python /app/modules/cli.py` | `--config /tmp/augmentation_batch.yaml` |
