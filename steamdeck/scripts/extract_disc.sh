#!/bin/bash
# Copies default.xex and data/ from your own Fable II disc image into $SPIRE_HOME/game.
# Only the supported releases (game/constants/game_versions.json) are accepted.
set -euo pipefail
source "$(dirname "$0")/common.sh"
iso="${1:?usage: steamdeck/scripts/extract_disc.sh <image.iso>}"
toolkit="$repo/launcher/toolkit"
versions="$game_src/constants/game_versions.json"
mkdir -p "$disc"
python3 -I "$toolkit/spire_disc.py" check "$iso" "$versions"
python3 -I "$toolkit/spire_disc.py" extract "$iso" "$versions" "$disc" | grep -v PROGRESS || true
test -f "$disc/default.xex" && echo "Extracted to $disc"
