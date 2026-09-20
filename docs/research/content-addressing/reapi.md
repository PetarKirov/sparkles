# Bazel Remote Execution API (REAPI)

The build-systems answer, and the survey's biggest surprise: a protocol whose
level-1 tree is conventional, and whose level-2 quietly grew a Merkle chunk
tree of its own.

|                    |                                                                                       |
| ------------------ | ------------------------------------------------------------------------------------- |
| **Ecosystem**      | Bazel, Buck2, Pants, BuildBarn, BuildGrid, `bazel-remote`                             |
| **Level 1**        | Merkle DAG of `Directory` protos, addressed by digest                                 |
| **Level 2**        | whole blob — **or `SHA256TREE`, a chunked Merkle hash**                               |
| **Node model**     | file (+ `is_executable`), directory, symlink; optional `NodeProperties` incl. `mtime` |
| **Entry ordering** | byte-wise (code point / UTF-8), **within three separate arrays**                      |
| **Digest**         | `{hash, size_bytes}` — the size is part of the identity                               |
| **Specification**  | [`remote_execution.proto`][proto]                                                     |

## Overview

### What it solves

Naming the exact input tree of a build action so a remote worker can
materialize it, and naming the output tree so results can be cached across
machines and organizations. Unlike every other subject here, the tree is a
_message_, not a byte stream: the canonical form is defined over protobuf
fields, and the digest is taken of the serialized message.

### Design philosophy

The canonical-form requirement is stated as an explicit contract with a named
term ([`remote_execution.proto`][proto]):

> In order to ensure that two equivalent directory trees hash to the same
> value, the following restrictions MUST be obeyed when constructing a
> `Directory`:
>
> - Every child in the directory must have a path of exactly one segment.
>   Multiple levels of directory hierarchy may not be collapsed.
> - Each child in the directory must have a unique path segment (file name).
> - The files, directories and symlinks in the directory must each be sorted
>   in lexicographical order by path. The path strings must be sorted by code
>   point, equivalently, by UTF-8 bytes.
> - The `NodeProperties` of files, directories, and symlinks must be sorted in
>   lexicographical order by property name.
>
> A `Directory` that obeys the restrictions is said to be in canonical form.

The same discipline is applied to `Platform.properties`, which "MUST be
lexicographically sorted by name, and then by value" — canonicity is treated as
a protocol-wide obligation, not a filesystem quirk.

## How it works

```protobuf
message Directory {
  repeated FileNode files = 1;
  repeated DirectoryNode directories = 2;
  repeated SymlinkNode symlinks = 3;
  NodeProperties node_properties = 5;
}

message Digest {
  string hash = 1;      // lowercase hex, zero-padded to the hash length
  int64 size_bytes = 2;
}
```

A `FileNode` is `{name, digest, is_executable, node_properties}`; a
`DirectoryNode` is `{name, digest}` where the digest names another `Directory`
message; a `SymlinkNode` is `{name, target}` with the target stored as a string
whose separator is `/` and which may be relative or absolute (absolute support
is negotiated through the Capabilities API).

### Dimension 1 — node model

The three FSO shapes plus an escape hatch. `is_executable` is a plain `bool` on
the file node, matching [NAR][nar] and [git][git]. What is unique here is
`NodeProperties`: an arbitrary sorted list of `{name, value}` strings **and an
`mtime`** — so REAPI is the only subject in this survey that can carry a
timestamp at all. It is opt-in, server-declared ("The server is responsible for
specifying the property `name`s that it accepts"), and the worked example in
the proto shows an `MTime` property with an ISO-8601 value.

That makes REAPI's node model _extensible_ where [OSTree's][ostree] is merely
_richer_: ownership, xattrs or anything else can ride as properties without a
schema change, at the cost of no two servers necessarily agreeing.

### Dimension 2 — canonical form and ordering

Byte-wise on UTF-8, applied **separately to each of the three arrays** — the
same structural escape [OSTree][ostree] takes with two, one step further. The
file-versus-directory ordering question [git][git] answers with an implicit `/`
cannot arise.

The **case-collision** question gets its third distinct answer in this survey,
and it is the most explicit:

> Note that while the API itself is case-sensitive, the environment where the
> Action is executed may or may not be case-sensitive. That is, it is legal to
> call the API with a Directory that has both "Foo" and "foo" as children, but
> the Action may be rejected by the remote system upon execution.

So: legal to _name_, possibly fatal to _use_, with the failure deferred to the
worker. Beside [NAR's][nar] name mangling and [git's][git] silence, that is the
full field.

### Dimension 3 — level-1 composition

A Merkle DAG by digest reference, with one wrinkle no other subject has: a
`Tree` message **flattens** the DAG for transport —

