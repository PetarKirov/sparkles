# Gradle (JVM)

A general-purpose, JVM-hosted build automation tool whose **multi-project build**
(one `settings.gradle(.kts)` declaring many subprojects sharing a build) and
**composite build** (`includeBuild` stitching whole builds together) form a
two-tier monorepo model, scheduled as a cross-project task **DAG** and accelerated
by an input-fingerprinting incremental engine plus a local/remote **build cache** —
the most caching- and remote-execution-mature data point in this survey short of
the polyglot engines.

| Field           | Value                                                                                                                                               |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language        | Java/Groovy/Kotlin (the tool runs on the JVM; build scripts are Groovy `build.gradle` or Kotlin `build.gradle.kts`)                                 |
| License         | Apache-2.0                                                                                                                                          |
| Repository      | [gradle/gradle][repo]                                                                                                                               |
| Documentation   | [Gradle User Manual][manual]                                                                                                                        |
| Category        | Language Package Manager / Build System                                                                                                             |
| Workspace model | Two tiers: **multi-project build** (root `settings.gradle(.kts)` + `include`d subprojects) and **composite build** (`includeBuild` of whole builds) |
| First released  | `0.1` on April 21, 2008 (conceived 2007 by Hans Dockter; Adam Murdoch co-developed early on)                                                        |
| Latest release  | `9.5.1` (patch for `9.5.0`, released May 14, 2026)                                                                                                  |

> **Latest release:** As of June 5, 2026 the current stable is **Gradle `9.5.1`**,
> the first patch release for `9.5.0` (2026-05-14). The 9.x line (since `9.0.0`)
> made the **configuration cache** and a Kotlin-first DSL the default-recommended
> path. Source citations below are against the current User Manual
> (`docs.gradle.org/current`) and the [`gradle/gradle`][repo] tree.

---

## Overview

### What it solves

Gradle is a **general-purpose build tool**, not a language-specific package
manager: it models a build as a graph of _tasks_ (compile, test, jar, lint,
codegen, …) over a tree of _projects_, and it resolves Maven/Ivy-format
dependencies as one of those tasks' inputs. Where [Cargo][cargo] couples
resolution + build + workspace into one Rust-only tool, Gradle separates the
concerns: a **project** is a unit of build configuration (one `build.gradle(.kts)`),
a **task** is a unit of work with declared inputs/outputs, and dependency
resolution is a service tasks consume. This generality is why it builds Android,
Spring, Kotlin Multiplatform, and large polyglot JVM monorepos from one model.

For monorepos Gradle offers **two nested topologies**:

1.  A **multi-project build** — one root with a single `settings.gradle(.kts)`
    that `include`s many subprojects. _"A multi-project build consists of a root
    project and one or more subprojects, all defined in a single
    `settings.gradle(.kts)` file"_ ([Structuring Multi-Project Builds][multi]).
    Subprojects depend on each other via `project(":lib")`, sharing one build
    invocation, one task DAG, one cache.
2.  A **composite build** — _"a build that includes other builds; those builds are
    known as included builds"_ ([Composite Builds][composite]). `includeBuild`
    wires together repositories that each have their own `settings.gradle(.kts)`,
    substituting published-artifact dependencies with the local source build.

The first is the everyday monorepo unit; the second is the multi-repo / "work on a
library and its consumer simultaneously" unit. Both feed the same scheduler.

### Design philosophy

Gradle's structuring guidance is unusually explicit that **many small projects are
the intended scale**, because that is what unlocks parallelism and incremental
work-avoidance. From the [Best Practices for Structuring Builds][best-structuring]:

> _"Expanding a build to hundreds of projects is common, and Gradle is designed to
> scale to this size and beyond. … you should typically err on the side of adding
> more projects rather than fewer"_ — with the caveat that _"in the extreme, tiny
> projects containing only a class or two are probably counterproductive."_

Three load-bearing decisions follow, all observable in the docs and the model:

1.  **Configuration is code, executed in phases.** A build runs in three phases —
    _initialization_ ("detects projects and included builds"), _configuration_
    ("configures projects and builds a task graph"), and _execution_ ("schedules
    and executes the selected tasks") ([Build Lifecycle][lifecycle]). The
    `settings.gradle(.kts)` file _is_ the topology declaration, evaluated in
    initialization.
2.  **Everything is a task with declared inputs and outputs.** Incrementality,
    caching, and the DAG all derive from tasks honestly declaring `@InputFiles` /
    `@OutputDirectory`. Gradle _"takes a fingerprint of the inputs … the paths of
    input files and a hash of the contents of each file"_ ([Incremental
    Build][incremental]) and skips a task whose fingerprint is unchanged.
