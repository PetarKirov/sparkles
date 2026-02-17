# Algebraic Effect Systems

A research survey of algebraic effects across theory, language design, compiler/runtime implementation, and production libraries.

**Last reviewed:** February 16, 2026.

---

## Scope

This section focuses on **algebraic effects and handlers** (operations + handlers + resumptions), plus adjacent systems that heavily influence practical adoption:

- effect systems without full handlers (for comparison)
- capability systems that overlap with effect tracking
- runtime proposals that make handlers efficient (for example, stack switching and delimited continuations)

---

## What Is an Algebraic Effect System?

At the core, an algebraic effect system has three ingredients:

1. **Operations** representing abstract effects (`get`, `put`, `choose`, `raise`, ...)
2. **Handlers** interpreting those operations
3. **Resumptions** (continuations) that let a handler continue, alter, duplicate, or abort the rest of the computation

This gives modular effectful code: programs describe _what_ effects they need, handlers decide _how_ they run.

---

## State of the Art (2026 Snapshot)

The frontier is no longer a single "best library". It is a set of converging advances along different axes:

| Axis                | Current Frontier                                                                                                                       |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| **Semantics**       | Sound treatment of higher-order effects and handler interactions (e.g. Hefty Algebras and follow-up work)                              |
| **Compilation**     | Evidence-passing and selective continuation capture; O(1) dispatch for common operations                                               |
| **Runtime support** | Native continuation support in major runtimes (OCaml 5, GHC delimited continuation primops, WebAssembly stack-switching proposal work) |
| **Parallelism**     | First formal systems and implementations for parallel algebraic handlers (`lambda^p`)                                                  |
| **Adoption**        | Industrial use of effect-inspired systems in Haskell, Scala, OCaml, and TypeScript ecosystems                                          |

No ecosystem currently dominates every axis at once.

---

## Encoding Taxonomy

### By Effect Representation Strategy

| Strategy                    | Description                                                                    | Libraries / Languages             |
| --------------------------- | ------------------------------------------------------------------------------ | --------------------------------- |
| **Free monad**              | Effects as data; computation tree built then interpreted                       | polysemy, freer-simple            |
| **Carrier fusion**          | Higher-order functors fused at compile time via typeclass instances            | fused-effects                     |
| **ReaderT IO**              | Concrete `IO` monad with extensible environment; effects dispatched via IORef  | effectful, cleff, bluefin         |
| **Delimited continuations** | Native stack capture via GHC primops; effects handled by resumable prompts     | eff, bluefin-algae                |
| **Hefty algebras**          | Separation of first-order and higher-order effect elaboration                  | heftia                            |
| **Fiber runtime**           | Lightweight green threads with structured concurrency                          | ZIO, Cats Effect                  |
| **Row-polymorphic effects** | Effects tracked via extensible row types with scoped labels and full inference | Koka, Eff                         |
| **Native continuations**    | One-shot delimited continuations built into the language runtime               | OCaml 5                           |
| **Capability passing**      | Effects accessed via value-level or context-level capability tokens            | bluefin, Scala 3 capabilities, Ox |
| **Generator-based**         | Effects encoded via generator functions yielding effect descriptors            | Effect (TypeScript)               |
| **Wasm continuations**      | Typed stack switching primitives at the bytecode level                         | WasmFX                            |

### By Type-Level Effect Tracking

| Approach                  | Mechanism                                                              | Libraries / Languages                     |
| ------------------------- | ---------------------------------------------------------------------- | ----------------------------------------- |
| **Type-level list**       | `Eff (es :: [Effect]) a` with `Member` / `:>` constraints              | effectful, cleff, polysemy, fused-effects |
| **Fixed type parameters** | `ZIO[R, E, A]` with intersection types for environment                 | ZIO                                       |
| **Typeclass hierarchy**   | `Sync`, `Async`, `Concurrent` etc. constraining `F[_]`                 | Cats Effect                               |
| **Value-level handles**   | ST-like scoped type variables on handle values                         | bluefin                                   |
| **Capture checking**      | Experimental `^{cap}` annotations tracking capability capture          | Scala 3 (Caprese)                         |
| **Row types**             | Extensible row types with effect labels; full effect inference         | Koka, Eff                                 |
| **Untyped**               | Effects are values at runtime; no static typing of effect sets         | OCaml 5                                   |
| **Ambient abilities**     | Effects as ambient abilities in scope; handler determines availability | Frank, Unison                             |
| **Three-parameter type**  | `Effect<A, E, R>` encoding success, error, and requirements            | Effect (TypeScript)                       |

