# CDDL (IETF / Rust tooling)

A compact language for specifying acceptable CBOR and JSON values, not an instruction set for arranging arbitrary binary fields.

| Field          | Value                                                                |
| -------------- | -------------------------------------------------------------------- |
| Language       | CDDL notation; representative validator in Rust                      |
| License        | RFC text: IETF Trust terms; `cddl-rs`: MIT ([license][license])      |
| Repository     | [`anweiss/cddl` at `48fbd5ca0aca97bc9046fff785b68397c0cf6fff`][repo] |
| Documentation  | [RFC 8610][rfc], [RFC 9165][controls], [RFC 8949][cbor]              |
| Category       | Separate data-model schema and validation language                   |
| Wire authority | CBOR or JSON specification and application profile, not CDDL alone   |

## Overview

### What it solves

[CDDL][rfc] gives protocol authors a readable, machine-checkable description
of allowed data structures. A CBOR protocol can specify literal integer map
keys, tagged byte strings, array tuples, repeated groups, and alternatives
without writing those constraints as scattered prose. JSON reuse is useful,
but its smaller value universe cannot represent every CBOR distinction
([RFC 8610 Appendix E][rfc]).

This page covers the schema rather than duplicating the [Serde catalog][serde].
CDDL is an external description that a validator or generator consumes;
Serde's traits connect host values to format implementations. They can coexist
without either being the other's binary layout specification.

### Design philosophy

[RFC 8610 §2.2.3][rfc] draws the crucial boundary verbatim:

> CDDL does not provide any language means to restrict the choice of
> serialization variants.

For example, `float16` means a value representable in half precision, not an
order to emit exactly a two-byte floating-point payload. Treating CDDL as a
byte grammar would contradict this rule. Its subject is the accepted value
set; byte identity belongs to a CBOR encoding profile.

## How it works

An illustrative schema uses integer keys and a discriminated array alternative:

```text
message = {
    0: uint,
    ? 1: tstr,
    2: ([0, bstr] / [1, uint]),
}
```

The first rule is the root type. A group can be reused in an array or map:
array entry labels document positions, whereas map labels become actual
keys. `/` chooses types; `//` chooses groups. This composition model avoids a
separate language feature for every combination of table, tuple, and object
([RFC 8610 §§2.1–2.2][rfc]).

### Schema source of truth

The CDDL document specifies an accepted set of values independently of host
class names. [RFC 8610 §§4.1–4.3][rfc] describes human guidance, automatic
checking, and data-analysis use; it does not mandate a particular generated
class layout or object ownership strategy.

The inspected [`cddl-rs` repository][repo] implements parsing, validators, and
type generation. Its AST/validator boundary is visible in
[`src/validator/cbor.rs`][validator]. A generated Rust type is a tool result,
not evidence that the notation specifies Rust memory layout.

### Wire encoding

CBOR major types supply integer, byte/text string, array, map, tag, and simple
value encodings ([RFC 8949 §3][cbor]). JSON has its own textual encoding.
CDDL adds constraints over those values; it introduces no field-offset table,
endianness switch, alignment declaration, or numeric relocation primitive.

For `pair = [uint, uint]`, CBOR bytes `82 01 02` represent `[1, 2]` using a
definite array. `9f 01 02 ff` is an indefinite-array representation of the
same value. [RFC 8610 §3.2][rfc] explicitly disconnects CDDL occurrence bounds
from definite/indefinite encoding. These are spec-derived examples, not a
claimed run of a CDDL validator.

### Access model

CDDL does not choose eager, incremental, borrowed, or lazy decoding.
Implementations may validate decoded values or combine checking with decoding.
The inspected [CBOR validator][validator] is concrete implementation evidence;
the language's syntax alone is not evidence for zero-copy parsing.

CBOR's sequential framing means locating a late array member requires walking
preceding items unless a separate index exists. Map semantics do not make a
serialized map a fixed-offset struct. A schema-generated convenience getter
and a direct bounded read from caller-owned bytes are different capabilities.

