# UBJSON (Language-neutral)

A marker-based binary JSON format whose optional typed containers can remove
every per-element tag, including all payload bytes for repeated null/booleans.

| Field                 | Value                                                            |
| --------------------- | ---------------------------------------------------------------- |
| Language              | Language-neutral; reference-tool probe in C++                    |
| License               | Specification: [Apache-2.0][intro]                               |
| Repository            | [Universal Binary JSON specification][readme]                    |
| Documentation         | [Draft-12 values][values] · [containers][containers]             |
| Category              | Self-describing binary JSON with optional homogeneous containers |
| Numeric byte order    | Big-endian                                                       |
| Binary representation | Typed unsigned-byte array, not a separate binary scalar          |

## Overview

### What it solves

UBJSON avoids textual numeric parsing while preserving JSON-like arrays,
objects, strings, booleans, and null. Human-recognizable ASCII markers make
the grammar easier to inspect than a dense bit-packed tag space. Numeric
widths and container optimizations provide compact representations without
a mandatory external schema ([introduction][intro]; [value types][values]).

The survey covers draft 12, not every historical UBJSON draft or BJData
extension. Shared concepts and cross-format conclusions live in
[concepts][concepts] and [comparison][comparison].

### Design philosophy

The specification explains the uniform structure:

> The Universal Binary JSON specification is intentionally defined using a single core data structure to build up the entire specification.

That statement in the [upstream README][readme] describes marker, optional
length, and payload. Container optimizations are still important exceptions
to the naive rule that every element begins with its own marker.

## How it works

Ordinary arrays use `[` and `]`; objects use `{` and `}`. Values begin with
ASCII type markers. Multi-byte numeric payloads are big-endian; string lengths
are themselves typed integer values ([values][values]; [containers][containers]).

| Marker        | Meaning                     | Payload                                    |
| ------------- | --------------------------- | ------------------------------------------ |
| `Z`           | Null                        | None                                       |
| `T`, `F`      | True, false                 | None                                       |
| `N`           | No-op                       | None; ignored rather than an array element |
| `i`, `U`      | Signed/unsigned byte        | 1 byte                                     |
| `I`, `l`, `L` | Signed 16/32/64-bit integer | 2/4/8 bytes                                |
| `d`, `D`      | Binary32/binary64           | 4/8 bytes                                  |
| `C`           | Single ASCII character      | 1 byte, at most 127                        |
| `S`           | UTF-8 string                | Typed byte length, then bytes              |
| `H`           | High-precision number       | Typed byte length, then JSON-number text   |

Object names are strings with their redundant `S` marker omitted. Their
length markers remain. Optional `$` declares one type for every value in a
container; `#` declares its element/pair count. If `$` is present it precedes
`#`, and a count is mandatory. Counted containers must not have closing
markers ([optimized format][containers]).

**Locally executed reference-tool probes.** A C++17 harness compiled against
the pinned [`nlohmann/json` implementation][writer] called `to_ubjson` with
both count and type optimization enabled:

```text
[1,2,3]:          5b 24 69 23 69 03 01 02 03
512 false values: 5b 24 46 23 49 02 00
```

The first reads `[` `$` `i` `#` `i` 3, followed by three untagged bytes.
The second reads `[` `$` `F` `#` `I` 512 and has **no body**. Its seven
encoded bytes represent 512 logical values. This is useful compression and
also a reason to budget logical work independently from input bytes.

> [!NOTE]
> The upstream container example calls the 512-false representation six bytes.
> Counting its required markers and two-byte `int16` payload gives seven,
> matching the local reference-tool output. The mechanism is useful; the
> example's byte total is not an oracle ([source example][containers]).

**Portable CI invariant check.** This independently checks the two observed
headers, payload extents, and logical-work budgeting. It is not a UBJSON codec
or upstream encoder execution. In particular, a zero-byte payload must still
consume an element-count budget.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "research_ubjson_vectors"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : writeln;

bool budgeted(ulong count, ulong width, ulong remaining, ulong maxItems)
    @safe pure nothrow @nogc
    => count <= maxItems && (width == 0 || count <= remaining / width);

