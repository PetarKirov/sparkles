# effectful (Haskell)

A fast, flexible, and easy-to-use extensible effects library for Haskell. effectful rethinks the approach of existing effect libraries to provide the best balance of performance, ergonomics, and safety.

| Field         | Value                                                       |
| ------------- | ----------------------------------------------------------- |
| Language      | Haskell                                                     |
| License       | BSD-3-Clause                                                |
| Repository    | [github.com/haskell-effectful/effectful]                    |
| Documentation | [Hackage][effectful-hackage] / [Website][effectful-website] |
| Key Authors   | Andrzej Rybczak                                             |
| Encoding      | ReaderT IO with evidence passing                            |

---

## Overview

### What It Solves

effectful solves the "mtl vs freer monad" dilemma in Haskell. The mtl approach (transformer stacks) has great performance but suffers from the O(n²) instances problem and difficult composition. Freer monad approaches (like [polysemy]) offer better composition but have inherent performance overhead (tree construction and interpretation). effectful provides both excellent performance (on par with mtl) and good composability, while remaining easy to use.

### Design Philosophy

effectful is built on the observation that the expressive power of freer monads comes at a high performance cost, while mtl's performance comes with composition difficulties. The solution is a concrete `Eff` monad (essentially `ReaderT IO`) with type-level effect tracking. This gives GHC the concrete representation it needs to optimize aggressively, while maintaining the benefits of extensible effects.

---

## Core Abstractions and Types

### The Eff Monad

```haskell
newtype Eff (es :: [Effect]) a
```

`Eff` is a concrete monad (not a type variable like in mtl). Internally, it's essentially `ReaderT IO` -- a function from an environment of effect implementations to an IO action.

### Effect Row

Effects are tracked as a type-level list. The type `Eff '[Error String, State Int, IOE] Int` describes a computation that:

- Can fail with a `String` error
- Can access/modify an `Int` state
- Can perform arbitrary `IO`
- Returns an `Int`

### Static vs Dynamic Dispatch

effectful offers two dispatch mechanisms:

**Static dispatch** (via `Effectful.Dispatch.Static`): Effects are inlined at compile time. This is the fastest approach, on par with hand-written `ST` code.

**Dynamic dispatch** (via `Effectful.Dispatch.Dynamic`): Effects are looked up at runtime via the environment. This offers flexibility and is still fast (O(1) array indexing).

Most built-in effects offer both variants; users choose the trade-off.

### Effect Definition

Effects are defined as GADTs with an extra `(Type -> Type)` parameter for higher-order effects:

```haskell
data State s :: Effect where
  Get :: State s m s
  Put :: s -> State s m ()
```

The `m` parameter enables higher-order effects (effects that take monadic computations as arguments).

---

## How Effects Are Declared

### The :> Constraint

The `:>` ("is a member of") constraint asserts that an effect is available:

```haskell
increment :: State Int :> es => Eff es ()
increment = modify @Int (+ 1)
```

The effect row `es` is polymorphic, but `State Int` must be a member. This is similar to mtl's `MonadState`, but:

- Multiple effects of the same type are allowed (e.g., two `State Int` effects)
- No functional dependencies (more flexible, but sometimes requires type annotations)
- No O(n²) instance problem

### Effect Operations

Operations are defined as functions that send the operation to the effect handler:

```haskell
get :: State s :> es => Eff es s
get = send Get

put :: State s :> es => s -> Eff es ()
put s = send (Put s)

modify :: State s :> es => (s -> s) -> Eff es ()
modify f = get >>= put . f
```

---

## How Handlers/Interpreters Work

### Running Effects

Handlers transform `Eff (e : es) a` into `Eff es a`, removing effect `e` from the row:

```haskell
runState :: s -> Eff (State s : es) a -> Eff es (s, a)
runError :: Eff (Error e : es) a -> Eff es (Either e a)
runIO :: IOE :> es => Eff es a -> Eff es a  -- access to underlying IO
```

Handlers can be stacked:

```haskell
program :: Eff '[State Int, Error String, IOE] ()

-- Run with all effects interpreted
runPure = runIO . runError . runState 0 $ program
-- Result: IO (Either String (Int, ()))
```

### Order Matters

As with all effect systems, handler order determines interaction semantics:

```haskell
-- State is rolled back on error:
runError (runState @Int 0 program)

-- State persists through error:
runState @Int 0 (runError program)
```

### Higher-Order Effects

effectful supports scoped operations like `local` (for `Reader`) and `catchError` (for `Error`) directly, without the unsoundness issues that plague [polysemy] and [fused-effects]. The implementation is carefully designed to handle the interaction between higher-order effects and the underlying IO semantics correctly.

---

## Performance Approach

### Why effectful Is Fast

1. **Concrete monad**: `Eff` is `ReaderT IO`, not a type variable. GHC knows the exact representation of bind, pure, etc., and can optimize aggressively.

2. **No tree construction**: Unlike freer monads, effectful doesn't build a syntax tree. Effects are dispatched directly via the environment.

3. **Static dispatch option**: For critical paths, effects can be inlined at compile time.

4. **O(1) dynamic dispatch**: When dynamic, effects are looked up via integer index into a mutable array -- constant time.

