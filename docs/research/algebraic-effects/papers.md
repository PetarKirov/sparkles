# Key Papers on Algebraic Effect Systems

A curated reading map for the history and current frontier of algebraic effects.

**Last reviewed:** February 16, 2026.

---

## How to Use This List

- If you want the **historical core**, read the foundational set first.
- If you want **implementation strategy**, read the compilation/runtime set.
- If you want **state of the art**, read the 2024-2025 frontier set.

---

## Foundational Set (Must Read)

| Year | Paper                                                                                                        | Core Contribution                             |
| ---- | ------------------------------------------------------------------------------------------------------------ | --------------------------------------------- |
| 1991 | [Notions of Computation and Monads](<https://doi.org/10.1016/0890-5401(91)90052-4>) (Moggi)                  | Monadic metalanguage for effects              |
| 2003 | [Algebraic Operations and Generic Effects](<https://doi.org/10.1016/S1571-0661(04)80969-2>) (Plotkin, Power) | Algebraic account of effects and operations   |
| 2009 | [Handlers of Algebraic Effects](https://doi.org/10.1007/978-3-642-00590-9_7) (Plotkin, Pretnar)              | Handlers + resumptions as a programming model |
| 2015 | [An Introduction to Algebraic Effects and Handlers](https://doi.org/10.1016/j.entcs.2015.12.003) (Pretnar)   | Practical tutorial-level consolidation        |

Why this set matters: it defines the semantic vocabulary still used by modern effect systems.

### Handlers of Algebraic Effects (Plotkin, Pretnar, 2009)

**Key Ideas:**

- Original introduction of effect handlers as a programming abstraction
- Effects modeled as operations of an algebraic theory
- Handlers give semantics by folding over the syntax tree of operations
- Established the theoretical foundation for all subsequent work

**Significance:** The paper that started the algebraic effects movement. All libraries and languages implementing algebraic effects trace back to this work.

---

## Practical Language and Compilation Set

| Year | Paper                                                                                                                                     | Why It Matters for Implementers                            |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| 2014 | [Effect Handlers in Scope](https://www.cs.ox.ac.uk/people/nicolas.wu/papers/Scope.pdf)                                                    | Scoped/higher-order effects in real programming patterns   |
| 2015 | [Fusion for Free](https://people.cs.kuleuven.be/~tom.schrijvers/Research/papers/mpc2015.pdf)                                              | Handler fusion and efficiency for free/freer-style systems |
| 2015 | [Freer Monads, More Extensible Effects](https://doi.org/10.1145/2804302.2804319)                                                          | Open unions and extensible effect encoding in Haskell      |
| 2016 | [Algebraic Effects for Functional Programming](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/08/algeff-tr-2016-v2.pdf) | Koka design and row-polymorphic effect typing              |
| 2017 | [Type Directed Compilation of Row-Typed Algebraic Effects](https://doi.org/10.1145/3009837.3009872)                                       | Selective CPS + practical compilation strategy             |
| 2020 | [Effect Handlers, Evidently](https://doi.org/10.1145/3408981)                                                                             | Evidence passing for efficient handler dispatch            |
| 2021 | [Generalized Evidence Passing](https://doi.org/10.1145/3473576)                                                                           | Extends evidence passing to general handler programs       |
| 2021 | [Retrofitting Effect Handlers onto OCaml](https://doi.org/10.1145/3453483.3454039)                                                        | Mainstream runtime integration with one-shot handlers      |
| 2023 | [Continuing WebAssembly with Effect Handlers](https://doi.org/10.1145/3622814)                                                            | Typed continuation target in Wasm for handler compilation  |

### Effect Handlers in Scope (Wu, Schrijvers, Hinze, 2014)

**Key Ideas:**

1. **The scoping problem**: Standard algebraic effect handlers cannot express scoping constructs (operations that delimit a region of computation, like `local`, `catch`, `mask`)
2. **Higher-order syntax**: Introduces effects as higher-order functors, where constructors can take monadic computations as arguments
3. **Two encoding approaches**: First uses existing handlers (limited); second introduces higher-order syntax (general)

**Significance:** Identified and solved a fundamental limitation of first-order algebraic effects. Directly inspired fused-effects and polysemy's higher-order effect support. Showed that operations like `local` and `catchError` need higher-order treatment to admit flexible interpretation.

### Fusion for Free (Wu, Schrijvers, 2015)

**Key Ideas:**

1. **The efficiency problem**: Sequential handler application constructs and traverses intermediate syntax trees
2. **Handler fusion**: A sequence of handlers can be fused into a single handler, reducing multiple tree traversals to one pass
3. **Abstract free monads**: Keeping the free monad abstract enables a change of representation that opens up fusion

**Significance:** Solved the performance problem of algebraic effect handlers. The GitHub Semantic team used these ideas in fused-effects, reporting a 250x performance improvement over their previous free-monad approach.

### Freer Monads, More Extensible Effects (Kiselyov, Ishii, 2015)

**Key Ideas:**

1. **Freer monad**: Removes the Functor constraint from free monads by CPS-encoding the continuation
2. **Open union**: Type-safe, extensible union for combining effects
3. **Efficient sequence**: Uses a type-aligned sequence for O(1) bind (amortized)

**Significance:** The practical breakthrough for extensible effects in Haskell. Spawned freer-simple, polysemy, and influenced all subsequent libraries. Showed that effects could be extensible without the boilerplate of mtl.

### Algebraic Effects for Functional Programming (Leijen, 2016)

**Key Ideas:**

1. **Row-polymorphic effect types**: Effects tracked via extensible row types with scoped labels; full type inference
2. **Free composition**: Unlike general monads, algebraic effects compose freely
3. **Delimited continuations**: Effect handlers capture delimited continuations; the `resume` variable is bound to the captured continuation
4. **Efficient compilation**: Compilation scheme targeting JavaScript, JVM, and .NET

**Significance:** Brought Plotkin and Pretnar's theoretical work into a practical, fully typed functional programming language (Koka) with inference and efficient compilation. Demonstrated that algebraic effects are a viable alternative to monads for structuring effectful computation.

### Effect Handlers, Evidently (Xie, Leijen, Brachthäuser, 2020)

**Key Ideas:**

1. **Evidence passing**: Effect handlers can be compiled by passing evidence (handler implementations) as extra function parameters, rather than using continuations or free monads
2. **Evidence vectors**: A runtime representation where each effect in scope has an entry in an evidence vector, enabling O(1) effect dispatch
3. **Tail-resumptive optimization**: Handlers that always resume at the tail position (the common case) can be optimized to avoid capturing continuations entirely
4. **Connection to capability passing**: Evidence passing is shown to be equivalent to capability passing

**Significance:** Provided the theoretical foundation for efficient compilation of algebraic effects without relying on CPS transforms or runtime continuation support. Directly influenced Koka's compilation strategy and connects to effectful's ReaderT IO pattern.

### Retrofitting Effect Handlers onto OCaml (Sivaramakrishnan et al., 2021)

**Key Ideas:**

1. **One-shot continuations**: OCaml 5 provides only one-shot (non-copyable) continuations, simplifying implementation
2. **Fiber-based runtime**: Effects implemented via lightweight fibers with stack segments
3. **Untyped effects**: A deliberate design choice -- effects are dynamically typed at the handler boundary, allowing the runtime to ship before the type system is fully designed
4. **Deep and shallow handlers**: Both handler styles are supported

**Significance:** The most significant practical deployment of algebraic effect handlers into a mainstream language runtime. Demonstrated that effect handlers can be retrofitted onto an existing language with a large codebase. The decision to ship untyped effects first was controversial but pragmatic.

---

## Soundness and Higher-Order Effects

| Year | Paper                                                                                | Problem Addressed                                 |
| ---- | ------------------------------------------------------------------------------------ | ------------------------------------------------- |
| 2023 | [Hefty Algebras](https://doi.org/10.1145/3571255)                                    | Sound modular elaboration of higher-order effects |
| 2024 | [A Framework for Higher-Order Effects and Handlers](https://doi.org/10.1145/3674632) | Unifies multiple higher-order effect formulations |
| 2024 | [Soundly Handling Linearity](https://doi.org/10.1145/3632904)                        | Interaction between linear resources and handlers |

This line of work is central for systems that need both expressive scoped effects and strong semantic guarantees.

### Hefty Algebras (Poulsen, van der Rest, 2023)

**Key Ideas:**

1. **The soundness problem**: Existing approaches to higher-order effects (polysemy's Tactics, fused-effects' carriers) have unsound interactions with algebraic effects
2. **Elaboration**: Higher-order effects should be transformed (elaborated) into first-order effects, not handled directly alongside them
3. **Hefty algebras**: Algebraic structures that generalize free monads to higher-order functors, enabling modular elaboration
4. **Two-phase processing**: Elaborate HO effects first, then interpret FO effects -- this separation ensures soundness

**Significance:** The first theoretically sound solution to combining higher-order and algebraic effects. Directly implemented in the heftia library. Represents the current state of the art in effect system theory.

---

## 2024-2025 Frontier Set (State of the Art)

| Year | Paper                                                                                          | Frontier Direction                                 |
| ---- | ---------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| 2024 | [Parallel Algebraic Effect Handlers](https://doi.org/10.1145/3674651)                          | Parallel handling model (`lambda^p`)               |
| 2024 | [Abstracting Effect Systems for Algebraic Effect Handlers](https://doi.org/10.1145/3674630)    | Meta-framework for comparing effect systems        |
| 2024 | [Effect Handlers for C via Coroutines](https://doi.org/10.1145/3649836)                        | Systems-language implementation path               |
| 2025 | [Affect: Affine Algebraic Effect Handlers](https://doi.org/10.1145/3704831)                    | Affine/resource-sensitive handler semantics        |
| 2025 | [Algebraic Temporal Effects](https://doi.org/10.1145/3704853)                                  | Temporal constraints in effect systems             |
| 2025 | [Asymptotic Speedup via Effect Handlers](https://doi.org/10.1145/3704871)                      | Complexity-level performance results with handlers |
| 2025 | [Deciding Not to Decide: Sound and Complete Effect Inference](https://doi.org/10.1145/3704881) | Advanced inference for modern effect calculi       |

---

## Recommended Reading Orders

### A. History-first path

1. Moggi 1991
2. Plotkin/Power 2003
3. Plotkin/Pretnar 2009
4. Pretnar 2015 tutorial
5. Hefty 2023

### B. Implementation-first path

1. Leijen 2016
2. Leijen 2017 (type-directed compilation)
3. Effect Handlers, Evidently 2020
4. Generalized Evidence Passing 2021
5. OCaml retrofit 2021
6. WasmFX 2023

### C. Frontier-first path

1. Hefty 2023
2. Parallel handlers 2024
3. Abstracting effect systems 2024
4. Affect 2025
5. Algebraic temporal effects 2025

---

## Living Bibliographies

- [Effects Bibliography](https://github.com/yallop/effects-bibliography)
- [Dan Thomas-Sherwood bibliography notes](https://www.dantb.dev/posts/effects-bibliography/)

---

## Notes

- Some production libraries marketed as "effect systems" do not implement full algebraic handlers.
- Conversely, some research systems prioritize semantic guarantees over ecosystem breadth or API ergonomics.
- For architecture decisions, read this page together with [comparison.md](comparison.md) and [theory-compilation.md](theory-compilation.md).
