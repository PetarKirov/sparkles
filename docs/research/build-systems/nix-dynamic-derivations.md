# Nix Dynamic Derivations (Nix + CA)

A derivation whose _output_ is another derivation, and a scheduler that realises the
chain it finds — Nix's experimental `dynamic-derivations` feature, which moves
import-from-derivation's `bind` out of the evaluator and into the build scheduler.

**Last reviewed:** November 2, 2026

| Field                 | Value                                                                                                                                                                        |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language              | Nix (expression language and `.drv` data), C++23 implementation (`cpp_std=c++23`); demos in Go, Rust, Haskell                                                                |
| License               | Nix: LGPL-2.1 (`COPYING`, "GNU LESSER GENERAL PUBLIC LICENSE Version 2.1")                                                                                                   |
| Repository            | [NixOS/nix][repo-nix]; the posts: [fzakaria/fzakaria.com][repo-fz]                                                                                                           |
| Documentation         | In-tree manual — [`store/derivation/index.md`][nix-drv-doc], [`store/resolution.md`][nix-resolution], [`store/build-trace.md`][nix-build-trace]; [RFC 92][rfc92]; four posts |
| Category              | Nix ecosystem — synthesis: the feature, its specification, and four field reports (two 2025, two 2026)                                                                       |
| Clone (posts)         | `$REPOS/build-systems-research/src/fzakaria-com` at `e4744a01435947269383d8ee92064ba59b3440a1`                                                                               |
| Clone (Nix)           | `$REPOS/build-systems-research/src/nix` is a fork clone; upstream tip read via `git show 1ed54a0fd62da96d4f5e9c806555861e46f65341:<path>` (2026-09-12, `2.36.0`)             |
| Feature status        | Experimental: `Xp::DynamicDerivations` → `dynamic-derivations`, tracking milestone 39; needs `ca-derivations`, plus `recursive-nix` for an in-build generator                |
| First shipped surface | `builtins.outputOf` in the 2.18 release notes (2023-09-20) ([`rl-2.18.md`][nix-rl218])                                                                                       |
| Scheduler × rebuilder | Suspending × deep constructive, with the _key set_ now open — see _Placement_ below                                                                                          |

## Overview

### What it solves

Nix separates planning from execution: evaluation produces a closed derivation set,
then the store builds it. Import-from-derivation breaks that by forcing a build _during_
evaluation — the 2025 post measures `nix-instantiate` alone taking 12.15 s on a
two-derivation example ([`2025-03-10…`][post-early]) — which is why `nixpkgs` bans IFD
and why `lang2nix` tools generate derivations out of band.

> "**Dynamic-derivations** seeks to solve this challenge by having derivations
> **create other derivations** without having to execute a `nix build` recursively.
> Nix will realize the output of one derivation is another derivation and build it as
> well."
>
> — [`2025-03-11-…-a-practical-application.md`][post-practical]

### Design philosophy

> "In the parlance of 'Build Systems à la carte', we are generalizing the Nix store
> layer to be a 'Monadic' instead of 'Applicative' build system."
>
> — [`doc/manual/source/store/derivation/index.md`][nix-drv-doc] § _Extending the
> model to be higher-order_

Nix always had `bind` in the evaluator — that is IFD — and the feature does not add
one, it relocates it: the scheduler "can run builders in parallel, ship them to remote
machines, and it can substitute their results from a cache. The evaluator cannot do
any of that" ([`2026-09-21…`][post-dice]). RFC 92 states it as a scheduling property —
each build step still "runs start to finish blocking on nothing" ([RFC 92][rfc92]).

## How it works

Four pieces, three of them data: a **text-hashed output** may produce a path ending in
`.drv` (`outputHashMode = "text"`, [`primops.cc`][nix-primops]); **`builtins.outputOf`**
returns that path, literally when static and as a placeholder otherwise, and "can be
chained arbitrarily deeply"; **deriving paths nest**, so `…-foo.drv^out^out` names the
output of the derivation that `foo`'s output turns out to be (`xp-dyn-drv` ATerm,
[`derivation-aterm.md`][nix-aterm]); and **two new goal types** chase the chain.

