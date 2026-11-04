# Build Systems à la Carte (Haskell)

The paper that turns "compare build systems" into "compose build systems": two
orthogonal choices — the order keys are built in, and the test for whether a key
needs building — generate a 3 × 4 landscape whose inhabited cells are Make,
Ninja, Excel, Bazel, Shake, CloudBuild, Buck and Nix, and whose uninhabited cells
are design opportunities. This catalog's spine and vocabulary are taken from it;
[concepts] defines the terms, this page covers the argument, the Haskell
encoding, and what the journal version learned by shipping the result.

**Last reviewed:** November 2, 2026

| Field            | Value                                                                                                                                                          |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Authors          | Andrey Mokhov (Newcastle University; Jane Street in the journal byline), Neil Mitchell (Digital Asset, then Facebook), Simon Peyton Jones (Microsoft Research) |
| Conference paper | _Build Systems à la Carte_, ICFP 2018 — PACMPL 2(ICFP), Article 79, 29 pp., [DOI 10.1145/3236774][icfp]                                                        |
| Journal version  | _Build systems à la carte: Theory and practice_, JFP 30, e11 (2020), 55 pp., [DOI 10.1017/S0956796820000088][jfp]                                              |
| License          | CC-BY 4.0 for both; the JFP front matter calls it "an Open Access article, distributed under the terms of the Creative Commons Attribution licence" (p. 1)     |
| Artifact         | Executable models on Hackage as [`build-1.0`][build-pkg] (ICFP footnote 2, JFP footnote 2); later Rust and Kotlin ports both lost precision (JFP §7.1)         |
| Category         | Foundations — the tree's organising vocabulary, not a surveyed system                                                                                          |

## Overview

### What it solves

Build systems are the least studied software most developers run, and each large
organisation built its own: "These complex build systems use subtle algorithms,
but they are often hidden away, and not the object of study" (JFP §1). The paper
names the two decisions every engine makes and writes each system as a one-line
composition of them.

### Design philosophy

> "Build systems are surprisingly tricky. It is easy to waffle and remarkably
> hard to be precise. As this paper exemplifies, it is possible to use Haskell as
> a design language, to express quite abstract ideas in a precise form – indeed,
> precise enough to be executed."
>
> — JFP §7.1

Definitions first, executability second, and no claim that is not runnable: claims
are refutable by typing into GHCi, because every §6 figure is a callable function.
It also explains the paper's limits — what would not type was dropped, not argued
about (§8).

## How it works

### Three types carry the design space

```haskell
newtype Task c k v = Task (forall f. c f => (k -> f v) -> f v)
type    Tasks c k v = k -> Maybe (Task c k v)
type    Build c i k v = Tasks c k v -> k -> Store i k v -> Store i k v

type Scheduler c i ir k v = Rebuilder c ir k v -> Build c i k v
type Rebuilder c   ir k v = k -> v -> Task c k v -> Task (MonadState ir) k v
```

`Store i k v` maps keys to values and carries `i`, the persistent build
information (ICFP Fig. 5, JFP §3.1). A `Task` receives a `fetch` callback and
returns one value; `Tasks` returns `Nothing` for input keys. `Build` is a _type
synonym_, not a type class — the classifying "class" sits one level down, on `c`,
the constraint the effect `f` must satisfy (JFP §3.4). The last two synonyms are
the decomposition (JFP §6.1): a `Rebuilder` wraps a task so it rebuilds only when
necessary; a `Scheduler` supplies the `fetch` it calls, which is how control
returns to the scheduler mid-task.

### The constraint classifies the graph shape

Polymorphism in `f` lets one task description run under every engine; `c` is what
each engine demands of it. The `Functor`/`Applicative`/`Selective`/`Monad` ↔
linear/static/conditional/dynamic correspondence is tabulated in
[concepts][concepts] (mechanism: JFP §3.4, §3.8). `Applicative` is exactly the
strength at which `dependencies` recovers a dependency list without computing
anything; `Monad` is exactly the strength at which it cannot, because `Const` has
no `Monad` instance (JFP §3.7) — which is why the topological column is
`Applicative` only.

