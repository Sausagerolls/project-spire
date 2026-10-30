#pragma once
/**
 * @file        graphics/metal/render_target_cache.h
 * @brief       EDRAM emulation with host render targets for the Metal backend
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */

// Objective-C++ only.

#include <array>
#include <cstdint>
#include <unordered_map>
#include <vector>

#import <Metal/Metal.h>

#include <rex/graphics/pipeline/render_target/cache.h>
#include <rex/graphics/util/draw.h>
#include <rex/graphics/xenos.h>

namespace rex::graphics::metal {

class MetalCommandProcessor;
class MetalSharedMemory;
class MetalTextureCache;

class MetalRenderTargetCache final : public RenderTargetCache {
 public:
  // What a render pass draws to: depth (with stencil) and up to 4 colors.
  struct RenderPassAttachments {
    id<MTLTexture> depth = nil;
    std::array<id<MTLTexture>, xenos::kMaxColorRenderTargets> color{};
    bool operator==(const RenderPassAttachments& other) const {
      if (depth != other.depth) {
        return false;
      }
      for (uint32_t i = 0; i < xenos::kMaxColorRenderTargets; ++i) {
        if (color[i] != other.color[i]) {
          return false;
        }
      }
      return true;
    }
    bool operator!=(const RenderPassAttachments& other) const { return !(*this == other); }
    bool empty() const {
      if (depth) {
        return false;
      }
      for (id<MTLTexture> texture : color) {
        if (texture) {
          return false;
        }
      }
      return true;
    }
  };

  // Formats of the attachments, for pipelines.
  struct RenderPassFormats {
    MTLPixelFormat depth = MTLPixelFormatInvalid;
    std::array<MTLPixelFormat, xenos::kMaxColorRenderTargets> color{};
    uint32_t sample_count = 1;
  };

  MetalRenderTargetCache(const RegisterFile& register_file, const memory::Memory& memory,
                         MetalCommandProcessor& command_processor)
      : RenderTargetCache(register_file, memory, 1, 1), command_processor_(command_processor) {}
  ~MetalRenderTargetCache() override;

  bool Initialize();
  void Shutdown(bool from_destructor = false);

  Path GetPath() const override { return Path::kHostRenderTargets; }

  bool Update(bool is_rasterization_done, reg::RB_DEPTHCONTROL normalized_depth_control,
              uint32_t normalized_color_mask, const Shader& vertex_shader) override;

  const RenderPassAttachments& last_update_attachments() const { return last_update_attachments_; }

  // Ownership transfers of the last update: performed in the guest render pass
  // of the draw if possible, or in their own render passes otherwise.
  bool has_pending_transfers() const { return has_pending_transfers_; }
  void PerformPendingTransfersInRenderPass(id<MTLRenderCommandEncoder> encoder);
  void FlushPendingTransfers();
  const RenderPassFormats& last_update_formats() const { return last_update_formats_; }
  uint32_t last_update_width() const { return last_update_width_; }
  uint32_t last_update_height() const { return last_update_height_; }

  // Performs the resolve (EDRAM to guest memory copy) and clears.
  bool Resolve(const memory::Memory& memory, MetalSharedMemory& shared_memory,
               MetalTextureCache& texture_cache, uint32_t& written_address_out,
               uint32_t& written_length_out);

  static MTLPixelFormat GetColorMetalFormat(xenos::ColorRenderTargetFormat format);
  static MTLPixelFormat GetDepthMetalFormat(xenos::DepthRenderTargetFormat format);

  // Fixed-point 16-bit formats are stored as SNORM - only [-1, 1].
  bool IsFixedRG16TruncatedToMinus1To1() const { return true; }
  bool IsFixedRGBA16TruncatedToMinus1To1() const { return true; }
  bool gamma_render_target_as_unorm16() const { return false; }
  bool depth_float24_round() const { return false; }
  bool depth_float24_convert_in_pixel_shader() const { return false; }

  // For statistics.
  uint64_t transfer_count() const { return transfer_count_; }

 protected:
  uint32_t GetMaxRenderTargetWidth() const override { return 16384; }
  uint32_t GetMaxRenderTargetHeight() const override { return 16384; }
  RenderTarget* CreateRenderTarget(RenderTargetKey key) override;
  bool IsHostDepthEncodingDifferent(xenos::DepthRenderTargetFormat format) const override;
  bool IsGammaFormatHostStorageSeparate() const override { return false; }

 private:
  class MetalRenderTarget final : public RenderTarget {
   public:
    MetalRenderTarget(RenderTargetKey key, id<MTLTexture> texture, id<MTLTexture> stencil_view)
        : RenderTarget(key), texture_(texture), stencil_view_(stencil_view) {}
    id<MTLTexture> texture() const { return texture_; }
    // For depth render targets, the stencil aspect for sampling.
    id<MTLTexture> stencil_view() const { return stencil_view_; }
    uint32_t temporary_sort_index() const { return temporary_sort_index_; }
    void SetTemporarySortIndex(uint32_t index) { temporary_sort_index_ = index; }

   private:
    id<MTLTexture> texture_;
    id<MTLTexture> stencil_view_;
    uint32_t temporary_sort_index_ = 0;
  };

