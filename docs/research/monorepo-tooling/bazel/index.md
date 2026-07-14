# Bazel (Polyglot)

Google's open-source incarnation of the internal `Blaze` build system: a
language-agnostic, hermetic, content-addressed build engine whose `BUILD` files
turn a whole monorepo into one fine-grained action graph that is incrementally
re-evaluated, parallelized, and cached locally or on a shared remote — the
reference design every other "polyglot build orchestrator" is measured against.

| Field           | Value                                                                                                              |
| --------------- | ------------------------------------------------------------------------------------------------------------------ |
| Language        | Java (core) + C++ (client/server, JNI) + Starlark (the build/rule language)                                        |
| License         | Apache-2.0                                                                                                         |
| Repository      | [bazelbuild/bazel][repo]                                                                                           |
| Documentation   | [bazel.build][docs] · [Bazel Query Reference][query-lang] · [Skyframe reference][skyframe]                         |
| Category        | Polyglot Build Orchestrator                                                                                        |
| Workspace model | Single repo rooted at a boundary-marker file (`MODULE.bazel`); the whole tree is one workspace of `BUILD` packages |
| First released  | Public open-source release March 2015 (1.0 in October 2019); internal `Blaze` predates it by ~10 years             |
| Latest release  | `9.1.0` LTS (May 6, 2026)                                                                                          |

> **Latest release:** `9.1.0` LTS, released **May 6, 2026**, supported through
> Dec 31, 2028. As of June 5, 2026 three release lines are supported in parallel:
> `9.1.0` (latest LTS), `8.x` (LTS, support through Dec 31, 2027), and the
> `rolling` releases cut from `master`. Bazel `8.0` (Dec 2024) flipped the
> decade-old `WORKSPACE` external-dependency mechanism **off by default** in
> favour of `Bzlmod` (`MODULE.bazel`); Bazel `9` removes `WORKSPACE` support
> entirely. Source citations below are against `master` and the LLVM project's
> in-tree Bazel overlay ([`utils/bazel/MODULE.bazel`][llvm-module]), a real,
> large polyglot workspace checked out locally.

---

## Overview

### What it solves

Bazel is built for the problem that language-specific package managers
([Cargo][cargo], [npm][npm], [uv][uv]) do not natively address: **one repository
containing many languages, built and tested as a single coherent graph.** A
Google-scale monorepo has C++, Java, Go, Python, TypeScript, protobuf, and shell
side by side; a change to a `.proto` must rebuild exactly the downstream C++ and
Java that consume it, no more and no less, and a `bazel test //...` over hundreds
of thousands of targets must finish by running only the handful actually affected
by the change. Bazel achieves this by modelling the build as a **pure function of
its inputs**: every action declares its exact input files and output files, the
engine hashes those inputs, and an action whose inputs are unchanged is never
re-run — its outputs are fetched from a cache instead, possibly a cache shared by
an entire engineering org.

The official positioning ([`bazel.build/about/intro`][intro]):

> _"Bazel maintains agility while handling builds with 100k+ source files. It
> works with multiple repositories and user bases in the tens of thousands."_

The trade for that power is that Bazel does **not** speak any language's native
dependency idioms. It does not read `Cargo.toml`, `package.json`, or `dub.sdl`;
you describe every library, binary, and test as a Starlark **target** in a
`BUILD` file, and a third-party dependency is brought in as an external
repository (a `bazel_dep` from a registry, or a fetched archive), not by the
language's own resolver. This is the diametric opposite of [Cargo][cargo]'s
"the manifest _is_ the build" model and the reason Bazel is a _build
orchestrator_ rather than a _package manager_.

### Design philosophy

Bazel's three stated pillars are **speed, correctness, and reproducibility**
([`bazel.build/about/intro`][intro]):

> _"Bazel caches all previously done work and tracks changes to both file content
> and build commands … rebuilds only that."_

> _"You can set up Bazel to run builds and tests hermetically through sandboxing,
> minimizing skew and maximizing reproducibility."_

