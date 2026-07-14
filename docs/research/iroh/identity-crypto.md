# Identity & Cryptography

An iroh endpoint's entire identity is a single Ed25519 keypair — the public key _is_ the [`EndpointId`][key] — and the whole security model is that keypair proving itself in an [RFC 7250][rfc7250] raw-public-key [TLS 1.3][rfc8446] handshake carried in QUIC `CRYPTO` frames, with no PKI, no X.509, and (unlike iroh 0.x) no separate Diffie-Hellman key derived from the identity.

| Field                 | Value                                                                                                                                                                                                                                      |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Crate(s)              | [`iroh-base`][docs-iroh-base] (`key.rs`), [`iroh`][docs-iroh] (`iroh/src/tls/*`), plus signing surfaces in `iroh-relay`, `iroh-dns`, `iroh-docs`                                                                                           |
| Version               | iroh workspace **v1.0.1** (commit `22cac742ca`); `iroh-docs` 0.101.0                                                                                                                                                                       |
| Repository            | [`n0-computer/iroh`][repo]                                                                                                                                                                                                                 |
| Documentation         | [docs.rs/iroh-base][docs-iroh-base] · [docs.rs/iroh][docs-iroh]                                                                                                                                                                            |
| ALPN(s)               | None owned here — ALPN is per-protocol (see [`endpoint.md`][endpoint]); the TLS layer only _requires_ that a negotiated ALPN exist post-handshake (`AuthenticationError::NoAlpn`, [`connection.rs`][connection])                           |
| Approx. size (LoC)    | ≈1,200 — `iroh-base/src/key.rs` (564) + `iroh/src/tls/*` (`tls.rs` 142, `verifier.rs` 211, `resolver.rs` 100, `name.rs` 63, `misc.rs` 125). **Excludes** the [TLS 1.3 engine itself][quic] (`rustls`, via [`noq`][quic])                   |
| Category              | Foundations                                                                                                                                                                                                                                |
| Upstream spec / draft | [RFC 8032][rfc8032] (Ed25519), [RFC 7250][rfc7250] (raw public keys), [RFC 8446][rfc8446] (TLS 1.3), [RFC 9001][rfc9001] (QUIC-TLS), [RFC 4648][rfc4648]/[RFC 5155][rfc5155] (base32), [RFC 2606][rfc2606] (`.invalid`), [BEP 0044][bep44] |

> [!NOTE]
> This page owns **cryptography and identity**. The postcard byte layouts of tickets and
> `EndpointAddr` live in [Wire Formats & Serialization][wire]; the QUIC/TLS key schedule,
> Retry-token wire format, 0-RTT gating, and multipath AEAD nonce live in
> [QUIC Transport (`noq`)][quic]; pkarr address publishing lives in [Address Lookup][discovery].
> Those are cross-linked, not duplicated here.

---

## Overview

### What it solves

Every iroh endpoint needs a globally-unique, self-certifying name that doubles as the root of
trust for all its connections. iroh 1.0 collapses **four** concerns onto a single Ed25519
keypair:

1. **Identity** — the 32-byte public key is the [`EndpointId`][key] (`pub type EndpointId = PublicKey`), a globally-unique name that requires no registry or CA.
2. **Addressing** — an `EndpointAddr { id, addrs }` is the id plus a set of hints about where to reach it (see [Wire Formats & Serialization][wire]); dialing by bare id is legal.
3. **Authentication** — during the QUIC handshake each side proves possession of its secret key by signing the TLS 1.3 `CertificateVerify` transcript; the connection is thereby bound to the dialed id.
4. **Transport security** — the authenticated handshake keys a TLS 1.3 session, so every byte after the handshake is confidential and integrity-protected to that specific peer.

The crypto surface a port must reproduce is deliberately tiny and **fixed**: Ed25519
(keygen/sign/`verify_strict`) with its internal SHA-512 and Edwards-point decompression,
[BLAKE3][blake3] (`derive_key` and `keyed_hash`) for two auxiliary MACs, and a CSPRNG. There is
**no X25519, no ECDH, no HKDF, and no Ed25519→Curve25519 conversion** anywhere in the workspace
(a grep for `to_montgomery`, `crypto_box`, `x25519`, `shared_secret`, `diffie` returns only an
unrelated test shim). This is the single largest change from the 0.x era: the old **DISCO**
sealed-box side-protocol (which converted node keys to Curve25519 for NaCl `crypto_box`) is
gone, replaced by QUIC-native NAT traversal that rides the same authenticated TLS session (see
[NAT Traversal & Address Discovery][nat]).

The identity model also drives a total rename cascade versus 0.x: `NodeId`→`EndpointId`,
`NodeAddr`→`EndpointAddr`, `NodeTicket`→`EndpointTicket`. Old `node…` ticket strings are
unparseable by 1.0; there is no migration shim in the pinned tree.

### Design philosophy

The crate root states the identity thesis directly ([`iroh-base/src/key.rs`][key]):

> _"Each endpoint in iroh has a unique identifier created as a cryptographic key. This can be
> used to globally identify an endpoint. Since it is also a cryptographic key it is also the
> mechanism by which all traffic is always encrypted for a specific endpoint only."_

Two naming conventions follow from that dual role, also fixed in the doc comment: use the name
`PublicKey` "when performing cryptographic operations, but use `EndpointId` when referencing an
endpoint" — they are the identical type ([`key.rs`][key]).

