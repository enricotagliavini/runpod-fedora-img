#!/bin/bash

set -euo pipefail

# Tee combined output to the log file AND the container's stdout/stderr.
# The file keeps the persistent debug log (tailable over SSH); the fd pass-through
# lets `podman logs` and attached runs show the same output live.
exec > >(tee -a /var/log/run.log) 2>&1

# Detect GPU and get vRAM information
get_gpu_vram() {
    local vram_gb=0
    local gpu_count
    local gpu_name
    local mem_mb

    command -v nvidia-smi &>/dev/null || { echo 0 ; return ; }
    
    gpu_count=$(nvidia-smi --query-gpu=count --format=csv 2>/dev/null || echo "0")
    
    if [[ "$gpu_count" != "0" ]]; then
        mem_mb=$(nvidia-smi --query-gpu=memory.total --format=csv 2>/dev/null | tail -1 | grep -oP '\d+' || echo "0")
        
        if [[ -n "$mem_mb" && "$mem_mb" != "0" ]]; then
            vram_gb=$(echo "scale=0; $mem_mb / 1024" | bc 2>/dev/null || echo "0")
        fi
        
        # if [[ "$vram_gb" == "0" ]]; then
        #     gpu_name=$(nvidia-smi --query-gpu=name --format=csv 2>/dev/null | head -1 | awk '{print $2}' || echo "")
        #     case "$gpu_name" in
        #         *3090*|*A40*|*A100*|*H100*|*RTX4090*|*RTX6000*|*RTX5000*) vram_gb=24 ;;
        #         *RTX4080*|*RTX3080*|*A30*|*V100*|*T4*|*P40*|*P100*|*RTX5000*|*RTX4000*) vram_gb=24 ;;
        #         *RTX4070*|*RTX3070*|*RTX3060*|*RTX2080*|*A20*|*T100*|*P20*|*T20*|*M40*|*M60*|*RTX4000*|*A4000*|*A2000*) vram_gb=12 ;;
        #         *RTX3060*|*RTX2060*|*GTX1660*|*RTX3050*|*T2000*|*A500*|*A10*|*A2*) vram_gb=10 ;;
        #         *) vram_gb=24 ;;
        #     esac
        # fi
    fi
    
    echo "$vram_gb"
}

# ---------------------------------------------------------------------------
# CUDA 13 compat-layer gate
#
# The llama-cpp CUDA backend needs CUDA 13, whose userspace libs require a host
# NVIDIA driver of major >= 580. Every host in this deployment ships at least a
# CUDA-12 driver (major >= 525), so the only gap worth bridging is
# image=CUDA13 vs host driver 525-579. When that gap exists we install
# cuda-compat-<maj>-<min> at runtime (it is deliberately NOT baked into the
# image, to save ~109MB) and put its shim libcudart on LD_LIBRARY_PATH so lemond
# can start on the older driver.
#
# Detection is self-correcting: the compat minor is derived from the cudart RPM
# actually installed in the image (pulled in by llama-cpp), so it stays right if
# the image ever moves to CUDA 12/14.
# ---------------------------------------------------------------------------

# tmpfs file where the resolved compat shim dir is staged for 'lemonadectl start'
# (run.sh as root decides/stages it; lemonadectl as the lemonade user applies it,
# because sudo strips LD_LIBRARY_PATH before we get there). Cleaned each boot.
HOST_DRIVER_STATE="/run/cuda_compat_dir"

# Host driver major version. Prefer /proc/driver/nvidia/version (no nvidia-smi
# dependency); the driver line format varies across driver releases, so pull the
# major from the first <major>.<minor> token rather than a fixed column.
# HOST_DRIVER_MAJOR is an optional deterministic override (used for testing).
host_driver_major() {
    if [[ -n "${HOST_DRIVER_MAJOR:-}" ]]; then
        echo "${HOST_DRIVER_MAJOR}"
        return
    fi
    local ver=""
    if [[ -r /proc/driver/nvidia/version ]]; then
        ver=$(head -n1 /proc/driver/nvidia/version | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || true)
    fi
    if [[ -z "$ver" ]]; then
        # Fallback: nvidia-smi's "Driver Version: X.Y" (only a bare number is usable).
        ver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1 || true)
    fi
    echo "${ver%%.*}"
}

# Image CUDA version parsed from the installed cudart RPM, e.g.
# cuda-cudart-13-5-13.5.37 -> "13.5". Empty if no cudart RPM is present.
image_cuda_version() {
    local pkg fam major minor
    pkg=$(rpm -qa 'cuda-cudart-*' 2>/dev/null | sort -V | tail -n1 || true)
    if [[ -z "$pkg" ]]; then
        echo ""
        return
    fi
    fam="${pkg#cuda-cudart-}"      # strip "cuda-cudart-" -> "13-5-13.5.37"
    major="${fam%%-*}"             # "13"
    fam="${fam#*-}"                # strip "13-" -> "5-13.5.37"
    minor="${fam%%-*}"             # "5"
    echo "${major}.${minor}"
}