Three consequences follow that shape the entire system, and that distinguish it
from the language package managers in this survey:

1. **Builds are deterministic functions of declared inputs.** An action's cache
   key is a hash over its command line, environment, and the content of every
   declared input. If two machines (or two CI runs) compute the same key, the
   output is identical and interchangeable — which is what makes a _shared
   remote cache_ correct rather than merely a heuristic.
2. **Hermeticity is enforced, not assumed.** Sandboxing hides undeclared files
   from an action so a missing dependency edge fails the build instead of
   silently working on one machine and breaking on another. This is the property
   `Nix` flakes pursue at the package level; Bazel pursues it at the
   per-action level.
3. **The build language is data, evaluated by a restricted interpreter.**
   `BUILD` files are written in **Starlark**, a deliberately non-Turing-complete,
   deterministic Python dialect (no `while`, no recursion, no I/O), so that
   loading the build graph is itself reproducible and parallelizable.

Within this survey Bazel is the canonical _heavy polyglot engine_: compare it
against the JS/TS task orchestrators ([Nx][nx], [Turborepo][turborepo]) that wrap
each package's own toolchain rather than replacing it, and against the
language-native workspace models of [Cargo][cargo] and [Go's `go.work`][go-work].
For the D-specific framing of why `dub` lacks all of this, see
[the D landscape note][d-landscape].

---

## How it works

### `BUILD` files, packages, targets, and labels

A directory containing a `BUILD` (or `BUILD.bazel`) file is a **package**. The
file declares **targets** — instances of **rules** (`cc_library`, `java_binary`,
`go_test`, `py_library`, …) plus source files and generated files. Every target
has a globally unique **label** of the form `//path/to/package:target_name`,
where `//` is the workspace root. A label with no colon (`//foo/bar`) is
shorthand for `//foo/bar:bar` (the target named after its package).

```starlark
# math/BUILD.bazel — a package with one library target
cc_library(
    name = "math",
    srcs = ["add.cc"],
    hdrs = ["add.h"],
    visibility = ["//visibility:public"],
)
```

```starlark
# app/BUILD.bazel — a binary that depends on the sibling library by label
cc_binary(
    name = "app",
    srcs = ["main.cc"],
    deps = ["//math"],          # local cross-reference: the //math:math library
)
```

The `deps = ["//math"]` edge is Bazel's entire local-cross-reference story: there
is no `path=`, no `workspace:` protocol, no version — a target in the same
repository is simply named by its label. This is structurally simpler than every
language-package-manager approach in this survey precisely because there is only
**one** workspace and **one** namespace of labels.

### The two-phase graph: loading/analysis → execution

A `bazel build` proceeds through phases that produce two distinct graphs:

1. **Loading & analysis** evaluates the `BUILD` (and `.bzl`) files in Starlark to
   produce the **target graph**, then runs each target's rule implementation to
   produce **configured targets** and, from them, the **action graph** — a DAG
   of hermetic commands ("actions") with file-level inputs and outputs. The
   action graph is _finer-grained_ than the target graph: one `cc_library` may
   expand into a compile action per source plus an archive action.
2. **Execution** walks the action graph, running each action whose outputs are
   stale (or fetching them from a cache), as much in parallel as the dependency
   edges and the resource limits allow.

> [!NOTE]
> The action graph "is different from the target dependency graph … The action
> graph contains file-level dependencies, full command lines, and other
> information Bazel needs to execute the build." Caching and affected-target
> reasoning operate at the **action** level, which is why Bazel can rebuild
> exactly the reverse-transitive closure of a changed file.

### Skyframe: the incremental evaluation core

Both graphs are evaluated by **Skyframe**, the engine's general-purpose
incremental-computation framework. The whole build is one big lazy functional
evaluation: nodes are `SkyValue`s keyed by `SkyKey`, computed by `SkyFunction`s
that request other nodes as dependencies. From the [Skyframe reference][skyframe]:

> _"Since functions can only interact with each other by way of requesting
> dependencies, functions that don't depend on each other can be run in parallel
> and Bazel can guarantee that the result is the same as if they were run
> sequentially."_

> _"Bazel can build up a complete data flow graph from the input files to the
> output files, and use this information to only rebuild those nodes that actually
> need to be rebuilt: the reverse transitive closure of the set of changed input
> files."_

This is the mechanism behind both correctness and incrementality: a `SkyFunction`
that needs a not-yet-computed dependency aborts and is restarted once the
dependency is ready, so the engine never blocks a worker thread on a missing
input; and a node whose recomputed value equals its old value "resurrects" the
nodes that were invalidated through it, pruning the rebuild (change pruning).

### Five dimensions

#### 1. Workspace declaration & topology

Bazel's workspace is **the entire repository**, discovered by a boundary-marker
file at its root rather than by enumerating members. A **repo** is "a directory
tree with a boundary marker file at its root"; the markers are `MODULE.bazel`,
`REPO.bazel`, `WORKSPACE`, or `WORKSPACE.bazel` ([external deps
overview][external]). The repo in which the command runs is the **main
repository**, and:

> _"The root of the main repository is also known as the workspace root."_
> ([external deps overview][external])

There is no "members" array and no glob of sub-packages: **every** directory with
a `BUILD` file anywhere beneath the root is automatically a package in the same
workspace, addressed by label. Sub-package "topology" is therefore implicit in
the directory tree and made explicit only through inter-target `deps` edges. A
real example is the LLVM project's Bazel overlay, whose root declares the module
and its registry dependencies ([`utils/bazel/MODULE.bazel`][llvm-module]):

```starlark
# llvm-project/utils/bazel/MODULE.bazel (excerpt, verbatim)
module(name = "llvm-project-overlay")

bazel_dep(name = "bazel_skylib", version = "1.8.2")
bazel_dep(name = "platforms", version = "1.0.0")
bazel_dep(name = "rules_cc", version = "0.2.11")
bazel_dep(name = "rules_python", version = "1.9.0")
```

> [!IMPORTANT]
> This is the inverse of the explicit-members model used by [Cargo][cargo]
> (`members = ["libs/*"]`), [pnpm][pnpm] (`pnpm-workspace.yaml`), and
> [Go's `go.work`][go-work] (a `use` list). Bazel has no concept of "workspace
> members" to enumerate — membership is "has a `BUILD` file under the root,"
> resolved lazily as labels are referenced. The unit of selection is the
> **package/target**, never the "sub-project."

#### 2. Dependency handling & isolation

Bazel separates **internal** dependencies (other targets in the same repo, by
label) from **external** dependencies (other repos), and isolates the latter
strictly.

- **Internal**: a `deps` edge to a `//path:target` label. No hoisting, no
  symlink trees, no virtual store — there is one source tree and one label
  namespace, so "isolation" is moot.
- **External (`Bzlmod`)**: each dependency is a versioned **Bazel module**
  declared with `bazel_dep(name, version)` in `MODULE.bazel`. "MODULE.bazel
  declares only direct dependencies, while transitive dependencies are
  automatically resolved" ([external deps overview][external]) — Bazel runs
  Minimal Version Selection over the registry-published metadata to pick one
  version of each module for the whole build, then materializes each as an
  isolated external **repo** under the output base, referenced as `@repo//…`.

Crucially for monorepos, an external module can be redirected to **local source**
with `local_path_override`, which "specifies that a dependency should come from a
certain directory on local disk, instead of from a registry" — effectively
backing it with a `local_repository`:

```starlark
# MODULE.bazel — develop against a local checkout of a dependency
bazel_dep(name = "mathlib", version = "1.0.0")

local_path_override(
    module_name = "mathlib",
    path = "../mathlib",
)
```

> [!WARNING]
> `local_path_override` (and the other non-registry overrides `archive_override`
> / `git_override`) "only takes effect in the root module; in other words, if a
> module is used as a dependency by others, its own overrides are ignored." This
> is the same root-only override discipline [Cargo][cargo] applies to
> `[patch]`/`replace`.

#### 3. Task orchestration & scheduling

The action graph **is** the task DAG, and Skyframe **is** the scheduler. There is
no separate "pipeline" config (contrast [Turborepo][turborepo]'s `tasks` /
[Nx][nx]'s `targetDefaults`): the dependency edges between actions, derived from
declared inputs/outputs, fully determine execution order. Independent actions run
concurrently up to `--jobs` (the number of concurrent Skyframe evaluators during
execution, defaulting to the machine's CPU count) and local resource limits
(`--local_cpu_resources`, `--local_ram_resources`). Change detection is **input
hashing**: an action re-runs only if its action key (a hash of command line +
environment + input file contents) changes; otherwise its outputs are reused.

Affected-target detection across a code change is expressed with **`bazel
query`/`cquery`**, not a bespoke `--since` flag. The canonical pattern computes
the reverse dependencies of the changed files:

```bash
# What depends on a changed file, within everything?
bazel query 'rdeps(//..., set(math/add.cc))'
```

The community `target-determinator` tool builds on this — it "determine[s] which
Bazel targets changed between two git commits," caching `cquery` results across
runs — and Bazel `8`+ ships **Skyfocus** (experimental) to GC the Skyframe graph
to a user-defined working set for large-monorepo iteration. (Compare
[Turborepo][turborepo]'s `--filter=...[ref]` and [Nx][nx]'s `nx affected`, which
bake git-diff change detection directly into the CLI.)

#### 4. Caching & remote execution

This is Bazel's defining capability. The remote cache has two parts
([remote caching][remote-caching]):

> _"The remote cache consists of an **action cache**, a map of action hashes to
> action result metadata, and a **content-addressable store (CAS)** of output
> files."_

Because an action's key is a content hash of its inputs, results are
**content-addressed** and portable: a teammate or CI runner that computes the
same key downloads the prebuilt output (`Action Cache` hit → `CAS` fetch) instead
of recompiling. Bazel supports a local on-disk cache and several remote backends:

| Backend                                     | Protocol                                     | Flag / form                                       |
| ------------------------------------------- | -------------------------------------------- | ------------------------------------------------- |
| Local disk cache                            | filesystem directory                         | `--disk_cache=path/to/cache`                      |
| HTTP/1.1 (e.g. `nginx` + WebDAV)            | `PUT`/`GET` of opaque BLOBs (`/ac/`,`/cas/`) | `--remote_cache=http://host:port`                 |
| gRPC Remote Execution API (REAPI v2)        | `grpc` / `grpcs`                             | `--remote_cache=grpc://host:port`                 |
| Google Cloud Storage                        | HTTP object store                            | `--remote_cache=https://storage.googleapis.com/…` |
| Remote **execution** (run actions remotely) | REAPI `Execution` service                    | `--remote_executor=grpc://host:port`              |

The cross-vendor contract is the **Remote Execution API (REAPI)** — `ActionCache`,
`ContentAddressableStorage` (with `FindMissingBlobs` to upload only absent inputs),
`Capabilities`, and the `ByteStream` services — implemented by `bazel-remote`,
`Buildbarn`, `Buildfarm`, `BuildGrid`, `NativeLink`, and `BuildBuddy`. With
`--remote_executor`, Bazel ships each action (inputs + command) to a remote worker
pool and downloads only the outputs, so a laptop can drive a build that physically
runs across hundreds of machines. This REAPI ecosystem is the reason whole
deep-dives in this survey exist for the backends (`buildbuddy`, `buildbarn`,
`nativelink`).

#### 5. CLI / UX ergonomics

Bazel's command boundary is **the target pattern**, a first-class, composable
addressing syntax rather than a flag ([target patterns][run-build]):

| Pattern         | Meaning                                                             |
| --------------- | ------------------------------------------------------------------- |
| `//foo/bar:wiz` | the single target `wiz` in package `foo/bar`                        |
| `//foo/bar`     | shorthand for `//foo/bar:bar`                                       |
| `//foo/bar:all` | all rule targets in package `foo/bar`                               |
| `//foo/...`     | all rule targets in every package beneath `foo` (recursive)         |
| `//...`         | all rule targets in the main repository                             |
| `:foo`          | working-directory-relative: the `foo` target in the current package |

```bash
bazel build //app                 # build one binary
bazel build //math/...            # build everything under math/ recursively
bazel test  //...                 # run every test in the repo
bazel test  -- //... -//slow/...  # everything except the slow/ subtree
bazel build //... --jobs=16 --keep_going   # 16-way parallel; report all failures
```

The `...` wildcard is Bazel's "broadcast over a subtree" idiom and `-//slow/...`
its exclusion idiom — the same role [Cargo][cargo]'s `--workspace`/`--exclude`
and [Turborepo][turborepo]'s `--filter` play, but expressed in the label algebra
itself so the _same_ syntax serves `build`, `test`, `run`, `query`, and `cquery`.
`--keep_going` (`-k`) continues past failures to report them all; `--jobs` (`-j`)
caps concurrency. There is no `-p package` flag because a package is already a
first-class addressable label.

---

## Strengths

- **Truly polyglot.** One graph, one cache, one CLI across every language with a
  ruleset (C++, Java, Go, Python, Rust, JS/TS, protobuf, …) — the only model in
  this survey that is genuinely language-agnostic end to end.
- **Correct incrementality at action granularity.** Input-hash cache keys mean a
  change rebuilds exactly its reverse-transitive closure, validated by sandboxing
  that turns undeclared-dependency bugs into hard failures.
- **Shared remote cache + remote execution.** Content-addressed results are
  portable across machines; a standard REAPI lets a thin client drive a build run
  across a worker farm — unmatched scaling for very large monorepos.
- **Reproducible build language.** Starlark is deterministic and sandboxed, so
  loading the graph is itself reproducible and parallel.
- **Scales to 100k+ files** with implicit (directory-tree) topology and lazy,
  label-driven loading — no member list to maintain.
- **Mature query layer.** `query`/`cquery`/`aquery` make the graph itself
  inspectable, enabling affected-target CI without bespoke tooling.

## Weaknesses

- **Total rewrite of the build, not adoption of native manifests.** Bazel
  ignores `Cargo.toml`/`package.json`/`dub.sdl`; every library and test must be
  re-expressed as `BUILD` targets, and third-party deps re-declared as modules.
  Migration cost is the dominant adoption barrier.
- **Ruleset maintenance burden.** Each language's rules (`rules_go`, `rules_js`,
  `rules_rust`, …) are separately versioned external modules with their own quirks
  and breakages, especially across the `WORKSPACE`→`Bzlmod` transition.
- **Steep learning curve.** Starlark, labels, configured targets, transitions,
  toolchains, and the loading/analysis/execution mental model are a lot before a
  first build.
- **Heavyweight for small/single-language repos.** For a one-language project a
  native package manager ([Cargo][cargo], [uv][uv], `dub`) is far less ceremony.
- **`WORKSPACE`→`Bzlmod` churn.** The external-dependency system was reworked
  across 7/8/9; older docs, examples, and rulesets lag, and Bazel `9` drops
  `WORKSPACE` entirely.
- **No language-native publishing.** Bazel builds artifacts but is not a registry
  client for any language ecosystem; publishing to crates.io/npm/the dub registry
  is out of scope.

## Key design decisions and trade-offs

| Decision                                                        | Rationale                                                                                     | Trade-off                                                                                 |
| --------------------------------------------------------------- | --------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Language-agnostic `BUILD`/Starlark over native manifests        | One uniform graph/cache/CLI across all languages; deterministic, sandboxed loading            | Must re-express every library/test/dep; large migration cost; ignores ecosystem manifests |
| Workspace = whole repo, topology implicit in the directory tree | No member list to maintain; lazy label-driven loading scales to 100k+ files                   | No first-class "sub-project" unit; everything is a package/target, not a workspace member |
| Action graph as the unit of work and caching (vs. target graph) | Fine-grained incrementality: rebuild exactly the reverse-transitive closure of changed inputs | More nodes to track; the mental model (loading vs. analysis vs. execution) is complex     |
| Builds are pure functions of declared inputs (input hashing)    | Makes a _shared_ cache correct, not heuristic; portable, content-addressed results            | Requires hermeticity/sandboxing discipline; undeclared inputs are hard errors             |
| Skyframe lazy parallel evaluation with restart-on-missing-dep   | Independent nodes parallelize automatically; only the changed closure recomputes              | Fixed thread pool + restart model; surprising for those expecting imperative ordering     |
| Bzlmod (`MODULE.bazel`) + MVS over a registry                   | Direct-only declarations; reproducible transitive resolution; clear dependency overview       | A second, Bazel-specific dependency universe parallel to each language's own resolver     |
| REAPI: standard remote cache + remote execution                 | Org-wide cache reuse and farm-scale execution from a thin client                              | Operational complexity (cache/worker infra); benefits accrue only at scale                |
| Target patterns (`//…:…`, `...`) as the command boundary        | One addressing algebra serves build/test/run/query uniformly; broadcast + exclusion built in  | Verbose vs. a short `-p name`; requires learning the label/wildcard syntax                |

---

## Sample workspace

A minimal, genuinely-runnable two-package Bazel workspace lives in
[`./sample/`](./sample/): a root `MODULE.bazel`, a `mathlib` package
(`cc_library`), an `app` package (`cc_binary`) that depends on it **locally by
label** (`deps = ["//mathlib"]`), a workspace-root `BUILD.bazel` exposing a
`bazel run //:hello` task alias, and a `.bazelrc`. It demonstrates Dimensions 1
(implicit directory-tree topology), 2 (local label cross-reference), 3 (the
action DAG), and 5 (target-pattern CLI) in ~30 lines of config.

---

## Sources

- [bazelbuild/bazel — GitHub repository][repo] (source for the cited subsystems)
- [bazel.build — official documentation][docs]
- [About Bazel / Intro — speed, correctness, reproducibility][intro]
- [External dependencies overview — repos, workspace root, `Bzlmod`][external]
- [Bazel modules / `MODULE.bazel` globals — `bazel_dep`, `local_path_override`][module-globals]
- [Skyframe reference — incremental parallel evaluation][skyframe]
- [Remote Caching — action cache + CAS, backends, flags][remote-caching]
- [Remote APIs (REAPI) — cross-vendor remote cache/execution contract][remote-apis]
- [Build with Bazel / target patterns — `//…:…`, `...`, exclusions][run-build]
- [Bazel Query Reference — `rdeps`, affected-target detection][query-lang]
- [`target-determinator` — changed-target detection between git commits][target-determinator]
- Local primary source: [`llvm-project/utils/bazel/MODULE.bazel`][llvm-module] (a real large polyglot Bazel workspace)
- Related deep-dives: [Cargo][cargo] · [Go `go.work`][go-work] · [Nx][nx] · [Turborepo][turborepo] · [Gradle][gradle] · [the D landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/bazelbuild/bazel
[docs]: https://bazel.build/
[intro]: https://bazel.build/about/intro
[external]: https://bazel.build/external/overview
[module-globals]: https://bazel.build/rules/lib/globals/module
[skyframe]: https://bazel.build/reference/skyframe
[remote-caching]: https://bazel.build/remote/caching
[remote-apis]: https://github.com/bazelbuild/remote-apis
[run-build]: https://bazel.build/run/build
[query-lang]: https://bazel.build/query/language
[target-determinator]: https://github.com/bazel-contrib/target-determinator
[llvm-module]: https://github.com/llvm/llvm-project/blob/d64972c91369c6372e23e728881d9c645edeb37d/utils/bazel/MODULE.bazel
[cargo]: ../cargo/
[go-work]: ../go-work/
[nx]: ../nx/
[turborepo]: ../turborepo/
[gradle]: ../gradle/
[npm]: ../npm/
[pnpm]: ../pnpm/
[uv]: ../uv/
[d-landscape]: ../../async-io/d-landscape.md
