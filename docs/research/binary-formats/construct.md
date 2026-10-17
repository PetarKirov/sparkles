# Construct (Python)

A host-language binary-description DSL that composes parsers and builders, including contextual counts, tagged choices, and seek-and-return pointers.

| Field         | Value                                                                                      |
| ------------- | ------------------------------------------------------------------------------------------ |
| Language      | Python schema objects and expressions                                                      |
| License       | MIT ([license][license])                                                                   |
| Repository    | [`construct/construct` at `28c6e5779f2b76d55474914607291a3821502000`][repo]                |
| Documentation | [Core implementation/docstrings][core], [compilation guide][compilation]                   |
| Category      | Host-language combinator DSL for existing binary formats                                   |
| Scope         | Interpreted parsing/building; optional compiled-Python path with documented safety caveats |

## Overview

### What it solves

[Construct][repo] replaces imperative stream manipulation with a composition
of reusable field descriptions. A `Struct` orders fields, `Array` repeats a
description, `Switch` dispatches on context, and `Pointer` visits an out-of-line
location. The same description can parse bytes or build them from Python
objects, so representation facts need not be written twice.

This is a host-language schema but **not host-type derivation**. A Python
`Struct` description is an executable object graph; a Python `Container`
returned by parsing does not determine its wire layout. Compare the distinct
host-declaration/derive approaches in the [Serde catalog][serde].

### Design philosophy

The [README][repo] states:

> Construct is a powerful **declarative** and **symmetrical** parser and builder for binary data.

“Symmetrical” describes reuse of combinators in both directions, not a claim
that every description is invertible or that unknown/padding bytes survive
round trips. Explicit choices such as `Rebuild`, adapters, defaults, and
unrepresented gaps can intentionally produce a normalized result.

## How it works

This complete schema input describes a count, a 16-bit absolute offset, and
big-endian elements at the offset:

```python
from construct import Array, Int16ub, Pointer, Struct, this

table = Struct(
    "count" / Int16ub,
    "offset" / Int16ub,
    "values" / Pointer(this.offset, Array(this.count, Int16ub)),
)
```

Field names enter a context used by `this` expressions. `Pointer` saves the
stream position, seeks, invokes its child, and restores the position. Its
declared sequential size is zero even though it reads/writes target bytes
([`Pointer` implementation][core]). This is exactly why physical extent and
sequential consumption must not be conflated.

### Schema source of truth

The composition of Construct objects is authoritative. Python code can
construct descriptions dynamically and use lambdas for context-dependent
behavior. This avoids a separate IDL and compiler frontend but also makes
schema loading ordinary trusted Python execution, not safe data-file loading.

`Struct` parses named values into a `Container` and constructs nested contexts;
the parent context is available through `_`. `Rebuild` computes a field during
building, such as deriving a sibling count from an array. These are runtime
relationships rather than a compile-time proof over host aggregate offsets
([core][core]).

### Wire encoding

No universal wire encoding exists. `Int16ub`, `Int32ul`, bitwise descriptions,
byte strings, alignment/padding, and adapters specify an existing format.
Names belong to the schema and parsed container unless the description
explicitly writes them as data.

The example's first four bytes are two unsigned big-endian 16-bit leaves.
The pointer then visits the position named by the second leaf; it is **not**
implicitly relative to that leaf or the record. Different offset widths and
bases are combinations of integer fields and position expressions, not a
dedicated typed pointer primitive.

### Access model

Default parsing materializes Python values. `Pointer` is eager unless wrapped
in a lazy combinator. `Lazy` returns a callable that saves sufficient stream
state to parse later; `LazyStruct`/`LazyArray` supply other deferred access
forms ([core][core]). None of these is a borrowed `ref const(T)` into mapped
storage.

The inspected `Lazy` implementation seeks back and parses on each callable
evaluation; do not generalize Kaitai's cached-instance behavior to it. The
underlying stream must stay alive and seekable. Delayed validation also means
“constructed a lazy result” is weaker than “validated its referenced bytes.”

### Variable-length and optional data

