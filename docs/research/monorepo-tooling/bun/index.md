# Bun (JavaScript/TypeScript)

A speed-first, all-in-one JavaScript runtime + toolkit whose `bun install` package manager treats npm `workspaces` as a native monorepo primitive — pairing glob-based topology discovery, the `workspace:` and `catalog:` protocols, a choice of **hoisted** (Yarn-style) or **isolated** (pnpm-style) `node_modules` layouts, and a parallel, dependency-ordered `bun run --filter` task runner — all implemented in Rust (the project completed its Zig→Rust rewrite) for sub-second installs.

| Field           | Value                                                                                                                                                                 |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language        | Rust (package-manager/runtime core; the Zig→Rust rewrite that began May 2026 has landed — the install/runtime sources are now `*.rs`, with no `*.zig` left in `src/`) |
| License         | MIT (Bun itself; bundled JavaScriptCore is LGPL/BSD)                                                                                                                  |
| Repository      | [oven-sh/bun][repo]                                                                                                                                                   |
| Documentation   | [bun.com/docs][docs] · [Workspaces][ws-docs] · [Isolated installs][iso-docs] · [Filter][filter-docs]                                                                  |
| Category        | JS/TS Package Manager                                                                                                                                                 |
| Workspace model | Virtual or root package: a root `package.json` with a glob `workspaces` array; members linked via the `workspace:` protocol                                           |
| First released  | `0.1.0` on July 5, 2022 (Jarred Sumner); `1.0` on September 8, 2023                                                                                                   |
| Latest release  | `1.4.0` (the `1.4.x` line; `1.3.14` is the prior stable tag)                                                                                                          |

> **Latest release:** `1.4.0` (June 2026). Key monorepo milestones: the **text lockfile** `bun.lock` shipped in `1.1.39` (Dec 2024) and became the **default** in `1.2.0` (Jan 2025), superseding the binary `bun.lockb`; **catalogs** and **isolated installs** (pnpm-style, default for new workspaces) also landed in the `1.2.x` line. In December 2025 the project [joined Anthropic][anthropic]; the [Zig→Rust rewrite][rust-rewrite] that began in May 2026 has since **landed in-tree** — the install/runtime sources quoted below are now Rust (`*.rs`), with no `*.zig` remaining under `src/`. (File paths and snippets here are pinned to commit [`df92f8f`][repo].)

---

## Overview

### What it solves

Bun's thesis is that the JavaScript toolchain — runtime, bundler, test runner, and **package manager** — is too slow and too fragmented, and that a single native binary can replace `node` + `npm`/`yarn`/`pnpm` + `webpack` + `jest` at a fraction of the latency. For the monorepo case specifically, `bun install` reads npm `workspaces` directly and installs the whole repo in one pass. From the [workspaces guide][ws-docs]:

> _"If package `b` depends on `a`, `bun install` will install your local `packages/a` directory into `node_modules` instead of downloading it from the npm registry. … If `a` and `b` share a common dependency, it will be hoisted to the root `node_modules` directory. This reduces redundant disk usage and minimizes 'dependency hell' issues associated with having multiple versions of a package installed simultaneously."_

So Bun occupies the same JS/TS package-manager niche as [npm](../npm/), [Yarn Berry](../yarn-berry/), and [pnpm](../pnpm/) — but with two differentiators. First, **raw speed**: the original binary lockfile let `bun install` benchmark, on the project's own numbers, _"33.28 ± 4.13 times faster than … npm install"_ ([text-lockfile blog][lock-blog]). Second, **a model toggle**: since `1.2`, Bun ships _both_ the classic hoisted installer and a pnpm-like **isolated** installer, and auto-selects between them based on whether the project is a workspace.