### Learning dependencies: extract or record

```haskell
dependencies :: Task Applicative k v -> [k]
dependencies task = getConst $ run task (\k -> Const [k])

track :: Monad m => Task Monad k v -> (k -> m v) -> m (v, [(k, v)])
```

`dependencies` instantiates `f` to `Const [k]`, so the task's arithmetic never
runs and the fetches accumulate a list. `track` runs the task for real in
`WriterT [(k, v)]`, because a monadic dependency list exists only after an
execution — so every rebuilder supporting dynamic dependencies consumes a
_previous_ run's list (the shape of [verifying and constructive
traces][concepts]), and `recordVT`/`recordCT` exist to write it.

### Composition is one line per system

Definitions are ICFP §5 / JFP §6: `make = topological modTimeRebuilder`,
`excel = restarting dirtyBitRebuilder`, `shake = suspending vtRebuilder`,
`bazel = restarting2 ctRebuilder`, `cloudShake = suspending ctRebuilder`,
`cloudBuild = topological (adaptRebuilder ctRebuilder)`, `nix = suspending
dctRebuilder`, `buck` as `cloudBuild` over `dctRebuilder`. `adaptRebuilder`
unwraps an applicative task into a monadic one so CloudBuild and Buck reuse
monadic rebuilders; `restarting2` swaps Excel's calc chain for a build queue.

### Correctness is a definition, and that is the point

A build is correct when inputs survive untouched and every non-input key equals
what recomputing its task on the final store would produce (JFP §3.6); it is
minimal when each task runs at most once and only downstream of changed inputs
(JFP §2.1). Both are stated over _any_ task description, which is what makes "any
scheduler composed with any rebuilder is correct" stronger than a benchmark.
Cycles are excluded by assumption — "All build systems discussed in this paper are
correct only under the assumption that the given task description is acyclic"
(JFP §3.6) — and the definition is weakened, with reasons, for non-determinism
(JFP §8.3) and shallow builds (JFP §8.4).

## The design space

| Rebuilder ↓ / Scheduler → | Topological  | Restarting | Suspending |
| ------------------------- | ------------ | ---------- | ---------- |
| Dirty bit                 | `Make`       | `Excel`    | —          |
| Verifying traces          | `Ninja`      | —          | `Shake`    |
| Constructive traces       | `CloudBuild` | `Bazel`    | —          |
| Deep constructive traces  | `Buck`       | —          | `Nix`      |

> "…which tabulates 12 possible combinations, 8 of which are inhabited by
> existing build systems… Of the remaining four spots, all result in workable
> build systems."
>
> — JFP §6

A dash is _unavailable when written_, not impossible: the four empty cells type
check and run, and the paper builds one. ICFP states this as a challenge and the
journal as a result — "the most interesting unfilled spot in the table is
suspending constructive traces… which we title Cloud Shake" (ICFP §4.4). Other
placements are prose, not cells, because they are refinements (JFP §9.1): `dune`
moved from arrows to selective functors, `pluto` adds cyclic rules with a user
strategy, `redo` "almost exactly matches Shake" and was developed independently,
`tup` is Make with a watched-file-system dirty bit. `fabricate` alone cannot be
expressed — "One way of capturing arbitrary writes in our model is to switch from
one callback `fetch` to two callbacks, say `read` and `write`" (JFP §9.1) — the
paper's own admission that _dependency discovery_ is unsupported.

## From ICFP to JFP: what the journal adds

JFP §1 lists the deltas: §3.8 entirely new (Fibonacci, Ackermann, Collatz,
`cloudAckermann` against a `MonadState Cache`); §4 and §5 substantially expanded,
including the wholly new §5.2.2 on Shake's verifying _step_ traces; §7 completely
new; §8.1 and §8.6–§8.9 almost entirely new; §8.3 revised.

