/**
 * @file        ui/metal/metal_provider.mm
 * @brief       Native Metal graphics provider (macOS)
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */

#include <rex/ui/metal/metal_provider.h>

#include <rex/cvar.h>
#include <rex/logging.h>
#include <rex/ui/metal/metal_immediate_drawer.h>
#include <rex/ui/metal/metal_presenter.h>

REXCVAR_DEFINE_STRING(metal_math_mode, "safe", "GPU/Metal",
                      "Metal shader math mode: 'safe' (IEEE), 'relaxed' (reassociation, keeps NaN "
                      "and infinity handling) or 'fast'")
    .lifecycle(rex::cvar::Lifecycle::kInitOnly);

namespace rex {
namespace ui {
namespace metal {

std::unique_ptr<MetalProvider> MetalProvider::Create(bool with_presentation) {
  (void)with_presentation;
  std::unique_ptr<MetalProvider> provider(new MetalProvider());
  provider->device_ = MTLCreateSystemDefaultDevice();
  if (!provider->device_) {
    REXLOG_ERROR("MetalProvider: No Metal device available");
    return nullptr;
  }
  // Long-running guest frames submit many command buffers.
  provider->queue_ = [provider->device_ newCommandQueueWithMaxCommandBufferCount:64];
  if (!provider->queue_) {
    REXLOG_ERROR("MetalProvider: Failed to create the command queue");
    return nullptr;
  }
  provider->queue_.label = @"rex";
  REXLOG_INFO("MetalProvider: Using {} (unified memory: {}, max buffer {} MB)",
              [provider->device_.name UTF8String], bool(provider->device_.hasUnifiedMemory),
              uint64_t(provider->device_.maxBufferLength) >> 20);
  return provider;
}

std::unique_ptr<Presenter> MetalProvider::CreatePresenter(
    Presenter::HostGpuLossCallback host_gpu_loss_callback) {
  return MetalPresenter::Create(host_gpu_loss_callback, this);
}

std::unique_ptr<ImmediateDrawer> MetalProvider::CreateImmediateDrawer() {
  return MetalImmediateDrawer::Create(this);
}

id<MTLLibrary> MetalProvider::CompileLibrary(NSString* source, const char* debug_name) const {
  MTLCompileOptions* options = [[MTLCompileOptions alloc] init];
  // Guest shaders rely on IEEE behavior (NaN and infinity handling).
  std::string math_mode = REXCVAR_GET(metal_math_mode);
  if (@available(macOS 15.0, *)) {
    options.mathMode = math_mode == "fast"      ? MTLMathModeFast
                       : math_mode == "relaxed" ? MTLMathModeRelaxed
                                                : MTLMathModeSafe;
  } else {
    options.fastMathEnabled = math_mode == "fast";
  }
  NSError* error = nil;
  id<MTLLibrary> library = [device_ newLibraryWithSource:source options:options error:&error];
  if (!library) {
    REXLOG_ERROR("MetalProvider: Failed to compile {}: {}", debug_name,
                 error ? [error.localizedDescription UTF8String] : "unknown error");
  }
  return library;
}

}  // namespace metal
}  // namespace ui
}  // namespace rex
