# Pants (Polyglot)

A scalable polyglot build orchestrator for monorepos whose defining bet is
**dependency inference**: instead of hand-written dependency edges (the
[Bazel][bazel] / `Buck2` model), Pants reads your `import` statements with
per-language static analysis, builds a fine-grained file-level target graph, and
executes it through a memoizing Rust + [Tokio][tokio]-async engine that caches
every process precisely by its inputs — locally or over the [Bazel][bazel]
Remote Execution API.

| Field           | Value                                                                                                                |
| --------------- | -------------------------------------------------------------------------------------------------------------------- |
| Language        | Rust (engine core) + typed Python 3 (rules / plugin API); Starlark-like `BUILD` files                                |
| License         | Apache-2.0                                                                                                           |
| Repository      | [pantsbuild/pants][repo]                                                                                             |
| Documentation   | [pantsbuild.org][docs] · [How does Pants work?][how] · [Targets & `BUILD` files][targets]                            |
| Category        | Polyglot Build Orchestrator                                                                                          |
| Workspace model | Single repo rooted at `pants.toml`; the whole tree is one workspace of `BUILD`-file packages, sliced by source roots |
| First released  | `v1` open-sourced out of Twitter, Sept 2014 (Scala/JVM era); `v2` (the current Rust-engine rewrite) GA 2020          |
| Latest release  | `2.32.0` (May 28, 2026); `2.31.0` (Feb 19, 2026) was the prior stable line                                           |

> **Latest release:** `2.32.0`, released **May 28, 2026**. Pants ships on a
> roughly quarterly `2.x` cadence (`2.27` Jun 2025, `2.28` Sep 2025, `2.31`
> Feb 2026, `2.32` May 2026). Note `2.31` **dropped Intel macOS (`x86_64`)
> binaries**. Citations below are against the `main` branch and the `dev`
> documentation channel as of June 5, 2026.

---

## Overview

### What it solves

Pants targets the same problem as [Bazel][bazel] and `Buck2` — **one repository
containing many projects in many languages, built and tested as a single
coherent graph** — but attacks the _adoption cost_ that makes those tools heavy.
The README states the scope precisely:

> _"Pants is a scalable build system for monorepos: codebases containing
> multiple projects, often using multiple programming languages and frameworks,
> in a single unified code repository."_ — [`README.md`][repo]

Where [Bazel][bazel] makes you write and maintain the dependency graph by hand
(`deps = ["//mathlib"]` on every rule), Pants' wager is that **the graph is already
encoded in your source** — Python `import`s, Go `import`s, JVM `import`s,
TypeScript `import`s, protobuf `import`s — and a build tool should _read_ it
rather than make you _restate_ it. That single decision cascades through the
whole design: `BUILD` files shrink to near-empty metadata stubs (often
auto-generated), and the engine still gets a precise, fine-grained graph to
invalidate and cache against. The official framing:

> _"Pants is designed to be easy to adopt, use, and extend. It doesn't require
> you to refactor your codebase or to create and maintain massive amounts of
> build metadata."_ — [Welcome to Pants][docs]

The README enumerates the seven pillars that follow from that goal:

1. **Explicit dependency modeling** (inferred, then materialized as a graph).
2. **Fine-grained invalidation.**
3. **Shared result caching.**
4. **Concurrent execution.**
5. **Remote execution.**
6. **Unified interface for multiple tools and languages.**
7. **Extensibility and customizability via a plugin API.**

Conceptually Pants sits between the language-specific package managers
([Cargo][cargo], [uv][uv], [npm][npm]) — which own dependency resolution for one
language but cannot orchestrate a polyglot graph — and the heavyweight hermetic
engines ([Bazel][bazel], `Buck2`) that orchestrate any language but demand fully
hand-authored build files. It overlaps most with `Please` (another
inference-leaning Go-implemented engine) and the simpler task graphs of
[Nx][nx] / [Turborepo][turborepo].

### Design philosophy

The headline architectural choice is a **two-language engine**: a Rust core for
speed, Python rules for extensibility.

> _"The Pants engine is written in Rust, for performance. … The build rules
> that it uses are written in typed Python 3, for familiarity and simplicity."_
> — [How does Pants work?][how]

