# Project Spire: Steam Deck port

This folder is everything needed to continue the Fable II native port on a Steam
Deck with Claude Code. It contains no game data: you supply your own disc image.

## Moving it to the Deck

1. Copy this whole folder to the Deck as `~/spire` (USB stick, network share, or
   `scp`). If it came as `steamdeck-port/` with a `repos/` folder inside, copy that.
2. On the Deck, switch to Desktop Mode and open Konsole.
3. Install Claude Code (https://claude.com/claude-code), then `cd ~/spire` and run
   `claude`. It reads `CLAUDE.md` here for the project's context.

## First build (Claude Code can do these for you)

```sh
cd ~/spire
scripts/deck_setup.sh                    # container with the tools, sources
scripts/extract_disc.sh ~/Fable2.iso     # your own disc image -> ~/spire/game
scripts/build.sh                         # SDK, code translation, game (30-45 minutes)
scripts/run.sh                           # play
```

Plug the Deck in for the build; it compiles a lot of generated code.

## Files

| File | What it is |
|---|---|
| `CLAUDE.md` | Context and rules for Claude Code |
| `PLAN.md` | The port plan, in phases |
| `GAME_NOTES.md` | What's known about the game's code (menus, prompts, input) |
| `scripts/` | Setup, disc extraction, build, run |
| `repos/` | Git bundles of the game project and the SDK (newest copies) |
