# Monorepo & Workspace Concepts: Shared Vocabulary

The cross-cutting vocabulary the rest of this survey leans on. Where a per-tool
[deep-dive](./) instantiates a feature in concrete config, this page defines the
_concept_ once — workspace topology, dependency isolation, local cross-references,
the task DAG, caching/remote execution, and lockfiles — and maps the 44 surveyed
tools onto each axis. Every term is grounded in a real tool; follow the cross-link
to its deep-dive for the mechanics.

> **Scope.** This is a _reference_ document, not a tool deep-dive. It is the spine
> for the cross-tool synthesis (consensus standard + "the dub delta") and the umbrella
> index (master catalog + taxonomies), and the monorepo-tooling analogue of async-io's
> [primitives][async-primitives] + [techniques][async-techniques]. The five research
> dimensions — _workspace declaration_, _dependency isolation_, _task orchestration_,
> _caching/remote execution_, _CLI ergonomics_ — are the spine of every deep-dive and
> the columns of the master catalog.

**Last reviewed:** June 5, 2026

---

## Why a layered vocabulary

A monorepo tool accretes capabilities in a predictable order, each tier a precondition
for the next: you cannot resolve a **local cross-reference** until you have **discovered
the members**; you cannot run a **topological task DAG** until you have a **package
graph** to topo-sort; you cannot **content-address a cache key** until you have
**declared a task's inputs**; and you cannot offer **remote execution** (REAPI) until
actions are **hermetic and content-addressed**.

The field stratifies into three bands the rest of this doc revisits: **package managers**
that resolve and isolate dependencies but own no task graph ([`npm`](./npm/), [`pnpm`](./pnpm/),
[`uv`](./uv/), [`cargo`](./cargo/), [`composer`](./composer/)); **task orchestrators**
that overlay a DAG and a cache onto a package manager's workspace ([`nx`](./nx/),
[`turborepo`](./turborepo/), [`lage`](./lage/), [`wireit`](./wireit/)); and **polyglot
build engines** that own the action graph, content-addressed cache, _and_ remote
execution down to the leaf compiler invocation ([`bazel`](./bazel/), [`buck2`](./buck2/),
[`pants`](./pants/), [`please`](./please/)).

## 1. Workspace topology

A **workspace** is a set of co-located packages ("members") built and resolved as a
unit. Two design choices define it: whether the root is _itself a buildable package_ or
a _stateless grouping manifest_, and _how members are discovered_.

### Root-package vs. virtual workspace

