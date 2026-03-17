# Rust: `vulkano`

## Mechanism: Ownership, Lifetimes, and the `GpuFuture` Trait

The `vulkano` crate relies heavily on Rust's borrow checker and trait system to provide a safe wrapper over Vulkan.

### Internal GPU Synchronization

Vulkano abstracts Vulkan's execution timeline into a chainable `GpuFuture` trait. Rather than manually inserting barriers, developers chain operations (e.g., `now().then_execute(...).then_signal_semaphore()`). This builds a dependency graph. Vulkano tracks resource access (read vs. write) along this graph and automatically calculates and inserts the correct `VkPipelineBarrier` or `VkSemaphore` at submission time.

### External Host Synchronization

Vulkan requires the host to guarantee that certain objects are never accessed concurrently by multiple CPU threads. Vulkano maps these "externally synchronized" requirements directly to Rust's `&mut` (exclusive borrowing) rules. If an API mutates state, it requires a `&mut` reference, forcing the compiler to statically reject data races.

### Resource Lifetimes

A `GpuFuture` retains ownership (via `Arc`) of all resources involved in its operation. This tightly couples the GPU's execution timeline with Rust's drop semantics, mathematically preventing a resource from being freed on the CPU while the GPU is still using it.

### Compile-Time State Tracking

Vulkano uses macros (like `shader!`) to parse SPIR-V at compile time, generating strongly-typed Rust structs for the shader's interface. This ensures layout compatibility at compile time.
