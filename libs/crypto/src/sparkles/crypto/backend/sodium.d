/**
 * The libsodium-backed crypto backend.
 *
 * Binds [libsodium](https://libsodium.org) via the ImportC translation unit
 * $(D sparkles.crypto.sodium_c). Each primitive is exposed as a thin `@trusted`
 * wrapper because the ImportC declarations are plain `extern(C)` with no D
 * safety attributes, so they cannot be called from `@safe nothrow @nogc`
 * D directly. We launder the attributes with the proven function-pointer cast
 * pattern (the one `sparkles:ghostty` uses for libghostty-vt):
 *
 * ---
 * alias Fn = extern(C) int function(scope ubyte*, scope const(ubyte)*, ulong)
 *     @nogc nothrow @system;
 * (cast(Fn) &crypto_hash_sha256)(out_.ptr, msg.ptr, msg.length);
 * ---
 *
 * The libsodium functions used here are documented as non-allocating and
 * non-throwing, so the asserted `nothrow @nogc` is sound; `@trusted` confines
 * the pointer arithmetic to these wrappers and the public surface stays
 * `@safe`.
 *
 * libsodium-backed code is `@safe nothrow @nogc` but $(B not) `pure`
 * (`randomBytes` reads OS entropy and even the deterministic primitives are
 * not modelled as pure). `randomBytes` is the only method that additionally
 * touches the OS, but it shares the same attribute set.
 *
 * `sodium_init()` is invoked exactly once at program startup via
 * `pragma(crt_constructor)` (see $(LREF sparkles_crypto_sodium_init)).
 *
 * See `docs/specs/age/SPEC.md` §4.3 (the libsodium backend) and §6
 * (primitives) for the normative description.
 *
 * Copyright: © 2026, Petar Kirov
 * License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Authors: Petar Kirov
 */
module sparkles.crypto.backend.sodium;

import sparkles.crypto.backend.traits : isCryptoBackend;
import sparkles.crypto.sodium_c;

/**
 * Ensure libsodium is initialized and usable.
 *
 * `sodium_init()` is idempotent: it returns `0` on the first successful call,
 * `1` if already initialized, and `-1` on failure. This wrapper reports success
 * as a `bool`. It is the original M0 link check confirming the ImportC + Nix
 * wiring works end-to-end; it remains as a cheap runtime sanity check.
 */
bool sodiumAvailable() @trusted
{
    return sodium_init() >= 0;
}

/// libsodium links and initializes.
@("crypto.sodium.linked")
@safe
unittest
{
    assert(sodiumAvailable());
}

/**
 * Initialize libsodium once, before `main`, via the C runtime constructor.
 *
 * `pragma(crt_constructor)` schedules this `extern(C)` function to run during
 * program startup. `sodium_init()` is required before any other libsodium
 * call in a multi-threaded program; running it here means every
 * `SodiumBackend` method can assume an initialized library. The init result is
 * `>= 0` on success (`0` first call, `1` already initialized); a negative value
 * means libsodium could not initialize and the process is unsafe to continue,
 * so we assert.
 */
pragma(crt_constructor)
extern(C) void sparkles_crypto_sodium_init() @trusted nothrow @nogc
{
    alias InitFn = extern(C) int function() @nogc nothrow @system;
    const rc = (cast(InitFn) &sodium_init)();
    assert(rc >= 0, "sodium_init() failed");
}

/**
 * The default, fully-capable crypto backend, backed by libsodium.
 *
 * A zero-size struct of `static` methods. The library never instantiates it;
 * it calls `SodiumBackend.method(...)` (usually indirectly, through the
 * backend-templated free functions in the primitive modules). The struct
 * satisfies $(REF isCryptoBackend, sparkles,crypto,backend,traits) and every
 * capability predicate except `hasScrypt` (scrypt lands in M4).
 *
 * Every method is `@trusted nothrow @nogc` (but not `pure`); the `@trusted`
 * is confined to these bodies, which only ever forward fixed-size or
 * slice-bounded buffers to libsodium.
 */
