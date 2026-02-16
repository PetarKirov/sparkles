# heftia (Haskell)

A Haskell library for algebraic effects grounded in the theory of hefty algebras, providing the first fully sound implementation of both algebraic effects (with delimited continuations) and higher-order effects. Based on the POPL 2023 paper "Hefty Algebras: Modular Elaboration of Higher-Order Algebraic Effects."

| Field         | Value                                                                                                                                           |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | Haskell                                                                                                                                         |
| License       | MPL-2.0                                                                                                                                         |
| Repository    | [github.com/sayo-hs/heftia](https://github.com/sayo-hs/heftia)                                                                                  |
| Documentation | [Hackage (heftia)](https://hackage.haskell.org/package/heftia) / [Hackage (heftia-effects)](https://hackage.haskell.org/package/heftia-effects) |
| Key Authors   | sayo-hs                                                                                                                                         |
| Encoding      | Hefty algebras with elaboration; higher-order freer monad                                                                                       |

---

## Overview

### What It Solves

heftia addresses the fundamental unsoundness that affects higher-order effects in existing libraries like polysemy, fused-effects, and effectful. These libraries can produce incorrect results when certain higher-order effects (like `local`, `catch`, `mask`) interact in specific ways. heftia provides fully sound semantics by separating the interpretation of first-order and higher-order effects through an elaboration mechanism.

### Design Philosophy

heftia is the first effect system -- not just among Haskell libraries but historically across all implementations and languages -- to completely implement both algebraic effects and higher-order effects with full type safety and sound semantics. It prioritizes correctness and theoretical rigor while achieving practical performance roughly on par with effectful.

---

## Core Abstractions and Types

### The Hefty Monad

The core data structure is a "hefty" (higher-order free) monad, derived from the Agda definitions in the original paper. It is essentially a higher-order version of Coyoneda, called HCoyoneda, composed into a free monad structure.

### Two-Level Effect Structure

heftia separates effects into two levels:

1. **First-order effects (algebraic)**: Standard operations like `get`, `put`, `throw` -- these can use delimited continuations
2. **Higher-order effects**: Scoped operations like `local`, `catch`, `mask` -- these are handled through elaboration

This separation is the key theoretical insight. In other libraries, first-order and higher-order effects are mixed in the same interpretation mechanism, which leads to unsound interactions. heftia processes higher-order effects first (via elaboration into first-order effects) and then handles the resulting first-order effects.

### Continuation-Based Semantics

The semantics are almost equivalent to freer-simple and similar to Alexis King's eff library -- this is often called "continuation-based semantics." When an effect operation is performed, the continuation up to the handler is captured and made available for resumption.

---

## How Effects Are Declared

Effects are defined as GADTs, following the standard pattern:

```haskell
-- First-order effect
data State s m a where
  Get :: State s m s
  Put :: s -> State s m ()

-- Higher-order effect
data Error e m a where
  Throw :: e -> Error e m a
  Catch :: m a -> (e -> m a) -> Error e m a
```

The distinction between first-order and higher-order effects is tracked at the type level, enabling the elaboration mechanism.

---

## How Handlers/Interpreters Work

### Elaboration (Higher-Order Effects)

Higher-order effects are processed via **elaboration**: they are transformed into compositions of first-order effects. An elaboration for `Catch` might transform it into operations on first-order `Throw` and continuation manipulation.

The elaboration approach from the paper allows:

- Straightforward treatment of higher-order effects
- Modular combination of different elaborations
- Sound semantics regardless of composition order

### Interpretation (First-Order Effects)

After elaboration, the resulting first-order effects are interpreted using standard algebraic effect handler semantics -- pattern matching on operations with access to delimited continuations.

### Two-Phase Processing

```
Program with HO + FO effects
    |
    v
[Elaboration] -- higher-order effects -> first-order effects
    |
    v
Program with FO effects only
    |
    v
[Interpretation] -- first-order effects -> result
    |
    v
Final result
```

This two-phase approach is what ensures soundness. Other libraries attempt to handle both phases simultaneously, leading to the documented unsoundness issues.

---

## Performance Approach

### Near-effectful Performance

heftia operates at a speed roughly on par with effectful and significantly faster than mtl and polysemy. The performance comes from:

1. Efficient internal data structures (equivalent to those in polysemy, cleff, and fused-effects)
2. No IO monad dependency for the core computation
3. Continuation-based dispatch that avoids unnecessary intermediate representations

### Ongoing Improvements

The author is experimentally testing a new approach based on the "multi-prompt control monad" in a separate repository. If successful, this would address remaining performance gaps compared to effectful.

---

## Composability Model

### Full Feature Set

heftia provides all of these simultaneously -- a unique achievement:

- Higher-order effects
- Delimited continuations (algebraic effects)
- Coroutines (non-scoped resumptions)
- Non-deterministic computations
- MonadUnliftIO compatibility

### No IO Dependency

Unlike effectful, cleff, and bluefin, heftia does not depend on the IO monad and can use any monad as the base monad. Semantics are isolated from IO, meaning asynchronous exceptions and threads do not affect effect behavior.

### Predictable Semantics

The semantics are predictable and based on simple, consistent rules. Unlike libraries where handler ordering can produce surprising results, heftia's elaboration approach ensures that higher-order effects compose soundly.

---

## Theoretical Foundations

### "Hefty Algebras: Modular Elaboration of Higher-Order Algebraic Effects"

- **Authors**: Casper Bach Poulsen, Cas van der Rest
- **Venue**: POPL 2023 (Proc. ACM Program. Lang. 7, POPL, Article 62)
- **Key Insight**: Higher-order effects should be elaborated into first-order effects rather than handled directly. This separation ensures soundness and modularity.

The paper introduces "hefty algebras" -- algebraic structures that generalize free monads to higher-order functors, enabling modular elaboration of higher-order effects.

---

## Strengths

- **Fully sound semantics**: The only library with completely correct higher-order + algebraic effect interaction
- **All effect features**: HO effects, delimited continuations, coroutines, nondeterminism, MonadUnliftIO
- **No IO dependency**: Pure base monad; semantics isolated from IO
- **Theoretical rigor**: Based on peer-reviewed POPL paper with formal proofs
- **Near-effectful performance**: Practical speed for real applications
- **Predictable behavior**: No surprising results from handler ordering

## Weaknesses

- **Newer library**: Smaller community; less battle-tested than effectful or polysemy
- **Two-phase complexity**: The elaboration/interpretation split adds conceptual overhead
- **Semantic differences**: Semantics differ from effectful, polysemy, and fused-effects, which may surprise users of those libraries
- **Learning curve**: Understanding hefty algebras and elaboration requires engaging with the theory
- **Limited ecosystem integration**: Fewer adapters and interop libraries

## Key Design Decisions and Trade-offs

| Decision                     | Rationale                                                   | Trade-off                                                       |
| ---------------------------- | ----------------------------------------------------------- | --------------------------------------------------------------- |
| Elaboration of HO effects    | Sound semantics; modular composition                        | Extra conceptual layer; two-phase processing                    |
| Continuation-based semantics | Matches algebraic effect theory; enables NonDet, coroutines | Different from effectful/polysemy semantics; may surprise users |
| No IO dependency             | Pure semantics; any base monad                              | Cannot use IO-based optimizations (IORef for state)             |
| Hefty algebra data structure | Formal basis from POPL paper                                | More complex internals than ReaderT IO approach                 |
| Full feature support         | No compromises on expressiveness                            | Harder to optimize for specific use cases                       |

---

## Related Work

### Theseus (2025)

A recently announced library that also addresses higher-order + algebraic effect soundness:

- Uses a higher-order Freer Monad
- Introduces a `ControlFlow` class for managing finalizers
- Guarantees order-independent interpretations
- Announced on [Haskell Discourse](https://discourse.haskell.org/t/theseus-worry-free-algebraic-and-higher-order-effects/13563)

---

## Sources

- [heftia on Hackage](https://hackage.haskell.org/package/heftia)
- [heftia-effects on Hackage](https://hackage.haskell.org/package/heftia-effects)
- [heftia GitHub repository](https://github.com/sayo-hs/heftia)
- [How the Heftia Extensible Effects Library Works](https://sayo-hs.github.io/jekyll/update/2024/09/04/how-the-heftia-extensible-effects-library-works.html) (Sept 2024)
- [Heftia: The Next Generation of Haskell Effects Management](https://sayo-hs.github.io/blog/heftia/heftia-rev-part-1-1/)
- [heftia-effects announcement on Haskell Discourse](https://discourse.haskell.org/t/ann-heftia-effects-higher-order-algebraic-effects-done-right/10509) (Oct 2024)
- Casper Bach Poulsen, Cas van der Rest. "Hefty Algebras: Modular Elaboration of Higher-Order Algebraic Effects." POPL 2023.
