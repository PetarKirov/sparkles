# Hypercore (JavaScript / Bare)

A sparse authenticated log whose flat-tree forest, size-aware hashes and signed heads support independently verified block replication.

| Metadata          | Value                                                              |
| ----------------- | ------------------------------------------------------------------ |
| Language          | JavaScript, Node.js and Bare                                       |
| License           | MIT                                                                |
| Repository        | [`holepunchto/hypercore`][repo]; [`hypercore-crypto`][crypto-repo] |
| Documentation     | [Hypercore README/API][readme]; [tree implementation][tree]        |
| Category          | Signed append-oriented log and sparse authenticated block access   |
| Hypercore pin     | `9c9cc3d8937b6ae539fbacf52a7090cd732a1945`, package 11.39.0        |
| Crypto pin        | `e2e0fdcc2521027ee49c58d50d60c42edb9466a0`                         |
| Identity boundary | Manifest-derived log key versus signed tree head versus block hash |

## Overview

### What it solves

A reader should be able to fetch selected blocks of a writer's log and
verify them without downloading the entire prefix. It also needs to learn
that the writer has extended the log, without trusting the relay supplying
the update. Hypercore combines a Merkle forest with signatures and sparse
storage to solve those problems ([README][readme], [tree code][tree]).

This is not a generic serializer for the block contents. A block can carry
JSON, UTF-8 or application binary bytes; changing that application codec
changes the committed bytes. The Merkle machinery supplies integrity and
positions, not a schema for values inside the blocks.

### Design philosophy

The [README][readme] states:

> Hypercore is a secure, distributed append-only log.

Its feature list qualifies the replication boundary:

> **Sparse replication.** Only download the data you are interested in.

The surveyed implementation also supports truncation and forks. Thus
“append-only” describes the normal log model, not a promise that a writer
can never authorize a replacement suffix. Fork and length are authenticated
parts of a head ([signable context][caps]).

## How it works

Leaf `i` occupies flat-tree index `2*i`. Internal nodes occupy the odd
positions between their descendant leaves. A complete subtree over the
first four blocks has root index 3; a fifth block is a separate root at 8.
Appending merges adjacent equal-height roots like a binary carry
([tree implementation][tree]).

```text
four blocks:          five blocks:
       3                     3       8
    /     \               /     \
   1       5             1       5
  / \     / \           / \     / \
 0   2   4   6         0   2   4   6
```

The forest roots cover the populated prefix without zero-padding to a
larger complete tree. Each stored node has an index, subtree byte size and
hash. These are protocol tree positions, not native byte offsets in an
application file.

### Schema source of truth

[`lib/messages.js`][messages] defines the internal compact encodings for
manifests and protocol structures. [`lib/caps.js`][caps] defines signed
context construction. [`hypercore-crypto/index.js`][crypto] defines the
leaf, parent and forest hashes. All three matter to interoperability;
the application block codec alone does not describe an authenticated log.

Application values use a selected `valueEncoding` or caller-supplied codec.
The tree sees bytes, not a reflected schema of those values. A JSON schema
or serialization library can validate a block after authentication, but
that is a separate [model/representation boundary][serde].

### Wire encoding

Internal messages use [`compact-encoding` through source definitions][messages],
with explicit flags, integers, fixed-width digests and arrays. A tree node
contains an integer index, integer size and 32-byte hash; proof messages
identify optional block, seek, hash and upgrade components. The precise
wire fields must come from the pinned source, not historical protobuf
descriptions of older Hypercore protocols.

Hash preimages use `c.uint64` for size/index words, rather than the generic
variable-width `c.uint` used for many message fields. In the equations below
`U64(x)` means that fixed-width, eight-byte little-endian representation
([`uint64` implementation][compact]).
Do not substitute a protobuf varint or an ASCII decimal length.

The signature context is a fixed 112-byte structure for the modern path:
32-byte `TREE` namespace, 32-byte manifest context, 32-byte forest hash,
64-bit block count and 64-bit fork number ([`treeSignable`][caps]).

### Access model

`get(index)` retrieves one block, possibly waiting for replication. A
Merkle path can establish that block under a known head while siblings
remain unavailable as raw blocks. The storage engine keeps tree metadata
separately from application payloads ([API][readme], [tree][tree]).

Byte seeking uses authenticated subtree **sizes** to navigate to the block
containing a byte position. This differs from SSZ's field generalized
indices and from a fixed-layout reader's direct loads. The proof machinery
can include both a seek and an upgrade; a bare block checksum is not the
whole access protocol.

### Variable-length and optional data

Blocks have variable byte sizes. Parent nodes sum their children's sizes,
and the forest tracks total byte length independently of block count.
Identical concatenated bytes split into different block boundaries do not
therefore have one guaranteed tree identity ([hash primitives][crypto]).

Internal optional proof sections are controlled by message flags and request
context; absence does not mean an application null value. Optional fields
inside a user's JSON or binary block are governed by that block codec.
There is no global Hypercore schema-evolution rule for them.

