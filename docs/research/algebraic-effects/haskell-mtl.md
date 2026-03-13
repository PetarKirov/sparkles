# mtl (Haskell)

The classic monad-transformer class stack for Haskell. `mtl` provides a stable, ubiquitous abstraction layer over `transformers`, and remains a baseline for performance and ecosystem interoperability in Haskell effectful programming.

| Field         | Value                                      |
| ------------- | ------------------------------------------ |
| Language      | Haskell                                    |
| License       | BSD-3-Clause                               |
| Repository    | [mtl GitHub repository]                    |
| Documentation | [Hackage][mtl on Hackage]                  |
| Key Authors   | Andy Gill, Mark P. Jones (foundational)    |
| Encoding      | Monad transformers + typeclasses (fundeps) |

---

## Overview

### What It Solves

`mtl` solves practical modularity for effectful programs by giving a common interface (`MonadReader`, `MonadState`, `MonadError`, etc.) over concrete transformer stacks. Instead of writing directly against `ReaderT r (StateT s (ExceptT e IO))`, code can be polymorphic in `m` and constrained by capabilities.

### Design Philosophy

`mtl` is pragmatic and conservative: keep semantics explicit, keep runtime representation close to transformer stacks, and provide broad compatibility with the rest of Haskell. It predates modern algebraic-effect libraries and is not trying to model handlers/resumptions as first-class constructs.

---

## Core Abstractions and Types

### Capability Classes

The central abstraction is a set of multi-parameter typeclasses with functional dependencies:

```haskell
class Monad m => MonadState s m | m -> s where
  get :: m s
  put :: s -> m ()
```

The dependency `m -> s` says that a given monad `m` determines a single state type `s`.

### Transformer-Based Runtime Representation

`mtl` reuses concrete transformers from [transformers on Hackage], such as:

- `ReaderT r m a`
- `StateT s m a`
- `ExceptT e m a`
- `WriterT w m a`

This gives predictable runtime behavior: each effect layer is explicit in the type and represented as a concrete wrapper.

### Typical Stack

```haskell
type AppM = ReaderT Env (StateT AppState (ExceptT AppError IO))
```

`mtl` class instances let this stack satisfy constraints like `MonadReader Env`, `MonadState AppState`, and `MonadError AppError`.

---

## How Effects Are Declared

Effects are not declared as GADTs (as in [polysemy], [fused-effects], or [effectful]). They are introduced by choosing transformer layers and by requiring matching typeclass constraints:

```haskell
program
  :: (MonadReader Env m, MonadState Int m, MonadError String m)
  => m ()
program = do
  env <- ask
  n <- get
  when (n < 0) (throwError "negative")
  put (n + env.delta)
```

This style keeps code generic in `m`, while concretely choosing interpretation via the final transformer stack.

---

## How Handlers/Interpreters Work

`mtl` uses runner/unwrapper functions from transformers rather than algebraic handlers:

```haskell
runReaderT :: ReaderT r m a -> r -> m a
runStateT  :: StateT s m a  -> s -> m (a, s)
runExceptT :: ExceptT e m a -> m (Either e a)
```

Composition order determines semantics:

```haskell
-- Error outside state: state can be discarded with failure
runExceptT (runStateT program s0)

-- State outside error: state is preserved around error layer
runStateT (runExceptT program) s0
```

This is a key strength and limitation: semantics are explicit and well-understood, but behavior depends on stack ordering and lifting patterns.

---

## Performance Approach

### Why mtl Is Often Fast

`mtl` is usually efficient because it compiles to concrete transformer code with familiar inlining/specialization behavior. It avoids constructing free/freer syntax trees and interpreting them at runtime.

### Typical Costs

1. Each bind traverses the transformer structure in the chosen stack order.
2. Repeated `lift` operations add boilerplate and can obscure hot paths.
3. Large capability surfaces increase instance complexity (the classic "instance boilerplate" issue that motivated extensible-effect libraries).

In practice, modern benchmarks frequently show `mtl` as a strong baseline that is competitive with optimized ReaderT-IO effect libraries for many workloads, while being much faster than classic freer encodings in deep interpreter-heavy pipelines.

---

## Composability Model

`mtl` composes effects via transformer stacking plus typeclass constraints.

### Advantages

- Very mature ecosystem support.
- Predictable interaction with existing libraries via `MonadIO`, `MonadUnliftIO`, etc.
- Straightforward local reasoning once the stack is fixed.

### Frictions

- Order-sensitive semantics are sometimes surprising.
- Functional dependencies restrict multiple same-type effects (for example, two independent `State Int` capabilities in one `m`).
- Deep stacks accumulate lifting and instance complexity.

---

## Strengths

- **Battle-tested standard**: decades of production and ecosystem use.
- **Excellent interoperability**: most Haskell libraries expose `mtl`-friendly APIs.
- **Predictable semantics**: explicit stack and explicit runners.
- **Strong baseline performance**: often close to optimized hand-written transformer code.
- **Low conceptual surprise**: no advanced handler machinery required.

## Weaknesses

- **No algebraic handlers**: no first-class operation/handler/resumption model.
- **Order-sensitive behavior**: changing stack order can change semantics significantly.
- **Multiple same-effect limitations**: fundeps constrain some composition patterns.
- **Boilerplate/lifting burden**: grows with stack depth.
- **Instance surface complexity**: extensibility overhead motivated newer effect systems.

## Key Design Decisions and Trade-offs

| Decision                          | Rationale                                               | Trade-off                                         |
| --------------------------------- | ------------------------------------------------------- | ------------------------------------------------- |
| Typeclasses + fundeps             | Ergonomic capability constraints (`MonadState s m`)     | Restricts multiple same-type effects in one monad |
| Reuse of `transformers` datatypes | Shared ecosystem and predictable runtime representation | Explicit stack management and lift-heavy code     |
| Runner-based interpretation       | Transparent semantics and easy debugging                | No modular algebraic handler composition          |
| Concrete stack ordering           | Direct control over semantics                           | Subtle behavior changes when reordering layers    |
| Conservative evolution            | Stability for huge downstream ecosystem                 | Slower adoption of newer effect abstractions      |

---

## Sources

- [mtl on Hackage]
- [mtl GitHub repository]
- [Control.Monad.State docs]
- [transformers on Hackage]
- [Functional Programming with Overloading and Higher-Order Polymorphism (1995)]
- [Evolution of Algebraic Effect Systems]

<!-- References -->

[polysemy]: haskell-polysemy.md
[fused-effects]: haskell-fused-effects.md
[effectful]: haskell-effectful.md
[Evolution of Algebraic Effect Systems]: evolution.md
[mtl on Hackage]: https://hackage.haskell.org/package/mtl
[mtl GitHub repository]: https://github.com/haskell/mtl
[Control.Monad.State docs]: https://hackage.haskell.org/package/mtl/docs/Control-Monad-State.html
[transformers on Hackage]: https://hackage.haskell.org/package/transformers
[Functional Programming with Overloading and Higher-Order Polymorphism (1995)]: http://web.cecs.pdx.edu/~mpj/pubs/springschool.html
