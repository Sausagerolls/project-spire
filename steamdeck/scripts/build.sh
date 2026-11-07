#!/bin/bash
# Builds the SDK and the game for the Steam Deck inside the "spire" container.
#   steamdeck/scripts/build.sh          SDK, codegen if needed, game
#   JOBS=3 steamdeck/scripts/build.sh   fewer compile jobs (each can use about 2 GB)
set -euo pipefail
source "$(dirname "$0")/common.sh"
if [ -z "${CONTAINER_ID:-}" ] && command -v distrobox >/dev/null; then
  exec distrobox enter spire -- "$0" "$@"
fi
jobs="${JOBS:-4}"
flags="-march=znver2"
compilers=(-DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++
           -DCMAKE_LINKER_TYPE=LLD -DCMAKE_C_FLAGS="$flags" -DCMAKE_CXX_FLAGS="$flags")

echo "== SDK"
# The SDK's presets are multi-config: pick Release when building and installing.
cmake --preset linux-amd64 -S "$sdk_src" "${compilers[@]}" >/dev/null
cmake --build "$sdk_src/out/build/linux-amd64" --config Release -j "$jobs"
cmake --install "$sdk_src/out/build/linux-amd64" --config Release --prefix "$sdk_install" >/dev/null

echo "== Game files"
test -f "$disc/default.xex" || { echo "Run steamdeck/scripts/extract_disc.sh first" >&2; exit 1; }
# Codegen and the build read the disc files from the project folder (git-ignored).
ln -f "$disc/default.xex" "$game_src/default.xex" 2>/dev/null || cp "$disc/default.xex" "$game_src/default.xex"
[ -e "$game_src/data" ] || ln -s "$disc/data" "$game_src/data"

echo "== Codegen"
if [ ! -f "$game_src/generated/default/codegen.stamp" ]; then
  (cd "$game_src" && "$sdk_install/bin/rexglue" codegen fable_2_manifest.toml)
fi

echo "== Game"
cmake --preset deck-release -S "$game_src" \
  -DCMAKE_PREFIX_PATH="$sdk_install" -Drexglue_DIR="$sdk_install/lib/cmake/rexglue" \
  -DFABLE2_ENABLE_REMOTE_CONTROL=ON >/dev/null
cmake --build "$build_dir" -j "$jobs" --target fable_2
echo "Built $build_dir/fable_2"
