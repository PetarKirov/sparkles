# High-Level Vulkan Bindings Research

## Goal

Design a D Vulkan abstraction that is high-performance, expressive, and much harder to misuse.

The key safety targets are:

1. Internal GPU synchronization correctness.
2. External host synchronization correctness.
3. Resource lifetime validity across CPU/GPU overlap.
4. Struct and extension correctness (`sType`, `pNext`, feature-gated calls).

## Surveyed Project List

1. Rust: [`vulkano`](./rust-vulkano)
2. Rust: [`vulkanalia`](./rust-vulkanalia)
3. Haskell: [`vulkan`](./haskell-vulkan)
4. OCaml: [`olivine`](./ocaml-olivine)
5. C++: [`Vulkan-Hpp`](./cpp-vulkan-hpp)
6. C++: [`Tephra`](./cpp-tephra)
7. C++: [`Daxa`](./cpp-daxa)
8. C#: [`SharpVk`](./csharp-sharpvk)
9. C#: [`Silk.NET` Vulkan](./csharp-silknet)
10. Java: [`jcoronado`](./java-jcoronado)
11. Java: [`vulkan4j`](./java-vulkan4j)
12. Zig: [`vulkan-zig`](./zig-vulkan-zig)

This expands the original set by eight noteworthy implementations.

## Comparative Snapshot

| Project           | Type-System Focus                                         | Internal Sync Model                                                 | External Sync Model                                 | Lifetime Model                                               |
| ----------------- | --------------------------------------------------------- | ------------------------------------------------------------------- | --------------------------------------------------- | ------------------------------------------------------------ |
| `vulkano`         | Ownership + typed shader interfaces                       | Runtime dependency graph with auto barriers/semaphores              | Borrowing-style exclusivity                         | In-flight ownership retained via futures/`Arc`               |
| `vulkanalia`      | Thin typed wrappers + lifetime-carrying builders          | Manual Vulkan synchronization                                       | Mostly manual                                       | Mostly manual handle destruction                             |
| Haskell `vulkan`  | Type-level `pNext` (`Chain`, type families, GADTs)        | Manual synchronization                                              | Scheduler-friendly safe FFI waits                   | `ResourceT` and `bracket` deterministic cleanup              |
| OCaml `olivine`   | Typed records/variants/options + generated API            | Manual Vulkan synchronization                                       | Not encoded in types                                | Mostly manual, with helper/finalizer patterns                |
| `Vulkan-Hpp`      | Strong enums/flags/handles + `StructureChain`             | Manual typed synchronization calls                                  | Manual discipline                                   | Optional RAII (`UniqueHandle`, `vk::raii`)                   |
| `Tephra`          | Typed access enums + high-level jobs/passes               | Runtime access tracking + automatic sync                            | Explicit thread-safety boundaries                   | Delayed destruction tied to queue progress                   |
| `Daxa`            | Typed IDs + task graph contracts                          | Automatic task-graph synchronization and optimization               | Thread-safe boundaries + validation                 | Automatic deferred destruction post GPU execution            |
| `SharpVk`         | Generated typed handles/enums/flags                       | Manual synchronization with typed submit/barrier structs            | Manual host synchronization                         | `IDisposable` wrappers, no in-flight tracking                |
| `Silk.NET` Vulkan | Generated handles + typed `pNext` chain interfaces        | Manual synchronization                                              | Manual host synchronization                         | Manual destroy + optional `IDisposable` chain helpers        |
| `jcoronado`       | Immutable value objects + typed extension interfaces      | Explicit modern baseline (`synchronization2` + timeline semaphores) | Externally synchronized operations annotated in API | `AutoCloseable` + `try-with-resources`                       |
| `vulkan4j`        | Panama typed pointers/records + generated command classes | Manual synchronization                                              | Manual host synchronization                         | `Arena`-scoped native memory, manual GPU lifetime discipline |
| `vulkan-zig`      | Generated typed handles/flags + wrapper out-param lifting | Manual synchronization                                              | Manual host synchronization                         | Manual lifetimes, no ownership graph                         |

## D-Centric Synthesis

The most promising architecture for D is layered:

1. Generated low-level ABI layer (Vulkan-Hpp/vulkan-zig style).
2. Compile-time structural safety layer (`pNext`, feature gating, descriptor typing).
3. Optional runtime synchronization planner layer (vulkano/Tephra/Daxa style).
4. Explicit in-flight lifetime tokens tied to submission completion.

This keeps a zero-magic escape hatch for experts while making the safer path the default path.
