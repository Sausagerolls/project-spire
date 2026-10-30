/**
 * @file        graphics/metal/render_target_cache.mm
 * @brief       EDRAM emulation with host render targets for the Metal backend
 *
 * The SPIR-V generation of the EDRAM dump shaders is from the Vulkan backend
 * (Xenia, Copyright 2022 Ben Vanik, BSD license).
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */

#include <rex/graphics/metal/render_target_cache.h>

#include <algorithm>
#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>

#include <SPIRV/GLSL.std.450.h>
#include <xxhash.h>

#include <rex/assert.h>
#include <rex/cvar.h>
#include <rex/graphics/metal/command_processor.h>
#include <rex/graphics/metal/msl_util.h>
#include <rex/graphics/metal/shared_memory.h>
#include <rex/ui/metal/metal_provider.h>
#include <rex/graphics/metal/texture_cache.h>
#include <rex/graphics/pipeline/shader/spirv_builder.h>
#include <rex/graphics/pipeline/shader/spirv_translator.h>
#include <rex/graphics/registers.h>
#include <rex/graphics/util/draw.h>
#include <rex/logging.h>
#include <rex/math.h>

REXCVAR_DEFINE_BOOL(metal_render_target_transfers_in_pass, true, "GPU/Metal",
                    "Perform EDRAM ownership transfers inside the guest render pass of the draw "
                    "when possible")
    .lifecycle(rex::cvar::Lifecycle::kHotReload);
REXCVAR_DEFINE_BOOL(metal_render_target_transfers, true, "GPU/Metal",
                    "Copy the EDRAM data between render targets aliasing the same EDRAM range "
                    "(disable only for debugging - causes artefacts)")
    .lifecycle(rex::cvar::Lifecycle::kHotReload);

