# eff (Haskell)

A work-in-progress effect system built on delimited continuation primops added to the GHC runtime, achieving high performance by design rather than relying on compiler optimizations. Created by Alexis King at Hasura.

| Field       | Value                                                  |
| ----------- | ------------------------------------------------------ |
| Language    | Haskell                                                |
| License     | ISC                                                    |
| Repository  | [github.com/hasura/eff](https://github.com/hasura/eff) |
| Key Authors | Alexis King                                            |
| Status      | Work in progress; development stalled                  |
| Encoding    | Delimited continuations via GHC runtime primops        |

---

## Overview

### What It Solves

eff demonstrates that algebraic effects can be implemented efficiently in Haskell by using native runtime support for delimited continuations, rather than encoding effects as data structures or relying on GHC's optimizer to eliminate indirection. The approach is performant by construction -- the cost of effect dispatch is minimal even without inlining or specialization.

### Design Philosophy

Traditional effect system benchmarks fail to capture the performance of real code because they are so small that GHC inlines everything. In real programs, GHC compiles most effect-polymorphic code via dictionary passing, not specialization, causing other effect systems to degrade. eff avoids this problem entirely by using native continuation capture, which has low overhead regardless of optimization level.

---

## Core Abstractions and Types

### Delimited Continuations

At the heart of eff are three GHC primops (from [GHC Proposal #313](https://github.com/ghc-proposals/ghc-proposals/blob/master/proposals/0313-delimited-continuation-primops.rst)):

```haskell
-- A tag that identifies a prompt (handler boundary)
data PromptTag# a

-- Create a new prompt tag
newPromptTag# :: (State# s -> (# State# s, PromptTag# a #))

-- Install a prompt (handler boundary) on the stack
prompt# :: PromptTag# a -> (State# s -> (# State# s, a #)) -> State# s -> (# State# s, a #)

-- Capture the continuation up to the nearest matching prompt
control0# :: PromptTag# a -> ((State# s -> (# State# s, b #)) -> State# s -> (# State# s, a #))
           -> State# s -> (# State# s, b #)
```

When an effect operation is performed, `control0#` captures the continuation (stack slice) up to the nearest matching `prompt#`, and the handler receives this continuation along with the effect operation.

### Effect Interface

eff's interface is comparable to freer-simple and polysemy:

- Effects are defined as data types
- Operations are invoked via `send`
- Handlers pattern-match on effect constructors
- The `resume` continuation can be called zero, one, or multiple times

### First-Order and Higher-Order Effects

eff supports both:

- **First-order (algebraic) effects**: Standard operations that can capture continuations
- **Higher-order (scoped) effects**: Operations like `local` and `catchError` that scope over sub-computations

Unlike polysemy and fused-effects, eff's semantics for scoped operations are consistent regardless of handler order, and scoped operations compose in predictable ways.

---

## How Effects Are Declared

Effects are defined as GADTs, similar to other effect libraries:

```haskell
data State s m a where
  Get :: State s m s
  Put :: s -> State s m ()
```

No Template Haskell is required. The low-boilerplate interface makes writing new effects simple.

---

## How Handlers/Interpreters Work

Handlers are defined by pattern matching on effect constructors with access to the captured continuation:

```haskell
runState :: s -> Eff (State s ': es) a -> Eff es (s, a)
runState s0 = handleState s0 $ \case
  Get   -> \k s -> k s s        -- resume with current state
  Put s -> \k _ -> k () s       -- resume with new state
```

The handler receives:

1. The effect operation (pattern matched)
2. A continuation `k` that resumes the computation
3. Any handler state

The continuation can be:

- Called once (normal resumption)
- Called zero times (aborting, like `throw`)
- Called multiple times (backtracking, like `NonDet`)
- Stored for later use (coroutines)

This is the key advantage over effectful/cleff, which cannot capture or resume continuations at all.

---

## Performance Approach

### Performance by Design

eff is fast not because of compiler optimizations but because of its implementation strategy:

1. **Native stack capture**: `control0#` captures a slice of the actual GHC RTS stack, not a data structure encoding of one
2. **No intermediate representation**: There is no syntax tree, no free monad, no carrier stack
3. **Zero-cost when unused**: The overhead of supporting continuations is negligible when continuations are not actually captured

### The CountDown Benchmark

In the standard CountDown microbenchmark (which measures bind overhead and effect dispatch without capturing any continuations), eff decisively outperforms all other effect systems. This is significant because:

- Other effect systems pay the cost of _supporting_ continuations even when they are not used
- eff pays nearly zero cost unless continuations are actually captured
- The benchmark uses `NOINLINE` to prevent unrealistic specialization

### Real-World Implications

Alexis King argued that traditional microbenchmarks are misleading because GHC inlines everything, hiding the dictionary-passing overhead that dominates in real programs. eff's advantage is most pronounced in real-world code where functions are compiled separately.

---

## Composability Model

### Consistent Semantics

Unlike polysemy and fused-effects, where handler order can produce surprising or nonsensical results with certain higher-order effect combinations, eff's semantics are based on delimited control and are consistent regardless of handler order. Scoped operations compose predictably.

### Effect Stacking

Effects stack in the standard way via type-level lists:

```haskell
program :: Eff '[State Int, Error String, IO] ()
```

---

## Current Status and GHC Proposal #313

### The Proposal

Alexis King authored [GHC Proposal #313](https://github.com/ghc-proposals/ghc-proposals/blob/master/proposals/0313-delimited-continuation-primops.rst), which adds native delimited continuation primops to GHC. The proposal was accepted and the primops were merged into GHC (as of late 2022, available from GHC 9.6).

Key design principles:

- **Minimal**: Only the ability to capture and restore stack slices; higher-level patterns are built in library code
- **RTS-only**: No changes to the compiler beyond the runtime
- **Prompt tags**: Added during review for type safety; not used by eff itself

### Development Status

The development of eff has stalled due to a few subtle issues related to its use of delimited continuations underneath. However, the primops themselves are available and have been used by other libraries (notably bluefin-algae).

### Impact Beyond eff

The proposal explicitly states it is neither about nor coupled to eff. Any effect system that needs continuation manipulation can benefit from these primops. The primops have enabled bluefin-algae's algebraic effects and continue to be used for experimentation.

---

## Strengths

- **Performance by design**: Fast without relying on fragile GHC optimizations
- **True algebraic effects**: Full support for continuation capture and resumption
- **NonDet and Coroutine support**: Unlike effectful/cleff, can implement backtracking and coroutines
- **Consistent semantics**: Handler order does not produce nonsensical results
- **Low boilerplate**: Comparable to freer-simple; no TH required
- **Influence on GHC**: Led to permanent addition of delimited continuation primops

## Weaknesses

- **Development stalled**: Not actively maintained; subtle unresolved issues
- **Experimental**: Never reached production-ready status
- **GHC-specific**: Depends on GHC-specific primops; not portable
- **Limited ecosystem**: No community libraries built on eff
- **Continuation overhead**: While minimal, continuation capture does have some cost when used

## Key Design Decisions and Trade-offs

| Decision                       | Rationale                                           | Trade-off                                      |
| ------------------------------ | --------------------------------------------------- | ---------------------------------------------- |
| Native delimited continuations | Performance by design; no optimizer dependency      | GHC-specific; required RTS changes             |
| Prompt-based dispatch          | Direct implementation of algebraic effect semantics | More complex runtime behavior; harder to debug |
| Full continuation support      | Enables NonDet, Coroutine, backtracking             | Loses MonadUnliftIO; more complex semantics    |
| No prompt tags (in eff)        | Simpler implementation                              | Type safety relies on library-level invariants |
| Minimal primops                | Leaves design space to libraries                    | Higher-level patterns must be built manually   |

---

## Sources

- [eff GitHub repository](https://github.com/hasura/eff)
- [GHC Proposal #313: Delimited continuation primops](https://github.com/ghc-proposals/ghc-proposals/blob/master/proposals/0313-delimited-continuation-primops.rst)
- [GHC Proposal #313 PR discussion](https://github.com/ghc-proposals/ghc-proposals/pull/313)
- [Alexis King -- Delimited Continuations, Demystified](https://www.lambdadays.org/lambdadays2023/alexis-king) (Lambda Days 2023)
- [From delimited continuations to algebraic effects in Haskell](https://blog.poisson.chat/posts/2023-01-02-del-cont-examples.html) -- Lysxia
- [What happens now after delimited continuations is merged to GHC?](https://discourse.haskell.org/t/what-happens-now-after-delimited-continuations-is-merged-to-ghc/5460)
