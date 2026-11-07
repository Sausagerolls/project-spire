# Plan: Project Spire on Steam Deck

Goal: the player's own Fable II disc image goes in, a native Linux x86-64 build of
the game comes out, built on the Deck itself, and it runs from Gaming Mode with the
Deck's controls. Same rules as the Mac version: no game data, game code or builds are
distributed; everything game-derived is made on the player's machine.

## What carries over

Most of the work so far is not Mac-specific.

| Part | Status for Linux |
|---|---|
| Recompiled game code (`rexglue codegen` output) | Host-independent C++; `game/CMakePresets.json` has the `deck-release` preset |
| SDK runtime, kernel, file system, audio, SDL input | Cross-platform (SDL3); `surface_gnulinux.cpp` exists |
| GPU | SDK's Vulkan backend (the Xenia-derived one), native on the Deck's RADV driver, no MoltenVK |
| Options and Controls menus, pause menu settings (`game/src/native_gpu/options_menu.cpp`) | Platform-independent: guest code and the menus' own Lua |
| Key bindings, input-mode switching, MnK driver, key capture | Platform-independent (SDK) |
| Texture replacement hook, file read hook | Hook API is shared; only the Metal texture cache implements it so far |
| Prompt keycaps, menu cursor (`mac_prompts.cpp`, `mac_menu_mouse.cpp`) | Drawn with Core Graphics: needs a portable drawer |
| Reduce Flashing | Metal swap shader: needs a Vulkan version |
| Setup toolkit (`spire_setup.sh`, `spire_disc.py`, `game_versions.json`) | Bash and Python: portable, with a Linux toolchain |
| Project Spire launcher app | SwiftUI: needs a Linux front end |

What we learned about the game that applies unchanged:
- Menus are GameFace presentations driven by Lua; `g_Menu:RefreshButtonText()`,
  `SetPopulationTable` wrapping and the Options screen's A handler (`sub_82582E50`)
  are how settings are added natively.
- Prompt icons: A/B/X/Y are raw tiled ARGB in `gui_textures.bnk` (hashes from the bank
  bytes); the others are Bink-compressed and identified by decoded hash
  (`metal_log_texture_hashes`); the menu gems are in the `abyx` sheet and the front-end
  atlas `82D3519765AD2444`.
- The title video's white flash cuts and the spell strobes are game content; the
  brightness limiter is the fix.
- The rare `Pool_AcquireNode` corruption (freed memory overwritten) is a game-side or
  runtime bug, not Metal's: it will follow us to Linux until it's found.

## Deck specifics

- **CPU:** Zen 2, 4 cores / 8 threads. Build with `-march=znver2`.
  The game's own threads are fine; the GPU command processor is the hot one.
- **GPU:** RDNA 2, about 1.6 TFLOPs, compared with about 2.6 for the M1. The game is
  GPU-bound on the M1 already (around 40–48 fps at our test spot), so expect 30–40 fps.
  The Deck's 40 Hz display mode matches the Frame Rate option's 40 FPS setting; make
  40 the Deck's default.
- **Memory:** 16 GB shared with the GPU, so the same one-instance rule applies. The
  guest memory mapping uses `memfd`/`shm` the same way (4 KB pages on x86 rather
  than 16 KB, which only makes the mapping code simpler).
- **Display:** 1280x800 (16:10). The game renders 1280x720: start letterboxed;
  later, try a 16:10 viewport patch or the backend's resolution scaling.
- **Input:** Steam Input presents the Deck as an Xbox pad through SDL, so the gamepad
  prompts show by default, and the input-mode switch already handles a keyboard and
  mouse in Desktop Mode or docked. Touchscreen taps can drive the same menu pointer
  logic as mouse clicks.
- **Storage:** a microSD card or the internal drive. The build needs about 15 GB at
  peak and about 7 GB after it finishes.

## Phases

### 1. Linux desktop build (x86-64, a regular Linux PC or the Deck in Desktop Mode)
- Build the SDK (`linux-amd64` preset, Release) and the game (`deck-release`) with clang. Fix
  Win32/Apple-only code paths (28 files use `_WIN32`; most are diagnostics that can
  be compiled out).
- Run on the Vulkan backend and compare with the Mac build scene by scene (same save,
  same spots; the remote-control screenshot tool works on Linux).
