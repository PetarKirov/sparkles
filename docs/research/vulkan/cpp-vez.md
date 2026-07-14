# V-EZ (C++)

AMD's 2018 "easy mode" Vulkan middleware and the historical **maximum of implicit synchronization**: a C API that mirrors Vulkan's shape while a record-time tracker infers every pipeline barrier and image layout transition, sub-allocates all memory, and hides descriptor sets, render passes, and pipeline state objects — announced with fanfare in March 2018 and effectively dead by the end of that same year.

| Field          | Value                                                                                                             |
| -------------- | ----------------------------------------------------------------------------------------------------------------- |
| Language       | C API (`Source/VEZ.h`), C++11 implementation                                                                      |
| License        | MIT                                                                                                               |
| Repository     | [GPUOpen-LibrariesAndSDKs/V-EZ][repo]                                                                             |
| Documentation  | [V-EZ API Documentation][docs] (asciidoctor, gh-pages)                                                            |
| Category       | Render-graph / auto-sync layer (runtime-tracked auto-sync; no graph — **historical**)                             |
| First release  | `v1.0.0` beta (binary-only) — March 24, 2018, [announced][announce] March 26, 2018; source opened August 20, 2018 |
| Latest release | `v1.1.0` — May 1, 2018; **last code commit October 5, 2018** ([commit history][commits])                          |

