# Wireit (JavaScript/TypeScript)

Google's minimal upgrade to `npm`/`yarn`/`pnpm` scripts: Wireit does **not**
declare or install workspaces — it leans on the package manager's own
`workspaces` — but it adds a per-script dependency graph, content-addressed
fingerprinting, incremental "skip-if-fresh" execution, and local + GitHub-Actions
output caching, all configured in a `wireit` block inside the package's existing
`package.json`.

| Field           | Value                                                                                                                     |
| --------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Language        | TypeScript (the CLI/engine; ships as the `wireit` npm package, a single binary plus a VS Code extension)                  |
| License         | Apache-2.0                                                                                                                |
| Repository      | [google/wireit][repo]                                                                                                     |
| Documentation   | [github.com/google/wireit README][docs] · [`package.json` config reference][docs]                                         |
| Category        | JS/TS Task Orchestrator                                                                                                   |
| Workspace model | **Inherited** from the package manager (`package.json#workspaces` / `pnpm-workspace.yaml`); Wireit adds only a task layer |
| First released  | `0.1.0`, **April 7, 2022** (`0.0.0` placeholder published April 4, 2022)                                                  |
| Latest release  | `0.14.12`, **April 10, 2025**                                                                                             |

> **Latest release:** `0.14.12` (published April 10, 2025; the npm `latest`
> dist-tag). A `0.15.0-pre.2` prerelease exists (same day) but is not the default
> tag. Wireit has never shipped a `1.0` — it has stayed deliberately at `0.x`
> through its life, and is still pre-1.0 as of June 2026. The headline `0.14.x`
> work was migrating the GitHub Actions cache integration to the service's **v2
> backend** (the old v1 Actions cache API was being retired); see
> [Caching & remote execution](#caching--remote-execution).

---

## Overview

### What it solves

A JS/TS monorepo's package manager (`npm`, `yarn`, `pnpm`) handles **workspaces**
— it installs and symlinks inter-dependent packages into a shared `node_modules`
— but it has no model of a **build/test graph**. `npm run build --workspaces`
runs every package's `build` script in declaration order, with no notion of
"package A's `build` must finish before package B's `build`", no way to run
independent legs in parallel, and no way to skip a script whose inputs have not
changed. The heavyweight answer to this is a separate orchestrator binary
([Turborepo][turborepo], [Nx][nx], [Lage][lage]) with its own root config file
(`turbo.json`, `nx.json`) layered over the workspace.

Wireit takes the **minimalist** position. Rather than introduce a new top-level
config file or a new CLI verb, it keeps `npm run build` as the entry point and
moves the actual command into a `wireit` block in the **same** `package.json`,
where each script can declare its `dependencies`, input `files`, and `output`
globs. From those three facts Wireit derives a cross-package task DAG, runs it
with bounded parallelism, and fingerprints every script so unchanged work is
skipped or restored from cache. The README states the design goal directly:

> _"Wireit is designed to be the minimal addition to npm needed to get script
> dependencies and incremental build."_ — [`README.md`][docs]

Within the JS/TS task-orchestrator family, Wireit is the canonical
_no-new-binary, no-new-config-file_ data point: compare [Turborepo][turborepo]
(separate Rust binary + `turbo.json` + remote cache as a service),
[Nx][nx] (a plugin platform with `nx.json` and project graph), [Lerna][lerna]
(now delegating task running to Nx), and [Lage][lage] (Microsoft's pipeline
runner). For where this leaves `dub`, see the [D landscape note][d-landscape].

### Design philosophy

Three commitments shape the whole tool, all visible in the README feature list
([`README.md`][docs]):

1. **Wrap, don't replace.** _"Use the `npm run` commands you already know."_ The
   `scripts` entry becomes the literal string `"wireit"`, so `npm run build`
   still works, CI scripts are untouched, and the migration is incremental — one
   script at a time. Wireit also _"works with `node --run`, `yarn`, and pnpm."_
2. **Correctness through content, not timestamps.** Freshness is decided by a
   SHA-256 **fingerprint** of all _"meaningful inputs of a script"_
   ([`fingerprint.ts`][fingerprint]) — command, file contents, env, transitive
   dependency fingerprints, platform — not by mtimes. A script with no declared
   `files`/`output` is treated as _always stale_, because Wireit cannot prove
   otherwise. Caching is correct-by-default or absent-by-default; it never
   guesses.
3. **The package manager owns dependencies and the workspace.** Wireit installs
   nothing, resolves no versions, and writes no lockfile. It _"complements npm
   workspaces"_ and reads `package.json` only to discover scripts and the
   `wireit` config. Cross-package edges are plain relative paths
   (`"../other-package:build"`), so they work in **any** monorepo layout the
   package manager already supports.

---

## How it works

A Wireit script lives in two places in one `package.json`: the `scripts` entry is
replaced by the sentinel `"wireit"`, and a same-named key under `wireit` carries
the real configuration. From [`README.md`][docs]:

```json
{
  "scripts": {
    "build": "wireit"
  },
  "wireit": {
    "build": {
      "command": "tsc",
      "dependencies": ["../other-package:build"],
      "files": ["src/**/*.ts", "tsconfig.json"],
      "output": ["lib/**", ".tsbuildinfo"],
      "clean": "if-file-deleted"
    }
  }
}
```

The recognized config keys are `command`, `dependencies`, `files`, `output`,
`clean`, `env`, `service`, and `packageLocks`. When `npm run build` is invoked,
the `build` script is the string `wireit`, so npm runs the `wireit` binary, which
inspects `npm_lifecycle_event` to learn _which_ script it was invoked as, then
analyzes, schedules, and runs that script's subgraph.

### Pipeline: analyze → fingerprint → execute

```bash
# All three of these run the SAME wireit binary; the package manager
# tells wireit which script via the npm_lifecycle_event env var.
npm run build                 # one-shot, with caching + incremental skip
npm run build --watch         # re-run on file changes (transitively)
WIREIT_PARALLEL=4 npm test    # bound parallelism (default = os.cpus().length * 2)
```

1. **Analyze** ([`analyzer.ts`][analyzer]). The `Analyzer` _"analyzes and
   validates a script along with all of its transitive dependencies, producing a
   build graph that is ready to be executed."_ It reads each `package.json` via a
   `CachingPackageJsonReader`, parses the `wireit` block with a JSON AST (so
   diagnostics point at exact source ranges), resolves dependency references, and
   detects cycles with a deterministic depth-first walk.
2. **Fingerprint** ([`fingerprint.ts`][fingerprint]). For each script,
   `Fingerprint.compute` hashes every meaningful input into a SHA-256 digest.
3. **Execute** ([`executor.ts`][executor], `execution/standard.ts`). The
   `Executor` walks the DAG, runs dependencies first, checks freshness/cache, and
   only spawns the command when neither is satisfied.

### Workspace declaration & topology

Wireit has **no workspace manifest of its own** — this is its defining
architectural choice. It never enumerates members; it discovers them lazily by
**following dependency edges**. The roots of the graph are the script(s) you
invoke; from there the `Analyzer` walks each `dependencies` entry, reading the
referenced `package.json` on demand:

- **Intra-package** dependencies are bare script names: `"dependencies":
["build"]` means _this package's_ `build` script.
- **Cross-package** dependencies are a **relative path** plus `:` plus a script
  name. From [`analyzer.ts`][analyzer], a reference is cross-package _"if it
  starts with a dot"_; `#resolveCrossPackageDependency` finds the `:` separator,
  splits into a package path and script name, resolves the path with
  `pathlib.resolve()` against the current package dir, and rejects a reference to
  the same package.

```json
{
  "wireit": {
    "build": {
      "command": "tsc",
      "dependencies": ["../core:build", "../utils:build"]
    }
  }
}
```

There is **no glob, no `members` array, no root config**. The "topology" is
exactly the transitive closure of `dependencies` from the invoked script. This is
both Wireit's great simplification (nothing to keep in sync; a package is "in the
workspace" iff something depends on it) and its limitation: there is no
first-class "the whole repo" object, so a true repo-wide operation is expressed
by the package manager's own fan-out (`npm run build --workspaces` /
`pnpm -r run build`), with Wireit handling ordering _within_ each invocation.

