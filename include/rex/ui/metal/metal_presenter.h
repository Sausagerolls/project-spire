#pragma once
/**
 * @file        ui/metal/metal_presenter.h
 * @brief       Presentation to a CAMetalLayer with Metal
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */

// Objective-C++ only.

#include <array>
#include <memory>

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <rex/ui/presenter.h>

namespace rex {
namespace ui {
namespace metal {

class MetalProvider;

class MetalPresenter final : public Presenter {
 public:
  // Guest output images are RGBA8 for now (the refresher writes 8bpc).
  static constexpr MTLPixelFormat kGuestOutputFormat = MTLPixelFormatRGBA8Unorm;

  // What the refresher (the GPU emulation) writes the guest output to. The
  // refresher must encode its writes into command buffers of the provider's
  // queue and commit them before returning.
  class MetalGuestOutputRefreshContext final : public GuestOutputRefreshContext {
   public:
    MetalGuestOutputRefreshContext(bool& is_8bpc_out_ref, id<MTLTexture> texture)
        : GuestOutputRefreshContext(is_8bpc_out_ref), texture_(texture) {}
    id<MTLTexture> texture() const { return texture_; }

   private:
    id<MTLTexture> texture_;
  };

  static std::unique_ptr<MetalPresenter> Create(HostGpuLossCallback host_gpu_loss_callback,
                                                const MetalProvider* provider);

  Surface::TypeFlags GetSupportedSurfaceTypes() const override;
  bool CaptureGuestOutput(RawImage& image_out) override;

 protected:
  SurfacePaintConnectResult ConnectOrReconnectPaintingToSurfaceFromUIThread(
      Surface& new_surface, uint32_t new_surface_width, uint32_t new_surface_height,
      bool was_paintable, bool& is_vsync_implicit_out) override;
  void DisconnectPaintingFromSurfaceFromUIThreadImpl() override;
  bool RefreshGuestOutputImpl(uint32_t mailbox_index, uint32_t frontbuffer_width,
                              uint32_t frontbuffer_height,
                              std::function<bool(GuestOutputRefreshContext& context)> refresher,
                              bool& is_8bpc_out_ref) override;
  PaintResult PaintAndPresentImpl(bool execute_ui_drawers) override;

 private:
  MetalPresenter(HostGpuLossCallback host_gpu_loss_callback, const MetalProvider* provider)
      : Presenter(host_gpu_loss_callback), provider_(provider) {}
  bool Initialize();
  id<MTLRenderPipelineState> GetGuestOutputPipeline(MTLPixelFormat format);

  const MetalProvider* provider_;

  id<MTLFunction> guest_output_vs_ = nil;
  id<MTLFunction> guest_output_bilinear_ps_ = nil;
  MTLPixelFormat guest_output_pipeline_format_ = MTLPixelFormatInvalid;
  id<MTLRenderPipelineState> guest_output_pipeline_ = nil;
  id<MTLSamplerState> linear_sampler_ = nil;

  // Mailbox images, written by the refresher, read by painting. The command
  // buffers retain the textures they use, so replacing them is safe.
  std::array<id<MTLTexture>, kGuestOutputMailboxSize> guest_output_textures_{};

  // Painting connection (UI thread).
  CAMetalLayer* layer_ = nil;
  uint32_t surface_width_ = 0;
  uint32_t surface_height_ = 0;
};

}  // namespace metal
}  // namespace ui
}  // namespace rex
