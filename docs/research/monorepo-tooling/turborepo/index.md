# Turborepo (JavaScript/TypeScript)

A high-performance, Rust-implemented **task orchestrator** for JS/TS monorepos:
Turborepo does **not** manage packages — it leans on the package manager's own
workspaces — but it reads the workspace graph, derives a task DAG from a single
`turbo.json`, content-addresses every task's inputs, and replays cached outputs
(local or remote) so you "never do the same work twice."

| Field           | Value                                                                                                                                                   |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language        | Rust (the CLI and engine; `turbo` ships as a thin per-platform native binary launched via the `turbo` npm package)                                      |
| License         | MIT                                                                                                                                                     |
| Repository      | [vercel/turborepo][repo]                                                                                                                                |
| Documentation   | [turborepo.dev/docs][docs] · [`turbo.json` reference][config] · [`--filter` reference][filter]                                                          |
| Category        | JS/TS Task Orchestrator                                                                                                                                 |
| Workspace model | **Inherited** from the package manager (`package.json#workspaces` for npm/yarn/bun, `pnpm-workspace.yaml` for pnpm); Turborepo adds a task layer on top |
| First released  | December 2021 (acquired by Vercel December 2021; the 1.0 line predates the Rust rewrite)                                                                |
| Latest release  | `2.9.16` (May 28, 2026)                                                                                                                                 |

