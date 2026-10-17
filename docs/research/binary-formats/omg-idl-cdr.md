# OMG IDL, CDR, and XCDR2 (OMG / C++)

A cross-language type system with standardized stream encodings, adding explicit extensibility and member framing rather than exposing host structs on disk.

| Field         | Value                                                                         |
| ------------- | ----------------------------------------------------------------------------- |
| Language      | OMG IDL; surveyed codec implementation in C++                                 |
| License       | OMG specification terms; Fast CDR Apache-2.0 ([license][license])             |
| Repository    | [`eProsima/Fast-CDR` at `03cb3bf14671c7dcc8c64668d06b324b6de50ca0`][repo]     |
| Documentation | [CORBA 3.4 interoperability][corba], [DDS-XTypes 1.3][xtypes], [IDL 4.2][idl] |
| Category      | Separate interface/data IDL; prescriptive CDR/XCDR stream codecs              |
| Scope         | CDR and XCDR2 representation; not DDS transport, discovery, or RPC semantics  |

## Overview

### What it solves

[OMG IDL][idl] supplies a language-independent authority for types that must
cross implementation and machine boundaries. [CDR][corba] defines their
external representation; [DDS-XTypes][xtypes] adds type assignability,
extensibility, and versioned encodings. Native padding, pointer values, and
the spelling of a host language's container are not wire contracts.

This page separates those layers. An IDL compiler can generate bindings,
while a CDR library encodes values under the prescribed rules. Neither the
presence of an IDL nor a fast codec proves arbitrary binary-layout description
or direct memory-mapped access. [Serde][serde] is adjacent host-value machinery,
not a replacement for the CDR representation specification.

### Design philosophy

The [OMG XTypes description][about] states:

> The specification defines a model of the data types that can be used for DDS Topics.

The focus is interoperable typed values, not an ABI snapshot. Extensibility is
a declared property of a type and influences its encoding. This is a useful
contrast with the [Flat draft][flat], whose arena policy rejects a mismatched
layout and rebuilds rather than negotiating assignable type revisions.

## How it works

An illustrative extensible declaration makes member identities explicit:

```text
@mutable
struct Sample {
    @id(1) unsigned short kind;
    @id(2) sequence<octet> payload;
};
```

The IDL `unsigned long` is 32 bits; it must not be confused with a platform's
C/C++ `unsigned long`. A codec tracks byte order, stream position, alignment,
and the encoding algorithm. XCDR2 selects a format from the type's
extensibility kind ([DDS-XTypes §7.4.2 and Table 35][xtypes]).

### Schema source of truth

IDL declarations and their annotations define portable types. Language
mapping/generated classes are downstream. XTypes also defines dynamic type
representations and assignability rules, so type authority is not equivalent
to a host compiler's `offsetof` calculations (§§7.2–7.3).

[Fast CDR][repo] is a codec library, not the IDL standard or a complete IDL
compiler. Its [tests][vectors] include IDL-shaped comments and hand-written
serialization routines; those are evidence for codec behavior, not proof
that this repository alone generates every language binding.

### Wire encoding

Classic CDR serializes primitives with specified widths and alignment,
collections with defined framing, and selected endianness. Alignment is
relative to the defined stream origin/state, not the pointer address of an
arbitrary enclosing C++ object ([CORBA interoperability §9.3][corba]).

[DDS-XTypes §7.4.2][xtypes] distinguishes three XCDR2 formats:

| Type extensibility | XCDR2 format    | Framing consequence                                    |
| ------------------ | --------------- | ------------------------------------------------------ |
| `FINAL`            | `PLAIN_CDR2`    | Positional fields without per-member evolution headers |
| `APPENDABLE`       | `DELIMITED_CDR` | A `DHEADER` bounds the serialized object               |
| `MUTABLE`          | `PL_CDR2`       | `DHEADER` plus member `EMHEADER`s with IDs and lengths |

The Fast CDR spelling `DELIMIT_CDR2` corresponds to the standard's delimited
format. XCDR2 aligns 64-bit quantities to four bytes rather than CDR's eight;
its reduced alignment ceiling does **not** make all members naturally aligned
for a host-native `double` reference.

### Access model

The normative [XCDR virtual machine (§7.4.3)][xtypes] is a linear byte stream
with state, not a record-overlay model. Variable collections and preceding
padding affect the positions of later fields. A decoder can avoid building a
generic tree without exposing the original bytes as a host aggregate.

