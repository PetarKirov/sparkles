# cleff (Haskell)

A fast and concise extensible effects library focused on the balance of performance, expressiveness, and ease of use. cleff uses a ReaderT IO approach like effectful but provides more versatile effect interpretation and a lighter-weight API.

| Field         | Value                                                      |
| ------------- | ---------------------------------------------------------- |
| Language      | Haskell                                                    |
| License       | BSD-3-Clause                                               |
| Repository    | [github.com/re-xyr/cleff](https://github.com/re-xyr/cleff) |
| Documentation | [Hackage](https://hackage.haskell.org/package/cleff)       |
| Key Authors   | re-xyr                                                     |
| Encoding      | ReaderT IO                                                 |

---

## Overview

### What It Solves

cleff provides an extensible effects system that outperforms polysemy and even mtl in microbenchmarks while maintaining expressive higher-order effect support. It achieves this by implementing `Eff` as `ReaderT IO` rather than using freer monads or monad transformers, allowing GHC optimizations to fire on the concrete monad.

### Design Philosophy

cleff targets the sweet spot between effectful's raw performance and polysemy's expressiveness. It draws inspiration from polysemy's Tactics API for higher-order effects but simplifies it, and from the ReaderT IO pattern for performance. Unlike effectful, cleff does not distinguish between static and dynamic dispatch, opting instead for a uniform dynamic dispatch with flexible interpretation combinators.

---

## Core Abstractions and Types

### The Eff Monad

```haskell
newtype Eff (es :: [Effect]) a
```

Internally implemented as `ReaderT IO`. The type-level list `es` tracks which effects are available. Like effectful, the concrete nature of the monad enables GHC to optimize aggressively.

### Effect Row Encoding

Effects are tracked as a type-level list. The `Eff` monad type is analogous to:

```
StateT String (ReaderT Int IO) Bool  ===  Eff '[State String, Reader Int, IOE] Bool
```

### Member Constraint

```haskell
-- A computation using State and Reader effects
example :: (State Int :> es, Reader String :> es) => Eff es ()
```

Unlike mtl, cleff does not use functional dependencies on effects, so multiple effects of the same type can coexist in the same effect row. When ambiguity arises, `TypeApplications` resolves it. The `cleff-plugin` GHC plugin can provide mtl-like functional dependency behavior.

---

## How Effects Are Declared

Effects are defined as GADTs parameterized by a monad and a return type:

```haskell
data Teletype :: Effect where
  ReadTTY  :: Teletype m String
  WriteTTY :: String -> Teletype m ()
```

Higher-order effects (effects whose constructors take monadic computations) are supported directly:

```haskell
data Error e :: Effect where
  ThrowError :: e -> Error e m a
  CatchError :: m a -> (e -> m a) -> Error e m a  -- higher-order
```

---

## How Handlers/Interpreters Work

cleff provides a set of combinators for interpreting effects, following and extending polysemy's approach:

### interpret

```haskell
interpret :: Handler e es -> Eff (e ': es) a -> Eff es a
```

The basic interpretation combinator. The `Handler` type is a function that handles each constructor of the effect.

### reinterpret

```haskell
reinterpret :: Handler e (e' ': es) -> Eff (e ': es) a -> Eff (e' ': es) a
```

Interprets an effect by introducing a new private effect.

### interpose

```haskell
interpose :: e :> es => Handler e es -> Eff es a -> Eff es a
```

Replaces the current handler for an effect that is already in scope.

### Higher-Order Effect Combinators

Following polysemy's path, cleff provides combinators for implementing higher-order effects that are as expressive as polysemy's Tactics API but easier to use correctly. These combinators thread state and handle the continuation properly through scoped operations like `local`, `catch`, and `mask`.

---

## Performance Approach

### Why cleff Is Fast

1. **ReaderT IO base**: Same fundamental approach as effectful -- concrete monad, no intermediate syntax tree.
2. **IO-based semantics**: State uses `IORef`, Error uses exceptions, providing predictable and efficient behavior.
3. **GHC optimization friendly**: The concrete monad representation allows inlining and specialization without special pragmas.

### Benchmark Position

In microbenchmarks, cleff outperforms polysemy and even mtl. It is slightly behind effectful in some scenarios because effectful provides static dispatch for built-in effects, which cleff does not.

---

## Composability Model

### Uniform Dynamic Dispatch

Unlike effectful, which distinguishes between static and dynamic dispatch, cleff uses a uniform approach. All effects go through the same dispatch mechanism, trading a small amount of performance for a simpler, more uniform API.

### MonadUnliftIO Compatibility

Like effectful, cleff's `Eff` is essentially `ReaderT IO`, so it satisfies `MonadUnliftIO`. Libraries like `unliftio`, `exceptions`, and `lifted-async` work directly without adapter code.

### IOE Effect

The `IOE` effect provides `MonadIO`, `MonadUnliftIO`, `PrimMonad`, `MonadCatch`, `MonadThrow`, and `MonadMask` capabilities. It serves as the final effect that most effect stacks eventually resolve into.

---

## Strengths

- **Very fast**: Outperforms polysemy and mtl in microbenchmarks
- **Expressive higher-order effects**: Combinators as powerful as polysemy's Tactics but simpler to use
- **Lightweight API**: Less boilerplate than fused-effects, simpler than effectful's dual dispatch
- **Multiple same-type effects**: No functional dependencies; can have multiple `State Int` in scope
- **Good ecosystem interop**: `MonadUnliftIO`, `MonadCatch`, etc.
- **IO-based semantics**: Predictable behavior with concurrency and exceptions

## Weaknesses

- **No algebraic effects**: Like effectful, cannot capture/resume continuations; no `NonDet` or `Coroutine`
- **IO dependency**: Cannot interpret effects purely without IO
- **No static dispatch**: Slightly slower than effectful for effects that would benefit from static dispatch
- **Ambiguity with multiple same-type effects**: Requires `TypeApplications` or the GHC plugin to resolve
- **Smaller community**: Less ecosystem support than effectful or polysemy

## Key Design Decisions and Trade-offs

| Decision                         | Rationale                                      | Trade-off                                           |
| -------------------------------- | ---------------------------------------------- | --------------------------------------------------- |
| ReaderT IO (like effectful)      | Performance; concrete monad; ecosystem interop | No pure interpretation; IO semantics leak through   |
| No static dispatch               | Simpler, uniform API                           | Slightly slower for effects that could be static    |
| No functional dependencies       | Multiple same-type effects possible            | Ambiguity requires TypeApplications or plugin       |
| Polysemy-inspired HO combinators | Expressiveness without complexity              | Still limited by ReaderT IO (no true continuations) |
| IO-based State/Error             | Predictable concurrency semantics              | Different from pure algebraic semantics             |

---

## Comparison with effectful

| Aspect                         | cleff                       | effectful                           |
| ------------------------------ | --------------------------- | ----------------------------------- |
| **Dispatch**                   | Dynamic only                | Static + Dynamic                    |
| **Performance**                | Very fast                   | Fastest (static dispatch advantage) |
| **HO effects**                 | More expressive combinators | Supported but less flexible         |
| **API weight**                 | Lighter                     | Heavier (two dispatch modules)      |
| **Multiple same-type effects** | Yes (no fundeps)            | Yes (no fundeps)                    |
| **Ecosystem**                  | Smaller                     | Larger, more actively maintained    |

---

## Sources

- [cleff on Hackage](https://hackage.haskell.org/package/cleff)
- [cleff GitHub repository](https://github.com/re-xyr/cleff)
- [cleff announcement on Haskell Discourse](https://discourse.haskell.org/t/ann-cleff-fast-and-concise-extensible-effects/4002)
- [Cleff.Internal.Base](https://hackage.haskell.org/package/cleff-0.3.4.0/candidate/docs/Cleff-Internal-Base.html)
