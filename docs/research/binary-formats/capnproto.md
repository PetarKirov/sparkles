# Cap'n Proto (C++ and other bindings)

A word-aligned pointer format with lazy checked traversal, schema evolution and
a separately specified canonical form, rather than a parse-into-objects encoding.

| Field           | Value                                                            |
| --------------- | ---------------------------------------------------------------- |
| Language        | C++ reference implementation and other language bindings         |
| License         | MIT; see [license][license]                                      |
| Repository      | [capnproto/capnproto][repo]                                      |
| Documentation   | [Encoding specification][encoding] · [schema language][language] |
| Category        | Schema-first segmented in-place object tree                      |
| Reviewed source | `b5ee48b9f3586fc83af8c429623e2c0d2435ec59`                       |

## Overview

### What it solves

Cap'n Proto lets a reader follow wire pointers without constructing a separate
object graph. The representation supports multiple independently allocated
segments, default values and schema extensions. RPC adds capability-oriented
communication, but this page concerns the data encoding and reader mechanics,
not a survey of its RPC protocol. [Encoding][encoding], [schema language][language]

### Design philosophy

The [encoding specification][encoding] puts validation at the access boundary:

> To avoid an upfront scan of the message (which would defeat Cap'n Proto's
> O(1) parsing performance), validation should occur lazily when the getter
> method for a pointer is called

Opening cheaply does not mean all subsequent work is free or all inputs are
trusted. Pointer bounds, traversal charges and nesting limits are integral to
this design. See the [shared concepts][concepts] and [comparison][comparison]
for its relationship to eager verification and borrowed in-place views.

## How it works

### Schema source of truth

A `.capnp` schema declares numbered fields, structs, lists, enums, unions and
interfaces. The compiler computes field placement independently of the host
language ABI. Field offsets depend on lower-numbered fields; higher-numbered
fields can fill padding without moving established fields. [Encoding][encoding]

The compiled schema carries layout information so another implementation need
not reproduce the full placement algorithm. A D binding would need that
semantic layout or a faithful schema compiler, not merely `offsetof` on a
convenient D struct. The [serde catalog][serde] examines host-type derivation
as a separate architectural choice.

The schema is not entirely needed for structural copying: splitting structs
into data and pointer sections makes pointer traversal possible without knowing
field names. It is still required for logical meaning and typed access.
[Encoding][encoding]

### Wire encoding

A word is eight bytes. Objects align to words; primitive fields align to their
width, except booleans which occupy individual bits. Integers and IEEE-754
floats use little-endian bytes. The first word of the first segment points to
the root struct. [Encoding][encoding]

A struct pointer packs a two-bit kind, signed 30-bit word offset relative to
the pointer's end, 16-bit data-section word count and 16-bit pointer-section
word count. A list pointer carries element-size information and a count;
inline-composite struct lists use an additional tag describing their layout.
Far pointers identify landing pads in other segments. [Encoding][encoding]

Stream framing carries segment counts and lengths before segment contents.
This frame is different from both a pointer within a segment and a content
digest. It also differs from the canonical form's hashing boundary, which
excludes the segment table. [Encoding][encoding]

**Upstream reference vector, not locally executed output:** the specification's
packing examples give a run of 32 zero bytes as:

```text
unpacked: 00 repeated 32 times
packed:   00 03
```

The first byte marks an all-zero word and the next counts three _additional_
zero words. This is a precise packing-layer example, not a complete framed
message. Packing compresses zeros and must be undone before ordinary in-place
reading. [Encoding, Packing][encoding]

### Access model

Generated `Reader` values refer to caller/message-reader storage and obtain
subreaders by following pointers. Bounds are checked when dereferencing, not
by a whole-object parse. [`MessageReader`][message] abstracts segment access;
[`layout.c++`][layout] implements the pointer arithmetic and validation.

The wire data structure is specified as an object **tree**, not a freely shared
application DAG. Malformed overlapping pointers are nevertheless difficult to
reject globally without scanning, which is why traversal limits exist.
Repeated getters can charge the same underlying bytes repeatedly.
[Encoding][encoding], [`ReaderOptions`][message]

Word alignment is a real source requirement, not just a schema property.
An arbitrary byte slice with only four-byte base alignment is not automatically
a suitable native segment. Endian-aware access does not erase that requirement.
The [endian helpers][endian] show how endian interpretation is implemented.

### Variable-length and optional data

Lists encode their element-size category and count. Struct lists keep elements
at a common data/pointer stride; text is a byte list with a final NUL included
in its encoded length but excluded from the exposed text length. `Data` is
a byte list without text semantics. [Encoding][encoding]

Data fields are XORed with their schema defaults, making all-zero storage
represent the default struct. Null pointer fields return their declared default
through accessors. A missing later field in a smaller old struct therefore
has meaningful default behavior without requiring rewritten old bytes.
[Encoding][encoding]

