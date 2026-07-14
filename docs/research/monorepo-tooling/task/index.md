# Task (go-task) (Polyglot)

A single-binary, YAML-configured generic task runner written in Go — "a fast,
cross-platform build tool inspired by Make" — that gives a polyglot monorepo a
DAG of `deps`, file-fingerprinted up-to-date checks, and `includes`-based
namespacing, but deliberately stops short of being a package manager or a
workspace resolver.

| Field           | Value                                                                                                                |
| --------------- | -------------------------------------------------------------------------------------------------------------------- |
| Language        | Go (the binary); workspace config in YAML (`Taskfile.yml`)                                                           |
| License         | MIT (Copyright 2016 Andrey Nering and contributors)                                                                  |
| Repository      | [go-task/task][repo]                                                                                                 |
| Documentation   | [taskfile.dev][docs] · [schema reference][schema] · [CLI reference][cli]                                             |
| Category        | Generic Task Runner                                                                                                  |
| Workspace model | No native workspace concept; a "monorepo" is a **root `Taskfile.yml`** that `includes` sub-`Taskfile`s as namespaces |
| First released  | `v1` (Feb 2017); the schema-`"3"` line (`v3.0.0`) in 2020                                                            |
| Latest release  | `v3.51.1` (May 16, 2026)                                                                                             |

> **Latest release:** `v3.51.1`, published **May 16, 2026** ([releases][releases]).
> Task is still on the schema-`version: '3'` line it has carried since 2020;
> the `3.x` minor stream adds features without breaking the Taskfile format.
> Recent `3.5x` work focused on **Remote Taskfiles** hardening (TLS / mTLS via
> `--cacert` / `--cert` / `--cert-key`, a `--trusted-hosts` flag and
> `remote.trusted-hosts` config), templating performance (skipping Go-template
> evaluation for static strings), and new template functions (`absPath`,
> `joinEnv`, `joinUrl`). Source citations below are against `main` and the
> official docs as of June 5, 2026.

---

## Overview

### What it solves

Task occupies the niche its README states plainly ([`README.md`][readme]):

> _"A fast, cross-platform build tool inspired by Make, designed for modern
> workflows."_

Where [Make][make] uses a tab-sensitive DSL, a single global namespace, and
mtime-only staleness, Task keeps Make's two good ideas — **a target depends on
other targets** and **don't redo work whose inputs are unchanged** — and rebuilds
the surface in declarative YAML with a single statically-linked Go binary, "zero
dependencies," that runs the same `Taskfile.yml` on Linux, macOS, and Windows.
It is squarely a member of the **generic task runner** family alongside
[just][just], [mise][mise], and [Make][make]: it orchestrates _commands_, not
_packages_. It has **no dependency resolver, no lockfile, no package store, and
no remote-execution backend** — capabilities owned by the language-specific
package managers ([Cargo][cargo], [uv][uv], [pnpm][pnpm]) and the heavyweight
build engines ([Bazel][bazel], [Buck2][buck2]) elsewhere in this survey.

For a monorepo, that scoping is the whole point. Task is the **glue layer**: a
root `Taskfile.yml` that `includes` each sub-package's `Taskfile.yml` under a
namespace, declares which library builds must precede which application build via
`deps`, and skips any leg whose `sources` haven't changed. The actual dependency
installation in each member is delegated to that member's native tool
(`go build`, `cargo build`, `npm ci`, `dub build`). In that respect Task is to a
polyglot monorepo what [moon][moon] is — minus moon's project graph, content-
addressable cache, and toolchain manager.

### Design philosophy

Three principles shape the tool, all visible in the config surface and the docs:

1. **Convention over a build language.** A Taskfile is data (YAML), not a
   Turing-complete build language like [Bazel][bazel]'s Starlark or
   [Buck2][buck2]'s. The most a task does dynamically is run shell via
   [`mvdan/sh`][mvdansh] (an embedded Go shell interpreter, so `Taskfile`s are
   cross-platform without `bash`) and interpolate Go `text/template` variables.
   There is no rule abstraction, no providers, no aspects.

