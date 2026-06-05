# Cross-Tool Synthesis & the Dub Delta

The capstone of the monorepo-tooling survey. **Part 1** distils the 44 deep-dives and
the [concepts][concepts] vocabulary into a head-to-head comparison across the five axes
that decide a monorepo tool's character: **workspace declaration**, **dependency
isolation**, **task DAG & change detection**, **caching & remote execution**, and
**CLI/filter ergonomics**. From that synthesis it extracts **The Consensus Standard**
(the baseline shared across almost every modern ecosystem), maps the **Architectural
Trade-offs** between the tool families, and closes with **The Dub Delta** — an explicit
capability-by-capability gap analysis of [`dub`][dub-baseline] against the consensus,
the bridge into the milestoned [proposal][proposal].

> **Scope.** This is the _synthesis_ leaf of the survey. It assumes the per-tool
> mechanics ([deep-dives](./)) and the shared definitions ([concepts][concepts]) as
> given and cross-links rather than re-derives them. For `dub`'s current architecture
> read directly from the `dlang/dub` source tree, see the [baseline][dub-baseline]; for
> the concrete enhancement plan, see the [proposal][proposal]. The monorepo-tooling
> analogue of async-io's [comparison][async-comparison].

**Last reviewed:** June 5, 2026

---

## Part 1 — Cross-tool synthesis

### 1.1 The 44 tools at a glance

