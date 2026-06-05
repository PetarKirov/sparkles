# sbt (Scala/JVM)

Scala's de-facto build tool and dependency manager, whose entire model is a
**multi-project build** authored as a Scala-DSL `build.sbt`: many `lazy val`
projects in one build, wired with `aggregate` (broadcast) and `dependsOn`
(classpath) edges, all executed by a memoizing **task graph** engine — the JVM
ecosystem's closest analogue to the language-native workspace `dub` wants.

| Field           | Value                                                                                                        |
| --------------- | ------------------------------------------------------------------------------------------------------------ |
| Language        | Scala (the tool is written in Scala; build definitions are a Scala DSL in `*.sbt` / `project/*.scala`)       |
| License         | Apache-2.0                                                                                                   |
| Repository      | [sbt/sbt][repo] (+ [sbt/zinc][zinc], [sbt/librarymanagement][lm])                                            |
| Documentation   | [The sbt Reference Manual (1.x)][refman] · [The Book of sbt (2.x)][book]                                     |
| Category        | Language Package Manager / Build System                                                                      |
| Workspace model | **Multi-project build**: one build = N `Project` values; `aggregate`/`dependsOn` edges; `ThisBuild` defaults |
| First released  | sbt 0.x circa 2008 (Mark Harrah); sbt 1.0.0 in August 2017                                                   |
| Latest release  | sbt 1.x (`1.12.x` line); sbt 2.0.0 in release-candidate (`2.0.0-RC14`)                                       |

> **Latest release:** As of June 5, 2026 the stable line is **sbt 1.12.x**
> (`1.12.11` is the latest 1.x tag the author observed, with `1.12.7` carrying a
> security fix for `CVE-2026-32948`). **sbt 2.0.0** — the version that makes
> caching automatic and Bazel-`REAPI`-compatible — is feature-complete but still
> shipping as **release candidates** (`2.0.0-RC14`); this deep-dive treats 1.x as
> the production reality and calls out 2.x where it changes a dimension. Source
> citations are against the docs and the `develop`/`1.x` trees.

---

## Overview

### What it solves

sbt unifies three concerns for a Scala codebase: **dependency management** (it
embeds [Apache Ivy][ivy] via [`sbt/librarymanagement`][lm] to resolve Maven/Ivy
coordinates), **incremental compilation** (it owns [Zinc][zinc], the Scala
incremental compiler also used by Maven, Gradle, Mill, Pants, Bazel, and Bloop),
and **build orchestration** (a memoizing task-graph engine). Unlike [Maven] (XML,
fixed lifecycle) or [Gradle] (Groovy/Kotlin imperative DSL), an sbt build is
**Scala source code** evaluated to produce a settings map and a task DAG.

The monorepo story is not an add-on: it is the _native_ shape of a build. A build
is a collection of projects, each a `lazy val` of type `Project`. From the sbt
2.x guide ([Multi project basics][mpbook]):

> _"Each subproject in a build has its own source directories, generates its own
> JAR file when you run `packageBin`, and in general works like any other
> project."_

A single `build.sbt` at the root defines them all; there is no separate
"workspace manifest" because the build _is_ the workspace. Members are wired with
two distinct edge types — **aggregation** (run a task here, run it everywhere) and
**classpath dependency** (`dependsOn`, which also orders compilation) — and the
task engine schedules the resulting graph concurrently.

### Design philosophy

sbt's load-bearing decisions, all observable in the docs and source:

1.  **The build is a Scala program.** `build.sbt` is not data; it is a restricted
    Scala DSL whose `lazy val`s of type `Project` and `:=`/`+=`/`.value`
    expressions are macro-expanded into a settings graph. The trade is total
    expressiveness (you can compute project lists, share settings via Scala
    functions) at the cost of a parse/compile step on every build load.
2.  **Settings vs. tasks are different kinds.** From the [Task graph][taskgraph]
    docs: _"A setting is defined by a setting expression with `SettingKey[A]`.
    The value is calculated once during load"_ whereas _"a task is defined by a
    task expression with `TaskKey[A]`. The value is calculated each time it is
    invoked."_ Settings form a static map; tasks form a per-invocation DAG.