> [!WARNING]
> **V-EZ is unmaintained and of historical interest only.** The last functional commit landed on
> October 5, 2018 ("Fixed issue #46"); the only later change is a documentation-typo merge on
> September 7, 2021. Community issue [#73, "V-EZ is unmaintained, what's next?"][issue-73]
> (February 18, 2020) records that the original author could not be reached and that a volunteer
> GitLab fork was attempted. This survey covers it because a **failed extreme is a finding**: V-EZ
> automated more of Vulkan than any system before or since, and every later auto-sync design
> ([Daxa][daxa], [vuk][vuk], [Tephra][tephra]) scopes its automation more narrowly.

---

## Overview

### What it solves

V-EZ targets the full breadth of Vulkan's "application responsibility" at once. The
[README][readme] positions it as

> _"an open source, cross-platform (Windows and Linux) wrapper intended to alleviate the inherent
> complexity and application responsibility of using the Vulkan API. V-EZ attempts to bridge the
> gap between traditional graphics APIs and Vulkan by providing similar semantics to Vulkan while
> lowering the barrier to entry and providing an easier to use API."_

Concretely, the [GPUOpen announcement][announce] (March 26, 2018) enumerates what disappears:
memory heaps and `VkDeviceMemory` (the application only sees buffer/image handles, backed by
[VMA][vma] sub-allocation), [pipeline barriers][concepts-barriers] and
[image layout transitions][concepts-layouts] ("applications are no longer required to handle
synchronization of resources at any level or to handle image layout transitions"), descriptor sets
("Descriptor sets and pools are no longer explicitly exposed in V-EZ"), up-front render passes
("V-EZ does not require an application to create render passes up front"), and monolithic pipeline
state objects ("V-EZ alleviates this burden by decoupling graphics state and vertex input format
from pipeline creation" — a pipeline is just a set of shader modules).

### Design philosophy

The announcement frames V-EZ explicitly as an adoption vehicle for **non-game ISVs**, not as an
engine-grade abstraction:

> _"a middleware layer that significantly reduces the house-keeping overhead of Vulkan"_ … _"This
> allows V-EZ to be used as a transition layer while ISVs familiarize themselves with the new
> concepts"_ ([GPUOpen announcement][announce])

Two further stances define the design. First, **API mimicry**: V-EZ keeps Vulkan's C calling
conventions (`vezCreateBuffer`, `VezSubmitInfo`, `VkResult` returns) and most of its object model,
so code "looks like Vulkan" minus the hard parts. Second, **interop as the escape hatch**: V-EZ

> _"will still retain the most powerful capabilities of Vulkan but with a simplified API that can
> be mixed with standard Vulkan where needed"_ ([GPUOpen announcement][announce])

— most handles it returns are real `Vk*` handles. On cost, AMD claimed the automation was
essentially free: _"this overhead is negligible and measured in the range of microseconds for tens
of thousands of API calls"_ ([GPUOpen announcement][announce]). The claim was never backed by a
published benchmark, and the implementation's own comments are less confident (see
[Overhead & escape hatches](#overhead--escape-hatches)).

### Rise and abandonment

The trajectory is fully visible in the [commit history][commits] and issue tracker:

- **March 22–26, 2018** — repo created; `v1.0.0` beta ships as **prebuilt binaries** plus headers
  and samples; GPUOpen announcement; coverage by [Phoronix][phoronix] and
  [the Khronos news feed][khronos-news].
- **May 1, 2018** — `v1.1.0`, still binary-core.
- **August 20, 2018** — commit _"V-EZ is now open source."_ publishes the implementation
  ([GamingOnLinux coverage][gamingonlinux], August 2018).
- **October 5, 2018** — last functional commit ("Fixed issue #46"). Total public lifespan of
  active development: **about six months**.
- **2019–2020** — issues accumulate unanswered; community PRs adding tessellation (`#75`),
  GLSL `#include` support (`#76`), and debug markers (`#77`) sit unmerged ([pull requests][pulls],
  April 2020). Issue [#73][issue-73] (February 18, 2020) reports the author was unreachable and
  AMD granted no maintainership; a volunteer fork on GitLab (`PRIME-tech-OSS/V-EZ`, announced in
  the same thread on February 20, 2021) saw no broader adoption.
- **2022–2023** — users still file bugs with fixes attached, titled "[fixed]" because nobody can
  merge them (issues `#85`–`#88`, [issue tracker][issues]).

AMD never published a post-mortem; the grounded record is simply that the single author
(`soconne`, Sean O'Connell) stopped, AMD declined to transfer maintainership, and no engine or
notable application adopted the layer while it was alive. The repository was never even archived —
it is abandoned in place, with 33 open issues.

---

## How it works

The public surface is a flat C API ([`Source/VEZ.h`][vez-h], ~630 lines) whose entry points mirror
Vulkan's (`vezCreateInstance`, `vezCreateDevice`, `vezCreateBuffer`, `vezCmdDraw`,
`vezQueueSubmit`), plus `Vez*` shadow structs that are Vulkan structs with the dangerous fields
deleted — `VezBufferCreateInfo` has no sharing mode, `VezImageCreateInfo` has no
`initialLayout`, `VezSubmitInfo` has no `sType`. The implementation is C++ under
`Source/Core/`.

The load-bearing mechanism is **deferred command encoding**. `vezCmd*` calls do not record into a
`VkCommandBuffer`; they are serialized into an in-memory byte stream by
[`StreamEncoder`][stream-encoder-h]:

```cpp
// Source/Core/StreamEncoder.h
// Command buffer stream encoder class for serializing incoming calls to an in memory binary stream.
// The StreamEncoder class is responsible for automatic pipeline barrier insertion determination
// and descriptor set creation from resource bindings.
```

While encoding, every buffer/image access is reported to the [`PipelineBarriers`][pb-h] tracker
(see [Synchronization safety](#synchronization-safety)), and resource bindings accumulate in
`ResourceBindings`. At `vezEndCommandBuffer`, [`CommandBuffer::End`][cb-cpp] replays the stream
through `StreamDecoder` into the real `VkCommandBuffer` — splicing in the inferred
`vkCmdPipelineBarrier` calls, the descriptor sets built from bindings, the render passes and
framebuffer objects materialized from `RenderPassCache`, and the `VkPipeline` permutations looked
up in `PipelineCache` from the current `GraphicsState`. Every command buffer is therefore recorded
**twice**: once into V-EZ's stream, once into Vulkan.

Pipelines are created from shader modules alone (GLSL is compiled in-library via a bundled
`glslang`, [`Source/Compiler/GLSLCompiler.cpp`][glsl-compiler]); descriptor-set layouts and
pipeline layouts are derived by V-EZ's own SPIR-V reflection
([`Source/Compiler/SPIRVReflection.cpp`][spirv-reflection]), queryable through
`vezEnumeratePipelineResources`.

### Binding generation & API coverage

**Nothing is generated from `vk.xml`** — the entire API is hand-written, and the absence is total:
no [`externsync`][concepts-externsync] metadata, no success/error-code tables, no feature/extension
typing survive into `VEZ.h`. The `Vez*` shadow structs were edited from their `Vk` counterparts by
hand, which means coverage is frozen at the author's snapshot: **core Vulkan 1.0 against SDK
1.1.70** ([README prerequisites][readme]). There is no extension mechanism — the `pNext` fields
exist but nothing consumes them — and the six-month lifespan meant timeline semaphores,
descriptor indexing, dynamic rendering, ray tracing, and `VK_KHR_synchronization2` all postdate
the project. The only "extension" surface is the hand-written interop header
[`Source/VEZ_ext.h`][vez-ext-h] (`vezImportVkImage`, `vezRemoveImportedVkImage`,
`vezGetImageLayout`), added so externally created images (e.g. from an OpenGL interop path) can
join the layout tracker.

### Handle lifetime & ownership model

Ownership is raw and Vulkan-like, with three twists:

- **Native handles, shadow objects.** `vezCreateBuffer` returns a real `VkBuffer`; the
  bookkeeping object (`vez::Buffer`, holding the VMA allocation and access state) lives in a
  global registry ([`Source/Utility/ObjectLookup.cpp`][object-lookup]) keyed by the native handle.
  Only four types are V-EZ-specific opaque handles — `VezSwapchain`, `VezPipeline`,
  `VezFramebuffer`, `VezVertexInputFormat` ([`VEZ.h`][vez-h]) — precisely the objects V-EZ
  synthesizes rather than wraps. The [docs][docs] state the consequence: _"Most object handles
  created by V-EZ are the native Vulkan objects. These can be used in native Vulkan."_
- **Memory is fully hidden.** Buffers and images are sub-allocated through [VMA][vma]
  (`VmaAllocator m_memAllocator`, [`Source/Core/Device.h`][device-h]); the application chooses
  only a `VezMemoryFlags` placement hint (`VEZ_MEMORY_GPU_ONLY`, `VEZ_MEMORY_CPU_TO_GPU`, …) or
  opts out per-resource with `VEZ_MEMORY_DEDICATED_ALLOCATION`.
- **Sync primitives are pooled and auto-recycled; resources are not.** `vezQueueSubmit` acquires a
  fence from `SyncPrimitivesPool` for **every** submission and allocates the caller's requested
  signal semaphores from the same pool ([`Source/Core/Queue.cpp`][queue-cpp]); if the caller
  doesn't take the fence, the `Device` tracks it and recycles fence + semaphores once it signals
  ([`Device::QueueSubmission`][device-h]). But there is **no
  [deferred destruction][concepts-deferred] for buffers/images/pipelines** — `vezDestroyBuffer`
  destroys immediately,
  and not destroying a resource the GPU is still reading remains the application's unchecked
  obligation. The "easy mode" layer automated barriers but not the other classic Vulkan footgun.

### Synchronization safety

This is V-EZ's reason to exist, and it is the **purest implicit model in the survey**: no graph,
no declared accesses, no typestate — every `vezCmd*` call's resource usages are **inferred at
record time** and hazard-checked by [`PipelineBarriers`][pb-h]
(per-resource [usage tracking][concepts-tracking] at command granularity). The announcement's
one-liner: _"Pipeline barriers are inserted on demand when read/write hazards are detected"_
([GPUOpen announcement][announce]); the docs extend the claim across submissions: _"within a
command buffer, and between command buffer submissions, pipeline barriers are inserted
automatically"_ ([V-EZ docs][docs]).

The mechanism ([`Source/Core/PipelineBarriers.h`][pb-h]):

> _"This class handles tracking resource usages within the same command buffer for automated
> pipeline barrier insertion. Buffer accesses are tracked per region with read-combining and
> write-combining done on adjacent 1D ranges. … Image accesses are tracked per array layer and mip
> level ranges. … If two accesses' rectangles intersect, then either their regions are merged into
> a larger rectangle or a pipeline barrier is inserted if the accesses require it."_

[Hazard][concepts-hazards] detection itself is a coarse read/write lattice
([`PipelineBarriers.cpp`][pb-cpp], `RequiresPipelineBarrier`): all `VkAccessFlags` are reduced to
read-ness and write-ness, and a barrier is required on write→anything and read→write transitions —
WAW, RAW, WAR all conservatively barriered, with no execution-only or finer-grained distinction.
Image layouts are a per-image property tracked across the frame: layouts transition lazily to
whatever the next use requires (`StreamEncoder::TransitionImageLayout`), and external code can
query or pre-set them via [`VEZ_ext.h`][vez-ext-h]. Render-pass internals get derived
`VkSubpassDependency` values from attachment usage ([`StreamEncoder.h`][stream-encoder-h]).

The boundaries of the automation, all visible in source:

- **Single command buffer, single queue.** The tracker state lives in the encoder; cross-queue
  hazards are not analyzed, and every generated barrier hard-codes
  `VK_QUEUE_FAMILY_IGNORED`/`VK_QUEUE_FAMILY_IGNORED` ([`PipelineBarriers.cpp`][pb-cpp]) —
  [queue-family ownership transfer][concepts-qfot] simply does not exist in V-EZ.
- **Host-side sync stays manual-ish.** The application still wires semaphores between submissions
  and present (`VezSubmitInfo`/`VezPresentInfo` carry wait/signal semaphore arrays,
  [`VEZ.h`][vez-h]); V-EZ only allocates the signal semaphores on its behalf.
- **No reordering, no aliasing.** Commands execute in recorded order; the tracker only inserts
  barriers between them. There is nothing graph-shaped to optimize.
- **`externsync` is unaddressed.** Threading rules are a paragraph of prose ([docs][docs]:
  command-buffer recording binds `vezCmd*` calls to the buffer begun **on that thread**, backed by
  per-thread command pools in [`Device.h`][device-h]); nothing in the types distinguishes
  externally synchronized handles, exactly as in raw Vulkan.

### Type-system techniques

**Effectively none — and for this survey that absence is the finding.** V-EZ is a C API whose
handles are Vulkan's own (`VkBuffer`, `VkImage`, `VkFence`); the four `Vez*` opaque handles are
plain `VK_DEFINE_NON_DISPATCHABLE_HANDLE` typedefs with no ownership, lifetime, or thread-affinity
encoding ([`VEZ.h`][vez-h]). There are no [phantom/branded types][concepts-phantom], no
[typestate][concepts-typestate], no RAII (creation/destruction are paired free functions), no
typed structure chains (bare `const void* pNext`). All of V-EZ's safety value is delivered by
**runtime tracking inside an unchanged type system** — the diametric opposite of
[vulkano][vulkano]'s types-plus-tracking or [Vulkan-Hpp][vulkan-hpp]'s types-without-tracking.
For a layer whose pitch was safety-through-automation, the type system contributes nothing; every
guarantee is dynamic and most misuses (destroy-in-flight, cross-thread recording, lying about
nothing — there is nothing to declare) fail at runtime or not at all.

### Overhead & escape hatches

The advertised story was _"negligible … microseconds"_ ([announcement][announce]); the
implementation tells a more cautious one:

- **Every command buffer is recorded twice** (encode to `MemoryStream`, decode to Vulkan —
  [`CommandBuffer::End`][cb-cpp]), with an 8 MB default stream block per command buffer
  ([`Device.h`][device-h]).
- **Every resource access walks STL containers at record time** — buffer accesses in a
  `std::map` keyed by handle/offset/range, image accesses likewise in a `std::map` of linked lists
  of rectangles (the in-source comment says "STL unordered_map", but the declaration
  `std::map<ImageAccessKey, ImageAccessList> m_imageAccesses;` is an ordered map), merged and split
  per call ([`PipelineBarriers.h`][pb-h]). The in-source implementation note concedes the scaling
  risk:

  > _"This implementation likely needs to be optimized and improved to handle the cases of random
  > scattered accesses across images and buffers as the process of merging and pipeline barrier
  > insertion could become quite expensive."_ ([`PipelineBarriers.h`][pb-h])

- **Per-draw cache lookups** — descriptor-set construction from current bindings, pipeline-
  permutation lookup from `GraphicsState`, render-pass/framebuffer cache hits — all happen behind
  ostensibly cheap `vezCmd*`/`End` calls, GL-driver style.
- **No knobs.** The automation cannot be turned off per-resource or per-pass; the only escape
  hatch is **leaving V-EZ entirely** — using the returned native handles in raw Vulkan and, for
  images, keeping the layout tracker informed through [`vezImportVkImage` /
  `vezGetImageLayout`][vez-ext-h]. Mixing is one-directional and manual: raw-Vulkan work is
  invisible to the tracker, so the user re-inherits full sync responsibility at the seam.

This cost profile is precisely what the next generation rejected. [Tephra][tephra]'s README states
the lesson as a design axiom — _"analyzing commands recorded into command lists would have
unacceptable performance overhead"_ ([Tephra README][tephra-readme]) — and tracks at **job**
granularity instead; [Daxa][daxa] and [vuk][vuk] move the knowledge problem to the user entirely
(declared task/pass accesses compiled by a [render graph][concepts-graph]), paying analysis cost
once per graph rather than per recorded command. V-EZ sits at the worst point of that trade
curve: per-command runtime cost **and** no cross-submission/cross-queue reasoning **and** no way
to amortize.

### Error handling & validation integration

Plain Vulkan style: every fallible `vez*` function returns `VkResult` ([`VEZ.h`][vez-h]), with no
error model of V-EZ's own — some internal failures surface as loosely matching codes (e.g.
`VK_NOT_READY` for ending a non-recording command buffer, [`CommandBuffer.cpp`][cb-cpp]). There is
**no validation layer, no debug-callback integration, and no usage checking** beyond what the
barrier tracker incidentally enforces; the standard Khronos validation layers still run underneath,
but they now validate **V-EZ's generated code**, so findings point at barriers and render passes
the application never wrote — and unfixed validation errors in V-EZ's own shipped samples
([issue #69][issue-69], August 2019) show the loop was not closed even internally.
[Synchronization validation][sync-validation] proper postdates the project (2020). Reported
correctness bugs in the tracker itself (e.g. wrong `srcAccessMask`/`srcStageMask` in generated
barriers, [issue #82][issue-82], August 2022) remain open — a reminder that with fully implicit
sync, **the abstraction's bugs become the application's data hazards**, with no declared intent
anywhere to cross-check against.

---

## Strengths

- **The most complete demonstration ever shipped that Vulkan can be driven fully implicitly** —
  barriers, layouts, subpass dependencies, descriptors, render passes, pipeline permutations, and
  memory all automated behind an API that still looks like Vulkan.
- **Genuinely low barrier to entry** for its target audience: GL-class ergonomics
  (`vezCreateBuffer` + `vezBufferSubData` + draw) with Vulkan semantics, from a hardware vendor,
  under MIT.
- **Native-handle interop as a principle**: most returned handles are real `Vk*` objects, and the
  `VEZ_ext.h` import/layout-query functions acknowledge that a tracker must be teachable about
  externally created resources — an idea later systems kept (cf. [vuk][vuk]'s acquire/release and
  [Tephra][tephra]'s exports).
- **Per-region tracking granularity** (buffer ranges; image layer/mip rectangles with merge logic)
  was ahead of contemporaries — subresource-level dependency resolution reappears in
  [Tephra][tephra].
- **Vendor-neutral**: "V-EZ is not hardware vendor specific and should work on non-AMD hardware"
  ([README][readme]).

## Weaknesses

- **Dead.** Six months of active development; zero maintainer response since October 2018;
  community fixes filed against an unmergeable repo; no known production adoption. Every other
  weakness below is also a hypothesis for why.
- **Inference at command granularity is the wrong altitude**: the layer must reconstruct intent
  the application already had, paying STL-map walks per access at record time — the exact cost
  [Tephra][tephra-readme] later called "unacceptable" — while still failing to see across
  submissions, queues, or raw-Vulkan seams.
- **All-or-nothing automation with no escape valve short of leaving the API** — no per-resource
  opt-out, no manual barrier injection, no way to batch or hoist what the tracker decides.
- **Conservative hazard lattice** (any write→anything barriers, `VK_QUEUE_FAMILY_IGNORED`
  everywhere, no execution/memory distinction) forfeits much of the performance headroom that
  justified Vulkan over GL in the first place — while hiding _where_ the cost went.
- **No lifetime safety**: immediate destruction of possibly-in-flight resources is unchecked, so
  the single most common beginner crash survives "easy mode" intact.
- **Type system untouched**: nothing distinguishes externally synchronized handles, thread
  affinity, or recording state; all contracts are prose.
- **Frozen API snapshot**: hand-edited shadow structs with dead `pNext` fields, no extension
  story, capped at Vulkan 1.0-era features forever.

## Key design decisions and trade-offs

| Decision                                                  | Rationale                                                                            | Trade-off                                                                                                    |
| --------------------------------------------------------- | ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------ |
| Infer all sync from recorded commands (no declarations)   | Zero new concepts for users; "barriers inserted on demand when hazards are detected" | Per-command tracking cost; conservative barriers; tracker bugs become silent app data hazards                |
| Encode-then-decode command streams                        | Barriers/descriptors/render passes can be spliced in with full lookahead at `End`    | Every command buffer recorded twice; 8 MB stream blocks; latency hidden inside `vezEndCommandBuffer`         |
| Mirror Vulkan's C API with edited shadow structs          | Familiar shape; usable as a "transition layer while ISVs familiarize themselves"     | Hand-maintained surface frozen at Vulkan 1.0; no `vk.xml` metadata, no extension mechanism                   |
| Return native `Vk*` handles, shadow objects in a registry | Mixing "with standard Vulkan where needed" stays possible                            | Raw-Vulkan work is invisible to the tracker; the seam reinstates full manual sync                            |
| Automate barriers but not resource lifetimes              | Sync was judged the adoption blocker; fences are pooled internally                   | Destroy-in-flight remains an unchecked crash; safety story is half-finished                                  |
| Single-author vendor side project, binary-first release   | Fast path to a GDC-season announcement                                               | No bus factor, no community ownership path — abandonment was structural, not incidental                      |
| Track within one command buffer / one queue only          | Keeps the tracker simple and allocation-local                                        | No cross-queue hazards, no QFOT, semaphores still user-wired — automation stops exactly where sync gets hard |

The composite lesson later systems drew — visible in [Daxa][daxa]'s declared task attachments,
[vuk][vuk]'s pass-level resource declarations, and [Tephra][tephra]'s job-level tracking with
explicit exports — is that **automation needs declared intent and an amortization boundary**:
infer nothing, verify declarations, compile sync once. V-EZ proved the opposite corner of the
design space is implementable; its abandonment, unfixed tracker bugs, and zero adoption are the
field's evidence that it is not the corner worth living in.

---

## Sources

- [GPUOpen-LibrariesAndSDKs/V-EZ — GitHub repository][repo] · [README][readme] ·
  [commit history][commits] · [issues][issues] · [pull requests][pulls]
- [V-EZ brings "Easy Mode" to Vulkan — GPUOpen announcement, March 26, 2018][announce]
- [V-EZ API Documentation][docs]
- [`Source/VEZ.h` — full public C API, `Vez*` handle/struct definitions][vez-h]
- [`Source/VEZ_ext.h` — native-image import & layout query interop][vez-ext-h]
- [`Source/Core/PipelineBarriers.h` — tracking design notes][pb-h] ·
  [`PipelineBarriers.cpp` — `RequiresPipelineBarrier`, barrier emission][pb-cpp]
- [`Source/Core/StreamEncoder.h` — command-stream encoder, auto barrier/descriptor insertion][stream-encoder-h]
- [`Source/Core/CommandBuffer.cpp` — encode/decode at `End`][cb-cpp]
- [`Source/Core/Device.h` — VMA allocator, per-thread pools, tracked fences][device-h] ·
  [`Source/Core/Queue.cpp` — pooled fences/semaphores at submit][queue-cpp]
- [`Source/Utility/ObjectLookup.cpp` — native-handle → shadow-object registry][object-lookup]
- [`Source/Compiler/GLSLCompiler.cpp`][glsl-compiler] · [`SPIRVReflection.cpp`][spirv-reflection]
- [Issue #73 — "V-EZ is unmaintained, what's next?"][issue-73] · [issue #69 — sample validation errors][issue-69] · [issue #82 — wrong generated barrier masks][issue-82]
- [Phoronix coverage, March 2018][phoronix] · [GamingOnLinux on the open-sourcing, August 2018][gamingonlinux] · [Khronos news item][khronos-news]
- [Tephra README — "unacceptable performance overhead" of command-level analysis][tephra-readme]
- Related: [Daxa (C++)][daxa] · [vuk (C++)][vuk] · [Tephra (C++)][tephra] · [vulkano (Rust)][vulkano] · [Vulkan-Hpp (C++)][vulkan-hpp] · [Sync validation][sync-validation] · [Concepts][concepts] · [Comparison][comparison] · [Survey index][index]

<!-- References -->

[repo]: https://github.com/GPUOpen-LibrariesAndSDKs/V-EZ
[readme]: https://github.com/GPUOpen-LibrariesAndSDKs/V-EZ/blob/29d2229e44ee692f74a33b698c80273ebcc67c3e/README.md
[commits]: https://github.com/GPUOpen-LibrariesAndSDKs/V-EZ/commits/master
[issues]: https://github.com/GPUOpen-LibrariesAndSDKs/V-EZ/issues
[pulls]: https://github.com/GPUOpen-LibrariesAndSDKs/V-EZ/pulls
[announce]: https://gpuopen.com/news/v-ez-brings-easy-mode-vulkan/
[docs]: https://gpuopen-librariesandsdks.github.io/V-EZ/
[vez-h]: https://github.com/GPUOpen-LibrariesAndSDKs/V-EZ/blob/29d2229e44ee692f74a33b698c80273ebcc67c3e/Source/VEZ.h
[vez-ext-h]: https://github.com/GPUOpen-LibrariesAndSDKs/V-EZ/blob/29d2229e44ee692f74a33b698c80273ebcc67c3e/Source/VEZ_ext.h
[pb-h]: https://github.com/GPUOpen-LibrariesAndSDKs/V-EZ/blob/29d2229e44ee692f74a33b698c80273ebcc67c3e/Source/Core/PipelineBarriers.h
[pb-cpp]: https://github.com/GPUOpen-LibrariesAndSDKs/V-EZ/blob/29d2229e44ee692f74a33b698c80273ebcc67c3e/Source/Core/PipelineBarriers.cpp
[stream-encoder-h]: https://github.com/GPUOpen-LibrariesAndSDKs/V-EZ/blob/29d2229e44ee692f74a33b698c80273ebcc67c3e/Source/Core/StreamEncoder.h
[cb-cpp]: https://github.com/GPUOpen-LibrariesAndSDKs/V-EZ/blob/29d2229e44ee692f74a33b698c80273ebcc67c3e/Source/Core/CommandBuffer.cpp
[device-h]: https://github.com/GPUOpen-LibrariesAndSDKs/V-EZ/blob/29d2229e44ee692f74a33b698c80273ebcc67c3e/Source/Core/Device.h
[queue-cpp]: https://github.com/GPUOpen-LibrariesAndSDKs/V-EZ/blob/29d2229e44ee692f74a33b698c80273ebcc67c3e/Source/Core/Queue.cpp
[object-lookup]: https://github.com/GPUOpen-LibrariesAndSDKs/V-EZ/blob/29d2229e44ee692f74a33b698c80273ebcc67c3e/Source/Utility/ObjectLookup.cpp
[glsl-compiler]: https://github.com/GPUOpen-LibrariesAndSDKs/V-EZ/blob/29d2229e44ee692f74a33b698c80273ebcc67c3e/Source/Compiler/GLSLCompiler.cpp
[spirv-reflection]: https://github.com/GPUOpen-LibrariesAndSDKs/V-EZ/blob/29d2229e44ee692f74a33b698c80273ebcc67c3e/Source/Compiler/SPIRVReflection.cpp
[issue-73]: https://github.com/GPUOpen-LibrariesAndSDKs/V-EZ/issues/73
[issue-69]: https://github.com/GPUOpen-LibrariesAndSDKs/V-EZ/issues/69
[issue-82]: https://github.com/GPUOpen-LibrariesAndSDKs/V-EZ/issues/82
[phoronix]: https://www.phoronix.com/news/AMD-GPUOpen-V-EZ
[gamingonlinux]: https://www.gamingonlinux.com/2018/08/looks-like-amd-just-open-sourced-their-v-ez-vulkan-wrapper/
[khronos-news]: https://www.khronos.org/news/permalink/gpu-open-v-ez-brings-easy-mode-to-vulkan
[tephra-readme]: https://github.com/Dolkar/Tephra/blob/c3b6a2905952ab401e28cc3c1e9397aa71d20d80/README.md
[vma]: https://github.com/GPUOpen-LibrariesAndSDKs/VulkanMemoryAllocator
[daxa]: ./cpp-daxa.md
[vuk]: ./cpp-vuk.md
[tephra]: ./cpp-tephra.md
[vulkano]: ./rust-vulkano.md
[vulkan-hpp]: ./cpp-vulkan-hpp.md
[sync-validation]: ./sync-validation.md
[concepts]: ./concepts.md
[concepts-barriers]: ./concepts.md#pipeline-barriers
[concepts-layouts]: ./concepts.md#image-layout-transitions
[concepts-externsync]: ./concepts.md#external-synchronization--externsync
[concepts-hazards]: ./concepts.md#hazards-rawwarwaw--syncvals-taxonomy
[concepts-qfot]: ./concepts.md#queue-family-ownership-transfer-qfot
[concepts-tracking]: ./concepts.md#auto-sync-via-per-resource-usage-tracking
[concepts-graph]: ./concepts.md#render-graph--task-graph--frame-graph
[concepts-deferred]: ./concepts.md#deferred-destruction
[concepts-phantom]: ./concepts.md#phantom--branded-types
[concepts-typestate]: ./concepts.md#typestate
[comparison]: ./comparison.md
[index]: ./index.md
