# FlatBuffers (multi-language)

An offset-based in-place representation that combines evolvable tables with
fixed-layout structs, backed by generated accessors and a separate verifier.

| Field           | Value                                              |
| --------------- | -------------------------------------------------- |
| Language        | C++ core/compiler and multiple generated bindings  |
| License         | Apache-2.0                                         |
| Repository      | [google/flatbuffers][repo]                         |
| Documentation   | [Internals][internals] · [schema language][schema] |
| Category        | Schema-first in-place tables and vectors           |
| Reviewed source | `b8431fbcd7a5c71817f314e18b332c0648554efa`         |

## Overview

### What it solves

FlatBuffers avoids constructing an object graph before reading a binary asset
or message. Generated accessors navigate relative offsets in the caller's
buffer; tables tolerate absent or added fields through a field-offset table.
Structs provide a cheaper fixed-layout alternative when evolution is unnecessary.
The [white paper][whitepaper] motivates this in terms of allocation, copies,
locality and mobile memory bandwidth rather than simply byte compression.

### Design philosophy

The [internals document][internals] deliberately allows multiple layouts:

> This may mean two different implementations may produce different binaries
> given the same input values, and this is perfectly valid.

Fast navigation and schema evolution do not require one canonical layout.
That distinction is central to the [shared concepts][concepts] and
[comparison][comparison]: in-place access, deterministic construction and
canonical encoding are independent properties.

## How it works

### Schema source of truth

An `.fbs` schema declares scalars, enums, structs, tables, vectors and unions.
`flatc` generates binding-specific accessors/builders. A binary schema supports
reflection separately; generated code is not a general description of arbitrary
external files. [Schema language][schema], [internals][internals]

Table fields have identities derived from declaration order or explicit `id`
attributes. Struct fields have a compiler-independent fixed layout, with scalar
alignment and padding dictated by FlatBuffers. Host compiler ABI layout is not
the authoritative source. [Internals][internals]

The [serde catalog][serde] covers host-language model derivation; FlatBuffers
instead makes its external schema and generated wire accessors the main seam.
No upstream D implementation was found in the reviewed source tree; that is
not a claim that no external D port exists.

### Wire encoding

The buffer begins with an unsigned relative offset to the root table.
Ordinary object offsets are 32-bit and normally point forward. A table begins
with a signed offset that is **subtracted** to find its vtable. Vtables can
be shared and can lie on either side of a table. [Internals][internals]

A vtable contains 16-bit entries: its own byte length, the table's inline
object size, then field offsets. A missing entry or zero field offset means
absent. The table payload can arrange present fields in different orders.
The accessor knows the field's vtable slot, not one universal table byte offset.
Structs instead inline their complete fixed layout. [Internals][internals]

Scalars are little-endian and aligned to their width. Strings/vectors are
referenced by offsets and carry element counts; strings add a zero terminator.
The [scalar helpers][base] show `EndianScalar` and `ReadScalar` rather than
making endianness disappear into an undefined native cast.

### Access model

Generated table access follows root offset, vtable entry and field payload;
scalar vectors and struct vectors permit direct indexed access. This avoids
whole-message deserialization, not every load, branch or byte swap.
The [generated sample][sample] is concrete access and verification code.

The C++ convenience root accessor accepts a pointer, not a bounded slice.
Calling it does not itself validate the buffer. Untrusted input requires the
generated verifier entry point before ordinary unchecked traversal. Bytes must
remain alive and unchanged for that proof to remain useful. [Verifier][verifier]

Alignment has two layers: offsets aligned within the format, and the actual
buffer base aligned in memory. `VerifyAlignment` checks an index relative to
the base, not the address modulo alignment. A successful relative-layout check
does not repair an arbitrarily misaligned base pointer. [Verifier][verifier], [base][base]

### Variable-length and optional data

A vector stores a count followed by contiguous elements or offsets. An offset
vector can refer to separately placed tables or strings; it can also reuse a
target. Strings have a byte count plus terminator. A table omits fields whose
defaults can be synthesized; scalar optionality can be explicitly requested
with a null default where supported. [Internals][internals], [schema][schema]

Unions normally use a discriminator field plus an object-offset field. `NONE`
represents no member. Structs have no absent fields and cannot gain fields
without changing their layout. This table/struct split buys different costs
without pretending that every declaration has the same evolution semantics.
[Internals][internals]

The C++ builder constructs backward, allowing child data to be emitted before
parents and offsets to be resolved without relocating every earlier reference.
Vtable deduplication and default omission further affect the output layout.
[`FlatBufferBuilder`][builder]

### Evolution and compatibility

Adding table fields is supported under the schema's identity rules; old
readers ignore unfamiliar slots and new readers synthesize defaults for absent
ones. Fields can be deprecated rather than reused. Reordering without stable
explicit IDs changes meaning. Changing an established default changes how old
buffers are interpreted. [Schema language][schema]

The [draft Flat proposal][flat-draft] deliberately does something else for its
own arenas: `WFL54` requires an increasing version/digest pin history, and
`WFL44` rejects mismatches for cache rebuild. That is not an inferior vtable;
it is a narrower contract for data built with its reader. Its foreign-format
conditional tails do not imply general arena migration.

