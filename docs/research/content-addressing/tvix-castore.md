# Snix castore (formerly Tvix castore)

A production Nix reimplementation that replaced [NAR][nar]-as-identity with a
BLAKE3 Merkle DAG and kept NAR only as a boundary format — the catalog's own
recommendation, already shipped by somebody else.

|                    |                                                                                             |
| ------------------ | ------------------------------------------------------------------------------------------- |
| **Ecosystem**      | Snix (the Rust reimplementation of Nix; `snix-castore`, `snix-store`)                       |
| **Level 1**        | Merkle DAG of protobuf `Directory` messages, addressed by digest                            |
| **Level 2**        | whole blob, digested by plain BLAKE3 over the raw bytes; chunking is a storage concern      |
| **Node model**     | file (+ `executable`), directory (+ `size`), symlink                                        |
| **Entry ordering** | byte-wise on the raw `name`, **within three separate arrays**                               |
| **Digest**         | BLAKE3-256 over the canonical protobuf serialization of `Directory`; raw BLAKE3 over a blob |
| **Documentation**  | [Data Model][data-model], [Why not Git?][why-not-git], [Blobstore: Chunking][chunking]      |

> [!NOTE]
> **Naming.** The component was `tvix-castore` under the TVL `tvix` project and
> is now `snix-castore` in the [`snix/snix`][repo] repository on the project's
> own Forgejo instance (`git.snix.dev`), default branch `canon`. The protobuf
> package renamed from `tvix.castore.v1` to `snix.castore.v1`; the copyright
> headers still read "Copyright © 2022 The Tvix Authors". Everything below is
> read from `snix/snix` at [`86a6e6e`][repo], and every source citation pins
> that commit.

## Overview

### What it solves

Nix's remote store protocol transfers whole [NAR][nar] files, which are serial
and therefore indivisible. `snix-store`'s README states the objection and the
answer in two sentences ([`snix/store/README.md`][store-readme]):

> Compared to the Nix model, `snix-store` stores data on a much more granular
> level than that, which provides more deduplication possibilities, and more
> granular copying.
>
> However, enough information is preserved to still be able to render NAR and
> NARInfo when needed.

The component documentation puts the same trade in terms of what the serial
format costs ([`responsibilities.md`][responsibilities]):

> Snix natively uses an improved store protocol. Instead of transferring around
> NAR files, which don't provide an index and don't allow seekable access, a
> concept similar to git tree hashing is used.
>
> This allows more granular substitution, chunk reusage and parallel download of
> individual files, reducing bandwidth usage. As these chunks are
> content-addressed, it opens up the potential for peer-to-peer trustless
> substitution of most of the data, as long as we sign the root of the index.

### Design philosophy

The model is git's, rebuilt on protobuf and BLAKE3 — and the project wrote down
why it did not simply adopt git's encoding ([`why-not-git.md`][why-not-git]):

> The git tree object format is a very binary, error-prone and
> "made-to-be-read-and-written-from-C" format.
>
> Tree objects are a combination of null-terminated strings, and fields of known
> length. References to other tree objects use the literal sha1 hash of another
> tree object in this encoding. Extensions of the format/changes are very hard
> to do right, because parsers are not aware they might be parsing something
> different.

and, on level 2, the objection that decides this page's most interesting
dimension:

> On disk, git blob objects start with a "blob" prefix, then the size of the
> payload, and then the data itself. The hash of a blob is the literal sha1sum
> over all of this - which makes it something very git specific to request for.
>
> The [Snix Castore Data Model] simply uses the [BLAKE3] hash of the literal
> contents when referring to a file/blob, which makes it very easy to ask other
> data sources for the same data, as no git-specific payload is included in the
> hash.

The second half of that quote is the thesis: a file's identity is the BLAKE3 of
its bytes and nothing else, so any BLAKE3-addressed system — [iroh][iroh] is
named explicitly — can serve it.

## How it works

Three layers, each content-addressed independently:

| Layer                     | Identity                                          | Service            |
| ------------------------- | ------------------------------------------------- | ------------------ |
| Blob (file contents)      | BLAKE3 of the **raw bytes**                       | `BlobService`      |
| `Directory` message       | BLAKE3 of its canonical protobuf serialization    | `DirectoryService` |
| `PathInfo` (a store path) | a root `Entry` + Nix metadata, incl. `nar_sha256` | `PathInfoService`  |

The Rust node type states the level-1 edge and the blob rule in one place
([`nodes/mod.rs`][nodes-mod]):

```rust
pub enum Node {
    Directory {
        /// The blake3 hash of a Directory message, serialized in protobuf canonical form.
        digest: B3Digest,
        size: u64,
    },
    File {
        /// The blake3 digest of the file contents
        digest: B3Digest,
        size: u64,
        executable: bool,
    },
    Symlink {
        target: SymlinkTarget,
    },
}
```

A `B3Digest` is exactly `blake3::OUT_LEN` bytes and renders as `blake3-` plus
base64 ([`digests.rs`][digests]) — note the algorithm tag lives in the _display_
form, not in the stored 32 bytes.

### Dimension 1 — node model

Three kinds, and the metadata floor is [NAR][nar]'s: one executable bit. No
mode, no ownership, no timestamps, no extended attributes. Two fields go
_beyond_ NAR, and both are sizes rather than metadata:

- `FileEntry.size` — the blob length, the same truncation guard
  [REAPI][reapi] puts inside `Digest`.
- `DirectoryEntry.size` — the transitive child count of the referenced
  subtree, whose proto comment is unusually careful about what it is worth
  ([`castore.proto`][proto]):

  > This field is precisely as verifiable as any other Merkle tree edge.
  > Resolve `digest`, and you can compute it incrementally. Resolve the entire
  > tree, and you can fully compute it from scratch. A credulous implementation
  > won't reject an excessive size, but this is harmless: you'll have some
  > ordinals without nodes. Undersizing is obvious and easy to reject: you
  > won't have an ordinal for some nodes.

  Its stated purpose is inode allocation for the FUSE mount. It _is_ checked on
  ingest: `order_validator.rs` reports `WrongSize { digest, referenced, actual }`
  when a received `Directory`'s computed size disagrees with the pointer that
  named it ([`order_validator.rs`][order-validator]).

Names are a distinct type, `PathComponent`, validated rather than assumed
([`path/component.rs`][component]):

```rust
pub const MAX_NAME_LEN: usize = 255;

pub(super) fn validate_name<B: AsRef<[u8]>>(name: B) -> Result<(), PathComponentError> {
    match name.as_ref() {
        b"" => Err(PathComponentError::Empty),
        b".." => Err(PathComponentError::Parent),
        b"." => Err(PathComponentError::CurDir),
        v if v.len() > MAX_NAME_LEN => Err(PathComponentError::TooLong),
        v if v.contains(&0x00) => Err(PathComponentError::Null),
        v if v.contains(&b'/') => Err(PathComponentError::Slashes),
        _ => Ok(()),
    }
}
```

`MAX_NAME_LEN` is 255 for the reason NAR's `narMaxName` is — "Linux allows 255
bytes of actual name, so we pick that" — an independent arrival at the same
bound.

### Dimension 2 — canonical form and ordering

**Three sorted arrays, byte-wise on the raw name — REAPI's answer, not
NAR's or git's.** The schema states it normatively ([`castore.proto`][proto]):

> The name attribute:
>
> - MUST not contain slashes or null bytes
> - MUST not be '.' or '..'
> - MUST be unique across all three lists
>
> Elements in each list need to be lexicographically ordered by the name
> attribute.

Uniqueness spans the three lists, so `a` cannot be both a file and a directory,
but ordering is _per list_ — a file and a directory never compare, which makes
git's implicit-`/` problem structurally unaskable here.

The check is enforced on ingest, not merely documented. `TryFrom<proto::Directory>`
folds each of the three lists against the previous name
([`proto/mod.rs`][proto-mod]):

