# IPLD, DAG-CBOR and DAG-PB (Multiformats)

A codec-independent linked data model whose content identifiers name encoded blocks, not arbitrary application-value equivalence classes.

| Metadata      | Value                                                                   |
| ------------- | ----------------------------------------------------------------------- |
| Language      | Specifications; implementations in Go, JavaScript and other languages   |
| License       | Apache-2.0 OR MIT for the surveyed specification repository             |
| Repository    | [`ipld/ipld`][repo]                                                     |
| Documentation | [DAG-CBOR specification][cbor]; [DAG-PB specification][pb]              |
| Category      | Content-addressed data model and block codecs                           |
| Snapshot      | `bfd348aa0b1acd980bb4cdbad445a453ec70c617`                              |
| Status        | DAG-CBOR: descriptive draft; DAG-PB: descriptive final at this snapshot |

## Overview

### What it solves

[IPLD][model] lets independently encoded blocks participate in one traversable
graph. A link is a first-class data-model value, rather than an application
string that a generic decoder must guess is an address. A codec maps between
the model and bytes; a [CID][cid] identifies the codec and the hash of those
bytes. A block store can therefore verify a fetched block before interpreting
its fields.

This page concerns block representation. File chunking, balanced versus
trickle layouts, directory sharding and import settings belong to the existing
[IPFS/UnixFS survey][unixfs]. Those choices can change a file's CID even when
the file bytes are unchanged. They are not defects in DAG-CBOR map ordering.

### Design philosophy

The [DAG-CBOR specification][cbor] states the byte-identity objective directly:

> DAG-CBOR requires that there exist a single, canonical way of encoding any given set of data, and that encoded forms contain no superfluous data that may be ignored or lost in a round-trip decode/encode.

The same repository explicitly says [DAG-PB][pb] does **not** support the full
IPLD data model. Codec independence is not a promise that every codec can
represent every node. The model/representation distinction parallels the
[serde vocabulary][serde]; the existing [content-addressing concepts][ca]
explain the graph-versus-whole-serialization boundary.

## How it works

The [data model][model] contains null, boolean, integer, float, string, bytes,
list, map and link kinds. Schema types and representation strategies refine
those kinds but are not required to parse an ordinary DAG-CBOR node.

A CIDv1 has this binary structure, using unsigned varints for its numeric
components ([CID specification][cid]):

```text
version=1 | codec-code | multihash-code | digest-length | digest
```

The digest is over the encoded block. The codec code is outside that digest,
but inside the CID that a parent block embeds. A multibase prefix belongs to
the CID's **text** representation; it is not normally part of the binary CID.
DAG-CBOR's leading zero inside a link byte string is a specific historical
exception, described below.

### Schema source of truth

For generic DAG-CBOR, the [data model][model] and [codec rules][cbor] are the
source of truth. An optional [IPLD Schema][schemas] describes stronger types,
including struct representations and unions. It does not replace the codec.
A struct represented as a tuple can have different bytes from a struct
represented as a map even when both implement the same application concept.

DAG-PB instead fixes two message shapes: `PBNode` and `PBLink`. Its logical
schema exposes `Links`, optional `Data`, and each link's required `Hash`,
optional `Name` and optional `Tsize`. An arbitrary extra map field is an
encoding error, not a protobuf extension point ([specification][pb]).

### Wire encoding

[DAG-CBOR][cbor] uses CBOR major types with string-only map keys. The only
accepted semantic tag is `42`. A link is encoded as that tag around a byte
string containing `00 || binary-CID`; the zero is the identity-multibase
prefix and **must not be omitted**. The shortest tag encoding is `d82a`.

Strings are UTF-8; integers and length arguments use shortest encodings;
containers have definite lengths. Floating-point values use binary64 even
when a narrower CBOR float would suffice. NaNs, infinities, undefined and
unrecognized simple values are outside the model. These rules differ from
[dCBOR numeric reduction][dcbor], not merely from its implementation API.

[DAG-PB][pb] encodes `PBLink.Hash` as field 1, `Name` as field 2 and `Tsize`
as field 3. `PBNode.Links` is repeated field 2; `Data` is field 1. Link hashes
contain a binary CID **without** DAG-CBOR's extra zero prefix. `Data` remains
opaque to this codec; UnixFS supplies a separate interpretation.

### Access model

Traversal walks map keys and list indices inside a decoded block, then follows
a link into another block. The block boundary is the fetch/cache/verification
unit. A schema-aware implementation may provide typed access, but neither
codec promises native-layout, aligned, zero-copy records.

