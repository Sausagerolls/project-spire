/**
 * @file        graphics/metal/command_processor.mm
 * @brief       Native Metal GPU command processor (macOS)
 *
 * The draw logic follows the Vulkan backend (Xenia, Copyright 2022 Ben
 * Vanik, BSD license).
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */

#include <rex/graphics/metal/command_processor.h>

#include <algorithm>
#include <cstring>
#include <chrono>
#include <string>
#include <thread>
#include <unordered_map>

#include <rex/assert.h>
#include <rex/cvar.h>
#include <rex/dbg.h>
#include <rex/graphics/flags.h>
#include <rex/graphics/graphics_system.h>
#include <rex/graphics/metal/graphics_system.h>
#include <rex/graphics/metal/msl_util.h>
#include <rex/graphics/pipeline/texture/util.h>
#include <rex/graphics/register_file.h>
#include <rex/graphics/registers.h>
#include <rex/graphics/xenos.h>
#include <rex/kernel/xboxkrnl/video.h>
#include <rex/logging.h>
#include <rex/math.h>
#include <rex/memory.h>
#include <rex/ui/metal/metal_presenter.h>
#include <rex/ui/metal/metal_provider.h>

REXCVAR_DEFINE_BOOL(metal_log_frame_rate, false, "GPU/Metal",
                    "Log the guest frame rate (swaps per second) and draws per frame about every "
                    "5 seconds")
    .lifecycle(rex::cvar::Lifecycle::kHotReload);
REXCVAR_DEFINE_BOOL(metal_defer_fence_writes, true, "GPU/Metal",
                    "Delay command stream memory writes (fences) until the GPU has completed the "
                    "preceding work, so the guest doesn't reuse memory the GPU still reads or writes "
                    "(required: resolves landing in freed memory corrupt the guest heap)")
    .lifecycle(rex::cvar::Lifecycle::kHotReload);
REXCVAR_DEFINE_BOOL(metal_wait_on_pending_writes, false, "GPU/Metal",
                    "Let WAIT_REG_MEM in the command stream see delayed fence writes as already "
                    "done (the GPU executes the commands in order anyway), instead of waiting for "
                    "the GPU to complete")
    .lifecycle(rex::cvar::Lifecycle::kHotReload);
REXCVAR_DEFINE_BOOL(metal_commit_on_fence, true, "GPU/Metal",
                    "Submit the GPU work when the command stream writes a fence, so the fence "
                    "is signaled as early as possible (with metal_defer_fence_writes)")
    .lifecycle(rex::cvar::Lifecycle::kHotReload);
REXCVAR_DEFINE_BOOL(metal_reorder_texture_loads, true, "GPU/Metal",
                    "Load textures that don't depend on GPU work of the current submission in a "
                    "command buffer submitted before it, so loads don't split render passes")
    .lifecycle(rex::cvar::Lifecycle::kHotReload);
REXCVAR_DEFINE_INT32(metal_log_draws, 0, "GPU/Metal",
                     "Log the next N draws with the registers the command processor received "
                     "(for comparison with the game's D3D-level draw capture)")
    .lifecycle(rex::cvar::Lifecycle::kHotReload);
REXCVAR_DEFINE_BOOL(metal_sync_submissions, false, "GPU/Metal",
                    "Wait for the GPU after every submission (debugging CPU / GPU memory hazards)")
    .lifecycle(rex::cvar::Lifecycle::kHotReload);
REXCVAR_DEFINE_BOOL(metal_log_stats, false, "GPU/Metal",
                    "Log Metal backend draw and resolve statistics about every 5 seconds")
    .lifecycle(rex::cvar::Lifecycle::kHotReload);

namespace rex::graphics::metal {

namespace {

// Copies the front buffer (a guest texture in shared memory) to the guest
// output image. 32bpp formats only for now.
NSString* const kSwapShaderSource = @R"(
#include <metal_stdlib>
using namespace metal;
struct SwapConstants {
  uint base;
  uint pitch;
  uint tiled;
  uint endian;
  uint format;
  uint width;
  uint height;
  uint swizzle;
};
int tiled_offset_2d(int x, int y, uint pitch, uint bpb_log2) {
  pitch = (pitch + 31u) & ~31u;
  int macro = ((x >> 5) + (y >> 5) * int(pitch >> 5)) << (bpb_log2 + 7);
  int micro = ((x & 7) + ((y & 0xE) << 2)) << bpb_log2;
  int offset = macro + ((micro & ~0xF) << 1) + (micro & 0xF) + ((y & 1) << 4);
  return ((offset & ~0x1FF) << 3) + ((y & 16) << 7) + ((offset & 0x1C0) << 2) +
         (((((y & 8) >> 2) + (x >> 3)) & 3) << 6) + (offset & 0x3F);
}
uint swap_endian(uint value, uint endian) {
  if (endian == 1u || endian == 2u) {
    value = ((value & 0x00FF00FFu) << 8u) | ((value & 0xFF00FF00u) >> 8u);
  }
  if (endian == 2u || endian == 3u) {
    value = (value << 16u) | (value >> 16u);
  }
  return value;
}
float f7e3_to_f32(uint f10) {
  uint mantissa = f10 & 0x7Fu;
  uint exponent = (f10 >> 7u) & 7u;
  if (exponent == 0u) {
    return float(mantissa) * exp2(-13.0);
  }
  return (1.0 + float(mantissa) / 128.0) * exp2(float(exponent) - 3.0);
}
kernel void swap_cs(device const uint* memory [[buffer(0)]],
                    constant SwapConstants& constants [[buffer(1)]],
                    texture2d<float, access::write> output [[texture(0)]],
                    uint2 xy [[thread_position_in_grid]]) {
  if (xy.x >= constants.width || xy.y >= constants.height) {
    return;
  }
  uint offset = constants.tiled != 0u
                    ? uint(tiled_offset_2d(int(xy.x), int(xy.y), constants.pitch, 2u))
                    : (xy.y * constants.pitch + xy.x) * 4u;
  uint value = swap_endian(memory[(constants.base + offset) >> 2u], constants.endian);
  float4 source;
  if (constants.format == 0u) {
    source = float4(float(value & 0xFFu), float((value >> 8u) & 0xFFu),
                    float((value >> 16u) & 0xFFu), float(value >> 24u)) / 255.0;
  } else {
    source = float4(float(value & 0x3FFu) / 1023.0, float((value >> 10u) & 0x3FFu) / 1023.0,
                    float((value >> 20u) & 0x3FFu) / 1023.0, float(value >> 30u) / 3.0);
  }
  // The fetch constant swizzle (3 bits per component: XYZW, 0, 1).
  float4 color;
  for (uint i = 0u; i < 4u; ++i) {
    uint component = (constants.swizzle >> (3u * i)) & 7u;
    color[i] = component < 4u ? source[component] : (component == 4u ? 0.0 : 1.0);
  }
  output.write(float4(color.rgb, 1.0), xy);
}
)";

}  // namespace

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
  const ui::metal::MetalProvider& provider = GetMetalProvider();
  device_ = provider.device();
  queue_ = provider.queue();

  shared_memory_ = std::make_unique<MetalSharedMemory>(*memory_, device_);
  if (!shared_memory_->Initialize()) {
    REXGPU_ERROR("Failed to initialize shared memory");
    return false;
  }
  primitive_processor_ = std::make_unique<MetalPrimitiveProcessor>(*register_file_, *memory_,
                                                                   *shared_memory_, device_);
  if (!primitive_processor_->Initialize()) {
    REXGPU_ERROR("Failed to initialize the geometric primitive processor");
    return false;
  }
  render_target_cache_ = std::make_unique<MetalRenderTargetCache>(*register_file_, *memory_, *this);
  if (!render_target_cache_->Initialize()) {
    REXGPU_ERROR("Failed to initialize the render target cache");
    return false;
  }
  pipeline_cache_ =
      std::make_unique<MetalPipelineCache>(*this, *register_file_, *render_target_cache_);
  if (!pipeline_cache_->Initialize()) {
    REXGPU_ERROR("Failed to initialize the graphics pipeline cache");
    return false;
  }
  texture_cache_ = MetalTextureCache::Create(*register_file_, *shared_memory_, *this);
  if (!texture_cache_) {
    REXGPU_ERROR("Failed to initialize the texture cache");
    return false;
  }

  id<MTLLibrary> swap_library = provider.CompileLibrary(kSwapShaderSource, "swap");
  if (swap_library) {
    id<MTLFunction> swap_function = [swap_library newFunctionWithName:@"swap_cs"];
    NSError* error = nil;
    swap_pipeline_ = [device_ newComputePipelineStateWithFunction:swap_function error:&error];
  }
  if (!swap_pipeline_) {
    REXGPU_ERROR("Failed to create the swap pipeline");
    return false;
  }

  std::memset(&system_constants_, 0, sizeof(system_constants_));
  current_constant_buffers_up_to_date_ = 0;
  REXGPU_INFO("Metal command processor: initialized (zero-copy guest memory)");
  return true;
}

void MetalCommandProcessor::ShutdownContext() {
  AwaitAllSubmissionsCompletion();
  texture_cache_.reset();
  pipeline_cache_.reset();
  render_target_cache_.reset();
  primitive_processor_.reset();
  shared_memory_.reset();
  transient_pages_free_.clear();
  transient_pages_used_.clear();
  transient_page_current_ = nil;
  swap_pipeline_ = nil;
  CommandProcessor::ShutdownContext();
}

void MetalCommandProcessor::ClearCaches() {
  CommandProcessor::ClearCaches();
}

void MetalCommandProcessor::InitializeShaderStorage(const std::filesystem::path& cache_root,
                                                    uint32_t title_id, bool blocking) {
  CommandProcessor::InitializeShaderStorage(cache_root, title_id, blocking);
}

void MetalCommandProcessor::WriteRegister(uint32_t index, uint32_t value) {
  CommandProcessor::WriteRegister(index, value);

  if (index >= XE_GPU_REG_SHADER_CONSTANT_000_X && index <= XE_GPU_REG_SHADER_CONSTANT_511_W) {
    uint32_t float_constant_index = (index - XE_GPU_REG_SHADER_CONSTANT_000_X) >> 2;
    if (float_constant_index >= 256) {
      float_constant_index -= 256;
      if (current_float_constant_map_pixel_[float_constant_index >> 6] &
          (1ull << (float_constant_index & 63))) {
        current_constant_buffers_up_to_date_ &=
            ~(UINT32_C(1) << SpirvShaderTranslator::kConstantBufferFloatPixel);
      }
    } else {
      if (current_float_constant_map_vertex_[float_constant_index >> 6] &
          (1ull << (float_constant_index & 63))) {
        current_constant_buffers_up_to_date_ &=
            ~(UINT32_C(1) << SpirvShaderTranslator::kConstantBufferFloatVertex);
      }
    }
  } else if (index >= XE_GPU_REG_SHADER_CONSTANT_BOOL_000_031 &&
             index <= XE_GPU_REG_SHADER_CONSTANT_LOOP_31) {
    current_constant_buffers_up_to_date_ &=
        ~(UINT32_C(1) << SpirvShaderTranslator::kConstantBufferBoolLoop);
  } else if (index >= XE_GPU_REG_SHADER_CONSTANT_FETCH_00_0 &&
             index <= XE_GPU_REG_SHADER_CONSTANT_FETCH_31_5) {
    current_constant_buffers_up_to_date_ &=
        ~(UINT32_C(1) << SpirvShaderTranslator::kConstantBufferFetch);
    if (texture_cache_) {
      texture_cache_->TextureFetchConstantWritten((index - XE_GPU_REG_SHADER_CONSTANT_FETCH_00_0) /
                                                  6);
    }
  }
}