```rust
value.files.iter().try_fold(&b""[..], |prev_name, e| {
    match e.name.as_ref().cmp(prev_name) {
        Ordering::Less => Err(DirectoryError::WrongSorting(e.name.to_owned())),
        Ordering::Equal => Err(DirectoryError::DuplicateName(/* … */)),
        Ordering::Greater => Ok(e.name.as_ref()),
    }
})?;
```

The in-memory `Directory` keeps a single `BTreeMap<PathComponent, Node>`
([`nodes/directory.rs`][nodes-directory]), so the _producer_ side gets one
byte-wise order for free and the three arrays are a partition of it on
serialization — the same "sort once, partition by kind" move this catalog's
[falsification gate][gate-reapi] identified for REAPI.

Canonicity rests on deterministic protobuf encoding, and the project says so
rather than assuming it ([`data-model.md`][data-model]):

> We currently use the [BLAKE3] digest of the protobuf serialization of the
> `proto::Directory` struct to calculate these digests. While pretty stable
> across most implementations, there's no guarantee this will always stay
> as-is, so we might switch to another serialization with stronger guarantees
> on that front in the future.

### Dimension 3 — level-1 composition

A Merkle DAG, explicitly so ([`data-model.md`][data-model]):

> The pointers from `Node::File` to `Directory`, and this one potentially
> containing `Node::File` again makes the whole structure a merkle tree (or
> strictly speaking, a graph, as two elements pointing to a child directory with
> the same contents would point to the same `Directory` message).

The digest is one line ([`proto/mod.rs`][proto-mod]):

```rust
pub fn digest(&self) -> B3Digest {
    let mut hasher = blake3::Hasher::new();
    hasher.update(&self.encode_to_vec()).finalize().as_bytes().into()
}
```

There is no length prefix, no type tag and no framing around the message — the
protobuf encoding _is_ the canonical form, and the type is implied by which
field of the parent the digest sits in. Ingest is order-validated in either
direction: `RootToLeaves` and `LeavesToRoot` implement a shared `OrderValidator`
trait whose `finalize` fails with `DirectoriesMissing` unless the accepted set
is a full closure ([`order_validator.rs`][order-validator]).

### Dimension 4 — level-2 content addressing

This is where the design departs from every other Merkle subject in this
catalog. A blob's identity is **plain BLAKE3 over the raw contents** — but
because BLAKE3 is itself a tree hash, chunking becomes a transport question
rather than an identity question ([`blobstore-chunking.md`][chunking]):

> It uses [BLAKE3] as hash function, and the blake3 digest of **the raw data
> itself** as an identifier (rather than some application-specific Merkle DAG
> that also embeds some chunking information).
>
> BLAKE3 is a tree hash where all left nodes fully populated, contrary to
> conventional serial hash functions. To be able to validate the hash of a node,
> one only needs the hash of the (2) children, if any.
>
> This means one only needs the root digest to validate a construction, and
> these constructions can be sent separately.
>
> This relieves us from the need of having to encode more granular chunking into
> our data model / identifier upfront, but can make this mostly a transport/
> storage concern.

The same document names the disease it is avoiding, and it is the one
[casync][casync] and [IPFS unixfs][unixfs] both have:

> However, they also have a big disadvantage. The chunking parameters, and the
> "topology" of the graph structure itself "bleeds" into the root hash of the
> entire data structure itself.
>
> Depending on the chunking parameters used, there's different representations
> for the same data, causing less data sharing/reuse in the overall system […]

**Chunking exists, but below identity.** The object-store blob backend runs
FastCDC v2020 over the stream while a separate `blake3::Hasher` consumes the
same bytes ([`blobservice/object_store/mod.rs`][objstore]):

```rust
let mut hasher = blake3::Hasher::new();
let mut b3_r = InspectReader::new(r, |data| { hasher.update(data); });
let mut chunker = AsyncStreamCDC::new(&mut b3_r, min_chunk_size, avg_chunk_size, max_chunk_size);
```

