# Git objects (blob / tree)

The Merkle DAG every other system in this survey is measured against — and the
one whose entry ordering is not what it appears to be.

|                    |                                                                                                  |
| ------------------ | ------------------------------------------------------------------------------------------------ |
| **Ecosystem**      | Git                                                                                              |
| **Level 1**        | Merkle DAG — every directory is a named, independently addressable object                        |
| **Level 2**        | whole blob                                                                                       |
| **Node model**     | five modes: regular, executable, symlink, tree, gitlink                                          |
| **Entry ordering** | byte-wise, **with a `/` implicitly appended to directory names**                                 |
| **Digest**         | SHA-1, or SHA-256 in a SHA-256 repository                                                        |
| **Specification**  | [`gitformat-loose.adoc`][loose] (object framing); the tree body is defined by the implementation |
| **Implementation** | [`tree.c`][tree-c] (ordering), [`fsck.c`][fsck-c] (canonical-form checks)                        |

## Overview

### What it solves

Versioning a tree such that an unchanged subtree costs nothing to re-record.
Because every directory is its own object named by its content, a commit that
touches one file shares every untouched subtree object with its parent — the
property [OSTree][ostree] adopted wholesale, [REAPI][reapi] rebuilt over
protobuf, and [NAR][nar] deliberately declined.

### Design philosophy

Object identity is defined over _uncompressed_ bytes with a type-and-length
prefix, so the framing is self-describing and storage is free to change
underneath it ([`gitformat-loose.adoc`][loose]):

> Each loose object contains a prefix, followed immediately by the data of the
> object. The prefix contains `<type> <size>\0`. […] The object ID of the
> object is the SHA-1 or SHA-256 (as appropriate) hash of the uncompressed
> data.

The documentation's own worked examples: a blob containing `abc` has
uncompressed data `blob 3\0abc`, and the empty tree is `tree 0\0`, which in a
SHA-256 repository is object
`6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321`.

## How it works

A tree object's body is a concatenation of entries, each
`<octal mode> <name>\0<raw digest bytes>` — no separators, no count, no
padding. The mode is the node model:

| Mode     | Node                                                                 |
| -------- | -------------------------------------------------------------------- |
| `100644` | regular file                                                         |
| `100755` | executable file                                                      |
| `120000` | symlink — a blob whose _contents are the target string_              |
| `040000` | tree                                                                 |
| `160000` | gitlink (`S_IFGITLINK`, [`object.h`][object-h]) — a submodule commit |

### Dimension 1 — node model

