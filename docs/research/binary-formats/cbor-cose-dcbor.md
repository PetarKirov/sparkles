# COSE, Deterministic CBOR and dCBOR (IETF / Rust)

Security envelopes, deterministic serialization rules and semantic narrowing are separate contracts, even when all use CBOR.

| Metadata           | Value                                                                 |
| ------------------ | --------------------------------------------------------------------- |
| Language           | Language-neutral RFCs/drafts; Rust reference implementation inspected |
| License            | RFC/draft: IETF Trust terms; Rust `dcbor`: BSD-2-Clause-Patent        |
| Repository         | [`BlockchainCommons/bc-dcbor-rust`][repo]                             |
| Documentation      | [RFC 9052][cose]; [RFC 9053][algorithms]; [dCBOR revision 18][dcbor]  |
| Category           | Security envelopes and deterministic serialization profiles           |
| Implementation pin | `c76a15a3729b5753824d0b08b95a08d7c7d8998d`, package `dcbor` 0.25.2    |
| Draft pins         | `draft-ietf-cbor-cde-13`; `draft-mcnally-deterministic-cbor-18`       |
| Review date        | October 17, 2026                                                      |

## Overview

### What it solves

[COSE][cose] specifies signatures, MACs, encryption and key representations.
[Deterministic CBOR][base] constrains the serialization of an already chosen
CBOR data item. [dCBOR][dcbor] additionally narrows the model and requires
strict decoding, including numeric reduction and NFC text. These solve
related but non-interchangeable problems.

An application can sign arbitrary opaque bytes with COSE without giving
those bytes a canonical application interpretation. Conversely, a dCBOR
document can have a unique encoding under its profile without having any
signature or authenticated origin. Neither automatically supplies a Merkle
tree. Base CBOR mechanics live in the [CBOR deep-dive][base].

### Design philosophy

[RFC 9052 §3][headers] explains why protected headers are byte strings:

> This avoids the problem of all parties needing to be able to do a common canonical encoding of the map for input to cryptographic operations.

That is a deliberate alternative to re-canonicalizing a received map.
The [dCBOR draft][dcbor], in contrast, describes narrowing choices to make
semantically equivalent values encode identically. The distinction parallels
the [serde model/representation vocabulary][serde] and the
[content-addressing canonical-form discussion][ca].

## How it works

The standards divide responsibility as follows:

| Contract          | Defines                                                   | Does not define                       |
| ----------------- | --------------------------------------------------------- | ------------------------------------- |
| RFC 8949          | CBOR values and encodings; optional deterministic rules   | Universal application equivalence     |
| RFC 9052          | COSE structures and cryptographic input construction      | Mandatory application algorithm suite |
| RFC 9053          | Initial concrete COSE algorithms and parameters           | General document canonicalization     |
| CDE revision 13   | Common deterministic serialization choices                | dCBOR numeric/text equivalences       |
| dCBOR revision 18 | Narrowed values, deterministic output and strict checking | Signatures, storage or Merkle proofs  |

### Schema source of truth

[RFC 9052][cose] uses normative prose and **informational** CDDL fragments.
Its `COSE_Sign1` array is `(protected, unprotected, payload, signature)`.
The protected member is a byte string containing an encoded map; the
unprotected member is an actual map. Integer or text labels identify header
parameters. Algorithm identifiers come from the COSE registry, with the
initial algorithms specified in [RFC 9053][algorithms].

CDE and dCBOR are profile rules, not schemas for an application's records.
An application can use [CDDL][cddl] to restrict shapes and still must state
which profile/version applies. A dCBOR type model does not automatically
make an application union, time value or decimal quantity unambiguous.

### Wire encoding

For a single signature the transmitted shape is:

```text
18([ protected-bstr, unprotected-map, payload-bstr-or-null, signature-bstr ])
```

Tag `18` is optional when external context identifies the message type.
An absent/detached payload uses null in the transmitted slot, but the actual
payload bytes are still supplied to the signature computation.

The separate `Sig_structure` for `COSE_Sign1` is:

```text
[ "Signature1", protected-bstr, external-aad-bstr, actual-payload-bstr ]
```

This array, not the entire transported COSE message, is encoded as
`ToBeSigned` under [§9][restrictions]. Signature algorithms consume that
byte string according to their own rules. Unprotected headers do not
magically become signed because they are in the outer array.