with `avg_chunk_size` defaulting to `256 * 1024` and min/max at half and double
that. Each chunk is stored zstd-compressed under its own BLAKE3 digest; the
blob object stores only a `StatBlobResponse` listing chunk digests and sizes.
Change the chunking parameters and the blob digest does not move — the chunk
store's contents do. When the chunker produces a single chunk, the list is
emitted empty, because "according to the protocol, we must return an empty list
of chunks when the blob is not split up further".

Crucially, the wire protocol treats the chunk list as advisory
([`rpc_blobstore.proto`][rpc-blob]):

> The way the data is chunked up in individual BlobChunk messages sent in the
> stream has no effect on how the server ends up chunking blobs up, if it does
> at all.

### Dimension 5 — digest

BLAKE3-256 everywhere, unnegotiated: 32 raw bytes, `blake3::OUT_LEN`
([`digests.rs`][digests]). There is no algorithm agility at the castore layer —
no multihash tag, no `DigestFunction` enum as in [REAPI][reapi]. The `blake3-`
prefix appears only in `Display`/`FromStr`, and `FromStr` rejects anything else
with `InvalidHashType`.

Sizes travel beside digests at both levels (`FileEntry.size`,
`DirectoryEntry.size`), the same guard [REAPI][reapi] and [Bao][bao] arrived at
independently.

### Dimension 6 — partial verification

Two granularities, one shipped and one declared.

**Per `Directory` message, and per blob: shipped.** Every edge is a digest, so
any node verifies against the pointer that named it. The object-store backend
re-hashes a fetched chunk before returning it — "ensure the b3 digest matches"
— and fails with `chunk contents invalid` otherwise ([`objstore`][objstore]).

**Per byte range inside a file: designed, partially built.** Because the
identity _is_ a BLAKE3 root, [Bao][bao]-style verified streaming needs only an
outboard tree, and the protocol already reserves the field
([`rpc_blobstore.proto`][rpc-blob]):

```proto
message StatBlobRequest {
  bytes digest = 1;
  bool send_chunks = 2;
  bool send_bao = 3;
}
```

with the response field documented as

> If `send_bao` was set to true, this MAY contain a outboard bao. The exact
> format and message types here will still be fleshed out.

and the writer path leaving `bao: "".into(), // still todo`. So today's chunk
list is **not** cryptographically bound to the blob digest: a client can verify
each chunk it receives against the chunk digest it was told, and can verify the
whole blob once assembled, but cannot verify that a _given_ chunk list is the
right decomposition of a given blob without reading all of it. The design
closes that gap with bao, and the documentation already reasons in terms of
logical 1 KiB BLAKE3 blocks versus physical FastCDC chunks, including the
`bao_shift` trimming trick the document attributes to `bao-tree`.

## What this validates (or refutes)

This catalog's [recommendations][rec] make two claims that Snix tests in
production. Both hold, with one caveat and one disagreement.

**Recommendation 1 — a Merkle tree identity internally, not NAR.** Validated,
and for the predicted reasons: granular substitution, seekable access, parallel
download, peer-to-peer substitution. Snix went further than the recommendation
by choosing BLAKE3 over SHA-1/SHA-256, which buys intra-file verification the
git-shaped option cannot.

**Recommendation 2 — `NarHash`/`NarSize` computed serially, on demand, at the
Nix boundary only.** Validated almost literally. NAR survives as _metadata on a
store path_, never as identity: `PathInfo` carries a castore `Entry` as the
content and a separate `NARInfo` message for Nix compatibility
([`pathinfo.proto`][pathinfo]):

```proto
message PathInfo {
  snix.castore.v1.Entry entry = 1;
  repeated bytes references = 2;
  NARInfo narinfo = 3;
}
```

whose `NARInfo` holds `nar_size`, `nar_sha256`, the `.narinfo` signatures, the
deriver and the `ca` field — and whose comment gives the precise reason the
field cannot simply be dropped:

> This is useful to render .narinfo files to clients, or to preserve/validate
> these signatures. As verifying these signatures requires the whole NAR file
> to be synthesized, moving to another signature scheme is desired. Even then,
> it still makes sense to hold this data, for old clients.

And the computation is exactly the recommended shape — render the NAR into a
sink, keep only the length and the SHA-256
([`narcalculationservice/mod.rs`][narcalc]):

```rust
let mut digester = Sha256Digester::new();
let mut nar_size = 0;
let writer = InspectWriter::new(tokio::io::sink(), |data| {
    nar_size += data.len() as u64;
    digester.update(data);
});
write_nar(writer, root_node, &self.blob_service, &self.directory_service).await?;
Ok((nar_size, digester.finalize().into()))
```

The doc comment states why it is retained at all: "This can be used to
calculate NAR-based output paths" — i.e. NAR hashing is not only a
compatibility nicety but an input to Nix's store-path derivation, so a
reimplementation cannot escape it even in principle. The component docs concede
the same: "In the case of NAR hash / NAR size, this data is strictly required
in some cases" ([`responsibilities.md`][responsibilities]).

**Caveat — the boundary is not free.** `NarCalculationService` is a _trait_ with
a rendering implementation, because rendering a NAR requires walking the whole
Merkle tree and streaming every blob. A remote `snix-store` can answer the
question instead of recomputing it, which is why the trait exists. The
recommendation's "the serial cost is irrelevant there because the bytes are
being streamed anyway" holds on ingest and does not hold when a cached
`PathInfo` is missing its `nar_sha256` — the right lesson is that `NarHash`
should be _stored_ alongside the Merkle identity, not merely recomputable.

**Disagreement — ordering.** The recommendation picks a git-shaped tree with
`gitTreeOrder`. Snix explicitly rejected git's encoding (quoted above) and took
REAPI's three-array partition instead. It gains what the [falsification
gate][gate-reapi] predicted — the `a` versus `a.b` ordering hazard cannot
arise — and loses the git oracle (`git write-tree`) that the recommendation
valued. This is a genuine fork in the road, and Snix took the other branch with
its reasons written down.

**Also worth flagging for the synthesis:** Snix independently derived
recommendation 7 (carry the length beside the digest) at _both_ levels, and
recommendation 9's `255`-byte name bound with the identical Linux rationale.

## Strengths

- **Identity is free of chunking policy.** A blob digest is BLAKE3 of the
  bytes, so chunking parameters can change, differ per backend, or be absent,
  without moving any identity — the property [casync][casync] and
  [IPFS unixfs][unixfs] both give up.
- **Verified streaming is reachable without a format change**, because BLAKE3 is
  already a tree hash; the protocol only needs to start shipping the outboard.
- **Interoperable blob addressing** — a plain BLAKE3 content hash is what
  [iroh][iroh] and other BLAKE3-addressed systems already speak, unlike git's
  `blob <len>\0` prefix.
- **Ordering hazards are structurally excluded** by partitioning entries into
  three arrays.
- **Canonicity is checked on ingest**, in both sort order and closure
  completeness, with typed errors (`WrongSorting`, `DuplicateName`,
  `DirectoriesMissing`, `WrongSize`).
- **Proof that the NAR boundary is tractable**: a full Nix reimplementation
  runs on a different identity and still renders `.narinfo` for existing
  clients.

## Weaknesses