The security layer is equally minimal and equally explicit. The TLS module opens with a
one-mechanism statement ([`iroh/src/tls.rs`][tls]):

> _"Currently there is one mechanism available: - Raw Public Keys, using the TLS extension
> described in [RFC 7250]"_

There is **no X.509 certificate at all** on the peer-to-peer plane. iroh 0.x carried a
self-signed X.509 cert with a libp2p extension binding the host key; 1.0 sends a bare 44-byte
Ed25519 `SubjectPublicKeyInfo` (SPKI) in place of a certificate, and the verifiers never build a
chain, check an expiry, or consult revocation — raw public keys do not expire. The design
consequence is that the entire trust decision reduces to a single byte-equality: _does the raw
key the peer presented equal the key I dialed?_

> [!NOTE]
> The doc-comment claim that the key "is the mechanism by which all traffic is always
> encrypted" is true at the level of _authentication_, not key agreement. In 1.0 the session
> secret comes from the TLS 1.3 ephemeral key exchange (X25519 by default, optionally the
> `X25519MLKEM768` hybrid). The Ed25519 identity key **signs** the handshake transcript; it
> never performs Diffie-Hellman. Confidentiality "to a specific endpoint only" is the product
> of that signature plus the SNI/SPKI binding described below.

---

## How it works

### The one keypair: `PublicKey`, `EndpointId`, `SecretKey`, `Signature`

[`PublicKey`][key] is a `#[repr(transparent)]` newtype over
`curve25519_dalek::edwards::CompressedEdwardsY` — exactly the 32-byte compressed Edwards
y-coordinate. Construction is the only place a curve check happens: `from_bytes` calls
`VerifyingKey::from_bytes`, which decompresses the point and rejects invalid encodings, then
stores the canonicalised compressed bytes. After that the type is a plain 32-byte value —
`Eq`, `Ord`, `Hash`, `Borrow<[u8; 32]>`, `Deref<Target = [u8; 32]>` all operate on the raw
bytes — and it re-derives a `VerifyingKey` on demand with an `expect("already verified")`
because the point-validity invariant holds from construction onward.

```rust
// iroh-base/src/key.rs — the whole identity surface
#[derive(Clone, Copy, PartialEq, Eq)]
#[repr(transparent)]
pub struct PublicKey(CompressedEdwardsY);       // 32-byte compressed y-coordinate

pub type EndpointId = PublicKey;                 // same type, addressing-context name
pub const LENGTH: usize = ed25519_dalek::PUBLIC_KEY_LENGTH; // 32

#[derive(Clone, zeroize::ZeroizeOnDrop)]
pub struct SecretKey(SigningKey);                // 32-byte seed, scrubbed on drop

#[derive(Copy, Clone, Eq, PartialEq)]
pub struct Signature(ed25519_dalek::Signature);  // 64 bytes
```

Verification funnels through `PublicKey::verify`, and it is `verify_strict`, not the permissive
`verify` ([`key.rs`][key]):

```rust
// iroh-base/src/key.rs
pub fn verify(&self, message: &[u8], signature: &Signature) -> Result<(), SignatureError> {
    self.as_verifying_key()
        .verify_strict(message, &signature.0)
        .map_err(|_| SignatureError::new())
}
```

`verify_strict` is load-bearing for interop: it rejects the malleable and small-order /
mixed-order edge cases that plain `verify` accepts. Because the TLS `CertificateVerify` check
routes through exactly this function (via the [`Ed25519Dalek`][verifier] adapter below), a D port
must replicate dalek's `verify_strict` semantics — a canonical-`S` bound plus the cofactorless
group-equation check — or handshakes with iroh peers will disagree on borderline signatures.

[`SecretKey`][key] wraps `ed25519_dalek::SigningKey` and derives `zeroize::ZeroizeOnDrop`. Its
API is small: `public()` derives the `PublicKey` from the verifying key; `generate()` is
`Self::from_bytes(&rand::random())` — 32 random seed bytes from the default `rand` CSPRNG;
`sign(msg)` produces a deterministic Ed25519 `Signature`; `to_bytes()`/`from_bytes()` round-trip
the 32-byte **seed** ("The public part can always be recovered"). There is no key-derivation, no
DH, no Curve25519 conversion.

### String encodings

The identity type is rendered five different ways depending on context; getting each alphabet
exactly right is a hard interop requirement. (The raw postcard byte forms belong to
[Wire Formats & Serialization][wire].)

| Encoding                                        | Alphabet                           | Where used                                                                              | Cite                        |
| ----------------------------------------------- | ---------------------------------- | --------------------------------------------------------------------------------------- | --------------------------- |
| lowercase hex (`HEXLOWER`)                      | `0-9a-f`, 64 chars                 | `Display` / `Debug` of `PublicKey`; JSON serde; the `IROH_SECRET` env var               | [`key.rs`][key]             |
| `BASE32_NOPAD` ([RFC 4648][rfc4648])            | `A-Z2-7`, no pad, 52 chars         | `FromStr` alternative input (case-insensitive); ticket string bodies (see [wire][wire]) | [`key.rs`][key]             |
| z-base-32                                       | `ybndrfg8ejkmcpqxot1uwisza345h769` | `to_z32`/`from_z32` — pkarr / DNS domain labels only                                    | [`key.rs`][key]             |
| `BASE32_DNSSEC` ([RFC 5155][rfc5155] base32hex) | `0-9a-v` lowercase, 52 chars       | the TLS server name (SNI), see below                                                    | [`name.rs`][name]           |
| `BASE64URL_NOPAD`                               | url-safe base64, no pad            | relay `ClientAuth` HTTP header (see [relay][relay])                                     | [`handshake.rs`][handshake] |

