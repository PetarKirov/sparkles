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
proves its layout, and a reader then reads untrusted bytes where they lie,
without parsing them first. A naturally aligned record whose byte order
matches the machine's is exposed as the bytes themselves after one length and
alignment check; any other field is read with a single load, byte-swapped when
its order differs. Every read is bounded, reports failures as values that name
the byte offset and field path, and runs in safe, pure, non-allocating code.
The same vocabulary describes foreign formats such as OpenType tables and the
library's own versioned cache files, which a builder lays out.

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
and every read is bounded. Where a record's every field sits at its natural
alignment, its byte order matches the host and every byte pattern is a valid
value, the view exposes the bytes directly as the record, through one
reinterpretation guarded by the proof and a runtime length and alignment check.
Any other field, such as one in a packed OpenType table, is read through an
accessor that compiles to one load, plus a byte swap when its order differs. A
builder writes the library's own formats: it lays records out in an arena,
fixes up offsets and stamps a header that identifies the layout.

The library does not obtain bytes. Mapping a file, reading an Android asset or
filling a buffer belongs to the caller; this specification states only what it
requires of the bytes it is given. It does not evolve schemas: a file whose
layout identity differs from the reader's is rejected and rebuilt, not
migrated. It does not encode values whose size lives only in a stream, such as
D slices behind a length prefix in the manner of cerealed, and it does not pack
fields at bit granularity across byte boundaries. It does not compress,
encrypt or authenticate data, write OpenType fonts, or replace the reader in
`sparkles:font`; describing OpenType tables is an acceptance criterion here,
and moving the font parser onto this library is separate work with its own
specification.

Section 1 states the contract at a glance and §2 the vocabulary and modules.
Sections 3–5 define the layout proof, reading, and variable-length members;
§6 applies them to OpenType tables. Sections 7 and 8 define the library's own
file convention and its builder, §9 the error contract, and §10 the proposed
surface with a requirement index. Delivery order, acceptance gates and the
record of reviews live in [PLAN.md](./PLAN.md), and unresolved questions in
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
   array of records. It runs only for naturally aligned, host-order records
   whose every byte pattern is valid, after a length and alignment check in the
   same function.
7. On x86_64 and aarch64, every leaf read compiles to one load of the leaf's
   width, plus a byte swap when its declared order is not the host's.
8. Reading allocates nothing and is `@safe pure nothrow @nogc` whenever the
   description's own check and count functions are.
9. The caller owns the bytes. Views and slices borrow them through
   `return scope`, and the library never copies, retains or frees them.
10. The library's own files carry a header with a magic number, a version, a
    layout digest and a content key; a mismatch is a rejection, not a
    migration. The version is declared with the layout's pinned digest, so
    a changed layout fails to compile until it gets a new version.
11. A builder's output is a pure function of its inputs, so a build that
    produces a file twice produces the same bytes.

