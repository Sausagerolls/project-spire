// Project-owned app artwork only. No original game artwork is bundled.
#pragma once
#include <filesystem>
#include <fstream>
#include <vector>
#include <cstring>
#include <rex/filesystem.h>
#include <rex/ui/window.h>

namespace fable2::branding {
inline void Apply(rex::ui::Window* window) {
  if (!window) return;
  window->SetTitle("Project Spire");
  std::ifstream file(rex::filesystem::GetExecutableFolder() / "app-icon.png",
                     std::ios::binary | std::ios::ate);
  if (!file) return;
  auto size = file.tellg();
  if (size < 8 || size > 1024 * 1024) return;
  std::vector<unsigned char> png(static_cast<size_t>(size));
  file.seekg(0);
  if (!file.read(reinterpret_cast<char*>(png.data()), png.size())) return;
  constexpr unsigned char signature[] = {137, 80, 78, 71, 13, 10, 26, 10};
  if (std::memcmp(png.data(), signature, 8) == 0) window->SetIcon(png.data(), png.size());
}
}  // namespace fable2::branding
