# Granite (C++)

Hans-Kristian Arntzen's (Themaister — RADV and vkd3d-proton developer) personal Vulkan engine, whose two-layer design — a deliberately _explicit_ mid-level `vulkan/` backend underneath a fully automatic `RenderGraph` that derives barriers, layouts, semaphores, subpass merges, and memory aliasing from declared pass inputs/outputs — is the intellectual ancestor of the [Daxa][daxa]/[vuk][vuk]-style task-graph layers, canonized in the August 15, 2017 blog post ["Render graphs and Vulkan — a deep dive"][rg-blog].

| Field          | Value                                                                                                  |
| -------------- | ------------------------------------------------------------------------------------------------------ |
| Language       | C++ (engine-style codebase; CMake; GCC/Clang/MSVC)                                                     |
| License        | MIT                                                                                                    |
| Repository     | [Themaister/Granite][repo]                                                                             |
| Documentation  | [`OVERVIEW.md`][overview] · [render-graph blog (2017)][rg-blog] · [backend tour series (2019)][tour-1] |
| Category       | Render-graph / auto-sync layer (personal engine, **not** a library)                                    |
| First release  | None — development started January 2017 ([tour part 1][tour-1]); no versioned releases                 |
| Latest release | None; actively developed as of March 29, 2026 ([descriptor-heap blog post][heap-blog])                 |

> [!IMPORTANT]
> Granite is explicitly **not a supported library**. The [README][readme] states: _"Do not
> expect any support or help. Pull requests will likely be ignored or dismissed."_ Its value to
> this survey is as a **reference implementation and design document**: the render graph
> (`renderer/render_graph.{hpp,cpp}`, ~3000 lines) and the blog series explaining it are the
> canonical public deep-dive of automatic-synchronization render graphs over Vulkan, predating
> [Daxa][daxa] (2022), [vuk][vuk], and [Tephra][tephra] — all of which productize the same idea.

---

## Overview

### What it solves

Granite attacks the same three Vulkan bookkeeping domains as its descendants, but splits them
across **two layers with opposite philosophies**:

- The **`vulkan/` backend** removes the _ceremony_ — descriptor pools/sets, render-pass and
  pipeline objects, fence/semaphore recycling, deferred destruction — while deliberately
  keeping **synchronization explicit** ([tour part 5][tour-5]).
- The **`RenderGraph`** (`renderer/render_graph.hpp`) removes the _synchronization_: passes
  declare their reads and writes up front, and a `bake()` step computes every barrier, image
  layout transition, subpass merge, transient attachment, memory alias, and cross-queue
  semaphore ([render-graph blog][rg-blog]).

The 2017 post frames why just-in-time sync tracking (the [V-EZ][vez]/[vulkano][vulkano] family)
was rejected and a declarative graph chosen instead — manual tracking degenerates into
unanswerable questions:

> _"When was the last time I read from this image? Probably last frame later in the post-chain
> ... We want to avoid write-after-read hazards."_ ([render-graph blog][rg-blog])

### Design philosophy

The backend's stance is stated in [`OVERVIEW.md`][overview]:

> _"The aim of Granite is a 'mid-level' abstraction. Some convenience is allowed at the cost of
> CPU cycles, but not so much that we're back to GL levels of silliness."_

and, on synchronization:

> _"Granite does not attempt to perform any synchronization on behalf of the application,
> except for a few isolated cases."_ ([`OVERVIEW.md`][overview])

Automation is **delegated upward**: the render graph is _"a powerful system for declaring the
rendering you're doing up front, and have the render graph sort out dependencies and
synchronization"_ ([`OVERVIEW.md`][overview]). This layering — explicit primitives below, a
declarative compiler above, each usable without the other — is precisely the architecture
[Daxa][daxa] (`CommandRecorder` + optional `TaskGraph`) and [vuk][vuk] later shipped as
libraries.

---

## How it works

