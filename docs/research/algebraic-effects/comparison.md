# Comparison and Analysis

A cross-language synthesis of design trade-offs, encoding strategies, and recommendations for understanding the algebraic effects landscape across Haskell, Scala, Rust, TypeScript, OCaml, Koka, and other languages.

---

## The Fundamental Trade-offs

Every effect system navigates tension between several competing concerns. No system achieves all simultaneously.

### The Effect System Trilemma

```
         Performance
            /\
           /  \
          /    \
         /      \
        /________\
  Expressiveness  Simplicity
```

| concern            | Best-in-class                                                           | What it costs                                                                                   |
| ------------------ | ----------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| **Performance**    | effectful, eff, Koka (evidence passing), OCaml 5 (native continuations) | Loses pure interpretation (effectful); stalled development (eff); untyped effects (OCaml 5)     |
| **Expressiveness** | heftia, Theseus, Koka (row-polymorphic), Effect-TS                      | Conceptual complexity; newer/less battle-tested; runtime overhead (Effect-TS generators)        |
| **Simplicity**     | bluefin, Ox, OCaml 5 Eio                                                | Explicit handle threading (bluefin); no effect handlers (Ox); no static effect typing (OCaml 5) |

### Purity vs. Pragmatism

| Approach          | Libraries                       | Purity                                                        | Pragmatism                                                   |
| ----------------- | ------------------------------- | ------------------------------------------------------------- | ------------------------------------------------------------ |
| Pure, IO-free     | polysemy, fused-effects, heftia | Effects interpretable without IO; testable; composable        | Slower; cannot use IO-based optimizations                    |
| IO-based          | effectful, cleff, bluefin       | Fastest; ecosystem interop; predictable concurrency semantics | Cannot interpret purely; IO semantics leak                   |
| Concrete IO monad | ZIO, Cats Effect                | Maximum runtime optimization; rich concurrency                | Fixed effect set; no algebraic effects                       |
| Effect-native     | Koka, Eff, Frank                | Effects are the language; no purity/pragmatism split          | Smaller ecosystems; less production adoption                 |
| Runtime-native    | OCaml 5, Java Loom              | Continuations in the runtime; zero-cost abstraction           | No static effect typing (OCaml 5); no effect handlers (Loom) |
| Implicit          | Rust                            | Zero-cost abstractions; ownership safety                      | No unified effect system; per-keyword fragmentation          |

### Fixed vs. Open Effect Sets

| Approach                          | Libraries                                 | Flexibility                                           | Cost                                          |
| --------------------------------- | ----------------------------------------- | ----------------------------------------------------- | --------------------------------------------- |
| **Fixed channels**                | ZIO (R,E), Cats Effect (Throwable)        | Simple; well-optimized                                | Cannot add custom effect types                |
| **Open type-level list**          | effectful, cleff, polysemy, fused-effects | Arbitrary effects; precise typing                     | Type complexity; longer compile times         |
| **Open with algebraic semantics** | Kyo, heftia, eff                          | Full algebraic effect power                           | Newer; less ecosystem                         |
| **Value-level handles**           | bluefin                                   | Simple; no type-level effects                         | Must thread handles explicitly                |
| **Row-polymorphic**               | Koka                                      | Full inference; label-based disambiguation            | Row types add conceptual complexity           |
| **Untyped open**                  | OCaml 5                                   | Maximum flexibility; no type overhead                 | No static guarantees about effect handling    |
| **Ambient abilities**             | Frank, Unison                             | Effects as ambient context; handler determines scope  | Less fine-grained control                     |
| **Three-parameter**               | Effect (TypeScript)                       | Typed errors + requirements in one type               | Fixed structure; no arbitrary effect channels |
| **Implicit per-feature**          | Rust                                      | Each feature (async, unsafe, ?) tracked independently | No composition; no user-defined effects       |

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

## Cross-Language Comparison

### Language Philosophy Comparison

| Dimension             | Haskell                                  | Scala                                     | Koka                                 | OCaml 5                       | Rust                          | TypeScript (Effect)       |
| --------------------- | ---------------------------------------- | ----------------------------------------- | ------------------------------------ | ----------------------------- | ----------------------------- | ------------------------- |
| **Primary concern**   | Purity and type safety                   | Pragmatism and JVM integration            | Effect typing as language design     | Runtime performance           | Zero-cost abstractions        | Developer experience      |
| **Effect tracking**   | Type-level effect rows                   | Type parameters (ZIO) or typeclasses (CE) | Row-polymorphic types                | Untyped (runtime)             | Per-keyword implicit          | Three-parameter type      |
| **Base monad**        | IO (effectful) or polymorphic (polysemy) | IO (concrete)                             | Pure (effects in type)               | Direct style                  | No monad (ownership)          | Effect monad              |
| **DI approach**       | Part of the effect system                | ZLayer (ZIO) or external (CE)             | Via effect handlers                  | Capability passing (Eio)      | Trait objects / generics      | Layer system              |
| **Concurrency model** | Green threads via RTS                    | Fiber runtimes on JVM threadpool          | Async as effect                      | Fibers via Eio                | async/await                   | Fibers                    |
| **Community**         | Fragmented across many libraries         | Split between ZIO and Cats Effect         | Small but growing                    | Established (OCaml community) | Large; effect system informal | Growing rapidly           |
| **Direction**         | Toward delimited continuations           | Toward direct style with capabilities     | Toward evidence passing optimization | Toward typed effects (future) | Toward keyword generics       | Toward platform expansion |

