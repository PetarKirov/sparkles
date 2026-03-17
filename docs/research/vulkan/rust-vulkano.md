# Rust: `vulkano`

## Safety Model: Ownership + `GpuFuture` + Runtime Access Tracking

`vulkano`'s design is best understood as three cooperating layers:

1. **Rust ownership/borrowing** for host-side aliasing and thread-safety.
2. **`GpuFuture` chains** for GPU timeline ordering and dependency composition.
3. **Runtime resource-state tracking** for hazards that cannot be proven statically.

The project explicitly aims to prevent invalid Vulkan usage through a combination of compile-time and runtime checks, not compile-time checks alone.

## 1) Internal GPU Synchronization (`GpuFuture`)

`GpuFuture` represents "work that will complete on the GPU in the future" and is chainable:

- `now().then_execute(...).then_signal_semaphore().then_signal_fence()`
- `join(...)` merges dependency branches.
- queue transitions are represented explicitly (typically via semaphore futures).

At `flush` time, vulkano walks this chain and builds a submission plan. It can batch compatible work into a single submit, insert waits/signals, and enforce ordering implied by the chain. In practice, this is a typed dependency graph that hides most manual semaphore/fence choreography.

## 2) External Host Synchronization (CPU-Side Safety)

Vulkan's "externally synchronized" rules are mapped to Rust semantics:

- mutating operations typically require exclusive access (`&mut`), preventing host data races at compile time,
- shared read-only access can remain `&`,
- internal mutable state uses synchronization primitives, but the API surface still encodes exclusivity expectations.

This means many host-side misuse cases are rejected by the compiler before the program runs.

## 3) Resource Lifetimes Coupled to Execution

`GpuFuture` values hold `Arc` references to command buffers, synchronization primitives, swapchain objects, and other resources needed by in-flight work.

Consequences:

- resources cannot be dropped while GPU work still depends on them,
- ownership of "work in flight" becomes explicit in user code,
- lifetime safety is mostly achieved through RAII and reference retention rather than manual bookkeeping.

One practical caveat: some future types are intentionally `#[must_use]` and can block if dropped too early, trading convenience for correctness.

## 4) Compile-Time vs Runtime Checks

### Compile-Time

- Rust's type/borrow system encodes aliasing and exclusivity constraints.
- Shader integration (`vulkano-shaders` / `shader!`) generates strongly typed interfaces from shader metadata, reducing descriptor/layout mismatch risk.
- Some illegal API compositions are prevented by typed builder/state APIs.

### Runtime

- Access conflict detection for buffers/images during submission.
- Validation of dynamic conditions (resource ranges, layouts, queue compatibility, swapchain state).
- Internal state machines and lock tracking for CPU/GPU read-write conflicts.

This split is essential: Vulkan hazards often depend on dynamic frame graphs and runtime-chosen resource ranges, which are not fully decidable at compile time.

## Strengths

- **Strong practical safety envelope:** many common Vulkan footguns are blocked either statically or at submit time.
- **Synchronization ergonomics:** future chaining removes large amounts of manual semaphore/fence boilerplate.
- **Lifetime robustness:** in-flight resources are retained automatically.
- **Typed shader boundary:** compile-time generated shader interfaces improve correctness and developer feedback.

## Limitations and Tradeoffs

- **Not purely static safety:** key hazard checks still happen at runtime.
- **Overhead from safety machinery:** `Arc`, lock/state tracking, and submit-time validation add cost versus raw Vulkan.
- **Potential surprise stalls:** dropping certain unfinished futures can block.
- **Unsafe extension points remain:** custom low-level integrations can bypass guarantees if implemented incorrectly.
- **Coverage gaps exist in edge cases:** some advanced synchronization/ownership scenarios are still tracked by TODOs in the codebase.

## Transferable Lessons for a D Vulkan Binding

1. **Separate safety domains explicitly:** host aliasing/threading rules should be encoded differently from GPU timeline hazards.
2. **Model in-flight work as first-class values:** a `GpuFuture`-like token that owns dependencies is a strong lifetime primitive.
3. **Use hybrid checking by design:** compile-time for structural invariants, runtime for dynamic hazard resolution.
4. **Provide an auto-sync default path:** infer barriers/semaphores from declared accesses, with expert escape hatches.
5. **Reflect shader interfaces at compile time:** CTFE/DbI can generate typed descriptor/push-constant interfaces similar to `shader!`.
6. **Be explicit about blocking semantics:** avoid hidden waits on destruction where possible; prefer visible "finalize/wait/cleanup" APIs.
7. **Make unsafe customization capability-gated:** keep advanced overrides available, but isolate them behind explicit unsafe contracts.

## D-Oriented Design Direction

For a state-of-the-art D abstraction, vulkano suggests a blueprint:

- **Static layer (DbI + UDAs + CTFE):** pipeline/layout/shader compatibility, extension chains, and API capability gating.
- **Dynamic layer (runtime graph):** per-frame access graph that emits barriers/semaphore plans.
- **Ownership layer:** explicit submission/future objects that retain resources until completion.

This hybrid architecture matches Vulkan's reality while still pushing as much correctness as possible into compile time.
