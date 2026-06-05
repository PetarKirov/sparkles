# Mill (Scala/JVM)

A JVM build tool for Java, Scala, and Kotlin whose entire model is a single
**tree of modules** declared as Scala `object`s, lowered into one **dependency
graph of `Task`s** that is content-hash-cached _by default, whether you want it to
or not_ — the JVM ecosystem's purest "everything is a memoized target" monorepo
engine, and the closest spiritual relative to [Bazel] that still reads as ordinary
host-language code.

| Field           | Value                                                                                                                        |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Language        | Scala (the tool is written in Scala; build definitions are a Scala DSL in `build.mill` / `package.mill`, with a YAML header) |
| License         | MIT                                                                                                                          |
| Repository      | [com-lihaoyi/mill][repo]                                                                                                     |
| Documentation   | [mill-build.org][docs]                                                                                                       |
| Category        | Language Package Manager / Build System                                                                                      |
| Workspace model | **Tree of modules**: `object`s extending `Module`/`ScalaModule`, mirroring the directory layout; `moduleDeps` edges          |
| First released  | Mill 0.1.x circa 2017–2018 (Li Haoyi / `com-lihaoyi`); evolved through the `0.9`–`0.12` lines                                |
| Latest release  | `1.1.6` (May 3, 2026); `1.0.0` was the major-stabilization release (July 10, 2025)                                           |

> **Latest release:** As of June 5, 2026 the stable line is **Mill `1.1.6`**
> (released May 3, 2026). The `1.0.0` milestone (July 10, 2025) was a major
> breaking release that "set a solid technical foundation," consolidated the
> per-build configuration zoo into a **YAML build header** at the top of
> `build.mill`, and enforced per-task filesystem **sandboxing**; `1.1.0` (Jan 27, 2026) added the compact `build.mill.yaml` configuration form. This deep-dive
> treats the `1.x` line as the production reality. Source citations are against the
> official docs ([mill-build.org][docs]) and the [com-lihaoyi/mill][repo] tree.

---

## Overview

### What it solves

Mill is a from-scratch JVM build tool positioned as a direct replacement for
[Maven], [Gradle], and [sbt], advertising _"3-7x faster dev workflows than other
JVM build tools"_ through, in its own words, _"aggressive caching & parallelism"_
([README][repo]). Its thesis is that the slowness and complexity of JVM builds is
not inherent: it comes from build tools whose core data model is unfamiliar
(sbt's settings hyper-matrix), whose caching is opt-in and plugin-authored (sbt
`1.x`, Maven), or whose graph is hidden behind imperative lifecycle phases
(Maven, Gradle). Mill replaces all of that with **one** idea borrowed wholesale
from [Bazel] but expressed in the host language: a **dependency graph of cached
tasks**, where the graph is constructed by a **tree of objects** that any
programmer already knows how to read.

Crucially, the monorepo story is not an add-on — it _is_ the model. From the Mill
blog ([Why Use a Monorepo Build Tool?][monorepo]):

> _"In monorepo build tools like Mill or Bazel, caching and parallelism are
> automatic and enabled by default."_

A Mill build is N modules in one tree, sharing one `out/` cache, one task graph,
one resolver, and one CLI. There is no "workspace manifest" separate from the
build because the build _is_ the workspace — the same property [sbt] has, but with
Bazel-style universal caching layered in from the first commit.

### Design philosophy

Mill's author, Li Haoyi, frames the entire tool around _familiar_ concepts. From
[So, What's So Special About The Mill Scala Build Tool?][special]:

> _"Call Graphs and Reference Graphs are concepts that are already familiar to any
> programmer with prior experience in any almost programming language … Programmers
> already_ know _this stuff, long before they ever set eyes on the Scala
> programming language or the Mill Build Tool."_

The [Design Principles][design] doc names the load-bearing abstraction outright:

> _"Mill's most important abstraction is the dependency graph of `Task`s … when
> Mill executes, the dependency graph is what matters."_

Four consequences follow, and they shape the whole tool:

1.  **Modules are a tree of Scala `object`s.** They _"serve as namespaces that let
    you group related `Task`s together"_ ([Modules][modules]), and their position
    in the tree _is_ their identity: _"A `Task`'s position in the module hierarchy
    tells you many things … you immediately know how to run it, find its output
    files, find any caches, or refer to it from other `Task`s"_ ([Design
    Principles][design]). This contrasts sharply with sbt's
    _"Four Dimensional Hyper-Matrix"_ that the author calls out as unfamiliar.
