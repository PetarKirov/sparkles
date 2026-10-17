# Tendermint and CometBFT (Go / Protobuf)

A consensus protocol that separates protobuf transport messages from the exact byte encodings committed by RFC 6962-style trees.

| Metadata         | Value                                                                 |
| ---------------- | --------------------------------------------------------------------- |
| Language         | Go; protobuf schemas and generated bindings                           |
| License          | Apache-2.0                                                            |
| Repository       | [`cometbft/cometbft`][repo]                                           |
| Documentation    | [Data structures][structures]; [protobuf migration ADR][migration]    |
| Category         | Consensus serialization and authenticated ordered sequences           |
| Snapshot         | `882888fc0e6c56a830f1477a0bf9eaaa63e8b3bb`                            |
| Historical scope | Tendermint's Amino-to-protobuf transition; CometBFT source at the pin |

## Overview

### What it solves

Validators must agree not merely on decoded transactions and headers but on
the exact bytes they sign and hash. An extensible transport serializer is
useful for networking, but generic protobuf equivalence is not an adequate
definition of consensus identity. CometBFT makes separate choices for message
transport, canonical sign bytes, header-field commitments and transaction
commitments ([data structures][structures], [header implementation][block]).

This page is not a description of Cosmos application-state trees. An
application supplies `AppHash`; its internal commitment scheme is outside
CometBFT's generic transaction and header tree. Nor is it a claim that all
Cosmos SDK serialization migrated at the same time as Tendermint Core.

### Design philosophy

The implemented [ADR 055][migration] states:

> Transition Tendermint to Protobuf because of its performance and tooling.

The ADR also retains handwritten native types and conversion functions to
generated protobuf types. This makes the boundary visible, but creates two
representations that contributors must keep consistent. The
[deterministic-protobuf RFC][determinism] records why encoding choices need
more attention when bytes participate in consensus.

## How it works

There are three distinct pipelines:

```text
native protocol value -> protobuf message -> transport bytes
vote/proposal -> canonical protobuf value -> length-delimited sign bytes
ordered leaf byte strings -> RFC6962-style tree -> commitment
```

The third pipeline accepts bytes. It is not reflection over every Go field,
and it is not `SHA256(marshal(entire-header))`. `Header.Hash` explicitly
assembles fourteen field encodings in a fixed order ([`types/block.go`][block]).

### Schema source of truth

The [protobuf directory][proto] describes transport messages. Handwritten
types implement validation and expose conversions such as `ToProto` and
`HeaderFromProto`. The effective consensus schema also includes the explicit
hashing/signing code: choosing or reordering a field in `Header.Hash` changes
identity even if a generated transport message remains wire-compatible.

The [migration ADR][migration] describes Amino's role as a prototyping-oriented
reflection codec and the decision to stop relying on it for core encoding.
Historical Amino prefixes and key encodings must not be retroactively read as
protobuf field tags; [ADR 054][keys] records that key-format break separately.

### Wire encoding

Protobuf transports use numbered fields, varints and length-delimited nested
messages. Generated Go structures are not memory images of those bytes.
Zero-valued fields, repeated-field order and nested encodings all matter
when deriving the exact canonical byte string used for a commitment.

Votes and proposals are canonicalized before signing, and use a
length-delimited encoding. The ordinary network message contains fields not
identical to the canonical sign structure. Consult [`types/vote.go`][vote]
and the [canonical schema][canonical], rather than signing a received
protobuf buffer verbatim.

For headers, version and `LastBlockID` are marshaled nested messages, time
uses the protobuf time encoder, and scalar/string/byte fields pass through
`cdcEncode`. These resulting byte strings become ordered tree leaves
([header code][block], [encoding helper][encoding]).

### Access model

The reference implementation decodes messages to Go values and validates
them. It does not expose a general in-place record API or arbitrary
field-offset lookup over the transport bytes. Separate native and generated
types are an explicit design choice, not a zero-copy layout guarantee.

Merkle inclusion access is a different facility: given an authenticated root,
a leaf and its proof, a reader can validate inclusion without receiving all
other leaves. That proves the chosen byte string's position, not a direct
native-memory view over a protobuf message ([proof implementation][proof]).

### Variable-length and optional data

Transactions are arbitrary byte slices at the core boundary. Their schema
belongs to the application. Protobuf framing supplies lengths on the wire;
the transaction hash code itself hashes `tx` bytes, not a newly prefixed
length encoding ([`types/tx.go`][tx]).

Optional/default protobuf semantics are distinct from tree membership. A
header field occupying an empty byte string still occupies its assigned
leaf position. Removing it from the tree is not equivalent to omitting a
default field from a protobuf message.

### Evolution and compatibility

The Amino-to-protobuf change is a protocol/encoding transition, not a promise
that old Amino blobs deserialize under a protobuf codec. The key-format ADR
explicitly warns of ecosystem-wide breaking changes ([ADR 054][keys]).
CometBFT's later protobuf-versioning policy addresses schema lifecycle
separately ([ADR 103][versioning]).

Adding transport fields can be protobuf-compatible while changing the hash
or sign-byte rules is consensus-breaking. A migration must pin all three:
network schema, canonical signed message and commitment leaf encoding.
Compatibility cannot be inferred from a serializer library's version alone.

