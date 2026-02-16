# Algebraic Effect Systems

A comprehensive survey of algebraic effect system implementations, encodings, performance characteristics, and design trade-offs across multiple language ecosystems. This research covers Haskell, Scala, Rust, TypeScript, OCaml, Koka, and other languages -- spanning major libraries, dedicated effect languages, key academic papers, and the evolution from monad transformers to modern effect systems.

## Table of Contents

### Haskell Effect Systems

| Library                                       | Encoding                | Performance    | Higher-Order Effects | Algebraic Effects | IO Dependency |
| --------------------------------------------- | ----------------------- | -------------- | -------------------- | ----------------- | ------------- |
| **[effectful](haskell-effectful.md)**         | ReaderT IO              | Fastest        | Yes                  | No                | Yes           |
| **[cleff](haskell-cleff.md)**                 | ReaderT IO              | Very fast      | Yes                  | No                | Yes           |
| **[polysemy](haskell-polysemy.md)**           | Freer monad             | Moderate       | Yes (Tactics)        | Partial           | No            |
| **[fused-effects](haskell-fused-effects.md)** | Carrier fusion          | Near-mtl       | Yes                  | Partial           | No            |
| **[bluefin](haskell-bluefin.md)**             | ReaderT IO (handles)    | Fast           | Yes                  | Via bluefin-algae | Yes           |
| **[eff](haskell-eff.md)**                     | Delimited continuations | Very fast      | Yes                  | Yes               | Yes           |
| **[heftia](haskell-heftia.md)**               | Hefty algebras          | Near-effectful | Yes (fully sound)    | Yes               | No            |

### Scala Effect Systems

| Library/System                                    | Approach                             | Performance        | Effect Tracking | DI Built-in  |
| ------------------------------------------------- | ------------------------------------ | ------------------ | --------------- | ------------ |
| **[ZIO](scala-zio.md)**                           | Fiber + ZIO[R,E,A]                   | High               | Error + Env     | Yes (ZLayer) |
| **[Cats Effect](scala-cats-effect.md)**           | Typeclass hierarchy                  | High (lighter)     | Via typeclasses | No           |
| **[Kyo](scala-kyo.md)**                           | Algebraic effects                    | High               | Open effect set | Partial      |
| **[Scala 3 Capabilities](scala-capabilities.md)** | Context functions + capture checking | N/A (experimental) | Type-level      | No           |
| **[Ox](scala-ox.md)**                             | Direct style + VT                    | Native threads     | IO capability   | No           |

### Effect-Native Languages

| Language/System         | Approach                | Effect Typing          | Performance                  | Key Innovation                                        |
| ----------------------- | ----------------------- | ---------------------- | ---------------------------- | ----------------------------------------------------- |
| **[Koka](koka.md)**     | Row-polymorphic effects | Row types with labels  | Perceus RC; evidence passing | Row-polymorphic effect types with full inference      |
| **[Eff](eff-lang.md)**  | Native effect handlers  | Row-based effect types | Interpreted                  | Reference language by Bauer/Pretnar; research vehicle |
| **[Frank](frank.md)**   | Multihandlers           | Ambient ability types  | Research prototype           | Multihandlers; ambient ability; CBPV foundation       |
| **[Unison](unison.md)** | Abilities (Frank-based) | Ability types          | Content-addressed            | Content-addressed code; Frank-inspired abilities      |

### OCaml Effect Systems

| Library/System                          | Approach             | Effect Typing      | Key Innovation                                                    |
| --------------------------------------- | -------------------- | ------------------ | ----------------------------------------------------------------- |
| **[OCaml 5 Effects](ocaml-effects.md)** | Native continuations | Untyped (runtime)  | One-shot continuations in the runtime; deep/shallow handlers      |
| **[Eio](ocaml-eio.md)**                 | Direct-style I/O     | Capability passing | Direct-style I/O built on OCaml 5 effects; structured concurrency |

### Rust Effect Approaches

| Approach                                      | Mechanism                                   | Requires Nightly | Effect Tracking              |
| --------------------------------------------- | ------------------------------------------- | ---------------- | ---------------------------- |
| **[Implicit Effects](rust-effect-system.md)** | Language features (async, ?, unsafe, const) | No               | Per-keyword; not unified     |
| **[effing-mad](rust-effing-mad.md)**          | Coroutine-based algebraic effects           | Yes (coroutines) | Trait-based effect sets      |
| **[CPS Effects](rust-cps-effects.md)**        | CPS encoding on stable Rust                 | No               | Type-level via CPS transform |

