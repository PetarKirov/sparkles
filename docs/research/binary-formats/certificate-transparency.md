# Certificate Transparency (TLS presentation language / Go)

Exact binary leaves and signed tree heads make an append-only log auditable; static tiles change distribution, not the Merkle commitment.

| Field         | Value                                                                                         |
| ------------- | --------------------------------------------------------------------------------------------- |
| Language      | Protocol-independent TLS presentation language; Go implementation examined                    |
| License       | RFC: IETF Trust terms; examined Google implementation: Apache-2.0                             |
| Repository    | [google/certificate-transparency-go][repo] · [C2SP][c2sp]                                     |
| Documentation | [RFC 6962][rfc] · [Static CT API][static] · [Tiled Transparency Logs][tiles]                  |
| Category      | Signed append-only log and authenticated static distribution                                  |
| D bindings    | No D binding surveyed; the inline probe uses Phobos, not the Go codec                         |
| Scope         | RFC 6962 v1 plus separately specified static/tiled read APIs; not RFC 9162 wire compatibility |

## Overview

### What it solves

Certificate Transparency (CT) lets monitors notice certificates and auditors
check whether a log included entries and retained an append-only history.
It does not make a logged certificate correctly issued. The serialized boundary
matters because the tree commits to **leaf bytes**, while signatures authenticate
particular tree heads or promises to include a certificate. JSON returned by an
HTTP API is not the signature input. [RFC 6962 §§1–5][rfc]

### Design philosophy

[RFC 6962 §2.1][rfc] explicitly motivates its leaf/node distinction:

> This domain separation is required to give second preimage resistance.

The [Static CT API][static] preserves that commitment while replacing server-side
proof queries with cacheable assets:

> Clients can fetch all the tiles they need in parallel and compute arbitrary proofs.

These are complementary choices: exact cryptographic framing at the trust
boundary, flexible distribution outside it. A tile need not be individually
signed if its contents are verified against an authenticated tree head.

## How it works

### Schema source of truth

[RFC 6962 §1.2][rfc] uses the TLS 1.2 presentation language for structures,
fixed arrays, length-prefixed vectors and discriminated selections. The
[Go types][types] encode these with fields and `tls` tags, including `maxlen`,
`size`, `selector` and `val`. They describe a pre-existing foreign format rather
than defining an implementation-native memory layout.

The [Static CT specification][static] and [generic tiled-log specification][tiles]
are distinct schemas. Both use RFC 6962's SHA-256 tree, but their entry endpoints
and entry framing differ. A shared path vocabulary does not imply byte-for-byte
interchangeability.

### Wire encoding

TLS integers are unsigned and big-endian at declared widths. An `ASN.1Cert`
vector has a three-byte byte length, while `CtExtensions` has a two-byte length.
A `MerkleTreeLeaf` starts with one-byte version and leaf type, followed by a
`TimestampedEntry`: eight-byte timestamp, two-byte entry type, selected signed
entry and extensions. X.509 entries carry a length-prefixed DER certificate;
precertificate entries carry a 32-byte issuer key hash and a length-prefixed
TBSCertificate. [RFC 6962 §§3.1–3.4][rfc], [Go types][types]

The signed tree-head **input** is exactly 50 bytes: version `1` byte, signature
type `1` byte, timestamp `8` bytes, tree size `8` bytes and root `32` bytes.
There is no JSON whitespace or base64 inside that input. The HTTP `get-sth`
response represents fields as JSON numbers and base64 strings; the
[`SerializeSTHSignatureInput` implementation][serialization] reconstructs the
binary structure and requires a 32-byte root.

**Precise upstream vectors, not locally executed:**
[`tls/tls_test.go`, `TestUnmarshalMarshalWithParamsRoundTrip`][tls-tests] contains:

| Hex              | Expected interpretation                                                               |
| ---------------- | ------------------------------------------------------------------------------------- |
| `010203`         | `Uint24(0x010203)`                                                                    |
| `020a0b`         | two-byte vector `0a 0b`, with `minlen:1,maxlen:5`                                     |
| `06010102020303` | vector byte length `6`, three `uint16` values `0x0101`, `0x0202`, `0x0303`            |
| `04030003010203` | `DigitallySigned`: SHA256 `4`, ECDSA `3`, signature byte length `3`, bytes `01 02 03` |

