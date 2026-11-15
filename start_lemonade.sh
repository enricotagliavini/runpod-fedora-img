#!/bin/bash

# Same as run.sh: persist to the file AND forward live to the container's
# stdout/stderr so `podman logs` and attached runs capture the server output too.
exec > >(tee -a /var/log/lemonade.log) 2>&1

# Download the GGUF checkpoints into the extra_models_dir folder BEFORE lemond starts, so
# the pre-pulled model is on disk the moment Lemonade scans the directory at startup.
# Runs as the `lemonade` user (no root). The optional `--mmproj` flag also fetches the
# vision projection so the model is registered with the `vision` label.
HF_MODEL_REPO="unsloth/Qwen3.8-27B-GGUF"
HF_MODEL_DIR="/var/cache/huggingface/Qwen3.8-27B-GGUF-UD-Q5_K_S"
CHECKPOINT="Qwen3.8-27B-UD-Q5_K_S.gguf"
if [[ "${1:-}" == "--mmproj" ]]; then
    CHECKPOINT="$CHECKPOINT mmproj-BF16.gguf"
    echo "[download] fetching $HF_MODEL_REPO:$CHECKPOINT"
fi

if command -v hf &>/dev/null; then
    mkdir -p "$HF_MODEL_DIR"
    echo "[download] hf download $HF_MODEL_REPO $CHECKPOINT -> $HF_MODEL_DIR"
    hf download "$HF_MODEL_REPO" $CHECKPOINT --local-dir "$HF_MODEL_DIR" || {
        echo "[download] FAILED for $HF_MODEL_REPO:$CHECKPOINT"
        exit 1
    }
fi

# keep the model folder tidy (huggingfile leaves a download metadata .cache/ dir it ignores)
rm -rf "$HF_MODEL_DIR/.cache"

REQUIRED_CUDA13_DRIVER=580

function run_lemonade() {
    export RUNTIME_DIRECTORY=/run/lemonade
    export STATE_DIRECTORY=/var/lib/lemonade
    export CACHE_DIRECTORY=/var/cache/lemonade
    export HF_HOME=/var/cache/lemonade/huggingface

    exec /usr/bin/lemond
}

# 1. Ensure nvidia-smi is available
if ! command -v nvidia-smi &> /dev/null; then
    echo "[CUDA-Check] nvidia-smi not found. Skipping driver version check."
    run_lemonade
fi

# 2. Extract host driver major version
HOST_DRIVER_MAJOR=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1 | cut -d'.' -f1)

if [[ -n "$HOST_DRIVER_MAJOR" && "$HOST_DRIVER_MAJOR" -lt "$REQUIRED_CUDA13_DRIVER" ]]; then
    # 3. Dynamically discover installed CUDA compat directories (sorted highest version first)
    COMPAT_PATH=$(compgen -G "/usr/local/cuda-13*/compat" | sort -rV | head -n1)

    if [[ -n "$COMPAT_PATH" && -d "$COMPAT_PATH" ]]; then
        echo "[CUDA-Check] Host driver ($HOST_DRIVER_MAJOR) < $REQUIRED_CUDA13_DRIVER. Enabling compat layer: $COMPAT_PATH"

        # Avoid duplicating entries if sourced multiple times
        if [[ ":$LD_LIBRARY_PATH:" != *":$COMPAT_PATH:"* ]]; then
            export LD_LIBRARY_PATH="$COMPAT_PATH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        fi
    else
        echo "[CUDA-Check] Warning: Host driver ($HOST_DRIVER_MAJOR) requires compat layer, but no /usr/local/cuda-13*/compat directory was found!"
    fi
else
    echo "[CUDA-Check] Host driver ($HOST_DRIVER_MAJOR) natively supports CUDA 13. No compat layer needed."
fi

run_lemonade