### Resolution: the cache key has to be computed

Nix's input-addressed path hashes the derivation with its inputs masked, so it cannot
be computed while an input is "the output of a derivation we have not built":

> "… Those derivations must be (partially) resolved enough first … Then, and only then,
> can input addresses be assigned."
>
> — [`store/derivation/outputs/input-address.md`][nix-input-address]

_Resolution_ is that normalisation. `shouldResolve` requires it for deferred
input-addressed outputs, floating content-addressed derivations, impure derivations, and
unconditionally for "any inputs are outputs of dynamic derivations"
([`resolution.hh`][nix-resolution-hh]); `tryResolve` rewrites each `Built` input's
placeholder to its realised path ([`resolution.cc`][nix-resolution-cc]), so the resolved
derivation is what gets hashed and what the trace is keyed by. Masking refuses to guess:
`maskInputDrvs` returns "`std::nullopt` if any input is deferred (depends on a CA or
dynamic derivation whose outputs are not yet known)" ([`masked.cc`][nix-masked]). The price:

> "For static derivations graphs, complete resolution is indeed total … For dynamic
> derivation graphs, however … resolution is not guaranteed to terminate."
>
> — [`store/resolution.md`][nix-resolution] § _Termination_

### The goal machine

`DerivationTrampolineGoal` is the outermost, deliberately administrative goal: it
obtains a derivation (which may itself require a build) and hands single outputs to
`DerivationGoal`. Its header frames the split as a choice about where complexity lives:
"By splitting out `DerivationTrampolineGoal`, we crucially avoid a need for (2),
letting goal sharing rather than ad-hoc retry mechanisms accomplish the deduplication
we need", where (2) is the restarting logic a single fat goal would need as wanted
outputs grow ([`derivation-trampoline-goal.hh`][nix-trampoline-hh]). The implementation
is a coroutine: resolve the derived path, `co_await` a goal for it on
`MissingRealisation`, resolve again, and read the derivation from whichever store holds
it ([`derivation-trampoline-goal.cc`][nix-trampoline-cc]); `DerivationResolutionGoal`
mirrors it, realising each `Built` input and then aliasing the resolved goal
([`derivation-resolution-goal.cc`][nix-resolution-goal]). That is a suspending scheduler
as continuations, suspending on the _resolution_ path.

### What changes in the à la carte cell

| Element      | Nix before                            | With `dynamic-derivations`                                                 |
| ------------ | ------------------------------------- | -------------------------------------------------------------------------- |
| Key set      | closed, produced by evaluation        | open: a build may add keys, arbitrarily deep                               |
| Scheduler    | suspending over a static `.drv` graph | suspending over a graph that grows; trampoline + resolution goals          |
| Rebuilder    | deep constructive over `.drv`         | deep constructive over the _resolved_ `.drv`; resolution queries the trace |
| Early cutoff | no (a rebuilt input gets a new path)  | at resolution, when a floating/text output is byte-identical               |
| Termination  | guaranteed by the static graph        | not guaranteed by the model; bounded only by what builders emit            |

Early cutoff is qualified: a content-addressed output's path _is_ its content hash, so an
unchanged intermediate resolves to the same path and the dependent's derivation is
unchanged — but a dependent referencing the producer by `.drv` still re-keys when that
derivation changes, even if the bytes do not ([Sandstone][sandstone] notes the same limit).

## Analysis spine

### Placement in the scheduler × rebuilder grid

Nix is **suspending × deep constructive** ([concepts][] §5, [nix-thesis][]), and this
feature does not move it to another cell. What changes is the _key_: the rebuilder still
judges a target from a recursive hash of terminal inputs, but the derivation carrying
those inputs may only exist after some of them were built. This is the catalog's clearest
case where the **store layer**, not the scheduler, becomes monadic.

### 1. Task model & scheduling

Dynamic dependencies in the strict sense: the task description cannot be inspected to
recover the graph, because part of the graph is a build product. The scheduler suspends
and runs concurrently — `co_await` on input goals, one `DerivationGoal` per output so
overlapping requests share work ([`derivation-trampoline-goal.hh`][nix-trampoline-hh]).

