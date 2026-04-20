# C++: `Vulkan-Hpp` & `Tephra`

## Mechanism: Generated Strong Types + Optional RAII + Compile-Time Chain Validation

`Vulkan-Hpp` is a generated, near-zero-overhead C++ layer over Vulkan C. Its design goal is not to hide Vulkan, but to replace common classes of mistakes with compile-time type checks and safer defaults.

This makes it a strong reference point for designing a safer D API: it demonstrates where static typing helps immediately, and where additional higher-level abstractions are still needed.

## What It Makes Safer by Construction

### 1) Enum and Flag Correctness

- C enums become scoped `enum class` values in `vk::`, preventing accidental implicit integer conversions and cross-enum comparisons.
- Flag-bit pairs are modeled as `vk::Flags<FlagBitsEnum>` aliases (for example, `vk::ImageUsageFlags`), which allows bitwise composition only from the corresponding `...FlagBits` type.
- Invalid mixes like image-usage bits with pipeline-stage bits are rejected at compile time.

Practical effect: many "looks valid, compiles, breaks later" bugs move to immediate compiler errors.

### 2) Struct Initialization Safety (`sType`, `pNext`, and field shape)

- Vulkan-Hpp struct wrappers pre-initialize `sType` correctly per struct type.
- `pNext` defaults to `nullptr` and is positioned safely in constructors.
- Constructor signatures mirror struct fields, so missing or wrong-typed fields are caught by C++ type checking and IDE tooling.

Practical effect: eliminates frequent C-style initialization hazards (`sType` mismatch, stale copied init blocks, half-initialized create infos).

### 3) `pNext` Chain Safety with `vk::StructureChain`

`vk::StructureChain<T0, T1, ...>` is one of Vulkan-Hpp's most safety-relevant features:

- Validates at compile time that each chained struct is permitted to extend the anchor struct.
- Enforces multiplicity rules for structs that may/may not appear multiple times in a chain.
- Owns storage for chained structs, avoiding dangling-pointer patterns common with manual stack-built chains.
- Supports runtime toggling via `unlink<T>()` / `relink<T>()` without rebuilding the entire chain object.

Practical effect: converts "`void*` chain correctness" from runtime convention to compile-time contract.

### 4) Handle Type Safety and C Interop Boundaries

- Handles are wrapped in distinct C++ types (`vk::Buffer`, `vk::Image`, etc.), preventing accidental cross-handle assignment.
- 64-bit builds permit efficient interop casts by default.
- 32-bit builds intentionally tighten conversions unless explicitly configured (`VULKAN_HPP_TYPESAFE_CONVERSION`) to avoid integer-handle confusion.

Practical effect: safer API surface while preserving explicit escape hatches for low-level interop.

## RAII in Vulkan-Hpp: Three Models, Different Tradeoffs

Vulkan-Hpp offers multiple ownership styles instead of one universal wrapper:

- `vk::Handle` (plain wrappers): typed but manually managed lifetimes.
- `vk::UniqueHandle`: move-only ownership (similar to `std::unique_ptr`) with automatic destruction.
- `vk::SharedHandle`: shared ownership including parent retention to preserve destruction order.
- `vk::raii::*`: object-oriented RAII handle classes with their own dispatch model.

Important caveats for safer API design:

- `UniqueHandle` is safer than raw handles but not fully zero-cost (deleters often carry parent/allocator state).
- `SharedHandle` keeps parent objects alive correctly, but shared handles themselves are not magically thread-safe.
- `vk::raii` improves ergonomics, yet Vulkan ownership edge cases still leak through (for example command buffers vs command pool lifetime ordering, descriptor-set free rules requiring `eFreeDescriptorSet`).

Practical effect: RAII removes a large class of leaks and teardown bugs, but cannot fully erase Vulkan's object graph constraints.

## Compile-Time/Static Tooling Hooks Worth Copying

Beyond obvious strong typing, Vulkan-Hpp exposes useful compile-time hooks:

- Type traits (`CppType`, `isVulkanHandleType`, handle-associated type constants) for generic metaprogramming.
- `[[nodiscard]]` on many operations to catch ignored results early.
- Optional static assertion coverage (`vulkan_static_assertions.hpp`) for ABI/layout assumptions.
- `constexpr`-friendly trait helpers in selected utility headers (e.g., format traits).

These are not full typestate, but they create a robust "static analysis substrate" for higher-level wrappers.

## What Vulkan-Hpp Deliberately Does Not Solve

For safer high-level API design, this is as important as what it _does_ solve:

- No automatic resource hazard tracking or barrier synthesis (unlike graph schedulers such as Tephra).
- No global compile-time encoding of command-buffer state transitions.
- No full host-thread data-race model encoded in the type system.

In other words, Vulkan-Hpp is a strong safer-foundation layer, not a complete correctness framework for synchronization and scheduling.

## Design Takeaways for a Safer D Vulkan Layer

### Keep

- Spec-driven generated wrappers as the baseline to minimize drift from Vulkan.
- Strongly-typed enums/flags/handles as non-optional defaults.
- A typed `pNext` chain builder with compile-time extension validation (Vulkan-Hpp-style `StructureChain` is a proven pattern).
- RAII-capable ownership wrappers for common lifetimes.

### Improve Beyond Vulkan-Hpp

- Add typestate or UDA/DbI-verified command recording states for render-pass and dynamic rendering legality.
- Add explicit resource-access declarations and auto-barrier planning at a higher abstraction tier.
- Encode host synchronization expectations in API shape where possible (borrow-like access phases, thread-affinity tags, or capability tokens).

### Preserve Escape Hatches

- Keep low-level raw Vulkan interop available for expert users and extension bring-up.
- Make safety layers composable, so users can opt into stronger guarantees incrementally.

## Why This Matters for the D Effort

`Vulkan-Hpp` shows that a generated binding can significantly reduce misuse without sacrificing performance or closeness to Vulkan semantics. For a D-first design, it should be treated as the "safe baseline," while the differentiator should be stronger compile-time state modeling and higher-level synchronization automation on top.

## Tephra: Job/Resource/Synchronization Model

`Tephra` sits at a different layer than `Vulkan-Hpp`: it is a higher-level execution and synchronization framework that keeps Vulkan command power available, but uses runtime graph/hazard tracking to remove a large share of manual barrier work.

### 1) Job-Centric Execution Model

- Work is authored as `tp::Job` objects, then enqueued and submitted to `tp::DeviceQueue` queues.
- Command recording is intentionally two-tiered: high-level job commands define resource operations and pass structure, while low-level draw/dispatch are recorded in `ComputeList` / `RenderList` command lists.
- Internally, the job command stream is replayed during submit in two passes: first to resolve synchronization/barriers, second to emit Vulkan commands with those barriers.

Practical effect: users get explicit control over ordering and pass structure, while Tephra automates barrier synthesis from declared accesses.

### 2) Resource Access Contract

- Compute and render passes require explicit access declarations (`BufferComputeAccess`, `ImageComputeAccess`, `BufferRenderAccess`, `ImageRenderAccess`) with `ComputeAccessMask` / `RenderAccessMask`.
- Contract rule: pass declarations must cover all accesses performed inside the pass unless that access is read-only and previously exported.
- `cmdExportResource` declares future read-only usages and can optionally export visibility to another queue type.
- Export validity is stateful: later incompatible accesses invalidate the export and require re-export.

Practical effect: Tephra does not parse low-level command lists for hazards; it relies on a user-provided access interface plus export metadata.

### 3) Internal GPU Synchronization (Within Queue/Job History)

- Tephra tracks per-resource subresource access history in runtime access maps (`BufferAccessMap`, `ImageAccessMap`).
- On each new command access, it intersects prior ranges, derives needed dependencies, and extends/reuses barriers (`BarrierList`) rather than regenerating everything blindly.
- Tracking granularity is subresource-level: byte ranges for buffers and layer/mip/aspect ranges for images.
- Access maps persist per queue, so synchronization naturally carries across previously submitted jobs on that queue.
- Barrier optimization policy is explicit: minimize barriers and place them late, but do not reorder user commands.

Practical effect: correctness is driven by runtime dependency analysis over recorded accesses, not a compile-time typestate machine.

### 4) Cross-Queue Synchronization and Ownership Transfer

- Execution ordering across queues is user-driven via `JobSemaphore` waits/signals (timeline semaphore model).
- Data visibility/ownership across queues requires exports in addition to semaphore waits.
- Internally, queue-to-queue export state is broadcast and consumed at submit (`CrossQueueSync`), with queue-family ownership transfer barriers inserted when required.
- Tephra's docs explicitly treat this as queue-local access maps plus message passing of exported ranges/layout state.

Practical effect: semaphore ordering and resource visibility are separate concerns; Tephra helps with the latter only when the export contract is followed.

### 5) Host and External Synchronization Boundary

