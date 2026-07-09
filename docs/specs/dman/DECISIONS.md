# `sparkles:dman` — Decision Log

_A running record of the foundational design decisions for `sparkles:dman`,
in the spirit of lightweight ADRs. Each entry states the decision, why, and
what it implies. Companion to the [design & milestone plan](./index.md)._

Status legend: **Accepted** — settled; **Open** — under discussion.

---

## D1 — Name

**Decision (Accepted, 2026-07-09):** use `dman` (development manager) as the
working codename.

**Rationale:** pre-1.0, so a rename is cheap; picking a working name now
unblocks the spec, the package/module namespace, and the CLI binary name.

**Implications:** the eventual dub sub-package is `sparkles:dman`, module root
`sparkles.dman`, CLI binary `dman`. Revisit before 1.0.

---

## D2 — v1 scope

**Decision (Accepted, 2026-07-09):** v1 is a **local, Git-first repository /
worktree / branch management** tool — a scriptable core plus an interactive TUI,
on a single machine. Jujutsu, monorepo orchestration, and all distributed
features are later milestones.

**Rationale:** the tightest, lowest-risk first deliverable; it is independently
useful and does not depend on the still-maturing distributed stack.

**Implications:** P1–P2 in the [milestone plan](./milestones.md);
the VCS abstraction is designed jj-shaped from the start (D4) but only Git is
implemented in v1.

---

## D3 — Async substrate

**Decision (Accepted, 2026-07-09):** build on **`sparkles:event-horizon` from
day one** — the `io_uring` completion loop is dman's substrate for _everything_:
subprocess orchestration (`proc`), file-watching (`watch`), networking (`net`),
signals, and timers, with the TUI frame loop riding `runOnce`.

**Rationale:** one async model unifies v1 with the distributed phase; direct-style
Tier-B fibers give blocking-looking code with no function coloring; the capability
row (with test doubles) gives deterministic tests.

**Implications:** v1 is **Linux-first** by construction (event-horizon is
Linux-only until its M10 kqueue / M11 IOCP land). dman becomes a first-class
driver of event-horizon's remaining milestones — notably the cross-fiber
`Channel!T` (open-issue O20) and the M13 PTY port needed for the multiplexer.
A long-lived daemon must weigh the `WorkStealingPool` GC tradeoff (O22).
_(This overrode the initial recommendation to defer event-horizon; the
unification was judged worth the Linux-first constraint.)_

---

## D4 — VCS access

**Decision (Accepted, 2026-07-09):** access Git (and later jj, gh, nix) as
**subprocesses**, behind a `VcsRepo` backend interface so jj slots in later —
but schema-driven rather than hand-written (see D5), spawned via event-horizon
`proc`.

**Rationale:** matches house style (`runCaptured`, `release/git.d`), fully
portable, no C dependency; subprocess spawn count is a non-issue at dman's scale.
The backend interface keeps Git-specific commands out of the UI and lets jj
reuse the same surface.

**Implications:** a Git-first `VcsRepo` (root detection, default-branch, branch
classification, ahead/behind, dirty state, worktree list/add/remove,
`status --porcelain=v2`) is P1; the jj backend is P3. Machine-readable output
(`--porcelain=v2`, `-z`, `--format`) is preferred over human output.

---

## D5 — Command architecture