### Cloud Shake: filling the cell, then shipping it

`cloudShake = suspending ctRebuilder`, fielded in Shake as two functions whose
signatures "are suspiciously like `recordCT` and `constructCT`" (JFP §7.3):

```haskell
addCloud    :: k -> Ver -> Ver -> [[(k, Hash v)]] -> v -> [k] -> IO ()
lookupCloud :: (k -> m (Maybe (Hash v))) -> k -> Ver -> Ver
            -> m (Maybe (v, [[k]], IO ()))
```

The differences from the paper's types are the engineering. Two `Ver` arguments
carry the build-script version and the rule version: change either and every
matching trace is invalidated — the difference between a theory of caching and a
cache that survives a refactor. The dependency argument is a list of lists
because Shake builds a requested set in parallel; `addCloud` also takes the
_declared_ output keys; `lookupCloud` returns at most one value rather than the
paper's list, "for simplicity" (JFP §7.3). Verifying traces stay the fast path and
the cloud is consulted only on a miss — a bolt-on the authors recommend rather
than regret: "We have not found any significant downsides … thus far" (JFP §7.3).

### Hadrian, and the numbers as reported

Experience reports, not controlled measurements.

- **Warm-cache rebuild.** The first production user was not GHC. Standard
  Chartered reported: "Building from scratch with a warm cache takes around 5 s,
  saving us up to 2 h. Not bad!" (JFP §7.4, quoting a `shake-build-system` post).
- **GHC from scratch.** "Building GHC 8.8 from scratch takes ∼1 hour on Windows
  using Hadrian or the original Make-based build system", covering the compiler,
  29 bundled libraries in vanilla and profiled flavours, and 6 bundled
  executables. "In an ideal case, when a commit does not affect the resulting GHC
  binaries… Hadrian can build GHC from scratch in just 3 minutes, by simply
  creating symbolic links to the previously built results stored in the cache"
  (JFP §7.5).
- **The cache is not a constant win.** If a commit touches the Stage 1 GHC
  executable, "any further cache hits become unlikely, thus limiting benefits of
  the build cache to Stage 1 only" (JFP §7.5). Package-database registration
  mutates a shared file instead of producing one, so such rules opt out.
- **Parallelism is not the bottleneck.** Shake's profiling "has shown us … that
  more CPUs would not help (on unlimited CPUs the speed up would be less than
  10%), and that a handful of build tasks … take up a significant fraction of
  build time (at least 15%)" (JFP §7.5).

### Cache hygiene: what practice cost

Three failure modes, each a bug a local build hides (JFP §7.4). **Irrelevant
differences** — `/usr/bin/gcc` versus `/usr/local/bin/gcc`, or an embedded
timestamp — cause silent misses; remedies are relative paths, version-number
dependencies, Nix-style environment control, and asking compilers for determinism.
**Undeclared outputs** — declaring `Foo.hi` while emitting `Foo.o` — work locally
and break remotely: "…most issues encountered during the move to cloud builds for
GHC were caused by failing to declare produced files." **Missing dependencies** get
monotonically worse: "With local builds, outputs will be built at least once per
user, but with a cloud build they might only be built once ever." Shake's lint
modes were coupled to FSATrace to find both classes — the paper's nearest approach
to dependency _discovery_, and the seed of the Rattle line of work.

### "Proofs": what the journal does not add

Nothing in either version is mechanised: no Coq, Lean or Isabelle development, no
soundness theorem about the composition, no proof that a rebuilder implements
minimality — the words do not appear. What exists is a precise _definition_ (JFP
§3.6), executable models testable against it, and an experience report; the
formal-verification page should treat this as the property to be proved.

## Limitations the authors state

- **Models are the essence, and cycles are excluded.** "we have modelled the most
  critical subset of various build systems" (JFP §8); parallel schedulers are
  described but omitted, "not overly onerous, but neither is it beautiful or
  informative" (§8.2); and "We choose not to deal with cyclic dependencies – a
  choice that most build systems also follow" (§8.5).
