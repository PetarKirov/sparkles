# Sparkles baseline: vulkan, ui-vulkan and the GPU upload path

What `sparkles:vulkan`, `sparkles:vulkan-wsi` and `sparkles:ui-vulkan` give an image and video library today: a binding over the whole stable `vulkan.h`, a device-memory sub-allocator, a graphics-only device, and one buffer-to-image upload path built for a UI canvas, with nothing yet for compute, transfer queues, timeline semaphores, video queues or zero-copy import.

| Field          | Value                                                                                                                                                                                                                                                                                                                                                                                                        |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Packages       | `sparkles:vulkan` (`libs/vulkan`), `sparkles:vulkan-wsi` (`libs/vulkan-wsi`), `sparkles:ui-vulkan` (`libs/ui-vulkan`), the Vulkan painter of `sparkles:terminal-view` (`libs/terminal-view`)                                                                                                                                                                                                                 |
| Specs read     | `docs/specs/vulkan/memory.md` (`VKM1`-`VKM13`), `docs/specs/ui-vulkan/{SPEC,PLAN,decisions,testing}.md` (`UVK1`-`UVK35`, `UVX1`-`UVX12`), `docs/specs/window-system-integration/SPEC.md` section 10.1, `docs/specs/shaders/PLAN.md` (M10), `docs/specs/ui-skia/canvas-seam-friction.md` (contrast only), `docs/research/vulkan/` (vocabulary)                                                                |
| Status summary | Shipped: binding, dispatch tiers, sub-allocator, 2-D image upload, glyph atlas, canvas, terminal painter. Specified but not built: none of the image/video-relevant items. Not present at all: compute, sync2, timeline semaphores, transfer queue, video, external memory, host image copy. The `vulkan` and `ui-vulkan` specs carry `status: draft` in their front matter; the shaders plan is `accepted`. |
| Last reviewed  | October 27, 2026                                                                                                                                                                                                                                                                                                                                                                                             |

> [!NOTE]
> Every claim below was read in a file or produced by a command in this session (branch `feat/images`; its `HEAD` is an ancestor of `origin/main`, so "shipped" means "on `main`"). Quotes from spec prose are joined across source line breaks and otherwise exact. Where a fact was not checked, the text says "not verified".

---

## What exists today

### Shipped (code on this branch)

**The binding is the real header, not a hand-written subset of types.** `libs/vulkan/src/sparkles/vulkan/vulkan_c.c` defines `VK_NO_PROTOTYPES`, adds the Wayland and XCB (Linux) or Android platform macros, and `#include <vulkan/vulkan.h>`; the D compiler imports it through ImportC. `libs/vulkan/dub.sdl` resolves the include path via `pkg-config` (`libs "vulkan"`) and is a `sourceLibrary`. `VK_ENABLE_BETA_EXTENSIONS` is not defined, so beta-gated declarations are absent. Consequence: every stable extension's structs, enums and `PFN_vk*` typedefs are visible to D code today, including the video structs and the `vk_video/*std*.h` codec headers (the Nix-store header in this shell is `1.4.357.0`, `VK_HEADER_VERSION 357`; whether the flake pin is the same header is not verified). What is missing is not types but dispatch entries and policy.

**Commands are a curated list, not generated from `vk.xml`.** `libs/vulkan/src/sparkles/vulkan/dispatch.d` declares three tiers (`GlobalCommands`, `InstanceCommands`, `DeviceCommands`), each a `CommandSet(extension, names)` list expanded by a `CommandTable` mixin into `PFN_vk*` fields, a `firstMissing`, `complete` and a per-extension `has!"..."`. The module's own text says "The command lists are deliberately small". Device tier today (`deviceSets`): queue submit (`QueueSubmit`, v1), binary `CreateSemaphore`/fences, command pools and buffers, `CmdPipelineBarrier` (v1), image/view/render-pass/framebuffer, `CreateGraphicsPipelines`, pipeline cache, `CmdBeginRenderPass`/`CmdDraw`, buffers and memory (`AllocateMemory`, `MapMemory`, `FlushMappedMemoryRanges`), `CmdCopyBuffer`, `CmdCopyBufferToImage`, `CmdCopyImageToBuffer`, `CmdClearColorImage`, descriptor sets, samplers. Extension sets: `khrSwapchain`, `khrDynamicRendering`, `vkVersion11` (`Get*MemoryRequirements2`), `vkVersion13` (`CmdBeginRendering`). Instance tier adds surface, `extDebugUtils`, `GetPhysicalDeviceFeatures2`, and per-platform surface sets. Other modules: `loader.d` (platform loader), `structure_type.d` (`vkInfo` derives `sType`), `enumerate.d` (`queryVkList`), `result.d` (`VkExpected!T = Expected!(T, VkResult)`), `extensions.d` (`hasExtension`, the portability handshake), `flags.d`, `names.d`, `spirv.d`, `api.d` (`apiVersion10`..`apiVersion14`).

**Device memory sub-allocator.** `libs/vulkan/src/sparkles/vulkan/memory.d` (1089 lines) implements `DeviceMemory(B)` (alias `VulkanDeviceMemory`) over an `isMemoryBackend` seam with `DeviceMemoryBackend` as the real driver and a fake in unit tests. API: `allocate`, `alignedAllocate`, `deallocate`, `deallocateAll`, `owns` (returns `Ternary`), `goodAllocSize`, `flush`, `stats(type)` returning `TypeStats`, `destroy`. `MemoryRequest` carries size, alignment, `typeBits`, required/preferred `VkMemoryPropertyFlags`, `Tiling` (`linear`/`optimal`) and `Dedication`. `MemoryConfig` defaults are a 64 KiB block and 32 MiB device allocation. `FrameArena(B)` is a per-slot bump range with `reset(slot)`. The module doc says "The contract is `docs/specs/vulkan/memory.md` (`VKM1`–`VKM13`)". The bookkeeping uses `UniqueBuffer` from `sparkles:base`.