**Decision (Accepted, 2026-07-09):** a **bidirectional, schema-driven command**
model — a struct-with-UDAs both **parses** `argv → struct` (dman's own CLI) and
**renders** `struct → argv` (invoking third-party tools), with return-type-driven
collectors (`run!T`) decoding stdout/exit-code. **No separate `sparkles:command`
library**: the executor is glue composing three existing libraries.

**Rationale:** the CLI analogue of `wired`'s value ⇄ JSON mapping. In D, a
field's declared type _is_ its parsed type, so Effect's `Param`/`Config.Infer`
machinery collapses into plain field types + UDAs. The parse side, the schema,
and faithful third-party tool models already exist in `core-cli`'s subcommands
framework; only `struct → argv` render + spawn + typed decode are net-new, and
those are small enough to compose rather than package.

**Implications:** the "run a tool" path is
`core_cli.renderArgv(cmd) → event_horizon.proc.spawn(argv, opts) → wired.fromJSON!T(stdout)`.
`core-cli` gains a pure `struct → argv` renderer; the spawn+decode glue lives in
dman (promotable to a `core_cli.command` _module_ if reused). The spawner is a
swappable capability, enabling deterministic VCS-layer tests with a `FakeSpawner`.
Collectors follow the fixed menu: `void`→exit-code, `string`→stdout,
`string[]`→lines, `T`→wired-decoded.

---

## D6 — Shared schema / policy

**Decision (Accepted, 2026-07-09):** `core-cli` **depends on `sparkles:wired`**
and re-exports `@Option`/`@Argument` as domain aliases over `wired.policy`'s
`@Wire*` UDAs; the CLI is modeled as a wired **format** (`struct Cli {}`).

**Rationale:** one policy vocabulary governs both the CLI shape and JSON
(de)serialization of the same struct. `@Option` desugars to
`@WireName` + `@WireCase` + `@WireOptional` (shared), plus CLI-only axes
(short alias, positional-vs-flag, subcommand, counter) owned by core-cli.
`@WireOptional`'s encode-omission / decode-tolerance semantics map directly onto
CLI render/parse of optional flags. Chosen over hoisting `wired.policy` down to
`base` because it needs no `wired` refactor.

**Implications:** `core-cli`'s dependency-light half now transitively pulls
`wired` (+ `optional`, + the JSON backend) — acceptable because `wired` is
pure/CTFE with **no `io_uring` dependency**, so the hard constraint (arg-parsing
must not drag in event-horizon) still holds. The two formats interlock where a
tool's flag value derives from wired field-names (e.g. `gh pr list --json
number,title`). Future option, deferred: split `core-cli` into `sparkles:tui` +
`sparkles:command` once that surface grows.

---

## D7 — Catalog & cache persistence

**Decision (Accepted, 2026-07-09):** persist the repo catalog and the PR cache in
a **bundled SQLite database** (WAL) — one `dman.db` for dman's local state.

**Rationale:** the PR cache wants concurrent-safe writes, native TTL/eviction, and
indexed lookups; a single embedded DB gives ACID durability, a real migration
story (`schema_migrations`), and a head start on the later distributed / shared-
cache work — worth the added dependency. Chosen over per-repo wired-JSON, which is
dependency-free but re-implements indexing, TTL, and concurrency by hand.
(Supersedes the earlier provisional wired-JSON default.)

**Implications:** a `dman.db` in `dataDir` holds `repositories`, `cached_prs`
(`UNIQUE(repo, branch)`, null `pr_number` = "queried, no PR" sentinel), and
`schema_migrations`; TTL bounds staleness on read and an eviction pass GCs old
rows; WAL + `foreign_keys=ON`. The filesystem stays authoritative for repo
existence (the DB is a rebuildable index). Adds a SQLite dependency — most
sparkles-idiomatically an ImportC binding to the bundled amalgamation (the
`sparkles:ghostty` pattern), or an existing D binding. TUI/session state stays in
`stateDir`. See [Repo catalog](./repo-catalog.md).

---

## D8 — VCS backend abstraction depth

**Decision (Accepted, 2026-07-09):** a **capability-based (Design-by-Introspection)
multi-backend `VcsRepo` abstraction**, designed _now_ from a deep read of jj's
model — a common core both backends fill plus capability-gated optional operations
(staging, operation-log/undo, first-class conflicts, workspace-stale, change-ids),
with backend-pluggable output decode. **Git is v1's sole implementation**; jj lands
at P3. Grounded in [Designing for Jujutsu](./jj-model.md).

**Rationale:** requested a jj research pass before committing to the abstraction.
It showed jj diverges from git structurally (two commit identities, no current
branch, no index, refs with 0..N targets, first-class conflicts, an operation
log, workspaces ≠ worktrees) — so a naive fat git-shaped trait would bake in wrong
assumptions, while a purely git-specific interface would force a large P3 rework.
Capability-by-presence (the sparkles house idiom) resolves both: design the whole
shape now from real jj knowledge, expose backend-specific power as detected
capabilities. It also confirmed **subprocess, not `jj-lib`** ([D4](./DECISIONS.md))
and validated [D5](./DECISIONS.md) — jj reads decode through `wired` from `-T
json()` templates, the same `run!T` path as `gh --json`.

**Implications:** the data model widens (opaque `commitId` + optional `changeId`;
refs that may be unnamed/multi-target; per-remote bound-valued ahead/behind;
capability-gated `staged`/conflicts/stale; nullable `currentBranch` + a working
revision); the repo scanner keys on `.git` **and** `.jj/` with backend-kind
tagging and colocated dedup; jj-only verbs (`op`/`undo`, workspace-stale,
track/untrack) are capability-gated. (Supersedes the earlier provisional "minimal
Git-shaped" default.) See [VCS backend § Designing for jj](./vcs-backend.md#designing-for-jj-the-p3-backend).

---

## D9 — Worktree on-disk layout

**Decision (Accepted — recommended default, 2026-07-09):** default to **sibling
directories named `<repo>-<branch>`** next to the main checkout, configurable via
a naming template.

**Rationale:** matches the existing sparkles worktree convention (e.g.
`sparkles-dman`, `sparkles-event-horizon`), so dman fits how the repos are
already laid out, and the repo scanner discovers worktrees as ordinary repos.

**Implications:** worktree support is net-new (no prior art); dman parses
`git worktree list --porcelain`, links branch↔worktree, and models
"checked out elsewhere". Layout is a template so a dedicated-subdir or central-root
convention can be selected instead. See
[VCS backend § worktree model](./vcs-backend.md#worktree-model-net-new).

> D7–D9 were adopted as the recommended defaults while the requester was away;
> they are low-cost to revisit pre-1.0.

---

## D10 — TUI architecture

**Decision (Accepted — recommended default, 2026-07-09):** build the interactive
UI as a new **`sparkles:tui`** package following the sparkles TUI/layout research:
**immediate-mode**, built from scratch in D, **double-buffer + cell-level diff**
rendering, **box-flow layout** (not a constraint solver), a compile-time
`isWidget!T` contract, and the three-layer (data / `State` / renderer) widget
model. dman is its first consumer. The loop is driven by `event-horizon`'s
`runOnce`, not a blocking poll.

**Rationale:** the sparkles research (`tui-libraries/comparison.md §8`,
`ui-layout`, `tree-view-case-study.md`) already concludes this is the right
design — immediate-mode maps to `@nogc`/UFCS/DbI with no vtables, cell-diff is the
best perf/ergonomics balance, and box-flow beats a constraint solver for a cell
grid. The Cell/Buffer/diff core is unavoidable for any interactive TUI, so making
it a reusable package rather than a dman-local shell costs little and serves the
later GPU-client/multiplexer work. Driving the loop from `event-horizon`
([D3](./DECISIONS.md)) lets async git/scan/PR/watch run without freezing the UI —
the one improvement over the prior art, whose loop is fully synchronous.

**Implications:** P2 splits into P2a (`sparkles:tui` core + layout), P2b (core
widgets, adapting the existing one-shot `drawTree`/`drawTable`/`wrap` renderers to
target a cell `Buffer`), and P2c (the dman shell: app state, an explicit
`InputMode` state machine, keymap, panes, modals). MVU and reactive rendering are
deferred optional overlays. Relates to the [D6](./DECISIONS.md) note about
eventually splitting `core-cli` into `sparkles:tui` + `sparkles:command`: this
creates `sparkles:tui`. See [TUI shell](./tui-shell.md).

> D10 was likewise adopted on the requester's "continue", following their own
> TUI/layout research; revisit if the framework-vs-dman-local scope should differ.