`COSE_Encrypt0`/`COSE_Encrypt` and `COSE_Mac0`/`COSE_Mac` use their own
structures and context strings. [RFC 9053][algorithms] specifies algorithm
details such as ECDSA signature component encodings and AEAD key/nonce/tag
sizes. A serializer cannot infer these from a generic CBOR byte-string type.

### Access model

CBOR parsing can expose an event stream or allocate a value tree; neither
RFC mandates a particular host layout. Preserving borrowed slices of
protected-header and payload bytes is useful, but is an implementation
choice rather than a native-struct overlay guarantee.

Verification must use the protected header **bytes as received**. Decoding
their map is needed for header interpretation; replacing those bytes with
a re-encoded map changes `ToBeSigned`. This is especially important when
a generic decoder loses map ordering or numeric representation distinctions.

### Variable-length and optional data

The base format has definite and indefinite containers. COSE's [§9][restrictions]
requires definite lengths and shortest argument encodings for the internal
`Sig_structure`, `Enc_structure` and `MAC_structure`; it does not require
every transported message or opaque payload to use dCBOR.

Protected headers may be empty: senders should use an empty byte string,
and receivers must also accept a byte string containing the encoded empty
map. A detached payload is null, not an empty payload byte string.
External AAD defaults to an empty byte string ([headers][headers], [signing][signing]).

CDE and dCBOR exclude indefinite-length strings/containers in their
deterministic encodings. dCBOR permits false, true and null but excludes
undefined and other simple values. Application absence still needs a
chosen representation: omitted field, null and empty string are not
interchangeable merely because one profile is deterministic.

### Evolution and compatibility

RFCs 9052 and 9053 together obsolete RFC 8152. The split separates
structures/process from algorithms. Countersignatures have a separate
successor, [RFC 9338][countersignatures]; do not apply removed RFC 8152
counter-signature assumptions to `COSE_Sign1` ([RFC 9052 §1.2][cose]).

The draft versions here are explicit snapshots, **not RFCs**:

- [CDE revision 13][cde], dated October 14, 2025, expires April 17, 2026.
  It is an expired work in progress at this review date, not an approved BCP.
- [dCBOR revision 18][dcbor], dated August 10, 2026, expires February 11, 2027. It remains an Internet-Draft, with no RFC number in the
  [Datatracker record][draft-status].

COSE extension handling includes the protected `crit` header: an unknown
critical parameter cannot be silently ignored. Supporting a new algorithm
also requires key/algorithm policy, not just accepting another integer label.

### Determinism and canonical form

[RFC 8949 §4.2][deterministic] distinguishes deterministic serialization from
application-level choices. [CDE revision 13][cde] combines preferred
serialization, definite lengths and lexicographic ordering of encoded map
keys. It retains floating-point versus integer distinctions and signed
floating zeros; it does not normalize all NaN payloads into one value.

[dCBOR revision 18][dcbor] adds specific narrowing:

- Integral floating values exactly within `[-2^63, 2^64-1]` reduce to integers.
- Integer zero, `0.0` and `-0.0` therefore encode as `00`.
- NaNs reduce to the single half-precision encoding `f97e00`.
- Text must be NFC; duplicate map keys and nonconforming encodings are rejected.
- Rules recurse into array elements, map keys/values and tag contents.

Numeric equivalence applies to **untagged** numbers. Tagged items are not
numerically equal to untagged numbers; equality of two tagged items includes
the tag number and enclosed value. Normalization can create duplicate keys,
so checking duplicates only before reducing numbers is insufficient.

Do not substitute [DAG-CBOR][ipld] for dCBOR: DAG-CBOR restricts tags to CIDs,
uses only string map keys and fixes floats at binary64. All three names
refer to different contracts, not settings with one shared “canonical” flag.

### Merkleization and content addressing

None of RFC 9052, RFC 9053, CDE or dCBOR defines a universal recursive Merkle
root over every nested field. Hashing a dCBOR document normally commits
to the whole deterministic encoded byte string. A signature authenticates
the specifically constructed COSE signing input, not a general subtree API.

