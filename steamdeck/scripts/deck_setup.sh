#!/bin/bash
# Sets up the Steam Deck for building Project Spire. Run in Desktop Mode, from this
# folder's parent (~/spire). SteamOS's system is read-only, so the tools live in a
# distrobox container ("spire", Arch Linux); your home folder is shared with it.
#
#   scripts/deck_setup.sh            create the container, unpack or clone the sources
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$here/src"

if ! command -v distrobox >/dev/null; then
  echo "distrobox is missing. It ships with SteamOS 3.5 and later; update SteamOS." >&2
  exit 1
fi
if ! distrobox list | grep -q " spire "; then
  distrobox create --yes --name spire --image docker.io/library/archlinux:latest
fi
# Compiler, build tools, and the headers SDL3 and the Vulkan loader need.
distrobox enter spire -- sudo pacman -Syu --noconfirm --needed \
  base-devel clang lld llvm cmake ninja git python python-pip pkgconf \
  vulkan-headers vulkan-icd-loader vulkan-radeon vulkan-tools mesa \
  libx11 libxext libxrandr libxcursor libxi libxss libxkbcommon wayland wayland-protocols \
  libdecor alsa-lib libpulse pipewire dbus mangohud

# Sources: the bundles in repos/ (newest), else GitHub.
clone() {  # clone <bundle> <github branch> <folder>
  if [ -d "$here/src/$3/.git" ]; then
    echo "$3 already there"
  elif [ -f "$here/repos/$1" ]; then
    git clone "$here/repos/$1" "$here/src/$3"
  else
    git clone --branch "$2" https://github.com/Sausagerolls/project-spire.git "$here/src/$3"
  fi
}
clone fable-2-recomp.bundle main Fable-2-Recomp
clone rexglue-sdk.bundle rexglue-sdk-metal rexglue-sdk
git -C "$here/src/Fable-2-Recomp" checkout -q macos-port 2>/dev/null || true
git -C "$here/src/rexglue-sdk" checkout -q metal-backend 2>/dev/null || true
# Third-party code comes from its own repositories.
git -C "$here/src/rexglue-sdk" submodule update --init --recursive
git -C "$here/src/Fable-2-Recomp" submodule update --init thirdparty/tomlplusplus 2>/dev/null || true
echo "Done. Next: scripts/extract_disc.sh <your Fable II .iso>, then scripts/build.sh"
