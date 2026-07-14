# mise (Polyglot)

A single-binary, `mise.toml`-configured polyglot **dev-tool manager, environment
loader, and task runner** (the successor to `rtx`, itself an `asdf` reimagining)
that — since the 2026 `experimental_monorepo_root` feature — also discovers
sub-projects across a tree, prefixes their tasks as `//path:task`, and runs them
through a `petgraph` DAG with `sources`/`outputs` change detection.

| Field           | Value                                                                                                                                                                                                                                                           |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language        | Rust (the binary); workspace config in TOML (`mise.toml`) + standalone task scripts                                                                                                                                                                             |
| License         | MIT (Copyright Jeff Dickey `@jdx` and contributors)                                                                                                                                                                                                             |
| Repository      | [jdx/mise][repo]                                                                                                                                                                                                                                                |
| Documentation   | [mise.jdx.dev][docs] · [Tasks][docs-tasks] · [Monorepo Tasks][docs-monorepo] · [Task architecture][docs-arch]                                                                                                                                                   |
| Category        | Generic Task Runner                                                                                                                                                                                                                                             |
| Workspace model | No package graph; **two layers** — (a) hierarchical `mise.toml` config that layers tools/env/tasks per directory, and (b) opt-in **monorepo mode** (`experimental_monorepo_root = true`) that discovers `config_roots` and namespaces tasks as `//project:task` |
| First released  | As `rtx` (2023); renamed to `mise` in 2024. CalVer release line                                                                                                                                                                                                 |
| Latest release  | `2026.6.0` (June 3, 2026)                                                                                                                                                                                                                                       |

> **Latest release:** `2026.6.0`, published **June 3, 2026** ([releases][releases]).
> mise uses a **CalVer** `YYYY.M.PATCH` scheme and ships extremely frequently
> (211 releases across 2025). The **monorepo tasks** feature analysed here is
> still gated behind `experimental_monorepo_root = true` **and** the global
> `MISE_EXPERIMENTAL=1` flag ([monorepo docs][docs-monorepo]). Source citations
> below are against `main` at commit `ebf4795` and the official docs as of
> June 5, 2026.

---

## Overview

### What it solves

mise's positioning is broader than the rest of the **Generic Task Runner**
family — it is three tools in one binary. From the README ([`README.md`][readme]):

> _"`mise` prepares your development environment before each command runs. It
> keeps project tools, environment variables, and tasks in one `mise.toml` file
> so new shells, checkouts, and CI jobs all start from the same setup."_

The three pillars, also stated in the README, are: **install and switch between
dev tools** (`node`, `python`, `terraform`, … — an `asdf` replacement), **load
environment variables per project directory** (a `direnv` replacement), and
**define and run tasks** (a `make`/[`just`][just] replacement). It is the only
tool in this survey that bundles a **version manager** with the task runner, which
is exactly what makes its monorepo story distinctive: a member's `[tools]` and
`[env]` are layered automatically alongside its `[tasks]`.

For a polyglot monorepo, mise is the **glue layer plus toolchain layer**. Like
[Task][task] and [just][just] it orchestrates _commands_, not _packages_ — it has
**no dependency resolver for the project graph, no unified lockfile across
members, no package store, and no remote-execution backend**. The actual build
of each member is delegated to that member's native tool (`cargo build`,
`npm ci`, `uv sync`, `dub build`), invoked as a task `run` command. What mise adds
over [Task][task]/[just][just] is (1) automatic per-directory tool + env layering
and (2) — new in 2026 — first-class monorepo task discovery with `//...:build`
wildcards.

mise itself draws the comparison explicitly ([`docs/tasks/monorepo.md`][docs-monorepo-md]):

> _"**mise's advantage:** Simplicity through non-hermetic builds. mise doesn't
> try to control your entire build environment in isolation — instead, it manages
> tools and tasks in a flexible, practical way. … You get powerful monorepo task
> management with simple TOML configuration — enough power for most teams without
> the enterprise-level complexity that hermetic builds require."_

### Design philosophy

Three principles shape the tool, all visible in the source and docs:

1. **Layered configuration, not a workspace manifest.** mise's core data model is
   a _stack_ of `mise.toml` files discovered by walking from the CWD up to the
   root (and `~/.config/mise/config.toml` globally). Each file contributes
   `[tools]`, `[env]`, and `[tasks]`; child files override parents. There is no
   `members = [...]` array in base mode — the "workspace" is implicit in the
   directory tree. Monorepo mode (below) is an opt-in overlay on top of this.

2. **Non-hermetic by design.** Unlike [Bazel][bazel]/[Buck2][buck2], mise makes no
   attempt to sandbox a task or capture undeclared inputs (the per-task
   `--deny-read`/`--deny-net`/`--deny-write` sandbox flags are an opt-in,
   experimental, _security_ feature, not a correctness/hermeticity guarantee).
   Change detection is best-effort `sources`/`outputs` comparison — the same
   correctness ceiling as [Task][task] and [moon][moon], well below a sandboxed
   action graph.

3. **One static Rust binary, batteries included.** No Node, JVM, or plugin runtime
   to bootstrap; the tool manager, env loader, task DAG, and a `blake3` content
   cache all ship in the single `mise` executable. This is the ergonomic axis on
   which it competes with [Task][task]/[just][just] while doing strictly more.

Within this survey mise is the canonical _"task runner that is also a version
manager, with an opt-in monorepo overlay"_ data point: compare it against
[Task][task] (file-fingerprinting runner, no tool management, hand-enumerated
`includes`), [just][just] (command runner, no change detection at all), and
[moon][moon]/[Turborepo][turborepo] (which add the project graph, content-
addressed cache, and `--affected` detection mise omits).

---

## How it works

### The configuration stack

A mise project is anchored by one or more `mise.toml` files. The config-root
resolver ([`config/config_file/config_root.rs`][config-root]) recognises a wide
family of filenames — `mise.toml`, `.mise.toml`, `.config/mise.toml`,
`mise/config.toml`, `.mise/config.toml`, `.config/mise/config.toml`,
`.config/mise/conf.d/*.toml`, plus `.tool-versions` (asdf compat) — and maps each
back to its **config root** (the directory the config governs). A single file
declares all three pillars:

```toml
# mise.toml
[tools]
node = "20"
python = "3.12"

[env]
DATABASE_URL = "postgres://localhost/dev"

[tasks.build]
run = "npm run build"
sources = ["src/**/*.ts"]
outputs = ["dist/**/*.js"]
depends = ["lint"]

[tasks.lint]
run = "eslint src"
```

Running `mise run build` activates `node@20`/`python@3.12`, exports the `[env]`
vars, then resolves the task DAG. Tasks can equally live as **standalone scripts**
in `mise-tasks/`, `.mise/tasks/`, `mise/tasks/`, or `.config/mise/tasks/` — the
filename becomes the task name ([`cli/run.rs`][run]):

```bash
$ cat .mise/tasks/build <<EOF
#!/usr/bin/env bash
npm run build
EOF
$ mise run build
```

### The task graph

When `mise run` is invoked, mise builds a `petgraph::DiGraph<Task, ()>` over the
requested tasks and their transitive dependencies ([`task/deps.rs`][deps]). Three
dependency edges exist, deserialised from the task config ([`task/task_dep.rs`][task-dep],
[`docs/tasks/task-configuration.md`][docs-taskcfg]):

| Key            | Semantics (verbatim from docs)                                                                                                       |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `depends`      | _"Tasks that must be run before this task."_                                                                                         |
| `depends_post` | _"Like `depends` but these tasks run after this task and its dependencies complete."_                                                |
| `wait_for`     | _"It will wait for these tasks to complete before running however they won't be added to the list of tasks to run."_ (soft ordering) |

A dependency entry is flexible: a bare string (`"lint"`), an array
(`["build", "arg1"]` → task + args), or a table (`{ task = "build", env = { … } }`).
Shell-style `FOO=bar taskname arg` is also parsed. The graph nodes are keyed by
`(name, args, env)` so the **same task with different args/env is a distinct
node** ([`task_key`][deps]).

---

## Workspace declaration & topology

mise has **two** topology mechanisms, and distinguishing them is the most
important fact about it for this survey.

### Base mode: hierarchical config discovery (no explicit members)

