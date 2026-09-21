# casync / desync

The one system that applies content-defined chunking to a **canonical tree
serialization** — i.e. what [NAR][nar] plus CDC would actually look like.

|                   |                                                                                 |
| ----------------- | ------------------------------------------------------------------------------- |
| **Ecosystem**     | systemd ecosystem; [`desync`][desync] is a Go reimplementation                  |
| **Level 1**       | `catar` — a canonical, random-access tree serialization ("a more modern `tar`") |
| **Level 2**       | **content-defined chunks that cross file boundaries**                           |
| **Node model**    | POSIX-ish, with selectable feature flags                                        |
| **Digest**        | SHA-512/256 per chunk; an index lists chunk digests + sizes                     |
| **Artifacts**     | `.catar` (serialized tree), `.caibx`/`.caidx` (index), `.castr` (chunk store)   |
| **Documentation** | [`README.md`][readme], [`doc/casync.rst`][rst]                                  |

## Overview

### What it solves

Distributing many _related versions_ of a filesystem tree — OS images,
especially — so that storage and transfer cost scale with what changed rather
than with image size, without a per-file granularity that misses similarity
inside and across files.

### Design philosophy

The README states the pipeline plainly:

> Take a large linear data stream, split it into variable-sized chunks […]
> store these chunks in files in some directory, each file named after a strong
> hash value of its contents […] At the same time, generate a "chunk index"
> file that lists these chunk hash values plus their respective chunk sizes in
> a simple linear array. The chunking algorithm is supposed to create variable,
> but similarly sized chunks from the data stream, and do so in a way that the
> **same data results in the same chunks even if placed at varying offsets**.

and then adds the tree layer _on top_ of the byte layer:

> As an extra twist, we introduce a well-defined, **reproducible**,
> random-access serialization format for directory trees (think: a more modern
> `tar`), to permit efficient, stable storage of complete directory trees in
> the system, simply by serializing them and then passing them into the
> encoding step explained above.

The design's distinguishing choice is stated as a contrast with the tools it
would otherwise resemble:

> Why is this different from `rsync` or OSTree, or similar tools? Well, one
> major difference between `casync` and those tools is that we **remove file
> boundaries before chunking things up**. This means that small files are
> lumped together with their siblings and large files are chopped into pieces,
> which permits us to recognize similarities in files and directories beyond
> file boundaries.

## How it works

Three artifacts, cleanly separated:

| Artifact            | Is                                                       |
| ------------------- | -------------------------------------------------------- |
| `.catar`            | the tree, serialized canonically — the level-1 output    |
| `.caibx` / `.caidx` | the index: an ordered array of `(chunk digest, size)`    |
| `.castr`            | the chunk store: one file per chunk, named by its digest |

Reconstruction concatenates the indexed chunks; deduplication happens because
unrelated images sharing content share chunk files.

### Dimension 1 — node model

POSIX-oriented and, unusually, **negotiable**: casync carries explicit feature
flags for which metadata classes a given `catar` encodes, so the same tool can
produce a timestamp-free archive or a fully-faithful one. That makes it the
only subject here where the node model is a _parameter_ rather than a fixed
decision — the axis [OSTree][ostree] and [REAPI][reapi] answer statically.

### Dimension 2 — canonical form and ordering

The `catar` format is specified as reproducible and ordered, which is the whole
point of introducing it rather than reusing tar — the same objection
[NAR][nar] raises and [OCI][oci] did not resolve.

### Dimension 3 — level-1 composition

Serial, like [NAR][nar]: the tree becomes one byte stream with no subtree
digests. Sharing is recovered _below_ that layer, at chunk granularity, rather
than above it at subtree granularity — a genuinely different answer to the same
problem. The cost is that two trees differing only in a deep subdirectory share
chunks but have no shared _name_ for the unchanged part.

### Dimension 4 — level-2 granularity

Content-defined, variable-sized, and **spanning file boundaries** — the
strongest form of level 2 in the survey. Contrast [Bao][bao]'s fixed 1024-byte
chunks, chosen so geometry is derivable from length alone: casync gives up that
determinism and gains insertion-resilient dedup. Both choices are right for
their job, which is the clearest illustration available that chunking is a
_policy_, not a scheme.

### Dimension 5 — digest

Per-chunk strong hashes, listed with sizes in the index; the index itself is
the transferable identity.

### Dimension 6 — partial verification

Per chunk, and — because the index is a flat array with sizes — with random
access into the reconstructed stream.

## Strengths

- **Dedup across file boundaries**, catching similarity nothing file-granular
  can.
- A canonical tree format, unlike [OCI][oci].
- Random access into the serialized tree.
- Chunk store is trivially shareable over plain HTTP.
- The node model is a set of feature flags, not a fixed decision.

## Weaknesses

- **No subtree identity** — the level-1 layer is serial, so unchanged
  subdirectories have no name.
- An index per image and a chunk store to garbage-collect.
- CDC boundaries are a tuning problem; average chunk size trades dedup against
  index size.
- Effectively two formats (`catar` and the index) to implement.

## Key design decisions and trade-offs

| Decision                                | Rationale                                                                    | Trade-off                                                                   |
| --------------------------------------- | ---------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Invent `catar` rather than reuse tar    | tar has no reproducible serialization                                        | Another format to implement and stabilize                                   |
| Chunk **across** file boundaries        | Small files lump together; large files split; chunk sizes stay even          | A chunk is not attributable to one file; per-file operations need the index |
| Content-defined chunk boundaries        | "the same data results in the same chunks even if placed at varying offsets" | Geometry is not derivable from length, unlike [Bao][bao]                    |
| Serial level 1 plus chunk-level sharing | Dedup without per-directory objects                                          | No subtree digests, so no `O(depth)` invalidation                           |
| Feature flags for the node model        | One tool serves reproducible builds and faithful OS images                   | Two `catar`s of the same tree can legitimately differ                       |

## Sources

- [`README.md`][readme] — the pipeline, and the rsync/OSTree contrast
- [`doc/casync.rst`][rst] — the command surface and artifact types
- [`desync`][desync] — an independent Go implementation of the same formats

<!-- References -->

[nar]: ./nar.md
[oci]: ./oci-layers.md
[ostree]: ./ostree.md
[reapi]: ./reapi.md
[bao]: ./bao-blake3.md
[readme]: https://github.com/systemd/casync/blob/b4b7e5606f785572b78a43626a27a45fe3df2fbd/README.md
[rst]: https://github.com/systemd/casync/blob/b4b7e5606f785572b78a43626a27a45fe3df2fbd/doc/casync.rst
[desync]: https://github.com/folbricht/desync
