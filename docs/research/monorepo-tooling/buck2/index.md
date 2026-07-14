# Buck2 (Polyglot)

Meta's from-scratch, Rust-rewrite successor to `Buck1`: a language-agnostic,
remote-execution-first build engine whose `BUCK` files (in [Starlark]) compile a
multi-language monorepo into **one** incremental dependency graph — evaluated,
invalidated, parallelized, and content-addressed by a single demand-driven engine
called `DICE`, with no separate loading/analysis/execution phases.

| Field           | Value                                                                                                                   |
| --------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Language        | Rust (core/daemon/engine) + Starlark (the build/rule language)                                                          |
| License         | Apache-2.0 OR MIT (dual)                                                                                                |
| Repository      | [facebook/buck2][repo]                                                                                                  |
| Documentation   | [buck2.build/docs][docs] · [Architectural Model][arch] · [Glossary][glossary]                                           |
| Category        | Polyglot Build Orchestrator                                                                                             |
| Workspace model | One project rooted at the directory holding `.buckconfig`; a tree of **cells**, each a tree of `BUCK`-file **packages** |
| First released  | Open-sourced **April 6, 2023** (internal at Meta for years prior, as the successor to `Buck1`)                          |
| Latest release  | Rolling bi-monthly pre-release tags; latest dated tag `2026-06-01` (no stable tag yet — see note)                       |

> **Latest release:** Buck2 ships **rolling, bi-monthly dated pre-release tags**
> (e.g. `2026-06-01`, `2026-05-18`, `2026-05-01`) plus a moving `latest` tag, each
> with a committable `dotslash` launcher file. As of June 5, 2026 the most recent
> dated tag is **`2026-06-01`**, and the project's README still states it
> _"currently does not have a stable release tag at this time"_ ([README][repo]).
> Meta internally runs HEAD continuously, so the open-source rolling tags track a
> production-hardened engine despite the "pre-release" label. Source citations
> below are against `main` and the official docs as of June 2026.

---

## Overview

### What it solves

Buck2 exists for the same problem as [Bazel][bazel]: **one repository holding many
languages, built and tested as a single coherent graph.** Meta's positioning is
explicit ([Why Buck2][why]):

> _"Meta employs a very large monorepo, consisting of a variety of programming
> languages, including C++, Python, Rust, Kotlin, Swift, Objective-C, Haskell,
> OCaml, and more."_

Like Bazel, Buck2 does **not** read a language's native manifest (`Cargo.toml`,
`package.json`, `dub.sdl`); you describe every library, binary, and test as a
Starlark **target** in a `BUCK` file, and the engine derives the fine-grained
**actions** (compile, link, archive, test) needed to produce outputs. The whole
build is then a pure function of declared inputs, so an action whose inputs are
unchanged is fetched from a cache — possibly a cache shared across an org via
remote execution — instead of re-run. This places Buck2 squarely among the _heavy
polyglot engines_ in this survey ([Bazel][bazel], [Pants][pants], [Please][please],
and `GN`) and against the language-native workspace models of [Cargo][cargo],
[Go's `go.work`][go-work], and the JS/TS task orchestrators ([Nx][nx],
[Turborepo][turborepo]) that wrap each package's own toolchain rather than
replacing it.

Where Buck2 differs from Bazel is **architectural rather than conceptual.** Buck2
is a from-scratch Rust rewrite of the Java-based `Buck1`, built around two
opinionated choices that Bazel does not make:

1. **A single incremental dependency graph with no phases.** Bazel runs distinct
   loading → analysis → execution phases over distinct graphs; Buck2 collapses
   everything onto one graph computed by `DICE`. From Meta's announcement
   ([engineering.fb.com][fb-blog]):

   > _"The build system is powered by a single incremental dependency graph,
   > avoiding any phases (in contrast to Buck1 or Bazel)."_

2. **Remote-execution-first.** Local execution is treated as a degenerate case of
   remote execution, so hermeticity and a content-addressed cache are the default
   substrate rather than an add-on ([Why Buck2][why]):

   > _"Buck2 is remote execution first — local execution is considered a special
   > case of remote execution."_

