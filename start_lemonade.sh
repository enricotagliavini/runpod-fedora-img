#!/bin/bash

exec >> /var/log/lemonade.log 2>&1

REQUIRED_CUDA13_DRIVER=580

function run_lemonade() {
    export RUNTIME_DIRECTORY=/run/lemonade
    export STATE_DIRECTORY=/var/lib/lemonade
    export CACHE_DIRECTORY=/var/cache/lemonade
    export HF_HOME=/var/cache/huggingface

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
