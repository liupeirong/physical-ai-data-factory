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
  run.sh                # the executor (ported from the task's inline run.sh)
  setup.sh              # `source`-d to export host paths + params before compose up
  <inline-script>.py    # any inline OSMO `files: contents` script, broken out
```

Use `entrypoint: ["bash", "/tmp/run.sh"]` (not `command:`) so the
`nvcr.io/...` image's own `ENTRYPOINT` is overridden, matching OSMO's
`command: ["bash"]` + `args:` behavior. With `command:` the script path would
be appended to the image's ENTRYPOINT instead of replacing it.

## Mapping rules (OSMO construct → Docker Compose)

| OSMO task construct | Docker Compose port |
| --- | --- |
| `image: "{{ some_image }}"` | `image:` in compose, resolved to the real img tag. ex. `nvcr.io/...` |
| `command: ["bash"]` + `args: ["/tmp/run.sh"]` | `entrypoint: ["bash", "/tmp/run.sh"]` |
| `environment:` block | `environment:` in compose; resolve `{{ param }}` to `${ENV:-default}` |
| `credentials: { name: { ENV: key } }` | plain `environment:` var (e.g. `HF_TOKEN: "${HF_TOKEN:-}"`); never commit the secret |
| `inputs: [{ url: ... }]` | read-only volume `-"${INPUT_DIR}:/data/input:ro"`; `{{input:0}}` → `/data/input` |
| `inputs: [{ task: <upstream> }]` | same read-only mount, pointed at the upstream task's host OUTPUT_DIR |
| `outputs: [{ url: ... }]` | writable volume `-"${OUTPUT_DIR}:/data/output"`; `{{output}}` → `/data/output` |
| `files: [{ localpath, path }]` | read-only volume mounting that cookbook/asset to `path` |
| `files: [{ path, contents: \| ... }]` | break the inline script out to a real file next to the compose, mount it |
| pod-template hostPath (e.g. nvoptix.bin) | read-only host volume mount with an env-overridable default path |
| `resources: { gpu, cpu, memory }` | `deploy.resources.reservations.devices` with `driver: nvidia`, `count`, `capabilities: [gpu]`; plus `NVIDIA_VISIBLE_DEVICES: all` env |
| `{{ scene_filename }}` and other params | `${SCENE_FILENAME:-default}` env, set in `setup.sh`; referenced as `$SCENE_FILENAME` inside `run.sh` |
| `shm_size` need (Kit ray-tracer etc.) | `shm_size: "32gb"` on the service |
| when NIMS ENDPOINT is required | set docker `network_mode: "host"` |

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
export INPUT_DIR=/datadrive/dig/runs/pcb-${TIMESTAMP}
export OUTPUT_DIR=/datadrive/dig/runs/pcb-${TIMESTAMP}/augment
```

Match `INPUT_DIR` to **where the upstream docker task actually writes**, not to
the OSMO `outputs.url` string. The docker ports often flatten the OSMO output
nesting (e.g. OSMO writes `runs/<name>/usd2roi-components/` but the docker port
writes `crop/` straight into `runs/pcb-${TIMESTAMP}/`). Verify the upstream
`setup.sh` `OUTPUT_DIR` + what its `run.sh` writes before wiring `INPUT_DIR`.

## Conventions / gotchas

- **Secrets**: HF tokens / registry creds become env vars defaulted to empty
  (`${HF_TOKEN:-}`); tell the user to export them in their shell, not commit them.
- **Comment headers**: each file opens with a comment block stating which
  OSMO task / config it ports and how OSMO constructs map to the compose env and
  volumes — match the style of the reference folders.

## Procedure

1. Locate the task in the `assets/configs/*.yaml` (find it by `- name: <task>`).
   Read the whole task: `image`, `environment`, `credentials`, `inputs`,
   `outputs`, `files` (both `localpath` mounts and inline `contents` scripts),
   and the workflow `default-values` for every `{{ param }}` it references.
2. Identify the upstream task so `INPUT_DIR` can point at **where the upstream
   docker port actually writes** (often a flatter path than the OSMO `outputs.url`).
3. Create `docker/<task-name>/` with the file types from "Output layout",
   applying the mapping table.
4. Wire `setup.sh` to prompt for the shared `TIMESTAMP` and export host paths,
   params, and secrets.