The reported payoff ([engineering.fb.com][fb-blog]):

> _"In our internal tests at Meta, we observed that Buck2 completed builds 2x as
> fast as Buck1."_ … _"If there are no source code changes, Buck2 is almost
> instant on subsequent builds."_

### Design philosophy

Buck2's stated character is _"a fast, hermetic, multi-language build system"_
([README][repo]). Three consequences shape the whole system and distinguish it
from both `Buck1` and the language package managers in this survey:

1. **The build language is data, evaluated by a restricted interpreter.** `BUCK`
   files are written in [Starlark] — a deterministic, immutable, non-Turing-complete
   Python dialect — so loading the graph is reproducible and parallelizable. The
   engine itself is language-agnostic ([engineering.fb.com][fb-blog]):

   > _"The core build system has no knowledge of any language-specific rules."_

   All rules live in Starlark, not in the binary (the inversion from `Buck1`, where
   rules were Java baked into the build tool). Rule-API power is deliberately
   bounded ([engineering.fb.com][fb-blog]): features are _"carefully restricted to
   ensure other properties (for example, fast queries or hermeticity) are not
   harmed."_

2. **Correctness via one demand-driven graph.** Every node in the graph — a parsed
   `BUCK` file, a configured target, an action's result — is a `DICE` **key** whose
   **value** is recomputed only when a transitive input changes. There is no
   "analysis cache" separate from an "execution cache"; there is one graph.

3. **Hermeticity is enforced through remote execution.** Because actions are
   shipped to (or sandboxed like) remote workers with declared inputs only, an
   undeclared dependency fails rather than silently succeeding — the same property
   `Nix` flakes pursue at the package level and Bazel at the per-action level.

Within this survey Buck2 is the canonical _modern Rust rewrite of the polyglot
engine_: compare its single-graph/`DICE` design against [Bazel][bazel]'s phased
Skyframe, its cell model against Bazel's repo/workspace model, and its
remote-execution-first stance against Bazel's opt-in `--remote_executor`. For the
D-specific framing of why `dub` lacks all of this, see [the D landscape
note][d-landscape].

---

## How it works

### Cells, packages, targets, and labels

Buck2's namespace has three nesting levels:

- A **cell** is a directory tree rooted at a `.buckconfig`, declared and aliased in
  the root config's `[cells]` section. Cells were _"originally intended to allow
  for migration of repositories with different setups into one monorepo"_
  ([Glossary][glossary]) — they are Buck2's answer to vendoring several previously
  independent repos under one build.
- A **package** is _"a directory that contains a Buck2 `BUCK` file and all source
  files belonging to the same directory as the `BUCK` file, or any of its
  subdirectories that do not contain a `BUCK` file themselves"_ ([Glossary][glossary]).
  Packages are hierarchical and non-overlapping: a subdirectory with its own `BUCK`
  becomes a new package root.
- A **target** is _"an object that is defined in a `BUCK` file … the buildable
  units of a build from the perspective of the end user"_ ([Glossary][glossary]),
  named by a **target label** structured as `cell_alias//path/to/package:target`
  ([Glossary][glossary]).

The project root is the directory holding the top `.buckconfig`; its `[cells]`
section enumerates the cells of the build:

```ini
# .buckconfig (project root) — declare cells and the build-file name
[cells]
    root = .
    prelude = prelude
    toolchains = toolchains
    bazel_skylib = ./third-party/skylark/bazel-skylib

[cell_aliases]
    config = prelude

[buildfile]
    name = BUCK
```

A `BUCK` file declares targets by calling rules; a local cross-reference is just a
label in `deps` (no `path=`, no version, no `workspace:` protocol — the same
structural simplicity [Bazel][bazel] gets from labels):

```python
# math/BUCK — a library target
cxx_library(
    name = "math",
    srcs = ["add.cpp"],
    headers = ["add.h"],
    visibility = ["PUBLIC"],
)
```

```python
# app/BUCK — a binary that depends on the sibling library by label
cxx_binary(
    name = "app",
    srcs = ["main.cpp"],
    deps = ["//math:math"],   # local cross-reference within the root cell
)
```