3.  **Caching is a first-class, sharable artifact.** Unlike [Cargo][cargo]'s
    machine-local `target/`, Gradle's build cache _"can be reused between builds on
    one computer or even between builds running on different computers via a build
    cache"_ ([Build Cache][buildcache]) — the local `DirectoryBuildCache` and a
    remote `HttpBuildCache` (typically Develocity) are the same mechanism at two
    scopes.

Within this survey Gradle is the canonical **general-purpose JVM build engine**:
contrast it with [Maven][maven]'s convention-over-configuration reactor, with
[sbt][sbt]/[Mill][mill]'s Scala-native task models, with [Cargo][cargo]'s
language-coupled workspace, and with the polyglot engines [Bazel][bazel] /
[Buck2][buck2] / [Pants][pants] whose hermetic, content-addressed remote execution
Gradle approximates (but does not fully match — see [Caching](#caching--remote-execution)).
For the D analogue under improvement see [`dub`][d-landscape].

---

## How it works

A Gradle invocation proceeds through the three lifecycle phases: **initialize**
(evaluate `settings.gradle(.kts)`, discover projects + included builds) →
**configure** (evaluate every `build.gradle(.kts)`, build the cross-project task
DAG) → **execute** (schedule the selected tasks honoring the DAG, skipping
up-to-date / cache-hit tasks). The five dimensions below trace each stage.

### Workspace declaration & topology

The declaration surface is the **settings file**. During initialization _"Gradle
first runs any init scripts, then evaluates the settings file,
`settings.gradle(.kts)`, and instantiates a `Settings` object"_
([Build Lifecycle][lifecycle]). Two methods on `Settings` build the topology:

**`include` — multi-project build.** Subprojects are named explicitly; there is no
glob:

```kotlin
// settings.gradle.kts (multi-project root)
rootProject.name = "my-monorepo"
include("app", "core", "util")
include("services:api", "services:worker")   // ':' is a path; maps to services/api
```

> _"By default, a project path corresponds to the relative physical location of the
> project directory. For example, the path `services:api` maps to the directory
> `./services/api`, relative to the root project."_ ([Multi-Project Builds][multi])

A project dependency uses `project(":path")` in a member's `build.gradle(.kts)`:

```kotlin
// app/build.gradle.kts
dependencies {
    implementation(project(":core"))
    implementation(project(":util"))
}
```

> _"A project dependency affects both the build order and classpath: The required
> project will be built first … Its compiled classes and transitive dependencies
> are added to the consuming project's classpath."_ ([Multi-Project Builds][multi])

**`includeBuild` — composite build.** Whole builds (each with its own settings
file) are stitched together by path:

```kotlin
// settings.gradle.kts (composite root)
includeBuild("../my-utils")     // a sibling repo that is itself a (multi-project) build
```

> [!NOTE]
> The two tiers compose: an included build can _itself_ be a multi-project build,
> and `Settings.includeBuild` can _"add subprojects and included builds
> simultaneously."_ The common monorepo pattern is one big multi-project build for
> the product, plus an `includeBuild("build-logic")` holding convention plugins —
> Gradle explicitly recommends putting build logic in _"an included build
> (typically named `build-logic`), **not** in `buildSrc`"_
> ([Best Practices][best-structuring]).

> [!WARNING]
> **There is no glob discovery.** Every subproject must be named in `include(...)`
> (commonly automated by a settings-script loop over directories, but that is user
> code, not a built-in `members = ["libs/*"]` array). This is the gap the `dub`
> proposal's glob-based virtual workspace targets — contrast [Cargo][cargo]'s
> `members = ["crates/*"]` and [pnpm][pnpm]'s `packages:` globs.

### Dependency handling & isolation

Gradle does **not** hoist or symlink a dependency store ([npm][npm]/[pnpm][pnpm]
style) — JVM dependencies are coordinates (`group:name:version`) resolved from
Maven/Ivy repositories into a per-configuration classpath, cached in the Gradle
User Home. Cross-member references work differently in each tier:

1.  **Within a multi-project build — `project(":path")`.** A direct, source-level
    edge in the build graph. The depended-on project is compiled once and its
    output reused; no publishing, no version, no path-to-artifact round-trip. This
    is Gradle's equivalent of a `workspace:` local reference.

2.  **Across a composite build — automatic dependency substitution.** This is the
    headline isolation feature. An included build advertises its `group:name`
    coordinates; when a consumer declares a normal external dependency on those
    coordinates, _"Gradle replaces the external dependency with a project
    dependency at execution time"_ ([Composite Builds][composite]). So a consumer
    written as `implementation("org.sample:number-utils:1.0")` transparently builds
    against the local `../number-utils` source when that build is `includeBuild`-ed
    — no edits to the consumer. Substitution can be made explicit:

    ```kotlin
    // settings.gradle.kts
    includeBuild("anonymous-library") {
        dependencySubstitution {
            substitute(module("org.sample:number-utils")).using(project(":"))
        }
    }
    ```

    Key constraints, verbatim: included builds are _"configured in isolation"_ and
    _"do not share repositories, plugins, or properties"_; _"Substitutions are not
    transitive across builds"_; and you _"cannot use `project()` notation across
    build boundaries; external coordinates [are] required"_ ([Composite
    Builds][composite]).

