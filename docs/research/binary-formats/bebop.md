# Bebop (C# compiler and multi-language runtimes)

A compact schema compiler separating immutable-layout structs from evolvable
indexed messages, with fixed-width little-endian scalars and small runtimes.

| Field           | Value                                                           |
| --------------- | --------------------------------------------------------------- |
| Language        | C# compiler; TypeScript, C#, Rust, C++ and other runtimes       |
| License         | Apache-2.0; see [license][license]                              |
| Repository      | [6over3/bebop][repo]                                            |
| Documentation   | [Wire format][wire] · [structs][structs] · [messages][messages] |
| Category        | Schema-first sequential records and indexed messages            |
| Reviewed source | `03a2a761d7ea96afdb5bcd8885d0be15cc888e8a`                      |

## Overview

### What it solves

Bebop generates typed encoders/decoders from `.bop` schemas without imposing
a large general-purpose runtime. The encoding has two important record shapes:
structs concatenate all fields, while messages encode only present indexed
fields inside a length-delimited body. Unions add a discriminant and length.
[Wire format][wire]

### Design philosophy

The [struct documentation][structs] makes the compatibility bargain explicit:

> When you define a `struct`, you're promising to never add or remove fields
> from it.

The convenience of one generated API must not obscure that distinction.
Struct compactness and message evolution are different contracts. Neither
turns a decoded TypeScript object into an in-place view simply because a
runtime helper is named `BebopView`. See [concepts][concepts] and
[comparison][comparison] for the catalog's access-model distinctions.

## How it works

### Schema source of truth

The `.bop` declaration specifies scalar types, enums, arrays, maps, structs,
messages and unions. Message fields have explicit indices; struct fields have
an ordered layout with no indices. The compiler generates binding-specific
code. [Types][types], [structs][structs], [messages][messages]

```text
message M {
    1 -> byte x;
    2 -> int16 y;
    3 -> int32 z;
}
```