Note: systems marked as having "no effect tracking" (Rust implicit features, Java Loom) are covered in individual pages but omitted from the taxonomy since they do not implement effect-system abstractions.

---

## Quick Navigation

### History and Synthesis

- [Evolution of Effect Systems](evolution.md)
- [Comparison and Analysis](comparison.md)
- [Theory and Compilation](theory-compilation.md)
- [Key Papers](papers.md)
- [Parallelism](parallelism.md)

### Haskell

- [effectful](haskell-effectful.md)
- [cleff](haskell-cleff.md)
- [polysemy](haskell-polysemy.md)
- [fused-effects](haskell-fused-effects.md)
- [bluefin](haskell-bluefin.md)
- [eff](haskell-eff.md)
- [heftia](haskell-heftia.md)
- [Theseus](haskell-theseus.md)

### Scala

- [ZIO](scala-zio.md)
- [Cats Effect](scala-cats-effect.md)
- [Kyo](scala-kyo.md)
- [Scala Capabilities](scala-capabilities.md)
- [Ox](scala-ox.md)

### Effect-Native / Runtime-Native

- [Koka](koka.md)
- [Eff Language](eff-lang.md)
- [Frank](frank.md)
- [Unison](unison.md)
- [OCaml 5 Effects](ocaml-effects.md)
- [OCaml Eio](ocaml-eio.md)
- [WasmFX](wasmfx.md)

### Other Ecosystems

- [TypeScript Effect](typescript-effect.md)
- [Java Loom](java-loom.md)
- [Rust Effect Notes](rust-effect-system.md)
- [Additional Implementations](other-implementations.md)

---

## High-Confidence Milestones

- **2009**: Plotkin and Pretnar formalize handlers of algebraic effects.
- **2014-2017**: Koka demonstrates practical row-polymorphic effect typing and efficient compilation strategies.
- **2020-2021**: Evidence-passing compilation gives strong performance and a clean semantic account.
- **2021**: OCaml effect handlers are retrofitted into an industrial language runtime (PLDI).
- **2023**: Hefty Algebras clarifies modular, sound higher-order effect elaboration.
- **2023**: WasmFX presents typed continuations for WebAssembly as a general target for non-local control.
- **2024-2025**: Parallel handlers, affine/linearity-aware systems, and abstract effect algebra frameworks expand the theory frontier.

---

## Notes on Terminology

- **Algebraic effects**: usually first-order operations interpreted by handlers.
- **Higher-order effects**: operations that take computations/continuations as arguments (for example, `local`, `catch`, scoped resources).
- **Effect system vs effect handlers**: many production systems track effects but do not support full algebraic handlers.

---

## Sources

- [Effects Bibliography (living index)](https://github.com/yallop/effects-bibliography)
- [Handlers of Algebraic Effects (ESOP 2009)](https://doi.org/10.1007/978-3-642-00590-9_7)
- [Effect Handlers, Evidently (ICFP 2020)](https://doi.org/10.1145/3408981)
- [Generalized Evidence Passing (ICFP 2021)](https://doi.org/10.1145/3473576)
- [Retrofitting Effect Handlers onto OCaml (PLDI 2021)](https://doi.org/10.1145/3453483.3454039)
- [Hefty Algebras (POPL 2023)](https://doi.org/10.1145/3571255)
- [Continuing WebAssembly with Effect Handlers (OOPSLA 2023)](https://doi.org/10.1145/3622814)
- [Parallel Algebraic Effect Handlers (ICFP 2024)](https://doi.org/10.1145/3674651)
- [OCaml 5.3.0 release notes (2025-01-08)](https://ocaml.org/releases/5.3.0)
- [OCaml release index (includes 5.4.0, 2025-10-09)](https://ocaml.org/releases/)
- [GHC 9.6.1 release notes (delimited continuation primops)](https://downloads.haskell.org/~ghc/9.6.5/docs/users_guide/9.6.1-notes.html)
- [WebAssembly stack-switching proposal repository](https://github.com/WebAssembly/stack-switching)