void MetalCommandProcessor::WriteRegistersFromMem(uint32_t start_index, uint32_t* base,
                                                  uint32_t num_registers) {
  // Like the Vulkan backend: write constant ranges in bulk.
  if (!num_registers) {
    return;
  }
  uint32_t end_index = start_index + num_registers - 1;
  if (start_index >= XE_GPU_REG_SHADER_CONSTANT_000_X &&
      end_index <= XE_GPU_REG_SHADER_CONSTANT_511_W) {
    memory::copy_and_swap(register_file_->values + start_index, base, num_registers);
    uint32_t first = (start_index - XE_GPU_REG_SHADER_CONSTANT_000_X) >> 2;
    uint32_t last = (end_index - XE_GPU_REG_SHADER_CONSTANT_000_X) >> 2;
    for (uint32_t constant = first; constant <= last; ++constant) {
      if (constant < 256) {
        if (current_float_constant_map_vertex_[constant >> 6] & (1ull << (constant & 63))) {
          current_constant_buffers_up_to_date_ &=
              ~(UINT32_C(1) << SpirvShaderTranslator::kConstantBufferFloatVertex);
        }
      } else {
        uint32_t pixel_constant = constant - 256;
        if (current_float_constant_map_pixel_[pixel_constant >> 6] &
            (1ull << (pixel_constant & 63))) {
          current_constant_buffers_up_to_date_ &=
              ~(UINT32_C(1) << SpirvShaderTranslator::kConstantBufferFloatPixel);
        }
      }
    }
    return;
  }
  if (start_index >= XE_GPU_REG_SHADER_CONSTANT_BOOL_000_031 &&
      end_index <= XE_GPU_REG_SHADER_CONSTANT_LOOP_31) {
    memory::copy_and_swap(register_file_->values + start_index, base, num_registers);
    current_constant_buffers_up_to_date_ &=
        ~(UINT32_C(1) << SpirvShaderTranslator::kConstantBufferBoolLoop);
    return;
  }
  if (start_index >= XE_GPU_REG_SHADER_CONSTANT_FETCH_00_0 &&
      end_index <= XE_GPU_REG_SHADER_CONSTANT_FETCH_31_5) {
    memory::copy_and_swap(register_file_->values + start_index, base, num_registers);
    current_constant_buffers_up_to_date_ &=
        ~(UINT32_C(1) << SpirvShaderTranslator::kConstantBufferFetch);
    if (texture_cache_) {
      texture_cache_->TextureFetchConstantsWritten(
          (start_index - XE_GPU_REG_SHADER_CONSTANT_FETCH_00_0) / 6,
          (end_index - XE_GPU_REG_SHADER_CONSTANT_FETCH_00_0) / 6);
    }
    return;
  }
  CommandProcessor::WriteRegistersFromMem(start_index, base, num_registers);
}

void MetalCommandProcessor::OnGammaRamp256EntryTableValueWritten() {}

void MetalCommandProcessor::OnGammaRampPWLValueWritten() {}

void MetalCommandProcessor::OnPrimaryBufferEnd() {
  // Submit the work so far, so the GPU starts on it while the next primary
  // buffer is processed.
  if (command_buffer_) {
    EndSubmission(false);
  }
}

id<MTLBuffer> MetalCommandProcessor::GetTessellationGridIndices(uint32_t factor,
                                                               uint32_t patch_count) {
  TessellationGridIndices& indices = tessellation_grid_indices_[factor];
  if (indices.buffer && indices.patch_capacity >= patch_count) {
    return indices.buffer;
  }
  uint32_t capacity = std::max(patch_count, std::max(indices.patch_capacity * 2, uint32_t(64)));
  uint32_t points_per_row = factor + 1;
  uint32_t points_per_patch = points_per_row * points_per_row;
  size_t indices_per_patch = size_t(factor) * factor * 6;
  std::vector<uint32_t> data(indices_per_patch * capacity);
  // The same triangulation as the non-indexed grid: quad diagonals pointing to
  // the center of the patch, clockwise in the domain.
  uint32_t half_factor = factor >> 1;
  uint32_t* out = data.data();
  for (uint32_t patch = 0; patch < capacity; ++patch) {
    uint32_t patch_base = patch * points_per_patch;
    for (uint32_t y = 0; y < factor; ++y) {
      for (uint32_t x = 0; x < factor; ++x) {
        bool main_diagonal = (x < half_factor) == (y < half_factor);
        uint32_t offsets_x = main_diagonal ? 0b010110 : 0b011010;
        uint32_t offsets_y = 0b110100;
        for (uint32_t vertex = 0; vertex < 6; ++vertex) {
          uint32_t point_x = x + ((offsets_x >> vertex) & 1);
          uint32_t point_y = y + ((offsets_y >> vertex) & 1);
          *(out++) = patch_base + point_y * points_per_row + point_x;
        }
      }
    }
  }
  id<MTLBuffer> buffer = [device_ newBufferWithBytes:data.data()
                                              length:data.size() * sizeof(uint32_t)
                                             options:MTLResourceStorageModeShared];
  if (!buffer) {
    return nil;
  }
  // The old buffer may still be used by submitted work - retained by it.
  indices.buffer = buffer;
  indices.patch_capacity = capacity;
  return buffer;
}

bool MetalCommandProcessor::ExecutePacketType3_XE_NATIVE(memory::RingBuffer* reader,
                                                         uint32_t packet, uint32_t count) {
  if (!count) {
    return true;
  }
  uint32_t subcommand = reader->ReadAndSwap<uint32_t>();
  uint32_t remaining = count - 1;
  // Subcommand 1: the D3D surfaces bound (depth / stencil, then 4 colors), 5
  // dwords each: object, RB_SURFACE_INFO, RB_COLOR_INFO / RB_DEPTH_INFO, size,
  // D3DFORMAT.
  constexpr uint32_t kSurfaceCount = 1 + xenos::kMaxColorRenderTargets;
  if (subcommand == 1 && remaining >= kSurfaceCount * 5) {
    MetalRenderTargetCache::NativeSurface surfaces[kSurfaceCount];
    for (uint32_t i = 0; i < kSurfaceCount; ++i) {
      surfaces[i].object = reader->ReadAndSwap<uint32_t>();
      surfaces[i].surface_info = reader->ReadAndSwap<uint32_t>();
      surfaces[i].info = reader->ReadAndSwap<uint32_t>();
      surfaces[i].size = reader->ReadAndSwap<uint32_t>();
      surfaces[i].format = reader->ReadAndSwap<uint32_t>();
    }
    remaining -= kSurfaceCount * 5;
    render_target_cache_->SetNativeSurfaces(surfaces);
  }
  reader->AdvanceRead(remaining * sizeof(uint32_t));
  return true;
}

void MetalCommandProcessor::WriteMemoryFromCommandStream(uint32_t address, uint32_t value,
                                                         bool is_fence) {
  // The write must become visible to the guest only after the GPU work
  // encoded so far: the current command buffer if there is one, otherwise the
  // last committed one.
  bool defer = REXCVAR_GET(metal_defer_fence_writes);
  bool commit = defer && command_buffer_ && REXCVAR_GET(metal_commit_on_fence);
  uint64_t after_submission = submission_current_ - (command_buffer_ ? 0 : 1);
  {
    std::lock_guard<std::mutex> lock(deferred_memory_writes_mutex_);
    uint64_t completed_submission = GetCompletedSubmission();
    if (!defer || completed_submission >= after_submission) {
      // Earlier deferred writes follow earlier submissions, so they're due too.
      ApplyDeferredMemoryWrites(UINT64_MAX);
      CommandProcessor::WriteMemoryFromCommandStream(address, value);
      return;
    }
    deferred_memory_writes_.push_back({after_submission, address, value, is_fence});
    ++stats_.deferred_memory_writes;
  }
  if (commit) {
    // The guest is likely to wait for the fence - start the GPU work now.
    EndSubmission(false);
  }
}

void MetalCommandProcessor::ApplyDeferredMemoryWrites(uint64_t completed_submission) {
  while (!deferred_memory_writes_.empty() &&
         deferred_memory_writes_.front().submission <= completed_submission) {
    const DeferredMemoryWrite& write = deferred_memory_writes_.front();
    CommandProcessor::WriteMemoryFromCommandStream(write.address, write.value);
    deferred_memory_writes_.pop_front();
  }
}

bool MetalCommandProcessor::GetPendingCommandStreamMemoryWrite(uint32_t address,
                                                               uint32_t& value_out) {
  if (!REXCVAR_GET(metal_wait_on_pending_writes)) {
    return false;
  }
  std::lock_guard<std::mutex> lock(deferred_memory_writes_mutex_);
  for (auto it = deferred_memory_writes_.rbegin(); it != deferred_memory_writes_.rend(); ++it) {
    if (it->address == address) {
      if (!it->is_fence) {
        return false;
      }
      value_out = it->value;
      return true;
    }
  }
  return false;
}

bool MetalCommandProcessor::AwaitCommandStreamMemoryWrites(uint32_t address) {
  // The awaited value may be written by the GPU work encoded so far (resolves,
  // memexport) or by a delayed write following it - submit it in any case.
  if (command_buffer_) {
    EndSubmission(false);
  }
  // Only wait for the GPU if a delayed write to the polled address is pending
  // (other values, such as flags set by the guest's interrupt handlers, are
  // polled as usual).
  uint64_t await_submission = 0;
  {
    std::lock_guard<std::mutex> lock(deferred_memory_writes_mutex_);
    for (const DeferredMemoryWrite& write : deferred_memory_writes_) {
      if (write.address == address) {
        await_submission = write.submission;
        break;
      }
    }
  }
  if (!await_submission) {
    return false;
  }
  std::unique_lock<std::mutex> lock(deferred_memory_writes_mutex_);
  submission_completed_cv_.wait_for(lock, std::chrono::milliseconds(4), [&] {
    return GetCompletedSubmission() >= await_submission;
  });
  return true;
}

// Submissions and frames.

id<MTLCommandBuffer> MetalCommandProcessor::GetCommandBuffer() {
  if (!command_buffer_) {
    BeginFrameIfNeeded();
    command_buffer_ = [queue_ commandBuffer];
    command_buffer_.label = @"guest";
    uint64_t submission = submission_current_;
    [command_buffer_ addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
      if (buffer.status == MTLCommandBufferStatusError) {
        REXGPU_ERROR("Metal command buffer {} failed: {}", submission,
                     buffer.error ? [buffer.error.localizedDescription UTF8String] : "unknown");
      }
      // The queue completes command buffers in order.
      std::lock_guard<std::mutex> lock(deferred_memory_writes_mutex_);
      submission_completed_.store(submission, std::memory_order_release);
      ApplyDeferredMemoryWrites(submission);
      submission_completed_cv_.notify_all();
    }];
  }
  return command_buffer_;
}

void MetalCommandProcessor::BeginFrameIfNeeded() {
  if (frame_open_) {
    return;
  }
  // Wait for the frame that used the same in-flight slot to complete.
  UpdateCompletedFrame();
  if (frame_current_ > kMaxFramesInFlight) {
    uint64_t await_submission = closed_frame_submissions_[frame_current_ % kMaxFramesInFlight];
    while (GetCompletedSubmission() < await_submission) {
      std::this_thread::yield();
    }
    UpdateCompletedFrame();
  }
  frame_open_ = true;
  // Reclaim transient pages of completed frames.
  while (!transient_pages_used_.empty() &&
         transient_pages_used_.front().last_frame <= frame_completed_) {
    if (transient_pages_used_.front().buffer.length == kTransientPageSize) {
      transient_pages_free_.push_back(transient_pages_used_.front());
    }
    transient_pages_used_.pop_front();
  }
  texture_cache_->BeginFrame();
  render_target_cache_->BeginFrame();
  current_constant_buffers_up_to_date_ = 0;
}

void MetalCommandProcessor::UpdateCompletedFrame() {
  uint64_t completed_submission = GetCompletedSubmission();
  while (frame_completed_ + 1 < frame_current_) {
    uint64_t frame = frame_completed_ + 1;
    if (closed_frame_submissions_[frame % kMaxFramesInFlight] > completed_submission) {
      break;
    }
    frame_completed_ = frame;
  }
}

void MetalCommandProcessor::EndSubmission(bool is_swap) {
  if (render_target_cache_ && render_target_cache_->has_pending_transfers()) {
    GetCommandBuffer();
    render_target_cache_->FlushPendingTransfers();
  }
  if (command_buffer_) {
    CountRenderPassBreak(is_swap ? "swap" : "submission");
    EndEncoding();
    if (upload_command_buffer_) {
      if (upload_compute_encoder_) {
        [upload_compute_encoder_ endEncoding];
        upload_compute_encoder_ = nil;
      }
      if (upload_blit_encoder_) {
        [upload_blit_encoder_ endEncoding];
        upload_blit_encoder_ = nil;
      }
      [upload_command_buffer_ commit];
      upload_command_buffer_ = nil;
    }
    submission_gpu_written_ranges_.clear();
    [command_buffer_ commit];
    ++stats_.submissions;
    if (REXCVAR_GET(metal_sync_submissions)) {
      [command_buffer_ waitUntilCompleted];
    }
    command_buffer_ = nil;
    ++submission_current_;
  }
  if (is_swap && frame_open_) {
    primitive_processor_->EndFrame();
    closed_frame_submissions_[frame_current_ % kMaxFramesInFlight] = submission_current_ - 1;
    ++frame_current_;
    frame_open_ = false;
    if (transient_page_current_) {
      transient_pages_used_.push_back({transient_page_current_, frame_current_ - 1});
      transient_page_current_ = nil;
      transient_page_current_used_ = kTransientPageSize;
    }
  }
}

void MetalCommandProcessor::AwaitAllSubmissionsCompletion() {
  EndSubmission(false);
  uint64_t await_submission = submission_current_ - 1;
  while (GetCompletedSubmission() < await_submission) {
    std::this_thread::yield();
  }
}

void MetalCommandProcessor::EndEncoding() {
  if (render_encoder_) {
    [render_encoder_ endEncoding];
    render_encoder_ = nil;
    render_encoder_attachments_ = MetalRenderTargetCache::RenderPassAttachments();
  }
  if (compute_encoder_) {
    [compute_encoder_ endEncoding];
    compute_encoder_ = nil;
  }
  if (blit_encoder_) {
    [blit_encoder_ endEncoding];
    blit_encoder_ = nil;
  }
}

