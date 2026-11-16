# Repository Guidelines

> AI-assistant notes for working in `runpod-fedora-img`.

## Project Overview

`runpod-fedora-img` is a **git repo that generates an OCI image** to deploy on **RunPod** for running **AI LLM inference** using **Lemonade** and **llama-cpp**.

- **Repo type:** Infrastructure / container recipe, **not** an application codebase. All "source" is shell/Docker config (9 tracked files).
- **Deliverable:** an OCI image (also buildable as a Podman image, tagged `fedora-lemonade`) intended to run on RunPod GPU instances.
- **Workloads:** self-hosted LLM chat/agent inference via Lemonade's server, backed by the `llama-cpp` CUDA backend.
- **Package source:** Lemonade and llama-cpp are **self-built RPM packages** hosted on the author's own GitHub-hosted yum repository (`ai-custom-infra.repo`, referenced inline in the Dockerfile). They are installed from that custom repo, **not** official upstream packages.
- **Language/runtime:** POSIX `bash` scripts + `Dockerfile`; container runtime = `podman`. No app package manager (npm/pip/cargo) — deps resolved by Fedora `dnf` `RUN` layers inside the image.
- **License:** GPL-3.0 (`LICENSE`); container SSH auth via `id_rsa.pub`.
- **Purpose:** Package a reproducible GPU inference host. On RunPod you build the image, then run it on a GPU pod; the entrypoint auto-detects VRAM, downloads the selected model, and serves it over SSH.

## Architecture & Data Flow

Boot-to-serve pipeline:

```
podman build .            build.sh -> fedora-lemonade (OCI image, deployable on RunPod)
        |
        v
OCI image on RunPod GPU pod -> podman run fedora-lemonade
        |
        +-- run.sh (entrypoint, WORKDIR /app, logs -> /var/log/run.log)
        |     1. get_gpu_vram(): nvidia-smi --query-gpu=count/memory.total -> VRAM_GB
        |     2. MODEL=${LEMONADE_MODEL:-qwen3-27b}          (registry lives in lemonadectl)
        |     3. /usr/bin/sshd -D &                          (SSH on :22, keys from id_rsa.pub)
        |     4. mkdir + chown lemonade:lemonade of cache/state dirs
        |     5. lemonadectl download $MODEL [--mmproj]      (as `lemonade` user, FOREGROUND;
        |        run.sh blocks until the model is on disk; --mmproj only when VRAM>30GB)
        |     6. lemonadectl start &                         (as `lemonade` user, backgrounded)
        |     7. wait for `lemonade status`, then `lemonade config set` x5
        |        (extra_models_dir + llamacpp cuda/cpu bin, backend, args)
        |     8. lemonadectl load $MODEL --vram $VRAM_GB     (per-model args/ctx from registry:
        |        <=30GB small profile ctx 110k / >30GB large profile ctx 250k)
        |     9. safety net: sleep 8h; kill %1 %2; sleep 20; kill -9
        |
        +-- lemonadectl start (backgrounded; model-agnostic — the server just scans
        |                      the extra_models_dir, which model serves is set by load)
              1. export RUNTIME/STATE/CACHE_DIRECTORY, HF_HOME=/var/cache/lemonade/huggingface
              2. CUDA-13 driver gate: need host driver >= 580
                 - if host driver < 580: prepend /usr/local/cuda-13*/compat (sorted, deduped) to LD_LIBRARY_PATH
                 - else: native CUDA 13 OK
              3. exec /usr/bin/lemond                          (actual server process)
```