| Model                  | Root manifest is…                              | Exemplars                                                                                                                             |
| ---------------------- | ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| **Root-package**       | A real, buildable package _and_ the root       | [`cargo`](./cargo/) (`[workspace]` in a package's `Cargo.toml`), `npm`, [`yarn-berry`](./yarn-berry/), [`maven`](./maven/) aggregator |
| **Virtual workspace**  | A stateless grouping manifest, not a package   | [`cargo`](./cargo/) (virtual: root has only `[workspace]`), [`pnpm`](./pnpm/), [`uv`](./uv/) (virtual form), [`go-work`](./go-work/)  |
| **Either (dual-mode)** | Tool supports both forms                       | [`cargo`](./cargo/), [`uv`](./uv/), [`bun`](./bun/)                                                                                   |
| **No native root**     | No workspace manifest; emergent or per-project | [`poetry`](./poetry/), [`composer`](./composer/), [`cmake`](./cmake/), [`earthly`](./earthly/), the generic runners                   |

[`cargo`](./cargo/) is the canonical dual-mode design and the template the dub proposal
adopts: a **root-package workspace** is a functional crate that also carries a
`[workspace]` table, whereas a **virtual workspace** has only `[workspace]` and no
`[package]`. [`pnpm`](./pnpm/) is purely virtual; [`go-work`](./go-work/) is virtual and
_developer-local_ — its `go.work` `use`-lists modules for Minimal Version Selection
(MVS) and is kept out of VCS.

### Member discovery

How the tool _finds_ its members:

| Discovery mechanism                | How it works                                                          | Exemplars                                                                                                                                             |
| ---------------------------------- | --------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Explicit array**                 | Members hand-enumerated by path; no globbing                          | [`maven`](./maven/) (`<modules>`), [`go-work`](./go-work/) (`use`), [`rush`](./rush/) (`rush.json` `projects[]`), [`gradle`](./gradle/) (`include()`) |
| **Glob array**                     | Path globs (often with `!` negation) expand to members                | `npm`/[`yarn-berry`](./yarn-berry/)/[`bun`](./bun/) (`workspaces`), [`pnpm`](./pnpm/) (`packages:`), [`cargo`](./cargo/), [`uv`](./uv/)               |
| **Filesystem auto-detect**         | Every directory with a marker file is a package; topology is the tree | [`bazel`](./bazel/) (`BUILD` files), [`buck2`](./buck2/) (`BUCK`), [`pants`](./pants/)/[`please`](./please/), [`nix-flakes`](./nix-flakes/)           |
| **Inherited from package manager** | Tool reads the host PM's workspace; declares no members of its own    | [`nx`](./nx/), [`turborepo`](./turborepo/), [`lerna`](./lerna/), [`lage`](./lage/), [`wireit`](./wireit/), [`moon`](./moon/)                          |

The "inherited" row is the defining trait of the **JS/TS task orchestrators**:
[`lage`](./lage/) reads the host's `workspaces` globs via Microsoft's `workspace-tools`,
and [`turborepo`](./turborepo/)/[`nx`](./nx/) read `package.json#workspaces` (or
`pnpm-workspace.yaml`) and overlay only a task layer. The polyglot engines instead make
membership _implicit in the directory tree_ — [`bazel`](./bazel/) treats every directory
with a `BUILD` file as a package addressed by a `//`-rooted label, no `members` array.

> [!NOTE]
> A workspace boundary is anchored by a **marker file** the CLI walks up to find:
> `Cargo.toml` with `[workspace]` ([`cargo`](./cargo/)), `pnpm-workspace.yaml`
> ([`pnpm`](./pnpm/)), `MODULE.bazel`/`WORKSPACE` ([`bazel`](./bazel/)), `.buckconfig`
> ([`buck2`](./buck2/)), `pants.toml` ([`pants`](./pants/)), `.plzconfig`
> ([`please`](./please/)), a `.gn` dotfile ([`gn`](./gn/)), or a `.tup`/`.redo` database
> ([`tup`](./tup/), [`redo`](./redo/)).

## 2. Dependency isolation models

Once members are known, their _third-party_ dependencies must be placed on disk so
every member can import them without duplication or conflict. Four models dominate,
ordered from least to most isolated.

| Model                          | Mechanism                                                                       | Hazard it trades on                         | Exemplars                                                                                               |
| ------------------------------ | ------------------------------------------------------------------------------- | ------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| **Flat hoisting**              | One shared `node_modules` at the root; deps deduped/lifted to the top           | Phantom deps; nondeterministic flattening   | `npm`, [`yarn-berry`](./yarn-berry/) (`node-modules` linker), [`lerna`](./lerna/) (via PM)              |
| **Strict / isolated symlinks** | Per-package symlink tree; a package sees only its declared deps                 | Symlink-aware tooling required              | [`pnpm`](./pnpm/) (`node_modules/.pnpm` virtual store), [`rush`](./rush/)                               |
| **Content-addressed store**    | A single global CAS of packages; members hard-link/reflink or resolve in-memory | No on-disk `node_modules` tree at all (PnP) | [`yarn-berry`](./yarn-berry/) (PnP `.pnp.cjs`), [`pnpm`](./pnpm/) store, [`uv`](./uv/), [`bun`](./bun/) |
| **Per-project vendoring**      | Each project owns a private dependency directory                                | Byte duplication across projects            | [`composer`](./composer/) (`vendor/`), [`poetry`](./poetry/)/[`hatch`](./hatch/) (per-project `.venv`)  |

**Flat hoisting** (the original npm model) lifts every dependency into one root
`node_modules`, deduplicating versions but exposing **phantom dependencies** — a package
can `import` something it never declared because a _sibling_ pulled it to the top.
[`pnpm`](./pnpm/) kills this with an **isolated symlink tree**: real packages live in a
content-addressed store (`store/cafs`, layout `files/<hex[:2]>/<hex[2:]>`, hard-linked
into a per-project virtual store) and each package is symlinked _only_ its declared
deps. **Content-addressed virtual stores** push furthest — [`yarn-berry`](./yarn-berry/)'s
**Plug'n'Play** drops `node_modules` entirely (`.pnp.cjs` maps each `import` to a zip in
`.yarn/cache/`, "Zero-Install"), and [`uv`](./uv/) materializes from its global cache via
`LinkMode::Clone` (reflink/CoW) or `Hardlink`. The **REAPI engines** ([`bazel`](./bazel/),
[`buck2`](./buck2/)) and [`nix-flakes`](./nix-flakes/) generalize the content-addressed
store to _all_ build inputs and outputs — a CAS keyed by digest is the substrate of both
their dependency model and their cache (§5).

> [!NOTE]
> The native build systems and generic runners have _no_ dependency-isolation layer:
> [`make`](./make/), [`ninja`](./ninja/), [`cmake`](./cmake/), [`meson`](./meson/),
> [`scons`](./scons/), [`waf`](./waf/), [`just`](./just/), [`task`](./task/), and
> [`mise`](./mise/) delegate all package placement to the native toolchain; their
> "cross-references" (§3) are graph edges between files or targets, not isolated package
> trees.

## 3. Local cross-references

The defining monorepo capability: a member depending on a _sibling_ member's source,
resolved locally without publishing to a registry. Four mechanisms recur.

### The `workspace:` protocol family

A dependency selector meaning "resolve from the workspace, never the registry": in dev
it symlinks (or PnP-maps) to the member's source dir, and at **publish time** it is
rewritten to a concrete registry range.

| Form                | Selector example                  | Exemplars                                                                                                   |
| ------------------- | --------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `workspace:` proper | `"@acme/greeter": "workspace:*"`  | [`yarn-berry`](./yarn-berry/), [`pnpm`](./pnpm/), [`bun`](./bun/), [`rush`](./rush/) (via pnpm)             |
| Implicit/automatic  | any sibling import resolves local | [`go-work`](./go-work/) (every `use`d module is a main module), [`pants`](./pants/) (inferred from imports) |
| Workspace-source    | `{ workspace = true }`            | [`uv`](./uv/) (`[tool.uv.sources]`), [`cargo`](./cargo/) (`dep.workspace = true`)                           |

[`yarn-berry`](./yarn-berry/) is the reference: a `workspace:*`/`^`/`~` selector links
to the member's source with `LinkType.SOFT` (symlinked, never fetched, not persisted to
the lockfile), and the `beforeWorkspacePacking` hook rewrites it to a real range at
publish. [`go-work`](./go-work/) makes this _implicit_ — because every `use`d module is
a co-equal main module, a cross-member import resolves to on-disk source through MVS
with no `replace`, version, or publish step: the `workspace:` protocol without the syntax.

