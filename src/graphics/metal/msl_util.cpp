/**
 * @file        graphics/metal/msl_util.cpp
 * @brief       SPIR-V to Metal Shading Language conversion
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */

#include <rex/graphics/metal/msl_util.h>

#include <vector>

#include <spirv_msl.hpp>

#include <rex/graphics/pipeline/shader/spirv_translator.h>

namespace rex::graphics::metal {

namespace {

namespace spvc = SPIRV_CROSS_NAMESPACE;

// SPIRV-Cross turns every NoContraction operation into a call to an
// unoptimized ([[clang::optnone]]) helper, which makes the shaders many times
// slower. Metal compiles with safe math anyway.
std::vector<uint32_t> StripNoContraction(const uint32_t* code, size_t word_count) {
  constexpr uint32_t kOpDecorate = 71;
  constexpr uint32_t kDecorationNoContraction = 42;
  constexpr size_t kHeaderWordCount = 5;
  std::vector<uint32_t> result;
  result.reserve(word_count);
  if (word_count < kHeaderWordCount) {
    result.assign(code, code + word_count);
    return result;
  }
  result.assign(code, code + kHeaderWordCount);
  size_t i = kHeaderWordCount;
  while (i < word_count) {
    uint32_t instruction_word_count = code[i] >> 16;
    if (!instruction_word_count || i + instruction_word_count > word_count) {
      result.insert(result.end(), code + i, code + word_count);
      break;
    }
    bool strip = (code[i] & 0xFFFF) == kOpDecorate && instruction_word_count == 3 &&
                 code[i + 2] == kDecorationNoContraction;
    if (!strip) {
      result.insert(result.end(), code + i, code + i + instruction_word_count);
    }
    i += instruction_word_count;
  }
  return result;
}

}  // namespace

bool ConvertSpirvToMsl(const uint32_t* spirv, size_t spirv_word_count,
                       const MslConversionOptions& options, std::string& msl_out,
                       std::string& error_out) {
  try {
    spvc::CompilerMSL compiler(StripNoContraction(spirv, spirv_word_count));

    spvc::CompilerMSL::Options msl_options = compiler.get_msl_options();
    msl_options.platform = spvc::CompilerMSL::Options::macOS;
    msl_options.set_msl_version(3, 0);
    msl_options.argument_buffers = false;
    msl_options.enable_decoration_binding = false;
    // Guest pixel shaders may write fewer components than the render target
    // format has.
    msl_options.pad_fragment_output_components = true;
    msl_options.force_native_arrays = true;
    compiler.set_msl_options(msl_options);

    spvc::CompilerGLSL::Options common_options = compiler.get_common_options();
    common_options.vertex.flip_vert_y = options.flip_vertex_y;
    compiler.set_common_options(common_options);

    spv::ExecutionModel stage = compiler.get_execution_model();
    spvc::ShaderResources resources = compiler.get_shader_resources();

    auto add_binding = [&](uint32_t set, uint32_t binding, uint32_t buffer, uint32_t texture,
                           uint32_t sampler) {
      spvc::MSLResourceBinding msl_binding;
      msl_binding.stage = stage;
      msl_binding.desc_set = set;
      msl_binding.binding = binding;
      msl_binding.msl_buffer = buffer;
      msl_binding.msl_texture = texture;
      msl_binding.msl_sampler = sampler;
      compiler.add_msl_resource_binding(msl_binding);
    };
    auto set_of = [&](spvc::ID id) {
      return compiler.get_decoration(id, spv::DecorationDescriptorSet);
    };
    auto binding_of = [&](spvc::ID id) {
      return compiler.get_decoration(id, spv::DecorationBinding);
    };

    if (options.utility) {
      for (const auto* list : {&resources.uniform_buffers, &resources.storage_buffers,
                               &resources.separate_images, &resources.storage_images,
                               &resources.separate_samplers, &resources.sampled_images}) {
        for (const spvc::Resource& resource : *list) {
          uint32_t set = set_of(resource.id), binding = binding_of(resource.id);
          uint32_t index = 4 * set + binding;
          add_binding(set, binding, kMslBufferUtilityFirst + index, index, index);
        }
      }
    } else {
      uint32_t image_counts[SpirvShaderTranslator::kDescriptorSetCount] = {};
      for (const spvc::Resource& resource : resources.separate_images) {
        uint32_t set = set_of(resource.id);
        if (set < SpirvShaderTranslator::kDescriptorSetCount) {
          ++image_counts[set];
        }
      }
      for (const spvc::Resource& resource : resources.storage_buffers) {
        uint32_t set = set_of(resource.id), binding = binding_of(resource.id);
        if (set == SpirvShaderTranslator::kDescriptorSetSharedMemoryAndEdram) {
          add_binding(set, binding, binding ? kMslBufferEdram : kMslBufferSharedMemory, 0, 0);
        }
      }
      for (const spvc::Resource& resource : resources.uniform_buffers) {
        uint32_t set = set_of(resource.id), binding = binding_of(resource.id);
        add_binding(set, binding, kMslBufferConstantsFirst + binding, 0, 0);
      }
      for (const spvc::Resource& resource : resources.separate_images) {
        uint32_t set = set_of(resource.id), binding = binding_of(resource.id);
        add_binding(set, binding, 0, binding, 0);
      }
      for (const spvc::Resource& resource : resources.separate_samplers) {
        uint32_t set = set_of(resource.id), binding = binding_of(resource.id);
        uint32_t image_count = set < SpirvShaderTranslator::kDescriptorSetCount
                                   ? image_counts[set]
                                   : 0;
        add_binding(set, binding, 0, 0, binding - image_count);
      }
    }
    if (!resources.push_constant_buffers.empty()) {
      spvc::MSLResourceBinding msl_binding;
      msl_binding.stage = stage;
      msl_binding.desc_set = spvc::kPushConstDescSet;
      msl_binding.binding = spvc::kPushConstBinding;
      msl_binding.msl_buffer = kMslBufferPushConstants;
      compiler.add_msl_resource_binding(msl_binding);
    }

    msl_out = compiler.compile();
    return true;
  } catch (const std::exception& exception) {
    error_out = exception.what();
    return false;
  }
}

}  // namespace rex::graphics::metal