struct SodiumBackend
{
@trusted nothrow @nogc:

    // AEAD parameters. These are C preprocessor macros in <sodium.h>, which
    // ImportC does not expose, so they are hardcoded here against the
    // crypto_aead_chacha20poly1305_ietf_* contract:
    //   NPUBBYTES = 12 (nonce), ABYTES = 16 (Poly1305 tag), KEYBYTES = 32.
    private enum size_t aeadNonceBytes = 12;
    private enum size_t aeadTagBytes = 16;
    private enum size_t aeadKeyBytes = 32;

    /**
     * SHA-256 digest of `msg` into the 32-byte `outDigest`.
     *
     * Params:
     *   msg       = message bytes (may be empty)
     *   outDigest = 32-byte output digest
     */
    static void sha256(scope const(ubyte)[] msg, ref ubyte[32] outDigest)
    {
        alias Fn = extern(C) int function(scope ubyte*, scope const(ubyte)*, ulong)
            @nogc nothrow @system;
        (cast(Fn) &crypto_hash_sha256)(outDigest.ptr, msg.ptr, msg.length);
    }

    /**
     * SHA-512 digest of `msg` into the 64-byte `outDigest`.
     *
     * Params:
     *   msg       = message bytes (may be empty)
     *   outDigest = 64-byte output digest
     */
    static void sha512(scope const(ubyte)[] msg, ref ubyte[64] outDigest)
    {
        alias Fn = extern(C) int function(scope ubyte*, scope const(ubyte)*, ulong)
            @nogc nothrow @system;
        (cast(Fn) &crypto_hash_sha512)(outDigest.ptr, msg.ptr, msg.length);
    }

    /**
     * HMAC-SHA256 of `msg` under a $(B variable-length) `key`, into the 32-byte
     * `outTag`.
     *
     * Uses the streaming `init`/`update`/`final` API rather than the one-shot
     * `crypto_auth_hmacsha256`, because the one-shot form fixes the key length
     * at 32 bytes whereas HKDF-Extract feeds keys (salts) of arbitrary length.
     *
     * Params:
     *   key    = HMAC key of any length
     *   msg    = message bytes (may be empty)
     *   outTag = 32-byte output tag
     */
    static void hmacSha256(scope const(ubyte)[] key, scope const(ubyte)[] msg,
        ref ubyte[32] outTag)
    {
        alias InitFn = extern(C) int function(
            scope crypto_auth_hmacsha256_state*, scope const(ubyte)*, size_t)
            @nogc nothrow @system;
        alias UpdateFn = extern(C) int function(
            scope crypto_auth_hmacsha256_state*, scope const(ubyte)*, ulong)
            @nogc nothrow @system;
        alias FinalFn = extern(C) int function(
            scope crypto_auth_hmacsha256_state*, scope ubyte*)
            @nogc nothrow @system;

        crypto_auth_hmacsha256_state state = void;
        (cast(InitFn) &crypto_auth_hmacsha256_init)(&state, key.ptr, key.length);
        (cast(UpdateFn) &crypto_auth_hmacsha256_update)(&state, msg.ptr, msg.length);
        (cast(FinalFn) &crypto_auth_hmacsha256_final)(&state, outTag.ptr);
    }

