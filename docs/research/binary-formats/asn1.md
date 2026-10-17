# ASN.1: BER, DER, and PER (standards / C)

A language-independent value schema with multiple transfer syntaxes: tagged extensibility in BER, a distinguished representation in DER, and constraint-driven bit packing in PER.

| Field         | Value                                                                               |
| ------------- | ----------------------------------------------------------------------------------- |
| Language      | ASN.1 modules; surveyed implementation generates C                                  |
| License       | ITU/ISO standards terms; `asn1c` is BSD-2-Clause ([license][license])               |
| Repository    | [`vlm/asn1c` at `8a274c3f99761f249b6c205e1c89be1b1cb7c669`][repo]                   |
| Documentation | [X.690 (2021)][x690], [X.691 (2021)][x691], [RFC 6025][translation]                 |
| Category      | Separate IDL; prescriptive transfer syntaxes; generated stream codecs               |
| Scope         | BER/DER and aligned/unaligned PER are distinct encodings, not interchangeable modes |

## Overview

### What it solves

[ASN.1][translation] separates the meaning of a message from its transfer syntax
and the implementation language's ABI. A `SEQUENCE` can become a generated C
structure, but its transmitted form follows an encoding rule, not `sizeof` or
the compiler's padding. Certificates, cryptographic messages, and mobile
protocols use different portions of this family; interoperability requires
identifying the module **and** the encoding/profile.