`Display` is **lowercase hex** (not the 0.x base32), so human-readable serde emits 64 hex
characters. `FromStr` accepts **either** hex (when the input length is 64) or `BASE32_NOPAD`
(uppercased first, `decode_len == 32`) through the shared `decode_base32_hex` helper —
`SecretKey::from_str` uses the same helper on the seed. `fmt_short()` renders the first 5 bytes
as 10 hex chars for logs and is used at ~70 call sites in `iroh/src`.

### The RFC 7250 raw-public-key handshake

The "certificate" iroh sends is a bare DER `SubjectPublicKeyInfo`: a constant 12-byte prefix
plus the 32 raw key bytes, 44 bytes total. It is built once per endpoint by
`ResolveRawPublicKeyCert::new` via `rustls::sign::public_key_to_spki(&alg_id::ED25519, pk_bytes)`
([`resolver.rs`][resolver]) and served unconditionally by both the `ResolvesClientCert` and
`ResolvesServerCert` implementations, each declaring `only_raw_public_keys() == true` (which makes
`rustls` advertise `client_certificate_type`/`server_certificate_type = RawPublicKey(0x02)`).

```text
SPKI "certificate" — 44 bytes, DER SubjectPublicKeyInfo
30 2a                     SEQUENCE, 42 bytes
   30 05                  SEQUENCE (AlgorithmIdentifier), 5 bytes
      06 03 2b 65 70      OID 1.3.101.112  (id-Ed25519)
   03 21 00               BIT STRING, 33 bytes = 1 unused-bits byte (00) + 32 key bytes
   <32 raw public-key bytes>
--------------------------------------------------------------
constant 12-byte prefix:  30 2a 30 05 06 03 2b 65 70 03 21 00
```

Signing is narrowly scoped: [`IrohSecretKey`][resolver] implements `rustls::sign::SigningKey` +
`Signer`, `choose_scheme` returns `Some` only if the peer offered `SignatureScheme::ED25519`, and
`Signer::sign` returns the raw 64-byte Ed25519 signature over the TLS transcript. The signature
scheme on the wire is therefore always `ED25519` (`0x0807`); TLS 1.2 is disabled outright
(`PROTOCOL_VERSIONS = [&rustls::version::TLS13]`).

**The client's identity check** ([`ServerCertificateVerifier`][verifier]) is the crux of the whole
model, and it is a byte comparison, not a chain build:

```rust
// iroh/src/tls/verifier.rs — verify_server_cert (abridged)
let ServerName::DnsName(dns_name) = server_name else { return Err(UnsupportedNameType) };
let Some(remote_peer_id) = super::name::decode(dns_name.as_ref())   // SNI -> expected EndpointId
    else { return Err(InvalidCertificate(NotValidForName)) };
if !intermediates.is_empty() { return Err(InvalidCertificate(UnknownIssuer)) }

let end_entity_as_spki = SubjectPublicKeyInfoDer::from(end_entity.as_ref());
let remote_public_spki  = public_key_to_spki(&alg_id::ED25519, remote_peer_id.as_bytes());
if remote_public_spki != end_entity_as_spki {                        // whole-buffer equality
    return Err(InvalidCertificate(UnknownIssuer));
}
Ok(ServerCertVerified::assertion())
```

`_ocsp_response` and `_now` are ignored. The `ServerName` compared against is the name the
**client itself** passed to `connect_with` — so the binding is local intent, not attacker-supplied
data. A man-in-the-middle presenting a different raw key fails the equality; a peer presenting the
right key but not proving possession fails the separate `CertificateVerify` signature check
(delegated to `verify_tls13_signature_with_raw_key` over the `ED25519_DALEK`-only algorithm set,
which parses the SPKI as a `webpki` raw-public-key entity and runs `PublicKey::verify`).

**The SNI carries the dialed id.** `tls::name::encode` produces `"{BASE32_DNSSEC(id)}.iroh.invalid"`
([`name.rs`][name]) — 52 base32hex characters plus the suffix. The reasons are documented on the
module and are worth quoting because they explain an otherwise surprising choice:

> _"We used to use a constant "localhost" for the TLS server name - however, that affects 0-RTT
> and would put all of the TLS session tickets we receive into the same bucket in the TLS session
> ticket cache. So we choose something that'd dependent on the EndpointId. We cannot use hex to
> encode the EndpointId, as that'd encode to 64 characters, but we only have 63 maximum per DNS
> subdomain. Base32 is the next best alternative."_ — [`iroh/src/tls/name.rs`][name]

Hex would exceed the 63-char DNS label limit; the `.invalid` TLD ([RFC 2606][rfc2606]) never
resolves; the `iroh` middle label is noted as possibly-removable in future. The SNI thus does
double duty: it is the authorization datum the client checks the SPKI against, **and** the cache
key that buckets 0-RTT session tickets and NEW_TOKEN entries per peer. Snapshot for the all-zero
secret key: `7dl2ff6emqi2qol3l382krodedij45bn3nh479hqo14a32qpr8kg.iroh.invalid`.

**Mutual auth is mandatory but asymmetric in what it checks.** The server's
[`ClientCertificateVerifier`][verifier] returns `offer_client_auth() == true`, so client
authentication is required, yet `verify_client_cert` checks essentially nothing:

> _"Beyond checking for no intermediates, we don't check the client certificate. The actual
> signatures are already verified - this ensures authentication."_ — [`iroh/src/tls/verifier.rs`][verifier]

The server does not know _who_ connected until after the handshake, when
`remote_id_from_noq_conn` downcasts `Connection::peer_identity()` to a one-element
`Vec<CertificateDer>` and parses it with `ed25519_dalek::pkcs8::DecodePublicKey::from_public_key_der`
([`connection.rs`][connection], covered from the connection side in [`endpoint.md`][endpoint]).

### Relay challenge signing

The identity key is exercised a second way, outside TLS, when authenticating to a relay
([`iroh-relay/src/protos/handshake.rs`][handshake]). The server sends 16 random challenge bytes;
the client does **not** sign them directly — it signs a BLAKE3-derived key:

```rust
// iroh-relay/src/protos/handshake.rs
const DOMAIN_SEP_CHALLENGE: &str = "iroh-relay handshake v1 challenge signature";

fn message_to_sign(&self) -> [u8; 32] {
    blake3::derive_key(DOMAIN_SEP_CHALLENGE, &self.challenge)   // then SecretKey::sign(..)
}
```

The rationale is domain separation against a signing oracle:

> _"We're signing a key instead of the direct challenge. This gives us domain separation
> protecting from multiple possible attacks… Assume a malicious relay. If the protocol required
> the client to sign the challenge directly, this would allow the relay to obtain an arbitrary
> 16-byte signature, if it maliciously choses the challenge."_ — [`handshake.rs`][handshake]

The response is a `ClientAuth { public_key, signature }` postcard struct. A TLS-fast-path variant
`KeyMaterialClientAuth` instead signs the first 16 bytes of TLS-exported keying material
(exporter context = the client's own public key), sent as a `BASE64URL_NOPAD` HTTP header. Full
relay-protocol framing is in [The Relay Protocol][relay].

### Auxiliary keyed hashing: reset tokens

BLAKE3 appears once more in the identity-adjacent auth surface. QUIC stateless-reset tokens use
[`Blake3HmacKey`][misc] — `blake3::keyed_hash` with a per-process random 32-byte key, verified in
constant time via `ctutils::CtEq`:

```rust
// iroh/src/tls/misc.rs — the reset-token MAC
fn sign(&self, data: &[u8], out: &mut [u8]) { out.copy_from_slice(blake3::keyed_hash(&self.0, data).as_slice()) }
fn verify(&self, data: &[u8], sig: &[u8]) -> Result<(), CryptoError> {
    if blake3::keyed_hash(&self.0, data).as_slice().ct_eq(sig).to_bool() { Ok(()) } else { Err(CryptoError) }
}
```

`noq` truncates the 32-byte MAC of a connection id to the 16-byte reset token. The choice of
keyed BLAKE3 over HMAC-SHA256 means a port needs BLAKE3's keyed mode anyway (it is already
load-bearing in [blobs][blobs] / [`bao-tree`][bao]). The separate address-validation Retry /
NEW_TOKEN tokens are AEAD-sealed with the TLS provider's cipher rather than BLAKE3; their wire
format and validation state machine belong to [QUIC Transport][quic].

### Post-quantum key exchange

Post-quantum protection is **pure provider configuration**, not iroh code: replace the `kx_groups`
on an `aws-lc-rs` provider with `[X25519MLKEM768]` for PQ-only, or prepend it before
`X25519`/`SECP256R1`/`SECP384R1` for PQ-preferred ([`iroh/examples/pq-only-key-exchange.rs`][pq]).
Two constraints: `ring` has no ML-KEM (its group list is `X25519, SECP256R1, SECP384R1`), so
`tls-aws-lc-rs` is required; and n0's public relay/discovery infrastructure "does not support PQ
key exchange yet", so a PQ-only endpoint cannot reach them. Because this only touches the
`CryptoProvider`, it changes nothing about the Ed25519 **identity** — the id, the SPKI, the
`CertificateVerify` signature scheme are all unchanged.

---

## Analysis

### Wire format & framing

This subsystem defines only a few byte layouts of its own; the bulk of iroh's wire formats —
`EndpointAddr`, the three ticket kinds, postcard framing rules — are owned by
[Wire Formats & Serialization][wire] and are not repeated here. What crypto contributes:

- **The 44-byte SPKI "certificate"** (byte layout above): a constant 12-byte DER prefix
  (`30 2a 30 05 06 03 2b 65 70 03 21 00`) + 32 key bytes, compared whole-buffer. A D port builds
  it by constant concatenation and never parses ASN.1 for the peer id beyond stripping the prefix.
- **The SNI string**: `BASE32_DNSSEC(id) ++ ".iroh.invalid"`, 65 characters, a DNS name.
- **The `Signature`** on the wire is 64 raw bytes (`serialize_tuple(64)` for serde, a raw
  64-byte flight in TLS); **`PublicKey`** is 32 raw bytes (fixed array, no length prefix).
- **Relay `ClientAuth` / `KeyMaterialClientAuth`** are postcard structs
  `{ public_key: PublicKey, signature: [u8; 64], (+ key_material_suffix: [u8; 16]) }`,
  `BASE64URL_NOPAD`-encoded in an HTTP header (detailed in [relay][relay]).

