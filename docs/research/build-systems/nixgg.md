# nixgg (Go + Nix)

A `gg`-style build accelerator that turns each `cc`, `ar` and link invocation
into a content-addressed Nix derivation — and leaves a per-invocation
derivation graph that can be counted and walked without compiling.

**Last reviewed:** November 2, 2026

| Field                 | Value                                                                                                                                  |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| Language / license    | Go 1.24 (`go/go.mod`), no CGO, no third-party dependencies; Nix expressions under `nix/`; MIT                                          |
| Repository            | [tomberek/nixgg][repo]                                                                                                                 |
| Documentation         | `README.md`, `ARCHITECTURE.md`, `DESIGN.md`, `SPECIFICATION.md`, `LESSONS.md`, `dyn-drv/NOTES.md`                                      |
| Category              | Nix ecosystem — per-invocation derivation construction; graph introspection by walking registered `.drv`s                              |
| Clone (pinned)        | `$REPOS/build-systems-research/src/nixgg` at `062bb9ab44db287fcf102fb91c807d3b5e0d451d` (2026-09-17); shallow, one commit, **no tags** |
| Scheduler × rebuilder | Not a cell of its own: a **front end** emitting leaf derivations into Nix's suspending × deep-constructive cell ([concepts][] Table 2) |

## Overview

### What it solves

> "Intercept every `-c` compile, `ar` archive, and link with a shim.
> Turn each invocation into a content-addressed Nix derivation. Nix
> decides what's cached and what needs building — nixgg just
> constructs the expressions."
>
> — [`README.md`][readme]

Nix's unit is the package; nixgg's is the tool invocation. A `make`, CMake or
Ninja build runs unmodified, but `cc`, `c++`, `ar` and `ld` on `PATH` are one Go
binary that writes a derivation instead of compiling — so a header edit
invalidates a translation unit, not a package.

The graph-introspection half is secondary and tooling-shaped: every node is an
ordinary `.drv`, so `nix show-derivation` enumerates a build without realising
it. The recipe lives in a checked-in agent skill
([`.claude/skills/nixgg-drv-graph-breakdown/`][skill]) and the test harness, not
the CLI, whose verbs are only `env`, `force` and `assemble`
([`SPECIFICATION.md`][spec] §2).

### Design philosophy

> "Every shim writes a derivation. Nix decides everything else.
> That's the only rule. It's what makes native mode and sandbox mode share the
> same call sites, and it's what makes reasoning about correctness simple."
>
> — [`ARCHITECTURE.md`][arch]

No scheduler, no dirty-bit database, no worker pool and no second cache.
`gg`'s thunk model is kept; its scheduler is dropped for the one Nix already
ships ([`DESIGN.md`][design] §6). That is why the graph is introspectable — the
nodes are Nix's objects in Nix's format. The cost is the invariant: native,
sandbox and eager-drv registration must produce **byte-identical derivations**
for one logical compile, archive or link.

## How it works

### Three registration modes, one derivation

The modes answer "how do I tell Nix this derivation exists", never "what goes
in it": `ToNix` and `toJSON` share every script, environment and output-placement
helper, and [`DESIGN.md`][design] §2 asserts they contain zero mode-conditional
branches ([`go/internal/expr/derivation.go`][derivation]).

| Mode              | Trigger             | Registration                                                            | Output before realisation   |
| ----------------- | ------------------- | ----------------------------------------------------------------------- | --------------------------- |
| Native            | default             | write `.nixgg/thunks/<id>.nix`; one `nix build --file` at the end       | symlink to the `.nix` thunk |
| Sandbox / dyn-drv | `NIXGG_SANDBOX=1`   | `nix derivation add` over the sandbox socket; `nix store submit-output` | `drvref` text stub (a file) |
| Eager drv         | `NIXGG_EAGER_DRV=1` | the same JSON path, from an ordinary daemon connection                  | symlink to the real `.drv`  |

The sandbox outer derivation's own output is _text_: the submitted `.drv`'s
path. Consumers reach the artifact by asking `builtins.outputOf` for `outer`'s
`out` output, so `nix build .#hello` walks outer → submitted `.drv` → real
output ([`nix/mkNixggBuild.nix`][mkbuild]).

### Edges, and reading the graph

`classify.Target` answers one question for every path — `Absent`, `Regular`,
`Store`, `Thunk` or `Drv` — and every consumer asks it rather than re-deriving
the answer, which is what turns shell invocations into a graph
([`go/internal/classify/classify.go`][classify]). `Drv` needs a stub because a
dangling symlink breaks Makefile prerequisites:

> "builder-rpc-v0 registers .drv files with the daemon but does not
> materialise them into the sandbox filesystem. A symlink to
> /nix/store/….drv would therefore dangle, and dangling is fatal for
> downstream Makefile prerequisite checks…"
>
> — [`go/internal/drvref/drvref.go`][drvref]

Native mode writes a `.nix` thunk; `nixgg force` then resolves the whole
sibling-import graph in one `nix build --file` — "not once per thunk"
([`go/internal/realise/realise.go`][realise]). Sandbox mode registers `.drv`s
instead, and counting them without compiling means building _one level short_ —
the outer wrapper's `^out` — then walking `nix show-derivation`'s
`derivations → inputs.drvs` shape ([`walk.py`][walk]).

> "Count exactly how many derivations a nixgg sandbox-mode build (mkNixggBuild /
> splitStdenv / batchGroups) breaks into, WITHOUT compiling a single translation
> unit."
>
> — [`SKILL.md`][skill]

The skill records `mosh-batch` at 8 and LLVM's `llvm-min-tblgen` phase at 186
without touching LLVM's ~2000 TUs. Its `lua` count (39) disagrees with
[`tests/drv-equivalence.sh`][equiv] (37); they likely count different sets, but
neither file says so, so treat the exact number as unverified. There is no
`nixgg graph` subcommand: the recipe is a checked-in agent skill, and
`nixgg assemble` is the nearest relative.

## Analysis spine

### Placement in the scheduler × rebuilder grid

nixgg does not occupy a cell. It is a **graph producer** that populates Nix's
suspending × deep-constructive cell ([concepts][] Table 2): each task is a
derivation keyed by a hash of its inputs, and the scheduler is Nix's evaluator
plus store. Edges are dynamic at the shim layer, but nixgg never plans
them; native mode writes a graph and hands it to one `nix build`. Unlike
[nix-ninja][] and [nixception][], it discovers the graph _during_ a build and
never parses a build file.

### 1. Task model & scheduling

One invocation is one task: `-c` compile, `ar`, link, plus sandbox-only `ld -r`
partial link, `objcopy`/`objtool` transform and `rustc` crate compile
([`go/internal/expr/derivation.go`][derivation] `Kind`). Edges are resolved at
invocation time by `classify.Target`: `make`, CMake or Ninja generates, and
nixgg observes.

Scheduling is inherited. `make -j` supplies process parallelism for the shim
pass; Nix decides order, concurrency and substitution — no topological planner,
restarting scheduler or speculation. The one exception is opt-in TU batching,
which folds N compiles plus one archive into one derivation and re-creates
bounded parallelism inside that builder with a FIFO `wait` runner capped at
`$NIX_BUILD_CORES` ([`ARCHITECTURE.md`][arch], "Batching pitfalls").

### 2. Rebuilding & correctness