A zero-sized struct needs a non-null pointer representation distinct from the
all-zero null pointer. That distinction also appears in canonicalization,
which chooses offset `-1` for a pointer to a zero-sized struct.
Unions use a discriminant with shared storage; they are not arbitrary native
language tagged unions copied into the wire image. [Encoding][encoding]

### Evolution and compatibility

Established field numbers and layouts are preserved while later fields can
extend data/pointer sections or consume padding. Readers synthesize defaults
for fields outside an older object's sections. Lists have specified upgrade
rules; compatibility is not permission to arbitrarily change type or number.
[Encoding][encoding], [schema language][language]

The [draft Flat arena][flat-draft] takes a narrower cache-oriented approach:
`WFL54` couples a layout pin to a version and `WFL44` rejects mismatches.
Cap'n Proto's defaults and field placement let separately deployed versions
continue reading; Flat's own arenas instead rely on regenerating caches.
Neither policy should be silently described as the other.

### Determinism and canonical form

Cap'n Proto **does** specify a canonical message form. Ordinary encoders are
not required to emit it. The rules require a single segment, preorder object
placement and truncation of trailing zero-valued data/pointer words. Struct
lists truncate common all-zero trailing words consistently across elements.
Zero-sized struct pointers use offset `-1`. [Encoding, Canonicalization][encoding]

Canonical messages are unpacked. When hashing or signing, the segment table is
excluded. A sender can pack for transport and unpack before checking identity.
[`MessageReader::isCanonical`][message] exposes an actual check; canonical copy
logic is implemented in [`layout.c++`][layout].

The canonical form normalizes wire object structure, not every application's
equality relation. It does not, for example, reorder application lists that a
consumer treats as sets or normalize Unicode text. A content protocol must
still choose its logical model. [Encoding][encoding]

This is a stronger contract than the draft Flat builder's `WFL49`: repeatable
calls and zeroed pads do not specify preorder relocation and structural
normalization. The draft's layout digest likewise concerns schema
identity rather than canonical arena content. [Draft][flat-draft]

### Merkleization and content addressing

**N/A as a built-in Merkle graph:** ordinary pointers name segment locations,
not child content hashes. Canonicalization enables a stable whole-message hash
under its specified byte boundary; it does not add chunk proofs or independently
addressed subobjects. [Encoding][encoding]

An application can put digests in `Data` fields and define child-resolution
rules, but that is an additional protocol. The [content-addressing catalog][cas]
covers those systems. A canonical single segment and a Merkle DAG answer
different questions even when both use cryptographic hashes.

### Hostile-input safety

[`ReaderOptions`][message] defaults `traversalLimitInWords` to `8 * 1024 * 1024`
words, or 64 MiB of charged traversal, and `nestingLimit` to `64`. Getting the
same substructure repeatedly counts it repeatedly. The traversal limit follows
the reader's logical dereferences rather than counting distinct input bytes.

The [encoding specification][encoding] explains why: overlapping or cyclic
pointers can make a tiny message appear huge to a naive recursive traversal.
Bounds checks alone do not limit that amplification. [`layout.c++`][layout]
checks nesting while constructing subreaders and uses amplified-read charging
for logically large lists whose physical representation is small.

Lists of `Void` or zero-sized structs are particularly important. The encoding
specification requires counting zero-sized elements as if each were one word;
otherwise an attacker can advertise huge iteration work in constant wire space.
The first-party [2015 amplification advisory][advisory] and
[additional C++ advisory][advisory-extra] document real historical failures,
not merely a theoretical concern.

The draft `WFL24` adopts the same category of defense, but a different unit:
`max(extent, 1)` bytes per record, array element and string, with shared targets
charged on every visit and offset depth checked before target charge.
Its default region-size multiplier and clamps are provisional, unlike evidence
that the defense category is necessary. The [draft plan][flat-plan] requires
measuring charges/depth over real fonts before acceptance.

Lazy checks can report errors during application traversal; they do not offer
the draft's proposed all-errors-as-values contract automatically. An untrusted
message must not be switched to unchecked traversal simply because opening its
segment table succeeded. [Encoding][encoding], [reader options][message]

### Describing foreign formats

**N/A for arbitrary external layouts:** the format fixes little-endian words,
pointer encodings, section layout and list categories. A schema cannot describe
an existing packed big-endian font table with 16-bit ancestor-relative offsets.
Wrapping those bytes in `Data` leaves its parser external. [Encoding][encoding]

The draft Flat vocabulary aims to describe such layouts while reserving native
record references for aligned host-order records. Its `WFL45` four-byte arena
ceiling deliberately differs from Cap'n Proto's eight-byte object alignment;
four-byte-aligned APK storage is not by itself proof that a Cap'n Proto segment
can be viewed without an aligned copy or stronger packaging guarantees.
[Draft][flat-draft]

