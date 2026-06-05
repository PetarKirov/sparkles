# Lerna (JavaScript/TypeScript)

The original JS/TS monorepo tool — a multi-package **versioning and publishing**
workhorse that, since its 2022 hand-off to the Nx team, **delegates its task
running and caching to [Nx][nx]** while keeping its own topology resolution,
`lerna version`/`lerna publish` release machinery, and `--scope`/`--since`
filter ergonomics.

| Field           | Value                                                                                                                                            |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| Language        | TypeScript (CLI + libraries); ships an `@lerna/*` library set and a single `lerna` bin                                                           |
| License         | MIT                                                                                                                                              |
| Repository      | [lerna/lerna][repo]                                                                                                                              |
| Documentation   | [lerna.js.org][docs] · [`lerna.json` schema][schema] · [features][features]                                                                      |
| Category        | JS/TS Task Orchestrator                                                                                                                          |
| Workspace model | **Inherited** from the package manager (`package.json#workspaces` / `pnpm-workspace.yaml`), or an explicit `packages` glob array in `lerna.json` |
| First released  | `1.0.1` on npm, **December 4, 2015** (created by Jamie Kyle / the Babel team)                                                                    |
| Latest release  | `9.0.7`, **March 13, 2026**                                                                                                                      |

> **Latest release:** `9.0.7` (published March 13, 2026; `dist-tags` `latest`
> and `next` both point at it). Lerna **changed stewardship to Nx** (Nrwl) in
> 2022 — the repository banner states this outright (_"this project [changed
> stewardship to Nx](https://github.com/lerna/lerna/issues/3121)!"_, [`README.md`][readme]).
> Since `lerna@6` the default task runner **is Nx**: `lerna run`/`lerna exec`
> route through Nx's `runOne`/`runMany` unless you set `"useNx": false`. The
> repo even dogfoods Nx — its own `nx.json` defines `targetDefaults`,
> `namedInputs`, and an `nxCloudAccessToken`. See [Task orchestration &
> scheduling](#task-orchestration--scheduling).

---

## Overview

### What it solves

Lerna was the **first** widely-adopted answer to "how do I keep many npm
packages in one git repository?" Long before npm/yarn/pnpm shipped first-class
`workspaces`, Lerna provided the two operations a multi-package JS repo needs
that the package manager did not: **`lerna bootstrap`** (symlink local packages
and install their externals) and **`lerna publish`** (bump versions across the
repo, generate changelogs, git-tag, and push to the registry in topological
order). That release-coordination half is still Lerna's enduring value — it is,
per the README, _"a fast, modern build system for managing and publishing
multiple JavaScript/TypeScript packages from the same repository"_ ([`README.md`][readme]).

The landscape then shifted twice. First, the package managers absorbed
`workspaces`, making `lerna bootstrap` largely redundant (it is now a thin
shim over the package manager). Second, **Nx, Turborepo, and friends** redefined
the bar for the _other_ half — task running — with project graphs, content-hashed
caching, and `affected`-style change detection that Lerna's original
"run-the-script-in-every-package" loop could not match. Rather than reinvent
that machinery, Lerna's maintainers (now the Nx team) **rebased Lerna's task
running onto Nx**: today `lerna run build` is, under the hood, an Nx
`runMany`/`runOne` invocation with a Lerna-shaped CLI. The documentation is
blunt about the equivalence — _"When it comes to running tasks, caching etc.,
Lerna and Nx can be used interchangeably"_ ([cache-tasks][cache]).

So a modern Lerna repo is best understood as **two layers with two owners**:

1. **Lerna's layer** — package discovery from the package manager's workspaces,
   the `--scope`/`--ignore`/`--since` _project filter_, and the
   `version`/`publish`/`changed`/`diff` release toolchain.
2. **Nx's layer** — the project graph, the task DAG, `dependsOn` task
   dependencies, the computation hash, and the local/remote cache (Nx Cloud).

### Design philosophy

Lerna's current philosophy follows directly from the stewardship change:
**don't compete with Nx; compose with it, and keep the publishing crown.** The
`lerna run` source makes the delegation explicit — the default branch builds an
Nx invocation and the legacy hand-rolled runners are only reached when the user
opts out ([`libs/commands/run/src/index.ts`][runsrc]):

```ts
// libs/commands/run/src/index.ts — RunCommand.execute (abridged)
let runScripts: () => Promise<unknown>;
if (this.options.useNx !== false) {
  runScripts = () => this.runScriptsUsingNx(); // DEFAULT: Nx runOne/runMany
} else if (this.options.parallel) {
  runScripts = () => this.runScriptInPackagesParallel(); // legacy
} else if (this.toposort) {
  runScripts = () => this.runScriptInPackagesTopological(); // legacy (PQueue)
} else {
  runScripts = () => this.runScriptInPackagesLexical(); // legacy
}
```

Three consequences follow:

1. **Lerna is a release tool first, a task runner second.** Its irreplaceable
   commands — `lerna version` and `lerna publish` — have no Nx equivalent; they
   own conventional-commits version bumping, lockstep ("fixed") vs `independent`
   versioning, changelog generation, git tagging, and registry publish. This is
   the sharpest contrast with [Turborepo][turborepo] and [Nx][nx] themselves,
   neither of which publishes packages.
2. **Topology comes from the package manager, not from Lerna.** Lerna does not
   own a dependency-isolation model; it reads `package.json#workspaces` (or
   `pnpm-workspace.yaml`) and lets the package manager do hoisting/symlinking
   (see [Dependency handling](#dependency-handling--isolation)).
3. **The task graph and cache are Nx's.** Lerna inherits Nx's content-addressed
   computation hash and Nx Cloud remote cache wholesale — it adds no cache of
   its own.

Within this survey Lerna is the **historical progenitor and the
release-management specialist** of the JS/TS task-orchestrator family. Compare
it with its now-parent [Nx][nx] (which it delegates to), its sibling
[Turborepo][turborepo] (also Nx-owned since 2025, same "graph + hash + remote
cache" model), and the package managers it sits on — [pnpm][pnpm],
[Yarn Berry][yarn-berry], [npm][npm], [Bun][bun].

---

## Core concepts and files

| Concept                 | File / item                                         | Role                                                                                   |
| ----------------------- | --------------------------------------------------- | -------------------------------------------------------------------------------------- |
| Workspace config        | `lerna.json` (repo root)                            | `version`, optional `packages` globs, `npmClient`, `command.*`, `useNx`                |
| Package discovery       | `Project.#resolvePackageConfigs()`                  | Resolves the package globs from `lerna.json` / workspaces / `pnpm-workspace.yaml`      |
| Project graph           | `ProjectGraphWithPackages` (`@lerna/core`)          | Nodes = packages, edges = local deps; reuses Nx's `ProjectGraph` plus package metadata |
| Project filter          | `filterProjects()` + `filterOptions()`              | `--scope`, `--ignore`, `--since`, `--include-dependents`, `--include-dependencies`     |
| Task delegation         | `runOne` / `runMany` (from `nx/src/command-line`)   | The default `lerna run` path; Nx schedules, hashes, and caches                         |
| Legacy runner           | `runProjectsTopologically()` (`PQueue`)             | `useNx: false` fallback — maximally-saturated topological execution                    |
| Version mode            | `lerna.json#version` = `"x.y.z"` or `"independent"` | Lockstep ("fixed") vs per-package independent versioning                               |
| Release toolchain       | `lerna version` / `lerna publish`                   | Conventional-commit bump, changelog, git tag, registry publish                         |
| Change detection        | `collectUpdates()` / `lerna changed` / `--since`    | Git-diff-based "which packages changed since the last tag/ref"                         |
| Nx config (for caching) | `nx.json` (`lerna add-caching` generates it)        | `targetDefaults`, `namedInputs`, cache + Nx Cloud settings                             |

### The two config files

`lerna.json` is small. Its load-bearing keys are `version` (the repo version, or
the literal string `"independent"`), an optional `packages` glob array, the
`npmClient`, a `command.*` block of per-command defaults, and `useNx`. The repo's
own `lerna.json` is representative ([`lerna.json`][lernajson]):

```json
{
  "$schema": "packages/lerna/schemas/lerna-schema.json",
  "command": {
    "publish": { "tempTag": true },
    "version": {
      "conventionalCommits": true,
      "createRelease": "github",
      "exact": true,
      "message": "chore(release): %s"
    }
  },
  "ignoreChanges": ["**/__fixtures__/**", "**/__tests__/**", "**/*.md"],
  "version": "9.0.7"
}
```

Caching and task-pipeline configuration, by contrast, live in **`nx.json`** —
not `lerna.json` — because the cache is Nx's. `lerna add-caching` scaffolds it:
_"If you don't have `nx.json`, run `npx lerna add-caching`"_ ([cache-tasks][cache]).
A minimal `nx.json` for a Lerna repo declares `targetDefaults` (cacheability and
`dependsOn`) and `namedInputs` exactly as a plain Nx repo would:

```json
{
  "targetDefaults": {
    "build": {
      "dependsOn": ["^build"],
      "outputs": ["{projectRoot}/dist"],
      "cache": true
    },
    "test": { "cache": true }
  },
  "namedInputs": {
    "default": ["{projectRoot}/**/*"],
    "production": ["default", "!{projectRoot}/**/*.spec.ts"]
  }
}
```

---

## How it works

### Package discovery and the project graph

On every command Lerna constructs a `Project` and resolves which package globs
to use. The precedence is explicit in the source ([`libs/core/src/lib/project/index.ts`][projsrc]):

1. **Explicit `packages` in `lerna.json`** wins if present.
2. **`npmClient: "pnpm"`** → read the `packages:` list from `pnpm-workspace.yaml`.
3. Otherwise → read `package.json#workspaces` (array, or the Yarn-classic
   `{ "packages": [...] }` object form).

The method's own doc comment captures the split between _filtering_ and _graph
construction_ — the explicit `packages` glob narrows what commands act on, but
the **full graph is always built from the package manager's workspaces**:

> _"By default, the user's package manager workspaces configuration will be used
> to resolve packages. However, they can optionally specify an explicit set of
> package globs to be used instead. NOTE: This does not impact the project graph
> creation process, which will still ultimately use the package manager
> workspaces configuration to construct a full graph, it will only impact which
> of the packages in that graph will be considered when running commands."_
> — [`libs/core/src/lib/project/index.ts`][projsrc]

The removed `useWorkspaces` option (now a hard error) reinforces the modern
stance — _"By default lerna will resolve your packages using your package
manager's workspaces configuration"_ ([`project/index.ts`][projsrc]). The graph
itself is a `ProjectGraphWithPackages`: Nx's `ProjectGraph` enriched with each
node's `Package` (its `package.json`), and a `localPackageDependencies` map of
the cross-package edges Lerna's topological sort and `--since` logic walk.

### From `lerna run` to an Nx invocation

The default `lerna run <script>` flow is:

1. **Filter** the projects (`filterProjects` over `--scope`/`--ignore`/`--since`),
   then keep only those whose `package.json` actually defines that script as an
   Nx target (`project.data.targets?.[script]`).
2. **Dispatch to Nx.** For a single project Lerna calls Nx's `runOne` with a
   `project:target` string; for many it calls `runMany` with a comma-joined
   project list and the target(s) ([`run/src/index.ts`][runsrc]):

   ```ts
   // libs/commands/run/src/index.ts — runScriptsUsingNx (abridged)
   if (this.projectsWithScript.length === 1 && !Array.isArray(this.script)) {
       return runOne(process.cwd(),
           { "project:target:configuration": fullQualifiedTarget, ...options },
           targetDependencies, extraOptions);
   } else {
       return runMany(
           { projects, targets: [...], ...options },
           targetDependencies, extraOptions);
   }
   ```

3. **Synthesize a `dependsOn` if none is configured.** To preserve Lerna's
   historical default (build a package's local deps first), if the user has _not_
   defined Nx `targetDefaults`/`targetDependencies`, Lerna injects a synthetic
   one — `{ [script]: [{ target: script, dependencies: true }] }` — and sets
   `excludeTaskDependencies: true` so Nx mirrors the old behavior. If the repo
   _does_ have Nx target config, Lerna defers to it and **warns that
   `--parallel`/`--sort`/`--no-sort` are ignored** ([`run/src/index.ts`][runsrc]).

The Nx options Lerna maps are familiar: `--concurrency` → Nx `parallel`,
`--no-bail` → `nxBail: false`, `--no-reject-cycles` → `nxIgnoreCycles`,
`--skip-nx-cache` → `skipNxCache`. It even relabels Nx's terminal output —
`output.cliName = "Lerna (powered by Nx)"`.

### The legacy task runner (`useNx: false`)

When Nx is disabled, Lerna falls back to its pre-6 runners. The interesting one
is `runProjectsTopologically`, which executes in _"maximally-saturated
topological order"_ using a `p-queue` with bounded concurrency
([`libs/core/src/lib/run-projects-topologically.ts`][toposrc]): it computes a
`dependenciesBySource` map from the graph's `localPackageDependencies`, then
repeatedly queues the **batch of packages with zero unsatisfied dependencies**,
removing each completed package from its dependents' dependency sets — a classic
Kahn-style topological wavefront. Cycles are detected (`getCycles`,
`mergeOverlappingCycles`) and either reported or rejected per `--reject-cycles`.
This runner has **no caching and no input hashing** — it is the behavior Nx was
brought in to supersede. (Notably, `lerna exec` still uses _only_ this legacy
runner — it does not route through Nx.)

### Versioning and publishing (the part Nx does not do)

`lerna version` is Lerna's crown jewel and has no Nx counterpart. It supports two
modes, keyed by `lerna.json#version` — _"The version of the repository, or
`"independent"` for a repository with independently versioned packages"_
([`lerna-schema.json`][schemafile]):

- **Fixed / lockstep** (`"version": "1.4.0"`) — all packages share one version;
  bumping bumps them all together.
- **Independent** (`"version": "independent"`) — each package is versioned on its
  own; `Project.isIndependent()` switches the bump logic per package
  ([`libs/commands/version/src/index.ts`][versionsrc]).

With `conventionalCommits: true`, Lerna parses commit messages to **recommend**
the next version per package (`recommendVersion`), generates/updates
`CHANGELOG.md`, writes the new versions into every affected `package.json` (and
into local dependency ranges), commits with the configured `message`, git-tags,
optionally creates a GitHub/GitLab release (`createRelease`), and pushes.
`lerna publish` then publishes the tagged versions to the registry in
topological order, with options like `tempTag` (publish under a temp dist-tag,
then move it) to make multi-package publishes more atomic. `lerna changed`
previews which packages a `lerna version` would bump.

---

## Workspace declaration & topology

Lerna has **no workspace-members array of its own by default** — topology is
inherited from the package manager, with an _optional_ Lerna-specific override.

- **Default (inherited):** the root `package.json#workspaces` globs (npm / Yarn /
  Bun), or `pnpm-workspace.yaml` `packages:` when `"npmClient": "pnpm"`.

  ```json
  // package.json
  { "workspaces": ["packages/*", "apps/*"] }
  ```

- **Override:** an explicit `packages` array in `lerna.json`, which **narrows
  which packages commands act on** but does not change graph construction:

  ```json
  // lerna.json
  { "version": "independent", "packages": ["packages/*"] }
  ```

Every resolved package becomes a graph node carrying its `Package`
(`package.json`) metadata. There is no Cargo-style "virtual workspace vs
root-package" distinction — the root `package.json` is always the de-facto
virtual root, and Lerna does not require it to be publishable. This mirrors
[Nx][nx] exactly (both inherit topology from the package manager) and contrasts
with [Cargo][cargo]'s `[workspace] members` and [Go workspaces][go-work]'s
`go.work` `use` directives, where the language tool owns topology declaration.

## Dependency handling & isolation

Like [Nx][nx], **Lerna does not isolate or store dependencies** — there is no
virtual store ([pnpm][pnpm]), no Plug'n'Play ([Yarn Berry][yarn-berry]), and no
Lerna lockfile. Installation, hoisting, symlinking, and `node_modules` layout are
the package manager's job.

- **Local cross-references** use the package manager's mechanism: package `A`
  declares `"@org/B": "*"` (or a `workspace:` range under pnpm/yarn), and the
  package manager symlinks `node_modules/@org/B` to the local directory. Lerna
  reads those `package.json` deps to draw `localPackageDependencies` edges and
  to drive topological ordering and `--since` impact analysis.
- **`lerna bootstrap` is legacy.** It historically did the symlink + install
  itself (with a `hoist` option to dedupe shared externals at the root), but is
  now deprecated in favor of native workspaces; modern Lerna repos run
  `npm/yarn/pnpm install` instead.
- **`lerna link`** still exists to symlink local packages together for repos not
  using package-manager workspaces, but it is a minority path.
- **External dependency versions** feed Nx's computation hash (via Nx's
  `external` input class), so a lockfile change correctly invalidates affected
  tasks even though Lerna never parses the lockfile for installation.

The upshot mirrors Nx: Lerna is **complementary** to the package manager, owning
release coordination and a filter, while the package manager owns isolation.

## Task orchestration & scheduling

There is a real task DAG — but **it is Nx's**, reached by default since
`lerna@6`.

- **DAG + scheduling (default):** `lerna run`/`lerna exec` → Nx `runMany`/`runOne`,
  which expands `dependsOn` over the project graph into a `TaskGraph`,
  topologically sorts it, runs independent legs concurrently
  (`--concurrency` maps to Nx `parallel`), and honors `nxBail`/`nxIgnoreCycles`.
  Nx's batch mode and forked-process runner apply unchanged.
- **DAG + scheduling (legacy, `useNx: false`):** `runProjectsTopologically`'s
  `p-queue` wavefront — concurrent, topology-respecting, but **uncached**.
- **Change detection** is two-flavored and double-layered:
  - **Lerna's `--since [ref]`** filter (and `lerna changed`) prunes the package
    set by git diff against a ref/tag _before_ scheduling — _"Only include
    packages that have been changed since the specified [ref]. If no ref is
    passed, it defaults to the most-recent tag"_ ([`filter-options.ts`][filtersrc]).
    It optionally widens to transitive dependents (`--include-dependents`) or
    narrows (`--exclude-dependents`).
  - **Nx's computation hash** then prunes execution _during_ scheduling: a task
    whose input hash already exists in the cache is replayed, not re-run.

```bash
lerna run build                       # Nx runMany: build all (topological, cached)
lerna run test --scope "@org/api"     # filter to one package, then Nx
lerna run lint --since main           # only packages changed vs main (+ dependents)
lerna run build --concurrency 8       # 8-wide
lerna run build --no-bail             # don't stop on first failure
```

## Caching & remote execution

Lerna's caching **is Nx's caching** — it ships none of its own.

- **Local cache.** Provided transparently by Nx once `nx.json` declares
  `"cache": true` targets — _"Lerna uses a computation cache to never rebuild the
  same code twice"_ and _"By default, Lerna (via Nx) uses a local computation
  cache"_ ([cache-tasks][cache]). `lerna add-caching` scaffolds the `nx.json`;
  `--skip-nx-cache` bypasses it.
- **Remote cache (distributed).** Inherited from **Nx Cloud / Nx Replay** —
  _"The computation cache provided by Lerna can be distributed across multiple
  machines"_ and Nx Cloud offers _"a fast and zero-config implementation of
  distributed caching"_ ([share-your-cache][share]). Enabled with
  `npx nx connect-to-nx-cloud` from the Lerna workspace root; `--no-cloud` or
  `NX_NO_CLOUD=true` disables it. (Self-hosting uses Nx's OpenAPI-spec cache
  server — see the [Nx deep-dive][nx].)
- **Remote execution (REAPI).** **Not supported** — Lerna inherits Nx's
  "cache-and-replay" model, not Bazel-style sandboxed remote action execution.
  The docs describe only cache reuse — _"Nx read the output from the cache
  instead of running the command"_ ([share-your-cache][share]). For true RBE see
  [Bazel][bazel] / [Buck2][buck2] over [Buildbarn][buildbarn] /
  [BuildBuddy][buildbuddy] / [NativeLink][nativelink].

> [!NOTE]
> Because Lerna's cache _is_ Nx's, the cache-poisoning history of Nx's
> deprecated self-hosted storage-cache plugins (CVE-2025-36852, "CREEP") applies
> to self-hosted Lerna caches too. See the [Nx deep-dive][nx] for the detail and
> the OpenAPI-spec replacement.

## CLI / UX ergonomics

Lerna's command surface is **verb-centric with a rich project filter** — the
`scope`/`since` filter family is its ergonomic signature and predates the
`--filter` DSLs of [pnpm][pnpm] and [Turborepo][turborepo].

| Goal                              | Command                                                     |
| --------------------------------- | ----------------------------------------------------------- |
| Run a script everywhere           | `lerna run build`                                           |
| Filter by package name glob       | `lerna run test --scope "@org/api"`                         |
| Exclude by package name glob      | `lerna run test --ignore "@org/*-e2e"`                      |
| Only packages changed since a ref | `lerna run build --since origin/main`                       |
| Widen to dependents               | `lerna run build --since main --include-dependents`         |
| Widen to dependencies             | `lerna run build --scope "@org/api" --include-dependencies` |
| Run an arbitrary command          | `lerna exec -- rm -rf dist`                                 |
| List packages / changed packages  | `lerna list` · `lerna changed`                              |
| Set concurrency                   | `lerna run build --concurrency 8`                           |
| Skip the (Nx) cache               | `lerna run build --skip-nx-cache`                           |
| Bump versions                     | `lerna version` (`major`/`minor`/`patch` or conventional)   |
| Publish to the registry           | `lerna publish` (or `lerna publish from-git`)               |

- **`--scope` / `--ignore`** are name-glob filters; **`--since [ref]`** is the
  git-diff "affected" filter (defaulting to the most-recent tag). The
  dependents/dependencies modifiers (`--include-dependents`,
  `--exclude-dependents`, `--include-dependencies`) tune the graph traversal —
  the same "changed projects **and** their dependents" idea [Nx][nx]'s
  `affected` bakes in, but exposed as composable flags
  ([`filter-options.ts`][filtersrc]).
- The filter applies to `run`, `exec`, `clean`, `list`, and historically
  `bootstrap`. Compared with [Nx][nx]'s `-t`/`-p` + `affected` verb or
  [Bazel][bazel]'s `//path:target` colon syntax, Lerna reads as
  _verb + glob/since filter_, which is terse for name-based selection but lacks
  Nx's tag-based project selection.

---

## Strengths

- **Best-in-class release tooling.** `lerna version` + `lerna publish` —
  conventional-commit bumping, fixed vs `independent` modes, changelog
  generation, git tagging, GitHub/GitLab releases, topological registry publish —
  remain unmatched by [Nx][nx]/[Turborepo][turborepo], which don't publish.
- **Modern task running for free.** By delegating to [Nx][nx], a Lerna repo gets
  a project graph, a task DAG, content-hashed caching, and Nx Cloud remote
  caching without adopting Nx's command surface.
- **Incremental adoption.** Drops onto any existing npm/yarn/pnpm/bun workspace;
  `lerna add-caching` is a one-liner to turn on the cache.
- **Mature, expressive filter.** `--scope`/`--ignore`/`--since` plus the
  dependents/dependencies modifiers are a precise, composable selection DSL.
- **Stable and long-lived.** A decade of production use; the canonical answer to
  "JS monorepo" that taught the ecosystem the patterns the newer tools refined.

## Weaknesses

- **No longer an independent tool.** Task running and caching are Nx's; Lerna is
  effectively an Nx front-end plus a publisher. "Lerna and Nx can be used
  interchangeably" cuts both ways — for pure task running, Nx is the substrate.
- **`bootstrap`/`link` are legacy.** The original reason to use Lerna
  (installing/linking local packages) is now the package manager's job; these
  commands are deprecated or minority paths.
- **Caching config lives in `nx.json`, not `lerna.json`.** Two config files with
  two owners; the cache knobs, `targetDefaults`, and `namedInputs` are pure Nx,
  which surprises users who expect `lerna.json` to be the single source of truth.
- **No remote execution.** Cache-and-replay only (inherited from Nx); large
  native builds favor [Bazel][bazel]/[Buck2][buck2].
- **Two task runners, divergent behavior.** The default Nx path and the
  `useNx: false` legacy path differ in caching, `--parallel`/`--sort` handling,
  and `dependsOn` semantics; `--parallel`/`--sort` are silently ignored once Nx
  targets are configured.
- **`exec` bypasses Nx.** `lerna exec` still uses only the legacy
  topological/parallel runners — so it is uncached even when `run` is not.

## Key design decisions and trade-offs

| Decision                                                | Rationale                                                                        | Trade-off                                                                               |
| ------------------------------------------------------- | -------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Delegate task running + caching to Nx (`useNx` default) | Get a project graph, task DAG, and content-hashed cache without reinventing them | Lerna becomes an Nx front-end; task config lives in `nx.json`; two-tool mental model    |
| Keep `version`/`publish` as Lerna's own                 | Release coordination has no Nx equivalent; it is Lerna's durable value           | Splits the repo's config across `lerna.json` (release) and `nx.json` (tasks)            |
| Inherit topology from the package manager               | Composes with any npm/yarn/pnpm/bun workspace; incremental adoption              | No Lerna-owned topology/isolation; inherits the package manager's resolution model      |
| Optional `packages` glob narrows _commands only_        | Lets a repo scope Lerna's actions without re-declaring the whole graph           | Subtle: the graph is still built from workspaces, so filtering ≠ graph membership       |
| `--since [ref]` filter + dependents modifiers           | Composable, explicit change-bounding that predates `affected`                    | Less automatic than Nx's `affected`; correctness depends on git tags/refs               |
| Fixed vs `independent` versioning modes                 | Supports both monorepo release philosophies from one flag                        | Independent mode multiplies changelog/tag bookkeeping; fixed mode over-bumps quiet pkgs |
| Legacy runner retained behind `useNx: false`            | Backward compatibility for repos that can't/won't adopt Nx                       | Divergent behavior, no caching, and silently-ignored flags vs the default path          |
| Cache-and-replay only (no REAPI)                        | Matches JS/TS needs; simple trust model via Nx Cloud                             | No sandboxed remote action execution for heavy/native builds                            |

---

## Sources

- [lerna/lerna — GitHub repository][repo] (source for all quoted file paths; cloned at `9.0.7`)
- [lerna.js.org — documentation][docs] · [features overview][features]
- [Cache Tasks (Lerna via Nx)][cache] — _"Lerna and Nx can be used interchangeably"_, `lerna add-caching` (verbatim quotes)
- [Share Your Cache (Nx Cloud / distributed caching)][share] — remote caching, `npx nx connect-to-nx-cloud` (verbatim quotes)
- [`README.md`][readme] — _"a fast, modern build system…"_, Nx stewardship banner
- [`lerna.json`][lernajson] — the repo's own config (fixed `version`, `command.*`)
- [`packages/lerna/schemas/lerna-schema.json`][schemafile] — `version`/`independent` semantics (verbatim quote)
- [`libs/core/src/lib/project/index.ts`][projsrc] — package discovery precedence, the filtering-vs-graph doc comment (verbatim quote)
- [`libs/commands/run/src/index.ts`][runsrc] — Nx delegation (`runOne`/`runMany`), synthetic `dependsOn`, legacy runners
- [`libs/core/src/lib/run-projects-topologically.ts`][toposrc] — legacy maximally-saturated topological runner
- [`libs/core/src/lib/filter-options.ts`][filtersrc] — `--scope`/`--ignore`/`--since` filter DSL (verbatim quote)
- [`libs/commands/version/src/index.ts`][versionsrc] — fixed vs independent versioning
- npm registry metadata — `latest` = `9.0.7` (2026-03-13); first publish `1.0.1` (2015-12-04)
- Sibling docs: [Nx][nx] · [Turborepo][turborepo] · [pnpm][pnpm] · [Yarn Berry][yarn-berry] · [npm][npm] · [Bun][bun] · [Cargo][cargo] · [Go workspaces][go-work] · [Bazel][bazel] · [Buck2][buck2] · [Buildbarn][buildbarn] · [BuildBuddy][buildbuddy] · [NativeLink][nativelink] · [the D landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/lerna/lerna
[docs]: https://lerna.js.org/
[features]: https://lerna.js.org/docs/features
[cache]: https://lerna.js.org/docs/features/cache-tasks
[share]: https://lerna.js.org/docs/features/share-your-cache
[schema]: https://lerna.js.org/docs/api-reference/configuration
[readme]: https://github.com/lerna/lerna/blob/main/README.md
[lernajson]: https://github.com/lerna/lerna/blob/main/lerna.json
[schemafile]: https://github.com/lerna/lerna/blob/main/packages/lerna/schemas/lerna-schema.json
[projsrc]: https://github.com/lerna/lerna/blob/main/libs/core/src/lib/project/index.ts
[runsrc]: https://github.com/lerna/lerna/blob/main/libs/commands/run/src/index.ts
[toposrc]: https://github.com/lerna/lerna/blob/main/libs/core/src/lib/run-projects-topologically.ts
[filtersrc]: https://github.com/lerna/lerna/blob/main/libs/core/src/lib/filter-options.ts
[versionsrc]: https://github.com/lerna/lerna/blob/main/libs/commands/version/src/index.ts
[nx]: ../nx/
[turborepo]: ../turborepo/
[pnpm]: ../pnpm/
[yarn-berry]: ../yarn-berry/
[npm]: ../npm/
[bun]: ../bun/
[cargo]: ../cargo/
[go-work]: ../go-work/
[bazel]: ../bazel/
[buck2]: ../buck2/
[buildbarn]: ../buildbarn/
[buildbuddy]: ../buildbuddy/
[nativelink]: ../nativelink/
[d-landscape]: ../../async-io/d-landscape.md