### The single graph: unconfigured → configured → actions, all on `DICE`

A `buck2 build` does **not** run discrete phases; it lazily demands values from one
graph. Conceptually three kinds of node coexist on that graph ([Architectural
Model][arch]):

1. **Unconfigured target graph.** Buck2 _"performs directory listings to discover
   packages, then evaluates the build files that were found, expands any macros …
   into their underlying rules, and then … converts [attributes] from Starlark to
   Rust types to construct a target node, and insert[s] it into the unconfigured
   target graph"_ ([Architectural Model][arch]). A **macro** is a Starlark wrapper
   around one or more **rules**; a **rule** _"consists of an attribute spec and an
   implementation, which is a Starlark function"_ ([Glossary][glossary]).
2. **Configured target graph.** **Configuration** _"consist[s] of a set of
   'constraint values' that are used to resolve `select` attributes prior to
   evaluating rule implementations"_ ([Glossary][glossary]). Applying a
   configuration to an unconfigured target resolves every `select()` and runs the
   rule implementation, which returns **providers** — _"the only way that
   information from this rule is available to other rules that depend on it"_
   ([Glossary][glossary]).
3. **Action graph.** Each rule implementation declares **actions** — _"an
   individual, cacheable, ideally hermetic command that's run during the build. It
   takes artifacts as inputs and produces other artifacts as outputs"_
   ([Glossary][glossary]). The action graph is finer-grained than the target graph
   (one `cxx_library` → a compile action per source plus an archive action).

`select()` chooses an attribute value against the active configuration's constraint
values:

```python
# build_mode is a constraint; select() resolves at configuration time
cxx_binary(
    name = "app",
    srcs = ["main.cpp"],
    compiler_flags = select({
        "//constraints:build_mode_debug": ["-g"],
        "//constraints:build_mode_release": ["-O2"],
        "DEFAULT": [],
    }),
)
```

A subtle Buck2 capability that Bazel's static model lacks: **dynamic dependencies.**
The target graph stays static, but _"within a rule implementation, we are allowed
to declare a set of build actions whose interdependencies will only be determined
dynamically at build time"_ ([Tweag tour][tweag]) — a rule may build a file, read
its contents, and only then decide what to build next. Paired with **anonymous
targets** (so _"two unrelated binaries [can] compile shared code only once"_,
[Why Buck2][why]) and **transitive sets** (deduplicated transitive dependency
collections), this is Buck2's headline expressiveness gain over `Buck1`/Bazel.

### `DICE`: the demand-incremental computation engine

The engine under all three graphs is **`DICE`**. Its in-tree design doc states
([`dice/dice/docs/index.md`][dice-doc]):

> _"DICE is a dynamic incremental computation engine that supports parallel
> computation, inspired by Adapton and Salsa."_

The model is uniform: _"everything on the dependency graph [has] a key and a value,
along with a function to compute the value from the key and other related keys"_
([Modern DICE][modern-dice]). You _"provide … leaf data and then define a set of
functions that the engine is going to manage for you"_ ([Modern DICE][modern-dice]);
requesting one computation transparently demands its dependencies. Invalidation is
reverse-dependency dirtying with **early cutoff**: when leaf data changes, `DICE`
_"invalidate[s] all those reverse dependencies … [then] only recomputes the nodes
that have been invalidated"_ ([Modern DICE][modern-dice]), and if a recomputed node
yields the same value as before, its dependents are **not** recomputed (the
Adapton/Salsa equality short-circuit). All computations _"are executed in parallel
… via tokio executors"_ ([Modern DICE][modern-dice]) — modern `DICE` keeps a
single-threaded core-state thread owning the cache while async evaluators fan work
out across threads. This is the structural counterpart to [Bazel][bazel]'s
Skyframe; the difference is that `DICE` carries _every_ build concept (parse,
configure, action result) on **one** graph rather than phase-specific ones.

### The daemon (`buckd`) and isolation