2.  **Tasks are `def` methods, customized by ordinary OOP.** A target is a method;
    you override it with `override def`, share it via `trait`, and call the parent
    with `super`. No special settings DSL.
3.  **Everything is cached by default.** _"Every `Task` in a build … is cached by
    default … This happens whether you want it to or not"_ ([Design
    Principles][design]). Caching is the baseline behavior, not an optimization you
    enable for expensive steps.
4.  **Tasks are pure.** _"Mill relies heavily on build tasks being 'pure': they
    only depend on their input tasks, and their only output is their return value"_
    ([Design Principles][design]) — which is what makes the universal caching and
    automatic parallelism sound.

Within this survey, Mill is the _Bazel-model-in-the-host-language_ data point.
Contrast it with the other Scala/JVM tools — [sbt] (settings/tasks split, Ivy
resolution, automatic CAS caching only in `2.x`), [Gradle] (imperative DSL,
incremental, remote build cache), and [Maven] (XML, fixed lifecycle, reactor) —
and with the polyglot engine it most resembles, [Bazel] (hermetic, REAPI remote
execution, non-host-language Starlark). For the D analogue under improvement see
[`dub`][d-landscape].

---

## How it works

A Mill invocation proceeds: **bootstrap** (a `./mill` launcher script pins and
fetches the version from the `build.mill` YAML header) → **compile the build**
(`build.mill` + `package.mill` files are themselves compiled as a Scala module)
→ **instantiate the module tree** (the `object`s, fixing the shape of the graph
via `moduleDeps`) → **resolve** the requested task selector against the graph →
**evaluate** the task DAG, skipping any task whose inputs and code are unchanged,
running independent tasks in parallel. The five dimensions trace each stage.

### A build is a tree of modules

The declaration surface is Scala objects in a root `build.mill`. Each `object` is
a module; nesting an object inside another nests the module; the module path
mirrors the directory layout:

```scala
// build.mill
package build
import mill._, scalalib._

object foo extends ScalaModule {
    def scalaVersion = "3.4.2"
}

object bar extends ScalaModule {
    def scalaVersion = "3.4.2"
    def moduleDeps = Seq(foo)        // bar's classpath depends on foo
    def mvnDeps = Seq(
        mvn"com.lihaoyi::os-lib:0.10.0"
    )
}
```

Source for the `foo` module lives in `foo/src/`, is compiled by the `foo.compile`
task, and its output lands in `out/foo/compile.dest/` — _"source files, output
files, and task names in Mill follow the module hierarchy"_ ([Modules][modules]).
Each `Module` carries a `moduleDir` _"that corresponds to the path that module
expects its input files to be on disk."_ Very large builds split the definition
across **`package.mill`** files in subfolders, with `build.mill` remaining the
root; libraries can also expose `ExternalModule`s _"shared between all builds
which use that library."_

### Tasks: the cached `def`

The smallest unit is a `Task`. The common kind is the cached **target**, written
with `Task { … }` (historically `T { … }`):

```scala
object foo extends ScalaModule {
    def scalaVersion = "3.4.2"

    // a custom cached target depending on `compile` and `sources`
    def lineCount = Task {
        sources()                                  // () = a dependency edge
            .flatMap(pr => os.walk(pr.path))
            .filter(_.ext == "scala")
            .map(p => os.read.lines(p).size)
            .sum
    }
}
```

Calling `sources()` (the parentheses) inside a `Task { … }` block declares a
**graph edge** — Mill records that `lineCount` depends on `sources`, exactly as
[sbt]'s `.value` macro does. There are several task flavors:

| Flavor        | Declaration               | Semantics                                                               |
| ------------- | ------------------------- | ----------------------------------------------------------------------- |
| Cached target | `def t = Task { … }`      | Memoized on disk; re-runs only if inputs/code change. The default.      |
| Input source  | `def s = Task.Source(…)`  | A filesystem input; its `PathRef` hash feeds change detection.          |
| Command       | `def c = Task.Command{…}` | Runs every invocation (e.g. `run`); not cached as a value.              |
| Persistent    | `Task(persistent=true)`   | Keeps its `Task.dest/` between runs for finer-grained incremental work. |
| Worker        | `def w = Task.Worker{…}`  | A long-lived in-memory object (e.g. a compiler), kept warm across runs. |