  union DumpPipelineKey {
    uint32_t key;
    struct {
      xenos::MsaaSamples msaa_samples : 2;
      uint32_t resource_format : 4;
      uint32_t is_depth : 1;
    };
    DumpPipelineKey() : key(0) { static_assert_size(*this, sizeof(key)); }
    bool operator<(const DumpPipelineKey& other_key) const { return key < other_key.key; }
    xenos::ColorRenderTargetFormat GetColorFormat() const {
      return xenos::ColorRenderTargetFormat(resource_format);
    }
    xenos::DepthRenderTargetFormat GetDepthFormat() const {
      return xenos::DepthRenderTargetFormat(resource_format);
    }
  };
  static constexpr uint32_t kDumpSamplesPerGroupX = 8;
  static constexpr uint32_t kDumpSamplesPerGroupY = 16;
  union DumpPitches {
    uint32_t pitches;
    struct {
      uint32_t dest_pitch : xenos::kEdramPitchTilesBits;
      uint32_t source_pitch : xenos::kEdramPitchTilesBits;
    };
    DumpPitches() : pitches(0) { static_assert_size(*this, sizeof(pitches)); }
  };
  union DumpOffsets {
    uint32_t offsets;
    struct {
      uint32_t dispatch_first_tile : xenos::kEdramBaseTilesBits + 1;
      uint32_t source_base_tiles : xenos::kEdramBaseTilesBits;
    };
    DumpOffsets() : offsets(0) { static_assert_size(*this, sizeof(offsets)); }
  };
  enum DumpDescriptorSet : uint32_t {
    kDumpDescriptorSetEdram,
    kDumpDescriptorSetSource,
  };
  enum DumpPushConstant : uint32_t {
    kDumpPushConstantPitches,
    kDumpPushConstantOffsets,
    kDumpPushConstantCount,
  };
  struct DumpInvocation {
    ResolveCopyDumpRectangle rectangle;
    DumpPipelineKey pipeline_key;
    DumpInvocation(const ResolveCopyDumpRectangle& rectangle, const DumpPipelineKey& pipeline_key)
        : rectangle(rectangle), pipeline_key(pipeline_key) {}
    bool operator<(const DumpInvocation& other_invocation) const {
      if (pipeline_key != other_invocation.pipeline_key) {
        return pipeline_key < other_invocation.pipeline_key;
      }
      return static_cast<MetalRenderTarget*>(rectangle.render_target)->temporary_sort_index() <
             static_cast<MetalRenderTarget*>(other_invocation.rectangle.render_target)
                 ->temporary_sort_index();
    }
  };
  friend bool operator!=(const DumpPipelineKey& a, const DumpPipelineKey& b) {
    return a.key != b.key;
  }

  id<MTLComputePipelineState> GetDumpPipeline(DumpPipelineKey key);
  bool DumpRenderTargets(uint32_t dump_base, uint32_t dump_row_length_used, uint32_t dump_rows,
                         uint32_t dump_pitch);
  void PerformTransfers(uint32_t render_target_count, RenderTarget* const* render_targets,
                        const std::vector<Transfer>* render_target_transfers,
                        const Transfer::Rectangle* cutout = nullptr);
  // pass_formats: for a transfer inside a guest render pass with these
  // attachments (writing to color pass_color_index or to depth).
  id<MTLRenderPipelineState> GetTransferPipeline(RenderTargetKey source_key,
                                                 RenderTargetKey dest_key, id<MTLTexture> texture,
                                                 const RenderPassFormats* pass_formats = nullptr,
                                                 uint32_t pass_color_index = 0);
  // Clears a rectangle of a render target to a guest clear value.
  void ClearRenderTarget(RenderTarget* render_target, uint64_t clear_value,
                         const Transfer::Rectangle& rectangle);

  MetalCommandProcessor& command_processor_;

  // The EDRAM contents for resolves (dumped from the host render targets).
  id<MTLBuffer> edram_buffer_ = nil;

  std::unordered_map<uint32_t, id<MTLComputePipelineState>> dump_pipelines_;
  std::vector<ResolveCopyDumpRectangle> dump_rectangles_;
  std::vector<DumpInvocation> dump_invocations_;

  std::array<id<MTLComputePipelineState>, size_t(draw_util::ResolveCopyShaderIndex::kCount)>
      resolve_copy_pipelines_{};

  id<MTLFunction> clear_vs_ = nil;
  id<MTLFunction> clear_color_ps_ = nil;
  id<MTLFunction> clear_depth_ps_ = nil;
  // Keyed by the pixel format and the sample count.
  std::unordered_map<uint32_t, id<MTLRenderPipelineState>> clear_pipelines_;
  id<MTLDepthStencilState> clear_depth_stencil_state_ = nil;
  std::vector<Transfer> clear_transfers_[2];

  // EDRAM ownership transfers between render targets.
  id<MTLLibrary> transfer_library_ = nil;
  id<MTLFunction> transfer_vs_ = nil;
  std::unordered_map<uint64_t, id<MTLRenderPipelineState>> transfer_pipelines_;
  id<MTLDepthStencilState> transfer_no_depth_stencil_state_ = nil;
  // Transfers of the last update, deferred to the guest render pass.
  bool has_pending_transfers_ = false;
  RenderTarget* pending_transfer_render_targets_[1 + xenos::kMaxColorRenderTargets] = {};
  std::vector<Transfer> pending_transfers_[1 + xenos::kMaxColorRenderTargets];
  id<MTLDepthStencilState> transfer_depth_stencil_state_ = nil;

  uint64_t transfer_count_ = 0;

  RenderPassAttachments last_update_attachments_;
  RenderPassFormats last_update_formats_;
  uint32_t last_update_width_ = 0;
  uint32_t last_update_height_ = 0;
};

}  // namespace rex::graphics::metal
