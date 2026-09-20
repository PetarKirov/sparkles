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

## Terms this survey does _not_ use

- **Chunking strategy** (fixed-size, or content-defined via a rolling hash such
  as FastCDC) is a _policy for choosing level-2 boundaries_, not an addressing
  scheme. It is named where a subject uses one, never treated as a peer.
- **Merkleization of typed data** (Ethereum SSZ's `hash_tree_root` and
  relatives) addresses consensus objects, not file system objects, and is out of
  scope — it shares only the word "Merkle".

<!-- References -->

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
