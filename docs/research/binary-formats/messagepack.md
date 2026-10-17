# MessagePack (Language-neutral)

A compact, self-describing value stream whose small headers simplify interchange,
but do not by themselves define a canonical object representation.

| Field              | Value                                                          |
| ------------------ | -------------------------------------------------------------- |
| Language           | Language-neutral specification; verified D implementation      |
| License            | Specification carries author copyright; `msgpack-d`: Boost-1.0 |
| Repository         | [MessagePack specification][spec] · [`msgpack-d`][d-readme]    |
| Documentation      | [Type system and encoding specification][spec]                 |
| Category           | Self-describing, sequential, tagged value encoding             |
| Application schema | External convention; no required IDL                           |

## Overview

### What it solves

MessagePack exchanges JSON-like values without decimal number parsing, string
escaping, or repeating verbose scalar syntax. It adds byte strings, arbitrary
map-key values, and typed extension payloads. A decoder can discover the value
shape without a generated schema, but cannot infer business meaning from the
bytes alone ([type system][spec]).

This is an interchange codec, not a record-layout description language. Its
useful comparison with the other systems is in [the synthesis][comparison];
shared terminology belongs in [concepts][concepts].

### Design philosophy

The specification explicitly separates values from representations:

> Serialization is conversion from application objects into MessagePack formats via MessagePack type system.

That sentence in [`spec.md`][spec] matters: an integer is a logical value,
whereas `fixint`, `uint16`, and `int64` are possible representations. Decoding
usually erases the representation choice. A round trip is therefore not
necessarily byte-preserving.

## How it works

The first byte selects a family. Small positive integers, negative integers,
short strings, short arrays, and short maps embed data or counts in that byte.
Larger forms add a fixed-width, big-endian length or number. Containers then
contain consecutive child encodings, with no offset table ([formats][spec]).

| Family            | Representative bytes | Meaning                           |
| ----------------- | -------------------- | --------------------------------- |
| Positive `fixint` | `00`–`7f`            | Integer 0–127                     |
| Negative `fixint` | `e0`–`ff`            | Integer −32–−1                    |
| `fixmap`          | `80`–`8f`            | 0–15 key/value pairs              |
| `fixarray`        | `90`–`9f`            | 0–15 elements                     |
| `fixstr`          | `a0`–`bf`            | 0–31 UTF-8 bytes                  |
| `nil`, booleans   | `c0`, `c2`, `c3`     | No payload                        |
| Binary            | `c4`, `c5`, `c6`     | 8-, 16-, 32-bit byte count        |
| Float             | `ca`, `cb`           | IEEE binary32 or binary64 payload |
| Extension         | `c7`–`c9`, `d4`–`d8` | Type identifier plus opaque bytes |

`c1` is unused; it is not a generic escape for arbitrary future data. Array
lengths count elements and map lengths count pairs, not payload bytes. The
largest ordinary string/binary length and container count are `2^32−1`; the
integer domain is `−2^63` through `2^64−1` ([limitations][spec]).

**Locally executed reference-tool probe.** A C++17 harness compiled against
[`nlohmann/json` at the pinned revision][writer] called `json::to_msgpack`
for `{"i":1}` and `1.5`. Its output was:

```text
object: 81 a1 69 01
float:  ca 3f c0 00 00
```

The object is one pair, one-byte key `i`, then integer 1. The float uses
binary32 because this implementation can represent `1.5` exactly that way.
These are observed encoder choices, not evidence that all conforming writers
produce those bytes. No throughput measurement was performed.

**Portable CI invariant check.** This independently checks the observed object
header, key extent, and float payload bits, including every truncated object
prefix. It is a deliberately narrow fixture checker, not a MessagePack codec
or another execution of the upstream C++ encoder.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "research_messagepack_vector"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : writeln;

bool matchesFixture(in ubyte[] bytes) @safe pure nothrow @nogc
{
    if (bytes.length < 2 || bytes[0] != 0x81 || bytes[1] != 0xa1)
        return false;
    immutable size_t keyStart = 2;
    immutable size_t keyBytes = bytes[1] & 0x1f;
    if (keyBytes > bytes.length - keyStart)
        return false;
    immutable valueAt = keyStart + keyBytes;
    return valueAt < bytes.length && bytes.length - valueAt == 1
        && bytes[keyStart] == 'i' && bytes[valueAt] == 1;
}