- **Errors are only values.** A partial store is modelled by instantiating `v` to
  `Maybe`/`Either`, which "does not let the build system apply special behaviour
  for errors, e.g. early aborting" (ICFP §6.1; JFP §8.1 adds encodings).
- **No polymorphism.** Typed keys and multi-output rules are "convenience rather
  than power" (ICFP §6.7); JFP §8.6–§8.7 recover both with GADTs.
- **No tracing, no sandbox mechanism, no provenance.** Fabricate needs a
  `read`/`write` callback pair to model; sandboxing appears only as a cache-hit
  remedy and to guarantee exclusive output access (JFP §8.9), never as a mechanism
  with a cost; correctness says nothing about who ran an action.
- **The cloud back end is unfinished.** "The one thing we have not yet completed on
  the engineering side is a move to hosting caches over HTTP. At the moment all
  caches are on shared file systems" (JFP §7.3) — and an HTTP mount needs
  administrator privileges on Windows.
- **Uncacheable rules remain, and the encoding leans on Haskell.** Shared-file
  mutation must be excluded by hand (JFP §7.5); the Rust and Kotlin ports both lost
  precision (JFP §7.1), so "copy the types" is not portable advice.

## Analysis spine

### 1. Task model & scheduling

`Tasks c k v` — a partial key→task function, each task a second-order function
over `fetch` — plus three schedulers ([concepts]). Two binding constraints:
topological and `Applicative` are inseparable, because ordering _is_ static
extraction; and suspension pays only "if the cost of avoided duplicate work
outweighs the cost of suspending tasks" (JFP §4.3).

### 2. Rebuilding & correctness

Four rebuilders, each a little persistent state; minimality and early cutoff are
properties of the _pair_, hence a grid rather than a list. Step traces (JFP §5.2.2)
are the one rebuilder whose observable behaviour differs from the ideal it
approximates: change a dependency away and back, and Shake rebuilds where a
verifying trace would not.

### 3. Dependency discovery

Declared (extracted statically, or stated by the rule) or recorded from a previous
execution — nothing else; Fabricate is the apologised-for exception. That is the
boundary with the tracing literature: à la carte says what to _do_ with a
dependency list, not how to obtain one you were not given.

### 4. Store & caching

`Store i k v` plus `i` is deliberately abstract; constructive traces are what let
a lookup _supply_ a value rather than merely confirm one. Policy is out of scope
(JFP §8.4), with one keeper: evicting a value need not evict traces naming its
hash, since a shallow build passes hints through until something materialises.

### 5. Hermeticity & provenance

Not a topic. Hermeticity is all cache hygiene — what makes two builds "the same
task" (JFP §7.4) — sandboxing appears once, for concurrent output writes (§8.9),
and provenance is absent.

### 6. Distribution

Cache sharing yes, remote execution no: "Offloading" is a bullet in the list of
what the model omits, and the deployed cache is a shared file system (JFP §7.3).
The transferable result is negative — non-determinism plus deep constructive
traces yields a "Frankenbuild" wrong under every correctness definition.

### 7. Sparkles relevance

`sparkles.build_primitives.task` is a validated static DAG — `TaskNode`,
`TaskEdge` with an `EdgeCondition` (`onSuccess`, `onFailure`, `onCompletion`,
`always`), `ResourceClaim`, `OutputPolicy` — whose modules hold no dirty bit, no
value hash, no trace. Through Table 2, Sparkles sits at _topological × no
rebuilder_: the plan says what to run and in what order, and nothing decides
whether a node is current. Three consequences:

1. **The rebuilder is the missing half, not the scheduler.** The graph is complete
   before execution, so static extraction adds nothing; a dirty-bit or
   verifying-trace rebuilder is what would let a second run skip work.
