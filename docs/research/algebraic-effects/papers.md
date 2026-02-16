# Key Academic Papers on Algebraic Effects

A curated bibliography of foundational and recent research papers on algebraic effects, effect handlers, and their practical implementation in programming languages.

---

## Foundational Papers

### "Algebraic Effects for Functional Programming" (Leijen, 2016)

| Field    | Value                                                                                                      |
| -------- | ---------------------------------------------------------------------------------------------------------- |
| Authors  | Daan Leijen                                                                                                |
| Venue    | Microsoft Research Technical Report (MSR-TR-2016-29)                                                       |
| PDF      | [microsoft.com](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/08/algeff-tr-2016-v2.pdf) |
| Language | Koka                                                                                                       |

**Key Ideas:**

1. **Generalization of common constructs**: Exception handling, state, iterators, and async-await are all instances of algebraic effects
2. **Row-polymorphic effect types**: Effects tracked via extensible row types with scoped labels; full type inference
3. **Free composition**: Unlike general monads, algebraic effects compose freely (restricted to the free monad)
4. **Delimited continuations**: Effect handlers capture delimited continuations; the `resume` variable is bound to the captured continuation
5. **Efficient compilation**: Compilation scheme targeting JavaScript, JVM, and .NET
6. **Semantic soundness**: Formal theorem that well-typed terms either diverge or reduce to values

**Significance**: Brought Plotkin and Pretnar's theoretical work into a practical, fully typed functional programming language with inference and efficient compilation. Demonstrated that algebraic effects are a viable alternative to monads for structuring effectful computation.

---

### "Handlers of Algebraic Effects" (Plotkin, Pretnar, 2009)

| Field   | Value                          |
| ------- | ------------------------------ |
| Authors | Gordon Plotkin, Matija Pretnar |
| Venue   | ESOP 2009                      |

**Key Ideas:**

- Original introduction of effect handlers as a programming abstraction
- Effects modeled as operations of an algebraic theory
- Handlers give semantics by folding over the syntax tree of operations
- Established the theoretical foundation for all subsequent work

**Significance**: The paper that started the algebraic effects movement. All libraries and languages implementing algebraic effects trace back to this work.

---

### "Effect Handlers in Scope" (Wu, Schrijvers, Hinze, 2014)

