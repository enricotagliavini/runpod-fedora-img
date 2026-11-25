#!/bin/bash

set -euo pipefail

# if you need to login first use
# podman login ghcr.io

podman tag localhost/fedora-lemonade:latest ghcr.io/enricotagliavini/fedora-lemonade:latest
podman push ghcr.io/enricotagliavini/fedora-lemonade:latest

podman image prune -f

