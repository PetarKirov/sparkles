# dub (D) — the baseline (system under improvement)

A grounding analysis of D's `dub` package manager and build tool **as it exists today**, read directly from the upstream source tree — the "system under improvement" against which every other tool in this catalog is measured and into which the [proposal][proposal] feeds.

| Field            | Value                                                                                |
| ---------------- | ------------------------------------------------------------------------------------ |
| Language         | D (the tool is written in D; targets D projects)                                     |
| License          | MIT (`LICENSE.txt`)                                                                  |
| Repository       | [dlang/dub][repo]                                                                    |
| Documentation    | [dub.dpldocs.info / dub-docs][docs] · package registry at [code.dlang.org][registry] |
| Category         | Language package manager / build system (baseline)                                   |
| Workspace model  | **None** — single root package + nested sub-packages; no first-class workspace       |
| Recipe formats   | `dub.sdl` (SDLang) or `dub.json` (one per package)                                   |
| Lockfile         | `dub.selections.json` (per root project; optionally `inheritable`)                   |
| Version analyzed | `v1.42.0-beta.1` line (commit `5efed360`, 2026-05-31)                                |

> **Last reviewed:** June 5, 2026.

> [!NOTE]
> This is a _baseline / reference_ doc, not a third-party deep-dive. It maps `dub`'s current architecture against the [five research dimensions][concepts] this catalog uses, names real types and file paths from the cloned `dlang/dub` and `dlang/dub-docs` trees, and ends with an honest gap analysis. The running example throughout is the **Sparkles** repository itself (`libs/core-cli`, `libs/versions`, `libs/test-utils`, `libs/math`, `apps/ci`) — a real five-package D project built with the sub-package mechanism. For how `dub` compares to the consensus tooling, see the [comparison][comparison]; for the concrete enhancement plan, see the [proposal][proposal].

---

## Overview

`dub` is D's de-facto package manager and build tool: it resolves dependencies against [code.dlang.org][registry], drives the compiler (`dmd`/`ldc2`/`gdc`), and is the entry point virtually every D project builds through. Its unit of organization is the **package** — a directory containing one recipe file, either `dub.sdl` (SDLang) or `dub.json`. The recipe is parsed into a single `PackageRecipe` struct ([`source/dub/recipe/packagerecipe.d`][rec]) whose _only mandatory field is `name`_:

> _"Name of the package, used to uniquely identify the package. This field is the only mandatory one."_ — `PackageRecipe.name` ([`packagerecipe.d`][rec])

For a single library or application this model is clean and well-trodden. The friction this catalog studies appears the moment a repository holds **several** interdependent packages — exactly the Sparkles layout. `dub` has _one_ facility for that case: **sub-packages**. There is no `[workspace]` block, no virtual root, no member globbing, no shared lockfile by default, and no cross-package task graph. A grep of the entire `dub` source and docs trees for the word "workspace" or "monorepo" returns **zero matches** — the concept simply does not exist in the tool's vocabulary today.

The rest of this document reads `dub`'s actual model from source, walks the Sparkles repo through it, then evaluates the five dimensions and the gaps.

---

## How dub works today

### The sub-package model

A package may declare **sub-packages** — smaller components versioned together with their parent. The recipe field is a plain array ([`packagerecipe.d`][rec]):

```d
// source/dub/recipe/packagerecipe.d
/// Sub-packages path or definitions
@Optional SubPackage[] subPackages;
```

Each `SubPackage` is _either_ a path to a sub-folder containing its own recipe, _or_ a recipe embedded inline ([`packagerecipe.d`][rec]):

```d
// source/dub/recipe/packagerecipe.d — SubPackage.fromConfig
if (p.node.type == Node.Type.Mapping)
    return SubPackage(null, p.parseAs!PackageRecipe);   // inline recipe
else
    return SubPackage(p.parseAs!string);                // path to sub-folder
```

The `dub-docs` reference is explicit about the semantics — and about the central limitation:

