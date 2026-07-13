# Shared Concepts: Vulkan Safety & Binding Vocabulary

The shared vocabulary of this survey: every synchronization primitive, architecture
pattern, and type-system technique the deep-dives reference, each defined once,
grounded in real examples from the surveyed systems, and assessed on the two axes the
whole tree cares about — **what it buys in safety** and **what it costs at runtime**.

> **Scope.** This is a _reference_ document, not a library deep-dive. Terms are grouped
> into five clusters: the [two synchronization domains](#the-two-synchronization-domains)
> Vulkan defines, the [device-side primitive set](#device-side-synchronization-primitives)
> wrappers must model, the [architecture patterns](#architecture-patterns) built above
> the raw API, the [type-system techniques](#type-system-techniques) used to encode
> rules statically, and [binding generation](#binding-generation) from `vk.xml`. For the
> registry/spec/validation-layer ground truth behind the synchronization terms, see
> [sync-validation][sync-validation]; for how each surveyed system combines these
> concepts, see the per-system deep-dives and the [comparison][comparison].

**Last reviewed:** June 11, 2026

---

## The two synchronization domains

Vulkan's correctness rules split into two domains that wrapper designs routinely
conflate, with very different machine-readability and very different type-system
mappings (the split is developed in full in [sync-validation][sync-validation]):

| Domain                     | Question it answers                                    | Machine-readable?                                                       | Natural static encoding                                                                                                            |
| -------------------------- | ------------------------------------------------------ | ----------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| **Host synchronization**   | Which CPU threads may touch which handles concurrently | Yes — [`externsync`](#external-synchronization--externsync) in `vk.xml` | Exclusive borrows (`&mut`, DIP1000 `scope ref`)                                                                                    |
| **Device synchronization** | Which GPU operations happen-before which               | No — prose Valid Usage only                                             | None mainstream; hence [graphs](#render-graph--task-graph--frame-graph) and [tracking](#auto-sync-via-per-resource-usage-tracking) |

### External synchronization & `externsync`

**Definition.** A parameter of a Vulkan command is _externally synchronized_ when the
application — not the driver — must guarantee exclusive access to it for the call's
duration. From the spec's [Threading Behavior chapter][spec-threading] (verbatim, via
[`fundamentals.adoc`][fundamentals-adoc]):

> _"All commands support being called concurrently from multiple threads, but certain
> parameters, or components of parameters are defined to be **externally synchronized**.
> This means that the caller must guarantee that no more than one thread is using such a
> parameter at a given time."_

The requirement is machine-encoded in [`vk.xml`][vkxml] as the `externsync` attribute —
402 attribute instances on `main` as of June 11, 2026, in four value forms (`true`, `maybe`,
member-path expressions like `pNameInfo->objectHandle`, and `maybe:` member paths); see
[sync-validation § What `vk.xml` encodes][sync-validation-encodes] for the full grammar.
Violations are plain undefined behavior — there is no `VK_ERROR_RACE_CONDITION`.

**Why it matters.** This is a textbook _exclusive-borrow_ obligation: `externsync="true"`
on a parameter is semantically `&mut`/`inout`, and `externsync` on every `vkDestroy*`
handle is semantically a consuming move. It is the **one** piece of Vulkan safety
metadata that is complete, trustworthy (the spec's own host-sync tables are generated
from it), and mechanically consumable by a binding generator — at **zero runtime cost**,
since the encoding would live entirely in signatures.

**Who uses it.** Almost nobody — the survey's central negative finding. The attribute is
parsed-and-discarded by [Vulkan-Hpp][cpp-vulkan-hpp]'s generator, never read by
[ash][rust-ash]'s, [vulkanalia][rust-vulkanalia]'s, or [vulkan-zig][zig-vulkan-zig]'s,
dropped with a literal `(* TODO *)` by [olivine][ocaml-olivine], and absent from
[erupted][d-erupted], [Silk.NET][csharp-silknet], and every JVM binding
[surveyed][java-lwjgl-vulkan4j]. [haskell-vulkan][haskell-vulkan] is the high-water mark:
the requirement survives as generated Haddock _prose_ ("Host access to `queue` must be
externally synchronized"), still not as types. [vulkano][rust-vulkano] discharges it at
runtime instead (internal `parking_lot` mutex on `Queue`, `!Send` recording command
buffers), and [daxa][cpp-daxa]/[Tephra][cpp-tephra] restate it as per-type documentation.

### Implicit vs explicit host synchronization

**Definition.** Vulkan objects fall into three host-threading classes:

1. **Internally synchronized** — the driver locks internally; any thread may use the
   handle concurrently (e.g. `VkDevice` for most commands, `vkAllocateDescriptorSets`
   when the pool has `VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT` unset is _not_
   one of them — the pool is the sync unit).
2. **Explicitly externally synchronized** — the parameter carries an
   [`externsync`](#external-synchronization--externsync) tag (e.g. `commandBuffer` in
   `vkBeginCommandBuffer`).
3. **Implicitly externally synchronized** — the exclusivity obligation falls on an
   object _not named in the call at all_. From [`fundamentals.adoc`][fundamentals-adoc]
   (verbatim): _"when a `commandBuffer` parameter needs to be externally synchronized, it
   implies that the `commandPool` from which that command buffer was allocated also needs
   to be externally synchronized."_ `vk.xml` records these as 7 free-text
   `implicitexternsyncparams` blocks — prose, not machine-checkable structure.

**Why it matters.** The implicit class contains the single most architecturally
important host rule (command buffer ⇒ its pool: one recording thread per
`VkCommandPool`), and because it is prose, every consumer must hand-curate it. It is
also the rule that shapes wrapper APIs most visibly: it is _why_ thread-safe wrappers
organize command recording around per-thread pools.

**Who uses it.** The Khronos thread-safety validation layer special-cases command pools
(see [sync-validation][sync-validation]); [vulkano][rust-vulkano] runtime-locks the pool
inside its command-buffer builder; [Tephra][cpp-tephra]'s documented threading rule is
literally "one thread per pool"; [daxa][cpp-daxa]'s `CommandRecorder` is documented as
"must be externally synchronized" while `Device` is internally synchronized. No surveyed
binding encodes the pool coupling in types — the [sync-validation][sync-validation] page
sketches the DIP1000/pool-branded-recorder encoding a D library could use.

---

## Device-side synchronization primitives

The five-primitive vocabulary every wrapper either exposes raw, wraps in builders, or
compiles away. All are defined normatively in the spec's
[Synchronization and Cache Control chapter][spec-sync]; the per-barrier
`(stage, access)` shape described below is the [`VK_KHR_synchronization2`][sync2-ext]
formulation (core since Vulkan 1.3), which every modern auto-sync layer surveyed
([daxa][cpp-daxa], [vuk][cpp-vuk], and [jcoronado][java-lwjgl-vulkan4j] by mandate)
targets exclusively.

### Pipeline barriers

**Definition.** `vkCmdPipelineBarrier2` records an _intra-queue_ execution + memory
dependency: everything matching `srcStageMask`/`srcAccessMask` before the barrier
happens-before everything matching `dstStageMask`/`dstAccessMask` after it, with caches
flushed/invalidated for the named access types. Under synchronization2 each
`VkMemoryBarrier2`/`VkBufferMemoryBarrier2`/`VkImageMemoryBarrier2` carries its own
self-contained `(stage, access)` pair — the atomic unit [syncval](#hazards-rawwarwaw--syncvals-taxonomy)
validates and graph compilers emit.

**Why it matters.** Barriers are where most synchronization bugs live (missing, wrong
scope, or — the silent performance bug — too wide). They are pure recorded commands:
**zero host-side cost beyond recording**, so the entire design question is who computes
them. Hand-written ([ash][rust-ash], [erupted][d-erupted], [Vulkan-Hpp][cpp-vulkan-hpp]),
runtime-derived ([wgpu][rust-wgpu], [vulkano][rust-vulkano] gen-2,
[Tephra][cpp-tephra]'s job tier), or graph-compiled ([daxa][cpp-daxa], [vuk][cpp-vuk] —
vuk has _no user-facing barrier API at all_). The minimal mitigation short of any
automation — still hand-placed, but no longer hand-assembled — is the
[simplified barrier vocabulary](#simplified-barrier-vocabulary-named-usage-states)
pattern below.

### Events (split barriers)

**Definition.** `VkEvent` splits a barrier in two: `vkCmdSetEvent2` marks the source
point (carrying its own `VkDependencyInfo` since sync2), `vkCmdWaitEvents2` the
destination, letting unrelated work execute between them.

**Why it matters.** Events are the fine-grained-overlap tool and the long tail of every
wrapper: maximum scheduling freedom, minimum abstraction support. **No surveyed system
automates them** — [daxa][cpp-daxa] exposes them manually outside its graph, [vuk][cpp-vuk]'s
README lists split barriers as an unchecked checkbox, [wgpu][rust-wgpu] and
[vulkano][rust-vulkano] never emit them. Their universal absence is a finding: per-range
event placement is exactly the optimization a whole-frame graph compiler is positioned
to do and none currently does.

### Fences

**Definition.** `VkFence` is a queue→host signal: passed to `vkQueueSubmit`, signaled
when the submission's work completes, waited on with `vkWaitForFences`. The canonical
gate for reusing per-frame resources.

**Why it matters.** Fences are the primitive behind every
[deferred-destruction](#deferred-destruction) and frames-in-flight scheme. Wrappers
either expose them raw (thin bindings), wrap them as waitable tokens
([vulkano][rust-vulkano]'s `FenceSignalFuture`, its taskgraph's fence-gated `Flight`
frames), or hide them entirely behind timeline counters ([wgpu][rust-wgpu]'s
`wgpu_hal::Api::Fence` _is_ a timeline semaphore when available, with a `VkFence`-pool
fallback; [vuk][cpp-vuk]'s API has no user-visible fence at all).

### Binary semaphores

**Definition.** `VkSemaphore` (binary type) orders work _between queues_ and with the
presentation engine: signaled by one submission, waited by another, automatically reset
on wait completion. Swapchain acquire/present is their irreducible use:
`vkAcquireNextImageKHR` and `vkQueuePresentKHR` accept only binary semaphores.

**Why it matters.** The strict signal-then-wait, one-shot protocol is a typestate-shaped
contract no surveyed system types (a double-wait compiles everywhere). Auto-sync layers
internalize them: [vuk][cpp-vuk] and [daxa][cpp-daxa] derive swapchain semaphores in
their graph executors; [wgpu][rust-wgpu] hides acquire/present semaphores inside its hal
(including a two-semaphore `RelaySemaphores` alternation working around a Mesa hang).

### Timeline semaphores

**Definition.** [`VK_KHR_timeline_semaphore`][timeline-sem] (core in Vulkan 1.2) gives a
semaphore a monotonically increasing 64-bit payload: any queue or host thread waits for
"value ≥ N", any submission signals a higher value, and one object replaces whole
families of binary semaphores and fences.

**Why it matters.** The monotonic counter is the natural "GPU progress epoch" primitive,
and the surveyed systems converge on it as infrastructure: [daxa][cpp-daxa] gates its
[zombie lists](#deferred-destruction) on per-queue timeline values, [vuk][cpp-vuk] rides
all GPU/host ordering on one timeline semaphore per `QueueExecutor`
(`SyncPoint{executor, visibility}`), [Tephra][cpp-tephra] unifies job IDs and timeline
values into one device-wide counter, [wgpu][rust-wgpu] implements its `Fence` as one,
and [vulkano][rust-vulkano]'s taskgraph uses them for cross-queue edges. Host-side they
map cleanly to futures/awaitables — and to D, a timeline value is the obvious epoch tag
for `@safe` deferred reclamation.

### Image layout transitions

**Definition.** Every `VkImage` subresource is, at each point on the GPU timeline, in a
_layout_ (`UNDEFINED`, `GENERAL`, `COLOR_ATTACHMENT_OPTIMAL`, `READ_ONLY_OPTIMAL`,
`PRESENT_SRC_KHR`, …) that licenses certain accesses and may imply a different physical
memory arrangement. Transitions are expressed as the `oldLayout`/`newLayout` fields of
an image memory barrier — i.e. layout is a hidden state machine threaded through
[barriers](#pipeline-barriers).

**Why it matters.** Layout is _device-side typestate with no host-side representation_:
the C API gives the program no value that holds an image's current layout, so wrappers
must reconstruct it. Strategies span the whole design space: track it per subresource at
runtime ([wgpu][rust-wgpu]'s `TextureUses` include layout-relevant states;
[vulkano][rust-vulkano]; [Tephra][cpp-tephra]'s access maps), derive it from declared
accesses ([vuk][cpp-vuk]'s `Access` values each imply a stage+access+**layout** triple,
with read groups merged into _"a merged layout (TRANSFER_SRC_OPTIMAL /
READ_ONLY_OPTIMAL / GENERAL)"_, per [`src/IRPasses.cpp`][vuk-irpasses]), or **abolish the
state machine**: [daxa][cpp-daxa] release 3.3 (November 2025) reduced supported layouts
to `UNDEFINED`/`GENERAL`/`PRESENT_SRC`, eliminating the transition bug class by fiat on
its modern-GPU-only floor. Thin bindings ([ash][rust-ash], [erupted][d-erupted], …)
leave layout entirely to the programmer and the validation layers.

### Queue-family ownership transfer (QFOT)

**Definition.** A buffer or image created with `VK_SHARING_MODE_EXCLUSIVE` has its
contents owned by one queue family at a time; moving it (e.g. transfer queue → graphics
queue) requires a matching **release barrier** on the source queue and **acquire
barrier** on the destination queue, with equal `srcQueueFamilyIndex`/`dstQueueFamilyIndex`
fields. `VK_SHARING_MODE_CONCURRENT` waives the protocol at a (hardware-dependent)
bandwidth cost.

**Why it matters.** QFOT is a two-phase, cross-queue protocol whose halves live in
different command buffers — maximally hostile to local reasoning, invisible to the
registry (the indices are plain `uint32_t`s in `vk.xml`), and unchecked by thin
bindings. The automation strategies: [vuk][cpp-vuk] emits QFOT only when its compiled
streams cross queue families and routes buffers via `CONCURRENT` sharing to dodge it
entirely; [daxa][cpp-daxa]'s `TaskGraph` derives transfers alongside its cross-queue
timeline-semaphore sync; [Tephra][cpp-tephra] broadcasts access-map state and ownership
via message passing between queues on cross-queue export; [wgpu][rust-wgpu] **deletes
the concept** — WebGPU has a single queue, so QFOT is absent by construction.

### Hazards (RAW/WAR/WAW) — syncval's taxonomy

**Definition.** A _hazard_ is a pair of memory accesses to overlapping resource ranges
without a sufficient dependency chain between them. The Khronos synchronization
validation layer (_syncval_, part of `VK_LAYER_KHRONOS_validation`) defines five kinds
in [`docs/syncval_usage.md`][syncval-usage] (first three verbatim):

| Hazard                   | Definition                                                                                                                                                               |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| RAW (Read-after-write)   | _"Occurs when a subsequent operation uses the result of a previous operation without waiting for the result to be completed."_                                           |
| WAR (Write-after-read)   | _"Occurs when a subsequent operation overwrites a memory location read by a previous operation before that operation is complete (requires only execution dependency)."_ |
| WAW (Write-after-write)  | _"Occurs when a subsequent operation writes to the same set of memory locations (in whole or in part) being written by a previous operation."_                           |
| WRW (Write-racing-write) | Write-racing-write between unsynchronized subpasses/queues                                                                                                               |
| RRW (Read-racing-write)  | Read-racing-write between unsynchronized subpasses/queues                                                                                                                |

Detection is per-resource-range most-recent-access tracking (`ResourceAccessState` in
interval trees) — see [sync-validation][sync-validation] for the design and its blind
spots.

**Why it matters.** This taxonomy is the survey's common currency for "what sync safety
means": it is exactly the property set that [usage tracking](#auto-sync-via-per-resource-usage-tracking)
checks dynamically, [graph compilers](#render-graph--task-graph--frame-graph) make
unrepresentable, and no surveyed type system proves statically. [wgpu][rust-wgpu]'s
usage-scope rule turns intra-pass write/write and read/write conflicts into validation
errors — WRW/RRW caught at runtime with zero false positives; [vulkano][rust-vulkano]'s
gen-2 tracker and [Tephra][cpp-tephra]'s access maps mirror syncval's per-range state;
[daxa][cpp-daxa] and [vuk][cpp-vuk] derive barriers such that RAW/WAR/WAW cannot occur
between declared accesses. Syncval itself remains the ground-truth oracle _below_ every
wrapper: a layer that emits sync2 barriers can be validated by it, which is how the
graph libraries test their compilers.

---

## Architecture patterns

### Simplified barrier vocabulary (named usage states)

**Definition.** A small closed enum of _named usage states_ — one value per way a
resource is actually used (color-attachment write, any-shader sampled read, transfer
source, present, …) — each of which expands by table lookup to a correct
`(stageMask, accessMask, imageLayout)` tuple, so a [barrier](#pipeline-barriers) is
declared as _previous accesses → next accesses_ instead of five hand-assembled
masks. The pattern's reference implementation is
[`simple_vulkan_synchronization`][thsvs-repo] by Tobias Hector — a Vulkan
specification author and the author of [`VK_KHR_synchronization2`][sync2-ext] — a
single-header C library ([`thsvs_simpler_vulkan_synchronization.h`][thsvs-header])
whose README states the move (verbatim, [README][thsvs-readme]):

> _"Rather than the complex maze of enums and bitflags in Vulkan - many combinations
> of which are invalid or nonsensical - this library collapses this to a much shorter
> list of 40 distinct usage types, and a couple of options for handling image
> layouts."_

`ThsvsAccessType` (e.g. `THSVS_ACCESS_COLOR_ATTACHMENT_WRITE`,
`THSVS_ACCESS_ANY_SHADER_READ_UNIFORM_BUFFER_OR_VERTEX_BUFFER`) _"defines all
potential resource usages in the Vulkan API"_ ([header][thsvs-header]);
`thsvsGetAccessInfo` expands one to the `{stageMask, accessMask, imageLayout}`
triple, and `thsvsCmdPipelineBarrier`/`thsvsCmdWaitEvents` wrap the raw commands.
Image layout handling collapses to three modes (`THSVS_IMAGE_LAYOUT_OPTIMAL`,
`_GENERAL`, `_GENERAL_AND_PRESENTATION`) — note the family resemblance to
[daxa][cpp-daxa]'s later layout abolition
([above](#image-layout-transitions)). The Rust port is Graham Wihlidal's
[`vk-sync`][vk-sync-rs] over [ash][rust-ash]: an `AccessType` enum
(`ColorAttachmentWrite`, `AnyShaderReadSampledImageOrUniformTexelBuffer`, …) consumed
by `GlobalBarrier`/`BufferBarrier`/`ImageBarrier` structs whose
`previous_accesses`/`next_accesses` are slices of `AccessType` — dormant upstream
since v0.1.6 (July 14, 2019) but kept current by community forks
([`vk-sync-fork`][vk-sync-fork]).

**Why it matters.** This is the **minimal type-safety move for device synchronization**:
it does not automate barrier _placement_ (unlike
[graphs](#render-graph--task-graph--frame-graph) or
[tracking](#auto-sync-via-per-resource-usage-tracking)) but makes barrier _contents_
correct by construction, collapsing an error-prone 5-tuple — where the invalid
combinations vastly outnumber the valid ones and a too-wide mask is a silent
performance bug — into one semantic value per endpoint. The cost is a constant table
lookup (CTFE-able in D: zero runtime cost); the residual constraints are themselves
enum-shaped (the C header asserts that a write access _"should appear on its own"_
— at most one write per barrier endpoint), and Hector accepts a deliberate
expressiveness loss: _"Execution only dependencies cannot be expressed"_
([README][thsvs-readme]), against the claim that the enum still _"expresses 99% of
what you'd actually ever want to do in practice."_ The survey's graph systems
internalized exactly this vocabulary as their declaration language:
[vuk][cpp-vuk]'s `Access` values each expand via `to_use(Access)` to a
`ResourceUse { stages, access, layout }` triple, and [daxa][cpp-daxa]'s task
attachments declare access-type + stage pairs — the named-usage-state enum is the
unit vocabulary a graph compiler consumes, with placement automated on top. The
survey's production instance is [NVRHI][cpp-nvrhi]: its D3D12-style `ResourceStates`
enum-class bitflags are the _entire_ synchronization vocabulary the API exposes,
lowered to batched `vkCmdPipelineBarrier2` calls — while [blade][rust-blade] marks
the opposite pole, abolishing the per-resource vocabulary altogether in favor of one
catch-all global barrier between passes. What the
pattern does **not** give is hazard freedom: it names a dependency edge correctly but
cannot ensure the edge _exists_ where needed or is ordered correctly — the
[RAW/WAR/WAW set](#hazards-rawwarwaw--syncvals-taxonomy) stays
[syncval][sync-validation]'s territory under manual placement.

### Render graph / task graph / frame graph

**Definition.** A frame's GPU work declared as a DAG of _passes/tasks_, each naming the
resources it reads and writes (and how), which a _graph compiler_ lowers to concrete
command-buffer recordings: barriers, [layout transitions](#image-layout-transitions),
[QFOT](#queue-family-ownership-transfer-qfot), semaphores, queue assignment, and
optionally pass reordering and transient-memory aliasing. The pattern was popularized as
"FrameGraph" by Frostbite ([O'Donnell, GDC 2017][framegraph-gdc]); the canonical Vulkan
treatment is [Hans-Kristian Arntzen's render-graph deep-dive][maister-rg], implemented
in his [Granite][cpp-granite] engine — the category's 2017 ancestor and a deep-dive of
this survey. "Render graph",
"task graph", and "frame graph" are used interchangeably in this tree; the surveyed
systems prefer "task graph" when the nodes are general (compute/transfer) rather than
render passes.

**Why it matters.** The graph is the field's answer to the fact that device-side
synchronization needs _whole-frame knowledge_: with every access declared up front, the
RAW/WAR/WAW [hazard set](#hazards-rawwarwaw--syncvals-taxonomy) is computable before
anything executes, and the cost is **amortized into a compile step** rather than paid
per command. The key axis among implementations is _when_ that compile happens:

| System                               | Declaration                                                         | Compile cadence                                                                              |
| ------------------------------------ | ------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| [Granite][cpp-granite] `RenderGraph` | String-named per-pass resource I/O, wired at graph build            | **`bake()` only on graph-topology change** — per-frame replay of precomputed physical passes |
| [daxa][cpp-daxa] `TaskGraph`         | Runtime attachment lists per task                                   | **Record once, execute many** — analysis front-loaded at `complete()`                        |
| [vuk][cpp-vuk]                       | In the pass's C++ type: `Arg<T, Access, tag>` via `VUK_IA`/`VUK_BA` | **Per submit**, mitigated by partial evaluation (executed nodes "morph into acquire")        |
| [vulkano-taskgraph][rust-vulkano]    | `node.buffer_access(id, AccessTypes)` per node                      | Compile once (`unsafe`, currently unvalidated), execute per frame against a `ResourceMap`    |
| [Tephra][cpp-tephra]                 | One **export** declaration per write (not per read)                 | Explicitly _"a render graph that does not reorder passes"_ — incremental, at job submit      |

A second hallmark is **virtual resources**: graph-time identities ([daxa][cpp-daxa]'s
`TaskBuffer`/`TaskImage`, [vulkano][rust-vulkano]'s phantom-typed `Id<T>` with a
virtual-resource tag bit) bound to physical resources only at execution, enabling
transient aliasing and N-frames-in-flight reuse. The pattern's cost is explicitness —
accesses are _declared, not inferred_, and a wrong declaration is a silent bug unless
the compiler validates it (vulkano's taskgraph currently does not; vuk validates at
graph-compile time with `std::source_location` provenance).

### Auto-sync via per-resource usage tracking

**Definition.** The inverse strategy: the wrapper _infers_ synchronization by recording,
for every buffer and image subresource, its most recent usage state, and diffing
state at each new use to emit the minimal barrier — effectively reimplementing
[syncval](#hazards-rawwarwaw--syncvals-taxonomy)'s `ResourceAccessState` model inline,
as a mandatory production component instead of a debug layer. [wgpu][rust-wgpu]'s
`wgpu-core/src/track` module states the job (verbatim, [`track/mod.rs`][wgpu-track]):

> _"These structures are responsible for keeping track of resource state, generating
> barriers where needednd [sic] making sure resources are kept alive until the trackers
> die."_

**Why it matters.** Tracking requires no up-front declarations (maximum ergonomics) but
pays **per-command runtime cost, every frame, with no whole-frame view** — it cannot
reorder or globally batch barriers. The survey's best-grounded overhead numbers come
from this pattern: wgpu's maintainers estimate 5–10% typical CPU overhead over raw hal
(~2× worst case, discussion #2080), and [vulkano][rust-vulkano]'s gen-2
`HashMap<Arc<Buffer>, RangeMap<DeviceSize, BufferState>>` per command buffer is the
measured cost that motivated its migration to a task graph. The field's trajectory is
the survey's clearest signal: vulkano moved from inferred tracking to declared graphs;
[Tephra][cpp-tephra] split the difference (track coarse job commands, never analyze
per-draw command lists, because that _"would have unacceptable performance overhead"_,
per its [README][tephra-readme]). [V-EZ][cpp-vez] marks the historical maximum —
per-command record-time inference with no opt-out, abandoned within six months —
while [blade][rust-blade], by wgpu's original author, deletes tracking outright in
favor of one global catch-all barrier. Full tracking survives in production in
[wgpu][rust-wgpu], as the price of WebGPU's declare-nothing portability contract,
and in [NVRHI][cpp-nvrhi] — the camp's production survivor — which tracks
D3D12-style named states per command list behind a graded per-resource opt-out
ladder.

### Bindless descriptors

**Definition.** Instead of binding small per-draw descriptor sets, the application
maintains one huge descriptor table (update-after-bind, via
[`VK_EXT_descriptor_indexing`][descriptor-indexing], core in 1.2) and shaders index into
it with plain integer IDs passed in push constants or buffers — "bindless" because
resources are never individually bound between draws.

**Why it matters.** Bindless converts descriptor management — a per-draw CPU cost and a
classic wrapper pain point — into array indexing, and it changes the _safety_ frontier:
the host-side type system loses sight of which resources a draw uses (the index lives in
GPU-visible memory), moving use-after-free from "validation layer catches it" to
unchecked GPU-side reads. [daxa][cpp-daxa] is the survey's bindless-by-default subject:
one update-after-bind mega-set indexed by the resource ID's index bits, README pledge
_"Bindless by default – no descriptor management nor bindings"_, with the implementation
noting the set _"does not need external sync given we use update after bind"_
([`src/impl_device.cpp`][daxa-impl-device]) — and, as the trade-off, _"GPU-side stale
bindless IDs are unchecked"_. [vuk][cpp-vuk] keeps classic per-draw descriptor hashing
with caches; [wgpu][rust-wgpu] supports bindless only partially (WebGPU limits).

### Deferred destruction

**Definition.** `vkDestroy*` while the GPU may still read the resource is UB, so safe
wrappers never destroy immediately: a "destroyed" resource enters a queue tagged with
the current GPU progress epoch (a [timeline-semaphore](#timeline-semaphores) value,
submission index, or frame counter), and is actually freed only once the device's
completed-value passes that epoch. [daxa][cpp-daxa] names the pattern memorably
([`include/daxa/device.hpp`][daxa-device-hpp], verbatim):

> _"a zombie lives until the gpu catches up to the point of zombification."_

**Why it matters.** Deferred destruction is the practical resolution of the temporal
half of handle safety — the half [RAII](#raii-vs-bracket-style-resource-management)
alone cannot deliver, because scope exit on the CPU says nothing about the GPU timeline.
Cost character: a per-destroy queue push plus a periodic collection sweep
(amortized, allocation-light), against the alternative of per-resource fence waits.
Every safety-oriented system surveyed implements a variant: daxa's per-type zombie
lists + `collect_garbage()`, [Tephra][cpp-tephra]'s job-ID-keyed destruction (at the
documented cost of over-extending unused resources' lifetimes), [Granite][cpp-granite]'s
frame-context-bucketed destruction queues gated on per-context fences,
[NVRHI][cpp-nvrhi]'s per-queue timeline `trackingSemaphore` consulted by a
once-per-frame `runGarbageCollection()`, [wgpu][rust-wgpu]'s
per-submission active lists freed when its timeline `Fence` passes,
[vulkano][rust-vulkano]'s queue-owned `Arc`s (gen 2) and per-`Flight` garbage queues
with hyaline-style reclamation (taskgraph), and [vuk][cpp-vuk]'s `DeviceFrameResource`
N-frame ring allocators. Thin bindings have none — in [ash][rust-ash],
[erupted][d-erupted], or [vulkan-zig][zig-vulkan-zig], destroying an in-flight resource
compiles silently — and [blade][rust-blade] and [V-EZ][cpp-vez] omit it by deliberate
choice (immediate explicit `destroy_*` / `vezDestroy*`).

### Memory allocation & VMA (out of the survey spine)

**Definition.** [Vulkan Memory Allocator][vma-repo] (VMA, from AMD's GPUOpen) is the
de-facto standard allocation layer above `vkAllocateMemory`: a single-header
(`vk_mem_alloc.h`), MIT-licensed C/C++ library — self-described simply as an
_"Easy to integrate Vulkan memory allocation library"_ ([README][vma-repo]) — that
handles memory-type selection from declared usage, block allocation and
suballocation (Vulkan caps `maxMemoryAllocationCount`, so per-resource
`vkAllocateMemory` does not scale), alignment and resource binding, dedicated
allocations, and defragmentation. Actively maintained (v3.4.0, June 4, 2026).

**Why it matters — and why it is not a spine dimension.** Nearly every surveyed
wrapper that owns resources delegates to VMA rather than reimplementing it:
[Tephra][cpp-tephra] is _"Built on VMA for all allocations"_, [daxa][cpp-daxa]'s
device struct holds a `VmaAllocator vma_allocator` member
([`src/impl_device.hpp`][daxa-impl-device-hpp]), [vulkanalia][rust-vulkanalia] ships
a dedicated `vulkanalia-vma` crate, and [haskell-vulkan][haskell-vulkan]'s generator
produces a sibling `VulkanMemoryAllocator` package in the same style. That consensus
is precisely why this catalog treats memory allocation as **out of the survey
spine**: it is a solved, delegated problem with one dominant implementation, and it
is orthogonal to the two axes the tree compares systems on — VMA suballocates
device memory but knows nothing of the GPU timeline (freeing an allocation the GPU
still reads remains the wrapper's problem, solved by
[deferred destruction](#deferred-destruction) above, not by the allocator) and
nothing of [hazards](#hazards-rawwarwaw--syncvals-taxonomy) (aliased transient
memory still needs the barriers a graph compiler or [syncval][sync-validation]
reasons about). Allocation therefore appears in the deep-dives only where it shapes
the binding surface — e.g. whether a wrapper's buffer-creation API takes VMA-style
usage declarations — not as a per-system analysis dimension.

---

## Type-system techniques

### Phantom / branded types

**Definition.** A type parameter (or generatively minted fresh type) that exists only at
compile time to make otherwise-identical representations un-mixable. _Phantom_ refers to
the unused parameter (Rust `PhantomData`, the [Haskell wiki's phantom types][phantom-haskell]);
_branding_ to using it as an identity tag.

**Why it matters.** Phantom typing is the cheapest safety in the survey — **always
zero-cost** (erased at compile time) — and the most widely deployed: distinct handle
newtypes are what separate `VkBuffer` from `VkImage` in every binding better than raw
`uint64_t`. Gradations observed:

- **Per-handle-type branding** (the baseline): [ash][rust-ash]'s `repr(transparent)`
  newtypes, [Vulkan-Hpp][cpp-vulkan-hpp]'s layout-asserted wrapper classes,
  [Tephra][cpp-tephra]'s `VkObjectHandle<T, VkObjectType>`, [vulkan-zig][zig-vulkan-zig]'s
  non-exhaustive `enum(u64)` handles, [olivine][ocaml-olivine]'s generative functors
  (a fresh abstract type per handle, minted by `Make()`), [vulkan4j][java-lwjgl-vulkan4j]'s
  record-per-handle. Negative data points: [erupted][d-erupted] handles degrade to
  `ulong` aliases on 32-bit; LWJGL leaves all non-dispatchable handles as bare `long`s.
- **Per-resource branding**: [vulkano-taskgraph][rust-vulkano]'s `Id<T>` slot-map IDs
  and [daxa][cpp-daxa]'s `TypedImageViewId<VIEW_TYPE>` brand IDs by kind (and daxa's by
  view type), though both stay copyable.
- **Per-value branding** (e.g. handle branded by its parent `VkDevice`) appears
  **nowhere in the survey** — wrong-device pairing is a runtime error even in vulkano.

A related zero-cost refinement: [olivine][ocaml-olivine]'s phantom singleton/plural
parameter on bitsets statically distinguishes "one flag" from "a union of flags" — the
`FlagBits`-vs-`Flags` distinction most bindings encode only nominally and
[vulkan-zig][zig-vulkan-zig] deliberately drops.

### Typestate

**Definition.** Encoding an object's protocol state in its _type_, so operations valid
only in some states simply do not exist on the others — typically by consuming a value
and returning a different type ([the typestate pattern in Rust][typestate-cliffle]).
Vulkan is full of latent typestate: command buffers (initial → recording → executable →
pending), swapchain images (acquired or not), [semaphores](#binary-semaphores)
(signaled/unsignaled), [image layouts](#image-layout-transitions).

**Why it matters.** Typestate is zero-cost and precisely shaped for Vulkan's protocols —
and the survey finds it **almost entirely unused**. The strongest sightings are partial:
[vulkano][rust-vulkano]'s `GpuFuture` combinator chains (nested concrete types encoding
the submission DAG — "typestate-ish", and being retired with the taskgraph migration)
and its marker-typed `AutoCommandBufferBuilder<L>`; [daxa][cpp-daxa]'s fluent task
builder is a weak form (order-suggesting, not type-enforced). No surveyed system types
begin/end recording, acquire/present, or semaphore signal/wait as state transitions.
The blocker is practical: typestate requires move semantics with use-after-move
prevention (affine types), which C++ lacks and which fights `Arc`-style sharing in Rust
wrappers. The gap is a standing invitation for a D design — `@disable this(this)` plus
DIP1000 gives the needed affine moves.

### Linear & affine types

**Definition.** [Substructural type systems][substructural]: a _linear_ value must be
consumed exactly once; an _affine_ value at most once. Rust's move semantics are affine
(drop is implicit); true linearity ("you _must_ call `vkDestroyBuffer`") exists in no
mainstream surveyed language.

**Why it matters.** Affinity is the natural encoding of two registry facts: every
`vkDestroy*`/`vkFree*` marks its handle [`externsync="true"`](#external-synchronization--externsync)
(destruction = consuming move), and one-shot protocols ([typestate](#typestate)
transitions) need at-most-once consumption. Observed usage is thin: Rust bindings
([ash][rust-ash], [vulkanalia][rust-vulkanalia]) make handles `Copy`, deliberately
forfeiting affine destruction; [vulkano][rust-vulkano] wraps everything in `Arc` (shared,
not affine) and recovers temporal safety via [deferred destruction](#deferred-destruction)
instead; [Vulkan-Hpp][cpp-vulkan-hpp]'s `UniqueHandle`/`raii` types are move-only but
C++ cannot reject use-after-move, so _"a dangling plain `vk::Buffer` copy of a destroyed
`UniqueHandle`/raii handle compiles and crashes exactly as in C"_ ([deep-dive][cpp-vulkan-hpp]).
The honest summary: **no surveyed system derives affine ownership from the registry's
destroy/externsync metadata** — each hand-picks where moves apply.

### RAII vs bracket-style resource management

**Definition.** Two idioms for pairing create with destroy. **RAII**: destruction in the
destructor of a scope-owned object ([cppreference: RAII][raii-cppref]) — used by
[Vulkan-Hpp][cpp-vulkan-hpp]'s `vk::raii` namespace and `UniqueHandle`s,
[Tephra][cpp-tephra]'s owning handles and `Lifeguard`, [vuk][cpp-vuk]'s `Unique<T>`,
[jcoronado][java-lwjgl-vulkan4j]'s `AutoCloseable` try-with-resources. **Bracket style**:
a higher-order function receives create/destroy and a continuation, guaranteeing the
destroy runs after the continuation — [haskell-vulkan][haskell-vulkan]'s generated
`with*` pairs (`withInstance` hands `bracket`/`ContT` the create/destroy pair;
[`Control.Exception.bracket`][bracket-haddock] is the canonical form), and
[Java's `Arena.ofConfined()`][java-lwjgl-vulkan4j] for host memory is bracket-shaped
(close the arena ⇒ dangling access throws).

**Why it matters.** Both give _deterministic, exception-safe release at scope exit_ at
zero or near-zero cost, and both share the same two limits: they bind lifetime to
**lexical scope** (awkward for resources whose lifetime is a frame ring or a cache), and
they release at **CPU scope exit**, which is wrong for anything the GPU still references
— which is why every RAII layer surveyed either documents the hazard
([Vulkan-Hpp][cpp-vulkan-hpp]: no temporal safety) or backs onto
[deferred destruction](#deferred-destruction) ([Tephra][cpp-tephra], [vuk][cpp-vuk]).
D offers both idioms natively (`struct` destructors + `@disable this(this)`;
`scope(exit)`); the design question for `sparkles:vulkan` is not RAII-vs-bracket but
what epoch check sits inside the release.

### Typed `pNext` structure chains

**Definition.** Vulkan extends create-info structs at runtime through `pNext` — a
`const void*` linked list whose legal links are declared per-struct in `vk.xml`'s
`structextends` attribute. A _typed chain_ promotes that attribute into the type system
so an illegal extension struct cannot be attached.

**Why it matters.** This is the **best-surviving piece of registry safety metadata** —
the positive counterpart to the [`externsync`](#external-synchronization--externsync)
finding — and a pure compile-time construct in every implementation (zero bytes, zero
instructions at runtime). The implementation spectrum:

| System                                             | Mechanism                                                                                      | Notable                                                                                                                                                |
| -------------------------------------------------- | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| [Vulkan-Hpp][cpp-vulkan-hpp]                       | `vk::StructureChain` tuple + 1,213 generated `StructExtends<X, Y>` traits + `static_assert`    | _"only chains which are valid according to the Vulkan specification can be created, which is verified at compile time"_ ([`docs/Usage.md`][hpp-usage]) |
| [ash][rust-ash]                                    | 1,217 generated `unsafe impl Extends<Base>` impls gating a safe `push()`                       | The one place ash promotes registry metadata into types                                                                                                |
| [vulkanalia][rust-vulkanalia]                      | `Extends*` marker traits + generated `InputChainStruct`/`OutputChainStruct` + chain iterators  | Only thin binding that types the **output** chain                                                                                                      |
| [haskell-vulkan][haskell-vulkan]                   | Type-level list `(a ::& es)` + closed type families `Extends`/`Extendss`; `Chain` is injective | Output-chain **inference**: pattern-matching a result infers the query chain                                                                           |
| [Silk.NET][csharp-silknet]                         | `IChainStart` / `IExtendsChain<TChain>` generic constraints                                    | Plus documented `*Any` escape methods for registry gaps                                                                                                |
| [vulkano][rust-vulkano]                            | **Abolished** — extension members flattened into create-info structs                           | Misuse-proof, but generic extensibility and coverage lag traded away                                                                                   |
| [vulkan-zig][zig-vulkan-zig], [erupted][d-erupted] | None — `pNext` stays `?*const anyopaque` / `const(void)*`                                      | The untyped floor                                                                                                                                      |

Remaining gaps even at the top of the table: duplicate-`sType` and chain-_order_ rules
are unchecked everywhere (only `allowduplicate` survives, in Vulkan-Hpp), and
heterogeneously-chained arrays force erasure (haskell-vulkan's existential
`SomeStruct`). For D, `structextends` → template constraints + CTFE is a direct mapping.

---

## Binding generation

### Binding generators & `vk.xml`

**Definition.** [`vk.xml`][vkxml] is the machine-readable Vulkan registry — every type,
command, extension, and a layer of semantic attributes (`len`, `optional`,
`successcodes`/`errorcodes`, `structextends`, `externsync`, handle `parent`,
`implicitexternsyncparams`) — from which the C headers, the spec's own tables, the
validation layers' thread-safety checks, and nearly every surveyed binding are
generated. Generator architectures observed: Khronos's own Python framework reused
([erupted][d-erupted]), bespoke offline generators committed with their output
([ash][rust-ash] in Rust, [vulkanalia][rust-vulkanalia] in Kotlin — regenerated nightly
by cron, [Vulkan-Hpp][cpp-vulkan-hpp] in C++ — released weekly per spec patch,
[haskell-vulkan][haskell-vulkan] — which also consumes the built spec asciidoc to embed
Valid Usage prose in Haddocks), build-time generation against the user's own `vk.xml`
([vulkan-zig][zig-vulkan-zig]'s generator binary run from `build.zig`, the closest
existing analogue to D CTFE), and **no generator at all** ([daxa][cpp-daxa],
[vuk][cpp-vuk], [Tephra][cpp-tephra], [wgpu][rust-wgpu] — hand-authored replacement
APIs, for which no registry metadata can survive by construction).

**Why it matters.** Generation determines both **coverage** (generated bindings track
the spec in days; hand-written layers curate a subset and lag) and **which safety
metadata survives** into the target type system — the survey's question 5. The observed
survival table is stark: `successcodes`/`errorcodes` survive almost universally (typed
results: ash/vulkanalia `Result` splits, [vulkan-zig][zig-vulkan-zig]'s per-command Zig
error sets, [olivine][ocaml-olivine]'s narrowed polymorphic variants — the natural D
target is `Expected!(T, VkResult)`); `structextends` survives in the
[typed-chain](#typed-pnext-structure-chains) systems; `len` survives as slices/views;
defaults from the registry survive uniquely well in D ([erupted][d-erupted]'s 666
`sType`-defaulted structs, via default field initializers); and
[`externsync`](#external-synchronization--externsync) survives **nowhere as types**.
Since the metadata is identical for all consumers, what survives is a _generator
choice_, not a language limit — the central premise behind a CTFE-driven
`sparkles:vulkan` generator.

---

## Concept → system matrix

Where each concept is load-bearing, at a glance (deep-dive links; the
[comparison][comparison] holds the full per-dimension matrix):

| Concept                                                                 | Compile-time-only users                                                                                                                                             | Runtime-cost users                                                                                                                                                                                                                          | Absent / negative data points                                                                         |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| [`externsync` in types](#external-synchronization--externsync)          | —                                                                                                                                                                   | [vulkano][rust-vulkano] (mutexes, `!Send`)                                                                                                                                                                                                  | every generated binding                                                                               |
| [Pipeline barriers, automated](#pipeline-barriers)                      | —                                                                                                                                                                   | [daxa][cpp-daxa] · [vuk][cpp-vuk] · [Tephra][cpp-tephra] · [wgpu][rust-wgpu] · [vulkano][rust-vulkano] · [Granite][cpp-granite] (graph only) · [NVRHI][cpp-nvrhi] · [blade][rust-blade] (global catch-all) · [V-EZ][cpp-vez] (historical)   | thin bindings (manual)                                                                                |
| [Named usage states](#simplified-barrier-vocabulary-named-usage-states) | [vuk][cpp-vuk] (`Access` → `ResourceUse`) · [daxa][cpp-daxa] (attachment access types)                                                                              | [`vk-sync`][vk-sync-rs] / [`thsvs`][thsvs-repo] (constant lookup) · [NVRHI][cpp-nvrhi] (`ResourceStates`, the entire sync vocabulary)                                                                                                       | thin bindings (raw stage/access masks); abolished in [blade][rust-blade]                              |
| [Timeline-semaphore epochs](#timeline-semaphores)                       | —                                                                                                                                                                   | [daxa][cpp-daxa] · [vuk][cpp-vuk] · [Tephra][cpp-tephra] · [wgpu][rust-wgpu] · [vulkano][rust-vulkano]                                                                                                                                      | thin bindings (raw)                                                                                   |
| [Render/task graph](#render-graph--task-graph--frame-graph)             | [vuk][cpp-vuk] (`Access` in the pass type)                                                                                                                          | [daxa][cpp-daxa] · [vulkano-taskgraph][rust-vulkano] · [Granite][cpp-granite] (`bake()`, the 2017 ancestor) · ([Tephra][cpp-tephra], partial)                                                                                               | JVM ecosystem ([survey][java-lwjgl-vulkan4j]); all of D ([erupted][d-erupted])                        |
| [Usage tracking](#auto-sync-via-per-resource-usage-tracking)            | —                                                                                                                                                                   | [wgpu][rust-wgpu] · [vulkano][rust-vulkano] gen-2 · [Tephra][cpp-tephra] (job tier) · [NVRHI][cpp-nvrhi] (per command list) · [V-EZ][cpp-vez] (per command, historical)                                                                     | graph-only systems; deleted by design in [blade][rust-blade]                                          |
| [Bindless](#bindless-descriptors)                                       | —                                                                                                                                                                   | [daxa][cpp-daxa] (default)                                                                                                                                                                                                                  | [wgpu][rust-wgpu] (partial), classic binding elsewhere                                                |
| [Deferred destruction](#deferred-destruction)                           | —                                                                                                                                                                   | [daxa][cpp-daxa] · [Tephra][cpp-tephra] · [wgpu][rust-wgpu] · [vulkano][rust-vulkano] · [vuk][cpp-vuk] · [Granite][cpp-granite] (frame-context-bucketed, fence-gated) · [NVRHI][cpp-nvrhi] (`trackingSemaphore` + `runGarbageCollection()`) | thin bindings; deliberately absent in [blade][rust-blade] · [V-EZ][cpp-vez]                           |
| [Phantom/branded handles](#phantom--branded-types)                      | [ash][rust-ash] · [Vulkan-Hpp][cpp-vulkan-hpp] · [Tephra][cpp-tephra] · [olivine][ocaml-olivine] · [vulkan-zig][zig-vulkan-zig] · [vulkano][rust-vulkano] (`Id<T>`) | —                                                                                                                                                                                                                                           | [erupted][d-erupted] (32-bit), LWJGL non-dispatchable                                                 |
| [Typestate](#typestate)                                                 | [vulkano][rust-vulkano] (`GpuFuture`, partial)                                                                                                                      | —                                                                                                                                                                                                                                           | everyone else — the survey's largest unused-technique gap                                             |
| [Typed `pNext` chains](#typed-pnext-structure-chains)                   | [Vulkan-Hpp][cpp-vulkan-hpp] · [ash][rust-ash] · [vulkanalia][rust-vulkanalia] · [haskell-vulkan][haskell-vulkan] · [Silk.NET][csharp-silknet]                      | —                                                                                                                                                                                                                                           | [vulkan-zig][zig-vulkan-zig] · [erupted][d-erupted]; abolished in [vulkano][rust-vulkano]             |
| [RAII/bracket](#raii-vs-bracket-style-resource-management)              | [Vulkan-Hpp][cpp-vulkan-hpp] · [Tephra][cpp-tephra] · [haskell-vulkan][haskell-vulkan] · [jcoronado][java-lwjgl-vulkan4j]                                           | (deferred-destruction backstops above)                                                                                                                                                                                                      | [ash][rust-ash] · [vulkanalia][rust-vulkanalia] · [vulkan-zig][zig-vulkan-zig] · [erupted][d-erupted] |

---

## Sources

- [Vulkan specification — Threading Behavior][spec-threading] ([`chapters/fundamentals.adoc`][fundamentals-adoc] source)
- [Vulkan specification — Synchronization and Cache Control][spec-sync]
- [`xml/vk.xml` — the machine-readable registry][vkxml]
- [`VK_KHR_synchronization2`][sync2-ext] · [`VK_KHR_timeline_semaphore`][timeline-sem] · [`VK_EXT_descriptor_indexing`][descriptor-indexing]
- [`docs/syncval_usage.md` — hazard taxonomy][syncval-usage]
- [`simple_vulkan_synchronization` (Tobias Hector)][thsvs-repo] · [`thsvs_simpler_vulkan_synchronization.h`][thsvs-header] · [`vk-sync-rs` (Graham Wihlidal)][vk-sync-rs] · [`vk-sync-fork` on lib.rs][vk-sync-fork]
- [Vulkan Memory Allocator (GPUOpen)][vma-repo] · [`src/impl_device.hpp` — daxa's `VmaAllocator` member][daxa-impl-device-hpp]
- [FrameGraph: Extensible Rendering Architecture in Frostbite (GDC 2017)][framegraph-gdc] · [Render graphs and Vulkan — a deep dive (Maister)][maister-rg]
- [`wgpu-core/src/track/mod.rs` — usage-tracking module docs][wgpu-track]
- [`include/daxa/device.hpp` — zombie lifetime comment][daxa-device-hpp] · [`src/impl_device.cpp` — update-after-bind note][daxa-impl-device]
- [`src/IRPasses.cpp` — vuk sync lowering / merged layouts][vuk-irpasses]
- [Vulkan-Hpp `docs/Usage.md` — `StructureChain` compile-time validity][hpp-usage] · [Tephra README — render-graph positioning][tephra-readme]
- [RAII (cppreference)][raii-cppref] · [`Control.Exception.bracket` (Haddock)][bracket-haddock] · [The typestate pattern in Rust (Cliffle)][typestate-cliffle] · [Substructural type systems (Wikipedia)][substructural] · [Phantom types (Haskell wiki)][phantom-haskell]
- Related: [sync-validation][sync-validation] · [comparison][comparison] · [survey index][index] · all per-system deep-dives linked throughout

<!-- References -->

[spec-threading]: https://docs.vulkan.org/spec/latest/chapters/fundamentals.html#fundamentals-threadingbehavior
[spec-sync]: https://docs.vulkan.org/spec/latest/chapters/synchronization.html
[fundamentals-adoc]: https://github.com/KhronosGroup/Vulkan-Docs/blob/main/chapters/fundamentals.adoc
[vkxml]: https://github.com/KhronosGroup/Vulkan-Docs/blob/main/xml/vk.xml
[sync2-ext]: https://registry.khronos.org/vulkan/specs/latest/man/html/VK_KHR_synchronization2.html
[timeline-sem]: https://registry.khronos.org/vulkan/specs/latest/man/html/VK_KHR_timeline_semaphore.html
[descriptor-indexing]: https://registry.khronos.org/vulkan/specs/latest/man/html/VK_EXT_descriptor_indexing.html
[syncval-usage]: https://github.com/KhronosGroup/Vulkan-ValidationLayers/blob/main/docs/syncval_usage.md
[thsvs-repo]: https://github.com/Tobski/simple_vulkan_synchronization
[thsvs-readme]: https://github.com/Tobski/simple_vulkan_synchronization/blob/main/README.md
[thsvs-header]: https://github.com/Tobski/simple_vulkan_synchronization/blob/main/thsvs_simpler_vulkan_synchronization.h
[vk-sync-rs]: https://github.com/gwihlidal/vk-sync-rs
[vk-sync-fork]: https://lib.rs/crates/vk-sync-fork
[vma-repo]: https://github.com/GPUOpen-LibrariesAndSDKs/VulkanMemoryAllocator
[daxa-impl-device-hpp]: https://github.com/Ipotrick/Daxa/blob/master/src/impl_device.hpp
[framegraph-gdc]: https://www.gdcvault.com/play/1024612/FrameGraph-Extensible-Rendering-Architecture-in
[maister-rg]: https://themaister.net/blog/2017/08/15/render-graphs-and-vulkan-a-deep-dive/
[wgpu-track]: https://github.com/gfx-rs/wgpu/blob/trunk/wgpu-core/src/track/mod.rs
[daxa-device-hpp]: https://github.com/Ipotrick/Daxa/blob/master/include/daxa/device.hpp
[daxa-impl-device]: https://github.com/Ipotrick/Daxa/blob/master/src/impl_device.cpp
[vuk-irpasses]: https://github.com/martty/vuk/blob/master/src/IRPasses.cpp
[hpp-usage]: https://github.com/KhronosGroup/Vulkan-Hpp/blob/main/docs/Usage.md
[tephra-readme]: https://github.com/Dolkar/Tephra/blob/main/README.md
[raii-cppref]: https://en.cppreference.com/w/cpp/language/raii
[bracket-haddock]: https://hackage.haskell.org/package/base/docs/Control-Exception.html#v:bracket
[typestate-cliffle]: https://web.archive.org/web/20260706064825/https://cliffle.com/blog/rust-typestate/
[substructural]: https://en.wikipedia.org/wiki/Substructural_type_system
[phantom-haskell]: https://wiki.haskell.org/Phantom_type
[sync-validation]: ./sync-validation.md
[sync-validation-encodes]: ./sync-validation.md#what-vkxml-encodes-externsync-and-its-four-value-forms
[comparison]: ./comparison.md
[index]: ./index.md
[cpp-vulkan-hpp]: ./cpp-vulkan-hpp.md
[rust-ash]: ./rust-ash.md
[rust-vulkanalia]: ./rust-vulkanalia.md
[zig-vulkan-zig]: ./zig-vulkan-zig.md
[d-erupted]: ./d-erupted.md
[rust-vulkano]: ./rust-vulkano.md
[haskell-vulkan]: ./haskell-vulkan.md
[ocaml-olivine]: ./ocaml-olivine.md
[csharp-silknet]: ./csharp-silknet.md
[java-lwjgl-vulkan4j]: ./java-lwjgl-vulkan4j.md
[cpp-daxa]: ./cpp-daxa.md
[cpp-vuk]: ./cpp-vuk.md
[cpp-tephra]: ./cpp-tephra.md
[rust-wgpu]: ./rust-wgpu.md
[cpp-granite]: ./cpp-granite.md
[cpp-nvrhi]: ./cpp-nvrhi.md
[rust-blade]: ./rust-blade.md
[cpp-vez]: ./cpp-vez.md
