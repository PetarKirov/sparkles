# OCaml: `Olivine`

## Mechanism: Spec-Generated Thin Bindings + OCaml Type Enrichment

`Olivine` is a Vulkan binding generator for OCaml that aims to stay close to the C API while replacing common C sharp edges with typed OCaml interfaces (`result`, variants, options, typed records, typed bitsets, abstract handles).

This section focuses on what `Olivine` itself provides today, and where higher-level safety is still missing.

## What Olivine Gets Right

### 1) Error Handling: `VkResult` -> Typed `result`

`Olivine` maps Vulkan return codes to OCaml `result` with polymorphic variants and narrows the error space per function signature.

- The generator maps `VkResult` to a typed `result` instead of a raw integer code.
- Function signatures encode only the valid success/error cases for that specific call.
- Out-parameters are folded into the `Ok` payload, so call sites handle status and outputs together.

This is a real safety upgrade versus C: callers must handle success/error at the type level, and cannot silently ignore status without intentionally discarding it.

### 2) Struct Modeling: Better Than C Initializers

Generated record modules provide labeled constructors (`make`) and typed fields instead of manual C aggregate literals.

- Optional pointer/array fields are detected from Vulkan metadata and exposed as OCaml `option`.
- Common Vulkan length+pointer patterns are lifted to array-like OCaml APIs in many cases.
- Sub-structures are accepted as values instead of forcing explicit address-taking at call sites.
- The generator recognizes the `sType`/`pNext` extension idiom and models it as open sum extensions, not just raw `void*` plumbing.

This reduces a large class of accidental init bugs (`NULL` mismatches, pointer-level confusion, stale field wiring).

### 3) Stronger Base Types

`Olivine` introduces several typed building blocks that are easy to underestimate but useful in practice:

- Handles are abstract types, reducing accidental cross-handle misuse.
- Enum/flag domains are distinct OCaml types rather than interchangeable integers.
- Bitsets use a phantom type split (`singleton` vs `plural`) to keep single-bit values and composed masks distinguishable.

These are lightweight but meaningful compile-time guards for everyday API usage.

## Important Gaps

### 1) Lifetime Safety Is Not Encoded

`Olivine` does not provide ownership/lifetime tracking for Vulkan object graphs.

- No Rust-style borrow/lifetime model.
- No built-in RAII scope system that enforces destruction order.
- No static prevention of use-after-free across dependent handles.

In practice, lifetime discipline remains manual. Even Olivine's own TODO mentions missing liveness analysis to keep OCaml values alive when referenced from C.

### 2) Synchronization Safety Is Mostly Manual

`Olivine` does not model Vulkan synchronization hazards (resource state transitions, access hazards, stage/access compatibility) in types.

- Queue submission and barrier logic remain explicit Vulkan work.
- There is no graph/future system that derives barriers/semaphore dependencies automatically.
- External host synchronization rules are not elevated into a stronger API contract.

So the API is cleaner than C, but sync correctness still depends on user discipline plus validation layers.

### 3) Fiber/Effect-Based Concurrency Is External, Not Core Olivine

OCaml 5 fibers/effects are a powerful way to structure render/event loops, but this is not a built-in Olivine synchronization abstraction.

- The frequently cited fiber-based Vulkan flow comes from higher-level wrapper code in external projects (for example, talex5's `vulkan-test` wrappers), not from Olivine core generated APIs.
- Olivine itself is primarily a typed binding layer over Vulkan C FFI.

This distinction matters when borrowing ideas: fibers improve application orchestration, but do not by themselves enforce Vulkan resource/sync correctness.

## Transferable Ideas for A Safer D Vulkan Layer

### Keep

- Spec-driven generation as the baseline to stay current with Vulkan.
- Narrowed per-function error types instead of generic integer/enum status handling.
- Automatic optional/array lifting and structured constructors for create-info ergonomics.
- Typed `sType`/`pNext` chain modeling to eliminate raw `void*` chain bugs.

### Improve Beyond Olivine

- Add ownership/lifetime tracking (typestate, scoped ownership tokens, or deterministic RAII wrappers).
- Add synchronization-aware abstractions (resource access declarations and barrier planning).
- Make CPU-side external synchronization constraints explicit in API shapes (capabilities/tokens/phases).
- Provide two tiers: raw generated layer + safety-enhanced layer, so expert escape hatches remain available.

## Bottom Line

`Olivine` is a strong example of "thin but typed" Vulkan binding design: it upgrades API shape, error handling, and struct correctness substantially over plain C usage.

It is not, however, a full safety system for Vulkan lifetime and synchronization correctness. The key lesson for D is to keep Olivine's generation and type-enrichment wins, then add explicit higher-level ownership and sync semantics on top.

## Primary Sources

- <https://github.com/Octachron/olivine>
- <https://raw.githubusercontent.com/Octachron/olivine/main/README.md>
- <https://github.com/Octachron/olivine/blob/main/TODO>
- <https://roscidus.com/blog/blog/2025/09/20/ocaml-vulkan/>
