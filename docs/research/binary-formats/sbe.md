# Simple Binary Encoding (Java/C++ and other bindings)

A schema-defined fixed-block encoding for low-latency messages, with sequential
groups and variable data rather than a general offset graph.

| Field                   | Value                                                                                                      |
| ----------------------- | ---------------------------------------------------------------------------------------------------------- |
| Language                | Java generator; Java, C, C++, C#, Go and Rust implementations                                              |
| License                 | Apache-2.0 for the [reference implementation][repo]; FIX specification has its own [license][spec-license] |
| Repository              | [Reference implementation][repo] · [FIX specification][spec-repo]                                          |
| Documentation           | [Field encoding][fields] · [message structure][structure] · [extension rules][evolution]                   |
| Category                | Schema-first fixed blocks with sequential variable tails                                                   |
| Reviewed implementation | `a2851c4550d14b83a587e98c7aff8936d3a9d4c0`                                                                 |
| Reviewed specification  | `418a8f6a8b93c65b308638dab2bc6a35dddcd864`, `v1-0-STANDARD` sources                                        |

## Overview

### What it solves

SBE targets predictable encoding/decoding work for financial messages. Stable
fixed-width fields can be read directly from a buffer at known offsets, while
repeating groups and variable data follow the fixed block. Schema evolution
preserves existing field offsets and communicates the sender's block length
and version. [Introduction][intro], [extension mechanism][evolution]

### Design philosophy

The [specification introduction][intro] says:

> SBE strives to use native binary datatypes in order to make conversion
> unnecessary, or at least trivial.

"Native" here means cheap primitive access, not copying a language ABI struct
or assuming every message is naturally aligned. The schema owns offsets and
byte order. This is the closest surveyed interchange family to the draft
Flat reader's per-leaf load goal, but its variable tails and evolution policy
remain different. See [concepts][concepts] and [comparison][comparison].

## How it works

### Schema source of truth

XML schemas define primitive encodings, composites, enums, bit sets, messages,
groups and variable data. An XSD constrains that vocabulary; the reference
generator turns it into an intermediate representation and language codecs.
The schema fixes byte order and field offsets independently of the host ABI.
[Schema chapter][schema], [reference XSD][xsd]

Field IDs express semantic identities but are not repeated tags in each
message's fixed block. A receiver uses `schemaId`, `templateId` and version
to choose the appropriate codec. A header identifies a known schema; it does
not inline the full schema or describe every field. [Message structure][structure]

The [serde catalog][serde] addresses host-model derivation. SBE's normal seam
is an external wire schema and a generated flyweight codec, not automatic
serialization of any host-language object representation.

### Wire encoding

A message has an encoding header, a fixed root block, repeating groups and
variable-length data in the schema's permitted order. The root block length
excludes groups and variable data. Fixed-width fields use the declared byte
order; schemas can specify little- or big-endian. [Structure][structure], [fields][fields]

Do not assume all SBE headers are eight bytes. The reviewed specification's
recommended header has six `uint16` members and is twelve bytes, including
group/variable-data counts. The reference `Car` test uses the familiar
eight-byte four-member header: block length, template ID, schema ID and
version. Both facts are visible in the primary sources. [Structure][structure], [codec tests][codec-tests]

**Upstream reference vector, not a local codec run:** the FIX specification's
[first example][examples] begins:

```text
00 00 00 44 eb 50 36 00 63 00 5b 00 00 00
```

The first six bytes are the example's Simple Open Framing Header: big-endian
total length `0x44` and encoding identifier `eb 50`. The following bytes are
the example's little-endian SBE header: block length `0x36`, template `0x63`,
schema `0x5b`, version `0`. This is the published example's prefix, not a
claim that every SBE deployment uses that header layout.

### Access model

Generated flyweights wrap a buffer, offset and bounds. Fixed fields are
accessed at schema-known offsets. Repeating groups and variable data advance
a shared position, so consuming them in the wrong order can change what the
next accessor reads. The [C++ generator][cpp] emits that stateful interface;
[field-order tests][order-tests] exercise optional access-order checking.

`wrapForDecode` takes `actingBlockLength` and `actingVersion` from the received
message, not simply the constants of the decoder's own schema. The initial
variable-data cursor is set after the **acting** block. Using the local block
length would enter new fixed fields as if they were the next group or string.
[Generated Java decoder][generated], [versioned message test][version-test]

