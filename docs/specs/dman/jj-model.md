# `sparkles:dman` — Designing for Jujutsu

_A research note grounding the git + jj VCS abstraction ([D8](./DECISIONS.md)),
distilled from the jj documentation. dman is Git-first; **jj is the P3 second
backend behind one interface**. This note captures how jj diverges from git and
what the abstraction must absorb; the interface itself lives in
[VCS backend](./vcs-backend.md)._

## Integration stance

- **Subprocess, not `jj-lib`.** jj-cli logic is still migrating into `jj-lib`, a
  stable `jj api` RPC is on the roadmap, and template field names are "usually
  stable but not guaranteed." So dman drives jj as a **subprocess** behind the
  same schema-driven `VcsRepo` ([D4](./DECISIONS.md)/[D5](./DECISIONS.md)) —
  never linking `jj-lib`. (This reaffirms D4 for the jj backend too.)
- **Git-first, colocated as the integration point.** A colocated repo (`.jj/`
  beside `.git/`) is "a git repo + a jj overlay"; dman can read `.git` directly
  but must know jj parks git at **detached HEAD** and leaves refs stale until an
  export runs. A **non-colocated** jj repo hides its git store at
  `.jj/repo/store/git` — not directly git-usable.
- **Machine-readable output is backend-pluggable.** git has stable porcelain
  (`--porcelain=v2`, `for-each-ref --format`, `-z`); jj has **none** on the
  commands that matter. jj's sanctioned path is the **template language**
  (`-T` + the `json()` function + `--no-graph`), decoded through `wired` — the
  _same_ `run!T` collector as `gh --json`, just not git's porcelain parser. Pin /
  gate the jj version; `wired`'s lenient decode (unknown keys ignored) absorbs
  minor template drift.

## The divergences the abstraction must absorb

1. **Two identities per commit.** A `commitId` (content hash = the git SHA under
   the GitBackend) _plus_ a stable **`changeId`** that survives rewrites (git has
   no equivalent). Change-IDs are 12 chars in reverse-hex `z..k`,
   prefix-addressable, with `xyz/N` offsets for divergent changes — **not** a git
   hex SHA, so parsers/matchers differ.
2. **No "current branch."** Bookmarks don't auto-advance on commit and are often
   absent; the working copy `@` is an anonymous change. `currentBranch` must be
   nullable; the real handle is the **working revision** (`@`'s change-id +
   commit-id), separate from any named ref.
3. **A ref points to 0..N targets.** Bookmarks can be **conflicted** (`main??`)
   and changes **divergent** — `name → one tip` fails. Tracking is 1-to-N
   (one local bookmark tracks several remotes), and ahead/behind is a **bound**
   (jj `SizeHint`), not a scalar `int`.
4. **No index; auto-snapshot.** "clean" means `@` is empty vs its parent;
   `staged`/`unstaged`/`untracked` are git-only (jj auto-tracks); and **reads
   mutate** — even `jj status` snapshots the working copy into a new commit, so
   pure scans must pass `--ignore-working-copy`.
5. **First-class conflicts.** A _commit_ can be conflicted (2..N-sided) and
   shared; git conflicts are transient in-progress-operation limbo. So
   merge/rebase need a **three-way outcome** (`Completed` |
   `CompletedWithConflictsRecorded` | `StoppedNeedsResolution`), and "clean
   working copy" ≠ "no conflicts."
6. **Operation log & real undo.** jj records every command as an operation with
   whole-view `jj undo` / `jj op restore`; git has none (the reflog is per-ref,
   prunable, not a faithful stand-in). Mutations can return an **undo token**, so
   dman offers genuine undo (e.g. undo a bookmark delete) on jj that it cannot on
   git.
7. **Workspaces ≠ worktrees.** `jj workspace add/list/forget` — no `remove` or
   `prune` (dman reconciles), `forget` keeps the files, and a workspace can go
   **stale** (`jj workspace update-stale`, no git analog). Each holds its own `@`
   (a commit, not a branch), and they are **not** git worktrees even in a
   colocated repo.

## Capability map (Design-by-Introspection)

The abstraction is **capability-based** — a common core both backends fill, plus
optional capabilities advertised per backend (the sparkles capability-by-presence
idiom). Callers gate git-only or jj-only fields/ops on these rather than assuming
git semantics:

| Capability                        | git     | jj                                |
| --------------------------------- | ------- | --------------------------------- |
| commit identity (hash)            | ✓       | ✓ (`== git SHA`)                  |
| stable change-id                  | —       | ✓                                 |
| named refs (branches / bookmarks) | ✓       | ✓ (may be unnamed / multi-target) |
| index / staging area              | ✓       | —                                 |
| first-class (committed) conflicts | —       | ✓                                 |
| operation log / undo              | —       | ✓                                 |
| sparse working copy               | partial | ✓                                 |
| workspace stale + `update-stale`  | —       | ✓                                 |

## Scanner & catalog impact

- **Marker set = `.git` _and_ `.jj/`.** Colocated (both present) → **one**
  `RepoRef`, jj-authoritative — dedupe on the physical root. A non-colocated jj
  repo (`.jj/` only) is silently **missed** by a `.git`-only scan. `.jj/repo` is a
  directory in the primary workspace but a **file pointer** in secondary
  workspaces — link secondaries to their primary; never descend into `.jj/`.
- **`RepoRef` gains a `backend` kind** (`git` | `jj`) and a `colocated` flag, so
  the catalog instantiates the right `VcsRepo` impl and capability set. In
  colocated git enumeration, filter the internal `refs/jj/keep/*` refs and the
  `@git` pseudo-remote so they don't surface as branches. `remotes[]` stays the
  portable identity (jj and git share the remote set).
- **Naming collision:** `RepoRef.workspace` (a grouping label) clashes with jj's
  "workspace" (a checkout); rename the grouping field (e.g. `group`) to avoid
  confusion.

See [VCS backend](./vcs-backend.md) for how the interface, data model, and
worktree layer reflect all of this.