id<MTLComputeCommandEncoder> MetalCommandProcessor::GetUploadComputeEncoder() {
  if (upload_compute_encoder_) {
    return upload_compute_encoder_;
  }
  // The upload command buffer is committed with a main one.
  GetCommandBuffer();
  if (!upload_command_buffer_) {
    upload_command_buffer_ = [queue_ commandBuffer];
    upload_command_buffer_.label = @"upload";
  }
  if (upload_blit_encoder_) {
    [upload_blit_encoder_ endEncoding];
    upload_blit_encoder_ = nil;
  }
  upload_compute_encoder_ = [upload_command_buffer_ computeCommandEncoder];
  upload_compute_encoder_.label = @"upload compute";
  ++stats_.texture_loads_reordered;
  return upload_compute_encoder_;
}

id<MTLBlitCommandEncoder> MetalCommandProcessor::GetUploadBlitEncoder() {
  if (upload_blit_encoder_) {
    return upload_blit_encoder_;
  }
  GetCommandBuffer();
  if (!upload_command_buffer_) {
    upload_command_buffer_ = [queue_ commandBuffer];
    upload_command_buffer_.label = @"upload";
  }
  if (upload_compute_encoder_) {
    [upload_compute_encoder_ endEncoding];
    upload_compute_encoder_ = nil;
  }
  upload_blit_encoder_ = [upload_command_buffer_ blitCommandEncoder];
  upload_blit_encoder_.label = @"upload blit";
  return upload_blit_encoder_;
}

void MetalCommandProcessor::MarkGpuWrittenInSubmission(uint32_t start, uint32_t length) {
  if (length) {
    submission_gpu_written_ranges_.emplace_back(start, start + length);
  }
}

bool MetalCommandProcessor::IsGpuWrittenInSubmission(uint32_t start, uint32_t length) const {
  if (!length) {
    return false;
  }
  uint32_t end = start + length;
  for (const auto& range : submission_gpu_written_ranges_) {
    if (start < range.second && end > range.first) {
      return true;
    }
  }
  return false;
}

void MetalCommandProcessor::CountRenderPassBreak(const char* reason) {
  if (render_encoder_ && !render_encoder_is_utility_ && REXCVAR_GET(metal_log_stats)) {
    ++stats_.render_pass_breaks[reason];
  }
}

id<MTLComputeCommandEncoder> MetalCommandProcessor::GetComputeEncoder(const char* reason) {
  if (compute_encoder_) {
    return compute_encoder_;
  }
  CountRenderPassBreak(reason);
  EndEncoding();
  compute_encoder_ = [GetCommandBuffer() computeCommandEncoder];
  compute_encoder_.label = @"compute";
  return compute_encoder_;
}

id<MTLBlitCommandEncoder> MetalCommandProcessor::GetBlitEncoder(const char* reason) {
  if (blit_encoder_) {
    return blit_encoder_;
  }
  CountRenderPassBreak(reason);
  EndEncoding();
  blit_encoder_ = [GetCommandBuffer() blitCommandEncoder];
  blit_encoder_.label = @"blit";
  return blit_encoder_;
}

id<MTLRenderCommandEncoder> MetalCommandProcessor::BeginUtilityRenderPass(
    MTLRenderPassDescriptor* descriptor, const char* reason) {
  CountRenderPassBreak(reason);
  if (REXCVAR_GET(metal_log_stats)) {
    ++stats_.utility_passes[reason];
  }
  EndEncoding();
  render_encoder_ = [GetCommandBuffer() renderCommandEncoderWithDescriptor:descriptor];
  render_encoder_is_utility_ = true;
  return render_encoder_;
}

id<MTLRenderCommandEncoder> MetalCommandProcessor::GetRenderEncoderForCurrentRenderTargets() {
  const MetalRenderTargetCache::RenderPassAttachments& attachments =
      render_target_cache_->last_update_attachments();
  if (render_encoder_ && !render_encoder_is_utility_ && render_encoder_attachments_ == attachments) {
    return render_encoder_;
  }
  CountRenderPassBreak("render target change");
  EndEncoding();
  ++stats_.guest_render_passes;
  MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
  for (uint32_t i = 0; i < xenos::kMaxColorRenderTargets; ++i) {
    if (!attachments.color[i]) {
      continue;
    }
    pass.colorAttachments[i].texture = attachments.color[i];
    pass.colorAttachments[i].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[i].storeAction = MTLStoreActionStore;
  }
  if (attachments.depth) {
    pass.depthAttachment.texture = attachments.depth;
    pass.depthAttachment.loadAction = MTLLoadActionLoad;
    pass.depthAttachment.storeAction = MTLStoreActionStore;
    pass.stencilAttachment.texture = attachments.depth;
    pass.stencilAttachment.loadAction = MTLLoadActionLoad;
    pass.stencilAttachment.storeAction = MTLStoreActionStore;
  }
  if (attachments.empty()) {
    // Rasterization without attachments (for instance, memexport only).
    pass.renderTargetWidth = std::max(render_target_cache_->last_update_width(), uint32_t(1));
    pass.renderTargetHeight = std::max(render_target_cache_->last_update_height(), uint32_t(1));
    pass.defaultRasterSampleCount = render_target_cache_->last_update_formats().sample_count;
  }
  render_encoder_ = [GetCommandBuffer() renderCommandEncoderWithDescriptor:pass];
  if (REXCVAR_GET(metal_log_stats)) {
    // Identify passes in GPU traces by their attachments.
    id<MTLTexture> first = attachments.color[0] ? attachments.color[0] : attachments.depth;
    render_encoder_.label = first ? [NSString stringWithFormat:@"guest %lux%lu x%lu c%d%d%d%d d%d",
                                                               (unsigned long)first.width,
                                                               (unsigned long)first.height,
                                                               (unsigned long)first.sampleCount,
                                                               attachments.color[0] != nil,
                                                               attachments.color[1] != nil,
                                                               attachments.color[2] != nil,
                                                               attachments.color[3] != nil,
                                                               attachments.depth != nil]
                                  : @"guest none";
  } else {
    render_encoder_.label = @"guest";
  }
  render_encoder_is_utility_ = false;
  render_encoder_attachments_ = attachments;
  encoder_pipeline_ = nil;
  encoder_depth_stencil_state_ = nil;
  encoder_shared_memory_bound_ = nil;
  return render_encoder_;
}

bool MetalCommandProcessor::RequestTransientBuffer(size_t size, size_t alignment,
                                                   __strong id<MTLBuffer>& buffer_out,
                                                   NSUInteger& offset_out, void*& mapping_out) {
  if (size > kTransientPageSize) {
    // Rare - a dedicated buffer, released with the frame.
    id<MTLBuffer> buffer = [device_ newBufferWithLength:size
                                                options:MTLResourceStorageModeShared |
                                                        MTLResourceHazardTrackingModeUntracked];
    if (!buffer) {
      return false;
    }
    transient_pages_used_.push_back({buffer, frame_current_});
    buffer_out = buffer;
    offset_out = 0;
    mapping_out = buffer.contents;
    return true;
  }
  size_t offset = (transient_page_current_used_ + alignment - 1) & ~(alignment - 1);
  if (!transient_page_current_ || offset + size > kTransientPageSize) {
    if (transient_page_current_) {
      transient_pages_used_.push_back({transient_page_current_, frame_current_});
    }
    if (!transient_pages_free_.empty()) {
      transient_page_current_ = transient_pages_free_.front().buffer;
      transient_pages_free_.pop_front();
    } else {
      transient_page_current_ =
          [device_ newBufferWithLength:kTransientPageSize
                               options:MTLResourceStorageModeShared |
                                       MTLResourceHazardTrackingModeUntracked];
      if (!transient_page_current_) {
        return false;
      }
    }
    offset = 0;
  }
  transient_page_current_used_ = offset + size;
  buffer_out = transient_page_current_;
  offset_out = NSUInteger(offset);
  mapping_out = static_cast<uint8_t*>(transient_page_current_.contents) + offset;
  return true;
}

id<MTLFunction> MetalCommandProcessor::CompileUtilitySpirv(const uint32_t* spirv,
                                                           size_t spirv_word_count,
                                                           const char* debug_name) {
  std::string msl, error;
  MslConversionOptions options;
  options.utility = true;
  if (!ConvertSpirvToMsl(spirv, spirv_word_count, options, msl, error)) {
    REXGPU_ERROR("Failed to convert the {} shader to MSL: {}", debug_name, error);
    return nil;
  }
  id<MTLLibrary> library = GetMetalProvider().CompileLibrary(
      [NSString stringWithUTF8String:msl.c_str()], debug_name);
  return library ? [library newFunctionWithName:@"main0"] : nil;
}

Shader* MetalCommandProcessor::LoadShader(xenos::ShaderType shader_type, uint32_t guest_address,
                                          const uint32_t* host_address, uint32_t dword_count) {
  (void)guest_address;
  return pipeline_cache_->LoadShader(shader_type, host_address, dword_count);
}

// Draws.

bool MetalCommandProcessor::IssueDraw(xenos::PrimitiveType prim_type, uint32_t index_count,
                                      IndexBufferInfo* index_buffer_info,
                                      bool major_mode_explicit) {
  ++stats_.draws_requested;
  ++frame_rate_draw_count_;
  {
    static int32_t last_requested = 0, remaining = 0;
    int32_t requested = REXCVAR_GET(metal_log_draws);
    if (requested != last_requested) {
      last_requested = requested;
      remaining = requested;
    }
    if (remaining > 0) {
      --remaining;
      const RegisterFile& regs = *register_file_;
      REXGPU_INFO(
          "[cp] draw initiator={:08X} index_base={:08X} index_size={:08X} "
          "RB_SURFACE_INFO={:08X} RB_COLOR_INFO={:08X} RB_DEPTH_INFO={:08X} "
          "RB_DEPTHCONTROL={:08X} RB_BLENDCONTROL0={:08X} RB_COLORCONTROL={:08X} "
          "PA_SU_SC_MODE_CNTL={:08X}",
          regs.values[XE_GPU_REG_VGT_DRAW_INITIATOR], regs.values[XE_GPU_REG_VGT_DMA_BASE],
          regs.values[XE_GPU_REG_VGT_DMA_SIZE], regs.values[XE_GPU_REG_RB_SURFACE_INFO],
          regs.values[XE_GPU_REG_RB_COLOR_INFO], regs.values[XE_GPU_REG_RB_DEPTH_INFO],
          regs.values[XE_GPU_REG_RB_DEPTHCONTROL], regs.values[XE_GPU_REG_RB_BLENDCONTROL0],
          regs.values[XE_GPU_REG_RB_COLORCONTROL], regs.values[XE_GPU_REG_PA_SU_SC_MODE_CNTL]);
    }
  }
  bool result = IssueDrawImpl();
  if (!result) {
    ++stats_.draws_failed;
  }
  return result;
}

