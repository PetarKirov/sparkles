# composefs + fs-verity

The digest as an **enforcement mechanism** rather than a name — and the only
subject here that hashes a file in constant time.

|                   |                                                                                                |
| ----------------- | ---------------------------------------------------------------------------------------------- |
| **Ecosystem**     | Linux kernel (`fs-verity`, ext4/f2fs/btrfs); composefs; OSTree; Android                        |
| **Level 1**       | an EROFS image describing the tree; content lives in a shared store                            |
| **Level 2**       | **a kernel-built, kernel-enforced Merkle tree over each file**                                 |
| **Node model**    | full POSIX, as an on-disk filesystem image                                                     |
| **Digest**        | the _fs-verity file digest_ — a hash of the descriptor, including the Merkle root              |
| **Documentation** | [`Documentation/filesystems/fsverity.rst`][fsverity], [OSTree `docs/composefs.md`][ostree-cfs] |

## Overview

### What it solves

Every other subject computes a digest by reading all the bytes. fs-verity
inverts that: the kernel builds the Merkle tree once at enable time, then
**verifies lazily, per block, on every read**, so obtaining the digest later is
free and corruption is caught at the moment it would be used. From the kernel
documentation ([`fsverity.rst`][fsverity]):

> After this, the file is made readonly, and all reads from the file are
> automatically verified against the file's Merkle tree. Reads of any corrupted
> data, including mmap reads, will fail.
>
> Userspace can use another ioctl to retrieve the root hash […] This ioctl
> executes in **constant time, regardless of the file size**.
>
> fs-verity is essentially a way to hash a file in constant time, subject to
> the caveat that reads which would violate the hash will fail at runtime.

That last sentence is the whole subject. It is the same structure as
[Bao][bao] — a Merkle tree over one file's blocks — with the verification moved
into the page-fault path instead of a network decoder.

### Design philosophy

composefs then builds the tree layer on top: an EROFS image holds the directory
structure and metadata, while file _contents_ are shared out of a backing
store, each named and verified by its fs-verity digest. OSTree's integration
makes the trust chain explicit ([`docs/composefs.md`][ostree-cfs]):

> if `composefs.enabled` is set to `signed` or `verity`, before the content of
> a file in the mounted composefs is read, the integrity of its backing OSTree
> object in `/ostree/repo/objects` is validated by the digest stored in
> `.ostree.cfs`.

and closes it with a signature over the _composefs digest itself_:

> This will inject the composefs digest as metadata into the ostree commit
> under a metadata key `ostree.composefs.v0`. Because an OSTree commit can be
> signed, this allows covering the composefs fsverity digest with a signature.

So: a signed commit names a composefs digest, which names per-file fs-verity
digests, which the kernel enforces per block. Three of this survey's subjects
chain into one boot-time integrity story.

## How it works

`FS_IOC_ENABLE_VERITY` takes the Merkle tree parameters — hash algorithm
(e.g. `FS_VERITY_HASH_ALG_SHA256`) and `block_size`, which "in Linux v6.3 and
later […] can be any power of 2 between 1024 and the page size" — builds the
tree, persists it, and makes the file immutable. `FS_IOC_MEASURE_VERITY`
returns a `struct fsverity_digest`.

The important subtlety for a content-addressing survey: the fs-verity file
digest is **not** the file's plain hash —

> a Merkle tree and is different from a traditional full-file digest.

It covers the descriptor (algorithm, block size, size, salt) as well as the
root, so it is not comparable with a `sha256sum`. Every other digest in this
survey is either a plain content hash or a defined serialization of one;
this one is a _parameterized_ digest, and two files with identical bytes get
different fs-verity digests under different block sizes.

### Dimensions

- **Node model** — full POSIX, because composefs is a real mountable
  filesystem; the richest in the survey, ahead of [OSTree][ostree].
- **Ordering** — an EROFS on-disk layout, not a byte-stream canonical form;
  reproducibility of the image is a property of the generator.
- **Level 1** — a filesystem image referencing a shared content store, i.e.
  structure and content separated exactly as [OSTree][ostree] separates
  `dirtree` from content objects.
- **Level 2** — the Merkle tree, built by the kernel, block size configurable.
- **Digest** — parameterized, descriptor-covering; retrievable in constant
  time.
- **Partial verification** — per block, on read, mandatory rather than
  optional.

## Strengths

- **Verification is not a step anyone can skip** — it happens under `read()`
  and `mmap()`.
- **Constant-time digest retrieval**, regardless of file size.
- Composes into a signed chain: signature → commit → composefs digest →
  per-file digest → block.
- Built-in signature support in the kernel for the descriptor.

## Weaknesses

- **Linux-only, filesystem-specific** (ext4, f2fs, btrfs), and needs privilege
  to enable.
- **Files become read-only** — this is an artifact-distribution mechanism, not
  a working-tree one.
- The digest is **parameterized**, so it is not comparable across block sizes
  and not comparable to a plain hash.
- OSTree's integration is still marked experimental.

## Key design decisions and trade-offs

| Decision                                                     | Rationale                                                            | Trade-off                                                                |
| ------------------------------------------------------------ | -------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| Build the Merkle tree in the kernel at enable time           | Digest retrieval becomes `O(1)`; verification lands in the read path | The file must become immutable, and enabling costs a full pass           |
| Verify per block on read                                     | Corruption is caught where it is used, including `mmap`              | Failures surface as `EIO` at arbitrary points, far from any hashing call |
| Digest covers the descriptor, not just the root              | Block size and salt cannot be swapped underneath a signature         | Not comparable with `sha256sum` or any other subject's digest            |
| Separate structure (EROFS image) from content (shared store) | Files dedup across images; the image stays small                     | Two artifacts plus a store to keep consistent                            |
| Sign the composefs digest inside the commit                  | One signature covers the whole tree's integrity                      | Ties the format to a signing scheme and a boot-time policy               |

## Sources

- [`Documentation/filesystems/fsverity.rst`][fsverity] — the Merkle tree, the ioctls, the constant-time claim
- [OSTree `docs/composefs.md`][ostree-cfs] — `signed`/`verity` modes, `ostree.composefs.v0`, the signature chain

<!-- References -->

[bao]: ./bao-blake3.md
[ostree]: ./ostree.md
[fsverity]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/Documentation/filesystems/fsverity.rst
[ostree-cfs]: https://github.com/ostreedev/ostree/blob/1d5a312a3189b0fbd70fe6769aadb19a366fedb2/docs/composefs.md
