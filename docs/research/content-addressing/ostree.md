# OSTree

Git's object model rebuilt for whole operating systems — which is to say, for
the one case where uid, gid, mode and extended attributes _must_ survive the
hash, and timestamps still must not.

|                    |                                                                      |
| ------------------ | -------------------------------------------------------------------- |
| **Ecosystem**      | Linux OS images (Fedora Silverblue, Flatpak, RHEL CoreOS)            |
| **Level 1**        | Merkle DAG — `dirtree` objects, with metadata split into `dirmeta`   |
| **Level 2**        | whole blob, with a header of its own                                 |
| **Node model**     | regular + uid/gid/mode/xattrs, directory, symlink; **no timestamps** |
| **Entry ordering** | byte-wise (`strcmp`), **within two separate arrays**                 |
| **Digest**         | SHA-256                                                              |
| **Serialization**  | GVariant                                                             |
| **Documentation**  | [`docs/repo.md`][repo-md]                                            |

## Overview

### What it solves

Versioning and atomically deploying complete filesystem trees, where "complete"
includes the ownership and permission bits an OS actually needs at boot. Its
own framing ([`docs/repo.md`][repo-md]):

> OSTree is deeply inspired by git; the core layer is a userspace
> content-addressed versioning filesystem. […] Its object types are similar to
> git; it has commit objects and content objects. Git has "tree" objects,
> whereas OSTree splits them into "dirtree" and "dirmeta" objects. But unlike
> git, OSTree's checksums are SHA256. And most crucially, its content objects
> include uid, gid, and extended attributes (but still no timestamps).

That sentence is the whole subject in miniature: same shape as [git][git],
three deliberate divergences.

### Design philosophy

Metadata that belongs to a _directory_ is factored out of the directory
listing, because it repeats:

> In git, tree objects contain the metadata such as permissions for their
> children. But OSTree splits this into a separate object to avoid duplicating
> extended attribute listings.

