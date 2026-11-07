// The mouse in the game's menus (macOS).
//
// While a menu is open, mouse look is off and a cursor in the game's colours shows.
// The menus are lists that scroll under a fixed highlighted row, so a click on a
// row presses Up or Down until it's highlighted, then A. The wheel scrolls, and a
// right click or a click on the Back bar presses B. The presses come from a
// synthetic pad merged with the others.
//
// A menu counts as open while its Lua runs (NoteMenuActivity, from the GUI Lua
// hook in src/native_gpu/options_menu.cpp), until its presentation exits.

#pragma once

#include <memory>

#include <rex/input/input_driver.h>

namespace fable2::menumouse {

// Called whenever a menu's Lua (g_Menu) runs.
void NoteMenuActivity();
// When a menu's presentation exits (GUI:OnExit()).
void NoteMenuClosed();

std::unique_ptr<rex::input::InputDriver> CreateDriver(rex::ui::Window* window);

}  // namespace fable2::menumouse