`Array(this.count, subcon)` uses a sibling count. `Bytes`, `Prefixed`,
`GreedyRange`, `If`, `Optional`, and `Switch` cover sizes, framing, and branches.
`Rebuild` derives output metadata rather than requiring callers to maintain
both an array and an independent count. Adapters can map physical fields to
more convenient logical values ([core][core]).

`Optional` is speculative parsing with fallback, not necessarily an explicit
presence flag. `GreedyRange` also has termination/failure semantics unlike a
fixed counted array. A security-sensitive schema should decide which failures
mean legitimate absence and which require rejection, then use explicit
conditions, checks, and termination requirements where appropriate.

### Evolution and compatibility

Version fields, `If` predicates, and tagged `Switch` branches can describe
several revisions. Compatibility belongs to the described format: Construct
does not introduce universal stable field IDs or unknown-field lengths.
Default branches must specify whether unknown data is rejected, skipped,
or retained.

A parser accepting trailing bytes is not automatically forward compatible.
The schema must know which region those bytes belong to and whether later
fields/offsets depend on them. Explicit framing and independent old/new
fixtures are more meaningful evidence than a successful same-schema round trip.

### Determinism and canonical form

Not a library-wide guarantee. Python lambdas may depend on ambient state;
adapters may normalize values; pointer writes may overlap; source padding may
not be retained. Reusing one schema in both directions does not select a
canonical layout of a graph.

The observed probe below writes zeros into the gap before an out-of-line
array. That is behavior for this description and output stream, not a rule
that every Construct serializer canonicalizes padding. A deterministic cache
format must constrain ordering, placement, gap contents, and value normalization
explicitly.

### Merkleization and content addressing

Not supplied. `Pointer` identifies a stream position, not a digest or a
content-addressed child. `Checksum` can verify a described checksum field,
but choosing a cryptographic hash and graph identity is application policy
([core][core]; [content-addressing catalog][content-addressing]).

An application can build a Merkle format with Construct, just as it can build
an ordinary file. The schema needs explicit digest-domain rules and a
canonical node encoding; combinator composition alone does not make
independently addressable subobjects.

### Hostile-input safety

The interpreted [`stream_read`][core] rejects negative lengths and short
reads with `StreamError`. `Check` supports cross-field invariants. This is
useful runtime checking, but Python allocations, attacker-controlled counts,
seeks, recursion, and user callbacks still need budgets.

The [compilation guide][compilation] carries an unusually important warning:

> Since some checks are ommited by generated code, you should not use it to parse corrupted or untrusted data.

The spelling is upstream's. Therefore interpreted and compiled modes must not
share an unqualified hostile-input safety assessment. The guide also documents
missing path information and unsupported context features; a performance
optimization can change both diagnostics and accepted schema behavior.