> [!NOTE]
> Like [pnpm](../pnpm/), [npm](../npm/), and [Yarn Berry](../yarn-berry/), Bun is a **package manager with a workspace + task layer**, not a build-graph engine. `bun run --filter` schedules **member scripts** in dependency order, but it has **no per-task input hashing, no build/test result cache, and no remote execution** (see [Caching & Remote Execution](#4-caching--remote-execution)). Teams wanting memoized, affected-only builds layer [Turborepo](../turborepo/) or [Nx](../nx/) on top — both of which support Bun as the underlying installer.

### Design philosophy

Three commitments shape Bun's monorepo surface, each restated as a column of the [trade-offs table](#key-design-decisions-and-trade-offs):

1. **Speed is the feature.** Bun is written in a systems language (Rust, after the 2026 rewrite from Zig) precisely so the package manager is I/O-bound, not CPU-bound; the binary lockfile, the global cache with hard-link/clonefile materialization, and a parallelized installer all serve the same end. The text lockfile was adopted in `1.2` only after the team was satisfied it kept _"`bun install` almost 30x faster than npm"_ ([text-lockfile blog][lock-blog]).
2. **Drop-in npm compatibility, then improve.** Bun reads the standard `package.json` `workspaces` field, the `workspace:` protocol, and `node_modules` — there is no proprietary manifest. Improvements (catalogs, isolated installs, the text lockfile) are added _on top of_ that compatible base so migration is `bun install` in an existing repo.
3. **Two isolation models, auto-selected.** Rather than force one `node_modules` layout, Bun offers `--linker hoisted` (flat, Yarn-style) and `--linker isolated` (symlinked, pnpm-style), defaulting to `auto`: **isolated for new workspaces, hoisted for single packages**. From the [isolated-installs docs][iso-docs]: _"Isolated installs create a non-hoisted dependency structure where packages can only access their explicitly declared dependencies."_

---

## How it works

### The install pipeline and the two linkers

`bun install` resolves the dependency graph into a lockfile, then **materializes** `node_modules` through one of two linkers, selected in `install_with_manager.rs`:

```rust
// src/install/PackageManager/install_with_manager.rs (abridged)
let mut linker = manager.options.node_linker;
loop {
    match linker {
        NodeLinker::Auto => match config_version {
            ConfigVersion::V0 => { linker = NodeLinker::Hoisted; continue; }   // legacy bun.lockb projects
            ConfigVersion::V1 => {                                             // text bun.lock projects
                if !load_result.migrated_from_npm()
                    && manager.lockfile.workspace_paths.len() > 0 {
                    linker = NodeLinker::Isolated; continue;                  // new workspace → pnpm-style
                }
                linker = NodeLinker::Hoisted; continue;                       // single package → flat
            }
        },
        NodeLinker::Hoisted  => break 'install_summary install_hoisted_packages(...)?,
        NodeLinker::Isolated => break 'install_summary install_isolated_packages(...)?,
    }
}
```

- **Hoisted** (`hoisted_install.rs`) builds one mostly-flat `node_modules` tree at the workspace root, deduplicating shared versions upward — the Yarn-Classic / npm model, and Bun's original behavior.
- **Isolated** (`isolated_install.rs`) builds a non-hoisted layout under `node_modules/.bun/<name>@<version>/`, with each package's `node_modules` containing **symlinks only to its declared dependencies** — the pnpm model. From the [docs][iso-docs]: _"All packages are installed in `node_modules/.bun/package@version/` directories"_ with _"Top-level `node_modules` contains symlinks pointing to the central store."_

The CLI flag is documented in `CommandLineArguments.rs` (`--linker <STR>` — _"one of 'isolated' or 'hoisted'"_); the default is `NodeLinker::Auto`.

### The isolated store and its content-addressed dedup key

The isolated installer's `Store` (`isolated_install/Store.rs`) is the most sophisticated piece. It does a DFS over the lockfile to build a tree of `Node`s, then computes a **content hash per entry** so that identical subtrees share one materialized copy in a global virtual store. From the source comment:

```rust
// src/install/isolated_install/Store.rs
/// Content hash of (package + sorted resolved dependency global-store keys),
/// used to key the global virtual store at `<cache>/links/<storepath>-<entry_hash>/`.
/// Two projects that resolve the same package to the same dependency closure
/// share one global-store entry; if a transitive dep version differs, the
/// hash differs and a new global-store entry is created. Computed after the
/// store is built (see `computeEntryHashes`).
pub entry_hash: u64,
```

Materialization into that store is done by clonefile / hard-link / copy (the `isolated_install/` directory carries `FileCloner`, `Hardlinker`, `FileCopier`, and `Symlinker`), so a package's bytes are written once and reflinked/hard-linked everywhere it is needed — the same disk-saving trick as [pnpm](../pnpm/)'s content-addressed store, here keyed by the **resolved dependency closure** so peer-dependency variants get distinct entries.

### The lockfile: binary `bun.lockb` → text `bun.lock`

Bun originally shipped a **binary** lockfile (`bun.lockb`) for parse speed. Since `1.2` the default is a **text** lockfile, `bun.lock` (`lockfile/bun.lock.rs`), a JSONC document whose version enum has since grown a `V2`:

```rust
// src/install/lockfile/bun.lock.rs
#[repr(u32)]
pub enum Version {
    V0 = 0,
    V1 = 1,   // fixed unnecessary listing of workspace dependencies
    V2 = 2,   // stricter parsing: integrity for off-registry tarballs, safe git/github tag paths
}
impl Version {
    pub const CURRENT: Version = Version::V2;
}
```

`V2` only tightens parse-time validation on otherwise-identical content (an already-written `v0`/`v1` lockfile keeps loading), so the on-disk shape readers see is unchanged. It is a **single, unified lockfile at the workspace root** covering every member. Its `"workspaces"` object keys each member by path (the root is the empty-string key `""`), and a top-level `"catalog"` / `"catalogs"` block records catalog versions. There is no per-member lockfile.

### The `workspace:` and `catalog:` protocols

Dependency-specifier parsing (`dependency.rs`) recognizes both protocols as first-class tags. `workspace:` is detected by prefix and resolved against in-repo members:

```rust
// src/install/dependency.rs — Tag::infer (abridged)
b'w' => { if dependency.starts_with(b"workspace:") { return Tag::Workspace; } }
b'c' => { if dependency.starts_with(b"catalog:")   { return Tag::Catalog;   } }
// ...
Tag::Workspace => {                              // value is the range after "workspace:"
    let mut input = dependency;
    if input.starts_with(b"workspace:") {
        input = &input[b"workspace:".len()..];
    }
    // ...
}
```

During development a `workspace:` dependency is satisfied by the local member directory (no registry download); on `bun publish` the specifier is rewritten to a concrete range — `workspace:*` → the member's exact version, `workspace:^`/`workspace:~` → the caret/tilde range ([workspaces guide][ws-docs]). The `catalog:` protocol (tag `Catalog = 9`) is parsed identically: `catalog:` references the default catalog and `catalog:<group>` a named one, both defined once in the **root** `package.json` (`"catalog"` and `"catalogs"` fields) and substituted at install time. This is Bun's [pnpm](../pnpm/)-style **workspace dependency registry** for killing version drift.

### Workspace discovery

`WorkspaceMap::process_names_array` (`lockfile/Package/WorkspaceMap.rs`) reads the root `package.json` `workspaces` field, globs each pattern to member directories, reads each member's `package.json` for its `name`/`version`, and builds the member map. Both manifest shapes are accepted — a bare array, or the Yarn-Classic object form `{"packages": [...]}` (handled in `filter_arg.rs`):

```rust
// src/runtime/cli/filter_arg.rs — get_candidate_package_patterns (abridged)
let json_array = match prop.expr.data {
    ExprData::EArray(arr) => arr,                              // "workspaces": [ ... ]
    ExprData::EObject(obj) => match (*obj).get(b"packages") { // "workspaces": { "packages": [ ... ] }
        Some(packages) => /* the inner EArray */ ...,
        None => break 'walk,
    },
    _ => break 'walk,
};
```

---

## The five dimensions

### 1. Workspace Declaration & Topology

Bun uses the **standard npm `workspaces` field** in the root `package.json` — no separate manifest (contrast [pnpm](../pnpm/)'s dedicated `pnpm-workspace.yaml`). The value is an array of **globs**, with **negative patterns** for exclusion ([workspaces guide][ws-docs]):

```json
{
  "name": "monorepo-root",
  "private": true,
  "workspaces": [
    "packages/**",
    "!packages/**/test/**",
    "!packages/**/template/**"
  ]
}
```

The Yarn-Classic object form `"workspaces": { "packages": ["packages/*"] }` is also accepted. Discovery is glob-based: `WorkspaceMap::process_names_array` expands each pattern to directories containing a `package.json`, reads each member's `name`, and the inter-member edges are derived from each member's `dependencies`/`devDependencies` that resolve to a workspace name. The root is typically a **virtual root** (`"private": true`, only orchestration scripts), though a root package may itself be a member. A `bun install` from anywhere in the tree walks up to the nearest `package.json` carrying `workspaces` to find the root (`get_candidate_package_patterns` ascends parent directories).

### 2. Dependency Handling & Isolation

This is where Bun is unusually flexible — it implements **both** mainstream isolation models and picks per project:

| Linker (`--linker`) | `node_modules` shape                                           | Phantom deps | Default when                          |
| ------------------- | -------------------------------------------------------------- | ------------ | ------------------------------------- |
| `hoisted`           | Flat, shared versions hoisted to root (npm/Yarn-Classic model) | Possible     | single packages; legacy `v0` lockfile |
| `isolated`          | `node_modules/.bun/<pkg>@<ver>/` + symlinks (pnpm model)       | Prevented    | new workspaces with `v1` `bun.lock`   |
| `auto` (default)    | Chooses `isolated` for new workspaces, else `hoisted`          | —            | always, unless overridden             |

- **Cross-member local refs** use the `workspace:` protocol; in dev the member is the on-disk directory (symlinked under isolated, linked-in-place under hoisted), rewritten to a real range on publish.
- **One unified root lockfile** (`bun.lock`) resolves all members together — no per-member lockfiles.
- **Isolated mode prevents phantom dependencies** exactly as pnpm does — _"Packages cannot accidentally import dependencies they haven't declared"_ ([isolated docs][iso-docs]) — because a member's `node_modules` contains only symlinks to what it declared. The architectural nuance Bun calls out: _"Bun uses symlinks in `node_modules` while pnpm uses a global store with symlinks"_ — Bun's central store lives under `node_modules/.bun/` per install, content-keyed by the resolved dependency closure (see [How it works](#the-isolated-store-and-its-content-addressed-dedup-key)).
- **Catalogs** (`catalog:` / `catalog:<group>`) centralize shared version ranges in the root manifest, the same anti-drift mechanism as pnpm's catalogs and [Gradle](../gradle/) version catalogs.

### 3. Task Orchestration & Scheduling

`bun run --filter <pattern> <script>` (and the shorthand `bun --filter …`) builds a **member-level DAG** and runs the matching script across members **in parallel by default, respecting dependency order**. From the [filter docs][filter-docs]: _"Bun will respect package dependency order when running scripts"_ — a dependent _"only start[s] running once"_ its workspace dependencies finish. The scheduler is in `filter_run.rs`:

```rust
// src/runtime/cli/filter_run.rs (abridged) — build the dependents graph
for handle in state.handles.iter_mut() {
    for name in &handle.config.deps {
        if let Some(pkgs) = map.get(&**name) {                // is the dep a workspace member?
            for &dep in pkgs {
                unsafe { (*dep).dependents.push(std::ptr::from_mut(handle)) };  // edge: dep → handle
                handle.remaining_dependencies += 1;           // Kahn-style in-degree
            }
        }
    }
}
// ... a process starts only when remaining_dependencies == 0; on exit it
// decrements each dependent's counter and starts any that reach zero.
for handle in state.handles.iter_mut() {
    if handle.remaining_dependencies == 0 { handle.start()?; }
}
```

It is a classic **Kahn topological execution**: each member-script `ProcessHandle` tracks `remaining_dependencies`; a script is spawned when that hits zero, and on exit it releases its `dependents`. Independent legs run concurrently (each spawned as a real OS process via `bun.spawn`), with a live multi-process terminal UI multiplexing their output.

**Cycle handling** is pragmatic — a DFS (`has_cycle`) checks the graph, and **if any cycle exists, dependency ordering is dropped entirely** (everything runs unordered):

```rust
// src/runtime/cli/filter_run.rs
if has_cycle_flag {                               // give up on ordering, run all at once
    for handle in state.handles.iter_mut() {
        handle.dependents.clear();
        handle.remaining_dependencies = 0;
    }
}
```

`pre`/`post` script ordering within a member is wired as extra edges _after_ the cycle check, so lifecycle hooks stay ordered even in a cyclic graph.

| Capability               | Bun answer                                                                                                     |
| ------------------------ | -------------------------------------------------------------------------------------------------------------- |
| Task/target DAG          | **Member** DAG (workspace → workspace) for the named script; not a fine-grained per-target graph               |
| Concurrent execution     | Yes — parallel by default; `--parallel` / `--sequential` flags; independent legs spawn together                |
| Ordering controls        | Topological by default (`remaining_dependencies` / Kahn); `--sequential` forces serial; `--elide-lines` for UI |
| Change detection         | **Not in `bun run --filter`** (no `[git-ref]` selector); **`bun test --changed`** does git-diff affected tests |
| Cross-script `dependsOn` | **No** explicit per-task `dependsOn`; ordering is inferred from the workspace dependency graph only            |

So, like [pnpm](../pnpm/), Bun schedules **packages**, not arbitrary tasks; there is no `turbo.json`-style `dependsOn` pipeline.

### 4. Caching & Remote Execution

**Install caching: strong. Task-result caching: none.**

- A **global package cache** (default `~/.bun/install/cache`) stores extracted package versions once; installs materialize from it via clonefile/hard-link rather than re-downloading or re-copying — the dominant install-time cache.
- The **isolated store** content-addresses each package by its resolved dependency closure, so identical subtrees share one on-disk entry (`computeEntryHashes`, [above](#the-isolated-store-and-its-content-addressed-dedup-key)).
- `bun.lock` gives reproducible resolution; `--frozen-lockfile` enforces it in CI.

There is **no build/test result cache, no per-task input hashing, and no remote execution / REAPI backend**. Bun never asks "have I already run this member's `test` for this input?" — that boundary is owned by [Turborepo](../turborepo/) (local + remote task cache), [Nx](../nx/) (computation cache + Nx Cloud), and the polyglot engines ([Bazel](../bazel/), [Buck2](../buck2/) with [BuildBuddy](../buildbuddy/)/[NativeLink](../nativelink/) remote execution). The nearest Bun comes to "skip unchanged work" is **`bun test --changed`**, which is _affected-test selection_, not memoization (next section).

### 5. CLI / UX Ergonomics

Bun's member-slicing centers on **one `--filter` flag** with a name-or-path glob grammar (`filter_arg.rs`, `FilterSet`):

- **Name patterns** match the `package.json` `name`: `--filter '*'` (all), `--filter 'pkg*'` (prefix), `--filter '@scope/app'` (exact). _"Name patterns select packages based on the package name"_ ([filter docs][filter-docs]).
- **Path patterns** start with `./` and match member directories: `--filter './packages/cli'`. _"Path patterns are specified by starting the pattern with `./`"_.
- **Negation** via `!`: `bun install --filter 'pkg-*' --filter '!pkg-c'`.
- `--filter '*'` / `--filter '**'` sets `match_all` (broadcast to every member).

```rust
// src/runtime/cli/filter_arg.rs — FilterSet::init classifies each pattern
let is_path = !filter_utf8.is_empty() && filter_utf8[0] == b'.';   // "./…" → path glob
// else → name glob; "*"/"**" → match_all
```

The command boundary:

- **Targeted** — `bun run --filter '@scope/app' build`, or `bun --filter './packages/*' dev`.
- **Broadcast** — `bun run --filter '*' test` runs the script in every member (topologically).
- **Install scoping** — `bun install --filter` limits which members' deps are installed.

> [!IMPORTANT]
> Unlike [pnpm](../pnpm/)'s `--filter` grammar, Bun's `bun run --filter` has **no dependents/dependencies closure operators** (`pkg...`, `...pkg`, `^`) and **no `[git-ref]` changed-since selector**. Affected-detection lives in a _different_ command — `bun test --changed` — which is git-aware and graph-aware (below). This is a real gap versus pnpm/Turborepo for "run X only on what changed and its dependents".

#### `bun test --changed` — git + module-graph affected detection

The one place Bun does true affected-detection is its test runner (`test/ChangedFilesFilter.rs`), vitest-compatible:

```rust
// src/runtime/cli/test/ChangedFilesFilter.rs (module header)
//! 1. Ask git for the set of changed files relative to HEAD (uncommitted,
//!    staged, and untracked) or relative to a user-supplied ref.
//! 2. Run the bundler over every discovered test file ... to produce the full
//!    parse graph (transitive imports) without linking or emitting code.
//! 3. Starting from each changed file ..., walk the reverse import edges to find
//!    every test entry point that can reach it.
```

So `bun test --changed` runs `git diff --name-only` (uncommitted/staged/untracked, or against `--changed <ref>`), builds the module import graph, and runs **only the tests whose transitive imports reach a changed file** — finer-grained (file-level, via the real import graph) than pnpm's member-level `[git-ref]` filter, but scoped to testing rather than general task selection.

---

## Strengths

- **Speed-first installs** — native (Rust) implementation, a global cache materialized by clonefile/hard-link, and the binary-then-text lockfile make `bun install` among the fastest in this survey (self-reported ~30x npm).
- **Two isolation models, auto-selected** — ships both a hoisted (Yarn-style) and an isolated (pnpm-style) `node_modules` linker, defaulting to isolated for new workspaces and hoisted for single packages.
- **Phantom-dependency prevention** — isolated mode enforces "import only what you declared," with a content-addressed store keyed by the resolved dependency closure.
- **Standard-manifest compatibility** — reads npm `workspaces`, `workspace:`, and `node_modules` directly; migrating an existing monorepo is just `bun install`.
- **Catalogs** — root-level `catalog:` / `catalogs:` central version registry abolishes cross-member version drift, as in pnpm/Gradle.
- **Parallel, topological task runner** — `bun run --filter` spawns member scripts concurrently in dependency order with a live multi-process UI; cycles degrade gracefully to unordered.
- **Unified text lockfile** — one human-reviewable `bun.lock` at the root for the whole workspace.
- **Graph-aware affected tests** — `bun test --changed` walks the real import graph from git-changed files.

## Weaknesses

- **No task-result cache, no remote execution** — Bun runs scripts; it does not memoize outputs. Teams add [Turborepo](../turborepo/)/[Nx](../nx/) for incrementality and remote caching — the single largest gap vs. dedicated orchestrators.
- **Thin `--filter` grammar for `run`** — no dependents/dependencies closure operators and no `[git-ref]` selector in `bun run --filter` (cf. [pnpm](../pnpm/)); affected-detection exists only for `bun test`.
- **Member-level DAG only** — orchestration granularity is the workspace member, not the individual task; no `dependsOn` pipeline.
- **Cycle handling is coarse** — any dependency cycle disables ordering for the _entire_ run rather than reporting/erroring on the offending edge.
- **Maturity / churn** — fast-moving (`workspace:`, catalogs, isolated installs, text lockfile all arrived across `1.1`→`1.2`); the just-completed Zig→Rust rewrite and the Anthropic acquisition add organizational flux.
- **Symlink friction (isolated mode)** — like pnpm, the symlinked layout can trip symlink-unaware tooling, Windows without Developer Mode, and some Docker/overlay filesystems; `--linker hoisted` is the escape hatch.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                        | Trade-off                                                                                                    |
| ----------------------------------------------------------------- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Native (Rust) implementation, global cache + clonefile/hard-link  | Make installs I/O-bound, not CPU-bound; ~30x npm on the project's own benchmarks | A large native codebase; a recent whole-codebase Zig→Rust rewrite; fewer external contributors than JS tools |
| Reuse npm `workspaces` / `package.json` (no proprietary manifest) | Zero-friction migration; reads existing monorepos as-is                          | Inherits npm's quirks; no place for richer first-class workspace metadata                                    |
| Two linkers (`hoisted` + `isolated`), `auto` default              | Offer both mainstream models; safe defaults (isolated for new workspaces)        | Two materialization code paths to maintain; behavior differs by project age / lockfile version               |
| Isolated store content-keyed by resolved dependency closure       | Dedup identical subtrees on disk; correct peer-dependency variants               | Symlink-layout friction on some platforms; more complex than a flat tree                                     |
| `catalog:` central version registry in root manifest              | One source of truth for shared ranges; abolishes drift                           | Another concept to learn; only as good as discipline in using it                                             |
| Single text lockfile `bun.lock` at the root (`v2`)                | Human-reviewable, diffable, one resolution for the whole workspace               | Slower to parse than the old binary `bun.lockb`; a single contention point for huge repos                    |
| Kahn topological `bun run --filter`, **no** task-result cache     | Correct build order + parallelism from the member graph, kept simple             | No memoization/affected-by-hash; needs Turborepo/Nx for incrementality and remote cache                      |
| Cycles disable ordering for the whole run                         | Always make progress; never deadlock on a bad graph                              | A single cycle silently degrades the entire run to unordered, masking a real configuration error             |
| Affected-detection only in `bun test --changed`                   | Graph-accurate (git diff + reverse import edges) where it matters most for CI    | Not available to `bun run --filter`; cannot bound general task runs to changed members                       |

---

## Sources

- [oven-sh/bun — GitHub repository][repo] (source for all quoted file paths; pinned to commit `df92f8f`, `1.4.0` working tree)
- [Bun documentation — bun.com/docs][docs]
- [Workspaces — bun.com/docs/install/workspaces][ws-docs]
- [Isolated installs — bun.com/docs/install/isolated][iso-docs]
- [Filter — bun.com/docs/cli/filter][filter-docs]
- [Lockfile — bun.com/docs/install/lockfile][lockfile-docs]
- [`src/install/PackageManager/install_with_manager.rs` — `auto` linker selection][install-mgr]
- [`src/install/isolated_install/Store.rs` — content-addressed isolated store][store]
- [`src/install/dependency.rs` — `workspace:` / `catalog:` protocol parsing][dependency]
- [`src/install/lockfile/Package/WorkspaceMap.rs` — workspace discovery][workspace-map]
- [`src/install/lockfile/bun.lock.rs` — text lockfile (`v2`), catalogs][bun-lock]
- [`src/runtime/cli/filter_run.rs` — Kahn topological member-script runner + cycle handling][filter-run]
- [`src/runtime/cli/filter_arg.rs` — `--filter` name/path glob grammar][filter-arg]
- [`src/runtime/cli/test/ChangedFilesFilter.rs` — `bun test --changed` affected tests][changed-filter]
- [Bun's new text-based lockfile (Bun blog)][lock-blog]
- [Bun 1.2 release notes][v12-blog]
- [Bun 1.0 release notes][v10-blog]
- [Bun is joining Anthropic (Bun blog)][anthropic]
- [Bun (software) — Wikipedia (history)][wiki]
- Sibling deep-dives: [npm](../npm/) · [Yarn Berry](../yarn-berry/) · [pnpm](../pnpm/) · [Composer](../composer/) · [Cargo](../cargo/) · [go-work](../go-work/) · [Gradle](../gradle/) · [Turborepo](../turborepo/) · [Nx](../nx/) · [Bazel](../bazel/) · [Buck2](../buck2/) · [BuildBuddy](../buildbuddy/) · [NativeLink](../nativelink/) · [comparison](../comparison.md) · [dub baseline](../dub-baseline.md) · [D landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/oven-sh/bun/tree/df92f8fd68ae58c9ef86e86822ff427672b7e797
[docs]: https://bun.com/docs
[ws-docs]: https://bun.com/docs/install/workspaces
[iso-docs]: https://bun.com/docs/install/isolated
[filter-docs]: https://bun.com/docs/cli/filter
[lockfile-docs]: https://bun.com/docs/install/lockfile
[install-mgr]: https://github.com/oven-sh/bun/blob/df92f8fd68ae58c9ef86e86822ff427672b7e797/src/install/PackageManager/install_with_manager.rs
[store]: https://github.com/oven-sh/bun/blob/df92f8fd68ae58c9ef86e86822ff427672b7e797/src/install/isolated_install/Store.rs
[dependency]: https://github.com/oven-sh/bun/blob/df92f8fd68ae58c9ef86e86822ff427672b7e797/src/install/dependency.rs
[workspace-map]: https://github.com/oven-sh/bun/blob/df92f8fd68ae58c9ef86e86822ff427672b7e797/src/install/lockfile/Package/WorkspaceMap.rs
[bun-lock]: https://github.com/oven-sh/bun/blob/df92f8fd68ae58c9ef86e86822ff427672b7e797/src/install/lockfile/bun.lock.rs
[filter-run]: https://github.com/oven-sh/bun/blob/df92f8fd68ae58c9ef86e86822ff427672b7e797/src/runtime/cli/filter_run.rs
[filter-arg]: https://github.com/oven-sh/bun/blob/df92f8fd68ae58c9ef86e86822ff427672b7e797/src/runtime/cli/filter_arg.rs
[changed-filter]: https://github.com/oven-sh/bun/blob/df92f8fd68ae58c9ef86e86822ff427672b7e797/src/runtime/cli/test/ChangedFilesFilter.rs
[lock-blog]: https://bun.com/blog/bun-lock-text-lockfile
[v12-blog]: https://bun.com/blog/bun-v1.2
[v10-blog]: https://bun.sh/blog/bun-v1.0
[anthropic]: https://bun.com/blog/bun-joins-anthropic
[rust-rewrite]: https://www.cosmicjs.com/blog/bun-rust-rewrite-javascript-runtime
[wiki]: https://en.wikipedia.org/wiki/Bun_(software)
[d-landscape]: ../../async-io/d-landscape.md
