# A Native Workspace Model for `dub` — Enhancement Proposal

A milestoned plan to give D's `dub` first-class monorepo primitives — a `[workspace]`
manifest, metadata and dependency inheritance, a `workspace:` local cross-reference
protocol, topological multi-member task routing, and git-ref change slicing — closing
the gap between `dub` and the [consensus standard][comparison] the 44-tool survey
distils.

**Last reviewed:** June 5, 2026

> [!NOTE]
> This is the **capstone proposal** of the monorepo-tooling survey, not a merged DIP
> or a `dub` roadmap commitment. It synthesises the [baseline][dub-baseline] (read
> directly from the `dlang/dub` source at `v1.42.0-beta.1`) and the cross-tool
> [comparison][comparison] into a concrete, ordered design. Every surface below is a
> _proposal_; syntax is illustrative and chosen to fit `dub`'s existing `dub.sdl` /
> `dub.json` recipe grammar and resolver. The running example throughout is the
> **Sparkles** repository itself — five sub-packages (`libs/core-cli`, `libs/versions`,
> `libs/test-utils`, `libs/math`, `apps/ci`) wired together today by hand-maintained
> `path="../.."` overrides and a bespoke `apps/ci` loop.

---

## 1. Abstract & Problem Statement

`dub` is D's de-facto package manager and build tool, and for a single library or
application its **package** model — one directory, one `dub.sdl`/`dub.json`, one
resolved `dub.selections.json` — is clean and well-trodden. The friction this proposal
addresses appears the moment a repository holds **several interdependent packages**, the
exact shape of [Sparkles][dub-baseline]. `dub` has _one_ facility for that case,
**sub-packages**, and a grep of the entire `dub` source and docs trees for "workspace"
or "monorepo" returns **zero matches** ([baseline §overview][dub-baseline]). The concept
does not exist in the tool's vocabulary.

The cost is not theoretical. Measured against the [consensus standard][comparison] —
the baseline feature set shared by [`cargo`][cargo], [`pnpm`][pnpm],
[`yarn-berry`][yarn-berry], [`uv`][uv], [`nx`][nx], and the rest of the catalog —
`dub`'s deficits cluster into four concrete, recurring pain points, each visible in
Sparkles today:

| Deficit                         | How it manifests in Sparkles ([baseline][dub-baseline])                                                                                                                                                                                                                                                                                              |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Manual path-based overrides** | `libs/versions/dub.sdl` says `dependency "sparkles:core-cli" path="../.."` — a depth-sensitive relative path that points at the _repo root_, not at `libs/core-cli/`. `AGENTS.md` keeps a whole table of `path` values per file location. The same edge is also written `version="*"` in `README.md`, and the two must be kept in sync by hand.      |
| **Fragmented lockfiles**        | There is **no** `dub.selections.json` at the Sparkles root. Each member that has ever built standalone has its own — `libs/core-cli/dub.selections.json`, `libs/versions/dub.selections.json`, … — and nothing reconciles `expected`/`silly` across them. Version drift is structurally possible.                                                    |
| **Redundant local compilation** | Building `:core-cli` then `:versions` (which path-depends on it) reuses the content-addressed package cache only when the `computeBuildID` inputs match; differing configurations (the `unittest` config adds `silly` and extra `dflags`) produce distinct ids, so the same source recompiles per configuration ([baseline §caching][dub-baseline]). |
| **Uncoordinated test scripts**  | There is no `dub build --all` / `dub test --workspace`. Building every member means five invocations, so the `apps/ci` D program and the Nix flake's `ci` package exist **outside `dub`** purely to loop the sub-packages. The orchestration is hand-written.                                                                                        |

The honest framing — established in the [baseline][dub-baseline] and confirmed across the
[comparison][comparison] — is that `dub` **already owns the two hard primitives a
workspace needs**: a working dependency resolver and a solid content-addressed local
build cache (`computeBuildID`). What it lacks is an _organising concept above the single
package_. Every multi-package capability in Sparkles is bolted on outside the tool. This
proposal adds that concept, in four milestones ordered strictly by
**[easy → least controversial → most bang-for-the-buck → advanced]**, each borrowing a
proven design from the catalog rather than inventing one.

> [!IMPORTANT]
> The proposal is deliberately **additive and opt-in**. A repository with no
> `[workspace]` block behaves exactly as `dub` does today; the sub-package mechanism is
> untouched. Workspace mode is a new layer over the existing resolver, not a replacement
> for it — the same staging discipline [`go-work`][go-work] applies with `GOWORK=off`.

---

## 2. Milestone 1 — Structural Foundations & Layout Primitives (Quick Wins)

