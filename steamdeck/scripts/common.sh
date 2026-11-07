# Shared paths for the Steam Deck scripts. Sourced, not run.
#   repo        this repository (game/, sdk/, launcher/, steamdeck/)
#   SPIRE_HOME  where the player's disc files and the installed SDK go
#               (default ~/spire); nothing in it is ever committed
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SPIRE_HOME="${SPIRE_HOME:-$HOME/spire}"
game_src="$repo/game"
sdk_src="$repo/sdk"
sdk_install="$SPIRE_HOME/sdk-install"
disc="$SPIRE_HOME/game"
build_dir="$game_src/out/build/deck-release"
