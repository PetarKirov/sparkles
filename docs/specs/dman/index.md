# `sparkles:dman` — Development Manager

_Working codename `dman` ([D1](./DECISIONS.md)). These are **living design
documents**, not yet a normative spec — they state what to build, in what order,
and why. Foundational decisions are recorded in the [decision log](./DECISIONS.md)._

## What `dman` is

**v1 (near-term):** a Git-first **repository / worktree / branch management**
tool — a scriptable core plus an interactive TUI, on a single machine. It
discovers repositories on disk, catalogs them, and gives fast, safe branch and
worktree operations, navigated as a repo → worktree → branch tree.

**Long-term:** a distributed **development manager** — host registry and SSH
remote hosts, repository sync across machines, remote Nix builds, and ultimately
a **headless remote terminal-session multiplexer** (tmux/zellij-like) whose
sessions outlive clients, with a GPU (Vulkan/WebGPU) client that owns all
windowing and layout. Transport grows from SSH to peer-to-peer QUIC
(iroh / QUIC-over-WireGuard). Jujutsu (`jj`) joins as a second VCS backend after
the Git-first foundation lands.

## Documentation map

| Page                                              | What it covers                                                                                                              |
| ------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| **Overview** (this page)                          | what dman is · navigation                                                                                                   |
| [Feature requirements](./feature-requirements.md) | what dman does for its users — v1 capabilities and the later distributed features; non-goals                                |
| [Architecture](./architecture.md)                 | how dman composes the sparkles stack, the async substrate, the VCS abstraction, the TUI shell, and building-block readiness |
| [Command schema](./command-schema.md)             | the bidirectional, `wired`-based CLI/command pillar — one struct schema for both dman's own CLI and invoking git/jj/…       |
| [CLI surface](./cli-surface.md)                   | the concrete `dman` command tree — repo/branch/worktree subcommands, scripting, machine output                              |
| [VCS backend](./vcs-backend.md)                   | the per-repo layer — branch/worktree/status data model and the `VcsRepo` backend                                            |
| [Designing for jj](./jj-model.md)                 | how jj diverges from git and the capability-based abstraction the P3 backend needs                                          |
| [Repo catalog](./repo-catalog.md)                 | the cross-repo layer — scan → catalog → registry → selection, and persistence                                               |
| [TUI shell](./tui-shell.md)                       | the interactive UI — the `sparkles:tui` immediate-mode framework and the dman shell's interaction model                     |
| [Milestones](./milestones.md)                     | the phased plan, dependency graph, and key risks                                                                            |
| [Decisions](./DECISIONS.md)                       | the foundational decision log (ADR-style)                                                                                   |

## Dependency snapshot

dman composes three existing sparkles libraries; the `io_uring` dependency stays
out of the pure arg-parsing layer:

```
base  ◀──  wired  ◀──  core-cli          (pure / CTFE; no io_uring)
base  ◀──  event-horizon                  (io_uring; Linux-first)
dman  ──▶  { core-cli, wired, event-horizon }
```

See [Architecture](./architecture.md) for how these fit together and
[Decisions](./DECISIONS.md) for why.
