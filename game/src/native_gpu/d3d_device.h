#pragma once
// View of the game's Direct3D device (the statically linked Xbox 360 D3D
// runtime) in guest memory. The device mirrors the Xenos registers and flushes
// the dirty ones into the command buffer before each draw. Offsets were
// reversed from the draw path; see docs/native-renderer-plan.md.

#include <cstdint>

namespace fable2::native_gpu {

// Guest virtual address to host pointer, matching REX_RAW_ADDR.
inline const uint8_t* GuestPointer(const uint8_t* base, uint32_t address) {
  return base + address + (address >= 0xE0000000u ? 0x1000u : 0u);
}
inline uint32_t LoadGuest32(const uint8_t* base, uint32_t address) {
  return __builtin_bswap32(*reinterpret_cast<const uint32_t*>(GuestPointer(base, address)));
}

class D3DDevice {
 public:
  // Command buffer.
  static constexpr uint32_t kCommandBufferWrite = 48;
  static constexpr uint32_t kCommandBufferLimit = 56;
  // Constants.
  static constexpr uint32_t kFetchConstants = 1152;     // 0x4800, 32 x 6 dwords
  static constexpr uint32_t kVertexConstants = 1920;    // 0x4000, 256 x float4
  static constexpr uint32_t kPixelConstants = 6016;     // 0x4400, 256 x float4
  // Surfaces and shaders (guest pointers to D3D objects).
  static constexpr uint32_t kRenderTargets = 12440;     // [4]
  static constexpr uint32_t kDepthStencil = 12456;
  static constexpr uint32_t kPixelShader = 12692;
  static constexpr uint32_t kVertexShader = 12696;
  static constexpr uint32_t kIndexBuffer = 12436;

  D3DDevice(const uint8_t* base, uint32_t address) : base_(base), address_(address) {}

  uint32_t address() const { return address_; }
  uint32_t Load(uint32_t offset) const { return LoadGuest32(base_, address_ + offset); }

  // The shadow of a Xenos register, or false if the device doesn't mirror it.
  bool GetRegister(uint32_t index, uint32_t& value_out) const {
    struct Range {
      uint32_t first, count, offset;
    };
    static constexpr Range kRanges[] = {
        {0x2000, 19, 10368}, {0x2100, 21, 10444}, {0x2180, 5, 10528},
        {0x2200, 12, 10548}, {0x2280, 21, 10596}, {0x2300, 38, 10680},
        {0x2380, 16, 10832}, {0x4900, 64, 10112},
    };
    for (const Range& range : kRanges) {
      if (index >= range.first && index < range.first + range.count) {
        value_out = Load(range.offset + (index - range.first) * 4);
        return true;
      }
    }
    return false;
  }

  uint32_t render_target(uint32_t index) const { return Load(kRenderTargets + index * 4); }
  uint32_t depth_stencil() const { return Load(kDepthStencil); }
  uint32_t vertex_shader() const { return Load(kVertexShader); }
  uint32_t pixel_shader() const { return Load(kPixelShader); }

 private:
  const uint8_t* base_;
  uint32_t address_;
};

}  // namespace fable2::native_gpu
