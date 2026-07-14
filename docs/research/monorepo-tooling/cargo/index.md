# Cargo (Rust)

Rust's official build system and package manager, whose first-class
`[workspace]` model — a single root manifest, one shared `Cargo.lock`, one shared
`target/` directory, and a topologically-scheduled, fingerprint-cached build
graph — is the canonical "language package manager that is also a monorepo
engine," and the most direct precedent for the workspace feature proposed for
`dub`.

| Field           | Value                                                                                               |
| --------------- | --------------------------------------------------------------------------------------------------- |
| Language        | Rust (the tool itself is written in Rust; manifests are TOML)                                       |
| License         | MIT OR Apache-2.0 (dual)                                                                            |
| Repository      | [rust-lang/cargo][repo]                                                                             |
| Documentation   | [The Cargo Book][book] · [doc.rust-lang.org/cargo][book]                                            |
| Category        | Language Package Manager / Build System                                                             |
| Workspace model | Root manifest with a `[workspace]` table; **root-package** _or_ **virtual** workspace; glob members |
| First released  | Cargo 1.0.0 with Rust 1.0 (May 15, 2015); `[workspace]` landed in Rust 1.12 (Sept 2016)             |
| Latest release  | Cargo 1.96.0 (with Rust 1.96.0)                                                                     |

> **Latest release:** Cargo ships in lockstep with the compiler on the six-week
> train, so its version always tracks `rustc`'s. As of June 5, 2026 the latest
> stable is **Cargo 1.96.0** (Rust 1.96.0, released May 28, 2026). All source
> citations below are against the development tree on `master`, which self-reports
> `version = "0.99.0"` in [`Cargo.toml`][repo] (the pre-`1.0`-style internal
> crate version that is renumbered to match the shipping `rustc` at release).

---

## Overview

### What it solves

Cargo unifies three concerns that other ecosystems split across separate tools:
**dependency resolution** (a SAT-style version solver writing a `Cargo.lock`),
**building** (orchestrating `rustc` invocations as a DAG), and **project
organization** (the workspace). A Rust monorepo is not a bolt-on: it is the same
`Cargo.toml` mechanism a single crate uses, extended with one extra table. The
unit of code is a _crate_ (one `rustc` compilation; one `lib` or `bin` target);
the unit of distribution and versioning is a _package_ (one `Cargo.toml`, one or
more targets); and the unit of monorepo grouping is a _workspace_ (one root
`Cargo.toml` with a `[workspace]` table, N member packages).

The workspace exists to make many packages behave like one project. From the
core type's own documentation ([`src/cargo/core/workspace.rs`][ws]):

> _"The core abstraction in Cargo for working with a workspace of crates. A
> workspace is often created very early on and then threaded through all other
> functions. It's typically through this object that the current package is
> loaded and/or learned about."_

Concretely, members of one workspace **share**: a single `Cargo.lock` (one
resolution, no per-package version drift), a single `target/` build directory
(so a library compiled once is reused by every dependent — no redundant local
compilation), the `[patch]`/`[replace]`/`[profile]` tables, and (since Rust 1.64)
an inheritable `[workspace.package]` + `[workspace.dependencies]` registry.

### Design philosophy

Cargo's monorepo design rests on a few load-bearing decisions, all observable in
the source:

1.  **The workspace is discovered, not configured per-invocation.** Running any
    command from anywhere inside the tree walks _up_ the filesystem to find the
    root manifest, then walks _down_ (or globs) to enumerate members.
    `Workspace::new` "will construct the entire workspace by determining the root
    and all member packages … `Ok` is only returned for valid workspaces"
    ([`workspace.rs`][ws]).
2.  **Two topologies, one mechanism.** A workspace root may itself be a buildable
    package (a _root-package workspace_) or a manifest with **only** a
    `[workspace]` table and no `[package]` (a _virtual workspace_). The same
    `WorkspaceRootConfig` drives both.
