# Nix Archive (NAR)

The archive format Nix invented because every universal alternative failed the
one requirement that matters for content addressing: a single canonical
serialization per tree.

|                    |                                                                              |
| ------------------ | ---------------------------------------------------------------------------- |
| **Ecosystem**      | Nix                                                                          |
| **Level 1**        | serial serialization — no subtree values                                     |
| **Level 2**        | whole blob, inline in the stream                                             |
| **Node model**     | regular (+ executable bit), directory, symlink                               |
| **Entry ordering** | byte-wise on the raw name                                                    |
| **Digest**         | SHA-256 over the whole stream (`NarHash`), plus `NarSize`                    |
| **Specification**  | [`protocols/nix-archive/index.md`][nar-spec] (EBNF + a Kaitai Struct schema) |
| **Implementation** | [`src/libutil/archive.cc`][archive-cc]                                       |

## Overview

### What it solves

Hashing a directory tree requires turning it into bytes, and the obvious
candidates cannot be used. Nix's manual states the objection twice over
([`content-address.md`][nix-ca]) — first on canonicity:

> They do not have a canonical serialisation, meaning that given an FSO, there
> can be many different serialisations. For instance, TAR files can have
> variable amounts of padding between archive members; and some archive formats
> leave the order of directory entries undefined. This would be bad because we
> use serialisation to compute cryptographic hashes over file system objects,
> and for those hashes to be useful as a content address or for integrity
> checking, uniqueness is crucial.

and then on over-specification:

> They store more information than we have in our notion of FSOs, such as time
> stamps. This can cause FSOs that Nix should consider equal to hash to
> different values on different machines, just because the dates differ.

Both halves are load-bearing. A format that admits two encodings of one tree
breaks the hash; a format that encodes more than the model breaks equality.

### Design philosophy

NAR "closely follows the abstract specification of a [file system object] tree,
because it is designed to serialize exactly that data structure"
([`nix-archive/index.md`][nar-spec]). There is no framing beyond what the model
needs, no compression, no metadata section, and no index — the byte stream _is_
the tree, in order.

## How it works

The complete grammar, quoted from the specification:

```ebnf
nar = str("nix-archive-1"), nar-obj;

nar-obj = str("("), nar-obj-inner, str(")");

nar-obj-inner
  = str("type"), str("regular") regular
  | str("type"), str("symlink") symlink
  | str("type"), str("directory") directory
  ;

regular = [ str("executable"), str("") ], str("contents"), str(contents);

symlink = str("target"), str(target);

(* side condition: directory entries must be ordered by their names *)
directory = { directory-entry };

directory-entry = str("entry"), str("("), str("name"), str(name), str("node"), nar-obj, str(")");
```

with `str(s)` = `int(|s|), pad(s)`, `int(n)` a 64-bit little-endian length, and
`pad(s)` zero-padding to a multiple of 8 bytes. Three consequences worth
naming: every field is length-prefixed (so a parser never scans for a
delimiter), the executable bit is encoded as the _presence_ of a tag rather
than a value, and a symlink's target is stored verbatim and never followed.

### Dimension 1 — node model

Exactly the three FSO shapes, with one bit of metadata. A regular file carries
`executable` or does not; a symlink carries its target string; a directory
carries names. Permissions beyond the bit, ownership, timestamps, hard links
and extended attributes are all absent by construction — see [concepts][fso].

### Dimension 2 — canonical form and ordering

The grammar's side condition — "directory entries must be ordered by their
names" — is enforced on both sides of the round trip. The writer iterates a
`std::map<std::string, …>`, so ordering is `std::string`'s byte-wise `<`; the
reader rejects anything else outright ([`archive.cc`][archive-cc]):

```cpp
if (name <= prevName)
    throw badArchive("NAR directory is not sorted");
prevName = name;
```

Note `<=`, not `<`: duplicate names are rejected by the same check. Names are
validated too — empty, `.`, `..`, or containing `/` or NUL is
`"NAR contains invalid file name"`.

**The macOS case collision is handled by name mangling, not refusal.** A
case-insensitive filesystem cannot hold both `README` and `readme`, so Nix
carries a `use-case-hack` setting — "a macOS-specific hack for dealing with
file name case collisions" — that appends the literal suffix
`~nix~case~hack~` plus a counter on restore, and strips it again on dump. It is
not free of failure: unhacking two names onto one throws
`"file name collision between '%s' and '%s'"`, and a name that genuinely
contains the suffix throws as well. This is one of three distinct answers the
field gives to the same problem ([REAPI][reapi] and [git][git] give the others).

### Dimension 3 — level-1 composition

Serial, and therefore without subtree values. Nothing in a NAR names a
subdirectory: the parent's bytes _contain_ the child's bytes. The whole
consequence chain follows from that single fact — no subtree caching, no
incremental rehash after a one-file edit, no independent verification of a
fragment, and no parallel hashing at any file size, because SHA-256 over one
stream is inherently sequential.

### Dimension 4 — level-2 content addressing

