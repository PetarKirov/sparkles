# Go toolchain (go.work) (Go)

Go's first-party multi-module workspace mode: a single root `go.work` file
that `use`s a set of on-disk modules as co-equal main modules, letting one
module import another locally without `replace` directives or publishing — but
with no task DAG, no test caching policy beyond the per-package content cache,
and no remote execution.

| Field           | Value                                                                                          |
| --------------- | ---------------------------------------------------------------------------------------------- |
| Language        | Go (`cmd/go` is the toolchain; workspaces are part of the module system)                       |
| License         | BSD-3-Clause (`The Go Authors`)                                                                |
| Repository      | [golang/go][repo] — `src/cmd/go/internal/workcmd/`, `src/cmd/go/internal/modload/`             |
| Documentation   | [Workspaces reference (`go.dev/ref/mod`)][ref] · [`go work` command][cmd] · [tutorial][tut]    |
| Category        | Language Package Manager / Build System                                                        |
| Workspace model | Virtual root file (`go.work`) `use`-listing local modules as **co-equal main modules** for MVS |
| First released  | Go `1.18` (March 15, 2022) — `go.work`, `go work init/use/edit/sync`                           |
| Latest release  | Go `1.26.4` (June 2, 2026)                                                                     |

> **Latest release:** Go `1.26.4`, released June 2, 2026 (with `1.25.11` the
> prior minor). Workspaces themselves have been stable since `1.18`; the model
> has been extended incrementally — `go work use -r` (`1.20`), workspace-level
> `godebug` directives that override `go.mod` (`1.21`), `go work vendor`
> (`1.22`), and `tool` directives that participate in workspaces (`1.24`). The
> `go.work` file format and the `use`/`replace`/`go`/`godebug` directive set are
> otherwise unchanged.

---

## Overview

### What it solves

Before Go `1.18`, developing two modules together — say a library and an
application that imports it, both unpublished — required editing the dependent's
`go.mod` with a `replace` directive pointing at a relative path, then **removing**
that `replace` before publishing so it didn't leak into consumers' builds. This
is the pain `go.work` removes. From the workspace design proposal
([`golang/proposal` 45713][proposal]):

> _"The `replace` directive is the exception: it allows users to replace the
> resolved version of a module with a working version on disk. But working with
> the replace directive can often be awkward. … users would choose to create
> `go.work` files defining the workspace using the modules in those repositories
> instead of adding `replaces` in the `go.mod` files."_

A `go.work` file lives **outside** any module (typically one directory up from
the modules it groups) and is deliberately **not** checked into a module's
repository — so it overrides nobody else's build. The proposal is explicit:

> _"`go.work` files should not be checked into version control repos containing
> modules so that the `go.work` file in a module does not end up overriding the
> configuration a user created themselves outside of the module."_

This positions `go.work` as a **developer-local view** over a set of modules,
not a published manifest. It is the Go analogue of Cargo's virtual workspace
(see [Cargo][cargo]) or pnpm's `pnpm-workspace.yaml` (see [pnpm][pnpm]), but
with a sharply narrower remit: it composes the **dependency graph** of several
modules; it does not orchestrate, cache, or filter tasks.

### Design philosophy

The defining decision is to model a workspace as a set of **co-equal main
modules** fed into Go's existing build algorithm — Minimal Version Selection
(MVS) — rather than inventing a new resolver. From the workspaces reference
([`go.dev/ref/mod`][ref]):

> _"A workspace is a collection of modules on disk that are used as the main
> modules when running minimal version selection (MVS). … A workspace can be
> declared in a `go.work` file that specifies relative paths to the module
> directories of each of the modules in the workspace. When no `go.work` file
> exists, the workspace consists of the single module containing the current
> directory."_

Three consequences follow, and they shape everything the toolchain does in
workspace mode:

1.  **No new resolver, no new lockfile.** A workspace is "module mode with more
    than one main module." MVS computes one unified build list across all
    `use`d modules; the only workspace-specific persisted state is a
    `go.work.sum` of checksums for dependencies not already covered by the
    members' own `go.sum` files. Each member keeps its own `go.mod` and
    `go.sum`.