### Determinism and canonical form

**N/A as a built-in canonical encoding:** table field order, object placement,
sharing and padding arrangements are not uniquely selected by the format.
The [internals document][internals] explicitly permits different byte images.
A stable implementation and fixed builder sequence can be repeatable without
defining canonical bytes across all writers and equivalent values.

The draft's `WFL49` promises a pure function of builder calls and zeroed pads.
It does **not** choose one allocation order, sharing policy or float/string
equivalence for every logically equal graph. `WFL41` canonicalizes a layout
description for a non-cryptographic digest, not arbitrary arena content.
[Draft specification][flat-draft]

### Merkleization and content addressing

**N/A as a built-in facility:** relative offsets identify locations in a
buffer, not cryptographic content. Shared vtables and targets are storage
deduplication, not Merkle links. Hashing the exact buffer is meaningful but
does not equate every alternative layout of the same values. [Internals][internals]

The draft arena's opaque 32-byte `contentKey` is supplied by its consumer;
it is not a recursive hash of every offset target. Its open operation does
not recompute an integrity digest over the whole file. The [draft issues][flat-issues]
leave hash selection and cache-input identity to the consumer. See the
[content-addressing catalog][cas] for genuinely authenticated object graphs.

### Hostile-input safety

The C++ [`VerifierTemplate`][verifier] defaults to `max_depth = 64`,
`max_tables = 1000000`, `check_alignment = true` and nested-buffer checking.
`VerifyTableStart` checks the vtable offset/extent and calls `VerifyComplexity`.
That method increments current `depth_` and cumulative `num_tables_`, rejecting
values above the configured bounds; `EndTable` decrements depth only.

These are **table-visit counters**, not a universal budget measured in input
bytes or a charge for every vector element. A scalar vector is checked as a
range; a vector of tables invokes verification on each target. Shared targets
can therefore cost multiple table visits. The options comment's broad wording
about nesting must be read with the actual increment sites. [Verifier][verifier]

`VerifyVectorOrString` bounds the count before multiplication, then checks the
whole range. `VerifyString` also checks the terminator; it does not implement
a complete UTF-8 validity scan. `VerifyOffset` rejects zero, excessive signed
range and out-of-buffer destinations before constructing a target pointer.
[Verifier][verifier]

Nested FlatBuffers create a fresh verifier with copied options, not a single
shared cumulative counter. Also, the verifier constructor asserts that the
input is below `max_size`; a caller must enforce that admission condition.
Neither detail is equivalent to the draft's proposed value-returning error
contract for all malformed input. [Verifier][verifier]

The draft `WFL24` instead charges every record, array element and string
`max(extent, 1)` bytes at every visit and bounds followed-offset depth.
That protects zero-extent logical elements and specifies charging order.
Its provisional defaults still require the real-font gate in the
[delivery plan][flat-plan]; similarity to an upstream limit is not that evidence.

### Describing foreign formats

**N/A for arbitrary layouts:** a schema cannot redefine scalars as big-endian,
change ordinary offsets to ancestor-relative 16-bit pointers or prescribe a
packed foreign table. FlatBuffers owns the format. [Internals][internals]

The draft's `WFL45` four-byte arena alignment ceiling is also not a FlatBuffers
guarantee. FlatBuffers can require eight-byte scalar alignment. A four-byte
asset-base guarantee alone is insufficient for such a buffer; packaging or
copying/alignment policy must account for its actual requirements. The draft
instead bans reachable arena records requiring more than four-byte alignment
and represents 64-bit quantities as halves or bytes. [Draft][flat-draft]

### Implementation and performance evidence

**Executed reference-library probe:** with the pinned C++ headers and generated
[`samples/monster_generated.h`][sample], compiled using `g++ -std=c++17 -O2`:

```cpp
#include <cstdio>
#include "samples/monster_generated.h"
int main() {
    flatbuffers::FlatBufferBuilder b;
    MyGame::Sample::FinishMonsterBuffer(b, MyGame::Sample::CreateMonster(b));
    for (size_t i = 0; i < b.GetSize(); ++i)
        std::printf("%s%02x", i ? " " : "", b.GetBufferPointer()[i]);
    std::puts("");
    flatbuffers::Verifier normal(b.GetBufferPointer(), b.GetSize());
    flatbuffers::Verifier::Options opts;
    std::printf("max_depth=%u max_tables=%u alignment=%d\n",
        opts.max_depth, opts.max_tables, opts.check_alignment);
    opts.max_tables = 0;
    flatbuffers::Verifier limited(b.GetBufferPointer(), b.GetSize(), opts);
    std::printf("default=%d max_tables=0=%d\n",
        MyGame::Sample::VerifyMonsterBuffer(normal),
        MyGame::Sample::VerifyMonsterBuffer(limited));
}
```

Observed output (manual reference probe, not a CI-registered Markdown example):

```text
08 00 00 00 04 00 04 00 04 00 00 00
max_depth=64 max_tables=1000000 alignment=1
default=1 max_tables=0=0
```

