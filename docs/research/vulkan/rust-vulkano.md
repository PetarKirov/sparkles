# vulkano (Rust)

The safety-maximalist Rust Vulkan wrapper: a hand-written safe layer over [`ash`][ash-dep] that re-validates (nearly) every Vulkan valid-usage rule on the host at call time, historically synchronized the GPU automatically via per-resource state tracking, and — after measuring what that tracking costs — is migrating wholesale to a compiled task graph ([`vulkano-taskgraph`][taskgraph-crate]).

| Field          | Value                                                                                                       |
| -------------- | ----------------------------------------------------------------------------------------------------------- |
| Language       | Rust                                                                                                        |
| License        | MIT OR Apache-2.0 (dual)                                                                                    |
| Repository     | [vulkano-rs/vulkano][repo]                                                                                  |
| Documentation  | [docs.rs/vulkano][docs] · [vulkano.rs guide][site]                                                          |
| Category       | Safety-first wrapper                                                                                        |
| First release  | Open-sourced March 2016 (Pierre "tomaka" Krieger); on crates.io since 2016                                  |
| Latest release | `0.35.x` line (`v0.35.0` tagged February 7, 2025); `vulkano-taskgraph 0.35.0` released alongside it         |
| Crates         | `vulkano`, `vulkano-shaders`, `vulkano-taskgraph`, `vulkano-util`, `vulkano-macros`, in-tree `autogen` tool |

> [!NOTE]
> Vulkano is the oldest still-maintained safe Vulkan wrapper in any language, and the one that has explored the **automatic synchronization** design space the furthest — including discovering, the hard way, where its runtime costs live. Its 2024–2025 trajectory (deprecating implicit sync in favor of an explicit, compile-once task graph) is the single most instructive datapoint in this survey for a future `sparkles:vulkan` design. Contrast with [ash][ash] (raw, zero validation), [wgpu][wgpu] (runtime tracking behind a portable API), and the C++ task-graph layers [daxa][daxa] and [vuk][vuk].

---

## Overview

### What it solves

Raw Vulkan pushes three classes of bugs onto the application: **invalid API usage** (thousands of "valid usage" rules, normally only caught by enabling the validation layers), **lifetime errors** (destroying a `VkBuffer` the GPU is still reading), and **synchronization errors** (missing barriers/semaphores, wrong image layouts, unsynchronized use of [externally synchronized][externsync] handles). Vulkano's bet is that all three can be eliminated in safe Rust: the library validates every call's arguments on the host, keeps resources alive via `Arc` ownership until the device is done with them, and either derives GPU↔GPU synchronization automatically or has the user declare accesses and compiles the synchronization ahead of time.

### Design philosophy

From the project [README][readme]:

> _"It follows the Rust philosophy, which is that as long as you don't use unsafe code you shouldn't be able to trigger any undefined behavior. In the case of Vulkan, this means that non-unsafe code should always conform to valid API usage."_

and, on scope:

> _"Plans to prevent all invalid API usages, even the most obscure ones. The purpose of Vulkano is not to simply let you draw a teapot, but to cover all possible usages of Vulkan and detect all the possible problems in order to write robust programs. Invalid API usage is prevented thanks to both compile-time checks and runtime checks."_

