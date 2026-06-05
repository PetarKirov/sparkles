# Maven (JVM)

Apache Maven is the JVM ecosystem's canonical declarative, convention-over-configuration build tool, whose **multi-module reactor** — a root aggregator `pom.xml` that globs child modules, topologically sorts them by inter-module dependency, and builds them in one pass with intra-build artifact resolution — is the original "language build system that is also a monorepo engine," predating `Cargo`'s `[workspace]` by a decade.

| Field           | Value                                                                                                                |
| --------------- | -------------------------------------------------------------------------------------------------------------------- |
| Language        | Java (the tool is written in Java; manifests are XML `pom.xml`)                                                      |
| License         | Apache License 2.0                                                                                                   |
| Repository      | [apache/maven][repo]                                                                                                 |
| Documentation   | [maven.apache.org][docs] · [POM Reference][pomref] · [Guide to Working with Multiple Modules][multimod]              |
| Category        | Language Package Manager / Build System                                                                              |
| Workspace model | Aggregator (root-package) `pom.xml` listing `<modules>` (Maven 4: `<subprojects>`); the build graph is the "reactor" |
| First released  | Maven 1.0 (July 2004); Maven 2.0 (Oct 2005) introduced the reactor and the transitive dependency model               |
| Latest release  | Maven 3.9.16 (stable); Maven 4.0.0-rc-5 (pre-GA)                                                                     |