Fixed-array indexing can be direct. A group whose entries contain nested
groups or variable data is not generally a uniform random-access array of
fixed structs. The next entry follows the preceding entry's complete content,
not just its fixed block. [Message structure][structure]

### Variable-length and optional data

Repeating-group dimensions carry the sender's block length and entry count;
entries contain fixed fields and can contain nested groups/variable data.
Variable data uses a schema-declared length/payload composite. This sequential
organization differs from table-relative pointers that can target anywhere in
a file. [Structure][structure], [field encoding][fields]

An optional fixed field normally occupies its fixed slot and uses a designated
null sentinel. It is not removed from the block when absent. A constant field
has no wire bytes. The encoding layer does not dictate the application default
to apply to a null optional field. [Field presence][fields]

Decimals are composites of mantissa/exponent with declared encoding rules,
not necessarily binary IEEE-754 approximations. Character arrays, byte arrays
and semantic string encodings must likewise follow the schema rather than a
host-language string representation. [Field encoding][fields]

### Evolution and compatibility

Compatible fixed-field extensions append to a block without moving or retyping
established fields. The wire block length lets an old decoder skip unfamiliar
fixed tail bytes. A new decoder uses `actingVersion` against `sinceVersion`
to avoid reading fields absent from an older message. [Extension rules][evolution]

The reference test `shouldV1DecodeV2Message` wraps a V1 decoder using the V2
block length/version and confirms that known fields plus the following string
remain readable. Its asserted decoded length is `26`. This is an upstream
test result contract, not a locally measured message size. [Version test][version-test]

Unknown groups/variable fields require the relevant header/dimension metadata
and a codec capable of skipping them; the eight-byte sample header alone does
not supply the extra counts of the twelve-byte recommendation. Compatibility
claims therefore need the concrete schema/profile, not just the label "SBE".
[Structure][structure], [evolution][evolution]

The [draft Flat][flat-draft] own-arena policy `WFL54` instead pins a layout and
rejects/rebuilds on mismatch. Its conditional foreign-format fields resemble
version-gated presence, but do not constitute SBE's full acting-block contract.

### Determinism and canonical form

**N/A as a universal canonical value encoding:** the layout is more prescribed
than a tagged field stream, but the cited standard does not define one global
normalization for padding, schema versions, decimal representations and float
bit patterns across semantically equivalent values. [Fields][fields], [structure][structure]

For a fixed schema, initialized buffer and fixed writing policy, repeatable
output is achievable. Unwritten reserved bytes still need a producer policy;
cheap setters are not proof that every byte has been initialized. The draft's
`WFL49` explicitly zeroes alignment gaps and pads, a useful reproducibility
rule that is still weaker than cross-representation canonicalization.
[Draft][flat-draft]

### Merkleization and content addressing

**N/A in SBE:** template IDs, schema IDs and version numbers name contracts,
not content. The message header supplies no cryptographic root and group
counts supply no child proofs. An application can encode a digest, but its
algorithm, domain separation and child interpretation are external.
[Message structure][structure]

Exact-message hashing can be useful once the producer defines initialization
and framing. It should not be confused with hashing a normalized business
event across versions or with the draft arena's caller-supplied input key.
See the [content-addressing catalog][cas] for those identity choices.

### Hostile-input safety

The reviewed [C++ generator][cpp] emits buffer-length checks and exceptions;
[`BoundsCheckTest.cpp`][bounds-tests] exercises truncation across root, groups
and variable data. An encoding specification and a fast flyweight are not by
themselves a complete hostile-input validator. Check the generated path and
any configuration that removes bounds checks.

Unaligned access deserves explicit attention. The C++ generator uses
`std::memcpy` into scalar temporaries, followed by endian-conversion macros,
rather than requiring an aligned `T*` at every wire field. This preserves the
language-level legality of packed reads and gives optimizing compilers an
opportunity to emit an unaligned load. It is not evidence of a particular
instruction sequence on every target. [C++ generator][cpp]

