# C#: `SharpVk`

## Mechanism: Spec-Driven Code Generation + Thin Typed Wrappers

`SharpVk` is generated from Vulkan registry data, then emitted as C# wrapper classes/structs over interop handles and marshalled native calls.

The generator pipeline is explicit (`LoadXmlStage` -> `SpecParserStage` -> `CollationStage` -> `GenerationStage` -> `EmissionStage`), with `VkXmlCache` sourcing `vk.xml` from Khronos and caching it locally.

## Generated Type-Safety Approach

### 1) Vulkan-spec-driven typing, not handwritten bindings

- `VkXmlCache` pulls/parses `vk.xml` and `TypeElementReader`/`CommandElementReader` consume Vulkan type/command metadata.
- `TypeCollator` maps Vulkan categories into output patterns (handle, enum, marshalled struct, etc.), including `Parent` and `structextends` information.

This gives SharpVk broad API coverage and consistency, but safety strength is capped by C#'s runtime model and by metadata quality in `vk.xml`.

### 2) Nominal handle typing and parent-aware wrappers

- Handles are emitted as C# classes wrapping distinct interop handle types.
- Generated handle classes carry a typed `parent` reference when Vulkan declares parent relationships.
- Public APIs consume typed wrappers (`Buffer`, `Semaphore`, `Fence`, etc.) instead of raw integers/pointers.

This prevents common "wrong handle type" mistakes at compile time.

### 3) Strong enum/flags typing

- Enum generation applies `[System.Flags]` to bitmask enums.
- Vulkan flag domains become distinct C# enum types, so stage/access/layout arguments are type-separated.

This improves call-site correctness relative to untyped integer constants.

### 4) Method-shape generation and marshaling discipline

- Generated methods marshal values through typed structs and `ArrayProxy<T>` instead of raw pointer arithmetic at call sites.
- `ArrayProxy<T>` supports null/single/array forms with implicit conversions, reducing call-site overload noise.

### 5) `pNext` handling via generated extension parameters

- For many `*CreateInfo`/`*Info`-style APIs, method signatures expose optional typed extension parameters.
- Generator rules (`VerbInfoMemberPattern`, `NextExtensionMemberPattern`) build `Next` chains internally during marshaling.

This is ergonomic compared to manual `void* pNext` management, but extension chaining support is not uniform for every struct path.

## Resource Lifetime And Disposal Semantics

### 1) Deterministic disposal through `IDisposable`

- Handle wrappers that have Vulkan `Destroy*` commands implement `IDisposable`.
- Generated `Dispose()` simply calls `Destroy(...)`.
- `Instance` and `Device` also implement `IDisposable` and expose explicit `Destroy`.

### 2) Ownership context is represented, not enforced

- Child handles store their parent wrapper and use parent raw handles when invoking destruction commands.
- This encodes Vulkan object hierarchy in API shape.

### 3) No automatic lifetime guards/finalization policy

- Generated wrappers do not implement `SafeHandle`, finalizers, or disposed-state guards in handle methods.
- Correct lifetime ordering remains a user responsibility.

### 4) No GPU in-flight lifetime tracking

- There is no built-in equivalent of Rust `GpuFuture`-style ownership tracking.
- CPU object disposal is not coupled to queue submission completion.
- Users must enforce this via fences/semaphores and explicit waits.

## Synchronization Ergonomics

### 1) Typed but explicit queue submission

- `Queue.Submit(...)` consumes typed `SubmitInfo` values with `WaitSemaphores`, `WaitDestinationStageMask`, `CommandBuffers`, and `SignalSemaphores`.
- `Queue.WaitIdle()` and `Device.WaitIdle()` are direct wrappers.

This improves API readability, but synchronization remains fully explicit.

### 2) Barrier/event APIs stay low-level

- `CommandBuffer.WaitEvents(...)` and `CommandBuffer.PipelineBarrier(...)` are exposed with typed barrier structs.
- A partial convenience overload exists for a common single-image `PipelineBarrier` pattern.

SharpVk does not infer hazards or auto-insert barriers.

### 3) Timeline semaphore coverage exists, but ergonomics are mixed