3.  **Centralized versions — version catalogs + platforms.** A
    `gradle/libs.versions.toml` **version catalog** centralizes coordinate +
    version aliases consumed type-safely as `libs.serde`:

    ```toml
    # gradle/libs.versions.toml
    [versions]
    junit = "5.11.0"

    [libraries]
    junit-jupiter = { module = "org.junit.jupiter:junit-jupiter", version.ref = "junit" }

    [bundles]
    testing = ["junit-jupiter"]
    ```

    A catalog _"only influence[s] declared versions, not resolved versions"_; to
    force a single resolved version across the whole graph you add a **platform**
    (a set of dependency constraints whose _"versions … are propagated through the
    dependency graph, affecting transitive dependencies and downstream
    consumers"_). The `[workspace.dependencies]`/`[workspace.package]` role
    [Cargo][cargo] plays with one table, Gradle splits across **catalog**
    (DRY aliases) + **platform** (enforced resolution) + **dependency locking**
    (reproducible pins).

> [!NOTE]
> Isolation in Gradle is at the _resolution + classpath_ layer (one chosen version
> per configuration; per-included-build isolated config), not a per-package
> filesystem store. The composite-build _coordinate substitution_ is a distinctive
> contribution to this survey — it lets a multi-repo behave like a monorepo
> **without touching any consumer manifest**, unlike a relative `path=` rewrite.

### Task orchestration & scheduling

Gradle is, at heart, a **task DAG scheduler**, and the DAG spans all projects in
the build. From [Build Lifecycle][lifecycle]:

> _"Across all projects in the build, tasks form a Directed Acyclic Graph (DAG). …
> Gradle builds the task graph **before** executing any task(s)."_

The graph is assembled in the configuration phase by _"analyzing the input and
output dependencies of tasks"_ plus explicit `dependsOn` edges; declaring
`assemble.dependsOn(build)` and `createDocs.dependsOn(assemble)` yields the order
`build → assemble → createDocs`. Because the order is derived from edges, **legs
that don't depend on each other run concurrently**: _"Gradle can execute tasks
that don't depend on each other, in the same project, in parallel"_
([Build Lifecycle][lifecycle]), and `--parallel` extends that across projects.

**Change detection is input fingerprinting**, the same mechanism as the cache key.
Before running a task, _"Gradle takes a new fingerprint of the inputs and outputs.
If the new fingerprints are the same as the previous fingerprints, Gradle assumes
that the outputs are up to date and skips the task"_ ([Incremental
Build][incremental]). Crucially Gradle _"considers the code of the task as part of
the inputs"_ — a changed plugin/task implementation invalidates downstream tasks.
The skipped state surfaces as `UP-TO-DATE` in the console:

```bash
$ gradle build
> Task :core:compileJava UP-TO-DATE
> Task :core:jar UP-TO-DATE
> Task :app:compileJava
> Task :app:test FROM-CACHE
```