namespace rex::graphics::metal {

namespace shaders {
#include "../shaders/vulkan_spirv/resolve_fast_32bpp_1x2xmsaa_cs.h"
#include "../shaders/vulkan_spirv/resolve_fast_32bpp_4xmsaa_cs.h"
#include "../shaders/vulkan_spirv/resolve_fast_64bpp_1x2xmsaa_cs.h"
#include "../shaders/vulkan_spirv/resolve_fast_64bpp_4xmsaa_cs.h"
#include "../shaders/vulkan_spirv/resolve_full_128bpp_cs.h"
#include "../shaders/vulkan_spirv/resolve_full_16bpp_cs.h"
#include "../shaders/vulkan_spirv/resolve_full_32bpp_cs.h"
#include "../shaders/vulkan_spirv/resolve_full_64bpp_cs.h"
#include "../shaders/vulkan_spirv/resolve_full_8bpp_cs.h"
}  // namespace shaders

namespace {

struct ResolveCopyShaderCode {
  const uint32_t* code;
  size_t code_size;
};
const ResolveCopyShaderCode kResolveCopyShaders[size_t(draw_util::ResolveCopyShaderIndex::kCount)] = {
    {shaders::resolve_fast_32bpp_1x2xmsaa_cs, sizeof(shaders::resolve_fast_32bpp_1x2xmsaa_cs)},
    {shaders::resolve_fast_32bpp_4xmsaa_cs, sizeof(shaders::resolve_fast_32bpp_4xmsaa_cs)},
    {shaders::resolve_fast_64bpp_1x2xmsaa_cs, sizeof(shaders::resolve_fast_64bpp_1x2xmsaa_cs)},
    {shaders::resolve_fast_64bpp_4xmsaa_cs, sizeof(shaders::resolve_fast_64bpp_4xmsaa_cs)},
    {shaders::resolve_full_8bpp_cs, sizeof(shaders::resolve_full_8bpp_cs)},
    {shaders::resolve_full_16bpp_cs, sizeof(shaders::resolve_full_16bpp_cs)},
    {shaders::resolve_full_32bpp_cs, sizeof(shaders::resolve_full_32bpp_cs)},
    {shaders::resolve_full_64bpp_cs, sizeof(shaders::resolve_full_64bpp_cs)},
    {shaders::resolve_full_128bpp_cs, sizeof(shaders::resolve_full_128bpp_cs)},
};

// Metal argument table indices of the utility shaders (see msl_util.h): set S
// binding B is buffer kMslBufferUtilityFirst + 4 * S + B, texture 4 * S + B.
constexpr uint32_t UtilityBuffer(uint32_t set, uint32_t binding) {
  return kMslBufferUtilityFirst + 4 * set + binding;
}
constexpr uint32_t UtilityTexture(uint32_t set, uint32_t binding) { return 4 * set + binding; }

bool IsColor16FormatFloatLike(xenos::ColorRenderTargetFormat format) {
  return format == xenos::ColorRenderTargetFormat::k_16_16_FLOAT ||
         format == xenos::ColorRenderTargetFormat::k_16_16_16_16_FLOAT;
}

NSString* const kClearShaderSource = @R"(
#include <metal_stdlib>
using namespace metal;
struct VertexOut {
  float4 position [[position]];
};
vertex VertexOut clear_vs(uint vertex_id [[vertex_id]]) {
  VertexOut out;
  float2 position = float2(float((vertex_id << 1u) & 2u), float(vertex_id & 2u));
  out.position = float4(position * 2.0 - 1.0, 0.0, 1.0);
  return out;
}
fragment float4 clear_color_ps(constant float4& color [[buffer(0)]]) {
  return color;
}
struct DepthOut {
  float depth [[depth(any)]];
};
fragment DepthOut clear_depth_ps(constant float4& value [[buffer(0)]]) {
  DepthOut out;
  out.depth = value.x;
  return out;
}
)";

NSString* const kTransferShaderSource = @R"(
#include <metal_stdlib>
using namespace metal;
// Specialization: destination and source render targets.
constant uint kDestFormat [[function_constant(0)]];
constant bool kDestIsDepth [[function_constant(1)]];
constant uint kDestMsaaLog2 [[function_constant(2)]];
constant bool kDestIs64bpp [[function_constant(3)]];
constant uint kSourceFormat [[function_constant(4)]];
constant bool kSourceIsDepth [[function_constant(5)]];
constant uint kSourceMsaaLog2 [[function_constant(6)]];
constant bool kSourceIs64bpp [[function_constant(7)]];
// Same pitch, base and bits per sample - the EDRAM addresses of the
// destination samples are the same sample coordinates in the source.
constant bool kSameLayout [[function_constant(8)]];
// Same format too - no conversion needed.
constant bool kSameFormat = kSameLayout && kSourceFormat == kDestFormat &&
                            kSourceIsDepth == kDestIsDepth;
constant bool kSourceColor1x = !kSourceIsDepth && kSourceMsaaLog2 == 0u;
constant bool kSourceColorMs = !kSourceIsDepth && kSourceMsaaLog2 != 0u;
constant bool kSourceDepth1x = kSourceIsDepth && kSourceMsaaLog2 == 0u;
constant bool kSourceDepthMs = kSourceIsDepth && kSourceMsaaLog2 != 0u;
struct Params {
  uint dest_base_tiles;
  uint dest_pitch_tiles;
  uint source_base_tiles;
  uint source_pitch_tiles;
};
struct VertexOut {
  float4 position [[position]];
};
vertex VertexOut transfer_vs(uint vertex_id [[vertex_id]]) {
  VertexOut out;
  float2 position = float2(float((vertex_id << 1u) & 2u), float(vertex_id & 2u));
  out.position = float4(position * 2.0 - 1.0, 0.0, 1.0);
  return out;
}
uint2 pixel_to_samples(uint2 pixel, uint sample, uint msaa_log2) {
  if (msaa_log2 >= 2u) {
    return uint2(pixel.x * 2u + (sample & 1u), pixel.y * 2u + (sample >> 1u));
  }
  if (msaa_log2 == 1u) {
    // Host sample 1 is the top guest sample, 0 the bottom one.
    return uint2(pixel.x, pixel.y * 2u + (sample == 0u ? 1u : 0u));
  }
  return pixel;
}
void samples_to_pixel(uint2 samples, uint msaa_log2, thread uint2& pixel, thread uint& sample) {
  if (msaa_log2 >= 2u) {
    pixel = samples >> 1u;
    sample = (samples.x & 1u) | ((samples.y & 1u) << 1u);
  } else if (msaa_log2 == 1u) {
    pixel = uint2(samples.x, samples.y >> 1u);
    sample = (samples.y & 1u) != 0u ? 0u : 1u;
  } else {
    pixel = samples;
    sample = 0u;
  }
}
// 7e3 and 20e4 conversions as in the Xenos backends.
uint f32_to_7e3(float f) {
  f = clamp(f, 0.0, 31.875);
  uint u = as_type<uint>(f);
  uint biased = u < 0x3E800000u ? ((u & 0x7FFFFFu) | 0x800000u) >> min(125u - (u >> 23u), 24u)
                                : u - (124u << 23u);
  return ((biased + 0x7FFFu + ((biased >> 16u) & 1u)) >> 16u) & 0x3FFu;
}
float f7e3_to_f32(uint f10) {
  uint mantissa = f10 & 0x7Fu;
  uint exponent = (f10 >> 7u) & 7u;
  if (exponent == 0u) {
    return float(mantissa) * exp2(-13.0);
  }
  return (1.0 + float(mantissa) / 128.0) * exp2(float(exponent) - 3.0);
}
uint f32_to_20e4(float f) {
  if (!(f > 0.0)) {
    return 0u;
  }
  uint u = as_type<uint>(f);
  if (u >= 0x3FFFFFF8u) {
    return 0xFFFFFFu;
  }
  if (u < 0x38800000u) {
    u = (0x800000u | (u & 0x7FFFFFu)) >> min(113u - (u >> 23u), 24u);
  } else {
    u += 0xC8000000u;
  }
  return (u >> 3u) & 0xFFFFFFu;
}
float f20e4_to_f32(uint f24) {
  f24 &= 0xFFFFFFu;
  if (f24 == 0u) {
    return 0.0;
  }
  uint mantissa = f24 & 0xFFFFFu;
  uint exponent = f24 >> 20u;
  if (exponent == 0u) {
    uint shift = clz(mantissa) - (32u - 21u);
    exponent = uint(1 - int(shift));
    mantissa = (mantissa << shift) & 0xFFFFFu;
  }
  return as_type<float>(((exponent + 112u) << 23u) | (mantissa << 3u));
}
uint pack16(float value, bool is_float) {
  if (is_float) {
    return uint(as_type<ushort>(half(value)));
  }
  return uint(int(rint(clamp(value, -1.0, 1.0) * 32767.0))) & 0xFFFFu;
}
float unpack16(uint value, bool is_float) {
  return is_float ? float(as_type<half>(ushort(value)))
                  : max(float(int(value << 16u) >> 16) / 32767.0, -1.0);
}
// Packs a source color to its EDRAM representation.
uint2 pack_color(float4 c, uint format) {
  switch (format) {
    case 0u:
    case 1u:
      return uint2(uint(c.r * 255.0 + 0.5) | (uint(c.g * 255.0 + 0.5) << 8u) |
                       (uint(c.b * 255.0 + 0.5) << 16u) | (uint(c.a * 255.0 + 0.5) << 24u),
                   0u);
    case 2u:
    case 10u:
      return uint2(uint(c.r * 1023.0 + 0.5) | (uint(c.g * 1023.0 + 0.5) << 10u) |
                       (uint(c.b * 1023.0 + 0.5) << 20u) | (uint(saturate(c.a) * 3.0 + 0.5) << 30u),
                   0u);
    case 3u:
    case 12u:
      return uint2(f32_to_7e3(c.r) | (f32_to_7e3(c.g) << 10u) | (f32_to_7e3(c.b) << 20u) |
                       (uint(saturate(c.a) * 3.0 + 0.5) << 30u),
                   0u);
    case 4u:
    case 6u:
      return uint2(pack16(c.r, format == 6u) | (pack16(c.g, format == 6u) << 16u), 0u);
    case 5u:
    case 7u:
      return uint2(pack16(c.r, format == 7u) | (pack16(c.g, format == 7u) << 16u),
                   pack16(c.b, format == 7u) | (pack16(c.a, format == 7u) << 16u));
    case 14u:
      return uint2(as_type<uint>(c.r), 0u);
    case 15u:
      return uint2(as_type<uint>(c.r), as_type<uint>(c.g));
    default:
      return uint2(0u);
  }
}
float4 unpack_color(uint2 v, uint format) {
  uint value = v.x;
  switch (format) {
    case 0u:
    case 1u:
      return float4(float(value & 0xFFu), float((value >> 8u) & 0xFFu),
                    float((value >> 16u) & 0xFFu), float(value >> 24u)) / 255.0;
    case 2u:
    case 10u:
      return float4(float(value & 0x3FFu) / 1023.0, float((value >> 10u) & 0x3FFu) / 1023.0,
                    float((value >> 20u) & 0x3FFu) / 1023.0, float(value >> 30u) / 3.0);
    case 3u:
    case 12u:
      return float4(f7e3_to_f32(value & 0x3FFu), f7e3_to_f32((value >> 10u) & 0x3FFu),
                    f7e3_to_f32((value >> 20u) & 0x3FFu), float(value >> 30u) / 3.0);
    case 4u:
    case 6u:
      return float4(unpack16(value & 0xFFFFu, format == 6u), unpack16(value >> 16u, format == 6u),
                    0.0, 0.0);
    case 5u:
    case 7u:
      return float4(unpack16(v.x & 0xFFFFu, format == 7u), unpack16(v.x >> 16u, format == 7u),
                    unpack16(v.y & 0xFFFFu, format == 7u), unpack16(v.y >> 16u, format == 7u));
    case 14u:
      return float4(as_type<float>(v.x), 0.0, 0.0, 0.0);
    case 15u:
      return float4(as_type<float>(v.x), as_type<float>(v.y), 0.0, 0.0);
    default:
      return float4(0.0);
  }
}
struct Sources {
  texture2d<float> color_1x;
  texture2d_ms<float> color_ms;
  depth2d<float> depth_1x;
  depth2d_ms<float> depth_ms;
  texture2d<uint> stencil_1x;
  texture2d_ms<uint> stencil_ms;
};
// Reads one source EDRAM element (packed) at the source samples.
uint2 read_source(uint2 samples, thread const Sources& sources) {
  uint2 pixel;
  uint sample;
  samples_to_pixel(samples, kSourceMsaaLog2, pixel, sample);
  if (kSourceIsDepth) {
    float depth;
    uint stencil;
    if (kSourceDepthMs) {
      depth = sources.depth_ms.read(pixel, sample);
      stencil = sources.stencil_ms.read(pixel, sample).x;
    } else {
      depth = sources.depth_1x.read(pixel);
      stencil = sources.stencil_1x.read(pixel).x;
    }
    uint depth24 = kSourceFormat == 1u ? f32_to_20e4(depth * 2.0)
                                       : uint(rint(depth * 16777215.0));
    return uint2((depth24 << 8u) | (stencil & 0xFFu), 0u);
  }
  float4 color = kSourceColorMs ? sources.color_ms.read(pixel, sample)
                                : sources.color_1x.read(pixel);
  return pack_color(color, kSourceFormat);
}
// The destination sample's data in the EDRAM layout of the source.
uint2 fetch_edram(uint2 dest_pixel, uint dest_sample, constant Params& params,
                  thread const Sources& sources) {
  uint2 dest_samples = pixel_to_samples(dest_pixel, dest_sample, kDestMsaaLog2);
  if (kSameLayout) {
    return read_source(dest_samples, sources);
  }
  uint dest_tile_width = kDestIs64bpp ? 40u : 80u;
  uint tile_x = dest_samples.x / dest_tile_width;
  uint tile_y = dest_samples.y / 16u;
  uint tx = dest_samples.x % dest_tile_width;
  uint ty = dest_samples.y % 16u;
  if (kDestIsDepth) {
    tx = tx < dest_tile_width / 2u ? tx + dest_tile_width / 2u : tx - dest_tile_width / 2u;
  }
  uint tile = params.dest_base_tiles + tile_y * params.dest_pitch_tiles + tile_x;
  uint byte_in_tile = (ty * dest_tile_width + tx) * (kDestIs64bpp ? 8u : 4u);
  // In the source.
  uint source_tile_width = kSourceIs64bpp ? 40u : 80u;
  uint source_element_size = kSourceIs64bpp ? 8u : 4u;
  uint source_relative_tile = (tile - params.source_base_tiles) & 2047u;
  uint source_tile_y = source_relative_tile / params.source_pitch_tiles;
  uint source_tile_x = source_relative_tile % params.source_pitch_tiles;
  uint dwords_needed = kDestIs64bpp ? 2u : 1u;
  uint dwords[2] = {0u, 0u};
  for (uint i = 0u; i < dwords_needed; ++i) {
    uint byte = byte_in_tile + i * 4u;
    uint element = byte / source_element_size;
    uint dword_in_element = (byte % source_element_size) / 4u;
    uint stx = element % source_tile_width;
    uint sty = element / source_tile_width;
    if (kSourceIsDepth) {
      stx = stx < source_tile_width / 2u ? stx + source_tile_width / 2u
                                         : stx - source_tile_width / 2u;
    }
    uint2 source_samples = uint2(source_tile_x * source_tile_width + stx,
                                 source_tile_y * 16u + sty);
    uint2 packed = read_source(source_samples, sources);
    dwords[i] = dword_in_element ? packed.y : packed.x;
  }
  return uint2(dwords[0], dwords[1]);
}
fragment float4 transfer_color_ps(
    VertexOut in [[stage_in]], uint sample [[sample_id]], constant Params& params [[buffer(30)]],
    texture2d<float> color_1x [[texture(30), function_constant(kSourceColor1x)]],
    texture2d_ms<float> color_ms [[texture(30), function_constant(kSourceColorMs)]],
    depth2d<float> depth_1x [[texture(30), function_constant(kSourceDepth1x)]],
    depth2d_ms<float> depth_ms [[texture(30), function_constant(kSourceDepthMs)]],
    texture2d<uint> stencil_1x [[texture(31), function_constant(kSourceDepth1x)]],
    texture2d_ms<uint> stencil_ms [[texture(31), function_constant(kSourceDepthMs)]]) {
  Sources sources;
  if (kSourceColor1x) sources.color_1x = color_1x;
  if (kSourceColorMs) sources.color_ms = color_ms;
  if (kSourceDepth1x) { sources.depth_1x = depth_1x; sources.stencil_1x = stencil_1x; }
  if (kSourceDepthMs) { sources.depth_ms = depth_ms; sources.stencil_ms = stencil_ms; }
  if (kSameFormat && !kDestIsDepth) {
    uint2 pixel;
    uint source_sample;
    samples_to_pixel(pixel_to_samples(uint2(in.position.xy), sample, kDestMsaaLog2),
                     kSourceMsaaLog2, pixel, source_sample);
    return kSourceColorMs ? color_ms.read(pixel, source_sample) : color_1x.read(pixel);
  }
  return unpack_color(fetch_edram(uint2(in.position.xy), sample, params, sources), kDestFormat);
}
// For transfers inside a guest render pass with multiple attachments - the
// pipeline's write masks select the destination.
struct ColorOut4 {
  float4 color0 [[color(0)]];
  float4 color1 [[color(1)]];
  float4 color2 [[color(2)]];
  float4 color3 [[color(3)]];
};
fragment ColorOut4 transfer_color_mrt_ps(
    VertexOut in [[stage_in]], uint sample [[sample_id]], constant Params& params [[buffer(30)]],
    texture2d<float> color_1x [[texture(30), function_constant(kSourceColor1x)]],
    texture2d_ms<float> color_ms [[texture(30), function_constant(kSourceColorMs)]],
    depth2d<float> depth_1x [[texture(30), function_constant(kSourceDepth1x)]],
    depth2d_ms<float> depth_ms [[texture(30), function_constant(kSourceDepthMs)]],
    texture2d<uint> stencil_1x [[texture(31), function_constant(kSourceDepth1x)]],
    texture2d_ms<uint> stencil_ms [[texture(31), function_constant(kSourceDepthMs)]]) {
  Sources sources;
  if (kSourceColor1x) sources.color_1x = color_1x;
  if (kSourceColorMs) sources.color_ms = color_ms;
  if (kSourceDepth1x) { sources.depth_1x = depth_1x; sources.stencil_1x = stencil_1x; }
  if (kSourceDepthMs) { sources.depth_ms = depth_ms; sources.stencil_ms = stencil_ms; }
  float4 color;
  if (kSameFormat && !kDestIsDepth) {
    uint2 pixel;
    uint source_sample;
    samples_to_pixel(pixel_to_samples(uint2(in.position.xy), sample, kDestMsaaLog2),
                     kSourceMsaaLog2, pixel, source_sample);
    color = kSourceColorMs ? color_ms.read(pixel, source_sample) : color_1x.read(pixel);
  } else {
    color = unpack_color(fetch_edram(uint2(in.position.xy), sample, params, sources), kDestFormat);
  }
  ColorOut4 out;
  out.color0 = color;
  out.color1 = color;
  out.color2 = color;
  out.color3 = color;
  return out;
}
struct DepthOut {
  float depth [[depth(any)]];
  uint stencil [[stencil]];
};
fragment DepthOut transfer_depth_ps(
    VertexOut in [[stage_in]], uint sample [[sample_id]], constant Params& params [[buffer(30)]],
    texture2d<float> color_1x [[texture(30), function_constant(kSourceColor1x)]],
    texture2d_ms<float> color_ms [[texture(30), function_constant(kSourceColorMs)]],
    depth2d<float> depth_1x [[texture(30), function_constant(kSourceDepth1x)]],
    depth2d_ms<float> depth_ms [[texture(30), function_constant(kSourceDepthMs)]],
    texture2d<uint> stencil_1x [[texture(31), function_constant(kSourceDepth1x)]],
    texture2d_ms<uint> stencil_ms [[texture(31), function_constant(kSourceDepthMs)]]) {
  Sources sources;
  if (kSourceColor1x) sources.color_1x = color_1x;
  if (kSourceColorMs) sources.color_ms = color_ms;
  if (kSourceDepth1x) { sources.depth_1x = depth_1x; sources.stencil_1x = stencil_1x; }
  if (kSourceDepthMs) { sources.depth_ms = depth_ms; sources.stencil_ms = stencil_ms; }
  DepthOut out;
  if (kSameFormat) {
    uint2 pixel;
    uint source_sample;
    samples_to_pixel(pixel_to_samples(uint2(in.position.xy), sample, kDestMsaaLog2),
                     kSourceMsaaLog2, pixel, source_sample);
    out.depth = kSourceDepthMs ? depth_ms.read(pixel, source_sample) : depth_1x.read(pixel);
    out.stencil = kSourceDepthMs ? stencil_ms.read(pixel, source_sample).x
                                 : stencil_1x.read(pixel).x;
    return out;
  }
  uint value = fetch_edram(uint2(in.position.xy), sample, params, sources).x;
  // 0 - D24S8, 1 - D24FS8 (stored as [0, 0.5) on the host).
  out.depth = kDestFormat == 1u ? f20e4_to_f32(value >> 8u) * 0.5
                                : float(value >> 8u) / 16777215.0;
  out.stencil = value & 0xFFu;
  return out;
}
)";

}  // namespace

MetalRenderTargetCache::~MetalRenderTargetCache() {
  Shutdown(true);
}