**Graphics-only device.** `libs/vulkan-wsi/src/sparkles/vulkan_wsi/device.d`: `VulkanDevice.create` (windowed) and `createHeadless` (offscreen, used by tests). `pickCandidates` takes, for each physical device, the first queue family with `VK_QUEUE_GRAPHICS_BIT` (and present support when presenting), and `Candidate.score` ranks discrete 3, integrated 2, virtual 1, other 0. One `VkDeviceQueueCreateInfo` with `queueCount: 1` is created, so there is one `VkQueue` and one family. `ContextRequest.apiVersion` defaults to `apiVersion11`. Device extensions it enables are swapchain (when presenting), portability subset, and dynamic-rendering and imageless-framebuffer plans (`planDynamicRendering`, `planImageless`). It loads and saves a `VkPipelineCache` to a path. Validation and `VK_EXT_debug_utils` are opt-in through `ContextRequest.validation`. `frame.d` owns frame synchronisation (`imageAvailable`, `inFlight` fences, `renderFinished` per swapchain image). `libs/vulkan-wsi/src/sparkles/vulkan_wsi/testing.d` has `HeadlessSession`, a validation-message counter, opt-in by `SPARKLES_VULKAN_READBACK=1`.

**The one upload path (2-D, buffer to image).** `libs/ui-vulkan/src/sparkles/ui_vulkan/`:

- `resources.d`: `GpuBuffer` and `GpuImage`. `GpuImage` is always `VK_IMAGE_TYPE_2D`, `mipLevels: 1`, `arrayLayers: 1`, `VK_IMAGE_TILING_OPTIMAL`, `VK_SHARING_MODE_EXCLUSIVE`, one colour view; the format is a parameter but no format table or plane concept exists.
- `frame_buffers.d`: `FrameBuffers(B)` binds a `VkBuffer` over each `FrameArena` range.
- `upload.d`: `Uploads(B).stage(slot, image, from, pixels, texelBytes, at, extent)` copies into the slot's host-visible arena and flushes; `record` emits, per copy, a v1 `VkImageMemoryBarrier` into `TRANSFER_DST_OPTIMAL`, `vkCmdCopyBufferToImage`, and a barrier to `SHADER_READ_ONLY_OPTIMAL` at the fragment stage. The `transition` helper uses `vkCmdPipelineBarrier` (v1). Copies go out in staged order.
- `canvas.d` `resolveImage`: only two formats are created, `VK_FORMAT_R8G8B8A8_UNORM` (images, placeholder) and `VK_FORMAT_R8_UNORM` (atlas pages). `CanvasConfig.uploadBudget` defaults to `16 << 20` bytes per frame; an image over `facts_.maxImageExtent` returns `tooLarge`; the first upload of a frame is exempt from the budget. Image identity is `(registry, handle, generation)`.
- `glyph_atlas.d`: `GlyphAtlas` of up to four 1024-square `R8` pages, shelf-packed, dirty regions re-uploaded; rasterization is `sparkles:font`'s `rasterizeGlyph`. Decision `UVX12` labels it interim.
- `pipelines.d`: graphics pipelines only; two samplers (`VK_FILTER_NEAREST` for atlases, `VK_FILTER_LINEAR` for images), both clamp-to-edge.

**Pixel sources feeding it are 8-bit RGBA only.** `libs/ui/src/sparkles/ui/image.d` `ImageData.rgba` is documented "8-bit RGBA, row-major, `size.width * size.height * 4` bytes", borrowed not owned, with a `generation` that backends compare. `libs/ui/src/sparkles/ui/png.d` is "the toolkit's one PNG codec" (decode bounded by the declared header, `maxPngPixels = 1UL << 26`). `libs/terminal-view/src/sparkles/terminal_view/vulkan_images.d` (`VulkanImages`) widens gray/RGB layouts to RGBA through `toRgba` and registers into an `ImageRegistry`; `vulkan_painter.d` (`VulkanTerminalPainter`) implements `createTexture`, `updateTextureRows`, `releaseTexture`, `drawTexture` over it.

**Tests.** Memory model tests run on a fake backend (`vulkan.memory.*`); `ui_vulkan.upload.anImageReadsBackAsUploaded` uploads a 64x48 RGBA image plus a patch and reads it back byte for byte on a real driver under the validation layer, skipped unless `SPARKLES_VULKAN_READBACK=1`.

### Specified (spec text exists)

| Spec                                | Status line                              | Notes                                                                                       |
| ----------------------------------- | ---------------------------------------- | ------------------------------------------------------------------------------------------- |
| `docs/specs/vulkan/memory.md`       | `status: draft`, reviewed 2026-10-19     | `VKM1`-`VKM13`; the code in `memory.d` cites it, so the draft label lags the implementation |
| `docs/specs/ui-vulkan/SPEC.md`      | `status: draft`, reviewed 2026-10-19     | `UVK1`-`UVK35`; `UVK22` carries "_Status: planned._"                                        |
| `docs/specs/ui-vulkan/decisions.md` | `status: draft`; `UVX1`-`UVX12` accepted | `UVX12` accepted 2026-10-27 as "interim"                                                    |
| `docs/specs/ui-vulkan/PLAN.md`      | `status: draft`                          | V0, V1, V2, V4, V5 "done"; V3 and V6 "in progress"; V7 "not started"                        |
| `docs/specs/shaders/PLAN.md`        | `status: accepted`                       | M10 "Compute and storage" is "not started"; entry condition M6                              |

### Draft or unmerged