void main() @safe
{
    immutable ubyte[] integers = [0x5b, 0x24, 0x69, 0x23, 0x69, 3, 1, 2, 3];
    immutable ubyte[] falses = [0x5b, 0x24, 0x46, 0x23, 0x49, 2, 0];
    assert(integers[0 .. 5] == ['[', '$', 'i', '#', 'i']);
    immutable ulong integerCount = integers[5];
    immutable size_t bodyAt = 6;
    assert(budgeted(integerCount, 1, integers.length - bodyAt, 3));
    assert(integerCount == integers.length - bodyAt);
    foreach (end; bodyAt .. integers.length)
        assert(!budgeted(integerCount, 1, end - bodyAt, 3));
    assert(falses[0 .. 5] == ['[', '$', 'F', '#', 'I']);
    immutable ulong falseCount = (cast(ulong)falses[5] << 8) | falses[6];
    assert(falseCount == 512 && falses.length == 7);
    assert(budgeted(falseCount, 0, 0, 512));
    assert(!budgeted(falseCount, 0, 0, 511));
    assert(!budgeted(ulong.max, 8, ulong.max, ulong.max));
    writeln("UBJSON: 3 int8 payload bytes; 512 false values in 7 bytes need a work budget");
}
```

```ansi
UBJSON: 3 int8 payload bytes; 512 false values in 7 bytes need a work budget
```

### Schema source of truth

The draft-12 specification defines value syntax. Applications decide field
types, required members, defaults, and versions. A `$` header describes the
current container's values; it is not a schema for the whole record graph
([container rules][containers]).

Objects have string names only. They are not generic-key maps like CBOR or
MessagePack. A schema conversion must reject or transform composite and
non-string keys rather than silently stringify them into potentially colliding
names. The high-precision marker likewise carries numeric text, not an
application-defined extensible typed blob ([value definitions][values]).

### Wire encoding

`i` is signed 8-bit and `U` is unsigned 8-bit; case matters. `I`, `l`, and
`L` carry signed wider integers. The spec recommends the smallest appropriate
numeric type, but several encodings can represent the same integer. Binary
floats use their IEEE representation, not a decimal conversion path
([numeric types][values]).

`S i 05 hello` stores five UTF-8 bytes with no terminator. A string's length
is bytes, not Unicode character count. `C` is only a one-byte ASCII value,
not a general Unicode scalar encoding. `H` preserves arbitrary-precision
numeric text when a receiver cannot represent the value natively.

Binary data uses a typed `$ U` array. That preserves raw bytes compactly, but
does not add a distinct binary value to the abstract JSON model; a consumer
may expose it as an ordinary integer array ([binary-data specification][binary]).
No compression, checksum, or encryption follows from choosing that container.

### Access model

The default access model is sequential parsing, optionally into an allocated
tree. Ordinary containers require walking elements until the closing token;
counted containers require decoding the declared number of children.
Strings can be skipped by checked length ([containers][containers]).

Typed fixed-width arrays offer a narrower direct-access opportunity: after
checking `count * width`, an element's offset is arithmetic. This does not
make all UBJSON values an [in-place view][in-place]. Numeric endianness,
alignment, restricted values, and ownership still matter, and typed strings
or nested containers have variable extents.

The optimization cannot be generalized to arbitrary objects: names remain
variable-length even when every value shares one type. No object field index
or foreign pointer/offset language is built into the format.

### Variable-length and optional data

Uncounted arrays/objects support incremental writing without knowing the
element count. Counted containers exchange that freedom for omitted terminators
and possible preallocation. Typed containers need counts because a payload byte
could otherwise look like a closing token ([optimized format][containers]).

Null and booleans are special typed-container cases: their markers already
determine the value, so arrays have no body and objects contain only names.
The logical count cannot be inferred from bytes consumed after the header.

Missing object names differ from explicit `Z`. `N` is not null and does not
stand for an absent array slot: it is a valueless no-op. The specification
permits ignored no-ops between container elements; a parser must not count
them as ordinary values ([no-op definition][values]).

### Evolution and compatibility

Named objects support additive evolution only when application decoders ignore
unknown members and define missing-field behavior. There is no mandatory
schema version in each encoded value. Draft selection therefore belongs in
the surrounding protocol or file convention.

Reserved or future marker choices are not automatically skippable. A decoder
must know whether a marker has fixed payload, a typed length, or nested
structure. BJData features in a library are not evidence that those features
belong to UBJSON draft 12; the inspected C++ writer has separate switches
for those formats ([writer][writer]).

### Determinism and canonical form

**No complete canonical form is defined.** Uncounted, counted, and typed-counted
containers can express the same array. Numeric width and length-integer width
can vary. `C` and a one-byte `S` can represent the same textual character in
many application models. No-ops add representation variability without adding
logical data ([values][values]; [containers][containers]).

Object ordering and duplicate-name handling need an application profile. A
particular writer using a sorted native map can be deterministic without
establishing a canonical order for all writers or a duplicate-key rejection
rule. Reject duplicates before converting to a lossy native object.

Float-width choices, signed zero, NaNs, and `H` spelling are additional hash
questions. The source says infinity is encoded as null; therefore mapping
non-finite IEEE values to generic JSON semantics is not automatically lossless.
A profile must explicitly define non-finite acceptance and normalization
instead of assuming every possible float payload has agreed meaning
([numeric rules][values]).

Two equal mathematical numbers can also have different `H` strings, such as
`1`, `1.0`, and `1e0`. Choosing shortest binary widths does not normalize
those strings, determine decimal equality, or define whether integer and float
values collapse into one hash identity.

### Merkleization and content addressing

**N/A as a supplied mechanism:** UBJSON has no digest links, Merkle chunk tree,
proofs, or canonical subtree identifiers. Hashing exact bytes is possible,
but no-op insertion alone can change that hash without changing decoded data.

A content-addressed protocol needs its own value domain and normalization:
object order, duplicate rejection, number equivalence, string form, no-op policy,
and a mandatory choice of container representation. Typed-array compression
does not supply any of those rules ([content-addressing concepts][ca]).

### Hostile-input safety

Counts and lengths can use signed 64-bit integer payloads. Reject negative
values and excessive positives before conversion or allocation. A typed
fixed-width payload needs checked multiplication against the remaining region;
declaring a count is not proof that its bytes exist ([containers][containers]).

Zero-payload typed booleans/nulls are the crucial amplification case. A small
header can request enormous allocation or billions of visitor calls without
any corresponding body. Bound logical nodes and output bytes independently
from input size; do not rely only on "one byte per element" reasoning.

No-op runs also consume parsing work without output growth. Bound total bytes,
nesting, key bytes, number-text length, and numeric-conversion work. Limit
high-precision exponents and digits before feeding a bignum parser. Counted
nested typed containers still require depth accounting.

Enforce `$` before `#`, require the count when a type is specified, reject
`N` as the declared container type, and distinguish an absent terminator from
a missing child value. These are grammar constraints, not merely encoder
preferences ([optimized rules][containers]). No CVE is attributed to all
UBJSON implementations here.

