# Project Spire on Steam Deck

Work in progress: building and running the game natively on a Steam Deck (SteamOS,
Linux x86-64, Vulkan on RADV). See `PLAN.md` for the phases. As on the Mac, you supply
your own disc image; nothing game-derived is ever distributed.

## Setting up

In Desktop Mode, open Konsole:

```sh
git clone --recurse-submodules https://github.com/Sausagerolls/project-spire.git ~/project-spire
cd ~/project-spire
steamdeck/scripts/deck_setup.sh                    # container with the tools, submodules
steamdeck/scripts/extract_disc.sh ~/Fable2.iso     # your own disc image -> ~/spire/game
steamdeck/scripts/build.sh                         # SDK, code translation, game (30-45 min)
steamdeck/scripts/run.sh                           # play
```

Plug the Deck in for the build; it compiles a lot of generated code. The disc files
and the installed SDK go in `~/spire` (set `SPIRE_HOME` to change it); build output
goes in `game/out/` and `sdk/out/`. All of it is git-ignored.

To continue the port with Claude Code, run `claude` in the repository; it reads
`steamdeck/CLAUDE.md` for the Deck work.

## Files

| File | What it is |
|---|---|
| `CLAUDE.md` | Context and rules for Claude Code on the Deck |
| `PLAN.md` | The port plan, in phases |
| `scripts/` | Setup, disc extraction, build, run |
| `../docs/game-notes.md` | What's known about the game's code (menus, prompts, input, rendering) |
