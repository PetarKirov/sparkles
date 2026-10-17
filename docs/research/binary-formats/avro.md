# Apache Avro (multi-language)

A schema-directed compact stream whose writer/reader schema resolution is part
of decoding, with separate envelopes for individual values and container files.

| Field           | Value                                                          |
| --------------- | -------------------------------------------------------------- |
| Language        | Java, C, C++, Python and other bindings                        |
| License         | Apache-2.0                                                     |
| Repository      | [apache/avro][repo]                                            |
| Documentation   | [Avro 1.12.0 specification][spec]                              |
| Category        | Schema-first sequential encoding with writer/reader resolution |
| Reviewed source | `3a207fa6e87c535b95eafca4cf5a6ef524d77df2`                     |

## Overview

### What it solves

Avro stores structured values compactly without repeating field tags or names.
The writer's schema supplies the information omitted from the datum. A distinct
reader's schema can project or evolve that datum through specified resolution
rules. Object container files carry the writer schema and block structure;
single-object encoding carries a schema fingerprint instead. [Specification][spec]

### Design philosophy

The [specification][spec] states:

> Binary encoded Avro data does not include type information or field names.

This is a different compactness bargain from [Protobuf][protobuf]. Avro does
not make each unknown field self-skippable from a tag. It gives the reader the
writer schema so that it can consume the entire structural sequence correctly.
The [shared concepts][concepts] and [comparison][comparison] distinguish that
external interpretation from self-description and native layout viewing.

## How it works

### Schema source of truth

A JSON schema defines primitives, records, enums, arrays, maps, unions and
fixed-size byte values. Namespaces and named references permit recursive types.
IDL and protocol tooling can produce those schemas, but the binary datum is
interpreted against the writer's schema, not a host compiler's object layout.
[Specification][spec]

```json
{
  "type": "record",
  "name": "test",
  "fields": [
    { "name": "a", "type": "long" },
    { "name": "b", "type": "string" }
  ]
}
```