bool MetalRenderTargetCache::Initialize() {
  id<MTLDevice> device = command_processor_.device();
  // EDRAM: 10 MB at 1x resolution scale.
  edram_buffer_ = [device newBufferWithLength:xenos::kEdramSizeBytes
                                      options:MTLResourceStorageModePrivate];
  if (!edram_buffer_) {
    REXGPU_ERROR("MetalRenderTargetCache: Failed to create the EDRAM buffer");
    return false;
  }
  edram_buffer_.label = @"EDRAM";

  for (size_t i = 0; i < size_t(draw_util::ResolveCopyShaderIndex::kCount); ++i) {
    const ResolveCopyShaderCode& code = kResolveCopyShaders[i];
    id<MTLFunction> function = command_processor_.CompileUtilitySpirv(
        code.code, code.code_size / sizeof(uint32_t), "resolve copy");
    if (!function) {
      continue;
    }
    NSError* error = nil;
    resolve_copy_pipelines_[i] = [device newComputePipelineStateWithFunction:function error:&error];
    if (!resolve_copy_pipelines_[i]) {
      REXGPU_ERROR("MetalRenderTargetCache: Failed to create resolve copy pipeline {}: {}", i,
                   error ? [error.localizedDescription UTF8String] : "unknown error");
    }
  }

  id<MTLLibrary> clear_library =
      command_processor_.GetMetalProvider().CompileLibrary(kClearShaderSource, "clear");
  if (!clear_library) {
    return false;
  }
  clear_vs_ = [clear_library newFunctionWithName:@"clear_vs"];
  clear_color_ps_ = [clear_library newFunctionWithName:@"clear_color_ps"];
  clear_depth_ps_ = [clear_library newFunctionWithName:@"clear_depth_ps"];

  transfer_library_ = command_processor_.GetMetalProvider().CompileLibrary(
      kTransferShaderSource, "render target transfer");
  if (!transfer_library_) {
    return false;
  }
  transfer_vs_ = [transfer_library_ newFunctionWithName:@"transfer_vs"];
  MTLDepthStencilDescriptor* load_depth_stencil = [[MTLDepthStencilDescriptor alloc] init];
  load_depth_stencil.depthCompareFunction = MTLCompareFunctionAlways;
  load_depth_stencil.depthWriteEnabled = YES;
  MTLStencilDescriptor* load_stencil = [[MTLStencilDescriptor alloc] init];
  load_stencil.stencilCompareFunction = MTLCompareFunctionAlways;
  load_stencil.depthStencilPassOperation = MTLStencilOperationReplace;
  load_stencil.writeMask = 0xFF;
  load_depth_stencil.frontFaceStencil = load_stencil;
  load_depth_stencil.backFaceStencil = load_stencil;
  transfer_depth_stencil_state_ =
      [command_processor_.device() newDepthStencilStateWithDescriptor:load_depth_stencil];

  InitializeCommon();
  return true;
}

void MetalRenderTargetCache::Shutdown(bool from_destructor) {
  if (!from_destructor) {
    ClearCache();
  }
  dump_pipelines_.clear();
  clear_pipelines_.clear();
  transfer_pipelines_.clear();
  clear_depth_stencil_state_ = nil;
  for (auto& pipeline : resolve_copy_pipelines_) {
    pipeline = nil;
  }
  edram_buffer_ = nil;
  if (!from_destructor) {
    ShutdownCommon();
  }
}

MTLPixelFormat MetalRenderTargetCache::GetColorMetalFormat(xenos::ColorRenderTargetFormat format) {
  switch (format) {
    case xenos::ColorRenderTargetFormat::k_8_8_8_8:
    case xenos::ColorRenderTargetFormat::k_8_8_8_8_GAMMA:
      return MTLPixelFormatRGBA8Unorm;
    case xenos::ColorRenderTargetFormat::k_2_10_10_10:
    case xenos::ColorRenderTargetFormat::k_2_10_10_10_AS_10_10_10_10:
      return MTLPixelFormatRGB10A2Unorm;
    case xenos::ColorRenderTargetFormat::k_2_10_10_10_FLOAT:
    case xenos::ColorRenderTargetFormat::k_2_10_10_10_FLOAT_AS_16_16_16_16:
      return MTLPixelFormatRGBA16Float;
    case xenos::ColorRenderTargetFormat::k_16_16:
      return MTLPixelFormatRG16Snorm;
    case xenos::ColorRenderTargetFormat::k_16_16_16_16:
      return MTLPixelFormatRGBA16Snorm;
    case xenos::ColorRenderTargetFormat::k_16_16_FLOAT:
      return MTLPixelFormatRG16Float;
    case xenos::ColorRenderTargetFormat::k_16_16_16_16_FLOAT:
      return MTLPixelFormatRGBA16Float;
    case xenos::ColorRenderTargetFormat::k_32_FLOAT:
      return MTLPixelFormatR32Float;
    case xenos::ColorRenderTargetFormat::k_32_32_FLOAT:
      return MTLPixelFormatRG32Float;
    default:
      return MTLPixelFormatInvalid;
  }
}

MTLPixelFormat MetalRenderTargetCache::GetDepthMetalFormat(xenos::DepthRenderTargetFormat format) {
  (void)format;
  // Apple GPUs have no 24-bit depth.
  return MTLPixelFormatDepth32Float_Stencil8;
}

bool MetalRenderTargetCache::IsHostDepthEncodingDifferent(
    xenos::DepthRenderTargetFormat format) const {
  // Both are stored as 32-bit float.
  return true;
}

RenderTargetCache::RenderTarget* MetalRenderTargetCache::CreateRenderTarget(RenderTargetKey key) {
  MTLTextureDescriptor* descriptor = [[MTLTextureDescriptor alloc] init];
  uint32_t sample_count = uint32_t(1) << uint32_t(key.msaa_samples);
  descriptor.textureType = sample_count > 1 ? MTLTextureType2DMultisample : MTLTextureType2D;
  descriptor.sampleCount = sample_count;
  descriptor.width = key.GetWidth() * draw_resolution_scale_x();
  descriptor.height =
      GetRenderTargetHeight(key.pitch_tiles_at_32bpp, key.msaa_samples) * draw_resolution_scale_y();
  descriptor.pixelFormat = key.is_depth ? GetDepthMetalFormat(key.GetDepthFormat())
                                        : GetColorMetalFormat(key.GetColorFormat());
  if (descriptor.pixelFormat == MTLPixelFormatInvalid) {
    REXGPU_ERROR("MetalRenderTargetCache: Unknown {} render target format {}",
                 key.is_depth ? "depth" : "color", uint32_t(key.resource_format));
    return nullptr;
  }
  descriptor.usage =
      MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
  descriptor.storageMode = MTLStorageModePrivate;
  id<MTLTexture> texture = [command_processor_.device() newTextureWithDescriptor:descriptor];
  if (!texture) {
    REXGPU_ERROR("MetalRenderTargetCache: Failed to create a {}x{} {}xMSAA {} render target",
                 uint32_t(descriptor.width), uint32_t(descriptor.height), sample_count,
                 key.GetFormatName());
    return nullptr;
  }
  texture.label = [NSString stringWithUTF8String:key.GetFormatName()];
  id<MTLTexture> stencil_view = nil;
  if (key.is_depth) {
    stencil_view = [texture newTextureViewWithPixelFormat:MTLPixelFormatX32_Stencil8];
  }
  return new MetalRenderTarget(key, texture, stencil_view);
}

bool MetalRenderTargetCache::Update(bool is_rasterization_done,
                                    reg::RB_DEPTHCONTROL normalized_depth_control,
                                    uint32_t normalized_color_mask, const Shader& vertex_shader) {
  if (!RenderTargetCache::Update(is_rasterization_done, normalized_depth_control,
                                 normalized_color_mask, vertex_shader)) {
    return false;
  }
  RenderTarget* const* render_targets = last_update_accumulated_render_targets();
  // Transfers to the render targets of this draw are performed in its render
  // pass (PerformPendingTransfersInRenderPass) - unless a source is bound
  // too, in which case it can't be read in the pass.
  FlushPendingTransfers();
  const std::vector<Transfer>* transfers = last_update_transfers();
  bool source_bound = false;
  bool any_transfers = false;
  for (uint32_t i = 0; i < 1 + xenos::kMaxColorRenderTargets; ++i) {
    for (const Transfer& transfer : transfers[i]) {
      any_transfers = true;
      for (uint32_t j = 0; j < 1 + xenos::kMaxColorRenderTargets; ++j) {
        if (transfer.source && transfer.source == render_targets[j]) {
          source_bound = true;
        }
      }
    }
  }
  if (any_transfers && REXCVAR_GET(metal_render_target_transfers)) {
    if (source_bound || !REXCVAR_GET(metal_render_target_transfers_in_pass)) {
      PerformTransfers(1 + xenos::kMaxColorRenderTargets, render_targets, transfers);
    } else {
      for (uint32_t i = 0; i < 1 + xenos::kMaxColorRenderTargets; ++i) {
        pending_transfer_render_targets_[i] = render_targets[i];
        pending_transfers_[i] = transfers[i];
      }
      has_pending_transfers_ = true;
    }
  }

  auto rb_surface_info = register_file().Get<reg::RB_SURFACE_INFO>();
  RenderPassAttachments attachments;
  RenderPassFormats formats;
  formats.sample_count = uint32_t(1) << uint32_t(rb_surface_info.msaa_samples);
  uint32_t width = 0, height = 0;
  for (uint32_t i = 0; i < 1 + xenos::kMaxColorRenderTargets; ++i) {
    if (!render_targets[i]) {
      continue;
    }
    id<MTLTexture> texture = static_cast<MetalRenderTarget*>(render_targets[i])->texture();
    if (i) {
      attachments.color[i - 1] = texture;
      formats.color[i - 1] = texture.pixelFormat;
    } else {
      attachments.depth = texture;
      formats.depth = texture.pixelFormat;
    }
    // Attachments of a render pass may differ in size - the render area is the
    // intersection.
    width = width ? std::min(width, uint32_t(texture.width)) : uint32_t(texture.width);
    height = height ? std::min(height, uint32_t(texture.height)) : uint32_t(texture.height);
  }
  last_update_attachments_ = attachments;
  last_update_formats_ = formats;
  last_update_width_ = width;
  last_update_height_ = height;
  return true;
}

void MetalRenderTargetCache::PerformTransfers(uint32_t render_target_count,
                                              RenderTarget* const* render_targets,
                                              const std::vector<Transfer>* render_target_transfers,
                                              const Transfer::Rectangle* cutout) {
  // One render pass per destination, drawing the rectangles of each transfer
  // with a shader reading the source render target at the same EDRAM
  // addresses and converting the format through the guest EDRAM
  // representation. Host depth precision is not preserved (depth goes
  // through the 24-bit guest representation).
  for (uint32_t i = 0; i < render_target_count; ++i) {
    RenderTarget* dest_rt = render_targets[i];
    if (!dest_rt || render_target_transfers[i].empty()) {
      continue;
    }
    auto& dest = *static_cast<MetalRenderTarget*>(dest_rt);
    RenderTargetKey dest_key = dest.key();
    id<MTLTexture> texture = dest.texture();
    id<MTLRenderCommandEncoder> encoder = nil;
    for (const Transfer& transfer : render_target_transfers[i]) {
      if (!transfer.source || transfer.source == dest_rt) {
        continue;
      }
      auto& source = *static_cast<MetalRenderTarget*>(transfer.source);
      RenderTargetKey source_key = source.key();
      Transfer::Rectangle rectangles[Transfer::kMaxRectanglesWithCutout];
      uint32_t rectangle_count =
          transfer.GetRectangles(dest_key.base_tiles, dest_key.GetPitchTiles(),
                                 dest_key.msaa_samples, dest_key.Is64bpp(), rectangles, cutout);
      if (!rectangle_count) {
        continue;
      }
      id<MTLRenderPipelineState> pipeline = GetTransferPipeline(source_key, dest_key, texture);
      if (!pipeline) {
        continue;
      }
      ++transfer_count_;
      if (!encoder) {
        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        if (dest_key.is_depth) {
          pass.depthAttachment.texture = texture;
          pass.depthAttachment.loadAction = MTLLoadActionLoad;
          pass.depthAttachment.storeAction = MTLStoreActionStore;
          pass.stencilAttachment.texture = texture;
          pass.stencilAttachment.loadAction = MTLLoadActionLoad;
          pass.stencilAttachment.storeAction = MTLStoreActionStore;
        } else {
          pass.colorAttachments[0].texture = texture;
          pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
          pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        }
        encoder = command_processor_.BeginUtilityRenderPass(pass, "transfer");
        encoder.label = @"transfer";
        if (dest_key.is_depth) {
          [encoder setDepthStencilState:transfer_depth_stencil_state_];
        }
      }
      [encoder setRenderPipelineState:pipeline];
      [encoder setFragmentTexture:source.texture() atIndex:30];
      if (source_key.is_depth) {
        [encoder setFragmentTexture:source.stencil_view() atIndex:31];
      }
      uint32_t params[4] = {dest_key.base_tiles, dest_key.GetPitchTiles(), source_key.base_tiles,
                            std::max(source_key.GetPitchTiles(), uint32_t(1))};
      [encoder setFragmentBytes:params length:sizeof(params) atIndex:30];
      for (uint32_t j = 0; j < rectangle_count; ++j) {
        const Transfer::Rectangle& rectangle = rectangles[j];
        MTLScissorRect scissor;
        scissor.x = std::min(NSUInteger(rectangle.x_pixels), texture.width);
        scissor.y = std::min(NSUInteger(rectangle.y_pixels), texture.height);
        scissor.width = std::min(NSUInteger(rectangle.width_pixels), texture.width - scissor.x);
        scissor.height = std::min(NSUInteger(rectangle.height_pixels), texture.height - scissor.y);
        if (!scissor.width || !scissor.height) {
          continue;
        }
        [encoder setScissorRect:scissor];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
      }
    }
    if (encoder) {
      command_processor_.EndEncoding();
    }
  }
}

