# Protocol Buffers (multi-language)

A field-numbered interchange encoding that buys independent schema evolution by
parsing tagged values, not by making the wire image a native object layout.

| Field           | Value                                                  |
| --------------- | ------------------------------------------------------ |
| Language        | C++, Java, Python and other generated/runtime bindings |
| License         | BSD-3-Clause; see [license][license]                   |
| Repository      | [protocolbuffers/protobuf][repo]                       |
| Documentation   | [Encoding][encoding] and [security contract][security] |
| Category        | Schema-first tagged message encoding                   |
| Reviewed source | `5a89c084a0c055b21804acd8eae5bfc8e5ba9e28`             |

## Overview

### What it solves

Protocol Buffers separates an application's message contract from its language's
object representation. A `.proto` declaration assigns stable numbers to fields;
generated code handles parsing, serialization and language-specific access.
Unknown fields can survive a relay that does not understand their meaning.
This is an interchange contract, rather than a description of arbitrary existing
binary files. The [encoding guide][encoding] specifies the wire mechanics.

### Design philosophy

The [encoding guide][encoding] states:

> Protobuf parsers must be able to parse fields in any order.

That commitment explains both compatibility and the absence of a universal
byte identity. Fields are located by tags while parsing, rather than by offsets
proven from a host declaration. The same field can occur more than once; its
declared cardinality determines whether occurrences replace, merge or append.
The [shared concepts][concepts] and [comparison][comparison] distinguish those
properties from in-place access and canonicalization.

## How it works

### Schema source of truth

The `.proto` file supplies field numbers, logical types, cardinality and message
relationships. The wire tag supplies only a number and a coarse wire type.
`LEN` does not reveal whether its payload is text, bytes, a packed numeric list
or another message. A schema-free dumper therefore cannot reliably recurse into
every length-delimited payload. See the [wire guide][encoding] and
[`descriptor.proto`][descriptor] for the schema's own representation.

```proto
message Test1 {
  int32 a = 1;
}
```

This is the official guide's example, not a proposed D API. D reflection can
generate an adapter, but that adapter must preserve Protobuf field identities
and semantics; host field order alone is not the wire contract.
Framework expressiveness is covered separately in the [serde catalog][serde].

### Wire encoding

A tag is the unsigned varint `(field_number << 3) | wire_type`.
Types `0`, `1`, `2` and `5` mean varint, eight-byte scalar, length-delimited
payload and four-byte scalar. Types `3` and `4` delimit deprecated groups.
The fixed-width scalars are little-endian. Varints use seven payload bits per
byte with a high continuation bit. [`wire_format_lite.h`][wire] implements
the low-level operations described by the [guide][encoding].

`int32` and `int64` encode negative values using a sign-extended two's-complement
representation, consuming ten bytes. `sint32` and `sint64` first apply ZigZag;
`fixed32` and `fixed64` have constant width. Choosing among these is a schema
decision with size and compatibility consequences, not a transparent optimizer.

**Upstream reference vector, not a locally executed encoder:** the
[official `Test1` example][encoding] sets `a = 150` and gives:

```text
08 96 01
```

`08` is field `1`, wire type `0`; `96 01` contributes `22 + 128 = 150`.
The same guide gives `12 07 74 65 73 74 69 6e 67` for field `2` containing
`"testing"`. These are source vectors, not timing or compression measurements.

### Access model

The conventional generated API parses wire bytes into an object representation.
It does not expose a table field by following a verified wire offset.
Repeated-field storage, unknown fields and strings need runtime representation;
arenas can change allocation ownership without changing the encoding into an
in-place format. See the [C++ arena guide][arenas].

A streaming parser can skip unwanted values, and specialized implementations
can borrow payload slices. Neither establishes that an arbitrary generated
message is a view of the original buffer. Framing is also external: a top-level
message has no mandatory total-length header, so stream users need an enclosing
length or another transport boundary. [Encoding][encoding] defines submessage
lengths, not a universal transport frame.

### Variable-length and optional data

