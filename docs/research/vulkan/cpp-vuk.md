# vuk (C++)

A rendergraph-based abstraction layer for Vulkan that treats a frame as a lazily-evaluated program: passes are functions, resources are typed `Value<T>` futures, and an IR compiler derives every barrier, layout transition, queue transfer, and submission from declared accesses.

| Field         | Value                                                                                                  |
| ------------- | ------------------------------------------------------------------------------------------------------ |
| Language      | C++20 (`target_compile_features(vuk PUBLIC cxx_std_20)` in [`CMakeLists.txt`][cmake])                  |
| License       | MIT                                                                                                    |
| Repository    | [martty/vuk][repo]                                                                                     |
| Documentation | [vuk.readthedocs.io][docs]                                                                             |
| Key Authors   | Marcell Kiss (martty) and contributors                                                                 |
| Category      | Render-graph / auto-sync layer (not a binding — sits on raw `vulkan.h` handles)                        |
| Sync strategy | Fully automated: per-argument `Access` declarations compiled by an IR into `synchronization2` barriers |
| First release | `v0.4` era tags; latest GitHub _release_ is `v0.5` (August 13, 2023)                                   |
| Latest tag    | `v0.7` (tagged December 23, 2025); `master` reviewed at commit `61abde9` (April 26, 2026)              |

> [!NOTE]
> vuk was rewritten between `v0.5` and `v0.6`: the original `RenderGraph`+`Future` API became a value-based eager-DSL/lazy-execution model built on a genuine compiler IR ([`include/vuk/IR.hpp`][ir]). This deep-dive covers current `master`; older articles describing `vuk::Future` and named-resource strings document the pre-rewrite API.

---

## Overview

### What it solves

Raw Vulkan makes the programmer schedule the GPU by hand: pipeline barriers with source/destination stage+access masks, image layout transitions, queue-family ownership transfers, semaphores between queues, and fences back to the host. Getting any of these wrong is undefined behavior that [synchronization validation][sync-validation] only partially catches. vuk's position — inherited from Themaister's [render-graph articles][maister] that the project credits as its origin — is that all of this is _derivable_: if every pass declares **how** it uses each resource, a compiler can compute the minimal synchronization, place it, and also deduce render passes, framebuffers, image layouts, and multi-queue submission.