The dirty check is the derivation hash — a constructive trace over the script,
environment and declared inputs: compiler content, tool basename, staged source
tree's NAR hash, source relative path, order-preserved flags, sorted wrapper
environment and sorted store references ([`ARCHITECTURE.md`][arch], "What every
CA hash includes"). Minimality is per invocation; early cutoff comes from
content-addressed outputs and, at the configure boundary, from `splitStdenv`'s
separate configure output.

The correctness argument is "the derivation captures every input", and that is
where the risk sits. Header discovery over-approximates (every transitively
included header is staged), so a comment-only header edit invalidates the TU;
the openssl version bump rebuilt 2153 of 2192 TUs (98%) because a version string
sits in a widely included header. Thunks also reference staging directories by
path literal, so Nix's eval cache needs `--refresh` when contents change but
thunk text does not ([`go/internal/realise/realise.go`][realise]). Hash equality
does not prove realisation, placement, blast radius or substitution;
[`tests/cross-mode-reuse.sh`][reuse] closes the last of those separately.

### 3. Dependency discovery

Hybrid, skewed to observation rather than declaration. Headers come from the
compiler (`gcc -MM -MG`), cached under `.nixgg/scans/` and invalidated by mtime.
Sibling artifacts come from `classify.Target` over each argv token. Library
references come from substring-matching a _known_ set of store paths against
flags and wrapper environment, deliberately not by parsing arbitrary
`/nix/store/...` text ([`go/internal/storedeps/storedeps.go`][storedeps]). Thin
archives need a sidecar member list, because their bytes are paths.

There is no strict-deps enforcement and no pruning: over-declaration is safe,
and unmodellable subtrees can be listed in `NIXGG_PASSTHROUGH_PATHS` so the
shims exec the real tool. A runtime-computed path stays invisible until the
sandbox refuses it — the failure mode [nixception][] documents, and the reason
both projects prefer stable, slightly imprecise keys.

### 4. Store & caching

There is exactly one cache: the Nix store. Compile, archive and link outputs are
`ca-derivations` outputs, so a store path is a function of content and two
structurally different builds that emit identical bytes collapse to one path.
nixgg computes no key of its own — a second cache would need its own proof of
consistency with Nix's ([`DESIGN.md`][design] §6, "Why not ccache").

`.nixgg/` is a workspace, not a cache: thunks, staged trees, scan memoisation,
symlink manifests and a promoted-file registry. It is relocatable only by
deleting it, and does not survive into an ephemeral sandbox build, so sandbox
reuse comes entirely from the store. The notable property is cross-mode reuse: a
derivation realised by hand in `nix develop` is the same store object
`nix build` computes. Eviction, remote caching and CAS dedup are Nix's.

### 5. Hermeticity & provenance

Each task is an ordinary Nix derivation, so it gets the daemon's sandbox and
nothing more. The sandbox outer derivation requires `builder-rpc-v0`, and the
build script sees store paths only where `inputs.drvs`/`inputs.srcs` declare
them. There is no attestation layer — no SLSA, in-toto or DSSE.

The hermeticity hole is the input scanner. A missed store path is denied at
build time (fail-closed), but a runtime-assembled path is invisible until then,
and the equivalence invariant makes the scanner's output part of the cache key:
`NIXGG_KNOWN_STORE_PATHS` must render identically in the sandbox's `preBuild`
and the native shell hook, or the modes diverge. Reproducibility is assumed, not
checked — the suite compares derivations and outputs, not a `--check` rebuild —
and native mode is impure, so "hermetic" means "Nix's sandbox plus a correct
input set".

### 6. Distribution

None of its own, by design. Every node is an ordinary derivation, so Nix's
remote builders, substituters and binary caches apply unchanged; a separate
scheduler would re-solve dispatch and substitution beside Nix. Sandbox mode
composes with a build farm; native mode's thunks are local files. The
worker-protocol client (`internal/rpc`) is a latency optimisation, not
distribution: it implements 3 of ~30 ops (`AddToStore`, `AddToStoreScanning`,
`SubmitOutput`) from inside a `builder-rpc-v0` sandbox.

### 7. Sparkles relevance

`sparkles:build-primitives` models work as a `TaskNode`/`TaskEdge` DAG. nixgg
contributes two mechanics and one warning:

- **One canonical action is the key.** Script plus environment plus declared
  inputs _are_ the identity; hash an action record, not paths and mtimes.
- **Keep serialisation mode-independent.** _How_ a node is registered must not
  change _what_ it says; a `drv-equivalence`-style test across every registration
  path is cheap insurance against cache fragmentation, and gives introspection
  for free.
- **Warning: an input scanner is part of the cache key.** Inference must be
  deterministic across execution contexts, or one task gets two identities. Do
  not parse build files or grep for paths — declare or trace.

## Strengths

- **Invocation-level granularity on a package-level store.** The 2-of-2213
  openssl result is the concrete payoff, and it comes from Nix's own hashing.
- **Identity across three registration mechanisms.** 149 derivations compared
  byte-for-byte, plus a test proving substitution rather than mere hash equality,
  is unusually rigorous for a cache bridge.
- **A readable, durable graph with an honest record.** `nix show-derivation`
  answers "how many derivations, of what kind" without a compiler; the kernel
  fixture reaches 29,268 derivations, and `LESSONS.md` keeps reverted designs.

## Weaknesses

- **The interesting mode needs an unreleased Nix.** `builder-rpc-v0` and
  `nix store submit-output` are described as merged to master but "not in a
  released Nix yet"; the flake builds its own `patched-nix`.
- **Mode equivalence is a maintenance tax.** Every change to shared environment
  construction must round-trip the equivalence suite, or cross-mode reuse is
  silently forfeited.
- **Introspection is a development skill, not a CLI.** No graph subcommand, no
  schema promise, and `walk.py`'s bucketing is name-substring based, so a
  renamed kind silently lands in `other`.
- **Discovery is heuristic and the toolchain is POSIX-shaped.** Header sets
  over-approximate, runtime-computed store paths are invisible, the activity log
  cannot be written from a sandbox, and anything that is not a compiler, linker,
  archiver or transform is a `passthrough`.
- **Young, and nearly at a ceiling.** No tags or releases, and a link/archive
  script hits Linux's 131072-byte `MAX_ARG_STRLEN` at roughly 1700 inputs.

## Key design decisions and trade-offs

| Decision                                          | Rationale                                                                 | Trade-off                                                              |
| ------------------------------------------------- | ------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| Per-invocation derivations, not per-target        | One file's change invalidates one derivation; Nix's CA hash does the work | Thousands of tiny store paths; per-derivation overhead dominates       |
| No scheduler; Nix is the engine                   | Reuses evaluator, store, substitution and remote builders already trusted | No nixgg-specific scheduling, speculation or worker placement          |
| Three registration modes over one derivation core | Each mode fits an environment (plain daemon, sandbox, dev shell)          | Byte-identity across modes becomes an invariant every change preserves |
| `drvref` stub instead of a symlink                | A dangling symlink fails Makefile `test -e` prerequisites                 | A bespoke format with three readers; not an artifact until resolved    |
| Shim interception, not `build.ninja` parsing      | Works for any generator; configure/generate phases run unmodified         | Only tool-shaped actions are accelerated                               |

## Sources

- [`tomberek/nixgg`][repo] at `062bb9ab44db287fcf102fb91c807d3b5e0d451d`,
  clone at `$REPOS/build-systems-research/src/nixgg` (shallow, one commit, no
  tags). Opened: `README.md`, `ARCHITECTURE.md`, `DESIGN.md`,
  `SPECIFICATION.md`, `LESSONS.md`, `LICENSE`, `go/go.mod`, `dyn-drv/NOTES.md`,
  the graph-breakdown skill, and the Go packages `classify`, `drvref`,
  `realise`, `thunk`, `storedeps`, `expr` and `cli/*`.
- Background: [concepts][], [nix-ninja][], [nixception][], and [content-addressing][].

<!-- References -->

[repo]: https://github.com/tomberek/nixgg
[readme]: https://github.com/tomberek/nixgg/blob/062bb9ab44db287fcf102fb91c807d3b5e0d451d/README.md
[arch]: https://github.com/tomberek/nixgg/blob/062bb9ab44db287fcf102fb91c807d3b5e0d451d/ARCHITECTURE.md
[design]: https://github.com/tomberek/nixgg/blob/062bb9ab44db287fcf102fb91c807d3b5e0d451d/DESIGN.md
[spec]: https://github.com/tomberek/nixgg/blob/062bb9ab44db287fcf102fb91c807d3b5e0d451d/SPECIFICATION.md
[mkbuild]: https://github.com/tomberek/nixgg/blob/062bb9ab44db287fcf102fb91c807d3b5e0d451d/nix/mkNixggBuild.nix
[derivation]: https://github.com/tomberek/nixgg/blob/062bb9ab44db287fcf102fb91c807d3b5e0d451d/go/internal/expr/derivation.go
[classify]: https://github.com/tomberek/nixgg/blob/062bb9ab44db287fcf102fb91c807d3b5e0d451d/go/internal/classify/classify.go
[drvref]: https://github.com/tomberek/nixgg/blob/062bb9ab44db287fcf102fb91c807d3b5e0d451d/go/internal/drvref/drvref.go
[realise]: https://github.com/tomberek/nixgg/blob/062bb9ab44db287fcf102fb91c807d3b5e0d451d/go/internal/realise/realise.go
[storedeps]: https://github.com/tomberek/nixgg/blob/062bb9ab44db287fcf102fb91c807d3b5e0d451d/go/internal/storedeps/storedeps.go
[equiv]: https://github.com/tomberek/nixgg/blob/062bb9ab44db287fcf102fb91c807d3b5e0d451d/tests/drv-equivalence.sh
[reuse]: https://github.com/tomberek/nixgg/blob/062bb9ab44db287fcf102fb91c807d3b5e0d451d/tests/cross-mode-reuse.sh
[skill]: https://github.com/tomberek/nixgg/blob/062bb9ab44db287fcf102fb91c807d3b5e0d451d/.claude/skills/nixgg-drv-graph-breakdown/SKILL.md
[walk]: https://github.com/tomberek/nixgg/blob/062bb9ab44db287fcf102fb91c807d3b5e0d451d/.claude/skills/nixgg-drv-graph-breakdown/walk.py
[concepts]: ./concepts.md
[nix-ninja]: ./nix-ninja.md
[nixception]: ./nixception.md
[content-addressing]: ../content-addressing/index.md
