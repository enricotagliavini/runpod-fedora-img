#!/bin/bash

set -euo pipefail

podman build -t fedora-lemonade .
podman image prune -f
