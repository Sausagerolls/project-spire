#!/bin/bash
# Builds Project Spire.app: the launcher plus the toolkit it uses to build the game.
#
# Usage: launcher/package.sh <sdk_install_dir> <out_dir>
#   sdk_install_dir  the SDK (sdk/) built and installed with `cmake --install`
#                    (macOS arm64 Release)
#   out_dir          where Project Spire.app is written
#
# The bundle contains the game project's tracked files (git archive of game/), the SDK,
# CMake and Ninja. No game data or game code goes in it. Needs Xcode (swiftc, actool),
# and cmake and ninja on PATH, whose files are copied in.

set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
sdk="$(cd "$1" && pwd)"
out="$(mkdir -p "$2" && cd "$2" && pwd)"
app="$out/Project Spire.app"
contents="$app/Contents"
toolkit="$contents/Resources/toolkit"
version="$(git -C "$repo" describe --always --dirty)"
build="$out/.package"

rm -rf "$app" "$build"
mkdir -p "$contents/MacOS" "$contents/Resources" "$toolkit/bin" "$build"

# Launcher.
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 \
  -o "$contents/MacOS/ProjectSpire" "$here/Sources/ProjectSpire.swift"

# Icon: the Icon Composer file for macOS 26, plus a classic .icns for older systems.
xcrun actool --compile "$build/icon" --platform macosx --minimum-deployment-target 14.0 \
  --app-icon AppIcon --include-all-app-icons --output-partial-info-plist "$build/icon.plist" \
  "$here/Icon/AppIcon.icon" >/dev/null 2>&1 || {
  mkdir -p "$build/icon"
  xcrun actool --compile "$build/icon" --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --output-partial-info-plist "$build/icon.plist" "$here/Icon/AppIcon.icon"
}
cp "$build/icon/AppIcon.icns" "$build/icon/Assets.car" "$contents/Resources/"

plist() {  # plist <file> <executable> <identifier> <name>
  cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$2</string>
  <key>CFBundleIdentifier</key><string>$3</string>
  <key>CFBundleName</key><string>$4</string>
  <key>CFBundleDisplayName</key><string>$4</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.role-playing-games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
EOF
}
plist "$contents/Info.plist" ProjectSpire org.projectspire.launcher "Project Spire"

# Toolkit: setup scripts, project source, SDK, CMake, Ninja.
cp "$here/toolkit/spire_setup.sh" "$here/toolkit/spire_disc.py" "$toolkit/"
echo "$version" > "$toolkit/VERSION"
mkdir -p "$toolkit/source"
git -C "$repo" archive --format=tar HEAD:game | tar -x -C "$toolkit/source"
cp -R "$sdk" "$toolkit/sdk"
cmake_root="$(cd "$(dirname "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$(command -v cmake)")")/.." && pwd)"
# A pip-installed cmake is a Python wrapper; the real binary is under its data folder.
[ -x "$cmake_root/bin/cmake" ] && file "$cmake_root/bin/cmake" | grep -q Mach-O ||
  cmake_root="$(python3 -c 'import cmake, os; print(os.path.join(os.path.dirname(cmake.__file__), "data"))')"
cmake_share="$(ls -d "$cmake_root"/share/cmake-* | head -1)"
mkdir -p "$toolkit/cmake/bin" "$toolkit/cmake/share"
cp "$cmake_root/bin/cmake" "$toolkit/cmake/bin/"
cp -R "$cmake_share" "$toolkit/cmake/share/"
ninja_bin="$(command -v ninja)"
file "$ninja_bin" | grep -q Mach-O ||
  ninja_bin="$(python3 -c 'import ninja, os; print(os.path.join(os.path.dirname(ninja.__file__), "data", "bin", "ninja"))')"
cp "$ninja_bin" "$toolkit/bin/ninja"

# The game's own small bundle, filled in by spire_setup.sh.
mkdir -p "$toolkit/game-bundle/Resources"
plist "$toolkit/game-bundle/Info.plist" fable_2 org.projectspire.game "Project Spire"
cp "$build/icon/AppIcon.icns" "$build/icon/Assets.car" "$toolkit/game-bundle/Resources/"

# Licences of what the bundle carries.
cp "$repo/LICENSE" "$repo/CREDITS.md" "$contents/Resources/"
cp "$repo/sdk/LICENSE" "$contents/Resources/LICENSE-rexglue-sdk"

rm -rf "$build"
codesign --force --deep --sign - "$app" >/dev/null
du -sh "$app"