Strings, bytes and submessages use `LEN`: a varint byte count followed by that
many bytes. Packed numeric repeated fields concatenate element encodings inside
one such payload. Readers accept multiple packed chunks and concatenate them;
packed and expanded forms must interoperate. A repeated message remains a
sequence of individually tagged submessages. [Encoding][encoding]

Absence is represented by omitting a field. Whether the API distinguishes
absence from an explicitly written default depends on its presence discipline,
not just on the wire type. Explicit presence and implicit presence are separate
schema/API choices; see [field presence][presence]. `oneof` uses the ordinary
member tags, not a distinct union envelope.

For duplicate singular scalars the last value wins; singular submessages merge;
repeated values append. Maps are repeated entry messages, and map iteration
order is not a wire-level order guarantee. These details matter to validators
and signature schemes as much as to ordinary application code. [Encoding][encoding]

### Evolution and compatibility

Field numbers are the durable identity. Adding a field lets an older reader
skip or preserve it using the wire type; reusing a deleted number can silently
reinterpret old bytes. The [best-practices guide][practice] recommends reserving
deleted numbers and avoiding incompatible type changes.

Compatibility is more than matching wire type. Several logical types share the
same wire type but disagree about signedness, meaning or UTF-8 requirements.
Unknown-field retention also depends on the path through the application:
converting to JSON or manually rebuilding a message can lose information that
binary parse/reserialize would preserve. [Language guide][language]

The [draft Flat arena policy][flat-draft] takes the opposite position: `WFL54` pins a layout
digest and version, and a mismatch is rejected for cache rebuild rather than
adapted. That is a reasonable cache policy, not Protobuf-style schema evolution.

### Determinism and canonical form

The [security contract][security] is explicit:

> There is **no canonical representation** of Protobuf messages.

Deterministic serialization is scoped to an implementation/build, not a stable
cross-language equivalence relation. Field order, unknown fields, duplicate
occurrences and packed versus expanded representations all prevent equating
"parses to the same application value" with "has identical bytes".
The dedicated [non-canonical serialization guide][canonical] explains why
unknown `LEN` values make schema-independent normalization especially difficult.

The draft Flat builder's `WFL49` similarly promises a pure function of a
sequence of builder calls. That is reproducibility of construction, not proof
that every representation of an equivalent value has one canonical encoding.

### Merkleization and content addressing

**N/A as a built-in facility:** Protobuf defines neither cryptographic child
links nor a Merkle traversal or digest algorithm. A `bytes` digest field is
application data until another protocol gives it semantics. [Security][security]

