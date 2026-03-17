# C++: `Vulkan-Hpp` & `Tephra`

## Mechanism: Typestate Pattern, Template Metaprogramming, and Job Graphs

High-level C++ bindings use templates to shift Vulkan's complex runtime state validation to compile-time.

### Foundational Safety

`Vulkan-Hpp` replaces C enums with scoped enums and enforces valid bitwise operations using a `vk::Flags<T>` template. It also provides deterministic RAII wrappers (`vk::raii`) for handle lifetimes, ensuring resources are destroyed when they go out of scope.

### Typestate State Machines

Advanced C++ wrappers use phantom types to encode the Vulkan state machine into the compiler. A command buffer might be templated as `CommandBuffer<State>`. Transitioning states consumes the object via rvalue references (`&&`) and returns a new type. Methods like `.draw()` are only defined for `CommandBuffer<InsideRenderPass>`, turning invalid API sequences into hard compiler errors.

### Automated Barriers

Libraries like `Tephra` use a high-level job system where developers specify typed access requirements (e.g., `ReadAccess::SampledImage`). The library infers and automatically inserts the optimal barriers and layout transitions during command recording, similar to Direct3D 12's resource state model.