> [!NOTE]
> Because edges are relative filesystem paths rather than package _names_, Wireit
> does not consult the package manager's resolved dependency graph at all. It
> works identically under `npm`, `yarn`, or `pnpm`, and even in a monorepo that
> uses no workspace feature — the only requirement is that the referenced
> directory contains a `package.json` with the named script.

### Dependency handling & isolation

This dimension largely **does not apply** to Wireit in the package-management
sense: Wireit performs **no** dependency installation, hoisting, symlinking, or
version resolution. That is wholly the package manager's job — Wireit assumes
`node_modules` is already populated. What Wireit _does_ model is the **task**
dependency between scripts, plus two correctness inputs that touch the dependency
world:

- **`packageLocks`** — a list of lockfile basenames (default
  `["package-lock.json"]`) whose content hashes feed the fingerprint, so a
  dependency upgrade invalidates the cache even if no source file changed.
- **`cascade`** — whether a dependency's fingerprint is folded into the
  dependent's fingerprint. The object form of a dependency carries it:

```json
{
  "dependencies": [
    {
      "script": "../core:build",
      "cascade": false
    }
  ]
}
```

`cascade: false` (introduced in `0.7.3`, 2022-11-14) is the escape hatch for
_"this dependency must run first, but its output does not change my inputs"_ — a
type-checked package that imports another's `.d.ts` but emits independently. From
the fingerprint logic ([`fingerprint.ts`][fingerprint]): _"cascade: false means
the fingerprint of the dependency isn't directly inherited."_ The dependency
still gates ordering; it just stops re-running the dependent when only the
dependency changed.