**Motivation.** Before any ergonomics or orchestration, `dub` needs a _noun_ for the
monorepo: a marker the CLI walks up to find, a way to enumerate members, and a single
place to resolve and cache them. Today the closest thing is a root package whose only job
is to list `subPackage` paths ([baseline §sub-package model][dub-baseline]). This
milestone replaces that with a real workspace, borrowing the **dual-mode root** that
[`cargo`][cargo] established and [`uv`][uv] ported verbatim. It is the foundation every
later milestone builds on, and it is the least controversial because it changes nothing
about how an individual package builds.

### 2.1 The `[workspace]` block

A new top-level `workspace` block in `dub.sdl` (and its `dub.json` equivalent) declares
the workspace and globs its members. Following [`cargo`][cargo]'s `WorkspaceRootConfig`
and [`uv`][uv]'s `[tool.uv.workspace]`, `members` is a glob array and `exclude` removes
matches:

```sdl
name "sparkles"
description "D library"
authors "Petar Kirov"
license "BSL-1.0"

workspace {
    members "libs/*" "apps/*"
    exclude "libs/experimental-*"
}
```

The JSON form mirrors it:

```json
{
  "name": "sparkles",
  "workspace": {
    "members": ["libs/*", "apps/*"],
    "exclude": ["libs/experimental-*"]
  }
}
```

Discovery walks **up** from the invocation directory to the nearest recipe carrying a
`workspace` block (the workspace marker, exactly as [`cargo`][cargo] walks to the
`Cargo.toml` with `[workspace]` and [`pnpm`][pnpm] to `pnpm-workspace.yaml`), then globs
**down** to find member recipes. This is a strict superset of today's explicit
`subPackage` list: `members "libs/*" "apps/*"` expands to the same five members Sparkles
enumerates by hand, but adding `libs/new-lib/` requires no edit to the root recipe.

> [!NOTE]
> `members` globs are matched against directories containing a `dub.sdl`/`dub.json`,
> mirroring how [`cargo`][cargo] expands path arrays plus the transitive closure of
> `path` dependencies. A glob that matches a directory with no recipe is silently
> skipped (as in [`pnpm`][pnpm]), so `libs/*` tolerates a stray non-package folder.

### 2.2 Root-package vs. virtual workspace

`dub` today has only one root model: **the root is always a buildable package**
([baseline §1][dub-baseline]). The catalog's reference design ([`cargo`][cargo], copied
by [`uv`][uv] and [`bun`][bun]) is **dual-mode**, and this proposal adopts both:

- **Root-package workspace** — a functional D package that _also_ carries a `workspace`
  block. The root has its own `targetType`, sources, and dependencies, and is itself a
  member. This is the minimal migration for Sparkles: keep `name "sparkles"`, add the
  `workspace` block, done.
- **Virtual workspace** — a stateless root manifest that groups members without being
  buildable itself. There is no buildable target at the root; it exists only to anchor the
  workspace and enumerate members. This matches [`cargo`][cargo]'s `[package]`-less
  virtual form, [`uv`][uv]'s virtual workspace, [`go-work`][go-work]'s `go.work`, and
  [`pnpm`][pnpm]'s dedicated `pnpm-workspace.yaml` — none of which is a buildable unit.

A virtual root is signalled by the absence of a buildable `targetType` (or an explicit
`targetType "none"`) alongside the `workspace` block:

```sdl
# A virtual workspace: groups members, builds nothing itself.
name "sparkles-workspace"
targetType "none"

workspace {
    members "libs/*" "apps/*"
}
```

This is the more honest model for Sparkles, whose root package `sparkles` exists "almost
solely to enumerate the five members" ([baseline §recipes][dub-baseline]). A virtual root
says that directly: there is no `sparkles` artifact, only a workspace of five members.

> [!WARNING]
> Nesting must be rejected with a clear error. [`cargo`][cargo] and [`uv`][uv] both
> forbid nested workspaces, and `dub`'s own sub-packages already disallow nesting
> (_"subpackages cannot be nested"_, [baseline §1][dub-baseline]). A member recipe that
> itself carries a `workspace` block inside an enclosing workspace must fail resolution,
> not silently create an ambiguous boundary.

### 2.3 Unified root `dub.selections.json`

The single biggest concrete win in this milestone. Today the selections file is _"only
used for the root package / project"_, where "root" means whatever package `dub` was
invoked on, producing the fragmented five-lockfile state ([baseline §selections][dub-baseline]).
A workspace resolves **all members together into one root `dub.selections.json`**, exactly
as [`cargo`][cargo] (`Cargo.lock`), [`pnpm`][pnpm] (`pnpm-lock.yaml`), [`uv`][uv]
(`uv.lock`), and [`yarn-berry`][yarn-berry] keep a single workspace-wide lock.