The Rust core is built on [Tokio][tokio] — the engine "can take full advantage
of all the cores on your machine," running lint, type-check, and test legs
concurrently across the discovered graph. Three consequences shape the entire
tool:

1. **The graph is a memoized pure-function evaluation.** Build logic is a set of
   `@rule`s: typed Python `async` functions whose `await Get(Output, Input)`
   calls form an implicit dependency graph the Rust engine schedules. The engine
   "caches processes precisely based on their inputs" — every node is a pure
   function of its declared inputs, so the same inputs always hit the cache.
   This is the same correctness discipline as Bazel's action graph, reached by a
   different authoring path.
2. **Hermetic, sandboxed process execution.** Each external process (a `pytest`
   run, a `go build`, a `mypy` invocation) executes in a sandbox containing only
   its declared inputs. Hermeticity is what makes the cache key trustworthy and
   what makes _remote_ execution a near-free extension of local execution.
3. **A long-lived daemon keeps the graph warm.** `pantsd` watches the
   filesystem and keeps the build graph and rule memoization resident between
   runs, so an edit invalidates only the reverse-transitive closure of the
   changed file rather than forcing a cold re-evaluation.

The unifying thesis, from the docs, is that incrementality and distribution are
emergent rather than bolted-on:

> _"…fine-grained invalidation, concurrency, hermeticity, caching, and remote
> execution happen naturally"_ — [Welcome to Pants][docs]

---

## Core abstractions and types

| Concept                  | Name / syntax                                                  | Role                                                                            |
| ------------------------ | -------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Workspace root           | `pants.toml` at the repo root                                  | The single boundary marker; everything below is one workspace                   |
| Package metadata         | `BUILD` files                                                  | Per-directory target declarations (often auto-generated by `tailor`)            |
| Target                   | `python_sources`, `go_binary`, `pex_binary`, `docker_image`, … | Addressable metadata describing code or an artifact                             |
| Atom (file-level) target | `path/to/file.py:tgt`                                          | One generated target per source file — the unit of inference & invalidation     |
| Target generator         | `python_tests`, `files`, `go_mod`                              | One declaration → many generated per-file/per-package targets                   |
| Target address           | `path/to/dir:name`, `//:root_tgt`, `:sibling`                  | The unique handle; `//` is the build root                                       |
| Source root              | `[source].root_patterns` / `marker_filenames`                  | Directory where a language's import namespace begins                            |
| Resolve                  | `[python.resolves]` name → lockfile path                       | A named third-party dependency universe (its own lockfile)                      |
| Goal                     | `test`, `lint`, `fmt`, `check`, `package`, `run`, `repl`       | The verb / command boundary; `pants <goal> <specs>`                             |
| Rule                     | `@rule async def …`                                            | A typed Python node in the engine graph (`await Get(Out, In)`)                  |
| Backend                  | `[GLOBAL].backend_packages`                                    | A pluggable language/tool module (`pants.backend.python`, `…go`, `…javascript`) |
| Daemon                   | `pantsd`                                                       | Filesystem-watching process keeping the graph + memo cache warm                 |
| Engine core              | `src/rust/engine` (Rust + Tokio)                               | Schedules and memoizes the rule graph; runs sandboxed processes                 |
| Local store              | `~/.cache/pants/lmdb_store`                                    | Content-addressed local CAS + action cache (LMDB)                               |

---

## How it works