Richer than [NAR's][nar] by exactly two: a symlink is a first-class mode rather
than a node type, and gitlink has no counterpart anywhere else in this survey.
Crucially, **the mode lives in the parent's entry, not in the object** — a blob
does not know whether it is executable. Nix documents the consequence for its
own git-hashing mode ([`content-address.md`][nix-ca]):

> Plain files, executable files, and symlinks are not differentiated as
> distinctly addressable objects, but by their context: by the directory entry
> that refers to them. […] if the root object is not a directory, then we have
> no way of knowing which one of an executable file, non-executable file, or
> symlink it is supposed to be.

So git's addressing is _partial_ over the FSO model: a bare executable file or
a bare symlink has no representation. Nix resolves it by treating a bare file
as non-executable and erroring on the other two cases.

### Dimension 2 — canonical form and ordering

Entries are sorted by name — but not by the name as written.
[`base_name_compare`][tree-c] compares the common prefix with `memcmp`, then:

```c
c1 = name1[len];
c2 = name2[len];
if (!c1 && S_ISDIR(mode1))
    c1 = '/';
if (!c2 && S_ISDIR(mode2))
    c2 = '/';
return (c1 < c2) ? -1 : (c1 > c2) ? 1 : 0;
```

A directory therefore sorts as though its name carried a trailing `/`. Since
`/` is `0x2F` and `.` is `0x2E`, a file `a.b` sorts **before** a directory `a`,
while a byte-wise sort of the bare names puts `a` first. Reproduced against
real git:

```bash
mkdir a && echo x > a/f && echo y > a.b && git add -A && git cat-file -p $(git write-tree)
# 100644 blob 975fbec8…	a.b
# 040000 tree a1dffc7a…	a
```

This is the single most consequential finding in the survey: **[NAR][nar] order
and git order are different functions of the same name set**, so one
"canonical order" primitive cannot serve both.

It also costs git something concrete. Because the implicit slash can separate
two spellings of the same name, duplicate detection is not an adjacent-pair
check. From [`fsck.c`][fsck-c]:

> There can be non-consecutive duplicates due to the implicitly added slash,
> e.g.:
>
> ```
> foo
> foo.bar
> foo.bar.baz
> foo.bar/
> foo/
> ```
>
> Record non-directory candidates (like "foo" and "foo.bar" in the example) on
> a stack and check directory candidates (like "foo/" and "foo.bar/") against
> that stack.

A stack, where [NAR's][nar] `if (name <= prevName)` suffices. The comment above
it records why the check exists at all: "git-write-tree used to write out a
nonsense tree that has entries with the same name, one blob and one tree."

`fsck` enumerates the rest of canonical form as named error codes —
`TREE_NOT_SORTED`, `DUPLICATE_ENTRIES`, `HAS_DOTDOT`, `HAS_DOTGIT`,
`ZERO_PADDED_FILEMODE`, `BAD_FILEMODE` — which makes git the only subject here
whose canonical-form violations have a stable vocabulary.

Case collisions are simply **permitted**: git will happily record `README` and
`readme` in one tree, and the failure surfaces at checkout on a
case-insensitive filesystem rather than at hashing. That is the third of the
field's three answers, beside [NAR's][nar] name mangling and [REAPI's][reapi]
"legal, but may be rejected on execution".

### Dimension 3 — level-1 composition

A true Merkle DAG, and a _DAG_ rather than a tree: identical subtrees anywhere
in history share one object. A one-file edit rewrites one blob and its ancestor
trees — O(depth) objects — which is the property that makes subtree caching and
incremental rehashing possible.

### Dimension 4 — level-2 content addressing

Whole blob, with the type/length prefix. No chunk tree, no range addressing;
packfile delta compression is a _storage_ optimization beneath the identity,
not part of it.

### Dimension 5 — digest

SHA-1 historically, SHA-256 in a SHA-256 repository, with the choice a
repository-wide property rather than a per-object tag. Digests appear as raw
bytes inside tree entries and as lowercase hex at the interface.

### Dimension 6 — partial verification

At object granularity: holding a tree's digest, a consumer can verify that
tree's bytes and, transitively, any subtree, without possessing sibling
subtrees. Not available _within_ a blob.

## Strengths

- **Subtree identity for free**, and with it dedup, incremental rehash, and
  parallel hashing across files.
- **A named vocabulary of canonical-form violations**, enforced by a tool
  (`git fsck`) users already run.
- **Ubiquitous independent oracle**: `git hash-object` and `git write-tree` are
  on every developer's machine, which makes a reimplementation cheap to test.
- Symlinks and submodules are expressible.

## Weaknesses

- **The implicit-slash ordering** is surprising, undocumented outside the
  source, and forces stack-based duplicate detection.
- **Partial over the FSO model** — a bare executable file or symlink cannot be
  addressed, because the mode lives in the parent.
- **Case collisions are not detected** at hashing time.
- SHA-1's continued presence in most repositories.
- The tree body format is defined by the implementation, not by a specification
  document.

## Key design decisions and trade-offs

| Decision                                          | Rationale                                                      | Trade-off                                                                               |
| ------------------------------------------------- | -------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Merkle DAG over serialization                     | Unchanged subtrees cost nothing to re-record                   | Every directory is an object to store, look up and garbage-collect                      |
| Mode in the parent entry, not the object          | Identical content under different modes shares one blob        | Bare files and symlinks are not addressable; addressing is partial over the FSO model   |
| Sort with an implicit trailing `/` on directories | Keeps a directory and its contents adjacent in traversal order | Diverges from every byte-wise sort; duplicates become non-consecutive                   |
| Type/length prefix over uncompressed bytes        | Identity independent of storage and compression                | Every reimplementation must frame identically before hashing                            |
| Symlink as a blob of its target                   | Reuses the blob object; no new type                            | Target strings are deduplicated against file contents, which is harmless but surprising |
| Canonical form checked by a separate tool         | Writers stay fast; readers stay permissive                     | Malformed trees exist in the wild and are tolerated on read                             |

## Sources

- [`Documentation/gitformat-loose.adoc`][loose] — object framing, the worked `blob 3\0abc` and empty-tree examples
- [`tree.c`][tree-c] — `base_name_compare` and `df_name_compare`
- [`fsck.c`][fsck-c] — the canonical-form checks and the non-consecutive-duplicates commentary
- [`object.h`][object-h] — `S_IFGITLINK`, `S_IFINVALID`
- [`content-address.md`][nix-ca] — Nix's statement of git's partiality over the FSO model

<!-- References -->

[nar]: ./nar.md
[ostree]: ./ostree.md
[reapi]: ./reapi.md
[loose]: https://github.com/git/git/blob/f78ce2f7b6df702f93d40b85d6bda92a3f65da79/Documentation/gitformat-loose.adoc
[tree-c]: https://github.com/git/git/blob/f78ce2f7b6df702f93d40b85d6bda92a3f65da79/tree.c
[fsck-c]: https://github.com/git/git/blob/f78ce2f7b6df702f93d40b85d6bda92a3f65da79/fsck.c
[object-h]: https://github.com/git/git/blob/f78ce2f7b6df702f93d40b85d6bda92a3f65da79/object.h
[nix-ca]: https://github.com/NixOS/nix/blob/1d8bdc1ee63246b591a8d77d0d481485cd09d438/doc/manual/source/store/file-system-object/content-address.md