By default there is **no workspace declaration at all**. mise walks the directory
tree from the CWD upward, loading every `mise.toml` it finds and **layering** them
— parent tools/env/tasks are inherited by children, children override parents.
A "monorepo" in base mode is simply a tree of directories that each carry a
`mise.toml`; tasks from the current directory's hierarchy are the ones visible.
There is no glob array of members, no project metadata, and **no cross-directory
task discovery** — a task in `packages/api/mise.toml` is invisible from the repo
root unless you `cd` into `packages/api`.

### Monorepo mode: opt-in discovery + `//` namespacing

The 2026 **monorepo tasks** feature ([discussion #6564][disc-6564],
[`docs/tasks/monorepo.md`][docs-monorepo]) adds an explicit overlay. It is
enabled by a flag in the **root** `mise.toml`, and requires the global
experimental gate:

```toml
# repo-root mise.toml
experimental_monorepo_root = true

[monorepo]
config_roots = [
    "packages/frontend",
    "packages/backend",
    "services/*",
]
```

The root-marking is detected by `experimental_monorepo_root()` and
`find_monorepo_root` ([`config/mod.rs`][config-mod]); the `[monorepo]` section
deserialises to a tiny struct ([`config/config_file/mise_toml.rs`][mise-toml]):

```rust
// src/config/config_file/mise_toml.rs
pub struct MonorepoConfig {
    /// Explicit list of config roots for monorepo task discovery.
    /// Supports single-level glob patterns (*).
    #[serde(default)]
    pub config_roots: Vec<String>,
}
```

> [!IMPORTANT]
> **Discovery globs are single-level only.** `config_roots` accepts `services/*`
> but **rejects recursive `**`** — `expand*config_roots` ([`config/mod.rs`][config-mod])
> errors with *"recursive glob '\*\*' not supported … use single-level '\*'
> instead"\_, and rejects absolute or out-of-tree paths. If `config_roots` is
> omitted entirely, mise auto-discovers any subdirectory containing a recognised
> config file. This is more automatic than [Task][task]'s hand-enumerated
> `includes`, but less expressive than [Cargo][cargo]'s `members = ["crates/*"]`
> (which `**`-globs) or [pnpm][pnpm]'s recursive `packages:` globs.

Once in monorepo mode, every sub-project's tasks are **prefixed by their
root-relative path** ([`prefix_monorepo_task_names`][config-mod]):

```rust
// src/config/mod.rs — prefix_monorepo_task_names
const MONOREPO_PATH_PREFIX: &str = "//";
const MONOREPO_TASK_SEPARATOR: &str = ":";
// "packages/frontend" + "build" => "//packages/frontend:build"
```

So a task `build` in `packages/frontend/mise.toml` is addressed globally as
`//packages/frontend:build`. The `//`-from-root / `:`-current-dir convention is
borrowed straight from [Bazel][bazel]/[Buck2][buck2] label syntax (`//pkg:target`),
and `extract_monorepo_path` ([`task/mod.rs`][task-mod]) parses it back out.

> [!NOTE]
> mise loads sub-project tasks **lazily**. By default (`should_load_subdirs ==
false`) only the current directory hierarchy is loaded; subdirectories are
> walked only when a wildcard (`//...:build`) or path hint (`//packages/...`) or
> `--all` is present ([`config/mod.rs`][config-mod] `load_local_tasks_with_context`).
> This keeps the common single-project `mise run build` fast even in a large repo.

---

## Dependency handling & isolation

This dimension splits cleanly between mise's two roles.

### Project dependencies — delegated (no resolver, no unified lockfile)

For the _project graph_, mise behaves like every other generic runner: it does
**not** resolve packages, hoist, symlink, maintain a virtual store, or produce a
unified lockfile across members. Each member's real dependencies are installed by
that member's native package manager, invoked as a task `run` command. Cross-member
ordering is a **task edge**, not a package edge: `depends = ["//libs/core:build"]`
guarantees the library builds first, but linking the dependent against the
library's _artifact_ remains the language toolchain's concern (a `path =` in
`Cargo.toml`, a `replace` in `go.mod`, a `path=` in `dub.sdl`). There is **no
`workspace:`-protocol equivalent** for one member to depend on a sibling's
_package_.

> [!NOTE]
> mise has a real but separate **"deps" subsystem** ([`src/deps/`][src-deps]) with
> providers for `npm`, `pnpm`, `yarn`, `bun`, `pip`, `uv`, `poetry`, `go`,
> `composer`, `bundler`, `dart`, and `git_submodule`. These detect and install a
> _single project's_ language dependencies (the `mise install`/`deps` flow) — they
> are **not** a cross-member workspace resolver. mise orchestrates these per
> project; it does not unify them into one lockfile the way [Cargo][cargo]/[uv][uv]
> /[pnpm][pnpm] do.

### Tool isolation — mise's distinctive layer

Where mise diverges from [Task][task]/[just][just] is **per-task and per-project
tool/env isolation**, which it owns natively because it is also a version manager:

- **Per-directory tool layering.** Each `mise.toml` in the config stack
  contributes `[tools]`; a sub-project can pin `node = "18"` while the root pins
  `node = "20"`, and the nearest config wins for commands in that directory. In
  monorepo mode each `config_root`'s tools and env are layered automatically when
  its tasks run.

- **Per-task tools.** A task can declare its own `[tools]` table — the field is
  `tools: IndexMap<String, TaskToolValue>` on the `Task` struct
  ([`task/mod.rs`][task-mod]) — to install/activate a specific tool version for
  just that task ([docs][docs-taskcfg]: _"Tools to install and activate before
  running the task."_). `mise run --tool node@20 build` adds tools ad-hoc from the
  CLI ([`cli/run.rs`][run]).

- **Per-task env, not inherited by deps.** A task's `[env]` is scoped to that
  task; the docs are explicit that these _"will not be passed to `depends`
  tasks."_ This is a deliberate isolation boundary between a task and its
  prerequisites.

This tool/env layering is the closest mise comes to "dependency isolation," and
it is genuinely more than the pure runners offer — but it isolates **toolchains
and environment**, not **package dependency trees**.

---

## Task orchestration & scheduling

This is where mise earns its keep as a build-ish tool.

### The DAG and the leaf-emitting scheduler

`Deps::new` ([`task/deps.rs`][deps]) builds the `petgraph::DiGraph`, walking each
task's resolved `depends`/`depends_post`/`wait_for` edges, detecting cycles, and
recording `dep_edges` and `post_dep_parents` maps. Execution is a **streaming
leaf-emission** model rather than a precomputed topological order: `emit_leaves`
finds all graph nodes with no outstanding outgoing edges (`graph.externals(
Direction::Outgoing)`) and pushes them to the scheduler; as each task completes it
is `remove`d from the graph, which re-emits any newly-freed leaves. This naturally
maximises parallelism — every currently-runnable task is dispatched at once.

The `Scheduler` ([`task/task_scheduler.rs`][scheduler]) is a Tokio construct: a
`Semaphore` caps concurrency, a `JoinSet` tracks in-flight work, and an
`mpsc::UnboundedSender<SchedMsg>` feeds leaves into a `run_loop`. On a task failure
without `--continue-on-error`, it sends `SIGTERM` to every sibling
(`CmdLineRunner::kill_all(SIGTERM)`) so the run aborts promptly:

```rust
// src/task/task_scheduler.rs — Scheduler::new
pub fn new(jobs: usize) -> Self {
    let (sched_tx, sched_rx) = mpsc::unbounded_channel::<SchedMsg>();
    Self {
        semaphore: Arc::new(Semaphore::new(jobs)),   // parallelism cap
        jset: Arc::new(Mutex::new(JoinSet::new())),
        // ...
    }
}
```

**Concurrency** defaults to **4** jobs, set by `--jobs`/`-j` (or `MISE_JOBS`, or
`jobs` in config); `-j 1` serialises. The DAG is the unit of parallelism — there
is no separate "parallel vs sequential deps" split as in [Task][task]; everything
that is concurrently runnable runs concurrently up to the job cap.

### Change detection — `sources`/`outputs`, mtime or `blake3`

A task with `sources` declared is **skipped when fresh**
([`task/task_source_checker.rs`][source-checker], [docs][docs-taskcfg]):

> _"if this and `outputs` is defined, mise will skip executing tasks where the
> modification time of the oldest output file is newer than the modification time
> of the newest source file."_

`sources_are_fresh` implements two staleness strategies, selected by settings:

| Mode                                                | Mechanism                                                                                                                                                         |
| --------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **metadata hash** (default)                         | Hash file metadata (size/mtime) of all `sources` into a digest stored beside the task; mismatch ⇒ stale. Then compare newest-source mtime vs oldest-output mtime. |
| **content hash** (`source_freshness_hash_contents`) | Hash `sources` **contents** with `blake3` (cached per file) instead of metadata — robust to mtime churn (e.g. fresh `git clone`, tarball extraction).             |

`sources`/`outputs` accept gitignore-style globs (with `!`-exclusions), parsed via
`ignore::overrides::Override` ([`build_source_matcher`][source-checker]). Two
escape hatches mirror the `auto` convention: **`outputs = { auto = true }`** lets
mise _"touch an internally tracked file based on the hash of the task
definition"_ ([docs][docs-taskcfg]) instead of you listing outputs; and
`save_checksum` touches those auto-outputs after a successful run. Files with a
UNIX-epoch mtime (timestamp-stripped tarball extracts) are conservatively treated
as stale.

> [!IMPORTANT]
> **Dependency-driven cascade re-run.** mise tracks, per task, whether each
> _dependency actually ran_ (`mark_ran` / `any_dep_ran` in [`task/deps.rs`][deps]).
> The documented contract ([docs][docs-taskcfg]): _"When a task depends on another
> task that also has `sources` defined, and the dependency runs because its
> sources changed, the dependent task will also re-run — even if the dependent's
> own sources haven't changed."_ This is the monorepo-critical behaviour [Task][task]
> lacks: a downstream member rebuilds when an upstream member it `depends` on was
> rebuilt, propagating change through the DAG.

> [!WARNING]
> **No Git-aware affected-detection.** There is no `--affected <ref>` /
> `--since main` that computes "which members changed since a branch," the way
> [moon][moon] / [Turborepo][turborepo] / [Nx][nx] do. mise's only change
> detection is the per-task `sources` fingerprint (plus the dependency cascade).
> Restricting a run to "what changed across the repo" must be hand-built, or
> approximated with `//...:build` (which runs every match and relies on each
> task's `sources` skip to no-op the unchanged ones).

---

## Caching & remote execution

mise's caching is **local-only and skip-only**, the same shape as [Task][task]'s
and fundamentally different from the artifact-replay caches of
[Turborepo][turborepo]/[Bazel][bazel]:

- **What is cached is a fingerprint, not an artifact.** mise stores the `sources`
  hash (metadata- or `blake3`-content-based) and, for `auto` outputs, a touched
  marker file — under the mise cache directory, **not** the build outputs
  themselves. On a "hit," mise **skips re-running the command** and leaves existing
  outputs in place; on a miss it re-runs and rewrites the hash. It never archives,
  restores, or transports build outputs. Consequence: a fresh `git clone` has no
  outputs and (with the default metadata strategy) churned mtimes, so everything
  re-runs — the `source_freshness_hash_contents` (`blake3`) mode exists precisely
  to make the skip survive mtime resets, but it still does not _replay_ a missing
  artifact.

- **No remote cache, no REAPI, no remote execution.** There is no content-
  addressable artifact store, no Bazel Remote-Execution-API client, no shared-team
  cache. mise's own monorepo docs draw the line explicitly
  ([`docs/tasks/monorepo.md`][docs-monorepo-md]): [Bazel] _"offers incredible
  features like distributed caching, remote execution, and hermetic builds,"_ and
  mise positions itself as the deliberately simpler, **non-hermetic** alternative
  that forgoes them. The docs' own "when **not** to use mise" guidance:
  _"You need advanced task caching → Nx, Turborepo, or Bazel offer sophisticated
  caching systems."_

- **Remote _tasks_ ≠ remote _cache_.** mise can fetch a task definition from an
  `http(s)://` or `git::` URL (the `task_file_providers` — `remote_task_http.rs`,
  `remote_task_git.rs`), with `--no-cache` / `MISE_TASK_REMOTE_NO_CACHE` to bypass
  the local copy. As in [Task][task], this caches the _configuration_, not _build
  results_.

> [!NOTE]
> The practical consequence for a monorepo: mise's incrementality is real on a
> warm checkout (don't re-run a task whose `sources` are unchanged, and propagate
> re-runs through `depends`), but there is **no cross-machine cache**. Teams that
> want shared/remote caching pair mise with an external CI cache keyed on the same
> globs, or reach for [moon][moon] / [Turborepo][turborepo] / [Bazel][bazel].

---

## CLI / UX ergonomics

mise's command boundary is `mise run [flags] <task...>` (aliased `mise r`, and a
bare `mise <task>` works for non-ambiguous names). The monorepo addressing scheme
is the ergonomic headline.

| Invocation                                   | Meaning                                                                  |
| -------------------------------------------- | ------------------------------------------------------------------------ |
| `mise run build`                             | Run `build` (and its `depends`) from the current config hierarchy        |
| `mise //packages/frontend:build`             | Run a specific sub-project's task by **absolute `//`-from-root path**    |
| `mise :build`                                | Run `build` in the **current** `config_root` (the `:` prefix)            |
| `mise //...:test`                            | **Path wildcard** — run `test` in **every** project at any depth (`...`) |
| `mise //packages/...:build`                  | Run `build` in every project under `packages/`                           |
| `mise '//projects/frontend:*'`               | **Task-name wildcard** (`*`) — run all tasks in one project              |
| `mise '//...:test*'`                         | Combined path + name wildcards                                           |
| `mise run -j 8 test`                         | Cap parallelism at 8 jobs (`--jobs`; default 4)                          |
| `mise run -f build`                          | `--force` — run even if `sources`/`outputs` say up to date               |
| `mise run -n build`                          | `--dry-run` — print tasks in execution order without running             |
| `mise run -c a b`                            | `--continue-on-error` — don't `SIGTERM` siblings on a failure            |
| `mise run -o prefix\|interleave\|keep-order` | Output mode: per-line task-labelled, raw interleaved, or ordered         |
| `mise tasks deps [--dot]`                    | Print the dependency graph (DOT format for Graphviz)                     |

The `//path:task` / `...` / `*` wildcard grammar is mise's answer to the
filter-flag problem. Where [Task][task] forces explicit enumeration and
[pnpm][pnpm]/[Turborepo][turborepo] use a `--filter` flag, mise folds project
selection into the **task address itself** — Bazel-style. `//...:test` is the
"test everything" broadcast; `//services/...:build` is a sub-tree slice;
`//api:lint` is a single target. There is, however, **no `--since`/`--affected`
Git slicing** — the wildcard runs every match and leans on per-task `sources`
skips to avoid redundant work.

> [!NOTE]
> mise warns that it _"will never define commands with a `//` or `:` prefix"_
> ([monorepo docs][docs-monorepo]) — the namespace grammar is reserved so it can
> never collide with a built-in subcommand. The trade-off is that the powerful
> addressing only exists inside an `experimental_monorepo_root` repo behind
> `MISE_EXPERIMENTAL=1`; outside monorepo mode you get plain `mise run <name>`.

---

## Strengths

- **Three tools in one binary.** A version manager (`asdf`), env loader
  (`direnv`), and task runner (`make`/`just`) unified in one static Rust
  executable with no runtime to bootstrap — uniquely, the toolchain and the tasks
  live in the same `mise.toml`.
- **Automatic per-directory tool + env layering.** Each member's `[tools]`/`[env]`
  activate when its tasks run, with child-overrides-parent inheritance — isolation
  the pure runners ([Task][task], [just][just]) cannot offer.
- **A real `petgraph` DAG with maximal-parallelism leaf scheduling**, a configurable
  job cap, and three edge types (`depends`, `depends_post`, `wait_for`).
- **Content-aware change detection with a `blake3` option.** `sources`/`outputs`
  skips, plus a `blake3` content-hash mode that survives `git clone` mtime churn,
  plus a **dependency-cascade re-run** that [Task][task] lacks.
- **Bazel-style `//path:task` addressing with `...`/`*` wildcards** — project
  selection folded into the task name, no separate `--filter` flag to learn.
- **Auto project discovery** (`config_roots` single-level globs, or zero-config
  subdir discovery) — more automatic than [Task][task]'s hand-enumerated `includes`.

## Weaknesses

- **Monorepo mode is experimental and double-gated** (`experimental_monorepo_root`
  **and** `MISE_EXPERIMENTAL=1`); the rich `//path:task` ergonomics don't exist in
  plain mode.
- **No package resolver, no unified lockfile, no `workspace:` protocol.** Cross-
  member linkage is a task edge, not a package edge; version unification across
  members is the user's problem.
- **`config_roots` globs are single-level only** (`*`, never `**`) — deep
  hierarchies need every level enumerated or rely on auto-discovery.
- **Cache is skip-only and local-only.** It stores fingerprints, not artifacts; no
  remote/shared cache, no REAPI, no remote execution — incrementality is lost on a
  fresh CI checkout (mitigated, not solved, by `blake3` content hashing).
- **No Git-aware affected-detection** (`--since`/`--affected`); "run only what
  changed" is approximated by `//...:task` + per-task `sources` skips.
- **Non-hermetic.** Undeclared inputs cause stale "up to date"; the `--deny-*`
  sandbox is a security feature, not a correctness guarantee.

## Key design decisions and trade-offs

| Decision                                                             | Rationale                                                                                      | Trade-off                                                                                         |
| -------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Bundle version manager + env loader + task runner in one binary      | One `mise.toml`, one tool to install; toolchain and tasks co-located per project               | Larger scope/surface than a pure runner; task features compete for roadmap with tool management   |
| Layered per-directory `mise.toml` instead of a workspace manifest    | Zero-ceremony; nearest-config-wins gives natural per-member tool/env overrides                 | No explicit member list/metadata in base mode; cross-dir task discovery needs monorepo overlay    |
| Opt-in monorepo mode (`experimental_monorepo_root` + `config_roots`) | Keeps the common single-project path fast; namespaced `//path:task` discovery when asked       | Experimental + double-gated; single-level globs only; lazy subdir loading has edge cases          |
| Bazel-style `//path:task` + `...`/`*` addressing (no `--filter`)     | Project selection folded into the task name; reserved grammar can't collide with subcommands   | Only available inside monorepo mode; no `--since`/`--affected` graph slicing                      |
| `petgraph` DAG with streaming leaf emission                          | Maximises parallelism automatically; newly-freed leaves dispatch immediately                   | All-or-nothing concurrency model; ordering nuance pushed into `depends_post`/`wait_for`           |
| `sources`/`outputs` skip with metadata **or** `blake3` content hash  | Content mode survives mtime churn (clones, tarballs); metadata mode is cheap by default        | Not hermetic — undeclared inputs cause stale hits; content hashing adds per-file hash cost        |
| Dependency-cascade re-run (`any_dep_ran`)                            | A downstream member rebuilds when an upstream `depends` member rebuilt — correct for monorepos | Coarser than fine-grained input tracking; a dep that re-ran but produced no change still cascades |
| Cache stores fingerprints, not artifacts; local only                 | Tiny, server-less, no cache infra to run                                                       | No artifact replay; no remote/shared cache; incrementality lost on fresh CI checkouts             |
| Non-hermetic, delegate real builds to native managers                | Polyglot by construction; no resolver to maintain; no codebase restructuring                   | No unified lockfile/isolation; correctness ceiling below sandboxed engines ([Bazel][bazel])       |

---

## Sources

- [jdx/mise — GitHub repository][repo] (Rust, MIT; source for the README positioning quote, formerly `rtx`)
- [mise.jdx.dev — official documentation][docs] · [Tasks][docs-tasks] · [Task configuration][docs-taskcfg]
- [Monorepo Tasks documentation][docs-monorepo] — `experimental_monorepo_root`, `config_roots`, `//path:task`, `...`/`*` wildcards, Bazel/Nx/Turborepo comparison
- [Task System Architecture][docs-arch] — DAG, `depends`/`depends_post`/`wait_for`, `--jobs`, sources/outputs freshness
- [`src/config/config_file/config_root.rs`][config-root] — config-file family + config-root resolution
- [`src/config/config_file/mise_toml.rs`][mise-toml] — `MonorepoConfig { config_roots }` struct
- [`src/config/mod.rs`][config-mod] — `find_monorepo_root`, `prefix_monorepo_task_names` (`//`/`:`), `expand_config_roots` (single-level glob), lazy subdir loading
- [`src/task/deps.rs`][deps] — `petgraph` DAG, `emit_leaves`, `task_key`, `mark_ran`/`any_dep_ran` cascade
- [`src/task/task_scheduler.rs`][scheduler] — Tokio `Semaphore`/`JoinSet` scheduler, `SIGTERM` sibling kill
- [`src/task/task_source_checker.rs`][source-checker] — `sources_are_fresh`, metadata vs `blake3` content hash, `auto` outputs
- [`src/task/task_dep.rs`][task-dep] · [`src/task/mod.rs`][task-mod] — `TaskDep` parsing, `extract_monorepo_path`, per-task `tools`
- [`src/cli/run.rs`][run] — `mise run` flags (`--jobs`, `--force`, `--dry-run`, `--continue-on-error`, `--output`, `--tool`, `--no-cache`)
- [Releases][releases] — `2026.6.0` (June 3, 2026); [Introducing Monorepo Tasks (discussion #6564)][disc-6564]
- Related: [Task][task] · [just][just] · [make][make] · [moon][moon] · [Turborepo][turborepo] · [Nx][nx] · [Cargo][cargo] · [uv][uv] · [pnpm][pnpm] · [Bazel][bazel] · [Buck2][buck2] · [D landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/jdx/mise
[readme]: https://github.com/jdx/mise/blob/e3920138974b779f82b1822aa8d02b67a77dbbe0/README.md
[docs]: https://mise.jdx.dev/
[docs-tasks]: https://mise.jdx.dev/tasks/
[docs-taskcfg]: https://mise.jdx.dev/tasks/task-configuration.html
[docs-monorepo]: https://mise.jdx.dev/tasks/monorepo.html
[docs-monorepo-md]: https://github.com/jdx/mise/blob/e3920138974b779f82b1822aa8d02b67a77dbbe0/docs/tasks/monorepo.md
[docs-arch]: https://mise.jdx.dev/tasks/architecture.html
[releases]: https://github.com/jdx/mise/releases
[disc-6564]: https://github.com/jdx/mise/discussions/6564
[config-root]: https://github.com/jdx/mise/blob/e3920138974b779f82b1822aa8d02b67a77dbbe0/src/config/config_file/config_root.rs
[mise-toml]: https://github.com/jdx/mise/blob/e3920138974b779f82b1822aa8d02b67a77dbbe0/src/config/config_file/mise_toml.rs
[config-mod]: https://github.com/jdx/mise/blob/e3920138974b779f82b1822aa8d02b67a77dbbe0/src/config/mod.rs
[deps]: https://github.com/jdx/mise/blob/e3920138974b779f82b1822aa8d02b67a77dbbe0/src/task/deps.rs
[scheduler]: https://github.com/jdx/mise/blob/e3920138974b779f82b1822aa8d02b67a77dbbe0/src/task/task_scheduler.rs
[source-checker]: https://github.com/jdx/mise/blob/e3920138974b779f82b1822aa8d02b67a77dbbe0/src/task/task_source_checker.rs
[task-dep]: https://github.com/jdx/mise/blob/e3920138974b779f82b1822aa8d02b67a77dbbe0/src/task/task_dep.rs
[task-mod]: https://github.com/jdx/mise/blob/e3920138974b779f82b1822aa8d02b67a77dbbe0/src/task/mod.rs
[src-deps]: https://github.com/jdx/mise/tree/e3920138974b779f82b1822aa8d02b67a77dbbe0/src/deps
[run]: https://github.com/jdx/mise/blob/e3920138974b779f82b1822aa8d02b67a77dbbe0/src/cli/run.rs
[task]: ../task/
[just]: ../just/
[make]: ../make/
[moon]: ../moon/
[turborepo]: ../turborepo/
[nx]: ../nx/
[cargo]: ../cargo/
[uv]: ../uv/
[pnpm]: ../pnpm/
[bazel]: ../bazel/
[buck2]: ../buck2/
[d-landscape]: ../../async-io/d-landscape.md
