# `sparkles:dman` — Architecture

_High-level: how dman is built on the sparkles stack. For the command layer in
depth, see [Command schema](./command-schema.md); for the user-facing
capabilities, see [Feature requirements](./feature-requirements.md)._

## Composition — three libraries

dman composes existing sparkles libraries rather than reinventing them:

- **`sparkles:core-cli`** — the CLI **schema** layer: `@Option`/`@Argument`
  UDAs (aliases over `wired`'s `@Wire*` policy), bidirectional `argv ⇄ struct`
  (parse **and** render), help / completions, and the TUI widgets (tree, table,
  wrapped-text renderers).
- **`sparkles:event-horizon`** — the `io_uring` completion loop and dman's async
  substrate for _everything_: subprocess orchestration (`proc`), file-watching
  (`watch`), networking (`net`), signals, and timers.
- **`sparkles:wired`** — structural (de)serialization: decodes tool output
  (JSON / porcelain) into typed D structs, and owns the shared `@Wire*` policy
  vocabulary.

## Dependency layering

The one hard constraint: **`io_uring` must stay out of the pure arg-parsing
layer** — so `core-cli` may depend on `wired` (pure / CTFE), but never on
`event-horizon`. The spawn side is dman-local glue that pulls `event-horizon`.

```
compile-time dependency layering:
    base  ◀──  wired  ◀──  core-cli          (pure / CTFE; no io_uring)
    base  ◀──  event-horizon                  (io_uring; Linux-first)
    dman  ──▶  { core-cli, wired, event-horizon }
```

## Async substrate — event-horizon from day one

dman builds on `event-horizon` from the start ([D3](./DECISIONS.md)): the
`io_uring` loop is the substrate for _all_ I/O, not just the eventual networking.

- **Subprocesses** — every `git` / `jj` / `nix` invocation is spawned and reaped
  on the loop via the `proc` capability (concurrent, non-blocking); the
  [scan pipeline](./repo-catalog.md#scan-pipeline) fans out per-item work under a
  bounded cap, paired back by index.
- **File-watching** — repo / worktree / branch change detection via `watch`
  (inotify through the ring).
- **TUI frame loop** — the interactive UI drives the loop with `runOnce`, which
  is designed as a GUI/frame-loop entry point; `signals` delivers `SIGWINCH`
  for resize.
- **Networking** (later) — the remote daemon, sync, and multiplexer ride `net`
  (TCP / Unix sockets) and the loop's multi-thread topologies.

dman's internal architecture is **direct-style** Tier-B fibers with
capability-passing (a `Ctx` row threading the loop, clock, subprocess spawner,
etc.), which gives blocking-looking code with no function coloring and
deterministic tests via swappable test doubles.

**Implication:** v1 is **Linux-first** by construction (the loop is Linux-only
until event-horizon's kqueue / IOCP backends land), and dman becomes a
first-class driver of event-horizon's remaining milestones — notably the
cross-fiber `Channel!T` (needed for the PTY multiplexer) and the M13 PTY port.

## VCS backend abstraction

Git (and later jj) is accessed as **subprocesses** ([D4](./DECISIONS.md)) behind
a `VcsRepo` backend interface, kept **jj-shaped** from the start so the second
backend slots in without touching the UI:

- root detection · default-branch resolution · branch enumeration + 5-way
  classification · trunk detection · ahead/behind · dirty state · worktree
  list/add/remove/prune · `status --porcelain=v2` parsing.

Crucially, this backend is **not** hand-written wrappers: each Git command is a
declarative schema rendered to argv, spawned via `proc`, and decoded via
`wired`. See [Command schema](./command-schema.md).

The discovery / catalog / registry layer is kept **separate** from `VcsRepo`
(which is per-repo) to avoid a dependency cycle: scanning and cataloging sit
above the per-repo backend.

## Config & state

dman uses `core-cli`'s `common_dirs` for cross-platform locations; config is a
file, and the catalog + PR cache live in a bundled SQLite DB
([D7](./DECISIONS.md)):

- **config** (`configDir`) — dman settings (a config file).
- **data** (`dataDir`) — `dman.db`: the repo catalog + PR cache (SQLite, WAL).
- **cache** (`cacheDir`) — regenerable scan artifacts.
- **state** (`stateDir`) — saved TUI layout, session state.

The filesystem stays authoritative; the DB is a rebuildable secondary index.

## The TUI shell — the biggest net-new piece

Nothing in sparkles today provides an **interactive** terminal UI: the tree /
table / wrapped-text widgets are one-shot **renderers** (they emit a string or
write to an output range) with no selection cursor, scroll viewport, focus,
key handling, or redraw/diff layer. dman must build that shell:

- raw-mode + alternate-screen entry/exit,
- an input event loop integrated with `event-horizon`'s `runOnce`,
- `SIGWINCH`-driven relayout (terminal size via `core-cli`),
- a stateful widget layer (selection, scroll, focus, keymap) over the existing
  one-shot renderers, with a redraw/diff pass.

This — not the VCS logic — is the hard part of v1, and is called out as the
primary risk in [Milestones](./milestones.md).

## Building-block readiness

Where each dependency stands, and when dman needs it:

| Building block                                        | Role for dman                                                                                                 | State today                                                           | Needed in                  |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- | -------------------------- |
| `base` / `core-cli` / `versions`                      | subprocess + monitoring, config/state dirs, CLI parse, term size, grapheme/width/wrap, box/table/tree/oscLink | stable, in-tree                                                       | now                        |
| `core-cli` subcommands (`args`)                       | nested `dman repo/worktree/branch …` + `argv⇄struct`                                                          | mature, on a feature branch — **prereq merge**                        | now                        |
| TUI widgets (`tui-table`/`tree-view`/`text-wrapping`) | `drawTree`/`drawTable`/`wrap`, gitignore repo walker                                                          | renderers stable but **one-shot only**; 3 branches — **prereq merge** | now                        |
| `release` git/gh porcelain                            | seed of the git command schema                                                                                | stable; extend to worktree/branch/`--porcelain=v2`                    | now                        |
| `wired`                                               | config/state persistence; tool-output decode; shared policy                                                   | JSON stable; no framing/binary                                        | now                        |
| `test-runner`                                         | dman's own test harness; a TUI results panel                                                                  | stable                                                                | now                        |
| `event-horizon`                                       | `io_uring` loop: `proc`/`watch`/`net`/`signals`/timers                                                        | **M1–M9 + M12 done, Linux-only**; `Channel!T` and M13 PTY not done    | v1 substrate + distributed |
| `crypto` + `age`                                      | host identity, encrypted sync, secrets                                                                        | stable; **gap: Ed25519 sign/verify** (symbols bound)                  | distributed                |
| `nix`                                                 | remote Nix builds, dev-shell provisioning                                                                     | eval/flake done; realise/copy-closure missing                         | remote-build phase         |
| `ghostty`                                             | headless VT engine (1 VT per remote PTY)                                                                      | PoC binding; headless confirmed; ABI 0.1.0-dev                        | multiplexer phase          |
| `terminal` + `vulkan` + window-system                 | raylib client PoC → Vulkan/WebGPU renderer                                                                    | research + PoC only; **no Vulkan lib**                                | GPU-client phase           |
| `iroh`                                                | authenticated P2P QUIC + content-addressed sync                                                               | **design-only, no D code**                                            | transport phase            |

**Feature blueprints** (studied, not referenced): a prior-art Rust
branch-cleanup TUI supplies the branch-management UX; general repo-management
concepts supply repo scan/catalog, workspace grouping, worktree isolation, the
portable repo-layout descriptor, and a symmetric provider-behind-RPC distributed
model; `mcl host` supplies drop-in D for host scan/enumerate/parallel-SSH; a
monorepo-tooling survey supplies the dub-overlay orchestration layer.

## Structure & extension

- **Shared-crate factoring, up front.** The VCS layer, the `sparkles:tui`
  framework, and the cross-cutting host helpers live in shared libraries, not the
  app — the natural sparkles monorepo shape — so they're reusable and dman stays
  thin. (A prior-art lesson: a shared crate set up but never populated means
  nothing ends up reusable.)
- **Documented extension points.** Because the `VcsRepo` abstraction is
  capability-based and meant to grow (jj at P3; new statuses/columns/subcommands),
  adding a backend / status / column / verb follows a maintained recipe, keeping
  the design easy to extend rather than a template to reverse-engineer.