**Lemonade model (how the platform stores/loads models):**
- Models are `user.*` definitions recorded in `user_models.json`; files live under `HF_HOME` (`/var/cache/lemonade/huggingface`) + recipe dirs.
- A model = **recipe** (inference backend, e.g. `llamacpp`) + **checkpoints** (model weights; multi-component models split by type, e.g. `main` + `mmproj` for vision).
- Checkpoints are downloaded by `lemonadectl download <model>` (hf CLI into `extra_models_dir` = `/var/cache/huggingface`, the dir lemond scans). `lemonade load NAME --llamacpp-args '...' --ctx-size N --save-options` (run via `lemonadectl load <model> --vram <GB>`) loads into the backend for serving; NAME is the model's local dir name.
- Labels are a taxonomy: `coding, embeddings, hot, mtp, reasoning, reranking, tool-calling, vision`.

**Model selection:** one model per container instance, picked at boot via the `LEMONADE_MODEL` env var (default `qwen3-27b`). Registered models, their HF repos, checkpoint/mmproj file names, and per-VRAM-tier load args live in the `lemonadectl` registry — adding a model is a matter of adding a few entries there.

**Observed behaviors / gotchas:**
- `MTP` (draft/speculative decoding) is **disabled** with a comment: *"MTP doesn't work well with nvidia and llama-cpp. Performance is bad, let's not use it."*
- CUDA-13 backend requires NVIDIA driver major version **>= 580**; otherwise the `cuda-13*/compat` shim is needed on `LD_LIBRARY_PATH`.
- The `get_gpu_vram()` fallback heuristic table (by GPU name) is commented out — detection now trusts `nvidia-smi`'s reported `memory.total`.
- VRAM split: `<=30GB` → small profile, `--ctx-size 110000`; `>30GB` → large profile, `--ctx-size 250000` (profiles defined per model in the lemonadectl registry).

## Key Directories

| Path | Purpose |
|------|---------|
| `/app` | WORKDIR; holds `run.sh`, `lemonadectl` (copied in); entrypoint CWD |
| `/var/log/run.log` | Combined stdout/stderr of `run.sh` (container diagnostics) |
| `/var/log/lemonade.log` | Combined stdout/stderr of the `lemond` server |
| `/var/cache/huggingface` | Downloaded GGUF checkpoints (`extra_models_dir`); owned by `lemonade` |
| `/var/cache/lemonade` | Lemonade runtime cache/recipes + `HF_HOME` (`huggingface/` subdir); owned by `lemonade` |
| `/var/lib/lemonade` | Lemonade **state** (created/exported, `STATE_DIRECTORY`) |
| `/run/lemonade` | Lemonade **runtime** dir (`RUNTIME_DIRECTORY`) |
| `/root/.ssh/authorized_keys` | Deployed key (`id_rsa.pub`) for root SSH |
| `mock/nvidia-smi` | Fake `nvidia-smi` emulating RTX 4090 / 24GB VRAM for test envs |

## Development Commands

All scripts use `set -euo pipefail`. `bash` only.

| Task | Command |
|------|---------|
| Build image | `bash build.sh` → `podman build -t fedora-lemonade .` |
| Push to GHCR | `bash push-to-ghcr.sh` (tags `localhost/fedora-lemonade:latest` → `ghcr.io/enricotagliavini/fedora-lemonade:latest`) |
| Test image locally | `bash test-podman-locally.sh` (runs detached, maps `2222:22`, mounts `~/.ssh/id_rsa_ovh.pub`, execs as root) |
| Run on RunPod | build/push the OCI image, then run it on a GPU pod |

**Diagnosing a container:** inspect `/var/log/run.log` (bootstrap/VRAM) and `/var/log/lemonade.log` (server). Verify GPU: `nvidia-smi` present + host driver major >= 580 for CUDA 13.

## Code Conventions & Common Patterns

