#!/bin/bash
# Sets up the Steam Deck for building Project Spire. Run in Desktop Mode.
# SteamOS's system is read-only, so the tools live in a distrobox container
# ("spire", Arch Linux); your home folder is shared with it.
set -euo pipefail
source "$(dirname "$0")/common.sh"

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

# The SDK (sdk/) and its third-party code are submodules.
git -C "$repo" submodule update --init --recursive
mkdir -p "$SPIRE_HOME"
echo "Done. Next: steamdeck/scripts/extract_disc.sh <your Fable II .iso>, then steamdeck/scripts/build.sh"
