/**
 * @file        graphics/metal/shared_memory.mm
 * @brief       Guest physical memory as a zero-copy Metal buffer
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */

#include <rex/graphics/metal/shared_memory.h>

#include <rex/logging.h>
#include <rex/memory.h>
#include <rex/system/xmemory.h>

namespace rex::graphics::metal {

MetalSharedMemory::~MetalSharedMemory() {
  Shutdown(true);
}

bool MetalSharedMemory::Initialize() {
  InitializeCommon();
  uint8_t* physical_membase = memory().TranslatePhysical(0);
  // The guest physical memory mapping is host-page aligned, and its size is a
  // multiple of the host page size, as newBufferWithBytesNoCopy requires.
  size_t host_page_size = rex::memory::page_size();
  if ((reinterpret_cast<uintptr_t>(physical_membase) & (host_page_size - 1)) ||
      (kBufferSize & (host_page_size - 1))) {
    REXGPU_ERROR("MetalSharedMemory: The guest physical memory is not host-page aligned");
    return false;
  }
  buffer_ = [device_ newBufferWithBytesNoCopy:physical_membase
                                       length:kBufferSize
                                      options:MTLResourceStorageModeShared |
                                              MTLResourceHazardTrackingModeUntracked
                                  deallocator:nil];
  if (!buffer_) {
    REXGPU_ERROR("MetalSharedMemory: Failed to wrap the guest physical memory in a Metal buffer");
    return false;
  }
  buffer_.label = @"guest physical memory";
  return true;
}

void MetalSharedMemory::Shutdown(bool from_destructor) {
  buffer_ = nil;
  if (!from_destructor) {
    ShutdownCommon();
  }
}

bool MetalSharedMemory::UploadRanges(
    const std::vector<std::pair<uint32_t, uint32_t>>& upload_page_ranges) {
  // The GPU reads the guest memory directly - only mark the pages as valid
  // (which also starts watching them for CPU writes).
  uint32_t page_size_log2 = this->page_size_log2();
  for (const std::pair<uint32_t, uint32_t>& range : upload_page_ranges) {
    MakeRangeValid(range.first << page_size_log2, range.second << page_size_log2, false);
  }
  return true;
}

}  // namespace rex::graphics::metal