3.  **One lock, one target dir.** The whole workspace resolves to a single
    `Cargo.lock` (`LOCKFILE_NAME = "Cargo.lock"`, [`ops/lockfile.rs`][lockfile])
    and shares one `target/` (`"None if the default path of root/target should be
used"`, [`workspace.rs`][ws]).
4.  **Change tracking over content addressing.** Cargo decides what to rebuild
    with per-unit _fingerprints_ + filesystem mtimes, **not** a content-addressed
    cache — a deliberate "balance of performance, simplicity, and completeness"
    ([`fingerprint/mod.rs`][fp]).
5.  **No remote execution.** Cargo has a local fingerprint cache and a global
    package cache, but ships **no** remote build cache or [REAPI][reapi] backend;
    remote/shared caching is delegated to external wrappers ([`sccache`][sccache]).

Within this survey Cargo is the reference _language-native_ monorepo: contrast it
with the JS managers ([pnpm], [yarn-berry]) that hoist/symlink a `node_modules`
store, with [go-work]'s lockfile-free multi-module overlay, and with the polyglot
engines ([bazel], [buck2]) that add content-addressed remote caching Cargo lacks.
For the D analogue under improvement see [`dub`][d-landscape].

---

## How it works

A Cargo invocation proceeds: **discover** the workspace → **resolve**
dependencies into `Cargo.lock` → **build the unit graph** → **schedule & execute**
it with fingerprint-driven freshness. The five dimensions below trace each stage.

### Workspace declaration & topology

The declaration surface is a single `[workspace]` table. A **virtual workspace**
has no `[package]` at all:

```toml
# Cargo.toml (virtual workspace root)
[workspace]
resolver = "3"
members = ["crates/*", "apps/*"]
exclude = ["crates/experimental"]
default-members = ["apps/cli"]
```

A **root-package workspace** is a normal package that _also_ carries the table:

```toml
# Cargo.toml (root is itself a buildable package)
[package]
name = "app"
version = "0.1.0"

[workspace]
members = ["crates/*"]
```

`members`, `default-members`, and `exclude` are all glob-capable arrays of path
patterns. They are held in `WorkspaceRootConfig` ([`workspace.rs`][ws]):

```rust
// src/cargo/core/workspace.rs
pub struct WorkspaceRootConfig {
    root_dir: PathBuf,
    members: Option<Vec<String>>,
    default_members: Option<Vec<String>>,
    exclude: Vec<String>,
    inheritable_fields: InheritableFields,
    custom_metadata: Option<toml::Value>,
}
```

**Discovery is bidirectional.** `Workspace::new` calls `find_root` then
`find_members`. `find_root` checks whether the invoked manifest _is_ a root, and
otherwise walks ancestors via `find_workspace_root_with_loader` until it finds a
`[workspace]` whose `members`/`exclude` claim this path. `find_members` then
materializes the membership ([`workspace.rs`][ws]):

> _"If the `workspace.members` configuration is present, then this just verifies
> that those are all valid packages to point to. Otherwise, this will
> transitively follow all `path` dependencies looking for members of the
> workspace."_

So membership is the **union** of two sources: the explicit (globbed) `members`
list, _and_ the transitive closure of `path = "..."` dependencies reachable from
the root (`find_path_deps`). A package can be a member implicitly just by being a
`path` dependency of another member. Globs are expanded by `members_paths` →
`expand_member_path`, which delegates to the `glob` crate and then filters to
directories (so a stray `.DS_Store` is not mistaken for a member):

```rust
// src/cargo/core/workspace.rs — expand_member_path (abridged)
let res = glob(path).with_context(|| format!("could not parse pattern `{}`", &path))?;
```

`exclude` subtracts paths from that union, with the subtlety (encoded in
`is_excluded`) that an _explicitly_ listed member always wins over an `exclude`
prefix match. `default-members` selects the subset that bare commands act on when
neither `--workspace` nor `-p` is given; for a virtual workspace with no
`default-members`, the default is **all** members.

