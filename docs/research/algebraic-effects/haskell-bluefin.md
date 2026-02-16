# Bluefin (Haskell)

A new Haskell effect system where effects are accessed through value-level handles rather than type-level constraints. Strongly inspired by effectful, Bluefin can be described as a well-typed implementation of "the functions-that-return-IO pattern."

| Field         | Value                                                                      |
| ------------- | -------------------------------------------------------------------------- |
| Language      | Haskell                                                                    |
| License       | MIT                                                                        |
| Repository    | [github.com/tomjaguarpaw/bluefin](https://github.com/tomjaguarpaw/bluefin) |
| Documentation | [Hackage](https://hackage.haskell.org/package/bluefin)                     |
| Key Authors   | Tom Ellis                                                                  |
| Encoding      | ReaderT IO with value-level handles; ST-like scoping                       |

---

## Overview

### What It Solves

Bluefin provides a simple, composable, and efficient effect system with a distinctive API: effects are accessed through value-level handles that appear as explicit function arguments. This makes it trivial to have multiple effects of the same type in scope simultaneously -- they are simply different values, with no type-level disambiguation needed.

### Design Philosophy

Where effectful provides "a well-typed implementation of the ReaderT IO pattern," Bluefin provides something even simpler: a well-typed implementation of "the functions-that-return-IO pattern." Effects are introduced by handlers and accessed through handles, with the type system ensuring (via ST-like scoping) that handles never escape their handler's scope.

---

## Core Abstractions and Types

### The Eff Monad

```haskell
newtype Eff (es :: Effects) a
```

`Eff` is an opaque wrapper around `IO`. The `es` parameter tracks active effects, but unlike other effect systems, individual effects are identified by their handle values, not by type-level membership constraints.

### Handles

Handles are value-level tokens that grant access to specific effects:

```haskell
-- State handle
data State s (e :: Effects)

-- Example: using a state handle
increment :: State Int e -> Eff e ()
increment st = modify st (+ 1)
```

Handles carry an `e` type parameter that links them to their enclosing scope, using the same mechanism as `ST`'s `s` parameter to prevent escape.

### ST-Like Scoping

Bluefin uses universally quantified type variables to ensure handles cannot escape their handler:

```haskell
evalState :: s -> (forall e. State s e -> Eff (e :& es) a) -> Eff es a
```

The `forall e` ensures the `State s e` handle cannot be used outside the callback. Once the handler finishes, the handle becomes inaccessible. This is analogous to how `runST` prevents `STRef` escape.

### Effect Combination (:&)

Effects are combined with `:&`:

```haskell
program :: State Int e1 -> Reader String e2 -> Eff (e1 :& e2 :& es) ()
```

---

## How Effects Are Declared

Built-in effects include `State`, `Reader`, `Writer`, `Exception`, `EarlyReturn`, `Stream`, `IO`, and more. Each is an opaque type wrapping its implementation:

- `State` wraps `IORef`
- `Exception` throws actual IO exceptions
- `IO` provides access to the IO monad

Custom effects are defined by creating new handle types.

---

## How Handlers/Interpreters Work

Handlers are functions that introduce a handle and delimit its scope:

```haskell
-- evalState introduces a State handle
evalState :: s -> (forall e. State s e -> Eff (e :& es) a) -> Eff es a

-- runReader introduces a Reader handle
runReader :: r -> (forall e. Reader r e -> Eff (e :& es) a) -> Eff es a

-- try introduces an Exception handle
try :: (forall e. Exception ex e -> Eff (e :& es) a) -> Eff es (Either ex a)
```

Usage example:

```haskell
program :: Eff es (Int, String)
program =
  evalState (0 :: Int) $ \st ->
    runReader "hello" $ \rd -> do
      modify st (+ 1)
      s <- ask rd
      n <- get st
      pure (n, s)
```

### Key Advantage: Multiple Same-Type Effects

Because effects are value-level, having two `State Int` effects is trivial:

```haskell
twoStates :: Eff es (Int, Int)
twoStates =
  evalState 0 $ \st1 ->
    evalState 100 $ \st2 -> do
      modify st1 (+ 1)
      modify st2 (+ 10)
      (,) <$> get st1 <*> get st2
```

No type-level machinery or `TypeApplications` needed -- `st1` and `st2` are simply different values.

---

## Bluefin-Algae: Algebraic Effects Extension

The [bluefin-algae](https://hackage.haskell.org/package/bluefin-algae) package, released in September 2025, adds algebraic effects to Bluefin by leveraging the delimited continuation primops added in GHC 9.6:

```haskell
-- Algebraic effect operations capture continuations
data Alg (op :: Type -> Type) e

-- Handle an algebraic effect with a handler function
handleAlg :: (forall e. Alg op e -> Eff (e :& es) a) -> Handler op es a -> Eff es a
```

With bluefin-algae, effects that were built-in to Bluefin (State, Exception, etc.) can be re-implemented from scratch as algebraic effects. It introduces **named effect handlers**, which provide a unique approach to scoping that differs from the dynamic scoping used in most other effect systems. However, early benchmarks in 2025 indicated surprising performance overheads that may require further optimization.

---

## Performance Approach

### Implementation

Because `Eff` wraps `IO`, `State` wraps `IORef`, and `Exception` throws real IO exceptions, performance is excellent -- comparable to effectful. The type system provides safety guarantees without runtime overhead beyond what the underlying IO operations cost.

### No Indirection

There is no effect dispatch mechanism at all -- handle values directly reference their backing implementation. A `State Int e` directly wraps an `IORef Int`. There is no lookup table, no type-level membership resolution, no dictionary passing.

---

## Composability Model

### Explicit Handle Threading

Effects compose by passing handles through function arguments:

```haskell
helper :: State Int e1 -> Reader String e2 -> Eff (e1 :& e2 :& es) String
helper st rd = do
  n <- get st
  s <- ask rd
  pure (s ++ show n)
```

This is more explicit than constraint-based approaches but eliminates all ambiguity.

### Relationship to effectful

All the design points that make effectful fast apply to Bluefin too. The major difference is that Bluefin uses value-level handles where effectful uses type-level constraints. This means:

- Bluefin functions take handles as explicit arguments
- effectful functions use `(:>)` constraints
- Bluefin trivially supports multiple same-type effects
- effectful requires type-level disambiguation for the same

---

## Strengths

- **Simple mental model**: Effects are values; handlers introduce them; scope prevents escape
- **Multiple same-type effects**: Trivially supported through different handle values
- **No type-level complexity**: No `Member` constraints, no type-level lists, no functional dependencies
- **Fast**: Same ReaderT IO performance as effectful
- **ST-like safety**: Handles cannot escape their scope, guaranteed by the type system
- **Algebraic effects available**: Via bluefin-algae and GHC 9.6 delimited continuations
- **Active development**: Talks at ZuriHac 2025, Functional Conf 2025

## Weaknesses

- **Explicit handle passing**: Functions must take handles as arguments, which can be verbose for deeply nested code
- **IO dependency**: Like effectful, fundamentally IO-based
- **Newer library**: Smaller ecosystem and community than effectful or polysemy
- **No implicit effect resolution**: Cannot automatically dispatch to the "nearest" handler of a given type
- **bluefin-algae requires GHC 9.6+**: Delimited continuation support is recent

## Key Design Decisions and Trade-offs

| Decision                           | Rationale                                       | Trade-off                                       |
| ---------------------------------- | ----------------------------------------------- | ----------------------------------------------- |
| Value-level handles                | Simple disambiguation; no type-level complexity | Explicit threading can be verbose               |
| ST-like scoping                    | Prevents handle escape; compile-time safety     | Requires rank-2 types in handler signatures     |
| ReaderT IO base                    | Performance; ecosystem interop                  | IO dependency; no pure interpretation           |
| Separate algebraic effects package | Core library stays simple; algae adds power     | Two packages to learn; GHC 9.6 requirement      |
| No implicit resolution             | Eliminates ambiguity entirely                   | Must pass handles explicitly through call chain |

---

## Sources

- [Bluefin on Hackage](https://hackage.haskell.org/package/bluefin)
- [Bluefin GitHub repository](https://github.com/tomjaguarpaw/bluefin)
- [Bluefin announcement on Haskell Discourse](https://discourse.haskell.org/t/bluefin-a-new-effect-system/9395)
- [bluefin-algae on Hackage](https://hackage.haskell.org/package/bluefin-algae)
- [Bluefin-algae announcement](https://discourse.haskell.org/t/bluefin-algae-algebraic-effects-in-bluefin/9470)
