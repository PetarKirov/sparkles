# uv (Python)

An extremely fast Rust-built Python package and project manager whose Cargo-inspired workspaces give a monorepo of `pyproject.toml`-defined packages a single shared lockfile, a global content-addressed cache, and one virtual environment.

| Field           | Value                                                                                             |
| --------------- | ------------------------------------------------------------------------------------------------- |
| Language        | Rust (edition 2024; MSRV `1.94.0`) — manages Python projects                                      |
| License         | MIT OR Apache-2.0 (dual)                                                                          |
| Repository      | [astral-sh/uv][repo]                                                                              |
| Documentation   | [docs.astral.sh/uv][docs] · [Workspaces concept][ws-doc]                                          |
| Category        | Python Package Manager                                                                            |
| Workspace model | Root-package **or** virtual root (`[tool.uv.workspace]`); single shared `uv.lock` and one `.venv` |
| First released  | February 2024 (`0.1.0`)                                                                           |
| Latest release  | `0.11.19`                                                                                         |

> **Latest release:** `0.11.19` (the version in the checked-out tree's `pyproject.toml` and at the top of `CHANGELOG.md`). uv ships rapid `0.11.x` point releases; workspace mechanics described here are stable since `0.1.x` but have been incrementally extended (e.g. faster large-workspace discovery in `#18311`). uv is **not** a build orchestrator: it has no task DAG or build cache — see [Task Orchestration](#task-orchestration-scheduling) and [Caching](#caching-remote-execution).

---

## Overview

### What it solves

Python's historical packaging stack splits the job across many tools — `pip` (install), `venv`/`virtualenv` (environment), `pip-tools` (lock), `pyenv` (interpreter), `pipx` (tool isolation), `poetry`/`pdm`/`hatch` (project metadata). Each re-implements resolution and caching, and none ships a first-class _monorepo_ story. uv collapses the whole stack into a single static Rust binary that resolves, locks, installs, builds, and runs — fast enough (10-100x `pip`) that re-resolving an entire workspace on every command is cheap.

The monorepo half of uv is its **workspace**: a collection of `pyproject.toml`-defined packages developed together in one repository, sharing **one** `uv.lock` and **one** `.venv`. The design is consciously borrowed from [Cargo][cargo] — the concept doc opens by attributing it directly:

> _"Inspired by the [Cargo] concept of the same name, a workspace is 'a collection of one or more packages, called workspace members, that are managed together.'"_
> — [`docs/concepts/projects/workspaces.md`][ws-doc]

This places uv beside the language-native package managers in this survey — [Cargo][cargo] (Rust), [Go workspaces][go-work], and the other Python contenders [Poetry][poetry] and [Hatch][hatch] — rather than the polyglot task engines ([Nx][nx], [Bazel][bazel]). It is a **dependency-and-environment** tool, not a build scheduler: it has nothing analogous to Turborepo's task pipeline or Bazel's action graph.

### Design philosophy

uv's workspace model rests on a few sharp, opinionated choices, visible directly in the source:

1. **One lockfile for the whole workspace.** `uv lock` resolves every member's dependencies jointly into a single root `uv.lock`, guaranteeing a _consistent_ set of versions across the monorepo. From the concept doc: _"In a workspace, each package defines its own `pyproject.toml`, but the workspace shares a single lockfile, ensuring that the workspace operates with a consistent set of dependencies."_ ([`workspaces.md`][ws-doc]).
2. **One virtual environment.** All members install into the workspace root's `.venv`. This is the explicit limitation that bounds the model: _"Workspaces are not suited for cases in which members have conflicting requirements, or desire a separate virtual environment for each member. In this case, path dependencies are often preferable."_ ([`workspaces.md`][ws-doc]).
3. **Local members are resolved as editable by default.** A `{ workspace = true }` source is installed editable, so edits to one member are visible to its dependents without reinstalling: _"Dependencies between workspace members are editable."_ ([`workspaces.md`][ws-doc]).
4. **Discovery is filesystem-driven and cached.** Members are found by globbing from the root manifest; a `WorkspaceCache` keyed by both root and member path avoids re-parsing `pyproject.toml` files (see [`workspace.rs`][workspace-rs]).
5. **Nested workspaces are forbidden.** A workspace is exactly one level deep — a member may not itself carry a `[tool.uv.workspace]` table.

---

## How it works

A uv workspace is a directory tree of standard [PEP 621][pep621] `pyproject.toml` files plus uv-specific `[tool.uv.*]` tables. The relevant types live in the [`uv-workspace`][workspace-crate] crate:

- `Workspace` — the resolved monorepo: `install_path` (root), a `BTreeMap<PackageName, WorkspaceMember>` of `packages`, the `required_members` (members other members depend on), and the root's merged `sources` and `indexes` tables ([`workspace.rs`][workspace-rs]).
- `ToolUvWorkspace` — the deserialized `[tool.uv.workspace]` table: `members: Option<Vec<SerdePattern>>` and `exclude: Option<Vec<SerdePattern>>`, both lists of globs ([`pyproject.rs`][pyproject-rs]).
- `Source::Workspace { workspace: bool, editable: Option<bool>, … }` — the `{ workspace = true }` cross-reference in `[tool.uv.sources]` ([`pyproject.rs`][pyproject-rs]).

A minimal root manifest declaring a virtual workspace with two member globs:

```toml
# pyproject.toml (workspace root)
[project]
name = "albatross"
version = "0.1.0"
requires-python = ">=3.12"
dependencies = ["bird-feeder", "tqdm>=4,<5"]

[tool.uv.sources]
bird-feeder = { workspace = true }   # resolve locally, not from PyPI

[tool.uv.workspace]
members = ["packages/*"]             # glob of member directories
exclude = ["packages/seeds"]         # globs subtracted from members

[build-system]
requires = ["uv_build>=0.11.19,<0.12"]
build-backend = "uv_build"
```

`uv lock` walks the tree, resolves all members jointly, and writes one `uv.lock` (a TOML document, `VERSION = 1`, carrying a top-level `requires-python` plus a `[[package]]` array — see [`lock/mod.rs`][lock-rs]). `uv sync` materializes the resolution into the root `.venv`. `uv run` executes a command after an implicit `uv sync`.

### Workspace Declaration & Topology

Discovery is **root-up then glob-down**, with the root manifest as the single source of truth.

**Finding the root.** `find_workspace` ([`workspace.rs`][workspace-rs]) walks `project_root.ancestors()` (skipping the project itself) looking for the first `pyproject.toml` that contains a `[tool.uv.workspace]` table _and_ that includes the starting project in its `members` globs (and does not `exclude` it). The walk is bounded by an optional `stop_discovery_at` and deliberately skips the uv cache directory. The doc-comment on `Workspace::find` states the algorithm verbatim:

> _"Steps of workspace discovery: Start by looking at the closest `pyproject.toml`: If it's an explicit workspace root: Collect workspace from this root, we're done. … Otherwise, try to find an explicit workspace root above … If there is no explicit workspace: We have a single project workspace, we're done."_
> — [`crates/uv-workspace/src/workspace.rs`][workspace-rs]

**Two root flavors**, exactly mirroring Cargo:

- **Root-package workspace** — the root `pyproject.toml` has both `[project]` and `[tool.uv.workspace]`; it is _itself_ a member (the common "app + libraries" layout).
- **Virtual (non-project) root** — a root `pyproject.toml` that has `[tool.uv.workspace]` but **no** `[project]` table; it only groups members. The doc-comment notes _"there are two kinds of workspace roots: projects, and non-project roots. The non-project roots lack a `[project]` table."_ ([`workspace.rs`][workspace-rs]).

**Collecting members.** `collect_members_only` ([`workspace.rs`][workspace-rs]) adds the root project (if any), then expands each `members` glob via the `glob` crate against the (escaped) root path:

```rust
// crates/uv-workspace/src/workspace.rs — collect_members_only (abridged)
for member_glob in workspace_definition.members.unwrap_or_default() {
    let absolute_glob = /* escape(root) */ .join(normalize_path(member_glob));
    for member_root in glob(&absolute_glob)? {
        if is_excluded_from_workspace(&member_root, root, def)? { continue; }
        let pyproject = PyProjectToml::from_string(read(member_root.join("pyproject.toml")))?;
        // ... insert WorkspaceMember keyed by project.name
    }
}
```

Members are keyed by `PackageName`; a duplicate name across two directories is a hard error (`DuplicatePackage`). Notable discovery rules from the same function:

- A matched directory **must** contain a `pyproject.toml`, else `MissingPyprojectTomlMember` (unless `MemberDiscovery::Existing` tolerates absent members).
- A member with `tool.uv.managed = false` is silently omitted.
- A member that itself declares `[tool.uv.workspace]` triggers `NestedWorkspace` — **nested workspaces are not supported**.
- Hidden directories and directories containing only git-ignored files (e.g. `__pycache__`) are skipped (`has_only_gitignored_files` runs an `ignore::WalkBuilder` respecting `.gitignore`).
- `exclude` globs are subtracted: _"If a package matches both `members` and `exclude`, it will be excluded."_ ([`pyproject.rs`][pyproject-rs]).

> [!NOTE]
> Topology is **flat and explicit**. There is no recursive auto-discovery of nested workspaces and no inter-member build ordering metadata beyond the dependency graph the resolver computes; the "workspace" is just a set of co-resolved packages, not a target graph.

### Dependency Handling & Isolation

uv uses a **global content-addressed cache** plus **copy-on-write/hardlink materialization** into per-project virtual environments — the same broad strategy as [pnpm][pnpm]'s store, adapted to Python wheels.

**Local cross-references — the `workspace:` protocol.** A member depends on a sibling by naming it in `[project].dependencies` and pointing `[tool.uv.sources]` at the workspace:

```toml
# packages/bird-feeder/pyproject.toml
[project]
name = "bird-feeder"
dependencies = ["seeds"]

[tool.uv.sources]
seeds = { workspace = true }
```

The `{ workspace = true }` entry deserializes to `Source::Workspace { workspace: true, editable, marker, … }` ([`pyproject.rs`][pyproject-rs]). Its docstring: _"A dependency on another package in the workspace. When set to `false`, the package will be fetched from the remote index, rather than included as a workspace package."_ Such members are installed **editable** by default, so source edits propagate without reinstall. This is uv's analogue of [Yarn Berry][yarn-berry]'s `workspace:` protocol and Cargo's path-implied workspace deps.

**Inheritance.** Any `[tool.uv.sources]` defined at the root applies to **all** members unless a member overrides the same key — _"Any `tool.uv.sources` definitions in the workspace root apply to all members, unless overridden in the `tool.uv.sources` of a specific member."_ ([`workspaces.md`][ws-doc]). The root `indexes` table is likewise inherited. (uv does **not**, however, offer Cargo-style `version.workspace = true` field inheritance for arbitrary `[project]` metadata.)

**One environment, one lockfile.** All members share the root `.venv` and `uv.lock`. There is no per-member hoisting decision because there is no per-member environment — the entire workspace is resolved into one flat dependency set.

**Materialization (`LinkMode`).** Resolved wheels are unpacked once into the cache and then linked into the `.venv` according to `LinkMode` ([`uv-fs/src/link.rs`][linkmode-rs]):

```rust
// crates/uv-fs/src/link.rs
pub enum LinkMode {
    Clone,    // copy-on-write (reflink) — DEFAULT on macOS/Linux
    Copy,
    Hardlink, // default on other platforms
    Symlink,
}
impl Default for LinkMode {
    fn default() -> Self {
        if cfg!(any(target_os = "macos", target_os = "ios", target_os = "linux")) {
            Self::Clone   // APFS / btrfs / xfs / bcachefs CoW
        } else {
            Self::Hardlink
        }
    }
}
```

The default `Clone` mode reflinks files from the global cache into each `.venv`, so a package shared across many projects/CI runs occupies disk once and installs near-instantly. The cache itself is bucketed and digest-keyed (e.g. `built-wheels-v0/<digest(index-url)>/foo/foo-1.0.0.zip/…`, `wheel-metadata-v0/url/<digest(url)>/…` — see the bucket docs in [`uv-cache/src/lib.rs`][cache-rs]).

### Task Orchestration & Scheduling

uv has **no task DAG, no targets, and no build/affected scheduler.** It is not a task runner; this dimension largely does not apply.

- **Dependency-graph scheduling exists only inside resolution/installation.** uv builds a `petgraph` resolution graph ([`lock/mod.rs`][lock-rs] imports `petgraph::graph::NodeIndex`) and downloads/builds/installs distributions concurrently (a Tokio async runtime drives parallel network and build work). But this is wheel resolution, not user-defined task orchestration.
- **`uv run` runs a single command**, optionally a PEP 723 inline-script or an entry point, after an implicit sync. There is no `uv run <task>` that fans out over members, no inter-task dependencies, and no change-based skipping. Compare [Turborepo][turborepo]/[Nx][nx], whose entire reason for being is the task DAG uv lacks.
- **No affected/`--since` detection.** uv does not diff git refs to bound work to changed members. The closest thing is that `uv lock` re-resolves the whole workspace (cheaply) and `uv sync` only installs what changed in the lockfile.

> [!IMPORTANT]
> If a uv monorepo needs "build/test all changed packages in topological order", that orchestration must come from an outer tool (a [Makefile][make], [Just][just], [Task][task], or a CI matrix). uv supplies the resolved, consistent environment those tasks run _in_; it does not supply the task graph. This is the single largest gap versus the JS task-orchestrator tier.

### Caching & Remote Execution

uv's caching is a **local, content-addressed wheel/metadata/source cache** — aggressive and central to its speed — but there is **no remote build cache and no remote-execution (REAPI) backend.**

- **Global cache, dedup by digest.** The `Cache` ([`uv-cache/src/lib.rs`][cache-rs]) is a versioned, bucketed directory (`wheel-metadata-v0/`, `built-wheels-v0/`, `archive-v0/`, …) keyed by hashes of index URLs, source URLs, and git SHAs. Built source distributions, downloaded wheels, and parsed metadata are all memoized, so a second resolve/install across projects on the same machine is near-free.
- **Workspace-discovery cache.** Orthogonally, `WorkspaceCache` ([`workspace.rs`][workspace-rs]) caches resolved `Workspace`s by root **and** member path within a single invocation, so the N members of a workspace are each parsed once, not N times (the `#18311` speedup targeted exactly this for large workspaces).
- **CoW install as a cache extension.** Because `LinkMode::Clone`/`Hardlink` shares bytes between the cache and every `.venv`, the cache effectively doubles as the installed-package store (à la [pnpm][pnpm]).
- **No remote cache / no REAPI.** uv has nothing like Turborepo's remote cache, Bazel's `--remote_cache`, or a [Buildbarn][buildbarn]/[BuildBuddy][buildbuddy] backend. The cache is per-machine. (CI typically restores `~/.cache/uv` via the runner's own caching, e.g. `actions/cache`.)

### CLI / UX Ergonomics

The command boundary is **root-broadcast by default, with a targeted `--package` / `--all-packages` selector** — there is no Yarn/pnpm-style `--filter` mini-language.

| Command                         | Default scope               | Selector flags                                       |
| ------------------------------- | --------------------------- | ---------------------------------------------------- |
| `uv lock`                       | **Whole workspace, always** | (no selector — locking is always global)             |
| `uv sync`                       | Workspace root member       | `--package <name>`, `--all-packages`                 |
| `uv run [--package <name>] cmd` | Workspace root member       | `--package <name>`                                   |
| `uv build`                      | Current package             | `--package <name>`, `--all-packages` (`--all` alias) |
| `uv add` / `uv remove`          | Current/`--package` member  | `--package <name>`                                   |
| `uv export`                     | Workspace root              | `--package <name>`, `--all-packages`                 |

From the CLI definitions ([`uv-cli/src/lib.rs`][cli-rs]), `--package` and `--all-packages` are mutually exclusive (`conflicts_with`), and a non-existent member errors out:

```rust
// crates/uv-cli/src/lib.rs — `uv build` selectors (abridged)
/// Build a specific package in the workspace.
#[arg(long, conflicts_with("all_packages"), value_hint = ValueHint::Other)]
pub package: Option<PackageName>,

/// Builds all packages in the workspace.
#[arg(long, alias = "all", conflicts_with("package"))]
pub all_packages: bool,
```

Key ergonomic facts from the docs ([`workspaces.md`][ws-doc]):

- `uv lock` _"operates on the entire workspace at once"_ — you cannot lock one member in isolation.
- `uv run` and `uv sync` _"operate on the workspace root by default, though both accept a `--package` argument, allowing you to run a command in a particular workspace member from any workspace directory."_ So `uv run` ≡ `uv run --package <root>`, and `uv run --package bird-feeder pytest` runs in that member.
- `uv init <path>` inside an existing workspace auto-registers the new package into the root's `members`.

> [!NOTE]
> The selector is a **single package name**, not a predicate. There is no `--filter '...{[origin/main]}'` (pnpm), no `-p` repetition for arbitrary subsets, no `--since <ref>`, and no glob over names. Breadth is "root" or "all"; precision is "exactly one member".

---

## Strengths

- **Speed.** Rust core + global CoW cache makes whole-workspace re-resolution and sync fast enough to run on every command, eliminating "is my lockfile stale?" anxiety.
- **One lockfile, one environment, guaranteed-consistent versions** across the monorepo — no per-member version drift, no lockfile fan-out.
- **Cargo-faithful, low-ceremony workspaces.** `members`/`exclude` globs + `{ workspace = true }` sources are minimal and immediately legible to anyone who knows Cargo.
- **Editable local cross-refs by default** — edit a library, dependents see it instantly; no reinstall, no publish.
- **Root-level `[tool.uv.sources]` / index inheritance** keeps shared upstreams (git deps, private indexes) defined once.
- **Single static binary** that also manages Python interpreters, tools, and PEP 723 scripts — no bootstrap chicken-and-egg.

## Weaknesses

- **No task orchestration whatsoever** — no task DAG, no topological build/test loop, no `--since`/affected detection. Needs an outer runner ([Just][just]/[Task][task]/[Make][make]) for "build changed members in order".
- **One environment for the whole workspace** — members with conflicting transitive requirements cannot coexist; the docs steer such cases to plain path dependencies instead.
- **No remote cache / no REAPI** — caching is per-machine; CI sharing relies on the runner's filesystem-cache step.
- **Single-name selector** — no filter expression language, no arbitrary subsets, no name globs.
- **Nested workspaces forbidden** — exactly one workspace level; very large orgs can't compose sub-workspaces.
- **No metadata-field inheritance** (no `version.workspace = true`); only `sources`/`indexes` are inherited, not arbitrary `[project]` fields.

## Key design decisions and trade-offs

| Decision                                              | Rationale                                                                             | Trade-off                                                                                   |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Single shared `uv.lock` for the whole workspace       | Guarantees a consistent dependency set; locking the monorepo is one cheap operation   | Members cannot have conflicting transitive requirements; can't lock one member in isolation |
| Single shared `.venv` for all members                 | One environment to create/activate; trivial cross-member imports                      | No per-member isolation; conflicting requirements force path-deps instead of a workspace    |
| Glob `members` + `exclude` from a root manifest       | Cargo-familiar, explicit, scales to many packages with one line                       | Flat topology only; nested workspaces explicitly rejected (`NestedWorkspace` error)         |
| `{ workspace = true }` local source, editable default | Edit-a-library-see-it-everywhere; no publish/reinstall loop                           | Editable installs differ subtly from published wheels; can mask packaging bugs              |
| Global content-addressed cache + CoW/hardlink install | Disk-dedup across projects/CI; near-instant installs; cache doubles as package store  | Per-machine only; no remote/REAPI sharing; CoW needs a supporting filesystem                |
| No task DAG / no orchestration                        | Stays a focused package+env manager; resolution is the only graph it owns             | Monorepos must bolt on an external task runner for topological build/test                   |
| `--package` / `--all-packages` (no filter language)   | Tiny, unambiguous selector surface; mutually exclusive flags are easy to reason about | No subsets, no name globs, no `--since`/affected; coarse compared to pnpm/Turborepo filters |

---

## Sample workspace

A minimal, runnable two-member uv workspace lives under [`./sample/`](./sample/): a root-package workspace `albatross` that depends on a library member `bird-feeder` via `{ workspace = true }`, plus a `[tool.uv.workspace]` glob and a PEP 723 task script. See [`sample/pyproject.toml`](./sample/pyproject.toml) for the root manifest and [`sample/packages/bird-feeder/pyproject.toml`](./sample/packages/bird-feeder/pyproject.toml) for the local cross-reference. It would resolve with `uv lock` and run with `uv run greet` / `uv run --package bird-feeder python -c "import bird_feeder"` if the toolchain were installed.

## Sources

- [astral-sh/uv — GitHub repository][repo]
- [uv documentation — docs.astral.sh/uv][docs]
- [Workspaces concept — `docs/concepts/projects/workspaces.md`][ws-doc]
- [`crates/uv-workspace/src/workspace.rs` — `Workspace`, discovery, glob/exclude, nested-workspace error][workspace-rs]
- [`crates/uv-workspace/src/pyproject.rs` — `ToolUvWorkspace`, `Source::Workspace`, `[tool.uv.sources]`][pyproject-rs]
- [`crates/uv-resolver/src/lock/mod.rs` — `uv.lock` format, resolution graph][lock-rs]
- [`crates/uv-cache/src/lib.rs` — content-addressed cache buckets][cache-rs]
- [`crates/uv-fs/src/link.rs` — `LinkMode` (Clone/Hardlink/Copy/Symlink)][linkmode-rs]
- [`crates/uv-cli/src/lib.rs` — `--package` / `--all-packages` selectors][cli-rs]
- [PEP 621 — project metadata in `pyproject.toml`][pep621]
- [Related: Cargo (Rust)][cargo] · [Poetry (Python)][poetry] · [Hatch (Python)][hatch] · [pnpm][pnpm] · [Yarn Berry][yarn-berry] · [Turborepo][turborepo] · [Comparison][comparison] · [D landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/astral-sh/uv
[docs]: https://docs.astral.sh/uv/
[ws-doc]: https://docs.astral.sh/uv/concepts/projects/workspaces/
[workspace-rs]: https://github.com/astral-sh/uv/blob/2937610e418bf5bb8e8922f5c935e67215d4f8c1/crates/uv-workspace/src/workspace.rs
[pyproject-rs]: https://github.com/astral-sh/uv/blob/2937610e418bf5bb8e8922f5c935e67215d4f8c1/crates/uv-workspace/src/pyproject.rs
[lock-rs]: https://github.com/astral-sh/uv/blob/2937610e418bf5bb8e8922f5c935e67215d4f8c1/crates/uv-resolver/src/lock/mod.rs
[cache-rs]: https://github.com/astral-sh/uv/blob/2937610e418bf5bb8e8922f5c935e67215d4f8c1/crates/uv-cache/src/lib.rs
[linkmode-rs]: https://github.com/astral-sh/uv/blob/2937610e418bf5bb8e8922f5c935e67215d4f8c1/crates/uv-fs/src/link.rs
[cli-rs]: https://github.com/astral-sh/uv/blob/2937610e418bf5bb8e8922f5c935e67215d4f8c1/crates/uv-cli/src/lib.rs
[pep621]: https://peps.python.org/pep-0621/
[cargo]: ../cargo/
[poetry]: ../poetry/
[hatch]: ../hatch/
[pnpm]: ../pnpm/
[yarn-berry]: ../yarn-berry/
[turborepo]: ../turborepo/
[nx]: ../nx/
[bazel]: ../bazel/
[buildbarn]: ../buildbarn/
[buildbuddy]: ../buildbuddy/
[go-work]: ../go-work/
[just]: ../just/
[task]: ../task/
[make]: ../make/
[comparison]: ../comparison.md
[d-landscape]: ../../async-io/d-landscape.md
