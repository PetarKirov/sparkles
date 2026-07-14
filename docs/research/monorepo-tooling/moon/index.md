# moon (Polyglot)

A Rust-built monorepo management and task-orchestration tool that began life
"for the web ecosystem" but has, by its `2.0` "Phobos" release, generalized into
a [Bazel][bazel]-inspired polyglot build orchestrator: an explicit project graph
plus a hash-based, content-addressable action graph, run through a unified
`moon exec` execution layer and cached locally or against any Bazel
Remote-Execution-API backend.

| Field           | Value                                                                                                                     |
| --------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Language        | Rust (the binary); workspace config in YAML / JSON / JSONC / TOML / HCL / Pkl                                             |
| License         | MIT                                                                                                                       |
| Repository      | [moonrepo/moon][repo]                                                                                                     |
| Documentation   | [moonrepo.dev/docs][docs] · [config reference][config] · [remote-cache guide][remote-cache]                               |
| Category        | Polyglot Build Orchestrator                                                                                               |
| Workspace model | Root-anchored: a `.moon/` config directory marks the workspace; members are `moon.yml` projects discovered by map or glob |
| First released  | `v0.1` (mid-2022); `v1.0` (Oct 2022)                                                                                      |
| Latest release  | `v2.3.1` (June 4, 2026)                                                                                                   |

> **Latest release:** `v2.3.1`, released **June 4, 2026** (the `2.3.0` feature
> release landed **June 1, 2026**). The major `v2.0` "Phobos" line shipped
> **Feb 18, 2026** ([blog][v2-blog], [InfoQ][infoq]); it replaced moon's
> hard-coded language "platforms" with **WASM toolchain plugins** managed by
> [proto][proto], unified `moon ci` / `moon check` / `moon run` over a new
> low-level `moon exec`, and added JSON/JSONC/HCL/Pkl/TOML as config formats
> alongside YAML. `2.3.0` then added the **local content-addressable storage
> (CAS) cache** experiment, sharing the on-disk format of the
> [REAPI][reapi] remote cache. Source citations below are against `master` and
> the official docs as of June 5, 2026.

---

## Overview

### What it solves

moon targets the same pain as every tool in this survey — a repository of many
projects whose tasks (build, lint, test, typecheck) must run in the right order,
only when something they depend on actually changed, and without each package
re-declaring the same boilerplate scripts. Where [Turborepo][turborepo] and
[Nx][nx] grew out of the JavaScript task-runner world and [Bazel][bazel] /
[Buck2][buck2] grew out of the hermetic-build world, moon sits deliberately
**in between**: it keeps the low-ceremony, convention-first ergonomics of a JS
task runner, but borrows Bazel's vocabulary of an explicit graph, content
hashing, and a remote cache spoken over the Remote Execution API.

The README states the original framing plainly ([`README.md`][readme]):

> _"moon is a repository **management**, **organization**, **orchestration**,
> and **notification** tool for the web ecosystem, written in Rust."_

By `v2.0` the "for the web ecosystem" qualifier is largely historical: the
toolchain is now a set of [proto][proto]-managed WASM plugins, and the same
project-graph / action-graph machinery drives Rust, Go, Python, PHP, Bash, and
arbitrary system commands as readily as Node/Bun/Deno.

### Design philosophy

moon is explicit about its lineage ([`README.md`][readme]):

> _"Many of the concepts within moon are heavily inspired from Bazel and other
> popular build systems."_

Three principles shape the surface:

1. **Incremental, opt-in adoption — not all-at-once.** The docs stress that
   _"moon has been designed to be adopted incrementally and is not an 'all at
   once adoption'"_ ([`README.md`][readme]). A repo can convert one project's
   `package.json` scripts into a single `moon.yml` task and grow from there;
   this is the opposite of Bazel's all-or-nothing `BUILD`-file conversion.
2. **Determinism through smart hashing.** _"With our smart hashing, only rebuild
   projects that have been changed since the last build"_ and moon _"collects
   inputs from multiple sources to ensure builds are deterministic and
   reproducible"_ ([`README.md`][readme]). Inputs are explicit (`inputs:`), so a
   single file change resolves to exactly the tasks whose declared inputs touch
   it.
3. **A managed, version-pinned toolchain.** moon _"automatically downloads and
   installs explicit versions of tools for consistency across the entire
   workspace or per project,"_ piggy-backing on [proto][proto]'s `~/.proto`
   store. This is the dimension where moon differs most from [Turborepo][turborepo]
   (which assumes you already installed Node) and aligns with Bazel's hermetic
   toolchains — though moon's is reproducible-by-convention, not hermetic.

