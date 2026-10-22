# Kaitai Struct (YAML / generated multi-language parsers)

A separate binary-description language that generates object-oriented readers for existing files, with explicit stream-relative positions and lazy out-of-line instances.

| Field           | Value                                                                                                                            |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Language        | `.ksy` YAML plus expressions; compiler in Scala                                                                                  |
| License         | Compiler GPL-3.0-or-later; generated output is outside that license's scope ([licensing][repo]); formats have their own licenses |
| Repository      | [Compiler at `fd2594257834241455f27121ae1adf296bcf09b9`][repo]                                                                   |
| Documentation   | [User guide source][guide]; [serialization guide source][writing]                                                                |
| Category        | Separate descriptive IDL; generated stream parsers; selected writer backends                                                     |
| Additional pins | Docs `43db335bbdd80ef3ad0bffa55e58de0b7037490b`; formats `6739687e6af86bb1326953dc6cef7f8e716c10ec`                              |

## Overview

### What it solves

[Kaitai Struct][repo] centralizes binary-layout knowledge that otherwise gets
repeated in hand-written parsers. One `.ksy` file states primitive widths,
endianness, sequence order, repetition, conditions, variant selection, and
out-of-line data. Compiler backends generate readers in several languages.
The result is a host API over parsed data, not a requirement that a format's
producer adopt a new encoding.