Buck2 runs as a persistent **daemon** — _"the Daemon process lives between
invocations and is designed to allow for cache reuse between Buck2 invocations"_
([Glossary][glossary]) — so the `DICE` graph (and its in-memory results) survives
across commands; a second `buck2 build` reuses the warm graph. Daemons are keyed by
**isolation dir**: _"instances of Buck2 share a daemon if and only if their
isolation directory is identical"_ ([Glossary][glossary]), which lets CI or
parallel worktrees run independent daemons side by side.

### `BXL`: scripting the graph

For graph introspection and bespoke tooling, Buck2 ships **`BXL`** — _"BXL scripts
are written in Starlark and give integrators the ability to inspect and interact
directly with the buck2 graph"_ ([Glossary][glossary]). `BXL` is Buck2's
programmable analogue to Bazel's fixed `query`/`cquery`/`aquery` surface: instead of
a query language, you write Starlark that walks targets, actions, and providers.

---

## Five dimensions

### 1. Workspace declaration & topology

Like [Bazel][bazel], Buck2's workspace is **the whole repository**, discovered by a
boundary-marker file (`.buckconfig`) rather than by enumerating members — but Buck2
adds an intermediate tier the Bazel model lacks: the **cell**. The project root is
the directory with the top `.buckconfig`; its `[cells]` section names the cells, and
_within_ each cell every directory holding a `BUCK` file is automatically a package,
addressed by label. There is **no `members` array and no glob of sub-packages**:
package membership is "has a `BUCK` file under a cell," resolved lazily by directory
listing as labels are referenced.