# Minimum host driver major version required for a given CUDA major version.
min_driver_for_cuda() {
    case "$1" in
        12) echo 525 ;;
        *)  echo 580 ;;           # 13+: CUDA 13.x requires driver major >= 580
    esac
}

# Decide whether the host driver can run the image's CUDA backend natively, and if
# not, install the compat shim at runtime and stage its dir for 'lemonadectl start'.
prepare_cuda_compat() {
    # Each boot starts from a clean slate (tmpfs; /run is wiped on restart).
    rm -f "$HOST_DRIVER_STATE"

    local image_cuda image_cuda_major image_cuda_minor drv drv_min compat_pkg compat_path
    image_cuda=$(image_cuda_version)
    if [[ -z "$image_cuda" ]]; then
        echo "[CUDA-Compat] Could not detect image CUDA version (no cudart RPM found). Skipping compat setup."
        return 0
    fi
    image_cuda_major="${image_cuda%%.*}"
    image_cuda_minor="${image_cuda#*.}"

    drv=$(host_driver_major)
    if ! [[ "$drv" =~ ^[0-9]+$ ]]; then
        echo "[CUDA-Compat] Could not determine host driver major version ('$drv'). Skipping compat setup."
        return 0
    fi

    drv_min=$(min_driver_for_cuda "$image_cuda_major")
    compat_pkg="cuda-compat-${image_cuda_major}-${image_cuda_minor}"

    if [[ "$drv" -ge "$drv_min" ]]; then
        echo "[CUDA-Compat] Host driver ($drv) natively supports CUDA ${image_cuda}. No compat layer needed."
        return 0
    fi

    echo "[CUDA-Compat] Host driver ($drv) < $drv_min for CUDA ${image_cuda}: installing ${compat_pkg} at runtime..."
    dnf install -y "$compat_pkg"
    compat_path=$(compgen -G "/usr/local/cuda-${image_cuda_major}-${image_cuda_minor}/compat" | sort -rV | head -n1 || true)

    if [[ -n "$compat_path" && -d "$compat_path" ]]; then
        printf '%s' "$compat_path" > "$HOST_DRIVER_STATE"
        chmod 644 "$HOST_DRIVER_STATE"
        echo "[CUDA-Compat] Compat layer staged: $compat_path (lemonadectl start will put it on LD_LIBRARY_PATH)."
    else
        echo "[CUDA-Compat] Warning: installed ${compat_pkg} but no /usr/local/cuda-${image_cuda_major}-${image_cuda_minor}/compat directory was found!"
    fi
}

VRAM_GB=$(get_gpu_vram)
echo "Detected GPU with ${VRAM_GB} GB VRAM"

# Which network to download/load: the MODEL env var (qwen|ornith) overrides
# the default; any other value is a warning, not an error. The default
# depends on VRAM: ornith's 25.3 GB checkpoint needs a 30GB+ GPU, so it is
# the default only there; qwen covers smaller GPUs (and no GPU at all).
if [[ "$VRAM_GB" -ge 30 ]]; then
    DEFAULT_MODEL="ornith"
else
    DEFAULT_MODEL="qwen"
fi
MODEL="${MODEL:-$DEFAULT_MODEL}"
case "$MODEL" in
    ornith)
        if [[ "$VRAM_GB" -lt 30 ]]; then
            echo "WARNING: MODEL=ornith was set explicitly, but ornith needs a 30GB+ GPU and only ${VRAM_GB} GB were detected - loading it anyway, it may not fit in VRAM"
        fi
        ;;
    qwen)
        ;;
    *)
        echo "WARNING: MODEL='${MODEL}' is not 'qwen' or 'ornith', using default '${DEFAULT_MODEL}'"
        MODEL="$DEFAULT_MODEL"
        ;;
esac
echo "Selected model: ${MODEL} (VRAM: ${VRAM_GB} GB)"

# SSH access. RunPod documents PUBLIC_KEY but, at present, does not actually set
# it (verified), so treat it as optional. SSH_PUBLIC_KEYS is the reliable source:
# its value is base64-encoded because RunPod's UI can't hold newlines in a
# variable, so we base64-decode it here to recover the keys. Keys from PUBLIC_KEY
# (plain text) and SSH_PUBLIC_KEYS are concatenated into /root/.ssh/authorized_keys,
# with the fallback key baked into the image always appended last so there is a
# known-good key to log in with even if the injected keys are flaky or wrong.
# An explicit IGNORE_PUBLIC_KEY (1|yes|true, case-insensitive) bypasses only
# PUBLIC_KEY; SSH_PUBLIC_KEYS is still honored. sshd reads authorized_keys per
# connection, so this only needs to run before anyone authenticates; StrictModes
# wants 700 on ~/.ssh and 600 on authorized_keys.
mkdir -p /root/.ssh
chmod 700 /root/.ssh
shopt -s nocasematch
case "${IGNORE_PUBLIC_KEY:-}" in
    1|yes|true) load_public_key=0 ;;
    *)          load_public_key=1 ;;
