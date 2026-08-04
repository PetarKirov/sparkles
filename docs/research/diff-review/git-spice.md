# git-spice (Go)

A stacked-branches CLI (`gs`) that layers a branch-dependency graph, automated
restacking, and multi-forge change-request submission on top of the plain Git
CLI — with all of its own state versioned inside a local Git ref.

| Field             | Value                                                   |
| ----------------- | ------------------------------------------------------- |
| Language          | Go (1.26)                                               |
| License           | GPL-3.0                                                 |
| Repository        | [github.com/abhinav/git-spice][repo]                    |
| Documentation     | [abhinav.github.io/git-spice][docs]                     |
| Category          | Stacked-PR CLI                                          |
| First release     | `v0.1.0` — 2024-07-21 (alphas from 2024-05)             |
| Latest release    | `v0.31.2` — 2026-07-21                                  |
| Surveyed revision | `23005f9b87b6cd8625426f59ec2ecb48a2e3d147` (2026-08-02) |

## Overview

### What it solves

Working on a feature as a chain of small, individually reviewable branches
("stacks") is painful with raw Git: every amend to a lower branch invalidates
everything above it, every PR's base must be pointed at the previous branch by
hand, and merges force a cascade of manual rebases. git-spice tracks the
base-branch relationship for every branch it manages, restacks whole subtrees
with one command (`gs stack restack`, `gs upstack restack`), navigates the
stack relationally (`gs up`/`down`/`top`/`bottom`), and submits each branch as
a GitHub/GitLab/Bitbucket/Gitea/Forgejo change request whose base is the
branch below it (`gs stack submit`). The CLI is noun–verb (`gs branch create`,
`gs commit amend`) with memorable shorthands (`gs bc`, `gs ca`) — a structure
chosen explicitly for alias-ability (`DESIGN.md`, "Noun-verb CLI command
structure").

### Design philosophy

Two commitments shape the whole codebase. First, no reimplemented Git — from
`doc/src/guide/internals.md`:

> "git-spice does not use a third-party Git implementation. All operations are
> performed directly against the Git CLI, often relying on Git's plumbing
> commands. […] Most third-party Git implementations trail behind in feature
> parity."

Second, its own bookkeeping is itself Git data: state lives in JSON blobs in a
tree pointed at by a commit under the local ref `refs/spice/data`, and every
mutation commits with a message describing what prompted it. From `DESIGN.md`
("Tracking git-spice state in a local Git ref"):

> "The Git ref for git-spice state points to a commit object, not a tree. This
> will give us a historical operation log over time […] Branches are tracked
> as entries inside the same ref instead of ref-per-branch […] This has the
> advantage of not polluting .git with excessive noise."

`git log --patch refs/spice/data` is a working audit log of everything the
tool ever did. Configuration follows the same "reuse Git" instinct: all
options are `git config` keys under `spice.*` (`DESIGN.md`, 2024-08-04
entries), read through Kong flag bindings (`config:"..."` tags in e.g.
`log.go`).

## How it works

### 1. Diff computation & data model

git-spice computes no diffs of its own. The one diff-viewing command,
`gs branch diff` (`branch_diff.go`), resolves the tracked base and execs
`git diff base...branch` with stdout/stderr passed straight through to the
user's terminal and pager (`internal/git/diff_wt.go`, `DiffBranch`). Hunk
content, coloring, and word-level refinement are whatever the user's Git/delta
configuration produces; review-time diff rendering is delegated entirely to
the forge's web UI. The tool's internal "diff" needs are graph-level, not
textual: `internal/git/diff.go` parses `git diff-files`/`diff-index`
`--name-status -z` into `FileStatus` records (used to guard operations on
dirty trees), and `internal/git/merge_tree.go` wraps `git merge-tree`
(index-free merges) surfacing structured `MergeTreeConflictError`s with
per-file conflict details. Absence is the finding: a mature stacked-PR CLI
ships zero diff-presentation code and treats "show me the change" as someone
else's problem — the seam it exposes instead is _which two commits to
compare_ (`base...branch` per stack edge, plus an optional whole-stack
`WithComparisonURL` trunk-comparison link in `internal/forge/forge.go`).

### 2. Rendering & layout

The signature visualization is the branch tree of `gs log short` (`gs ls`) /
`gs log long` (`gs ll`). Rendering is layered:

- `internal/ui/fliptree` draws a tree _in reverse_ — children above parents,
  so trunk sits at the bottom exactly like the mental model of a stack:
  box-drawing joints (`┌─┴`, `├─`), a `□` node marker, multiline node views,
  and an `Offset`/`Height` viewport with `▲▲▲`/`▼▼▼` scroll markers for use
  inside interactive prompts (`internal/ui/fliptree/tree.go`).
- `internal/ui/branchtree` maps branch data onto that tree: current-branch
  highlighting, `(#123)` change IDs rendered as OSC 8 hyperlinks
  (`Item.ChangeURL`), open/closed/merged state glyphs, comment-resolution
  counts (`[☑️2/5💬]`), `needs restack` markers, worktree annotations, and
  per-rune highlight indexes for fuzzy-match emphasis
  (`internal/ui/branchtree/tree.go`).
- `log.go` assembles the presenter: `log long` additionally lists each
  branch's owned commits (short hash, subject, author date) under its node,
  fetched via `ListCommitsDetails` over the branch's owned range
  (`internal/handler/list`).

Styling uses `lipgloss` v2 with a theme layer (`internal/ui/style.go`,
`theme.go`); interactive prompts are `bubbletea` v2 widgets. A parallel
`--json` presenter (`jsonLogPresenter` in `log.go`) streams one JSON object
per branch — name, `down`/`ups` edges, commits, change status, push status —
an explicitly documented machine interface for scripting.

### 3. Intra-line & noise handling

Not applicable, and deliberately so: since git-spice renders no hunks, it has
no word-level refinement or whitespace suppression anywhere in the tree. The
closest analogue is _semantic_ noise suppression at the branch level:
`prepareBranch` (`internal/handler/submit/handler.go`) compares a branch's
tree hash against its base's tree and warns "Branch X has no changes compared
to its base" before letting the user submit an empty CR — an
equivalence-by-tree-hash check rather than a textual one.

### 4. Navigation, folding & scale

Navigation is graph-relational, not positional. `gs up [N]`/`gs down [N]`
walk the `BranchGraph` (`internal/spice/branch_graph.go` — an in-memory index
`byName`/`byBase` built from one state scan); when several branches sit above
the current one, `up.go` opens a `widget.BranchTreeSelect` prompt rendering
the candidate subtree. `gs top`/`gs bottom` jump to stack extremes; `gs trunk`
returns to trunk. `gs branch checkout` (`gs bco`) offers fuzzy selection over
the whole tree with per-rune match highlighting (the `*Highlights` fields in
`branchtree.Item`). The fliptree viewport (`Offset`/`Height` + scroll
markers) keeps huge trees usable inside prompts. `log short` folds by scope:
it shows only the current branch's upstack+downstack unless `--all` is given
(`log_short.go` help text). Scale guards are mostly about network, not
rendering: change-request status/comment-count lookups are batched per forge
call (`ChangeStatuses`, `CommentCountsByChange` in `internal/forge/forge.go`)
and only requested when the corresponding flag/config asks for them.

### 5. VCS & review integration

This is the heart of the tool.

**State model.** `internal/spice/state/storage` implements a tiny key–value
store whose Git backend (`storage/git.go`) reads and writes tree entries via
plumbing (`ListTree`, `MakeTree`, `CommitTree`, `SetRef`) under
`refs/spice/data`. Keys: `repo` (trunk + remote name), `branches/<name>`
(JSON: base name + base hash, upstream branch, forge-namespaced change
metadata `{"github": {...}}`, and `mergedDownstack` history), `templates`
(cached CR templates), `rebase-continue`, `prepared` (`state/branch.go`,
`doc/src/guide/internals.md`). Branch mutations go through a transaction
(`BeginBranchTx`) that commits with a human-readable message.

**Restack machinery.** The correctness core is
`internal/spice/replay_range.go`: `branchBaseInfo` reconciles the _recorded_
base hash with the _actual_ Git graph, computing the branch's ownership
boundary `Upstream` (the exclusive lower bound of commits the branch owns)
from the recorded hash, the merge base, and `git merge-base --fork-point` as
fallbacks — each case documented with ASCII commit-graph diagrams covering
external rebases, branches reset onto the base, bases that merged the branch,
and retarget-without-rebase. `IsRestacked()` is then simply
`MergeBase == BaseHead && !UpstreamDescendsFromBase`, and `Service.Restack`
(`internal/spice/restack.go`) runs one `git rebase --onto BaseHead
ReplayBoundary branch` (autostash, quiet) and records the new base hash.
State self-heals: `reconcileRecordedBaseHash` persists boundaries recovered
from the graph even when the user rebased outside git-spice. Multi-branch
operations (`stack restack`, `upstack restack`, `branch onto`) compose this
per-edge primitive.

**Conflict resumption.** Any interrupted rebase is "rescued"
(`internal/spice/rebase.go`, `RebaseRescue`): the command that must re-run is
appended to a _queue_ of continuations persisted at `rebase-continue` in the
state ref (`state/continue.go`), because one user command can trigger several
independent interruptible rebases (`DESIGN.md`, "Rebase continuations need a
queue"). `gs rebase continue` pops and re-runs continuations in a loop;
commands are written to be idempotent so re-running skips completed work.

**Forge abstraction.** `internal/forge/forge.go` defines `Definition` (forge
before binding to a remote) → `Forge` (bound, can parse repo paths and run
auth flows) → `Repository` (the ~20-method surface: submit/edit/merge change,
batched `ChangeStatuses`, CI checks, comment CRUD + listing, templates).
Change IDs and metadata are _opaque JSON_ to the core — each forge
marshals/unmarshals its own (`ChangeMetadataCodec`), which is how one
`branches/<name>` schema serves five forges. Capability discovery is by
optional interface (`WithChangeURL`, `WithNavigationReference`,
`WithComparisonURL`) — a Go-flavored design-by-introspection: forges that
cannot build a comparison URL simply don't implement the interface and the
feature silently disappears. Registered forges (`main.go`): Bitbucket,
Forgejo, Gitea, GitHub (in-house GraphQL gateway,
`internal/gateway/github/graphql.go`), GitLab (REST) — plus `shamhub`, a
fully scriptable in-process fake forge used by the ~393 `testscript`
end-to-end scripts under `testdata/script/`.

**Review UX on the forge.** Submission (`internal/handler/submit/handler.go`)
pushes each branch and creates/updates a CR whose base is the tracked base
branch, refusing with guidance when the base itself is unsubmitted
(`ErrUnsubmittedBase`). Every submitted CR gets a _navigation comment_ — a
Markdown nested list of the whole stack with a `◀` marker on the current CR —
generated by `internal/forge/stacknav/nav.go` (linear downstack, then a DFS
over upstack subtrees) and kept up to date on every submit
(`nav_comment.go`; configurable `always`/`never`/`multiple`). Merged
branches remain visible in later comments via the `mergedDownstack` history
propagated upward on merge (`DESIGN.md`, 2024-12-01). `gs repo sync` closes
the loop: fetch trunk, detect merged/closed CRs via batched forge status
queries plus local ancestry (`internal/handler/sync/handler.go`,
`findLocalMergedBranches` — squash/rebase merges are detected via forge
state, with a head-mismatch prompt guarding against deleting unpushed work),
delete the branches, restack their upstacks, and retarget upstack CRs.
`FindStaleBases` (`internal/spice/stale_base.go`) performs the same
merged-base detection on demand for submit-time warnings. `gs stack merge`
drives forge merges through a local scheduler (`internal/mergequeue`) that
waits for mergeability/CI (`ChangeMergeability`, `ChangeChecks`).

**Comparison to av (Aviator).** Surveyed against a local checkout of
[aviator-co/av][av] at `6473453679a3139630f9a454e6f9b87a07ceab10`
(2026-07-10). Both are Go noun–verb stacked-branch CLIs shelling out to Git,
but the contrasts are instructive: av stores its branch metadata in a plain
JSON file, `.git/av/av.db`, behind an in-memory read/write-transaction layer
(`internal/meta/jsonfiledb/`) — mutable, unversioned, invisible to `git log`
— where git-spice's ref-backed store gives a free operation log and
worktree-shared state. av's per-branch record (`internal/meta/branch.go`)
carries `Parent` (with an explicit `Trunk` flag and pinned parent `Head`
hash) and a `MergeCommit`, structurally close to git-spice's
`base{name,hash}`; but av has nothing like the `branchBaseInfo`
ownership-boundary reconciliation — the documented failure modes git-spice
handles (external rebases, retarget-without-rebase) are exactly where such
tools historically lose commits. av is GitHub-only and couples to Aviator's
hosted merge-queue service; git-spice is forge-plural via the opaque-metadata
`Forge` interface and needs no service. av's `av pr` posts a similar
stack-visualization comment, so the navigation-comment pattern is
ecosystem-standard rather than git-spice-specific.

### 6. Architecture & reuse

A single static Go binary. CLI wiring is Kong with dependency-injection-style
`BindToProvider` (`log.go`, `AfterApply` hooks); since 2025, shared business
logic lives in domain handlers (`internal/handler/{submit,restack,sync,
checkout,list,...}`) that declare minimal consumer interfaces and are
unit-tested with generated mocks — an explicit replacement for a too-broad
`spice.Service` god object (`DESIGN.md`, 2025-07-12). Layering is clean and
each layer is a reusable idea:

- `internal/git` — a porcelain-free Git driver: every operation is a typed
  request struct over the CLI with `-z`/plumbing parsing (`rev_list.go`,
  `merge_tree.go`, worktree-scoped `*_wt.go` variants).
- `internal/spice/state/storage` — versioned KV-in-a-git-ref, usable by any
  tool wanting auditable local state without touching the working tree.
- `internal/spice` — the graph/restack algebra (`BranchGraph`,
  `branchBaseInfo`, `RebaseRescue`).
- `internal/forge` + `stacknav` — the multi-forge port/adapter seam with
  optional-interface capabilities.
- `internal/ui/fliptree`, `branchtree` — standalone inverted-tree renderers.

The e2e strategy — `rogpeppe/go-internal` testscript txtar scripts driving
the real binary against the `shamhub` fake forge — makes forge behavior
testable offline and is arguably the most reusable piece of engineering
practice in the repo.

## Strengths

- The `branchBaseInfo` ownership-boundary reconciliation is the most
  carefully reasoned restack core in the stacked-PR space: every edge case is
  diagrammed in-source, and state self-heals after external Git operations.
- State in a versioned Git ref: auditable (`git log --patch refs/spice/data`),
  shared across worktrees, zero working-tree pollution, transactional with
  meaningful commit messages.
- Forge abstraction with opaque per-forge metadata and optional-interface
  capabilities scales to five forges without the core knowing any of them.
- Continuation _queue_ for interrupted rebases makes deeply composed
  operations (`branch onto` → N × `upstack restack`) resumable with one
  `gs rebase continue`.
- Inverted fliptree rendering matches the stack mental model; OSC 8 links,
  comment counts, and push status pack review state into one glanceable tree;
  `--json` is a first-class machine surface.
- 393 offline end-to-end scripts against an in-process fake forge.

## Weaknesses

- No diff presentation at all: `gs branch diff` is a thin exec of `git diff`;
  reviewing content happens on the forge. There is no local per-stack-edge
  review surface, no interdiff between submitted revisions
  (range-diff-style), and no comment reading/writing UX beyond counts.
- Restacking is `git rebase` per edge — a K-branch stack is K sequential
  subprocess rebases with working-tree checkouts, not an in-memory replay
  (contrast Jujutsu); large stacks pay linear worktree churn.
- Navigation comments are plain Markdown lists maintained by edit-in-place;
  concurrent submitters can race, and the forge comment is the only
  stack-level review artifact.
- GPL-3.0 licensing limits embedding of the (otherwise cleanly layered)
  internal packages, which all live under `internal/` anyway.

## Key design decisions and trade-offs

| Decision                                        | Rationale                                                                      | Trade-off                                                                                |
| ----------------------------------------------- | ------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------- |
| Shell out to the Git CLI, never reimplement     | Feature parity with worktrees/sparse-checkout for free (`guide/internals.md`)  | Subprocess latency per operation; output-format parsing coupling                         |
| State as JSON blobs in a commit-backed ref      | Operation log, worktree sharing, transactional updates (`DESIGN.md`)           | Custom KV-store plumbing; state invisible to users who don't know the ref                |
| Recorded base _hash_ + graph reconciliation     | Distinguish branch-owned commits from base commits even after external rebases | The subtlest code in the repo (`replay_range.go`); fork-point heuristics can still guess |
| Opaque forge metadata + optional interfaces     | One branch schema, five forges; features degrade silently per forge            | Core cannot reason about forge data; capability checks are runtime type assertions       |
| Continuation queue persisted in state           | Multi-rebase operations resumable across processes (`DESIGN.md` 2024-05-28)    | Commands must be idempotent/re-entrant by construction                                   |
| Configuration via `git config` (`spice.*`)      | Familiar hierarchy (system/user/repo/worktree) at zero UX cost (`DESIGN.md`)   | No schema validation; discoverability depends on docs                                    |
| Review artifacts = forge comments, not local UI | Zero-install for reviewers; works in any browser                               | No local review loop; stack context lives in an editable Markdown comment                |

## Sources

- Local checkout at `/home/petar/code/repos/go/git-spice`, revision
  `23005f9b87b6cd8625426f59ec2ecb48a2e3d147` (2026-08-02) — primary; key
  files: `DESIGN.md`, `internal/spice/replay_range.go`,
  `internal/spice/restack.go`, `internal/spice/state/branch.go`,
  `internal/spice/state/storage/git.go`, `internal/forge/forge.go`,
  `internal/forge/stacknav/nav.go`, `internal/handler/submit/handler.go`,
  `internal/ui/fliptree/tree.go`, `internal/ui/branchtree/tree.go`,
  `log.go`, `branch_diff.go`, `up.go`
- `doc/src/guide/internals.md`, `doc/src/guide/concepts.md` (in-tree docs)
- [git-spice documentation site][docs]
- Local checkout of [aviator-co/av][av] at
  `6473453679a3139630f9a454e6f9b87a07ceab10` (2026-07-10) for the comparison
  (`internal/meta/branch.go`, `internal/meta/jsonfiledb/`)

<!-- References -->

[repo]: https://github.com/abhinav/git-spice/tree/23005f9b87b6cd8625426f59ec2ecb48a2e3d147
[docs]: https://abhinav.github.io/git-spice/
[av]: https://github.com/aviator-co/av/tree/6473453679a3139630f9a454e6f9b87a07ceab10
