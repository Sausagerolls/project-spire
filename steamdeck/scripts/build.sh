#!/bin/bash
# Builds the SDK and the game for Linux x86-64 inside the "spire" container.
#   scripts/build.sh          SDK (install to ~/spire/sdk-install), codegen if needed, game
#   JOBS=3 scripts/build.sh   fewer compile jobs (each can use about 2 GB)
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "${CONTAINER_ID:-}" ] && command -v distrobox >/dev/null; then
  exec distrobox enter spire -- "$0" "$@"
fi
jobs="${JOBS:-4}"
sdk="$here/src/rexglue-sdk"
game="$here/src/Fable-2-Recomp"
flags="-march=znver2"
compilers=(-DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++
           -DCMAKE_LINKER_TYPE=LLD -DCMAKE_C_FLAGS="$flags" -DCMAKE_CXX_FLAGS="$flags")

echo "== SDK"
cmake --preset linux-amd64-release -S "$sdk" "${compilers[@]}" >/dev/null
cmake --build "$sdk/out/build/linux-amd64-release" -j "$jobs"
cmake --install "$sdk/out/build/linux-amd64-release" --prefix "$here/sdk-install" >/dev/null

echo "== Game files"
test -f "$here/game/default.xex" || { echo "Run scripts/extract_disc.sh first" >&2; exit 1; }
# The project reads the disc files from its own folder (they're git-ignored).
ln -f "$here/game/default.xex" "$game/default.xex" 2>/dev/null || cp "$here/game/default.xex" "$game/default.xex"
[ -e "$game/data" ] || ln -s "$here/game/data" "$game/data"

echo "== Codegen"
if [ ! -f "$game/generated/default/codegen.stamp" ]; then
  (cd "$game" && "$here/sdk-install/bin/rexglue" codegen fable_2_manifest.toml)
fi

echo "== Game"
cmake --preset linux-amd64-release -S "$game" "${compilers[@]}" \
  -DCMAKE_PREFIX_PATH="$here/sdk-install" -Drexglue_DIR="$here/sdk-install/lib/cmake/rexglue" \
  -DFABLE2_ENABLE_REMOTE_CONTROL=ON >/dev/null
cmake --build "$game/out/build/linux-amd64-release" -j "$jobs" --target fable_2
echo "Built $game/out/build/linux-amd64-release/fable_2"
