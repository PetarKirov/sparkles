# Evolution of Algebraic Effect Systems

How the field moved from monads to modern handlers, and what changed by February 2026.

---

## Timeline

| Period    | Milestone                                                | Why It Matters                                                        |
| --------- | -------------------------------------------------------- | --------------------------------------------------------------------- |
| 1991      | Moggi's monadic metalanguage                             | Unified view of computational effects in typed lambda calculi         |
| 2001-2003 | Plotkin and Power's algebraic view of effects            | Connected effect operations to algebraic theories and free models     |
| 2009      | Plotkin and Pretnar: handlers of algebraic effects       | Established handlers as a general programming abstraction             |
| 2013-2017 | Effekt/Eff/Koka era                                      | Practical effect languages and row-polymorphic typing became real     |
| 2014-2015 | Higher-order handlers and fusion (Wu, Schrijvers, Hinze) | Scoped effects and performance techniques for handlers                |
| 2015      | Freer monads in Haskell                                  | Extensible effects with open unions and practical APIs                |
| 2020-2021 | Evidence-passing compilation                             | O(1) operation dispatch and stronger implementation story             |
| 2021      | OCaml handlers in a mainstream runtime                   | Industrial language runtime adopts native handlers                    |
| 2022+     | GHC delimited continuation primops usable in releases    | Runtime substrate for continuation-based effect libraries             |
| 2023      | Hefty Algebras                                           | Modular and sound account of higher-order effect elaboration          |
| 2023      | WasmFX (typed continuations for WebAssembly)             | Cross-language low-level target for control effects                   |
| 2024-2025 | Parallel/affine/temporal research wave                   | Focus shifts to multicore, resource sensitivity, and richer semantics |

---

## Phase 1: Monadic Foundation (1991)

The modern story starts with monads: effects are represented by a type constructor `T` and sequencing laws. This gave a precise semantic framework but made effect composition difficult in practice.

Key result: monads made effects first-class in denotational semantics, but did not by themselves solve modular combination of independent effects.

---

## Phase 2: Algebraic Characterization (2001-2003)

Plotkin and Power showed that many common effects can be described as algebraic operations with equations, and that free constructions provide canonical semantics.

Key result: this reframed effects from ad hoc monadic plumbing to a uniform algebraic theory, setting up handlers naturally.

---

## Phase 3: Handlers as Programming Abstraction (2009)

Plotkin and Pretnar introduced handlers explicitly as interpreters for effect operations and resumptions. This became the conceptual core of almost all later handler systems.

Key result: programs can describe effects abstractly; handlers define concrete behavior locally.

---

## Phase 4: Practical Languages and Libraries (2013-2017)

Two streams matured:

1. **Language designs** (Eff, Koka, later Effekt/Frank) demonstrated usable effect syntax and typing.
2. **Library encodings** (especially in Haskell) explored free/freer and higher-order effect encodings.

Row-polymorphic effect types and type-directed compilation were major breakthroughs in this period.

---

## Phase 5: Performance and Compilation Discipline (2020-2021)

Evidence-passing semantics (ICFP 2020, 2021) gave a concrete answer to a long-standing concern: handlers can be compiled efficiently without abandoning type precision.

Key implementation lesson:

- Keep effect dispatch as direct indexed lookup (evidence vectors/environments)
- Capture continuations only when necessary
- Treat tail-resumptive operations as a fast path

This strongly influenced practical systems and narrowed the performance gap with direct-style code.

---

## Phase 6: Runtime Integration (2021-2025)

### OCaml

- PLDI 2021 formalized the retrofit strategy.
- OCaml 5 delivered one-shot handlers in the runtime.
- OCaml 5.3 (released January 8, 2025) added direct deep-handler syntax (`match ... with effect ...`).
- OCaml 5.4 (released October 9, 2025) continues maturation of the runtime/tooling release train.

### GHC

Delimited continuation primops from Proposal #313 became available in released toolchains (notably the 9.6 line), enabling library experimentation with runtime-backed control operations.

### WebAssembly

WasmFX (OOPSLA 2023) and the stack-switching proposal line position typed continuations/stack control as a cross-language compilation substrate.

---

## Phase 7: Current Research Frontier (2023-2025)

Recent work shifts from "can handlers work?" to "which guarantees and performance envelopes can we prove?"

### 1. Sound higher-order effects

- Hefty Algebras (POPL 2023) separates higher-order elaboration from first-order interpretation.
- Follow-up work studies abstractions over handler frameworks and modularity properties.

### 2. Parallelism and multicore semantics

- Parallel Algebraic Effect Handlers (ICFP 2024) introduces `lambda^p` and a path to parallel handling.
- Work on asymptotic speedups through handlers and multicore runtime models expands this direction.

### 3. Resource-sensitive effects

- Affine/linear handling and temporal effects papers (2025) focus on stronger control over resource usage and ordering guarantees.

### 4. Better cross-framework understanding

- New frameworks compare and abstract over effect systems rather than proposing isolated encodings.

---

## Haskell-Specific Generational Evolution

The Haskell ecosystem provides the clearest case study of how effect encodings evolved in a single language, because each generation directly addressed limitations of its predecessor.

### Generation 1: Monad Transformers (mtl, ~1995+)

Monad transformers compose effects by stacking transformer layers. The `mtl` library provides typeclasses (`MonadState`, `MonadReader`, `MonadError`) that abstract over the concrete stack.

**Strengths:** Well-understood; decades of use; good GHC optimization.

**Limitations:** O(n²) instances (every new transformer requires instances for every existing transformer); lifting overhead accumulates; stack ordering changes semantics.