### Industry Platforms

| System                             | Language    | Approach                        | Relationship to AE                              |
| ---------------------------------- | ----------- | ------------------------------- | ----------------------------------------------- |
| **[Effect](typescript-effect.md)** | TypeScript  | Effect\<A,E,R\> + generators    | Generator-based; Layer DI; ZIO-inspired         |
| **[Project Loom](java-loom.md)**   | Java        | Virtual threads + continuations | Hidden continuations; no effect typing          |
| **[WasmFX](wasmfx.md)**            | WebAssembly | Typed continuations             | Typed stack switching; multi-language AE target |

### Cross-Cutting Topics

- **[Evolution of Haskell Effect Systems](evolution.md)** -- From mtl to modern approaches
- **[Key Academic Papers](papers.md)** -- Foundational and recent research
- **[Comparison and Analysis](comparison.md)** -- Cross-library synthesis and design trade-offs
- **[Theory and Compilation Strategies](theory-compilation.md)** -- Evidence passing, capability passing, and compilation techniques

---

## Encoding Taxonomy

### By Effect Representation Strategy

| Strategy                     | Description                                                                    | Libraries                         |
| ---------------------------- | ------------------------------------------------------------------------------ | --------------------------------- |
| **Free monad**               | Effects as data; computation tree built then interpreted                       | polysemy, freer-simple            |
| **Carrier fusion**           | Higher-order functors fused at compile time via typeclass instances            | fused-effects                     |
| **ReaderT IO**               | Concrete `IO` monad with extensible environment; effects dispatched via IORef  | effectful, cleff, bluefin         |
| **Delimited continuations**  | Native stack capture via GHC primops; effects handled by resumable prompts     | eff, bluefin-algae                |
| **Hefty algebras**           | Separation of first-order and higher-order effect elaboration                  | heftia                            |
| **Fiber runtime**            | Lightweight green threads with structured concurrency                          | ZIO, Cats Effect                  |
| **Algebraic (open effects)** | Arbitrary number of effect channels tracked at type level                      | Kyo                               |
| **Capability passing**       | Effects accessed via value-level or context-level capability tokens            | bluefin, Scala 3 capabilities, Ox |
| **Row-polymorphic effects**  | Effects tracked via extensible row types with scoped labels and full inference | Koka, Eff                         |
| **Native continuations**     | One-shot delimited continuations built into the language runtime               | OCaml 5                           |
| **Coroutine-based**          | Algebraic effects encoded via language coroutine/generator primitives          | effing-mad (Rust)                 |
| **Implicit/keyword-based**   | Effects expressed through dedicated language keywords (async, unsafe, ?)       | Rust                              |
| **Generator-based**          | Effects encoded via generator functions yielding effect descriptors            | Effect (TypeScript)               |
| **Virtual threads**          | Lightweight threads with hidden continuation support in the runtime            | Java Project Loom                 |
| **Wasm continuations**       | Typed stack switching primitives at the bytecode level                         | WasmFX                            |

### By Type-Level Effect Tracking

| Approach                  | Mechanism                                                                   | Libraries                                 |
| ------------------------- | --------------------------------------------------------------------------- | ----------------------------------------- |
| **Type-level list**       | `Eff (es :: [Effect]) a` with `Member` / `:>` constraints                   | effectful, cleff, polysemy, fused-effects |
| **Fixed type parameters** | `ZIO[R, E, A]` with intersection types for environment                      | ZIO                                       |
| **Typeclass hierarchy**   | `Sync`, `Async`, `Concurrent` etc. constraining `F[_]`                      | Cats Effect                               |
| **Intersection types**    | `A < (Abort[E] & Env[R] & Async)` with contravariant pending effects        | Kyo                                       |
| **Value-level handles**   | ST-like scoped type variables on handle values                              | bluefin                                   |
| **Capture checking**      | Experimental `^{cap}` annotations tracking capability capture in types      | Scala 3 (Caprese)                         |
| **Row types**             | Extensible row types with effect labels; supports full effect inference     | Koka, Eff                                 |
| **Untyped**               | Effects are values at runtime; no static typing of effect sets              | OCaml 5                                   |
| **Ambient abilities**     | Effects as ambient abilities in scope; handler determines what is available | Frank, Unison                             |
| **Three-parameter type**  | `Effect<A, E, R>` encoding success, error, and requirements in one type     | Effect (TypeScript)                       |
| **No tracking**           | Effects are implicit in language features; no unified effect type           | Rust (implicit), Java Loom                |