COSE provides domain/context separation through strings such as
`"Signature1"`; byte-string and array lengths delimit components. This
prevents ambiguous concatenation of adjacent fields. There is no SSZ
length mix-in or prescribed binary tree shape ([signing process][signing]).

Proof boundaries are consequently whole signing inputs/payloads. Selective
disclosure, detached digests and field proofs require an additional protocol.
RFC 9052 explicitly declines to standardize one universal digest object;
it points to application-specific design instead. The [existing
recommendations][recommendations] explain why byte identity, authenticated
origin and partial verification must be considered separately.

### Hostile-input safety

Reject duplicate header labels rather than allowing a host map to overwrite
earlier values. Enforce expected types, supported algorithms, key usage,
critical parameters and nonce policy. Successful parsing or mathematically
valid signature verification does not establish signer authorization.

dCBOR decoders must reject nonpreferred floats, non-NFC strings and invalid
map order; normalizing after accepting a hostile alternate byte encoding is
not the same contract. Apply independent limits to depth, map/array count,
payload size and work. Unicode normalization checks themselves consume
resources ([dCBOR security considerations][dcbor], [COSE security][security]).

### Describing foreign formats

Not a fixed-layout foreign-format language. CDDL describes values and
embedded CBOR; it does not express arbitrary endian fields and relative
pointers in a font file. A COSE payload can hold such a file as opaque
bytes, but COSE then authenticates bytes without describing their layout.

For the [Flat draft][flat], signing a whole arena or its digest is a separate
layer from its layout proof and caller-provided input key. dCBOR could encode
a manifest of inputs, but choosing its hash/domain and proving completeness
of those inputs remains an application responsibility.

### Implementation and performance evidence

**Runnable independent COSE framing check, not a signer or CBOR codec.**
This fixed empty-payload `Sig_structure` retains the protected-map bytes.
The SHA-256 comparison only detects changed preimages; it is not signature
verification or a requirement that every COSE algorithm use SHA-256.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "research_cose_signing_input_framing"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.digest.sha : sha256Of;
import std.stdio : writeln;

