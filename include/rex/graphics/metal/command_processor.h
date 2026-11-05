#pragma once
/**
 * @file        graphics/metal/command_processor.h
 * @brief       Native Metal GPU command processor (macOS)
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */

// Objective-C++ only.

#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <map>
#include <memory>
#include <string>
#include <unordered_map>
#include <mutex>
#include <vector>

#import <Metal/Metal.h>

#include <rex/graphics/command_processor.h>
#include <rex/graphics/metal/pipeline_cache.h>
#include <rex/graphics/metal/primitive_processor.h>
#include <rex/graphics/metal/render_target_cache.h>
#include <rex/graphics/metal/shader.h>
#include <rex/graphics/metal/shared_memory.h>
#include <rex/graphics/metal/texture_cache.h>
#include <rex/graphics/pipeline/shader/spirv_translator.h>
#include <rex/graphics/util/draw.h>

namespace rex::ui::metal {
class MetalProvider;
}

namespace rex::graphics::metal {

class MetalGraphicsSystem;

class MetalCommandProcessor : public CommandProcessor {
 public:
  MetalCommandProcessor(MetalGraphicsSystem* graphics_system, system::KernelState* kernel_state);
  ~MetalCommandProcessor() override;

  void ClearCaches() override;

  void IssueSwap(uint32_t frontbuffer_ptr, uint32_t frontbuffer_width,
                 uint32_t frontbuffer_height) override;

  const ui::metal::MetalProvider& GetMetalProvider() const;
  id<MTLDevice> device() const { return device_; }
  MetalRenderTargetCache& render_target_cache() { return *render_target_cache_; }

  // Submissions are command buffers, frames are guest frames (between swaps).
  uint64_t GetCurrentSubmission() const { return submission_current_; }
  uint64_t GetCompletedSubmission() const {
    return submission_completed_.load(std::memory_order_acquire);
  }
  uint64_t GetCurrentFrame() const { return frame_current_; }
  uint64_t GetCompletedFrame() const { return frame_completed_; }
  // Ends the current submission and waits until all GPU work has completed.
  void AwaitAllSubmissionsCompletion();

  // The command buffer of the current submission (begins it if needed).
  id<MTLCommandBuffer> GetCommandBuffer();
  // Ends the current render, compute or blit encoder.
  void EndEncoding();
  // Counts why the current guest render pass is ended (for metal_log_stats).
  void CountRenderPassBreak(const char* reason);
  // Return the compute or blit encoder, ending any other encoder.
  // The reason names the work for render pass break statistics.
  id<MTLComputeCommandEncoder> GetComputeEncoder(const char* reason = "compute");
  id<MTLBlitCommandEncoder> GetBlitEncoder(const char* reason = "blit");
  // The render encoder for the render targets from the last render target
  // cache update, beginning a new render pass if needed.
  id<MTLRenderCommandEncoder> GetRenderEncoderForCurrentRenderTargets();
  // Begins a render pass with the given descriptor for utility drawing (the
  // caller ends it implicitly via EndEncoding).
  id<MTLRenderCommandEncoder> BeginUtilityRenderPass(MTLRenderPassDescriptor* descriptor,
                                                     const char* reason = "utility pass");

  // A command buffer committed right before the current submission, for work
  // that must not split guest render passes (texture loads). Only for work
  // that doesn't depend on GPU work in the current submission.
  id<MTLComputeCommandEncoder> GetUploadComputeEncoder();
  id<MTLBlitCommandEncoder> GetUploadBlitEncoder();
  // Guest memory written by the GPU (resolves, memexport) in the current
  // submission - reading it needs ordering after that work.
  void MarkGpuWrittenInSubmission(uint32_t start, uint32_t length);
  bool IsGpuWrittenInSubmission(uint32_t start, uint32_t length) const;
  // Whether a render pass for guest drawing is open.
  bool IsGuestRenderPassOpen() const { return render_encoder_ && !render_encoder_is_utility_; }
  // Clears a whole render target at the start of the next render pass that uses it (as its
  // load action), or in its own pass before any other GPU work, which may read it.
  void DeferClear(id<MTLTexture> texture, bool is_depth, const float values[4],
                  uint32_t stencil);
  void FlushDeferredClears();

  // Per-frame transient GPU memory (constants and other small data), valid
  // until the frame completes on the GPU.
  bool RequestTransientBuffer(size_t size, size_t alignment, __strong id<MTLBuffer>& buffer_out,
                              NSUInteger& offset_out, void*& mapping_out);

  // Converts a SPIR-V utility shader to MSL and compiles it.
  id<MTLFunction> CompileUtilitySpirv(const uint32_t* spirv, size_t spirv_word_count,
                                      const char* debug_name);

 protected:
  bool SetupContext() override;
  void ShutdownContext() override;

  void WriteRegister(uint32_t index, uint32_t value) override;
  void WriteRegistersFromMem(uint32_t start_index, uint32_t* base, uint32_t num_registers) override;