Nothing of this area is unmerged on this branch: `git merge-base --is-ancestor HEAD origin/main` succeeds, and the last commits touching the area (`81176261f feat(ui-vulkan): draw text from the glyph atlas (V3)`, `d77f7893c feat(terminal-view.vulkan_painter): draw the terminal's text on Vulkan`) are on it. The only "draft" in play is the spec front matter above. No branch holding video or compute work was looked for beyond the repository tree; not verified.

### Planned only

- Compute and storage resources for D shaders: `docs/specs/shaders/PLAN.md` M10, "not started". The `@compute(...)` attribute seen in `libs/ui-vulkan/shaders/` and `libs/vulkan-wsi/src/sparkles/vulkan_wsi/triangle_shader.d` is dcompute's spelling for any shader module; those modules are vertex/fragment, and `dispatch.d` has no `CmdDispatch` or `CreateComputePipelines`.
- A pollable fence: a comment in `dispatch.d` says the fence "is what the event-horizon frame clock will export as a pollable sync_fd". No external-fence command is bound and no code in `libs` or `apps` mentions `sync_fd` other than that comment (grep).
- Linear-light blending (`UVX6`), effects (`UVQ1`), Graphite (`UVQ2`), the font library's own glyph cache replacing the interim atlas (`UVX12`), the phone terminal (`V7`).
- Video: `grep` over `libs`, `apps` and `docs/specs` for `KHR_video` and `VideoSession` returns nothing. Video is neither shipped nor specified in the repository.

### Local hardware (from `vulkaninfo`, read-only)

Three devices: GPU0 `AMD Radeon RX Vega (RADV VEGA10)` discrete; GPU1 `AMD Radeon 610M (RADV RAPHAEL_MENDOCINO)` integrated; GPU2 `llvmpipe`. All report API 1.4.318 and `maxImageDimension2D = 16384`.

| Extension / fact                                                                                                                  | GPU0 (discrete) | GPU1 (integrated) | GPU2 (llvmpipe) |
| --------------------------------------------------------------------------------------------------------------------------------- | --------------- | ----------------- | --------------- |
| `VK_KHR_video_queue`, `video_maintenance1/2`                                                                                      | no              | yes               | no              |
| `VK_KHR_video_decode_{h264,h265,av1,vp9}`                                                                                         | no              | yes               | no              |
| `VK_KHR_video_encode_{h264,h265}` (no AV1 encode)                                                                                 | no              | yes               | no              |
| `VK_QUEUE_VIDEO_DECODE_BIT_KHR` / `ENCODE_BIT_KHR` families                                                                       | none            | one each          | none            |
| async compute+transfer family (no graphics)                                                                                       | yes             | yes               | no              |
| `VK_EXT_external_memory_host` (`minImportedHostPointerAlignment = 0x1000`, as reported)                                           | yes             | yes               | yes             |
| `VK_EXT_external_memory_dma_buf`, `VK_KHR_external_memory_fd`, `VK_KHR_external_semaphore_fd`, `VK_EXT_image_drm_format_modifier` | yes             | yes               | yes             |
| `VK_KHR_timeline_semaphore`, `VK_KHR_synchronization2`, `VK_KHR_sampler_ycbcr_conversion`                                         | yes             | yes               | yes             |
| `VK_EXT_host_image_copy`                                                                                                          | no              | no                | yes             |
| `VK_EXT_memory_decompression` / `VK_NV_memory_decompression`                                                                      | no              | no                | no              |

The video-capable device is the integrated one, and `Candidate.score` prefers the discrete one (3 against 2), so today's device selection would pick GPU0 and never see a video queue. GPU2's `bufferImageGranularity` is `0x40`, the RADV devices' is `0x1`; the allocator's separate linear/optimal pools (`VKM5`) make both irrelevant.

---

## Contracts that constrain image and video work

Quotes are from the named file; line numbers are the first line of the requirement.

**`VKM1` (`docs/specs/vulkan/memory.md:38`)**: "`alignedAllocate(request, alignment)` **must** take a size, a memory-type bit mask and the required and preferred property flags, and return a region: the `VkDeviceMemory`, an offset into it, the size, and for host-visible memory a host slice of exactly the region."

**`VKM3` (`memory.md:51`)**: "The allocator's state **must** live in CPU memory it owns. It **must not** dereference a device allocation's memory; only a host-visible region's slice is ever dereferenced, by its user." Constrains imported memory: a `VK_EXT_external_memory_host` or dma-buf import is not a region this allocator can name today.

**`VKM5` (`memory.md:61`)**: "Buffers and optimally tiled images **must** be placed in separate pools, so `bufferImageGranularity` never constrains a placement."

**`VKM8` (`memory.md:79`)**: "A request whose memory requirements prefer or require a dedicated allocation, or whose alignment exceeds its pool's block size, **must** receive a device allocation of its own, outside the pools, freed with its region." Video decode pictures and DPB images commonly require dedicated or special memory; not verified against any driver here.

**`VKM9` (`memory.md:84`)**: "A host-visible device allocation **must** be mapped once, when it is made, and unmapped when it is freed. For memory that is not host-coherent, `flush(region)` **must** flush the region widened to whole `nonCoherentAtomSize` units, and regions **must** start on such a unit."

**`VKM10` (`memory.md:89`)**: "A `FrameArena` **must** keep one host-visible, persistently mapped range per frame slot, of a size fixed at creation, and hand out regions from it by bumping an offset. A request that does not fit **must** be served from an extra range added to that slot."

**`VKM11` (`memory.md:96`)**: "The allocator **must** count its live device allocations, dedicated ones included, and refuse one past `maxMemoryAllocationCount` with `VK_ERROR_TOO_MANY_OBJECTS`, without calling the driver."

**Out of scope of the allocator (`memory.md:32`)**: "Defragmentation, sparse binding, aliasing of transient attachments and memory budgets are out of scope." A decoder's reference-picture pool and a large still-image working set would need at least budgets.

