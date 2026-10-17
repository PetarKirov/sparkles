# TUF / in-toto / DSSE (JSON / Python)

Signed update metadata and typed attestations illustrate two different authentication boundaries: canonical objects versus exact payload bytes.

| Field         | Value                                                                                                           |
| ------------- | --------------------------------------------------------------------------------------------------------------- |
| Language      | Protocol-independent JSON profiles; Python reference tools examined                                             |
| License       | TUF specification: Community Specification License 1.0; in-toto attestation and DSSE reference code: Apache-2.0 |
| Repository    | [TUF specification][tuf-repo] · [in-toto attestation][att-repo] · [DSSE][dsse-repo]                             |
| Documentation | [TUF 1.0.37][tuf] · [in-toto statement v1][statement] · [DSSE 1.0.2][dsse]                                      |
| Category      | Authenticated metadata and typed signature-envelope framing                                                     |
| D bindings    | No D binding surveyed; the inline probe independently constructs PAE bytes                                      |
| Scope         | TUF JSON metaformat, in-toto attestation layers and DSSE; not every historical in-toto layout/link format       |

## Overview

### What it solves

[TUF][tuf] secures the selection and retrieval of software updates despite
untrusted mirrors and limited key compromise. It specifies authority, versions,
expiry, delegation and target-file identity, not a package payload format.
[in-toto statements][statement] bind claims to artifact digests and identify a
predicate schema. [DSSE][dsse] authenticates the serialized statement and its
payload type without needing to parse or canonicalize that statement first.

These mechanisms can compose, but their signature inputs are not interchangeable.
A serializer that “makes JSON deterministic” has solved neither all of TUF's
trust workflow nor DSSE's typed byte framing. See the survey's [concepts][concepts]
and [comparison][comparison] for the wider encoding taxonomy.

### Design philosophy