---

## Quick Reference: Performance Ranking (Haskell, approximate)

Based on [effectful benchmarks](https://github.com/haskell-effectful/effectful/blob/master/benchmarks/README.md) and [community benchmarks](https://github.com/patrickt/effects-benchmarks):

1. **effectful** (static dispatch) -- on par with hand-written `ST` code
2. **effectful** (dynamic dispatch) / **cleff** -- very fast, outperforms mtl in microbenchmarks
3. **eff** -- fast by design via delimited continuations (no reliance on optimizer)
4. **heftia** -- roughly on par with effectful for most scenarios
5. **fused-effects** / **mtl** -- approximately equivalent; near-optimal with GHC optimizations
6. **freer-simple** -- decent for free monad approach but ~30x slower than mtl
7. **polysemy** -- similar to freer-simple with higher initial overhead

---

## Detailed Studies

The following libraries and topics are analyzed in depth:

### Haskell

- **[effectful](haskell-effectful.md)** -- ReaderT IO with evidence passing; fastest dynamic dispatch
- **[cleff](haskell-cleff.md)** -- ReaderT IO with expressive higher-order effect combinators
- **[polysemy](haskell-polysemy.md)** -- Freer monad with Tactics API for higher-order effects
- **[fused-effects](haskell-fused-effects.md)** -- Carrier-based fusion inspired by Wu/Schrijvers
- **[bluefin](haskell-bluefin.md)** -- Value-level handles; ST-like scoping
- **[eff](haskell-eff.md)** -- GHC delimited continuation primops
- **[heftia](haskell-heftia.md)** -- Hefty algebras for sound higher-order effects

### Scala

- **[ZIO](scala-zio.md)** -- Batteries-included effect system with typed errors and ZLayer DI
- **[Cats Effect](scala-cats-effect.md)** -- Typeclass-based pure async runtime with work-stealing fibers
- **[Kyo](scala-kyo.md)** -- Algebraic effects with open effect channels and direct style
- **[Scala 3 Capabilities](scala-capabilities.md)** -- Context functions, capture checking, and Caprese
- **[Ox](scala-ox.md)** -- Direct-style concurrency on virtual threads

### Effect-Native Languages

- **[Koka](koka.md)** -- Row-polymorphic effects with evidence passing and Perceus reference counting
- **[Eff](eff-lang.md)** -- Reference implementation by Bauer and Pretnar; research vehicle for effect handler semantics
- **[Frank](frank.md)** -- Multihandlers with ambient ability and call-by-push-value foundation
- **[Unison](unison.md)** -- Content-addressed language with Frank-inspired abilities

### OCaml

- **[OCaml 5 Effects](ocaml-effects.md)** -- Native one-shot continuations with deep and shallow handlers; untyped effect system
- **[Eio](ocaml-eio.md)** -- Direct-style I/O library built on OCaml 5 effects with capability passing

### Rust

- **[Implicit Effects](rust-effect-system.md)** -- Rust's implicit effect system: async, Result/?, const fn, unsafe as effect-like features
- **[effing-mad](rust-effing-mad.md)** -- Coroutine-based algebraic effects on nightly Rust
- **[CPS Effects](rust-cps-effects.md)** -- CPS-based effect encoding on stable Rust

### Industry Platforms

- **[Effect (TypeScript)](typescript-effect.md)** -- Effect\<A,E,R\> with generator-based encoding and Layer DI; ZIO-inspired
- **[Project Loom (Java)](java-loom.md)** -- Virtual threads with hidden continuations; no algebraic effects but related runtime support
- **[WasmFX](wasmfx.md)** -- Typed continuations for WebAssembly; multi-language compilation target for algebraic effects

### Cross-Cutting

- **[Evolution of Haskell Effect Systems](evolution.md)** -- The path from mtl through free monads to modern approaches
- **[Key Academic Papers](papers.md)** -- Leijen, Wu/Schrijvers, Poulsen, King, and recent ICFP/POPL work
- **[Comparison and Analysis](comparison.md)** -- Unified analysis of trade-offs, design decisions, and recommendations
- **[Theory and Compilation Strategies](theory-compilation.md)** -- Evidence passing, capability passing, and compilation techniques for algebraic effects
