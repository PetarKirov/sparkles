# Evolution of Haskell Effect Systems

The journey from monad transformers to modern algebraic effect systems spans three decades of research and engineering. Each generation addressed limitations of its predecessor while introducing new trade-offs.

---

## Timeline

| Era        | Approach                          | Key Libraries / Papers                  | Key Characteristics                                     |
| ---------- | --------------------------------- | --------------------------------------- | ------------------------------------------------------- |
| ~1994      | Extensible denotational semantics | Cartwright & Felleisen                  | First extensible approach; overlooked for 20+ years     |
| ~1995+     | Monad transformers (mtl)          | mtl, transformers                       | Composable but O(n^2) instances; lifting overhead       |
| ~2008+     | Free monads                       | free                                    | Effects as data; requires Functor constraint            |
| ~2012-2015 | Extensible effects / Freer monads | extensible-effects, freer, freer-simple | No Functor needed; open unions; ~30x slower than mtl    |
| ~2018      | Fused effects                     | fused-effects                           | Carrier fusion; near-mtl performance; HO effects        |
| ~2019      | Freer + higher-order              | polysemy                                | Low boilerplate; Tactics API; GHC optimization issues   |
| ~2020+     | ReaderT IO                        | effectful, cleff                        | Concrete monad; fastest dispatch; IO-based semantics    |
| ~2020+     | Delimited continuations           | eff, GHC Proposal #313                  | Native stack capture; performance by design             |
| ~2024      | Value-level handles               | bluefin                                 | ST-like scoping; no type-level effect rows              |
| ~2024+     | Hefty algebras                    | heftia                                  | Sound HO effects via elaboration; continuation-based    |
| ~2025      | Higher-order freer                | Theseus                                 | Order-independent interpretation; guaranteed finalizers |
| ~2026      | Parallel Effects                  | λp                                      | Multicore handlers; deterministic parallel execution    |

---

## Generation 1: Monad Transformers (mtl)

### The Approach

Monad transformers compose effects by stacking transformer layers:

```haskell
type App = StateT AppState (ReaderT Config (ExceptT AppError IO))
```

The `mtl` library provides typeclasses (`MonadState`, `MonadReader`, `MonadError`) that abstract over the concrete transformer stack.

### Strengths

- Well-understood; decades of use
- Good GHC optimization (known, concrete types)
- Large ecosystem of compatible libraries
- Familiar to most Haskell developers

### Limitations

1. **O(n^2) instances**: Every new transformer requires instances for interaction with every existing transformer
2. **Lifting overhead**: `lift` calls accumulate; each bind traverses n transformer layers
3. **Ordering matters**: `StateT s (ExceptT e m)` behaves differently from `ExceptT e (StateT s m)`
4. **Rigid composition**: Adding/removing effects requires restructuring the entire stack
5. **One effect per type**: Cannot have two `State` effects of the same type

### Historical Note

Cartwright and Felleisen presented extensible denotational language specifications in April 1994 -- eight months before Liang et al.'s monad transformer paper. Their work was largely forgotten until Oleg Kiselyov rediscovered it in 2004, finding it "remarkably inspiring."

---

## Generation 2: Free Monads

### The Approach

Instead of encoding effects as typeclasses, represent them as data types and build a syntax tree (free monad) of the computation:

```haskell
data Free f a = Pure a | Free (f (Free f a))
```

The syntax tree is then interpreted by a handler function that gives meaning to each constructor.

### Strengths

- Effects as data: inspectable, serializable, testable
- Clean separation of syntax (what) and semantics (how)
- No O(n^2) instance problem
- Multiple interpretations of the same program

### Limitations

- Requires `Functor` constraint on effect types
- Performance overhead from tree construction and traversal
- Composing different free monads requires coproducts
- No higher-order effects (cannot scope over sub-computations)

---

## Generation 3: Freer Monads and Extensible Effects

### The Approach

The freer monad removes the `Functor` constraint by using a different representation:

```haskell
data Eff r a where
  Pure :: a -> Eff r a
  Impure :: Union r b -> (b -> Eff r a) -> Eff r b
```

Effects are stored in an open union (`Union r`), and continuations are chained via an efficient sequence structure.

### Key Paper

**"Freer Monads, More Extensible Effects"** (Oleg Kiselyov, Hiromi Ishii, 2015)

### Key Libraries

- **extensible-effects**: Original implementation
- **freer**: Direct translation of the paper
- **freer-effects**: Fork of freer
- **freer-simple**: Simplified fork; most popular in this family

### Strengths

- No Functor constraint
- Open union for effect types
- Algorithmically better performance than monad transformers for longer stacks
- Extensible: adding new effects does not require touching existing code

### Limitations

- **~30x slower than mtl** for short stacks
- No support for higher-order effects (scoped operations)
- The community forked multiple times, fragmenting the ecosystem

---

## Generation 4: Fused Effects and Higher-Order Effects

### The Approach

Instead of building and interpreting a free monad tree, encode effects as higher-order functors and interpret them via typeclass-based carriers that GHC fuses at compile time.

### Key Papers

1. **"Effect Handlers in Scope"** (Wu, Schrijvers, Hinze, 2014) -- Higher-order effects as higher-order functors
2. **"Fusion for Free"** (Wu, Schrijvers, 2015) -- Fusing sequential handlers into one pass

### Key Library

**fused-effects** -- Achieved near-mtl performance with extensible, higher-order effects. The GitHub Semantic team reported a 250x improvement over their previous free-monad approach.