### Variable-length and optional data

`?`, `*`, `+`, and `n*m` govern occurrences of group entries. Ranges constrain
numeric values; `.size` constrains lengths or appropriate numeric sizes;
`.bits` constrains allowed set bits. `.cbor` and `.cborseq` constrain CBOR
embedded in a byte string ([RFC 8610 §§3.2, 3.8][rfc]).

Optional map entries are distinct from entries whose value is `null`. A
count field plus a sibling vector is also distinct from a length-prefixed
wire object: baseline CDDL does not turn one instance member into an arbitrary
dependent expression over another member. Additional controls, such as
[RFC 9165][controls], extend expressions over schema values; they are not a
general stream-position or ancestor-offset language.

### Evolution and compatibility

Maps can reserve an extension surface using a wildcard entry such as
`* tstr => any`. Closed maps reject uncovered members. `/=` and `//=` extend
type/group choices, and sockets/plugs identify extensible portions of a schema
([RFC 8610 §§2.2.2, 3.5.1, 3.9][rfc]). Those are schema composition mechanisms,
not an automatic protocol version-negotiation system.

The **cut** in map matching is a consequential detail. With
`? "known" => int, * tstr => any`, a malformed value under `known` may match
the wildcard. The colon form `? known: int` includes cut semantics and locks
in the key match, preventing that fallback ([RFC 8610 §3.5.4][rfc]).
Compatibility policy can otherwise accidentally weaken validation.

### Determinism and canonical form

Not supplied by CDDL. [RFC 8949 §4.2][cbor] defines deterministic CBOR
requirements, including preferred representations and map key ordering.
A protocol must select those requirements and any additional normalization
rules independently of whether its values validate against CDDL.

Numeric representability is particularly easy to mistake for encoding width.
Likewise `.size` on a byte string constrains the string's contents length,
not the exact length-header spelling. A canonicalization test needs to inspect
bytes; a value-level schema validator cannot necessarily recover distinctions
discarded by its decoder.

### Merkleization and content addressing

CDDL specifies neither hashing nor a Merkle topology. A schema may describe a
digest byte string or a tagged link value, but the application still defines
the digest algorithm, interpretation, serialization profile, and graph edges.
Compare the [content-addressing catalog][content-addressing] rather than
equating “machine-checkable schema” with “stable content address.”

Even a fully deterministic CBOR node is only a byte-stable node. Independently
addressable children and verification of those child links require an explicit
graph representation that CDDL can document but does not create.

### Hostile-input safety

Schema validation follows basic wire decoding and does not replace it.
[RFC 8949 §10][cbor] discusses nesting, size, duplicate keys, and other decoder
hazards; [RFC 8610 §5][rfc] warns that schema expressiveness does not resolve
all security validation. Put depth, input-length, allocation, and work limits
on the decoder before trusting a value tree.

Ambiguous map matching is another layer. [RFC 8610 §3.5.3][rfc] gives a
pathological case and explicitly urges authors not to write such schemas.
Precise keys, discriminants, cuts, and bounded alternatives are preferable to
assuming every accepted schema has cheap deterministic validation.

No product-specific vulnerability was established in the inspected validator.
That is a limitation of this review, not a clean security record or a reason
to omit fuzzing at the decoder/validator boundary.

### Describing foreign formats

Not a suitable language for OpenType layouts. It can describe a **logical
projection** containing a count, an offset number, and glyph data, but cannot
declare that an existing big-endian `Offset16` is relative to an ancestor
table, or that a tagged payload begins at a particular byte position.

Putting the font in `bstr` preserves its original bytes but makes its internal
layout opaque. `.bits` can constrain a CBOR integer's value; it does not place
OpenType flag bits inside a specified physical 16-bit word. A separate IDL
is not intrinsically more expressive than host annotations: what matters is
whether its primitives describe value structure or physical storage.
The [Flat draft §§5–6][flat] is explicitly about the latter, and remains a
proposed contract rather than evidence of a delivered D implementation.