3.  **Two edge types, two purposes.** `aggregate` is _broadcast without ordering_;
    `dependsOn` is _classpath + ordering_. Keeping them separate is what lets a
    root project fan a `test` out to every member in parallel while a library is
    still compiled strictly before its dependents.
4.  **The task engine memoizes.** Every task in a single command runs **once**,
    even if many tasks depend on it (de-duplication), and non-dependent tasks run
    in parallel — the three properties below.
5.  **Caching was manual in 1.x, automatic in 2.x.** sbt 1.x relied on Zinc's
    incremental compiler plus plugin-authored caching; sbt 2.x embeds a
    content-addressed `ActionCache` into the task macro itself and makes it
    Bazel-`REAPI`-compatible — the single biggest architectural jump in the tool.

Within this survey sbt is the _Scala-native multi-project_ data point. Contrast
it with sibling JVM tools [Maven] (declarative XML, reactor) and [Gradle]
(imperative, incremental, with a remote build cache), the Scala alternative
[Mill] (pure-functional target graph, content-addressed by construction), and the
language-native precedent [Cargo]. For the D analogue under improvement see
[`dub`][d-landscape].

---

## How it works

An sbt invocation proceeds: **load** the build (compile `project/*.scala`, then
evaluate `*.sbt` into a settings graph) → **resolve** library dependencies via
Ivy into a per-project classpath → **build the task DAG** for the requested keys
→ **schedule & execute** it concurrently, with Zinc making `compile`
incremental and (in 2.x) the `ActionCache` skipping already-computed tasks. The
five dimensions trace each stage.

### Workspace declaration & topology

The declaration surface is Scala. Each member is a `lazy val` whose name becomes
the project ID used on the CLI; the base directory is `project in file("…")`
(or inferred from the val name). From [Multi-Project Builds][multiproject]:

> _"A project is defined by declaring a `lazy val` of type `Project`."_

```scala
// build.sbt (root of a multi-project build)
ThisBuild / scalaVersion := "3.4.2"
ThisBuild / version      := "0.1.0-SNAPSHOT"
ThisBuild / organization := "com.example"

lazy val util = (project in file("util"))

lazy val core = (project in file("core"))
    .dependsOn(util)                       // classpath edge: util compiles first

lazy val root = (project in file("."))
    .aggregate(util, core)                 // broadcast edge: tasks fan out
    .settings(name := "my-monorepo")
```

Two facts make this a _workspace_ rather than N loose projects:

1.  **One build file, one root.** All members live in one build; `build.sbt`
    files in subdirectories are _merged_ into the build but scoped to that
    project — _"Any `.sbt` files in `foo`, say `foo/build.sbt`, will be merged
    with the build definition for the entire build, but scoped to the `hello-foo`
    project"_ ([Multi-Project Builds][multiproject]). Crucially, _"You cannot have
    a `project` subdirectory or `project/*.scala` files in the sub-projects"_ —
    there is exactly one build-definition root.
2.  **An implicit root if you omit one.** From [Multi project basics][mpbook]:
    _"If a subproject is not defined at the root directory of the build, sbt
    automatically creates a default one that aggregates all other subprojects in
    the build."_ So topology discovery has a sensible default: with no explicit
    root, every project is aggregated.

`ThisBuild` is the cross-cutting default scope — _"`ThisBuild` acts as a special
subproject name that you can use to define default value for the build"_
([Multi-Project Builds][multiproject]). Setting `ThisBuild / scalaVersion`
once gives every member the same Scala version unless it overrides it: this is
sbt's equivalent of Cargo's `[workspace.package]` field inheritance, expressed
through **scope delegation** rather than explicit `field.workspace = true`
markers. Membership is _explicit and code-driven_ (you list `lazy val`s and pass
them to `.aggregate(...)`); there is **no glob** like Cargo's `members = ["libs/*"]`
— though, because the build is Scala, you can compute the project list
programmatically (real builds such as ZIO maintain `lazy val projectsCommon =
List(core, streams, …)` and fold over it).