This is the [specification's record example][spec]. Its field order is wire
significant. Schema resolution can match a differently ordered reader by name,
but that does not retroactively make the writer's order irrelevant.
The [serde catalog][serde] covers generic host-language schema abstractions;
Avro's writer/reader resolution is a particular wire-level contract.

### Wire encoding

`int` and `long` use ZigZag varints; booleans use one byte; `null` uses zero
bytes. Floating-point values use raw IEEE-754 bits in little-endian order.
Strings and byte arrays have a non-negative byte length encoded as a `long`,
then their payload. A record concatenates field values in writer-schema order.
Enums encode their symbol's zero-based index, not its spelling. [Specification][spec]

**Upstream reference vectors, not locally executed output:** the
[specification's Binary Encoding section][spec] supplies:

```text
string "foo":                   06 66 6f 6f
record {a: 27, b: "foo"}:       36 06 66 6f 6f
array<long> [3, 27]:            04 06 36 00
union ["null", "string"] "a":  02 02 61
```

The string's `06` is ZigZag encoding of length `3`; `36` encodes signed
integer `27`. The array starts with count `2`, encoded as `04`, and ends
with a zero block count. These labels are interpretations of upstream vectors,
not invented bytes from an unrun reference tool.

### Access model

The decoder walks the writer's schema depth-first, left-to-right. To find a
later variable-sized field, it consumes or skips earlier encodings. A resolving
decoder can reorder assignments and drop fields, but this is projection while
parsing, not constant-time access by a stored offset. [Specification][spec]

[`BinaryDecoder`][decoder] is concrete implementation evidence: it maintains
a buffer cursor, decodes variable integers, checks EOF and exposes operations
for reading and skipping strings and container blocks. A data-model reader
builds generic or generated objects above that interface.

Container-file synchronization markers permit splitting and resynchronization
at block boundaries. They do not provide random access to arbitrary fields
inside a datum or authenticate a block's content. [Specification][spec]

### Variable-length and optional data

Arrays and maps are sequences of blocks terminated by a zero count. A positive
count is followed by that many items; a negative count's absolute value is the
item count and is followed by the block's byte size. That size enables fast
skipping when projecting away the block. It also lets a writer stream a
collection without knowing its final count. [Specification][spec]

Nullable values use a union such as `["null", "string"]`. The datum first
encodes the selected branch index, then that branch's value. A missing writer
field is different: every writer-schema record field has an encoding, even
when that encoding is zero bytes. Defaults fill reader fields absent from the
writer schema; they do not authorize a writer to omit its own field bytes.
[Specification][spec]

A `fixed` value contains exactly its schema-declared number of bytes, without
a length prefix. That is useful for digests but does not define their hash
algorithm or meaning. Logical types annotate underlying encodings; they do not
replace the underlying binary framing. [Specification][spec]

### Evolution and compatibility

Resolution has two inputs: the writer's schema and the reader's schema.
Record fields match by name; unmatched writer fields are skipped; unmatched
reader fields require defaults or produce an error. Allowed promotions include
`int` to `long`, `float` or `double`, and `float` to `double`. Union resolution
selects a compatible branch according to specified ordering. [Specification][spec]

Aliases and defaults therefore affect reading semantics even when parsing can
proceed without them. A schema fingerprint that identifies parsing structure
is not a complete identifier of every application's resolution policy.
[`SchemaNormalization`][normalization] implements parsing normalization,
while [`ResolvingDecoder`][resolving] serves the resolution layer.

The [draft Flat arena's][flat-draft] `WFL54` instead rejects a version/layout mismatch and
expects a cache rebuild. Avro is the useful counterexample when data must
outlive or cross the build that produced its reader: compatibility requires
explicit resolution semantics, not only a new digest and version.

### Determinism and canonical form

Avro specifies **Parsing Canonical Form for schemas**, not one canonical byte
encoding for all equivalent data. Normalization expands names, removes
non-parsing attributes, orders JSON object attributes and eliminates irrelevant
whitespace. It preserves record field and enum symbol order because those
affect decoding. [Specification][spec], [normalization implementation][normalization]

The distinction matters. An array can be divided into different legal blocks;
maps need not have a single key order. Container files additionally choose
block boundaries, codecs, metadata and synchronization markers. Identical
decoded records do not force identical complete files. [Specification][spec]

The schema's canonical form strips attributes including aliases and defaults.
It should not be mistaken for a full canonical description of evolution policy.
Similarly, the draft Flat builder's `WFL49` determinism is about a fixed call
sequence, not normalization of all equivalent graphs.

### Merkleization and content addressing

**N/A as a built-in content graph:** Avro specifies schema fingerprints and
file synchronization, but not cryptographic links between application objects.
The single-object envelope is marker `c3 01`, an eight-byte little-endian
`CRC-64-AVRO` schema fingerprint, then a binary datum. That fingerprint names
the schema, not the datum and not its integrity. [Specification][spec]

The specification explicitly says schema fingerprints provide no security
guarantees, even when using a longer hash. A registry lookup requires its own
trust/collision policy. Content addressing must separately bind schema identity,
encoding profile and data bytes, or define canonical value semantics.
See the [content-addressing catalog][cas] for those additional contracts.

### Hostile-input safety

Omitting tags does not remove malformed-input work. Lengths, block counts,
union indices, enum indices and schema recursion are all attacker-controlled
interpretation boundaries. [`BinaryDecoder`][decoder] bounds varint widths and
checks cursor movement against EOF; those checks are implementation behavior,
not a promise that a whole decoded object graph has bounded allocation.

The reviewed Java tree has [`SystemLimitException`][limits] controls for bytes,
strings, collection item counts, collection allocation and decompressed length.
Its collection-allocation logic specifically considers schemas whose elements
can consume **zero encoded bytes**. A small encoded list can otherwise request
large logical work or object allocation.

That is directly relevant to the draft `WFL24` rule charging at least one byte
per visited element: bounds must follow work, not merely physical byte extent.
The Java controls are source evidence for that category of defense; this page
does not claim identical defaults or protection in every Avro binding.

Container compression adds another budget: the compressed block's length alone
does not bound decompressed size. [`SystemLimitException`][limits] makes that
dimension explicit. Authentication remains external to the Avro encoding.

### Describing foreign formats

**N/A for arbitrary byte layouts:** an Avro record follows Avro encodings in
schema order. It cannot declare a packed, big-endian integer at an arbitrary
offset, a table-relative pointer or version-selected fixed-layout tail.
Wrapping a font in `bytes` preserves it but does not describe it. [Specification][spec]

The draft Flat proposal addresses that foreign-layout gap using declared
endianness, counts and offset bases. Avro's advantage is different: it supplies
resolution and streaming data framing rather than pretending to be a universal
layout-description language.

### Implementation and performance evidence

Two **third-party** D implementations illustrate why a package name does not
establish feature parity. [`vnayar/avro-d`][d-avro] advertises schema parsing,
generic data and binary/JSON codecs, but lists schema resolution, object
containers, compression, logical types, generated specific types and RPC wire
support as unimplemented. [`sdv4day/avro-d`][d-avro-sdv] advertises those
additional facilities, including null/deflate compression. These are README
claims, not verified conformance or performance findings; neither library
was built here. The independent D invariant below exercises neither binding.

The [Java decoder][decoder], [resolving decoder][resolving] and
[schema normalizer][normalization] expose the mechanics behind the specification.
They are stronger evidence than treating the word "binary" as a speed claim.
The checked source tree also contains [explicit allocation limits][limits].

No Java build, reference encoder or benchmark was executed for this page.
The four hex examples are labeled upstream specification vectors. They prove
neither a throughput ranking nor the cost of schema resolution, decompression
or generic-object construction on Sparkles' target hardware.

This **independent invariant check**, not an Avro implementation or reference
encoder run, checks the published record vector's ZigZag integer, string
length and payload. It intentionally assumes the example's known schema.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "binary_avro_invariant"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : writeln;

void main() @safe
{
    immutable ubyte[5] bytes = [0x36, 0x06, 0x66, 0x6F, 0x6F];
    const a = (cast(int) bytes[0] >> 1) ^ -(cast(int) bytes[0] & 1);
    const length = bytes[1] >> 1;
    assert(a == 27 && length == 3 && 2 + length == bytes.length);
    assert(bytes[2 .. $] == [0x66, 0x6F, 0x6F]);
    writeln("a=", a, " string-bytes=", length, " record-bytes=", bytes.length);
}
```

```ansi
a=27 string-bytes=3 record-bytes=5
```

## Strengths

- Compact data with no per-field names or type tags. [Specification][spec]
- Explicit writer/reader resolution supports long-lived heterogeneous datasets.
- Blocked collections and container files support streaming and projection.
- Schema normalization/fingerprinting is specified rather than ad hoc.

## Weaknesses

- A datum is uninterpretable without its writer schema or a trusted lookup.
- Variable-width sequential fields do not provide general constant-time indexing.
- Schema canonicalization does not imply canonical data or file bytes.
- Logical allocation, schema depth and decompression need independent limits.

## Key design decisions and trade-offs

| Decision                    | Rationale                                       | Trade-off                                            |
| --------------------------- | ----------------------------------------------- | ---------------------------------------------------- |
| Omit per-field tags         | Compact sequential encoding                     | Writer schema must accompany interpretation          |
| Resolve two schemas         | Evolve stored data and readers independently    | Resolution is a decoding operation                   |
| Block arrays/maps           | Stream unknown-size collections and skip blocks | Multiple legal byte representations                  |
| Fingerprint parsing schemas | Compact schema cache/lookup identity            | Not content integrity or complete evolution identity |

## Sources

- [Avro 1.12.0 specification, including the cited binary vectors][spec].
- [Java binary decoder][decoder] and [resolving decoder][resolving].
- [Parsing normalization implementation][normalization] and [resource limits][limits].

<!-- References -->

[repo]: https://github.com/apache/avro/tree/3a207fa6e87c535b95eafca4cf5a6ef524d77df2
[spec]: https://github.com/apache/avro/blob/3a207fa6e87c535b95eafca4cf5a6ef524d77df2/doc/content/en/docs/1.12.0/Specification/_index.md
[decoder]: https://github.com/apache/avro/blob/3a207fa6e87c535b95eafca4cf5a6ef524d77df2/lang/java/avro/src/main/java/org/apache/avro/io/BinaryDecoder.java
[resolving]: https://github.com/apache/avro/blob/3a207fa6e87c535b95eafca4cf5a6ef524d77df2/lang/java/avro/src/main/java/org/apache/avro/io/ResolvingDecoder.java
[normalization]: https://github.com/apache/avro/blob/3a207fa6e87c535b95eafca4cf5a6ef524d77df2/lang/java/avro/src/main/java/org/apache/avro/SchemaNormalization.java
[limits]: https://github.com/apache/avro/blob/3a207fa6e87c535b95eafca4cf5a6ef524d77df2/lang/java/avro/src/main/java/org/apache/avro/SystemLimitException.java
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[serde]: ../serde/index.md
[protobuf]: ./protobuf.md
[cas]: ../content-addressing/index.md
[flat-draft]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
[d-avro]: https://github.com/vnayar/avro-d/blob/f0f199082eb7a6d725eb73b53ac7911f2e1cc847/README.md
[d-avro-sdv]: https://github.com/sdv4day/avro-d/blob/7e1feb0b9cc8b2316ed8f8467a1e6a5698513ff2/README.md