id<MTLRenderPipelineState> MetalRenderTargetCache::GetTransferPipeline(
    RenderTargetKey source_key, RenderTargetKey dest_key, id<MTLTexture> texture,
    const RenderPassFormats* pass_formats, uint32_t pass_color_index) {
  struct {
    uint32_t key;
    uint32_t pass_color_index;
    RenderPassFormats formats;
  } full_key;
  std::memset(&full_key, 0, sizeof(full_key));
  full_key.key = uint32_t(dest_key.resource_format) | (uint32_t(dest_key.is_depth) << 4) |
                 (uint32_t(dest_key.msaa_samples) << 5) |
                 (uint32_t(source_key.resource_format) << 8) |
                 (uint32_t(source_key.is_depth) << 12) | (uint32_t(source_key.msaa_samples) << 13) |
                 (uint32_t(source_key.base_tiles == dest_key.base_tiles &&
                           source_key.GetPitchTiles() == dest_key.GetPitchTiles())
                  << 15);
  if (pass_formats) {
    full_key.pass_color_index = pass_color_index;
    full_key.formats = *pass_formats;
  }
  uint64_t pipeline_key = XXH3_64bits(&full_key, sizeof(full_key));
  auto it = transfer_pipelines_.find(pipeline_key);
  if (it != transfer_pipelines_.end()) {
    return it->second;
  }
  MTLFunctionConstantValues* constants = [[MTLFunctionConstantValues alloc] init];
  uint32_t values_uint[4] = {dest_key.resource_format, uint32_t(dest_key.msaa_samples),
                             source_key.resource_format, uint32_t(source_key.msaa_samples)};
  bool values_bool[4] = {bool(dest_key.is_depth), dest_key.Is64bpp(), bool(source_key.is_depth),
                         source_key.Is64bpp()};
  [constants setConstantValue:&values_uint[0] type:MTLDataTypeUInt atIndex:0];
  [constants setConstantValue:&values_bool[0] type:MTLDataTypeBool atIndex:1];
  [constants setConstantValue:&values_uint[1] type:MTLDataTypeUInt atIndex:2];
  [constants setConstantValue:&values_bool[1] type:MTLDataTypeBool atIndex:3];
  [constants setConstantValue:&values_uint[2] type:MTLDataTypeUInt atIndex:4];
  [constants setConstantValue:&values_bool[2] type:MTLDataTypeBool atIndex:5];
  [constants setConstantValue:&values_uint[3] type:MTLDataTypeUInt atIndex:6];
  [constants setConstantValue:&values_bool[3] type:MTLDataTypeBool atIndex:7];
  bool same_layout = source_key.base_tiles == dest_key.base_tiles &&
                     source_key.GetPitchTiles() == dest_key.GetPitchTiles() &&
                     source_key.Is64bpp() == dest_key.Is64bpp() &&
                     bool(source_key.is_depth) == bool(dest_key.is_depth);
  [constants setConstantValue:&same_layout type:MTLDataTypeBool atIndex:8];
  NSError* error = nil;
  id<MTLFunction> fragment = [transfer_library_
      newFunctionWithName:dest_key.is_depth ? @"transfer_depth_ps"
                          : pass_formats    ? @"transfer_color_mrt_ps"
                                            : @"transfer_color_ps"
           constantValues:constants
                    error:&error];
  id<MTLRenderPipelineState> pipeline = nil;
  if (fragment) {
    MTLRenderPipelineDescriptor* descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.label = @"render target transfer";
    descriptor.vertexFunction = transfer_vs_;
    descriptor.fragmentFunction = fragment;
    descriptor.rasterSampleCount = texture.sampleCount;
    if (pass_formats) {
      // All the attachments of the guest render pass, writing only to the
      // destination.
      for (uint32_t j = 0; j < xenos::kMaxColorRenderTargets; ++j) {
        descriptor.colorAttachments[j].pixelFormat = pass_formats->color[j];
        descriptor.colorAttachments[j].writeMask =
            (!dest_key.is_depth && j == pass_color_index) ? MTLColorWriteMaskAll
                                                          : MTLColorWriteMaskNone;
      }
      descriptor.depthAttachmentPixelFormat = pass_formats->depth;
      descriptor.stencilAttachmentPixelFormat = pass_formats->depth;
      descriptor.rasterSampleCount = pass_formats->sample_count;
    } else if (dest_key.is_depth) {
      descriptor.depthAttachmentPixelFormat = texture.pixelFormat;
      descriptor.stencilAttachmentPixelFormat = texture.pixelFormat;
    } else {
      descriptor.colorAttachments[0].pixelFormat = texture.pixelFormat;
    }
    pipeline = [command_processor_.device() newRenderPipelineStateWithDescriptor:descriptor
                                                                           error:&error];
  }
  if (!pipeline) {
    REXGPU_ERROR("MetalRenderTargetCache: Failed to create a render target transfer pipeline: {}",
                 error ? [error.localizedDescription UTF8String] : "unknown error");
  }
  transfer_pipelines_.emplace(pipeline_key, pipeline);
  return pipeline;
}

void MetalRenderTargetCache::FlushPendingTransfers() {
  if (!has_pending_transfers_) {
    return;
  }
  has_pending_transfers_ = false;
  PerformTransfers(1 + xenos::kMaxColorRenderTargets, pending_transfer_render_targets_,
                   pending_transfers_);
  for (auto& transfers : pending_transfers_) {
    transfers.clear();
  }
}

void MetalRenderTargetCache::PerformPendingTransfersInRenderPass(
    id<MTLRenderCommandEncoder> encoder) {
  if (!has_pending_transfers_) {
    return;
  }
  has_pending_transfers_ = false;
  if (!transfer_no_depth_stencil_state_) {
    MTLDepthStencilDescriptor* descriptor = [[MTLDepthStencilDescriptor alloc] init];
    descriptor.depthCompareFunction = MTLCompareFunctionAlways;
    descriptor.depthWriteEnabled = NO;
    transfer_no_depth_stencil_state_ =
        [command_processor_.device() newDepthStencilStateWithDescriptor:descriptor];
  }
  for (uint32_t i = 0; i < 1 + xenos::kMaxColorRenderTargets; ++i) {
    RenderTarget* dest_rt = pending_transfer_render_targets_[i];
    std::vector<Transfer>& transfers = pending_transfers_[i];
    if (!dest_rt || transfers.empty()) {
      transfers.clear();
      continue;
    }
    auto& dest = *static_cast<MetalRenderTarget*>(dest_rt);
    RenderTargetKey dest_key = dest.key();
    id<MTLTexture> texture = dest.texture();
    [encoder setDepthStencilState:dest_key.is_depth ? transfer_depth_stencil_state_
                                                    : transfer_no_depth_stencil_state_];
    for (const Transfer& transfer : transfers) {
      if (!transfer.source || transfer.source == dest_rt) {
        continue;
      }
      auto& source = *static_cast<MetalRenderTarget*>(transfer.source);
      RenderTargetKey source_key = source.key();
      Transfer::Rectangle rectangles[Transfer::kMaxRectanglesWithCutout];
      uint32_t rectangle_count =
          transfer.GetRectangles(dest_key.base_tiles, dest_key.GetPitchTiles(),
                                 dest_key.msaa_samples, dest_key.Is64bpp(), rectangles);
      if (!rectangle_count) {
        continue;
      }
      id<MTLRenderPipelineState> pipeline = GetTransferPipeline(
          source_key, dest_key, texture, &last_update_formats_, i ? i - 1 : 0);
      if (!pipeline) {
        continue;
      }
      ++transfer_count_;
      [encoder setRenderPipelineState:pipeline];
      [encoder setFragmentTexture:source.texture() atIndex:30];
      if (source_key.is_depth) {
        [encoder setFragmentTexture:source.stencil_view() atIndex:31];
      }
      uint32_t params[4] = {dest_key.base_tiles, dest_key.GetPitchTiles(), source_key.base_tiles,
                            std::max(source_key.GetPitchTiles(), uint32_t(1))};
      [encoder setFragmentBytes:params length:sizeof(params) atIndex:30];
      MTLViewport viewport = {0.0, 0.0, double(last_update_width_), double(last_update_height_),
                              0.0, 1.0};
      [encoder setViewport:viewport];
      [encoder setCullMode:MTLCullModeNone];
      [encoder setTriangleFillMode:MTLTriangleFillModeFill];
      [encoder setDepthBias:0.0f slopeScale:0.0f clamp:0.0f];
      for (uint32_t j = 0; j < rectangle_count; ++j) {
        const Transfer::Rectangle& rectangle = rectangles[j];
        // Within the pass render area (the smallest attachment).
        NSUInteger area_width = std::min(NSUInteger(last_update_width_), texture.width);
        NSUInteger area_height = std::min(NSUInteger(last_update_height_), texture.height);
        MTLScissorRect scissor;
        scissor.x = std::min(NSUInteger(rectangle.x_pixels), area_width);
        scissor.y = std::min(NSUInteger(rectangle.y_pixels), area_height);
        scissor.width = std::min(NSUInteger(rectangle.width_pixels), area_width - scissor.x);
        scissor.height = std::min(NSUInteger(rectangle.height_pixels), area_height - scissor.y);
        if (!scissor.width || !scissor.height) {
          continue;
        }
        [encoder setScissorRect:scissor];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
      }
    }
    transfers.clear();
  }
}

