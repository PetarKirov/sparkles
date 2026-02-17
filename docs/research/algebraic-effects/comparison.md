# Comparison and Analysis

Cross-ecosystem comparison of algebraic effect systems and closely related effect platforms.

**Last reviewed:** February 16, 2026.

---

## Reading This Table Correctly

Many production systems called "effect systems" are not full algebraic handler systems. This page separates:

- **full handler semantics** (operations + handlers + resumptions)
- **effect tracking/runtime systems** that solve adjacent problems

---

## The Effect System Trilemma

Every effect system navigates tension between several competing concerns. No system achieves all simultaneously.

| Concern            | Best-in-class                                                           | What it costs                                                                                   |
| ------------------ | ----------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| **Performance**    | effectful, eff, Koka (evidence passing), OCaml 5 (native continuations) | Loses pure interpretation (effectful); stalled development (eff); untyped effects (OCaml 5)     |
| **Expressiveness** | heftia, Koka (row-polymorphic), Effect-TS                               | Conceptual complexity; newer/less battle-tested; runtime overhead (Effect-TS generators)        |
| **Simplicity**     | bluefin, Ox, OCaml 5 Eio                                                | Explicit handle threading (bluefin); no effect handlers (Ox); no static effect typing (OCaml 5) |

---

## 2026 Comparison Matrix

| System / Family                                                    | Effect Typing                                      | Full Handlers?                          | Continuation Strategy                         | Key Strengths                                                         | Current Limits                                                 |
| ------------------------------------------------------------------ | -------------------------------------------------- | --------------------------------------- | --------------------------------------------- | --------------------------------------------------------------------- | -------------------------------------------------------------- |
| **Koka**                                                           | Row-polymorphic effect types with inference        | Yes                                     | Selective CPS + evidence-style compilation    | Strong theory/implementation alignment; practical effect inference    | Smaller ecosystem than mainstream platforms                    |
| **Eff / Effekt / research languages**                              | Varies, usually explicit effects                   | Yes                                     | Interpreter or compiler-specific              | Clean semantics and experimentation velocity                          | Research-oriented tooling/ecosystem                            |
| **OCaml 5 runtime + Eio**                                          | Runtime effects (no effect rows in function types) | Yes (runtime handlers)                  | Native one-shot continuations/fibers          | Direct style, strong multicore story, production language integration | Static effect typing remains an open language-design direction |
| **Haskell effectful / cleff**                                      | Type-level effect lists                            | Not full algebraic handlers (by design) | Reader/environment dispatch over `IO`         | Excellent practical performance and ecosystem interop                 | No general continuation-based algebraic effects                |
| **Haskell continuation-backed libraries (`eff`, `bluefin-algae`)** | Library-specific                                   | Closer to full handlers                 | GHC delimited continuation primops            | Runtime-backed control effects in Haskell                             | API/maintenance maturity varies across libraries               |
| **Haskell hefty-style line (`heftia`)**                            | Algebraic + higher-order structure                 | Yes                                     | Elaborate HO effects before FO interpretation | Strong soundness story for HO interactions                            | Newer ecosystem; higher conceptual load                        |
| **Scala ZIO / Cats Effect**                                        | Typed channels/typeclasses                         | No (not algebraic handlers)             | Fiber runtime on JVM                          | Production-grade concurrency/runtime tooling                          | Different abstraction goal than algebraic handlers             |
| **Scala Kyo**                                                      | Open effect channels                               | Handler-inspired algebraic model        | Runtime/library-specific                      | Direct-style ergonomics with effect tracking                          | Rapidly evolving API/model compared with mature stacks         |
| **Scala 3 capabilities/capture checking**                          | Capability/capture types                           | N/A (language capability system)        | Language-level type discipline                | Promising static reasoning for authority/effects                      | Experimental status in Scala 3.8                               |
| **Effect (TypeScript)**                                            | `Effect<A, E, R>` style channels                   | Handler-inspired library model          | Generator/runtime encoding                    | Strong industrial ergonomics in JS/TS ecosystem                       | Runtime overhead model differs from native runtimes            |
| **WasmFX / stack-switching targets**                               | Low-level typed continuation substrate             | Target-level primitives                 | Runtime/VM continuation support               | Cross-language compilation path for handlers                          | Proposal/toolchain maturity still evolving                     |