> [!IMPORTANT]
> This is the inverse of the explicit-members model of [Cargo][cargo]
> (`members = ["libs/*"]`), [pnpm][pnpm] (`pnpm-workspace.yaml`), and
> [Go's `go.work`][go-work] (a `use` list). The selectable unit is the
> **package/target** (a label), never a "sub-project." Cells add a coarse grouping
> on top — a way to slot several formerly-separate repos into one project — but they
> are still discovered by config, not enumerated as members.

### 2. Dependency handling & isolation

Buck2 splits **internal** deps (other targets, by label) from **external** deps
(other cells / third-party), and isolates execution through content-addressing
rather than symlink trees:

- **Internal**: a `deps = ["//math:math"]` edge to a label in the same or another
  cell. No hoisting, no `node_modules`-style symlink farm, no virtual store — one
  source tree, one label namespace. (Contrast [pnpm][pnpm]'s isolated symlink store
  or [Yarn Berry][yarn-berry]'s PnP virtual store: in a label-graph engine,
  "isolation" is a property of action sandboxing, not of dependency layout.)
- **External**: brought in as **cells**. A third-party tree (e.g. a vendored
  `bazel-skylib`) is declared as a cell in `[cells]` and referenced by its
  `cell_alias//…` prefix. Buck2 has no single registry/MVS resolver baked into the
  binary the way Bazel's `Bzlmod` or Cargo's resolver are; third-party version
  policy is expressed in Starlark/`BUCK` files within the relevant cell, so the
  ecosystem layers package-manager bridges on top rather than the engine owning
  resolution.
- **Isolation at execution time**: every action's inputs are content-hashed into an
  **action digest** that _"is sent to remote execution"_ ([Glossary][glossary]);
  the action runs against exactly those declared inputs (locally sandboxed or on a
  remote worker), so undeclared files are invisible. This is where Buck2 gets
  hermeticity — from the remote-execution substrate, not from a dependency-tree
  layout.

### 3. Task orchestration & scheduling

The graph **is** the scheduler. There is no separate "pipeline" config (contrast
[Turborepo][turborepo]'s `tasks` / [Nx][nx]'s `targetDefaults`): the configured
target graph's dependency edges, and the action graph derived from declared
input/output artifacts, fully determine execution order. `DICE` evaluates
independent nodes **concurrently on tokio executors** and reuses any node whose
inputs are unchanged.

Change detection is **input hashing with early cutoff**, the `DICE` mechanism above:
a leaf change (an edited source file, a changed `BUCK` attribute, a flipped config)
dirties exactly its reverse-transitive closure, and a node whose recomputed value
equals its prior value prunes its dependents. Because the daemon keeps the `DICE`
graph warm between invocations, incremental rebuilds reuse the prior graph rather
than rebuilding it — the basis of the _"almost instant on subsequent builds"_ claim
([engineering.fb.com][fb-blog]). Git-diff-based affected-target selection is
expressed via `BXL` or `buck2 uquery`/`cquery` over the graph (Buck2's analogue to
Bazel's `rdeps()`), rather than a bespoke `--since` flag like [Turborepo][turborepo]'s
`--filter=...[ref]` or [Nx][nx]'s `nx affected`.

### 4. Caching & remote execution

This is Buck2's defining axis, and the reason it is _"remote execution first"_
([Why Buck2][why]). Buck2 speaks **Bazel's Remote Execution API** ([REAPI]):

> _"Buck2 can use services that expose Bazel's remote execution API in order to run
> actions remotely."_ ([Remote Execution docs][re-docs])

The cache is content-addressed: actions are keyed by an **action digest** over their
command + declared inputs, results live in a **content-addressable store (CAS)**,
and an `ActionCache` maps digests to results — the same REAPI contract Bazel uses,
so the cross-vendor backends overlap. Buck2 is validated against **EngFlow**,
**BuildBarn**, and **BuildBuddy** ([Remote Execution docs][re-docs]); the broader
REAPI backend ecosystem (`NativeLink`, `Buildbarn`, `BuildBuddy`) applies because
the wire protocol is shared with [Bazel][bazel]. Remote execution is wired in
`.buckconfig` under `[buck2_re_client]`:

```ini
# .buckconfig — point Buck2 at a REAPI backend (CAS + action cache + executor)
[buck2_re_client]
    engine_address       = grpcs://remote.example.com
    action_cache_address = grpcs://remote.example.com
    cas_address          = grpcs://remote.example.com
    tls_client_cert      = /etc/buck2/client.pem
    instance_name        = default
```

Per-platform execution policy is a Starlark `CommandExecutorConfig` exposing
`remote_enabled`, `local_enabled`, and `use_limited_hybrid` ([Remote Execution
docs][re-docs]), giving a **hybrid local/remote** model: an action can race or fall
back between a local sandbox and a remote worker. Digest algorithm is configurable
(`SHA256` default; `BLAKE3`, `SHA1` available via `digest_algorithms`). Because
remote execution is the _default_ mental model — not an opt-in flag like Bazel's
`--remote_executor` — a thin client can drive a build that physically runs across a
worker farm, and even a "local" build is a single-worker special case of the same
machinery.

### 5. CLI / UX ergonomics

Buck2's command boundary is the **target pattern** — a first-class, composable
addressing syntax (shared between `build`, `test`, `run`, `uquery`, `cquery`, `bxl`)
rather than a flag. A target pattern _"resolves to a set of targets … used as
arguments to commands such as `buck2 build` and `buck2 uquery`"_ ([Glossary][glossary]):

| Pattern                 | Resolves to                                                        |
| ----------------------- | ------------------------------------------------------------------ |
| `cell//path/to/pkg:tgt` | the single target `tgt` in package `path/to/pkg` of cell `cell`    |
| `//path/to/pkg:tgt`     | `tgt` in the **current** cell                                      |
| `:tgt`                  | working-directory-relative: `tgt` in the current package           |
| `//path/to/pkg:`        | all targets in package `path/to/pkg`                               |
| `//path/to/pkg/...`     | all targets in every package **recursively** beneath `path/to/pkg` |
| `//...`                 | all targets in the current cell                                    |

```bash
buck2 build //app:app                 # build one binary
buck2 build //math/...                # build everything under math/ recursively
buck2 test  //...                     # run every test in the current cell
buck2 run   //app:app -- --flag       # build and run, forwarding args after --
buck2 build //... -j 16               # cap concurrency at 16 jobs
buck2 uquery 'rdeps(//..., //math:math)'   # affected-target reasoning over the graph
```

The `...` wildcard is the "broadcast over a subtree" idiom and the
`cell//…:…` prefix the cross-cell addressing idiom — the role [Cargo][cargo]'s
`--workspace` and [Turborepo][turborepo]'s `--filter` play, but expressed in the
label algebra itself so the same syntax serves every subcommand. There is no
`-p package` flag because a package is already a first-class addressable label;
`buck2 targets //…` lists targets, `buck2 audit` introspects config, and `BXL`
covers anything the fixed CLI does not.

---

## Strengths

- **Single incremental graph, no phases.** `DICE` carries parse, configuration, and
  action results on one demand-driven graph, avoiding the redundant work and the
  loading/analysis/execution mental model of [Bazel][bazel]'s Skyframe.
- **Remote-execution-first.** Hermeticity and a content-addressed REAPI cache are
  the default substrate; "local" is a single-worker special case, so org-wide cache
  reuse and farm-scale execution come for free rather than as an opt-in.
- **Truly polyglot, language-agnostic core.** The Rust binary knows no rules; every
  ruleset is Starlark, so one graph/cache/CLI spans C++, Rust, Python, Kotlin,
  Swift, OCaml, Haskell, and more.
- **Expressive rule API.** Dynamic dependencies, anonymous targets, and transitive
  sets express build patterns (build-then-inspect, shared-compile-once) that Bazel's
  fully static model cannot.
- **Fast, GC-free engine.** Rust + tokio (no JVM GC pauses); Meta reports ~2x over
  `Buck1` and near-instant no-op rebuilds thanks to the warm daemon graph.
- **Programmable introspection via `BXL`.** Starlark scripting over the live graph
  is more flexible than a fixed query language for affected-target CI and tooling.
- **Cells for repo consolidation.** A clean mechanism for folding several formerly
  independent repositories into one project without rewriting their internals.

## Weaknesses

- **Total rewrite of the build, not adoption of native manifests.** Buck2 ignores
  `Cargo.toml`/`package.json`/`dub.sdl`; every library, test, and third-party dep
  must be re-expressed as `BUCK` targets/cells. Migration cost dominates adoption.
- **No stable release.** Only rolling bi-monthly pre-release tags; the README
  itself disclaims a stable tag, which deters conservative adopters even though Meta
  runs HEAD in production.
- **Thin third-party story out of the box.** Unlike Bazel's `Bzlmod` registry + MVS,
  Buck2 has no built-in registry resolver; third-party versioning is hand-rolled in
  cells/Starlark or via community bridges.
- **Steep learning curve.** Starlark, cells, labels, configurations/`select`,
  providers, execution platforms, and `BXL` are a lot of surface before a first
  green build.
- **Heavyweight for small / single-language repos.** For one language a native
  package manager ([Cargo][cargo], [uv][uv], `dub`) is far less ceremony.
- **Smaller ecosystem than Bazel.** Fewer mature rulesets and integrations; the
  open-source rule prelude lags Meta's internal one, and docs are still maturing
  (the `DICE` doc itself notes it is _"still experimental and largely being
  rewritten"_, [`dice/dice/docs/index.md`][dice-doc]).

## Key design decisions and trade-offs

| Decision                                                         | Rationale                                                                                        | Trade-off                                                                                    |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------- |
| Single incremental graph via `DICE` (no phases)                  | Less redundant work; one key/value/compute model for parse, configure, and execute; early cutoff | A novel engine to reason about; `DICE` itself is still being rewritten/stabilized            |
| Remote-execution-first (local = special case)                    | Hermeticity + content-addressed REAPI cache are the default; thin client drives a worker farm    | RE infra (CAS/executor) is the assumed substrate; more operational weight for tiny projects  |
| Rust + Starlark; language-agnostic core, rules out of the binary | No JVM GC pauses; deterministic, sandboxed loading; one binary serves every language             | Must re-express every library/test/dep in `BUCK`/Starlark; rulesets are separate, lagging    |
| Cells layered over packages/targets                              | Fold many ex-repos into one project; coarse grouping without a members list                      | A third namespace tier to learn; still config-discovered, not an enumerable "members" array  |
| Dynamic deps + anonymous targets + transitive sets               | Express build-then-inspect and shared-compile-once that a static graph cannot                    | More rule-author complexity; power deliberately bounded to protect query speed / hermeticity |
| Persistent daemon (`buckd`) keyed by isolation dir               | Warm `DICE` graph across invocations → near-instant no-op rebuilds; parallel worktrees coexist   | A long-lived process to manage; daemon/graph state can drift or need restarts                |
| REAPI compatibility (Bazel's remote-apis)                        | Reuse the whole Bazel RE backend ecosystem (EngFlow, BuildBarn, BuildBuddy, NativeLink)          | Inherits REAPI's operational complexity; benefits accrue mainly at scale                     |
| Target patterns (`cell//…:…`, `...`) as the command boundary     | One addressing algebra serves build/test/run/query/bxl; broadcast + cross-cell built in          | Verbose vs. a short `-p name`; requires learning labels, cells, and wildcard syntax          |
| Rolling pre-release tags, no stable tag                          | Ship Meta's battle-tested HEAD continuously without a release-stabilization burden               | No semver stability contract; conservative adopters hesitate; docs/prelude lag internal      |

---

## Sources

- [facebook/buck2 — GitHub repository][repo] (source for the cited subsystems and README)
- [buck2.build/docs — official documentation][docs]
- [Why Buck2 — design rationale, remote-execution-first, Buck1 comparison][why]
- [Architectural Model — unconfigured/configured/action graphs, package discovery][arch]
- [Glossary of Terms — cell, package, target, action, provider, daemon, RE, BXL][glossary]
- [Key Concepts — build file, target, dependency graph, package/cell/project][key-concepts]
- [`.buckconfig` — `[cells]`, `[buildfile]`, project root discovery][buckconfig]
- [Remote Execution — REAPI compatibility, `[buck2_re_client]`, hybrid execution][re-docs]
- [`dice/dice/docs/index.md` — DICE: dynamic incremental engine, Adapton/Salsa, tokio][dice-doc]
- [Introduction to Modern DICE — key/value/compute model, invalidation, early cutoff][modern-dice]
- [Build faster with Buck2 (Meta Engineering blog) — single graph, 2x, Rust, Starlark][fb-blog]
- [A Tour Around Buck2 (Tweag) — dynamic deps, configured graph, RE, cells][tweag]
- [Remote Execution API (REAPI) — the cross-vendor remote cache/execution contract][REAPI]
- Related deep-dives: [Bazel][bazel] · [Pants][pants] · [Please][please] · [Cargo][cargo] · [Go `go.work`][go-work] · [Nx][nx] · [Turborepo][turborepo] · [the D landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/facebook/buck2
[docs]: https://buck2.build/docs/
[why]: https://buck2.build/docs/about/why/
[arch]: https://web.archive.org/web/20230626131415/https://buck2.build/docs/developers/architecture/buck2/
[glossary]: https://buck2.build/docs/concepts/glossary/
[key-concepts]: https://buck2.build/docs/concepts/key_concepts/
[buckconfig]: https://buck2.build/docs/concepts/buckconfig/
[re-docs]: https://buck2.build/docs/users/remote_execution/
[dice-doc]: https://github.com/facebook/buck2/blob/3ac72b5b743d2c66909d03ab846c36e6bb30075d/dice/dice/docs/index.md
[modern-dice]: https://buck2.build/docs/insights_and_knowledge/modern_dice/
[fb-blog]: https://engineering.fb.com/2023/04/06/open-source/buck2-open-source-large-scale-build-system/
[tweag]: https://www.tweag.io/blog/2023-07-06-buck2/
[REAPI]: https://github.com/bazelbuild/remote-apis
[Starlark]: https://github.com/bazelbuild/starlark
[bazel]: ../bazel/
[pants]: ../pants/
[please]: ../please/
[cargo]: ../cargo/
[go-work]: ../go-work/
[nx]: ../nx/
[turborepo]: ../turborepo/
[pnpm]: ../pnpm/
[yarn-berry]: ../yarn-berry/
[uv]: ../uv/
[d-landscape]: ../../async-io/d-landscape.md