### Task orchestration & scheduling

Wireit builds an explicit **task DAG** and executes it with a content-hash
freshness check at each node — the core of the tool.

**The DAG.** The `Analyzer` produces a validated graph of `ScriptConfig` nodes
keyed by `ScriptReference` (`{name, packageDir}`), with `Dependency` edges
`{specifier, config, cascade}`. Cycle detection is a deterministic DFS that sorts
dependencies by package directory and name for reproducible error messages.

**Concurrency.** The `Executor` runs independent legs concurrently through a
`WorkerPool` ([`util/worker-pool.ts`][workerpool]), _"a mechanism for ensuring
that at most N tasks are taking place at once … to prevent running too many
scripts at once and swamping the system."_ The default `numWorkers` is
`os.cpus().length * 2` ([`cli-options.ts`][clioptions]), overridable with the
`WIREIT_PARALLEL` env var (`Infinity` for unbounded). Scheduling is LIFO and
makes _"no guarantee … about ordering or fairness."_

**Change detection via fingerprint.** Each script's `Fingerprint` is the SHA-256
of a JSON object of all meaningful inputs. The verbatim `FingerprintData`
interface ([`fingerprint.ts`][fingerprint]):

```ts
// src/fingerprint.ts — "All meaningful inputs of a script. Used for
// determining if a script is fresh, and as the key for storing cached output."
export interface FingerprintData {
  __FingerprintDataBrand__: never;
  fullyTracked: boolean; // are all inputs+outputs known, transitively?
  platform: NodeJS.Platform; // e.g. linux, win32
  arch: string; // e.g. x64
  nodeVersion: string; // e.g. 16.7.0
  command: string | undefined; // the shell command
  extraArgs: string[]; // extra args forwarded to the command
  clean: boolean | 'if-file-deleted';
  files: { [packageDirRelativeFilename: string]: FileSha256HexDigest };
  output: string[];
  dependencies: { [dep: ScriptReferenceString]: FingerprintSha256HexDigest };
  service: { readyWhen: { lineMatches: string | undefined } } | undefined;
  env: Record<string, string>;
}
```

The fingerprint hashes **file contents**, not timestamps — `files` maps each
input path to its SHA-256 — so it is stable across checkouts, machines, and CI
runners. `dependencies` embeds each cascading dependency's own fingerprint,
making the whole thing recursive. The execution decision in
`execution/standard.ts` is, in order:

1. Run all dependencies first (`_executeDependencies`), collecting their
   fingerprints.
2. Compute this script's fingerprint from current file contents + those
   dependency fingerprints.
3. If `#fingerprintIsFresh(fingerprint)` **and** `#outputManifestIsFresh()`,
   return `#handleFresh` — **skip execution entirely**.
4. Otherwise, if the fingerprint is `fullyTracked`, ask the cache:
   `cacheHit = await this.#cache?.get(config, fingerprint)`. A hit restores the
   output via `cacheHit.apply()` instead of running.
5. Otherwise `#handleNeedsRun` spawns the command in a child process.

A script with no `files`/`output` has `fullyTracked: false`, so step 4 is
skipped — _"scripts without defined `files` or `output` will always run, because
Wireit doesn't know which files to check for changes."_

