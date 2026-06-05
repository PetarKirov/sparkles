# Nx (JavaScript/TypeScript)

A task-orchestration layer for JS/TS (and increasingly polyglot) monorepos: Nx
does **not** manage packages or `node_modules` itself — it leans on the package
manager's own workspaces — but it builds a project **graph** from your source
imports, derives a **task DAG**, hashes every task's inputs, and replays cached
results locally or from a shared remote cache so that "you never run the same
computation twice."

| Field           | Value                                                                                                        |
| --------------- | ------------------------------------------------------------------------------------------------------------ |
| Language        | TypeScript (CLI/plugins) + Rust (native core: hasher, project-graph, file walker, TUI, daemon)               |
| License         | MIT                                                                                                          |
| Repository      | [nrwl/nx][repo]                                                                                              |
| Documentation   | [nx.dev][docs] · [`nx.json` reference][nxjson] · [project configuration][projcfg]                            |
| Category        | JS/TS Task Orchestrator                                                                                      |
| Workspace model | **Inherited** from the package manager (npm/yarn/pnpm/bun `workspaces`); Nx adds a graph + task layer on top |
| First released  | 2017, as an Angular CLI extension by Nrwl (now Nx)                                                           |
| Latest release  | `22.7.5` (May 27, 2026); `23.0.0` in beta                                                                    |

