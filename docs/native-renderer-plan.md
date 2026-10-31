# Native Metal renderer (D3D-level replacement) — plan

Goal: render Fable II through a host Metal renderer driven by the game's Direct3D
calls, instead of emulating the Xenos GPU (PM4 command stream, EDRAM, resolves).

## Why

The current backends (Vulkan, and the Metal backend in the SDK) emulate the GPU:
every frame the game writes Xenos PM4 packets, the command processor parses them,
and the render target cache emulates the 10 MB EDRAM with ownership transfers,
dumps and resolve copies. That layer costs most of the frame time and is the
source of the timing bugs (fences written before the GPU ran, heap corruption
after ~40 minutes, flicker). Replacing the renderer at the D3D level removes
PM4 parsing, EDRAM emulation and the CPU/GPU fence races.

What stays converted: the game's shaders are Xenos microcode and its textures are
in Xenos (tiled, big-endian) formats. Those are translated once (shader to MSL,
cached on disk; textures untiled when created or unlocked), not per frame.

## Survey (2026-10-31, from generated/default, no game runs)

Tools: `/Volumes/1TB/fable2-mac/tools/survey/` — `index.py` (function index and
call graph -> funcs.jsonl, 60753 functions), `pm4scan.py` (functions that build
PM4 type-3 headers inline -> pm4.txt).

- D3D device core (statically linked Xbox D3D runtime): `0x82B80000`–`0x82BC0000`,
  957 functions, 210 called from outside. Ring buffer init and ME_INIT in
  `sub_82B9BA58` (VdInitializeRingBuffer); present in `MainRenderLoop_82B9CD68`
  (VdSwap, EVENT_WRITE_SHD fences); interrupt setup in `sub_82BA0220`.
- Draw calls are inlined into Lionhead's renderer (Xbox D3D draws are header
  inlines): six functions build DRAW_INDX packets — `sub_82207C30`,
  `ProcessAndProcessAndProcess576_82217EE8`, `sub_8221C9C8`, `sub_8221E0F0`,
  `ProcessAndProcessAndProcess841_8221C518`, `ProcessAndProcessAndProcess876_822060A0`
  — plus DRAW_INDX_2 (immediate indices) in `ProcessAndProcessAndProcess820_821EF988`
  and the runtime's own utility draws (`sub_82B98770`, `sub_82B988C8`,
  `sub_82BA29B8`, `sub_82BA5448`, `sub_82BA5CE8`, `sub_82B9C068`, `sub_82B928A8`;
  likely clears / resolves / fast paths).
- The six draw functions share one prologue of helpers, which flush dirty device
  state to the command buffer before the packet: `8221DF98`, `8221B140`
  (IM_LOAD + SET_CONSTANT: shaders, constants), `822155E0` (SET_CONSTANT),
  `8221C908`, `8221D2E0`, `822B3E40` (WAIT_REG_MEM), `821E8D20` (command
  buffer space), `821D1270`. At that point the device's shadow state holds the
  full draw state — the natural hook point.
- Fences / GPU sync: WAIT_REG_MEM in `821F5F20`, `821F61D0`, `82283530`,
  `822B3E40`, `822C6BA0`, `82B9C7F8`, `82B9CB88`; EVENT_WRITE_SHD in
  `EndFrame_822981F0`, `82BA8170`, `82B9E610`. Occlusion queries: EVENT_WRITE_ZPD
  in `sub_82219418`. Indirect buffers (precompiled command buffers) in
  `ProcessAndProcessAndProcess816_82286248`.

## Approach

Host implementations replace guest functions (the existing hotfunc override
mechanism), in this order:

1. **Device state model.** Reverse the D3D device structure (the shadow of render
   state, fetch constants, shader pointers, stream/index sources, render target
   and depth surfaces, viewport/scissor, shader constants, dirty masks) from the
   draw prologue helpers above. Write a C++ view of it over guest memory.
2. **Draw hook.** Override the draw functions: read the device state, translate
   to Metal (pipeline from shaders + blend/depth/raster state; vertex fetch from
   guest memory; textures from a host texture cache keyed by guest texture
   header), encode the draw. No PM4 written.
3. **Surfaces.** Render targets and depth as plain Metal textures (no EDRAM).
   `Resolve` becomes a copy/format conversion into the destination texture (or
   aliasing when formats match); `Clear` becomes load actions / clear draws.
4. **Present and sync.** Override present (VdSwap path) and the fence functions:
   fences complete on Metal command buffer completion; the GPU identifier and
   frame counter the frame limiter reads are written from completion handlers.
5. **Remaining PM4 users.** Utility draws in the runtime, occlusion queries,
   indirect (precompiled) command buffers, memexport (GPU particles), gamma ramp.
6. **Remove the GPU emulator from the path** once nothing writes PM4 for drawing.

Each step is checked against the current Metal backend's output (screenshots of
the same save at the same spot).

## Constraints

- One game instance at a time (two instances exhausted memory and froze the Mac).
- Memory watchdog on every run; no tracing or building while the game runs.
- No game data or generated code is committed or distributed.
