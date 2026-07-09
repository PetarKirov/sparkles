# `sparkles:dman` — Feature Requirements

_End-user–oriented: what dman **does**, from the user's perspective — capability
by capability, not implementation. For how it is built, see
[Architecture](./architecture.md); for delivery order, see
[Milestones](./milestones.md)._

## v1 — local Git repository, worktree & branch management

### Repository discovery & catalog

- **Scan** the filesystem for Git repositories from one or more roots — a
  marker-based walk honouring `.gitignore`, with max-depth, exclude globs, and
  parallelism, plus sensible default exclusions.
- **Catalog** discovered repos into a persistent store + an in-memory registry,
  and keep it self-healing (the filesystem is authoritative; the catalog is a
  secondary index rebuildable from a scan).
- **Manage** the catalog: `dman repo scan | list | add | remove | show`.
- **Select** the active repo by walking up from the current directory, or
  explicitly with `--repo PATH|URL` (canonicalised, remote-URL-resolvable),
  with clear, actionable errors and a non-interactive exit code.

### Repository → worktree → branch navigation

- Present repositories, their worktrees, and their branches as a single
  navigable **tree**.
- **Live-update** the view when a new scan completes or the working tree changes
  on disk (file-watching), without a manual refresh.

### Branch management (the core UX)

- **List** branches with **classification**: current, merged-into-trunk,
  stale / gone (upstream deleted), ahead / behind counts, and protected / trunk.
- **Trunk detection** (main / master / configured default) driving "merged" and
  "safe to delete".
- **Multi-select** with **safe delete** (merged only) and **force delete**,
  always mediated by a confirm step, a **dry-run**, and an **action log**.
- **Filter** by status, **sort** by several modes, and **search** with `/`
  including `@author` queries and autocomplete.
- Optional **PR status** column (GitHub via `gh`), cached, with an explicit
  refresh and cache-invalidation on branch delete.

### Worktree management

- **List** worktrees and map the current worktree to its branch.
- **Add / remove / prune** worktrees under a chosen on-disk layout convention
  (sibling directories or a dedicated worktrees root; a per-task branch-naming
  scheme).
- **Enter / exit** a worktree from the TUI or CLI (a shell-in-worktree UX).

### Surfaces & ergonomics

- Every operation is available **non-interactively** (CI-friendly, `--yes` for
  batch mutations) **and** through an **interactive, keyboard-driven TUI** that
  is resize-aware.
- dman can act as a **thin Git passthrough**: git-style arguments are parsed and
  re-emitted to real `git`, so unknown flags pass through unchanged.

## Later — distributed development manager

_These are deliberately out of v1 scope ([D2](./DECISIONS.md)) and are sketched
here so the v1 abstractions (VCS backend, config/state, command schema) are
designed to accommodate them._

### Host registry & remote hosts

- `dman host` to scan / enumerate / register machines, report hardware &
  software capability, and fan out commands over SSH in parallel.

### Repository sync across machines

- A **portable repo-layout descriptor** (order-independent, remote-URL-derived)
  as the unit of sync; clone / update each repo at its relative path; encrypted
  transfer between machines (age).

### Remote builds

- Drive Nix **remote / distributed builders**, provision dev-shells on remote
  hosts, and monitor remote build resource usage.

### Headless remote terminal-session multiplexer

- **Session persistence** — shells and coding agents whose lifetime is decoupled
  from any client connection; they survive disconnects and reattach.
- **Client-side layout** — panes, tabs, Kanban columns, and canvas workflows are
  managed and rendered exclusively on the client; the server holds only terminal
  state.
- **Viewport-aware multiplexing** — stream raw terminal feeds only for visible
  panes; send lightweight status metadata for background panes.
- **On-demand history** — fetch server-side scrollback dynamically when the user
  scrolls up in a pane.
- **Input routing** — keystrokes, resizes, and control commands route instantly
  to the exact targeted remote PTY.

### Clients & transport

- **GPU client** — desktop (Wayland + Vulkan, Win32 + Vulkan, macOS via
  MoltenVK), browser (WebGPU), and mobile (Android first, iOS later).
- **Transport** — SSH first, then peer-to-peer QUIC (iroh, or QUIC over
  WireGuard: Tailscale / NetBird).

## Non-goals (v1)

- **Not a Git reimplementation** — dman orchestrates `git`/`jj`, it does not
  replace them.
- **Not cross-platform in v1** — Linux-first by construction, because the async
  substrate is `io_uring`-based ([D3](./DECISIONS.md)); macOS / Windows follow
  once the substrate's peer backends land.
- **No distributed features in v1** — host registry, sync, remote builds, and
  the multiplexer are later milestones.
- **jj backend** and **monorepo/workspace orchestration** are deferred past v1.