**Failure modes.** The `Executor` supports three `FailureMode`s
([`executor.ts`][executor]): `no-new` (let running scripts finish, start no new
ones), `continue` (start new ones unless a _dependency_ failed), and `kill`
(immediately kill running scripts).

**Services.** Long-running processes (dev servers) set `"service": true`. A
service started as a _dependency_ comes up before its dependents and is torn down
after they finish; a service run _directly_ stays up until the user kills Wireit.
Readiness is detected by a log regex:

```json
{
  "wireit": {
    "serve": {
      "service": {
        "readyWhen": {
          "lineMatches": "Server listening on port \\d+"
        }
      }
    }
  }
}
```

**Watch mode.** `npm run build --watch` _"monitors all `files` of a script, and
all `files` of its transitive dependencies, and when there is a change, it
re-runs only the affected scripts."_ Strategy is tunable via
`WIREIT_WATCH_STRATEGY` (`event` / `poll`) and `WIREIT_WATCH_POLL_MS`.

> [!IMPORTANT]
> Wireit has **no `--since`/git-diff affected-detection** like
> [Turborepo][turborepo] (`--filter=...[ref]`), [Nx][nx] (`nx affected`), or
> [Lerna][lerna] (`--since`). "Did this change?" is answered entirely by the
> per-script content fingerprint, not by diffing git refs. The effect is similar
> (unchanged scripts are skipped) but the granularity is the script's declared
> `files`, and there is no "given this PR diff, which packages are impacted?"
> query — only "run the graph, skipping fresh nodes."

### Caching & remote execution

Wireit caches a script's **`output` files** keyed by its fingerprint, behind the
small `Cache` interface ([`caching/cache.ts`][cache]) — _"Saves and restores
output files to some cache store (e.g. local disk or remote server)"_ — with a
deferred-apply `CacheHit` so the `Executor` controls _when_ restored files land:

```ts
// src/caching/cache.ts
export interface Cache {
  get(
    script: ScriptReference,
    fingerprint: Fingerprint,
  ): Promise<CacheHit | undefined>;
  set(
    script: ScriptReference,
    fingerprint: Fingerprint,
    absoluteFiles: AbsoluteEntry[],
  ): Promise<boolean>;
}
export interface CacheHit {
  apply(): Promise<void>; // write the cached files to disk
}
```

Two backends implement it:

- **Local disk** ([`caching/local-cache.ts`][localcache]). Output is copied into
  `".wireit/<script-name-hex>/cache/<cache-key-sha256-hex>"` inside each package.
  A `get` is a directory-exists check on that path; restore is a file copy. Local
  caching is on by default and disabled when `CI=true`. (A known limitation noted
  in-source: _"A script's cache directory currently just grows forever"_ — there
  is no automatic eviction.)
- **GitHub Actions** ([`caching/github-actions-cache.ts`][ghcache]). Enabled by
  adding the `google/wireit@setup-github-actions-caching/v2` action to a
  workflow, which injects the credentials Wireit reads. `set` builds a **tarball**
  of the output and runs a reserve → upload (chunked) → commit handshake against
  the Actions cache service; `get` queries by `(key, version)` where the **key**
  derives from the script reference and the **version** is the fingerprint. Cache
  entries are deleted after 7 days or once total usage exceeds 10 GB (Actions
  service policy). Cache keys are namespaced with a `wireit-` prefix (added in
  `0.14.11`), and `ImageOS` is folded in so different runner images don't collide.

There is **no general remote-execution (REAPI) backend** and no first-party
self-hosted remote cache: the only "remote" tier is the GitHub Actions cache,
reused as a free content store. This is a deliberate scope limit — contrast
[Turborepo][turborepo]'s Remote Cache (Vercel-hosted or self-hostable),
[Nx][nx]'s Nx Cloud / Nx Replay, and the full Remote Execution API of
[Bazel][bazel] / Buck2 backed by remote-execution backends such as BuildBuddy or
NativeLink.

The `output` globs also drive **clean** behavior: `clean: true` (default) deletes
output before every run for hermeticity; `clean: "if-file-deleted"` only cleans
when an input was removed (cheaper for incremental compilers like `tsc` that do
their own stale-output pruning); `clean: false` never cleans.

### CLI / UX ergonomics