> _"Sub-packages can be declared individually within the same project, rather than needing to maintain and publish multiple packages on a registry. **All sub-packages share the same versioning as the root package**, acting like regular individual packages on their own."_ — [`subpackages.md`][subdocs]

That single sentence is the load-bearing constraint. Sub-packages are not co-equal members of a workspace; they are _components of one versioned root package_. A sub-package is addressed as `<package>:<sub-package>` or, when the root is implied, just `:<sub-package>` — the `:` prefix that pervades the Sparkles build commands (`dub test :core-cli`).

### Recipes — `dub.sdl` and the Sparkles root

The Sparkles root recipe is a near-minimal sub-package aggregator. Its entire `dub.sdl`:

```sdl
name "sparkles"
description "D library"
authors "Petar Kirov"
copyright "Copyright © 2023, Petar Kirov"
license "BSL-1.0"

targetPath "build"

subPackage "libs/core-cli"
subPackage "libs/test-utils"
subPackage "libs/math"
subPackage "libs/versions"
subPackage "apps/ci"
```

Each `subPackage "libs/core-cli"` is the _path form_: it points at a sub-folder that holds its own `dub.sdl`. The root package `sparkles` exists almost solely to enumerate the five members — but note it is still a **real package** in `dub`'s eyes (it has a `name`, a `targetPath`, and could carry its own sources and dependencies). There is no notion of a "virtual" root that merely groups members without being buildable itself; the root is always a package.

### Dependencies — three kinds, one `SumType`

A dependency in `dub` is a `Dependency` whose value is a three-way sum ([`source/dub/dependency.d`][dep]):

```d
// source/dub/dependency.d
struct Dependency {
    private alias Value = SumType!(VersionRange, NativePath, Repository);
    private Value m_value = Value(VersionRange.Invalid);
    // ...
}
```

The three kinds map exactly to how packages reference each other:

| Kind           | Recipe syntax                                                  | Resolves to                                         |
| -------------- | -------------------------------------------------------------- | --------------------------------------------------- |
| `VersionRange` | `dependency "expected" version="~>0.4.1"`                      | registry (or any local source path) by SemVer match |
| `NativePath`   | `dependency "sparkles:core-cli" path="../.."`                  | a package on disk at a relative path                |
| `Repository`   | `dependency "x" repository="git+https://…" version="<commit>"` | a git checkout pinned to a tag or commit            |

In a monorepo the **path dependency** is the workhorse for local cross-references. Sparkles' `libs/versions/dub.sdl` depends on its sibling like this:

```sdl
configuration "library" {
    targetType "library"
    dependency "sparkles:core-cli" path="../.."
}
```

The `path="../.."` does _not_ point at `libs/core-cli/`; it points at the **repo root**, because `core-cli` is a _sub-package of `sparkles`_, and `dub` resolves the `:core-cli` sub-package name through the root recipe found at `../..`. This is the manual, depth-sensitive wiring the Sparkles `AGENTS.md` documents as a table of `path` values per file location (`libs/*/dub.sdl` → `../..`, `libs/*/examples/*.d` → `../../..`, `docs/guidelines/*.d` → `../..`). Every cross-reference is a hand-maintained relative path; there is no `workspace:` protocol that says "resolve this name to a local member, wherever it lives."

> [!WARNING]
> Because in-repo files use `path=` while published `README.md` examples must use `version="*"` (end users lack the repo layout), the same dependency is expressed two different ways depending on context. Keeping the two in sync is a manual, error-prone chore that a workspace model would eliminate — the `README` keeps `version="*"`, while `libs/*/dub.sdl` keeps `path="../.."`.

### Selections — the per-package lockfile

`dub` records resolved versions in `dub.selections.json`, its lockfile equivalent ([`source/dub/recipe/selection.d`][sel]):

> _"The selections file, commonly known by its file name `dub.selections.json`, is used by Dub to store resolved dependencies. Its purpose is identical to other package managers' lock file."_ — [`selection.d`][sel]

