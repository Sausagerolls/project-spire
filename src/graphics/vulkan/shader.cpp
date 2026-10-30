/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2022 Ben Vanik. All rights reserved.                             *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 *
 * @modified    Tom Clay, 2026 - Adapted for ReXGlue runtime
 */

#include <cstdint>
#include <vector>

#include <rex/assert.h>
#include <rex/cvar.h>
#include <rex/platform.h>
#include <rex/graphics/vulkan/shader.h>
#include <rex/logging.h>
#include <rex/ui/vulkan/provider.h>

#if REX_PLATFORM_MAC
#define REX_VULKAN_STRIP_NO_CONTRACTION_DEFAULT true
#else
#define REX_VULKAN_STRIP_NO_CONTRACTION_DEFAULT false
#endif
REXCVAR_DEFINE_BOOL(vulkan_strip_no_contraction, REX_VULKAN_STRIP_NO_CONTRACTION_DEFAULT,
                    "GPU/Vulkan",
                    "Remove NoContraction decorations from translated guest shaders. SPIRV-Cross "
                    "turns every NoContraction operation into a call to an unoptimized "
                    "([[clang::optnone]]) helper on Metal, which makes MoltenVK shaders run many "
                    "times slower.");

namespace rex::graphics::vulkan {

namespace {

// Returns a copy of the SPIR-V module without OpDecorate NoContraction instructions.
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
      // Malformed - keep the rest as is.
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

VulkanShader::VulkanTranslation::~VulkanTranslation() {
  if (shader_module_) {
    const ui::vulkan::VulkanDevice* const vulkan_device =
        static_cast<const VulkanShader&>(shader()).vulkan_device_;
    vulkan_device->functions().vkDestroyShaderModule(vulkan_device->device(), shader_module_,
                                                     nullptr);
  }
}

VkShaderModule VulkanShader::VulkanTranslation::GetOrCreateShaderModule() {
  if (!is_valid()) {
    return VK_NULL_HANDLE;
  }
  if (shader_module_ != VK_NULL_HANDLE) {
    return shader_module_;
  }
  const ui::vulkan::VulkanDevice* const vulkan_device =
      static_cast<const VulkanShader&>(shader()).vulkan_device_;
  VkShaderModuleCreateInfo shader_module_create_info;
  shader_module_create_info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
  shader_module_create_info.pNext = nullptr;
  shader_module_create_info.flags = 0;
  shader_module_create_info.codeSize = translated_binary().size();
  shader_module_create_info.pCode = reinterpret_cast<const uint32_t*>(translated_binary().data());
  std::vector<uint32_t> stripped_code;
  if (REXCVAR_GET(vulkan_strip_no_contraction)) {
    stripped_code = StripNoContraction(shader_module_create_info.pCode,
                                       shader_module_create_info.codeSize / sizeof(uint32_t));
    shader_module_create_info.codeSize = stripped_code.size() * sizeof(uint32_t);
    shader_module_create_info.pCode = stripped_code.data();
  }
  if (vulkan_device->functions().vkCreateShaderModule(vulkan_device->device(),
                                                      &shader_module_create_info, nullptr,
                                                      &shader_module_) != VK_SUCCESS) {
    REXGPU_ERROR(
        "VulkanShader::VulkanTranslation: Failed to create a Vulkan shader "
        "module for shader {:016X} modification {:016X}",
        shader().ucode_data_hash(), modification());
    MakeInvalid();
    return VK_NULL_HANDLE;
  }
  return shader_module_;
}

VulkanShader::VulkanShader(const ui::vulkan::VulkanDevice* const vulkan_device,
                           const xenos::ShaderType shader_type, const uint64_t ucode_data_hash,
                           const uint32_t* const ucode_dwords, const size_t ucode_dword_count,
                           const std::endian ucode_source_endian)
    : SpirvShader(shader_type, ucode_data_hash, ucode_dwords, ucode_dword_count,
                  ucode_source_endian),
      vulkan_device_(vulkan_device) {
  assert_not_null(vulkan_device);
}

Shader::Translation* VulkanShader::CreateTranslationInstance(uint64_t modification) {
  return new VulkanTranslation(*this, modification);
}

}  // namespace rex::graphics::vulkan
