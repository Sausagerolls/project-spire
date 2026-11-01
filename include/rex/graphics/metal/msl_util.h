#pragma once
/**
 * @file        graphics/metal/msl_util.h
 * @brief       SPIR-V to Metal Shading Language conversion
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */

#include <cstddef>
#include <cstdint>
#include <string>

namespace rex::graphics::metal {

// Metal argument table indices of the resources of translated guest shaders
// and of the SPIR-V utility shaders (SpirvShaderTranslator descriptor sets
// and bindings remapped):
// - Set 0 (shared memory and EDRAM): binding 0 - buffer 0, binding 1 - buffer
//   kMslBufferEdram.
// - Set 1 (constants): binding N - buffer kMslBufferConstantsFirst + N.
// - Sets 2 and 3 (vertex and pixel textures): images at bindings 0...T-1 -
//   textures 0...T-1, samplers at bindings T... - samplers 0....
// - Push constants (utility shaders) - buffer kMslBufferPushConstants.
constexpr uint32_t kMslBufferSharedMemory = 0;
constexpr uint32_t kMslBufferConstantsFirst = 1;
constexpr uint32_t kMslBufferEdram = 8;
constexpr uint32_t kMslBufferPushConstants = 9;
// Per-patch data (stage_in) of hardware-tessellated guest draws.
constexpr uint32_t kMslBufferTessellationPatches = 30;
// Utility (non-guest) shaders may use other sets: set S binding N - buffer
// kMslBufferUtilityFirst + 4 * S + N for buffers, texture 4 * S + N.
constexpr uint32_t kMslBufferUtilityFirst = 10;

struct MslConversionOptions {
  // Utility shaders use the generic remapping of sets and bindings rather than
  // the guest shader layout.
  bool utility = false;
  // Flip clip space Y for Metal (vertex stage), like MoltenVK does.
  bool flip_vertex_y = true;
};

// Converts a SPIR-V module to MSL source. The entry point is named "main0".
// Returns false and writes the error message on failure.
bool ConvertSpirvToMsl(const uint32_t* spirv, size_t spirv_word_count,
                       const MslConversionOptions& options, std::string& msl_out,
                       std::string& error_out);

}  // namespace rex::graphics::metal
