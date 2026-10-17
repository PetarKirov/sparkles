# Apache Thrift (multi-language)

A schema compiler and RPC stack with interchangeable protocols; its Binary and
Compact encodings are tagged streams, not fixed-layout views.

| Field           | Value                                                   |
| --------------- | ------------------------------------------------------- |
| Language        | Multi-language compiler and runtimes, including D       |
| License         | Apache-2.0                                              |
| Repository      | [apache/thrift][repo]                                   |
| Documentation   | [Binary protocol][binary] · [Compact protocol][compact] |
| Category        | Schema-first RPC and tagged serialization               |
| Reviewed source | `f95a92969ed452347529c2e00e1d335528db4e57`              |

## Overview

### What it solves

Thrift generates interoperable clients, servers and data types from one IDL.
Its protocol abstraction separates value serialization from the transport
carrying it. A message's semantic definition is therefore not tied to one
encoding or socket implementation. The [upstream introduction][intro] describes
transport, serialization and application processing as distinct layers.

### Design philosophy

The [upstream introduction][intro] says:

> Thrift is specifically designed to support non-atomic version changes
> across client and server code.

Stable field identities and unknown-field skipping serve rolling upgrades.
The cost is that a reader parses a protocol stream into application values;
it cannot substitute a native record reference for that interpretation.
See the [shared concepts][concepts] and [comparison][comparison] for the
catalog's distinction between those access models.

## How it works

### Schema source of truth

The IDL declares numbered fields, primitive/container types, structs, unions,
exceptions and services. Generated code supplies the schema-specific decisions;
the protocol supplies operations such as field begin, list begin and scalar
read/write. [`TProtocol` in the D runtime][d-base] exposes that abstraction.

```thrift
struct Sample {
  1: optional i32 count
  2: optional string label
}
```

This illustrative declaration gives the fields wire identities `1` and `2`.
The names help generated APIs but are not the binary field identifiers.
Changing a host field's spelling is different from reassigning its ID.
The [Binary][binary] and [Compact][compact] specifications make that distinction.

The [serde catalog][serde] covers host-language schema/framework expressiveness;
this page concentrates on what Thrift's wire protocols require.

### Wire encoding

Binary writes a field's type byte, signed 16-bit field ID and payload, ending
a struct with a `STOP` type. Fixed-width integers use network byte order;
strings/binary carry a signed 32-bit non-negative length. Lists/sets have an
element type and count; maps have key/value types and count. [Binary][binary]

Compact packs a small positive field-ID delta into the high nibble of a
header byte, with the compact type in the low nibble. If the delta does not
fit, the full field ID follows in ZigZag-varint form. Signed integer values
use ZigZag then varints. Binary/string lengths are unsigned varints, not
ZigZag lengths. [Compact][compact]

Compact folds a struct field's boolean value into the field header. Boolean
container elements instead use byte values `1` and `2`. Small list counts
share their header with the element type; larger counts have an extra varint.
An empty map has a special zero count without a key/value-type byte.
These are protocol rules, not optional per-writer compression choices.

