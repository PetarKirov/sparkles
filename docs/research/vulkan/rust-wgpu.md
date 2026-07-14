# wgpu (Rust)

A safe, cross-platform GPU API for Rust that implements **WebGPU semantics over Vulkan** (and Metal/D3D12/OpenGL ES): instead of typing Vulkan's rules, it makes them disappear behind a runtime layer that auto-derives every barrier — the most-studied production auto-barrier implementation, shipped in Firefox.

| Field          | Value                                                                                              |
| -------------- | -------------------------------------------------------------------------------------------------- |
| Language       | Rust (MSRV policy: stable minus a few releases; v28 required 1.92)                                 |
| License        | MIT OR Apache-2.0 (dual)                                                                           |
| Repository     | [gfx-rs/wgpu][repo]                                                                                |
| Documentation  | [wgpu.rs][site] · [docs.rs/wgpu][docs] · [docs.rs/wgpu-hal][hal-docs]                              |
| Category       | Render-graph / auto-sync layer (runtime usage-tracker, not a graph the user declares)              |
| First release  | `0.1` (2019, as `wgpu-rs` over `wgpu-core`); lineage from `gfx-rs`/`gfx-hal`                       |
| Latest release | `v29.0.3` (May 2026); major releases roughly quarterly (v25 → v29 between April 2025 and May 2026) |

> [!NOTE]
> wgpu is **not a Vulkan binding** — it sits two layers above one. The Vulkan
> backend is written against [ash][ash] (see the [`ash` deep-dive][rust-ash]).
> It is in this survey as the reference point for the _opposite_ design pole
> from typed bindings: full runtime tracking with zero type-level Vulkan
> exposure, and a measurable CPU bill for it.

---

## Overview

### What it solves

Raw Vulkan demands that the programmer place every `vkCmdPipelineBarrier`, manage every `VkFence`/`VkSemaphore`, and respect every externally-synchronized handle — and rewards mistakes with undefined behavior. wgpu removes the entire class: the user records passes against a [WebGPU][webgpu-spec]-shaped API (`RenderPass`, `ComputePass`, `Queue::submit`), and the implementation _derives_ the required Vulkan barriers, layout transitions, and queue synchronization at submit time by tracking the state of every buffer and texture subresource. Invalid usage is caught by wgpu's own validation (a reimplementation of the WebGPU validation rules in [`wgpu-core`][core-src]) and surfaced as Rust errors or panics — never as UB.

The stack is three crates, each a distinct point on the safety/overhead curve:

| Crate       | Role                                                                 | Safety contract                               |
| ----------- | -------------------------------------------------------------------- | --------------------------------------------- |
| `wgpu`      | Idiomatic Rust-flavoured WebGPU API; also targets the browser via JS | Safe; all types `Send + Sync`                 |
| `wgpu-core` | Validation, usage tracking, barrier generation, lifetime management  | Safe interface over unsafe internals          |
| `wgpu-hal`  | Thin unsafe portability layer; Vulkan backend over [ash][ash]        | `unsafe` traits, "minimal validation, if any" |

### Design philosophy

The split is stated bluntly in the [`wgpu-hal` crate docs][hal-docs]:

> _"Our traits' contracts are **unsafe**: implementations perform minimal validation, if any, and incorrect use will often cause undefined behavior. … Validation is the calling code's responsibility, not `wgpu-hal`'s."_

So all safety lives in `wgpu-core`, whose tracking layer describes its own job ([`wgpu-core/src/track/mod.rs`][track], verbatim):

> _"These structures are responsible for keeping track of resource state, generating barriers where needednd [sic] making sure resources are kept alive until the trackers die."_

The philosophy is therefore the inverse of [vulkano][rust-vulkano]'s type-driven approach and of [Daxa][cpp-daxa]/[vuk][cpp-vuk]'s user-declared task graphs: **no Vulkan concept escapes into the user-facing type system at all**. Synchronization, layouts, queue ownership, and external synchronization are implementation details, paid for at runtime and amortized by careful data-structure engineering ("metadata SOA style, one vector per type of metadata", per the same module docs).

---

## How it works

What the user writes is pure WebGPU shape — record a pass, submit; no barrier, layout,
semaphore, or fence appears anywhere (the [`docs.rs` examples][docs] follow this pattern):

