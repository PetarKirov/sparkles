# `sparkles:age` + `sparkles:crypto` — Specification

_Audience: developers and coding agents building against the libraries.
This document is normative and self-contained — it states what the
libraries provide, not why. For the delivery plan and milestone
orchestration see [PLAN.md](./PLAN.md). The wire format is the
[`age-encryption.org/v1`](https://c2sp.org/age) spec; this document
specifies the D implementation of it._

## 1. Overview

`sparkles:age` is a D implementation of the
[age](https://c2sp.org/age) file-encryption format — a modern format
with multiple pluggable recipients and seekable streaming encryption. It
is a port of the Rust [`rage`](https://github.com/str4d/rage)
implementation (crates `age-core` + `age`), restructured to the
`sparkles` conventions: `@safe` by default, output-range APIs,
`Expected`-based errors, `SmallBuffer`, compile-time concepts checked
with `static assert(isFoo!T)`.

The work is split across two libraries and one CLI:

- **`sparkles:crypto`** (`libs/crypto`) — generic, age-agnostic
  cryptographic and encoding primitives behind a **backend abstraction**.
  The default backend binds [libsodium](https://libsodium.org) via D's
  ImportC; a pure-D backend can be added later behind the same concept.
  This library also owns the **secret-memory foundation** (§3) — the D
  analogues of RustCrypto [`zeroize`](https://docs.rs/zeroize) and
  iqlusion [`secrecy`](https://docs.rs/secrecy) — on which every key type
  in both libraries is built.
- **`sparkles:age`** (`libs/age`) — the age wire format (§7), the
  recipient/identity concepts (§8), the native recipient types (§9), and
  the encrypt/decrypt protocol (§10). Depends on `sparkles:crypto`.
- **`age` / `age-keygen`** (`apps/age`, dub name `age-cli`) — the
  command-line tools (§13).

Core rules:

- A recipient type is a plain struct conforming to the compile-time
  concept [`isRecipient!R`](#82-required-surface); an identity to
  [`isIdentity!I`](#82-required-surface). There is no base class and no
  registration step. Generic `Encryptor`/`Decryptor` operate over any
  conforming type, and a sum type (`AnyRecipient`/`AnyIdentity`) holds
  heterogeneous collections for the CLI.
- A crypto backend is a struct conforming to
  [`isCryptoBackend!B`](#41-the-backend-concept) plus per-primitive
  capability traits. Algorithm sizes (key, nonce, tag, output) are
  compile-time `size_t` constants, not runtime values.
- All key material lives in a [secret type](#3-secret-memory-foundation)
  that wipes itself on destruction and never renders its bytes.

A consumer who only needs one-shot passphrase encryption imports the
simple API:

```d
import sparkles.age.simple : encrypt, decrypt;
import sparkles.age.recipients.scrypt : ScryptRecipient, ScryptIdentity;

auto ct = encrypt(ScryptRecipient("correct horse"), cast(const(ubyte)[]) "hello").value;
auto pt = decrypt(ScryptIdentity("correct horse"), ct).value;
assert(pt == cast(const(ubyte)[]) "hello");
```

## 2. Package and module layout

| Identifier      | Value                                             |
| --------------- | ------------------------------------------------- |
| Dub sub-package | `sparkles:crypto`                                 |
| Source root     | `libs/crypto/src/sparkles/crypto/`                |
| Package module  | `sparkles.crypto`                                 |
| Dub sub-package | `sparkles:age`                                    |
| Source root     | `libs/age/src/sparkles/age/`                      |
| Package module  | `sparkles.age`                                    |
| CLI sub-package | `sparkles:age-cli` (binaries `age`, `age-keygen`) |
| CLI source root | `apps/age/src/`                                   |

The CLI sub-package is named `age-cli` (not `age`) because dub
sub-package names must be unique within the monorepo, and the library is
`sparkles:age`. The binaries it produces are named `age` and `age-keygen`
via per-configuration `targetName`.

### `sparkles.crypto` modules

| Module                            | Contents                                                                                         |
| --------------------------------- | ------------------------------------------------------------------------------------------------ |
| `sparkles.crypto`                 | Public re-exports (`package.d`)                                                                  |
| `sparkles.crypto.zeroize`         | `zeroizeMemory`, `isZeroizable!T`, `Zeroizing!T` (§3)                                            |
| `sparkles.crypto.secret`          | `SecretBuffer`, `SecretArray`, `SecretString`, `isSecret!T`, `exposeSecret` (§3)                 |
| `sparkles.crypto.ct`              | Constant-time `ctEquals`, `ctIsZero` (§3)                                                        |
| `sparkles.crypto.concepts`        | Compile-time size aliases `Key!T`/`Nonce!T`/`Tag!T`/`Output!T`; `isDigest`/`isMac`/`isAead` (§4) |
| `sparkles.crypto.backend`         | Package module: re-exports `backend.traits` + `SodiumBackend` (§4)                               |
| `sparkles.crypto.backend.traits`  | `isCryptoBackend!B`, capability traits, `DefaultBackend` (§4)                                    |
| `sparkles.crypto.backend.sodium`  | `SodiumBackend` — `@trusted` libsodium wrappers, `sodiumAvailable` (§4)                          |
| `sparkles.crypto.encoding.base64` | Unpadded + padded standard base64, strict canonical decode (§5)                                  |
| `sparkles.crypto.encoding.bech32` | BIP173 bech32, no length limit (§5)                                                              |
| `sparkles.crypto.encoding.hex`    | Hex encode/decode (§5)                                                                           |
| `sparkles.crypto.hash`            | `sha256`, `sha512` (§6)                                                                          |
| `sparkles.crypto.hmac`            | `hmacSha256`, `HmacWriter` (§6)                                                                  |
| `sparkles.crypto.hkdf`            | HKDF-SHA256 extract/expand/combined (§6)                                                         |
| `sparkles.crypto.aead`            | ChaCha20-Poly1305 IETF, `StreamNonce` (§6)                                                       |
| `sparkles.crypto.x25519`          | X25519 DH, all-zero (contributory) check (§6)                                                    |
| `sparkles.crypto.ed25519`         | Ed25519 → X25519 conversions (§6)                                                                |
| `sparkles.crypto.scrypt`          | scrypt KDF (§6)                                                                                  |
| `sparkles.crypto.random`          | CSPRNG `randomBytes` (§6)                                                                        |
| `sparkles/crypto/sodium_c.c`      | ImportC translation unit (`#include <sodium.h>`); not a D module                                 |

### `sparkles.age` modules

| Module                                | Contents                                                                            |
| ------------------------------------- | ----------------------------------------------------------------------------------- |
| `sparkles.age`                        | Public re-exports (`package.d`)                                                     |
| `sparkles.age.errors`                 | `DecryptError`, `EncryptError`, `ArmorError` (§11)                                  |
| `sparkles.age.keys`                   | `FileKey`, `macKey`, `payloadKey`, `newFileKey` (§7.1, §10)                         |
| `sparkles.age.mac`                    | `computeHeaderMac`, `verifyHeaderMac` (§7.4)                                        |
| `sparkles.age.format.stanza`          | `Stanza`, stanza writer + body decode (§7.3)                                        |
| `sparkles.age.format.header`          | `HeaderV1`, header parser/builder/writer (§7.2)                                     |
| `sparkles.age.stream`                 | `StreamWriter`, `StreamReader` (§7.5)                                               |
| `sparkles.age.armor`                  | PEM armor encode/decode (§7.6)                                                      |
| `sparkles.age.protocol`               | `Encryptor`, `Decryptor` (§10)                                                      |
| `sparkles.age.recipient`              | `isRecipient!R`, `AnyRecipient` (§8)                                                |
| `sparkles.age.identity`               | `isIdentity!I`, `AnyIdentity` (§8)                                                  |
| `sparkles.age.recipients.x25519`      | `X25519Recipient`, `X25519Identity` (§9.1)                                          |
| `sparkles.age.recipients.scrypt`      | `ScryptRecipient`, `ScryptIdentity` (§9.2)                                          |
| `sparkles.age.recipients.ssh_ed25519` | `SshEd25519Recipient`, `SshEd25519Identity` (§9.3)                                  |
| `sparkles.age.recipients.ssh_keys`    | authorized_keys + OpenSSH private-key parsing; ssh-rsa keys cleanly rejected (§9.3) |
| `sparkles.age.identity_file`          | `IdentityFile` parser (§10.4)                                                       |
| `sparkles.age.simple`                 | One-shot `encrypt`/`encryptAndArmor`/`decrypt` (§10.3)                              |
| `sparkles.age.keygen`                 | X25519 key generation + formatting (§10.5)                                          |
| `sparkles.age.testkit_vectors`        | `version(unittest)` list of the 114 testkit vector names (§12)                      |
| `sparkles.age.testkit_runner`         | `version(unittest)` `static foreach` conformance driver (§12)                       |

`sparkles.age.recipients.ssh_rsa` is **not** in this build (DEFERRED, §9.4):
ssh-rsa recipients/identities need RSA-OAEP, which libsodium does not provide.
ssh-rsa keys encountered by `ssh_keys` are cleanly rejected rather than silently
mis-handled.

**Foundation in `sparkles.core_cli`.** The generic text-parsing
primitives the parsers build on already live in core_cli and are reused,
not duplicated:

| Module                           | Provides                                                         |
| -------------------------------- | ---------------------------------------------------------------- |
| `sparkles.core_cli.text.errors`  | `ParseError {code, offset}`, `ParseErrorCode`, `ParseExpected!T` |
| `sparkles.core_cli.text.readers` | `readInteger`, `skipWhile`, `tryConsume`, `readUntil`            |
| `sparkles.core_cli.text.writers` | `writeInteger`, `writeIntegerPadded`                             |
| `sparkles.core_cli.smallbuffer`  | `SmallBuffer`, `checkToString`, `checkWriter`                    |

`ParseErrorCode` gains three additive members for the encodings:
`checksumMismatch`, `nonCanonicalEncoding`, `invalidPadding`.

## 3. Secret-memory foundation

Every byte of key material in both libraries lives in a secret type that
(1) zeroizes its storage on destruction, (2) cannot be implicitly copied,
and (3) never renders its contents. This layer is **pure D** — it does
not depend on the libsodium backend, so it is the bedrock everything else
is built on. It is modeled on RustCrypto `zeroize` and iqlusion
`secrecy`.

### 3.1 `zeroize`

```d
/// Overwrite `buf` with zeroes such that the write cannot be elided by the
/// optimizer. Uses volatile stores plus a compiler barrier. Not `pure`:
/// the wipe is a deliberate, observable side effect on memory.
void zeroizeMemory(scope ubyte[] buf) @trusted nothrow @nogc;

/// A value type whose `T.init` (all-zero) bit pattern is the desired wipe
/// result — true for scalars and arrays/static arrays of them.
enum isZeroizable(T) = /* … */;

/// RAII wrapper: holds a `T`, exposes it via `get`/`alias this`, and calls
/// `zeroize` on it in `~this`. `@disable this(this)` — no silent copies.
struct Zeroizing(T) if (isZeroizable!T) { /* … */ }
```

`zeroizeMemory` is the single trusted primitive; everything else is
built on it. The libsodium backend MAY route it through `sodium_memzero`
when present, but the default implementation is pure D so the foundation
compiles and tests without any backend.

### 3.2 `secret`

`SecretBuffer!(T, N)` is the secrecy analogue: a `SmallBuffer`-shaped
growable buffer (inline storage of `N` elements, `pureMalloc` on
overflow) that wipes its full capacity before freeing, on destruction and
on reallocation.

```d
struct SecretBuffer(T, size_t N) if (isZeroizable!T)
{
    @disable this(this);                 // no implicit copy

    void put(in T element);              // output-range interface
    void put(scope const(T)[] elements);

    inout(T)[] exposeSecret() inout return @trusted;   // the ONLY read path
    T[]        exposeSecretMut() return @trusted;       // the ONLY write path
    @property size_t length() const;

    SecretBuffer clone() @safe;          // explicit opt-in copy

    void toString(W)(ref W w) const;     // writes "SecretBuffer([REDACTED])"
    ~this() @trusted;                    // zeroizeMemory then free
}

/// Fixed-size secret (the common case for keys). FileKey = SecretArray!16.
alias SecretArray(size_t N) = /* fixed-capacity SecretBuffer-like */;

/// UTF-8 secret string (passphrases).
alias SecretString = /* SecretBuffer!(char, …) with str helpers */;

/// Detects a type exposing `exposeSecret`.
enum isSecret(T) = is(typeof((ref T s) => s.exposeSecret()));
```

Rules:

- **`exposeSecret` is the only access path.** Reading or mutating the
  bytes is explicit and greppable; there is no implicit conversion to
  `ubyte[]`.
- **`toString` is redacted.** It writes `SecretBuffer([REDACTED])` and
  never the bytes, so a secret cannot leak through the logger or
  pretty-printer.
- **`initWithMut`** fills the secret in place from a callback (e.g. the
  CSPRNG writing a fresh `FileKey`), avoiding an intermediate plaintext
  copy.
- **Copy is opt-in** via an explicit `clone()`; assignment and pass-by-value
  do not duplicate a secret.

`FileKey` is `SecretArray!16`; derived wrap/payload keys are
`SecretArray!32`.

### 3.3 `ct`

```d
@safe nothrow @nogc:
bool ctEquals(scope const(ubyte)[] a, scope const(ubyte)[] b);  // length-independent timing
bool ctIsZero(scope const(ubyte)[] a);                          // for the X25519 contributory check
```

Constant-time comparison is pure-D by default (bitwise fold behind an
optimization barrier) and MAY use `sodium_memcmp` when the backend is
present.

## 4. The crypto backend

### 4.1 The backend concept

A backend is a struct (typically zero-size) of `static` methods. A
required concept guarantees the always-present primitives; per-primitive
capability traits gate the rest, so a partial pure-D backend can coexist
with libsodium for the gaps (the same optional-capability discipline as
`sparkles:versions`).

```d
// sparkles.crypto.backend
enum isCryptoBackend(B) = is(typeof(checkCryptoBackend!B)); // sha256, sha512, hmacSha256

enum hasChaCha20Poly1305(B) = /* … */;
enum hasX25519(B)            = /* … */;
enum hasEd25519ToX25519(B)   = /* … */;
enum hasScrypt(B)            = /* … */;
enum hasCsprng(B)            = /* … */;
enum hasConstantTimeCompare(B) = /* … */;

alias DefaultBackend = SodiumBackend;
static assert(isCryptoBackend!DefaultBackend);
```

Public primitive functions are templated `B = DefaultBackend` and
constrained on the capability they use, e.g.:

```d
void aeadSeal(B = DefaultBackend)(in Key!ChaCha20Poly1305 key, in Nonce!ChaCha20Poly1305 nonce,
    in ubyte[] plaintext, in ubyte[] aad, ubyte[] ciphertext)
if (isCryptoBackend!B && hasChaCha20Poly1305!B);
```

### 4.2 Sizes at compile time

Algorithm sizes are compile-time constants on each algorithm tag struct,
and `Key!T`/`Nonce!T`/`Tag!T`/`Output!T` resolve to fixed-size arrays:

```d
enum KEY_SIZE   = 32;   // on ChaCha20Poly1305
enum NONCE_SIZE = 12;
enum TAG_SIZE   = 16;
alias Key(T)   = ubyte[T.KEY_SIZE];
alias Nonce(T) = ubyte[T.NONCE_SIZE];
alias Tag(T)   = ubyte[T.TAG_SIZE];
```

`isDigest!T`/`isMac!T`/`isAead!T` are concept predicates standing in for
RustCrypto's `Digest`/`Mac`/`Aead` traits; the buffering/core/closure
machinery RustCrypto needs for monomorphization is unnecessary in D and
is collapsed.

### 4.3 The libsodium backend

`SodiumBackend` wraps the libsodium C functions imported via ImportC
(the `sodium_c.c` translation unit). Each method is a thin `@trusted nothrow
@nogc` wrapper (ImportC functions carry no D attributes). `sodium_init()`
is called once via `pragma(crt_constructor)` before `main`. The backend
provides every capability except those libsodium lacks (RSA-OAEP,
bcrypt-pbkdf, AES-CTR/CBC — see §9.4).

## 5. Encodings

All encoders are output-range writers; all decoders return
`ParseExpected!(ubyte[])` over a caller-provided output buffer and are
fully `@safe pure nothrow @nogc`.

- **base64** — standard alphabet, two variants: **unpadded** (the age
  wire format for stanza bodies and arguments) and **`=`-padded** (PEM
  armor, §7.6). Decoding is **strict and canonical**: padding characters
  are rejected by the unpadded decoder, non-canonical trailing bits are
  rejected (`nonCanonicalEncoding`), and incorrect padding is rejected
  (`invalidPadding`). This is required by the age spec.
- **bech32** — BIP173, used for `age1…` / `AGE-SECRET-KEY-1…` keys.
  Age uses a long variant **without** the BIP173 90-character limit. The
  checksum is computed over the lowercase form; mixed-case input is
  rejected (`nonCanonicalEncoding`); checksum failure is `checksumMismatch`.
- **hex** — lowercase encode, lower/upper decode; used by test vectors
  and fingerprints.

## 6. Primitives

| Function                                 | Algorithm              | Notes                                                                                       |
| ---------------------------------------- | ---------------------- | ------------------------------------------------------------------------------------------- |
| `sha256`, `sha512`                       | SHA-2                  | output-range / fixed-array out                                                              |
| `hmacSha256`                             | HMAC-SHA256            | one-shot + `HmacWriter` streaming sink (for the header MAC)                                 |
| `hkdfSha256`                             | HKDF-SHA256            | extract + expand + combined; built from HMAC (libsodium has no HKDF)                        |
| `aeadSeal`/`aeadOpen`                    | ChaCha20-Poly1305 IETF | 12-byte nonce; zero-nonce convenience for stanza key-wrap; `aeadOpen` returns `bool` (auth) |
| `StreamNonce`                            | —                      | 11-byte big-endian counter ‖ 1-byte last-chunk flag                                         |
| `x25519`                                 | X25519                 | returns `false` on all-zero (non-contributory) shared secret                                |
| `ed25519PkToX25519`, `ed25519SkToX25519` | Ed25519 → X25519       | for ssh-ed25519                                                                             |
| `scrypt`                                 | scrypt                 | N = 2^logN, r = 8, p = 1, 32-byte output; `in (logN < 64)`                                  |
| `randomBytes`                            | CSPRNG                 | not `pure` (OS entropy); stays `@safe nothrow @nogc`                                        |

The `pure` boundary: encodings are fully `@safe pure nothrow @nogc`;
libsodium-backed primitives keep `@safe nothrow @nogc` but drop `pure`.
`randomBytes` is the one primitive whose impurity is semantically essential
(identical arguments yield different results), but it too remains `@safe
nothrow @nogc`.

## 7. The age wire format

This section specifies the binary format per
[`age-encryption.org/v1`](https://c2sp.org/age). An age file is a textual
[header](#72-header) carrying the wrapped _file key_, followed by a binary
[payload](#75-payload) encrypted with it. age files are treated as
binary.

### 7.1 File key

Each file is encrypted with a 128-bit (16-byte) symmetric _file key_,
generated as 16 bytes of CSPRNG output and never reused. It is held in a
`FileKey = SecretArray!16` (§3).

### 7.2 Header

```
age-encryption.org/v1
-> X25519 <base64 ephemeral share>
<base64 body, wrapped at 64 columns, ending in a line < 64 chars>
--- <base64 MAC>
```

The header is a version line (`age-encryption.org/v1\n`), one or more
[recipient stanzas](#73-recipient-stanza), and a MAC line. Each section is
recognized by its first three bytes; a stanza body ends at the first line
shorter than 64 columns. `HeaderV1` preserves the **exact wire bytes**
(`encodedBytes`) so the MAC verifies against the bytes as received (§7.4).

The parser is a hand-written slice-advance parser over
`sparkles.core_cli.text.readers`; `Decryptor.parse` (§10) takes the
complete header buffer. It tolerates the pre-spec "missing empty final
line" stanza-body form for legacy compatibility, then re-checks
canonicality.

A header is structurally valid iff it contains either zero `scrypt`
stanzas, or exactly one `scrypt` stanza and no others (§9.2).

### 7.3 Recipient stanza

```d
struct Stanza
{
    string   tag;    // arbitrary printable string, e.g. "X25519"
    string[] args;   // zero or more space-separated arguments
    ubyte[]  body_;  // decoded binary body
}
```

A stanza is `-> tag arg1 arg2…\n` followed by the base64 body wrapped at
64 columns, ending with a line shorter than 64 characters (possibly
empty). Each stanza wraps the same file key independently. Identity
implementations MUST ignore unrecognized stanzas and reject malformed
ones addressed to their type. Bodies are encoded with **unpadded** base64
and decoded strictly (§5).

### 7.4 Header MAC

The MAC line is `--- <base64 MAC>` where the MAC is
`HMAC-SHA256(key, header-up-to-and-including "---")`, excluding the space
and MAC, computed over the exact wire bytes. The HMAC key is:

```
HMAC key = HKDF-SHA-256(ikm = file key, salt = empty, info = "header")
```

### 7.5 Payload

The payload begins with a 16-byte CSPRNG nonce (fresh per file), then the
STREAM-encrypted body:

```
payload key = HKDF-SHA-256(ikm = file key, salt = nonce, info = "payload")
```

The body is split into 64 KiB chunks, each encrypted with
ChaCha20-Poly1305 under the payload key and a 12-byte nonce: an 11-byte
big-endian chunk counter (from zero) followed by a last-chunk flag byte
(`0x01` for the final chunk, `0x00` otherwise). The final chunk MAY be
shorter than 64 KiB but MUST NOT be empty unless the whole payload is
empty. Decryption MUST error if EOF is reached without a valid final
chunk.

`StreamWriter` buffers up to a chunk and flushes; `StreamWriter.finish()`
is **mandatory** — it emits the final chunk with the last-chunk flag.
`StreamReader` decrypts lazily and exposes a bulk `read(buf)`. Seekable
decryption is designed-for but may land later.

### 7.6 ASCII armor

Armored files use strict PEM (RFC 7468) with label `AGE ENCRYPTED FILE`
and **`=`-padded** standard base64 wrapped at 64 columns. The decoder
rejects CR characters, non-64-column wrapping, garbage before/after the
markers, and non-canonical base64. `looksArmored` detects the begin
marker.

## 8. Recipient and Identity concepts

### 8.1 Design

Recipients and identities are plain structs conforming to compile-time
concepts (the design-by-introspection idiom of `isVersion!T`). The two
join points with the protocol are `wrapFileKey` and `unwrapStanza`.

### 8.2 Required surface

```d
// isRecipient!R — appends its stanza(s) and label(s) into caller buffers
Expected!(void, EncryptError, NoGcHook) wrapFileKey(
    in FileKey fileKey,
    ref SmallBuffer!(Stanza, N) stanzas,
    ref SmallBuffer!(string, M) labels) @safe;

// isIdentity!I — the "not mine / structural error / success" trichotomy
Nullable!(Expected!(FileKey, DecryptError, NoGcHook)) unwrapStanza(in Stanza stanza) @safe;
```

`unwrapStanza` returns:

- a null `Nullable` — the stanza is not addressed to this identity (skip);
- `some(err(…))` — the stanza is ours but structurally invalid;
- `some(ok(fileKey))` — success.

An identity MAY additionally provide `unwrapStanzas(in Stanza[])` (the
`hasUnwrapStanzas!I` capability) when it needs whole-header context — the
scrypt identity uses this to enforce that its stanza is the only one.

`wrapFileKey` also appends **labels**; the encryptor requires every
recipient to contribute an identical label set (the scrypt recipient
returns a random label, forcing it to be the sole recipient).

### 8.3 `AnyRecipient` / `AnyIdentity`

For runtime-heterogeneous collections (the CLI), `AnyRecipient` and
`AnyIdentity` are `SumType`s over the concrete types, with `wrapFileKey` /
`unwrapStanza` dispatchers — the same pattern as `AnyVersion` in
`sparkles:versions`.

## 9. Native recipient types

### 9.1 X25519

Identity HRP `AGE-SECRET-KEY-`; recipient HRP `age`. Stanza:
`-> X25519 <base64 ephemeral share>` + body. The body is
`ChaCha20-Poly1305(key, fileKey)` with a zero nonce, where
`key = HKDF-SHA-256(salt = ephemeral_share ‖ recipient, info =
"age-encryption.org/v1/X25519", ikm = X25519(ephemeral_secret, recipient))`.
The identity rejects an all-zero shared secret and requires a 32-byte
body and a canonical 32-byte share.

### 9.2 scrypt (passphrase)

Stanza: `-> scrypt <base64 salt> <logN>` + body, where
`key = scrypt(S = "age-encryption.org/v1/scrypt" ‖ salt, N = 2^logN, r = 8,
p = 1, 32)` and the body is `ChaCha20-Poly1305(key, fileKey)` with a zero
nonce. The salt is 16 CSPRNG bytes; `logN` is decimal with no leading
zeros. An scrypt stanza MUST be the only stanza in the header. The
identity SHOULD cap the work factor (`ExcessiveWork` otherwise) and the
recipient returns a random label to force singleton use.

### 9.3 ssh-ed25519

Stanza: `-> ssh-ed25519 <base64 tag> <base64 ephemeral share>` + body,
where `tag = SHA-256(ssh-wire-pubkey)[:4]`. The Ed25519 key is converted
to X25519 (Montgomery) form; a tweak
`= HKDF-SHA-256(salt = ssh-wire-pubkey, info =
"age-encryption.org/v1/ssh-ed25519", ikm = "")` binds the shared secret
to the specific key. Public keys are parsed from `authorized_keys` lines;
identities from unencrypted OpenSSH private keys. Fully covered by the
libsodium backend (`crypto_sign_ed25519_*_to_curve25519`).

### 9.4 ssh-rsa (DEFERRED — not implemented in this build)

Stanza: `-> ssh-rsa <base64 tag>` + body, where the body is
`RSAES-OAEP(SHA-256, MGF1-SHA256, label = "age-encryption.org/v1/ssh-rsa",
fileKey)`. RSA-OAEP, plus bcrypt-pbkdf + AES-CTR/CBC for **encrypted**
OpenSSH private keys, are **not** in libsodium; they require a second
backend (e.g. OpenSSL deimos).

**This build does not implement ssh-rsa.** There is no
`sparkles.age.recipients.ssh_rsa` module, and encrypted OpenSSH private keys
are not loadable. ssh-rsa keys are **cleanly rejected** when encountered (an
ssh-rsa `authorized_keys` line or private key produces a structured error
rather than being silently ignored or mis-handled), so the absence is
explicit and never a silent failure. The type can be added later behind a
second crypto backend without changing the recipient/identity concepts (§8).

### 9.5 Deferred

The post-quantum and tagged types (`mlkem768x25519`, `p256tag`,
`mlkem768p256tag`) and the plugin IPC protocol are out of scope for this
implementation.

## 10. Protocol

### 10.1 `Encryptor`

```d
struct Encryptor
{
    static Expected!(Encryptor, EncryptError, NoGcHook) withRecipients(R)(R[] recipients) if (isRecipient!R);
    static Expected!(Encryptor, EncryptError, NoGcHook) withAnyRecipients(scope AnyRecipient[] recipients);
    static Encryptor withPassphrase(scope const(char)[] passphrase);

    Expected!(StreamWriter!W, EncryptError, NoGcHook) wrapOutput(W)(ref W output)
        if (isOutputRange!(W, const(ubyte)[]));
}
```

`withRecipients` generates the file key, calls each recipient's
`wrapFileKey` (checking label compatibility), builds and MAC-signs the
header, generates the payload nonce, and derives the payload key.
`wrapOutput` writes the header and nonce, then returns a `StreamWriter`;
the caller writes plaintext and MUST call `finish()`.

### 10.2 `Decryptor`

```d
struct Decryptor
{
    static Expected!(Decryptor, DecryptError, NoGcHook) parse(scope const(ubyte)[] input);
    bool isScrypt() const;
    Expected!(StreamReader, DecryptError, NoGcHook) decrypt(I)(in I identity) if (isIdentity!I);
    Expected!(StreamReader, DecryptError, NoGcHook) decryptAny(scope AnyIdentity[] identities);
}
```

`parse` reads the header and payload nonce. `decrypt` finds the first
identity that unwraps a stanza, derives and MAC-verifies the payload key,
and returns a `StreamReader`. Header parse errors map to
`DecryptError.invalidHeader`; a wrong MAC to `invalidMac`; no matching
identity to `noMatchingKeys`.

### 10.3 Simple API

```d
Expected!(ubyte[], EncryptError, NoGcHook) encrypt(R)(in R recipient, scope const(ubyte)[] plaintext) if (isRecipient!R);
Expected!(string,  EncryptError, NoGcHook) encryptAndArmor(R)(in R recipient, scope const(ubyte)[] plaintext) if (isRecipient!R);
Expected!(ubyte[], DecryptError, NoGcHook) decrypt(I)(in I identity, scope const(ubyte)[] ciphertext) if (isIdentity!I);
```

`decrypt` detects and strips armor transparently.

### 10.4 Identity files

`IdentityFile` parses either a native age-identity file (blank/`#`-comment
lines plus one `AGE-SECRET-KEY-1…` per line) or a single unencrypted OpenSSH
private key (`-----BEGIN OPENSSH PRIVATE KEY-----` PEM, ssh-ed25519). The two
forms never mix — an OpenSSH PEM marker at the start switches the whole input
to the SSH parser. It exposes the parsed `X25519Identity[]` and
`SshEd25519Identity[]`, convertible to `AnyIdentity[]` for the protocol.
Encrypted OpenSSH keys and ssh-rsa keys are rejected (§9.4).

### 10.5 Key generation

`keygen` generates an X25519 identity and writes the standard format:

```
# created: <RFC 3339 timestamp>
# public key: age1…
AGE-SECRET-KEY-1…
```

It also converts an identity file to its recipient public keys.

## 11. Errors

All fallible operations return `Expected` (or `ParseExpected`); the
libraries throw no exceptions in their own code. Error types are tagged
structs with output-range `toString`:

```d
enum DecryptErrorCode { decryptionFailed, excessiveWork, invalidHeader,
    invalidMac, noMatchingKeys, unknownFormat, truncatedPayload, payloadError }
enum EncryptErrorCode { missingRecipients, incompatibleRecipients,
    mixedRecipientAndPassphrase, wrapFailed }
enum ArmorErrorCode   { crlf, invalidCharacter, longLine, missingEndMarker,
    nonCanonical, unexpectedEof, trailingGarbage }
```

`ExcessiveWork` carries `required`/`target` work factors. Header
`ParseError`s (from §2's core_cli vocabulary) are mapped into
`DecryptError.invalidHeader` at the `Decryptor.parse` boundary.

## 12. Conformance and test vectors

The official age testkit (114 vectors) is vendored into
`libs/age/tests/testkit/` from the rage reference. Each vector is header
lines — `expect:` (`success` / `header failure` / `HMAC failure` /
`armor failure` / `no match` / `payload failure`), `payload:` (SHA-256 of
the expected plaintext), `file key:`, `identity:`, `passphrase:`,
`armored:` — a blank line, then the raw or armored age bytes. The names are
listed in `sparkles.age.testkit_vectors`; the `static foreach` harness in
`sparkles.age.testkit_runner` string-imports each vector and runs it as
`@("testkit.<name>")`, decrypting with the given identity/passphrase and
asserting the expected outcome. **All 114 vectors pass.**

The testkit covers only the v1 native types (X25519, scrypt) plus
format/stream/armor; it has **no SSH vectors**. SSH recipient types
(ssh-ed25519) are validated by hand-authored round-trip tests with
synthesized keys and by interop tests against the reference `rage` binary
(version 0.11.1): files this library encrypts decrypt with `rage`, and files
`rage` encrypts decrypt with this library — verified in both directions for
X25519, scrypt, and ssh-ed25519.

Primitive correctness is validated against published vectors: RFC 7539
(ChaCha20-Poly1305), RFC 5869 (HKDF), RFC 7914 (scrypt), RFC 7748
(X25519), BIP173 (bech32), RFC 4648 (base64).

## 13. Command-line tools

`age` reproduces the `rage` surface: positional input (file or stdin
`-`); `-e/--encrypt`, `-d/--decrypt`, `-p/--passphrase`,
`--max-work-factor`, `-a/--armor`, repeatable `-r/--recipient`,
`-R/--recipients-file`, `-i/--identity`, `-o/--output`, and `-h/--help`. It
enforces the same validation matrix (mixed encrypt/decrypt, ambiguous `-i`,
identical input/output, passphrase-mixed-with-recipients, decrypt-mode
flag rejections, binary-to-TTY guard, double-encrypt warning). Argument
parsing reuses `sparkles.core_cli.args`. `-h/--help` is detected by a scan
that runs before any other work and prints usage to stdout with exit `0`.
The `-j <PLUGIN>` flag is accepted by the parser but rejected as
unsupported (plugins are out of scope, §9.5).

Recipients are age public keys (`age1…`) or ssh-ed25519 public keys;
identity files are age identity files or unencrypted ssh-ed25519 private
keys. ssh-rsa keys and encrypted OpenSSH keys are rejected (§9.4).

`age-keygen` generates a new identity (`-o`, file mode 0600, refuses
overwrite) or converts an identity file to recipients (`-y`). It also
honours `-h/--help` before generating a key, so a help request never has
the side effect of writing a fresh private key.

The CLI lives in `apps/age` (dub sub-package `age-cli`): the `age` and
`age-keygen` entry points (`src/age.d`, `src/age_keygen.d`) over the
`sparkles.age_cli.*` helpers (`options`, `validate`, `io`, `passphrase`,
`keygen_flow`, `usage`, `errors`).

---

→ [PLAN.md](./PLAN.md) — delivery milestones and workflow orchestration
→ [age-encryption.org/v1](https://c2sp.org/age) — the normative wire format