bool MetalCommandProcessor::IssueDrawImpl() {
  const RegisterFile& regs = *register_file_;
  auto draw_fail = [](const char* reason) {
    static std::unordered_map<std::string, bool> logged;
    if (!logged[reason]) {
      logged[reason] = true;
      REXGPU_ERROR("Metal draw failed: {}", reason);
    }
    return false;
  };

  xenos::EdramMode edram_mode = regs.Get<reg::RB_MODECONTROL>().edram_mode;
  if (edram_mode == xenos::EdramMode::kCopy) {
    return IssueCopy();
  }

  bool surface_pitch_is_zero = regs.Get<reg::RB_SURFACE_INFO>().surface_pitch == 0;

  auto vertex_shader = static_cast<MetalShader*>(active_vertex_shader());
  if (!vertex_shader) {
    return draw_fail("no vertex shader");
  }
  pipeline_cache_->AnalyzeShaderUcode(*vertex_shader);
  bool memexport_used_vertex = vertex_shader->memexport_eM_written() != 0;

  bool primitive_polygonal = draw_util::IsPrimitivePolygonal(regs);
  bool is_rasterization_done = draw_util::IsRasterizationPotentiallyDone(regs, primitive_polygonal);
  if (surface_pitch_is_zero && is_rasterization_done) {
    return true;
  }
  MetalShader* pixel_shader = nullptr;
  if (is_rasterization_done) {
    if (edram_mode == xenos::EdramMode::kColorDepth) {
      pixel_shader = static_cast<MetalShader*>(active_pixel_shader());
      if (pixel_shader) {
        pipeline_cache_->AnalyzeShaderUcode(*pixel_shader);
        if (!draw_util::IsPixelShaderNeededWithRasterization(*pixel_shader, regs)) {
          pixel_shader = nullptr;
        }
      }
    }
  } else if (!memexport_used_vertex) {
    return true;
  }
  bool memexport_used_pixel = pixel_shader && pixel_shader->memexport_eM_written() != 0;

  reg::RB_DEPTHCONTROL normalized_depth_control = draw_util::GetNormalizedDepthControl(regs);

  uint32_t ps_param_gen_pos = UINT32_MAX;
  uint32_t interpolator_mask =
      pixel_shader ? (vertex_shader->writes_interpolators() &
                      pixel_shader->GetInterpolatorInputMask(regs.Get<reg::SQ_PROGRAM_CNTL>(),
                                                             regs.Get<reg::SQ_CONTEXT_MISC>(),
                                                             ps_param_gen_pos))
                   : 0;

  GetCommandBuffer();
  PrimitiveProcessor::ProcessingResult primitive_processing_result;
  if (!primitive_processor_->Process(primitive_processing_result)) {
    return draw_fail("primitive processing");
  }
  if (!primitive_processing_result.host_draw_vertex_count) {
    return true;
  }
  Shader::HostVertexShaderType host_vertex_shader_type =
      primitive_processing_result.host_vertex_shader_type;
  uint32_t tessellation_grid_factor = 0;
  if (Shader::IsHostVertexShaderTypeDomain(host_vertex_shader_type)) {
    tessellation_grid_factor =
        MetalPipelineCache::GetTessellationGridFactor(regs, host_vertex_shader_type);
    if (!tessellation_grid_factor) {
      static bool logged = false;
      if (!logged) {
        logged = true;
        REXGPU_WARN("Metal: Skipping a tessellated draw not drawable as a triangle grid");
      }
      return true;
    }
  } else if (host_vertex_shader_type != Shader::HostVertexShaderType::kVertex &&
             host_vertex_shader_type != Shader::HostVertexShaderType::kPointListAsTriangleStrip &&
             host_vertex_shader_type !=
                 Shader::HostVertexShaderType::kRectangleListAsTriangleStrip) {
    return draw_fail("host vertex shader type");
  }

  SpirvShaderTranslator::Modification vertex_shader_modification =
      pipeline_cache_->GetCurrentVertexShaderModification(*vertex_shader, host_vertex_shader_type,
                                                          interpolator_mask,
                                                          ps_param_gen_pos != UINT32_MAX);
  SpirvShaderTranslator::Modification pixel_shader_modification =
      pixel_shader ? pipeline_cache_->GetCurrentPixelShaderModification(
                         *pixel_shader, interpolator_mask, ps_param_gen_pos,
                         normalized_depth_control)
                   : SpirvShaderTranslator::Modification(0);
  auto vertex_shader_translation = static_cast<MetalShader::MetalTranslation*>(
      vertex_shader->GetOrCreateTranslation(vertex_shader_modification.value));
  auto pixel_shader_translation =
      pixel_shader ? static_cast<MetalShader::MetalTranslation*>(
                         pixel_shader->GetOrCreateTranslation(pixel_shader_modification.value))
                   : nullptr;
  if (!pipeline_cache_->EnsureShadersTranslated(vertex_shader_translation,
                                                pixel_shader_translation)) {
    return draw_fail("shader translation");
  }

  uint32_t normalized_color_mask =
      pixel_shader ? draw_util::GetNormalizedColorMask(regs, pixel_shader->writes_color_targets())
                   : 0;
  uint32_t used_texture_mask =
      vertex_shader->GetUsedTextureMaskAfterTranslation() |
      (pixel_shader ? pixel_shader->GetUsedTextureMaskAfterTranslation() : 0);
  texture_cache_->RequestTextures(used_texture_mask);

  if (!render_target_cache_->Update(is_rasterization_done, normalized_depth_control,
                                    normalized_color_mask, *vertex_shader)) {
    return draw_fail("render target update");
  }

  id<MTLRenderPipelineState> pipeline = pipeline_cache_->GetPipeline(
      vertex_shader_translation, pixel_shader_translation, primitive_processing_result,
      normalized_color_mask, render_target_cache_->last_update_formats());
  if (!pipeline) {
    return draw_fail("pipeline");
  }

  draw_util::ViewportInfo viewport_info;
  draw_util::GetHostViewportInfo(regs, 1, 1, false, 16384, 16384, true, normalized_depth_control,
                                 false, true, pixel_shader && pixel_shader->writes_depth(),
                                 viewport_info);

  UpdateSystemConstantValues(primitive_polygonal, primitive_processing_result, viewport_info,
                             used_texture_mask, normalized_depth_control, normalized_color_mask);

  id<MTLRenderCommandEncoder> encoder = GetRenderEncoderForCurrentRenderTargets();
  if (!encoder) {
    return draw_fail("encoder");
  }
  if (render_target_cache_->has_pending_transfers()) {
    render_target_cache_->PerformPendingTransfersInRenderPass(encoder);
    encoder_pipeline_ = nil;
    encoder_depth_stencil_state_ = nil;
  }
  if (encoder_pipeline_ != pipeline) {
    [encoder setRenderPipelineState:pipeline];
    encoder_pipeline_ = pipeline;
  }
  bool depth_bound = render_target_cache_->last_update_attachments().depth != nil;
  // Without rasterization in the guest (memexport only), the host still
  // rasterizes - nothing must be written.
  id<MTLDepthStencilState> depth_stencil_state = pipeline_cache_->GetDepthStencilState(
      normalized_depth_control, depth_bound && is_rasterization_done, primitive_polygonal);
  if (encoder_depth_stencil_state_ != depth_stencil_state) {
    [encoder setDepthStencilState:depth_stencil_state];
    encoder_depth_stencil_state_ = depth_stencil_state;
  }
  if (!UpdateDynamicState(encoder, viewport_info, primitive_polygonal, normalized_depth_control,
                          !is_rasterization_done)) {
    // Nothing to draw (empty scissor or everything culled).
    return true;
  }
  if (!UpdateConstantBuffers(vertex_shader, pixel_shader)) {
    return draw_fail("constants");
  }
  BindDrawResources(encoder, vertex_shader, pixel_shader);
  ++stats_.draws_encoded;
  if (REXCVAR_GET(metal_log_stats)) {
    uint64_t vertex_count = primitive_processing_result.host_draw_vertex_count;
    if (tessellation_grid_factor) {
      vertex_count = (primitive_processing_result.tessellation_mode ==
                              xenos::TessellationMode::kAdaptive
                          ? vertex_count / 4
                          : vertex_count) *
                     tessellation_grid_factor * tessellation_grid_factor * 6;
    }
    stats_.vertices += vertex_count;
    const char* type_name = tessellation_grid_factor ? "tessellated"
                            : host_vertex_shader_type ==
                                    Shader::HostVertexShaderType::kPointListAsTriangleStrip
                                ? "points"
                            : host_vertex_shader_type ==
                                    Shader::HostVertexShaderType::kRectangleListAsTriangleStrip
                                ? "rectangles"
                                : "vertex";
    stats_.vertices_by_type[type_name] += vertex_count;
  }

  // Draw.
  MTLPrimitiveType primitive_type;
  if (tessellation_grid_factor) {
    primitive_type = MTLPrimitiveTypeTriangle;
  } else {
    switch (primitive_processing_result.host_primitive_type) {
      case xenos::PrimitiveType::kPointList:
        primitive_type = MTLPrimitiveTypePoint;
        break;
      case xenos::PrimitiveType::kLineList:
        primitive_type = MTLPrimitiveTypeLine;
        break;
      case xenos::PrimitiveType::kLineStrip:
        primitive_type = MTLPrimitiveTypeLineStrip;
        break;
      case xenos::PrimitiveType::kTriangleList:
      case xenos::PrimitiveType::kRectangleList:
        primitive_type = MTLPrimitiveTypeTriangle;
        break;
      case xenos::PrimitiveType::kTriangleStrip:
        primitive_type = MTLPrimitiveTypeTriangleStrip;
        break;
      default:
        return draw_fail("primitive type");
    }
  }
  if (tessellation_grid_factor) {
    uint32_t patch_count =
        primitive_processing_result.tessellation_mode == xenos::TessellationMode::kAdaptive
            ? primitive_processing_result.host_draw_vertex_count / 4
            : primitive_processing_result.host_draw_vertex_count;
    id<MTLBuffer> grid_indices = GetTessellationGridIndices(tessellation_grid_factor, patch_count);
    if (!grid_indices) {
      return draw_fail("tessellation grid indices");
    }
    [encoder drawIndexedPrimitives:primitive_type
                        indexCount:NSUInteger(patch_count) * tessellation_grid_factor *
                                   tessellation_grid_factor * 6
                         indexType:MTLIndexTypeUInt32
                       indexBuffer:grid_indices
                 indexBufferOffset:0];
  } else if (primitive_processing_result.index_buffer_type ==
             PrimitiveProcessor::ProcessedIndexBufferType::kNone) {
    [encoder drawPrimitives:primitive_type
                vertexStart:0
                vertexCount:primitive_processing_result.host_draw_vertex_count];
  } else {
    id<MTLBuffer> index_buffer = nil;
    NSUInteger index_buffer_offset = 0;
    switch (primitive_processing_result.index_buffer_type) {
      case PrimitiveProcessor::ProcessedIndexBufferType::kGuestDMA:
        index_buffer = shared_memory_->buffer();
        index_buffer_offset = primitive_processing_result.guest_index_base;
        break;
      case PrimitiveProcessor::ProcessedIndexBufferType::kHostConverted: {
        auto pair = primitive_processor_->GetConvertedIndexBuffer(
            primitive_processing_result.host_index_buffer_handle);
        index_buffer = pair.first;
        index_buffer_offset = pair.second;
      } break;
      case PrimitiveProcessor::ProcessedIndexBufferType::kHostBuiltinForAuto:
      case PrimitiveProcessor::ProcessedIndexBufferType::kHostBuiltinForDMA: {
        auto pair = primitive_processor_->GetBuiltinIndexBuffer(
            primitive_processing_result.host_index_buffer_handle);
        index_buffer = pair.first;
        index_buffer_offset = pair.second;
      } break;
      default:
        return draw_fail("index buffer type");
    }
    [encoder drawIndexedPrimitives:primitive_type
                        indexCount:primitive_processing_result.host_draw_vertex_count
                         indexType:primitive_processing_result.host_index_format ==
                                           xenos::IndexFormat::kInt16
                                       ? MTLIndexTypeUInt16
                                       : MTLIndexTypeUInt32
                       indexBuffer:index_buffer
                 indexBufferOffset:index_buffer_offset];
  }

  if (memexport_used_vertex || memexport_used_pixel) {
    // The data is written directly to guest memory - only invalidate textures
    // there.
    memexport_ranges_.clear();
    if (memexport_used_vertex) {
      draw_util::AddMemExportRanges(regs, *vertex_shader, memexport_ranges_);
    }
    if (memexport_used_pixel) {
      draw_util::AddMemExportRanges(regs, *pixel_shader, memexport_ranges_);
    }
    for (const draw_util::MemExportRange& range : memexport_ranges_) {
      shared_memory_->RangeWrittenByGpu(range.base_address_dwords << 2, range.size_bytes);
      MarkGpuWrittenInSubmission(range.base_address_dwords << 2, range.size_bytes);
    }
    // Hazard tracking doesn't order draws within one render encoder - make the
    // exported data visible to the following draws (as vertices, for example).
    [encoder memoryBarrierWithScope:MTLBarrierScopeBuffers
                        afterStages:memexport_used_pixel ? MTLRenderStageFragment
                                                         : MTLRenderStageVertex
                       beforeStages:MTLRenderStageVertex | MTLRenderStageFragment];
    ++stats_.memexport_draws;
  }
  return true;
}

