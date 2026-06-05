# Dagger (Polyglot / CI)

A programmable, container-native automation engine: you write your CI/CD pipeline
as ordinary Go, Python, TypeScript, PHP, Java, or `.NET` code that calls Dagger's
GraphQL API, and a [BuildKit][buildkit]-based engine executes it as a
content-addressed DAG of containerized operations — cached automatically and
identically whether it runs on your laptop, in CI, or in the cloud.

| Field           | Value                                                                                                                                 |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Language        | Go (~80% of the engine); SDKs in Go, Python, TypeScript, PHP, Java, `.NET`, Elixir, Rust                                              |
| License         | Apache-2.0                                                                                                                            |
| Repository      | [`dagger/dagger`][repo]                                                                                                               |
| Documentation   | [docs.dagger.io][docs] · [Module configuration][modcfg] · [`dagger.json` schema][schema]                                              |
| Category        | Container / CI-Oriented                                                                                                               |
| Workspace model | **Module graph** — each component is a Dagger _module_ (`dagger.json`); composition is by module `dependencies`, not a workspace root |
| First released  | `v0.1.0`, early 2022 (weekly auto-releases began January 18, 2022)                                                                    |
| Latest release  | `v0.20.8` (May 6, 2026)                                                                                                               |

> **Latest release:** `v0.20.8`, published May 6, 2026. The `v0.13` line (Sep 2024)
> introduced what Dagger calls _"first-class monorepo support"_ — **context-directory
> access** and **pre-call filtering** ([Dagger 0.13 blog][blog013]); those two
> mechanisms, not a workspace manifest, are how Dagger addresses the monorepo
> problem. Recent `v0.20.x` releases focus on engine-side scaling (`dagger generate`
> no longer spikes to 30 GB+ RSS on large module graphs; long `withDirectory` chains
> no longer re-materialize at every step). See [Caching & remote execution](#caching--remote-execution).

> [!IMPORTANT]
> This is `dagger/dagger`, the CI/CD automation engine founded by the original
> Docker team — **not** Google's `google/dagger` dependency-injection framework for
> Java/Android, which is an unrelated project that shares the name.

---

## Overview

### What it solves

Dagger sits in a different category from every package-manager- and
build-system-centric tool in this survey ([Cargo][cargo], [pnpm][pnpm],
[Bazel][bazel], [Nx][nx]). It does not resolve library dependencies, install a
`node_modules`, or compile your code directly. It is a **CI/CD engine**: its job is
to make the _glue_ — "build the image, run the tests, push the artifact, deploy" —
reproducible, cacheable, and runnable on a developer laptop instead of only inside a
YAML-configured CI runner. Its README states the scope plainly:

> _"Automation engine to build, test and ship any codebase. Runs locally, in CI, or
> directly in the cloud."_ — [`dagger/dagger` README][repo]

The pain it targets is **YAML-pipeline drift**: a `.github/workflows/*.yml` or
`.gitlab-ci.yml` that only runs on the CI provider, can only be debugged by pushing
commits, re-runs the whole world on every change, and reimplements caching
ad-hoc per-job. Dagger replaces that with code that calls an API, plus an engine
that caches at the operation level.

### Design philosophy

The core insight is that a CI/CD pipeline should be a **regular program calling an
API**, executed as a **content-addressed DAG of containerized operations**. Every
operation — pulling an image, running a command, copying files — becomes a node in a
directed acyclic graph; the engine (a custom fork of [BuildKit][buildkit], the
solver behind `docker build`) executes that graph with automatic caching and
parallelism. The Dagger 0.13 announcement frames the monorepo angle of this:

> _"each logical component in your monorepo can get its own Dagger module, which
> cleanly encapsulates both the data and pipeline logic necessary to build, test and
> deploy it."_ — [Dagger 0.13: First-class monorepo support][blog013]

Three consequences flow from this and shape everything below:

1. **Pipelines are modules, not config.** A unit of automation is a _Dagger module_
   declared by a `dagger.json` and written in a real SDK language. Modules **compose
   by depending on each other** (`dagger install`), exactly as code libraries do —
   there is no separate "workspace manifest" concept.
2. **The DAG is content-addressed, so caching is automatic.** Because each node is
   keyed by its inputs (`call.ID` in the engine's GraphQL layer), changing one file
   re-runs only the affected nodes; everything else is replayed from cache. This is
   the same property that makes [Turborepo][turborepo] and [Bazel][bazel] fast,
   except here it is intrinsic to the execution substrate (BuildKit) rather than a
   bespoke task hasher.
3. **Local ≡ CI.** The engine runs as a container; the same module graph executes the
   same way on a laptop and in a CI runner, eliminating the "works on CI only"
   debugging loop.

Within this survey Dagger is the canonical **container/CI-oriented** data point;
compare it with the sibling tools [Earthly][earthly] (a `Dockerfile`-derived DSL with
explicit targets) and [Garden][garden] (Kubernetes-native stack orchestration), and
with the task-runner family ([Task][task], [Just][just], [mise][mise]) that Dagger
out-scopes by being containerized and cached. For why `dub` lacks any of this, see
the [D landscape notes][d-landscape].

---

## How it works

A Dagger program is a set of **Dagger Functions** — methods on a module's top-level
type — that the engine exposes through a dynamically generated GraphQL schema. You
invoke them with `dagger call`, chaining function outputs into the next call's
inputs with a pipe.

### The module: `dagger.json` + an SDK

`dagger init` scaffolds a module; `dagger develop --sdk=<lang>` generates the SDK
client code. The module's metadata lives in `dagger.json`:

```json
{
  "name": "ci",
  "engineVersion": "v0.20.8",
  "sdk": { "source": "go" },
  "source": "./dagger",
  "dependencies": [
    {
      "name": "hello",
      "source": "github.com/shykes/daggerverse/hello@54d86c6002d954167796e41886a47c47d95a626d"
    }
  ],
  "include": ["!**/testdata/large-fixtures"]
}
```

The fields ([Module configuration][modcfg], [`dagger.json` schema][schema]):

| Field           | Role                                                                                                 |
| --------------- | ---------------------------------------------------------------------------------------------------- |
| `name`          | Module identifier (defaults to the directory name)                                                   |
| `sdk`           | The SDK language — `go`, `python`, `typescript`, `php`, `java`, `.net`, …                            |
| `source`        | Path to the module's source subdirectory (commonly `./dagger`)                                       |
| `engineVersion` | Pins the Dagger API/engine version the module was written against                                    |
| `dependencies`  | Array of `{ name, source }` records — other modules this one calls                                   |
| `include`       | Extra include/exclude globs for **pre-call filtering** of the module's context directory (see below) |
| `blueprint`     | A template module a project inherits its automation from                                             |
| `clients`       | Generated-client configuration                                                                       |

Functions are ordinary methods. A Go example:

```go
// dagger/main.go
func (m *Ci) Test(
    // +ignore=["*", "!**/*.go", "!go.mod", "!go.sum"]
    source *dagger.Directory,
) *dagger.Container {
    return dag.Container().
        From("golang:1.24").
        WithMountedDirectory("/src", source).
        WithWorkdir("/src").
        WithExec([]string{"go", "test", "./..."})
}
```

### The engine: BuildKit, LLB, and DAGql

The pipeline code does not run the containers itself. It calls the **Dagger Engine**
— a daemon running a custom build of [BuildKit][buildkit] inside a container —
through a GraphQL API. The engine translates each high-level API call into BuildKit's
**Low-Level Build (LLB)** representation and lets BuildKit's solver execute it. The
GraphQL layer is Dagger's own server, **`dagql.Server`**, which supports dynamic
schema modification at runtime so that each installed module can register new types
and fields ([architecture overview][deepwiki-arch]).

The unit of content addressing is **`call.ID`** in `dagql`: every operation is keyed
by its inputs, and the engine distinguishes _handle IDs_ (runtime pointers) from
_recipe IDs_ (canonical semantic descriptions of an operation), using the latter to
decide what must re-execute. Container execution is **lazy**: `withExec` builds up
metadata (mounts, env, command), defers execution (`ContainerExecLazy`), and only
forces a solve when a result is actually read — so independent branches of the DAG
solve in parallel and unchanged branches are skipped entirely.

```bash
# A chained pipeline: build a container, add a package, drop into a terminal.
dagger -m github.com/dagger/dagger/modules/wolfi@v0.16.2 \
    call container --packages="cowsay" terminal
```

The five dimensions below analyze where this model lands relative to the rest of the
catalog.

### 1. Workspace declaration & topology

Dagger has **no workspace root manifest** in the sense [Cargo][cargo]'s `[workspace]`,
[`go.work`][go-work], or [pnpm][pnpm]'s `pnpm-workspace.yaml` have one. There is no
glob array enumerating members. Instead, **topology is the module dependency graph**:
each component is a module with its own `dagger.json`, and the monorepo's structure is
expressed by which modules `dagger install` which others. The docs describe the
recommended pattern ([Monorepos best practices][bp-monorepo]):

> _"create a top-level Dagger module for the monorepo, attach sub-modules for each
> component of the monorepo, and model the Dagger module dependencies on the logical
> dependencies between components."_

So the "workspace" is a tree of modules rooted at a top-level orchestrator module that
imports per-component sub-modules — discovery is **explicit, by dependency edge**, not
by directory globbing. An alternative the docs also endorse is a single _shared_
automation module that every project imports, which _"reduces code duplication and
ensures a consistent CI environment for all projects."_

**Discovery of the context** is by `dagger.json` location: for a Git repo the _context
directory_ is the repository root (for absolute paths) or the directory containing
`dagger.json` (for relative paths); outside Git it is the `dagger.json` directory. For
security, _"it is not possible to retrieve files or directories outside the context
directory"_ ([Directory filters][filters]).

> [!NOTE]
> Because there is no member-enumerating root, Dagger does not "know" your whole repo
> the way [Nx][nx] or [Bazel][bazel] do. It knows the module graph you wired by hand.
> A new component is integrated by giving it a module and `dagger install`-ing it into
> the parent — not by matching a `members = ["libs/*"]` glob.

### 2. Dependency handling & isolation

Two distinct dependency notions coexist, and it is important not to conflate them:

- **Module dependencies (Dagger's own).** `dagger install <ref>` adds another Dagger
  module so your code can call its functions. The reference grammar is
  `[proto://]host/repo[/subpath][@version]` ([Module dependencies][moddeps]); the
  `/subpath` segment is explicitly _"optional subdirectory for monorepos."_ An install
  writes a pinned record into `dagger.json`:

  ```json
  "dependencies": [
      {
          "name": "hello",
          "source": "github.com/shykes/daggerverse/hello@54d86c6002d954167796e41886a47c47d95a626d"
      }
  ]
  ```

  Remote refs pin to a **commit SHA** (resolved from a tag/branch at install time);
  the dependent module is _"added to the code-generation routines and can be accessed
  from your own module's code."_

- **Local cross-module references.** A module can depend on another module **in the
  same Git repository** by relative path:

  ```bash
  dagger install ./path/to/component
  ```

  This is the Dagger analogue of [Yarn][yarn-berry]'s `workspace:` protocol or a Cargo
  `path =` dependency — it lets sibling components reference each other without
  publishing. The constraint, per the docs, is that it _"is only possible if your
  module is within the repository root (for Git repositories)."_

**Isolation of language-level dependencies** (your app's `pip`/`npm`/`cargo`
packages) is handled by the container model, not by a symlink tree or virtual store:
each operation runs in its own container filesystem, and package downloads are kept
warm with **cache volumes** (next section). There is no hoisting and no shared
`node_modules`; isolation is the container boundary itself.

### 3. Task orchestration & scheduling

Orchestration is the strongest part of Dagger's design, and it is _structural_ rather
than declarative. There is no `turbo.json`-style task list with `dependsOn` rules
([Turborepo][turborepo]) and no `BUILD` target graph ([Bazel][bazel]). Instead:

- **The DAG is built implicitly from data flow.** Every API call (`From`,
  `WithMountedDirectory`, `WithExec`, …) is a node; an edge exists wherever one
  operation consumes another's output. The engine — BuildKit — _"executes this graph
  with automatic caching and parallelism."_ Independent legs run concurrently with no
  user annotation; the topological order falls out of the data dependencies.
- **Cross-component orchestration is code.** Because a top-level module imports
  sub-modules and calls their functions, _"the top-level module of a project can
  orchestrate the sub-modules using the language's native concurrency features"_
  ([Monorepos best practices][bp-monorepo]) — e.g. Go goroutines or Python
  `asyncio.gather`. Concurrency is whatever the SDK language offers, not a `--jobs N`
  flag.
- **Change detection is content hashing, not git-diff.** Dagger does not compute an
  "affected set" from a git ref the way [Turborepo][turborepo]'s `--affected` or
  [Nx][nx]'s `affected` do. Instead, **pre-call filtering** plus content-addressing
  achieves the same effect at the operation level: a directory is filtered _before_
  upload, so _"minor unrelated changes in the source directory don't invalidate
  Dagger's build cache"_, and only operations whose hashed inputs actually changed
  re-run. The 0.13 release pairs this with context-directory access so a function for
  one component only ever sees — and only re-runs on — that component's files.

> [!NOTE]
> The practical upshot for monorepos, per the docs: _"Even if unnecessary CI jobs are
> triggered, Dagger's layer cache allows most to finish almost instantly, as it
> quickly determines there's nothing to run."_ ([Monorepos best practices][bp-monorepo]).
> Affected-detection is emergent from caching rather than an explicit graph query.

### 4. Caching & remote execution

Caching is the engine's reason for existing, and it operates at two layers:

- **Operation / layer cache (automatic).** Every DAG vertex is content-addressed, so
  _"if you've already built a particular step with the same inputs, BuildKit skips it
  entirely,"_ caching at the operation level across the whole graph. This is the
  BuildKit layer cache, working _"automatically across local runs and CI."_ No
  configuration; it is intrinsic.
- **Cache volumes (explicit).** A **`CacheVolume`** (`dag.CacheVolume("go-mod")`,
  mounted via `WithMountedCache`) _"represents a directory whose contents persist
  across Dagger sessions."_ It is the idiomatic way to keep package-manager caches
  (`npm`, `pip`, `maven`, `cargo`) warm across runs. Under the hood it uses the same
  BuildKit primitive — `llb.AsPersistentCacheDir()` — that backs
  `RUN --mount=type=cache` in a `Dockerfile` ([cache-volumes discussion][issue1345]).

  ```go
  func (m *Ci) Build(source *dagger.Directory) *dagger.Container {
      return dag.Container().
          From("golang:1.24").
          WithMountedDirectory("/src", source).
          WithMountedCache("/go/pkg/mod", dag.CacheVolume("go-mod")). // persists across sessions
          WithWorkdir("/src").
          WithExec([]string{"go", "build", "./..."})
  }
  ```

**Remote / distributed caching** is where the CI-oriented nature shows its seams. The
persistent cache dir is _"stored internally in BuildKit, which works great locally,
however it's not persistent across CI runs (because we get a different BuildKit
instance each time)"_ ([persist-cache-volumes issue][issue1345]). The intended
solutions are (a) **import/export of cache contents** — _"the same experience as cache
imports/exports … for normal container layers,"_ most useful with ephemeral
`buildkitd`s in CI — and (b) running a **shared, persistent Dagger Engine** (with
persistent volumes or object-storage-backed caches, e.g. on Kubernetes) that all CI
jobs connect to. **Dagger Cloud** layers observability (traces of cache imports/exports
and whether caches were hit) on top. Dagger does **not** implement the
[Remote Execution API (REAPI)][bazel] that [Bazel][bazel]/[Buck2][buck2] backends like
[Buildbarn][buildbarn]/[NativeLink][nativelink] speak — its remote story is
BuildKit cache import/export plus a shared engine, not REAPI-style action farming.

### 5. CLI / UX ergonomics

The command boundary is **function-centric**, not target- or filter-centric:

- **`dagger call <function> [flags]`** invokes a Dagger Function; its arguments become
  CLI flags. Names are converted to a shell-friendly **kebab-case** (`MyFunction` →
  `my-function`, `gitRef` → `--git-ref`) ([Using the Dagger CLI][cli]).
- **Chaining with `|`.** Function outputs pipe into the next call —
  `dagger call container --packages=cowsay terminal` — which the docs call _"one of
  Dagger's most powerful features."_ This is the closest analogue to a task pipeline,
  expressed inline rather than in config.
- **Module selection with `-m`.** `dagger -m <ref> call …` runs a function from a
  remote or local module; the 0.13 `dagger core` command runs a function from the
  built-in Core API with no module to load.
- **Directory/Git arguments.** A `Directory`-typed flag accepts _"a local filesystem
  path or a remote Git reference,"_ so the same pipeline can be pointed at a working
  tree or a tagged commit without code changes.
- **Per-argument filtering.** The `+ignore` annotation (gitignore syntax) on a
  `Directory` argument controls exactly which files upload, both for performance and
  to keep unrelated edits from busting the cache ([Directory filters][filters]):

  ```go
  // +ignore=["*", "!**/*.go", "!go.mod", "!go.sum"]
  source *dagger.Directory
  ```

  Order is significant: _"the pattern `"**", "!**"` includes everything but `"!**",
"**"` excludes everything."_

There is **no `--filter`, `-p`, `:target`, or `--since` vocabulary** here — the
selection unit is _which function on which module you call_, and "which component" is
resolved by the directory/module you point it at, not by a package-filter flag. This
is the inverse of [Turborepo][turborepo] / [pnpm][pnpm] ergonomics, and a direct
consequence of pipelines being code rather than a declared task matrix.

---

## Strengths

- **Local ≡ CI by construction.** The same containerized module graph runs on a
  laptop and in CI, eliminating push-to-debug loops — the headline value over plain
  YAML pipelines and over task runners like [Task][task]/[Just][just].
- **Automatic, intrinsic caching.** Content-addressed operation caching is free and
  always on (BuildKit), not a bolt-on hasher; cache volumes keep package managers warm.
- **Real languages, real composition.** Pipelines are Go/Python/TS/etc. code; modules
  compose like libraries (`dagger install`), including **local cross-repo references**
  by relative path and **remote modules pinned to a SHA**.
- **Polyglot and engine-agnostic to the codebase.** Dagger doesn't care what language
  your app is — it orchestrates containers, so it can drive a D/`dub` build, an npm
  build, and a Maven build from one module graph.
- **Pre-call filtering for monorepos.** Per-component context directories plus
  `+ignore` mean unrelated edits don't invalidate a component's cache and only its
  files upload — emergent affected-detection without an explicit graph query.
- **Implicit parallelism.** Independent DAG branches solve concurrently with zero
  user annotation.

## Weaknesses

- **Not a package manager or build system.** Dagger resolves no library dependencies,
  produces no lockfile, and has no notion of a workspace root — it is orthogonal to
  [Cargo][cargo]/[dub][d-landscape]/[pnpm][pnpm], not a replacement. For `dub`'s
  workspace problem it offers _orchestration_ patterns, not _manifest_ primitives.
- **No declarative workspace topology.** Structure is hand-wired module dependencies;
  there is no member glob, no single-command "build everything that changed," and no
  affected-from-git-ref query (`--since`/`--affected`) — change detection is emergent
  from caching, which is harder to reason about explicitly.
- **Remote cache is BuildKit import/export, not REAPI.** Cache persistence across
  ephemeral CI runs requires a shared engine or explicit cache import/export; cache
  volumes are _not_ persistent across CI BuildKit instances out of the box. No
  REAPI/distributed-action-execution like [Bazel][bazel]/[Buck2][buck2].
- **Engine/daemon required.** Every run needs a running Dagger Engine container
  (Docker/Kubernetes), a heavier operational footprint than a static task runner.
- **CLI selection is function/path-based.** No `--filter pkg...` / `-p` / `:target`
  ergonomics; "which component" is encoded in the module/path you call, which is less
  discoverable than a package-filter flag.
- **Scaling has been a moving target.** Large module graphs historically stressed the
  engine (`dagger generate` RSS spikes, `withDirectory` re-materialization) — actively
  fixed through `v0.20.x`, but evidence the model is demanding at scale.

## Key design decisions and trade-offs

| Decision                                                      | Rationale                                                                                  | Trade-off                                                                                            |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------- |
| Pipelines as code calling a GraphQL API (vs YAML config)      | Real languages, testing, abstraction, and IDE support; same code runs locally and in CI    | An engine/daemon must run; a learning curve beyond editing a YAML file                               |
| BuildKit/LLB content-addressed DAG as the substrate           | Automatic operation-level caching and parallelism come for free, identical local↔CI       | Tied to container semantics; everything is an op in a container, even trivial steps                  |
| Modules compose by `dependencies` (vs a workspace root)       | Components encapsulate their own automation; reuse is library-like, including across repos | No member-enumerating manifest; no whole-repo view; topology is hand-wired, not globbed              |
| Local module refs by relative path (within the repo)          | `workspace:`-style local-first composition without publishing                              | Constrained to the repo root; not a general cross-repo path mechanism                                |
| Change detection via content hashing + pre-call filtering     | Unrelated edits don't bust a component's cache; affected work is skipped at the op level   | No explicit git-ref affected query (`--since`/`--affected`); "what will run" is emergent, opaque     |
| Cache volumes on BuildKit `AsPersistentCacheDir` (vs REAPI)   | Reuses Docker's proven `--mount=type=cache` primitive; warm package caches                 | Not persistent across ephemeral CI BuildKit instances without a shared engine or cache import/export |
| Remote story = shared engine + cache import/export (no REAPI) | Pragmatic reuse of BuildKit's cache transport; Dagger Cloud adds observability             | No distributed action execution / REAPI farm like Bazel/Buck2 backends                               |
| Function-centric CLI (`dagger call`, chaining) in kebab-case  | A uniform, shell-friendly surface generated from the module schema                         | No package-filter (`--filter`/`-p`/`:target`) selection vocabulary                                   |

---

## Sources

- [`dagger/dagger` — GitHub repository (README, Apache-2.0, Go engine)][repo]
- [Dagger documentation — docs.dagger.io][docs]
- [Module configuration — `dagger.json` fields][modcfg]
- [`dagger.json` JSON schema][schema]
- [Module structure & initialization][modstruct]
- [Module dependencies — `dagger install`, local & remote refs, pinning][moddeps]
- [Directory filters — pre-call filtering, `+ignore`, context directory][filters]
- [Using the Dagger CLI — `dagger call`, chaining, kebab-case][cli]
- [Best practices: Monorepos][bp-monorepo]
- [Dagger 0.13: First-class monorepo support, private modules, a new CLI command][blog013]
- [Architecture overview (DAGql, BuildKit, sessions, `call.ID`) — DeepWiki][deepwiki-arch]
- [BuildKit — the LLB solver Dagger forks][buildkit]
- [Cache-volume persistence across CI — `AsPersistentCacheDir`, import/export (issue #1345)][issue1345]
- Sibling tools: [Earthly][earthly] · [Garden][garden] · [Turborepo][turborepo] · [Nx][nx] · [Bazel][bazel] · [Buck2][buck2] · [Cargo][cargo] · [`go.work`][go-work] · [pnpm][pnpm] · [Yarn Berry][yarn-berry] · [Task][task] · [Just][just] · [mise][mise] · [Buildbarn][buildbarn] · [NativeLink][nativelink]
- D context: [the D landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/dagger/dagger
[docs]: https://docs.dagger.io/
[modcfg]: https://docs.dagger.io/reference/configuration/modules/
[schema]: https://docs.dagger.io/reference/dagger.schema.json
[modstruct]: https://docs.dagger.io/api/module-structure/
[moddeps]: https://docs.dagger.io/extending/module-dependencies/
[filters]: https://docs.dagger.io/api/filters/
[cli]: https://docs.dagger.io/api/cli/
[bp-monorepo]: https://docs.dagger.io/reference/best-practices/monorepos/
[blog013]: https://dagger.io/blog/dagger-0-13
[deepwiki-arch]: https://deepwiki.com/dagger/dagger/1.2-architecture-overview
[buildkit]: https://github.com/moby/buildkit
[issue1345]: https://github.com/dagger/dagger/issues/1345
[earthly]: ../earthly/
[garden]: ../garden/
[turborepo]: ../turborepo/
[nx]: ../nx/
[bazel]: ../bazel/
[buck2]: ../buck2/
[cargo]: ../cargo/
[go-work]: ../go-work/
[pnpm]: ../pnpm/
[yarn-berry]: ../yarn-berry/
[task]: ../task/
[just]: ../just/
[mise]: ../mise/
[buildbarn]: ../buildbarn/
[nativelink]: ../nativelink/
[d-landscape]: ../../async-io/d-landscape.md