### Feature Matrix

| Feature      | effectful        | polysemy         | heftia         | ZIO           | Cats Effect    | Kyo           | Koka                 | OCaml 5            | Effect-TS     | Rust          |
| ------------ | ---------------- | ---------------- | -------------- | ------------- | -------------- | ------------- | -------------------- | ------------------ | ------------- | ------------- |
| Typed errors | No (via effect)  | Yes (via effect) | Yes            | Yes (E param) | No (Throwable) | Yes (Abort)   | Yes (exn effect)     | No (untyped)       | Yes (E param) | Yes (Result)  |
| DI           | No built-in      | No built-in      | No built-in    | ZLayer        | No built-in    | Env effect    | Via handlers         | Capability passing | Layer         | Trait objects |
| Streaming    | No built-in      | No built-in      | No built-in    | ZStream       | fs2 (external) | Built-in      | Iterators as effects | Eio.Flow           | Stream type   | async streams |
| Concurrency  | Via IO           | Via IO           | Via base monad | Fibers        | Fibers         | Async effect  | Async effect         | Eio fibers         | Fibers        | async/await   |
| STM          | Via IO           | No               | No             | Built-in      | Via stm4cats   | No            | No                   | No                 | STM           | No            |
| NonDet       | No               | Partial          | Yes            | No            | No             | Choice effect | Yes                  | No                 | No            | No            |
| Coroutines   | No               | No               | Yes            | No            | No             | No            | Yes                  | Yes (via effects)  | No            | No (nightly)  |
| Pure interp. | No               | Yes              | Yes            | No            | No             | Partial       | Yes                  | No                 | Yes           | N/A           |
| Testing      | Dynamic dispatch | Reinterpret      | Reinterpret    | ZIO Test      | Law testing    | Handler swap  | Handler swap         | Handler swap       | TestLayer     | Trait mocking |

---

## When to Choose What

### Haskell

| If you need...                     | Choose                      | Why                                                                 |
| ---------------------------------- | --------------------------- | ------------------------------------------------------------------- |
| Maximum performance                | **effectful**               | Fastest dispatch; static + dynamic; best ecosystem interop          |
| Simple mental model                | **bluefin**                 | Value-level handles; ST-like scoping; no type-level complexity      |
| Sound HO + algebraic effects       | **heftia**                  | Only fully sound implementation; near-effectful performance         |
| Minimal boilerplate                | **polysemy**                | GADTs + TH; pattern-matching interpreters (accept performance cost) |
| Production carrier-based system    | **fused-effects**           | Battle-tested at GitHub; near-mtl performance; principled theory    |
| Experimentation with continuations | **eff** / **bluefin-algae** | Native GHC primops; true algebraic effects                          |

### Scala

| If you need...                         | Choose                   | Why                                                       |
| -------------------------------------- | ------------------------ | --------------------------------------------------------- |
| Batteries-included production system   | **ZIO**                  | Typed errors, DI, STM, streaming, testing -- all built in |
| Maximum abstraction & ecosystem        | **Cats Effect**          | Tagless final; fs2, http4s, doobie ecosystem              |
| Open algebraic effects                 | **Kyo**                  | Arbitrary effect channels; direct-style aspiration        |
| Simplest direct style                  | **Ox**                   | No wrappers; virtual threads; minimal learning curve      |
| Future-proofing with language features | **Scala 3 Capabilities** | Context functions + capture checking (experimental)       |

### Effect-Native Languages

| If you need...                   | Choose     | Why                                                                                                  |
| -------------------------------- | ---------- | ---------------------------------------------------------------------------------------------------- |
| Production effect-typed language | **Koka**   | Row-polymorphic effects with full inference; evidence passing for performance; Perceus RC for memory |
| Research and prototyping         | **Eff**    | Reference implementation by Bauer/Pretnar; clean semantics for exploring effect handler designs      |
| Multihandler exploration         | **Frank**  | Ambient ability with multihandlers; CBPV foundation; novel approach to effect interaction            |
| Content-addressed codebase       | **Unison** | Frank-inspired abilities; content-addressed code enables unique distribution and versioning model    |

### Other Platforms