And timestamps are excluded with an argument that goes further than
[Nix's][nar] — not merely "they vary between machines", but a positive
requirement of the deployment model:

> The OSTree data format intentionally does not contain timestamps. […] These
> files may be large, so most users would like them to be shared, both in the
> repository and between the repository and deployments. This could cause
> problems with programs that check if files are out-of-date by comparing
> timestamps. […] OSTree has to hardlink files to check them out, and commits
> are assumed to be internally consistent with no build steps needed. For this
> reason, OSTree acts as though all timestamps are set to `time_t` 0.

The postscript is a good cautionary tale about changing a canonical constant:
OSTree briefly used `1` instead of `0` to silence GNU tar's "implausibly old
time stamp" warning, and reverted, because there was no clean transition
mechanism.

## How it works

Objects are GVariant values, with the format strings declared in
[`ostree-core.h`][core-h] and documented inline:

```c
/* - a(say)   - array of (filename, checksum) for files
   - a(sayay) - array of (dirname, tree_checksum, meta_checksum) for directories */
#define OSTREE_TREE_GVARIANT_STRING "(a(say)a(sayay))"

/* - u - uid (big-endian)
   - u - gid (big-endian)
   - u - mode (big-endian)
   - a(ayay) - xattrs */
#define OSTREE_DIRMETA_GVARIANT_STRING "(uuua(ayay))"
```

A directory is therefore named by a **pair** of checksums — its `dirtree` and
its `dirmeta` — which is why a subdirectory entry carries two digests where
git's carries one.

### Dimension 1 — node model

The richest in this survey. A content object "has a separate internal header
and payload sections. The header contains uid, gid, mode, and symbolic link
target (for symlinks), as well as extended attributes. After the header, for
regular files, the content follows. **These parts together form the SHA256 hash
for content objects.**" So ownership and xattrs are inside the identity, not
beside it — the opposite of [REAPI's][reapi] optional node properties.

One consequence the docs flag honestly: in `archive` repositories the stored
`.filez` files are gzipped while the hash is over the _uncompressed_ header +
content, so "these files do not match the hash they are named as."

### Dimension 2 — canonical form and ordering

Byte-wise, by `strcmp`, applied **separately to each of the two arrays**
(`create_tree_variant_from_hashes` in [`ostree-repo-commit.c`][commit-c], whose
comment reads "The input hashes will be sorted"). Because files and
directories live in different arrays, the question [git][git] answers with an
implicit `/` simply does not arise — there is never a file and a directory to
order against each other. This is the cheapest of the four orderings in the
survey and the only one that is _structurally_ free of the file-versus-directory
comparison.

### Dimension 3 — level-1 composition

A Merkle DAG like git's, with one extra edge per directory (to `dirmeta`) and
one extra indirection to pay for. Subtree sharing, incremental rehash and
parallel hashing all work exactly as in git.

### Dimension 4 — level-2 content addressing

Whole blob, but with a header inside the hashed bytes — so unlike [git][git],
identical file _contents_ under different ownership are different objects. That
is a deliberate trade: correctness of a deployed OS over maximal dedup.

### Dimension 5 — digest

SHA-256 throughout, rendered as lowercase hex in object filenames, with objects
sharded by the first two characters as in git.

### Dimension 6 — partial verification

At object granularity, as in git. The `dirtree`/`dirmeta` split means directory
_metadata_ can be fetched and verified without the listing, which matters for
the deduplicated-xattr case the split exists for.

## Strengths

- **The only surveyed model that can restore a real OS tree** — uid, gid, mode
  and xattrs are inside the identity.
- **Ordering is structurally simple**: two arrays, plain `strcmp`, no
  file-versus-directory comparison anywhere.
- **Metadata dedup** via the `dirmeta` split, which pays off exactly where
  xattr listings repeat across thousands of directories.
- The timestamp rationale is written down, including the failed attempt to
  change it.

## Weaknesses

- **Two objects per directory** — more lookups, more round trips, more to
  garbage-collect.
- **Ownership inside the file hash** defeats dedup between otherwise identical
  files.
- **GVariant** is a dependency and a decoding surface that git's and NAR's
  hand-rolled framings are not.
- Stored `.filez` objects do not hash to their own names, which every tool
  touching the store must know.

## Key design decisions and trade-offs

| Decision                                    | Rationale                                              | Trade-off                                                                         |
| ------------------------------------------- | ------------------------------------------------------ | --------------------------------------------------------------------------------- |
| Split `dirtree` from `dirmeta`              | Avoid duplicating xattr listings across directories    | Two objects and two digests per directory                                         |
| uid/gid/mode/xattrs inside the content hash | A deployed OS needs them restored exactly              | Identical contents under different ownership no longer share an object            |
| No timestamps; behave as if `time_t` 0      | Hardlinked checkouts must compare as up to date        | Tools that read mtime see a fixed epoch; changing the constant proved impractical |
| SHA-256 from the start                      | Avoid git's SHA-1 migration                            | Larger digests in every object                                                    |
| Two sorted arrays instead of one            | Files and directories never compare against each other | Two arrays to merge when a consumer wants one ordered listing                     |
| GVariant instead of a bespoke framing       | Reuse a typed, versioned serialization                 | An external format dependency inside the identity                                 |

## Sources

- [`docs/repo.md`][repo-md] — object types, the git comparison, the timestamp rationale
- [`src/libostree/ostree-core.h`][core-h] — `OSTREE_TREE_GVARIANT_STRING`, `OSTREE_DIRMETA_GVARIANT_STRING`, `OSTREE_COMMIT_GVARIANT_STRING`
- [`src/libostree/ostree-repo-commit.c`][commit-c] — `create_tree_variant_from_hashes` and its `strcmp` sort

<!-- References -->

[nar]: ./nar.md
[git]: ./git-objects.md
[reapi]: ./reapi.md
[repo-md]: https://github.com/ostreedev/ostree/blob/1d5a312a3189b0fbd70fe6769aadb19a366fedb2/docs/repo.md
[core-h]: https://github.com/ostreedev/ostree/blob/1d5a312a3189b0fbd70fe6769aadb19a366fedb2/src/libostree/ostree-core.h
[commit-c]: https://github.com/ostreedev/ostree/blob/1d5a312a3189b0fbd70fe6769aadb19a366fedb2/src/libostree/ostree-repo-commit.c
