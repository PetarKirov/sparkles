# C++: `Daxa`

## Mechanism: Typed IDs + Compiled Task Graph + Deferred GC

`Daxa` is a modern-GPU-focused Vulkan abstraction with a strong bindless model and a high-level TaskGraph framework.

Compared to wrappers that only re-skin Vulkan symbols, Daxa adds a real execution model:

1. Typed resource IDs and strongly typed flag/access structures.
2. TaskGraph compilation that builds access timelines and auto-inserts synchronization.
3. Deferred destruction (`zombify` + `collect_garbage`) tied to submit progress.
4. Validation-heavy debug mode with detailed diagnostics.

## 1) Typed API Design

### Versioned Resource IDs

`include/daxa/gpu_resources.hpp` defines all core resource handles (`BufferId`, `ImageId`, `ImageViewId`, `SamplerId`, `BlasId`, `TlasId`) as a 64-bit split of `index` and `version` (`20 + 44` bits).

The same file enforces layout compatibility with `GPUResourceId` via `static_assert`, which enables cheap casting while preserving type distinctions per resource kind.

This design gives Daxa a practical runtime type-and-validity boundary: stale IDs fail version checks once a slot is recycled.

### Typed Bindless Surface

Daxa extends raw IDs with typed texture wrappers (`TextureId<T, VIEW_TYPE>`, `TextureIndex<T, VIEW_TYPE>`), so shader-visible texture dimensionality and access form are carried in C++ types.

The bindless model is explicit in the README: resources are accessed by IDs/pointers rather than per-draw descriptor binding plumbing.

### Strongly Typed Flags and Access

`include/daxa/types.hpp` provides `Flags<Properties>` and typed flag families (`ImageUsageFlags`, `PipelineStageFlags`, `AccessTypeFlags`, etc.), so unrelated flag domains are not implicitly mixed.

The same file defines `Access` (`stages` + `type`) and a large `AccessConsts` catalog, which becomes the canonical low-level dependency language used by TaskGraph internals.

### Task Attachment Typing

`include/daxa/utils/task_graph_types.hpp` defines:

1. `TaskAccessType` with encoded read/write/concurrent/sampled bits.
2. `TaskAccessConsts` stage-scoped access constants (`CS::READ`, `FS::WRITE`, etc.).
3. Task-head declaration macros (`DAXA_DECL_COMPUTE_TASK_HEAD_BEGIN`, `DAXA_TH_IMAGE_ID`, `DAXA_TH_BUFFER_PTR`, ...).

The macro-based task head system generates a typed declaration layer plus an `AttachmentShaderBlob` layout that maps host-side attachments to shader-visible payload.

## 2) Task Graph Synchronization Model

### Public Contract

`TaskGraphInfo` in `include/daxa/utils/task_graph.hpp` exposes synchronization-related controls:

1. `reorder_tasks`.
2. `optimize_transient_lifetimes`.
3. `alias_transients`.
4. `amd_rdna3_4_image_barrier_fix`.

This already hints that synchronization is planned, optimized, and then lowered to barriers.

### Access Timelines and Access Groups

In `src/utils/impl_task_graph.cpp`, compilation builds per-resource access timelines by grouping compatible accesses into `AccessGroup`s.

Compatibility is governed by `are_accesses_compatible(...)` from `task_graph_types.hpp`, and timeline construction tracks stage masks, access kinds, and queue bits.

### Barrier Insertion Strategy

In `src/utils/impl_task_graph.cpp` and `src/utils/impl_task_graph.hpp`, Daxa lowers transitions between access groups into `TaskBarrier`s attached to per-queue `TasksBatch` objects.

Notable behavior:

1. Initial transient image transitions from `UNDEFINED` are inserted before first use.
2. Inter-queue transitions rely on submit/semaphore ordering; same-submit same-queue transitions get explicit barriers.
3. The RDNA3/4 option can force image barriers for image sync paths.

So, synchronization is mostly declarative for users, but explicitly materialized during graph compilation.

### Scheduling and Optimization

The compiler can reorder tasks and compact them forward to shrink transient lifetimes, then optionally memory-alias non-overlapping transient resources (`alias_transients`).

This is a key design point: synchronization and memory placement are co-optimized in one pass, not handled as separate systems.

## 3) Resource Lifetime Management

### CPU Handle Lifetime

`ManagedPtr` in `include/daxa/types.hpp` provides intrusive ref-counted handle semantics for top-level objects (`Device`, task externals, etc.), with copy/move behavior and centralized `inc_refcnt` / `dec_refcnt` hooks.

### GPU Resource Slot Lifetime

`GpuResourcePool` in `src/impl_gpu_resources.hpp` manages GPU object slots with:

