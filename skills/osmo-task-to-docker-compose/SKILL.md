---
name: osmo-task-to-docker-compose
description: >-
  Use when the user wants to convert a single OSMO workflow task (a task under
  `workflow.groups[].tasks[]` in an `assets/configs/*.yaml`) into a standalone,
  runnable Docker Compose project under `docker/<task-name>/`. Produces a
  self-contained folder a learner can run one task at a time with plain
  `docker compose up`, without OSMO or Kubernetes. Chains task-to-task by hand
  via a shared run TIMESTAMP (previous task's output dir becomes the next task's
  input dir).

  Trigger keywords: convert OSMO task, OSMO to docker compose, port task to
  docker, standalone docker compose, run task without OSMO, run task without
  kubernetes, docker-ize task, de-OSMO.
version: "1.0.0"
license: CC-BY-4.0 AND Apache-2.0
tools:
  - Read
  - Shell
metadata:
  owner: NVIDIA
  service: physical-ai-data-factory
  tags:
    - osmo
    - docker-compose
    - workflow-conversion
---

# OSMO Task → Docker Compose Conversion

Convert one OSMO workflow task into a standalone Docker Compose project so it
can be run on a single host with `docker compose up`, with no OSMO scheduler and
no Kubernetes. Each task becomes its own folder under `docker/<task-name>/`.
Tasks are chained by hand: the output directory of one run is fed as the input
directory of the next, all sharing one run `TIMESTAMP`.

## Reference implementations

Read these before converting a new task — they are the canonical examples:

- `docker/usd2roi-replicator/` — a GPU render task with cookbook file mounts and
  a host `hostPath`-style mount (the OptiX binary).
- `docker/augment-image-edit/` — a task that consumes the previous task's output,
  uses a credential (HF token), calls a remote endpoint, and breaks an inline
  OSMO python script out into its own file.

## Output layout (one folder per task)

```
docker/<task-name>/
  docker-compose.yaml   # the service, env, and volume mounts
  run_org.sh            # the REAL executor (ported from the task's inline run.sh)
  run.sh                # DRY-RUN variant: echoes heavy commands, hydrates input/output paths
  setup.sh              # `source`-d to export host paths + params before compose up
  <inline-script>.py    # any inline OSMO `files: contents` script, broken out
```

- **`run_org.sh` is the real script.** **`run.sh` is the dry run** — it performs
  the host-side prep without needing special libs and gpu. Mostly used for validating
  the hydrated input/output paths. Only `echo`s the heavy GPU / model / `uv run`
  commands, so the flow can be exercised on the placeholder `ubuntu:24.04` image
  without a GPU or live endpoint.
- `docker-compose.yaml` runs `run.sh` by default (dry-run safe). Switching to a
  real run = flip the image to the real `nvcr.io/...` image and point `command`
  at `run_org.sh` (call this out in `setup.sh` with an echoed NOTE).

## Mapping rules (OSMO construct → Docker Compose)

| OSMO task construct | Docker Compose port |
| --- | --- |
| `image: "{{ some_image }}"` | `image:` — keep real `nvcr.io/...` image commented, use `ubuntu:24.04` placeholder for dry-run |
| `command: ["bash"]` + `args: ["/tmp/run.sh"]` | `command: ["bash", "/tmp/run.sh"]` (ENTRYPOINT is overridden, same as OSMO) |
| `environment:` block | `environment:` in compose; resolve `{{ param }}` to `${ENV:-default}` |
| `credentials: { name: { ENV: key } }` | plain `environment:` var (e.g. `HF_TOKEN: "${HF_TOKEN:-}"`); never commit the secret |
| `inputs: [{ url: ... }]` | read-only volume `-"${INPUT_DIR}:/data/input:ro"`; `{{input:0}}` → `/data/input` |
| `inputs: [{ task: <upstream> }]` | same read-only mount, pointed at the upstream task's host OUTPUT_DIR |
| `outputs: [{ url: ... }]` | writable volume `-"${OUTPUT_DIR}:/data/output"`; `{{output}}` → `/data/output` |
| `files: [{ localpath, path }]` | read-only volume mounting that cookbook/asset to `path` |
| `files: [{ path, contents: \| ... }]` | break the inline script out to a real file next to the compose, mount it |
| pod-template hostPath (e.g. nvoptix.bin) | read-only host volume mount with an env-overridable default path |
| `resources: { gpu, cpu, memory }` | commented `deploy.resources.reservations.devices` GPU block + `NVIDIA_VISIBLE_DEVICES: all` |
| `{{ scene_filename }}` and other params | `${SCENE_FILENAME:-default}` env, set in `setup.sh` |
| `shm_size` need (Kit ray-tracer etc.) | `shm_size: "32gb"` on the service |

