#!/bin/bash

set -euo pipefail

exec >> /var/log/run.log 2>&1

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

/usr/bin/sshd -D &

mkdir -p /var/cache/huggingface /root/.config/htop
chown lemonade:lemonade /var/cache/huggingface

# start lemonade here
mkdir /var/cache/lemonade
touch /var/log/lemonade.log
chown lemonade:lemonade /var/cache/lemonade /var/log/lemonade.log
sudo -u lemonade /app/start_lemonade.sh &
lemonade config set llamacpp.cuda_bin=/usr/bin/llama-server
lemonade config set llamacpp.backend=cuda || lemonade config set llamacpp.backend=system
lemonade config set llamacpp.args="--flash-attn on"
lemonade config set llamacpp.cpu_bin=/usr/bin/llama-server

# MTP doesn't work well with nvidia and llama-cpp. Performance is bad, let's not use it
# lemonade pull unsloth/Qwen3.8-27B-GGUF:UD-Q5_K_S

if [[ "$VRAM_GB" -le 30 ]]; then
    # 24GB or less (or no GPU)
    echo "Using 24GB GPU profile"
    lemonade pull user.Qwen3.8-27B-GGUF-UD-Q5_K_S \
      --source huggingface \
      --checkpoint main unsloth/Qwen3.8-27B-GGUF:UD-Q5_K_S \
      --checkpoint mmproj unsloth/Qwen3.8-27B-GGUF:mmproj-BF16.gguf \
      --recipe llamacpp \
      --label chat \
      --label vision

    # with this you run directly using lemonade
    lemonade load Qwen3.8-27B-GGUF-UD-Q5_K_S --llamacpp-args='--cache-type-k q8_0 --cache-type-v q8_0 --spec-type none' --ctx-size 110000 --save-options
else
    # More than 30GB
    echo "Using 30GB+ GPU profile"
    lemonade pull unsloth/Qwen3.8-27B-GGUF:UD-Q5_K_S
    lemonade load Qwen3.8-27B-GGUF-UD-Q5_K_S --llamacpp-args='--cache-type-k q8_0 --cache-type-v q8_0 --spec-draft-n-max 2' --ctx-size 250000 --save-options
fi

# otherwise uncomment the following
# pkill lemond
# sleep 5
# pkill -9 lemond
# sudo -u lemonade -- llama-server -m /var/cache/huggingface/hub/models--unsloth--Qwen3.8-27B-GGUF/snapshots/4ca720788d1e01f1bff70c033e0d0028fd02e502/Qwen3.8-27B-UD-Q5_K_S.gguf --ctx-size 100000 --port 8001 --jinja --metrics --mmproj /var/cache/huggingface/hub/models--unsloth--Qwen3.8-27B-GGUF/snapshots/4ca720788d1e01f1bff70c033e0d0028fd02e502/mmproj-BF16.gguf --cache-type-k q8_0 --cache-type-v q8_0 --flash-attn on --spec-type draft-mtp --parallel 1 &> /var/log/llama-server.log &
# safety net, don't let the container run for more than 12 hours
sleep 8h

kill %1 %2
sleep 20
kill -9 %1 %2