- **Shell style:** `#!/bin/bash`, `set -euo pipefail`, functions grouped by purpose, `&&/||` chains in `RUN` layers, `ed25519` ssh-keygen, `chmod +x` on copied scripts.
- **Idempotency:** `lemonadectl start` guards `LD_LIBRARY_PATH` with `if [[ ":$LD_LIBRARY_PATH:" != *":$COMPAT_PATH:"* ]]` to avoid dup shim entries on multi-source.
- **Model registry:** per-model facts (HF repo, checkpoint/mmproj file names, local dir, per-VRAM-tier load args) live in the associative-array registry at the top of `lemonadectl`, keyed by slug; `run.sh` only passes the slug + detected VRAM.
- **Backgrounding + logging:** services are `&`-ed while the script's own stdout is redirected (`exec >> /var/log/... 2>&1`), then a hard `sleep 8h` safety-net kills `%1 %2`.
- **Lemonade config via `config set`:** namespace `llamacpp.*` → keys `cuda_bin`, `cpu_bin`, `backend` (`cuda`|`system`), `args`. These configure the CUDA-backed llama-server entrypoint.
- **Error handling:** relies on `set -e` + `command -v ... &>/dev/null || {...}` guards; `nvidia-smi` failures are tolerated (defaults to `0` GB → CPU fallback path).
- **Self-built RPMs:** `dnf install lemonade-server llama-cpp` resolves from the author's custom yum repo (`ai-custom-infra.repo`), not upstream packages — edit that URL to repoint the build at a different RPM set.
- **No async/dependency-injection/state-machine patterns** — this is orchestration config, not app logic.

## Important Files

| File | Role |
|------|------|
| `Dockerfile` | Fedora 44 base; installs NVIDIA CUDA libs (`libcublas13-cuda-13`, `cuda-compat-13-3`, `xorg-x11-drv-nvidia-cuda`), `openssh-server`, `lemonade-server` + `llama-cpp` from the `ai-custom-infra` custom RPM repo; exposes :22; CMD `/app/run.sh` |
| `run.sh` | Entrypoint: VRAM detect, model selection (`LEMONADE_MODEL`), sshd, cache setup, `lemonadectl download` (foreground) → `lemonadectl start &`, lemonade `config set`, `lemonadectl load`, safety net |
| `lemonadectl` | Model registry + CLI: `models`, `download <model> [--mmproj]`, `start` (CUDA-13 driver/compat gate → `exec lemond`), `load <model> --vram <GB>` |
| `build.sh` | One-line `podman build` |
| `push-to-ghcr.sh` | Tag+push to GHCR (`-x` verbose) |
| `test-podman-locally.sh` | Local detached run w/ SSH + key mount |
| `mock/nvidia-smi` | GPU-less testing shim (RTX 4090 / 24GB) |
| `id_rsa.pub` | Deployment SSH public key |

## Runtime/Tooling Preferences

- **Container runtime:** Podman. Image is OCI-compliant and meant for RunPod; the Dockerfile uses `docker://registry.fedoraproject.org/fedora-minimal:44` as base and `push-to-ghcr.sh` tags `localhost/...`.
- **Package management:** Fedora `dnf` inside the image. Lemonade and llama-cpp are **locally built RPMs** from the author's GitHub-hosted repo (`ai-custom-infra.repo`) — treat these as first-party builds, not upstream packages.
- **Tooling:** bash scripting idioms; `nvidia-smi` `--query-gpu=count|name|memory.total --format=csv` parsing; `bc` for integer VRAM math; `compgen -G` for globbing cuda compat dirs.

## Testing & QA

- **No unit/integration test framework** for the shell logic. QA is done by running the image.
- **`test-podman-locally.sh`:** spins the image detached, maps SSH `2222:22`, mounts `~/.ssh/id_rsa_ovh.pub`, opens a root shell, then cleans up. Use it to sanity-check that the image boots and the model loads.
- **`mock/nvidia-smi`:** lets you test `get_gpu_vram`/driver paths without an NVIDIA GPU. It caches output to `/tmp/nvidia-smi.mock` (+ `.mb` for the raw MB value) on first run and dispatches the `--query-gpu=...`/`--format=csv` flags used by `run.sh`.
- **Coverage expectation:** informal (smoke-run the container); there is no test suite to extend.