| Field   | Value                                                                     |
| ------- | ------------------------------------------------------------------------- |
| Authors | Nicolas Wu, Tom Schrijvers, Ralf Hinze                                    |
| Venue   | Haskell Symposium 2014                                                    |
| PDF     | [cs.ox.ac.uk](https://www.cs.ox.ac.uk/people/nicolas.wu/papers/Scope.pdf) |

**Key Ideas:**

1. **The scoping problem**: Standard algebraic effect handlers cannot express scoping constructs (operations that delimit a region of computation, like `local`, `catch`, `mask`)
2. **Higher-order syntax**: Introduces effects as higher-order functors, where constructors can take monadic computations as arguments
3. **Two encoding approaches**: First uses existing handlers (limited); second introduces higher-order syntax (general)
4. **Reorderable handlers**: Different semantics achieved by reordering handlers

**Significance**: Identified and solved a fundamental limitation of first-order algebraic effects. Directly inspired fused-effects and polysemy's higher-order effect support. Showed that operations like `local` and `catchError` need higher-order treatment to admit flexible interpretation.

---

### "Fusion for Free: Efficient Algebraic Effect Handlers" (Wu, Schrijvers, 2015)

| Field   | Value                                                                                    |
| ------- | ---------------------------------------------------------------------------------------- |
| Authors | Nicolas Wu, Tom Schrijvers                                                               |
| Venue   | MPC 2015                                                                                 |
| PDF     | [kuleuven.be](https://people.cs.kuleuven.be/~tom.schrijvers/Research/papers/mpc2015.pdf) |

**Key Ideas:**

1. **The efficiency problem**: Sequential handler application constructs and traverses intermediate syntax trees, which is painfully inefficient
2. **Handler fusion**: A sequence of handlers can be fused into a single handler, reducing multiple tree traversals to one pass
3. **Abstract free monads**: Keeping the free monad abstract enables a change of representation that opens up fusion
4. **Compile-time fusion**: The fused code can be inlined at compile time to produce efficient handlers
5. **Extension to higher-order**: The technique is expected to extend to higher-order functors

**Significance**: Solved the performance problem of algebraic effect handlers. The GitHub Semantic team used these ideas in fused-effects, achieving a 250x performance improvement. The paper bridges the gap between the elegance of algebraic effects and practical performance.

---

### "Freer Monads, More Extensible Effects" (Kiselyov, Ishii, 2015)

| Field   | Value                                                          |
| ------- | -------------------------------------------------------------- |
| Authors | Oleg Kiselyov, Hiromi Ishii                                    |
| Venue   | Haskell Symposium 2015                                         |
| PDF     | [okmij.org](https://okmij.org/ftp/Haskell/extensible/more.pdf) |

**Key Ideas:**

1. **Freer monad**: Removes the Functor constraint from free monads by CPS-encoding the continuation
2. **Open union**: Type-safe, extensible union for combining effects
3. **Efficient sequence**: Uses a type-aligned sequence for O(1) bind (amortized), avoiding the quadratic overhead of naive free monads
4. **Subsumes monad transformers**: The framework generalizes monad transformers while overcoming their limitations

**Significance**: The practical breakthrough for extensible effects in Haskell. Spawned freer-simple, polysemy, and influenced all subsequent libraries. Showed that effects could be extensible without the boilerplate of mtl.

---

### "Hefty Algebras: Modular Elaboration of Higher-Order Algebraic Effects" (Poulsen, van der Rest, 2023)

| Field   | Value                                                    |
| ------- | -------------------------------------------------------- |
| Authors | Casper Bach Poulsen, Cas van der Rest                    |
| Venue   | POPL 2023 (Proc. ACM Program. Lang. 7, POPL, Article 62) |

**Key Ideas:**

1. **The soundness problem**: Existing approaches to higher-order effects (polysemy's Tactics, fused-effects' carriers) have unsound interactions with algebraic effects
2. **Elaboration**: Higher-order effects should be transformed (elaborated) into first-order effects, not handled directly alongside them
3. **Hefty algebras**: Algebraic structures that generalize free monads to higher-order functors, enabling modular elaboration
4. **Two-phase processing**: Elaborate HO effects first, then interpret FO effects -- this separation ensures soundness
5. **Modularity**: Different elaborations can be composed modularly

**Significance**: The first theoretically sound solution to combining higher-order and algebraic effects. Directly implemented in the heftia library. Represents the current state of the art in effect system theory.

---

### "Do Be Do Be Do" (Lindley, McBride, McLaughlin, 2017)

| Field    | Value                                        |
| -------- | -------------------------------------------- |
| Authors  | Sam Lindley, Conor McBride, Craig McLaughlin |
| Venue    | POPL 2017                                    |
| Language | Frank                                        |

**Key Ideas:**

1. **Multihandlers**: Handlers that can simultaneously handle multiple computations, enabling direct expression of binary operators over effectful computations
2. **Ambient ability**: Effects are ambient in Frank -- a computation's type describes what effects are available, not what effects it uses
3. **Call-by-push-value (CBPV)**: Frank's type system is based on CBPV, distinguishing values from computations at the type level
4. **No explicit `resume`**: In Frank, the continuation is implicit in the handler clause structure rather than an explicit variable
5. **Bidirectional typing**: The type system uses bidirectional type checking for practical type inference

**Significance**: Introduced a fundamentally different approach to effect handlers where handlers are multi-argument and effects are ambient rather than tracked. Influenced Unison's ability system and ongoing research into effect handler design. The CBPV foundation provides a clean theoretical basis that avoids many complications of monadic effect systems.

---

### "Retrofitting Effect Handlers onto OCaml" (Sivaramakrishnan et al., 2021)

| Field    | Value                                                                                     |
| -------- | ----------------------------------------------------------------------------------------- |
| Authors  | KC Sivaramakrishnan, Stephen Dolan, Leo White, Sadiq Jaffer, Anil Madhavapeddy, Tom Kelly |
| Venue    | PLDI 2021                                                                                 |
| Language | OCaml 5                                                                                   |

**Key Ideas:**

1. **One-shot continuations**: OCaml 5 provides only one-shot (non-copyable) continuations, which simplifies implementation and avoids the complexity of multi-shot semantics
2. **Fiber-based runtime**: Effects are implemented via lightweight fibers with stack segments, enabling efficient context switching
3. **Untyped effects**: A deliberate design choice -- effects are dynamically typed at the handler boundary, allowing the runtime to ship before the type system is fully designed
4. **Deep and shallow handlers**: Both handler styles are supported; deep handlers automatically re-wrap the continuation, while shallow handlers give the programmer explicit control
5. **Backwards compatibility**: The design maintains full backwards compatibility with existing OCaml 4 code

**Significance**: The most significant practical deployment of algebraic effect handlers into a mainstream language runtime. Demonstrated that effect handlers can be retrofitted onto an existing language with a large codebase. The decision to ship untyped effects first was controversial but pragmatic, enabling the ecosystem (especially Eio) to develop while typed effects research continues.

---

### "Effect Handlers, Evidently" (Xie, Leijen, Brachthäuser, 2020)

| Field   | Value                                                     |
| ------- | --------------------------------------------------------- |
| Authors | Ningning Xie, Daan Leijen, Jonathan Immanuel Brachthäuser |
| Venue   | ICFP 2020                                                 |

**Key Ideas:**

1. **Evidence passing**: Effect handlers can be compiled by passing evidence (handler implementations) as extra function parameters, rather than using continuations or free monads
2. **Evidence vectors**: A runtime representation where each effect in scope has an entry in an evidence vector, enabling O(1) effect dispatch
3. **Tail-resumptive optimization**: Handlers that always resume at the tail position (the common case) can be optimized to avoid capturing continuations entirely
4. **Connection to capability passing**: Evidence passing is shown to be equivalent to capability passing, unifying two previously separate compilation strategies
5. **Typed, efficient compilation**: The approach preserves full effect typing while achieving performance competitive with direct function calls

**Significance**: Provided the theoretical foundation for efficient compilation of algebraic effects without relying on CPS transforms or runtime continuation support. Directly influenced Koka's compilation strategy and connects to effectful's ReaderT IO pattern. Established evidence passing as a key compilation technique that bridges the gap between algebraic effects theory and practical implementation.

---

### "Structured Asynchrony with Algebraic Effects" (Leijen, 2017)

| Field    | Value                                                |
| -------- | ---------------------------------------------------- |
| Authors  | Daan Leijen                                          |
| Venue    | Microsoft Research Technical Report (MSR-TR-2017-21) |
| Language | Koka                                                 |

**Key Ideas:**

1. **Async/await as algebraic effects**: The async/await pattern found in C#, JavaScript, and other languages is shown to be a specific instance of algebraic effects with a particular handler
2. **Structured concurrency via effects**: Algebraic effects naturally provide structured concurrency -- the handler (scope) determines the lifetime of concurrent operations
3. **Interleaving and cancellation**: Effect handlers can express interleaving, cancellation, and timeout patterns without special language support
4. **Composable async**: Unlike built-in async/await, the algebraic effects version composes with other effects (exceptions, state, nondeterminism)

**Significance**: Demonstrated that algebraic effects subsume async/await, providing a more general and composable approach to asynchronous programming. This insight influenced the design of structured concurrency in Koka and informed discussions about async in other languages including Rust and OCaml.

---

## Recent Papers (2024-2025)

### "Abstracting Effect Systems for Algebraic Effect Handlers" (ICFP 2024)

| Field   | Value                        |
| ------- | ---------------------------- |
| Authors | Yoshioka, Sekiyama, Igarashi |
| Venue   | ICFP 2024                    |

Shows that effect algebras meeting certain safety conditions can accommodate existing effect systems and proposes a framework for comparing effect system designs. Extends the framework to lift coercions and type-erasure semantics.

---

### "Parallel Algebraic Effect Handlers" (ICFP 2024)

| Field   | Value                                   |
| ------- | --------------------------------------- |
| Authors | Ningning Xie et al.                     |
| Venue   | ICFP 2024 (PACMPL Volume 8, Issue ICFP) |

Addresses the limitation that algebraic effects typically require sequential execution. Proposes a design for parallel effect handlers, enabling concurrent execution of effect operations.

---

### "Algebraic Effects and Handlers for Arrows" (ICFP 2024)

| Field | Value                       |
| ----- | --------------------------- |
| Venue | ICFP 2024 (JFP First paper) |

Extends algebraic effects to the arrow calculus, with operational and denotational semantics. Shows that the algebraic effects paradigm can be applied beyond monadic computation.

---

### "Soundly Handling Linearity" (POPL 2024)

| Field   | Value                              |
| ------- | ---------------------------------- |
| Authors | Tang, Hillerstrom, Lindley, Morris |
| Venue   | POPL 2024 (Article 54)             |

Addresses the interaction between linear types and effect handlers. Ensures that linear resources are properly managed in the presence of continuation capture and resumption.

---

### "An Intrinsically Typed Compiler for Algebraic Effect Handlers" (PEPM 2024)

| Field   | Value                   |
| ------- | ----------------------- |
| Authors | Tsuyama, Cong, Masuhara |
| Venue   | PEPM 2024 at POPL 2024  |

Formalizes a type-preserving compiler from an effect handler calculus to a typed stack-machine assembly language. The main challenge is ensuring safety of continuation capture and resumption during compilation.

---

### "Paella: Algebraic Effects with Parameters and Their Handlers" (HOPE 2024)

| Field   | Value                           |
| ------- | ------------------------------- |
| Authors | Sigal, Kammar, Matache, McBride |
| Venue   | HOPE 2024 at ICFP 2024          |

Develops algebraic effects with resumptions structured after Kripke possible-world semantics. Can express dynamic allocation effects such as dynamically allocated full ground reference cells. Implementation in Idris 2.

---

### "Context-Dependent Effects in Guarded Interaction Trees" (ESOP 2025)

| Field   | Value                                         |
| ------- | --------------------------------------------- |
| Authors | Stepanenko, Nardino, Frumin, Timany, Birkedal |
| Venue   | ESOP 2025                                     |

Explores context-dependent effects in the framework of guarded interaction trees, published in Programming Languages and Systems, May 2025.

---

## Active Research Directions

Based on the 2024-2025 papers and ongoing language development, the field is actively pursuing:

1. **Parallelism**: Enabling concurrent execution of effect operations
2. **Abstraction**: Frameworks for comparing and unifying different effect system designs
3. **Compilation**: Type-preserving compilation of effect handlers to efficient machine code
4. **Linearity**: Sound interaction between linear types and effect handlers
5. **Dependent types**: Effects in dependently typed languages (Idris 2, Agda)
6. **Capability safety**: Tracking effect permissions through type systems (Scala 3 Caprese)
7. **WebAssembly effect handlers**: The WasmFX proposal for typed continuations in WebAssembly, enabling efficient cross-language compilation of algebraic effects to the web platform
8. **Typed effects for OCaml**: Active research into adding static effect typing to OCaml 5, building on the untyped runtime foundation already shipped
9. **Effect systems for systems programming**: Exploration of algebraic effects in ownership-based languages like Rust, including the keyword generics initiative and library-level encodings (effing-mad, CPS effects)
10. **Industrial adoption**: Growth of Effect-TS ecosystem demonstrating viability of effect system concepts in mainstream TypeScript/JavaScript development; influence on language design discussions

---

## Comprehensive Bibliography

For a complete, community-maintained bibliography of algebraic effects research, see:

- [effects-bibliography](https://github.com/yallop/effects-bibliography) -- maintained by Jeremy Yallop et al.
- [My Effects Bibliography](https://www.dantb.dev/posts/effects-bibliography/) -- curated list by Dan Thomas-Sherwood

---

## Sources

- [Algebraic Effects for Functional Programming](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/08/algeff-tr-2016-v2.pdf) -- Leijen
- [Effect Handlers in Scope](https://www.cs.ox.ac.uk/people/nicolas.wu/papers/Scope.pdf) -- Wu, Schrijvers, Hinze
- [Fusion for Free](https://people.cs.kuleuven.be/~tom.schrijvers/Research/papers/mpc2015.pdf) -- Wu, Schrijvers
- [Freer Monads, More Extensible Effects](https://okmij.org/ftp/Haskell/extensible/more.pdf) -- Kiselyov, Ishii
- [Algebraic Effects and Handlers Summer School](https://www.cs.uoregon.edu/research/summerschool/summer25/_lectures/Xie-slides-3.pdf) -- Xie
- [effects-bibliography on GitHub](https://github.com/yallop/effects-bibliography)
- [ICFP 2024 program](https://icfp24.sigplan.org/)
- [POPL 2024 program](https://popl24.sigplan.org/)