**`UVK25` (`docs/specs/ui-vulkan/SPEC.md:280`)**: "An image larger than the device's maximum 2-D image extent **must** draw the reference canvas's placeholder and count as `imageTooLarge`. An image whose upload would exceed the frame's upload budget **must** draw the placeholder, count as `imageDeferred`, ask for another frame, and upload in a later one; the frame's first upload is exempt, so an image larger than the whole budget still arrives." The budget is a whole-image granularity: there is no tiled or incremental image upload.

**`UVK23` (`SPEC.md:269`)**: "An image **must** be uploaded once per residency of its `(registry, handle, generation)`: once when first drawn, and again only after its upload was released (`UVK32`) or the device was rebuilt."

**`UVK27` (`SPEC.md:296`)**: "Device memory **must** come from the `sparkles:vulkan` sub-allocator ([memory.md][memory-spec]); the canvas makes no `vkAllocateMemory` call of its own."

**`UVK28` (`SPEC.md:300`)**: "Instances and staged uploads **must** live in the frame arena of the frame's slot (`VKM10`), reused only after that slot's fence has signalled." Staging is therefore tied to a frame slot and a fence, not to a transfer-queue timeline.

**`UVK30` (`SPEC.md:307`)**: "Uploads **must** be recorded before the frame's rendering pass, followed by a barrier from the transfer write to the fragment shader's read. An atlas page **must** be append-only while any frame in flight samples it: written regions are never rewritten until every slot that referenced the page has signalled."

**`UVK31` (`SPEC.md:313`)**: "A released resource — an evicted page, a replaced image, a cache dropped on memory pressure — **must** be destroyed only after every slot that referenced it has signalled."

**`UVK6` (`SPEC.md:162`)**: "A canvas **must** be created with a blend space. In the `gamma` space, every operation **must** composite as premultiplied source over destination, `out = src + dst·(1 − α_src)`, in the target's stored encoding: the shaders premultiply straight colours and image texels, and colour glyphs arrive premultiplied." No colour-space, HDR or ICC concept exists in this layer.

**`UVK24` (`SPEC.md:276`)**: "An image **must** be placed by `fitRect`, clipped to its rectangle for `cover`, sampled through a linear-filtering sampler, and its texels multiplied by the operation's foreground alpha."

**`UVX10` evidence (`docs/specs/ui-vulkan/decisions.md:197`)**: "The reference phone (Xiaomi 2107113SG, Adreno 660, Android 14) reports Vulkan 1.1.128 with driver 512.530 through `cmd gpu vkjson`. Of its 75 device extensions none is `VK_KHR_dynamic_rendering` or `VK_KHR_synchronization2`; it has `VK_KHR_create_renderpass2`, `VK_KHR_imageless_framebuffer` and `VK_KHR_separate_depth_stencil_layouts`." This is the portability floor: a design that assumes sync2 or timeline semaphores everywhere breaks the Android build the repo already ships.

**`UVX3` (`decisions.md:62`)**: the allocator is "A sub-allocator in `sparkles:vulkan` with the shape of `std.experimental.allocator`'s protocol"; the rejected alternative is binding VMA ("No C++ dependency to build for four platforms").

**WSI lifetimes, section 10.1 (`docs/specs/window-system-integration/SPEC.md:684`)**: "Work belongs to the longest scope that can own it, so nothing is repeated per window or per surface that a process could do once." The process-scoped `VulkanDevice` owns "the loader, `VkInstance`, the physical device, `VkDevice`, its queues and its `VkPipelineCache`". Any decoder session or compute pipeline cache belongs in the process scope too.

**Dispatch policy (`libs/vulkan/src/sparkles/vulkan/dispatch.d` module doc)**: "Each table is paired with the handle it was loaded from"; a process with two devices must not share pointers. A video session on the integrated GPU plus rendering on the discrete GPU is a two-device process, which this design already supports.

**Package dependency floor (`libs/vulkan/dub.sdl`)**: "This and `expected` are the whole D dependency floor; keep it that way." (`sparkles:base` and `expected`.) An image library must not make `sparkles:vulkan` depend on `sparkles:ui`.

**Test oracle (`docs/specs/ui-vulkan/testing.md`)**: "Mesa's software rasterizer is a separate Vulkan implementation; the test reads the target's bytes back." Lavapipe (GPU2 here) is the CI device; it exposes no video queue (table above), so video paths have no CI oracle on it.

---

## Capability table

