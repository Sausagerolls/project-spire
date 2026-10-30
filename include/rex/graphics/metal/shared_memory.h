#pragma once
/**
 * @file        graphics/metal/shared_memory.h
 * @brief       Guest physical memory as a zero-copy Metal buffer
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */

// Objective-C++ only.

#import <Metal/Metal.h>

#include <rex/graphics/shared_memory.h>

namespace rex::graphics::metal {

// On Apple Silicon the CPU and the GPU share memory, so the guest physical
// memory itself is the GPU buffer (newBufferWithBytesNoCopy): nothing is
// uploaded, and GPU writes (resolves, memexport) land in guest memory
// directly. The base class page tracking is still used for watches (texture
// invalidation on CPU writes).
class MetalSharedMemory : public SharedMemory {
 public:
  MetalSharedMemory(memory::Memory& memory, id<MTLDevice> device)
      : SharedMemory(memory), device_(device) {}
  ~MetalSharedMemory() override;

  bool Initialize();
  void Shutdown(bool from_destructor = false);

  id<MTLBuffer> buffer() const { return buffer_; }

 protected:
  bool UploadRanges(const std::vector<std::pair<uint32_t, uint32_t>>& upload_page_ranges) override;

 private:
  id<MTLDevice> device_;
  id<MTLBuffer> buffer_ = nil;
};

}  // namespace rex::graphics::metal
