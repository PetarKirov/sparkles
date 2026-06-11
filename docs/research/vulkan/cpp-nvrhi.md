# NVRHI (C++)

NVIDIA's production rendering hardware interface — one API over D3D11, D3D12, and Vulkan — and the catalog's clearest production example of [auto-sync-by-default with per-resource opt-out][auto-sync]: every command list runs a [D3D12-style resource-state tracker][named-states] that places barriers automatically, and every piece of that tracking can be selectively switched off (`setEnableAutomaticBarriers`, `keepInitialState`, `setPermanentTextureState`, per-resource UAV-barrier toggles) when a hot path needs manual control.

| Field          | Value                                                                                                          |
| -------------- | -------------------------------------------------------------------------------------------------------------- |
| Language       | C++17 (`CMakeLists.txt` sets `CMAKE_CXX_STANDARD 17`)                                                          |
| License        | MIT                                                                                                            |
| Repository     | [NVIDIA-RTX/NVRHI][repo] (formerly `NVIDIAGameWorks/nvrhi`; the old URL redirects)                             |
| Documentation  | [ProgrammingGuide.md][pg] · [Tutorial.md][tut] (in-repo)                                                       |
| Category       | Render-graph / auto-sync layer (cross-API RHI with command-list-scoped state tracking — no graph, no task DSL) |
| First release  | Repository created July 13, 2021 (open-sourced together with the [Donut][donut] framework)                     |
| Latest release | No tagged releases — rolling `main` (CMake `project(nvrhi VERSION 1.0.0)`); last pushed June 10, 2026          |

> [!NOTE]
> NVRHI is **not Vulkan-first**: it abstracts Direct3D 11, Direct3D 12, and Vulkan 1.3 behind one
> interface (Windows x64, Linux x64/ARM64), and its synchronization vocabulary is D3D12's resource
> states, _lowered onto_ Vulkan barriers. It is the rendering layer under NVIDIA's [Donut][donut]
> sample framework and the RTX SDK sample suite (RTXDI, RTXGI, RTX Path Tracing), so its
> auto-sync design has shipped in many production-grade ray-tracing codebases.

---

## Overview

### What it solves

NVRHI targets the same two Vulkan/D3D12 pain points as [Daxa][daxa] and [vuk][vuk] —
synchronization and lifetime — but from the opposite direction: instead of a redesigned
modern-GPU-only API, it offers a **DX11-flavoured programming model** portable across three
APIs of very different explicitness. The [programming guide][pg] states the contract up front:

> _"Unlike the modern GAPIs, the library tracks the resources created by the application, where
> they are used, when the GPU work using the resources finishes, and when it's safe to release the
> resources. The library also implements resource state tracking and automatic barrier placement,
> although it needs some hints to do so and maintain support for multiple command lists that might
> use the same resource."_ ([`doc/ProgrammingGuide.md`][pg])