The [TUF specification's metaformat section][tuf] permits different data formats,
but requires unambiguous interpretation and says:

> Implementers should choose a data format that allows for canonicalization, or one that will decode data deterministically by default so that signatures can be accurately verified.

The [in-toto envelope specification][envelope] takes another approach:

> SHOULD avoid depending on canonicalization for security

That is not a contradiction. TUF's described JSON profile signs canonical role
objects; DSSE signs an unambiguous pre-authentication encoding of an opaque
serialized body and type. Their common objective is to make the signed meaning
unambiguous, but they place parsing on different sides of authentication.

## How it works

### Schema source of truth

[TUF 1.0.37][tuf] defines metadata roles and the client workflow. Its
Protocol, Operations, Usage, and Format (POUF) mechanism records implementation
choices. JSON is the described profile, not the only permitted representation.
The examined [`securesystemslib.formats`][canonical] implements OLPC-style
canonical JSON; it must not be silently substituted with RFC 8785 JSON
Canonicalization Scheme or a generic JSON library's “sort keys” mode.

[in-toto][layers] separates envelope, statement and predicate. Statement v1 has
`_type`, required `subject` descriptors with digests, `predicateType`, and an
optional `predicate`. The [envelope][envelope] recommends DSSE and binds a JSON
statement using `application/vnd.in-toto+json` or its specified predicate-specific
form. The authenticated statement's `predicateType`, not an unauthenticated
storage label, determines predicate interpretation.

### Wire encoding

TUF metadata is an outer object with `signed` and `signatures`. Each signature
has a `keyid` and hex `sig`; it authenticates the canonical form of the **role
object under `signed`**, not the containing document including signatures.
Thus adding another signature need not invalidate existing signatures.
[TUF object format][tuf]

DSSE's recommended [JSON envelope][dsse-envelope] carries `payloadType`,
base64 `payload` and a signatures array. Its signature input is:

```text
PAE(type, body) = "DSSEv1" || SP || LEN(type) || SP || type || SP || LEN(body) || SP || body
```

Here `type` is UTF-8 bytes, both lengths are decimal ASCII **byte counts without
leading zeroes**, and the body is the exact decoded payload bytes, not its
base64 spelling. The marker and length boundaries prevent type/body
concatenation ambiguities; they do not normalize the body. [DSSE protocol][dsse]

Local reference-tool probes, executed at the cited source pins:

```bash
PYTHONPATH="$REPOS/securesystemslib" python3 -c 'from securesystemslib.formats import encode_canonical; print(encode_canonical({"z":3,"a":[True,None]})); print(encode_canonical({"z":3,"a":[True,None]}).encode().hex())'
PYTHONPATH="$REPOS/dsse/implementation" python3 -c 'from signing_spec import PAE; print(PAE("application/vnd.in-toto+json", b"{}")); print(PAE("application/vnd.in-toto+json", b"{}").hex())'
```

Observed output:

```text
{"a":[true,null],"z":3}
7b2261223a5b747275652c6e756c6c5d2c227a223a337d
b'DSSEv1 28 application/vnd.in-toto+json 2 {}'
445353457631203238206170706c69636174696f6e2f766e642e696e2d746f746f2b6a736f6e2032207b7d
```

These exercise the actual [canonical encoder][canonical] and [DSSE reference
PAE function][pae], not a reimplementation. `{}` is a framing-only body, not a
valid in-toto statement, and neither command signs or verifies a signature.

### Access model

TUF clients follow trust transitions rather than treating any successfully
parsed document as trusted: load an out-of-band trusted root; update roots in
sequence; verify timestamp, snapshot and targets/delegations; then download and
verify a selected target. Role-specific thresholds and stored versions govern
acceptance. Target files are opaque bytes and can use any layout. [TUF client workflow][tuf]

DSSE parses the outer envelope to obtain bytes, verifies their PAE with trusted
keys, checks the supported payload type, and only then parses the body. The
same verified bytes must be handed to the application; reparsing an envelope
after verification to fetch its payload is expressly prohibited. Neither JSON
profile is an in-place fixed-record access model. [DSSE protocol][dsse]

### Variable-length and optional data

JSON strings, objects and arrays carry the metadata shape; HTTP/file framing
supplies the document extent. DSSE PAE's decimal lengths delimit the signature
preimage internally but do **not** serve as trusted download size limits: the
envelope already supplied those bytes. Base64 further separates textual
transport length from decoded payload length. [DSSE protocol][dsse], [envelope][dsse-envelope]

TUF target descriptions include mandatory target byte length and hash mappings;
snapshot/timestamp metadata references can optionally include metadata file
lengths and hashes. These are not lengths of the canonical role preimage.
in-toto's `predicate` may be absent, treated like an empty predicate object,
while subject digests are required. [TUF formats][tuf], [statement][statement]

### Evolution and compatibility

TUF's `spec_version` declares format compatibility while metadata `version`
supports rollback checks; these have different meanings. Unknown attribute/value
pairs must remain included when hashing or verifying and must survive
reserialization. A decoder that drops unknown fields before canonicalizing can
verify the wrong object. [TUF formats][tuf]

in-toto uses type URIs with major versions and requires unknown fields to be
ignored under its monotonic extension rules. Ignoring a field must not turn an
expected denial into allowance. This is a **policy** constraint, not merely a
JSON parser option. Exact-byte DSSE verification still covers those unknown
fields even if application code ignores them afterward. [in-toto parsing rules][layers]

DSSE authenticates an opaque, case-sensitive payload type. Unsupported types
must be rejected, not guessed from body shape. A valid signature for some other
schema is not authorization to reinterpret the body as an in-toto statement.
[DSSE protocol][dsse]

### Determinism and canonical form

The examined [canonical encoder][canonical] sorts object keys, removes
insignificant whitespace, emits no floating-point values and escapes only quote
and backslash in strings. This is a particular canonical JSON dialect, not the
claim that every standards-compliant JSON serializer yields these bytes.
Its [tests][canonical-tests] explicitly reject floats, including nested ones.

TUF signature verification operates on the canonical role object, so different
outer JSON indentation can preserve signatures. A metadata file's hash recorded
by another role, however, identifies the **downloaded metadata file bytes**.
Changing pretty-printing can therefore require updating that file hash even
when the role signature remains valid. Target hashes likewise cover exact
target file bytes, not JSON semantic equivalence. [TUF formats and workflow][tuf]

DSSE does not canonicalize its body. `{"a":1}` and `{ "a": 1 }` are different
signed byte sequences even if a JSON application treats them equally. Reformatting
the outer envelope may preserve verification because its base64 value decodes
to the same body; reformatting the **body** changes the PAE and requires new
signatures. Deterministic producer output can be useful, but it is not DSSE's
security requirement. [DSSE protocol][dsse]

### Merkleization and content addressing

Not a Merkle-tree format: neither TUF's metadata roles nor an in-toto subject
list implies CT-style tree proofs. TUF uses signatures to authorize metadata
and lengths/hashes to bind target bytes; an in-toto subject digest names the
artifact about which a signer makes a claim. Predicate semantics and signer
authorization still need policy. [TUF][tuf], [statement][statement]

TUF's **root role** is a trust/key configuration, not a Merkle root. Root
rotation requires thresholds under both the previously trusted root and the
candidate new root, plus the exact next version. No hash alone can replace
that authority transition. DSSE's `keyid` is explicitly an unauthenticated
selection hint; it cannot make an untrusted public key authoritative.
[TUF root workflow][tuf], [DSSE protocol][dsse]

### Hostile-input safety

Cap downloads **before** signature checks can finish. TUF explicitly sets
application-defined maximum bytes for root and timestamp downloads when no
trusted length is known, and limits the number of root updates. Trusted
lengths/hashes for later files constrain fetching; final digest verification
does not excuse accepting an endless response. [TUF client workflow][tuf]

Bound JSON nesting, token counts, integer parsing, signature count and base64
expansion. Resolve duplicate-member ambiguity consistently; do not verify one
parse and consume another. Count distinct authorized keys for threshold
acceptance, not repeated signatures. DSSE's normative threshold procedure uses
a set of accepted trusted keys. TUF also requires unique-key counting.
[TUF][tuf], [DSSE protocol][dsse]

A further local framing probe exposed a reference-code limitation:

```bash
PYTHONPATH="$REPOS/dsse/implementation" python3 -c 'from signing_spec import PAE; print(PAE("é", b"x").hex())'
```

Observed:

```text
445353457631203120c3a920312078
```

This is `DSSEv1 1 ` followed by UTF-8 `c3 a9`, then ` 1 x`: the reference Python
function uses `len(payloadType)` before UTF-8 encoding and therefore counts one
character rather than two bytes here. The [normative protocol][dsse] requires
byte lengths. The ASCII media-type probe agrees with the protocol; this Unicode
probe does not. This is evidence about the pinned illustrative implementation,
not a claim that production DSSE libraries share the defect. [Reference source][pae]

### Describing foreign formats

These systems authenticate arbitrary target bytes but do not describe their
internal field offsets. A [Flat-style cache][flat] can be a TUF target or an
in-toto subject, but its bounded layout validation remains separate from trust
and attestation evaluation. Its layout digest cannot substitute for a target
content hash, trusted signing role, expiry check or predicate policy.

### Implementation and performance evidence

The local probes exercise the pinned Python canonical encoder and PAE function,
including the non-ASCII discrepancy. They do not exercise key loading,
cryptographic signing, threshold verification, update workflows or full
attestation policy. Their commands are reproducible but not CI-registered.

The [DSSE protocol's own source vector][dsse] specifies
`DSSEv1 29 http://example.com/HelloWorld 11 hello world` and an ECDSA example;
that signature vector was **not locally executed**. No throughput or allocation
benchmarks were run. Preimage framing avoids a body parse before verification,
but that structural property is not a measured performance comparison with
TUF's canonicalization. [DSSE][dsse], [in-toto envelope][envelope]

#### CI-verified independent framing probe

This small independent PAE constructor checks the normative UTF-8 **byte**
length rule and the cited ASCII reference result. It is not a DSSE signer,
verifier, canonical JSON encoder or upstream-tool execution. In particular, its
non-ASCII case follows the protocol rather than the illustrative Python defect.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "binary_dsse_pae_probe"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.conv : to;
import std.digest : toHexString;
import std.stdio : writeln;
import std.string : representation;

string pae(string payloadType, string body) @safe pure
{
    return "DSSEv1 " ~ payloadType.length.to!string ~ " " ~ payloadType
        ~ " " ~ body.length.to!string ~ " " ~ body;
}

void main() @safe
{
    immutable asciiFrame = pae("application/vnd.in-toto+json", "{}");
    assert(asciiFrame == "DSSEv1 28 application/vnd.in-toto+json 2 {}");
    immutable unicodeFrame = pae("é", "x");
    assert("é".length == 2);
    assert(unicodeFrame == "DSSEv1 2 é 1 x");
    assert(pae("a", "bc") != pae("ab", "c"));
    assert(pae("application/vnd.in-toto+json", "{ }") != asciiFrame);
    writeln(asciiFrame);
    writeln("UTF-8 type frame: ", unicodeFrame.representation.toHexString);
}
```

```ansi
DSSEv1 28 application/vnd.in-toto+json 2 {}
UTF-8 type frame: 445353457631203220C3A920312078
```

## Strengths

- TUF separates authority, freshness, consistency and byte identity.
- DSSE binds the payload type and exact serialized body without body canonicalization.
- in-toto separates authenticated transport from subject and predicate semantics.
- Explicit threshold/key and update limits address attacks beyond hash mismatch.

## Weaknesses

- Canonical role bytes, metadata-file bytes and target bytes are easy to confuse.
- JSON/base64 framing and signatures do not by themselves impose resource limits.
- A valid attestation signature is not a complete authorization or provenance policy.
- Illustrative reference code requires differential checking against the normative
  byte-level contract, as the Unicode PAE probe demonstrates.

## Key design decisions and trade-offs

| Decision                                            | Rationale                                                           | Trade-off                                                  |
| --------------------------------------------------- | ------------------------------------------------------------------- | ---------------------------------------------------------- |
| TUF signs canonical role objects                    | Preserve signatures across outer formatting/signature changes       | Canonicalization and unknown-field preservation must agree |
| Hash metadata files separately from role signatures | Bind exactly distributed files between roles                        | Reformatting may change referenced file hashes             |
| DSSE signs typed opaque bytes                       | Avoid canonicalizing or interpreting the body before authentication | Semantically equal bodies can need different signatures    |
| Treat `keyid` as a hint                             | Keep trust in configured keys rather than attacker labels           | Verifiers need separate key/threshold policy               |
| Versioned roles and expiry                          | Detect rollback and prolonged freeze attacks                        | Clients need trusted state and time policy                 |
| Separate statement and predicate                    | Reuse authentication across claim types                             | Consumers still need schema-specific policy                |

## Sources

- [The Update Framework Specification 1.0.37][tuf], TUF contributors — metaformat,
  roles, target hashes and trusted update workflow; [license][tuf-license].
- [Canonical encoder][canonical] and [tests][canonical-tests] — locally executed
  JSON preimage evidence.
- [in-toto parsing rules][layers], [statement][statement] and [envelope][envelope]
  — layer boundaries and policy semantics.
- [DSSE protocol 1.0.2][dsse], [JSON envelope][dsse-envelope] and
  [reference implementation][pae] — PAE definition, trust procedure and probes.

<!-- References -->

[tuf-repo]: https://github.com/theupdateframework/specification/tree/e2bc7d83d0740aaae8dd7133dd4f237ce3d86b16
[tuf]: https://github.com/theupdateframework/specification/blob/e2bc7d83d0740aaae8dd7133dd4f237ce3d86b16/tuf-spec.md
[tuf-license]: https://github.com/theupdateframework/specification/blob/e2bc7d83d0740aaae8dd7133dd4f237ce3d86b16/LICENSE.md
[canonical]: https://github.com/secure-systems-lab/securesystemslib/blob/e13bac299ebe9064592787c761e865bc0c5a78bd/securesystemslib/formats.py
[canonical-tests]: https://github.com/secure-systems-lab/securesystemslib/blob/e13bac299ebe9064592787c761e865bc0c5a78bd/tests/test_formats.py
[att-repo]: https://github.com/in-toto/attestation/tree/fd2609c16bcb0ac53443e2b4612977f997e8f9a5
[statement]: https://github.com/in-toto/attestation/blob/fd2609c16bcb0ac53443e2b4612977f997e8f9a5/spec/v1/statement.md
[layers]: https://github.com/in-toto/attestation/blob/fd2609c16bcb0ac53443e2b4612977f997e8f9a5/spec/v1/README.md
[envelope]: https://github.com/in-toto/attestation/blob/fd2609c16bcb0ac53443e2b4612977f997e8f9a5/spec/v1/envelope.md
[dsse-repo]: https://github.com/secure-systems-lab/dsse/tree/b531b787bb3e5f0c3e1c19cee84da1c5d569b061
[dsse]: https://github.com/secure-systems-lab/dsse/blob/b531b787bb3e5f0c3e1c19cee84da1c5d569b061/protocol.md
[dsse-envelope]: https://github.com/secure-systems-lab/dsse/blob/b531b787bb3e5f0c3e1c19cee84da1c5d569b061/envelope.md
[pae]: https://github.com/secure-systems-lab/dsse/blob/b531b787bb3e5f0c3e1c19cee84da1c5d569b061/implementation/signing_spec.py
[flat]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