> **Latest release:** As of June 5, 2026 the latest **stable GA** line is the
> 3.9.x series — **Maven 3.9.16** (released 2026-05-13). **Maven 4.0.0** is still
> in release-candidate phase (**4.0.0-rc-5**, 2025-11-13; the project's stance is
> _"Maven 4.0.0 will be there when it's there"_). Source citations below are
> against the Maven 4 development tree on `master` (the root [`pom.xml`][repo]
> self-reports parent version `48`), which carries the new `<subprojects>`
> element and the `4.1.0` POM model namespace. Where a mechanic differs between
> Maven 3 and Maven 4 the text says so. See [Version gating](#workspace-declaration--topology).

---

## Overview

### What it solves

A Maven project is described by a single XML manifest, the **Project Object
Model** (`pom.xml`), identified by a `groupId:artifactId:version` (**GAV**)
coordinate. Maven's thesis is _convention over configuration_: a project that
follows the standard directory layout (`src/main/java`, `src/test/java`,
`target/`) and binds to the standard **build lifecycle** (`validate → compile →
test → package → verify → install → deploy`) needs almost no build script — just
declarations. Dependencies are GAV coordinates resolved transitively from remote
repositories (Maven Central and mirrors) into the per-user **local repository**
(`~/.m2/repository`), which doubles as a content cache.

The monorepo story is the **multi-module project** (a "reactor" build). A
_parent_ or _aggregator_ `pom.xml` with `<packaging>pom</packaging>` lists child
modules; running `mvn` at the root collects every module's POM, builds a single
dependency graph across them, sorts it topologically, and executes the requested
lifecycle phase against each module in order — resolving one module's output as
another module's dependency **without** going through a remote repository or even
`install` (see [`ReactorReader`](#dependency-handling--isolation)). One command,
many co-versioned artifacts, one consistent dependency resolution.

From the multi-module guide ([guide-multiple-modules][multimod]):

> _"The mechanism in Maven that handles multi-module builds is referred to as the
> reactor. … The reactor sorts all the projects so that any project is built
> before it is required."_

### Design philosophy

Maven's monorepo model rests on a handful of load-bearing decisions, all visible
in the source tree:

1. **The POM is data, not a program.** Unlike `Gradle`'s imperative Groovy/Kotlin
   DSL ([see the Gradle deep-dive][gradle]), a `pom.xml` is pure declarative XML.
   Build behavior comes from **plugins** bound to lifecycle phases, configured by
   data. This makes the build graph statically analyzable but extension verbose.
2. **Inheritance and aggregation are orthogonal.** A `<parent>` element gives a
   module _inheritance_ (shared `groupId`/`version`, `<dependencyManagement>`,
   `<pluginManagement>`, `<properties>`); a `<modules>` list gives a POM
   _aggregation_ (it triggers a reactor build of its children). A POM can do
   both, either, or neither — they are independent axes, a frequent source of
   confusion for newcomers.
3. **One coordinate space.** Every module is a first-class artifact with a GAV.
   There is no separate "local path" concept — a sibling module is referenced by
   the _same_ `<dependency>` GAV you would use for a third-party library; the
   reactor simply intercepts resolution when the GAV matches a module in the
   current build. This is the deepest difference from `Cargo`'s explicit
   `path = "../foo"` ([see Cargo][cargo]) and Yarn's `workspace:` protocol
   ([see Yarn Berry][yarn-berry]).
4. **Determinism over speed (historically).** Core Maven has no input-hashing,
   no incremental build cache, and (pre-`-T`) no parallelism — every `mvn`
   invocation re-runs the bound plugins from scratch. Caching and daemons are
   bolt-ons ([`mvnd`][mvnd-repo], the [build-cache extension][buildcache]); this
   is the field Maven _most_ lags behind `Bazel`/`Turborepo`/`Nx`.

Maven sits in the same category as [`Gradle`][gradle], [`sbt`][sbt], and
[`Mill`][mill] (JVM build systems), and as a package manager alongside
[`Cargo`][cargo] and [`Go`][go-work]. Within this survey it is the **declarative-XML,
coordinate-driven, no-native-cache** data point.

---

## How it works

### The reactor: collect, sort, build

Running `mvn <phase>` at a multi-module root drives four stages inside
`maven-core`:

1. **Collection.** The `DefaultGraphBuilder`
   ([`graph/DefaultGraphBuilder.java`][graphbuilder]) reads the root POM, walks
   its `<modules>`/`<subprojects>` recursively, and builds a `MavenProject` for
   every reachable POM (the "reactor projects").
2. **Sorting.** The `ProjectSorter` ([`project/ProjectSorter.java`][sorter])
   turns those projects into a DAG and topologically sorts them.
3. **Slicing.** `trimProjectsToRequest` applies `--projects`/`--also-make`/
   `--resume-from` to prune the graph to the requested subset
   ([see Task Orchestration](#task-orchestration--scheduling)).
4. **Building.** A `Builder` (`SingleThreadedBuilder` or `MultiThreadedBuilder`)
   walks the sorted list, running the requested lifecycle phase against each
   module.

The sorter's own doc-comment is the clearest statement of the algorithm
([`ProjectSorter.java`][sorter]):

> _"collect all the vertices for the projects that we want to build. iterate
> through the deps of each project and if that dep is within the set of projects
> we want to build then add an edge, otherwise throw the edge away because that
> dependency is not within the set of projects we are trying to build. we assume
> a closed set. do a topo sort on the graph that remains."_

Edges come from **four** relationship kinds, not just `<dependency>` — the sorter
adds an edge for each `<dependency>`, `<parent>`, `<build><plugin>`, and
`<extension>` whose GAV resolves to another reactor module:

```java
// impl/maven-core/.../project/ProjectSorter.java (abridged)
for (Dependency dependency : project.getModel()...getDependencies()) {
    addEdge(projectMap, vertexMap, project, projectVertex,
            dependency.getGroupId(), dependency.getArtifactId(),
            dependency.getVersion(), false, false);
}
Parent parent = project.getModel()...getParent();
if (parent != null) { addEdge(..., parent.getGroupId(), ..., true, false); }
// ...and one addEdge per <plugin> and per <extension>
List<String> sortedProjectLabels = graph.visitAll();   // DFS topo sort
```

The topo sort itself is a depth-first walk with three-color cycle detection in
`Graph.visitAll` ([`project/Graph.java`][graph]): each vertex transitions
`VISITING → VISITED`; re-entering a `VISITING` vertex raises a
`CycleDetectedException`. A module GAV duplicated across the reactor raises
`DuplicateProjectException`. Local cross-references match on the **versionless
key** (`groupId:artifactId`) and then by exact version
(`ArtifactUtils.versionlessKey`), so a sibling at the build's own version is
wired automatically.

### POM inheritance and the effective model

Before sorting, each `pom.xml` is merged with its `<parent>` chain and the
built-in **super POM** to produce the **effective POM** (`mvn help:effective-pom`).
`<dependencyManagement>` in a parent (or imported **BOM**) pins versions and
scopes that children inherit _by declaration_ — a child writes
`<dependency><groupId>…</groupId><artifactId>…</artifactId></dependency>`
without a `<version>`, and the managed version applies. This is Maven's analogue
to `Cargo`'s `[workspace.dependencies]` registry, except it is achieved through
the parent/BOM inheritance mechanism rather than a dedicated workspace table.

### Lifecycle phases and plugin goals

Maven does not run "tasks"; it runs **phases**, and phases are bound to plugin
**goals**. `mvn package` runs every phase up to and including `package` for each
reactor module; whatever goals are bound to those phases (e.g.
`maven-compiler-plugin:compile`, `maven-surefire-plugin:test`,
`maven-jar-plugin:jar`) execute in order. This phase-graph is fixed and global,
which is why Maven is _declarative_: you choose a phase, not a task DAG.

---

## Workspace Declaration & Topology

**Explicit child lists, recursively aggregated — no globbing in core Maven.** A
multi-module workspace is declared by an aggregator POM:

```xml
<!-- root pom.xml (Maven 3 spelling) -->
<project>
    <modelVersion>4.0.0</modelVersion>
    <groupId>com.example</groupId>
    <artifactId>app-parent</artifactId>
    <version>1.0.0-SNAPSHOT</version>
    <packaging>pom</packaging>

    <modules>
        <module>libs/core</module>
        <module>libs/util</module>
        <module>apps/server</module>
    </modules>
</project>
```

Each `<module>` is a **relative path to a directory** containing a child
`pom.xml`, not a GAV. Aggregation is recursive: a listed module may itself be an
aggregator. The reactor is the transitive closure of `<modules>` from the POM you
invoke.

> [!NOTE]
> **Maven 4 renames `<modules>` to `<subprojects>`.** In the POM `4.1.0` model
> ([`maven.mdo`][mdo]) the `modules` field is `@Deprecated(since = "4.0.0")` and
> superseded by `subprojects`: _"The subprojects (formerly called modules) to
> build as a part of this project. Each subproject listed is a relative path to
> the directory containing the subproject."_ The "module" terminology collided
> with Java Platform Modules (JPMS), prompting the rename. The semantics are
> unchanged.

Notable topology properties:

- **No glob patterns.** Unlike `pnpm-workspace.yaml`'s `packages: ['libs/*']`
  ([see pnpm][pnpm]) or `Cargo`'s `members = ["crates/*"]`, core Maven requires
  every module path to be listed explicitly. (The community `flatten`/`tiles`
  plugins and Maven 4's improvements ease some boilerplate, but enumeration is
  the norm.)
- **Parent ≠ aggregator.** The conventional layout puts a `<parent>` POM for
  _inheritance_ and an _aggregator_ POM for the `<modules>` list; they are often
  the same file but need not be. A child does not have to point its `<parent>` at
  the aggregator that lists it.
- **`.mvn/` directory** at the tree root holds `maven.config` (default CLI args),
  `extensions.xml` (core extensions like the build cache), and `jvm.config`,
  giving the workspace a root-anchored configuration surface
  ([handled in the CLI invoker][clivoker]).
- **Maven 4 subfolder awareness.** The reactor in Maven 4 is _"aware of subfolder
  builds,"_ so invoking `mvn` from inside a subproject directory builds the right
  slice without manually passing `-pl`.

---

## Dependency Handling & Isolation

**A shared, content-addressed local repository plus an in-build `WorkspaceReader`
for sibling modules.** Maven has no per-project `node_modules`, no symlink farm,
and no virtual store — there is one **local repository** (`~/.m2/repository`)
shared by every project on the machine, laid out by GAV path
(`<group>/<artifact>/<version>/<artifact>-<version>.jar`). Resolution is
transitive with **nearest-wins** conflict mediation (the version closest to the
root of the dependency tree wins, breaking ties by declaration order), tunable
via `<dependencyManagement>`, `<exclusions>`, and dependency `<scope>`.

The monorepo-critical piece is the **reactor reader**. When a reactor module
depends (by GAV) on another module in the same build, resolution is intercepted
by `ReactorReader` — a `MavenWorkspaceReader` — _before_ it ever consults the
local repository or the network. Its own class doc ([`ReactorReader.java`][reactorreader]):

> _"An implementation of a workspace reader that knows how to search the Maven
> reactor for artifacts, either as packaged jar if it has been built, or only
> compile output directory if packaging hasn't happened yet."_

So a downstream module consumes an upstream sibling's freshly-built `target/`
output (or its `target/classes` directory if `package` hasn't run) directly,
with no `install` round-trip to `~/.m2`. This is Maven's local-cross-reference
mechanism — and unlike `Cargo`/Yarn it is **coordinate-based, not path-based**:
the dependency is written as a normal GAV, and the reactor decides at build time
whether to satisfy it locally or remotely.

> [!WARNING]
> **Outside a reactor build, sibling modules must be `install`ed.** If you build a
> single module standalone (not via the aggregator), `ReactorReader` is not in
> play, so its sibling dependencies must already exist in `~/.m2` — the classic
> _"mvn install the whole thing first"_ workflow. There is no isolation between
> projects sharing `~/.m2`: two checkouts of the same `…-SNAPSHOT` GAV will clobber
> each other in the local repository, a real footgun the build cache and per-build
> `project-local-repo` partially mitigate.

There is **no lockfile** in core Maven. Reproducibility relies on pinned versions
(version _ranges_ are discouraged), `<dependencyManagement>`/BOM pinning, and
repository immutability — a sharp contrast to `Cargo.lock` ([Cargo][cargo]) or
`pnpm-lock.yaml` ([pnpm][pnpm]). (The `maven-lockfile` and reproducible-build
plugins exist as third-party add-ons.)

---

## Task Orchestration & Scheduling

**A topologically-sorted DAG with optional thread-level parallelism — but no
input-hashing or affected-detection in core.** The reactor _is_ a build DAG: the
`ProjectSorter` produces a total order consistent with the module dependency
graph, and the chosen `Builder` executes it.

### Concurrency

Single-threaded by default. `-T <n>` (`--threads`) switches to the
`MultiThreadedBuilder`, which builds in **weave mode** — phase-by-phase across
modules rather than module-by-module — using a thread pool sized to
`min(degreeOfConcurrency, numberOfProjects)` ([`MultiThreadedBuilder.java`][mtbuilder]):

> _"Builds the full lifecycle in weave-mode (phase by phase as opposed to
> project-by-project). This builder uses a number of threads equal to the minimum
> of the degree of concurrency (… set with `-T` on the command-line) and the
> number of projects to build."_

A `ConcurrencyDependencyGraph` tracks which modules have all upstream
dependencies satisfied and are therefore eligible to start, dispatching them to
the pool as soon as their prerequisites complete (independent legs of the DAG run
concurrently). The thread count accepts a core multiplier: `-T 1C` = one thread
per core, `-T 2.5C` = 2.5× cores. The [`Takari` smart builder][mvnd-repo] (and
`mvnd`, below) push this further with dependency-path-aware scheduling that
_"aggressively built along a dependency-path in topological order as upstream
dependencies have been satisfied."_

### Change detection

**Core Maven has none.** Every invocation re-executes the bound plugins from
scratch; there is no input fingerprinting, no "skip unchanged module," no
git-diff–based affected-set computation. Maven 4 adds **build resumption** —
`--resume`/`-r` records successfully-built subprojects in a `resume.properties`
file so a failed build can restart from the failure point — but that is failure
recovery, not change-driven skipping. True incrementality requires the
[build-cache extension](#caching--remote-execution). This is Maven's single
largest gap versus [`Turborepo`][turborepo]/[`Nx`][nx]/[`Bazel`][bazel], whose
content-hashed task graphs skip unchanged work by design.

---

## Caching & Remote Execution

**Repository caching is built in; build/output caching and remote reuse are an
opt-in extension.** Two distinct "caches" must not be conflated:

1. **The local repository (`~/.m2/repository`)** caches _downloaded
   dependencies_. It is content-addressed by GAV and shared across all projects.
   This avoids re-downloading, but does nothing to avoid re-_compiling_.

2. **The [Apache Maven Build Cache Extension][buildcache]** (latest `1.2.3`)
   caches _build outputs_. Installed via `.mvn/extensions.xml`, it interposes on
   the reactor to hash each module's inputs and restore outputs when the hash
   matches. From its concepts doc ([`concepts.md`][buildcache-concepts]):

   > _"The build cache calculates a key from module inputs, stores outputs in the
   > cache, and transparently restores them later to the standard Maven core. The
   > cache associates each project state with a unique key … Projects with the
   > same key are up-to-date (not changed) and can be restored from the cache.
   > Projects that produce different keys are out-of-date (changed), and the cache
   > fully rebuilds them."_

   The key is computed with a **HashTree** over every configured source file,
   every dependency, and the effective POM including plugin parameters;
   _"Source code content fingerprinting is digest based, which is more reliable
   than the file timestamps used in tools like Make or Apache Ant."_ The default
   algorithm is **XX** (XXHash), a fast non-cryptographic hash. The local cache
   lives in a `build-cache` directory beside `~/.m2` and retains the last
   `maxLocalBuildsCached` (default `3`) records per project.

### Remote / distributed cache (REAPI-adjacent)

The build cache supports a **remote backend**, enabling cross-machine and CI
reuse. It is **not** a Bazel-style REAPI implementation — instead it rides Maven
Resolver / Wagon transports, so _"any technology supported by Maven Resolver will
suffice. In the simplest form, it could be any HTTP web server supporting get/put
operations"_ (Nexus raw repos, Artifactory generic repos, plain Nginx). The
extension's pitch is _"Deterministic inputs calculation allows distributed and
parallel builds running in heterogeneous environments (like a cloud of build
agents) to efficiently reuse cached build artifacts as soon as they are
published"_ — i.e. a content-addressed remote cache, but over artifact-repo
transports rather than the [Bazel Remote Execution API][bazel].

### The daemon: `mvnd`

[`mvnd`][mvnd-repo] (Apache Maven Daemon) attacks JVM/plugin warm-up rather than
caching outputs: a GraalVM-native client talks to a long-lived background JVM
that keeps plugin classloaders and JIT-compiled code hot across invocations, and
defaults to the `Takari` smart builder with parallelism
`max(availableProcessors() - 1, 1)`. It is the closest Maven analogue to
`Gradle`'s build daemon.

> [!NOTE]
> Neither `mvnd` nor the build cache is part of the core distribution. Out of the
> box, `mvn` re-runs everything, single-threaded, every time — the baseline that
> the proposed `dub` workspace feature should aim to _exceed_, not merely match.

---

## CLI / UX Ergonomics

**Targeted flags on a single `mvn` (or `mvnd`) binary; phase as verb, module
selection as flags.** A Maven command is `mvn [options] <phase…>` — the verb is a
lifecycle phase (`compile`, `test`, `package`, `install`, `verify`, `deploy`) or
a fully-qualified `plugin:goal`. Reactor scope is controlled by flags, all defined
in `CommonsCliMavenOptions` ([source][cliopts]):

| Flag (long)                      | Short        | Meaning                                                                                            |
| -------------------------------- | ------------ | -------------------------------------------------------------------------------------------------- |
| `--projects <list>`              | `-pl`        | Build only listed modules; `[groupId]:artifactId` or relative path; `!`/`-` excludes, `?` optional |
| `--also-make`                    | `-am`        | Also build the upstream modules the selected list **depends on**                                   |
| `--also-make-dependents`         | `-amd`       | Also build the downstream modules that **depend on** the selected list                             |
| `--resume-from <project>`        | `-rf`        | Resume the reactor from the named module (skip everything before it)                               |
| `--resume`                       | `-r`         | _(Maven 4)_ Resume from the last failed module, via `resume.properties`                            |
| `--threads <n>`                  | `-T`         | Parallelism: `4`, `1C` (per core), `2.5C` (core multiplier)                                        |
| `--non-recursive`                | `-N`         | Build only the POM in the current dir, **not** its `<modules>`                                     |
| `--fail-at-end` / `--fail-never` | `-fae`/`-fn` | Keep building independent modules after a failure (vs default fail-fast)                           |
| `--offline`                      | `-o`         | Resolve only from `~/.m2`; never hit the network                                                   |

The `-pl … -am`/`-amd` combination is exactly the **upstream/downstream graph
slicing** other tools expose as `--filter ...^` / `...` (Turborepo) or
`-p`/`--recursive` (Yarn): `includeAlsoMakeTransitively` walks
`graph.getUpstreamProjects(p, true)` and/or `graph.getDownstreamProjects(p, true)`
to expand the selection, then re-sorts in reactor order ([`DefaultGraphBuilder.java`][graphbuilder]):

```java
// includeAlsoMakeTransitively (abridged)
boolean makeUpstream   = makeBoth || REACTOR_MAKE_UPSTREAM.equals(makeBehavior);
boolean makeDownstream = makeBoth || REACTOR_MAKE_DOWNSTREAM.equals(makeBehavior);
for (MavenProject project : projects) {
    if (makeUpstream)   projectsSet.addAll(graph.getUpstreamProjects(project, true));
    if (makeDownstream) projectsSet.addAll(graph.getDownstreamProjects(project, true));
}
result.sort(comparing(sortedProjects::indexOf));   // keep reactor order
```

Ergonomic observations:

- **No `--since <git-ref>` in core.** There is no built-in affected-by-VCS-diff
  selection à la Yarn's `--since` or Nx's `affected`; you compute the changed
  module set yourself and feed it to `-pl` (or use a third-party plugin/CI glue).
  This is precisely the Milestone-4 capability the `dub` proposal targets.
- **Module identity in `-pl` is flexible** — accepting GAV, `:artifactId`, or
  relative path — which is friendlier than tools that demand the package name.
- **The verb is a phase, not a task.** You cannot ask Maven to "run target X on
  module Y"; you ask it to run a _phase_ (and whatever goals are bound to it).
  This keeps the CLI tiny but means the build's behavior lives in the POM's plugin
  bindings, not on the command line.

---

## Strengths

- **Battle-tested reactor.** Two decades of production use; the topological
  multi-module build is stable, predictable, and universally understood across the
  JVM ecosystem.
- **Coordinate-based local refs need zero extra config.** A sibling module is just
  a GAV `<dependency>`; the reactor wires it automatically — no `path=`, no
  `workspace:` protocol, no symlinks.
- **Declarative, statically analyzable POMs.** Tooling (IDEs, dependency
  scanners, SBOM generators) can read the build graph without executing arbitrary
  code, unlike imperative DSL build scripts.
- **Inheritance + BOM is a powerful version-convergence tool.**
  `<dependencyManagement>` and importable BOMs eliminate version drift across many
  modules through a single managed table.
- **Mature ecosystem.** Maven Central, a vast plugin catalog, and first-class IDE
  support are unmatched in breadth.
- **Optional speed layers exist.** `-T` parallelism, `mvnd`, the `Takari` smart
  builder, and the build-cache extension can be added incrementally without
  changing POMs much.

## Weaknesses

- **No native build cache or incrementality.** Core `mvn` re-runs everything every
  time; skip-unchanged requires the opt-in extension. This is the central gap
  versus [`Bazel`][bazel], [`Turborepo`][turborepo], and [`Nx`][nx].
- **No lockfile.** Reproducibility depends on disciplined version pinning and
  repository immutability; there is no `Cargo.lock`/`pnpm-lock.yaml` equivalent in
  core.
- **No glob module discovery.** Every `<module>`/`<subproject>` must be enumerated
  explicitly; large monorepos accumulate long, hand-maintained lists.
- **Shared, unisolated `~/.m2`.** All projects share one local repository;
  concurrent `…-SNAPSHOT` builds can clobber each other.
- **XML verbosity and plugin indirection.** Behavior is spread across
  parent POMs, `<pluginManagement>`, and lifecycle bindings — hard to trace for
  newcomers; "where does this goal come from?" is a common question.
- **No VCS-aware affected selection.** No `--since <ref>`; computing the changed
  module set is left to the user or CI.
- **Phase-not-task model is rigid.** Custom ad-hoc task graphs don't fit the fixed
  lifecycle cleanly; you bind goals to phases instead.

## Key design decisions and trade-offs

| Decision                                                           | Rationale                                                                                  | Trade-off                                                                                        |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------ |
| Declarative XML POM, behavior via plugins bound to phases          | Statically analyzable; convention over configuration; no arbitrary code in the build graph | Verbose; behavior is indirected through plugin bindings; ad-hoc task graphs don't fit            |
| Coordinate-based (GAV) module references, not paths                | A sibling is just a dependency; reactor wires it with zero extra config                    | Requires a reactor build to short-circuit resolution; standalone builds need `mvn install` first |
| Explicit `<modules>`/`<subprojects>` lists, no globbing            | Deterministic, exact reactor membership                                                    | Long hand-maintained lists in big monorepos; no `crates/*`-style patterns                        |
| Single shared local repository (`~/.m2`), no lockfile              | One download cache for the whole machine; simple mental model                              | No per-project isolation; SNAPSHOT clobbering; reproducibility relies on version discipline      |
| Topological reactor sort over deps+parent+plugins+extensions       | One correct build order across all relationship kinds                                      | Mixing relationship types in one DAG can surface false cycles (noted in `ProjectSorter` `FIXME`) |
| No core build cache / incrementality (extension is opt-in)         | Keeps core simple and deterministic; caching is a separable concern                        | Every `mvn` re-runs everything; speed depends on bolt-ons (`mvnd`, build-cache extension)        |
| Parallelism via `-T` weave-mode, off by default                    | Safe sequential default; opt into concurrency when the graph allows                        | Default builds are slow; weave-mode and smart builders are extra surface to learn                |
| Inheritance (`<dependencyManagement>`/BOM) for version convergence | Single managed table eliminates drift across modules                                       | Inheritance ≠ aggregation confusion; effective POM must be computed to see the real config       |

---

## Sources

- [apache/maven — source repository][repo] (all quoted Java paths are against the Maven 4 `master` tree)
- [`impl/maven-core/.../project/ProjectSorter.java`][sorter] — reactor topological sort, the four edge kinds
- [`impl/maven-core/.../project/Graph.java`][graph] — DFS topo sort + `VISITING`/`VISITED` cycle detection
- [`impl/maven-core/.../graph/DefaultGraphBuilder.java`][graphbuilder] — collection, slicing, `--also-make` upstream/downstream expansion
- [`impl/maven-core/.../ReactorReader.java`][reactorreader] — the in-build `MavenWorkspaceReader` for sibling artifacts
- [`impl/maven-core/.../builder/multithreaded/MultiThreadedBuilder.java`][mtbuilder] — `-T` weave-mode parallel builder
- [`impl/maven-cli/.../mvn/CommonsCliMavenOptions.java`][cliopts] — `-pl`/`-am`/`-amd`/`-rf`/`-T`/`-N` flag definitions
- [`api/maven-api-model/src/main/mdo/maven.mdo`][mdo] — POM model; `modules` → `subprojects` (Maven 4)
- [Maven — Guide to Working with Multiple Modules][multimod] — reactor definition and ordering
- [What's new in Maven 4?][whatsnew4] — `<subprojects>`, `--resume`, subfolder builds, POM `4.1.0`
- [Apache Maven Build Cache Extension][buildcache] · [concepts][buildcache-concepts] — input-hash cache, remote cache
- [apache/maven-mvnd][mvnd-repo] — the Maven daemon and `Takari` smart builder
- [POM Reference][pomref] · [Maven Releases History][docs]
- Sibling deep-dives: [Cargo][cargo] · [Gradle][gradle] · [sbt][sbt] · [Mill][mill] · [Go (`go.work`)][go-work] · [pnpm][pnpm] · [Yarn Berry][yarn-berry] · [Turborepo][turborepo] · [Nx][nx] · [Bazel][bazel]; D context in [the D async landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/apache/maven
[docs]: https://maven.apache.org/docs/history.html
[pomref]: https://maven.apache.org/pom.html
[multimod]: https://maven.apache.org/guides/mini/guide-multiple-modules.html
[whatsnew4]: https://maven.apache.org/whatsnewinmaven4.html
[sorter]: https://github.com/apache/maven/blob/master/impl/maven-core/src/main/java/org/apache/maven/project/ProjectSorter.java
[graph]: https://github.com/apache/maven/blob/master/impl/maven-core/src/main/java/org/apache/maven/project/Graph.java
[graphbuilder]: https://github.com/apache/maven/blob/master/impl/maven-core/src/main/java/org/apache/maven/graph/DefaultGraphBuilder.java
[reactorreader]: https://github.com/apache/maven/blob/master/impl/maven-core/src/main/java/org/apache/maven/ReactorReader.java
[mtbuilder]: https://github.com/apache/maven/blob/master/impl/maven-core/src/main/java/org/apache/maven/lifecycle/internal/builder/multithreaded/MultiThreadedBuilder.java
[cliopts]: https://github.com/apache/maven/blob/master/impl/maven-cli/src/main/java/org/apache/maven/cling/invoker/mvn/CommonsCliMavenOptions.java
[mdo]: https://github.com/apache/maven/blob/master/api/maven-api-model/src/main/mdo/maven.mdo
[clivoker]: https://github.com/apache/maven/blob/master/impl/maven-cli/src/main/java/org/apache/maven/cling/invoker/LookupInvoker.java
[buildcache]: https://maven.apache.org/extensions/maven-build-cache-extension/index.html
[buildcache-concepts]: https://github.com/apache/maven-build-cache-extension/blob/master/src/site/markdown/concepts.md
[mvnd-repo]: https://github.com/apache/maven-mvnd
[cargo]: ../cargo/
[gradle]: ../gradle/
[sbt]: ../sbt/
[mill]: ../mill/
[go-work]: ../go-work/
[pnpm]: ../pnpm/
[yarn-berry]: ../yarn-berry/
[turborepo]: ../turborepo/
[nx]: ../nx/
[bazel]: ../bazel/
[d-landscape]: ../../async-io/d-landscape.md