2.  **Configuration is a separate file, kept out of VCS.** Workspace config is
    too multi-parameter for a flag or env var (per the proposal), so it is a
    file — but a developer-local one, discovered by walking up from the cwd, and
    overridable/disable-able via `GOWORK`.
3.  **The directive vocabulary is a subset of `go.mod`.** `go.work` reuses the
    `go.mod` grammar machinery (`golang.org/x/mod/modfile`) and supports only
    `go`, `toolchain`, `use`, `replace`, and `godebug` — there is no
    `require`, because members declare their own requirements.

What `go.work` deliberately is **not**: it is not a task runner, has no notion
of "build this member then that one," performs no input-hash-based affected
detection across members, and ships no remote cache. Those responsibilities
stay with `go build`/`go test` (which have their own content-addressed cache)
and with external tools. Compare the heavyweight polyglot engines
([Bazel][bazel], [Buck2][buck2]) that fold all of this into one tool, and the
JS task orchestrators ([Nx][nx], [Turborepo][turborepo]) layered atop package
managers.

---

## How it works

### The `go.work` file

A `go.work` file is line-oriented and reuses `go.mod`'s block syntax. Parsed by
`modfile.ParseWork` ([`x/mod/modfile/work.go`][workfile]) into:

```go
// golang.org/x/mod/modfile/work.go
type WorkFile struct {
    Go        *Go
    Toolchain *Toolchain
    Godebug   []*Godebug
    Use       []*Use      // each: a directory containing a go.mod
    Replace   []*Replace
    Syntax    *FileSyntax
}

type Use struct {
    Path       string // directory of the module's go.mod (relative or absolute)
    ModulePath string // module path, recorded as a trailing comment
    Syntax     *Line
}
```

A representative file:

```go
go 1.24

use (
    ./greeter
    ./cli
)

// Optional: override a conflicting replace across members, pin a dep, or
// set a workspace-wide GODEBUG. There is no `require` directive here.
replace example.com/legacy => example.com/legacy v1.4.5
godebug default=go1.24
```

The `use` directive names a **directory** (the one holding a `go.mod`), not a
module path. Crucially it does **not** recurse: `use ./foo` adds only `./foo`'s
module, never `./foo/sub`'s — each module needs its own `use` line. From
[`use.go`][use] the toolchain records the module path back into the file as a
`// example.com/...` comment via `UpdateWorkFile`, purely for readability.

### Discovery: walking up to `go.work`

There is no member glob and no central registry — discovery is a parent-directory
walk from the current working directory, short-circuited by the `GOWORK` env var.
From `Loader.FindGoWork` and `findWorkspaceFile` ([`modload/init.go`][init]):

```go
// cmd/go/internal/modload/init.go — FindGoWork (abridged)
switch gowork := cfg.Getenv("GOWORK"); gowork {
case "off":
    return ""                       // disable workspace mode entirely
case "", "auto":
    return findWorkspaceFile(wd)    // walk up directories looking for go.work
default:
    if !filepath.IsAbs(gowork) {
        base.Fatalf("go: invalid GOWORK: not an absolute path")
    }
    return gowork                   // explicit override
}
```

```go
// cmd/go/internal/modload/init.go — findWorkspaceFile (abridged)
for {
    f := filepath.Join(dir, "go.work")
    if fi, err := fsys.Stat(f); err == nil && !fi.IsDir() {
        return f
    }
    d := filepath.Dir(dir)
    if d == dir { break }
    if d == cfg.GOROOT { return "" } // never cross GOROOT
    dir = d
}
```

`go env GOWORK` reports the file in effect (or empty); `GOWORK=off` is the
escape hatch that drops back to single-module mode.

### Loading members as main modules