### Path dependencies, project references, and label edges

The lower-tech analogues — a relative filesystem path, a typed project value, or a graph
label — achieving the same local-first resolution without a selector protocol.

| Mechanism                   | Edge is…                                           | Exemplars                                                                                                                                                                           |
| --------------------------- | -------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Relative `path=` dep**    | A directory path to the sibling                    | [`cargo`](./cargo/) (`path = "../sibling"`), [`composer`](./composer/) (`path` repos), [`poetry`](./poetry/) (`path`, `develop=true`), and **dub today** ([baseline][dub-baseline]) |
| **Typed project reference** | A type-checked project _value_, not a path string  | [`sbt`](./sbt/) (`dependsOn(util)`), [`mill`](./mill/) (`moduleDeps = Seq(foo)`), [`gradle`](./gradle/) (`project(":path")`)                                                        |
| **Label edge**              | A `//path:target` graph label in one namespace     | [`bazel`](./bazel/), [`buck2`](./buck2/), [`please`](./please/), [`gn`](./gn/), [`pants`](./pants/)                                                                                 |
| **Coordinate interception** | A normal published coordinate, intercepted locally | [`maven`](./maven/) (`ReactorReader` serves the sibling's fresh `target/`), [`gradle`](./gradle/) composite-build substitution                                                      |

The **dub baseline** sits in the `path=` row: a Sparkles member depends on
`sparkles:core-cli` with `path="../.."`, the manual scheme the dub proposal replaces
with a `workspace:`-style protocol — see [`dub-baseline.md`][dub-baseline].
[`maven`](./maven/)'s **coordinate interception** is a distinct trick: a sibling is an
ordinary `<dependency>` GAV, but the reactor's `ReactorReader` (a
`MavenWorkspaceReader`) intercepts resolution _within the build_ to serve the
freshly-built `target/` output, falling back to `~/.m2` only outside a reactor build.

