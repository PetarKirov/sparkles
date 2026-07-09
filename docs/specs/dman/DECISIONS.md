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