- Host readback is deliberately explicit: waiting on job completion alone is insufficient; resource data must be exported with `ReadAccess::Host` before mapped host reads are guaranteed up-to-date.
- Presentation has the same pattern: presented images must be exported for present access.
- For operations performed outside Tephra, `vkCmdImportExternalResource` updates Tephra's internal synchronization state using explicit Vulkan stage/access/layout metadata.
- Queue ownership and external synchronization details are still an explicit user responsibility at the interop boundary.

Practical effect: Tephra strongly models internal GPU dependencies, but intentionally does not hide host/external sync obligations.

### 6) Safety Boundary: Type-Encoded vs Runtime-Tracked

| Concern                          | Type/API-level safety                                                                                 | Runtime tracking / user contract                                                                       |
| -------------------------------- | ----------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Access vocabulary correctness    | Strong enum masks (`ReadAccess`, `ComputeAccess`, `RenderAccess`) prevent category mixups             | Actual correctness still depends on declaring complete real usage                                      |
| Pass interface shape             | Typed pass setup structs force explicit resource+mask declarations                                    | Tephra cannot infer undeclared accesses inside command lists                                           |
| Export mask formation            | `DescriptorBinding::getReadAccessMask()` yields compatible read masks under single-layout export rule | Export lifetime/invalidation is tracked dynamically as commands execute                                |
| Command ordering legality        | No typestate `CommandBuffer<State>`-style compile-time sequencing                                     | Job state transitions and usage constraints are runtime-managed (`recording -> enqueued -> submitted`) |
| Hazard/barrier correctness       | Not compile-time proven                                                                               | Access maps + barrier synthesis at submit time                                                         |
| Cross-queue visibility/ownership | Queue types and semaphore types are strongly represented                                              | Requires runtime semaphore waits + exports + ownership transfer handling                               |
| Host visibility                  | Typed `ReadAccess::Host` token                                                                        | Must export + wait; docs state waiting alone is insufficient                                           |

Summary: Tephra is a hybrid model. Type-level API design reduces accidental misuse and structures declarations, but safety-critical synchronization correctness is primarily achieved by runtime hazard tracking over declared accesses.

## Tephra Design Takeaways for a D Binding

- Keep Tephra's separation between execution ordering (semaphores) and data visibility (exports/access metadata); this separation maps well to Vulkan's real model and avoids implicit magic.
- Consider Tephra's runtime access-map algorithm as the baseline for automatic barriers, then add D compile-time assistance to reduce "undeclared access" risk (UDAs/DbI-generated pass access manifests).
- Preserve a first-class interop boundary similar to `vkCmdImportExternalResource`; high-level safety layers must still compose with raw Vulkan and extension workflows.
- If stronger static safety is a goal, target the gap Tephra intentionally leaves open: compile-time enforcement that low-level pass code cannot access resources outside declared capability sets.

## Vulkan-Hpp Primary Sources

- <https://github.com/KhronosGroup/Vulkan-Hpp>
- <https://github.com/KhronosGroup/Vulkan-Hpp/blob/main/docs/Usage.md>
- <https://github.com/KhronosGroup/Vulkan-Hpp/blob/main/docs/Handles.md>
- <https://github.com/KhronosGroup/Vulkan-Hpp/blob/main/docs/VkRaiiProgrammingGuide.md>
- <https://developer.nvidia.com/blog/preferring-compile-time-errors-over-runtime-errors-with-vulkan-hpp/>

## Tephra Primary Sources

- <https://github.com/Dolkar/Tephra>
- <https://dolkar.github.io/Tephra/user-guide.html>
- <https://github.com/Dolkar/Tephra/blob/main/include/tephra/job.hpp>
- <https://github.com/Dolkar/Tephra/blob/main/include/tephra/device.hpp>
- <https://github.com/Dolkar/Tephra/blob/main/include/tephra/descriptor.hpp>
- <https://github.com/Dolkar/Tephra/blob/main/include/tephra/compute.hpp>
- <https://github.com/Dolkar/Tephra/blob/main/include/tephra/render.hpp>
- <https://github.com/Dolkar/Tephra/blob/main/src/tephra/job/accesses.hpp>
- <https://github.com/Dolkar/Tephra/blob/main/src/tephra/job/barriers.hpp>
- <https://github.com/Dolkar/Tephra/blob/main/src/tephra/job/job_compile.cpp>
- <https://github.com/Dolkar/Tephra/blob/main/src/tephra/device/queue_state.cpp>
- <https://github.com/Dolkar/Tephra/blob/main/src/tephra/device/cross_queue_sync.hpp>