Within this survey moon is the canonical _"Rust-built, convention-first polyglot
orchestrator that speaks the Bazel REAPI"_ data point: compare it against the
heavyweight hermetic engines [Bazel][bazel] / [Buck2][buck2] / [Pants][pants],
against the JS-rooted [Turborepo][turborepo] / [Nx][nx] task graphs it most
resembles ergonomically, and against the generic runners [Task][task] / [just][just].

---

## How it works

A moon workspace is anchored by a `.moon/` directory at the repository root. The
two cornerstone files are `.moon/workspace.yml` (where the members live and how
the pipeline behaves) and `.moon/toolchain.yml` (which tool versions to pin).
Each member project then carries a `moon.yml` declaring its relationships,
tasks, inputs, and outputs. From these, moon builds — in order — a **project
graph** (`dependsOn` edges), then an **action graph** (the DAG of concrete
actions: install deps, sync project, run task), then executes that graph.

The docs describe the run pipeline tersely: moon will _"generate a directed
acyclic graph, known as the action (dependency) graph,"_ then _"run all tasks in
the graph in parallel and in topological order"_ ([run-task][run-task]). On a
cache hit it _exits early_; on a miss it runs the command and writes a new cache
entry.

### Workspace file

```yaml
# .moon/workspace.yml
projects:
  globs:
    - 'apps/*'
    - 'packages/*'
  sources:
    root: '.'

vcs:
  manager: 'git'
  defaultBranch: 'master'

hasher:
  optimization: 'accuracy'
  walkStrategy: 'vcs'

pipeline:
  installDependencies: true
  syncProjects: true
```

### A project + its tasks

```yaml
# packages/components/moon.yml
type: 'library'
language: 'typescript'

dependsOn:
  - 'designSystem'
  - id: 'apiClients'
    scope: 'production'

tasks:
  build:
    command: 'tsc --build'
    inputs:
      - 'src/**/*'
      - '@group(configs)'
    outputs:
      - 'dts/**/*'
    deps:
      - '^:build' # build all upstream projects first
    options:
      cache: true
      runInCI: true
```

The `^:build` dependency means _"build every project this one `dependsOn`,
first"_; `~:typecheck` (or a bare `typecheck`) means _"a sibling task in the
same project."_ Those `^` / `~` config-scopes are how topological ordering is
declared without hand-listing every upstream target.

---

## Workspace declaration & topology

moon is **root-anchored**: the presence of a `.moon/` directory defines the
workspace boundary, and `.moon/workspace.yml`'s `projects` setting enumerates
the members. That setting accepts three shapes ([workspace config][config-ws]):

- **Explicit map** — `id -> path`, the most precise form:

  ```yaml
  projects:
    admin: 'apps/admin'
    apiClients: 'packages/api-clients'
    web: 'apps/web'
  ```

- **Glob list** — auto-discovery, where the project id is derived from the
  folder name:

  ```yaml
  projects:
    - 'apps/*'
    - 'packages/*'
    - 'shared/*/moon.yml'
  ```

- **Combined** — globs plus a `sources` map for the handful that need an
  explicit id (and a `globFormat` knob to choose how ids are derived):

  ```yaml
  projects:
    globs:
      - 'apps/*'
      - 'packages/*'
    sources:
      www: 'www'
  ```

Every discovered project **must** carry a `moon.yml` (or one of the other
config formats). The id is the stable handle used everywhere — in `dependsOn`,
in `project:task` targets, and in `--query` filters — so unlike a path-based
scheme, renaming a folder needn't change references if an explicit id is set.

The project graph is then built from two edge sources:

- **Explicit edges** — _"dependencies that are explicitly defined in a project's
  `moon.*` config file, using the `dependsOn` setting"_ ([concepts/project][concept-project]).
- **Implicit edges** — _"dependencies that are implicitly discovered by moon
  when scanning the repository. How an implicit dependency is discovered is
  based on the project's `language` setting, and how that language's ecosystem
  functions"_ ([concepts/project][concept-project]). For a `typescript`/`javascript`
  project, moon reads the `package.json` `dependencies` and maps any
  `workspace:`-protocol or in-repo package back to its owning moon project,
  wiring the graph edge automatically.

> [!NOTE]
> moon's `layer` (`application`/`library`/`tool`/…) and `stack`
> (`frontend`/`backend`/`infrastructure`/…) project fields are **metadata for
> filtering and constraints**, not topology. They populate `--query` and tag
> selectors (below) but do not by themselves create graph edges.

