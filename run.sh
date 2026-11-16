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

VRAM_GB=$(get_gpu_vram)
echo "Detected GPU with ${VRAM_GB} GB VRAM"

# Which network to download/load: picked via the LEMONADE_MODEL env var.
# The default keeps the previous single-model behavior; `lemonadectl models`
# lists the registry.
MODEL="${LEMONADE_MODEL:-qwen3-27b}"

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