Delimited objects and member lengths permit skipping unknown data. That
improves evolution and traversal, but does not provide a persistent index for
constant-time arbitrary member access. [Fast CDR's `Cdr` implementation][cdr]
tracks stream state and dispatches codecs; zero-copy transport features in
DDS should not be attributed to the CDR encoding by association.

### Variable-length and optional data

IDL distinguishes fixed arrays, bounded/unbounded sequences, strings, unions,
and optional members. Sequence counts are part of the CDR representation,
not arbitrary sibling fields chosen by a foreign layout. Bounds in a schema
can constrain accepted sizes without turning a sequence into inline native
slice storage.

XTypes optional-member handling differs by encoding format; a mutable
member's absence can be represented by omission, whereas other formats have
their specified presence/header mechanisms. [Fast CDR's optional tests][optional]
exercise the combinations. A tagged IDL union serializes the discriminator
and the active branch under standard rules, not at arbitrary fixed offsets.

### Evolution and compatibility

`FINAL`, `APPENDABLE`, and `MUTABLE` are different compatibility policies, not
performance presets. Appendable types preserve the required member ordering;
mutable types use member IDs to support identification independent of
declaration order. Unknown must-understand members can force rejection
([DDS-XTypes §§7.2, 7.4.1.2, 7.4.2–7.4.3][xtypes]).

Assignability also constrains types and values: numeric conversions, bounds,
keys, and construction policy matter. A reader finding a skippable unknown
member is not by itself evidence that the sender and receiver types are
semantically compatible. Stable member IDs must survive source refactoring.

### Determinism and canonical form

CDR interoperability is not universal canonicalization. Endianness and
representation version admit different bytes for corresponding values.
Mutable-member ordering and header choices add further distinctions; even
the standard's XCDR1 parameter discussion explicitly allows equivalent short
and extended headers (§7.4.1.2.2).

A reproducible application can fix these choices and initialization of pads,
but “CDR-encoded” is insufficient as a canonical hash domain. XTypes rules
for type identifiers or key-related serialization are specialized domains,
not a blanket canonical representation of every application sample.

### Merkleization and content addressing

Not supplied for application samples. `DHEADER` and `EMHEADER` carry length
and identity metadata, not child-content digests. An XTypes type identifier
identifies type information, not the serialized content of a sample.

One can hash a selected representation or put digests in IDL members, but
must define the hash domain and graph semantics separately. The
[content-addressing catalog][content-addressing] explains why canonical
serialization and independently addressed subobjects remain separate choices.

### Hostile-input safety

A decoder must check lengths before allocation and before advancing past a
delimited region; member lengths must not escape their enclosing object.
Unknown IDs, malformed headers, invalid booleans, huge sequence counts, and
truncation are independent tests. [Fast CDR's implementation][cdr] and
[optional-member fixtures][optional] are the relevant code, not an assurance
that validly encoded input has acceptable resource cost.

The IDL schema's collection bound is useful only where actually enforced.
A stream reader should additionally cap total input, nested object depth,
aggregate allocation, and work. No product-specific security incident or
complete global budget was established in this review; no security ranking
is inferred from that absence.

### Describing foreign formats

CDR prescribes the encoding rather than describing arbitrary storage.
OpenType's big-endian `Offset16`/`Offset32`, ancestor-relative targets,
sibling-count arrays, and shared tagged subtables do not become CDR layouts
by spelling their logical fields in IDL. Encoding those types as CDR would
produce a new representation.

An integer can carry an offset value, but the standard codec does not follow
it as a bounded borrowed reference relative to a named ancestor. Likewise an
IDL union solves semantic variant selection, not a discriminator at an
arbitrarily positioned byte in a foreign subtable. These are distinct
requirements in [Flat §§5–6][flat].

### Implementation and performance evidence

[Fast CDR's `short` test][vectors] contains exact vectors for signed
`0x7DDC`. The following are **upstream expected bytes**, not locally measured
codec output; the final two encapsulation octets are the fixture's options:

```text
PLAIN_CDR, big endian:       00 00 00 02 7d dc
PLAIN_CDR2, little endian:   00 07 00 02 dc 7d
DELIMIT_CDR2, little endian: 00 09 00 02 02 00 00 00 dc 7d
PL_CDR2, little endian:      00 0b 00 02 06 00 00 00 01 00 00 10 dc 7d
```

The last vector shows a four-byte delimited length, then a four-byte member
header, then the two-byte value. It is a useful independent oracle for a
layout implementation; it is not a claim that all encapsulation options must
equal this fixture's value. [The XCDR2 suite][xcdr2] also checks decoder version
selection from the encapsulation.

The [README][repo] distinguishes standards-conforming CDR from its modified
Fast CDR mechanism. Do not silently benchmark the latter and attribute the
result to standard XCDR2. No benchmark or local Fast CDR build was run, and
no maintained D binding was verified.

This portable D sample checks the delimited fixture's length/origin invariant,
**not** a general XCDR2 decoder or a local Fast CDR execution.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "binary_xcdr2_delimiter_probe"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : writeln;

void main() @safe
{
    immutable ubyte[] bytes = [0, 9, 0, 2, 2, 0, 0, 0, 0xdc, 0x7d];
    uint length;
    foreach (i, b; bytes[4 .. 8])
        length |= cast(uint)b << (8 * i);
    assert(length == 2 && length == bytes.length - 8);
    const value = cast(uint)bytes[8] | (cast(uint)bytes[9] << 8);
    assert(value == 0x7ddc);
    writeln("XCDR2 fixture: delimiter=2, value=32220, total=10");
}
```

```ansi
XCDR2 fixture: delimiter=2, value=32220, total=10
```

## Strengths

- Precise cross-language widths and representation rules.
- Explicit evolution categories and stable member identity.
- Delimited/member framing supports skipping and bounded subobject parsing.
- Rich upstream byte vectors distinguish encoding variants.

## Weaknesses

- Not a description language for existing offset-based files.
- Several encodings and annotation policies increase interoperability testing.
- Native memory layout and wire alignment remain different.
- General canonical bytes and resource bounds need extra policy.

## Key design decisions and trade-offs

| Decision                          | Rationale                              | Trade-off                                  |
| --------------------------------- | -------------------------------------- | ------------------------------------------ |
| IDL owns portable types           | Avoid host ABI dependence              | Generated mappings and build tooling       |
| Alignment in the stream           | Efficient primitive codecs             | Padding and stream origin affect positions |
| Distinct extensibility kinds      | Pay only for required evolution        | Policy changes can change encoding         |
| Mutable member IDs/lengths        | Reordering and unknown-member handling | Header overhead and ID management          |
| XCDR2 four-byte maximum alignment | Reduce padding                         | Does not guarantee host-natural wide loads |

## Sources

- [OMG IDL 4.2][idl]: type and annotation notation.
- [CORBA 3.4 interoperability §9.3][corba]: classic CDR.
- [DDS-XTypes 1.3 §§7.2–7.4, particularly §7.4.2][xtypes]: evolution and XCDR2.
- [Fast CDR basic-type][vectors], [optional][optional], and [XCDR2][xcdr2] tests.

<!-- References -->

[idl]: https://www.omg.org/spec/IDL/4.2/PDF
[corba]: https://www.omg.org/spec/CORBA/3.4/Interoperability/PDF
[about]: https://www.omg.org/spec/DDS-XTypes/1.3
[xtypes]: https://www.omg.org/spec/DDS-XTypes/1.3/PDF
[repo]: https://github.com/eProsima/Fast-CDR/blob/03cb3bf14671c7dcc8c64668d06b324b6de50ca0/README.md
[license]: https://github.com/eProsima/Fast-CDR/blob/03cb3bf14671c7dcc8c64668d06b324b6de50ca0/LICENSE
[cdr]: https://github.com/eProsima/Fast-CDR/blob/03cb3bf14671c7dcc8c64668d06b324b6de50ca0/src/cpp/Cdr.cpp
[vectors]: https://github.com/eProsima/Fast-CDR/blob/03cb3bf14671c7dcc8c64668d06b324b6de50ca0/test/xcdr/basic_types.cpp
[optional]: https://github.com/eProsima/Fast-CDR/blob/03cb3bf14671c7dcc8c64668d06b324b6de50ca0/test/xcdr/optional.cpp
[xcdr2]: https://github.com/eProsima/Fast-CDR/blob/03cb3bf14671c7dcc8c64668d06b324b6de50ca0/test/xcdr/xcdrv2.cpp
[flat]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
[serde]: ../serde/serde.md
[content-addressing]: ../content-addressing/concepts.md