Where [Daxa's TaskGraph][daxa] applies the same idea as a record-once/execute-many framework, vuk goes further down the "frame as program" road: passes compose like ordinary C++ function calls over `Value<T>` futures, nothing executes until a result is observed, and the work list is compiled each submit by a multi-pass IR pipeline (SSA linking, type inference, queue inference, partitioning, sync lowering, linearization — [`src/IRPasses.cpp`][irpasses]).

### Design philosophy

From the documentation root ([`docs/index.rst`][index-rst]), verbatim (including the typos):

> _"Alltogether vuk presents a vision of GPU development that embraces compilation - the idea that knowledge about optimisation of programs can be encoded into to tools (compilers) and this way can be insitutionalised, which allows a broader range of programs and programmers to take advantage of these."_

And the execution model, from [`docs/topics/rendergraph.rst`][rg-rst]:

> _"The key difference is that execution is **lazy** - work is deferred until you explicitly observe a result."_

The [README][readme] frames the feature set as automation with full access retained: _"Comes with lots of sugar to simplify common operations, but still exposing the full Vulkan interface"_ — automatic renderpass/subpass/framebuffer deduction, automatic layout transitions, shader-reflection-driven pipeline and descriptor-set-layout creation, and _"Automates resource binding with hashmaps, reducing descriptor set allocations and updates."_

---

## How it works

A pass is a named lambda whose parameters after `CommandBuffer&` are resources annotated with an [`Access`](#synchronization-safety); `make_pass` turns it into a callable that weaves an IR `CALL` node. From [`examples/01_triangle.cpp`][triangle]:

```cpp
// examples/01_triangle.cpp
auto pass = vuk::make_pass("01_triangle", [](vuk::CommandBuffer& command_buffer, VUK_IA(vuk::eColorWrite) color_rt) {
    command_buffer.set_viewport(0, vuk::Rect2D::framebuffer());
    command_buffer.set_scissor(0, vuk::Rect2D::framebuffer());
    command_buffer
        .set_rasterization({})              // Set the default rasterization state
        .set_color_blend(color_rt, {})      // Set the default color blend state
        .bind_graphics_pipeline("triangle") // Recall pipeline for "triangle" and bind
        .draw(3, 1, 0, 0);                  // Draw 3 vertices
    return color_rt;
});

auto drawn = pass(std::move(target));
```

`target` and `drawn` are `vuk::Value<vuk::ImageAttachment>` — futures naming a resource produced by GPU work that has not happened yet. Values enter the graph via `declare_ia`/`declare_buf` (vuk allocates), `acquire_ia`/`acquire_buf` (import an existing resource with its last-known `Access`), or `discard_*` (import, contents dead); they leave via `Value::as_released(access, domain)`, which records the final state a consumer outside the graph will see ([`include/vuk/RenderGraph.hpp`][rendergraph-hpp]). Calling `submit()`, `wait()`, or `get()` on a `Value` triggers `Compiler::compile` + `execute` over the accumulated IR; per [`docs/topics/rendergraph.rst`][rg-rst], computation happens once — re-observing the same `Value` does not re-execute it (see [Overhead](#overhead--escape-hatches) for the mechanism).

The IR ([`include/vuk/IR.hpp`][ir]) is a real compiler IR: nodes of kind `CONSTRUCT`, `CALL`, `SLICE` (mip/layer/subrange views), `CONVERGE`, `ACQUIRE`, `RELEASE`, `ACQUIRE_NEXT_IMAGE`, `CAST`, `MATH_BINARY`, … over a structural type system (`INTEGER_TY`, `COMPOSITE_TY`, `IMBUED_TY` — a type annotated with an `Access`, `ALIASED_TY`, `OPAQUE_FN_TY`). Even integers can be `Value<uint64_t>` with GPU-side arithmetic via `MATH_BINARY` nodes, so buffer sizes and counts can flow through the graph without host round-trips.

### Binding generation & API coverage

vuk is **not generated from `vk.xml`** and is not a binding: it includes `<vulkan/vulkan.h>` directly ([`include/vuk/Config.hpp`][config]) and consumes raw `VkInstance`/`VkDevice`/`VkQueue` handles the application created (the examples use `vk-bootstrap`). Its Vulkan surface is a hand-curated dispatch table declared as X-macro lists — [`VkPFNRequired.hpp`][pfn-req] (101 entries, grouped by core version `// 1.0`, `// 1.1`, `// 1.2`) and [`VkPFNOptional.hpp`][pfn-opt] (19 entries, including `VK_KHR_ray_tracing` / acceleration-structure commands):

```cpp
// include/vuk/runtime/vk/VkPFNRequired.hpp
// REQUIRED
// 1.0
VUK_X(vkCmdBindDescriptorSets)
VUK_X(vkCmdBindIndexBuffer)
VUK_X(vkCmdBindPipeline)
```

The table is filled either by the user or by dynamic loading: `FunctionPointers::load_pfns(instance, device, allow_dynamic_loading_of_vk_function_pointers)` ([`VkRuntime.hpp`][vkruntime]); a missing required pointer is a `RequiredPFNMissingException`. The platform floor is stated verbatim in [`src/extra/init/SimpleInit.cpp`][simpleinit]: _"vuk requires at least vulkan 1.2 and the synchronization2 extension"_. Coverage is therefore _curated_, not exhaustive: graphics, compute, transfer, ray tracing, swapchain, timestamps — but no video, and new extensions appear only when vuk grows a feature that needs them. No `vk.xml` metadata (`externsync`, valid-usage) survives into the API, because none is consumed; the safety story is entirely vuk's own graph compiler. Applications needing full enumerated bindings pair vuk with a binding such as [Vulkan-Hpp][vulkan-hpp].

### Handle lifetime & ownership model

Resource memory is managed by a chainable **allocator** hierarchy ([`include/vuk/runtime/vk/Allocator.hpp`][allocator]): `DeviceVkResource` (direct Vulkan allocation), `DeviceFrameResource` (a ring of N frames; everything allocated from frame _i_ is recycled when frame _i+N_ begins), `DeviceLinearResource` (arena), and `DeviceNestedResource` for stacking. Long-term handles use the RAII wrapper `Unique<T>` (move-only, `Unique(Unique const&) = delete`, frees through its `Allocator` on destruction). `Buffer` and `ImageAttachment` themselves are _copyable plain structs_ carrying raw `VkBuffer`/`VkImage` plus metadata — ownership lives in the allocator and in `Unique`, not in the handle type, so nothing in the type system prevents using a dead handle; the frame ring plus deferred destruction makes the common per-frame case safe by construction.

Graph-side lifetime is reference-counted: a `Value<T>` holds a `std::shared_ptr<ExtNode>` keeping its IR subgraph alive, and dead nodes are reclaimed by `IRModule::collect_garbage()` ([`include/vuk/IR.hpp`][ir]). Keeping a `Value` alive across frames is the supported idiom for persistent GPU state — the executed node degenerates into a cheap `ACQUIRE` (see [Overhead](#overhead--escape-hatches)).

### Synchronization safety

Synchronization is **fully automated** from per-argument `Access` declarations — there is no user-facing barrier API at all. `Access` ([`include/vuk/Types.hpp`][types]) is a 64-bit flag enum whose values each imply a stage+access+layout triple:

```cpp
// include/vuk/Types.hpp
/// Written as a framebuffer color attachment
eColorWrite = 1ULL << 2,
/// Sampled in a vertex shader
eVertexSampled = 1ULL << 5,
```

`to_use(Access)` in [`include/vuk/SyncLowering.hpp`][synclowering] expands an `Access` into a `ResourceUse { PipelineStageFlags stages; AccessFlags access; ImageLayout layout; }`. The compiler ([`src/IRPasses.cpp`][irpasses]) then runs, per `Compiler::compile`: SSA link building over value revisions (`build_links`), inference reification (unspecified extents/formats/sample counts propagated via `same_extent_as`-style constraints), chain collection, `queue_inference()` (forward/backward propagation of `DomainFlagBits` through the graph), `pass_partitioning()` into transfer/compute/graphics streams, sync lowering (`build_sync`, which merges compatible read groups into _"a merged layout (TRANSFER_SRC_OPTIMAL / READ_ONLY_OPTIMAL / GENERAL)"_), and linearization.

The backend emits `VkImageMemoryBarrier2KHR`/`VkMemoryBarrier2KHR` (`synchronization2` is mandatory). **Queue-family ownership transfer is derived, not declared**: a barrier gets real family indices only when the producing and consuming streams sit on executors with different queue families ([`src/runtime/vk/Backend.cpp`][backend]):

```cpp
// src/runtime/vk/Backend.cpp
barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
if (src_use.stream && dst_use.stream && src_use.stream != dst_use.stream) {         // cross-stream
    ...
    if (src_queue->get_queue_family_index() != dst_queue->get_queue_family_index()) { // cross queue family
        barrier.srcQueueFamilyIndex = src_queue->get_queue_family_index();
        barrier.dstQueueFamilyIndex = dst_queue->get_queue_family_index();
    }
}
```

Buffers sidestep QFOT entirely: when more than one queue family exists they are created with `VK_SHARING_MODE_CONCURRENT` ([`src/runtime/vk/DeviceVkResource.cpp`][devicevk]). Cross-queue and host-GPU ordering uses **one timeline semaphore per `QueueExecutor`** (`VK_SEMAPHORE_TYPE_TIMELINE`, [`src/runtime/vk/VkQueueExecutor.cpp`][queueexec]); a point in device time is the two-word `SyncPoint { Executor* executor; uint64_t visibility; }`, whose comment reads verbatim _"results are available if waiting for {executor, visibility}"_ ([`include/vuk/SyncPoint.hpp`][syncpoint]). Fences are absent from the API — host waits are timeline-semaphore waits surfaced as `Value::wait()`/`Signal::Status::eHostAvailable`. Swapchain images enter as `ACQUIRE_NEXT_IMAGE` IR nodes so even binary-semaphore present sync is graph-derived. The README's one honest unchecked box: fine-grained `VkEvent`-based split barriers are _not_ used (_"[ ] using fine grained synchronization when possible (events)"_, [README][readme]).

Implicit vs. explicit external synchronization (`vk.xml` `externsync`) is **not modeled in types**; instead vuk removes the hazard category — command pools, descriptor pools, and queues are owned by executors/allocators, and `Runtime` documents which entry points are thread-safe. Multi-threaded graph _construction_ is supported via a thread-local `current_module`; submission is serialized per executor.

### Type-system techniques

- **Typed futures (phantom-ish wrapper):** `Value<T>` is a thin typed view over an untyped IR reference (`UntypedValue` + `ExtNode`), with `T`-specific surface grafted on — `mip()`, `layer()`, `same_extent_as()` for `ImageAttachment`; `subrange()` for `Buffer`; arithmetic operators for `Value<uint64_t>` ([`include/vuk/Value.hpp`][value]).
- **Access as a non-type template parameter:** pass arguments carry their access _in the signature_. `VUK_IA(access)` expands to `vuk::Arg<vuk::ImageAttachment, access, vuk::tag_type<__COUNTER__>>` ([`include/vuk/RenderGraph.hpp`][rendergraph-hpp]), and the `Arg` carrier ([`include/vuk/Types.hpp`][types]) is:

  ```cpp
  // include/vuk/Types.hpp
  template<class Type, Access acc, class UniqueT>
  struct Arg {
      using type = Type;
      static constexpr Access access = acc;
      Type* ptr;
      ...
  };
  ```

  `make_pass` reflects the lambda's parameter pack at compile time (the `__COUNTER__` tag keeps otherwise-identical argument types distinct) and builds the matching `IMBUED_TY` IR types — so declaring usage is part of the function type, not a separate registration step, and passing a `Value<Buffer>` where an image is expected is a compile error.

- **Runtime structural type system:** beneath the C++ types sits the IR's own hashed, structural `Type` lattice (`IMBUED_TY` = type + access, `ALIASED_TY`, composites for images/buffers), which is what inference and sync lowering actually operate on — C++ types are the checked frontend, IR types the semantic truth.
- **No linear/affine ownership and no borrow checking:** `Value` is freely copyable (shared graph node); use-after-free of raw handles is prevented operationally (frame rings, deferred destruction), not by types. C++20 offers vuk no equivalent of [Vulkano's][vulkano] lifetime-checked references — a relevant delta for a D port, where `DIP1000`/`scope` could type the `CommandBuffer&`-scoped `Arg::ptr` borrows.
- **Provenance capture instead of lifetimes:** every graph-building API threads `VUK_CALLSTACK` (`std::source_location` chains) so compiler errors point at the user code that created the offending node.

### Overhead & escape hatches

vuk's costs are deliberately **runtime, amortized by caching**, not compile-time-only:

- **Per-submit graph compilation.** The IR is rebuilt by running your frame code and recompiled on every `submit()` — there is no record-once/execute-many compiled artifact as in [Daxa](#scheduling-model-vs-daxa-taskgraph). The mitigations are arena/colony node storage (`plf::colony`, `InlineArena`), `ShortAlloc`/`FixedVector` small-allocation tooling, and partial evaluation (next point). The reusable `Compiler` object retains state across `compile()` calls but each call re-derives schedule and sync.
- **Partial evaluation of executed work.** After a node executes, the backend rewrites it _in place_ into an `ACQUIRE` node carrying the produced values and their last-use sync state — the comment in `node_to_acq` ([`src/runtime/vk/Backend.cpp`][backend]) says verbatim _"// morph into acquire"_. A `Value` kept across frames therefore costs one constant-like IR node thereafter: the upload chain runs once, and subsequent graphs see only "resource, available at `{executor, visibility}`, last used as X". This is the current incarnation of the old `Future` cross-frame story.
- **Hash-based runtime caches everywhere.** Pipelines, pipeline layouts, descriptor-set layouts, shader modules, samplers, render passes, framebuffers, image views, and descriptor sets are all `Cache<T>` hashmaps keyed on create-info ([`src/runtime/vk/VkRuntime.cpp`][vkruntime-cpp], [`src/runtime/vk/DeviceFrameResource.cpp`][framers]); descriptor sets are hashed per draw from `bind_*` calls (the README's _"Automates resource binding with hashmaps"_), with `set_descriptor_set_strategy()` and `bind_persistent(set, PersistentDescriptorSet&)` ([`include/vuk/runtime/CommandBuffer.hpp`][cmdbuf]) as the opt-outs for bindless/perf-critical paths.
- **Escape hatches.** `CommandBuffer::get_underlying()` returns the raw `VkCommandBuffer` — annotated verbatim _"Unsafe: use only when not setting state, eg. tracing. Otherwise use the bind_X_state functions"_ ([`include/vuk/runtime/CommandBuffer.hpp`][cmdbuf]). `Buffer`/`ImageAttachment` expose their raw `VkBuffer`/`VkImage`/`VkImageView`, the device/instance/queues are the application's to begin with, and `acquire_*`/`as_released` are the sanctioned airlock for resources whose lifetime vuk never sees. There is no zero-overhead mode: you cannot keep the pass API and skip graph compilation.

### Error handling & validation integration

All fallible APIs return `vuk::Result<T, E>` ([`include/vuk/Result.hpp`][result]) — attributed verbatim in-source as _"based on `https://github.com/kociap/anton_core/blob/master/public/anton/expected.hpp`"_ — a discriminated union whose error arm is a heap-allocated pointer to an `Exception`-derived object. Its distinctive policy is **unobserved-error escalation**: destroying a `Result` holding an unexamined error calls `_error->throw_this()` when `VUK_USE_EXCEPTIONS` is set, otherwise `std::abort()`; `VUK_FAIL_FAST` asserts at the error's creation site instead. The error taxonomy ([`include/vuk/Exception.hpp`][exception]) covers `ShaderCompilationException`, `RenderGraphException` (graph validation failures: unattached resources, inference contradictions, illegal access combinations — diagnosed at compile-of-the-graph, before any Vulkan call, with `VUK_CALLSTACK` source locations in the message), `RequiredPFNMissingException`, `VkException` (a `VkResult` wrapper), and `AllocateException`.

`CommandBuffer` recording is monadic-light: `bind_*`/`draw` return `CommandBuffer&` for chaining while a floating `Result<void> current_error` latches the first failure; the pass framework checks `result()` after the callback, so a broken bind poisons the pass rather than crashing mid-record ([`include/vuk/runtime/CommandBuffer.hpp`][cmdbuf]). For debugging, `Compiler::dump_graph()` emits the IR ([`src/GraphDumper.cpp`][dumper]), passes/resources get debug names propagated to Vulkan object names (the README: _"Helps debugging by naming the internal resources"_), and because barriers are machine-derived, [synchronization validation][sync-validation] findings indicate vuk bugs rather than user bugs. Khronos validation layers remain the backstop for everything below the graph (vuk does not ingest validation output programmatically).

### Scheduling model vs Daxa TaskGraph

Both libraries derive barriers from declared per-task accesses, but their **compilation economics differ fundamentally**:

| Aspect              | vuk                                                                                    | [Daxa TaskGraph][daxa]                                                                                                       |
| ------------------- | -------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Graph construction  | Re-built every frame by running C++ code over lazy `Value`s; shape may change freely   | Recorded once into a `TaskGraph`, then `complete()`d; shape is fixed (escape: permutations)                                  |
| Compilation cost    | `Compiler::compile` per submit; amortized via `ACQUIRE` morphing + create-info caches  | Paid once: _"record graph once and execute it many times, significantly reducing CPU overhead"_ ([Daxa README][daxa-readme]) |
| Dynamism            | Free — any frame can build any graph; data-dependent values via `Value<uint64_t>` math | Conditionals via pre-compiled graph permutations; per-frame variation is otherwise re-recording                              |
| Use declaration     | In the C++ type: `Arg<T, Access, tag>` via `VUK_IA`/`VUK_BA` macros                    | Runtime attachment lists (`TaskAttachmentInfo`) on task structs                                                              |
| Cross-frame results | A live `Value` partial-evaluates to `ACQUIRE`                                          | Persistent `TaskBuffer`/`TaskImage` objects track latest access between executions                                           |
| Optimization locus  | IR passes: queue inference, partitioning, read-group merging, linearization            | Graph-level: task reordering to minimize barriers, transient memory aliasing                                                 |

In short, Daxa buys per-frame CPU time with rigidity; vuk buys flexibility (and a compiler-shaped future: the docs say development focuses on a _"backend… -agnostic form of representing graphics programs"_ [sic], [`docs/index.rst`][index-rst]) with a per-frame compile it must keep cheap. See the [Daxa deep-dive][daxa] and the [cross-survey comparison][comparison].

---

## Strengths

- **The most complete auto-sync design surveyed**: barriers, layouts, renderpasses, framebuffers, queue routing, QFOT, timeline semaphores, and swapchain sync are all derived from one declaration — the per-argument `Access`.
- **Access in the function type**: `Arg<Type, Access, tag>` makes resource usage part of a pass's compile-time signature, catching wrong-resource-kind errors and keeping declarations adjacent to use (no separate registration list to drift).
- **Lazy `Value` composition** subsumes upload pipelines, cross-frame persistence, GPU readbacks, and multi-queue chains under one future-like abstraction with partial evaluation (`node_to_acq`) keeping steady-state cost low.
- **Genuine IR with inference**: image parameters propagate through the graph (`same_extent_as`), integers can live GPU-side, and `dump_graph()` gives a real compiler-style debugging artifact.
- **Graph-time validation with source locations** (`VUK_CALLSTACK`) reports errors before any Vulkan call, in terms of user code.
- **Multi-queue for free**: `DomainFlagBits::eAny` plus `queue_inference()`/`pass_partitioning()` exploits async compute/transfer without user-visible semaphore code.

## Weaknesses

- **Per-frame graph compilation is irreducible CPU overhead** — the inverse of [Daxa's][daxa] precompilation model; vuk has no record-once mode, and its IR passes run on every submit.
- **No type-level lifetime/ownership safety**: `Buffer`/`ImageAttachment` are copyable raw-handle structs; safety against use-after-free is operational (frame rings, RAII `Unique<T>`), and `Access` correctness inside the pass body (does the shader really only sample?) is unchecked.
- **Curated, lagging API surface**: the hand-maintained PFN tables cover what vuk uses (no `vk.xml` generation, no video, no mesh-shading-specific sugar at review time); anything else needs the raw escape hatches.
- **Hash lookups on hot paths**: per-draw descriptor-set hashing and create-info cache probes are the price of "binding with hashmaps"; bindless via `bind_persistent` is the workaround, not the default.
- **No `VkEvent` split barriers** — the README's own unchecked box; sync is correct-but-coarse pipeline barriers.
- **Pre-1.0, API in flux** ("will change in API and behaviour as we better understand the shape of the problem", [`docs/index.rst`][index-rst]); the `v0.5`→`v0.6` rewrite invalidated most third-party tutorials, and bus factor is essentially one.

## Key design decisions and trade-offs

| Decision                                                                     | Rationale                                                                                      | Trade-off                                                                                          |
| ---------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| Lazy `Value<T>` futures + per-submit IR compilation (vs. record-once)        | Frames stay ordinary C++ control flow; arbitrary per-frame dynamism; uploads/readbacks compose | Graph build + compile every frame; CPU cost must be re-amortized via caches and `ACQUIRE` morphing |
| `Access` as non-type template parameter in pass signatures (`VUK_IA`)        | Usage declarations are type-checked, colocated with the parameter, reflectable by `make_pass`  | Macro-based ergonomics; declared access is trusted, not verified against shader behavior           |
| Layered on raw `vulkan.h` + curated X-macro PFN tables (no `vk.xml` codegen) | Zero binding maintenance; interops with any loader/binding; small dispatch surface             | API coverage lags the registry; no `externsync`/valid-usage metadata can inform the type system    |
| One timeline semaphore per queue executor; `SyncPoint{executor, visibility}` | Uniform GPU/host sync; no fence pools; trivially expressible cross-queue waits                 | Requires Vulkan 1.2 + `synchronization2`; binary semaphores survive only at the swapchain boundary |
| QFOT derived from stream partitioning; buffers `VK_SHARING_MODE_CONCURRENT`  | Ownership transfer is invisible to users; buffers skip the dance entirely                      | Concurrent sharing can cost bandwidth on some hardware; no user control over transfer placement    |
| `Result<T, E>` that throws/aborts when an error is dropped unexamined        | Errors cannot be silently ignored even without exceptions enabled                              | Heap-allocated errors; destructor-driven control flow surprises; `VUK_USE_EXCEPTIONS` config split |
| Descriptor/pipeline/renderpass state via create-info hashmaps                | No descriptor lifecycle code for users; deduplication across passes for free                   | Hash + probe per draw on the default path; `bind_persistent` needed for bindless-class performance |

---

## Sources

- [martty/vuk — GitHub repository][repo] · [README][readme] · [`CMakeLists.txt`][cmake]
- [vuk documentation (readthedocs)][docs] · [`docs/index.rst`][index-rst] · [`docs/topics/rendergraph.rst`][rg-rst]
- [`include/vuk/IR.hpp` — IR nodes, structural types, `IMBUED_TY`][ir]
- [`include/vuk/Value.hpp` — `Value<T>` / `UntypedValue` futures][value]
- [`include/vuk/RenderGraph.hpp` — `make_pass`, `VUK_IA`/`VUK_BA`, `declare_*`/`acquire_*`, `Compiler`][rendergraph-hpp]
- [`include/vuk/Types.hpp` — `Access` enum, `Arg` carrier][types]
- [`include/vuk/SyncLowering.hpp` — `to_use`, access classification][synclowering] · [`include/vuk/ResourceUse.hpp`][resourceuse]
- [`include/vuk/SyncPoint.hpp` — `SyncPoint`/`Signal`][syncpoint]
- [`src/IRPasses.cpp` — SSA linking, inference, queue inference, partitioning, linearization][irpasses]
- [`src/runtime/vk/Backend.cpp` — barrier emission, QFOT derivation, `node_to_acq`][backend]
- [`src/runtime/vk/VkQueueExecutor.cpp` — timeline-semaphore executors][queueexec] · [`src/runtime/vk/DeviceVkResource.cpp`][devicevk] · [`src/runtime/vk/DeviceFrameResource.cpp`][framers]
- [`include/vuk/runtime/CommandBuffer.hpp` — binding model, error latch, `get_underlying()`][cmdbuf]
- [`include/vuk/Result.hpp`][result] · [`include/vuk/Exception.hpp`][exception] · [`src/GraphDumper.cpp`][dumper]
- [`include/vuk/runtime/vk/VkPFNRequired.hpp`][pfn-req] · [`VkPFNOptional.hpp`][pfn-opt] · [`VkRuntime.hpp`][vkruntime] · [`src/extra/init/SimpleInit.cpp`][simpleinit]
- [Themaister: Render graphs and Vulkan — a deep dive][maister]
- [Ipotrick/Daxa — README (TaskGraph precompilation quote)][daxa-readme]
- Related: [Daxa (C++)][daxa] · [Tephra (C++)][tephra] · [Vulkano (Rust)][vulkano] · [Vulkan-Hpp (C++)][vulkan-hpp] · [Synchronization validation][sync-validation] · [Comparison][comparison] · [Survey index][survey-index]

<!-- References -->

[repo]: https://github.com/martty/vuk
[readme]: https://github.com/martty/vuk/blob/master/README.md
[cmake]: https://github.com/martty/vuk/blob/master/CMakeLists.txt
[docs]: https://vuk.readthedocs.io/en/latest/
[index-rst]: https://github.com/martty/vuk/blob/master/docs/index.rst
[rg-rst]: https://github.com/martty/vuk/blob/master/docs/topics/rendergraph.rst
[ir]: https://github.com/martty/vuk/blob/master/include/vuk/IR.hpp
[value]: https://github.com/martty/vuk/blob/master/include/vuk/Value.hpp
[rendergraph-hpp]: https://github.com/martty/vuk/blob/master/include/vuk/RenderGraph.hpp
[types]: https://github.com/martty/vuk/blob/master/include/vuk/Types.hpp
[synclowering]: https://github.com/martty/vuk/blob/master/include/vuk/SyncLowering.hpp
[resourceuse]: https://github.com/martty/vuk/blob/master/include/vuk/ResourceUse.hpp
[syncpoint]: https://github.com/martty/vuk/blob/master/include/vuk/SyncPoint.hpp
[irpasses]: https://github.com/martty/vuk/blob/master/src/IRPasses.cpp
[backend]: https://github.com/martty/vuk/blob/master/src/runtime/vk/Backend.cpp
[queueexec]: https://github.com/martty/vuk/blob/master/src/runtime/vk/VkQueueExecutor.cpp
[devicevk]: https://github.com/martty/vuk/blob/master/src/runtime/vk/DeviceVkResource.cpp
[framers]: https://github.com/martty/vuk/blob/master/src/runtime/vk/DeviceFrameResource.cpp
[cmdbuf]: https://github.com/martty/vuk/blob/master/include/vuk/runtime/CommandBuffer.hpp
[result]: https://github.com/martty/vuk/blob/master/include/vuk/Result.hpp
[exception]: https://github.com/martty/vuk/blob/master/include/vuk/Exception.hpp
[dumper]: https://github.com/martty/vuk/blob/master/src/GraphDumper.cpp
[allocator]: https://github.com/martty/vuk/blob/master/include/vuk/runtime/vk/Allocator.hpp
[vkruntime]: https://github.com/martty/vuk/blob/master/include/vuk/runtime/vk/VkRuntime.hpp
[vkruntime-cpp]: https://github.com/martty/vuk/blob/master/src/runtime/vk/VkRuntime.cpp
[pfn-req]: https://github.com/martty/vuk/blob/master/include/vuk/runtime/vk/VkPFNRequired.hpp
[pfn-opt]: https://github.com/martty/vuk/blob/master/include/vuk/runtime/vk/VkPFNOptional.hpp
[config]: https://github.com/martty/vuk/blob/master/include/vuk/Config.hpp
[simpleinit]: https://github.com/martty/vuk/blob/master/src/extra/init/SimpleInit.cpp
[triangle]: https://github.com/martty/vuk/blob/master/examples/01_triangle.cpp
[maister]: https://themaister.net/blog/2017/08/15/render-graphs-and-vulkan-a-deep-dive/
[daxa-readme]: https://github.com/Ipotrick/Daxa/blob/master/README.md
[daxa]: ./cpp-daxa.md
[tephra]: ./cpp-tephra.md
[vulkano]: ./rust-vulkano.md
[vulkan-hpp]: ./cpp-vulkan-hpp.md
[sync-validation]: ./sync-validation.md
[comparison]: ./comparison.md
[survey-index]: ./index.md