DAG-PB's model paths include `Links`, an index and `Hash`. Historical
implementations also resolved names directly; the specification distinguishes
that legacy behavior from modern model traversal. Treating `/name` as generic
IPLD behavior loses this distinction ([legacy pathing][pb]).

### Variable-length and optional data

CBOR length heads describe byte strings, text, arrays and maps. DAG-CBOR has
no indefinite-length streaming representation. A schema's optional map field
is absent; a nullable field can instead be present with null. They are
different model values and can hash differently.

DAG-PB distinguishes absent `Data` from present empty bytes at the logical
level, although some legacy interfaces blur that distinction. An absent wire
`Links` sequence decodes as an empty list. `Hash` is required logically even
though the historical protobuf declaration says `optional` ([constraints][pb]).

### Evolution and compatibility

A CID selects a codec, not a versioned application schema. Applications must
identify schema changes through their own protocol, an enclosing value or a
new codec. Unknown application map fields can survive generic DAG-CBOR
decoding, but typed-schema acceptance is a separate policy.

DAG-PB rejects unknown fields and wire types, duplicate singular fields and
out-of-order link fields. It deliberately does not inherit every protobuf
forward-compatibility behavior. Changing a representation strategy changes
the encoded block and thus its content address ([strictness][pb]).

### Determinism and canonical form

DAG-CBOR sorts map keys by their encoded bytes. Because all keys are strings,
the CBOR length head produces length-first ordering, followed by bytewise
ordering for equal lengths. There is no Unicode normalization rule making
distinct text sequences equal. The source also excludes negative zero in
favor of positive zero ([strictness][cbor]).

The specification permits decoder leniency for historical data: map ordering,
nonminimal lengths or integers, and narrow floats can be accepted. An
implementation's ordinary decode success is consequently not proof that the
input was canonical. Hash the received bytes when checking a CID; decoding
and re-encoding first verifies a different object.

DAG-PB accepts both `Links`-before-`Data` and `Data`-before-`Links`. Link
sorting is an encode rule; decoding preserves the existing order. Its
aspiration to canonicality therefore does not mean one accepted byte string
per decoded value. The link-name uniqueness and stable-sorting discussion
also needs a protocol-level reading for unnamed/equal-name links ([spec][pb]).

### Merkleization and content addressing

IPLD does not prescribe an intra-block binary Merkle tree. For a block with
two child links, the construction is conceptually:

```text
child-A bytes -> multihash -> CID-A --+
                                    +-> encode parent -> multihash -> CID-parent
child-B bytes -> multihash -> CID-B --+
```

The parent commits to the child CIDs because their binary encodings occur in
its bytes. There is no SSZ-style per-field root or list-length mix-in; CBOR
length heads are part of the hashed bytes. CID codec/hash codes identify
interpretation, while a digest alone omits that surrounding context.

An inclusion argument across blocks supplies the relevant parent blocks and
verifies links. An ordinary CID cannot prove a field inside a missing block
from a logarithmic sibling path. Smaller proof granularity requires smaller
blocks or an additional authenticated structure. See the existing
[recommendations][recommendations] rather than equating a graph with a
universal partial-value proof API.

### Hostile-input safety

Validate tag `42` payloads as actual CIDs, including the prefix, codec and
multihash framing. Apply limits to block size, container counts, nesting,
traversal steps and fetched bytes. Hash verification alone says nothing about
whether decoding is cheap or whether a tag is allowed.

Reject invalid UTF-8, forbidden keys/tags and trailing bytes when enforcing
the strict DAG-CBOR profile. DAG-PB additionally needs its specialized
protobuf validation. A generic protobuf parser that silently ignores fields
does not implement the required rejection policy ([DAG-CBOR][cbor], [DAG-PB][pb]).

These are observed failure modes, not just defensive suggestions. The CNA
records report [CVE-2026-35480][allocation-cve]: `go-ipld-prime` before
0.22.0 trusted CBOR collection headers as uncapped preallocation hints.
[CVE-2026-42328][recursion-cve] reports unbounded DAG-CBOR/DAG-JSON recursion
before 0.23.0, allowing fatal Go stack overflow. These concern particular
decoder versions, not a break of CID hashing or the abstract IPLD model.

### Describing foreign formats

Not a general arbitrary-layout description system. An IPLD codec can expose
an existing format through model nodes, but that requires implementing the
format's parser and representation mapping. An IPLD Schema alone does not
declare foreign endianness, relative offsets or alignment.

For the Flat design question, this is a separable architectural lesson:
application type, encoded representation and address identity should not be
conflated. It is not evidence that fixed-layout font tables can be described
by choosing DAG-CBOR or adding a CID.