### `moduleDeps` shapes the graph; tasks may not

A subtle but central rule: inter-module edges are declared by `def moduleDeps`,
which is deliberately **not** a `Task`. From [Modules][modules]:

> _"`def moduleDeps` is not a Task. This is necessary because tasks cannot change
> the shape of the task graph during evaluation, whereas `moduleDeps` defines
> module dependencies that determine the shape of the graph."_

This separation of _graph topology_ (static, decided before evaluation) from _task
values_ (computed during evaluation) is what keeps the DAG well-defined and is the
property that makes Bazel-style analysis possible at all.

---

## Workspace declaration & topology

Discovery is **structural and code-driven**: the workspace is the tree of
`object`s reachable from the root `build.mill`, plus any `package.mill` files in
subfolders. There is **no glob** (`members = ["libs/*"]` à la [Cargo]) and no
explicit member array — membership is "is this `object` in the tree?" Because the
build is Scala, you _can_ compute or factor modules programmatically (shared
`trait`s, `for`-comprehensions over a list), but the canonical form is an explicit
object tree whose shape equals the directory tree.

Two topology features matter for monorepos:

1.  **The module path is the address.** `foo.bar` is the module at `foo/bar/`,
    its output is `out/foo/bar.{json,dest}`, and it is referenced from other
    modules as `moduleDeps = Seq(foo.bar)` (short name) or `build.foo.bar` (fully
    qualified). One name space; one source of truth for location, cache, and
    identity.