These isolate the important rule: a vector prefix counts **serialized bytes**,
not elements. The synthetic three-byte signature checks codec framing only,
not ECDSA validity. No Go toolchain was available on `PATH` for a local run.

### Access model

RFC 6962 supplies dynamic queries for entries, inclusion proofs and consistency
proofs. `get-entries` uses inclusive `start` and `end` indices and may return fewer
entries than requested, starting at `start`. `leaf_input` is the hashed
`MerkleTreeLeaf`; `extra_data` is unsigned auxiliary chain material. It is wrong
to hash their concatenation or to treat a valid leaf proof as authentication of
all auxiliary bytes. [RFC 6962 §§4.5–4.8][rfc]

[Static CT][static] instead publishes `checkpoint`, hash tiles under
`tile/L/N[.p/W]`, and data tiles under `tile/data/N[.p/W]`. Hash tiles hold
256 consecutive 32-byte hashes: exactly 8192 bytes when full. Tile level `0`
contains leaf hashes; each next level advances **eight binary tree levels**.
Clients reconstruct intervening nodes and proofs locally.

The [generic tiled API][tiles] uses `tile/entries/N[.p/W]` for entry bundles,
not Static CT's `tile/data` encoding. Bundles are sequences of two-byte
big-endian length-prefixed entries. Static CT data tiles instead concatenate
`TileLeaf` structures: `TimestampedEntry`, a precertificate only when selected,
and a two-byte-length vector of 32-byte certificate-chain fingerprints.
To hash a Static CT leaf, reconstruct the RFC leaf's version/type prefix;
do not hash the entire `TileLeaf` with its auxiliary data. [Static CT][static]

### Variable-length and optional data

TLS vector maxima determine prefix width, independent of the actual encoded
length. Every nested vector must stay within its parent's declared byte region.
The selected entry type determines which fields exist; it is not permission to
reinterpret a host-language union with implicit padding. [RFC 6962 §3][rfc], [TLS tests][tls-tests]

Static CT defines a required `leaf_index` SCT extension: one-byte type `0`,
two-byte extension-data length `5`, and a five-byte big-endian index. Thus its
extension list's **contents** occupy eight bytes, and the enclosing
`CtExtensions` length prefix adds another two. Extension order is arbitrary;
duplicates of a type are forbidden. [Static CT, SCT Extension][static]

Partial tiles contain between 1 and 255 hashes, with width
`floor(size / 256^level) mod 256`; they are not hashed as full subtrees into the
next tile level. The width suffix makes each published partial object immutable.
A client requests partial tiles justified by a verified checkpoint, with a full
tile fallback if the partial is retired. [Static CT][static], [tiled API][tiles]

### Evolution and compatibility

RFC 6962's serialized SCT list length-prefixes each SCT independently, enabling
an old client to skip an unknown version. Likewise the dynamic entries API
allows an unknown leaf/entry type to remain opaque for tree verification.
Authenticating bytes need not require understanding their semantic type.
[RFC 6962 §§3.3, 4.6][rfc]

Static CT retains the RFC submission endpoints and RFC signatures. Its read
API is a distribution change, not the RFC 9162 v2 encoding. The generic tiled
API is broader still: at the examined revision its levels range from `0` to
`63`, whereas Static CT specifies `0` to `5`. Pin and implement the chosen
profile rather than accepting similar-looking endpoints indiscriminately.
[Static CT][static], [tiled API][tiles]

### Determinism and canonical form

RFC 6962's tree commits to the complete encoded leaf, not a normalized
certificate object. Certificates are carried as DER bytes; extension bytes are
included. HTTP JSON ordering is irrelevant to the reconstructed binary
signature input. Identical certificate bytes with different timestamps are
different leaves. [RFC 6962 §§3.2–3.5][rfc]

A [checkpoint][checkpoint] is textual: origin line, canonical decimal tree size
and base64 root, each newline-delimited, followed by note signatures. Static CT
has a special RFC6962 note-signature mapping that carries timestamp and the
original tree-head signature, enabling conversion without a private key. That
signature does **not** authenticate the textual origin; Static CT states this
limitation explicitly and prohibits checkpoint extension lines for this
algorithm. Do not assume every note-signature profile signs the same text.
[Static CT, Checkpoints][static]