Trivial: a regular file's contents are one `str(contents)` field inline in the
stream. There is no chunk tree, no block boundary, and no way to address a range
of a file.

### Dimension 5 — digest

`NarHash` is a hash (SHA-256 in practice) over the entire serialization, and
`NarSize` its length in bytes; both appear as fields in the
[`.narinfo`][narinfo] binary-cache format alongside `FileHash`/`FileSize` for
the _compressed_ transfer artifact. Nix also defines a **flat** method for the
single-file case — hash the raw bytes, with no framing at all — chosen "for
compatibility with other systems", so that `sha256sum` agrees ([`content-address.md`][nix-ca]).

### Dimension 6 — partial verification

None. A consumer must have the complete stream to check anything, which is
why the binary-cache protocol transfers whole NARs and validates after the
fact.

## Bounds worth copying

`archive.cc` caps the parser in three places, each with a stated reason — depth
"bounds stack usage so deep trees cannot overflow the (possibly coroutine)
stack these run on":

| Bound         | Value |
| ------------- | ----- |
| `narMaxDepth` | 64    |
| `narMaxTag`   | 32    |
| `narMaxName`  | 255   |

## Strengths

- **One tree, one byte string** — the property the format exists for, achieved
  with a grammar small enough to quote in full.
- **Trivially parseable**: every field length-prefixed, 8-byte aligned.
- **Streams in constant memory** in both directions, at any tree size.
- **Excludes what varies between machines** — timestamps and permissions cannot
  perturb the hash.

## Weaknesses

- **No subtree identity**, and everything that follows from it: no incremental
  rehash, no cross-run subtree cache, no parallelism within a hash.
- **Case collisions need an out-of-band hack** that is itself lossy in edge
  cases.
- **No partial verification** — integrity is all-or-nothing.
- **Padding and 64-bit lengths** make it larger than necessary for trees of
  many small files.

## Key design decisions and trade-offs

| Decision                                              | Rationale                                                         | Trade-off                                                                 |
| ----------------------------------------------------- | ----------------------------------------------------------------- | ------------------------------------------------------------------------- |
| Invent a format rather than reuse TAR/ZIP             | Neither has a canonical serialization, and both encode timestamps | A bespoke format every reimplementation must get byte-exact               |
| Serialize, don't Merkleize                            | Simplest thing that yields one digest per tree                    | No subtree values: no caching, no incremental hashing, no parallelism     |
| One `executable` bit, nothing more                    | Machine-varying metadata must not perturb the hash                | Cannot represent a tree faithfully enough to restore ownership or modes   |
| Entries sorted byte-wise, duplicates rejected on read | Canonicity enforced at the parser, not merely documented          | The order differs from [git's][git], so the two cannot share a comparison |
| Length-prefix and pad every field                     | Parse without delimiters or escaping                              | Bytes spent on padding; no human readability                              |
| Symlink target as an opaque string                    | Nix "does not assign any semantics to symbolic links"             | A dangling or absolute link round-trips unchanged, for better and worse   |

## Sources

- [`doc/manual/source/protocols/nix-archive/index.md`][nar-spec] — the complete grammar, plus `nar.ksy`
- [`doc/manual/source/store/file-system-object.md`][nix-fso] — the FSO model
- [`doc/manual/source/store/file-system-object/content-address.md`][nix-ca] — flat, NAR and Merkle methods
- [`doc/manual/source/protocols/binary-cache/narinfo.md`][narinfo] — where `NarHash`/`NarSize` surface
- [`src/libutil/archive.cc`][archive-cc] — dump, parse, the sort check, the case hack, the bounds
- [`src/libutil/include/nix/util/archive.hh`][archive-hh] — `caseHackSuffix`, `use-case-hack`

<!-- References -->

[fso]: ./concepts.md#file-system-object-fso
[git]: ./git-objects.md
[reapi]: ./reapi.md
[nar-spec]: https://github.com/NixOS/nix/blob/1d8bdc1ee63246b591a8d77d0d481485cd09d438/doc/manual/source/protocols/nix-archive/index.md
[nix-fso]: https://github.com/NixOS/nix/blob/1d8bdc1ee63246b591a8d77d0d481485cd09d438/doc/manual/source/store/file-system-object.md
[nix-ca]: https://github.com/NixOS/nix/blob/1d8bdc1ee63246b591a8d77d0d481485cd09d438/doc/manual/source/store/file-system-object/content-address.md
[narinfo]: https://github.com/NixOS/nix/blob/1d8bdc1ee63246b591a8d77d0d481485cd09d438/doc/manual/source/protocols/binary-cache/narinfo.md
[archive-cc]: https://github.com/NixOS/nix/blob/1d8bdc1ee63246b591a8d77d0d481485cd09d438/src/libutil/archive.cc
[archive-hh]: https://github.com/NixOS/nix/blob/1d8bdc1ee63246b591a8d77d0d481485cd09d438/src/libutil/include/nix/util/archive.hh