### Version unification (`catalog:` / `[workspace.dependencies]`)

A _central registry of versions_ at the root so members reference a shared upstream by
name, eliminating version drift. [`cargo`](./cargo/) is the archetype: a central
`[workspace.dependencies]` table consumed via `dep.workspace = true`, plus
`[workspace.package]` field inheritance (`version.workspace = true`,
`authors.workspace = true`). The JS ecosystem reached the same destination via the
Gradle-inspired **`catalog:`** protocol ([`pnpm`](./pnpm/), [`bun`](./bun/) `catalogs:`,
[`yarn-berry`](./yarn-berry/)): a root catalog pins one `react` and every member writes
`"react": "catalog:"`. Both are the dub proposal's Milestone-2 target
(`vibe-d.workspace = true`).

## 4. The task / target graph

Dependency placement (§2–3) determines _what builds against what_; the task graph
determines _what runs in what order_. The pivotal distinction is **package-graph vs.
action-graph**.

### Package-graph vs. action-graph

| Graph kind                 | Nodes are…                                | Granularity       | Exemplars                                                                                                                 |
| -------------------------- | ----------------------------------------- | ----------------- | ------------------------------------------------------------------------------------------------------------------------- |
| **Package graph**          | Whole members/projects                    | Coarse (per-pkg)  | [`pnpm`](./pnpm/) `-r`, [`yarn-berry`](./yarn-berry/) `foreach -t`, [`bun`](./bun/) `--filter`                            |
| **Task graph**             | `(package × task)` pairs                  | Medium            | [`turborepo`](./turborepo/), [`nx`](./nx/), [`lage`](./lage/), [`wireit`](./wireit/), [`rush`](./rush/)                   |
| **Action graph**           | Single compiler/tool invocations          | Fine (per-action) | [`bazel`](./bazel/) (Skyframe), [`buck2`](./buck2/) (DICE), [`cargo`](./cargo/) (units), [`ninja`](./ninja/) (file edges) |
| **Implicit data-flow DAG** | API/command calls; edges follow data flow | Fine (per-op)     | [`dagger`](./dagger/) (BuildKit LLB), [`earthly`](./earthly/), [`garden`](./garden/) (Stack Graph)                        |

A **package graph** sorts whole members ([`pnpm`](./pnpm/)'s `pnpm -r run` chunks the
project DAG via `graphSequencer` under `pLimit`-bounded `--workspace-concurrency`). A
**task graph** crosses that package graph with a per-task pipeline: [`lage`](./lage/)'s
"target graph" is the explicit `pipeline` _crossed_ with the package dependency graph,
where `^build` is "build of my dependencies", `^^transpile` is transitive, `pkg#task` is
a specific node, and bare `build` is same-package. An **action graph** dissolves packages
entirely: [`cargo`](./cargo/) schedules a DAG of "units" (one `rustc`/build-script/doc
invocation each), and [`bazel`](./bazel/)'s **action graph _is_ the task DAG**, so a
Skyframe rebuild touches only the reverse-transitive closure of changed inputs.

### Topological execution

The shared engine: topo-sort the graph, run independent legs concurrently under a job
cap, build a member's prerequisites before its dependents.

