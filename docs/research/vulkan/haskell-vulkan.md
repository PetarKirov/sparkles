# Haskell: `vulkan` (by expipiplus1)

## Mechanism: Type-Level Lists, Type Families, and Monadic Scoping

The Haskell `vulkan` package focuses on providing an idiomatic, statically typed interface without the overhead of runtime graph tracking.

### Extensible Structures (`pNext` Chains)

Vulkan's untyped `void* pNext` extension chains are solved using Type-Level Lists (`Chain es`) and Type Families (`Extends a b`). The compiler statically enforces that a struct `b` can legitimately be placed in the `pNext` chain of struct `a`. GADTs are used to safely unpack heterogeneous chains returned by the driver.

### Synchronization Tracking

Rather than runtime tracking, Haskell uses its type system to ensure structural correctness (e.g., automatically inferring the `sType` tag). For CPU-GPU synchronization, blocking FFI calls (like `vkWaitDeviceIdle`) are marked as "safe" FFI, allowing GHC's green-thread scheduler to yield the CPU to other tasks while waiting on the GPU.

### Resource Management

The package uses `ResourceT` and the `bracket` pattern to enforce deterministic destruction of Vulkan handles in the correct reverse-dependency order, solving manual lifecycle bugs without needing a garbage collector to track handles.
