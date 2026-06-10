# Synchronization machinery & registry metadata (Cross-cutting)

The vocabulary anchor for the survey's synchronization question: what the Vulkan specification and `vk.xml` registry actually say about host-side external synchronization, how [`VK_KHR_synchronization2`][sync2-ext] reshaped the device-side barrier model, and which hazards the Khronos [synchronization validation layer][syncval-usage] (_syncval_) catches at runtime — i.e. the ground truth every typed wrapper in this tree ([vulkano][vulkano], [daxa][daxa], [vuk][vuk], [Tephra][tephra], [wgpu][wgpu], …) is trying to encode statically.

| Field         | Value                                                                                                                                                                                         |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | C API + XML registry (spec toolchain in Python/AsciiDoc; validation layers in C++)                                                                                                            |
| License       | Apache-2.0 / CC-BY 4.0 ([Vulkan-Docs][repo-docs]); Apache-2.0 ([Vulkan-ValidationLayers][repo-vvl])                                                                                           |
| Repository    | [KhronosGroup/Vulkan-Docs][repo-docs] · [KhronosGroup/Vulkan-ValidationLayers][repo-vvl]                                                                                                      |
| Documentation | [Vulkan spec, Threading Behavior][spec-threading] · [registry.adoc][registry-doc] · [syncval docs][syncval-usage]                                                                             |
| Category      | Thematic (cross-cutting)                                                                                                                                                                      |
| First release | Vulkan 1.0 / `vk.xml` schema, February 2016; syncval phase 1 shipped in SDK 1.2.135 (April 2020)                                                                                              |
| Latest state  | `vk.xml` on `main` (June 2026): 402 `externsync` attributes, 7 `implicitexternsyncparams` blocks; syncval validates submit-time and present in [`VK_LAYER_KHRONOS_validation`][syncval-usage] |

**Last reviewed:** June 11, 2026

> [!NOTE]
> This page deliberately covers **no single library**. It establishes the three layers of ground truth — registry metadata, spec threading rules, and runtime hazard detection — that the per-library deep-dives reference. For the shared device-side vocabulary (barriers, semaphores, fences, timeline semaphores, events) see [concepts][concepts]; for the cross-library synthesis see the [comparison][comparison].

---

## Overview

### What it solves

Vulkan has **two distinct synchronization domains**, and conflating them is the most common source of confusion in wrapper design:

1. **Host synchronization (threading rules).** Which CPU threads may call which commands on which handles concurrently. This is a _data-race_ question, fully specified by the spec's [Threading Behavior chapter][spec-threading] and machine-encoded in `vk.xml` as [`externsync`](#what-vkxml-encodes-externsync-and-its-four-value-forms) attributes. It is exactly the problem Rust's `&mut`/`&` distinction, D's `@safe` + [DIP1000][dip1000], and mutexes address.
2. **Device synchronization (execution & memory dependencies).** Ordering GPU work via pipeline barriers, semaphores, fences, events, and render-pass dependencies, plus image layout transitions and queue-family ownership transfers. This is a _happens-before_ question on the GPU timeline; no mainstream type system expresses it directly, which is why wrappers reach for [runtime tracking][vulkano] or [render graphs][daxa] instead.