The one framing subtlety intrinsic to identity is that `CertificateVerify` signs the TLS 1.3
handshake **transcript**, not a naked message — so the sign/verify callbacks receive the exact
bytes the TLS engine computes, and a D implementation must feed `verify_strict` the identical
context string + transcript hash the engine constructs (a [QUIC Transport][quic] concern that the
identity layer only supplies the primitive for).

### Cryptography & identity

The exact primitive set a D port needs for iroh 1.0 identity, and nothing more:

| Primitive                                         | Used for                                                                                | Cite                               |
| ------------------------------------------------- | --------------------------------------------------------------------------------------- | ---------------------------------- |
| Ed25519 keygen (seed → scalar/prefix via SHA-512) | `SecretKey::generate` / `from_bytes`, `public()`                                        | [`key.rs`][key]                    |
| Ed25519 deterministic sign                        | TLS `CertificateVerify`, relay challenge, pkarr `SignedPacket`, docs entries            | [`key.rs`][key]                    |
| Ed25519 `verify_strict`                           | every signature check (`PublicKey::verify`) — **strict** semantics required for interop | [`key.rs`][key]                    |
| Edwards point decompression + validity            | `PublicKey::from_bytes` / deserialize — the type invariant                              | [`key.rs`][key]                    |
| SHA-512                                           | internal to Ed25519 (nonce + challenge hashing per [RFC 8032][rfc8032])                 | [`key.rs`][key]                    |
| BLAKE3 `derive_key`                               | relay challenge domain separation (`DOMAIN_SEP_CHALLENGE`)                              | [`handshake.rs`][handshake]        |
| BLAKE3 `keyed_hash`                               | QUIC stateless-reset token MAC (`Blake3HmacKey`)                                        | [`misc.rs`][misc]                  |
| CSPRNG                                            | `SecretKey::generate`, reset-token key, relay challenge, token nonces                   | [`key.rs`][key], [`misc.rs`][misc] |

Conspicuously **absent**: X25519 / ECDH, HKDF, and any Ed25519→Curve25519 conversion. HKDF and
X25519 do appear in iroh's dependency closure, but only inside the TLS 1.3 key schedule that lives
in the `rustls` `CryptoProvider` (`ring` or `aws-lc-rs`) — not in iroh's own identity code. If a D
port pairs its own TLS engine with hand-rolled AEAD/HKDF (see [QUIC Transport][quic]), the
**identity** module still needs only the eight rows above.

Crypto backend pins are exact release candidates, a notable operational fact: `ed25519-dalek`
is `=3.0.0-rc.0` and `curve25519-dalek` is `=5.0.0-rc.0` ([`iroh-base/Cargo.toml`][base-cargo]).
`iroh-base` enables the dalek features `serde, rand_core, zeroize`; `iroh` additionally enables
`pkcs8, pem` (only DER `from_public_key_der` was found in use — the PEM feature may be spillover).

### State machines & lifecycle

The identity subsystem is deliberately **state-free** — pure value types and codecs. There are
only three state-machine-shaped elements, and two of them belong to sibling pages:

1. **The `PublicKey` validity invariant.** Every constructor (`from_bytes`, `TryFrom<&[u8]>`,
   deserialize) must pass point decompression, after which "always a valid curve point" holds and
   `as_verifying_key` relies on it with an `expect`. This is an invariant, not a transition.
2. **Key lifecycle in an endpoint.** `Endpoint::builder().secret_key(..)` is optional; `bind()`
   falls back to `SecretKey::generate` ([`endpoint.rs`][endpoint-src]). Apps such as `dumbpipe` /
   `sendme` read a hex secret from `IROH_SECRET` or generate and print one. Once bound, the key is
   an immutable field of the endpoint for its lifetime.
3. **The TLS handshake pump** _uses_ this subsystem's sign/verify as callbacks but is itself a
   `rustls`/`noq` state machine (handshake keys → 1-RTT keys → key update; 0-RTT accept/reject).
   That machine is documented in [QUIC Transport][quic] and [Endpoint & Protocol Router][endpoint].

No timers, no I/O-driven transitions originate in identity/crypto. (The pkarr publisher's
monotonic-timestamp CAS loop is a [discovery][discovery] concern.)

### Dependencies & coupling

| Crate                     | Pin                   | Role                                                                                                                   |
| ------------------------- | --------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `ed25519-dalek`           | `=3.0.0-rc.0` (exact) | **The identity algorithm.** keygen, `Signer::sign`, `verify_strict`, `VerifyingKey::from_bytes`, `from_public_key_der` |
| `curve25519-dalek`        | `=5.0.0-rc.0` (exact) | Storage type only: `CompressedEdwardsY`; no point arithmetic called directly                                           |
| `blake3`                  | 1.x                   | `derive_key` (relay challenge) + `keyed_hash` (reset tokens)                                                           |
| `zeroize`                 | 1.9                   | `SecretKey: ZeroizeOnDrop`                                                                                             |
| `rand` / `getrandom`      | 0.10 / 0.4            | CSPRNG for keygen and nonces (`wasm_js` backend for browsers)                                                          |
| `data-encoding` (+ macro) | 2.6 / 0.1.19          | HEXLOWER, BASE32_NOPAD, BASE32_DNSSEC, BASE64URL_NOPAD, the z-base-32 alphabet                                         |
| `rustls` + `webpki_types` | 0.23-line             | The TLS engine; identity provides the RPK resolver/verifier plug-ins and the `alg_id::ED25519` SPKI helper             |
| `ctutils` (`CtEq`)        | —                     | constant-time MAC compare                                                                                              |

