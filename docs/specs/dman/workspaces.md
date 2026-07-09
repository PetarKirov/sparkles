# `sparkles:dman` — Workspaces (multi-repo grouping)

_How dman groups repositories. Grouping is **many-to-many tags** on each repo;
`tags[0]` is a reserved, auto-detected **directory group**, and the rest are
free-form labels. A mid-phase feature layered on the single-repo VCS core
([D11](./DECISIONS.md)). See [Repo catalog](./repo-catalog.md) for the underlying
catalog and selection._

## Tags model

Each cataloged repo carries a `string[] tags` (in `RepoRef`) — a repo can belong
to several workspaces at once:

```d
struct RepoRef {
    // …path, name, backend, colocated, remotes, lastScanned…
    string[] tags;      // tags[0] = the directory group; tags[1..] = user labels
}
```

- **`tags[0]` — the primary directory group.** The parent-of-repo-roots directory
  the repo sits under, resolved by auto-detection (below), with **single-repo
  collapse**: a lone repo's `tags[0]` is the repo itself — no parent is invented.
- **`tags[1..]` — free-form user labels.** Arbitrary cross-cutting groupings
  (`work`, `oss`, `frontend`, …), managed explicitly and independent of on-disk
  layout.

Catalog queries filter by any tag (`dman repo list --tag <t>`), so the same repo
appears under each workspace it is tagged with.

## Directory-group auto-detection (populates `tags[0]`)

Walking up from the current directory, **first match wins**:

1. an explicit group-marker file/dir on an ancestor (strongest signal);
2. an existing dman group-state directory on an ancestor (dman has run here);
3. **heuristic** — the top-most ancestor that _directly_ contains a repo-root
   child, bounded by a stop directory (default `$HOME`) so it can't over-reach;
4. single-repo fallback (a lone repo is its own group);
5. plain CWD-repo fallback; a structured error if no repo is found at all.

## Declarative config (optional)

A file at the group root overrides auto-detection: the directory-group name, a
membership allowlist (missing/non-repo entries warn, they don't fail), an optional
server/endpoint pin, and any default `tags` to apply to member repos.

## Group identity

A directory group's stable, machine-independent ID is the **order-independent
hash of its members' canonical remote URLs** (the repos sharing a `tags[0]`) —
reusing dman's existing remote-URL identity ([Repo catalog](./repo-catalog.md)),
so two machines with the same repos compute the same group ID. This is the unit
the later distributed phase's portable layout descriptor and remote reproduction
operate on.

## CLI

```
dman workspace list | show | create | members | delete [--clean]
dman repo tag add|remove <tag> [--repo …]      # manage tags[1..]
dman repo list --tag <t>                        # filter the catalog by any tag
```

- `--tag`/`--group <name>` overrides CWD auto-detection (for scripts/CI); a
  single-repo-only command rejects it with a clear message.
- `delete` removes tracking but leaves files; `--clean` also removes markers/state.
- Config toggles can disable group auto-detection and auto-registration.

## Scoping & resolution

Resolution is **two-layer**: detect the directory group (establishing the in-scope
repo set), then run single-repo [selection](./repo-catalog.md#selection) within
that scope. State is classified as group-scoped (shared across a group's repos) or
repo-scoped, governing where it lives in the catalog.
