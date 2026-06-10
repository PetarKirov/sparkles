# Daxa (C++)

An opinionated, modern-hardware-only GPU API built on Vulkan, whose two pillars — bindless-by-default resource access through generational IDs and the `TaskGraph` render-graph utility that derives all barriers and semaphores from declared task attachments — aim to remove the parts of Vulkan that are "irrelevant on contemporary hardware" without giving up explicit control.

| Field          | Value                                                                                         |
| -------------- | --------------------------------------------------------------------------------------------- |
| Language       | C++20 (core implemented as a C API with a thin C++ wrapper)                                   |
| License        | MIT                                                                                           |
| Repository     | [Ipotrick/Daxa][repo]                                                                         |
| Documentation  | [docs.daxa.dev][docs] · [TaskGraph wiki][tg-wiki] · [Bindless wiki][bindless-wiki]            |
| Category       | Render-graph / auto-sync layer (full GPU abstraction, not a 1:1 binding)                      |
| First release  | `0.1.0` — October 13, 2022                                                                    |
| Latest release | `3.6` — May 3, 2026 (API stability committed "until early 2027" per the [release notes][rel]) |

> [!NOTE]
> Daxa explicitly targets **modern GPUs only** — NVIDIA Turing+, AMD RDNA3+, Intel Arc — and makes
> features like buffer device address, descriptor indexing with update-after-bind, timeline
> semaphores, dynamic rendering, and `VK_EXT_host_image_copy` **mandatory**. There is no fallback
> path for older hardware; this is the load-bearing assumption behind both the bindless model and
> the simplified synchronization story.

---

## Overview

### What it solves

Raw Vulkan burdens the user with three large, error-prone bookkeeping domains: **descriptor
management** (pools, set layouts, allocation, writes, binding points), **synchronization**
(pipeline barriers, image layout transitions, semaphores, queue-family ownership), and **resource
lifetime** (a `VkBuffer` must not be destroyed while any submitted command buffer still references
it). Bindings like [Vulkan-Hpp][vulkan-hpp] make this bookkeeping type-safer but no smaller;
runtime-tracking wrappers like [vulkano][vulkano] make it automatic but pay per-call costs.

Daxa instead **redesigns the API surface** so that two of the three domains mostly disappear and
the third is automated by an optional layer:

- **Descriptors disappear.** Buffers, images, samplers, and acceleration structures "are all
  exclusively accessed via IDs or pointers" ([README][readme]) — a single internal mega descriptor
  set, indexed by the resource ID, is bound once. The user never touches a `VkDescriptorSet`.
- **Lifetimes are deferred.** Destroying a resource "zombifies" it; the actual `vkDestroy*` call
  happens in `collect_garbage()` once per-queue timeline semaphores prove the GPU has caught up
  ([`include/daxa/device.hpp`][device-hpp]).