> [!NOTE]
> sbt does not have a "virtual workspace" / "root package" dichotomy the way
> [Cargo] does. **Every** build has a root project (explicit or synthesized), and
> that root is itself a buildable `Project` — closer to Cargo's _root-package_
> mode, but always present.

### Dependency handling & isolation

There are **two** completely different notions of "dependency" in sbt, and the
distinction is the heart of the model:

1.  **Library (external) dependencies** are Maven/Ivy coordinates added to
    `libraryDependencies`, resolved by the embedded Ivy engine
    ([`sbt/librarymanagement`][lm]):

    ```scala
    libraryDependencies += "org.typelevel" %% "cats-effect" % "3.5.4"
    ```

    These are per-project lists; there is **no shared lockfile** by default. sbt
    1.x has no `Cargo.lock`/`dub.selections.json` equivalent — resolution is
    re-run (Ivy-cached on disk under `~/.ivy2`/Coursier's cache) and reproducible
    only to the extent your version ranges are pinned. (Optional plugins like
    `sbt-dependency-lock` add lockfiles; [Coursier] is the modern resolver.)

2.  **Inter-project dependencies** are the two edge types:
    - **`dependsOn`** is a _classpath_ dependency. _"A project may depend on code
      in another project … This also creates an ordering between the projects
      when compiling them; `util` must be updated and compiled before `core` can
      be compiled"_ ([Multi-Project Builds][multiproject]). This is sbt's
      local-first cross-reference: a member references a sibling **by its
      `Project` value**, not by a path string or a published coordinate — no
      relative `path=` config, no publish-to-resolve cycle. It is the closest
      analogue to Yarn's `workspace:` protocol or Cargo's `path` dependency, but
      type-checked at build-load time.

    - **`aggregate`** carries _no classpath_ and _no ordering_; it only forwards
      task invocations.

    `dependsOn` can be **configuration-scoped** so test code reuses test code:

    ```scala
    lazy val core = project.dependsOn(util % "test->test;compile->compile")
    ```

    _"You can have multiple configurations for a dependency, separated by
    semicolons … `dependsOn(util % "test->test;compile->compile")`"_
    ([Multi-Project Builds][multiproject]). Here `test->test` means _core's_
    `Test` configuration depends on _util's_ `Test` configuration.

There is **no isolation layer** in the JS sense — no hoisting, no symlink farm,
no virtual store (contrast [pnpm], [yarn-berry]). Each project has its own
classpath assembled from its `dependsOn` edges plus its resolved library jars;
shared upstreams are de-duplicated by Ivy/Coursier at resolution, not by a store.

> [!WARNING]
> Because library resolution is per-project and (in 1.x) lockfile-free, **version
> drift across members is possible**: two subprojects can pin two different
> `cats-effect` patch versions unless you centralize them (e.g. a
> `Dependencies.scala` object in `project/`, the pattern ZIO uses, or a BOM /
> `dependencyOverrides`). This is precisely the drift the `dub` proposal's
> `[workspace.dependencies]` registry aims to prevent.

### Task orchestration & scheduling

This is sbt's strongest dimension. Tasks form **a DAG of tasks, where the edges
denote happens-before relationships** ([Task graph][taskgraph]). Dependencies are
expressed by calling `.value` on another key inside a task body:

```scala
// a custom task depending on `compile` and a setting
lazy val hello = taskKey[Unit]("greets after compiling")
hello := {
    val cp = (Compile / fullClasspath).value   // .value = a dependency edge
    val n  = name.value
    println(s"compiled $n; classpath has ${cp.size} entries")
}
```

`.value` is not a normal call — _"`.value` is not a normal Scala method call"_;
it is _"a special method that is used to express the dependency to other tasks and
settings"_ that a macro lifts out of the task body ([Task graph][taskgraph]). The
engine then guarantees three properties, quoted verbatim as the _"main
advantages"_:

> _"de-duplication, parallel processing, and customizability … a task is executed
> only once even when it is depended by multiple tasks"_ and _"the task engine can
> schedule mutually non-dependent tasks in parallel."_

Concretely, when you invoke a task the engine: evaluates dependencies before the
task (**partial ordering**), runs independent dependencies concurrently
(**parallelization**), and evaluates each dependency once per command
(**de-duplication** / memoization). This is a per-invocation DAG, _not_ a
persisted incremental graph (that is Zinc's job, below).

**Aggregation parallelism.** `root/test` fans `test` to every aggregated member —
_"aggregation will run the aggregated tasks in parallel and with no defined
ordering between them"_ ([Multi-Project Builds][multiproject]). Per-task
aggregation can be disabled (`update / aggregate := false`).

**Concurrency control via Tags.** sbt classifies tasks with **tags** —
_"the `compile` task may be tagged as `Tags.Compile` and `Tags.CPU`"_ — drawn
from semantic tags (`Compile`, `Test`, `Publish`, `Update`) and resource tags
(`Network`, `Disk`, `CPU`) ([Parallel Execution][parallel]). `concurrentRestrictions`
then bounds concurrency by weighted tag, defaulting to one task per core:

```scala
// default Global / concurrentRestrictions (from the docs)
Global / concurrentRestrictions := {
    val max = Runtime.getRuntime.availableProcessors
    Tags.limitAll(if (parallelExecution.value) max else 1) :: Nil
}
```

`Tags.limit(Tags.CPU, 4)` caps CPU-heavy tasks at four; `Tags.limit(Tags.Network, 1)`
serializes network access. Under the hood `sbt.ConcurrentRestrictions` is _"an
intermediate scheduling queue between task execution (`sbt.Execute`) and the
underlying thread-based parallel execution service (`java.util.concurrent.CompletionService`)"_
that _"restricts new tasks from being forwarded to the `j.u.c.CompletionService`"_
([Parallel Execution][parallel]).

**Change detection** at the compilation layer is **[Zinc][zinc]**, the Scala
incremental compiler. Zinc uses a **name-hashing** algorithm: it _"computes a hash
for each name defined in your class … keeps track of all names used in your class
… To decide if a given class needs to be recompiled, we only need to check if any
of the names used have changed since the last compilation"_ ([Zinc-friendly
code][zincblog]). On a source change Zinc _"compiles the minimum subset of source
files affected by your change,"_ traversing the dependency analysis it persists in
`target/.../zinc/`. This is _fine-grained, intra-project_ change detection — the
analogue of Cargo fingerprints, but at the level of individual Scala definitions
rather than whole compilation units. It is **not** VCS-diff / affected-package
detection across the monorepo (there is no built-in `--since <git-ref>`).