Coupling runs outward from a small core. The **identity binding contract** (SPKI equality +
`ED25519` `CertificateVerify` + mandatory client auth) is defined in `iroh/src/tls`, but the TLS
1.3 machinery it plugs into is `rustls`, reached through [`noq`][quic]. The **same** `SecretKey`
is reused verbatim by three other subsystems with zero extra crypto: relay auth ([relay][relay]),
pkarr publishing ([discovery][discovery]), and iroh-docs, whose `Author` and `NamespaceSecret`
are thin wrappers around `iroh::SecretKey` that sign/verify with the identical primitives
([`iroh-docs/src/keys.rs`][docs-keys]; see [Document Sync][docs-sync]). A D crypto layer that
implements the eight primitives above supports **all four** signing surfaces.

### Concurrency & I/O model

The identity/crypto layer spawns nothing, awaits nothing, and owns no timers or channels. Its only
shared state is immutable-and-`Arc`'d, present purely to satisfy `rustls`'s ownership model:

| Primitive                                                           | Where                                      | Why it exists                                                                                     |
| ------------------------------------------------------------------- | ------------------------------------------ | ------------------------------------------------------------------------------------------------- |
| `Arc<ResolveRawPublicKeyCert>` / `Arc<CertifiedKey>`                | [`tls.rs`][tls], [`resolver.rs`][resolver] | one signed identity shared across all sessions; **Arc pointer identity** matters for rustls 0-RTT |
| `Arc<ServerCertificateVerifier>` / `Arc<ClientCertificateVerifier>` | [`tls.rs`][tls]                            | immutable unit structs; also pointer-compared by rustls across 0-RTT sessions                     |
| `Arc<dyn ClientSessionStore>` = `ClientSessionMemoryCache(256)`     | [`tls.rs`][tls]                            | interior-`Mutex` LRU of TLS tickets keyed by the per-peer SNI                                     |
| `Arc<Mutex<LruCache<PublicKey, ()>>>` (`KeyCache`)                  | `iroh-relay/src/key_cache.rs`              | dedupe expensive point decompression when a relay parses millions of repeated keys                |

The rationale for the `Arc` pointer-identity constraint is documented on `TlsConfig`
([`tls.rs`][tls]): _"the `server_verifier` and `client_verifier` Arc pointers are checked to be
the same between different TLS session calls with 0-RTT data in rustls."_ This is an artifact of
rustls's config-identity checks, not an inherent concurrency requirement.

### Mapping to event-horizon

Everything in this subsystem is `@safe pure nothrow @nogc`-friendly value code — no fibers,
scopes, `Scope.spawn`, `race`, or `JoinHandle` are needed anywhere (contrast the [tokio
inventory][tokio-async]). The two places a **capability** should be threaded in are the CSPRNG and
(for token/ticket freshness) the clock — matching the event-horizon capability model of DbI traits
with deterministic test doubles ([SPEC][eh-spec]).

`PublicKey`/`EndpointId` map to a struct over `ubyte[32]` with a validated-invariant constructor
returning [`Expected!`][eh-spec]:

```rust
// iroh-base/src/key.rs (Rust, verbatim)
#[repr(transparent)]
pub struct PublicKey(CompressedEdwardsY);
pub type EndpointId = PublicKey;

pub fn from_bytes(bytes: &[u8; 32]) -> Result<Self, KeyParsingError> {
    let key = VerifyingKey::from_bytes(bytes).map_err(|_| e!(KeyParsingError::InvalidKeyData))?;
    Ok(Self(CompressedEdwardsY(key.to_bytes())))
}
```

```d
// proposed / sketch — validated 32-byte ed25519 point; the invariant holds post-construction
struct PublicKey
{
    private ubyte[32] _compressed;   // CompressedEdwardsY y-coordinate

    // Point-decompression check is the only fallible path; `verify_strict` domain.
    static Expected!(PublicKey, KeyParsingError) fromBytes(const ubyte[32] bytes)
        @safe pure nothrow @nogc;

    bool verify(scope const(ubyte)[] message, in Signature sig) const
        @safe nothrow @nogc;         // MUST match dalek verify_strict

    // lowercase hex, staged through sparkles.base.text.writers (no GC)
    void toString(Writer)(ref Writer w) const;
}
alias EndpointId = PublicKey;
```

`SecretKey` has no direct D idiom for `ZeroizeOnDrop`; the port holds the seed in a non-GC array,
scrubs it in the destructor, and never routes the seed through a GC-allocated hex string (the
`IROH_SECRET` decode must land in a scratch static array). The RNG becomes a capability so a
`TestRng` double gives deterministic keygen:

```rust
// iroh-base/src/key.rs (Rust, verbatim)
#[derive(Clone, zeroize::ZeroizeOnDrop)]
pub struct SecretKey(SigningKey);
pub fn generate() -> Self { Self::from_bytes(&rand::random()) }   // global CSPRNG
```

```d
// proposed / sketch — seed off the GC heap; entropy is a capability, not a global
struct SecretKey
{
    private ubyte[32] _seed;         // ed25519 seed; never touches the GC

    // Rng is a DbI capability (isRng); attributes inferred on the template.
    static SecretKey generate(Rng)(ref Rng rng) if (isRng!Rng);

    PublicKey public_() const @safe nothrow @nogc;                 // SHA-512 expand + basepoint mul
    Signature sign(scope const(ubyte)[] msg) const @safe nothrow @nogc;

    ~this() @trusted nothrow @nogc { volatileScrub(_seed[]); }     // no ZeroizeOnDrop in D
}
```

