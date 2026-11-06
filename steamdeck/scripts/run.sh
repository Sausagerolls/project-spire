#!/bin/bash
# Starts the game (one instance only). Extra arguments go to the game, e.g.
#   scripts/run.sh --gpu_backend=vulkan --fullscreen=true
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
game="$here/src/Fable-2-Recomp"
if pgrep -x fable_2 >/dev/null; then echo "fable_2 is already running" >&2; exit 1; fi
if [ -z "${CONTAINER_ID:-}" ] && command -v distrobox >/dev/null; then
  exec distrobox enter spire -- "$0" "$@"
fi
exec "$game/out/build/linux-amd64-release/fable_2" --game_data_root="$game" "$@"