bool MetalCommandProcessor::UpdateDynamicState(id<MTLRenderCommandEncoder> encoder,
                                               const draw_util::ViewportInfo& viewport_info,
                                               bool primitive_polygonal,
                                               reg::RB_DEPTHCONTROL normalized_depth_control,
                                               bool memexport_only) {
  const RegisterFile& regs = *register_file_;

  MTLViewport viewport;
  if (viewport_info.xy_extent[0] && viewport_info.xy_extent[1]) {
    viewport.originX = double(viewport_info.xy_offset[0]);
    viewport.originY = double(viewport_info.xy_offset[1]);
    viewport.width = double(viewport_info.xy_extent[0]);
    viewport.height = double(viewport_info.xy_extent[1]);
  } else {
    viewport.originX = 0.0;
    viewport.originY = 0.0;
    viewport.width = 1.0;
    viewport.height = 1.0;
  }
  viewport.znear = viewport_info.z_min;
  viewport.zfar = viewport_info.z_max;
  [encoder setViewport:viewport];

  // Scissor, clamped to the render target bounds (Metal requires that).
  draw_util::Scissor scissor;
  draw_util::GetScissor(regs, scissor);
  uint32_t rt_width = std::max(render_target_cache_->last_update_width(), uint32_t(1));
  uint32_t rt_height = std::max(render_target_cache_->last_update_height(), uint32_t(1));
  uint32_t scissor_left = std::min(scissor.offset[0], rt_width);
  uint32_t scissor_top = std::min(scissor.offset[1], rt_height);
  uint32_t scissor_right = std::min(scissor.offset[0] + scissor.extent[0], rt_width);
  uint32_t scissor_bottom = std::min(scissor.offset[1] + scissor.extent[1], rt_height);
  if (scissor_right <= scissor_left || scissor_bottom <= scissor_top) {
    if (!memexport_only) {
      return false;
    }
    // The vertex shader must still run for memexport, and nothing is written
    // to the render targets.
    scissor_left = 0;
    scissor_top = 0;
    scissor_right = 1;
    scissor_bottom = 1;
  }
  MTLScissorRect scissor_rect = {scissor_left, scissor_top, scissor_right - scissor_left,
                                 scissor_bottom - scissor_top};
  [encoder setScissorRect:scissor_rect];

  auto pa_su_sc_mode_cntl = regs.Get<reg::PA_SU_SC_MODE_CNTL>();
  if (primitive_polygonal && memexport_only) {
    [encoder setCullMode:MTLCullModeNone];
    [encoder setTriangleFillMode:MTLTriangleFillModeFill];
  } else if (primitive_polygonal) {
    if (pa_su_sc_mode_cntl.cull_front && pa_su_sc_mode_cntl.cull_back) {
      return false;
    }
    [encoder setCullMode:pa_su_sc_mode_cntl.cull_front  ? MTLCullModeFront
                         : pa_su_sc_mode_cntl.cull_back ? MTLCullModeBack
                                                        : MTLCullModeNone];
    [encoder setFrontFacingWinding:pa_su_sc_mode_cntl.face ? MTLWindingClockwise
                                                           : MTLWindingCounterClockwise];
    bool wireframe = false;
    if (pa_su_sc_mode_cntl.poly_mode == xenos::PolygonModeEnable::kDualMode) {
      xenos::PolygonType polygon_type = xenos::PolygonType::kTriangles;
      if (!pa_su_sc_mode_cntl.cull_front) {
        polygon_type = std::min(polygon_type, pa_su_sc_mode_cntl.polymode_front_ptype);
      }
      if (!pa_su_sc_mode_cntl.cull_back) {
        polygon_type = std::min(polygon_type, pa_su_sc_mode_cntl.polymode_back_ptype);
      }
      wireframe = polygon_type != xenos::PolygonType::kTriangles;
    }
    [encoder setTriangleFillMode:wireframe ? MTLTriangleFillModeLines : MTLTriangleFillModeFill];
  } else {
    [encoder setCullMode:MTLCullModeNone];
  }
  [encoder setDepthClipMode:regs.Get<reg::PA_CL_CLIP_CNTL>().clip_disable ? MTLDepthClipModeClamp
                                                                           : MTLDepthClipModeClip];

  float depth_bias_constant_factor, depth_bias_slope_factor;
  draw_util::GetPreferredFacePolygonOffset(regs, primitive_polygonal, depth_bias_slope_factor,
                                           depth_bias_constant_factor);
  // Depth is stored as 32-bit float on the host.
  depth_bias_constant_factor *= draw_util::kD3D10PolygonOffsetFactorFloat24;
  depth_bias_slope_factor *= xenos::kPolygonOffsetScaleSubpixelUnit;
  [encoder setDepthBias:depth_bias_constant_factor slopeScale:depth_bias_slope_factor clamp:0.0f];

  [encoder setBlendColorRed:regs.Get<float>(XE_GPU_REG_RB_BLEND_RED)
                      green:regs.Get<float>(XE_GPU_REG_RB_BLEND_GREEN)
                       blue:regs.Get<float>(XE_GPU_REG_RB_BLEND_BLUE)
                      alpha:regs.Get<float>(XE_GPU_REG_RB_BLEND_ALPHA)];

  if (normalized_depth_control.stencil_enable) {
    auto stencil_ref_mask_front = regs.Get<reg::RB_STENCILREFMASK>();
    if (primitive_polygonal && normalized_depth_control.backface_enable) {
      auto stencil_ref_mask_back =
          regs.Get<reg::RB_STENCILREFMASK>(XE_GPU_REG_RB_STENCILREFMASK_BF);
      [encoder setStencilFrontReferenceValue:stencil_ref_mask_front.stencilref
                          backReferenceValue:stencil_ref_mask_back.stencilref];
    } else {
      [encoder setStencilReferenceValue:stencil_ref_mask_front.stencilref];
    }
  }
  return true;
}

bool MetalCommandProcessor::UpdateConstantBuffers(const MetalShader* vertex_shader,
                                                  const MetalShader* pixel_shader) {
  const RegisterFile& regs = *register_file_;

  const Shader::ConstantRegisterMap& float_constant_map_vertex =
      vertex_shader->constant_register_map();
  uint32_t float_constant_count_vertex = float_constant_map_vertex.float_count;
  for (uint32_t i = 0; i < 4; ++i) {
    if (current_float_constant_map_vertex_[i] != float_constant_map_vertex.float_bitmap[i]) {
      current_float_constant_map_vertex_[i] = float_constant_map_vertex.float_bitmap[i];
      current_constant_buffers_up_to_date_ &=
          ~(UINT32_C(1) << SpirvShaderTranslator::kConstantBufferFloatVertex);
    }
  }
  uint32_t float_constant_count_pixel = 0;
  if (pixel_shader) {
    const Shader::ConstantRegisterMap& float_constant_map_pixel =
        pixel_shader->constant_register_map();
    float_constant_count_pixel = float_constant_map_pixel.float_count;
    for (uint32_t i = 0; i < 4; ++i) {
      if (current_float_constant_map_pixel_[i] != float_constant_map_pixel.float_bitmap[i]) {
        current_float_constant_map_pixel_[i] = float_constant_map_pixel.float_bitmap[i];
        current_constant_buffers_up_to_date_ &=
            ~(UINT32_C(1) << SpirvShaderTranslator::kConstantBufferFloatPixel);
      }
    }
  } else {
    std::memset(current_float_constant_map_pixel_, 0, sizeof(current_float_constant_map_pixel_));
  }

  auto upload = [this](uint32_t constant_buffer, size_t size) -> uint8_t* {
    ConstantBufferBinding& binding = current_constant_buffers_[constant_buffer];
    void* mapping;
    if (!RequestTransientBuffer(size, 256, binding.buffer, binding.offset, mapping)) {
      return nullptr;
    }
    current_constant_buffers_up_to_date_ |= UINT32_C(1) << constant_buffer;
    constant_buffers_to_bind_ |= UINT32_C(1) << constant_buffer;
    return static_cast<uint8_t*>(mapping);
  };

  if (!(current_constant_buffers_up_to_date_ &
        (UINT32_C(1) << SpirvShaderTranslator::kConstantBufferSystem))) {
    uint8_t* mapping = upload(SpirvShaderTranslator::kConstantBufferSystem,
                              sizeof(SpirvShaderTranslator::SystemConstants));
    if (!mapping) {
      return false;
    }
    std::memcpy(mapping, &system_constants_, sizeof(SpirvShaderTranslator::SystemConstants));
  }
  for (uint32_t stage = 0; stage < 2; ++stage) {
    uint32_t constant_buffer = stage ? SpirvShaderTranslator::kConstantBufferFloatPixel
                                     : SpirvShaderTranslator::kConstantBufferFloatVertex;
    if (current_constant_buffers_up_to_date_ & (UINT32_C(1) << constant_buffer)) {
      continue;
    }
    uint32_t count = stage ? float_constant_count_pixel : float_constant_count_vertex;
    uint8_t* mapping = upload(constant_buffer, sizeof(float) * 4 * std::max(count, uint32_t(1)));
    if (!mapping) {
      return false;
    }
    const uint64_t* map =
        stage ? current_float_constant_map_pixel_ : current_float_constant_map_vertex_;
    uint32_t register_base =
        stage ? XE_GPU_REG_SHADER_CONSTANT_256_X : XE_GPU_REG_SHADER_CONSTANT_000_X;
    for (uint32_t i = 0; i < 4; ++i) {
      uint64_t float_constant_map_entry = map[i];
      uint32_t float_constant_index;
      while (rex::bit_scan_forward(float_constant_map_entry, &float_constant_index)) {
        float_constant_map_entry &= ~(1ull << float_constant_index);
        std::memcpy(mapping, &regs[register_base + (i << 8) + (float_constant_index << 2)],
                    sizeof(float) * 4);
        mapping += sizeof(float) * 4;
      }
    }
  }
  if (!(current_constant_buffers_up_to_date_ &
        (UINT32_C(1) << SpirvShaderTranslator::kConstantBufferBoolLoop))) {
    constexpr size_t kBoolLoopConstantsSize = sizeof(uint32_t) * (8 + 32);
    uint8_t* mapping =
        upload(SpirvShaderTranslator::kConstantBufferBoolLoop, kBoolLoopConstantsSize);
    if (!mapping) {
      return false;
    }
    std::memcpy(mapping, &regs[XE_GPU_REG_SHADER_CONSTANT_BOOL_000_031], kBoolLoopConstantsSize);
  }
  if (!(current_constant_buffers_up_to_date_ &
        (UINT32_C(1) << SpirvShaderTranslator::kConstantBufferFetch))) {
    constexpr size_t kFetchConstantsSize = sizeof(uint32_t) * 6 * 32;
    uint8_t* mapping = upload(SpirvShaderTranslator::kConstantBufferFetch, kFetchConstantsSize);
    if (!mapping) {
      return false;
    }
    std::memcpy(mapping, &regs[XE_GPU_REG_SHADER_CONSTANT_FETCH_00_0], kFetchConstantsSize);
  }
  return true;
}

void MetalCommandProcessor::BindDrawResources(id<MTLRenderCommandEncoder> encoder,
                                              const MetalShader* vertex_shader,
                                              const MetalShader* pixel_shader) {
  // Shared memory (read-write for memexport) and constant buffers.
  if (encoder_shared_memory_bound_ != encoder) {
    [encoder setVertexBuffer:shared_memory_->buffer() offset:0 atIndex:kMslBufferSharedMemory];
    [encoder setFragmentBuffer:shared_memory_->buffer() offset:0 atIndex:kMslBufferSharedMemory];
    encoder_shared_memory_bound_ = encoder;
    constant_buffers_to_bind_ = (UINT32_C(1) << SpirvShaderTranslator::kConstantBufferCount) - 1;
    for (auto& stage_textures : encoder_textures_) {
      stage_textures.fill(nullptr);
    }
    for (auto& stage_samplers : encoder_samplers_) {
      stage_samplers.fill(nullptr);
    }
  }
  uint32_t to_bind = constant_buffers_to_bind_;
  uint32_t constant_buffer;
  while (rex::bit_scan_forward(to_bind, &constant_buffer)) {
    to_bind &= ~(UINT32_C(1) << constant_buffer);
    const ConstantBufferBinding& binding = current_constant_buffers_[constant_buffer];
    if (!binding.buffer) {
      continue;
    }
    [encoder setVertexBuffer:binding.buffer
                      offset:binding.offset
                     atIndex:kMslBufferConstantsFirst + constant_buffer];
    [encoder setFragmentBuffer:binding.buffer
                        offset:binding.offset
                       atIndex:kMslBufferConstantsFirst + constant_buffer];
  }
  constant_buffers_to_bind_ = 0;

  // Textures and samplers.
  for (uint32_t stage = 0; stage < 2; ++stage) {
    const MetalShader* shader = stage ? pixel_shader : vertex_shader;
    if (!shader) {
      continue;
    }
    const std::vector<MetalShader::TextureBinding>& textures =
        shader->GetTextureBindingsAfterTranslation();
    for (size_t i = 0; i < textures.size(); ++i) {
      const MetalShader::TextureBinding& binding = textures[i];
      id<MTLTexture> texture = texture_cache_->GetActiveTextureOrNull(
          binding.fetch_constant, binding.dimension, bool(binding.is_signed));
      if (i < kMaxBoundTextures) {
        const void*& bound = encoder_textures_[stage][i];
        if (bound == (__bridge const void*)texture) {
          continue;
        }
        bound = (__bridge const void*)texture;
      }
      if (stage) {
        [encoder setFragmentTexture:texture atIndex:i];
      } else {
        [encoder setVertexTexture:texture atIndex:i];
      }
    }
    const std::vector<MetalShader::SamplerBinding>& samplers =
        shader->GetSamplerBindingsAfterTranslation();
    for (size_t i = 0; i < samplers.size() && i < 16; ++i) {
      id<MTLSamplerState> sampler =
          texture_cache_->GetSampler(texture_cache_->GetSamplerParameters(samplers[i]));
      const void*& bound_sampler = encoder_samplers_[stage][i];
      if (bound_sampler == (__bridge const void*)sampler) {
        continue;
      }
      bound_sampler = (__bridge const void*)sampler;
      if (stage) {
        [encoder setFragmentSamplerState:sampler atIndex:i];
      } else {
        [encoder setVertexSamplerState:sampler atIndex:i];
      }
    }
  }
}

// Copies and swaps.

