# Bao / BLAKE3 verified streaming

The level-2 subject: a Merkle tree **inside** one file, which is what makes a
byte range verifiable, resumable and parallel-hashable — and the reason the
walk in this survey's design must never hand content to a visitor.

|                        |                                                                                |
| ---------------------- | ------------------------------------------------------------------------------ |
| **Ecosystem**          | iroh (`iroh-blobs`), `bao`, `bao-tree`; the same shape as IPFS unixfs chunking |
| **Level 1**            | **none** — a blob is the root; a directory is an application convention        |
| **Level 2**            | Merkle tree over 1024-byte BLAKE3 chunks, grouped into 16 KiB chunk groups     |
| **Node model**         | bytes; no file system object model at all                                      |
| **Digest**             | BLAKE3, 32 raw bytes                                                           |
| **Companion artifact** | an _outboard_ — the interior tree hashes, stored beside the data               |
| **In-repo survey**     | [`docs/research/iroh/blobs.md`][iroh-blobs-doc] (protocol, store, downloader)  |

> [!NOTE]
> This page covers only what bears on content addressing. The wire protocol,
> the crash-consistent store and the multi-provider downloader are surveyed in
> the [iroh blobs deep-dive][iroh-blobs-doc], and the tree math belongs to
> `bao-tree`.

## Overview

### What it solves

Fetching bytes from an untrusted peer and being able to reject a lie _before_
surfacing the data — without downloading the whole object first. That is
impossible with a whole-blob digest: a single hash can only be checked once the
last byte has arrived. Splitting the file into a Merkle tree makes every chunk
independently attributable to the root.

### Design philosophy

BLAKE3 is a tree hash by construction — 1024-byte chunks are leaves, and
interior nodes combine two child chaining values — so the verification tree is
not an addition to the hash, it _is_ the hash, read at a different granularity.
iroh picks a coarser block for I/O: `IROH_BLOCK_SIZE` is
`BlockSize::from_chunk_log(4)`, documented in [`store/mod.rs`][store-mod] as
"Block size used by iroh, 2^4\*1024 = 16KiB", while ranges remain denominated in
chunks — [`protocol.rs`][protocol-rs] is explicit that "Ranges are always given
in terms of 1024 byte blake3 chunks".

The store keeps the tree's interior separately from the payload, for a reason
worth quoting ([`DESIGN.md`][design-md], via the [iroh survey][iroh-blobs-doc]):

> The job of a blob store is to store two pieces of data per hash, the actual
> data itself and an `outboard` containing the BLAKE3 hash tree that connects
> each chunk of data to the root. Data and outboard are kept separate so that
> the data can be used as-is.

## How it works

A response is a pre-order interleave of 64-byte parent nodes (left chaining
value ‖ right chaining value) and leaf payloads of at most one chunk group,
preceded by an 8-byte little-endian **claimed** size. The decoder reconstructs
the same traversal from `(size, ranges)` and validates each parent and leaf
against a hash stack seeded with the requested root, so "a lying or corrupt
provider is caught within one 16 KiB chunk group."