  void OnGammaRamp256EntryTableValueWritten() override;
  void OnGammaRampPWLValueWritten() override;

  void OnPrimaryBufferEnd() override;

  void WriteMemoryFromCommandStream(uint32_t address, uint32_t value,
                                    bool is_fence = false) override;
  bool ExecutePacketType3_XE_NATIVE(memory::RingBuffer* reader, uint32_t packet,
                                    uint32_t count) override;
  bool AwaitCommandStreamMemoryWrites(uint32_t address) override;
  bool GetPendingCommandStreamMemoryWrite(uint32_t address, uint32_t& value_out) override;

  Shader* LoadShader(xenos::ShaderType shader_type, uint32_t guest_address,
                     const uint32_t* host_address, uint32_t dword_count) override;

  bool IssueDraw(xenos::PrimitiveType prim_type, uint32_t index_count,
                 IndexBufferInfo* index_buffer_info, bool major_mode_explicit) override;
  bool IssueCopy() override;

  void InitializeShaderStorage(const std::filesystem::path& cache_root, uint32_t title_id,
                               bool blocking) override;

 private:
  bool IssueDrawImpl();
  void ApplyMergedTileScissor();
  void IssueSwapImpl(uint32_t frontbuffer_ptr, uint32_t frontbuffer_width,
                     uint32_t frontbuffer_height);
  void BeginFrameIfNeeded();
  // Commits the current command buffer if there is one, and if is_swap, ends
  // the guest frame.
  void EndSubmission(bool is_swap);
  void UpdateCompletedFrame();

  void UpdateSystemConstantValues(
      bool primitive_polygonal,
      const PrimitiveProcessor::ProcessingResult& primitive_processing_result,
      const draw_util::ViewportInfo& viewport_info, uint32_t used_texture_mask,
      reg::RB_DEPTHCONTROL normalized_depth_control, uint32_t normalized_color_mask);
  bool UpdateConstantBuffers(const MetalShader* vertex_shader, const MetalShader* pixel_shader);
  void BindDrawResources(id<MTLRenderCommandEncoder> encoder, const MetalShader* vertex_shader,
                         const MetalShader* pixel_shader);
  // Returns false if nothing will be drawn (empty scissor or all culled).
  bool UpdateDynamicState(id<MTLRenderCommandEncoder> encoder,
                          const draw_util::ViewportInfo& viewport_info, bool primitive_polygonal,
                          reg::RB_DEPTHCONTROL normalized_depth_control, bool memexport_only);

  id<MTLDevice> device_ = nil;
  id<MTLCommandQueue> queue_ = nil;

  std::unique_ptr<MetalSharedMemory> shared_memory_;
  std::unique_ptr<MetalPrimitiveProcessor> primitive_processor_;
  std::unique_ptr<MetalRenderTargetCache> render_target_cache_;
  std::unique_ptr<MetalPipelineCache> pipeline_cache_;
  std::unique_ptr<MetalTextureCache> texture_cache_;

  id<MTLComputePipelineState> swap_pipeline_ = nil;

  // Index buffers for tessellation drawn as an indexed grid, per grid factor:
  // (factor + 1)^2 vertices per patch, factor^2 quads of 2 triangles.
  struct TessellationGridIndices {
    id<MTLBuffer> buffer = nil;
    uint32_t patch_capacity = 0;
  };
  std::unordered_map<uint32_t, TessellationGridIndices> tessellation_grid_indices_;
  id<MTLBuffer> GetTessellationGridIndices(uint32_t factor, uint32_t patch_count);
  // Draws a quad-domain patch draw with the Metal tessellator.
  static constexpr uint32_t kTessellationPatchControlPoints = 0;
  bool DrawHardwareTessellated(id<MTLRenderCommandEncoder> encoder,
                               const PrimitiveProcessor::ProcessingResult& primitive_processing_result);

  // Submissions.
  id<MTLCommandBuffer> command_buffer_ = nil;
  uint64_t submission_current_ = 1;
  std::atomic<uint64_t> submission_completed_{0};
  // Frames.
  static constexpr uint32_t kMaxFramesInFlight = 2;
  bool frame_open_ = false;
  uint64_t frame_current_ = 1;
  uint64_t frame_completed_ = 0;
  uint64_t closed_frame_submissions_[kMaxFramesInFlight] = {};

  // Command stream memory writes (fences) waiting for the GPU to complete the
  // submission they follow, because the GPU reads guest memory directly and
  // the guest may reuse it as soon as it sees the fence value.
  struct DeferredMemoryWrite {
    uint64_t submission;
    uint32_t address;
    uint32_t value;
    bool is_fence;
  };
  std::mutex deferred_memory_writes_mutex_;
  // Notified when a submission completes.
  std::condition_variable submission_completed_cv_;
  // GPU execution time of completed command buffers (seconds, for stats).
  std::atomic<double> gpu_busy_seconds_{0.0};
  std::atomic<double> gpu_upload_busy_seconds_{0.0};
  std::deque<DeferredMemoryWrite> deferred_memory_writes_;
  // Applies the deferred writes up to the completed submission (with the
  // mutex locked).
  void ApplyDeferredMemoryWrites(uint64_t completed_submission);

