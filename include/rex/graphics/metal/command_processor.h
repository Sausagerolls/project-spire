#pragma once
/**
 * @file        graphics/metal/command_processor.h
 * @brief       Native Metal GPU command processor (macOS)
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */

// Objective-C++ only.

#include <cstdint>
#include <memory>
#include <unordered_map>

#import <Metal/Metal.h>

#include <rex/graphics/command_processor.h>

namespace rex::ui::metal {
class MetalProvider;
}

namespace rex::graphics::metal {

class MetalGraphicsSystem;

class MetalCommandProcessor : public CommandProcessor {
 public:
  MetalCommandProcessor(MetalGraphicsSystem* graphics_system, system::KernelState* kernel_state);
  ~MetalCommandProcessor() override;

  void IssueSwap(uint32_t frontbuffer_ptr, uint32_t frontbuffer_width,
                 uint32_t frontbuffer_height) override;

  const ui::metal::MetalProvider& GetMetalProvider() const;

 protected:
  bool SetupContext() override;
  void ShutdownContext() override;

  Shader* LoadShader(xenos::ShaderType shader_type, uint32_t guest_address,
                     const uint32_t* host_address, uint32_t dword_count) override;

  bool IssueDraw(xenos::PrimitiveType prim_type, uint32_t index_count,
                 IndexBufferInfo* index_buffer_info, bool major_mode_explicit) override;
  bool IssueCopy() override;

 private:
  std::unordered_map<uint64_t, std::unique_ptr<Shader>> shaders_;
};

}  // namespace rex::graphics::metal
