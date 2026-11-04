# build2 (C++)

build2 is a Make-shaped DAG engine with typed targets, per-action rule matching, and a
per-target dependency sidecar — packaged as a three-tool toolchain (`b`, `bpkg`, `bdep`)
rather than a single binary. Vocabulary is [concepts]'s; this page does not redefine
_scheduler_, _rebuilder_, _trace_, _minimality_ or _early cutoff_.

**Last reviewed:** November 2, 2026

| Field          | Value                                                                                            |
| -------------- | ------------------------------------------------------------------------------------------------ |
| Language       | C++14 (`manifest`: `requires: c++14`; `bootstrap.sh` compiles with `-std=c++1y`)                 |
| License        | MIT — `LICENSE`; sources carry `// license : MIT; see accompanying LICENSE file`                 |
| Repository     | [build2/build2][repo]; canonical `src-url` in `manifest` is `git.build2.org/cgit/build2/tree/`   |
| Documentation  | In-tree `doc/manual.cli` (the build system manual); `doc-url` is `https://build2.org/doc.xhtml`  |
| Category       | Industry — general-purpose build engine; C/C++ first, target model general enough for any DAG    |
| Clone (pinned) | `$REPOS/build-systems-research/src/build2` at `adf7693d8521dff4c08d53889a43a173d76d6357`         |
| Version        | `0.19.0-a.0.z` (`manifest`); `NEWS` documents `0.18.0` and earlier series                        |
| Tests          | 144 `*.testscript` files under `tests/` and `libbuild2/`, run by the in-tree `testscript` runner |

## Overview

### What it solves

build2 targets C/C++ projects that must build the same way on Linux, macOS and Windows, in
and out of the source tree, with several configurations, subprojects, imported libraries and
packaged dependencies. The model descends from make but resembles it only conceptually:
targets are typed, rules are matched per operation, and persistent state is a sidecar
database next to each output rather than one global `.depend` file. The repository contains
one tool of the advertised three:

> "The toolchain is a hierarchy of tools consisting of a general-purpose build system,
> package manager (for package consumption), and project manager (for project
> development). This package contains the `build2` build system."
>
> — [`README.md`][readme]