The registry encodes domain 1 precisely and domain 2 barely at all — a fact with direct consequences for every generated binding in this tree: a generator can mechanically derive "this call needs `&mut CommandPool`" from `vk.xml`, but it cannot derive "this image needs a layout transition before sampling" from anything machine-readable. Domain 2 correctness is checked only dynamically, by [syncval](#synchronization-safety-what-syncval-checks-at-runtime).

### Design philosophy

The spec's threading model is a deliberate trade of safety for scalability — locks are pushed out of the driver and onto the application. From [`chapters/fundamentals.adoc`][fundamentals-adoc], § Threading Behavior (verbatim):

> _"Vulkan is intended to provide scalable performance when used on multiple host threads. All commands support being called concurrently from multiple threads, but certain parameters, or components of parameters are defined to be **externally synchronized**. This means that the caller must guarantee that no more than one thread is using such a parameter at a given time."_

And the consequence of getting it wrong, from the same file's [Valid Usage section][fundamentals-adoc]:

> _"The core layer assumes applications are using the API correctly. Except as documented elsewhere in the Specification, the behavior of the core layer to an application using the API incorrectly is undefined, and may include program termination."_

In other words: external synchronization violations are plain undefined behavior, with no driver-side detection. Everything a wrapper or validation layer does about it is reconstructed from the registry metadata described next.

---

## How it works

### Binding generation & API coverage

The registry pipeline is the single source of truth for three downstream consumers, and tracing what each consumes shows which safety metadata _survives_ generation:

| Consumer                                                                        | Generator                                                                                    | What it extracts from `vk.xml`                                                                                                                                                   |
| ------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The spec's host-sync tables                                                     | [`scripts/hostsyncgenerator.py`][hostsyncgen] (Vulkan-Docs)                                  | `externsync` params, externally-synchronized list elements, `implicitexternsyncparams` → three generated AsciiDoc tables included by [`fundamentals.adoc`][fundamentals-adoc]    |
| Thread-safety validation layer                                                  | [`scripts/generators/thread_safety_generator.py`][threadsafetygen] (Vulkan-ValidationLayers) | `externsync` on params and struct members → generated `StartWriteObject`/`FinishWriteObject`/`StartReadObject` counter checks around every call                                  |
| Language bindings ([ash][ash], [erupted][erupted], [vulkan-hpp][vulkan-hpp], …) | each binding's own generator                                                                 | **Usually nothing.** Most binding generators read names, types, `len`, `optional`, `successcodes`/`errorcodes`, and `pNext` `structextends` — and drop `externsync` on the floor |

The spec itself is generated the same way: `fundamentals.adoc` does not hand-list externally synchronized parameters, it includes them —

```asciidoc
Parameters of commands that are externally synchronized are listed below.

include::{generated}/hostsynctable/parameters.adoc[]
```

([`chapters/fundamentals.adoc`][fundamentals-adoc]) — so the registry attribute is _definitionally_ complete: if a parameter is externally synchronized, it is `externsync`-tagged, or the spec's own table would be wrong. This makes `externsync` uniquely trustworthy input for a binding generator, and its near-universal neglect by bindings (only [vulkanalia][vulkanalia]'s docs and the thread-safety layer consume it; see the [comparison][comparison]) is one of this survey's central findings.

#### What `vk.xml` encodes: `externsync` and its four value forms

The schema documentation, [`registry.adoc`][registry-doc] (verbatim, § attr:externsync on `param` tags):

> _"A value of `\"true\"` indicates that this parameter (e.g. the object a handle refers to, or the contents of an array a pointer refers to) is modified by the command, and is not protected against modification in multiple application threads. … Parameters which do not have an attr:externsync attribute are assumed to not require external synchronization."_

Four value forms appear in the current `vk.xml` (402 `externsync` attribute instances on `main` as of June 11, 2026):

