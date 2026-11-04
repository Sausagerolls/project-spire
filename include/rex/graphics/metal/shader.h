#pragma once
/**
 * @file        graphics/metal/shader.h
 * @brief       Guest shaders translated to SPIR-V and converted to MSL
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */

// Objective-C++ only.

#include <atomic>
#include <cstdint>
#include <mutex>

#include <filesystem>

#import <Metal/Metal.h>

#include <rex/graphics/pipeline/shader/spirv.h>

namespace rex::ui::metal {
class MetalProvider;
}

namespace rex::graphics::metal {

class MetalShader : public SpirvShader {
 public:
  // Directory for converted MSL, keyed by the hash of the SPIR-V.
  static void SetMslCacheDirectory(const std::filesystem::path& directory);
  // Compiles the cached MSL in the background, so shaders seen in earlier runs
  // are ready when first drawn with.
  static void PreloadCachedLibraries(const ui::metal::MetalProvider& provider);

  class MetalTranslation : public SpirvTranslation {
   public:
    explicit MetalTranslation(MetalShader& shader, uint64_t modification)
        : SpirvTranslation(shader, modification) {}

    // Converts the translated SPIR-V to MSL and compiles it on the first call
    // (thread-safe). Returns nil if the translation is invalid or fails.
    id<MTLFunction> GetOrCreateFunction(const ui::metal::MetalProvider& provider);
    // Translated and with its function created (never goes back to false).
    bool is_function_ready() const { return function_ready_.load(std::memory_order_acquire); }

   private:
    std::mutex function_mutex_;
    bool function_attempted_ = false;
    id<MTLFunction> function_ = nil;
    std::atomic<bool> function_ready_{false};
  };

  MetalShader(xenos::ShaderType shader_type, uint64_t ucode_data_hash,
              const uint32_t* ucode_dwords, size_t ucode_dword_count)
      : SpirvShader(shader_type, ucode_data_hash, ucode_dwords, ucode_dword_count) {}

 protected:
  Translation* CreateTranslationInstance(uint64_t modification) override;
};

}  // namespace rex::graphics::metal
