# polysemy (Haskell)

A higher-order, low-boilerplate extensible effects library based on freer monads. polysemy pioneered accessible higher-order effects in Haskell via its Tactics API and remains influential despite performance limitations.

| Field         | Value                                                                                  |
| ------------- | -------------------------------------------------------------------------------------- |
| Language      | Haskell                                                                                |
| License       | BSD-3-Clause                                                                           |
| Repository    | [github.com/polysemy-research/polysemy](https://github.com/polysemy-research/polysemy) |
| Documentation | [Hackage](https://hackage.haskell.org/package/polysemy)                                |
| Key Authors   | Sandy Maguire                                                                          |
| Encoding      | Freer monad with type-level effect rows                                                |

---

## Overview

### What It Solves

polysemy provides extensible effects with minimal boilerplate and strong support for higher-order effects. It avoids the O(n^2) instances problem of mtl, composes better than monad transformers, is more powerful than freer-simple (which lacks higher-order effects), and requires an order of magnitude less boilerplate than fused-effects.

### Design Philosophy

polysemy prioritizes ergonomics and expressiveness over raw performance. Effects are defined as simple GADTs, and interpretation requires minimal ceremony. The Tactics API enables higher-order effects -- operations that take monadic computations as arguments -- which was a significant advance over freer-simple.

---

## Core Abstractions and Types

### The Sem Monad

```haskell
newtype Sem (r :: EffectRow) a
```

`Sem r` describes a program with the capabilities listed in `r`. The `r` parameter should generally be kept polymorphic, with capabilities added via `Member` constraints. The `Sem` monad allows writing programs against a set of effects without predefined meaning, with that meaning provided later by interpretation.

### Effect Kinds

```haskell
type Effect    = (Type -> Type) -> Type -> Type
type EffectRow = [Effect]
```

Effects have kind `(* -> *) -> * -> *`. The extra `(* -> *)` parameter holds a monad, enabling higher-order effects. For example, `Error e` has constructors like `Throw` and `Catch` where the `m` parameter allows monadic arguments.

### The Union Type

```haskell
data Union (r :: EffectRow) (mWoven :: Type -> Type) a
```

`Union` is an extensible, type-safe union -- the core internal type that stores effect values together with information about the higher-order interpretation state. It is indexed by the effect row `r`, and any one of the effects in `r` may be held within it.

### Member Constraint

```haskell
type Member e r  -- e is a member of effect row r

-- Example:
greet :: Member (Output String) r => Sem r ()
greet = output "hello"
```

`Member (State s) r` is analogous to mtl's `MonadState s m`. Unlike mtl, a `Sem` may have an arbitrary number of the same effect -- for example, you can have both `Member (Output Int) r` and `Member (Output Bool) r` simultaneously, disambiguated at the type level.

---

## How Effects Are Declared

Effects are defined as GADTs with one constructor per operation:

```haskell
data Teletype m a where
  ReadTTY  :: Teletype m String
  WriteTTY :: String -> Teletype m ()

makeSem ''Teletype  -- Template Haskell generates smart constructors
```

The `makeSem` TH splice generates:

```haskell
readTTY  :: Member Teletype r => Sem r String
writeTTY :: Member Teletype r => String -> Sem r ()
```

### Higher-Order Effects

```haskell
data Error e m a where
  Throw :: e -> Error e m a
  Catch :: m a -> (e -> m a) -> Error e m a  -- 'm' appears in arguments
```

The presence of `m` in constructor arguments makes `Catch` a higher-order operation.

---

## How Handlers/Interpreters Work

### Basic Interpretation

```haskell
interpret
  :: FirstOrder e "interpret"
  => (forall rInitial x. e (Sem rInitial) x -> Sem r x)
  -> Sem (e ': r) a
  -> Sem r a
```

For first-order effects (no `m` in constructors), interpretation is straightforward -- each constructor maps to a `Sem` computation.

### interpretH (Higher-Order)

```haskell
interpretH
  :: (forall rInitial x. e (Sem rInitial) x -> Tactical e (Sem rInitial) r x)
  -> Sem (e ': r) a
  -> Sem r a
```

For higher-order effects, `interpretH` provides access to the **Tactics** API.

### The Tactics API

The Tactics API is polysemy's mechanism for handling higher-order effects. It provides:

- **`runT`**: Run a monadic action from a higher-order effect constructor, threading the interpreter's state
- **`bindT`**: Bind the result of `runT` to continue interpretation
- **`getInitialStateT`**: Get the initial state of the interpretation context
- **`pureT`**: Lift a pure value into the tactical context

Example -- interpreting `Catch`:

```haskell
runError :: Sem (Error e ': r) a -> Sem r (Either e a)
runError = interpretH $ \case
  Throw e -> pure (Left e)
  Catch action handler -> do
    result <- runT action
    case result of
      Left e  -> bindT (handler e)
      Right a -> pure (Right a)
```

### Weaving (Internal)

Internally, higher-order interpretation works via **weaving** -- threading a functor of state through effect constructors. The `Weaving` type accumulates weaving functions of the form:

```haskell
Functor f => f () -> (forall x. f (m x) -> n (f x)) -> e m a -> e n (f a)
```

The functor `f` corresponds to some piece of state, and the distribution function is analogous to `runStateT`.

### Running the Final Result

```haskell
run      :: Sem '[] a -> a                  -- pure result
runM     :: Monad m => Sem '[Embed m] a -> m a  -- into any monad
runFinal :: Monad m => Sem '[Final m] a -> m a  -- higher-order embedding
```

---

## Performance Approach

### The Performance Problem

polysemy is based on freer monads, which build an explicit syntax tree of effects. This has inherent overhead:

1. **Tree construction**: Each `send` allocates a node in the effect tree
2. **Tree traversal**: Interpretation walks the tree, pattern-matching on each node
3. **GHC optimization brittleness**: Performance depends heavily on GHC's ability to inline and specialize, which is unpredictable for larger programs

Sandy Maguire documented these issues in his post ["Polysemy: Mea Culpa"](https://reasonablypolymorphic.com/blog/mea-culpa/), acknowledging that the hoped-for GHC optimizations did not materialize for real programs.

### Benchmark Position

- Roughly **1-3 orders of magnitude** slower than fused-effects and mtl
- Similar performance to freer-simple but with higher initial overhead
- The performance gap widens in "deep" benchmarks with many effects in scope

### Proposed Solutions

Alexis King proposed GHC primops for delimited continuations that would allow effect interpretation at runtime with minimal overhead. While not zero-cost, the overhead would be negligible in practice. This work led to GHC Proposal #313 and the `eff` library.

---

## Composability Model

### Effect Ordering

The order of interpreters determines behavior:

```haskell
-- State rolled back on error:
runError . runState @Int 0 $ program

-- State preserved on error:
runState @Int 0 . runError $ program
```

### Members Constraint

```haskell
type Members es r = ...  -- all effects in es are members of r

program :: Members '[State Int, Error String, Output Log] r => Sem r ()
```

### Embedding External Monads

```haskell
embed :: Member (Embed m) r => m a -> Sem r a      -- lift monadic actions
embedFinal :: Member (Final m) r => m a -> Sem r a  -- higher-order embedding
```

---

## Strengths

- **Minimal boilerplate**: Effect definition via GADTs + `makeSem`; interpretation via pattern matching
- **Higher-order effects**: The Tactics API was groundbreaking for accessible scoped effects
- **No O(n^2) instances**: Unlike mtl, no quadratic growth of typeclass instances
- **Custom type errors**: Helpful error messages when effects are missing or ambiguous
- **Multiple same-type effects**: Naturally supported
- **Pure interpretation**: Can interpret to pure values without IO
- **Good documentation**: Extensive tutorials and blog posts by Sandy Maguire

## Weaknesses

- **Poor performance**: 1-3 orders of magnitude slower than mtl/effectful; depends on brittle GHC optimizations
- **Unsound higher-order semantics**: Some combinations of higher-order effects can produce incorrect results (documented by heftia authors)
- **Template Haskell dependency**: `makeSem` requires TH, complicating cross-compilation
- **Complex internals**: Weaving, Tactics, and Union are difficult to understand and extend
- **Abandoned by author**: Sandy Maguire moved on after documenting performance issues; community maintenance

## Key Design Decisions and Trade-offs

| Decision                                | Rationale                                       | Trade-off                                                      |
| --------------------------------------- | ----------------------------------------------- | -------------------------------------------------------------- |
| Freer monad encoding                    | Minimal boilerplate; effects as data            | Inherent performance overhead from tree construction           |
| Tactics API                             | Accessible higher-order effects                 | Complex internals; some unsound semantics                      |
| Type-level effect rows                  | Compile-time safety; multiple same-type effects | Type errors can be cryptic; type inference sometimes struggles |
| Template Haskell for smart constructors | Eliminates boilerplate                          | Cross-compilation issues; opaque generated code                |
| Pure interpretation                     | No IO dependency; testability                   | Performance cost; cannot use IO-based optimizations            |

---

## Sources

- [polysemy on Hackage](https://hackage.haskell.org/package/polysemy)
- [Polysemy.Internal](https://hackage.haskell.org/package/polysemy-1.9.2.0/docs/Polysemy-Internal.html)
- [Polysemy.Internal.Union](https://hackage.haskell.org/package/polysemy-1.9.0.0/docs/Polysemy-Internal-Union.html)
- [Freer Interpretations of Higher-Order Effects](https://reasonablypolymorphic.com/blog/freer-higher-order-effects/) -- Sandy Maguire
- [The Effect-Interpreter Effect (Tactics)](https://reasonablypolymorphic.com/blog/tactics/index.html) -- Sandy Maguire
- [Polysemy: Mea Culpa](https://reasonablypolymorphic.com/blog/mea-culpa/) -- Sandy Maguire
- [Chasing Performance in Free Monads](https://reasonablypolymorphic.com/polysemy-talk/) -- Sandy Maguire