| Capability                                                                                        | Where                                                                                     | Status                            | Evidence                                                                                                                                              |
| ------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| Full stable `vulkan.h` types via ImportC                                                          | `libs/vulkan/src/sparkles/vulkan/vulkan_c.c`                                              | Shipped                           | `#include <vulkan/vulkan.h>` under `VK_NO_PROTOTYPES`; video, ycbcr, host-copy, decompression structs present in the header (grep of `vulkan_core.h`) |
| Beta-gated extensions                                                                             | same                                                                                      | Not bound                         | `VK_ENABLE_BETA_EXTENSIONS` undefined; `VK_KHR_portability_subset` name is hand-written in `extensions.d` for that reason                             |
| Command dispatch (3 tiers, per-device)                                                            | `dispatch.d`                                                                              | Shipped                           | `GlobalCommands`, `InstanceCommands`, `DeviceCommands`; lists "deliberately small"                                                                    |
| Adding a command or extension                                                                     | `dispatch.d` `deviceSets`                                                                 | How to add                        | Append `CommandSet(extName, ["Name", ...])`, add an extension-name `enum string` pinned with `matchesHeaderMacro`; field, loader and `has!` follow    |
| Expected-typed results                                                                            | `result.d`                                                                                | Shipped                           | `VkExpected(T = void) = Expected!(T, VkResult)`                                                                                                       |
| Device memory sub-allocator                                                                       | `memory.d`                                                                                | Shipped                           | `DeviceMemory`, `FrameArena`; fake-backend unit tests; spec `VKM1`-`VKM13` still `status: draft`                                                      |
| Buffer / 2-D image creation bound to regions                                                      | `ui_vulkan/resources.d`                                                                   | Shipped                           | `GpuBuffer`, `GpuImage`: 2-D, 1 mip, 1 layer, optimal, exclusive                                                                                      |
| Staging buffer to image upload                                                                    | `ui_vulkan/upload.d`, `frame_buffers.d`                                                   | Shipped                           | readback test `ui_vulkan.upload.anImageReadsBackAsUploaded`                                                                                           |
| Image formats used                                                                                | `canvas.d`                                                                                | Shipped (2)                       | `R8G8B8A8_UNORM`, `R8_UNORM` for uploads; swapchain `B8G8R8A8`/`R8G8B8A8` UNORM/SRGB variants appear elsewhere in `libs`                              |
| Format property / capability query                                                                | `dispatch.d`                                                                              | Partly                            | `GetPhysicalDeviceFormatProperties` bound at instance tier; no `GetPhysicalDeviceImageFormatProperties2`, no format table                             |
| Samplers                                                                                          | `ui_vulkan/pipelines.d`                                                                   | Shipped                           | nearest and linear, clamp-to-edge, no anisotropy or mips in the code read                                                                             |
| Descriptors                                                                                       | `dispatch.d`                                                                              | Shipped (basic)                   | set layouts, pools, `UpdateDescriptorSets`; no `VK_EXT_descriptor_indexing` flags, no push descriptors, no descriptor buffer                          |
| Graphics pipelines, dynamic rendering                                                             | `ui_vulkan/pipelines.d`, `vulkan_wsi/device.d`                                            | Shipped                           | `CreateGraphicsPipelines`, `CmdBeginRendering` with render-pass fallback (`UVX10`)                                                                    |
| Compute pipelines and dispatch                                                                    | -                                                                                         | Not bound                         | `CreateComputePipelines`, `CmdDispatch` absent from `deviceSets`; shaders M10 "not started"                                                           |
| Storage buffers / storage images                                                                  | -                                                                                         | Not bound; planned (shaders M10)  | no usage flag or descriptor type in the code read                                                                                                     |
| Submit and sync primitives                                                                        | `dispatch.d`, `vulkan_wsi/frame.d`                                                        | Shipped (v1, binary)              | `QueueSubmit`, `CreateSemaphore`, `CreateFence`, `WaitForFences`, `CmdPipelineBarrier`                                                                |
| `VK_KHR_synchronization2` (core 1.3)                                                              | -                                                                                         | Not bound                         | no `QueueSubmit2` or `CmdPipelineBarrier2`; absent on the reference phone (`UVX10`); present on all three local devices                               |
| `VK_KHR_timeline_semaphore` (core 1.2)                                                            | -                                                                                         | Not bound                         | no `WaitSemaphores`, `SignalSemaphore`, `GetSemaphoreCounterValue`; present locally                                                                   |
| Queue-family selection                                                                            | `vulkan_wsi/device.d` `pickCandidates`                                                    | Shipped (graphics only)           | first graphics family, one queue, one `VkQueue`; no transfer, async-compute or video family chosen                                                    |
| Dedicated transfer / async compute queue                                                          | -                                                                                         | Not present                       | RADV exposes a compute+transfer family (`vulkaninfo`); unused                                                                                         |
| `VK_KHR_video_queue`, `video_decode_*`, `video_encode_*`, `video_maintenance1/2`                  | types only (via header)                                                                   | Types present, commands not bound | no `CreateVideoSessionKHR`, `CmdDecodeVideoKHR` etc. in `deviceSets`; no repo reference (grep); present on GPU1 only                                  |
| `VK_EXT_external_memory_host`                                                                     | -                                                                                         | Not bound                         | no `GetMemoryHostPointerPropertiesEXT`; allocator cannot hold an imported region (`VKM3`); present locally                                            |
| `VK_KHR_external_memory_fd`, `VK_EXT_external_memory_dma_buf`, `VK_EXT_image_drm_format_modifier` | -                                                                                         | Not bound                         | no `GetMemoryFdKHR`; present locally                                                                                                                  |
| `VK_KHR_external_semaphore_fd` / fence fd                                                         | -                                                                                         | Not bound; mentioned in a comment | `dispatch.d` comment about a future pollable `sync_fd`                                                                                                |
| `VK_KHR_sampler_ycbcr_conversion` (core 1.1)                                                      | -                                                                                         | Not bound                         | no `CreateSamplerYcbcrConversion`; present locally                                                                                                    |
| `VK_EXT_host_image_copy`                                                                          | -                                                                                         | Not bound                         | present on llvmpipe only here                                                                                                                         |
| `VK_EXT_memory_decompression` / `VK_NV_memory_decompression`                                      | -                                                                                         | Not bound                         | declared in the pinned header; advertised by none of the three local devices                                                                          |
| `VK_KHR_buffer_device_address`, `cooperative_matrix`, `descriptor_buffer`, `shader_object`        | -                                                                                         | Not bound                         | declared in the header; not referenced in `libs` (grep not exhaustive for every spelling)                                                             |
| Glyph atlas (R8 pages, dirty-rect upload)                                                         | `ui_vulkan/glyph_atlas.d`                                                                 | Shipped, interim                  | `UVX12`; replaced by `sparkles:font` S3 later                                                                                                         |
| Terminal inline images                                                                            | `terminal-view/vulkan_images.d`, `vulkan_painter.d`                                       | Shipped                           | RGBA registry, canvas uploads within budget, `UVX11`                                                                                                  |
| PNG decode                                                                                        | `libs/ui/src/sparkles/ui/png.d` (and a second one in `libs/font/src/sparkles/font/png.d`) | Shipped x2                        | header text of both files; the font one is premultiplied-RGBA, strike-only, no interlace                                                              |
| Colour management, HDR, 16-bit, float formats                                                     | -                                                                                         | Not present                       | `UVK6` fixes premultiplied 8-bit gamma blending; `UVX6` defers linear light                                                                           |
| Deferred destruction                                                                              | `ui_vulkan/canvas.d` (`Retired`)                                                          | Shipped (per-slot fence)          | `UVK31`; no timeline-epoch scheme                                                                                                                     |
| Pipeline cache persistence                                                                        | `vulkan_wsi/device.d`                                                                     | Shipped                           | `loadPipelineCache`, `savePipelineCache`                                                                                                              |
| Validation-layer test harness                                                                     | `vulkan_wsi/testing.d`                                                                    | Shipped, opt-in                   | `SPARKLES_VULKAN_READBACK=1`                                                                                                                          |