Wireit's command boundary is the most distinctive in this survey: **there is no
Wireit verb.** You never type `wireit build`. The entire UX is the package
manager's existing `run`:

```bash
npm run build                  # invoke the "build" script (analyze+fingerprint+run)
npm run build --watch          # add watch mode
npm test --workspaces          # package-manager fan-out; wireit orders each leg
pnpm -r run build              # same idea under pnpm
WIREIT_PARALLEL=4 npm run build  # cap concurrency
```

Configuration — not flags — selects behavior. Where Turborepo has `--filter`,
`-F`, and `[ref]` syntax, and Nx has `nx run-many --projects=...` and
`nx affected`, Wireit has:

- **No targeting flags.** Selection is "which script you invoke"; scope is "what
  it depends on." Repo-wide scope is delegated to `npm`/`pnpm`'s own
  `--workspaces` / `-r`.
- **A handful of env vars**, not flags: `WIREIT_PARALLEL` (concurrency),
  `WIREIT_WATCH_STRATEGY` / `WIREIT_WATCH_POLL_MS` (watch tuning), `CI`
  (auto-detected, disables local caching), `WIREIT_FAILURES` (failure mode),
  `WIREIT_CACHE` (`local` / `github` / `none`).
- **Pass-through args** after `--` reach the underlying `command` and are folded
  into `extraArgs` in the fingerprint, so `npm run test -- --grep foo` is a
  distinct cache key from a bare `npm run test`.
- **Editor integration.** A VS Code extension surfaces the same diagnostics the
  `Analyzer` produces (cycles, missing scripts, bad globs) inline, plus
  hover/go-to-definition across `dependencies` edges.

The net ergonomic trade is: zero new commands to learn and zero new top-level
config file, at the cost of no rich on-the-fly selection/filtering vocabulary —
everything you want Wireit to do, you declare in `package.json` ahead of time.

---

## Strengths

- **Truly minimal adoption.** No new binary to invoke, no new top-level config
  file, no lockfile, no install step. Migrate one script at a time; `npm run`
  keeps working for collaborators who don't know Wireit is there.
- **Correct, content-based incrementality.** SHA-256 fingerprints over file
  _contents_ (not mtimes), env, lockfiles, platform, and transitive dependency
  fingerprints make skip/cache decisions reproducible across machines and CI.
- **Free remote cache.** The GitHub Actions cache backend gives cross-CI-run
  output reuse with no third-party service and no hosting cost.
- **Package-manager-agnostic and layout-agnostic.** Cross-package edges are
  relative paths, so it works under `npm`/`yarn`/`pnpm` and in any directory
  layout, even with no workspace feature enabled.
- **First-class services + watch.** Dependency-ordered service startup/teardown
  and transitive-aware watch mode cover the dev-server inner loop, not just CI.
- **`cascade: false`** cleanly separates _ordering_ from _fingerprint
  inheritance_, avoiding needless rebuilds in type-only dependency chains.
- **Excellent diagnostics.** JSON-AST-based config parsing yields precise,
  source-located error messages and editor integration.

## Weaknesses

- **No workspace model of its own.** No `members` glob, no virtual root, no
  repo-wide object; "the whole repo" is the package manager's fan-out, and the
  task graph is only ever the closure of the invoked script.
- **No affected/`--since` git-diff selection.** Freshness is per-script content
  hashing only; there is no "which packages does this PR touch?" query and no
  targeting/filter flags at all.
- **Remote tier is GitHub-Actions-only.** No REAPI, no self-hostable remote
  cache, no remote _execution_; non-GitHub CI gets only local caching.
- **Manual `files`/`output` declaration.** Forget them and the script always
  re-runs (no caching); declare them wrong and you risk under-caching. There is
  no input inference.
- **Unbounded local cache growth.** `.wireit/.../cache/` has no eviction
  (acknowledged TODO in-source).
- **Still pre-1.0** after ~4 years (`0.14.12`); config keys and behavior carry
  the implicit instability of `0.x`.
- **Node-/JS-centric.** Commands are arbitrary shells, but the whole model
  (scripts in `package.json`, `node_modules`, `node --run`) assumes a JS toolbox.

## Key design decisions and trade-offs