| If you need...                    | Choose                                                             | Why                                                                                                                          |
| --------------------------------- | ------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| Effects in TypeScript             | **Effect**                                                         | ZIO-inspired; typed errors + DI via Layer; generator-based encoding; large growing ecosystem                                 |
| Effects in OCaml                  | **OCaml 5 + Eio**                                                  | Native continuations in runtime; Eio for structured concurrency and I/O; direct-style programming                            |
| Effects in Rust                   | **Implicit features** (production) / **effing-mad** (experimental) | Rust has no unified effect system; use async/Result/? for production; effing-mad for algebraic effect exploration on nightly |
| Effects in Java                   | **Project Loom**                                                   | Virtual threads with hidden continuations; not algebraic effects but solves similar concurrency problems                     |
| Multi-language effect compilation | **WasmFX**                                                         | Typed continuations in WebAssembly; compilation target for Koka, OCaml, and other effect-typed languages                     |

---

## The Soundness Question

A critical issue that separates effect systems is the **soundness of higher-order effects**:

### The Problem

When a higher-order effect (like `catch` or `local`) scopes over a computation that uses algebraic effects (like `NonDet` or `Coroutine`), the interaction can produce incorrect results. For example:

```
catch (nondet [1, 2] + nondet [10, 20]) handler
```

The question is whether `catch` captures all nondeterministic branches or just one. Different libraries give different answers, and some give inconsistent answers depending on handler ordering.

### Library Standings

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

## The Future Direction

### Haskell

The Haskell ecosystem is converging on two camps:

1. **Pragmatic IO-based**: effectful and bluefin, with bluefin-algae providing algebraic effects when needed (using GHC 9.6 primops)
2. **Theoretically sound**: heftia and Theseus, providing full algebraic + higher-order effects with formal guarantees

The addition of delimited continuation primops to GHC (Proposal #313) is the most significant infrastructure change, enabling both camps to improve.

### Scala

Scala's trajectory is more unified but longer-term:

1. **Current production**: ZIO and Cats Effect dominate, with Kyo as an emerging algebraic alternative
2. **Near-term**: Ox for direct-style on virtual threads; Kyo approaching 1.0
3. **Long-term**: Scala 3 capabilities + capture checking (Caprese) integrated into the language, potentially replacing library-based effect systems

### OCaml

OCaml 5 introduced native effect handlers but left them **untyped** -- a deliberate pragmatic choice to ship runtime support before solving the type system challenge:

1. **Current**: Eio builds direct-style I/O on top of untyped effects; growing adoption for concurrent applications
2. **Near-term**: Libraries establishing conventions for effect safety through capability passing patterns
3. **Long-term**: Active research into typed effect systems for OCaml; potential future integration of effect types into the language

### Rust

Rust has no unified effect system, but several threads are converging:

1. **Keyword generics initiative**: Exploring ways to abstract over async/const/unsafe, which would partially unify Rust's implicit effect system
2. **effing-mad and CPS approaches**: Demonstrating that algebraic effects can be encoded in Rust, though requiring nightly features or awkward CPS transforms
3. **Ownership as effect tracking**: Rust's borrow checker already provides a form of effect tracking (aliasing, mutability); future work may formalize this connection

### TypeScript

Effect-TS is driving industrial adoption of effect system concepts in the JavaScript ecosystem:

1. **Current**: Rapid growth with Effect\<A,E,R\> providing typed errors, dependency injection, and structured concurrency
2. **Near-term**: Platform expansion (Effect RPC, Effect Schema, Effect Cluster)
3. **Long-term**: Potential influence on TC39 proposals for native effect support in JavaScript

### WebAssembly

WasmFX is the most significant cross-language development:

1. **Typed continuations proposal**: Adding stack switching to WebAssembly, enabling efficient compilation of algebraic effects
2. **Multi-language target**: Koka, OCaml, and other effect-typed languages can compile to Wasm with native continuation support
3. **Browser integration**: Potential to bring algebraic effects to web applications through any language that compiles to Wasm

### Cross-Language Trends

1. **Direct style is ascendant**: Both Haskell (bluefin) and Scala (Ox, Caprese) are moving toward less monadic, more direct programming styles
2. **Runtime support matters**: GHC primops, JVM virtual threads, OCaml 5 continuations, and WasmFX all show that language/runtime support is crucial for performance
3. **Soundness is being taken seriously**: heftia, Theseus, Caprese, and Frank all prioritize formal soundness
4. **Parallelism**: Recent papers (ICFP 2024) address parallel algebraic effects, a previously unexplored area
5. **Evidence passing convergence**: Koka's evidence passing and effectful's ReaderT IO pattern are converging on similar compilation strategies, suggesting a common underlying theory
6. **Industrial adoption accelerating**: Effect-TS, OCaml 5 Eio, and Java Loom show that effect-related concepts are reaching mainstream production use

---

## Sources

- All library-specific sources listed in individual analysis documents
- [effects-bibliography](https://github.com/yallop/effects-bibliography)
- [Algebraic Effects and Handlers Summer School 2025](https://www.cs.uoregon.edu/research/summerschool/summer25/_lectures/Xie-slides-3.pdf)
