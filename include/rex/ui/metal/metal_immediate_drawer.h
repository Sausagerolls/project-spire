#pragma once
/**
 * @file        ui/metal/metal_immediate_drawer.h
 * @brief       Immediate-mode (UI) drawing with Metal
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */

// Objective-C++ only.

#include <memory>
#include <vector>

#import <Metal/Metal.h>

#include <rex/ui/immediate_drawer.h>
#include <rex/ui/presenter.h>

namespace rex {
namespace ui {
namespace metal {

class MetalProvider;

// The draw context the Metal presenter passes to the UI drawers: the render
// command encoder of the pass drawing to the presented image.
class MetalUIDrawContext final : public UIDrawContext {
 public:
  MetalUIDrawContext(Presenter& presenter, uint32_t render_target_width,
                     uint32_t render_target_height, id<MTLRenderCommandEncoder> encoder,
                     MTLPixelFormat render_target_format)
      : UIDrawContext(presenter, render_target_width, render_target_height),
        encoder_(encoder),
        render_target_format_(render_target_format) {}

  id<MTLRenderCommandEncoder> encoder() const { return encoder_; }
  MTLPixelFormat render_target_format() const { return render_target_format_; }

 private:
  id<MTLRenderCommandEncoder> encoder_;
  MTLPixelFormat render_target_format_;
};

class MetalImmediateDrawer final : public ImmediateDrawer {
 public:
  static std::unique_ptr<MetalImmediateDrawer> Create(const MetalProvider* provider);

  std::unique_ptr<ImmediateTexture> CreateTexture(uint32_t width, uint32_t height,
                                                  ImmediateTextureFilter filter, bool is_repeated,
                                                  const uint8_t* data) override;

  void Begin(UIDrawContext& ui_draw_context, float coordinate_space_width,
             float coordinate_space_height) override;
  void BeginDrawBatch(const ImmediateDrawBatch& batch) override;
  void Draw(const ImmediateDraw& draw) override;
  void EndDrawBatch() override;
  void End() override;

 private:
  class MetalImmediateTexture final : public ImmediateTexture {
   public:
    MetalImmediateTexture(uint32_t width, uint32_t height, id<MTLTexture> texture,
                          id<MTLSamplerState> sampler)
        : ImmediateTexture(width, height), texture_(texture), sampler_(sampler) {}
    id<MTLTexture> texture() const { return texture_; }
    id<MTLSamplerState> sampler() const { return sampler_; }

   private:
    id<MTLTexture> texture_;
    id<MTLSamplerState> sampler_;
  };

  explicit MetalImmediateDrawer(const MetalProvider* provider) : provider_(provider) {}
  bool Initialize();
  id<MTLRenderPipelineState> GetPipeline(MTLPixelFormat format);

  const MetalProvider* provider_;
  id<MTLFunction> vertex_function_ = nil;
  id<MTLFunction> fragment_function_ = nil;
  std::vector<std::pair<MTLPixelFormat, id<MTLRenderPipelineState>>> pipelines_;
  id<MTLSamplerState> samplers_[2][2] = {};  // [linear][repeat]
  id<MTLTexture> white_texture_ = nil;

  // Between Begin and End.
  id<MTLRenderCommandEncoder> encoder_ = nil;
  // Between BeginDrawBatch and EndDrawBatch.
  bool batch_has_indices_ = false;
  id<MTLBuffer> batch_index_buffer_ = nil;
};

}  // namespace metal
}  // namespace ui
}  // namespace rex
