#pragma once
/**
 * @file        graphics/metal/primitive_processor.h
 * @brief       Primitive and index processing for the Metal backend
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */

// Objective-C++ only.

#include <utility>
#include <vector>

#import <Metal/Metal.h>

#include <rex/graphics/primitive_processor.h>

namespace rex::graphics::metal {

class MetalPrimitiveProcessor final : public PrimitiveProcessor {
 public:
  MetalPrimitiveProcessor(const RegisterFile& register_file, memory::Memory& memory,
                          SharedMemory& shared_memory, id<MTLDevice> device)
      : PrimitiveProcessor(register_file, memory, shared_memory), device_(device) {}
  ~MetalPrimitiveProcessor();

  bool Initialize();
  void Shutdown(bool from_destructor = false);
  void EndFrame();

  std::pair<id<MTLBuffer>, NSUInteger> GetBuiltinIndexBuffer(size_t handle) const {
    return std::make_pair(builtin_index_buffer_,
                          NSUInteger(GetBuiltinIndexBufferOffsetBytes(handle)));
  }
  std::pair<id<MTLBuffer>, NSUInteger> GetConvertedIndexBuffer(size_t handle) const {
    return std::make_pair(frame_index_buffers_[handle], converted_offsets_[handle]);
  }

 protected:
  bool InitializeBuiltinIndexBuffer(size_t size_bytes,
                                    std::function<void(void*)> fill_callback) override;
  void* RequestHostConvertedIndexBufferForCurrentFrame(xenos::IndexFormat format,
                                                       uint32_t index_count, bool coalign_for_simd,
                                                       uint32_t coalignment_original_address,
                                                       size_t& backend_handle_out) override;

 private:
  id<MTLDevice> device_;
  id<MTLBuffer> builtin_index_buffer_ = nil;
  // Command buffers retain the buffers they use, so the references can be
  // dropped at the end of the frame.
  std::vector<id<MTLBuffer>> frame_index_buffers_;
  // Offsets of the indices in frame_index_buffers_ (SIMD coalignment).
  std::vector<NSUInteger> converted_offsets_;
};

}  // namespace rex::graphics::metal
