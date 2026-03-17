# High-Level Vulkan Bindings

## Goal

To build a state-of-the-art D abstraction for Vulkan that excels at guiding developers to performance, safety, and convenience. The binding should make it easy to utilize all CPU cores to submit work in parallel, while preventing common Vulkan pitfalls like synchronization hazards, resource lifetime issues, and invalid state transitions.

## Leveraging D's Strengths

Unlike other languages that rely heavily on either runtime validation or complex macro systems, D provides unique compile-time metaprogramming capabilities that we can leverage:

- **Design by Introspection (DbI):** We can inspect types and configurations at compile time to dynamically generate optimal Vulkan API calls, struct layouts, and extension chains (`pNext`).
- **User-Defined Attributes (UDAs):** Can be used to annotate structs or functions with required Vulkan states, access masks, or memory domains, which are then verified at compile time.
- **Compile-Time Function Execution (CTFE):** Allows us to parse shaders (GLSL/SPIR-V), construct dependency graphs, or validate synchronization models during compilation, completely eliminating runtime overhead.
- **Typestate and Graph/Lifetime Tracking:** By using phantom types and move semantics (or `core.lifetime`), we can model the Vulkan state machine at compile time, ensuring resources are only accessed when in the correct layout and state, similar to C++'s Typestate pattern but more ergonomic.

## Ecosystem Research

We have researched how other language ecosystems leverage their type systems to enforce safety and manage synchronization in Vulkan.

- [Rust: `vulkano`](./rust-vulkano)
- [Haskell: `vulkan`](./haskell-vulkan)
- [C++: `Vulkan-Hpp` & `Tephra`](./cpp-vulkan-hpp)
- [OCaml: `Olivine`](./ocaml-olivine)
