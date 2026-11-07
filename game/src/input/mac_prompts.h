// Keyboard and mouse button prompts on macOS (see mac_prompts.cpp).
#pragma once

#include <filesystem>

namespace fable2::prompts {

// Starts replacing the controller button icons with keycaps as the game loads them.
// Call before the game reads its GUI banks.
void Install(const std::filesystem::path& game_data_root);

}  // namespace fable2::prompts