- **Synchronization is automated** by [`TaskGraph`](#synchronization-safety), a render graph that
  compiles declared per-task resource accesses into batched `vkCmdPipelineBarrier2` calls, task
  reordering, transient-memory aliasing, and cross-queue semaphores.

### Design philosophy

The [README][readme] leads with the stance that defines every design choice:

> _"Strong modern GPU focus - no legacy hardware compromises"_ … _"Bindless by default – no
> descriptor management nor bindings"_

and sells `TaskGraph` on amortized cost rather than zero cost — an

> _"efficient precompilation model: allows you to record graph once and execute it many times,
> significantly reducing CPU overhead"_ ([README][readme])

Daxa is **not a binding**: it is a curated replacement API in the same family as [vuk][vuk] and
[Tephra][tephra] (and, at a higher remove, [wgpu][wgpu]). It trades 1:1 Vulkan coverage for a
surface small enough that its safety claims — generational-ID validity checks, deferred
destruction, graph-derived sync — can actually be enforced, backed by "tons of validation checks
with detailed error messages explaining the issue and potential solutions" ([README][readme]).

---

## How it works

The core (`Instance`, `Device`, `CommandRecorder`, `Swapchain`, pipelines, sync primitives) is
implemented as a **C API** (`include/daxa/c/*.h`, implemented in `src/impl_*.cpp`); the public C++
classes are a thin layer over it ([`src/cpp_wrapper.cpp`][cpp-wrapper]). `TaskGraph` is an optional
utility (`include/daxa/utils/task_graph.hpp`, [`src/utils/impl_task_graph.cpp`][impl-tg]) layered
purely on the core API. A task is declared with a builder, naming its accesses; the callback only
records commands:

```cpp
// docs.daxa.dev/wiki/taskgraph/ — task declaration
daxa::TaskImageView src = ...;
daxa::TaskImageView dst = ...;
graph.add_task(daxa::Task::Transfer("example task")
    .reads(src)
    .writes(dst)
    .executes([=](daxa::TaskInterface ti){
        copy_image_to_image(ti.recorder, ti.id(src), ti.id(dst), blur_width);
    }));
```

The graph is then `submit()`ed / `present()`ed, `complete()`d (compiled) once, and `execute()`d
every frame, optionally re-pointing the persistent `TaskBuffer`/`TaskImage` handles at different
real resources between executions.

### Binding generation & API coverage

**Daxa does not generate anything from `vk.xml` — and this absence is structural, not an
omission.** The API is hand-authored: every entry point is a designed function like
`daxa_dvc_create_buffer`, not a projection of a Vulkan command. Consequently **no registry
metadata (`externsync`, `optional`, success/error codes, structure-chain validity) survives into
the type system** — it cannot, because the Vulkan surface it annotates is hidden. Thread-safety
contracts are instead re-documented by hand on each type (see
[Synchronization safety](#synchronization-safety)), and `pNext`-style extensibility is replaced by
versioned info structs (`BufferInfo`, `ImageInfo`, `TaskGraphInfo`) with designated-initializer
defaults.

Coverage is deliberately partial but deep where it matters: compute, raster (dynamic rendering
only — no `VkRenderPass`), ray tracing (TLAS/BLAS, RT pipelines), mesh shaders, multi-queue
(main + async compute + async transfer), host image copy, and a shader build system
(`PipelineManager` with `#include` resolution, hot reload, and SPIR-V caching for GLSL and Slang).
What is _not_ exposed: descriptor sets, render passes, sparse binding, most of the extension zoo —
by design. The one piece of code generation Daxa does perform is **host↔shader code sharing**: the
`DAXA_DECL_TASK_HEAD_BEGIN` macro family expands the same declaration into a C++ attachment list
and a GLSL/Slang struct (see [Type-system techniques](#type-system-techniques)).

### Handle lifetime & ownership model

All GPU objects are referred to by 64-bit **generational IDs** defined in
[`include/daxa/gpu_resources.hpp`][gpures-hpp]:

```cpp
// include/daxa/gpu_resources.hpp (abridged)
struct GPUResourceId {
    u64 index   : ID_INDEX_BITS   = {};   // slot in the resource pool
    u64 version : ID_VERSION_BITS = {};   // generation; 0 == empty/invalid
    auto is_empty() const -> bool { return version == 0; }
};
// BufferId, ImageId, ImageViewId, SamplerId, TlasId, BlasId are distinct
// structs with this layout; ImageId::default_view() yields an ImageViewId.
```

The backing pool ([`src/impl_gpu_resources.hpp`][impl-gpures]) is a paged slot table with a
free-index stack. Each slot packs the resource's hot data together with its **version and an
atomic reference count** in one 64-bit atomic (`HotDataAndVersion`); freeing a slot bumps the
version so a stale ID's `version` no longer matches — the classic generational-index
use-after-free defence. Two source comments carry the contract:

> _"Slots that reached max version CAN NOT be recycled"_ — ID uniqueness is preserved even at
> version exhaustion, and
>
> _"This struct is threadsafe if the following assumptions are met: \* never dereference a deleted
> resource \* never delete a resource twice"_ ([`src/impl_gpu_resources.hpp`][impl-gpures])

Destruction is **always deferred**. [`include/daxa/device.hpp`][device-hpp] states it directly:

> _"When calling destroy, or removing all references to an object, it is zombified not really
> destroyed. A zombie lives until the gpu catches up to the point of zombification."_

`daxa_dvc_destroy_buffer` decrements the refcount; at zero the resource enters a per-type zombie
list (`buffer_zombies`, `image_zombies`, …, [`src/impl_device.cpp`][impl-device]) tagged with the
current global submit-timeline value. `collect_garbage()` reads every queue's timeline semaphore
via `vkGetSemaphoreCounterValue`, computes the oldest still-pending submit, and truly destroys
every zombie older than it. `CommandRecorder` adds `destroy_buffer_deferred()` and friends, which
"destroy the \[resource] AFTER the gpu is finished executing the command list"
([`include/daxa/command_recorder.hpp`][cmdrec-hpp]). Validity is queryable at runtime
(`is_buffer_id_valid`), but dangling-ID detection inside shaders is the user's problem — an ID
baked into a buffer the GPU reads is beyond the host type system's reach.

### Synchronization safety

Daxa's answer is layered: **manual-but-assisted** in the core, **fully automated** in `TaskGraph`.

**Core layer.** `CommandRecorder` exposes `pipeline_barrier()` / `pipeline_image_barrier()` plus
split-barrier events (`signal_event`, `wait_events`, `reset_event`). Barriers are coalesced
automatically:

> _"Successive pipeline barrier calls are combined. As soon as a non-pipeline barrier command is
> recorded, the currently recorded barriers are flushed with a vkCmdPipelineBarrier2 call."_
> ([`include/daxa/command_recorder.hpp`][cmdrec-hpp])

Image layouts were largely **abolished** in release 3.3 (November 27, 2025): only `UNDEFINED`,
`GENERAL`, and `PRESENT_SRC` remain, on the modern-drivers-don't-care thesis — which removes the
single most common sync bug class (wrong-layout transitions) by fiat rather than by checking.

**Vulkan's external-synchronization rules are re-stated as per-type prose contracts**, not types:
`Device` is documented _"is internally synchronized \* can be passed between different threads \*
may be accessed by multiple threads at the same time"_ ([`include/daxa/device.hpp`][device-hpp])
— it takes internal mutexes (slot pool, zombie lists, command pools) so the `vk.xml` `externsync`
burden never reaches the user — while `CommandRecorder` is the opposite: _"must be externally
synchronized \* can be passed between different threads \* may only be accessed by one thread at a
time"_ ([`include/daxa/command_recorder.hpp`][cmdrec-hpp]). Nothing in the type system enforces
either; it is documentation plus validation.

**TaskGraph layer.** Each task's attachments declare resource, access type, and pipeline stages.
At `complete()` time the graph builds, per resource, an **access timeline** of compatible access
groups ([`src/utils/impl_task_graph.cpp`][impl-tg] — a new group is appended when
`are_accesses_compatible(...)` fails or the submit index changes), then derives:

- **Barriers** — one batched `vkCmdPipelineBarrier2` between adjacent incompatible groups; reads
  are implicitly concurrent ("there is no extra concurrent read access, as all reads are
  implicitly concurrent already", [TaskGraph wiki][tg-wiki]), and an explicit _concurrent_ mode
  lets disjoint writes share a group.
- **Reordering & batching** — `reorder_tasks` ("Task reordering can drastically improve
  performance", [`task_graph.hpp`][tg-hpp]) packs independent tasks into the same barrier-free
  batch; `optimize_transient_lifetimes` moves tasks to shrink transient lifetimes for aliasing.
- **Cross-queue sync** — per-task queue assignment (multi-queue landed in 3.1, June 22, 2025;
  matured in 3.5) tracks `queue_bits` per resource and inserts timeline-semaphore waits/signals
  between submits on different queues; queue-family ownership transfer is sidestepped entirely
  because release 3.6 made all images concurrent across queues.
- **Swapchain** — acquire/present semaphores are wired automatically when a `Swapchain` is given
  in `TaskGraphInfo` and the graph records a `present()`.
- **Driver-bug pragmatism** — `amd_rdna3_4_image_barrier_fix`: _"AMD gpus of the generations RDNA3
  and RDNA4 have hardware bugs that make image barriers still useful for cache flushes"_
  ([`task_graph.hpp`][tg-hpp]) — sync policy is a per-graph flag, not hard-coded.

The graph is also honest about its boundary: _"Only make attachments for resources that need sync.
Textures that are uploaded and synched once after upload for example should be ignored in the
graph"_ ([TaskGraph wiki][tg-wiki]) — bindless access to thousands of static textures flows
_around_ the graph, not through it, which is precisely what keeps graph compilation cheap.

### Type-system techniques

Daxa uses C++'s type system sparingly but deliberately:

- **Distinct generational-ID types** — `BufferId`, `ImageId`, `ImageViewId`, `SamplerId`,
  `TlasId`, `BlasId` are separate structs, so a buffer ID cannot be passed where an image ID is
  expected; `TypedImageViewId<VIEW_TYPE>` brands a view ID with its image-view dimensionality at
  compile time ([`gpu_resources.hpp`][gpures-hpp]).
- **Virtual task resources** — `TaskBuffer`/`TaskImage` and their `TaskBufferView`/`TaskImageView`
  projections separate graph-time identity from runtime identity, which is what makes
  record-once/execute-many possible.
- **Builder typestate, weak form** — `daxa::Task::Transfer("…").reads(...).writes(...).executes(...)`
  (3.1's builder API) sequences declaration fluently, but the stages are not type-enforced.
- **Macro-driven host/shader codegen** — the closest thing to typed structure chains in Daxa is
  the **TaskHead**, a single declaration expanded for both C++ and shaders:

  ```cpp
  // docs.daxa.dev/wiki/taskgraph/ — TaskHead
  DAXA_DECL_TASK_HEAD_BEGIN(MyTaskHead)
  DAXA_TH_BUFFER_PTR(READ, daxa_BufferPtr(daxa_u32), src_buffer)
  DAXA_TH_IMAGE_ID(WRITE, REGULAR_2D, dst_image)
  DAXA_DECL_TASK_HEAD_END
  ```

  On the C++ side this yields the attachment declarations (access + stage per resource); on the
  GLSL/Slang side, a struct of `daxa_BufferPtr`/`daxa_ImageViewId` fields that `TaskGraph` fills
  into the push constant automatically at execution. The access declaration and the shader's view
  of the resource are thus **one artifact** — a preprocessor-era cousin of what D could do with
  CTFE and a single introspectable struct.

What is **absent**: no linear/affine ownership (IDs are freely copyable), no lifetimes, no
phantom-typed sync scopes, no capability/extension typing (feature presence is runtime-checked at
device creation). Daxa's safety budget is spent on runtime validation and API-surface reduction,
not on type-level proofs — a coherent position for C++, and the inverse of
[vulkano][vulkano]'s.

### Overhead & escape hatches

The overhead story is **"amortize, then get out of the way"**:

- **Bindless eliminates per-draw descriptor cost.** One descriptor set, written once per resource
  creation with update-after-bind (the implementation notes _"Does not need external sync given we
  use update after bind"_, [`src/impl_device.cpp`][impl-device]); shaders index it by the ID's
  `index` bits or use raw buffer device addresses (`daxa_dvc_buffer_device_address`).
- **Runtime costs that do exist**: mutexed slot-pool allocation and zombie-list pushes on
  create/destroy (creation-rate paths, not per-draw), one relaxed atomic CAS per ID
  refcount operation, timeline-semaphore queries in `collect_garbage()`, and `TaskGraph`'s
  arena-allocated access timelines at `complete()` time.
- **Graph cost is front-loaded.** `complete()` does the analysis once; `execute()` replays batches
  and callbacks. The 3.1 release removed the backend's virtual calls and cut allocations by ~60%;
  the 3.5 rewrite (February 5, 2026) replaced the execution engine for roughly 2× faster
  record/execute ([releases][rel]). Per-graph arena pools (`task_memory_pool_size`,
  `staging_memory_pool_size`, [`task_graph.hpp`][tg-hpp]) keep execution allocation-free.
- **Escape hatches are first-class.** The C API hands back every raw handle —
  `daxa_dvc_get_vk_device`, `daxa_dvc_get_vk_physical_device`, `daxa_dvc_get_vk_queue`,
  `daxa_dvc_get_vk_buffer`, `daxa_dvc_get_vk_image`, `daxa_dvc_get_vk_image_view`
  ([`include/daxa/c/device.h`][c-device]) — so native Vulkan code, profilers, and interop layers
  can reach under the abstraction. `TaskGraph` itself is optional: the same `Device` and
  `CommandRecorder` work with fully manual `pipeline_barrier()` calls, and resources synced once
  (static textures) are deliberately kept out of the graph.

> [!WARNING]
> Some convenience queries are explicitly not free: `device_memory_report()` and
> `buffer_device_address_to_buffer()` carry the in-source warning _"THIS FUNCTION IS VERY SLOW,
> ONLY CALL IT FOR DEBUGGING PURPOSES!"_ ([`include/daxa/device.hpp`][device-hpp]).

### Error handling & validation integration

The C API returns `daxa_Result` codes from every fallible call. The C++ wrapper's policy is
striking — **abort, don't throw** ([`src/cpp_wrapper.cpp`][cpp-wrapper]):

```cpp
// src/cpp_wrapper.cpp — check_result (abridged)
if (!result_allowed)
{
#if DAXA_VALIDATION
    std::cout << std::format(
        "[[DAXA ASSERT FAILURE]]: error code: {}, {}.\n\n",
        daxa_result_to_string(result), message) << std::flush;
#endif
    std::abort();
}
```

Recoverable-error handling therefore lives only at the C layer (or in the few C++ calls that
allow extra success codes, e.g. swapchain out-of-date). The compensation is Daxa's own validation:
under `DAXA_VALIDATION`, both the core and `TaskGraph` check usage aggressively — attachment/view
overlap rules, "all task resources need valid IDs at execution time", present-without-swapchain,
etc. — with the README-advertised "detailed error messages explaining the issue and potential
solutions". Because layouts, descriptors, and (inside the graph) barriers are managed by Daxa,
whole categories of [Khronos sync-validation][sync-validation] findings cannot occur in
graph-driven code; the standard validation layers remain useful mainly under the escape hatches.
`enable_command_labels` additionally wraps every task in profiler markers (Nsight, RenderDoc), and
3.5 shipped a RenderDoc-style in-app `TaskGraph` debug UI
([`src/utils/impl_task_graph_ui.cpp`][impl-tg-ui], [releases][rel]).

---

## Strengths

- **The synchronization problem is actually solved, not re-typed**: declared accesses in, batched
  `vkCmdPipelineBarrier2` + cross-queue timeline semaphores + swapchain sync out, with reordering,
  transient aliasing, and async-compute support — and a debug UI to inspect the result.
- **Bindless-by-default removes the descriptor API entirely**, and generational IDs give cheap,
  probabilistically-sound use-after-free detection on the host side.
- **Deferred destruction is universal and automatic** — timeline-semaphore-gated zombie lists mean
  no per-frame fence babysitting.
- **Amortized cost model with receipts**: record-once/execute-many, virtual-call-free backend,
  arena allocators; the maintainers track and publish backend perf (≈2× in 3.5, ~40% hot-path in
  3.3).
- **Clean escape hatches** (raw `VkDevice`/`VkBuffer`/`VkImage` getters; graph optional) and a
  stable C ABI under the C++ sugar — notable for D, which could bind the C API directly.
- **TaskHead host/shader code sharing** keeps shader resource declarations and sync declarations
  as one artifact.

## Weaknesses

- **Not a Vulkan binding** — applications needing extensions, render passes, sparse resources, or
  exotic descriptor setups outside Daxa's curated surface must drop to raw handles and lose the
  guarantees.
- **Modern-GPU-only is a hard floor** (Turing/RDNA3/Arc); no mobile, no older desktop GPUs.
- **C++ error model is abort-on-error** — no recoverable error path at the C++ layer; libraries
  embedding Daxa inherit `std::abort` semantics unless they use the C API.
- **No compile-time sync or lifetime guarantees**: correctness inside the graph relies on the user
  declaring attachments honestly; a lying attachment produces a data hazard the types cannot
  catch (only `DAXA_VALIDATION` and the sync-validation layer might).
- **GPU-side dangling IDs are unchecked** — bindless moves the use-after-free frontier into shader
  memory, where host generational checks cannot follow.
- **Registry metadata is discarded wholesale**; thread-safety and validity contracts are
  hand-maintained prose, which can drift from the implementation.
- Breaking-change cadence has been high (3.6 was "extensive breaking changes" two years' worth),
  though the project now pledges stability into early 2027.

## Key design decisions and trade-offs

| Decision                                                      | Rationale                                                                            | Trade-off                                                                                  |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------ |
| Redesigned API instead of generated binding                   | Surface small enough to make safety guarantees enforceable; no descriptor/layout API | No `vk.xml` metadata survives; partial coverage; escape hatches forfeit guarantees         |
| Bindless-by-default via one update-after-bind mega set        | Zero per-draw descriptor cost; IDs/pointers "dramatically simplify code"             | Requires descriptor-indexing-class hardware; GPU-side stale IDs are undetectable           |
| Generational IDs (index + version) with atomic refcounts      | O(1) handle validation; copyable handles without ownership ceremony                  | Per-handle-op atomic CAS; validity is probabilistic (version exhaustion slots are retired) |
| Universal deferred destruction gated on queue timeline values | "A zombie lives until the gpu catches up" — no manual fence tracking                 | Memory lingers until `collect_garbage()`; explicit GC call is part of the frame loop       |
| Sync automated by an optional precompiled `TaskGraph`         | Barriers/semaphores derived from declared uses; record once, execute many            | `complete()`-time cost; correctness depends on honest attachment declarations              |
| Image layouts reduced to `UNDEFINED`/`GENERAL`/`PRESENT_SRC`  | Modern drivers make layout micro-management moot; kills the top sync-bug class       | Leaves potential layout-specific compression wins on the table for some hardware           |
| `Device` internally synchronized; `CommandRecorder` external  | Users never re-derive `externsync` rules for the device; recorders stay lock-free    | Internal mutexes on creation paths; recorder contract is prose, not types                  |
| C core + thin C++ wrapper that `std::abort()`s on error       | Stable ABI for other languages; validation messages over exception plumbing          | No recoverable C++ errors; embedding libraries must use the C layer for robustness         |

---

## Sources

- [Ipotrick/Daxa — GitHub repository][repo] · [README][readme] · [Releases][rel]
- [docs.daxa.dev — official docs][docs] · [TaskGraph wiki][tg-wiki] · [Bindless wiki][bindless-wiki]
- [`include/daxa/gpu_resources.hpp` — generational ID types][gpures-hpp]
- [`include/daxa/device.hpp` — zombification, THREADSAFETY contracts][device-hpp]
- [`include/daxa/command_recorder.hpp` — barrier coalescing, deferred destroys, externsync contract][cmdrec-hpp]
- [`include/daxa/utils/task_graph.hpp` — `TaskGraphInfo` flags (reordering, aliasing, AMD fix)][tg-hpp]
- [`include/daxa/c/device.h` — raw `VkDevice`/`VkBuffer`/… escape hatches][c-device]
- [`src/impl_gpu_resources.hpp` — slot pool, version/refcount packing, mega descriptor set][impl-gpures]
- [`src/impl_device.cpp` — zombie lists, `collect_garbage`, update-after-bind][impl-device]
- [`src/utils/impl_task_graph.cpp` — access timelines, batching, multi-queue sync][impl-tg]
- [`src/cpp_wrapper.cpp` — `check_result` abort-on-error policy][cpp-wrapper]
- Related: [vuk (C++)][vuk] · [Tephra (C++)][tephra] · [vulkano (Rust)][vulkano] · [wgpu (Rust)][wgpu] · [Vulkan-Hpp (C++)][vulkan-hpp] · [Sync validation][sync-validation] · [Concepts][concepts] · [Comparison][comparison] · [Survey index][index]

<!-- References -->

[repo]: https://github.com/Ipotrick/Daxa
[readme]: https://github.com/Ipotrick/Daxa/blob/master/README.md
[rel]: https://github.com/Ipotrick/Daxa/releases
[docs]: https://docs.daxa.dev/
[tg-wiki]: https://docs.daxa.dev/wiki/taskgraph/
[bindless-wiki]: https://docs.daxa.dev/wiki/bindless/
[gpures-hpp]: https://github.com/Ipotrick/Daxa/blob/master/include/daxa/gpu_resources.hpp
[device-hpp]: https://github.com/Ipotrick/Daxa/blob/master/include/daxa/device.hpp
[cmdrec-hpp]: https://github.com/Ipotrick/Daxa/blob/master/include/daxa/command_recorder.hpp
[tg-hpp]: https://github.com/Ipotrick/Daxa/blob/master/include/daxa/utils/task_graph.hpp
[c-device]: https://github.com/Ipotrick/Daxa/blob/master/include/daxa/c/device.h
[impl-gpures]: https://github.com/Ipotrick/Daxa/blob/master/src/impl_gpu_resources.hpp
[impl-device]: https://github.com/Ipotrick/Daxa/blob/master/src/impl_device.cpp
[impl-tg]: https://github.com/Ipotrick/Daxa/blob/master/src/utils/impl_task_graph.cpp
[impl-tg-ui]: https://github.com/Ipotrick/Daxa/blob/master/src/utils/impl_task_graph_ui.cpp
[cpp-wrapper]: https://github.com/Ipotrick/Daxa/blob/master/src/cpp_wrapper.cpp
[vuk]: ./cpp-vuk.md
[tephra]: ./cpp-tephra.md
[vulkano]: ./rust-vulkano.md
[wgpu]: ./rust-wgpu.md
[vulkan-hpp]: ./cpp-vulkan-hpp.md
[sync-validation]: ./sync-validation.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