### Dependency handling & isolation

Cargo does **not** isolate per-package dependency trees the way the JS world does;
there is no hoisting, no symlink farm, no virtual store. Instead the **entire
workspace resolves together** into a single `Cargo.lock`. One version of each
`(name, source)` is chosen for the whole graph (subject to semver-compatible
de-duplication), so two members can never silently use two patch versions of the
same crate — the source of "version drift" the proposal aims to kill in `dub`.

Three mechanisms make members reference each other and shared upstreams cleanly:

1.  **Local path dependencies.** A member depends on a sibling with a relative
    `path`:

    ```toml
    [dependencies]
    greeter = { path = "../greeter" }
    ```

    Such a dependency is a normal edge in the build graph; the sibling is compiled
    once into the shared `target/` and reused. Because the resolver follows
    `path` deps, the sibling is automatically pulled into membership.

2.  **The central dependency registry** (`[workspace.dependencies]`, Rust 1.64+).
    Declare a dependency _once_ at the root, then each member opts in with
    `dep.workspace = true`:

    ```toml
    # root Cargo.toml
    [workspace.dependencies]
    serde = { version = "1", features = ["derive"] }
    greeter = { path = "crates/greeter" }
    ```

    ```toml
    # member Cargo.toml
    [dependencies]
    serde.workspace = true          # version + features inherited from root
    greeter.workspace = true        # the path is inherited too
    ```

    `InheritableFields::get_dependency` ([`util/toml/mod.rs`][toml]) resolves the
    name against the root table, and for a `path` dependency **rewrites the path
    relative to the member** — _"update the path to be relative to the workspace
    root instead."_ This is Cargo's equivalent of Yarn's `workspace:` protocol.

3.  **Field inheritance** (`[workspace.package]`). Metadata fields are inherited
    with `field.workspace = true`. The inheritable set is fixed in
    `InheritableFields` ([`util/toml/mod.rs`][toml]):

    ```rust
    // src/cargo/util/toml/mod.rs — package_field_getter! (abridged)
    ("authors", authors -> Vec<String>),  ("edition", edition -> String),
    ("license", license -> String),       ("repository", repository -> String),
    ("rust-version", rust_version -> RustVersion), ("version", version -> semver::Version),
    // ...also categories, description, documentation, homepage, keywords, publish, ...
    ```

> [!NOTE]
> Isolation in Cargo is achieved at the _resolution_ layer (one lock, one chosen
> version per crate), not at the _filesystem_ layer (no per-package store). This
> is the opposite end of the spectrum from [pnpm]'s content-addressed
> `node_modules` and [yarn-berry]'s zero-installs PnP — and a much closer fit to
> what a compiled language like D needs.

### Task orchestration & scheduling

Cargo builds a **DAG of "units"** and executes it concurrently. A unit
([`core/compiler/unit.rs`][unit]) is one `rustc`/build-script/doc invocation —
roughly a `(package, target, profile, features, kind)` tuple. Units are connected
by `unit_dependencies` into a graph, then handed to the job queue.

The scheduler is `JobQueue` ([`job_queue/mod.rs`][jq]). Its own header states the
model plainly:

> _"This module implements a job queue. A job here represents a unit of work,
> which is roughly a rustc invocation, a build script run, or just a no-op. …
> Spawns concurrent jobs … Controls the number of concurrency. It allocates and
> manages [jobserver] tokens to each spawned off rustc and build scripts."_

Ordering is a `DependencyQueue` ([`util/dependency_queue.rs`][dq]) — a graph that
only releases a node once all its dependencies have finished:

> _"A graph-like structure used to represent a set of dependencies and in what
> order they should be built … to figure out when a dependency should be built."_