The same README is candid that the design is still moving: _"none of the known projects in the ecosystem (including Vulkano) reached stable release versions"_ — and indeed the synchronization story has been redesigned twice (see [Synchronization safety](#synchronization-safety)).

---

## How it works

### Binding generation & API coverage

Vulkano does **not** generate its public API from `vk.xml`. The FFI layer is outsourced to [`ash`][ash-dep] (a direct dependency of the `vulkano` crate, [`vulkano/Cargo.toml`][cargo]), and the safe wrapper types — `Instance`, `Device`, `Buffer`, `Image`, pipelines, command buffers — are **hand-written**, one Rust module per API area. What _is_ generated is the data-heavy periphery: an in-tree [`autogen`][autogen] binary (run by `build.rs`) parses a vendored [`vk.xml`][vkxml-vendored] with [`vk-parse`][vk-parse] plus the SPIR-V grammar `spirv.core.grammar.json`, and emits ([`autogen/src/main.rs`][autogen-main]):

| Generator                          | Output                                                                                                                                                 |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `errors.rs`                        | `VulkanError` from the registry's `VkResult` error codes                                                                                               |
| `extensions.rs`                    | `InstanceExtensions` / `DeviceExtensions` structs-of-`bool`s, with the registry's extension dependency/promotion metadata                              |
| `features.rs`                      | `DeviceFeatures` — every feature from every `VkPhysicalDevice*Features*` struct flattened into one struct-of-`bool`s                                   |
| `formats.rs`                       | The `Format` enum plus per-format metadata (block extent, components, compression, …) from the registry's `format` elements                            |
| `fns.rs`                           | Function-pointer tables grouped by core version / extension                                                                                            |
| `properties.rs`                    | `DeviceProperties` flattened across all property structs                                                                                               |
| `spirv_parse.rs` / `spirv_reqs.rs` | A SPIR-V parser and, per SPIR-V capability/extension, the Vulkan features/extensions that enable it, normalized via a `conjunctive_normal_form` module |
| `version.rs`                       | The registry header version                                                                                                                            |

This split answers the survey's registry question precisely: **the metadata that survives into the type system is the enumerable kind** — errors, formats, features, properties, extension dependency graphs, SPIR-V capability requirements. The per-command valid-usage rules and the `externsync` attributes do **not** survive mechanically; they are re-implemented by hand in each wrapper function's validation code (see [§ Error handling](#error-handling--validation-integration)). The cost of the hand-written approach is coverage lag: each new extension needs a manually authored safe wrapper, so vulkano trails the spec further than generated bindings like [ash][ash] or [vulkanalia][vulkanalia].

Notably, vulkano **abolishes `pNext` chains** in its public API instead of typing them: extension-struct members are flattened into the owning create-info struct as ordinary Rust fields (e.g. everything that would arrive via a `VkBufferCreateInfo` chain appears as `Option` fields on `BufferCreateInfo`). There is no typed chain mechanism to misuse — the chain is rebuilt internally when the call is translated to `ash`. Shader interfaces get the same flattening treatment at compile time: the [`vulkano-shaders`][vulkano-shaders] proc macro compiles GLSL in `build` position and generates Rust structs for the shader's interface — the README's _"Type-safe compile-time shaders … Automatically generated types for shader's Layout"_.

### Handle lifetime & ownership model

Ownership is **`Arc`-based and runtime-counted**, not lifetime-based. Every device-child wrapper holds an `Arc<Device>`; users hold `Arc<Buffer>`, `Arc<Image>`, `Arc<GraphicsPipeline>`, etc. Destruction is a `Drop` impl; keeping an object alive while the GPU uses it is achieved by cloning the `Arc` into whatever tracks the submission. The [CHANGELOG][changelog] for `v0.32.0` (October 31, 2022) states it directly:

> _"Queue now takes ownership of resources belonging to operations that you execute on it, to keep them from being destroyed while in use."_

So a submitted command buffer (and through it the queue/fence machinery) clones the `Arc` of every referenced resource and releases it when the corresponding fence is observed signaled — deferred reclamation by reference count.

Since `v0.32.0` there is also an explicit **raw layer**: `RawBuffer` and `RawImage` (renamed from `UnsafeBuffer`/`UnsafeImage` in `v0.32.0`, October 31, 2022, per the [CHANGELOG][changelog]) wrap a handle with no memory bound and no tracking, for users who want to do binding and lifetime management themselves.

[`vulkano-taskgraph`][taskgraph-crate] replaces user-visible `Arc`s with a slot-map: all resources live in a per-device [`Resources`][resources-src] collection — _"There can only exist one `Resources` collection per device, because there must only be one source of truth in regards to the synchronization state of a resource"_ ([`resource/mod.rs`][resources-src]) — and are referred to by copyable phantom-typed IDs ([§ Type-system techniques](#type-system-techniques)). Reclamation there is epoch-style: a deferred garbage collector (`concurrent_slotmap`'s hyaline scheme plus per-[`Flight`][flight-src] garbage queues gated on frame fences) instead of per-resource `Arc` traffic.

### Synchronization safety

Vulkano has shipped **three generations** of synchronization model, and the transitions between them are the finding.

**Generation 1 — `GpuFuture` chains (2017–present, legacy).** Host-side submission ordering is encoded in types: the [`GpuFuture`][gpufuture] trait represents _"an event that will happen on the GPU in the future"_, and combinators build a dependency chain — `then_execute(queue, cb)`, `then_signal_semaphore()`, `then_signal_fence_and_flush()`, `join(other)`. Each combinator returns a new concrete future type wrapping its predecessor, so the inter-submission dependency graph is literally a Rust type, and semaphores/fences are inserted by the library when the chain crosses queues or needs host visibility (the README: _"Dependencies between submissions are automatically detected, and semaphores are managed automatically"_). The future keeps the resources of its submissions alive and answers `check_buffer_access`/`check_image_access` queries so the next submission can decide whether a fresh barrier is needed.

**Generation 2 — `AutoCommandBufferBuilder` intra-buffer auto-sync.** Inside a command buffer, vulkano derives pipeline barriers automatically. The mechanism, verbatim from [`command_buffer/auto/mod.rs`][auto-mod]:

> _"Since barriers are 'expensive' (as the queue must block), vulkano attempts to group as many pipeline barriers as possible into one. Adding a command to an `AutoCommandBufferBuilder` does not immediately add it to the underlying command buffer builder. Instead the command is added to a queue, and the builder keeps a prototype of a barrier that must be added before the commands in the queue are flushed."_

The implementation cost is visible in [`auto/builder.rs`][auto-builder]: the internal `AutoSyncState` carries

```rust
// vulkano/src/command_buffer/auto/builder.rs (abridged)
barriers: HashMap<usize, Vec<DependencyInfo>>,
buffers:  HashMap<Arc<Buffer>, RangeMap<DeviceSize, BufferState>>,
images:   HashMap<Arc<Image>,  RangeMap<DeviceSize, ImageState>>,
```

— i.e. **per command buffer, per resource, per byte/subresource range** state tracking in hash maps of range maps, consulted and updated on every recorded command. That is the measured shape of "automatic synchronization": every `copy`/`dispatch`/`draw` pays hashing, range splitting, and barrier-merging logic at record time, every frame, even when the frame's structure is identical to the last one. Image layouts are tracked per range the same way; queue-family ownership is largely sidestepped (resources default to exclusive use on one queue; the future chain inserts semaphores when crossing queues).

**Generation 3 — `vulkano-taskgraph` (the v0.35-era rework).** Rather than rediscovering the same barriers per frame, the user declares a DAG once: `TaskGraph::create_task_node(name, QueueFamilyType, task)`, then per node `node.buffer_access(id, AccessTypes)` / `node.image_access(id, AccessTypes, ImageLayoutType)` ([`vulkano-taskgraph/src/lib.rs`][taskgraph-lib]). An `unsafe` [`compile`][compile-src] pass then plans everything ahead of time — it checks the graph is _"[weakly connected]: every node must be able to reach every other node when disregarding the direction of the edges"_ and has _"no [directed cycles]"_ ([`graph/compile.rs`][compile-src]) — and lowers it to a static instruction stream of submissions, pipeline barriers, semaphores (`SemaphoreIndex`, `Submission`, `BarrierIndex` in the compiler's output), render-pass objects, and a present hand-off. Frames in flight are first-class: a [`Flight`][flight-src] owns `frame_count` fences and a deferred-destruction queue, and `execute` replays the precompiled instructions against a `ResourceMap` binding [virtual resource IDs](#type-system-techniques) to physical resources each frame. Queue selection is also lifted into the graph: `QueueFamilyType::{Graphics, Compute, Transfer, Specific}` lets _"the task graph compiler … pick the most optimal queue family indices"_ ([`lib.rs`][taskgraph-lib]).

The trade is explicitness for cost: accesses are **declared, not inferred**, and (currently) **not validated** — `compile` is `unsafe` with the contract _"There must be no conflicting device accesses in task nodes with no path between them"_ ([`compile.rs`][compile-src]), and the crate banner warns: _"Vulkano's **EXPERIMENTAL** task graph implementation. … There is also currently no validation except the most bare-bones sanity checks."_ ([`lib.rs`][taskgraph-lib]). In survey terms vulkano is moving from **runtime auto-sync** to the **render-graph** camp of [daxa][daxa] and [vuk][vuk], with declared per-node accesses exactly like daxa's task-graph uses.

**Externally synchronized handles** (`externsync` in `vk.xml`) are handled by interior locking, not by types: `v0.32.0` made `Queue` access explicit — _"To do operations on a queue, you must now call [`Queue::with`] to gain access"_ ([CHANGELOG][changelog]) — which takes an internal `parking_lot` mutex; command pools are hidden behind a thread-aware `StandardCommandBufferAllocator`; recording command buffers simply don't implement `Send`/`Sync` ([`auto/builder.rs`][auto-builder]: _"command buffers in the recording state don't implement the `Send` and `Sync` traits"_). So the `externsync` contract is discharged at runtime (locks) or by `!Send` types, never surfaced as a capability in signatures.

### Type-system techniques

For "the deepest type-system subject" of this survey, vulkano's actual technique inventory is instructive — it is **less** exotic than its reputation suggests:

- **Typed futures (typestate-ish chaining).** The [`GpuFuture`][gpufuture] combinator chain encodes the submission DAG in nested concrete types (`then_signal_fence_and_flush()` returns `FenceSignalFuture<...>` wrapping the whole chain). This is the closest vulkano comes to typestate, and it is the part being retired.
- **Phantom-typed handles.** `vulkano-taskgraph`'s `Id<T>` is a `#[repr(transparent)]` slot-map key with `marker: PhantomData<fn() -> T>` ([`lib.rs`][taskgraph-lib]) — `Id<Buffer>`, `Id<Image>`, `Id<Swapchain>`, `Id<Flight>` are distinct types over the same 64-bit slot. A tag **bit inside the slot ID** distinguishes _virtual_ resources (graph-time placeholders, bound per frame via `ResourceMap`) from physical ones (`is_virtual()` checks `slot.tag() & Id::VIRTUAL_BIT`).
- **Typed buffer contents.** `Subbuffer<T>` carries the element type; the `BufferContents` derive (via `vulkano-macros` and `bytemuck`) proves the type is plain-old-data, and `vulkano-shaders` generates matching Rust types from the shader interface — host↔shader layout mismatches become compile errors.
- **Generated capability structs.** `DeviceFeatures` / `DeviceExtensions` / `DeviceProperties` are flat structs-of-`bool`s (see [§ Binding generation](#binding-generation--api-coverage)); feature/extension requirements are checked at runtime against them and reported through `RequiresOneOf` ([§ Error handling](#error-handling--validation-integration)) — capabilities are **data, not type parameters**. There is no branded/`Device`-indexed handle typing: pairing an object with the wrong device is a runtime validation error.
- **Marker-typed builders.** `AutoCommandBufferBuilder<L>` is parameterized over primary/secondary level, gating which methods exist.

Conspicuously **absent**: borrow-checker lifetimes for device-child relations (everything is `Arc`), linear types for swapchain/acquire protocols, const-generic or trait-level encoding of pipeline state, and typed `pNext` chains (flattened away, [§ Binding generation](#binding-generation--api-coverage)). Vulkano's safety weight rests on _runtime validation_, with the type system used for data layout and ID hygiene rather than protocol enforcement.

### Overhead & escape hatches

The overhead story has three tiers, with an escape hatch at each:

1. **Host validation on every call.** Every safe function validates all parameters against the Vulkan valid-usage rules before calling into `ash`. The escape hatch is per-call, not global — from the [crate docs][docs]: _"Many functions in Vulkano have two versions: the normal function, which is usually safe to call, and another function with `_unchecked` added onto the end of the name, which is unsafe to call."_ The `_unchecked` variants _"skip this validation entirely"_, are hidden from docs unless the `document_unchecked` cargo feature is enabled, and carry the contract: _"a call to the function is valid, if a call to the corresponding normal function with the same arguments would return without any error. All other usage … may be undefined behavior."_ This is host-side validation **duplicating the validation layers** — by design (it returns typed errors instead of logs, and is always on in safe code), but it means safe vulkano pays validation cost even in release builds where a layer-based workflow would pay zero.
2. **Auto-sync state tracking.** Generation-2 sync costs `HashMap<Arc<Buffer>, RangeMap<...>>` lookups and barrier-merging per recorded command, plus `Arc` clone/drop per resource per submission, plus the `Queue` mutex ([§ Synchronization safety](#synchronization-safety)). This recurring per-frame cost on unchanging frame structure is precisely what the task-graph rework amortizes into a one-time `compile`: `execute` replays precomputed instructions, and resource state lives in one concurrent slot map keyed by copyable IDs instead of `Arc`s.
3. **Raw-handle escape.** Every wrapper implements `VulkanObject`, exposing the underlying `ash` handle, so any missing or too-slow path can drop to [ash][ash] directly; `RawBuffer`/`RawImage` skip vulkano's memory binding and tracking; `RecordingCommandBuffer` (the `sys`-level builder under `AutoCommandBufferBuilder`) records without any resource tracking; and `vulkano-taskgraph`'s own `execute`/`compile` are `unsafe fn`s that trust the caller's declared accesses.

Nothing in vulkano is compile-time-only in the [vulkan-hpp][hpp] or [vulkan-zig][zig] sense: the safe path always carries runtime validation plus (gen-1/2) tracking, and "zero-overhead" is reachable only by opting out function-by-function (`_unchecked`) or layer-by-layer (raw types, `ash` handles).

### Error handling & validation integration

`v0.34.0` (October 25, 2023) reworked all error handling around two types ([CHANGELOG][changelog]): fallible functions return `Result<_, Validated<VulkanError>>`, where `Validated<E>` is _either_ a runtime error `E` (generated from `vk.xml`'s result codes, [§ Binding generation](#binding-generation--api-coverage)) _or_ a boxed [`ValidationError`][validationerror]. `ValidationError` is a structured report — fields `context` (_"The context in which the problem exists (e.g. a specific parameter)"_), `problem`, `requires_one_of` (_"settings that the user could enable to avoid the problem"_ — i.e. which feature/extension/API version would make the call legal), and `vuids`: _"Valid Usage IDs (VUIDs) in the Vulkan specification that relate to the problem"_ ([docs.rs][validationerror]). Hand-maintained validation code thus re-attaches the registry's VUID identifiers that the autogen pipeline cannot extract mechanically — the spec linkage survives as curated string data.

This makes vulkano's relationship to the [Khronos validation layers][sync-validation] unusual: it does not integrate them, it **competes** with them — same rules, but synchronous, typed, always-on in safe code, and usable for control flow (`requires_one_of` enables capability-driven fallback). The gaps are the inverse of the layers': vulkano's checks are only as complete as its hand-written coverage ("plans to prevent _all_ invalid usages" is aspirational — issues like [#2217][issue-2217] track unchecked cases), and `vulkano-taskgraph` currently validates almost nothing, so the practical recommendation for taskgraph users is to keep the layers on during development anyway.

---

## Strengths

- **The most complete safe-by-default Vulkan API anywhere**: typed, synchronous, always-on host validation with VUID-linked, capability-aware errors — far better diagnostics ergonomics than log-scraping validation layers.
- **A decade of design history in public**: every synchronization model it tried (typed future chains → per-resource auto-sync → compiled task graph) is documented in the tree and CHANGELOG, with the costs that motivated each move.
- **Per-call `unsafe` granularity**: `_unchecked` twins for every validated function let hot paths opt out surgically instead of abandoning the safe layer wholesale.
- **`vulkano-shaders` compile-time shader interface typing** — host/shader layout mismatch is a build error, a feature most surveyed wrappers lack.
- **Registry-derived capability machinery**: generated `DeviceFeatures`/`DeviceExtensions`/`Format` metadata plus SPIR-V capability→feature requirement tables (in CNF) give principled feature negotiation.
- **The task-graph rework is architecturally sound**: virtual phantom-typed resource IDs, flights with fence-gated deferred reclamation, compiler-chosen queue families, precompiled barrier/semaphore streams — the same shape as [daxa][daxa]/[vuk][vuk] with Rust ID hygiene.

## Weaknesses

- **Validation overhead is structural**: safe code pays host re-validation on every call in every build profile; there is no global "release mode" switch, only per-call `_unchecked`.
- **Generation-2 auto-sync is expensive by construction** — per-command hash-map + range-map tracking and per-submission `Arc` traffic — and is the part of the library its own maintainers are replacing.
- **The replacement is not ready**: `vulkano-taskgraph` is self-described _"EXPERIMENTAL … many bugs and incomplete features … currently no validation except the most bare-bones sanity checks"_, and its core entry points are `unsafe` — the safety story regresses precisely where the performance story improves.
- **Hand-written wrapper = coverage lag**: new Vulkan extensions (e.g. ray tracing, descriptor buffers) arrive late or partially compared to generated bindings.
- **No type-level device/queue/extension branding**: wrong-device and wrong-queue-family mistakes are runtime errors, despite Rust having the machinery (phantom branding) to catch some statically.
- **Perpetual 0.x**: breaking releases roughly yearly (`0.32` → `0.33` → `0.34` → `0.35` each reworked core APIs), and the official guide lags the API.

## Key design decisions and trade-offs

| Decision                                                           | Rationale                                                                                         | Trade-off                                                                                                  |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Hand-written safe layer over `ash`, autogen only for registry data | Valid-usage rules need judgment and Rust-shaped APIs; data tables (formats, features) don't       | Coverage lags the spec; VUID knowledge lives in hand-maintained code, not derived from `vk.xml`            |
| Host-side validation on every safe call, typed `ValidationError`   | UB impossible without `unsafe`; errors are values with VUIDs + `requires_one_of`, not layer logs  | Runtime cost in all build profiles; duplicates the validation layers; opt-out only per call (`_unchecked`) |
| `Arc` ownership + queue-held references (gen 1/2)                  | GPU-lifetime safety without lifetimes infecting every signature                                   | Ref-count traffic per submission; no compile-time lifetime guarantees                                      |
| Automatic barriers via per-resource range tracking (gen 2)         | Sync is "annoying to handle and error-prone" — derive it from observed accesses                   | Hash-map/range-map work per recorded command, re-paid every frame; barrier quality limited by local view   |
| `GpuFuture` typed combinator chains (gen 1)                        | Submission ordering as composable types; semaphores/fences managed automatically                  | Type nesting grows with the chain; resource liveness tied to opaque future objects; being retired          |
| Task graph compiled once, replayed per frame (gen 3)               | Frame structure is static — pay planning once; enables multi-queue planning and prebuilt barriers | Accesses are declared not inferred; `compile`/`execute` are `unsafe`; validation not yet implemented       |
| Phantom-typed slot-map IDs + virtual resources (taskgraph)         | Copyable, type-safe, device-scoped handles; per-frame rebinding of swapchain images               | IDs are runtime-checked against one `Resources` registry; another API dialect alongside `Arc` types        |
| `pNext` chains flattened into create-info structs                  | Misuse-proof, discoverable, idiomatic Rust                                                        | Every new extension struct requires editing the wrapper by hand; no generic chain extensibility            |
| `externsync` discharged by interior locks / `!Send` types          | Zero user-visible ceremony; safe by default                                                       | Mutex cost on `Queue` even in single-threaded apps; the contract is invisible in signatures                |

---

## Sources

- [vulkano-rs/vulkano — GitHub repository][repo] · [README][readme] (safety philosophy, ecosystem comparison)
- [vulkano on docs.rs][docs] (validation / `_unchecked` / `document_unchecked` documentation)
- [`ValidationError` — docs.rs][validationerror] (`context`, `problem`, `requires_one_of`, `vuids` fields)
- [`GpuFuture` — docs.rs][gpufuture] (typed future combinators)
- [CHANGELOG.md][changelog] (v0.31–v0.35: queue ownership, `Validated`/`ValidationError`, `RawBuffer`/`RawImage`)
- [`autogen/src/main.rs`][autogen-main] — `vk-parse` over vendored [`vk.xml`][vkxml-vendored] + SPIR-V grammar; generator list
- [`vulkano/src/command_buffer/auto/mod.rs`][auto-mod] — barrier-prototype auto-sync docs (verbatim quote)
- [`vulkano/src/command_buffer/auto/builder.rs`][auto-builder] — `AutoSyncState` hash-map/range-map tracking
- [`vulkano-taskgraph/src/lib.rs`][taskgraph-lib] — experimental banner, `Id<T>` phantom IDs, `QueueFamilyType`, `unsafe execute`
- [`vulkano-taskgraph/src/graph/compile.rs`][compile-src] — `unsafe compile`, DAG conditions, lowered barriers/semaphores/submissions
- [`vulkano-taskgraph/src/resource/mod.rs`][resources-src] — single-source-of-truth `Resources`; [`resource/state.rs`][flight-src] — `Flight` fences
- [vulkano.rs — About][site] (design goals)
- Siblings: [ash][ash] · [vulkanalia][vulkanalia] · [wgpu][wgpu] · [daxa][daxa] · [vuk][vuk] · [vulkan-hpp][hpp] · [vulkan-zig][zig] · [sync validation][sync-validation] · [comparison][comparison] · [index][index]

<!-- References -->

[repo]: https://github.com/vulkano-rs/vulkano
[readme]: https://github.com/vulkano-rs/vulkano/blob/master/README.md
[docs]: https://docs.rs/vulkano/latest/vulkano/
[site]: https://vulkano.rs/
[changelog]: https://github.com/vulkano-rs/vulkano/blob/master/CHANGELOG.md
[cargo]: https://github.com/vulkano-rs/vulkano/blob/master/vulkano/Cargo.toml
[autogen]: https://github.com/vulkano-rs/vulkano/tree/master/autogen
[autogen-main]: https://github.com/vulkano-rs/vulkano/blob/master/autogen/src/main.rs
[vkxml-vendored]: https://github.com/vulkano-rs/vulkano/blob/master/autogen/vk.xml
[vk-parse]: https://crates.io/crates/vk-parse
[ash-dep]: https://crates.io/crates/ash
[auto-mod]: https://github.com/vulkano-rs/vulkano/blob/master/vulkano/src/command_buffer/auto/mod.rs
[auto-builder]: https://github.com/vulkano-rs/vulkano/blob/master/vulkano/src/command_buffer/auto/builder.rs
[gpufuture]: https://docs.rs/vulkano/latest/vulkano/sync/future/trait.GpuFuture.html
[validationerror]: https://docs.rs/vulkano/latest/vulkano/struct.ValidationError.html
[taskgraph-crate]: https://crates.io/crates/vulkano-taskgraph
[taskgraph-lib]: https://github.com/vulkano-rs/vulkano/blob/master/vulkano-taskgraph/src/lib.rs
[compile-src]: https://github.com/vulkano-rs/vulkano/blob/master/vulkano-taskgraph/src/graph/compile.rs
[resources-src]: https://github.com/vulkano-rs/vulkano/blob/master/vulkano-taskgraph/src/resource/mod.rs
[flight-src]: https://github.com/vulkano-rs/vulkano/blob/master/vulkano-taskgraph/src/resource/state.rs
[vulkano-shaders]: https://crates.io/crates/vulkano-shaders
[issue-2217]: https://github.com/vulkano-rs/vulkano/issues/2217
[externsync]: ./concepts.md
[ash]: ./rust-ash.md
[vulkanalia]: ./rust-vulkanalia.md
[wgpu]: ./rust-wgpu.md
[daxa]: ./cpp-daxa.md
[vuk]: ./cpp-vuk.md
[hpp]: ./cpp-vulkan-hpp.md
[zig]: ./zig-vulkan-zig.md
[sync-validation]: ./sync-validation.md
[comparison]: ./comparison.md
[index]: ./index.md