Hashing an exact encoded blob is well-defined, but it does not make all
equivalent message values converge. [REAPI's `Directory` protocol][reapi] is a
concrete example of an application adding sorting and structural restrictions
above Protobuf. Reuse that catalog's analysis rather than treating its rules
as a property of the Protobuf wire format.

### Hostile-input safety

Bounds, total bytes, allocation and recursion limits are runtime obligations.
The [security contract][security] distinguishes hardened parse surfaces from
API misuse and warns against validating at a gateway while forwarding original
bytes for a backend to reinterpret under another schema.

There is primary evidence for real recursion failures, not merely a hypothetical
"recursive parsers might overflow" warning. The publisher's advisory
`GHSA-735f-pc8j-v9w8` / [`CVE-2024-7254`][java-cve] identifies nested unknown groups in Java
Full/Lite, discard-unknown parsing and map-related paths. Its reproduction
references are [`LiteTest.java`][lite-tests] and
[`CodedInputStreamTest.java`][java-tests]; the pinned tree contains explicit
recursion-limit regression coverage. The advisory lists patched branches
`3.25.5`, `4.27.5` and `4.28.2`. Google's CNA record links the
[fix commit][java-fix].

The publisher's `GHSA-8qvm-5x2c-j2w7` / [`CVE-2025-4565`][python-cve] separately concerns
the **pure-Python backend**, including recursive groups/messages. It lists
`4.25.8`, `5.29.5` and `6.31.1` as mitigations. Its reproduction sources are
[`decoder_test.py`][decoder-tests] and [`message_test.py`][python-tests].
These are backend-specific historical advisories, not a claim that the reviewed
revision remains vulnerable or that every Python backend was affected.
Google's CNA record identifies the [Python fix commit][python-fix].

The design lesson for `WFL24` is to budget every recursive/skip/unknown path,
not just the normal schema-known submessage parser. A byte bound alone cannot
stand in for a stack or work bound. [Security][security]

### Describing foreign formats

**N/A for arbitrary layouts:** Protobuf owns its tag and payload encoding.
A schema cannot say "this existing big-endian field begins at byte 20" or
"this 16-bit offset is relative to an ancestor table". A foreign file can be
wrapped in `bytes`, but its interior still requires a different parser.
The [wire guide][encoding] fixes these mechanics rather than exposing a
general binary-layout vocabulary.

This is the substantive boundary with the draft Flat proposal: its foreign
format descriptions, declared endian and offset bases are not substitutes for
Protobuf's compatibility contract, and Protobuf is not a substitute for them.

### Implementation and performance evidence

Two **third-party** D implementations were identified, neither an official
Google-supported generator. [`protobuf-d`][d-protobuf] advertises binary/JSON
codecs and a `protoc-gen-d` plugin limited to **proto3** input.
[`dproto`][d-dproto] instead mixes schema declarations into D at compile time;
its example uses `required`/`optional` fields. The [official language list][languages]
does not list D. These are source-advertised integration options, not
conformance, maintenance or security results established by this survey.
The independent D invariant below exercises neither library.

The [C++ wire helpers][wire] show the actual varint/fixed-width substrate;
[`descriptor.proto`][descriptor] shows the schema model. The cited Java and
Python tests are independent evidence for recursion-limit behavior, rather than
an inference from a marketing description.

No encoder benchmark or complete upstream test suite was run for this page.
The hex examples above are explicitly upstream documentation vectors. They establish
wire interpretation only; they do not measure allocation, throughput, cold
startup, or compatibility with every supported runtime.

The following **independent invariant check**, not a Protobuf codec or a
reference-runtime observation, checks that vector's tag and seven-bit groups.
It is a portable, CI-verified D program with no package dependencies.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "binary_protobuf_invariant"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : writeln;

void main() @safe
{
    immutable ubyte[3] bytes = [0x08, 0x96, 0x01];
    const field = bytes[0] >> 3;
    const wire = bytes[0] & 7;
    const value = (bytes[1] & 0x7F) | ((bytes[2] & 0x7F) << 7);
    assert(field == 1 && wire == 0 && value == 150);
    assert((bytes[1] & 0x80) != 0 && (bytes[2] & 0x80) == 0);
    writeln("field=", field, " wire=", wire, " value=", value);
}
```

```ansi
field=1 wire=0 value=150
```

## Strengths

- Stable numbered fields support independently deployed producers and consumers.
- Compact small integers and omitted fields suit sparse messages. [Encoding][encoding]
- Unknown-field handling supports binary relays without complete schema knowledge.
- Mature, explicit security and non-canonical-serialization guidance. [Security][security]

## Weaknesses

- Conventional access pays parsing/materialization costs rather than native viewing.
- Coarse wire types cannot replace the schema for semantic interpretation.
- Deterministic output is not a portable canonical identity. [Canonicalization][canonical]
- Compatibility and recursion guarantees must be checked per backend and code path.

## Key design decisions and trade-offs

| Decision                       | Rationale                          | Trade-off                                    |
| ------------------------------ | ---------------------------------- | -------------------------------------------- |
| Stable field numbers           | Independent schema evolution       | Number reuse can reinterpret historical data |
| Tags plus coarse wire types    | Skip unknown fields                | Field lookup requires parsing                |
| Multiple legal representations | Flexible writers and compatibility | No universal canonical message bytes         |
| Runtime object APIs            | Idiomatic language integration     | Not a general in-place file view             |

## Sources

- [Wire encoding and official hex vectors][encoding].
- [Schema descriptors][descriptor] and [C++ wire helpers][wire].
- [Publisher security contract][security], with the named advisory reproduction
  sources in [Java Full][java-tests], [Java Lite][lite-tests] and [Python][python-tests].
- Google-authored CNA records for [Java recursion][java-cve] and [pure-Python recursion][python-cve].
- [Presence][presence], [evolution guidance][practice] and [canonicalization limits][canonical].

<!-- References -->

[repo]: https://github.com/protocolbuffers/protobuf/tree/5a89c084a0c055b21804acd8eae5bfc8e5ba9e28
[license]: https://github.com/protocolbuffers/protobuf/blob/5a89c084a0c055b21804acd8eae5bfc8e5ba9e28/LICENSE
[security]: https://github.com/protocolbuffers/protobuf/blob/5a89c084a0c055b21804acd8eae5bfc8e5ba9e28/SECURITY.md
[wire]: https://github.com/protocolbuffers/protobuf/blob/5a89c084a0c055b21804acd8eae5bfc8e5ba9e28/src/google/protobuf/wire_format_lite.h
[descriptor]: https://github.com/protocolbuffers/protobuf/blob/5a89c084a0c055b21804acd8eae5bfc8e5ba9e28/src/google/protobuf/descriptor.proto
[lite-tests]: https://github.com/protocolbuffers/protobuf/blob/5a89c084a0c055b21804acd8eae5bfc8e5ba9e28/java/lite/src/test/java/com/google/protobuf/LiteTest.java
[java-tests]: https://github.com/protocolbuffers/protobuf/blob/5a89c084a0c055b21804acd8eae5bfc8e5ba9e28/java/core/src/test/java/com/google/protobuf/CodedInputStreamTest.java
[python-tests]: https://github.com/protocolbuffers/protobuf/blob/5a89c084a0c055b21804acd8eae5bfc8e5ba9e28/python/google/protobuf/internal/message_test.py
[decoder-tests]: https://github.com/protocolbuffers/protobuf/blob/5a89c084a0c055b21804acd8eae5bfc8e5ba9e28/python/google/protobuf/internal/decoder_test.py
[encoding]: https://github.com/protocolbuffers/protocolbuffers.github.io/blob/ffc09fed939e44bb3cfdef77852a0e6c62f90b17/content/programming-guides/encoding.md
[canonical]: https://github.com/protocolbuffers/protocolbuffers.github.io/blob/ffc09fed939e44bb3cfdef77852a0e6c62f90b17/content/programming-guides/serialization-not-canonical.md
[practice]: https://github.com/protocolbuffers/protocolbuffers.github.io/blob/ffc09fed939e44bb3cfdef77852a0e6c62f90b17/content/best-practices/dos-donts.md
[presence]: https://github.com/protocolbuffers/protocolbuffers.github.io/blob/ffc09fed939e44bb3cfdef77852a0e6c62f90b17/content/programming-guides/field_presence.md
[language]: https://protobuf.dev/programming-guides/proto3/
[arenas]: https://protobuf.dev/reference/cpp/arenas/
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[serde]: ../serde/index.md
[reapi]: ../content-addressing/reapi.md
[flat-draft]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
[d-protobuf]: https://github.com/dcarp/protobuf-d/blob/f8f1c9fdbfcc2ef8a9409263e852e47937b3ee55/README.md
[d-dproto]: https://github.com/msoucy/dproto/blob/00e4bfdd0f4528cbfaf4aaa1a5af7d0bf26a80c7/README.md
[languages]: https://github.com/protocolbuffers/protocolbuffers.github.io/blob/ffc09fed939e44bb3cfdef77852a0e6c62f90b17/content/overview.md
[java-cve]: https://cveawg.mitre.org/api/cve/CVE-2024-7254
[python-cve]: https://cveawg.mitre.org/api/cve/CVE-2025-4565
[java-fix]: https://github.com/protocolbuffers/protobuf/commit/cc8b3483a5584b3301e3d43d17eb59704857ffaa
[python-fix]: https://github.com/protocolbuffers/protobuf/commit/17838beda2943d08b8a9d4df5b68f5f04f26d901
