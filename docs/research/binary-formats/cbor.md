# CBOR (IETF / Language-neutral)

A self-describing binary value format with explicit deterministic encoding rules,
but deliberately no universal canonical application data model.

| Field            | Value                                                            |
| ---------------- | ---------------------------------------------------------------- |
| Language         | Language-neutral; reference implementation inspected in C        |
| License          | RFC: IETF Trust terms; `libcbor`: MIT                            |
| Repository       | [`libcbor` source][loader]                                       |
| Documentation    | [RFC 8949][rfc] (STD 94)                                         |
| Category         | Self-describing tagged values; definite or indefinite containers |
| Schema language  | Optional [CDDL, RFC 8610][cddl]                                  |
| Related profiles | [COSE and deterministic-CBOR profiles][profiles]                 |

## Overview

### What it solves

CBOR encodes Internet protocol values without textual number conversion or
base64 for binary data. It supports schema-free generic decoding and specific
application models, including tagged dates and arbitrary-precision numbers.
The RFC prioritizes small implementations as well as compact messages
([RFC 8949 §1.1][objectives]).

This page covers the base wire format. Security envelopes and stricter semantic
profiles are covered separately in [CBOR/COSE/dCBOR][profiles]. See [concepts][concepts]
for the shared comparison vocabulary and [comparison][comparison] for selection.

### Design philosophy

The RFC deliberately does not make uniqueness a base-format requirement:

> There is no requirement that all data formats be uniquely encoded; that is, it is acceptable that the number "7" might be encoded in multiple different ways.

That statement in [§1.1][objectives] explains why deterministic encoding is a
separate contract. A decoder may accept more encodings than a deterministic
encoder emits, and a protocol may need to reject accepted-but-nondeterministic
inputs before verifying semantic identity.

## How it works

Each initial byte contains a three-bit major type and five-bit additional
information. Arguments 0–23 are inline; 24, 25, 26, and 27 select a following
1-, 2-, 4-, or 8-byte unsigned big-endian argument. Values 28–30 are reserved
and not well-formed in this version ([§3][encoding]).

| Major type | Interpretation of argument `N`                  |
| ---------- | ----------------------------------------------- |
| 0          | Unsigned integer `N`                            |
| 1          | Negative integer `−1−N`                         |
| 2          | Byte string containing `N` bytes                |
| 3          | UTF-8 text containing `N` bytes                 |
| 4          | Array containing `N` data items                 |
| 5          | Map containing `N` key/value pairs              |
| 6          | Tag number `N`, followed by one data item       |
| 7          | Simple value, float, or indefinite-length break |

The argument is not generally a byte extent. `82 01 02` is `[1,2]`, while
`42 01 02` is a byte string. A map consumes twice its pair count in nested
items. Integers cover `−2^64` through `2^64−1`, which exceeds signed 64-bit
range on the negative side ([§3.1][major]).

**Locally executed reference-tool probe.** A C++17 harness using the pinned
[`nlohmann/json` writer][writer] produced:

```text
{"i":1}: a1 61 69 01
1.5:     fa 3f c0 00 00
```

The first is one map pair, text key `i`, integer 1. The float output is a
useful counterexample: the shortest exact CBOR float encoding is `f9 3e 00`,
but this encoder emitted binary32. The half-precision bytes are an
**upstream source vector**, not locally emitted output ([Appendix A][vectors]).
Consequently ordinary `to_cbor` output is not evidence of compliance with
§4.2 core deterministic encoding.

**Portable CI invariant check.** The object and binary32 bytes below are the
observed tool output; binary16 is the cited RFC source vector. This independent
structural/IEEE check proves equal value with different float widths, not
upstream encoder execution or a general deterministic-CBOR verifier.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "research_cbor_vector"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : writeln;

bool matchesFixture(in ubyte[] bytes) @safe pure nothrow @nogc
{
    if (bytes.length < 2 || bytes[0] != 0xa1 || bytes[1] != 0x61)
        return false;
    immutable size_t textStart = 2;
    immutable size_t textBytes = bytes[1] & 0x1f;
    if (textBytes > bytes.length - textStart)
        return false;
    immutable valueAt = textStart + textBytes;
    return valueAt < bytes.length && bytes.length - valueAt == 1
        && bytes[textStart] == 'i' && bytes[valueAt] == 1;
}

