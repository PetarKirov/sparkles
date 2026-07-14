# Yarn Berry (JavaScript/TypeScript)

The ground-up TypeScript rewrite of Yarn (Yarn 2+, "Berry"): a plugin-based package manager whose `workspaces` field, first-class `workspace:` resolver protocol, Plug'n'Play install model, and `yarn workspaces foreach` topological runner make it one of the most complete native-workspace implementations in any ecosystem — and the closest existing template for the local-cross-reference protocol a `dub` `[workspace]` block would need.

| Field           | Value                                                                                                                                     |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Language        | TypeScript (Node.js `>=18.12.0`; the codebase is itself a Yarn workspace)                                                                 |
| License         | BSD-2-Clause                                                                                                                              |
| Repository      | [yarnpkg/berry][repo]                                                                                                                     |
| Documentation   | [yarnpkg.com][docs] · [Workspaces feature page][docs-ws] · [`workspace:` protocol][docs-proto]                                            |
| Category        | JS/TS Package Manager                                                                                                                     |
| Workspace model | **Root-package workspace** declared by a `workspaces` glob array in the root `package.json`; members linked via the `workspace:` protocol |
| First released  | Yarn 2.0 ("Berry"), January 2020 (rewrite of Yarn 1 / "Classic")                                                                          |
| Latest release  | `4.15.0`                                                                                                                                  |

