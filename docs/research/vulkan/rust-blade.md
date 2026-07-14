# blade (Rust)

A deliberately minimal, unsafe GPU abstraction by [wgpu][wgpu]'s original author, built _after_ writing
wgpu's per-resource usage tracker — and concluding that for his workloads the tracking was not worth its
cost: blade replaces per-resource barriers, image layout transitions, and lifetime tracking with one
catch-all global barrier between passes, every image permanently in `VK_IMAGE_LAYOUT_GENERAL`, and a
single timeline semaphore per queue.

| Field          | Value                                                                                                           |
| -------------- | --------------------------------------------------------------------------------------------------------------- |
| Language       | Rust (backends: Vulkan via [ash][ash], Metal, GLES; one selected per platform at compile time)                  |
| License        | MIT                                                                                                             |
| Repository     | [kvark/blade][repo]                                                                                             |
| Documentation  | [docs.rs/blade-graphics][docsrs] · [motivation.md][motivation] · [FAQ.md][faq] · [performance.md][perf]         |
| Category       | Render-graph / auto-sync layer (the in-category counterpoint: minimal tracking, no graph, no per-resource sync) |
| First release  | `blade-graphics 0.1.0` — January 26, 2023                                                                       |
| Latest release | `blade-graphics 0.8.4` — April 18, 2026                                                                         |

