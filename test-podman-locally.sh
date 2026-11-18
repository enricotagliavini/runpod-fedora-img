#!/bin/bash
set -euo pipefail

# Local debugging harness for the fedora-lemonade image.
#
# On any failure (set -e), the script exits here — before the final `trap - EXIT`
# below — so this EXIT trap still runs: dump the container's logs, then remove it.
# A clean run reaches that last line, disarms the trap, and exits silently.
#
#   podman logs fedora-lemonade-test
#   ssh -p 2222 root@localhost   # -> cat /var/log/run.log /var/log/lemonade.log
#
# The podman invocation is written once (RUN_ARGS) and reused verbatim; only the
# launch vs. cleanup differs.
#
# IMPORTANT: no --rm. Without it, the container keeps its tee'd
# /var/log/run.log and /var/log/lemonade.log on disk after it stops or crashes,
# so `podman logs` above still finds them instead of hitting an empty container.

NAME="fedora-lemonade-test"
# Shared run flags; the `podman run ... fedora-lemonade` line is written once here.
# The hf_token secret (podman secret store) is injected as the HF_TOKEN env var
# (same mechanism as RunPod secrets) so the hf CLI runs authenticated (higher
# rate limits); run.sh bridges it to lemonadectl as a file.
RUN_ARGS=(-d -p 2222:22 --secret hf_token,type=env,target=HF_TOKEN --name "$NAME")

# Forward MODEL (qwen|ornith) when set in this shell, so a non-default model
# can be tested without rebuilding the image; left unset otherwise, in which
# case run.sh falls back to its VRAM-based default.
if [[ -n "${MODEL:-}" ]]; then
    RUN_ARGS+=(-e "MODEL=$MODEL")
fi

# Best-effort cleanup: never trips set -e, so the happy path stays silent even
# if rm hiccups. Called by the happy path and, after logs, by the EXIT trap.
cleanup() {
    podman rm -f "$NAME" 2>/dev/null || true
}

trap 'podman logs "$NAME" 2>/dev/null || true; cleanup' EXIT

# Launch in the background (no --rm), then drop into a login shell for interactive
# debugging. run.sh stays up until its 8h safety net; Ctrl-C tears it down (and
# the EXIT trap prints the logs it produced).
podman run "${RUN_ARGS[@]}" fedora-lemonade
podman exec -it -u 0 "$NAME" /bin/bash -l
podman kill "$NAME"
cleanup

# Clean run: drop the trap so this final exit prints no logs.
trap - EXIT
