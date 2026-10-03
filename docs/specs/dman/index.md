---
status: draft
owner: sparkles:dman
---

# `sparkles:dman` — Development Manager

## Abstract

`sparkles:dman` manages the Git repositories, worktrees and branches on a
developer's machine. It discovers repositories on disk, keeps a catalog of
them, and presents each as a tree of worktrees and branches. It classifies
every branch, for example as merged or as having lost its upstream, and makes
cleanup safe: each destructive step can be previewed, must be confirmed
interactively or by an explicit flag, and a deleted branch can be restored.
Every operation works both as a prompt-free command for scripts and in an
interactive terminal interface. Its version-control layer and its event loop
are chosen to carry a second backend, Jujutsu, and a distributed phase of
remote hosts, cross-machine sync, remote builds and persistent terminal
sessions.

## Introduction

A developer who works across many repositories accumulates worktrees and
branches: one per task, per review, per experiment. Git answers questions
about them one repository and one command at a time. Which branches are
already merged into trunk? Whose upstream branch was deleted? Which worktree
has which branch checked out, and which repositories exist on this disk at
all? Cleaning up is destructive, and a wrong guess about any of these answers
deletes work.

Branch-cleanup scripts and Git aliases cover pieces of this, but each one
hard-codes assumptions such as the trunk's name, the protected branches and
the worktree layout. Most work inside one repository, and most are either
scriptable or interactive, not both. A tool whose model is shaped like Git
also cannot grow a second version-control system. Jujutsu has two identities
per commit, no current branch, no staging area, and conflicts that are
recorded rather than blocking, so a Git-shaped interface would have to be
rewritten to admit it.

dman orchestrates the real tools as subprocesses instead of reimplementing
them. One annotated struct, its [command schema](../../glossary.md#command-schema),
both parses dman's own command line and renders the arguments of each tool
dman invokes, and the tool's machine-readable output is decoded into typed
values. Version-control access sits behind a backend interface with a common
core that every backend fills and optional operations that a backend either
offers or lacks, so Git ships first and Jujutsu fits without reshaping. All
I/O runs on the completion-based event loop of `sparkles:event-horizon`:
subprocesses, file watching, signals and the interactive frame loop alike.
Services reach code through a [capability row](../../glossary.md#capability-row),
so tests substitute fakes.

Three rules govern state, safety and policy. The filesystem is authoritative
for which repositories exist: the catalog is an index that a fresh scan can
rebuild. Every destructive operation shows the exact command it will run,
offers a dry run, and logs each outcome; a branch delete records the ref it
removed, so it can be undone.
Policy is data, so every assumption dman detects, such as the trunk branch or
the scan roots, has a configuration override.

The first version is local, single-machine and Git-only. It is not a Git
reimplementation. It targets Linux only, because the event loop it builds on
is based on `io_uring`; other platforms depend on that loop's other
backends. A Jujutsu backend, task orchestration across a monorepo's packages,
filesystem snapshots, and the whole distributed phase are out of scope for
that version. The distributed phase comprises a host
registry with SSH fan-out, repository sync, remote Nix builds, a headless
terminal-session multiplexer whose sessions outlive their clients, and GPU
clients over SSH and then peer-to-peer QUIC. These pages describe those
phases only so that the first version's abstractions can accommodate them.

[Feature requirements](./feature-requirements.md) states what dman does for
its users, and [Architecture](./architecture.md) how it composes the Sparkles
libraries. [Command schema](./command-schema.md) and
[CLI surface](./cli-surface.md) cover the command layer, and
[Config](./config.md) the settings model. The per-repository layer is in
[VCS backend](./vcs-backend.md) and [Designing for jj](./jj-model.md), the
cross-repository layer in [Repo catalog](./repo-catalog.md) and
[Workspaces](./workspaces.md), and the interactive interface in
[TUI shell](./tui-shell.md). Delivery order and risks live in
[Milestones](./milestones.md), and the reasons for each foundational choice in
the [decision log](./DECISIONS.md).

## Documentation map

| Page                                              | What it covers                                                                                                              |
| ------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| **Overview** (this page)                          | abstract · introduction · map                                                                                               |
| [Feature requirements](./feature-requirements.md) | what dman does for its users — v1 capabilities and the later distributed features; non-goals                                |
| [Architecture](./architecture.md)                 | how dman composes the sparkles stack, the async substrate, the VCS abstraction, the TUI shell, and building-block readiness |
| [Command schema](./command-schema.md)             | the bidirectional, `wired`-based CLI/command pillar — one struct schema for both dman's own CLI and invoking git/jj/…       |
| [CLI surface](./cli-surface.md)                   | the concrete `dman` command tree — repo/branch/worktree subcommands, scripting, machine output                              |
| [Config](./config.md)                             | the settings model — policy-as-data, overrides for every auto-detected assumption                                           |
| [VCS backend](./vcs-backend.md)                   | the per-repo layer — branch/worktree/status data model and the `VcsRepo` backend                                            |
| [Designing for jj](./jj-model.md)                 | how jj diverges from git and the capability-based abstraction the P3 backend needs                                          |
| [Repo catalog](./repo-catalog.md)                 | the cross-repo layer — scan → catalog → registry → selection, and persistence                                               |
| [Workspaces](./workspaces.md)                     | multi-repo grouping — `string[]` tags, the directory group, and workspace verbs                                             |
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
