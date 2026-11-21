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
        |     2. model selection: MODEL env (qwen|ornith)    (registry lives in lemonadectl)
        |        default: ornith at VRAM>=30GB, else qwen; invalid MODEL -> warn + default
        |     3. /usr/bin/sshd -D &                          (SSH on :22, keys from id_rsa.pub)
        |     4. mkdir + chown lemonade:lemonade of cache/state dirs
        |     5. prepare_cuda_compat(): host driver < CUDA-major floor (525 for CUDA12, 580 for 13)?
        |        (prefer /proc/driver/nvidia/version, nvidia-smi fallback, HOST_DRIVER_MAJOR override)
        |        install cuda-compat-<maj>-<min> at runtime (NOT baked in, ~109MB), stage shim dir to
        |        /run/cuda_compat_dir for 'lemonadectl start' to apply; no-op when the host driver is new enough
        |     6. lemonadectl download $MODEL [--mmproj] [--hf-token-file PATH]
        |        (as `lemonade` user, FOREGROUND; run.sh blocks until the model
        |        is on disk; --mmproj only when VRAM>30GB; HF_TOKEN env var is
        |        bridged to a 0600 /run/hf_token for the download's duration)
        |     7. lemonadectl start &                         (as `lemonade` user, backgrounded)
        |     8. wait for `lemonade status`, then `lemonade config set` x5
        |        (extra_models_dir + llamacpp cuda/cpu bin, backend, args)
        |     9. lemonadectl load $MODEL --vram $VRAM_GB     (per-model args/ctx from registry:
        |        small tier = VRAM<=30GB; qwen ctx 110k/128k, ornith ctx 128k)
        |     10. safety net: sleep 8h; kill %1 %2; sleep 20; kill -9
        |
        +-- lemonadectl start (backgrounded; model-agnostic — the server just scans
        |                      the extra_models_dir, which model serves is set by load)
              1. export RUNTIME/STATE/CACHE_DIRECTORY, HF_HOME=/var/cache/lemonade/huggingface
              2. CUDA-13 driver gate: read the shim dir staged by run.sh at
                 $CUDA_COMPAT_STATE (/run/cuda_compat_dir); apply it to
                 LD_LIBRARY_PATH (sudo strips it before we reach the lemonade
                 user), deduped; absent => host driver supports CUDA natively
              3. exec /usr/bin/lemond                          (actual server process)
```

**Lemonade model (how the platform stores/loads models):**
- Models are `user.*` definitions recorded in `user_models.json`; files live under `HF_HOME` (`/var/cache/lemonade/huggingface`) + recipe dirs.
- A model = **recipe** (inference backend, e.g. `llamacpp`) + **checkpoints** (model weights; multi-component models split by type, e.g. `main` + `mmproj` for vision).
- Checkpoints are downloaded by `lemonadectl download <model>` (hf CLI into `extra_models_dir` = `/var/cache/huggingface`, the dir lemond scans). `lemonade load NAME --llamacpp-args '...' --ctx-size N --save-options` (run via `lemonadectl load <model> --vram <GB>`) loads into the backend for serving; the `--llamacpp-args` passed to lemond include a common profile (`--cache-reuse`, `--batch-size`, `--ubatch-size`, `--cache-ram`) applied to every model, plus the model/tier-specific bits. NAME is the model's local dir name.
- Labels are a taxonomy: `coding, embeddings, hot, mtp, reasoning, reranking, tool-calling, vision`.

**Model selection:** one model per container instance, picked at boot by the `MODEL` env var (`qwen` or `ornith`; any other value logs a warning and falls back to the default). When `MODEL` is unset the default is VRAM-based: `ornith` (25.3 GB Q5_K_M, needs a 30GB+ GPU) at VRAM >= 30GB, `qwen` below that. An explicit `MODEL=ornith` on a smaller GPU is honored with a warning. Registered models, their HF repos, checkpoint/mmproj file names, and per-VRAM-tier load args live in the `lemonadectl` registry — adding a model is a matter of adding a few entries there.

**hf auth (downloads):** the token reaches `run.sh` as the `HF_TOKEN` env var in both environments (podman `--secret hf_token,type=env,target=HF_TOKEN` in the test harness, RunPod template secret in production). `run.sh` bridges it to a 0600 `/run/hf_token` for the download's duration and passes `--hf-token-file` to `lemonadectl download` — the token never lands on a command line (sudo strips the env var, and argv is visible via `ps`).

**Observed behaviors / gotchas:**
- `MTP` (draft/speculative decoding) is **disabled** with a comment: *"MTP doesn't work well with nvidia and llama-cpp. Performance is bad, let's not use it."*
- CUDA-13 backend needs a host NVIDIA driver major >= 580. `prepare_cuda_compat()` (run.sh) compares the host driver against the CUDA-major floor (525 for CUDA12, 580 for 13); if older, it installs **`cuda-compat-<maj>-<min>` at runtime** (not baked into the image, saves ~109MB) and stages the shim dir at `/run/cuda_compat_dir`. Detection reads `/proc/driver/nvidia/version` (fallback `nvidia-smi`, override `HOST_DRIVER_MAJOR`), and the compat minor is derived from the installed cudart RPM so it stays correct if the image moves CUDA versions. `lemonadectl start` applies that shim to `LD_LIBRARY_PATH`.
- **CUDA version support policy:** the image supports the latest CUDA major and the one before it — currently **13 + 12**. When NVIDIA ships a new major (e.g. 14), the image switches to shipping that plus the previous major (**14 + 13**) and drops the older one (12). This is a *packaging* choice (which CUDA major `llama-cpp`/`lemonade-server` are built against, and therefore which cudart RPM lands in the image); `run.sh`'s runtime detection is version-agnostic and keeps working unchanged. When the tiers shift, update the `min_driver_for_cuda` map in `run.sh` (currently `12 → 525`, `13 → 580`) with the new majors' driver floors, then drop the old entry.
- The `get_gpu_vram()` fallback heuristic table (by GPU name) is commented out — detection now trusts `nvidia-smi`'s reported `memory.total`.
- VRAM split: `<=30GB` → small profile, `>30GB` → large profile (per-model in the lemonadectl registry). Context sizes: qwen 110000 (small) / 128000 (large); ornith 128000 in both tiers.

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
| `/run/cuda_compat_dir` | tmpfs file where run.sh stages the resolved CUDA compat shim dir (set by `prepare_cuda_compat`); `lemonadectl start` reads it and applies to `LD_LIBRARY_PATH` |
| `/root/.ssh/authorized_keys` | Deployed key (`id_rsa.pub`) for root SSH |
| `mock/nvidia-smi` | Fake `nvidia-smi` emulating RTX 4090 / 24GB VRAM for test envs |

## Development Commands

All scripts use `set -euo pipefail`. `bash` only.

| Task | Command |
|------|---------|
| Build image | `bash build.sh` → `podman build -t fedora-lemonade .` |
| Push to GHCR | `bash push-to-ghcr.sh` (tags `localhost/fedora-lemonade:latest` → `ghcr.io/enricotagliavini/fedora-lemonade:latest`) |
| Test image locally | `bash test-podman-locally.sh` (runs detached, maps `2222:22`, mounts `~/.ssh/id_rsa_ovh.pub`, injects `hf_token` secret as the `HF_TOKEN` env var, execs as root) |
| Run on RunPod | build/push the OCI image, then run it on a GPU pod |

**Diagnosing a container:** inspect `/var/log/run.log` (bootstrap/VRAM) and `/var/log/lemonade.log` (server). Verify GPU: `nvidia-smi` present + host driver major >= 580 for CUDA 13.

## Code Conventions & Common Patterns

- **Shell style:** `#!/bin/bash`, `set -euo pipefail`, functions grouped by purpose, `&&/||` chains in `RUN` layers, `ed25519` ssh-keygen, `chmod +x` on copied scripts.
- **Idempotency:** `lemonadectl start` reads the shim dir staged by run.sh at `$CUDA_COMPAT_STATE` (`/run/cuda_compat_dir`) and applies it to `LD_LIBRARY_PATH`, guarding against dup entries with a `if [[ ":$LD_LIBRARY_PATH:" != *":$compat_path:"* ]]` test (multi-source compat dirs deduped).
- **Model registry:** per-model facts (HF repo, checkpoint/mmproj file names, local dir, per-VRAM-tier load args) live in the associative-array registry at the top of `lemonadectl`, keyed by slug; `run.sh` only passes the slug + detected VRAM.
- **Backgrounding + logging:** services are `&`-ed while the script's own stdout is redirected (`exec >> /var/log/... 2>&1`), then a hard `sleep 8h` safety-net kills `%1 %2`.
- **Lemonade config via `config set`:** namespace `llamacpp.*` → keys `cuda_bin`, `cpu_bin`, `backend` (`cuda`|`system`), `args`. These configure the CUDA-backed llama-server entrypoint.
- **Error handling:** relies on `set -e` + `command -v ... &>/dev/null || {...}` guards; `nvidia-smi` failures are tolerated (defaults to `0` GB → CPU fallback path).
- **Self-built RPMs:** `dnf install lemonade-server llama-cpp` resolves from the author's custom yum repo (`ai-custom-infra.repo`), not upstream packages — edit that URL to repoint the build at a different RPM set.
- **No async/dependency-injection/state-machine patterns** — this is orchestration config, not app logic.

## Important Files

| File | Role |
|------|------|
| `Dockerfile` | Fedora 44 base; the CUDA 44 yum repo (so `dnf install cuda-compat-*`, plus the `libcublas`/`libcudart` sonames that `llama-cpp` Requires, resolve at build time), `openssh-server`, `lemonade-server` + `llama-cpp` from the `ai-custom-infra` custom RPM repo; exposes :22; CMD `/app/run.sh`. `libcublas` + `cuda-cudart` arrive automatically as `llama-cpp` deps (no explicit install); `cuda-compat` is installed at runtime by run.sh, not baked in (saves ~109MB) |
| `run.sh` | Entrypoint: VRAM detect, model selection (`MODEL` env, VRAM-based default), sshd, cache setup, `lemonadectl download` (foreground) → `lemonadectl start &`, lemonade `config set`, `lemonadectl load`, safety net |
| `lemonadectl` | Model registry + CLI: `models`, `download <model> [--mmproj] [--hf-token-file PATH]`, `start` (applies the compat shim staged by run.sh at `$CUDA_COMPAT_STATE` → `exec lemond`), `load <model> --vram <GB>` |
| `build.sh` | One-line `podman build` |
| `push-to-ghcr.sh` | Tag+push to GHCR (`-x` verbose) |
| `test-podman-locally.sh` | Local detached run w/ SSH + key mount |
| `mock/nvidia-smi` | GPU-less testing shim (RTX 4090 / 24GB) |
| `id_rsa.pub` | Deployment SSH public key |

## Runtime/Tooling Preferences

- **Container runtime:** Podman. Image is OCI-compliant and meant for RunPod; the Dockerfile uses `docker://registry.fedoraproject.org/fedora-minimal:44` as base and `push-to-ghcr.sh` tags `localhost/...`.
- **Package management:** Fedora `dnf` inside the image. Lemonade and llama-cpp are **locally built RPMs** from the author's GitHub-hosted repo (`ai-custom-infra.repo`) — treat these as first-party builds, not upstream packages.
- **Tooling:** bash scripting idioms; `nvidia-smi` `--query-gpu=count|name|memory.total --format=csv` parsing; host-driver read from `/proc/driver/nvidia/version` (fallback `nvidia-smi`, override `HOST_DRIVER_MAJOR`); image CUDA version from `rpm -qa 'cuda-cudart-*'`; `bc` for integer VRAM math; `compgen -G` for globbing cuda compat dirs.

## Testing & QA

- **No unit/integration test framework** for the shell logic. QA is done by running the image.
- **`test-podman-locally.sh`:** spins the image detached, maps SSH `2222:22`, mounts `~/.ssh/id_rsa_ovh.pub`, injects the `hf_token` podman secret as the `HF_TOKEN` env var (hf auth; `run.sh` bridges it to a 0600 file for `lemonadectl download`), forwards `MODEL` to the container when set in the shell env, opens a root shell, then cleans up. Use it to sanity-check that the image boots and the model loads.
- **`mock/nvidia-smi`:** lets you test `get_gpu_vram`/driver paths without an NVIDIA GPU. It caches output to `/tmp/nvidia-smi.mock` (+ `.mb` for the raw MB value) on first run and dispatches the `--query-gpu=...`/`--format=csv` flags used by `run.sh`.
- **Coverage expectation:** informal (smoke-run the container); there is no test suite to extend.