void main() @safe
{
    ubyte[] input = [0x84, 0x6a]; // array(4), text(10)
    foreach (ch; "Signature1") input ~= cast(ubyte) ch;
    input ~= [0x43, 0xa1, 0x01, 0x26, 0x40, 0x40];
    // protected bstr(a10126), empty external AAD, empty payload
    assert(input.length == 18 && input[12] == 0x43);
    auto changed = input.dup;
    changed[15] = 0x27; // different protected-header bytes
    assert(sha256Of(input) != sha256Of(changed));
    writeln("empty-payload Sig_structure: ", input.length, " bytes");
    writeln("protected-header byte change alters the signing input");
}
```

```ansi
empty-payload Sig_structure: 18 bytes
protected-header byte change alters the signing input
```

**Normative-source vectors, not local execution.** [dCBOR revision 18 §7][dcbor]
provides these exact acceptance/rejection fixtures:

| Input/value            | Hex                  | dCBOR result                                             |
| ---------------------- | -------------------- | -------------------------------------------------------- |
| `42.0`                 | `182a`               | Reduced integer encoding                                 |
| `-0.0`                 | `00`                 | Reduced zero encoding                                    |
| `1.5`                  | `f93e00`             | Preferred half-precision encoding                        |
| Floating `12.0`        | `f94a00`             | Reject: reducible                                        |
| Double-precision `1.5` | `fb3ff8000000000000` | Reject: not preferred                                    |
| Integer `−2^63−1`      | `3b8000000000000000` | Draft §7.2 says reject; implementation discrepancy below |
| Integer `−2^64`        | `3bffffffffffffffff` | Draft §7.2 says reject; implementation discrepancy below |

> [!WARNING]
> The draft and inspected implementation disagree at the negative-integer
> boundary. Revision 18 §7.2 rejects the two integer fixtures above, while the
> pinned [Rust decoder][decoder] accepts major-type-1 values directly and its
> [value model][value-model] explicitly supports negative integers through
> `−2^64`. The draft's §2.5 interval quoted above expressly governs **float
> reduction**; it does not by itself resolve this integer-fixture tension.
> Treat this as an unresolved draft-vector/implementation discrepancy, not
> established interoperability with revision 18 at these boundaries.

[RFC 9052 Appendix C.2.1][cose-vector] supplies a `COSE_Sign1` ECDSA/P-256
fixture with protected-map bytes `a10126`, payload `This is the content.`
and a complete signature. Those bytes describe an algorithm header, not a
standalone signed message; the appendix is the complete independent vector.

No D port or binding was verified in this survey.
The pinned [Rust encoder tests][tests] compare exact hex, display form and
round trips, including integer-width normalization. No local Rust build,
signature verification or timing benchmark was run. Their presence is
implementation evidence, not a claim of profile conformance established by
this survey or a performance ranking against generic CBOR codecs.

## Strengths

- COSE preserves exact authenticated bytes without demanding canonical payloads.
- dCBOR specifies both encoder behavior and strict decoder checks.
- CDE distinguishes serialization choices from application semantic choices.

## Weaknesses

- “Deterministic CBOR” alone does not identify a complete interoperable profile.
- Numeric/text reduction can erase distinctions an application needs.
- Signatures and deterministic bytes do not provide field-level Merkle proofs.

## Key design decisions and trade-offs

| Decision                               | Rationale                                  | Trade-off                                        |
| -------------------------------------- | ------------------------------------------ | ------------------------------------------------ |
| Preserve protected map as bytes        | Avoid re-encoding disagreement             | Verifiers must retain original bytes             |
| Separate COSE structure and algorithms | Extend cryptography independently          | Application must specify a policy suite          |
| dCBOR numeric and NFC narrowing        | Reduce semantic representation variability | Some original distinctions/maps are inadmissible |
| Strict profile checking                | Exclude alternate encodings at ingress     | More validation work and less legacy leniency    |

## Sources

- [RFC 9052][cose], [RFC 9053][algorithms] and [RFC 9338][countersignatures].
- Exact [CDE revision 13][cde] and [dCBOR revision 18][dcbor], plus [draft status][draft-status].
- Pinned [Rust manifest][manifest] and [encoder tests][tests].
- [Shared concepts][concepts] and [comparison][comparison].

<!-- References -->

[repo]: https://github.com/BlockchainCommons/bc-dcbor-rust/tree/c76a15a3729b5753824d0b08b95a08d7c7d8998d
[manifest]: https://github.com/BlockchainCommons/bc-dcbor-rust/blob/c76a15a3729b5753824d0b08b95a08d7c7d8998d/Cargo.toml
[tests]: https://github.com/BlockchainCommons/bc-dcbor-rust/blob/c76a15a3729b5753824d0b08b95a08d7c7d8998d/tests/encode.rs
[cose]: https://www.rfc-editor.org/rfc/rfc9052
[headers]: https://www.rfc-editor.org/rfc/rfc9052#section-3
[signing]: https://www.rfc-editor.org/rfc/rfc9052#section-4.4
[restrictions]: https://www.rfc-editor.org/rfc/rfc9052#section-9
[security]: https://www.rfc-editor.org/rfc/rfc9052#section-12
[cose-vector]: https://www.rfc-editor.org/rfc/rfc9052#appendix-C.2.1
[algorithms]: https://www.rfc-editor.org/rfc/rfc9053
[countersignatures]: https://www.rfc-editor.org/rfc/rfc9338
[deterministic]: https://www.rfc-editor.org/rfc/rfc8949#section-4.2
[cde]: https://www.ietf.org/archive/id/draft-ietf-cbor-cde-13.txt
[dcbor]: https://www.ietf.org/archive/id/draft-mcnally-deterministic-cbor-18.txt
[draft-status]: https://datatracker.ietf.org/doc/draft-mcnally-deterministic-cbor/
[cddl]: ./cddl.md
[base]: ./cbor.md
[ipld]: ./ipld.md
[serde]: ../serde/concepts.md
[ca]: ../content-addressing/concepts.md#canonical-form
[recommendations]: ../content-addressing/recommendations.md
[flat]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[decoder]: https://github.com/BlockchainCommons/bc-dcbor-rust/blob/c76a15a3729b5753824d0b08b95a08d7c7d8998d/src/decode.rs
[value-model]: https://github.com/BlockchainCommons/bc-dcbor-rust/blob/c76a15a3729b5753824d0b08b95a08d7c7d8998d/src/cbor.rs
