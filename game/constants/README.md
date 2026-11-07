# Supported game versions

`game_versions.json` lists the disc executables Project Spire accepts: their SHA-256,
name, language and the files that tell the editions apart. It holds no game content.

After editing it, run `python3 tools/generate_game_versions.py` to regenerate
`game_versions.h` (used by the game) and `game_versions.cmake` (used by the build),
and commit them together. CMake refuses to configure while they are stale.

`requiredFiles` must all exist. A rejection rule matches only when all `rejectFiles`
and `rejectDirectories` exist. A compatible hash alone is not proof that the code
matches: a new entry needs its own testing before `compatible` is set.