2. **Incremental, file-based correctness — not hermeticity.** Task decides
   whether to skip a task by **fingerprinting declared `sources` against declared
   `generates`** (a checksum or a timestamp), exactly Make's contract made
   explicit and content-aware. It makes no attempt to sandbox a task or capture
   undeclared inputs; an unlisted input that changes will silently produce a
   stale "up to date." This is the same correctness ceiling as [moon][moon]'s
   declared-inputs model, and well below [Bazel][bazel]'s sandboxed actions.

3. **A single binary, zero install ceremony.** The entire tool is one Go
   executable; a Taskfile needs no `node_modules`, no JVM, no plugin install.
   This is the ergonomic axis on which it beats [Nx][nx] / [Turborepo][turborepo]
   (which assume a Node toolchain) and the JVM build tools ([Gradle][gradle],
   [Maven][maven], [sbt][sbt]).

Within this survey Task is the canonical _"minimal, polyglot, file-fingerprinting
generic runner"_ data point: compare it against [just][just] (a command runner
with **no** up-to-date checks or DAG-level change detection), [Make][make] (its
mtime-only ancestor), and [moon][moon] / [Turborepo][turborepo] (which add the
project graph, remote cache, and affected-detection Task omits).

---

## How it works

A Task project is anchored by a `Taskfile.yml` (or `.yaml`; a `Taskfile.dist.yml`
committed-defaults variant is also recognised). The top of the file declares the
schema `version`, optional global `vars` / `env` / `dotenv`, optional `includes`,
and a `tasks` map. Each task carries `cmds` (what to run), optional `deps` (what
must run first), and optional `sources` / `generates` (the fingerprint inputs and
outputs).

```yaml
# Taskfile.yml
version: '3'

vars:
  BIN: ./bin/app

tasks:
  build:
    deps: [assets] # runs concurrently before build
    sources:
      - '**/*.go'
    generates:
      - '{{.BIN}}'
    cmds:
      - go build -o {{.BIN}} .

  assets:
    sources:
      - 'assets/**/*'
    generates:
      - 'public/bundle.css'
    cmds:
      - npm run build:css
```

Running `task build` resolves the DAG, runs `assets` first (because `build`
`deps` on it), then runs `build` — but only the legs whose `sources` checksum
differs from the cached value in `.task/` actually execute. The data model is a
flat `ast.Task` struct ([`taskfile/ast/task.go`][ast-task]) carrying exactly
these fields: `Cmds []*Cmd`, `Deps []*Dep`, `Sources []*Glob`,
`Generates []*Glob`, `Status []string`, `Preconditions []*Precondition`,
`Method string`, `Run string`, `Dir string`, and — populated only during the
merge of included files — `Namespace string` and `FullName string`.

### The short forms

For trivial tasks Task accepts terse syntax — a bare string is the single `cmd`:

```yaml
tasks:
  hello: echo "Hello, World!" # == { cmds: ['echo "Hello, World!"'] }
```

### Calling tasks from tasks (sequential vs. parallel)

`deps` are **parallel** prerequisites; to force an _order_ you call a task from
within `cmds` using the `task:` form, which runs synchronously in sequence:

```yaml
tasks:
  release:
    cmds:
      - task: build # runs to completion first
      - task: package
        vars: { TARGET: 'linux' } # pass vars to the called task
```