### Determinism and canonical form

Protobuf permits byte-level alternatives for an equivalent decoded message.
The [determinism RFC][determinism] discusses the problem rather than treating
a language runtime's deterministic-marshaling switch as a universal
cross-language canonical form.

CometBFT's explicit construction paths provide the required concrete rule.
For example, the header root follows the field order in `Header.Hash`, while
`Txs.Hash` follows transaction order. Sorting transactions to obtain a
“canonical set” would change the committed sequence ([header][block], [tx][tx]).

### Merkleization and content addressing

[`crypto/merkle/tree.go`][tree] says it follows [RFC 6962][rfc6962]. With
`H = SHA256`, the functions in [`hash.go`][hash] define:

```text
M([])       = H(empty)
M([x])      = H(00 || x)
M(xs)       = H(01 || M(xs[:k]) || M(xs[k:]))
k           = largest power of two strictly less than len(xs)
M([a,b,c])  = H(01 || H(01 || H(00||a) || H(00||b)) || H(00||c))
```

This is an unpadded, left-heavy tree, not SSZ's capacity-sized zero-padded
tree. Leaf and internal-node prefixes separate their domains. There is no
SSZ-style explicit length mix-in; proof verification uses the claimed
`Total` and `Index` to reconstruct the split shape.

The input to this generic tree is context-dependent. `Txs.hashList` first
computes `SHA256(tx)` for every transaction, so a transaction tree leaf is
`SHA256(00 || SHA256(tx))`, **not** `SHA256(00 || tx)`. Header leaves instead
contain the selected field encodings. A transaction's lookup hash, a leaf
hash and a block header hash are three different objects ([transaction code][tx]).

`Proof` carries `Total`, `Index`, `LeafHash` and `Aunts`. Its checks constrain
indices, digest widths and aunt counts. Inclusion does not prove validator
authorization by itself: the root must be authenticated through consensus or
light-client verification. It also does not prove non-inclusion or a
transaction's application semantics ([proof code][proof]).

### Hostile-input safety

Generated protobuf decoding is followed by native validation; length limits
and semantic checks remain protocol responsibilities. `Header.ValidateBasic`
checks field/hash constraints, while transaction validation accounts for the
encoded size against a maximum ([header][block], [transactions][tx]).

Merkle proof validation rejects invalid totals/indices, malformed hashes and
excessive aunt paths. A malformed proof is not a reason to allocate a full
tree of the claimed total size. The source tests mutate leaf/root bytes and
make trails too long and too short ([tree tests][tests]).

The primary [security advisory catalog][advisories] lists ASA-2025-002,
where apparently valid block parts could stall the network: generic Merkle
proof validity is not enough without binding the enclosing part index to
the proof index. Separately, [CVE-2025-24371][sync-cve] concerns malicious
blocksync height reports, fixed in 0.38.17 and 1.0.1. It is a state/protocol
validation failure, not a SHA-256 collision or protobuf syntax weakness.

### Describing foreign formats

Not applicable as a general format-description facility. The `.proto`
schemas define CometBFT's own format, while native conversion code bridges
its application representation. Protobuf tags cannot describe foreign
packed structs, arbitrary byte order or offsets into an OpenType table.

For Flat, the transferable lesson is to identify exactly which projection
is hashed. A layout digest, a hash of serialized output and an opaque cache
key derived from inputs serve different purposes; CometBFT's transaction
lookup/hash/tree separation is a concrete warning against one generic
“content hash” field.

### Implementation and performance evidence

**Runnable independent hash check, not CometBFT execution.** This tests
the generic tree's empty/singleton separation and its published two-leaf
vector. It does not exercise header serialization or transaction hashing.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "research_cometbft_merkle_invariants"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.ascii : toLower;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.stdio : writeln;