> **Latest release:** `4.15.0` (the `4.x` "Yarn Modern" line, May 2026); the active development trunk read for this deep-dive is at `@yarnpkg/cli` `4.16.0`. Yarn 4.0 (March 2024) reinforced **Plug'n'Play** (`nodeLinker: pnp`) as the default linker, shipped the JavaScript [constraints engine](#workspace-constraints), and introduced the `catalog:` protocol for centralized version pinning. All file paths below are quoted from the `master` checkout at `~/code/repos/typescript/berry`.

---

## Overview

### What it solves

Yarn Berry is a Node.js package manager: it reads a `package.json` manifest, resolves the transitive dependency closure against the npm registry, writes a `yarn.lock` lockfile, and installs the result so that `import`/`require` resolve. But unlike [Composer](../composer/) (which has no workspace model) or even [npm](../npm/) (whose workspaces are a thinner layer), Berry treats the **monorepo as the primary unit of work**. A single repository declares a set of member packages ("workspaces") in its root `package.json`; those members can depend on **each other** through the dedicated `workspace:` protocol; the resolver links them locally with a symlink (`LinkType.SOFT`) instead of fetching from the registry; and a built-in plugin, `plugin-workspace-tools`, runs commands across the member graph in **topological order** with bounded concurrency and git-based change detection.

Berry's second defining bet is **Plug'n'Play (PnP)**: rather than materialize a `node_modules/` tree, it writes a single `.pnp.cjs` data file mapping every `(package, version)` to its on-disk location (a zip in a content-addressed cache) and patches Node's module resolver to consult that map. This eliminates the hoisting non-determinism and "phantom dependency" hazards of `node_modules`, and makes installs near-instant on a warm cache. PnP is optional — `nodeLinker` can be set to `node-modules` (classic hoisting) or `pnpm` (an isolated symlink store like [pnpm](../pnpm/)) — but it is the default in Yarn 4.

### Design philosophy

Berry is a **plugin architecture wrapped around a small core**. The core (`@yarnpkg/core`) owns the `Project`, `Workspace`, `Manifest`, `Configuration`, the resolver/fetcher/linker interfaces, and the lockfile; everything user-facing — the `npm` registry resolver, the `workspace:`/`portal:`/`link:`/`patch:`/`catalog:` protocols, the `nm`/`pnp`/`pnpm` linkers, even `yarn workspaces foreach` — is a plugin under `packages/plugin-*`. The `workspace:` protocol is itself just a `Resolver` implementation. From [`WorkspaceResolver.ts`][ws-resolver], the resolver that turns a `workspace:` range into a local, symlinked package:

> ```ts
> // packages/yarnpkg-core/sources/WorkspaceResolver.ts
> async resolve(locator: Locator, opts: ResolveOptions) {
>     const workspace = opts.project.getWorkspaceByCwd(locator.reference.slice(WorkspaceResolver.protocol.length) as PortablePath);
>     return {
>         ...locator,
>         version: workspace.manifest.version || `0.0.0`,
>         languageName: `unknown`,
>         linkType: LinkType.SOFT,
>         // ...
>     };
> }
> ```

The `LinkType.SOFT` is the crux: a workspace dependency is **never copied or fetched**, it is linked to its source directory, so an edit to a member is immediately visible to its dependents with no rebuild or re-install. The `shouldPersistResolution()` method returns `false`, so workspace resolutions are _never written to the lockfile as fixed_ — they are re-derived from the live workspace graph on every install. This is the structural inverse of [Composer](../composer/)'s `path` repositories, which bolt local linking onto a registry-shaped resolver after the fact.

Within this catalog, Berry is the canonical _JS/TS package manager with a first-class local-cross-reference protocol_. Compare it against [npm](../npm/) (workspaces but no `workspace:`-style range rewriting on publish), [pnpm](../pnpm/) (also has `workspace:`, plus the isolated symlink store Berry borrows as `nodeLinker: pnpm`), and [Bun](../bun/) (workspaces with a fast native installer). For where `dub` sits today, see [the dub baseline](../dub-baseline.md) and [the D landscape][d-landscape].

---

## How it works

### The `Project`, the `Workspace`, and discovery

A Berry install begins with `Project.find()`, which walks up from the cwd to the directory containing the lockfile / root `package.json`, then recursively loads every workspace. The root workspace's `package.json` carries the `workspaces` field — an array of globs — and `Workspace.setup()` ([`Workspace.ts`][workspace]) expands them with `fast-glob`, recursing into each matched directory that contains a `package.json`:

```ts
// packages/yarnpkg-core/sources/Workspace.ts
const patterns = this.manifest.workspaceDefinitions.map(
  ({ pattern }) => pattern,
);
if (patterns.length === 0) return;

const relativeCwds = await fastGlob(patterns, {
  cwd: npath.fromPortablePath(this.cwd),
  onlyDirectories: true,
  ignore: [`**/node_modules`, `**/.git`, `**/.yarn`],
});
```

The `workspaces` field is parsed in [`Manifest.ts`][manifest], accepting **either** a bare array **or** the legacy `{ packages: [...] }` object form:

```ts
// packages/yarnpkg-core/sources/Manifest.ts
const workspaces = Array.isArray(data.workspaces)
  ? data.workspaces
  : typeof data.workspaces === `object` &&
      data.workspaces !== null &&
      Array.isArray(data.workspaces.packages)
    ? data.workspaces.packages
    : [];
```

Every workspace gets an `anchoredLocator` whose reference is `workspace:<relativeCwd>` — i.e. the workspace's own identity in the dependency graph is a `workspace:` locator keyed by its path relative to the project root. This is why the relative path is hashed for the identity (so the lockfile is OS-independent) and why two workspaces with the same `name` are a hard error (`addWorkspace` rejects a duplicate `identHash`).

> [!NOTE]
> A nested workspace can itself declare a `workspaces` array, so the discovery is recursive — but the conventional layout is a flat `packages/*` (or `apps/*` + `libs/*`) under one root. The root `package.json` is almost always `"private": true`, because the root _is_ a package (root-package-workspace model) but should never be publishable.

### The `workspace:` protocol and publish-time range rewriting

A member depends on a sibling by writing a `workspace:` range in its `dependencies`:

```json
{
  "name": "@acme/cli",
  "dependencies": {
    "@acme/greeter": "workspace:^"
  }
}
```

The selector after the colon controls how the range is **rewritten when the package is published** (`yarn pack` / `yarn npm publish`). During development all four forms resolve identically — to the local workspace — but the `beforeWorkspacePacking` hook in [`plugin-pack/sources/index.ts`][pack] substitutes the real version so the published artifact has a normal, registry-resolvable range:

```ts
// packages/plugin-pack/sources/index.ts — beforeWorkspacePacking (abridged)
// For workspace:path/to/workspace and workspace:* we look up the workspace version
if (
  structUtils.areDescriptorsEqual(
    descriptor,
    matchingWorkspace.anchoredDescriptor,
  ) ||
  range.selector === `*`
)
  versionToWrite = matchingWorkspace.manifest.version ?? `0.0.0`;
// For workspace:~ and workspace:^ we add the selector in front of the workspace version
else if (range.selector === `~` || range.selector === `^`)
  versionToWrite = `${range.selector}${matchingWorkspace.manifest.version ?? `0.0.0`}`;
else
  // for workspace:version we simply strip the protocol
  versionToWrite = range.selector;
```

| Range written by author | Resolves to (dev) | Published as (if member version is `1.4.0`) |
| ----------------------- | ----------------- | ------------------------------------------- |
| `workspace:*`           | local workspace   | `1.4.0` (exact)                             |
| `workspace:~`           | local workspace   | `~1.4.0`                                    |
| `workspace:^`           | local workspace   | `^1.4.0`                                    |
| `workspace:^1.0.0`      | local workspace   | `^1.0.0` (protocol stripped)                |
| `workspace:packages/x`  | local workspace   | the member's exact version                  |

This is the single most-imitated piece of Berry's design: it gives developers a _local-first_ dependency that becomes a _correct registry range_ at publish, with zero manual bookkeeping. [pnpm](../pnpm/) adopted the same `workspace:` syntax; it is the direct model for the "Local Cross-Referencing Protocol" milestone in the [dub proposal](../dub-proposal.md).

### Plug'n'Play, the cache, and the linkers

After resolution, a **linker** materializes the install. The default (`nodeLinker: pnp`, from [`plugin-pnp/sources/index.ts`][pnp]) does **not** create `node_modules/`. Instead it writes a `.pnp.cjs` that encodes, for every package, the exact filesystem location of its dependencies, plus a Node loader (`.pnp.loader.mjs`) that intercepts module resolution. Package contents live as zip archives in a per-project (or global) content-addressed cache (`.yarn/cache/`), read in place via a zip filesystem layer (`@yarnpkg/libzip` / `@yarnpkg/fslib`).

```ts
// packages/plugin-pnp/sources/index.ts — nodeLinker setting
nodeLinker: {
    description: `The linker used for installing Node packages, one of: "pnp", "pnpm", or "node-modules"`,
    type: SettingsType.STRING,
    default: `pnp`,
},
```

The three linkers are the three points on the dependency-isolation spectrum surveyed in [concepts](../concepts.md):

| `nodeLinker` value | Install shape                                          | Isolation                                           |
| ------------------ | ------------------------------------------------------ | --------------------------------------------------- |
| `pnp` (default)    | one `.pnp.cjs` map + zipped packages in `.yarn/cache/` | **strict** — only declared deps are resolvable      |
| `pnpm`             | isolated symlink store (à la [pnpm](../pnpm/))         | **strict** — non-flat `node_modules` of symlinks    |
| `node-modules`     | classic hoisted `node_modules/` tree                   | **loose** — phantom deps resolvable (compatibility) |

PnP's strictness is the dependency-isolation payoff: a package can only `require` what it actually declared, because the `.pnp.cjs` map omits everything else — the "phantom dependency" class of bug is structurally impossible.

### `yarn workspaces foreach`: the topological task runner

Task orchestration lives in `plugin-workspace-tools`. `yarn workspaces foreach <cmd>` ([`foreach.ts`][foreach]) selects a set of workspaces, then runs the sub-command across them, optionally in topological order and in parallel. The selection and scheduling flags are the heart of Berry's monorepo UX (detailed in [dimension 5](#5-cli--ux-ergonomics)). The scheduler is a worklist loop: a workspace becomes runnable only once every workspace it depends on (via `dependencies`, plus `devDependencies` under `--topological-dev`) has left the pending set:

```ts
// packages/plugin-workspace-tools/sources/commands/foreach.ts (abridged)
while (needsProcessing.size > 0) {
  if (report.hasErrors()) break;
  const commandPromises = [];
  for (const [identHash, workspace] of needsProcessing) {
    if (processing.has(workspace.anchoredDescriptor.descriptorHash)) continue;

    let isRunnable = true;
    if (this.topological || this.topologicalDev) {
      const resolvedSet = this.topologicalDev
        ? new Map([
            ...workspace.manifest.dependencies,
            ...workspace.manifest.devDependencies,
          ])
        : workspace.manifest.dependencies;
      for (const descriptor of resolvedSet.values()) {
        const depWorkspace = project.tryWorkspaceByDescriptor(descriptor);
        isRunnable =
          depWorkspace === null ||
          !needsProcessing.has(depWorkspace.anchoredLocator.locatorHash);
        if (!isRunnable) break;
      }
    }
    if (!isRunnable) continue;
    // ...dispatch under a pLimit(concurrency) gate...
  }
  if (commandPromises.length === 0) {
    // every remaining workspace is blocked → a cycle
    report.reportError(
      MessageName.CYCLIC_DEPENDENCIES,
      `Dependency cycle detected (...)`,
    );
    return;
  }
  await Promise.all(commandPromises);
}
```

Concurrency defaults to roughly half the available cores (`Math.ceil(nodeUtils.availableParallelism() / 2)`), is gated by `p-limit`, and is configurable via `-j,--jobs` (including `-j unlimited`). If no workspace is runnable yet the pending set is non-empty, that is by definition a dependency cycle, and Berry reports `CYCLIC_DEPENDENCIES` rather than deadlocking — a clean failure mode worth copying.

---

## The five dimensions

### 1. Workspace Declaration & Topology

**Root-package workspace, declared by a glob array.** The root `package.json` carries `workspaces: ["packages/*"]` (or the legacy `{"packages": [...]}` object form). There is **no separate workspace manifest file** — the root package _is_ the workspace root (contrast [`go.work`](../go-work/), [Cargo](../cargo/)'s virtual `[workspace]`, or [pnpm](../pnpm/)'s separate `pnpm-workspace.yaml`). Discovery is by `fast-glob`, recursive (a member may declare its own `workspaces`), and always ignores `node_modules`, `.git`, and `.yarn`. Each member's identity in the graph is a `workspace:<relativeCwd>` locator; duplicate `name`s are rejected.

```json
{
  "name": "@acme/monorepo",
  "private": true,
  "workspaces": ["packages/*"]
}
```

There is no "virtual workspace" mode distinct from a "root package workspace" the way Cargo distinguishes them — the root is always a package, conventionally marked `"private": true` so it is never published. Topology (who-depends-on-whom) is derived from members' `dependencies`/`devDependencies` that point at sibling workspaces; `Workspace.getRecursiveWorkspaceDependencies()` and `...Dependents()` walk that graph.

### 2. Dependency Handling & Isolation

**Three selectable models via `nodeLinker`; default is content-addressed PnP.** Cross-workspace local references use the **`workspace:` protocol** — a member is linked (`LinkType.SOFT`) to its sibling's source directory, never fetched, and the resolution is _not persisted to the lockfile_ (`shouldPersistResolution() === false`), so it is always re-derived from the live graph. Selectors (`*`, `~`, `^`, explicit semver) control only publish-time range rewriting.

Third-party dependencies are isolated according to the linker: `pnp` (a `.pnp.cjs` map over zipped cache entries — strict, only declared deps resolvable), `pnpm` (isolated symlink store), or `node-modules` (hoisted, loose). PnP makes "phantom dependencies" structurally impossible. Berry also ships sibling local-link protocols in `plugin-link`:

```ts
// packages/plugin-link/sources/constants.ts
export const PORTAL_PROTOCOL = `portal:`; // link a folder *with* its dependencies (full resolution)
export const LINK_PROTOCOL = `link:`; // link a raw folder *without* dependency resolution
```

`portal:` and `link:` cover out-of-tree local packages; `workspace:` is the in-tree case. The `catalog:` protocol ([`plugin-catalog`][catalog]) adds a _workspace dependency registry_: a root `.yarnrc.yml` `catalog:` map pins one version per dependency, and members write `"typescript": "catalog:"` to inherit it — the direct analogue of a Cargo `[workspace.dependencies]` table, and a model for the [dub proposal](../dub-proposal.md)'s centralized-dependency milestone.

```yaml
# .yarnrc.yml — the default catalog
catalog:
  typescript: ^5.9.2
```

### 3. Task Orchestration & Scheduling

**A real topological DAG executor with bounded concurrency — but no input-hash result cache.** `yarn workspaces foreach -t run build` builds the workspace dependency graph and runs each member's `build` script only after all of its workspace dependencies have finished (`--topological` uses `dependencies`; `--topological-dev` adds `devDependencies`). Execution is concurrent under a `p-limit` gate (default ≈ half the cores, `-j unlimited` to uncap), output is either buffered-per-process or `-i,--interlaced` in real time, and a non-empty-but-unrunnable worklist is reported as a `CYCLIC_DEPENDENCIES` error.

Change detection is **git-ref-based affected detection**, not content hashing: `--since [ref]` selects only workspaces whose files changed since a base ref, computed by `fetchChangedWorkspaces` ([`gitUtils.ts`][git]) via `git merge-base` + `git diff --name-only` + `git ls-files --others`, mapping each changed file back to its owning workspace and skipping the lockfile / cache / install-state / virtual folder:

```ts
// packages/plugin-git/sources/gitUtils.ts (abridged)
const base = await fetchBase(root, {
  baseRefs:
    typeof ref === `string`
      ? [ref]
      : project.configuration.get(`changesetBaseRefs`),
});
const changedFiles = await fetchChangedFiles(root, {
  base: base.hash,
  project,
});
return new Set(
  miscUtils.mapAndFilter(changedFiles, file => {
    const workspace = project.tryWorkspaceByFilePath(file);
    // ...skip lockfile / cache / installStatePath / virtualFolder...
    return workspace;
  }),
);
```

> [!IMPORTANT]
> Berry's `--since` answers _"which workspaces changed?"_ and (with `-R`/`--recursive`) _"what depends on them?"_, but it does **not** memoize task **outputs**. Unlike [Turborepo](../turborepo/) or [Nx](../nx/), there is no per-task input hash and no "this build is already up to date, skip it" — `foreach` always _runs_ the selected commands. Berry orchestrates; it does not cache build results.

### 4. Caching & Remote Execution

**Package-install caching only; no task-output cache and no remote execution.** Berry's cache (`.yarn/cache/`, or a global cache when `enableGlobalCache: true`) is a **content-addressed store of resolved package archives** (zips), keyed by `(ident, version, cacheKey)` and validated by checksum in `yarn.lock`. This makes re-installs and offline installs ("Zero-Installs" — commit the cache and `.pnp.cjs`, and `git clone` is install-free) fast and reproducible. But it is a _dependency_ cache, not a _build/test result_ cache:

- **No build/test result caching.** `foreach` re-executes scripts every run; there is no `--filter ...^...` input-hash skip the way [Turborepo](../turborepo/) and [Nx](../nx/) provide. JS is interpreted, so the missing artifact cache hurts less for "build" than for, say, [Bazel](../bazel/) — but TypeScript compilation, bundling, and test runs are exactly the kind of work a result cache would skip, and Berry does not.
- **No REAPI / remote execution.** There is no remote build cache or [REAPI](../buildbarn/) backend (contrast [Turborepo](../turborepo/)'s remote cache, or [Bazel](../bazel/)/[Buck2](../buck2/) with [BuildBuddy](../buildbuddy/)/[NativeLink](../nativelink/)). Teams wanting remote task caching layer Turborepo or Nx _on top of_ Yarn workspaces.

For a `dub` proposal the lesson is delimited: Berry demonstrates a robust **content-addressed dependency cache + lockfile reproducibility + Zero-Installs**, but contributes nothing on **task-output** caching or remote execution — those come from the [JS/TS task orchestrators](../turborepo/) and [polyglot engines](../bazel/) elsewhere in this survey.

### 5. CLI / UX Ergonomics

**Rich, flag-driven member selection layered on a single `foreach` verb.** Outside a workspace command, the everyday verbs are workspace-aware by cwd: `yarn add @acme/greeter@workspace:^` (adds a local member dep), `yarn install`, `yarn run build` (runs the current workspace's script), and `yarn workspace @acme/cli run build` (run a script _in a named workspace_). The monorepo broadcast surface is `yarn workspaces foreach`, whose flags are the model the [dub proposal](../dub-proposal.md) draws from directly:

| Flag                       | Effect                                                                               |
| -------------------------- | ------------------------------------------------------------------------------------ |
| `-A,--all`                 | run on **all** workspaces of the project                                             |
| `-R,--recursive`           | seed from the current workspace, follow `dependencies`/`devDependencies` recursively |
| `-W,--worktree`            | run only on the current worktree's workspace                                         |
| `--from <glob>`            | use workspaces matching the glob as the recursion roots (paired with `-R`)           |
| `--since [ref]`            | only workspaces changed since a git ref (affected-detection)                         |
| `-t,--topological`         | wait for `dependencies` to finish first; `--topological-dev` adds `devDependencies`  |
| `-p,--parallel`            | run concurrently (≈ half the cores by default)                                       |
| `-j,--jobs <n\|unlimited>` | cap (or uncap) the concurrency                                                       |
| `-i,--interlaced`          | stream output live instead of buffering per process                                  |
| `--include` / `--exclude`  | glob whitelists / blacklists over workspace idents or paths                          |
| `--no-private`             | skip private workspaces (e.g. for `npm publish`)                                     |
| `-n,--dry-run`             | print what would run                                                                 |

So the idiomatic "build everything in dependency order, in parallel" is `yarn workspaces foreach -Apt run build`, and "build only what changed since `main` and its dependents" is `yarn workspaces foreach -Rpt --since main run build`. This is the most complete native member-slicing CLI of any _package manager_ in the catalog (the [task orchestrators](../turborepo/) match or exceed it, but they are dedicated runners). The colon (`@scope/name`) is a package-naming convention, not a target syntax; selection is entirely flag-driven over idents and paths.

### Workspace constraints

A sixth, Berry-specific capability worth flagging for the [dub proposal](../dub-proposal.md)'s "Workspace Constraints Engine" milestone: `yarn constraints` ([`constraints.ts`][constraints]) validates that workspace manifests conform to rules written in `yarn.config.cjs`, and `yarn constraints --fix` rewrites manifests to satisfy them (a multi-pass, up-to-10-iteration fixpoint). Yarn 4's engine is plain JavaScript (`defineConfig` from `@yarnpkg/types`), having replaced the earlier Prolog (`constraints.pro`) engine. The repo's own `yarn.config.cjs` enforces, for example, that _every workspace depends on the same version of a shared dependency_:

```js
// yarn.config.cjs (abridged) — enforce one version of each dep across the monorepo
for (const dependency of Yarn.dependencies()) {
  for (const otherDependency of Yarn.dependencies({
    ident: dependency.ident,
  })) {
    dependency.update(otherDependency.range);
  }
}
```

This is exactly the "no version drift across members" rule that [Composer](../composer/) needs `monorepo-builder validate` for, made first-class and auto-fixable.

---

## Strengths

- **First-class local cross-references.** The `workspace:` protocol links members by source directory (`LinkType.SOFT`), never fetches, never persists the resolution, and rewrites to a real registry range on publish — the cleanest local-first-then-publishable model in the survey.
- **Real topological task runner.** `yarn workspaces foreach -Apt` runs the member graph in dependency order with bounded concurrency, cycle detection, and per-process output control — built in, no extra tool.
- **Strict dependency isolation by default.** PnP's `.pnp.cjs` map makes phantom dependencies impossible; `nodeLinker` lets a team trade strictness for compatibility (`node-modules`) or pick an isolated symlink store (`pnpm`).
- **Affected-detection out of the box.** `--since [ref]` + `-R` bounds work to changed workspaces and their dependents via `git merge-base`/`diff`, no external graph tool needed.
- **Centralized version pinning.** The `catalog:` protocol and the JS `yarn constraints` engine eliminate version drift across members and can auto-fix manifests.
- **Zero-Installs + reproducibility.** Committing the content-addressed cache and `.pnp.cjs` makes `git clone` install-free; `yarn.lock` checksums guarantee reproducible installs.
- **Plugin architecture.** Protocols, linkers, and commands are all plugins, so the core stays small and the model is extensible.

## Weaknesses

- **No task-output cache.** `foreach` always re-runs the selected scripts; there is no input-hash "already up to date, skip" memoization — teams add [Turborepo](../turborepo/)/[Nx](../nx/) for that.
- **No remote execution / remote cache.** No REAPI backend and no shared remote build cache; the cache is dependency archives only.
- **PnP compatibility friction.** Tools that assume a physical `node_modules/` (some bundlers, IDEs, postinstall scripts) need PnP-aware shims or the `node-modules` linker; PnP's strictness occasionally surfaces real-but-annoying peer-dependency errors.
- **No virtual-workspace mode.** The root is always a package; there is no Cargo-style stateless virtual root (mitigated by `"private": true`, but conceptually less clean).
- **Selection is git/glob-based, not content-based.** `--since` detects _changed files_, not _changed inputs to a task_, so it can over- or under-select relative to a true input-hash model.
- **Migration cost.** Berry is a large departure from Yarn Classic / npm; PnP, the `.yarn/` layout, and `corepack` pinning are a real adoption ramp.

## Key design decisions and trade-offs

| Decision                                                             | Rationale                                                                                     | Trade-off                                                                               |
| -------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Root-package workspace via a `workspaces` glob array                 | Reuses the existing `package.json`; no new manifest file; recursive discovery                 | No distinct virtual-root mode; root is always a (private) package                       |
| `workspace:` protocol with `LinkType.SOFT`, resolution not persisted | Local-first: edits to a member are instantly visible; never fetches or pins a sibling         | The workspace graph must be re-derived each install; cross-workspace ranges are special |
| Publish-time selector rewriting (`*`/`~`/`^`/explicit)               | One range works in dev _and_ becomes a correct registry constraint on publish, no manual edit | Selector semantics are subtle; authors must know which selector publishes to what       |
| Plug'n'Play as the default linker                                    | Strict isolation (no phantom deps), near-instant installs, Zero-Installs                      | Compatibility friction with `node_modules`-assuming tooling; needs PnP-aware shims      |
| `nodeLinker` choice of `pnp` / `pnpm` / `node-modules`               | Lets each repo pick its point on the isolation-vs-compatibility spectrum                      | Three install shapes to support and document; behavior differs across them              |
| `foreach` topological runner with `p-limit` concurrency              | Built-in dependency-ordered, parallel task execution; clean cycle detection                   | Always re-runs (no result cache); orchestration only, not memoization                   |
| `--since` git-ref affected detection (not input hashing)             | Cheap, dependency-free "what changed?" using git plumbing                                     | Detects changed _files_, not changed task _inputs_; can mis-scope vs a true hash model  |
| Content-addressed dependency cache + lockfile checksums              | Reproducible, offline, Zero-Install-capable dependency installs                               | Caches downloads, not build/test outputs; no remote task cache                          |
| Constraints engine (`yarn constraints --fix`) in JS                  | First-class, auto-fixable cross-member rules (e.g. single shared version)                     | Another config surface (`yarn.config.cjs`); replaced the older Prolog engine            |

---

## Sample workspace

A minimal, genuinely-runnable Yarn Berry workspace lives in [`./sample/`](./sample/): a private root declaring `workspaces: ["packages/*"]`, two members where `@acme/cli` depends on `@acme/greeter` via `workspace:^`, and a `build` script driven topologically with `yarn workspaces foreach -Apt run build`. It demonstrates all five dimensions in ~30 lines of config.

---

## Sources

- [yarnpkg/berry — GitHub repository][repo] (source for all quoted file paths; read at `master`, `@yarnpkg/cli` `4.16.0`)
- [`packages/yarnpkg-core/sources/WorkspaceResolver.ts` — the `workspace:` resolver, `LinkType.SOFT`, non-persisted resolution][ws-resolver]
- [`packages/yarnpkg-core/sources/Workspace.ts` — glob discovery via `fast-glob`, `anchoredLocator`][workspace]
- [`packages/yarnpkg-core/sources/Manifest.ts` — `workspaces` array / `{packages}` parsing][manifest]
- [`packages/plugin-pack/sources/index.ts` — `beforeWorkspacePacking` publish-time range rewriting][pack]
- [`packages/plugin-workspace-tools/sources/commands/foreach.ts` — topological scheduler, flags, cycle detection][foreach]
- [`packages/plugin-git/sources/gitUtils.ts` — `--since` affected detection (`merge-base`/`diff`)][git]
- [`packages/plugin-pnp/sources/index.ts` — `nodeLinker` setting, PnP linker][pnp]
- [`packages/plugin-link/sources/constants.ts` — `portal:` / `link:` protocols][catalog]
- [`packages/plugin-constraints/` + `yarn.config.cjs` — JS constraints engine][constraints]
- [Yarn documentation — workspaces feature page][docs-ws]
- [Yarn documentation — the `workspace:` protocol][docs-proto]
- [Release: Yarn 4.0 — PnP default, JS constraints, `catalog:`][docs-4]
- Sibling deep-dives: [npm](../npm/) · [pnpm](../pnpm/) · [Bun](../bun/) · [Cargo](../cargo/) · [go-work](../go-work/) · [Composer](../composer/) · [Turborepo](../turborepo/) · [Nx](../nx/) · [Bazel](../bazel/) · [Buck2](../buck2/) · [Buildbarn](../buildbarn/) · [BuildBuddy](../buildbuddy/) · [NativeLink](../nativelink/) · [concepts](../concepts.md) · [comparison](../comparison.md) · [dub baseline](../dub-baseline.md) · [dub proposal](../dub-proposal.md) · [D landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/yarnpkg/berry
[docs]: https://yarnpkg.com/
[docs-ws]: https://yarnpkg.com/features/workspaces
[docs-proto]: https://yarnpkg.com/protocol/workspace
[docs-4]: https://yarnpkg.com/blog/release/4.0
[ws-resolver]: https://github.com/yarnpkg/berry/blob/0a230c14e71247576f6b51fa811ae08edb6608aa/packages/yarnpkg-core/sources/WorkspaceResolver.ts
[workspace]: https://github.com/yarnpkg/berry/blob/0a230c14e71247576f6b51fa811ae08edb6608aa/packages/yarnpkg-core/sources/Workspace.ts
[manifest]: https://github.com/yarnpkg/berry/blob/0a230c14e71247576f6b51fa811ae08edb6608aa/packages/yarnpkg-core/sources/Manifest.ts
[pack]: https://github.com/yarnpkg/berry/blob/0a230c14e71247576f6b51fa811ae08edb6608aa/packages/plugin-pack/sources/index.ts
[foreach]: https://github.com/yarnpkg/berry/blob/0a230c14e71247576f6b51fa811ae08edb6608aa/packages/plugin-workspace-tools/sources/commands/foreach.ts
[git]: https://github.com/yarnpkg/berry/blob/0a230c14e71247576f6b51fa811ae08edb6608aa/packages/plugin-git/sources/gitUtils.ts
[pnp]: https://github.com/yarnpkg/berry/blob/0a230c14e71247576f6b51fa811ae08edb6608aa/packages/plugin-pnp/sources/index.ts
[catalog]: https://github.com/yarnpkg/berry/blob/0a230c14e71247576f6b51fa811ae08edb6608aa/packages/plugin-link/sources/constants.ts
[constraints]: https://github.com/yarnpkg/berry/blob/0a230c14e71247576f6b51fa811ae08edb6608aa/packages/plugin-constraints/sources/commands/constraints.ts
[d-landscape]: ../../async-io/d-landscape.md
