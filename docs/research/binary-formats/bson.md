# BSON (MongoDB / Language-neutral)

Length-delimited, ordered documents designed for typed database values and
skippable subdocuments, not minimum size or universal canonical hashing.

| Field              | Value                                                                              |
| ------------------ | ---------------------------------------------------------------------------------- |
| Language           | Language-neutral; implementation inspected in C                                    |
| License            | Driver specifications: [CC BY-NC-SA 3.0 US][license]; driver licensing is separate |
| Repository         | [MongoDB specifications][corpus] · [`mongo-c-driver`][bson-c]                      |
| Documentation      | [BSON specification 1.1][spec]                                                     |
| Category           | Self-describing, ordered, length-delimited document encoding                       |
| Root shape         | Document; no standalone scalar root in the base grammar                            |
| Integer byte order | Little-endian                                                                      |

## Overview

### What it solves

BSON represents database documents with explicit numeric types, binary
subtypes, timestamps, object identifiers, and nested documents. Lengths let
readers skip whole nested documents without first decoding every descendant.
That is useful for document processing, but not equivalent to an offset-indexed
record layout ([grammar][spec]).

The [comparison][comparison] places BSON beside stream-oriented binary JSON
formats. Shared terminology is in [concepts][concepts]. MongoDB's operational
document limits must be distinguished from the larger bounds expressible by
the wire grammar.

### Design philosophy

The official specification opens with:

> BSON is a binary format in which zero or more ordered key/value pairs are stored as a single entity. We call this entity a document.

"Ordered" is consequential. A document is not simply an unordered mathematical
map serialized in an arbitrary order. A binding that uses an unordered native
dictionary can alter information the BSON model retains ([specification][spec]).

## How it works

A document is a signed little-endian `int32` total byte length, a sequence of
elements, then a zero terminator. The length includes its own four bytes and
the terminator; the empty document is therefore five bytes. Each element starts
with a type byte, then a NUL-terminated field name, then its typed payload
([grammar][spec]).

| Type byte  | Value            | Payload                                                |
| ---------- | ---------------- | ------------------------------------------------------ |
| `01`       | Double           | 8-byte IEEE binary64                                   |
| `02`       | String           | `int32` byte length including trailing NUL, then bytes |
| `03`       | Document         | Complete nested document                               |
| `04`       | Array            | Document keyed by consecutive decimal indices          |
| `05`       | Binary           | `int32` byte count, subtype byte, payload              |
| `07`       | `ObjectId`       | 12 bytes                                               |
| `08`       | Boolean          | Exactly `00` or `01`                                   |
| `09`       | UTC datetime     | Signed 64-bit milliseconds since Unix epoch            |
| `0a`       | Null             | No payload                                             |
| `10`, `12` | `int32`, `int64` | 4 or 8 bytes                                           |
| `11`       | Timestamp        | Replication/sharding timestamp, not UTC datetime       |
| `13`       | `Decimal128`     | 16-byte decimal floating-point representation          |

**Locally executed reference-tool probe.** The pinned
[`nlohmann/json` writer][writer], compiled in a C++17 harness, emitted this for
`{"i":1}`:

```text
0c 00 00 00 10 69 00 01 00 00 00 00
```

This exactly matches the **upstream source vector** for integer 1 in
[`bson-corpus/tests/int32.json`][int32]. The 12 bytes are: total length 12;
type `int32`; name `i` and NUL; little-endian 1; document terminator.
The local run used C++, not `libbson` or a MongoDB server.

**Portable CI invariant check.** This independently checks that observed
document's framing and fixed `int32` element. The framing predicate intentionally
does not validate arbitrary elements: passing it proves only a checked envelope,
not whole-document validity. No upstream encoder runs in this example.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "research_bson_vector"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : writeln;

bool framed(in ubyte[] bytes) @safe pure nothrow @nogc
{
    if (bytes.length < 5)
        return false;
    uint declared;
    foreach (i; 0 .. 4)
        declared |= cast(uint)bytes[i] << (8 * i);
    return declared >= 5 && declared <= int.max
        && declared == bytes.length && bytes[$ - 1] == 0;
}