esac
shopt -u nocasematch

# Build authorized_keys from PUBLIC_KEY (plain text) then SSH_PUBLIC_KEYS
# (base64-decoded). Concatenating with a trailing newline per source keeps each
# key on its own line even if a source did not already end with one.
authorized_keys_content=""
if [[ "$load_public_key" -eq 1 && -n "${PUBLIC_KEY:-}" ]]; then
    authorized_keys_content+="${PUBLIC_KEY}"$'\n'
fi
if [[ -n "${SSH_PUBLIC_KEYS:-}" ]]; then
    if decoded_keys=$(printf '%s' "$SSH_PUBLIC_KEYS" | base64 -d 2>/dev/null); then
        authorized_keys_content+="${decoded_keys}"$'\n'
    fi
fi
# Always append the baked-in fallback key last: RunPod's key injection is
# unreliable, so authorized_keys must always contain a known-good key.
authorized_keys_content+="$(cat /root/.ssh/fallback_key.pub)"$'\n'
printf '%s' "$authorized_keys_content" > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

/usr/bin/sshd -D &

mkdir -p /var/cache/huggingface /var/cache/lemonade/huggingface /root/.config/htop
touch /var/log/lemonade.log
chown lemonade:lemonade /var/cache/huggingface /var/cache/lemonade /var/log/lemonade.log /var/cache/lemonade/huggingface

# start lemonade here. lemonadectl first downloads the selected model's GGUF
# checkpoints into the extra_models_dir in the foreground (this blocks until the
# model is on disk), and only THEN starts lemond in the background, so the model
# is present before the server scans the directory at startup.
MMPROJ_FLAG=()
if [[ "$VRAM_GB" -gt 30 ]]; then
    # More than 30GB: also fetch the mmproj for the `vision` label — room to spare.
    # (24GB tier: skip the mmproj to save VRAM on a smaller GPU, main checkpoint only.)
    MMPROJ_FLAG=(--mmproj)
fi
# Optional hf auth: the token reaches run.sh as the HF_TOKEN env var (podman
# secret in the test harness, RunPod secret in production). It is bridged to
# lemonadectl as a file path so it never appears on a command line (sudo's
# env_reset strips the env var anyway, and argv is visible via ps for the whole
# download). The 0600 file lives only for the download's duration (if the
# download fails, run.sh exits and the container's /run tmpfs goes with it).
HF_TOKEN_ARGS=()
HF_TOKEN_TMP=""
if [[ -n "${HF_TOKEN:-}" ]]; then
    HF_TOKEN_TMP=/run/hf_token
    (umask 077 && printf '%s' "${HF_TOKEN//[$'\n\r']/}" > "$HF_TOKEN_TMP")
    chown lemonade:lemonade "$HF_TOKEN_TMP"
    HF_TOKEN_ARGS=(--hf-token-file "$HF_TOKEN_TMP")
fi
# Decide whether the host driver can run the image's CUDA backend natively, and,
# if not, install the compat shim (not baked into the image) before lemond starts.
prepare_cuda_compat
sudo -u lemonade /app/lemonadectl download "$MODEL" "${MMPROJ_FLAG[@]}" "${HF_TOKEN_ARGS[@]}"
if [[ -n "$HF_TOKEN_TMP" ]]; then
    rm -f "$HF_TOKEN_TMP"
fi
sudo -u lemonade /app/lemonadectl start &

# Wait for the server to come up (lemond only starts after the download finished).
echo "Waiting for Lemonade server to become ready (up to 15 minutes)..."
for _ in $(seq 1 900); do
    lemonade status >/dev/null 2>&1 && { echo "Lemonade server is ready"; break; }
    sleep 1
done
if ! lemonade status >/dev/null 2>&1; then
    echo "ERROR: Lemonade server did not start within 15 minutes; tearing down."
    kill %1 2>/dev/null || true
    exit 1
fi

# Point the running server at the pre-downloaded models (picked up immediately, no restart).
lemonade config set extra_models_dir=/var/cache/huggingface

lemonade config set llamacpp.cuda_bin=/usr/bin/llama-server
lemonade config set llamacpp.backend=cuda || lemonade config set llamacpp.backend=system
lemonade config set llamacpp.args="--flash-attn on"
lemonade config set llamacpp.cpu_bin=/usr/bin/llama-server

# Load the selected model: per-model llama.cpp args and ctx-size come from the
# lemonadectl registry, profiled by the detected VRAM tier.
/app/lemonadectl load "$MODEL" --vram "$VRAM_GB"

# safety net, don't let the container run indefinitely. If forgetten it should just stop and not drain funding for nothing
sleep 8h

kill %1 %2
sleep 20
kill -9 %1 %2