Further mapping notes:

- **All five `Arc`s in `TlsConfig` collapse** under the `single` topology to plain fields of the
  endpoint struct; `ClientSessionMemoryCache`, `TokenMemoryCache`, and the relay `KeyCache` become
  plain `SmallBuffer`-backed LRUs with no `Mutex`. The rustls "same Arc pointer across 0-RTT
  sessions" constraint simply disappears — it never applied to a single-threaded owner.
- **Encoders** (hex, two base32 alphabets, z-base-32, base64url) are all table-driven codecs with
  a computable max output size; implement once with the alphabet as a template/DbI parameter and
  stage into a `SmallBuffer` (`⌈8n/5⌉` for base32), keeping `toString` allocation-free.
- **No `spawn_blocking` substitute is needed.** Ed25519 sign/verify and BLAKE3 are microsecond
  scale; running them inline on the loop fiber is fine, which matters because event-horizon has
  **no** thread pool (flagged in [`d-architecture-migration.md`][migration]).
- **`verify_strict` is the one irreducible interop risk.** The exact rejection rules live in
  `ed25519-dalek 3.0.0-rc.0` and are not vendored in the pinned tree; a D port must extract them
  from dalek to stay handshake-compatible.
- **The TLS 1.3 engine is the big missing piece**, not part of identity per se: a sans-I/O state
  machine that the D port implements as a plain struct owned by the connection fiber, fed byte
  slices from the QUIC driver. It plugs into this subsystem only via the sign/verify callbacks and
  the SPKI helper. Its full feature list and D shape are in [QUIC Transport][quic] and
  [D Architecture Migration][migration].

---

## Strengths

- **Radically small trust model.** One keypair; no CA, no chain, no expiry, no revocation. The
  entire server-auth decision is a 44-byte buffer equality plus one Ed25519 `verify_strict`.
- **Minimal, fixed crypto surface.** Ed25519 + SHA-512 + BLAKE3 + a CSPRNG covers all four signing
  surfaces (TLS, relay, pkarr, docs). No X25519/ECDH/HKDF in iroh's own code.
- **Self-certifying names.** `EndpointId` = `PublicKey` means the address _is_ the verification
  key; there is no separate binding step to spoof.
- **0-RTT-aware by construction.** Encoding the dialed id into the SNI keys the ticket cache and
  NEW_TOKEN store per peer, avoiding cross-peer ticket pollution — a subtle but deliberate win.
- **PQ-ready without touching identity.** `X25519MLKEM768` is a one-line provider swap; the id and
  its signatures are unchanged.
- **Domain-separated auxiliary signatures.** Signing `derive_key(DOMAIN_SEP, challenge)` rather
  than the raw challenge closes a signing-oracle attack from a malicious relay.

## Weaknesses

- **Release-candidate crypto pins.** `ed25519-dalek =3.0.0-rc.0` and `curve25519-dalek =5.0.0-rc.0`
  are exact-pinned RCs; a shipping 1.0 depends on pre-release cryptography.
- **Interop hinges on `verify_strict`'s edge-case rules**, which are defined only in dalek's
  sources — a re-implementer must replicate them precisely or silently diverge on malleable /
  small-order signatures.
- **`SecretKey` inside a `DocTicket::Write` is a bearer credential.** A write ticket embeds a raw
  32-byte namespace secret in a copy-pasteable string (see [Document Sync][docs-sync]); tickets are
  secrets, not just addresses.
- **No forward secrecy _from the identity key_ is even conceptually available**; all confidentiality
  rests on the TLS ephemeral exchange, so a broken TLS provider is total — the identity layer
  offers no defence in depth beyond authentication.
- **Server-side SNI is unchecked against the server's own id.** The server serves its single key to
  any SNI and never validates `HandshakeData::server_name`; correctness relies entirely on the
  client's local comparison.
- **`.invalid` SNI is opaque to standard tooling.** Packet captures and TLS debuggers see a
  synthetic name that no resolver understands; operators must know the base32hex→id decoding.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                                   | Trade-off                                                                                         |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| One Ed25519 keypair is identity + addressing + auth               | Self-certifying names; no registry/CA; smallest possible trust root                         | The id can never rotate without becoming a different endpoint; key compromise is total            |
| RFC 7250 raw public keys, no X.509 on the p2p plane               | No parsing, expiry, chain-building, or revocation; a 44-byte SPKI + one signature           | Loses X.509 tooling/interop; server auth is a bespoke byte-equality, not a standard PKI path      |
| SNI encodes the dialed id (`{b32}.iroh.invalid`)                  | Keys 0-RTT tickets and NEW_TOKENs per peer; carries authorization without a wire round-trip | Synthetic, tooling-opaque name; 52-char base32hex chosen only to fit the 63-char DNS label limit  |
| `verify_strict`, not `verify`                                     | Rejects malleable / small-order signatures; safer and unambiguous                           | Re-implementers must replicate dalek's exact strict rules for handshake interop                   |
| BLAKE3 `derive_key` / `keyed_hash` for aux MACs (not HMAC-SHA256) | Domain separation for free; reuses BLAKE3 already needed by blobs                           | A second hash family in the stack; reset tokens truncate a 32-byte MAC to 16 bytes                |
| Drop DISCO / x25519; NAT-traversal auth rides QUIC-TLS            | One authenticated channel; no separate sealed-box key or conversion                         | Loses the pre-handshake authenticated side-channel 0.x had; everything depends on the TLS session |
| Mandatory but check-nothing client auth                           | Cheap mutual possession proof; id learned post-handshake from `peer_identity()`             | The server cannot gate on identity _during_ the handshake — only afterward                        |
| Exact-pinned RC dalek crates                                      | Track the latest Ed25519 API/perf before dalek 3.0/5.0 final                                | A production release depends on pre-release cryptography; upgrades may churn                      |