### Benchmark Results

From the [effectful benchmark suite]:

- **Countdown (shallow)**: effectful static ~1x reference; effectful dynamic ~1.1x; mtl ~1.5x; [fused-effects] ~1.5x; [polysemy] ~20x; freer-simple ~15x
- **Filesize (I/O benchmark)**: effectful and mtl within margin of error; [polysemy] ~2-3x slower

Key insight: effectful essentially closes the performance gap with mtl while maintaining much better ergonomics.

### Concrete IO

Because `Eff` is `ReaderT IO`, it naturally satisfies `MonadUnliftIO`, enabling direct use of libraries like `unliftio`, `exceptions`, and `lifted-async` without adapter code.

---

## Composability Model

### Effect Interoperability

```haskell
program :: (State Int :> es, Error String :> es, IOE :> es) => Eff es ()
program = do
  n <- get
  when (n < 0) $ throwError "negative!"
  liftIO $ print n
  modify (+ 1)
```

The `(Effect :> es)` constraints are collected automatically during inference.

### Ecosystem Integration

effectful's IO-based foundation enables seamless integration:

- **unliftio**: `MonadUnliftIO` just works
- **exceptions**: `MonadMask`, `MonadCatch`, `MonadThrow` instances provided
- **resource**: `resourcet` works directly
- **lifted-async**: `async` with proper unlifting

### Pure vs IO Interpretation

effectful's design commits to IO at the base. This means:

- Cannot "interpret" effects to pure values (must use IO)
- Cannot implement true algebraic effects (no continuations)

The trade-off is accepted: most real applications end up in IO anyway, and the performance/ecosystem benefits outweigh the theoretical purity.

---

## Strengths

- **Excellent performance**: On par with mtl; 10-20x faster than [polysemy]
- **Easy composition**: No O(n²) instances; effects compose naturally
- **Flexible dispatch**: Choose static (fastest) or dynamic (flexible) per effect
- **Great ecosystem interop**: `MonadUnliftIO`, `exceptions`, `async` all work
- **Beginner-friendly**: Simpler than mtl transformers; better errors than freer
- **Production-ready**: Mature library with active maintenance
- **Higher-order effects**: Sound semantics for `local`, `catchError`, etc.

## Weaknesses

- **No algebraic effects**: Cannot capture/resume continuations (no `NonDet`, coroutines)
- **IO dependency**: Cannot interpret effects purely; always ends in IO
- **No explicit continuation control**: No `reset`/`shift` or similar
- **Newer than mtl**: Smaller community than decades-old mtl (but growing)

## Key Design Decisions and Trade-offs

| Decision                      | Rationale                                                     | Trade-off                                                       |
| ----------------------------- | ------------------------------------------------------------- | --------------------------------------------------------------- |
| ReaderT IO base               | Maximum performance; concrete monad enables GHC optimizations | Loses purity; cannot interpret effects without IO               |
| Static + Dynamic dispatch     | User chooses performance vs flexibility trade-off             | Two modules to learn; decision overhead per effect              |
| No functional dependencies    | Multiple same-type effects possible                           | Ambiguity requires TypeApplications or explicit type signatures |
| Concrete `Eff` monad          | Optimization opportunities; predictable runtime               | Less abstract than `Monad m =>` style; locks in IO              |
| Higher-order effects built-in | Common patterns work (local, catch)                           | Not as theoretically elegant as [heftia]'s elaboration approach |
| Evidence passing env          | O(1) lookup; efficient state threading                        | Environment passing overhead (minimal due to inlining)          |

---

## 2024-2025 Developments

- **API stabilization**: effectful 2.0+ series commits to stable API
- **GHC 9.8+ support**: Staying current with latest GHC releases
- **Effect ecosystem growth**: Third-party effect packages on Hackage
- **Documentation improvements**: Expanded tutorials and examples

---

## Sources

- [effectful on Hackage]
- [effectful GitHub repository]
- [effectful website]
- [effectful documentation]
- [effectful benchmarks]
- [Effect Handlers, Evidently (ICFP 2020)] -- theoretical basis
- [Polysemy: Mea Culpa] -- motivation for effectful's design

<!-- References -->

[polysemy]: haskell-polysemy.md
[fused-effects]: haskell-fused-effects.md
[heftia]: haskell-heftia.md
[github.com/haskell-effectful/effectful]: https://github.com/haskell-effectful/effectful
[effectful-hackage]: https://hackage.haskell.org/package/effectful
[effectful-website]: https://haskell-effectful.github.io/
[effectful benchmark suite]: https://github.com/haskell-effectful/effectful/blob/master/benchmarks/README.md
[effectful on Hackage]: https://hackage.haskell.org/package/effectful
[effectful GitHub repository]: https://github.com/haskell-effectful/effectful
[effectful website]: https://haskell-effectful.github.io/
[effectful documentation]: https://haskell-effectful.github.io/effectful-docs/
[effectful benchmarks]: https://github.com/haskell-effectful/effectful/blob/master/benchmarks/README.md
[Effect Handlers, Evidently (ICFP 2020)]: https://doi.org/10.1145/3408981
[Polysemy: Mea Culpa]: https://reasonablypolymorphic.com/blog/mea-culpa/