RFC 92's `--dry-run` claim did not survive the implementation. The RFC argues the
feature is "quite compatible with `--dry-run`" because "derivations don't get new
dependencies _mid build_" ([RFC 92][rfc92]); the tree instead warns:

> "Ignoring dynamic derivation %s while querying missing paths; not yet implemented"
>
> — [`src/libstore/misc.cc`][nix-misc]

Both are true of different objects: a _derivation_ is fixed once written, the _graph_
is not — "a second graph that exists only after the build". Depth is bounded only by the
store, "no `max-call-depth` equivalent": 893 randomised chains gave mean 6.18 and
longest 46, with rigged cases to 500 ([`2026-09-21…`][post-dice]).

### 2. Rebuilding & correctness

The dirty check is unchanged in kind and stronger in practice: a realised output is
reused by path, a resolved derivation is the key, the build trace is the memo table
([`build-trace.md`][nix-build-trace]). Derived (unresolved) entries "are merely cache"
and can be incoherent across stores. Correctness is partial and the docs say so:
resolution is confluent but not total, `tryResolve` returns `std::nullopt` rather than a
wrong answer, and a text-hashed output is checked only against its declared hash, so
non-determinism surfaces as a different `.drv` path, not a failed build. A functional
test pins the intended equivalence — `…-producingDrv.drv^out^out` must equal a plain
build ([`build-built-drv.sh`][nix-dyn-build-built]) — but nothing proves a generated
graph is right.

### 3. Dependency discovery

Nothing is traced. Discovery is whatever the generator already knew: `gcc -MM` for
[MakeNix][makenix], `ghc -M` for [Sandstone][sandstone], a parsed `build.ninja` for
[nix-ninja][nix-ninja], Cargo's unit graph for [nix-cargo-unit][nix-cargo-unit]. The
contribution is _when_ discovery is paid — inside a sandbox, cached as a derivation
output — not _how_. An undeclared input still fails as a sandbox error, not a wrong cache
hit; the difference is grain, since an incomplete depfile yields a smaller graph rather
than a stale package.

### 4. Store & caching

The store is still the cache: no action cache, no eviction policy. Three mechanics are
new. **Two stores are in play** — resolution consults realisations in the main store
while evaluator derivations live in the eval store
([`derivation-trampoline-goal.cc`][nix-trampoline-cc]). **Substitution covers
derivations**, since a `.drv` is now an ordinary store object. **References are recorded
on dynamic outputs**: `submit-reference.sh` asserts one reference per chain level, so a
closure survives a graph the evaluator never saw
([`submit-reference.sh`][nix-dyn-submit-ref]).

### 5. Hermeticity & provenance

The generator is a privileged builder: `recursive-nix` gives it a store connection and
the right to add paths, so what comes back is opaque bytes the daemon parses as a
derivation. RFC 92 accepts this — recursive Nix is still required for many uses, and the
feature is "not a replacement" for it. Provenance is thin: no SLSA, in-toto or DSSE
emission in the tree; the `.drv` and the trace are the record. Trace entries are
"typically _signed_", and there is "no way to audit a build trace entry except for by
performing the build again from scratch" ([`build-trace.md`][nix-build-trace]).

### 6. Distribution

In principle the strongest: the bind lands in the layer that already has remote builders,
substituters and parallel execution. In practice every participant needs the flag, and the
protocol carries the extra structure (`xp-dyn-drv` ATerm, a builder-RPC path at `2.36pre`).
The 2026-10-17 post proposes a competing route: `$ORIGIN`-relative `RUNPATH` and
`PT_INTERP`, so a Nix closure can be a buck2 tree artifact and a buck2 output a store
path, with an REAPI CAS between them ([`2026-10-17…`][post-two-frontends]).

### 7. Sparkles relevance

`sparkles:build-primitives` models work as `TaskId`/`TaskNode`/`TaskEdge` in a graph
validated before execution, with `EdgeReason.planning` for "a planning step feeds the
work it planned"
(`libs/build-primitives/src/sparkles/build_primitives/task/model.d`).
Three mechanics transfer:

- **A plan-producing node is representable; a graph-extending one is not.** The planning
  edge carries work from planner to planned, but the node set is fixed at validation, so
  the analogue of `^out^out` has no representation today.
- **Normalise the key before hashing.** Hash the _resolved_ graph, never the declared one.
- **Record discovered edges as events, and borrow the ordering, not the mechanism.**
  Sparkles already emits per-task events, so the second graph need not be unobservable;
  seven years in, Nix's own authors still have not stabilised the mechanism.

## Strengths

- **The bind lands where the parallelism is** — remote execution, substitution and build slots reach a dependency that used to block evaluation.
- **Granularity without committed codegen** — per-object derivations generated inside a sandbox, so `nixpkgs` carries no generated Nix and IFD stays banned.
- **Resolution doubles as cache-key normalisation** — why byte-identical intermediates can stop a cascade and why the build trace stays coherent.

## Weaknesses

- **Still experimental after seven years, with daemon-version gates** — RFC 92 is dated 2019-02-01, `builtins.outputOf` shipped in 2.18 (2023-09-20), and at the 2026-09-12 tip the flag is still `Xp::DynamicDerivations` ([`experimental-features.cc`][nix-xp]); its tests need `2.35.0pre20260303`/`2.36pre` daemons ([`common.sh`][nix-dyn-common], [`submit-reference.sh`][nix-dyn-submit-ref]).
- **The graph is unobservable** — `--dry-run`, `nix-store -q --tree` and `nix-diff` cannot see edges that do not exist yet.
- **Termination is the builder's problem, and trust widens at the generator** — no depth bound, no cross-boundary cycle detection, and no provenance layer to record what the generator emitted.

## Key design decisions and trade-offs

| Decision                                      | Rationale                                                             | Trade-off                                                                   |
| --------------------------------------------- | --------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Text-hashed outputs, not a new output kind    | A `.drv` is bytes, so existing content addressing covers it           | Exposes `outputHashMode = "text"`, which RFC 92 calls undesirable           |
| `builtins.outputOf` as a primop               | Derivation references stay in string context, so plumbing still works | No derivation _object_; the graph stays opaque to evaluation                |
| Nest deriving paths rather than adding a type | `^` composes, so CLI, JSON and ATerm generalise uniformly             | Parsing and masking recurse; equal objects acquire many names               |
| Resolution inside the scheduler               | Reuses substitution and remote execution; rebuilder unchanged         | Resolution may not terminate; the trace becomes mutually recursive          |
| Trampoline goal plus per-output goals         | Avoids restarting logic as wanted-output sets grow                    | More goal types and coroutine plumbing; more places to pick the wrong store |
| `--dry-run` as best effort                    | The graph genuinely is not knowable up front                          | Tooling that reasoned about closures silently degrades                      |

## Sources

- [NixOS/nix][repo-nix] at upstream tip `1ed54a0fd62da96d4f5e9c806555861e46f65341`
  (2026-09-12, `2.36.0`), read via `git show` from the fork clone at
  `$REPOS/build-systems-research/src/nix`. Opened: `COPYING`; `.version`;
  `doc/manual/source/store/{derivation/index.md,resolution.md,build-trace.md}`;
  `…/store/derivation/outputs/input-address.md`; `…/protocols/derivation-aterm.md`;
  `…/release-notes/rl-2.18.md`; `src/libutil/experimental-features.cc`;
  `src/libexpr/primops.cc`; `src/libstore/meson.build`; `src/libstore/include/nix/store/{derivation/resolution.hh,build/derivation-trampoline-goal.hh}`;
  `src/libstore/{derivation/resolution.cc,derivation/masked.cc,misc.cc}`;
  `src/libstore/build/{derivation-trampoline-goal.cc,derivation-resolution-goal.cc}`;
  `tests/functional/dyn-drv/{common.sh,build-built-drv.sh,submit-reference.sh}`.