---

## Dependency handling & isolation

This is the dimension where moon's "in-between" position is sharpest. moon does
**not** run its own dependency resolver or maintain a virtual content-addressed
package store the way [pnpm][pnpm], [Yarn Berry][yarn-berry], or [Bazel][bazel]
do. Instead it **delegates installation to the language's own package manager**
and concerns itself with _ordering_ and _syncing_:

- **Tool + dependency installation is delegated to proto + the native manager.**
  The toolchain piggy-backs on proto: _"moon will piggyback off proto's
  toolchain found at `~/.proto` and reuse any tools available, or download and
  install them if they're missing"_ ([concepts/toolchain][concept-toolchain]).
  With `pipeline.installDependencies: true`, moon runs `npm`/`pnpm`/`yarn`/`bun`
  install (or `uv pip`, `cargo`, etc.) as an action graph node before tasks
  that need it. The isolation model is therefore whatever the underlying manager
  provides — pnpm's symlinked store, npm's hoisted `node_modules`, Cargo's
  registry cache — not something moon imposes.

- **Local cross-references use the host ecosystem's own protocol.** moon has no
  bespoke `workspace:`-style protocol of its own; in a JS workspace you keep
  using pnpm/yarn `workspace:*` versions, and moon's implicit-dependency scan
  reflects those into the project graph. The `dependsOn` field is moon's
  _explicit, language-agnostic_ overlay on top, used either to add edges the
  scanner can't infer (e.g. a Rust crate consumed by a Node build step) or to
  annotate the **scope** of an edge — `production`, `development`, `build`, or
  `peer` ([project config][config-project]):

  ```yaml
  dependsOn:
    - id: 'apiClients'
      scope: 'production'
    - id: 'designSystem'
      scope: 'peer'
  ```

- **Project syncing keeps manifests consistent.** With
  `pipeline.syncProjects: true`, moon's `SyncProject` action writes the project
  graph back into the native manifests — e.g. ensuring a TypeScript project's
  `tsconfig.json` `references` and its `package.json` `dependencies` actually
  list the sibling moon projects it `dependsOn`. This is moon's answer to the
  "did you forget to add the workspace dependency?" class of drift, analogous to
  Nx's project-graph sync.

> [!IMPORTANT]
> Because moon delegates resolution, it does **not** own a unified lockfile.
> There is no single moon lockfile resolving all members the way
> [Cargo][cargo]'s root `Cargo.lock` or a workspace `dub.selections.json` does;
> the source of truth for versions remains the native manager's lockfile
> (`pnpm-lock.yaml`, `Cargo.lock`, …). moon's reproducibility guarantee is about
> _tool versions_ (via proto) and _task input hashes_, not package resolution.

---

## Task orchestration & scheduling

moon builds and runs a two-tier graph.

1. **Project graph** — nodes are projects, edges are `dependsOn` (+ implicit
   scans). This is the topology used to resolve `^:` config-scope targets.
2. **Action graph** — the executable DAG. Nodes are concrete actions:
   `SetupToolchain`, `InstallDeps`, `SyncWorkspace`, `SyncProject`, and
   `RunTask`. moon _"generate[s] a directed acyclic graph … then run[s] all
   tasks in the graph in parallel and in topological order"_
   ([run-task][run-task]). In `v2.0` this all funnels through a single low-level
   `moon exec` engine that `moon run`, `moon ci`, and `moon check` sit on top of
   ([v2 blog][v2-blog]).

**Task deps and ordering.** A task's `deps` list names other targets that must
complete first, using the same scope grammar as `dependsOn`:

```yaml
tasks:
  build:
    command: 'vite build'
    deps:
      - '^:build' # upstream projects' build
      - '~:codegen' # a sibling task in this project
      - target: 'apiClients:build'
        cacheStrategy: 'outputs' # consume the dep's cached outputs
```

**Change detection via input hashing.** Each task declares `inputs` (file globs,
`@group(...)` file-group refs, env vars, even other projects) and `outputs`. moon
hashes the resolved inputs plus the toolchain version plus the command into a
single content hash; if that hash is unchanged from a prior run, the task is a
**cache hit** and is skipped. This is the mechanism that lets _"a single file
change … be narrowed to the tasks affected by that file and its graph
relationships."_ The `hasher.walkStrategy` chooses how files are enumerated —
`'vcs'` (ask Git, fast and ignores untracked noise) or `'glob'` (walk the
filesystem).

