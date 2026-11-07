// Draw capture: hooks the game's D3D draw functions and records each draw with
// the device state it was issued with, while the original code still writes the
// command buffer. First milestone of the native Metal renderer: it validates the
// device layout against what the GPU emulator receives.

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_set>

#include <rex/cvar.h>
#include <rex/logging.h>

#include "fable_2_pch.h"
#include "native_gpu/d3d_device.h"

// D3D command buffer make-space (kicks the buffer to the GPU).
extern "C" void FastHelper_821E8D20(PPCContext& ctx, uint8_t* base);

REXCVAR_DEFINE_BOOL(native_gpu_merge_tiles, true, "NativeGPU",
                    "Draw predicated tiling lists as one tile (needs the Metal backend's native "
                    "surfaces, which have no EDRAM size limit)")
    .lifecycle(rex::cvar::Lifecycle::kInitOnly);
REXCVAR_DEFINE_BOOL(native_gpu_report_surfaces, true, "NativeGPU",
                    "Report the D3D surfaces bound for each draw and resolve to the GPU backend "
                    "(PM4_XE_NATIVE packets in the command buffer)")
    .lifecycle(rex::cvar::Lifecycle::kHotReload);
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
  // Dump each distinct surface object once (layout reverse engineering).
  {
    static std::mutex mutex;
    static std::unordered_set<uint32_t> dumped;
    std::lock_guard<std::mutex> lock(mutex);
    for (uint32_t surface : {device.render_target(0), device.render_target(1),
                             device.depth_stencil()}) {
      if (!surface || !dumped.insert(surface).second) {
        continue;
      }
      std::string words;
      for (uint32_t i = 0; i < 16; ++i) {
        words += fmt::format(" {:08X}", LoadGuest32(base, surface + i * 4));
      }
      REXSYS_INFO("[native-gpu] surface {:08X}:{}", surface, words);
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

namespace {
std::atomic<uint32_t> merged_tile_width{0};
std::atomic<uint32_t> merged_tile_height{0};
std::atomic<uint32_t> merged_full_height{0};

inline void StoreGuest32(uint8_t* base, uint32_t address, uint32_t value) {
  *reinterpret_cast<uint32_t*>(const_cast<uint8_t*>(GuestPointer(base, address))) =
      __builtin_bswap32(value);
}
}  // namespace

void MergeTiles(uint8_t* base, uint32_t list) {
  // Other backends and the EDRAM emulation still have the EDRAM size limit.
  static const bool enabled = REXCVAR_GET(native_gpu_merge_tiles) &&
                              rex::cvar::GetFlagByName("gpu_backend") == "metal" &&
                              rex::cvar::GetFlagByName("metal_native_surfaces") == "true";
  if (!enabled || LoadGuest32(base, list) != 0x80000000u) {
    return;
  }
  uint32_t count = LoadGuest32(base, list + 8);
  if (count < 2 || count > 15) {
    return;
  }
  // Merge the rectangles into the first.
  uint32_t left = LoadGuest32(base, list + 12), top = LoadGuest32(base, list + 16);
  uint32_t right = LoadGuest32(base, list + 20), bottom = LoadGuest32(base, list + 24);
  uint32_t first_right = right, first_bottom = bottom;
  for (uint32_t i = 1; i < count; ++i) {
    uint32_t rect = list + 12 + i * 16;
    left = std::min(left, LoadGuest32(base, rect));
    top = std::min(top, LoadGuest32(base, rect + 4));
    right = std::max(right, LoadGuest32(base, rect + 8));
    bottom = std::max(bottom, LoadGuest32(base, rect + 12));
  }
  StoreGuest32(base, list + 8, 1);
  StoreGuest32(base, list + 12, left);
  StoreGuest32(base, list + 16, top);
  StoreGuest32(base, list + 20, right);
  StoreGuest32(base, list + 24, bottom);
  {
    static std::mutex mutex;
    static std::unordered_set<uint64_t> logged;
    uint64_t key = (uint64_t(first_right) << 40) | (uint64_t(first_bottom) << 20) | bottom;
    std::lock_guard<std::mutex> lock(mutex);
    if (logged.insert(key).second) {
      REXSYS_INFO("[native-gpu] merged tile list: {} tiles, first {}x{}, whole {}x{}", count,
                  first_right, first_bottom, right, bottom);
    }
  }
  // Surfaces of the size of the first tile are really as tall as the whole
  // area (see ReportSurfaces).
  merged_tile_width.store(first_right);
  merged_tile_height.store(first_bottom);
  merged_full_height.store(bottom);
}

// Writes a PM4_XE_NATIVE packet with the bound surfaces into the device's
// command buffer if they changed since the last one, before the device writes
// the packets of a draw or a resolve.
void ReportSurfaces(PPCContext& ctx, uint8_t* base, uint32_t device_address) {
  if (!REXCVAR_GET(native_gpu_report_surfaces)) {
    return;
  }
  D3DDevice device(base, device_address);
  constexpr uint32_t kSurfaceCount = 5;
  constexpr uint32_t kPayload = 1 + kSurfaceCount * 5 + 3;
  uint32_t payload[kPayload];
  payload[0] = 1;  // Subcommand: surfaces.
  for (uint32_t i = 0; i < kSurfaceCount; ++i) {
    uint32_t object = i ? device.render_target(i - 1) : device.depth_stencil();
    uint32_t* out = payload + 1 + i * 5;
    out[0] = object;
    out[1] = object ? LoadGuest32(base, object + 24) : 0;
    out[2] = object ? LoadGuest32(base, object + 28) : 0;
    out[3] = object ? LoadGuest32(base, object + 36) : 0;
    // size: (width - 1) << 18 | (height - 1) << 3.
    if (object && merged_full_height.load()) {
      uint32_t width = (out[3] >> 18) + 1;
      uint32_t height = ((out[3] >> 3) & 0x7FFF) + 1;
      if (width == merged_tile_width.load() && height == merged_tile_height.load()) {
        out[3] = (out[3] & ~(uint32_t(0x7FFF) << 3)) | ((merged_full_height.load() - 1) << 3);
      }
    }
    out[4] = object ? LoadGuest32(base, object + 40) : 0;
  }
  // PA_SC_WINDOW_SCISSOR_BR of the merged first tile and of the merged area.
  uint32_t merged_height = merged_full_height.load();
  uint32_t* merged_out = payload + 1 + kSurfaceCount * 5;
  merged_out[0] = merged_height ? (merged_tile_height.load() << 16) | merged_tile_width.load() : 0;
  merged_out[1] = merged_height ? (merged_height << 16) | merged_tile_width.load() : 0;
  merged_out[2] = 0;
  static uint32_t last_device = 0;
  static uint32_t last_payload[kPayload] = {};
  if (last_device == device_address && !std::memcmp(last_payload, payload, sizeof(payload))) {
    return;
  }
  uint32_t write = device.Load(D3DDevice::kCommandBufferWrite);
  uint32_t limit = device.Load(D3DDevice::kCommandBufferLimit);
  if (write + 4 * (1 + kPayload) > limit) {
    // Let the device kick the command buffer and make space, keeping the
    // caller's registers (the draw arguments and the return address).
    PPCContext saved = ctx;
    ctx.r3.u64 = device_address;
    FastHelper_821E8D20(ctx, base);
    write = ctx.r3.u32;
    ctx = saved;
  }
  auto store = [&](uint32_t value) {
    write += 4;
    *reinterpret_cast<uint32_t*>(const_cast<uint8_t*>(GuestPointer(base, write))) =
        __builtin_bswap32(value);
  };
  store(0xC0000000u | ((kPayload - 1) << 16) | (0x65u << 8));
  for (uint32_t value : payload) {
    store(value);
  }
  *reinterpret_cast<uint32_t*>(const_cast<uint8_t*>(
      GuestPointer(base, device_address + D3DDevice::kCommandBufferWrite))) =
      __builtin_bswap32(write);
  last_device = device_address;
  std::memcpy(last_payload, payload, sizeof(payload));
}

}  // namespace fable2::native_gpu

#define FABLE2_NATIVE_GPU_DRAW_HOOK(name)                                              \
  extern "C" void __imp__##name(PPCContext& __restrict ctx, uint8_t* base);            \
  extern "C" void name(PPCContext& __restrict ctx, uint8_t* base) {                    \
    uint32_t device = ctx.r3.u32;                                                      \
    fable2::native_gpu::ReportSurfaces(ctx, base, device);                             \
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

// D3DDevice_Resolve: reads the bound surfaces too.
extern "C" void __imp__ProcessAndProcessAndProcess806_822069C0(PPCContext& __restrict ctx,
                                                              uint8_t* base);
extern "C" void ProcessAndProcessAndProcess806_822069C0(PPCContext& __restrict ctx, uint8_t* base) {
  fable2::native_gpu::ReportSurfaces(ctx, base, ctx.r3.u32);
  __imp__ProcessAndProcessAndProcess806_822069C0(ctx, base);
}

// The D3D runtime's tiling token list: the main scene doesn't fit the Xbox 360
// EDRAM, so it's replayed once per tile. Host render targets have no such limit,
// so the game is told there's a single tile covering all of them.
// Token 0x80000000 is followed by flags, the tile count and the rectangles
// (left, top, right, bottom).
extern "C" void __imp__ProcessAndProcessAndProcess1079_82B9ED28(PPCContext& __restrict ctx,
                                                               uint8_t* base);
extern "C" void ProcessAndProcessAndProcess1079_82B9ED28(PPCContext& __restrict ctx, uint8_t* base) {
  fable2::native_gpu::MergeTiles(base, ctx.r3.u32);
  __imp__ProcessAndProcessAndProcess1079_82B9ED28(ctx, base);
}