The "hints" caveat is the design's honest core: because multiple independently-recorded command
lists may touch the same resource, no single command list can know a resource's current state.
NVRHI resolves this with three explicit per-resource policies
(see [Synchronization safety](#synchronization-safety)) rather than a global mutex-guarded state
database — and that decision is what makes both parallel recording and per-resource opt-out cheap.

### Design philosophy

The [README][readme] sells exactly the trade-off this survey cares about, with the opt-out in the
same breath as the feature:

> _"Automatic tracking of resource states and barrier placement (optional)"_ … _"Automatic
> tracking of resource usage and lifetime, deferred and safe resource destruction"_ … _"Convenient
> and efficient resource binding model with little runtime overhead"_ ([README][readme])

Philosophically NVRHI is a **lowest-common-denominator with escape hatches**: the API is "mostly a
blend between DX11 and DX12, with a flavor of Vulkan" ([programming guide][pg]), each command-list
method documents its per-API lowering (`- Vulkan: Maps to vkCmdPushConstants`,
[`include/nvrhi/nvrhi.h`][nvrhi-h]), and `getNativeObject`/`createHandleForNativeTexture` provide
two-way interop with the underlying API when the abstraction runs out.

---

## How it works

The public interface is one hand-written header, [`include/nvrhi/nvrhi.h`][nvrhi-h] (~3,900
lines): COM-style refcounted interfaces (`IDevice`, `ICommandList`, `ITexture`, `IBuffer`, …) held
through `RefCountPtr<T>` handles (`TextureHandle`, `BufferHandle`). The application creates the
native device itself and wraps it — on Vulkan via `nvrhi::vulkan::createDevice(DeviceDesc)`, whose
[`DeviceDesc`][vulkan-h] takes the application's `VkInstance`/`VkPhysicalDevice`/`VkDevice`, up to
three `VkQueue`s (graphics required; compute and transfer optional), and the enabled extension
lists. Command lists are recorded between `open()`/`close()` and run with
`IDevice::executeCommandList`, which returns a 64-bit _instance_ used for cross-queue waits
(`queueWaitForCommandList`).

An NVRHI command list is fatter than a `VkCommandBuffer`:

> _"On DX12 and Vulkan, NVRHI command lists do not map to GAPI command lists 1:1, they aggregate
> more resources in order to make the programming model easier to use. One command list will
> typically keep multiple GAPI command lists and use them in a round-robin fashion if the
> previously recorded instance of the command list is still being executed when the command list
> is re-opened."_ ([`doc/ProgrammingGuide.md`][pg])

Each command list owns its upload manager (versioned constant/upload buffers), its acceleration-
structure scratch allocator, and — centrally for this survey — its own
`CommandListResourceStateTracker` ([`src/common/state-tracking.h`][st-h]), shared by the D3D12 and
Vulkan backends.

### Binding generation & API coverage

**Nothing is generated from `vk.xml`; the abstraction is hand-written** — necessarily, since the
interface must be the intersection-plus-union of three APIs that no Vulkan registry describes.
Registry metadata ([`externsync`][externsync], success codes, structure-chain validity) does not
survive into the interface; thread-safety and per-API behaviour are hand-maintained doc comments
on each `ICommandList` method. Generation appears only **indirectly**: the Vulkan backend is
written against [Vulkan-Hpp][vulkan-hpp] (`vk::ImageMemoryBarrier2`, `vk::DependencyInfo` in
[`src/vulkan/vulkan-state-tracking.cpp`][vkst]), so the type-safe enums and builders it uses
internally are `vk.xml` products one layer down.

Coverage is broad for a portability layer: graphics, compute, ray tracing (TLAS/BLAS, opacity
micromaps, the optional RTXMU compaction integration), meshlet pipelines, variable-rate shading,
sparse/tiled resources (`Queue::bindSparse` in [`src/vulkan/vulkan-queue.cpp`][vkq]), cooperative
vectors, and push constants (exactly one block per pipeline). Non-portable features are kept and
labelled rather than dropped — sampler-feedback methods are documented _"DX11, Vulkan:
Unsupported"_ ([`nvrhi.h`][nvrhi-h]) — and the [`ResourceStates`][named-states] enum carries
DX12-shaped bits (`PixelShaderResource` vs `NonPixelShaderResource`) that Vulkan must approximate
(see [Overhead & escape hatches](#overhead--escape-hatches)).

### Handle lifetime & ownership model

Lifetime is **COM-style reference counting plus per-queue [deferred destruction][deferred]**.
Every NVRHI object descends from `IResource` with `AddRef`/`Release`; `RefCountPtr<T>` is
documented as "same as `ComPtr` provided by WRL" ([programming guide][pg]). The safety mechanism
is internal references: binding sets strongly reference their resources, and each in-flight
Vulkan command buffer accumulates a `referencedResources` vector while recording
([`src/vulkan/vulkan-commandlist.cpp`][vkcl]). Each `Queue` owns a **timeline semaphore**
(`trackingSemaphore`, [`src/vulkan/vulkan-queue.cpp`][vkq]) signalled with the submission ID;
`IDevice::runGarbageCollection()` — "supposed to be called at least once per frame"
([programming guide][pg]) — reads `vkGetSemaphoreCounterValue` per queue and, for every command
buffer with `submissionID <= lastFinishedID`, clears its `referencedResources` and returns it to
the pool ([`vulkan-queue.cpp`][vkq], `CommandListLifetimeTracker::runGarbageCollection`). The
result is the guide's "fire and forget" model:

> _"it is valid to create resources and even pipelines in local scope, record the draw commands
> into a command list, maybe execute that command list, and just exit the scope"_
> ([`doc/ProgrammingGuide.md`][pg])

The tracking has a deliberate hole at the [bindless][bindless] boundary:

> _"descriptor tables do not keep strong references to their resources, and therefore provide no
> resource lifetime tracking or automatic barrier placement. Applications must take care to
> synchronize descriptor table writes with GPU work and to ensure the correct state of each
> referenced resource - most likely, by using only permanent resources in descriptor tables."_
> ([`doc/ProgrammingGuide.md`][pg])

— i.e. exactly where per-resource tracking would be O(thousands), NVRHI turns it off and points
users at the permanent-state escape hatch instead.

### Synchronization safety

NVRHI's model is **[named usage states][named-states] + command-list-scoped automatic tracking**.
A resource is in one `ResourceStates` bitmask at a time (`ShaderResource`, `UnorderedAccess`,
`RenderTarget`, `CopyDest`, `AccelStructWrite`, … — [`nvrhi.h`][nvrhi-h]); state-setting commands
(`setGraphicsState`, `writeTexture`, copies, clears) call `requireTextureState`/
`requireBufferState`, which diff against the tracker and append `TextureBarrier`/`BufferBarrier`
records to a pending list ([`src/common/state-tracking.cpp`][st-cpp]). Barriers flush lazily:
`commitBarriers()` — called implicitly before draws/dispatches — ends any dynamic render pass and
emits **one batched `vkCmdPipelineBarrier2`** for images and one for buffers
([`src/vulkan/vulkan-state-tracking.cpp`][vkst], `commitBarriersInternal`).

Because trackers are per-command-list, the cross-command-list state problem is solved by three
user-chosen policies ([programming guide][pg]):

1. **Explicit bracketing** — `beginTrackingTextureState`/`beginTrackingBufferState` declares the
   entry state after `open()`; `setTextureState`/`setBufferState` transitions to a known exit
   state before `close()`.
2. **`keepInitialState`** — set on `TextureDesc`/`BufferDesc` with an `initialState`: _"command
   lists that use the texture will automatically begin tracking the texture from the initial
   state and transition it to the initial state on command list close"_ ([`nvrhi.h`][nvrhi-h]).
   The invariant "always in `initialState` at command-list boundaries" replaces global tracking.
3. **Permanent state** — `setPermanentTextureState`/`setPermanentBufferState` freezes a static
   resource (material textures, vertex buffers): _"Permanent resources do not require any state
   tracking and are therefore cheaper on the CPU side"_ ([programming guide][pg]). Subsequent
   incompatible uses are diagnosed by `verifyPermanentResourceState`
   ([`state-tracking.cpp`][st-cpp]).

**[Hazard][hazards]-class coverage.** Transitions cover RAW/WAW across state changes; the
same-state WAW case (UAV→UAV) is handled by automatic **UAV barriers** _"between successive uses
of the same resource in `UnorderedAccess` state"_ ([programming guide][pg]) — on Vulkan a
`GENERAL`-layout `vkCmdPipelineBarrier2` with shader read+write access both sides. The tracker
emits a barrier when `transitionNecessary || uavNecessary`, where `uavNecessary` requires
`tracking->enableUavBarriers || !tracking->firstUavBarrierPlaced` ([`state-tracking.cpp`][st-cpp])
— so `setEnableUavBarriersForTexture(tex, false)` suppresses _inter-dispatch_ UAV barriers but the
first transition into `UnorderedAccess` is still placed, a carefully-shaped opt-out for
accumulation passes where dispatches are known independent.

**The global opt-out** is one method on the command list:

> _"Enables or disables the automatic barrier placement on set[...]State, copy, write, and clear
> operations. By default, automatic barriers are enabled, but can be optionally disabled to
> improve CPU performance and/or specific barrier placement. When automatic barriers are disabled,
> it is application's responsibility to set correct states for all used resources."_
> (`setEnableAutomaticBarriers`, [`include/nvrhi/nvrhi.h`][nvrhi-h])

In manual mode the _same_ tracker machinery is driven by hand — `setTextureState`/`setBufferState`
plus the convenience sweeps `setResourceStatesForBindingSet` and `setResourceStatesForFramebuffer`
accumulate pending barriers, `commitBarriers()` flushes them — so manual and automatic code share
one barrier path and one diagnostic system. Mis-declared entry states are caught at runtime, not
compile time: _"Unknown prior state of texture …. Call CommandList::beginTrackingTextureState(...)
before using the texture or use the keepInitialState and initialState members of TextureDesc."_
([`state-tracking.cpp`][st-cpp]).

**Host-side [external synchronization][externsync]** is prose, not types: command lists are
single-threaded objects, parallel recording means one command list per thread, and cross-queue
ordering uses `IDevice::queueWaitForCommandList(waitQueue, executionQueue, instance)` against the
per-queue timeline semaphores. [Queue-family ownership transfer][qfot] is **not modeled at all**:
every barrier sets `VK_QUEUE_FAMILY_IGNORED` on both sides ([`vulkan-state-tracking.cpp`][vkst])
and images are created with `vk::SharingMode::eExclusive`
([`src/vulkan/vulkan-texture.cpp`][vk-tex]) — the D3D12-shaped model simply has no vocabulary for
QFOT, and NVRHI relies on same-family queues / ignored-family semantics in practice.

### Type-system techniques

Modest, deliberately so — NVRHI predates and out-ships most type-level safety experiments:

- **Distinct interface types per resource kind** (`ITexture` vs `IBuffer` vs `rt::IAccelStruct`)
  and typed handles (`TextureHandle = RefCountPtr<ITexture>`), so kind confusion is a compile
  error; but states, subresources, and slots are all plain integers/bitmasks.
- **`ResourceStates` as `enum class` bitflags** — the whole sync vocabulary is one 32-bit enum
  ([`nvrhi.h`][nvrhi-h]); nothing distinguishes read-only from read-write states in types.
- **Builder setters** (`CommandListParameters& setQueueType(...)`, `TextureDesc` fluent setters)
  for ergonomics only — no typestate; command-list `open()`/`close()` ordering is checked at
  runtime by the validation layer, not by types.
- **Tag-dispatched native interop** — `getNativeObject(ObjectType)` returns a type-erased
  `Object` keyed by an `ObjectType` enum (`VK_Image`, `D3D12_Resource`, …), the classic
  cross-API escape-hatch pattern.

Absent, and worth recording: no [phantom/branded types][phantom], no [typestate][typestate], no
ownership beyond refcounting, no compile-time distinction between implicitly and explicitly
synchronized operations. NVRHI's safety budget goes entirely into **runtime tracking plus a
wrappable validation layer** — the same position as [Daxa][daxa], with even less type-level
ambition, and the diametric opposite of [vulkano][vulkano].

### Overhead & escape hatches

The cost model is **per-use hash-map tracking, amortized by opt-outs**:

- **Tracking cost.** Each `requireTextureState` does an `std::unordered_map` lookup keyed on the
  resource pointer, a per-subresource state diff, and possibly a vector push
  ([`state-tracking.cpp`][st-cpp]). This runs on every state-setting command for every tracked
  resource — the cost `setEnableAutomaticBarriers(false)` and permanent states exist to remove.
  Binding-set application is incremental: `insertResourceBarriersForBindingSets` diffs new
  against current bindings (`arrayDifferenceMask`) and only re-walks changed sets — except sets
  with UAV bindings, which are re-walked every draw to place UAV barriers
  ([`vulkan-state-tracking.cpp`][vkst]).
- **The opt-out ladder** (cheapest correctness work to most): default automatic tracking →
  `keepInitialState` (no per-list bracketing calls) → `setEnableUavBarriersFor*(.., false)`
  (suppress inter-dispatch UAV sync) → `setPermanentTexture/BufferState` (resource leaves
  tracking entirely) → `setEnableAutomaticBarriers(false)` + manual `setTextureState`/
  `commitBarriers` (application-placed barriers through the same accumulator).
- **Lowering is conservative — the Vulkan expressiveness tax.** `convertResourceState`
  ([`src/vulkan/vulkan-constants.cpp`][vkc]) maps state bits through a fixed table to
  `(stage, access, layout)` triples, so precision is capped by the table:
  `NonPixelShaderResource`, `ConstantBuffer`, and `UnorderedAccess` all lower to
  `vk::PipelineStageFlagBits2::eAllCommands` — a full pipeline sync where hand-written Vulkan
  would scope to, say, `COMPUTE_SHADER`. Buffer barriers are whole-buffer
  (`setOffset(0).setSize(buffer->desc.byteSize)`, [`vulkan-state-tracking.cpp`][vkst]). There are
  no split barriers/[events][events], no fine-grained `VkAccessFlags2` beyond the table, no QFOT,
  and image layouts are dictated per state bit (with one curated exception: `ShaderResource |
DepthRead` resolves to `eDepthStencilReadOnlyOptimal`, [`vulkan-constants.cpp`][vkc]). This is
  the cross-API price: the sync interface can express only what D3D11 can survive and D3D12 can
  name.
- **Escape hatches** are first-class and bidirectional: `getNativeObject`/`getNativeView` hand
  out `VkImage`/`VkImageView`/`VkBuffer`/`VkDevice`/queues; `createHandleForNativeTexture`/
  `createHandleForNativeBuffer` _import_ externally-created native resources into the tracking
  system ([`nvrhi.h`][nvrhi-h]) — the pattern swapchains use.

### Error handling & validation integration

No exceptions and no result codes on the hot path: fallible operations report through the
application-supplied `IMessageCallback` and return null handles. The header is explicit that
severity policy belongs to the application:

> _"NVRHI will call message(...) whenever it needs to signal something. The application is free
> to ignore the messages, show message boxes, or terminate."_
> ([`include/nvrhi/nvrhi.h`][nvrhi-h])

Validation is an **interposing wrapper device** — `nvrhi::validation::createDevice` wraps any
`IDevice` and every command list it creates ([`src/validation/validation-commandlist.cpp`][val]),
checking the runtime state machine the types don't ("Cannot open a command list that is already
open", "A command list should be executed before it is reopened", at most one immediate command
list open). The state tracker itself diagnoses sync misuse at `MessageSeverity::Error` (unknown
prior state, permanent-state violations via `verifyPermanentResourceState`,
[`state-tracking.cpp`][st-cpp]). Since NVRHI places the barriers, [Khronos sync
validation][sync-validation] findings in tracked code indicate NVRHI bugs or lied-about entry
states; the layers regain their usual role wherever the application opted out. Nsight Aftermath
crash-dump integration is built in (`aftermathEnabled` in [`DeviceDesc`][vulkan-h]), and
`beginMarker`/`endMarker` lower to `vkCmdBeginDebugUtilsLabelEXT`.

---

## Strengths

- **The clearest production statement of auto-sync-by-default, opt-out-by-resource**: one default
  that is always correct, plus a graded ladder (`keepInitialState` → UAV-barrier toggles →
  permanent states → fully manual) that removes tracking cost exactly where profiling says to —
  and manual mode reuses the same accumulator/diagnostics instead of a separate API.
- **Per-resource entry-state policies solve the multi-command-list problem without a global lock**,
  preserving parallel recording — a problem [render graphs][render-graph] solve by owning the
  whole frame and [vulkano][vulkano]-style trackers solve with runtime locking.
- **Lifetime is genuinely fire-and-forget**: refcounts + per-queue timeline semaphores + once-a-
  frame `runGarbageCollection()`, with command-list-attached references making even transient
  resources safe.
- **Battle-tested breadth**: ray tracing (incl. opacity micromaps, RTXMU), meshlets, VRS, sparse
  resources, cooperative vectors — under one interface shipped across NVIDIA's sample/SDK fleet.
- **Two-way native interop** (`getNativeObject` out, `createHandleForNativeTexture` in) keeps the
  abstraction non-totalizing.
- **The validation story is layered like Vulkan's own**: zero-cost release builds, a wrapper
  device in debug — a structure a D library could mirror with a compile-time hook policy instead
  of a runtime wrapper.

## Weaknesses

- **D3D12-shaped sync caps Vulkan precision**: fixed state→`(stage, access, layout)` table with
  `eAllCommands` for common states, whole-buffer barriers, no split barriers/events, no QFOT, no
  per-aspect layouts — over-synchronization a hand-tuned Vulkan renderer (or a graph like
  [vuk][vuk]'s) would avoid.
- **Tracking is per-use CPU work** (hash lookups + subresource diffs on every state-setting call);
  the opt-outs exist precisely because the default shows up in profiles of draw-heavy frames.
- **Cross-command-list correctness rests on honest declarations** — a wrong
  `beginTrackingTextureState` or a violated `keepInitialState` invariant is a runtime error
  message at best and a GPU hazard at worst; nothing is compile-time.
- **Bindless breaks the safety net by design**: descriptor tables carry no lifetime or state
  tracking, pushing users to permanent states — safe but layout-frozen.
- **No `vk.xml`-derived metadata**: `externsync`, success-code, and validity knowledge is
  hand-written doc-comment prose that can drift; thread-safety contracts are conventions.
- **No versioning signal**: no tags or releases, CMake version pinned at `1.0.0` — consumers
  vendor a commit (the intended model, but it complicates downstream packaging).

## Key design decisions and trade-offs

| Decision                                                              | Rationale                                                                                       | Trade-off                                                                                       |
| --------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| One interface over D3D11/D3D12/Vulkan                                 | Renderer code ports unmodified; NVIDIA SDK samples ship on all three                            | Sync vocabulary is the D3D12 intersection; Vulkan-only expressiveness (events, QFOT) is dropped |
| D3D12-style `ResourceStates` instead of stage/access/layout           | One enum a human can reason about; identical model on all backends                              | Fixed conservative lowering table; `eAllCommands` stages; whole-buffer barriers                 |
| Command-list-scoped tracker + 3 entry-state policies                  | No global state database → parallel recording stays lock-free                                   | User must pick a policy per resource; wrong hints surface at runtime                            |
| `setEnableAutomaticBarriers` / permanent states / UAV-barrier toggles | "improve CPU performance and/or specific barrier placement" where tracking shows up in profiles | Manual islands forfeit the guarantee; correctness burden returns to the application             |
| Auto UAV barriers between successive `UnorderedAccess` uses           | WAW hazards covered by default; first barrier always placed even when toggled off               | Re-walks UAV binding sets every draw; independent dispatches pay until opted out                |
| COM refcounts + per-queue timeline-semaphore GC                       | Fire-and-forget lifetimes; one `runGarbageCollection()` call per frame                          | Frees are batched/deferred; upload/scratch pools never shrink short of dropping the list        |
| `IMessageCallback` + wrapper validation device, no exceptions         | Zero-cost release path; app owns severity policy; validation is opt-in layering                 | Errors are observational — execution continues unless the app terminates                        |
| Hand-written header, no `vk.xml` generation                           | The cross-API surface exists in no registry; per-API behaviour documented per method            | No machine-checked `externsync`/validity metadata; doc comments can drift                       |

---

## Sources

- [NVIDIA-RTX/NVRHI — GitHub repository][repo] · [README][readme]
- [`doc/ProgrammingGuide.md` — state-tracking policies, lifetime model, binding model][pg] · [`doc/Tutorial.md`][tut]
- [`include/nvrhi/nvrhi.h` — `ResourceStates`, `keepInitialState`, `setEnableAutomaticBarriers` et al. doc comments][nvrhi-h]
- [`include/nvrhi/vulkan.h` — `DeviceDesc`, queue/extension wiring][vulkan-h]
- [`src/common/state-tracking.h` / `.cpp` — `CommandListResourceStateTracker`, UAV-barrier logic, diagnostics][st-h] ([implementation][st-cpp])
- [`src/vulkan/vulkan-state-tracking.cpp` — barrier lowering to `vkCmdPipelineBarrier2`, `VK_QUEUE_FAMILY_IGNORED`][vkst]
- [`src/vulkan/vulkan-constants.cpp` — `g_ResourceStateMap` state→(stage, access, layout) table][vkc]
- [`src/vulkan/vulkan-queue.cpp` — timeline `trackingSemaphore`, `CommandListLifetimeTracker::runGarbageCollection`][vkq]
- [`src/vulkan/vulkan-commandlist.cpp` — `referencedResources`, submission/recording IDs][vkcl]
- [`src/vulkan/vulkan-texture.cpp` — `eExclusive` sharing mode][vk-tex]
- [`src/validation/validation-commandlist.cpp` — wrapper validation layer][val]
- [NVIDIA-RTX/Donut — the sample framework built on NVRHI][donut]
- Related: [Daxa (C++)][daxa] · [vuk (C++)][vuk] · [Tephra (C++)][tephra] · [Granite (C++)][granite] · [vulkano (Rust)][vulkano] · [wgpu (Rust)][wgpu] · [Vulkan-Hpp (C++)][vulkan-hpp] · [Sync validation][sync-validation] · [Concepts][concepts] · [Comparison][comparison] · [Survey index][index]

<!-- References -->

[repo]: https://github.com/NVIDIA-RTX/NVRHI
[readme]: https://github.com/NVIDIA-RTX/NVRHI/blob/main/README.md
[pg]: https://github.com/NVIDIA-RTX/NVRHI/blob/main/doc/ProgrammingGuide.md
[tut]: https://github.com/NVIDIA-RTX/NVRHI/blob/main/doc/Tutorial.md
[nvrhi-h]: https://github.com/NVIDIA-RTX/NVRHI/blob/main/include/nvrhi/nvrhi.h
[vulkan-h]: https://github.com/NVIDIA-RTX/NVRHI/blob/main/include/nvrhi/vulkan.h
[st-h]: https://github.com/NVIDIA-RTX/NVRHI/blob/main/src/common/state-tracking.h
[st-cpp]: https://github.com/NVIDIA-RTX/NVRHI/blob/main/src/common/state-tracking.cpp
[vkst]: https://github.com/NVIDIA-RTX/NVRHI/blob/main/src/vulkan/vulkan-state-tracking.cpp
[vkc]: https://github.com/NVIDIA-RTX/NVRHI/blob/main/src/vulkan/vulkan-constants.cpp
[vkq]: https://github.com/NVIDIA-RTX/NVRHI/blob/main/src/vulkan/vulkan-queue.cpp
[vkcl]: https://github.com/NVIDIA-RTX/NVRHI/blob/main/src/vulkan/vulkan-commandlist.cpp
[vk-tex]: https://github.com/NVIDIA-RTX/NVRHI/blob/main/src/vulkan/vulkan-texture.cpp
[val]: https://github.com/NVIDIA-RTX/NVRHI/blob/main/src/validation/validation-commandlist.cpp
[donut]: https://github.com/NVIDIA-RTX/Donut
[auto-sync]: ./concepts.md#auto-sync-via-per-resource-usage-tracking
[named-states]: ./concepts.md#simplified-barrier-vocabulary-named-usage-states
[externsync]: ./concepts.md#external-synchronization--externsync
[qfot]: ./concepts.md#queue-family-ownership-transfer-qfot
[hazards]: ./concepts.md#hazards-rawwarwaw--syncvals-taxonomy
[events]: ./concepts.md#events-split-barriers
[deferred]: ./concepts.md#deferred-destruction
[bindless]: ./concepts.md#bindless-descriptors
[render-graph]: ./concepts.md#render-graph--task-graph--frame-graph
[phantom]: ./concepts.md#phantom--branded-types
[typestate]: ./concepts.md#typestate
[daxa]: ./cpp-daxa.md
[vuk]: ./cpp-vuk.md
[tephra]: ./cpp-tephra.md
[granite]: ./cpp-granite.md
[vulkano]: ./rust-vulkano.md
[wgpu]: ./rust-wgpu.md
[vulkan-hpp]: ./cpp-vulkan-hpp.md
[sync-validation]: ./sync-validation.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
