# Rush (JavaScript/TypeScript)

Microsoft's enterprise-scale monorepo orchestrator: Rush does **not** invent its
own package store — it drives `pnpm` (or `yarn`/`npm`) underneath — but it adds an
explicitly-enumerated project inventory, a deterministic shared install, a global
incremental build engine with content-addressed caching, distributed "cobuilds",
and a policy/versioning layer designed for hundreds of packages and dozens of teams.

| Field           | Value                                                                                                    |
| --------------- | -------------------------------------------------------------------------------------------------------- |
| Language        | TypeScript (the `@microsoft/rush` CLI + the `@rushstack/*` engine and plugins)                           |
| License         | MIT                                                                                                      |
| Repository      | [microsoft/rushstack][repo] (Rush lives in `apps/rush`)                                                  |
| Documentation   | [rushjs.io][docs] · [`rush.json` reference][rushjson] · [`command-line.json` reference][cmdline]         |
| Category        | JS/TS Task Orchestrator                                                                                  |
| Workspace model | **Explicit project registry** (`rush.json` `projects[]`) layered over the package manager's `workspace:` |
| First released  | 2017 (open-sourced by the Microsoft SharePoint platform team; in-house since ~2016)                      |
| Latest release  | `5.175.1` (April 20, 2026)                                                                               |

> **Latest release:** `@microsoft/rush` `5.175.1`, published April 20, 2026 (the
> CLI has stayed on the `5.x` line for years; the engine packages under
> `@rushstack/*` version independently). Rush is installed globally and
> self-bootstraps the exact version pinned in `rush.json` `rushVersion`, so a
> repo's contributors all run the same Rush regardless of what they typed
> `npm install -g`. Build caching, cobuilds, and subspaces are all marked
> **EXPERIMENTAL** in their config schemas but are used in production at
> Microsoft, TikTok, and others.

---

## Overview

### What it solves

A large JS/TS monorepo has two distinct problems, and most tools solve only one.
The first is **installation**: dozens of inter-dependent packages must resolve to a
single, deterministic `node_modules` layout without each package secretly relying
on a dependency it never declared. The second is **orchestration**: running
`build`/`test`/`lint` across all packages in dependency order, in parallel, while
skipping work that hasn't changed. Plain `pnpm`/`yarn`/`npm` `workspaces` (see
[pnpm], [yarn-berry], [npm]) solve the first; pure orchestrators like [Turborepo]
or [Nx][nx] bolt the second onto a package manager's workspaces; Rush is unusual in
that it **owns both ends** — it wraps the package manager's install _and_ ships a
global incremental build engine — under one opinionated, policy-enforcing CLI.

From the project's own framing ([`welcome.md`][welcome-src]):

> _"Rush makes life easier for JavaScript developers who build and publish many
> NPM packages at once. … In one step, Rush installs all the dependencies for all
> your projects into a common folder. … Inside a Rush repo, all your projects are
> automatically symlinked to each other."_