| Form                              | Meaning                                                                                                               | Example (real lines from [`xml/vk.xml`][vkxml])                                                                 |
| --------------------------------- | --------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `externsync="true"`               | The whole parameter (or each array element) is exclusively owned for the call's duration                              | `vkBeginCommandBuffer`'s `commandBuffer`; `vkFreeCommandBuffers`' `commandPool` **and** `pCommandBuffers` array |
| `externsync="maybe"`              | Conditionally external-sync; the exact rule lives in prose Valid Usage                                                | `vkQueueSubmit`'s `queue` (conditional since [`VK_KHR_internally_synchronized_queues`][internally-sync-queues]) |
| `externsync="<expression>"`       | Only a _member reached through_ the parameter is externally synchronized                                              | `vkSetDebugUtilsObjectNameEXT`: `externsync="pNameInfo-&gt;objectHandle"`                                       |
| `externsync="maybe:<expression>"` | Conditional member-path form (added to the schema May 7, 2025 per [`registry.adoc`][registry-doc]'s revision history) | `vkUpdateDescriptorSets`: `externsync="maybe:pDescriptorWrites[].dstSet"`                                       |

Since the 1.4-era schema, `externsync="true"` also appears on **struct members**, moving the requirement to where the handle actually flows:

```xml
<!-- xml/vk.xml — VkCommandBufferAllocateInfo -->
<member externsync="true"><type>VkCommandPool</type>          <name>commandPool</name></member>
```

([`xml/vk.xml`][vkxml]) — so `vkAllocateCommandBuffers` no longer carries a parameter-path expression; the pool inside `pAllocateInfo` is tagged directly. The same pattern marks `VkSwapchainCreateInfoKHR::surface`/`oldSwapchain` and `VkPresentInfoKHR::pWaitSemaphores`/`pSwapchains`.

#### Implicit external synchronization

The subtlest host-sync rule is not on any parameter at all. From [`fundamentals.adoc`][fundamentals-adoc] (verbatim):

> _"In addition, there are some implicit parameters that need to be externally synchronized. For example, when a `commandBuffer` parameter needs to be externally synchronized, it implies that the `commandPool` from which that command buffer was allocated also needs to be externally synchronized."_

`vk.xml` encodes these as `implicitexternsyncparams` blocks (7 on `main`) — free-text AsciiDoc, _not_ machine-checkable structure:

```xml
<!-- xml/vk.xml — vkBeginCommandBuffer -->
<implicitexternsyncparams>
    <param>the sname:VkCommandPool that pname:commandBuffer was allocated from</param>
</implicitexternsyncparams>
```

([`xml/vk.xml`][vkxml]). Other instances: `vkDeviceWaitIdle` implicitly owns _"all sname:VkQueue objects created from pname:device"_, and `vkResetDescriptorPool` owns _"any sname:VkDescriptorSet objects allocated from pname:descriptorPool"_. Because these are prose, a generator that wants them (as the [thread-safety layer][threadsafetygen] does for command pools) must special-case them — a key obstacle for any "derive the ownership model from the registry" plan, including a future `sparkles:vulkan`.

### Handle lifetime & ownership model

`vk.xml` encodes a **parentage tree** for handles (`<type category="handle" parent="VkDevice">…`), which bindings universally use for destructor plumbing, but the registry says nothing structured about _lifetime validity_ — "do not destroy a `VkBuffer` while a submitted command buffer references it" exists only as prose Valid Usage. Two ownership notions matter for this page:

- **Host ownership for a call's duration** — exactly the `externsync` data above. Destruction commands are the canonical case: every `vkDestroy*`/`vkFree*` marks the destroyed handle `externsync="true"`, which is why Rust wrappers can map destruction to moving/dropping an owned value and D can map it to a non-copyable wrapper consumed by `destroy`.
- **Queue-family ownership of resources** — a _device-side_ concept (a `VK_SHARING_MODE_EXCLUSIVE` resource's contents are only valid on one queue family at a time; transfer requires a matching release/acquire barrier pair on the two queues). It is _not_ expressed in the registry at all: `VkBufferMemoryBarrier2::srcQueueFamilyIndex`/`dstQueueFamilyIndex` are plain `uint32_t`s. Wrappers either ignore it ([ash][ash], [erupted][erupted]), track it at runtime ([vulkano][vulkano]), or absorb it into a graph compiler ([daxa][daxa], [vuk][vuk]).

A registry-faithful binding therefore gets handle parentage and call-duration exclusivity "for free", and everything about temporal validity (in-flight references, queue-family residency, swapchain image acquisition state) from nowhere.

### Synchronization safety

#### The device-side primitive set (the vocabulary the wrappers automate)

Five primitives, in increasing scope — each defined in the spec's [synchronization chapter][spec-sync] and elaborated in [concepts][concepts]:

| Primitive                                                                     | Scope                                                           | What typed wrappers do with it                                                                                |
| ----------------------------------------------------------------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| Pipeline barrier (`vkCmdPipelineBarrier2`)                                    | Within a queue, between commands                                | Auto-inserted by render graphs ([daxa][daxa], [vuk][vuk]) or tracked state ([vulkano][vulkano], [wgpu][wgpu]) |
| Event (`vkCmdSetEvent2`/`vkCmdWaitEvents2`)                                   | Split barrier within a queue                                    | Almost universally _not_ wrapped safely; the long tail                                                        |
| Binary semaphore                                                              | Between queues / with the presentation engine                   | Typed as part of submit/present builders                                                                      |
| Timeline semaphore ([`VK_KHR_timeline_semaphore`][timeline-sem], core in 1.2) | Cross-queue + host, monotonically increasing `uint64_t` payload | The natural "frame counter" primitive; maps cleanly to host futures/awaitables                                |
| Fence                                                                         | Queue → host                                                    | Wrapped as a waitable token gating resource reuse                                                             |

#### Why `VK_KHR_synchronization2` simplified the model

The original 1.0 barrier API had three structural defects that sync2 (core since Vulkan 1.3) fixed:

1. **Stage and access masks were specified apart.** `vkCmdPipelineBarrier` took `srcStageMask`/`dstStageMask` as _command_ arguments while access masks sat in per-barrier structs — so one stage scope had to cover heterogeneous barriers, and the stage↔access pairing rules ("`VK_ACCESS_SHADER_READ_BIT` is only meaningful with a shader stage") were implicit. From the [Vulkan Guide chapter][sync2-guide] (verbatim): _"One main change with the extension is to have pipeline stages and access flags now specified together in memory barrier structures."_ `VkDependencyInfo` now carries arrays of `VkMemoryBarrier2`/`VkBufferMemoryBarrier2`/`VkImageMemoryBarrier2`, each with its own `srcStageMask`+`srcAccessMask`+`dstStageMask`+`dstAccessMask` — making the (stage, access) pair the atomic unit, which is exactly the unit syncval validates and the unit a typed wrapper should expose.
2. **The 32-bit flag spaces ran out.** Per the [extension description][sync2-ext]: _"the `VkAccessFlags2KHR` type was created with a 64-bit range"_ (and likewise `VkPipelineStageFlags2`), with fine-grained stages (`COPY`, `RESOLVE`, `BLIT`, `CLEAR`, separate `INDEX_INPUT`…) replacing overloaded catch-alls. Because C lacks 64-bit enums, these are `static const uint64_t` values — there is no `VkPipelineStageFlagBits2` enum type, a wrinkle every binding generator must special-case.
3. **Special-case semantics were removed.** `TOP_OF_PIPE`/`BOTTOM_OF_PIPE` are deprecated in favor of `VK_PIPELINE_STAGE_2_NONE` and `ALL_COMMANDS`; `vkCmdSetEvent2` carries its own `VkDependencyInfo` (per the [guide][sync2-guide]: _"`vkCmdSetEvent2KHR`, unlike `vkCmdSetEvent`, has the ability to add barriers"_), removing the set/wait stage-mask matching trap; and `vkQueueSubmit2` replaces `VkSubmitInfo`'s three parallel arrays + `pWaitDstStageMask` with per-semaphore `VkSemaphoreSubmitInfo` (stage mask, timeline value, and device index per semaphore op).

For this survey the lesson is architectural: sync2 moved the API toward _self-contained, per-barrier dependency records_ — precisely the shape a render-graph compiler emits and a typed builder can validate field-by-field. Every modern wrapper in this tree ([daxa][daxa], [vuk][vuk], [tephra][tephra]) targets sync2 exclusively.

#### What syncval checks at runtime

The synchronization validation layer (part of [`VK_LAYER_KHRONOS_validation`][syncval-usage], enabled via `VK_VALIDATION_VALIDATE_SYNC=1` or VkConfig's Synchronization preset) detects **hazards**: pairs of memory accesses to overlapping resource ranges without a sufficient dependency chain between them. The hazard taxonomy from [`docs/syncval_usage.md`][syncval-usage] (definitions verbatim):

| Hazard                   | Definition                                                                                                                                                               |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| RAW (Read-after-write)   | _"Occurs when a subsequent operation uses the result of a previous operation without waiting for the result to be completed."_                                           |
| WAR (Write-after-read)   | _"Occurs when a subsequent operation overwrites a memory location read by a previous operation before that operation is complete (requires only execution dependency)."_ |
| WAW (Write-after-write)  | _"Occurs when a subsequent operation writes to the same set of memory locations (in whole or in part) being written by a previous operation."_                           |
| WRW (Write-racing-write) | _"Occurs when unsynchronized subpasses/queues perform writes to the same set of memory locations."_                                                                      |
| RRW (Read-racing-write)  | _"Occurs when unsynchronized subpasses/queues perform read and write operations on the same set of memory locations."_                                                   |

The detection model ([`docs/syncval_design.md`][syncval-design]) is per-resource-range state tracking: every buffer/image subresource range maps into a unified "fake base address" space held in interval trees, and each range carries a `ResourceAccessState` — the most recent write, the set of reads since that write, and the barriers applied to each. Stage/access pairs are normalized into 79 distinct valid combinations so barrier scopes can be tested exactly. The core economy of the design, verbatim from [`syncval_design.md`][syncval-design]:

> _"When detecting memory access hazards, synchronization validation considers only the most recent access (MRA) for comparison. All prior hazards are assumed to have been reported."_

Scope has grown in phases: within a command buffer (phase 1, 2020), then queue-submit-time validation across command buffers, semaphores, fences, and present via `QueueBatchContext` (which carries forward access history across submissions). Known limitations listed in [`syncval_usage.md`][syncval-usage] include no aliased-memory analysis, limited indirect-draw/dispatch buffer content awareness, and no component-level granularity.

> [!IMPORTANT]
> Note the division of labor: the **thread-safety layer** (generated from `externsync`) catches _host_ races; **syncval** (hand-written, ~zero registry input) catches _device_ hazards. The statically-typed wrappers in this tree split the same way — host exclusivity maps onto `&mut`/linear ownership essentially for free, while device hazards require either runtime tracking that mirrors syncval's `ResourceAccessState` ([vulkano][vulkano], [wgpu][wgpu]) or a graph compiler that makes hazards unrepresentable ([daxa][daxa], [vuk][vuk]).

### Type-system techniques

**Not applicable directly — and that absence is the finding.** The C API has no type-level distinction between an internally synchronized parameter and an externally synchronized one: `vkBeginCommandBuffer(VkCommandBuffer, …)` and `vkGetCommandPool…`-style read-only accesses take the same plain dispatchable-handle typedef. All four `externsync` value forms, the implicit-parameter prose, and the queue-family ownership rules are erased at the C ABI.

What the metadata _could_ support, mapped to mechanisms surveyed in the sibling deep-dives:

| Registry fact                                                | Faithful type-system encoding                                                                                      | Who does it                                                                                      |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------ |
| `externsync="true"` param                                    | `&mut` / `inout` exclusive borrow, or consuming `self` for destroy                                                 | [vulkano][vulkano] (hand-mapped), no generator does it mechanically                              |
| `externsync="maybe"`                                         | Cannot be typed without modeling the condition; needs runtime check or conservative `&mut`                         | Nobody; even docs rarely surface it                                                              |
| `externsync="maybe:pDescriptorWrites[].dstSet"`              | Per-element exclusive borrow inside a shared slice — beyond mainstream borrow checkers                             | Nobody                                                                                           |
| `implicitexternsyncparams` (pool of a command buffer)        | Lifetime/parent coupling: recording handle borrows the pool (`&mut` pool ⇒ commands), or pool-scoped phantom brand | [vulkano][vulkano] runtime-locks the pool; D could use DIP1000 `scope` + a pool-branded recorder |
| `vkQueueSubmit` keeps `pSubmits` resources alive until fence | Affine "in-flight" tokens / timeline-semaphore-indexed epochs                                                      | [vulkano][vulkano], [wgpu][wgpu] (runtime refcount/epoch); graph libs hide it                    |

For a future `sparkles:vulkan`, the actionable shape is: `externsync` is the one piece of safety metadata that is complete, machine-readable, and CTFE-consumable — a D generator can read `vk.xml` at compile time and emit `ref`/`scope`-qualified, `@safe` wrappers whose signatures encode exclusivity, with `implicitexternsyncparams` handled by a hand-curated table (there are only 7).

### Overhead & escape hatches

The entire machinery on this page is **zero-cost in production by construction**: layers are external shared libraries interposed only when enabled, and `externsync` enforcement does not exist at all unless the thread-safety layer is loaded. The cost ledger:

| Mechanism            | When active    | Cost character                                                                                                                                                                                                                                         |
| -------------------- | -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Spec threading rules | Always         | Zero — they are _obligations_, not checks; violation is UB                                                                                                                                                                                             |
| Thread-safety layer  | Dev/debug only | Per-call atomic counter bumps (`StartWriteObject`/`StartReadObject`) per `externsync` param                                                                                                                                                            |
| Syncval              | Dev/debug only | Heavy: interval-tree range maps + `ResourceAccessState` per range, per command; the [usage doc][syncval-usage] recommends the Synchronization preset, which _"will turn off other non-sync validation … making Synchronization Validation run faster"_ |
| Sync2 itself         | Always         | Zero vs. 1.0 barriers; purely an API reshape (drivers map both to the same hardware operations)                                                                                                                                                        |

The "escape hatch" question inverts here: raw Vulkan _is_ the escape hatch every wrapper exposes. The relevant design point for wrappers is that syncval remains usable below them — a wrapper that emits valid sync2 barriers gets syncval's hazard analysis on its output for free, which is how [daxa][daxa] and [vuk][vuk] test their graph compilers, and how a `sparkles:vulkan` test suite could validate generated synchronization without GPU-vendor-specific tooling.

### Error handling & validation integration

The core API reports almost nothing about synchronization mistakes: there is no `VK_ERROR_RACE_CONDITION`. The reporting path is entirely layer-based:

- Layers deliver findings through [`VK_EXT_debug_utils`][debug-utils] messenger callbacks; syncval messages name the hazard type, both conflicting accesses (command, stage, access), the resource range, and the synchronization that _was_ applied — with structured key-value "extra properties" for programmatic filtering/suppression.
- `vk.xml` does encode per-command `successcodes`/`errorcodes` (visible on every `<command>` element in [`xml/vk.xml`][vkxml]), and bindings consume these well — it is the registry safety metadata with the _best_ survival rate, typically becoming `Result`/`Expected` types ([ash][ash], [vulkanalia][vulkanalia], [haskell-vulkan][haskell-vulkan]; the D mapping to `Expected!(T, VkResult)` is direct).
- `VK_ERROR_VALIDATION_FAILED` exists in the registry's error-code lists but is layer-originated, not driver-originated.

The asymmetry is stark: result codes (machine-readable, universally consumed) vs. synchronization rules (machine-readable for host, prose for device, almost never consumed). A binding that treats `externsync` with the same seriousness bindings already treat `errorcodes` would be genuinely novel.

---

## Strengths

- **`externsync` is complete and trustworthy** — the spec's own host-sync tables are generated from it, so it cannot drift from the normative text; 402 attribute instances cover every externally synchronized parameter and struct member.
- **The schema is expressive where it counts**: boolean, conditional (`maybe`), member-path, and conditional-member-path forms distinguish "whole handle", "only this nested handle", and "only under documented conditions".
- **Sync2 made barriers compositional**: self-contained per-barrier (stage, access) records in `VkDependencyInfo` are the right compilation target for graphs and the right validation unit for types.
- **Syncval is a precise dynamic oracle**: the RAW/WAR/WAW/WRW/RRW taxonomy plus most-recent-access tracking gives wrappers and applications a ground-truth checker that now spans command buffers, submits, semaphores, and present.
- **Clean layering**: zero production cost; all checking is opt-in and out-of-process from the driver's perspective.

## Weaknesses

- **Device-side synchronization is invisible to the registry.** Layout transitions, queue-family ownership, in-flight resource lifetime, and required barrier placement exist only in prose Valid Usage — no generator can derive them, which is why every "safe" wrapper hand-builds its sync model.
- **`implicitexternsyncparams` is free-text AsciiDoc**, so the most architecturally important host rule (command buffer ⇒ its pool) needs hand-curated handling in every consumer.
- **`maybe` is unresolvable statically**: the condition lives in prose, forcing consumers to choose between over-locking and ignoring it.
- **Syncval is debug-only and late**: hazards surface at run time on the developer's machine, only on exercised code paths — exactly the gap static typing aims to close.
- **Syncval's own blind spots** (aliasing, indirect buffers, descriptor-indexed access patterns) mean even dynamic validation is not a complete oracle.
- **64-bit sync2 flags aren't C enums**, a recurring generator wart (no `VkPipelineStageFlagBits2` type to hang type safety on).

## Key design decisions and trade-offs

| Decision                                                            | Rationale                                                                                    | Trade-off                                                                                 |
| ------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Externally synchronized parameters instead of driver-internal locks | _"Scalable performance when used on multiple host threads"_ — no hidden mutexes on hot paths | All host races become application UB; safety must be rebuilt above the API                |
| Encode host-sync rules as `externsync` in `vk.xml`                  | Single source of truth; spec tables and thread-safety layer generated from it                | Device-side rules got no equivalent encoding; bindings mostly ignore the attribute anyway |
| `implicitexternsyncparams` as prose                                 | Some rules ("the pool this buffer came from") don't fit an attribute grammar                 | The most important ownership-coupling rule is not machine-checkable                       |
| Sync2: per-barrier (stage, access) records                          | Removes implicit pairing rules and shared stage scopes; matches hardware reality             | A second, parallel barrier API; 32→64-bit flags break the C enum model                    |
| Syncval: most-recent-access tracking, not full history              | Bounded memory; _"all prior hazards are assumed to have been reported"_                      | Cascading hazards can hide behind the first report; needs iterative fix-and-rerun         |
| All validation in optional layers                                   | Zero production overhead; one validation codebase for all drivers                            | No always-on safety net; correctness depends on developer discipline and test coverage    |

---

## Sources

- [Vulkan specification — Threading Behavior][spec-threading] ([`chapters/fundamentals.adoc`][fundamentals-adoc] source)
- [Vulkan registry schema documentation (`registry.adoc`)][registry-doc] — `externsync`, `implicitexternsyncparams` definitions and revision history
- [`xml/vk.xml` — the machine-readable registry][vkxml] (counts and excerpts from `main`, June 11, 2026)
- [`scripts/hostsyncgenerator.py` — spec host-sync table generator][hostsyncgen]
- [`scripts/generators/thread_safety_generator.py` — thread-safety layer generator][threadsafetygen]
- [`VK_KHR_synchronization2` extension description][sync2-ext] · [Vulkan Guide chapter][sync2-guide]
- [`docs/syncval_usage.md` — hazard taxonomy, scope, limitations][syncval-usage]
- [`docs/syncval_design.md` — `ResourceAccessState`, MRA model, `QueueBatchContext`][syncval-design]
- [Vulkan specification — Synchronization and Cache Control chapter][spec-sync]
- [`VK_KHR_timeline_semaphore`][timeline-sem] · [`VK_EXT_debug_utils`][debug-utils] · [`VK_KHR_internally_synchronized_queues` proposal][internally-sync-queues]
- Related: [concepts][concepts] · [comparison][comparison] · [vulkano (Rust)][vulkano] · [daxa (C++)][daxa] · [vuk (C++)][vuk] · [Tephra (C++)][tephra] · [wgpu (Rust)][wgpu] · [ash (Rust)][ash] · [vulkanalia (Rust)][vulkanalia] · [vulkan (Haskell)][haskell-vulkan] · [Vulkan-Hpp (C++)][vulkan-hpp] · [erupted (D)][erupted] · [survey index][index]

<!-- References -->

[repo-docs]: https://github.com/KhronosGroup/Vulkan-Docs
[repo-vvl]: https://github.com/KhronosGroup/Vulkan-ValidationLayers
[spec-threading]: https://docs.vulkan.org/spec/latest/chapters/fundamentals.html#fundamentals-threadingbehavior
[spec-sync]: https://docs.vulkan.org/spec/latest/chapters/synchronization.html
[fundamentals-adoc]: https://github.com/KhronosGroup/Vulkan-Docs/blob/main/chapters/fundamentals.adoc
[registry-doc]: https://github.com/KhronosGroup/Vulkan-Docs/blob/main/registry.adoc
[vkxml]: https://github.com/KhronosGroup/Vulkan-Docs/blob/main/xml/vk.xml
[hostsyncgen]: https://github.com/KhronosGroup/Vulkan-Docs/blob/main/scripts/hostsyncgenerator.py
[threadsafetygen]: https://github.com/KhronosGroup/Vulkan-ValidationLayers/blob/main/scripts/generators/thread_safety_generator.py
[sync2-ext]: https://registry.khronos.org/vulkan/specs/latest/man/html/VK_KHR_synchronization2.html
[sync2-guide]: https://github.com/KhronosGroup/Vulkan-Guide/blob/main/chapters/extensions/VK_KHR_synchronization2.adoc
[syncval-usage]: https://github.com/KhronosGroup/Vulkan-ValidationLayers/blob/main/docs/syncval_usage.md
[syncval-design]: https://github.com/KhronosGroup/Vulkan-ValidationLayers/blob/main/docs/syncval_design.md
[timeline-sem]: https://registry.khronos.org/vulkan/specs/latest/man/html/VK_KHR_timeline_semaphore.html
[debug-utils]: https://registry.khronos.org/vulkan/specs/latest/man/html/VK_EXT_debug_utils.html
[internally-sync-queues]: https://github.com/KhronosGroup/Vulkan-Docs/blob/main/proposals/VK_KHR_internally_synchronized_queues.adoc
[dip1000]: https://dlang.org/spec/function.html#scope-parameters
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
[vulkano]: ./rust-vulkano.md
[daxa]: ./cpp-daxa.md
[vuk]: ./cpp-vuk.md
[tephra]: ./cpp-tephra.md
[wgpu]: ./rust-wgpu.md
[ash]: ./rust-ash.md
[vulkanalia]: ./rust-vulkanalia.md
[haskell-vulkan]: ./haskell-vulkan.md
[vulkan-hpp]: ./cpp-vulkan-hpp.md
[erupted]: ./d-erupted.md
