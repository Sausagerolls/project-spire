#!/bin/bash
# Builds Project Spire from the user's own Fable II disc image.
#
# Usage: spire_setup.sh <image.iso> <install_dir>
#
# Runs from the toolkit folder inside Project Spire.app (or a copy of it). The
# toolkit holds the project source, the ReXGlue SDK, CMake and Ninja, but no
# game data or game code: those come only from the disc, on this Mac.
#
# Output lines for the app (anything else is log text):
#   STEP <number> <total> <title>
#   PROGRESS <fraction 0..1>        progress within the current step
#   ERROR <message>                 then exit non-zero
#   DONE
#
# Install layout:
#   <install_dir>/game/       default.xex and data/ from the disc (the content root)
#   <install_dir>/Project Spire Game.app   the native game
#   <install_dir>/user/       its settings, saves, cache and logs, kept on a rebuild
#   <install_dir>/spire.json  what was installed

set -u
set -o pipefail

TOTAL_STEPS=6
toolkit="$(cd "$(dirname "$0")" && pwd)"
iso="${1:-}"
dest="${2:-}"

fail() {
  echo "ERROR $*"
  exit 1
}
step() {
  echo "STEP $1 $TOTAL_STEPS $2"
}

[ -n "$iso" ] && [ -n "$dest" ] || fail "Usage: spire_setup.sh <image.iso> <install_dir>"
[ -f "$iso" ] || fail "The disc image was not found: $iso"
mkdir -p "$dest" || fail "Can't create the install folder: $dest"
dest="$(cd "$dest" && pwd)"
source_tree="$toolkit/source"
sdk="$toolkit/sdk"
cmake="$toolkit/cmake/bin/cmake"
ninja="$toolkit/bin/ninja"
versions="$source_tree/constants/game_versions.json"
work="$dest/work"
game="$dest/game"
# Keep temporary files with the build, not on the system drive.
export TMPDIR="$work/tmp/"

# --- 1. Tools -------------------------------------------------------------
step 1 "Checking this Mac"
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find clang++ >/dev/null 2>&1; then
  fail "Apple's Command Line Tools are needed to build the game. Install them, then try again."
fi
python=/usr/bin/python3
"$python" -c "import sys; sys.exit(sys.version_info < (3, 8))" 2>/dev/null ||
  fail "Python 3 from Apple's Command Line Tools was not found."
for tool in "$cmake" "$ninja" "$sdk/bin/rexglue"; do
  [ -x "$tool" ] || fail "Project Spire is incomplete: $tool is missing. Download it again."
done
[ "$(uname -m)" = arm64 ] || fail "Project Spire needs a Mac with Apple silicon."
# The disc data, generated code and build objects need about 15 GB at peak.
free_kb=$(df -k "$dest" | awk 'NR==2 {print $4}')
have_game=0
[ -f "$game/default.xex" ] && have_game=1
need_kb=$((15 * 1024 * 1024))
[ "$have_game" = 1 ] && need_kb=$((9 * 1024 * 1024))
if [ "$free_kb" -lt "$need_kb" ]; then
  fail "Not enough free space: $((free_kb / 1024 / 1024)) GB free, about $((need_kb / 1024 / 1024)) GB needed. Choose another location or free up space."
fi
# Each compile job on the generated code can use 1-2 GB of memory.
mem_gb=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
cpus=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || sysctl -n hw.ncpu)
jobs=$(( mem_gb / 3 ))
[ "$jobs" -gt "$cpus" ] && jobs=$cpus
[ "$jobs" -lt 1 ] && jobs=1
[ -n "${SPIRE_JOBS:-}" ] && jobs=$SPIRE_JOBS
echo "Memory ${mem_gb} GB, using $jobs build jobs"

# --- 2. Disc --------------------------------------------------------------
step 2 "Checking the disc"
result=$("$python" -I "$toolkit/spire_disc.py" check "$iso" "$versions") ||
  fail "$(echo "$result" | "$python" -c 'import json,sys; print(json.loads(sys.stdin.read() or "{}").get("message") or "The disc could not be read.")')"
echo "$result"
version_name=$(echo "$result" | "$python" -c 'import json,sys; print(json.load(sys.stdin)["name"])')
version_id=$(echo "$result" | "$python" -c 'import json,sys; print(json.load(sys.stdin)["id"])')

