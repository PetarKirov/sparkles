# Concepts & vocabulary

The shared terms the deep-dives in this survey use. Each is defined once here
and grounded in at least one surveyed system; the deep-dives link back rather
than redefining.

---

## File system object (FSO)

The abstract value a content-addressing scheme serializes. Nix states the
minimal version most directly — a file system object is exactly one of a
**regular file** ("a possibly empty sequence of bytes for contents" plus "a
single boolean representing the executable permission"), a **directory**
("mapping of names to child file system objects"), or a **symbolic link** ("an
arbitrary string, known as the _target_")
([`store/file-system-object.md`][nix-fso]). Nix then says what is deliberately
absent:

> Nix does not encode any other file system notions such as hard links,
> permissions, timestamps, or other metadata.

Every system in this survey makes a version of that exclusion, and the
_differences_ between their exclusions are the first axis of the
[comparison][rec]. [git][git] keeps a four-value mode; [OSTree][ostree] keeps
uid, gid, mode and extended attributes but still discards timestamps;
[REAPI][reapi] is alone in carrying an `mtime`, and carries it as an optional
node property rather than as part of the node.

## Level 1 and level 2

Two nested trees, which this survey keeps strictly apart because a scheme can
be conventional at one level and exotic at the other:

- **Level 1 — the directory tree.** How named children compose into a
  directory, and directories into a root. [NAR][nar], [git trees][git],
  [REAPI `Directory`][reapi] and [OSTree dirtrees][ostree] all live here.
- **Level 2 — the intra-file tree.** How the bytes of one file become a
  digest. For most of the field this is trivial ("hash the whole blob"), but it
  is a real tree for [Bao/BLAKE3][bao], for IPFS's unixfs chunker, and — the
  finding that surprised this survey — for REAPI's [`SHA256TREE`][reapi].

[Venti][venti] settles the question of whether the levels _nest_: they do not.
Its directories are "a special file" of concatenated 40-byte `VtEntry`
structures, so its level-1 tree is an instance of its level-2 pointer tree with
a different block-type base — the same machine run twice, not one layer inside
another.

A scheme is a pair. Nix is _NAR × whole-blob_; git is _git-tree × whole-blob_;
iroh is _no level 1 at all_ (a bare blob) _× Bao_. The levels are independent,
not a hierarchy.

## Serial serialization vs Merkle DAG

Nix names the distinction precisely
([`file-system-object/content-address.md`][nix-ca]):

> The simplest method is to serialise the entire file system object tree into a
> single binary string, and then hash that binary string, yielding the content
> address.

against

> Another technique is that of a Merkle graph, where previously computed hashes
> are included in subsequent byte strings to be hashed. […] we can first hash
> (serialised) child file system objects, and then hash parent objects using the
> hashes of their children.

The consequence is the practical one this survey cares about. A **serial**
scheme (NAR) has no subtree value: nothing below the root can be hashed
independently, cached across runs, verified in isolation, or computed in
parallel. A **Merkle** scheme (git, REAPI, OSTree, Bao) gives every subtree its
own name, so a changed file rewrites one blob plus its ancestor chain, and
disjoint subtrees hash concurrently.

## Canonical form

The rule set that makes "two equivalent trees hash to the same value" true.
Every Merkle scheme in this survey states one; the requirements are strikingly
similar and the _orderings_ are not. REAPI calls the concept out by name
([`remote_execution.proto`][reapi-proto]):

> A `Directory` that obeys the restrictions is said to be in canonical form.

Nix's reason for having a bespoke archive format at all is the absence of such
a form in the obvious alternatives — TAR and ZIP "do not have a canonical
serialisation, meaning that given an FSO, there can be many different
serialisations", and "this would be bad because we use serialisation to compute
cryptographic hashes" ([`content-address.md`][nix-ca]).

## Entry ordering

The part of canonical form that differs most, and the one that cannot be
abstracted behind a single comparison function. Four distinct answers appear in
five systems — see the [ordering axis][rec-ordering] for the table and the
worked `a` versus `a.b` case that separates the first two.

## Digest, and whether size is part of it

A content address is "an opaque fixed-size digest" ([Nix][nix-ca]), but the
schemes disagree about what accompanies it. [REAPI][reapi]'s `Digest` is a hash
_and_ a `size_bytes`, and both travel everywhere a digest travels;
[iroh][bao]'s `Hash` is 32 raw bytes with the size carried separately in the
wire protocol and verified progressively; git and OSTree carry the hash alone.
Encoding differs again: hex for git and REAPI, Nix's own base-32 for store
paths, and multibase-tagged bytes in the IPFS family.

## Partial verification

Whether a consumer holding a root digest can validate a _fragment_ without
possessing the whole tree. Level-1 Merkle schemes give this at directory
granularity for free. Level-2 chunk trees extend it inside a file, which is what
[iroh][bao] is built on — a lying provider is "caught within one 16 KiB chunk
group". A serial scheme gives none of it: NAR must be hashed end to end.

## Identity versus provenance

Where the _context_ of a digest lives. A Merkle DAG deduplicates, which means it
deliberately erases the path and origin by which a subtree was reached — two
identical directories anywhere in the world are one object. [Software
Heritage][swh] hit this head-on: a citation needs to say _which_ repository and
_which_ path a file came from, and none of that is recoverable from the
identifier. Its answer is SWHID **qualifiers** (`origin`, `visit`, `anchor`,
`path`, `lines`), which sit _outside_ the hash and are unverifiable by
construction.

The rule generalizes: **record context beside the digest, never inside it.**
Putting provenance in the hash would destroy the dedup that made the digest
worth having.

## Parameterized digests

Most digests in this survey are a hash of a defined serialization, so two
implementations agree by construction. A growing minority are hashes of a
_descriptor_ that includes the parameters used, so the same bytes legitimately
produce different digests under different settings:

| Subject             | Parameter that changes the digest                                  |
| ------------------- | ------------------------------------------------------------------ |
| [fs-verity][cfs]    | hash algorithm, `block_size`, salt — all covered by the descriptor |
| [dm-verity][apk]    | on-disk version (salt prepended vs appended), block size           |
| [IPFS unixfs][ipfs] | chunker, chunk size, DAG layout, raw-leaves                        |
| [eStargz][estargz]  | the prefetch order chosen by a profiling run                       |

A parameterized digest is not comparable with a plain content hash, and often
not comparable with itself across settings. Treat "what parameters does this
digest cover" as a question to answer explicitly, not a detail.

## Who builds the tree

For a level-2 Merkle tree, _when_ it is constructed decides who pays and who can
verify. The field runs in one direction:

| Built by                                | Example                                                           | Consequence                                                          |
| --------------------------------------- | ----------------------------------------------------------------- | -------------------------------------------------------------------- |
| An offline tool, before distribution    | `veritysetup format` ([dm-verity][apk])                           | The verifier receives a root only                                    |
| The kernel, on demand                   | `FS_IOC_ENABLE_VERITY` ([fs-verity][cfs])                         | One full pass at enable time; `O(1)` digest afterwards               |
| The packager, shipped with the artifact | APK v4 `.apk.idsig` ([APK v4][apk]); iroh's outboard ([Bao][bao]) | The verifier can check a range **without ever hashing the artifact** |

Only the last removes the computation from the verifier, which is why a seam
should let a tree arrive **out of band** rather than assuming each consumer
recomputes one.

## Index versus tree

Two ways to make part of a blob verifiable, and they are not equivalent. A
**tree** ([Bao][bao], `SHA256TREE`) lets a 16 KiB range be checked against a
32-byte root with nothing else transmitted, because the geometry follows from
the length. An **index** ([eStargz and SOCI][estargz]) is a flat list of
per-chunk digests in a document that must be fetched _whole_ before any byte can
be checked — and whose own integrity hangs off an annotation or a side artifact.
The index gives depth-2 trust; the tree gives `O(log n)`.

## Terms this survey does _not_ use

- **Chunking strategy** (fixed-size, or content-defined via a rolling hash such
  as FastCDC) is a _policy for choosing level-2 boundaries_, not an addressing
  scheme. It is named where a subject uses one, never treated as a peer.
- **Merkleization of typed data** (Ethereum SSZ's `hash_tree_root` and
  relatives) addresses consensus objects, not file system objects, and is out of
  scope — it shares only the word "Merkle".

<!-- References -->

[venti]: ./venti.md
[swh]: ./software-heritage.md
[cfs]: ./composefs-fs-verity.md
[apk]: ./apk-dm-verity.md
[ipfs]: ./ipfs-unixfs.md
[estargz]: ./estargz-soci.md
[nar]: ./nar.md
[git]: ./git-objects.md
[ostree]: ./ostree.md
[reapi]: ./reapi.md
[bao]: ./bao-blake3.md
[rec]: ./recommendations.md
[rec-ordering]: ./recommendations.md#axis-2-entry-ordering
[nix-fso]: https://github.com/NixOS/nix/blob/1d8bdc1ee63246b591a8d77d0d481485cd09d438/doc/manual/source/store/file-system-object.md
[nix-ca]: https://github.com/NixOS/nix/blob/1d8bdc1ee63246b591a8d77d0d481485cd09d438/doc/manual/source/store/file-system-object/content-address.md
[reapi-proto]: https://github.com/bazelbuild/remote-apis/blob/76ddd98e1f92c0e2e71d0d3aa6906eca31754c03/build/bazel/remote/execution/v2/remote_execution.proto