One integrity subtlety generalizes beyond iroh: the size header is _claimed_,
not trusted, so a validated leaf containing the final chunk must end exactly at
the claimed size — otherwise a remote could inflate work with a fake length.
[REAPI's][reapi] decision to carry `size_bytes` inside `Digest` is the same
guard reached from the other direction.

### Dimension 1 — node model

There is none. A blob is a sequence of bytes; there is no executable bit, no
symlink, no directory. Collections of blobs are a convention (`HashSeq`), not a
protocol concept. **This is the finding that matters for a fileset design**: a
scheme can be entirely level-2, which is only expressible if the two levels are
independent rather than nested.

### Dimension 2 — canonical form and ordering

Not applicable — there are no named entries to order. Canonicity comes from the
tree geometry being fully determined by the byte length, which is why blob
boundaries "need no delimiter".

### Dimension 3 — level-1 composition

Absent by design.

### Dimension 4 — level-2 content addressing

The subject's entire content. Chunks are fixed-size (1024 bytes), _not_
content-defined: there is no rolling hash and no boundary-shifting. That is a
deliberate difference from content-defined chunking (FastCDC and relatives),
which buys dedup under insertion at the cost of a deterministic geometry — and
iroh needs the geometry, because `(size, ranges)` must reconstruct the
traversal exactly.

Two properties follow that a whole-blob scheme cannot have:

- **Intra-file parallelism.** Disjoint aligned ranges hash independently and
  combine, so a large file is not a serial hash. Contrast [NAR][nar], where a
  100 GiB file is one sequential SHA-256 at any core count.
- **Monotone possession.** From [`DESIGN.md`][design-md]: "A chunk of a blob
  can only go from not present (all zeroes) to present […] And this means that
  all changes due to syncing from a remote source commute, which makes dealing
  with concurrent downloads from multiple sources much easier." Commutativity
  of partial state is what makes resumable, multi-provider fetching sound — and
  it is a property of the _chunk tree_, unavailable to a whole-blob digest.

### Dimension 5 — digest

BLAKE3, 32 raw bytes on the wire with no length prefix; displayed as 64-char
lowercase hex, parsed from hex or 52-char base32-nopad. The empty blob is a
hard-coded special case that is never stored and always "present".

### Dimension 6 — partial verification

Complete, at chunk-group granularity — the reason the scheme exists. A consumer
can request an arbitrary set of ranges and verify exactly those against the
root.

## The sibling: IPFS unixfs

The same shape with different parameters: files are chunked (a default in the
hundreds of KiB), the chunks form a DAG-PB Merkle DAG, directories _are_
modelled (unlike Bao), and digests are multihash-tagged so the algorithm
travels with the value. Its chunker is pluggable and may be content-defined,
which is where CDC genuinely lives in this landscape — as a level-2 boundary
policy, not an addressing scheme. Surveyed here only as a contrast; the
in-repo [iroh catalog][iroh-index] covers the peer-to-peer side in depth.

## Strengths

- **Verification at 16 KiB granularity** against an untrusted source.
- **Intra-file parallel hashing**, unavailable to every whole-blob scheme here.
- **Resumable and multi-provider** by construction, because partial state
  commutes.
- **Geometry from length alone** — no delimiters, no index to distribute.

## Weaknesses

- **No file system object model**, so it cannot address a tree by itself.
- **An outboard to store and keep consistent** beside every large blob.
- **Fixed-size chunks** give no dedup under insertion.
- BLAKE3 internals (`finalize_non_root`, chaining-value merging, root domain
  separation) must be exposed by the hash implementation — a one-shot `hash()`
  API is not enough, which is a real porting constraint.

## Key design decisions and trade-offs

| Decision                                     | Rationale                                                    | Trade-off                                                                  |
| -------------------------------------------- | ------------------------------------------------------------ | -------------------------------------------------------------------------- |
| Merkle tree inside the file                  | Reject corrupt data within one chunk group, not one blob     | An outboard artifact per blob, and a second thing to keep crash-consistent |
| Fixed 1024-byte chunks, 16 KiB groups        | Geometry derivable from length; no index to transmit         | No dedup under insertion; no content-defined boundaries                    |
| Data and outboard stored separately          | "so that the data can be used as-is"                         | Two files per blob, and a consistency discipline between them              |
| Claimed size verified against the final leaf | A remote cannot inflate work with a fake length              | Size must be carried and checked everywhere                                |
| Deletion is whole-blob only                  | Chunk possession stays monotone, so concurrent syncs commute | No partial eviction of a large blob                                        |
| No level-1 model at all                      | Keeps the blob layer orthogonal to any tree convention       | Anything tree-shaped is an application concern                             |

## Sources

- [`src/store/mod.rs`][store-mod] — `IROH_BLOCK_SIZE`, "2^4\*1024 = 16KiB"
- [`src/protocol.rs`][protocol-rs] — ranges denominated in 1024-byte chunks
- [`DESIGN.md`][design-md] — the outboard's purpose; monotone possession and commutativity
- [iroh blobs deep-dive][iroh-blobs-doc] — the in-repo survey of the protocol, store and downloader

<!-- References -->

[nar]: ./nar.md
[reapi]: ./reapi.md
[iroh-blobs-doc]: ../iroh/blobs.md
[iroh-index]: ../iroh/index.md
[store-mod]: https://github.com/n0-computer/iroh-blobs/blob/e82cbdcbdac9a78033174aad55e3199b2cf4c0dc/src/store/mod.rs
[protocol-rs]: https://github.com/n0-computer/iroh-blobs/blob/e82cbdcbdac9a78033174aad55e3199b2cf4c0dc/src/protocol.rs
[design-md]: https://github.com/n0-computer/iroh-blobs/blob/e82cbdcbdac9a78033174aad55e3199b2cf4c0dc/DESIGN.md