```rust
// Idiomatic wgpu frame: everything sync-related is derived behind this API.
let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor::default());
{
    let mut rpass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        label: None,
        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
            view: &frame_view, // swapchain acquire/present semaphores: internal
            depth_slice: None,
            resolve_target: None,
            ops: wgpu::Operations {
                load: wgpu::LoadOp::Clear(wgpu::Color::BLACK), // layout transition: derived
                store: wgpu::StoreOp::Store,
            },
        })],
        ..Default::default()
    });
    rpass.set_pipeline(&pipeline);
    rpass.draw(0..3, 0..1); // usage tracking merges per-draw resource states here
}
queue.submit([encoder.finish()]); // barriers diffed & emitted; fence = timeline semaphore
```

Everything the rest of this page describes — trackers, snatch lock, deferred
destruction — happens behind those few calls.

### Binding generation & API coverage

wgpu is **not generated from `vk.xml`** — this dimension applies only indirectly, and the indirection is itself the finding. The layering is:

- **Vulkan entry points** come from [ash][ash], which _is_ generated from `vk.xml` (see [rust-ash][rust-ash]); `wgpu-hal/src/vulkan/` is a hand-written backend (~15 kLoC) that calls ash and is where all `vk.xml` knowledge (extension gating, `pNext` chains, workarounds) is encoded manually.
- **The public API surface** mirrors the [WebGPU specification][webgpu-spec] and its `webgpu.idl`; the types in `wgpu-types` are hand-maintained Rust structs/bitflags kept in sync with the spec by review, not codegen. Shaders are WGSL, translated to SPIR-V by [naga][naga] (in-tree).

Consequently **no registry safety metadata survives** to the user: `externsync` annotations, handle parentage, and valid-usage rules from `vk.xml` are all replaced wholesale by WebGPU's own (stricter, smaller) validation rules implemented by hand in `wgpu-core`. Coverage is deliberately the WebGPU subset plus native-only extensions (`wgpu::Features`, e.g. push constants, ray-tracing acceleration structures, 64-bit atomics) — far below raw Vulkan (no multi-queue, bindless only partially, no user-visible render-pass control).

### Handle lifetime & ownership model