> **Latest release:** `22.7.5`, published May 27, 2026, with `23.0.0-beta.x`
> in the release channel. Nx ships as the `nx` package plus a constellation of
> `@nx/*` plugins (`@nx/js`, `@nx/jest`, `@nx/vite`, `@nx/eslint`, `@nx/react`,
> …). Since **Nx 20.8** self-hosted remote caching is driven by a published
> **OpenAPI spec**; the previous first-party cloud-storage cache plugins
> (`@nx/s3-cache`, `@nx/gcs-cache`, `@nx/azure-cache`, `@nx/shared-fs-cache`)
> were **deprecated on May 21, 2026** under [CVE-2025-36852 ("CREEP")][creep].
> See [Caching & remote execution](#caching--remote-execution).

---

## Overview

### What it solves

A large JS/TS monorepo has a structural problem the package manager alone does
not solve. npm/yarn/pnpm/bun **workspaces** can install and symlink dozens of
inter-dependent packages into one `node_modules`, but they have no notion of a
**build/test graph**: `npm run build --workspaces` runs every package's `build`
script in arbitrary order, re-runs work that did not change, and cannot answer
"given this git diff, which packages actually need re-testing?" In a repo with
hundreds of projects this means CI re-builds and re-tests the whole world on
every commit.

Nx layers a **task orchestrator** over the existing workspace. It does three
things the package manager does not:

1. **Builds a project graph.** Nx statically analyzes import statements and
   `package.json` dependencies to derive which projects depend on which —
   _"Nx uses powerful source-code analysis to figure out your workspace's
   project graph"_ ([project configuration][projcfg]). Edges it cannot infer
   statically are declared via `implicitDependencies`.
2. **Derives and schedules a task DAG.** From a target like `build` plus a
   `dependsOn` rule like `["^build"]`, Nx computes the topological order of
   every task across every project and runs independent legs concurrently.
3. **Hashes and caches every task.** Before running a cacheable task Nx computes
   a **computation hash** over all of the task's inputs; if that hash has been
   seen before — locally or in a shared remote cache — Nx **replays** the stored
   terminal output and output files instead of re-running.

The `affected` command ties these together: given a git range, Nx walks the
project graph to find the changed projects **and their dependents**, then runs a
target only on that slice. This is the headline value proposition — bounded,
incremental CI on a graph the tool understands.

### Design philosophy

Nx began in 2017 as an Angular CLI extension and has shed almost all of that
heritage; its current philosophy is that **configuration should be inferred, not
written.** Since **Nx 18** (February 2024), the "Project Crystal" model lets
plugins infer tasks from existing tool config files rather than requiring an
explicit `project.json` per project. From the inferred-tasks documentation
([Inferred Tasks (Project Crystal)][crystal]):

> _"Nx plugins can automatically infer tasks for your projects based on the
> configuration of different tools. … The plugin will search the workspace for
> configuration files of the tool. For each configuration file found, the plugin
> will infer tasks."_

So a project's Nx-side configuration can collapse to nothing more than
`{ "name": "myapp" }` — the `@nx/vite/plugin`, `@nx/jest/plugin`, and
`@nx/eslint/plugin` entries in `nx.json` discover `vite.config.ts`,
`jest.config.ts`, and `eslint.config.js` and synthesize `build`, `test`, and
`lint` targets with correct inputs, outputs, and cacheability.

Three consequences shape the whole tool:

1. **Nx is orchestration, not package management.** It deliberately delegates
   dependency installation and `node_modules` linking to the package manager's
   workspaces (see [Dependency handling](#dependency-handling--isolation)). This
   is the sharpest contrast with [pnpm][pnpm] (a package manager that also
   orchestrates) and with [Cargo][cargo]/[Go workspaces][go-work] (language
   tools that own both halves).
2. **The graph is the source of truth.** Targets, dependencies, inputs, and
   outputs are all expressed against the project graph; the same graph drives
   scheduling, hashing, and `affected`.
3. **Caching is content-addressed and shareable.** A task result is keyed by the
   hash of its inputs, so a result computed in CI can be replayed on a
   developer's laptop — the basis of Nx Cloud's "Nx Replay."

Within this survey Nx is the canonical **JS/TS task orchestrator that sits on
top of a package manager**. Compare it with its closest sibling [Turborepo][turborepo]
(same "graph + hash + remote cache" model, leaner config), with the older
publishing-focused [Lerna][lerna] (which Nrwl now maintains and which delegates
its `run` to Nx), and with the heavier polyglot engines [Bazel][bazel] /
[Buck2][buck2] / [Pants][pants] that demand explicit `BUILD` files instead of
inferring from source.

---

## Core concepts and files

| Concept           | File / item                                        | Role                                                                              |
| ----------------- | -------------------------------------------------- | --------------------------------------------------------------------------------- |
| Workspace config  | `nx.json` (repo root)                              | Plugins, `targetDefaults`, `namedInputs`, parallelism, cache + cloud settings     |
| Project config    | `project.json` _or_ `package.json#nx`              | Per-project `targets`, `tags`, `implicitDependencies`, `namedInputs`              |
| Inference plugins | `plugins: [...]` in `nx.json`                      | `createNodesV2`/`createDependencies` hooks that synthesize tasks from tool config |
| Project graph     | (computed) `ProjectGraph`                          | Nodes = projects, edges = static/implicit deps; cached in `.nx/workspace-data`    |
| Task graph        | (computed) `TaskGraph`                             | The DAG of `project:target` invocations expanded from `dependsOn`                 |
| Target / task     | `targets.<name>` (with `executor` + `options`)     | A runnable unit; `nx run <project>:<target>` / `nx <target> <project>`            |
| Task dependencies | `dependsOn` (`"^build"`, `"build"`, object)        | Edges into the task DAG (across deps with `^`, within the project without)        |
| Cache inputs      | `inputs` / `namedInputs` (`default`, `production`) | File sets, runtime values, and env vars folded into the computation hash          |
| Cache outputs     | `outputs` (`{projectRoot}`, `{workspaceRoot}`)     | The files Nx stores and restores on a cache hit                                   |
| Native hasher     | `packages/nx/src/native/hasher.rs` (xxHash)        | Rust + `rayon` parallel hashing of files/config/externals                         |
| Local cache       | `.nx/cache` + a SQLite DB (`getLocalDbConnection`) | Stores terminal output, output files, and the input hash per task                 |
| Affected          | `nx affected -t <target> --base --head`            | Restrict execution to changed projects and their dependents                       |
| Daemon            | Nx Daemon (Rust)                                   | Long-lived process caching the project graph + watching the filesystem            |

### The two config files

`nx.json` ([reference][nxjson]) _"configures the Nx CLI and project defaults."_
Its load-bearing keys are `plugins`, `targetDefaults`, `namedInputs`, `parallel`,
`cacheDirectory`, `defaultBase`, `nxCloudId`/`nxCloudUrl`, `maxCacheSize`, and
`release`. A minimal modern `nx.json`:

```json
{
  "$schema": "./node_modules/nx/schemas/nx-schema.json",
  "plugins": [
    { "plugin": "@nx/js/typescript" },
    { "plugin": "@nx/jest/plugin", "options": { "targetName": "test" } }
  ],
  "namedInputs": {
    "default": ["{projectRoot}/**/*", "sharedGlobals"],
    "production": ["default", "!{projectRoot}/**/*.spec.ts"]
  },
  "targetDefaults": {
    "build": {
      "dependsOn": ["^build"],
      "inputs": ["production", "^production"],
      "outputs": ["{workspaceRoot}/dist/{projectRoot}"],
      "cache": true
    },
    "test": { "inputs": ["default", "^production"], "cache": true }
  },
  "defaultBase": "main"
}
```

A project that opts out of inference declares targets explicitly in
`project.json`:

```json
{
  "name": "greeter",
  "projectType": "library",
  "sourceRoot": "packages/greeter/src",
  "tags": ["scope:shared"],
  "targets": {
    "build": {
      "executor": "@nx/js:tsc",
      "outputs": ["{workspaceRoot}/dist/packages/greeter"],
      "dependsOn": ["^build"],
      "cache": true,
      "options": { "main": "{projectRoot}/src/index.ts" }
    }
  }
}
```

---

## How it works

### The project graph

Nx's first job on any command is to construct a `ProjectGraph` — projects as
nodes, dependencies as directed edges. Nodes come from the package manager's
workspaces (every workspace member is a project) plus anything the inference
plugins discover. Edges come from three sources, in order of preference:

1. **Static analysis** of `import`/`require` statements and dynamic imports
   (the Rust file-walker + a TypeScript-aware analyzer).
2. **`package.json` dependencies** that resolve to another workspace project.
3. **`implicitDependencies`** declared in `project.json` for edges that cannot
   be inferred statically (e.g. a runtime config dependency) —
   _"Manually declared dependencies that cannot be statically inferred."_

The graph is expensive to compute, so a long-lived **Nx Daemon** (written in
Rust) keeps it in memory, watches the filesystem, and serves it to CLI
invocations; the serialized graph is cached under `.nx/workspace-data`. You can
inspect it with `nx graph` (interactive) or `nx show project <name>` (to see a
project's inferred targets and deps).

### From target to task DAG

A **target** is a named runnable (`build`, `test`, `lint`); an invocation of a
target on a project is a **task** (`greeter:build`). `dependsOn` turns targets
into a task DAG ([project configuration][projcfg]):

- `"^build"` — _"Run the `build` target on all dependencies first."_
- `"build"` — _"Run the `build` target on the current project first."_
- The object form `{ "target": "build", "dependencies": true, "params": "forward" }`
  controls argument forwarding (`"ignore"` default vs `"forward"`).
- Wildcards (`"build-*"`, `"^*build-*"`) are supported since `19.5.0`.

`packages/nx/src/tasks-runner/create-task-graph.ts` expands these rules over the
project graph into a concrete `TaskGraph`. The orchestrator then topologically
sorts it and runs independent tasks concurrently. From the orchestrator's
imports ([`task-orchestrator.ts`][orch]) you can read its anatomy directly — it
pulls in `hashTask`/`hashTasks` from the hasher, `TasksSchedule` for scheduling,
a `DbCache` for the local cache, a `ForkedProcessTaskRunner` for parallelism,
and a `RunningTasksService` from the Rust native layer.

### Computation hashing (the cache key)

Before running any cacheable task, Nx computes a **computation hash**. From
[How Caching Works][caching]:

> _"Before running any cacheable task, Nx computes its computation hash. As long
> as the computation hash is the same, the output of running the task is the
> same."_

The hash folds in, per the same doc: _"All the source files of the project and
its dependencies,"_ _"Relevant global configuration,"_ _"Versions of external
dependencies,"_ _"Runtime values provisioned by the user such as the version of
Node,"_ and _"CLI Command flags."_ The native hasher enumerates exactly these
categories in its `HashInputs` struct ([`task_hasher.rs`][taskhash]):

```rust
// packages/nx/src/native/tasks/task_hasher.rs
#[napi(object)]
pub struct HashInputs {
    /// Expanded file paths that were used as inputs
    pub files: Vec<String>,
    /// Runtime commands
    pub runtime: Vec<String>,
    /// Environment variable names
    pub environment: Vec<String>,
    /// Dependent task outputs
    pub dep_outputs: Vec<String>,
    /// External dependencies
    pub external: Vec<String>,
}
```

The hashing itself is **xxHash** (`xxh3_64`), computed in Rust and parallelized
with `rayon` over a `DashMap` of per-file caches ([`hasher.rs`][hasher]):

```rust
// packages/nx/src/native/hasher.rs
use xxhash_rust::xxh3;

pub fn hash(content: &[u8]) -> String {
    xxh3::xxh3_64(content).to_string()
}
```

Which files count as input is governed by `inputs` / `namedInputs`. The
convention is two named sets: `default` (everything in the project) and
`production` (everything except specs/test config). A `build` target typically
takes `["production", "^production"]` — its own production files plus its
dependencies' — so a change to a sibling's _test_ file does **not** invalidate a
downstream `build`.

### Cache lookup and replay

With a hash in hand, Nx checks the cache. From [How Caching Works][caching]:

> _"First, it checks locally, and then if it is missing, and if a remote cache is
> configured, it checks remotely."_

A cache entry stores three things: _"Terminal output generated when running a
task,"_ _"The output files of a task,"_ and _"The hash of the inputs to the
computation."_ On a hit, Nx **replays** rather than recomputes:

> _"Nx places the right files in the right folders and prints the terminal
> output. From the user's point of view, the command ran the same, only a lot
> faster."_

Nx captures stdout/stderr precisely _"to make sure the replayed output looks the
same, including on Windows."_ The local cache lives in `.nx/cache` with a SQLite
database (opened via `getLocalDbConnection`) tracking entries; file contents are
deduplicated under a per-workspace native file cache whose directory is keyed by
a hash of `(workspaceRoot, nxVersion, username)` ([`native-file-cache-location.ts`][cacheloc]).

### `affected`: slicing by git diff

`nx affected` is the project-graph applied to a git range. From the
[affected feature page][affected], Nx will _"use the project graph to determine
which projects depend on the projects you modified"_ and run the target only on
that slice:

```bash
nx affected -t test                                   # vs defaultBase (e.g. main)
nx affected -t build --base=origin/main --head=$SHA   # explicit range
nx affected -t lint  --files=packages/greeter/src/index.ts  # explicit file list
```

Crucially, "affected" includes **dependents**, not just changed projects: if
`greeter` changes, `cli` (which imports it) is affected too, because its tests
might break. Combined with caching, an unchanged-but-affected project can still
hit the cache, so `affected` and the hash work together to minimize CI work.

---

## Workspace declaration & topology

Nx has **no workspace-members array of its own.** Topology is inherited from the
package manager's workspaces, and Nx discovers projects from there plus its
inference plugins.

- **npm / yarn / bun:** the root `package.json` `"workspaces"` array of globs:

  ```json
  { "workspaces": ["packages/*", "apps/*"] }
  ```

- **pnpm:** a `pnpm-workspace.yaml` with a `packages:` list. (Note: pnpm only
  symlinks workspace packages that a project **explicitly** depends on, so each
  project must declare its local deps.)

Every workspace member becomes a project node. Nx itself contributes only
`nx.json` (workspace-level config) and, optionally, per-project `project.json`
or a `package.json#nx` block. There is no separate "virtual workspace" vs
"root-package" distinction as in [Cargo][cargo]; the package-manager root
`package.json` is always the de-facto virtual root, and whether it also ships
shippable code is irrelevant to Nx.

> [!NOTE]
> Older Nx (pre-16) generated a non-package-manager layout under `apps/` and
> `libs/` with a central `workspace.json` mapping project names to paths. Modern
> Nx ("package-based" and "integrated" repos alike) aligns with native package
> manager workspaces; `workspace.json` is gone and `workspaceLayout` in `nx.json`
> only steers where generators scaffold new projects.

Project **tags** (`"tags": ["scope:shared", "type:lib"]`) plus the
`@nx/enforce-module-boundaries` ESLint rule let you declare which projects may
depend on which — a constraints layer over the graph (cf. Yarn's constraints
engine).

## Dependency handling & isolation

This is Nx's most important architectural choice: **Nx does not isolate or store
dependencies at all.** It has no virtual store ([pnpm][pnpm]), no Plug'n'Play
([Yarn Berry][yarn-berry]), and no lockfile of its own. Installation, hoisting,
symlinking, and `node_modules` layout are entirely the package manager's job.

- **Local cross-references** between workspace members use the package manager's
  own mechanism: a project depends on `@my-org/greeter`, and the package manager
  symlinks `node_modules/@my-org/greeter` to the local `packages/greeter`
  directory. Nx reads those `package.json` deps (and the source imports) to draw
  the graph edge; it does **not** introduce a `workspace:`-style protocol of its
  own (that is pnpm's/yarn's).
- **TypeScript path resolution** historically used `compilerOptions.paths` in a
  root `tsconfig.base.json` (e.g. `"@my-org/greeter": ["packages/greeter/src/index.ts"]`).
  Newer Nx steers toward **TypeScript project references** + package-manager
  workspace links instead, the [TypeScript Project Linking][tslinking] model:
  the symlink in `node_modules` resolves the import, and `references` in
  `tsconfig.json` order the type-check.
- **Versions of external dependencies** still feed the cache hash (the `external`
  field above), so a `pnpm-lock.yaml`/`package-lock.json` change correctly
  invalidates affected tasks even though Nx never parses it for installation.

The upshot: Nx is **complementary** to the package manager, not a replacement.
This is what lets it be incrementally adopted into an existing npm/yarn/pnpm
monorepo with a single `nx init`, and what distinguishes it from
[Cargo][cargo]/[Go workspaces][go-work], where the language tool owns both the
dependency graph and the build graph.

## Task orchestration & scheduling

Yes — a real task DAG with concurrent execution and input-hash change detection.

- **DAG construction.** `create-task-graph.ts` expands every requested target
  through its `dependsOn` rules over the project graph into a `TaskGraph` of
  `project:target` nodes with prerequisite edges.
- **Topological, concurrent execution.** The `TaskOrchestrator` schedules tasks
  whose prerequisites are complete, forking child processes
  (`ForkedProcessTaskRunner`) up to a parallelism limit (`--parallel`, default
  **3**; raise with `--parallel=8` or set `parallel` in `nx.json`). Independent
  legs run simultaneously; dependent legs wait.
- **Batch mode.** For executors that support it, Nx runs a whole "batch" of
  same-target tasks in one process (`tasks-runner/batch`) to amortize
  tool-startup cost (e.g. a single `tsc --build` over many projects).
- **Change detection** is double-layered: `affected` prunes the graph by git
  diff _before_ scheduling, and the **computation hash** prunes execution _during_
  scheduling (a task whose hash hits the cache is replayed, not run). A task is
  re-run only if its inputs changed.
- **Output streaming.** A Rust-backed pseudo-terminal + TUI
  (`is-tui-enabled.ts`, `native/tui`) renders live, per-task interleaved output.

```bash
nx run-many -t build              # build every project, in graph order
nx run-many -t test -p greeter cli  # only these two projects (+ their deps)
nx affected -t lint test --parallel=8   # changed slice, two targets, 8-wide
```

## Caching & remote execution

Nx is fundamentally a **caching** tool; "remote execution" in the Bazel/REAPI
sense is **not** part of it (it caches and replays results — it does not ship
task execution to remote workers).

- **Local cache.** `.nx/cache` + SQLite. Content-addressed by the xxHash
  computation hash; stores terminal output + output files. `--skipNxCache`
  bypasses it; `nx reset` clears it.
- **Remote cache ("Nx Replay").** A content-addressed cache shared across the
  team and CI — _"a build that ran in CI doesn't need to run again on your
  machine."_ The first-party backend is **Nx Cloud** (`nxCloudId` in `nx.json`).
- **Self-hosted cache.** Since **Nx 20.8** Nx publishes an **OpenAPI
  specification** for a custom remote-cache server, so you can host your own
  (several community Rust/Deno + S3 implementations exist).

> [!WARNING]
> The previous first-party storage cache plugins — `@nx/s3-cache`,
> `@nx/gcs-cache`, `@nx/azure-cache`, `@nx/shared-fs-cache` — were
> **deprecated on May 21, 2026** because of **CVE-2025-36852 ("CREEP")**: they
> used a single credential granting read/write over the whole cache with nothing
> tracking which branch produced an artifact, so a malicious PR could **poison
> the cache**. The flaw is in the design and is not patchable. Use Nx Cloud or a
> self-hosted server built against the [OpenAPI spec][selfhost] instead. ([CVE][creep])

- **Remote execution (true RBE)** is out of scope. For that, see [Bazel][bazel] /
  [Buck2][buck2] over [Buildbarn][buildbarn] / [BuildBuddy][buildbuddy] /
  [NativeLink][nativelink]. Nx Cloud does, however, offer **Distributed Task
  Execution (DTE / "Nx Agents")**, which farms the _task graph_ out across CI
  agent machines and re-aggregates results — graph-level distribution, not
  REAPI sandboxed action execution.

## CLI / UX ergonomics

Nx's command surface is built around **target + project selection**, with
filters layered onto a small set of verbs.

| Goal                           | Command                                                     |
| ------------------------------ | ----------------------------------------------------------- |
| Run one task                   | `nx build greeter` / `nx run greeter:build`                 |
| Run one target everywhere      | `nx run-many -t build`                                      |
| Run several targets            | `nx run-many -t build test lint`                            |
| Filter to projects             | `nx run-many -t test -p greeter cli`                        |
| Exclude projects               | `nx run-many -t test --exclude=cli-e2e`                     |
| Only what a diff touches       | `nx affected -t test`                                       |
| Diff against a range           | `nx affected -t build --base=origin/main --head=$SHA`       |
| Diff by explicit files         | `nx affected -t lint --files=packages/greeter/src/index.ts` |
| Set concurrency                | `--parallel=8`                                              |
| Skip the cache                 | `--skipNxCache`                                             |
| Stop on first failure          | `--nxBail`                                                  |
| Inspect a project's tasks/deps | `nx show project greeter`                                   |
| Visualize the graph            | `nx graph`                                                  |

- **`-t/--targets`** selects targets; **`-p/--projects`** selects projects (globs
  and tags allowed: `-p "tag:scope:shared"`). `--exclude` removes projects.
- **`affected`** is the dedicated "since" verb; `--base`/`--head` define the git
  range and `--files` bypasses git entirely. Most flags (`--skipNxCache`,
  `--verbose`, `--nxBail`, `--parallel`) are shared across `run`, `run-many`, and
  `affected`.
- Compared with the colon-target syntax of [Bazel][bazel] (`//path:target`) or
  the `--filter` DSL of [pnpm][pnpm]/[Turborepo][turborepo], Nx's
  verb + `-t` + `-p` shape reads as plain target/project selection, and `affected`
  is its first-class change-bounded mode rather than a flag.

---

## Strengths

- **Drop-in over any package manager.** `nx init` adds orchestration to an
  existing npm/yarn/pnpm/bun workspace without changing the dependency model.
- **Inferred configuration (Project Crystal).** Plugins synthesize tasks from
  existing tool config, so per-project Nx config can be near-empty.
- **Fast, correct caching.** Rust + xxHash + `rayon`, content-addressed,
  local-then-remote, with output replay (incl. terminal output) — _"never run
  the same computation twice."_
- **`affected` change-bounding.** Walks the real project graph (changed projects
  **and dependents**) to minimize CI work, with explicit `--base`/`--head`.
- **Shared remote cache + DTE.** Nx Cloud's Replay and distributed task
  execution scale CI across machines; self-hosting via an OpenAPI spec.
- **Polyglot reach.** Though JS/TS-first, `@nx/gradle`, `@nx/rust`, `nx-dotnet`,
  and generic `run-commands` executors bring non-JS projects into the graph.
- **Mature ecosystem.** Generators (`nx generate`), automated `nx migrate`
  upgrades, `nx graph` visualization, and module-boundary lint rules.

## Weaknesses

- **Not a package manager.** Dependency isolation, hoisting, and lockfiles are
  entirely delegated; Nx inherits whatever resolution pain the package manager
  has, and cannot offer pnpm-style strictness on its own.
- **Plugin/version surface area.** The `@nx/*` plugin matrix and frequent major
  versions make `nx migrate` essential but occasionally noisy; inference can
  surprise (which plugin "wins" a target name depends on `plugins` order).
- **No true remote execution.** It caches/replays and distributes the task
  graph, but does not sandbox and ship individual actions to remote workers like
  [Bazel][bazel]/[Buck2][buck2] over REAPI.
- **Cache-poisoning history.** The deprecated storage cache plugins
  ([CVE-2025-36852][creep]) are a cautionary tale about shared-cache trust
  boundaries.
- **Hash correctness depends on declared inputs.** Under-declared `inputs`
  (e.g. a build that reads an undeclared env var or file) yield stale cache hits;
  over-declared inputs yield needless misses ([troubleshoot cache misses][misses]).
- **Heavier than a plain task runner.** For a tiny repo, the daemon, graph, and
  plugin machinery are more than [Just][just]/[Task][task] or
  [Turborepo][turborepo] would impose.

## Key design decisions and trade-offs

| Decision                                          | Rationale                                                                   | Trade-off                                                                             |
| ------------------------------------------------- | --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Orchestrate, don't manage packages                | Drop into any npm/yarn/pnpm/bun workspace; composable, incremental adoption | Inherits the package manager's isolation model; no store/PnP/lockfile of its own      |
| Project graph from static import analysis         | Dependencies stay accurate without hand-maintained `BUILD` files            | Statically-invisible edges need manual `implicitDependencies`; analysis cost          |
| Inferred tasks (Project Crystal, Nx 18+)          | Near-zero per-project config; one plugin configures many projects           | "Magic" — which plugin wins a target name depends on `plugins` order; harder to debug |
| Content-addressed computation hash (xxHash, Rust) | Correct, fast, shareable cache keys; local-then-remote replay               | Cache correctness hinges on fully-declared `inputs`/`namedInputs`                     |
| `affected` = changed projects **and dependents**  | CI runs only the impacted slice, safely (dependents may break)              | Requires a clean git range; over-broad graphs reduce the savings                      |
| Cache results, not remote-execute actions         | Simple trust/setup vs REAPI; replay is enough for most JS/TS work           | No sandboxed remote action execution; large native builds favor Bazel/Buck2           |
| Rust native core (hasher, graph, daemon, TUI)     | Hot paths (hashing, walking, graphing) are fast and parallel (`rayon`)      | A native addon per platform; WASM fallback for unsupported targets                    |
| `dependsOn: ["^build"]` topological build rule    | Declarative cross-project ordering driven by the existing graph             | Easy to forget; a missing `^build` yields "module not found" at task time             |

---

## Sample workspace

A minimal, runnable two-package Nx workspace lives in [`./sample/`](./sample/):
a `@sample/greeter` library and a `@sample/cli` app that imports it locally via
the package manager workspace link, wired with a `dependsOn: ["^build"]`
topological build and a cacheable `test` target. See the directory for the exact
`nx.json`, `package.json` workspace globs, per-project `project.json`, and
`tsconfig` setup.

---

## Sources

- [nrwl/nx — GitHub repository][repo] (source for all quoted file paths)
- [nx.dev — documentation][docs]
- [`nx.json` reference][nxjson] — workspace config keys, `targetDefaults`, plugins
- [Project configuration reference][projcfg] — `project.json`, `dependsOn`, `implicitDependencies`
- [Inferred Tasks (Project Crystal)][crystal] — plugin task inference (verbatim quote)
- [How Caching Works][caching] — computation hash, local-then-remote lookup, replay (verbatim quotes)
- [Run Only Tasks Affected by a PR][affected] — `affected` semantics, `--base`/`--head`/`--files`
- [`packages/nx/src/native/hasher.rs`][hasher] — xxHash (`xxh3_64`) hashing core
- [`packages/nx/src/native/tasks/task_hasher.rs`][taskhash] — `HashInputs`, `rayon` parallel hashing
- [`packages/nx/src/tasks-runner/task-orchestrator.ts`][orch] — DAG scheduling, cache, forked runner
- [`packages/nx/src/native/native-file-cache-location.ts`][cacheloc] — per-workspace cache directory keying
- [Remote Cache / self-hosted (OpenAPI spec)][selfhost] · [Deprecation notice (CREEP / CVE-2025-36852)][creep]
- [TypeScript Project Linking][tslinking] — workspace symlinks + project references
- Sibling docs: [Turborepo][turborepo] · [Lerna][lerna] · [pnpm][pnpm] · [Yarn Berry][yarn-berry] · [Cargo][cargo] · [Go workspaces][go-work] · [Bazel][bazel] · [Buck2][buck2] · [Pants][pants] · [Just][just] · [Task][task] · [Buildbarn][buildbarn] · [BuildBuddy][buildbuddy] · [NativeLink][nativelink] · [the D landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/nrwl/nx
[docs]: https://nx.dev/
[nxjson]: https://nx.dev/docs/reference/nx-json
[projcfg]: https://nx.dev/docs/reference/project-configuration
[crystal]: https://nx.dev/docs/concepts/inferred-tasks
[caching]: https://nx.dev/docs/concepts/how-caching-works
[affected]: https://nx.dev/docs/features/ci-features/affected
[selfhost]: https://nx.dev/docs/guides/tasks--caching/self-hosted-caching
[creep]: https://nx.dev/docs/reference/deprecated/self-hosted-cache-packages
[tslinking]: https://nx.dev/docs/concepts/typescript-project-linking
[misses]: https://nx.dev/docs/troubleshooting/troubleshoot-cache-misses
[hasher]: https://github.com/nrwl/nx/blob/master/packages/nx/src/native/hasher.rs
[taskhash]: https://github.com/nrwl/nx/blob/master/packages/nx/src/native/tasks/task_hasher.rs
[orch]: https://github.com/nrwl/nx/blob/master/packages/nx/src/tasks-runner/task-orchestrator.ts
[cacheloc]: https://github.com/nrwl/nx/blob/master/packages/nx/src/native/native-file-cache-location.ts
[turborepo]: ../turborepo/
[lerna]: ../lerna/
[pnpm]: ../pnpm/
[yarn-berry]: ../yarn-berry/
[cargo]: ../cargo/
[go-work]: ../go-work/
[bazel]: ../bazel/
[buck2]: ../buck2/
[pants]: ../pants/
[just]: ../just/
[task]: ../task/
[buildbarn]: ../buildbarn/
[buildbuddy]: ../buildbuddy/
[nativelink]: ../nativelink/
[d-landscape]: ../../async-io/d-landscape.md