- [fzakaria/fzakaria.com][repo-fz] at `e4744a01435947269383d8ee92064ba59b3440a1`,
  clone at `$REPOS/build-systems-research/src/fzakaria-com`. Posts opened (filenames
  verified by `ls _posts`; the dice post's front matter dates it 2026-09-20, its filename
  09-21): `_posts/2025-03-10-an-early-look-at-nix-dynamic-derivations.md`,
  `_posts/2025-03-11-nix-dynamic-derivations-a-practical-application.md`,
  `_posts/2026-09-21-a-build-graph-that-rolls-dice.md`,
  `_posts/2026-10-17-one-store-two-frontends.md`.
- [RFC 92, _Plan dynamism_][rfc92], fetched as raw text, pinned to commit `32c871cae67fec997c9af2bf15f4a9e41d885109`.
- Background: [concepts][], [nix-thesis][], [à la carte][a-la-carte],
  [content-addressing][], [nix-flakes][]. Siblings consuming the feature:
  [MakeNix][makenix], [nix-ninja][nix-ninja], [nix-cargo-unit][nix-cargo-unit], [Sandstone][sandstone].

<!-- References -->

[repo-nix]: https://github.com/NixOS/nix
[repo-fz]: https://github.com/fzakaria/fzakaria.com
[rfc92]: https://github.com/NixOS/rfcs/blob/32c871cae67fec997c9af2bf15f4a9e41d885109/rfcs/0092-plan-dynamism.md
[nix-drv-doc]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/doc/manual/source/store/derivation/index.md
[nix-resolution]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/doc/manual/source/store/resolution.md
[nix-build-trace]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/doc/manual/source/store/build-trace.md
[nix-input-address]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/doc/manual/source/store/derivation/outputs/input-address.md
[nix-aterm]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/doc/manual/source/protocols/derivation-aterm.md
[nix-rl218]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/doc/manual/source/release-notes/rl-2.18.md
[nix-xp]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/src/libutil/experimental-features.cc
[nix-primops]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/src/libexpr/primops.cc
[nix-resolution-hh]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/src/libstore/include/nix/store/derivation/resolution.hh
[nix-resolution-cc]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/src/libstore/derivation/resolution.cc
[nix-masked]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/src/libstore/derivation/masked.cc
[nix-misc]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/src/libstore/misc.cc
[nix-trampoline-hh]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/src/libstore/include/nix/store/build/derivation-trampoline-goal.hh
[nix-trampoline-cc]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/src/libstore/build/derivation-trampoline-goal.cc
[nix-resolution-goal]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/src/libstore/build/derivation-resolution-goal.cc
[nix-dyn-common]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/tests/functional/dyn-drv/common.sh
[nix-dyn-build-built]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/tests/functional/dyn-drv/build-built-drv.sh
[nix-dyn-submit-ref]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/tests/functional/dyn-drv/submit-reference.sh
[post-early]: https://github.com/fzakaria/fzakaria.com/blob/e4744a01435947269383d8ee92064ba59b3440a1/_posts/2025-03-10-an-early-look-at-nix-dynamic-derivations.md
[post-practical]: https://github.com/fzakaria/fzakaria.com/blob/e4744a01435947269383d8ee92064ba59b3440a1/_posts/2025-03-11-nix-dynamic-derivations-a-practical-application.md
[post-dice]: https://github.com/fzakaria/fzakaria.com/blob/e4744a01435947269383d8ee92064ba59b3440a1/_posts/2026-09-21-a-build-graph-that-rolls-dice.md
[post-two-frontends]: https://github.com/fzakaria/fzakaria.com/blob/e4744a01435947269383d8ee92064ba59b3440a1/_posts/2026-10-17-one-store-two-frontends.md
[concepts]: ./concepts.md
[a-la-carte]: ./a-la-carte.md
[nix-thesis]: ./nix-thesis.md
[nix-ninja]: ./nix-ninja.md
[nix-cargo-unit]: ./nix-cargo-unit.md
[makenix]: ./makenix.md
[sandstone]: ./sandstone.md
[content-addressing]: ../content-addressing/index.md
[nix-flakes]: ../monorepo-tooling/nix-flakes/
