# heftia (Haskell)

A library for higher-order effects and handlers using Hefty algebras. heftia separates the handling of higher-order effects from first-order effects, ensuring sound semantics and full support for both algebraic operations and scoped operations.

| Field         | Value                                                     |
| ------------- | --------------------------------------------------------- |
| Language      | Haskell                                                   |
| License       | BSD-3-Clause                                              |
| Repository    | [github.com/sayo-hs/heftia]                               |
| Documentation | [Hackage (heftia)] / [Hackage (heftia-effects)]           |
| Key Authors   | sayo-hs                                                   |
| Encoding      | Hefty algebras (higher-order effects + algebraic effects) |

---

## Overview

### What It Solves

heftia is the first Haskell library to provide a fully sound implementation of both higher-order effects (scoped operations) and first-order algebraic effects (continuations). Prior libraries like [polysemy] and [fused-effects] offered higher-order effects but had documented unsound cases where combining higher-order and algebraic effects produced incorrect results. heftia solves this through **elaboration** -- higher-order effects are transformed into first-order effects before interpretation.

### Design Philosophy

Based on the [Hefty Algebras] paper (POPL 2023), heftia uses a two-level approach:

1. **Higher-order effects** are treated as elaborations -- definitions of how to transform higher-order syntax into lower-level operations
2. **First-order (algebraic) effects** are handled through standard continuation-based interpretation

This separation ensures that the interaction between higher-order and algebraic effects is always well-defined and sound.

---

## Core Abstractions and Types

### Two-Level Effect System

heftia separates effects into two levels:

```haskell
-- Higher-order effects are "elaborations"
type Elaboration eh ef = forall a. eh (Eff ef) a -> Eff ef a

-- First-order effects are handled algebraically
newtype Eff ef a
```

The key insight: elaborations can be composed and applied first, then the resulting first-order effects are handled normally.

### Soundness Through Separation

| Library         | Higher-Order Effects | Algebraic Effects | Sound Composition           |
| --------------- | -------------------- | ----------------- | --------------------------- |
| [polysemy]      | Yes (Tactics)        | Partial           | **No** (documented unsound) |
| [fused-effects] | Yes (carriers)       | Partial           | **No** (documented unsound) |
| [effectful]     | Yes                  | **No**            | N/A (avoids the problem)    |
| [cleff]         | Yes                  | **No**            | N/A (avoids the problem)    |
| [eff]           | Yes                  | Yes               | Yes (delimited control)     |
| **heftia**      | Yes                  | **Yes**           | **Yes** (elaboration)       |
| [Theseus]       | Yes                  | Yes               | Yes (HO freer)              |

heftia provides all of these simultaneously -- a unique achievement:

- Full algebraic effects (continuation capture/resumption)
- Full higher-order effects (scoped operations)
- Sound composition of both
- Practical performance

---

## How Effects Are Declared

### First-Order Effects (Algebraic)

Like other effect libraries:

```haskell
data State s :: Effect where
  Get :: State s s
  Put :: s -> State s ()
```

### Higher-Order Effects

Declared with elaborations in mind:

```haskell
data Catch e :: EffectH where
  Catch :: m a -> (e -> m a) -> Catch e m a

-- Elaboration: transform Catch into first-order effects
elabCatch :: (Error e :> ef) => Elaboration (Catch e) ef
elabCatch = \case
  Catch m h -> catchError m h
```

The elaboration `elabCatch` transforms the higher-order `Catch` operation into uses of the first-order `Error` effect.

---

## How Handlers/Interpreters Work

### The Two-Phase Process

1. **Elaboration Phase**: Higher-order effects are elaborated into first-order effects

   ```haskell
   elaborate :: Elaborations esh ef -> Eff (esh :++ ef) a -> Eff ef a
   ```

2. **Interpretation Phase**: First-order effects are handled
   ```haskell
   runError :: Eff (Error e : ef) a -> Eff ef (Either e a)
   ```

### Example: Combining Catch and NonDet

The classic unsound case that breaks [polysemy] and [fused-effects]:

```haskell
-- Does the state inside catch get rolled back on exception?
program = catchError (put 10 >> throwError "boom") (\_ -> pure ())
```

In heftia, the interaction is always well-defined because:

- `catchError` is an elaboration that transforms into explicit first-order operations
- The resulting first-order operations interact predictably with `NonDet` or `State`
- Handler ordering semantics are explicit in the elaboration