---

## Gaps and tensions

**G1. The upload path is a UI texture path, not an image-core path (Q1, Q6).** `Uploads.stage` takes a flat `ubyte[]` of `extent.width * extent.height * texelBytes` bytes with an `in` contract that "the pixels must fill the extent exactly". It has no row stride, no plane, no sub-image, no array layer, no mip, no multi-sample, no 3-D. `ImageData.rgba` is 8-bit RGBA by definition. A planar YCbCr 4:2:0 frame, a 16-bit or float image or an N-D volume has no representation in `GpuImage`, `ImageData` or `CanvasImages`. Whatever pixel model Q1 picks must say how it maps to `VkBufferImageCopy` (row length, image height, aspect per plane); today that mapping is hard-wired to the one-plane tight case.

**G2. Two PNG decoders and an 8-bit-only registry pull against "no package-local copies of shared infra" (Q9, Q4, Q8).** `libs/ui/src/sparkles/ui/png.d` and `libs/font/src/sparkles/font/png.d` are separate decoders with different output contracts (straight RGBA with Adam7 against premultiplied RGBA without interlace). The `png.d` header in `ui` calls itself "the toolkit's one PNG codec", which the font copy contradicts. A new `image-formats` package should replace or absorb both, not add a third. The hostile-input posture there (output sized by header, `maxPngPixels`) is the pattern Q4 should generalise.

