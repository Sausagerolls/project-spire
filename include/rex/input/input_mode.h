/**
 * @file        rex/input/input_mode.h
 * @brief       Which kind of input device the player used last.
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */
#pragma once

#include <cstdint>

namespace rex::input {

enum class InputMode : uint32_t { kKeyboardMouse, kGamepad };

// Set by the input drivers when a device is used: keys, mouse buttons and mouse
// movement for keyboard and mouse; buttons, triggers and sticks past their dead
// zones for a gamepad. Safe from any thread.
void NoteInputMode(InputMode mode);
InputMode GetInputMode();
// Changes each time the mode changes, or RefreshInputModeDependents is called.
uint32_t GetInputModeGeneration();
// For when what depends on the mode changes (key bindings shown in prompts).
void RefreshInputModeDependents();

}  // namespace rex::input
