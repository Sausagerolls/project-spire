# Credits

## Borrowed work

**Fable-2-Recomp** by Himdo and contributors — https://github.com/himdo/Fable-2-Recomp
(MIT). A Windows recompilation of Fable II. Project Spire's `game/` started as a copy of
it and keeps its recompilation manifest (`fable_2_manifest.toml`, function names and
switch tables), the game version catalogue, the runtime patches and hooks in
`game/src/core`, the diagnostics in `game/src/diagnostics` and the debug Lua scripts.
Its Windows launcher, packaging and tooling are not included here.

**ReXGlue SDK** by Tom Clay and contributors — https://github.com/rexglue/rexglue-sdk.
The recompiler and runtime. `sdk/` is a copy of it with Project Spire's changes on
top (the Metal renderer and the other changes listed in its history). Its license is
in `sdk/LICENSE`.

**Xenia** — https://xenia.jp. The ReXGlue runtime and the GPU command translation are
derived from the Xenia Xbox 360 emulator (BSD 3-Clause).

**toml++** by Mark Gillard — https://github.com/marzer/tomlplusplus (MIT), in
`game/thirdparty/tomlplusplus`.

## Project Spire's own work

- `sdk/`: the native Metal backend (command processor, shaders translated to MSL,
  render targets, texture cache, presenter), the Reduce Flashing limiter, keyboard and
  mouse with key capture and a menu pointer, texture replacement and input-mode
  tracking, and macOS fixes.
- `game/`: the macOS build; Options, Controls and pause menu settings in the game's
  own menus (`src/native_gpu/options_menu.cpp`); key bindings (`src/input/mac_controls.h`);
  keycap prompts (`src/input/mac_prompts.cpp`); the menu mouse
  (`src/input/mac_menu_mouse.cpp`).
- `launcher/`: the Project Spire app and its setup toolkit, including the disc reader.
- `steamdeck/`: the Steam Deck port.

## Trademarks

Fable, Fable II, Xbox and Xbox 360 are trademarks of Microsoft. Project Spire is not
affiliated with or endorsed by Microsoft, Lionhead or Xbox Game Studios.