| Decision                                                      | Rationale                                                                          | Trade-off                                                                                           |
| ------------------------------------------------------------- | ---------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Config in `package.json`, script string = `"wireit"`          | Zero new files/commands; `npm run` keeps working; incremental, per-script adoption | No global/repo-wide config object; everything must be declared per package, no central defaults     |
| No workspace manifest; graph = closure of `dependencies`      | Nothing to keep in sync; works under any PM and any layout                         | No "whole workspace" primitive; repo-wide runs delegate to `npm --workspaces` / `pnpm -r`           |
| Cross-package edges are **relative paths** (`../p:build`)     | PM-agnostic; ignores resolved package graph; works with no workspace feature       | Refactoring a directory breaks edges; no name-based resolution; no awareness of version constraints |
| SHA-256 fingerprint of file _contents_ + env + deps           | Reproducible freshness/caching across machines & CI; immune to mtime churn         | Must declare `files`/`output`; misdeclaration under/over-caches; hashing cost on large inputs       |
| Freshness/affected = fingerprint only (no git-diff `--since`) | One correct mechanism; no ref-diff bookkeeping                                     | No "impacted by this PR" query; no filter/target flags; coarser than per-package diff in some flows |
| Caching: local disk + **GitHub Actions** only                 | Free cross-run cache with no third-party service                                   | No REAPI, no self-hosted remote cache, no remote execution; non-GitHub CI gets local-only           |
| `cascade: false` separates ordering from fingerprint inherit  | Avoids rebuilding dependents on type-only/independent-output dependency changes    | Another correctness knob to reason about; wrong setting can skip a genuinely-needed rebuild         |
| `WorkerPool` cap = `os.cpus().length * 2`, env-tunable        | Bounds load without per-run flags; sensible default for I/O-bound script commands  | LIFO, no fairness guarantees; tuning is an env var, not a flag                                      |
| Pre-1.0, minimal surface area                                 | Keeps the tool small and the maintenance burden low                                | Implied instability; features like remote execution / affected-graph deliberately out of scope      |

---

## Sources

- [google/wireit — GitHub repository][repo]
- [`README.md` — features, config reference, "minimal addition to npm" goal][docs]
- [`src/analyzer.ts` — `Analyzer`, cross-package resolution, cycle detection][analyzer]
- [`src/fingerprint.ts` — `FingerprintData`, SHA-256 hashing, `cascade`][fingerprint]
- [`src/executor.ts` — `Executor`, `WorkerPool`, `FailureMode`][executor]
- [`src/execution/standard.ts` — fresh/cache-hit/needs-run decision flow][executor]
- [`src/caching/cache.ts` — `Cache` / `CacheHit` interface][cache]
- [`src/caching/local-cache.ts` — `.wireit/.../cache/` local backend][localcache]
- [`src/caching/github-actions-cache.ts` — Actions cache tarball backend][ghcache]
- [`src/util/worker-pool.ts` — bounded-concurrency pool][workerpool]
- [`src/cli-options.ts` — `WIREIT_PARALLEL`, default `cpus*2`][clioptions]
- [`wireit` on npm — versions / publish dates][npm]
- Sibling deep-dives: [Turborepo][turborepo] · [Nx][nx] · [Lerna][lerna] · [Lage][lage] · [pnpm][pnpm] · [Bazel][bazel]
- Synthesis: [umbrella index][umbrella] · D context: [D async/runtime landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/google/wireit
[docs]: https://github.com/google/wireit/blob/main/README.md
[npm]: https://www.npmjs.com/package/wireit
[analyzer]: https://github.com/google/wireit/blob/main/src/analyzer.ts
[fingerprint]: https://github.com/google/wireit/blob/main/src/fingerprint.ts
[executor]: https://github.com/google/wireit/blob/main/src/executor.ts
[cache]: https://github.com/google/wireit/blob/main/src/caching/cache.ts
[localcache]: https://github.com/google/wireit/blob/main/src/caching/local-cache.ts
[ghcache]: https://github.com/google/wireit/blob/main/src/caching/github-actions-cache.ts
[workerpool]: https://github.com/google/wireit/blob/main/src/util/worker-pool.ts
[clioptions]: https://github.com/google/wireit/blob/main/src/cli-options.ts
[turborepo]: ../turborepo/
[nx]: ../nx/
[lerna]: ../lerna/
[lage]: ../lage/
[pnpm]: ../pnpm/
[bazel]: ../bazel/
[umbrella]: ../
[d-landscape]: ../../async-io/d-landscape.md