`dub` already has the latching point: the `inheritable` flag on `Selections!1` and the
parent-directory walk in `readSelections`/`findSelections` ([baseline §inheritable][dub-baseline]).
In workspace mode, the root `dub.selections.json` is implicitly `inheritable: true` and
authoritative — but unlike today's opt-in inheritance (which only _supplies_ versions a
member did not pin locally), workspace resolution computes **one consistent version set
for the whole graph**, so a transitive dependency like `expected` is pinned once,
monorepo-wide:

```json
{
  "fileVersion": 1,
  "inheritable": true,
  "versions": {
    "expected": "0.4.1",
    "silly": "1.1.1"
  }
}
```

The per-member `dub.selections.json` files disappear (or become advisory and ignored in
workspace mode). This makes version drift across `core-cli` and `versions`
**structurally impossible** — the [`rush`][rush] `ensureConsistentVersions` invariant,
delivered for free by joint resolution rather than a separate check.

### 2.4 Shared build output (`.dub/target/`)

[`cargo`][cargo]'s one-lock/one-`target/` design is its single biggest concrete win:
each local cross-referenced library is compiled **exactly once** for a given
configuration, and dependents reuse that artifact ([cargo dubLessons][cargo]). `dub`'s
content-addressed cache already keys artifacts by `computeBuildID`
([baseline §caching][dub-baseline]); a workspace simply **anchors that cache at the root**
under a shared `.dub/target/` (in addition to the per-machine `$DUB_HOME`), so building
`:core-cli` then `:versions` reuses one `core-cli` artifact per configuration instead of
recomputing build ids against five separate working directories. This directly attacks the
"redundant local compilation" deficit from §1: the shared output layout is the place a
later milestone's change-tracking (§5) and any future task-output cache plug into.

**Prior art.** [`cargo`][cargo] is the most direct precedent — `[workspace]` table,
dual-mode root, `members`/`exclude` globs, one `Cargo.lock`, one `target/`. [`uv`][uv]
ports it verbatim (`[tool.uv.workspace]`, glob `members`, root-package _or_ virtual, one
`uv.lock`, nesting forbidden); [`bun`][bun] supports both root models; [`pnpm`][pnpm] is
purely virtual (`pnpm-workspace.yaml`, one `pnpm-lock.yaml`); and [`go-work`][go-work]'s
virtual `go.work` adds the one-flag master switch (`GOWORK=off/auto/path`) worth copying
for testing members standalone.

**Risks & open questions.** `workspace` is a new top-level block; SDLang and JSON
accommodate it without a format bump (`PackageRecipe` gains an `@Optional WorkspaceConfig
workspace` field) — additive, low-risk. A package may carry both a `workspace` block and a
`subPackages` array: the proposal treats them as orthogonal (sub-packages are components
of _one_ versioned package; members are co-equal packages), leaving open whether a member
may itself have sub-packages. Glob semantics — whether `exclude` filters before or after
recipe-presence, and whether `members` may name a directory outside the root tree (Cargo
allows `../sibling`) — need pinning down.

---

## 3. Milestone 2 — Configuration Ergonomics & Metadata Inheritance

**Motivation.** With a workspace _noun_ in place, the next friction is **repetition and
drift** in member recipes. Every Sparkles member repeats `authors "Petar Kirov"`,
`license "BSL-1.0"`, a `copyright` line, and pins shared upstreams (`expected`, `silly`)
independently. And every local cross-reference is a hand-maintained `path="../.."`
([baseline §dependencies][dub-baseline]). This milestone eliminates all three with
inheritance and a local-first cross-reference protocol — the [`cargo`][cargo] +
[`yarn-berry`][yarn-berry] combination the [comparison][comparison] identifies as the
fragmentation cure. It is medium-complexity (it touches recipe resolution, not just
discovery) but still uncontroversial, because each feature is opt-in per field.

### 3.1 Field inheritance — `version.workspace = true`

Borrowing [`cargo`][cargo]'s `InheritableFields` and `[workspace.package]`, the root
declares shared metadata once and members opt in per field. In `dub.sdl`, a member marks
a field as inherited with a `workspace=true` attribute:

```sdl
# Root dub.sdl
workspace {
    members "libs/*" "apps/*"

    package {
        authors "Petar Kirov"
        license "BSL-1.0"
        copyright "Copyright © 2023, Petar Kirov"
        version "0.4.1"
    }
}
```

