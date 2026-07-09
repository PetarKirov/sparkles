# `sparkles:dman` — Repo Catalog (cross-repo)

_The cross-repository layer: discovering repos on disk, cataloging them,
selecting the active one, and persisting it all. Kept **separate** from the
per-repo [VCS backend](./vcs-backend.md) (cross-repo vs per-repo) to avoid a
dependency cycle — scanning and cataloging sit above `VcsRepo`._

## Scan

A marker-based walk from one or more roots, honouring `.gitignore`, exclude
globs, a max depth, and sensible default exclusions, run in parallel on the
`event-horizon` loop. It reuses the existing gitignore-aware repo walker
(`walkGitRepository` from the TUI-widgets tree). The marker set is **`.git` _and_
`.jj/`** ([D8](./DECISIONS.md), [Designing for jj](./jj-model.md)): a colocated
repo (both present) is deduped to **one** jj-authoritative `RepoRef`, and a
non-colocated jj repo (`.jj/` only, its git store hidden at `.jj/repo/store/git`)
would be missed by a `.git`-only scan. `.jj/repo` is a directory in a primary
workspace but a file pointer in secondary workspaces (linked back to the
primary); the walker never descends into `.jj/`. Worktrees under the default
`<repo>-<branch>` layout are discovered as ordinary repos and linked to their
main checkout (by shared git-dir, or by the shared `.jj/repo` store for jj
workspaces).

## Catalog & registry

```d
enum VcsKind { git, jj }

struct RepoRef {
    string          path;              // canonical absolute path
    string          name;             // display name
    VcsKind         backend;          // git | jj  (per-repo, from the marker)
    bool            colocated;        // .jj/ beside .git/
    string[]        remotes;          // remote URLs (order-independent identity)
    string[]        tags;             // tags[0] = directory group; tags[1..] = user labels
    SysTime         lastScanned;
}
```

- **Catalog** — the persisted set of known `RepoRef`s. The filesystem stays
  authoritative; the catalog is a **rebuildable secondary index** (a lost or
  stale catalog self-heals on the next scan).
- **Registry** — the in-memory working set, live-updated by `watch` (a new scan
  or an on-disk change refreshes it without a manual reload).
- **Tags** — many-to-many grouping (`--tag <t>` filters the catalog). `tags[0]`
  is the auto-detected directory group; `tags[1..]` are free-form labels — see
  [Workspaces](./workspaces.md). (Not to be confused with a jj _workspace_, which
  is a checkout.)

The `remotes` set (order-independent) is the repo's portable identity — the same
notion the later cross-machine sync builds on.

## Selection

Resolving the _active_ repo:

- **CWD walk-up** — from the current directory, ascend to the enclosing repo
  root (the no-argument default).
- **`--repo PATH|URL`** — an explicit path (canonicalised) or a remote URL
  resolved to a catalog entry by `remotes`.

Failures produce structured, actionable errors and a non-interactive exit code
(so scripts and CI get a clean signal).

## Persistence

Persistence is a **bundled SQLite database** ([D7](./DECISIONS.md)) — `dman.db` in
`core-cli`'s `dataDir` (WAL, `foreign_keys=ON`) — holding the catalog and the PR
cache; `stateDir` keeps TUI/session state. The filesystem stays authoritative for
whether a repo exists; the DB is a rebuildable index that self-heals on the next
scan.

```
repositories(id, path UNIQUE, name, remotes, last_scanned)
cached_prs(id, repo_id → repositories, branch, pr_number?, state, title, url,
           cached_at, UNIQUE(repo_id, branch))
schema_migrations(version, applied_at)
```

**PR cache.** Keyed by `(repo_id, branch)`. A row with a null `pr_number` is the
"queried, no PR" sentinel (distinct from a cache miss), so a known-absent PR is
not re-fetched; a TTL bounds staleness on read, an eviction pass drops old rows,
and deleting a branch invalidates its row. Concurrency-safe under WAL — the one
place a shared/distributed cache later plugs in.

**Dependency.** SQLite is new to sparkles; the idiomatic route is an ImportC
binding to the bundled amalgamation (the `sparkles:ghostty` pattern), or an
existing D binding.

## CLI surface

```
dman repo scan     [--root DIR]... [--depth N] [--exclude GLOB]...
dman repo list     [--workspace NAME]
dman repo add PATH
dman repo remove PATH|NAME
dman repo show     [PATH|NAME]
```

All are non-interactive and scriptable; the interactive TUI drives the same
catalog + registry (see [Architecture § TUI shell](./architecture.md#the-tui-shell--the-biggest-net-new-piece)).
