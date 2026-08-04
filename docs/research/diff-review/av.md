# av — Aviator CLI (Go)

A GitHub-centric stacked-PR CLI that stores a parent-pointer branch graph plus per-branch branching-point SHAs in a JSON file under `.git/av/`, replays `git rebase --onto` across the graph with a serializable, conflict-resumable sequencer, and mirrors the stack into every PR body as an HTML-comment-fenced JSON block plus a human-readable stack list — while deliberately computing and rendering **no diffs of its own**.

| Field             | Value                                                                         |
| ----------------- | ----------------------------------------------------------------------------- |
| Language          | Go (1.26)                                                                     |
| License           | MIT (Copyright 2022 Aviator Technologies, Inc., `LICENSE`)                    |
| Repository        | <https://github.com/aviator-co/av>                                            |
| Documentation     | <https://docs.aviator.co/aviator-cli>; man pages in `docs/*.1.md`             |
| Category          | stacked-pr                                                                    |
| First release     | 2022 (per `LICENSE` copyright; tag history not present in the surveyed clone) |
| Latest release    | `v0.1.45` (2026-07-10, the only release tag in the surveyed clone)            |
| Surveyed revision | `6473453679a3139630f9a454e6f9b87a07ceab10` (2026-07-10)                       |

## Overview

### What it solves

Stacking — splitting a large change into a chain (or tree) of small dependent PRs — is miserable with raw git: every amend to a lower branch invalidates the branch points of everything above it, and GitHub has no native notion of "PR B depends on PR A". `av` is the client-side fix: "`av` is a command-line tool that helps you manage your stacked PRs on GitHub. It allows you to create a PR stacked on top of another PR, and it will automatically update the dependent PR when the base PR is updated" (`README.md`). The feature list is entirely stack lifecycle: create stacked branches (`av branch`), visualize (`av tree`), restack after parent changes (`av restack`, `av sync`), submit the whole stack as PRs (`av pr --all`), split/reorder commits and branches (`av split-commit`, `av reorder`), and clean up merged branches (`av tidy`, prune during `av sync`). It optionally talks to Aviator's hosted merge-queue service (`av pr status` via `internal/avgql`), but works against plain GitHub with only a token.

### Design philosophy

Three commitments are visible in the tree:

1. **Metadata lives beside git, not inside it.** "Since `av` needs to keep track of the extra information about branches such as the parent branch, we have `av-branch`(1) to create a new branch and track the necessary information. This metadata is stored in `.git/av/av.db`. We call the branches that `av` has metadata for as 'managed branches', and the branches that av doesn't have metadata for as 'unmanaged branches'" (`docs/av-git-interaction.7.md`). Branches created outside `av` can be adopted (`av adopt`, backed by `internal/treedetector`), and metadata for branches deleted with plain `git branch -D` is garbage-collected on the next run.
2. **Flat commands, resumable operations.** "The CLI follows a flat command structure where commands are added as root-level commands rather than nested subcommands … The project has migrated away from layered commands (e.g., `av stack commit` → `av commit`)" (`CLAUDE.md`). Every long-running operation (sync, restack, reorder) serializes its full plan to a JSON state file so `--continue`/`--abort`/`--skip` can resume after a rebase conflict.
3. **The PR itself is the transport for stack topology.** Each PR body carries both a machine block — "This information is embedded by the av CLI when creating PRs to track the status of stacks when using Aviator. Please do not delete or edit this section of the PR." (`PRMetadataCommentHelpText`, `internal/actions/pr.go`) — and a human-readable stack list, so reviewers on github.com see the dependency chain without any browser extension.

## How it works

### 1. Diff computation & data model

`av` computes no diffs. `internal/git/diff.go` is a 65-line shell-out: `git diff --exit-code [--quiet] [--color=always] <specifiers> -- <paths>`, returning `Diff{Empty bool, Contents string}` — the contents are git's byte stream, never parsed. In practice the struct is used almost exclusively in `Quiet` mode as a **boolean dirtiness oracle**: is the worktree clean before rebasing (`Sequencer.checkNoUnstagedChanges`), does a local branch differ from its remote counterpart (`getStackTreeBranchInfo` in `cmd/av/tree.go`, feeding a `NeedSync` flag).

