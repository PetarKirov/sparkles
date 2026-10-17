# DFDL (Open Grid Forum / Apache Daffodil)

A descriptive schema language for existing text and binary formats, pairing XML Schema's logical structure with explicit representation properties.

| Field                   | Value                                                                             |
| ----------------------- | --------------------------------------------------------------------------------- |
| Language                | Annotated XSD plus XPath-derived expressions; Daffodil implementation in Scala    |
| License                 | OGF standard copyright terms; Daffodil Apache-2.0 ([license][license])            |
| Repository              | [`apache/daffodil` at `b5892e183284a0cd981d798541d45e0378611473`][repo]           |
| Documentation           | [DFDL 1.0, GFD-R-P.240 (February 2021)][spec]                                     |
| Category                | Separate descriptive IDL; parsing and unparsing                                   |
| Distinguishing boundary | Describes existing representations rather than imposing one universal wire format |

## Overview

### What it solves

[DFDL][spec] addresses data that cannot be redesigned merely to suit a new
consumer: fixed-width records, binary scientific data, delimited interchange,
and legacy encodings. The logical schema says what values exist; annotations
say how their representation is found and decoded. Endianness, bit order,
length, alignment, number representation, and separators are format facts,
not incidental parser code.

That makes DFDL a stronger foreign-format comparison than a generic
serialization framework. The [Serde catalog][serde] covers mapping host
values through an abstract data model; DFDL can instead describe bytes laid
out by someone else's producer. This does not imply that every pointer-based
file format is expressible in standard DFDL 1.0.

### Design philosophy

