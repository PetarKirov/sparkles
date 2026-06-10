# Tephra (C++)

A mid-level C++17 graphics and compute library that fills the gap between Vulkan and OpenGL/DirectX 11 with a two-tier **job system**: high-level job commands get driver-style automatic synchronization, while low-level command lists deliberately stay untracked for minimal recording overhead.

| Field                      | Value                                                                                                                 |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Language                   | C++17 (exceptions and standard library required)                                                                      |
| License                    | MIT                                                                                                                   |
| Repository                 | [Dolkar/Tephra][repo]                                                                                                 |
| Documentation              | [User guide][user-guide] · [API docs (Doxygen)][api-docs] · [Changelog][changelog]                                    |
| Category                   | Render-graph / auto-sync layer (non-reordering)                                                                       |
| Key Authors                | Dolkar; used and partially developed by BAE Systems OneArc (formerly Bohemia Interactive Simulations)                 |
| First version (changelog)  | `v0.1.0`, July 15, 2023 — per [`changelog.dox`][changelog-dox]; the repository has **no git tags or GitHub releases** |
| Latest version (changelog) | `v0.8.0`, October 14, 2025 — labelled the _"In-dev version"_ in [`changelog.dox`][changelog-dox]                      |

> **Requirements:** Vulkan **1.3+** devices, Vulkan headers 1.4.304+, Visual Studio 2022 or CMake 3.15+; primary testing on Windows x64. Built on [VMA] for all allocations. The 0.x series makes breaking changes on minor versions ([`changelog.dox`][changelog-dox]).

---

## Overview

### What it solves

Vulkan moved the resource tracking, synchronization guessing, and on-the-fly pipeline compilation that OpenGL/DX11 drivers used to do into the application — and a [triangle demo][sascha-triangle] balloons past a thousand lines. Render-graph layers like [Daxa][daxa] and [vuk][vuk] answer with a declarative graph that reorders and schedules passes. Tephra takes a deliberately simpler position: it is, per its own [README][readme], an approach that

> _"works the same as a render graph that does not reorder passes, but has a smaller API footprint, does not force resource virtualization and is already familiar to users of last-gen graphics APIs. A render graph solution can be easily implemented on top of Tephra, if desired."_