Once found, `LoadWorkFile` ([`modload/init.go`][init]) resolves every `use`
path to an absolute `go.mod` directory, rejects duplicates, and hands the list
to `makeMainModules`, which builds a `MainModuleSet` — the in-memory record that
the rest of `cmd/go` treats as "the main modules." The unified build list is
then computed by MVS over the union of those modules' requirements, with a
special pruning mode named exactly `workspace` ([`modload/modfile.go`][modfile]):

```go
// cmd/go/internal/modload/modfile.go
const (
    // ...
    workspace // pruned to the union of modules in the workspace
)
```

Local cross-references between members fall out for free: because both
`./greeter` and `./cli` are main modules, when `cli` imports
`example.com/greeter`, MVS resolves that import to the **on-disk** `greeter`
module rather than fetching a tagged version from a proxy. No `replace`, no
version, no publish.

### Persisted state: `go.work.sum`, not a lockfile

A workspace does **not** introduce a unified lockfile. Each member's exact
dependency versions still live in its own `go.mod`/`go.sum`. The only
workspace-scoped file is `go.work.sum`, holding checksums for dependencies in
the workspace build list that aren't already verified by a member's `go.sum`
([`modload/init.go`][init], `SetGoSumFile(workFilePath + ".sum")`). On write,
`commitRequirements` _"only writes changes to go.work.sum"_ — it never edits
members' files implicitly.

### `go work sync`: pushing the unified build list back down

The one operation that reconciles members is `go work sync`
([`workcmd/sync.go`][sync]). It computes the workspace-wide MVS build list, then
**upgrades each member's `go.mod`** so that every member uses at least the
workspace-selected version of each shared dependency — eliminating version drift
that would otherwise only surface when a member is built outside the workspace.
Its own doc comment states the invariant:

> _"Minimal Version Selection guarantees that the build list's version of each
> module is always the same or higher than that in each workspace module."_

So `sync` is a _convergence_ step, not a continuous guarantee: between syncs,
members can diverge, and each still builds standalone from its own `go.mod`.

---

## Workspace Declaration & Topology

| Aspect           | `go.work` behavior                                                                                 |
| ---------------- | -------------------------------------------------------------------------------------------------- |
| Declaration unit | A `use ./dir` line per member; **no glob** (`use ./libs/*` is not supported)                       |
| Root config      | A standalone `go.work` file, typically one level above the modules; not part of any module         |
| Discovery        | Parent-directory walk from cwd (`findWorkspaceFile`), capped at `GOROOT`; overridable via `GOWORK` |
| Bulk add         | `go work use -r .` walks subtrees and adds **every** directory containing a `go.mod` (`1.20`+)     |
| Topology model   | Flat set of **co-equal main modules**; no root-vs-leaf hierarchy, no nesting semantics             |
| Exclusion        | Implicit — anything not `use`d is excluded; removing a `use` line drops a member                   |
| Member identity  | Identified by directory; module path recorded as a comment, not the key                            |

Go's model is the most **explicit and least magical** of the surveyed tools:
membership is an enumerated list of directories, not a pattern. `go work use -r`
([`use.go`][use]) is the closest thing to globbing — it `WalkDir`s the argument
tree, skips `vendor` directories and symlinks, and emits one `use` line per
discovered `go.mod`. Symlinks are notably **not** resolved when matching `use`
paths to modules (a documented sharp edge): a symlink and its target are treated
as distinct.

> [!NOTE]
> Unlike [Cargo][cargo] (`members = ["crates/*"]`) or [pnpm][pnpm]
> (`packages: ["libs/*"]`), `go.work` has **no glob**. A 40-module repo gets 40
> `use` lines. `go work use -r .` regenerates them, but the file stays a flat
> enumeration that must be maintained (or regenerated) as members are added.

## Dependency Handling & Isolation

