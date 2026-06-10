# Cross-Binding Synthesis & the `sparkles:vulkan` Delta

The capstone of the Vulkan-bindings survey. Part 1 distils the fourteen library
deep-dives and the [synchronization & registry-metadata ground truth][sync-validation]
into a head-to-head comparison along the tree's six-dimension analysis spine —
generation, lifetime, synchronization, type techniques, overhead, errors. Part 2 names
the consensus architecture and the real trade-off axes, with the measured overhead
numbers the [wgpu][wgpu]/[vulkano][vulkano]/[Daxa][daxa] dives surfaced. Part 3 is the
delta table: what each surveyed safety capability would look like built with D's CTFE
metaprogramming, `@safe` + [DIP1000][dip1000] scoped lifetimes, and
[Design by Introspection][dbi] in a future `sparkles:vulkan`.

**Last reviewed:** June 11, 2026

> [!NOTE]
> This is the _synthesis_ leaf of the survey. It assumes the shared vocabulary
> ([concepts][concepts]) and the registry/validation ground truth
> ([sync-validation][sync-validation]) as given and cross-links rather than re-derives
> them. For the breadth-first map and reading paths see [the index][index].

---

## Part 1 — The field, compared

### 1.1 The subjects at a glance

| Subject                            | Language    | Category                 | Sync strategy                                                         | Overhead class                                                 | Type-system mechanisms                                                                          | Link                         |
| ---------------------------------- | ----------- | ------------------------ | --------------------------------------------------------------------- | -------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- | ---------------------------- |
| Vulkan-Hpp (incl. `vk::raii`)      | C++         | Thin / generated         | None by design; manual + validation layers                            | Zero-cost core; opt-in paid tiers (`UniqueHandle`, `raii`)     | `StructureChain` + `StructExtends`, strong handles, scoped enums, `ArrayProxy`                  | [deep-dive][vulkan-hpp]      |
| ash                                | Rust        | Thin / generated         | None — _"everything is **unsafe**"_                                   | Zero-cost (`#[inline]` over cached fn-pointer tables)          | `repr(transparent)` newtypes, struct lifetimes, `Extends` `pNext` traits                        | [deep-dive][ash]             |
| vulkanalia                         | Rust        | Thin / generated         | None; validation layers expected                                      | Zero-cost (`repr(transparent)` builders)                       | Lifetime builders, `Extends*` + output-chain traits, success/error result split                 | [deep-dive][vulkanalia]      |
| vulkan-zig                         | Zig         | Thin / generated         | None; `externsync` not even parsed                                    | Zero-cost above dynamic dispatch                               | Per-command error sets, non-exhaustive-enum handles, packed-struct flags, `comptime` loader     | [deep-dive][vulkan-zig]      |
| ErupteD (+ D landscape)            | D           | Thin / generated         | None; default loading tier itself thread-unsafe                       | Zero-cost (the binding _is_ the raw API)                       | Mixin-branded handles, **default-initialized `sType`** (unique), platform mixin templates       | [deep-dive][erupted]         |
| vulkano                            | Rust        | Safety-first wrapper     | Auto-sync (per-resource tracking) → declared-access task graph        | Runtime tracking + always-on host validation                   | Phantom `Id<T>`, `GpuFuture` chains, `Subbuffer<T>`, flattened `pNext`                          | [deep-dive][vulkano]         |
| vulkan                             | Haskell     | Safety-first wrapper     | None; `externsync` survives as Haddock prose only                     | Low-not-zero (chains erased; per-call marshalling)             | Type-level-list chains, closed/injective type families, bracket pairs, `Zero` class             | [deep-dive][haskell]         |
| Olivine                            | OCaml       | Safety-first wrapper     | None; `externsync` dropped with a literal `(* TODO *)`                | Runtime FFI (ctypes/libffi); type machinery zero-cost          | Generative-functor branding, phantom bitsets, polymorphic-variant results, extension functors   | [deep-dive][olivine]         |
| Silk.NET (+ SharpVk context)       | C#          | Thin + typed chains      | None; `externsync` invisible in types and docs                        | Near-zero for managed (`calli` via cached VTable)              | `IChainStart`/`IExtendsChain<TChain>` generic-constraint chains, blittable handle structs       | [deep-dive][silknet]         |
| LWJGL 3 / vulkan4j / jcoronado     | Java        | Thin → safety-first      | None on all three; jcoronado mandates `synchronization2`              | JNI / Panama FFM downcalls (+ segment checks)                  | Record-per-handle over `MemorySegment`, `Arena` host-memory scoping, IDE-enforced enum branding | [deep-dive][java]            |
| Daxa                               | C++         | Render-graph / auto-sync | Compiled task graph (record once, execute many) + timeline semaphores | Amortized runtime tracking; bindless zero per-draw descriptors | Generational IDs, `TypedImageViewId<VIEW_TYPE>`, virtual task resources                         | [deep-dive][daxa]            |
| vuk                                | C++20       | Render-graph / auto-sync | Per-submit IR compilation of per-argument `Access` declarations       | Per-submit graph build, amortized by partial evaluation        | `Value<T>` lazy futures, `Access` as non-type template parameter, `Result<T,E>` error latch     | [deep-dive][vuk]             |
| Tephra                             | C++17       | Render-graph / auto-sync | Two-tier: auto barriers for job commands; untracked lists + `export`  | Tracking paid only at job submit; recording near-raw           | Phantom-tagged handles, `EnumBitMask`, `VkStructureMap` chains, documented lifetime classes     | [deep-dive][tephra]          |
| wgpu                               | Rust        | Render-graph / auto-sync | Full runtime usage tracking, eager per-command barrier derivation     | 5–10 % typical / ~2× worst CPU vs raw `hal`; lock contention   | Deliberately almost none user-facing (`Arc` handles, all `Send + Sync`)                         | [deep-dive][wgpu]            |
| Sync machinery & registry metadata | C API + XML | Thematic (ground truth)  | Defines it: `externsync` (host) machine-readable; device sync prose   | Zero in production — all checking in optional layers           | Registry attributes as latent type metadata                                                     | [deep-dive][sync-validation] |

