---
status: draft
owner: sparkles:build-primitives
reviewed: 2026-11-09
---

# Content addressing — Decisions

The founding record is the filesets decision
[A19](../filesets/decisions.md#a19-content-addressing-is-a-family-of-schemes-with-snix-castore-as-the-default):
content addressing is a family of schemes on the fileset seam, castore with
BLAKE3 is the default identity, and every instance has an oracle. The records
below follow from it. Each states its question, the alternatives, the choice
and when to revisit it; **proposed** records await the owner's decision, and
**open** ones have no proposal yet.

## C1: `NarHash` is stored beside the identity (proposed)

_Was open as the filesets record D2._

**Question.** A Nix store asks for the `NarHash` and `NarSize` of every path
it is given. Is that hash computed once, when the fileset is named, and kept
with its identity, or recomputed from the stored tree when a Nix boundary
asks?

**Alternatives.**

- **Recompute on demand.** Keep only the castore identity, and render the
  NAR from the stored blobs and directories when asked. Nothing is spent on
  SHA-256 by a consumer that never meets Nix.
- **Store it.** Compute the NAR in the same walk that names the fileset, and
  keep the digest and length beside the identity.

**Evidence.** Snix stores `nar_size` and `nar_sha256` in its `PathInfo`, and
makes `NarCalculationService` a trait so that a remote store can answer
instead of re-walking the tree and re-streaming every blob
([castore research](../../../research/content-addressing/tvix-castore.md),
[recommendation 2](../../../research/content-addressing/recommendations.md#_2-narhash-should-be-stored-not-merely-recomputable)).
The tee of [`CAT2`](./SPEC.md#_6-the-tee-cat) computes both in one walk that
reads each file once, so storing costs one SHA-256 pass over bytes already
in memory, not a second read.

**Choice.** Store it. The default tee, `CastoreNar`, returns the castore id
with `NarHash` and `NarSize` beside it ([`CAT3`](./SPEC.md#_6-the-tee-cat)).
A consumer that never meets Nix names its filesets by castore alone, and
pays nothing for NAR. Where the pair is kept is the store's.

**Revisit** if a store must answer for trees it named by castore alone. It
then has to recompute, as Snix's trait allows, and the contract would need a
NAR rendered from stored blobs rather than from a walk.

## C2: The outboard's layout (open)

**Question.** [`CAO1` and `CAO2`](./SPEC.md#_7-a-file-s-supplied-tree-cao)
need a supplied tree to have one layout. Which one, at which chunk-group
size?

**Alternatives.**

- **iroh's pre-order outboard at 16 KiB chunk groups.** Records of 64 bytes
  in pre-order, with no size prefix: `(blocks - 1) * 64` bytes for
  `blocks = ceil(size / 16384)`. It is the layout `iroh-blobs` keeps on
  disk, so a blob fetched from iroh arrives with its tree
  ([bao-tree](../../../research/iroh/bao-tree.md)).
- **The `bao` crate's outboard.** 1024-byte chunks with a length prefix: an
  outboard 16 times larger, which no store in this design produces.

**Constraints.** The oracle must be independent: `bao-tree`'s own encoder,
or `sendme`, both from nixpkgs. Producing either layout needs BLAKE3's
chaining values for whole subtrees, which `sparkles.base.hash.blake3`
computes internally but does not expose.

**Decision point.** Before `CAO1` is implemented. iroh's layout is the
expected choice, because publishing to iroh is the consumer that motivates
it.