### Evolution and compatibility

Use the package manifest to identify the inspected implementation: it says
11.39.0, while the README retains wording calling version 10 the latest
release. That stale wording is not a release-status oracle. The README's
warning that version 10 is incompatible with version 9 and earlier is
historical context, not proof that every later mode is interchangeable
([manifest][package], [README][readme]).

The verifier distinguishes compatibility mode and manifest versions. It
also handles modern multisignature/quorum policies and optional prologues.
For manifest version zero, the signer uses its namespace as the context;
for later versions it uses the manifest hash. Legacy signing paths have
different context layouts ([`verifier.js`][verifier], [`caps.js`][caps]).

These branches are why a generic statement that “Hypercore signs its Merkle
root with the log public key” is incomplete. A migration or verifier must
pin manifest interpretation, signed context and signature aggregation,
not just BLAKE2b and Ed25519.

### Determinism and canonical form

At a fixed protocol version, forest order, flat indices, sizes and exact
block bytes determine the tree hash. The parent helper orders its children
by index before hashing. `crypto.tree`, however, hashes the supplied root
sequence in order; callers must provide the canonical forest ordering
([crypto primitives][crypto]).

This determinism does not normalize application values. Two JSON serializers
can produce different block hashes for equal decoded objects. Encryption
and application encoding introduce additional representation boundaries;
the tree authenticates the bytes passed into its append path, not an
abstract original document or its build inputs.

### Merkleization and content addressing

Let `B` be BLAKE2b with a 32-byte digest as used by sodium's generic hash.
The [crypto implementation][crypto] defines three distinct domains:

```text
leaf(data) = B(00 || U64(byteLength(data)) || data)
parent(a,b) = B(01 || U64(a.size+b.size) || a.hash || b.hash)
forest(roots) = B(02 || concat(root.hash || U64(root.index) || U64(root.size)))
```

The sizes are byte counts, while the signed head's `length` is a block
count. Flat indices and byte sizes occur in the forest preimage; length
and fork occur in the signed context. This is not SSZ's zero-padding and
length-mix-in construction, and not CometBFT's SHA-256 RFC 6962 tree.

For five blocks the signed forest hash aggregates two roots: index 3
covering blocks 0–3, then index 8 covering block 4. A proof of block 0
requires its path within the first subtree and enough head/upgrade context
to authenticate the relevant forest. It does not need every other block's
payload ([proof generation][tree]).

The log's public `key` is generally a manifest-derived identifier. It is
not the content hash of the latest log prefix; the same log key can name
many successive signed heads. Conversely, a forest hash alone does not
identify the authorized writers. The [verifier][verifier] binds that hash
to manifest policy, count and fork through signature verification.

An inclusion proof establishes a block and position under an authenticated
head. It does not prove that the writer has never equivocated, that a head
is globally freshest, or that the block's application record is valid.
These are separate protocol/application responsibilities. See the existing
[content-addressing recommendations][recommendations] for the identity
versus authenticity distinction.

### Hostile-input safety

[`NodeQueue`][tree] checks that supplied proof nodes appear at expected
indices. Tree verification recomputes parents and rejects missing,
inconsistent or invalid checksums. Signature verification checks signature
and public-key widths in [`hypercore-crypto`][crypto]; manifest verification
checks supported signature algorithms and quorum/signers ([verifier][verifier]).

Maintain size/index bounds, allocation limits and request/proof budgets
independently of cryptographic verification. A validly signed large or
deeply structured application block can still exhaust its application
decoder. Authenticated subtree byte sizes also need validation before they
can safely guide local byte-offset arithmetic.

### Describing foreign formats

Not applicable as a general arbitrary-layout description system. The
internal compact encoders describe Hypercore's own metadata. User blocks
can store a foreign format, but offsets and endian fields inside that
format require a separate parser.

For the [Flat draft][flat], Hypercore demonstrates the additional protocol
required to make partial authentication real: explicit tree positions,
size-aware domain-separated preimages, proof encoding and an authenticated
root context. A Flat arena's opaque input key supplies none of these by
itself. Keeping I/O ownership outside the layout reader also remains a
separate concern from sparse replication.

### Implementation and performance evidence

**Runnable independent hash-preimage framing check, not Hypercore execution.**
This checks domain bytes, fixed-width sizes and the leaf/parent/forest
preimage extents. It does not implement BLAKE2b, signatures or proof checking.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "research_hypercore_preimage_framing"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : writeln;

ubyte[8] word(ulong n) @safe pure nothrow @nogc
{
    ubyte[8] result;
    foreach (i; 0 .. 8) result[i] = cast(ubyte) (n >> (8 * i));
    return result;
}

