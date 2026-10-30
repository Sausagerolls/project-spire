/**
 * @file        graphics/metal/shader.mm
 * @brief       Guest shaders translated to SPIR-V and converted to MSL
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */

#include <rex/graphics/metal/shader.h>

#include <string>

#include <rex/graphics/metal/msl_util.h>
#include <rex/logging.h>
#include <rex/ui/metal/metal_provider.h>

namespace rex::graphics::metal {

Shader::Translation* MetalShader::CreateTranslationInstance(uint64_t modification) {
  return new MetalTranslation(*this, modification);
}

id<MTLFunction> MetalShader::MetalTranslation::GetOrCreateFunction(
    const ui::metal::MetalProvider& provider) {
  std::lock_guard<std::mutex> lock(function_mutex_);
  if (function_attempted_) {
    return function_;
  }
  function_attempted_ = true;
  if (!is_valid()) {
    return nil;
  }
  const std::vector<uint8_t>& spirv = translated_binary();
  std::string msl, error;
  MslConversionOptions options;
  if (!ConvertSpirvToMsl(reinterpret_cast<const uint32_t*>(spirv.data()),
                         spirv.size() / sizeof(uint32_t), options, msl, error)) {
    REXGPU_ERROR("MetalShader: Failed to convert shader {:016X} modification {:016X} to MSL: {}",
                 shader().ucode_data_hash(), modification(), error);
    MakeInvalid();
    return nil;
  }
  std::string debug_name = fmt::format("shader {:016X} modification {:016X}",
                                       shader().ucode_data_hash(), modification());
  @autoreleasepool {
    id<MTLLibrary> library =
        provider.CompileLibrary([NSString stringWithUTF8String:msl.c_str()], debug_name.c_str());
    if (library) {
      function_ = [library newFunctionWithName:@"main0"];
    }
  }
  if (!function_) {
    MakeInvalid();
  }
  return function_;
}

}  // namespace rex::graphics::metal
