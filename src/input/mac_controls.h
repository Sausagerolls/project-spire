// Keyboard and mouse controls on macOS: the actions the Controls menu lists, their
// default keys, and the file the player's choices are kept in (controls.toml next to
// fable2_config.toml).
//
// Each action is one of the SDK MnK driver's keybind_* cvars. A value is a comma
// separated list of keys ("E,Space,Shift"); rebinding from the menu replaces the
// list with the one key pressed. The F4 settings overlay edits the same cvars.

#pragma once

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <string>
#include <string_view>

#include <rex/cvar.h>
#include <rex/logging.h>
#include <toml++/toml.hpp>

namespace fable2::controls {

struct Action {
  const char* cvar;
  const char* label;  // as shown in the Controls menu
  const char* keys;   // default
};

// In menu order.
inline constexpr Action kActions[] = {
    {"keybind_lstick_up", "Move Forward", "W"},
    {"keybind_lstick_down", "Move Back", "S"},
    {"keybind_lstick_left", "Move Left", "A"},
    {"keybind_lstick_right", "Move Right", "D"},
    {"keybind_a", "Interact / Run", "E,Space,Shift"},
    {"keybind_x", "Melee", "LMB"},
    {"keybind_y", "Ranged", "RMB"},
    {"keybind_b", "Magic", "MMB,F"},
    {"keybind_left_trigger", "Left Trigger", "Q"},
    {"keybind_right_trigger", "Right Trigger", "R"},
    {"keybind_left_shoulder", "Left Bumper", "Z"},
    {"keybind_right_shoulder", "Right Bumper", "Tab"},
    {"keybind_dpad_up", "D-Pad Up", "Up,1"},
    {"keybind_dpad_down", "D-Pad Down", "Down,2"},
    {"keybind_dpad_left", "D-Pad Left", "Left,3"},
    {"keybind_dpad_right", "D-Pad Right", "Right,4"},
    {"keybind_lstick_press", "Left Stick Click", "C"},
    {"keybind_rstick_press", "Right Stick Click", "V"},
    {"keybind_start", "Pause", "Escape,Return"},
    {"keybind_back", "Back", "M"},
};

// The mouse moves the camera, so these have no keys by default.
inline constexpr const char* kUnboundByDefault[] = {
    "keybind_rstick_up", "keybind_rstick_down", "keybind_rstick_left", "keybind_rstick_right"};

inline constexpr double kSensitivities[] = {0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0};

namespace detail {
inline std::filesystem::path& Path() {
  static std::filesystem::path path;
  return path;
}
}  // namespace detail

// "LMB" -> "Left Click", for labels.
inline std::string KeyDisplayName(std::string_view key) {
  if (key == "LMB") return "Left Click";
  if (key == "RMB") return "Right Click";
  if (key == "MMB") return "Wheel Click";
  if (key == "Escape") return "Esc";
  if (key == "Return") return "Enter";
  return std::string(key);
}

// "E,Space,Shift" -> "E / Space / Shift".
inline std::string KeysDisplay(std::string_view keys) {
  std::string out;
  while (!keys.empty()) {
    size_t comma = keys.find(',');
    std::string_view key = keys.substr(0, comma);
    while (!key.empty() && key.front() == ' ') key.remove_prefix(1);
    while (!key.empty() && key.back() == ' ') key.remove_suffix(1);
    if (!key.empty()) {
      if (!out.empty()) out += " / ";
      out += KeyDisplayName(key);
    }
    keys = comma == std::string_view::npos ? std::string_view() : keys.substr(comma + 1);
  }
  return out.empty() ? "None" : out;
}

inline std::string CurrentKeys(const char* cvar) {
  return rex::cvar::GetFlagByName(cvar);
}

inline double CurrentSensitivity() {
  try {
    return std::stod(rex::cvar::GetFlagByName("mnk_sensitivity"));
  } catch (...) {
    return 1.0;
  }
}

inline bool ReduceFlashing() {
  return rex::cvar::GetFlagByName("metal_reduce_flashing") != "false";
}

// Writes every action's keys and the mouse sensitivity.
inline void Save() {
  if (detail::Path().empty()) {
    return;
  }
  toml::table keybinds;
  for (const Action& action : kActions) {
    keybinds.insert(action.cvar, CurrentKeys(action.cvar));
  }
  toml::table mouse;
  mouse.insert("sensitivity", CurrentSensitivity());
  toml::table display;
  display.insert("reduce_flashing", ReduceFlashing());
  toml::table root;
  root.insert("keybinds", std::move(keybinds));
  root.insert("mouse", std::move(mouse));
  root.insert("display", std::move(display));
  std::filesystem::path temporary = detail::Path();
  temporary += ".tmp";
  {
    std::ofstream out(temporary, std::ios::binary | std::ios::trunc);
    out << "# Keyboard and mouse controls, set from the Controls menu.\n" << root << "\n";
  }
  std::error_code error_code;
  std::filesystem::rename(temporary, detail::Path(), error_code);
}

inline void SetKeys(const char* cvar, std::string_view keys) {
  rex::cvar::SetFlagByName(cvar, keys);
  Save();
}

inline void SetSensitivity(double sensitivity) {
  rex::cvar::SetFlagByName("mnk_sensitivity", std::to_string(sensitivity));
  Save();
}

inline void SetReduceFlashing(bool on) {
  rex::cvar::SetFlagByName("metal_reduce_flashing", on ? "true" : "false");
  Save();
}

inline void ResetToDefaults() {
  for (const Action& action : kActions) {
    rex::cvar::SetFlagByName(action.cvar, action.keys);
  }
  rex::cvar::SetFlagByName("mnk_sensitivity", "1.0");
  Save();
}

// Turns keyboard and mouse on and sets each action from controls.toml, or its
// default. `seed` sets a cvar only if nothing (fable_2.toml, environment, command
// line) has set it already.
template <typename Seed>
void Load(const std::filesystem::path& path, Seed&& seed) {
  detail::Path() = path;
  toml::table root;
  if (std::filesystem::exists(path)) {
    try {
      root = toml::parse_file(path.string());
    } catch (const toml::parse_error& error) {
      REXSYS_WARN("[controls] {} could not be read: {}", path.string(), error.description());
    }
  }
  seed("mnk_mode", "true");
  seed("mnk_mouse", "true");
  for (const Action& action : kActions) {
    std::string keys = root["keybinds"][action.cvar].value_or(std::string(action.keys));
    seed(action.cvar, keys);
  }
  for (const char* cvar : kUnboundByDefault) {
    seed(cvar, "");
  }
  if (auto sensitivity = root["mouse"]["sensitivity"].value<double>()) {
    seed("mnk_sensitivity", std::to_string(*sensitivity));
  }
}

// Display settings live in the GPU plugin, so they're applied once it's loaded.
template <typename Seed>
void LoadDisplay(Seed&& seed) {
  if (detail::Path().empty() || !std::filesystem::exists(detail::Path())) {
    return;
  }
  toml::table root;
  try {
    root = toml::parse_file(detail::Path().string());
  } catch (const toml::parse_error&) {
    return;
  }
  if (auto reduce = root["display"]["reduce_flashing"].value<bool>()) {
    seed("metal_reduce_flashing", *reduce ? "true" : "false");
  }
}

}  // namespace fable2::controls