A frame declares logical passes against a `RenderGraph`; each pass names its attachments and
the graph resolves everything at `bake()` time:

```cpp
// themaister.net/blog/2017/08/15/render-graphs-and-vulkan-a-deep-dive/ — deferred setup
auto &gbuffer = graph.add_pass("gbuffer", VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT);
gbuffer.add_color_output("emissive", emissive);
gbuffer.add_color_output("albedo", albedo);
gbuffer.set_depth_stencil_output("depth", depth);

auto &lighting = graph.add_pass("lighting", VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT);
lighting.add_color_output("HDR", emissive, "emissive");   // read-modify-write of "emissive"
lighting.add_attachment_input("albedo");
lighting.add_texture_input("shadow-main");
```

Resources are described logically (`AttachmentInfo` with `SizeClass::SwapchainRelative` /
`Absolute` / `InputRelative` sizing, format, samples, levels, layers; `BufferInfo` with size and
usage) and bound to physical `VkImage`/`VkBuffer` objects only after baking. Inside each pass's
record callback, the explicit backend API is used — `cmd->set_texture(set, binding, view,
sampler)`, draws, dispatches — with no sync calls.

### Binding generation & API coverage

**Nothing is generated from `vk.xml` — the wrapper is entirely hand-written.** The backend
loads Vulkan through [volk][volk] (`vulkan/vulkan_headers.hpp` is literally `#include
"volk.h"`) and wraps the entry points the engine needs in hand-authored classes (`Device`,
`CommandBuffer`, `Image`, `Buffer`, `RenderPass`, `DescriptorSetAllocator`, …, under
[`vulkan/`][vulkan-dir]). Consequently no registry metadata — `externsync`, success/error
codes, structure-chain validity — informs the types; thread-safety and usage contracts live in
[`OVERVIEW.md`][overview] and the blog series.