```sdl
# libs/core-cli/dub.sdl — inherit shared fields, override what is local
name "sparkles:core-cli"
authors workspace=true
license workspace=true
copyright workspace=true
version workspace=true
```

The `dub.json` form uses the explicit-marker object [`cargo`][cargo] uses for the same
purpose:

```json
{
  "name": "sparkles:core-cli",
  "authors": { "workspace": true },
  "license": { "workspace": true },
  "version": { "workspace": true }
}
```

Resolution is a merge during recipe parse: where a member sets `field workspace=true`,
the value is read from the root's `workspace.package` table. This is purely opt-in — a
member that sets `authors "Someone Else"` keeps its own value, exactly as Cargo's
inheritance is field-by-field.

> [!NOTE]
> [`uv`][uv] deliberately ships the workspace **without** Cargo-style field inheritance
> (no `version.workspace = true`), proving the two features are separable. `dub` could
> land §3.2/§3.3 first and field inheritance later; they are independent.

### 3.2 Central `[workspace.dependencies]`

The version-unification half. A root `workspace.dependencies` table pins one version per
shared upstream; members reference it with the same `workspace=true` marker. This is
[`cargo`][cargo]'s `[workspace.dependencies]`, the [`pnpm`][pnpm]/[`bun`][bun]/[`yarn-berry`][yarn-berry]
`catalog:` protocol, and [`rush`][rush]'s consistent-versions policy, unified into one
mechanism:

```sdl
# Root dub.sdl
workspace {
    members "libs/*" "apps/*"

    dependencies {
        dependency "expected" version="~>0.4.1"
        dependency "silly" version="~>1.1.1"
    }
}
```

```sdl
# libs/versions/dub.sdl — reference the shared pin, no version here
dependency "expected" workspace=true
```

A member writes `dependency "expected" workspace=true` and the version is taken from the
root table — the direct analogue of Cargo's `expected.workspace = true` or pnpm's
`"expected": "catalog:"`. Combined with the unified lockfile from §2.3, this means
`expected` is **specified once and resolved once**, killing both recipe-level drift (two
members asking for different ranges) and lockfile-level drift (two members resolving the
same range differently).

### 3.3 The `workspace:` local cross-reference protocol

The headline ergonomic win. Today a sibling reference is a depth-sensitive relative path
that points at the repo root, not the sibling, and must be re-expressed as `version="*"`
for published `README` examples ([baseline §dependencies][dub-baseline]). The catalog's
universal answer is a **local-first cross-reference protocol** — [`yarn-berry`][yarn-berry]'s
`workspace:` (the reference design), [`pnpm`][pnpm]'s and [`bun`][bun]'s `workspace:`,
[`cargo`][cargo]'s and [`uv`][uv]'s `{ workspace = true }`, and [`go-work`][go-work]'s
implicit MVS. This proposal adopts Yarn's `workspace:` spelling because it is the most
explicit and self-documenting:

```sdl
# libs/versions/dub.sdl — BEFORE (today)
configuration "library" {
    targetType "library"
    dependency "sparkles:core-cli" path="../.."
}
```

```sdl
# libs/versions/dub.sdl — AFTER (proposed)
configuration "library" {
    targetType "library"
    dependency "sparkles:core-cli" version="workspace:*"
}
```

The `workspace:*` selector resolves to the member named `sparkles:core-cli` _wherever it
lives in the workspace_ — no relative path, no depth sensitivity, no `AGENTS.md` table of
`path` values. The accepted forms mirror Yarn/pnpm:

| Selector          | Meaning ([`yarn-berry`][yarn-berry], [`pnpm`][pnpm])   |
| ----------------- | ------------------------------------------------------ |
| `workspace:*`     | the member's current in-tree version, any version      |
| `workspace:^`     | resolves in-tree; rewritten to `^<version>` at publish |
| `workspace:~`     | resolves in-tree; rewritten to `~<version>` at publish |
| `workspace:1.2.x` | an explicit range that must match the in-tree member   |

**Publish-time rewriting** is the feature that makes this safe for a registry. Like
Yarn's `beforeWorkspacePacking` hook and pnpm's publish rewrite, `dub`'s pack/publish step
substitutes `workspace:^` for a concrete registry range (`^0.4.1`) derived from the
member's resolved version. This finally **unifies the two spellings** Sparkles maintains
by hand: the in-tree recipe uses `version="workspace:*"`, and the published artifact
gets a real range — the `README` `version="*"` divergence ([baseline §dependencies][dub-baseline])
disappears. [`gradle`][gradle]'s composite-build substitution and [`maven`][maven]'s
`ReactorReader` achieve the same "depend by coordinate, resolve locally" effect by a
different route; the `workspace:` protocol is the lighter-weight, more explicit choice for
`dub`'s recipe grammar.

