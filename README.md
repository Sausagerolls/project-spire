# Project Spire

Fable II, rebuilt to run natively on Apple silicon Macs, from your own disc.

Project Spire takes the Xbox 360 game's executable from a disc image you own,
translates its PowerPC code to C++ ahead of time, and compiles that on your Mac
together with a runtime and a Metal renderer. The result is a native arm64 app; there
is no emulator running underneath it.

**No game data is included or distributed, and none ever will be.** The repository and
the release contain only Project Spire's own code and tools. The game's code and files
are produced on your machine, from your disc, and stay there.

## Using it

1. Download `Project-Spire-<version>-macOS.zip` from
   [Releases](https://github.com/Sausagerolls/project-spire/releases) and unzip it.
2. Open **Project Spire**. The first time, right-click it and choose **Open** (the app
   is signed ad hoc, not notarised).
3. Choose a disc image (`.iso`) of **Fable II Game of the Year** (USA/Europe; the
   German GOTY release is also accepted) and an install location, then click
   **Build Game**. Building takes a while and needs about 15 GB free, 7 GB after.
4. Click **Play**.

Needs: a Mac with Apple silicon, macOS 14 or later, and Apple's Command Line Tools
(the app offers to install them).

## What it adds

- A native Metal renderer, with frame rate options (30, 40, 60, 90 fps or uncapped).
- Keyboard and mouse: mouse look, rebindable keys in the game's own Options menu and
  pause menu, a menu pointer, and on-screen prompts that switch between keycaps and
  controller buttons depending on what you're using.
- Reduce Flashing: an accessibility option that limits sudden brightness rises (the
  title video's white cuts, spell strobes).
- Gamepads through SDL (Xbox, PlayStation and others).

## Status

Playable on macOS from start to finish. Known issues:

- A rare crash or hang in the game's allocator (`Pool_AcquireNode`); save often.
- A few controller icons (shoulder buttons, sticks, Start/Back) still show the
  controller graphics while using the keyboard.

A Steam Deck version is in progress: see [steamdeck/](steamdeck/).

## Repository

| Folder | Contents |
|---|---|
| `game/` | The game project: build files, the recompilation manifest, and Project Spire's code (hooks, fixes, menus, input, prompts) |
| `sdk/` | The ReXGlue SDK with Project Spire's changes: the Metal renderer, keyboard and mouse, texture replacement (submodule) |
| `launcher/` | The macOS launcher app and its setup toolkit |
| `steamdeck/` | The Steam Deck port: plan and build scripts |
| `docs/` | Notes on the game's code and the renderer |

## Building from source

Needs Xcode or the Command Line Tools, CMake 3.25+, Ninja and Python 3.

```sh
git clone --recurse-submodules https://github.com/Sausagerolls/project-spire.git
cd project-spire

# The SDK
cmake --preset mac-arm64 -S sdk
cmake --build sdk/out/build/mac-arm64 --config Release
cmake --install sdk/out/build/mac-arm64 --config Release --prefix sdk-install

# Either package the launcher app, which builds the game from a disc image...
launcher/package.sh sdk-install dist

# ...or build the game directly. Put default.xex and data/ from your disc in game/
# first (launcher/toolkit/spire_disc.py extract can copy them from an .iso).
(cd game && ../sdk-install/bin/rexglue codegen fable_2_manifest.toml)
cmake --preset mac-release -S game -DCMAKE_PREFIX_PATH="$PWD/sdk-install" \
  -Drexglue_DIR="$PWD/sdk-install/lib/cmake/rexglue"
cmake --build game/out/build/mac-release
game/out/build/mac-release/fable_2 --game_data_root="$PWD/game"
```

Everything the build produces from the disc (`game/default.xex`, `game/data/`,
`game/generated/default/`, `out/`) is git-ignored. Don't commit or share it.

## Credits

Project Spire builds on others' work; see [CREDITS.md](CREDITS.md).

- The game project began from [himdo/Fable-2-Recomp](https://github.com/himdo/Fable-2-Recomp)
  (MIT), a Windows recompilation of the same executable: its manifest, function
  mappings, and runtime fixes are the base of `game/`.
- [ReXGlue SDK](https://github.com/rexglue/rexglue-sdk), derived from
  [Xenia](https://xenia.jp), does the recompilation and provides the runtime.

Fable II is a trademark of Microsoft. Project Spire is not affiliated with or endorsed
by Microsoft, Lionhead or Xbox Game Studios.

## License

MIT, see [LICENSE](LICENSE). The SDK has its own license (`sdk/LICENSE`).
