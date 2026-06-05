# Just (Polyglot)

A single-binary, `make`-inspired **command runner** written in Rust — it saves
and runs project-specific commands from a `justfile`, deliberately omitting the
build-system machinery (file timestamps, change detection, artifact caching) so
that it stays a thin, polyglot orchestration layer rather than a workspace or
package manager.

| Field           | Value                                                                                                                       |
| --------------- | --------------------------------------------------------------------------------------------------------------------------- |
| Language        | Rust (the binary); recipes are shell — `sh`/`bash`/`pwsh`/`python`/any interpreter                                          |
| License         | CC0-1.0 (public-domain dedication)                                                                                          |
| Repository      | [casey/just][repo]                                                                                                          |
| Documentation   | [just.systems/man/en][manual] (the Programmer's Manual) · [`just(1)`][man1]                                                 |
| Category        | Generic Task Runner                                                                                                         |
| Workspace model | **No native workspace concept;** a "monorepo" is a root `justfile` that declares `mod` submodules (a recipe namespace tree) |
| First released  | `0.0.0` (Oct 23, 2016); `1.0.0` (Oct 2021)                                                                                  |
| Latest release  | `1.51.0` (May 10, 2026)                                                                                                     |

> **Latest release:** `1.51.0`, published **May 10, 2026** ([releases][releases]).
> `just` is firmly in its `1.x` line and intends to stay there — the README
> states there _"will never be a `just` 2.0."_ The recent `1.4x`–`1.5x` minors
> added the scheduling and layout primitives most relevant to this survey:
> the **`[parallel]`** recipe attribute (run a recipe's dependencies
> concurrently, `1.42.0`), the **`[working-directory: …]`** recipe attribute and
> **`set working-directory`** setting, and a `no-cd` setting (`1.51.0`). The
> **modules** feature (`mod` statements) was introduced in `1.19.0` and
> stabilized (on by default) in **`1.31.0`**. Source citations below are against
> the official manual and the GitHub repository as of June 5, 2026.

---

## Overview

### What it solves

`just` occupies the niche its README states in one line ([`README.md`][readme]):

> _"`just` is a handy way to save and run project-specific commands."_

It is a direct descendant of `make` that keeps `make`'s one genuinely good
ergonomic idea — _"a file of named, parameterized commands you invoke by name,
some of which depend on others"_ — and discards the rest. The README is explicit
about the boundary it draws ([`README.md`][readme]):

> _"`just` is a command runner, not a build system, so it avoids much of
> `make`'s complexity and idiosyncrasies. No need for `.PHONY` recipes!"_

That single sentence is the most important fact about `just` for this survey.
Because it is **not** a build system, `just` has, by deliberate design, **none**
of the four mechanisms that define the rest of this catalog:

- it does **not** track file timestamps or hashes (`make`'s prerequisite model
  is gone — every recipe is effectively `.PHONY`);
- it does **not** maintain a dependency graph of _files_, only of _recipes_;
- it does **not** cache, store, or replay build artifacts; and
- it does **not** resolve, lock, hoist, or isolate package dependencies.

It is squarely a member of the **generic task runner** family alongside
[Task (go-task)][task], [mise][mise], and [Make][make]: it orchestrates
_commands_, not _packages_, and it is the **glue layer** of a polyglot monorepo,
not its workspace engine. Where [Task][task] adds a content-aware
`sources`/`generates` fingerprint on top of the command DAG, `just` does not even
do that — a `just` recipe runs **every** time it is invoked. The value `just`
adds over a folder of shell scripts is: named, documented, parameterized recipes;
recipe dependencies; per-recipe working directories; `.env` loading; cross-shell
portability; tab-completion; and a `mod` namespace tree for large repos.

For a polyglot D monorepo (the lens of this survey — see [the D landscape][d-landscape]),
`just` is the outer-loop driver: a root `justfile` whose recipes shell out to
`dub build`, `dub test`, `cargo build`, `npm ci`, etc., one `mod` per
sub-component. The actual package resolution, lockfile, and isolation are owned
by each language's native tool ([Cargo][cargo], [uv][uv], [pnpm][pnpm]) and the
heavy build engines ([Bazel][bazel], [Buck2][buck2]); `just` only **names and
orders** the commands that drive them.

### Design philosophy

Three principles, all visible in the manual and the README, shape the tool:

1. **A command runner, not a build system.** This is the founding constraint,
   repeated throughout the docs. `just` intentionally rejects the timestamp /
   prerequisite / artifact model so that there is no `.PHONY`, no stale-file
   class of bug, no hidden rebuild logic — a recipe is "a name for a sequence of
   commands," nothing more.

2. **Stability is a feature; no `2.0`.** From the README ([`README.md`][readme]):

   > _"There will never be a `just` 2.0. Any desirable backwards-incompatible
   > changes will be opt-in on a per-`justfile` basis, so users may migrate at
   > their leisure."_

   New behavior arrives behind `set`-tings and recipe attributes rather than as
   breaking format changes, so a `justfile` written years ago still runs.

3. **Convention from `make`, ergonomics from a real language.** Syntax is
   `make`-flavored (`recipe: dependency` then a TAB-or-space-indented body), but
   recipes get real parameters with defaults, string functions, conditionals,
   `[attributes]`, doc comments surfaced in `--list`, and arbitrary interpreter
   shebangs (a recipe can be a Python or Node script, not just shell). The result
   is "a Makefile you actually want to read," which is the entire pitch.

Within this survey `just` is the canonical _"minimal command runner with **no**
change detection and **no** cache"_ data point — one notch below [Task][task]
(which adds fingerprinting) and far below [moon][moon] / [Turborepo][turborepo] /
[Bazel][bazel] (project graph, content-addressed cache, affected-detection).

---

## How it works

A `just` project is anchored by a `justfile` (or `.justfile`; `Justfile` and
other casings are also recognized) in the project root. Running `just` with no
arguments runs the **default recipe** (the first recipe in the file, or one
marked `[default]`). Running `just RECIPE` runs that recipe after its
dependencies; `just RECIPE ARG…` passes positional arguments.

```just
# justfile — recipes, dependencies, parameters, variables

set dotenv-load                     # load .env into the recipe environment

version := "0.4.1"                  # a `:=` assignment (evaluated once)

# build the project (the default recipe — first in the file)
build:
    dub build :core-cli

# run the test suite; `build` is a prior dependency, runs first
test: build
    dub test :core-cli

# a parameterized recipe with a default argument
tag VERSION=version:
    git tag "v{{VERSION}}"
```

The grammar's load-bearing pieces:

- **Recipes** are `name PARAM…: DEP…` followed by an indented body. Body lines
  are run by the configured shell (`sh -cu` by default; change with
  `set shell := ["bash", "-uc"]` or a per-recipe shebang `#!/usr/bin/env bash`).
- **<span v-pre>`{{…}}`</span> interpolation** substitutes variables, parameters,
  function calls, and backtick command output into recipe lines and string literals.
- **Variables** are `name := expression`, evaluated once when the `justfile` is
  loaded; `export name := …` (or `set export`) puts them in the recipe
  environment as `$name`.
- **Attributes** `[…]` decorate a recipe (`[private]`, `[group: 'ci']`,
  `[confirm]`, `[no-cd]`, `[working-directory: 'subdir']`, `[parallel]`,
  `[linux]`/`[macos]`/`[windows]`, …).
- **`set` settings** at file top configure behavior (`shell`, `dotenv-load`,
  `export`, `fallback`, `working-directory`, `positional-arguments`, …).

The full per-tool analysis answers the five survey dimensions below.

---

## Workspace declaration & topology

`just` has **no first-class workspace, project, or member concept** — like
[Task][task], and this is the defining fact for this survey. There is no
`[workspace]` block, no `members = […]` glob, no project graph, no member
metadata. What `just` _does_ provide for structuring a large repo is the
**modules** feature: a `justfile` declares submodules with `mod` statements,
forming a **recipe namespace tree**.

```just
# repo-root justfile — a module tree, NOT a workspace
mod core-cli                # loads ./core-cli.just OR ./core-cli/mod.just OR ./core-cli/justfile
mod versions                # one mod per sub-component
mod? experimental          # optional: no error if its source file is missing
mod docs 'website'         # custom path: load the module from ./website/
```

The manual specifies the resolution order for `mod bar` exactly
([modules][mod-doc]): `just` searches, in order, **`bar.just`**, then
**`bar/mod.just`**, then **`bar/justfile`**, then **`bar/.justfile`** (the latter
two allowing any capitalization). A `?` makes the module **optional**
(`mod? foo` — a missing source file is not an error), and `mod foo 'PATH'` loads
from a custom location (with `~/` home-expansion). Doc comments on `mod`
statements appear in `--list` output:

```just
# core CLI utilities       <- this becomes the module's --list description
mod core-cli
```

Submodule recipes are addressed either as **subcommands** (`just core-cli build`)
or with **path syntax** (`just core-cli::build`); modules nest arbitrarily
(`just a::b::c`). This is the closest thing `just` has to a monorepo topology —
and it is purely a **command namespace**, carrying none of the package-graph
semantics that `members = [...]` does in [Cargo][cargo] or `packages:` does in
[pnpm][pnpm].

> [!IMPORTANT]
> **Module discovery is explicit, never glob-based.** Every sub-component is
> enumerated by hand with a `mod` line — there is no `mod libs/*` wildcard,
> unlike [Cargo][cargo]'s `members = ["libs/*"]`, [pnpm][pnpm]'s `packages:`
> globs, or [moon][moon]'s `projects` globs. Adding a sub-package to the repo
> means adding a `mod` line to the root `justfile`. This (shared with
> [Task][task]'s hand-enumerated `includes`) is the single largest gap between a
> command runner and a true workspace tool.

> [!NOTE]
> **Working directory is the one real topology semantic.** A submodule's recipes
> run with the working directory set to **the directory containing the module's
> source file** (unless the recipe carries `[no-cd]`). So `mod core-cli` loading
> `libs/core-cli/justfile` will run `core-cli`'s recipes inside
> `libs/core-cli/`. The `justfile()` and `justfile_directory()` functions,
> however, _always_ reference the **root** `justfile`. This per-module `cd` is
> the analogue of [moon][moon] anchoring each task to its project root — and a
> meaningful improvement over [Task][task]'s default of running an included
> file's tasks in the **caller's** directory.

`set fallback := true` adds an upward-search dimension: if the first recipe named
on the command line isn't found in the nearest `justfile`, `just` searches
**parent directories** for one that has it ([settings][settings]) — a lightweight
way to invoke a repo-root recipe from inside a sub-component directory without a
`mod` reference.

---

## Dependency handling & isolation

This dimension **barely applies**, and saying so plainly is the honest answer for
a command runner. `just` does **not** resolve packages, does **not** hoist,
symlink, or maintain a virtual store, has **no lockfile**, and has **no notion of
one member depending on a sibling member's _package_**. Every package concern is
delegated to whatever tool a recipe shells out to.

- **Dependency installation is a delegated recipe.** A `justfile` recipe shells
  out to `dub upgrade`, `cargo fetch`, `npm ci`, `uv sync`, etc. `just`'s job is
  to **name and order** these commands, not to perform resolution. The isolation
  model is entirely whatever the underlying manager provides.

- **There is no `workspace:`-protocol equivalent.** Cross-member ordering is
  expressed purely as **recipe ordering** — "build `core-cli` before
  `versions`" — through `mod` plus recipe dependencies. The dependency is a
  **recipe edge**, not a package edge: `just` guarantees the prior recipe runs
  first, but linking one D sub-package against another's artifact is `dub`'s
  concern (a `path=` dependency in `dub.sdl`), exactly as a `replace` directive in
  `go.mod` or a `path =` in `Cargo.toml` would carry it elsewhere.

  ```just
  # repo-root justfile — cross-member ordering is a recipe dependency
  mod core-cli
  mod versions

  # `versions` depends on `core-cli` being built first
  build-versions: (build-member 'core-cli')
      dub build :versions

  build-member NAME:
      dub build :{{NAME}}
  ```

- **Config "inheritance" is variables + `.env`, not dependency versions.** A
  root `justfile`'s variables and `set dotenv-load`/`dotenv-path` propagate into
  recipes, and the manual notes that environment files loaded in a **parent
  module are inherited by submodules** (a submodule's own `.env` may override
  parent values). This is a lightweight version of the centralized-config story
  that [Cargo][cargo]'s `[workspace.package]` inheritance provides — but for
  **shell variables and environment**, never for a shared dependency-version
  registry.

> [!WARNING]
> Because `just` has no package model at all, **version drift across members is
> entirely the user's problem.** There is no central `[workspace.dependencies]`
> table, no unified lockfile, and no resolver to deduplicate a library two
> members both depend on — every concern that [Cargo][cargo]'s and
> [Yarn Berry][yarn-berry]'s workspace dependency registries solve is out of
> scope. `just` is the layer that _invokes_ the resolver, not the resolver.

---

## Task orchestration & scheduling

This is the dimension where `just` has real, if minimal, mechanics — and where
the recent `1.4x`–`1.5x` releases moved the needle.

**The recipe DAG.** A recipe declares **prior dependencies** after a colon and
**subsequent dependencies** after `&&` ([dependencies][deps-doc]):

```just
# `b` runs first (prior), then this recipe's body, then `c` and `d` (subsequent)
a: b && c d
    echo 'A!'
```

Running `just a` topologically sorts the recipe graph: prior dependencies run
before the recipe body, subsequent dependencies after it. Dependencies may take
arguments (`recipe: (dep 'arg')`). The manual specifies the crucial **run-once**
guarantee verbatim ([dependencies][deps-doc]):

> _"A recipe with the same arguments will only run once, regardless of how many
> times it appears in the command-line invocation, or how many times it appears
> as a dependency."_

So a shared `setup` dependency of many recipes is performed exactly once per
invocation — but, critically, **only when arguments match**: a parameterized
`test TEST: build` invoked as `just test foo test bar` runs `build` once and the
test recipe twice. Cyclic dependencies are rejected at parse time.

**Concurrency.** Historically `just` ran a recipe's dependencies **serially**, in
declared order — there was no `make -j`. That changed with the **`[parallel]`**
recipe attribute, added in `1.42.0` ([releases][releases]): the changelog line is
exactly _"Add `[parallel]` attribute to run dependencies in parallel."_

```just
# the three build-* dependencies run concurrently, then this body runs
[parallel]
build-all: build-core build-versions build-math
    @echo "all members built"
```

This is recipe-scoped, opt-in parallelism of a single recipe's **dependencies**
(later refined in `1.47.1` to "block on running parallel dependencies"). There is
no global `-j N` job-count flag and no automatic cross-recipe parallelism — the
unit of concurrency is "the dependencies of one `[parallel]` recipe," which is a
narrower and more explicit model than [Task][task]'s "`deps` always run in
parallel" default or [make][make]'s repo-wide `-j`.

> [!IMPORTANT]
> **`just` has no change detection whatsoever.** This is the headline difference
> from every build-system-shaped tool in this survey, including the otherwise
> similar [Task][task]. There is **no `sources`/`generates` fingerprint**, no
> mtime check, no content hash — a recipe runs **every** time it is invoked, even
> if nothing changed. Skipping work is the user's job: a recipe must shell out to
> its own staleness check (`git diff --quiet`, a marker file, the underlying
> tool's own incremental build). `just` is `.PHONY` all the way down by design.

> [!IMPORTANT]
> **No Git-aware affected-detection.** There is nothing like
> [moon][moon]'s / [Turborepo][turborepo]'s / [Nx][nx]'s `--affected <ref>` that
> computes "which members changed since `main`." Restricting a monorepo run to
> "what changed" must be hand-built — typically a recipe that runs
> `git diff --name-only` and dispatches `just <module>::build` per changed path.

`--no-deps` runs a recipe **without** its dependencies (the manual: _"Don't run
recipe dependencies"_) — useful when a prerequisite was already satisfied
out-of-band. `--dry-run` / `-n` prints the commands a run would execute without
running them.

---

## Caching & remote execution

`just` has **no caching and no remote execution — at all.** This is the
single sharpest contrast with the build engines in this survey, and it is a
direct consequence of "command runner, not build system":

- **No artifact cache.** `just` stores nothing between runs. It does not record
  which recipe ran, does not hash inputs, does not archive `generates` outputs
  (there is no `generates` concept), and cannot "replay" a previous result.
  Contrast [Turborepo][turborepo] / [moon][moon] / [Bazel][bazel], which store
  outputs keyed by a content hash and replay them on a cache hit.

- **No skip-cache either.** Unlike [Task][task] — which at least keeps a
  per-directory `.task/` of source **checksums** to _skip_ unchanged commands —
  `just` keeps no state directory and performs no up-to-date check. Every recipe
  body executes on every invocation.

- **No remote cache, no REAPI, no remote execution.** There is no
  content-addressable store, no Bazel Remote-Execution-API client, no
  shared-team cache, and no notion of executing a recipe on a remote worker.
  The remote-execution backends in this survey ([Buildbuddy][buildbuddy],
  [Buildbarn][buildbarn], [NativeLink][nativelink]) have no `just` integration
  point because `just` produces no cacheable, content-addressed actions.

The practical consequence for a monorepo: any incrementality must come from the
**tool a recipe invokes** — `dub`'s own object-file reuse, `cargo`'s incremental
compilation, a `ccache` wrapper — never from `just` itself. `just` is a faithful
dispatcher; whether a dispatched command is fast on the second run is entirely
that command's concern.

> [!NOTE]
> This is not a deficiency `just` aspires to fix — it is the boundary the project
> draws on purpose. Teams that need cross-machine artifact caching pair `just`
> with a tool that has it (`just ci:` shells out to [moon][moon] /
> [Turborepo][turborepo] / [Bazel][bazel]), or accept that `just` is the
> human-facing **command vocabulary** and the cache lives one layer down.

---

## CLI / UX ergonomics

`just`'s command boundary is `just [OPTIONS] [RECIPE] [ARGS…]`. There is no
global-vs-targeted split to learn: you name the recipe (optionally module-scoped)
you want and pass trailing arguments. Selection is **explicit naming**, not graph
filtering.

| Invocation                       | Meaning                                                                    |
| -------------------------------- | -------------------------------------------------------------------------- |
| `just`                           | Run the **default** recipe (first in the file, or `[default]`-marked)      |
| `just test`                      | Run the `test` recipe (and its dependencies) in the current `justfile`     |
| `just --no-deps test`            | Run `test` **without** running its dependencies                            |
| `just core-cli build`            | Run the `build` recipe of the `core-cli` **module** (subcommand form)      |
| `just core-cli::build`           | The same, in explicit **path** form (`MODULE::RECIPE`)                     |
| `just tag 0.4.1`                 | Run `tag` passing `0.4.1` as its positional argument                       |
| `just --set VERSION 0.4.1 tag`   | Override the `VERSION` variable, then run `tag`                            |
| `just --list` / `-l`             | List recipes (with their doc comments and `[group: …]` headings)           |
| `just --list core-cli`           | List the recipes of the `core-cli` module                                  |
| `just --summary`                 | Print recipe names only (space-separated; for scripting/completion)        |
| `just --choose`                  | Pick recipes to run via an interactive binary chooser (`fzf`-style)        |
| `just --show test` / `-s`        | Print the source of the `test` recipe                                      |
| `just --evaluate`                | Evaluate and print all variables (no recipe runs)                          |
| `just --variables`               | Print variable names only                                                  |
| `just --fmt`                     | Format the `justfile` in place (`--fmt --check` for a CI lint gate)        |
| `just --dump --dump-format json` | Dump the parsed `justfile` as JSON (machine-readable introspection)        |
| `just -d DIR -f FILE`            | Use `DIR` as the working directory (requires `--justfile`/`-f` too)        |
| `just -g RECIPE`                 | Run a recipe from the user's **global** `justfile` (cross-project helpers) |
| `just -n` / `--dry-run`          | Print the commands without executing                                       |
| `just --yes`                     | Auto-confirm recipes carrying the `[confirm]` attribute                    |

Module namespacing gives the monorepo ergonomics: `just --list` from the root
shows recipes grouped by module (and by `[group: …]`), and
`just core-cli::test versions::test` runs a hand-picked subset. The selection
model is **explicit enumeration** — there is **no `--filter <glob>`, no
`-p <project>` package selector, and no `--affected`/`--since` graph slicing**.
"Test everything" is written as an aggregator recipe that depends on each module's
test recipe (optionally `[parallel]`). Compare [Turborepo][turborepo]'s
`--filter`, [pnpm][pnpm]'s `--filter`, [moon][moon]'s `:task` broadcast +
`--query`, or [Cargo][cargo]'s `-p` / `--workspace` — none of which `just`
offers natively.

> [!NOTE]
> `just`'s ergonomic win is the inverse of its filtering weakness: a contributor
> needs to learn essentially nothing beyond `just --list` and `just <name>`.
> There are no graph flags, no project selectors, no cache config, no daemon.
> Tab-completions ship for the major shells, and `--choose` turns the recipe
> list into an interactive menu. For small-to-medium monorepos that simplicity is
> the feature; for large ones the lack of `--filter`/`--affected` and any change
> detection becomes the bottleneck.

---

## Strengths

- **One static Rust binary, zero runtime deps.** No Node, JVM, Python, or plugin
  install; the same `justfile` runs on Linux, macOS, Windows, and the BSDs.
- **Dead-simple, stable mental model.** `just --list` + `just <name>` is the
  entire UX; the "no `just` 2.0" promise means `justfile`s don't rot.
- **Genuinely polyglot glue.** Every recipe is just shell (or an arbitrary
  interpreter via shebang), so D, Rust, Python, JS, and shell coexist with no
  language assumptions — the ideal _outer_ loop for a heterogeneous monorepo.
- **Real recipes, not Makefile cruft.** Parameters with defaults, string
  functions, conditionals, `[attributes]`, doc comments in `--list`, `.env`
  loading, and per-recipe interpreters — far more readable than `make`.
- **A module namespace tree** (`mod`) with per-module working directories,
  optional modules (`mod?`), custom paths, and `MODULE::RECIPE` addressing gives
  a workable large-repo structure.
- **Useful built-in tooling:** `--fmt`/`--check` (formatter + CI lint gate),
  `--dump --dump-format json` (machine-readable introspection), `--choose`
  (interactive picker), `--dry-run`, and `[confirm]`/`--yes` guards.
- **Per-recipe `[parallel]`** gives explicit, opt-in concurrency of a recipe's
  dependencies without a global `-j` foot-gun.

## Weaknesses

- **No workspace model.** Members are enumerated by hand with `mod`; there is
  **no glob discovery**, no project graph, no member metadata.
- **No change detection — none.** Every recipe runs every time; there is no
  `sources`/`generates` fingerprint (so it is _below_ even [Task][task] here),
  no mtime check, no content hash. Skipping work is hand-built.
- **No caching and no remote execution.** No artifact cache, no skip-cache, no
  REAPI, no remote workers — incrementality must come from the invoked tool.
- **No dependency resolution, lockfile, or isolation.** Everything package-
  related is delegated to the native managers; cross-member linkage is a recipe
  edge, not a package edge; version drift is the user's problem.
- **No graph-filtering ergonomics.** No `--filter`/`-p`/`--affected`/`--since`;
  selection is explicit naming plus aggregator recipes.
- **Concurrency is narrow.** `[parallel]` parallelizes only one recipe's direct
  dependencies; there is no global job count and no automatic cross-recipe
  parallelism.
- **Modules are still maturing.** The manual itself notes modules are _"missing a
  lot of features, for example, the ability to refer to variables in other
  modules."_

## Key design decisions and trade-offs

| Decision                                                           | Rationale                                                                               | Trade-off                                                                                        |
| ------------------------------------------------------------------ | --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Command runner, **not** a build system (no timestamps/`.PHONY`)    | Eliminates `make`'s prerequisite/stale-file complexity; every recipe is trivially "run" | No change detection at all; every recipe re-runs; incrementality is the invoked tool's job       |
| No artifact cache, no remote execution                             | Tiny, stateless, no cache server or daemon to run; faithful dispatcher                  | No artifact replay; no shared/remote cache; no REAPI; large repos pay full cost every run        |
| `mod` namespace tree instead of a workspace/project model          | Reuses one mechanism to split a `justfile` and to compose a monorepo                    | Members enumerated by hand (no glob); no package graph, member metadata, or discovery            |
| Per-module working directory (recipes `cd` into the module dir)    | Each member's commands resolve paths relative to that member automatically              | A genuine improvement over [Task][task], but `justfile()`/`_directory()` still point at the root |
| Recipe DAG with run-once-per-arguments dependencies                | Shared setup runs exactly once; deterministic prior/`&&`-subsequent ordering            | Run-once is keyed on arguments; parameterized deps can re-run; no file-level prerequisites       |
| `[parallel]` attribute (opt-in, per-recipe dependency parallelism) | Explicit concurrency where wanted; no surprising global `-j` behavior                   | Narrow: only one recipe's direct deps; no global job count; no cross-recipe auto-parallelism     |
| Explicit recipe naming on the CLI (no `--filter`/`--affected`)     | Trivial mental model: `just --list` + `just <name>`                                     | Doesn't scale to large graphs; "run what changed"/subset selection must be hand-built            |
| No package resolver / lockfile (delegate to native managers)       | Stays a runner; polyglot by construction; nothing to resolve or lock                    | No unified lockfile, no isolation, no `workspace:`-protocol; version drift is the user's problem |
| "There will never be a `just` 2.0" (opt-in behavior changes)       | Long-term `justfile` stability; no churn-driven migrations                              | New capabilities arrive as settings/attributes, never as cleaner format breaks                   |

---

## Sources

- [casey/just — GitHub repository][repo] (source for the quoted README positioning; CC0-1.0, written in Rust)
- [Just Programmer's Manual][manual] — the canonical reference
  - [Modules][mod-doc] — `mod` statements, resolution order (`bar.just` → `bar/mod.just` → `bar/justfile`), `mod?`, custom paths, `MODULE::RECIPE`, per-module working directory, "missing a lot of features" caveat
  - [Recipe Dependencies][deps-doc] — prior (`:`) vs subsequent (`&&`) deps, the run-once-per-arguments guarantee (quoted), serial-by-default ordering
  - [Settings][settings] — `set fallback`, `set working-directory`, `set dotenv-load`/`dotenv-path`, `set shell`, `set export`
- [`just(1)` man page][man1] — full CLI flag set: `--list`/`-l`, `--summary`, `--choose`, `--no-deps`, `--fmt`/`--check`, `--dump`/`--dump-format`, `--show`/`-s`, `--evaluate`, `--working-directory`/`-d`, `--global-justfile`/`-g`, `--dry-run`/`-n`, `--yes`, `--set`, and `MODULE::RECIPE` syntax
- [Releases][releases] — `1.51.0` (May 10, 2026); `[parallel]` attribute added in `1.42.0` (quoted changelog line); modules stabilized in `1.31.0`
- Related generic runners: [Task (go-task)][task] · [mise][mise] · [Make][make]
- Contrast with cache/graph tools: [moon][moon] · [Turborepo][turborepo] · [Nx][nx] · [Bazel][bazel] · [Buck2][buck2] · remote backends [Buildbuddy][buildbuddy] / [Buildbarn][buildbarn] / [NativeLink][nativelink]
- Contrast with package/workspace managers: [Cargo][cargo] · [uv][uv] · [pnpm][pnpm] · [Yarn Berry][yarn-berry] · [the D landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/casey/just
[readme]: https://github.com/casey/just/blob/master/README.md
[manual]: https://just.systems/man/en/
[man1]: https://man.archlinux.org/man/extra/just/just.1.en
[mod-doc]: https://just.systems/man/en/modules.html
[deps-doc]: https://just.systems/man/en/dependencies.html
[settings]: https://just.systems/man/en/settings.html
[releases]: https://github.com/casey/just/releases
[task]: ../task/
[mise]: ../mise/
[make]: ../make/
[moon]: ../moon/
[turborepo]: ../turborepo/
[nx]: ../nx/
[bazel]: ../bazel/
[buck2]: ../buck2/
[buildbuddy]: ../buildbuddy/
[buildbarn]: ../buildbarn/
[nativelink]: ../nativelink/
[cargo]: ../cargo/
[uv]: ../uv/
[pnpm]: ../pnpm/
[yarn-berry]: ../yarn-berry/
[d-landscape]: ../../async-io/d-landscape.md