- **Canonicity rests on deterministic protobuf serialization**, which the
  project itself flags as not guaranteed across implementations
  ([issue #111][issue111]).
- **The chunk list is not yet bound to the blob digest.** `bao` is reserved and
  unimplemented (`bao: "".into(), // still todo`), so today's partial reads are
  verified per chunk against server-supplied chunk digests, not against the
  blob root.
- **No algorithm agility.** BLAKE3-256 is wired in; there is no negotiation
  field, unlike [REAPI][reapi]'s seven digest functions.
- **NAR does not go away** — `nar_sha256` is required for Nix store-path
  computation and for validating existing signatures, so the serial format
  remains a permanent tax on the boundary.
- **A second addressing scheme to implement.** Interoperating with Nix means
  implementing both castore and NAR, and keeping their FSO models aligned.
- **`DirectoryEntry.size` has a compatibility wart**: older implementations
  counted directory elements twice, so a `compat-accept-bigger-sizes` feature
  exists to accept the historical upper bound.

## Key design decisions and trade-offs

| Decision                                                | Rationale                                                                                | Trade-off                                                                               |
| ------------------------------------------------------- | ---------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Merkle DAG of protobuf `Directory`s instead of NAR      | Granular substitution, seekable access, subtree dedup, parallel download                 | Two formats to maintain; NAR still required at the Nix boundary                         |
| Protobuf encoding rather than git's binary tree object  | Extensible, wide codec availability, unknown fields are detectable                       | Canonicity depends on deterministic protobuf serialization, which is not guaranteed     |
| Blob digest = plain BLAKE3 of raw contents              | Any BLAKE3-addressed system can serve the same blob; chunking cannot bleed into identity | Loses the free length/type binding git's `blob <len>\0` prefix provides                 |
| Three sorted arrays (files / directories / symlinks)    | A file and a directory never compare, so git's implicit-`/` hazard cannot arise          | A consumer wanting one listing merges three; diverges from git's order                  |
| BLAKE3 with no negotiation                              | One hash, a tree hash, chosen once                                                       | No migration path if BLAKE3 is ever retired                                             |
| FastCDC chunking below the identity layer               | Dedup and partial transfer without the chunking topology entering the root hash          | The chunk list is advisory and, until `bao` lands, not verifiable against the blob root |
| `size` on every directory edge                          | Inode allocation for the FUSE mount; truncation detection                                | Redundant state that must be checked (`WrongSize`), plus a historical double-count      |
| Keep `NARInfo` (size, sha256, signatures) on `PathInfo` | NAR hashing feeds Nix output-path computation, and old signatures must still verify      | The serial format never fully disappears; rendering it costs a full tree walk           |

## Sources

- [`web/content/docs/components/castore/data-model.md`][data-model] — the node
  and `Directory` model, the Merkle DAG framing, the protobuf caveat
  (also live at [snix.dev][data-model-live])
- [`web/content/docs/components/castore/why-not-git.md`][why-not-git] — the
  rejection of git's tree and blob encodings (also live at
  [snix.dev][why-not-git-live])
- [`web/content/docs/components/castore/blobstore-chunking.md`][chunking] —
  identity versus chunking, logical BLAKE3 blocks versus physical chunks
- [`web/content/docs/components/store/responsibilities.md`][responsibilities] —
  why NAR hash and size are "strictly required in some cases"
- [`snix/castore/protos/castore.proto`][proto] — `Directory`, `DirectoryEntry`,
  `FileEntry`, `SymlinkEntry`, the ordering and uniqueness rules
- [`snix/castore/protos/rpc_blobstore.proto`][rpc-blob] — `Stat`/`Read`/`Put`,
  `send_chunks`, `send_bao`
- [`snix/castore/src/proto/mod.rs`][proto-mod] — `Directory::digest`, the
  three sort checks
- [`snix/castore/src/nodes/mod.rs`][nodes-mod] — the `Node` enum
- [`snix/castore/src/nodes/directory.rs`][nodes-directory] — the `BTreeMap`
  producer, duplicate rejection, size arithmetic
- [`snix/castore/src/digests.rs`][digests] — `B3Digest`, the `blake3-` display form
- [`snix/castore/src/path/component.rs`][component] — `PathComponent`
  validation, `MAX_NAME_LEN`
- [`snix/castore/src/blobservice/object_store/mod.rs`][objstore] — FastCDC,
  chunk paths, chunk verification
- [`snix/castore/src/directoryservice/order_validator.rs`][order-validator] —
  ingest ordering and closure validation
- [`snix/store/protos/pathinfo.proto`][pathinfo] — `PathInfo`, `NARInfo`, `CA`
- [`snix/store/src/nar/narcalculationservice/mod.rs`][narcalc] — NAR rendered
  into a sink purely for size and SHA-256
- [`snix/store/README.md`][store-readme] — the granularity/compatibility trade

<!-- References -->

[nar]: ./nar.md
[reapi]: ./reapi.md
[bao]: ./bao-blake3.md
[casync]: ./casync.md
[unixfs]: ./ipfs-unixfs.md
[rec]: ./recommendations.md#recommendations-for-sparklesbuild-primitives
[gate-reapi]: ./recommendations.md#reapi-through-the-seam
[iroh]: ../iroh/index.md
[repo]: https://git.snix.dev/snix/snix/src/commit/86a6e6ef8c1c43d015b09f10051de78b2cae548b
[data-model]: https://git.snix.dev/snix/snix/src/commit/86a6e6ef8c1c43d015b09f10051de78b2cae548b/web/content/docs/components/castore/data-model.md
[data-model-live]: https://snix.dev/docs/components/castore/data-model/
[why-not-git]: https://git.snix.dev/snix/snix/src/commit/86a6e6ef8c1c43d015b09f10051de78b2cae548b/web/content/docs/components/castore/why-not-git.md
[why-not-git-live]: https://snix.dev/docs/components/castore/why-not-git/
[chunking]: https://git.snix.dev/snix/snix/src/commit/86a6e6ef8c1c43d015b09f10051de78b2cae548b/web/content/docs/components/castore/blobstore-chunking.md
[responsibilities]: https://git.snix.dev/snix/snix/src/commit/86a6e6ef8c1c43d015b09f10051de78b2cae548b/web/content/docs/components/store/responsibilities.md
[proto]: https://git.snix.dev/snix/snix/src/commit/86a6e6ef8c1c43d015b09f10051de78b2cae548b/snix/castore/protos/castore.proto
[rpc-blob]: https://git.snix.dev/snix/snix/src/commit/86a6e6ef8c1c43d015b09f10051de78b2cae548b/snix/castore/protos/rpc_blobstore.proto
[proto-mod]: https://git.snix.dev/snix/snix/src/commit/86a6e6ef8c1c43d015b09f10051de78b2cae548b/snix/castore/src/proto/mod.rs
[nodes-mod]: https://git.snix.dev/snix/snix/src/commit/86a6e6ef8c1c43d015b09f10051de78b2cae548b/snix/castore/src/nodes/mod.rs
[nodes-directory]: https://git.snix.dev/snix/snix/src/commit/86a6e6ef8c1c43d015b09f10051de78b2cae548b/snix/castore/src/nodes/directory.rs
[digests]: https://git.snix.dev/snix/snix/src/commit/86a6e6ef8c1c43d015b09f10051de78b2cae548b/snix/castore/src/digests.rs
[component]: https://git.snix.dev/snix/snix/src/commit/86a6e6ef8c1c43d015b09f10051de78b2cae548b/snix/castore/src/path/component.rs
[objstore]: https://git.snix.dev/snix/snix/src/commit/86a6e6ef8c1c43d015b09f10051de78b2cae548b/snix/castore/src/blobservice/object_store/mod.rs
[order-validator]: https://git.snix.dev/snix/snix/src/commit/86a6e6ef8c1c43d015b09f10051de78b2cae548b/snix/castore/src/directoryservice/order_validator.rs
[pathinfo]: https://git.snix.dev/snix/snix/src/commit/86a6e6ef8c1c43d015b09f10051de78b2cae548b/snix/store/protos/pathinfo.proto
[narcalc]: https://git.snix.dev/snix/snix/src/commit/86a6e6ef8c1c43d015b09f10051de78b2cae548b/snix/store/src/nar/narcalculationservice/mod.rs
[store-readme]: https://git.snix.dev/snix/snix/src/commit/86a6e6ef8c1c43d015b09f10051de78b2cae548b/snix/store/README.md
[issue111]: https://git.snix.dev/snix/snix/issues/111
