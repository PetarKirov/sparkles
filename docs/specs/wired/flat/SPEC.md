---
status: draft
owner: sparkles:wired
reviewed: 2026-10-16
---

# `sparkles.wired.flat` — Binary in-place format

## Abstract

`sparkles:wired` reads and writes fixed-layout binary data described by
ordinary D declarations. A struct annotated with its byte order, the counts of
its arrays and the bases of its offsets is the whole description: the compiler
proves its layout, and a reader then views untrusted bytes as that type in
place. When the declared byte order matches the machine's, the view is the
bytes themselves after one length and alignment check; otherwise each field is
byte-swapped as it is read. Every read is bounded, reports failures as values
that name the byte offset and field path, and runs in safe, pure,
non-allocating code. The same vocabulary describes foreign formats such as
OpenType tables and the library's own versioned cache files, which a builder
lays out.

## Introduction

Some data is read far more often than it is written, and is large enough that
parsing it into objects costs more than the work it feeds. A font's tables are
read by every shaping and rasterizing call; a terminal's face catalog and
glyph-atlas cache are read at every launch, on a phone, before the first frame.
For such data the efficient representation on disk is the representation in
memory: fixed-width integers at known offsets, arrays whose length is stored
next to them, and offsets from one record to another. A reader that maps the
file and reads fields where they lie does no parsing at all. The bytes,
however, may come from anywhere: a font downloaded from the web, a cache file
truncated by a crash, an asset in a tampered package.

