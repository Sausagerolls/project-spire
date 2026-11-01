/**
 * @file        graphics/metal/shader.mm
 * @brief       Guest shaders translated to SPIR-V and converted to MSL
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */

#include <rex/graphics/metal/shader.h>

#include <fstream>
#include <mutex>
#include <sstream>
#include <string>

#include <xxhash.h>

#include <rex/cvar.h>
#include <rex/graphics/metal/msl_util.h>
#include <rex/logging.h>
#include <rex/ui/metal/metal_provider.h>

REXCVAR_DEFINE_STRING(metal_vertex_math_mode, "", "GPU/Metal",
                      "Math mode for guest vertex shaders ('safe', 'relaxed' or 'fast'), or empty "
                      "for metal_math_mode")
    .lifecycle(rex::cvar::Lifecycle::kInitOnly);
REXCVAR_DEFINE_STRING(metal_dump_shaders_path, "", "GPU/Metal",
                      "Directory to write the MSL of translated guest shaders to (debugging)");

namespace rex::graphics::metal {

namespace {
std::mutex msl_cache_mutex;
std::filesystem::path msl_cache_directory;
}  // namespace

void MetalShader::SetMslCacheDirectory(const std::filesystem::path& directory) {
  std::lock_guard<std::mutex> lock(msl_cache_mutex);
  msl_cache_directory = directory;
}

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
  std::filesystem::path msl_cache_path;
  {
    std::lock_guard<std::mutex> lock(msl_cache_mutex);
    if (!msl_cache_directory.empty()) {
      msl_cache_path = msl_cache_directory /
                       fmt::format("{:016X}.metal", XXH3_64bits(spirv.data(), spirv.size()));
    }
  }
  if (!msl_cache_path.empty()) {
    std::ifstream msl_cache_file(msl_cache_path, std::ios::binary);
    if (msl_cache_file) {
      std::stringstream msl_stream;
      msl_stream << msl_cache_file.rdbuf();
      msl = msl_stream.str();
    }
  }
  if (msl.empty()) {
    if (!ConvertSpirvToMsl(reinterpret_cast<const uint32_t*>(spirv.data()),
                           spirv.size() / sizeof(uint32_t), options, msl, error)) {
      REXGPU_ERROR("MetalShader: Failed to convert shader {:016X} modification {:016X} to MSL: {}",
                   shader().ucode_data_hash(), modification(), error);
      MakeInvalid();
      return nil;
    }
    if (!msl_cache_path.empty()) {
      std::filesystem::path temporary_path = msl_cache_path;
      temporary_path += ".tmp";
      std::ofstream(temporary_path, std::ios::binary) << msl;
      std::error_code error_code;
      std::filesystem::rename(temporary_path, msl_cache_path, error_code);
    }
  }
  std::string debug_name = fmt::format("shader {:016X} modification {:016X}",
                                       shader().ucode_data_hash(), modification());
  const std::string& dump_path = REXCVAR_GET(metal_dump_shaders_path);
  if (!dump_path.empty()) {
    std::ofstream(fmt::format("{}/{}_{:016X}_{:016X}.metal", dump_path,
                              shader().type() == xenos::ShaderType::kVertex ? "vs" : "ps",
                              shader().ucode_data_hash(), modification()))
        << msl;
  }
  @autoreleasepool {
    id<MTLLibrary> library =
        provider.CompileLibrary([NSString stringWithUTF8String:msl.c_str()], debug_name.c_str(),
                                shader().type() == xenos::ShaderType::kVertex &&
                                        !REXCVAR_GET(metal_vertex_math_mode).empty()
                                    ? REXCVAR_GET(metal_vertex_math_mode).c_str()
                                    : nullptr);
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
