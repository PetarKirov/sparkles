# Haskell: `vulkan` (expipiplus1)

## Core Mechanism

The `expipiplus1/vulkan` bindings use the type system for **structural Vulkan correctness** (especially `pNext`, `sType`, and marshaling shape), while intentionally leaving most synchronization/state correctness to Vulkan semantics plus app-level discipline.

That yields a clear split:

1. Compile-time checks for representational correctness and legal extension composition.
2. Runtime responsibility for timeline/barrier/layout correctness and externally synchronized host access.

## 1) Type-Level `pNext` Chains

### `Chain`, `Extends`, and generated legality

`Vulkan.CStruct.Extends` models extension tails as a type-level list:

```haskell
type family Chain (xs :: [a]) = (r :: a) | r -> xs where
  Chain '[]    = ()
  Chain (x:xs) = (x, Chain xs)
```

Each extensible struct has kind `[Type] -> Type`, and `Extends`/`Extendss` determine which tail elements are legal. Crucially, `Extends` is generated from Vulkan XML `structextends` metadata (generator module: `generate-new/src/Render/Spec/Extends.hs`), so invalid combinations fail at compile time.

### `Extensible`, `PokeChain`, and `PeekChain`

The `Extensible` class (`getNext`, `setNext`, `extends`) and chain classes (`PokeChain`, `PeekChain`) provide typed marshalling to/from native `pNext` linked lists.

1. `PokeChain` recursively allocates and links nodes (`linkChain` writes `pNext`).
2. `PeekChain` recursively walks pointers to reconstruct typed tails.
3. `peekSomeCStruct`/`peekChainHead` allow dynamic tail decoding when the exact type list is unknown at call site.

### Ergonomic construction/deconstruction

Pattern synonyms keep usage practical:

1. `h ::& t` attaches tail `t` to head struct `h`.
2. `x :& xs` constructs tail tuples, terminated with `()`.

Example shape used in real code (timeline semaphore setup): `zero ::& SemaphoreTypeCreateInfo ... :& ()`.

### Existential fallback: `SomeStruct`

`SomeStruct a` is a GADT that erases the concrete tail list while preserving per-value extension validity constraints. This is essential for heterogeneous arrays like `Vector (SomeStruct SubmitInfo)` in `queueSubmit`, where each element can carry a different extension chain.

## 2) Resource Lifetimes and Teardown

### Higher-order `with*` pattern

Create/destroy pairs expose generated `with*` wrappers where the caller supplies the lifetime strategy. Example (`withSemaphore`):

```haskell
withSemaphore
  :: ...
  => Device
  -> SemaphoreCreateInfo a
  -> Maybe AllocationCallbacks
  -> (io Semaphore -> (Semaphore -> io ()) -> r)
  -> r
```

The final callback can be `bracket`, `allocate` (`ResourceT`), or another custom consumer. This is a highly composable API shape.

### `ResourceT` usage model

Examples and utils use `runResourceT` + `allocate`, giving deterministic LIFO finalization. If resources are created parent-first, this naturally destroys child-first, matching Vulkan's expected practical ordering.

### Boundaries

1. Guaranteed: deterministic scoped cleanup when using `with*` correctly.
2. Not guaranteed by types: full global parent-child dependency DAG correctness.

So lifetime safety is largely achieved through scoped construction discipline rather than a full type-enforced ownership graph.

### Initialization strategy (`Zero`)

`Vulkan.Zero` provides `zero` for all-zero/default construction (`zero { ... }`), including ergonomic initialization of complex structs without repetitive boilerplate.

## 3) Synchronization Modeling Boundaries

### What is statically encoded

1. Struct layout/shape correctness.
2. Valid extension-chain composition.
3. Boilerplate correctness (e.g., many `sType`/pointer/length details).

### What is not statically encoded

1. Command buffer state machine transitions.
2. Semaphore/fence signal state.
3. Barrier correctness and image layout transitions.
4. Externally synchronized host access obligations.

The binding keeps synchronization explicit through Vulkan data structures (`SubmitInfo`, barriers, semaphores, fences) and docs, rather than enforcing a typed GPU dependency graph.

### Safe vs unsafe FFI waiting

The project defaults Vulkan calls to `unsafe` FFI for lower overhead, and provides `Safe` variants for blocking waits (e.g., `queueWaitIdleSafe`, `deviceWaitIdleSafe`). This is a pragmatic mechanism boundary: performance-first default plus scheduler-friendly alternatives when waits can block.

## 4) Practical Tradeoffs

### Strengths

1. Strong compile-time `pNext` legality with generation from spec metadata.
2. Ergonomic chain syntax without giving up type information.
3. Composable resource lifecycle API (`with*` + `bracket`/`ResourceT`).
4. Minimal runtime abstraction overhead versus graph-tracking engines.

### Limits

1. Semantic sync hazards remain largely user-managed.
2. No global typestate/lifetime proof system across all object relationships.
3. Heterogeneous cases require existential wrappers (`SomeStruct`), reducing visible specificity at API boundaries.

## Design Takeaways For A Future D Vulkan API

1. Generate an `Extends`-equivalent compile-time relation from `vk.xml` and enforce extension legality through template constraints.
2. Model typed `pNext` chains as variadic type lists (`AliasSeq`) but include an existential/erased wrapper for heterogeneous submission arrays.
3. Copy the higher-order `with*` idea: expose acquire/release pairs consumable by `scope(exit)`, explicit allocators, or custom lifetime managers.
4. Treat deterministic LIFO scope cleanup as the baseline lifetime model; it gives most of Vulkan's practical ordering guarantees with low complexity.
5. Keep structural correctness in compile time, but acknowledge synchronization correctness as a separate layer unless you intentionally adopt a heavier typestate/future-graph design.
6. Offer explicit blocking-safe wrappers for waits (D scheduler/task integration), while keeping low-overhead direct calls available.
7. Preserve explicit control over barriers/semaphores to avoid hiding performance-critical synchronization intent.

## Primary Sources

1. Repository README (`readme.md` sections on structure chains, bracketing commands, and safe/unsafe FFI): <https://github.com/expipiplus1/vulkan>
2. `Vulkan.CStruct.Extends` (`Chain`, `Extends`, `Extendss`, `SomeStruct`, `::&`, `:&`): <https://github.com/expipiplus1/vulkan/blob/main/src/Vulkan/CStruct/Extends.hs>
3. `Render.Spec.Extends` generator (`Extends` generation from spec metadata): <https://github.com/expipiplus1/vulkan/blob/main/generate-new/src/Render/Spec/Extends.hs>
4. `Vulkan.CStruct` (`ToCStruct`, `FromCStruct`, scoped marshalling): <https://github.com/expipiplus1/vulkan/blob/main/src-manual/Vulkan/CStruct.hs>
5. `Vulkan.Zero` (`Zero` initialization): <https://github.com/expipiplus1/vulkan/blob/main/src-manual/Vulkan/Zero.hs>
6. `Core10.QueueSemaphore` (`withSemaphore` API shape): <https://github.com/expipiplus1/vulkan/blob/main/src/Vulkan/Core10/QueueSemaphore.hs>
7. `Core10.Queue` (`queueSubmit`, `queueWaitIdleSafe`, `deviceWaitIdleSafe`): <https://github.com/expipiplus1/vulkan/blob/main/src/Vulkan/Core10/Queue.hs>
8. Utility/example usage of `ResourceT` and typed chains:
   - <https://github.com/expipiplus1/vulkan/blob/main/utils/src/Vulkan/Utils/Initialization.hs>
   - <https://github.com/expipiplus1/vulkan/blob/main/examples/timeline-semaphore/Main.hs>