A Pants invocation is `pants <goals> <specs>` — e.g. `pants test ::` ("test
everything") or `pants lint check src/python::`. The engine resolves the specs
to a set of targets, expands each goal into a rule subgraph, infers the
dependency edges between targets from their source imports, schedules the
resulting node graph across cores, executes every external tool in a sandbox,
and memoizes each node by the content hash of its inputs.

A minimal root config selecting a couple of language backends:

```toml
# pants.toml
[GLOBAL]
pants_version = "2.32.0"
backend_packages = [
    "pants.backend.python",
    "pants.backend.experimental.go",
]

[source]
root_patterns = ["/src/python", "/src/go"]

[python]
enable_resolves = true
default_resolve = "python-default"

[python.resolves]
python-default = "3rdparty/python/default.lock"
```

A `BUILD` file is typically tiny because inference fills in `dependencies`:

```python
# src/python/myorg/app/BUILD
python_sources()          # generates one python_source target per .py file here
pex_binary(name="bin", entry_point="main.py")

# src/python/myorg/app/BUILD  — note: no `dependencies=[...]` needed
```

The canonical way to author/refresh `BUILD` files is not by hand but via the
`tailor` goal, which scans for unowned source files and writes the minimal
target stubs for them:

```bash
pants tailor ::          # auto-create/update BUILD targets across the whole repo
```

### Dimension 1 — Workspace declaration & topology

Pants has **no explicit member array and no glob of sub-packages.** The
workspace is the single repository rooted at `pants.toml`; topology is _implicit
in the directory tree_, where every directory containing a `BUILD` file is a
**package**, and the language-import namespace is anchored by **source roots**.
This is closer to [Bazel][bazel]'s implicit-tree model than to the explicit
`members = [...]` arrays of [Cargo][cargo] or [pnpm][pnpm].

Source roots are the topology primitive. They are declared two ways
([Source roots][sourceroots]):

```toml
# pattern-based: paths that are roots of an import hierarchy
[source]
root_patterns = ["/src/python", "/test/python", "/src/*"]

# OR marker-file based:
[source]
marker_filenames = ["SOURCE_ROOT", "BUILD_ROOT"]
```

> _"Place a file of that name in each of the source roots. The contents of those
> files don't matter."_ — [Source roots][sourceroots]

Source roots translate filesystem layout into import namespaces: with
`/src/python` a source root, `src/python/project/app.py` imports as
`from project.app import App`. Because patterns support relative suffixes
(`src/python` matches any directory ending that way) and globs (`/src/*`), a
monorepo can mix per-language top-level trees (`src/java`, `src/go`) and
project-local roots (via marker files) in the same repository without
reorganizing code — the explicit anti-refactor stance from the design
philosophy.

> [!NOTE]
> The unit of addressing is finer than a directory. Pants generates a **target
> per file** (the "atom" target `path/to/file.py:gen`), which is what lets
> inference and invalidation operate at file granularity rather than at the
> coarse package granularity of most language package managers.

### Dimension 2 — Dependency handling & isolation

This is where Pants diverges most sharply from every neighbor. There are two
distinct dependency layers, handled differently:

**First-party (intra-repo) edges are inferred, not declared.**

> _"Usually, you leave off the `dependencies` field thanks to dependency
> inference. Pants will read your import statements and map those imports back to
> your first-party code and your third-party requirements."_ —
> [Targets & `BUILD` files][targets]

So a local cross-reference between two members is _automatic_: importing
`from myorg.lib import x` creates a graph edge to the target owning
`myorg/lib`. There is no `workspace:` protocol ([pnpm][pnpm] / [Yarn][yarn]), no
`path = "../lib"` ([Cargo][cargo]), and no `//lib` label ([Bazel][bazel]) to
write — the import _is_ the edge.

**Third-party deps use named resolves + lockfiles, with no global hoisting.**
A **resolve** is a named dependency universe backed by its own lockfile
([Lockfiles][lockfiles]):

```toml
[python]
enable_resolves = true
default_resolve = "python-default"

[python.resolves]
python-default = "3rdparty/python/default.lock"
django3      = "3rdparty/python/django3.lock"
django4      = "3rdparty/python/django4.lock"
```

A lockfile "enumerates specific pinned versions of every transitive third-party
dependency" with SHA256 hashes; `pants generate-lockfiles` (delegating to Pex
for Python) produces them. Each target picks its universe via a `resolve=`
field, and "all transitive dependencies of a source target must use the same
resolve" — so multiple incompatible versions (Django 3 _and_ Django 4) can
coexist in one repo as separate resolves, the multi-version story that flat
hoisting ([npm][npm]) cannot express.

Isolation is **per-process, not per-tree**: there is no shared `node_modules`
hoist and no symlink farm. Each sandboxed process gets _only_ the requirements
it transitively uses:

> _"…when running a test, only the requirements actually used (transitively) by
> that test will be present on the `sys.path`."_ — [Lockfiles][lockfiles]