When porting the inline `run.sh`, replace every OSMO template token:
`{{input:0}}` → `$INPUT_DIR`, `{{output}}` → `$OUTPUT_DIR`,
`{{ param }}` → the corresponding `$PARAM` env (defaulted at the top of the
script with `${PARAM:-default}`).

## Task-to-task chaining (shared TIMESTAMP)

These tasks run one after another by hand but behave like one workflow run. A
single run `TIMESTAMP` ties them together:

- The first task's `setup.sh` writes `OUTPUT_DIR=.../runs/<usecase>-${TIMESTAMP}`.
- Each downstream `setup.sh` **prompts for the same TIMESTAMP** and sets
  `INPUT_DIR` to the upstream task's output dir for that timestamp, and
  `OUTPUT_DIR` to a subdir of the same run.

```sh
read -r -p "Run TIMESTAMP to use (e.g. 20260619_120000): " TIMESTAMP
[ -n "$TIMESTAMP" ] || { echo "ERROR: TIMESTAMP is required"; return 1 2>/dev/null || exit 1; }
export TIMESTAMP
export INPUT_DIR=/modeldata1/dig/runs/pcb-${TIMESTAMP}
export OUTPUT_DIR=/modeldata1/dig/runs/pcb-${TIMESTAMP}/augment
```

Match `INPUT_DIR` to **where the upstream docker task actually writes**, not to
the OSMO `outputs.url` string. The docker ports often flatten the OSMO output
nesting (e.g. OSMO writes `runs/<name>/usd2roi-components/` but the docker port
writes `crop/` straight into `runs/pcb-${TIMESTAMP}/`). Verify the upstream
`setup.sh` `OUTPUT_DIR` + what its `run_org.sh` writes before wiring `INPUT_DIR`.

## Conventions / gotchas

- **Dry-run sanity checks**: any post-run check that inspects produced files
  (e.g. `find ... | wc -l` then `exit 1` if zero) must be **commented out in
  `run.sh`** — nothing is produced when commands are only echoed. Keep them live
  in `run_org.sh`.
- **Secrets**: HF tokens / registry creds become env vars defaulted to empty
  (`${HF_TOKEN:-}`); tell the user to export them in their shell, not commit them.
- **Comment headers**: each file opens with a comment block stating which
  OSMO task / config it ports and how OSMO constructs map to the compose env and
  volumes — match the style of the reference folders.
- **`setup.sh` echoes a NOTE** reminding the user to switch the image and run
  script in `docker-compose.yaml` for a real (non-dry) run.

## Procedure

1. Locate the task in the `assets/configs/*.yaml` (find it by `- name: <task>`).
   Read the whole task: `image`, `environment`, `credentials`, `inputs`,
   `outputs`, `files` (both `localpath` mounts and inline `contents` scripts),
   and the workflow `default-values` for every `{{ param }}` it references.
2. Identify upstream/downstream tasks to know what `INPUT_DIR` must point at.
3. Create `docker/<task-name>/` and write the five file types above:
   - `docker-compose.yaml` (placeholder image, env, volumes, commented GPU block),
   - `run_org.sh` (faithful port of the inline run.sh),
   - `run.sh` (dry-run: echo heavy commands, comment out post-run sanity checks),
   - any inline `files: contents` script broken out verbatim,
   - `setup.sh` (prompt for TIMESTAMP, export host paths + params + secrets).
4. Resolve every `{{ ... }}` token to an env var with a sensible default.
5. Tell the user how to chain it (reuse the upstream run's TIMESTAMP) and how to
   flip to a real run (real image + `run_org.sh`).