### Implementation and performance evidence

The [pinned `cddl-rs` README][repo] distinguishes `no_std` lexing/parsing from
validation and records support for RFC 8610, RFC 9165, RFC 9682, and RFC 9741.
Its list also names draft features; draft controls should not be silently
presented as baseline standardized CDDL.

The [validator source][validator] was inspected; no compiler or validator probe
was executed. The two CBOR array encodings above are grounded in RFC 8949's
wire rules, not generated-tool observations. No measured throughput, bounded
memory claim, or verified D implementation follows from this review.

For an independent wire oracle, [RFC 8949 Appendix A][cbor] publishes exact
vectors, including `[1, 2, 3]` as `83 01 02 03`. A useful test suite should
separate these wire vectors from CDDL accepted/rejected-value cases and
deterministic-profile rejection cases.

This dependency-free D sample maintains the RFC vector's small definite-array
count invariant. It is **not** a CBOR decoder or CDDL validator, and deliberately
handles only these one-octet integer elements.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "binary_cddl_array_probe"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : writeln;

void main() @safe
{
    immutable ubyte[] bytes = [0x83, 1, 2, 3];
    const count = bytes[0] & 0x1f;
    assert((bytes[0] >> 5) == 4 && count == 3);
    assert(bytes.length == 1 + count);
    uint sum;
    foreach (value; bytes[1 .. $])
        sum += value;
    assert(sum == 6);
    writeln("CBOR fixture: 3 elements, 4 octets, sum=6");
}
```

```ansi
CBOR fixture: 3 elements, 4 octets, sum=6
```

## Strengths

- Concise, reusable specification of CBOR/JSON protocol value sets.
- Literal keys and explicit variants are convenient for interoperable messages.
- Extension points and cuts make permissiveness reviewable.
- Independent of one host language or codec implementation.

## Weaknesses

- Does not specify physical layouts, access guarantees, or canonical bytes.
- Baseline notation is not a general dependent instance-expression language.
- A decoded tree may hide wire distinctions that security profiles must reject.
- Tool support and newer/draft controls require explicit version pinning.

## Key design decisions and trade-offs

| Decision                                | Rationale                                    | Trade-off                                        |
| --------------------------------------- | -------------------------------------------- | ------------------------------------------------ |
| Constrain data-model values             | Reuse notation across CBOR and JSON          | Cannot dictate arbitrary binary layout           |
| Reusable groups                         | Compose tuples, vectors, structs, and tables | Labels have different wire roles in arrays/maps  |
| Open maps only when declared            | Make extension policy explicit               | Authors must choose future key domains           |
| Colon implies cut                       | Prevent malformed known keys falling through | Matching semantics need more than visual reading |
| Separate deterministic encoding profile | Avoid coupling schema to one serializer      | Validation alone cannot establish hash identity  |

## Sources

- [RFC 8610 §§2–5, Appendices B–E][rfc]: normative notation and matching.
- [RFC 9165][controls]: additional standardized controls.
- [RFC 8949 §§3–4, §10, Appendix A][cbor]: bytes, determinism, security, vectors.
- [`cddl-rs` README and CBOR validator][repo]: inspected implementation.

<!-- References -->

[rfc]: https://www.rfc-editor.org/rfc/rfc8610.html
[controls]: https://www.rfc-editor.org/rfc/rfc9165.html
[cbor]: https://www.rfc-editor.org/rfc/rfc8949.html
[repo]: https://github.com/anweiss/cddl/blob/48fbd5ca0aca97bc9046fff785b68397c0cf6fff/README.md
[license]: https://github.com/anweiss/cddl/blob/48fbd5ca0aca97bc9046fff785b68397c0cf6fff/LICENSE
[validator]: https://github.com/anweiss/cddl/blob/48fbd5ca0aca97bc9046fff785b68397c0cf6fff/src/validator/cbor.rs
[serde]: ../serde/serde.md
[content-addressing]: ../content-addressing/concepts.md
[flat]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