> [!NOTE]
> blade exists as a **counter-experiment to wgpu**, by the same primary author (Dzmitry Malyshau,
> kvark — wgpu's lead from its inception through 2021). Where [wgpu][wgpu] spends a measured
> [5–10 % of CPU time][wgpu] on validation, state tracking, and lifetime tracking, blade spends
> approximately zero — by declining to track anything per-resource and pushing correctness onto the
> driver, the [Khronos validation layers][sync-validation], and the user. Its production test was the
> [Zed][zed-blog] editor's Linux renderer from February 2024 until February 2026, when Zed replaced it
> with wgpu (see [Error handling & validation integration](#error-handling--validation-integration)).

---

## Overview

### What it solves

blade targets the gap its author saw between engines ("too high level"), raw APIs ("too verbose"),
and portability layers ("overly general"). The [motivation document][motivation] positions it
against the author's own prior work:

> _"**wgpu** provides the most thorough graphics abstraction in Rust ecosystem. … However, it is very
> restricted (by being a least common denominator of the platforms), fairly verbose … and has overhead
> (for safety and portability)."_ ([`blade-graphics/etc/motivation.md`][motivation])

and against `wgpu-hal`, which removes the overhead but keeps the ceremony:

> _"wgpu-hal expects resource states to be tracked by the user and changed (on a command encoder)
> explicitly."_ ([motivation.md][motivation])

blade's answer is to delete the state machine rather than automate or expose it. Three bookkeeping
domains that [vulkano][vulkano] tracks at runtime, [Daxa][daxa]/[vuk][vuk] compile from a graph, and
wgpu derives per command are simply **defined away**:

- **Resource states do not exist.** No per-resource access tracking, no [image layout
  transitions][concepts-layouts] (everything is `GENERAL`), no queue-family ownership transfers.
- **Descriptor sets do not exist** as a user concept. A plain Rust struct deriving `ShaderData` is
  pushed at draw/dispatch time; the Vulkan backend materializes a descriptor set on the fly via
  `VK_KHR_descriptor_update_template`.
- **Lifetime tracking does not exist.** Resources are `Copy` structs; `destroy_*` is explicit and
  immediate; keeping a resource alive until the GPU is done is the user's job, checked by nobody.

### Design philosophy

The [motivation document][motivation] states the inversion of wgpu's priorities outright:

> _"**safety**: wgpu places safety first and foremost. Self-sufficient, guarantees no UB. Blade is on
> the opposite - considers safety to be secondary. Expects users to rely on native API's validation
> and tooling."_ ([motivation.md][motivation])

and is equally direct about why per-resource barrier derivation was abandoned rather than improved:

> _"**barriers**: wgpu attempts to always use the optimal image layouts and can set reduced access
> flags on resources based on use. Placing the barriers optimally is a non-trivial task to solve, no
> universal solutions. Blade not only ignores this fight by making the user place the barrier, these
> barriers are only global, and there are no image layout changes - everything is GENERAL."_
> ([motivation.md][motivation])

The same document frames the whole project as _"a bit **experiment**. It may fail horribly, or it may
open up new ideas and perspectives"_, and the [FAQ][faq] answers "why invest in this when there is
wgpu?" with: _"Blade is an attempt to strike where `wgpu` can't reach, it makes a lot of the opposite
design solutions."_ The January 2023 [announcement talk][talk] compresses the sync story to three
lines: _"No per-object state. No image layout transitions. Global barriers between passes."_

---

## How it works

`blade-graphics` is the GPU abstraction (the subject of this page); above it sit `blade-render`
(a hardware-ray-tracing path tracer), `blade-egui`, `blade-asset`, and a small `blade-engine`. The
portable surface is defined as traits in [`blade-graphics/src/traits.rs`][traits-rs]
(`ResourceDevice`, `CommandDevice`, `TransferEncoder`, …) with exactly one backend compiled per
platform (`src/vulkan/`, `src/metal/`, `src/gles/`) — there is no runtime backend dispatch and no
generic parameter in user code. A frame is: create a `CommandEncoder`, open named passes, push data
structs, submit, and keep the returned `SyncPoint`:

```rust
// kvark/blade — examples follow this shape (see blade-graphics/README.md)
#[derive(blade_macros::ShaderData)]
struct Params {
    input: gpu::BufferPiece,
    output: gpu::TextureView,
}

encoder.start();
if let mut pass = encoder.compute("filter") {          // global barrier inserted here by default
    let mut pc = pass.with(&pipeline);                 // rebinds everything; pipeline-scoped
    pc.bind(0, &Params { input, output });             // descriptor set created on the fly
    pc.dispatch(groups);
}
let sync_point = context.submit(&mut encoder);         // bumps the queue's timeline semaphore
context.wait_for(&sync_point, timeout_ms);             // CPU-GPU sync
```

The Vulkan backend requires `VK_KHR_descriptor_update_template`, `VK_KHR_timeline_semaphore`, and
`VK_KHR_dynamic_rendering` ([`blade-graphics/README.md`][gfx-readme]) — _"the baseline Vulkan hardware
with a relatively fresh driver"_, with ray tracing (`AccelerationStructure` is a first-class resource
type in the portable API) available on the Vulkan backend only.

### Binding generation & API coverage

**blade generates nothing from `vk.xml`, and adds no metadata of its own.** The Vulkan backend is
hand-written over [ash][ash] (which supplies the generated raw API); the portable surface is a small
hand-designed trait set, so — exactly as with [Daxa][daxa] — no registry metadata (`externsync`,
success codes, structure-chain validity) survives to the user, because the Vulkan surface it would
annotate is hidden. Coverage is deliberately narrow: compute, raster (dynamic rendering only), ray
queries/acceleration structures, transfers, timestamp timings, and external memory import/export
([`Memory::External`][lib-rs] with Win32/fd/DMA-BUF sources). Deliberately absent, per
[motivation.md][motivation]: multisampling ("too expensive") and — for a long time — vertex buffers
("use storage buffers instead"; a `Vertex` derive was added later). Shaders are WGSL compiled through
[naga][naga], with bindings matched **by struct-field name** rather than by binding decorations — the
`ShaderData` derive and the shader module are reconciled at pipeline creation, a name-keyed cousin of
[Daxa][daxa]'s TaskHead single-artifact trick.

### Handle lifetime & ownership model

The [motivation document][motivation] is one line on this: _"**Object lifetime** is explicit, no
automatic tracking is done."_ Every resource type in [`traits.rs`][traits-rs] is constrained
`Send + Sync + Clone + Copy + Debug + Hash + PartialEq` — plain bit-copyable value handles, the
opposite pole from [vulkano][vulkano]'s `Arc`-everywhere and from wgpu-hal's `Clone`-only opaque
objects:

> _"**object copy**: wgpu-hal hides API objects so that they can only be `Clone`, and some of the
> backends use `Arc` and other heap-allocated backing for them. Blade keeps the API for resources to
> be are light as possible and allows them to be copied freely."_ ([motivation.md][motivation])

`destroy_buffer`/`destroy_texture`/… free immediately; there is **no deferred destruction, no zombie
list, no epoch tracking** ([deferred destruction][concepts-deferred] is simply absent — the user holds
`SyncPoint`s and schedules frees themselves). The one concession is `CommandEncoderDesc::buffer_count`
(how many command buffers the encoder rotates internally, e.g. 2 for one-recording-one-executing).
Memory is allocated automatically from a few profiles (`Memory::Device`/`Shared`/`Upload`) via
`gpu-alloc` — the user picks a profile, not a heap. Rust's ownership system is **not** used to enforce
any of this: a copied `Buffer` handle outliving its `destroy_buffer` call is a use-after-free the type
system never sees.

### Synchronization safety

blade's model has exactly three moving parts, all coarse:

- **Global barriers between passes.** Opening any pass (`encoder.compute(label)` / `.render(…)` /
  `.transfer(…)`) calls `begin_pass`, which by default emits one full-pipeline
  `vkCmdPipelineBarrier` with a single `VkMemoryBarrier` — `MEMORY_WRITE` →
  `MEMORY_READ | MEMORY_WRITE` across `ALL_COMMANDS` → `ALL_COMMANDS`
  ([`src/vulkan/command.rs`][vk-command], `fn barrier`). No resource is named; everything written
  before the pass is visible to everything after it. `CommandEncoderDesc::manual_barriers` opts out:
  _"When set, automatic memory barriers between passes are not inserted. The user is responsible for
  calling `barrier()` on the encoder where synchronization is needed."_
  ([`src/lib.rs`][lib-rs]) — so the sync the user ever writes is at most _placement_ of an opaque
  full barrier, never stages, access masks, or layouts. A compute pass additionally exposes a
  within-pass compute-to-compute `barrier()`.
- **No image layouts.** `init_texture` transitions `UNDEFINED` → `GENERAL` once at creation;
  presentation transitions `GENERAL` → `PRESENT_SRC_KHR`; nothing else ever changes layout
  ([`src/vulkan/command.rs`][vk-command]). [Daxa][daxa] reached the same all-`GENERAL` position in
  its release 3.3 (November 27, 2025) — nearly three years after blade shipped it — on the same
  modern-drivers-don't-care thesis.
- **One [timeline semaphore][concepts-timeline] per queue.** `submit` signals the queue's
  `timeline_semaphore` and returns a `SyncPoint { progress }` — a plain cloneable counter value;
  `wait_for(&sync_point, timeout_ms)` waits on it ([`src/vulkan/mod.rs`][vk-mod]). There are no
  user-visible fences, binary semaphores (swapchain acquire/present semaphores are managed
  internally), or events.

What is **given up** relative to [wgpu][wgpu]'s tracker is every per-resource guarantee: nothing
detects a read of a buffer the GPU is still writing in the _same_ pass, a destroy-while-in-flight, or
a missing barrier under `manual_barriers` — there is no [hazard][concepts-hazards] model at all, and
the [`externsync`][concepts-externsync] burden is handled only by Rust's ordinary `&mut` borrows on
the encoder plus an internal queue mutex. The compensating bet is stated in
[motivation.md][motivation]: _"**Resource states** do not exist. The API is built on an assumption
that the driver knows better how to track resource states, and so our API doesn't need to care about
this. The only command exposed is a catch-all barrier."_ The model is sound-by-overshoot between
passes (a full barrier is never _missing_ sync, only excess) — the GPU-side cost is serialized
passes: no compute/raster overlap across a barrier that a per-resource system would have permitted.

### Type-system techniques

blade uses Rust's type system for ergonomics and scoping, not for safety proofs:

- **Scoped pass/pipeline encoders** — `CommandEncoder` → pass encoder (`compute()`/`render()`/
  `transfer()`) → pipeline encoder (`.with(&pipeline)`), each holding a `&mut` borrow of its parent,
  so passes cannot interleave and commands cannot be recorded outside a pass — a borrow-checker-lite
  [typestate][concepts-typestate] without phantom types.
- **`ShaderData` derive macro** ([`blade-macros`][macros]) — a struct of `BufferPiece`/`TextureView`/
  `Sampler`/`AccelerationStructure`/plain-data fields becomes a `ShaderDataLayout` at compile time;
  binding is by field name against the naga-reflected WGSL module.
- **Const-generic bindless arrays** — `ResourceArray<T, const N>` with aliases `BufferArray<N>`,
  `TextureArray<N>`, `AccelerationStructureArray<N>` ([`src/lib.rs`][lib-rs]) give a fixed-capacity
  [bindless][concepts-bindless] table whose size is a type parameter.
- **Compile-time backend selection** — `cfg`-selected backend modules behind shared traits; no trait
  objects, no generics in user code, so the abstraction is resolved entirely at compile time.

Deliberately absent: no lifetimes tying handles to the `Context`, no phantom-typed sync scopes, no
linear/affine handle ownership ([linear types][concepts-linear] would contradict the `Copy`-handles
goal), no typed structure chains (the portable API has no `pNext`). The crate root says it plainly:
`clippy::missing_safety_doc` is allowed because _"This is the land of unsafe."_
([`src/lib.rs`][lib-rs])

### Overhead & escape hatches

The CPU overhead story is the inverse of wgpu's: **nothing is tracked, so nothing is paid per
command** — no usage-state CAS, no lifetime refcounts, no barrier derivation. What blade pays instead
is at the **bind and GPU level**: a descriptor set is created on the fly for every bind (_"Blade
considers it cheap enough to always create on the fly"_, [motivation.md][motivation]), a pipeline
switch rebinds everything (_"everything is re-bound on pipeline change"_ — defended in the [FAQ][faq]
by analogy to D3D12's actual behavior), and global barriers serialize passes on the GPU. The project
measures itself honestly in [performance.md][perf] with the ported wgpu `bunnymark` (_"the worst case
of the usage"_, every draw fully dynamic):

> _"Blade starts to slow down after about 23K bunnies … wgpu-hal starts at 60K bunnies … wgpu starts
> at 15K bunnies"_ (MacBook Pro 2016 / Metal; on a Ryzen 3500U via Vulkan: blade ≈18K, wgpu-hal ≈60K,
> wgpu ≈20K) ([performance.md][perf])

— i.e. worst-case blade lands **on par with full wgpu and well below wgpu-hal**, and the [FAQ][faq]
owns it: _"Short answer is - yes, it's unlikely going to be faster than wgpu-hal. Long answer is -
slow doesn't matter here"_ — above ~100 unique objects you should be instancing anyway, and blade's
target workloads (compute, ray tracing, AZDO-style rendering, a UI like Zed's) issue few, fat
commands. The same document counts ergonomics as the real win: the bunnymark example is _"335 LOC
versus 830 LOC of wgpu-hal"_.

The ultimate escape hatch is structural rather than an API: _"Blade expects to be vendored in and
modified according to the needs of a user"_ and _"Blade needs to be transparent, since it assumes
modifcation by the user"_ ([motivation.md][motivation]) — backend internals are reachable, raw
external memory can be imported/exported (`Memory::External`), and `manual_barriers` removes even the
automatic global barriers.

### Error handling & validation integration

Initialization is the only recoverable phase: `Context::init` is an `unsafe fn` returning
`Result<Self, NotSupportedError>` ([`src/vulkan/init.rs`][vk-init]); after that, _"Blade doesn't
expect any recovery"_ ([motivation.md][motivation]) — creation functions are infallible-or-panic, and
only `wait_for` surfaces a `DeviceError` (`DeviceLost`/`OutOfMemory`). In place of its own validation
layer, blade integrates the native tooling it tells users to rely on: `ContextDesc { validation: true }`
loads `VK_LAYER_KHRONOS_validation`, names every object via `VK_EXT_debug_utils`, labels passes for
capture tools, and — notably — arms a built-in **GPU crash handler**: when `VK_AMD_buffer_marker` is
available under validation, every pass writes a marker into a dedicated buffer and a failed submit is
decoded by `check_gpu_crash` into the name of the pass that hung the device
([`src/vulkan/mod.rs`][vk-mod], `CrashHandler`). Since all sync between passes is a full barrier,
[synchronization validation][sync-validation] has little to find in default-mode blade code — the
hazards it hunts are mostly _within_ a pass or under `manual_barriers`, where blade offers no help.

The production verdict on this safety posture is mixed. Zed adopted blade for its Linux port
(kvark's own [PR #7343][zed-pr-old], merged February 7, 2024; the [Zed blog][zed-blog] introduced it
as a _"lean low-level GPU abstraction focused at ergonomics and fun"_) and shipped on it for two
years — then removed it ([PR #46758][zed-pr], opened January 14, 2026, merged February 13, 2026),
citing NVIDIA freezes and Wayland-compositor crashes: _"The blade graphics library is a mess and
causes several issues for both Zed users as well as other 3rd party apps using GPUI"_ — replacing it
with wgpu, the abstraction blade was designed in reaction to.

---

## Strengths

- **The cleanest existing answer to "what if we just don't track?"** — a real, shipping system where
  per-resource sync, layouts, and lifetime tracking are absent by design, giving an empirical
  baseline for what that buys (≈zero CPU sync overhead, ~2.5× less user code than wgpu-hal) and costs.
- **Worst-case performance parity with wgpu at a fraction of the implementation** — bunnymark's
  fully-dynamic draws land where wgpu's tracked draws do ([performance.md][perf]), and blade's target
  workloads (compute/RT/batched draws) avoid that worst case entirely.
- **Sound-by-overshoot inter-pass sync** — the catch-all barrier can be wasteful but never wrong;
  whole bug classes (wrong stage masks, missed layout transitions) cannot be expressed.
- **All-`GENERAL` layouts pioneered in 2023** — independently validated when [Daxa][daxa] adopted the
  same model in late 2025.
- **First-class ray tracing and external memory** in a tiny portable API; `blade-render` demonstrates
  the RT-first intent end to end.
- **Honest self-assessment culture** — motivation/FAQ/performance docs state the trade-offs, the
  benchmark losses, and the experimental status in the project's own voice.

## Weaknesses

- **Safety is genuinely gone, not relocated**: use-after-destroy, in-pass hazards, and
  `manual_barriers` mistakes are silent UB; the only nets are the Khronos layers and the AMD
  buffer-marker crash decoder. Rust's `unsafe` shows up at `Context::init` and then largely
  disappears from signatures that can still cause UB.
- **GPU-side cost of global barriers is unmeasured** — passes serialize fully; workloads that need
  async-compute-style overlap have no path to it (no per-resource barriers, no multi-queue API).
- **Per-bind descriptor allocation and rebind-all-on-pipeline-change** put a ceiling (~18–23K dynamic
  draws) well under wgpu-hal's (~60K) ([performance.md][perf]); blade is the wrong tool past ~10K
  unique draws by its own [FAQ][faq].
- **Production reliability did not hold up at Zed scale** — driver/compositor interaction bugs
  (NVIDIA freezes, Smithay crashes) drove the one major adopter back to wgpu in February 2026
  ([PR #46758][zed-pr]).
- **"Vendor and modify" as the extension model** limits it as a dependency: the API is small, young
  (`0.x`), sparsely documented (≈38 % docs coverage on [docs.rs][docsrs]), and effectively
  single-author.
- No web/D3D12 story beyond a basic GLES path; requires fresh Vulkan drivers.

## Key design decisions and trade-offs

| Decision                                                               | Rationale                                                                                                     | Trade-off                                                                                      |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| No per-resource state; one catch-all global barrier between passes     | _"the driver knows better how to track resource states"_; optimal barrier placement has no universal solution | GPU passes fully serialize; no async overlap; in-pass hazards are invisible                    |
| All images permanently in `GENERAL` layout                             | Eliminates the largest sync-bug class and all transition bookkeeping                                          | Forfeits layout-specific compression/bandwidth wins on some hardware                           |
| Safety secondary; rely on native validation and tooling                | Zero tracking overhead; radically smaller implementation to maintain and vendor                               | UB is reachable from safe-looking code; adopters inherit driver-bug surface (Zed's experience) |
| Resources are bit-`Copy` value handles, destroyed explicitly           | _"as light as possible"_; no `Arc`/refcount/registry cost per handle                                          | Use-after-destroy unchecked; user must schedule frees against `SyncPoint`s themselves          |
| Descriptor sets created on the fly per bind; rebind on pipeline change | Removes layout/pool/caching machinery; matches D3D12's actual rebind semantics                                | ~3× lower max dynamic draw rate than wgpu-hal; unsuitable above ~10K unique draws              |
| One timeline semaphore per queue; `SyncPoint` = counter value          | CPU-GPU sync collapses to compare-and-wait; no fence pools                                                    | No fine-grained GPU-GPU dependencies; single-queue model                                       |
| WGSL + name-based binding via naga reflection                          | No binding decorations to keep in sync between shader and host struct                                         | Ties shaders to naga's WGSL dialect; renames break bindings at pipeline creation               |
| Vendored-in, transparent codebase over stable library API              | Users with niche needs patch the backend directly                                                             | Weak compatibility guarantees; ecosystem reuse (GPUI's plugin authors) suffered in practice    |

---

## Sources

- [kvark/blade — GitHub repository][repo] · [`blade-graphics/README.md`][gfx-readme]
- [`blade-graphics/etc/motivation.md` — goals, wgpu/wgpu-hal assumption-by-assumption comparison][motivation]
- [`blade-graphics/etc/FAQ.md` — "slow doesn't matter here", when not to use blade][faq]
- [`blade-graphics/etc/performance.md` — bunnymark numbers vs wgpu / wgpu-hal][perf]
- [`blade-graphics/src/lib.rs` — `manual_barriers`, `ResourceArray`, `ShaderData`, "land of unsafe"][lib-rs]
- [`blade-graphics/src/traits.rs` — `Copy` resource handles, `SyncPoint`/`wait_for` contract][traits-rs]
- [`blade-graphics/src/vulkan/command.rs` — global `VkMemoryBarrier`, `GENERAL` layout transitions][vk-command]
- [`blade-graphics/src/vulkan/mod.rs` — timeline-semaphore `SyncPoint`, `CrashHandler`][vk-mod]
- [`blade-graphics/src/vulkan/init.rs` — `unsafe fn init`, validation-layer wiring][vk-init]
- [Blade — kvark's announcement talk notes (Rust Graphics Meetup, January 2023)][talk]
- [docs.rs — blade-graphics API documentation][docsrs]
- [Zed blog — "Linux when?" (Blade adoption context, May 2024)][zed-blog] · [zed#7343 — "Linux port via Blade" (merged February 7, 2024)][zed-pr-old] · [zed#46758 — "Remove blade, reimplement linux renderer with wgpu" (merged February 13, 2026)][zed-pr]
- Related: [wgpu (Rust)][wgpu] · [ash (Rust)][ash] · [vulkano (Rust)][vulkano] · [Daxa (C++)][daxa] · [vuk (C++)][vuk] · [Sync validation][sync-validation] · [Concepts][concepts] · [Comparison][comparison] · [Survey index][index]

<!-- References -->

[repo]: https://github.com/kvark/blade
[gfx-readme]: https://github.com/kvark/blade/blob/ba0fb5a6f2b5462c3e5796f8ce06b3b3d580adac/blade-graphics/README.md
[motivation]: https://github.com/kvark/blade/blob/ba0fb5a6f2b5462c3e5796f8ce06b3b3d580adac/blade-graphics/etc/motivation.md
[faq]: https://github.com/kvark/blade/blob/ba0fb5a6f2b5462c3e5796f8ce06b3b3d580adac/blade-graphics/etc/FAQ.md
[perf]: https://github.com/kvark/blade/blob/ba0fb5a6f2b5462c3e5796f8ce06b3b3d580adac/blade-graphics/etc/performance.md
[lib-rs]: https://github.com/kvark/blade/blob/ba0fb5a6f2b5462c3e5796f8ce06b3b3d580adac/blade-graphics/src/lib.rs
[traits-rs]: https://github.com/kvark/blade/blob/ba0fb5a6f2b5462c3e5796f8ce06b3b3d580adac/blade-graphics/src/traits.rs
[vk-command]: https://github.com/kvark/blade/blob/ba0fb5a6f2b5462c3e5796f8ce06b3b3d580adac/blade-graphics/src/vulkan/command.rs
[vk-mod]: https://github.com/kvark/blade/blob/ba0fb5a6f2b5462c3e5796f8ce06b3b3d580adac/blade-graphics/src/vulkan/mod.rs
[vk-init]: https://github.com/kvark/blade/blob/ba0fb5a6f2b5462c3e5796f8ce06b3b3d580adac/blade-graphics/src/vulkan/init.rs
[macros]: https://github.com/kvark/blade/tree/ba0fb5a6f2b5462c3e5796f8ce06b3b3d580adac/blade-macros
[docsrs]: https://docs.rs/blade-graphics/latest/blade_graphics/
[talk]: https://hackmd.io/@kvark/blade
[naga]: https://github.com/gfx-rs/wgpu/tree/1f56415f14dfd8f64af0f2e1003dd30825015a5f/naga
[zed-blog]: https://zed.dev/blog/zed-decoded-linux-when
[zed-pr-old]: https://github.com/zed-industries/zed/pull/7343
[zed-pr]: https://github.com/zed-industries/zed/pull/46758
[wgpu]: ./rust-wgpu.md
[ash]: ./rust-ash.md
[vulkano]: ./rust-vulkano.md
[daxa]: ./cpp-daxa.md
[vuk]: ./cpp-vuk.md
[sync-validation]: ./sync-validation.md
[concepts]: ./concepts.md
[concepts-layouts]: ./concepts.md#image-layout-transitions
[concepts-timeline]: ./concepts.md#timeline-semaphores
[concepts-hazards]: ./concepts.md#hazards-rawwarwaw--syncvals-taxonomy
[concepts-externsync]: ./concepts.md#external-synchronization--externsync
[concepts-typestate]: ./concepts.md#typestate
[concepts-linear]: ./concepts.md#linear--affine-types
[concepts-bindless]: ./concepts.md#bindless-descriptors
[concepts-deferred]: ./concepts.md#deferred-destruction
[comparison]: ./comparison.md
[index]: ./index.md