---

## Encoding Strategies Compared

### Performance Characteristics

| Encoding                             | Bind Cost      | Dispatch Cost            | Memory         | GHC Optimization Dependency |
| ------------------------------------ | -------------- | ------------------------ | -------------- | --------------------------- |
| **mtl (transformers)**               | O(n) per layer | O(1)                     | Low            | Moderate                    |
| **Free monad**                       | O(1) amortized | O(n) per handler         | High (tree)    | Low                         |
| **Freer monad**                      | O(1) amortized | O(n) per handler         | High (tree)    | Low                         |
| **Carrier fusion**                   | O(1)           | O(1) (fused)             | Low            | High (inlining critical)    |
| **ReaderT IO**                       | O(1)           | O(1)                     | Low            | Low (concrete monad)        |
| **Delimited continuations**          | O(1)           | O(1)                     | Low-Medium     | None (by design)            |
| **Hefty algebras**                   | O(1)           | O(1) per phase           | Medium         | Moderate                    |
| **Row-polymorphic evidence passing** | O(1)           | O(1) via evidence        | Low            | N/A (Koka compiler)         |
| **Native continuations (OCaml)**     | O(1)           | O(1)                     | Low (one-shot) | N/A (OCaml runtime)         |
| **Coroutine-based (Rust)**           | O(1)           | O(1) via coroutine yield | Low-Medium     | N/A (LLVM)                  |
| **Generator-based (TypeScript)**     | O(1) amortized | O(n) per yield           | Medium         | N/A (V8/JIT)                |

### Semantic Properties

| Encoding                         | Captures Continuations | Sound HO Effects        | Pure Interpretation  | Multiple Same-Type Effects |
| -------------------------------- | ---------------------- | ----------------------- | -------------------- | -------------------------- |
| **mtl**                          | No                     | N/A (no HO as data)     | Yes                  | No (fundeps)               |
| **Free monad**                   | Via tree inspection    | No HO effects           | Yes                  | Yes                        |
| **Freer monad**                  | Via tree inspection    | No HO effects           | Yes                  | Yes                        |
| **Carrier fusion**               | Limited                | Partial (unsound cases) | Yes                  | Yes                        |
| **ReaderT IO**                   | No                     | Partial (unsound cases) | No                   | Yes                        |
| **Delimited continuations**      | Yes (native)           | Yes (eff)               | No (IO-based)        | Yes                        |
| **Hefty algebras**               | Yes                    | Yes (fully sound)       | Yes                  | Yes                        |
| **Higher-order freer (Theseus)** | Yes                    | Yes (consistent)        | Yes                  | Yes                        |
| **Row-polymorphic (Koka)**       | Yes (multi-shot)       | N/A (first-order only)  | Yes                  | Yes (labels)               |
| **Native continuations (OCaml)** | Yes (one-shot only)    | N/A                     | No (untyped)         | Yes                        |
| **Coroutine-based (Rust)**       | Yes (via coroutine)    | No                      | Yes (no IO required) | Yes                        |
| **Generator-based (Effect-TS)**  | No (single-shot)       | N/A                     | Yes                  | Yes                        |

---

## The Soundness Question

A critical issue that separates effect systems is the **soundness of higher-order effects**. When a higher-order effect (like `catch` or `local`) scopes over a computation that uses algebraic effects (like `NonDet` or `Coroutine`), the interaction can produce incorrect results. Different libraries give different answers, and some give inconsistent answers depending on handler ordering.

| Library       | Higher-Order Effects   | Algebraic Effects         | Sound Interaction                                                                       |
| ------------- | ---------------------- | ------------------------- | --------------------------------------------------------------------------------------- |
| polysemy      | Yes (Tactics)          | Partial                   | **No** -- documented unsound cases                                                      |
| fused-effects | Yes (carriers)         | Partial                   | **No** -- same class of issues                                                          |
| effectful     | Yes                    | **No** (no continuations) | N/A (avoids the problem)                                                                |
| cleff         | Yes                    | **No**                    | N/A                                                                                     |
| eff           | Yes                    | **Yes**                   | **Yes** -- consistent delimited control semantics                                       |
| heftia        | Yes                    | **Yes**                   | **Yes** -- elaboration ensures soundness                                                |
| Theseus       | Yes                    | **Yes**                   | **Yes** -- order-independent interpretation                                             |
| Koka          | N/A (first-order only) | **Yes**                   | N/A -- no higher-order effects; first-order algebraic effects are sound by construction |
| OCaml 5       | N/A                    | **Yes** (untyped)         | N/A -- no static guarantees; soundness is the programmer's responsibility               |
| Eff           | N/A (first-order only) | **Yes**                   | N/A -- reference semantics by Plotkin/Pretnar                                           |
| Frank         | Yes (multihandlers)    | **Yes**                   | **Yes** -- ambient ability with CBPV ensures consistent semantics                       |

