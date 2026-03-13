# freer-simple (Haskell)

A friendly extensible-effects library built on freer monads, open unions, and fast type-aligned queues. `freer-simple` was a major step in making extensible effects practical in Haskell before the newer ReaderT-IO and continuation-primop generations.

| Field         | Value                                     |
| ------------- | ----------------------------------------- |
| Language      | Haskell                                   |
| License       | BSD-3-Clause                              |
| Repository    | [freer-simple GitHub repository]          |
| Documentation | [Hackage][freer-simple on Hackage]        |
| Key Authors   | Alexis King, Oleg Kiselyov (foundational) |
| Encoding      | Freer monad + open union + FTCQueue       |

---

## Overview

### What It Solves

`freer-simple` solves two long-standing pain points of classic transformer stacks:

1. Boilerplate from stacking and lifting monad transformers.
2. Limited modularity when introducing new effect capabilities.

It gives a single `Eff` monad with a type-level effect list, plus interpreters that can be composed to remove effects one by one.

### Design Philosophy

The library emphasizes ergonomics and accessibility for extensible effects: represent effects as ordinary GADTs, send operations with `send`, and interpret with combinators like `interpret`/`reinterpret`. Compared to [polysemy], it is lower-level and smaller in scope; compared to [mtl], it is more modular in effect declaration and interpretation.

---

## Core Abstractions and Types

### The Eff Monad

The core type is:

```haskell
data Eff effs a
```

where `effs` is a type-level list of available effects.

Internally, the representation uses:

- **Open unions** (`Data.OpenUnion`) for effect requests.
- **Fast type-aligned queue** (`Data.FTCQueue`) for continuations.

This structure avoids the classic free-monad Functor constraint and supports efficient continuation composition.

### Membership Constraints

`Member`/`Members` constraints declare required capabilities:

```haskell
Member (State Int) effs => Eff effs Int
```

The concrete list stays polymorphic, which enables interpreters to be reordered and combined more flexibly than fixed transformer stacks.

### Core Primitives

Key primitives include:

- `send` to emit an effect request.
- `run` for pure programs (`Eff '[] a -> a`).
- `runM` for programs ending in one monadic effect (`Eff '[m] a -> m a`).
- Handler constructors like `handleRelay` / `handleRelayS`.

---

## How Effects Are Declared

Effects are defined as GADTs with one constructor per operation:

```haskell
data Teletype r where
  ReadTTY  :: Teletype String
  WriteTTY :: String -> Teletype ()
```

Operations are then exposed as smart constructors using `send`, manually or via Template Haskell (`makeEffect`):

```haskell
readTTY :: Member Teletype effs => Eff effs String
readTTY = send ReadTTY
```

Built-in modules provide common effects (`Reader`, `State`, `Writer`, `Error`, etc.) as reusable GADTs plus handlers.

---

## How Handlers/Interpreters Work

Interpreters eliminate effects from the row.

### First-Order Interpretation

`interpret` maps each operation to the remaining `Eff` stack:

```haskell
interpret
  :: (forall v. e v -> Eff effs v)
  -> Eff (e ': effs) a
  -> Eff effs a
```

### Reinterpretation

`reinterpret` converts one effect into another (or several), enabling layered implementation without exposing private internal effects in external signatures.

### Running

Programs typically compose several handlers then finish with `run` or `runM`.

This gives a clear "build syntax first, interpret later" workflow similar to other extensible-effect systems.

---

## Performance Approach

### Why It Was a Breakthrough

`freer-simple` improved significantly over older free encodings by using freer representation plus open-union dispatch and FTCQueue continuations. For many teams, it made extensible effects viable without custom compiler support.

### Current Performance Position

Relative to newer libraries, `freer-simple` is generally slower in deep effect-heavy workloads because it still builds/interprets effect requests at runtime. Benchmarks in later ecosystem discussions (and in [effectful benchmark suite] comparisons) consistently place it behind [effectful], [cleff], and usually [fused-effects].

The key takeaway: historically important and still expressive, but no longer state-of-the-art on throughput/latency-sensitive hot paths.

---

## Composability Model

### Strength of the Model

- Effects are declared as independent algebras.
- Programs can stay polymorphic over `effs`.
- Interpreters can be swapped for pure tests or IO-backed execution.

### Limits

- Compared to [polysemy], higher-order/scoped effects are less ergonomic and less central to the core design.
- Compared to ReaderT-IO systems ([effectful], [cleff]), interoperability with mainstream `MonadUnliftIO`-style ecosystems is less direct.

---

## Strengths

- **Historically foundational**: key bridge from transformers to modern extensible effects.
- **Good ergonomics for first-order effects**: concise GADT + `send` + interpreter workflow.
- **Pure interpretation support**: easy to test and reason about interpreter logic.
- **Modular effect rows**: avoids many stack-coupling issues of monad transformers.
- **Template Haskell helpers**: `makeEffect` reduces operation boilerplate.

## Weaknesses

- **Performance lag vs newer systems**: usually behind [effectful]/[cleff]/[fused-effects] on demanding benchmarks.
- **Aging ecosystem momentum**: fewer recent releases and less active expansion than newer libraries.
- **Higher-order effect ergonomics**: weaker than later designs centered around HO effects.
- **Complex internals**: open-union + continuation machinery is non-trivial for contributors.

## Key Design Decisions and Trade-offs

| Decision                     | Rationale                                        | Trade-off                                  |
| ---------------------------- | ------------------------------------------------ | ------------------------------------------ |
| Freer-monad core             | Extensible effects as data, modular interpreters | Runtime interpretation overhead            |
| Open union dispatch          | Type-safe membership of many effects             | Internal complexity                        |
| FTCQueue continuations       | Better asymptotic continuation composition       | Harder internals than plain transformers   |
| Library-level implementation | No compiler patching required                    | Limited runtime optimization opportunities |
| TH (`makeEffect`) support    | Lower user boilerplate                           | TH dependency and generated-code opacity   |

---

## Sources

- [freer-simple on Hackage]
- [freer-simple GitHub repository]
- [Control.Monad.Freer.Internal docs]
- [Freer Monads, More Extensible Effects (2015)]
- [effectful benchmark suite]

<!-- References -->

[mtl]: haskell-mtl.md
[polysemy]: haskell-polysemy.md
[fused-effects]: haskell-fused-effects.md
[effectful]: haskell-effectful.md
[cleff]: haskell-cleff.md
[freer-simple on Hackage]: https://hackage.haskell.org/package/freer-simple
[freer-simple GitHub repository]: https://github.com/lexi-lambda/freer-simple
[Control.Monad.Freer.Internal docs]: https://hackage.haskell.org/package/freer-simple/docs/Control-Monad-Freer-Internal.html
[Freer Monads, More Extensible Effects (2015)]: https://doi.org/10.1145/2804302.2804319
[effectful benchmark suite]: https://github.com/haskell-effectful/effectful/blob/master/benchmarks/README.md