This dependency **subsetting** is both a correctness property (a sandbox cannot
see undeclared deps) and a cache property (a change to an unrelated requirement
does not invalidate this test's action key).

### Dimension 3 — Task orchestration & scheduling

Pants builds a true **rule DAG**, not a fixed task list. The Rust engine
([`src/rust/engine`][engine]) treats every `@rule` as a memoized node; a rule's
`await Get(Output, Input)` calls are its outgoing edges. A goal like `test`
expands into a subgraph rooted at the requested targets, which in turn pull in
their inferred first-party dependencies and the processes needed to compile,
resolve, and run them. The engine then:

- **Schedules concurrently.** Independent legs (lint vs. type-check vs. test of
  unrelated targets) run in parallel across all cores via Tokio. The Tokio move
  was deliberate — the engine separates "control of concurrent filesystem access
  from process execution," ([PR #5846][tokio-pr]).
- **Invalidates fine-grained.** `pantsd` watches the filesystem; an edit
  invalidates only the memo nodes whose inputs changed and their
  reverse-transitive dependents. Everything else stays warm in the daemon.
- **Keys on content, not timestamps.** A process's cache key is the content hash
  of its sandbox inputs (sources, tool, args, env). Identical inputs ⇒ cache
  hit, the precondition for a _shared_ cache being correct.

This is the same "pure function of declared inputs" invariant that makes
[Bazel][bazel]'s action cache sound — but Pants reaches it without the author
declaring the inputs, by deriving them from imports + the rule graph.

### Dimension 4 — Caching & remote execution

Caching is layered:

- **Local memoization** — within and across runs (warm in `pantsd`).
- **Local persistent cache** — a content-addressed store on disk
  (`~/.cache/pants/lmdb_store`, an LMDB-backed CAS + action cache). Default
  behavior is local-only: "Pants executes locally and caches results locally by
  default."
- **Remote caching & remote execution** over **REAPI**, the same standard
  protocol Bazel uses:

> _"Pants is compatible with remote caching and remote execution servers that
> comply with the Remote Execution API standard ('REAPI')."_ —
> [Remote caching & execution][remote]

A REAPI server exposes three services, which Pants maps onto its own vocabulary:
a **content-addressable storage** ("store server"), an **action cache**, and an
**execution service** ("execution server"). A _remote cache_ implements CAS +
action cache; a _remote executor_ implements all three. Compatible self-hosted
backends include **[BuildBarn][buildbarn]**, **Buildfarm**, and **BuildGrid**
for full execution, plus **[bazel-remote-cache][bazel-remote]** (local disk, S3,
GCS, Azure Blob) for CAS-only caching — the very same REAPI backend universe
shared with `Buildbarn` and `NativeLink`.

Enabling a shared cache is a few `[GLOBAL]` keys:

```toml
[GLOBAL]
remote_cache_read  = true
remote_cache_write = true
remote_store_address = "grpc://build.corp.example.com:8980"   # grpcs:// for TLS
remote_instance_name = "main"
```

Remote _execution_ adds `remote_execution = true` and a
`remote_execution_address`. Because every process is already hermetic and
keyed by input content, remote execution is a near-transparent substitution of
"run this action on a farm" for "run it locally" — the hermeticity invested for
caching pays for distribution too.

### Dimension 5 — CLI / UX ergonomics

The command boundary is `pants <goals...> <specs...>`. Goals are the verbs
(`test`, `lint`, `fmt`, `check`, `package`, `run`, `repl`, `dependencies`,
`list`, `peek`, `paths`); specs are the noun set.

**Spec algebra** ([Advanced target selection][selection]):

| Spec form         | Selects                                    |
| ----------------- | ------------------------------------------ |
| `::`              | All targets in the entire repo (recursive) |
| `dir::`           | All targets under `dir` (recursive)        |
| `dir:`            | All targets in `dir` (non-recursive)       |
| `path/to/file.py` | The target(s) owning that file             |
| `dir:name`        | One specific target by address             |
| `-dir/ignore::`   | Exclude a subtree (leading `-`)            |

Crucially, you can pass **files and directories directly** — `pants test
src/python/app/test_foo.py` — and Pants maps the file back to its owning
target. The docs make this the headline ergonomic: you "invoke it directly on
source files and directories, so it doesn't require users to adopt a new
conceptual model" ([Welcome to Pants][docs]). Compare Bazel's mandatory
`//pkg:tgt` label algebra.

**Affected-target / change detection** is first-class via git:

> _"pants can find which files have changed since a certain commit through the
> `--changed-since` option."_ — [Advanced target selection][selection]

```bash
pants --changed-since=origin/main lint                       # only changed files
pants --changed-since=HEAD~1 --changed-dependents=transitive test
```

`--changed-dependents=direct|transitive` widens the set from the changed files
to their dependents — the affected-set CI optimization that [Nx][nx],
[Turborepo][turborepo], and Bazel's `rdeps`/`target-determinator` provide,
built into the core CLI here rather than as a side tool.

**Filtering and sharding** layer on top: `--filter-target-type=python_test`,
`--filter-address-regex=…`, `--filter-tag-regex=…` (comma = OR, repeat = AND,
`-` prefix = NOT), `--tag`/`--tag='-…'` against each target's `tags` field,
`--spec-files=<file>` for a centralized allowlist, and native test sharding via
`--test-shard=k/N`. Reusable verb+flag combos go in `[cli.alias]` in
`pants.toml`.

---

## Strengths

- **Dependency inference erases the biggest Bazel/Buck2 adoption cost.** No
  hand-written `deps`; `BUILD` files are generated by `tailor` and stay tiny.
  The graph still ends up fine-grained and precise.
- **Polyglot from one interface.** A single `pants test ::` covers Python, Go,
  JVM (Java/Scala/Kotlin), JS/TS, Shell, Docker, protobuf — composing each
  language's standard tools into one hermetic toolchain.
- **Correct shared caching by construction.** Hermetic, content-keyed processes
  make local, remote-cache, and remote-execution results interchangeable —
  REAPI-compatible, so it reuses the [BuildBarn][buildbarn]/[bazel-remote] farm
  ecosystem rather than inventing one.
- **File-level granularity + warm daemon.** `pantsd` keeps the graph resident;
  edits invalidate only the reverse-transitive closure of the touched file.
- **Affected-set CI is built in.** `--changed-since` + `--changed-dependents`
  need no external determinator tool.
- **Extensible in plain typed Python.** Rules are `async` Python functions over
  a typed `Get`/`Rule` API — a far lower barrier than authoring Starlark rules.
- **Ergonomic noun model.** Pass files/dirs directly; no mandatory label syntax.

## Weaknesses

- **Inference is per-language and imperfect.** Dynamic imports, runtime plugin
  discovery, resources, and non-import file dependencies need explicit
  `dependencies` entries or fail silently — the convenience has sharp edges.
- **Heavier and slower to cold-start than minimalist runners** (`Task`, `Just`,
  [Turborepo][turborepo]); the Rust engine + daemon + Python rule graph is real
  machinery (though `2.28` cut daemon startup to ~30–40%).
- **One conceptual universe per language, parallel to native tooling.** Resolves
  - lockfiles are a Pants-managed dependency world living alongside (and
    sometimes duplicating) each language's own resolver — the same critique
    levelled at Bazel's `Bzlmod`.
- **"All transitive deps share one resolve"** is a real constraint: mixing two
  versions of a library means partitioning targets into separate resolves.
- **Smaller ecosystem & community than [Bazel][bazel].** Fewer pre-built rules
  for exotic languages; more reliance on the (good) built-in backends.
- **Platform trimming.** `2.31` dropped Intel-macOS binaries — an operational
  gotcha for mixed fleets.

## Key design decisions and trade-offs

| Decision                                                         | Rationale                                                                                 | Trade-off                                                                                       |
| ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Dependency **inference** from imports (vs. hand-written `deps`)  | Eliminates the dominant adoption cost of Bazel/Buck2; `BUILD` files stay near-empty       | Inference is per-language and misses dynamic/non-import edges; needs occasional explicit deps   |
| Rust engine core + typed Python `@rule` plugin API               | Rust+Tokio for parallel performance; Python for an approachable, extensible rule language | Two-language internals; a rule-graph indirection that minimalist runners don't carry            |
| File-level (atom) targets generated per source file              | File-granular inference, invalidation, and caching                                        | Many more graph nodes than package-granular tools; `BUILD` generators needed to manage them     |
| Implicit directory-tree topology rooted at `pants.toml`          | No member arrays/globs to maintain; the tree _is_ the workspace                           | Less explicit than `members = [...]`; topology is discovered, not declared                      |
| Hermetic, content-keyed sandboxed processes                      | Makes local, remote-cache, and remote-execution results interchangeable and correct       | Undeclared inputs are errors; sandboxing has overhead vs. running tools in-place                |
| Named **resolves** + lockfiles, dependency subsetting (no hoist) | Multiple conflicting third-party versions coexist; unrelated dep changes don't invalidate | A Pants-managed dependency universe parallel to each language's resolver; one-resolve-per-graph |
| **REAPI** for remote cache + execution (reuse Bazel's protocol)  | Plug into existing [BuildBarn]/[bazel-remote]/Buildfarm farms; no bespoke backend         | Operational complexity of running CAS/action-cache/executor infra; pays off only at scale       |
| `pantsd` daemon keeps the graph + memo warm                      | Fine-grained invalidation; fast incremental edit-loop                                     | A long-lived process to manage; cold start still non-trivial                                    |
| Goals + file/dir specs + `--changed-since` as the CLI boundary   | Pass source files directly; affected-set CI without an external determinator              | A larger spec/filter vocabulary than a simple `-p name`                                         |

---

## Sources

- [pantsbuild/pants — GitHub repository][repo] (the `README.md` feature list and `src/rust/engine` core)
- [pantsbuild.org — official documentation][docs]
- [How does Pants work? — Rust engine + typed Python rules, Tokio concurrency][how]
- [Targets and `BUILD` files — addresses, target generators, dependency inference][targets]
- [Source roots — `root_patterns` / `marker_filenames`, import-path computation][sourceroots]
- [Python lockfiles & resolves — named resolves, dependency subsetting][lockfiles]
- [Remote caching & execution — REAPI, CAS / action cache / execution server][remote]
- [Advanced target selection — `::` specs, `--changed-since`, `--changed-dependents`, filters][selection]
- [`tailor` goal — auto-generating `BUILD` targets][tailor-goal]
- [PR #5846 — "Use tokio for scheduler requests and local process execution"][tokio-pr]
- [Pants 2.28 release notes — faster daemon startup, batched remote-cache reads][rel-2-28]
- [Pants 2.31 release notes — Feb 2026 stable; Intel-macOS binaries dropped][rel-2-31]
- [To Understand Pants, Understand Bazel's History — v1→v2 Rust-engine rewrite history][earthly]
- Related deep-dives: [Bazel][bazel] · `Buck2` · `Please` · [Nx][nx] · [Turborepo][turborepo] · [Cargo][cargo] · [the D landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/pantsbuild/pants
[docs]: https://www.pantsbuild.org/
[how]: https://www.pantsbuild.org/dev/docs/introduction/how-does-pants-work
[targets]: https://www.pantsbuild.org/dev/docs/using-pants/key-concepts/targets-and-build-files
[sourceroots]: https://www.pantsbuild.org/dev/docs/using-pants/key-concepts/source-roots
[lockfiles]: https://www.pantsbuild.org/dev/docs/python/overview/lockfiles
[remote]: https://www.pantsbuild.org/dev/docs/using-pants/remote-caching-and-execution
[selection]: https://www.pantsbuild.org/dev/docs/using-pants/advanced-target-selection
[tailor-goal]: https://www.pantsbuild.org/dev/reference/goals/tailor
[engine]: https://github.com/pantsbuild/pants/tree/5235dca1e76aad0a798081ad2ce16ef6bb887bcc/src/rust/engine
[tokio-pr]: https://github.com/pantsbuild/pants/pull/5846
[rel-2-28]: https://www.pantsbuild.org/blog/2025/09/08/pants-2-28
[rel-2-31]: https://www.pantsbuild.org/blog/2026/02/19/pants-2-31
[earthly]: https://earthly.dev/blog/pants-build/
[buildbarn]: https://github.com/buildbarn/bb-storage
[bazel-remote]: https://github.com/buchgr/bazel-remote
[bazel]: ../bazel/
[nx]: ../nx/
[turborepo]: ../turborepo/
[cargo]: ../cargo/
[uv]: ../uv/
[npm]: ../npm/
[pnpm]: ../pnpm/
[yarn]: ../yarn-berry/
[tokio]: ../../async-io/tokio.md
[d-landscape]: ../../async-io/d-landscape.md