- Port the SDK Metal fixes that were bugs rather than Metal-specific, such as the shm
  unlink on creation, which is already shared code.
- Milestone: boots to gameplay, saves and loads, sound works.

### 2. Shared feature parity
- Texture replacement in `VulkanTextureCache` (same hook, same input-mode reload).
- Reduce Flashing in the Vulkan presenter or swap (same three-step shader).
- Replace Core Graphics in the prompts and cursor with a portable rasterizer: render
  the keycaps with stb_truetype and a bundled open font (or the game's own font from
  its data at runtime), into the same RGBA buffers. Keep the drawing code in one
  shared file, with the Mac using the same path, so the keycaps look identical.
- Move `controls.toml` and the user folder to `~/.local/share/ProjectSpire/user`.
- Milestone: menus, keycaps, gamepad prompts, rebinding and flashing option all work.

### 3. Deck performance
- Profile with RADV tools (`RADV_DEBUG`, `MANGOHUD`, GPU trace) at the same test spot.
- Pipeline cache on disk plus background pipeline compiles, as on Metal (Vulkan's
  pipeline libraries on RADV make this cheaper); no Steam shader pre-caching for
  non-Steam games, so first-run hitches have to be handled by the game itself.
- Port the GPU wins that applied on Metal, where the Vulkan backend lacks them:
  deferred clears into load ops, resolve snapshots instead of memory round trips.
- Tune for 40 fps at the Deck's 15 W TDP.
- Milestone: steady 30 fps everywhere, 40 fps in most places.

### 4. Launcher for Linux
"Same launcher system" means the same toolkit and flow: choose disc image, check it,
extract, translate, compile, install, then Play. Only the front end changes.

- **Front end:** a small native app made with SDL3 and Dear ImGui (both already in the
  SDK), styled like Project Spire and usable with the Deck's controls and touchscreen,
  so it works in Gaming Mode. It runs `spire_setup.sh` and reads the same
  `STEP`/`PROGRESS`/`ERROR`/`DONE` lines the Mac app reads. It can also add the
  installed game to Steam as a non-Steam shortcut, with artwork, via Steam's
  `shortcuts.vdf`.
- **Packaging:** a Flatpak (preferred on SteamOS, whose root file system is
  read-only) or an AppImage, containing the launcher, the toolkit, the SDK, CMake,
  Ninja and a clang/lld toolchain. SteamOS has no compiler, so the toolchain has to
  ship in the package (about 400 MB).
- **Setup on the Deck:** `spire_setup.sh` gains a Linux branch: toolchain paths,
  `nproc`, free space with `df`, memory from `/proc/meminfo`, and `-march=znver2`.
  Expected build time is 30–45 minutes with 4 jobs. Keep the screen on and show that
  the build can be left running; resume from the last finished step if interrupted.
- **Install layout:** unchanged (`game/`, the game binary, `user/`, `spire.json`), in
  `~/.local/share/ProjectSpire` or on the SD card.
- **Permissions:** the Flatpak needs access to the disc image's folder (portal file
  picker) and the install folder.
- Milestone: from a fresh Deck, download the launcher, pick the ISO, wait, then Play
  from the Steam library in Gaming Mode.

### 5. Polish
- Deck controls by default (gamepad prompts; the trackpads as the menu pointer).
- Suspend and resume: the audio and GPU must survive the Deck sleeping.
- Battery: a 30 fps option for longer play.
- Steam artwork for the shortcut, from the Project Spire icon.

## Risks

- **Vulkan backend correctness for this game.** The first MoltenVK run on the Mac
  showed flicker; native RADV should be better, but Phase 1 has to establish it.
- **Performance.** The Deck's GPU is weaker than the M1's. The Metal fixes were what
  took the M1 to 40+ fps; the Vulkan backend needs equivalents.
- **Build on the device.** A 30–45 minute compile on battery is slow; the launcher
  should recommend plugging in and use a jobs count that keeps 16 GB from swapping.
- **The allocator corruption crash**, until it's root-caused.

## Order of work

Phase 1 first, on a Linux PC if one is available (faster iteration than the Deck),
then the Deck in Desktop Mode. Phases 2 and 4 can run in parallel once the game boots.
Phase 3 needs the Deck.