    /**
     * ChaCha20-Poly1305 (IETF, 12-byte nonce) authenticated encryption.
     *
     * Encrypts `pt` under `key`/`nonce` with associated data `aad`, writing the
     * ciphertext followed by the 16-byte Poly1305 tag into `ct`. The caller
     * MUST size `ct` as `pt.length + 16`.
     *
     * Params:
     *   key   = 32-byte key
     *   nonce = 12-byte nonce
     *   pt    = plaintext (may be empty)
     *   aad   = associated data (may be empty)
     *   ct    = output, exactly `pt.length + 16` bytes
     */
    static void chaCha20Poly1305Encrypt(in ubyte[32] key, in ubyte[12] nonce,
        scope const(ubyte)[] pt, scope const(ubyte)[] aad, scope ubyte[] ct)
    in (ct.length == pt.length + aeadTagBytes,
        "chaCha20Poly1305Encrypt: ct.length must equal pt.length + 16")
    {
        alias Fn = extern(C) int function(
            scope ubyte* c, scope ulong* clen,
            scope const(ubyte)* m, ulong mlen,
            scope const(ubyte)* ad, ulong adlen,
            scope const(ubyte)* nsec, scope const(ubyte)* npub,
            scope const(ubyte)* k) @nogc nothrow @system;

        ulong clen = void;
        (cast(Fn) &crypto_aead_chacha20poly1305_ietf_encrypt)(
            ct.ptr, &clen,
            pt.ptr, pt.length,
            aad.ptr, aad.length,
            null, nonce.ptr, key.ptr);
    }

    /**
     * ChaCha20-Poly1305 (IETF) authenticated decryption.
     *
     * Verifies the appended 16-byte tag and, on success, writes the plaintext
     * into `pt`. The caller MUST size `pt` as `ct.length - 16`.
     *
     * Params:
     *   key   = 32-byte key
     *   nonce = 12-byte nonce
     *   ct    = ciphertext ‖ tag, at least 16 bytes
     *   aad   = associated data (may be empty)
     *   pt    = output, exactly `ct.length - 16` bytes
     * Returns: `true` if authentication succeeds, `false` otherwise (in which
     *   case `pt` MUST be treated as undefined).
     */
    static bool chaCha20Poly1305Decrypt(in ubyte[32] key, in ubyte[12] nonce,
        scope const(ubyte)[] ct, scope const(ubyte)[] aad, scope ubyte[] pt)
    in (ct.length >= aeadTagBytes,
        "chaCha20Poly1305Decrypt: ct must be at least 16 bytes (the tag)")
    in (pt.length == ct.length - aeadTagBytes,
        "chaCha20Poly1305Decrypt: pt.length must equal ct.length - 16")
    {
        alias Fn = extern(C) int function(
            scope ubyte* m, scope ulong* mlen,
            scope ubyte* nsec,
            scope const(ubyte)* c, ulong clen,
            scope const(ubyte)* ad, ulong adlen,
            scope const(ubyte)* npub, scope const(ubyte)* k)
            @nogc nothrow @system;

        ulong mlen = void;
        const rc = (cast(Fn) &crypto_aead_chacha20poly1305_ietf_decrypt)(
            pt.ptr, &mlen,
            null,
            ct.ptr, ct.length,
            aad.ptr, aad.length,
            nonce.ptr, key.ptr);
        return rc == 0;
    }

    /**
     * X25519 Diffie-Hellman scalar multiplication: `outShared = scalar · point`.
     *
     * Params:
     *   scalar    = 32-byte secret scalar
     *   point     = 32-byte peer public point
     *   outShared = 32-byte output shared secret
     * Returns: `false` if libsodium reports a low-order `point` (the result
     *   would be the all-zero, non-contributory shared secret), `true`
     *   otherwise.
     */
    static bool x25519(in ubyte[32] scalar, in ubyte[32] point,
        ref ubyte[32] outShared)
    {
        alias Fn = extern(C) int function(
            scope ubyte* q, scope const(ubyte)* n, scope const(ubyte)* p)
            @nogc nothrow @system;
        const rc = (cast(Fn) &crypto_scalarmult_curve25519)(
            outShared.ptr, scalar.ptr, point.ptr);
        return rc == 0;
    }

