/**
 * @file        graphics/metal/primitive_processor.mm
 * @brief       Primitive and index processing for the Metal backend
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */

#include <rex/graphics/metal/primitive_processor.h>

#include <rex/assert.h>
#include <rex/logging.h>

namespace rex::graphics::metal {

MetalPrimitiveProcessor::~MetalPrimitiveProcessor() {
  Shutdown(true);
}

bool MetalPrimitiveProcessor::Initialize() {
  // Metal has no geometry shaders: triangle fans, line loops and quad lists
  // are converted, point sprites and rectangles are expanded in the vertex
  // shader.
  if (!InitializeCommon(true, false, false, false, false, false)) {
    Shutdown();
    return false;
  }
  return true;
}

void MetalPrimitiveProcessor::Shutdown(bool from_destructor) {
  frame_index_buffers_.clear();
  converted_offsets_.clear();
  builtin_index_buffer_ = nil;
  if (!from_destructor) {
    ShutdownCommon();
  }
}

void MetalPrimitiveProcessor::EndFrame() {
  ClearPerFrameCache();
  frame_index_buffers_.clear();
  converted_offsets_.clear();
}

bool MetalPrimitiveProcessor::InitializeBuiltinIndexBuffer(
    size_t size_bytes, std::function<void(void*)> fill_callback) {
  assert_not_zero(size_bytes);
  builtin_index_buffer_ = [device_ newBufferWithLength:size_bytes
                                               options:MTLResourceStorageModeShared |
                                                       MTLResourceHazardTrackingModeUntracked];
  if (!builtin_index_buffer_) {
    REXGPU_ERROR("Metal primitive processor: Failed to create the built-in index buffer ({} bytes)",
                 size_bytes);
    return false;
  }
  builtin_index_buffer_.label = @"built-in indices";
  fill_callback(builtin_index_buffer_.contents);
  return true;
}

void* MetalPrimitiveProcessor::RequestHostConvertedIndexBufferForCurrentFrame(
    xenos::IndexFormat format, uint32_t index_count, bool coalign_for_simd,
    uint32_t coalignment_original_address, size_t& backend_handle_out) {
  size_t index_size = format == xenos::IndexFormat::kInt16 ? sizeof(uint16_t) : sizeof(uint32_t);
  size_t size = index_size * index_count + (coalign_for_simd ? XE_GPU_PRIMITIVE_PROCESSOR_SIMD_SIZE
                                                             : 0);
  id<MTLBuffer> buffer = [device_ newBufferWithLength:std::max(size, size_t(4))
                                              options:MTLResourceStorageModeShared |
                                                      MTLResourceHazardTrackingModeUntracked];
  if (!buffer) {
    REXGPU_ERROR("Metal primitive processor: Failed to create a converted index buffer");
    return nullptr;
  }
  uint8_t* mapping = static_cast<uint8_t*>(buffer.contents);
  if (coalign_for_simd) {
    // The offset is applied when binding (GetConvertedIndexBuffer).
    ptrdiff_t coalignment_offset = GetSimdCoalignmentOffset(mapping, coalignment_original_address);
    mapping += coalignment_offset;
    converted_offsets_.push_back(NSUInteger(coalignment_offset));
  } else {
    converted_offsets_.push_back(0);
  }
  backend_handle_out = frame_index_buffers_.size();
  frame_index_buffers_.push_back(buffer);
  return mapping;
}

}  // namespace rex::graphics::metal
