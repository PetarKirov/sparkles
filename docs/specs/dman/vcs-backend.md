# `sparkles:dman` — VCS Backend (per-repo)

_The per-repository layer: the branch / worktree / status data model and the
`VcsRepo` backend that produces it. Git-first, kept jj-shaped ([D8](./DECISIONS.md)).
Discovery and cataloging of repos is a separate concern — see
[Repo catalog](./repo-catalog.md); how a git command is actually invoked is the
[Command schema](./command-schema.md)._

## Data model

All types are plain structs (`wired`-decodable, `Expected`-returning at the edges):

```d
// 5-way, mutually exclusive, priority-ordered (current > protected > gone >
// merged > unmerged), matching the prior-art classification.
enum BranchStatus { current, protected_, goneUpstream, safeMerged, unmerged }
// safe-to-delete = goneUpstream | safeMerged ;  deletable = !(current | protected_)

struct BranchInfo {
    string            name;
    Nullable!string   upstream;
    Nullable!int      ahead, behind;         // vs upstream
    BranchStatus      status;
    bool              stale;                  // orthogonal age flag, NOT a 6th status
    string            tipSha, tipAuthor, tipSubject;
    SysTime           tipTime;                // last activity (a sort key)
    SysTime           createdTime;            // first commit trunk..branch
    string            createdAuthor;
    Nullable!WorktreeRef worktree;            // checked-out-here / elsewhere
    Nullable!PrInfo   pr;                     // optional gh enrichment
}

struct WorktreeInfo {
    string          path;
    Nullable!string branch;                   // null when detached
    string          headSha;
    bool            bare, detached, locked, prunable;
}
struct WorktreeRef { string path; bool isCurrent; }   // branch → worktree link

struct RepoStatus {
    string root, currentBranch;
    bool   detached, clean;
    int    staged, unstaged, untracked;
}

enum   PrState { open, merged, closed }
struct PrInfo  { uint number; PrState state; string title, url; }
```

Two refinements over the prior art: **staleness is an orthogonal flag**
(a branch can be `unmerged` _and_ stale — a mutually-exclusive "stale" bucket
would lose that), with a configurable age threshold; and **branch↔worktree
association is first-class**, so a branch checked out in another worktree is
shown correctly instead of misclassified.

## Branch classification

Priority order (first match wins):

1. **current** — the branch checked out in _this_ worktree.
2. **protected\_** — the trunk, or a configured protected name
   (default set: `main`, `master`, `develop`, `development`).
3. **goneUpstream** — upstream tracked but deleted (`[gone]`).
4. **safeMerged** — reachable from the trunk (`git branch --merged <trunk>`).
5. **unmerged** — everything else.

**Trunk detection** ladder: explicit config → `symbolic-ref --short
refs/remotes/origin/HEAD` (strip `origin/`) → first existing of `main` / `master`
→ `main`. **Staleness** is computed separately from `tipTime` against a
configurable threshold and never changes the `status`.

## The `VcsRepo` backend

A minimal, Git-first interface ([D8](./DECISIONS.md)) — every operation is a
command schema rendered → spawned via `event-horizon` `proc` → decoded, per
[D4/D5](./DECISIONS.md); nothing hand-parses at the call site:

```d
interface VcsRepo {
    Expected!(string,         VcsError) root(), defaultBranch();
    Expected!(RepoStatus,     VcsError) status();
    Expected!(BranchInfo[],   VcsError) branches();
    Expected!(WorktreeInfo[], VcsError) worktrees();
    Expected!(void,           VcsError) deleteBranch(string name, bool force);
    Expected!(WorktreeInfo,   VcsError) addWorktree(string path, string branch, bool create);
    Expected!(void,           VcsError) removeWorktree(string path, bool force);
    Expected!(void,           VcsError) pruneWorktrees();
}
```

Git emits no JSON, so reads use stable plumbing formats parsed by a small
`base.text` porcelain parser — the `%x1f` / `%x1e` field/record-separator trick
already proven in `release/git.d` — rather than `wired`. (`gh`, which _does_ emit
`--json`, decodes through `wired`.) The git commands behind each datum:

| Datum                          | git command                                                                                    |
| ------------------------------ | ---------------------------------------------------------------------------------------------- |
| branch list + upstream + track | `for-each-ref --format='%(refname:short)%1f%(upstream:short)%1f%(upstream:track)' refs/heads/` |
| merged-into-trunk set          | `branch --merged <trunk> --format='%(refname:short)'`                                          |
| ahead / behind                 | `rev-list --left-right --count <branch>...<upstream>`                                          |
| tip meta                       | `log -1 --format='%h%x1f%an%x1f%cI%x1f%s' <branch>` (`%cI` = strict ISO-8601 → `SysTime`)      |
| creation time + author         | `log --reverse --format='%cI%x1f%an' <trunk>..<branch>` (first record)                         |
| trunk                          | `symbolic-ref --short refs/remotes/origin/HEAD` (+ fallbacks)                                  |
| status                         | `status --porcelain=v2 --branch`                                                               |
| worktrees                      | `worktree list --porcelain`                                                                    |
| delete                         | `branch -d` / `branch -D`                                                                      |
| remote slug                    | `remote get-url origin` (→ `owner/repo`)                                                       |

Each `VcsRepo` method returns `Expected` and never throws (git failures become a
`VcsError` carrying stderr). Because the spawner is a capability, the whole
backend is testable with a `FakeSpawner` returning canned output keyed by argv —
see [Command schema](./command-schema.md#testability--passthrough).

## Worktree model (net-new)

The prior art has no worktree support, so dman designs it from scratch, built on
`git worktree list --porcelain` (path / HEAD / branch / bare / detached / locked
/ prunable per entry). This drives the branch↔worktree link and a
"checked out elsewhere" state that the naive single-`current` model gets wrong.

**On-disk layout** ([D9](./DECISIONS.md)): sibling directories named
`<repo>-<branch>` next to the main checkout by default (matching the existing
sparkles worktree convention, e.g. `sparkles-dman`), configurable via a naming
template; the repo scanner discovers them as ordinary repos. Operations:
`addWorktree` (optionally creating the branch), `removeWorktree`,
`pruneWorktrees`, and enter/exit (a shell in the worktree).

## PR enrichment (optional)

`gh pr list --head <branch> --state all --limit 1 --json number,state,title,url`
→ decoded via `wired` into `PrInfo`. It is an opt-in column; its cache lives with
the catalog persistence — see
[Repo catalog § persistence](./repo-catalog.md#persistence).