void main() @safe
{
    immutable ubyte[] object = [0x81, 0xa1, 0x69, 0x01];
    immutable ubyte[] floating = [0xca, 0x3f, 0xc0, 0x00, 0x00];
    assert(matchesFixture(object));
    foreach (end; 0 .. object.length)
        assert(!matchesFixture(object[0 .. end]));
    assert(floating[0] == 0xca && floating.length == 1 + uint.sizeof);
    uint bits;
    foreach (part; floating[1 .. $])
        bits = (bits << 8) | part;
    assert(bits == 0x3fc00000); // IEEE binary32 1.5, big-endian payload.
    writeln("MessagePack: one pair, bounded key, binary32 bits, truncations rejected");
}
```

```ansi
MessagePack: one pair, bounded key, binary32 bits, truncations rejected
```

### Schema source of truth

The type-system specification is the source of syntax and generic values.
Application records are typically mapped to maps or arrays by a language codec.
The map choice preserves names; the array choice makes position part of the
application contract. Neither choice is a universal MessagePack struct schema.

[`msgpack-d`][d-readme] derives packing from D declarations and offers
`@nonPacked`, custom registered handlers, and `@serializedAs`. Those are
binding policies, not MessagePack wire features. A schema adapter must record
them rather than assume another implementation makes the same choices.

### Wire encoding

`uint16` is `cd` plus two big-endian bytes; `int16` is `d1` plus a
two's-complement payload. Float payloads are also big-endian. There is no
alignment padding and no host-ABI interpretation ([integer and float families][spec]).

Extension types use a signed 8-bit identifier. Applications own `0`–`127`;
negative identifiers are reserved for predefined extensions. Fixed extension
forms carry 1, 2, 4, 8, or 16 payload bytes; variable forms carry a length and
then the type byte. Unknown extensions can remain opaque without losing their
type number or payload ([extension types][spec]).

The predefined timestamp uses type `−1`: 32-bit unsigned seconds; 64 bits
split into 30 nanosecond bits and 34 second bits; or 96 bits containing
32-bit nanoseconds followed by signed 64-bit seconds. Nanoseconds above
999,999,999 are invalid. These are three encodings, not three unrelated
application date types ([timestamp][spec]).

### Access model

Access is sequential parsing. Skipping a string is cheap after its length is
known; skipping a container requires walking its children because its header
does not contain the byte extent. Looking up a late map key requires scanning
earlier pairs unless an implementation builds an index.

Borrowing a contiguous string/binary slice is possible, but does not turn a
heterogeneous map into an [in-place view][in-place]. Integer and float headers
still need decoding, and variable-width preceding values still determine later
positions. This distinction is important when comparing a serialization codec
with fixed-layout foreign-format readers.

### Variable-length and optional data

Every ordinary string, binary payload, array, and map has a declared length.
There is no indefinite-length container or break marker. Writers with unknown
counts need buffering, counting, backpatching into a seekable destination, or
an application-level stream of independent values ([formats][spec]).

`nil` is explicit null-like data. An absent map entry is different from a
present entry holding `nil`; the application determines defaults and required
fields. An array encoding has no implicit absent slot: dropping an element
shifts positions unless the application uses a fixed sentinel convention.

### Evolution and compatibility

Map-based records can admit unknown fields and default missing fields, but
that behavior belongs to the record decoder. Array-based records require a
versioned positional convention. Extension identifiers are only useful when
their payload contracts are shared; arbitrary reuse of application type 0
does not establish interoperability.

The specification's upgrade guidance covers the historical raw/string/binary
split and `str8`: readers gain support before writers use the new forms, and
compatibility mode avoids unsupported output. That is concrete evidence that
self-description does not remove deployment compatibility work ([upgrade guidance][spec]).

### Determinism and canonical form

The specification says:

> If an object can be represented in multiple possible output formats, serializers SHOULD use the format which represents the data in the smallest number of bytes.

This is a recommendation, not a canonical validation rule. Its proposed
profile discussion mentions sorting map keys for digests, but does not define
a complete key ordering or cross-language equivalence relation ([conversion and profiles][spec]).

For integer 1, `01`, `cc 01`, and `d1 00 01` all decode to the same
integer. Float 1.5 has both binary32 and binary64 encodings. A hash profile
must additionally settle signed zero, NaN payloads, integer-versus-float
equivalence, extension normalization, text validity, and map ordering.

Duplicate map keys have no normative conflict-resolution algorithm in the
base specification. A decoder that inserts into a native dictionary may lose
pairs or conflate keys. Reject duplicates before insertion for security-sensitive
profiles; never infer a portable first-wins or last-wins contract.

### Merkleization and content addressing

**N/A as a built-in feature:** there are no digest fields, authenticated links,
chunk boundaries, or proof rules. Hashing one encoded value identifies those
exact bytes, not a universal MessagePack logical value ([formats][spec]).

A content-addressed application can impose a profile and encode child digests
as byte strings or extensions. It must define domain separation, hash algorithm,
link semantics, and the allowed value domain itself. Those additions are a
new protocol, not capabilities supplied by the map header.

Deterministically iterating one implementation's map is weaker than canonical
encoding across implementations. Sorting alone is insufficient if one writer
keeps `−0.0` and another changes it to `0`, or if an extension has multiple
equivalent payload spellings. See the [content-addressing vocabulary][ca].

### Hostile-input safety

The wire's 32-bit maximum lengths are not reasonable allocation limits.
Reject counts above application limits before reserving memory, check length
against remaining bytes, and avoid computing `2 * mapCount` in 32 bits.
A tiny `map32` header can request billions of pairs without containing them.

Budget nesting, total decoded nodes, cumulative copied bytes, and duplicate-key
work separately. Unknown-field skipping still consumes work. Nested singleton
arrays exhaust recursive decoders even when each header is one byte. Hash-table
collision behavior and composite-key comparison can add costs beyond traversal.

The specification explicitly permits invalid string byte sequences and leaves
decoder behavior implementation-dependent; a security profile must choose
rejection or raw-byte preservation, not silently normalize inconsistently
([limitations][spec]). Validate timestamp ranges and extension payloads at
their semantic boundary. No format-wide CVE claim is made here.

### Describing foreign formats

**N/A:** MessagePack defines its own grammar. A custom pack handler can map a
foreign structure into MessagePack, but cannot make an existing OpenType or
network packet layout become MessagePack without changing bytes.

Opaque binary payloads can transport foreign bytes, but bounds, byte order,
offset bases, checksums, and graph traversal remain another parser's job.
This is categorically different from declaratively describing fields at
existing offsets, the concern motivating the Flat draft.

### Implementation and performance evidence

The verified D option is [`msgpack-d`][d-readme], whose source exposes
[`Unpacker`][d-unpack] and [`StreamingUnpacker`][d-stream]. Its README claims
zero-copy operation and high performance; these are upstream claims, not
benchmarks reproduced for this survey. Its warning that D `real` is not
interoperable should be treated as a hard boundary when designing a portable
profile.

The C++ probe establishes actual layout for one object and one float only.
It does not establish `@safe`, `@nogc`, hostile-input resilience, extension
coverage, or equivalence of D and C++ defaults. Before adopting a D codec,
measure allocations and borrowing lifetimes and run cross-implementation
fixtures for missing fields, overflow, duplicate keys, and timestamps.

## Strengths

- Compact small values and cheap first-byte dispatch ([formats][spec]).
- No required schema compiler; opaque extension forwarding is possible.
- Verified pure-D implementation and explicit streaming API exist.

## Weaknesses

- No base canonical profile or duplicate-key conflict policy.
- Container counts do not provide direct subtree byte extents.
- Unknown-size containers are not directly streamable as one container.
- String validity and application extension meanings need extra agreements.

## Key design decisions and trade-offs

| Decision                             | Rationale                       | Trade-off                                  |
| ------------------------------------ | ------------------------------- | ------------------------------------------ |
| Embed small lengths/integers in tags | Reduce common-case bytes        | Many equivalent representation families    |
| Count containers, omit offset tables | Simple sequential grammar       | Late field lookup requires traversal       |
| Signed extension namespace           | Add application-specific values | Payload interoperability is out of band    |
| Recommend shortest output            | Encourage compactness           | Does not establish canonical hash identity |

## Sources

- [MessagePack specification][spec]: value model, complete wire tables, extensions.
- [`msgpack-d` source and README][d-readme]: verified D implementation scope.
- [`nlohmann/json` binary writer][writer]: locally executed probe implementation.

<!-- References -->

[spec]: https://github.com/msgpack/msgpack/blob/8aa09e2a6a9180a49fc62ecfefe149f063cc5e4b/spec.md
[d-readme]: https://github.com/msgpack/msgpack-d/blob/26ef07e16023483ad93e3f86374b19d0e541c924/README.markdown
[d-unpack]: https://github.com/msgpack/msgpack-d/blob/26ef07e16023483ad93e3f86374b19d0e541c924/src/msgpack/unpacker.d
[d-stream]: https://github.com/msgpack/msgpack-d/blob/26ef07e16023483ad93e3f86374b19d0e541c924/src/msgpack/streaming_unpacker.d
[writer]: https://github.com/nlohmann/json/blob/cd6b428ef087fb0ce06a7daaa547f71d2907e948/include/nlohmann/detail/output/binary_writer.hpp
[comparison]: ./comparison.md
[concepts]: ./concepts.md
[ca]: ../content-addressing/concepts.md
[in-place]: ./concepts.md#in-place-access-and-zero-copy