This is **per-task affected-detection by hashing**, propagated through the DAG: a
changed input invalidates that task's fingerprint, which (being an input to its
dependents) invalidates them in turn. It is _not_ VCS-diff-based — there is no
built-in `--since <git-ref>` affected selection (cf. [Nx][nx] /
[Turborepo][turborepo]); the diff is computed in content space, not commit space.

The **configuration cache** (default-recommended since `9.0`) caches the _task
graph itself_, so warm builds _"skip[] the configuration phase entirely"_ and load
a _"snapshot of the task graph … the set of tasks to run, their configuration
details, dependency information"_ ([Configuration Cache][configcache]). It is keyed
on build-configuration inputs — init/build/settings scripts, version catalogs,
lockfiles, `gradle.properties`, and any files/env read at configuration time —
and it additionally _enables stronger parallelism_: with it on, _"even tasks within
the same project can be run in parallel, subject to dependency constraints."_

### Caching & remote execution

This is Gradle's standout dimension relative to the language-native package
managers. The **build cache** stores _task outputs_ keyed by a build-cache key,
and exists at two scopes ([Build Cache][buildcache]):

| Scope      | Implementation        | Behavior                                                                                  |
| ---------- | --------------------- | ----------------------------------------------------------------------------------------- |
| **Local**  | `DirectoryBuildCache` | A directory in Gradle User Home; _"pre-configured … and enabled by default"_ for storage. |
| **Remote** | `HttpBuildCache`      | _"provides the ability [to] read to and write from a remote cache via HTTP."_             |

Enable both with `org.gradle.caching=true` in `gradle.properties`; _"when both
remote and local caches are enabled, then the build output is first checked in the
local cache"_, falling through to remote on a miss. A cache-restored task prints
`FROM-CACHE` (distinct from `UP-TO-DATE`, which is local incremental skip without a
cache fetch). The build-cache key is computed from the same task-input fingerprint
plus _"the task type and its classpath"_, the values of `@Input`-annotated
properties, and _"the classpath of the Gradle distribution, `buildSrc` and
plugins"_ ([Build Cache][buildcache]).

The canonical deployment is **CI populates, developers consume**: an
organization-wide remote cache _"populated regularly by continuous integration
builds"_, where _"developers … load cache entries from the remote build cache"_ but
are typically not permitted to write to it ([Build Cache][buildcache]). The
recommended remote backend is **Develocity** (formerly Gradle Enterprise):
_"Develocity includes a high-performance, easy to install and operate, shared build
cache backend."_

```kotlin
// settings.gradle.kts — wiring a remote cache
buildCache {
    local { isEnabled = true }
    remote<HttpBuildCache> {
        url = uri("https://cache.example.com/cache/")
        isPush = System.getenv("CI") == "true"   // only CI writes
    }
}
```

> [!IMPORTANT]
> Gradle's caching is **content-keyed and sharable across machines** — a real
> distinction from [Cargo][cargo]'s mtime-based, machine-local `target/`. But it is
> **caching, not remote _execution_**: Gradle does not ship a [REAPI][reapi]
> sandboxed-action backend that runs the work on a remote farm (cf. [Bazel][bazel],
> [Buck2][buck2], and the [NativeLink][nativelink] / [Buildbarn][buildbarn]
> backends). Cache correctness also depends on tasks honestly and completely
> declaring inputs/outputs; under-declared inputs cause cache poisoning — the price
> of Gradle's non-hermetic, configuration-as-code generality.

### CLI / UX ergonomics

Gradle's command boundary is **task paths**, not package-selection flags. A task
is addressed by a colon-separated path mirroring the project tree
([Command-Line Interface][cli]):

| Invocation                   | Selects                                                                                            |
| ---------------------------- | -------------------------------------------------------------------------------------------------- |
| `gradle :app:test`           | the `test` task in subproject `:app` only                                                          |
| `gradle :services:api:build` | the `build` task in the nested `:services:api` subproject                                          |
| `gradle test`                | _"a task selector that consists of only the task name"_ → `test` in **every** project that has one |
| `gradle build --parallel`    | build, running independent projects' tasks concurrently                                            |

So the "global broadcast vs. targeted" axis maps to **bare name vs. qualified
path**: a bare `gradle test` is the broadcast (run `test` across all subprojects),
while `:app:test` is the targeted form. There is no `-p <package>` /
`--filter <glob>` package selector in the [Cargo][cargo]/[pnpm][pnpm] sense —
selection is by task path, and `-p, --project-dir` instead _"specifies the start
directory for Gradle"_ (a different meaning of `-p` from Cargo's `--package`).