### Caching & remote execution

This dimension splits sharply by major version.

**sbt 1.x** has three local caching layers and **no** task-level remote cache in
core:

- **Zinc incremental compilation** — the persisted analysis (`Analysis`) lets
  `compile` recompile only the affected definition closure.
- **The dependency cache** — resolved jars under `~/.ivy2` (or the Coursier
  cache), shared across all builds on the machine.
- **An experimental remote cache** ([Remote Caching][remotecache]) that
  push/pulls compilation outputs as artifacts to an Ivy/Maven repository
  (`pushRemoteCache` / `pullRemoteCache`) — coarse-grained and opt-in.

**sbt 2.x** is the step change: it makes caching **automatic and content-addressed**.
From [Caching, The Book of sbt][caching]:

> _"sbt 2.x cache automates the caching by embedding itself into the task macro
> unlike sbt 1.x wherein the plugin author called the cache functions manually in
> the task implementation."_

> _"sbt 2.x disk cache is shared among all builds on a machine."_

The engine tracks each cacheable task's inputs, stores results in a CAS
(content-addressable storage) `ActionCacheStore`, and — because storage is
configured separately — _"all cacheable tasks are automatically remote-cache-ready"_
([Caching][caching]). Output files produced on the side are registered with
`Def.declareOutput` so they too are content-addressed. The remote backend is
**Bazel-compatible**: sbt 2.x _"implements Bazel-compatible gRPC interface, which
works with number of backend both open source and commercial"_ — i.e. the
[Remote Execution API (`REAPI`)][reapi], the same protocol [nativelink],
[buildbarn], and [buildbuddy] speak. The stated goal is _"to flatten the build and
test time growth as the code size increases"_ ([Caching][caching]).

