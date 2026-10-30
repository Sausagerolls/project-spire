#pragma once
/**
 * @file        graphics/metal/texture_cache.h
 * @brief       Guest texture cache for the Metal backend
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */

// Objective-C++ only.

#include <array>
#include <cstdint>
#include <memory>
#include <unordered_map>

#import <Metal/Metal.h>

#include <rex/graphics/metal/shader.h>
#include <rex/graphics/metal/shared_memory.h>
#include <rex/graphics/pipeline/texture/cache.h>

namespace rex::graphics::metal {

class MetalCommandProcessor;

class MetalTextureCache final : public TextureCache {
 public:
  // Sampler parameters that can be directly converted to a host sampler.
  union SamplerParameters {
    uint32_t value;
    struct {
      xenos::ClampMode clamp_x : 3;         // 3
      xenos::ClampMode clamp_y : 3;         // 6
      xenos::ClampMode clamp_z : 3;         // 9
      xenos::BorderColor border_color : 2;  // 11
      uint32_t mag_linear : 1;              // 12
      uint32_t min_linear : 1;              // 13
      uint32_t mip_linear : 1;              // 14
      xenos::AnisoFilter aniso_filter : 3;  // 17
      uint32_t mip_min_level : 4;           // 21
      uint32_t mip_base_map : 1;            // 22
    };
    SamplerParameters() : value(0) { static_assert_size(*this, sizeof(value)); }
    bool operator==(const SamplerParameters& parameters) const { return value == parameters.value; }
  };

  static std::unique_ptr<MetalTextureCache> Create(const RegisterFile& register_file,
                                                   MetalSharedMemory& shared_memory,
                                                   MetalCommandProcessor& command_processor);
  ~MetalTextureCache();

  // The texture to bind for a texture binding of a translated shader, or a
  // null texture of the needed type.
  id<MTLTexture> GetActiveTextureOrNull(uint32_t fetch_constant_index,
                                        xenos::FetchOpDimension dimension, bool is_signed);

  SamplerParameters GetSamplerParameters(const MetalShader::SamplerBinding& binding) const;
  id<MTLSamplerState> GetSampler(SamplerParameters parameters);

 protected:
  uint32_t GetHostFormatSwizzle(TextureKey key) const override;
  uint32_t GetMaxHostTextureWidthHeight(xenos::DataDimension dimension) const override;
  uint32_t GetMaxHostTextureDepthOrArraySize(xenos::DataDimension dimension) const override;
  std::unique_ptr<Texture> CreateTexture(TextureKey key) override;
  bool LoadTextureDataFromResidentMemoryImpl(Texture& texture, bool load_base,
                                             bool load_mips) override;

 private:
  struct HostFormat {
    LoadShaderIndex load_shader = kLoadShaderIndexUnknown;
    MTLPixelFormat format = MTLPixelFormatInvalid;
    // The guest block size is kept on the host (not decompressed on load).
    bool block_compressed = false;
    // The format of the view for signed sampling (same data), or invalid if
    // signed sampling is unsupported.
    MTLPixelFormat format_signed = MTLPixelFormatInvalid;
    // Mapping of the Xenos components to the host format components.
    uint32_t swizzle = xenos::XE_GPU_TEXTURE_SWIZZLE_RGBA;
  };
  static HostFormat GetHostFormat(TextureKey key);

  class MetalTexture final : public Texture {
   public:
    MetalTexture(MetalTextureCache& texture_cache, const TextureKey& key, id<MTLTexture> texture);
    id<MTLTexture> texture() const { return texture_; }
    // A view with the host swizzle (12 bits, 3 per component) and signedness.
    id<MTLTexture> GetView(bool is_signed, uint32_t host_swizzle);

   private:
    id<MTLTexture> texture_;
    std::unordered_map<uint32_t, id<MTLTexture>> views_;
  };

  MetalTextureCache(const RegisterFile& register_file, MetalSharedMemory& shared_memory,
                    MetalCommandProcessor& command_processor)
      : TextureCache(register_file, shared_memory, 1, 1), command_processor_(command_processor) {}
  bool Initialize();

  MetalCommandProcessor& command_processor_;
  xenos::AnisoFilter max_anisotropy_ = xenos::AnisoFilter::kMax_16_1;

  std::array<id<MTLComputePipelineState>, kLoadShaderCount> load_pipelines_{};

  id<MTLTexture> null_texture_2d_array_ = nil;
  id<MTLTexture> null_texture_3d_ = nil;
  id<MTLTexture> null_texture_cube_ = nil;

  std::unordered_map<uint32_t, id<MTLSamplerState>> samplers_;
};

}  // namespace rex::graphics::metal
