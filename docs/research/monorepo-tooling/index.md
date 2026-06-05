# Monorepo & Workspace Tooling

A breadth-first survey of **monorepo workspace features, task orchestration, and
polyglot build architectures** across 44 package managers, build systems, task
runners, and remote-execution backends — mapped against five recurring dimensions
(workspace declaration, dependency isolation, task DAG, caching/remote execution, and
filter ergonomics) to inform a phased, native workspace/monorepo proposal for `dub`,
the D package manager and build tool.

This is the master index for the monorepo-tooling research tree. Each row links to a
deep-dive that was written and fact-checked independently against the tool's own
source tree or official documentation; where this index summarizes a system, the
deep-dive is the source of truth.

This survey answers six questions:

1. **Vocabulary** — what is a workspace, a virtual root, a task DAG, dependency
   hoisting vs. a virtual store, content-addressed caching, REAPI, and the
   `workspace:`-protocol family of local cross-references? See [concepts].
2. **What `dub` does today** — how does the D package manager handle multi-package
   projects, sub-packages, `path=` overrides, and `dub.selections.json`, and where
   are the gaps? See the [`dub` baseline][dub-baseline].
3. **How 44 tools answer the five dimensions** — workspace declaration, dependency
   isolation, task orchestration, caching/remote execution, and CLI filter
   ergonomics. See the [master catalog](#master-catalog) and each linked deep-dive.
4. **What the field agrees on, and where it splits** — the consensus standard, the
   explicit-graph (Bazel/Buck2) vs. minimalist vs. language-lockfile (Cargo/uv)
   trade-offs, and "the `dub` delta." See the [comparison][comparison].
5. **When key capabilities landed** across ecosystems — workspaces, topological
   `foreach`, content-addressed caches, REAPI remote execution. See
   [Milestones](#milestones).
6. **What `dub` should adopt, and in what order** — the milestoned enhancement
   proposal, from layout primitives to git-ref change detection. See the
   [`dub` proposal][dub-proposal].

> **Scope note.** The 44 tools span ten categories — JS/TS and Python package
> managers, language build systems, JS/TS and polyglot orchestrators,
> container/CI engines, generic task runners, native build systems, REAPI backends,
> minimalist/research tools, and Nix as polyglot glue. `dub` itself is the system
> under improvement and is written up only in the [baseline][dub-baseline], not as a
> catalog row.

**Last reviewed:** June 5, 2026

---

## Master Catalog

One row per surveyed tool. **Task DAG?** answers whether the tool builds a graph of
_tasks_ (not merely a dependency graph) and schedules it concurrently in topological
order. **Caching** classifies the deepest tier reached: _none_ → _install/download
only_ → _local task-output_ → _remote cache_ → _REAPI remote execution_. **Local
cross-refs** names the mechanism a member uses to depend on a sibling without
publishing. **Sample?** flags whether a runnable `sample/` workspace ships with the
deep-dive.

| Tool               | Ecosystem      | Category               | Workspace model                                               | Task DAG? | Caching                          | Local cross-refs                        | Sample? | Link                       |
| ------------------ | -------------- | ---------------------- | ------------------------------------------------------------- | --------- | -------------------------------- | --------------------------------------- | :-----: | -------------------------- |
| **npm**            | JS/TS          | JS/TS package manager  | Root-package: `workspaces` glob in `package.json`             | No        | Install only (`_cacache`)        | Plain semver; symlink if satisfied      |   ✅    | [npm][npm]                 |
| **Yarn Berry**     | JS/TS          | JS/TS package manager  | Root-package: `workspaces` glob; `workspace:` protocol        | Yes       | Install only (`.yarn/cache`)     | `workspace:` protocol + `portal:`       |   ✅    | [Yarn Berry][yarn-berry]   |
| **pnpm**           | JS/TS          | JS/TS package manager  | Virtual root: `pnpm-workspace.yaml` globs                     | Yes (pkg) | Install only (CAS store)         | `workspace:` protocol + `catalog:`      |   ✅    | [pnpm][pnpm]               |
| **Bun**            | JS/TS          | JS/TS package manager  | Root/virtual: npm `workspaces` glob; `bun.lock`               | Yes (pkg) | Install only (clonefile store)   | `workspace:` protocol + `catalog:`      |    —    | [Bun][bun]                 |
| **uv**             | Python (Rust)  | Python package manager | Cargo-inspired `[tool.uv.workspace]`; one `uv.lock`, one venv | No        | Local CAS (`~/.cache/uv`)        | `[tool.uv.sources] {workspace = true}`  |   ✅    | [uv][uv]                   |
| **Poetry**         | Python         | Python package manager | None native; per-project `pyproject.toml` + plugins           | No        | Download only                    | Relative `path` dep (`develop = true`)  |    —    | [Poetry][poetry]           |
| **Hatch**          | Python         | Python package manager | Env-scoped `workspace.members` (1.16.0)                       | No        | Env + download                   | Editable `workspace.members` + `path`   |    —    | [Hatch][hatch]             |
| **Cargo**          | Rust           | Language build system  | Root `[workspace]`; root-package or virtual; one `Cargo.lock` | Yes       | Local (`target/` + fingerprints) | `path` + `[workspace.dependencies]`     |   ✅    | [Cargo][cargo]             |
| **Go (`go.work`)** | Go             | Language build system  | Virtual root `go.work` `use`-list of local modules (MVS)      | No        | Local CAS (`$GOCACHE`)           | Implicit: every `use`d module is local  |   ✅    | [Go `go.work`][go-work]    |
| **Gradle**         | JVM            | Language build system  | Multi-project `include()` + composite `includeBuild()`        | Yes       | Local + remote build cache       | `project(":path")` + substitution       |    —    | [Gradle][gradle]           |
| **Maven**          | JVM            | Language build system  | Aggregator `pom.xml` `<modules>` (the reactor)                | Yes       | Download (cache = extension)     | GAV coordinate via `ReactorReader`      |    —    | [Maven][maven]             |
| **sbt**            | Scala/JVM      | Language build system  | Multi-project `build.sbt`; `aggregate`/`dependsOn`            | Yes       | 2.x: REAPI ActionCache           | `dependsOn(project)` value reference    |    —    | [sbt][sbt]                 |
| **Mill**           | Scala/JVM      | Language build system  | Module tree of Scala `object`s; `moduleDeps`                  | Yes       | Local content-hash (universal)   | `moduleDeps` value reference            |    —    | [Mill][mill]               |
| **Composer**       | PHP            | Language build system  | None native; `path` repositories + `replace`                  | No        | Download only                    | `path` repository (symlink into vendor) |    —    | [Composer][composer]       |
| **Nx**             | JS/TS          | JS/TS orchestrator     | Inherited from package manager + inference plugins            | Yes       | Local + remote (Nx Cloud)        | Delegated to package-manager symlinks   |   ✅    | [Nx][nx]                   |
| **Turborepo**      | JS/TS          | JS/TS orchestrator     | Inherited; adds only `turbo.json` task layer                  | Yes       | Local + HTTP remote cache        | Package-manager `workspace:`/`*`        |   ✅    | [Turborepo][turborepo]     |
| **Lerna**          | JS/TS          | JS/TS orchestrator     | Inherited + optional `lerna.json` `packages` glob             | Yes (Nx)  | Inherited from Nx                | Delegated to package-manager symlinks   |    —    | [Lerna][lerna]             |
| **Rush**           | JS/TS          | JS/TS orchestrator     | Explicit `rush.json` `projects[]` registry                    | Yes       | Local + cloud + cobuilds         | Package-manager `workspace:` (pnpm)     |    —    | [Rush][rush]               |
| **Lage**           | JS/TS          | JS/TS orchestrator     | Parasitic: reads host package-manager workspaces              | Yes       | Local + remote (backfill)        | Host `workspace:` deps (edges only)     |    —    | [Lage][lage]               |
| **Wireit**         | JS/TS          | JS/TS orchestrator     | Inherited; `wireit` block inside `package.json`               | Yes       | Local + GitHub Actions cache     | Relative `../core:build` path+script    |    —    | [Wireit][wireit]           |
| **Bazel**          | Polyglot       | Polyglot orchestrator  | Single repo at `MODULE.bazel`; `//`-label packages            | Yes       | REAPI (cache + execution)        | `//path:target` label                   |   ✅    | [Bazel][bazel]             |
| **Buck2**          | Polyglot       | Polyglot orchestrator  | One project at `.buckconfig`; tree of cells                   | Yes       | REAPI-first (CAS + ActionCache)  | `cell//path:target` label               |    —    | [Buck2][buck2]             |
| **Pants**          | Polyglot       | Polyglot orchestrator  | Single repo at `pants.toml`; inferred from imports            | Yes       | Local LMDB + REAPI               | Inferred from `import` statements       |    —    | [Pants][pants]             |
| **Please**         | Polyglot       | Polyglot orchestrator  | Single repo at `.plzconfig`; `BUILD`-file packages            | Yes       | Local + HTTP + REAPI v2.1        | `//path:target` label                   |    —    | [Please][please]           |
| **moon**           | Polyglot       | Polyglot orchestrator  | Root `.moon/`; `moon.yml` id→path map / globs                 | Yes       | Local + REAPI v2 cache           | Host `workspace:*` + `dependsOn`        |   ✅    | [moon][moon]               |
| **GN + Ninja**     | Polyglot       | Polyglot orchestrator  | Single tree at `.gn`; `BUILD.gn` packages × toolchain         | Yes       | None native (`mtime` only)       | `//path:target` label                   |    —    | [GN + Ninja][gn]           |
| **Dagger**         | Polyglot       | Container / CI         | Module graph: per-component `dagger.json` `dependencies`      | Yes       | BuildKit CAS + `CacheVolume`     | `dagger install ./path` (same repo)     |    —    | [Dagger][dagger]           |
| **Earthly**        | Polyglot / CI  | Container / CI         | Emergent `+target` graph across `Earthfile`s                  | Yes       | BuildKit + registry remote cache | `+target` (file/dir/repo edges)         |    —    | [Earthly][earthly]         |
| **Garden**         | Polyglot / k8s | Container / CI         | Repo-wide Stack Graph of `*.garden.yml` actions               | Yes       | Version-hash + cluster caches    | `<kind>.<name>` action edges            |    —    | [Garden][garden]           |
| **Task (go-task)** | Go             | Generic task runner    | None native; root `Taskfile.yml` `includes`                   | Yes       | Local skip-only (`.task/`)       | None; `includes` + `deps` task edges    |    —    | [Task][task]               |
| **Just**           | Polyglot       | Generic task runner    | None native; `justfile` `mod` namespace tree                  | Yes       | None                             | None; recipe edges (`:` / `&&`)         |    —    | [Just][just]               |
| **mise**           | Polyglot       | Generic task runner    | Hierarchical `mise.toml`; opt-in monorepo mode                | Yes       | Local skip-only (`blake3`)       | None; `//libs/core:build` task edges    |    —    | [mise][mise]               |
| **Make**           | Polyglot       | Generic task runner    | None; one makefile or recursive `$(MAKE) -C`                  | Yes       | None (`mtime` only)              | None; file/order prerequisites          |    —    | [Make][make]               |
| **Meson**          | C/C++/native   | Native build system    | Root `meson.build` + `subprojects/` `.wrap` manifests         | Yes       | Ninja `mtime`/depfile only       | `.wrap` `[provide]` name mapping        |    —    | [Meson][meson]             |
| **CMake**          | C/C++/native   | Native build system    | None native; `add_subdirectory()` into one target graph       | Target    | None native (`mtime` backend)    | Target name in global namespace         |    —    | [CMake][cmake]             |
| **SCons**          | C/C++/native   | Native build system    | Single tree at `SConstruct`; `SConscript` hierarchy           | Yes       | Local + shared `CacheDir` (CAS)  | Graph edges + `Export()`/`Import()`     |    —    | [SCons][scons]             |
| **Waf**            | C/C++/native   | Native build system    | Single `wscript`; `ctx.recurse('sub')`                        | Yes       | Local hash + `wafcache` (S3/GCS) | `use='A B'` task-generator name         |    —    | [Waf][waf]                 |
| **Ninja**          | C/C++/native   | Native build system    | Machine-generated `build.ninja`; `subninja`/`include`         | Yes       | Local incremental only           | Graph edges (output path as input)      |    —    | [Ninja][ninja]             |
| **BuildBuddy**     | REAPI backend  | Remote execution       | None — server for a REAPI client                              | No (svc)  | REAPI v2 (cache + execution)     | N/A (`--remote_instance_name`)          |    —    | [BuildBuddy][buildbuddy]   |
| **Buildbarn**      | REAPI backend  | Remote execution       | None — server side of REAPI v2                                | No (svc)  | Full REAPI cache + execution     | N/A (shared CAS digests)                |    —    | [Buildbarn][buildbarn]     |
| **NativeLink**     | REAPI backend  | Remote execution       | None — REAPI v2 server, client-agnostic                       | No (svc)  | Full REAPI CAS + ActionCache     | N/A (content-addressed digests)         |    —    | [NativeLink][nativelink]   |
| **redo**           | Polyglot       | Minimalist / research  | None; tree of `.do` scripts + global `.redo` DB               | Yes       | Local incremental (`.redo`)      | N/A; `redo-ifchange ../lib/foo.o`       |    —    | [redo][redo]               |
| **tup**            | Polyglot       | Minimalist / research  | One tree at `.tup` SQLite DB; per-dir `Tupfile`s              | Yes       | None (avoid-work, not reuse)     | N/A; `group`/`bin` file-level edges     |    —    | [tup][tup]                 |
| **Nix (flakes)**   | Nix / polyglot | Polyglot glue          | Virtual graph of flakes; `flake.lock` pins the DAG            | Yes       | CAS store + binary caches        | Relative `path:./libs/core-cli`         |    —    | [Nix (flakes)][nix-flakes] |

> [!NOTE]
> "Task DAG? = No" does not mean "no graph at all": npm, uv, Poetry, Composer, and
> `go.work` all build a _dependency_ DAG for resolution, but expose no _task_ DAG —
> topological build/test is delegated to an external runner. "Yes (pkg)" marks
> package-level ordering (pnpm/Bun) without an intra-package `dependsOn` task graph.
> The REAPI backends own no client-side DAG at all; they schedule the leaf actions a
> client's DAG emits. See [concepts] for the task-DAG vs. dependency-DAG distinction.

### By category

The same 44 rows, grouped by the scope matrix's **Category** column (the grouping
carried into the VitePress sidebar).

| Category                    | Tools                                                                                                                     |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| **JS/TS package managers**  | [npm][npm], [Yarn Berry][yarn-berry], [pnpm][pnpm], [Bun][bun]                                                            |
| **Python package managers** | [uv][uv], [Poetry][poetry], [Hatch][hatch]                                                                                |
| **Language build systems**  | [Cargo][cargo], [Go `go.work`][go-work], [Gradle][gradle], [Maven][maven], [sbt][sbt], [Mill][mill], [Composer][composer] |
| **JS/TS orchestrators**     | [Nx][nx], [Turborepo][turborepo], [Lerna][lerna], [Rush][rush], [Lage][lage], [Wireit][wireit]                            |
| **Polyglot orchestrators**  | [Bazel][bazel], [Buck2][buck2], [Pants][pants], [Please][please], [moon][moon], [GN + Ninja][gn]                          |
| **Container / CI**          | [Dagger][dagger], [Earthly][earthly], [Garden][garden]                                                                    |
| **Generic task runners**    | [Task][task], [Just][just], [mise][mise], [Make][make]                                                                    |
| **Native build systems**    | [Meson][meson], [CMake][cmake], [SCons][scons], [Waf][waf], [Ninja][ninja]                                                |
| **Remote execution**        | [BuildBuddy][buildbuddy], [Buildbarn][buildbarn], [NativeLink][nativelink]                                                |
| **Minimalist / research**   | [redo][redo], [tup][tup]                                                                                                  |
| **Polyglot glue**           | [Nix (flakes)][nix-flakes]                                                                                                |

---

## Taxonomy

Four re-cuts of the same set, one axis each. The full treatment with verbatim quotes
lives in [concepts] and each deep-dive.

### By workspace declaration

_How are members discovered?_ The central split is whether the root manifest is
itself a buildable package (**root-package workspace**) or a stateless grouping node
(**virtual workspace**), and whether membership is **globbed**, **enumerated**, or
**inferred from the directory tree**. See [concepts § workspace topology][concepts].

| Declaration style               | Mechanism                                                            | Tools                                                                                                                        |
| ------------------------------- | -------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| **Root-package, glob**          | Root is a package; `workspaces`/`members` glob array                 | [npm][npm], [Yarn Berry][yarn-berry], [Bun][bun], [Cargo][cargo] (root-package mode), [uv][uv] (root-package mode)           |
| **Virtual root, glob**          | Stateless root groups members by glob                                | [pnpm][pnpm], [Cargo][cargo] (virtual mode), [uv][uv] (virtual mode), [Nix flakes][nix-flakes]                               |
| **Explicit enumeration**        | Members hand-listed (no glob)                                        | [Maven][maven], [Gradle][gradle], [Rush][rush], [Go `go.work`][go-work], [Task][task], [Just][just], [Meson][meson]          |
| **Value-reference tree**        | Members are language values wired by edges                           | [sbt][sbt], [Mill][mill], [SCons][scons], [Waf][waf]                                                                         |
| **Implicit (tree / inference)** | Whole directory tree is the workspace; deps from `import`s or labels | [Bazel][bazel], [Buck2][buck2], [Pants][pants], [Please][please], [GN + Ninja][gn], [Ninja][ninja], [tup][tup], [redo][redo] |
| **Inherited / parasitic**       | Reads the host package manager's workspace                           | [Nx][nx], [Turborepo][turborepo], [Lerna][lerna], [Lage][lage], [Wireit][wireit], [moon][moon]                               |
| **None native**                 | No workspace concept; assembled procedurally or by plugins           | [Poetry][poetry], [Hatch][hatch], [Composer][composer], [CMake][cmake], [Make][make], [mise][mise]                           |

### By dependency isolation & local cross-references

_How does a member depend on a sibling without publishing, and how is the dependency
tree laid out on disk?_ The `workspace:`-protocol family symlinks to source; the
label/coordinate family resolves through one global namespace; the path family is a
filesystem link. See [concepts § dependency isolation][concepts].

| Isolation / cross-ref model        | Mechanism                                                      | Tools                                                                                                                                  |
| ---------------------------------- | -------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| **`workspace:` protocol**          | Explicit local-first selector, rewritten to a range at publish | [Yarn Berry][yarn-berry], [pnpm][pnpm], [Bun][bun], [Rush][rush] (via pnpm)                                                            |
| **Implicit local resolution**      | Sibling resolves locally with no selector                      | [npm][npm] (symlink-if-satisfied), [Go `go.work`][go-work] (MVS), [Maven][maven] (`ReactorReader`)                                     |
| **Central registry + inheritance** | `[workspace.dependencies]` / catalog shared upstream pinning   | [Cargo][cargo], [pnpm][pnpm] (`catalog:`), [Bun][bun] (`catalog:`), [uv][uv] (inherited `[tool.uv.sources]`)                           |
| **Relative `path` link**           | Filesystem symlink/copy into the dep tree                      | [Composer][composer], [Poetry][poetry], [Hatch][hatch], [Dagger][dagger], [Nix flakes][nix-flakes]                                     |
| **Value / module reference**       | Sibling referenced by a typed language value                   | [sbt][sbt], [Mill][mill], [Gradle][gradle], [SCons][scons], [Waf][waf], [CMake][cmake]                                                 |
| **Global label namespace**         | One `//path:target` label space, no version/path               | [Bazel][bazel], [Buck2][buck2], [Please][please], [GN + Ninja][gn], [Pants][pants] (inferred)                                          |
| **Task / file edge only**          | No package edge; cross-refs are task or file prerequisites     | [Task][task], [Just][just], [mise][mise], [Make][make], [Ninja][ninja], [redo][redo], [tup][tup], [Earthly][earthly], [Garden][garden] |

### By orchestration model

_Does the tool build and schedule a task graph itself, or delegate it?_ See
[concepts § task DAG][concepts].

| Orchestration model                | Behavior                                                      | Tools                                                                                                                                                                                                                                            |
| ---------------------------------- | ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Full task DAG**                  | `(package × task)` graph, topologically scheduled, concurrent | [Cargo][cargo], [Gradle][gradle], [Maven][maven], [sbt][sbt], [Mill][mill], [Nx][nx], [Turborepo][turborepo], [Rush][rush], [Lage][lage], [Wireit][wireit], [Bazel][bazel], [Buck2][buck2], [Pants][pants], [Please][please], [moon][moon]       |
| **Package-level ordering only**    | Members ordered topologically; no intra-package task graph    | [pnpm][pnpm], [Bun][bun], [Yarn Berry][yarn-berry] (`foreach -t`)                                                                                                                                                                                |
| **File/recipe DAG (no package)**   | Real DAG over files or recipes, not packages                  | [Make][make], [Ninja][ninja], [GN + Ninja][gn], [Task][task], [Just][just], [mise][mise], [Meson][meson], [SCons][scons], [Waf][waf], [redo][redo], [tup][tup], [Dagger][dagger], [Earthly][earthly], [Garden][garden], [Nix flakes][nix-flakes] |
| **Delegated / none**               | No task DAG; defer to an external runner                      | [npm][npm], [uv][uv], [Poetry][poetry], [Hatch][hatch], [Composer][composer], [Go `go.work`][go-work], [CMake][cmake] (backend), [Lerna][lerna] (via Nx)                                                                                         |
| **Distributed scheduler (server)** | Schedules leaf actions a client's DAG emits                   | [BuildBuddy][buildbuddy], [Buildbarn][buildbarn], [NativeLink][nativelink]                                                                                                                                                                       |

### By caching & remote execution

_How deep does reuse go?_ The tiers run _none_ → _install/download only_ → _local
task-output cache_ → _shared/remote cache_ → _REAPI remote execution_. The REAPI
(Remote Execution API) line is the field's high-water mark; only a handful of
language tools reach it natively. See [concepts § caching and REAPI][concepts].

| Caching tier                    | What is reused                                                   | Tools                                                                                                                                                                                           |
| ------------------------------- | ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **None / `mtime` only**         | Nothing portable; incrementality dies on fresh CI checkout       | [Just][just], [Make][make], [CMake][cmake], [Ninja][ninja] (incremental only), [GN + Ninja][gn], [Meson][meson], [tup][tup]                                                                     |
| **Install / download only**     | Package archives + lockfile reproducibility                      | [npm][npm], [Yarn Berry][yarn-berry], [pnpm][pnpm], [Bun][bun], [Poetry][poetry], [Hatch][hatch], [Composer][composer], [Maven][maven] (core)                                                   |
| **Local content-addressed**     | Build/test outputs keyed by input hash, single machine           | [uv][uv], [Cargo][cargo], [Go `go.work`][go-work], [Mill][mill], [Task][task], [mise][mise], [redo][redo]                                                                                       |
| **Local + shared/remote cache** | Output reuse across machines/CI (HTTP/cloud)                     | [Gradle][gradle], [Nx][nx], [Turborepo][turborepo], [Rush][rush], [Lage][lage], [Wireit][wireit], [SCons][scons], [Waf][waf], [Nix flakes][nix-flakes], [Garden][garden], [Earthly][earthly]    |
| **REAPI (cache + remote exec)** | Content-addressed actions cached _and executed_ on a remote farm | [Bazel][bazel], [Buck2][buck2], [Pants][pants], [Please][please], [moon][moon] (cache only), [sbt][sbt] (2.x cache), [BuildBuddy][buildbuddy], [Buildbarn][buildbarn], [NativeLink][nativelink] |

> [!NOTE]
> `moon` and `sbt` 2.x speak REAPI for **caching** but do not perform remote
> _execution_; they are listed in the REAPI row because they share the protocol and
> CAS format. The three REAPI backends are pure servers — they provide the cache and
> execution surface for the orchestrators above them.

---

## Milestones

A high-confidence chronology of when each capability — native workspaces, topological
`foreach`, content-addressed task caching, and REAPI remote execution — landed in
each ecosystem. Dates are first stable/GA release unless noted; entries marked `~`
are approximate.

| Date     | Workspace / monorepo milestone                                                                 | Caching / remote-execution milestone                                              |
| -------- | ---------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| 1976     | **Make** — file-`mtime` target/prerequisite DAG; the universal front door                      | —                                                                                 |
| ~2003    | **Maven 2** — the multi-module **reactor**; aggregator `pom.xml` `<modules>`                   | `~/.m2` shared download repository                                                |
| ~2006    | **Bazel** ancestor **Blaze** in production at Google (content-addressed action graph)          | Internal content-addressed action cache                                           |
| 2008     | **SCons** content-hash build signatures; shared `CacheDir`                                     | Shared NFS derived-file cache (content-addressed)                                 |
| ~2008    | **Gradle** 0.x multi-project builds (`include()`)                                              | —                                                                                 |
| 2010     | **Ninja** released (Chromium); **GN** generator later pairs with it                            | Local incremental (`.ninja_log`)                                                  |
| 2011     | **Cargo** ships with Rust 1.0 lineage (single-crate first)                                     | Local `target/` build cache                                                       |
| 2015     | **Bazel** open-sourced (Mar 2015); **sbt** multi-project builds mature                         | Bazel local action cache                                                          |
| 2016     | **Lerna** 2.x popularizes JS monorepos; **Bazel remote cache** (gRPC) lands                    | **Bazel remote cache** over gRPC (the proto-**REAPI**)                            |
| 2017     | **Yarn (classic) workspaces** (`workspaces` field, Yarn 1.0, Sep 2017)                         | **Bazel Remote Execution API (REAPI) v2** stabilizes; Buildbarn/BuildGrid emerge  |
| 2018     | **npm 7 workspaces** in development; **pnpm** workspace + `workspace:` protocol                | **Gradle build cache** GA (local + remote)                                        |
| 2019     | **Cargo `[workspace]`** mature (virtual + root-package); **Yarn Berry (v2)** + PnP + `foreach` | **Bazel** RBE on Google Cloud; **BuildBuddy** founded                             |
| 2020     | **Turborepo** released (acquired by Vercel Dec 2021); **Nx** task graph + affected             | **Turborepo / Nx** content-addressed task cache + remote cache                    |
| Mar 2021 | **npm 7** ships **workspaces** GA (Node 15/16); **Buck2** in development at Meta               | **Nx Cloud** distributed cache; **NativeLink** (Rust REAPI) development           |
| 2022     | **Bun** released (`workspaces` support); **Rush** subspaces; **Wireit** (Google) released      | **Wireit** SHA-256 fingerprint cache; **Lage** remote backfill cache              |
| Mar 2022 | **Go 1.18** — **`go.work`** workspace mode (first-party multi-module)                          | `$GOCACHE` content-addressed (already present); `GOCACHEPROG` shim later          |
| 2023     | **Buck2 open-sourced** (Meta, Apr 2023); **moon** + **Pants 2.x** dependency inference         | **Buck2** REAPI-first; **Pants** local LMDB + REAPI; **moon** REAPI cache         |
| Feb 2024 | **uv** released (Astral); **uv workspaces** (Cargo-inspired) shortly after                     | **uv** local content-addressed cache; **Go 1.24** stabilizes `GOCACHEPROG` (2025) |
| ~2025    | **Hatch** `workspace.members` (1.16.0); **Earthly** frozen/unmaintained (mid-2025)             | **Earthly** Satellites + auto-skip cloud cache shut down (Jul 16, 2025)           |
| Jun 2026 | **sbt 2.x** RC — automatic content-addressed `ActionCache`; `dub` workspace proposal authored  | **sbt 2.x** Bazel-compatible **REAPI** remote cache (RC)                          |

> [!WARNING]
> Several dates are approximate (`~`) where a capability shipped incrementally
> (Gradle multi-project builds, Cargo workspaces, npm workspaces across 7.x point
> releases) or where the exact public-release date is contested. The first-party
> sources for each are in the linked deep-dive; this table optimizes for "which
> ecosystem reached this capability first," not point-release precision.

---

## Quick Navigation

### Suggested reading paths

- **"Give me the vocabulary first."** [concepts] → [comparison] → one
  language-native deep-dive ([Cargo][cargo] or [pnpm][pnpm]).
- **"I'm designing `dub` workspaces."** [`dub` baseline][dub-baseline] →
  [comparison] (the "`dub` delta") → [`dub` proposal][dub-proposal]. Cross-reference
  [Cargo][cargo] (virtual roots, `[workspace.dependencies]`, fingerprint cache) and
  [Yarn Berry][yarn-berry] (`workspace:` protocol, `foreach -t` topological loop) —
  the two structural precedents the proposal builds on.
- **"I want the orchestrator landscape."** [Nx][nx] → [Turborepo][turborepo] →
  [Bazel][bazel] → [Buck2][buck2] → [comparison].
- **"I care about caching and remote execution."** [comparison] (caching tiers) →
  [Bazel][bazel] → [BuildBuddy][buildbuddy] / [Buildbarn][buildbarn] /
  [NativeLink][nativelink] (the REAPI backends).
- **"I want the minimal end of the spectrum."** [Make][make] → [Ninja][ninja] →
  [redo][redo] → [tup][tup].

### Concepts & synthesis

- **[Concepts & vocabulary][concepts]** — workspace topology (root-package vs.
  virtual), dependency isolation (hoisting / symlink / virtual store), the task DAG
  and change detection, content-addressed caching + REAPI, the `workspace:`-protocol
  family.
- **[`dub` baseline][dub-baseline]** — the system under improvement: how `dub`
  handles sub-packages, `path=` overrides, and `dub.selections.json` today, and where
  the gaps are.
- **[Comparison][comparison]** — the consensus standard, the architectural
  trade-offs (explicit-graph vs. minimalist vs. language-lockfile), and the "`dub`
  delta" that bridges into the proposal.
- **[`dub` proposal][dub-proposal]** — the milestoned enhancement plan: layout
  primitives → metadata inheritance → topological task routing → git-ref change
  detection.

---

## Library deep-dives

One line per tool. Each links to its `<slug>/` deep-dive.

| Tool                       | One-line                                                                                                                                |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| [npm][npm]                 | Node.js's default package manager: a `workspaces` glob array symlinks members; no `workspace:` protocol, no task DAG, no caching.       |
| [Yarn Berry][yarn-berry]   | TypeScript rewrite of Yarn: `workspace:` protocol, Plug'n'Play, and `yarn workspaces foreach` topological runner — most complete.       |
| [pnpm][pnpm]               | Content-addressed store + strict symlinked `node_modules`; `pnpm-workspace.yaml`, `workspace:` protocol, catalogs, recursive runner.    |
| [Bun][bun]                 | Speed-first all-in-one toolkit: reads npm `workspaces`, hoisted-or-isolated `node_modules`, parallel dependency-ordered runner.         |
| [uv][uv]                   | Rust-built Python manager: Cargo-inspired workspaces, one shared `uv.lock`, one venv, local CAS — but no task orchestration.            |
| [Poetry][poetry]           | PubGrub-resolved `pyproject.toml` manager with no native workspace; monorepos improvised from `path` deps and plugins.                  |
| [Hatch][hatch]             | PyPA project manager of isolated matrix environments; new per-env `workspace.members` editable-installs locals, no shared lock.         |
| [Cargo][cargo]             | Rust's `[workspace]`: one root manifest, one `Cargo.lock`, one `target/`, a fingerprint-cached build DAG — the canonical precedent.     |
| [Go `go.work`][go-work]    | Go's first-party multi-module workspace: `use`-listed local modules cross-import via MVS; no member task DAG, no unified lockfile.      |
| [Gradle][gradle]           | JVM build engine: two-tier `include` + composite `includeBuild`, a cross-project task DAG, local + remote build cache.                  |
| [Maven][maven]             | The JVM reactor: aggregator `pom.xml` topologically sorts modules by GAV and builds them in one pass; no native lockfile or cache.      |
| [sbt][sbt]                 | Scala's build tool: `build.sbt` with `aggregate`/`dependsOn`, a memoizing task graph, Zinc, and (2.x) a REAPI-compatible cache.         |
| [Mill][mill]               | JVM build tool: a tree of Scala-object modules lowered into one graph of content-hash-cached tasks — Bazel's model in the host.         |
| [Composer][composer]       | PHP's lockfile-driven single-package manager; its only monorepo primitive is the symlinking `path` repository.                          |
| [Nx][nx]                   | JS/TS orchestrator atop the package manager: a project graph → hashed, cached, topologically-scheduled task DAG with `affected`.        |
| [Turborepo][turborepo]     | Lean Rust JS/TS orchestrator: one `turbo.json`, content-hashed tasks, local + remote replayed outputs — "never do work twice."          |
| [Lerna][lerna]             | The original JS monorepo tool, now Nx-stewarded: delegates tasks/cache to Nx, keeps its `version`/`publish` release toolchain.          |
| [Rush][rush]               | Microsoft's enterprise orchestrator: explicit project registry, deterministic install, native incremental engine, cobuild cache.        |
| [Lage][lage]               | Microsoft's task runner overlaying a pipeline onto any npm/yarn/pnpm workspace; `(package × task)` DAG, local + remote cache.           |
| [Wireit][wireit]           | Google's no-new-binary upgrade to npm scripts: per-script cross-package DAG, SHA-256 fingerprinting, local + GitHub-Actions cache.      |
| [Bazel][bazel]             | Google's language-agnostic content-addressed engine: a monorepo becomes one action graph, Skyframe-incremental, REAPI-cacheable.        |
| [Buck2][buck2]             | Meta's Rust rewrite of Buck: remote-execution-first, one phaseless DICE dependency graph, Starlark rules, REAPI caching.                |
| [Pants][pants]             | Polyglot orchestrator betting on dependency inference: reads imports for a file-level DAG, memoizing Rust + Tokio engine over REAPI.    |
| [Please][please]           | Lightweight Go Bazel/Buck-family engine: restricted-Python `BUILD` files form one hash-keyed, sandboxed, REAPI-cacheable graph.         |
| [moon][moon]               | Rust convention-first polyglot orchestrator: explicit project/action graph, content-hashed tasks, local + Bazel-REAPI cache.            |
| [GN + Ninja][gn]           | A strict generator/executor split: GN writes `build.ninja` from `BUILD.gn`; Ninja executes it at maximum speed, `mtime`-incremental.    |
| [Dagger][dagger]           | Container-native CI engine: pipelines are real code calling a GraphQL API, run by BuildKit as an auto-caching content-addressed DAG.    |
| [Earthly][earthly]         | Container-native build tool ("Dockerfile + Makefile"): `+target` artifact references across files/repos; now frozen/unmaintained.       |
| [Garden][garden]           | Kubernetes-native automation: repo-wide Build/Deploy/Test/Run actions compiled into a version-hashed, graph-aware Stack Graph.          |
| [Task][task]               | Single-binary YAML task runner (declarative Make): parallel `deps` DAG, file-fingerprinted up-to-date checks, `includes` namespaces.    |
| [Just][just]               | Single-binary make-inspired command runner (not a build system): names/orders commands via a `justfile`, no caching or resolution.      |
| [mise][mise]               | Single-binary dev-tool manager + env loader + task runner: 2026 monorepo mode, `//path:task` namespacing, `petgraph` DAG.               |
| [Make][make]               | The 1976 `mtime` dependency engine and universal front door: a real parallel DAG, but no workspace, resolver, or content cache.         |
| [Meson][meson]             | Fast generate-then-execute native build system; monorepo model is the in-tree `subproject` wired in by a `.wrap` manifest.              |
| [CMake][cmake]             | Cross-platform meta-build generator with no native workspace; multi-package trees aggregated via `add_subdirectory`.                    |
| [SCons][scons]             | Pure-Python construction tool: the build description IS a Python program; content-hash signatures, shared `CacheDir`.                   |
| [Waf][waf]                 | Zero-dependency single-file Python build framework: `recurse()` assembles the tree, Waf schedules a hash-signature task DAG.            |
| [Ninja][ninja]             | Deliberately minimal, maximally-fast executor ("an assembler"): runs a generated `build.ninja` with near-instant incremental builds.    |
| [BuildBuddy][buildbuddy]   | Open-core Go REAPI implementation: CAS + ActionCache + a Redis scheduler + autoscaling executors behind one `--remote_executor` URL.    |
| [Buildbarn][buildbarn]     | Modular Go REAPI: content-addressable cache + size-class-aware remote execution from small composable daemons wired by Jsonnet.         |
| [NativeLink][nativelink]   | Nix-powered single-binary Rust REAPI: a composable JSON5 store stack and Nix-based Local Remote Execution for bit-identical toolchains. |
| [redo][redo]               | djb's minimalist design realized: per-target `.do` scripts declare prerequisites at runtime via `redo-ifchange` into `.redo`.           |
| [tup][tup]                 | File-based build system updating only the affected slice (the beta algorithm); the DAG is discovered by intercepting real I/O.          |
| [Nix (flakes)][nix-flakes] | Flakes turn any directory into a content-hash-locked node — the polyglot glue that wires multi-language monorepos no one tool sees.     |

---

## Sources

Each deep-dive carries its own primary-source citations (the tool's own source tree
or official documentation, with verbatim quotes). The authoritative artifacts behind
this index's classifications are:

- **The five dimensions** — workspace declaration, dependency isolation, task DAG,
  caching/remote execution, and CLI ergonomics — are defined in [concepts] and
  applied uniformly across all 44 deep-dives.
- **`dub` grounding** — the `dub` and `dub-docs` source trees under
  `~/code/repos/dlang/`, written up in the [`dub` baseline][dub-baseline] and the
  "`dub` delta" of the [comparison][comparison].
- **REAPI** — the Remote Execution API v2 specification, as implemented by
  [Bazel][bazel], [Buck2][buck2], [Pants][pants], [Please][please], and served by
  [BuildBuddy][buildbuddy], [Buildbarn][buildbarn], and [NativeLink][nativelink].
- **Per-tool sources** — repository trees, official docs, and design write-ups cited
  in each linked deep-dive.

Cross-tree, the sibling [async I/O survey][async-io-index] and [coroutines
survey][coroutines-index] share this corpus's house style and feed the broader
Sparkles research program.

<!-- References -->

<!-- Synthesis & concept docs (siblings) -->

[concepts]: ./concepts.md
[dub-baseline]: ./dub-baseline.md
[comparison]: ./comparison.md
[dub-proposal]: ./dub-proposal.md

<!-- Tool deep-dives (subdirs) -->

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
[nx]: ./nx/
[turborepo]: ./turborepo/
[lerna]: ./lerna/
[rush]: ./rush/
[lage]: ./lage/
[wireit]: ./wireit/
[bazel]: ./bazel/
[buck2]: ./buck2/
[pants]: ./pants/
[please]: ./please/
[moon]: ./moon/
[gn]: ./gn/
[dagger]: ./dagger/
[earthly]: ./earthly/
[garden]: ./garden/
[task]: ./task/
[just]: ./just/
[mise]: ./mise/
[make]: ./make/
[meson]: ./meson/
[cmake]: ./cmake/
[scons]: ./scons/
[waf]: ./waf/
[ninja]: ./ninja/
[buildbuddy]: ./buildbuddy/
[buildbarn]: ./buildbarn/
[nativelink]: ./nativelink/
[redo]: ./redo/
[tup]: ./tup/
[nix-flakes]: ./nix-flakes/

<!-- Cross-tree siblings -->

[async-io-index]: ../async-io/index.md
[coroutines-index]: ../coroutines/index.md