void main() @safe
{
    ubyte[] leaf = [0];
    const size = word(11);
    leaf ~= size[];
    foreach (ch; "hello world") leaf ~= cast(ubyte) ch;
    ubyte[] parent = [1];
    const combined = word(22);
    parent ~= combined[];
    parent.length += 64; // two digest-width placeholders
    assert(leaf.length == 20 && parent.length == 73);
    assert(leaf[1] == 11 && parent[1] == 22);
    assert(1 + 2 * (32 + 8 + 8) == 97); // two-root forest preimage
    writeln("leaf/parent/two-root forest preimage bytes: 20 / 73 / 97");
}
```

```ansi
leaf/parent/two-root forest preimage bytes: 20 / 73 / 97
```

**Source test vectors, not local execution.** The pinned
[`hypercore-crypto/test.js`][crypto-tests] provides these exact fixtures:

```text
data = UTF-8 bytes of "hello world" (11 bytes)
leaf = 9f1b578fd57a4df015493d2886aec9600eef913c3bb009768c7f0fb875996308
parent of equal leaves at indices 0 and 2, size 11 each:
       3ad0c9b58b771d1b7707e1430f37c23a23dd46e0c7c3ab9c16f79d25f7c36804
```

The same test file hashes roots `(index=3,size=11,hash=ZERO32)` and
`(index=9,size=2,hash=ZERO32)` to:

```text
0e576a56b478cddb6ffebab8c494532b6de009466b2e9f7af9143fc54b9eaa36
```

The [Merkle tests][tree-tests] additionally assert concrete proof-node
indices: requesting block 4 in a ten-block tree with two nodes yields
`[10,13]`; the upgrade fixture adds node 3 in that block path. These are
precise layout/proof fixtures rather than invented diagrams alone.

No D port or binding was verified in this survey.
No local npm install, native sodium build, replication run or benchmark was
performed. The package's sparse APIs and source tests establish mechanisms,
not measured throughput, memory use or network savings for a Flat workload.

## Strengths

- Sparse verification operates at explicit block boundaries.
- Size-aware hashing supports byte seeking as well as block indexing.
- Signed heads bind sequence extent and fork context, not merely a digest.

## Weaknesses

- Log identity, tree identity and manifest/signature versions require care.
- Application values have no canonical encoding imposed by the log.
- Writer signatures do not by themselves prove freshness or non-equivocation.

## Key design decisions and trade-offs

| Decision                              | Rationale                            | Trade-off                                     |
| ------------------------------------- | ------------------------------------ | --------------------------------------------- |
| Flat indexed forest                   | Incremental append and sparse proofs | Multiple roots and upgrade-proof machinery    |
| Commit subtree sizes                  | Authenticate byte seeking            | More metadata in hash preimages               |
| Separate leaf/parent/forest domains   | Bind structural role                 | Not interchangeable with generic blob hashes  |
| Sign manifest context, count and fork | Bind writer policy and head identity | Versioned compatibility and aggregation logic |

## Sources

- [README][readme], [package manifest][package] and [message codecs][messages].
- [Tree/proof implementation][tree], [signed context][caps] and [verifier][verifier].
- [Crypto primitives][crypto], [crypto vectors][crypto-tests] and [tree tests][tree-tests].
- The [fixed-width integer encoder][compact] used in hash preimages.
- [Shared concepts][concepts] and [comparison][comparison].

<!-- References -->

[repo]: https://github.com/holepunchto/hypercore/tree/9c9cc3d8937b6ae539fbacf52a7090cd732a1945
[readme]: https://github.com/holepunchto/hypercore/blob/9c9cc3d8937b6ae539fbacf52a7090cd732a1945/README.md
[package]: https://github.com/holepunchto/hypercore/blob/9c9cc3d8937b6ae539fbacf52a7090cd732a1945/package.json
[messages]: https://github.com/holepunchto/hypercore/blob/9c9cc3d8937b6ae539fbacf52a7090cd732a1945/lib/messages.js
[tree]: https://github.com/holepunchto/hypercore/blob/9c9cc3d8937b6ae539fbacf52a7090cd732a1945/lib/merkle-tree.js
[caps]: https://github.com/holepunchto/hypercore/blob/9c9cc3d8937b6ae539fbacf52a7090cd732a1945/lib/caps.js
[verifier]: https://github.com/holepunchto/hypercore/blob/9c9cc3d8937b6ae539fbacf52a7090cd732a1945/lib/verifier.js
[tree-tests]: https://github.com/holepunchto/hypercore/blob/9c9cc3d8937b6ae539fbacf52a7090cd732a1945/test/merkle-tree.js
[crypto-repo]: https://github.com/holepunchto/hypercore-crypto/tree/e2e0fdcc2521027ee49c58d50d60c42edb9466a0
[crypto]: https://github.com/holepunchto/hypercore-crypto/blob/e2e0fdcc2521027ee49c58d50d60c42edb9466a0/index.js
[crypto-tests]: https://github.com/holepunchto/hypercore-crypto/blob/e2e0fdcc2521027ee49c58d50d60c42edb9466a0/test.js
[serde]: ../serde/concepts.md
[recommendations]: ../content-addressing/recommendations.md
[flat]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[compact]: https://github.com/compact-encoding/compact-encoding/blob/c5089d708694a4438370c950c0812ffda72a7266/index.js
