# npm (JavaScript/TypeScript)

Node.js's default package manager: a per-package `package.json` manifest, the [`Arborist`][arborist-pkg] tree-doctor that resolves and reifies a `node_modules` graph, and — since `npm` v7 — a **first-class `workspaces` array** that turns sibling packages into symlinked, locally-resolved members of one root, with no separate workspace manifest and no `workspace:` protocol.

| Field           | Value                                                                                                                            |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Language        | JavaScript (Node.js; the `npm` CLI is itself a Node program)                                                                     |
| License         | Artistic-2.0                                                                                                                     |
| Repository      | [npm/cli][repo] (`Arborist` in [`workspaces/arborist/`][arborist-src])                                                           |
| Documentation   | [docs.npmjs.com][docs]                                                                                                           |
| Category        | JS/TS Package Manager                                                                                                            |
| Workspace model | **Root-package workspace.** A `workspaces` glob array in the root `package.json`; members symlinked into the root `node_modules` |
| First released  | `npm` 1.0 — 2011; bundled with Node.js since the beginning                                                                       |
| Latest release  | `11.16.0` (workspaces shipped in `7.0.0`, 2020-10-13)                                                                            |

> **Latest release:** `11.16.0` (published 2026-05-27; the development tree in [npm/cli][repo] is already tagged `12.0.0-pre.0`). **Workspaces landed in `npm` v7.0.0** (2020-10-13) — the same release that replaced the legacy installer with [`Arborist`][arborist-pkg]. Unlike [pnpm](../pnpm/) and [Yarn Berry](../yarn-berry/), `npm` has **no `workspace:` protocol** and **no `--filter` flag**: cross-member dependencies use ordinary semver ranges, and member selection is spelled `--workspace`/`-w` and `--workspaces`/`-ws`. See [CLI / UX Ergonomics](#5-cli--ux-ergonomics).

---

## Overview

### What it solves

`npm` is the original Node.js package manager and the one bundled with every Node install. Its core job is the same as [Cargo](../cargo/)'s for Rust or [Composer](../composer/)'s for PHP: read a per-package manifest (`package.json`), resolve a transitive dependency graph against the public registry, pin it in a lockfile (`package-lock.json`), and install it into a `node_modules` tree that the Node module resolver can walk.

What `npm` added in v7 is a **monorepo answer built into that same machinery** rather than bolted on by a separate orchestrator. The [npm RFC 0026][rfc] frames it directly:

> _"Add a set of features to the npm cli that provide support to managing multiple packages from within a singular top-level, root package."_

A **workspace** is _"a nested package within the Top-level workspace file system that is explicitly defined as such via workspaces configuration"_ ([RFC 0026][rfc]). You list member globs in the root `package.json`, and from then on a single `npm install` at the root resolves _every_ member's dependencies together, symlinks the members into the root `node_modules`, and lets one member depend on another **locally** — with no publish/`update` cycle, no relative `path=` rewriting, and no separate workspace file. This is the structural model a `dub` `[workspace]` block would most directly imitate; contrast [Composer](../composer/), which has no native workspace at all, and [`go.work`](../go-work/), which adds a _separate_ workspace manifest.

### Design philosophy

`npm` deliberately reused an existing word and an existing resolver. From [RFC 0026][rfc]:

> _"The name 'workspaces' is already established in the community with both Yarn and Pnpm implementing similar features under that same name so we chose to reuse it for the sake of simplicity to the larger community involved."_

The mechanism, however, is `npm`'s own. Workspaces are not a new resolver — they are a new **edge type** inside [`Arborist`][arborist-pkg], the tree engine introduced alongside them. The [Arborist deep-dive][arborist-blog] explains:

> _"We added a new edge type called `workspace`, which is always resolved as a symlink. Then, the `@npmcli/map-workspaces` module reads the set of named workspaces so that they can be turned into these special edges."_

Two consequences define the whole model and recur through the dimensions below:

1. **Members are just packages, linked instead of fetched.** A member is an ordinary `package.json`; the only difference is that `Arborist` resolves a dependency on it to a symlink if its local version satisfies the requested range. There is no `workspace:` sigil — _"workspaces always prefer to install a nested package if semver is satisfied"_ ([`workspace.md`][ws-doc]).
2. **The lockfile and the `node_modules` tree are shared and global.** All members resolve into **one** root `package-lock.json` and **one** hoisted `node_modules`. `npm` does not give each member an isolated dependency tree the way [pnpm](../pnpm/)'s content-addressed store does.

> [!NOTE]
> `npm` workspaces are a _package-manager_ feature, not a _task orchestrator_. `npm` builds a **dependency** DAG (`Arborist`'s tree) but **not a task DAG**: there is no input-hash change detection, no affected-detection, and no build/test result cache. Those layers are supplied by [Turborepo](../turborepo/), [Nx](../nx/), [Lage](../lage/), or [Wireit](../wireit/) on top of `npm` workspaces — see [Task Orchestration](#3-task-orchestration--scheduling).

---

## How it works

### The manifest, the lockfile, and `node_modules`

An `npm` package is rooted at a `package.json`; `dependencies`/`devDependencies` declare requirements as semver ranges. `npm install` resolves the closure, writes `package-lock.json`, and installs into `node_modules`. The whole tree is managed by [`Arborist`][arborist-pkg] — described in its own repo simply as _"npm's tree doctor"_ — which reasons over **three** distinct trees ([`tree-types.md`][tree-types]):

> _"`arborist.actualTree` — This is the representation of the actual packages on disk. … `arborist.virtualTree` — This is the package tree as captured in a `package-lock.json`. … `arborist.idealTree` — This is the tree of package data that we intend to install."_

The lifecycle is **build the ideal tree, then reify it**: `buildIdealTree()` computes the desired graph from `package.json` + the lockfile, and `reify()` diffs it against the actual tree and writes the delta to disk. As the Arborist blog puts it, _"While `buildIdealTree()` is strictly a read operation, `reify()` will write stuff to disk."_

### Declaring a workspace

The root `package.json` gains a `workspaces` array of paths and globs:

```json
{
  "name": "my-monorepo",
  "version": "1.0.0",
  "private": true,
  "workspaces": ["packages/*", "apps/web"]
}
```

Per the [`package.json` docs][pkgjson], `workspaces` is _"an array of file patterns that describes locations within the local file system that the install client should look up to find each workspace that needs to be symlinked to the top level `node_modules` folder."_ The `@npmcli/map-workspaces` module expands the globs (via `minimatch`, supporting negation) into a `Map` of `{ name => path }`.

### The `workspace` edge and local resolution

On `npm install` at the root, `Arborist` adds one **`workspace`-type edge** per member and creates a `Link` node in the root's `node_modules` pointing at the member directory ([`workspace.md`][ws-doc]):

```text
root
+-- node_modules
|   +-- a => pkgs/a        (symlink: a Link node, workspace edge)
|   +-- b => pkgs/b
+-- pkgs
    +-- a (depends on b)
    +-- b
```

When one member depends on another, resolution checks the workspace siblings **first**:

> _"if any dep CAN be satisfied by a named dep in the workspace, then create a Link targeting that workspace child node — resolving: first check this.wsParent.get('dep-name'), and if that's ok, then resolve with a link to that target."_ ([`workspace.md`][ws-doc])

Crucially there is **no special version syntax**. Member `cli` depends on member `greeter` with an ordinary range, and `Arborist` links it locally because the on-disk version satisfies that range:

```json
{
  "name": "@acme/cli",
  "dependencies": { "@acme/greeter": "^1.0.0" }
}
```

The fallback is the registry — _"workspaces will try to install deps from registry if no satisfying semver version was found within its nested packages"_ ([`workspace.md`][ws-doc]). This is the sharpest contrast with [pnpm](../pnpm/)/[Yarn Berry](../yarn-berry/), whose explicit `workspace:*` protocol _forces_ a local link and fails if none exists, rather than silently reaching for the registry on a version mismatch.

### Hoisting: the placement algorithm

`Arborist`'s `node_modules` is **hoisted** (flat where possible), the legacy npm v3+ model. Placing a dependency walks _up_ the tree to the shallowest non-conflicting slot ([`ideal-tree.md`][ideal-tree]):

> _"Starting from the original thing depending on the dep, walk up the tree checking each spot until we find the shallowest spot in the tree where the dependency can go without causing conflicts."_

A member's own dependencies are therefore hoisted to the **root** `node_modules` and shared with every other member when versions agree; only a conflicting version is nested under that member's local `node_modules`. This deduplication _"builds upon the 'maximally naive deduplication' approach … but adds two new features"_ ([Arborist blog][arborist-blog]). The `legacyBundling` and `preferDedupe` options tune nesting vs. dedupe ([`ideal-tree.md`][ideal-tree]).

### Pinning shared versions: `overrides`

Because the tree is shared, version drift across members is policed with the root-only `overrides` field ([`package.json` docs][pkgjson]):

> _"Overrides are only considered in the root `package.json` file for a project. Overrides in installed dependencies (including workspaces) are not considered in dependency tree resolution."_

```json
{
  "overrides": { "lodash": "4.17.21" }
}
```

This forces a single resolved version of `lodash` across the whole tree — `npm`'s blunt instrument where [pnpm](../pnpm/) offers `catalog:` and Cargo offers `[workspace.dependencies]`.

---

## The five dimensions

### 1. Workspace Declaration & Topology

`npm` uses a **root-package workspace**: the workspace root is _itself_ an installable package (it has a `name`/`version`, though monorepo roots usually set `"private": true`), and members are discovered by the `workspaces` glob array in that root `package.json`. There is **no separate workspace manifest** (contrast [`go.work`](../go-work/), [pnpm](../pnpm/)'s `pnpm-workspace.yaml`, or Cargo's `[workspace]` table) and **no "virtual workspace"** mode — the root always doubles as a package.

Discovery is glob-based and supports negation, mirroring `npm-packlist` patterns ([RFC 0026][rfc]):

> _"The npm cli will read from the paths and globs defined in this workspaces configuration and look for valid package.json files in order to create a list of packages that will be treated as workspaces."_

```json
{ "workspaces": ["packages/*", "!packages/internal-tooling"] }
```

Member identity is the member's own `package.json` `name`, not its path — `@npmcli/map-workspaces` returns a `{ name => path }` map, and every CLI selector resolves by **name** (see dimension 5). Nested workspaces (a member that is itself a workspace root) appear in the design notes but are a long-standing rough edge ([`workspace.md`][ws-doc], "Missing: Nested workspaces").

> [!NOTE]
> There is no `npm workspaces list` command. The closest is `npm query` / `npm ls`, or reading the `map-workspaces` output programmatically. The RFC explicitly floated an `npm workspaces info` command ([`workspace.md`][ws-doc]) that was never shipped.

### 2. Dependency Handling & Isolation

**Hoisted, shared, single-tree** — the opposite of isolation. All members resolve into **one** root `package-lock.json` and **one** hoisted root `node_modules`; common dependency versions are deduplicated to the root and shared. A member only gets a nested `node_modules` for a dependency whose version _conflicts_ with what is already hoisted. This is `npm`'s long-standing model extended to members, and it is what [pnpm](../pnpm/) was built to reject (strict, non-flat, content-addressed per-package trees) and what [Yarn Berry](../yarn-berry/) replaces with Plug'n'Play.

Cross-member local references use **a normal semver range plus an `Arborist` `workspace` edge** — no protocol sigil. `Arborist` symlinks the member into `node_modules` (`node_modules/a -> ../packages/a`) and, where one member requires another, prefers the local copy when its version satisfies the range, falling back to the registry otherwise ([`workspace.md`][ws-doc]). Edits to a member library are instantly visible to dependents because the link _is_ the source tree.

Two notable knobs:

- **`overrides`** (root-only) is the only built-in way to force a single shared version of a third-party dependency across members ([`package.json` docs][pkgjson]).
- **`install-links`** packs-and-installs `file:` dependencies instead of symlinking them, but per the docs _has no effect on workspaces_ — workspace members are always linked.

> [!WARNING]
> Because the tree is shared and hoisted, a member can `require()` a transitively-hoisted package it never declared (**phantom dependencies**) — the classic flat-`node_modules` hazard that [pnpm](../pnpm/)'s strict store eliminates. `npm` workspaces do not protect against this.

### 3. Task Orchestration & Scheduling

`npm` builds a **dependency** DAG (the `Arborist` tree) but **not a task DAG**. Its task surface is `package.json` `scripts`, run across members with the workspace flags:

```bash
npm run build --workspaces --if-present   # run "build" in every member that has it
npm run test  -w @acme/cli                # run "test" only in the cli member
```

Behavior and limits:

- **Execution is sequential, in declared order** — _"Commands will be run in each workspace in the order they appear in your `package.json`"_ ([workspaces docs][docs]). There is **no built-in parallelism** and **no topological ordering** of the script run (the `workspace` _edges_ are topological for install/link, but `npm run --workspaces` does not sort scripts by the member dependency graph).
- **`--if-present`** skips members lacking the named script instead of erroring — the one ergonomic concession to heterogeneous members.
- **No change detection.** `npm` has no input hashing, no `--since`/affected-detection, and no per-member task cache. It never asks "which members changed since `HEAD~1`".

This is the largest delta versus the JS/TS orchestrators in this catalog. [Turborepo](../turborepo/) and [Nx](../nx/) exist precisely to add the task DAG, topological scheduling, parallelism, affected-detection, and caching that `npm run --workspaces` lacks — they consume `npm`'s `workspaces` array and `scripts` and orchestrate them. [Lerna](../lerna/) historically filled this role for `npm`/Yarn; [Wireit](../wireit/) and [Lage](../lage/) are lighter-weight script-graph layers. For a `dub` proposal, the lesson is that the package manager should _at least_ expose a topological foreach loop (à la `yarn workspaces foreach`), which `npm` notably does **not**.

### 4. Caching & Remote Execution

`npm` has **no build/test result cache and no remote execution** — and, like [Composer](../composer/), this is partly because JS/TS has no single compile step the package manager owns. What `npm` caches is **package downloads and metadata**: a content-addressed local cache (`~/.npm/_cacache`, an integrity-keyed CAS of tarballs and HTTP responses) makes re-installs and cross-project installs offline-capable (`npm ci --offline`). `package-lock.json` provides **reproducibility** (exact pinned versions + integrity hashes), and `npm ci` does a clean, lockfile-exact install.

But there is:

- **No task-output cache** (contrast [Turborepo](../turborepo/)'s local + remote cache, [Nx](../nx/)'s computation cache).
- **No remote execution / REAPI backend** (contrast [Bazel](../bazel/)/[Buck2](../buck2/) with [BuildBuddy](../buildbuddy/)/[NativeLink](../nativelink/)).

Remote/shared **task** caching for an `npm`-workspaces monorepo is delegated entirely to the orchestrator layer ([Turborepo](../turborepo/) Remote Cache, [Nx](../nx/) Nx Cloud). `npm` itself contributes only the dependency CAS and the lockfile — exactly the same caching ceiling this catalog records for [Composer](../composer/).

### 5. CLI / UX Ergonomics

`npm`'s member-selection vocabulary is **`--workspace`/`-w`** (one or repeated members) and **`--workspaces`/`-ws`** (all members) — _not_ `--filter`. The flag definitions are explicit ([`definitions.js`][defs]):

> `workspace` (`-w`): _"Enable running a command in the context of the configured workspaces of the current project while filtering by running only the workspaces defined by this configuration option. Valid values … are either: Workspace names; Path to a workspace directory; Path to a parent workspace directory (will result in selecting all workspaces within that folder)."_

> `workspaces` (`-ws`): _"Set to true to run the command in the context of all configured workspaces. Explicitly setting this to false will cause commands like install to ignore workspaces altogether."_

So a `-w` argument matches three ways — by **name**, by **directory path**, or by a **parent directory** (selecting every member beneath it). The resolver for this lives in [`get-workspaces.js`][getws], which matches a filter against each member by exact name, resolved path, or a `minimatch` glob:

```js
// lib/utils/get-workspaces.js (abridged)
if (
  filterArg === workspaceName ||
  resolve(relativeFrom, filterArg) === workspacePath ||
  minimatch(relativePath, `${globify(relativeFilter)}/*`) ||
  minimatch(relativePath, `${globify(filterArg)}/*`)
) {
  res.set(workspaceName, workspacePath);
}
```

Companion flags:

- **`--include-workspace-root`** — _"Include the workspace root when workspaces are enabled for a command"_ ([`definitions.js`][defs]); by default `-w`/`-ws` operate _only_ on members.
- **`--if-present`** — skip members missing the script.

What is **absent** is as telling as what is present: **no `--filter`** (the pnpm/Turborepo spelling), **no `:target` colon-syntax** ([Gradle](../gradle/)/[Bazel](../bazel/)), **no `--since`/affected slicing** ([Turborepo](../turborepo/)/[Nx](../nx/)), and **no recursive/`--from` sub-graph traversal** ([Yarn Berry](../yarn-berry/)). `npm` gives you whole-workspace broadcast (`-ws`), name/path-targeted selection (`-w`), and an opt-in root — and stops there. The command boundary ends at "install/link the members and run a script in each"; the topological, affected-aware, cached parts live in the orchestrator layer above.

---

## Strengths

- **Zero-install ubiquity** — bundled with every Node.js; no extra tool to adopt, and `workspaces` is understood by the same `package.json` everyone already writes.
- **No separate workspace manifest** — the root `package.json` `workspaces` glob array is the entire declaration; nothing new to learn or keep in sync.
- **No version-protocol ceremony** — cross-member deps are ordinary semver ranges; `Arborist` links locally when satisfied, so members publish to the registry unchanged.
- **Instant local feedback** — members are symlinked into `node_modules`; an edit to a member library is immediately visible to dependents with no `update` cycle.
- **One lockfile, deterministic installs** — a single root `package-lock.json` with integrity hashes; `npm ci` gives clean, reproducible, offline-capable installs from the download CAS.
- **Hoisted, deduplicated tree** — shared dependency versions collapse to the root `node_modules`, reducing duplication across members when versions agree.

## Weaknesses

- **No task DAG, no parallelism, no topological script ordering** — `npm run --workspaces` runs scripts sequentially in `package.json` order; the orchestration layer ([Turborepo](../turborepo/)/[Nx](../nx/)) is effectively mandatory for real monorepos.
- **No change detection / affected-slicing** — no input hashing, no `--since`, no task-result cache; every run is from scratch.
- **No `workspace:` protocol** — a version mismatch silently falls back to the **registry** instead of failing, an easy way to accidentally consume a published package instead of the local member.
- **Shared, hoisted tree → phantom dependencies** — members can `require()` un-declared, transitively-hoisted packages; no per-member isolation (the problem [pnpm](../pnpm/) was built to solve).
- **`overrides` is the only shared-version mechanism** — root-only, blunt, and ignored inside members; no `catalog:`/`[workspace.dependencies]` registry.
- **No member-listing or `--filter` ergonomics** — selection is `-w`/`-ws` by name/path only; no glob `--filter`, no `:target`, no recursion.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                                 | Trade-off                                                                                           |
| ----------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Root-package workspace; `workspaces` glob in `package.json`       | Reuses the manifest everyone already has; no new workspace file to learn or sync          | No "virtual workspace" mode; the root always doubles as an installable package                      |
| Workspaces as a new `Arborist` `workspace` edge, always a symlink | Folds the monorepo into the existing resolver/reifier, not a separate engine              | A member is just a package; no protocol-level guarantee that a dep _must_ resolve locally           |
| Cross-member deps via plain semver range (no `workspace:`)        | Members publish unchanged; "links if satisfied, else registry" is one uniform rule        | Version mismatch silently fetches from the registry instead of failing; drift is easy               |
| Single hoisted root `node_modules` + one `package-lock.json`      | Maximal deduplication; one resolution; familiar flat layout                               | No per-member isolation; phantom dependencies; members can't diverge on a shared version cleanly    |
| `overrides` (root-only) for shared-version pinning                | Simple, single place to force one version across the tree                                 | Blunt; ignored inside member manifests; no shared-dependency registry like `catalog:`               |
| Package manager, not task orchestrator (no task DAG/cache)        | Keeps `npm`'s scope to resolve + link + run-script; defers orchestration to the ecosystem | Real monorepos need [Turborepo](../turborepo/)/[Nx](../nx/) for DAG, parallelism, caching, affected |
| `-w`/`-ws` selection by name/path (no `--filter`/`:target`)       | Small, explicit selector surface; matches the RFC's minimal design                        | No glob filter, no `--since`, no recursion; less expressive than pnpm/Turborepo selectors           |
| Download CAS (`_cacache`) + integrity-pinned lockfile             | Reproducible, offline-capable installs across projects                                    | Caches _downloads_, never _task output_; no remote execution                                        |

---

## Sample workspace

A minimal, runnable two-member `npm` workspace lives under [`./sample/`](./sample/): a root `package.json` with a `workspaces` glob, a `@acme/greeter` library member, and a `@acme/cli` member that depends on `greeter` via an ordinary `^1.0.0` semver range (no `workspace:` sigil). After `npm install` at the root, `Arborist` symlinks both members into `node_modules` and links `greeter` into `cli`; `npm run build --workspaces --if-present` runs the per-member `build` script. See the sample's `package.json` files for the exact cross-reference.

---

## Sources

- [npm/cli — GitHub repository][repo] (`Arborist` lives in [`workspaces/arborist/`][arborist-src]; CLI workspace utils in `lib/utils/`)
- [`@npmcli/arborist` — "npm's tree doctor"][arborist-pkg]
- [Workspaces — npm Docs][docs] (declaration, symlinks, `-w`/`-ws`, `--if-present`)
- [`package.json` — npm Docs][pkgjson] (`workspaces` field, `overrides`, `bundleDependencies`, local-path deps)
- [npm RFC 0026 — Workspaces][rfc] (motivation, definition, glob discovery, naming rationale)
- [`workspaces/arborist/docs/workspace.md`][ws-doc] (the `workspace` edge, local-first resolution, registry fallback, design notes)
- [`workspaces/arborist/docs/tree-types.md`][tree-types] (actual / virtual / ideal trees)
- [`workspaces/arborist/docs/ideal-tree.md`][ideal-tree] (build-ideal-tree and shallowest-non-conflicting placement / hoisting)
- [`workspaces/config/lib/definitions/definitions.js`][defs] (`workspace`/`workspaces`/`include-workspace-root` flag definitions)
- [`lib/utils/get-workspaces.js`][getws] (name / path / `minimatch` glob member selection)
- [npm v7 Series — Arborist Deep Dive (npm blog)][arborist-blog] (actual/virtual/ideal, `reify`, the `workspace` edge, maximally-naive dedupe)
- [Presenting v7.0.0 of the npm CLI (GitHub blog, 2020-10-13)][v7-blog] (workspaces + Arborist release)
- Sibling deep-dives: [pnpm](../pnpm/) · [Yarn Berry](../yarn-berry/) · [Bun](../bun/) · [Cargo](../cargo/) · [go-work](../go-work/) · [Composer](../composer/) · [Turborepo](../turborepo/) · [Nx](../nx/) · [Lerna](../lerna/) · [Lage](../lage/) · [Wireit](../wireit/) · [Bazel](../bazel/) · [Buck2](../buck2/) · [BuildBuddy](../buildbuddy/) · [NativeLink](../nativelink/) · [comparison](../comparison.md) · [dub baseline](../dub-baseline.md) · [D landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/npm/cli
[arborist-src]: https://github.com/npm/cli/tree/latest/workspaces/arborist
[arborist-pkg]: https://www.npmjs.com/package/@npmcli/arborist
[docs]: https://docs.npmjs.com/cli/v11/using-npm/workspaces/
[pkgjson]: https://docs.npmjs.com/cli/v11/configuring-npm/package-json
[rfc]: https://github.com/npm/rfcs/blob/main/implemented/0026-workspaces.md
[ws-doc]: https://github.com/npm/cli/blob/latest/workspaces/arborist/docs/workspace.md
[tree-types]: https://github.com/npm/cli/blob/latest/workspaces/arborist/docs/tree-types.md
[ideal-tree]: https://github.com/npm/cli/blob/latest/workspaces/arborist/docs/ideal-tree.md
[defs]: https://github.com/npm/cli/blob/latest/workspaces/config/lib/definitions/definitions.js
[getws]: https://github.com/npm/cli/blob/latest/lib/utils/get-workspaces.js
[arborist-blog]: https://blog.npmjs.org/post/618653678433435649/npm-v7-series-arborist-deep-dive.html
[v7-blog]: https://github.blog/2020-10-13-presenting-v7-0-0-of-the-npm-cli/
[d-landscape]: ../../async-io/d-landscape.md