The one code-generation-like mechanism Granite does use is **reflection from shaders, not from
the registry**: pipeline layouts and descriptor-set layouts are derived automatically by
running [SPIRV-Cross][spirv-cross] over the SPIR-V (compiled at runtime from GLSL via
shaderc) — _"using reflection to automatically generate layouts is a good idea. There is no
reason for users to copy information which exists in the shaders already"_
([tour part 3][tour-3]). Coverage is engine-shaped, not registry-shaped: what the glTF
PBR renderer, post-processing chain, async compute, and the Beetle PSX emulator backend (the
project's origin, per [tour part 1][tour-1]) need — and nothing else.

### Handle lifetime & ownership model

Granite predates the generational-ID fashion; it uses **intrusive reference counting plus
frame-context-bucketed deferred destruction** ([tour part 2][tour-2]):

- Handles (`ImageHandle`, `BufferHandle`, …) are an intrusive smart pointer — _"It can
  basically be thought of a std::shared_ptr, but simpler"_ ([tour part 2][tour-2]). Refcount
  operations stay visible at API boundaries; command-buffer arguments take plain references.
- When a handle's refcount hits zero, the `VkImage`/`VkBuffer` is **not** destroyed — it is
  queued on the current **frame context**, _"basically a huge data structure which holds data
  like: Which VkFences must be waited on to make sure that all GPU work associated with this
  queue is done"_ ([tour part 2][tour-2]). The `Device` keeps 2–3 contexts in flight; actual
  `vkDestroy*` happens when a context's fences signal. `Device::wait_idle()` _"will
  automatically clean up everything in one go"_.
- Command buffers are transient handles that _"must be recorded and submitted in the same frame
  context"_ they were requested in ([tour part 2][tour-2]) — pools use
  `ONE_TIME_SUBMIT_BIT`/`TRANSIENT_BIT` and recycle wholesale per context.

This is the same deferred-destruction shape as Daxa's timeline-gated
[zombie lists][daxa] — gated on per-context fences instead of timeline semaphore values —
and the README lists _"memory manager"_ and deferred destruction among the backend's core
features ([README][readme]).

### Synchronization safety

The defining design decision is **where** automation lives.

**Backend layer: explicit by argument.** [Tour part 5][tour-5] states _"synchronization in
Granite is almost 100% explicit"_ and gives three reasons automatic per-resource tracking was
rejected: barriers cannot be retroactively injected into recorded command buffers (eager
insertion costs performance, late injection stalls); tracking statically-read resources wastes
CPU _"unless it is trivial to do so"_; and multi-threaded recording makes access order unknowable
before submission. The user gets thin explicit wrappers —
`cmd->barrier(srcStage, srcAccess, dstStage, dstAccess)` and
`cmd->image_barrier(image, oldLayout, newLayout, …)` — plus pooled fences, single-wait
semaphores, and `VkEvent` wrappers. The few automated exceptions are layout transitions for WSI
images, transients, and first/last use inside a render pass ([tour part 5][tour-5]).

**Graph layer: fully automatic.** `RenderGraph::bake()`
([`renderer/render_graph.cpp`][rg-cpp]) runs a fixed pipeline — validate passes, traverse
dependencies backward from the backbuffer, reorder, build physical resources/passes,
transients, render-pass info, barriers, aliases:

- **Barriers** — per pass, _"inputs to a pass are placed in the invalidate bucket, outputs are
  placed in the flush bucket"_ ([render-graph blog][rg-blog]); adjacent buckets become batched
  pipeline barriers with the correct `VkAccessFlags2`/stage masks and image-layout transitions
  (e.g. texture inputs become `SHADER_READ` in `SHADER_READ_ONLY_OPTIMAL`). Color + input
  attachment feedback and depth + input attachment cases fall back to `GENERAL`.
- **Subpass merging & reordering** — mergeable graphics passes become subpasses of one
  `VkRenderPass` (barriers turn into `VkSubpassDependency`, a tiler win); the scheduler scores
  merge candidates infinitely and otherwise maximizes the distance between writes and dependent
  reads. The heuristic is deliberately modest: _"A more clever scheduling algorithm might help
  here, but I'd like to keep it as simple as possible."_ ([render-graph blog][rg-blog])
- **Transient attachments** — a resource used in one physical pass and not loaded qualifies;
  _"Granite recognizes transient attachments internally, and forces `storeOp = DONT_CARE`"_
  ([render-graph blog][rg-blog]), enabling `LAZILY_ALLOCATED` memory on tilers.
- **Aliasing** — _"For each resource we figure out the first and last physical render pass
  where a resource is used. If we find another resource with the same dimensions/format, and
  their pass range does not overlap, presto, we can alias!"_; on handoff _"the barriers
  associated with Alias #0 are copied over to Alias #1, and the layout is forced to
  UNDEFINED"_ ([render-graph blog][rg-blog]). History-buffer resources (`add_history_input()`,
  for TAA-style previous-frame reads) never alias.
- **Cross-queue semaphores** — passes carry queue flags (`RENDER_GRAPH_QUEUE_GRAPHICS_BIT`,
  `_COMPUTE_BIT`, `_ASYNC_COMPUTE_BIT`, [`render_graph.hpp`][rg-hpp]); resources crossing
  queues signal one semaphore per consuming queue (each waitable exactly once), and ownership
  is sidestepped: _"In the name of not making this horribly complicated, I went with
  `CONCURRENT`"_ sharing for cross-queue resources ([render-graph blog][rg-blog]) — the same
  shortcut Daxa 3.6 later adopted wholesale.

Vulkan's **externally-synchronized-handle rules are nowhere reified in types** at either
layer: contracts are prose (e.g. command buffers tied to one frame context and thread), and the
graph's correctness rests on honest `add_*_input`/`add_*_output` declarations — a pass touching
an undeclared resource produces an unprotected hazard the engine cannot see.

### Type-system techniques

Granite spends almost nothing here, and the absence is a deliberate finding:

- **Distinct handle classes** (`Image`, `Buffer`, `ImageView`, `Sampler`, `Semaphore`,
  `Fence`) and logical-resource classes (`RenderTextureResource`, `RenderBufferResource`
  deriving from `RenderResource`, [`render_graph.hpp`][rg-hpp]) give nominal type safety over
  raw `uint64_t` Vulkan handles — and that is essentially all.
- **Strings as graph identity** — graph resources are named by `std::string` and connected by
  name matching at `bake()` time; typos are runtime errors, not compile errors. Descendants
  replaced this with typed virtual handles ([Daxa][daxa]'s `TaskImageView`, [vuk][vuk]'s
  futures).
- **No typestate, no phantom types, no compile-time access tags** — access/stage/layout are
  runtime enum values in a `Barrier` struct (`resource_index`, `layout`, `access`, `stages`,
  `history`); pass declaration methods (`add_color_output`, `add_storage_read_only_input`,
  `add_indirect_buffer_input`, …) encode the access kind in the _method name_, turning what
  vk.xml would call usage metadata into runtime graph edges rather than types.
- The strongest static artifact is **reflection-driven pipeline layouts**: the shader's SPIR-V
  is the single source of truth for descriptor interfaces ([tour part 3][tour-3]) — the same
  "one artifact for host and shader" instinct behind Daxa's `TaskHead` macros, achieved by
  introspection instead of macro codegen.

Safety is structural (the graph sees every declared edge) and runtime (validation layers),
never type-level — coherent for a single-author C++ engine, and the exact gap a D
implementation could close with CTFE-checked declarations.

### Overhead & escape hatches

The cost model is **amortize in the graph, stay lean in the backend, accept measured
convenience costs**:

- **Bake is amortized.** `bake()` runs only when the graph topology changes (typically once, or
  on resize); per-frame `enqueue_render_passes()` replays precomputed physical passes,
  barriers, and submissions, with per-pass GPU recording farmed to a thread pool
  ([`render_graph.cpp`][rg-cpp]).
- **Descriptor cost is hashed away, with receipts.** The backend hashes bindings at draw time
  and reuses `VkDescriptorSet`s from per-layout allocators (recycled after 8 frames unused) —
  _"In the ideal case, we almost never actually need to call vkUpdateDescriptorSets"_; on the
  hashing overhead: _"I honestly never saw it in the profiler"_ ([tour part 3][tour-3]). The
  philosophy is anti-theoretical: _"the benefits you gain by designing for maximum possible CPU
  performance are more theoretical design exercises than practical ones"_
  ([tour part 1][tour-1]). (A March 29, 2026 follow-up ports the backend to
  `VK_EXT_descriptor_heap` while keeping the slot-based binding abstraction, revisiting exactly
  this trade-off — [descriptor-heap post][heap-blog].)
- **Known costs are documented honestly**: pipeline/render-pass hashing per draw, the graph's
  CONCURRENT sharing (forfeits some DCC/compression on some hardware), and aliasing's barrier
  inflation — _"Adding aliasing might increase the number of barriers needed and reduce GPU
  throughput"_ ([render-graph blog][rg-blog]).
- **Escape hatches are the default, not the exception.** Because the backend is explicit, the
  graph is strictly optional — any code path can record command buffers with manual
  `cmd->barrier(...)` calls, and raw `VkDevice`/`VkImage`/full `vkCmdPipelineBarrier`
  structures are reachable when the wrappers are too narrow ([tour part 5][tour-5]).

### Error handling & validation integration

There is **no recoverable-error story** — and as a personal engine, none is claimed. Fallible
creation paths log (`logging.hpp`/`LOGE`) and return null handles or assert; there is no
result/exception policy comparable to a library's, and `VkResult` plumbing stops at the
wrapper boundary. The compensating machinery is operational rather than typed:

- Development runs lean on the **Khronos validation layers** (the README's tested-platform
  matrix and the blog's bug confessions — _"I'm sure there are bugs (actually I found two in
  async compute while writing this)"_ ([render-graph blog][rg-blog]) — show the workflow), and
  graph `bake()` performs its own structural validation (mismatched attachment dimensions,
  invalid resolve/color pairings) before any Vulkan call ([`render_graph.cpp`][rg-cpp]).
- **[Fossilize][fossilize]** integration records pipelines for replay/warm-up, and a
  `vulkan/post-mortem/` module aids device-loss debugging — tooling-grade robustness in place
  of API-grade error types.

Notably, the author later co-developed exactly the missing piece upstream: the explicit
backend's barrier discipline is what [synchronization validation][sync-validation] checks
mechanically, and Granite's layering (explicit core, automated graph) is the architecture that
makes those checks tractable.

---

## Strengths

- **The architecture that defined the category**: declared pass I/O in, batched barriers +
  layout transitions + subpass merges + transient/lazy memory + aliasing + cross-queue
  semaphores out — published with full reasoning in 2017, before any comparable library
  ([render-graph blog][rg-blog]).
- **The layering argument is made explicitly and well**: automation belongs in a declarative
  compiler above an explicit backend, not in per-call tracking inside it — with three concrete
  reasons ([tour part 5][tour-5]) that map directly onto why [vulkano][vulkano]-style tracking
  costs and [V-EZ][vez]-style implicitness failed to win.
- **Tiler-aware by design** — subpass merging and transient attachments are first-class graph
  outputs, not afterthoughts; tested on Arm Mali, not just desktop ([README][readme]).
- **Reflection-driven descriptor management** (SPIRV-Cross) eliminates a whole class of
  layout-mismatch bugs with measured, accepted overhead ([tour part 3][tour-3]).
- **Exceptionally documented for a personal engine**: `OVERVIEW.md` plus a six-part backend
  tour and the render-graph deep-dive make every trade-off inspectable and citable.

## Weaknesses

- **Not a library, by decree** — no releases, no stability, _"pull requests will likely be
  ignored or dismissed"_ ([README][readme]); it can be studied and forked, not depended on.
- **String-keyed graph identity** — resource wiring is checked at `bake()` time, not compile
  time; nothing stops a typo'd or undeclared access at the type level.
- **No type-level safety anywhere**: no typestate, no access-tagged handles, no
  `externsync` reification; thread/lifetime contracts are blog prose.
- **No error model** — null-handle/assert/log on failure is fine for an engine, unusable as a
  library contract.
- **Single-author bus factor** and engine-shaped coverage: features exist iff the author's
  projects (glTF viewer, emulators, parallel-rdp) needed them.
- The graph predates `VK_KHR_synchronization2`-era simplifications in places, and its
  `CONCURRENT`-sharing shortcut leaves queue-ownership-transfer wins unexplored (acknowledged
  in the [blog][rg-blog]).

## Key design decisions and trade-offs

| Decision                                                        | Rationale                                                                                   | Trade-off                                                                            |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Explicit sync in the backend; automation only in the graph      | Per-call tracking can't inject barriers retroactively, taxes static resources, breaks MT    | Two APIs to learn; non-graph code carries full manual-barrier responsibility         |
| Hand-written wrapper over volk, no `vk.xml` codegen             | Engine needs a curated surface, not 1:1 coverage                                            | No registry metadata in types; coverage limited to what the author's projects need   |
| Declarative pass I/O compiled by `bake()`                       | Whole-frame knowledge enables batching, merging, aliasing, reordering — JIT tracking can't  | Graph must be re-baked on topology change; honesty of declarations is unverifiable   |
| String-named logical resources                                  | Trivial wiring ergonomics; passes composable without shared headers                         | Identity errors surface at bake time, not compile time                               |
| Subpass merging + transient attachments as graph outputs        | Tile-based GPUs win big from on-chip attachment lifetime                                    | Merge legality rules add complexity; desktop gains are marginal                      |
| `CONCURRENT` sharing for cross-queue resources                  | _"In the name of not making this horribly complicated"_ — skips ownership-transfer barriers | Forfeits compression/DCC on some hardware; less optimal than `EXCLUSIVE` transfers   |
| Intrusive refcount handles + frame-context deferred destruction | Simple, cheap, GPU-safe deletion without per-resource fences                                | Destruction latency tied to frame-context cadence; handles are not thread-safe prose |
| Draw-time descriptor hashing with 8-frame set recycling         | _"almost never … call vkUpdateDescriptorSets"_; convenience worth measured cycles           | Per-draw hash cost; revisited by the 2026 `VK_EXT_descriptor_heap` port              |

---

## Sources

- [Themaister/Granite — GitHub repository][repo] · [README][readme] · [`OVERVIEW.md`][overview]
- ["Render graphs and Vulkan — a deep dive" (August 15, 2017)][rg-blog] — the canonical render-graph design write-up
- ["A tour of Granite's Vulkan backend" — Part 1 (April 14, 2019)][tour-1] · [Part 2 — lifetimes & frame contexts][tour-2] · [Part 3 — shaders & descriptors][tour-3] · [Part 5 — render passes & synchronization][tour-5]
- ["Walking backwards into the future — a look at descriptor heap in Granite" (March 29, 2026)][heap-blog]
- [`renderer/render_graph.hpp` — pass/resource declaration API, queue flags, `Barrier`][rg-hpp]
- [`renderer/render_graph.cpp` — `bake()` pipeline, barriers, aliasing, submission][rg-cpp]
- [`vulkan/` — hand-written backend (device, command buffer, descriptors, sync managers)][vulkan-dir]
- [volk — Vulkan meta-loader Granite builds on][volk] · [SPIRV-Cross][spirv-cross] · [Fossilize][fossilize]
- Related: [Daxa (C++)][daxa] · [vuk (C++)][vuk] · [Tephra (C++)][tephra] · [V-EZ (C++)][vez] · [vulkano (Rust)][vulkano] · [Sync validation][sync-validation] · [Concepts][concepts] · [Comparison][comparison] · [Survey index][index]

<!-- References -->

[repo]: https://github.com/Themaister/Granite
[readme]: https://github.com/Themaister/Granite/blob/master/README.md
[overview]: https://github.com/Themaister/Granite/blob/master/OVERVIEW.md
[rg-blog]: https://themaister.net/blog/2017/08/15/render-graphs-and-vulkan-a-deep-dive/
[tour-1]: https://themaister.net/blog/2019/04/14/a-tour-of-granites-vulkan-backend-part-1/
[tour-2]: https://themaister.net/blog/2019/04/17/a-tour-of-granites-vulkan-backend-part-2/
[tour-3]: https://themaister.net/blog/2019/04/20/a-tour-of-granites-vulkan-backend-part-3/
[tour-5]: https://themaister.net/blog/2019/04/27/a-tour-of-granites-vulkan-backend-part-5/
[heap-blog]: https://themaister.net/blog/2026/03/29/walking-backwards-into-the-future-a-look-at-descriptor-heap-in-granite/
[rg-hpp]: https://github.com/Themaister/Granite/blob/master/renderer/render_graph.hpp
[rg-cpp]: https://github.com/Themaister/Granite/blob/master/renderer/render_graph.cpp
[vulkan-dir]: https://github.com/Themaister/Granite/tree/master/vulkan
[volk]: https://github.com/zeux/volk
[spirv-cross]: https://github.com/KhronosGroup/SPIRV-Cross
[fossilize]: https://github.com/ValveSoftware/Fossilize
[daxa]: ./cpp-daxa.md
[vuk]: ./cpp-vuk.md
[tephra]: ./cpp-tephra.md
[vez]: ./cpp-vez.md
[vulkano]: ./rust-vulkano.md
[sync-validation]: ./sync-validation.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