Work is recorded in **two phases**. A [`tp::Job`][job-hpp] records _high-level_ commands — job-local resource allocations, clears, copies, blits, resource **exports**, and compute/render passes — and these are what the library synchronizes automatically. The _low-level_ commands (pipeline/descriptor binds, draws, dispatches) go into per-pass command lists that can be recorded in parallel and are **never analyzed**. Cross-job and cross-queue ordering is explicit, via timeline-semaphore-backed [`tp::JobSemaphore`](#synchronization-safety) values and export operations.

### Design philosophy

The [user guide][user-guide-dox] states the trade-off that defines the whole library (`documentation/dox/user_guide.dox`):

> _"There is an unreachable goal of having the same convenience of the old APIs, but with the advantages of the new. Tephra tries to get as close to that goal as possible. It implements automatic synchronization and resource tracking much like the drivers used to do, but only for the high-level commands where it is needed the most. Low-level commands, like binds, draws and dispatches enjoy very low overhead and the possibility of multi-threaded recording."_

And the [README][readme] explains why command lists are exempt from analysis:

> _"While Tephra handles most of the Vulkan-mandated synchronization automatically from the list of job commands, analyzing commands recorded into command lists would have unacceptable performance overhead."_

The escape from that dilemma is the **export mechanism** (detailed [below](#synchronization-safety)): after writing to a resource you declare once how it will be _read_ in the future, instead of declaring every access in every pass. A second pillar is _not forcing architectural decisions_: no mandatory frame concept, no required recording callbacks, no bindless-only resource model ([README][readme]). Within this survey Tephra sits between the fully automatic runtime tracking of [Vulkano][vulkano] and the explicit task-graph models of [Daxa][daxa]/[vuk][vuk]; see the [comparison][comparison].

---

## How it works

The recording pipeline, end to end:

1. Create a [`tp::JobResourcePool`][job-hpp] per thread/purpose; pools recycle backing resources across similar jobs (zero Vulkan allocations on stable periodic workloads).
2. `pool->createJob(...)` → record high-level `cmd*` commands into the [`tp::Job`][job-hpp] in execution order — Tephra does **not** reorder.
3. `device->enqueueJob(queue, std::move(job))` consumes the job and returns a `tp::JobSemaphore`; command lists for each pass are then recorded (in parallel, with per-thread `tp::CommandPool`s) before submission.
4. `device->submitQueuedJobs(queue)` compiles the job — this is where barriers are generated — and submits it.

```cpp
// documentation/dox/user_guide.dox — job submission example
tp::Job job = mainJobPool->createJob({}, "Example job");
recordSomeCommands(job);

// Enqueue the job to finalize the recording
tp::JobSemaphore semaphore = device->enqueueJob(mainQueue, std::move(job));

// Finally submit it for execution and wait for it to be done on the device
device->submitQueuedJobs(mainQueue);
device->waitForJobSemaphores({ semaphore });
```

Compilation is a two-pass replay over the job's command list ([`src/tephra/job/job_compile.cpp`][job-compile], described in [`user_guide.dox`][user-guide-dox]): the first pass resolves synchronization and computes barriers against per-queue **access maps**; the second pass translates commands into the job's primary `VkCommandBuffer`, inserting the barriers and invoking any inline pass callbacks.

### Binding generation & API coverage

Tephra is **hand-written, not generated**. There is no `vk.xml` code-generation step anywhere in the tree; the library includes the stock C headers with prototypes disabled and loads everything dynamically through its own loader ([`include/tephra/vulkan/header.hpp`][header-hpp]):

```cpp
// include/tephra/vulkan/header.hpp
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>
#undef VK_NO_PROTOTYPES
```

[`src/tephra/vulkan/loader.cpp`][loader] opens the Vulkan library and resolves `vkGetInstanceProcAddr`; hand-maintained dispatch structs (`VulkanGlobalInterface`, `VulkanInstanceInterface`, `VulkanDeviceInterface` in [`src/tephra/vulkan/interface.hpp`][interface]) hold the `PFN_vk*` pointers Tephra actually uses. Coverage is therefore curated, not exhaustive: _"All of the compute and graphics commands supported by core Vulkan"_ ([README][readme]), plus a small set of fully integrated extensions exposed as `tp::ApplicationExtension` / `tp::DeviceExtension` constants (`EXT_DebugUtils`, `EXT_LayerSettings`, `KHR_Swapchain`, acceleration-structure/ray-query support, …). Anything else goes through the [interop escape hatches](#overhead--escape-hatches).

Because no generator runs over the registry, **no `vk.xml` safety metadata survives into the types** — `externsync` annotations, valid-usage data, and feature/extension dependency info are re-encoded by hand where they matter (e.g. the thread-safety contract in the user guide, the curated [`ErrorType`](#error-handling--validation-integration) enum) and absent elsewhere. This is a real data point for the survey: a mid-level layer can ship a useful safety model without consuming the registry at all, at the cost of manual maintenance whenever Vulkan moves.

### Handle lifetime & ownership model

Ownership is conventional C++ RAII with three notable refinements:

- **Customizable owning pointer.** Ownable objects are returned as `tp::OwningPtr`, which `include/interface_glue.hpp` defines as `std::unique_ptr` by default but lets the integrator swap for `std::shared_ptr` or a custom smart pointer ([`user_guide.dox`][user-guide-dox] § Interface tools).
- **A documented parent–child hierarchy with lifetime classes.** The user guide spells out the full object tree (`tp::Application` → `tp::Device` → `tp::Buffer`/`tp::Image`/`tp::JobResourcePool` → `tp::Job` → views, lists, pools) and tags each node with rules: **[F]** children must be destroyed before the parent, **[L]** children are context-local, **[E]** the object's lifetime must be _extended during job recording_ (alive until the job is enqueued or destroyed), **[N]** library-owned. Nearly all interaction happens through cheap **non-owning views** (`tp::BufferView`, `tp::ImageView`, `tp::DescriptorSetView`). None of this is compiler-enforced — it is documentation plus optional runtime validation.
- **Deferred destruction keyed on job IDs.** Vulkan handles must outlive GPU use, so destroying a Tephra object parks its handles in a per-device container stamped with the ID of the last enqueued job; the IDs double as the device-wide timeline-semaphore values. From [`user_guide.dox`][user-guide-dox]:

  > _"This method avoids tracking how the handles are actually used, but comes with the downside that the lifetime is extended regardless of whether the object has actually been used in recent jobs or not."_

  Reclamation happens opportunistically inside calls like `tp::Device::enqueueJob`, or explicitly via `tp::Device::updateDeviceProgress` ([`src/tephra/device/timeline_manager.cpp`][timeline], [`deferred_destructor.hpp`][deferred]).

For raw-handle interop there is [`tp::Lifeguard`][handles-hpp] — _"a lifeguard for a Vulkan handle implementing RAII by invoking specialized deleters according to the type of the handle"_ — creatable as owning (`tp::Device::vkMakeHandleLifeguard`) or explicitly non-owning (`tp::Lifeguard::NonOwning`), and `tp::Device::addCleanupCallback` covers handle types Tephra cannot destroy itself.

### Synchronization safety

Synchronization is **automated within a queue's job stream, explicit across queues**, with the export mechanism bridging the untracked command lists.

**Within and across jobs on one queue.** From [`user_guide.dox`][user-guide-dox]: _"Within the scope of a job, Tephra synchronizes accesses fully automatically, like in OpenGL."_ The engine is an **access map** per resource ([`src/tephra/job/accesses.cpp`][accesses], [`barriers.cpp`][barriers]): for any subresource range (byte ranges for buffers; mip levels × array layers for images) it stores the last accesses and which barriers already cover them, so existing barriers are reused. New barriers are inserted _as late as possible_ and never by reordering commands — _"the implementation tries to minimize the number of barriers without reordering the commands - the control of that is left in the hands of the user"_ ([README][readme]). Access maps persist per queue, so consecutive jobs on the same queue are synchronized automatically too. The generated barriers are classic synchronization-scope barriers (`VkPipelineStageFlags` + `VkAccessFlags` in `ResourceAccess`, emitted as `VkBufferMemoryBarrier`/`VkImageMemoryBarrier` with queue-family indices — [`barriers.hpp`][barriers]).

**Inside passes: declared, not analyzed.** Render/compute passes must list the resources they _write_ (attachments, storage targets); reads can ride on exports. Within a single compute pass, dispatches are **manually** synchronized — `tp::ComputeList::cmdPipelineBarrier` exists for that, and the guide's advice is that if _"manual synchronization seems daunting, you can always split the dispatches into separate compute passes"_.

**The export mechanism.** `tp::Job::cmdExportResource(resource, readAccessMask)` declares, right after a write, every way the data will be _read_ from then on — across passes and across jobs — so passes need not re-declare read-only inputs:

> _"Exports are very useful in the majority of cases where you write to a resource rarely and then read from it many times after."_ — [`user_guide.dox`][user-guide-dox]

Any non-exported access invalidates the export and requires re-exporting. `tp::DescriptorBinding::getReadAccessMask()` derives the mask for "readable through this binding". `tp::Job::cmdDiscardContents` is the discard-instead-of-preserve hint.

**Across queues.** Every enqueued job signals a `tp::JobSemaphore` — a value of a single device-wide **timeline semaphore** counter — which other jobs wait on via `enqueueJob`'s `waitJobSemaphores` (same-queue jobs are already ordered by enqueue order). Semaphores handle _execution_ ordering only; making the _contents_ visible to another queue additionally requires a **cross-queue export** naming the destination queue type, which broadcasts the relevant access-map state (and issues queue-family ownership-transfer barriers when needed) via message passing between the per-queue access maps ([`src/tephra/device/cross_queue_sync.cpp`][cross-queue]); _"a cross-queue export with an empty access mask is therefore enough to just transfer ownership to another queue."_ Host readback likewise requires an export with `tp::ReadAccess::Host` plus waiting on the job semaphore.

> [!IMPORTANT]
> Nothing in the type system forces an export or a semaphore wait — forgetting one is a runtime correctness bug, caught (at best) by Tephra's WIP validation or the Vulkan validation layers (see [sync validation][sync-validation]). Tephra's safety is _convention plus runtime tracking_, not _proof_.

### Type-system techniques

Tephra uses the type system for **classification and misuse-resistance**, not for ownership or state proofs:

- **Strongly typed handle wrappers.** [`tp::VkObjectHandle<T, VkObjectType Id>`][handles-hpp] brands every raw handle with its `VkObjectType` (`VkBufferHandle`, `VkImageViewHandle`, …); a `static_assert(sizeof(TypedHandle) == sizeof(VkHandleType))` keeps the wrappers layout-compatible so `vkCastTypedHandlePtr` is a free cast. This is the same phantom-tag idea as [Ash][ash]'s handle newtypes, applied to a C++ wrapper layer.
- **Typed bitmasks.** [`tp::EnumBitMask<Enum>`][enum-tools] distinguishes "a single flag" from "a set of flags" — _"clarifies when a single bit or a mask is expected with strong typing"_ ([`user_guide.dox`][user-guide-dox]) — with `contains`/`containsAny`/`containsAll`. Tephra enums marked _Vulkan-compatible_ can be cast losslessly to their `Vk*` counterparts via `vkCastConvertibleEnum` ([`enums.hpp`][enums-hpp]), so extension-added raw values pass through.
- **Typed `pNext` chains.** [`tp::VkStructureMap`][structure-map] is _"a heterogenous container of unique Vulkan structure types"_ where structures are zero-initialized with `sType` filled from a compile-time trait (`getVkFeatureStructureType<T>()`) and chained via `pNext` automatically — used for feature/property queries and rendering-info extension chains. Elsewhere, setup structs simply accept a raw `void*` extension pointer.
- **Immutability as thread-safety.** Descriptor sets are **immutable** by design — _"Descriptor sets differ from Vulkan's by being immutable. Changing them requires waiting until the device is done with any workload that uses it, which is infeasible in practice. Instead, Tephra recycles and reuses old descriptor sets"_ ([README][readme]); `tp::utils::MutableDescriptorSet` is sugar over allocate-new-and-recycle. The general rule: _"Whenever possible, Tephra offers thread safety by virtue of immutability."_
- **Lifetime-aware array views.** `tp::ArrayView` rejects construction from temporaries at compile time (so `tp::ArrayView<int> view = {1, 2, 3};` won't compile), while `tp::ArrayParameter` permits it only in immediately-consumed function-parameter position ([`tools/array.hpp`][array-hpp]).

There is **no builder typestate, no linear/affine ownership, no compile-time pass-dependency checking** — C++17 has no facility for the first two, and the non-reordering job model makes dependencies a runtime property of recording order. Externally-synchronized objects (pools, jobs, command lists) are distinguished **in documentation only**: the user guide's thread-safety section enumerates allowed/forbidden concurrent uses ("one thread per pool"), mirroring `vk.xml` `externsync` rules without encoding them in types.

### Overhead & escape hatches

The overhead story is the library's thesis, split cleanly along the two-tier line:

| Tier                                                        | Cost                                                                                                                                                                                                                       |
| ----------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| High-level job commands (copies, clears, passes, exports)   | Runtime tracking: per-subresource access maps, barrier resolution at `submitQueuedJobs` (a _"relatively expensive operation"_), job compilation replay                                                                     |
| Low-level command-list recording (binds, draws, dispatches) | Near-raw-Vulkan: no analysis, no per-command tracking, parallel recording with per-thread `tp::CommandPool`s                                                                                                               |
| Resource creation                                           | Amortized via `tp::JobResourcePool` recycling, suballocation, and aliasing (`AliasingSuballocator`); _"the library tries to avoid allocations whenever possible, opting instead for pooling and reuse"_ ([README][readme]) |
| Handle destruction                                          | Deferred, batched against timeline values; lifetime over-extension is the accepted price (quote [above](#handle-lifetime--ownership-model))                                                                                |
| Validation                                                  | Compile-time opt-in (`TEPHRA_ENABLE_DEBUG`, `TEPHRA_ENABLE_DEBUG_NAMES`); zero cost when off                                                                                                                               |

Escape hatches back to raw Vulkan are first-class and documented in the user guide's _Vulkan interoperation_ section:

- `tp::Device::vkGetDeviceHandle` and per-object `vkGetHandle()` expose internal handles — _"this can be used, for example, to record an extension Vulkan command to a Tephra command list."_
- `tp::Device::vkLoadDeviceProcedure` loads any `PFN_vk*` directly.
- Existing Vulkan handles enter Tephra via `tp::Lifeguard` (owning or `NonOwning`) and `tp::Device::vkCreateExternalBuffer` / `vkCreateExternalImage`.
- Setup structs take `void*` `pNext` extension pointers and raw `vkAdditionalUsage` flag pass-throughs ([`buffer.hpp`][buffer-hpp], [`image.hpp`][image-hpp]); Vulkan-compatible enums accept extension-added raw values.

### Error handling & validation integration

Errors are **exceptions**, on a curated mapping from `VkResult`. [`include/tephra/errors.hpp`][errors-hpp] defines `tp::ErrorType` with each enumerant documenting which exception it maps to (`tp::OutOfMemoryError`, `tp::DeviceLostError`, `tp::OutOfDateError`, `tp::UnsupportedOperationError`, …, all deriving from `tp::RuntimeError : std::runtime_error`); results Tephra prevents by construction (e.g. `VK_ERROR_FRAGMENTED_POOL`, `VK_ERROR_OUT_OF_POOL_MEMORY`) are deliberately excluded — _"Vulkan errors that should not propagate to Tephra user."_

Validation is layered:

1. **Tephra's own validation** — enabled by the `TEPHRA_ENABLE_DEBUG` define, debug builds only, and explicitly incomplete: _"Tephra validation is far from complete. User errors or bugs in the library may silently manifest as incorrect usage of the Vulkan API, so it is recommended to also enable Vulkan validation during development."_ ([`user_guide.dox`][user-guide-dox])
2. **Vulkan validation layers** — enabled by adding `VK_LAYER_KHRONOS_validation` to `tp::ApplicationSetup`, configured through `tp::ApplicationExtension::EXT_LayerSettings` (`v0.8.0` migrated off the deprecated `VK_EXT_validation_features`, [changelog][changelog-dox]).
3. **A unified message sink** — the `tp::DebugReportHandler` interface receives both Tephra messages and (with `EXT_DebugUtils` enabled) Vulkan layer messages as `tp::DebugMessage`; `tp::utils::StandardReportHandler` is the stock stream-printing implementation ([`utils/standard_report_handler.hpp`][report-handler]).

Debug **names** thread through the whole stack: nearly every create call takes a name, `TEPHRA_ENABLE_DEBUG_NAMES` propagates them onto the internal (often suballocated) Vulkan objects for RenderDoc and the layers, and `tp::JobResourcePoolFlag::DisableSuballocation` exists purely to make suballocated resources individually identifiable while debugging.

---

## Strengths

- **The clearest articulation in this survey of the automation/overhead dividing line** — driver-style auto-sync exactly where commands are few and coarse (jobs), zero tracking where they are many and hot (command lists), with the export mechanism as the explicit bridge.
- **Subresource-granular barrier optimization without reordering**: byte-range/mip/layer-level dependency resolution, barrier reuse via persistent per-queue access maps, late barrier placement — while keeping execution order under user control.
- **Cross-queue model built on timeline semaphores + exports** cleanly separates execution ordering (`tp::JobSemaphore`) from memory visibility/layout/ownership (cross-queue export), including queue-family ownership transfer.
- **Strong pooling story**: job-local resources with recycling, layer-based image suballocation, and usage-range aliasing; growable ring buffers for staging.
- **Pragmatic interop**: typed handle wrappers, `Lifeguard`, external resource adoption, raw `pNext`/procedure access — raw Vulkan is always reachable.
- **Production exposure** via BAE Systems OneArc, with an unusually thorough user guide that documents internals (access maps, aliasing allocator, deferred destruction) rather than just API surface.

## Weaknesses

- **Pre-1.0** (`v0.8.0`): breaking changes on minor versions; ray-tracing pipelines and Vulkan profiles still planned; validation explicitly _"far from complete"_ and WIP.
- **No compile-time safety net**: lifetime classes, thread-safety rules, and export obligations live in documentation and optional runtime checks — nothing like Rust ownership ([Vulkano][vulkano]) or even builder typestate enforces them.
- **Forgotten exports are a silent-failure class**: an invalidated or missing export is legal-looking code with undefined GPU-side results, only diagnosable via validation layers / [sync validation][sync-validation].
- **Single-author bus factor** for the open-source tree, despite corporate use.
- **Hand-maintained Vulkan surface**: no `vk.xml` generation means new core versions and extensions need manual integration; uncurated extensions fall back to `void*` interop.
- **Barriers target the classic sync model** (`VkPipelineStageFlags`/`VkAccessFlags`) rather than `VK_KHR_synchronization2`'s 64-bit stage/access flags, per [`accesses.hpp`][accesses].
- **Lifetime over-extension** of deferred destruction can hold large buffer/image memory longer than strictly needed (acknowledged in the docs, with an alternative "may be implemented in the future").
- **Windows-first testing**; Linux is supported via CMake but secondary.

## Key design decisions and trade-offs

| Decision                                                           | Rationale                                                                                                       | Trade-off                                                                                                    |
| ------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Two-tier recording: tracked jobs, untracked command lists          | Auto-sync _"only for the high-level commands where it is needed the most"_; draw-call recording stays near-raw  | Pass resources must be declared; in-pass dispatch hazards are the user's problem                             |
| Export mechanism for read accesses                                 | One declaration per write covers all future reads, across passes and jobs; far less verbose than per-pass lists | A forgotten/invalidated export is a silent runtime bug; write-heavy resources need repeated re-export        |
| No pass reordering (vs. a render graph)                            | Smaller API footprint, no resource virtualization, familiar to OpenGL/DX11 users; user keeps ordering control   | Forfeits graph-level scheduling/aliasing optimizations that [Daxa][daxa]/[vuk][vuk] perform                  |
| Per-queue persistent access maps + barrier reuse                   | Minimal barriers at subresource granularity without reordering; cross-job sync on one queue is free             | Runtime cost at submit; maps are state that exports must shuttle between queues via message passing          |
| One device-wide timeline counter as job ID and semaphore value     | Unified primitive for cross-queue waits, host waits, and deferred handle destruction                            | Destruction is coarse: lifetime extended whether or not the handle was actually used recently                |
| Immutable descriptor sets                                          | Thread safety by immutability; recycling replaces the wait-until-idle mutation Vulkan would require             | Per-update set allocation; mutation patterns need `tp::utils::MutableDescriptorSet` sugar                    |
| Hand-written dispatch over `VK_NO_PROTOTYPES` headers (no codegen) | Full control of the curated surface; no generator toolchain; layout-compatible typed handles are zero-cost      | Manual upkeep per Vulkan release; registry metadata (`externsync`, valid usage) re-encoded as prose, or lost |
| Exceptions for errors, compile-time-gated validation               | Idiomatic C++17; zero validation cost in shipping builds                                                        | No `noexcept` recording path; incomplete validation pushes correctness onto Vulkan layers in debug only      |

---

## Sources

- [Dolkar/Tephra — GitHub repository][repo]
- [`README.md` — feature list, sync overhead quote, render-graph comparison][readme]
- [Tephra User Guide (rendered)][user-guide] · [`documentation/dox/user_guide.dox` — source of the guide][user-guide-dox]
- [Tephra API documentation (Doxygen)][api-docs]
- [Changelog (rendered)][changelog] · [`documentation/dox/changelog.dox`][changelog-dox]
- [`include/tephra/vulkan/handles.hpp` — `VkObjectHandle`, `Lifeguard`][handles-hpp]
- [`include/tephra/vulkan/header.hpp` — `VK_NO_PROTOTYPES` + VMA setup][header-hpp]
- [`include/tephra/vulkan/enums.hpp` — `vkCastConvertibleEnum`][enums-hpp]
- [`include/tephra/tools/enum_tools.hpp` — `EnumBitMask`][enum-tools]
- [`include/tephra/tools/structure_map.hpp` — `VkStructureMap` typed `pNext` chains][structure-map]
- [`include/tephra/tools/array.hpp` — `ArrayView` / `ArrayParameter`][array-hpp]
- [`include/tephra/errors.hpp` — `ErrorType` → exception mapping][errors-hpp]
- [`include/tephra/utils/standard_report_handler.hpp` — stock `DebugReportHandler`][report-handler]
- [`include/tephra/buffer.hpp`][buffer-hpp] · [`include/tephra/image.hpp` — `vkAdditionalUsage` pass-throughs][image-hpp]
- [`include/tephra/job.hpp` — `Job`, `JobResourcePool`, `JobSemaphore`][job-hpp]
- [`src/tephra/job/accesses.hpp` — `ResourceAccess`, access conversion][accesses]
- [`src/tephra/job/barriers.hpp` — dependency → `VkBufferMemoryBarrier`/`VkImageMemoryBarrier`][barriers]
- [`src/tephra/job/job_compile.cpp` — two-pass job compilation][job-compile]
- [`src/tephra/device/cross_queue_sync.cpp` — export broadcast between queues][cross-queue]
- [`src/tephra/device/timeline_manager.cpp`][timeline] · [`deferred_destructor.hpp`][deferred]
- [`src/tephra/vulkan/loader.cpp` — dynamic Vulkan loading][loader] · [`interface.hpp` — dispatch tables][interface]
- [Render graphs and Vulkan — a deep dive (Maister), linked from the README][maister]
- [Sascha Willems' Vulkan triangle example (the "1000 lines" baseline)][sascha-triangle]
- Related: [Daxa (C++)][daxa] · [vuk (C++)][vuk] · [Vulkano (Rust)][vulkano] · [Ash (Rust)][ash] · [Synchronization validation][sync-validation] · [Concepts][concepts] · [Comparison][comparison] · [Survey index][index]

<!-- References -->

[repo]: https://github.com/Dolkar/Tephra
[readme]: https://github.com/Dolkar/Tephra/blob/main/README.md
[user-guide]: https://dolkar.github.io/Tephra/user-guide.html
[user-guide-dox]: https://github.com/Dolkar/Tephra/blob/main/documentation/dox/user_guide.dox
[api-docs]: https://dolkar.github.io/Tephra/annotated.html
[changelog]: https://dolkar.github.io/Tephra/changelog.html
[changelog-dox]: https://github.com/Dolkar/Tephra/blob/main/documentation/dox/changelog.dox
[handles-hpp]: https://github.com/Dolkar/Tephra/blob/main/include/tephra/vulkan/handles.hpp
[header-hpp]: https://github.com/Dolkar/Tephra/blob/main/include/tephra/vulkan/header.hpp
[enums-hpp]: https://github.com/Dolkar/Tephra/blob/main/include/tephra/vulkan/enums.hpp
[enum-tools]: https://github.com/Dolkar/Tephra/blob/main/include/tephra/tools/enum_tools.hpp
[structure-map]: https://github.com/Dolkar/Tephra/blob/main/include/tephra/tools/structure_map.hpp
[array-hpp]: https://github.com/Dolkar/Tephra/blob/main/include/tephra/tools/array.hpp
[errors-hpp]: https://github.com/Dolkar/Tephra/blob/main/include/tephra/errors.hpp
[report-handler]: https://github.com/Dolkar/Tephra/blob/main/include/tephra/utils/standard_report_handler.hpp
[buffer-hpp]: https://github.com/Dolkar/Tephra/blob/main/include/tephra/buffer.hpp
[image-hpp]: https://github.com/Dolkar/Tephra/blob/main/include/tephra/image.hpp
[job-hpp]: https://github.com/Dolkar/Tephra/blob/main/include/tephra/job.hpp
[accesses]: https://github.com/Dolkar/Tephra/blob/main/src/tephra/job/accesses.hpp
[barriers]: https://github.com/Dolkar/Tephra/blob/main/src/tephra/job/barriers.hpp
[job-compile]: https://github.com/Dolkar/Tephra/blob/main/src/tephra/job/job_compile.cpp
[cross-queue]: https://github.com/Dolkar/Tephra/blob/main/src/tephra/device/cross_queue_sync.cpp
[timeline]: https://github.com/Dolkar/Tephra/blob/main/src/tephra/device/timeline_manager.cpp
[deferred]: https://github.com/Dolkar/Tephra/blob/main/src/tephra/device/deferred_destructor.hpp
[loader]: https://github.com/Dolkar/Tephra/blob/main/src/tephra/vulkan/loader.cpp
[interface]: https://github.com/Dolkar/Tephra/blob/main/src/tephra/vulkan/interface.hpp
[maister]: https://themaister.net/blog/2017/08/15/render-graphs-and-vulkan-a-deep-dive/
[sascha-triangle]: https://github.com/SaschaWillems/Vulkan/blob/master/examples/triangle/triangle.cpp
[VMA]: https://gpuopen.com/vulkan-memory-allocator/
[daxa]: ./cpp-daxa.md
[vuk]: ./cpp-vuk.md
[vulkano]: ./rust-vulkano.md
[ash]: ./rust-ash.md
[sync-validation]: ./sync-validation.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