bool MetalCommandProcessor::IssueCopy() {
  GetCommandBuffer();
  uint32_t written_address, written_length;
  bool result = render_target_cache_->Resolve(*memory_, *shared_memory_, *texture_cache_,
                                              written_address, written_length);
  ++stats_.resolves;
  if (written_length) {
    ++stats_.resolves_written;
  }
  return result;
}

void MetalCommandProcessor::IssueSwap(uint32_t frontbuffer_ptr, uint32_t frontbuffer_width,
                                      uint32_t frontbuffer_height) {
  ++stats_.swaps;
  if (REXCVAR_GET(metal_log_frame_rate)) {
    static auto rate_start = std::chrono::steady_clock::now();
    static uint32_t rate_swaps = 0;
    static uint64_t rate_draws_start = 0;
    ++rate_swaps;
    auto now = std::chrono::steady_clock::now();
    double seconds = std::chrono::duration<double>(now - rate_start).count();
    if (seconds >= 5.0) {
      REXGPU_INFO("Frame rate: {:.2f} fps, {} draws per frame", rate_swaps / seconds,
                  (frame_rate_draw_count_ - rate_draws_start) / rate_swaps);
      rate_start = now;
      rate_swaps = 0;
      rate_draws_start = frame_rate_draw_count_;
    }
  }
  if (REXCVAR_GET(metal_log_stats)) {
    auto now = std::chrono::steady_clock::now();
    if (now - stats_.last_log >= std::chrono::seconds(5)) {
      REXGPU_INFO(
          "Metal stats: {} swaps, {} draws requested, {} encoded, {} failed, {} resolves "
          "({} written), {} memexport draws, {} submissions, {} deferred memory writes, {} "
          "transfers in total",
          stats_.swaps, stats_.draws_requested, stats_.draws_encoded, stats_.draws_failed,
          stats_.resolves, stats_.resolves_written, stats_.memexport_draws, stats_.submissions,
          stats_.deferred_memory_writes,
          render_target_cache_->transfer_count());
      std::string breaks;
      for (const auto& reason : stats_.render_pass_breaks) {
        breaks += fmt::format(" {}: {:.1f},", reason.first,
                              double(reason.second) / std::max(stats_.swaps, uint64_t(1)));
      }
      breaks += fmt::format(" vertices: {:.0f}k (", double(stats_.vertices) / 1000.0 /
                                                      std::max(stats_.swaps, uint64_t(1)));
      for (const auto& type : stats_.vertices_by_type) {
        breaks += fmt::format("{} {:.0f}k ", type.first,
                              double(type.second) / 1000.0 / std::max(stats_.swaps, uint64_t(1)));
      }
      breaks += ")";
      breaks += " utility passes:";
      for (const auto& reason : stats_.utility_passes) {
        breaks += fmt::format(" {}: {:.1f},", reason.first,
                              double(reason.second) / std::max(stats_.swaps, uint64_t(1)));
      }
      REXGPU_INFO("Metal memory: {} MB allocated by the device, {} transient pages used, {} "
                  "free, {} deferred memory writes queued",
                  [device_ currentAllocatedSize] >> 20, transient_pages_used_.size(),
                  transient_pages_free_.size(), deferred_memory_writes_.size());
      REXGPU_INFO("Metal per frame: {:.1f} guest render passes, {:.1f} reordered texture loads, "
                  "ends:{}",
                  double(stats_.guest_render_passes) / std::max(stats_.swaps, uint64_t(1)),
                  double(stats_.texture_loads_reordered) / std::max(stats_.swaps, uint64_t(1)),
                  breaks);
      Stats empty;
      empty.last_log = now;
      stats_ = empty;
    }
  }
  ui::Presenter* presenter = graphics_system_->presenter();
  if (!presenter || !frontbuffer_width || !frontbuffer_height) {
    EndSubmission(true);
    return;
  }

  // The front buffer is described by fetch constant 0 by the swap packet.
  const RegisterFile& regs = *register_file_;
  xenos::xe_gpu_texture_fetch_t fetch = regs.GetTextureFetch(0);
  struct SwapConstants {
    uint32_t base;
    uint32_t pitch;
    uint32_t tiled;
    uint32_t endian;
    uint32_t format;
    uint32_t width;
    uint32_t height;
    uint32_t swizzle;
  } constants;
  constants.base = fetch.base_address << 12;
  constants.pitch = fetch.pitch << 5;
  constants.tiled = fetch.tiled;
  constants.endian = uint32_t(fetch.endianness);
  switch (fetch.format) {
    case xenos::TextureFormat::k_2_10_10_10:
    case xenos::TextureFormat::k_2_10_10_10_AS_16_16_16_16:
      constants.format = 1;
      break;
    default:
      constants.format = 0;
      break;
  }
  constants.width = frontbuffer_width;
  constants.height = frontbuffer_height;
  constants.swizzle = fetch.swizzle;
  (void)frontbuffer_ptr;

  system::X_VIDEO_MODE video_mode;
  kernel::xboxkrnl::VdQueryVideoMode(&video_mode);
  uint32_t display_width = std::max(uint32_t(1), uint32_t(video_mode.display_width));
  uint32_t display_height = std::max(uint32_t(1), uint32_t(video_mode.display_height));

  presenter->RefreshGuestOutput(
      frontbuffer_width, frontbuffer_height, display_width, display_height,
      [&](ui::Presenter::GuestOutputRefreshContext& context) -> bool {
        auto& metal_context =
            static_cast<ui::metal::MetalPresenter::MetalGuestOutputRefreshContext&>(context);
        context.SetIs8bpc(constants.format == 0);
        id<MTLComputeCommandEncoder> encoder = GetComputeEncoder();
        [encoder setComputePipelineState:swap_pipeline_];
        [encoder setBuffer:shared_memory_->buffer() offset:0 atIndex:0];
        [encoder setBytes:&constants length:sizeof(constants) atIndex:1];
        [encoder setTexture:metal_context.texture() atIndex:0];
        [encoder dispatchThreadgroups:MTLSizeMake((frontbuffer_width + 7) / 8,
                                                  (frontbuffer_height + 7) / 8, 1)
                threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        // Committed before the presenter's command buffer reads the image.
        EndSubmission(true);
        return true;
      });
  if (frame_open_ || command_buffer_) {
    EndSubmission(true);
  }
}

void MetalCommandProcessor::UpdateSystemConstantValues(
    bool primitive_polygonal,
    const PrimitiveProcessor::ProcessingResult& primitive_processing_result,
    const draw_util::ViewportInfo& viewport_info, uint32_t used_texture_mask,
    reg::RB_DEPTHCONTROL normalized_depth_control, uint32_t normalized_color_mask) {
  constexpr bool shader_32bit_index_dma = false;
  constexpr uint32_t compute_memexport_vertex_count = 0;
#if XE_GPU_FINE_GRAINED_DRAW_SCOPES
  SCOPE_profile_cpu_f("gpu");
#endif  // XE_GPU_FINE_GRAINED_DRAW_SCOPES

  const RegisterFile& regs = *register_file_;
  auto pa_cl_clip_cntl = regs.Get<reg::PA_CL_CLIP_CNTL>();
  auto pa_cl_vte_cntl = regs.Get<reg::PA_CL_VTE_CNTL>();
  auto pa_su_sc_mode_cntl = regs.Get<reg::PA_SU_SC_MODE_CNTL>();
  auto rb_alpha_ref = regs.Get<float>(XE_GPU_REG_RB_ALPHA_REF);
  auto rb_colorcontrol = regs.Get<reg::RB_COLORCONTROL>();
  auto rb_depth_info = regs.Get<reg::RB_DEPTH_INFO>();
  auto rb_stencilrefmask = regs.Get<reg::RB_STENCILREFMASK>();
  auto rb_stencilrefmask_bf = regs.Get<reg::RB_STENCILREFMASK>(XE_GPU_REG_RB_STENCILREFMASK_BF);
  auto rb_surface_info = regs.Get<reg::RB_SURFACE_INFO>();
  auto vgt_dma_size = regs.Get<reg::VGT_DMA_SIZE>();
  auto vgt_draw_initiator = regs.Get<reg::VGT_DRAW_INITIATOR>();
  auto vgt_indx_offset = regs.Get<int32_t>(XE_GPU_REG_VGT_INDX_OFFSET);
  auto vgt_max_vtx_indx = regs.Get<uint32_t>(XE_GPU_REG_VGT_MAX_VTX_INDX);
  auto vgt_min_vtx_indx = regs.Get<uint32_t>(XE_GPU_REG_VGT_MIN_VTX_INDX);

  bool edram_fragment_shader_interlock =
      render_target_cache_->GetPath() == RenderTargetCache::Path::kPixelShaderInterlock;
  uint32_t draw_resolution_scale_x = texture_cache_->draw_resolution_scale_x();
  uint32_t draw_resolution_scale_y = texture_cache_->draw_resolution_scale_y();

  // Get the color info register values for each render target. Also, for FSI,
  // exclude components that don't exist in the format from the write mask.
  // Don't exclude fully overlapping render targets, however - two render
  // targets with the same base address are used in the lighting pass of
  // 4D5307E6, for example, with the needed one picked with dynamic control
  // flow.
  reg::RB_COLOR_INFO color_infos[xenos::kMaxColorRenderTargets];
  float rt_clamp[4][4];
  // Two UINT32_MAX if no components actually existing in the RT are written.
  uint32_t rt_keep_masks[4][2];
  for (uint32_t i = 0; i < xenos::kMaxColorRenderTargets; ++i) {
    auto color_info = regs.Get<reg::RB_COLOR_INFO>(reg::RB_COLOR_INFO::rt_register_indices[i]);
    color_infos[i] = color_info;
    if (edram_fragment_shader_interlock) {
      RenderTargetCache::GetPSIColorFormatInfo(
          color_info.color_format, (normalized_color_mask >> (i * 4)) & 0b1111, rt_clamp[i][0],
          rt_clamp[i][1], rt_clamp[i][2], rt_clamp[i][3], rt_keep_masks[i][0], rt_keep_masks[i][1]);
    }
  }

  // Disable depth and stencil if it aliases a color render target (for
  // instance, during the XBLA logo in 58410954, though depth writing is already
  // disabled there).
  bool depth_stencil_enabled =
      normalized_depth_control.stencil_enable || normalized_depth_control.z_enable;
  if (edram_fragment_shader_interlock && depth_stencil_enabled) {
    for (uint32_t i = 0; i < 4; ++i) {
      if (rb_depth_info.depth_base == color_infos[i].color_base &&
          (rt_keep_masks[i][0] != UINT32_MAX || rt_keep_masks[i][1] != UINT32_MAX)) {
        depth_stencil_enabled = false;
        break;
      }
    }
  }

  bool dirty = false;

  // Flags.
  uint32_t flags = 0;
  // Vertex index shader loading.
  if (shader_32bit_index_dma) {
    flags |= SpirvShaderTranslator::kSysFlag_VertexIndexLoad;
  }
  // Adaptive tessellation drawn as a grid uses the patch index directly - the
  // index buffer contains edge factors.
  bool adaptive_tessellation_grid =
      primitive_processing_result.IsTessellated() &&
      primitive_processing_result.tessellation_mode == xenos::TessellationMode::kAdaptive &&
      MetalPipelineCache::GetTessellationGridFactor(
          regs, primitive_processing_result.host_vertex_shader_type) != 0;
  if (!adaptive_tessellation_grid &&
      (primitive_processing_result.index_buffer_type ==
           PrimitiveProcessor::ProcessedIndexBufferType::kHostBuiltinForDMA ||
       primitive_processing_result.index_buffer_type ==
           PrimitiveProcessor::ProcessedIndexBufferType::kGuestDMA ||
       primitive_processing_result.index_buffer_type ==
           PrimitiveProcessor::ProcessedIndexBufferType::kHostConverted)) {
    flags |= SpirvShaderTranslator::kSysFlag_ComputeOrPrimitiveVertexIndexLoad;
    if (vgt_draw_initiator.index_size == xenos::IndexFormat::kInt32) {
      flags |= SpirvShaderTranslator ::kSysFlag_ComputeOrPrimitiveVertexIndexLoad32Bit;
    }
    // Point and rectangle expansion uses primitive restart only in the host
    // built-in strip index buffer; guest indices are not reset-based there.
    bool compute_or_primitive_vertex_index_reset =
        primitive_processing_result.host_primitive_reset_enabled &&
        primitive_processing_result.host_vertex_shader_type !=
            Shader::HostVertexShaderType::kPointListAsTriangleStrip &&
        primitive_processing_result.host_vertex_shader_type !=
            Shader::HostVertexShaderType::kRectangleListAsTriangleStrip;
    if (compute_or_primitive_vertex_index_reset) {
      flags |= SpirvShaderTranslator::kSysFlag_ComputeOrPrimitiveVertexIndexReset;
    }
  }
  if (primitive_processing_result.host_vertex_shader_type ==
      Shader::HostVertexShaderType::kTriangleDomainPatchIndexed) {
    flags |= SpirvShaderTranslator::kSysFlag_ComputeMemExportPatchIndexInRegister1;
  }
  if (primitive_processing_result.host_vertex_shader_type ==
      Shader::HostVertexShaderType::kTriangleDomainCPIndexed) {
    flags |= SpirvShaderTranslator::kSysFlag_ComputeMemExportTriangleCPIndexed;
  } else if (primitive_processing_result.host_vertex_shader_type ==
             Shader::HostVertexShaderType::kQuadDomainCPIndexed) {
    flags |= SpirvShaderTranslator::kSysFlag_ComputeMemExportQuadCPIndexed;
  }
  if (primitive_processing_result.tessellation_mode == xenos::TessellationMode::kAdaptive &&
      (primitive_processing_result.host_vertex_shader_type ==
           Shader::HostVertexShaderType::kTriangleDomainPatchIndexed ||
       primitive_processing_result.host_vertex_shader_type ==
           Shader::HostVertexShaderType::kQuadDomainPatchIndexed)) {
    flags |= SpirvShaderTranslator::kSysFlag_ComputeMemExportPatchIndexFromInvocation;
  }
  // W0 division control.
  // http://www.x.org/docs/AMD/old/evergreen_3D_registers_v2.pdf
  // 8: VTX_XY_FMT = true: the incoming XY have already been multiplied by 1/W0.
  //               = false: multiply the X, Y coordinates by 1/W0.
  // 9: VTX_Z_FMT = true: the incoming Z has already been multiplied by 1/W0.
  //              = false: multiply the Z coordinate by 1/W0.
  // 10: VTX_W0_FMT = true: the incoming W0 is not 1/W0. Perform the reciprocal
  //                        to get 1/W0.
  if (pa_cl_vte_cntl.vtx_xy_fmt) {
    flags |= SpirvShaderTranslator::kSysFlag_XYDividedByW;
  }
  if (pa_cl_vte_cntl.vtx_z_fmt) {
    flags |= SpirvShaderTranslator::kSysFlag_ZDividedByW;
  }
  if (pa_cl_vte_cntl.vtx_w0_fmt) {
    flags |= SpirvShaderTranslator::kSysFlag_WNotReciprocal;
  }
  // Whether the primitive is polygonal, and gl_FrontFacing matters.
  if (primitive_polygonal) {
    flags |= SpirvShaderTranslator::kSysFlag_PrimitivePolygonal;
  }
  // Primitive type.
  if (draw_util::IsPrimitiveLine(regs)) {
    flags |= SpirvShaderTranslator::kSysFlag_PrimitiveLine;
  }
  // MSAA sample count.
  flags |= uint32_t(rb_surface_info.msaa_samples)
           << SpirvShaderTranslator::kSysFlag_MsaaSamples_Shift;
  // Depth format.
  if (rb_depth_info.depth_format == xenos::DepthRenderTargetFormat::kD24FS8) {
    flags |= SpirvShaderTranslator::kSysFlag_DepthFloat24;
  }
  // Alpha test.
  xenos::CompareFunction alpha_test_function = rb_colorcontrol.alpha_test_enable
                                                   ? rb_colorcontrol.alpha_func
                                                   : xenos::CompareFunction::kAlways;
  flags |= uint32_t(alpha_test_function) << SpirvShaderTranslator::kSysFlag_AlphaPassIfLess_Shift;
  // Gamma writing.
  if (!render_target_cache_->gamma_render_target_as_unorm16()) {
    // Keep parity with D3D12: gamma targets in this path are converted via
    // explicit Xenos PWL gamma logic in shaders rather than via host sRGB
    // attachment conversion semantics.
    for (uint32_t i = 0; i < xenos::kMaxColorRenderTargets; ++i) {
      if (color_infos[i].color_format == xenos::ColorRenderTargetFormat::k_8_8_8_8_GAMMA) {
        flags |= SpirvShaderTranslator::kSysFlag_ConvertColor0ToGamma << i;
      }
    }
  }
  if (edram_fragment_shader_interlock && depth_stencil_enabled) {
    flags |= SpirvShaderTranslator::kSysFlag_FSIDepthStencil;
    if (normalized_depth_control.z_enable) {
      flags |= uint32_t(normalized_depth_control.zfunc)
               << SpirvShaderTranslator::kSysFlag_FSIDepthPassIfLess_Shift;
      if (normalized_depth_control.z_write_enable) {
        flags |= SpirvShaderTranslator::kSysFlag_FSIDepthWrite;
      }
    } else {
      // In case stencil is used without depth testing - always pass, and
      // don't modify the stored depth.
      flags |= SpirvShaderTranslator::kSysFlag_FSIDepthPassIfLess |
               SpirvShaderTranslator::kSysFlag_FSIDepthPassIfEqual |
               SpirvShaderTranslator::kSysFlag_FSIDepthPassIfGreater;
    }
    if (normalized_depth_control.stencil_enable) {
      flags |= SpirvShaderTranslator::kSysFlag_FSIStencilTest;
    }
    // Hint - if not applicable to the shader, will not have effect.
    if (alpha_test_function == xenos::CompareFunction::kAlways &&
        !rb_colorcontrol.alpha_to_mask_enable) {
      flags |= SpirvShaderTranslator::kSysFlag_FSIDepthStencilEarlyWrite;
    }
  }
  dirty |= system_constants_.flags != flags;
  system_constants_.flags = flags;

  // Index buffer address for loading in the shaders.
  if (flags & (SpirvShaderTranslator::kSysFlag_VertexIndexLoad |
               SpirvShaderTranslator::kSysFlag_ComputeOrPrimitiveVertexIndexLoad)) {
    dirty |=
        system_constants_.vertex_index_load_address != primitive_processing_result.guest_index_base;
    system_constants_.vertex_index_load_address = primitive_processing_result.guest_index_base;
  }

  // Primitive reset index for shader-side index loading.
  uint32_t vertex_index_reset =
      (flags & SpirvShaderTranslator::kSysFlag_ComputeOrPrimitiveVertexIndexReset)
          ? regs.Get<reg::VGT_MULTI_PRIM_IB_RESET_INDX>().reset_indx
          : 0;
  dirty |= system_constants_.vertex_index_reset != vertex_index_reset;
  system_constants_.vertex_index_reset = vertex_index_reset;
  dirty |= system_constants_.compute_memexport_vertex_count != compute_memexport_vertex_count;
  system_constants_.compute_memexport_vertex_count = compute_memexport_vertex_count;

  // Index or tessellation edge factor buffer endianness.
  xenos::Endian guest_index_endian = vgt_dma_size.swap_mode;
  if (vgt_draw_initiator.index_size == xenos::IndexFormat::kInt16 &&
      guest_index_endian != xenos::Endian::kNone && guest_index_endian != xenos::Endian::k8in16) {
    guest_index_endian =
        guest_index_endian == xenos::Endian::k8in32 ? xenos::Endian::k8in16 : xenos::Endian::kNone;
  }
  xenos::Endian index_endian =
      (flags & SpirvShaderTranslator::kSysFlag_ComputeOrPrimitiveVertexIndexLoad)
          ? guest_index_endian
          : primitive_processing_result.host_shader_index_endian;
  dirty |= system_constants_.vertex_index_endian != index_endian;
  system_constants_.vertex_index_endian = index_endian;

  dirty |= system_constants_.line_loop_closing_index !=
           primitive_processing_result.line_loop_closing_index;
  system_constants_.line_loop_closing_index = primitive_processing_result.line_loop_closing_index;

  // Vertex index offset.
  dirty |= system_constants_.vertex_base_index != vgt_indx_offset;
  system_constants_.vertex_base_index = vgt_indx_offset;

  // Vertex index range.
  dirty |= system_constants_.vertex_index_min != vgt_min_vtx_indx;
  dirty |= system_constants_.vertex_index_max != vgt_max_vtx_indx;
  system_constants_.vertex_index_min = vgt_min_vtx_indx;
  system_constants_.vertex_index_max = vgt_max_vtx_indx;

  // User clip planes (UCP_ENA_#), when not CLIP_DISABLE.
  // The shader knows only the total count - tightly packing the user clip
  // planes that are actually used.
  if (!pa_cl_clip_cntl.clip_disable) {
    float* user_clip_plane_write_ptr = system_constants_.user_clip_planes[0];
    uint32_t user_clip_planes_remaining = pa_cl_clip_cntl.ucp_ena;
    uint32_t user_clip_plane_index;
    while (rex::bit_scan_forward(user_clip_planes_remaining, &user_clip_plane_index)) {
      user_clip_planes_remaining &= ~(UINT32_C(1) << user_clip_plane_index);
      const void* user_clip_plane_regs =
          &regs[XE_GPU_REG_PA_CL_UCP_0_X + user_clip_plane_index * 4];
      if (std::memcmp(user_clip_plane_write_ptr, user_clip_plane_regs, 4 * sizeof(float))) {
        dirty = true;
        std::memcpy(user_clip_plane_write_ptr, user_clip_plane_regs, 4 * sizeof(float));
      }
      user_clip_plane_write_ptr += 4;
    }
  }

  // Tessellation factor range, plus 1.0 according to
  // https://www.slideshare.net/blackdevilvikas/next-generation-graphics-programming-on-xbox-360.
  float tessellation_factor_min = regs.Get<float>(XE_GPU_REG_VGT_HOS_MIN_TESS_LEVEL) + 1.0f;
  float tessellation_factor_max = regs.Get<float>(XE_GPU_REG_VGT_HOS_MAX_TESS_LEVEL) + 1.0f;
  dirty |= system_constants_.tessellation_factor_range_min != tessellation_factor_min;
  dirty |= system_constants_.tessellation_factor_range_max != tessellation_factor_max;
  system_constants_.tessellation_factor_range_min = tessellation_factor_min;
  system_constants_.tessellation_factor_range_max = tessellation_factor_max;

  // Conversion to host normalized device coordinates.
  for (uint32_t i = 0; i < 3; ++i) {
    dirty |= system_constants_.ndc_scale[i] != viewport_info.ndc_scale[i];
    dirty |= system_constants_.ndc_offset[i] != viewport_info.ndc_offset[i];
    system_constants_.ndc_scale[i] = viewport_info.ndc_scale[i];
    system_constants_.ndc_offset[i] = viewport_info.ndc_offset[i];
  }

  // Point size.
  if (vgt_draw_initiator.prim_type == xenos::PrimitiveType::kPointList) {
    auto pa_su_point_minmax = regs.Get<reg::PA_SU_POINT_MINMAX>();
    auto pa_su_point_size = regs.Get<reg::PA_SU_POINT_SIZE>();
    float point_vertex_diameter_min = float(pa_su_point_minmax.min_size) * (2.0f / 16.0f);
    float point_vertex_diameter_max = float(pa_su_point_minmax.max_size) * (2.0f / 16.0f);
    float point_constant_diameter_x = float(pa_su_point_size.width) * (2.0f / 16.0f);
    float point_constant_diameter_y = float(pa_su_point_size.height) * (2.0f / 16.0f);
    dirty |= system_constants_.point_vertex_diameter_min != point_vertex_diameter_min;
    dirty |= system_constants_.point_vertex_diameter_max != point_vertex_diameter_max;
    dirty |= system_constants_.point_constant_diameter[0] != point_constant_diameter_x;
    dirty |= system_constants_.point_constant_diameter[1] != point_constant_diameter_y;
    system_constants_.point_vertex_diameter_min = point_vertex_diameter_min;
    system_constants_.point_vertex_diameter_max = point_vertex_diameter_max;
    system_constants_.point_constant_diameter[0] = point_constant_diameter_x;
    system_constants_.point_constant_diameter[1] = point_constant_diameter_y;
    // 2 because 1 in the NDC is half of the viewport's axis, 0.5 for diameter
    // to radius conversion to avoid multiplying the per-vertex diameter by an
    // additional constant in the shader.
    float point_screen_diameter_to_ndc_radius_x =
        (/* 0.5f * 2.0f * */ float(draw_resolution_scale_x)) /
        std::max(viewport_info.xy_extent[0], uint32_t(1));
    float point_screen_diameter_to_ndc_radius_y =
        (/* 0.5f * 2.0f * */ float(draw_resolution_scale_y)) /
        std::max(viewport_info.xy_extent[1], uint32_t(1));
    dirty |= system_constants_.point_screen_diameter_to_ndc_radius[0] !=
             point_screen_diameter_to_ndc_radius_x;
    dirty |= system_constants_.point_screen_diameter_to_ndc_radius[1] !=
             point_screen_diameter_to_ndc_radius_y;
    system_constants_.point_screen_diameter_to_ndc_radius[0] =
        point_screen_diameter_to_ndc_radius_x;
    system_constants_.point_screen_diameter_to_ndc_radius[1] =
        point_screen_diameter_to_ndc_radius_y;
  }

  // Texture signedness / gamma.
  uint32_t textures_resolution_scaled = 0;
  {
    uint32_t textures_remaining = used_texture_mask;
    uint32_t texture_index;
    while (rex::bit_scan_forward(textures_remaining, &texture_index)) {
      textures_remaining &= ~(UINT32_C(1) << texture_index);
      uint32_t& texture_signs_uint = system_constants_.texture_swizzled_signs[texture_index >> 2];
      uint32_t texture_signs_shift = 8 * (texture_index & 3);
      uint8_t texture_signs = texture_cache_->GetActiveTextureSwizzledSigns(texture_index);
      uint32_t texture_signs_shifted = uint32_t(texture_signs) << texture_signs_shift;
      uint32_t texture_signs_mask = ((UINT32_C(1) << 8) - 1) << texture_signs_shift;
      dirty |= (texture_signs_uint & texture_signs_mask) != texture_signs_shifted;
      texture_signs_uint = (texture_signs_uint & ~texture_signs_mask) | texture_signs_shifted;
      textures_resolution_scaled |=
          uint32_t(texture_cache_->IsActiveTextureResolutionScaled(texture_index)) << texture_index;
    }
  }
  dirty |= system_constants_.textures_resolution_scaled != textures_resolution_scaled;
  system_constants_.textures_resolution_scaled = textures_resolution_scaled;

  // Texture host swizzle in the shader.
  if (false) {
    uint32_t textures_remaining = used_texture_mask;
    uint32_t texture_index;
    while (rex::bit_scan_forward(textures_remaining, &texture_index)) {
      textures_remaining &= ~(UINT32_C(1) << texture_index);
      uint32_t& texture_swizzles_uint = system_constants_.texture_swizzles[texture_index >> 1];
      uint32_t texture_swizzle_shift = 12 * (texture_index & 1);
      uint32_t texture_swizzle = texture_cache_->GetActiveTextureHostSwizzle(texture_index);
      uint32_t texture_swizzle_shifted = uint32_t(texture_swizzle) << texture_swizzle_shift;
      uint32_t texture_swizzle_mask = ((UINT32_C(1) << 12) - 1) << texture_swizzle_shift;
      dirty |= (texture_swizzles_uint & texture_swizzle_mask) != texture_swizzle_shifted;
      texture_swizzles_uint =
          (texture_swizzles_uint & ~texture_swizzle_mask) | texture_swizzle_shifted;
    }
  }

  // Alpha test.
  dirty |= system_constants_.alpha_test_reference != rb_alpha_ref;
  system_constants_.alpha_test_reference = rb_alpha_ref;
  uint32_t alpha_to_mask =
      rb_colorcontrol.alpha_to_mask_enable ? (rb_colorcontrol.value >> 24) | (UINT32_C(1) << 8) : 0;
  dirty |= system_constants_.alpha_to_mask != alpha_to_mask;
  system_constants_.alpha_to_mask = alpha_to_mask;

  uint32_t edram_tile_dwords_scaled = xenos::kEdramTileWidthSamples *
                                      xenos::kEdramTileHeightSamples *
                                      (draw_resolution_scale_x * draw_resolution_scale_y);

  // EDRAM pitch for FSI render target writing.
  if (edram_fragment_shader_interlock) {
    // Align, then multiply by 32bpp tile size in dwords.
    uint32_t edram_32bpp_tile_pitch_dwords_scaled =
        ((rb_surface_info.surface_pitch *
          (rb_surface_info.msaa_samples >= xenos::MsaaSamples::k4X ? 2 : 1)) +
         (xenos::kEdramTileWidthSamples - 1)) /
        xenos::kEdramTileWidthSamples * edram_tile_dwords_scaled;
    dirty |= system_constants_.edram_32bpp_tile_pitch_dwords_scaled !=
             edram_32bpp_tile_pitch_dwords_scaled;
    system_constants_.edram_32bpp_tile_pitch_dwords_scaled = edram_32bpp_tile_pitch_dwords_scaled;
  }

  // Color exponent bias and FSI render target writing.
  for (uint32_t i = 0; i < xenos::kMaxColorRenderTargets; ++i) {
    reg::RB_COLOR_INFO color_info = color_infos[i];
    // Exponent bias is in bits 20:25 of RB_COLOR_INFO.
    int32_t color_exp_bias = color_info.color_exp_bias;
    if (render_target_cache_->GetPath() == RenderTargetCache::Path::kHostRenderTargets &&
        (color_info.color_format == xenos::ColorRenderTargetFormat::k_16_16 &&
             !render_target_cache_->IsFixedRG16TruncatedToMinus1To1() ||
         color_info.color_format == xenos::ColorRenderTargetFormat::k_16_16_16_16 &&
             !render_target_cache_->IsFixedRGBA16TruncatedToMinus1To1())) {
      // Remap from -32...32 to -1...1 by dividing the output values by 32,
      // losing blending correctness, but getting the full range.
      color_exp_bias -= 5;
    }
    float color_exp_bias_scale;
    *reinterpret_cast<int32_t*>(&color_exp_bias_scale) =
        UINT32_C(0x3F800000) + (color_exp_bias << 23);
    dirty |= system_constants_.color_exp_bias[i] != color_exp_bias_scale;
    system_constants_.color_exp_bias[i] = color_exp_bias_scale;
    if (edram_fragment_shader_interlock) {
      dirty |= system_constants_.edram_rt_keep_mask[i][0] != rt_keep_masks[i][0];
      system_constants_.edram_rt_keep_mask[i][0] = rt_keep_masks[i][0];
      dirty |= system_constants_.edram_rt_keep_mask[i][1] != rt_keep_masks[i][1];
      system_constants_.edram_rt_keep_mask[i][1] = rt_keep_masks[i][1];
      if (rt_keep_masks[i][0] != UINT32_MAX || rt_keep_masks[i][1] != UINT32_MAX) {
        uint32_t rt_base_dwords_scaled = color_info.color_base * edram_tile_dwords_scaled;
        dirty |= system_constants_.edram_rt_base_dwords_scaled[i] != rt_base_dwords_scaled;
        system_constants_.edram_rt_base_dwords_scaled[i] = rt_base_dwords_scaled;
        uint32_t format_flags = RenderTargetCache::AddPSIColorFormatFlags(color_info.color_format);
        dirty |= system_constants_.edram_rt_format_flags[i] != format_flags;
        system_constants_.edram_rt_format_flags[i] = format_flags;
        uint32_t blend_factors_ops =
            regs[reg::RB_BLENDCONTROL::rt_register_indices[i]] & 0x1FFF1FFF;
        dirty |= system_constants_.edram_rt_blend_factors_ops[i] != blend_factors_ops;
        system_constants_.edram_rt_blend_factors_ops[i] = blend_factors_ops;
        // Can't do float comparisons here because NaNs would result in always
        // setting the dirty flag.
        dirty |=
            std::memcmp(system_constants_.edram_rt_clamp[i], rt_clamp[i], 4 * sizeof(float)) != 0;
        std::memcpy(system_constants_.edram_rt_clamp[i], rt_clamp[i], 4 * sizeof(float));
      }
    }
  }

  if (edram_fragment_shader_interlock) {
    uint32_t depth_base_dwords_scaled = rb_depth_info.depth_base * edram_tile_dwords_scaled;
    dirty |= system_constants_.edram_depth_base_dwords_scaled != depth_base_dwords_scaled;
    system_constants_.edram_depth_base_dwords_scaled = depth_base_dwords_scaled;

    // For non-polygons, front polygon offset is used, and it's enabled if
    // POLY_OFFSET_PARA_ENABLED is set, for polygons, separate front and back
    // are used.
    float poly_offset_front_scale = 0.0f, poly_offset_front_offset = 0.0f;
    float poly_offset_back_scale = 0.0f, poly_offset_back_offset = 0.0f;
    if (primitive_polygonal) {
      if (pa_su_sc_mode_cntl.poly_offset_front_enable) {
        poly_offset_front_scale = regs.Get<float>(XE_GPU_REG_PA_SU_POLY_OFFSET_FRONT_SCALE);
        poly_offset_front_offset = regs.Get<float>(XE_GPU_REG_PA_SU_POLY_OFFSET_FRONT_OFFSET);
      }
      if (pa_su_sc_mode_cntl.poly_offset_back_enable) {
        poly_offset_back_scale = regs.Get<float>(XE_GPU_REG_PA_SU_POLY_OFFSET_BACK_SCALE);
        poly_offset_back_offset = regs.Get<float>(XE_GPU_REG_PA_SU_POLY_OFFSET_BACK_OFFSET);
      }
    } else {
      if (pa_su_sc_mode_cntl.poly_offset_para_enable) {
        poly_offset_front_scale = regs.Get<float>(XE_GPU_REG_PA_SU_POLY_OFFSET_FRONT_SCALE);
        poly_offset_front_offset = regs.Get<float>(XE_GPU_REG_PA_SU_POLY_OFFSET_FRONT_OFFSET);
        poly_offset_back_scale = poly_offset_front_scale;
        poly_offset_back_offset = poly_offset_front_offset;
      }
    }
    // With non-square resolution scaling, make sure the worst-case impact is
    // reverted (slope only along the scaled axis), thus max. More bias is
    // better than less bias, because less bias means Z fighting with the
    // background is more likely.
    float poly_offset_scale_factor = xenos::kPolygonOffsetScaleSubpixelUnit *
                                     std::max(draw_resolution_scale_x, draw_resolution_scale_y);
    poly_offset_front_scale *= poly_offset_scale_factor;
    poly_offset_back_scale *= poly_offset_scale_factor;
    dirty |= system_constants_.edram_poly_offset_front_scale != poly_offset_front_scale;
    system_constants_.edram_poly_offset_front_scale = poly_offset_front_scale;
    dirty |= system_constants_.edram_poly_offset_front_offset != poly_offset_front_offset;
    system_constants_.edram_poly_offset_front_offset = poly_offset_front_offset;
    dirty |= system_constants_.edram_poly_offset_back_scale != poly_offset_back_scale;
    system_constants_.edram_poly_offset_back_scale = poly_offset_back_scale;
    dirty |= system_constants_.edram_poly_offset_back_offset != poly_offset_back_offset;
    system_constants_.edram_poly_offset_back_offset = poly_offset_back_offset;

    if (depth_stencil_enabled && normalized_depth_control.stencil_enable) {
      uint32_t stencil_front_reference_masks = rb_stencilrefmask.value & 0xFFFFFF;
      dirty |=
          system_constants_.edram_stencil_front_reference_masks != stencil_front_reference_masks;
      system_constants_.edram_stencil_front_reference_masks = stencil_front_reference_masks;
      uint32_t stencil_func_ops = (normalized_depth_control.value >> 8) & ((1 << 12) - 1);
      dirty |= system_constants_.edram_stencil_front_func_ops != stencil_func_ops;
      system_constants_.edram_stencil_front_func_ops = stencil_func_ops;

      if (primitive_polygonal && normalized_depth_control.backface_enable) {
        uint32_t stencil_back_reference_masks = rb_stencilrefmask_bf.value & 0xFFFFFF;
        dirty |=
            system_constants_.edram_stencil_back_reference_masks != stencil_back_reference_masks;
        system_constants_.edram_stencil_back_reference_masks = stencil_back_reference_masks;
        uint32_t stencil_func_ops_bf = (normalized_depth_control.value >> 20) & ((1 << 12) - 1);
        dirty |= system_constants_.edram_stencil_back_func_ops != stencil_func_ops_bf;
        system_constants_.edram_stencil_back_func_ops = stencil_func_ops_bf;
      } else {
        dirty |= std::memcmp(system_constants_.edram_stencil_back,
                             system_constants_.edram_stencil_front, 2 * sizeof(uint32_t)) != 0;
        std::memcpy(system_constants_.edram_stencil_back, system_constants_.edram_stencil_front,
                    2 * sizeof(uint32_t));
      }
    }

    dirty |= system_constants_.edram_blend_constant[0] != regs.Get<float>(XE_GPU_REG_RB_BLEND_RED);
    system_constants_.edram_blend_constant[0] = regs.Get<float>(XE_GPU_REG_RB_BLEND_RED);
    dirty |=
        system_constants_.edram_blend_constant[1] != regs.Get<float>(XE_GPU_REG_RB_BLEND_GREEN);
    system_constants_.edram_blend_constant[1] = regs.Get<float>(XE_GPU_REG_RB_BLEND_GREEN);
    dirty |= system_constants_.edram_blend_constant[2] != regs.Get<float>(XE_GPU_REG_RB_BLEND_BLUE);
    system_constants_.edram_blend_constant[2] = regs.Get<float>(XE_GPU_REG_RB_BLEND_BLUE);
    dirty |=
        system_constants_.edram_blend_constant[3] != regs.Get<float>(XE_GPU_REG_RB_BLEND_ALPHA);
    system_constants_.edram_blend_constant[3] = regs.Get<float>(XE_GPU_REG_RB_BLEND_ALPHA);
  }

  if (dirty) {
    current_constant_buffers_up_to_date_ &=
        ~(UINT32_C(1) << SpirvShaderTranslator::kConstantBufferSystem);
  }
}

}  // namespace rex::graphics::metal