This `deps`-are-parallel / `cmds`-`task:`-are-sequential split is the core
scheduling primitive and the most common source of confusion (see
[Weaknesses](#weaknesses)).

---

## Workspace declaration & topology

Task has **no first-class workspace, project, or member concept** — and this is
the most important fact about it for this survey. There is no `[workspace]` block,
no `members = [...]` glob, no project graph. A "monorepo" is expressed entirely
through the `includes` mechanism: a root `Taskfile.yml` pulls in each
sub-package's `Taskfile.yml` and exposes its tasks under a **namespace**
([guide][guide]):

```yaml
# repo-root Taskfile.yml
version: '3'

includes:
  docs: ./documentation # tasks become `docs:<name>`
  api:
    taskfile: ./services/api/Taskfile.yml
    dir: ./services/api # run api's tasks in their own dir
  lib:
    taskfile: ./libs/core
    internal: true # not exposed on the CLI / --list
```

The included file's tasks are addressed as `docs:build`, `api:test`, etc. The
`Include` schema ([schema][schema]) carries the knobs that make this usable as a
monorepo topology:

| `includes` key | Effect                                                                                          |
| -------------- | ----------------------------------------------------------------------------------------------- |
| `taskfile`     | Path to the included `Taskfile.yml` **or** to a directory containing one                        |
| `dir`          | Working directory for the included tasks (defaults to the **caller's** dir, not the includee's) |
| `internal`     | Hide the namespace's tasks from `--list` and direct CLI invocation (used for library internals) |
| `flatten`      | Merge the included tasks into the **root** namespace with **no** prefix                         |
| `optional`     | Don't error if the file is missing                                                              |
| `aliases`      | Alternative namespace names                                                                     |
| `excludes`     | Specific tasks to drop from the include                                                         |
| `vars`         | Variables injected into the included Taskfile                                                   |
| `checksum`     | An expected file checksum (pins a remote/included file's contents)                              |

> [!IMPORTANT]
> **Discovery is explicit, never glob-based.** Unlike [Cargo][cargo]'s
> `members = ["crates/*"]`, [pnpm][pnpm]'s `packages:` globs, or [moon][moon]'s
> `projects` globs, Task's `includes` map **enumerates every member by hand** —
> there is no `includes: ["packages/*"]` wildcard. Adding a sub-package to the
> monorepo means adding a line to the root `Taskfile.yml`. This is the single
> largest gap between Task and a true workspace tool, and the reason community
> threads repeatedly ask for "an idiomatic root Taskfile for a monorepo"
> ([discussion #1517][disc-1517]).

> [!NOTE]
> A subtle footgun: by default an included Taskfile's tasks **run in the
> directory Task was invoked from**, not in the directory of the included file.
> Monorepo setups must set `dir:` (per-include) or `dir:` (per-task) so each
> member's commands resolve paths relative to that member, mirroring how
> [moon][moon] anchors tasks to their project root automatically.

---

## Dependency handling & isolation

This dimension barely applies — and saying so plainly is the honest answer for a
generic task runner. Task does **not** resolve packages, does **not** hoist,
symlink, or maintain a virtual store, and has **no lockfile**. Each member's
real dependencies are installed by that member's native package manager, which
Task merely invokes:

- **Dependency installation is a delegated `cmd`.** A member's `Taskfile.yml`
  has an `install` (or `deps`) task that shells out to `go mod download`,
  `cargo fetch`, `npm ci`, `uv sync`, or `dub upgrade`. Task's job is to **order**
  these and **skip** the unchanged ones, not to perform resolution. The isolation
  model is therefore entirely whatever the underlying manager provides.

- **There is no `workspace:`-protocol equivalent.** Task has no notion of one
  member depending on a _sibling member's package_. Cross-member ordering is
  expressed purely as task ordering — "build `lib` before `service`" — via
  `includes` + `deps`:

  ```yaml
  # services/api/Taskfile.yml
  version: '3'
  includes:
    core: ../../libs/core # the sibling library
  tasks:
    build:
      deps:
        - core:build # build the library member first
      cmds:
        - go build ./...
  ```

  The dependency on the sibling is a **task edge**, not a package edge: Task
  guarantees `core:build` runs before `api:build`, but the linkage of `api`
  against `core`'s _artifact_ is the language toolchain's concern (a `replace`
  directive in `go.mod`, a `path =` dependency in `Cargo.toml`, a `path=` in
  `dub.sdl`).

- **Variable inheritance is the only "config inheritance."** A root `Taskfile`'s
  `vars` and `dotenv` propagate down to includes (and an include can override via
  `includes.<ns>.vars`), giving a lightweight version of the centralized-config
  story that [Cargo][cargo]'s `[workspace.package]` inheritance provides — but for
  **shell variables**, not dependency versions.

> [!WARNING]
> Because the `.task/` checksum cache is **per-directory**, a library included by
> two services and built in each service's `dir` is **fingerprinted and built
> twice** — its cache is not shared across the two include sites
> ([issue #852][issue-852]). Task has no global, content-addressed artifact store
> to deduplicate this the way [moon][moon]'s CAS or [Bazel][bazel]'s does.

---

## Task orchestration & scheduling

This is where Task earns the "build tool" half of its tagline.

**The DAG.** When Task runs, it merges every included `Taskfile` into one
`ast.Taskfile` (namespaces flattened into qualified names), then compiles the
requested task plus its transitive `deps` into a directed acyclic graph. `deps`
edges are the prerequisites; `cmds` with a `task:` reference are sequential
sub-invocations. Cyclic `deps` are detected and rejected.

**Concurrency.** `deps` of a single task **run in parallel by default** — the
docs are explicit ([guide][guide]):

> _"Dependencies run in parallel, so dependencies of a task should not depend one
> another."_

Across top-level targets, `task a b c` runs them sequentially unless `--parallel`
/ `-p` is given; `--concurrency` / `-C N` caps the total number of concurrently
executing tasks (`0` = unlimited). To avoid a diamond-shaped DAG running a shared
dependency multiple times within one invocation, a task sets `run: once` (the
other `run` modes are `always`, the default, and `when_changed`, which re-runs
once per distinct variable set).

**Change detection — fingerprinting.** A task with `sources` declared is skipped
when its fingerprint is unchanged. The `method` chooses the algorithm
([schema][schema], [`internal/fingerprint/`][fingerprint]):

| `method`    | Mechanism                                                                                           | Stored in          |
| ----------- | --------------------------------------------------------------------------------------------------- | ------------------ |
| `checksum`  | (default) SHA-256 over the **contents** of all resolved `sources` globs; compared to a saved digest | `.task/checksum/`  |
| `timestamp` | Compares the newest `sources` mtime against the oldest `generates` mtime (Make-style)               | `.task/timestamp/` |
| `none`      | No fingerprint; the task always runs                                                                | —                  |

The documented contract ([guide][guide]):

> _"When given, Task will compare the checksum of the source files to determine
> if it's necessary to run the task. If not, it will just print a message like
> `Task "js" is up to date`."_

Implementation-wise, `internal/fingerprint` is a small strategy hierarchy
(`sources_checksum.go`, `sources_timestamp.go`, `sources_none.go`, all behind a
`checker.go` interface), with `status.go` and the `status:` task field providing
an **escape hatch**: `status` is a list of shell commands whose exit code decides
freshness (exit `0` ⇒ up to date), letting a task define "am I stale?" with
arbitrary logic when file globs aren't enough (e.g. "does this Docker image tag
already exist in the registry?"). `preconditions` is the logical inverse —
commands that, on non-zero exit, **fail** the task and everything depending on it.

**Watch mode.** `task --watch` / `-w` (or `watch: true` on a task) re-runs a task
whenever its `sources` change, polling at `--interval` (default `5s`). This is a
local dev-loop feature, not a build-server primitive.

> [!IMPORTANT]
> Task has **no Git-aware affected-detection.** There is nothing like
> [moon][moon]'s / [Turborepo][turborepo]'s / [Nx][nx]'s `--affected <ref>` that
> computes "which members changed since `main`." Task's only change detection is
> the per-task `sources` fingerprint. Restricting a monorepo run to "what
> changed" must be hand-built — e.g. a task whose `status` shells out to
> `git diff --quiet HEAD~1 -- <dir>`.

---

## Caching & remote execution

Task's caching is **local-only and skip-only**, fundamentally different from the
artifact-replay caches elsewhere in this survey:

- **What is cached is a fingerprint, not an artifact.** The `.task/` directory
  stores source **checksums/timestamps**, _not_ the `generates` outputs. On a
  cache "hit," Task **skips re-running the command** and leaves the existing
  output files in place; on a miss it re-runs and rewrites the fingerprint. It
  never archives, restores, or transports build outputs. Contrast
  [Turborepo][turborepo] / [moon][moon] / [Bazel][bazel], which **store the
  outputs** keyed by hash and **replay** them (including stdout/stderr) — so a
  cache hit on a fresh checkout reconstructs artifacts that were never built
  locally. Task cannot do that: a fresh checkout has no `generates` outputs, so
  every task runs.

- **No remote cache, no REAPI, no remote execution.** There is no
  content-addressable store, no Bazel Remote-Execution-API client, no
  shared-team cache. The `.task/` directory is per-checkout and not designed to be
  shared (and `.gitignore`d in practice).

- **Remote _Taskfiles_ ≠ remote _cache_.** Task does ship a **Remote Taskfiles**
  experiment, but it is about fetching the _configuration_, not caching _build
  results_. A Taskfile can `include` an `http(s)://` or `git::` URL, or be the
  entrypoint via `--taskfile <url>` ([remote-taskfiles][remote]). The security
  model is trust-on-first-use plus checksum-change detection:

  > _"Whenever you run a remote Taskfile, Task will create and store a checksum
  > of the file that you are running. If the checksum changes, then Task will
  > print another warning to the console to inform you that the contents of the
  > remote file has changed."_

  and on caching the fetched file:

  > _"Whenever you run a remote Taskfile, the latest copy will be downloaded
  > from the internet and cached locally."_

  Relevant flags: `--download` (force a fresh fetch), `--offline` /
  `TASK_OFFLINE` (use only the cached copy), `--clear-cache` (purge), `--expiry`
  (cache TTL, default immediate), plus `--yes` / `--trust` / `--trusted-hosts`
  and the TLS options (`--cacert`, `--cert`, `--cert-key`) for the trust prompt.

> [!NOTE]
> The practical consequence for a monorepo: Task's incrementality is real on a
> warm checkout (don't rebuild what didn't change) but evaporates on CI, where
> every run is a fresh clone with an empty `.task/`. Teams that want
> cross-machine caching pair Task with an external layer — a CI artifact cache
> keyed on the same source globs, or simply reach for [moon][moon] /
> [Turborepo][turborepo] / [Bazel][bazel] instead.

---

## CLI / UX ergonomics

Task's command boundary is `task [flags] [task...] [VAR=value...]`. There is no
global-vs-targeted split to learn: you name the namespaced task(s) you want, and
pass CLI variables as trailing `KEY=value` pairs.

| Invocation                    | Meaning                                                                     |
| ----------------------------- | --------------------------------------------------------------------------- |
| `task build`                  | Run the `build` task (and its `deps`) in the current `Taskfile`             |
| `task docs:serve`             | Run the `serve` task from the `docs` include namespace                      |
| `task build test`             | Run `build` then `test` **sequentially**                                    |
| `task -p build test`          | Run them **in parallel** (`--parallel`)                                     |
| `task build VERSION=1.2.0`    | Pass `VERSION` as a CLI variable (highest precedence)                       |
| `task --list` / `-l`          | List documented tasks (those with `desc`)                                   |
| `task --list-all` / `-a`      | List **all** tasks, including undocumented                                  |
| `task --status build`         | Exit non-zero if `build` is **not** up to date (no execution; CI gate)      |
| `task --force` / `-f`         | Ignore fingerprints; run even if up to date                                 |
| `task --dry` / `-n`           | Print the commands without running them                                     |
| `task --watch` / `-w`         | Re-run on `sources` change                                                  |
| `task -d <dir>` / `-t <file>` | Point at a non-default working dir / Taskfile                               |
| `task -g <task>`              | Run from the **global** `Taskfile` in `$HOME` (cross-project helpers)       |
| `task -C N`                   | Cap concurrency at `N`                                                      |
| `task -o group`               | Buffer each task's output into a labelled group (vs. `interleaved` default) |

Namespacing gives the monorepo ergonomics: `task --list` from the root shows
`api:build`, `docs:serve`, `lib:test`, … and `task api:test docs:build` runs a
hand-picked subset. The selection model is **explicit enumeration** — there is no
`--filter <glob>`, no `-p <project>` package selector, no `--affected`/`--since`
graph slicing. To "test everything," authors write an aggregator task that
`deps`-on every member's test task, or that loops with the `for:` matrix construct
over a list. Compare [Turborepo][turborepo]'s `--filter`, [pnpm][pnpm]'s
`--filter`, [moon][moon]'s `:task` broadcast + `--query`, or
[Cargo][cargo]'s `-p` / `--workspace` — none of which Task offers natively.

> [!NOTE]
> Task's ergonomic win is the inverse of its filtering weakness: a contributor
> needs to learn _nothing_ beyond `task --list` and `task <name>`. There are no
> graph flags, no project selectors, no remote-cache config. For small-to-medium
> monorepos that simplicity is the feature; for large ones the lack of
> `--affected`/`--filter` becomes the bottleneck.

---

## Strengths

- **One static binary, zero runtime deps.** No Node, JVM, or plugin install; the
  same `Taskfile.yml` runs identically on Linux, macOS, and Windows (commands run
  through the embedded [`mvdan/sh`][mvdansh] interpreter, not a system shell).
- **Genuinely polyglot glue.** Because every member's real build is just a `cmd`,
  Go, Rust, Python, PHP, D, and shell coexist with no language assumptions — a
  natural fit for a heterogeneous monorepo's _outer_ loop.
- **Make's good ideas, made declarative.** A real DAG with parallel `deps`, plus
  content-aware `sources`/`generates` fingerprinting (`checksum`/`timestamp`),
  beats Make's tab-DSL and mtime-only staleness while keeping the model small.
- **Low learning curve / incremental adoption.** `task --list` + `task <name>` is
  the entire UX; a repo can wrap its existing scripts one task at a time.
- **Flexible escape hatches.** `status:` (custom freshness check), `preconditions:`,
  `requires:` (mandatory vars), `for:` matrix loops, and `defer:` cleanups cover
  cases pure file-globs can't.
- **Namespacing via `includes`** gives a workable per-member structure and
  `internal`/`flatten`/`aliases` to shape the public task surface.

## Weaknesses

- **No workspace model.** Members are enumerated by hand in `includes`; there is
  **no glob discovery** of sub-packages, no project graph, no member metadata.
- **No dependency resolution, no lockfile, no isolation.** Task orders and skips
  commands; everything package-related is delegated to the native managers, and
  cross-member linkage is a task edge, not a package edge.
- **Cache is skip-only and local-only.** It stores fingerprints, not outputs; no
  artifact replay, no remote/shared cache, no REAPI, no remote execution — so
  incrementality vanishes on a fresh CI checkout.
- **No Git-aware affected-detection.** No `--affected`/`--since`; "run only what
  changed across the repo" must be hand-built with `status:` + `git diff`.
- **No graph filtering ergonomics.** No `--filter`/`-p`/`--query`; task selection
  is explicit enumeration plus aggregator tasks.
- **`deps`-parallel vs `cmds`-`task:`-sequential is a recurring footgun**, as is
  the default that included tasks run in the **caller's** directory.
- **Double-build of shared includes:** a library included by two members is
  fingerprinted and built per-site (`.task/` is not shared) ([issue #852][issue-852]).

---

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                 | Trade-off                                                                                        |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Declarative YAML, not a build language (Starlark, etc.)           | Low ceremony; data is diffable and toolable; no DSL to learn              | No abstraction/rules/providers; logic must live in shell `cmds` or `status` hatches              |
| Single Go binary + embedded `mvdan/sh` shell                      | Zero install deps; truly cross-platform without a system `bash`           | Shell semantics differ subtly from real bash; advanced shell features unavailable                |
| `includes` namespaces instead of a workspace/project model        | Reuses one mechanism for "split a Taskfile" and "compose a monorepo"      | Members enumerated by hand (no glob); no project metadata, graph, or member discovery            |
| `deps` run in parallel; sequencing via `cmds: [{task: …}]`        | Maximizes concurrency by default; explicit order only where needed        | Surprising to newcomers; ordered prerequisites are verbose; diamond deps need `run: once`        |
| `sources`/`generates` fingerprint (`checksum` default)            | Content-aware "is it up to date?" beats Make's mtime; deterministic skips | Not hermetic — undeclared inputs cause stale hits; per-dir cache double-builds shared includes   |
| Cache stores fingerprints, not artifacts; local only              | Tiny, dependency-free, no cache server to run                             | No artifact replay; no remote/shared cache; incrementality lost on fresh CI checkouts            |
| No package resolver / lockfile (delegate to native managers)      | Stays a runner; polyglot by construction; no resolver to maintain         | No unified lockfile, no isolation, no `workspace:`-protocol; version drift is the user's problem |
| `status`/`preconditions`/`requires` escape hatches                | Arbitrary freshness/guard logic when file globs are insufficient          | Pushes correctness onto hand-written shell; easy to get subtly wrong                             |
| Explicit task enumeration on the CLI (no `--filter`/`--affected`) | Trivial mental model: `task --list` + `task <name>`                       | Doesn't scale to large graphs; "run what changed" / subset selection must be hand-built          |

---

## Sources

- [go-task/task — GitHub repository][repo] (source for the quoted README tagline; MIT, written in Go)
- [taskfile.dev — official documentation][docs] · [Guide][guide] (deps-parallel, up-to-date/checksum quotes)
- [Taskfile schema reference][schema] — top-level / `Include` / `Task` / `Cmd` keys, `method` & `run` enums
- [CLI reference][cli] — `--parallel`/`-p`, `--concurrency`/`-C`, `--force`, `--watch`, `--status`, `--list`
- [`taskfile/ast/task.go`][ast-task] — the `ast.Task` struct fields (`Deps`, `Sources`, `Generates`, `Namespace`, …)
- [`internal/fingerprint/`][fingerprint] — `sources_checksum.go` / `sources_timestamp.go` / `sources_none.go` strategies
- [Remote Taskfiles experiment][remote] — remote include trust model, checksum-change warning, `--offline`/`--download`
- [Releases][releases] — `v3.51.1` (May 16, 2026)
- [Issue #852: shared-include cache not shared][issue-852] · [Discussion #1517: root Taskfile for a monorepo][disc-1517]
- Related: [Make][make] · [just][just] · [mise][mise] · [moon][moon] · [Turborepo][turborepo] · [Nx][nx] · [Cargo][cargo] · [uv][uv] · [pnpm][pnpm] · [Bazel][bazel] · [Buck2][buck2] · [Gradle][gradle] · [Maven][maven] · [sbt][sbt] · [D landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/go-task/task
[readme]: https://github.com/go-task/task/blob/75b227ee13db066a830187315fa4345cef28878f/README.md
[docs]: https://taskfile.dev/
[guide]: https://taskfile.dev/docs/guide
[schema]: https://taskfile.dev/docs/reference/schema
[cli]: https://taskfile.dev/docs/reference/cli
[ast-task]: https://github.com/go-task/task/blob/75b227ee13db066a830187315fa4345cef28878f/taskfile/ast/task.go
[fingerprint]: https://github.com/go-task/task/tree/75b227ee13db066a830187315fa4345cef28878f/internal/fingerprint
[remote]: https://taskfile.dev/docs/experiments/remote-taskfiles
[releases]: https://github.com/go-task/task/releases
[issue-852]: https://github.com/go-task/task/issues/852
[disc-1517]: https://github.com/go-task/task/discussions/1517
[mvdansh]: https://github.com/mvdan/sh
[make]: ../make/
[just]: ../just/
[mise]: ../mise/
[moon]: ../moon/
[turborepo]: ../turborepo/
[nx]: ../nx/
[cargo]: ../cargo/
[uv]: ../uv/
[pnpm]: ../pnpm/
[bazel]: ../bazel/
[buck2]: ../buck2/
[gradle]: ../gradle/
[maven]: ../maven/
[sbt]: ../sbt/
[d-landscape]: ../../async-io/d-landscape.md
