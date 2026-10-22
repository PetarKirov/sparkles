# Smile (Jackson / JVM)

A sequential binary JSON token stream that trades context-independent values
for bounded dictionaries of repeated property names and short strings.

| Field         | Value                                                   |
| ------------- | ------------------------------------------------------- |
| Language      | Language-neutral wire specification; Jackson/JVM origin |
| License       | Specification repository: [BSD-2-Clause][license]       |
| Repository    | [Smile format specification][spec]                      |
| Documentation | [Specification 1.0.7][spec] · [design goals][goals]     |
| Category      | Stateful, self-describing binary JSON token encoding    |
| Sharing model | Separate name/value dictionaries of up to 1024 entries  |
| Access        | Sequential; random access explicitly a non-goal         |

## Overview

### What it solves

Smile preserves JSON-like event processing while avoiding textual number
conversion and repeated transmission of familiar names. A parser can expose
the same logical start-object, name, value, and end-object events as a JSON
parser. Native binary and richer numeric representations fit the Jackson API
without requiring a generated schema ([goals][goals]; [specification][spec]).

The important comparison is not just message size: shared-name state changes
what a byte slice means. See [concepts][concepts] and [comparison][comparison]
for the distinction between stream processing and independently readable data.

### Design philosophy

The upstream design goals explicitly say:

> NEED NOT design for random-access: low-level Jackson APIs are designed for sequential access; can implement "low-hanging fruits" if that makes sense.

They also prefer processing speed over maximal compactness and require bounded
streaming buffers ([`smile-design-goals.md`][goals]). The trade-off is deliberate:
Smile is not an arena format waiting for a zero-copy wrapper.

## How it works

A section has a four-byte header, a properly nested token sequence, and an
optional `ff` end marker. The first three bytes are `3a 29 0a`, a smiley
and line feed. The fourth carries a four-bit format version and flags for
raw binary, shared string values, and shared names ([high-level format][spec]).

The version nibble is zero for this wire version; specification document
version 1.0.7 is not the header nibble. With no header, decoding assumes shared
names enabled and shared values disabled. Header and parser configuration
requirements therefore need an explicit application policy.

| Token/context | Bytes                  | Meaning                                   |
| ------------- | ---------------------- | ----------------------------------------- |
| Value         | `20`, `21`, `22`, `23` | Empty string, null, false, true           |
| Value         | `c0`–`df`              | Zigzag integers −16 through 15            |
| Value         | `24`, `25`             | 32-/64-bit zigzag VInt                    |
| Value         | `28`, `29`             | Binary32/binary64 encoded in 7-bit groups |
| Value         | `f8`, `f9`             | Start/end array                           |
| Value / key   | `fa` / `fb`            | Start object / end object                 |
| Value         | `e8`, `fd`             | Safe 7-bit binary / raw binary            |
| Long text     | `fc`                   | End-of-string marker                      |

Token interpretation depends on **key mode versus value mode**. For example,
`40` in key mode is a shared-name reference; `40` in value mode prefixes a
one-byte ASCII string. A byte scanner cannot treat every token-looking byte
inside a payload as structure ([low-level format][spec]).

**Upstream source vector, not a Jackson run.** The specification gives float
29.9510 as IEEE bits `41 ef 9b a6`, with safe payload `04 0f 3e 37 26`.
Including its type token yields `28 04 0f 3e 37 26` ([float encoding][spec]).
The following portable D check independently verifies the bit regrouping,
not the correctness or speed of an upstream codec:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "research_smile_float_groups"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : writeln;

