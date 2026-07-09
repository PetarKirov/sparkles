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

A **capability-based** interface ([D8](./DECISIONS.md); Design-by-Introspection),
with **Git as v1's sole implementation** and jj added at P3 — a common core both
backends fill, plus capability-gated optional operations (see
[Designing for jj](#designing-for-jj-the-p3-backend)). Every operation is a
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

## Worktree workflow ([D13](./DECISIONS.md))

Composable, worktree-native primitives (no agent machinery):

- **`enter` / `exec`** — `enter` changes into a worktree's directory and records
  its context; `exec` runs a command in that context non-interactively and returns
  the child's exit code. Each is a reusable primitive that scripts and automation
  compose rather than reimplement.
- **Branch-per-task naming** — a deterministic template maps a unit of work to a
  branch and its worktree (the [D9](./DECISIONS.md) layout), giving a predictable
  work → branch → worktree mapping.
- **Working-copy mode** — a 2-mode taxonomy on each worktree record: `inPlace`
  (work in the user's own checkout — isolation off, mutation explicit) vs
  `isolatedWorktree` (the default sibling worktree). An `overlay` mode is reserved
  for the deferred snapshot subsystem ([D12](./DECISIONS.md)).
- **File-based context descriptor** — the branch/worktree context is published as
  a small on-disk descriptor and resolved by a precedence chain (explicit flag →
  descriptor file → auto-detect), robust where environment variables don't
  propagate through nested / child processes.

Three cross-cutting **host helpers** belong in the shared layer (reused by the PR
column, opening forge pages, and tool detection): a remote-URL → `owner/repo` slug
parser (HTTPS + SSH forms, directory-basename fallback), an "open URL in the
browser" helper, and an "is external tool on PATH" probe.

## PR enrichment (optional)

`gh pr list --head <branch> --state all --limit 1 --json number,state,title,url`
→ decoded via `wired` into `PrInfo`. It is an opt-in column; its cache lives with
the catalog persistence — see
[Repo catalog § persistence](./repo-catalog.md#persistence).

## Designing for jj (the P3 backend)

jj (P3) diverges from git deeply enough that the interface above is
**capability-based** rather than git-shaped. The full analysis is in
[Designing for Jujutsu](./jj-model.md); the shape it imposes here:

- **Output decode is backend-pluggable.** git reads parse porcelain
  (`--porcelain=v2` / `for-each-ref --format`, the `%x1f`/`%x1e` parser); jj has
  no porcelain, so its reads render a **template** (`jj … -T 'json(self)'
--no-graph`) decoded through `wired` — the same `run!T` machinery, a different
  collector. Both backends stay schema-driven command invocations.
- **The data model widens** (each field git-only ⇒ capability-gated):
  - `BranchInfo` → a **ref/bookmark** that may be **unnamed** (an anonymous head /
    the working-copy change) and may resolve to **0..N targets** (`conflicted`);
    `tipSha` becomes an opaque `commitId` with an optional stable `changeId`;
    `upstream`/`ahead`/`behind` widen to a **per-remote tracked set** with
    **bound-valued** (not scalar) ahead/behind.
  - `RepoStatus` → `currentBranch` becomes nullable (jj has no current branch —
    expose a separate **working revision**); `staged`/`unstaged`/`untracked`
    become capability-gated (jj has no index); add `conflicted` and `stale`.
  - `WorktreeInfo` → add a workspace **`name`** and a **`stale`** flag; `branch`
    becomes truly optional (a workspace checks out a commit); `bare`/`detached`/
    `locked`/`prunable` become git-only.
  - `BranchStatus` classification becomes **backend-provided** (jj computes
    "merged" as the `::trunk()` revset, "gone" via tracking state) and gains
    jj-only buckets (anonymous head, divergent).
- **Capability-gated operation groups** (present on jj, absent on git): the
  **operation log + undo** (`jj op log` / `jj undo` → a real "undo the branch
  delete" dman cannot offer on git), **first-class conflict** handling (a
  three-way merge/rebase outcome + `jj resolve`), **workspace stale** repair, and
  **track/untrack** + delete-vs-forget bookmark semantics.
- **Worktree ops map to `jj workspace`** (not `git worktree`): `forget` keeps
  files (dman deletes), there is no `remove`/`prune` (dman reconciles), and reads
  pass `--ignore-working-copy` to avoid jj's snapshot-on-read side effect.

v1 implements only the git capabilities; the interface is shaped so the jj
backend slots in at P3 without reworking callers.
