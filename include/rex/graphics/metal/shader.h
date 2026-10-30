#pragma once
/**
 * @file        graphics/metal/shader.h
 * @brief       Guest shaders translated to SPIR-V and converted to MSL
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */

// Objective-C++ only.

#include <cstdint>
#include <mutex>

#import <Metal/Metal.h>

#include <rex/graphics/pipeline/shader/spirv.h>

namespace rex::ui::metal {
class MetalProvider;
}

namespace rex::graphics::metal {

class MetalShader : public SpirvShader {
 public:
  class MetalTranslation : public SpirvTranslation {
   public:
    explicit MetalTranslation(MetalShader& shader, uint64_t modification)
        : SpirvTranslation(shader, modification) {}

    // Converts the translated SPIR-V to MSL and compiles it on the first call
    // (thread-safe). Returns nil if the translation is invalid or fails.
    id<MTLFunction> GetOrCreateFunction(const ui::metal::MetalProvider& provider);

   private:
    std::mutex function_mutex_;
    bool function_attempted_ = false;
    id<MTLFunction> function_ = nil;
  };

  MetalShader(xenos::ShaderType shader_type, uint64_t ucode_data_hash,
              const uint32_t* ucode_dwords, size_t ucode_dword_count)
      : SpirvShader(shader_type, ucode_data_hash, ucode_dwords, ucode_dword_count) {}

 protected:
  Translation* CreateTranslationInstance(uint64_t modification) override;
};

}  // namespace rex::graphics::metal