2.  **Cross-modules** handle "same sources, many configurations." `Cross[T]`
    instantiates a module once per axis value ([Cross Builds][cross]):

        ```scala
        object foo extends Cross[FooModule]("2.13.12", "3.4.2")
        trait FooModule extends ScalaModule with Cross.Module[String] {
            def scalaVersion = crossValue
        }
        ```

        This yields `foo["2.13.12"]` and `foo["3.4.2"]` (rendered on the CLI as
        `foo.2_13_12` because Mill _"replaces `.`s, `:`s, and `/`s in the module names
        with `_`s"_), with `Cross.Module2`/`Module3`for multi-axis (version × platform)

    builds. This is the analogue of sbt's`crossScalaVersions`/`+` cross-building,
    but expressed as first-class modules in the same tree.

> [!NOTE]
> Mill has no "root package vs. virtual workspace" dichotomy like [Cargo]. The
> root `build.mill` is always present and is itself the top of the module tree; it
> need not own sources. Topology is _the tree_, full stop.

---

## Dependency handling & isolation

Mill, like [sbt], has **two** distinct notions of dependency:

1.  **External (library) dependencies** — Maven/Ivy coordinates resolved by
    [Coursier]. The key is `mvnDeps` (renamed from `ivyDeps` in `1.x`), with a
    colon micro-syntax that encodes Scala binary-version handling
    ([Dependencies][deps]):

    ```scala
    def mvnDeps = Seq(
        mvn"org.apache.commons:commons-text:1.12.0",  // plain Java artifact
        mvn"com.lihaoyi::os-lib:0.10.0",              // :: → append Scala major version
        mvn"com.lihaoyi:::acyclic:0.3.12"             // ::: → full Scala version match
    )
    ```

    Companion keys split the classpath by scope: `compileMvnDeps` (provided),
    `runMvnDeps` (runtime), `unmanagedClasspath` (local jars), and `repositories`
    (extra Maven repos). Resolution goes through Coursier, which _"reads Coursier
    config files automatically"_ and respects mirror configuration.

    > [!WARNING]
    > **There is no lockfile by default.** Mill has no `Cargo.lock` /
    > `dub.selections.json` equivalent shipped in core — resolution is performed by
    > Coursier and cached on disk (`~/.cache/coursier`), reproducible only to the
    > extent your coordinates are pinned. Cross-module version centralization is a
    > _convention_: a shared `object Deps { val osLib = mvn"…" }` or a base `trait`,
    > the same manual discipline [sbt] needs. This is precisely the version-drift
    > gap the `dub` proposal's `[workspace.dependencies]` registry targets.

2.  **Inter-module dependencies** — `moduleDeps = Seq(foo)`. A module references a
    sibling **by its module value** (a Scala reference), not by a path string or a
    published coordinate: no relative `path=`, no publish-to-resolve cycle. This is
    Mill's local-first cross-reference, the analogue of Yarn's `workspace:`
    protocol or sbt's `dependsOn`, but type-checked when the build compiles.
    Test-scoped reuse is handled by referencing a module's test object directly.

There is **no JS-style isolation layer** — no hoisting, no symlink farm, no
virtual store (contrast [pnpm], [yarn-berry]). Each module's classpath is the
transitive closure of its `moduleDeps` plus its resolved library jars; shared
upstreams are de-duplicated by Coursier at resolution. Isolation is instead
enforced at the _filesystem_ level: `1.0.0` made each task's `Task.dest/` a
sandbox, so _"tasks would only write to their destination folder … and that module
initialization did not write to the filesystem"_ ([v1.0.0 release][v1]), with
violations now hard errors (escape hatch: `BuildCtx.withFilesystemCheckerDisabled`).

---

## Task orchestration & scheduling

This is Mill's strongest dimension — the dependency graph _is_ the tool.

**The DAG.** Every module's `def`-tasks and their cross-references form one global
directed acyclic graph; `moduleDeps` fix its shape before evaluation. When you
request a task, Mill resolves the selector to a set of target nodes, then
evaluates their transitive upstream closure.

**Parallelism.** Because tasks are pure, mutually independent tasks run
concurrently with no extra ceremony — _"caching and parallelism are automatic and
enabled by default"_ ([monorepo blog][monorepo]). Parallelism is bounded by
`--jobs`/`-j` (e.g. `-j 4`; `-j 0` uses all cores; the default is one-thread-per-
core). There is no tag/resource-restriction concept as elaborate as sbt's
`concurrentRestrictions`; the graph plus the job count govern scheduling.

**Change detection** is the headline. Two layers:

- **Value/output hashing.** A target's return value is hashed; for file outputs
  you write into `Task.dest` and return a `PathRef`, whose `hashCode` _"will
  include the hashes of all files on disk at time of creation."_ A downstream
  task re-runs only if an upstream _value_ changed — so editing a comment that
  leaves the classfiles identical _stops the rebuild at `compile`_, because
  `compile`'s `PathRef` is unchanged ([Tasks][tasks]).
- **Code/callgraph invalidation.** Uniquely among the tools in this survey, Mill
  invalidates on _build-code_ changes at method granularity: tasks are
  _"invalidated if the code they depend on changes, at a method-level granularity
  via callgraph reachability analysis"_ ([Caching][caching]). Change the body of
  one `def` in `build.mill` and only the tasks reachable from it re-run.

The default rule, verbatim: _"Default cached Tasks only re-evaluate if their input
Tasks have their value change"_ ([Caching][caching]). `Worker`s are _"kept
in-memory between runs where possible, and only invalidated if their input Tasks
change"_ — so the Scala compiler stays warm across invocations.

**Affected-detection across the monorepo** is **Selective Execution** — a
snapshot-diff workflow purpose-built for CI ([Selective Execution][selective]):

| Command                        | Role                                                                              |
| ------------------------------ | --------------------------------------------------------------------------------- |
| `mill selective.prepare`       | Run _before_ a change; snapshots task inputs + implementations to `out/`.         |
| `mill selective.run <sel>`     | Run _after_ a change; runs only the tasks in `<sel>` affected since the snapshot. |
| `mill selective.resolve <sel>` | Dry run; prints which tasks _would_ run, without running them.                    |
| `mill selective.resolveTree`   | JSON tree of invalidated inputs → selected tasks.                                 |

The canonical CI usage diffs against `main`: check out `main`, run
`selective.prepare`; check out the feature branch, run `mill selective.run
__.test`, and Mill _"use[s] the build graph to determine what modules can be
affected by the difference"_ and runs only those tests plus their downstream
dependents. It relies on `out/mill-selective-execution.json` and errors if that
snapshot is missing. This is Mill's `--since <git-ref>` equivalent — but
expressed as an explicit prepare/run handshake over the persisted task-input
fingerprints rather than a single VCS-diff flag.

---

## Caching & remote execution

**Local caching is universal and automatic.** Every task is cached on disk under
the `out/` directory: a task `foo.bar` writes a `out/foo/bar.json` metadata file
holding _"the cache-key and JSON-serialized return-value"_, plus a dedicated
`out/foo/bar.dest/` scratch/output folder ([Tasks][tasks], [Caching][caching]).
On the next run Mill reads the cache-key (a hash of the task's inputs and code),
and if it matches, the stored value is reused and the task — and everything
downstream of it whose value is therefore unchanged — is skipped entirely. Build
profiling output (`out/mill-profile.json`, `out/mill-invalidation-tree.json`)
records a `"cached": boolean` per task and the invalidation tree, so you can see
exactly what re-ran and why.

This is a meaningful contrast with [sbt] `1.x` (where task caching was manual /
plugin-authored) and even with [Cargo]/[go-work] (which cache compilation
fingerprints but not arbitrary tasks): in Mill, _any_ `def` you write is a cached
node for free.

**Remote / distributed caching is _not_ native.** This is Mill's most notable gap
versus the heavyweight engines. As of the `1.x` line, Mill has no built-in
content-addressed remote cache and no [Remote Execution API (`REAPI`)][reapi]
backend — only a community proof-of-concept ([remote-cache POC][remotepoc],
[discussion #1400][disc1400]) that `GET`/`PUT`s outputs to an HTTP server, plus
prototypes the maintainers describe as work-in-progress. So unlike [sbt] `2.x`
and [Gradle] (which speak Bazel-compatible `REAPI` / a remote build cache), or the
polyglot [Bazel]/[Buck2] engines wired to [buildbuddy]/[buildbarn]/[nativelink],
Mill's caching is **machine-local**. Teams achieve cross-CI reuse by **persisting
the `out/` directory** as a CI cache artifact between jobs — coarser and less
principled than a shared CAS, but workable.

> [!IMPORTANT]
> Mill is, among the _language_ build tools in this survey, unusual in pairing
> **best-in-class automatic local task caching** with **no native remote cache**.
> Its answer to "scale CI without a cache server" is **Selective Execution**
> (skip unaffected work via graph + git diff) rather than **remote caching**
> (fetch already-computed results) — a different, complementary lever to the one
> [sbt] `2.x`/[Gradle] reach for. There is no remote _execution_ at all.

---

## CLI / UX ergonomics

Mill's command boundary is a **task selector** that walks the module tree, with a
rich query syntax ([Query Syntax][query]):

```bash
mill foo.compile               # one task in one module
mill foo.run hello world       # a command with arguments
mill foo.{compile,test}        # brace enumeration → two tasks
mill '{foo,bar}.test'          # run test in two modules
mill '_.test'                  # _ = ONE path segment: every top-level module's test
mill '__.test'                 # __ = MANY segments: every test task, recursively
mill '__:TestModule.jar'       # type filter: only modules that are TestModules
mill foo.run a + bar.run b     # + starts a new selector with its own args
mill -w foo.compile            # -w / --watch: re-run on source change
mill -j 4 __.compile           # -j / --jobs: cap parallelism at 4
mill resolve __                # dry-run: list every task the selector matches
```

The two wildcards are the ergonomic core: `_` _"acts as a placeholder for a single
segment"_, while `__` _"acts as a placeholder for many segments … it can represent
an empty segment"_ ([Query Syntax][query]). So `__.test` is the monorepo "test
everything" broadcast, `foo.__.test` scopes the broadcast to a subtree, and
`foo.bar.test` is a single targeted member — the same global-broadcast →
subtree-scope → single-target spectrum [sbt] expresses with `test` /
`subproj/task`, but with first-class glob wildcards [sbt] lacks. `mill resolve`
makes the selector introspectable before you run anything.

Two more ergonomic levers:

- **`-w` / `--watch`** turns any selector into a file-watching loop (the analogue
  of sbt's `~` prefix), re-running on source changes.
- **A warm daemon by default.** Mill `1.x` runs as a background server so the JVM
  and `Worker`s (compiler, etc.) stay hot between commands — the same
  amortize-JVM-startup strategy as sbt's `sbtn`/server, but on by default rather
  than opt-in.

There is no `--filter` package-glob flag in the [Turborepo]/[Nx] sense and no
single `--changed-since` flag; cross-monorepo "only what changed" is the
`selective.*` prepare/run pair described above.

---

## Strengths

- **One model, familiar concepts.** A tree of `object`s + a graph of `def`s; no
  settings hyper-matrix, no XML, no separate workspace manifest. The build reads
  as ordinary Scala/host-language code.
- **Universal, automatic, content-hash caching.** _Every_ task is a cached node
  by default; downstream work is skipped on value-equality, and **build-code
  changes invalidate at method granularity** via callgraph analysis — finer than
  any peer in this survey.
- **Monorepo-native from day one.** N modules, one `out/`, one graph, one
  resolver, automatic parallelism — caching and concurrency are on by default,
  not bolted on.
- **Selective Execution for CI.** Graph-aware, git-diff-driven affected-test
  selection (`selective.prepare` / `selective.run`) scales large-monorepo CI
  without a remote cache.
- **Powerful, introspectable CLI.** `_`/`__` wildcards, brace enumeration, type
  filters, `+` multi-selectors, `mill resolve` dry-run, and `-w` watch.
- **Polyglot within the JVM.** `mill.javalib`, `mill.scalalib`, `mill.kotlinlib`
  (binary-compatibility-enforced in `1.0.0`), plus Android support.
- **Warm daemon by default** amortizes JVM/compiler startup.

## Weaknesses

- **No native remote cache or remote execution.** Caching is machine-local; teams
  persist `out/` as a CI artifact or rely on Selective Execution. No `REAPI`
  backend (contrast [sbt] `2.x`, [Gradle], [Bazel]).
- **No lockfile in core.** External-dependency reproducibility leans on pinned
  coordinates + the Coursier cache; cross-module version centralization is a
  manual `Deps`-object convention — version drift is possible.
- **No glob membership.** Members are the object tree; there is no
  `members = ["libs/*"]` (though the Scala build can compute modules).
- **Build is compiled Scala.** A cold build pays a build-compilation step (the
  daemon mitigates); editing `build.mill` triggers a rebuild of the build itself.
- **Smaller ecosystem than [Gradle]/[Maven].** Fewer third-party plugins; some
  enterprise integrations and IDE corner cases are less polished.
- **Younger API surface.** `1.0.0` (July 2025) deliberately broke compatibility
  (`ivyDeps` → `mvnDeps`, `T{}` → `Task{}`, sandbox enforcement); pre-`1.0`
  builds and docs need migration.

## Key design decisions and trade-offs

| Decision                                               | Rationale                                                                        | Trade-off                                                                          |
| ------------------------------------------------------ | -------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Build = tree of `object`s + graph of `def` tasks       | Reuse "object hierarchy" + "call graph" — concepts every programmer knows        | Build is compiled Scala; editing the build recompiles it; cold-start cost          |
| Everything cached by default (`out/<mod>/<task>.json`) | Caching is baseline, not an optimization; correctness from pure tasks            | Large `out/` on disk; sandbox rules must be respected or caching is unsound        |
| Value/`PathRef`-hash change detection                  | Skip downstream when an upstream _value_ is unchanged (comment edits stop early) | Requires disciplined `Task.dest`-only writes; non-determinism breaks reuse         |
| Method-level callgraph invalidation of build code      | Editing one `def` re-runs only reachable tasks — minimal rebuild                 | Analysis machinery in the core; surprising if you expect coarse whole-build reload |
| `moduleDeps` is _not_ a task (topology fixed pre-eval) | Keeps the DAG well-defined; enables Bazel-style analysis                         | Graph shape can't be computed by tasks at runtime; some dynamism is off-limits     |
| Coursier resolution, **no lockfile** in core           | Simple, machine-cached, flexible per-module versions                             | Version drift across modules; reproducibility needs pinning + a `Deps` convention  |
| Selective Execution instead of a remote cache          | Scale CI by _skipping_ unaffected work via graph + git diff                      | Two-step prepare/run handshake; no cross-machine reuse of _computed results_       |
| No native `REAPI` remote cache/execution (`1.x`)       | Keep the core small; local caching covers the common case                        | No shared CAS; CI reuse is coarse (`out/` artifact); lags [sbt] `2.x`/[Gradle]     |
| `_`/`__` wildcard selectors + warm daemon by default   | Expressive targeting; amortized JVM/compiler startup                             | Selector syntax has a learning curve; daemon lifecycle/staleness to manage         |

---

## Sources

- [com-lihaoyi/mill — GitHub repository][repo] (tagline, "3-7x faster",
  MIT, `1.1.6`)
- [mill-build.org — official documentation][docs]
- [Mill Design Principles][design] — _"the dependency graph of `Task`s … is what
  matters"_; tree-of-modules-as-identity; "every Task … is cached by default …
  whether you want it to or not"; tasks are pure
- [So, What's So Special About The Mill Scala Build Tool?][special] — call
  graphs/reference graphs as familiar concepts; OOP customization; sbt's
  "Four Dimensional Hyper-Matrix"
- [Caching in Mill][caching] — default cached tasks re-evaluate only on input
  value change; method-level callgraph reachability invalidation; warm `Worker`s
- [Tasks][tasks] — `Task`/`Task.dest`/`PathRef` hashing; `out/<mod>/<task>.json`
  metadata (cache-key + serialized value); persistent tasks
- [Modules][modules] — `object extends Module`/`ScalaModule`; `moduleDeps`
  ("not a Task … determines the shape of the graph"); `moduleDir`; nesting;
  `ExternalModule`; `package.mill`
- [Cross Builds][cross] — `Cross[T]`, `crossValue`, `Cross.Module2/3`, name
  mangling of `.`/`:`/`/` to `_`
- [Scala Library Dependencies][deps] — `mvnDeps`/`compileMvnDeps`/`runMvnDeps`,
  `mvn"org::artifact:version"` `:`/`::`/`:::` syntax, Coursier resolver
- [Selective Test Execution][selective] — `selective.prepare`/`run`/`resolve`,
  `out/mill-selective-execution.json`, git-diff-driven downstream selection
- [Faster CI with Selective Testing][selectiveblog] — CI workflow rationale
- [Query Syntax][query] — `_`/`__` wildcards, brace enumeration, type filters,
  `+` multi-selector, `.super`
- [Why Use a Monorepo Build Tool?][monorepo] — "caching and parallelism are
  automatic and enabled by default"; Selective Execution positioning
- [Mill Build Tool v1.0.0 Release Highlights][v1] — YAML build header,
  per-task filesystem sandboxing, Kotlin binary-compat
- [Remote Caching POC (discussion #1400)][disc1400] · [community remote-cache
  server][remotepoc] — remote caching is community/prototype, not native
- Related deep-dives: [sbt] · [Gradle] · [Maven] · [Cargo] · [go-work] ·
  [pnpm] · [yarn-berry] · [Bazel] · [Buck2] · [Turborepo] · [Nx] ·
  [buildbuddy] · [buildbarn] · [nativelink] · [`dub` (D)][d-landscape]

<!-- References -->

[repo]: https://github.com/com-lihaoyi/mill
[docs]: https://mill-build.org/mill/index.html
[design]: https://mill-build.org/mill/depth/design-principles.html
[special]: https://www.lihaoyi.com/post/SoWhatsSoSpecialAboutTheMillScalaBuildTool.html
[caching]: https://mill-build.org/mill/depth/caching.html
[tasks]: https://mill-build.org/mill/fundamentals/tasks.html
[modules]: https://mill-build.org/mill/fundamentals/modules.html
[cross]: https://mill-build.org/mill/fundamentals/cross-builds.html
[deps]: https://mill-build.org/mill/scalalib/dependencies.html
[selective]: https://mill-build.org/mill/large/selective-execution.html
[selectiveblog]: https://mill-build.org/blog/3-selective-testing.html
[query]: https://mill-build.org/mill/cli/query-syntax.html
[monorepo]: https://mill-build.org/blog/2-monorepo-build-tool.html
[v1]: https://mill-build.org/blog/13-mill-build-tool-v1-0-0.html
[disc1400]: https://github.com/com-lihaoyi/mill/discussions/1400
[remotepoc]: https://github.com/psilospore/mill-remote-cache-server
[reapi]: https://github.com/bazelbuild/remote-apis
[coursier]: https://get-coursier.io/
[sbt]: ../sbt/
[gradle]: ../gradle/
[maven]: ../maven/
[cargo]: ../cargo/
[go-work]: ../go-work/
[pnpm]: ../pnpm/
[yarn-berry]: ../yarn-berry/
[bazel]: ../bazel/
[buck2]: ../buck2/
[turborepo]: ../turborepo/
[nx]: ../nx/
[buildbuddy]: ../buildbuddy/
[buildbarn]: ../buildbarn/
[nativelink]: ../nativelink/
[d-landscape]: ../../async-io/d-landscape.md