- Timeline primitives are present (`Semaphore.GetCounterValue()`, `Device.WaitSemaphores(...)`, `Device.SignalSemaphore(...)`, `TimelineSemaphoreSubmitInfo`).
- However, generated `SubmitInfo` marshaling sets `Next = null`, so timeline submit chaining is not modeled there directly.

## Design Tradeoffs For D Research

1. A generator-driven API can deliver excellent Vulkan surface coverage and consistent type domains quickly.
2. Handle/enum typing and parent-aware wrappers prevent many category errors cheaply.
3. `IDisposable` wrappers alone are insufficient for GPU-safe lifetime guarantees; higher-level in-flight tracking must be a separate layer.
4. Typed synchronization arguments improve correctness, but without policy-level abstractions users still face raw Vulkan synchronization complexity.
5. Generated, typed extension parameters are a strong ergonomics pattern worth reusing for D `pNext` handling.

## Sources Used

- Repository overview: <https://github.com/FacticiusVir/SharpVk>
- Generator pipeline and spec ingestion:
  - <https://github.com/FacticiusVir/SharpVk/blob/master/src/SharpVk.Generator/Program.cs>
  - <https://github.com/FacticiusVir/SharpVk/blob/master/src/SharpVk.Generator/VkXmlCache.cs>
  - <https://github.com/FacticiusVir/SharpVk/blob/master/src/SharpVk.Generator/Specification/TypeElementReader.cs>
  - <https://github.com/FacticiusVir/SharpVk/blob/master/src/SharpVk.Generator/Specification/CommandElementReader.cs>
  - <https://github.com/FacticiusVir/SharpVk/blob/master/src/SharpVk.Generator/Collation/TypeCollator.cs>
- Handle/enum generation and disposal behavior:
  - <https://github.com/FacticiusVir/SharpVk/blob/master/src/SharpVk.Generator/Generation/HandleGenerator.cs>
  - <https://github.com/FacticiusVir/SharpVk/blob/master/src/SharpVk.Generator/Emission/HandleEmitter.cs>
  - <https://github.com/FacticiusVir/SharpVk/blob/master/src/SharpVk.Generator/Emission/EnumEmitter.cs>
  - <https://github.com/FacticiusVir/SharpVk/blob/master/src/SharpVk/Buffer.gen.cs>
  - <https://github.com/FacticiusVir/SharpVk/blob/master/src/SharpVk/Instance.gen.cs>
  - <https://github.com/FacticiusVir/SharpVk/blob/master/src/SharpVk/Device.gen.cs>
- `pNext` / extension-chain handling:
  - <https://github.com/FacticiusVir/SharpVk/blob/master/src/SharpVk.Generator/Generation/Marshalling/NextExtensionMemberPattern.cs>
  - <https://github.com/FacticiusVir/SharpVk/blob/master/src/SharpVk.Generator/Generation/Marshalling/VerbInfoMemberPattern.cs>
- Synchronization surfaces:
  - <https://github.com/FacticiusVir/SharpVk/blob/master/src/SharpVk/Queue.gen.cs>
  - <https://github.com/FacticiusVir/SharpVk/blob/master/src/SharpVk/SubmitInfo.gen.cs>
  - <https://github.com/FacticiusVir/SharpVk/blob/master/src/SharpVk/CommandBuffer.gen.cs>
  - <https://github.com/FacticiusVir/SharpVk/blob/master/src/SharpVk/CommandBuffer.partial.cs>
  - <https://github.com/FacticiusVir/SharpVk/blob/master/src/SharpVk/TimelineSemaphoreSubmitInfo.gen.cs>
  - <https://github.com/FacticiusVir/SharpVk/blob/master/src/SharpVk/Semaphore.gen.cs>
  - <https://github.com/FacticiusVir/SharpVk/blob/master/src/SharpVk/SemaphoreWaitInfo.gen.cs>
  - <https://github.com/FacticiusVir/SharpVk/blob/master/src/SharpVk/SemaphoreSignalInfo.gen.cs>
- Utility API shape (`ArrayProxy<T>`):
  - <https://github.com/FacticiusVir/SharpVk/blob/master/src/SharpVk/ArrayProxy.cs>