---

## Sources

- [`iroh-base/src/key.rs`][key] — `PublicKey`/`EndpointId`/`SecretKey`/`Signature`, `verify_strict`, all encodings
- [`iroh-base/Cargo.toml`][base-cargo] — exact dalek pins + features
- [`iroh/src/tls.rs`][tls] — `TlsConfig`, RFC 7250 statement, `DEFAULT_MAX_TLS_TICKETS`
- [`iroh/src/tls/verifier.rs`][verifier] — server/client verifiers, `Ed25519Dalek` adapter
- [`iroh/src/tls/resolver.rs`][resolver] — `ResolveRawPublicKeyCert`, `IrohSecretKey`, SPKI construction
- [`iroh/src/tls/name.rs`][name] — `EndpointId` ↔ SNI codec, the `.iroh.invalid` rationale
- [`iroh/src/tls/misc.rs`][misc] — `Blake3HmacKey` reset-token MAC
- [`iroh-relay/src/protos/handshake.rs`][handshake] — relay challenge `derive_key` signing
- [`iroh/src/endpoint/connection.rs`][connection] — post-handshake peer-id extraction
- [`iroh/src/endpoint.rs`][endpoint-src] — `SecretKey` entry point, `bind()` fallback
- [`iroh/examples/pq-only-key-exchange.rs`][pq] — `X25519MLKEM768` provider configuration
- [`iroh-docs/src/keys.rs`][docs-keys] — `Author`/`NamespaceSecret` reuse of `SecretKey`
- [`noq-proto/src/crypto.rs`][noq-crypto] — the `Session` trait a D TLS engine must implement
- Specs: [RFC 8032][rfc8032], [RFC 7250][rfc7250], [RFC 8446][rfc8446], [RFC 9001][rfc9001], [RFC 4648][rfc4648], [RFC 5155][rfc5155], [RFC 2606][rfc2606], [BEP 0044][bep44]
- Related iroh pages: [Concepts & Vocabulary][concepts] · [Wire Formats & Serialization][wire] · [QUIC Transport][quic] · [Endpoint & Protocol Router][endpoint] · [The Multipath Socket][socket] · [NAT Traversal][nat] · [The Relay Protocol][relay] · [Address Lookup][discovery] · [Blobs][blobs] · [`bao-tree`][bao] · [Document Sync][docs-sync] · [D Architecture Migration][migration]
- Cross-tree: [event-horizon SPEC][eh-spec] · [Tokio (async-io)][tokio-async] · [Algebraic effects][alg-eff]

<!-- References -->

[repo]: https://github.com/n0-computer/iroh/tree/22cac742ca
[key]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-base/src/key.rs
[base-cargo]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-base/Cargo.toml
[tls]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/tls.rs
[verifier]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/tls/verifier.rs
[resolver]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/tls/resolver.rs
[name]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/tls/name.rs
[misc]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/tls/misc.rs
[handshake]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/protos/handshake.rs
[connection]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint/connection.rs
[endpoint-src]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint.rs
[pq]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/examples/pq-only-key-exchange.rs
[docs-keys]: https://github.com/n0-computer/iroh-docs/blob/091e8cac47bbc49cdb84b0bfed227cc163b61dfe/src/keys.rs
[noq-crypto]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/crypto.rs
[docs-iroh-base]: https://docs.rs/iroh-base/1.0.1/iroh_base/
[docs-iroh]: https://docs.rs/iroh/1.0.1/iroh/
[blake3]: https://docs.rs/blake3/latest/blake3/
[rfc8032]: https://www.rfc-editor.org/rfc/rfc8032
[rfc7250]: https://www.rfc-editor.org/rfc/rfc7250
[rfc8446]: https://www.rfc-editor.org/rfc/rfc8446
[rfc9001]: https://www.rfc-editor.org/rfc/rfc9001
[rfc4648]: https://www.rfc-editor.org/rfc/rfc4648
[rfc5155]: https://www.rfc-editor.org/rfc/rfc5155
[rfc2606]: https://www.rfc-editor.org/rfc/rfc2606
[bep44]: https://www.bittorrent.org/beps/bep_0044.html
[concepts]: ./concepts.md
[wire]: ./wire-serialization.md
[quic]: ./quic-transport.md
[endpoint]: ./endpoint.md
[socket]: ./socket.md
[nat]: ./nat-traversal.md
[relay]: ./relay.md
[discovery]: ./discovery.md
[blobs]: ./blobs.md
[bao]: ./bao-tree.md
[docs-sync]: ./docs-sync.md
[migration]: ./d-architecture-migration.md
[eh-spec]: ../../specs/event-horizon/SPEC.md
[tokio-async]: ../async-io/tokio.md
[alg-eff]: ../algebraic-effects/index.md