Counts and lengths need checked arithmetic and message bounds, and nested
groups can require separate work/depth admission policies. This page does
not infer a Cap'n Proto-style global traversal budget from SBE's block lengths.
The draft `WFL24` spells out such charging; the reference bounds tests prove
the cases they exercise, not that stronger global contract. [Bounds tests][bounds-tests]

### Describing foreign formats

**Limited, not arbitrary:** explicit widths, offsets, byte order and composites
can match some existing fixed blocks. The vocabulary is still organized around
SBE message headers, groups and length-prefixed variable data. It does not
generally express arbitrary table-relative offset graphs or dependent foreign
record variants. [Schema chapter][schema], [message structure][structure]

This makes SBE useful prior art for the draft's `WFL17`/`WFL52` accessors, not
a replacement for its OpenType-description acceptance set. The draft `WFL45`
four-byte ceiling is an **arena** restriction; its foreign accessors can still
read packed 64-bit leaves. SBE's `memcpy`-based access illustrates why scalar
access need not require a native record reference. [Draft][flat-draft], [C++ generator][cpp]

### Implementation and performance evidence

The [reference implementation's language list][languages] names Java, C, C++,
C#, Go and Rust, not D. No D binding was verified by the targeted repository
and DUB search; that is not proof that none exists. The independent D invariant
below is not a binding or evidence of an upstream-supported D runtime.

The [reference benchmark sources][bench] include Java and C++ workloads.
`CarBenchmark` explicitly reads the received header's acting length/version
before wrapping the message. The [C++ generator][cpp] is inspectable evidence
for unaligned/endian access, not a substitute for assembly or latency measures.

No SBE generator, benchmark or full test suite was run for this page. The hex
prefix is a labeled FIX specification vector; the V1/V2 and bounds behaviors
are precise upstream tests. No numbers from vendor charts are promoted into a
cross-format result or a speedup for the unimplemented Flat reader.

This **independent header invariant check** reads the published example's
prefix. It is not an SBE codec: it checks only the selected example's framing
and eight-byte header, without interpreting the message body.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "binary_sbe_invariant"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : writeln;

uint le16(const(ubyte)[] bytes, size_t at) @safe pure nothrow @nogc
{
    assert(at < bytes.length && bytes.length - at >= 2);
    return bytes[at] | (uint(bytes[at + 1]) << 8);
}

void main() @safe
{
    immutable ubyte[14] bytes = [0, 0, 0, 0x44, 0xEB, 0x50,
        0x36, 0, 0x63, 0, 0x5B, 0, 0, 0];
    const frame = (uint(bytes[0]) << 24) | (uint(bytes[1]) << 16)
        | (uint(bytes[2]) << 8) | bytes[3];
    const block = le16(bytes[], 6);
    assert(frame == 68 && block == 54 && 6 + 8 + block == frame);
    assert(le16(bytes[], 8) == 99 && le16(bytes[], 10) == 91);
    assert(le16(bytes[], 12) == 0);
    writeln("frame=", frame, " block=", block, " template=", le16(bytes[], 8),
        " schema=", le16(bytes[], 10), " version=", le16(bytes[], 12));
}
```

```ansi
frame=68 block=54 template=99 schema=91 version=0
```

## Strengths

- Direct fixed-field access with explicit endian and schema layout.
- Acting block length/version make additive fixed tails practical.
- Optional fixed values avoid per-field tag/branch framing.
- Concrete code-generation and compatibility/bounds tests are available.

## Weaknesses

- Variable sections require stateful sequential traversal.
- Null sentinels consume part of a field's value space.
- Header/profile differences must accompany compatibility claims.
- Neither general foreign offset graphs nor canonical content hashing is supplied.

## Key design decisions and trade-offs

| Decision                        | Rationale                                    | Trade-off                                       |
| ------------------------------- | -------------------------------------------- | ----------------------------------------------- |
| Fixed blocks                    | Cheap predictable scalar access              | Optional values keep their slots                |
| Acting block length             | Skip future fixed tail fields                | Decoder must use sender metadata correctly      |
| Sequential groups/data          | Compact traversal without arbitrary pointers | Order-sensitive variable access                 |
| `memcpy` plus endian conversion | Legal packed scalar loads                    | Instruction quality still needs target evidence |

## Sources

- FIX [introduction][intro], [field encodings][fields], [message structure][structure],
  [schema][schema], [evolution rules][evolution] and [hex examples][examples].
- Reference [C++ generator][cpp], [generated Java decoder][generated],
  [versioned tests][version-test], [bounds tests][bounds-tests] and [benchmarks][bench].
- Proposed [Flat contract][flat-draft], not an implementation claim.

<!-- References -->

[repo]: https://github.com/real-logic/simple-binary-encoding/tree/a2851c4550d14b83a587e98c7aff8936d3a9d4c0
[spec-repo]: https://github.com/FIXTradingCommunity/fix-simple-binary-encoding/tree/418a8f6a8b93c65b308638dab2bc6a35dddcd864
[spec-license]: https://github.com/FIXTradingCommunity/fix-simple-binary-encoding/blob/418a8f6a8b93c65b308638dab2bc6a35dddcd864/LICENSE
[intro]: https://github.com/FIXTradingCommunity/fix-simple-binary-encoding/blob/418a8f6a8b93c65b308638dab2bc6a35dddcd864/v1-0-STANDARD/doc/01Introduction.md
[fields]: https://github.com/FIXTradingCommunity/fix-simple-binary-encoding/blob/418a8f6a8b93c65b308638dab2bc6a35dddcd864/v1-0-STANDARD/doc/02FieldEncoding.md
[structure]: https://github.com/FIXTradingCommunity/fix-simple-binary-encoding/blob/418a8f6a8b93c65b308638dab2bc6a35dddcd864/v1-0-STANDARD/doc/03MessageStructure.md
[schema]: https://github.com/FIXTradingCommunity/fix-simple-binary-encoding/blob/418a8f6a8b93c65b308638dab2bc6a35dddcd864/v1-0-STANDARD/doc/04MessageSchema.md
[evolution]: https://github.com/FIXTradingCommunity/fix-simple-binary-encoding/blob/418a8f6a8b93c65b308638dab2bc6a35dddcd864/v1-0-STANDARD/doc/05SchemaExtensionMechanism.md
[examples]: https://github.com/FIXTradingCommunity/fix-simple-binary-encoding/blob/418a8f6a8b93c65b308638dab2bc6a35dddcd864/v1-0-STANDARD/doc/07Examples.md
[xsd]: https://github.com/real-logic/simple-binary-encoding/blob/a2851c4550d14b83a587e98c7aff8936d3a9d4c0/sbe-tool/src/main/resources/fpl/sbe.xsd
[cpp]: https://github.com/real-logic/simple-binary-encoding/blob/a2851c4550d14b83a587e98c7aff8936d3a9d4c0/sbe-tool/src/main/java/uk/co/real_logic/sbe/generation/cpp/CppGenerator.java
[generated]: https://github.com/real-logic/simple-binary-encoding/blob/a2851c4550d14b83a587e98c7aff8936d3a9d4c0/sbe-tool/src/main/java/uk/co/real_logic/sbe/ir/generated/FrameCodecDecoder.java
[version-test]: https://github.com/real-logic/simple-binary-encoding/blob/a2851c4550d14b83a587e98c7aff8936d3a9d4c0/sbe-tool/src/test/cpp/VersionedMessageTest.cpp
[codec-tests]: https://github.com/real-logic/simple-binary-encoding/blob/a2851c4550d14b83a587e98c7aff8936d3a9d4c0/sbe-tool/src/test/cpp/CodeGenTest.cpp
[bounds-tests]: https://github.com/real-logic/simple-binary-encoding/blob/a2851c4550d14b83a587e98c7aff8936d3a9d4c0/sbe-tool/src/test/cpp/BoundsCheckTest.cpp
[order-tests]: https://github.com/real-logic/simple-binary-encoding/blob/a2851c4550d14b83a587e98c7aff8936d3a9d4c0/sbe-tool/src/test/cpp/FieldAccessOrderCheckTest.cpp
[bench]: https://github.com/real-logic/simple-binary-encoding/tree/a2851c4550d14b83a587e98c7aff8936d3a9d4c0/sbe-benchmarks
[flat-draft]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
[languages]: https://github.com/real-logic/simple-binary-encoding/blob/a2851c4550d14b83a587e98c7aff8936d3a9d4c0/README.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[serde]: ../serde/index.md
[cas]: ../content-addressing/index.md