**Affected detection.** Beyond per-task hashing, moon has a Git-aware **affected
tracker** that, given a base ref, computes the changed files and the set of
projects/tasks touched by them — the basis for `--affected` (below). `v2.2`
shipped an experimental **async affected tracker** the release notes clock at
_"100-150% faster"_, and an async graph builder at _"100-170%"_ on large
workspaces ([releases][releases]).

**Concurrency.** Independent legs of the action graph run in parallel up to a
worker bound (overridable with `--concurrency` / `-c`); `runDepsInParallel`
controls whether a task's own `deps` fan out concurrently. A `persistent` task
flag marks long-running processes (dev servers) so they're scheduled last and
not awaited.

---

## Caching & remote execution

moon's caching is a three-layer story, and `2.x` aligned all of it on the Bazel
content-addressable format:

- **Local task-output cache.** Every cacheable task's `outputs` (plus its
  captured `stdout`/`stderr`) are archived and keyed by the task's input hash.
  Re-running with the same hash replays the archived outputs and logs instead of
  re-executing — _"the outputs of a task … as well as the stdout and stderr"_
  ([remote-cache][remote-cache]).

- **Local CAS cache (`2.3.0`, experimental).** The release notes describe _"a
  new experiment that stores task outputs in a local content-addressable storage
  (CAS) cache, sharing the same format used by the remote cache"_
  ([releases][releases]), enabled via `experiments.casOutputsCache`. Sharing the
  REAPI on-disk format means the local and remote caches are byte-compatible —
  a local hit and a remote hit reconstruct identical artifacts.

- **Remote cache over the Bazel Remote Execution API.** moon _"leverages the
  Bazel Remote Execution v2 API"_; a backend must support _action-result
  caching, content-addressable storage caching, SHA256 digest hashing, and gRPC
  requests_ ([remote-cache][remote-cache]). It speaks **gRPC by default** (or
  HTTP), so any REAPI-compatible server works — the docs call out
  [bazel-remote][bazel-remote] explicitly, and managed [Depot][depot] (since
  `v1.32`) and [BuildBuddy][buildbuddy]-class backends fit the same contract:

  ```yaml
  # .moon/workspace.yml — self-hosted REAPI cache
  remote:
    host: 'grpc://your-host.com:9092'
    api: 'grpc'
    cache:
      compression: 'zstd'
      instanceName: 'moon-outputs'
    auth:
      token: 'MOON_REMOTE_TOKEN'
  ```

> [!WARNING]
> moon's remote support is **caching only, not remote _execution_.** Despite
> speaking the Remote Execution API, moon uploads/downloads the Action Cache and
> CAS but still runs every action on the local machine — it does not dispatch
> actions to remote workers the way [Bazel][bazel] / [Buck2][buck2] /
> [BuildBuddy][buildbuddy] RBE do. The feature is also still marked unstable.
> moon stores _outputs_ only; _"the system does not store source code."_

> [!NOTE]
> The older hosted **moonbase** service (moon's first-party cache/CI insights
> SaaS) has been de-emphasized in favour of self-hosted REAPI backends and
> third-party managed caches; `2.x` documents the REAPI path as the primary
> remote-cache mechanism.

---

## CLI / UX ergonomics

moon's command boundary is **target-centric**: nearly everything is
`moon run <target>`, where a target is a compound `scope:task` identifier. The
scope grammar is the heart of the UX ([concepts/target][concept-target]):

| Form                | Meaning                                         | Example                                          |
| ------------------- | ----------------------------------------------- | ------------------------------------------------ |
| `project:task`      | one task in one project                         | `moon run app:lint`                              |
| `:task`             | that task in **every** project that defines it  | `moon run :lint`                                 |
| `'#tag:task'`       | that task in every project carrying a **tag**   | `moon run '#frontend:lint'`                      |
| `project:#tasktag`  | every task tagged `tasktag` in a project        | `moon run app:#quality`                          |
| `'~:task'`          | the **closest** project to the CWD (run-time)   | `moon run '~:lint'`                              |
| `'^:task'`          | the same task in all **upstream** deps (config) | `deps: ['^:build']`                              |
| `'~:task'` / `task` | a sibling task in the owning project (config)   | `deps: ['~:typecheck']` or `deps: ['typecheck']` |

Selection refinements layer on top of the target:

- **`--query`** — a small expression language over project metadata, the
  general-purpose filter: `moon run :build --query "language=[javascript, typescript]"`,
  or `--query "stack=frontend && layer=application"`.