Concurrency and resilience flags:

- `--parallel` (or `org.gradle.parallel=true`) — parallel _project_ execution;
  `--max-workers N` caps the worker pool (default = CPU count).
- `--configuration-cache` (or `org.gradle.configuration-cache=true`) — reuse the
  cached task graph; also unlocks intra-project task parallelism.
- `--continue` — _"Gradle executes every task in the build if all the dependencies
  for that task are completed without failure"_ (don't stop at the first failure).
- `--offline` — _"the build should operate without accessing network resources."_

> [!NOTE]
> Gradle has **no built-in topological `foreach` loop, no `--since <git-ref>`
> affected-package selection, and no glob `--filter`.** The DAG implicitly enforces
> topological order within a build (dependencies build first), and bare-name task
> broadcast covers "run X everywhere", but VCS-diff slicing and named-package
> filtering are left to wrappers / Develocity's predictive test selection. This is
> the same gap [Cargo][cargo] has and the opposite of [Nx][nx]'s `affected`-first
> CLI.

---

## Strengths

- **General-purpose by design.** Tasks-with-inputs/outputs model arbitrary work
  (codegen, lint, container builds, polyglot compilation), not just JVM compile —
  scales to Android, KMP, and mixed-language monorepos from one model.
- **Two complementary monorepo tiers.** `include` (one build, many projects) for
  the everyday monorepo; `includeBuild` (many builds, coordinate-substituted) for
  multi-repo "edit library + consumer together" without publishing.
- **Sharable, machine-portable build cache.** Local + remote (`HttpBuildCache` /
  Develocity), keyed by content fingerprints — reuse outputs across developers and
  CI, far beyond [Cargo][cargo]'s local `target/`.
- **Strong incremental engine.** Per-task input/output fingerprinting with
  `UP-TO-DATE` / `FROM-CACHE`, plus a **configuration cache** that skips
  configuration and unlocks intra-project parallelism.
- **Cross-project task DAG with real concurrency.** Independent legs run in
  parallel (`--parallel`, `--max-workers`); order derived from declared edges.
- **Centralized version management** via `libs.versions.toml` catalogs, platforms
  (enforced resolution), and dependency locking.
- **Massive ecosystem** — the de-facto build tool for Android and a huge JVM plugin
  marketplace.

## Weaknesses

- **No glob workspace discovery.** Every subproject must be enumerated in
  `include(...)`; there is no `members = ["libs/*"]` array (you script the loop
  yourself).
- **Caching ≠ remote execution.** No native [REAPI][reapi] sandboxed remote-action
  farm (cf. [Bazel][bazel]/[Buck2][buck2]/[NativeLink][nativelink]); cache
  correctness rests on honest, complete input/output declarations.
- **Configuration-as-code complexity.** Groovy/Kotlin build logic, plugin order,
  and the configuration phase are powerful but a steep learning curve; misconfigured
  inputs cause subtle cache misses or poisoning.
- **No `--since`/affected, no `--filter`, no topological `foreach`.** VCS-diff
  slicing and package globbing are delegated to wrappers / Develocity predictive
  test selection.
- **Composite-build sharp edges.** Included builds don't share repos/plugins/props,
  substitutions aren't transitive, no `project()` across build boundaries, and
  configuration-on-demand interacts poorly with composites.