### Describing foreign formats

**N/A:** UBJSON's fixed-width typed arrays are its own encoding, not a language
for describing a foreign record's offsets or endian mix. A raw unsigned-byte
array can carry a font or packet but leaves its interpretation to another
parser.

The [Flat draft][flat] seeks checked access to existing layouts. UBJSON offers
a useful comparison for homogeneous data and count arithmetic, but not an
alternative to foreign-format layout declarations or offset-base validation.

### Implementation and performance evidence

The inspected [`nlohmann/json` binary writer][writer] implements ordinary and
optimized UBJSON and distinguishes BJData options. The local probe verified
typed integer payload layout and zero-body boolean expansion, not broad
conformance or performance. Its header-only C++ toolchain was available; no
extra dependency installation was needed.

No D UBJSON implementation was verified. Upstream claims about average size
reductions or parsing speed are not reproduced here: they require a corpus,
writer options, versions, and allocation measurements. The exact seven-byte
false-array result is a size fact about one value, not a throughput benchmark.

## Strengths

- Simple recognizable markers and JSON-like containers.
- Uncounted containers support unknown-size streaming.
- Typed numeric arrays eliminate per-element markers.
- Counted null/boolean arrays can compress to headers alone.

## Weaknesses

- Container optimization creates extra parser states and representation choices.
- Tiny zero-payload headers can expand into enormous logical workloads.
- No canonical profile, generic-key map, or distinct binary scalar semantics.
- Draft and extension negotiation is external.

## Key design decisions and trade-offs

| Decision                            | Rationale                                 | Trade-off                                         |
| ----------------------------------- | ----------------------------------------- | ------------------------------------------------- |
| Use ASCII type markers              | Keep grammar recognizable                 | Small scalars generally need marker overhead      |
| Optional type and count headers     | Compress homogeneous containers           | Counts must be validated before resource use      |
| Omit counted-container terminators  | Avoid redundant bytes                     | Parser must track context and exact counts        |
| Carry high precision as number text | Preserve portability beyond native widths | Conversion and canonical spelling remain external |

## Sources

- [Specification introduction and license][intro].
- [Draft-12 value types][values], [container rules][containers], [binary data][binary].
- [Pinned C++ binary writer][writer]: locally executed reference-tool probes.

<!-- References -->

[readme]: https://github.com/ubjson/universal-binary-json/blob/b3037c84600d6d34f505f6175716f10f5274538e/README.md
[intro]: https://github.com/ubjson/universal-binary-json/blob/b3037c84600d6d34f505f6175716f10f5274538e/spec12/index.html
[values]: https://github.com/ubjson/universal-binary-json/blob/b3037c84600d6d34f505f6175716f10f5274538e/spec12/value-types.html
[containers]: https://github.com/ubjson/universal-binary-json/blob/b3037c84600d6d34f505f6175716f10f5274538e/spec12/container-types.html
[binary]: https://github.com/ubjson/universal-binary-json/blob/b3037c84600d6d34f505f6175716f10f5274538e/spec12/binary-data.html
[writer]: https://github.com/nlohmann/json/blob/cd6b428ef087fb0ce06a7daaa547f71d2907e948/include/nlohmann/detail/output/binary_writer.hpp
[flat]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[ca]: ../content-addressing/concepts.md
[in-place]: ./concepts.md#in-place-access-and-zero-copy