- **`--affected [remote]`** — restrict to projects/tasks touched by local (or
  `remote`) Git changes; refine by status with `--status modified --status deleted`
  (`added`/`deleted`/`modified`/`staged`/`untracked`/…).
- **`--downstream direct`** (and `--upstream`) — pull in dependents/dependencies
  of the matched set, the Nx/Turborepo "`...`"-style graph expansion.
- **`-- <args>`** — everything after `--` is forwarded verbatim to the underlying
  command: `moon run app:build -- --force`.

Three umbrella commands wrap `moon run` for common intents, all sharing the
`moon exec` engine since `v2.0`:

- **`moon ci`** — run all affected tasks for a CI pipeline, with built-in
  base/head ref handling and job sharding (`--job` / `--jobTotal`) so the action
  graph can be split across parallel CI runners.
- **`moon check [project]`** — run _every_ task flagged `runInCI` for a project
  (the "is this project healthy?" command).
- **`moon run`** — the explicit, fully-general form.

Inspection commands round it out: `moon project-graph` / `moon task-graph` /
`moon action-graph` emit (or visualize) the DAGs, and `moon query projects` /
`moon query tasks` expose the same selectors programmatically for scripting.

---

## Strengths

- **Convention-first, incrementally adoptable.** A single `moon.yml` with one
  task brings a project into the graph; no all-at-once `BUILD`-file conversion.
- **Managed, pinned toolchain via proto.** Tool versions are reproducible across
  machines and CI without manual pre-install — a capability most JS task runners
  ([Turborepo][turborepo], [Lerna][lerna]) lack entirely.
- **Explicit inputs/outputs → precise, content-hashed incrementality.** Change
  detection is per-task, not per-project, and deterministic.
- **Bazel-REAPI remote cache without Bazel's ceremony.** Any REAPI server
  (`bazel-remote`, Depot, BuildBuddy-class) works; the local CAS shares the same
  format.
- **Polyglot by design (especially since `v2.0`).** WASM toolchain plugins +
  arbitrary system commands mean Rust, Go, Python, PHP, and shell are
  first-class, not bolted on.
- **Rich target/selector grammar.** Tags, `--query`, `--affected`,
  `--downstream`, and the `^`/`~`/`:` scopes give expressive slicing.
- **Project syncing** keeps native manifests (`tsconfig.json`, `package.json`)
  consistent with the declared graph.

## Weaknesses

- **No dependency resolution or unified lockfile.** moon orchestrates the native
  package manager but doesn't resolve versions; there's no single moon lockfile,
  so version drift is the underlying manager's problem, not moon's.
- **Remote _execution_ is absent.** It speaks REAPI for _caching_ only — actions
  always run locally, unlike [Bazel][bazel]/[Buck2][buck2]/RBE backends.
- **Not hermetic.** Reproducibility is by-convention (pinned tools + declared
  inputs); an undeclared input or ambient system state can still leak in, unlike
  Bazel's sandboxed actions.
- **Younger, smaller ecosystem** than Bazel or the npm-native orchestrators;
  several `2.x` headline features (CAS cache, async tracker, remote cache) are
  still flagged experimental/unstable.
- **proto coupling.** The managed-toolchain story assumes proto; opting out
  (`MOON_TOOLCHAIN_FORCE_GLOBALS`) gives up the determinism that is a key selling
  point.
- **Config surface is large.** Six config formats and a deep `moon.yml` schema
  (tasks, options, merge-strategies, owners, docker) raise the learning curve
  relative to [just][just]/[Task][task].

---

## Key design decisions and trade-offs

