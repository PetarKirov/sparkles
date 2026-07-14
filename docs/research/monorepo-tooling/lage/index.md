# Lage (JavaScript/TypeScript)

Microsoft's monorepo task runner: a thin orchestration layer that overlays an **explicit task pipeline** onto an existing npm/yarn/pnpm workspace, compiles `(package × task)` pairs into a **target graph**, and runs it concurrently across a persistent worker-thread pool with content-addressed local + remote caching (via `backfill`).

| Field           | Value                                                                                                                          |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Language        | TypeScript (Node.js; ships as `@lage-run/*` packages)                                                                          |
| License         | MIT                                                                                                                            |
| Repository      | [microsoft/lage][repo]                                                                                                         |
| Documentation   | [microsoft.github.io/lage][docs]                                                                                               |
| Category        | JS/TS Task Orchestrator                                                                                                        |
| Workspace model | **Parasitic** — no workspace declaration of its own; reads the host package manager's `workspaces` globs via `workspace-tools` |
| First released  | 2020 (Microsoft OSS; `lage` 1.x)                                                                                               |
| Latest release  | `lage` `2.15.12`                                                                                                               |

> **Latest release:** `lage` `2.15.12` (published Dec 29, 2024, per the npm registry). The runtime is split across `@lage-run/*` scoped packages (`@lage-run/cli`, `@lage-run/scheduler`, `@lage-run/target-graph`, `@lage-run/hasher`, `@lage-run/cache`), all versioned together in the monorepo at `0.x`; the user-facing `lage` umbrella package is the one pinned at `2.15.x`. Lage is a **sibling** of [Turborepo][turborepo], [Nx][nx], and [Wireit][wireit] in the JS/TS task-orchestrator family; unlike a package manager ([npm][npm] / [pnpm][pnpm] / [Yarn Berry][yarn-berry]), it does **not** install dependencies or own a lockfile — it orchestrates the scripts a package manager already wired up.

---

## Overview

### What it solves

A JavaScript monorepo's per-package `scripts` (`build`, `test`, `lint`) carry an **implicit** ordering: a package's `test` needs its own `build` first, and a package's `build` needs its dependencies' `build`s first. Legacy runners (`lerna` before its rewrite, `pnpm --recursive`, `rush`, `wsrun`) execute one task name at a time across all packages, creating a "build phase" barrier — every package's `build` must finish before any `test` may start — which leaves CPU cores idle.

Lage's pitch, from its [introduction][intro]:

> _"`lage` has a secret weapon: it has a "pipeline" configuration syntax to define the implicit relationship between tasks. Combined with a package graph, `lage` knows how to schedule which task to run first and which one can be run in parallel."_