No product-specific incident was established here. The primary warning is
already enough to reject a claim that optional compilation preserves every
security property. The [Flat draft's][flat] bounded-error-value contract is
substantially stronger than Construct's exception-based combinator interface.

### Describing foreign formats

Construct directly expresses OpenType-like big-endian leaves, sibling counts,
and tagged variants. An ancestor-relative offset can be modeled by recording
the ancestor start with `Tell` and computing `base + offset` through context;
using `Pointer(offset, ...)` alone would instead use the stream's absolute
coordinate system. A new `relativeOffset` option exists at the inspected pin,
but current-position-relative is still not named-ancestor-relative.

For a grandparent-relative `Offset16`/`Offset32`, the schema must retain or
pass the correct base and choose the correct stream. A tagged payload uses
`Switch` or explicit conditions; a zero offset meaning null needs its own
rule. Context navigation is expressive but does not statically prove that
all enclosing paths supply the required base or that every target fits the
intended region.

This demonstrates why “host language versus separate IDL” is not the decisive
expressiveness axis. Python combinators can describe physical dependencies
that CDDL cannot; a D declaration approach can additionally use compile-time
introspection, provided it defines equally explicit offset/count semantics.

### Implementation and performance evidence

The following **actually executed** against the pinned checkout, using Python
3.11.15 and `PYTHONPATH` pointing at the clone (no installed package assumed):

```bash
PYTHONPATH="$REPOS/construct/construct" python3 -c 'from construct import *; s=Struct("count"/Int16ub,"offset"/Int16ub,"values"/Pointer(this.offset,Array(this.count,Int16ub))); b=s.build(dict(count=2,offset=8,values=[0x1234,0x5678])); print(b.hex(" ")); print(list(s.parse(b).values))'
```

```text
00 02 00 08 00 00 00 00 12 34 56 78
[4660, 22136]
```

The pointer target begins at byte eight; the header consumes four bytes and
the gap is four zeros. The result confirms physical placement and values,
not throughput, global safety, or a generic graph builder. No benchmark was
run; the [compiler guide's timing example][compilation] is upstream evidence,
not a measurement reproduced for this schema. No maintained D port was verified.

This portable D probe checks the **coordinate/bounds invariant**, not Construct's
implementation: an ancestor at byte two plus offset six reaches the same target.
It also rejects overflowing/out-of-region inputs before addition or indexing.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "binary_ancestor_offset_probe"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : writeln;

private bool read16(in ubyte[] b, ulong base, ushort offset, out ushort value)
    @safe pure nothrow @nogc
{
    if (base > b.length || offset > b.length - base)
        return false;
    const at = cast(size_t)(base + offset);
    if (b.length - at < 2)
        return false;
    value = cast(ushort)((cast(uint)b[at] << 8) | b[at + 1]);
    return true;
}

void main() @safe
{
    immutable ubyte[] bytes = [0, 2, 0, 8, 0, 0, 0, 0, 0x12, 0x34, 0x56, 0x78];
    ushort value;
    assert(read16(bytes, 2, 6, value) && value == 4660);
    assert(!read16(bytes, ulong.max, 1, value));
    assert(!read16(bytes, 2, ushort.max, value));
    assert(!read16(bytes, 2, 10, value));
    writeln("ancestor + offset: 4660; invalid ranges rejected");
}
```

```ansi
ancestor + offset: 4660; invalid ranges rejected
```

## Strengths

- Direct existing-layout vocabulary without a separate schema compiler.
- Contextual counts, seeks, variants, adapters, and computed output metadata.
- One composition can parse and build, making small reference oracles easy.
- Implementation docstrings expose exact stream and error semantics.

## Weaknesses

- Dynamic Python object processing is not allocation-free borrowed access.
- Arbitrary callbacks and context coupling limit static guarantees.
- Compilation explicitly weakens checks for untrusted input.
- Pointer positioning does not solve safe graph placement or global budgets.

## Key design decisions and trade-offs

| Decision                      | Rationale                                  | Trade-off                                         |
| ----------------------------- | ------------------------------------------ | ------------------------------------------------- |
| Schema objects in Python      | Reuse language, callbacks, and composition | Trusted executable schema and runtime checks      |
| Symmetric combinators         | Share representation knowledge             | Not every schema preserves original bytes         |
| Context-dependent expressions | Describe sibling counts and ancestor bases | Dependencies can fail only at runtime             |
| Pointer save/seek/restore     | Read and write indexed foreign layouts     | Seekable stream and explicit coordinate policy    |
| Optional compiled Python      | Reduce interpreter dispatch overhead       | Documented loss of checks and diagnostic features |

## Sources

- [README][repo]: goals and feature inventory.
- [`construct/core.py`][core]: `Struct`, `Array`, `Pointer`, `Lazy`, `Rebuild`, checks.
- [Compilation guide][compilation]: performance intent and hostile-input warning.
- [Flat draft §§4–6][flat]: bounded-view comparison target.

<!-- References -->

[repo]: https://github.com/construct/construct/blob/28c6e5779f2b76d55474914607291a3821502000/README.rst
[license]: https://github.com/construct/construct/blob/28c6e5779f2b76d55474914607291a3821502000/LICENSE
[core]: https://github.com/construct/construct/blob/28c6e5779f2b76d55474914607291a3821502000/construct/core.py
[compilation]: https://github.com/construct/construct/blob/28c6e5779f2b76d55474914607291a3821502000/docs/compilation.rst
[flat]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
[serde]: ../serde/serde.md
[content-addressing]: ../content-addressing/concepts.md