### Merkleization and content addressing

RFC 6962 defines `MTH(empty) = SHA256(empty)`, leaf hash
`SHA256(0x00 || leaf_bytes)`, and internal hash
`SHA256(0x01 || left_hash || right_hash)`. An uneven tree splits at the largest
power of two **strictly smaller** than its leaf count, without zero-padding
phantom entries. Shape depends on the number of entries, not their byte lengths.
This differs from [BitTorrent v2][bt]'s padded per-file tree and [Bao][bao]'s
byte/chunk geometry. [RFC 6962 §2.1][rfc]

An inclusion proof binds a leaf and index to a root at a specified tree size.
A consistency proof binds two sizes/roots as prefix histories. Neither signs
anything: signatures on trusted tree heads establish log-key accountability.
An SCT is instead a signed promise of incorporation within the maximum merge
delay, not an inclusion proof. Even valid signatures and local proofs do not
exclude split views without exchanged checkpoints, gossip or witness policy.
[RFC 6962 §§2.1–3.5, 5, 7.3][rfc]

### Hostile-input safety

Bounds-check every nested vector and reject lengths that escape their parent
or exceed resource budgets. Treat network chunks as short reads, not whole TLS
structures. Bound JSON/base64 expansion and HTTP decompression independently;
Static CT mandates support for gzip data tiles, so compressed length alone is
not an adequate memory bound. [RFC grammar][rfc], [Static CT][static]

Verify root length, tree-head signature, freshness policy and tree size before
letting untrusted sizes drive fetch plans. Proof validation must check index,
size and exact path geometry, not merely hash all provided siblings until a
value matches. Authenticate tile contents against a checkpoint, not their URL
or cache lifetime. Re-check consistency when advancing a checkpoint.
[RFC 6962 §§2.1, 5][rfc], [Static CT partial tiles][static]

The examined TLS test suite explicitly notes that `maxval` determines enum
**width**, not accepted enum values: its vector accepts `32` with `maxval:18`.
Therefore a generic binary codec's successful decode is not evidence that a
protocol discriminator or signature algorithm is semantically allowed.
[TLS tests][tls-tests]

### Describing foreign formats

CT is a useful counterexample to treating every binary format as native-memory
records. Fixed-width big-endian fields coexist with byte-counted vectors and
selector-dependent bodies. A [Flat-style reader][flat] can describe fixed
prefixes and bounded selected regions, but cryptographic preimage construction,
DER semantics, proof validation and log trust policy remain outside its layout
proof. The [Go TLS codec][tls-tests] demonstrates foreign-format annotations,
not zero-copy or alignment guarantees.

### Implementation and performance evidence

The examined [Go implementation][serialization] has separate serializers for
SCT and tree-head signature inputs. Its [TLS vectors][tls-tests] provide precise
independent byte oracles; they were read, not executed locally. No public log
was queried and no throughput benchmark was run.

Format-level evidence is quantitative without being a benchmark: full hash
tiles are 8192 bytes, each groups eight binary levels, and clients can reuse
immutable tiles across many proof computations. Static delivery trades larger
fetch units and local hash computation for HTTP cache reuse and fewer bespoke
proof endpoints. [Static CT][static], [tiled API][tiles]

#### CI-verified independent framing probe

This small independent probe checks the cited vector's **byte** count and the
RFC's leaf/node preimage prefixes with Phobos SHA-256. It does not execute the
Go codec or verify a certificate, log signature or Merkle proof.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "binary_ct_frame_probe"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.stdio : writeln;