The product is the **target graph**: the Cartesian-ish product of the **task graph** (declared in `lage.config.js`'s `pipeline`) and the **package graph** (derived from `dependencies`/`devDependencies` in each `package.json`). A node is a _target_ — one task on one package, e.g. `foo#build`. Lage then layers three speedups on top, framed in the docs as escalating "levels": **scoping** (run only affected packages), **caching** (skip targets whose inputs are unchanged), and **remote cache fallback** ("never build the same code twice" across CI and developer machines).

### Design philosophy

The central thesis is **explicitness over convention**. From the [pipeline guide][pipeline]:

> _"Futhermore, the developer is expected to keep track of an **implicit** graph of the tasks. … `lage` gives developers a way to specify these relationships **explicitly**. The advantage here is twofold: `lage` can use this explicit declaration to perform an optimized build based on the abundant availability of multi-core processors. Incoming developers can look at `lage.config.js` and understand how tasks are related."_

Three consequences shape the whole tool:

1. **Lage is not a package manager.** It owns no workspace manifest, no dependency resolver, no lockfile. Workspace topology, hoisting, and isolation are entirely the host manager's job (`npm`/`yarn`/`pnpm`); Lage merely _reads_ the resulting layout through the [`workspace-tools`][repo] library (also a Microsoft project, vendored in the same monorepo). This makes it trivially adoptable — _"all it takes is just one npm package install with a single configuration file"_ — but means Lage inherits whatever `node_modules` model the manager imposes.
2. **The pipeline is global, not per-package.** Unlike [Turborepo][turborepo]'s and [Nx][nx]'s tendency to colocate task config near each package, Lage's `pipeline` lives in **one** root `lage.config.js`. One file is the source of truth for how every task on every package relates.
3. **Caching is content-addressed and remote-first-class.** A target's cache key hashes its declared `inputs` (file contents), its CLI args, the package's resolved dependency versions, the hashes of its upstream targets, and a repo-wide `environmentGlob`. A `RemoteFallbackCacheProvider` transparently layers a remote store (Azure Blob, S3, GCS via `backfill`) behind the local on-disk cache.

---

## Core abstractions and types

| Concept                   | Type / file                                                                | Role                                                                                              |
| ------------------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Config + pipeline         | `ConfigOptions` / `PipelineDefinition` ([`config`][config])                | The single `lage.config.js`: `pipeline`, `cacheOptions`, `priorities`, `npmClient`, `concurrency` |
| Task dependency           | `TargetConfig.dependsOn` (was `deps`) ([`target-graph`][tgraph])           | Dep-spec strings: `build`, `^build`, `^^transpile`, `pkg#task`                                    |
| Runtime node              | `Target` (`packageName` + `task` ⇒ `id` like `foo#build`)                  | One task on one package; carries `inputs`, `outputs`, `cache`, `weight`, `priority`               |
| Graph builder             | `WorkspaceTargetGraphBuilder` ([`WorkspaceTargetGraphBuilder.ts`][wtgb])   | Expands dep-specs into edges, scopes the subgraph, attaches priorities                            |
| Dep-spec expansion        | `expandDepSpecs` ([`expandDepSpecs.ts`][expand])                           | Interprets `^`/`^^`/`#` against the package `DependencyMap`                                       |
| Scheduler                 | `SimpleScheduler` ([`SimpleScheduler.ts`][sched])                          | Ready-set loop: runs every target whose deps are all `successful`                                 |
| Wrapped run + cache check | `WrappedTarget` ([`WrappedTarget.ts`][sched])                              | Per-target cache fetch → run → cache put, with logging                                            |
| Hasher                    | `TargetHasher` ([`TargetHasher.ts`][hasher])                               | Content hash of inputs + deps + env globs; uses `glob-hasher` (Rust native)                       |
| Cache provider            | `RemoteFallbackCacheProvider` / `BackfillCacheProvider` ([`cache`][cache]) | Local-then-remote fetch; remote populated on `LAGE_WRITE_REMOTE_CACHE`                            |
| Worker pool               | `AggregatedPool` ([`worker-threads-pool`][pool])                           | `worker_threads` pool, partitioned per task name, with idle-memory restart                        |
| Runner                    | `NpmScriptRunner` / `WorkerRunner` / `NoOpRunner` ([`runners`][runners])   | How a target actually executes: spawn an npm script, call a worker fn, or no-op                   |
| Background service        | `lage server` / `lage-server` ([`rpc`][rpc], `server` command)             | Persistent daemon hosting `worker`-type targets across invocations (gRPC-style routes)            |

---

## How it works

A `lage build test lint` invocation flows through four stages: **discover the workspace → build the target graph → hash + schedule → run (cache-aware) on the worker pool.**

### 1. Configuration

There is exactly one config file at the repo root. The canonical form (what `npx lage init` emits):

```js
// lage.config.js
/** @type {import("lage").ConfigFileOptions} */
const config = {
  pipeline: {
    build: ['^build'],
    test: ['build'],
    lint: [],
  },
};
module.exports = config;
```

Each key is a **task name**; each value is a list of **dep-specs** (or a richer `TargetConfig` object). `getConfig` ([`getConfig.ts`][getconfig]) fills defaults: `concurrency` defaults to `os.availableParallelism()`, `npmClient` to `"npm"`, and `repoWideChanges` to a list of "if these change, scoping is void" files (`lage.config.js`, `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `lerna.json`, `rush.json`).

The advanced object form attaches per-target metadata — this excerpt from Lage's own `lage.config.js` shows a `worker`-type target with declared `outputs`, a transitive dep (`^^transpile`), a dynamic `weight`, and a `priority`:

```js
pipeline: {
    transpile: {
        type: "worker",
        options: { worker: path.join(__dirname, "scripts/worker/transpile.js") },
        outputs: ["lib/**/*.{js,map}"],
    },
    "lage#bundle": {
        dependsOn: ["^^transpile", "types"],
        outputs: ["dist/**/*"],
    },
    "@lage-run/e2e-tests#test": {
        dependsOn: ["^^transpile", "lage#bundle"],
        weight: os.availableParallelism(), // hog all cores
        priority: -9999, // run last
    },
}
```

### 2. Building the target graph

`WorkspaceTargetGraphBuilder` ([`WorkspaceTargetGraphBuilder.ts`][wtgb]) walks `Object.keys(packageInfos)` and, for each requested task, materializes a `Target` per package (`createPackageTarget`), per `pkg#task` literal, or a single global target for `//`/`#`-prefixed ids. It then calls `expandDepSpecs` to translate every dep-spec into concrete `[from, to]` edges. The dep-spec grammar is the heart of the tool ([`ConfigOptions.ts`][config] doc comment):

| Dep-spec      | Meaning                                                                                            |
| ------------- | -------------------------------------------------------------------------------------------------- |
| `build`       | Same-package dependency: this package's `build` (no ordering guarantee across packages)            |
| `^build`      | **Topological**: the `build` task of this package's _direct_ workspace dependencies                |
| `^^transpile` | **Transitive topological**: `transpile` for _all_ transitive deps, but **not** the current package |
| `pkg-a#build` | Specific cross-package target: depend on package `pkg-a`'s `build`                                 |
| `foo#build`   | (as a pipeline _key_) override the pipeline entry for one specific package's task                  |

`^` resolves against `dependencyMap.dependencies.get(packageName)`; `^^` recursively walks the dependency map (`getTransitiveGraphDependencies`, memoized, cycle-guarded with a `"walk-in-progress"` sentinel). A synthetic `START_TARGET_ID` root node is added as a predecessor of every target so the scoped subgraph always has a single entry point.

A notable subtlety is the **phantom target optimization** (`enablePhantomTargetOptimization`): an `npmScript` target generated for a package that doesn't actually define that script is excluded from `^`/`^^` expansion, so removing it later (because `shouldRun` is false) doesn't reconnect its same-package deps to cross-package dependents and create phantom work.

### 3. Hashing (change detection)

Each target is hashed by `TargetHasher.hash` ([`TargetHasher.ts`][hasher]). The cache key combines, in order:

```text
hashStrings([
    ...environmentGlob file hashes,        // repo-wide inputs (CI workflow, lockfile, lage.config.js)
    `${target.id}|${JSON.stringify(cliArgs)}`,
    cacheKey,                              // optional user salt
    ...target.inputs file content hashes,  // the target's own declared inputs
    ...resolvedDependencies,               // internal + external dep versions (from the lockfile)
    ...targetDepHashes,                    // the hashes of upstream targets (graph-transitive)
])
```

File hashing goes through `glob-hasher` — a **native (Rust) addon** — and `FileHasher` persists an mtime/size/hash manifest so unchanged files skip rehashing. Because `targetDepHashes` folds in upstream target hashes, a change deep in the graph correctly invalidates everything downstream. The `environmentGlob` (e.g. `yarn.lock`, `.github/workflows/*`, `lage.config.js`) is the global salt — touching CI config busts every cache entry.

### 4. Scheduling and execution

Despite the legacy "p-graph" comment in the source, the current `SimpleScheduler` ([`SimpleScheduler.ts`][sched]) is a **ready-set fixpoint loop**, not a precomputed promise DAG:

```ts
// SimpleScheduler — getReadyTargets (abridged)
const ready = targetDeps.every(dep => {
  const fromTarget = this.targetRuns.get(dep)!;
  return fromTarget.successful || dep === getStartTargetId();
});
```

`scheduleReadyTargets` collects every `pending` target whose dependencies are all `successful`, launches each via `#generateTargetRunPromise`, and — crucially — each finishing promise recursively calls `scheduleReadyTargets()` again, so newly-unblocked targets dispatch the instant their last predecessor completes. Targets are popped in `sortTargetsByPriority` order so critical-path / high-`priority` work goes first. `continueOnError` controls whether a failure aborts the run or merely records the error and lets independent legs finish; an `AbortController` propagates cancellation.

Execution itself is delegated to an `AggregatedPool` of `worker_threads` ([`worker-threads-pool`][pool]), partitioned by task name (`groupBy: ({ target }) => target.task`) with a per-task cap (`maxWorkersPerTask`) and a global `concurrency` cap. A target's `weight` reserves multiple worker "slots" for CPU-heavy tasks (e.g. a `jest` target that spawns its own internal pool), and `workerIdleMemoryLimit` restarts a worker that bloats — a pragmatic mitigation for Node memory leaks. The `WrappedTarget` wraps the actual run with a cache `fetch` (skip + restore on hit) before and a cache `put` after.

---

## Dimension 1 — Workspace Declaration & Topology

Lage has **no workspace model of its own** and declares no members. Workspace discovery is fully delegated to the [`workspace-tools`][repo] library, which auto-detects the host package manager and reads _its_ workspace globs:

- **npm / yarn**: the `workspaces` array in the root `package.json` (`getPackageJsonWorkspacePatterns`).
- **pnpm**: `packages:` in `pnpm-workspace.yaml` (with catalog support — `getCatalogs`, `parseCatalogContent`).
- **lerna**: `packages` in `lerna.json`.
- **rush**: `projects` in `rush.json`.

`getWorkspacePatterns(cwd)` returns the raw glob patterns; `getWorkspaceInfos` expands them into concrete package paths, and `getPackageInfos` parses every member `package.json` into a `PackageInfos` map. So a Lage repo's topology lives in, e.g.:

```json
// package.json (the host manager declares the workspace; lage just reads it)
{ "workspaces": ["packages/*", "scripts"] }
```

> [!NOTE]
> This "parasitic" model is the sharpest contrast with [Cargo][cargo]/[Go workspaces][go-work]/[Bazel][bazel], which own their workspace declaration outright. Lage occupies the **orchestrator** tier: it sits above whatever workspace the package manager already defines. The same is true of [Turborepo][turborepo] and [Wireit][wireit]; [Nx][nx] optionally adds its own `project.json` layer on top.

The **package graph** (who depends on whom) is derived by `createDependencyMap` from each package's `dependencies` + `devDependencies` (peer deps excluded), giving both a `dependencies` and a reverse `dependents` map used for topological expansion and for affected-package detection.

## Dimension 2 — Dependency Handling & Isolation

**Out of scope by design.** Lage installs nothing, hoists nothing, and symlinks nothing — it has no virtual store, no PnP, no isolated `node_modules`. Whatever isolation model the host manager provides (npm/yarn hoisting, pnpm's symlinked content-addressed store, Yarn Berry PnP) is what Lage runs inside.

Where dependencies _do_ enter Lage is **as cache-key inputs**. `TargetHasher` calls `parseLockFile` and `resolveExternalDependencies` (from `backfill-hasher`) to fold each package's resolved internal + external dependency versions into its target hash. Thus a dependency version bump in the lockfile invalidates the dependent's cache, even though Lage never touched the install. Cross-package _local_ references are likewise not a Lage concept — they are ordinary `workspace:`-protocol or `*` deps in the member `package.json`, surfaced to Lage only as edges in the `DependencyMap`.

## Dimension 3 — Task Orchestration & Scheduling

This is Lage's core competency.

- **Task DAG?** Yes — the **target graph** of `(package, task)` nodes, built by `WorkspaceTargetGraphBuilder` from the `pipeline` × package graph. Cycles are caught (`detectCycles`); a transitive reduction (`transitiveReduction`) and graph optimization (`optimizeTargetGraph`) prune redundant edges.
- **Concurrent execution?** Yes — `SimpleScheduler` runs **all** ready targets at once up to `concurrency`, recursively re-scheduling as each completes. Parallelism crosses task names: one package's `test` can run while another's `build` is still going, the explicit advantage over phase-barrier runners.
- **Change detection?** Yes, two complementary layers:
  1. **Input hashing** (per target, above) → a cache hit means the target is _skipped entirely_.
  2. **Affected detection** via `--since <ref>` → `getChangedPackages` runs `git diff` against the ref to compute changed packages, then `getTransitiveDependents` expands to impacted downstream packages, bounding the graph before it is even built.
- **Priorities & weights.** `priorities` (global, per `package#task`) bias the scheduler toward the critical path; `weight` lets a target reserve multiple worker slots.
- **Persistent worker service.** `lage server` / `lage-server` ([`rpc`][rpc]) keeps a background daemon alive that hosts `worker`-type targets across invocations (with an autoshutoff `--timeout`, default 300 s), amortizing Node/compiler warmup — Lage's analogue of [Bazel][bazel]'s persistent workers and [Gradle][gradle]'s daemon.

## Dimension 4 — Caching & Remote Execution

Lage has **first-class local + remote caching**, but **no remote _execution_** (no REAPI; it does not ship targets to a remote cluster — only cache artifacts move).

- **Local cache.** Outputs and logs are stored content-addressed under `<root>/node_modules/.cache/lage/{cache,logs}/<hash[0:4]>/` ([`getCacheDirectory.ts`][cachedir]), via the [`backfill`][repo] library (also in this monorepo). On a hit, declared `outputs` globs are restored and the runner is skipped.
- **Remote cache.** `RemoteFallbackCacheProvider` ([`RemoteFallbackCacheProvider.ts`][remotecache]) layers a remote store behind the local one: `fetch` tries local, falls back to remote, and **back-fills local from a remote hit**. Backends come from `backfill` — Azure Blob Storage (with `@azure/identity` credential chains), plus S3/GCS provider configs.
- **Asymmetric write policy.** Per the [remote-cache guide][remotecache-doc], remote _writes_ require the `LAGE_WRITE_REMOTE_CACHE` env var (typically set only in CI): _"`lage` will look for cache in layers: first on disk, then on remote server."_ Developers consume the CI-produced "last known good" cache read-only. `skipLocalCache` (default on in CI) and `writeRemoteCache` tune this further.

```text
# the layered fallback, conceptually
target hash ─▶ local cache?  ──hit──▶ restore outputs, skip run
                  │ miss
                  ▼
              remote cache? ──hit──▶ download → fill local → restore, skip run
                  │ miss
                  ▼
              run target ─▶ put local ─▶ (if LAGE_WRITE_REMOTE_CACHE) put remote
```

> [!NOTE]
> Caching is **target-level skip**, not Bazel-style hermetic action caching. Lage trusts user-declared `inputs`/`outputs` globs; an under-declared `inputs` set silently produces stale hits. There is no sandbox enforcing that a target reads only its declared inputs (contrast [Bazel][bazel]/[Buck2][buck2]).

## Dimension 5 — CLI / UX Ergonomics

The CLI is `commander`-based with grouped option sets ([`options.ts`][options]). Tasks are **positional arguments**, not flags — `lage build test lint` runs three tasks across the whole workspace. Targeting is then **narrowed by filter flags**:

| Flag                                                  | Effect                                                                                   |
| ----------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `--scope <pkg...>`                                    | Restrict to these packages (by default _includes_ their dependencies **and** dependents) |
| `--to <pkg...>`                                       | Shorthand for `--scope <pkg...> --no-dependents` (build "up to" a package)               |
| `--no-deps` / `--no-dependents`                       | Disable pulling in dependents of the scoped set                                          |
| `--include-dependencies`                              | Add the scoped packages' dependencies as graph entry points                              |
| `--since <ref>`                                       | Only packages changed since a git commit/tag/branch (+ their transitive dependents)      |
| `--ignore <glob...>`                                  | Files to ignore when computing `--since` scope                                           |
| `-c, --concurrency <n>`                               | Max simultaneous targets (default `availableParallelism`)                                |
| `--max-workers-per-task k=v`                          | Per-task worker caps, e.g. `build=2 test=4`                                              |
| `--continue`                                          | Keep running independent targets after a failure                                         |
| `--no-cache` / `--reset-cache` / `--skip-local-cache` | Cache controls (`--skip-local-cache` defaults on in CI)                                  |
| `--watch`                                             | Re-run affected targets on file change                                                   |
| `--profile [file]`                                    | Emit a Chromium-devtools trace of the run                                                |
| `--server [host:port]`                                | Route `worker` targets through the background service                                    |

```bash
# whole workspace
lage build test lint

# only packages changed vs main, plus their downstream dependents
lage build test lint --since origin/main

# just package-a and package-b, no dependents, 4-way parallel
lage build test lint --scope package-a package-b --no-deps --concurrency=4
```

Every option also auto-maps to an env var (`LAGE_<GROUP>_<NAME>`, e.g. `LAGE_RUN_CONCURRENCY`) via `addEnvOptions`, easing CI configuration. The boundary is thus: **task = positional; package selection = `--scope`/`--to`/`--since`; everything else = grouped flags.** This is close to [Turborepo][turborepo]'s `--filter` model but split across several flags rather than one expression language.

---

## Strengths

- **Explicit, central pipeline.** One `lage.config.js` describes every task relationship — easy to read, easy to reason about, no per-package config sprawl.
- **True cross-task parallelism.** The target graph dissolves the phase-barrier of legacy runners; `test` for one package overlaps `build` for another, saturating multi-core machines.
- **Trivial adoption.** No workspace migration: install one package, write one config, keep your existing npm scripts and package-manager workspace.
- **Strong caching story.** Content-addressed local cache + transparent remote fallback (`backfill`), with a CI-writes/devs-read asymmetric policy that is the right default.
- **Native-speed hashing.** `glob-hasher` is a Rust addon with a persisted mtime/size manifest, keeping the hash phase cheap on large repos.
- **Persistent worker service** (`lage server`) amortizes Node/compiler startup for `worker`-type targets — a meaningful edge for TypeScript/jest heavy repos.
- **Pragmatic resource controls.** `weight`, `maxWorkersPerTask`, and `workerIdleMemoryLimit` give fine-grained control over heavy tasks and leaky processes.

## Weaknesses

- **No isolation/install responsibility** — inherits whatever `node_modules` model the host manager imposes; no PnP, no sandbox.
- **Caching trusts declared `inputs`/`outputs`.** Under-declaring inputs yields silent stale hits; there is no hermetic enforcement (unlike [Bazel][bazel]/[Buck2][buck2]).
- **No remote execution.** Only cache artifacts are distributed; the build itself always runs on the local machine.
- **JS/TS-only.** Targets are npm scripts or Node worker functions; polyglot builds need wrapper scripts (contrast [Moon][moon]/[Bazel][bazel]).
- **Filter flags are fragmented.** `--scope` + `--to` + `--no-deps` + `--since` + `--include-dependencies` is more surface than [Turborepo][turborepo]'s single `--filter` DSL.
- **Implicit pipeline behavior across packages.** A bare same-package dep-spec gives _no_ ordering guarantee between packages, which can surprise newcomers expecting topological semantics.
- **Smaller ecosystem and mindshare** than [Nx][nx] or [Turborepo][turborepo]; primarily a Microsoft-internal-scale tool exposed publicly.

---

## Key design decisions and trade-offs

| Decision                                                      | Rationale                                                                              | Trade-off                                                                                  |
| ------------------------------------------------------------- | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Parasitic workspace model (read host manager's `workspaces`)  | Zero-migration adoption; reuse npm/yarn/pnpm/lerna/rush layouts as-is                  | No control over isolation; topology bugs live in the manager, not Lage                     |
| Single root `lage.config.js` pipeline                         | One readable source of truth for all task relationships across all packages            | Less colocation; large monorepos get a big central file                                    |
| Target graph = task graph × package graph                     | Unlocks cross-task parallelism and precise per-`(pkg,task)` caching                    | Graph can explode on big repos; needs transitive reduction + scoping to stay tractable     |
| Dep-spec mini-language (`^`, `^^`, `#`)                       | Compact, expressive topological vs same-package vs transitive vs specific dependencies | Terse syntax has a learning curve; bare specs give no cross-package ordering guarantee     |
| Content-hash caching trusting declared `inputs`/`outputs`     | Fast, simple, no sandbox overhead; works with any npm script                           | Stale hits if inputs under-declared; no hermeticity guarantee                              |
| Remote **cache** fallback, no remote **execution**            | Big real-world win (CI→dev cache reuse) at a fraction of REAPI complexity              | All compute is local; no horizontal build farm scaling                                     |
| Ready-set scheduler + `worker_threads` pool (per-task groups) | Dispatches the instant deps finish; reuses warm workers; weights heavy tasks           | In-process workers share a Node heap (hence idle-memory restart); no remote workers        |
| Persistent `lage server` for `worker` targets                 | Amortizes Node/TS/jest warmup across invocations                                       | Daemon lifecycle + autoshutoff to manage; only benefits `worker`-type, not raw npm scripts |

---

## Relevance to `dub`

For the [`dub` proposal][dub-landscape], Lage is the clearest demonstration that **task orchestration can be cleanly decoupled from package management**. `dub` already owns the package graph and resolver (the "package manager" tier); Lage shows what a thin layer _above_ that graph buys you. Concretely:

- A **declarative task pipeline** keyed by topological dep-specs (`^build`, `^^`) maps directly onto `dub`'s existing dependency topology — `dub` could expose a `[pipeline]`/build-order overlay without rewriting its resolver.
- **Content-addressed, target-level caching with a remote fallback** is the single highest-leverage feature: skipping unchanged sub-package builds across a monorepo (and across CI↔dev) is exactly the "redundant local compilation passes" deficit the proposal targets.
- **`--since <ref>` affected-detection** (git-diff → changed packages → transitive dependents) is a low-cost, high-value addition that bounds `dub test`/`dub build` to impacted members.

Lage also warns of a pitfall: caching that trusts user-declared `inputs`/`outputs` is fast but unsound. `dub` already _knows_ each target's source files from its own build description, so it could compute inputs **automatically** and avoid the stale-hit footgun Lage lives with.

---

## Sources

- [microsoft/lage — GitHub repository][repo] (source read at `2.15.x`; `@lage-run/*` packages)
- [`@lage-run/config` — `ConfigOptions` / `PipelineDefinition` / `CacheOptions`][config]
- [`@lage-run/target-graph` — `WorkspaceTargetGraphBuilder` and `expandDepSpecs`][wtgb]
- [`@lage-run/scheduler` — `SimpleScheduler` ready-set loop][sched]
- [`@lage-run/hasher` — `TargetHasher` cache-key composition][hasher]
- [`@lage-run/cache` — `RemoteFallbackCacheProvider` and cache directory layout][cache]
- [`@lage-run/cli` — `options.ts` flag surface and filter logic][options]
- [Lage documentation — Introduction][intro], [Pipelines][pipeline], [Remote cache][remotecache-doc]
- [npm registry — `lage@2.15.12`][npmreg]
- Related JS/TS orchestrators: [Turborepo][turborepo] · [Nx][nx] · [Wireit][wireit] · [Lerna][lerna] · [Rush][rush]; package managers [npm][npm] / [pnpm][pnpm] / [Yarn Berry][yarn-berry]; polyglot engines [Bazel][bazel] / [Buck2][buck2] / [Moon][moon]; and the [`dub` landscape][dub-landscape].

<!-- References -->

[repo]: https://github.com/microsoft/lage
[docs]: https://microsoft.github.io/lage/
[intro]: https://microsoft.github.io/lage/docs/introduction
[pipeline]: https://web.archive.org/web/20220626133110/https://microsoft.github.io/lage/docs/Guide/pipeline/
[remotecache-doc]: https://web.archive.org/web/20220817191936/https://microsoft.github.io/lage/docs/Guide/remote-cache/
[npmreg]: https://www.npmjs.com/package/lage
[config]: https://github.com/microsoft/lage/blob/1fbdf8c093946653d4ce8f3f4933d1585fababa7/packages/config/src/types/ConfigOptions.ts
[wtgb]: https://github.com/microsoft/lage/blob/1fbdf8c093946653d4ce8f3f4933d1585fababa7/packages/target-graph/src/WorkspaceTargetGraphBuilder.ts
[tgraph]: https://github.com/microsoft/lage/blob/1fbdf8c093946653d4ce8f3f4933d1585fababa7/packages/target-graph/src/types/TargetConfig.ts
[expand]: https://github.com/microsoft/lage/blob/1fbdf8c093946653d4ce8f3f4933d1585fababa7/packages/target-graph/src/expandDepSpecs.ts
[sched]: https://github.com/microsoft/lage/blob/1fbdf8c093946653d4ce8f3f4933d1585fababa7/packages/scheduler/src/SimpleScheduler.ts
[hasher]: https://github.com/microsoft/lage/blob/1fbdf8c093946653d4ce8f3f4933d1585fababa7/packages/hasher/src/TargetHasher.ts
[cache]: https://github.com/microsoft/lage/tree/1fbdf8c093946653d4ce8f3f4933d1585fababa7/packages/cache/src
[remotecache]: https://github.com/microsoft/lage/blob/1fbdf8c093946653d4ce8f3f4933d1585fababa7/packages/cache/src/providers/RemoteFallbackCacheProvider.ts
[cachedir]: https://github.com/microsoft/lage/blob/1fbdf8c093946653d4ce8f3f4933d1585fababa7/packages/cache/src/getCacheDirectory.ts
[options]: https://github.com/microsoft/lage/blob/1fbdf8c093946653d4ce8f3f4933d1585fababa7/packages/cli/src/commands/options.ts
[getconfig]: https://github.com/microsoft/lage/blob/1fbdf8c093946653d4ce8f3f4933d1585fababa7/packages/config/src/getConfig.ts
[pool]: https://github.com/microsoft/lage/tree/1fbdf8c093946653d4ce8f3f4933d1585fababa7/packages/worker-threads-pool/src
[runners]: https://github.com/microsoft/lage/tree/1fbdf8c093946653d4ce8f3f4933d1585fababa7/packages/runners/src
[rpc]: https://github.com/microsoft/lage/tree/1fbdf8c093946653d4ce8f3f4933d1585fababa7/packages/rpc/src
[turborepo]: ../turborepo/
[nx]: ../nx/
[wireit]: ../wireit/
[lerna]: ../lerna/
[rush]: ../rush/
[npm]: ../npm/
[pnpm]: ../pnpm/
[yarn-berry]: ../yarn-berry/
[cargo]: ../cargo/
[go-work]: ../go-work/
[gradle]: ../gradle/
[bazel]: ../bazel/
[buck2]: ../buck2/
[moon]: ../moon/
[dub-landscape]: ../../async-io/d-landscape.md