    /**
     * X25519 fixed-base scalar multiplication: `outPublic = scalar · basepoint`.
     *
     * Derives the X25519 public key for a secret `scalar`.
     *
     * Params:
     *   scalar    = 32-byte secret scalar
     *   outPublic = 32-byte output public key
     */
    static void x25519Base(in ubyte[32] scalar, ref ubyte[32] outPublic)
    {
        alias Fn = extern(C) int function(scope ubyte* q, scope const(ubyte)* n)
            @nogc nothrow @system;
        (cast(Fn) &crypto_scalarmult_curve25519_base)(outPublic.ptr, scalar.ptr);
    }

    /**
     * Convert an Ed25519 public key to its X25519 (Montgomery) form.
     *
     * Used to derive an ssh-ed25519 recipient's X25519 public key.
     *
     * Params:
     *   edPk    = 32-byte Ed25519 public key
     *   curvePk = 32-byte output X25519 public key
     */
    static void ed25519PkToX25519(in ubyte[32] edPk, ref ubyte[32] curvePk)
    {
        alias Fn = extern(C) int function(
            scope ubyte* curvePk, scope const(ubyte)* edPk)
            @nogc nothrow @system;
        (cast(Fn) &crypto_sign_ed25519_pk_to_curve25519)(curvePk.ptr, edPk.ptr);
    }

    /**
     * Convert an Ed25519 secret key to its X25519 (Montgomery) form.
     *
     * The libsodium Ed25519 secret key is 64 bytes (seed ‖ public key).
     *
     * Params:
     *   edSk    = 64-byte Ed25519 secret key
     *   curveSk = 32-byte output X25519 secret key
     */
    static void ed25519SkToX25519(in ubyte[64] edSk, ref ubyte[32] curveSk)
    {
        alias Fn = extern(C) int function(
            scope ubyte* curveSk, scope const(ubyte)* edSk)
            @nogc nothrow @system;
        (cast(Fn) &crypto_sign_ed25519_sk_to_curve25519)(curveSk.ptr, edSk.ptr);
    }

    /**
     * Constant-time equality of two byte slices, via `sodium_memcmp`.
     *
     * `sodium_memcmp` compares a fixed length without short-circuiting, so the
     * timing leaks nothing about where the slices differ. Slices of unequal
     * length can never be equal and are rejected $(B before) the comparison
     * (the length itself is not a secret).
     *
     * Params:
     *   a = first slice
     *   b = second slice
     * Returns: `true` iff `a` and `b` have equal length and identical contents.
     */
    static bool ctEquals(scope const(ubyte)[] a, scope const(ubyte)[] b)
    {
        if (a.length != b.length)
            return false;
        if (a.length == 0)
            return true;

        alias Fn = extern(C) int function(
            scope const(void)* b1, scope const(void)* b2, size_t len)
            @nogc nothrow @system;
        return (cast(Fn) &sodium_memcmp)(a.ptr, b.ptr, a.length) == 0;
    }

    /**
     * Fill `buf` with cryptographically-secure random bytes from the OS CSPRNG.
     *
     * This is the one method that is $(B not) `pure`: it draws fresh entropy on
     * every call.
     *
     * Params:
     *   buf = destination, filled in full
     */
    static void randomBytes(scope ubyte[] buf)
    {
        if (buf.length == 0)
            return;

        alias Fn = extern(C) void function(scope void* buf, size_t size)
            @nogc nothrow @system;
        (cast(Fn) &randombytes_buf)(buf.ptr, buf.length);
    }

