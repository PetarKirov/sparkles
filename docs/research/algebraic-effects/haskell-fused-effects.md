# fused-effects (Haskell)

A fast and flexible effect system for Haskell with fused effect handlers, combining the expressiveness of effect systems with near-mtl performance through carrier fusion.

| Field         | Value                                                               |
| ------------- | ------------------------------------------------------------------- |
| Language      | Haskell                                                             |
| License       | BSD-3-Clause                                                        |
| Repository    | [github.com/fused-effects/fused-effects]                            |
| Documentation | [Hackage][fused-effects-hackage]                                    |
| Key Authors   | Rob Rix, Josh Vera, GitHub Semantic team                            |
| Encoding      | Higher-order functors fused at compile time via typeclass instances |

---

## Overview

### What It Solves

fused-effects bridges the gap between mtl (fast but uncomposable) and freer monad approaches (composable but slow). It provides an extensible effect system with higher-order effects (like `catch`, `local`) while achieving performance comparable to mtl through **carrier fusion** -- compile-time optimization of effect handler composition.

The library gained attention when the GitHub Semantic team reported a **250x performance improvement** when migrating from freer monads to fused-effects.

### Design Philosophy

fused-effects is based on the "Fusion for Free" paper (Wu, Schrijvers 2015). The insight is that handler composition can be fused at compile time: instead of running handler A then handler B (two tree traversals), the compiler fuses them into a single handler (one traversal).

The implementation uses higher-order functors as "syntax" for effects and typeclass instances as handlers, enabling GHC to inline and specialize aggressively.

---

## Core Abstractions and Types

### Carrier Pattern

Unlike free/freer monads that build a syntax tree, fused-effects uses **carriers** -- type constructors that directly represent the semantics of combined effects:

```haskell
-- A carrier for State + Error
newtype StateErrorC s e m a = StateErrorC { runStateErrorC :: s -> m (Either e a, s) }

-- A carrier for Reader + IO
newtype ReaderIOC r m a = ReaderIOC { runReaderIOC :: r -> IO a }
```

Carriers are composed by nesting, and GHC's optimizer fuses them into efficient direct code.

### The Has Class

The `Has` class (effect membership) has a crucial functional dependency:

```haskell
class (HFunctor sig, Monad m) => Has sig m | m -> sig where
  send :: sig m a -> m a
```

The `m -> sig` dependency means each monad has exactly one effect signature. This enables efficient compilation but prevents multiple effects of the same type.

### Effect Signatures

Effects are defined as higher-order functors:

```haskell
data State s (m :: Type -> Type) k where
  Get :: State s m s
  Put :: s -> State s m ()
```

The `m` parameter enables higher-order effects -- operations like `catch` that scope over computations.

---

## How Effects Are Declared

### Effect Definition

```haskell
-- First-order effect
data Reader r m k where
  Ask :: Reader r m r
  Local :: (r -> r) -> m a -> Reader r m a  -- higher-order

-- Smart constructors
ask :: Has (Reader r) sig m => m r
ask = send Ask

local :: Has (Reader r) sig m => (r -> r) -> m a -> m a
local f m = send (Local f m)
```

### Effect Constraints

```haskell
program :: (Has (State Int) sig m, Has (Error String) sig m, MonadIO m) => m ()
program = do
  n <- get
  when (n < 0) $ throwError "negative"
  liftIO $ print n
  put (n + 1)
```

The `sig` type represents the combined effect signature; `m` is the carrier monad.

---

## How Handlers/Interpreters Work

### Carrier Instantiation

Handlers are not separate functions but **carrier types** with `Monad` instances:

```haskell
-- State carrier
newtype StateC s m a = StateC { runStateC :: s -> m (a, s) }

instance Monad m => Monad (StateC s m) where
  return a = StateC $ \s -> return (a, s)
  m >>= f = StateC $ \s -> do
    (a, s') <- runStateC m s
    runStateC (f a) s'

instance Monad m => Algebra (State s) (StateC s m) where
  alg hdl sig ctx = StateC $ \s -> case sig of
    Get   -> runStateC (hdl (<$ ctx) s) s
    Put s' -> runStateC (hdl (<$ ctx) ()) s'
```

### Running Effects

```haskell
-- Run State effect
runState :: s -> StateC s m a -> m (a, s)
runState s = runStateC

-- Run Error effect
runError :: ErrorC e m a -> m (Either e a)

-- Composition
program :: IO (Either String (Int, ()))
program = runError $ runState @Int 0 $ do
  n <- get
  when (n < 0) $ throwError "negative!"
  put (n + 1)
```

### Fusion

In fused-effects, this fusion happens because:

