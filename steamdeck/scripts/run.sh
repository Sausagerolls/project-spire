#!/bin/bash
# Starts the game (one instance only). Extra arguments go to the game, e.g.
#   steamdeck/scripts/run.sh --fullscreen=true
set -euo pipefail
source "$(dirname "$0")/common.sh"
if pgrep -x fable_2 >/dev/null; then echo "fable_2 is already running" >&2; exit 1; fi
if [ -z "${CONTAINER_ID:-}" ] && command -v distrobox >/dev/null; then
  exec distrobox enter spire -- "$0" "$@"
fi
exec "$build_dir/fable_2" --game_data_root="$disc" "$@"
