#pragma once
/**
 * @file        graphics/metal/pipeline_cache.h
 * @brief       Shader translation and pipeline states for the Metal backend
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */

// Objective-C++ only.

#include <cstdint>
#include <memory>
#include <unordered_set>
#include <mutex>
#include <vector>
#include <unordered_map>

#include <filesystem>

#import <Metal/Metal.h>

#include <rex/graphics/metal/render_target_cache.h>
#include <rex/graphics/metal/shader.h>
#include <rex/graphics/pipeline/shader/spirv_translator.h>
#include <rex/graphics/primitive_processor.h>
#include <rex/graphics/register_file.h>
#include <rex/graphics/registers.h>
#include <rex/string/buffer.h>

namespace rex::graphics::metal {

class MetalCommandProcessor;

class MetalPipelineCache {
 public:
  MetalPipelineCache(MetalCommandProcessor& command_processor, const RegisterFile& register_file,
                     MetalRenderTargetCache& render_target_cache);
  ~MetalPipelineCache();

  bool Initialize();
  void Shutdown();

  // Stores converted shaders and a pipeline binary archive in the directory,
  // so later runs don't compile them again (no stutter on first use).
  void InitializeStorage(const std::filesystem::path& directory);
  // Writes the new pipelines to the binary archive.
  void FlushStorage();
  // Total time spent on the command processor thread (for statistics).
  double shader_compile_seconds() const { return shader_compile_seconds_; }
  double pipeline_compile_seconds() const { return pipeline_compile_seconds_; }
  double shader_translate_seconds() const { return shader_translate_seconds_; }
  uint64_t pipelines_created() const { return pipelines_created_; }

  MetalShader* LoadShader(xenos::ShaderType shader_type, const uint32_t* host_address,
                          uint32_t dword_count);
  void AnalyzeShaderUcode(Shader& shader);

  SpirvShaderTranslator::Modification GetCurrentVertexShaderModification(
      const Shader& shader, Shader::HostVertexShaderType host_vertex_shader_type,
      uint32_t interpolator_mask, bool ps_param_gen_used) const;
  SpirvShaderTranslator::Modification GetCurrentPixelShaderModification(
      const Shader& shader, uint32_t interpolator_mask, uint32_t param_gen_pos,
      reg::RB_DEPTHCONTROL normalized_depth_control) const;

  // Translates (if needed) and compiles the shaders. Returns false if a shader
  // can't be used.
  // With allow_async, shader functions not compiled yet are compiled in the background
  // and pending is set instead of waiting for them.
  bool EnsureShadersTranslated(MetalShader::MetalTranslation* vertex_shader,
                               MetalShader::MetalTranslation* pixel_shader,
                               bool allow_async = false, bool* pending = nullptr);

  // The pipeline state for the current registers and render target formats,
  // nil if it can't be created.
  id<MTLRenderPipelineState> GetPipeline(
      MetalShader::MetalTranslation* vertex_shader, MetalShader::MetalTranslation* pixel_shader,
      const PrimitiveProcessor::ProcessingResult& primitive_processing_result,
      uint32_t normalized_color_mask, const MetalRenderTargetCache::RenderPassFormats& formats,
      bool allow_async = false, bool* pending = nullptr);
  id<MTLDepthStencilState> GetDepthStencilState(reg::RB_DEPTHCONTROL normalized_depth_control,
                                                bool depth_attachment_bound,
                                                bool primitive_polygonal);

  // Like VulkanPipelineCache::GetTessellationGridFactor: the integer factor
  // for drawing quad patches as a triangle grid in the vertex shader, or 0 if
  // the draw can't be drawn that way (Metal has no tessellation stages usable
  // by the translated shaders).
  // Whether the draw is tessellated by the Metal tessellator (per-patch
  // factors computed by the command processor) rather than drawn as a grid.
  static bool UseHardwareTessellation(Shader::HostVertexShaderType host_vertex_shader_type);
  static uint32_t GetTessellationGridFactor(const RegisterFile& regs,
                                            Shader::HostVertexShaderType host_vertex_shader_type);

 private:
  MetalCommandProcessor& command_processor_;
  const RegisterFile& register_file_;
  MetalRenderTargetCache& render_target_cache_;

  std::unique_ptr<SpirvShaderTranslator> shader_translator_;
  string::StringBuffer ucode_disasm_buffer_;

  std::unordered_map<uint64_t, std::unique_ptr<MetalShader>> shaders_;
  std::filesystem::path binary_archive_path_;
  id<MTLBinaryArchive> binary_archive_ = nil;
  bool binary_archive_dirty_ = false;
  double shader_compile_seconds_ = 0.0;
  double pipeline_compile_seconds_ = 0.0;
  double shader_translate_seconds_ = 0.0;
  uint64_t pipelines_created_ = 0;
  std::unordered_map<uint64_t, id<MTLRenderPipelineState>> pipelines_;
  // Pipelines being compiled in the background, and those done (filled by Metal's
  // completion handlers, moved to pipelines_ on the command processor thread).
  std::unordered_set<uint64_t> pending_pipelines_;
  std::mutex completed_pipelines_mutex_;
  std::vector<std::pair<uint64_t, id<MTLRenderPipelineState>>> completed_pipelines_;
  std::unordered_map<uint64_t, id<MTLDepthStencilState>> depth_stencil_states_;
};

}  // namespace rex::graphics::metal