> [!IMPORTANT]
> sbt 2.x is, with [Gradle], one of the few _language package managers_ in this
> survey to ship a **content-addressed, `REAPI`-compatible task cache** — a
> capability [Cargo], [go-work], and [`dub`][d-landscape] lack entirely (Cargo
> punts remote caching to `sccache`). The 1.x reality, however, is closer to
> Cargo's: local incremental compilation plus a per-machine dependency cache, no
> shared task cache.

### CLI / UX ergonomics

sbt's command boundary is the **scoped-key** axis, written with slash-delimited
**`ref / Config / intask / key`** syntax ([Scopes][scopes]). The project (`ref`)
axis is how you target one member of the monorepo:

| Command                          | Targets                                                  |
| -------------------------------- | -------------------------------------------------------- |
| `sbt test`                       | the current (root) project — aggregates to all members   |
| `sbt core/test`                  | run `test` **only** in the `core` subproject             |
| `sbt core/Test/compile`          | `core`'s `Test` configuration's `compile`                |
| `sbt root/compile`               | compile the root (and, via aggregation, members)         |
| `sbt "project core"` then `test` | switch the _current_ project to `core`, then bare `test` |
| `sbt ThisBuild/version`          | the build-wide `version` setting                         |

So the ergonomics are: **global broadcast** is the default (a bare `test` on the
aggregating root fans out); **targeted selection** is `subproj/task`
(`core/test`); **fine scoping** drills into configuration and task axes
(`core/Test/compile`). There is no `--filter` glob and no `--since` diff flag in
core; selection is by explicit project ID, or by `project`-switching the shell
session. Cross-building over Scala versions uses the `+` prefix (`+test` runs
across `crossScalaVersions`), and arbitrary multi-step pipelines are wired with
`addCommandAlias` — e.g. ZIO's `addCommandAlias("build", "; fmt; rootJVM/test")`
and `addCommandAlias("testJVM", ";coreTestsJVM/test;streamsTestsJVM/test;…")`.

**The interactive server + thin client.** Because build load (JVM spin-up + build
compile) is slow, sbt 1.4+ ships **`sbtn`**, a native thin client that keeps a
**server** daemon warm: _"the native thin client will run sbt (server) as a
daemon, which avoids the JVM spinup and loading time for the second call
onwards,"_ with command latency around 60 ms ([sbt 1.4 release notes][sbt14]).
The same server speaks **BSP** (Build Server Protocol) for IDEs — on start sbt
_"will create a file named `.bsp/sbt.json`"_ describing how to launch `sbt -bsp`.
`sbt --client compile` / `sbt --client shutdown` drive the client explicitly.

> [!NOTE]
> The interactive shell is itself a major ergonomic lever: most developers keep a
> single warm sbt session and issue `compile`, `core/test`, `~compile` (the `~`
> prefix re-runs on source change), and `project` switches against it, amortizing
> the heavy load cost across many commands — a workflow most other tools in this
> survey lack.

---

## Strengths

- **Multi-project is the native model.** A monorepo is the default shape, not a
  bolt-on: N `Project` values in one build, no separate workspace manifest.
- **Two precise edge types.** `aggregate` (broadcast, unordered, parallel) and
  `dependsOn` (classpath, ordered, type-checked sibling reference) cover both
  "do this everywhere" and "build the library first" cleanly.