This is not the same abstraction as [Serde's host-type data model][serde]. An
ASN.1 module can express ranges, size constraints, extension points, and
relationships between an identifier and an open payload. The separate schema
can drive several language bindings without making one host language normative.

### Design philosophy

The [`asn1c` README][repo] makes the breadth limitation explicit:

> The ASN.1 family of standards is large and complex, and no open source
> compiler supports it in its entirety.

That qualification matters more than a language-support checkbox. At the
surveyed revision `asn1c` provides BER decoding, DER encoding, and unaligned
PER encoding/decoding; its interoperability table explicitly marks aligned
PER unsupported. A claim about ASN.1's expressiveness is not automatically a
claim about this compiler's generated code.

## How it works

An illustrative module fragment separates constraints from representation:

```text
Message ::= SEQUENCE {
    counter INTEGER (0..255),
    enabled BOOLEAN,
    note OCTET STRING (SIZE (0..32)) OPTIONAL,
    ...
}
```

Under BER the components carry identifiers and lengths. Under PER the schema
supplies enough information to omit most tags and often encode bounds in a
small number of bits. The extension marker changes PER framing; it is not a
comment. [X.691 §§11.5, 13, 19, 23][x691] specify constrained integers,
sequences, and choices; [X.690 §§8–11][x690] specify BER and its restricted forms.

### Schema source of truth

The module is authoritative. `asn1c` parses, fixes semantic relationships, and
generates source, as its [processing pipeline][repo] documents. Generated
headers are products of the schema rather than a second independent wire
description. Application validation may still supply constraints the compiler
does not enforce.

[RFC 6025 §5][translation] explicitly puts responsibility on the programmer to
ensure constraints expressed in ASN.1 **or prose** are actually enforced.
Translating newer syntax into older syntax can preserve BER bytes while losing
automated constraint checking. Schema equivalence and validator equivalence
are therefore separate review questions.

### Wire encoding

BER is identifier-length-contents framing: tag class, primitive/constructed
bit, tag number, and a definite or permitted indefinite length. Integers use
signed contents; a positive value whose high bit would be set needs a leading
zero octet. A BER `BOOLEAN` permits nonzero true contents; DER requires `FF`.
[X.690 §§8.1–8.3, 10–11][x690] are the relevant rules.

DER restricts BER: definite lengths, shortest length forms, canonical true,
omission of default-valued components, and ordering rules for sets. It does
not mean “the decoder was called with a DER-looking input.” The surveyed
implementation's [API matrix][repo] uses `ber_decode()` for both BER and DER.
Strict DER acceptance needs additional enforcement, not just that function name.

PER uses the schema's PER-visible constraints to encode an integer relative
to its lower bound. Aligned PER introduces specified octet alignment;
unaligned PER can carry fields across octet boundaries. Neither is BER with
smaller length prefixes, and neither is a native-memory layout.

### Access model

The [BER decoder][decoder] consumes a stream into generated values and can
return `RC_WMORE` for incomplete input. This supports incremental input, not
constant-time field lookup into a mapped file. Finding an arbitrary late
component generally requires walking earlier framing.

Definite lengths let a parser skip a subtree without materializing it, but an
indefinite-length subtree requires structural scanning to its end-of-contents.
[`ber_skip_length`][length] implements that recursive distinction. PER makes
the schema even more essential: omitted tags remove the opportunity for
generic tag-indexed browsing.

### Variable-length and optional data

`OPTIONAL`, `DEFAULT`, `SEQUENCE OF`, and `SIZE` are schema-level mechanisms.
BER normally represents optional presence by the component's tagged
occurrence. PER uses presence bits for optional/default root components and
length determinants for variable collections; constraints can eliminate or
shrink length fields ([X.691 §§11.9, 19–20][x691]).

An open type is not an unchecked union cast. [RFC 6025 §§2.1–2.2][translation]
shows information object sets linking an object identifier to the payload
type, including ancestor-relative component relation constraints. Those are
**value/type** relationships, not byte-offset relocation rules.

### Evolution and compatibility

Stable tags and declared extension points support evolution, but changes must
be evaluated against the encoding. Adding an extension outside the root is
different from inserting a required root component; changing PER-visible
bounds can change the bit layout. [RFC 6025 §2.4][translation] explains
extension markers and version brackets without promising universal compatibility.

Unknown-value skipping is not semantic acceptance. A certificate extension
marked critical, for example, has protocol-specific rejection rules beyond
the ASN.1 decoder. ASN.1's extension machinery does not decide which unknown
features an application can safely ignore.

### Determinism and canonical form

BER intentionally admits multiple encodings. DER provides a distinguished
encoding of an ASN.1 value when the complete type and relevant contained
encodings are specified. Opaque `OCTET STRING` contents remain opaque unless
the protocol specifies their interpretation; DER does not normalize arbitrary
embedded files or Unicode strings for the application.

Canonical PER is specified separately from basic PER in [X.691][x691]. Do not
infer a portable canonical profile from an implementation happening to emit
one repeatable byte sequence. Pin module revision, encoding variant, and
application normalization when bytes become signature or cache-key inputs.

### Merkleization and content addressing

None of these encodings specifies a Merkle graph, link digest, chunking rule,
or subtree address. DER can supply stable serialization for an externally
chosen whole-value hash; that is not independently addressable child nodes.
The distinction follows the [content-addressing catalog][content-addressing].

An ASN.1 object identifier names a registered concept, not the digest of the
bytes carrying that concept. Confusing the two would hide both the hash
algorithm choice and the exact canonicalization domain.

### Hostile-input safety

Lengths, high tag numbers, recursive nesting, and resource consumption are
separate boundaries. [`ber_fetch_length`][length] checks length accumulation
for overflow; the decoder and recursive skip path use a stack budget. Those
checks are implementation evidence, not a proof that every generated parser
or application has a complete allocation/work budget.

**Type confusion can cross the parse/write boundary.** OpenSSL's primary
[CVE-2016-2108 advisory][advisory] reports that `d2i_ASN1_TYPE` could interpret
a large universal tag as negative zero. Re-encoding through
`i2c_ASN1_INTEGER` then caused an out-of-bounds write. Two independently
non-exploitable bugs combined through an `ANY` value; “parse succeeded” did
not establish that the writer's internal representation was valid.

The same advisory documents **CVE-2016-2109**: a short invalid ASN.1 BIO input
could trigger excessive allocation. Its affected BIO functions and unaffected
memory-based functions are distinguished explicitly. A bounded input slice,
a nesting cap, and an allocation cap answer different threats.

### Describing foreign formats

ASN.1 describes values whose encoding follows an ASN.1 transfer syntax; it
does not describe arbitrary OpenType storage. A `SEQUENCE OF` can represent
glyph IDs logically, but cannot force an existing sibling count to govern a
separate `Offset16` array whose targets are relative to a grandparent table.

One can wrap original font bytes in an `OCTET STRING`, but then the foreign
layout is opaque and needs another parser. `CHOICE` provides semantic tagged
variants, not arbitrary discriminants at chosen byte positions. Host-type
annotations can avoid a separate IDL in a D-specific design, but must supply
the offset-base and bounds contracts that ASN.1 deliberately does not address;
the [Flat draft §§4–6][flat] makes those separate obligations explicit.

### Implementation and performance evidence

The exact implementation evidence is the [API support matrix][repo],
[incremental BER decoder][decoder], and [length codec][length]. No benchmark
was run here; neither compact PER nor generated C establishes a particular
throughput or allocation count. No maintained D port was verified; generated
C can be an FFI starting point, not a demonstrated D binding.

An actual **OpenSSL 3.6.3** probe, executed during this review, inspected the
eight literal octets below. This tests BER/DER framing only, not `asn1c` or PER:

```bash
printf '\060\006\002\001\005\001\001\377' | openssl asn1parse -inform DER -i
```

```text
    0:d=0  hl=2 l=   6 cons: SEQUENCE
    2:d=1  hl=2 l=   1 prim:  INTEGER           :05
    5:d=1  hl=2 l=   1 prim:  BOOLEAN           :255
```

The bytes are `30 06 02 01 05 01 01 ff`: the sequence length is six, not the
total eight. `-inform DER` selects binary input, so this observation is **not**
evidence that the command rejects every non-DER BER representation.

This portable D sample maintains only the literal vector's TLV length and
canonical-true invariants; it is **not** an ASN.1 decoder or OpenSSL execution.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "binary_asn1_length_probe"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : writeln;

void main() @safe
{
    immutable ubyte[] der = [0x30, 6, 2, 1, 5, 1, 1, 0xff];
    assert(der[0] == 0x30 && der[1] == der.length - 2);
    assert(der[2] == 2 && der[3] == 1 && der[4] == 5);
    assert(der[5] == 1 && der[6] == 1 && der[7] == 0xff);
    writeln("DER fixture: 6 content octets, 8 total, true=FF");
}
```

```ansi
DER fixture: 6 content octets, 8 total, true=FF
```

## Strengths

- A mature separation of abstract schema, transfer syntax, and host bindings.
- DER gives a precise byte-identity tool for cryptographic protocols.
- PER exploits constraints rather than paying generic tags for every value.
- Open-type relationships and extension markers are explicit schema concepts.

## Weaknesses

- Standards breadth exceeds individual compiler support; profiles must be audited.
- Not a foreign-layout language or a borrowed random-access view system.
- Decoder permissiveness and canonical writer behavior are easily conflated.
- Constraint enforcement and resource policy remain implementation/application work.

## Key design decisions and trade-offs

| Decision                        | Rationale                                    | Trade-off                                                   |
| ------------------------------- | -------------------------------------------- | ----------------------------------------------------------- |
| Separate module from host types | Cross-language authority                     | Schema/compiler generation pipeline                         |
| Several transfer syntaxes       | Fit security, bandwidth, and streaming needs | Encoding must be negotiated precisely                       |
| DER restricts BER               | Make signature input unambiguous             | Ordering and length decisions can require buffering         |
| PER removes redundant structure | Use known constraints for compactness        | Schema mismatch changes interpretation deeply               |
| Open types and extensions       | Accommodate registered future types          | Dispatch and unknown-type policy become security boundaries |

## Sources

- [ITU-T X.690 (2021), §§8–11][x690]: BER structure and DER/CER restrictions.
- [ITU-T X.691 (2021), §§11–13, 19–23][x691]: PER primitives and composites.
- [RFC 6025, §§2 and 5][translation]: relationships, evolution, enforcement limits.
- [`asn1c` README, decoder, length handling, license][repo]: inspected source pin.
- [OpenSSL advisory, May 3, 2016][advisory]: confusion and allocation incidents.

<!-- References -->

[repo]: https://github.com/vlm/asn1c/blob/8a274c3f99761f249b6c205e1c89be1b1cb7c669/README.md
[license]: https://github.com/vlm/asn1c/blob/8a274c3f99761f249b6c205e1c89be1b1cb7c669/LICENSE
[decoder]: https://github.com/vlm/asn1c/blob/8a274c3f99761f249b6c205e1c89be1b1cb7c669/skeletons/ber_decoder.c
[length]: https://github.com/vlm/asn1c/blob/8a274c3f99761f249b6c205e1c89be1b1cb7c669/skeletons/ber_tlv_length.c
[x690]: https://www.itu.int/rec/T-REC-X.690-202102-I/en
[x691]: https://www.itu.int/rec/T-REC-X.691-202102-I/en
[translation]: https://www.rfc-editor.org/rfc/rfc6025.html
[advisory]: https://www.openssl.org/news/secadv/20160503.txt
[serde]: ../serde/serde.md
[content-addressing]: ../content-addressing/concepts.md
[flat]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