The one genuinely diff-shaped piece of intelligence is **base selection** in `cmd/av/diff.go`: `av diff` shows "the diff between the working tree and the parent branch", and picks the base so that parent churn is excluded. For a stack root it diffs with `--merge-base <remote>/<trunk>` — the in-source comment explains that without it, trunk having advanced would make the diff "show that we're undoing the changes that were introduced in Y", and notes "This roughly matches the diff that GitHub will show in the pull request files changed view". For a non-root branch it diffs against the **recorded branching point** (`branch.Parent.BranchingPointCommitHash`), not the parent's current HEAD — "We can't just use merge-base here to account for the fact that one might be amended (not just advanced)". If the parent has moved past the recorded point, the command prints a "not up to date … Run `av sync`" warning _after_ the pager exits and returns exit code 1.

That branching point is the heart of the data model. `internal/meta/branchstate.go`:

```go
type BranchState struct {
    Name  string `json:"name"`
    Trunk bool   `json:"trunk,omitempty"`
    // The branching point commit hash. … recorded when we start a new branch
    // off of a parent branch … This allows us to later identify which commits
    // belong to the child branch when syncing with the parent branch.
    BranchingPointCommitHash string `json:"head,omitempty"` // "head" for historical reasons
}
```

`meta.Branch` adds `Parent BranchState`, `PullRequest *PullRequest` (GraphQL ID, number, permalink, state), `MergeCommit string`, and `ExcludeFromSyncAll bool` (`internal/meta/branch.go`). There is no child list — children are derived by scanning all branches for matching `Parent.Name` (`meta.Children`), sorted by name for determinism. Graph algorithms (`PreviousBranches`, `SubsequentBranches`, `Root`, `Trunk`, `ValidateNoCycle`) are recursive walks over this parent-pointer map, with cycle guards that log-and-skip.

### 2. Rendering & layout

There is no diff rendering: `av diff` runs `git diff` with `Interactive: true` and deliberately avoids the internal `repo.Diff` wrapper "since that sets the `--exit-error` flag which in turn disables the output pager. We want this command to behave similarly to default `git diff` for the user" (`cmd/av/diff.go`). Colors, word-diff, pager — all inherited from the user's git config.

