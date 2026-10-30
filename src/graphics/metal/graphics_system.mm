/**
 * @file        graphics/metal/graphics_system.mm
 * @brief       Native Metal GPU emulation backend (macOS)
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */

#include <rex/graphics/metal/graphics_system.h>

#include <rex/graphics/metal/command_processor.h>
#include <rex/ui/metal/metal_provider.h>

namespace rex::graphics::metal {

MetalGraphicsSystem::MetalGraphicsSystem() {}

MetalGraphicsSystem::~MetalGraphicsSystem() {}

std::string MetalGraphicsSystem::name() const {
  return "Metal";
}

void MetalGraphicsSystem::CreateProvider(bool with_presentation) {
  provider_ = rex::ui::metal::MetalProvider::Create(with_presentation);
}

std::unique_ptr<CommandProcessor> MetalGraphicsSystem::CreateCommandProcessor() {
  return std::make_unique<MetalCommandProcessor>(this, kernel_state_);
}

}  // namespace rex::graphics::metal