Normative keywords are bold and lowercase, with the meanings of
[BCP 14](https://www.rfc-editor.org/info/bcp14). Code blocks are illustrative
declarations of proposed operations, not shipped API.

## 2. Model, vocabulary and modules

### 2.1 Terms

A **record** is a D `struct` admitted by the [layout proof](../../../glossary.md#layout-proof)
of §3. A **leaf** is a field whose type is admitted by `WFL1` and is not a
record; a field whose type is another record is a **nested record** and lies
inline.

A **dynamic member** is a field of type `E[0]`. D gives such a field size zero
and places it at the end of the preceding fields, like a C flexible array
member. Its attributes say how many elements or bytes follow and what they are
(§5). A **conditional field** is a leaf or nested record whose presence depends
on earlier values (`WFL37`).

A record's **fixed part** runs from its start to the end of its last field that
is neither dynamic nor conditional; it is empty when there is no such field.
Its **declared size** runs to the end of its last field that is not dynamic,
conditional fields included. The **extent** of a record in a buffer is its
fixed part, then its present conditional fields, then its dynamic members, in
declaration order.

Each type has a **canonical alignment**, which is a property of the format and
not of the compiler: the size of a 1-, 2-, 4- or 8-byte scalar; 1 for the
24-bit integers; for an `Offset`, the alignment of its integer; an array's
element alignment; 1 for a dynamic member, whatever its element type, and for
`FlatSelect`, `FlatTagged` and every other zero-size marker type; and for a
record, the largest canonical alignment of its fields, or 1 when it has none.
`flatAlignOf!T` is a record's canonical alignment. A record is **naturally
aligned** when every field, recursively, sits at an offset that is a multiple
of its canonical alignment and its declared size is a multiple of
`flatAlignOf!T`. A record that is not naturally aligned is **packed**.

A **view** is a value that pairs a borrowed byte slice with a record type and
the position of one record in it. An [in-place view](../../../glossary.md#in-place-view)
additionally exposes the record as `ref const(T)` into the slice. A **swapped
read** decodes one leaf whose declared byte order differs from the host's.

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
`float`, `double`; the 24-bit integers `FlatU24` and `FlatI24`; an `Offset`
(§5.3); a static array `E[N]` with `N > 0` of an admissible leaf
or record; `bool`; or an `enum` whose base type is an admissible integer leaf.
Every other field type **must** fail the layout proof.

_Rationale:_ These are the types whose width is the same on every target D
supports. `real`, pointers, slices, classes, interfaces, delegates, associative
arrays and D `union`s either vary by target or hold addresses, which data from
outside the process cannot supply.

**WFL2: One schema.** The layout proof **must** walk `T` in lockstep with the
node indices of `wireSchemaOf!(Flat, T)`, as the JSON codec's
`decodeNative!(V, Root, nodeIndex)` and the SDL codec do, so that each layout
entry names the schema node it describes. Flat's own admissibility checks
(`WFL1`, `WFL4`) **must** run before the schema is built, so that a rejected
type reports Flat's message with its field path rather than the schema
builder's. Flat **must not** keep a second description of `T` that is not
indexed by schema nodes; a fact other formats or emitters need is added to the
shared schema.

_Rationale:_ The [SDL backend](../sdl/SPEC.md#_1-1-shared-schema-prerequisite)
set the same rule. The shared schema holds structure and resolved policy but
not D offsets, and it stores foreign attributes only as strings, so Flat reads
offsets and alias-carrying attributes from the declaration a node names, the
way the base library already re-reads `@WireConvert`.

### 2.3 Modules (proposed)

| Module                         | Contents                                                                                     |
| ------------------------------ | -------------------------------------------------------------------------------------------- |
| `sparkles.wired.flat`          | Public re-exports and the `Flat` marker                                                      |
| `sparkles.wired.flat.attrs`    | The attributes of §§3–5 and the leaf types `FlatU24`, `FlatI24`                              |
| `sparkles.wired.flat.layout`   | The layout proof, `flatLayoutOf`, `isFlatRecord`, `isFlatInPlace`, `flatAlignOf`, the digest |
| `sparkles.wired.flat.view`     | `FlatView`, `FlatArray`, `FlatSeq`, offsets, tagged unions, `flatDecode`                     |
| `sparkles.wired.flat.validate` | Eager validation under `FlatLimits`                                                          |
| `sparkles.wired.flat.arena`    | The arena header, spans, string tables and `openFlatArena`                                   |
| `sparkles.wired.flat.builder`  | `FlatBuilder`, slots and offset fix-ups                                                      |
| `sparkles.wired.flat.error`    | `FlatError`, `FlatErrorKind`, `FlatLimit`, path rendering                                    |

The package depends on `sparkles:base`, `sparkles:metadata`, `expected` and
`optional`, as the rest of `sparkles:wired` does. It does not depend on
`sparkles:font`.

## 3. The layout proof

The layout proof decides at compile time whether a type is a record and
computes its layout as a value. A failure is a `static assert` whose message
names the root type, the path from the root to the offending field, and the
fact that failed, such as `Pair.b: offset 8, expected 4 (implicit padding of 4
bytes after a)` for `struct Pair { uint a; ulong b; }` on x86_64.

**WFL3: No implicit padding.** For a record `T`, the first field's `offsetof`
**must** be zero, and each further field's `offsetof` **must** equal the
previous field's `offsetof` plus its `sizeof`. `T.sizeof` **must** equal the
declared size, or 1 when the declared size is zero. A field whose bytes are
deliberately unused **must** be declared as a leaf carrying `@FlatPad`.

_Rationale:_ Padding bytes have unspecified content in D, so a type with
implicit padding has no single byte representation, and a builder could leak
memory contents into a file. Requiring explicit pads makes every byte of the
fixed part either a named field or a declared pad. D's `align(1)` attribute is
how a description states that a format packs fields without natural alignment,
as OpenType's `head` does with its 64-bit timestamps at offset 20. D gives a
struct whose only fields are dynamic members a size of 1, which the proof
accepts and the extent ignores.

**WFL4: Rejected shapes.** The proof **must** reject: a type that is not a
`struct`; a struct with no fields; a nested struct that carries a context
pointer; a field of a type not admitted by `WFL1`; a field that is neither
dynamic nor conditional after a conditional field or a dynamic member; a
conditional field after a dynamic member; a nested record, or a static array
of records, whose record has dynamic members or conditional fields, unless it
is the last field of its parent; and a struct with a postblit, copy
constructor, destructor or `opAssign`. Each rejection **must** name the field
or member responsible.

_Rationale:_ A non-`static` nested struct carries a hidden pointer, which the
shared schema's field enumeration drops without comment. An inline record
whose extent varies would overlap the parent's later fields, whose offsets are
fixed. Lifecycle hooks would run on values that the library constructs by
reinterpretation, where they never run.

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
for every field in declaration order, its schema node, path, offset, size,
canonical alignment, leaf kind, resolved byte order and attributes, and for
every dynamic member its rule from §5. It **must** be usable in `enum` and
`static immutable` declarations, with no run-time construction. It **must
not** contain D's `alignof` of any type, which differs between targets.

**WFL53: Natural or packed.** A record whose `T.alignof` is not 1 **must** be
naturally aligned, or the proof **must** fail. A packed record is therefore
always declared with `align(1)` fields, and its D layout is the same on every
target.

_Rationale:_ D's alignment of `ulong` and `double` is 8 on x86_64 and 4 on
i686, so `struct { uint a; ulong b; }` has no padding on i686 and 4 bytes of
it on x86_64, and `struct { ulong a; uint b; }` has a size of 12 on i686 and
16 elsewhere. Judging natural alignment by the canonical rule, including the
declared size, rejects both structs on every target alike.

**WFL7: Admission for in-place use.** `isFlatInPlace!(T, hostEndian)` **must**
be true exactly when `T` is a naturally aligned record with no dynamic members,
no conditional fields and no `bool` or `enum` leaves at any depth, and every
multi-byte leaf's resolved byte order equals `hostEndian`. `hostEndian`
**must** default to `std.system.endian`. A packed record is never admitted.

_Rationale:_ A packed record has a D alignment of 1, so no start-address check
could make `ref const(T)` safe: LDC still loads `head.created`, at offset 20,
with an 8-byte-aligned instruction, which faults on armv7. `bool` and `enum`
leaves are excluded because not every byte pattern is a valid value. The D
specification makes a [`bool`](https://dlang.org/spec/type.html#bool) with a
byte other than 0 or 1 undefined behaviour, and an out-of-range enum reaching a
`final switch` raises an error from data. Rust's zerocopy draws the same line
between types "for which any bit pattern is valid" and those "for which some
bit patterns are valid" ([zerocopy 0.8.63](https://docs.rs/zerocopy/0.8.63/zerocopy/);
documentation wording, not reproduced locally).

**WFL8: Target independence.** For every record, `flatLayoutOf!T` and
`flatLayoutDigest!T` **must** be identical on every supported target. A
description that uses a type alias whose width varies by target, such as
`size_t`, `ptrdiff_t` or `c_long`, violates this requirement. The proof cannot
see such an alias, so the violation is never a compile-time error on any single
target; it is detected only by comparing digests across a 32-bit and a 64-bit
build, and remains undetected for targets no build covers.

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
the region, with the arithmetic done in 64-bit integers or overflow-checked. A
range that does not fit **must** produce `truncated` when its start is at most
the region's length, including a non-empty range that starts exactly at the
end, and `badOffset` when its start is past the end or its computation
overflows.

**WFL12: No assertion on data.** No value in the input **may** cause an
assertion failure, a `RangeError`, an exception, a call to a contract-violation
handler or undefined behaviour. Contracts (`in`, `out`, `assert`) in the read
path **may** restate only what a preceding check established.

**WFL13: Caller arguments are data.** An element index, variant choice or
other argument supplied by the caller that is out of range for the data
**must** produce `indexOutOfRange`, not a precondition failure. This mirrors
[`FTP15`](../../font/parsing.md#_1-common-rules).

**WFL14: Bounded work.** Opening a view of a record **must** cost time
linear in the size of its fixed part plus its constant and cross-field checks.
Reading a leaf, a conditional field, an element of a uniform array or an offset
target **must** cost constant time beyond the checks of the record reached.
Advancing a sequential range **must** cost the extent of one element. No other
read **may** loop or recurse over data; eager validation is bounded by
`WFL24`.

### 4.3 Opening, in-place and swapped access

**WFL15: Opening a view.** `FlatView!T.open(bytes, at = 0, regionBase = 0)`
**must** check that the fixed part fits at `at` and check every `@FlatConst`
field in the fixed part (§5.1), including those of nested records. When `T`,
or a nested record in its fixed part, carries a type-level `@WireCheck`, it
**must** then decode that record as `WFL20` does, which range-checks its
present conditional fields, and run the checks. It returns a view or the first failure,
and **must not** inspect dynamic members or offset targets, nor conditional
fields beyond what those checks require.

**WFL16: The in-place reinterpretation.** When `isFlatInPlace!T` holds for the
actual host, a view **must** offer `native`, returning `ref const(T)` into the
input, and `FlatArray!E` **must** offer `native`, returning `const(E)[]`. Both
**must** go through a single `@trusted` function that checks, in its own body,
that the range fits and that the start address is a multiple of
`flatAlignOf!T`, and returns `misaligned` or `truncated` otherwise. Code outside
that function **must not** cast between `ubyte` storage and record types. On a
host whose byte order differs from the record's, `native` does not exist; a
forced `hostEndian` argument changes the answer of `isFlatInPlace` only.

_Rationale:_ Keeping the checks inside the one trusted function gives it a safe
interface: no caller can reach the cast without them. The compile-time proof
supplies the rest of the argument: every byte pattern is a valid `T`, every
field is naturally aligned within `T`, and `T` has no indirections, padding or
lifecycle hooks. Checking `flatAlignOf!T`, not `T.alignof`, makes the check
identical on every target.

**WFL17: Accessors.** A view **must** offer one accessor per field that is not
a pad, named as the field, with the result type of the table in §4.4. A leaf
accessor **must** read the leaf from the bytes with its resolved byte order
whether or not the record is in-place, and **must not** assume an alignment the
bytes are not proven to have.

**WFL52: One load per leaf.** On x86_64 and aarch64 with the `checked` build
type, an accessor for a 2-, 4- or 8-byte leaf **must** compile, apart from its
bounds check, to one load of the leaf's width, unaligned where the target
permits it, followed by one byte swap when the leaf's order is not the host's.
For a 16-bit leaf the swap **may** be a rotate by 8 bits, and a `float` or
`double` leaf **may** add one move into a floating-point register.

_Rationale:_ This is the owner's zero-copy rule stated per field, which is
what a packed format such as OpenType can have. An LDC probe compiles a
byte-assembled little-endian 8-byte read to one `movq` on x86_64 and one `ldr`
on aarch64; `PLAN.md` keeps the probe as a codegen test.

**WFL18: Floating-point bit patterns.** A swapped read of `float` or `double`
**must** swap the bytes as an integer of the same width and reinterpret the
bits, so that every bit pattern, including signalling NaN payloads, reads back
unchanged.

**WFL19: Restricted leaves.** Reading a `bool` leaf whose byte is neither 0 nor
1, or an `enum` leaf whose value is not a member, **must** produce
`invalidValue` with the raw value. Such a leaf **must** never be produced from
the input without that check.

**WFL20: Decoding a copy.** `flatDecode!T(bytes, at = 0)` **must** return a
`T` holding every field of the fixed part and every present conditional field
decoded with its byte order, every restricted leaf checked and every constant
compared, or the first failure. An absent conditional field holds its `.init`
value; a present one that does not fit is `truncated`. Dynamic members of the
returned value are empty, as in any `T`.

### 4.4 Result types

**WFL21: Results are values.** Every fallible read **must** return
`FlatResult!X`, an alias of `Expected!(X, FlatError, NoGcHook)`, and **must
not** throw. The library **must not** offer throwing wrappers. A read that
cannot fail once its view is open **must** return `X` itself.

**WFL55: Result types by field kind.** The accessors and ranges of a view
**must** have these results:

| Read                                              | Result                                                                           |
| ------------------------------------------------- | -------------------------------------------------------------------------------- |
| Unrestricted leaf or leaf array in the fixed part | `X`, by value                                                                    |
| `bool` or `enum` leaf in the fixed part           | `FlatResult!X`                                                                   |
| Nested record in the fixed part                   | `FlatView!R`, which was checked when its parent opened                           |
| Conditional field                                 | `FlatResult!(Optional!X)`; absent is an empty `Optional`, not an error           |
| `Offset` field                                    | `FlatResult!(FlatView!R)`, or `FlatResult!(Optional!(FlatView!R))` when nullable |
| `Offset` field's stored value                     | `raw!"field"`, the unsigned integer, by value                                    |
| Dynamic member with a uniform element             | `FlatResult!(FlatArray!E)`                                                       |
| Dynamic member with a sequential element          | `FlatResult!(FlatSeq!E)`                                                         |
| `FlatArray!E`: `length`                           | `size_t`                                                                         |
| `FlatArray!E`: `opIndex(i)`, `front`              | `FlatResult!V`, `V` being `E` for a leaf or `FlatView!E` for a record            |
| `FlatArray!E`: `empty`, `popFront`, `save`        | `bool`, `void`, `FlatArray!E`: a random-access range of results                  |
| `FlatSeq!E`: `front`                              | `FlatResult!(FlatView!E)`                                                        |
| `FlatSeq!E`: `empty`, `popFront`, `save`          | `bool`, `void`, `FlatSeq!E`; after a failed `front` the range is empty           |
| `FlatSeq!E`: `opIndex(i)`                         | `FlatResult!(FlatView!E)`, linear in `i`                                         |
| `FlatTagged`: `tag`                               | the tag value, by value                                                          |
| `FlatTagged`: `match!(handlers…)`                 | the handlers' common result; one handler per variant, checked at compile time    |
| `FlatTagged`: `get!R`                             | `FlatResult!(FlatView!R)`; another variant is `unknownVariant`                   |
| `FlatString`                                      | `FlatResult!(const(char)[])`, not UTF-8-checked; `checked` validates it          |

_Rationale:_ Opening a view proves its fixed part, so most reads of a
validated record are plain values. Results remain where a read reaches bytes
that opening did not check, which keeps memory safety and the error contract
independent of whether the caller validated (`WFL10`).

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
successful validation of unchanged bytes, no read of a view of the same root
**may** return an error, except `indexOutOfRange` for a caller's argument.

**WFL24: Validation limits.** Validation **must** charge each record, array
element and string it visits `max(extent, 1)` bytes against
`FlatLimits.traversalBytes`, and track the number of offsets followed on the
current path against `FlatLimits.maxDepth`. When it follows an offset, it
**must** check the depth before charging the target. It **must** stop with
`limitExceeded`, naming the limit, at the first step or charge that passes one.
The defaults are provisional ([O7](./open-issues.md#o7-provisional-validation-limits)):
`maxDepth = 64`, and `traversalBytes` equal to 64 times the region length,
clamped to between 16,384 and 2^30 − 1.

_Rationale:_ Offsets let many records share one target, so a small input can
describe an exponentially large tree. Charging at least one byte per element
bounds arrays of empty elements, whose count alone comes from the data. A
self-referential offset stops at whichever limit it reaches first; checking
depth first makes a chain of small records stop at `maxDepth`. The defaults
are HarfBuzz's: its sanitizer allows 64 operations per byte, clamped to
between 16,384 and `0x3FFFFFFF`
([`hb-sanitize.hh`](https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-sanitize.hh#L110-L117),
[its use](https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-sanitize.hh#L236-L241)),
and a nesting limit of 64
([`hb-limits.hh`](https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-limits.hh#L52-L53)).
Shared targets, such as the Coverage tables `GSUB` and `GPOS` reuse, are
charged at every visit, so the budget is checked against real fonts in
`PLAN.md`. Cap'n Proto requires the same defence: a reader increments a
counter by the size of each object it dereferences and fails past a limit, with
a pointer depth limit of 64 in its C++ implementation
([encoding](https://capnproto.org/encoding.html); documented behaviour, not
reproduced locally).

## 5. Variable-length members

### 5.1 Constants, pads, bit ranges and checks

**WFL25: Constant fields.** A leaf carrying `@FlatConst(v)` **must** be
compared with `v` when a view of its record is opened, or, for a conditional
field, when it is read, and a different value **must** produce
`constantMismatch` carrying both values. The builder **must** write `v` there
whatever the source value holds.

**WFL26: Pads.** A `@FlatPad` leaf **must** be written as zero bytes by the
builder and **must** be ignored by readers, unless it is declared
`@FlatPad(FlatPadRead.mustBeZero)`, in which case a non-zero byte **must**
produce `invalidValue`. A pad has no accessor.

**WFL27: Bit ranges.** `@FlatBits!(name, shift, width)` on an unsigned integer
leaf **must** define a derived value `name` of the leaf's type, equal to the
`width` bits of the leaf starting at bit `shift`. The mask **must** be computed
in `ulong`, with a width of 64 meaning all bits. The proof **must** reject a
width of zero, a range that exceeds the leaf's width, and two ranges on one
field with the same name.

**WFL28: Cross-field checks.** A record **may** carry type-level `@WireCheck`
attributes as the [expressiveness specification](../expressiveness/SPEC.md#_6-4-validation-wirecheck)
defines them. On Flat, a check receives the value `flatDecode` produces and
runs when a view opens, and a failure **must** produce `checkFailed` carrying
the check's message.

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
bit ranges, and the record's parameters (§5.5). Selectors (`WFL39`) and
conditions (`WFL37`) use the same scope.

**WFL29: Rules are checked at compile time.** The proof **must** reject a rule
naming a value not in scope at that member, a value that is not an unsigned
integer, a function that is not callable with the named values, a count or
selector function whose result is not `FlatResult!ulong`, and a member carrying
no length attribute or more than one.

**WFL30: Rule arithmetic is checked.** A rule's value **must** be computed in
`ulong`. A function rule reports its own overflow as `countOverflow` through
its result. The library's multiplication of a count by an element size, and
addition of a length to a position, **must** be overflow-checked and produce
`countOverflow` on overflow.

**WFL31: Back-to-back placement.** The first dynamic member **must** start at
the end of the record's present conditional fields, or of its fixed part when
none is present, and each further dynamic member at the end of the previous
one. A `@FlatBytes` length that is not a whole number of elements **must**
produce `invalidLength`.

**WFL32: Rest.** A `@FlatRest` member **must** be the last member of its record
and **must** extend to the end of the region (§5.3). A rest length that is not
a whole number of elements, and a rest over elements whose extent is zero,
**must** produce `invalidLength`.

**WFL33: Uniform and sequential arrays.** An array whose element is a record
with no dynamic members, or whose elements' sizes depend only on parameters
and selectors the array supplies, is **uniform**: its stride is computed once,
element `i` **must** be reachable in constant time, and the array **must**
expose `length` and indexing. An array whose element sizes depend on each
element's own bytes is **sequential**: it **must** expose a forward range whose
`popFront` costs the extent of one element, and indexing **must** cost at most
linear time in the index. A sequential element whose extent is zero **must**
produce `invalidLength`, so every step advances.

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
the target is absent, and the accessor **must** return an empty `Optional`
rather than a view at the base. When `nullable` is false, 0 is an ordinary
offset.

**WFL36: Following offsets.** Following an offset **must** open a view of the
target with the checks of `WFL15`, anywhere in the region. A target outside the
region **must** produce `badOffset` carrying the offset's own position and its
value.

_Rationale:_ OpenType subtables are shared and may lie outside the extent of
the record that points at them, so containment is checked against the region.
A consumer that wants a table confined to its own bytes opens the root on that
table's slice, passing the slice's position in the file as `regionBase`.

### 5.4 Conditional fields and unions

**WFL37: Conditional fields.** A leaf or nested record carrying
`@FlatSince!(name, v)` is present only when the value `name` is at least `v`,
and one carrying `@FlatPresentIf!(pred, names…)` only when `pred` applied to the
named values is true. Every conditional field **must** follow the fixed part.
The `@FlatSince` thresholds on one name **must** not decrease in declaration
order, or the proof fails. A conditional field that follows an absent one is
absent whatever its own condition says. Reading a present conditional field
**must** range-check it and produce `truncated` if it does not fit.

_Rationale:_ This is how OpenType grows tables by version: an `OS/2` table of
version 0 is 78 bytes and one of version 5 is 100, so a description of version
5 must open a version-0 table and report the later fields absent. Making
absence monotone keeps every present field at its proven offset.

**WFL38: Tagged unions.** `FlatTagged!(Tag, tagOffset, endian, v1, R1, v2, R2,
…)` **must** be usable as the target of an offset and as an element type.
Opening it reads a `Tag` at `tagOffset` from the union's start, selects the
record whose value matches, and opens that record there; a tag with no matching
record **must** produce `unknownVariant` carrying the tag. Each `Ri` **must**
declare its tag field as `@FlatConst(vi)` at `tagOffset`, checked at compile
time, so the tag is checked once more by the variant's own view.

**WFL39: Selected element types.** `FlatSelect!(name, v1, R1, v2, R2, …)`
**must** be usable as the element type of a dynamic member. It selects the
element record by the value `name` in scope, and a value with no match **must**
produce `unknownVariant`.

### 5.5 Parameters

**WFL40: Record parameters.** A record type **may** declare named parameters
with `@FlatParam!(T, name)`, `T` an unsigned integer type. A member whose
element type has parameters **must** supply each with `@FlatArgs!(names…)`
naming values in scope at the member, and the proof **must** reject a missing,
extra or narrower-typed argument. Inside the record, parameters are in scope
like leaves.

_Rationale:_ A delta-set row of an OpenType `ItemVariationData` has a layout
determined by fields of the table that holds it, not by bytes of its own.
Parameters make that dependency explicit and keep the array uniform (`WFL33`).

### 5.6 Layout digest and pins

**WFL41: Layout digest.** `flatLayoutDigest!T` **must** be the 64-bit FNV-1a
hash of a canonical serialization of `flatLayoutOf!T` and of the layouts of
every record it reaches through nested records, `Offset`, `FlatSpan`,
`FlatTagged` and `FlatSelect` targets, visited depth-first in declaration
order. The serialization **must** include field order, leaf kinds, sizes,
offsets, canonical alignments, byte orders, constants, pad policies, bit
ranges, count and selector rules by shape and by the position of the values
they name, conditions, offset widths, bases and nullability, union tags, and
for an `enum` leaf its members' values. A record reached a second time
**must** be serialized as a back-reference to its first-visit index, so that
recursive layouts terminate. The serialization **must not** include field,
member or type names, documentation, `@FlatLayoutPin` and `@FlatArena`
attributes, `@WireCheck` attributes, or anything target-dependent. The
depth-first list of records it visits is the root's **visit table**.

_Rationale:_ The digest guards against reading a file with a different layout,
which is an accident, not an attack; content identity and integrity are the
content key's job (§7). Names are excluded so that renaming a field keeps
existing files readable. `wireSchemaDigest` cannot serve: it hashes field and
enum member names and omits offsets and offset targets.

**WFL54: Layout pins.** A record **may** carry one or more
`@FlatLayoutPin(version, digest)` attributes, which together are its pin
history. The proof **must** fail when the versions are not strictly
increasing in declaration order, when two pins share a digest, or when
`flatLayoutDigest!T` differs from the digest of the last pin; the message
**must** give the computed digest. Every arena root **must** carry a pin
history, and its **current version** is the last pin's version.
`openFlatArena` and the builder's `finish` **must** take the version from the
pin history, never from an argument.

_Rationale:_ A changed layout without a changed version would be read as a
`layoutMismatch` at run time on every device. With the version declared next
to the digest, a layout change fails to compile until the author appends a
pin with a new version; prior pins stay, so reusing an old digest or version
is a compile error too. Rewriting the last pin in place is the remaining
escape, which the golden files of `PLAN.md` FL3 catch.

## 6. Describing OpenType

OpenType is the reference foreign format: big-endian, packed, with `Offset16`
and `Offset32` relative to a table or subtable start, arrays counted by sibling
fields, tables extended by version, and subtables tagged by format. The
following descriptions are illustrative; their shape, not their spelling, is
normative. None of them is in-place on a little-endian host, and `Head` and
`ItemVariationStore` are packed, so they are read through accessors (`WFL52`).

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
36 for `hhea`, 4 for each Coverage format, 8 for `ItemVariationStore`, 6 for
`ItemVariationData` and 0 for a delta set.

`head` and `hhea` are fixed records. `align(1)` places `head.created` at
offset 20 without padding, which makes `Head` packed, and `@FlatConst` checks
the magic number. `Hhea`'s 2-byte fields all sit at even offsets, so it is
naturally aligned:

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
    long created;                  // LONGDATETIME, at offset 20
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
    @FlatConst(1) ushort coverageFormat;
    ushort glyphCount;
    @FlatCount!"glyphCount" ushort[0] glyphArray;
}

@FlatEndian(Endian.bigEndian)
struct RangeRecord
{
    ushort startGlyphID, endGlyphID, startCoverageIndex;
}

@FlatEndian(Endian.bigEndian)
struct CoverageFormat2
{
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
The description states both with parameters and a selected element type.
`DeltaSet` has only dynamic members, so its fixed part is empty; D
gives it a size of 1, which the extent ignores (`WFL3`):

```d
@FlatEndian(Endian.bigEndian)
@FlatParam!(ushort, "wordCount") @FlatParam!(ushort, "regionCount")
struct DeltaSet(Wide, Narrow)
{
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
    Offset32!VariationRegionList variationRegionListOffset; // at offset 2
    ushort itemVariationDataCount;
    @FlatCount!"itemVariationDataCount"
    Offset32!ItemVariationData[0] itemVariationDataOffsets; // from the store
}

// VariationRegionList is described the same way and omitted here.
```

Because `DeltaSet`'s size depends only on its parameters and the selector,
`deltaSets` is a uniform array (`WFL33`): row `i` is reached in constant time,
as HarfBuzz and
[fontations](https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/read-fonts/src/tables/variations.rs#L1719-L1738)
compute it. When both counts are zero, every row is empty and the array has
stride zero; indexing it is still constant time, and validation charges each
row one byte (`WFL24`). Fontations types the rows as raw bytes of a computed
length
([`variations.rs`](https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/resources/codegen_inputs/variations.rs#L144-L160))
and decodes deltas by hand; this description keeps them typed.

## 7. Arena formats

An arena format is a file that this library writes and later reads in place:
the font catalog and glyph-atlas cache of the
[startup slice](../../font/PLAN.md#ms-startup-slice) are the first. Its bytes
are little-endian, because every target Sparkles builds for is, so readers on
those targets take the in-place path for naturally aligned records.

**WFL43: The arena header.** An arena file **must** begin with this record,
little-endian, at offset 0:

| Offset | Field          | Type        | Meaning                                                             |
| ------ | -------------- | ----------- | ------------------------------------------------------------------- |
| 0      | `magic`        | `ubyte[8]`  | Format identity, from the root's `@FlatArena(magic)`, fixed forever |
| 8      | `version`      | `uint`      | The root's current version, from its pin history (`WFL54`)          |
| 12     | `headerSize`   | `uint`      | 64, the size of this header                                         |
| 16     | `layoutDigest` | `uint[2]`   | `flatLayoutDigest` of the root record (`WFL41`), low half first     |
| 24     | `byteLength`   | `uint[2]`   | Total file length, header included, low half first                  |
| 32     | `contentKey`   | `ubyte[32]` | The content hash of the inputs the file was built from              |

`layoutDigest` and `byteLength` are 64-bit values stored as two `uint` halves,
so that the header needs only 4-byte alignment (`WFL45`). The root record
**must** start at offset 64.

**WFL44: Opening an arena.** `openFlatArena!Root(bytes, regionBase = 0)`
**must** compile only for a `Root` carrying `@FlatArena(magic)` and a pin
history, and
**must** check, in this order, stopping at the first failure: at least 8 bytes
(`truncated`); `magic` (`notThisFormat`); at least 64 bytes (`truncated`);
`version` against the current version (`unsupportedVersion`, carrying both); `headerSize`
(`invalidValue`); `layoutDigest` against `flatLayoutDigest!Root`
(`layoutMismatch`, carrying both); `byteLength` equal to the input length
(`invalidLength`). It then opens the root as `WFL15` does and returns its view,
in time independent of the file's size. Eager validation is a separate call.

_Rationale:_ Checking the magic before the full header length lets a short
unrelated file report `notThisFormat`. Keeping "wrong version" distinct from
"same version, different layout" exposes a pin rewritten in place (`WFL54`). Arena files are caches keyed by content and
rebuilt on mismatch, so no migration path is specified. Leaving validation to
the caller keeps opening cheap; every later read is bounded either way.

**WFL45: Alignment ceiling.** Every record reachable from a root carrying
`@FlatArena` **must** have a canonical alignment of at most 4, or the proof
fails. A record that needs a 64-bit integer **must** store it as two `uint`
fields or a `ubyte[8]`. `openFlatArena` and `FlatBuilder` **must** reject a
root without `@FlatArena` or without a pin history at compile time.

_Rationale:_ Android stores uncompressed APK assets aligned to 4 bytes by
[zipalign](https://developer.android.com/tools/zipalign) (documented behaviour,
not reproduced locally), so 4 is the strongest alignment an asset read in place
can rely on. That alignment holds only for assets stored uncompressed, and
`AAsset_getBuffer` returns memory aligned as the asset's offset in the file is.
Within the file, the builder aligns each record to its own alignment, so a file
mapped at a 4-byte boundary is aligned throughout.

**WFL46: Spans and strings.** `FlatSpan!E` **must** be a record, not a leaf, of two
little-endian `uint` fields, `offset` from the region start and `count`, naming
a uniform array of `E`. `FlatString` **must** be `FlatSpan!char`. Its accessor
returns the bytes as `const(char)[]` without checking UTF-8, in constant time;
its `checked` accessor validates them, in time linear in their length, and
returns `invalidUtf8` with the position of the first bad byte. Eager validation
**must** check every `FlatString` it reaches.

## 8. The builder

**WFL47: Builder storage.** `FlatBuilder!(Root, Storage)` **must** write into
a caller-supplied output: a growable `sparkles.base.buffer` buffer or a fixed
`ubyte[]`. Exhausting fixed storage **must** produce `limitExceeded` with the
limit `builderStorage` and the size needed. Builder operations are templates
and infer `@safe pure nothrow @nogc` from their storage.

**WFL48: Allocation and fix-up.** The builder **must** offer:
`reserve!R()` and `reserveArray!R(n)`, which allocate space aligned to
`flatAlignOf!R` and return `FlatResult!(FlatSlot!R)`; `write(slot, value)`,
which encodes each leaf with its declared byte order; `putString(text)` and
`putBytes(bytes)`, which return a `FlatResult!FlatString` or span; and
`link!"field"(from, to)`, which sets an `Offset` or `FlatSpan` field of slot
`from` to point at slot `to` and returns `FlatResult!void`. A link whose
target precedes the offset's base, or whose distance does not fit the field's
width, **must** produce `offsetOverflow`. A slot from another builder, or a
reserved slot not written before `finish`, **must** produce `invalidSlot`. A
failed operation **must** leave the builder unchanged, so the caller may retry
with more storage or abandon it.

**WFL49: Deterministic output.** The builder's output **must** be a pure
function of the sequence of builder calls and their arguments. Alignment gaps
and pads **must** be zero bytes. `finish(contentKey)` **must** write the
arena header of `WFL43`, taking the magic from `@FlatArena`, the version from
the pin history and the digest from `flatLayoutDigest!Root`.

_Rationale:_ Nix builds the startup slice's files at package build time, and
both reproducibility and content-keyed caching need byte-identical output for
identical inputs.

**WFL50: Round-trip.** For every value the builder writes, reading the result
through `openFlatArena` **must** succeed and every accessor **must** return
the written value.

## 9. Errors

**WFL51: Error location.** A `FlatError` **must** carry its `kind`; the
absolute byte offset where the problem was found, which is `regionBase` plus
the offset in the region; the offset of the enclosing record's start; the
location of the field; the name of the root type; and, where the problem
concerns a value read from the data, that value and the expected value or
bound. A `limitExceeded` error **must** name the limit and its value.

_Rationale:_ `regionBase` lets a consumer that opens a table slice report
file-absolute offsets, while the record start gives the table-relative one, as
[`FTP14`](../../font/parsing.md#_1-common-rules) requires of `sparkles:font`.
A font port maps a `maxDepth` stop to its own `cycle` kind and supplies the
table tag itself.

**WFL56: Compact paths.** A `FlatError` **must** store the field's location as
a sequence of hops, not as text. A hop is a record's index in the root's visit
table (`WFL41`), a field's ordinal in that record, and an optional array index;
a path crosses into a new hop at every nested record, array element and
followed offset, so recursive layouts repeat visit-table entries rather than
needing new ones. The error **must** keep the first hop and the 7 innermost,
and record whether hops between them were dropped. Its `toString(writer)`
**must** render the path on demand in the [path syntax](../SPEC.md#_9-errors)
of base §9, such as `$.itemVariationDataOffsets[3].regionIndexes`, where a
followed offset continues the path with the target's field, and **must** write
`…` where hops were dropped. A `FlatError` **must not** exceed 160 bytes, and
building or rendering one **must not** allocate from the garbage collector.

_Rationale:_ Every `FlatResult` carries room for an error, and test threads
have 512 KiB stacks. A text path would make each result as large as its longest
path. Eight hops of a 16-bit record index, a 16-bit field ordinal and a 64-bit
array index take 96 bytes; with the kind, the limit, two offsets, the value
and its bound, and a pointer to the root's static name table, the error stays
under 160.

Error kinds (proposed `FlatErrorKind`):

| Kind                 | Raised when                                                                                                            |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `truncated`          | A range starts at or before the region's end but does not fit                                                          |
| `badOffset`          | A position is past the region's end, or its computation overflows                                                      |
| `misaligned`         | An in-place view's start is not a multiple of the type's canonical alignment                                           |
| `constantMismatch`   | A `@FlatConst` field holds another value                                                                               |
| `invalidValue`       | A restricted leaf, strict pad or header field holds an invalid value                                                   |
| `checkFailed`        | A `@WireCheck` rejected a record                                                                                       |
| `unknownVariant`     | A tag or selector matches no variant, or `get!R` names another variant                                                 |
| `countOverflow`      | Count, length or position arithmetic overflows                                                                         |
| `invalidLength`      | A length is not a whole number of elements, an element's extent is zero where it must advance, or `byteLength` differs |
| `invalidUtf8`        | A checked string is not UTF-8                                                                                          |
| `indexOutOfRange`    | A caller's index or argument is out of range for the data                                                              |
| `limitExceeded`      | Validation or builder storage passes a limit                                                                           |
| `notThisFormat`      | An arena's magic differs                                                                                               |
| `unsupportedVersion` | An arena's version differs                                                                                             |
| `layoutMismatch`     | An arena's layout digest differs                                                                                       |
| `offsetOverflow`     | The builder cannot represent a link in its offset's width or direction                                                 |
| `invalidSlot`        | A builder slot is foreign or unwritten                                                                                 |

Exact message text is not part of the contract; the fields above are.

## 10. Proposed surface and requirement index

The surface below is proposed. Names may change before delivery; the
requirements bind behaviour, not spelling.

| Operation                                                                           | Requirement               |
| ----------------------------------------------------------------------------------- | ------------------------- |
| `isFlatRecord!T`, `flatLayoutOf!T`, `flatAlignOf!T`                                 | `WFL3`–`WFL6`, `WFL53`    |
| `isFlatInPlace!(T, hostEndian)`                                                     | `WFL7`                    |
| `FlatView!T.open(bytes, at, regionBase)`, accessors, `native`                       | `WFL15`–`WFL17`, `WFL55`  |
| `FlatArray!E`, `FlatSeq!E`, `FlatTagged` views                                      | `WFL33`, `WFL38`, `WFL55` |
| `flatDecode!T(bytes, at)`                                                           | `WFL20`                   |
| `validateFlat!T(bytes, limits[, sink])`                                             | `WFL23`, `WFL24`          |
| `flatLayoutDigest!T`, `@FlatLayoutPin`                                              | `WFL41`, `WFL54`          |
| `openFlatArena!Root(bytes, regionBase)`, `@FlatArena(magic)`                        | `WFL44`                   |
| `FlatBuilder!(Root, Storage)`: `reserve`, `reserveArray`, `write`, `link`, `finish` | `WFL47`–`WFL50`           |

| ID                        | Requirement                                              | Traces to                                        | Status  |
| ------------------------- | -------------------------------------------------------- | ------------------------------------------------ | ------- |
| `WFL1`, `WFL2`            | Admissible leaves; lockstep with the shared schema       | proposed `sparkles.wired.flat.layout`            | planned |
| `WFL3`–`WFL8`, `WFL53`    | Layout proof, byte order, alignment, in-place admission  | proposed `flatLayoutOf`, `isFlatInPlace`         | planned |
| `WFL9`, `WFL10`           | Borrowed, stable input                                   | proposed `sparkles.wired.flat.view`              | planned |
| `WFL11`–`WFL14`           | Bounded reads, no assertion on data, bounded work        | proposed `sparkles.wired.flat.view`              | planned |
| `WFL15`–`WFL20`, `WFL52`  | Opening, in-place reinterpretation, loads, swaps, decode | proposed `FlatView`, `flatDecode`                | planned |
| `WFL21`, `WFL22`, `WFL55` | Result types and attributes                              | proposed `FlatResult`                            | planned |
| `WFL23`, `WFL24`          | Eager validation and its limits                          | proposed `validateFlat`, `FlatLimits`            | planned |
| `WFL25`–`WFL28`           | Constants, pads, bit ranges, cross-field checks          | proposed `sparkles.wired.flat.attrs`             | planned |
| `WFL29`–`WFL33`           | Counted, byte-length and rest arrays                     | proposed `FlatArray`, `FlatSeq`                  | planned |
| `WFL34`–`WFL36`           | Offsets, bases, null offsets                             | proposed `Offset`                                | planned |
| `WFL37`–`WFL40`           | Conditional fields, tagged unions, selection, parameters | proposed `FlatTagged`, `FlatSelect`, `FlatParam` | planned |
| `WFL41`, `WFL54`          | Layout digest and pins                                   | proposed `flatLayoutDigest`, `FlatLayoutPin`     | planned |
| `WFL42`                   | OpenType acceptance set                                  | proposed test descriptions                       | planned |
| `WFL43`–`WFL46`           | Arena header, opening, alignment, spans, strings         | proposed `openFlatArena`, `FlatSpan`             | planned |
| `WFL47`–`WFL50`           | Builder                                                  | proposed `FlatBuilder`                           | planned |
| `WFL51`, `WFL56`          | Error location and compact paths                         | proposed `FlatError`                             | planned |

## 11. Dependencies

The library needs, from outside this specification:

- The shared schema of the [expressiveness specification](../expressiveness/SPEC.md#_2-the-reified-schema),
  walked in lockstep as `WFL2` states; see
  [O10](./open-issues.md#o10-alias-carrying-attributes-through-the-shared-schema).
- `@WireCheck` from [expressiveness §6.4](../expressiveness/SPEC.md#_6-4-validation-wirecheck)
  for `WFL28`; see [O3](./open-issues.md#o3-wirecheck-is-not-delivered).
- A byte source in `sparkles:base` that maps a file or an Android asset as
  `const(ubyte)[]` with a stated lifetime, for the first arena consumer; see
  [O1](./open-issues.md#o1-the-byte-source).
- A content hash for `contentKey`, computed by the consumer; see
  [O2](./open-issues.md#o2-the-content-key).
