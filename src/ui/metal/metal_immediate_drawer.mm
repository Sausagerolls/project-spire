/**
 * @file        ui/metal/metal_immediate_drawer.mm
 * @brief       Immediate-mode (UI) drawing with Metal
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */

#include <rex/ui/metal/metal_immediate_drawer.h>

#include <cstring>

#include <rex/assert.h>
#include <rex/logging.h>
#include <rex/ui/metal/metal_provider.h>

namespace rex {
namespace ui {
namespace metal {

namespace {
// Vertex buffer index 0 is the batch vertices (stage_in), 1 the constants.
NSString* const kImmediateShaderSource = @R"(
#include <metal_stdlib>
using namespace metal;
struct VertexIn {
  float2 position [[attribute(0)]];
  float2 texcoord [[attribute(1)]];
  float4 color [[attribute(2)]];
};
struct VertexOut {
  float4 position [[position]];
  float2 texcoord;
  float4 color;
};
vertex VertexOut immediate_vs(VertexIn in [[stage_in]],
                              constant float2& coordinate_space_size_inv [[buffer(1)]]) {
  VertexOut out;
  out.position = float4(in.position * coordinate_space_size_inv * float2(2.0, -2.0) +
                            float2(-1.0, 1.0),
                        0.0, 1.0);
  out.texcoord = in.texcoord;
  out.color = in.color;
  return out;
}
fragment float4 immediate_ps(VertexOut in [[stage_in]], texture2d<float> tex [[texture(0)]],
                             sampler tex_sampler [[sampler(0)]]) {
  return in.color * tex.sample(tex_sampler, in.texcoord);
}
)";
}  // namespace

std::unique_ptr<MetalImmediateDrawer> MetalImmediateDrawer::Create(const MetalProvider* provider) {
  std::unique_ptr<MetalImmediateDrawer> drawer(new MetalImmediateDrawer(provider));
  if (!drawer->Initialize()) {
    return nullptr;
  }
  return drawer;
}

bool MetalImmediateDrawer::Initialize() {
  id<MTLDevice> device = provider_->device();
  id<MTLLibrary> library = provider_->CompileLibrary(kImmediateShaderSource, "immediate drawer");
  if (!library) {
    return false;
  }
  vertex_function_ = [library newFunctionWithName:@"immediate_vs"];
  fragment_function_ = [library newFunctionWithName:@"immediate_ps"];
  for (uint32_t linear = 0; linear < 2; ++linear) {
    for (uint32_t repeat = 0; repeat < 2; ++repeat) {
      MTLSamplerDescriptor* sampler_descriptor = [[MTLSamplerDescriptor alloc] init];
      MTLSamplerMinMagFilter filter =
          linear ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
      sampler_descriptor.minFilter = filter;
      sampler_descriptor.magFilter = filter;
      MTLSamplerAddressMode address_mode =
          repeat ? MTLSamplerAddressModeRepeat : MTLSamplerAddressModeClampToEdge;
      sampler_descriptor.sAddressMode = address_mode;
      sampler_descriptor.tAddressMode = address_mode;
      samplers_[linear][repeat] = [device newSamplerStateWithDescriptor:sampler_descriptor];
    }
  }
  const uint32_t white = 0xFFFFFFFF;
  std::unique_ptr<ImmediateTexture> white_texture =
      CreateTexture(1, 1, ImmediateTextureFilter::kNearest, false,
                    reinterpret_cast<const uint8_t*>(&white));
  if (!white_texture) {
    return false;
  }
  white_texture_ = static_cast<MetalImmediateTexture*>(white_texture.get())->texture();
  return vertex_function_ && fragment_function_;
}

id<MTLRenderPipelineState> MetalImmediateDrawer::GetPipeline(MTLPixelFormat format) {
  for (const auto& pipeline : pipelines_) {
    if (pipeline.first == format) {
      return pipeline.second;
    }
  }
  MTLVertexDescriptor* vertex_descriptor = [MTLVertexDescriptor vertexDescriptor];
  vertex_descriptor.attributes[0].format = MTLVertexFormatFloat2;
  vertex_descriptor.attributes[0].offset = offsetof(ImmediateVertex, x);
  vertex_descriptor.attributes[0].bufferIndex = 0;
  vertex_descriptor.attributes[1].format = MTLVertexFormatFloat2;
  vertex_descriptor.attributes[1].offset = offsetof(ImmediateVertex, u);
  vertex_descriptor.attributes[1].bufferIndex = 0;
  vertex_descriptor.attributes[2].format = MTLVertexFormatUChar4Normalized;
  vertex_descriptor.attributes[2].offset = offsetof(ImmediateVertex, color);
  vertex_descriptor.attributes[2].bufferIndex = 0;
  vertex_descriptor.layouts[0].stride = sizeof(ImmediateVertex);
  MTLRenderPipelineDescriptor* descriptor = [[MTLRenderPipelineDescriptor alloc] init];
  descriptor.label = @"immediate drawer";
  descriptor.vertexFunction = vertex_function_;
  descriptor.fragmentFunction = fragment_function_;
  descriptor.vertexDescriptor = vertex_descriptor;
  MTLRenderPipelineColorAttachmentDescriptor* color = descriptor.colorAttachments[0];
  color.pixelFormat = format;
  color.blendingEnabled = YES;
  color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  color.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  color.rgbBlendOperation = MTLBlendOperationAdd;
  color.sourceAlphaBlendFactor = MTLBlendFactorOne;
  color.destinationAlphaBlendFactor = MTLBlendFactorOne;
  color.alphaBlendOperation = MTLBlendOperationAdd;
  NSError* error = nil;
  id<MTLRenderPipelineState> pipeline =
      [provider_->device() newRenderPipelineStateWithDescriptor:descriptor error:&error];
  if (!pipeline) {
    REXLOG_ERROR("MetalImmediateDrawer: Failed to create the pipeline: {}",
                 error ? [error.localizedDescription UTF8String] : "unknown error");
  }
  pipelines_.emplace_back(format, pipeline);
  return pipeline;
}

std::unique_ptr<ImmediateTexture> MetalImmediateDrawer::CreateTexture(uint32_t width,
                                                                      uint32_t height,
                                                                      ImmediateTextureFilter filter,
                                                                      bool is_repeated,
                                                                      const uint8_t* data) {
  MTLTextureDescriptor* descriptor =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                         width:width
                                                        height:height
                                                     mipmapped:NO];
  descriptor.usage = MTLTextureUsageShaderRead;
  descriptor.storageMode = MTLStorageModeShared;
  id<MTLTexture> texture = [provider_->device() newTextureWithDescriptor:descriptor];
  if (!texture) {
    REXLOG_ERROR("MetalImmediateDrawer: Failed to create a {}x{} texture", width, height);
    return nullptr;
  }
  if (data) {
    [texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
               mipmapLevel:0
                 withBytes:data
               bytesPerRow:width * 4];
  }
  return std::make_unique<MetalImmediateTexture>(
      width, height, texture,
      samplers_[filter == ImmediateTextureFilter::kLinear][is_repeated ? 1 : 0]);
}

void MetalImmediateDrawer::Begin(UIDrawContext& ui_draw_context, float coordinate_space_width,
                                 float coordinate_space_height) {
  ImmediateDrawer::Begin(ui_draw_context, coordinate_space_width, coordinate_space_height);
  auto& metal_context = static_cast<MetalUIDrawContext&>(ui_draw_context);
  encoder_ = metal_context.encoder();
  id<MTLRenderPipelineState> pipeline = GetPipeline(metal_context.render_target_format());
  if (!pipeline) {
    encoder_ = nil;
    return;
  }
  [encoder_ setRenderPipelineState:pipeline];
  MTLViewport viewport = {0.0,
                          0.0,
                          double(ui_draw_context.render_target_width()),
                          double(ui_draw_context.render_target_height()),
                          0.0,
                          1.0};
  [encoder_ setViewport:viewport];
  float coordinate_space_size_inv[2] = {1.0f / this->coordinate_space_width(),
                                        1.0f / this->coordinate_space_height()};
  [encoder_ setVertexBytes:coordinate_space_size_inv
                    length:sizeof(coordinate_space_size_inv)
                   atIndex:1];
}

void MetalImmediateDrawer::BeginDrawBatch(const ImmediateDrawBatch& batch) {
  if (!encoder_ || !batch.vertex_count) {
    return;
  }
  id<MTLDevice> device = provider_->device();
  size_t vertices_size = sizeof(ImmediateVertex) * size_t(batch.vertex_count);
  // setVertexBytes is limited to 4 KB.
  if (vertices_size <= 4096) {
    [encoder_ setVertexBytes:batch.vertices length:vertices_size atIndex:0];
  } else {
    id<MTLBuffer> vertex_buffer = [device newBufferWithBytes:batch.vertices
                                                      length:vertices_size
                                                     options:MTLResourceStorageModeShared];
    [encoder_ setVertexBuffer:vertex_buffer offset:0 atIndex:0];
  }
  batch_has_indices_ = batch.indices != nullptr;
  batch_index_buffer_ = nil;
  if (batch_has_indices_) {
    batch_index_buffer_ = [device newBufferWithBytes:batch.indices
                                              length:sizeof(uint16_t) * size_t(batch.index_count)
                                             options:MTLResourceStorageModeShared];
  }
}

void MetalImmediateDrawer::Draw(const ImmediateDraw& draw) {
  if (!encoder_ || draw.count <= 0) {
    return;
  }
  uint32_t scissor_left, scissor_top, scissor_width, scissor_height;
  if (!ScissorToRenderTarget(draw, scissor_left, scissor_top, scissor_width, scissor_height)) {
    return;
  }
  MTLScissorRect scissor = {scissor_left, scissor_top, scissor_width, scissor_height};
  [encoder_ setScissorRect:scissor];
  auto* texture = static_cast<MetalImmediateTexture*>(draw.texture);
  [encoder_ setFragmentTexture:texture ? texture->texture() : white_texture_ atIndex:0];
  [encoder_ setFragmentSamplerState:texture ? texture->sampler() : samplers_[0][0] atIndex:0];
  MTLPrimitiveType primitive_type = draw.primitive_type == ImmediatePrimitiveType::kLines
                                        ? MTLPrimitiveTypeLine
                                        : MTLPrimitiveTypeTriangle;
  if (batch_has_indices_) {
    [encoder_ drawIndexedPrimitives:primitive_type
                         indexCount:NSUInteger(draw.count)
                          indexType:MTLIndexTypeUInt16
                        indexBuffer:batch_index_buffer_
                  indexBufferOffset:sizeof(uint16_t) * NSUInteger(draw.index_offset)
                      instanceCount:1
                         baseVertex:draw.base_vertex
                       baseInstance:0];
  } else {
    [encoder_ drawPrimitives:primitive_type
                 vertexStart:NSUInteger(draw.base_vertex)
                 vertexCount:NSUInteger(draw.count)];
  }
}

void MetalImmediateDrawer::EndDrawBatch() {
  batch_has_indices_ = false;
  batch_index_buffer_ = nil;
}

void MetalImmediateDrawer::End() {
  encoder_ = nil;
  ImmediateDrawer::End();
}

}  // namespace metal
}  // namespace ui
}  // namespace rex
