#!/bin/bash
# Copies default.xex and data/ from your own Fable II disc image into ~/spire/game.
# Only the supported releases (constants/game_versions.json) are accepted.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
iso="${1:?usage: scripts/extract_disc.sh <image.iso>}"
src="$here/src/Fable-2-Recomp"
toolkit="$src/macos/ProjectSpire/toolkit"
versions="$src/constants/game_versions.json"
mkdir -p "$here/game"
python3 -I "$toolkit/spire_disc.py" check "$iso" "$versions"
python3 -I "$toolkit/spire_disc.py" extract "$iso" "$versions" "$here/game" | grep -v PROGRESS || true
test -f "$here/game/default.xex" && echo "Extracted to $here/game"