> **Latest release:** `2.9.16`, published May 28, 2026. The whole `2.x` line is
> the **Rust rewrite** (the original `1.x` was Go); the engine, cache, hasher,
> globwalker, SCM integration, and daemon all live in the `crates/` tree as
> `turborepo-*` crates. The headline `2.0` change was renaming the top-level
> `turbo.json` key from `pipeline` to `tasks`; the `daemon` top-level option is
> deprecated and slated for removal in `3.0` (still used by `turbo watch` and the
> LSP). See [Caching & remote execution](#caching--remote-execution).

---

## Overview

### What it solves

A large JS/TS monorepo has a structural problem the package manager alone does
not solve. npm/yarn/pnpm/bun **workspaces** install and symlink dozens of
inter-dependent packages into one `node_modules`, but they have no notion of a
**build/test graph**: `npm run build --workspaces` runs every package's `build`
script in arbitrary order, re-runs work that did not change, and cannot answer
"given this git diff, which packages actually need re-building?" In a repo with
hundreds of packages this means CI re-builds and re-tests the whole world on
every commit.

Turborepo layers a **task orchestrator** over the existing workspace. It does
three things the package manager does not:

1. **Reads the package graph.** Turborepo asks the package manager which packages
   exist (the `workspaces` globs) and reads the lockfile to learn how they depend
   on each other — _"Turborepo uses the lockfile to understand the dependencies
   between your Internal Packages within your Workspace"_ ([structuring][structure]).
2. **Derives and schedules a task DAG.** From a target like `build` plus a
   `dependsOn` rule like `["^build"]` in `turbo.json`, Turborepo computes the
   topological order of every task across every package and runs independent
   legs concurrently (a `petgraph` DAG; see [Task orchestration](#task-orchestration--scheduling)).
3. **Hashes and caches every task.** Before running a task Turborepo computes a
   content hash over all of the task's inputs (a global hash and a per-package
   hash); if that hash has been seen before — locally in `.turbo/cache` or in a
   shared remote cache — it **replays** the stored terminal output and output
   files instead of re-running, printing `>>> FULL TURBO`.

The `--filter` flag — especially its `[git-ref]` form and the newer `--affected`
shorthand — ties these together: given a git range, `turbo` restricts execution
to changed packages (and, with `...` syntax, their dependents/dependencies).

### Design philosophy

Turborepo's positioning, from the docs landing page ([turborepo.dev/docs][docs]):

> _"Turborepo is a high-performance build system for JavaScript and TypeScript
> codebases."_

The single most important architectural commitment is that **Turborepo is an
orchestrator, not a package manager.** From [Managing dependencies][deps]:

> _"Turborepo does not play a role in managing your dependencies, leaving that
> work up to your package manager of choice. … It's up to the package manager to
> handle things like downloading the right external dependency version,
> symlinking, and resolving modules."_

The caching philosophy is stated just as bluntly — Turborepo exists so you
_"never do the same work twice"_ ([Caching][caching]). Three consequences shape
the whole tool:

1. **No dependency model of its own.** There is no virtual store ([pnpm][pnpm]),
   no Plug'n'Play ([Yarn Berry][yarn-berry]), and no Turborepo lockfile.
   Installation, hoisting, symlinking, and `node_modules` layout are entirely the
   package manager's job; Turborepo merely _reads_ the manifest globs and the
   lockfile. This is what lets it be adopted incrementally into any existing
   npm/yarn/pnpm/bun monorepo.
2. **One root `turbo.json` is the task source of truth.** Targets, their cross-
   package ordering (`dependsOn`), their cache inputs/outputs, and their env
   dependencies are all declared once at the root (with optional per-package
   `turbo.json` overrides via `extends`). This is the sharpest contrast with
   [Nx][nx], whose config surface is larger (`nx.json` + per-project
   `project.json` + inference plugins).
3. **Content-addressed, shareable caching.** A task result is keyed by the hash
   of its inputs, so a result computed in CI can be replayed on a developer's
   laptop — the basis of Vercel Remote Cache.

Within this survey Turborepo is the **leaner sibling of [Nx][nx]**: same
"package graph + task DAG + content-hash + remote cache" model, but a much
smaller config surface and no generators/plugins/daemon-graph machinery.
Compare it with the publishing-focused [Lerna][lerna] (whose `run` Nx now backs),
with the script-runner [Wireit][wireit] (same idea, per-`package.json`, no remote
cache), and with the heavier polyglot engines [Bazel][bazel] / [Buck2][buck2] /
[Pants][pants] that demand explicit `BUILD` files and offer true remote
execution.

---

## Core concepts and files

| Concept              | File / crate / item                                               | Role                                                                           |
| -------------------- | ----------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Workspace config     | `turbo.json` (repo root)                                          | `tasks`, `globalDependencies`, `globalEnv`, `remoteCache`, `ui`, `concurrency` |
| Package config       | `turbo.json` inside a package (`extends: ["//"]`)                 | Per-package task overrides; inherits the root via `extends`                    |
| Workspace globs      | `package.json#workspaces` / `pnpm-workspace.yaml`                 | Where packages live — read from the package manager, not from `turbo.json`     |
| Lockfile             | `package-lock.json` / `yarn.lock` / `pnpm-lock.yaml` / `bun.lock` | The source of truth for inter-package dependency edges                         |
| Task                 | `tasks.<name>` keyed to a `package.json` script                   | A runnable unit; `turbo run <task>` finds the matching `scripts` entry         |
| Task dependency      | `dependsOn` (`"^build"`, `"build"`, `"pkg#task"`)                 | Edges into the task DAG (across deps with `^`, within-package, or explicit)    |
| Cache inputs         | `inputs` + `globalDependencies` + `env`/`globalEnv`               | The file globs and env vars folded into the package/global hash                |
| Cache outputs        | `outputs` (globs; `$TURBO_ROOT$` for root-relative)               | The files Turborepo stores and restores on a cache hit                         |
| Run engine           | `crates/turborepo-engine`                                         | The `petgraph` task DAG, dependency resolution, parallel execution             |
| Hasher               | `crates/turborepo-hash`, `crates/turborepo-task-hash`             | Task input hashing (the cache key)                                             |
| Local + remote cache | `crates/turborepo-cache`                                          | `FSCache`, `HttpCache`, a `Multiplexer`, and an `AsyncCache` worker pool       |
| SCM integration      | `crates/turborepo-scm`                                            | `git` queries for `--filter=[ref]` / `--affected` change detection             |
| Filtering / scope    | `crates/turborepo-scope`                                          | Resolves `--filter` expressions to a set of packages                           |
| Package discovery    | `crates/turborepo-repository`, `crates/turborepo-lockfiles`       | Workspace + lockfile parsing → the package graph                               |
| Daemon               | `crates/turborepo-daemon` + `turborepo-filewatch`                 | Long-lived filesystem watcher (powers `turbo watch`, the LSP)                  |

### The root `turbo.json`

`turbo.json` ([reference][config]) is the entire task-orchestration surface. Each
key under `tasks` _"is the name of a task that can be executed by `turbo run`"_,
matched to a `scripts` entry of the same name in each package's `package.json`. A
representative root config:

```json
{
  "$schema": "https://turborepo.dev/schema.json",
  "globalDependencies": ["tsconfig.base.json"],
  "globalEnv": ["CI"],
  "ui": "tui",
  "concurrency": "10",
  "tasks": {
    "build": {
      "dependsOn": ["^build"],
      "inputs": ["$TURBO_DEFAULT$", "src/**", "tsconfig.json"],
      "outputs": ["dist/**"],
      "env": ["NODE_ENV"],
      "cache": true
    },
    "test": {
      "dependsOn": ["build"],
      "outputs": [],
      "cache": true
    },
    "dev": {
      "cache": false,
      "persistent": true
    }
  }
}
```

A package can override the root with its own `turbo.json` that uses `extends`:

```json
{
  "extends": ["//"],
  "tasks": {
    "build": { "outputs": ["build/**"] }
  }
}
```

The `"//"` token refers to the workspace root, the convention Turborepo uses
throughout to name root-level tasks and inheritance (`extends: ["//"]`,
`//#some-root-task`).

---

## How it works

### Package discovery: deferring to the package manager

Turborepo's first job is to enumerate packages, and it does so by reading the
**package manager's** workspace definition rather than inventing one
([structuring][structure]):

- **npm / yarn / bun:** the root `package.json` `"workspaces"` array of globs:

  ```json
  { "workspaces": ["apps/*", "packages/*"] }
  ```

- **pnpm:** a `pnpm-workspace.yaml` with a `packages:` list:

  ```yaml
  packages:
    - 'apps/*'
    - 'packages/*'
  ```

_"Every directory **with a `package.json`** in the `apps` or `packages`
directories will be considered a package"_ ([structuring][structure]). The
`crates/turborepo-repository` crate detects the package manager, expands the
globs, and reads each `package.json`; `crates/turborepo-lockfiles` parses the
lockfile so Turborepo can resolve which `dependencies`/`devDependencies` entries
point at _other workspace packages_ (Internal Packages) versus the registry. That
lockfile-derived edge set is the **package graph** — the substrate on which the
task DAG is later built. A workspace _"can either be a single package or a
collection of packages,"_ so `turbo` also works in a single-package repo.

### From `tasks` to the task DAG

A **task** is `<package>#<script>` — e.g. `@acme/web#build`. The
`crates/turborepo-engine` crate turns the `tasks` config into a directed acyclic
graph. From the engine crate's documentation:

> _"turborepo-engine: … provides the core engine for executing tasks in a
> Turborepo monorepo. It handles task graph construction, dependency resolution,
> and parallel execution."_

The graph is a `petgraph::Graph<TaskNode, ()>` whose nodes are either individual
tasks or a special `Root` anchor for tasks with no prerequisites; an edge from
task `B` to task `A` means **"`B` depends on `A`."** `dependsOn` is what creates
those edges ([config][config]):

- **`^build`** — _topological_ dependency: _"run task in dependency packages
  first."_ The `^` caret is the load-bearing operator; `web#build` waits on
  `ui#build` for every Internal Package `web` depends on.
- **`build`** — same-package dependency: another script in the _same_ package
  runs first (e.g. `test` `dependsOn` `build`).
- **`utils#build`** — an explicit cross-package edge to a named task, escape
  hatch for relationships the graph cannot infer.

Because the edges come from the package graph (lockfile) crossed with
`dependsOn`, the ordering is derived, not hand-maintained — change a
`dependencies` entry and the build order follows automatically.

### Concurrent, topological execution

The engine topologically schedules the DAG and runs independent legs
simultaneously, bounded by `--concurrency` (default `10`; accepts an integer or a
percentage like `"50%"`). `--parallel` ignores the dependency edges entirely and
runs everything at once (used for long-running `dev` servers). Tasks marked
`persistent: true` are long-running and _"prevent other tasks from depending on
them"_; the `with` key pairs sibling long-running tasks so they start together,
and `interruptible: true` lets `turbo watch` restart a persistent task on change.

```bash
turbo run build                       # whole graph, topological, 10-wide
turbo run build --concurrency=100%    # use all cores
turbo run dev --parallel              # ignore edges; start every dev server
turbo run lint test --filter=@acme/web   # two tasks, one package (+ its deps)
```

### Hashing: the cache key

Before running a cacheable task Turborepo computes **two** content hashes
([Caching][caching]); if either changes, the task misses cache:

| Hash         | Folds in                                                                                                                                                                                    |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Global hash  | root + package `turbo.json`, the workspace-root lockfile, `globalDependencies` file contents, `globalEnv` values, behavior flags (`--cache-dir`, framework inference), and passthrough args |
| Package hash | the package's `turbo.json`, its lockfile slice, its `package.json`, and its source-controlled files (narrowed by `inputs`)                                                                  |

`inputs` defaults to all source-controlled files in the package; you narrow it
with globs, and `$TURBO_DEFAULT$` re-injects the default set so you can add to
(rather than replace) it. `env` lists the environment variables a task _depends
on_ (wildcards `MY_API_*` and negation `!VAR` allowed) and feeds the hash;
`passThroughEnv` makes variables available to the task **without** affecting the
hash. The hashing lives in `crates/turborepo-hash` / `crates/turborepo-task-hash`,
and `crates/turborepo-scm` supplies the git file-state queries that make hashing
fast and correct.

### Cache lookup, storage, and replay

With a hash in hand, Turborepo consults the cache. The `crates/turborepo-cache`
crate's module documentation describes the layered design:

> _"Cache management for task outputs. Provides local and remote caching
> capabilities and a 'multiplexed' cache which operates over both. … When both
> are in use local is preferred and remote writes are done asynchronously. …
> Under the hood cache artifacts are stored [as] gzipped tarballs."_

So there are four cooperating pieces:

- **`FSCache`** — the local filesystem cache (default `.turbo/cache`), storing a
  gzipped tarball of each task's `outputs` plus its captured terminal logs.
- **`HttpCache`** — the remote cache client (see below).
- A **`Multiplexer`** — _"a wrapper that allows reads and writes from the file
  system and remote cache"_, preferring local on read and writing remote
  asynchronously.
- An **`AsyncCache`** — _"a wrapper for the cache that uses a worker pool to
  perform cache operations,"_ so cache I/O doesn't stall task scheduling.

On a hit, Turborepo restores the output files into place **and** replays the
captured stdout/stderr, so the run looks identical, only faster. A run where
**every** task hits the cache prints the trademark `>>> FULL TURBO`. The local
cache is automatically shared across git worktrees, and `cacheMaxAge` /
`cacheMaxSize` (e.g. `"7d"`, `"10GB"`) bound its growth.

---

## Workspace declaration & topology

Turborepo has **no workspace-members array of its own.** Topology is inherited
from the package manager:

- **npm / yarn / bun:** root `package.json` `"workspaces": ["apps/*", "packages/*"]`.
- **pnpm:** `pnpm-workspace.yaml` with a `packages:` list.

Each directory containing a `package.json` under those globs is a package. The
root `package.json` is the de-facto **virtual root**; whether it also ships
shippable code is irrelevant to `turbo`. Turborepo contributes only `turbo.json`
(at the root, and optionally per-package via `extends`). There is no separate
"virtual workspace" vs "root-package" distinction as in [Cargo][cargo] — the
package-manager root is always the implicit virtual root.

The lockfile is mandatory and load-bearing: _"A lockfile is key to reproducible
behavior … Turborepo uses the lockfile to understand the dependencies between your
Internal Packages"_ ([structuring][structure]). No lockfile means no reliable
package graph, hence no correct `^build` ordering or `--filter` traversal.

A **`boundaries`** config block (with the `turbo boundaries` command) optionally
declares which tagged packages may depend on which — a lightweight constraints
layer reminiscent of Nx's `@nx/enforce-module-boundaries` and Yarn's constraints
engine.

## Dependency handling & isolation

This is Turborepo's defining choice: **it does not isolate, store, hoist, or
install dependencies at all.** From [Managing dependencies][deps]:

> _"Turborepo does not play a role in managing your dependencies, leaving that
> work up to your package manager of choice."_

- **Installation, hoisting, symlinking** are 100% the package manager's job —
  whatever model that manager uses (npm/yarn hoisting, [pnpm][pnpm]'s content-
  addressed store, [Yarn Berry][yarn-berry]'s PnP) is what you get.
- **Local cross-references** ("Internal Packages") use the package manager's own
  protocol, not a Turborepo invention:
  - **pnpm / bun:** `"@repo/ui": "workspace:*"`
  - **yarn / npm:** `"@repo/ui": "*"` (implicit workspace linking)
    Turborepo merely _reads_ these from the lockfile to draw the package-graph edge
    and order `^build`.
- **External dependency versions** still feed the hash (via the lockfile slice in
  the package hash and the whole lockfile in the global hash), so a dependency
  bump correctly invalidates the affected tasks even though Turborepo never
  parses the lockfile for _installation_.

The upshot mirrors [Nx][nx]: Turborepo is **complementary** to the package
manager, never a replacement — the opposite of [Cargo][cargo]/[Go
workspaces][go-work], where the language tool owns both the dependency graph and
the build graph.

> [!NOTE]
> Because dependency layout is delegated, Turborepo inherits whatever resolution
> guarantees (or lack thereof) the package manager provides. The docs explicitly
> warn against referencing `node_modules` paths directly, since _"the location of
> the dependency on disk can change with other dependency changes around the
> Workspace."_

## Task orchestration & scheduling

Yes — a real task DAG with concurrent execution and input-hash change detection.

- **DAG construction.** `crates/turborepo-engine` expands every requested task
  through its `dependsOn` rules over the package graph into a
  `petgraph::Graph<TaskNode, ()>` rooted at a synthetic `Root` node (edge `B→A`
  ≡ "`B` depends on `A`").
- **Topological, concurrent execution.** The engine runs tasks whose
  prerequisites are complete, up to `--concurrency` (default `10`). `--parallel`
  drops the edges for long-running processes; `persistent`/`with`/`interruptible`
  manage dev servers and `turbo watch`.
- **Change detection is double-layered.** `--filter=[ref]` / `--affected` prune
  the package set by git diff _before_ scheduling (via `crates/turborepo-scm`),
  and the **content hash** prunes execution _during_ scheduling (a hash hit is
  replayed, not run). A task re-runs only if its inputs changed.
- **Output rendering.** `ui: "tui"` gives an interactive task viewer (the
  `crates/turborepo-vt100` + `turborepo-ui` terminal stack); `ui: "stream"` (the
  legacy default) interleaves logs as they arrive. `outputLogs` controls
  verbosity per task (`full`, `hash-only`, `new-only`, `errors-only`, `none`).

```bash
turbo run build                          # build everything, in graph order
turbo run test --filter=@acme/web        # one package (+ its dependencies)
turbo run build --affected               # only packages changed vs the base ref
turbo run lint --filter='./packages/*'   # by path glob
```

## Caching & remote execution

Turborepo is fundamentally a **caching** tool; "remote execution" in the
Bazel/REAPI sense is **explicitly not** part of it. From [Remote Caching][remote]:

> _"Remote Caching is **caching only**, not remote execution. Tasks are not run
> on remote machines; only their cached results are shared."_

- **Local cache.** `.turbo/cache`, gzipped tarballs + captured logs, keyed by the
  content hash. `--force` bypasses it; `cacheMaxAge`/`cacheMaxSize` bound it.
- **Remote cache.** The `HttpCache` client talks to a remote cache server over an
  HTTP API. The first-party backend is **Vercel Remote Cache** — _"free to use on
  all plans, even if you do not host your applications on Vercel"_ — enabled with
  `turbo login` + `turbo link`.
- **Self-hosted cache.** Turborepo publishes an **OpenAPI specification** for the
  Remote Cache; _"all versions of turbo are compatible with the v8 endpoints,"_
  and several open-source servers implement it (`ducktors/turborepo-remote-cache`,
  `brunojppb/turbo-cache-server`). Point `turbo` at one with `turbo login --manual`
  or the `remoteCache.apiUrl` key.
- **Cache signing.** With `remoteCache.signature: true` plus a
  `TURBO_REMOTE_CACHE_SIGNATURE_KEY`, Turborepo signs artifacts with HMAC-SHA256
  before upload, so a consumer can verify an artifact's provenance — a guard
  against the cache-poisoning class of attack that bit [Nx][nx]'s deprecated
  storage plugins.

> [!WARNING]
> Turborepo does **no** sandboxed remote _execution_. If you need to ship
> individual hermetic actions to a remote worker farm, that is the domain of
> [Bazel][bazel] / [Buck2][buck2] over the REAPI backends [Buildbarn][buildbarn]
> / [BuildBuddy][buildbuddy] / [NativeLink][nativelink]. Turborepo's remote cache
> is artifact sharing, full stop — which is also why it is so easy to self-host.

## CLI / UX ergonomics

Turborepo's command surface is small: essentially `turbo run <tasks>` (plus
`prune`, `watch`, `boundaries`, `login`, `link`). Selection is driven by one
powerful flag, **`--filter`** ([filter][filter]):

| Goal                                | Command                                         |
| ----------------------------------- | ----------------------------------------------- |
| Run a task everywhere               | `turbo run build`                               |
| One package by name                 | `turbo run build --filter=@acme/web`            |
| A package **and its dependencies**  | `turbo run dev --filter=web...`                 |
| A package **and its dependents**    | `turbo run build --filter=...ui`                |
| By directory path glob              | `turbo run lint --filter='./packages/*'`        |
| Changed since a git ref             | `turbo run build --filter='[HEAD^1]'`           |
| Changed in a branch range           | `turbo run test --filter='[main...my-feature]'` |
| Changed vs the base ref (shorthand) | `turbo run build --affected`                    |
| Exclude a package                   | `turbo run build --filter='!@acme/docs'`        |
| Direct task addressing (≥ 2.2.4)    | `turbo run web#build docs#lint`                 |
| Limit concurrency                   | `turbo run build --concurrency=4` (or `50%`)    |
| Ignore the cache                    | `turbo run build --force`                       |

The `--filter` micro-DSL composes four orthogonal operators: a **name or path**
selects packages; a **leading/trailing `...`** widens the selection along graph
edges (`web...` = web + its dependencies, `...ui` = ui + its dependents); a
**`[ref]`** bracket scopes to git-changed packages; and a **`!`** prefix excludes.
Multiple `--filter`s union. `--affected` is sugar for the common
`--filter=[<base>...<head>]` case. Compared with [Nx][nx]'s verb + `-t` + `-p`
shape or [Bazel][bazel]'s `//path:target` labels, Turborepo's `run` + `--filter`
reads as a single composable selection language; the same `[ref]` syntax that
selects packages is also how change-bounded CI is expressed.

---

## Strengths

- **Drop-in over any package manager.** `turbo` adds orchestration to an existing
  npm/yarn/pnpm/bun workspace without touching the dependency model; adoption is
  "a few minutes."
- **Tiny config surface.** One root `turbo.json` (plus optional `extends`
  overrides) expresses the whole task graph — far less than [Nx][nx]'s
  `nx.json` + `project.json` + plugins.
- **Fast, correct content-hash caching.** Rust hasher, gzipped-tarball artifacts,
  log replay, `>>> FULL TURBO`, local-then-remote multiplexed cache with an async
  worker pool.
- **Composable `--filter` + `--affected`.** One micro-DSL for name/path/graph/git
  selection; change-bounded CI falls out of the same syntax.
- **Easy, signable, self-hostable remote cache.** An open OpenAPI spec and HMAC
  artifact signing mean you can run your own cache server and verify provenance.
- **Rust engine.** The `2.x` rewrite put the hot paths (graph, hashing,
  globwalk, SCM) in Rust; a long-lived daemon + filewatcher powers `turbo watch`
  and the LSP.

## Weaknesses

- **Not a package manager.** Dependency isolation, hoisting, and lockfiles are
  entirely delegated; Turborepo inherits whatever resolution pain the package
  manager has and cannot offer pnpm-style strictness on its own.
- **No remote execution.** It caches and replays results; it does **not** sandbox
  and ship actions to remote workers like [Bazel][bazel]/[Buck2][buck2].
- **Hash correctness depends on declared inputs/env.** An under-declared `inputs`
  or missing `env` entry yields stale cache hits; over-declaring yields needless
  misses — the same footgun as every content-hash cache.
- **JS/TS-centric.** Tasks are `package.json` scripts; bringing non-JS work in
  means wrapping it in a script, with weaker graph/inference than [Nx][nx]'s
  polyglot plugins or the polyglot engines.
- **Caching, not graph inference.** Unlike [Nx][nx]'s static import analysis,
  Turborepo derives edges from the **lockfile + `package.json` deps**, so an
  undeclared cross-package import is invisible to the graph (and to `^build`).
- **Churn on the config key.** The `pipeline` → `tasks` rename (`2.0`) and the
  `daemon` deprecation mean older tutorials mislead; the `futureFlags` surface
  signals more defaults in flight.

## Key design decisions and trade-offs

| Decision                                                     | Rationale                                                                   | Trade-off                                                                               |
| ------------------------------------------------------------ | --------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Orchestrate, don't manage packages                           | Drop into any npm/yarn/pnpm/bun workspace; composable, incremental adoption | Inherits the package manager's isolation model; no store/PnP/lockfile of its own        |
| Derive the package graph from the **lockfile**               | Zero hand-maintained `BUILD` files; ordering follows `dependencies` edits   | An undeclared cross-package import is invisible; correctness hinges on the lockfile     |
| One root `turbo.json` (`tasks` + `extends`)                  | Minimal config surface; the whole task DAG declared in one place            | Less per-project expressivity than `project.json`; no task inference from tool config   |
| `dependsOn: ["^build"]` topological rule                     | Declarative cross-package ordering driven by the existing package graph     | Easy to forget a `^`; a missing edge yields "module not found" at task time             |
| Content-hash caching (global + package hash)                 | Correct, fast, shareable cache keys; local-then-remote replay               | Cache correctness hinges on fully-declared `inputs`/`env`; stale hits if under-declared |
| Cache results, **not** remote-execute actions                | Trivial trust/setup vs REAPI; replay is enough for most JS/TS work          | No sandboxed remote action execution; large native builds favor Bazel/Buck2             |
| `Multiplexer` + `AsyncCache` (local-preferred, async remote) | Local hits are instant; remote writes never block scheduling                | Eventual remote consistency; a crash can drop an in-flight async upload                 |
| HMAC-signed, OpenAPI-spec'd remote cache                     | Easy self-hosting; artifact provenance guards against cache poisoning       | Signing is opt-in; an unsigned shared cache is a trust boundary (cf. Nx's CVE)          |
| `--filter` micro-DSL (`...`, `[ref]`, `!`) + `--affected`    | One composable selection language for name/path/graph/git scoping           | Dense syntax; `[ref]` quoting and `...` direction are easy to get backwards             |
| Rust rewrite (`2.x`) + daemon                                | Fast hashing/graphing/globwalk; `turbo watch` and LSP off a live watcher    | Native binary per platform; `daemon` option deprecated and churning toward `3.0`        |

---

## Sample workspace

A minimal, runnable two-package Turborepo workspace lives in
[`./sample/`](./sample/): a `@sample/greeter` library and a `@sample/cli` app
that imports it locally via the package manager workspace link (`workspace:*`),
wired with a `dependsOn: ["^build"]` topological build and a `dev` task. See the
directory for the exact root `turbo.json`, the `package.json` workspace globs, the
`pnpm-workspace.yaml`, and the two member `package.json` files (the cross-package
reference is `@sample/cli`'s `"@sample/greeter": "workspace:*"` dependency).

---

## Sources

- [vercel/turborepo — GitHub repository][repo] (source for all quoted crate paths)
- [turborepo.dev/docs — documentation][docs] (positioning quote)
- [`turbo.json` configuration reference][config] — top-level + per-task keys, `dependsOn`, `inputs`/`$TURBO_DEFAULT$`, `outputs`/`$TURBO_ROOT$`
- [Structuring a repository][structure] — package discovery via the package manager; lockfile-derived graph (verbatim quotes)
- [Managing dependencies][deps] — "Turborepo does not play a role in managing your dependencies" (verbatim)
- [Caching][caching] — global vs package hash, gzipped tarballs, `>>> FULL TURBO`, "never do the same work twice" (verbatim)
- [Remote Caching][remote] — caching-only (not remote execution), Vercel Remote Cache, OpenAPI v8 spec, HMAC signing (verbatim)
- [`--filter` reference][filter] — the `...`/`[ref]`/`!` micro-DSL, `--affected`
- `crates/turborepo-engine` — `petgraph` task DAG, dependency resolution, parallel execution (crate doc quote)
- `crates/turborepo-cache` — `FSCache`/`HttpCache`/`Multiplexer`/`AsyncCache`, tarball storage (crate doc quotes)
- `crates/turborepo-scm`, `crates/turborepo-scope`, `crates/turborepo-repository`, `crates/turborepo-lockfiles`, `crates/turborepo-hash`, `crates/turborepo-task-hash` — SCM/filter/discovery/hash internals
- Sibling docs: [Nx][nx] · [Lerna][lerna] · [Wireit][wireit] · [Lage][lage] · [Rush][rush] · [pnpm][pnpm] · [Yarn Berry][yarn-berry] · [npm][npm] · [Bun][bun] · [Cargo][cargo] · [Go workspaces][go-work] · [Bazel][bazel] · [Buck2][buck2] · [Pants][pants] · [Buildbarn][buildbarn] · [BuildBuddy][buildbuddy] · [NativeLink][nativelink] · [the D landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/vercel/turborepo
[docs]: https://turborepo.dev/docs
[config]: https://turborepo.dev/docs/reference/configuration
[filter]: https://turborepo.dev/docs/reference/run#--filter-string
[structure]: https://turborepo.dev/docs/crafting-your-repository/structuring-a-repository
[deps]: https://turborepo.dev/docs/crafting-your-repository/managing-dependencies
[caching]: https://turborepo.dev/docs/crafting-your-repository/caching
[remote]: https://turborepo.dev/docs/core-concepts/remote-caching
[nx]: ../nx/
[lerna]: ../lerna/
[wireit]: ../wireit/
[lage]: ../lage/
[rush]: ../rush/
[pnpm]: ../pnpm/
[yarn-berry]: ../yarn-berry/
[npm]: ../npm/
[bun]: ../bun/
[cargo]: ../cargo/
[go-work]: ../go-work/
[bazel]: ../bazel/
[buck2]: ../buck2/
[pants]: ../pants/
[buildbarn]: ../buildbarn/
[buildbuddy]: ../buildbuddy/
[nativelink]: ../nativelink/
[d-landscape]: ../../async-io/d-landscape.md