All user-facing handles (`Buffer`, `Texture`, `BindGroup`, …) are opaque, clonable, reference-counted objects. The internals went through a famous redesign — **"arcanization"** ([blog, November 24, 2023][arcanization]; [PR #3626][pr3626]) — that moved every `wgpu-core` resource behind `Arc<T>`:

- **Before:** resources lived in contiguous arrays inside a global "Hub"; _every_ access took a `RwLock` on the storage, and dependencies were tracked by error-prone manual refcounts. Lock contention made multithreaded recording barely faster than single-threaded.
- **After (v0.19, January 2024):** the Hub stores `Arc`s; locks are held _"in a lot of cases only while cloning the arc"_ ([arcanization post][arcanization]). Bevy's testing showed parallel shadow-pass encoding give a _"45% frame time reduction on a test scene … compared to their single threaded configuration"_ ([arcanization post][arcanization]).

Two further mechanisms complete the model:

- **The snatch lock** ([`wgpu-core/src/snatch.rs`][snatch]) reconciles `Arc`-based liveness with WebGPU's explicit `destroy()`: a `Snatchable<T>` is _"a value that is mostly immutable but can be 'snatched' if we need to destroy it early"_, guarded by one device-wide `SnatchLock` taken (read) on hot paths. It has caused real deadlocks ([#6378][i6378]) and contention ([#5525][d5525]).
- **Deferred destruction:** dropping a handle never destroys GPU memory immediately; the device tracks per-submission "active" resource lists and frees them when the fence (see [below](#synchronization-safety)) passes the submission index — the classic frames-in-flight problem solved centrally, invisible to the user.

Because everything is internally locked, **every wgpu type is `Send + Sync`** — Vulkan's externally-synchronized handles (`vk.xml` `externsync`, e.g. `VkQueue`, command pools) are wrapped in Mutexes inside the backend, distinguished nowhere in user-facing types or docs. After repeated deadlock regressions, lock _ordering_ is enforced by a hand-maintained static lock-rank graph ([`wgpu-core/src/lock/rank.rs`][rank], reinstated via [#5204][i5204]) checked at runtime in debug builds.

### Synchronization safety

This is wgpu's center of gravity: a fully **automated, runtime-tracked** model with no user-visible barrier, semaphore, layout, or queue-ownership concept.

**The usage tracker** ([`wgpu-core/src/track/`][track]) maintains, per buffer and per texture _subresource_ (mip level × array layer, via `TextureSelector`), the current internal usage state (`BufferUses`/`TextureUses` — a superset of WebGPU usages that includes layout-relevant states). Three tracker flavours compose:

1. **Bind-group trackers** — precomputed lists of (resource, usage) for each bind group, so per-draw merging is a replay, not a re-derivation.
2. **Usage-scope trackers** — implement WebGPU's _usage scope_ rule: within one scope (one render pass, or one dispatch), usages of a resource are **merged**, and a merge that combines a writable usage with any other usage is a **validation error** (WebGPU's exclusive-writer rule). This is where races inside a pass are rejected rather than synchronized.
3. **Full (device/command-buffer) trackers** — hold before/after states; the **barrier** operation diffs the command buffer's first-use states against the device tracker's current states and emits the minimal transitions, which the Vulkan backend lowers to `vkCmdPipelineBarrier` with image-layout transitions (`wgpu-hal`'s `CommandEncoder::transition_buffers`/`transition_textures` — the hal docs require the caller to _"record explicit barriers between different usages of a resource"_).

The module docs are explicit that this hot path is engineered, not naive: state lives in flat vectors indexed by re-used ID indices ("they will always be as low as reasonably possible"), presence is a bit vector permitting _"bailing out of whole blocks of 32-64 resources with a single usize comparison"_, and the pervasive unsafe indexing is mirrored by debug asserts ([`track/mod.rs`][track]).

**Fences and semaphores:** the user sees neither. `wgpu-hal`'s `Fence` is a monotonically increasing timeline; the Vulkan backend ([`wgpu-hal/src/vulkan/mod.rs`][hal-vk]) implements it as a `VkSemaphoreTypeKHR` **timeline semaphore** when available — _"timeline semaphores work exactly the way `wgpu_hal::Api::Fence` is specified to work"_ — and otherwise as a pool of binary `VkFence`s tracking the highest signalled value. Swapchain acquire/present semaphores and inter-submission ordering (`RelaySemaphores`, including a two-semaphore alternation working around a Mesa hang) are likewise internal.

**Queue-family ownership transfer does not exist** in wgpu: the WebGPU model has a single queue, the Vulkan backend opens one queue, and all resources stay in one family. The absence is load-bearing — it removes an entire axis of Vulkan synchronization (and a long-standing feature request: multi-queue is among the missing features users cite for staying on raw Vulkan).

> [!IMPORTANT]
> The contrast with [Daxa][cpp-daxa]/[vuk][cpp-vuk] matters for a future
> `sparkles:vulkan`: wgpu derives barriers **while recording, eagerly,
> per command**, with no whole-frame view — so it cannot reorder passes or
> batch barriers globally the way a declared task graph can, and it pays the
> tracking cost on every encoder operation whether or not the frame's
> structure changed since last frame.

#### Comparison: Dawn, the other production tracker

[Dawn][dawn] (Google's WebGPU implementation, shipped in Chrome; C++, calling Vulkan directly) solves the identical problem and is the natural cross-check on wgpu's design. Dawn's frontend records commands into an intermediate linear-allocated command stream ([`src/dawn/native/CommandAllocator.h`][dawn-cmdalloc]: _"To avoid doing an allocation per command or to avoid copying commands when reallocing, we use a linear allocator in a growing set of large memory blocks"_) while a [`SyncScopeUsageTracker`][dawn-usage-tracker] accumulates each pass's merged resource usages — per the header, it _"returns the per-pass usage for use by backends for APIs with explicit barriers"_. Only at submit does the Vulkan backend ([`src/dawn/native/vulkan/CommandBufferVk.cpp`][dawn-cmdvk]) replay the stream and call `PrepareResourcesForSyncScope` — once per render pass, and once per dispatch in compute passes (WebGPU's per-dispatch usage-scope rule, same as wgpu) — diffing against per-resource last-sync state (`SubresourceStorage<TextureSyncInfo>` `mSubresourceLastSyncInfos` in [`TextureVk.cpp`][dawn-texvk], stored _on each resource_ rather than in wgpu's central index-vector device tracker). Where the designs agree: usage-scope merging with exclusive-writer validation, per-subresource granularity, barriers batched at sync-scope boundaries, read-only-reuse skipping (`CanReuseWithoutBarrier`). Where they diverge: Dawn additionally _splits_ merged barriers by destination stage —

> _"Separate barriers with vertex stages in destination stages from all other barriers. This avoids creating unnecessary fragment->vertex dependencies when merging barriers."_ ([`CommandBufferVk.cpp`][dawn-cmdvk])

— a pessimization-avoidance pass wgpu's eager per-encoder emission has no equivalent of; and Dawn's barrier behavior is tuned per device via [**toggles**][dawn-toggles] (e.g. `vulkan_split_command_buffer_on_compute_pass_after_render_pass`, default-on for Qualcomm) rather than wgpu's compile-time/feature gating. Notably, Dawn has published **no overhead numbers** comparable to wgpu's [#2080][d2080] — the wgpu discussion remains the only quantified cost estimate for this architecture, which is itself why this page leans on it.

### Type-system techniques

Almost deliberately **none** — absence is the finding here. wgpu's safety is dynamic:

- No phantom-typed handles, no typestate builders, no lifetime-encoded scoping. The one notable lifetime — `RenderPass<'encoder>` borrowing its `CommandEncoder` — was _removed_ (made `'static` via internal `Arc`s, wgpu v22) because it blocked users, the opposite direction from [vulkano][rust-vulkano]/ash-style typed designs.
- The light typing that exists: `wgpu-core`'s `id::Id<T>` carries a `PhantomData` marker so buffer/texture IDs don't cross-assign (an internal, not user-facing, mechanism); `wgpu-types` bitflags (`BufferUsages`, `TextureUsages`) are validated at runtime, not by type; backend selection in `wgpu-hal` is static dispatch over an `Api` trait (generics, not trait objects) so the Vulkan path monomorphizes.
- `pNext` chains never reach the user; the hal Vulkan backend builds them by hand, and the documented interop hook `wgpu_hal::vulkan::Adapter::open_with_callback` exists precisely so embedders can _"modify the pnext chains and extension lists before creating a vulkan device"_ ([#965 lineage][i965]).
- Capability typing is runtime too: `Features` and `Limits` are checked when a device is requested and re-checked per call during validation.

The Rust type system is used for **memory safety of the implementation** (and API misuse like use-after-`drop` simply being impossible with `Arc` handles), not for encoding Vulkan's rules.

### Overhead & escape hatches

wgpu is the best-documented data point for what automatic barriers + validation cost on the CPU:

- **Headline estimate:** in the long-running performance discussion [#2080][d2080], maintainer kvark put the expected overhead over raw hal at **5–10 % in a real app**, with a measured **worst case of ~2× CPU time** comparing `halmark` (raw hal) to `bunnymark` (full wgpu) — the gap being _"validation, state tracking, and lifetime tracking"_. (kvark's own post-wgpu answer to this cost is [blade][rust-blade], which deletes the tracker entirely — the zero-tracking counterpoint whose benchmark numbers are quoted against these.)
- **Multithreading:** pre-arcanization, parallel encoding was effectively serialized by Hub locks; post-arcanization it scales (the 45 % Bevy number [above](#handle-lifetime--ownership-model)), but contention remains real: [#5525][d5525] (May 2024) profiles a production app dropping from 60 FPS to ~10 FPS during concurrent asset upload, with Tracy traces pointing at the registry `data.write()` in `assign()`, `device.trackers.lock()`, the snatchable read lock, and `texture.views.lock()`. Maintainers' replies acknowledge arcanization replaced _"a global lock"_ with _"finer-grained locks"_ rather than eliminating locking; follow-up work ([#5121][i5121]) targets removing the registries entirely. [#2710][i2710] ("Remove Locking From Hot Paths") tracks the broader goal.
- **Per-command cost** that typed/manual bindings don't pay: usage-state merge per resource per draw/dispatch, validation of every call against WebGPU rules, and (for `DrawIndirect` with bounds checking) injected GPU-side validation work.
- **Escape hatches are real and layered.** `as_hal` returns a guard dereferencing to the `wgpu-hal` type, from which raw ash/Vulkan handles (`vk::Buffer`, `vk::Device`, queue) are reachable; `from_hal`/`texture_from_raw`/`Device::create_buffer_from_hal` import externally created Vulkan objects (with an explicit `drop_guard` ownership story, [#6142][i6142]); `CommandEncoder::transition_resources` lets interop code force states so the tracker's assumptions stay true; `vulkan::Queue::add_wait_semaphore` lets CUDA/GL producers be awaited without CPU blocking. One can also skip `wgpu`/`wgpu-core` entirely and program `wgpu-hal` directly — Vulkan-shaped, portable, unsafe, and validation-free, _"1:1 with Vulkan"_ enough that its overhead over raw calls is negligible.

### Error handling & validation integration

wgpu **replaces**, rather than integrates, Vulkan's validation layers: `wgpu-core` implements the WebGPU validation algorithms itself, so a correct wgpu program should never trip `VK_LAYER_KHRONOS_validation` (wgpu CI still runs the layers to catch wgpu's own backend bugs; cf. [the sync-validation survey][sync-validation]).

- Following WebGPU's [error model][webgpu-errors], errors are **deferred and contagious**: object creation always returns a handle; if creation failed the handle is internally invalid and later uses propagate the error. On native Rust, an unhandled validation error **panics by default** via the uncaptured-error handler; `Device::on_uncaptured_error` and `push_error_scope`/`pop_error_scope` give the WebGPU-style programmatic capture path. Device loss is a separate callback, mirroring `VK_ERROR_DEVICE_LOST`.
- Usage-scope conflicts (write/write or read/write on one subresource within a pass) surface as descriptive validation errors at encode time — the safety property that typed systems try to prove statically, here checked dynamically with full runtime information (hence zero false positives, at runtime cost).
- `wgpu-hal` returns errors only for _"cases the user can't anticipate, like running out of memory or losing the device"_ ([hal docs][hal-docs]) — everything anticipatable is `wgpu-core`'s job, keeping the hal hot path branch-light.

---

## Strengths

- **The strongest safety guarantee in the survey**: no unsafe code, no UB, no sync hazards expressible in the safe API — races inside a pass are _validation errors_, races across passes are _auto-barriered_.
- **Production-proven at scale**: ships in Firefox as its WebGPU implementation and underpins Bevy; the auto-barrier engine has years of fuzzing/CTS coverage no hobby layer matches.
- **Cache-conscious tracker engineering** (SOA metadata, bit-vector presence, index-reusing IDs) shows auto-sync need not mean hash maps everywhere — directly transferable design material.
- **Portability for free** (Vulkan/Metal/D3D12/GLES/WebGPU-in-browser) with one shader language via [naga][naga].
- **Graduated escape hatches** — `as_hal`/`from_hal`/raw `wgpu-hal` — let hot paths or interop drop to raw Vulkan without abandoning the stack.
- **Timeline-semaphore-first fence model** with transparent fallback is a clean pattern for D.

## Weaknesses

- **Permanent CPU tax**: ~5–10 % typical, up to ~2× worst case versus raw hal ([#2080][d2080]); per-draw tracking work scales with scene complexity and cannot be opted out of short of leaving `wgpu-core`.
- **Lock architecture is still a liability**: post-arcanization contention on registries, device trackers, and the snatch lock measurably degrades concurrent upload + render workloads ([#5525][d5525]); the snatch lock can deadlock ([#6378][i6378]); lock order needs a hand-maintained rank table ([#5204][i5204]).
- **Eager per-command barrier derivation** can't reorder or globally optimize like a declared task graph ([Daxa][cpp-daxa], [vuk][cpp-vuk]) and re-pays the cost every frame even for static scenes.
- **API ceiling is WebGPU**: single queue (no async compute/transfer queues, no queue-ownership control), no user render-graph hooks, extension access only insofar as wgpu chose to expose a `Feature`.
- **Nothing for the type-system column**: a D library hoping to encode sync rules statically gets anti-lessons (the removed `RenderPass` lifetime) rather than techniques.
- **Rapid major-version cadence** (quarterly breaking releases) is a churn cost for dependents.

## Key design decisions and trade-offs

| Decision                                                            | Rationale                                                                                      | Trade-off                                                                                          |
| ------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| WebGPU semantics instead of Vulkan semantics                        | A spec'd, fuzzable, portable safety model; browser + native from one codebase                  | Single queue, reduced feature surface, no user control over passes/barriers                        |
| Runtime usage tracking, not types or user graphs                    | Zero user burden; zero false positives; works for fully dynamic workloads                      | 5–10 % (worst ~2×) CPU overhead; eager per-command derivation; no whole-frame barrier optimization |
| Safety concentrated in `wgpu-core`; `wgpu-hal` unsafe + unvalidated | Pay for validation exactly once, at one layer; hal stays portable and near-zero-cost           | Two APIs to maintain; hal misuse is instant UB; safe API can't expose what core didn't model       |
| Arcanization: `Arc`-per-resource over Hub arrays                    | Cut lock hold times; enable real multithreaded encoding (45 % frame-time win)                  | Per-resource refcount traffic; many fine-grained locks needing a static rank graph                 |
| Snatch lock for explicit `destroy()` under `Arc` liveness           | WebGPU requires early destroy; one device-wide RwLock keeps reads cheap                        | A global read-lock on hot paths; documented contention and a recursive-lock deadlock class         |
| Hand-written backends over ash, no `vk.xml` codegen of the API      | The API is `webgpu.idl`-shaped; backend code is where workarounds and `pNext` wiring must live | `externsync`/valid-usage metadata from the registry is discarded; backend upkeep is manual         |
| hal `Fence` = timeline semaphore (pool-of-`VkFence` fallback)       | Timeline semantics match the abstract model 1:1; one concept for all backends                  | Fallback path complexity; binary-semaphore relay dance (incl. Mesa workaround) stays internal      |
| Errors deferred + contagious, panic-by-default on native            | Matches the WebGPU spec; keeps creation calls infallible-shaped                                | Failure surfaces later than the offending call; panic default surprises library users              |

---

## Sources

- [gfx-rs/wgpu — GitHub repository][repo] · [wgpu.rs][site] · [docs.rs/wgpu][docs]
- [`wgpu-core/src/track/mod.rs` — tracker design doc (SOA, bit vectors, insert/merge/barrier/update)][track]
- [`wgpu-hal` crate docs — unsafe contract, explicit barriers, error scope][hal-docs] · [`wgpu-hal/README.md`][hal-readme]
- [`wgpu-hal/src/vulkan/mod.rs` — timeline-semaphore `Fence`, `RelaySemaphores`, barrier lowering][hal-vk]
- [`wgpu-core/src/snatch.rs` — `Snatchable`/`SnatchLock`][snatch] · [`wgpu-core/src/lock/rank.rs` — static lock ranks][rank]
- [Arcanization lands on trunk — gfx-rs blog, November 24, 2023][arcanization] · [PR #3626][pr3626]
- [Discussion #2080 — "RE: performance" (5–10 % / 2× numbers)][d2080]
- [Discussion #5525 — "Major performance problems with multithreading"][d5525]
- [Issue #2710 — Remove locking from hot paths][i2710] · [Issue #5121 — remove registries][i5121] · [Issue #5204 — static lock order][i5204] · [Issue #6378 — recursive snatch-lock deadlock][i6378]
- [Issue #965 — interop with the underlying graphics API][i965] · [Issue #6142 — `drop_guard` semantics for raw imports][i6142]
- [google/dawn][dawn]: [`PassResourceUsageTracker.h`][dawn-usage-tracker] · [`vulkan/CommandBufferVk.cpp` — `PrepareResourcesForSyncScope`, vertex-stage barrier split][dawn-cmdvk] · [`vulkan/TextureVk.cpp` — `mSubresourceLastSyncInfos`][dawn-texvk] · [`Toggles.cpp`][dawn-toggles] · [`CommandAllocator.h`][dawn-cmdalloc]
- [WebGPU specification][webgpu-spec] · [WebGPU error handling][webgpu-errors] · [naga][naga]
- Related: [ash][rust-ash] · [vulkano][rust-vulkano] · [blade][rust-blade] · [Daxa][cpp-daxa] · [vuk][cpp-vuk] · [sync-validation][sync-validation] · [concepts][concepts] · [comparison][comparison] · [Survey index][index]

<!-- References -->

[repo]: https://github.com/gfx-rs/wgpu
[site]: https://wgpu.rs/
[docs]: https://docs.rs/wgpu/latest/wgpu/
[hal-docs]: https://docs.rs/wgpu-hal/latest/wgpu_hal/
[hal-readme]: https://github.com/gfx-rs/wgpu/blob/1f56415f14dfd8f64af0f2e1003dd30825015a5f/wgpu-hal/README.md
[hal-vk]: https://github.com/gfx-rs/wgpu/blob/1f56415f14dfd8f64af0f2e1003dd30825015a5f/wgpu-hal/src/vulkan/mod.rs
[track]: https://github.com/gfx-rs/wgpu/blob/1f56415f14dfd8f64af0f2e1003dd30825015a5f/wgpu-core/src/track/mod.rs
[snatch]: https://github.com/gfx-rs/wgpu/blob/1f56415f14dfd8f64af0f2e1003dd30825015a5f/wgpu-core/src/snatch.rs
[rank]: https://github.com/gfx-rs/wgpu/blob/1f56415f14dfd8f64af0f2e1003dd30825015a5f/wgpu-core/src/lock/rank.rs
[core-src]: https://github.com/gfx-rs/wgpu/tree/1f56415f14dfd8f64af0f2e1003dd30825015a5f/wgpu-core
[arcanization]: https://gfx-rs.github.io/2023/11/24/arcanization.html
[pr3626]: https://github.com/gfx-rs/wgpu/pull/3626
[d2080]: https://github.com/gfx-rs/wgpu/discussions/2080
[d5525]: https://github.com/gfx-rs/wgpu/discussions/5525
[i2710]: https://github.com/gfx-rs/wgpu/issues/2710
[i5121]: https://github.com/gfx-rs/wgpu/issues/5121
[i5204]: https://github.com/gfx-rs/wgpu/issues/5204
[i6378]: https://github.com/gfx-rs/wgpu/issues/6378
[i965]: https://github.com/gfx-rs/wgpu/issues/965
[i6142]: https://github.com/gfx-rs/wgpu/issues/6142
[ash]: https://github.com/ash-rs/ash
[dawn]: https://github.com/google/dawn
[dawn-usage-tracker]: https://github.com/google/dawn/blob/c5366f72b54c6935a1b7e49215f3fa01e4c376ed/src/dawn/native/PassResourceUsageTracker.h
[dawn-cmdvk]: https://github.com/google/dawn/blob/c5366f72b54c6935a1b7e49215f3fa01e4c376ed/src/dawn/native/vulkan/CommandBufferVk.cpp
[dawn-texvk]: https://github.com/google/dawn/blob/c5366f72b54c6935a1b7e49215f3fa01e4c376ed/src/dawn/native/vulkan/TextureVk.cpp
[dawn-toggles]: https://github.com/google/dawn/blob/c5366f72b54c6935a1b7e49215f3fa01e4c376ed/src/dawn/native/Toggles.cpp
[dawn-cmdalloc]: https://github.com/google/dawn/blob/c5366f72b54c6935a1b7e49215f3fa01e4c376ed/src/dawn/native/CommandAllocator.h
[naga]: https://github.com/gfx-rs/wgpu/tree/1f56415f14dfd8f64af0f2e1003dd30825015a5f/naga
[webgpu-spec]: https://www.w3.org/TR/webgpu/
[webgpu-errors]: https://www.w3.org/TR/webgpu/#errors-and-debugging
[rust-ash]: ./rust-ash.md
[rust-blade]: ./rust-blade.md
[rust-vulkano]: ./rust-vulkano.md
[cpp-daxa]: ./cpp-daxa.md
[cpp-vuk]: ./cpp-vuk.md
[sync-validation]: ./sync-validation.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
