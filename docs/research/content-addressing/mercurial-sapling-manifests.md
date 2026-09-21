# Mercurial manifests → Sapling tree manifests

The only **flat, whole-tree** answer to level 1 in this survey — and the
documented story of why it had to become a tree.

|                    |                                                                                               |
| ------------------ | --------------------------------------------------------------------------------------------- |
| **Ecosystem**      | Mercurial; Sapling (Meta's fork)                                                              |
| **Level 1**        | flat: one sorted text listing of **every path in the repository**; later, per-directory trees |
| **Level 2**        | per-file revlog identity                                                                      |
| **Node model**     | path + file revision id + one flag: `x` executable, `l` symlink (later `t` = tree)            |
| **Entry ordering** | sorted rows of a text file                                                                    |
| **Digest**         | `Sha1(min(p1, p2) + max(p1, p2) + content)` — **includes the parents**                        |
| **Documentation**  | [`201910-manifests-past-and-future.md`][note] (Sapling)                                       |

## Overview

### What it solves

Answering "what files exist at this commit" without walking history. Sapling's
own retrospective defines it ([`201910-manifests-past-and-future.md`][note]):

> The Manifest is the list of files in the repository at a given commit. […]
> Manifests can be seen as indexes, precomputed data, or derived data.

### Design philosophy

The flat manifest is deliberately the simplest thing that works — "a big string
that is associated with a commit identifier" — with an ABNF given in the note:

```abnf
Manifest   = *( Row LF )
Row        = FilePath %x00 HgId [ Flag ]
Flag       = %s"x" / %s"l"
FilePath   = 1*( %x01-%x09 / %x0B-%xFF )
HgId       = 40HEXDIG
```

so a manifest looks like:

```text
analytics/abtest.pig 06763db6de79098e8cdf14726ca506fdf16749bex
assets/banner.jpg 5ac863e17c7035f1d11828d848fb2ca450d89794
index.php 78f7c038716f258f451528e1e8241d895419f2ee
```

Two things are unusual against everything else in this survey.

**There is no directory structure at all.** Paths are full paths; `analytics/`
is not an object. So the manifest is a _flat_ level 1 — closer to a sorted
listing than to a tree — and the whole listing is one revlog entry.

**The identity is not a pure content address.** The note gives it as:

```text
manifest_id = Sha1(min(p1, p2) + max(p1, p2) + content)
```

where `p1`/`p2` are the parent manifest ids. Two commits with byte-identical
file listings and different histories therefore have **different manifest
ids** — the opposite of [git's][git] property that identical trees share an
object. This is the survey's only history-dependent identity, and it is worth
naming precisely because it looks like content addressing and is not.

## The transition, and why

Flat manifests are stored as revlog deltas, which makes them compact; what they
are not is _scalable to read_. The note is blunt about the reason:

> Even if Revlog can have indexes on the index file, the Manifest itself is not
> efficient. Parsing the contents of a flat Manifest is going to be expensive.
> For large code bases, we can assume that commits will touch a relatively
> small number of files so we would like a data structure that scales with
> **O(|changed files|)** rather than **O(|repo files|)**.

and states the resulting bound:

> Modeling the Manifest as a Tree will reduce scaling of the operations to
> O(|changed files| _ |directory size| _ |directory depth|). Assuming that
> `directory size` and `directory depth` are capped, the operations are going
> to be O(|changed files|).

That is the clearest available statement of _why_ every other level-1 scheme in
this survey is per-directory. [Git][git], [OSTree][ostree] and [REAPI][reapi]
all start there; Mercurial is the one that started elsewhere and had to move,
which makes its retrospective the evidence rather than the assumption.

The migration is also instructive about compatibility: the tree format was
bootstrapped _from_ the flat one — "A Flat Manifest that has one level can be
seen as a Tree Manifest node" — by adding a third flag, `t`, marking a row as a
subdirectory rather than a file. The node model grew by one character.

The note is candid about the storage consequence, too: because Mercurial gives
each path its own revlog, tree manifests meant a revlog per directory node —
"Personally, I don't like the idea having O(|files|) revlog entries. I find
this solution unfortunate."

## Dimensions

- **Node model** — the leanest in the survey: path, revision id, one flag. No
  mode bits beyond executable, no ownership, no timestamps.
- **Ordering** — sorted rows; with full paths in a flat manifest, the
  file-versus-directory ordering question [git][git] answers with an implicit
  `/` cannot arise, because directories do not appear. It returns with tree
  manifests.
- **Level 1** — flat listing, then per-directory tree. The only subject to have
  shipped both.
- **Level 2** — per-file revlog, delta-compressed; identity is a revision id,
  itself parent-dependent.
- **Digest** — SHA-1 over parents plus content: **history-dependent**.
- **Partial verification** — none for a flat manifest (it is one blob); per
  node once trees arrive.

## Strengths

- Extremely simple format, trivially inspectable as text.
- Delta storage makes flat manifests compact across adjacent commits.
- The tree migration preserved the format's shape by adding one flag.
- The scaling rationale is written down by the people who lived it.

## Weaknesses

- **`O(|repo files|)` to parse** — the failure that forced the migration.
- **History-dependent identity**: identical trees do not share a manifest id,
  so the dedup every Merkle scheme relies on is unavailable.
- A revlog per directory node once trees land — `O(|files|)` storage entries,
  which the note itself criticizes.
- Sorted text with NUL separators is a parsing surface with edge cases.

## Key design decisions and trade-offs

| Decision                                         | Rationale                                                       | Trade-off                                                    |
| ------------------------------------------------ | --------------------------------------------------------------- | ------------------------------------------------------------ | ---------- | ----------------------------------------- |
| Flat, whole-repository listing                   | Simplest possible manifest; excellent delta compression         | `O(                                                          | repo files | )` parse cost; forced a redesign at scale |
| Identity includes parent ids                     | Fits Mercurial's revlog/DAG model, where everything has parents | Identical trees get different ids — no cross-history dedup   |
| One flag character for the node model            | Minimal format; easy to extend                                  | Executable and symlink only; everything else is out of scope |
| Bootstrap trees from the flat format, adding `t` | Reuses the parser and storage machinery                         | Inherits revlog-per-path storage, i.e. `O(                   | files      | )` entries                                |
| Text, not binary                                 | Debuggable, greppable                                           | Parsing cost is exactly the thing that did not scale         |

## Sources

- [`eden/scm/newdoc/notes/201910-manifests-past-and-future.md`][note] — the ABNF, the manifest-id formula, the `O(|changed files|)` argument, the `t` flag
- [`eden/scm/lib/manifest-tree`][mtree] and [`manifest-augmented-tree`][maug] — the Rust implementations

<!-- References -->

[git]: ./git-objects.md
[ostree]: ./ostree.md
[reapi]: ./reapi.md
[note]: https://github.com/facebook/sapling/blob/87b7db94b0a7fc5186b472f0ee8d01fd5a2036a2/eden/scm/newdoc/notes/201910-manifests-past-and-future.md
[mtree]: https://github.com/facebook/sapling/tree/87b7db94b0a7fc5186b472f0ee8d01fd5a2036a2/eden/scm/lib/manifest-tree
[maug]: https://github.com/facebook/sapling/tree/87b7db94b0a7fc5186b472f0ee8d01fd5a2036a2/eden/scm/lib/manifest-augmented-tree
