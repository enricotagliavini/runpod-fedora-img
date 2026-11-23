# fedora-lemonade

An OCI image that turns a GPU instance into a self-hosted LLM inference server.
It bundles **Lemonade** and **llama-cpp**, downloads one of a few pre-selected
models, and serves it over SSH. Designed to run on **RunPod** GPUs.

- Base image: Fedora 44
- GPU backend: `llama-cpp` on CUDA 13 (NVIDIA driver ≥ 580)
- Service: Lemonade's `lemond` server, exposed over SSH (port 22)
- Package source: Lemonade and llama-cpp are self-built RPMs from the author's
  GitHub-hosted yum repo (see `Dockerfile`)

Deep technical details, the model registry, and development notes live in
[`AGENTS.md`](AGENTS.md).

## Models

The image ships with two models (see [`lemonadectl`](lemonadectl) for the
registry):

| Model   | Checkpoint                     | VRAM tier | Notes |
|---------|--------------------------------|-----------|-------|
| `qwen`  | Qwen3.8-27B-UD-Q5_K_S          | any (≤30GB and larger) | default on smaller GPUs |
| `ornith`| Ornith-1.5-35B-Q5_K_M (25.3 GB)| 30GB+     | default only on 30GB+ GPUs |

The vision projection (`mmproj`, for the `vision` label) is downloaded only when
the GPU has more than 30GB of VRAM. Note: MTP/speculative decoding is also disabled
when running on GPUs with less VRAM to let the model fit.

## Architecture: how it works at boot

`run.sh` (the entrypoint) runs this pipeline on every container start:

```
podman build .                 build.sh -> fedora-lemonade (OCI image)
        |
        v
podman run fedora-lemonade     # run.sh (entrypoint, WORKDIR /app)
        |
  1. get_gpu_vram()            detect VRAM via nvidia-smi (memory.total)
  2. choose MODEL              MODEL env var, else VRAM-based default (ornith @ ≥30GB, qwen otherwise)
  3. /usr/bin/sshd -D &        SSH on :22 (public key baked into the image: id_rsa.pub)
  4. prepare cache dirs       /var/cache/{huggingface,lemonade}... (owned by user lemonade)
  5. cuda compat gate         host driver < 580? install cuda-compat-13-<min> at runtime (not baked in), stage its dir
  6. lemonadectl download     download GGUF checkpoints (foreground, blocks until on disk)
  7. lemonadectl start &       background the lemond server
  8. wait for server ready
  9. lemonade config set ...   point the server at the models + cuda backend
  10. lemonadectl load         load the chosen model with a per-VRAM-tier profile
        |
        v
  safety net: sleep 8h; kill the container (so a forgotten run does not drain funding)
```

Model selection is deliberately simple: pick one model per container via the
`MODEL` environment variable (`qwen` or `ornith`), or let it choose by VRAM.

## Quickstart: build

```bash
podman build -t fedora-lemonade .
```

(`build.sh` is a one-liner wrapper around the command above.)

Build output is the `fedora-lemonade` image, deployable on any GPU pod.

**Package-pollution workaround:** the NVIDIA CUDA repo ships
`datacenter-gpu-manager-*-cuda*-cublas` packages that advertise a `libcublas`
provide they don't actually ship. DNF can grab one to satisfy the real
`libcublas13` dependency, and then the library is missing at runtime. So the
Dockerfile appends `excludepkgs=datacenter-gpu-manager-*-cuda*-cublas` into the
downloaded `/etc/yum.repos.d/cuda-fedora44.repo` before installing. This is a
stopgap: once NVIDIA fixes the fake `libcublas` provide, drop the line (and the
two Dockerfile comments) and it can be removed entirely.

## Run on RunPod

The standard flow:

1. **Create a GPU template** with enough VRAM for your model (30GB+ for `ornith`).
2. **Build and push** the image from the template (as a Run Command):
   ```bash
   bash build.sh && bash push-to-ghcr.sh
   ```
   This pushes to `ghcr.io/enricotagliavini/fedora-lemonade:latest`.
3. **Start the container** (as a second Run Command / Run Template). Provide the
   HuggingFace token as a RunPod **Secret** named `HF_TOKEN` so the download can
   authenticate; to force the use of a model, regardless of the available VRAM
   set `MODEL`, when unset a default is picked based on VRAM.

The public key (`id_rsa.pub`, committed in the repo) is baked into
`/root/.ssh/authorized_keys`, so SSH in with the matching private key:

Logs are streamed live with `podman logs -f fedora-lemonade` (when running locally)
and persisted to `/var/log/run.log` (bootstrap + VRAM) and `/var/log/lemonade.log` (the server).
The container auto-shuts down after an 8-hour safety-net sleep.

## Run locally (test the image without RunPod)

[`test-podman-locally.sh`](test-podman-locally.sh) spins the image up detached,
maps SSH `2222:22`, mounts your key (`~/.ssh/id_rsa_ovh.pub`), injects the
`hf_token` podman secret as the `HF_TOKEN` env var, and drops you into a shell:

```bash
bash test-podman-locally.sh
```

If you set `MODEL` in your shell, it is forwarded to the container. During a
clean run the container stays up until its 8-hour safety net; `Ctrl-C` tears it
down and dumps the logs (see the script header for why there is no `--rm`).

## Configuration

| Setting        | How it's set | Effect |
|----------------|--------------|--------|
| Model           | `MODEL` env var (`qwen`\|`ornith`) | Which model is downloaded and loaded |
| GPU profile     | Detected from VRAM | ≤30GB → small, >30GB → large (context size, mmproj, vision) |
| HuggingFace auth| `HF_TOKEN` env var | Passes the token to `lemonadectl download` as a 0600 file |
| NVIDIA driver    | Host driver major version | CUDA 13 backend needs driver ≥ 580; if the host driver is older, `cuda-compat-13-<min>` is installed at runtime and its shim is prepended to `LD_LIBRARY_PATH` |

The per-model facts (HF repo, checkpoint files, local dir, and per-VRAM-tier
load args) live in the model registry in [`lemonadectl`](lemonadectl): adding a
model means adding a few entries there. See [`AGENTS.md`](AGENTS.md) for the full
VRAM split and context sizes.

## Project layout

| File | Role |
|------|------|
| `Dockerfile` | Fedora 44 base; CUDA libs, `lemonade-server` + `llama-cpp`, SSH key |
| `run.sh` | Entrypoint: VRAM detection, model selection, sshd, download, load |
| `lemonadectl` | Model registry + CLI: `models`, `download`, `start`, `load` |
| `build.sh` | One-line `podman build` |
| `push-to-ghcr.sh` | Tag + push to GHCR |
| `test-podman-locally.sh` | Local detached run with SSH + secret injection |
| `mock/nvidia-smi` | Fake `nvidia-smi` for GPU-less testing |
| `id_rsa.pub` | Deployment SSH public key (baked into the image) |

## License

[GPL-3.0](LICENSE).