Reading such bytes safely by hand is repetitive and error-prone. Every field
access repeats a bounds check, an offset computation and a byte-order
conversion, and an omission in any of them reads past the buffer. The OpenType
parser in `sparkles:font` follows this discipline in
[`sparkles.font.bytes`](../../font/parsing.md#_1-common-rules): check that a
range fits, then read big-endian integers from it. It is correct, but each
table restates its layout as a list of offsets that nothing checks against the
specification. Serialization libraries do not close the gap.
[cerealed](https://github.com/atilaneves/cerealed/blob/3340ea8b1881588c30f7f363f3dec0d5d13ec372/src/cerealed/attrs.d)
derives a binary layout from D declarations and its attributes are a good
vocabulary, but it copies values out of a stream, allocates from the garbage
collector, writes only big-endian data and reports malformed input by throwing.
[FlatBuffers](https://flatbuffers.dev/internals/) and
[Cap'n Proto](https://capnproto.org/encoding.html) read data in place, but each
defines its own little-endian encoding and schema language, so neither can
describe a format someone else designed.

This library makes the D declaration the description and proves it at compile
time. A _record_ is a struct whose fields have fixed widths and whose layout
has no implicit padding; the proof computes every field's offset, size,
alignment and byte order, and rejects anything else with an error naming the
field. Variable-length parts are declared as zero-length trailing members whose
counts, byte lengths or element types come from earlier fields. A view over
caller-owned bytes checks only what the next read needs, so opening is cheap
and every read is bounded. Where the declared byte order matches the host and
the record has no fields with restricted values, the view exposes the bytes
directly as the record, through one reinterpretation guarded by the proof and a
runtime length and alignment check. Otherwise the same view decodes each field
on access. A builder writes the library's own formats: it lays records out in
an arena, fixes up offsets and stamps a header that identifies the layout.

The library does not obtain bytes. Mapping a file, reading an Android asset or
filling a buffer belongs to the caller; this specification states only what it
requires of the bytes it is given. It does not evolve schemas: a file whose
layout identity differs from the reader's is rejected and rebuilt, not
migrated. It does not compress, encrypt or authenticate data, write OpenType
fonts, or replace the reader in `sparkles:font`; describing OpenType tables is
an acceptance criterion here, and moving the font parser onto this library is
separate work with its own specification.

Section 1 states the contract at a glance and §2 the vocabulary and modules.
Sections 3–5 define the layout proof, reading, and variable-length members;
§6 applies them to OpenType tables. Sections 7 and 8 define the library's own
file convention and its builder, §9 the error contract, and §10 the proposed
surface with a requirement index. Delivery order and acceptance gates live in
[PLAN.md](./PLAN.md), and unresolved questions in
[open-issues.md](./open-issues.md). Where this page is silent, the
[base specification](../SPEC.md) and the
[expressiveness specification](../expressiveness/SPEC.md) stand.

## 1. Contract at a glance

1. A D declaration plus `Flat` attributes is the complete description of a
   binary layout. There is no schema file, registration or code generator.
2. A type that is not a provable record fails to compile, and the message names
   the type, the field path and the violated fact.
3. Byte order is declared, never assumed. A multi-byte field with no declared
   byte order is a compile-time error.
4. No byte outside the caller's slice is ever read. Every offset, count and
   length taken from the data is range-checked in 64-bit or overflow-checked
   arithmetic before use.
5. Malformed data produces a structured error value, never an assertion,
   exception, range error or undefined behaviour.
6. The only `@trusted` code is one reinterpretation of bytes as a record or an
   array of records. It runs only for types the proof admits for in-place use,
   after a length and alignment check in the same function.
7. Reading allocates nothing and is `@safe pure nothrow @nogc` whenever the
   description's own check and count functions are.
8. The caller owns the bytes. Views and slices borrow them through
   `return scope`, and the library never copies, retains or frees them.
9. The library's own files carry a header with a magic number, a version, a
   layout digest and a content key; a mismatch is a rejection, not a migration.
10. A builder's output is a pure function of its inputs, so a build that
    produces a file twice produces the same bytes.

Normative keywords are bold and lowercase, with the meanings of
[BCP 14](https://www.rfc-editor.org/info/bcp14). Code blocks are illustrative
declarations of proposed operations, not shipped API.

## 2. Model, vocabulary and modules

### 2.1 Terms

A **record** is a D `struct` admitted by the [layout proof](../../../glossary.md#layout-proof)
of §3. Its **fixed part** is the bytes from its start to `T.sizeof`. A
**leaf** is a field whose type is a scalar admitted by `WFL1`; a field whose
type is another record is a **nested record** and lies inline.

A **dynamic member** is a field of type `E[0]`. D gives such a field size zero
and places it at the end of the preceding fields, like a C flexible array
member. Its attributes say how many elements or bytes follow and what they are
(§5). The **extent** of a record in a buffer is its fixed part, its present
conditional fields and its dynamic members, in declaration order.

A **view** is a value that pairs a borrowed byte slice with a record type and
the position of one record in it. An [in-place view](../../../glossary.md#in-place-view)
additionally exposes the record as `ref const(T)` into the slice. A **swapped
read** decodes one leaf whose declared byte order differs from the host's, or
that lies at an address the host cannot load from directly.

An **arena format** is a file format defined with this library and written by
its builder (§7, §8), as opposed to a **foreign format** such as OpenType,
which this library only describes.

### 2.2 Format marker and relation to the shared schema

`Flat` is a format marker in the sense of base §3: `struct Flat {}` in
`sparkles.wired.flat`. Policy attributes from the base specification that
affect names (`@WireName`, `@WireCase`) have no effect on Flat bytes, because
Flat fields are positional.

**WFL1: Admissible leaves.** A leaf **must** be one of `ubyte`, `byte`,
`char`, `ushort`, `short`, `wchar`, `uint`, `int`, `dchar`, `ulong`, `long`,
`float`, `double`, the 24-bit integers `FlatU24` and `FlatI24`, a static array
`E[N]` with `N > 0` of an admissible leaf or record, `bool`, or an `enum` whose
base type is an admissible integer leaf. Every other field type **must** fail
the layout proof.

_Rationale:_ These are the types whose width is the same on every target D
supports. `real`, pointers, slices, classes, interfaces, delegates, associative
arrays and D `union`s either vary by target or hold addresses, which data from
outside the process cannot supply.

**WFL2: One schema.** The layout proof **must** be computed by walking
`wireSchemaOf!(Flat, T)` and the declarations it names. Flat-specific facts
such as offsets, byte order and count rules **must** be carried as format
annotations of that schema. A Flat-private reflection of `T` that bypasses it
**must not** exist; a capability the shared schema lacks is added there first.

_Rationale:_ The [SDL backend](../sdl/SPEC.md#_1-1-shared-schema-prerequisite)
set the same rule. One schema keeps digests, diagnostics and later emitters
consistent across formats.

### 2.3 Modules (proposed)

| Module                         | Contents                                                                      |
| ------------------------------ | ----------------------------------------------------------------------------- |
| `sparkles.wired.flat`          | Public re-exports and the `Flat` marker                                       |
| `sparkles.wired.flat.attrs`    | The attributes of §§3–5 and the leaf types `FlatU24`, `FlatI24`               |
| `sparkles.wired.flat.layout`   | The layout proof, `flatLayoutOf`, `isFlatRecord`, `isFlatInPlace`, the digest |
| `sparkles.wired.flat.view`     | `FlatView`, `FlatArray`, `FlatSeq`, offsets, tagged unions, `flatDecode`      |
| `sparkles.wired.flat.validate` | Eager validation under `FlatLimits`                                           |
| `sparkles.wired.flat.arena`    | The arena header, spans, string tables and `openFlatArena`                    |
| `sparkles.wired.flat.builder`  | `FlatBuilder`, slots and offset fix-ups                                       |
| `sparkles.wired.flat.error`    | `FlatError`, `FlatErrorKind`, `FlatLimit`, path rendering                     |

The package depends on `sparkles:base`, `sparkles:metadata` and `expected`,
as the rest of `sparkles:wired` does. It does not depend on `sparkles:font`.

## 3. The layout proof

The layout proof decides at compile time whether a type is a record and
computes its layout as a value. A failure is a `static assert` whose message
names the root type, the path from the root to the offending field, and the
fact that failed, such as `Head.created: offset 24, expected 20 (implicit
padding of 4 bytes after modified)`.

**WFL3: No implicit padding.** For a record `T`, the first field's `offsetof`
**must** be zero, each further field's `offsetof` **must** equal the previous
field's `offsetof` plus its `sizeof`, and `T.sizeof` **must** equal the last
field's `offsetof` plus its `sizeof`. A field whose bytes are deliberately
unused **must** be declared as a leaf carrying `@FlatPad`.

_Rationale:_ Padding bytes have unspecified content in D, so a type with
implicit padding has no single byte representation, and a builder could leak
memory contents into a file. Requiring explicit pads makes every byte of the
fixed part either a named field or a declared pad. D's `align(1)` attribute is
how a description states that a format packs fields without natural alignment,
as OpenType's `head` does with its 64-bit timestamps at offset 20.

**WFL4: Rejected shapes.** The proof **must** reject: a type that is not a
`struct`; a struct with no fields; a nested struct that carries a context
pointer; a field of a type not admitted by `WFL1`; a dynamic member followed by
a field that is not a dynamic member; and a struct with a postblit, copy
constructor, destructor or `opAssign`. Each rejection **must** name the field
or member responsible.

_Rationale:_ A non-`static` nested struct carries a hidden pointer that the
proof cannot see in the schema, and lifecycle hooks would run on values that
the library constructs by reinterpretation, where they never run.

**WFL5: Declared byte order.** Every leaf wider than one byte, and every
element of such a leaf array, **must** have a byte order resolved at compile
time from `@FlatEndian(std.system.Endian)`. The resolution order is: the
leaf field's own attribute; else the attribute on the record type that declares
the field; else, moving outward through the path from the root, the attribute
on the field holding that record, then on that field's declaring type. A leaf
with no resolved byte order **must** fail the proof. A `@FlatEndian` on a field
of record type that contradicts the byte order the record type declares for
itself **must** fail the proof rather than override it.

_Rationale:_ A layout whose byte order follows the build host is a different
file format on each host. Contradictions are errors because a reusable record
that declares its byte order states a fact about its format, which a holder
cannot change by annotation.

**WFL6: Layout as data.** `flatLayoutOf!T` **must** be a CTFE value listing,
for every field in declaration order, its path, offset, size, alignment, leaf
kind, resolved byte order and attributes, and for every dynamic member its
rule from §5. It **must** be usable in `enum` and `static immutable`
declarations, with no run-time construction.

**WFL7: Admission for in-place use.** `isFlatInPlace!(T, hostEndian)` **must**
be true exactly when `T` is a record, it has no dynamic members, no
conditional fields and no `bool` or `enum` leaves at any depth, and every
multi-byte leaf's resolved byte order equals `hostEndian`. `hostEndian`
**must** default to `std.system.endian`.

_Rationale:_ `bool` and `enum` leaves are excluded because not every byte
pattern is a valid value. The D specification makes a
[`bool`](https://dlang.org/spec/type.html#bool) with a byte other than 0 or 1
undefined behaviour, and an out-of-range enum reaching a `final switch` raises
an error from data. Rust's zerocopy draws the same line between types "for
which any bit pattern is valid" and those "for which some bit patterns are
valid" ([zerocopy 0.8.63](https://docs.rs/zerocopy/0.8.63/zerocopy/)). The
explicit `hostEndian` parameter lets tests exercise both outcomes on one host.

**WFL8: Target independence.** For every record, `flatLayoutOf!T` **must** be
identical on every supported target. A description that uses a type alias
whose width varies by target, such as `size_t`, `ptrdiff_t` or `c_long`,
violates this requirement even when the proof accepts it on each target
separately.

_Rationale:_ D aliases `size_t` to `uint` or `ulong`, so the proof cannot see
the alias. The requirement is checked by comparing layout digests across a
32-bit and a 64-bit build (see `PLAN.md`).

## 4. Reading

### 4.1 The input contract

**WFL9: Borrowed input.** Every read operation **must** take its input as
`const(ubyte)[]` and return views, slices and references that borrow from it
through `return scope`, so that `-preview=dip1000` ties their lifetime to the
input. No operation **may** copy the input, keep a reference to it beyond the
returned values, free it, or perform I/O.

**WFL10: Stable bytes.** A caller **must not** modify the input while any view
or slice of it is live. If it does, every read remains memory-safe and bounded,
but the values read and the outcome of earlier validation are unspecified.

_Rationale:_ Memory safety cannot depend on a promise the library cannot check,
so it rests on per-read bounds checks against a slice length that cannot
change. Only the meaning of the values depends on the caller's promise. Where
the bytes come from, and how they stay unchanged, is the byte source's
contract; see [open-issues O1](./open-issues.md#o1-the-byte-source).

### 4.2 Bounded reads

**WFL11: Bounds before every read.** Before reading a leaf, slicing an array,
or following an offset, a view **must** establish that the whole range lies in
the input, with the arithmetic done in 64-bit integers or overflow-checked. A
range that does not fit **must** produce `truncated` when it starts inside the
input and `badOffset` when its start is outside it or its computation
overflows.

**WFL12: No assertion on data.** No value in the input **may** cause an
assertion failure, a `RangeError`, an exception, a call to a contract-violation
handler or undefined behaviour. Contracts (`in`, `out`, `assert`) in the read
path **may** restate only what a preceding check established.

**WFL13: Caller arguments are data.** An element index, variant choice or
other argument supplied by the caller that is out of range for the data
**must** produce `indexOutOfRange`, not a precondition failure. This mirrors
[`FTP15`](../../font/parsing.md#_1-common-rules).

**WFL14: Bounded work.** Creating a view of a record **must** cost time
linear in the size of its fixed part plus its constant and cross-field checks.
Reading a leaf, an element of a uniform array or an offset target **must** cost
constant time beyond the checks of the record reached. No read **may** recurse
or loop over data except as §5.6 and §4.5 state, under the limits there.

### 4.3 In-place and swapped access

**WFL15: Opening a view.** `flatView!T(bytes, at = 0)` **must** check that the
fixed part fits at `at`, then check every `@FlatConst` field (§5.1) and every
type-level `@WireCheck` (§5.1) of `T`, and return a view or the first failure.
It **must not** inspect dynamic members, offsets or conditional fields beyond
what those checks read.

**WFL16: The in-place reinterpretation.** When `isFlatInPlace!T` holds, a view
**must** offer `native`, returning `ref const(T)` into the input, and
`flatNativeArray!E(bytes, at, count)` **must** return `const(E)[]`. Both
**must** go through a single `@trusted` function that checks, in its own body,
that the range fits and that the start address is a multiple of `T.alignof`,
and returns `misaligned` or `truncated` otherwise. Code outside that function
**must not** cast between `ubyte` storage and record types.

_Rationale:_ Keeping the checks inside the one trusted function gives it a safe
interface: no caller can reach the cast without them. The compile-time proof
supplies the rest of the argument: every byte pattern is a valid `T`, and `T`
has no indirections, padding or lifecycle hooks.

**WFL17: Accessors.** A view **must** offer one accessor per field, named as
the field, returning the field's value decoded with its resolved byte order, or
a view of a nested record. A leaf accessor on an in-place view **must** compile
to a plain load of the field; on any other view it **must** assemble the value
from bytes, so that it never performs a misaligned load.

**WFL18: Floating-point bit patterns.** A swapped read of `float` or `double`
**must** swap the bytes as an integer of the same width and reinterpret the
bits, so that every bit pattern, including signalling NaN payloads, reads back
unchanged.

**WFL19: Restricted leaves.** Reading a `bool` leaf whose byte is neither 0 nor
1, or an `enum` leaf whose value is not a member, **must** produce
`invalidValue` with the raw value. Such a leaf **must** never be produced from
the input without that check.

**WFL20: Decoding a copy.** `flatDecode!T(bytes, at = 0)` **must** return a
`T` holding every field of the fixed part decoded with its byte order and every
restricted leaf checked, or the first failure. It **must** apply the checks of
`WFL15`. Dynamic members of the returned value are empty, as in any `T`.

### 4.4 Results and attributes

**WFL21: Results are values.** Every fallible read **must** return
`FlatResult!X`, an alias of `Expected!(X, FlatError, NoGcHook)`, and **must
not** throw. The library **must not** offer throwing wrappers.

**WFL22: Attributes.** Every read operation, view accessor, `flatDecode` and
eager validation **must** be `@safe pure nothrow @nogc` when instantiated for a
description whose check, count and selection functions are. Read operations
are templates, so they infer their attributes (as AGENTS.md requires); a
unittest per milestone **must** assert the inferred attributes for every
acceptance description.

### 4.5 Eager validation

**WFL23: Validation is optional and complete.** `validateFlat!T(bytes, limits)`
**must** visit every field, dynamic member, conditional field, non-null offset
target and union variant reachable from the root, and report the first failure,
or every failure into a caller-supplied sink as in
[expressiveness §7.1](../expressiveness/SPEC.md#_7-1-accumulation). After a
successful validation of unchanged bytes, no accessor of a view of the same
root **may** return an error, except `indexOutOfRange` for a caller's argument.

**WFL24: Validation limits.** Validation **must** stop with `limitExceeded`,
naming the limit, when the offset depth exceeds `FlatLimits.maxDepth` or when
the total size of the extents it has visited exceeds
`FlatLimits.traversalBytes`. The defaults **must** be documented constants; the
traversal default **must** be a fixed multiple of the input length.

_Rationale:_ Offsets let many records share one target, so a small input can
describe an exponentially large tree. Cap'n Proto requires the same defence:
a reader increments a counter by the size of each object it dereferences and
fails past a limit, and it bounds pointer depth
([encoding, security considerations](https://capnproto.org/encoding.html)).

## 5. Variable-length members

### 5.1 Constants, pads, bit ranges and checks

**WFL25: Constant fields.** A leaf carrying `@FlatConst(v)` **must** be
compared with `v` when a view of its record is opened, and a different value
**must** produce `constantMismatch` carrying both values. The builder **must**
write `v` there whatever the source value holds.

**WFL26: Pads.** A `@FlatPad` leaf **must** be written as zero bytes by the
builder and **must** be ignored by readers, unless it is declared
`@FlatPad(FlatPadRead.mustBeZero)`, in which case a non-zero byte **must**
produce `invalidValue`. A pad has no accessor.

**WFL27: Bit ranges.** `@FlatBits!(name, shift, width)` on an unsigned integer
leaf **must** define a derived value `name` equal to `(field >> shift) & ((1 <<
width) - 1)`, usable wherever a count, selector or condition names a value. The
proof **must** reject a range that exceeds the field's width and two ranges on
one field with the same name.

**WFL28: Cross-field checks.** A record **may** carry type-level `@WireCheck`
attributes as the [expressiveness specification](../expressiveness/SPEC.md#_6-4-validation-wirecheck)
defines them. On Flat, a check receives the decoded fixed part, runs when a
view opens, and a failure **must** produce `checkFailed` carrying the check's
message.

### 5.2 Counted arrays

A dynamic member declares its length with exactly one of three attributes:

| Attribute           | Meaning                                                      |
| ------------------- | ------------------------------------------------------------ |
| `@FlatCount!(rule)` | The member holds `rule` elements                             |
| `@FlatBytes!(rule)` | The member occupies `rule` bytes, a whole number of elements |
| `@FlatRest`         | The member occupies every remaining byte of the region       |

A **rule** is either the name of a value in scope or a function followed by the
names of its arguments, for example `@FlatCount!(rowCount, "a", "b")`. The
values in scope at a member are the record's leaves declared before it, their
bit ranges, and the record's parameters (§5.5).

**WFL29: Rules are checked at compile time.** The proof **must** reject a rule
naming a value not in scope at that member, a value that is not an unsigned
integer, a function that is not callable with the named values, a function
whose result is not `FlatResult!ulong` or an unsigned integer, and a member
carrying no length attribute or more than one.

**WFL30: Rule arithmetic is checked.** A rule's value **must** be computed in
`ulong`. A function rule **must** report overflow as `countOverflow` through
its result; the library's own multiplication of a count by an element size, and
addition of a length to a position, **must** be overflow-checked and produce
`countOverflow` on overflow.

**WFL31: Sequential placement.** The first dynamic member **must** start at the
end of the fixed part and its present conditional fields, and each further
dynamic member at the end of the previous one. A `@FlatBytes` length that is
not a whole number of elements **must** produce `invalidLength`.

**WFL32: Rest.** A `@FlatRest` member **must** be the last member of its record
and **must** extend to the end of the region (§5.3). A rest length that is not
a whole number of elements **must** produce `invalidLength`.

**WFL33: Uniform and sequential arrays.** An array whose element is a record
with no dynamic members, or whose elements' sizes depend only on parameters
the array supplies, is **uniform**: its stride is computed once, element `i`
**must** be reachable in constant time, and the array **must** expose `length`
and indexing. An array whose element sizes depend on each element's own bytes
is **sequential**: it **must** expose a forward range whose `popFront` costs
the extent of one element, and indexing **must** cost at most linear time in
the index.

### 5.3 Offsets

`Offset!(W, Target, base = FlatBase.record, nullable = true)` is a leaf whose
value is an unsigned integer of width `W` (`ubyte`, `ushort`, `FlatU24`,
`uint`). It names where a `Target` record starts. `Offset16!T`, `Offset24!T`
and `Offset32!T` are aliases with the OpenType defaults.

**WFL34: Offset bases.** An offset's target position **must** be its base plus
its value, computed in checked 64-bit arithmetic. The base **must** be one of:
the start of the record that declares the offset (`FlatBase.record`); the
start of the nearest enclosing record of a named type on the path from the
root (`FlatBase.ancestor!R`), checked at compile time to exist on every path
that reaches the offset; or the start of the root's region (`FlatBase.region`).
The **region** of a view is the input slice given when opening the root.

**WFL35: Null offsets.** When `nullable` is true, the value 0 **must** mean
the target is absent, and the accessor **must** return an absent result rather
than a view at the base. When `nullable` is false, 0 is an ordinary offset.

**WFL36: Following offsets.** Following an offset **must** open a view of the
target with the checks of `WFL15`, anywhere in the region. A target outside the
region **must** produce `badOffset` carrying the offset's own position and its
value.

_Rationale:_ OpenType subtables are shared and may lie outside the extent of
the record that points at them, so containment is checked against the region.
A consumer that wants a table confined to its own bytes opens the root on that
table's slice.

### 5.4 Conditional fields and unions

**WFL37: Conditional fields.** A leaf or nested record carrying
`@FlatSince!(name, v)` is present only when the value `name` is at least `v`,
and one carrying `@FlatPresentIf!(pred, names…)` only when `pred` applied to the
named values is true. Conditional fields **must** follow every unconditional
field of the fixed part, and once one is absent every later one **must** be
absent. Their accessors **must** return an absent result when the condition is
false, and the record's extent **must** exclude them.

_Rationale:_ This is how OpenType grows tables by version: OS/2 version 1 adds
fields at the end of version 0. Requiring absence to be monotone keeps every
present field at its proven offset.

**WFL38: Tagged unions.** `FlatTagged!(Tag, tagOffset, endian, v1, R1, v2, R2,
…)` **must** be usable as the target of an offset and as an element type. It
reads a `Tag` at `tagOffset` from the union's start, selects the record whose
value matches, and opens it there. A tag with no matching record **must**
produce `unknownVariant` carrying the tag. Each `Ri` **must** declare its tag
field as `@FlatConst(vi)` at `tagOffset`, checked at compile time, so the tag
is checked once more by the variant's own view.

**WFL39: Selected element types.** `FlatSelect!(name, v1, R1, v2, R2, …)`
**must** be usable as the element type of a dynamic member. It selects the
element record by the value `name` in scope, and a value with no match **must**
produce `unknownVariant`.

### 5.5 Parameters

**WFL40: Record parameters.** A record type **may** declare named parameters
with `@FlatParam!(T, name)`. A member whose element type has parameters
**must** supply each with `@FlatArgs!(names…)` naming values in scope at the
member, and the proof **must** reject a missing, extra or mistyped argument.
Inside the record, parameters are in scope like leaves.

_Rationale:_ A delta-set row of an OpenType `ItemVariationData` has a layout
determined by fields of the table that holds it, not by bytes of its own.
Parameters make that dependency explicit and keep the array uniform (`WFL33`).

### 5.6 Layout digest

**WFL41: Layout digest.** `flatLayoutDigest!T` **must** be a 64-bit value
computed at compile time from every layout-visible fact of `T` and the records
it reaches: field order, leaf kinds, sizes, offsets, byte orders, constants,
pad policies, bit ranges, count rules (by shape and named values),
conditions, offset widths and bases, and union tags. It **must not** depend on
field names, type names, documentation or the target. Equal layouts
**must** have equal digests on every target, which `PLAN.md` checks across a
32-bit and a 64-bit build (`WFL8`).

_Rationale:_ The digest guards against reading a file with a different layout,
which is an accident, not an attack; content identity and integrity are the
content key's job (§7). Field names are excluded so that renaming a field keeps
existing files readable. The digest uses the hashing of `wireSchemaDigest` over
the Flat annotations of `WFL2`.

## 6. Describing OpenType

OpenType is the reference foreign format: big-endian, packed, with `Offset16`
and `Offset32` relative to a table or subtable start, arrays counted by sibling
fields, tables extended by version, and subtables tagged by format. The
following descriptions are illustrative; their shape, not their spelling, is
normative.

**WFL42: OpenType acceptance set.** The vocabulary **must** describe, with no
hand-written read code, the
[`head`](https://learn.microsoft.com/en-us/typography/opentype/spec/head) and
[`hhea`](https://learn.microsoft.com/en-us/typography/opentype/spec/hhea)
tables, the [Coverage table](https://learn.microsoft.com/en-us/typography/opentype/spec/chapter2#coverage-table)
in formats 1 and 2, and the
[`ItemVariationStore` header and `ItemVariationData`](https://learn.microsoft.com/en-us/typography/opentype/spec/otvarcommonformats#item-variation-store-header-and-item-variation-data-subtables)
subtable with delta widths selected by its `LONG_WORDS` flag. For each, reading
real fonts through the description **must** agree with the oracle named in
`PLAN.md`, and the proof **must** compute fixed parts of 54 bytes for `head`,
36 for `hhea`, 4 for each Coverage format, 8 for `ItemVariationStore` and 6 for
`ItemVariationData`.

`head` and `hhea` are fixed records. `align(1)` places `head.created` at
offset 20 without padding, and `@FlatConst` checks the magic number:

```d
@FlatEndian(Endian.bigEndian)
struct Head
{
align(1):
    @FlatConst(1) ushort majorVersion;
    ushort minorVersion;
    int fontRevision;              // Fixed 16.16
    uint checksumAdjustment;
    @FlatConst(0x5F0F3CF5) uint magicNumber;
    ushort flags;
    ushort unitsPerEm;
    long created;                  // LONGDATETIME
    long modified;
    short xMin, yMin, xMax, yMax;
    ushort macStyle;
    ushort lowestRecPPEM;
    short fontDirectionHint;
    short indexToLocFormat;
    short glyphDataFormat;
}

@FlatEndian(Endian.bigEndian)
struct Hhea
{
align(1):
    @FlatConst(1) ushort majorVersion;
    ushort minorVersion;
    short ascender, descender, lineGap;
    ushort advanceWidthMax;
    short minLeftSideBearing, minRightSideBearing, xMaxExtent;
    short caretSlopeRise, caretSlopeRun, caretOffset;
    @FlatPad short[4] reserved;
    @FlatConst(0) short metricDataFormat;
    ushort numberOfHMetrics;
}
```

Coverage is a tagged union over two records, each with one counted array:

```d
@FlatEndian(Endian.bigEndian)
struct CoverageFormat1
{
align(1):
    @FlatConst(1) ushort coverageFormat;
    ushort glyphCount;
    @FlatCount!"glyphCount" ushort[0] glyphArray;
}

@FlatEndian(Endian.bigEndian)
struct RangeRecord
{
align(1):
    ushort startGlyphID, endGlyphID, startCoverageIndex;
}

@FlatEndian(Endian.bigEndian)
struct CoverageFormat2
{
align(1):
    @FlatConst(2) ushort coverageFormat;
    ushort rangeCount;
    @FlatCount!"rangeCount" RangeRecord[0] rangeRecords;
}

alias Coverage = FlatTagged!(ushort, 0, Endian.bigEndian,
    1, CoverageFormat1, 2, CoverageFormat2);
```

`ItemVariationData` packs two values into `wordDeltaCount`: the high bit is
`LONG_WORDS` and the low 15 bits count the wide deltas. Each of `itemCount`
rows holds `wordCount` wide deltas then `regionIndexCount - wordCount` narrow
ones; wide and narrow mean 32 and 16 bits when `LONG_WORDS` is set, 16 and 8
when it is not. HarfBuzz computes the same row size and rejects a `wordCount`
greater than `regionIndexCount`
([`hb-ot-layout-common.hh`](https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-ot-layout-common.hh#L2960-L2966),
[sanitize](https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-ot-layout-common.hh#L3038-L3047)).
The description states both with parameters and a selected element type:

```d
@FlatEndian(Endian.bigEndian)
@FlatParam!(ushort, "wordCount") @FlatParam!(ushort, "regionCount")
struct DeltaSet(Wide, Narrow)
{
align(1):
    @FlatCount!"wordCount" Wide[0] wide;
    @FlatCount!(narrowCount, "regionCount", "wordCount") Narrow[0] narrow;
}

FlatResult!ulong narrowCount(ulong regions, ulong words)
    => regions >= words ? ok(regions - words) : flatError(FlatErrorKind.countOverflow);

@FlatEndian(Endian.bigEndian)
@WireCheck!(d => (d.wordDeltaCount & 0x7FFF) <= d.regionIndexCount,
    "wordCount exceeds regionIndexCount")
struct ItemVariationData
{
align(1):
    ushort itemCount;
    @FlatBits!("longWords", 15, 1) @FlatBits!("wordCount", 0, 15)
    ushort wordDeltaCount;
    ushort regionIndexCount;
    @FlatCount!"regionIndexCount" ushort[0] regionIndexes;
    @FlatCount!"itemCount" @FlatArgs!("wordCount", "regionIndexCount")
    FlatSelect!("longWords", 0, DeltaSet!(short, byte),
                             1, DeltaSet!(int, short))[0] deltaSets;
}

@FlatEndian(Endian.bigEndian)
struct ItemVariationStore
{
align(1):
    @FlatConst(1) ushort format;
    Offset32!VariationRegionList variationRegionListOffset;
    ushort itemVariationDataCount;
    @FlatCount!"itemVariationDataCount"
    Offset32!ItemVariationData[0] itemVariationDataOffsets; // from the store
}

// VariationRegionList is described the same way and omitted here.
```

Because `DeltaSet`'s size depends only on its parameters, `deltaSets` is a
uniform array (`WFL33`): row `i` is reached in constant time, as HarfBuzz and
[fontations](https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/read-fonts/src/tables/variations.rs#L1719-L1738)
compute it. Fontations itself types the rows as raw bytes of a computed length
([`variations.rs`](https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/resources/codegen_inputs/variations.rs#L144-L160))
and decodes deltas by hand; this description keeps them typed.

## 7. Arena formats

An arena format is a file that this library writes and later reads in place:
the font catalog and glyph-atlas cache of the
[startup slice](../../font/PLAN.md#ms-startup-slice) are the first. Its bytes
are little-endian, because every target Sparkles builds for is, so readers on
those targets take the in-place path.

**WFL43: The arena header.** An arena file **must** begin with this record,
little-endian, at offset 0:

| Offset | Field          | Type        | Meaning                                                         |
| ------ | -------------- | ----------- | --------------------------------------------------------------- |
| 0      | `magic`        | `ubyte[8]`  | Format identity, chosen by the format and fixed forever         |
| 8      | `version`      | `uint`      | Format version, incremented by the format's owner               |
| 12     | `headerSize`   | `uint`      | 64, the size of this header                                     |
| 16     | `layoutDigest` | `uint[2]`   | `flatLayoutDigest` of the root record (`WFL41`), low half first |
| 24     | `byteLength`   | `uint[2]`   | Total file length, header included, low half first              |
| 32     | `contentKey`   | `ubyte[32]` | The content hash of the inputs the file was built from          |

`layoutDigest` and `byteLength` are 64-bit values stored as two `uint` halves,
so that the header needs only 4-byte alignment (`WFL45`). The root record
**must** start at offset 64.

**WFL44: Opening an arena.** `openFlatArena!(Root, magic, version)(bytes)`
**must** check, in this order, and stop at the first failure: the header fits
(`truncated`); `magic` (`notThisFormat`); `version` (`unsupportedVersion`,
carrying both values); `headerSize` (`invalidValue`); `layoutDigest` against
`flatLayoutDigest!Root` (`layoutMismatch`, carrying both); `byteLength`
equals the input length (`invalidLength`). It **must** then validate the root
eagerly (`WFL23`) and return a view of it, or the failure.

_Rationale:_ The order puts the cheapest rejection of an unrelated file first
and keeps "wrong version" distinct from "same version, different layout", which
means the format's owner forgot to bump the version. Arena files are caches
keyed by content and rebuilt on mismatch, so no migration path is specified.

**WFL45: Alignment ceiling.** Every record in an arena format **must** have an
alignment of at most 4, enforced by the layout proof for every record reachable
from a root declared with `@FlatArena`. A record that needs a 64-bit integer
**must** store it as two `uint` fields or a `ubyte[8]`.

_Rationale:_ Android stores uncompressed APK assets aligned to 4 bytes by
[zipalign](https://developer.android.com/tools/zipalign), so 4 is the strongest
alignment an asset read in place can rely on. Within the file, the builder
aligns each record to its own alignment, so a file mapped at a 4-byte boundary
is aligned throughout.

**WFL46: Spans and strings.** `FlatSpan!E` **must** be a record of two
little-endian `uint` fields, `offset` from the region start and `count`, naming
a uniform array of `E`. `FlatString` **must** be `FlatSpan!char`, whose
accessor returns `const(char)[]` borrowed from the input. Eager validation of
an arena **must** check that every `FlatString` is valid UTF-8 and produce
`invalidUtf8` with its position otherwise.

## 8. The builder

**WFL47: Builder storage.** `FlatBuilder!Storage` **must** write into a
caller-supplied output: a growable `sparkles.base.buffer` buffer or a fixed
`ubyte[]`. Exhausting fixed storage **must** produce `limitExceeded` with the
limit `builderStorage` and the size needed. Builder operations are templates
and infer `@safe pure nothrow @nogc` from their storage.

**WFL48: Allocation and fix-up.** The builder **must** offer: reserving a
record or an array of `n` records, aligned to the element's alignment, which
returns a typed slot holding its position; writing a value into a slot,
encoding each leaf with its declared byte order; appending a string or bytes;
and assigning an offset or span field in one slot to point at another. An
offset value that does not fit its width **must** produce `offsetOverflow`.
A slot from one builder used with another, or a slot whose space was not
written before `finish`, **must** produce `invalidSlot`.

**WFL49: Deterministic output.** The builder's output **must** be a pure
function of the sequence of builder calls and their arguments. Alignment gaps
and pads **must** be zero bytes. `finish` **must** write the arena header of
`WFL43`, with `contentKey` supplied by the caller.

_Rationale:_ Nix builds the startup slice's files at package build time, and
both reproducibility and content-keyed caching need byte-identical output for
identical inputs.

**WFL50: Round-trip.** For every value the builder writes, reading the result
through `openFlatArena` **must** succeed and every accessor **must** return
the written value.

## 9. Errors

**WFL51: Error location.** A `FlatError` **must** carry its `kind`; the
absolute byte offset in the region where the problem was found; the offset of
the enclosing record's start; the path from the root to the field, in the
[path syntax](../SPEC.md#_9-errors) of base §9 (`$.itemVariationDataOffsets[3].regionIndexes`);
the name of the record type; and, where the problem concerns a value read from
the data, that value and the expected value or bound. A `limitExceeded` error
**must** name the limit and its value. Building a `FlatError` **must not**
allocate from the garbage collector.

Error kinds (proposed `FlatErrorKind`):

| Kind                 | Raised when                                                              |
| -------------------- | ------------------------------------------------------------------------ |
| `truncated`          | A range starts in the region but does not fit                            |
| `badOffset`          | A position is outside the region, or its computation overflows           |
| `misaligned`         | An in-place view's start is not a multiple of the type's alignment       |
| `constantMismatch`   | A `@FlatConst` field holds another value                                 |
| `invalidValue`       | A restricted leaf, strict pad or header field holds an invalid value     |
| `checkFailed`        | A `@WireCheck` rejected a record                                         |
| `unknownVariant`     | A tag or selector matches no variant                                     |
| `countOverflow`      | Count, length or position arithmetic overflows                           |
| `invalidLength`      | A byte length is not a whole number of elements, or `byteLength` differs |
| `invalidUtf8`        | A validated string is not UTF-8                                          |
| `indexOutOfRange`    | A caller's index or argument is out of range for the data                |
| `limitExceeded`      | Validation or builder storage passes a limit                             |
| `notThisFormat`      | An arena's magic differs                                                 |
| `unsupportedVersion` | An arena's version differs                                               |
| `layoutMismatch`     | An arena's layout digest differs                                         |
| `offsetOverflow`     | The builder cannot represent an offset in its width                      |
| `invalidSlot`        | A builder slot is foreign or unwritten                                   |

Exact message text is not part of the contract; the fields above are.

## 10. Proposed surface and requirement index

The surface below is proposed. Names may change before delivery; the
requirements bind behaviour, not spelling.

| Operation                                                   | Requirement      |
| ----------------------------------------------------------- | ---------------- |
| `isFlatRecord!T`, `flatLayoutOf!T`                          | `WFL3`–`WFL6`    |
| `isFlatInPlace!(T, hostEndian)`                             | `WFL7`           |
| `flatView!T(bytes, at)`, accessors, `native`                | `WFL15`–`WFL17`  |
| `flatNativeArray!E(bytes, at, count)`                       | `WFL16`          |
| `flatDecode!T(bytes, at)`                                   | `WFL20`          |
| `validateFlat!T(bytes, limits[, sink])`                     | `WFL23`, `WFL24` |
| `flatLayoutDigest!T`                                        | `WFL41`          |
| `openFlatArena!(Root, magic, version)(bytes)`               | `WFL44`          |
| `FlatBuilder!Storage`: `reserve`, `write`, `link`, `finish` | `WFL47`–`WFL50`  |

| ID               | Requirement                                              | Traces to                                        | Status  |
| ---------------- | -------------------------------------------------------- | ------------------------------------------------ | ------- |
| `WFL1`, `WFL2`   | Admissible leaves; one shared schema                     | proposed `sparkles.wired.flat.layout`            | planned |
| `WFL3`–`WFL8`    | Layout proof, byte order, in-place admission             | proposed `flatLayoutOf`, `isFlatInPlace`         | planned |
| `WFL9`, `WFL10`  | Borrowed, stable input                                   | proposed `sparkles.wired.flat.view`              | planned |
| `WFL11`–`WFL14`  | Bounded reads, no assertion on data, bounded work        | proposed `sparkles.wired.flat.view`              | planned |
| `WFL15`–`WFL20`  | Views, in-place reinterpretation, swaps, decode          | proposed `flatView`, `flatDecode`                | planned |
| `WFL21`, `WFL22` | Results and attributes                                   | proposed `FlatResult`                            | planned |
| `WFL23`, `WFL24` | Eager validation and its limits                          | proposed `validateFlat`, `FlatLimits`            | planned |
| `WFL25`–`WFL28`  | Constants, pads, bit ranges, cross-field checks          | proposed `sparkles.wired.flat.attrs`             | planned |
| `WFL29`–`WFL33`  | Counted, byte-length and rest arrays                     | proposed `FlatArray`, `FlatSeq`                  | planned |
| `WFL34`–`WFL36`  | Offsets, bases, null offsets                             | proposed `Offset`                                | planned |
| `WFL37`–`WFL40`  | Conditional fields, tagged unions, selection, parameters | proposed `FlatTagged`, `FlatSelect`, `FlatParam` | planned |
| `WFL41`          | Layout digest                                            | proposed `flatLayoutDigest`                      | planned |
| `WFL42`          | OpenType acceptance set                                  | proposed test descriptions                       | planned |
| `WFL43`–`WFL46`  | Arena header, opening, alignment, spans, strings         | proposed `openFlatArena`, `FlatSpan`             | planned |
| `WFL47`–`WFL50`  | Builder                                                  | proposed `FlatBuilder`                           | planned |
| `WFL51`          | Error location                                           | proposed `FlatError`                             | planned |

## 11. Dependencies

The library needs, from outside this specification:

- The shared schema of the [expressiveness specification](../expressiveness/SPEC.md#_2-the-reified-schema),
  which exists, extended with the Flat annotations of `WFL2`.
- `@WireCheck` from [expressiveness §6.4](../expressiveness/SPEC.md#_6-4-validation-wirecheck)
  for `WFL28`; see [O3](./open-issues.md#o3-wirecheck-is-not-delivered).
- A byte source in `sparkles:base` that maps a file or an Android asset as
  `const(ubyte)[]` with a stated lifetime, for the first arena consumer; see
  [O1](./open-issues.md#o1-the-byte-source).
- A content hash for `contentKey`, computed by the consumer; see
  [O2](./open-issues.md#o2-the-content-key).