| Concern              | `go.work` behavior                                                                               |
| -------------------- | ------------------------------------------------------------------------------------------------ |
| Local cross-refs     | Automatic: importing another `use`d member resolves to its on-disk source via MVS                |
| Hoisting / store     | None — Go has a global module cache (`$GOMODCACHE`), not a per-workspace store or `node_modules` |
| Isolation model      | Source-based: every package is compiled from source into the content-addressed build cache       |
| Version unification  | MVS over the union of members' requirements; one version per module across the whole workspace   |
| Lockfile             | **No unified lockfile**; per-member `go.mod`/`go.sum` + a workspace `go.work.sum` for extras     |
| Drift control        | `go work sync` upgrades members' `go.mod` files to the workspace-selected versions               |
| `replace` precedence | A `go.work` `replace` **takes precedence over** members' `go.mod` replaces (conflict resolution) |

The headline win is **automatic local cross-references**: because every `use`d
module is a main module, MVS prefers its on-disk copy over any published
version, with no per-edge configuration. This is precisely the
`workspace:`-protocol affordance that Yarn Berry (see [yarn-berry][yarn-berry])
and pnpm expose explicitly — Go gets it implicitly from "everything is a main
module."

The cost is that Go has **no unified lockfile**. Each member is independently
reproducible from its own `go.mod`/`go.sum`; the workspace adds only a
`go.work.sum`. That keeps members publishable as-is (their `go.mod` is the
source of truth consumers see) but means cross-member version consistency is a
_manual_ `go work sync` rather than a single resolved root manifest as in Cargo
or uv (see [uv][uv]).

## Task Orchestration & Scheduling

This is the dimension where `go.work` **does the least**, by design — and where
the gap between "workspace" and "monorepo build system" is widest.

`go.work` itself orchestrates **nothing**. It composes the dependency graph;
task execution is entirely `go build` / `go test` over package patterns. There
is **no** member-level task DAG, **no** `foreach`-style topological loop over
members, and **no** affected-member detection from a Git diff. To act on the
whole workspace you run an ordinary package query — `go build ./...` from the
workspace root expands `./...` across **all** packages in **all** `use`d modules.

Where Go _does_ build a DAG is one level down: `go build`/`go test` construct a
**package-level** action graph and execute it concurrently. From
[`work/exec.go`][exec], `Builder.Do` topologically sorts actions and drives a
worker pool:

```go
// cmd/go/internal/work/exec.go — Builder.Do (abridged)
for _, a := range all {
    for _, a1 := range a.Deps {
        a1.triggers = append(a1.triggers, a) // reverse edges
    }
    a.pending = len(a.Deps)
    if a.pending == 0 {
        b.ready.push(a); b.readySema <- true // leaves are immediately ready
    }
}
// ... when an action finishes, decrement each trigger's pending count;
// when it hits zero, that action becomes ready:
for _, a0 := range a.triggers {
    if a0.pending--; a0.pending == 0 {
        b.ready.push(a0); b.readySema <- true
    }
}
```

The worker count is `cfg.BuildP`, controlled by the `-p` flag and defaulting to
`runtime.GOMAXPROCS(0)` ([`cfg.go`][cfg], [`build.go`][build]):

```go
// cmd/go/internal/cfg/cfg.go
BuildP = runtime.GOMAXPROCS(0) // -p flag
```

So Go's concurrency and "change detection" operate at **package** granularity
via the build cache (below), not at **member** granularity. A change in one
member triggers recompilation only of the packages whose inputs changed
(transitively), but there is no notion of "skip member B because nothing it
depends on changed" beyond what the package cache already gives you. There is no
`--since <ref>` affected-detection across members — that is left to wrappers or
external orchestrators.

> [!IMPORTANT]
> `go build ./...` from a workspace root is the _only_ "run across all members"
> primitive, and it is a **package** broadcast, not a **member** loop. There is
> no built-in way to say "build member `cli` and its local prerequisites, in
> topological member order, skipping unaffected members" — the package action
> graph subsumes ordering, but member-level filtering/affected logic does not
> exist.

## Caching & Remote Execution