**Upstream reference vector, not a local encoder run:** the [Compact
specification's varint example][compact] encodes the unsigned integer `50399` as:

```text
df 89 03
```

This is the raw varint example, **not** a complete `i32` field: a signed
`i32` would first undergo ZigZag and a struct field would need its header.
The distinction prevents borrowing a mathematically correct byte sequence
and labeling it as the wrong reference-tool output.

### Access model

Protocols consume a transport cursor and build values through generated code.
Variable-width headers and containers mean locating a later field normally
requires scanning prior entries. Skipping an unknown field also consumes its
structure recursively; this is not an indexed random-access table.
See the [protocol interface][d-base] and [D Binary implementation][d-binary].

An RPC message adds method name, message type and sequence ID around its
argument/result struct. Strict Binary headers contain a version marker;
the older unversioned envelope is accepted only when the runtime's strict-read
policy permits it. Compact uses protocol ID `0x82` and version `1`.
Transport framing is a separate concern. [Binary][binary], [Compact][compact]

### Variable-length and optional data

Container counts and string lengths come from the wire. An optional field is
omitted when absent, not represented by a native nullable pointer in the
encoding. Union encoding is structurally a struct with at most one field;
exceptions use the struct encoding as well. [Compact][compact]

Binary container payloads preserve the logical sequence of list elements.
Sets and maps do not acquire a global canonical iteration order merely
because their counts are explicit. The protocol describes the emitted sequence,
not a sorting rule for all possible host containers. [Binary][binary]

The D Binary implementation exposes `containerSizeLimit` and `stringSizeLimit`.
They limit different dimensions: a huge collection of tiny elements is not
the same resource problem as one huge string. [`binary.d`][d-binary]

### Evolution and compatibility

Unknown numbered fields can be skipped because the protocol supplies a type.
Adding an optional field therefore permits an old reader to continue reading
known fields. A required field creates a stronger reader obligation and is
not a free additive change. [IDL reference][idl]

Field type changes and number reuse remain dangerous. The protocol's ability
to find a field boundary does not prove semantic compatibility. Generated-code
and runtime behavior must agree about accepted types, missing required values
and union constraints. The [protocol descriptions][binary] explicitly qualify
some observations as based on older Java implementations; those observations
must not be generalized into a guarantee for every binding.

Unlike the [draft Flat arena's][flat-draft] `WFL54` layout pin and reject/rebuild policy,
Thrift's compatibility mechanism is designed for peers running different
schema versions. Rebuild-only caches and long-lived RPC contracts have
different requirements, even when both use a version identifier.

### Determinism and canonical form

**N/A as a protocol-wide canonical form:** Binary and Compact permit fields
in arbitrary order, identified by number. The same logical struct can have
different legal encodings; Compact's delta headers also depend on that order.
Neither cited protocol defines a normalization of map ordering, duplicate
fields, floating-point encodings and presence into one semantic byte image.
[Binary][binary], [Compact][compact]

A particular generated writer can be repeatable without that becoming a
cross-language canonical encoding. A profile for signing would need to choose
a protocol, constrain order and presence, and define value equivalence.
The draft Flat builder's `WFL49` repeatability has the same logical boundary:
same construction sequence is weaker than canonical bytes for equivalent data.

### Merkleization and content addressing

**N/A in the wire protocols:** field IDs and RPC sequence IDs are not content
digests. Neither Binary nor Compact defines cryptographic child references,
chunking or Merkle verification. Such a graph belongs to an application
schema and its hashing profile. [Protocol specification][protocol]

An exact serialized blob can be hashed, but changing protocol, map iteration
or field order can change the hash without changing the decoded values.
See the [content-addressing catalog][cas] for applications that explicitly
define byte identities rather than assuming serialization provides them.

### Hostile-input safety

Readers must reject negative lengths, excessive counts, truncated payloads
and malformed varints before using them to allocate or iterate. The D Binary
implementation checks size limits and throws `TProtocolException`; it is not
an error-as-value, allocation-free API. [`binary.d`][d-binary]

The [D protocol base][d-base] gives recursive `skip` and generated struct
read/write paths a shared thread-local depth budget of `64`, with scope-exit
decrement and a `DEPTH_LIMIT` exception. Its default string and container
ceilings are `16,384,000`; zero or negative explicitly disables these size
ceilings. These concrete D defaults must not be generalized to every binding.

The draft Flat proposal's `WFL24` counts record/array/string work with an explicit
depth policy. A Thrift port must audit analogous work performed by protocol
skip paths and generated decoders, not assume that an outer frame's byte limit
bounds recursion or aggregate allocation.

> [!WARNING]
> The Binary protocol prose contains an old statement grouping Compact doubles
> with big-endian encoding. The [Compact specification][compact] explicitly says
> little-endian, and the [D Compact source][d-compact] is the implementation
> evidence to consult. Do not propagate the Binary document's sentence as a
> cross-protocol rule.

### Describing foreign formats

**N/A for arbitrary fixed layouts:** the IDL chooses Thrift types, not existing
byte offsets, field alignment or offset bases. Selecting Binary versus Compact
changes a protocol implementation; it does not let a schema describe a packed
OpenType table. [Protocol interface][d-base]

Adding a custom protocol can produce another representation of Thrift's data
model, but a general foreign-format reader needs vocabulary for structural
facts that this IDL does not carry. The draft Flat proposal targets those facts
directly and deliberately excludes general stream codecs.

### Implementation and performance evidence

There is a genuine upstream D implementation, not merely a proposed third-party
port: [`lib/d/README.md`][d-readme], [Binary][d-binary], [Compact][d-compact]
and [`serialization_benchmark.d`][d-bench] provide source and a workload.
That presence is evidence of an implementation; it does not establish modern
`@safe pure nothrow @nogc` compatibility or a maintained performance advantage.

No Thrift compiler or benchmark was executed for this page. The hex sequence
above is precisely the Compact specification's raw-varint vector. The
benchmark source is cited as reproducible upstream methodology, with no
invented throughput figures or comparisons to the draft Flat reader.

This **independent invariant check** checks the documented raw-varint payload
groups. It is not a signed Thrift field decoder or a reference-runtime run;
it deliberately performs neither ZigZag nor field-header decoding.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "binary_thrift_invariant"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : writeln;

void main() @safe
{
    immutable ubyte[3] bytes = [0xDF, 0x89, 0x03];
    const value = (bytes[0] & 0x7F) | ((bytes[1] & 0x7F) << 7)
        | ((bytes[2] & 0x7F) << 14);
    assert((bytes[0] & 0x80) && (bytes[1] & 0x80));
    assert((bytes[2] & 0x80) == 0 && value == 50399);
    writeln("raw-varint=", value, " bytes=", bytes.length);
}
```

```ansi
raw-varint=50399 bytes=3
```

## Strengths

- One IDL covers data and RPC services. [Introduction][intro]
- Numbered fields enable rolling upgrades and unknown-field skipping.
- Binary/Compact offer different size/CPU trade-offs behind one protocol API.
- Upstream D runtime and serialization benchmark are available. [D runtime][d-readme]

## Weaknesses

- A parsed stream, not random access to verified fields in a wire image.
- Protocol choice is part of interoperability; "Thrift bytes" is underspecified.
- Runtime limit and error behavior varies by binding and path.
- No universal canonical representation or built-in content graph.

## Key design decisions and trade-offs

| Decision                        | Rationale                             | Trade-off                                         |
| ------------------------------- | ------------------------------------- | ------------------------------------------------- |
| Separate protocol and transport | Reuse generated application contracts | Deployments must agree on both layers             |
| Numbered typed fields           | Skip unknown schema additions         | Parsing headers and payload boundaries costs work |
| Compact delta/varint encoding   | Reduce common field/integer sizes     | More state and variable-width decoding            |
| Struct-like union encoding      | Reuse protocol machinery              | Cardinality validity needs schema-aware checking  |

## Sources

- [Upstream introduction][intro] and [IDL reference][idl].
- [Binary][binary], [Compact][compact] and [protocol specification][protocol].
- [D runtime overview][d-readme], [Binary][d-binary], [Compact][d-compact]
  and [serialization benchmark][d-bench].

<!-- References -->

[repo]: https://github.com/apache/thrift/tree/f95a92969ed452347529c2e00e1d335528db4e57
[intro]: https://github.com/apache/thrift/blob/f95a92969ed452347529c2e00e1d335528db4e57/README.md
[binary]: https://github.com/apache/thrift/blob/f95a92969ed452347529c2e00e1d335528db4e57/doc/specs/thrift-binary-protocol.md
[compact]: https://github.com/apache/thrift/blob/f95a92969ed452347529c2e00e1d335528db4e57/doc/specs/thrift-compact-protocol.md
[protocol]: https://github.com/apache/thrift/blob/f95a92969ed452347529c2e00e1d335528db4e57/doc/specs/thrift-protocol-spec.md
[idl]: https://thrift.apache.org/docs/idl
[d-readme]: https://github.com/apache/thrift/blob/f95a92969ed452347529c2e00e1d335528db4e57/lib/d/README.md
[d-base]: https://github.com/apache/thrift/blob/f95a92969ed452347529c2e00e1d335528db4e57/lib/d/src/thrift/protocol/base.d
[d-binary]: https://github.com/apache/thrift/blob/f95a92969ed452347529c2e00e1d335528db4e57/lib/d/src/thrift/protocol/binary.d
[d-compact]: https://github.com/apache/thrift/blob/f95a92969ed452347529c2e00e1d335528db4e57/lib/d/src/thrift/protocol/compact.d
[d-bench]: https://github.com/apache/thrift/blob/f95a92969ed452347529c2e00e1d335528db4e57/lib/d/test/serialization_benchmark.d
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[serde]: ../serde/index.md
[cas]: ../content-addressing/index.md
[flat-draft]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
