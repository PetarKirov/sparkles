# Git `cache-tree` & the index stat-cache

How a Merkle tree is maintained **incrementally** — the mechanism the rest of
this survey assumes exists and never shows, plus the cautionary tale attached
to every staleness heuristic.

|                    |                                                                               |
| ------------------ | ----------------------------------------------------------------------------- |
| **Ecosystem**      | Git                                                                           |
| **What it is**     | an index extension caching known-good subtree OIDs, invalidated by path       |
| **Companion**      | the index's per-entry `stat` data, and the **racy-git** problem               |
| **Specification**  | [`gitformat-index.adoc` § Cache tree][fmt-index]                              |
| **Implementation** | [`cache-tree.c`][cache-tree], [`Documentation/technical/racy-git.adoc`][racy] |

## Overview

### What it solves

[Git's Merkle DAG][git] makes an incremental rehash _possible_; `cache-tree`
makes it _happen_. The index lists files, not directories, so without a cache
every commit would rebuild every tree object. The extension records, per
directory, the OID of the tree that already matches that span of the index
([`gitformat-index.adoc`][fmt-index]):

> The cache tree extension stores a recursive tree structure that describes the
> trees that already exist and completely match sections of the cache entries.
> This speeds up tree object generation from the index for a new commit by only
> computing the trees that are "new" to that commit. It also assists when
> comparing the index to another tree, such as `HEAD^{tree}`, since sections of
> the index can be skipped when a tree comparison demonstrates equality.

### Design philosophy

Invalidation is by **path, upward** — the minimal correct rule for a Merkle
tree, and exactly what our own subtree-cache proposal needs:

> When a path is updated in index, Git invalidates all nodes of the recursive
> cache tree corresponding to the parent directories of that path. We store
> these tree nodes as being "invalid" by using "-1" as the number of cache
> entries. Invalid nodes still store a span of index entries, allowing Git to
> focus its efforts when reconstructing a full cache tree.

The sentinel is visible in the source: `cache_tree()` initializes
`it->entry_count = -1` ([`cache-tree.c`][cache-tree]). Note the second half —
an invalidated node **keeps its span**, so recovery is bounded to that
subdirectory rather than restarting from the root. A cache that forgets where
the hole was has to re-derive it.

## How it works

The `TREE` extension is a flat encoding of the recursive structure: per entry,
a NUL-terminated path component relative to its parent, the ASCII decimal
`entry_count` (or `-1` for invalid), a space, the subtree count, and — when
valid — the object ID.

Three properties are worth copying wholesale:

1. **The cache is an optimization, never an authority.** A missing or invalid
   node costs work, never correctness.
2. **Invalidation is path-directed and upward-closed**, which is the smallest
   rule that keeps a Merkle tree honest.
3. **Invalid nodes retain their extent**, bounding the repair.

## The staleness half: racy-git

The cache above answers "which subtree digests are still good". A separate
mechanism answers "which _files_ changed", and it is where the famous bug
lives. Git's index stores `stat` data per entry and treats an entry as clean
when that data matches — but filesystem timestamps have limited granularity, so
a file modified within the same timestamp tick as the index write looks clean
while being dirty. [`racy-git.adoc`][racy] names these entries **"racily
clean"** and describes the mitigation: entries whose cached mtime is not
strictly older than the index's own are re-checked against the filesystem
content rather than trusted.

The generalizable rule — and the one our design states as an axiom — is that a
staleness heuristic may produce a **false "changed"** (costing work) but must
never produce a **false "unchanged"** (costing correctness). Git's answer is to
detect the ambiguous window and downgrade to a content comparison inside it.
Any mtime-based cache that does not do something equivalent has this bug; it is
simply rarer on filesystems with finer timestamps.

## Dimensions

This subject sits below the six-dimension spine — it is a _mechanism_, not a
scheme — but two dimensions still apply:

- **Level-1 composition**: it exists _only_ because git's level 1 is a Merkle
  DAG. There is no `cache-tree` analogue for a serial scheme like [NAR][nar],
  because there are no subtree digests to cache.
- **Partial verification**: the same subtree-naming property that allows
  fragment verification allows fragment _caching_. They are the same property
  read in two directions.

## Strengths

- Minimal, correct invalidation rule, in production for two decades.
- Cache is advisory: corruption costs time, not correctness.
- Invalid nodes keep their span, bounding repair.
- The racy-git treatment is a worked, documented answer to a subtle problem
  most caches get wrong silently.

## Weaknesses

- Applies only to the index's view; it does not help a walk of an arbitrary
  directory.
- The flat encoding is compact but fiddly to parse.
- Correctness of the staleness half depends on filesystem timestamp
  granularity, which varies by platform.

## Key design decisions and trade-offs

| Decision                                          | Rationale                                                    | Trade-off                                                      |
| ------------------------------------------------- | ------------------------------------------------------------ | -------------------------------------------------------------- |
| Cache subtree OIDs in the index, not a side store | The index is already read and written every operation        | Tied to the index's lifecycle; useless outside it              |
| Invalidate parent directories of a changed path   | Smallest rule that keeps a Merkle tree honest                | Touching one deep file invalidates the whole spine to the root |
| `-1` sentinel, span retained                      | Repair stays bounded to the affected subtree                 | A magic value in a binary format                               |
| Treat same-tick entries as "racily clean"         | A timestamp comparison alone can produce a false "unchanged" | Extra content comparisons in a narrow window                   |

## Sources

- [`Documentation/gitformat-index.adoc`][fmt-index] — the `TREE` extension and the invalidation rule
- [`cache-tree.c`][cache-tree] — `entry_count = -1`, invalidation, tree construction
- [`Documentation/technical/racy-git.adoc`][racy] — "racily clean" entries

<!-- References -->

[git]: ./git-objects.md
[nar]: ./nar.md
[fmt-index]: https://github.com/git/git/blob/f78ce2f7b6df702f93d40b85d6bda92a3f65da79/Documentation/gitformat-index.adoc
[cache-tree]: https://github.com/git/git/blob/f78ce2f7b6df702f93d40b85d6bda92a3f65da79/cache-tree.c
[racy]: https://github.com/git/git/blob/f78ce2f7b6df702f93d40b85d6bda92a3f65da79/Documentation/technical/racy-git.adoc