The headline differentiator from a plain workspace is **scale + governance**: a
single deterministic lockfile (or, with [subspaces](#subspaces-sharding-the-install),
several), a consistent-versions policy that fails the build on drift, coordinated
multi-package publishing with changelog generation, and an incremental build that
performs _"its own global analysis of the repo, in a single pass"_ so build scripts
_"are not invoked at all for projects that are up to date"_ ([incremental builds
docs][incr]).

### Design philosophy

Three convictions shape Rush's design, and each is a deliberate departure from the
JS-ecosystem default:

1. **Explicit over implicit.** Projects are enumerated by hand in `rush.json`
   `projects[]` — Rush _"does not automatically scan for projects using
   wildcards"_ ([`rush.json` reference][rushjson]). The same explicitness governs
   dependency declarations: Rush actively hunts for **phantom dependencies** (code
   importing a package it never declared) and treats them as bugs.
2. **Determinism and policy as first-class build steps.** With
   `ensureConsistentVersions`, mismatched dependency versions across packages are a
   hard error before `rush install` even resolves; version policies, allowed
   change types, and review categories are config, not convention.
3. **Multi-process parallelism beats single-process cleverness.** Rush's value is
   in fanning real OS processes across the dependency graph — the docs quip that
   this yields _"more significant speedups than all those async functions in your
   single-process toolchain."_

Rush was _"created by the platform team for Microsoft SharePoint"_ and is now the
flagship of the broader **Rush Stack** family (`@rushstack/heft`, `api-extractor`,
`eslint-config`, …). It targets the same niche as [Nx][nx], [Turborepo], and
[Lerna] but stakes out the "batteries-included, governance-heavy" corner; see the
[comparison] for where the orchestrators diverge, and [d-landscape] for the D
analogues.

---

## How it works

Rush is a thin (but opinionated) layer that turns a package manager into a
governed monorepo. The control flow of a build splits cleanly into two engines.

**Install engine (delegated).** `rush install` / `rush update` translate the
explicit `projects[]` registry into the package manager's native `workspace:`
configuration, run a single install into a repo-root `common/temp/node_modules`,
and commit the resulting lockfile to `common/config/rush/pnpm-lock.yaml`
(`shrinkwrap` for older managers). Rush never re-implements resolution — it relies
on `pnpm`'s strict, symlinked store for isolation (below).

**Build engine (native).** `rush build` builds an **operation graph** from the
project dependency graph, hashes each operation's inputs, consults the build cache,
and schedules cache-miss operations across worker processes in topological order.

### Workspace declaration and topology

Rush's workspace is a **single explicit registry** at the repo root. Every package
is hand-listed in `rush.json` `projects[]` with a `packageName` → `projectFolder`
mapping:

```json
// rush.json (excerpt)
{
  "rushVersion": "5.175.1",
  "pnpmVersion": "9.15.0",
  "nodeSupportedVersionRange": ">=18.20.0 <19.0.0 || >=20.18.0 <21.0.0",
  "ensureConsistentVersions": true,
  "projectFolderMinDepth": 2,
  "projectFolderMaxDepth": 2,
  "projects": [
    {
      "packageName": "@my-company/my-controls",
      "projectFolder": "libraries/my-controls",
      "reviewCategory": "production",
      "shouldPublish": true,
      "tags": ["frontend-team"]
    },
    {
      "packageName": "@my-company/web-app",
      "projectFolder": "apps/web-app",
      "decoupledLocalDependencies": ["@my-company/my-toolchain"]
    }
  ]
}
```

Key topology facts:

- **No globs.** Unlike [pnpm]'s `packages: ['packages/*']` or [Cargo][cargo]'s
  `members = ["crates/*"]`, Rush requires a literal entry per project. The
  `projectFolderMinDepth` / `projectFolderMaxDepth` fields don't _discover_
  projects — they constrain the folder shape so the registry stays tidy.
- **The package manager is chosen, not assumed.** Exactly one of `pnpmVersion` /
  `yarnVersion` / `npmVersion` is set; `pnpm` is the recommended default and the
  only one that gets full phantom-dependency protection.
- **`decoupledLocalDependencies`** (formerly `cyclicDependencyProjects`) opts a
  local dependency _out_ of symlinking, letting Rush tolerate dependency cycles
  the build graph would otherwise reject.
- **`tags`** annotate projects for selector expressions (see
  [CLI ergonomics](#cli--ux-ergonomics)); `reviewCategory` and `versionPolicyName`
  feed the governance/publishing layer.

> [!NOTE]
> The explicit registry is the price of Rush's determinism: every project is
> visible to policy checks and the selector engine without a filesystem scan, and
> adding a project is a reviewable diff to one file. The cost is manual upkeep — a
> common complaint versus glob-based workspaces.

### Dependency handling and isolation

Each project keeps its **own** `package.json` declaring its real dependencies; Rush
links projects that depend on each other locally rather than from the registry —
_"all your projects are automatically symlinked to each other"_. Isolation is
delegated to the package manager, and Rush strongly prefers `pnpm` precisely
because `pnpm`'s content-addressed store and per-package symlinked `node_modules`
make phantom dependencies impossible by construction. Rush defines the hazard
([phantom dependencies doc][phantom]):

> _"A phantom dependency is when a project uses a package that is not defined in
> its `package.json` file."_

The install is **single-lockfile by default**: one `common/config/rush/pnpm-lock.yaml`
governs the whole repo, guaranteeing every package sees the same resolved version
of every transitive dependency. `ensureConsistentVersions` makes _declared_
versions agree too — a mismatch is rejected before install. For repos where one
giant lockfile becomes a bottleneck, **subspaces** shard it:

#### Subspaces: sharding the install

A subspace is a named partition that gets **its own lockfile** under
`common/config/subspaces/<name>/pnpm-lock.yaml`, declared centrally in
`common/config/subspaces.json`:

```json
// common/config/subspaces.json
{
  "subspacesEnabled": true,
  "subspaceNames": ["default", "my-team", "experimental"]
}
```

Every project belongs to exactly one subspace (assigned in `rush.json`), yet the
repo remains _"one unified workspace"_ — a `package.json` can still use the
`workspace:` specifier to depend on a project in another subspace. Subspaces let a
huge codebase _"install using multiple PNPM lockfiles"_, bounding install time and
blast radius, and they double as an isolated-install testing trick (move test
projects into a subspace to get a publish-like install without a real registry).
This is Rush's answer to the install-scaling problem that single-lockfile tools
([Cargo][cargo], [go-work]) don't face and that other JS orchestrators leave to
the package manager.

### Task orchestration and scheduling

Rush's build engine is a **global, incremental, topological scheduler** — the most
substantial part of the tool.

**Bulk vs. phased commands.** A _bulk_ command (the classic model) runs one
`package.json` script per project — `rush build` looks for a `"build"` script in
each project and runs them in dependency order. A _phased_ command splits each
project's work into named **phases** (`_phase:build`, `_phase:test`, …), letting
Rush interleave phases across projects: project B's `_phase:build` can start as
soon as A's `_phase:build` finishes, without waiting for A's `_phase:test`. Phases
are declared in `common/config/rush/command-line.json`:

```json
// common/config/rush/command-line.json (excerpt)
{
  "phases": [
    {
      "name": "_phase:build",
      "dependencies": { "upstream": ["_phase:build"] },
      "ignoreMissingScript": true
    },
    {
      "name": "_phase:test",
      "dependencies": { "self": ["_phase:build"] },
      "ignoreMissingScript": true
    }
  ]
}
```

The two dependency kinds are the whole grammar of the graph:

| Field      | Meaning                                                              |
| ---------- | -------------------------------------------------------------------- |
| `upstream` | this phase waits for the **same/named phase in dependency projects** |
| `self`     | this phase waits for the **named phase within the same project**     |

From these, Rush constructs an **operation graph whose nodes are `(project ×
phase)` pairs**; edges come from `upstream`/`self`. Independent nodes run
concurrently (default parallelism = number of CPU cores, tunable with
`--parallelism`). `ignoreMissingScript` lets a project opt out of a phase without
failing the run.

**Change detection.** `rush build` is _"hard-wired to be incremental"_ (`rush
rebuild` is the force-everything variant). Before running an operation, Rush
computes a hash over: the project's tracked source files (respecting
`.gitignore`), the hashes of its dependency projects, the resolved versions of
every direct and indirect NPM dependency, and the command-line parameters. If the
hash matches a prior run, the operation is skipped (or restored from cache). This
input hashing is what lets Rush _"perform its own global analysis of the repo, in
a single pass"_ and avoid invoking scripts for up-to-date projects — the same
content-addressing principle [Turborepo], [Nx][nx], and [Bazel][bazel] use, but
computed natively by the engine rather than by a script wrapper.

### Caching and remote execution

Rush has **two** layers of build acceleration, and it is careful to call neither
of them remote execution.

**1. Content-addressed build cache** (`common/config/rush/build-cache.json`).
Opt-in and marked _"EXPERIMENTAL"_; the cache key is the operation hash above, and
the cached payload is the project's declared output folders. Providers:

```json
// common/config/rush/build-cache.json (excerpt)
{
  "buildCacheEnabled": true,
  "cacheProvider": "amazon-s3",
  "amazonS3Configuration": {
    "s3Region": "us-east-1",
    "s3Bucket": "my-build-cache",
    "isCacheWriteAllowed": false
  }
}
```

| `cacheProvider`      | Backend                                                          |
| -------------------- | ---------------------------------------------------------------- |
| `local-only`         | on-disk cache under `.rush/build-cache` (the default)            |
| `azure-blob-storage` | an Azure Blob container (SAS token)                              |
| `amazon-s3`          | an S3 bucket (or S3-compatible endpoint)                         |
| `http`               | any HTTP cache server (added later; powers self-hosted backends) |

Each cacheable project lists its outputs in `config/rush-project.json`
(`projectOutputFolderNames`); the docs warn these _"folders should not be tracked
by Git. They must not contain symlinks."_ Cloud writes authenticate via
`RUSH_BUILD_CACHE_CREDENTIAL` (Azure SAS token; or `<AccessKeyID>:<SecretAccessKey>`
[`:<SessionToken>`] for AWS), and CI gates write access with
`RUSH_BUILD_CACHE_WRITE_ALLOWED` so PR builds read but don't poison the cache.

**2. Cobuilds** (`common/config/rush/cobuild.json`, experimental). Cobuilds turn
several identical CI agents into a cooperating swarm using the build cache **plus**
a distributed lock (the official provider is Redis, via
`@rushstack/rush-redis-cobuild-plugin`):

```json
// common/config/rush/cobuild.json
{
  "cobuildFeatureEnabled": true,
  "cobuildLockProvider": "redis"
}
```

All agents run the same `rush build`; for each operation cluster they race to
acquire a Redis lock keyed `cobuild:lock:<context_id>:<cluster_id>`. The winner
builds and writes the cache; the losers read the result from the cache instead of
rebuilding — so N machines split the graph without a central scheduler.
`RUSH_COBUILD_CONTEXT_ID` (shared per pipeline run, changed on retry) gates the
feature; `RUSH_COBUILD_RUNNER_ID` identifies each machine.

> [!IMPORTANT]
> **Cobuilds are not remote execution (REAPI).** Rush has no REAPI backend and
> does not ship actions to a [Bazel][bazel]-style remote executor; it does not
> centralize scheduling or replace the CI system. Cobuilds are a _cache-plus-lock_
> coordination layer over CI machines you already have — _"a cheap way to get
> distributed builds"_ — sitting a tier below true remote execution backends.

### CLI / UX ergonomics

Rush's command boundary is a **global verb + a rich project-selector grammar**.
The default scope of `rush build` is the whole repo in dependency order; selectors
narrow it. The core selectors (from [selecting subsets][selectsubsets]):

| Selector flag          | Selects                                                                 |
| ---------------------- | ----------------------------------------------------------------------- |
| `--to <p>`             | project `p` **and everything it depends on** (build it for real)        |
| `--to-except <p>`      | `p`'s dependencies, but **not** `p` itself                              |
| `--from <p>`           | `p`, **everything that depends on** `p`, and their dependencies         |
| `--only <p>`           | exactly `p`, ignoring its dependencies                                  |
| `--impacted-by <p>`    | projects that **might break** if `p` changes (dependents, deps trusted) |
| `--impacted-by-except` | same, excluding `p` itself                                              |

The selector _argument_ is itself a small expression language — a bare name, or a
**scoped selector**:

- `git:<ref>` — _"calculates the git diff of the current working directory versus
  the referenced commit, then computes a list of affected file paths"_, i.e.
  change-based selection (`rush build --to git:origin/main`).
- `tag:<tag>` — all projects carrying a `tags` entry.
- `subspace:<name>` — all projects in a subspace.
- `.` — the project in the current working directory.

The semantic split between `--to` and `--impacted-by` is the ergonomic crux, and
the docs phrase `--impacted-by` plainly:

> _"Select only those projects that might be broken by a change to B, and trust me
> that their dependencies are in a usable state."_

That is — `--to` rebuilds the world below a target; `--impacted-by` rebuilds the
world _above_ a change while trusting the cache for everything below. Combined with
`git:` selectors, `rush build --impacted-by git:origin/main` is the canonical
"test only what this PR could have broken" invocation — Rush's equivalent of
[Turborepo]'s `--filter=...[origin/main]` or [Nx][nx]'s `nx affected`.

Other ergonomic touches: `rush` self-bootstraps the `rushVersion` from `rush.json`
(no version skew across a team); `rushx <script>` runs a single project's script
through Rush's environment; `rush add`/`rush remove` edit a project's
`package.json` and re-resolve; and custom verbs (bulk or phased) are declared in
`command-line.json`, so `rush lint` or `rush my-pipeline` are first-class commands
with the full selector grammar, not shell wrappers.

---

## Strengths

- **Owns install + orchestration in one governed tool.** One CLI handles
  deterministic installs, incremental builds, caching, and coordinated publishing —
  no need to stack a package manager + an orchestrator + a release tool.
- **Determinism and governance by default.** Single committed lockfile,
  `ensureConsistentVersions`, version policies, review categories, and phantom-
  dependency hunting make large multi-team repos auditable and reproducible.
- **Mature incremental engine with global analysis.** Input-hashed skip logic and
  the `(project × phase)` operation graph predate and rival the dedicated
  orchestrators; phased commands give fine-grained cross-project interleaving.
- **Pluggable, self-hostable caching** (`local-only` / Azure / S3 / `http`) plus
  **cobuilds** for cheap distributed CI builds without standing up a REAPI cluster.
- **Subspaces** scale the install itself — multiple lockfiles in one workspace —
  which single-lockfile ecosystems cannot do.
- **Version-pinned, self-bootstrapping CLI** eliminates "works on my machine"
  tool-version skew.

## Weaknesses

- **No glob discovery.** Every project must be hand-registered in `rush.json`;
  large or fast-churning repos feel the manual upkeep versus glob workspaces
  ([pnpm], [Cargo][cargo]).
- **`pnpm`-centric and JS/TS-only.** Full isolation guarantees assume `pnpm`;
  `npm`/`yarn` are second-class, and Rush has no story for polyglot builds the way
  [Bazel][bazel]/[Nx][nx] reach beyond JS.
- **Headline features are "EXPERIMENTAL."** Build cache, cobuilds, and subspaces
  all carry experimental markers in their schemas — production-proven but evolving.
- **No true remote execution.** Cobuilds share a _cache_, not an action scheduler;
  there is no REAPI backend for hermetic remote builds.
- **Heavy, opinionated, with a learning curve.** The `common/config/rush/` tree,
  version policies, and the bulk-vs-phased distinction are a lot of surface area for
  a small repo; Rush shines at scale and is overkill below it.
- **Cache correctness leans on declared outputs.** `projectOutputFolderNames` and
  `.gitignore` hygiene are the cache's safety contract; mis-declared outputs cause
  stale or missing cache entries.

## Key design decisions and trade-offs

| Decision                                               | Rationale                                                                              | Trade-off                                                                                       |
| ------------------------------------------------------ | -------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Explicit `projects[]` registry, **no globs**           | Every project is visible to policy/selectors without a scan; adds are reviewable diffs | Manual upkeep; friction versus glob-based workspaces                                            |
| Delegate install/isolation to `pnpm`                   | Reuse a battle-tested strict store; phantom deps impossible by construction            | Tied to `pnpm` for full guarantees; `npm`/`yarn` are weaker; JS/TS-only                         |
| Single committed lockfile + `ensureConsistentVersions` | Repo-wide deterministic, drift-free dependency resolution                              | One lockfile can bottleneck huge repos (mitigated by subspaces, which add their own complexity) |
| Native incremental engine with input hashing           | Skip up-to-date work in a single global pass; no per-script wrapper                    | Cache correctness depends on correctly declared output folders and ignore rules                 |
| Phased commands (`_phase:*`, `upstream`/`self`)        | Interleave fine-grained `(project × phase)` operations for higher parallelism          | More config than bulk commands; another mental model to learn                                   |
| Cobuilds = cache + distributed lock (not REAPI)        | Distributed CI builds with just Redis + the existing cache; no executor cluster        | No hermetic remote execution; correctness still bounded by cache hashing                        |
| Subspaces = multiple lockfiles in one workspace        | Bound install time/blast radius; enable isolated-install testing                       | Cross-subspace `workspace:` deps add resolution complexity; more config trees                   |
| Version-pinned, self-bootstrapping CLI                 | Whole team runs the identical Rush regardless of global install                        | Extra bootstrap indirection; a `rushVersion` bump touches everyone                              |

---

## Sources

- [microsoft/rushstack — GitHub monorepo (Rush is `apps/rush`)][repo]
- [rushjs.io — official documentation][docs]
- [`welcome.md` — Rush positioning, verbatim quotes][welcome-src]
- [`rush.json` configuration reference — explicit `projects[]`, no globs][rushjson]
- [`command-line.json` reference — bulk vs phased commands][cmdline]
- [Enabling phased builds — `_phase:*`, `upstream`/`self`][phased]
- [Incremental builds — global single-pass analysis][incr]
- [Phantom dependencies — verbatim definition][phantom]
- [Enabling the build cache — providers, keys, credentials][buildcache]
- [Cobuilds — distributed builds via cache + Redis lock][cobuilds]
- [Rush subspaces — multiple lockfiles in one workspace][subspaces]
- [Selecting subsets of projects — `--to`/`--from`/`--impacted-by`, `git:`/`tag:`][selectsubsets]
- Sibling deep-dives: [pnpm], [yarn-berry], [npm], [Nx][nx], [Turborepo], [Lerna], [Bazel][bazel], [Cargo][cargo], [go-work]
- Umbrella: [Monorepo & Workspace Tooling][umbrella] · cross-tree: [D async-I/O landscape][d-landscape] · [comparison]

<!-- References -->

[repo]: https://github.com/microsoft/rushstack
[docs]: https://rushjs.io/
[welcome-src]: https://github.com/microsoft/rushstack-websites/blob/main/websites/rushjs.io/docs/pages/intro/welcome.md
[rushjson]: https://rushjs.io/pages/configs/rush_json/
[cmdline]: https://rushjs.io/pages/configs/command-line_json/
[phased]: https://rushjs.io/pages/maintainer/phased_builds/
[incr]: https://rushjs.io/pages/advanced/incremental_builds/
[phantom]: https://rushjs.io/pages/advanced/phantom_deps/
[buildcache]: https://rushjs.io/pages/maintainer/build_cache/
[cobuilds]: https://rushjs.io/pages/maintainer/cobuilds/
[subspaces]: https://rushjs.io/pages/advanced/subspaces/
[selectsubsets]: https://rushjs.io/pages/developer/selecting_subsets/
[pnpm]: ../pnpm/
[yarn-berry]: ../yarn-berry/
[npm]: ../npm/
[nx]: ../nx/
[turborepo]: ../turborepo/
[lerna]: ../lerna/
[bazel]: ../bazel/
[cargo]: ../cargo/
[go-work]: ../go-work/
[umbrella]: ../
[comparison]: ../comparison.md
[d-landscape]: ../../async-io/d-landscape.md