The [standard's introduction][spec] states the organizing distinction:

> DFDL is not a format for data; it is a way of describing any data format.

The same standard immediately qualifies that breadth. Section 1.3 says that
the data model's order and structure must correspond to the described data
and that recursive definitions are unsupported. Read the slogan together with
those constraints, not as a claim of arbitrary object-graph parsing.

## How it works

A schema annotates elements or reusable format definitions. An illustrative
fragment, **not a complete executable schema**, fixes a 16-bit big-endian leaf:

```xml
<xs:element name="count" type="xs:unsignedShort"
    dfdl:representation="binary"
    dfdl:binaryNumberRep="binary"
    dfdl:byteOrder="bigEndian"
    dfdl:lengthKind="explicit"
    dfdl:lengthUnits="bits"
    dfdl:length="16"/>
```

Namespaces, required defaults, and enclosing schema declarations are omitted
here. The standard itself warns that explanatory fragments may omit required
properties (§3). A processor compiles the schema, parses native data into the
[DFDL infoset][spec], or unparses an infoset into the native representation.
XML/JSON rendering of that infoset is optional, not the native wire format.

### Schema source of truth

The annotated XSD is authoritative. Its logical structure is constrained by
the physical format; it is not an arbitrary business-object model followed
by a transformation. [DFDL §§1.3, 4–5][spec] defines that correspondence.

Reusable `dfdl:defineFormat` and property-scoping rules avoid repeating every
representation property on every field (§§7.2, 8). This is analogous in purpose
to inherited host-type annotations, but resolution belongs to a separate
schema language and has its own conflict/error rules.

### Wire encoding

There is no DFDL wire encoding. Binary integer widths, signedness,
`byteOrder`, `bitOrder`, text encodings, delimiters, fill bytes, and alignment
are selected by schema properties ([DFDL §§11–13][spec]). A text field and a
binary field can coexist in one described record.

`lengthKind` distinguishes `explicit`, `delimited`, `implicit`, `prefixed`,
`pattern`, and `endOfParent` (§12.3). These are not cosmetic alternatives:
they select the method used to discover a field's boundary. An implicit
binary integer length is not necessarily a host compiler's integer layout.

### Access model

The standard defines parse/unparse semantics over an infoset and permits
implementations to optimize access. Its introduction mentions seekable and
lazy implementations as possibilities; that is not a Daffodil borrowed-view
contract. The [Daffodil README][repo] describes parsing to an infoset, including
direct framework integration that bypasses XML/JSON conversion.

Speculative choices introduce points of uncertainty. A parser may need to
retain input/state while exploring an alternative, then backtrack; a
`dfdl:discriminator` commits interpretation ([DFDL §§7.6, 9, 15][spec]).
Opening a description therefore need not have the constant-work behavior of
opening a fixed-layout view.

### Variable-length and optional data

XSD occurrence bounds combine with `dfdl:occursCountKind`. An expression can
read a sibling count, while `parsed` and `implicit` discover occurrences by
other rules. Optional, nil, empty, absent, and zero-length representations
are distinct ([DFDL §§9.2, 13.15–13.16, 16][spec]). Treating them all as a
single nullable host pointer loses information.

Calculated values support asymmetry between wire and logical fields.
`dfdl:outputValueCalc` can derive an output count from the infoset array;
`dfdl:inputValueCalc` introduces computed logical values (§17).
[Daffodil's `ovc_09` fixture][vectors] pairs
`occursCount="{ ../ex:count }"` with an output count calculated by
`fn:count(../ex:e1)`. This is real sibling-count evidence, not inferred support.

### Evolution and compatibility

DFDL can describe version-dependent alternatives, optional tails, and explicit
dispatch. It does not define a universal unknown-field framing convention.
Whether an old reader can skip a new part depends on the **foreign format's**
lengths, delimiters, tags, and version policy.

Updating a schema without changing a legacy file is a central use case, but
schema compatibility is not automatically data compatibility. Constraints,
defaults, discriminators, and branch ordering can change what values the same
bytes produce. Independent fixtures are needed for each accepted version
([DFDL §§9, 15–17][spec]).

### Determinism and canonical form

No universal canonical byte form is supplied. A description may recognize
multiple number spellings, delimiter forms, or absent/default representations
that map to one infoset. Section 9.2.8 explicitly discusses round-trip
ambiguities; parsing and then unparsing is not a guarantee of preserving
every original lexical choice.

A controlled unparser can emit repeatable bytes for a carefully constrained
schema, but a content-key contract must separately select padding, formatting,
normalization, and any otherwise ambiguous representation. “Bidirectional”
means a shared description supports both directions, not byte-injective parsing.

### Merkleization and content addressing

Not provided. A DFDL description can include checksum or digest fields, but
does not specify child-link semantics, hash algorithms, chunking, or a
canonical graph. Its infoset is not a Merkle tree merely because it is
hierarchical. See the [content-addressing vocabulary][content-addressing].

For legacy bytes, hashing the exact input and hashing an unparsed normalized
infoset are different identities. DFDL's representation flexibility makes
that choice particularly important: normalization can deliberately discard
lexical distinctions a forensic/archive consumer must preserve.

### Hostile-input safety

Untrusted data can drive counts, delimiter scans, expression evaluation,
speculation, and buffering. The [standard's security discussion (§24)][spec]
belongs alongside its forward-progress requirement (§16.6), not in place of
implementation-specific limits. A parser that always advances can still do
too much work or allocate too much.

Separate trusted schemas from untrusted inputs. Schema imports and external
resources also enlarge the authority boundary; a protocol service should not
accept arbitrary caller-controlled schema resolution by default. Neither
the notation nor this source review proves a global time/memory bound.

Validation errors deserve special attention: [DFDL §3.2][spec] says optional
validation failures must not influence parsing behavior. Security conditions
that must reject data cannot be assumed to act as parser discriminators
merely because they look like XSD restrictions.

### Describing foreign formats

DFDL directly addresses endian leaves, alignment, sibling-counted arrays,
flag-dependent choices, and length-dependent layouts. It is therefore useful
prior art for the [Flat draft's][flat] count/condition vocabulary.

The difficult OpenType case is **out-of-line graph navigation**. DFDL 1.0's
correspondence/order restriction and lack of recursive definitions mean an
arbitrary `Offset16`/`Offset32` relative to an ancestor is not established by
having an XPath expression language. Forward padding to an offset in a
particular ordered file is weaker than general seek-and-return traversal of
shared subtables. No standard primitive equivalent to a typed, bounded,
ancestor-relative offset was verified here.

Similarly, direct dispatch (§15.1.2) selects a branch at the current parsing
point; it does not make that branch a zero-copy tagged view. A D host-type
design can use semantic introspection instead of XSD, but still needs explicit
rules for region bounds, null offsets, shared targets, and variant validity.

### Implementation and performance evidence

The [pinned `outputValueCalc.tdml`][vectors] supplies exact unparser vectors:
`binaryIntegerBigEndian` maps decimal `437984285` to `1A1B1C1D`, while
`binaryIntegerLittleEndian` maps it to `1D1C1B1A`. The schemas declare
`length="32"`, `lengthUnits="bits"`, and the respective byte orders. These
are inspected upstream expectations; Daffodil was **not executed** here.

The same file's `ovc_09` test expects text `2ab` from a two-element array with
the count derived on output. Together these cases provide stronger evidence
than a marketing statement about “arbitrary binary.” They do not exercise
OpenType offset graphs or establish their support.

Daffodil documents JVM processing and a C toolchain in its [build material][repo].
No latency, throughput, memory comparison, or D port/binding was verified.
In particular, a C code-generation path is not evidence of a maintained D
binding or the Flat draft's `@safe pure nothrow @nogc` contract.

This portable D check maintains the two upstream vectors' endian invariant.
It executes integer assembly only, **not** Daffodil or a DFDL processor.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "binary_dfdl_endian_probe"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : writeln;

void main() @safe
{
    immutable ubyte[] be = [0x1a, 0x1b, 0x1c, 0x1d];
    immutable ubyte[] le = [0x1d, 0x1c, 0x1b, 0x1a];
    uint big, little;
    foreach (b; be)
        big = (big << 8) | b;
    foreach (i, b; le)
        little |= cast(uint)b << (8 * i);
    assert(big == 437984285 && little == big);
    writeln("DFDL fixtures: BE=437984285 LE=437984285");
}
```

```ansi
DFDL fixtures: BE=437984285 LE=437984285
```

## Strengths

- Explicit separation between logical structure and existing representation.
- Rich framing, text/binary mixing, sibling-count, and computed-output vocabulary.
- Bidirectional processing without requiring XML/JSON on the native wire.
- Normative treatment of uncertainty, validation, absence, and round-trip ambiguity.

## Weaknesses

- XSD and property scoping impose a substantial schema/compiler surface.
- Not a demonstrated arbitrary pointer-graph or recursive font-layout solution.
- Parse/unparse symmetry does not imply exact lexical preservation.
- Resource limits and zero-copy access are implementation questions.

## Key design decisions and trade-offs

| Decision                             | Rationale                                | Trade-off                                            |
| ------------------------------------ | ---------------------------------------- | ---------------------------------------------------- |
| Annotate XSD                         | Reuse established type/schema machinery  | Verbose separate IDL and restricted XSD subset       |
| Describe rather than prescribe bytes | Integrate legacy producers unchanged     | Compatibility depends on each described format       |
| Shared parse/unparse schema          | Keep representation facts together       | Ambiguous representations can normalize on output    |
| Expressions and calculated values    | Model sibling counts and derived framing | Dependency scheduling and possible unparse deadlocks |
| Speculation with discriminators      | Handle formats without explicit tags     | Buffering/work must be controlled                    |

## Sources

- [DFDL 1.0 GFD-R-P.240 §§1, 3–5, 7–18, 24][spec].
- [Daffodil README][repo]: implementation model and direct infoset integration.
- [`outputValueCalc.tdml`][vectors]: count expressions and endian vectors.
- [Flat draft §§4–6][flat]: comparison target, not a delivered implementation.

<!-- References -->

[spec]: https://daffodil.apache.org/docs/dfdl/
[repo]: https://github.com/apache/daffodil/blob/b5892e183284a0cd981d798541d45e0378611473/README.md
[license]: https://github.com/apache/daffodil/blob/b5892e183284a0cd981d798541d45e0378611473/LICENSE
[vectors]: https://github.com/apache/daffodil/blob/b5892e183284a0cd981d798541d45e0378611473/daffodil-test/src/test/resources/org/apache/daffodil/section17/calc_value_properties/outputValueCalc.tdml
[flat]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
[serde]: ../serde/serde.md
[content-addressing]: ../content-addressing/concepts.md