### Also in This Generation

**polysemy** (2019) -- Took the freer monad approach but added higher-order effects via the Tactics API. Prioritized ergonomics over performance. Sandy Maguire later documented the performance issues in "Polysemy: Mea Culpa."

### The Community Split

The community fragmented into four camps:

1. **mtl loyalists**: "mtl works fine; effects libraries are over-engineered"
2. **ReaderT IO pattern**: "Just use `ReaderT IO` and call it a day"
3. **Three-layer cake**: Structured approach with pure/effect/IO layers
4. **Free(r) monad advocates**: "The composability is worth the performance cost"

---

## Generation 5: ReaderT IO (Modern Pragmatic)

### The Approach

Embrace `IO` as the base and build an extensible environment on top:

```haskell
newtype Eff (es :: [Effect]) a = Eff (Env es -> IO a)
```

Effects are dispatched by looking up handlers in the environment using O(1) integer indices.

### Key Libraries

- **effectful** (2021+) -- Fastest; static + dynamic dispatch; active development
- **cleff** (2022+) -- Lighter API; more expressive interpretation combinators

### Key Insight

Michael Snoyman's observation: most Haskell applications end up in `IO` anyway, so making the base monad concrete enables dramatic optimizations. Monadic binds become known function calls; GHC can optimize aggressively without special pragmas.

### The Performance Leap

effectful's static dispatch is on par with hand-written `ST` code. Dynamic dispatch outperforms mtl. This generation essentially closed the performance gap that plagued previous approaches.

### Limitations

- Cannot capture delimited continuations (no `NonDet`, `Coroutine`)
- IO semantics leak into effect behavior
- Cannot interpret effects purely (without `IO`)

---

## Generation 6: Delimited Continuations and Native Runtime Support

### The Approach

Add native support for capturing and restoring slices of the GHC runtime stack, enabling algebraic effects without the overhead of encoding continuations as data.

### Key Work

- **Alexis King's GHC Proposal #313** (2020, merged 2022) -- Adds `prompt#` and `control0#` primops to GHC
- **eff library** -- Demonstrates the approach; decisive performance wins in benchmarks
- **bluefin-algae** (2024) -- Uses the primops to add algebraic effects to Bluefin

### Key Insight

Traditional effect system benchmarks are misleading. In real programs, GHC compiles effect-polymorphic code via dictionary passing, not specialization. eff's performance advantage is most pronounced in realistic multi-module programs.

### Current Status

The primops are available in GHC 9.6+. The `eff` library's development has stalled, but the primops continue to be used by other libraries. This generation proved that algebraic effects can be fast on GHC.

---

## Generation 7: Sound Higher-Order Effects

### The Problem

All previous generations (except eff) had unsound interactions between higher-order effects and algebraic effects. Operations like `local`, `catch`, and `mask` could produce incorrect results when combined in certain ways.

### The Approach

Separate the handling of higher-order effects (via elaboration) from first-order effects (via algebraic interpretation). This is the insight from "Hefty Algebras" (POPL 2023).

### Key Libraries

- **heftia** (2024) -- First implementation of hefty algebras; fully sound HO + algebraic effects

- **Theseus** (2025) -- Higher-order freer monad with order-independent interpretation and guaranteed finalizers

### The Current Frontier (2026)

The state of the art in Haskell effect systems is now a four-way trade-off:

1. **effectful/cleff**: Maximum performance, no algebraic effects, pragmatic IO-based semantics

2. **heftia / Theseus**: Sound semantics, all features, prioritize theoretical rigor and resource safety

3. **bluefin + bluefin-algae**: Simple mental model (handles), algebraic effects via primops

4. **λp (Parallel Effects)**: Native support for multicore handlers and parallelized effect operations

---

## Summary: The Pendulum of Design

The history of Haskell effect systems shows a pendulum between **purity** and **pragmatism**:

```
Purity                                              Pragmatism
<----|---------|---------|---------|---------|---------|--->
     |         |         |         |         |         |
  Free      Freer    Fused     Polysemy  Effectful  ReaderT IO
  Monads    Monads   Effects             Cleff      Pattern
                                         Heftia     Bluefin
```

Early approaches prioritized purity and theoretical elegance. The ReaderT IO generation swung toward pragmatism. The latest generation (heftia, Theseus) attempts to combine theoretical rigor with practical performance, finding a middle ground.

---

## Sources

- [Monad transformers, free monads, mtl, laws and a new approach](https://blog.ocharles.org.uk/posts/2016-01-26-transformers-free-monads-mtl-laws.html) -- Ollie Charles
- [Freer Monads, More Extensible Effects](https://okmij.org/ftp/Haskell/extensible/more.pdf) -- Kiselyov, Ishii
- [Freer Monads and Extensible Effects](https://okmij.org/ftp/Haskell/extensible/index.html) -- Oleg Kiselyov
- [Freer Monads, More Better Programs](https://reasonablypolymorphic.com/blog/freer-monads/) -- Sandy Maguire
- [Polysemy: Mea Culpa](https://reasonablypolymorphic.com/blog/mea-culpa/) -- Sandy Maguire
- [effects-benchmarks](https://github.com/patrickt/effects-benchmarks) -- Patrick Thomson
- [GHC Proposal #313](https://github.com/ghc-proposals/ghc-proposals/blob/master/proposals/0313-delimited-continuation-primops.rst)
- [Heftia blog posts](https://sayo-hs.github.io/blog/heftia/heftia-rev-part-1-1/)