- **Memoizing task DAG.** De-duplication + automatic parallelism + tag-based
  concurrency limits give a principled, contention-aware scheduler.
- **Best-in-class incremental compilation.** Zinc's name-hashing recompiles the
  minimal affected definition closure — far finer-grained than whole-unit
  fingerprints.
- **Full programmability.** The build is Scala: project lists, shared settings,
  and command aliases are ordinary code, foldable and abstractable.
- **sbt 2.x: automatic, content-addressed, `REAPI`-compatible caching** —
  local-disk and Bazel-compatible remote, embedded in the task macro.
- **Warm server + thin client (`sbtn`) + BSP** amortize JVM/load cost and
  integrate IDEs.

## Weaknesses

- **Slow, heavyweight build load.** The build definition is compiled Scala;
  cold start pays JVM spin-up plus build compilation. `sbtn` mitigates, doesn't
  eliminate.
- **Steep DSL learning curve.** Scopes (`ref / Config / intask / key`), the
  settings-vs-tasks split, `.value` macro semantics, and `aggregate` vs
  `dependsOn` are notoriously hard for newcomers.
- **No shared lockfile in 1.x.** Per-project `libraryDependencies` invite
  version drift across members; centralization is a manual convention
  (`Dependencies.scala`, BOMs, `dependencyOverrides`).
- **No glob membership, no `--since` affected detection.** Members are listed in
  code; there is no `members = ["libs/*"]` and no VCS-diff scoping in core.
- **Caching maturity is version-gated.** The automatic content-addressed cache
  is **sbt 2.x**, still in RC as of this writing; 1.x relies on Zinc + an
  experimental artifact-based remote cache.
- **Plugin ecosystem inconsistency.** Behavior is heavily plugin-driven
  (`sbt-assembly`, `sbt-scalajs`, `sbt-mdoc`, …); cross-plugin scope interactions
  are a recurring source of confusion.

## Key design decisions and trade-offs

