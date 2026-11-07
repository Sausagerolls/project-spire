# Project Spire: notes for Claude Code

Fable II recompiled to run natively (macOS with Metal; Steam Deck in progress). See
`README.md` for the layout and `docs/game-notes.md` for what is known about the
game's code. Steam Deck work: `steamdeck/CLAUDE.md`.

## Rules

- Never commit, upload or package game data or anything made from it: `default.xex`,
  `data/`, `game/generated/default/`, builds, captures of game textures. The player
  supplies their own disc.
- One game instance at a time (`pgrep -x fable_2` first): two can exhaust memory.
- Commit locally when a piece of work is done; push only when asked.
- SDK changes are committed inside `sdk/` (branch `rexglue-sdk-metal`), then the
  submodule pointer in this repository.
- The user judges visuals by eye: compare only the same scene.
