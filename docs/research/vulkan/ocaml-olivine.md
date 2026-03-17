# OCaml: `Olivine`

## Mechanism: Polymorphic Variants and Result Monads

`Olivine` is a thin but strongly typed OCaml interface that maps Vulkan to idiomatic OCaml constructs.

### Structural Safety

It maps integer `VkResult` codes directly to the OCaml `result` monad using polymorphic variants (e.g., `` `Success``, `` `Error_out_of_host_memory``). This forces exhaustive pattern matching of all possible failure states.

### Record Mapping

Vulkan C structs are mapped to OCaml records. `Olivine` automatically populates `sType` fields under the hood based on context and safely wraps nullable C pointers in OCaml `option` types.

### Concurrency

It leverages OCaml 5's effect handlers (Fibers) to manage CPU/GPU concurrency, allowing the CPU to yield cleanly while waiting for Vulkan fences without blocking the OS thread. Unlike Rust, it does not attempt to encode resource lifetimes, leaving manual handle destruction to the developer.