void MetalRenderTargetCache::ClearRenderTarget(RenderTarget* render_target, uint64_t clear_value,
                                               const Transfer::Rectangle& rectangle) {
  auto& metal_rt = *static_cast<MetalRenderTarget*>(render_target);
  RenderTargetKey key = metal_rt.key();
  id<MTLTexture> texture = metal_rt.texture();
  float clear_values[4] = {};
  uint32_t stencil = 0;
  if (key.is_depth) {
    uint32_t depth_guest_clear_value = (uint32_t(clear_value) >> 8) & 0xFFFFFF;
    clear_values[0] = key.GetDepthFormat() == xenos::DepthRenderTargetFormat::kD24FS8
                          ? xenos::Float20e4To32(depth_guest_clear_value) * 0.5f
                          : xenos::UNorm24To32(depth_guest_clear_value);
    stencil = uint32_t(clear_value) & 0xFF;
  } else {
    switch (key.GetColorFormat()) {
      case xenos::ColorRenderTargetFormat::k_8_8_8_8:
      case xenos::ColorRenderTargetFormat::k_8_8_8_8_GAMMA:
        for (uint32_t j = 0; j < 4; ++j) {
          clear_values[j] = ((clear_value >> (j * 8)) & 0xFF) * (1.0f / 0xFF);
        }
        break;
      case xenos::ColorRenderTargetFormat::k_2_10_10_10:
      case xenos::ColorRenderTargetFormat::k_2_10_10_10_AS_10_10_10_10:
        for (uint32_t j = 0; j < 3; ++j) {
          clear_values[j] = ((clear_value >> (j * 10)) & 0x3FF) * (1.0f / 0x3FF);
        }
        clear_values[3] = ((clear_value >> 30) & 0x3) * (1.0f / 0x3);
        break;
      case xenos::ColorRenderTargetFormat::k_2_10_10_10_FLOAT:
      case xenos::ColorRenderTargetFormat::k_2_10_10_10_FLOAT_AS_16_16_16_16:
        for (uint32_t j = 0; j < 3; ++j) {
          clear_values[j] = xenos::Float7e3To32((clear_value >> (j * 10)) & 0x3FF);
        }
        clear_values[3] = ((clear_value >> 30) & 0x3) * (1.0f / 0x3);
        break;
      case xenos::ColorRenderTargetFormat::k_16_16:
      case xenos::ColorRenderTargetFormat::k_16_16_FLOAT:
      case xenos::ColorRenderTargetFormat::k_16_16_16_16:
      case xenos::ColorRenderTargetFormat::k_16_16_16_16_FLOAT: {
        uint32_t component_count =
            (key.GetColorFormat() == xenos::ColorRenderTargetFormat::k_16_16 ||
             key.GetColorFormat() == xenos::ColorRenderTargetFormat::k_16_16_FLOAT)
                ? 2
                : 4;
        for (uint32_t j = 0; j < component_count; ++j) {
          uint16_t component = uint16_t((clear_value >> (j * 16)) & 0xFFFF);
          clear_values[j] = IsColor16FormatFloatLike(key.GetColorFormat())
                                ? rex::xenos_half_to_float(component)
                                : std::max(float(int16_t(component)) * (1.0f / 32767.0f), -1.0f);
        }
      } break;
      case xenos::ColorRenderTargetFormat::k_32_FLOAT: {
        uint32_t component = uint32_t(clear_value);
        std::memcpy(&clear_values[0], &component, sizeof(component));
      } break;
      case xenos::ColorRenderTargetFormat::k_32_32_FLOAT: {
        uint32_t components[2] = {uint32_t(clear_value), uint32_t(clear_value >> 32)};
        std::memcpy(clear_values, components, sizeof(components));
      } break;
      default:
        break;
    }
  }

  uint32_t clear_pipeline_key = uint32_t(texture.pixelFormat) | (uint32_t(texture.sampleCount) << 16);
  id<MTLRenderPipelineState> pipeline = nil;
  auto pipeline_it = clear_pipelines_.find(clear_pipeline_key);
  if (pipeline_it != clear_pipelines_.end()) {
    pipeline = pipeline_it->second;
  } else {
    MTLRenderPipelineDescriptor* descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.label = @"render target clear";
    descriptor.vertexFunction = clear_vs_;
    descriptor.fragmentFunction = key.is_depth ? clear_depth_ps_ : clear_color_ps_;
    descriptor.rasterSampleCount = texture.sampleCount;
    if (key.is_depth) {
      descriptor.depthAttachmentPixelFormat = texture.pixelFormat;
      descriptor.stencilAttachmentPixelFormat = texture.pixelFormat;
    } else {
      descriptor.colorAttachments[0].pixelFormat = texture.pixelFormat;
    }
    NSError* error = nil;
    pipeline = [command_processor_.device() newRenderPipelineStateWithDescriptor:descriptor
                                                                           error:&error];
    if (!pipeline) {
      REXGPU_ERROR("MetalRenderTargetCache: Failed to create a clear pipeline: {}",
                   error ? [error.localizedDescription UTF8String] : "unknown error");
    }
    clear_pipelines_.emplace(clear_pipeline_key, pipeline);
  }
  if (!pipeline) {
    return;
  }

  MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
  if (key.is_depth) {
    pass.depthAttachment.texture = texture;
    pass.depthAttachment.loadAction = MTLLoadActionLoad;
    pass.depthAttachment.storeAction = MTLStoreActionStore;
    pass.stencilAttachment.texture = texture;
    pass.stencilAttachment.loadAction = MTLLoadActionLoad;
    pass.stencilAttachment.storeAction = MTLStoreActionStore;
  } else {
    pass.colorAttachments[0].texture = texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  }
  id<MTLRenderCommandEncoder> encoder = command_processor_.BeginUtilityRenderPass(pass, "clear");
  if (!encoder) {
    return;
  }
  encoder.label = @"clear";
  [encoder setRenderPipelineState:pipeline];
  if (key.is_depth) {
    if (!clear_depth_stencil_state_) {
      MTLDepthStencilDescriptor* ds = [[MTLDepthStencilDescriptor alloc] init];
      ds.depthCompareFunction = MTLCompareFunctionAlways;
      ds.depthWriteEnabled = YES;
      MTLStencilDescriptor* stencil_descriptor = [[MTLStencilDescriptor alloc] init];
      stencil_descriptor.stencilCompareFunction = MTLCompareFunctionAlways;
      stencil_descriptor.depthStencilPassOperation = MTLStencilOperationReplace;
      stencil_descriptor.writeMask = 0xFF;
      ds.frontFaceStencil = stencil_descriptor;
      ds.backFaceStencil = stencil_descriptor;
      clear_depth_stencil_state_ = [command_processor_.device() newDepthStencilStateWithDescriptor:ds];
    }
    [encoder setDepthStencilState:clear_depth_stencil_state_];
    [encoder setStencilReferenceValue:stencil];
  }
  uint32_t scale_x = draw_resolution_scale_x(), scale_y = draw_resolution_scale_y();
  MTLScissorRect scissor;
  scissor.x = std::min(NSUInteger(rectangle.x_pixels * scale_x), texture.width);
  scissor.y = std::min(NSUInteger(rectangle.y_pixels * scale_y), texture.height);
  scissor.width = std::min(NSUInteger(rectangle.width_pixels * scale_x), texture.width - scissor.x);
  scissor.height =
      std::min(NSUInteger(rectangle.height_pixels * scale_y), texture.height - scissor.y);
  if (!scissor.width || !scissor.height) {
    return;
  }
  [encoder setScissorRect:scissor];
  [encoder setFragmentBytes:clear_values length:sizeof(clear_values) atIndex:0];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
}

