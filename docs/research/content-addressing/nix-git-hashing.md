# Nix `git-hashing`

One system, two level-1 schemes — the direct precedent for computing a
git-shaped Merkle identity internally while still emitting a
[NAR][nar] at the interoperability boundary.

|                    |                                                                    |
| ------------------ | ------------------------------------------------------------------ |
| **Ecosystem**      | Nix (experimental feature `git-hashing`)                           |
| **Level 1**        | git tree objects, over Nix's FSO model                             |
| **Level 2**        | git blobs                                                          |
| **Node model**     | the [Nix FSO triple][fso] — mapped onto git's modes, **partially** |
| **Entry ordering** | git's, implemented by suffixing directory keys with `/`            |
| **Digest**         | SHA-1 or SHA-256                                                   |
| **Implementation** | [`src/libutil/git.cc`][git-cc], [`git.hh`][git-hh]                 |

## Overview

### What it solves

Nix needed a Merkle-graph content-addressing method alongside serial [NAR][nar]
hashing, and rather than invent one it adopted git's. Its reasoning
([`file-system-object/content-address.md`][nix-ca]):

> Git's file system model is very close to Nix's, and so Git's content
> addressing method is a pretty good fit. Just as with regular Git, files and
> symlinks are hashed as git "blobs", and directories are hashed as git
> "trees".

That is the whole case for reusing git's shape: an existing, ubiquitous,
independently-implemented Merkle DAG whose node model is a near-match.

### Design philosophy

The interesting part is what Nix documents as _not_ fitting, because it is the
sharpest available statement of [git's][git] structural limitation:

> Plain files, executable files, and symlinks are not differentiated as
> distinctly addressable objects, but by their context: by the directory entry
> that refers to them. That means so long as the root object is a directory,
> there is no problem […] However, if the root object is not a directory, then
> we have no way of knowing which one of an executable file, non-executable
> file, or symlink it is supposed to be.
>
> In response to this, we have decided to treat a bare file as non-executable
> file. […] To avoid an address collision, attempts to hash a bare executable
> file or symlink will result in an error […] Thus, Git can encode some, but
> not all of Nix's "File System Objects", and this sort of content-addressing
> is likewise **partial**.

A scheme that is partial over its own model, and says so, is a better guide
than one that pretends otherwise.

## How it works

[`git.cc`][git-cc] is a compact, readable second implementation of git's object
formats. Blobs:

```cpp
auto s = fmt("blob %d\0"s, std::to_string(size));
```

Trees, with the ordering trick made explicit:

```cpp
for (auto & [name, entry] : entries) {
    auto name2 = name;
    if (entry.mode == Mode::Directory) {
        assert(!name2.empty());
        assert(name2.back() == '/');
        name2.pop_back();
    }
    v1 += fmt("%o %s\0"s, static_cast<RawMode>(entry.mode), name2);
    std::copy(entry.hash.hash, entry.hash.hash + entry.hash.hashSize, std::back_inserter(v1));
}
```

The `Tree` type is a `std::map` keyed by name, and [`git.hh`][git-hh] states
the invariant in a comment that is the clearest one-line account of git
ordering anywhere in this survey:

> Directory names must end in a `/` for sake of sorting. See
> https://github.com/mirage/irmin/issues/352

So: append `/` to directory keys, let the ordered map sort byte-wise, strip the
`/` when writing. An independent reimplementation arriving at the same trick —
and the cited irmin issue is a third project arriving there too — is good
evidence that this is the _only_ practical way to get git's order from a
byte-wise container.

A symlink is dumped as a blob of its target, and the whole path is gated on the
experimental feature: every entry point calls
`xpSettings.require(Xp::GitHashing)`.

## What it demonstrates for a fileset design

Three things, each directly load-bearing:

1. **Two level-1 schemes can coexist over one node model.** Nix computes NAR
   hashes and git hashes from the same `SourceAccessor` walk. The walk does not
   know which scheme will consume it.
2. **The two orderings cannot share a primitive.** Nix's NAR path sorts raw
   names; its git path sorts `/`-suffixed keys. They are separate code with
   separate containers, in one codebase, by necessity — see the
   [ordering axis][rec-ordering].
3. **Partiality is a property to surface, not to paper over.** The bare
   executable file and bare symlink cases are _errors_, not silent
   reinterpretations, and the flat method is documented as having the same
   limitation for the same reason.

## Strengths

- **Merkle identity with two independent oracles** — `git hash-object` /
  `git write-tree`, and Nix's own implementation.
- **A second, readable implementation** of git's formats, useful as a reference
  when porting.
- **The partiality is documented and enforced**, not discovered later.

## Weaknesses

- **Experimental**, and gated at every entry point.
- **Partial over the FSO model** — bare executable files and bare symlinks
  cannot be addressed.
- Inherits git's ordering, and therefore needs the `/`-suffix workaround in any
  container that sorts byte-wise.

## Key design decisions and trade-offs

| Decision                                           | Rationale                                                            | Trade-off                                                           |
| -------------------------------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------------- |
| Adopt git's method rather than design a Merkle one | Git's model "is very close to Nix's"; enormous existing tooling      | Inherits git's ordering quirk and its mode-in-the-parent partiality |
| Error on bare executable files and symlinks        | "To avoid an address collision"                                      | Some FSOs simply have no git address                                |
| Suffix directory keys with `/` in an ordered map   | The only way to get git's order from a byte-wise container           | A representation invariant to assert, and to strip on output        |
| Keep both NAR and git hashing                      | Serial for the store's existing identity, Merkle where a graph helps | Two canonical orderings, two serializers, in one codebase           |
| Gate behind an experimental feature                | The method is partial and not yet committed to                       | Consumers cannot rely on it                                         |

## Sources

- [`doc/manual/source/store/file-system-object/content-address.md`][nix-ca] — the flat / NAR / git methods and the partiality statement
- [`src/libutil/git.cc`][git-cc] — `dumpBlobPrefix`, `dumpTree`, `dump`
- [`src/libutil/include/nix/util/git.hh`][git-hh] — `Tree`, `ObjectType`, and the `/`-suffix comment

<!-- References -->

[nar]: ./nar.md
[git]: ./git-objects.md
[fso]: ./concepts.md#file-system-object-fso
[rec-ordering]: ./recommendations.md#axis-2-entry-ordering
[nix-ca]: https://github.com/NixOS/nix/blob/1d8bdc1ee63246b591a8d77d0d481485cd09d438/doc/manual/source/store/file-system-object/content-address.md
[git-cc]: https://github.com/NixOS/nix/blob/1d8bdc1ee63246b591a8d77d0d481485cd09d438/src/libutil/git.cc
[git-hh]: https://github.com/NixOS/nix/blob/1d8bdc1ee63246b591a8d77d0d481485cd09d438/src/libutil/include/nix/util/git.hh
