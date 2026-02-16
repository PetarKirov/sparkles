# effectful (Haskell)

An easy to use, performant extensible effects library with seamless integration with the existing Haskell ecosystem. effectful is currently the fastest dynamically-dispatched extensible effects library in Haskell.

| Field         | Value                                                                                                      |
| ------------- | ---------------------------------------------------------------------------------------------------------- |
| Language      | Haskell                                                                                                    |
| License       | BSD-3-Clause                                                                                               |
| Repository    | [github.com/haskell-effectful/effectful](https://github.com/haskell-effectful/effectful)                   |
| Documentation | [Hackage](https://hackage.haskell.org/package/effectful) / [Website](https://haskell-effectful.github.io/) |
| Key Authors   | Andrzej Rybczak                                                                                            |
| Encoding      | ReaderT IO with evidence passing                                                                           |

---

## Overview

### What It Solves

effectful provides an extensible effects system that achieves near-native performance by using a concrete `Eff` monad implemented as `ReaderT` over `IO`. Unlike free monad or monad transformer approaches, the monadic bind in effectful is a known, concrete function call that the compiler can optimize directly, eliminating the O(n) per-bind overhead of transformer stacks.

### Design Philosophy

The central insight is that most real Haskell applications ultimately run in `IO`, so rather than abstracting over the base monad, effectful embraces `IO` directly and builds an extensible environment on top of it. This trades the theoretical purity of non-IO-based approaches for dramatic performance gains and seamless interoperability with the existing Haskell ecosystem (via `MonadUnliftIO`, `MonadCatch`, etc.).

---

## Core Abstractions and Types

### The Eff Monad

```haskell
newtype Eff (es :: [Effect]) a = Eff (Env es -> IO a)
```

The `Eff` monad is parameterized by a type-level list of effects `es`. Internally, it is a function from an environment `Env es` to `IO a` -- essentially a `ReaderT` pattern. Because the monad is concrete (not polymorphic), GHC can apply its full optimization suite without requiring `INLINE` pragmas or special compiler passes.

### The Effect Kind

```haskell
type Effect = (Type -> Type) -> Type -> Type
```

Effects in effectful use a higher-kinded type with an extra `(Type -> Type)` parameter that carries the monad, enabling higher-order effects (effects that take monadic computations as arguments).

### The Environment (Env)

The `Env` is a strict, thread-local, mutable, extensible record indexed by effect types. Internally it uses `IORef`-based storage with integer indices for O(1) lookup:

| Operation      | Complexity                  |
| -------------- | --------------------------- |
| Extending      | O(n) where n = stack size   |
| Shrinking      | O(1)                        |
| Element access | O(1)                        |
| Getting tail   | O(1)                        |
| Cloning        | O(N) where N = storage size |

The environment cannot be shared across threads directly; `cloneEnv` must be used for cross-thread passing.

### Effect Membership

```haskell
type (:>) :: Effect -> [Effect] -> Constraint

-- Example: a computation needing State and Reader
example :: (State Int :> es, Reader String :> es) => Eff es ()
```

The `:>` constraint compiles down to a single `Int` pointing at the position in the effect stack where the relevant effect resides. This is the "evidence passing" approach -- unlike mtl where each bind traverses n transformer layers, effectful passes only an integer index.

---

## How Effects Are Declared

### Static Dispatch

Statically dispatched effects have a single, fixed interpretation that cannot be changed at runtime. They are defined by associating a `StaticRep` with the effect:

```haskell
data MyEffect :: Effect

type instance DispatchOf MyEffect = Static WithSideEffects
newtype instance StaticRep MyEffect = MyEffect SomeInternalState
```

Static effects are slightly faster because their operations compile to standard top-level functions. Use static dispatch when the effect has only one reasonable interpretation (e.g., `IOE` for lifting `IO`).

### Dynamic Dispatch

Dynamically dispatched effects can have multiple interpretations, selected at runtime. They are defined as GADTs:

```haskell
data FileSystem :: Effect where
  ReadFile  :: FilePath -> FileSystem m String
  WriteFile :: FilePath -> String -> FileSystem m ()

type instance DispatchOf FileSystem = Dynamic
```

Dynamic dispatch is more flexible and should be the default choice when in doubt.

---

## How Handlers/Interpreters Work

### interpret

The primary combinator for handling dynamic effects. It takes an effect handler and a computation, producing a computation without that effect:

```haskell
interpret
  :: (EffectHandler e es -> Eff (e ': es) a -> Eff es a)

type EffectHandler e es
  = forall a localEs. (HasCallStack, e :> localEs)
  => LocalEnv localEs handlerEs
  -> e (Eff localEs) a
  -> Eff es a
```

### reinterpret

Interprets an effect using other, private effects that are not visible to the caller:

```haskell
reinterpret
  :: (Eff handlerEs a -> Eff es b)  -- runner for private effects
  -> EffectHandler e handlerEs
  -> Eff (e ': es) a
  -> Eff es b
```

This is particularly useful for splitting a large effect into smaller private components.

### interpose

Replaces the handler of an existing effect with a new one, allowing augmentation of existing handlers:

```haskell
interpose
  :: e :> es
  => EffectHandler e es
  -> Eff es a
  -> Eff es a
```

### inject

Allows injection of effects into a wider effect stack, useful for composing handlers that share private effects:

```haskell
inject :: Subset es1 es2 => Eff es1 a -> Eff es2 a
```

---

## Performance Approach

### Why effectful Is Fast

1. **Concrete monad**: `Eff` is `ReaderT IO`, not a type variable. GHC knows the exact representation of bind, pure, etc., and can optimize aggressively.

2. **Evidence passing via Int**: Effect constraints compile to dictionaries containing a single `Int` index, not a full method dictionary. Looking up an effect in the environment is O(1).

3. **No intermediate data structures**: Unlike free/freer monads, there is no syntax tree to build and then traverse. Effects are dispatched immediately.

4. **Static dispatch zero-cost**: Statically dispatched effects compile to direct function calls with no indirection.

5. **IORef-based state**: The `State` effect uses `IORef` internally, which is the fastest mutable reference on GHC. (Caveat: not thread-safe for concurrent `get`/`put`.)

### Benchmark Results

From the [effectful benchmark suite](https://github.com/haskell-effectful/effectful/blob/master/benchmarks/README.md):

- **Countdown (shallow)**: effectful static ~1x reference; effectful dynamic ~1.1x; mtl ~1.5x; fused-effects ~1.5x; polysemy ~20x; freer-simple ~15x
- **Countdown (deep, 10 redundant effects)**: effectful maintains near-constant overhead; mtl and others degrade significantly
- **Filesize (I/O benchmark)**: effectful and mtl within margin of error; polysemy ~2-3x slower

All benchmarked code is annotated with `NOINLINE` to prevent GHC from performing whole-program specialization, simulating realistic multi-module applications.

---

## Composability Model

### Handler Composition

Multiple effects can be interpreted in sequence:

```haskell
runApp :: Eff '[FileSystem, Logger, State Config, IOE] a -> IO a
runApp = runEff
       . evalState defaultConfig
       . runLogger
       . runFileSystem
```

The order of handlers matters and determines semantics (e.g., whether state is rolled back on error).

### Private Effects via reinterpret

```haskell
-- Split a Counter effect into private Get and Put
runCounter :: Eff (Counter ': es) a -> Eff es a
runCounter = reinterpret (evalState (0 :: Int)) $ \env -> \case
  Increment -> localSeqUnlift env $ \unlift -> do
    modify @Int (+ 1)
  GetCount -> localSeqUnlift env $ \unlift -> do
    get @Int
```

### MonadUnliftIO Compatibility

Because `Eff` is `ReaderT IO`, it naturally satisfies `MonadUnliftIO`, enabling direct use of libraries like `unliftio`, `exceptions`, and `lifted-async` without adapter code.

---

## Strengths

- **Best-in-class performance** for dynamically dispatched effects
- **Seamless ecosystem integration** via `MonadUnliftIO`, `MonadCatch`, `PrimMonad`
- **Both static and dynamic dispatch** in a single library
- **Predictable IO-based semantics** for state, errors, and concurrency
- **Low boilerplate** for effect definition and interpretation
- **Active development** with comprehensive documentation

## Weaknesses

- **No algebraic effects**: Cannot capture/resume delimited continuations; no `NonDet` or `Coroutine` effect handlers
- **IO dependency**: The `Eff` monad is fundamentally `IO`-based; effects cannot be interpreted purely without `IO`
- **Thread-local state**: `IORef`-based state is not safely shared across threads
- **Static dispatch is inflexible**: Cannot swap implementations at runtime; testing requires dynamic dispatch
- **Semantic coupling to IO**: Exceptions, async exceptions, and threading semantics leak into effect behavior

## Key Design Decisions and Trade-offs

| Decision                   | Rationale                                                     | Trade-off                                                   |
| -------------------------- | ------------------------------------------------------------- | ----------------------------------------------------------- |
| ReaderT IO base            | Maximum performance; concrete monad enables GHC optimizations | Loses purity; cannot interpret effects without IO           |
| Int-based evidence         | O(1) dispatch; minimal dictionary overhead                    | Requires careful environment management                     |
| IORef for State            | Fastest mutable reference                                     | Not thread-safe; semantics differ from pure State           |
| No delimited continuations | Simplifies implementation; enables MonadUnliftIO              | Cannot support NonDet, Coroutine, or true algebraic effects |
| Static + Dynamic dispatch  | Flexibility vs. performance trade-off per effect              | Two APIs to learn; static effects cannot be reinterpreted   |

---

## Sources

- [effectful on Hackage](https://hackage.haskell.org/package/effectful)
- [effectful GitHub repository](https://github.com/haskell-effectful/effectful)
- [effectful benchmarks](https://github.com/haskell-effectful/effectful/blob/master/benchmarks/README.md)
- [effectful documentation site](https://haskell-effectful.github.io/)
- [Effectful.Dispatch.Dynamic](https://hackage.haskell.org/package/effectful-core-2.5.1.0/docs/Effectful-Dispatch-Dynamic.html)
- [Effectful.Dispatch.Static](https://hackage-content.haskell.org/package/effectful-core-2.6.1.0/docs/Effectful-Dispatch-Static.html)