| Decision                                                      | Rationale                                                                           | Trade-off                                                                                   |
| ------------------------------------------------------------- | ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Root `.moon/` config dir + map-or-glob `projects`             | One obvious workspace boundary; stable ids decouple references from folder paths    | Every member needs a `moon.yml`; two graph sources (config + scan) to reason about          |
| Delegate dependency install to the native manager (+ proto)   | Reuse mature resolvers/lockfiles; incremental adoption; polyglot by default         | No unified lockfile; isolation model is whatever the host manager gives; version drift risk |
| Explicit `inputs`/`outputs` per task → content hashing        | Deterministic, file-precise incrementality; cache hits skip work entirely           | Authoring burden; an undeclared input causes stale-cache bugs (not hermetic)                |
| Two-tier project graph → action graph, one `moon exec` engine | Clean separation of topology from execution; `ci`/`check`/`run` share one code path | Indirection; the action graph (install/sync/run) is more moving parts than a plain runner   |
| Adopt the Bazel REAPI for the cache wire format               | Interop with an existing backend ecosystem; local CAS == remote format              | Caching-only (no remote execution); still unstable; ties moon to REAPI's semantics          |
| Managed toolchain via proto + WASM plugins (`v2.0`)           | Reproducible tool versions; community-extensible to any language                    | proto coupling; WASM plugin maturity varies; force-globals path forfeits determinism        |
| Target grammar with `:` / `#` / `^` / `~` scopes + `--query`  | Expressive, terse slicing of a large graph                                          | Steeper grammar than `tool run <name>`; `^`/`~` overload run-vs-config meaning              |
| Incremental, opt-in adoption over hermetic all-or-nothing     | Low barrier; coexists with existing scripts                                         | Caps the correctness ceiling — can't guarantee Bazel-grade hermeticity                      |

---

## Sample workspace

A minimal, runnable two-project moon workspace lives in [`./sample/`](./sample/).
It shows the root `.moon/workspace.yml` + `.moon/toolchain.yml`, two TypeScript
projects where `apps/web` `dependsOn` `packages/utils` **locally** (via both
`dependsOn` and a pnpm `workspace:*` reference), and a `build` task whose
`deps: ['^:build']` forces the upstream `utils` build to run first. With moon on
`PATH`, `moon run web:build` would build `utils` then `web` in topological order.

---

## Sources

- [moonrepo/moon — GitHub repository][repo] (source for quoted README text)
- [moonrepo.dev/docs][docs] — official documentation
- [`.moon/workspace.yml` config reference][config-ws] — `projects` map/glob, `vcs`, `pipeline`, `hasher`, `remote`
- [`moon.yml` project config reference][config-project] — `dependsOn` scopes, `tasks`, `inputs`/`outputs`/`deps`
- [Concepts: Targets][concept-target] — the `scope:task` grammar
- [Concepts: Projects][concept-project] — explicit vs implicit dependencies
- [Concepts: Toolchain][concept-toolchain] — proto integration, version pinning
- [Run a task][run-task] — action graph, `--affected`, `--query`, target forms
- [Remote caching guide][remote-cache] — Bazel REAPI v2, gRPC/HTTP, bazel-remote
- [moon v2.0 "Phobos" release][v2-blog] · [InfoQ coverage][infoq] · [Releases][releases]
- Related: [Bazel][bazel] · [Buck2][buck2] · [Pants][pants] · [Turborepo][turborepo] · [Nx][nx] · [Lerna][lerna] · [Task][task] · [just][just] · [pnpm][pnpm] · [Yarn Berry][yarn-berry] · [Cargo][cargo] · [BuildBuddy][buildbuddy] · [D landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/moonrepo/moon
[readme]: https://github.com/moonrepo/moon/blob/0670031933b72403abb8d134c5cc3363b4a57874/README.md
[docs]: https://moonrepo.dev/docs
[config]: https://moonrepo.dev/docs/config
[config-ws]: https://moonrepo.dev/docs/config/workspace
[config-project]: https://moonrepo.dev/docs/config/project
[concept-target]: https://moonrepo.dev/docs/concepts/target
[concept-project]: https://moonrepo.dev/docs/concepts/project
[concept-toolchain]: https://moonrepo.dev/docs/concepts/toolchain
[run-task]: https://moonrepo.dev/docs/run-task
[remote-cache]: https://moonrepo.dev/docs/guides/remote-cache
[v2-blog]: https://moonrepo.dev/blog/moon-v2.0
[infoq]: https://www.infoq.com/news/2026/05/moonrepo-2-release/
[releases]: https://github.com/moonrepo/moon/releases
[proto]: https://moonrepo.dev/proto
[reapi]: https://github.com/bazelbuild/remote-apis
[bazel-remote]: https://github.com/buchgr/bazel-remote
[depot]: https://web.archive.org/web/20250103201614/https://depot.dev/
[bazel]: ../bazel/
[buck2]: ../buck2/
[pants]: ../pants/
[turborepo]: ../turborepo/
[nx]: ../nx/
[lerna]: ../lerna/
[task]: ../task/
[just]: ../just/
[pnpm]: ../pnpm/
[yarn-berry]: ../yarn-berry/
[cargo]: ../cargo/
[buildbuddy]: ../buildbuddy/
[d-landscape]: ../../async-io/d-landscape.md