**G3. Single graphics queue, graphics-first device scoring, no async path (Q6, Q7).** `pickCandidates` accepts only graphics-capable families and `queueCount: 1`. A transfer or compute upload overlapping rendering, and any video session, needs more families and queues than the code ever requests. On this machine the discrete GPU has no video queue and the integrated one has two, while `Candidate.score` prefers discrete. Choosing a device "by queue capability" (the WSI spec's own phrase) would need to be per-purpose, which `VulkanDevice` (one device per process in section 10.1) does not model. Cross-device sharing of a decoded frame would then need dma-buf export and import, none of which is bound.

**G4. Sync vocabulary is Vulkan 1.0 binary objects; the Android floor forbids assuming more (Q3, Q6).** Everything uses `vkQueueSubmit`, fences, binary semaphores and `vkCmdPipelineBarrier`. A decode, upload and render pipeline wants timeline semaphores (cross-queue progress counters that map onto the event-horizon completion model) and sync2 stage masks. `UVX10` records that the reference phone lacks sync2 and dynamic rendering. This is the same tension the repo already resolved for rendering by keeping two paths; the design has to say whether image and video work does the same or raises the floor for GPU-only features. The `research/vulkan` tree states the alternatives (`concepts.md` timeline section; `comparison.md` graph compilation versus manual).

**G5. Event-horizon integration is a comment, not a seam (Q6).** `dispatch.d` anticipates exporting a fence as a pollable `sync_fd`; `docs/specs/event-horizon/open-issues.md` O7 resolves Wayland/Vulkan frame-loop integration only at the `OpPollAdd` level and says deeper pacing "stays with the window-system replacement work". No code connects a Vulkan fence, timeline value or `VkFence` completion to an event-horizon completion or an `io_uring` fixed-buffer registration. File to GPU is therefore: read into host memory, copy into a `FrameArena` slice, `vkCmdCopyBufferToImage`: two host copies for a decoded image unless the read lands in the arena directly (possible in principle because arena regions are persistently mapped host slices, `VKM10`, but nothing arranges it).

**G6. No zero-copy import; the allocator forbids it as written (Q6).** `VKM3` and `VKM1` describe regions as sub-ranges of allocator-owned `VkDeviceMemory`. `VK_EXT_external_memory_host` (page-aligned host pointers, `minImportedHostPointerAlignment = 0x1000` locally) would let a decoder's output buffer or an `mmap`ed file be a Vulkan buffer without a copy, but needs an import path in the allocator and a lifetime rule (the host pages must outlive the buffer). The `UVK31` deferred-destruction rule is per frame slot and would need extending to imported memory.

**G7. No compute (Q3, Q7).** Generic algorithms on the GPU (resize, colour conversion, YCbCr to RGB, filters) need `CreateComputePipelines`, `CmdDispatch`, storage buffers and images, workgroup sizing and, for the dispatch-versus-SIMD break-even of Q7, a host-side way to time both. All are absent. The shaders toolchain plan puts compute at M10, "not started", and D shaders are compiled by the `gpu-effects` build; the CPU reference executor is M11 and depends on M10. Q3's "GPU kernels" and Q8's oracle ("same kernel on CPU and GPU") both wait on this.

**G8. Video: types exist, nothing else (Q4, Q6, Q8).** The header gives the structs, including codec-std headers for H.264, H.265, AV1 and VP9, because ImportC includes them for free. No dispatch entry, no session or session-parameters wrapper, no DPB/reference-picture pool, no bitstream-buffer model, no queue-family selection. The decode API is bitstream-driven with slice-level parsing done by the application, which is exactly the incremental, hostile-input surface Q4 asks about: the CPU side must parse the stream headers (SPS/PPS, AV1 sequence header) in a bounded, `@nogc` way before it can fill `StdVideo*` structs. CI runs on lavapipe, which has no video queue (table above), so there is no CI oracle for GPU decode; Q8 needs a CPU reference decoder or recorded hardware vectors.

**G9. Allocator scope excludes what image workloads need (Q1, Q6).** `memory.md` excludes budgets, defragmentation, aliasing and sparse binding. A large still image (tens of megapixels at 16 bits), a decoder DPB and a tile cache all stress `MemoryConfig.allocationSize` (32 MiB) and the dedicated-allocation path; none of that is measured. The `FrameArena` is sized at creation ("a size fixed at creation") and grows through extra ranges, which is right for per-frame UI instances but not for a streamed image whose size is known only after the header is parsed. `UVK29`'s fixed 16 MiB per-frame upload budget is a UI-pacing policy that an image viewer for a 100-megapixel file would have to bypass or tile around.

**G10. Colour is out of the layer (Q5).** `UVK6`/`UVK7` fix premultiplied 8-bit gamma-space blending, with sRGB handled by a counted degradation (`srgbBlending`). There is no format-to-colour-space mapping, no `VK_EXT_swapchain_colorspace`/HDR metadata use (the extension is advertised by the loader here, instance list in `vulkaninfo`, but not enabled by the code), no YCbCr matrix or range model, and no ICC. These are properties of the pixel model (Q1/Q5), and this layer will have to consume them rather than invent them.

**G11. `@nogc`/`nothrow`/`Expected` hold in the binding but not everywhere around it (Q4).** The binding's result type is `Expected` and its enumerate/extensions helpers are `@safe pure nothrow @nogc`. `VulkanDevice.savePipelineCache` allocates (`new ubyte[size]`, `std.file`) and `deviceName` calls `idup`, and the `ui_vulkan` upload and canvas code is `@system`. An image decoder that streams into Vulkan buffers must either stay below that layer (writing into caller-provided spans) or the `@nogc` boundary must be drawn explicitly. betterC and wasm builds are not applicable to the ImportC Vulkan binding; Android is (the `ui-vulkan` and WSI code targets it), which makes the Android floor of G4 the practical portability constraint.

**G12. Separate GPU texture caches would duplicate infrastructure (Q9).** `UVX11` already states the rule for kitty images: "A second GPU cache beside the canvas would upload outside the canvas's budget and retire on a different schedule." An image library with its own `GpuImage` residency would repeat that mistake. The residency key `(registry, handle, generation)` and the `UVK23`/`UVK31` lifetime rules are the existing shared mechanism; the design should decide whether image-core's decoded buffers register there or whether the canvas takes a more general "texture source" concept.

**G13. Resource limits are not queried generally (Q1, Q8).** Only `maxImageExtent` reaches the canvas (`DeviceFacts`); there is no `GetPhysicalDeviceImageFormatProperties2` binding, so max array layers, max mip levels, supported usage for a format (storage, blit, sampled-linear) and tiling-feature bits are not asked. Choosing a GPU representation for an arbitrary decoded format (for example `R16G16B16A16_SFLOAT` or a planar `G8_B8R8_2PLANE_420_UNORM`) depends on those answers.

---

## Questions for the design grill

**D1. Where does the GPU side of images live? (Q9)**

- A. A new `sparkles:image-vulkan` package depending on `image-core` and `sparkles:vulkan`, with `ui-vulkan` consuming it.
- B. Extend `libs/ui-vulkan/resources.d` and `upload.d` in place and keep GPU code in the UI package.
- C. Move the generic parts (`GpuImage`, `GpuBuffer`, `Uploads`, `FrameBuffers`) down into `sparkles:vulkan` (the dependency floor is `base` and `expected`, so this keeps it).
- Recommendation: C for resources and uploads (they have no UI knowledge), A for anything that knows an `image-core` pixel type.

**D2. Pixel-format to `VkFormat` mapping: table, trait or runtime query? (Q1, Q2, Q5)**

- A. A compile-time table keyed by an `image-core` format enum, checked with `static assert` against the header (the `matchesHeaderMacro` pattern in `dispatch.d`).
- B. Design-by-introspection: the pixel type declares its Vulkan format through a UDA or member, and uploads are a template over it.
- C. Runtime query through `GetPhysicalDeviceImageFormatProperties2` with a fallback ladder (for example float16 to float32 to 8-bit).
- Recommendation: A plus a runtime support check from C; B only if Q2 selects DbI as the generic mechanism.

**D3. Queue model for upload, compute and video. (Q6, Q7)**

- A. Stay single-queue; do uploads and compute on the graphics queue, serialised by fences.
- B. Request one graphics queue plus optional transfer, async-compute and video queues, choosing families by capability, still one logical device.
- C. One logical device per purpose (for example video on the integrated GPU, rendering on the discrete one), joined by dma-buf.
- Recommendation: B first, with the per-device dispatch tiers already allowing C later; A remains the Android and lavapipe fallback (single family).

**D4. Synchronisation floor. (Q3, Q6)**

- A. Keep Vulkan 1.0 binary objects and `CmdPipelineBarrier` everywhere (current).
- B. Add sync2 and timeline semaphores as optional `has!` command sets, with the current path as the fallback (as `UVX10` did for dynamic rendering).
- C. Require Vulkan 1.3 for GPU image/video features and refuse the phone.
- Recommendation: B; it matches the repo's own precedent, keeps Android working, and lets the event-horizon seam (D6) use timeline values where they exist.

**D5. Zero-copy import: allocator change or separate path? (Q6)**

- A. Extend `DeviceMemory` with an `importHost(ptr, size)` region kind that bypasses pools (like a dedicated allocation) and amend `VKM3`/`VKM8`.
- B. Keep the allocator pure and add a small `ExternalMemory` type beside it, with its own lifetime rules.
- C. Do not support import; always copy through the arena.
- Recommendation: B first, measuring C as the baseline; `VKM3`'s "only a host-visible region's slice is ever dereferenced" is easier to keep if imports are a separate concept.

**D6. How do Vulkan completions meet event-horizon? (Q6)**

- A. Fence polling on a timer (current, implicit).
- B. Export `sync_fd` from fences or semaphores and register it with `OpPollAdd` (the comment in `dispatch.d`).
- C. Timeline semaphore waited on by a helper thread that posts to the loop's external waker (SPEC section 5.6).
- Recommendation: B where `VK_KHR_external_semaphore_fd`/fence fd is present (it is on all three local devices), C as the fallback; both need new dispatch entries.

**D7. Compute: wait for shaders M10, or start with hand-written SPIR-V? (Q3, Q7, Q8)**

- A. Wait for D compute kernels (M10 is "not started", and M11 CPU executor depends on it).
- B. Bind compute dispatch now and load precompiled SPIR-V (`spirv.d` already assembles words at compile time), writing kernels in GLSL or via an external tool.
- C. Skip GPU compute in the first image milestones; keep SIMD and CPU only, and use the GPU only for upload and display.
- Recommendation: C for the baseline, with the dispatch work (B) done early enough to measure the Q7 break-even; A is where kernels should end up so CPU and GPU share one source.

**D8. Video scope. (Q4, Q6, Q8)**

- A. Out of scope for the first image library; only reserve the package boundary.
- B. Bind decode only (H.264, H.265, AV1, VP9), with bitstream parsing in D and the GPU doing reconstruction.
- C. Decode and encode, H.264 and H.265 encode being what the local hardware offers.
- Recommendation: A for the first milestone and B for the second; decode drives the Q4 parser work, and encode has no CPU oracle locally (no AV1 encode on this hardware).

**D9. What is the CI oracle for GPU paths? (Q8)**

- A. Lavapipe readback only (current: `SPARKLES_VULKAN_READBACK=1`), which covers upload and compute but not video.
- B. A CPU reference implementation of every GPU kernel, compared with a tolerance (the shaders plan's M11 idea).
- C. Recorded known-answer vectors for video decode, run only on machines with the hardware, skipped elsewhere via `skipTest`.
- Recommendation: A and B together for upload/compute; C for video, with the environment-dependent skip rule from `AGENTS.md`.

**D10. What owns the upload budget and residency for large images? (Q1, Q6, Q9)**

- A. Keep `UVK23`/`UVK29` as they are; large images go through the canvas and its 16 MiB per-frame budget.
- B. Add a tiled or progressive residency (sub-rectangle `stage` calls already exist) driven by a viewer, with the budget a parameter.
- C. A separate image-viewer residency with its own cache.
- Recommendation: B; it reuses the registry/generation mechanism and avoids the duplicated cache `UVX11` warns against.

---

## Sources

- [`docs/specs/vulkan/memory.md`][memory-spec]: `VKM1`-`VKM13`.
- [`docs/specs/ui-vulkan/SPEC.md`][uv-spec], [`PLAN.md`][uv-plan], [`decisions.md`][uv-decisions], [`testing.md`][uv-testing].
- [`docs/specs/window-system-integration/SPEC.md`][wsi-spec] section 10.1, [`docs/specs/shaders/PLAN.md`][shaders-plan] M10, [`docs/specs/event-horizon/open-issues.md`][eh-open] O7, [`docs/specs/ui-skia/canvas-seam-friction.md`][skia-friction] (contrast only; not used for any fact above beyond its framing).
- `libs/vulkan/src/sparkles/vulkan/`: `vulkan_c.c`, `dispatch.d`, `memory.d`, `extensions.d`, `result.d`, `package.d`; `libs/vulkan/dub.sdl`.
- `libs/vulkan-wsi/src/sparkles/vulkan_wsi/`: `device.d`, `frame.d`, `testing.d`.
- `libs/ui-vulkan/src/sparkles/ui_vulkan/`: `resources.d`, `upload.d`, `frame_buffers.d`, `canvas.d`, `glyph_atlas.d`, `pipelines.d`.
- `libs/terminal-view/src/sparkles/terminal_view/`: `vulkan_painter.d`, `vulkan_images.d`; `libs/ui/src/sparkles/ui/`: `image.d`, `png.d`; `libs/font/src/sparkles/font/png.d`.
- [`docs/research/vulkan/`][research-vulkan]: `index.md`, `concepts.md`, `comparison.md`, `sync-validation.md` (vocabulary: timeline semaphores, sync2, deferred destruction, graph compilation).
- Commands run read-only: `vulkaninfo`, `vulkaninfo --summary`, `pkg-config --cflags vulkan`, greps over the header `vulkan_core.h` of the Nix store `vulkan-headers-1.4.357.0`, `git merge-base --is-ancestor HEAD origin/main`.
- Not verified: the flake's pinned header version against the shell's; per-driver dedicated-allocation behaviour of video images; whether any branch outside this tree holds compute or video work.

<!-- References -->

[memory-spec]: ../../../specs/vulkan/memory.md
[uv-spec]: ../../../specs/ui-vulkan/SPEC.md
[uv-plan]: ../../../specs/ui-vulkan/PLAN.md
[uv-decisions]: ../../../specs/ui-vulkan/decisions.md
[uv-testing]: ../../../specs/ui-vulkan/testing.md
[wsi-spec]: ../../../specs/window-system-integration/SPEC.md
[shaders-plan]: ../../../specs/shaders/PLAN.md
[eh-open]: ../../../specs/event-horizon/open-issues.md
[skia-friction]: ../../../specs/ui-skia/canvas-seam-friction.md
[research-vulkan]: ../../vulkan/index.md
