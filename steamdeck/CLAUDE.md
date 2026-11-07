# Project Spire on Steam Deck: instructions for Claude Code

You are continuing the port of Project Spire to the Steam Deck (SteamOS 3, Linux
x86-64, AMD RDNA 2 GPU through Vulkan/RADV). The game already runs natively on macOS
with a Metal renderer. Read `steamdeck/PLAN.md` for the phases and
`docs/game-notes.md` for what is known about the game's code.

## Rules

- **Never distribute game data, game-derived builds or generated code.** The player
  supplies their own disc image; everything game-derived (extracted files,
  `game/generated/default/`, builds) is made on the player's machine and stays there.
  Don't commit any of it, don't upload it, don't put it in packages.
- One game instance at a time (16 GB shared memory). Check `pgrep -x fable_2` first.
- Commit locally when a piece of work is done; push only when the user asks.
- The user judges visuals by eye: describe what changed and ask them to look, and
  compare only the same scene. Use the screenshot tool for your own checks.
- Keep replies short; don't narrate each step.

## Layout

```
game/        the game project (CMake, src/, manifest); codegen output in generated/default
sdk/         the ReXGlue SDK with Project Spire's changes (submodule, branch rexglue-sdk-metal)
launcher/    the macOS launcher; launcher/toolkit has the portable disc reader and setup script
steamdeck/   this port: plan and scripts
docs/        notes on the game and the renderers
~/spire/     outside the repo: game/ (the player's disc files), sdk-install/
```

SDK changes are committed in `sdk/` (branch `rexglue-sdk-metal`) and then the
submodule pointer is committed in the main repository.

## Building

Everything builds inside a distrobox container (SteamOS's root file system is
read-only and has no compiler): `steamdeck/scripts/deck_setup.sh` creates it and
fetches the submodules; `steamdeck/scripts/build.sh` builds the SDK and the game;
`steamdeck/scripts/run.sh` starts the game.

The game's code is translated from the player's `default.xex` by `rexglue codegen`
(about a minute) and compiled (332 Ninja steps; the generated code is large, so use at
most 4 jobs on the Deck, about 2 GB of memory each).

## Testing

- `game/tools/fable2_control.py` drives a remote gamepad and takes screenshots over
  localhost: `python3 -I game/tools/fable2_control.py screenshot out.png`,
  `press A --hold 150`, `game-state`, `cvar NAME VALUE`. The build script enables it
  (`FABLE2_ENABLE_REMOTE_CONTROL=ON`).
- Frame captures for flicker checks: `--metal_capture_frames=N` exists only on Metal;
  add the Vulkan equivalent when needed.
- Logs: `<exe folder>/logs/`.
- Remote input counts as a gamepad for the prompt switching.

## What's Mac-only today (see PLAN.md phase 2)

- `game/src/input/mac_prompts.cpp`, `game/src/input/mac_menu_mouse.cpp`: Core Graphics
  drawing of keycaps and the cursor. The logic is portable; replace the drawing.
- Texture replacement and input-mode reloads: implemented in the SDK's Metal texture
  cache (`sdk/src/graphics/metal/texture_cache.mm`, `TryReplaceTexture`,
  `ReloadTexturesForInputMode`); the Vulkan texture cache needs the same.
- Reduce Flashing: Metal swap shader in `sdk/src/graphics/metal/command_processor.mm`
  (`kSwapShaderSource`, `flash_limit_cs`, `flash_scale_cs`).
- `launcher/`: the SwiftUI launcher. Its toolkit (`spire_setup.sh`, `spire_disc.py`)
  is the part to reuse.