    /**
     * scrypt key derivation (RFC 7914) with the age profile: `r = 8`, `p = 1`,
     * 32-byte output. The cost parameter is `N = 2^logN`.
     *
     * Backed by libsodium's low-level
     * `crypto_pwhash_scryptsalsa208sha256_ll`, which takes explicit `N`, `r`,
     * `p` (unlike the high-level `crypto_pwhash`, whose parameters are opaque).
     * The age scrypt recipient stanza fixes `r = 8`, `p = 1`, so they are not
     * part of the signature; the caller bounds `logN` (the identity applies a
     * work-factor cap) before calling.
     *
     * Params:
     *   password = passphrase bytes (may be empty)
     *   salt     = salt bytes (may be empty)
     *   logN     = base-2 log of the cost parameter N (N = 1 << logN)
     *   outKey   = 32-byte derived key
     * Returns: `true` on success; `false` if libsodium could not derive the key
     *          (e.g. the requested `N` exceeds the addressable memory limit).
     *          On `false`, `outKey` is unspecified and MUST NOT be used.
     */
    static bool scrypt(scope const(ubyte)[] password, scope const(ubyte)[] salt,
        ubyte logN, ref ubyte[32] outKey)
    in (logN < 64, "scrypt: logN must be < 64")
    {
        alias Fn = extern(C) int function(
            scope const(ubyte)* passwd, size_t passwdlen,
            scope const(ubyte)* salt, size_t saltlen,
            ulong n, uint r, uint p,
            scope ubyte* buf, size_t buflen) @nogc nothrow @system;
        const ulong n = 1UL << logN;
        const rc = (cast(Fn) &crypto_pwhash_scryptsalsa208sha256_ll)(
            password.ptr, password.length, salt.ptr, salt.length,
            n, 8, 1, outKey.ptr, outKey.length);
        return rc == 0;
    }
}

// `SodiumBackend` is a conforming crypto backend. (The capability predicates
// are additionally asserted against it in `backend/package.d`.)
static assert(isCryptoBackend!SodiumBackend);

// ─────────────────────────────────────────────────────────────────────────
// Tests — known-answer vectors from the relevant RFCs / FIPS examples.
//
// Hex literals are decoded with sparkles.crypto.encoding.hex.decodeHex into
// stack buffers so the tests stay allocation-free.
// ─────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import sparkles.crypto.encoding.hex : decodeHex;

    /// Decode a compile-time-known hex string into a fixed `ubyte[N]`,
    /// asserting it decodes cleanly. `N` is the expected byte length.
    private ubyte[N] fromHex(size_t N)(scope const(char)[] s) @safe nothrow @nogc
    in (s.length == N * 2, "fromHex: hex length does not match N")
    {
        ubyte[N] out_ = void;
        auto r = decodeHex(s, out_[]);
        assert(r.hasValue, "fromHex: invalid hex literal");
        assert(r.value.length == N, "fromHex: decoded length mismatch");
        return out_;
    }
}

