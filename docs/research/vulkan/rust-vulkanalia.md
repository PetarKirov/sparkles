# Rust: `vulkanalia`

## Mechanism: Spec-Generated Core + Thin Wrappers + Lifetime-Carrying Builders

`vulkanalia` explicitly positions itself as a fairly thin, Rust-idiomatic wrapper over generated Vulkan bindings. The project goal is to stay close to Vulkan while removing common call-site hazards (parameter encoding, function loading, boilerplate) rather than enforcing full correctness for synchronization or lifetimes.

## Safety and Ergonomics Model

### 1) Generated Types from `vk.xml`

- `vulkanalia-sys` is generated from the Vulkan API Registry (`vk.xml`) and contains raw commands, enums, bitmasks, and structs.
- `vulkanalia` re-exports these generated items in `vk` and adds handwritten wrappers (`Entry`, `Instance`, `Device`) plus helper modules.
- Name normalization removes C namespacing prefixes (`VkInstanceCreateInfo` -> `vk::InstanceCreateInfo`), improving readability without changing semantics.

### 2) Typed API Surface That Reduces FFI Footguns

- Enums are represented as structs with associated constants (instead of Rust `enum`) to avoid FFI UB concerns.
- Bitmasks are modeled with typed bitflags, which prevents cross-domain flag mixups at compile time.
- Wrapper signatures encode intent missing from raw C signatures, for example optional pointers become `Option<&CStr>` and fallible commands return `VkResult<T>`.
- Command wrappers encapsulate common two-call enumerate patterns and return owned vectors.

### 3) Builder + Lifetime Pattern (Most Important Safety Lever)

- Generated create-info builders carry lifetimes (`InstanceCreateInfoBuilder<'b>`) so borrowed slices and `pNext` references must outlive the builder.
- `push_next` is constrained by generated traits like `ExtendsInstanceCreateInfo`, giving compile-time validation that a struct is legal in that chain position.
- Crucial caveat acknowledged by the project: calling `.build()` discards builder lifetime information. The recommended safe pattern is to pass builders directly into command wrappers.

This is a strong, practical pattern to borrow for D: preserve borrow relationships until the final call boundary instead of eagerly materializing pointer-filled structs.

### 4) `pNext` Support: Better Than Raw Pointers, Still Low-Level

- Builders support typed `push_next` composition.
- The `chain` module provides iterators for input/output chains and typed casts against `sType`.
- This makes chain composition and inspection safer than manual `void*` handling, but still relies on `unsafe` when traversing arbitrary chain pointers.

### 5) Ownership / RAII Strategy

- `Entry`, `Instance`, and `Device` are lightweight wrappers around handles and loaded command tables.
- They are `Clone + Send + Sync` wrappers, but they do not implement `Drop`-based Vulkan destruction.
- Official examples perform explicit teardown (`destroy_*` calls in dependency order), so lifecycle correctness is mostly manual policy rather than enforced ownership.

## Synchronization and Threading Story

### Internal GPU Synchronization

- `vulkanalia` does not provide a `GpuFuture`/task-graph style scheduler.
- Queue submission, barriers, semaphores, and fences are still orchestrated explicitly by user code.
- Tutorial/example code follows classic Vulkan explicit sync patterns (`wait_for_fences`, `reset_fences`, `queue_submit`, present wait semaphores).

### External Host Synchronization

- The library does not encode Vulkan externally-synchronized object access rules as a type-level borrowing discipline.
- Many wrappers remain `unsafe`, and valid usage invariants are still expected to be upheld by the caller.

### Capability/Extension Handling

- Commands are loaded into dispatch tables.
- If a command is unavailable, generated fallback stubs panic when called (`"could not load vk..."`).

This is ergonomic for bring-up, but it is not a type-level capability system; extension availability is primarily a runtime discipline.

## Compile-Time Checks Worth Reusing

- Lifetime-carrying builders for borrowed arrays and chained structs.
- Generated `Extends*` traits for legal `pNext` chain edges.
- `include_shader_code!` macro validates SPIR-V byte length/alignment at compile time for static shader inclusion.

## Implications for a Type-Safe D Vulkan API

### Keep

- Spec-driven code generation from `vk.xml` as the canonical base layer.
- Thin ergonomic wrappers over generated commands (typed options/results, enumerate helpers).
- Lifetime-like builder discipline (in D terms: scope-aware borrowed slices/chains) all the way to call boundaries.

### Improve Beyond `vulkanalia`

- Add deterministic ownership wrappers that enforce destruction ordering by construction (optional RAII/ownership tier).
- Add capability-gated APIs so extension/device feature commands are statically or structurally gated, avoiding runtime panic stubs.
- Add a higher-level synchronization model (resource access declarations + barrier/semaphore planning) on top of the thin layer.
- Encode external synchronization constraints in API shape (typestate/capability tokens) where practical.

### Design Positioning Lesson

`vulkanalia` is an excellent "safe-er thin wrapper" reference, not a full correctness framework. For D, it is a strong baseline for generated typing + ergonomics, but not sufficient as the end-state if the goal is compile-time guidance for lifetimes, hazards, and parallel submission correctness.

## Primary Sources

- <https://github.com/KyleMayes/vulkanalia>
- <https://raw.githubusercontent.com/KyleMayes/vulkanalia/master/README.md>
- <https://kylemayes.github.io/vulkanalia/overview.html#api-concepts>
- <https://raw.githubusercontent.com/KyleMayes/vulkanalia/master/vulkanalia/src/lib.rs>
- <https://raw.githubusercontent.com/KyleMayes/vulkanalia/master/vulkanalia/src/vk/builders.rs>
- <https://raw.githubusercontent.com/KyleMayes/vulkanalia/master/vulkanalia/src/vk/versions.rs>
- <https://raw.githubusercontent.com/KyleMayes/vulkanalia/master/vulkanalia/src/vk/commands.rs>
- <https://raw.githubusercontent.com/KyleMayes/vulkanalia/master/examples/src/lib.rs>
