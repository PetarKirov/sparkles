# fused-effects (Haskell)

A fast, flexible, fused effect system that achieves near-mtl performance through carrier-based fusion of effect handlers. Developed by the GitHub Semantic team, fused-effects encodes higher-order algebraic effects as higher-order functors and interprets them via typeclass-based carriers.

| Field         | Value                                                                                    |
| ------------- | ---------------------------------------------------------------------------------------- |
| Language      | Haskell                                                                                  |
| License       | BSD-3-Clause                                                                             |
| Repository    | [github.com/fused-effects/fused-effects](https://github.com/fused-effects/fused-effects) |
| Documentation | [Hackage](https://hackage.haskell.org/package/fused-effects)                             |
| Key Authors   | Rob Rix, Patrick Thomson (GitHub Semantic team)                                          |
| Encoding      | Higher-order functor carriers with compile-time fusion                                   |

---

## Overview

### What It Solves

fused-effects provides an encoding of algebraic and higher-order effects that achieves performance approximately on par with mtl. The key innovation is that there is no intermediate free monad representation -- instead, effect interpretation happens directly through carrier typeclass instances, which GHC eagerly inlines, causing multiple handler passes to fuse into a single traversal.

### Design Philosophy

fused-effects values expressivity, efficiency, and rigor. It splits effectful programs into two parts -- **effect types** (syntax) and **carrier types** (semantics) -- following the algebraic effects paradigm. The design is directly inspired by three academic papers: "Effect Handlers in Scope," "Monad Transformers and Modular Algebraic Effects," and "Fusion for Free."

---

## Core Abstractions and Types

### Effects as Higher-Order Functors

Effects are defined as data types (functors) with one constructor per action:

```haskell
data Teletype m k where
  ReadTTY  :: Teletype m String
  WriteTTY :: String -> Teletype m ()
```

The `m` parameter enables higher-order effects, and `k` represents the continuation (the remainder of the computation after the effect).

### Carriers as Interpreters

Carriers are monads that provide semantics for effects via `Algebra` instances:

```haskell
class (HFunctor sig, Monad m) => Algebra sig m where
  alg :: sig m a -> m a
```

Each carrier interprets one or more effects. Multiple carriers can be defined for the same effect, corresponding to different interpretations.

### The Has Constraint

```haskell
type Has eff sig m = (Members eff sig, Algebra sig m)

-- Example:
greet :: Has (Writer String) sig m => m ()
greet = tell "hello"
```

The `Has` constraint combines effect membership with the requirement that the carrier knows how to interpret the effect.

### No Free Monad

Unlike polysemy and freer-simple, fused-effects does **not** build a free monad syntax tree. There is no intermediate representation. Instead, computations are performed directly in the carrier type, and interpretation happens as typeclass method dispatch that GHC inlines and fuses.

---

## How Effects Are Declared

### First-Order Effects

```haskell
data State s m k where
  Get :: State s m s
  Put :: s -> State s m ()
```

### Higher-Order Effects

By specifying effects as higher-order functors, operations like `local` or `catchError` admit multiple interpretations:

```haskell
data Error exc m k where
  Throw :: exc -> Error exc m a
  Catch :: m a -> (exc -> m a) -> Error exc m a
```

In a strictly first-order system, `Catch` would have to be hard-coded as an interpreter. With higher-order functors, it is a first-class operation that can be given different semantics by different carriers.

### The HFunctor and Effect Classes

Effects must be instances of:

- **`HFunctor`**: Higher-order functor map (`hmap :: (forall x. m x -> n x) -> sig m a -> sig n a`)
- **`Effect`**: Provides `handle` for threading carrier state through scoped operations

These instances can be derived via `Generic1` and `deriving stock`.

---

## How Handlers/Interpreters Work

### Carrier-Based Interpretation

Interpretation is defined by writing an `Algebra` instance for a carrier type:

```haskell
newtype StateC s m a = StateC { runStateC :: s -> m (s, a) }

instance Algebra (State s :+: sig) (StateC s m) where
  alg (L Get)     = StateC $ \s -> pure (s, s)
  alg (L (Put s)) = StateC $ \_ -> pure (s, ())
  alg (R other)   = StateC $ \s -> alg (thread (s, ()) other)
```

The `R other` case threads the carrier's state through effects it does not handle, delegating to the next carrier in the stack.

### Effect Sum Types (:+:)

Multiple effects are combined using the `:+:` type-level sum:

```haskell
type sig = State Int :+: Error String :+: Reader Config :+: Lift IO
```

### Running Carriers

```haskell
run :: Identity a -> a                      -- pure result
runM :: LiftC m a -> m a                    -- into a monad
runState :: s -> StateC s m a -> m (s, a)   -- specific carrier runner
```

### InterpretC for Rapid Prototyping

```haskell
runInterpret
  :: (forall ctx n . Functor ctx => Handler ctx n (eff :+: rest) m -> sig n a -> m (ctx a))
  -> InterpretC eff m a
  -> m a
```

`InterpretC` allows interpreting an effect using a passed-in function rather than a dedicated carrier type, suitable for prototyping.

---

## Performance Approach

### Fusion Mechanism

The central performance insight comes from "Fusion for Free" (Wu/Schrijvers, 2015): a sequence of handlers can be fused into one, reducing multiple tree traversals to a single pass with no intermediate tree allocation.

In fused-effects, this fusion happens because:

1. **Carriers are typeclass instances**, which GHC eagerly inlines
2. **No free monad is constructed**, so there are no intermediate syntax trees
3. **Handler composition is implicit** via the carrier stack, not explicit via sequential traversal

The result: performance approximately on par with mtl, without relying on complex `RULES` pragmas.

### Benchmark Position

- **Approximately equal to mtl** in performance
- **Significantly faster than polysemy** and freer-simple (1-3 orders of magnitude)
- **Slightly slower than effectful** (which benefits from static dispatch)
- The GitHub Semantic team reported a **250x performance improvement** when moving from a free monad approach to fused-effects

---

## Composability Model

### Carrier Stacking

Carriers compose by stacking, similar to monad transformers:

```haskell
runApp :: IO (Either String (Int, a))
runApp = runM
       . runError @String
       . runState @Int 0
       $ program
```

### Initial Algebra vs. Final Tagless

Like mtl, fused-effects allows scoped operations like `local` and `catchError` to be given different interpretations. However:

- **mtl** achieves this via final tagless encoding (typeclass methods)
- **fused-effects** achieves this via initial algebra encoding (Carrier instances over syntax types)

The initial algebra approach gives more principled control over interpretation order and makes it easier to define new effects.

---

## Theoretical Foundations

fused-effects is directly inspired by three papers:

1. **"Effect Handlers in Scope"** (Wu, Schrijvers, Hinze, 2014) -- Higher-order effects as higher-order functors
2. **"Monad Transformers and Modular Algebraic Effects"** (Schrijvers, Pirog, Wu, Jaskelioff) -- Connecting transformers with algebraic effects
3. **"Fusion for Free"** (Wu, Schrijvers, 2015) -- Fusing sequential handlers for efficiency

---

## Strengths

- **Near-mtl performance**: Carrier fusion eliminates intermediate representations
- **Principled higher-order effects**: Based on solid theoretical foundations (Wu/Schrijvers)
- **No RULES pragmas needed**: Fusion is a natural consequence of typeclass inlining
- **Flexible interpretation**: Multiple carriers for the same effect; initial algebra encoding
- **Production-tested**: Used in GitHub's Semantic code analysis tool
- **Good documentation**: Comprehensive README, tutorials, and inline docs

## Weaknesses

- **High boilerplate**: Defining new effects requires writing `HFunctor`, `Effect`, and `Algebra` instances
- **Complex carrier types**: Understanding and debugging carrier stacks requires deep familiarity with the library
- **Slower than effectful**: Does not match ReaderT IO performance for most scenarios
- **Unsound higher-order semantics**: Like polysemy, some higher-order effect combinations can produce incorrect results
- **Learning curve**: The initial algebra approach and threading state through carriers is conceptually demanding

## Key Design Decisions and Trade-offs

| Decision                     | Rationale                                     | Trade-off                                                 |
| ---------------------------- | --------------------------------------------- | --------------------------------------------------------- |
| No free monad                | Eliminates tree construction overhead         | Effect semantics less inspectable than with explicit tree |
| Carrier-based interpretation | Fusion via typeclass inlining; near-mtl speed | High boilerplate; complex carrier types                   |
| Higher-order functors        | Principled scoped effects per Wu/Schrijvers   | Requires HFunctor/Effect instances; complexity            |
| Initial algebra encoding     | Clear separation of syntax and semantics      | More code than final tagless (mtl); less familiar         |
| Thread state via `handle`    | Correct higher-order effect semantics         | Difficult to understand; error-prone for custom effects   |

---

## Sources

- [fused-effects on Hackage](https://hackage.haskell.org/package/fused-effects)
- [fused-effects GitHub repository](https://github.com/fused-effects/fused-effects)
- [fused-effects defining effects guide](https://github.com/fused-effects/fused-effects/blob/main/docs/defining_effects.md)
- [Effect Handlers in Scope](https://www.cs.ox.ac.uk/people/nicolas.wu/papers/Scope.pdf) -- Wu, Schrijvers, Hinze (2014)
- [Fusion for Free](https://people.cs.kuleuven.be/~tom.schrijvers/Research/papers/mpc2015.pdf) -- Wu, Schrijvers (2015)
- [effects-benchmarks](https://github.com/patrickt/effects-benchmarks) -- Community benchmarks