This is the [wire documentation's example][wire], not a D declaration.
Binary schemas can carry a condensed compiler-produced schema for dynamic
tooling; [`binary.ts`][binary-runtime] is the TypeScript implementation.
That schema transport is distinct from claiming every ordinary datum is
self-describing. [Binary-schema documentation][binary-schema]

The [serde catalog][serde] covers general host-language schema frameworks;
Bebop's generated record model is a specific encoding design, not another
reason to duplicate that survey here.

### Wire encoding

Integer and floating-point scalars have fixed widths and little-endian byte
order. A boolean is one byte. Enums use their declared underlying integer
type, defaulting to `uint32`. Strings have a `uint32` byte count and UTF-8
bytes; arrays have a `uint32` element count; maps count key/value pairs.
[Wire format][wire]

Structs concatenate fields. Messages have a `uint32` body length, then
one-byte field indices plus payloads, ending with index `00`. Field indices
do **not** carry a wire type or an individual payload length. A union has
a length followed by a one-byte discriminator and selected record body.
The union's length counts body bytes after the discriminator. [Wire][wire], [generator][generator]

**Upstream reference vector, not locally executed encoder output:** for the
schema above and `{x = 15, z = 5}`, [the wire documentation][wire] gives:

```text
08 00 00 00 01 0f 03 05 00 00 00 00
```

The first four bytes encode the eight-byte body length; `01 0f` is `x`;
`03 05 00 00 00` is `z`; the last `00` terminates the body. The same source
gives the all-absent message as `01 00 00 00 00`. These are upstream vectors,
not fabricated runtime observations or benchmark data.

Dates use .NET-style 100 ns ticks from year 1, with the top two bits ignored;
GUIDs use `.NET Guid.ToByteArray` order, not an unspecified textual UUID order.
These interoperability details should accompany any D implementation.
[Wire format][wire], [runtime constants and GUID functions][runtime]

### Access model

The TypeScript runtime's `BebopView` owns a cursor and a `DataView` over bytes.
Generated decoders read values from that cursor and construct ordinary objects.
`CompileDecodeStruct` emits local field values followed by an object literal;
`CompileDecodeMessage` creates an object and assigns fields in a loop.
[Runtime][runtime], [TypeScript generator][generator]

`readBytes` returns a `Uint8Array.subarray`, so that particular payload can
borrow backing storage. That is narrower than zero-copy decoding of every
record. Strings, maps, arrays and scalar object fields still have their
binding-specific representations. [Runtime][runtime]

Fixed scalars use `DataView` with explicit little-endian access and no native
alignment requirement. Structs with variable-length fields still require
sequential decoding; later field offsets depend on preceding values.
`mut struct` concerns generated object's mutability, not necessarily the
ability to patch serialized bytes in place. [Struct documentation][structs]

### Variable-length and optional data

Array/map/string counts precede concatenated payloads. Message absence means
no indexed field is emitted; it is not an encoded native nullable pointer.
Struct fields are always present. A message's final zero index distinguishes
the end of its field list from ordinary absent members. [Wire format][wire]

An unknown message index cannot be skipped as an individual value because
its type/size is unavailable. The reader jumps to the message's end instead.
`CompileDecodeMessage` emits `view.index = end; return message;` for the
default switch branch. This discards the _remaining message body_, not merely
one unknown field. [TypeScript generator][generator]

For an unknown union discriminator, the TypeScript generator likewise moves
to the end but throws `BebopRuntimeError`. Unknown message fields and unknown
union members therefore have different application outcomes. The
[union documentation][unions] explicitly permits a catchable decode failure.

### Evolution and compatibility

New message indices permit additions without changing the encoding of known
fields. Established indices and types still need stable meaning. Because the
first unknown index ends decoding of the message, compatibility depends on
writer ordering and on the application's expectations for later known fields.
Do not describe this as Protobuf's schema-free skip-one-field behavior.
[Wire format][wire], [generator][generator]

Structs cannot change field count/order while retaining their old contract.
A replacement needs a distinct type or an evolvable enclosing message/union.
Union variants use stable discriminants, and an old reader may reject an
unknown variant rather than synthesize a value. [Structs][structs], [unions][unions]

The [draft Flat arena][flat-draft] similarly rejects incompatible layouts, but
adds `WFL54` pin histories and an explicit cache rebuild policy. Bebop's
immutable-layout promise is a schema convention, not proof of the draft's
compile-time digest/version enforcement or its retained golden-file checks.

### Determinism and canonical form

**N/A as a specified canonical content encoding:** the cited wire rules define
typed representations but no universal normalization of message ordering,
map order, floating-point NaNs or every equivalent application value.
Generated writers can be repeatable under a fixed model/runtime, which is a
different promise from canonical bytes across bindings. [Wire format][wire]

The distinction is also visible in dates: ignored high bits are not semantic
information yet can differ in incoming representations. A signing profile must
say whether it signs exact received bytes or normalized values. The draft
Flat builder's `WFL49` repeatability of call sequences likewise does not settle
canonicalization of equivalent content. [Wire][wire], [draft][flat-draft]

### Merkleization and content addressing

**N/A in the format:** field indices, union discriminants and schema opcodes
are not content digests. The wire specification defines no hash algorithm,
child-link convention or inclusion proof. A message carrying a byte-array hash
would need application-level interpretation and integrity checks. [Wire][wire]

Even a fixed-layout struct containing digests is not automatically a Merkle
node protocol. Ordering, identity boundaries and schema binding still need
specification. The [content-addressing catalog][cas] treats those requirements
directly; the draft arena's opaque input key is another distinct cache policy.

### Hostile-input safety

The TypeScript source does not establish the draft Flat's proposed bounded,
value-returning failure contract. Multi-byte `DataView` reads can throw
`RangeError`. `readByte` directly indexes the array and increments its cursor;
out-of-range access is not an explicit structured decoder error.
[Runtime][runtime]

`readBytes` reads a length, advances the index by that length and returns
`subarray(start, end)`. JavaScript clamps that subarray; the helper itself does
not reject an advertised payload extending beyond the input. The generated
message loop also does not establish a per-field `end` bound before every
known-field decode. These are precise source observations, not a claim that
every Bebop runtime has the same behavior. [Runtime][runtime], [generator][generator]

The short-string decoder manually assembles UTF-8 code points; the long-string
path uses a default `TextDecoder`. Neither should be presented as evidence of
strict rejection of every invalid UTF-8 sequence. Explicit hostile-input
validation requires more than length-delimited framing. [Runtime][runtime]

Nested records and declared container counts require work/allocation/depth
limits in a hardened integration. No global traversal budget analogous to
the draft's `WFL24` was established from these TypeScript paths. This is a
review limitation, not an assertion that safe low-level host reads can access
outside JavaScript memory or that a formal vulnerability was confirmed.

### Describing foreign formats

**Limited fixed concatenation, not arbitrary layouts:** a scalar-only struct
can coincide with an existing little-endian packed record. The schema does
not generally express mixed endian, absolute/ancestor-relative offsets,
dependent array counts from arbitrary earlier fields, or externally prescribed
tagged subtables. [Wire format][wire], [types][types]

The draft Flat reader's foreign-layout vocabulary and `WFL45` own-arena
four-byte ceiling solve different issues. Bebop's `DataView` scalar access
avoids a native alignment precondition; it does not supply the draft's
compile-time proof that selected D records can safely be exposed by reference.
[Draft][flat-draft], [runtime][runtime]

### Implementation and performance evidence

The [built-in generator registration][host] lists C#, Dart, Rust, Python,
TypeScript, C++ and C, not D. No D binding was verified by the targeted
repository and DUB search; that is not proof that none exists. The independent
D invariant below is not a binding or evidence of an upstream-supported D runtime.

The [TypeScript runtime][runtime] and [generator][generator] substantiate
cursor access, object creation, endian reads and unknown-field control flow.
The [upstream benchmark directory][benchmarks] contains TypeScript workloads;
it is evidence of a harness, not a transferable speed ranking.

No compiler, runtime test suite or benchmark was executed for this page.
The two message hex examples are explicitly upstream documentation vectors.
The upstream README's headline speedups are not repeated as measured findings:
they would require pinned toolchains, schemas, allocations, payloads and
hardware comparable to the intended Sparkles consumer.

This **independent invariant check** verifies byte positions in the published
message vector. It is not a Bebop codec, does not discover field types and
does not invoke any upstream runtime.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "binary_bebop_invariant"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : writeln;

void main() @safe
{
    immutable ubyte[12] bytes = [8, 0, 0, 0, 1, 15, 3, 5, 0, 0, 0, 0];
    const body = bytes[0] | (uint(bytes[1]) << 8)
        | (uint(bytes[2]) << 16) | (uint(bytes[3]) << 24);
    const z = bytes[7] | (uint(bytes[8]) << 8)
        | (uint(bytes[9]) << 16) | (uint(bytes[10]) << 24);
    assert(4 + body == bytes.length && bytes[$ - 1] == 0);
    assert(bytes[4] == 1 && bytes[5] == 15 && bytes[6] == 3 && z == 5);
    writeln("body-bytes=", body, " x=", bytes[5], " z=", z, " stop=", bytes[$ - 1]);
}
```

```ansi
body-bytes=8 x=15 z=5 stop=0
```

## Strengths

- Small explicit wire rules and lightweight generated runtimes.
- Struct/message split makes the compactness/evolution choice visible.
- Fixed-width little-endian scalars avoid varint loops for numeric fields.
- Generator source makes unknown-field and unknown-union behavior auditable.

## Weaknesses

- Unknown message indices skip the remainder, not just one field.
- Normal generated object decoding is not a general in-place view.
- Reviewed TypeScript paths do not establish strict hostile-input validation.
- No specified canonical content encoding, Merkle graph or arbitrary-layout model.

## Key design decisions and trade-offs

| Decision                          | Rationale                        | Trade-off                                       |
| --------------------------------- | -------------------------------- | ----------------------------------------------- |
| Fixed-width scalars               | Simple direct reads              | Small integers are not varint-compressed        |
| Struct concatenation              | Minimal per-field overhead       | Layout cannot evolve in place                   |
| Indexed length-delimited messages | Optionality and forward skipping | Unknown type forces skipping the remaining body |
| Generated idiomatic objects       | Convenient binding APIs          | Decoding can allocate/materialize               |

## Sources

- [Wire format and official byte vectors][wire], [structs][structs], [messages][messages]
  and [union behavior][unions].
- [TypeScript runtime][runtime], [TypeScript generator][generator] and [binary schemas][binary-schema].
- [Benchmark workload sources][benchmarks]; no local throughput result is claimed.
- Proposed [Flat specification][flat-draft], used only as a design comparison.

<!-- References -->

[repo]: https://github.com/6over3/bebop/tree/03a2a761d7ea96afdb5bcd8885d0be15cc888e8a
[license]: https://github.com/6over3/bebop/blob/03a2a761d7ea96afdb5bcd8885d0be15cc888e8a/LICENSE.TXT
[wire]: https://github.com/6over3/bebop/blob/03a2a761d7ea96afdb5bcd8885d0be15cc888e8a/docs/src/content/docs/reference/wire-format.mdx
[structs]: https://github.com/6over3/bebop/blob/03a2a761d7ea96afdb5bcd8885d0be15cc888e8a/docs/src/content/docs/reference/struct.mdx
[messages]: https://github.com/6over3/bebop/blob/03a2a761d7ea96afdb5bcd8885d0be15cc888e8a/docs/src/content/docs/reference/message.mdx
[unions]: https://github.com/6over3/bebop/blob/03a2a761d7ea96afdb5bcd8885d0be15cc888e8a/docs/src/content/docs/reference/union.md
[types]: https://github.com/6over3/bebop/blob/03a2a761d7ea96afdb5bcd8885d0be15cc888e8a/docs/src/content/docs/reference/types.mdx
[runtime]: https://github.com/6over3/bebop/blob/03a2a761d7ea96afdb5bcd8885d0be15cc888e8a/Runtime/TypeScript/index.ts
[generator]: https://github.com/6over3/bebop/blob/03a2a761d7ea96afdb5bcd8885d0be15cc888e8a/Core/Generators/TypeScript/TypeScriptGenerator.cs
[binary-schema]: https://github.com/6over3/bebop/blob/03a2a761d7ea96afdb5bcd8885d0be15cc888e8a/docs/src/content/docs/reference/binary-schema.mdx
[binary-runtime]: https://github.com/6over3/bebop/blob/03a2a761d7ea96afdb5bcd8885d0be15cc888e8a/Runtime/TypeScript/binary.ts
[benchmarks]: https://github.com/6over3/bebop/tree/03a2a761d7ea96afdb5bcd8885d0be15cc888e8a/Laboratory/TypeScript/benchmark
[flat-draft]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
[host]: https://github.com/6over3/bebop/blob/03a2a761d7ea96afdb5bcd8885d0be15cc888e8a/Core/CompilerHost.cs
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[serde]: ../serde/index.md
[cas]: ../content-addressing/index.md