| Concept               | Definition                                                | Exemplars                                                                                                                                                   |
| --------------------- | --------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Topological order** | A node runs only after all its predecessors finish        | [`yarn-berry`](./yarn-berry/) `foreach -t`, [`maven`](./maven/) reactor, [`sbt`](./sbt/), [`cargo`](./cargo/) `JobQueue`                                    |
| **Concurrency cap**   | A bound on simultaneously-running legs                    | `-j/--jobs` ([`cargo`](./cargo/), [`mill`](./mill/), [`ninja`](./ninja/)), `--concurrency` 10 ([`turborepo`](./turborepo/)), `--parallel` 3 ([`nx`](./nx/)) |
| **Cycle detection**   | Reject or warn on a dependency cycle                      | [`maven`](./maven/) (`ProjectSorter` DFS), [`wireit`](./wireit/), [`yarn-berry`](./yarn-berry/) (`CYCLIC_DEPENDENCIES`)                                     |
| **Jobserver**         | GNU-Make-compatible token pool shared across nested tools | [`cargo`](./cargo/), [`make`](./make/), [`ninja`](./ninja/) (since 1.13), [`redo`](./redo/)                                                                 |

Most package managers stop _before_ this engine — `npm run --workspaces` runs scripts
sequentially with no topology, precisely why [`turborepo`](./turborepo/), [`nx`](./nx/),
[`lage`](./lage/), and [`wireit`](./wireit/) exist as overlays. [`yarn-berry`](./yarn-berry/)'s
`yarn workspaces foreach -t` is the direct inspiration for the dub proposal's loop.

### Change detection

Bounding work to what actually changed. Three families, increasingly precise.

| Mechanism                | What it compares                                           | Exemplars                                                                                                                                   |
| ------------------------ | ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| **mtime / timestamp**    | File modification times vs. outputs                        | [`make`](./make/), [`ninja`](./ninja/), [`cmake`](./cmake/)/[`meson`](./meson/) (delegated)                                                 |
| **Input hashing**        | A content hash of declared inputs vs. a stored fingerprint | [`turborepo`](./turborepo/), [`nx`](./nx/) (`xxh3_64`), [`bazel`](./bazel/), [`gradle`](./gradle/), [`cargo`](./cargo/) fingerprints        |
| **Affected / `--since`** | A VCS diff against a ref → changed members + dependents    | [`lerna`](./lerna/) (`--since`), [`nx`](./nx/) affected, [`moon`](./moon/) (Git-aware), [`please`](./please/) (`plz query changes --since`) |

These compose: [`moon`](./moon/) pairs per-task content hashing with a Git-aware
affected tracker, and [`nx`](./nx/) layers `--since` affected detection on top of its
`xxh3_64` computation hash.

> [!WARNING]
> **mtime-based detection is fragile on ephemeral CI.** [`make`](./make/)'s
> incrementality "vanishes on a fresh checkout" because every mtime is new, so it
> rebuilds everything — the structural reason CI-heavy monorepos migrate to
> input-hashing tools whose cache survives a clean clone (§5).

## 5. Caching

A cache reuses a prior result instead of recomputing it, varying by _where_ (local vs.
remote), _what_ (downloaded packages vs. task outputs), and _how keyed_
(content-addressed and hermetic, or not).

### The caching ladder

| Tier                          | Reuses…                              | Keyed by                          | Exemplars                                                                                                                                                                                               |
| ----------------------------- | ------------------------------------ | --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Download / metadata cache** | Fetched package archives only        | integrity digest                  | `npm` (`_cacache`), [`composer`](./composer/), [`maven`](./maven/) (`~/.m2`), [`poetry`](./poetry/), [`go-work`](./go-work/) (`$GOCACHE`)                                                               |
| **Local task-output cache**   | Build/test outputs on this machine   | input content hash                | [`turborepo`](./turborepo/) (`.turbo`), [`nx`](./nx/) (`.nx/cache`), [`gradle`](./gradle/), [`mill`](./mill/), [`bazel`](./bazel/) (`--disk_cache`)                                                     |
| **Remote / shared cache**     | Task outputs across machines & CI    | same hash, fetched over HTTP/gRPC | [`turborepo`](./turborepo/) (HttpCache), [`nx`](./nx/) (Nx Cloud), [`gradle`](./gradle/) (HttpBuildCache), [`scons`](./scons/) (`CacheDir`), [`waf`](./waf/) (`wafcache` → S3/GCS), [`sbt`](./sbt/) 2.x |
| **Remote execution (REAPI)**  | Runs the action _on a remote worker_ | action digest → CAS + ActionCache | [`bazel`](./bazel/), [`buck2`](./buck2/), [`pants`](./pants/), [`please`](./please/), [`buildbuddy`](./buildbuddy/), [`buildbarn`](./buildbarn/), [`nativelink`](./nativelink/)                         |