void main() @safe
{
    immutable ubyte[7] vector = [6, 1, 1, 2, 2, 3, 3];
    assert(vector[0] == vector.length - 1);
    assert(vector[0] / ushort.sizeof == 3);
    immutable ubyte[1] emptyLeafPreimage = [0];
    immutable leaf = sha256Of(emptyLeafPreimage[]);
    assert(leaf.toHexString ==
        "6E340B9CFFB37A989CA544E6BB780A2C78901D3FB33738768511A30617AFA01D");
    ubyte[65] nodePreimage;
    nodePreimage[0] = 1;
    nodePreimage[1 .. 33] = leaf[];
    nodePreimage[33 .. $] = leaf[];
    assert(sha256Of(nodePreimage[]) != sha256Of(nodePreimage[1 .. $]));
    assert(sha256Of(nodePreimage[]) != sha256Of([cast(ubyte) 0] ~ nodePreimage[1 .. $]));
    writeln("vector: 6 payload bytes, 3 uint16 elements");
    writeln("empty leaf: ", leaf.toHexString);
    writeln("node preimage: ", nodePreimage.length, " bytes; prefix separation checked");
}
```

```ansi
vector: 6 payload bytes, 3 uint16 elements
empty leaf: 6E340B9CFFB37A989CA544E6BB780A2C78901D3FB33738768511A30617AFA01D
node preimage: 65 bytes; prefix separation checked
```

## Strengths

- Domain-separated tree hashes have explicit exact-byte inputs.
- Signed heads, inclusion and consistency answer different questions cleanly.
- Static tiles support immutable caching and locally computed proofs.
- Unknown opaque leaves can remain verifiable without semantic parsing.

## Weaknesses

- Many layers coexist: JSON/base64, TLS vectors, DER, checkpoints and tile profiles.
- An inclusion proof does not authenticate auxiliary chain material or prevent split views.
- Static CT's legacy tree-head signature mapping leaves the origin unauthenticated.
- Vector framing and enum width do not establish semantic validity or resource safety.

## Key design decisions and trade-offs

| Decision                                         | Rationale                                 | Trade-off                                                |
| ------------------------------------------------ | ----------------------------------------- | -------------------------------------------------------- |
| Prefix leaf/node hashes separately               | Prevent structural reinterpretation       | Every implementation must hash the precise prefixes      |
| Sign timestamp, size and root                    | Make a log's advertised state accountable | Trust keys and freshness remain external policy          |
| Keep auxiliary chains outside leaf commitment    | Keep the authenticated leaf focused       | Auxiliary content needs separate checks                  |
| Serve immutable 256-hash tiles                   | Cache and amortize proof material         | Small proofs can require overfetch and local computation |
| Preserve RFC signatures in Static CT checkpoints | Retain submission/client compatibility    | The mapped signature does not cover checkpoint origin    |

## Sources

- [RFC 6962][rfc] — primary protocol and Merkle definitions.
- [Static CT API][static], [generic tiled API][tiles], [checkpoints][checkpoint] — separate static profiles.
- [Go serialization][serialization], [types][types] and [TLS vectors][tls-tests] — implementation and exact source oracles.

<!-- References -->

[rfc]: https://www.rfc-editor.org/rfc/rfc6962.html
[repo]: https://github.com/google/certificate-transparency-go/tree/fdc03fb9514dac81a11bdc9cf871a96f2ee80691
[serialization]: https://github.com/google/certificate-transparency-go/blob/fdc03fb9514dac81a11bdc9cf871a96f2ee80691/serialization.go
[types]: https://github.com/google/certificate-transparency-go/blob/fdc03fb9514dac81a11bdc9cf871a96f2ee80691/types.go
[tls-tests]: https://github.com/google/certificate-transparency-go/blob/fdc03fb9514dac81a11bdc9cf871a96f2ee80691/tls/tls_test.go
[c2sp]: https://github.com/C2SP/C2SP/tree/2b83ce1818712df2a4bf9b41c1212eda4a6d6376
[static]: https://github.com/C2SP/C2SP/blob/2b83ce1818712df2a4bf9b41c1212eda4a6d6376/static-ct-api.md
[tiles]: https://github.com/C2SP/C2SP/blob/2b83ce1818712df2a4bf9b41c1212eda4a6d6376/tlog-tiles.md
[checkpoint]: https://github.com/C2SP/C2SP/blob/2b83ce1818712df2a4bf9b41c1212eda4a6d6376/tlog-checkpoint.md
[bt]: ./bittorrent-v2.md
[bao]: ./iroh-bao.md
[flat]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