The effectful/cleff approach sidesteps the problem entirely by not supporting algebraic effects (no continuation capture). This is a pragmatic choice that works well for most applications.

---

## Where the Frontier Actually Is

### 1. Semantic soundness

The hardest unsolved practical issue is still the interaction of higher-order effects, resumptions, and resource management. Work since 2023 (Hefty and follow-ups) is the most important movement here.

### 2. Performance without semantic collapse

The current best results avoid a single universal technique:

- Evidence-passing style dispatch for common operations
- Selective continuation capture when needed
- Runtime primitives where available

This combination replaces the old "handlers are elegant but too slow" narrative.

### 3. Parallel and resource-sensitive handlers

2024-2025 papers push handlers into parallel, affine, and temporal regimes. This is a major shift from earlier single-threaded, mostly first-order benchmarks.

### 4. Mainstream language integration

OCaml and GHC runtime support, plus Wasm target work, suggest long-term success depends on runtime/compiler cooperation, not only library encodings.

---

## Practical Selection Guide

### If your primary goal is production reliability today

- Haskell: `effectful`/`cleff` when continuation-heavy algebraic semantics are not required
- Scala: ZIO or Cats Effect for mature runtime ecosystems
- OCaml: Eio on OCaml 5 for direct-style concurrent systems

### If your primary goal is semantic expressiveness of handlers

- Koka and research languages (Eff/Effekt)
- Haskell hefty-style research line for sound HO composition
- Experimental continuation-backed Haskell libraries

### If your primary goal is language/runtime research

- Parallel handlers (`lambda^p`)
- Affine and temporal effect calculi
- Wasm continuation targets and cross-language lowering

---

## Misleading Comparisons to Avoid

1. **"Effect system" vs "algebraic handlers"** as if equivalent.
2. Microbenchmark-only rankings that ignore modular compilation and optimizer boundaries.
3. Treating "typed effects" as binary: many systems intentionally trade static tracking for runtime ergonomics.

---

## Sources

- [Hefty Algebras (POPL 2023)](https://doi.org/10.1145/3571255)
- [Effect Handlers, Evidently (ICFP 2020)](https://doi.org/10.1145/3408981)
- [Generalized Evidence Passing (ICFP 2021)](https://doi.org/10.1145/3473576)
- [Retrofitting Effect Handlers onto OCaml (PLDI 2021)](https://doi.org/10.1145/3453483.3454039)
- [Parallel Algebraic Effect Handlers (ICFP 2024)](https://doi.org/10.1145/3674651)
- [A Framework for Higher-Order Effects and Handlers (ICFP 2024)](https://doi.org/10.1145/3674632)
- [Abstracting Effect Systems for Algebraic Effect Handlers (ICFP 2024)](https://doi.org/10.1145/3674630)
- [Affect: Affine Algebraic Effect Handlers (POPL 2025)](https://doi.org/10.1145/3704831)
- [Algebraic Temporal Effects (POPL 2025)](https://doi.org/10.1145/3704853)
- [Asymptotic Speedup via Effect Handlers (POPL 2025)](https://doi.org/10.1145/3704871)
- [OCaml 5.3.0 release notes](https://ocaml.org/releases/5.3.0)
- [GHC 9.6.1 release notes](https://downloads.haskell.org/~ghc/9.6.5/docs/users_guide/9.6.1-notes.html)
- [Scala 3.8 release announcement (2026-01-21)](https://www.scala-lang.org/blog/2026/01/21/scala-3.8.html)
- [WebAssembly stack-switching proposal repo](https://github.com/WebAssembly/stack-switching)
- [effects-bibliography](https://github.com/yallop/effects-bibliography)