### Implementation and performance evidence

**Runnable independent framing check, not an IPLD codec/reference tool.**
This constructs the SHA2-256 CIDv1 framing of the empty DAG-PB block and
the additional DAG-CBOR link wrapper; it does not decode either codec.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "research_ipld_link_framing"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.digest.sha : sha256Of;
import std.stdio : writeln;

void main() @safe
{
    const ubyte[] empty;
    const digest = sha256Of(empty);
    ubyte[] cid = [0x01, 0x70, 0x12, 0x20];
    cid ~= digest[]; // v1, dag-pb, sha2-256, 32-byte digest
    assert(cid.length == 36);
    // tag 42, byte-string length 37, identity prefix, binary CID
    ubyte[] link = [0xd8, 0x2a, 0x58, 0x25, 0x00];
    link ~= cid;
    assert(link.length == 41 && link[4] == 0 && link[5] == 1);
    writeln("binary CIDv1: ", cid.length, " bytes");
    writeln("DAG-CBOR link wrapper: ", link.length, " bytes");
}
```

```ansi
binary CIDv1: 36 bytes
DAG-CBOR link wrapper: 41 bytes
```

**Source test vector, not local execution.** The [DAG-PB zero-length-block
section][pb] defines the empty byte string as a valid block and gives:

```text
block hex: (empty)
CIDv1: bafybeihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku
CIDv0: QmdfTbBqBPQ7VNxZEYEj14VmRuZBkqFbiwReogJgS1zR1n
```

This is a precise identity fixture, not an invented encoding of an empty
CBOR map. The CIDv0 form implies DAG-PB and a SHA2-256 multihash; CIDv1 makes
the codec explicit ([CID specification][cid]).

The DAG-CBOR source documents concrete implementation deviations, including
decoder strictness and JavaScript number round trips. Those are stronger
interoperability evidence than an undifferentiated “canonical CBOR” label.
No D port or binding was verified in this survey.
No throughput or allocation benchmark was executed for this page. Cost
depends on block sizes, schema representation and traversal workload.

## Strengths

- Codec and hash agility travel with an address.
- Links have model semantics; block boundaries support independent verification.
- DAG-CBOR has explicit restrictions and documented historical exceptions.

## Weaknesses

- Block authentication does not provide intra-block field proofs.
- DAG-PB and DAG-CBOR have materially different model coverage and strictness.
- Application equality and import-policy equality remain outside a CID.

## Key design decisions and trade-offs

| Decision                        | Rationale                                   | Trade-off                                          |
| ------------------------------- | ------------------------------------------- | -------------------------------------------------- |
| Hash encoded blocks             | Verify before interpreting application data | Equivalent representations can have different CIDs |
| Carry codec and multihash       | Allow independent evolution                 | Registry and policy surface grows                  |
| Recognize links as a kind       | Make graph traversal generic                | A codec must preserve link semantics               |
| Keep legacy decoding exceptions | Read deployed data                          | Acceptance does not certify canonicality           |

## Sources

- [IPLD data model][model] and [schema documentation][schemas].
- [DAG-CBOR][cbor] and [DAG-PB][pb] pinned specifications.
- [CID binary/text specification][cid].
- CNA records for [allocation exhaustion][allocation-cve] and [recursion exhaustion][recursion-cve].
- Related analysis: [shared concepts][concepts], [comparison][comparison],
  [UnixFS][unixfs] and [content-addressing recommendations][recommendations].

<!-- References -->

[repo]: https://github.com/ipld/ipld/tree/bfd348aa0b1acd980bb4cdbad445a453ec70c617
[cbor]: https://github.com/ipld/ipld/blob/bfd348aa0b1acd980bb4cdbad445a453ec70c617/specs/codecs/dag-cbor/spec.md
[pb]: https://github.com/ipld/ipld/blob/bfd348aa0b1acd980bb4cdbad445a453ec70c617/specs/codecs/dag-pb/spec.md
[model]: https://ipld.io/docs/data-model/
[schemas]: https://ipld.io/docs/schemas/
[cid]: https://github.com/multiformats/cid/blob/9eca1c5ba064823a5ddbe13e9925f9b6c9d19c84/README.md
[unixfs]: ../content-addressing/ipfs-unixfs.md
[ca]: ../content-addressing/concepts.md
[recommendations]: ../content-addressing/recommendations.md
[serde]: ../serde/concepts.md
[dcbor]: ./cbor-cose-dcbor.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[allocation-cve]: https://cveawg.mitre.org/api/cve/CVE-2026-35480
[recursion-cve]: https://cveawg.mitre.org/api/cve/CVE-2026-42328