What `av` does render is the **stack tree**. `internal/utils/stackutils/render_tree.go` is a compact (60-line) bottom-up renderer: children are printed _above_ their parent (mirroring `git log` orientation — newest work at the top, trunk at the bottom), each subtree indented into its own column, and sibling columns joined into the parent with box-drawing: ` ├─┴─┘` rows for >2-way merges, ` │` continuation rows otherwise. Each node is a `* ` bullet whose right-hand side is an arbitrary **multi-line** cell supplied by a callback (`branchDataFn`); `lipgloss.JoinHorizontal(lipgloss.Top, lhs, branchData)` pads the connector column (`lipgloss.Height` counts the cell's lines) so a branch can carry a second line with its PR permalink or "No pull request" (`renderStackTreeBranchInfo`, `cmd/av/tree.go`). Sibling order is not chronological: `BuildTree` (`stackutils.go`) sorts the subtree containing the _current_ branch first, then alphabetically — the active stack always renders in the top column.

The same renderer is reused as a **live progress display**: during `av sync`/`av restack`, the Bubble Tea `RestackModel.View` (`internal/sequencer/sequencerui/ui.go`) re-renders the tree every frame, prefixing each branch with `✓` (synced, green), a spinner (in progress), `⚠ … (skipped: reason)`, `✗` (aborted), plus a 7-char commit SHA suffix and `(merged)` markers. A performance comment there is instructive: branch SHAs are resolved via a direct ref lookup instead of `ResolveRevision` because "revision resolution attempts hash-prefix expansion, which scans the entire pack index and is extremely slow on large repositories — especially here, where View is evaluated on every render frame".

### 3. Intra-line & noise handling

Does not apply — `av` never inspects diff content, so there is no word-level refinement, whitespace policy, or formatting-noise classification anywhere in the tree. The nearest analog operates at _stack_ granularity: the branching-point discipline of §1 is noise suppression one level up — it keeps a child PR's diff free of the parent's churn, exactly the property GitHub's own stacked-base PR view loses when the base branch is force-pushed. Content-level noise is delegated wholesale to `git diff` and to GitHub's web UI.

### 4. Navigation, folding & scale

Navigation is between _branches_, not within diffs. `av next`/`av prev` walk the parent/child pointers; `av switch` (`cmd/av/switch.go`, 359 lines) is a Bubble Tea picker over the rendered stack tree that also accepts a PR URL and resolves it to the local branch. `av tree --current` restricts the forest to the current stack. Scale guards are for repository size, not diff size: the per-frame ref-lookup optimization of §2, and `jsonfiledb`'s copy-on-read state (`internal/meta/jsonfiledb/db.go` — a read transaction copies the whole state map under a mutex, acceptable because the DB holds only branch metadata, not content). Nothing folds or windows anything — output is plain scrollback.

### 5. VCS & review integration

This is the substance of the tool.

**Git plumbing.** A hybrid: behavior-critical operations (rebase, push, diff, rev-list, merge-base) shell out to the system `git` binary (`Repo.Run`/`Repo.Git`, `internal/git/git.go`) so semantics match the user's git exactly; read-only inspection (refs, commit objects, remote fetch refspecs) uses go-git v6 in-process (`repo.GoGitRepo()`).

**Restacking.** `internal/sequencer/planner` turns a target set (current stack / current+parents / all) into an ordered `[]RestackOp{Name, NewParent, NewParentIsTrunk, NewParentHash}`; `internal/sequencer/sequencer.go` executes one op at a time as `git rebase --onto <newParentHash> <branchingPoint> <branch>` — the recorded branching point makes the "which commits belong to this branch" question exact even when the parent was amended. The whole `Sequencer` struct "should be JSON serializable. The caller is expected to save this to file when the sequencer needs to be paused" — on conflict it is written to a per-worktree state file (`.git/av/stack-sync-v2.state.json` et al., `internal/git/state_file.go`) and `av sync --continue/--abort/--skip` rehydrates it. After each successful rebase the branch's `Parent.BranchingPointCommitHash` is atomically updated in the metadata DB (`postRebaseBranchUpdate`). Edge cases are handled explicitly: an ancestor check skips no-op rebases that would otherwise replay shared commits into conflicts; branches checked out in _other worktrees_ are detached before rebasing and restored after; dirty worktrees cause that branch **and its entire descendant subtree** to be skipped with per-branch reasons (`PrepareWorktrees`, `skipDescendants`) rather than hard-failing the run.

**Sync pipeline.** `av sync` (`cmd/av/sync.go`) chains phases as Bubble Tea models via continuation callbacks: trunk prompt → pre-sync hook → GitHub fetch → sequencer → push (`ghui.GitHubPushModel`, with `ask/yes/no` policy) → prune merged branches (`gitui.PruneBranchModel`) → optional trunk fast-forward. The fetch phase (`internal/gh/ghui/fetch.go`) is where merge detection lives, with three mechanisms layered: (a) querying each branch's PR state via GraphQL (`UpdatePullRequestState`); (b) scanning new trunk commit messages for GitHub's `closes #N` / merge annotations (`FindClosesPullRequestComments` over `git log` output) to recover the merge commit even when the PR object lags; (c) _propagating_ merge commits from children to parents — verified by an ancestor check against the trunk ref before trusting it (`shouldPropagateMergeCommit`). `PlanForSync` then reparents children of merged branches directly onto trunk. `MergeCommit != ""` branches are never rebased again.

**PR creation.** `actions.CreatePullRequest` (`internal/actions/pr.go`, 985 lines) pushes with `--force-with-lease` (plain `--force` only with `av pr --force`), refuses to create a PR whose parent branch has no PR yet, seeds the editor with the commit list / PR template / previously saved draft (aborted editor sessions are saved to `av-pr-<branch>.md` and reused), auto-drafts titles containing "WIP", and writes the result back to branch metadata. All GitHub access is GraphQL v4 (`shurcooL/githubv4`, `internal/gh/client.go`), including GitHub Enterprise base-URL support; `UpdatePullRequestIfChanged` diffs desired vs. current field values to avoid no-op mutations.

**Stack in the PR body.** Every PR body is rewritten (`AddPRMetadataAndStack`) to contain, between `<!-- av pr stack begin/end -->` markers, a collapsible `<details>` list of the stack — degenerate (linear) stacks render top-down as `* **#N**` bullets with a `➡️` marker on the current PR, trees render as nested bullets — wrapped in a `<table>` "for two reasons: 1. It actually looks nicer on GitHub 2. … Slack doesn't support and strips out `<table>` elements in unfurls" (`internal/actions/pr.go`). Below the user's text, between `<!-- av pr metadata` and `-->`, a fenced JSON `PRMetadata{parent, parentHead, parentPull, trunk}` records the topology machine-readably; `ParsePRBody` strips both blocks on read so user edits round-trip. `UpdatePullRequestWithStack` refreshes this in every PR of the stack after each submit/sync.

**Review itself is out of scope.** Nothing in the tree reads review threads, comments, approvals, or file-level diffs; `av pr status` prints PR metadata (state, author, base ← head, URL) from GitHub, or — with an Aviator API token — merge-queue status, required-check results as ✅/❌/⌛ lines, and the queue's bot-PR checks (`cmd/av/pr_status.go` via `internal/avgql`). "Viewing a PR" in `av` means opening the browser (`av pr --open`, `browser.Open`). The absence is structural: `av` is a _write-side_ stack manager; the read side is GitHub's.

**Adoption & history surgery.** `internal/treedetector` reconstructs stack structure for unmanaged branches: for each branch it walks commits parent-ward (`object.NewCommitPreorderIter`) until hitting the trunk merge-base or a commit that is another branch's tip, producing a `BranchPiece` with either a resolved parent + merge-base or `PossibleParents` (ambiguity surfaced to an interactive selector) — merge commits abort detection (`ContainsMergeCommit`). `av reorder` (`internal/reorder`) exposes the whole stack as an editable, `git-rebase-todo`-style script of typed commands (`StackBranchCmd`, `PickCmd` with squash/fixup modes, `DeleteBranchCmd`) that parse/print round-trip and execute with the same interrupt/continuation machinery.

### 6. Architecture & reuse

Single Go binary, cobra CLI, flat command layout in `cmd/av/`. Long-lived logic sits in `internal/`: `meta` (data model + `DB`/`ReadTx`/`WriteTx` interfaces), `jsonfiledb` (the only DB implementation: whole-state JSON file, copy-on-write transactions), `sequencer`/`planner` (restack engine), `actions` (PR orchestration), `gh` (GraphQL client), `treedetector`, `reorder`. TUI is Bubble Tea v2 + lipgloss throughout; interactive commands compose a **stack of sequential views** (`uiutils.BaseStackedView`) where each phase model's completion callback appends the next — a continuation-passing pipeline rather than one monolithic model. E2E tests use `rogpeppe/go-internal` testscript plus a mock GitHub GraphQL server (`e2e_tests/mock_ghgql_server.go`), so the full sync/submit flows run hermetically.

Cleanly liftable ideas (none of the code depends on Aviator's service except `avgql`): the `BranchState`/branching-point metadata schema and its JSON-compat evolution (string-or-object `parent`, `UnmarshalJSON` alias trick), the serializable sequencer + per-worktree state files, the bottom-up tree renderer, the PR-body metadata/stack-comment contract (a de-facto wire format also readable by third parties), and the trunk-commit-scan merge detector.

## Strengths

- **Minimal, evolvable data model.** One parent pointer + one branching-point SHA per branch is enough to reconstruct per-branch commit ranges under amends, drive exact `rebase --onto` calls, and choose correct diff bases; the JSON compat shims show the schema surviving years of evolution in place.
- **Everything resumable.** Plans (sequencer ops, reorder scripts) are data, serialized on interruption; conflict handling reuses git's own rebase machinery and state, so users resolve conflicts with tools they already know.
- **Robust merge detection.** Three independent signals (PR state, trunk commit-message scan, child→parent propagation with ancestor verification) make `av sync` converge even with squash merges, lagging APIs, or out-of-band merges.
- **Worktree-aware and failure-tolerant restacking**: dirty trees skip subtrees with reasons instead of aborting; other worktrees are detached/restored around rebases.
- **Stack topology travels inside the PR** — visible to any reviewer on github.com with zero tooling, machine-recoverable from the body JSON.
- Hermetic e2e coverage of GitHub flows via a mock GraphQL server.

## Weaknesses

- **No diff surface at all.** `av diff` is a `git diff` launcher; there is no hunk model, no word-level or structural refinement, no side-by-side, no review-comment access — the entire read/review half of the PR lifecycle is delegated to GitHub's web UI.
- GitHub-only (GraphQL v4 baked in); no GitLab/Gerrit/Forgejo backends.
- The metadata DB is a single JSON blob copied per transaction — fine for branch counts, but no history/undo, and concurrent `av` processes are serialized only by an in-process mutex (cross-process races rely on last-write-wins of the whole file).
- Derived child lists via full-map scans and recursive walks are O(branches) per query — harmless here, but the model gives up indexed traversal.
- PR-body rewriting is invasive: every sync mutates all PR descriptions (mitigated by `UpdatePullRequestIfChanged`), and user content must round-trip through `ParsePRBody`'s marker stripping.

## Key design decisions and trade-offs

| Decision                                                            | Rationale                                                                                                 | Trade-off                                                                                        |
| ------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Store metadata in `.git/av/av.db`, not git refs/notes/config        | Atomic multi-field updates; trivially serializable; survives branch deletion for GC-on-next-run           | Invisible to git tooling; not pushed/shared; single-file write races across processes            |
| Record the branching-point SHA at branch creation                   | Exact commit ownership under parent _amends_ (merge-base only handles parent _advances_)                  | Must be maintained through every rebase; stale value ⇒ wrong diffs (hence the `av diff` warning) |
| Shell out to system git for rebase/push/diff; go-git for reads only | Bit-exact behavior with user's git (hooks, config, rerere); go-git avoids process spawn on hot read paths | Two git stacks to keep consistent; output parsing (`RebaseParse`) instead of typed results       |
| Sequencer as serializable data + per-worktree JSON state files      | `--continue/--abort/--skip` after conflicts; crash-safe; testable planning separated from execution       | State can go stale (guarded by `IsRebaseInProgress` check on load)                               |
| Embed stack + JSON metadata in every PR body                        | Reviewers see the stack natively on GitHub; topology recoverable from server data alone                   | Body churn on every sync; parsing user-edited HTML comments; Slack-unfurl workarounds            |
| No diff rendering; delegate to `git diff` + pager                   | Zero maintenance, users keep their delta/difftastic configuration via git's pager/difftool settings       | The tool cannot answer any content-level question; review stays in the browser                   |
| Flat command namespace (`av commit`, not `av stack commit`)         | Discoverability, shorter invocations; documented migration policy in `CLAUDE.md`                          | Legacy aliases linger (`av stack foreach`); root namespace crowds as features grow               |

## Sources

- Local checkout at `/home/petar/code/repos/go/av`, revision `6473453679a3139630f9a454e6f9b87a07ceab10` (2026-07-10) — primary; key files: `internal/meta/branch.go`, `internal/meta/branchstate.go`, `internal/meta/db.go`, `internal/meta/jsonfiledb/db.go`, `internal/sequencer/sequencer.go`, `internal/sequencer/planner/planner.go`, `internal/sequencer/sequencerui/ui.go`, `internal/actions/pr.go`, `internal/gh/ghui/fetch.go`, `internal/treedetector/detector.go`, `internal/reorder/`, `internal/utils/stackutils/render_tree.go`, `internal/utils/stackutils/stackutils.go`, `internal/git/diff.go`, `internal/git/state_file.go`, `cmd/av/diff.go`, `cmd/av/tree.go`, `cmd/av/sync.go`, `cmd/av/pr_status.go`, `docs/av-git-interaction.7.md`, `CLAUDE.md`, `README.md`
- [av repository][av-repo] (pinned to the surveyed revision)
- [Aviator CLI documentation][av-docs]
- [Rethinking code reviews with stacked PRs][av-blog] (Aviator blog, linked from `README.md`)

<!-- References -->

[av-repo]: https://github.com/aviator-co/av/tree/6473453679a3139630f9a454e6f9b87a07ceab10
[av-docs]: https://docs.aviator.co/aviator-cli
[av-blog]: https://www.aviator.co/blog/rethinking-code-reviews-with-stacked-prs/