Priority is cost-based: when the graph is finalized, each node's priority is the
sum of its own cost plus the transitive cost of its dependencies, so long
critical-path chains start first (`queue_finished` / `dequeue`,
[`dependency_queue.rs`][dq]). The job-queue docs are candid that "the current
scheduling algorithm is not really polished … the cost is just passed as a fixed
placeholder," with future PGO-style historical-timing prioritization noted as an
idea.

Concurrency is governed by a GNU-make-compatible **jobserver**: Cargo is one
process handing out N tokens (`-j N` / `--jobs`, default = CPU count) to many
`rustc` children, so build scripts that shell out to `make` cooperate on the same
token pool — _"the jobserver relationship among Cargo and rustc processes is
**1 cargo to N rustc**."_ Cargo also **pipelines**: a dependent can start as soon
as its dependency emits its `.rmeta` (metadata) file, before the dependency's
`.rlib` (codegen) is finished, overlapping compilation along the DAG
([`compiler/mod.rs`][compiler]).

**Change detection** is the `Fingerprint` ([`fingerprint/mod.rs`][fp]). Each unit
is "dirty" or "fresh"; a fresh unit is skipped:

```rust
// src/cargo/core/compiler/job_queue/job.rs
pub enum Freshness {
    Fresh,
    Dirty(DirtyReason),
}
```

A fingerprint is a hash (persisted in `target/.../.fingerprint/`) over rustc
version, profile, compile mode, target kind, enabled+declared features, immediate
dependency fingerprints, `RUSTFLAGS`, the `[lints]` table, source mtimes, and
more (a full matrix is tabulated in [`fingerprint/mod.rs`][fp]). A change in any
dependency's fingerprint propagates "dirty" upward through the DAG, and source
mtimes are compared against a dep-info anchor file. This is _affected-package
detection_, but driven by hashes + mtimes rather than VCS diffs.

### Caching & remote execution

Cargo has **two** local caches and **no** native remote execution:

1.  **The build cache** is the shared `target/` directory plus its
    `.fingerprint/` metadata. Reuse is per-unit: a member library compiled once is
    not recompiled for the next dependent in the same `target/`. This is local and
    machine-specific; mtimes make it non-portable.
2.  **The global package cache** under `CARGO_HOME` (`~/.cargo`): the registry
    index, downloaded `.crate` source tarballs, and git checkouts, shared across
    _all_ workspaces on the machine. A SQLite-backed `GlobalCacheTracker`
    ([`global_cache_tracker.rs`][gct]) records last-use timestamps and sizes to
    drive automatic garbage collection of stale downloads — _"Tracking of cache
    files is stored in a sqlite database which contains a timestamp of the last
    time the file was used, as well as the size of the file."_

> [!IMPORTANT]
> There is **no remote/shared build cache and no remote-execution** in Cargo
> itself. The fingerprint model is explicitly _not_ content-addressed — the
> source notes that "hashing file contents, tracking every file access … would
> ensure more reliable and reproducible builds at the cost of being complex,
> slow, and platform-dependent" ([`fingerprint/mod.rs`][fp]). Shared/remote
> caching is achieved out-of-tree by setting `build.rustc-wrapper` to
> [`sccache`][sccache], which can back onto S3/GCS/Redis. This is the single
> biggest gap versus [bazel]/[buck2]/[turborepo] (and the [nativelink]/[buildbarn]
> [REAPI][reapi] backends), and a deliberate one.

### CLI / UX ergonomics

Cargo's command boundary for monorepos is a small, consistent set of
**package-selection flags** layered on every build-like subcommand
(`build`, `check`, `test`, `bench`, `doc`, `run`, `publish`). They are defined
once in `command_prelude.rs` ([`command_prelude.rs`][cli]) and reduce to four
states in the `Packages` enum ([`ops/cargo_compile/packages.rs`][pkgsel]):