void main() @safe
{
    immutable ubyte[] object = [0xa1, 0x61, 0x69, 0x01];
    immutable ubyte[] single = [0xfa, 0x3f, 0xc0, 0x00, 0x00];
    immutable ubyte[] half = [0xf9, 0x3e, 0x00];
    assert(matchesFixture(object));
    foreach (end; 0 .. object.length)
        assert(!matchesFixture(object[0 .. end]));
    uint singleBits;
    foreach (part; single[1 .. $])
        singleBits = (singleBits << 8) | part;
    immutable uint halfBits = (cast(uint)half[1] << 8) | half[2];
    assert(single[0] == 0xfa && half[0] == 0xf9);
    assert(((singleBits >> 23) & 0xff) == 127); // Exponent is zero.
    assert(((halfBits >> 10) & 0x1f) == 15);    // Exponent is zero.
    immutable singleValue = 1.0 + (singleBits & 0x7fffff) / 8388608.0;
    immutable halfValue = 1.0 + (halfBits & 0x3ff) / 1024.0;
    assert(singleValue == 1.5 && halfValue == singleValue);
    assert(half.length < single.length);
    writeln("CBOR: bounded map; 1.5 has equal binary16/binary32 values, unequal bytes");
}
```

```ansi
CBOR: bounded map; 1.5 has equal binary16/binary32 values, unequal bytes
```

### Schema source of truth

RFC 8949 defines the generic value model and wire grammar; an application
defines its specific model. CDDL can describe permitted maps, arrays, choices,
ranges, and tags without becoming a prerequisite for decoding ([§2][model];
[RFC 8610][cddl]). A schema does not automatically choose a deterministic
profile or an equality relation.

The generic model distinguishes integers from floats even when numerically
equal, and text from byte strings. A binding that maps both integer and float
keys into an equality-coalescing dictionary loses information before an
application can validate its model. That is a binding limitation, not a reason
to redefine all CBOR numbers as one host-language type ([§2.2][specific]).

### Wire encoding

Major type 7 assigns `f4`/`f5` to false/true, `f6` to null, `f7` to
undefined, and `f9`/`fa`/`fb` to binary16/binary32/binary64. Floats carry
their IEEE bits in big-endian order; they are not decimal strings ([§3.3][floats]).

Tags wrap one value rather than supplying opaque extension bytes. Tags 2 and
3 contain big-endian bignum magnitudes; tag 4 represents a decimal fraction
as exponent/mantissa; tag 24 wraps encoded CBOR bytes. An unknown tag can be
preserved as a number and child value without understanding its semantics
([§3.4][tags]). No universal graph-pointer semantics follows from tagging.

Tag 55799 is self-described CBOR, not a required magic prefix. Its presence
does not identify an application schema, supported feature set, or authenticity.
An application can disallow it when hashing a model that does not retain it
([§3.4.6][self-described]).

### Access model

CBOR is sequential. A parser can expose callbacks, borrowed definite strings,
or an allocated tree, but the format does not supply field offsets or indexes.
Skipping a nested array/map requires parsing its descendants. A definite
string can be skipped by checked byte length ([§3][encoding]).

[`libcbor`'s `cbor_load`][loader] builds values by repeatedly calling the
stream decoder with builder callbacks and an explicit context stack.
[`cbor_stream_decode`][stream] instead permits caller-controlled callback
handling. These are different allocation/access APIs over the same wire;
neither is a fixed-layout [in-place view][in-place].

### Variable-length and optional data

Additional information 31 starts indefinite byte strings, text strings,
arrays, or maps. `ff` closes the immediately enclosing indefinite item.
It cannot appear as a value in a definite array, or in place of a map value
after a key ([§3.2.1–2][indefinite]).

Indefinite strings contain definite chunks of the same string kind. Nested
indefinite chunks are not permitted; each text chunk must independently contain
valid UTF-8, so a code point cannot cross a chunk boundary. Concatenation is
the resulting string value; chunk boundaries are not generic-model data
([§3.2.3][chunks]).

Missing map entries, null, and undefined are three distinct possibilities.
Specific models decide which are permitted and whether defaults are applied.
Normalizing them together without an application rule changes meaning
([§5.7][undefined]).

### Evolution and compatibility

Tags and registered simple values extend the model without changing the base
grammar. Generic decoders can preserve unknown tags, but applications must
decide whether a field carrying one is expected. Unknown map fields can be
skipped only when the application permits them ([§5.4][evolution]).

RFC 8949 explicitly keeps the RFC 7049 interchange format, rather than creating
a version-2 wire format. Nevertheless "canonical CBOR" in an older protocol
can mean a different ordering from RFC 8949 core deterministic ordering.
Wire compatibility and deterministic-profile compatibility are separate claims.

### Determinism and canonical form

[§4.1][preferred] defines preferred serialization: shortest argument encodings,
shortest exact float widths, and suitable preferred representations for tags.
It does not alone order maps or forbid indefinite-length containers.

[§4.2.1][core] adds the core deterministic requirements: preferred serialization,
no indefinite-length items, and map keys sorted by bytewise lexicographic order
of their deterministic encodings. With keys 24 and −1, `20` (−1) sorts before
`18 18` (24) only under length-first ordering; core bytewise ordering puts
`18 18` first because `18` precedes `20`.

[§4.2.3][length-first] separately defines length-first deterministic ordering:
shorter encoded keys first, then bytewise lexicographic order. This matches the
older RFC 7049 canonical ordering. A protocol must name which rule it uses;
"sort the keys" is not precise enough.

[§4.2.2][additional] covers the remaining semantic decisions: whether integral
floats may become integers, how tags participate in equivalent values, and
which NaN distinctions matter. Preferred NaN encoding can use `f9 7e 00`
when payload/signaling distinctions are not preserved; preserving those
distinctions changes the normalization problem. Signed zero also needs an
application equality policy, not an unexamined native numeric conversion.

A duplicate-key map may be syntactically well-formed but is not valid.
[§5.6.1][keys] defines key equivalence considerations; a specific model may
equate integer 0 and float 0.0 even though the generic model distinguishes
them. Checking only encoded byte equality misses duplicate keys encoded with
different integer widths, float widths, or application-equivalent types.

### Merkleization and content addressing

**N/A in the base format:** CBOR contains no mandatory digests, authenticated
child links, chunk tree, or proof construction. Deterministic bytes can feed a
hash, but do not themselves form a Merkle DAG. Link semantics, hash/domain
identifiers, and application value equivalence must come from a profile.

Hashing received bytes and hashing a normalized decoded value answer different
questions. The first distinguishes `01` from `18 01`; the second may not.
A signature design must specify which bytes are covered, and must not silently
re-encode protected bytes through a binding that loses tags or float details.
The [profile companion][profiles] covers this boundary rather than duplicating
COSE and dCBOR here.

### Hostile-input safety

[§10][security] explicitly warns about integer overflow, enormous allocations,
deep nesting, resource exhaustion, and differing decoders' interpretations.
Validity is layered: well-formed, valid, and application-expected are different
checks ([§1.2][terminology]; [§5.3][validity]). A syntax-only parser is not
automatically a duplicate-key or tag-content validator.

Check 64-bit lengths before conversion to `size_t`, and bounds before addition
or multiplication. A declared array size does not prove the payload exists.
Bound aggregate copied bytes, item count, depth, chunks, tag nesting, and
duplicate-key comparison work. Empty indefinite string chunks consume input
and parser work even though they add no output bytes.

**Concrete library advisory.** The maintainer-associated CNA record for
[CVE-2026-26209][cve-depth] identifies Python `cbor2` versions before 5.9.0,
including its Python decoder and `_cbor2` extension. Deep nesting raises
`RecursionError`; an uncaught exception can terminate a service worker. The
C extension uses `Py_EnterRecursiveCall`, so this must not be paraphrased as
proof that every input produces an unchecked native stack overwrite. The fix
adds a data-driven depth limit; the record names 5.9.0 as patched.

That is a `cbor2` vulnerability, not a CBOR-format defect or a finding about
`libcbor`. The inspected [`libcbor` stack][stack] checks
`CBOR_MAX_STACK_SIZE` before pushing. A stack cap still does not establish a
total allocation or callback-work budget.

For a distinct native stack-overflow example, the primary
[RustSec advisory for CVE-2019-25001][cve-tags] identifies Rust `serde_cbor`
before 0.10.2: nested semantic tags in documents below 1 KiB can exhaust the
stack. The correction limits nested tags. Counting only arrays/maps would
miss this path; every recursive wrapper needs the same depth accounting.

### Describing foreign formats

**N/A:** CBOR/CDDL describe CBOR values and their encoded shape, not arbitrary
existing byte layouts. Wrapping a font table in a byte string preserves its
bytes but does not describe its offset bases, alignment, or mixed endianness.

The [Flat draft][flat] addresses that distinct requirement. A CBOR codec can
serve as an interchange backend for a shared schema, while a fixed-layout
reader uses additional layout facts; neither backend substitutes for the other.

### Implementation and performance evidence

The inspected primary implementation is [`libcbor`][loader] with separate
streaming and tree-building paths. The C++ reference-tool probe demonstrated
ordinary output, including its non-shortest float width; it did not benchmark
either library or establish canonical validation.

No D CBOR binding was verified in this investigation. A C API being callable
from D is not evidence that an existing D wrapper is maintained, memory-safe,
or allocation-free. Such claims require an actual wrapper audit and tests.

## Strengths

- Precisely specified generic model and layered validity rules.
- Streaming indefinite values and compact definite values share one grammar.
- Explicit deterministic profiles rather than an unspecified "canonical" flag.
- Registered tags support interoperable richer values.

## Weaknesses

- Profiles must still choose semantic equivalence and numeric normalization.
- Sequential containers provide no native random-access index.
- Generic host mappings can lose keys, tags, and floating-point distinctions.
- Streaming freedom expands validation and resource-budget requirements.

## Key design decisions and trade-offs

| Decision                               | Rationale                                | Trade-off                                     |
| -------------------------------------- | ---------------------------------------- | --------------------------------------------- |
| Separate model, validity, expectedness | Permit reusable generic tooling          | Applications own semantic policy              |
| Optional indefinite lengths            | Emit unknown-size values incrementally   | More parser states and representation choices |
| Tags wrap ordinary values              | Extensibility with generic fallback      | Tag semantics need separate validation        |
| Two named deterministic key orders     | Preserve old uses and specify core rules | "Canonical CBOR" alone remains ambiguous      |

## Sources

- [RFC 8949][rfc], especially §§3, 4.2, 5.6, and 10.
- [RFC 8610][cddl]: optional schema language, not a foreign-layout language.
- [`libcbor` loader][loader], [stream decoder][stream], and [stack bound][stack].
- [CNA record for CVE-2026-26209][cve-depth]: affected library and version scope.
- [C++ binary writer][writer]: actual probe implementation.

<!-- References -->

[rfc]: https://www.rfc-editor.org/rfc/rfc8949
[objectives]: https://www.rfc-editor.org/rfc/rfc8949#section-1.1
[terminology]: https://www.rfc-editor.org/rfc/rfc8949#section-1.2
[model]: https://www.rfc-editor.org/rfc/rfc8949#section-2
[specific]: https://www.rfc-editor.org/rfc/rfc8949#section-2.2
[encoding]: https://www.rfc-editor.org/rfc/rfc8949#section-3
[major]: https://www.rfc-editor.org/rfc/rfc8949#section-3.1
[indefinite]: https://www.rfc-editor.org/rfc/rfc8949#section-3.2
[chunks]: https://www.rfc-editor.org/rfc/rfc8949#section-3.2.3
[floats]: https://www.rfc-editor.org/rfc/rfc8949#section-3.3
[tags]: https://www.rfc-editor.org/rfc/rfc8949#section-3.4
[self-described]: https://www.rfc-editor.org/rfc/rfc8949#section-3.4.6
[preferred]: https://www.rfc-editor.org/rfc/rfc8949#section-4.1
[core]: https://www.rfc-editor.org/rfc/rfc8949#section-4.2.1
[additional]: https://www.rfc-editor.org/rfc/rfc8949#section-4.2.2
[length-first]: https://www.rfc-editor.org/rfc/rfc8949#section-4.2.3
[validity]: https://www.rfc-editor.org/rfc/rfc8949#section-5.3
[evolution]: https://www.rfc-editor.org/rfc/rfc8949#section-5.4
[keys]: https://www.rfc-editor.org/rfc/rfc8949#section-5.6.1
[undefined]: https://www.rfc-editor.org/rfc/rfc8949#section-5.7
[security]: https://www.rfc-editor.org/rfc/rfc8949#section-10
[vectors]: https://www.rfc-editor.org/rfc/rfc8949#appendix-A
[cddl]: https://www.rfc-editor.org/rfc/rfc8610
[loader]: https://github.com/PJK/libcbor/blob/ab8c72b1b26c0c3a6a462a11055bf7000a9d2ef5/src/cbor.c
[stream]: https://github.com/PJK/libcbor/blob/ab8c72b1b26c0c3a6a462a11055bf7000a9d2ef5/src/cbor/streaming.c
[stack]: https://github.com/PJK/libcbor/blob/ab8c72b1b26c0c3a6a462a11055bf7000a9d2ef5/src/cbor/internal/stack.c
[writer]: https://github.com/nlohmann/json/blob/cd6b428ef087fb0ce06a7daaa547f71d2907e948/include/nlohmann/detail/output/binary_writer.hpp
[cve-depth]: https://cveawg.mitre.org/api/cve/CVE-2026-26209
[cve-tags]: https://rustsec.org/advisories/RUSTSEC-2019-0025.html
[flat]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
[profiles]: ./cbor-cose-dcbor.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[in-place]: ./concepts.md#in-place-access-and-zero-copy