void main() @safe
{
    immutable ubyte[] document = [
        0x0c, 0, 0, 0, 0x10, 0x69, 0, 1, 0, 0, 0, 0];
    assert(framed(document));
    foreach (end; 0 .. document.length)
        assert(!framed(document[0 .. end]));
    assert(document[4] == 0x10 && document[5 .. 7] == [0x69, 0]);
    uint value;
    foreach (i; 0 .. 4)
        value |= cast(uint)document[7 + i] << (8 * i);
    assert(value == 1 && 7 + int.sizeof == document.length - 1);
    auto corrupt = document.dup;
    corrupt[0] = 0; // A zero declared length must not underflow an end index.
    assert(!framed(corrupt));
    corrupt[0 .. 4] = 0xff; // Negative signed length, read as raw bits.
    assert(!framed(corrupt));
    writeln("BSON: 12-byte envelope, int32 value 1, truncations and bad lengths rejected");
}
```

```ansi
BSON: 12-byte envelope, int32 value 1, truncations and bad lengths rejected
```

### Schema source of truth

The grammar determines BSON types and lengths. Application record schemas,
required fields, validation, aliases, and defaults are external. MongoDB's
query and schema-validation facilities are additional database contracts, not
necessary ingredients of a BSON decoder ([spec][spec]).

Driver specifications additionally constrain type mappings. The
[`Decimal128` specification][decimal] and [Extended JSON specification][extjson]
show why an ordinary JSON object is insufficient as the complete schema:
`int32`, `int64`, double, and decimal values may need to remain distinguishable
even when their displayed numbers look alike.

### Wire encoding

Field names are `cstring`: they cannot contain NUL and have no separate length.
String values have a length and terminal NUL; their payload may contain embedded
NUL. Those are different scan/bounds contracts. A reader must never use an
unbounded C string operation simply because the wire calls a field `cstring`
([grammar][spec]).

Arrays are embedded documents with keys `"0"`, `"1"`, and so on in order.
The decimal keys consume bytes and must be checked if the reader claims strict
array validity. The nested document length is a byte extent, not an element
count. There is no packed ordinary numeric-array layout.

Binary subtypes add semantic contracts. Generic bytes use subtype 0; UUID uses
4; legacy binary subtype 2 embeds another `int32` length. Subtype 9 defines
numeric vectors with their own dtype/padding rules, rather than retroactively
making ordinary BSON arrays packed ([base specification][spec]; [vector spec][vector]).

`ObjectId` is not a document content digest. UTC date milliseconds and the
replication timestamp have different types and semantics. Deprecated code,
symbol, DBPointer, and code-with-scope values still matter to a generic reader
that advertises the complete grammar ([spec][spec]).

### Access model

BSON supports borrowed byte views and iterative scanning. The inspected
[`bson_init_static`][bson-c] checks a length range, equality with the stored
length, and the final zero byte, then marks the buffer read-only and non-owned.
It does **not** recursively prove that every element is valid.

Full validation is a separate operation:
`bson_validate_with_error_and_offset` dispatches to the validator and can report
an error and offset. Keeping opening and traversal separate avoids confusing a
cheap framing check with whole-document validation ([implementation][bson-c]).

A nested document can be skipped using its checked length. Locating a field
still scans earlier element headers and names; there is no field offset index.
Borrowing avoids copying bytes but does not make arbitrary BSON fields native
struct members at compile-time offsets. Compare [in-place views][in-place].

### Variable-length and optional data

Document and string lengths are signed 32-bit values. Negative lengths, a
document length below 5, and a string length below 1 cannot be valid payload
sizes. A writer normally buffers, counts in advance, or patches the document
length after constructing its elements ([grammar][spec]).

An omitted field differs from a field holding null. Deprecated undefined is
also a distinct wire type, not permission for a binding to erase arbitrary
missingness distinctions. Repeated field names can occur syntactically, but
MongoDB does not support duplicate-field documents as ordinary stored records
([MongoDB limits and duplicate-field warnings][limits]).

### Evolution and compatibility

Named fields support additive application evolution when readers ignore unknown
names and define missing-field behavior. BSON itself supplies no required-field
set, per-record schema identifier, migration graph, or default values.

Unknown element **type codes** differ from unknown field names: without a
known payload grammar, a reader cannot generally find the next element.
Binary subtypes are more extensible because the enclosing binary value has a
known byte extent ([grammar][spec]).

UUID legacy subtype/order conventions and deprecated types require explicit
driver compatibility policy. Mapping every BSON value into relaxed JSON and
back can discard type information. The [Extended JSON specification][extjson]
distinguishes canonical and relaxed representations precisely for that reason.

### Determinism and canonical form

BSON prescribes field order preservation, not a global sort order. A writer
that deterministically visits a struct can produce stable bytes for that
declaration without creating a canonical representation of unordered logical
maps. Sorting fields changes an ordered document unless the application
explicitly declares order irrelevant ([model][spec]).

Likewise `int32(1)`, `int64(1)`, double 1.0, and decimal 1 are different BSON
types. A semantic hash profile must state whether those distinctions survive.
Binary64 NaN payloads, signed zero, and decimal representation details require
their own rules; a native numeric equality test is not a byte normalizer.

"Canonical Extended JSON" and corpus `canonical_bson` labels are not a
universal canonical BSON map-hashing standard. The corpus labels identify
expected fixture representations; Extended JSON's canonical form preserves
type information in text ([corpus][corpus]; [Extended JSON][extjson]).

Duplicate keys must be rejected or explicitly modeled as an ordered sequence
before conversion to native maps. The server warns of dropped values and
inconsistent query results; neither first-wins nor last-wins is a portable
MongoDB document contract ([duplicate-field warnings][limits]).

### Merkleization and content addressing

**N/A as a base feature:** documents inline their children; there are no
authenticated links, subtree digests, proofs, or chunk boundaries. Hashing a
BSON buffer commits to its bytes, order, and exact numeric types.

An application can place hashes in binary fields, but must specify algorithm,
domain separation, link interpretation, and canonical semantic model. A UUID,
`ObjectId`, or BSON timestamp is not evidence that the surrounding object is
content-addressed. See [content-addressing concepts][ca].

### Hostile-input safety

Validate every nested length against its parent extent, not merely the whole
file. Check for signed-negative sizes before unsigned conversion, bound NUL
searches, and check addition/multiplication before allocating. Legacy binary
subtype 2 and code-with-scope require consistency between nested lengths
([grammar][spec]).

MongoDB's **server** limits are 16 MiB per document and 100 nesting levels;
these are not universal BSON grammar constants. The C implementation's
`BSON_MAX_SIZE` is `2^31−1`, illustrating a different library-level boundary
([server limits][limits]; [`bson.h`][bson-h]).

**Concrete overflow advisory.** MongoDB's CNA record
[CVE-2025-0755][cve-overflow] identifies `bson_append` operations that can
overflow when the resulting document exceeds `INT32_MAX`: affected `libbson`
versions are before 1.27.5; affected MongoDB Server branches are 7.0 before
7.0.16 and 8.0 before 8.0.1. This is builder arithmetic, not proof that every
BSON parser is vulnerable. The inspected append machinery checks lengths
using subtraction against `BSON_MAX_SIZE` ([`bson.c`][bson-c]).

**Concrete depth advisory.** MongoDB's CNA record
[CVE-2026-9740][cve-depth] concerns BSONColumn interleaved-reference validation:
mutual recursion resets depth tracking and can terminate unauthenticated
server processing. Its affected ranges are 7.0.0–before 7.0.35,
8.0.0–before 8.0.24, 8.2.0–before 8.2.10, and 8.3.0–before 8.3.3.
This is not a vulnerability claim about every BSON subtype implementation or
about `libbson`'s ordinary document iterator.

The transferable lesson is to carry one budget across nested parser boundaries,
including subtype decompression and embedded BSON validation. A byte-size limit
alone cannot bound all expanded work; resetting depth in a helper can bypass
an otherwise plausible nesting cap.

### Describing foreign formats

**N/A:** BSON specifies its own ordered-document grammar. Transporting foreign
bytes in subtype 0 does not describe those bytes' endian fields, offset bases,
alignment, or invariants. A custom subtype adds a second parser contract.

The [Flat draft][flat] instead describes existing layouts directly. BSON's
useful precedent is checked nested extents and borrowing, not a replacement
for a foreign-format layout proof.

### Implementation and performance evidence

The primary implementation inspected is [`mongo-c-driver`'s `libbson`][bson-c].
Its separate static initialization and validation APIs are concrete evidence
for borrowing and staged validation, not a measurement of parsing throughput.
The reference-tool probe confirms one 12-byte layout against an independent
upstream corpus vector.

No D BSON binding was verified here. Calling C from D is possible in principle,
but maintenance, error translation, lifetime annotations, allocation behavior,
and subtype support need an actual wrapper audit. No performance number or
`@nogc` guarantee is inferred from binary encoding alone.

## Strengths

- Nested byte extents enable cheap checked subtree skipping.
- Ordered documents and explicit database scalar types preserve useful detail.
- Independent driver corpus includes valid values and decode errors.
- Mature C source exposes borrowed views and separate validation.

## Weaknesses

- Field names, terminators, and decimal array indices add substantial overhead.
- Whole-document lengths complicate unknown-size streaming writers.
- Database semantics and binary subtype parsers enlarge the validation surface.
- No universal canonical semantic hash representation.

## Key design decisions and trade-offs

| Decision                              | Rationale                                  | Trade-off                                 |
| ------------------------------------- | ------------------------------------------ | ----------------------------------------- |
| Store total document byte length      | Skip/copy embedded documents cheaply       | Writers need lengths before finalization  |
| Use ordered named elements            | Preserve document order and field identity | Linear lookup without an external index   |
| Represent arrays as indexed documents | Reuse the document grammar                 | Per-element decimal-key overhead          |
| Retain distinct numeric types         | Database type fidelity                     | Equality and hashing need explicit policy |

## Sources

- [Official BSON 1.1 grammar][spec].
- [MongoDB BSON corpus][corpus], especially [integer vectors][int32].
- [Decimal128][decimal], [Extended JSON][extjson], and [vector subtype][vector].
- [`libbson` source][bson-c] and [MongoDB limits][limits].
- MongoDB CNA records for [overflow][cve-overflow] and [nested validation][cve-depth].

<!-- References -->

[spec]: https://bsonspec.org/spec.html
[license]: https://github.com/mongodb/specifications/blob/7235b61bde1bc75e51f28d8f67dd935198969c02/LICENSE.md
[corpus]: https://github.com/mongodb/specifications/blob/7235b61bde1bc75e51f28d8f67dd935198969c02/source/bson-corpus/bson-corpus.md
[int32]: https://github.com/mongodb/specifications/blob/7235b61bde1bc75e51f28d8f67dd935198969c02/source/bson-corpus/tests/int32.json
[decimal]: https://github.com/mongodb/specifications/blob/7235b61bde1bc75e51f28d8f67dd935198969c02/source/bson-decimal128/decimal128.md
[extjson]: https://github.com/mongodb/specifications/blob/7235b61bde1bc75e51f28d8f67dd935198969c02/source/extended-json/extended-json.md
[vector]: https://github.com/mongodb/specifications/blob/7235b61bde1bc75e51f28d8f67dd935198969c02/source/bson-binary-vector/bson-binary-vector.md
[bson-c]: https://github.com/mongodb/mongo-c-driver/blob/08fa1d2bfafea1bf2492aa55e6cca307e5983791/src/libbson/src/bson/bson.c
[bson-h]: https://github.com/mongodb/mongo-c-driver/blob/08fa1d2bfafea1bf2492aa55e6cca307e5983791/src/libbson/src/bson/bson.h
[limits]: https://www.mongodb.com/docs/manual/reference/limits/
[cve-overflow]: https://cveawg.mitre.org/api/cve/CVE-2025-0755
[cve-depth]: https://cveawg.mitre.org/api/cve/CVE-2026-9740
[writer]: https://github.com/nlohmann/json/blob/cd6b428ef087fb0ce06a7daaa547f71d2907e948/include/nlohmann/detail/output/binary_writer.hpp
[flat]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[ca]: ../content-addressing/concepts.md
[in-place]: ./concepts.md#in-place-access-and-zero-copy