  // Upload command buffer (committed before command_buffer_).
  id<MTLCommandBuffer> upload_command_buffer_ = nil;
  id<MTLComputeCommandEncoder> upload_compute_encoder_ = nil;
  id<MTLBlitCommandEncoder> upload_blit_encoder_ = nil;
  std::vector<std::pair<uint32_t, uint32_t>> submission_gpu_written_ranges_;

  // Encoders (one at a time).
  id<MTLRenderCommandEncoder> render_encoder_ = nil;
  id<MTLComputeCommandEncoder> compute_encoder_ = nil;
  id<MTLBlitCommandEncoder> blit_encoder_ = nil;
  // Reason the open compute or blit encoder was started for (labels, with metal_log_stats).
  const char* encoder_reason_ = nullptr;
  MetalRenderTargetCache::RenderPassAttachments render_encoder_attachments_;
  // The render encoder is for utility drawing, not the guest render targets.
  bool render_encoder_is_utility_ = false;
  struct DeferredClear {
    bool is_depth;
    float values[4];
    uint32_t stencil;
  };
  std::vector<std::pair<id<MTLTexture>, DeferredClear>> deferred_clears_;
  // State bound to the current render encoder.
  id<MTLRenderPipelineState> encoder_pipeline_ = nil;
  id<MTLDepthStencilState> encoder_depth_stencil_state_ = nil;
  id<MTLRenderCommandEncoder> encoder_shared_memory_bound_ = nil;
  // Textures and samplers bound to the current render encoder (per stage, per
  // slot; not retained - only compared), to skip redundant bindings.
  static constexpr uint32_t kMaxBoundTextures = 32;
  static constexpr uint32_t kMaxBoundSamplers = 16;
  std::array<std::array<const void*, kMaxBoundTextures>, 2> encoder_textures_{};
  std::array<std::array<const void*, kMaxBoundSamplers>, 2> encoder_samplers_{};
  // Per stage: hash of the shader and the fetch constants of its textures and
  // samplers bound to the current encoder, to skip the whole binding.
  std::array<uint64_t, 2> encoder_binding_hash_{};
  bool encoder_bindings_valid_[2] = {};
  // Memexport wrote guest memory in the current render encoder - later draws
  // reading it need a new encoder (ordered by hazard tracking).
  bool encoder_memexport_written_ = false;

  // Transient memory: pages of shared buffers, reused when their frame has
  // completed.
  static constexpr size_t kTransientPageSize = 4 * 1024 * 1024;
  struct TransientPage {
    id<MTLBuffer> buffer;
    uint64_t last_frame;
  };
  std::deque<TransientPage> transient_pages_free_;
  std::deque<TransientPage> transient_pages_used_;
  id<MTLBuffer> transient_page_current_ = nil;
  size_t transient_page_current_used_ = kTransientPageSize;

  // Per-draw state.
  SpirvShaderTranslator::SystemConstants system_constants_;
  uint64_t current_float_constant_map_vertex_[4] = {};
  uint64_t current_float_constant_map_pixel_[4] = {};
  // Bits of SpirvShaderTranslator::ConstantBuffer.
  uint32_t current_constant_buffers_up_to_date_ = 0;
  uint32_t constant_buffers_to_bind_ = 0;
  struct ConstantBufferBinding {
    id<MTLBuffer> buffer = nil;
    NSUInteger offset = 0;
  };
  std::array<ConstantBufferBinding, SpirvShaderTranslator::kConstantBufferCount>
      current_constant_buffers_;
  std::vector<draw_util::MemExportRange> memexport_ranges_;

  struct Stats {
    uint64_t swaps = 0;
    uint64_t draws_requested = 0;
    uint64_t draws_encoded = 0;
    uint64_t draws_failed = 0;
    uint64_t resolves = 0;
    uint64_t resolves_written = 0;
    uint64_t memexport_draws = 0;
    uint64_t submissions = 0;
    uint64_t deferred_memory_writes = 0;
    uint64_t guest_render_passes = 0;
    uint64_t texture_loads_reordered = 0;
    double cp_wait_seconds = 0.0;
    // Frame times (between swaps).
    double worst_frame_ms = 0.0;
    uint32_t frames_over_50ms = 0;
    uint32_t frames_over_100ms = 0;
    uint64_t vertices = 0;
    std::map<std::string, uint64_t> vertices_by_type;
    std::unordered_map<uint64_t, uint64_t> vertices_by_shader;
    std::map<std::string, uint64_t> render_pass_breaks;
    std::map<std::string, uint64_t> utility_passes;
    std::chrono::steady_clock::time_point last_log{};
  };
  Stats stats_;
  uint64_t frame_rate_draw_count_ = 0;
  uint64_t total_swaps_ = 0;
  std::chrono::steady_clock::time_point last_swap_time_{};
};

}  // namespace rex::graphics::metal