### Implementation and performance evidence

[`message.h`][message] provides exact default limits and accounting semantics;
[`layout.c++`][layout] provides checks, canonical copying and amplification
handling. The [encoding specification][encoding] provides both bit layouts and
the labeled packing vector. These are separate kinds of primary evidence.

An executed C++20 header-only probe constructed `capnp::ReaderOptions` from
the pinned tree and printed its fields (and word count times eight):

```text
traversal_words=8388608 traversal_bytes=67108864 nesting=64
```

This observes defaults, not successful enforcement on adversarial input.
No full library build, reference CLI run or benchmark was executed.
The packing example is upstream specification evidence, not a local codec
round-trip. No D binding or big-endian runtime was evaluated. Claimed constant
opening cost must not be reported as a measured speedup for a workload that
also traverses, canonicalizes, unpacks or copies its messages.

This **independent packing invariant check** checks the specified all-zero
run's count convention. It is not a Cap'n Proto decoder and does not claim to
validate framing, pointers or a complete packed stream.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "binary_capnproto_invariant"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : writeln;

void main() @safe
{
    immutable ubyte[2] packed = [0x00, 0x03];
    assert(packed[0] == 0);
    const words = 1 + uint(packed[1]);
    const unpackedBytes = words * 8;
    assert(words == 4 && unpackedBytes == 32);
    writeln("packed-bytes=", packed.length, " zero-words=", words,
        " unpacked-bytes=", unpackedBytes);
}
```

```ansi
packed-bytes=2 zero-words=4 unpacked-bytes=32
```

## Strengths

- Lazy checked access avoids mandatory whole-graph materialization.
- Explicit traversal and nesting defenses address wire-to-work amplification.
- Canonicalization is actually specified, independently of normal construction.
- Default representation and layout rules support additive evolution.

## Weaknesses

- Word alignment and lifetime constrain the byte-source boundary.
- Traversal accounting can penalize repeated getters over legitimate data.
- Packed transport bytes are not directly the ordinary in-place representation.
- Fixed format does not describe arbitrary foreign layouts or define Merkle links.

## Key design decisions and trade-offs

| Decision                  | Rationale                                | Trade-off                                       |
| ------------------------- | ---------------------------------------- | ----------------------------------------------- |
| Data/pointer sections     | Structural traversal without field names | Format-specific layout and word granularity     |
| Lazy checked getters      | Cheap opening and selective access       | Failures and traversal charges occur during use |
| Segments and far pointers | Grow without moving earlier allocations  | More pointer forms and framing checks           |
| Separate canonical form   | Stable hashing boundary                  | Normal builder output needs normalization       |

## Sources

- [Encoding specification, canonical form and packing vectors][encoding].
- [Schema language][language], [reader options][message], [layout implementation][layout].
- First-party [amplification][advisory] and [additional C++ amplification][advisory-extra] advisories.
- Proposed Sparkles [Flat specification][flat-draft] and [acceptance plan][flat-plan].

<!-- References -->

[repo]: https://github.com/capnproto/capnproto/tree/b5ee48b9f3586fc83af8c429623e2c0d2435ec59
[license]: https://github.com/capnproto/capnproto/blob/b5ee48b9f3586fc83af8c429623e2c0d2435ec59/LICENSE
[encoding]: https://github.com/capnproto/capnproto/blob/b5ee48b9f3586fc83af8c429623e2c0d2435ec59/doc/encoding.md
[language]: https://github.com/capnproto/capnproto/blob/b5ee48b9f3586fc83af8c429623e2c0d2435ec59/doc/language.md
[message]: https://github.com/capnproto/capnproto/blob/b5ee48b9f3586fc83af8c429623e2c0d2435ec59/c%2B%2B/src/capnp/message.h
[layout]: https://github.com/capnproto/capnproto/blob/b5ee48b9f3586fc83af8c429623e2c0d2435ec59/c%2B%2B/src/capnp/layout.c%2B%2B
[endian]: https://github.com/capnproto/capnproto/blob/b5ee48b9f3586fc83af8c429623e2c0d2435ec59/c%2B%2B/src/capnp/endian.h
[advisory]: https://github.com/capnproto/capnproto/blob/b5ee48b9f3586fc83af8c429623e2c0d2435ec59/security-advisories/2015-03-02-2-all-cpu-amplification.md
[advisory-extra]: https://github.com/capnproto/capnproto/blob/b5ee48b9f3586fc83af8c429623e2c0d2435ec59/security-advisories/2015-03-05-0-c++-addl-cpu-amplification.md
[flat-draft]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
[flat-plan]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/PLAN.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[serde]: ../serde/index.md
[cas]: ../content-addressing/index.md