| Layer            | What Go provides                                                                                |
| ---------------- | ----------------------------------------------------------------------------------------------- |
| Build cache      | Local, content-addressed, at package granularity (`$GOCACHE`); shared across all workspaces     |
| Test cache       | Local: `go test` caches passing results keyed by inputs + flags; `-count=1` forces a re-run     |
| Remote cache     | **None** in the toolchain (no REAPI client/server)                                              |
| Remote execution | **None**                                                                                        |
| Cache scope      | Per-user (`$GOCACHE`), **not** per-workspace — identical inputs hit the same entry across repos |

Go ships a mature **local content-addressed cache** but no remote-execution
story. The cache is keyed by an `ActionID` — a hash of _everything_ that feeds a
compilation. From [`cache/cache.go`][cache]:

> _"An ActionID is a cache action key, the hash of a complete description of a
> repeatable computation (command line, environment variables, input file
> contents, executable contents)."_

The build ID scheme ([`work/buildid.go`][buildid]) composes these so that
`actionID(binary)/actionID(main.a)/contentID(main.a)/contentID(binary)`
identifies an artifact, and _"the content hash of every input file for a given
action must be included in the action ID hash."_ This is genuine
input-hash-based incrementality — the same conceptual mechanism as
[Bazel][bazel]/[Turborepo][turborepo] caches — but it is **package-scoped,
local-only, and per-user**. Two members that compile an identical package share
the cache entry; two developers do not, and CI cannot pull a teammate's cached
artifacts without a third-party `GOCACHEPROG` shim. There is no native REAPI
backend ([Buildbarn][buildbarn], [NativeLink][nativelink]) integration.

> [!NOTE]
> Go `1.24` stabilized `GOCACHEPROG` — an external program protocol
> ([`cache/prog.go`][prog]) that lets a child process serve cache `Get`/`Put`,
> which third parties use to bolt on a remote/shared cache. The base toolchain
> still ships **local-disk caching only**; remote caching is an out-of-tree
> extension point, not a workspace feature.

## CLI / UX Ergonomics

The command boundary is the cleanest illustration of the philosophy: **`go work`
manages the file; ordinary build commands act on packages.** There is no
`--filter`/`-p member`/`:target` member-selection vocabulary because the unit of
work is a _package pattern_, not a _member_.

| Command                     | Effect                                                                          |
| --------------------------- | ------------------------------------------------------------------------------- |
| `go work init [dirs]`       | Create `go.work`, `use`-listing the given module directories                    |
| `go work use [-r] [dirs]`   | Add/remove `use` directives (`-r` recurses, adding every `go.mod` subtree)      |
| `go work edit ...`          | Programmatic edits (`-use`, `-dropuse`, `-replace`, `-go`, `-godebug`, `-json`) |
| `go work sync`              | Upgrade members' `go.mod` to the workspace-wide MVS build list                  |
| `go work vendor [-o dir]`   | Write a single workspace `vendor/` covering all members (`1.22`+)               |
| `go build ./...`            | Build **all packages in all members** (a package broadcast over the workspace)  |
| `go test ./...`             | Test all packages in all members; results cached by input hash                  |
| `go build ./cli/...`        | Scope to one member's packages by path pattern (the closest thing to a filter)  |
| `GOWORK=off go build ./...` | Bypass workspace mode for one invocation                                        |

Selection idioms:

- **Global broadcast:** `go build ./...` / `go test ./...` from the workspace
  root — operates on every package across every member.
- **Targeted:** a **path pattern**, e.g. `go test ./greeter/...`, narrows to a
  member's packages. There is no member-name flag; you scope by directory.
- **The `-p` flag is parallelism, not packages.** A recurring point of
  confusion: `go build -p 4` sets the _number of build workers_
  ([`build.go`][build]), it does **not** select a package or member (contrast
  pnpm/Nx where `-p` often means "project"/"parallel projects").
- **Disable:** `GOWORK=off` or `go env -w GOWORK=off`.

> [!WARNING]
> The absence of member-level filter ergonomics (`--filter`, `--since`,
> `--from`) is the single biggest gap versus JS orchestrators and Cargo. In a
> large `go.work`, "test only what my change affects" is `go test ./...` (test
> everything, lean on the result cache to skip unchanged tests) or a hand-built
> package list — there is no first-party affected-graph command.