This is directly relevant to [Flat's foreign-format acceptance set][flat].
Both need explicit offsets, counts, and variants; their access contracts
are different. Kaitai normally reads fields into generated objects; Flat's
draft instead proposes borrowed bounded leaf access and a separately proved
host-native fast path.

### Design philosophy

The [compiler README][repo] describes the single-description principle:

> The main idea is that a particular format is described in Kaitai
> Struct language (`.ksy` files) only once and then can be compiled with
> this compiler into source files in one of the supported programming
> languages.

The separate IDL purchases multi-language reuse and tooling, including format
visualization. It does not claim that generated host fields themselves define
the wire representation. This is the opposite direction from deriving a
codec from existing host declarations; see the [Serde catalog][serde].

## How it works

An illustrative description combines a sibling count and an absolute offset:

```yaml
meta:
  id: table
  endian: be
seq:
  - id: count
    type: u2
  - id: offset
    type: u2
instances:
  entries:
    pos: offset
    type: u2
    repeat: expr
    repeat-expr: count
```

`seq` fields are parsed in order. `instances` can parse at another position
and are lazy by default. In this fragment `pos` is relative to the current
stream's beginning, **not** the byte where `offset` itself was read
([user guide, “Instances: data beyond the sequence”][guide]).

### Schema source of truth

The `.ksy` schema owns the layout. It supplies `meta`, `seq`, nested `types`,
`instances`, and parameters; host objects are generated products. The
[compiler's import/precompile pipeline][pipeline] loads dependencies and
resolves the schema before invoking a backend.

Parameters make context dependencies explicit across type boundaries, while
`_parent` and `_root` provide references through the generated object graph.
This is expressive, but it is not the same as a statically checked
“nearest ancestor of named type” offset-base rule. A reusable type must have
the right enclosing context or receive suitable parameters.

### Wire encoding

There is no Kaitai wire format. `u2`, `u4`, endian suffixes/defaults, bit
fields, `contents`, and size expressions describe existing bytes. A file can
contain different orders or encodings in different regions. The [user guide][guide]
defines the primitives and expression language.

The upstream [`font/ttf.ksy`][ttf] is concrete evidence: `endian: be`, a
`u2` table count, `u4` directory offsets and lengths, and table dispatch by
the four-character tag. It neither rewrites the font as a Kaitai container
nor requires changing the producer. Its `meta.license` is MIT, independent
of the compiler's GPL license.

### Access model

`seq` parsing materializes fields immediately; an instance getter parses on
first use and normally caches its result. The [guide][guide] explicitly
describes loading into RAM and reusing that cached copy. Lazy does not mean
borrowed or allocation-free.

The [Python backend][python] emits seek/restore operations and cache checks.
Offset navigation needs a seekable/tellable stream, or a compatible buffered
implementation. It is not the same capability as a monotonic network stream
reader. Deferred access also means malformed out-of-line data may be detected
later than root construction.

### Variable-length and optional data

`repeat: expr`, `repeat: eos`, and `repeat: until` describe repetitions;
`size` bounds byte regions; `if` controls presence. Expressions can refer to
earlier values or explicit context. `switch-on` selects a type by a tag, with
a default branch where the schema provides one ([guide][guide]).

A sized user type introduces a substream with its own origin and boundary.
This can conveniently make offsets table-relative, but it can also make
legitimate shared targets unreachable if their base/region is modeled
incorrectly. The stream selected by `io` and the origin used by `pos` must be
reviewed together; the integer's width alone says nothing about its base.

### Evolution and compatibility

Conditions and switches can describe several existing format versions.
Kaitai supplies no universal field-ID evolution convention: an old parser's
ability to skip a new variant depends on the foreign format's framing and
the schema's fallback handling.

Keeping an unknown payload as a sized byte string may preserve it for later
interpretation. Omitting a size can instead make an unknown branch consume
the wrong extent. The schema author must choose the unknown-case behavior;
generation cannot infer protocol semantics from an unrecognized tag.

### Determinism and canonical form

Not defined globally. The schema recognizes a representation chosen by the
foreign format; it does not establish canonical padding, record order,
floating-point normalization, or placement of shared data. A parser may
discard bytes that have no corresponding field.

Current upstream is **not parser-only**. The [serialization guide][writing]
states writing is available since v0.11 for Java and Python. Its procedure
includes creating objects, populating properties, checking consistency with
`_check`, and calling `_write`. Target support is intentionally narrower than
parser support; do not generalize writer support to every backend.

### Merkleization and content addressing

Not provided. Neither `pos` nor an instance cache is a content-addressed
reference. They identify positions and materialized results, not digests.
A description may parse a Merkle file format, but that file's hash rules are
external to Kaitai; see the [content-addressing catalog][content-addressing].

Writing support does not automatically make the output canonical. Choosing
physical target placement, resolving aliasing/shared regions, and normalizing
padding are distinct from writing the fields at positions supplied to the
generated writer. Byte-preserving editing needs dedicated fixtures.

### Hostile-input safety

`contents` and `valid` introduce explicit checks; sized substreams constrain
where child readers can read. The [guide][guide] and [Python backend][python]
show validation operations, but do not establish a universal allocation,
depth, or traversal budget across all runtime languages.

An attacker-controlled count can request many objects; offset cycles or
repeated lazy getters can create excessive work or retention. Bounding a
substream prevents one class of out-of-bounds read while leaving those
resource threats. Validate counts against both format limits and available
bytes before constructing large collections.

Schema compilation and runtime parsing are separate authority boundaries.
Generated code is only as defensive as the chosen backend/runtime and schema;
the existence of many targets is not a cross-target safety proof. No
product-specific advisory was verified in this review.

### Describing foreign formats

The upstream [TrueType schema][ttf] demonstrates the precise pattern of
interest: directory entries read `offset`/`length`, then `value` uses
`io: _root._io`, `pos: offset`, `size: length`, and a switch on `tag`.
Inside `cmap`, a subtable header uses `io: _parent._io` and
`pos: subtable_offset`, expressing a different ancestor-relative origin.

Sibling counts appear as `repeat-expr: number_of_encoding_tables`, and
`cmap` dispatches on a `u2` format discriminator. These examples establish
offset/count/variant vocabulary rather than a hypothetical capability inferred
from YAML. `u2`/`u4` can carry 16-/32-bit offsets; null-zero behavior still
needs an explicit condition when the foreign format defines it.

The schema is **not a complete OpenType conformance oracle**: the inspected
file contains a `TODO` in a `cmap` branch and handles only selected formats.
Its success at describing TrueType does not establish coverage of every
variation table or graph-safety requirement in [Flat §6][flat].

### Implementation and performance evidence

The source review uses the [compiler pipeline][pipeline], [Python generation][python],
and [TrueType schema][ttf]. A separate **executed probe** used the released npm
compiler `0.11.0` (not the newer compiler checkout) and the [Python runtime][runtime]
at `adfafda2d2f16074f49e113e428af5a3c10338b2`. The following compiles exactly
the introductory YAML's schema, supplied as its equivalent object:

```bash
npm install --prefix /tmp/opencode/kaitai-probe --no-save --ignore-scripts kaitai-struct-compiler@0.11.0
node -e 'const fs=require("fs"),c=require("/tmp/opencode/kaitai-probe/node_modules/kaitai-struct-compiler"); c.compile("python",{meta:{id:"table",endian:"be"},seq:[{id:"count",type:"u2"},{id:"offset",type:"u2"}],instances:{entries:{pos:"offset",type:"u2",repeat:"expr","repeat-expr":"count"}}},null,false).then(f=>{fs.writeFileSync("/tmp/opencode/kaitai-probe/table.py",f["table.py"]);console.log(c.version)});'
PYTHONPATH="/tmp/opencode/kaitai-probe:$REPOS/kaitai-io/kaitai_struct_python_runtime" python3 -c 'from table import Table; b=bytes.fromhex("00 02 00 08 00 00 00 00 12 34 56 78"); t=Table.from_bytes(b); print(b.hex(" ")); print(t.count,t.offset,t._io.pos()); print(t.entries,t._io.pos())'
```

Observed compiler version and decoder output:

```text
0.11.0
00 02 00 08 00 00 00 00 12 34 56 78
2 8 4
[4660, 22136] 4
```

The lazy instance reads the target at byte eight and restores the header
cursor to byte four. These bytes were supplied independently, not generated
by a Kaitai writer. This demonstrates positioning and restoration, not
ancestor-relative bounds, every truncation case, or throughput; no benchmark
was run. Reproduction requires the runtime clone at the cited revision.

This independent D sample checks that the literal sibling count and offset
describe four bytes at byte eight. It is **not** Kaitai execution or a complete
offset parser; the actual generated-reader observation is above.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "binary_kaitai_extent_probe"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : writeln;

void main() @safe
{
    immutable ubyte[] bytes = [0, 2, 0, 8, 0, 0, 0, 0, 0x12, 0x34, 0x56, 0x78];
    const count = (cast(uint)bytes[0] << 8) | bytes[1];
    const offset = (cast(uint)bytes[2] << 8) | bytes[3];
    assert(count == 2 && offset == 8);
    assert(offset <= bytes.length && count <= (bytes.length - offset) / 2);
    assert(offset + 2 * count == bytes.length);
    writeln("Kaitai fixture: count=2 offset=8 extent=4 total=12");
}
```

```ansi
Kaitai fixture: count=2 offset=8 extent=4 total=12
```

The [serialization guide][writing] notes fixed-length output streams and the
need to calculate sizes in the application. That is a limitation for a general
arena builder: schema-derived field writes do not by themselves solve graph
placement and offset fix-ups.

No D backend appears among the compiler backend files inspected at this pin,
and no maintained D runtime/binding was verified. This is a scoped finding,
not proof that no experimental or third-party port exists. Generated C++ or
another backend is not automatically a usable D binding.

## Strengths

- Existing-byte descriptions with explicit width, order, counts, and variants.
- Lazy seek-and-return instances suit large indexed files.
- One external schema can generate several language APIs and tooling views.
- Real upstream TrueType descriptions expose offset-origin decisions clearly.

## Weaknesses

- Generated object access is not a borrowed in-place contract.
- Safety/performance differ by backend/runtime; global budgets are not implicit.
- Writer support is narrower and does not eliminate placement/size work.
- Parent-context coupling and partial format schemas require careful review.

## Key design decisions and trade-offs

| Decision                                 | Rationale                               | Trade-off                                           |
| ---------------------------------------- | --------------------------------------- | --------------------------------------------------- |
| Separate `.ksy` source                   | Share layout and tools across languages | Generation step and independent expression language |
| Sequential fields plus lazy instances    | Handle both headers and indexed bodies  | Requires stream lifetime and often seekability      |
| Stream-relative `pos` with explicit `io` | Reuse table-local coordinate systems    | Wrong origin can silently select wrong bytes        |
| Materialize/cache objects                | Convenient repeated field access        | Allocations and delayed validation                  |
| Selected read/write backends             | Extend a mature parsing architecture    | Not uniform serializer capability across targets    |

## Sources

- [Compiler README][repo]: purpose and licensing boundary.
- [User guide][guide]: instances, parameters, validation, substreams.
- [Serialization guide][writing]: version/target scope and output constraints.
- [`font/ttf.ksy`][ttf]: actual nested stream bases and partial coverage.
- [Python backend][python]: generated seek/cache/validation operations.

<!-- References -->

[repo]: https://github.com/kaitai-io/kaitai_struct_compiler/blob/fd2594257834241455f27121ae1adf296bcf09b9/README.md
[pipeline]: https://github.com/kaitai-io/kaitai_struct_compiler/blob/fd2594257834241455f27121ae1adf296bcf09b9/shared/src/main/scala/io/kaitai/struct/Main.scala
[python]: https://github.com/kaitai-io/kaitai_struct_compiler/blob/fd2594257834241455f27121ae1adf296bcf09b9/shared/src/main/scala/io/kaitai/struct/languages/PythonCompiler.scala
[guide]: https://github.com/kaitai-io/kaitai_struct_doc/blob/43db335bbdd80ef3ad0bffa55e58de0b7037490b/user_guide.adoc
[writing]: https://github.com/kaitai-io/kaitai_struct_doc/blob/43db335bbdd80ef3ad0bffa55e58de0b7037490b/serialization.adoc
[ttf]: https://github.com/kaitai-io/kaitai_struct_formats/blob/6739687e6af86bb1326953dc6cef7f8e716c10ec/font/ttf.ksy
[runtime]: https://github.com/kaitai-io/kaitai_struct_python_runtime/blob/adfafda2d2f16074f49e113e428af5a3c10338b2/kaitaistruct.py
[flat]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
[serde]: ../serde/serde.md
[content-addressing]: ../content-addressing/concepts.md