void main() @safe
{
    immutable uint bits = 0x41ef9ba6;
    ubyte[5] groups;
    foreach (i; 0 .. groups.length)
        groups[i] = cast(ubyte)((bits >> (28 - 7 * i)) & 0x7f);
    assert(groups == [0x04, 0x0f, 0x3e, 0x37, 0x26]);
    uint restored;
    foreach (group; groups)
        restored = (restored << 7) | group;
    assert(restored == bits);
    writeln("Smile binary32: 5 payload bytes, exact bit reconstruction");
}
```

```ansi
Smile binary32: 5 payload bytes, exact bit reconstruction
```

### Schema source of truth

The source of wire truth is the Smile specification; application field
requirements live in the JSON-like record model or binding configuration.
There is no mandatory schema IDL or generated field table. Property-name
dictionaries are learned from the stream, not a transmitted or preinstalled
schema ([shared-name resolution][spec]).

The proposed pre-defined shared-value scheme in the specification's future
ideas is explicitly **not** a Smile 1.0 feature. Treating it as an existing
schema mechanism would produce noninteroperable files.

### Wire encoding

Signed integral values first use zigzag conversion, then a big-endian VInt.
Non-final bytes have seven data bits with the high bit clear; the final byte
has its high bit set and only six data bits. This is not protobuf's
little-endian varint representation, even though both use zigzag
([VInt rules and appendix][spec]).

Binary32 uses five 7-bit payload bytes, binary64 uses ten, with leading unused
bits. Arbitrary integers and decimal values use safe binary; decimals also
carry a zigzag scale. Length VInts are unsigned and do not use zigzag.

Safe binary maps seven raw bytes to eight encoded bytes, with a partial final
group right-aligned in its low bits. Raw binary avoids this overhead but
permits bytes otherwise reserved for framing. A stream with raw binary cannot
be reliably split by blindly searching for `ff` ([binary and header rules][spec]).

### Access model

The stream is both sequential and stateful. Shared names and eligible short
string values are stored in separate indexable tables. References use indices
from the beginning of the table, not relative distances. When a table fills
with 1024 entries and another literal is added, it clears and restarts
([shared resolution][spec]).

Referencing an existing string does not add another dictionary entry. Long
value strings do not participate in short-value sharing. A parser skipping
an uninteresting object must nevertheless update relevant dictionaries, or
subsequent references may resolve incorrectly.

Consequently, copying a nested object's encoded bytes out of a section does
not necessarily produce a self-contained Smile object. Dictionary state and
mode are part of the decoding context. Borrowing individual literal payloads
is not the same as a context-free [in-place view][in-place].

### Variable-length and optional data

Arrays and objects end with structural tokens rather than declared element
counts. Short strings have byte-length information in their prefix; long
strings end with `fc`. This avoids precomputing all long UTF-8 byte lengths,
one of the explicit streaming motivations in the [design goals][goals].

Absent object members differ from present null (`21`). Defaults and required
members belong to the application. An array has no generic missing-element
marker. Empty strings have their own token, not a zero-length long-string
requirement.

### Evolution and compatibility

The header provides format versioning and feature flags. Reserved bytes do
not supply an automatically skippable new type: a decoder needs a known
payload grammar. Application objects can evolve by adding named fields when
their readers permit unknown names ([specification][spec]).

Specification 1.0.7 corrects a float example; 1.0.6 documents an existing
requirement to avoid long references whose low byte is `fe` or `ff`.
These are specification corrections, not evidence that historical decoders
all agreed. Pin the actual specification and test dictionary-boundary cases.

The narrative contains older stale wording around the miscellaneous-token
range; use the explicit structural-token assignments and detailed key-mode
table rather than interpreting an isolated obsolete sentence as a new wire
version ([update history and token tables][spec]).

### Determinism and canonical form

**No universal canonical form is specified.** Sharing checks are optional,
encoder lookups may be lossy, headers carry configurable flags, and names
can arrive in different object orders. Identical logical objects can therefore
have different valid byte streams ([shared values][spec]).

Numeric width choices and arbitrary-precision encodings add more variability.
The specification says unused bits should be zero, but decoders must ignore
them by default; optional strict verification may reject them. Thus decoding
and re-encoding can change bytes even before object reordering is considered.

Duplicate property names have no complete Smile-specific semantic resolution
rule. A security profile must reject them or model ordered pairs explicitly.
Native map insertion is too late if it erases earlier values. Likewise a
semantic hash profile needs rules for binary32/binary64 equivalence, NaNs,
signed zero, decimal scales, and big integers ([numeric tokens][spec]).

### Merkleization and content addressing

**N/A:** Smile defines no Merkle nodes, digest algorithm, link type, or proof
structure. Section-local references are compression dictionaries, not
content-addressed references. Their targets depend on preceding literal order.

Hashing exact complete sections is possible. Hashing a copied subtree is not
generally context-independent: re-encoding it alone can change reference
indices and literal/reference choices. A Merkle protocol would need to disable
or scope sharing and define a canonical semantic profile first.

This is a stronger obstacle than mere map ordering. It is a dependency on
history, even when an implementation emits the same bytes repeatedly for one
fixed traversal ([sharing rules][spec]; [content-addressing concepts][ca]).

### Hostile-input safety

Bound nesting, string scan length, total decoded bytes, numeric magnitude,
and cumulative event work. Fixed dictionary cardinality bounds entry count,
not all retained name bytes: property names can be long. Validate references
against entries actually populated since the last reset ([resolution][spec]).

Bound VInt byte counts before shifts; distinguish unsigned length VInts from
zigzag values; check safe-binary expansion arithmetic before buffering.
Unterminated long strings and truncated encoded groups must produce errors,
not unbounded scanning. Raw binary requires honoring its checked length rather
than treating embedded structural bytes as nesting tokens.

Strict duplicate detection, numeric policies, and dictionary maintenance
remain relevant even when a caller discards most values. No vulnerability or
absence-of-vulnerabilities claim is inferred from the small wire grammar.

### Describing foreign formats

**N/A:** Smile describes its own event encoding. A binary token can transport
existing file bytes, but does not describe their fields, checksums, offset
bases, or mixed endian conventions. Custom Jackson serializers generate
Smile events, not arbitrary foreign layouts.

The [Flat draft][flat] has a separate purpose: proving existing fixed layouts
and reading their fields at known offsets. Smile's lesson for that design is
the cost of hidden stream state, not an alternative layout mechanism.

### Implementation and performance evidence

The primary evidence read here is the specification and design rationale,
including their explicit references to Jackson codec behavior. A JVM codec
was **not** executed; float bytes above are labeled source vectors and the D
program checks only their arithmetic invariant.

No D Smile implementation was verified. No size/throughput comparison with
JSON, MessagePack, or CBOR was reproduced. The design's bounded dictionaries
explain a mechanism for reducing repeated text, not a measured universal win.

## Strengths

- Streaming structure fits existing JSON event APIs.
- Shared names reduce repeated schema-like text without an IDL.
- Header and reserved ranges support detection and consistency checks.
- Numeric values avoid decimal conversion on ordinary binary paths.

## Weaknesses

- Dictionary state prevents context-free subtree extraction.
- Key/value modes and sharing resets complicate parsers and skip paths.
- Safe binary and float regrouping add transformations and some overhead.
- No specified canonical semantic representation.

## Key design decisions and trade-offs

| Decision                           | Rationale                                       | Trade-off                                        |
| ---------------------------------- | ----------------------------------------------- | ------------------------------------------------ |
| Separate learned name/value tables | Compact recurring text with bounded entry count | History-dependent byte interpretation            |
| Delimited long strings             | Avoid precomputing UTF-8 length                 | Readers must scan to a checked terminator        |
| Mostly reserve framing bytes       | Support section boundaries                      | Safe binary expansion; raw mode weakens scanning |
| Reuse JSON event model             | Fit Jackson-style APIs                          | No direct random-access record layout            |

## Sources

- [Smile 1.0.7 specification][spec]: grammar, vectors, flags, dictionary rules.
- [Design goals][goals]: streaming priorities and random-access non-goal.
- [Specification license][license].

<!-- References -->

[spec]: https://github.com/FasterXML/smile-format-specification/blob/a37fdb9730e35d99b6e23d590c5884a0c4d001a6/smile-specification.md
[goals]: https://github.com/FasterXML/smile-format-specification/blob/a37fdb9730e35d99b6e23d590c5884a0c4d001a6/smile-design-goals.md
[license]: https://github.com/FasterXML/smile-format-specification/blob/a37fdb9730e35d99b6e23d590c5884a0c4d001a6/LICENSE
[flat]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[ca]: ../content-addressing/concepts.md
[in-place]: ./concepts.md#in-place-access-and-zero-copy