1. Paged storage.
2. Versioned IDs.
3. Atomic packed version+refcount.

`try_inc_refcnt`, `try_dec_refcnt`, and `is_id_valid` enforce runtime validity and detect stale/double-free style misuse (especially in debug validation mode).

### Deferred Destruction via Zombies

`src/impl_device.hpp` and `src/impl_device.cpp` implement the deferred destruction model:

1. `destroy_*` paths zombify resources (`zombify_buffer`, `zombify_image`, etc.).
2. Zombies store the current global submit timeline value.
3. `collect_garbage()` compares zombie timeline stamps with `oldest_pending_submit_index()` across queues.
4. Only resources older than all pending GPU work are physically cleaned up.

This is the central protection against CPU-side premature destruction of in-flight GPU resources.

## 4) Validation Strategy

### Compile-Time Build Mode Switch

`include/daxa/core.hpp` sets `DAXA_VALIDATION` by build mode. In validation mode, `DAXA_DBG_ASSERT_TRUE_M` aborts with explicit messages; in release mode it compiles out.

`DAXA_GPU_ID_VALIDATION` is enabled in validation builds, activating stricter runtime ID checks.

### TaskGraph Validation Messages

`src/utils/impl_task_graph.cpp` has explicit error-message helpers (for unassigned views, missing stages, invalid external registrations, and other graph contract violations), then asserts those invariants throughout compile/execute.

This is unusually actionable compared to raw Vulkan layer output alone.

### Null Descriptor Safety Net

`src/impl_device.hpp` documents Daxa's null-resource strategy: dead descriptor slots are overwritten with known null handles (debug pink sentinel behavior), reducing catastrophic device-lost outcomes during use-after-free scenarios.

## Strengths

1. Strong typed API surface without going full template-typestate everywhere.
2. Practical automatic synchronization for real render/compute graphs.
3. Lifetime model explicitly designed for overlapping CPU/GPU timelines.
4. High-quality validation diagnostics integrated into the abstraction layer.

## Limitations

1. Core safety (especially synchronization) is mostly runtime-checked, not fully compile-time proven.
2. Benefits are maximal when work is expressed through TaskGraph; manual paths lose many protections.
3. Modern-hardware-first scope is deliberate and may not match portability-first projects.

## D Takeaways

1. A D Vulkan layer should likely separate typed resource identity from synchronization policy, then provide a graph compiler as the default policy.
2. Versioned typed IDs plus compile-time traits/UDAs could give stronger static ergonomics than C++ macros while keeping Daxa-like runtime guarantees.
3. Deferred destruction tied to queue progress should be considered non-optional in any high-level API.
4. Validation UX matters: precise, task-level diagnostics are a major differentiator versus thin wrappers.

## Sources

1. `README.md` (project positioning, bindless/task graph claims): <https://github.com/Ipotrick/Daxa/blob/master/README.md>
2. `include/daxa/gpu_resources.hpp` (typed/versioned IDs, texture ID types): <https://github.com/Ipotrick/Daxa/blob/master/include/daxa/gpu_resources.hpp>
3. `include/daxa/types.hpp` (`ManagedPtr`, `Flags`, `Access`): <https://github.com/Ipotrick/Daxa/blob/master/include/daxa/types.hpp>
4. `include/daxa/utils/task_graph.hpp` (`TaskGraphInfo`, scheduling knobs): <https://github.com/Ipotrick/Daxa/blob/master/include/daxa/utils/task_graph.hpp>
5. `include/daxa/utils/task_graph_types.hpp` (task access model, task heads, task interface): <https://github.com/Ipotrick/Daxa/blob/master/include/daxa/utils/task_graph_types.hpp>
6. `src/utils/impl_task_graph.hpp` + `src/utils/impl_task_graph.cpp` (access timelines, barrier lowering, validation): <https://github.com/Ipotrick/Daxa/blob/master/src/utils/impl_task_graph.hpp>, <https://github.com/Ipotrick/Daxa/blob/master/src/utils/impl_task_graph.cpp>
7. `src/impl_gpu_resources.hpp` (resource pool, version/refcount validity): <https://github.com/Ipotrick/Daxa/blob/master/src/impl_gpu_resources.hpp>
8. `include/daxa/device.hpp` + `src/impl_device.hpp` + `src/impl_device.cpp` (thread-safety notes, zombie lifetime model, garbage collection): <https://github.com/Ipotrick/Daxa/blob/master/include/daxa/device.hpp>, <https://github.com/Ipotrick/Daxa/blob/master/src/impl_device.hpp>, <https://github.com/Ipotrick/Daxa/blob/master/src/impl_device.cpp>