void main() @safe
{
    const ubyte[] empty;
    const ubyte[] a = [0, 1, 2, 3]; // 00 domain, then leaf 010203
    const ubyte[] b = [0, 4, 5, 6];
    const left = sha256Of(a), right = sha256Of(b);
    const root = sha256Of(cast(ubyte[])[1] ~ left[] ~ right[]);
    assert(sha256Of(empty) != sha256Of(cast(ubyte[])[0]));
    auto hex = toHexString(root);
    foreach (ref ch; hex) ch = toLower(ch);
    assert(hex[] == "82e6cfce00453804379b53962939eaa7906b39904be0813fcadd31b100773c4b");
    writeln(hex[]);
}
```

```ansi
82e6cfce00453804379b53962939eaa7906b39904be0813fcadd31b100773c4b
```

**Source test vectors, not local execution.** `TestHashFromByteSlices` in
[`tree_test.go`][tests] specifies the following generic-tree inputs:

| Leaf byte strings (hex) | Expected root (hex)                                                |
| ----------------------- | ------------------------------------------------------------------ |
| Empty sequence          | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| One empty leaf          | `6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d` |
| `010203`                | `054edec1d0211f624fed0cbca9d4f9400b0e491c43742af2c5b0abebf0c990d8` |
| `010203`, `040506`      | `82e6cfce00453804379b53962939eaa7906b39904be0813fcadd31b100773c4b` |

These are **not** `Txs.Hash` vectors: those inputs receive an extra
transaction-hash layer. The distinction makes the fixture useful for
independent implementations rather than merely illustrative.

No D port or binding was verified in this survey.
The source includes recursive and iterative implementations and a benchmark
comparing them. Historical timings in comments are not measurements on this
host, and the page makes no performance ranking from them. No Go tests or
benchmarks were run locally for this survey.

## Strengths

- Explicit, inspectable commitment projections rather than implicit reflection.
- Domain-separated ordered trees with independent inclusion proofs.
- Migration records distinguish ecosystem/tooling reasons from wire mechanics.

## Weaknesses

- Transport compatibility does not imply consensus-byte compatibility.
- Native and generated schemas create synchronization work.
- A generic inclusion tree does not authenticate application state semantics.

## Key design decisions and trade-offs

| Decision                                | Rationale                                          | Trade-off                                        |
| --------------------------------------- | -------------------------------------------------- | ------------------------------------------------ |
| Replace Amino with protobuf             | Tooling and language ecosystem                     | Encoding transition and generated-type boundary  |
| Hash header fields separately           | Stable explicit commitment projection              | Hash code is part of the schema contract         |
| Prefix leaf and branch domains          | Avoid structural ambiguity                         | Not a raw hash of concatenated values            |
| Hash transactions before tree insertion | Separate transaction identity from list commitment | Additional hash layer must be reproduced exactly |

## Sources

- [ADR 055][migration], [ADR 054][keys], [determinism RFC][determinism] and [ADR 103][versioning].
- [Header][block], [transaction][tx], [tree][tree], [proof][proof] and [test][tests] implementations.
- [RFC 6962][rfc6962]; [shared concepts][concepts] and [comparison][comparison].
- Primary [advisory catalog][advisories] and [CNA blocksync record][sync-cve].

<!-- References -->

[repo]: https://github.com/cometbft/cometbft/tree/882888fc0e6c56a830f1477a0bf9eaaa63e8b3bb
[migration]: https://github.com/cometbft/cometbft/blob/882888fc0e6c56a830f1477a0bf9eaaa63e8b3bb/docs/references/architecture/tendermint-core/adr-055-protobuf-design.md
[keys]: https://github.com/cometbft/cometbft/blob/882888fc0e6c56a830f1477a0bf9eaaa63e8b3bb/docs/references/architecture/tendermint-core/adr-054-crypto-encoding-2.md
[determinism]: https://github.com/cometbft/cometbft/blob/882888fc0e6c56a830f1477a0bf9eaaa63e8b3bb/docs/references/rfc/tendermint-core/rfc-007-deterministic-proto-bytes.md
[versioning]: https://github.com/cometbft/cometbft/blob/882888fc0e6c56a830f1477a0bf9eaaa63e8b3bb/docs/references/architecture/adr-103-proto-versioning.md
[structures]: https://github.com/cometbft/cometbft/blob/882888fc0e6c56a830f1477a0bf9eaaa63e8b3bb/spec/core/data_structures.md
[block]: https://github.com/cometbft/cometbft/blob/882888fc0e6c56a830f1477a0bf9eaaa63e8b3bb/types/block.go
[encoding]: https://github.com/cometbft/cometbft/blob/882888fc0e6c56a830f1477a0bf9eaaa63e8b3bb/types/encoding_helper.go
[vote]: https://github.com/cometbft/cometbft/blob/882888fc0e6c56a830f1477a0bf9eaaa63e8b3bb/types/vote.go
[canonical]: https://github.com/cometbft/cometbft/blob/882888fc0e6c56a830f1477a0bf9eaaa63e8b3bb/proto/tendermint/types/canonical.proto
[proto]: https://github.com/cometbft/cometbft/tree/882888fc0e6c56a830f1477a0bf9eaaa63e8b3bb/proto
[tx]: https://github.com/cometbft/cometbft/blob/882888fc0e6c56a830f1477a0bf9eaaa63e8b3bb/types/tx.go
[tree]: https://github.com/cometbft/cometbft/blob/882888fc0e6c56a830f1477a0bf9eaaa63e8b3bb/crypto/merkle/tree.go
[hash]: https://github.com/cometbft/cometbft/blob/882888fc0e6c56a830f1477a0bf9eaaa63e8b3bb/crypto/merkle/hash.go
[proof]: https://github.com/cometbft/cometbft/blob/882888fc0e6c56a830f1477a0bf9eaaa63e8b3bb/crypto/merkle/proof.go
[tests]: https://github.com/cometbft/cometbft/blob/882888fc0e6c56a830f1477a0bf9eaaa63e8b3bb/crypto/merkle/tree_test.go
[rfc6962]: https://www.rfc-editor.org/rfc/rfc6962#section-2.1
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[advisories]: https://github.com/interchainio/security/blob/4263cba1d1de18c8942137039a2909a8c8c3a5b6/ADVISORIES.md
[sync-cve]: https://cveawg.mitre.org/api/cve/CVE-2025-24371