---

## Performance Approach

### Near-[effectful] Performance

heftia operates at a speed roughly on par with [effectful] and significantly faster than mtl and [polysemy]. The performance comes from:

1. Efficient internal data structures (equivalent to those in [polysemy], [cleff], and [fused-effects])
2. O(1) elaboration dispatch
3. Careful optimization of the two-phase pipeline

### Benchmark Position

- Faster than mtl (often by 1-2 orders of magnitude for deep stacks)
- Faster than [polysemy] (by 1-3 orders of magnitude)
- Roughly comparable to [effectful] (within 2x factor)
- Slower than [eff] (which uses native continuations)

The performance cost of soundness is modest -- heftia proves that you don't need to choose between correctness and speed.

---

## Composability Model

### Effect Composition

Higher-order and first-order effects compose freely:

```haskell
program :: Eff '[Catch String, NonDet, State Int, IO] ()
```

After elaboration:

```haskell
-- Catch is elaborated away
elaborated :: Eff '[NonDet, State Int, Error String, IO] ()
```

Then handled normally.

### Handler Reordering

Because higher-order effects are elaborated first, the interaction semantics are determined by the elaboration definitions, not by handler order surprises.

---

## Strengths

- **Fully sound**: Both higher-order and algebraic effects with correct semantics
- **Near-[effectful] performance**: Practical speed for real applications
- **Pure interpretation possible**: Can interpret to pure values (unlike ReaderT IO approaches)
- **Continuation-based semantics**: True algebraic effects with resumption
- **Based on solid theory**: Direct implementation of [Hefty Algebras] paper

## Weaknesses

- **Newer library**: Smaller community; less battle-tested than [effectful] or [polysemy]
- **Learning curve**: The two-phase elaboration model requires adjustment
- **Semantic differences**: Semantics differ from [effectful], [polysemy], and [fused-effects], which may surprise users of those libraries
- **Documentation**: Still growing; less tutorial material than established libraries

## Key Design Decisions and Trade-offs

| Decision                            | Rationale                                                   | Trade-off                                                           |
| ----------------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------- |
| Hefty algebras (elaboration)        | Sound HO + FO composition                                   | Two-phase mental model; elaboration boilerplate                     |
| Two-level effect system             | Clear separation of concerns                                | More types to understand; new abstraction                           |
| Near-[effectful] performance target | Practical usability                                         | Not the absolute fastest (native continuations faster)              |
| Pure interpretation support         | Testability; reasoning                                      | Some runtime overhead vs ReaderT IO                                 |
| Continuation-based semantics        | Matches algebraic effect theory; enables NonDet, coroutines | Different from [effectful]/[polysemy] semantics; may surprise users |
| Hefty algebra data structure        | Formal basis from POPL paper                                | More complex internals than ReaderT IO approach                     |

---

## Related Work

### [Theseus] (2025)

A recently announced library that also addresses higher-order + algebraic effect soundness:

- Uses a higher-order Freer Monad
- Introduces a `ControlFlow` class for managing finalizers
- Guarantees order-independent interpretations
- Announced on [Haskell Discourse][Theseus announcement]

---

## Sources

- [heftia GitHub repository]
- [heftia on Hackage]
- [heftia-effects on Hackage]
- [Hefty Algebras (POPL 2023)]

<!-- References -->

[polysemy]: haskell-polysemy.md
[fused-effects]: haskell-fused-effects.md
[effectful]: haskell-effectful.md
[cleff]: haskell-cleff.md
[eff]: haskell-eff.md
[Theseus]: haskell-theseus.md
[Hefty Algebras]: papers.md
[github.com/sayo-hs/heftia]: https://github.com/sayo-hs/heftia
[Hackage (heftia)]: https://hackage.haskell.org/package/heftia
[Hackage (heftia-effects)]: https://hackage.haskell.org/package/heftia-effects
[Theseus announcement]: https://discourse.haskell.org/t/theseus-worry-free-algebraic-and-higher-order-effects/13563
[heftia GitHub repository]: https://github.com/sayo-hs/heftia
[heftia on Hackage]: https://hackage.haskell.org/package/heftia
[heftia-effects on Hackage]: https://hackage.haskell.org/package/heftia-effects
[Hefty Algebras (POPL 2023)]: https://doi.org/10.1145/3571255