| Flag form                        | `Packages` variant   | Selects                                            |
| -------------------------------- | -------------------- | -------------------------------------------------- |
| _(none)_                         | `Packages::Default`  | `default-members` (all members for a virtual root) |
| `-p <spec>` / `--package <spec>` | `Packages::Packages` | hand-picked members (repeatable; globs allowed)    |
| `--workspace` (alias `--all`)    | `Packages::All`      | every member                                       |
| `--workspace --exclude <spec>`   | `Packages::OptOut`   | every member minus the excluded specs              |

```rust
// src/cargo/ops/cargo_compile/packages.rs — from_flags (abridged)
pub fn from_flags(all: bool, exclude: Vec<String>, package: Vec<String>) -> CargoResult<Self> {
    Ok(match (all, exclude.len(), package.len()) {
        (false, 0, 0) => Packages::Default,
        (false, 0, _) => Packages::Packages(package),
        (false, _, _) => bail!("--exclude can only be used together with --workspace"),
        (true, 0, _)  => Packages::All(package),
        (true, _, _)  => Packages::OptOut(exclude),
    })
}
```

So the developer ergonomics are: **global broadcast** with `--workspace`,
**targeted selection** with `-p` (e.g. `cargo test -p greeter`), and
**subtractive selection** with `--workspace --exclude`. `-p` accepts a
`PackageIdSpec` (a name, or `name@version`, or a URL), and bare patterns expand
against the member list. The `-j/--jobs N` and `--keep-going` flags
([`command_prelude.rs`][cli]) tune concurrency and failure behavior.

Cargo has **no built-in `--filter`-by-glob, no `--since <git-ref>`
affected-package selection, and no topological `foreach`**: there is no
`cargo workspaces foreach`-style loop in core (that role is filled by the
third-party [`cargo-workspaces`][cargo-workspaces] / [`cargo-hakari`] plugins).
Custom workflows are usually wired up as **aliases** in `.cargo/config.toml` or as
an [`xtask`][xtask]-pattern member binary:

```toml
# .cargo/config.toml
[alias]
ci = ["test", "--workspace"]
```

---

## Sample workspace

A minimal, runnable two-member workspace lives under [`./sample/`](./sample/). It
demonstrates every dimension above in ~40 lines of TOML:

- a **virtual** root (`Cargo.toml` with only `[workspace]`, `resolver = "3"`,
  `members = ["crates/*"]`, `default-members = ["crates/cli"]`);
- a **central registry** (`[workspace.dependencies]`) and **field inheritance**
  (`[workspace.package]` consumed by members via `version.workspace = true`);
- a **local cross-reference**: `cli` depends on the sibling `greeter` via
  `greeter.workspace = true`, whose `path = "crates/greeter"` is declared once at
  the root;
- a **task**: a `.cargo/config.toml` `[alias]` (`cargo ci` → `cargo test
--workspace`).