The root is at byte `8`; its four-byte vtable is at byte `4`. The empty
table is accepted normally but rejected under a zero-table budget. This tiny
probe establishes neither deep-limit coverage nor throughput; no benchmark
or full FlatBuffers test suite was run.

The following portable D program is an **independent offset invariant check**
over that observed vector, plus a separately constructed negative-displacement
case. It is not a complete verifier or FlatBuffers binding.
Unlike the manual C++ probe, this example is registered by its Markdown
code/output pair for `ci --verify`.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "binary_flatbuffers_invariant"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : writeln;

uint le32(const(ubyte)[] bytes, size_t at) @safe pure nothrow @nogc
{
    assert(at <= bytes.length && bytes.length - at >= 4);
    return bytes[at] | (uint(bytes[at + 1]) << 8)
        | (uint(bytes[at + 2]) << 16) | (uint(bytes[at + 3]) << 24);
}

void main() @safe
{
    immutable ubyte[12] bytes = [8, 0, 0, 0, 4, 0, 4, 0, 4, 0, 0, 0];
    const root = le32(bytes[], 0);
    const displacement = cast(int) le32(bytes[], root);
    const long target = cast(long) root - displacement;
    assert(target >= 0 && target <= bytes.length - 4);
    const vtable = cast(size_t) target;
    assert(root == 8 && vtable == 4);
    assert(bytes[vtable] == 4 && bytes[vtable + 2] == 4);
    writeln("root=", root, " vtable=", vtable, " inline-bytes=", bytes[vtable + 2]);
    // Independently constructed: the vtable follows this empty table.
    immutable ubyte[12] after = [4, 0, 0, 0, 252, 255, 255, 255, 4, 0, 4, 0];
    const otherRoot = le32(after[], 0);
    const signedDelta = cast(int) le32(after[], otherRoot);
    const long otherTarget = cast(long) otherRoot - signedDelta;
    assert(signedDelta == -4 && otherTarget == 8);
    assert(otherTarget >= 0 && otherTarget <= after.length - 4);
    writeln("negative displacement=", signedDelta, " vtable=", otherTarget);
}
```

```ansi
root=8 vtable=4 inline-bytes=4
negative displacement=-4 vtable=8
```

## Strengths

- In-place random access without constructing an object graph. [White paper][whitepaper]
- Tables support evolution; structs provide a cheaper stable-layout option.
- Concrete verifier code exposes limits, range arithmetic and recursion sites.
- Compiler-independent endian/alignment rules define cross-platform bytes.

## Weaknesses

- Unchecked C++ access needs a trustworthy validation/lifetime boundary.
- Table indirection and default synthesis are not a single native record load.
- Verifier limits are not one comprehensive per-element work budget.
- Arbitrary foreign layouts and universal canonical bytes are out of scope.

## Key design decisions and trade-offs

| Decision           | Rationale                                     | Trade-off                                                 |
| ------------------ | --------------------------------------------- | --------------------------------------------------------- |
| Vtable indirection | Optional fields and evolution without parsing | Extra dependent loads                                     |
| Separate structs   | Compact fixed-layout data                     | No field-wise evolution                                   |
| Backward builder   | Resolve children before parents               | Output follows construction choices                       |
| Separate verifier  | Cheap ordinary access after checking          | Base alignment and immutable storage remain caller duties |

## Sources

- [Internals][internals], [schema language][schema] and [white paper][whitepaper].
- [Verifier][verifier], [scalar helpers][base], [builder][builder] and [generated sample][sample].
- Pinned draft [specification][flat-draft], [plan][flat-plan] and [open issues][flat-issues];
  these describe proposed Sparkles behavior, not delivered implementation.

<!-- References -->

[repo]: https://github.com/google/flatbuffers/tree/b8431fbcd7a5c71817f314e18b332c0648554efa
[internals]: https://github.com/google/flatbuffers/blob/b8431fbcd7a5c71817f314e18b332c0648554efa/docs/source/internals.md
[schema]: https://github.com/google/flatbuffers/blob/b8431fbcd7a5c71817f314e18b332c0648554efa/docs/source/schema.md
[whitepaper]: https://github.com/google/flatbuffers/blob/b8431fbcd7a5c71817f314e18b332c0648554efa/docs/source/white_paper.md
[verifier]: https://github.com/google/flatbuffers/blob/b8431fbcd7a5c71817f314e18b332c0648554efa/include/flatbuffers/verifier.h
[base]: https://github.com/google/flatbuffers/blob/b8431fbcd7a5c71817f314e18b332c0648554efa/include/flatbuffers/base.h
[builder]: https://github.com/google/flatbuffers/blob/b8431fbcd7a5c71817f314e18b332c0648554efa/include/flatbuffers/flatbuffer_builder.h
[sample]: https://github.com/google/flatbuffers/blob/b8431fbcd7a5c71817f314e18b332c0648554efa/samples/monster_generated.h
[flat-draft]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
[flat-plan]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/PLAN.md
[flat-issues]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/open-issues.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[serde]: ../serde/index.md
[cas]: ../content-addressing/index.md