---

## Strengths

- **Zero-ceremony local cross-references.** `use`-listing two modules makes one
  import the other from source instantly — the whole reason workspaces exist,
  replacing the awkward `replace`-then-delete dance.
- **First-party and ubiquitous.** Ships in every Go toolchain since `1.18`; no
  plugin, no extra binary, no config DSL to learn beyond five directives.
- **Members stay independently publishable.** Each keeps its own
  `go.mod`/`go.sum`; the `go.work` is developer-local and never leaks into
  consumers' builds (and shouldn't be committed inside a module repo).
- **Reuses MVS — predictable, deterministic resolution.** No new algorithm;
  one version per module across the workspace, computed the same way as a
  single module.
- **Mature local content cache.** Package-level, input-hashed build/test
  caching gives real incrementality out of the box.
- **`GOWORK` is a clean kill switch.** `off`/`auto`/explicit-path makes
  workspace mode trivially toggleable per command or per environment.

## Weaknesses

- **No member globbing.** Membership is a flat, hand-maintained list of `use`
  lines; `go work use -r` regenerates but doesn't _declare_ a pattern.
- **No unified lockfile.** Cross-member version consistency is a manual
  `go work sync`, not a single resolved root manifest; members can silently
  drift between syncs.
- **No member-level task orchestration.** No topological `foreach`, no
  per-member task DAG, no affected-detection from a Git diff — only
  package-pattern broadcasts.
- **No remote cache or remote execution.** Local-disk, per-user cache only;
  remote/shared caching requires the out-of-tree `GOCACHEPROG` shim, and there
  is no REAPI client.
- **No filter ergonomics.** No `--filter`/`--since`/`--from`; you scope by
  directory pattern and rely on the result cache to skip unchanged work.
- **Developer-local by intent.** Because `go.work` shouldn't be committed
  inside a module repo, CI typically runs members standalone or constructs a
  workspace ad hoc — there is no canonical "the repo's workspace" artifact.

## Key design decisions and trade-offs

| Decision                                                      | Rationale                                                                      | Trade-off                                                                              |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------- |
| Workspace = set of **co-equal main modules** fed to MVS       | Reuse the existing resolver; local cross-refs fall out for free                | One version per module workspace-wide; no per-member version divergence within a build |
| Config in a **separate `go.work`**, not in `go.mod`           | Multi-parameter config; keep it developer-local so it never leaks to consumers | Not part of any module's published metadata; CI must construct/own the workspace view  |
| `go.work` **kept out of VCS** (per design)                    | A committed `go.work` would override others' local configuration               | No canonical repo-level workspace; each developer/CI assembles its own                 |
| **Enumerated `use` lines**, no glob                           | Explicit, unambiguous membership; trivially diffable                           | Manual maintenance at scale; `go work use -r` mitigates but doesn't replace patterns   |
| **No unified lockfile** (per-member `go.mod` + `go.work.sum`) | Members remain independently reproducible and publishable                      | Cross-member consistency is a manual `go work sync`; drift possible between syncs      |
| Orchestration left to `go build`/`go test` over patterns      | Keep `go.work` a graph-composition tool, not a task engine                     | No member DAG, no affected-detection, no `--filter`/`--since`                          |
| **Package-scoped, local-only content cache**                  | Simple, deterministic, shared across all workspaces on the machine             | No remote/shared cache or REAPI without the out-of-tree `GOCACHEPROG` shim             |
| `GOWORK` env var as the master switch (`off`/`auto`/path)     | One-flag enable/disable/override for tooling and CI                            | Workspace activation is implicit (directory walk) unless pinned explicitly             |

---

## Sample workspace

A minimal, runnable two-module workspace lives in [`./sample/`](./sample/): a
`go.work` at the root `use`s a `greeter/` library module and a `cli/` application
module, where `cli` imports `greeter` **locally** (no `replace`, no version).
The `cli` module declares a `tool` build target. Run `go build ./...` /
`go test ./...` from the sample root to exercise the workspace; see
[`sample/go.work`](./sample/go.work) for the declaration and
[`sample/cli/main.go`](./sample/cli/main.go) for the cross-module import.