`INSTALL.cli` says the same ("Unless you specifically only need the `build2` build system,
you should install the entire `build2` toolchain"), and `manifest` declares
`depends: * bpkg >= 0.18.0-`. There is no `bdep/` or `bpkg/` directory in this clone; the
manual refers to `bdep-new(1)` but the implementation is elsewhere, so this page is about
`b`.

### Design philosophy

The DAG model is inherited, not reinvented: the manual's introduction says `build2`
"borrows the fundamental DAG-based build model from original `make` and many of its
conceptual extensions from GNU `make`", then adds typed targets, scopes, operations and an
explicit module system. Declarations must also be configuration-independent and complete,
which the manual turns into a rule:

> "The `if-else` chains should not be used for conditional dependency declarations since
> this would violate the expectation that all of the project's source files are listed as
> prerequisites, irrespective of the configuration."
>
> — `doc/manual.cli`, "Conditions (`if-else`)"

Hence the graph is materialized once per invocation, and `dist` collects a complete source tree.

## How it works

### Buildfile: typed targets, prerequisites, scopes

```text
exe{hello}: {hxx cxx}{**}
exe{hello}: file{test.out}: test.stdout = true
```

Target types form a base-derived hierarchy rooted at `target{}`; `mtime_target` and
`path_target` add timestamps and paths, `file` adds a filesystem path, and modules add
`c{}`, `cxx{}`, `h{}`, `exe{}`, `obj{}`, `bmi{}` and friends. Types abstract extensions and
let non-file targets (`alias{}`, `dir{}`) join the graph. Name generation (`{hxx cxx}{**}`,
`*.?xx`) expands at parse time, so the prerequisite set is fixed before matching.

`./` is the directory target and `dir{}` is "everything in this directory". A project is a
tree of _scopes_: each directory gets one, variables are looked up across scopes, and the
out-of-source tree mirrors the source tree (`b hello/@hello-out/`). Variables attach to
scopes, targets or individual prerequisites; the last is how
`include = ($cxx.target.class == 'linux')` excludes a source from one configuration without
losing the declaration.

A rule is either C++ (the shipped modules), matched from a pattern, or an **ad hoc recipe**
in the `buildfile` — text hashed into `adhoc_buildscript_rule::checksum` ("Script text
hash") so a recipe edit invalidates the target, which is how one-off actions avoid a new C++
rule.

An invocation is a _buildspec_: meta-operations, operations and targets (`b clean update`,
`b update: hello/exe{hello}`). `update` and `clean` are core; `test`, `install`, `dist`,
`configure` and `version` come from modules. An _action_ is a meta-operation plus an
operation, with one-level inner/outer nesting so `test` runs `update` as its pre-operation
while a rule can still tell the difference. A rule implements `match(action, target, hint,
extras)` and `apply(...)`; `apply` returns a _recipe_, a
`target_state (action, const target&)` function returning `changed`, `unchanged` or
`postponed`, or throwing `failed`. The state is a lattice ordered for merging:
`operator|=` keeps the numerically greater state (`libbuild2/target-state.hxx`).

### Three phases, two of them parallel

> "To perform a build the build system goes through several phases. During the load phase
> the `buildfiles` are loaded and processed. … Next is the match phase during which rules
> are matched to the targets that need to be built, recursively. Finally, during the
> execute phase the matched rules are executed to perform the build."
>
> — `doc/manual.cli`, "Diagnostics and Debugging"

`load` is serial and stops at the first error. `match` and `execute` are parallel by
default and keep going after errors; `--serial-stop|-s` turns both off for debugging.
Matching recurses into prerequisites, memoizes the result, and may switch back to `load`
(to load a subdirectory's `buildfile` while resolving a `dir{}` prerequisite) or forward to
`execute` (to build a generated header the match needs). Load can also run a target through
the `update` directive — "a last resort because such updates happen serially and block
further `buildfile` evaluation".

### `depdb`: the per-target trace

Targets that need auxiliary dependency state get a `.d` sidecar beside the output:

> "This is a strange beast: a line-oriented, streaming database that can, at some point, be
> switched from reading to (over)writing. The idea is to store auxiliary/ad-hoc dependency
> information in the "invalidation" order. That is, if an earlier line is out of date, then
> all the subsequent ones are out of date as well."
>
> — `libbuild2/depdb.hxx`

For a C++ object the order is: rule id and version, compiler checksum (including the
absolute compiler path), compiler-environment checksum, a hash of the compile options
(`xxh64`), the source path, then the extracted headers. A mismatch truncates the database
there and forces an update, so a header list after a changed option is never trusted. The
database also enforces an interruption invariant — a current target must have
`mtime >= depdb.mtime` — so a crash between writing the database and writing the output is
detected next run. The static half is written during match, the dynamic half appended during
execute via `close_to_reopen()`, and the design accepts a gap: comparing the target against
its newest prerequisite "would cost extra", so "the database is a barrier between
prerequisites and the target" (`libbuild2/depdb.hxx`).

### The scheduler is a thread pool with counted tasks

A master thread issues `async()` calls, then `wait()`s on a task counter; while waiting it
works its own queue or suspends and lets a helper run. The header says it "works best for
'substantial' tasks (e.g., running a process), where in comparison thread synchronization
overhead is negligible" (`libbuild2/scheduler.hxx`).

`--jobs|-j` bounds active jobs (build-system threads plus external commands not yet
finished); `--max-jobs|-J` bounds created threads (default 32× jobs on 64-bit); `-Q` sets
queue depth. The scheduler also starts a GNU make-compatible jobserver (`fifo` on POSIX) and
exports `MAKEFLAGS` to children, so an outer `make` and build2 share one token pool; a
deadlock monitor and a jobserver monitor are budgeted as auxiliary threads.

### Placement in the scheduler × rebuilder grid

Execution is a ready-set over a graph materialized before `execute`:
`execute_prerequisites()` waits for each prerequisite before the recipe runs, so the
scheduler is _topological_ in effect even though the graph is discovered by recursion.

Rebuilding is an mtime dirty bit (`newer()`: a newer mtime, or an equal mtime with
`changed` this run) refined per target by the `depdb` trace of tool, command line and
header list — _verifying step traces_ in [concepts]'s sense, except the trace is replayed
during match and carries no result hash. The nearest cell is therefore
**topological × verifying traces (`Ninja`)**. It does not fit cleanly for three reasons the
3 × 4 grid has no axis for: the trace is consulted in a **match** phase that may itself run
tools and extend the graph; output currency is **timestamp**, not a result hash, so there is
no general early cutoff — only a rule-local one (the C++ rule compares a
preprocessed-translation-unit checksum and `touch`es the object when only whitespace or
comments changed); and the trace is a **local sidecar**, never uploaded, so the
cloud-capable cells are out of reach by construction.

## Analysis spine

### 1. Task model & scheduling

The unit of work is an `(action, target)` pair. Dependencies are prerequisites, split by
`include_type` into normal, `adhoc`, `posthoc` and `excluded`; groups (`lib{}` containing
`liba{}`/`libs{}`, `obj{}` groups, directory groups) add member resolution and a group state
that members inherit. Operation nesting gives each action an inner and outer state so
`test` and `install` reuse `update` without confusing rule matching.

Scheduling is demand-driven but not speculative: match builds the graph, execute runs it.
`match` and `execute` run concurrently by default, with a phase mutex keeping `load`
exclusive. There is no critical-path priority, no historical runtime estimate and no
speculation; the only policy is "ready work runs, blocked work waits".

### 2. Rebuilding & correctness

A target is out of date when a prerequisite is newer, or when the matched rule says so (the
cxx rule does this on a `depdb` mismatch). Rebuilding is memoized per target per run, so a
diamond builds each node once — the paper's _minimality_ holds within an invocation as long
as declarations are complete.

Correctness is timestamp-based, and the system is candid about the cost. There is no content
hash of an output, so a rebuilt-but-identical prerequisite still carries a newer mtime and
rebuilds its dependents; early cutoff exists only where a rule implements it. The C++ rule
does: `parse_unit()` checksums the preprocessed translation unit, and when the checksum
matches it skips the compiler, `touch`es the object and records `md.touch`, keeping
downstream targets clean. `depdb`'s mtime invariant catches an interrupted update that would otherwise look
current, and `--dry-run` still executes commands "required to create an accurate build
state", since skipping preprocessing would poison the next build.

### 3. Dependency discovery

Discovery is **declared plus tool-reported**, never syscall-traced. Declared prerequisites
come from the `buildfile`, including name-pattern expansion, `include` conditionals and
imported targets. For C/C++, when the list must be rebuilt, the rule runs the compiler in a
preprocessing-only mode during match (`g++ -MD -E -fdirectives-only -MF hello.o.t -o
hello.o.ii hello.cxx`), parses the make-style dependency output, and injects each header
through `dyndep_rule::inject_file()`, which also updates it if it is generated. C++20 module
imports are discovered by the same pass and become `bmi{}` prerequisites; resolving a `dir{}`
prerequisite loads that directory's `buildfile` during match. Ad hoc rules record their own
dependencies with the `depdb` builtin, including environment reads (`depdb env FOO BAR`).

There is no `ptrace`, FUSE, seccomp or sandbox checking the compiler's claim: `depdb` is the
only record of what a compilation read, so a header it did not report never becomes an edge.
The fast path replays the previous run's list and checks each header's mtime; only an invalid
database triggers a new preprocessing pass. Validating that list is not free — mapping a
header path to a target "can take up to 50% of an up-to-date check time on some projects",
which is why `enter_header()` caches it (`libbuild2/cc/compile-rule.cxx`).

### 4. Store & caching

The store is the **in-place filesystem**: outputs sit in the source tree or a mirrored
out-of-source tree, and the only persistent build information is `.d` sidecars, mtimes and
`build/config.build`. There is no content-addressable store, no action cache, no remote
cache and no deduplication. Cache keys are local: the absolute compiler path is hashed into
the compiler checksum and environment variables into the environment checksum, so the key is
correct locally and useless as a shareable one. An external compiler cache is rejected —
build2 warns that a path "looks like a ccache wrapper" because "ccache cannot be used as a …
compiler" (it does not handle `-fdirectives-only`, `libbuild2/cc/guess.cxx`). What remains
is an in-build file cache for partially preprocessed translation units, not a build cache
([`libbuild2/file-cache.hxx`][file-cache]).

### 5. Hermeticity & provenance

There is no sandbox. Commands run with the ambient environment in the project directory;
nothing verifies that a recipe read only its declared inputs or wrote only its declared
outputs. "Hermetic" here means a configuration that pins the environment:

> "Hermetic build configurations save environment variables that affect the project along
> with other project configuration in the `build/config.build` file. … the project "sees"
> exactly the same environment as during configuration."
>
> — `doc/manual.cli`, "Hermetic Build Configurations"

The manual admits the limits: hermetic configurations "only deal with the environment" and
may break when a saved compiler path goes stale. The complementary mechanism is environment
_tracking_: modules and imported programs report the variables that affect them,
`config.environment` records manual reads, `depdb env` records ad hoc recipe reads, and a
changed checksum forces a rebuild. That rebuilds the right targets after an environment
change; it is not isolation, and there is no attestation, SLSA or in-toto hook in the tree.

### 6. Distribution

Single-host only. Parallelism is threads plus child processes on one machine, bounded by
`--jobs`; the GNU make jobserver shares tokens with an enclosing `make`, which is
composition rather than distribution. There is no REAPI client, remote worker, shared cache
protocol or build farm, and no remote, CAS or execution protocol appears in `libbuild2/` —
`bpkg` distributes _packages_, not actions. This absence is a finding.

### 7. Sparkles relevance

For `sparkles:build_primitives.task`, whose DAG is fully declared and rebuilt in one pass,
build2 offers four cheap ideas: a **per-task ordered trace** (`depdb`'s rule/version, tool
checksum, command hash, then dependencies — a mismatch short-circuits the rest and
truncation yields the next write position); **tool and environment checksums as key
components**; a **mergeable result lattice** (`unchanged`, `postponed`, `busy`, `changed`,
`failed`, in merge order) as a parallel protocol; and a **machine-readable plan**
(`--match-only --dump=match --dump-format=json-v0.1`), the introspection a task DAG needs.

Avoid or measure **mtime as the only currency** (it costs early cutoff), **running tools
during graph construction** (it buys a serial load escape hatch), and **no result store**
(nothing is shareable and a clean build is a full build). The 50% header-mapping figure is
what to measure if Sparkles ever preprocesses at match: discovery is not free when nothing
rebuilds.

## Strengths

- **A target model that scales past C/C++.** Types, modules, groups, operations and ad hoc
  recipes cover compilation, code generation, testing, installation and distribution in one
  engine without pseudo-targets.
- **A small, durable trace format.** `depdb` is readable, ordered by invalidation, and
  detects interrupted updates; it is the most directly reusable idea in the tree.
- **Honest, end-to-end toolchain.** Out-of-source trees, scopes, `config.build` and
  `bpkg`/`bdep` give a coherent story from "new project" to "installed package".

## Weaknesses

- **No cache and no distribution.** Every rebuild is local and mtime-driven: no action cache,
  no CAS, no remote execution and no general early cutoff. Completeness is also the user's
  job: discovery exists only for languages with a dep-extraction rule, so an ad hoc rule
  that forgets an input is silently stale.
- **A large, opinionated surface.** Buildfile, buildscript and testscript are three
  languages, and fighting the scope/out-of-source model is explicitly discouraged.

## Key design decisions and trade-offs

| Decision                                            | Rationale                                                               | Trade-off                                                                 |
| --------------------------------------------------- | ----------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| Typed targets and rule dispatch per action          | Extensible without special-casing names; one graph for many languages   | More machinery than filename rules; a new type needs a rule               |
| Explicit `load` / `match` / `execute` phases        | Dynamic dependencies are known before any recipe runs                   | Match is impure (it may run tools) and load updates are serial            |
| `depdb` sidecar per target, invalidation-ordered    | Cheap incremental validation; readable; interruption detection built in | Not shareable; no result value; ordering is a hand-maintained convention  |
| mtime dirty bit, `target_state` merge               | Simple and fast; no hashing of every output                             | No general early cutoff; a rebuilt-but-identical output rebuilds children |
| No sandbox; hermetic configurations pin environment | Zero syscall tax; works on every supported platform                     | No isolation, no observed-input validation, no provenance                 |
| GNU make jobserver interop                          | Composes with an enclosing make without oversubscription                | Still one host; no cross-machine scheduling                               |

## Sources

- [`build2/build2`][repo] at `adf7693d8521dff4c08d53889a43a173d76d6357` (clone at
  `$REPOS/build-systems-research/src/build2`, clean worktree); quotes are verbatim at that
  SHA, with `doc/manual.cli`'s CLI markup (`\c{}`, `\i{}`) removed.
- Packaging: [`README.md`][readme], [`INSTALL.cli`][install], [`manifest`][manifest],
  [`buildfile`][root-buildfile], [`NEWS`][news], [`bx/bx.cli`][bx].
- Manual: [`doc/manual.cli`][manual] — "Introduction", "Operations", "Output Directories and
  Scopes", "Buildfile Language", "Targets and Target Types", "Diagnostics and Debugging",
  "Hermetic Build Configurations", "JSON Dump Format".
- Engine: [`libbuild2/scheduler.hxx`][scheduler], [`libbuild2/depdb.hxx`][depdb],
  [`libbuild2/target-state.hxx`][target-state], [`libbuild2/target.hxx`][target],
  [`libbuild2/target.ixx`][target-ixx], [`libbuild2/action.hxx`][action],
  [`libbuild2/operation.hxx`][operation], [`libbuild2/algorithm.hxx`][algorithm],
  [`libbuild2/algorithm.cxx`][algorithm-cxx], [`libbuild2/dyndep.hxx`][dyndep],
  [`libbuild2/b.cli`][b-cli].
- C/C++ rules: [`libbuild2/cc/compile-rule.cxx`][compile-rule],
  [`libbuild2/cc/guess.cxx`][guess], [`libbuild2/config/init.cxx`][config-init].
- Sibling pages: [concepts] for the vocabulary and Table 2, [a-la-carte] for the paper's
  model, [buildxl] for the opposite stance, [perfect-dependencies] for Rattle's traces.

<!-- References -->

[repo]: https://github.com/build2/build2
[readme]: https://github.com/build2/build2/blob/adf7693d8521dff4c08d53889a43a173d76d6357/README.md
[install]: https://github.com/build2/build2/blob/adf7693d8521dff4c08d53889a43a173d76d6357/INSTALL.cli
[manifest]: https://github.com/build2/build2/blob/adf7693d8521dff4c08d53889a43a173d76d6357/manifest
[root-buildfile]: https://github.com/build2/build2/blob/adf7693d8521dff4c08d53889a43a173d76d6357/buildfile
[news]: https://github.com/build2/build2/blob/adf7693d8521dff4c08d53889a43a173d76d6357/NEWS
[bx]: https://github.com/build2/build2/blob/adf7693d8521dff4c08d53889a43a173d76d6357/bx/bx.cli
[manual]: https://github.com/build2/build2/blob/adf7693d8521dff4c08d53889a43a173d76d6357/doc/manual.cli
[scheduler]: https://github.com/build2/build2/blob/adf7693d8521dff4c08d53889a43a173d76d6357/libbuild2/scheduler.hxx
[depdb]: https://github.com/build2/build2/blob/adf7693d8521dff4c08d53889a43a173d76d6357/libbuild2/depdb.hxx
[target-state]: https://github.com/build2/build2/blob/adf7693d8521dff4c08d53889a43a173d76d6357/libbuild2/target-state.hxx
[target]: https://github.com/build2/build2/blob/adf7693d8521dff4c08d53889a43a173d76d6357/libbuild2/target.hxx
[target-ixx]: https://github.com/build2/build2/blob/adf7693d8521dff4c08d53889a43a173d76d6357/libbuild2/target.ixx
[action]: https://github.com/build2/build2/blob/adf7693d8521dff4c08d53889a43a173d76d6357/libbuild2/action.hxx
[operation]: https://github.com/build2/build2/blob/adf7693d8521dff4c08d53889a43a173d76d6357/libbuild2/operation.hxx
[algorithm]: https://github.com/build2/build2/blob/adf7693d8521dff4c08d53889a43a173d76d6357/libbuild2/algorithm.hxx
[algorithm-cxx]: https://github.com/build2/build2/blob/adf7693d8521dff4c08d53889a43a173d76d6357/libbuild2/algorithm.cxx
[dyndep]: https://github.com/build2/build2/blob/adf7693d8521dff4c08d53889a43a173d76d6357/libbuild2/dyndep.hxx
[file-cache]: https://github.com/build2/build2/blob/adf7693d8521dff4c08d53889a43a173d76d6357/libbuild2/file-cache.hxx
[b-cli]: https://github.com/build2/build2/blob/adf7693d8521dff4c08d53889a43a173d76d6357/libbuild2/b.cli
[compile-rule]: https://github.com/build2/build2/blob/adf7693d8521dff4c08d53889a43a173d76d6357/libbuild2/cc/compile-rule.cxx
[guess]: https://github.com/build2/build2/blob/adf7693d8521dff4c08d53889a43a173d76d6357/libbuild2/cc/guess.cxx
[config-init]: https://github.com/build2/build2/blob/adf7693d8521dff4c08d53889a43a173d76d6357/libbuild2/config/init.cxx
[concepts]: ./concepts.md
[a-la-carte]: ./a-la-carte.md
[buildxl]: ./buildxl.md
[perfect-dependencies]: ./perfect-dependencies.md
