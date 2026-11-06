/**
 * @file        rex/graphics/texture_replacement.h
 * @brief       Lets a game replace guest textures by the hash of their data.
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */
#pragma once

#include <cstdint>
#include <vector>

namespace rex::graphics {

// An RGBA8 image (rows from the top, straight alpha) to show in place of a texture.
struct TextureReplacement {
  uint32_t width = 0;
  uint32_t height = 0;
  std::vector<uint8_t> rgba;
};

// A guest texture's base level as it is in guest memory.
struct GuestTextureData {
  uint64_t hash;      // XXH3 64-bit hash of `data`
  uint32_t width;
  uint32_t height;
  uint32_t format;    // xenos::TextureFormat
  bool tiled;
  uint32_t endian;    // xenos::Endian
  const uint8_t* data;
  size_t length;
};

// Asked when a 2D texture of at most 512x512 loads from guest memory. Return true
// and fill `out` to replace the texture. Called on the GPU command processor thread.
// Supported by the Metal backend.
using TextureReplacementHook = bool (*)(const GuestTextureData& texture,
                                        TextureReplacement& out);
extern TextureReplacementHook g_texture_replacement_hook;

}  // namespace rex::graphics