### Generation 2: Free and Freer Monads (~2008-2015)

Free monads represent effects as data, building a syntax tree interpreted by handlers. The freer monad (Kiselyov, Ishii 2015) removed the Functor constraint and introduced open unions for extensible effects.

**Strengths:** Effects as inspectable data; clean syntax/semantics separation; no O(n²) instance problem.

**Limitations:** ~30x slower than mtl for short stacks in benchmarks; no support for higher-order effects (scoped operations).

### Generation 3: Fused Effects and Higher-Order Effects (~2018-2019)

fused-effects encoded effects as higher-order functors and fused sequential handlers at compile time via typeclass instances. polysemy (2019) added higher-order effects via the Tactics API but prioritized ergonomics over performance.

**Key data point:** The GitHub Semantic team reported a 250x improvement switching from free monads to fused-effects. Sandy Maguire later documented polysemy's performance issues in "Polysemy: Mea Culpa."

### Generation 4: ReaderT IO (~2020+)

effectful and cleff embraced `IO` as the base monad, building extensible environments on top with O(1) integer-indexed dispatch.

**Key insight:** Michael Snoyman's observation that most Haskell applications end up in `IO` anyway, so making the base monad concrete enables dramatic optimizations. effectful's static dispatch is on par with hand-written `ST` code. This generation essentially closed the performance gap.

**Limitation:** Cannot capture delimited continuations (no `NonDet`, `Coroutine`); cannot interpret effects purely.

### Generation 5: Delimited Continuations and Sound HO Effects (~2022+)

Alexis King's GHC Proposal #313 added `prompt#` and `control0#` primops. The eff library demonstrated native continuation performance wins. heftia (2024) implemented hefty algebras for fully sound higher-order + algebraic effects. bluefin-algae uses the primops to add algebraic effects to Bluefin's value-level handles.

**Current landscape (2026):** The Haskell ecosystem now offers four distinct strategies:

1. **effectful/cleff**: Maximum performance, pragmatic IO-based semantics, no algebraic effects
2. **heftia**: Sound semantics, all features, prioritizes theoretical rigor
3. **bluefin + bluefin-algae**: Simple mental model (handles), algebraic effects via primops
4. **eff**: Demonstrates native continuation performance (development stalled, but primops continue to be used)

---

## What Is "State of the Art" in 2026?

State of the art is now best understood as a combination of four properties:

1. **Semantic clarity**: precise meaning of handlers/resumptions, especially with higher-order effects
2. **Compilation efficiency**: evidence passing, selective continuation capture, and runtime support
3. **Concurrency story**: structured concurrency plus emerging parallel-handler models
4. **Adoption path**: workable ergonomics in production ecosystems

Different ecosystems currently optimize different subsets of these properties.

---

## Open Problems

1. **Typed effects in mainstream runtimes**: especially the OCaml path from untyped runtime handlers to typed surface systems.
2. **Stable, ergonomic higher-order abstractions**: balancing formal guarantees with developer usability.
3. **Parallel handlers in production**: moving from calculi/prototypes to robust multicore implementations.
4. **Interop and compilation targets**: proving and engineering reliable lowering to common targets (native, JVM, Wasm).

---

## Sources

- [Notions of Computation and Monads (1991)](<https://doi.org/10.1016/0890-5401(91)90052-4>)
- [Algebraic Operations and Generic Effects (2003)](<https://doi.org/10.1016/S1571-0661(04)80969-2>)
- [Handlers of Algebraic Effects (2009)](https://doi.org/10.1007/978-3-642-00590-9_7)
- [Effect Handlers in Scope (2014)](https://www.cs.ox.ac.uk/people/nicolas.wu/papers/Scope.pdf)
- [Fusion for Free (2015)](https://people.cs.kuleuven.be/~tom.schrijvers/Research/papers/mpc2015.pdf)
- [Freer Monads, More Extensible Effects (2015)](https://doi.org/10.1145/2804302.2804319)
- [Algebraic Effects for Functional Programming (2016)](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/08/algeff-tr-2016-v2.pdf)
- [Type Directed Compilation of Row-Typed Algebraic Effects (2017)](https://doi.org/10.1145/3009837.3009872)
- [Effect Handlers, Evidently (2020)](https://doi.org/10.1145/3408981)
- [Generalized Evidence Passing (2021)](https://doi.org/10.1145/3473576)
- [Retrofitting Effect Handlers onto OCaml (2021)](https://doi.org/10.1145/3453483.3454039)
- [Hefty Algebras (2023)](https://doi.org/10.1145/3571255)
- [Continuing WebAssembly with Effect Handlers (2023)](https://doi.org/10.1145/3622814)
- [Parallel Algebraic Effect Handlers (2024)](https://doi.org/10.1145/3674651)
- [Polysemy: Mea Culpa](https://reasonablypolymorphic.com/blog/mea-culpa/) -- Sandy Maguire
- [GHC Proposal #313](https://github.com/ghc-proposals/ghc-proposals/blob/master/proposals/0313-delimited-continuation-primops.rst)
- [Effects Bibliography (living index)](https://github.com/yallop/effects-bibliography)
- [OCaml 5.3.0 release (2025-01-08)](https://ocaml.org/releases/5.3.0)
- [OCaml releases index (includes 5.4.0, 2025-10-09)](https://ocaml.org/releases/)
- [GHC 9.6.1 release notes (delimited continuation primops)](https://downloads.haskell.org/~ghc/9.6.5/docs/users_guide/9.6.1-notes.html)
