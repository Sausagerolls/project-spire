# Project Spire launcher (macOS)

Project Spire is a Mac app that builds a native Apple silicon version of Fable II from
your own disc, then starts it. It contains no game data and no game code. Everything
game-derived is made on your Mac from your disc image.

## Using it

1. Install Apple's Command Line Tools if you don't have them. The app offers a button
   for this, which runs `xcode-select --install`.
2. Open Project Spire, choose your disc image (`.iso`) and an install location, then
   click **Build Game**.
3. When the build finishes, click **Play**. You can delete or unplug the disc image.

Setup steps:

1. Checks the Mac: tools, free space (about 15 GB at peak) and memory.
2. Checks the disc. Only the supported releases listed in `game/constants/game_versions.json`
   are accepted. Nothing is copied from any other disc.
3. Copies `default.xex` and `data/` from the disc.
4. Translates the game code with `rexglue codegen`.
5. Compiles it with the system clang, using CMake and Ninja from the app.
6. Installs `Project Spire Game.app` and removes the build files.

Install layout (default `~/Library/Application Support/Project Spire`):

| Path | Contents |
|---|---|
| `game/` | `default.xex` and `data/` from the disc |
| `Project Spire Game.app` | the native game. It finds `game/` and `user/` beside itself |
| `user/` | settings (`fable2_config.toml`, `fable_2.toml`), saves, shader cache and logs |
| `spire.json` | which release was installed and when |
| `setup.log` | output of the last setup |

Rebuilding from the disc replaces the game app and keeps `user/`.

If the disc image or the install location is on an external drive, macOS asks once
whether Project Spire, and later Project Spire Game, may access files on a removable
volume. Click **Allow**. Until then setup or the game waits. Because the app is signed
ad hoc, macOS asks again after each rebuild.

## Building the app

```sh
launcher/package.sh <sdk-install-dir> <out-dir>
```

This needs Xcode (`swiftc`, `actool`), plus `cmake` and `ninja` on `PATH`. Their files
are copied into the app. The SDK is `sdk/` built as a macOS arm64 Release and installed with
`cmake --install` (see the main README). Only files tracked by git go into the app's
copy of the game project (`git archive` of `game/`), so commit changes before
packaging.

`toolkit/spire_setup.sh` can also run without the app:

```sh
"Project Spire.app/Contents/Resources/toolkit/spire_setup.sh" <image.iso> <install-dir>
```

Set `SPIRE_JOBS` to override the number of compile jobs, which defaults to one per
3 GB of memory.

## Icon

`Icon/AppIcon.icon` is an Icon Composer file. `actool` compiles it to `Assets.car` for
macOS 26 and `AppIcon.icns` for older systems.

## Distribution

The app is signed ad hoc. Without a Developer ID signature and notarisation, macOS
blocks the first open of a downloaded copy. Right-click the app and choose **Open**
to allow it.
