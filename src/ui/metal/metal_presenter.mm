/**
 * @file        ui/metal/metal_presenter.mm
 * @brief       Presentation to a CAMetalLayer with Metal
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */

#include <rex/cvar.h>
#include <rex/logging.h>
#include <atomic>
#include <rex/ui/metal/metal_presenter.h>

#include <cstring>

#include <rex/assert.h>
#include <rex/logging.h>
#include <rex/ui/metal/metal_immediate_drawer.h>
#include <rex/ui/metal/metal_provider.h>
#include <rex/ui/surface_mac.h>

REXCVAR_DEFINE_BOOL(metal_display_sync, true, "GPU/Metal",
                    "Present the window's frames in step with the display")
    .lifecycle(rex::cvar::Lifecycle::kHotReload);
REXCVAR_DEFINE_INT32(metal_max_drawables, 2, "GPU/Metal",
                     "Drawables of the window's Metal layer, 2 or 3. 2 can show frames sooner")
    .lifecycle(rex::cvar::Lifecycle::kHotReload);

namespace rex {
namespace ui {
namespace metal {

namespace {
NSString* const kGuestOutputShaderSource = @R"(
#include <metal_stdlib>
using namespace metal;
struct VertexOut {
  float4 position [[position]];
};
// A triangle covering the whole viewport (the viewport is the output rectangle).
vertex VertexOut guest_output_vs(uint vertex_id [[vertex_id]]) {
  VertexOut out;
  float2 position = float2(float((vertex_id << 1u) & 2u), float(vertex_id & 2u));
  out.position = float4(position * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
  return out;
}
struct BilinearConstants {
  int2 output_offset;
  float2 output_size_inv;
};
fragment float4 guest_output_bilinear_ps(VertexOut in [[stage_in]],
                                         texture2d<float> source [[texture(0)]],
                                         sampler source_sampler [[sampler(0)]],
                                         constant BilinearConstants& constants [[buffer(0)]]) {
  float2 texcoord = (in.position.xy - float2(constants.output_offset)) * constants.output_size_inv;
  return float4(source.sample(source_sampler, texcoord).rgb, 1.0);
}
)";
}  // namespace

std::unique_ptr<MetalPresenter> MetalPresenter::Create(HostGpuLossCallback host_gpu_loss_callback,
                                                       const MetalProvider* provider) {
  std::unique_ptr<MetalPresenter> presenter(new MetalPresenter(host_gpu_loss_callback, provider));
  if (!presenter->Initialize()) {
    return nullptr;
  }
  return presenter;
}

bool MetalPresenter::Initialize() {
  id<MTLLibrary> library = provider_->CompileLibrary(kGuestOutputShaderSource, "guest output");
  if (!library) {
    return false;
  }
  guest_output_vs_ = [library newFunctionWithName:@"guest_output_vs"];
  guest_output_bilinear_ps_ = [library newFunctionWithName:@"guest_output_bilinear_ps"];
  MTLSamplerDescriptor* sampler_descriptor = [[MTLSamplerDescriptor alloc] init];
  sampler_descriptor.minFilter = MTLSamplerMinMagFilterLinear;
  sampler_descriptor.magFilter = MTLSamplerMinMagFilterLinear;
  sampler_descriptor.sAddressMode = MTLSamplerAddressModeClampToEdge;
  sampler_descriptor.tAddressMode = MTLSamplerAddressModeClampToEdge;
  linear_sampler_ = [provider_->device() newSamplerStateWithDescriptor:sampler_descriptor];
  if (!guest_output_vs_ || !guest_output_bilinear_ps_ || !linear_sampler_) {
    return false;
  }
  return InitializeCommonSurfaceIndependent();
}

Surface::TypeFlags MetalPresenter::GetSupportedSurfaceTypes() const {
  return Surface::kTypeFlag_CAMetalLayer;
}

id<MTLRenderPipelineState> MetalPresenter::GetGuestOutputPipeline(MTLPixelFormat format) {
  if (guest_output_pipeline_ && guest_output_pipeline_format_ == format) {
    return guest_output_pipeline_;
  }
  MTLRenderPipelineDescriptor* descriptor = [[MTLRenderPipelineDescriptor alloc] init];
  descriptor.label = @"guest output bilinear";
  descriptor.vertexFunction = guest_output_vs_;
  descriptor.fragmentFunction = guest_output_bilinear_ps_;
  descriptor.colorAttachments[0].pixelFormat = format;
  NSError* error = nil;
  guest_output_pipeline_ =
      [provider_->device() newRenderPipelineStateWithDescriptor:descriptor error:&error];
  if (!guest_output_pipeline_) {
    REXLOG_ERROR("MetalPresenter: Failed to create the guest output pipeline: {}",
                 error ? [error.localizedDescription UTF8String] : "unknown error");
  }
  guest_output_pipeline_format_ = format;
  return guest_output_pipeline_;
}

bool MetalPresenter::CaptureGuestOutput(RawImage& image_out) {
  id<MTLTexture> texture = nil;
  {
    uint32_t mailbox_index;
    auto consumer_lock = ConsumeGuestOutput(mailbox_index, nullptr, nullptr);
    if (mailbox_index == UINT32_MAX) {
      return false;
    }
    texture = guest_output_textures_[mailbox_index];
  }
  if (!texture) {
    return false;
  }
  // Wait for the GPU work writing the image (same queue, so an empty command
  // buffer completing means everything before it has completed).
  id<MTLCommandBuffer> command_buffer = [provider_->queue() commandBuffer];
  [command_buffer commit];
  [command_buffer waitUntilCompleted];
  uint32_t width = uint32_t(texture.width), height = uint32_t(texture.height);
  image_out.width = width;
  image_out.height = height;
  image_out.stride = size_t(width) * 4;
  image_out.data.resize(image_out.stride * height);
  [texture getBytes:image_out.data.data()
        bytesPerRow:image_out.stride
         fromRegion:MTLRegionMake2D(0, 0, width, height)
        mipmapLevel:0];
  // RGBA8 to RGBX8.
  for (size_t i = 3; i < image_out.data.size(); i += 4) {
    image_out.data[i] = 0xFF;
  }
  return true;
}

Presenter::SurfacePaintConnectResult MetalPresenter::ConnectOrReconnectPaintingToSurfaceFromUIThread(
    Surface& new_surface, uint32_t new_surface_width, uint32_t new_surface_height,
    bool was_paintable, bool& is_vsync_implicit_out) {
  (void)was_paintable;
  if (new_surface.GetType() != Surface::kTypeIndex_CAMetalLayer) {
    return SurfacePaintConnectResult::kFailureSurfaceUnusable;
  }
  CAMetalLayer* layer =
      (__bridge CAMetalLayer*)(static_cast<CAMetalLayerSurface&>(new_surface).layer());
  if (!layer) {
    return SurfacePaintConnectResult::kFailureSurfaceUnusable;
  }
  bool unchanged = layer == layer_ && new_surface_width == surface_width_ &&
                   new_surface_height == surface_height_;
  layer_ = layer;
  surface_width_ = new_surface_width;
  surface_height_ = new_surface_height;
  layer_.device = provider_->device();
  layer_.pixelFormat = MTLPixelFormatBGRA8Unorm;
  layer_.framebufferOnly = YES;
  layer_.drawableSize = CGSizeMake(new_surface_width, new_surface_height);
  is_vsync_implicit_out = layer_.displaySyncEnabled;
  return unchanged ? SurfacePaintConnectResult::kSuccessUnchanged
                   : SurfacePaintConnectResult::kSuccess;
}

void MetalPresenter::DisconnectPaintingFromSurfaceFromUIThreadImpl() {
  layer_ = nil;
  surface_width_ = 0;
  surface_height_ = 0;
}

bool MetalPresenter::RefreshGuestOutputImpl(
    uint32_t mailbox_index, uint32_t frontbuffer_width, uint32_t frontbuffer_height,
    std::function<bool(GuestOutputRefreshContext& context)> refresher, bool& is_8bpc_out_ref) {
  assert_not_zero(frontbuffer_width);
  assert_not_zero(frontbuffer_height);
  __strong id<MTLTexture>& texture = guest_output_textures_[mailbox_index];
  if (!texture || texture.width != frontbuffer_width || texture.height != frontbuffer_height) {
    MTLTextureDescriptor* descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:kGuestOutputFormat
                                                           width:frontbuffer_width
                                                          height:frontbuffer_height
                                                       mipmapped:NO];
    descriptor.usage =
        MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
    // Shared so CaptureGuestOutput can read it directly.
    descriptor.storageMode = MTLStorageModeShared;
    texture = [provider_->device() newTextureWithDescriptor:descriptor];
    if (!texture) {
      REXLOG_ERROR("MetalPresenter: Failed to create a {}x{} guest output image",
                   frontbuffer_width, frontbuffer_height);
      return false;
    }
    texture.label = @"guest output";
  }
  MetalGuestOutputRefreshContext context(is_8bpc_out_ref, texture);
  return refresher(context);
}

Presenter::PaintResult MetalPresenter::PaintAndPresentImpl(bool execute_ui_drawers) {
  if (!layer_ || !surface_width_ || !surface_height_) {
    return PaintResult::kNotPresented;
  }
  @autoreleasepool {
    int32_t max_drawables = REXCVAR_GET(metal_max_drawables);
    if (layer_.maximumDrawableCount != NSUInteger(max_drawables)) {
      layer_.maximumDrawableCount = NSUInteger(max_drawables);
    }
    if (layer_.displaySyncEnabled != REXCVAR_GET(metal_display_sync)) {
      layer_.displaySyncEnabled = REXCVAR_GET(metal_display_sync);
    }
    id<CAMetalDrawable> drawable = [layer_ nextDrawable];
    if (!drawable) {
      return PaintResult::kNotPresented;
    }
    id<MTLCommandBuffer> command_buffer = [provider_->queue() commandBuffer];
    command_buffer.label = @"present";

    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [command_buffer renderCommandEncoderWithDescriptor:pass];

    GuestOutputProperties properties;
    GuestOutputPaintConfig paint_config;
    id<MTLTexture> guest_output = nil;
    {
      uint32_t mailbox_index;
      auto consumer_lock = ConsumeGuestOutput(mailbox_index, &properties, &paint_config);
      if (mailbox_index != UINT32_MAX) {
        guest_output = guest_output_textures_[mailbox_index];
      }
    }
    if (guest_output) {
      uint32_t max_size = 16384;
      GuestOutputPaintFlow flow = GetGuestOutputPaintFlow(
          properties, surface_width_, surface_height_, max_size, max_size, paint_config);
      id<MTLRenderPipelineState> pipeline = GetGuestOutputPipeline(drawable.texture.pixelFormat);
      if (flow.effect_count && pipeline) {
        // Only the bilinear effect for now: draw the source directly to the
        // final rectangle.
        size_t final_effect = flow.effect_count - 1;
        const std::pair<uint32_t, uint32_t>& output_size = flow.effect_output_sizes[final_effect];
        BilinearConstants constants;
        constants.output_offset[0] = flow.output_x;
        constants.output_offset[1] = flow.output_y;
        constants.output_size_inv[0] = 1.0f / float(output_size.first);
        constants.output_size_inv[1] = 1.0f / float(output_size.second);
        MTLViewport viewport = {double(flow.output_x),
                                double(flow.output_y),
                                double(output_size.first),
                                double(output_size.second),
                                0.0,
                                1.0};
        [encoder setViewport:viewport];
        [encoder setRenderPipelineState:pipeline];
        [encoder setFragmentTexture:guest_output atIndex:0];
        [encoder setFragmentSamplerState:linear_sampler_ atIndex:0];
        [encoder setFragmentBytes:&constants length:sizeof(constants) atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
      }
    }

    if (execute_ui_drawers) {
      MTLViewport viewport = {0.0, 0.0, double(surface_width_), double(surface_height_), 0.0, 1.0};
      [encoder setViewport:viewport];
      MetalUIDrawContext ui_draw_context(*this, surface_width_, surface_height_, encoder,
                                         drawable.texture.pixelFormat);
      ExecuteUIDrawersFromUIThread(ui_draw_context);
    }

    [encoder endEncoding];
    [command_buffer presentDrawable:drawable];
    [command_buffer commit];
  }
  return PaintResult::kPresented;
}

}  // namespace metal
}  // namespace ui
}  // namespace rex
