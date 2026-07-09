# `sparkles:dman` — Milestones

_The phased delivery plan and its dependency graph. Milestones graduate into a
normative `PLAN.md` (each independently green — builds + tests + lints) as their
boundaries firm up. For the capabilities each phase delivers, see
[Feature requirements](./feature-requirements.md)._

## Dependency graph

```
P0  Spec + scaffolding ─┬─ merge core-cli subcommands (args package)
                        ├─ add struct→argv render + run!T executor glue
                        └─ reconcile 3 TUI-widget branches onto base/text
                                     │
P1  Git VCS core (headless) ─────────┤  command schemas for git; VcsRepo iface
    repo scan / catalog / select     │  (Git-first, jj-shaped): root, default
    branch + worktree ops            │  branch, classification, ahead/behind,
    scriptable & non-interactive     │  dirty, worktree list/add/remove;
                                     │  spawned via event-horizon proc
                                     │
P2  Interactive TUI ★ NET-NEW ───────┤  raw-mode + alt-screen + event loop
    (biggest greenfield piece)       │  (event-horizon runOnce) + redraw/diff
    branch-mgmt UX · tree nav ·      │  over the one-shot renderers; selection /
    list+detail panes · PR (opt)     │  scroll / focus / keymap
                                     │
P3  Jujutsu backend ─────────────────┤  second impl behind the VcsRepo iface
                                     │
P4  Monorepo orchestration ──────────┘  dub overlay: members → task-DAG →
    (optional / parallel track)         --since affected → local cache

    ══════ distributed phase — event-horizon net + crypto Ed25519 ══════
P5  Host registry + SSH ───────── port mcl hosts.d/host_info.d; ControlMaster
        │                          transport (+ add Ed25519 sign/verify)
P6  Repo sync across machines ─── portable layout descriptor + age-encrypted
        │                          transfer; symmetric provider-behind-RPC
P7  Remote Nix builds ─────────── nix realise/copy-closure wrappers + ssh-ng://
        │
        ├─ (parallel, long-horizon) iroh transport:
        │     identity+QUIC+relay+NAT → blobs → docs-sync/gossip
        │
P8  Headless session multiplexer ── event-horizon M13 (PTY + Channel!T) +
        │                            ghostty headless; viewport-aware streaming,
        │                            dirty-row protocol, scrollback paging
P9  Vulkan/WebGPU client ────────── new sparkles:vulkan + windowing; desktop
                                     (Wayland/Win32/MoltenVK) → browser → mobile
```

## Phases

### P0 — Spec & scaffolding

The prerequisite merges are dependencies, not incremental work:

- Merge the `core-cli` subcommands (`args`) package into the dman tree.
- Add the pure `struct → argv` renderer to `core-cli`, and the `run!T` executor
  glue in dman (see [Command schema](./command-schema.md)).
- Reconcile the three TUI-widget branches (`tui-table` / `tree-view` /
  `text-wrapping`) onto the single `base.text` engine.

### P1 — Git VCS core (headless, scriptable)

- Command schemas for git; the `VcsRepo` backend interface (Git-first,
  jj-shaped): root detection, default-branch, branch classification,
  ahead/behind, dirty state, worktree list/add/remove, `status --porcelain=v2`.
- Repo scanner + catalog + registry; `repo scan/list/add/remove/show`; CWD-walk
  selection. Everything works non-interactively first — valuable and testable
  on its own.

### P2 — Interactive TUI ★

The largest net-new piece: the interactive shell (raw-mode, alt-screen, event
loop on `runOnce`, redraw/diff) over the one-shot renderers, then the
branch-management UX (classification, multi-select safe/force delete, dry-run,
action log, filters, sort, fuzzy/`@author` search), tree navigation, list/detail
panes, and optional PR enrichment.

### P3 — Jujutsu backend

A second implementation behind the `VcsRepo` interface (jj workspaces vs git
worktrees; change vs branch model). No prior art — designed from scratch.

### P4 — Monorepo orchestration _(optional / parallel)_

A dub-overlay task layer: member discovery → topological task-DAG → `--since`
affected slicing → local content-addressed cache. Could replace the current
hand-written CI + Nix-flake orchestration.

### P5–P7 — Distributed foundation

Gated on `event-horizon`'s `net` capability being exercised and on adding
Ed25519 sign/verify to `crypto`:

- **P5** Host registry + SSH — port `mcl` host scan/enumerate/parallel-SSH;
  ControlMaster transport.
- **P6** Repo sync — the portable layout descriptor + age-encrypted transfer;
  the symmetric provider-behind-RPC model.
- **P7** Remote Nix builds — `nix realise` / `copy-closure` wrappers over the
  already-bound C API + `ssh-ng://` remote store.

### iroh transport _(parallel, long-horizon)_

A native-D iroh port for peer-to-peer QUIC: identity + QUIC + relay + NAT
traversal → content-addressed blobs (repo content) → docs-sync CRDT + gossip
(metadata / notifications). Design-only today; SSH is the first transport, iroh
the strategic follow-on, and even then a minimal slice is the entry point.

### P8–P9 — Multiplexer & GPU client

- **P8** Headless session multiplexer — gated on event-horizon M13 (PTY port +
  `Channel!T`) and a headless `ghostty` wrapper: session persistence,
  viewport-aware streaming, a dirty-row wire protocol, scrollback paging, input
  routing.
- **P9** Vulkan/WebGPU client — new `sparkles:vulkan` + windowing layer; desktop
  (Wayland / Win32 / MoltenVK) → browser (WebGPU) → mobile (Android first).

## Key risks

1. **The interactive TUI shell (P2) is the biggest net-new risk.** Nothing in
   sparkles provides selection / scroll / focus / keymap / redraw — every widget
   is a one-shot string emitter. This, not the VCS logic, is the hard part of v1.
2. **The distributed half is gated on `event-horizon`**, which is Linux-only
   today and missing the cross-fiber `Channel!T` the PTY multiplexer needs.
   Choosing event-horizon as the v1 substrate ([D3](./DECISIONS.md)) makes dman
   a first-class driver of those remaining milestones and makes v1 Linux-first.
3. **iroh is a research design, not a library** (~38k LoC of QUIC alone, doubly
   gated). The distributed phase is SSH-first; iroh is a long-horizon parallel
   track.
