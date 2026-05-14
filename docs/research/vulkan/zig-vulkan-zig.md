# Zig: `vulkan-zig`

## Mechanism: `vk.xml`-Driven Generation + Typed Dispatch Wrappers

`vulkan-zig` is primarily a generator that translates Vulkan XML registries (`vk.xml`, optionally `video.xml`) into a Zig module (`vk.zig`).

At a high level, the pipeline is:

1. Parse Vulkan XML into an internal registry model.
2. Merge features + extensions into core declarations (including enum field merging).
3. Fix known bitflag/registry edge cases.
4. Render Zig declarations and wrappers.
5. Parse the generated Zig AST and format it before writing output.

This is not a runtime abstraction layer in the `vulkano`/`Tephra` sense; it is a build-time code generator that produces a strongly typed, mostly zero-cost API surface.

## Compile-Time/Build-Time Generation Model

`vulkan-zig` can be used either as:

- A standalone CLI (`vulkan-zig-generator <vk.xml> <out.zig>`), or
- A build integration in `build.zig` where the binding is generated and imported as a module.

Design consequences:

- Bindings track the exact Vulkan registry revision supplied by the user.
- Generation is reproducible and vendorable (`vk.zig` can be checked in).
- The resulting API is static from the compiler's point of view; no reflection/macro runtime is required.

## Typed API Surface

### Handle Typing

Handles are emitted as non-exhaustive Zig enums, preserving nominal type distinctions between handle classes.

- Dispatchable handles are backed by `usize`.
- Non-dispatchable handles are backed by `u64`.

This intentionally preserves type safety for non-dispatchable handles even on 32-bit targets.

### Flags/Bitfields

Rather than separate `FlagBits` and `Flags` APIs, `vulkan-zig` emits packed struct bitfields of booleans plus mixin helpers (`toInt`, `fromInt`, `merge`, `contains`, etc.).

Notable tradeoff: places that semantically want "exactly one bit" may still accept the full packed flag struct, so correctness there is left to caller discipline.

### Pointer and Parameter Metadata

Parsing tracks pointer metadata from XML where possible:

- Optionality (`?`)
- Constness
- Shape (single item, many, zero-terminated)
- Length relationships (`len=`) to identify buffer/count pairings

This metadata is then used to synthesize safer wrapper signatures, but quality is constrained by accuracy of upstream registry annotations.

### Dispatch Tables and Wrappers

Generated API has layered surfaces:

- Function pointer typedefs (`Pfn*`) matching Vulkan ABI.
- Dispatch structs (`BaseDispatch`, `InstanceDispatch`, `DeviceDispatch`) with optional function pointers.
- Wrapper structs (`BaseWrapper`, `InstanceWrapper`, `DeviceWrapper`) that expose Zig-idiomatic methods.
- Proxy wrappers (`InstanceProxy`, `DeviceProxy`, etc.) that pair a handle + wrapper for ergonomic call sites.

Wrapper transformations include:

- Converting out parameters into return values.
- Converting `VkResult` error codes into Zig error sets.
- Coalescing pointer+length parameters into slices, with debug checks for shared lengths.
- Normalizing many names into Zig style (`vkCreateInstance` -> `createInstance`).

## Error Model Integration

`VkResult` handling is a core strength of the wrapper layer:

- Failure `VkResult` values become Zig typed errors (`error.OutOfDeviceMemory`, etc.).
- Unknown/unmapped errors are still representable (`error.Unknown`).
- Some wrappers return richer aggregate structs when multiple outputs must be returned.

This creates idiomatic Zig error propagation (`try`, `catch`) without losing Vulkan result semantics.

## Synchronization and Lifetime Boundaries

`vulkan-zig` deliberately does not attempt to enforce Vulkan synchronization/resource-state correctness beyond typed signatures.

### What Is Enforced

- ABI-correct function signatures.
- Typed handles/flags/enums/structs.
- Better parameter forms (slices, returned out-values, error sets).

### What Is Not Enforced

- No automatic pipeline barrier inference.
- No command/resource hazard tracking.
- No queue ownership/layout transition state machine.
- No host-thread external synchronization model.
- No automatic destruction/RAII graph for resources.

### Important Safety Edge

Wrapper `load` eagerly attempts to load function pointers, but unavailable commands remain `null`. Calling through missing entries can crash/UB; extension/version support checks are the user's responsibility.

## Practical Characterization

`vulkan-zig` is best understood as an advanced typed binding generator with ergonomic wrappers, not as a full safety runtime.

Compared to higher-level systems like Rust `vulkano` or C++ `Tephra`:

- It strongly improves call-site correctness and ergonomics.
- It does not own execution/synchronization policy.
- It leaves most semantic Vulkan correctness (ordering, hazards, lifetime discipline) to application architecture.

## Transferable Ideas For A D Binding

- Preserve a strict separation between generated low-level ABI surface and optional high-level policy layer.
- Generate error translations and out-parameter lifting automatically from registry metadata.
- Use generated typed dispatch tables (base/instance/device) to keep dynamic loading explicit.
- Encode flags as richer types, but add explicit single-bit APIs where Vulkan semantics require exclusivity.
- Treat sync/lifetime as a separate layer (typestate graph or submission DAG), not as a side effect of plain wrappers.