bool MetalRenderTargetCache::Resolve(const memory::Memory& memory,
                                     MetalSharedMemory& shared_memory,
                                     MetalTextureCache& texture_cache,
                                     uint32_t& written_address_out, uint32_t& written_length_out) {
  written_address_out = 0;
  written_length_out = 0;

  FlushPendingTransfers();

  draw_util::ResolveInfo resolve_info;
  if (!draw_util::GetResolveInfo(register_file(), memory, draw_resolution_scale_x(),
                                 draw_resolution_scale_y(), IsFixedRG16TruncatedToMinus1To1(),
                                 IsFixedRGBA16TruncatedToMinus1To1(), resolve_info)) {
    return false;
  }
  if (!resolve_info.coordinate_info.width_div_8 || !resolve_info.height_div_8) {
    return true;
  }

  bool copied = false;
  if (resolve_info.copy_dest_extent_length) {
    draw_util::ResolveCopyShaderConstants copy_shader_constants;
    uint32_t copy_group_count_x, copy_group_count_y;
    draw_util::ResolveCopyShaderIndex copy_shader =
        resolve_info.GetCopyShader(draw_resolution_scale_x(), draw_resolution_scale_y(),
                                   copy_shader_constants, copy_group_count_x, copy_group_count_y);
    if (copy_shader != draw_util::ResolveCopyShaderIndex::kUnknown &&
        resolve_copy_pipelines_[size_t(copy_shader)]) {
      uint32_t dump_base, dump_row_length_used, dump_rows, dump_pitch;
      resolve_info.GetCopyEdramTileSpan(dump_base, dump_row_length_used, dump_rows, dump_pitch);
      if (!DumpRenderTargets(dump_base, dump_row_length_used, dump_rows, dump_pitch)) {
        REXGPU_ERROR("MetalRenderTargetCache: Failed to dump host render targets for resolve");
        return false;
      }
      if (shared_memory.RequestRange(resolve_info.copy_dest_extent_start,
                                     resolve_info.copy_dest_extent_length)) {
        id<MTLComputeCommandEncoder> encoder = command_processor_.GetComputeEncoder("resolve");
        [encoder setComputePipelineState:resolve_copy_pipelines_[size_t(copy_shader)]];
        [encoder setBuffer:edram_buffer_ offset:0 atIndex:UtilityBuffer(0, 0)];
        // Bind the destination at its base, like the Vulkan backend, so the
        // shader's addressing is relative.
        NSUInteger dest_offset = resolve_info.copy_dest_base;
        [encoder setBuffer:shared_memory.buffer() offset:dest_offset atIndex:UtilityBuffer(1, 0)];
        copy_shader_constants.dest_base -= uint32_t(dest_offset);
        [encoder setBytes:&copy_shader_constants
                   length:sizeof(copy_shader_constants)
                  atIndex:kMslBufferPushConstants];
        [encoder dispatchThreadgroups:MTLSizeMake(copy_group_count_x, copy_group_count_y, 1)
                threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        texture_cache.MarkRangeAsResolved(resolve_info.copy_dest_extent_start,
                                          resolve_info.copy_dest_extent_length);
        command_processor_.MarkGpuWrittenInSubmission(resolve_info.copy_dest_extent_start,
                                                      resolve_info.copy_dest_extent_length);
        written_address_out = resolve_info.copy_dest_extent_start;
        written_length_out = resolve_info.copy_dest_extent_length;
        copied = true;
      }
    } else {
      REXGPU_ERROR("MetalRenderTargetCache: No resolve copy shader for this resolve");
    }
  } else {
    copied = true;
  }

  bool clear_depth = resolve_info.IsClearingDepth();
  bool clear_color = resolve_info.IsClearingColor();
  if (clear_depth || clear_color) {
    Transfer::Rectangle clear_rectangle;
    RenderTarget* clear_render_targets[2];
    if (PrepareHostRenderTargetsResolveClear(resolve_info, clear_rectangle, clear_render_targets[0],
                                             clear_transfers_[0], clear_render_targets[1],
                                             clear_transfers_[1])) {
      // The cleared rectangle doesn't need the old data.
      PerformTransfers(2, clear_render_targets, clear_transfers_, &clear_rectangle);
      if (clear_render_targets[0]) {
        ClearRenderTarget(clear_render_targets[0], resolve_info.rb_depth_clear, clear_rectangle);
      }
      if (clear_render_targets[1]) {
        ClearRenderTarget(
            clear_render_targets[1],
            resolve_info.rb_color_clear | (uint64_t(resolve_info.rb_color_clear_lo) << 32),
            clear_rectangle);
      }
    }
  }
  return copied;
}

bool MetalRenderTargetCache::DumpRenderTargets(uint32_t dump_base, uint32_t dump_row_length_used,
                                               uint32_t dump_rows, uint32_t dump_pitch) {
  GetResolveCopyRectanglesToDump(dump_base, dump_row_length_used, dump_rows, dump_pitch,
                                 dump_rectangles_);
  if (dump_rectangles_.empty()) {
    return true;
  }
  for (const ResolveCopyDumpRectangle& rectangle : dump_rectangles_) {
    static_cast<MetalRenderTarget*>(rectangle.render_target)->SetTemporarySortIndex(UINT32_MAX);
  }
  dump_invocations_.clear();
  dump_invocations_.reserve(dump_rectangles_.size());
  uint32_t rt_sort_index = 0;
  for (const ResolveCopyDumpRectangle& rectangle : dump_rectangles_) {
    auto& metal_rt = *static_cast<MetalRenderTarget*>(rectangle.render_target);
    RenderTargetKey rt_key = metal_rt.key();
    if (metal_rt.temporary_sort_index() == UINT32_MAX) {
      metal_rt.SetTemporarySortIndex(rt_sort_index++);
    }
    DumpPipelineKey pipeline_key;
    pipeline_key.msaa_samples = rt_key.msaa_samples;
    pipeline_key.resource_format = rt_key.resource_format;
    pipeline_key.is_depth = rt_key.is_depth;
    dump_invocations_.emplace_back(rectangle, pipeline_key);
  }
  std::sort(dump_invocations_.begin(), dump_invocations_.end());

  id<MTLComputeCommandEncoder> encoder = command_processor_.GetComputeEncoder("dump");
  [encoder setBuffer:edram_buffer_ offset:0 atIndex:UtilityBuffer(kDumpDescriptorSetEdram, 0)];
  bool all_pipelines_available = true;
  for (const DumpInvocation& invocation : dump_invocations_) {
    const ResolveCopyDumpRectangle& rectangle = invocation.rectangle;
    auto& metal_rt = *static_cast<MetalRenderTarget*>(rectangle.render_target);
    RenderTargetKey rt_key = metal_rt.key();
    id<MTLComputePipelineState> pipeline = GetDumpPipeline(invocation.pipeline_key);
    if (!pipeline) {
      all_pipelines_available = false;
      continue;
    }
    [encoder setComputePipelineState:pipeline];
    [encoder setTexture:metal_rt.texture() atIndex:UtilityTexture(kDumpDescriptorSetSource, 0)];
    if (rt_key.is_depth) {
      [encoder setTexture:metal_rt.stencil_view()
                  atIndex:UtilityTexture(kDumpDescriptorSetSource, 1)];
    }
    uint32_t push_constants[kDumpPushConstantCount];
    DumpPitches pitches;
    pitches.dest_pitch = dump_pitch;
    pitches.source_pitch = rt_key.GetPitchTiles();
    push_constants[kDumpPushConstantPitches] = pitches.pitches;
    DumpOffsets offsets;
    offsets.source_base_tiles = rt_key.base_tiles;
    ResolveCopyDumpRectangle::Dispatch dispatches[ResolveCopyDumpRectangle::kMaxDispatches];
    uint32_t dispatch_count = rectangle.GetDispatches(dump_pitch, dump_row_length_used, dispatches);
    for (uint32_t i = 0; i < dispatch_count; ++i) {
      const ResolveCopyDumpRectangle::Dispatch& dispatch = dispatches[i];
      offsets.dispatch_first_tile = dump_base + dispatch.offset;
      push_constants[kDumpPushConstantOffsets] = offsets.offsets;
      [encoder setBytes:push_constants length:sizeof(push_constants) atIndex:kMslBufferPushConstants];
      [encoder
           dispatchThreadgroups:
               MTLSizeMake((draw_resolution_scale_x() *
                                (xenos::kEdramTileWidthSamples >> uint32_t(rt_key.Is64bpp())) *
                                dispatch.width_tiles +
                            (kDumpSamplesPerGroupX - 1)) /
                               kDumpSamplesPerGroupX,
                           (draw_resolution_scale_y() * xenos::kEdramTileHeightSamples *
                                dispatch.height_tiles +
                            (kDumpSamplesPerGroupY - 1)) /
                               kDumpSamplesPerGroupY,
                           1)
           threadsPerThreadgroup:MTLSizeMake(kDumpSamplesPerGroupX, kDumpSamplesPerGroupY, 1)];
    }
  }
  return all_pipelines_available;
}

id<MTLComputePipelineState> MetalRenderTargetCache::GetDumpPipeline(DumpPipelineKey key) {
  auto pipeline_it = dump_pipelines_.find(key.key);
  if (pipeline_it != dump_pipelines_.end()) {
    return pipeline_it->second;
  }

  std::vector<spv::Id> id_vector_temp;

  SpirvBuilder builder(spv::Spv_1_0, (SpirvShaderTranslator::kSpirvMagicToolId << 16) | 1, nullptr);
  spv::Id ext_inst_glsl_std_450 = builder.import("GLSL.std.450");
  builder.addCapability(spv::CapabilityShader);
  builder.setMemoryModel(spv::AddressingModelLogical, spv::MemoryModelGLSL450);
  builder.setSource(spv::SourceLanguageUnknown, 0);

  spv::Id type_void = builder.makeVoidType();
  spv::Id type_int = builder.makeIntType(32);
  spv::Id type_int2 = builder.makeVectorType(type_int, 2);
  spv::Id type_uint = builder.makeUintType(32);
  spv::Id type_uint2 = builder.makeVectorType(type_uint, 2);
  spv::Id type_uint3 = builder.makeVectorType(type_uint, 3);
  spv::Id type_float = builder.makeFloatType(32);

  // Bindings.
  // EDRAM buffer.
  bool format_is_64bpp =
      !key.is_depth && xenos::IsColorRenderTargetFormat64bpp(key.GetColorFormat());
  id_vector_temp.clear();
  id_vector_temp.push_back(builder.makeRuntimeArray(format_is_64bpp ? type_uint2 : type_uint));
  // Storage buffers have std430 packing, no padding to 4-component vectors.
  builder.addDecoration(id_vector_temp.back(), spv::DecorationArrayStride,
                        sizeof(uint32_t) << uint32_t(format_is_64bpp));
  spv::Id type_edram = builder.makeStructType(id_vector_temp, "XeEdram");
  builder.addMemberName(type_edram, 0, "edram");
  builder.addMemberDecoration(type_edram, 0, spv::DecorationNonReadable);
  builder.addMemberDecoration(type_edram, 0, spv::DecorationOffset, 0);
  // Block since SPIR-V 1.3, but since SPIR-V 1.0 is generated, it's
  // BufferBlock.
  builder.addDecoration(type_edram, spv::DecorationBufferBlock);
  // StorageBuffer since SPIR-V 1.3, but since SPIR-V 1.0 is generated, it's
  // Uniform.
  spv::Id edram_buffer =
      builder.createVariable(spv::NoPrecision, spv::StorageClassUniform, type_edram, "xe_edram");
  builder.addDecoration(edram_buffer, spv::DecorationDescriptorSet, kDumpDescriptorSetEdram);
  builder.addDecoration(edram_buffer, spv::DecorationBinding, 0);
  // Color or depth source.
  bool source_is_multisampled = key.msaa_samples != xenos::MsaaSamples::k1X;
  bool source_is_uint;
  if (key.is_depth) {
    source_is_uint = false;
  } else {
    // Render targets are read in their own (non-integer) formats.
    source_is_uint = false;
  }
  spv::Id source_component_type = source_is_uint ? type_uint : type_float;
  spv::Id source_texture = builder.createVariable(
      spv::NoPrecision, spv::StorageClassUniformConstant,
      // Metal requires depth texture types for depth formats.
      builder.makeImageType(source_component_type, spv::Dim2D, bool(key.is_depth), false,
                            source_is_multisampled, 1, spv::ImageFormatUnknown),
      "xe_edram_dump_source");
  builder.addDecoration(source_texture, spv::DecorationDescriptorSet, kDumpDescriptorSetSource);
  builder.addDecoration(source_texture, spv::DecorationBinding, 0);
  // Stencil source.
  spv::Id source_stencil_texture = spv::NoResult;
  if (key.is_depth) {
    source_stencil_texture = builder.createVariable(
        spv::NoPrecision, spv::StorageClassUniformConstant,
        builder.makeImageType(type_uint, spv::Dim2D, false, false, source_is_multisampled, 1,
                              spv::ImageFormatUnknown),
        "xe_edram_dump_stencil");
    builder.addDecoration(source_stencil_texture, spv::DecorationDescriptorSet,
                          kDumpDescriptorSetSource);
    builder.addDecoration(source_stencil_texture, spv::DecorationBinding, 1);
  }
  // Push constants.
  id_vector_temp.clear();
  id_vector_temp.reserve(kDumpPushConstantCount);
  for (uint32_t i = 0; i < kDumpPushConstantCount; ++i) {
    id_vector_temp.push_back(type_uint);
  }
  spv::Id type_push_constants = builder.makeStructType(id_vector_temp, "XeEdramDumpPushConstants");
  builder.addMemberName(type_push_constants, kDumpPushConstantPitches, "pitches");
  builder.addMemberDecoration(type_push_constants, kDumpPushConstantPitches, spv::DecorationOffset,
                              int(sizeof(uint32_t) * kDumpPushConstantPitches));
  builder.addMemberName(type_push_constants, kDumpPushConstantOffsets, "offsets");
  builder.addMemberDecoration(type_push_constants, kDumpPushConstantOffsets, spv::DecorationOffset,
                              int(sizeof(uint32_t) * kDumpPushConstantOffsets));
  builder.addDecoration(type_push_constants, spv::DecorationBlock);
  spv::Id push_constants =
      builder.createVariable(spv::NoPrecision, spv::StorageClassPushConstant, type_push_constants,
                             "xe_edram_dump_push_constants");

  // gl_GlobalInvocationID input.
  spv::Id input_global_invocation_id = builder.createVariable(
      spv::NoPrecision, spv::StorageClassInput, type_uint3, "gl_GlobalInvocationID");
  builder.addDecoration(input_global_invocation_id, spv::DecorationBuiltIn,
                        spv::BuiltInGlobalInvocationId);

  // Begin the main function.
  std::vector<spv::Id> main_param_types;
  std::vector<std::vector<spv::Decoration>> main_precisions;
  spv::Block* main_entry;
  spv::Function* main_function = builder.makeFunctionEntry(
      spv::NoPrecision, type_void, "main", main_param_types, main_precisions, &main_entry);

  // For now, as the exact addressing in 64bpp render targets relatively to
  // 32bpp is unknown, treating 64bpp tiles as storing 40x16 samples rather than
  // 80x16 for simplicity of addressing into the texture.

  // Split the destination sample index into the 32bpp tile and the
  // 32bpp-tile-relative sample index.
  // Note that division by non-power-of-two constants will include a 4-cycle
  // 32*32 multiplication on AMD, even though so many bits are not needed for
  // the sample position - however, if an OpUnreachable path is inserted for the
  // case when the position has upper bits set, for some reason, the code for it
  // is not eliminated when compiling the shader for AMD via RenderDoc on
  // Windows, as of June 2022.
  spv::Id global_invocation_id = builder.createLoad(input_global_invocation_id, spv::NoPrecision);
  spv::Id rectangle_sample_x = builder.createCompositeExtract(global_invocation_id, type_uint, 0);
  uint32_t tile_width =
      (xenos::kEdramTileWidthSamples >> uint32_t(format_is_64bpp)) * draw_resolution_scale_x();
  spv::Id const_tile_width = builder.makeUintConstant(tile_width);
  spv::Id rectangle_tile_index_x =
      builder.createBinOp(spv::OpUDiv, type_uint, rectangle_sample_x, const_tile_width);
  spv::Id tile_sample_x =
      builder.createBinOp(spv::OpUMod, type_uint, rectangle_sample_x, const_tile_width);
  spv::Id rectangle_sample_y = builder.createCompositeExtract(global_invocation_id, type_uint, 1);
  uint32_t tile_height = xenos::kEdramTileHeightSamples * draw_resolution_scale_y();
  spv::Id const_tile_height = builder.makeUintConstant(tile_height);
  spv::Id rectangle_tile_index_y =
      builder.createBinOp(spv::OpUDiv, type_uint, rectangle_sample_y, const_tile_height);
  spv::Id tile_sample_y =
      builder.createBinOp(spv::OpUMod, type_uint, rectangle_sample_y, const_tile_height);

  // Get the tile index in the EDRAM relative to the dump rectangle base tile.
  id_vector_temp.clear();
  id_vector_temp.push_back(builder.makeIntConstant(kDumpPushConstantPitches));
  spv::Id pitches_constant = builder.createLoad(
      builder.createAccessChain(spv::StorageClassPushConstant, push_constants, id_vector_temp),
      spv::NoPrecision);
  spv::Id const_uint_0 = builder.makeUintConstant(0);
  spv::Id const_edram_pitch_tiles_bits = builder.makeUintConstant(xenos::kEdramPitchTilesBits);
  spv::Id rectangle_tile_index = builder.createBinOp(
      spv::OpIAdd, type_uint,
      builder.createBinOp(spv::OpIMul, type_uint,
                          builder.createTriOp(spv::OpBitFieldUExtract, type_uint, pitches_constant,
                                              const_uint_0, const_edram_pitch_tiles_bits),
                          rectangle_tile_index_y),
      rectangle_tile_index_x);
  // Add the base tile in the dispatch to the dispatch-local tile index, not
  // wrapping yet so in case of a wraparound, the address relative to the base
  // in the image after subtraction of the base won't be negative.
  id_vector_temp.clear();
  id_vector_temp.push_back(builder.makeIntConstant(kDumpPushConstantOffsets));
  spv::Id offsets_constant = builder.createLoad(
      builder.createAccessChain(spv::StorageClassPushConstant, push_constants, id_vector_temp),
      spv::NoPrecision);
  spv::Id const_edram_base_tiles_bits_plus_1 =
      builder.makeUintConstant(xenos::kEdramBaseTilesBits + 1);
  spv::Id edram_tile_index_non_wrapped =
      builder.createBinOp(spv::OpIAdd, type_uint,
                          builder.createTriOp(spv::OpBitFieldUExtract, type_uint, offsets_constant,
                                              const_uint_0, const_edram_base_tiles_bits_plus_1),
                          rectangle_tile_index);

  // Combine the tile sample index and the tile index, wrapping the tile
  // addressing, into the EDRAM sample index.
  spv::Id edram_sample_address = builder.createBinOp(
      spv::OpIAdd, type_uint,
      builder.createBinOp(
          spv::OpIMul, type_uint, builder.makeUintConstant(tile_width * tile_height),
          builder.createBinOp(spv::OpBitwiseAnd, type_uint, edram_tile_index_non_wrapped,
                              builder.makeUintConstant(xenos::kEdramTileCount - 1))),
      builder.createBinOp(
          spv::OpIAdd, type_uint,
          builder.createBinOp(spv::OpIMul, type_uint, const_tile_width, tile_sample_y),
          tile_sample_x));
  if (key.is_depth) {
    // Swap 40-sample columns in the depth buffer in the destination address to
    // get the final address of the sample in the EDRAM.
    uint32_t tile_width_half = tile_width >> 1;
    edram_sample_address = builder.createUnaryOp(
        spv::OpBitcast, type_uint,
        builder.createBinOp(
            spv::OpIAdd, type_int,
            builder.createUnaryOp(spv::OpBitcast, type_int, edram_sample_address),
            builder.createTriOp(
                spv::OpSelect, type_int,
                builder.createBinOp(spv::OpULessThan, builder.makeBoolType(), tile_sample_x,
                                    builder.makeUintConstant(tile_width_half)),
                builder.makeIntConstant(int32_t(tile_width_half)),
                builder.makeIntConstant(-int32_t(tile_width_half)))));
  }

  // Get the linear tile index within the source texture.
  spv::Id source_tile_index = builder.createBinOp(
      spv::OpISub, type_uint, edram_tile_index_non_wrapped,
      builder.createTriOp(spv::OpBitFieldUExtract, type_uint, offsets_constant,
                          const_edram_base_tiles_bits_plus_1,
                          builder.makeUintConstant(xenos::kEdramBaseTilesBits)));
  // Split the linear tile index in the source texture into X and Y in tiles.
  spv::Id source_pitch_tiles =
      builder.createTriOp(spv::OpBitFieldUExtract, type_uint, pitches_constant,
                          const_edram_pitch_tiles_bits, const_edram_pitch_tiles_bits);
  spv::Id source_tile_index_y =
      builder.createBinOp(spv::OpUDiv, type_uint, source_tile_index, source_pitch_tiles);
  spv::Id source_tile_index_x =
      builder.createBinOp(spv::OpUMod, type_uint, source_tile_index, source_pitch_tiles);
  // Combine the source tile offset and the sample index within the tile.
  spv::Id source_sample_x = builder.createBinOp(
      spv::OpIAdd, type_uint,
      builder.createBinOp(spv::OpIMul, type_uint, const_tile_width, source_tile_index_x),
      tile_sample_x);
  spv::Id source_sample_y = builder.createBinOp(
      spv::OpIAdd, type_uint,
      builder.createBinOp(spv::OpIMul, type_uint, const_tile_height, source_tile_index_y),
      tile_sample_y);
  // Get the source pixel coordinate and the sample index within the pixel.
  spv::Id source_pixel_x = source_sample_x, source_pixel_y = source_sample_y;
  spv::Id source_sample_id = spv::NoResult;
  if (source_is_multisampled) {
    spv::Id const_uint_1 = builder.makeUintConstant(1);
    source_pixel_y =
        builder.createBinOp(spv::OpShiftRightLogical, type_uint, source_sample_y, const_uint_1);
    if (key.msaa_samples >= xenos::MsaaSamples::k4X) {
      source_pixel_x =
          builder.createBinOp(spv::OpShiftRightLogical, type_uint, source_sample_x, const_uint_1);
      // 4x MSAA source texture sample index - bit 0 for horizontal, bit 1 for
      // vertical.
      source_sample_id = builder.createQuadOp(
          spv::OpBitFieldInsert, type_uint,
          builder.createBinOp(spv::OpBitwiseAnd, type_uint, source_sample_x, const_uint_1),
          source_sample_y, const_uint_1, const_uint_1);
    } else {
      // 2x MSAA source texture sample index - convert from the guest to
      // the Vulkan standard sample locations.
      source_sample_id = builder.createTriOp(
          spv::OpSelect, type_uint,
          builder.createBinOp(
              spv::OpINotEqual, builder.makeBoolType(),
              builder.createBinOp(spv::OpBitwiseAnd, type_uint, source_sample_y, const_uint_1),
              const_uint_0),
          builder.makeUintConstant(
              draw_util::GetD3D10SampleIndexForGuest2xMSAA(1, true)),
          builder.makeUintConstant(
              draw_util::GetD3D10SampleIndexForGuest2xMSAA(0, true)));
    }
  }

  // Load the source, and pack the value into one or two 32-bit integers.
  spv::Id packed[2] = {};
  spv::Builder::TextureParameters source_texture_parameters = {};
  source_texture_parameters.sampler = builder.createLoad(source_texture, spv::NoPrecision);
  id_vector_temp.clear();
  id_vector_temp.push_back(builder.createUnaryOp(spv::OpBitcast, type_int, source_pixel_x));
  id_vector_temp.push_back(builder.createUnaryOp(spv::OpBitcast, type_int, source_pixel_y));
  source_texture_parameters.coords = builder.createCompositeConstruct(type_int2, id_vector_temp);
  if (source_is_multisampled) {
    source_texture_parameters.sample =
        builder.createUnaryOp(spv::OpBitcast, type_int, source_sample_id);
  } else {
    source_texture_parameters.lod = builder.makeIntConstant(0);
  }
  spv::Id source_vec4 = builder.createTextureCall(
      spv::NoPrecision, builder.makeVectorType(source_component_type, 4), false, true, false, false,
      false, source_texture_parameters, spv::ImageOperandsMaskNone);
  const bool source_color_16_is_float =
      !key.is_depth && IsColor16FormatFloatLike(key.GetColorFormat());
  spv::Id const_uint_16 = builder.makeUintConstant(16);
  spv::Id const_float_0 = builder.makeFloatConstant(0.0f);
  spv::Id const_float_1 = builder.makeFloatConstant(1.0f);
  spv::Id const_float_minus_1 = builder.makeFloatConstant(-1.0f);
  spv::Id const_float_32767 = builder.makeFloatConstant(32767.0f);
  auto LinearToPWLGamma = [&](spv::Id linear, bool linear_pre_saturated) -> spv::Id {
    if (!linear_pre_saturated) {
      linear = builder.createTriBuiltinCall(type_float, ext_inst_glsl_std_450, GLSLstd450NClamp,
                                            linear, const_float_0, const_float_1);
    }
    spv::Id is_piece_at_least_3 =
        builder.createBinOp(spv::OpFOrdGreaterThanEqual, builder.makeBoolType(), linear,
                            builder.makeFloatConstant(512.0f / 1023.0f));
    spv::Id scale_3_or_2 = builder.createTriOp(spv::OpSelect, type_float, is_piece_at_least_3,
                                               builder.makeFloatConstant(1023.0f / 8.0f),
                                               builder.makeFloatConstant(1023.0f / 4.0f));
    spv::Id offset_3_or_2 = builder.createTriOp(spv::OpSelect, type_float, is_piece_at_least_3,
                                                builder.makeFloatConstant(128.0f / 255.0f),
                                                builder.makeFloatConstant(64.0f / 255.0f));
    spv::Id is_piece_at_least_1 =
        builder.createBinOp(spv::OpFOrdGreaterThanEqual, builder.makeBoolType(), linear,
                            builder.makeFloatConstant(64.0f / 1023.0f));
    spv::Id scale_1_or_0 = builder.createTriOp(spv::OpSelect, type_float, is_piece_at_least_1,
                                               builder.makeFloatConstant(1023.0f / 2.0f),
                                               builder.makeFloatConstant(1023.0f));
    spv::Id offset_1_or_0 =
        builder.createTriOp(spv::OpSelect, type_float, is_piece_at_least_1,
                            builder.makeFloatConstant(32.0f / 255.0f), const_float_0);
    spv::Id is_piece_at_least_2 =
        builder.createBinOp(spv::OpFOrdGreaterThanEqual, builder.makeBoolType(), linear,
                            builder.makeFloatConstant(128.0f / 1023.0f));
    spv::Id scale = builder.createTriOp(spv::OpSelect, type_float, is_piece_at_least_2,
                                        scale_3_or_2, scale_1_or_0);
    spv::Id offset = builder.createTriOp(spv::OpSelect, type_float, is_piece_at_least_2,
                                         offset_3_or_2, offset_1_or_0);
    return builder.createBinOp(
        spv::OpFAdd, type_float,
        builder.createBinOp(spv::OpFMul, type_float,
                            builder.createUnaryBuiltinCall(
                                type_float, ext_inst_glsl_std_450, GLSLstd450Trunc,
                                builder.createBinOp(spv::OpFMul, type_float, linear, scale)),
                            builder.makeFloatConstant(1.0f / 255.0f)),
        offset);
  };
  auto PackDumpSource16ComponentToUint = [&](spv::Id component) -> spv::Id {
    if (source_is_uint) {
      return component;
    }
    if (source_color_16_is_float) {
      id_vector_temp.clear();
      id_vector_temp.push_back(component);
      id_vector_temp.push_back(const_float_0);
      spv::Id packed_half = builder.createUnaryBuiltinCall(
          type_uint, ext_inst_glsl_std_450, GLSLstd450PackHalf2x16,
          builder.createCompositeConstruct(builder.makeVectorType(type_float, 2), id_vector_temp));
      return builder.createTriOp(spv::OpBitFieldUExtract, type_uint, packed_half, const_uint_0,
                                 const_uint_16);
    }
    spv::Id component_clamped =
        builder.createTriBuiltinCall(type_float, ext_inst_glsl_std_450, GLSLstd450NClamp, component,
                                     const_float_minus_1, const_float_1);
    spv::Id component_rounded = builder.createUnaryBuiltinCall(
        type_float, ext_inst_glsl_std_450, GLSLstd450RoundEven,
        builder.createBinOp(spv::OpFMul, type_float, component_clamped, const_float_32767));
    spv::Id component_snorm =
        builder.createUnaryOp(spv::OpConvertFToS, type_int, component_rounded);
    return builder.createTriOp(spv::OpBitFieldUExtract, type_uint,
                               builder.createUnaryOp(spv::OpBitcast, type_uint, component_snorm),
                               const_uint_0, const_uint_16);
  };
  auto PackDumpSource16PairToUint32 = [&](spv::Id component_0, spv::Id component_1) -> spv::Id {
    return builder.createQuadOp(
        spv::OpBitFieldInsert, type_uint, PackDumpSource16ComponentToUint(component_0),
        PackDumpSource16ComponentToUint(component_1), const_uint_16, const_uint_16);
  };
  if (key.is_depth) {
    source_texture_parameters.sampler =
        builder.createLoad(source_stencil_texture, spv::NoPrecision);
    spv::Id source_stencil = builder.createCompositeExtract(
        builder.createTextureCall(spv::NoPrecision, builder.makeVectorType(type_uint, 4), false,
                                  true, false, false, false, source_texture_parameters,
                                  spv::ImageOperandsMaskNone),
        type_uint, 0);
    spv::Id source_depth32 = builder.createCompositeExtract(source_vec4, type_float, 0);
    switch (key.GetDepthFormat()) {
      case xenos::DepthRenderTargetFormat::kD24S8: {
        // Round to the nearest even integer. This seems to be the correct
        // conversion, adding +0.5 and rounding towards zero results in red
        // instead of black in the 4D5307E6 clear shader.
        packed[0] = builder.createUnaryOp(
            spv::OpConvertFToU, type_uint,
            builder.createUnaryBuiltinCall(
                type_float, ext_inst_glsl_std_450, GLSLstd450RoundEven,
                builder.createBinOp(spv::OpFMul, type_float, source_depth32,
                                    builder.makeFloatConstant(float(0xFFFFFF)))));
      } break;
      case xenos::DepthRenderTargetFormat::kD24FS8: {
        packed[0] = SpirvShaderTranslator::PreClampedDepthTo20e4(
            builder, source_depth32, depth_float24_round(), true, ext_inst_glsl_std_450);
      } break;
    }
    packed[0] = builder.createQuadOp(spv::OpBitFieldInsert, type_uint, source_stencil, packed[0],
                                     builder.makeUintConstant(8), builder.makeUintConstant(24));
  } else {
    switch (key.GetColorFormat()) {
      case xenos::ColorRenderTargetFormat::k_8_8_8_8_GAMMA: {
        if (false) {
          // 8_8_8_8_GAMMA is represented by linear stored in
          // R16G16B16A16_UNORM.
          id_vector_temp.clear();
          for (uint32_t i = 0; i < 3; ++i) {
            id_vector_temp.push_back(
                LinearToPWLGamma(builder.createCompositeExtract(source_vec4, type_float, i), true));
          }
        }
      }
        [[fallthrough]];
      case xenos::ColorRenderTargetFormat::k_8_8_8_8: {
        spv::Id unorm_round_offset = builder.makeFloatConstant(0.5f);
        spv::Id unorm_scale = builder.makeFloatConstant(255.0f);
        spv::Id color_0 = builder.createCompositeExtract(source_vec4, type_float, 0);
        if (key.GetColorFormat() == xenos::ColorRenderTargetFormat::k_8_8_8_8_GAMMA &&
            false) {
          color_0 = id_vector_temp[0];
        }
        packed[0] = builder.createUnaryOp(
            spv::OpConvertFToU, type_uint,
            builder.createBinOp(spv::OpFAdd, type_float,
                                builder.createBinOp(spv::OpFMul, type_float, color_0, unorm_scale),
                                unorm_round_offset));
        spv::Id component_width = builder.makeUintConstant(8);
        for (uint32_t i = 1; i < 4; ++i) {
          spv::Id color_i = builder.createCompositeExtract(source_vec4, type_float, i);
          if (key.GetColorFormat() == xenos::ColorRenderTargetFormat::k_8_8_8_8_GAMMA &&
              false && i < 3) {
            color_i = id_vector_temp[i];
          }
          packed[0] = builder.createQuadOp(
              spv::OpBitFieldInsert, type_uint, packed[0],
              builder.createUnaryOp(spv::OpConvertFToU, type_uint,
                                    builder.createBinOp(spv::OpFAdd, type_float,
                                                        builder.createBinOp(spv::OpFMul, type_float,
                                                                            color_i, unorm_scale),
                                                        unorm_round_offset)),
              builder.makeUintConstant(8 * i), component_width);
        }
      } break;
      case xenos::ColorRenderTargetFormat::k_2_10_10_10:
      case xenos::ColorRenderTargetFormat::k_2_10_10_10_AS_10_10_10_10: {
        spv::Id unorm_round_offset = builder.makeFloatConstant(0.5f);
        spv::Id unorm_scale_rgb = builder.makeFloatConstant(1023.0f);
        packed[0] = builder.createUnaryOp(
            spv::OpConvertFToU, type_uint,
            builder.createBinOp(
                spv::OpFAdd, type_float,
                builder.createBinOp(spv::OpFMul, type_float,
                                    builder.createCompositeExtract(source_vec4, type_float, 0),
                                    unorm_scale_rgb),
                unorm_round_offset));
        spv::Id width_rgb = builder.makeUintConstant(10);
        spv::Id unorm_scale_a = builder.makeFloatConstant(3.0f);
        spv::Id width_a = builder.makeUintConstant(2);
        for (uint32_t i = 1; i < 4; ++i) {
          packed[0] = builder.createQuadOp(
              spv::OpBitFieldInsert, type_uint, packed[0],
              builder.createUnaryOp(
                  spv::OpConvertFToU, type_uint,
                  builder.createBinOp(spv::OpFAdd, type_float,
                                      builder.createBinOp(spv::OpFMul, type_float,
                                                          builder.createCompositeExtract(
                                                              source_vec4, type_float, i),
                                                          i == 3 ? unorm_scale_a : unorm_scale_rgb),
                                      unorm_round_offset)),
              builder.makeUintConstant(10 * i), i == 3 ? width_a : width_rgb);
        }
      } break;
      case xenos::ColorRenderTargetFormat::k_2_10_10_10_FLOAT:
      case xenos::ColorRenderTargetFormat::k_2_10_10_10_FLOAT_AS_16_16_16_16: {
        // Float16 has a wider range for both color and alpha, also NaNs - clamp
        // and convert.
        packed[0] = SpirvShaderTranslator::UnclampedFloat32To7e3(
            builder, builder.createCompositeExtract(source_vec4, type_float, 0),
            ext_inst_glsl_std_450);
        spv::Id width_rgb = builder.makeUintConstant(10);
        for (uint32_t i = 1; i < 3; ++i) {
          packed[0] = builder.createQuadOp(
              spv::OpBitFieldInsert, type_uint, packed[0],
              SpirvShaderTranslator::UnclampedFloat32To7e3(
                  builder, builder.createCompositeExtract(source_vec4, type_float, i),
                  ext_inst_glsl_std_450),
              builder.makeUintConstant(10 * i), width_rgb);
        }
        // Saturate and convert the alpha.
        spv::Id alpha_saturated = builder.createTriBuiltinCall(
            type_float, ext_inst_glsl_std_450, GLSLstd450NClamp,
            builder.createCompositeExtract(source_vec4, type_float, 3),
            builder.makeFloatConstant(0.0f), builder.makeFloatConstant(1.0f));
        packed[0] = builder.createQuadOp(
            spv::OpBitFieldInsert, type_uint, packed[0],
            builder.createUnaryOp(
                spv::OpConvertFToU, type_uint,
                builder.createBinOp(spv::OpFAdd, type_float,
                                    builder.createBinOp(spv::OpFMul, type_float, alpha_saturated,
                                                        builder.makeFloatConstant(3.0f)),
                                    builder.makeFloatConstant(0.5f))),
            builder.makeUintConstant(30), builder.makeUintConstant(2));
      } break;
      case xenos::ColorRenderTargetFormat::k_16_16:
      case xenos::ColorRenderTargetFormat::k_16_16_16_16:
      case xenos::ColorRenderTargetFormat::k_16_16_FLOAT:
      case xenos::ColorRenderTargetFormat::k_16_16_16_16_FLOAT: {
        for (uint32_t i = 0; i <= uint32_t(format_is_64bpp); ++i) {
          packed[i] = PackDumpSource16PairToUint32(
              builder.createCompositeExtract(source_vec4, source_component_type, 2 * i),
              builder.createCompositeExtract(source_vec4, source_component_type, 2 * i + 1));
        }
      } break;
      // Float32 is transferred as uint32 to preserve NaN encodings. However,
      // multisampled sampled image support is optional in Vulkan.
      case xenos::ColorRenderTargetFormat::k_32_FLOAT:
      case xenos::ColorRenderTargetFormat::k_32_32_FLOAT: {
        for (uint32_t i = 0; i <= uint32_t(format_is_64bpp); ++i) {
          spv::Id& packed_ref = packed[i];
          packed_ref = builder.createCompositeExtract(source_vec4, source_component_type, i);
          if (!source_is_uint) {
            packed_ref = builder.createUnaryOp(spv::OpBitcast, type_uint, packed_ref);
          }
        }
      } break;
    }
  }

  // Write the packed value to the EDRAM buffer.
  spv::Id store_value = packed[0];
  if (format_is_64bpp) {
    id_vector_temp.clear();
    id_vector_temp.push_back(packed[0]);
    id_vector_temp.push_back(packed[1]);
    store_value = builder.createCompositeConstruct(type_uint2, id_vector_temp);
  }
  id_vector_temp.clear();
  // The only SSBO structure member.
  id_vector_temp.push_back(builder.makeIntConstant(0));
  id_vector_temp.push_back(builder.createUnaryOp(spv::OpBitcast, type_int, edram_sample_address));
  // StorageBuffer since SPIR-V 1.3, but since SPIR-V 1.0 is generated, it's
  // Uniform.
  builder.createStore(store_value, builder.createAccessChain(spv::StorageClassUniform, edram_buffer,
                                                             id_vector_temp));

  // End the main function and make it the entry point.
  builder.leaveFunction();
  builder.addExecutionMode(main_function, spv::ExecutionModeLocalSize, kDumpSamplesPerGroupX,
                           kDumpSamplesPerGroupY, 1);
  spv::Instruction* entry_point =
      builder.addEntryPoint(spv::ExecutionModelGLCompute, main_function, "main");
  // Bindings only need to be added to the entry point's interface starting with
  // SPIR-V 1.4 - emitting 1.0 here, so only inputs / outputs.
  entry_point->addIdOperand(input_global_invocation_id);

  // Serialize the shader code.
  std::vector<unsigned int> shader_code;
  builder.dump(shader_code);

  id<MTLFunction> function = command_processor_.CompileUtilitySpirv(
      reinterpret_cast<const uint32_t*>(shader_code.data()), shader_code.size(), "EDRAM dump");
  id<MTLComputePipelineState> pipeline = nil;
  if (function) {
    NSError* error = nil;
    pipeline = [command_processor_.device() newComputePipelineStateWithFunction:function
                                                                          error:&error];
    if (!pipeline) {
      REXGPU_ERROR("MetalRenderTargetCache: Failed to create a dump pipeline: {}",
                   error ? [error.localizedDescription UTF8String] : "unknown error");
    }
  }
  if (!pipeline) {
    REXGPU_ERROR(
        "MetalRenderTargetCache: Failed to create a render target dumping pipeline for "
        "{}-sample render targets with format {}",
        UINT32_C(1) << uint32_t(key.msaa_samples),
        key.is_depth ? xenos::GetDepthRenderTargetFormatName(key.GetDepthFormat())
                     : xenos::GetColorRenderTargetFormatName(key.GetColorFormat()));
  }
  dump_pipelines_.emplace(key.key, pipeline);
  return pipeline;
}

}  // namespace rex::graphics::metal
