/**
 * @file        graphics/metal/texture_cache.mm
 * @brief       Guest texture cache for the Metal backend
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */

#include <rex/graphics/metal/texture_cache.h>

#include <algorithm>

#include <rex/cvar.h>
#include <rex/graphics/flags.h>
#include <rex/graphics/metal/command_processor.h>
#include <rex/graphics/metal/msl_util.h>
#include <rex/graphics/pipeline/texture/info.h>
#include <rex/graphics/pipeline/texture/util.h>
#include <rex/logging.h>

namespace rex::graphics::metal {

namespace shaders {
#include "../shaders/vulkan_spirv/texture_load_128bpb_cs.h"
#include "../shaders/vulkan_spirv/texture_load_16bpb_cs.h"
#include "../shaders/vulkan_spirv/texture_load_32bpb_cs.h"
#include "../shaders/vulkan_spirv/texture_load_64bpb_cs.h"
#include "../shaders/vulkan_spirv/texture_load_8bpb_cs.h"
#include "../shaders/vulkan_spirv/texture_load_bgrg8_rgb8_cs.h"
#include "../shaders/vulkan_spirv/texture_load_ctx1_cs.h"
#include "../shaders/vulkan_spirv/texture_load_depth_float_cs.h"
#include "../shaders/vulkan_spirv/texture_load_depth_unorm_cs.h"
#include "../shaders/vulkan_spirv/texture_load_dxn_rg8_cs.h"
#include "../shaders/vulkan_spirv/texture_load_dxt1_rgba8_cs.h"
#include "../shaders/vulkan_spirv/texture_load_dxt3_rgba8_cs.h"
#include "../shaders/vulkan_spirv/texture_load_dxt3a_cs.h"
#include "../shaders/vulkan_spirv/texture_load_dxt5_rgba8_cs.h"
#include "../shaders/vulkan_spirv/texture_load_dxt5a_r8_cs.h"
#include "../shaders/vulkan_spirv/texture_load_gbgr8_rgb8_cs.h"
#include "../shaders/vulkan_spirv/texture_load_r10g11b11_rgba16_cs.h"
#include "../shaders/vulkan_spirv/texture_load_r11g11b10_rgba16_cs.h"
#include "../shaders/vulkan_spirv/texture_load_r4g4b4a4_rgba8_cs.h"
#include "../shaders/vulkan_spirv/texture_load_r5g6b5_rgba8_cs.h"
}  // namespace shaders

namespace {
// Utility shader argument table indices (see msl_util.h): set S binding B is
// buffer kMslBufferUtilityFirst + 4 * S + B.
constexpr uint32_t kLoadBufferDestination = kMslBufferUtilityFirst + 4 * 0 + 0;
constexpr uint32_t kLoadBufferSource = kMslBufferUtilityFirst + 4 * 1 + 0;

MTLTextureSwizzle ToMetalSwizzle(uint32_t component) {
  switch (component) {
    case 0:
      return MTLTextureSwizzleRed;
    case 1:
      return MTLTextureSwizzleGreen;
    case 2:
      return MTLTextureSwizzleBlue;
    case 3:
      return MTLTextureSwizzleAlpha;
    case 4:
      return MTLTextureSwizzleZero;
    default:
      return MTLTextureSwizzleOne;
  }
}
}  // namespace

std::unique_ptr<MetalTextureCache> MetalTextureCache::Create(
    const RegisterFile& register_file, MetalSharedMemory& shared_memory,
    MetalCommandProcessor& command_processor) {
  std::unique_ptr<MetalTextureCache> texture_cache(
      new MetalTextureCache(register_file, shared_memory, command_processor));
  if (!texture_cache->Initialize()) {
    return nullptr;
  }
  return texture_cache;
}

MetalTextureCache::~MetalTextureCache() {
  DestroyAllTextures(true);
}

bool MetalTextureCache::Initialize() {
  id<MTLDevice> device = command_processor_.device();
  auto make_null = [&](MTLTextureType type) -> id<MTLTexture> {
    MTLTextureDescriptor* descriptor = [[MTLTextureDescriptor alloc] init];
    descriptor.textureType = type;
    descriptor.pixelFormat = MTLPixelFormatRGBA8Unorm;
    descriptor.width = 1;
    descriptor.height = 1;
    descriptor.depth = 1;
    descriptor.arrayLength = 1;
    descriptor.usage = MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    if (texture) {
      const uint32_t zero[6] = {};
      for (uint32_t slice = 0; slice < (type == MTLTextureTypeCube ? 6 : 1); ++slice) {
        [texture replaceRegion:MTLRegionMake3D(0, 0, 0, 1, 1, 1)
                   mipmapLevel:0
                         slice:slice
                     withBytes:zero
                   bytesPerRow:4
                 bytesPerImage:4];
      }
    }
    return texture;
  };
  null_texture_2d_array_ = make_null(MTLTextureType2DArray);
  null_texture_3d_ = make_null(MTLTextureType3D);
  null_texture_cube_ = make_null(MTLTextureTypeCube);

  std::pair<const uint32_t*, size_t> load_shader_code[kLoadShaderCount] = {};
#define REX_METAL_LOAD_SHADER(index, name) \
  load_shader_code[index] = std::make_pair(shaders::name, sizeof(shaders::name))
  REX_METAL_LOAD_SHADER(kLoadShaderIndex8bpb, texture_load_8bpb_cs);
  REX_METAL_LOAD_SHADER(kLoadShaderIndex16bpb, texture_load_16bpb_cs);
  REX_METAL_LOAD_SHADER(kLoadShaderIndex32bpb, texture_load_32bpb_cs);
  REX_METAL_LOAD_SHADER(kLoadShaderIndex64bpb, texture_load_64bpb_cs);
  REX_METAL_LOAD_SHADER(kLoadShaderIndex128bpb, texture_load_128bpb_cs);
  REX_METAL_LOAD_SHADER(kLoadShaderIndexR5G6B5ToRGBA8, texture_load_r5g6b5_rgba8_cs);
  REX_METAL_LOAD_SHADER(kLoadShaderIndexRGBA4ToRGBA8, texture_load_r4g4b4a4_rgba8_cs);
  REX_METAL_LOAD_SHADER(kLoadShaderIndexGBGR8ToRGB8, texture_load_gbgr8_rgb8_cs);
  REX_METAL_LOAD_SHADER(kLoadShaderIndexBGRG8ToRGB8, texture_load_bgrg8_rgb8_cs);
  REX_METAL_LOAD_SHADER(kLoadShaderIndexR10G11B11ToRGBA16, texture_load_r10g11b11_rgba16_cs);
  REX_METAL_LOAD_SHADER(kLoadShaderIndexR11G11B10ToRGBA16, texture_load_r11g11b10_rgba16_cs);
  REX_METAL_LOAD_SHADER(kLoadShaderIndexDXT1ToRGBA8, texture_load_dxt1_rgba8_cs);
  REX_METAL_LOAD_SHADER(kLoadShaderIndexDXT3ToRGBA8, texture_load_dxt3_rgba8_cs);
  REX_METAL_LOAD_SHADER(kLoadShaderIndexDXT5ToRGBA8, texture_load_dxt5_rgba8_cs);
  REX_METAL_LOAD_SHADER(kLoadShaderIndexDXNToRG8, texture_load_dxn_rg8_cs);
  REX_METAL_LOAD_SHADER(kLoadShaderIndexDXT3A, texture_load_dxt3a_cs);
  REX_METAL_LOAD_SHADER(kLoadShaderIndexDXT5AToR8, texture_load_dxt5a_r8_cs);
  REX_METAL_LOAD_SHADER(kLoadShaderIndexCTX1, texture_load_ctx1_cs);
  REX_METAL_LOAD_SHADER(kLoadShaderIndexDepthUnorm, texture_load_depth_unorm_cs);
  REX_METAL_LOAD_SHADER(kLoadShaderIndexDepthFloat, texture_load_depth_float_cs);
#undef REX_METAL_LOAD_SHADER
  for (uint32_t i = 0; i < kLoadShaderCount; ++i) {
    if (!load_shader_code[i].first) {
      continue;
    }
    id<MTLFunction> function = command_processor_.CompileUtilitySpirv(
        load_shader_code[i].first, load_shader_code[i].second / sizeof(uint32_t), "texture load");
    if (!function) {
      continue;
    }
    NSError* error = nil;
    load_pipelines_[i] = [device newComputePipelineStateWithFunction:function error:&error];
    if (!load_pipelines_[i]) {
      REXGPU_ERROR("MetalTextureCache: Failed to create texture load pipeline {}: {}", i,
                   error ? [error.localizedDescription UTF8String] : "unknown error");
    }
  }
  return null_texture_2d_array_ && null_texture_3d_ && null_texture_cube_;
}

id<MTLTexture> MetalTextureCache::GetActiveTextureOrNull(uint32_t fetch_constant_index,
                                                         xenos::FetchOpDimension dimension,
                                                         bool is_signed) {
  const TextureBinding* binding = GetValidTextureBinding(fetch_constant_index);
  if (binding && binding->texture) {
    auto* texture = static_cast<MetalTexture*>(binding->texture);
    MTLTextureType type = texture->texture().textureType;
    bool type_matches;
    switch (dimension) {
      case xenos::FetchOpDimension::k3DOrStacked:
        type_matches = type == MTLTextureType3D;
        break;
      case xenos::FetchOpDimension::kCube:
        type_matches = type == MTLTextureTypeCube;
        break;
      default:
        type_matches = type == MTLTextureType2DArray;
        break;
    }
    if (type_matches) {
      id<MTLTexture> view = texture->GetView(is_signed, binding->host_swizzle);
      if (view) {
        return view;
      }
    }
  }
  switch (dimension) {
    case xenos::FetchOpDimension::k3DOrStacked:
      return null_texture_3d_;
    case xenos::FetchOpDimension::kCube:
      return null_texture_cube_;
    default:
      return null_texture_2d_array_;
  }
}

MetalTextureCache::SamplerParameters MetalTextureCache::GetSamplerParameters(
    const MetalShader::SamplerBinding& binding) const {
  const auto& regs = register_file();
  xenos::xe_gpu_texture_fetch_t fetch = regs.GetTextureFetch(binding.fetch_constant);

  SamplerParameters parameters;
  xenos::ClampMode fetch_clamp_x, fetch_clamp_y, fetch_clamp_z;
  texture_util::GetClampModesForDimension(fetch, fetch_clamp_x, fetch_clamp_y, fetch_clamp_z);
  parameters.clamp_x = fetch_clamp_x;
  parameters.clamp_y = fetch_clamp_y;
  parameters.clamp_z = fetch_clamp_z;
  if (xenos::ClampModeUsesBorder(parameters.clamp_x) ||
      xenos::ClampModeUsesBorder(parameters.clamp_y) ||
      xenos::ClampModeUsesBorder(parameters.clamp_z)) {
    parameters.border_color = fetch.border_color;
  } else {
    parameters.border_color = xenos::BorderColor::k_ABGR_Black;
  }
  xenos::TextureFilter mag_filter = binding.mag_filter == xenos::TextureFilter::kUseFetchConst
                                        ? fetch.mag_filter
                                        : binding.mag_filter;
  parameters.mag_linear = mag_filter == xenos::TextureFilter::kLinear;
  xenos::TextureFilter min_filter = binding.min_filter == xenos::TextureFilter::kUseFetchConst
                                        ? fetch.min_filter
                                        : binding.min_filter;
  parameters.min_linear = min_filter == xenos::TextureFilter::kLinear;
  xenos::TextureFilter mip_filter = binding.mip_filter == xenos::TextureFilter::kUseFetchConst
                                        ? fetch.mip_filter
                                        : binding.mip_filter;
  parameters.mip_linear = mip_filter == xenos::TextureFilter::kLinear;
  parameters.mip_base_map = mip_filter == xenos::TextureFilter::kBaseMap;
  xenos::AnisoFilter aniso_filter = binding.aniso_filter == xenos::AnisoFilter::kUseFetchConst
                                        ? fetch.aniso_filter
                                        : binding.aniso_filter;
  aniso_filter = std::min(aniso_filter, max_anisotropy_);
  uint32_t mip_min_level, mip_max_level;
  texture_util::GetSubresourcesFromFetchConstant(fetch, nullptr, nullptr, nullptr, nullptr, nullptr,
                                                 &mip_min_level, &mip_max_level);
  parameters.mip_min_level = mip_min_level;
  if (aniso_filter != xenos::AnisoFilter::kDisabled) {
    parameters.mag_linear = 1;
    parameters.min_linear = 1;
    parameters.mip_linear = 1;
  }
  parameters.aniso_filter = aniso_filter;
  return parameters;
}

id<MTLSamplerState> MetalTextureCache::GetSampler(SamplerParameters parameters) {
  auto it = samplers_.find(parameters.value);
  if (it != samplers_.end()) {
    return it->second;
  }
  auto address_mode = [](xenos::ClampMode mode) {
    switch (mode) {
      case xenos::ClampMode::kRepeat:
        return MTLSamplerAddressModeRepeat;
      case xenos::ClampMode::kMirroredRepeat:
        return MTLSamplerAddressModeMirrorRepeat;
      case xenos::ClampMode::kClampToEdge:
      case xenos::ClampMode::kClampToHalfway:
        return MTLSamplerAddressModeClampToEdge;
      case xenos::ClampMode::kMirrorClampToEdge:
      case xenos::ClampMode::kMirrorClampToHalfway:
        return MTLSamplerAddressModeMirrorClampToEdge;
      case xenos::ClampMode::kClampToBorder:
      case xenos::ClampMode::kMirrorClampToBorder:
        return MTLSamplerAddressModeClampToBorderColor;
      default:
        return MTLSamplerAddressModeClampToEdge;
    }
  };
  MTLSamplerDescriptor* descriptor = [[MTLSamplerDescriptor alloc] init];
  descriptor.sAddressMode = address_mode(parameters.clamp_x);
  descriptor.tAddressMode = address_mode(parameters.clamp_y);
  descriptor.rAddressMode = address_mode(parameters.clamp_z);
  switch (parameters.border_color) {
    case xenos::BorderColor::k_ABGR_White:
      descriptor.borderColor = MTLSamplerBorderColorOpaqueWhite;
      break;
    case xenos::BorderColor::k_ABGR_Black:
      descriptor.borderColor = MTLSamplerBorderColorTransparentBlack;
      break;
    default:
      descriptor.borderColor = MTLSamplerBorderColorOpaqueBlack;
      break;
  }
  descriptor.magFilter =
      parameters.mag_linear ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
  descriptor.minFilter =
      parameters.min_linear ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
  descriptor.mipFilter = parameters.mip_base_map ? MTLSamplerMipFilterNotMipmapped
                         : parameters.mip_linear ? MTLSamplerMipFilterLinear
                                                 : MTLSamplerMipFilterNearest;
  descriptor.lodMinClamp = float(parameters.mip_min_level);
  descriptor.lodMaxClamp = parameters.mip_base_map ? float(parameters.mip_min_level) : FLT_MAX;
  if (parameters.aniso_filter != xenos::AnisoFilter::kDisabled) {
    descriptor.maxAnisotropy = NSUInteger(1) << (uint32_t(parameters.aniso_filter) - 1);
  }
  descriptor.supportArgumentBuffers = NO;
  id<MTLSamplerState> sampler = [command_processor_.device() newSamplerStateWithDescriptor:descriptor];
  samplers_.emplace(parameters.value, sampler);
  return sampler;
}

MetalTextureCache::HostFormat MetalTextureCache::GetHostFormat(TextureKey key) {
  using TF = xenos::TextureFormat;
  HostFormat f;
  auto set = [&f](LoadShaderIndex load_shader, MTLPixelFormat format, MTLPixelFormat format_signed,
                  uint32_t swizzle, bool block_compressed = false) {
    f.load_shader = load_shader;
    f.format = format;
    f.format_signed = format_signed;
    f.swizzle = swizzle;
    f.block_compressed = block_compressed;
  };
  const FormatInfo* format_info = FormatInfo::Get(key.format);
  bool unaligned = (key.GetWidth() & (format_info->block_width - 1)) ||
                   (key.GetHeight() & (format_info->block_height - 1));
  switch (key.format) {
    case TF::k_8:
    case TF::k_8_A:
      set(kLoadShaderIndex8bpb, MTLPixelFormatR8Unorm, MTLPixelFormatR8Snorm,
          xenos::XE_GPU_TEXTURE_SWIZZLE_RRRR);
      break;
    case TF::k_5_6_5:
      set(kLoadShaderIndexR5G6B5ToRGBA8, MTLPixelFormatRGBA8Unorm, MTLPixelFormatInvalid,
          xenos::XE_GPU_TEXTURE_SWIZZLE_RGBB);
      break;
    case TF::k_8_8_8_8:
    case TF::k_8_8_8_8_AS_16_16_16_16:
      set(kLoadShaderIndex32bpb, MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA8Snorm,
          xenos::XE_GPU_TEXTURE_SWIZZLE_RGBA);
      break;
    case TF::k_2_10_10_10:
    case TF::k_2_10_10_10_AS_16_16_16_16:
      set(kLoadShaderIndex32bpb, MTLPixelFormatRGB10A2Unorm, MTLPixelFormatInvalid,
          xenos::XE_GPU_TEXTURE_SWIZZLE_RGBA);
      break;
    case TF::k_8_8:
      set(kLoadShaderIndex16bpb, MTLPixelFormatRG8Unorm, MTLPixelFormatRG8Snorm,
          xenos::XE_GPU_TEXTURE_SWIZZLE_RGGG);
      break;
    case TF::k_Cr_Y1_Cb_Y0_REP:
      set(kLoadShaderIndexGBGR8ToRGB8, MTLPixelFormatRGBA8Unorm, MTLPixelFormatInvalid,
          xenos::XE_GPU_TEXTURE_SWIZZLE_RGBB);
      break;
    case TF::k_Y1_Cr_Y0_Cb_REP:
      set(kLoadShaderIndexBGRG8ToRGB8, MTLPixelFormatRGBA8Unorm, MTLPixelFormatInvalid,
          xenos::XE_GPU_TEXTURE_SWIZZLE_RGBB);
      break;
    case TF::k_4_4_4_4:
      set(kLoadShaderIndexRGBA4ToRGBA8, MTLPixelFormatRGBA8Unorm, MTLPixelFormatInvalid,
          xenos::XE_GPU_TEXTURE_SWIZZLE_RGBA);
      break;
    case TF::k_10_11_11:
    case TF::k_10_11_11_AS_16_16_16_16:
      set(kLoadShaderIndexR11G11B10ToRGBA16, MTLPixelFormatRGBA16Unorm, MTLPixelFormatInvalid,
          xenos::XE_GPU_TEXTURE_SWIZZLE_RGBB);
      break;
    case TF::k_11_11_10:
    case TF::k_11_11_10_AS_16_16_16_16:
      set(kLoadShaderIndexR10G11B11ToRGBA16, MTLPixelFormatRGBA16Unorm, MTLPixelFormatInvalid,
          xenos::XE_GPU_TEXTURE_SWIZZLE_RGBB);
      break;
    case TF::k_DXT1:
    case TF::k_DXT1_AS_16_16_16_16:
      if (unaligned) {
        set(kLoadShaderIndexDXT1ToRGBA8, MTLPixelFormatRGBA8Unorm, MTLPixelFormatInvalid,
            xenos::XE_GPU_TEXTURE_SWIZZLE_RGBA);
      } else {
        set(kLoadShaderIndex64bpb, MTLPixelFormatBC1_RGBA, MTLPixelFormatInvalid,
            xenos::XE_GPU_TEXTURE_SWIZZLE_RGBA, true);
      }
      break;
    case TF::k_DXT2_3:
    case TF::k_DXT2_3_AS_16_16_16_16:
      if (unaligned) {
        set(kLoadShaderIndexDXT3ToRGBA8, MTLPixelFormatRGBA8Unorm, MTLPixelFormatInvalid,
            xenos::XE_GPU_TEXTURE_SWIZZLE_RGBA);
      } else {
        set(kLoadShaderIndex128bpb, MTLPixelFormatBC2_RGBA, MTLPixelFormatInvalid,
            xenos::XE_GPU_TEXTURE_SWIZZLE_RGBA, true);
      }
      break;
    case TF::k_DXT4_5:
    case TF::k_DXT4_5_AS_16_16_16_16:
      if (unaligned) {
        set(kLoadShaderIndexDXT5ToRGBA8, MTLPixelFormatRGBA8Unorm, MTLPixelFormatInvalid,
            xenos::XE_GPU_TEXTURE_SWIZZLE_RGBA);
      } else {
        set(kLoadShaderIndex128bpb, MTLPixelFormatBC3_RGBA, MTLPixelFormatInvalid,
            xenos::XE_GPU_TEXTURE_SWIZZLE_RGBA, true);
      }
      break;
    case TF::k_DXN:
      if (unaligned) {
        set(kLoadShaderIndexDXNToRG8, MTLPixelFormatRG8Unorm, MTLPixelFormatInvalid,
            xenos::XE_GPU_TEXTURE_SWIZZLE_RGGG);
      } else {
        set(kLoadShaderIndex128bpb, MTLPixelFormatBC5_RGUnorm, MTLPixelFormatInvalid,
            xenos::XE_GPU_TEXTURE_SWIZZLE_RGGG, true);
      }
      break;
    case TF::k_DXT5A:
      if (unaligned) {
        set(kLoadShaderIndexDXT5AToR8, MTLPixelFormatR8Unorm, MTLPixelFormatInvalid,
            xenos::XE_GPU_TEXTURE_SWIZZLE_RRRR);
      } else {
        set(kLoadShaderIndex64bpb, MTLPixelFormatBC4_RUnorm, MTLPixelFormatInvalid,
            xenos::XE_GPU_TEXTURE_SWIZZLE_RRRR, true);
      }
      break;
    case TF::k_DXT3A:
      set(kLoadShaderIndexDXT3A, MTLPixelFormatR8Unorm, MTLPixelFormatInvalid,
          xenos::XE_GPU_TEXTURE_SWIZZLE_RRRR);
      break;
    case TF::k_CTX1:
      set(kLoadShaderIndexCTX1, MTLPixelFormatRG8Unorm, MTLPixelFormatInvalid,
          xenos::XE_GPU_TEXTURE_SWIZZLE_RGGG);
      break;
    case TF::k_24_8:
      set(kLoadShaderIndexDepthUnorm, MTLPixelFormatR32Float, MTLPixelFormatR32Float,
          xenos::XE_GPU_TEXTURE_SWIZZLE_RRRR);
      break;
    case TF::k_24_8_FLOAT:
      set(kLoadShaderIndexDepthFloat, MTLPixelFormatR32Float, MTLPixelFormatR32Float,
          xenos::XE_GPU_TEXTURE_SWIZZLE_RRRR);
      break;
    case TF::k_16:
      set(kLoadShaderIndex16bpb, MTLPixelFormatR16Unorm, MTLPixelFormatR16Snorm,
          xenos::XE_GPU_TEXTURE_SWIZZLE_RRRR);
      break;
    case TF::k_16_16:
      set(kLoadShaderIndex32bpb, MTLPixelFormatRG16Unorm, MTLPixelFormatRG16Snorm,
          xenos::XE_GPU_TEXTURE_SWIZZLE_RGGG);
      break;
    case TF::k_16_16_16_16:
      set(kLoadShaderIndex64bpb, MTLPixelFormatRGBA16Unorm, MTLPixelFormatRGBA16Snorm,
          xenos::XE_GPU_TEXTURE_SWIZZLE_RGBA);
      break;
    case TF::k_16_EXPAND:
    case TF::k_16_FLOAT:
      set(kLoadShaderIndex16bpb, MTLPixelFormatR16Float, MTLPixelFormatR16Float,
          xenos::XE_GPU_TEXTURE_SWIZZLE_RRRR);
      break;
    case TF::k_16_16_EXPAND:
    case TF::k_16_16_FLOAT:
      set(kLoadShaderIndex32bpb, MTLPixelFormatRG16Float, MTLPixelFormatRG16Float,
          xenos::XE_GPU_TEXTURE_SWIZZLE_RGGG);
      break;
    case TF::k_16_16_16_16_EXPAND:
    case TF::k_16_16_16_16_FLOAT:
      set(kLoadShaderIndex64bpb, MTLPixelFormatRGBA16Float, MTLPixelFormatRGBA16Float,
          xenos::XE_GPU_TEXTURE_SWIZZLE_RGBA);
      break;
    case TF::k_32_FLOAT:
      set(kLoadShaderIndex32bpb, MTLPixelFormatR32Float, MTLPixelFormatR32Float,
          xenos::XE_GPU_TEXTURE_SWIZZLE_RRRR);
      break;
    case TF::k_32_32_FLOAT:
      set(kLoadShaderIndex64bpb, MTLPixelFormatRG32Float, MTLPixelFormatRG32Float,
          xenos::XE_GPU_TEXTURE_SWIZZLE_RGGG);
      break;
    case TF::k_32_32_32_32_FLOAT:
      set(kLoadShaderIndex128bpb, MTLPixelFormatRGBA32Float, MTLPixelFormatRGBA32Float,
          xenos::XE_GPU_TEXTURE_SWIZZLE_RGBA);
      break;
    default:
      break;
  }
  return f;
}

uint32_t MetalTextureCache::GetHostFormatSwizzle(TextureKey key) const {
  return GetHostFormat(key).swizzle;
}

uint32_t MetalTextureCache::GetMaxHostTextureWidthHeight(xenos::DataDimension dimension) const {
  return dimension == xenos::DataDimension::k3D ? 2048 : 16384;
}

uint32_t MetalTextureCache::GetMaxHostTextureDepthOrArraySize(
    xenos::DataDimension dimension) const {
  return 2048;
}

MetalTextureCache::MetalTexture::MetalTexture(MetalTextureCache& texture_cache,
                                              const TextureKey& key, id<MTLTexture> texture)
    : Texture(texture_cache, key), texture_(texture) {
  // Approximate - for the texture cache's memory usage accounting.
  SetHostMemoryUsage(uint64_t(texture.allocatedSize));
}

id<MTLTexture> MetalTextureCache::MetalTexture::GetView(bool is_signed, uint32_t host_swizzle) {
  uint32_t view_key = (host_swizzle & 0xFFF) | (uint32_t(is_signed) << 12);
  auto it = views_.find(view_key);
  if (it != views_.end()) {
    return it->second;
  }
  HostFormat host_format = GetHostFormat(key());
  MTLPixelFormat format = is_signed ? host_format.format_signed : host_format.format;
  id<MTLTexture> view = nil;
  if (format != MTLPixelFormatInvalid) {
    MTLTextureSwizzleChannels swizzle = MTLTextureSwizzleChannelsMake(
        ToMetalSwizzle(host_swizzle & 7), ToMetalSwizzle((host_swizzle >> 3) & 7),
        ToMetalSwizzle((host_swizzle >> 6) & 7), ToMetalSwizzle((host_swizzle >> 9) & 7));
    view = [texture_ newTextureViewWithPixelFormat:format
                                       textureType:texture_.textureType
                                            levels:NSMakeRange(0, texture_.mipmapLevelCount)
                                            slices:NSMakeRange(0, texture_.textureType ==
                                                                          MTLTextureTypeCube
                                                                      ? 6
                                                                      : texture_.arrayLength)
                                           swizzle:swizzle];
  }
  views_.emplace(view_key, view);
  return view;
}

std::unique_ptr<TextureCache::Texture> MetalTextureCache::CreateTexture(TextureKey key) {
  HostFormat host_format = GetHostFormat(key);
  if (host_format.format == MTLPixelFormatInvalid ||
      !load_pipelines_[host_format.load_shader]) {
    static std::array<bool, 64> logged = {};
    if (!logged[uint32_t(key.format) & 63]) {
      logged[uint32_t(key.format) & 63] = true;
      REXGPU_WARN("MetalTextureCache: Unsupported texture format {}",
                  FormatInfo::Get(key.format)->name);
    }
    return nullptr;
  }
  MTLTextureDescriptor* descriptor = [[MTLTextureDescriptor alloc] init];
  descriptor.pixelFormat = host_format.format;
  descriptor.width = key.GetWidth();
  descriptor.height = key.GetHeight();
  switch (key.dimension) {
    case xenos::DataDimension::k3D:
      descriptor.textureType = MTLTextureType3D;
      descriptor.depth = key.GetDepthOrArraySize();
      break;
    case xenos::DataDimension::kCube:
      descriptor.textureType = MTLTextureTypeCube;
      break;
    default:
      descriptor.textureType = MTLTextureType2DArray;
      descriptor.arrayLength = key.GetDepthOrArraySize();
      break;
  }
  descriptor.mipmapLevelCount = key.mip_max_level + 1;
  descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
  descriptor.storageMode = MTLStorageModePrivate;
  id<MTLTexture> texture = [command_processor_.device() newTextureWithDescriptor:descriptor];
  if (!texture) {
    REXGPU_ERROR("MetalTextureCache: Failed to create a {}x{}x{} {} texture", key.GetWidth(),
                 key.GetHeight(), key.GetDepthOrArraySize(), FormatInfo::Get(key.format)->name);
    return nullptr;
  }
  return std::make_unique<MetalTexture>(*this, key, texture);
}

bool MetalTextureCache::LoadTextureDataFromResidentMemoryImpl(Texture& texture, bool load_base,
                                                              bool load_mips) {
  // Follows the Vulkan backend: decode the guest data with a compute shader
  // into a buffer, then copy the buffer to the texture.
  auto& metal_texture = static_cast<MetalTexture&>(texture);
  TextureKey texture_key = metal_texture.key();
  if (texture_key.scaled_resolve) {
    return false;
  }
  HostFormat host_format = GetHostFormat(texture_key);
  LoadShaderIndex load_shader = host_format.load_shader;
  if (load_shader == kLoadShaderIndexUnknown || !load_pipelines_[load_shader]) {
    return false;
  }
  id<MTLComputePipelineState> pipeline = load_pipelines_[load_shader];
  const LoadShaderInfo& load_shader_info = GetLoadShaderInfo(load_shader);

  const texture_util::TextureGuestLayout& guest_layout = metal_texture.guest_layout();
  xenos::DataDimension dimension = texture_key.dimension;
  bool is_3d = dimension == xenos::DataDimension::k3D;
  bool is_3d_tiling = is_3d || metal_texture.force_load_3d_tiling();
  uint32_t width = texture_key.GetWidth();
  uint32_t height = texture_key.GetHeight();
  uint32_t depth_or_array_size = texture_key.GetDepthOrArraySize();
  uint32_t depth = is_3d ? depth_or_array_size : 1;
  uint32_t array_size = is_3d ? 1 : depth_or_array_size;
  xenos::TextureFormat guest_format = texture_key.format;
  const FormatInfo* guest_format_info = FormatInfo::Get(guest_format);
  uint32_t block_width = guest_format_info->block_width;
  uint32_t block_height = guest_format_info->block_height;
  uint32_t bytes_per_block = guest_format_info->bytes_per_block();
  uint32_t level_first = load_base ? 0 : 1;
  uint32_t level_last = load_mips ? texture_key.mip_max_level : 0;
  if (level_first > level_last) {
    return true;
  }
  uint32_t level_packed = guest_layout.packed_level;
  uint32_t level_stored_first = std::min(level_first, level_packed);
  uint32_t level_stored_last = std::min(level_last, level_packed);

  uint32_t loop_level_first, loop_level_last;
  if (level_packed == 0) {
    loop_level_first = uint32_t(level_first != 0);
    loop_level_last = uint32_t(level_last != 0);
  } else {
    loop_level_first = level_stored_first;
    loop_level_last = level_stored_last;
  }

  uint32_t host_block_width = host_format.block_compressed ? block_width : 1;
  uint32_t host_block_height = host_format.block_compressed ? block_height : 1;
  uint32_t host_x_blocks_per_thread = UINT32_C(1)
                                      << load_shader_info.guest_x_blocks_per_thread_log2;
  if (!host_format.block_compressed) {
    host_x_blocks_per_thread *= block_width;
  }
  size_t host_buffer_size = 0;
  struct HostLayout {
    size_t offset_bytes;
    size_t slice_size_bytes;
    uint32_t x_pitch_blocks;
    uint32_t y_pitch_blocks;
  };
  HostLayout host_layout_base = {};
  HostLayout host_layout_mips[xenos::kTextureMaxMips] = {};
  for (uint32_t loop_level = loop_level_first; loop_level <= loop_level_last; ++loop_level) {
    bool is_base = loop_level == 0;
    uint32_t level = (level_packed == 0) ? 0 : loop_level;
    HostLayout& level_host_layout = is_base ? host_layout_base : host_layout_mips[level];
    level_host_layout.offset_bytes = host_buffer_size;
    uint32_t level_guest_x_extent_texels, level_guest_y_extent_texels, level_guest_z_extent_texels;
    if (level == level_packed) {
      const texture_util::TextureGuestLayout::Level& guest_layout_packed =
          is_base ? guest_layout.base : guest_layout.mips[level];
      level_guest_x_extent_texels = guest_layout_packed.x_extent_blocks * block_width;
      level_guest_y_extent_texels = guest_layout_packed.y_extent_blocks * block_height;
      level_guest_z_extent_texels = guest_layout_packed.z_extent;
    } else {
      level_guest_x_extent_texels = std::max(width >> level, UINT32_C(1));
      level_guest_y_extent_texels = std::max(height >> level, UINT32_C(1));
      level_guest_z_extent_texels = std::max(depth >> level, UINT32_C(1));
    }
    level_host_layout.x_pitch_blocks =
        rex::round_up((level_guest_x_extent_texels + (host_block_width - 1)) / host_block_width,
                      host_x_blocks_per_thread);
    level_host_layout.y_pitch_blocks =
        (level_guest_y_extent_texels + (host_block_height - 1)) / host_block_height;
    level_host_layout.slice_size_bytes = size_t(load_shader_info.bytes_per_host_block) *
                                         level_host_layout.x_pitch_blocks *
                                         level_host_layout.y_pitch_blocks *
                                         level_guest_z_extent_texels;
    host_buffer_size += level_host_layout.slice_size_bytes * array_size;
  }
  if (!host_buffer_size) {
    return true;
  }
  id<MTLBuffer> scratch_buffer =
      [command_processor_.device() newBufferWithLength:host_buffer_size
                                               options:MTLResourceStorageModePrivate |
                                                       MTLResourceHazardTrackingModeUntracked];
  if (!scratch_buffer) {
    return false;
  }

  auto& metal_shared_memory = static_cast<MetalSharedMemory&>(shared_memory());
  id<MTLComputeCommandEncoder> encoder = command_processor_.GetComputeEncoder();
  [encoder setComputePipelineState:pipeline];
  [encoder setBuffer:scratch_buffer offset:0 atIndex:kLoadBufferDestination];

  LoadConstants load_constants;
  load_constants.is_tiled_3d_endian_scale =
      uint32_t(texture_key.tiled) | (uint32_t(is_3d_tiling) << 1) |
      (uint32_t(texture_key.endianness) << 2) | (UINT32_C(1) << 4) | (UINT32_C(1) << 7);
  uint32_t guest_x_blocks_per_group_log2 = load_shader_info.GetGuestXBlocksPerGroupLog2();
  for (uint32_t loop_level = loop_level_first; loop_level <= loop_level_last; ++loop_level) {
    bool is_base = loop_level == 0;
    uint32_t level = (level_packed == 0) ? 0 : loop_level;
    // The source is bound at the base or the mips address (the shader uses
    // offsets relative to it).
    uint32_t source_start = (is_base ? texture_key.base_page : texture_key.mip_page) << 12;
    [encoder setBuffer:metal_shared_memory.buffer() offset:source_start atIndex:kLoadBufferSource];
    load_constants.guest_offset = 0;
    if (!is_base) {
      load_constants.guest_offset += guest_layout.mip_offsets_bytes[level];
    }
    const texture_util::TextureGuestLayout::Level& level_guest_layout =
        is_base ? guest_layout.base : guest_layout.mips[level];
    uint32_t level_guest_pitch = level_guest_layout.row_pitch_bytes;
    if (texture_key.tiled) {
      level_guest_pitch /= bytes_per_block;
    }
    load_constants.guest_pitch_aligned = level_guest_pitch;
    load_constants.guest_z_stride_block_rows_aligned = level_guest_layout.z_slice_stride_block_rows;
    uint32_t level_width, level_height, level_depth;
    if (level == level_packed) {
      level_width = level_guest_layout.x_extent_blocks * block_width;
      level_height = level_guest_layout.y_extent_blocks * block_height;
      level_depth = level_guest_layout.z_extent;
    } else {
      level_width = std::max(width >> level, UINT32_C(1));
      level_height = std::max(height >> level, UINT32_C(1));
      level_depth = std::max(depth >> level, UINT32_C(1));
    }
    load_constants.size_blocks[0] = (level_width + (block_width - 1)) / block_width;
    load_constants.size_blocks[1] = (level_height + (block_height - 1)) / block_height;
    load_constants.size_blocks[2] = level_depth;
    load_constants.height_texels = level_height;
    uint32_t group_count_x =
        (load_constants.size_blocks[0] + ((UINT32_C(1) << guest_x_blocks_per_group_log2) - 1)) >>
        guest_x_blocks_per_group_log2;
    uint32_t group_count_y =
        (load_constants.size_blocks[1] + ((UINT32_C(1) << kLoadGuestYBlocksPerGroupLog2) - 1)) >>
        kLoadGuestYBlocksPerGroupLog2;
    const HostLayout& level_host_layout = is_base ? host_layout_base : host_layout_mips[level];
    load_constants.host_offset = uint32_t(level_host_layout.offset_bytes);
    load_constants.host_pitch =
        load_shader_info.bytes_per_host_block * level_host_layout.x_pitch_blocks;
    uint32_t level_array_slice_stride_bytes = level_guest_layout.array_slice_stride_bytes;
    for (uint32_t slice = 0; slice < array_size; ++slice) {
      [encoder setBytes:&load_constants length:sizeof(load_constants) atIndex:kMslBufferPushConstants];
      [encoder dispatchThreadgroups:MTLSizeMake(group_count_x, group_count_y,
                                                load_constants.size_blocks[2])
              threadsPerThreadgroup:MTLSizeMake(UINT32_C(1) << kLoadGuestXThreadsPerGroupLog2,
                                                UINT32_C(1) << kLoadGuestYBlocksPerGroupLog2, 1)];
      load_constants.guest_offset += level_array_slice_stride_bytes;
      load_constants.host_offset += uint32_t(level_host_layout.slice_size_bytes);
    }
  }

  // Copy to the texture.
  id<MTLBlitCommandEncoder> blit = command_processor_.GetBlitEncoder();
  id<MTLTexture> destination = metal_texture.texture();
  for (uint32_t level = level_first; level <= level_last; ++level) {
    const HostLayout& level_host_layout =
        level != 0 ? host_layout_mips[std::min(level, level_packed)] : host_layout_base;
    size_t buffer_offset = level_host_layout.offset_bytes;
    if (level >= level_packed) {
      uint32_t level_offset_blocks_x, level_offset_blocks_y, level_offset_z;
      texture_util::GetPackedMipOffset(width, height, depth, guest_format, level,
                                       level_offset_blocks_x, level_offset_blocks_y,
                                       level_offset_z);
      uint32_t level_offset_host_blocks_x = level_offset_blocks_x;
      uint32_t level_offset_host_blocks_y = level_offset_blocks_y;
      if (!host_format.block_compressed) {
        level_offset_host_blocks_x *= block_width;
        level_offset_host_blocks_y *= block_height;
      }
      buffer_offset += size_t(load_shader_info.bytes_per_host_block) *
                       (level_offset_host_blocks_x +
                        size_t(level_host_layout.x_pitch_blocks) *
                            (level_offset_host_blocks_y +
                             size_t(level_host_layout.y_pitch_blocks) * level_offset_z));
    }
    uint32_t level_width = std::max(width >> level, UINT32_C(1));
    uint32_t level_height = std::max(height >> level, UINT32_C(1));
    uint32_t level_depth = std::max(depth >> level, UINT32_C(1));
    NSUInteger bytes_per_row =
        NSUInteger(load_shader_info.bytes_per_host_block) * level_host_layout.x_pitch_blocks;
    NSUInteger bytes_per_image = bytes_per_row * level_host_layout.y_pitch_blocks;
    for (uint32_t slice = 0; slice < array_size; ++slice) {
      [blit copyFromBuffer:scratch_buffer
                 sourceOffset:buffer_offset + level_host_layout.slice_size_bytes * slice
            sourceBytesPerRow:bytes_per_row
          sourceBytesPerImage:is_3d ? bytes_per_image : 0
                   sourceSize:MTLSizeMake(level_width, level_height, level_depth)
                    toTexture:destination
             destinationSlice:slice
             destinationLevel:level
            destinationOrigin:MTLOriginMake(0, 0, 0)];
    }
  }
  return true;
}

}  // namespace rex::graphics::metal