/// SHA-256 of "abc" matches the FIPS 180-4 example digest.
@("crypto.sodium.sha256.abc")
@safe nothrow @nogc
unittest
{
    static immutable ubyte[3] msg = ['a', 'b', 'c'];
    ubyte[32] digest = void;
    SodiumBackend.sha256(msg[], digest);

    const expected = fromHex!32(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    assert(digest == expected);
}

/// SHA-256 of the empty message matches the well-known digest.
@("crypto.sodium.sha256.empty")
@safe nothrow @nogc
unittest
{
    ubyte[32] digest = void;
    SodiumBackend.sha256(null, digest);

    const expected = fromHex!32(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    assert(digest == expected);
}

/// SHA-512 of "abc" matches the FIPS 180-4 example digest.
@("crypto.sodium.sha512.abc")
@safe nothrow @nogc
unittest
{
    static immutable ubyte[3] msg = ['a', 'b', 'c'];
    ubyte[64] digest = void;
    SodiumBackend.sha512(msg[], digest);

    const expected = fromHex!64(
        "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
        ~ "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f");
    assert(digest == expected);
}

/// HMAC-SHA256 with RFC 4231 Test Case 2 (key="Jefe",
/// data="what do ya want for nothing?"), exercising a short, variable-length
/// key.
@("crypto.sodium.hmacSha256.rfc4231")
@safe nothrow @nogc
unittest
{
    static immutable ubyte[4] key = ['J', 'e', 'f', 'e'];
    immutable(ubyte)[] data = cast(immutable(ubyte)[]) "what do ya want for nothing?";

    ubyte[32] tag = void;
    SodiumBackend.hmacSha256(key[], data, tag);

    const expected = fromHex!32(
        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
    assert(tag == expected);
}

/// ChaCha20-Poly1305 IETF round-trips and matches the RFC 7539 §2.8.2 known
/// ciphertext+tag; flipping a ciphertext byte makes decryption fail.
@("crypto.sodium.chacha20poly1305.rfc7539")
@safe nothrow @nogc
unittest
{
    const key = fromHex!32(
        "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f");
    // RFC 7539 §2.8.2 nonce: 32-bit constant 0x07000000 ‖ 64-bit IV.
    const nonce = fromHex!12("070000004041424344454647");
    const aad = fromHex!12("50515253c0c1c2c3c4c5c6c7");

    static immutable string ptStr =
        "Ladies and Gentlemen of the class of '99: If I could offer you " ~
        "only one tip for the future, sunscreen would be it.";
    immutable(ubyte)[] pt = cast(immutable(ubyte)[]) ptStr;

    // Expected ciphertext (RFC 7539 §2.8.2, 114 bytes) followed by the 16-byte
    // Poly1305 tag — 130 bytes total.
    const expectedCt = fromHex!130(
        "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d6"
        ~ "3dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b36"
        ~ "92ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc"
        ~ "3ff4def08e4b7a9de576d26586cec64b6116"
        ~ "1ae10b594f09e26a7e902ecbd0600691");

    ubyte[130] ct = void; // pt.length (114) + 16 tag
    assert(pt.length == 114);
    SodiumBackend.chaCha20Poly1305Encrypt(key, nonce, pt, aad[], ct[]);
    assert(ct == expectedCt);

    ubyte[114] recovered = void; // 130 - 16
    assert(SodiumBackend.chaCha20Poly1305Decrypt(key, nonce, ct[], aad[], recovered[]));
    assert(recovered[] == pt);

    // Tamper with the ciphertext: authentication must fail.
    ubyte[130] tampered = ct;
    tampered[0] ^= 0x01;
    ubyte[114] discard = void; // 130 - 16
    assert(!SodiumBackend.chaCha20Poly1305Decrypt(key, nonce, tampered[], aad[], discard[]));
}

/// ChaCha20-Poly1305 with an empty plaintext produces a bare 16-byte tag and
/// round-trips.
@("crypto.sodium.chacha20poly1305.emptyPlaintext")
@safe nothrow @nogc
unittest
{
    const key = fromHex!32(
        "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f");
    const nonce = fromHex!12("070000004041424344454647");

    ubyte[16] ct = void; // 0 plaintext + 16 tag
    SodiumBackend.chaCha20Poly1305Encrypt(key, nonce, null, null, ct[]);

    ubyte[0] recovered;
    assert(SodiumBackend.chaCha20Poly1305Decrypt(key, nonce, ct[], null, recovered[]));
}

/// X25519 matches the RFC 7748 §5.2 first test vector.
@("crypto.sodium.x25519.rfc7748")
@safe nothrow @nogc
unittest
{
    const scalar = fromHex!32(
        "a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4");
    const point = fromHex!32(
        "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c");

    ubyte[32] shared_ = void;
    assert(SodiumBackend.x25519(scalar, point, shared_));

    const expected = fromHex!32(
        "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552");
    assert(shared_ == expected);
}

/// X25519 reports a low-order point as a non-contributory (all-zero) shared
/// secret by returning `false`.
@("crypto.sodium.x25519.lowOrderPoint")
@safe nothrow @nogc
unittest
{
    // An all-zero public point is low-order; libsodium yields an all-zero
    // shared secret and signals failure.
    ubyte[32] scalar = void;
    SodiumBackend.randomBytes(scalar[]);
    ubyte[32] zeroPoint = 0;

    ubyte[32] shared_ = void;
    assert(!SodiumBackend.x25519(scalar, zeroPoint, shared_));
}

/// `x25519Base` derives the public key, and a full ephemeral DH agrees on
/// both sides (`a·B` then `a·(b·B) == b·(a·B)`).
@("crypto.sodium.x25519Base.agreement")
@safe nothrow @nogc
unittest
{
    ubyte[32] skA = void, skB = void;
    SodiumBackend.randomBytes(skA[]);
    SodiumBackend.randomBytes(skB[]);

    ubyte[32] pkA = void, pkB = void;
    SodiumBackend.x25519Base(skA, pkA);
    SodiumBackend.x25519Base(skB, pkB);

    ubyte[32] sharedAB = void, sharedBA = void;
    assert(SodiumBackend.x25519(skA, pkB, sharedAB));
    assert(SodiumBackend.x25519(skB, pkA, sharedBA));
    assert(sharedAB == sharedBA);
}

/// `x25519Base` matches the RFC 7748 §6.1 Alice key-pair: from her private
/// key, the derived public key equals the published value.
@("crypto.sodium.x25519Base.rfc7748")
@safe nothrow @nogc
unittest
{
    const alicePriv = fromHex!32(
        "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
    const alicePubExpected = fromHex!32(
        "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a");

    ubyte[32] alicePub = void;
    SodiumBackend.x25519Base(alicePriv, alicePub);
    assert(alicePub == alicePubExpected);
}

/// Ed25519 → X25519 conversion is consistent: converting both halves of an
/// Ed25519 key pair yields an X25519 key pair where the public key equals the
/// base-point multiple of the secret key.
@("crypto.sodium.ed25519ToX25519.consistency")
@system nothrow @nogc
unittest
{
    // Generate an Ed25519 key pair via libsodium's keypair function.
    alias KeypairFn = extern(C) int function(scope ubyte*, scope ubyte*)
        @nogc nothrow @system;
    ubyte[32] edPk = void;
    ubyte[64] edSk = void;
    (cast(KeypairFn) &crypto_sign_ed25519_keypair)(edPk.ptr, edSk.ptr);

    ubyte[32] curvePk = void, curveSk = void;
    SodiumBackend.ed25519PkToX25519(edPk, curvePk);
    SodiumBackend.ed25519SkToX25519(edSk, curveSk);

    // The converted public key must be the X25519 base-point multiple of the
    // converted secret key.
    ubyte[32] derivedPk = void;
    SodiumBackend.x25519Base(curveSk, derivedPk);
    assert(derivedPk == curvePk);
}

/// `ctEquals` is `true` for identical slices, `false` on a single differing
/// byte, and `false` on a length mismatch; empty slices compare equal.
@("crypto.sodium.ctEquals")
@safe nothrow @nogc
unittest
{
    static immutable ubyte[4] a = [1, 2, 3, 4];
    static immutable ubyte[4] b = [1, 2, 3, 4];
    static immutable ubyte[4] c = [1, 2, 3, 5];
    static immutable ubyte[3] d = [1, 2, 3];

    assert(SodiumBackend.ctEquals(a[], b[]));
    assert(!SodiumBackend.ctEquals(a[], c[]));
    assert(!SodiumBackend.ctEquals(a[], d[]));   // length mismatch
    assert(SodiumBackend.ctEquals(null, null));  // both empty
    assert(!SodiumBackend.ctEquals(a[], null));  // empty vs non-empty
}

/// `randomBytes` fills the whole buffer and is overwhelmingly unlikely to
/// return all zeros for a 32-byte draw; two draws differ.
@("crypto.sodium.randomBytes")
@safe nothrow @nogc
unittest
{
    ubyte[32] first = 0;
    ubyte[32] second = 0;
    SodiumBackend.randomBytes(first[]);
    SodiumBackend.randomBytes(second[]);

    ubyte[32] allZero = 0;
    assert(first != allZero);
    assert(second != allZero);
    assert(first != second);

    // A zero-length request is a no-op (no crash, nothing to fill).
    SodiumBackend.randomBytes(null);
}