**Prior art.** [`yarn-berry`][yarn-berry] is the reference for §3.3 — the `workspace:`
protocol with `LinkType.SOFT` (symlinked, never fetched, not persisted to the lockfile)
and `beforeWorkspacePacking` publish rewriting. [`cargo`][cargo] is the reference for
§3.1/§3.2 (`[workspace.dependencies]`, `[workspace.package]`, `field.workspace = true`).
[`pnpm`][pnpm]/[`bun`][bun] add `workspace:` + `catalog:` central pins; [`uv`][uv]'s
`{ workspace = true }` carries root-level source inheritance; [`go-work`][go-work]'s
implicit zero-config refs are the "highest-value, least-controversial borrow"; and
[`gradle`][gradle]/[`maven`][maven] reach the same effect via composite-build substitution
/ `ReactorReader`, the coordinate-based alternative to the `workspace:` spelling.

**Risks & open questions.** Both `dependency "expected" workspace=true` and
`version="workspace:*"` must parse under SDLang and round-trip through `dub.json`; the
`workspace:` _string_ form (riding the existing `version` attribute) is the safer encoding
and the recommended primary spelling. Publish-rewriting must derive a range from the
member's resolved version at pack time — a workspace-only member with no concrete version
cannot be published until it has one (Yarn's packing hook; `dub`'s `describe`/pack path
needs the equivalent). Finally, whether the existing `:subpkg` selector also accepts
`workspace:` (for a sub-package of a member) is open; likely members are addressed by name
and sub-packages keep `:`.

---

## 4. Milestone 3 — Topological Task Routing & Slicing (High Bang-for-the-Buck)

**Motivation.** Milestones 1–2 fix _declaration_; this one fixes _execution_, and it is
where the survey locates the real monorepo payoff. `dub` has **no cross-member task** —
no `dub build --all`, no `dub test --workspace` — so building every Sparkles member is
five invocations or the bespoke `apps/ci` loop ([baseline §3][dub-baseline]). Crucially,
`dub` **already computes the resolver topology** it needs: it topologically orders a
package's dependencies for correct link order ([baseline §3][dub-baseline]). The
[comparison][comparison] makes the key observation: like the JS orchestrators that overlay
a graph on a package manager they don't own, `dub` can add a topological loop _without
rebuilding resolution_, because it already owns the resolver. This is the highest
bang-for-the-buck milestone: maximum capability for reuse of existing machinery.

### 4.1 Topological execution loop

