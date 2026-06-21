# pnpm (JavaScript/TypeScript)

A fast, disk-efficient Node.js package manager whose **content-addressed store** and **strict symlinked `node_modules`** make it the de-facto monorepo tool for JS/TS — pairing a first-class `pnpm-workspace.yaml` topology, the `workspace:` local-reference protocol, Gradle-inspired version **catalogs**, and a topological recursive task runner (`pnpm -r run`) driven by the rich `--filter` selector grammar.

| Field           | Value                                                                                                            |
| --------------- | ---------------------------------------------------------------------------------------------------------------- |
| Language        | TypeScript (CLI); a Rust port, `pacquet`, lives in-tree under `pacquet/`                                         |
| License         | MIT — **except** the `pnpr/` directory, source-available under PolyForm Shield 1.0.0                             |
| Repository      | [pnpm/pnpm][repo]                                                                                                |
| Documentation   | [pnpm.io][docs] · [pnpm.io/workspaces][ws-docs] · [pnpm.io/catalogs][catalogs-docs]                              |
| Category        | JS/TS Package Manager                                                                                            |
| Workspace model | Virtual root: a `pnpm-workspace.yaml` with a glob `packages` array; members linked via the `workspace:` protocol |
| First released  | `1.0` on June 28, 2017 (initial work in 2016 by Rico Sta. Cruz; lead maintainer Zoltan Kochan)                   |
| Latest release  | `11.5.2`                                                                                                         |

> **Latest release:** `11.5.2` (the `11.x` line, June 2026). pnpm `11.0` (April 2026) is a watershed: it is **pure ESM**, requires **Node.js 22+**, replaced the JSON-per-package store index with a **single SQLite database**, and completed the migration of all non-auth settings out of `package.json#pnpm` into `pnpm-workspace.yaml` — pnpm `11` no longer reads the `pnpm` field of `package.json` at all. Catalogs (the `catalog:` protocol) landed earlier, in `9.5.0` (July 2024).

---

## Overview

### What it solves

npm and Yarn Classic install dependencies into a **flat, hoisted `node_modules`**: every transitive package is copied (or deduplicated by hoisting to the top) into one tree per project. This wastes disk (100 projects using `lodash` keep 100 copies) and is **non-strict** — a package can `require` something it never declared, because hoisting accidentally made it reachable ("phantom dependencies").

pnpm rejects both. It stores every file of every package version **once**, in a global **content-addressable store**, and builds each project's `node_modules` out of **symlinks into a hidden virtual store** (`node_modules/.pnpm`) whose contents are in turn **hard-linked (or reflinked / copy-on-write)** from the global store. From the project [README][repo]:

> _"pnpm uses a content-addressable filesystem to store all files from all module directories on a disk. When using npm, if you have 100 projects using lodash, you will have 100 copies of lodash on disk. With pnpm … All the files are saved in a single place on the disk. When packages are installed, their files are linked from that single place consuming no additional disk space. Linking is performed using either hard-links or reflinks (copy-on-write)."_

The same machinery makes pnpm an exceptional **monorepo** tool. A `pnpm-workspace.yaml` declares the member packages; each member gets its own strict, isolated `node_modules` (no cross-member phantom deps); members depend on each other with the `workspace:` protocol, which resolves to an **on-disk symlink** during development and is **rewritten to a real version range at publish time**; and `pnpm -r` (`--recursive`) runs scripts across members **in topological order with bounded concurrency**, sliced by the `--filter` selector grammar.

This puts pnpm in the same niche as [npm](../npm/) and [Yarn Berry](../yarn-berry/) (the other JS/TS package managers), but with a stricter dependency model than either; compare it to [Bun](../bun/)'s speed-first installer. For pure task orchestration on top of pnpm workspaces, [Turborepo](../turborepo/) and [Nx](../nx/) add input-hashing build caches that pnpm itself does not have.

### Design philosophy

pnpm's three load-bearing commitments, each restated as a column of the trade-offs table below:

1. **Strictness over convenience.** A package may import only what its own `package.json` declares. The non-flat `node_modules` is the enforcement mechanism, not an accident — the maintainers' position is laid out in _["Flat node_modules is not the only way"][flat-blog]_.
2. **Store the bytes once, link everywhere.** The content-addressable store keyed by `sha512` ([`store/cafs/src/index.ts`][cafs-index]: `export const HASH_ALGORITHM = 'sha512'`) means identical files across versions/projects share one inode; only changed files cost new disk.
3. **The workspace is first-class.** Unlike [Composer](../composer/) (no native workspace) or even npm (workspaces bolted onto `package.json`), pnpm carries a dedicated `pnpm-workspace.yaml`, a `workspace:` resolver protocol, version catalogs, and a recursive topological runner — the full monorepo surface in the package manager itself.

> [!NOTE]
> pnpm is a **package manager that grew a strong workspace + task layer**, not a build-graph engine. It has no build/test **result** cache and no remote execution (see [Caching & Remote Execution](#4-caching--remote-execution)); teams that need those layer [Turborepo](../turborepo/) / [Nx](../nx/) on top. The catalog of orchestrators in this survey exists precisely because package managers stop at "install + run script in topo order".

---

## How it works

### The store, the virtual store, and the project `node_modules`

A pnpm install resolves three nested layers of indirection:

1. **The global content-addressable store** (default `~/.local/share/pnpm/store/v10` on Linux). Each _file_ — not each package — is written under a path derived from its `sha512` digest. From [`store/cafs/src/getFilePathInCafs.ts`][cafs-path]:

   ```ts
   export function contentPathFromHex(fileType: FileType, hex: string): string {
     const p = `files${SEP}${hex.slice(0, 2)}${SEP}${hex.slice(2)}`;
     switch (fileType) {
       case 'exec':
         return `${p}-exec`; // mode & 0o111 !== 0
       case 'nonexec':
         return p;
     }
   }
   ```

   Two package versions that differ in one file share every _other_ file's inode. Writes are atomic and concurrency-safe (`O_CREAT|O_EXCL`, temp+rename on integrity mismatch — see [`store/cafs/src/writeBufferToCafs.ts`][write-buffer-to-cafs]).

2. **The virtual store** — `node_modules/.pnpm/` at the workspace (or project) root. Each resolved package+peer-set gets a directory like `.pnpm/lodash@4.17.21/node_modules/lodash`, whose files are **hard-linked** from the global store. A package's _own_ dependencies are symlinked as siblings inside its `.pnpm` entry, so the dependency graph is reconstructed exactly, with no hoisting.

3. **The project `node_modules`** — only the package's **direct** dependencies appear here, each a **symlink** into the virtual store. This is what enforces strictness: nothing a package didn't declare is reachable.

### The `workspace:` protocol

Local cross-references use a dedicated specifier. The parser is tiny ([`workspace/spec-parser/src/index.ts`][spec-parser]):

```ts
const WORKSPACE_PREF_REGEX =
  /^workspace:(?:(?<alias>[^._/][^@]*)@)?(?<version>.*)$/;
```

so `workspace:*`, `workspace:^`, `workspace:~`, `workspace:1.2.3`, and aliased `workspace:other-name@*` are all valid. The version part is matched against in-repo member versions by [`workspace/range-resolver/src/index.ts`][range-resolver]:

```ts
export function resolveWorkspaceRange(
  range: string,
  versions: string[],
): string | null {
  if (range === '*' || range === '^' || range === '~' || range === '') {
    return semver.maxSatisfying(versions, '*', { includePrerelease: true });
  }
  return semver.maxSatisfying(versions, range, { loose: true });
}
```

During development the dependency is a **symlink to the member's source directory** — edits are seen immediately, no rebuild/republish. At **publish** time pnpm rewrites the `workspace:` specifier to a concrete range: `workspace:*` → the exact current version, `workspace:^` → `^<version>`, `workspace:~` → `~<version>`. So a published package never ships an unresolvable `workspace:` string.

### Catalogs: one version, referenced many times

A **catalog** defines a dependency range once in `pnpm-workspace.yaml` and lets members reference it by the `catalog:` protocol — the feature was added in `9.5.0`, explicitly _"inspired by a similar idea from the Gradle build tool"_. The manifest type ([`workspace/workspace-manifest-reader/src/index.ts`][workspace-manifest-reader]):

```ts
export interface WorkspaceManifest extends PnpmSettings {
  packages: string[];
  /** The default catalog … referenced via `catalog:default` or the `catalog:` shorthand. */
  catalog?: WorkspaceCatalog;
  /** Named catalogs … referenced via `catalog:<name>`. */
  catalogs?: WorkspaceNamedCatalogs;
}
```

A member writes `"react": "catalog:"` (default catalog) or `"react": "catalog:react18"` (a named catalog); pnpm substitutes the range at install time and rewrites it to the literal range at publish time. `catalogMode: strict` (used in pnpm's own `pnpm-workspace.yaml`) forbids un-cataloged versions of cataloged packages, killing version drift across members. This is the cleanest realization in this survey of a **workspace dependency registry**.

### Injected dependencies (hard-copy isolation)

The default `workspace:` link is a **symlink**, which means the dependent sees the member's _own_ `node_modules` — usually correct, but wrong when the member must be resolved against the _dependent's_ peer dependencies (e.g. a React component library tested against multiple React versions). For that, pnpm offers **injected dependencies** (`dependenciesMeta.<name>.injected: true`): the member is **hard-copied** into the dependent's virtual store instead of symlinked, and [`workspace/injected-deps-syncer/src/`][injected-deps-syncer] re-syncs the copy after each build. This is a deliberate isolation knob distinct from both symlinks and [Yarn Berry](../yarn-berry/)'s Plug'n'Play.

---

## The five dimensions

### 1. Workspace Declaration & Topology

pnpm uses a **dedicated workspace manifest**, `pnpm-workspace.yaml`, with a `packages` array of **globs** (relative to the file's directory). Discovery is glob-based with **negation** support — pnpm's own root manifest is the canonical example:

```yaml
# pnpm-workspace.yaml (excerpt from pnpm's own repo)
packages:
  - __utils__/*
  - '!__utils__/build-artifacts' # negation excludes a match
  - cli/*
  - config/*
  - pnpm
```

The reader ([`workspace/workspace-manifest-reader/src/index.ts`][workspace-manifest-reader]) treats a missing file, an empty file, and `{}` all as "valid, no workspace", and validates that `packages` is a string array. The root manifest is a **virtual root** — `package.json` at the root is typically `"private": true` and holds only orchestration scripts, not shippable code (though a root _can_ also be a member). Members are read and their inter-dependency edges computed in [`workspace/projects-graph/src/index.ts`][projects-graph], which walks each member's `dependencies`/`devDependencies`/`optionalDependencies`/`peerDependencies`, recognizes `workspace:` specs and `file:`/directory specs, and resolves each to a member `rootDir` — building the **project graph** that every recursive command consumes.

> [!NOTE]
> Since pnpm `11`, `pnpm-workspace.yaml` is also where **all settings** live (`onlyBuiltDependencies` → `allowBuilds`, `linkWorkspacePackages`, `catalogMode`, …). The `pnpm` field of `package.json` and non-auth keys of `.npmrc` are no longer read — registry/auth stay in `.npmrc`, everything else is YAML.

### 2. Dependency Handling & Isolation

pnpm's defining trait. **No hoisting** by default: each member gets a strict `node_modules` of only its declared direct deps (symlinks), backed by the per-project/-workspace virtual store `node_modules/.pnpm`, backed by the global content-addressed store (hard-link / reflink). The isolation guarantees:

- **No phantom dependencies** — a member cannot import an undeclared package, because it is simply not present in that member's `node_modules`.
- **Conflicting versions coexist** — two members may legitimately depend on different versions of the same library; each resolves to its own virtual-store entry. This is the opposite of [Composer](../composer/)'s single-flat-version model.
- **Disk is shared globally** — the store is cross-project, so a CI machine with many checkouts pays for each unique file once.

Cross-member local refs are the `workspace:` protocol (above). A `--shared-workspace-lockfile` (the default) produces **one `pnpm-lock.yaml` at the workspace root** covering every member — a unified lockfile, not per-member files. pnpm offers escape hatches for ecosystems that need flatness: `node-linker: hoisted` (a classic flat `node_modules`), `public-hoist-pattern`, and `shamefully-hoist` — all opt-in, all named to discourage use.

### 3. Task Orchestration & Scheduling

pnpm builds a **project DAG** and runs scripts across it **in topological order with bounded concurrency** — but it does **not** do per-task input hashing or result caching (that is the orchestrators' job). The recursive runner [`exec/commands/src/runRecursive.ts`][run-recursive] is the core:

```ts
const sortedPackageChunks = opts.sort
  ? sortProjects(opts.selectedProjectsGraph) // topological chunks
  : [Object.keys(opts.selectedProjectsGraph).sort()];
let packageChunks = opts.reverse
  ? sortedPackageChunks.reverse()
  : sortedPackageChunks;
const limitRun = pLimit(getWorkspaceConcurrency(opts.workspaceConcurrency));
for (const chunk of packageChunks) {
  // every project in a chunk is independent → run them concurrently
  await Promise.all(
    selectedScripts.map(({ prefix, scriptName }) =>
      limitRun(async () => {
        /* runScript(...) */
      }),
    ),
  );
}
```

The topology comes from [`workspace/projects-sorter/src/index.ts`][projects-sorter], which feeds the project graph to a `graphSequencer` and returns **chunks**: each chunk is a set of mutually-independent projects safe to run in parallel; chunks run in dependency order so a library builds before its dependents.

| Capability                | pnpm answer                                                                                                                    |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Task/target DAG           | **Project** DAG (member → member), not a fine-grained per-target DAG; ordering via `graphSequencer` chunks                     |
| Concurrent execution      | Yes — `pLimit(getWorkspaceConcurrency(...))`; `--workspace-concurrency N` (`1` = serial); independent chunk peers run together |
| Ordering controls         | `--sort` (topological, default on), `--reverse`, `--resume-from <pkg>`, `--bail`/`--no-bail`                                   |
| Change detection          | Yes, but only as **filtering** — `--filter '[<git-ref>]'` selects _changed_ members; there is no task-output hashing           |
| Cross-script `depends-on` | **No** — pnpm has no `dependsOn` task graph within a package; [Turborepo](../turborepo/)/[Nx](../nx/) add that                 |

So pnpm schedules **packages**, not **tasks**. `pnpm -r run build` runs each member's `build` script in topo order; it does _not_ know that one member's `test` depends on another's `build` output beyond the package-level edge.

### 4. Caching & Remote Execution

**Install caching: excellent. Task-result caching: none.** pnpm's caches are all about _installation_:

- The **content-addressable store** is the dominant cache: re-installing an already-seen file is a hard-link, not a download or copy. Since `11.0` the **store index is a single SQLite database** (replacing one JSON file per package), speeding cold installs and reducing inode pressure.
- `pnpm-lock.yaml` gives **reproducible** installs; `11.3`'s `trustLockfile` skips the supply-chain verification pass on an already-trusted lockfile.
- A metadata/HTTP cache avoids re-querying the registry.

There is **no build/test result cache, no input hashing of tasks, and no remote execution / REAPI backend** — pnpm never asks "have I already run this member's `test` for this input set?". That is the explicit boundary where [Turborepo](../turborepo/) (local + remote task cache), [Nx](../nx/) (computation cache + Nx Cloud), and the polyglot engines ([Bazel](../bazel/), [Buck2](../buck2/) with [BuildBuddy](../buildbuddy/)/[NativeLink](../nativelink/)) take over. The closest pnpm comes to "skip unchanged work" is `--filter '[origin/main]'`, which _selects_ changed members so you don't _run_ the others — coarse affected-detection, not memoized results.

### 5. CLI / UX Ergonomics

pnpm has the **richest member-slicing CLI** in this survey, built on two flags and one selector grammar. Setting either `--filter` or `--filter-prod` **auto-enables recursive mode** ([`cli/parse-cli-args/src/index.ts`][cli-parse-args]):

```ts
const RECURSIVE_CMDS = new Set(['recursive', 'multi', 'm']);
// ...
if (
  options['recursive'] !== true &&
  (options['filter'] || options['filter-prod'] || recursiveCommandUsed)
) {
  options['recursive'] = true;
}
```

The command boundary:

- **Global broadcast** — `pnpm -r run build` / `pnpm --recursive run test` runs a script in **every** member (topologically).
- **Targeted** — `pnpm --filter @scope/app run start`, or the short `pnpm -F @scope/app …`; `pnpm --filter ./packages/cli …` selects by location.
- **`--workspace-root` / `-w`** pins a command to the root project (e.g. `pnpm add -w typescript`).

The `--filter` **selector grammar** ([`workspace/projects-filter/src/parseProjectSelector.ts`][selector]) is the standout — a compact algebra over the project graph:

| Selector              | Meaning                                                                 |
| --------------------- | ----------------------------------------------------------------------- |
| `pkg`                 | the package named `pkg` (glob on name allowed, e.g. `@scope/*`)         |
| `./path` / `{glob}`   | members under a directory / matching a path glob                        |
| `!pkg`                | **exclude** `pkg` from the selection                                    |
| `pkg...`              | `pkg` **and all its dependencies** (downstream closure)                 |
| `...pkg`              | `pkg` **and all its dependents** (upstream closure)                     |
| `pkg^...` / `...^pkg` | the closure **excluding `pkg` itself** (the `^` marker)                 |
| `[<git-ref>]`         | members **changed since** `<git-ref>` (e.g. `--filter '[origin/main]'`) |

These compose: `--filter '...{packages/core}[HEAD~1]'` reads "everything that depends on whatever changed under `packages/core` since `HEAD~1`". The git-ref form is backed by [`workspace/projects-filter/src/getChangedProjects.ts`][changed], which runs `git diff --name-only <commit>` and maps changed files up to their owning member, even distinguishing `source` vs `test` changes (a test-only change does not force dependents to re-run).

---

## Strengths

- **Strict, isolated dependencies** — symlinked non-flat `node_modules` eliminates phantom dependencies; each member sees only what it declares.
- **Dramatic disk savings** — the global content-addressed store hard-links/reflinks every file once across all projects and versions.
- **First-class workspace model** — dedicated `pnpm-workspace.yaml`, glob+negation discovery, a unified root lockfile, and a clean virtual-root convention.
- **The `workspace:` protocol** — local-first cross-references that symlink in dev and rewrite to real ranges on publish; no relative `path=` bookkeeping.
- **Catalogs** — a Gradle-style central version registry (`catalog:` / `catalog:<name>`, `catalogMode: strict`) that abolishes cross-member version drift.
- **Best-in-class `--filter` grammar** — dependents/dependencies closures, `^` self-exclusion, path globs, and `[git-ref]` changed-since selection, all composable.
- **Topological recursive runner** — `pnpm -r run` builds members in dependency order with `--workspace-concurrency`, `--reverse`, `--resume-from`, `--bail`.
- **Injected dependencies** — an explicit hard-copy isolation mode for peer-sensitive members.

## Weaknesses

- **No task-result cache, no remote execution** — pnpm runs scripts; it does not memoize their outputs. Teams add [Turborepo](../turborepo/)/[Nx](../nx/) for that, the single largest gap vs. dedicated orchestrators.
- **Package-level DAG only** — orchestration granularity is the member, not the individual task; no intra-package `dependsOn` graph.
- **Symlink/hard-link friction on some platforms** — Windows without Developer Mode, certain Docker/overlay filesystems, and tools that don't follow symlinks (older bundlers, some native-addon toolchains) can misbehave; the `node-linker: hoisted` escape hatch exists for exactly these.
- **Strictness surprises** — code relying on npm's accidental hoisting breaks under pnpm until missing deps are declared (the intended behavior, but a migration cost).
- **Churn in configuration surface** — settings migrated from `.npmrc`/`package.json#pnpm` to `pnpm-workspace.yaml` across `10`→`11`, and `11` requires Node 22+ and is pure ESM — a real upgrade burden.

## Key design decisions and trade-offs

| Decision                                                         | Rationale                                                                           | Trade-off                                                                                    |
| ---------------------------------------------------------------- | ----------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Non-flat, symlinked `node_modules` (strict isolation)            | Eliminates phantom dependencies; each package sees only its declared deps           | Breaks code relying on hoisting; symlink-unaware tools / Windows / some Docker FS need care  |
| Global content-addressed store, hard-link / reflink              | Store each file's bytes once; huge disk savings; fast re-installs                   | Cross-project shared store can surprise (global cache invalidation, permissions, store GC)   |
| Dedicated `pnpm-workspace.yaml` + glob `packages` (virtual root) | A first-class, discoverable topology with negation, separate from any one package   | A second manifest to maintain; settings churn moving into it across `10`→`11`                |
| `workspace:` protocol (symlink in dev, rewrite on publish)       | Local-first refs with zero relative-path bookkeeping; published artifacts are valid | Behavior differs between dev (symlink) and consumers (range); injected mode needed for peers |
| Catalogs (`catalog:` central version registry, `strict` mode)    | One source of truth for shared ranges; abolishes drift; fewer merge conflicts       | `pnpm update` historically didn't manage catalogs; another concept to learn                  |
| Topological recursive runner, **no** task-result cache           | Correct build order + concurrency from the package graph, kept simple               | No memoization/affected-by-hash; needs Turborepo/Nx for incrementality and remote cache      |
| Rich `--filter` selector grammar (closures, `^`, `[git-ref]`)    | Precise, composable member slicing without external tooling                         | A grammar to learn; `[git-ref]` is coarse (member-level), not per-task affected-detection    |
| Unified root lockfile (`--shared-workspace-lockfile`, default)   | One reproducible resolution for the whole workspace                                 | A single lockfile is a contention point for very large repos with many concurrent PRs        |

---

## Sample workspace

A minimal, runnable two-package workspace ships alongside this deep-dive at [`./sample/`](./sample/). It demonstrates the model end to end:

- `pnpm-workspace.yaml` declares `packages: ['packages/*']` and a **default catalog** pinning `picocolors`.
- `packages/greeter` consumes the catalog with `"picocolors": "catalog:"`.
- `packages/cli` depends on the sibling **locally** via `"@sample/greeter": "workspace:*"`.
- The root `package.json` exposes the **topological task** `pnpm -r run build` and a filtered `pnpm --filter @sample/cli run start`.

With pnpm installed: `pnpm install` (links the workspace), `pnpm -r run build`, then `pnpm start` prints a colorized greeting from `@sample/cli` through `@sample/greeter`. (No `node_modules/`, `pnpm-lock.yaml`, or store is committed — see the sample's `.gitignore`.)

---

## Sources

- [pnpm/pnpm — GitHub repository][repo] (source for all quoted file paths)
- [pnpm documentation — pnpm.io][docs]
- [Workspaces — pnpm.io/workspaces][ws-docs]
- [Catalogs — pnpm.io/catalogs][catalogs-docs] (Gradle-inspired version registry, added `9.5.0`)
- [Filtering — pnpm.io/filtering][filtering-docs] (the `--filter` selector grammar)
- [Settings (`pnpm-workspace.yaml`) — pnpm.io/settings][settings-docs]
- [`workspace/spec-parser/src/index.ts` — the `workspace:` protocol parser][spec-parser]
- [`workspace/range-resolver/src/index.ts` — `workspace:*`/`^`/`~` resolution][range-resolver]
- [`workspace/projects-graph/src/index.ts` — building the project DAG][projects-graph]
- [`workspace/projects-sorter/src/index.ts` — topological chunking via `graphSequencer`][projects-sorter]
- [`workspace/projects-filter/src/parseProjectSelector.ts` — the `--filter` grammar][selector]
- [`workspace/projects-filter/src/getChangedProjects.ts` — `[git-ref]` changed-since detection][changed]
- [`workspace/workspace-manifest-reader/src/index.ts` — `pnpm-workspace.yaml` + catalogs][workspace-manifest-reader]
- [`exec/commands/src/runRecursive.ts` — the recursive topological runner][run-recursive]
- [`store/cafs/src/getFilePathInCafs.ts` — content-addressed store layout][cafs-path]
- [`store/cafs/src/index.ts` — `HASH_ALGORITHM = 'sha512'`][cafs-index]
- [`cli/parse-cli-args/src/index.ts` — CLI argument parser][cli-parse-args]
- [`store/cafs/src/writeBufferToCafs.ts` — integrity checks and writing to store][write-buffer-to-cafs]
- [`workspace/injected-deps-syncer/src/` — injected dependencies synchronization][injected-deps-syncer]
- [pnpm 11.0 release notes — ESM, Node 22, SQLite store][v11-blog]
- [Flat node_modules is not the only way (pnpm blog)][flat-blog]
- [pnpm 9.5 Introduces Catalogs (Socket)][catalogs-blog]
- [pnpm version 1 is out! (Zoltan Kochan, 2017)][v1-blog]
- [pnpm — Wikipedia (history)][wiki]
- Sibling deep-dives: [npm](../npm/) · [Yarn Berry](../yarn-berry/) · [Bun](../bun/) · [Composer](../composer/) · [Cargo](../cargo/) · [go-work](../go-work/) · [Turborepo](../turborepo/) · [Nx](../nx/) · [Bazel](../bazel/) · [Buck2](../buck2/) · [BuildBuddy](../buildbuddy/) · [NativeLink](../nativelink/) · [comparison](../comparison.md) · [dub baseline](../dub-baseline.md) · [D landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/pnpm/pnpm
[docs]: https://pnpm.io/
[ws-docs]: https://pnpm.io/workspaces
[catalogs-docs]: https://pnpm.io/catalogs
[filtering-docs]: https://pnpm.io/filtering
[settings-docs]: https://pnpm.io/settings
[spec-parser]: https://github.com/pnpm/pnpm/blob/9f002da43f61acd3ca1d99ba4a6e734d9d16ed3a/workspace/spec-parser/src/index.ts
[range-resolver]: https://github.com/pnpm/pnpm/blob/9f002da43f61acd3ca1d99ba4a6e734d9d16ed3a/workspace/range-resolver/src/index.ts
[projects-graph]: https://github.com/pnpm/pnpm/blob/9f002da43f61acd3ca1d99ba4a6e734d9d16ed3a/workspace/projects-graph/src/index.ts
[projects-sorter]: https://github.com/pnpm/pnpm/blob/9f002da43f61acd3ca1d99ba4a6e734d9d16ed3a/workspace/projects-sorter/src/index.ts
[selector]: https://github.com/pnpm/pnpm/blob/9f002da43f61acd3ca1d99ba4a6e734d9d16ed3a/workspace/projects-filter/src/parseProjectSelector.ts
[changed]: https://github.com/pnpm/pnpm/blob/9f002da43f61acd3ca1d99ba4a6e734d9d16ed3a/workspace/projects-filter/src/getChangedProjects.ts
[workspace-manifest-reader]: https://github.com/pnpm/pnpm/blob/9f002da43f61acd3ca1d99ba4a6e734d9d16ed3a/workspace/workspace-manifest-reader/src/index.ts
[run-recursive]: https://github.com/pnpm/pnpm/blob/9f002da43f61acd3ca1d99ba4a6e734d9d16ed3a/exec/commands/src/runRecursive.ts
[cafs-path]: https://github.com/pnpm/pnpm/blob/9f002da43f61acd3ca1d99ba4a6e734d9d16ed3a/store/cafs/src/getFilePathInCafs.ts
[cafs-index]: https://github.com/pnpm/pnpm/blob/9f002da43f61acd3ca1d99ba4a6e734d9d16ed3a/store/cafs/src/index.ts
[cli-parse-args]: https://github.com/pnpm/pnpm/blob/9f002da43f61acd3ca1d99ba4a6e734d9d16ed3a/cli/parse-cli-args/src/index.ts
[write-buffer-to-cafs]: https://github.com/pnpm/pnpm/blob/9f002da43f61acd3ca1d99ba4a6e734d9d16ed3a/store/cafs/src/writeBufferToCafs.ts
[injected-deps-syncer]: https://github.com/pnpm/pnpm/tree/9f002da43f61acd3ca1d99ba4a6e734d9d16ed3a/workspace/injected-deps-syncer/src
[v11-blog]: https://pnpm.io/blog/releases/11.0
[flat-blog]: https://pnpm.io/blog/2020/05/27/flat-node-modules-is-not-the-only-way
[catalogs-blog]: https://socket.dev/blog/pnpm-9-5-introduces-catalogs-shareable-dependency-version-specifiers
[v1-blog]: https://medium.com/pnpm/pnpm-version-1-is-out-935a07af914
[wiki]: https://en.wikipedia.org/wiki/Pnpm
[d-landscape]: ../../async-io/d-landscape.md