The format is a flat map of package name → selected version (or `path`/`repository`):

```json
{
  "fileVersion": 1,
  "versions": {
    "expected": "0.4.1",
    "silly": "1.1.1"
  }
}
```

The critical fact for monorepos: **the selections file is written for the root project only**, and the writer comments say so directly ([`source/dub/packagemanager.d`][pm], `writeSelections`):

> _"The selections file is only used for the root package / project."_ — [`packagemanager.d`][pm]

But "root project" means _whatever package `dub` was invoked on_. When you run `dub test :core-cli`, `dub` loads `core-cli` as the working package and writes/reads selections accordingly. The upshot in Sparkles is a **fragmented set of five lockfiles** — one per sub-package that has ever been built standalone:

```
libs/core-cli/dub.selections.json
libs/test-utils/dub.selections.json
libs/math/dub.selections.json
libs/versions/dub.selections.json
apps/ci/dub.selections.json
```

There is no `dub.selections.json` at the Sparkles root at all. Each member resolves `expected`/`silly` independently, and nothing structurally prevents drift between them.

### The one nod toward sharing: `inheritable`

The selections type does carry a single workspace-adjacent feature — an `inheritable` flag ([`selection.d`][sel]):

```d
// source/dub/recipe/selection.d — Selections!1
/// Whether this dub.selections.json can be inherited by nested projects
/// without local dub.selections.json
@Optional public bool inheritable;
```

When resolving, `dub` walks _up_ the directory tree looking for a selections file, and an ancestor's file is used **only if it is marked `inheritable`** ([`source/dub/packagemanager.d`][pm], `readSelections` / `findSelections`):

```d
// source/dub/packagemanager.d — readSelections (abridged)
// check for dub.selections.json in root project dir first, then walk up its
// parent directories and look for inheritable dub.selections.json files
const path = this.findSelections(absProjectPath);
// ...
// Non-inheritable selections found
if (!path.startsWith(absProjectPath) && !selections.get().inheritable)
    return N.init;
```

This is the closest `dub` comes to a shared root lockfile: place an `inheritable: true` `dub.selections.json` at the repo root and nested members _can_ inherit it. But it is opt-in, undocumented in the reference, not generated by any `dub` command, and does **not** unify resolution — each member still resolves its own graph; the inherited file only supplies versions a member did not pin locally. Sparkles does not use it (it has no root selections file).

### A real walkthrough — building Sparkles

Putting the pieces together, here is what actually happens for the Sparkles layout (per `AGENTS.md`):

```bash
dub build :core-cli        # build the core-cli sub-package
dub test  :versions        # test versions (which path-depends on :core-cli)
dub --root /path/to/wt test :core-cli   # operate on another worktree
```

1. `dub build :core-cli` loads the **root** `sparkles` package to discover sub-packages, then via `getSubPackage(rootPackage, "core-cli", …)` ([`source/dub/commandline.d`][cli]) switches the working package to `core-cli` and builds _it_ as if it were the root.
2. `dub test :versions` does the same for `versions`. Because `versions` path-depends on `:core-cli`, `dub` resolves and **recompiles `core-cli` again** for this build — there is no shared "already built `core-cli`" artifact reused across the two invocations beyond the content-addressed package cache (below).
3. There is no command that says "build/test _all_ members." The Sparkles `apps/ci` helper exists precisely to fill that hole: it iterates the sub-packages and runs `dub test` for each (`nix run .#ci -- --test`). That orchestration lives in hand-written D, _outside_ `dub`.

---

## The five dimensions

### 1. Workspace declaration & topology

There is **no workspace primitive.** The only multi-package construct is `subPackages`, an explicit array of paths (or inline recipes) inside a single root recipe ([`packagerecipe.d`][rec]). Consequences:

- **No globbing.** You cannot write `members = ["libs/*", "apps/*"]` the way [Cargo][cargo] or [pnpm][pnpm] do; every member is listed by hand (the five `subPackage` lines above).
- **No virtual root.** The root is always a buildable package, never a stateless manifest that merely groups members.
- **One-level nesting only.** A deprecation notice in source states it outright: _"This function is not supported as subpackages cannot be nested"_ ([`packagerecipe.d`][rec]). Sub-packages of sub-packages are disallowed.
- **Discovery is the root recipe.** Members are whatever the root's `subPackages` array enumerates — there is no filesystem scan for member recipes (that role belongs to the separate, machine-global `dub add-path` search-path mechanism, not to the project).

### 2. Dependency handling & isolation

Local cross-references are expressed as **path dependencies** (`path="../.."`) or the implicit `:subpkg` sub-package reference; upstream dependencies are version ranges resolved against the registry. There is no hoisting and no virtual store — D has no per-package `node_modules`-style install tree; resolved packages live in a shared user/system cache (`$DUB_HOME/packages/`). Isolation characteristics:

- **No unified resolution across members.** Each member resolves and locks its own graph into its own `dub.selections.json`; nothing reconciles `expected` across `core-cli` and `versions`. Version drift is structurally possible.
- **`dub upgrade` is per-root.** The upgrade command loads the root, upgrades it, then — only with `-s`/`--sub-packages` — loops over path-based sub-packages **creating a fresh `Dub` instance for each** ([`source/dub/commandline.d`][cli]):

  > _"…we have to use separate Dub instances, because the upgrade always works on the root package of a project, which in this case are the individual sub packages."_

  That comment is the architectural admission: `dub` has no concept of resolving a _set_ of packages together. It re-enters its single-root machinery N times.

- **Git-based local development** is handled out-of-band by `dub add-path` / `dub add-local`, which register on-disk package directories machine-wide so they shadow registry fetches ([`dependencies.md`][depdocs]). This is global mutable state, not a per-repo workspace declaration. The Sparkles `README` workflow even depends on this: _"To verify them against your working tree, `dub add-local <repo>` first."_

### 3. Task orchestration & scheduling

`dub` has **no task graph beyond a single package's compile/link DAG.** The commands are per-package verbs: `build`, `run`, `test`, `lint`, `generate`, `clean`, `describe` ([`commandline.d`][cli]). Within one build, `dub` does topologically order a package's _dependencies_ (link order is preserved — _"preserve topological sorting of dependencies for correct link order"_, [`generator.d`][gen]) and can parallelize compilation **at the source-file level** (`srcs.parallel(1)` under `settings.parallelBuild`, [`build.d`][build]). But:

- **No cross-member task.** There is no `dub build --all` / `dub test --workspace`. Building every Sparkles member means five invocations (or the bespoke `ci` helper that loops them).
- **No user-defined tasks / pipelines.** `dub` cannot model "lint → build → test" with `dependsOn` edges, the way [Nx][nx], [Turborepo][turbo], or [Gradle][gradle] do. Pre/post hooks exist per package (`preBuildCommands`, etc.) but they are shell strings, not graph nodes.
- **No change-detection-driven slicing.** There is no `--since <ref>` to bound work to changed members + dependents; every run reconsiders the full target.
- Orchestration across members is therefore **uncoordinated scripts** — in Sparkles, the `apps/ci` D program and the Nix flake's `ci` package.

### 4. Caching & remote execution

`dub` _does_ have a real, content-addressed **local build cache** — this is its genuine strength and worth stating honestly. `computeBuildID` ([`generator.d`][gen]) hashes the full build inputs (versions, debug versions, `dflags`, `lflags`, import paths, architecture, compiler binary + version, build options, package path) into a stable id like `library-debug-Z7qINYX4IxM8muBSlyNGrw`, and artifacts are stored under `targetCacheDir = packageCache/build/<buildId>` with a `db.json` index and an `isUpToDate` timestamp/dep-file check ([`build.d`][build]). A rebuild with identical inputs is served from cache (`any_cached`).

What it lacks:

- **No remote cache, no REAPI.** The cache is purely local to one machine's `$DUB_HOME`. There is nothing like Bazel/Turborepo/Nx remote caching or a [REAPI][concepts] backend; CI cannot pull a teammate's or a previous run's artifacts.
- **Cache is per-package, not workspace-aware.** The id keys on one package's inputs; there is no notion of "this member is unchanged, skip its whole subtree" at the workspace level.
- **Redundant local recompilation across invocations.** Building `:core-cli` then `:versions` (which depends on it) does reuse the package cache _if_ the build id matches — but configuration differences (e.g. the `unittest` config adds `silly`, extra `dflags`) produce different build ids, so the same source gets recompiled per configuration. The Sparkles `dflags` blocks (per-config `-checkaction=context -allinst`, `-ftime-trace`) guarantee distinct ids between `library` and `unittest` builds.
- **No remote execution.** All compilation runs locally; there is no distribution of build actions to a farm.

### 5. CLI / UX ergonomics

The developer boundary is the `:subpkg` selector plus `--root`:

| Mechanism             | Source                                              | Meaning                                                                    |
| --------------------- | --------------------------------------------------- | -------------------------------------------------------------------------- |
| `:<sub-package>`      | `loadSpecificPackage` ([`commandline.d`][cli])      | operate on a named sub-package of the implied root (`dub test :core-cli`)  |
| `<pkg>:<sub>`         | `getSubPackage` ([`commandline.d`][cli])            | fully-qualified sub-package reference                                      |
| `--root <path>`       | `args.getopt("root", …)` ([`commandline.d`][cli])   | _"Path to operate in instead of the current working dir"_                  |
| `--recipe <file>`     | `args.getopt("recipe", …)` ([`commandline.d`][cli]) | load a non-default recipe path                                             |
| `-s`/`--sub-packages` | `UpgradeCommand` ([`commandline.d`][cli])           | the **only** flag that fans an operation out across sub-packages (upgrade) |