---

## Sources

- [golang/go — `cmd/go` source][repo] (all quoted file paths):
  - [`src/cmd/go/internal/workcmd/work.go` — `go work` command tree][workgo]
  - [`src/cmd/go/internal/workcmd/use.go` — `use -r`, path canonicalization][use]
  - [`src/cmd/go/internal/workcmd/sync.go` — workspace MVS sync][sync]
  - [`src/cmd/go/internal/modload/init.go` — `findWorkspaceFile`, `GOWORK`, `LoadWorkFile`, `go.work.sum`][init]
  - [`src/cmd/go/internal/modload/modfile.go` — `workspace` pruning mode][modfile]
  - [`src/cmd/go/internal/work/exec.go` — package action-graph executor][exec]
  - [`src/cmd/go/internal/work/buildid.go` — content-addressed build IDs][buildid]
  - [`src/cmd/go/internal/cache/cache.go` — `ActionID`/`OutputID` cache][cache]
  - [`src/cmd/vendor/golang.org/x/mod/modfile/work.go` — `WorkFile`/`Use` structs][workfile]
- [Workspaces reference — `go.dev/ref/mod#workspaces`][ref]
- [`go work` command documentation][cmd]
- [Tutorial: multi-module workspaces][tut]
- [Get familiar with workspaces (Go blog)][blog]
- [Proposal 45713: Multi-Module Workspaces][proposal]
- Sibling tools: [Cargo][cargo] · [uv][uv] · [pnpm][pnpm] · [Yarn Berry][yarn-berry] · [Nx][nx] · [Turborepo][turborepo] · [Bazel][bazel] · [Buck2][buck2] · [Buildbarn][buildbarn] · [NativeLink][nativelink] · the [`dub` D landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/golang/go
[workgo]: https://github.com/golang/go/blob/master/src/cmd/go/internal/workcmd/work.go
[use]: https://github.com/golang/go/blob/master/src/cmd/go/internal/workcmd/use.go
[sync]: https://github.com/golang/go/blob/master/src/cmd/go/internal/workcmd/sync.go
[init]: https://github.com/golang/go/blob/master/src/cmd/go/internal/modload/init.go
[modfile]: https://github.com/golang/go/blob/master/src/cmd/go/internal/modload/modfile.go
[exec]: https://github.com/golang/go/blob/master/src/cmd/go/internal/work/exec.go
[buildid]: https://github.com/golang/go/blob/master/src/cmd/go/internal/work/buildid.go
[cache]: https://github.com/golang/go/blob/master/src/cmd/go/internal/cache/cache.go
[prog]: https://github.com/golang/go/blob/master/src/cmd/go/internal/cache/prog.go
[cfg]: https://github.com/golang/go/blob/master/src/cmd/go/internal/cfg/cfg.go
[build]: https://github.com/golang/go/blob/master/src/cmd/go/internal/work/build.go
[workfile]: https://github.com/golang/go/blob/master/src/cmd/vendor/golang.org/x/mod/modfile/work.go
[ref]: https://go.dev/ref/mod#workspaces
[cmd]: https://pkg.go.dev/cmd/go#hdr-Workspace_maintenance
[tut]: https://go.dev/doc/tutorial/workspaces
[blog]: https://go.dev/blog/get-familiar-with-workspaces
[proposal]: https://go.googlesource.com/proposal/+/master/design/45713-workspace.md
[cargo]: ../cargo/
[uv]: ../uv/
[pnpm]: ../pnpm/
[yarn-berry]: ../yarn-berry/
[nx]: ../nx/
[turborepo]: ../turborepo/
[bazel]: ../bazel/
[buck2]: ../buck2/
[buildbarn]: ../buildbarn/
[nativelink]: ../nativelink/
[d-landscape]: ../../async-io/d-landscape.md
