# Project Spire on Steam Deck: instructions for Claude Code

You are continuing a port of Fable II (Xbox 360) to run natively on a Steam Deck
(SteamOS 3, Linux x86-64, AMD RDNA 2 GPU through Vulkan/RADV). The game has already
been ported to macOS on Apple silicon with a native Metal renderer; this folder holds
what's needed to bring it to the Deck. Read `PLAN.md` for the phases and
`GAME_NOTES.md` for what is known about the game's code.

## Rules

- **Never distribute game data, game-derived builds or generated code.** The player
  supplies their own disc image; everything game-derived (extracted files,
  `generated/`, builds) is made on the player's machine and stays there. Don't commit
  any of it, don't upload it, don't put it in packages.
- One game instance at a time (16 GB shared memory). Check `pgrep -x fable_2` first.
- Commit locally when a piece of work is done; push only when the user asks.
- The user judges visuals by eye: describe what changed and ask them to look, and
  compare only the same scene. Use the screenshot tool for your own checks.
- Keep replies short; don't narrate each step.

## Layout on the Deck

```
~/spire/                       this folder (README.md, CLAUDE.md, PLAN.md, ...)
~/spire/src/Fable-2-Recomp     game project (from repos/fable-2-recomp.bundle or GitHub main)
~/spire/src/rexglue-sdk        ReXGlue SDK (from repos/rexglue-sdk.bundle or branch rexglue-sdk-metal)
~/spire/sdk-install            SDK installed with cmake --install
~/spire/game                   the player's extracted disc files (default.xex, data/) - never commit
```

GitHub: https://github.com/Sausagerolls/project-spire (`main` = game project,
`rexglue-sdk-metal` = SDK). The bundles in `repos/` may be newer than GitHub.

## Building

Everything builds inside a distrobox container (SteamOS's root file system is
read-only and has no compiler): `scripts/deck_setup.sh` creates it, clones the
sources and installs the tools; `scripts/build.sh` builds the SDK and the game;
`scripts/run.sh` starts the game. See `README.md`.

The game's code is translated from the player's `default.xex` by `rexglue codegen`
(about a minute) and compiled (332 Ninja steps, the generated code is large: use at
most 4 jobs on the Deck, about 2 GB of memory each).

## Testing

- `tools/fable2_control.py` (in the game project) drives a remote gamepad and takes
  screenshots over localhost: `python3 -I tools/fable2_control.py screenshot out.png`,
  `press A --hold 150`, `game-state`, `cvar NAME VALUE`. The game must be built with
  `FABLE2_ENABLE_REMOTE_CONTROL=ON` (the default for dev builds).
- Frame captures for flicker checks: `--metal_capture_frames=N` exists only on Metal;
  add the Vulkan equivalent when needed.
- Logs: `<exe folder>/logs/` (or `user/logs` in an installed layout).
- Remote input counts as a gamepad for the prompt switching.

## What's Mac-only today (to port, see PLAN.md phase 2)

- `src/input/mac_prompts.cpp`, `src/input/mac_menu_mouse.cpp`: Core Graphics drawing
  of keycaps and the cursor. The logic is portable; replace the drawing.
- Texture replacement and input-mode reloads: implemented in the SDK's Metal texture
  cache (`src/graphics/metal/texture_cache.mm`, `TryReplaceTexture`,
  `ReloadTexturesForInputMode`); the Vulkan texture cache needs the same.
- Reduce Flashing: Metal swap shader in `src/graphics/metal/command_processor.mm`
  (`kSwapShaderSource`, `flash_limit_cs`, `flash_scale_cs`).
- `macos/ProjectSpire`: the SwiftUI launcher. Its toolkit (`spire_setup.sh`,
  `spire_disc.py`) is the part to reuse.