`cargo test --workspace` (or `cargo ci`) builds `greeter` once, reuses it for
`cli`, and runs both members' tests in topological order. `cargo run -p cli --
Cargo` runs just the binary.

---

## Strengths

- **Workspaces are native and zero-ceremony.** One extra `[workspace]` table
  turns N packages into a coherent monorepo — same manifest format, no separate
  tool. Glob `members` scale to large trees.
- **One lock, one resolution, no drift.** A single `Cargo.lock` for the whole
  workspace guarantees every member sees the same version of every crate.
- **Shared `target/` eliminates redundant local compilation.** A local library is
  compiled once and reused by every dependent in the workspace.
- **First-class DAG scheduling with pipelining + jobserver.** Concurrent,
  cost-prioritized, `.rmeta`-pipelined builds that cooperate with `make` on
  parallelism tokens.
- **Field + dependency inheritance** (`[workspace.package]` /
  `[workspace.dependencies]`) keeps versions and metadata DRY.
- **Consistent, minimal selection flags** (`-p`, `--workspace`, `--exclude`) on
  every subcommand.
- **Automatic GC of the global cache** via a SQLite last-use tracker.

## Weaknesses

- **No remote/shared build cache, no remote execution.** Reuse stops at the local
  `target/`; sharing CI cache requires external [`sccache`][sccache]. No
  [REAPI][reapi] story (cf. [bazel], [buck2], [nativelink]).
- **mtime-based freshness is fragile and non-portable.** Fingerprints depend on
  filesystem mtimes; clock skew, container layer copies, and checkout order cause
  spurious rebuilds or (rarely) missed ones. Content hashing is unstable-only
  (`checksum-freshness`).
- **No affected-package / `--since` selection.** Cargo can't natively scope a
  build to "members changed since `git ref`" the way [turborepo]/[nx] do; you
  rebuild what fingerprints say is dirty, not what a diff says is touched.
- **No topological `foreach` or per-member task pipeline.** Custom multi-step
  workflows live in `.cargo/config.toml` aliases or `xtask` binaries, not in a
  declarative task graph.
- **One global jobserver, scheduling is admittedly "rudimentary."** The cost
  heuristic is a placeholder; no historical-timing prioritization yet.
- **Whole-workspace resolution is all-or-nothing.** You cannot have two
  incompatible major versions of a build-time tool across members without
  `[patch]` gymnastics.

## Key design decisions and trade-offs

| Decision                                               | Rationale                                                               | Trade-off                                                                       |
| ------------------------------------------------------ | ----------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Workspace = one extra `[workspace]` table              | No new file format/tool; monorepo is an extension of the single crate   | Discovery must walk up _and_ down the tree; implicit `path`-dep membership      |
| Root-package **or** virtual root, one mechanism        | Supports both "app + its libs" and "pure library collection" layouts    | Two modes to document; virtual roots have no buildable target of their own      |
| Single shared `Cargo.lock` + `target/`                 | One resolution (no drift); compile each local lib exactly once          | Whole-workspace lock is all-or-nothing; can't hold two incompatible majors      |
| `[workspace.dependencies]` + `field.workspace = true`  | DRY versions/metadata; central upgrade point; Yarn-`workspace:`-like    | Only a fixed set of fields is inheritable; indirection when reading a member    |
| Fingerprint + mtime freshness (not content-addressed)  | Fast, simple, "good enough" change detection without hashing every file | Fragile to clock skew/container copies; not reproducible; no portable cache key |
| Local `target/` cache only, no remote execution        | Keeps Cargo simple and platform-independent                             | No shared CI cache / REAPI; punts remote caching to `sccache` and wrappers      |
| DAG + jobserver + `.rmeta` pipelining                  | Saturate cores; cooperate with `make`; overlap metadata/codegen         | Cost model is a placeholder; one global jobserver; "rudimentary" scheduling     |
| Four selection states (`-p`/`--workspace`/`--exclude`) | Small, consistent command boundary on every subcommand                  | No `--filter` globs, no `--since` diff selection, no built-in `foreach`         |

---

## Sources

- [rust-lang/cargo][repo] — source for all quoted file paths (tree on `master`,
  internal `version = "0.99.0"`)
- [The Cargo Book][book] — workspaces, manifest, dependency, and config reference
- [`src/cargo/core/workspace.rs`][ws] — `Workspace`, `WorkspaceRootConfig`,
  `find_root`/`find_members`, glob `members_paths`
- [`src/cargo/util/toml/mod.rs`][toml] — `InheritableFields`, `[workspace.package]`
  field getters, `[workspace.dependencies]` path rewriting
- [`src/cargo/core/compiler/job_queue/mod.rs`][jq] — the job queue, jobserver,
  scheduling model
- [`src/cargo/util/dependency_queue.rs`][dq] — the topological `DependencyQueue`
- [`src/cargo/core/compiler/fingerprint/mod.rs`][fp] — freshness, fingerprints,
  mtime tracking
- [`src/cargo/core/compiler/job_queue/job.rs`][job] — the `Freshness` enum
- [`src/cargo/core/global_cache_tracker.rs`][gct] — SQLite global-cache GC
- [`src/cargo/ops/cargo_compile/packages.rs`][pkgsel] — the `Packages` selection enum
- [`src/cargo/util/command_prelude.rs`][cli] — `-p`/`--workspace`/`--exclude`/`-j` flags
- [`src/cargo/ops/lockfile.rs`][lockfile] — `LOCKFILE_NAME = "Cargo.lock"`
- The runnable [sample workspace](./sample/)
- Related deep-dives: [pnpm] · [yarn-berry] · [go-work] · [bazel] · [buck2] ·
  [turborepo] · [nx] · [nativelink] · [buildbarn] · [`dub` (D)][d-landscape]

<!-- References -->

[repo]: https://github.com/rust-lang/cargo
[book]: https://doc.rust-lang.org/cargo/
[ws]: https://github.com/rust-lang/cargo/blob/877ff64d694ae967badcf9b6a629619e6fe5e0db/src/cargo/core/workspace.rs
[toml]: https://github.com/rust-lang/cargo/blob/877ff64d694ae967badcf9b6a629619e6fe5e0db/src/cargo/util/toml/mod.rs
[jq]: https://github.com/rust-lang/cargo/blob/877ff64d694ae967badcf9b6a629619e6fe5e0db/src/cargo/core/compiler/job_queue/mod.rs
[dq]: https://github.com/rust-lang/cargo/blob/877ff64d694ae967badcf9b6a629619e6fe5e0db/src/cargo/util/dependency_queue.rs
[fp]: https://github.com/rust-lang/cargo/blob/877ff64d694ae967badcf9b6a629619e6fe5e0db/src/cargo/core/compiler/fingerprint/mod.rs
[job]: https://github.com/rust-lang/cargo/blob/877ff64d694ae967badcf9b6a629619e6fe5e0db/src/cargo/core/compiler/job_queue/job.rs
[compiler]: https://github.com/rust-lang/cargo/blob/877ff64d694ae967badcf9b6a629619e6fe5e0db/src/cargo/core/compiler/mod.rs
[unit]: https://github.com/rust-lang/cargo/blob/877ff64d694ae967badcf9b6a629619e6fe5e0db/src/cargo/core/compiler/unit.rs
[gct]: https://github.com/rust-lang/cargo/blob/877ff64d694ae967badcf9b6a629619e6fe5e0db/src/cargo/core/global_cache_tracker.rs
[pkgsel]: https://github.com/rust-lang/cargo/blob/877ff64d694ae967badcf9b6a629619e6fe5e0db/src/cargo/ops/cargo_compile/packages.rs
[cli]: https://github.com/rust-lang/cargo/blob/877ff64d694ae967badcf9b6a629619e6fe5e0db/src/cargo/util/command_prelude.rs
[lockfile]: https://github.com/rust-lang/cargo/blob/877ff64d694ae967badcf9b6a629619e6fe5e0db/src/cargo/ops/lockfile.rs
[jobserver]: https://github.com/rust-lang/jobserver-rs
[sccache]: https://github.com/mozilla/sccache
[xtask]: https://github.com/matklad/cargo-xtask
[cargo-workspaces]: https://github.com/pksunkara/cargo-workspaces
[cargo-hakari]: https://github.com/guppy-rs/guppy/tree/2deddd390245dfa226dc5acf3a46f3d2eb38f2e5/tools/cargo-hakari
[reapi]: https://github.com/bazelbuild/remote-apis
[pnpm]: ../pnpm/
[yarn-berry]: ../yarn-berry/
[go-work]: ../go-work/
[bazel]: ../bazel/
[buck2]: ../buck2/
[turborepo]: ../turborepo/
[nx]: ../nx/
[nativelink]: ../nativelink/
[buildbarn]: ../buildbarn/
[d-landscape]: ../../async-io/d-landscape.md