A `foreach`-style worklist loop, modelled directly on [`yarn-berry`][yarn-berry]'s
`yarn workspaces foreach -t` (the [comparison][comparison] names it "the direct
inspiration for the dub proposal's loop") and [`pnpm`][pnpm]'s recursive `-r`. The loop
reuses `dub`'s existing dependency topology to run a verb on a member **only after its
in-repo dependencies succeed**:

```bash
# Build every member in topological order (core-cli before versions before ci).
dub build --workspace

# Test every member, dependencies first.
dub test --all
```

The loop is a textbook topological worklist over the member graph `dub` already resolves,
with three properties the catalog establishes as table stakes:

- **Topological ordering.** A member runs only after its workspace dependencies — Sparkles'
  `versions` (which depends on `core-cli`) builds after `core-cli`, mirroring
  [`cargo`][cargo]'s `DependencyQueue`, [`maven`][maven]'s reactor `ProjectSorter`, and
  [`nx`][nx]'s `^build` rule.
- **Explicit cycle detection.** A dependency cycle fails with a clear error naming the
  offending members (three-color DFS, as [`maven`][maven]'s `ProjectSorter` reports the
  offending path), never a deadlock — a [`yarn-berry`][yarn-berry] dubLesson.
- **Per-process output control.** Member output is grouped/prefixed, not interleaved, as
  `yarn workspaces foreach` and `pnpm -r` do.

### 4.2 Target slicing & filter ergonomics

`dub`'s current multi-package CLI surface is "loop it yourself" — `:subpkg` and
`--root`, with no selection vocabulary ([baseline §5][dub-baseline]). This milestone adds
the catalog's filter grammar, ordered from the cleanest binary pair to the richest:

| Surface                             | Meaning                                                 | Prior art                                                            |
| ----------------------------------- | ------------------------------------------------------- | -------------------------------------------------------------------- |
| `dub build --workspace`             | broadcast to **all** members, topologically             | [`cargo`][cargo] `--workspace`, [`yarn-berry`][yarn-berry] `foreach` |
| `dub test --all`                    | alias for the all-members broadcast                     | [`cargo`][cargo] `--workspace`, [`pnpm`][pnpm] `-r`                  |
| `dub run -p app-backend`            | focus a **single** member by name                       | [`cargo`][cargo] `-p`, [`maven`][maven] `-pl`                        |
| `dub test -p core-cli -p versions`  | repeatable per-member selector                          | [`cargo`][cargo] `-p` (repeatable)                                   |
| `dub build --filter "libs/*"`       | name/path glob selection                                | [`pnpm`][pnpm] `--filter`, [`turborepo`][turborepo] `--filter`       |
| `dub test --from core-cli`          | the member **plus its dependents** (downstream closure) | [`pnpm`][pnpm] `...pkg`, [`lerna`][lerna] `--include-dependents`     |
| `dub build --recursive -p versions` | the member **plus its dependencies** (upstream closure) | [`pnpm`][pnpm] `pkg...`, [`maven`][maven] `-am`                      |

The `-p`/`--workspace` pair is [`cargo`][cargo]'s clean binary boundary; `--filter` is
[`pnpm`][pnpm]'s richer grammar (name globs, path globs, exclusion); and `--from` /
`--recursive` are the subgraph-traversal directions [`pnpm`][pnpm] spells `...pkg` /
`pkg...` and [`lerna`][lerna] spells `--include-dependents` / `--include-dependencies`.
All three compose: `dub test --filter "libs/*" --from core-cli` selects the `libs/*`
members and everything downstream of `core-cli`. This single feature **replaces the
entire `apps/ci` test-loop** with `dub test --all`.

### 4.3 Concurrency controls

Independent legs of the topological graph compile asynchronously under a worker cap, the
universal pattern ([`cargo`][cargo] `-j`, [`ninja`][ninja], [`turborepo`][turborepo]
concurrency, [`pnpm`][pnpm] `--workspace-concurrency`):

```bash
# Run independent members in parallel, up to 4 at once.
dub test --workspace -j 4

# Shorthand: parallelize across all available cores.
dub build --workspace -p
```

| Flag             | Meaning                                                             |
| ---------------- | ------------------------------------------------------------------- |
| `-j, --jobs N`   | at most `N` members building concurrently (the topological-leg cap) |
| `-p, --parallel` | parallelize independent legs across available cores (auto cap)      |

> [!WARNING]
> `dub` already parallelizes compilation **at the source-file level** within one build
> (`srcs.parallel(1)` under `settings.parallelBuild`, [baseline §3][dub-baseline]).
> Member-level `-j` is a _second, outer_ concurrency tier and must compose with the inner
> one without oversubscribing cores — the classic jobserver problem [`cargo`][cargo] and
> [`make`][make] solve with a shared token pool. The two tiers sharing one job budget is
> an explicit design requirement, not an afterthought.

**Prior art.** [`yarn-berry`][yarn-berry]'s `yarn workspaces foreach -t` is the direct
inspiration for the loop (cycle detection, per-process output); [`pnpm`][pnpm] supplies
recursive `-r`, the `--filter` grammar, `...pkg`/`pkg...` traversal, and
`--workspace-concurrency`; [`cargo`][cargo] the clean `--workspace`/`-p`/`--exclude` pair
plus `-j` jobserver concurrency; [`maven`][maven] a reactor sort over _all_ prerequisite
edges with `-pl`, `-am`/`-amd` slicing and `-T` parallelism; [`nx`][nx]/[`turborepo`][turborepo]
the `dependsOn: ["^build"]` (deps-first) vs. `build` (self-first) split; and
[`lerna`][lerna] the `--include-dependents`/`--include-dependencies` + `--concurrency`
controls.

**Risks & open questions.** The main implementation risk is the two-tier concurrency
above: outer (member) and inner (source-file) parallelism must share one job budget.
Verb applicability needs per-member handling (`dub run` on a library must skip or error,
as `yarn workspaces foreach` does for missing scripts). The selector grammar overlaps
(`--filter`, `-p`, `--from`/`--recursive`), so settling a minimal orthogonal set rather
than shipping all of pnpm's grammar is an open question, as is grouped-per-member vs.
interleaved output (Yarn buffers; a `--stream` escape hatch, à la pnpm, covers the latter).

---

## 5. Milestone 4 — Advanced Optimizations & Change Tracking (Long-term)

**Motivation.** The first three milestones make the workspace _correct and ergonomic_;
this one makes it _fast at scale_ and _self-enforcing_. Once a topological loop and a
unified lockfile exist (§2–4), the next lever is **not running work that cannot have
changed**, and the one after that is **validating that members conform to workspace-wide
rules**. Both are long-term because they are higher-effort and slightly more controversial
(change detection has correctness subtleties; a constraints engine adds policy). They are
the [`nx`][nx]/[`lerna`][lerna]/[`moon`][moon] frontier of the [comparison][comparison].

### 5.1 Git-ref change detection — `--since`

`dub` has **no change-detection-driven slicing**; every run reconsiders the full target
([baseline §3][dub-baseline]). The catalog's cheapest, highest-leverage CI feature is a
**git-diff affected set**: map changed files to owning members, then expand to those
members' downstream dependents. This is [`lerna`][lerna]'s and [`nx affected`][nx]'s
`--since`, [`moon`][moon]'s and [`please`][please]'s git-ref slicing, and a
[`yarn-berry`][yarn-berry]/[`pnpm`][pnpm] dubLesson:

```bash
# Test only members changed since the previous commit, plus everything downstream.
dub test --since HEAD~1

# Build the slice affected since branching off main.
dub build --since main
```

The mechanism is deliberately simple and dependency-free: `git diff --name-only <ref>`
→ owning members (via the `members` globs from §2.1) → downstream-dependent expansion
over the topology `dub` already computes (the same `--from` traversal as §4.2). On a CI
run for a one-line change in `libs/math`, `dub test --since HEAD~1` runs `math` and its
dependents only, skipping `core-cli`, `versions`, and `ci` entirely.

> [!IMPORTANT]
> `--since` detects **changed files, not changed task inputs** — it is coarser than a
> true input-hash cache ([`nx`][nx], [`turborepo`][turborepo]), and the proposal is
> explicit about this ([`yarn-berry`][yarn-berry] dubLesson). It is the high-leverage,
> low-magic _first_ step; a content-addressed task-output cache (hashing source +
> resolved `dub.selections.json` + `dflags` + env, à la [`nx`][nx]/[`turborepo`][turborepo],
> reusing `computeBuildID` machinery) and an eventual **remote** cache are the larger,
> later horizons the [comparison][comparison] places at the frontier. `--since` is chosen
> first precisely because it needs no cache infrastructure — just git and the topology.

### 5.2 Workspace constraints engine

The self-enforcement half. A large workspace accumulates rules — "every member uses the
same `license`", "every member enables `-preview=dip1000`", "no member depends on a
banned package" — that today live in prose (Sparkles' `AGENTS.md`) or a hand-written
linter (`apps/ci`). [`yarn-berry`][yarn-berry]'s `yarn constraints` engine and
[`rush`][rush]'s consistent-versions policy formalize this as a declarative, optionally
auto-fixable validation pass:

```sdl
# Root dub.sdl — workspace-wide invariants
workspace {
    members "libs/*" "apps/*"

    constraints {
        # Every member must carry these dflags.
        require dflags="-preview=in" "-preview=dip1000"
        # Every member's license must match the root.
        require license="BSL-1.0"
        # Ban a dependency workspace-wide.
        forbid dependency="some-unmaintained-lib"
    }
}
```

`dub workspace check` (or a `--check` gate folded into resolution) validates every member
against the rules and reports — or, where safe, auto-fixes — violations. This subsumes the
attribute/flag-conformance checks `apps/ci` performs by hand and the version-consistency
guarantee §2.3/§3.2 already deliver, unifying policy into the workspace manifest.

**Prior art.** For §5.1, [`nx`][nx] (`affected --base --head` over the project graph,
plus the `xxh3_64` computation hash and output replay that mark the content-cache
horizon), [`lerna`][lerna] (`--since [ref]` + dependents/dependencies modifiers),
[`moon`][moon] (git-aware `--affected`/`--since`, REAPI-compatible cache wire format —
the remote-cache horizon), [`please`][please] (`plz query changes --since`), and
[`turborepo`][turborepo] (`--filter=[ref]`/`--affected`, content-hash task cache);
[`gradle`][gradle]'s content-keyed, machine-portable cache is the argument for hashing
inputs over mtime when that horizon arrives. For §5.2, [`yarn-berry`][yarn-berry]'s
`yarn constraints` and [`rush`][rush]'s consistent-versions policy are the model.

**Risks & open questions.** A file-level git diff can miss inputs outside member
directories — a change to the root `dub.sdl` or shared `dflags` must invalidate _all_
members — so the changed-path → affected-member mapping needs careful definition.
`--since` is a slicing heuristic, not a correctness guarantee, and must never be the
_only_ gate for a release build (a full input-hash cache is the sound-but-larger
successor). The constraints DSL must resist scope creep (Yarn's is Prolog-like): a small
declarative `require`/`forbid` vocabulary, not a general logic language. Finally, a
shared/remote task-output cache and eventual REAPI remote execution ([`bazel`][bazel],
[`buildbuddy`][buildbuddy]) are the post-proposal horizon the [comparison][comparison]
places beyond this milestone — out of scope here, but the shared `.dub/target/` (§2.4) and
any `--since` hashing are the substrate they would plug into.

---

## Milestone summary

| Milestone                                                                                                       | Effort | Controversy | Impact    | Key prior art                                                                              |
| --------------------------------------------------------------------------------------------------------------- | ------ | ----------- | --------- | ------------------------------------------------------------------------------------------ |
| **M1 — Structural foundations** (`[workspace]` block, dual-mode root, unified lockfile, shared `.dub/target/`)  | Low    | Very low    | High      | [`cargo`][cargo], [`uv`][uv], [`pnpm`][pnpm], [`go-work`][go-work]                         |
| **M2 — Config & metadata inheritance** (`version.workspace`, `[workspace.dependencies]`, `workspace:` protocol) | Medium | Low         | High      | [`cargo`][cargo], [`yarn-berry`][yarn-berry], [`pnpm`][pnpm], [`gradle`][gradle]           |
| **M3 — Topological task routing & slicing** (`foreach` loop, `-p`/`--workspace`/`--filter`/`--from`, `-j`/`-p`) | Medium | Low–medium  | Very high | [`yarn-berry`][yarn-berry], [`pnpm`][pnpm], [`cargo`][cargo], [`maven`][maven], [`nx`][nx] |
| **M4 — Change tracking & constraints** (`--since` git slicing, constraints engine; cache horizon)               | High   | Medium      | High (CI) | [`nx`][nx], [`lerna`][lerna], [`moon`][moon], [`yarn-berry`][yarn-berry], [`rush`][rush]   |

The ordering is deliberate and cumulative: **M1** gives the workspace a noun and the one
shared lockfile (the single biggest concrete win, [`cargo`][cargo]'s one-lock/one-target
design); **M2** makes member recipes stop repeating and stop drifting; **M3** turns the
resolver topology `dub` already owns into a `foreach` loop with filter ergonomics (the
highest bang-for-the-buck, since it reuses existing machinery); and **M4** bounds CI work
to what changed and enforces workspace-wide policy. Each milestone is independently
shippable and additive — a repo adopts as much of the ladder as it needs, and a repo with
no `[workspace]` block builds exactly as `dub` does today. Together they move every
multi-package concern Sparkles handles _outside_ `dub` — the `apps/ci` loop, the Nix
glue, the `path="../.."` strings, the five lockfiles — _into_ the tool, closing the
[dub delta][comparison].

---

## Sources

- The system under improvement: the [`dub` baseline][dub-baseline], read directly from the
  `dlang/dub` source at `v1.42.0-beta.1` — the four deficits in §1, the resolver topology
  and `computeBuildID` cache this proposal reuses, and the `inheritable`-selections latch
  point for §2.3.
- The cross-tool [comparison][comparison] and its [concepts][concepts] vocabulary — the
  consensus standard each milestone targets and the "dub delta" this proposal closes.
- Per-tool primary sources and the structured `dubLessons` are cited in each linked
  [deep-dive](./); the reference precedents are [`cargo`][cargo] (M1/M2),
  [`yarn-berry`][yarn-berry] (M2/M3), [`pnpm`][pnpm] (M3), [`nx`][nx]/[`lerna`][lerna]
  (M4).
- The running example is the Sparkles repository's own `dub.sdl` and `AGENTS.md`
  (five sub-packages, hand-maintained `path=` overrides, the `apps/ci` loop).
- Structural model: async-io's [comparison][async-comparison] (the synthesis/proposal-doc
  pattern this imitates).

<!-- References -->

<!-- Sibling synthesis docs -->

[dub-baseline]: ./dub-baseline.md
[comparison]: ./comparison.md
[concepts]: ./concepts.md

<!-- Cross-tree synthesis -->

[async-comparison]: ../async-io/comparison.md

<!-- Deep-dives cited -->

[cargo]: ./cargo/
[yarn-berry]: ./yarn-berry/
[pnpm]: ./pnpm/
[bun]: ./bun/
[uv]: ./uv/
[go-work]: ./go-work/
[nx]: ./nx/
[turborepo]: ./turborepo/
[lerna]: ./lerna/
[rush]: ./rush/
[moon]: ./moon/
[maven]: ./maven/
[gradle]: ./gradle/
[please]: ./please/
[bazel]: ./bazel/
[buildbuddy]: ./buildbuddy/
[ninja]: ./ninja/
[make]: ./make/
