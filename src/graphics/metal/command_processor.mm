/**
 * @file        graphics/metal/command_processor.mm
 * @brief       Native Metal GPU command processor (macOS)
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */

#include <rex/graphics/metal/command_processor.h>

#include <xxhash.h>

#include <rex/graphics/graphics_system.h>
#include <rex/graphics/metal/graphics_system.h>
#include <rex/graphics/pipeline/shader/shader.h>
#include <rex/logging.h>
#include <rex/ui/metal/metal_presenter.h>
#include <rex/ui/metal/metal_provider.h>

namespace rex::graphics::metal {

MetalCommandProcessor::MetalCommandProcessor(MetalGraphicsSystem* graphics_system,
                                             system::KernelState* kernel_state)
    : CommandProcessor(graphics_system, kernel_state) {}

MetalCommandProcessor::~MetalCommandProcessor() = default;

const ui::metal::MetalProvider& MetalCommandProcessor::GetMetalProvider() const {
  return *static_cast<const ui::metal::MetalProvider*>(graphics_system_->provider());
}

bool MetalCommandProcessor::SetupContext() {
  if (!CommandProcessor::SetupContext()) {
    return false;
  }
  REXGPU_INFO("Metal command processor: GPU emulation is not implemented yet - drawing nothing");
  return true;
}

void MetalCommandProcessor::ShutdownContext() {
  shaders_.clear();
  CommandProcessor::ShutdownContext();
}

Shader* MetalCommandProcessor::LoadShader(xenos::ShaderType shader_type, uint32_t guest_address,
                                          const uint32_t* host_address, uint32_t dword_count) {
  (void)guest_address;
  uint64_t hash = XXH3_64bits(host_address, dword_count * sizeof(uint32_t));
  auto it = shaders_.find(hash);
  if (it != shaders_.end()) {
    return it->second.get();
  }
  auto shader = std::make_unique<Shader>(shader_type, hash, host_address, dword_count);
  Shader* shader_ptr = shader.get();
  shaders_.emplace(hash, std::move(shader));
  return shader_ptr;
}

bool MetalCommandProcessor::IssueDraw(xenos::PrimitiveType prim_type, uint32_t index_count,
                                      IndexBufferInfo* index_buffer_info,
                                      bool major_mode_explicit) {
  (void)prim_type;
  (void)index_count;
  (void)index_buffer_info;
  (void)major_mode_explicit;
  return true;
}

bool MetalCommandProcessor::IssueCopy() {
  return true;
}

void MetalCommandProcessor::IssueSwap(uint32_t frontbuffer_ptr, uint32_t frontbuffer_width,
                                      uint32_t frontbuffer_height) {
  (void)frontbuffer_ptr;
  ui::Presenter* presenter = graphics_system_->presenter();
  if (!presenter || !frontbuffer_width || !frontbuffer_height) {
    return;
  }
  const ui::metal::MetalProvider& provider = GetMetalProvider();
  presenter->RefreshGuestOutput(
      frontbuffer_width, frontbuffer_height, 1280, 720,
      [&provider](ui::Presenter::GuestOutputRefreshContext& context) -> bool {
        auto& metal_context =
            static_cast<ui::metal::MetalPresenter::MetalGuestOutputRefreshContext&>(context);
        context.SetIs8bpc(true);
        // Nothing is emulated yet: fill the guest output with a dark color.
        @autoreleasepool {
          id<MTLCommandBuffer> command_buffer = [provider.queue() commandBuffer];
          command_buffer.label = @"guest output";
          MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
          pass.colorAttachments[0].texture = metal_context.texture();
          pass.colorAttachments[0].loadAction = MTLLoadActionClear;
          pass.colorAttachments[0].clearColor = MTLClearColorMake(0.05, 0.05, 0.15, 1.0);
          pass.colorAttachments[0].storeAction = MTLStoreActionStore;
          [[command_buffer renderCommandEncoderWithDescriptor:pass] endEncoding];
          [command_buffer commit];
        }
        return true;
      });
}

}  // namespace rex::graphics::metal