- **JVM-centric startup/daemon overhead.** A long-lived daemon mitigates JVM warm-up
  but adds operational state and occasional daemon-incompatibility friction.

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                                       | Trade-off                                                                                 |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| General task-graph engine (not a language package manager) | Models any work (polyglot compile, codegen, containers) uniformly               | Heavier and more abstract than a language-coupled tool like [Cargo][cargo]                |
| Two tiers: `include` (projects) + `includeBuild` (builds)  | One build for the monorepo; composite builds for multi-repo + local source swap | Two models to learn; composite builds are isolated with non-obvious substitution rules    |
| Explicit `include(...)`, no glob members                   | Deterministic, code-driven topology in `settings.gradle(.kts)`                  | No `members = ["libs/*"]`; large trees script their own enumeration                       |
| Composite-build coordinate substitution                    | A consumer builds against local source with **no manifest edits**               | Not transitive across builds; isolated config; `project()` can't cross boundaries         |
| Input/output fingerprinting for incrementality + cache key | One mechanism drives both `UP-TO-DATE` skips and `FROM-CACHE` reuse             | Correctness hinges on complete input/output declarations; under-declaration poisons cache |
| Local + remote build cache (`HttpBuildCache` / Develocity) | Share task outputs across machines/CI — portable, content-keyed                 | Caching only, not remote _execution_; no [REAPI][reapi] action farm in core               |
| Configuration cache stores the task graph                  | Skip the configuration phase; unlock intra-project parallelism                  | Adds another cache to invalidate; some plugins are not configuration-cache compatible     |
| Task-path CLI (`:proj:task`) + bare-name broadcast         | Precise targeting and "run X everywhere" without extra flags                    | No `-p`/`--filter` package selection, no `--since` affected slicing, no `foreach`         |
| Catalog + platform + locking (split version management)    | Catalogs DRY the coordinates; platforms enforce resolution; locking pins        | Three concepts where [Cargo][cargo] uses one `[workspace.dependencies]` table             |

---

## Sources

- [gradle/gradle][repo] — the Gradle source repository (Apache-2.0)
- [Gradle User Manual][manual] — the documentation root for all quoted pages
- [Multi-Project / Structuring Multi-Project Builds][multi] — `settings.gradle(.kts)`,
  `include`, `project(":path")`, project-path-to-directory mapping
- [Composite Builds (Included Builds)][composite] — `includeBuild`, dependency
  substitution, isolation constraints
- [Build Lifecycle][lifecycle] — the three phases, the cross-project task **DAG**,
  graph-before-execution, intra-project parallelism
- [Incremental Build][incremental] — input fingerprinting, `@InputFiles`/`@OutputDirectory`,
  `UP-TO-DATE`
- [Build Cache][buildcache] — local `DirectoryBuildCache` vs remote `HttpBuildCache`,
  cache key, `FROM-CACHE`, CI-populates pattern, Develocity backend
- [Configuration Cache][configcache] — caching the task graph, configuration inputs,
  intra-project parallelism
- [Version Catalogs][catalogs] — `gradle/libs.versions.toml`, type-safe accessors,
  bundles
- [Command-Line Interface][cli] — task-path selection, bare-name broadcast,
  `--parallel`, `--max-workers`, `--continue`, `--offline`, `-p`
- [Best Practices for Structuring Builds][best-structuring] — "err on the side of
  adding more projects", `build-logic` over `buildSrc`
- Related deep-dives: [Maven][maven] · [sbt][sbt] · [Mill][mill] · [Cargo][cargo] ·
  [Bazel][bazel] · [Buck2][buck2] · [Pants][pants] · [Nx][nx] · [Turborepo][turborepo] ·
  [pnpm][pnpm] · [npm][npm] · [NativeLink][nativelink] · [Buildbarn][buildbarn] ·
  [`dub` (D)][d-landscape]

<!-- References -->

[repo]: https://github.com/gradle/gradle
[manual]: https://docs.gradle.org/current/userguide/userguide.html
[multi]: https://docs.gradle.org/current/userguide/multi_project_builds.html
[composite]: https://docs.gradle.org/current/userguide/composite_builds.html
[lifecycle]: https://docs.gradle.org/current/userguide/build_lifecycle.html
[incremental]: https://docs.gradle.org/current/userguide/incremental_build.html
[buildcache]: https://docs.gradle.org/current/userguide/build_cache.html
[configcache]: https://docs.gradle.org/current/userguide/configuration_cache.html
[catalogs]: https://docs.gradle.org/current/userguide/version_catalogs.html
[cli]: https://docs.gradle.org/current/userguide/command_line_interface.html
[best-structuring]: https://docs.gradle.org/current/userguide/best_practices_structuring_builds.html
[reapi]: https://github.com/bazelbuild/remote-apis
[maven]: ../maven/
[sbt]: ../sbt/
[mill]: ../mill/
[cargo]: ../cargo/
[bazel]: ../bazel/
[buck2]: ../buck2/
[pants]: ../pants/
[nx]: ../nx/
[turborepo]: ../turborepo/
[pnpm]: ../pnpm/
[npm]: ../npm/
[nativelink]: ../nativelink/
[buildbarn]: ../buildbarn/
[d-landscape]: ../../async-io/d-landscape.md