This is serviceable for one-at-a-time work — `dub test :versions`, or `dub --root /path/to/worktree test :core-cli` to operate on another checkout without `cd`. But there is **no filter/selection vocabulary** for operating on _multiple_ members: no `--filter <glob>`, no `-p <member>` repeatable selector, no `--recursive`/`--from`/`--since` graph traversal, no "all members" broadcast. The `-s` upgrade flag is a one-off; it is not a general slicing model. Compared to [Cargo's][cargo] `-p`/`--workspace`, [Yarn Berry's][yarn] `workspaces foreach`, or [pnpm's][pnpm] `--filter`, `dub`'s multi-package CLI surface is essentially "loop it yourself."

---

## Gap analysis — what dub lacks

Measuring `dub` against the consensus monorepo feature set this catalog documents, the unoccupied space is concrete and large:

| Dimension                       | dub today                                                  | Consensus (Cargo/pnpm/Nx/…)                                | Gap                                                                              |
| ------------------------------- | ---------------------------------------------------------- | ---------------------------------------------------------- | -------------------------------------------------------------------------------- |
| **Workspace declaration**       | `subPackages` array; no globbing; root is always a package | `[workspace] members = ["libs/*"]`; virtual roots          | No `[workspace]` block, no member globbing, no virtual (non-buildable) root      |
| **Local cross-references**      | manual `path="../.."` + `:subpkg`; depth-sensitive         | `workspace:` protocol; resolve-by-name to local member     | No local-first protocol; hand-maintained relative paths that drift vs. published |
| **Unified lockfile**            | one `dub.selections.json` per member; root none            | single root lockfile resolving all members together        | Fragmented per-member lockfiles; version drift structurally possible             |
| **Shared config / inheritance** | none (only the obscure `inheritable` selections flag)      | `version.workspace = true`, `[workspace.dependencies]`     | No metadata or dependency-version inheritance from a root                        |
| **Cross-member tasks**          | none; per-package verbs + bespoke scripts                  | task DAG with `dependsOn`; topological `foreach`           | No `dub build --workspace`; orchestration is uncoordinated external scripts      |
| **Target slicing / filters**    | `:subpkg`, `--root`, one-off `upgrade -s`                  | `--filter`, `-p`, `--recursive`, `--from`, `--since <ref>` | No multi-member selection or change-based slicing                                |
| **Caching**                     | local content-addressed package cache (real, good)         | local **plus** remote/REAPI content-addressed cache        | No remote cache; cache is per-package, not workspace-aware                       |
| **Remote execution**            | none                                                       | REAPI backends (Bazel/Buck2 family)                        | No distributed build                                                             |

The honest summary: `dub` already has the two _hard_ primitives a workspace needs — a working dependency resolver and a solid content-addressed local build cache — but it has **no organizing concept above the single package.** Every multi-package capability in Sparkles today (looping tests across the five members, keeping `expected`/`silly` versions aligned, building dependents after their local libraries) is bolted on _outside_ `dub`: in `apps/ci`, in the Nix flake, and in hand-maintained `path=` strings and per-member lockfiles. The deficits cluster into four addressable themes — **(1)** structural workspace layout (a `[workspace]` block + unified lockfile), **(2)** config/dependency inheritance, **(3)** topological multi-member task routing with filter ergonomics, and **(4)** change-tracking and remote caching. Those themes are exactly the milestone structure of the [proposal][proposal], and the cross-tool evidence for each lives in the [comparison][comparison].

---

## Sources

- [dlang/dub — GitHub repository][repo] (analyzed at `v1.42.0-beta.1`, commit `5efed360`)
- [`source/dub/recipe/packagerecipe.d` — `PackageRecipe`, `SubPackage`][rec]
- [`source/dub/recipe/selection.d` — `dub.selections.json` model, `inheritable`][sel]
- [`source/dub/dependency.d` — `Dependency` = `SumType!(VersionRange, NativePath, Repository)`][dep]
- [`source/dub/packagemanager.d` — selections read/write, parent-dir inheritance][pm]
- [`source/dub/commandline.d` — `:subpkg` resolution, `--root`, `upgrade -s`][cli]
- [`source/dub/generators/generator.d` — `computeBuildID`, topological link order][gen]
- [`source/dub/generators/build.d` — content-addressed build cache, parallel source compile][build]
- [dub-docs — Sub-Packages reference][subdocs]
- [dub-docs — Dependencies reference (`path`, `repository`, `add-path`/`add-local`)][depdocs]
- [Sparkles `dub.sdl` and `AGENTS.md` — the running five-package example][repo]
- Related: [concepts][concepts] · [comparison][comparison] · [proposal][proposal] · [Cargo][cargo] · [pnpm][pnpm] · [Yarn Berry][yarn] · [Nx][nx] · the D ecosystem context in [async-io/d-landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/dlang/dub
[docs]: https://dub.dpldocs.info/
[registry]: https://code.dlang.org/
[rec]: https://github.com/dlang/dub/blob/master/source/dub/recipe/packagerecipe.d
[sel]: https://github.com/dlang/dub/blob/master/source/dub/recipe/selection.d
[dep]: https://github.com/dlang/dub/blob/master/source/dub/dependency.d
[pm]: https://github.com/dlang/dub/blob/master/source/dub/packagemanager.d
[cli]: https://github.com/dlang/dub/blob/master/source/dub/commandline.d
[gen]: https://github.com/dlang/dub/blob/master/source/dub/generators/generator.d
[build]: https://github.com/dlang/dub/blob/master/source/dub/generators/build.d
[subdocs]: https://github.com/dlang/dub-docs/blob/master/docs/dub-reference/subpackages.md
[depdocs]: https://github.com/dlang/dub-docs/blob/master/docs/dub-reference/dependencies.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[proposal]: ./dub-proposal.md
[cargo]: ./cargo/
[pnpm]: ./pnpm/
[yarn]: ./yarn-berry/
[nx]: ./nx/
[turbo]: ./turborepo/
[gradle]: ./gradle/
[d-landscape]: ../async-io/d-landscape.md