# --- 3. Game files --------------------------------------------------------
step 3 "Copying game files from the disc"
mkdir -p "$game"
# Re-extract unless an earlier run finished copying this same disc.
if [ ! -f "$game/.extracted-$version_id" ]; then
  rm -rf "$game/data" "$game/default.xex" "$game"/.extracted-*
  "$python" -I "$toolkit/spire_disc.py" extract "$iso" "$versions" "$game" |
    while read -r kind done total; do
      if [ "$kind" = PROGRESS ]; then
        echo "PROGRESS $(echo "$done $total" | awk '{printf "%.3f", $1 / $2}')"
      fi
    done || fail "Copying the game files failed. Check that the disc image is complete."
  [ -f "$game/default.xex" ] || fail "Copying the game files failed."
  touch "$game/.extracted-$version_id"
else
  echo "Game files already copied"
fi
echo "PROGRESS 1"

# --- 4. Recompile ----------------------------------------------------------
step 4 "Translating the game code for this Mac"
rm -rf "$work"
mkdir -p "$work/tmp"
cp -R "$source_tree" "$work/source" || fail "Can't copy the project source."
src="$work/source"
# The build reads the disc files in place, and stages its scripts into data/.
# Codegen refuses a symlinked XEX that resolves outside the source tree; a hard link
# (same volume) or a copy is fine.
ln "$game/default.xex" "$src/default.xex" 2>/dev/null || cp "$game/default.xex" "$src/default.xex"
ln -s "$game/data" "$src/data"
(cd "$src" && "$sdk/bin/rexglue" codegen fable_2_manifest.toml) > "$work/codegen.log" 2>&1 ||
  fail "Translating the game code failed. See $work/codegen.log"
echo "PROGRESS 1"

# --- 5. Compile ------------------------------------------------------------
step 5 "Building the game (this takes a while)"
build="$work/build"
"$cmake" -S "$src" -B "$build" -G Ninja \
  -DCMAKE_MAKE_PROGRAM="$ninja" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_C_FLAGS=-march=armv8-a -DCMAKE_CXX_FLAGS=-march=armv8-a \
  -DCMAKE_PREFIX_PATH="$sdk" -Drexglue_DIR="$sdk/lib/cmake/rexglue" \
  -DPython3_EXECUTABLE="$python" \
  -DFABLE2_ENABLE_REMOTE_CONTROL=OFF \
  > "$work/configure.log" 2>&1 || fail "Setting up the build failed. See $work/configure.log"
# Ninja prints [done/total] for each finished command.
"$ninja" -C "$build" -j "$jobs" fable_2 2>&1 | tee "$work/build.log" |
  sed -nu 's/^\[\([0-9]*\)\/\([0-9]*\)\].*/\1 \2/p' |
  while read -r done total; do
    echo "PROGRESS $(echo "$done $total" | awk '{printf "%.3f", $1 / $2}')"
  done
[ -x "$build/fable_2" ] && ! grep -q "^FAILED:" "$work/build.log" ||
  fail "Building the game failed. See $work/build.log"
echo "PROGRESS 1"

# --- 6. Install -------------------------------------------------------------
step 6 "Installing"
# The game is a small app bundle so it shows its own name and icon. It finds the
# disc files in game/ and keeps its settings, saves, cache and logs in user/, next
# to the bundle. Rebuilding replaces the bundle and keeps user/.
bundle="$dest/Project Spire Game.app"
rm -rf "$bundle"
app="$bundle/Contents/MacOS"
mkdir -p "$app" "$bundle/Contents/Resources" "$dest/user" || fail "Installing failed."
cp "$toolkit/game-bundle/Info.plist" "$bundle/Contents/" || fail "Installing failed."
cp -R "$toolkit/game-bundle/Resources/" "$bundle/Contents/Resources/" || fail "Installing failed."
for file in fable_2 librexruntime.dylib librexgpu-xenos.dylib libTracyClient.dylib fable2_build.json; do
  cp "$build/$file" "$app/" || fail "Installing failed: $file is missing from the build."
done
[ -d "$build/vulkan" ] && cp -R "$build/vulkan" "$app/"
[ -f "$dest/user/fable2_config.toml" ] || cp "$build/fable2_config.toml" "$dest/user/"
cat > "$dest/spire.json" <<EOF
{"version": "$(cat "$toolkit/VERSION" 2>/dev/null || echo dev)", "game": "$version_name", "profile": "$version_id", "built": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
rm -rf "$work"
echo "PROGRESS 1"
echo DONE
