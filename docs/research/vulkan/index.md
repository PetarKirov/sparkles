# Vulkan Bindings & Wrappers

A breadth-first survey of state-of-the-art Vulkan bindings and wrapper layers across
eight languages — thin generated bindings, safety-first wrappers, and render-graph /
auto-sync layers — focused on zero/low-overhead abstractions and the type-system
techniques that make Vulkan safer without notable performance cost. The survey informs
a future `sparkles:vulkan` D library, which can draw on CTFE metaprogramming, `@safe`,
[DIP1000][dip1000] scoped lifetimes, and [Design by Introspection][dbi].

This survey answers five questions:

1. **Synchronization modeling** — how are barriers, semaphores, fences, timeline
   semaphores, and queue-family ownership handled: automated (render/task graph,
   auto-sync), type-checked, or manual-with-validation? Ground truth in
   [sync-validation][sync-validation]; the three camps and their representatives in
   the [taxonomy below](#by-synchronization-strategy) and [comparison § 1.4][comparison-1-4].
2. **Implicit vs explicit host synchronization** — how are externally-synchronized
   handles (`vk.xml`'s `externsync`, 402 attribute instances) distinguished — in types, docs,
   or not at all? See [sync-validation][sync-validation] and
   [concepts § External synchronization][concepts-externsync]; the per-system verdicts are
   summarized in [comparison § 1.2][comparison-1-2] (spoiler: universally discarded).
3. **Type-system techniques** — phantom/branded types, linear/affine ownership,
   lifetimes, builder typestate, comptime/CTFE codegen, typed `pNext` structure
   chains, capability/extension typing. Vocabulary in
   [concepts § Type-system techniques][concepts-types]; best-in-class per technique in
   [comparison § 1.5][comparison-1-5] and the [mechanism taxonomy](#by-type-system-mechanism).
4. **The overhead story** — what is compile-time-only vs runtime cost (locks, hash
   maps, ref-counts, per-resource state tracking), and what escape hatches back to
   raw handles exist? Measured numbers in [wgpu][wgpu], [vulkano][vulkano], and
   [blade][blade] (the zero-tracking counterpoint, with its own benchmark suite); the
   cost ladder in [comparison § 1.6][comparison-1-6] and the
   [overhead taxonomy](#by-overhead-class).
5. **Binding generation** — how are bindings generated from `vk.xml`, and which
   registry safety metadata (`externsync`, `structextends`, `successcodes`, `len`,
   `optional`) survives into the target type system? The metadata-survival table is
   in [comparison § 1.2][comparison-1-2]; the registry grammar in
   [sync-validation][sync-validation].

> [!NOTE]
> This is the master index for the Vulkan-bindings research tree. Each row links to a
> deep-dive that was written and fact-checked independently against the primary source
> tree; where this index summarizes a system, the deep-dive is the source of truth.
> Registry counts (402 `externsync` attributes, 7 `implicitexternsyncparams` blocks)
> were taken from [`vk.xml`][vkxml] on `main` as of June 11, 2026 — see
> [sync-validation][sync-validation].

**Last reviewed:** June 11, 2026

---

## Master Catalog

One row per surveyed subject. **Category** is the three-rung ladder developed in
[concepts § Architecture patterns][concepts-arch] (thin generated binding → safety-first
wrapper → render-graph / auto-sync layer); **Sync strategy** and **Overhead class**
are the axes re-cut in the [taxonomy](#taxonomy) below. Unmaintained and
research-artifact entries are marked — staleness is itself a survey finding.

| System                                 | Language    | Category                                  | Sync strategy                                                       | Overhead class                                                 | Link                                  |
| -------------------------------------- | ----------- | ----------------------------------------- | ------------------------------------------------------------------- | -------------------------------------------------------------- | ------------------------------------- |
| **Vulkan-Hpp** (incl. `vk::raii`)      | C++         | Thin / generated                          | None by design; manual + validation layers                          | Zero-cost core; opt-in paid tiers (`UniqueHandle`, `raii`)     | [cpp-vulkan-hpp.md][vulkan-hpp]       |
| **ash**                                | Rust        | Thin / generated                          | None — _"everything is **unsafe**"_                                 | Zero-cost (`#[inline]` over cached fn-pointer tables)          | [rust-ash.md][ash]                    |
| **vulkanalia**                         | Rust        | Thin / generated                          | None; validation layers expected                                    | Zero-cost (`repr(transparent)` builders)                       | [rust-vulkanalia.md][vulkanalia]      |
| **vulkan-zig**                         | Zig         | Thin / generated                          | None; `externsync` not even parsed                                  | Zero-cost above dynamic dispatch                               | [zig-vulkan-zig.md][vulkan-zig]       |
| **ErupteD** (+ D landscape) ⚠️ frozen  | D           | Thin / generated                          | None; default loading tier itself thread-unsafe (`__gshared`)       | Zero-cost (the binding _is_ the raw API)                       | [d-erupted.md][erupted]               |
| **vulkano**                            | Rust        | Safety-first wrapper                      | Per-resource auto-sync → declared-access task graph (in migration)  | Runtime tracking + always-on host validation                   | [rust-vulkano.md][vulkano]            |
| **vulkan** (Haskell)                   | Haskell     | Safety-first wrapper                      | Manual; `externsync` survives as Haddock prose only                 | Low-not-zero (chains erased; per-call marshalling)             | [haskell-vulkan.md][haskell]          |
| **Olivine** ⚠️ research artifact       | OCaml       | Safety-first wrapper                      | Manual; `externsync` dropped with a literal `(* TODO *)`            | Runtime FFI (ctypes/libffi); type machinery zero-cost          | [ocaml-olivine.md][olivine]           |
| **Silk.NET** (+ SharpVk ⚠️ abandoned)  | C#          | Thin + typed chains                       | Manual; `externsync` invisible in types and docs                    | Near-zero for managed (`calli` via cached VTable)              | [csharp-silknet.md][silknet]          |
| **LWJGL 3 / vulkan4j / jcoronado**     | Java        | Raw binding → safety-first wrapper        | Manual on all three; jcoronado mandates `synchronization2`          | JNI / Panama FFM downcalls (+ `MemorySegment` checks)          | [java-lwjgl-vulkan4j.md][java]        |
| **Daxa**                               | C++         | Render-graph / auto-sync                  | Compiled task graph (record once, execute many)                     | Amortized runtime tracking; bindless zero per-draw descriptors | [cpp-daxa.md][daxa]                   |
| **vuk**                                | C++20       | Render-graph / auto-sync                  | Per-submit IR compilation of per-argument `Access` declarations     | Per-submit graph build, amortized by partial evaluation        | [cpp-vuk.md][vuk]                     |
| **Tephra**                             | C++17       | Render-graph / auto-sync (non-reordering) | Two-tier: auto barriers for job commands; untracked lists + export  | Tracking paid only at job submit; recording near-raw           | [cpp-tephra.md][tephra]               |
| **wgpu**                               | Rust        | Render-graph / auto-sync (usage tracker)  | Full runtime usage tracking, eager per-command barrier derivation   | 5–10 % typical / ~2× worst CPU vs raw `hal`; lock contention   | [rust-wgpu.md][wgpu]                  |
| **Granite** ⚠️ personal engine         | C++         | Render-graph / auto-sync (reference impl) | Explicit mid-level backend; full automation only in `bake()`d graph | Amortized: `bake()` re-runs only on graph-topology change      | [cpp-granite.md][granite]             |
| **NVRHI**                              | C++17       | Render-graph / auto-sync (cross-API RHI)  | Runtime-tracked D3D12-style named states, per-resource opt-out      | Hash-map state lookup per use; removable per resource          | [cpp-nvrhi.md][nvrhi]                 |
| **blade**                              | Rust        | Render-graph / auto-sync (counterpoint)   | One catch-all global barrier between passes; all images `GENERAL`   | ≈Zero CPU tracking by construction; passes serialize on GPU    | [rust-blade.md][blade]                |
| **V-EZ** ⚠️ unmaintained (2018)        | C / C++11   | Render-graph / auto-sync (implicit)       | Fully implicit record-time hazard inference; no graph, no opt-out   | Per-command runtime: every command buffer recorded twice       | [cpp-vez.md][vez]                     |
| **Sync machinery & registry metadata** | C API + XML | Thematic (ground truth)                   | Defines it: `externsync` (host) machine-readable; device sync prose | Zero in production — all checking in optional debug layers     | [sync-validation.md][sync-validation] |

> [!WARNING]
> Maintenance markers, as verified in the deep-dives: **ErupteD** is frozen at
> `2.1.98+v1.3.248` (April 20, 2023, ~105 header revisions behind); **Olivine** was
> never released on opam (~85 % of its commits date to 2017; briefly revived
> July–August 2025); **SharpVk** — covered inside the [Silk.NET][silknet] dive as the
> failed idiomatic predecessor — last released 0.4.2 in January 2018; **V-EZ**'s last
> functional commit landed October 5, 2018, and issue #73 (February 18, 2020) records
> AMD granted no successor maintainership — historical interest only. **Granite** is a
> personal engine, not a packaged library — no versioned release has ever existed and
> its README disclaims support ("Pull requests will likely be ignored or dismissed."),
> though it is actively developed as of March 29, 2026. **NVRHI** ships no tags or
> releases (rolling `main`, last pushed June 10, 2026). **blade**'s flagship production
> deployment is past tense: the Zed editor adopted it in February 2024 and replaced it
> with wgpu in February 2026. Everything else in the catalog is actively maintained as
> of June 2026.

---

## Taxonomy

### By synchronization strategy

The survey's main architectural axis. The **typed** row is empty by finding, not by
omission — see [comparison § 1.4][comparison-1-4] for the full treatment and
[sync-validation][sync-validation] for the hazard taxonomy (RAW/WAR/WAW/WRW/RRW) and
the host-vs-device domain split that explains _why_ the camps look like this.

| Strategy                                 | Mechanism                                                                                                                                                                            | Systems                                                                                                                                                                                                                                                                                                                                             |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Manual (with validation layers)**      | Fences/semaphores/barriers exposed as inert values; correctness delegated to the developer + [`VK_LAYER_KHRONOS_validation`][sync-validation]                                        | [Vulkan-Hpp][vulkan-hpp], [ash][ash], [vulkanalia][vulkanalia], [vulkan-zig][vulkan-zig], [ErupteD][erupted], [Haskell][haskell], [Olivine][olivine], [Silk.NET][silknet], all three [Java][java] subjects                                                                                                                                          |
| **Runtime-tracked auto-sync (inferred)** | Per-resource state maps diffed per recorded command; barriers derived eagerly                                                                                                        | [vulkano][vulkano] (gen 2: `HashMap` + `RangeMap` per command buffer), [wgpu][wgpu] (per-subresource SOA state), [Tephra][tephra]'s job tier (per-queue access maps at submit), [NVRHI][nvrhi] (D3D12-style named states per command list, graded per-resource opt-out), [V-EZ][vez] ⚠️ (the historical maximum: per-command inference, no opt-out) |
| **Declarative graph (compiled)**         | Declared per-task/per-argument accesses compiled into batched `synchronization2` barriers + timeline semaphores                                                                      | [Daxa][daxa] (record once, replay), [vuk][vuk] (per-submit IR + partial evaluation), `vulkano-taskgraph` ([vulkano][vulkano], compile-once but currently `unsafe`/unvalidated), [Granite][granite] (the 2017 ancestor: `bake()`-derived barriers/aliasing/semaphores over an explicit backend)                                                      |
| **Global catch-all barrier (untracked)** | No per-resource state at all: one automatic `ALL_COMMANDS` memory barrier between passes, every image permanently in `GENERAL` layout                                                | [blade][blade] (opt-out via `manual_barriers`; sound-by-overshoot between passes, silent UB within them — the deliberate counterpoint to runtime tracking)                                                                                                                                                                                          |
| **Typed (compile-time-checked)**         | **Nobody.** No surveyed system promotes `externsync` or device happens-before into types — the survey's central negative finding and the cheapest differentiation open to a newcomer | — ([sync-validation][sync-validation], [comparison § 2.1][comparison-2-1])                                                                                                                                                                                                                                                                          |

The strongest single data point on this axis is **vulkano's own migration** from
inferred per-command tracking to a declared-access compiled DAG
(`vulkano-taskgraph`, February 2025) — inference was safe-but-slow, declaration is
fast-but-(currently)-unchecked ([vulkano][vulkano]).

### By overhead class

The cost ladder from [comparison § 1.6][comparison-1-6], with the survey's measured
numbers. Every tier ships sanctioned escape hatches back to raw handles — the
universal design contract.

| Overhead class                          | Cost character                                                                                                                                                                                                | Systems                                                                                                                                                             |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Zero-cost, structurally enforced**    | Layout parity `static_assert`-ed per type; `repr(transparent)`; one indirect call through a per-device function-pointer table; all type machinery compile-time-erased                                         | [Vulkan-Hpp][vulkan-hpp], [ash][ash], [vulkanalia][vulkanalia], [vulkan-zig][vulkan-zig], [ErupteD][erupted]                                                        |
| **Near-zero, managed runtime**          | `calli` via cached VTable ([Silk.NET][silknet]); Panama FFM at ~49.7 ns vs JNI ~56.6 ns per call ([Java][java]); per-call `ContT` marshalling ([Haskell][haskell]); libffi dynamic calls ([Olivine][olivine]) | Managed-language bindings                                                                                                                                           |
| **Runtime tracking, per command**       | Hash-map + range-map state per recorded command per frame ([vulkano][vulkano] gen 2); **5–10 % typical / ~2× worst** CPU vs raw `hal`, plus lock contention ([wgpu][wgpu])                                    | [vulkano][vulkano], [wgpu][wgpu], [NVRHI][nvrhi] (hash-map lookup per state-setting call), [V-EZ][vez] ⚠️ (encode-then-decode: every command buffer recorded twice) |
| **Runtime tracking, amortized**         | Graph analysis front-loaded at compile/`complete()` time; per-draw recording untracked — _"analyzing commands recorded into command lists would have unacceptable performance overhead"_ ([Tephra][tephra])   | [Daxa][daxa] (~2× faster record/execute in 3.5), [vuk][vuk], [Tephra][tephra], [Granite][granite] (`bake()` only on graph-topology change)                          |
| **≈Zero tracking, cost shifted to GPU** | No CPU sync/tracking by construction; global barriers fully serialize passes on the GPU — worst-case dynamic-draw throughput on par with full wgpu (bunnymark ~18–23K draws vs `wgpu-hal`'s ~60K)             | [blade][blade]                                                                                                                                                      |
| **Zero in production by construction**  | All checking lives in optional debug-only layers (thread-safety layer, syncval)                                                                                                                               | The Khronos validation architecture itself ([sync-validation][sync-validation])                                                                                     |

### By type-system mechanism

Best-in-class per technique; full per-mechanism analysis in
[comparison § 1.5][comparison-1-5], definitions in
[concepts § Type-system techniques][concepts-types].

| Mechanism                                                           | Best in class                                                                                                                                                                                                                  | Also notable                                                                                                                                                                                                                    |
| ------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Typed `pNext` chains**                                            | [Haskell][haskell] — type-level-list chains via closed/injective type families; output chains _inferred_                                                                                                                       | `StructureChain` + `StructExtends` ([Vulkan-Hpp][vulkan-hpp]); `Extends` traits ([ash][ash], [vulkanalia][vulkanalia]); `IExtendsChain<TChain>` constraints ([Silk.NET][silknet]); _abolished_ — flattened ([vulkano][vulkano]) |
| **Handle branding**                                                 | [Olivine][olivine] — generative functors mint a fresh abstract type per handle kind                                                                                                                                            | `repr(transparent)` newtypes ([ash][ash]); phantom-tagged `VkObjectHandle<T, VkObjectType>` ([Tephra][tephra]); `TypedImageViewId<VIEW_TYPE>` ([Daxa][daxa]); IDE-plugin-enforced int branding ([Java][java])                   |
| **Result typing**                                                   | [vulkan-zig][vulkan-zig] — per-command error sets, compiler-enforced via `try`                                                                                                                                                 | Exhaustive polymorphic variants ([Olivine][olivine]); success-code-preserving split ([vulkanalia][vulkanalia]); `std::expected` regime ([Vulkan-Hpp][vulkan-hpp])                                                               |
| **Host-memory lifetimes**                                           | [ash][ash] 0.38 — `'a` + `PhantomData` on structs, proven by a `trybuild` compile-fail test                                                                                                                                    | `Builder<'b>` with a lifetime-discarding `.build()` ([vulkanalia][vulkanalia]); `Arena` confinement ([Java][java])                                                                                                              |
| **Access-as-type**                                                  | [vuk][vuk] — `Access` as a non-type template parameter in the pass's function type (`Arg<T, Access, tag>`)                                                                                                                     | Runtime attachment declarations + `DAXA_DECL_TASK_HEAD` codegen ([Daxa][daxa])                                                                                                                                                  |
| **Capability / extension typing**                                   | [Olivine][olivine] — extensions as ML functors over a live `VkInstance`/`VkDevice` module                                                                                                                                      | Version/extension traits that panic at runtime if unloaded ([vulkanalia][vulkanalia]); per-tag extension classes ([Silk.NET][silknet])                                                                                          |
| **`sType` auto-initialization**                                     | [ErupteD][erupted] — D default field initializers on all 666 tagged structs, zero cost, unique to D                                                                                                                            | Builder/chain machinery elsewhere; registry `values` defaults ([vulkan-zig][vulkan-zig])                                                                                                                                        |
| **Comptime/CTFE codegen**                                           | [vulkan-zig][vulkan-zig] — build-time generator on the user's own `vk.xml` + `comptime` reflective templates                                                                                                                   | Offline committed generation everywhere else; D CTFE could collapse the two stages ([comparison § 2.2][comparison-2-2])                                                                                                         |
| **Named usage states (simplified barrier vocabulary)**              | [NVRHI][nvrhi] — `ResourceStates` enum-class bitflags are the _entire_ sync vocabulary, lowered to batched `vkCmdPipelineBarrier2`                                                                                             | The `ThsvsAccessType`/`vk-sync` pattern ([concepts § named usage states][concepts-named-states]); abolished entirely — no per-resource vocabulary at all ([blade][blade])                                                       |
| **Linear/affine ownership, builder typestate, typed image layouts** | **Nobody** — conspicuous absences; [Daxa][daxa] _abolished_ layouts rather than typing them; all four auto-sync newcomers ([Granite][granite], [NVRHI][nvrhi], [blade][blade], [V-EZ][vez]) document the absence as deliberate | — ([comparison § 1.5][comparison-1-5])                                                                                                                                                                                          |

---

## Milestones

Key capability landings across the field, in absolute dates. Entries marked `~` are
approximate (rolling-release projects or undated upstream events); all others are
verified in the linked deep-dives.

| Date              | Milestone                                                                                                                                                                                                                                                          |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| February 16, 2016 | **Vulkan 1.0** + the machine-readable [`vk.xml`][vkxml] registry ([sync-validation][sync-validation])                                                                                                                                                              |
| March 2016        | **vulkano** open-sourced — the oldest safe Vulkan wrapper ([vulkano][vulkano])                                                                                                                                                                                     |
| 2016              | **Vulkan-Hpp** developed at NVIDIA, adopted as the official Khronos C++ binding ([vulkan-hpp][vulkan-hpp]); Haskell **vulkan** `0.1.0.0` ([haskell][haskell]); **ErupteD** forked from `dvulkan` ([erupted][erupted]); **LWJGL 3.0.0** ships Vulkan ([java][java]) |
| December 9, 2016  | **ash** `0.1.0` ([ash][ash])                                                                                                                                                                                                                                       |
| May 2017          | **Olivine** created by Florian Angeletti — the survey's research-artifact pole ([olivine][olivine])                                                                                                                                                                |
| August 15, 2017   | **Granite's "Render graphs and Vulkan — a deep dive"** — the canonical public design document for automatic-sync render graphs (development started January 2017), intellectual ancestor of Daxa, vuk, and Tephra ([granite][granite])                             |
| January 2018      | **SharpVk** `0.4.2` — last release of the idiomatic exception-based C# wrapper; .NET converges on thin-and-fast instead ([silknet][silknet])                                                                                                                       |
| March 26, 2018    | **V-EZ announced** by AMD GPUOpen — the historical maximum of implicit sync (record-time inference of every barrier and layout transition); last functional commit October 5, 2018, declared unmaintained by issue #73 (February 18, 2020) ([vez][vez])            |
| ~2019             | **wgpu** `0.1` over `wgpu-core` (lineage from `gfx-rs`) ([wgpu][wgpu]); **Silk.NET** `v1.0.0-preview` (August 4, 2019) ([silknet][silknet])                                                                                                                        |
| April 2020        | **Synchronization validation (syncval) phase 1** ships in Vulkan SDK 1.2.135 ([sync-validation][sync-validation])                                                                                                                                                  |
| October 19, 2020  | **vulkanalia** `0.1.0`; **vulkan-zig** emerges the same year (~2020, rolling) ([vulkanalia][vulkanalia], [vulkan-zig][vulkan-zig])                                                                                                                                 |
| January 2, 2021   | **Silk.NET 2.0** — the SilkTouch `calli` source-generator rewrite ([silknet][silknet])                                                                                                                                                                             |
| ~early 2021       | **`VK_KHR_synchronization2`** published — per-barrier `(stage, access)` records, the substrate every later graph compiler targets ([sync-validation][sync-validation])                                                                                             |
| July 13, 2021     | **NVRHI open-sourced** by NVIDIA (with the Donut framework) — production auto-sync-by-default with a per-resource opt-out ladder, under the RTX SDK sample fleet ([nvrhi][nvrhi])                                                                                  |
| July 16, 2021     | **`gfx-hal` retired** — wgpu 0.9 is its last gfx-hal release; the successor `wgpu-hal` sits directly on ash, and the `rendy` frame-graph experiment built on gfx-hal is archived with it ([ash][ash], [wgpu][wgpu])                                                |
| January 25, 2022  | **Vulkan 1.3** — `synchronization2` promoted to core ([sync-validation][sync-validation])                                                                                                                                                                          |
| October 13, 2022  | **Daxa** `0.1.0` — compiled TaskGraph, bindless by default ([daxa][daxa])                                                                                                                                                                                          |
| January 26, 2023  | **blade-graphics** `0.1.0` — wgpu's original author deletes the tracker: one global barrier, all images `GENERAL` (~3 years before Daxa 3.3 adopted the same layout model, November 2025) ([blade][blade])                                                         |
| April 20, 2023    | **ErupteD** final release `2.1.98+v1.3.248` — the D ecosystem freezes at header 1.3.248 ([erupted][erupted])                                                                                                                                                       |
| July 15, 2023     | **Tephra** `v0.1.0` — the two-tier job/command-list split ([tephra][tephra])                                                                                                                                                                                       |
| January 2024      | **wgpu v0.19 "arcanization"** — all resources behind `Arc`, 45 % frame-time win for Bevy's parallel encoding ([wgpu][wgpu])                                                                                                                                        |
| April 1, 2024     | **ash 0.38** — builders deleted; lifetimes moved onto generated structs ([ash][ash])                                                                                                                                                                               |
| February 7, 2025  | **vulkano 0.35 + `vulkano-taskgraph`** — the flagship of inferred auto-sync migrates to declared-access graph compilation ([vulkano][vulkano])                                                                                                                     |
| May 7, 2025       | **`externsync="maybe:<path>"`** conditional member-path form added to the `vk.xml` schema ([sync-validation][sync-validation])                                                                                                                                     |
| December 23, 2025 | **vuk** `v0.7` — the compiler-IR rewrite line (`Value<T>`/`make_pass`) ([vuk][vuk])                                                                                                                                                                                |
| February 5, 2026  | **Daxa 3.5** backend rewrite — ~2× faster TaskGraph record/execute ([daxa][daxa])                                                                                                                                                                                  |
| May 17, 2026      | **Vulkan-Hpp `v1.4.352`** — weekly releases still tracking spec patches 1:1; **wgpu `v29.0.3`** the same month ([vulkan-hpp][vulkan-hpp], [wgpu][wgpu])                                                                                                            |
| June 11, 2026     | Survey ground truth: `vk.xml` on `main` carries 402 `externsync` attributes and 7 `implicitexternsyncparams` blocks ([sync-validation][sync-validation])                                                                                                           |

---

## Quick Navigation

### Suggested reading paths

- **"I want the vocabulary first."** [concepts][concepts] →
  [sync-validation][sync-validation] → one deep-dive per category
  ([ash][ash], [vulkano][vulkano], [Daxa][daxa]).
- **"I want the synchronization story."** [sync-validation][sync-validation] →
  [Granite][granite] (the 2017 origin of the declarative graph, over an explicit
  backend) → [vulkano][vulkano] (the inferred→declared migration) → [Daxa][daxa] vs
  [vuk][vuk] (record-once vs per-submit graph compilation) → [wgpu][wgpu] (the
  measured cost of runtime tracking) → [NVRHI][nvrhi] (production opt-out ladder) →
  [comparison § 1.4][comparison-1-4].
- **"I want the boundaries of automation."** [V-EZ][vez] (total per-command inference
  — failed within six months) → [blade][blade] (zero tracking — sound between passes,
  unchecked within them) → [Granite][granite] and [Tephra][tephra] (why both rejected
  per-call tracking) → [comparison § 2.3][comparison-2-3] (where the survey draws the
  automation boundary the two extremes bound).
- **"I want the type-system techniques."** [concepts § Type-system techniques][concepts-types] →
  [Haskell][haskell] (maximal chains) → [Olivine][olivine] (branding, variants,
  functors) → [vulkan-zig][vulkan-zig] (error sets, `comptime`) →
  [comparison § 1.5][comparison-1-5].
- **"I want the generation pipeline."** [sync-validation][sync-validation] (what the
  registry encodes) → [Vulkan-Hpp][vulkan-hpp] and [ash][ash] (offline committed) →
  [vulkan-zig][vulkan-zig] (consumer-build-time) → [vulkanalia][vulkanalia]
  (nightly-cron, best `pNext` typing among thin bindings) →
  [comparison § 1.2][comparison-1-2] (the metadata-survival table).
- **"I'm designing `sparkles:vulkan`."** [d-erupted][erupted] (the D baseline and its
  unique `sType`-default win) → [sync-validation][sync-validation] (the unused
  `externsync` contract a D binding could consume) → the boundaries-of-automation
  evidence ([V-EZ][vez] and [blade][blade] as the failed/deliberate extremes;
  [comparison § 2.3][comparison-2-3]) → [comparison][comparison] Part 2
  (consensus + trade-off axes) → **[comparison Part 3 — the `sparkles:vulkan` delta
  table][comparison-part-3]** (every capability mapped to a D mechanism).

### Concepts & synthesis

- **[Shared Concepts][concepts]** — the two synchronization domains, the device-side
  primitive set, architecture patterns, type-system techniques, binding generation,
  and the concept → system matrix.
- **[Sync machinery & registry metadata][sync-validation]** — the ground truth: the
  `externsync` grammar, `synchronization2`, syncval's hazard taxonomy, and the
  proposed `externsync` → `ref`/`scope` mapping.
- **[Comparison][comparison]** — the capstone: head-to-head matrix along the
  six-dimension spine, consensus standard, trade-off axes, and the
  `sparkles:vulkan` delta table.

### Library deep-dives

| System                                 | One-line                                                                                                                              |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| [Vulkan-Hpp][vulkan-hpp]               | Khronos's official C++ binding: zero-cost layout-asserted wrappers, `StructureChain`, four coexisting ownership models.               |
| [ash][ash]                             | Rust's raw substrate (under vulkano _and_ wgpu): _"No validation, everything is unsafe"_ — and 1,217 typed `Extends` impls.           |
| [vulkanalia][vulkanalia]               | Nightly-regenerated Rust binding with the best `pNext` typing among thin bindings (input _and_ output chains).                        |
| [vulkan-zig][vulkan-zig]               | Build-time generator on the user's own `vk.xml`; per-command Zig error sets; `comptime` instead of codegen stage two.                 |
| [ErupteD & the D landscape][erupted]   | Frozen 2023 D binding; its `sType` default initializers are the survey's unique zero-cost win; the gap `sparkles:vulkan` fills.       |
| [vulkano][vulkano]                     | The decade-long auto-sync experiment and its migration to a declared-access task graph.                                               |
| [vulkan (Haskell)][haskell]            | Maximal structural typing: type-level-list `pNext` chains with inferred output chains; bracket-style lifetimes.                       |
| [Olivine][olivine]                     | OCaml research artifact: generative-functor branding, exhaustive variant results, extension functors.                                 |
| [Silk.NET][silknet]                    | .NET standard: `calli` VTable dispatch + generic-constraint `pNext` chains; SharpVk's failure as context.                             |
| [LWJGL 3 / vulkan4j / jcoronado][java] | The JVM spectrum: JNI flyweights, Panama FFM records + `Arena` scoping, and an `AutoCloseable` wrapper.                               |
| [Daxa][daxa]                           | Hand-authored replacement API: compiled TaskGraph, bindless by default, generational IDs + zombie lists.                              |
| [vuk][vuk]                             | Lazy `Value<T>` futures over a graph-compiler IR; `Access` in the pass's _type_; per-submit compilation with partial evaluation.      |
| [Tephra][tephra]                       | Two-tier driver-style auto-sync: tracked job commands above untracked command lists, bridged by explicit exports.                     |
| [wgpu][wgpu]                           | Production runtime usage tracking (Firefox, Bevy) with the survey's best-grounded overhead numbers — and almost no user-facing types. |
| [Granite][granite]                     | The 2017 ancestor: explicit mid-level backend under a `bake()`-compiled render graph — a personal engine, not a packaged library.     |
| [NVRHI][nvrhi]                         | NVIDIA's cross-API RHI: D3D12-style named-state auto-tracking per command list with a graded per-resource opt-out ladder.             |
| [blade][blade]                         | wgpu's author deletes the tracker: one global barrier, all images `GENERAL`, ≈zero CPU cost — and silent UB where tracking would be.  |
| [V-EZ][vez]                            | AMD's 2018 fully-implicit "easy mode": the failed maximum of per-command sync inference, dead within six months of open-sourcing.     |

---

## Sources

Each deep-dive carries its own primary-source citations; the authoritative artifacts
behind this index's classifications are:

- **The registry and spec** — [`xml/vk.xml`][vkxml] (counts from `main`, June 11,
  2026), the spec's [Threading Behavior chapter][spec-threading], and the
  [Vulkan-ValidationLayers][vvl] tree — all worked through in
  [sync-validation][sync-validation].
- **The category taxonomy and shared vocabulary** — [concepts][concepts], grounded in
  the per-system deep-dives.
- **Per-system sources** — repository trees, official docs, release notes, and design
  discussions cited in each linked deep-dive ([Vulkan-Hpp][vulkan-hpp], [ash][ash],
  [vulkanalia][vulkanalia], [vulkan-zig][vulkan-zig], [ErupteD][erupted],
  [vulkano][vulkano], [Haskell][haskell], [Olivine][olivine], [Silk.NET][silknet],
  [Java][java], [Daxa][daxa], [vuk][vuk], [Tephra][tephra], [wgpu][wgpu],
  [Granite][granite], [NVRHI][nvrhi], [blade][blade], [V-EZ][vez]).
- **Measured overhead numbers** — wgpu discussion #2080 (5–10 % typical / ~2× worst)
  and #5525 (lock contention), Daxa release notes (3.1/3.3/3.5), blade's bunnymark
  suite (~18–23K draws vs `wgpu-hal`'s ~60K), and the JVM FFI benchmarks, each cited
  in the respective deep-dive ([wgpu][wgpu], [daxa][daxa], [blade][blade],
  [java][java]).

<!-- References -->

<!-- Concept & synthesis docs (siblings) -->

[concepts]: ./concepts.md
[concepts-externsync]: ./concepts.md#external-synchronization--externsync
[concepts-types]: ./concepts.md#type-system-techniques
[concepts-arch]: ./concepts.md#architecture-patterns
[concepts-named-states]: ./concepts.md#simplified-barrier-vocabulary-named-usage-states
[comparison]: ./comparison.md
[comparison-1-2]: ./comparison.md#12-binding-generation--api-coverage
[comparison-1-4]: ./comparison.md#14-synchronization-safety
[comparison-1-5]: ./comparison.md#15-type-system-techniques
[comparison-1-6]: ./comparison.md#16-overhead--escape-hatches
[comparison-2-1]: ./comparison.md#21-the-consensus-standard
[comparison-2-2]: ./comparison.md#22-the-architectural-trade-off-axes
[comparison-2-3]: ./comparison.md#23-the-boundaries-of-automation
[comparison-part-3]: ./comparison.md#part-3--the-sparklesvulkan-delta-table
[sync-validation]: ./sync-validation.md

<!-- Library deep-dives (siblings) -->

[vulkan-hpp]: ./cpp-vulkan-hpp.md
[ash]: ./rust-ash.md
[vulkanalia]: ./rust-vulkanalia.md
[vulkan-zig]: ./zig-vulkan-zig.md
[erupted]: ./d-erupted.md
[vulkano]: ./rust-vulkano.md
[haskell]: ./haskell-vulkan.md
[olivine]: ./ocaml-olivine.md
[silknet]: ./csharp-silknet.md
[java]: ./java-lwjgl-vulkan4j.md
[daxa]: ./cpp-daxa.md
[vuk]: ./cpp-vuk.md
[tephra]: ./cpp-tephra.md
[wgpu]: ./rust-wgpu.md
[granite]: ./cpp-granite.md
[nvrhi]: ./cpp-nvrhi.md
[blade]: ./rust-blade.md
[vez]: ./cpp-vez.md

<!-- Repo guidelines -->

[dbi]: ../../guidelines/design-by-introspection-01-guidelines.md

<!-- External -->

[dip1000]: https://dlang.org/spec/function.html#scope-parameters
[vkxml]: https://github.com/KhronosGroup/Vulkan-Docs/blob/7f61271fa6b6e7d71bf56dbc3a6165cda43bd8cb/xml/vk.xml
[spec-threading]: https://registry.khronos.org/vulkan/specs/latest/html/vkspec.html#fundamentals-threadingbehavior
[vvl]: https://github.com/KhronosGroup/Vulkan-ValidationLayers
