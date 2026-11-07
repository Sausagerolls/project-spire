# What we know about the game's code

Learned while building Project Spire on macOS. Addresses are guest (PowerPC) addresses in the GOTY
USA/Europe build; generated functions are named after them (`sub_82582E50`), and a
function can be overridden by defining it `extern "C"` in the game project and calling
`__imp__<name>` for the original.

## Menus (GameFace + Lua)

- All menus are GameFace presentations (`.bgf` in `data/guiscripts.bnk`) with an
  expandable menu written in Lua (`scripts/gameface/expandablemenu/*.lua`, compiled
  Lua 5.1, little-endian, float numbers). `g_Menu` is the menu table.
- C++ runs Lua on a GUI element with `ProcessAndVcallAndProcess16_823F8908(code String,
  element)`; the code is text such as `g_Menu:SpawnButton()`. Hooking it shows every
  menu action (`FABLE2_LUA_LOG=1` logs them).
- Parameters go through element attributes, set with
  `ProcessAndProcessAndProcess26_8259D6C8(lua engine, key String, value String, element)`:
  `String1..4`, `Float1..4`.
- Main menu: built by `sub_826CA6E0`, items added with
  `ProcessAndProcessAndProcess2440_826CB808` (fires `g_Menu:SpawnButton()`),
  selections arrive by name at `ProcessAndProcessAndProcess2446_826C81A0`. Lua engine:
  `*(*(*(*(0x83496928)+8)+80)+40)`.
- In-game menus (pause): items added with `sub_824083C0`; Lua engine
  `*(*(0x834968A4)+40)`. The pause Options page is filled by Lua
  (`g_Menu:SetPopulationTable`, parent attribute `MenuPopulationScript` = `OptionsMenu`).
- Relabel an item: set `String1` = item name, `String2` = label, run
  `g_Menu:RefreshButtonText()`, then call vtable +12 on the element and vtable +16 on
  the object that returns (main menu).
- The pause Options screen's buttons go to `sub_82582E50(screen, button, pressed)`;
  A is 36. With no panel open it reads the highlighted item with
  `sub_8259DB00(screen, out)`: type at +0, String name at +8, label at +12, and opens
  the panel for type - 70. The added settings are handled before that.
- `game/src/native_gpu/options_menu.cpp` has all of this working: Options and Controls in
  the main menu, Frame Rate / Reduce Flashing / Mouse Sensitivity and a Controls
  submenu (controller layout + key bindings) in the pause menu.
- A third menu level in the main menu opens to a blank row: keep settings two levels
  deep there; settings with several values are one item that steps.

## Prompt icons

- `data/art/gui/gui_textures.bnk`: zlib TOC (big-endian: count, then name length,
  name, offset from 0x8000, size). `Art\GUI\Controller\icon_button_{a,b,x,y}.tex` are
  64x64 ARGB, tiled (Xenos 2D tiling), after a 4-byte size: their texture hashes are
  the XXH3 of those bank bytes.
- Other controller icons are Bink-compressed (header format 0x27); identified by the
  XXH3 of their decoded guest data (`metal_log_texture_hashes=true` dumps them):
  LT `675A49C07D8610CE` (32), `D50ABA1873F4DD1B` (64), `DC53FC27CDB38059` (32);
  D-pad `0574501F949C2CD6` (64), `3C88BE8AD6189A55` (32).
- Gem sheet `Art\GUI\Persistant\abyx.tex` decodes to `BD011766CAD4A839` (256x256
  DXT5): A, B, Y, X in 64x64 cells, lit row then dim row, rings below.
- Front-end menu atlas `82D3519765AD2444` (512x512 DXT5): A gem centre (35, 397)
  r 22, B gem (67, 217) r 21.
- `game/src/input/mac_prompts.cpp` replaces all of these with keycaps while the keyboard
  and mouse are in use (`rex::input::GetInputMode()`), and the originals while a
  gamepad is.

## Input

- Keyboard and mouse use the SDK's MnK driver (`keybind_*` cvars, `mnk_mode`,
  `mnk_mouse`, `mnk_sensitivity`), seeded with Fable defaults and saved in
  `user/controls.toml` (`game/src/input/mac_controls.h`).
- The front end's per-frame input poll is `FrontMenu_PollEventQueue` (0x82185C90); it
  runs during gameplay too.
- Menus' Lua runs `g_Menu:*` every frame while open and `GUI:OnExit()` when closed:
  that's how the menu mouse knows a menu is open (`game/src/input/mac_menu_mouse.cpp`).
- Menu lists scroll under a fixed highlighted row at y 192 (720p), rows 58.6 apart,
  Back bar at x 215-415, y 592-640.

## Rendering facts

- The game is GPU-bound. Fable's frame rate cap comes from `guest_vblank_hz`
  (2x the fps) and `vsync`; the Frame Rate option sets them.
- White flash cuts in the title video and strobing spell effects are game content;
  `metal_reduce_flashing` limits brightness rises.
- Native point sprites made snow fall upward (`metal_native_points` off); the Vulkan
  backend handles points its own way, check snow.

## Known bugs

- Rare crash or hang in `Pool_AcquireNode_83230688` (allocator free list link of 1 or
  9: freed memory overwritten). Not Metal-specific. Diagnostics: the SDK logs guest
  registers on the first unhandled guest access fault.
- Some textures' hashes may differ by build or run if they load before the game
  finishes writing them; log `[prompts] icon-sized texture` lines to check.

## Golden objective trail flicker (fixed on Metal, SDK commit 562e853)

The trail is CPU-built billboard particles (vertex shader 29B6506FBACEB93A, gold
tint in c116), not the 4096-point draws (snow). The game draws it either into the
main target or into a half-resolution 8888 buffer (EDRAM 09000230, resolved to
12BEF000) that the composite adds; the camera angle picks the path, so a broken path
flickers. On the half-res path it failed depth everywhere:

1. With native surfaces, the runtime's clears (utility draws, prerecorded lists) set
   the RB_* registers directly and hit the last hook-reported surface. Choose render
   targets from the registers at every draw (GetRegisterNativeSurface).
2. The runtime clears 352 of 360 rows through a 4x layout at half the pitch
   (RB_SURFACE_INFO 04820118), the same EDRAM as the 1x surface: apply such clears to
   the 1x textures (ClearAliasedSurfaces, metal_aliased_clears).
3. oDepth on D24FS8 surfaces must be scaled like interpolated depth (0.5): use
   DepthStencilMode::kFloat24Rounding when the shader writes depth.

Also: memexport-only draws must run (else no trail), and point sprites must be
emulated as quads (native points gave dotted trails and upward snow).