Two structural observations frame everything below:

1. **The categories are a ladder, not alternatives.** Every render-graph layer sits on a
   thin binding or raw headers ([vulkano][vulkano] and [wgpu][wgpu] on [ash][ash];
   [Daxa][daxa]/[vuk][vuk]/[Tephra][tephra] on hand-curated `vulkan.h` pointer tables),
   and every thin binding's implicit safety story is "run the
   [validation layers][sync-validation]". No subject does type-level _and_ graph-level
   safety at once.
2. **The registry's safety metadata almost entirely fails to survive generation** — the
   survey's central negative finding, quantified in [§1.2](#12-binding-generation--api-coverage).

---

### 1.2 Binding generation & API coverage

Three generation strategies partition the field:

| Strategy                               | Subjects                                                                                                                                                                | Freshness mechanism                                                                                                                                                                                                                                                                                        |
| -------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Generated from `vk.xml`, committed** | [Vulkan-Hpp][vulkan-hpp], [ash][ash], [vulkanalia][vulkanalia], [ErupteD][erupted], [Silk.NET][silknet], [LWJGL/vulkan4j][java], [Haskell][haskell], [Olivine][olivine] | Weekly automated releases tracking spec patches (Vulkan-Hpp, `v1.4.352` on May 17, 2026); a nightly cron (`0 21 * * *`) that regenerates and opens a PR ([vulkanalia's `update.yml`][vulkanalia]); or nothing — frozen at header 1.3.248 ([ErupteD][erupted], April 2023) and 1.2.162 ([Olivine][olivine]) |
| **Generated at the consumer's build**  | [vulkan-zig][vulkan-zig]                                                                                                                                                | The generator is a build-time executable run on the _user's own_ `vk.xml` via `b.addRunArtifact`, so bindings can never drift from the shipped headers                                                                                                                                                     |
| **Hand-written, no `vk.xml` at all**   | [vulkano][vulkano]'s safe layer, [wgpu][wgpu], [Daxa][daxa], [vuk][vuk], [Tephra][tephra]                                                                               | Hand-curated API surface ([vuk][vuk]: X-macro PFN tables of 101 required + 19 optional entry points); coverage follows the library's features, not the registry                                                                                                                                            |

The pattern in the third row is itself a finding: **every layer that automates
synchronization abandons registry generation.** [vulkano][vulkano] is the partial
exception — its `autogen` consumes `vk.xml` for enumerable data (errors, formats,
features, extension dependencies) while the safe semantics are hand-written.

What survives of the registry's safety metadata (full attribute definitions in
[sync-validation][sync-validation]):

| `vk.xml` metadata                     | Survival rate across the survey                                                                                                                                                                                                                                                                                                                                                                                      |
| ------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `successcodes` / `errorcodes`         | **Best-surviving.** Per-command Zig error sets ([vulkan-zig][vulkan-zig]), narrowed polymorphic-variant results ([Olivine][olivine]), the `VkResult`/`VkSuccessResult` split ([vulkanalia][vulkanalia]), typed exception hierarchy / `std::expected` ([Vulkan-Hpp][vulkan-hpp])                                                                                                                                      |
| `structextends` (`pNext`)             | **Survives well.** 1,213 `StructExtends` specializations ([Vulkan-Hpp][vulkan-hpp]), 1,217 `unsafe impl Extends` ([ash][ash]), `Extends*` + output-chain traits ([vulkanalia][vulkanalia]), `IExtendsChain<TChain>` constraints ([Silk.NET][silknet]), closed type families ([Haskell][haskell])                                                                                                                     |
| `len` / `optional`                    | **Sometimes.** Slices with debug asserts ([vulkan-zig][vulkan-zig]), `ArrayProxy` ([Vulkan-Hpp][vulkan-hpp]), labelled optional arguments ([Olivine][olivine]), inert `[Count]`/`[Flow]` attributes ([Silk.NET][silknet])                                                                                                                                                                                            |
| `externsync` (402 instances)          | **Universally discarded.** Parsed then never rendered ([Vulkan-Hpp][vulkan-hpp]'s generator validates it and emits nothing); absent from extraction ([ash][ash], [vulkanalia][vulkanalia]); not even parsed ([vulkan-zig][vulkan-zig]); dropped with `(* TODO *)` ([Olivine][olivine]). Sole partial survivor: [Haskell][haskell] embeds the spec's host-sync prose in generated Haddocks — documentation, not types |
| `implicitexternsyncparams` (7 blocks) | **Nobody.** Free-text AsciiDoc; only the Khronos thread-safety layer hand-curates it                                                                                                                                                                                                                                                                                                                                 |
| Handle `parent` attribute             | Destructor plumbing only; [vulkan-zig][vulkan-zig] parses it and renders nothing                                                                                                                                                                                                                                                                                                                                     |

The asymmetry is stark and deliberate-looking: bindings consume exactly the metadata
that improves _ergonomics_ (chains, results, lengths) and drop exactly the metadata
that encodes _thread-safety obligations_. As [sync-validation][sync-validation] shows,
`externsync` is definitionally complete — the spec's own host-sync tables are generated
from it — so this is a missed opportunity, not missing data.

---

### 1.3 Handle lifetime & ownership model

No surveyed system achieves compile-time temporal safety for **device objects**. The
spectrum of what exists:

| Model                                | Subjects                                                                                                                                                                                                                                                                                               | Temporal-safety property                                                                                                                 |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------- |
| **Bare `Copy` handles**              | [ash][ash], [vulkanalia][vulkanalia], [vulkan-zig][vulkan-zig], [ErupteD][erupted], [Silk.NET][silknet], LWJGL non-dispatchables ([Java][java])                                                                                                                                                        | None: use-after-destroy and double-destroy compile silently                                                                              |
| **Opt-in RAII tiers**                | [Vulkan-Hpp][vulkan-hpp] (plain / `UniqueHandle` / `SharedHandle` / `vk::raii` — four coexisting models), bracket pairs (`withInstance`) in [Haskell][haskell], `AutoCloseable` in jcoronado ([Java][java])                                                                                            | Deterministic destruction, but nothing prevents use of a stale handle — [Vulkan-Hpp][vulkan-hpp]'s `raii` still admits use-after-destroy |
| **Host-memory lifetimes only**       | [ash][ash]/[vulkanalia][vulkanalia] struct/builder lifetimes (`'a` + `PhantomData`, proven by an in-tree `trybuild` compile-fail test); `Arena` confinement in vulkan4j ([Java][java]) — dangling segment access throws `IllegalStateException`                                                        | Compile-time (Rust) / runtime-checked (Java) safety for _CPU-side struct memory_, none for the GPU objects it describes                  |
| **Refcounts + deferred destruction** | `Arc` everywhere + queues owning in-flight resources ([vulkano][vulkano]); all resources behind `Arc` post-arcanization ([wgpu][wgpu])                                                                                                                                                                 | Runtime-guaranteed liveness, paid in atomic traffic and (wgpu) lock contention                                                           |
| **Generational IDs + zombie lists**  | [Daxa][daxa] — index+version bitfields, _"a zombie lives until the gpu catches up to the point of zombification"_; slot map + deferred reclamation in `vulkano-taskgraph` ([vulkano][vulkano]); job-ID/timeline-keyed destruction ([Tephra][tephra]); frame-ring allocators + `Unique<T>` ([vuk][vuk]) | Stale IDs detectable (version mismatch) on the host; GPU-side stale bindless IDs remain unchecked                                        |

Two anti-lessons stand out. First, [wgpu][wgpu] _removed_ its `RenderPass` lifetime
parameter (made it `'static`) because composing lifetimes with `Arc`-everywhere
internals proved unworkable — typed designs must commit early. Second,
[ErupteD][erupted]'s default loading tier stores commands in `__gshared` module-level
function pointers, so the "binding" itself is a multi-device hazard — lifetime safety
starts at the dispatch table, not the resource.

---

### 1.4 Synchronization safety

The field splits into exactly three camps, and the boundary is the survey's main
architectural axis (hazard taxonomy and the host/device domain split in
[sync-validation][sync-validation]):

| Camp                       | Subjects                                                                                                        | Mechanism                                                                                                                                                                                                                                                      |
| -------------------------- | --------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **None by design**         | All thin bindings; [Haskell][haskell], [Olivine][olivine], [Silk.NET][silknet], all three [Java][java] subjects | Fences/semaphores/barriers are inert typed (or untyped) values; correctness is delegated to the developer plus the [validation layers][sync-validation]                                                                                                        |
| **Runtime usage tracking** | [vulkano][vulkano] (gen 2), [wgpu][wgpu], [Tephra][tephra]'s job tier                                           | Per-resource state maps diffed per command: `HashMap<Arc<Buffer>, RangeMap<DeviceSize, BufferState>>` per command buffer (vulkano), per-subresource SOA state vectors (wgpu), per-queue subresource access maps resolved at job submit (Tephra)                |
| **Graph compilation**      | [Daxa][daxa], [vuk][vuk], `vulkano-taskgraph` ([vulkano][vulkano])                                              | Declared per-task/per-argument accesses compiled into batched `synchronization2` barriers + timeline semaphores; Daxa records once and replays, vuk recompiles per submit with partial evaluation, vulkano-taskgraph compiles once but is `unsafe`/unvalidated |

The strongest single data point is **vulkano's own migration**: after a decade as the
flagship of inferred per-command auto-sync, its v0.35-era rework
(`vulkano-taskgraph`, February 2025) moves to declared accesses and a compiled DAG —
the [Daxa][daxa]/[vuk][vuk] model — because the gen-2 hash-map/range-map work per
recorded command per frame did not scale. The temporary price is the survey's most
telling caveat, verbatim from the crate banner: _"EXPERIMENTAL … There is also
currently no validation except the most bare-bones sanity checks"_
([vulkano][vulkano]). Inference was safe-but-slow; declaration is fast-but-(currently)-unchecked.

On **queue-family ownership transfer**: only the graph layers model it at all —
[vuk][vuk] derives transfers from producing/consuming queue placement (and sidesteps
them for buffers via `VK_SHARING_MODE_CONCURRENT`), [Daxa][daxa] emits cross-queue
timeline-semaphore sync, [Tephra][tephra] broadcasts access-map state across queues on
cross-queue export; [wgpu][wgpu] erases the problem by exposing a single queue.
Everyone else leaves `srcQueueFamilyIndex` a raw integer.

On **`externsync`/externally-synchronized handles**: per [§1.2](#12-binding-generation--api-coverage),
no subject promotes it into types. The runtime camps discharge it dynamically —
[vulkano][vulkano] takes an internal `parking_lot` mutex in `Queue::with` and makes
recording command buffers `!Send`/`!Sync`; [wgpu][wgpu] makes _everything_
`Send + Sync` by wrapping externally-synchronized handles in internal mutexes ordered
by a hand-maintained static lock-rank table. The spec's contract that motivates all of
this, verbatim from `fundamentals.adoc` ([sync-validation][sync-validation]):

> _"the caller must guarantee that no more than one thread is using such a parameter at
> a given time."_

That is precisely an exclusive-borrow obligation — `&mut` in Rust, `ref` + DIP1000
`scope` in D — and nobody generates it.

---

### 1.5 Type-system techniques

Best-in-class per technique, across the whole survey:

| Technique                         | Best in class                                                                                                                                                                                                                                                                                                                                 | Also-rans / notes                                                                                                                                                                                                                                                                                                                                                                 |
| --------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Typed `pNext` chains**          | [Haskell][haskell]: structs parameterized over a type-level list of their chain tail; `Extends`/`Extendss` closed type families from `structextends`; the `Chain` family is _injective_, so **output** chains are inferred from the pattern match — _"the head of any struct chain is parameterized over the rest of the items in the chain"_ | `StructureChain` + `static_assert` ([Vulkan-Hpp][vulkan-hpp]); `Extends` marker traits ([ash][ash]); generated output-chain traits — best among thin bindings ([vulkanalia][vulkanalia]); generic constraints ([Silk.NET][silknet]); _abolished_ — flattened into create-info structs ([vulkano][vulkano]); untyped `void*` ([vulkan-zig][vulkan-zig], [ErupteD][erupted], LWJGL) |
| **Handle branding**               | [Olivine][olivine]: generative functors mint a fresh abstract type per handle kind with one ~60-line runtime module and zero per-handle codegen                                                                                                                                                                                               | `repr(transparent)` newtypes ([ash][ash]); non-exhaustive `enum(u64)` ([vulkan-zig][vulkan-zig]); phantom-tagged `VkObjectHandle<T, VkObjectType>` ([Tephra][tephra]); `TypedImageViewId<VIEW_TYPE>` ([Daxa][daxa]); IDE-plugin-enforced `@EnumType` int branding — type checking pushed into tooling ([Java][java])                                                              |
| **Result typing**                 | [vulkan-zig][vulkan-zig]: per-command error sets force handling via `try` while non-`VK_SUCCESS` success codes stay values                                                                                                                                                                                                                    | Polymorphic-variant narrowing with exhaustiveness — caught an unchecked `vkMapMemory` the C tutorial missed ([Olivine][olivine]); `VkSuccessResult` preserving `SUBOPTIMAL_KHR` ([vulkanalia][vulkanalia])                                                                                                                                                                        |
| **Host-memory lifetimes**         | [ash][ash] 0.38: `'a` + `PhantomData` on generated structs, guarded by a `trybuild` compile-fail test                                                                                                                                                                                                                                         | Separate `Builder<'b>` types with a lifetime-discarding `.build()` escape hatch ([vulkanalia][vulkanalia]); `ArrayProxyNoTemporaries` overload restriction ([Vulkan-Hpp][vulkan-hpp]); `Arena` confinement ([Java][java])                                                                                                                                                         |
| **Access-as-type**                | [vuk][vuk]: `Access` is a non-type template parameter in the pass's function type (`Arg<T, Access, tag>`), reflected by `make_pass` into the IR                                                                                                                                                                                               | Daxa's attachments are runtime declarations behind a fluent builder, shared with shaders via `DAXA_DECL_TASK_HEAD` codegen ([Daxa][daxa])                                                                                                                                                                                                                                         |
| **Capability / extension typing** | [Olivine][olivine]: extensions are ML functors over a module holding a live `VkInstance`/`VkDevice` — access is a static module-system obligation                                                                                                                                                                                             | Version/extension traits that compile regardless of enablement and panic at runtime ([vulkanalia][vulkanalia]); runtime-loaded per-tag classes ([Silk.NET][silknet]); `Features`/`Limits` as data, not types ([wgpu][wgpu], [vulkano][vulkano])                                                                                                                                   |
| **`sType` auto-initialization**   | [ErupteD][erupted]: D default field initializers on all 666 tagged structs — zero-cost, no builder needed, unique to D in this survey                                                                                                                                                                                                         | Builder/chain machinery sets it everywhere else; registry `values` defaults ([vulkan-zig][vulkan-zig])                                                                                                                                                                                                                                                                            |
| **Flags vs FlagBits distinction** | [Olivine][olivine]: phantom singleton/plural parameter — `mem` statically requires a single flag, set operators yield unions, zero cost                                                                                                                                                                                                       | `EnumBitMask` ([Tephra][tephra]); packed structs of bools that deliberately _lose_ the distinction ([vulkan-zig][vulkan-zig]); weak `uint` aliases ([ErupteD][erupted])                                                                                                                                                                                                           |

Conspicuous absences are findings too: **no subject uses builder typestate** for
command-recording protocols (begin/end, render-pass scope), **no subject types image
layouts** ([Daxa][daxa] instead _abolished_ them down to three on modern-GPU-only
hardware), and the production-scale auto-sync layer ([wgpu][wgpu]) has _deliberately
almost no_ user-facing type machinery — its safety is 100 % runtime.

---

### 1.6 Overhead & escape hatches

The cost ladder, with the survey's measured numbers:

| Tier                                 | Cost character                                                                                                                                                                                                                                                                                                                                                                                        | Subjects                         |
| ------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------- |
| **Zero-cost, structurally enforced** | Layout parity asserted per type (`static_assert` _"handle and wrapper have different size!"_, [Vulkan-Hpp][vulkan-hpp]); `repr(transparent)` + `#[inline]` ([ash][ash], [vulkanalia][vulkanalia]); one indirect call through a per-device table ([ErupteD][erupted], [vulkan-zig][vulkan-zig])                                                                                                        | All thin bindings                |
| **Near-zero, managed runtime**       | `calli` through a lazily-cached VTable ([Silk.NET][silknet]); Panama FFM at ~49.7 ns vs JNI ~56.6 ns per call, `Linker.Option.critical` ≈ 160 % of JNI throughput, plus `MemorySegment` bounds/liveness checks ([Java][java]); ContT marshalling allocation per call ([Haskell][haskell]); libffi dynamic marshalling per call ([Olivine][olivine])                                                   | Managed-language bindings        |
| **Runtime tracking, per command**    | Hash-map + range-map state per recorded command every frame ([vulkano][vulkano] gen 2); maintainer-estimated **5–10 % typical CPU overhead over raw `hal`, measured ~2× worst case** (`halmark` vs `bunnymark`), and post-arcanization lock contention still degrading concurrent upload from 60 FPS to ~10 FPS — against a **45 % frame-time reduction** for Bevy's parallel encoding ([wgpu][wgpu]) | [vulkano][vulkano], [wgpu][wgpu] |
| **Runtime tracking, amortized**      | Graph analysis front-loaded: `complete()` once then replay ([Daxa][daxa] — release receipts: ~2× faster record/execute in 3.5, ~60 % fewer allocations in 3.1); per-submit IR compilation with executed nodes _"morph[ed] into acquire"_ in place ([vuk][vuk]); tracking only at job submit, never during command-list recording ([Tephra][tephra])                                                   | Graph layers                     |

[Tephra][tephra] states the dividing line of this ladder most cleanly, verbatim from
its README:

> _"analyzing commands recorded into command lists would have unacceptable performance
> overhead."_

— i.e. the field's consensus is that per-draw-call tracking is off the table; the open
question is only _where above the draw call_ the tracking sits (per command: vulkano
gen 2/wgpu; per job: Tephra; per graph: Daxa/vuk).

**Escape hatches are universal and load-bearing.** Every subject, including the
maximal-safety ones, ships a sanctioned route to raw handles: `reinterpret_cast`
licensed by layout asserts ([Vulkan-Hpp][vulkan-hpp]), `Handle::as_raw`/`from_raw` and
`device.fp_v1_0()` ([ash][ash]), per-call `_unchecked` twins plus `VulkanObject`
([vulkano][vulkano]), `wgpu-hal` `as_hal`/`from_hal` with _"minimal validation, if
any"_ ([wgpu][wgpu]), `vkGetHandle()` and external-handle adoption ([Tephra][tephra]),
`CommandBuffer::get_underlying()` ([vuk][vuk]), raw `VkDevice`/`VkBuffer` getters
([Daxa][daxa]), three-tier raw/regular/native generation modes ([Olivine][olivine]).
The lesson for any new design: the escape hatch is not a concession, it is part of the
contract — interop with VMA, windowing, and capture tools all flow through it.

---

### 1.7 Error handling & validation integration

`successcodes`/`errorcodes` is the registry metadata with the best survival rate
([sync-validation][sync-validation]), and the regimes built on it span the whole
severity spectrum:

| Regime                      | Subjects                                                                                                                                                                                                                  |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Ignorable raw `Result` enum | [Silk.NET][silknet], [ErupteD][erupted], LWJGL ([Java][java])                                                                                                                                                             |
| Exceptions                  | [Vulkan-Hpp][vulkan-hpp] default (`vk::SystemError` hierarchy), jcoronado's `VulkanException` ([Java][java]), the abandoned SharpVk ([Silk.NET][silknet])                                                                 |
| `Result`/`Expected` values  | [ash][ash], [vulkanalia][vulkanalia]'s success-preserving split, [Vulkan-Hpp][vulkan-hpp] under `VULKAN_HPP_USE_STD_EXPECTED` (C++23)                                                                                     |
| Compiler-enforced handling  | [vulkan-zig][vulkan-zig] error sets (`try`), [Olivine][olivine] exhaustive polymorphic variants, [vuk][vuk]'s `Result<T,E>` that throws/aborts if an error is dropped unexamined                                          |
| Abort                       | [Daxa][daxa]'s C++ wrapper (`check_result` → `std::abort`; recoverable errors only at the C ABI)                                                                                                                          |
| Full host-side revalidation | [vulkano][vulkano]: every safe call re-checks valid usage and returns typed `ValidationError`s (with VUIDs) — always on, no global off-switch; [wgpu][wgpu] reimplements WebGPU validation entirely, replacing the layers |

Validation-layer integration is mostly **pass-through by ABI fidelity**: thin bindings
work under `VK_LAYER_KHRONOS_validation` because their types are layout-exact, and
their docs uniformly treat the layers as the real safety net ([ash][ash]'s _"No
validation, everything is **unsafe**"_ is the honest statement of the whole tier's
contract). The graph layers add a subtler relationship: because [Daxa][daxa] and
[vuk][vuk] _emit_ standard `synchronization2` barriers, [syncval][sync-validation]
functions as a test oracle for their compilers' output — a free correctness harness any
new graph implementation (including a D one) inherits.

---

## Part 2 — Consensus and trade-offs

### 2.1 The consensus standard

Where the evidence converges, across fourteen libraries and eight languages:

1. **A thin, fully-generated, zero-overhead core is table stakes.** Every healthy
   ecosystem's foundation is an `ash`-shaped artifact: `vk.xml`-generated, layout-exact,
   loader-aware (global → instance → device function-pointer tiers), with automation
   keeping it current (weekly for [Vulkan-Hpp][vulkan-hpp], nightly for
   [vulkanalia][vulkanalia], build-time for [vulkan-zig][vulkan-zig]). Ecosystems
   without one stagnate — the D row ([ErupteD][erupted], frozen April 2023, ~105 header
   revisions behind) is the cautionary instance.
2. **Safety is layered above, opt-in, and per-resource.** [Vulkan-Hpp][vulkan-hpp]'s
   four ownership models, [vulkano][vulkano]'s `_unchecked` twins, [wgpu][wgpu]'s `hal`
   floor: the field rejects all-or-nothing safety. The .NET history is the sharpest
   proof — the idiomatic exception-based SharpVk died while thin
   [Silk.NET][silknet] became the standard, mirroring Rust's vulkano→ash usage drift.
3. **Typed `pNext` chains from `structextends` are a solved problem** with four
   independent convergent implementations (C++ traits, Rust marker traits, C# generic
   constraints, Haskell type families). Any new binding that ships untyped `void*`
   chains is leaving proven, zero-cost safety on the table.
4. **`synchronization2` is the sync substrate.** [vuk][vuk] requires it
   (_"vuk requires at least vulkan 1.2 and the synchronization2 extension"_),
   [Daxa][daxa] emits it, jcoronado mandates the device feature to collapse code paths
   (99.82 % hardware coverage, per [its README][java]); per-barrier `(stage, access)`
   records are both the graph compilers' target and [syncval][sync-validation]'s
   validation unit.
5. **Declared-access graphs are where auto-sync converged.** Inferred per-command
   tracking ([vulkano][vulkano] gen 2, [wgpu][wgpu]) is the measured-overhead pole;
   record-once compiled graphs ([Daxa][daxa], `vulkano-taskgraph`) and per-submit
   compilation with partial evaluation ([vuk][vuk]) are the destination. Tephra's
   two-tier split and wgpu's eager derivation are the intermediate points.
6. **`externsync` is consensus-ignored** — the one place the whole field agrees by
   omission, and therefore the cheapest genuine differentiation available to a
   newcomer ([sync-validation §Type-system techniques][sync-validation-types]).

### 2.2 The architectural trade-off axes

| Axis                                      | Pole A                                                                                                                             | Pole B                                                                                                                                        | The measured/structural evidence                                                                                                                                                                   |
| ----------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Auto-sync runtime cost vs manual risk** | Manual barriers, zero overhead, UB on mistakes (thin tier)                                                                         | Automated tracking: 5–10 % typical / ~2× worst CPU ([wgpu][wgpu]); per-command hash/range maps ([vulkano][vulkano])                           | The resolution is the third option: amortized graph compilation ([Daxa][daxa] ~2× record/execute gains; [vuk][vuk] `ACQUIRE` morphing) — declared accesses cost compile-time, not per-command time |
| **Inference vs declaration**              | Infer sync from observed commands (vulkano gen 2, wgpu) — ergonomic, unscalable                                                    | Declare accesses up front (Daxa, vuk, taskgraph) — scalable, shifts correctness burden to declarations                                        | vulkano migrated A→B and temporarily lost validation doing it; declarations are themselves uncheckable without either runtime validation or a type system                                          |
| **Type-level safety vs API ergonomics**   | Maximal structural typing ([Haskell][haskell] chains) with GHC-skill error messages                                                | Flattened/abolished features ([vulkano][vulkano] removed `pNext` genericity; [Daxa][daxa] removed image layouts)                              | Both extremes ship; the middle (trait-constrained chains with an `*Any` escape, [Silk.NET][silknet]) has the best adoption story                                                                   |
| **Codegen vs comptime**                   | Offline generator, committed output (ash's 76k-line `definitions.rs`; Kotlin generator for a Rust crate, [vulkanalia][vulkanalia]) | In-language compile-time work ([vulkan-zig][vulkan-zig]'s two-stage build-time generator + `comptime` reflective templates)                   | Zig shows the split collapsing; D's CTFE + string imports could collapse it fully — one stage, no foreign-language generator, no committed drift                                                   |
| **Where thread-safety lives**             | In types (nobody, for `externsync`)                                                                                                | In runtime mutexes ([wgpu][wgpu]'s lock-rank table; [vulkano][vulkano]'s `Queue` mutex) or in nothing ([ErupteD][erupted]'s `__gshared` tier) | The registry's machine-readable contract sits unused between the poles                                                                                                                             |
| **Error severity**                        | Ignorable codes (C parity)                                                                                                         | Unskippable (`try` error sets, drop-aborting `Result`, always-on revalidation)                                                                | Compiler-enforced-but-zero-cost ([vulkan-zig][vulkan-zig], [Olivine][olivine]) dominates both extremes on the cost/safety frontier                                                                 |

---

## Part 3 — The `sparkles:vulkan` delta table

The D ecosystem baseline is empty above the thin tier ([ErupteD][erupted]: no
maintained binding, no RAII layer, no sync automation anywhere). That is a liability
and an opportunity: every capability below has a best-in-class exemplar elsewhere and a
direct D mechanism — CTFE/metaprogramming, `@safe` + [DIP1000][dip1000] `scope`, and
the repo's [DbI shell-with-hooks vocabulary][dbi] — with no measured-runtime-cost
entries required except where the field's evidence says runtime is genuinely
unavoidable.

| Capability                              | Best-in-class example                                                                                           | D mechanism                                                                                                                                                                                                                                      | Feasibility note                                                                                                                                                                                                           |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Always-current generation**           | [vulkan-zig][vulkan-zig]'s build-time generator on the user's `vk.xml`; [vulkanalia][vulkanalia]'s nightly cron | CTFE parse of `vk.xml` via string `import(...)` + mixin codegen — one stage, no foreign-language generator, no committed 76k-line artifact                                                                                                       | CTFE memory/time on a ~4 MB XML is the open risk; fallback is a D-written offline generator (still one language). ImportC already provides a verified always-current floor ([ErupteD][erupted])                            |
| **`sType` auto-initialization**         | [ErupteD][erupted] — default field initializers on all 666 tagged structs                                       | Same: `VkStructureType sType = VK_STRUCTURE_TYPE_…;` default initializers                                                                                                                                                                        | Already proven in D, zero cost, no builder required — beats every C++/Rust mechanism on simplicity; inherit it verbatim                                                                                                    |
| **Typed `pNext` chains (input)**        | [Haskell][haskell] type families; [Vulkan-Hpp][vulkan-hpp] `StructureChain` (1,213 pairs)                       | `structextends` → CTFE-generated trait `enum extendsStruct(Ext, Base)`; a variadic `StructureChain!(Ts...)` shell with template-constraint validation                                                                                            | Direct mapping to D template constraints; strictly easier than C++ (no SFINAE) — compile-time only                                                                                                                         |
| **Typed `pNext` chains (output/query)** | [Haskell][haskell]'s injective `Chain` family; [vulkanalia][vulkanalia]'s generated output-chain traits         | Templated query wrappers returning the caller-specified chain type; `static if` on whether the registry marks `pNext` non-const                                                                                                                  | vulkanalia proves the registry distinguishes output chains; D type inference handles the rest                                                                                                                              |
| **`externsync` → exclusive borrows**    | **Nobody** — the survey's open gap ([sync-validation][sync-validation])                                         | CTFE-consume the 402 `externsync` attributes: `externsync="true"` params become `ref` + `scope` in `@safe` wrappers; `vkDestroy*` consumes a non-copyable handle wrapper; the 7 `implicitexternsyncparams` blocks hand-curated into a CTFE table | The genuinely novel deliverable. `maybe` forms need conservative treatment (over-lock or document); per-element `maybe:path[]` is beyond DIP1000 — runtime-assert in debug                                                 |
| **Result typing**                       | [vulkan-zig][vulkan-zig] error sets; [vulkanalia][vulkanalia]'s success-code-preserving split                   | `successcodes`/`errorcodes` → `Expected!(T, VkResult)` per the repo's [`expected` idiom][expected-idiom]; multi-success commands return `(T, SuccessCode)` tuples                                                                                | Direct fit with existing `core-cli`/`versions` conventions; `@nogc nothrow` compatible                                                                                                                                     |
| **Handle branding**                     | [Olivine][olivine] generative functors; [ash][ash] newtypes                                                     | Distinct zero-size-wrapped structs (or typed enums) per handle, `static assert` layout parity à la [Vulkan-Hpp][vulkan-hpp]                                                                                                                      | Trivial; also fixes ErupteD's 32-bit degradation to `ulong` aliases                                                                                                                                                        |
| **Host-memory lifetime safety**         | [ash][ash] 0.38 struct lifetimes + `trybuild` compile-fail proof                                                | DIP1000 `scope`/`return ref` on pointer-carrying create-info members; compile-fail tests via `__traits(compiles, …)`                                                                                                                             | The repo already builds everything with `-preview=dip1000`; known Phobos `scope` clashes are documented in [AGENTS][agents]                                                                                                |
| **Device-object temporal safety**       | None compile-time anywhere; best runtime: [Daxa][daxa] generational IDs + zombie lists                          | Accept the field's verdict: runtime — generational IDs + timeline-gated deferred destruction in the mid-tier; DIP1000 cannot express "until the GPU catches up"                                                                                  | Do not over-promise statically; the survey shows even Rust's borrow checker punts here ([wgpu][wgpu]'s `'static` retreat)                                                                                                  |
| **Capability / extension typing**       | [Olivine][olivine] extension functors; [vulkanalia][vulkanalia] version/extension traits                        | DbI: the device wrapper is a shell whose hook encodes enabled extensions; `static if (hasCapability!(Hook, "khrSwapchain"))` gates command availability at compile time                                                                          | Fits the repo's [shell-with-hooks pattern][dbi] exactly; stronger than Olivine (can encode _enablement_, not just handle possession) when device creation flows through the typed path                                     |
| **Flags vs FlagBits**                   | [Olivine][olivine] phantom singleton/plural bitsets                                                             | Distinct single-bit enum + multi-bit struct with `opBinary` set algebra; CTFE-checked single-bit construction                                                                                                                                    | Zero cost; also resolves the 64-bit `Flags2` non-enum wart ([sync-validation][sync-validation]) that breaks C-enum-based generators                                                                                        |
| **Sync automation (mid/high tier)**     | [Daxa][daxa]/[vuk][vuk] declared-access graphs; [vulkano][vulkano]'s migration as the evidence                  | A later `sparkles:vulkan-graph` tier: declared per-task accesses as template value parameters (vuk's `Arg<T, Access, tag>` maps to D template value params + CTFE), graph checked at compile time where the topology is static                   | The gap `vulkano-taskgraph` exposes — declared accesses that are _validated_ — is reachable in D because access declarations can be CTFE data, not just runtime structs; treat as a separate library tier, not the binding |
| **Escape hatches**                      | [Vulkan-Hpp][vulkan-hpp] layout-assert-licensed `reinterpret_cast`; [ash][ash] `as_raw`/`from_raw`              | Layout-asserted wrappers; `.rawHandle` accessors; the typed tier always convertible down to ImportC/raw-struct level                                                                                                                             | Non-negotiable per the field consensus ([§1.6](#16-overhead--escape-hatches)); design it first, not last                                                                                                                   |
| **Validation integration**              | [syncval][sync-validation] as a test oracle for graph output ([Daxa][daxa], [vuk][vuk])                         | CI tests run generated barrier streams under `VK_LAYER_KHRONOS_validation` + syncval where an ICD exists; the typed host-sync layer is _complementary_ (compile-time host races, runtime device hazards)                                         | Mirrors the Khronos division of labor: thread-safety layer ↔ generated `externsync` types; syncval ↔ graph tier                                                                                                          |

### The zero-dependency rows, demonstrated

Three of the delta-table rows claim mechanisms D already has, with no Vulkan SDK or
binding required — `sType` default initializers, `structextends` → template
constraints, and `Expected!(T, VkResult)` result typing. The following runnable
sketch (CI-verified via the repo's `ci --verify` harness) puts those claims under
test against miniature stand-ins for the registry-generated types:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "vulkan_delta_sketch"
    dependency "expected" version="~>0.4.0"
+/
import std.stdio : writeln;
import expected : Expected, ok, err;

// vk.xml's per-struct sType tag becomes a default field initializer (the
// ErupteD-proven win) — no builder, no runtime setter, no way to forget it.
enum VkStructureType { applicationInfo = 0, bufferCreateInfo = 12, dedicatedAlloc = 1000127001 }
enum VkResult { success = 0, errorOutOfDeviceMemory = -2 }

struct VkBufferCreateInfo
{
    VkStructureType sType = VkStructureType.bufferCreateInfo; // pre-set at compile time
    const(void)* pNext = null;
    ulong size;
}

struct VkDedicatedAllocationCreateInfo
{
    VkStructureType sType = VkStructureType.dedicatedAlloc;
    const(void)* pNext = null;
}

// vk.xml structextends="VkBufferCreateInfo" → a CTFE-generated trait...
enum extendsStruct(Ext, Base) =
    is(Ext == VkDedicatedAllocationCreateInfo) && is(Base == VkBufferCreateInfo);

// ...consumed as a template constraint: an illegal pNext chain does not compile.
ref Base chain(Base, Ext)(return ref Base base, return ref Ext ext)
if (extendsStruct!(Ext, Base))
{
    ext.pNext = base.pNext;
    base.pNext = &ext;
    return base;
}

// successcodes/errorcodes → Expected!(T, VkResult), per the repo's expected idiom.
Expected!(ulong, VkResult) createBuffer(in VkBufferCreateInfo info) @safe pure nothrow @nogc
{
    if (info.size == 0)
        return err!ulong(VkResult.errorOutOfDeviceMemory);
    return ok!VkResult(0xB0F0UL); // a fake handle
}

void main() @safe
{
    VkBufferCreateInfo info = { size: 64 };
    writeln("sType pre-set:       ", info.sType == VkStructureType.bufferCreateInfo);

    VkDedicatedAllocationCreateInfo dedicated;
    () @trusted { info.chain(dedicated); }();
    writeln("chain wired:         ", () @trusted { return info.pNext is &dedicated; }());
    // Chaining in the wrong direction is rejected at compile time:
    static assert(!__traits(compiles, dedicated.chain(info)));

    writeln("created:             ", createBuffer(info).hasValue);
    writeln("typed error:         ", createBuffer(VkBufferCreateInfo()).error);
}
```

```[Output]
sType pre-set:       true
chain wired:         true
created:             true
typed error:         errorOutOfDeviceMemory
```

The one-paragraph synthesis: **`sparkles:vulkan` should be a CTFE-generated thin
binding that finally consumes the registry's safety metadata** — `sType` defaults
(ErupteD's proven win), `Expected`-typed results, constraint-checked `pNext` chains,
and, uniquely, `externsync`-derived `ref`/`scope`/`@safe` signatures with non-copyable
destroy-consumed handles — at zero runtime cost with layout-asserted escape hatches,
leaving runtime machinery (generational IDs, deferred destruction, a declared-access
graph) to clearly separated opt-in tiers, exactly the layering the field converged on
and the D ecosystem entirely lacks.

---

## Sources

- Ground truth: [sync-validation][sync-validation] · [concepts][concepts] · [survey index][index]
- Thin bindings: [Vulkan-Hpp][vulkan-hpp] · [ash][ash] · [vulkanalia][vulkanalia] ·
  [vulkan-zig][vulkan-zig] · [ErupteD & the D landscape][erupted]
- Safety-first wrappers: [vulkano][vulkano] · [vulkan (Haskell)][haskell] ·
  [Olivine][olivine] · [Silk.NET][silknet] · [LWJGL / vulkan4j / jcoronado][java]
- Render-graph / auto-sync layers: [Daxa][daxa] · [vuk][vuk] · [Tephra][tephra] · [wgpu][wgpu]
- Repo conventions: [agent guidelines][agents] · [DbI guidelines][dbi] ·
  [`expected` idioms][expected-idiom]
- Language references: [DIP1000 scoped pointers][dip1000]

<!-- References -->

[index]: ./index.md
[concepts]: ./concepts.md
[sync-validation]: ./sync-validation.md
[sync-validation-types]: ./sync-validation.md#type-system-techniques
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
[dip1000]: https://dlang.org/spec/function.html#scope-parameters
[dbi]: ../../guidelines/design-by-introspection-01-guidelines.md
[agents]: ../../guidelines/AGENTS.md
[expected-idiom]: ../../guidelines/idioms/expected/index.md
