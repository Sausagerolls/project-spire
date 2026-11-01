#pragma once
/**
 * @file        ui/metal/metal_provider.h
 * @brief       Native Metal graphics provider (macOS)
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */

// Objective-C++ only (Metal object types).

#include <memory>

#import <Metal/Metal.h>

#include <rex/ui/graphics_provider.h>

namespace rex {
namespace ui {
namespace metal {

class MetalProvider : public GraphicsProvider {
 public:
  static std::unique_ptr<MetalProvider> Create(bool with_presentation);

  id<MTLDevice> device() const { return device_; }
  // The queue for GPU emulation and presentation, so that their commands are
  // ordered without cross-queue synchronization.
  id<MTLCommandQueue> queue() const { return queue_; }

  std::unique_ptr<Presenter> CreatePresenter(Presenter::HostGpuLossCallback host_gpu_loss_callback =
                                                 Presenter::FatalErrorHostGpuLossCallback) override;
  std::unique_ptr<ImmediateDrawer> CreateImmediateDrawer() override;

  // Compiles MSL source. Logs and returns nil on failure.
  // math_mode: "safe", "relaxed" or "fast", or null for metal_math_mode.
  id<MTLLibrary> CompileLibrary(NSString* source, const char* debug_name,
                                const char* math_mode = nullptr) const;

 private:
  MetalProvider() = default;

  id<MTLDevice> device_ = nil;
  id<MTLCommandQueue> queue_ = nil;
};

}  // namespace metal
}  // namespace ui
}  // namespace rex