1. Carrier types nest: `ErrorC e (StateC s (IO))`
2. GHC inlines the nested `>>=` definitions
3. The resulting code directly manipulates the underlying state

The GitHub Semantic team reported a **250x performance improvement** when moving from a free monad approach to fused-effects.

---

## Performance Approach

### Fusion Mechanism

| Library       | Mechanism         | Dispatch Cost    | Memory      |
| ------------- | ----------------- | ---------------- | ----------- |
| mtl           | Transformer stack | O(n) per bind    | Low         |
| free/freer    | Syntax tree       | O(n) per handler | High (tree) |
| fused-effects | Fused carriers    | O(1)             | Low         |
| [effectful]   | Evidence passing  | O(1)             | Low         |

fused-effects achieves O(1) dispatch by fusing handlers at compile time rather than interpreting at runtime.

### GHC Optimization Dependency

fused-effects relies heavily on GHC's optimizer:

- `-O2` is essential
- `-fexpose-all-unfoldings` and `-fspecialise-aggressively` help
- Compilation times can be longer due to heavy inlining

### Benchmark Position

- **1-3 orders of magnitude** faster than [polysemy] and freer-simple
- Roughly comparable to mtl (within 2x)
- Slightly slower than [effectful] (which benefits from static dispatch)

---

## Composability Model

### Scoped Effects

fused-effects supports scoped operations like `local` and `catchError` directly:

```haskell
scoped :: Has (Reader Int) sig m => m a -> m a
scoped = local (+ 10)

program :: Has (Reader Int) sig m => m Int
program = do
  base <- ask
  modified <- scoped ask
  return (base + modified)  -- base + (base + 10)
```

### Limitations on Soundness

Like [polysemy], fused-effects has documented unsound cases where combinations of higher-order and algebraic effects can produce incorrect results. The library prioritizes ergonomics and performance over semantic purity.

**Example issue**: The interaction of `catchError` with `NonDet` can produce surprising results depending on handler order. The library documents these as known limitations.

---

## Strengths

- **Excellent performance**: 250x improvement over free monads; near-mtl speed
- **Higher-order effects**: `local`, `catchError` work correctly in common cases
- **No O(n²) instances**: Unlike mtl, new effects don't require instances for all others
- **GitHub battle-tested**: Used in production by GitHub Semantic
- **Clean syntax**: No Template Haskell required for most use cases
- **Carrier fusion**: Interesting optimization technique with theoretical backing

## Weaknesses

- **Unsound in some cases**: Higher-order + algebraic effect interactions can be incorrect
- **Slightly slower than [effectful]**: Does not match ReaderT IO performance for most scenarios
- **GHC optimization dependent**: Requires `-O2` and can have longer compile times
- **More complex internals**: Carriers and fusion are harder to understand than simple monads
- **Functional dependency limits**: `m -> sig` prevents some effect patterns
- **Smaller ecosystem than [effectful]**: Less community momentum
- **Maintenance mode**: Core is stable but new development has slowed

## Key Design Decisions and Trade-offs

| Decision                     | Rationale                      | Trade-off                                     |
| ---------------------------- | ------------------------------ | --------------------------------------------- |
| Carrier fusion               | Compile-time optimization      | Complex implementation; GHC-dependent         |
| `Has` class with fundep      | Efficient dispatch             | Multiple same-type effects not possible       |
| Higher-order functors        | Expressive scoped effects      | Conceptual complexity; soundness limitations  |
| No TH required               | Simplicity; faster compile     | More boilerplate for effect definitions       |
| Typeclass-based              | GHC optimization opportunities | Harder to understand than data types          |
| Pure interpretation possible | Testing; reasoning             | Performance cost; cannot use IO optimizations |

---

## Sources

- [fused-effects on Hackage]
- [fused-effects GitHub repository]
- [Fusion for Free (Wu, Schrijvers 2015)]
- [GitHub Semantic's blog post on fused-effects]
- [fused-effects README with examples]

<!-- References -->

[polysemy]: haskell-polysemy.md
[effectful]: haskell-effectful.md
[github.com/fused-effects/fused-effects]: https://github.com/fused-effects/fused-effects
[fused-effects-hackage]: https://hackage.haskell.org/package/fused-effects
[fused-effects on Hackage]: https://hackage.haskell.org/package/fused-effects
[fused-effects GitHub repository]: https://github.com/fused-effects/fused-effects
[Fusion for Free (Wu, Schrijvers 2015)]: https://people.cs.kuleuven.be/~tom.schrijvers/Research/papers/mpc2015.pdf
[GitHub Semantic's blog post on fused-effects]: https://github.blog/2019-09-26-fused-effects-a-250x-speedup/
[fused-effects README with examples]: https://github.com/fused-effects/fused-effects/blob/master/README.md
