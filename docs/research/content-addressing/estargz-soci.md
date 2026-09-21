# eStargz and SOCI

What it costs to retrofit partial verification onto a format that has none: two
answers to the same problem, one that **changes the bytes so they become
seekable** and one that **leaves the bytes alone and ships a side index** —
and the second had to walk its own premise back.

|                    |                                                                                                                                         |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------------- |
| **Ecosystem**      | containerd remote snapshotters: `stargz-snapshotter`, `soci-snapshotter`; `zstd:chunked` in Podman/`containers/storage`                 |
| **Level 1**        | **unchanged** — still [OCI's][oci] chain of tar layers; neither adds a tree                                                             |
| **Level 2**        | eStargz: per-file gzip members plus optional chunks. SOCI: fixed-size **spans** of the compressed stream                                |
| **Node model**     | a second, authoritative copy of the tar header in a JSON **TOC** / flatbuffer **zTOC** — which overrides the tar                        |
| **Entry ordering** | eStargz: **prefetch order**, with landmark entries. SOCI/`zstd:chunked`: tar order, explicitly not to be relied on                      |
| **Digest**         | eStargz: `chunkDigest` over _uncompressed_ content. SOCI: `SpanDigests` over _compressed_ bytes                                         |
| **Specification**  | [`docs/estargz.md`][estargz-spec]; SOCI has no spec document — the format is its [`ztoc.go`][ztoc-go] and [`soci_index.go`][soci-index] |

> [!NOTE]
> This page covers only the addressing and verification layer. The FUSE
> filesystem, the snapshotter plugin protocol and the pull orchestration are
> out of scope; [`docs/pull-modes.md`][soci-pull-modes] is the entry point for
> those.

## Overview

### What it solves

Container startup is dominated by transferring bytes nobody reads. SOCI's
`README.md` states the measurement the whole subject rests on
([`README.md`][soci-readme]):

> Using a representative suite of images, Harter et al [FAST '16] found that
> image download accounts for 76% of container startup time, but on average
> only 6.4% of the fetched data is actually needed for the container to start
> doing useful work.

Fetching 6.4% of a layer requires exactly the two properties the
[OCI base model][oci-d6] lacks, and eStargz's specification names both
([`docs/estargz.md`][estargz-spec]):

> 1. The entire layer blob needs to be extracted even for getting a single file
>    entry.
> 2. Digests aren't provided for each file so it cannot be verified
>    independently.

Read against [concepts][concepts]: the first is a **level-2 granularity**
problem and the second is a **partial verification** problem. They are the same
two properties [Bao][bao] was designed around from the start — reached here
after the fact, by a format nobody is allowed to redesign.

### Design philosophy

Google's CRFS names the obstacle precisely, and then the trick that gets around
it ([CRFS `README.md`][crfs-readme]):

> container images are, somewhat regrettably, represented by _tar.gz_ files,
> and tar files are unindexed, and gzip streams are not seekable. […]
> Fortunately, we can fix the fact that _tar.gz_ files are unindexed and
> unseekable, while still making the file a valid _tar.gz_ file by taking
> advantage of the fact that two gzip streams can be concatenated and still be
> a valid gzip stream. So you can just make a tar file where each tar entry is
> its own gzip stream.

That is the whole of stargz: gzip's concatenation property is a **loophole in
the container format's own compression**, and the price is stated in the same
paragraph — "a few percent larger (due to more gzip headers and loss of
compression context between files)".

SOCI refuses to pay in bytes and pays in metadata instead
([SOCI `README.md`][soci-readme]):

> SOCI addresses these issues by loading from the original, unmodified OCI
> image. Instead of converting the image, it builds a separate index artifact
> (the "SOCI index"), which lives in the remote registry, right next to the
> image itself.

The rationale is not aesthetic. Conversion rewrites the layer bytes, so
the layer digest changes, so `DiffID`, `ChainID` and the manifest digest all
change — and, as SOCI's `README.md` notes, "the conversion step invalidates any
signatures that were created against the original OCI image."

## How it works

### eStargz: a layer that is its own index

The blob stays a valid `application/vnd.oci.image.layer.v1.tar+gzip`. Four gzip
header positions are mandated, and one is optional
([`docs/estargz.md`][estargz-spec]):

```
MUST: top of blob | top of each non-empty regular file payload
      | top of the TOC tar header | top of the footer
MAY:  arbitrary location within a regular file payload   (= a chunk)
```

The last tar entry is the **TOC**, a JSON file named `stargz.index.json`
holding one **`TOCEntry`** per tar entry _and per chunk_. A `TOCEntry` carries
`name`, `type`, `mode`, `uid`, `gid`, `modtime`, `xattrs`, `devMajor`/`Minor`,
plus the seek fields that make the format work: `offset` (the byte position of
that payload's gzip header in the blob), `chunkOffset`, `chunkSize`,
`innerOffset`, and the digests `digest` and `chunkDigest`.

The TOC is located by a **footer** — an empty gzip member whose RFC 1952 Extra
field spells the TOC's offset in hex:

```
22 bytes  Extra: subfield = fmt.Sprintf("%016xSTARGZ", offsetOfTOC)
```

Its length is the format's version marker. CRFS's stargz footer is **47
bytes** ([`stargz/stargz.go`][crfs-stargz]); eStargz's is **51**, because it
adds the `SI1`/`SI2`/`LEN` subfield header "to make it compliant to Extra field
definition in RFC1952" — a four-byte incompatibility taken deliberately, to be
_more_ standard rather than less.

A reader therefore does: range-request the last 51 bytes → parse the offset →
range-request the TOC → range-request individual `offset`/`chunkSize` windows.
Three round trips and no layer download.

**Ordering carries prefetch semantics.** eStargz splits the archive into
_prioritized_ and non-prioritized files, separated by a **landmark** entry — a
1-byte regular file named `.prefetch.landmark`, or `.no.prefetch.landmark` when
nothing is prioritized. The snapshotter prefetches everything before the
landmark "by a single HTTP Range Request". The optimizer derives the set by
running the image's own workload in a sandbox and recording accesses, then
places prioritized files "from the top of the archive, sorting them by the
accessed order".

### SOCI: an index that describes a layer it never touches

A **zTOC** ("a Table of Contents for compressed data") is two things
([`docs/glossary.md`][soci-glossary], [`ztoc.go`][ztoc-go]):

> (1). toc (`TOC`): a table of contents containing file metadata and its offset
> in the decompressed TAR archive. (2). zinfo (`CompressionInfo`): a collection
> of "checkpoints" of the state of the compression engine at various points in
> the layer.

The zinfo is the load-bearing half, and it is [zlib's `zran.c`][zran]
industrialized — [`gzip_zinfo.h`][gzip-zinfo-h] says so, and its checkpoint
record says what seeking into an unmodified DEFLATE stream actually costs:

```c
/* Since gzip is compressed with 32 KiB window size, WINDOW_SIZE is fixed */
#define WINSIZE 32768U

/*
    -  8 bytes, compressed offset
    -  8 bytes, uncompressed offset
    -  1 byte, bits
    -  32768 bytes, window
*/
#define PACKED_CHECKPOINT_SIZE (8 + 8 + 1 + WINSIZE)
```

Each checkpoint stores **the preceding 32 KiB of uncompressed output**, because
DEFLATE back-references may reach that far and the decompressor cannot be
started cold. A **span** is the region between checkpoints; the default span
size is `1 << 22` — 4 MiB ([`soci_index.go`][soci-index]) — so the zinfo costs
roughly `32785 / 4 Mi ≈ 0.78%` of the compressed layer, paid in the index
rather than in the layer.

The zTOC blobs and a **SOCI index manifest** form an OCI artifact that points
at the image through the `subject` field (`artifactType`
`application/vnd.amazon.soci.index.v1+json`), discovered at pull time through
the distribution spec's Referrers API. The layer's own digest is recorded in an
annotation, `com.amazon.soci.image-layer-digest`, and is unchanged: the pointer
runs index → image, never image → index.

**That direction is the design's central defect, and SOCI says so**
([`docs/soci-index-manifest-v2.md`][soci-v2]):

> The cost for the convenience of the referrers API is a weak, mutable
> reference between the SOCI index and the container image. Anyone with write
> access to the image registry can add or delete a SOCI index at any time which
> can affect the runtime characteristics of the associated image.

v2 reverses the arrow: "a lightweight image conversion step to package your
image and SOCI index into a single, strongly-linked, SOCI-enabled image", with
the image manifest carrying `com.amazon.soci.index-digest`. Note carefully what
does and does not change — v2 converts the **manifest**, while "the layers,
which make up the majority of the data in your images, are shared between a
SOCI-enabled image and the original image." SOCI gave up "no conversion"; it
did not give up "unmodified layer bytes".

### `zstd:chunked`: the same trick in a format that has a legal escape hatch

`containers/storage` plays eStargz's move with zstd, where RFC 8478
**skippable frames** make it clean: the TOC and a `tar-split` stream are
appended as frames a stock decoder ignores, located by a 64-byte footer and
the annotations `io.github.containers.zstd-chunked.manifest-position` /
`.tarsplit-position` ([`compression.go`][zstd-chunked]). The TOC is
deliberately CRFS-shaped — the manifest type constant is literally
`ManifestTypeCRFS = 1`.

Two departures matter. First, chunk boundaries are **content-defined**: regular
files become "a sequence of 'chunks' […] heuristically determined to increase
chance of chunk matching / reuse similar to rsync", with a `ChunkTypeZeros`
that stores holes as nothing. Second, it carries the `tar-split` data the
[OCI spec recommends][oci-tarsplit] as a frame inside the layer, so the
original tar can be replayed byte-for-byte — the `SHOULD` from `config.md`
promoted into the format.

### Dimension 1 — node model

A **second node model layered over tar's**, and the one that wins. eStargz's
`TOCEntry` carries the same fields the tar header does — `mode`, `uid`, `gid`,
`modtime`, `xattrs`, device numbers — plus `chunk` as a _node type_, which no
other subject in this survey has: a fragment of a file is a first-class entry.
SOCI's `FileMetadata` is the same shape with `TarHeaderOffset` added.

The duplication is resolved in the index's favour, explicitly. eStargz: "If
metadata in a TOCEntry of a file differs from the corresponding tar entry,
TOCEntry SHOULD be respected." `zstd:chunked` is blunter: "the metadata here
[…] is used instead of that in the tar stream. The contents of the tar stream
are not used in this scenario."

So the authoritative node model is now JSON (or a flatbuffer), while the digest
of record still covers the tar. Nothing forces the two to agree, and only
eStargz even states a precedence rule.

### Dimension 2 — canonical form and ordering

Still none, inherited unchanged from [OCI][oci-d2] — but the _reason_ order is
unspecified changes, and that is a new answer to this survey's
[ordering axis][axis2].

Everywhere else, entry order either is canonical (a rule that makes equal trees
hash equally) or is arbitrary. eStargz makes it **neither**: order is a
deliberate, workload-derived prefetch plan, with the landmark entry encoding
the boundary _in the archive itself_. Two eStargz blobs holding identical trees
optimized for different entrypoints differ in bytes and in digest, by design —
identity now depends on a profiling run.

SOCI and `zstd:chunked` decline the question: the latter's TOC documents that
ordering "currently defaults to being the same as that of the tar stream;
however, this should not be relied on."

### Dimension 3 — level-1 composition

**Unchanged, and this is the dimension neither project touches.** A layer is
still a tar changeset with `.wh.*` whiteouts, layers still compose as an
ordered chain, and `ChainID` is still a Merkle list. The TOC is a **flat array
of full path strings**, not a tree: there is no subtree digest, no `O(depth)`
rehash, no way to name a directory independently of the layer containing it.

The consequence is easy to miss because the ecosystem talks about these formats
as if they added a tree. They did not. They added a **level-2 index**, and left
level 1 exactly as [OCI layers][oci] found it — which is why a one-byte change
to one file still rewrites and re-digests the whole layer, and why an eStargz
image is still rebuilt, not patched.

### Dimension 4 — level-2 granularity

Three different boundary policies, and the differences are instructive:

| Format         | Boundary                                                        | Chosen by                                                        |
| -------------- | --------------------------------------------------------------- | ---------------------------------------------------------------- |
| eStargz        | a gzip member per non-empty regular file, optionally subdivided | **file semantics** — a chunk never spans two files               |
| SOCI           | a span of the compressed stream, default 4 MiB                  | **compressed offsets** — a span freely straddles file boundaries |
| `zstd:chunked` | a content-defined chunk within a file, plus `zeros` runs        | **a rolling checksum**, for cross-layer reuse                    |

eStargz's boundaries are semantic, so a fetch maps to a file and dedup happens
at file granularity. SOCI's are mechanical, so the index knows nothing about
what a span contains and a small file read may pull a 4 MiB span — the price
of not being allowed to move the data. eStargz's `innerOffset` is the
concession in the other direction: `--estargz-min-chunk-size` packs several
small payloads into one gzip member to stop the "few percent larger" from
becoming a lot, which trades back some of the seekability it just bought.

`zstd:chunked` is the only place in this survey where **content-defined
chunking** appears in a production addressing format rather than as the
boundary policy [concepts][concepts-cdc] describes in the abstract — and it is
there for cross-image dedup, not for verification.

### Dimension 5 — digest

Three digests for three purposes, and it matters which bytes each covers:

| Digest                | Over                                                                                                         | Committed to by                                                                   |
| --------------------- | ------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------- |
| eStargz `chunkDigest` | the **uncompressed** content of a `reg`/`chunk` entry                                                        | the TOC                                                                           |
| eStargz TOC digest    | the TOC file                                                                                                 | the `containerd.io/snapshot/stargz/toc.digest` annotation in the layer descriptor |
| SOCI `SpanDigests[i]` | the **compressed** bytes of span `i` ([`span_manager.go`][span-manager]: `digest.FromBytes(compressedData)`) | the zTOC blob's own descriptor digest                                             |

eStargz digests decompressed content, so a chunk verifies after inflation and
the check is meaningful about _data_. SOCI digests compressed bytes, so a span
verifies before inflation and the check is meaningful about _transport_ — it
catches a lying registry, but says nothing about whether the zinfo's window
correctly reconstructs the plaintext.

Note what is absent from both: **no digest of the tree**. There is no value
naming "the set of files this layer contains" other than the layer digest
itself, which is a digest of a tar archive with [no canonical form][oci-d2].

### Dimension 6 — partial verification

Present — that is the point of the subject — but at **depth two, not depth
log n**. The trust chain is a fixed three-step path:

```
verified manifest
  -> annotation / artifact descriptor  (digest of the whole TOC or zTOC)
  -> TOC                               (flat list of per-chunk digests)
  -> one chunk or span
```

Compare [Bao][bao-d6], where a consumer verifies a 16 KiB range against a
32-byte root with `O(log n)` interior nodes and **never fetches an index at
all** — geometry comes from the length. Here the index _is_ the proof, so:

- **You must download the whole TOC before verifying any byte.** For SOCI a
  zTOC additionally carries a 32 KiB window per span. There is no partial
  verification _of the index_.
- **The root of trust is an annotation, not a structure.** eStargz's chain
  holds only because `containerd.io/snapshot/stargz/toc.digest` sits in a
  descriptor inside an already-verified manifest. Drop the annotation and the
  TOC is unauthenticated — the layer digest alone cannot certify it, since
  verifying _that_ means downloading the blob, which is the thing being
  avoided.
- **SOCI v1's chain does not close at all.** The image manifest does not
  reference the index; the index references the image. A holder of the image
  digest has no way to know which index is legitimate — the "weak, mutable
  reference" quoted above — which is precisely why v2 exists.

## Strengths

- **Backward compatibility that actually holds.** An eStargz blob is a valid
  `tar.gz`; a `zstd:chunked` blob is a valid zstd stream. Unmodified registries
  store them and unmodified runtimes run them.
- **The first practical partial verification in the container ecosystem**, at
  chunk (eStargz) or span (SOCI) granularity.
- **SOCI leaves the layer digest, and therefore existing signatures, intact** —
  the only scheme here that adds seekability without changing identity.
- **eStargz encodes a prefetch plan in the archive**, collapsing cold-start
  fetch into one range request.
- **`zstd:chunked` carries `tar-split` in-band**, turning OCI's reproducibility
  `SHOULD` into a property of the blob.

## Weaknesses

- **Level 1 is untouched.** No subtree identity, no `O(depth)` rehash; a flat
  path list, not a tree.
- **Two node models, one digest.** The TOC overrides the tar it is packed
  beside, and nothing verifies that they agree.
- **The index must be fetched whole** before any chunk can be verified —
  unavoidable for a flat digest list, and worst for SOCI, whose zinfo is ~0.78%
  of the layer and mostly DEFLATE window state.
- **eStargz changes the layer bytes**, so digests change, signatures break, and
  the image exists in two formats; compression ratio drops because context is
  lost at every member boundary.
- **SOCI's span boundaries are blind to content**, so a 4 KiB read can cost a
  4 MiB fetch.
- **eStargz's identity depends on a profiling run** — optimizing for a
  different entrypoint produces a different digest for the same tree.
- **SOCI v1's trust link is mutable by anyone with registry write access**, by
  its maintainers' own statement.

## Key design decisions and trade-offs

| Decision                                                       | Rationale                                                            | Trade-off                                                                                           |
| -------------------------------------------------------------- | -------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| eStargz: one gzip member per file, exploiting concatenation    | Seekability inside a still-valid `tar.gz`                            | Layer bytes and digest change; images a few percent larger from lost compression context            |
| eStargz: TOC as the last tar entry, found via a 51-byte footer | Index travels inside the blob; three range requests to first byte    | The footer's length is the version marker, so stargz (47 bytes) and eStargz are not interchangeable |
| eStargz: `innerOffset` / `--estargz-min-chunk-size`            | Recovers compression ratio by packing small payloads into one member | Coarser seek granularity — partially undoes the split it depends on                                 |
| eStargz: entry order as a prefetch plan with landmarks         | One range request warms the whole working set                        | Order becomes workload-derived, so identity depends on a profiling run                              |
| SOCI: side index over an unmodified layer                      | Layer digest, `ChainID` and signatures survive; no CI/CD change      | The image does not commit to the index — a "weak, mutable reference"                                |
| SOCI: DEFLATE checkpoints (`zran.c`) instead of reformatting   | Seek into gzip nobody rewrote                                        | ~32 KiB of window state per span; ~0.78% of the layer, and useless to anything but SOCI             |
| SOCI: fixed 4 MiB spans over compressed offsets                | Independent of file layout; nothing in the layer must move           | Spans straddle files; small reads amplify                                                           |
| SOCI: digest the compressed span bytes                         | Verify before inflating; cheap                                       | Certifies transport, not the reconstruction                                                         |
| SOCI v2: convert the manifest, share the layers                | Strong, immutable image → index link                                 | The "no conversion" premise is retired; an extra image to manage                                    |
| `zstd:chunked`: skippable frames + in-band `tar-split`         | A sanctioned extension point; byte-exact tar replay                  | zstd only; TOC and tar can disagree, and the TOC wins                                               |

## Sources

- [`docs/estargz.md`][estargz-spec] — the eStargz specification: gzip member placement, TOC/`TOCEntry`, the 51-byte footer, landmarks, the verification chain, external TOC
- [CRFS `README.md`][crfs-readme] — the origin: why `tar.gz` is unseekable and how concatenated gzip streams fix it
- [`stargz/stargz.go`][crfs-stargz] — `TOCTarName`, the 47-byte stargz footer
- [SOCI `README.md`][soci-readme] — the Harter et al measurement, "no image conversion", the v2 caveat
- [`docs/glossary.md`][soci-glossary] — zTOC, zinfo, span, and the refusal of the term "SOCI image"
- [`ztoc/ztoc.go`][ztoc-go] — `Ztoc`, `CompressionInfo`, `SpanDigests`, `FileMetadata`
- [`ztoc/compression/gzip_zinfo.h`][gzip-zinfo-h] — `WINSIZE`, `PACKED_CHECKPOINT_SIZE`, the `zran.c` provenance
- [`ztoc/compression/zinfo.go`][zinfo-go] — the span/offset interface
- [`soci/soci_index.go`][soci-index] — artifact types, layer-digest annotation, `defaultSpanSize = 1 << 22`
- [`fs/span-manager/span_manager.go`][span-manager] — span digests computed over compressed bytes
- [`docs/soci-index-manifest-v2.md`][soci-v2] — the weak mutable reference, and the conversion step that replaces it
- [`pkg/chunked/internal/minimal/compression.go`][zstd-chunked] — the `zstd:chunked` TOC, skippable frames, `ManifestTypeCRFS`, content-defined chunks, `tar-split`

<!-- References -->

[oci]: ./oci-layers.md
[oci-d2]: ./oci-layers.md#dimension-2--canonical-form-and-ordering
[oci-d6]: ./oci-layers.md#dimension-6--partial-verification
[oci-tarsplit]: ./oci-layers.md#design-philosophy
[bao]: ./bao-blake3.md
[bao-d6]: ./bao-blake3.md#dimension-6--partial-verification
[concepts]: ./concepts.md
[concepts-cdc]: ./concepts.md#terms-this-survey-does-not-use
[axis2]: ./recommendations.md#axis-2--entry-ordering
[estargz-spec]: https://github.com/containerd/stargz-snapshotter/blob/624678b4e421947534cbf0618f9609853cccee0f/docs/estargz.md
[crfs-readme]: https://github.com/google/crfs/blob/71d77da419c90be7b05d12e59945ac7a8c94a543/README.md
[crfs-stargz]: https://github.com/google/crfs/blob/71d77da419c90be7b05d12e59945ac7a8c94a543/stargz/stargz.go
[soci-readme]: https://github.com/awslabs/soci-snapshotter/blob/0479e9dcfe3ccdb08dac117959d517ec6284cd14/README.md
[soci-glossary]: https://github.com/awslabs/soci-snapshotter/blob/0479e9dcfe3ccdb08dac117959d517ec6284cd14/docs/glossary.md
[soci-pull-modes]: https://github.com/awslabs/soci-snapshotter/blob/0479e9dcfe3ccdb08dac117959d517ec6284cd14/docs/pull-modes.md
[soci-v2]: https://github.com/awslabs/soci-snapshotter/blob/0479e9dcfe3ccdb08dac117959d517ec6284cd14/docs/soci-index-manifest-v2.md
[ztoc-go]: https://github.com/awslabs/soci-snapshotter/blob/0479e9dcfe3ccdb08dac117959d517ec6284cd14/ztoc/ztoc.go
[zinfo-go]: https://github.com/awslabs/soci-snapshotter/blob/0479e9dcfe3ccdb08dac117959d517ec6284cd14/ztoc/compression/zinfo.go
[gzip-zinfo-h]: https://github.com/awslabs/soci-snapshotter/blob/0479e9dcfe3ccdb08dac117959d517ec6284cd14/ztoc/compression/gzip_zinfo.h
[soci-index]: https://github.com/awslabs/soci-snapshotter/blob/0479e9dcfe3ccdb08dac117959d517ec6284cd14/soci/soci_index.go
[span-manager]: https://github.com/awslabs/soci-snapshotter/blob/0479e9dcfe3ccdb08dac117959d517ec6284cd14/fs/span-manager/span_manager.go
[zstd-chunked]: https://github.com/containers/storage/blob/83cf57466529353aced8f1803f2302698e0b5cb7/pkg/chunked/internal/minimal/compression.go
[zran]: https://github.com/madler/zlib/blob/767c4c947852e143f582c85f14cf573411df1b35/examples/zran.c