| Decision                                              | Rationale                                                                | Trade-off                                                                         |
| ----------------------------------------------------- | ------------------------------------------------------------------------ | --------------------------------------------------------------------------------- |
| Build definition is a Scala DSL                       | Total expressiveness: compute project lists, share settings as functions | Cold load compiles Scala; slow start; steep learning curve                        |
| Two edge types: `aggregate` vs `dependsOn`            | Separate "broadcast a task" from "classpath + ordering"                  | Newcomers conflate them; aggregation is unordered, `dependsOn` is ordered         |
| Settings (load-time) vs tasks (run-time) as kinds     | Static config map + dynamic per-invocation DAG                           | Two mental models; `.value` macro semantics are subtle                            |
| Memoizing task DAG (`.value` = dependency edge)       | De-dup + auto-parallelism + customizability for free                     | Per-command graph only; not a persisted cross-run incremental graph (that's Zinc) |
| Zinc name-hashing incremental compile                 | Recompile the minimal affected definition closure, not whole units       | Per-project; no cross-monorepo affected-package/`--since` selection               |
| Per-project `libraryDependencies`, no 1.x lockfile    | Simple, Ivy/Coursier-cached; flexible per-module versions                | Version drift across members; reproducibility needs manual centralization         |
| Scope delegation via `ThisBuild` (not explicit marks) | DRY defaults without `field.workspace = true` ceremony                   | Implicit; debugging "where did this value come from" needs `inspect`              |
| Tag-based `concurrentRestrictions`                    | Bound CPU/Network/Disk contention, not just total parallelism            | Extra concept; defaults to one-per-core unless tuned                              |
| Caching manual in 1.x → automatic CAS in 2.x          | 2.x embeds content-addressed, `REAPI`-compatible cache in the task macro | The headline win is gated on sbt 2.x, still in RC; 1.x has no shared task cache   |
| Warm server + `sbtn` thin client + BSP                | Amortize heavy load cost; integrate IDEs over BSP                        | Adds a daemon lifecycle; stale-server confusion; `.bsp/` files to manage          |

---

## Sources

- [sbt/sbt][repo] — the build tool's source (Scala)
- [sbt/zinc][zinc] — the Scala incremental compiler (name-hashing analysis)
- [sbt/librarymanagement][lm] — the Ivy-backed dependency manager
- [The sbt Reference Manual (1.x)][refman] · [The Book of sbt (2.x)][book]
- [Multi-Project Builds][multiproject] — `lazy val Project`, `aggregate`,
  `dependsOn`, config-scoped `test->test;compile->compile`, `ThisBuild`,
  per-project `.sbt` merge, "no `project/*.scala` in sub-projects"
- [Multi project basics (2.x)][mpbook] — implicit aggregating root, "each
  subproject works like any other project"
- [Task graph][taskgraph] — settings-vs-tasks, `.value` as a dependency edge,
  "de-duplication, parallel processing, and customizability", DAG of happens-before
- [Parallel Execution][parallel] — `Tags`, `concurrentRestrictions`,
  `Tags.limit`/`Tags.limitAll`, `ConcurrentRestrictions` ↔ `CompletionService`
- [Scopes][scopes] — `ref / Config / intask / key` slash syntax, project-scoped
  CLI targeting, `ThisBuild`
- [Caching (The Book of sbt, 2.x)][caching] — automatic task-macro caching,
  machine-wide disk cache, CAS, Bazel-compatible gRPC `REAPI`, `Def.declareOutput`
- [Remote Caching (1.x)][remotecache] — `pushRemoteCache`/`pullRemoteCache`
- [Zinc-friendly code][zincblog] — name-hashing recompilation explanation
- [sbt 1.4 release notes][sbt14] — `sbtn` thin client, server daemon, BSP support
- A real multi-project build for cross-reference: ZIO's `build.sbt` and
  `project/plugins.sbt` (local checkout) — `addCommandAlias`, `lazy val
projectsCommon = List(...)`, `aggregate`, cross-build `+` commands
- Related deep-dives: [Maven] · [Gradle] · [Mill] · [Cargo] · [go-work] ·
  [pnpm] · [yarn-berry] · [bazel] · [buildbuddy] · [nativelink] · [buildbarn] ·
  [`dub` (D)][d-landscape]

<!-- References -->

[repo]: https://github.com/sbt/sbt
[zinc]: https://github.com/sbt/zinc
[lm]: https://github.com/sbt/librarymanagement
[refman]: https://www.scala-sbt.org/1.x/docs/
[book]: https://www.scala-sbt.org/2.x/docs/en/
[multiproject]: https://www.scala-sbt.org/1.x/docs/Multi-Project.html
[mpbook]: https://www.scala-sbt.org/2.x/docs/en/guide/multi-project-basics.html
[taskgraph]: https://www.scala-sbt.org/1.x/docs/Task-Graph.html
[parallel]: https://www.scala-sbt.org/1.x/docs/Parallel-Execution.html
[scopes]: https://www.scala-sbt.org/1.x/docs/Scopes.html
[caching]: https://www.scala-sbt.org/2.x/docs/en/concepts/caching.html
[remotecache]: https://www.scala-sbt.org/1.x/docs/Remote-Caching.html
[zincblog]: https://medium.com/virtuslab/zinc-sbt-friendly-code-bff0adc6b007
[sbt14]: https://www.scala-sbt.org/1.x/docs/sbt-1.4-Release-Notes.html
[ivy]: https://ant.apache.org/ivy/
[reapi]: https://github.com/bazelbuild/remote-apis
[coursier]: https://get-coursier.io/
[maven]: ../maven/
[gradle]: ../gradle/
[mill]: ../mill/
[cargo]: ../cargo/
[go-work]: ../go-work/
[pnpm]: ../pnpm/
[yarn-berry]: ../yarn-berry/
[bazel]: ../bazel/
[buildbuddy]: ../buildbuddy/
[nativelink]: ../nativelink/
[buildbarn]: ../buildbarn/
[d-landscape]: ../../async-io/d-landscape.md