The master catalog, grouped by category. `DAG` = does the tool build a multi-member
task/target graph (vs. a single package's compile DAG). `Cache` summarises the deepest
tier reached: _dl_ (download/metadata only), _local_ (local task-output), _remote_
(shared/HTTP/gRPC cache), _REAPI_ (Remote Execution API). `XRef` = the local
cross-reference mechanism. The link cell points at each deep-dive.

#### Package managers (resolve & isolate; mostly no task DAG)

| Tool                       | Ecosystem | Workspace model                | DAG              | Cache       | Local cross-refs                  |
| -------------------------- | --------- | ------------------------------ | ---------------- | ----------- | --------------------------------- |
| [`npm`][npm]               | JS/TS     | Root-package (`workspaces`)    | no               | dl          | semver + symlink                  |
| [`yarn-berry`][yarn-berry] | JS/TS     | Root-package (`workspaces`)    | pkg (`foreach`)  | dl          | `workspace:`                      |
| [`pnpm`][pnpm]             | JS/TS     | Virtual (`pnpm-workspace`)     | pkg (`-r`)       | dl          | `workspace:` + `catalog:`         |
| [`bun`][bun]               | JS/TS     | Root/virtual (`workspaces`)    | pkg (`--filter`) | dl          | `workspace:` + `catalog:`         |
| [`uv`][uv]                 | Python    | Cargo-style (dual-mode)        | no               | local       | `{ workspace = true }`            |
| [`poetry`][poetry]         | Python    | None native                    | no               | dl          | `path` + `develop=true`           |
| [`hatch`][hatch]           | Python    | Env-scoped `workspace.members` | no               | local       | editable members + `path`         |
| [`cargo`][cargo]           | Rust      | `[workspace]` (dual-mode)      | action           | local       | `path` + `.workspace = true`      |
| [`go-work`][go-work]       | Go        | Virtual (`go.work`)            | no               | local       | implicit (MVS main modules)       |
| [`gradle`][gradle]         | JVM       | Multi-project + composite      | task             | remote      | `project(":path")` + substitution |
| [`maven`][maven]           | JVM       | Aggregator (`<modules>`)       | task (reactor)   | dl          | GAV + `ReactorReader`             |
| [`sbt`][sbt]               | Scala/JVM | Multi-project (Scala DSL)      | task             | REAPI (2.x) | `dependsOn(proj)`                 |
| [`mill`][mill]             | Scala/JVM | Module tree (Scala DSL)        | action           | local       | `moduleDeps`                      |
| [`composer`][composer]     | PHP       | None native                    | no               | dl          | `path` repos + `replace`          |

#### JS/TS task orchestrators (overlay a DAG + cache on a package manager's workspace)

| Tool                     | Ecosystem | Workspace model       | DAG       | Cache       | Local cross-refs        |
| ------------------------ | --------- | --------------------- | --------- | ----------- | ----------------------- |
| [`nx`][nx]               | JS/TS     | Inherited from PM     | task      | remote      | delegated to PM         |
| [`turborepo`][turborepo] | JS/TS     | Inherited from PM     | task      | remote      | delegated to PM         |
| [`lerna`][lerna]         | JS/TS     | Inherited from PM     | task (Nx) | remote (Nx) | delegated to PM         |
| [`rush`][rush]           | JS/TS     | Explicit `projects[]` | task      | remote      | `workspace:` (via pnpm) |
| [`lage`][lage]           | JS/TS     | Inherited from PM     | task      | remote      | delegated to PM         |
| [`wireit`][wireit]       | JS/TS     | Inherited from PM     | task      | remote (GH) | relative path + script  |

#### Polyglot build orchestrators (own the action graph, often down to REAPI)

| Tool               | Ecosystem | Workspace model          | DAG    | Cache  | Local cross-refs      |
| ------------------ | --------- | ------------------------ | ------ | ------ | --------------------- |
| [`bazel`][bazel]   | Polyglot  | FS auto-detect (`BUILD`) | action | REAPI  | `//path:target` label |
| [`buck2`][buck2]   | Polyglot  | FS auto-detect (`BUCK`)  | action | REAPI  | `cell//path:target`   |
| [`pants`][pants]   | Polyglot  | FS auto-detect (`BUILD`) | action | REAPI  | inferred from imports |
| [`please`][please] | Polyglot  | FS auto-detect (`BUILD`) | action | REAPI  | `//path:target` label |
| [`moon`][moon]     | Polyglot  | Root-anchored (`.moon/`) | action | remote | host PM + `dependsOn` |
| [`gn`][gn]         | Polyglot  | FS auto-detect (`.gn`)   | action | none   | `//path:target` label |

#### Container / CI-oriented (data-flow DAG over containerised steps)

| Tool                 | Ecosystem | Workspace model          | DAG       | Cache  | Local cross-refs       |
| -------------------- | --------- | ------------------------ | --------- | ------ | ---------------------- |
| [`dagger`][dagger]   | Container | Module graph             | data-flow | remote | `dagger install ./mod` |
| [`earthly`][earthly] | Container | Emergent `+target` graph | data-flow | remote | `+target` (cross-repo) |
| [`garden`][garden]   | Container | Stack Graph (scanned)    | data-flow | remote | action-to-action       |

#### Generic task runners (a `deps` DAG; no package model)

| Tool           | Ecosystem | Workspace model               | DAG  | Cache         | Local cross-refs           |
| -------------- | --------- | ----------------------------- | ---- | ------------- | -------------------------- |
| [`task`][task] | Polyglot  | `includes` namespaces         | task | local (skip)  | task edges                 |
| [`just`][just] | Polyglot  | `mod` namespace tree          | task | none          | task edges                 |
| [`mise`][mise] | Polyglot  | `config_roots` (experimental) | task | local (skip)  | task edges (`//path:task`) |
| [`make`][make] | Polyglot  | None (recursive `$(MAKE)`)    | task | local (mtime) | file edges                 |

#### Native build systems (one global target DAG; toolchain owns linkage)

| Tool             | Ecosystem | Workspace model           | DAG    | Cache               | Local cross-refs  |
| ---------------- | --------- | ------------------------- | ------ | ------------------- | ----------------- |
| [`meson`][meson] | Native    | `subprojects/` + `.wrap`  | target | local (mtime)       | `.wrap [provide]` |
| [`cmake`][cmake] | Native    | None (`add_subdirectory`) | target | none                | target name       |
| [`scons`][scons] | Native    | `SConscript` tree         | action | remote (`CacheDir`) | graph edges       |
| [`waf`][waf]     | Native    | `recurse()` tree          | action | remote (`wafcache`) | `use='A B'`       |
| [`ninja`][ninja] | Native    | Generated `build.ninja`   | action | local (mtime)       | file edges        |

#### Remote-execution backends (REAPI servers; no client-side workspace)

| Tool                       | Ecosystem | Workspace model | DAG           | Cache | Local cross-refs |
| -------------------------- | --------- | --------------- | ------------- | ----- | ---------------- |
| [`buildbuddy`][buildbuddy] | REAPI     | none (server)   | no (consumes) | REAPI | n/a              |
| [`buildbarn`][buildbarn]   | REAPI     | none (server)   | no (consumes) | REAPI | n/a              |
| [`nativelink`][nativelink] | REAPI     | none (server)   | no (consumes) | REAPI | n/a              |

#### Minimalist / research & polyglot glue

| Tool                       | Ecosystem | Workspace model            | DAG              | Cache                 | Local cross-refs     |
| -------------------------- | --------- | -------------------------- | ---------------- | --------------------- | -------------------- |
| [`redo`][redo]             | Research  | `.do` tree + `.redo` db    | action (dynamic) | local                 | `redo-ifchange ../x` |
| [`tup`][tup]               | Research  | `.tup` SQLite db           | action (file)    | none                  | `group`/`bin` edges  |
| [`nix-flakes`][nix-flakes] | Polyglot  | Flake graph (`flake.lock`) | derivation       | remote (binary cache) | relative `path:`     |

> [!NOTE]
> The seven category bands above are the same grouping the [umbrella index](./) carries
> in its sidebar. **[`dub`][dub-baseline]** is omitted from these tables because it is the
> _baseline_, not a surveyed peer — its row is the subject of [The Dub Delta](#the-dub-delta).

The single most useful lens on the catalog: **the five axes are largely orthogonal, and
a tool's category predicts where it sits on each.** Package managers max out _isolation_
and _lockfiles_ but stop before the _task DAG_; orchestrators inherit the workspace and
add a _DAG + cache_ but own no dependency resolution; the polyglot engines fuse all five
into one content-addressed action graph at the cost of adopting a foreign build language.
The sections below walk each axis.

---

### 1.2 Workspace declaration & topology

_How are members discovered, and is the root itself a buildable package?_ Three
discovery mechanisms and two root models (full taxonomy in [concepts §1][concepts]):

| Discovery                  | Root model              | Exemplars                                                                                                                     |
| -------------------------- | ----------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| **Glob array**             | root-package or virtual | [`cargo`][cargo], [`uv`][uv], [`pnpm`][pnpm], [`npm`][npm], [`bun`][bun], [`yarn-berry`][yarn-berry]                          |
| **Explicit array**         | aggregator/registry     | [`maven`][maven] (`<modules>`), [`go-work`][go-work] (`use`), [`rush`][rush] (`projects[]`), [`gradle`][gradle] (`include()`) |
| **Filesystem auto-detect** | implicit (tree)         | [`bazel`][bazel], [`buck2`][buck2], [`pants`][pants], [`please`][please], [`gn`][gn], [`nix-flakes`][nix-flakes]              |
| **Inherited from PM**      | none of its own         | [`nx`][nx], [`turborepo`][turborepo], [`lerna`][lerna], [`lage`][lage], [`wireit`][wireit], [`moon`][moon]                    |

The reference design is [`cargo`][cargo]'s **dual-mode** root: a `[workspace]` table
either sits inside a buildable crate (root-package form) or stands alone with no
`[package]` (virtual form), and members are glob-expanded path arrays _plus_ the
transitive closure of `path` dependencies. [`uv`][uv] ports this verbatim
(`[tool.uv.workspace]` with `members`/`exclude`, root-package or virtual), and
[`bun`][bun] supports both. [`pnpm`][pnpm] is purely virtual (a dedicated
`pnpm-workspace.yaml`), and [`go-work`][go-work] is virtual _and developer-local_ —
its `go.work` `use`-lists modules and is deliberately kept out of VCS.

At the opposite pole, the polyglot engines need **no member array at all**: every
directory with a marker file _is_ a package. [`bazel`][bazel] addresses each as a
`//`-rooted label and discovers topology from `deps` edges; [`pants`][pants] goes
furthest, inferring even the cross-references from import statements. The JS/TS
orchestrators are **parasitic** — [`lage`][lage], [`turborepo`][turborepo], and
[`nx`][nx] declare no members, reading the host package manager's `workspaces` globs
and overlaying only a task layer. Finally, several mainstream tools have **no native
workspace** ([`poetry`][poetry], [`composer`][composer], [`cmake`][cmake]):
multi-package trees are improvised from per-project manifests glued by relative paths —
exactly where [`dub`][dub-baseline]'s `subPackages` array sits today.

> [!NOTE]
> A workspace boundary is anchored by a **marker file** the CLI walks up to find:
> `Cargo.toml` with `[workspace]`, `pnpm-workspace.yaml`, `MODULE.bazel`, `.buckconfig`,
> `pants.toml`, `.plzconfig`, a `.gn` dotfile, or a `.tup`/`.redo` database. `dub` has no
> such workspace marker — only a root recipe enumerating sub-packages by path.

---

### 1.3 Dependency isolation & local cross-references

Two coupled questions: where do _third-party_ deps land on disk, and how does a member
reference a _sibling_ member's source ([concepts §2–3][concepts]).

**Isolation.** Four models, least to most isolated: **flat hoisting** (one root
`node_modules`, [`npm`][npm]; trades on phantom deps), **isolated symlinks**
([`pnpm`][pnpm]'s `node_modules/.pnpm` virtual store, [`rush`][rush]),
**content-addressed store** ([`yarn-berry`][yarn-berry] Plug'n'Play `.pnp.cjs`,
[`uv`][uv] `LinkMode::Clone` reflink, [`bun`][bun]), and **per-project vendoring**
([`composer`][composer] `vendor/`, [`poetry`][poetry]/[`hatch`][hatch] per-project
`.venv`). The REAPI engines ([`bazel`][bazel], [`buck2`][buck2]) and
[`nix-flakes`][nix-flakes] generalise the content-addressed store to _all_ inputs and
outputs — the same CAS underpins both their dependency model and their cache (§1.5). The
native runners ([`make`][make], [`ninja`][ninja], [`just`][just],
[`task`][task]) have **no isolation layer** at all: package placement is the native
toolchain's job — the model `dub`'s shared `$DUB_HOME/packages/` cache already follows.

**Local cross-references.** The defining monorepo capability — depending on a sibling's
source without publishing. Four mechanisms recur:

| Mechanism                 | Edge is…                                   | Exemplars                                                                                     |
| ------------------------- | ------------------------------------------ | --------------------------------------------------------------------------------------------- |
| **`workspace:` protocol** | local-first selector, rewritten on publish | [`yarn-berry`][yarn-berry], [`pnpm`][pnpm], [`bun`][bun], [`rush`][rush]                      |
| **Workspace-source flag** | `{ workspace = true }` / `dep.workspace`   | [`uv`][uv], [`cargo`][cargo]                                                                  |
| **Relative `path=` dep**  | a directory path to the sibling            | [`cargo`][cargo], [`composer`][composer], [`poetry`][poetry], **dub today**                   |
| **Typed project / label** | a project value or graph label             | [`sbt`][sbt] (`dependsOn`), [`mill`][mill] (`moduleDeps`), [`bazel`][bazel] (`//path:target`) |

[`yarn-berry`][yarn-berry] is the reference: a `workspace:*`/`^`/`~` selector links
to the member's source with `LinkType.SOFT` (symlinked, never fetched, not persisted to
the lockfile), then the `beforeWorkspacePacking` hook rewrites it to a real registry
range at publish. [`go-work`][go-work] makes the same idea **implicit** — every `use`d
module is a co-equal main module, so a cross-member import resolves to on-disk source
through MVS with no `replace`, version, or publish step. [`maven`][maven] has a unique
variant: a sibling is an ordinary `<dependency>` GAV, and the reactor's `ReactorReader`
intercepts resolution _within the build_ to serve the freshly-built `target/`.

A second layer is **version unification**: a central `[workspace.dependencies]`
([`cargo`][cargo]) or `catalog:` ([`pnpm`][pnpm], [`bun`][bun],
[`yarn-berry`][yarn-berry]) registry at the root, so every member writes
`react.workspace = true` / `"react": "catalog:"` and a shared upstream is pinned _once_.
[`cargo`][cargo] couples this with field inheritance (`version.workspace = true`,
`authors.workspace = true`). This is precisely the **fragmentation [`dub`][dub-baseline]
suffers**: each Sparkles member pins `expected`/`silly` independently, with nothing
reconciling them — the Milestone-2 target of the [proposal][proposal].

---

### 1.4 Task DAG & change detection

Dependency placement determines _what builds against what_; the task graph determines
_what runs in what order_. The pivotal distinction is **graph granularity**
([concepts §4][concepts]):

| Graph kind             | Nodes are…               | Exemplars                                                                                                                 |
| ---------------------- | ------------------------ | ------------------------------------------------------------------------------------------------------------------------- |
| **Package graph**      | whole members            | [`pnpm`][pnpm] `-r`, [`yarn-berry`][yarn-berry] `foreach -t`, [`bun`][bun] `--filter`                                     |
| **Task graph**         | `(package × task)` pairs | [`turborepo`][turborepo], [`nx`][nx], [`lage`][lage], [`wireit`][wireit], [`rush`][rush], [`maven`][maven] reactor        |
| **Action graph**       | single tool invocations  | [`cargo`][cargo] units, [`bazel`][bazel] (Skyframe), [`buck2`][buck2] (DICE), [`ninja`][ninja] file edges, [`mill`][mill] |
| **Implicit data-flow** | API/command calls        | [`dagger`][dagger] (BuildKit LLB), [`earthly`][earthly], [`garden`][garden] (Stack Graph)                                 |

A **package graph** topo-sorts whole members under a concurrency cap — [`pnpm`][pnpm]
chunks the project DAG via `graphSequencer` and runs it under `pLimit`-bounded
`--workspace-concurrency`; [`yarn-berry`][yarn-berry]'s `yarn workspaces foreach -t`
is the **direct inspiration for the dub proposal's loop**. A **task graph** crosses that
package graph with a per-task pipeline: [`lage`][lage]'s dep-specs `^build`
(dependencies' build), `^^transpile` (transitive), `pkg#task` (specific node), and bare
`build` (same package) are the canonical vocabulary, shared by [`turborepo`][turborepo]
(`dependsOn`) and [`nx`][nx]. An **action graph** dissolves packages entirely:
[`bazel`][bazel]'s action graph _is_ the task DAG, so a Skyframe rebuild touches only
the reverse-transitive closure of changed inputs.

A crucial gap: **most package managers stop before any task DAG.** `npm run
--workspaces` runs scripts sequentially in declared order — no topology, no parallelism —
which is the entire reason [`turborepo`][turborepo], [`nx`][nx], [`lage`][lage],
and [`wireit`][wireit] exist as overlays. [`uv`][uv], [`poetry`][poetry],
[`composer`][composer], and [`dub`][dub-baseline] own no member-level task graph at
all.

**Change detection** bounds work to what changed, in three increasingly precise
families:

| Mechanism                | Compares…                                 | Exemplars                                                                                                             |
| ------------------------ | ----------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| **mtime / timestamp**    | file mtimes vs. outputs                   | [`make`][make], [`ninja`][ninja], [`cmake`][cmake]/[`meson`][meson] (delegated)                                       |
| **Input hashing**        | content hash vs. stored fingerprint       | [`turborepo`][turborepo], [`nx`][nx] (`xxh3_64`), [`bazel`][bazel], [`gradle`][gradle], [`cargo`][cargo] fingerprints |
| **Affected / `--since`** | a VCS diff → changed members + dependents | [`lerna`][lerna], [`nx`][nx] affected, [`moon`][moon], [`please`][please] (`plz query changes --since`)               |

These compose: [`nx`][nx] layers `--since` affected detection over its `xxh3_64`
computation hash, and [`moon`][moon] pairs per-task content hashing with a Git-aware
tracker. **mtime detection is fragile on ephemeral CI** — [`make`][make]'s
incrementality "vanishes on a fresh checkout," the structural reason CI-heavy monorepos
migrate to input-hashing tools. `dub`'s build cache is content-addressed (a genuine
strength, §1.5) but per-package, with **no `--since` slicing** — the Milestone-4 target
of the [proposal][proposal].

---

### 1.5 Caching & remote execution

The caching ladder, deepest tier reached varying by _where_ and _what_
([concepts §5][concepts]):

| Tier                         | Reuses…                              | Exemplars                                                                                                                                                  |
| ---------------------------- | ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Download / metadata**      | fetched package archives only        | [`npm`][npm], [`composer`][composer], [`maven`][maven] (`~/.m2`), [`poetry`][poetry], [`go-work`][go-work], **dub** (`$DUB_HOME`)                          |
| **Local task-output**        | build/test outputs on this machine   | [`turborepo`][turborepo], [`nx`][nx], [`gradle`][gradle], [`mill`][mill], [`cargo`][cargo] `target/`, [`bazel`][bazel] `--disk_cache`                      |
| **Remote / shared**          | outputs across machines & CI         | [`turborepo`][turborepo] (HttpCache), [`nx`][nx] (Nx Cloud), [`gradle`][gradle] (HttpBuildCache), [`scons`][scons], [`waf`][waf], [`sbt`][sbt] 2.x         |
| **Remote execution (REAPI)** | runs the action _on a remote worker_ | [`bazel`][bazel], [`buck2`][buck2], [`pants`][pants], [`please`][please], [`buildbuddy`][buildbuddy], [`buildbarn`][buildbarn], [`nativelink`][nativelink] |

The crucial cliff is between **remote _cache_** and **remote _execution_**. Almost every
modern orchestrator now offers a remote cache that _replays_ a prior result (terminal
logs + output files) keyed by a content hash — [`turborepo`][turborepo],
[`nx`][nx], [`lage`][lage], [`rush`][rush], [`wireit`][wireit],
[`gradle`][gradle], [`moon`][moon]. Far fewer run the action _remotely_: **remote
execution** ships an action's inputs to a worker fleet and runs the compiler there, which
requires the action to be **hermetic** (fully described by its declared inputs). Only the
polyglot engines and the dedicated REAPI servers — [`buildbuddy`][buildbuddy],
[`buildbarn`][buildbarn], [`nativelink`][nativelink] — implement the **Remote
Execution API (REAPI v2)**: `ContentAddressableStorage` + `ByteStream` + `ActionCache` +
(optionally) `Execution`. These backends own _no workspace_; they only ever see the
hashed, post-analysis action graph a client emits. [`sbt`][sbt] 2.x is the rare
_language package manager_ with native REAPI-compatible task caching;
[`nix-flakes`][nix-flakes] reaches the deepest hermeticity in the catalog (a
content-addressed store keyed by the full build closure) but over Nix's own protocol,
orthogonal to REAPI.

This is **the largest single capability gap.** The language package managers
([`cargo`][cargo], [`uv`][uv], [`go-work`][go-work], [`npm`][npm],
[`pnpm`][pnpm], [`composer`][composer]) and [`dub`][dub-baseline] cache only
_downloads_ and _local incremental build state_; none has a shared task-output cache.
`dub` does have a real, content-addressed local build cache (its `computeBuildID` hashes
the full build inputs) — but it is local-only, per-package, and has no remote tier.

---

### 1.6 CLI & filter ergonomics

The developer command boundary — how to target _one_ member, _several_, or a subgraph:

| Ergonomic                 | Vocabulary                                   | Exemplars                                                                                                     |
| ------------------------- | -------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| **Per-package selector**  | `-p <pkg>` / `:pkg` / colon-label            | [`cargo`][cargo] (`-p`), [`bazel`][bazel] (`//path:target`), **dub** (`:subpkg`)                              |
| **Filter grammar**        | `--filter <pattern>` (name/path/glob)        | [`pnpm`][pnpm], [`turborepo`][turborepo], [`bun`][bun], [`nx`][nx], [`lerna`][lerna] (`--scope`)              |
| **Topological broadcast** | `foreach -t` / `-r` over all members         | [`yarn-berry`][yarn-berry], [`pnpm`][pnpm] (`-r`), [`maven`][maven] reactor, [`cargo`][cargo] (`--workspace`) |
| **Subgraph traversal**    | `--from` / dependents / `...pkg`             | [`pnpm`][pnpm] (`...pkg`), [`turborepo`][turborepo] (`...`), [`nx`][nx] (`affected`)                          |
| **Change-based slicing**  | `--since <ref>`                              | [`lerna`][lerna], [`nx`][nx], [`moon`][moon], [`please`][please]                                              |
| **Concurrency controls**  | `-j`/`--jobs`, `--parallel`, `--concurrency` | [`cargo`][cargo], [`ninja`][ninja], [`turborepo`][turborepo] (10), [`nx`][nx] (3)                             |

[`pnpm`][pnpm]'s `--filter` is the richest grammar — name globs, path globs, the
`...pkg` dependents/dependencies expansion, and `[<ref>]` git-range selectors all
compose. [`cargo`][cargo] offers the cleanest binary pair: `-p <member>` for one,
`--workspace` for all. The orchestrators add change-aware selection on top —
[`nx affected`][nx] and [`lerna --since`][lerna] compute the changed members plus
their impacted dependents from a git diff.

**[`dub`][dub-baseline]'s CLI surface is the minimal end of this axis.** It offers the
`:subpkg` selector and `--root <path>`, but **no filter/selection vocabulary for
multiple members**: no `--filter`, no repeatable `-p`, no `--recursive`/`--from`/`--since`,
no "all members" broadcast. The one fan-out flag, `upgrade -s`/`--sub-packages`, is a
one-off that re-enters `dub`'s single-root machinery N times. Multi-package work is
"loop it yourself" — exactly what the Sparkles `apps/ci` helper does.

---

## The Consensus Standard

Cutting across the 44 tools, a **baseline feature set** has emerged that almost every
modern monorepo ecosystem now ships (or that teams bolt on if the native tool lacks it).
A tool is "consensus-grade" when it offers all of:

1. **A declared workspace with glob member discovery** — a root manifest naming members
   by glob (`members = ["libs/*", "apps/*"]`), with a virtual (non-buildable) root
   option. Shipped natively by [`cargo`][cargo], [`uv`][uv], [`pnpm`][pnpm],
   [`bun`][bun], [`npm`][npm]/[`yarn-berry`][yarn-berry]. The polyglot engines
   substitute filesystem auto-detection ([`bazel`][bazel]).
2. **A `workspace:`-style local-first cross-reference** — depend on a sibling by name,
   resolved to its source in dev, rewritten to a real range on publish. The
   [`yarn-berry`][yarn-berry]/[`pnpm`][pnpm] `workspace:` protocol, [`cargo`][cargo]'s
   `dep.workspace = true`, [`go-work`][go-work]'s implicit MVS.
3. **A unified root lockfile** — one lock resolving all members together so a transitive
   dependency is pinned once, monorepo-wide. [`cargo`][cargo] (`Cargo.lock`),
   [`pnpm`][pnpm], [`uv`][uv], [`bun`][bun], [`yarn-berry`][yarn-berry].
4. **Central version unification** — a `[workspace.dependencies]` table or `catalog:`
   protocol eliminating per-member version drift. [`cargo`][cargo], [`pnpm`][pnpm],
   [`bun`][bun], [`yarn-berry`][yarn-berry].
5. **A topological task DAG with bounded concurrency** — build/test a member only after
   its workspace dependencies, running independent legs in parallel under a `-j`/`--concurrency`
   cap. [`yarn-berry`][yarn-berry] `foreach -t`, [`pnpm`][pnpm] `-r`,
   [`turborepo`][turborepo], [`nx`][nx], [`cargo`][cargo], [`gradle`][gradle],
   [`maven`][maven].
6. **A filter/selection vocabulary** — target one member, a glob of members, or a
   change-bounded subgraph (`--filter`, `-p`, `--since`). [`pnpm`][pnpm],
   [`turborepo`][turborepo], [`nx`][nx], [`cargo`][cargo], [`lerna`][lerna].
7. **Content-addressed task-output caching** — a cache key over source contents +
   command + env + upstream output hashes, replaying a prior result instead of
   recomputing. [`turborepo`][turborepo], [`nx`][nx], [`gradle`][gradle],
   [`mill`][mill], [`bazel`][bazel] — increasingly with a **remote** tier.

Items 1–6 are now table stakes for a serious monorepo; item 7's _local_ form is common,
its _remote_ form is the current frontier, and **REAPI remote execution** (the eighth,
aspirational tier) remains the exclusive province of the heavy polyglot engines. The
consensus tool lands in the **middle-to-right of every axis** in the
[concepts grid][concepts]: dual-mode root, glob discovery, a `workspace:` protocol,
a unified lockfile, a topological DAG with input-hash change detection, a filter grammar,
and at least a local content-addressed cache.

---

## Architectural Trade-offs

The catalog's tools cluster into seven families, each making a different bet about _what
to own_ and _what to delegate_. The central tension is **power vs. ceremony**: the more
of the five axes a tool owns natively, the more it imposes its own build language and the
less it cooperates with the host ecosystem.

| Family                         | Owns                                         | Delegates                                    | The bet                                                   |
| ------------------------------ | -------------------------------------------- | -------------------------------------------- | --------------------------------------------------------- |
| **Heavy polyglot engines**     | all five axes; action graph; REAPI           | the host language's idioms                   | hermeticity + scale are worth a foreign build language    |
| **Language-native workspaces** | workspace, lockfile, package DAG             | task pipelines, remote cache                 | the ecosystem's own model is enough; stay idiomatic       |
| **JS task orchestrators**      | task DAG, cache, change detection            | workspace + deps (to the package manager)    | overlay a graph on the PM you already use                 |
| **Minimalist task runners**    | a `deps` DAG, namespacing                    | everything else (packages, cache, isolation) | be a thin, universal command front-end                    |
| **Container / CI engines**     | a data-flow DAG, layer cache, hermetic steps | the package model                            | the container _is_ the unit of reproducibility            |
| **Remote-execution backends**  | the CAS + scheduler + worker fleet           | the entire workspace (to the client)         | be the server half of REAPI; own nothing above the action |
| **Polyglot glue**              | a content-hashed dependency/derivation graph | task pipelines                               | pin and wire what no single ecosystem tool can see whole  |

**Heavy polyglot action-graph engines** ([`bazel`][bazel], [`buck2`][buck2],
[`pants`][pants], [`please`][please]) own _everything_ down to the leaf compiler
invocation. They dissolve packages into a fine-grained action DAG, content-address every
action, and reach REAPI remote execution — [`bazel`][bazel]'s Skyframe rebuilds only
the reverse-transitive closure of changed inputs; [`buck2`][buck2]'s DICE graph gives
near-instant no-op rebuilds; [`pants`][pants] infers the graph from imports so there
is nothing to hand-wire. The price is a **foreign build language** (Starlark `BUILD`
files), a steep hermeticity discipline, and abandoning the host ecosystem's idioms. This
is the right bet at Google/Meta scale and the wrong one for a five-package library.

**Language-native workspaces** ([`cargo`][cargo], [`uv`][uv], [`pnpm`][pnpm],
[`yarn-berry`][yarn-berry], [`go-work`][go-work]) own the workspace, the unified
lockfile, and a package-level DAG, but **stop before user-defined task pipelines and
remote caching**. They stay maximally idiomatic — a Rust dev needs no new tool, just a
`[workspace]` table — at the cost of a coarse graph (whole-member, not per-action) and no
shared cache. [`cargo`][cargo] is the canonical example and **the most direct
precedent for the proposed `dub` workspace feature**: one root manifest, one
`Cargo.lock`, one shared `target/`, a topologically-scheduled fingerprint-cached build
DAG, dual-mode root, and `[workspace.dependencies]` inheritance. This is the family `dub`
should join.

**JS task orchestrators** ([`nx`][nx], [`turborepo`][turborepo], [`lage`][lage],
[`wireit`][wireit], [`rush`][rush]) are the **overlay** answer: they own the task
DAG, content-addressed cache, and change detection, but delegate the workspace and
dependency resolution to the package manager underneath. This exists precisely because
the JS package managers stopped at item 5 — `npm run --workspaces` has no topology, so an
entire tool category sprang up to add one. [`turborepo`][turborepo] is the lean
extreme (one `turbo.json`, reads the PM's lockfile, hashes every task); [`nx`][nx] the
maximal (project-graph inference, `affected`, Nx Cloud); [`wireit`][wireit] the most
minimal (a `wireit` block _inside_ the existing `package.json`, no new binary). The bet —
"overlay a graph on the PM you already use" — is itself a lesson for `dub`: the proposal
can add a topological loop _without_ rebuilding resolution, because `dub` already owns the
resolver.

**Minimalist task runners** ([`just`][just], [`task`][task], [`make`][make],
[`mise`][mise], [`redo`][redo], [`tup`][tup]) own a `deps` DAG and namespacing
and **deliberately delegate everything else**. They are universal polyglot front doors —
[`make`][make]'s 1976 mtime engine, [`task`][task]'s declarative YAML, [`just`][just]'s
parameterised recipes — with no package model, no isolation, and (mostly) no content
cache. [`redo`][redo] and [`tup`][tup] are the research-grade outliers: [`tup`][tup]
discovers the dependency graph by intercepting real syscalls and updates only the
change-reachable slice. These are what `dub` users reach for _today_ to glue members
together (the Sparkles `apps/ci` helper is this pattern in hand-written D).

**Container / CI engines** ([`dagger`][dagger], [`earthly`][earthly],
[`garden`][garden]) make the **container the unit of reproducibility**: every step
runs in a BuildKit container, the graph is an implicit data-flow DAG that caches and
parallelises automatically, and [`earthly`][earthly]'s `+target` references reach
across files and even git repositories. The bet trades fine-grained incrementality for
environmental hermeticity — and is orthogonal to `dub` (it would _wrap_ a `dub` build,
not replace it). Note [`earthly`][earthly] is now frozen/unmaintained (mid-2025).

**Remote-execution backends** ([`buildbuddy`][buildbuddy], [`buildbarn`][buildbarn],
[`nativelink`][nativelink]) own **only the server half** — a CAS + `ActionCache` +
scheduler + worker fleet speaking REAPI v2 — and nothing above the action. The workspace,
members, and dependency DAG live entirely on the client ([`bazel`][bazel]/[`buck2`][buck2]);
the backend only ever sees hashed, post-analysis actions. [`nativelink`][nativelink]'s
Nix-pinned Local Remote Execution makes local and remote toolchains bit-for-bit
identical. These are irrelevant to `dub` until it has a content-addressed _action_ graph
to feed them — a post-proposal horizon.

**Polyglot glue** ([`nix-flakes`][nix-flakes]) pins and wires what no single ecosystem
tool can see whole: each `flake.nix` is a content-hash-locked node, relative `path:`
inputs reference sibling flakes, and `flake.lock` pins the whole transitive DAG. Sparkles
_already_ uses this (the Nix flake, `nix/dub-lock.json`) as the layer _above_ `dub` — the
glue that does what `dub` cannot. The proposal's goal is to move workspace concerns _into_
`dub` so the Nix layer is reproducibility, not orchestration.

---

## The Dub Delta

Measuring [`dub`][dub-baseline] — read directly from the `dlang/dub` source at
`v1.42.0-beta.1` — against [The Consensus Standard](#the-consensus-standard) yields a
concrete, addressable gap. `dub` already owns the two _hard_ primitives a workspace needs
— a working dependency resolver and a solid content-addressed local build cache — but it
has **no organising concept above the single package**. A grep of the entire `dub` source
and docs trees for "workspace" or "monorepo" returns **zero matches**.

| Capability                       | Consensus (exemplar)                                                                          | Dub today ([baseline][dub-baseline])                          | The gap                                                                               |
| -------------------------------- | --------------------------------------------------------------------------------------------- | ------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| **Workspace declaration**        | `[workspace] members = ["libs/*"]`, virtual root ([`cargo`][cargo])                           | `subPackages` array; root is always a package; no globbing    | No `[workspace]` block, no member globbing, no virtual (non-buildable) root           |
| **Local cross-references**       | `workspace:` protocol; resolve-by-name ([`yarn-berry`][yarn-berry], [`go-work`][go-work])     | manual `path="../.."` + `:subpkg`, depth-sensitive            | No local-first protocol; hand-maintained relative paths that drift vs. published      |
| **Unified lockfile**             | one root lock for all members ([`cargo`][cargo], [`pnpm`][pnpm])                              | one `dub.selections.json` per member; no root lock            | Fragmented per-member lockfiles; version drift structurally possible                  |
| **Config / version inheritance** | `version.workspace = true`, `[workspace.dependencies]` ([`cargo`][cargo])                     | none (only the obscure `inheritable` selections flag)         | No metadata or dependency-version inheritance from a root                             |
| **Cross-member task DAG**        | topological `foreach -t` ([`yarn-berry`][yarn-berry]), `dependsOn` ([`turborepo`][turborepo]) | none; per-package verbs + bespoke `apps/ci` scripts           | No `dub build --workspace`; orchestration is uncoordinated external scripts           |
| **Filter / slicing**             | `--filter`, `-p`, `--recursive`, `--since` ([`pnpm`][pnpm], [`nx`][nx])                       | `:subpkg`, `--root`, one-off `upgrade -s`                     | No multi-member selection or change-based slicing                                     |
| **Change detection**             | input-hash + `--since` affected ([`nx`][nx], [`moon`][moon])                                  | content-addressed _per-package_ build cache, no `--since`     | No workspace-aware affected slicing                                                   |
| **Local caching**                | content-addressed task-output cache ([`turborepo`][turborepo])                                | content-addressed `computeBuildID` package cache (real, good) | Per-package, not workspace-aware; configs produce distinct ids → redundant recompiles |
| **Remote cache / execution**     | remote cache ([`turborepo`][turborepo]) → REAPI ([`bazel`][bazel])                            | none — local `$DUB_HOME` only                                 | No remote cache, no REAPI; CI cannot pull a teammate's artifacts                      |

The deficits cluster into **four addressable themes**, which are exactly the milestone
structure of the [proposal][proposal]:

1. **Structural workspace layout** — a `[workspace]` block (root-package _and_ virtual
   modes) with glob member discovery and a unified root `dub.selections.json`, borrowing
   the [`cargo`][cargo] model. _(Proposal Milestone 1.)_
2. **Config & dependency inheritance** — a `workspace:`-style local cross-reference
   protocol and a central `[workspace.dependencies]` registry, eliminating the
   depth-sensitive `path="../.."` wiring and version drift. _(Milestone 2, modelled on
   [`yarn-berry`][yarn-berry] + [`cargo`][cargo].)_
3. **Topological multi-member task routing** — a `dub build --workspace` /
   `dub test -p <member>` loop using `dub`'s existing resolver topology, with filter
   ergonomics and `-j`/`--parallel` concurrency, inspired by `yarn workspaces foreach`.
   _(Milestone 3.)_
4. **Change tracking & remote caching** — `--since <ref>` git-diff slicing and a
   workspace constraints engine, the [`nx`][nx]/[`lerna`][lerna] affected model.
   _(Milestone 4.)_

The honest summary: every multi-package capability in Sparkles today — looping tests
across the five members, keeping `expected`/`silly` aligned, building dependents after
their local libraries — is bolted on _outside_ `dub` (in `apps/ci`, in the Nix flake, in
hand-maintained `path=` strings and per-member lockfiles). `dub` has the resolver and the
cache; it lacks the **workspace**. The cross-tool evidence above shows the consensus
shape that workspace should take, and the [proposal][proposal] is the milestoned plan to
build it.

---

## Sources

- Cross-cutting concept doc: [concepts][concepts] (workspace topology, isolation, task
  DAG, caching, lockfiles — the layered vocabulary this synthesis re-cuts by axis).
- The system under improvement: [`dub` baseline][dub-baseline] (read from the
  `dlang/dub` source at `v1.42.0-beta.1`) and the [proposal][proposal] it bridges into.
- Per-tool primary sources are cited in each [deep-dive](./); this page synthesises the
  44-tool catalog.
- Structural model: async-io's [comparison][async-comparison] (the synthesis-doc
  pattern this imitates).

<!-- References -->

<!-- Sibling synthesis docs -->

[concepts]: ./concepts.md
[dub-baseline]: ./dub-baseline.md
[proposal]: ./dub-proposal.md

<!-- Cross-tree synthesis -->

[async-comparison]: ../async-io/comparison.md

<!-- Package managers -->

[npm]: ./npm/
[yarn-berry]: ./yarn-berry/
[pnpm]: ./pnpm/
[bun]: ./bun/
[uv]: ./uv/
[poetry]: ./poetry/
[hatch]: ./hatch/
[cargo]: ./cargo/
[go-work]: ./go-work/
[gradle]: ./gradle/
[maven]: ./maven/
[sbt]: ./sbt/
[mill]: ./mill/
[composer]: ./composer/

<!-- JS/TS task orchestrators -->

[nx]: ./nx/
[turborepo]: ./turborepo/
[lerna]: ./lerna/
[rush]: ./rush/
[lage]: ./lage/
[wireit]: ./wireit/

<!-- Polyglot build orchestrators -->

[bazel]: ./bazel/
[buck2]: ./buck2/
[pants]: ./pants/
[please]: ./please/
[moon]: ./moon/
[gn]: ./gn/

<!-- Container / CI-oriented -->

[dagger]: ./dagger/
[earthly]: ./earthly/
[garden]: ./garden/

<!-- Generic task runners -->

[task]: ./task/
[just]: ./just/
[mise]: ./mise/
[make]: ./make/

<!-- Native build systems -->

[meson]: ./meson/
[cmake]: ./cmake/
[scons]: ./scons/
[waf]: ./waf/
[ninja]: ./ninja/

<!-- Remote-execution backends -->

[buildbuddy]: ./buildbuddy/
[buildbarn]: ./buildbarn/
[nativelink]: ./nativelink/

<!-- Minimalist / research & polyglot glue -->

[redo]: ./redo/
[tup]: ./tup/
[nix-flakes]: ./nix-flakes/
