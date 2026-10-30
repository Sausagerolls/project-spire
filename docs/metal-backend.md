# Native Metal GPU backend (macOS)

Status: in progress, on the `metal-backend` branch. The Vulkan backend (through
MoltenVK) stays the default until the Metal backend renders games correctly.

Select it with `--gpu_backend=metal` (the `gpu_plugin` stays `xenos`).

## Why

On Apple Silicon the Vulkan backend runs through MoltenVK. Measured with Fable II
on an M1 (see the Mac port notes), the remaining costs that a native backend can
remove are:

- MoltenVK re-records every command: the backend records into its own deferred
  command buffer, replays it into a VkCommandBuffer, and MoltenVK encodes that into
  Metal at vkQueueSubmit. About 30% of the GPU command thread.
- Descriptor sets are emulated: about 4,000 descriptor set writes per frame, each
  turned into Metal argument-buffer or binding work.
- Guest memory is a separate GPU buffer kept coherent by page-level invalidation and
  uploads (and the global lock traffic that goes with them). On Apple Silicon the
  memory is unified, so the GPU can read and write the guest physical memory
  directly.
- Render pass control: MoltenVK decides when a Metal render pass ends or restarts
  and which load and store actions are used.

The shaders stay the same: Xenos microcode is translated to SPIR-V by the shared
`SpirvShaderTranslator`, then to MSL with SPIRV-Cross, which this backend drives
itself (so the resource binding layout is ours, with no descriptor emulation).

## Design

- `src/ui/metal/`: `MetalProvider` (MTLDevice, command queue), `MetalPresenter`
  (CAMetalLayer surface, guest output mailbox textures, guest output effects),
  `MetalImmediateDrawer` (ImGui and other UI drawing).
- `src/graphics/metal/`: `MetalGraphicsSystem`, `MetalCommandProcessor`, and the
  Metal versions of the shared memory, primitive processor, pipeline cache, render
  target cache and texture cache, following the structure of the Vulkan backend.
- Shared memory: the guest physical memory (512 MB, host-page aligned) is wrapped
  with `newBufferWithBytesNoCopy`, so no uploads and no CPU-side page validity
  tracking are needed for GPU reads. GPU writes (resolves, memexport) land in guest
  memory directly. Watches that invalidate textures on CPU writes are still needed.
- Shaders: guest shaders and the SPIR-V utility shaders already in the tree
  (resolves, texture loads, guest output, immediate drawing) are converted with
  SPIRV-Cross to MSL and compiled with `newLibraryWithSource`, cached by hash.
- Commands are encoded directly into MTLCommandBuffers: one render command encoder
  per host render pass, compute and blit encoders between them.

## Phases

1. Device, presenter, immediate drawer, and a command processor that parses PM4 and
   presents (no drawing). The game runs with the UI overlay on a black screen.
2. Shared memory, primitive processor, shader translation and pipelines, draws
   into host render targets without EDRAM aliasing.
3. Render target cache with EDRAM ownership transfers, resolves, clears.
4. Texture cache (texture loads, samplers), guest output presentation.
5. Memexport, occlusion queries, tessellation (as triangle grids), gamma ramp.
6. Performance: render pass merging, load/store actions, pipeline caching on disk.
