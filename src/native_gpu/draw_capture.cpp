// Draw capture: hooks the game's D3D draw functions and records each draw with
// the device state it was issued with, while the original code still writes the
// command buffer. First milestone of the native Metal renderer: it validates the
// device layout against what the GPU emulator receives.

#include <atomic>
#include <cstdint>

#include <rex/cvar.h>
#include <rex/logging.h>

#include "fable_2_pch.h"
#include "native_gpu/d3d_device.h"

REXCVAR_DEFINE_INT32(native_gpu_log_draws, 0, "NativeGPU",
                     "Log the next N draws as seen at the D3D level (device state and the draw "
                     "packet written)")
    .lifecycle(rex::cvar::Lifecycle::kHotReload);

namespace fable2::native_gpu {
namespace {

std::atomic<int32_t> draws_to_log{0};
int32_t last_requested = 0;

// Finds the last DRAW_INDX / DRAW_INDX_2 packet in [begin, end) of the command
// buffer (guest addresses of dwords) and returns its header address, or 0.
uint32_t FindDrawPacket(const uint8_t* base, uint32_t begin, uint32_t end) {
  uint32_t found = 0;
  uint32_t address = begin;
  while (address < end) {
    uint32_t header = LoadGuest32(base, address);
    uint32_t type = header >> 30;
    uint32_t count;
    if (type == 3) {
      uint32_t opcode = (header >> 8) & 0x7F;
      count = ((header >> 16) & 0x3FFF) + 1;
      if (opcode == 0x22 || opcode == 0x36) {
        found = address;
      }
    } else if (type == 0) {
      count = ((header >> 16) & 0x3FFF) + 1;
    } else if (type == 2) {
      count = 0;
    } else {
      count = 2;  // type 1: two registers
    }
    address += 4 * (1 + count);
  }
  return found;
}

void OnDraw(const char* function, const uint8_t* base, uint32_t device_address,
            uint32_t write_before) {
  int32_t requested = REXCVAR_GET(native_gpu_log_draws);
  if (requested != last_requested) {
    last_requested = requested;
    draws_to_log.store(requested);
  }
  if (draws_to_log.load(std::memory_order_relaxed) <= 0) {
    return;
  }
  draws_to_log.fetch_sub(1);
  D3DDevice device(base, device_address);
  // The write pointer points at the last written dword (writes are stwu).
  uint32_t write_after = device.Load(D3DDevice::kCommandBufferWrite);
  uint32_t packet = 0;
  if (write_after > write_before) {
    packet = FindDrawPacket(base, write_before + 4, write_after + 4);
  }
  uint32_t initiator = 0, index_base = 0, index_size = 0;
  if (packet) {
    uint32_t opcode = (LoadGuest32(base, packet) >> 8) & 0x7F;
    // DRAW_INDX: viz query, VGT_DRAW_INITIATOR, index base, index size.
    initiator = LoadGuest32(base, packet + (opcode == 0x22 ? 8 : 4));
    if (opcode == 0x22) {
      index_base = LoadGuest32(base, packet + 12);
      index_size = LoadGuest32(base, packet + 16);
    }
  }
  auto reg = [&](uint32_t index) {
    uint32_t value = 0;
    device.GetRegister(index, value);
    return value;
  };
  REXSYS_INFO(
      "[native-gpu] draw {} initiator={:08X} index_base={:08X} index_size={:08X} "
      "RB_SURFACE_INFO={:08X} RB_COLOR_INFO={:08X} RB_DEPTH_INFO={:08X} RB_DEPTHCONTROL={:08X} "
      "RB_BLENDCONTROL0={:08X} RB_COLORCONTROL={:08X} PA_SU_SC_MODE_CNTL={:08X} "
      "RT0={:08X} DS={:08X} VS={:08X} PS={:08X}",
      function, initiator, index_base, index_size, reg(0x2000), reg(0x2001), reg(0x2002),
      reg(0x2200), reg(0x2201), reg(0x2202), reg(0x2205), device.render_target(0),
      device.depth_stencil(), device.vertex_shader(), device.pixel_shader());
}

}  // namespace
}  // namespace fable2::native_gpu

#define FABLE2_NATIVE_GPU_DRAW_HOOK(name)                                              \
  extern "C" void __imp__##name(PPCContext& __restrict ctx, uint8_t* base);            \
  extern "C" void name(PPCContext& __restrict ctx, uint8_t* base) {                    \
    uint32_t device = ctx.r3.u32;                                                      \
    uint32_t write_before =                                                            \
        fable2::native_gpu::LoadGuest32(base, device + fable2::native_gpu::D3DDevice::kCommandBufferWrite); \
    __imp__##name(ctx, base);                                                          \
    fable2::native_gpu::OnDraw(#name, base, device, write_before);                     \
  }

// The game's draw functions (D3D draw inlines with the dirty state flush).
FABLE2_NATIVE_GPU_DRAW_HOOK(sub_8221E0F0)
FABLE2_NATIVE_GPU_DRAW_HOOK(sub_8221C9C8)
FABLE2_NATIVE_GPU_DRAW_HOOK(sub_82207C30)
FABLE2_NATIVE_GPU_DRAW_HOOK(ProcessAndProcessAndProcess576_82217EE8)
FABLE2_NATIVE_GPU_DRAW_HOOK(ProcessAndProcessAndProcess841_8221C518)
FABLE2_NATIVE_GPU_DRAW_HOOK(ProcessAndProcessAndProcess876_822060A0)