> All the child directories: the directories referred to by the root and,
> recursively, all its children. In order to reconstruct the directory tree,
> the client must take the digests of each of the child directories and then
> build up a tree starting from the `root`. Servers SHOULD ensure that these
> are ordered consistently such that two actions producing equivalent output
> directories on the same server implementation also produce `Tree` messages
> with matching digests.

Note the weakened obligation: `SHOULD`, and only _within_ one server
implementation. The flattened form is explicitly _not_ guaranteed canonical
across implementations, while `Directory` itself is — a useful illustration
that canonical form is a property you have to claim deliberately at each layer.

### Dimension 4 — level-2 content addressing

Ordinarily a whole-blob digest. But `DigestFunction` includes **`SHA256TREE`**,
"the SHA-256 digest function, modified to use a Merkle tree for large objects",
with two stated motives:

> This permits implementations to store large blobs as a decomposed sequence of
> 2^j sized chunks, where j >= 10, while being able to validate integrity at
> the chunk level.
>
> Furthermore, on systems that do not offer dedicated instructions for
> computing SHA-256 hashes […] `SHA256TREE` hashes can be computed more
> efficiently than plain SHA-256 hashes by using generic SIMD extensions, such
> as Intel AVX2 or ARM NEON.

Blobs of 1024 bytes or fewer use plain SHA-256; larger ones split into a left
half of length 2^k and a remainder, recurse, and combine the two child hashes
through a single SHA-256 block-cipher invocation with a distinct initial state.

This is the finding that generalizes: **an intra-file Merkle tree is not
exotic, and it is not confined to peer-to-peer systems.** It appears here for
exactly the reasons [Bao][bao] exists — chunk-level verification and
parallelism — inside a build protocol, alongside a conventional level-1 tree.
The same proto also lists `MD5` and a non-cryptographic `MURMUR3`, so the
digest function is genuinely a parameter, not a constant.

### Dimension 5 — digest

`{hash, size_bytes}`, and the size travels everywhere the hash does. Carrying
the length beside the digest is what lets a client allocate before fetching and
detect a truncated or inflated blob without hashing it — the same guard
[iroh][bao] implements as a "size honesty" check against its claimed size
header. Hash encoding is lowercase hex, zero-padded to the function's length.

### Dimension 6 — partial verification

At `Directory` granularity, and — with `SHA256TREE` — at chunk granularity
inside a blob.

## Strengths

- **Canonical form is specified, named, and normative**, including for
  non-filesystem messages.
- **Three sorted arrays** dodge the file-versus-directory ordering problem
  entirely.
- **Extensible metadata** via `NodeProperties` without changing the schema.
- **Digest carries size**, enabling cheap integrity and allocation decisions.
- **Pluggable digest functions**, including a chunked Merkle one.

## Weaknesses

- **Canonicity depends on protobuf serialization** being deterministic, a
  notoriously delicate property across implementations and versions.
- **`NodeProperties` are server-defined**, so two servers can disagree about
  what a tree even means.
- The flattened `Tree` message is only `SHOULD`-canonical, and only per server.
- Case collisions are deferred to execution rather than detected.
- Considerably more surface than the job needs if all you want is a digest.

## Key design decisions and trade-offs

| Decision                                      | Rationale                                                           | Trade-off                                                    |
| --------------------------------------------- | ------------------------------------------------------------------- | ------------------------------------------------------------ |
| Tree as a protobuf message, not a byte stream | Reuses an existing schema, transport and codegen                    | Canonicity now rests on deterministic protobuf serialization |
| Three separate sorted arrays                  | Files, directories and symlinks never compare against each other    | A consumer wanting one ordered listing must merge three      |
| `Digest` = hash **and** size                  | Cheap truncation detection and pre-allocation                       | Size must be tracked and propagated everywhere               |
| Optional `NodeProperties`, incl. `mtime`      | Real build inputs sometimes need metadata the model excludes        | Server-specific semantics; two servers may not agree         |
| `SHA256TREE` as a digest function             | Chunk-level verification, and SIMD parallelism SHA-256 cannot offer | A second hashing scheme to implement and negotiate           |
| Case collisions legal at the API              | The API cannot know the worker's filesystem                         | The failure lands at execution time, far from the cause      |

## Sources

- [`build/bazel/remote/execution/v2/remote_execution.proto`][proto] — `Directory`, `FileNode`, `DirectoryNode`, `SymlinkNode`, `Digest`, `Tree`, `DigestFunction`, `Platform`

<!-- References -->

[nar]: ./nar.md
[git]: ./git-objects.md
[ostree]: ./ostree.md
[bao]: ./bao-blake3.md
[proto]: https://github.com/bazelbuild/remote-apis/blob/76ddd98e1f92c0e2e71d0d3aa6906eca31754c03/build/bazel/remote/execution/v2/remote_execution.proto
