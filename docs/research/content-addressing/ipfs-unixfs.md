# IPFS unixfs, IPLD & CID

The **self-describing digest**, and the only answer in this survey to a
directory too large to be one object.

|                    |                                                                          |
| ------------------ | ------------------------------------------------------------------------ |
| **Ecosystem**      | IPFS, Filecoin, the wider IPLD/multiformats family                       |
| **Level 1**        | DAG-PB Merkle DAG; huge directories **HAMT-sharded** into sub-objects    |
| **Level 2**        | a pluggable chunker — fixed-size or content-defined                      |
| **Node model**     | file, directory, symlink; optional mode and mtime                        |
| **Digest**         | **CID** — a self-describing tuple of version, content type and multihash |
| **Specifications** | [CID][cid-spec], [unixfs][unixfs-spec]                                   |

## Overview

### What it solves

Addressing arbitrary data on an open network where no participant can be
assumed to share your hash function, your codec, or your string encoding. Every
other subject in this survey fixes those by fiat; IPFS makes them part of the
address.

### Design philosophy

The CID specification states the goal directly ([`multiformats/cid`][cid-spec]):

> It uses a [multicodec] to indicate its version, making it **fully self
> describing**.

and composes three registries to get there:

> 1. [multihash] to hash content addressed, and
> 2. [multicodec] to type that addressed content,
> 3. [multibase] to encode that binary CID as a string.

## How it works

A CIDv1 is a binary concatenation of unsigned varints:

```text
<cidv1> ::= <CIDv1-multicodec><content-type-multicodec><content-multihash>
```

— the version code, a codec identifying _how to interpret_ the bytes
(`dag-pb`, `dag-cbor`, `raw`, …), and a multihash that itself carries a hash
function code and length. Its string form prefixes a multibase character, so
even the text encoding is negotiable:

```text
<cidv1> ::= <multibase-codec><multibase-encoding(<CIDv1-multicodec><multicodec><multihash>)>
```

### Dimension 1 — node model

unixfs models files, directories and symlinks, with mode and mtime as
_optional_ fields — so, like [REAPI][reapi], it can carry a timestamp without
requiring one. A file is not a blob but a **DAG**: a root node listing child
chunk links plus their sizes.

### Dimension 2 — canonical form and ordering

The weakest in the survey, and knowingly so. A unixfs file's CID depends on the
**chunker, the chunk size, the DAG layout (balanced vs trickle), and whether
raw leaves are used** — all producer choices. Two IPFS nodes importing the same
file with different settings produce different CIDs. Where [OCI][oci] fails to
be canonical by accident, IPFS declines to be canonical by design, treating the
import parameters as part of the addressing decision rather than a bug.

### Dimension 3 — level-1 composition

A Merkle DAG, with one capability nothing else here has: **HAMT sharding**. A
directory with a million entries would otherwise be one enormous object that
must be fetched whole to resolve one name; unixfs shards such directories into
a hash-array-mapped trie of sub-objects, so a lookup fetches `O(log n)` blocks.
[Git][git], [NAR][nar], [OSTree][ostree] and [REAPI][reapi] all encode a
directory as a single object, and all degrade the same way on a pathological
directory.

### Dimension 4 — level-2 granularity

A chunk DAG, with the chunker as a parameter — fixed-size by default,
content-defined (rabin, buzhash) optionally. This is the **home of CDC as a
policy**, exactly as the survey's scope note claims: the same level-1 model
accepts either boundary strategy.

### Dimension 5 — digest

The CID, and the reason this subject earns a page. Compare the field: [git][git]
makes the hash function a repository-wide property, [REAPI][reapi] negotiates
it per server, [NAR][nar], [OSTree][ostree] and [Bao][bao] fix it. Only a CID
carries the answer _inside the address_, so a digest remains interpretable when
it is separated from the system that made it.

### Dimension 6 — partial verification

Per block, at DAG granularity, in both levels.

## Strengths

- **Self-describing**: hash function, codec and string encoding travel with the
  address.
- **HAMT-sharded directories** — the only answer to a directory that does not
  fit in one object.
- **Chunking is a parameter**, so one model serves dedup-oriented and
  determinism-oriented imports.
- Genuine format agility (`dag-pb`, `dag-cbor`, `raw`) under one address type.

## Weaknesses

- **No canonical form**: the same bytes yield different CIDs under different
  import settings, which makes CIDs poor _equality_ tests for content.
- Multiformats are three more registries to implement and keep current.
- A file is a DAG even when it is small, so there is per-file structural
  overhead.
- The spec surface is spread across several repositories and moved hosts —
  `ipfs/specs`' `UNIXFS.md` is now a stub reading "Moved to
  <https://specs.ipfs.tech/unixfs/>".

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                 | Trade-off                                                    |
| ---------------------------------------------------------- | --------------------------------------------------------- | ------------------------------------------------------------ |
| Self-describing addresses (multihash/multicodec/multibase) | An open network cannot agree on one hash function forever | Three registries; longer addresses; parsing complexity       |
| Chunker and layout as import parameters                    | Serves both dedup and determinism                         | The same file has many valid CIDs — canonicity is sacrificed |
| Files as DAGs, not blobs                                   | Partial fetch and dedup inside a file                     | Structural overhead even for tiny files                      |
| HAMT-shard large directories                               | A million-entry directory stays resolvable in `O(log n)`  | Two directory representations, and a threshold to tune       |

## Sources

- [`multiformats/cid` README][cid-spec] — the CIDv1 grammar and the three registries
- [unixfs specification][unixfs-spec] — the file/directory model, chunking and HAMT sharding

<!-- References -->

[nar]: ./nar.md
[git]: ./git-objects.md
[ostree]: ./ostree.md
[reapi]: ./reapi.md
[oci]: ./oci-layers.md
[bao]: ./bao-blake3.md
[cid-spec]: https://github.com/multiformats/cid/blob/9eca1c5ba064823a5ddbe13e9925f9b6c9d19c84/README.md
[unixfs-spec]: https://specs.ipfs.tech/unixfs/
[multicodec]: https://github.com/multiformats/multicodec
[multihash]: https://github.com/multiformats/multihash
[multibase]: https://github.com/multiformats/multibase