The crucial cliff is between **remote _cache_** and **remote _execution_**. Almost
every modern orchestrator now offers a remote cache that _replays_ a prior result
(terminal logs + output files) keyed by a content hash — [`turborepo`](./turborepo/),
[`nx`](./nx/), [`lage`](./lage/), [`rush`](./rush/), [`wireit`](./wireit/),
[`gradle`](./gradle/), [`moon`](./moon/). Far fewer run the action _remotely_:
**remote execution** ships the action's inputs to a worker fleet and runs the compiler
there, which requires the action to be **hermetic** (fully described by its declared
inputs, no ambient state).

### Cache keys and hermeticity

A cache key is sound only if it captures _every_ input that can change the output —
source-file contents ([`wireit`](./wireit/) SHA-256, [`nx`](./nx/) `xxh3_64`,
[`bazel`](./bazel/) Merkle CAS), command + args ([`turborepo`](./turborepo/),
[`rush`](./rush/)), env vars ([`lage`](./lage/)'s `environmentGlob`), the hashes of
upstream task outputs ([`lage`](./lage/), [`wireit`](./wireit/) transitive
fingerprints), and the toolchain/platform ([`bazel`](./bazel/), [`nix-flakes`](./nix-flakes/)
full closure). **Content-addressing** is the unifying technique: an action is reduced
to a digest (SHA-256/BLAKE3) over its complete input set, and the cache maps that digest
to the output blobs. [`bazel`](./bazel/), [`buck2`](./buck2/), and the dedicated REAPI
backends — [`buildbuddy`](./buildbuddy/), [`buildbarn`](./buildbarn/),
[`nativelink`](./nativelink/) — implement the **Remote Execution API (REAPI v2)**:
`ContentAddressableStorage` (CAS) + `ByteStream` + `ActionCache` + (optionally)
`Execution`. These backends own _no workspace_; they only ever see the hashed,
post-analysis action graph a client emits. [`nix-flakes`](./nix-flakes/) reaches the
deepest hermeticity in the catalog — a content-addressed store keyed by the _full build
closure_, with binary caches giving exact-environment hits — but over Nix's own
protocol, orthogonal to REAPI.

> [!IMPORTANT]
> **Caching is the largest single capability gap in the catalog.** The language
> package managers ([`cargo`](./cargo/), [`uv`](./uv/), [`go-work`](./go-work/), `npm`,
> [`pnpm`](./pnpm/), [`composer`](./composer/)) and **dub** ([baseline][dub-baseline])
> cache only _downloads_ and _local incremental build state_; none has a shared
> task-output cache. [`sbt`](./sbt/) 2.x is the rare language package manager with
> native REAPI-compatible task caching. The full dub gap analysis lives in the
> cross-tool synthesis.

## 6. Lockfiles

A lockfile pins the exact resolved version of every dependency for reproducible, offline
installs. The monorepo question is _scope_: one lockfile for the whole workspace, or one
per member.

| Model                        | Scope                                                | Exemplars                                                                                                                                                                                                             |
| ---------------------------- | ---------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Unified root lockfile**    | One lock resolving all members together              | [`pnpm`](./pnpm/) (`pnpm-lock.yaml`), [`yarn-berry`](./yarn-berry/) (`yarn.lock`), [`bun`](./bun/) (`bun.lock`), [`cargo`](./cargo/) (`Cargo.lock`), [`uv`](./uv/) (`uv.lock`), [`rush`](./rush/) (single by default) |
| **Per-project lockfile**     | Each member resolves and locks independently         | [`poetry`](./poetry/) (`poetry.lock`), [`hatch`](./hatch/), [`composer`](./composer/) (`composer.lock`)                                                                                                               |
| **Sharded / subspace locks** | Multiple locks _within_ one workspace                | [`rush`](./rush/) (subspaces), [`pnpm`](./pnpm/) (opt-in)                                                                                                                                                             |
| **No lockfile**              | Resolution is positional or content-hash, not pinned | [`go-work`](./go-work/) (MVS, no workspace lock), [`bazel`](./bazel/) (`MODULE.bazel.lock`), [`make`](./make/)/[`ninja`](./ninja/) (none)                                                                             |

**Resolution unification** is the prize of the unified model: [`uv`](./uv/) resolves
the whole workspace into one `uv.lock` against a single shared `.venv`, and
[`cargo`](./cargo/) produces one `Cargo.lock` for all members, so a transitive
dependency is pinned to _one_ version monorepo-wide — no two members can silently
disagree. The per-project model ([`poetry`](./poetry/), [`hatch`](./hatch/)) forgoes
this, allowing cross-member version drift; [`go-work`](./go-work/) is the outlier with
_no_ workspace lockfile at all, relying on MVS to pick the minimal satisfying version.

**Dub today** has a per-package `dub.selections.json` (with a Nix-format
`nix/dub-lock.json` shared across sub-packages); unifying these into a single root
selections file is the dub proposal's Milestone-1 deliverable — see
[`dub-baseline.md`][dub-baseline].

## Putting it together: the concept-to-tool grid

Each axis is a spectrum, minimal-to-maximal, with **dub today** at or near the minimal
end of most:

| Axis                 | Minimal end                                                | Maximal end                                                                |
| -------------------- | ---------------------------------------------------------- | -------------------------------------------------------------------------- |
| Workspace topology   | no root ([`poetry`](./poetry/), [`composer`](./composer/)) | dual-mode ([`cargo`](./cargo/), [`uv`](./uv/))                             |
| Member discovery     | explicit array ([`maven`](./maven/))                       | filesystem auto-detect ([`bazel`](./bazel/))                               |
| Dependency isolation | per-project vendoring ([`composer`](./composer/))          | content-addressed CAS ([`bazel`](./bazel/), [`nix-flakes`](./nix-flakes/)) |
| Local cross-refs     | relative `path=` (**dub**)                                 | `workspace:` + `catalog:` ([`pnpm`](./pnpm/), [`cargo`](./cargo/))         |
| Task graph           | none (`npm`, [`uv`](./uv/))                                | fine action graph ([`bazel`](./bazel/), [`buck2`](./buck2/))               |
| Change detection     | mtime ([`make`](./make/))                                  | input-hash + `--since` ([`nx`](./nx/), [`moon`](./moon/))                  |
| Caching              | download-only (`npm`, **dub**)                             | REAPI execution ([`bazel`](./bazel/), [`buck2`](./buck2/))                 |
| Lockfile             | per-project ([`poetry`](./poetry/))                        | unified root ([`cargo`](./cargo/), [`pnpm`](./pnpm/), [`uv`](./uv/))       |

The **consensus modern monorepo** — the subject of the cross-tool synthesis — lands in
the middle-to-right of every axis: a dual-mode root, glob discovery, an isolated or
content-addressed store, a `workspace:`/`catalog:` cross-reference protocol, a
topological task DAG with input-hash change detection, a remote cache, and a unified
root lockfile. **Dub today** ([baseline][dub-baseline]) sits at the _minimal_ end of
most axes; the dub proposal is the milestoned plan to close that delta, borrowing the
[`cargo`](./cargo/) workspace model, the [`yarn-berry`](./yarn-berry/) `workspace:`
protocol and topological loop, and the [`pnpm`](./pnpm/)/[`cargo`](./cargo/) unified
lockfile and version catalog.

## Sources

- Per-tool primary sources are cited in each [deep-dive](./); this page synthesizes
  the 44-tool catalog into shared definitions.
- Structural models: async-io's [primitives][async-primitives] and
  [techniques][async-techniques] (the layered-vocabulary pattern), and the
  [coroutines concepts][coroutines-concepts] doc.
- Cross-cutting sibling: [`dub-baseline.md`][dub-baseline] (the system under
  improvement). The umbrella index and the cross-tool synthesis build on these
  definitions.

<!-- References -->

<!-- Sibling synthesis docs -->

[dub-baseline]: ./dub-baseline.md

<!-- Cross-tree concept docs -->

[async-primitives]: ../async-io/primitives.md
[async-techniques]: ../async-io/techniques.md
[coroutines-concepts]: ../coroutines/concepts.md
