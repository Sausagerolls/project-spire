/**
 * @file        graphics/metal/pipeline_cache.mm
 * @brief       Shader translation and pipeline states for the Metal backend
 *
 * The shader modification logic follows the Vulkan backend (Xenia, Copyright
 * 2022 Ben Vanik, BSD license).
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */

#include <rex/graphics/metal/pipeline_cache.h>

#include <cstring>

#include <xxhash.h>

#include <rex/assert.h>
#include <rex/graphics/metal/command_processor.h>
#include <rex/graphics/pipeline/texture/util.h>
#include <rex/graphics/util/draw.h>
#include <rex/logging.h>
#include <rex/math.h>
#include <rex/ui/metal/metal_provider.h>

namespace rex::graphics::metal {

namespace {

MTLBlendFactor ToMetalBlendFactor(xenos::BlendFactor factor) {
  switch (factor) {
    case xenos::BlendFactor::kZero:
      return MTLBlendFactorZero;
    case xenos::BlendFactor::kOne:
      return MTLBlendFactorOne;
    case xenos::BlendFactor::kSrcColor:
      return MTLBlendFactorSourceColor;
    case xenos::BlendFactor::kOneMinusSrcColor:
      return MTLBlendFactorOneMinusSourceColor;
    case xenos::BlendFactor::kSrcAlpha:
      return MTLBlendFactorSourceAlpha;
    case xenos::BlendFactor::kOneMinusSrcAlpha:
      return MTLBlendFactorOneMinusSourceAlpha;
    case xenos::BlendFactor::kDstColor:
      return MTLBlendFactorDestinationColor;
    case xenos::BlendFactor::kOneMinusDstColor:
      return MTLBlendFactorOneMinusDestinationColor;
    case xenos::BlendFactor::kDstAlpha:
      return MTLBlendFactorDestinationAlpha;
    case xenos::BlendFactor::kOneMinusDstAlpha:
      return MTLBlendFactorOneMinusDestinationAlpha;
    case xenos::BlendFactor::kConstantColor:
      return MTLBlendFactorBlendColor;
    case xenos::BlendFactor::kOneMinusConstantColor:
      return MTLBlendFactorOneMinusBlendColor;
    case xenos::BlendFactor::kConstantAlpha:
      return MTLBlendFactorBlendAlpha;
    case xenos::BlendFactor::kOneMinusConstantAlpha:
      return MTLBlendFactorOneMinusBlendAlpha;
    case xenos::BlendFactor::kSrcAlphaSaturate:
      return MTLBlendFactorSourceAlphaSaturated;
    default:
      return MTLBlendFactorZero;
  }
}

MTLBlendOperation ToMetalBlendOperation(xenos::BlendOp op) {
  switch (op) {
    case xenos::BlendOp::kAdd:
      return MTLBlendOperationAdd;
    case xenos::BlendOp::kSubtract:
      return MTLBlendOperationSubtract;
    case xenos::BlendOp::kMin:
      return MTLBlendOperationMin;
    case xenos::BlendOp::kMax:
      return MTLBlendOperationMax;
    case xenos::BlendOp::kRevSubtract:
      return MTLBlendOperationReverseSubtract;
    default:
      return MTLBlendOperationAdd;
  }
}

MTLCompareFunction ToMetalCompareFunction(xenos::CompareFunction function) {
  switch (function) {
    case xenos::CompareFunction::kNever:
      return MTLCompareFunctionNever;
    case xenos::CompareFunction::kLess:
      return MTLCompareFunctionLess;
    case xenos::CompareFunction::kEqual:
      return MTLCompareFunctionEqual;
    case xenos::CompareFunction::kLessEqual:
      return MTLCompareFunctionLessEqual;
    case xenos::CompareFunction::kGreater:
      return MTLCompareFunctionGreater;
    case xenos::CompareFunction::kNotEqual:
      return MTLCompareFunctionNotEqual;
    case xenos::CompareFunction::kGreaterEqual:
      return MTLCompareFunctionGreaterEqual;
    case xenos::CompareFunction::kAlways:
    default:
      return MTLCompareFunctionAlways;
  }
}

MTLStencilOperation ToMetalStencilOperation(xenos::StencilOp op) {
  switch (op) {
    case xenos::StencilOp::kKeep:
      return MTLStencilOperationKeep;
    case xenos::StencilOp::kZero:
      return MTLStencilOperationZero;
    case xenos::StencilOp::kReplace:
      return MTLStencilOperationReplace;
    case xenos::StencilOp::kIncrementClamp:
      return MTLStencilOperationIncrementClamp;
    case xenos::StencilOp::kDecrementClamp:
      return MTLStencilOperationDecrementClamp;
    case xenos::StencilOp::kInvert:
      return MTLStencilOperationInvert;
    case xenos::StencilOp::kIncrementWrap:
      return MTLStencilOperationIncrementWrap;
    case xenos::StencilOp::kDecrementWrap:
      return MTLStencilOperationDecrementWrap;
    default:
      return MTLStencilOperationKeep;
  }
}

}  // namespace

MetalPipelineCache::MetalPipelineCache(MetalCommandProcessor& command_processor,
                                       const RegisterFile& register_file,
                                       MetalRenderTargetCache& render_target_cache)
    : command_processor_(command_processor),
      register_file_(register_file),
      render_target_cache_(render_target_cache) {}

MetalPipelineCache::~MetalPipelineCache() {
  Shutdown();
}

bool MetalPipelineCache::Initialize() {
  SpirvShaderTranslator::Features features(false);
  features.spirv_version = spv::Spv_1_3;
  features.max_storage_buffer_range = UINT32_MAX;
  features.full_draw_index_uint32 = true;
  features.vertex_pipeline_stores_and_atomics = true;
  features.fragment_stores_and_atomics = true;
  features.clip_distance = true;
  features.image_view_format_swizzle = true;
  features.demote_to_helper_invocation = true;
  features.tessellation_grid_indexed = true;
  // Metal supports 2x MSAA natively.
  shader_translator_ = std::make_unique<SpirvShaderTranslator>(features, true, true, false);
  return true;
}

void MetalPipelineCache::Shutdown() {
  pipelines_.clear();
  depth_stencil_states_.clear();
  shaders_.clear();
  shader_translator_.reset();
}

MetalShader* MetalPipelineCache::LoadShader(xenos::ShaderType shader_type,
                                            const uint32_t* host_address, uint32_t dword_count) {
  uint64_t hash = XXH3_64bits(host_address, dword_count * sizeof(uint32_t));
  auto it = shaders_.find(hash);
  if (it != shaders_.end()) {
    return it->second.get();
  }
  auto shader = std::make_unique<MetalShader>(shader_type, hash, host_address, dword_count);
  MetalShader* shader_ptr = shader.get();
  shaders_.emplace(hash, std::move(shader));
  return shader_ptr;
}

void MetalPipelineCache::AnalyzeShaderUcode(Shader& shader) {
  if (!shader.is_ucode_analyzed()) {
    shader.AnalyzeUcode(ucode_disasm_buffer_);
  }
}

uint32_t MetalPipelineCache::GetTessellationGridFactor(
    const RegisterFile& regs, Shader::HostVertexShaderType host_vertex_shader_type) {
  if (host_vertex_shader_type != Shader::HostVertexShaderType::kQuadDomainPatchIndexed) {
    return 0;
  }
  xenos::TessellationMode tessellation_mode = regs.Get<reg::VGT_HOS_CNTL>().tess_mode;
  // Adaptive patches use the maximum factor of the draw (see the Vulkan
  // backend's vulkan_tessellation_grid_adaptive).
  float factor = regs.Get<float>(XE_GPU_REG_VGT_HOS_MAX_TESS_LEVEL) + 1.0f;
  if (!(factor >= 1.0f && factor <= 64.0f)) {
    return 0;
  }
  uint32_t factor_integer = uint32_t(factor);
  if (float(factor_integer) != factor ||
      (tessellation_mode != xenos::TessellationMode::kDiscrete && (factor_integer & 1))) {
    return 0;
  }
  return factor_integer;
}

SpirvShaderTranslator::Modification MetalPipelineCache::GetCurrentVertexShaderModification(
    const Shader& shader, Shader::HostVertexShaderType host_vertex_shader_type,
    uint32_t interpolator_mask, bool ps_param_gen_used) const {
  assert_true(shader.type() == xenos::ShaderType::kVertex);
  assert_true(shader.is_ucode_analyzed());
  const auto& regs = register_file_;

  SpirvShaderTranslator::Modification modification(
      shader_translator_->GetDefaultVertexShaderModification(
          shader.GetDynamicAddressableRegisterCount(regs.Get<reg::SQ_PROGRAM_CNTL>().vs_num_reg),
          host_vertex_shader_type));

  modification.vertex.interpolator_mask = interpolator_mask;
  if (Shader::IsHostVertexShaderTypeDomain(host_vertex_shader_type)) {
    modification.vertex.tessellation_mode = uint32_t(regs.Get<reg::VGT_HOS_CNTL>().tess_mode);
    modification.vertex.tessellation_grid =
        GetTessellationGridFactor(regs, host_vertex_shader_type) != 0;
  } else {
    modification.vertex.tessellation_mode = 0;
  }

  // Metal has clip distances, but no cull distances.
  auto pa_cl_clip_cntl = regs.Get<reg::PA_CL_CLIP_CNTL>();
  uint32_t user_clip_planes = pa_cl_clip_cntl.clip_disable ? 0 : pa_cl_clip_cntl.ucp_ena;
  modification.vertex.user_clip_plane_cull = 0;
  modification.vertex.user_clip_plane_count = rex::bit_count(user_clip_planes);
  modification.vertex.point_ps_ucp_mode = pa_cl_clip_cntl.ps_ucp_mode;

  if (host_vertex_shader_type == Shader::HostVertexShaderType::kPointListAsTriangleStrip) {
    modification.vertex.output_point_parameters = uint32_t(ps_param_gen_used);
  } else {
    modification.vertex.output_point_parameters =
        uint32_t((shader.writes_point_size_edge_flag_kill_vertex() & 0b001) &&
                 regs.Get<reg::VGT_DRAW_INITIATOR>().prim_type == xenos::PrimitiveType::kPointList);
  }
  modification.vertex.vertex_kill_and = 0;
  return modification;
}

SpirvShaderTranslator::Modification MetalPipelineCache::GetCurrentPixelShaderModification(
    const Shader& shader, uint32_t interpolator_mask, uint32_t param_gen_pos,
    reg::RB_DEPTHCONTROL normalized_depth_control) const {
  assert_true(shader.type() == xenos::ShaderType::kPixel);
  assert_true(shader.is_ucode_analyzed());
  const auto& regs = register_file_;

  SpirvShaderTranslator::Modification modification(
      shader_translator_->GetDefaultPixelShaderModification(
          shader.GetDynamicAddressableRegisterCount(regs.Get<reg::SQ_PROGRAM_CNTL>().ps_num_reg)));

  modification.pixel.interpolator_mask = interpolator_mask;
  modification.pixel.interpolators_centroid =
      interpolator_mask & ~xenos::GetInterpolatorSamplingPattern(
                              regs.Get<reg::RB_SURFACE_INFO>().msaa_samples,
                              regs.Get<reg::SQ_CONTEXT_MISC>().sc_sample_cntl,
                              regs.Get<reg::SQ_INTERPOLATOR_CNTL>().sampling_pattern);

  if (param_gen_pos < xenos::kMaxInterpolators) {
    modification.pixel.param_gen_enable = 1;
    modification.pixel.param_gen_interpolator = param_gen_pos;
    modification.pixel.param_gen_point =
        uint32_t(regs.Get<reg::VGT_DRAW_INITIATOR>().prim_type == xenos::PrimitiveType::kPointList);
  } else {
    modification.pixel.param_gen_enable = 0;
    modification.pixel.param_gen_interpolator = 0;
    modification.pixel.param_gen_point = 0;
  }

  using DepthStencilMode = SpirvShaderTranslator::Modification::DepthStencilMode;
  if (shader.implicit_early_z_write_allowed() &&
      (!shader.writes_color_target(0) ||
       !draw_util::DoesCoverageDependOnAlpha(regs.Get<reg::RB_COLORCONTROL>()))) {
    modification.pixel.depth_stencil_mode = DepthStencilMode::kEarlyHint;
  } else {
    modification.pixel.depth_stencil_mode = DepthStencilMode::kNoModifiers;
  }
  return modification;
}

bool MetalPipelineCache::EnsureShadersTranslated(MetalShader::MetalTranslation* vertex_shader,
                                                 MetalShader::MetalTranslation* pixel_shader) {
  const ui::metal::MetalProvider& provider = command_processor_.GetMetalProvider();
  for (MetalShader::MetalTranslation* translation : {vertex_shader, pixel_shader}) {
    if (!translation) {
      continue;
    }
    if (!translation->is_translated()) {
      AnalyzeShaderUcode(translation->shader());
      if (!shader_translator_->TranslateAnalyzedShader(*translation)) {
        REXGPU_ERROR("Shader {:016X} translation failed; marking as ignored",
                     translation->shader().ucode_data_hash());
        return false;
      }
    }
    if (!translation->GetOrCreateFunction(provider)) {
      return false;
    }
  }
  return true;
}

id<MTLRenderPipelineState> MetalPipelineCache::GetPipeline(
    MetalShader::MetalTranslation* vertex_shader, MetalShader::MetalTranslation* pixel_shader,
    const PrimitiveProcessor::ProcessingResult& primitive_processing_result,
    uint32_t normalized_color_mask, const MetalRenderTargetCache::RenderPassFormats& formats) {
  const RegisterFile& regs = register_file_;

  bool tessellation_grid =
      SpirvShaderTranslator::Modification(vertex_shader->modification()).vertex.tessellation_grid;
  MTLPrimitiveTopologyClass topology_class;
  if (tessellation_grid) {
    topology_class = MTLPrimitiveTopologyClassTriangle;
  } else {
    switch (primitive_processing_result.host_primitive_type) {
      case xenos::PrimitiveType::kPointList:
        topology_class = MTLPrimitiveTopologyClassPoint;
        break;
      case xenos::PrimitiveType::kLineList:
      case xenos::PrimitiveType::kLineStrip:
        topology_class = MTLPrimitiveTopologyClassLine;
        break;
      default:
        topology_class = MTLPrimitiveTopologyClassTriangle;
        break;
    }
  }
  bool primitive_polygonal = tessellation_grid || draw_util::IsPrimitivePolygonal(regs);
  bool rasterization_enabled = draw_util::IsRasterizationPotentiallyDone(regs, primitive_polygonal);
  bool alpha_to_coverage = pixel_shader && regs.Get<reg::RB_COLORCONTROL>().alpha_to_mask_enable;

  // Key: shaders, formats, blending.
  struct Key {
    const void* vertex_shader;
    const void* pixel_shader;
    uint32_t color_formats[xenos::kMaxColorRenderTargets];
    uint32_t blend[xenos::kMaxColorRenderTargets];
    uint32_t depth_format;
    uint32_t sample_count;
    uint32_t write_masks;
    uint32_t flags;
  } key;
  std::memset(&key, 0, sizeof(key));
  key.vertex_shader = vertex_shader;
  key.pixel_shader = pixel_shader;
  for (uint32_t i = 0; i < xenos::kMaxColorRenderTargets; ++i) {
    key.color_formats[i] = uint32_t(formats.color[i]);
    if (formats.color[i] != MTLPixelFormatInvalid) {
      key.blend[i] = regs[reg::RB_BLENDCONTROL::rt_register_indices[i]];
    }
  }
  key.depth_format = uint32_t(formats.depth);
  key.sample_count = formats.sample_count;
  key.write_masks = normalized_color_mask;
  key.flags = uint32_t(topology_class) | (uint32_t(rasterization_enabled) << 4) |
              (uint32_t(alpha_to_coverage) << 5);
  uint64_t key_hash = XXH3_64bits(&key, sizeof(key));
  auto it = pipelines_.find(key_hash);
  if (it != pipelines_.end()) {
    return it->second;
  }

  const ui::metal::MetalProvider& provider = command_processor_.GetMetalProvider();
  MTLRenderPipelineDescriptor* descriptor = [[MTLRenderPipelineDescriptor alloc] init];
  descriptor.vertexFunction = vertex_shader->GetOrCreateFunction(provider);
  descriptor.fragmentFunction = pixel_shader ? pixel_shader->GetOrCreateFunction(provider) : nil;
  descriptor.inputPrimitiveTopology = topology_class;
  descriptor.rasterSampleCount = formats.sample_count;
  // Metal requires a void vertex function without rasterization. Draws not
  // rasterizing (memexport only) are drawn without a fragment shader and with
  // all writes masked instead (the command processor disables depth writes).
  if (!rasterization_enabled) {
    descriptor.fragmentFunction = nil;
  }
  descriptor.alphaToCoverageEnabled = alpha_to_coverage;
  for (uint32_t i = 0; i < xenos::kMaxColorRenderTargets; ++i) {
    MTLRenderPipelineColorAttachmentDescriptor* color = descriptor.colorAttachments[i];
    color.pixelFormat = formats.color[i];
    if (formats.color[i] == MTLPixelFormatInvalid) {
      continue;
    }
    uint32_t write_mask = (normalized_color_mask >> (i * 4)) & 0b1111;
    color.writeMask = ((write_mask & 0b0001) ? MTLColorWriteMaskRed : 0) |
                      ((write_mask & 0b0010) ? MTLColorWriteMaskGreen : 0) |
                      ((write_mask & 0b0100) ? MTLColorWriteMaskBlue : 0) |
                      ((write_mask & 0b1000) ? MTLColorWriteMaskAlpha : 0);
    if (!write_mask || !pixel_shader || !rasterization_enabled) {
      color.writeMask = MTLColorWriteMaskNone;
      continue;
    }
    auto blend_control = regs.Get<reg::RB_BLENDCONTROL>(reg::RB_BLENDCONTROL::rt_register_indices[i]);
    MTLBlendFactor src_color = ToMetalBlendFactor(blend_control.color_srcblend);
    MTLBlendFactor dst_color = ToMetalBlendFactor(blend_control.color_destblend);
    MTLBlendFactor src_alpha = ToMetalBlendFactor(blend_control.alpha_srcblend);
    MTLBlendFactor dst_alpha = ToMetalBlendFactor(blend_control.alpha_destblend);
    MTLBlendOperation color_op = ToMetalBlendOperation(blend_control.color_comb_fcn);
    MTLBlendOperation alpha_op = ToMetalBlendOperation(blend_control.alpha_comb_fcn);
    bool blending = !(src_color == MTLBlendFactorOne && dst_color == MTLBlendFactorZero &&
                      color_op == MTLBlendOperationAdd && src_alpha == MTLBlendFactorOne &&
                      dst_alpha == MTLBlendFactorZero && alpha_op == MTLBlendOperationAdd);
    // Floating-point 32-bit formats are not blendable.
    if (formats.color[i] == MTLPixelFormatR32Float || formats.color[i] == MTLPixelFormatRG32Float) {
      blending = false;
    }
    color.blendingEnabled = blending;
    color.sourceRGBBlendFactor = src_color;
    color.destinationRGBBlendFactor = dst_color;
    color.rgbBlendOperation = color_op;
    color.sourceAlphaBlendFactor = src_alpha;
    color.destinationAlphaBlendFactor = dst_alpha;
    color.alphaBlendOperation = alpha_op;
  }
  descriptor.depthAttachmentPixelFormat = formats.depth;
  descriptor.stencilAttachmentPixelFormat = formats.depth;

  NSError* error = nil;
  id<MTLRenderPipelineState> pipeline =
      [command_processor_.device() newRenderPipelineStateWithDescriptor:descriptor error:&error];
  if (!pipeline) {
    REXGPU_ERROR("MetalPipelineCache: Failed to create a pipeline for shaders {:016X}/{:016X}: {}",
                 vertex_shader->shader().ucode_data_hash(),
                 pixel_shader ? pixel_shader->shader().ucode_data_hash() : 0,
                 error ? [error.localizedDescription UTF8String] : "unknown error");
  }
  pipelines_.emplace(key_hash, pipeline);
  return pipeline;
}

id<MTLDepthStencilState> MetalPipelineCache::GetDepthStencilState(
    reg::RB_DEPTHCONTROL normalized_depth_control, bool depth_attachment_bound,
    bool primitive_polygonal) {
  const RegisterFile& regs = register_file_;
  auto stencil_ref_mask_front = regs.Get<reg::RB_STENCILREFMASK>();
  auto stencil_ref_mask_back =
      regs.Get<reg::RB_STENCILREFMASK>(XE_GPU_REG_RB_STENCILREFMASK_BF);
  struct Key {
    uint32_t depth_control;
    uint32_t masks;
    uint32_t flags;
  } key;
  key.depth_control = depth_attachment_bound ? normalized_depth_control.value : 0;
  bool back_separate = primitive_polygonal && normalized_depth_control.backface_enable;
  key.masks = depth_attachment_bound && normalized_depth_control.stencil_enable
                  ? (stencil_ref_mask_front.stencilmask | (stencil_ref_mask_front.stencilwritemask << 8) |
                     (back_separate ? (stencil_ref_mask_back.stencilmask << 16) |
                                          (stencil_ref_mask_back.stencilwritemask << 24)
                                    : 0))
                  : 0;
  key.flags = uint32_t(depth_attachment_bound) | (uint32_t(back_separate) << 1);
  uint64_t key_hash = XXH3_64bits(&key, sizeof(key));
  auto it = depth_stencil_states_.find(key_hash);
  if (it != depth_stencil_states_.end()) {
    return it->second;
  }

  MTLDepthStencilDescriptor* descriptor = [[MTLDepthStencilDescriptor alloc] init];
  if (depth_attachment_bound) {
    if (normalized_depth_control.z_enable) {
      descriptor.depthCompareFunction = ToMetalCompareFunction(normalized_depth_control.zfunc);
      descriptor.depthWriteEnabled = normalized_depth_control.z_write_enable;
    } else {
      descriptor.depthCompareFunction = MTLCompareFunctionAlways;
      descriptor.depthWriteEnabled = NO;
    }
    if (normalized_depth_control.stencil_enable) {
      MTLStencilDescriptor* front = [[MTLStencilDescriptor alloc] init];
      front.stencilFailureOperation = ToMetalStencilOperation(normalized_depth_control.stencilfail);
      front.depthStencilPassOperation =
          ToMetalStencilOperation(normalized_depth_control.stencilzpass);
      front.depthFailureOperation = ToMetalStencilOperation(normalized_depth_control.stencilzfail);
      front.stencilCompareFunction = ToMetalCompareFunction(normalized_depth_control.stencilfunc);
      front.readMask = stencil_ref_mask_front.stencilmask;
      front.writeMask = stencil_ref_mask_front.stencilwritemask;
      descriptor.frontFaceStencil = front;
      if (back_separate) {
        MTLStencilDescriptor* back = [[MTLStencilDescriptor alloc] init];
        back.stencilFailureOperation =
            ToMetalStencilOperation(normalized_depth_control.stencilfail_bf);
        back.depthStencilPassOperation =
            ToMetalStencilOperation(normalized_depth_control.stencilzpass_bf);
        back.depthFailureOperation =
            ToMetalStencilOperation(normalized_depth_control.stencilzfail_bf);
        back.stencilCompareFunction =
            ToMetalCompareFunction(normalized_depth_control.stencilfunc_bf);
        back.readMask = stencil_ref_mask_back.stencilmask;
        back.writeMask = stencil_ref_mask_back.stencilwritemask;
        descriptor.backFaceStencil = back;
      } else {
        descriptor.backFaceStencil = front;
      }
    }
  }
  id<MTLDepthStencilState> state =
      [command_processor_.device() newDepthStencilStateWithDescriptor:descriptor];
  depth_stencil_states_.emplace(key_hash, state);
  return state;
}

}  // namespace rex::graphics::metal
