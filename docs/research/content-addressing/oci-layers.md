# OCI image layers

The survey's counter-example: an ecosystem-scale content-addressing scheme
built on a serialization format that has **no canonical form** — exactly the
failure [NAR][nar] was invented to avoid.

|                    |                                                                                       |
| ------------------ | ------------------------------------------------------------------------------------- |
| **Ecosystem**      | Docker, containerd, Podman, every container registry                                  |
| **Level 1**        | an ordered **chain** of tar layers, not a tree                                        |
| **Level 2**        | whole tar archive, compressed or not                                                  |
| **Node model**     | POSIX tar — modes, uid/gid, **mtime**, hardlinks, plus `.wh.*` whiteouts              |
| **Entry ordering** | **unspecified** — whatever the producer's tar emitted                                 |
| **Digest**         | `sha256:<hex>`, with `DiffID` / layer digest / `ChainID` as three distinct identities |
| **Specification**  | [`config.md`][oci-config], [`layer.md`][oci-layer]                                    |

## Overview

### What it solves

Naming, transferring and deduplicating filesystem _changesets_, so an image is
a base plus deltas and a registry stores each delta once.

### Design philosophy

Unlike every other subject here, OCI did not define a serialization — it
adopted tar, and then had to add rules around it. The consequence is visible in
the specification's own hedging ([`config.md`][oci-config]):

> A layer DiffID is the digest over the layer's uncompressed tar archive […]
> Layers **SHOULD** be packed and unpacked reproducibly to avoid changing the
> layer DiffID, for example by using [tar-split][] to save the tar headers.

Read that twice. The identity of a layer depends on byte-level details of a tar
archive that the format does not canonicalize, so the recommended mitigation is
to **save the original tar headers alongside the content** and replay them —
because regenerating them is not guaranteed to reproduce the same bytes. Every
Merkle scheme in this survey defines a canonical form precisely so that step is
unnecessary.

## How it works

Three identities, which are routinely confused:

| Identity         | Digest over                                                     | Used for                                                   |
| ---------------- | --------------------------------------------------------------- | ---------------------------------------------------------- |
| **layer digest** | the layer blob **as stored** (usually gzip- or zstd-compressed) | registry addressing, the manifest                          |
| **`DiffID`**     | the layer's **uncompressed** tar archive                        | the image config's `rootfs.diff_ids`                       |
| **`ChainID`**    | a recursion over `DiffID`s                                      | identifying the _result_ of applying a prefix of the stack |

The `ChainID` recursion is the closest thing OCI has to a Merkle structure
([`config.md`][oci-config]):

```
ChainID(L₀) =  DiffID(L₀)
ChainID(L₀|...|Lₙ₋₁|Lₙ) = Digest(ChainID(L₀|...|Lₙ₋₁) + " " + DiffID(Lₙ))
```

> While a layer's `DiffID` identifies a single changeset, the `ChainID`
> identifies the subsequent application of those changesets.

### Dimension 1 — node model

Whatever tar carries: mode bits, uid/gid, **mtime**, device nodes, hardlinks.
This is the richest node model in the survey and the least disciplined — the
fields that [Nix][nar] and [OSTree][ostree] exclude _because they vary between
machines_ are all inside the digest here. Plus a model no one else has:
**whiteouts** (`.wh.<name>` entries) encoding deletion, which only make sense
because a layer is a diff rather than a tree.

### Dimension 2 — canonical form and ordering

There is none. Tar entry order is the producer's, padding and header field
encodings vary between implementations (GNU versus pax versus ustar), and
mtimes are recorded verbatim. Two builders producing byte-identical trees
routinely produce different `DiffID`s. This is the single strongest empirical
argument for the position [NAR's own rationale][nix-ca] states in the abstract.

### Dimension 3 — level-1 composition

A **chain**, not a tree: layers apply in order, later layers shadowing earlier
ones. `ChainID` is a Merkle _list_, so a change in layer _k_ invalidates every
`ChainID` from _k_ onward — `O(n)` in the layer count rather than
[git's][git] `O(depth)` in the tree.

### Dimension 4 — level-2 granularity

Whole archive. Partial fetch was retrofitted later by
[seekable layer formats][estargz], which are a separate subject precisely
because they are not part of the base model.

### Dimension 5 — digest

`sha256:<hex>` in the descriptor form, algorithm-tagged (so more agile than
[git][git], less than multicodec). The **same layer has two different digests**
depending on whether you mean the stored blob or the uncompressed tar, which is
a recurring source of bugs.

### Dimension 6 — partial verification

None in the base model: a layer is verified after the whole blob arrives.

## Strengths

- **Enormous deployment**, with a registry ecosystem that works.
- `ChainID` gives a principled identity for "the result of applying these
  layers", which a naive list of digests does not.
- Algorithm-tagged digests.
- Layers as diffs make incremental _distribution_ cheap even without a tree.

## Weaknesses

- **No canonical form.** Identity depends on producer-specific tar encoding,
  mitigated by preserving the original headers rather than by specification.
- **Timestamps and ownership inside the digest**, so identical trees built
  twice differ.
- `O(n)` chain invalidation instead of `O(depth)` tree invalidation.
- Three identities for one layer.
- No partial verification without a separate format.

## Key design decisions and trade-offs

| Decision                                                        | Rationale                                           | Trade-off                                                              |
| --------------------------------------------------------------- | --------------------------------------------------- | ---------------------------------------------------------------------- |
| Reuse tar rather than define a format                           | Universal tooling; layers are ordinary archives     | No canonical serialization — the exact failure NAR exists to prevent   |
| Layers as ordered diffs, with whiteouts                         | Incremental distribution without a tree             | A chain, not a tree: `O(n)` invalidation and order-dependent semantics |
| Separate `DiffID` from the stored blob digest                   | Compression must not change the identity of content | Two digests per layer, routinely confused                              |
| `ChainID` as a Merkle list                                      | Names the _result_ of applying a prefix             | Recomputed for every layer after a change                              |
| Reproducibility as a `SHOULD`, with `tar-split` as the fallback | Cannot retrofit canonicity onto tar                 | Producers must store headers to reproduce their own digests            |

## Sources

- [`config.md`][oci-config] — `DiffID`, `ChainID`, the `tar-split` recommendation
- [`layer.md`][oci-layer] — layer changesets, whiteouts, the tar fields carried

<!-- References -->

[nar]: ./nar.md
[git]: ./git-objects.md
[ostree]: ./ostree.md
[estargz]: ./estargz-soci.md
[nix-ca]: https://github.com/NixOS/nix/blob/1d8bdc1ee63246b591a8d77d0d481485cd09d438/doc/manual/source/store/file-system-object/content-address.md
[oci-config]: https://github.com/opencontainers/image-spec/blob/af26a05fba5ee648512f4ea3c9fda1fcc1b6d6dc/config.md
[oci-layer]: https://github.com/opencontainers/image-spec/blob/af26a05fba5ee648512f4ea3c9fda1fcc1b6d6dc/layer.md
[tar-split]: https://github.com/vbatts/tar-split