2. **Conditional edges are `track` in disguise.** An `onFailure` or `onCompletion`
   edge makes the executed path depend on an outcome, so a rebuilder must record
   the edges taken, not the ones planned.
3. **The cheapest correctness win is a definition.** Sparkles has
   `Succeeded`/`Failed`/`Skipped`/`Cancelled`/`Blocked`/`Degraded` outcomes but no
   analogue of JFP §3.6; "recompute from the final store and compare" is an oracle
   that makes the rebuild question checkable before any cache exists.

## Strengths

- **Generative.** The factorisation explains eight systems in a sentence each and
  predicted a ninth that now ships; correctness and minimality are stated over all
  task descriptions, not measured on a corpus.
- **Executable and production-checked.** Every §6 figure is a definition in
  [`build-1.0`][build-pkg], so errors surface as type errors; the journal then
  closes the loop with cache-key version pins, uncacheable rules, and misses
  caused by a compiler's path.

## Weaknesses

- **Narrow and anecdotal.** No traced discovery, sandbox cost, provenance or
  remote execution; granularity is the key, so Nix's package-level dependencies
  satisfy the table while its real difficulty lives elsewhere (JFP §9.1);
  determinism is assumed for the deep constructive row; and the evidence is a
  mailing-list report plus one project's experience, with no benchmark and no cost
  model beyond §4.3.

## Key design decisions and trade-offs

| Decision                                           | Rationale                                                                                  | Trade-off                                                                                                      |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------- |
| A second-order function, not an interface or class | One task description runs under every engine; `c` states what an engine may assume         | Needs higher-kinded polymorphism; the Rust and Kotlin ports lost precision (JFP §7.1)                          |
| Factor into scheduler × rebuilder                  | The choices are orthogonal, so the space is a grid and empty cells become research targets | Behaviour that couples them — cancellation on file-watch events — falls outside the model (JFP §8.9)           |
| Abstract `Store i k v` with opaque `i`             | Every system's memory fits: mtime map, calc chain, trace store, cloud memo table           | Nothing is said about eviction, size, or communication cost (JFP §8.4)                                         |
| Trace-based rebuilders over dirty bits             | Preserves minimality, dynamic dependencies and early cutoff at once                        | Larger persistent state; step traces trade hash fidelity for size and rebuild in the change-back case (§5.2.2) |
| Deep constructive traces for the cheap cloud cell  | One lookup on terminal inputs enables shallow builds and single-round-trip queries         | Requires determinism, forbids early cutoff, produces Frankenbuilds when determinism fails (§5.4, Fig. 12)      |
| Bolt constructive traces onto verifying traces     | Avoids re-engineering the central database; the common case stays local and cheap          | Two trace formats to keep consistent; the miss path is exercised only in the cloud                             |

## Sources

- Mokhov, Mitchell & Peyton Jones — ICFP 2018 [DOI][icfp]; read from
  `$REPOS/papers/build-systems/mokhov-2018-build-systems-a-la-carte-icfp.pdf`.
- Mokhov, Mitchell & Peyton Jones — JFP 30, e11 (2020) [DOI][jfp]; read from
  `$REPOS/papers/build-systems/mokhov-2020-build-systems-a-la-carte-theory-and-practice-jfp.pdf`.
  Both via `pdftotext -layout`; cited section numbers are the journal version's.
- Models: [`build-1.0`][build-pkg] on Hackage (ICFP footnote 2, JFP footnote 2) —
  referenced, not opened. Sibling pages: [concepts] (vocabulary this page assumes
  and does not redefine), [index] (master catalog). Sparkles side, read for §7:
  `libs/build-primitives/src/sparkles/build_primitives/task/`.

<!-- References -->

[icfp]: https://doi.org/10.1145/3236774
[jfp]: https://doi.org/10.1017/S0956796820000088
[build-pkg]: https://hackage.haskell.org/package/build-1.0
[concepts]: ./concepts.md
[index]: ./index.md
