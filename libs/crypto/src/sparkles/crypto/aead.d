/**
 * ChaCha20-Poly1305 (IETF) authenticated encryption (§6).
 *
 * This is the AEAD age uses for both the per-file payload (in the STREAM
 * construction) and the per-recipient file-key wrap inside a stanza. The
 * algorithm tag $(LREF ChaCha20Poly1305) carries the fixed sizes (32-byte key,
 * 12-byte nonce, 16-byte tag) as compile-time constants and satisfies
 * $(REF isAead, sparkles,crypto,concepts), so $(REF Key, sparkles,crypto,concepts)`!ChaCha20Poly1305`,
 * $(REF Nonce, sparkles,crypto,concepts)`!ChaCha20Poly1305` and
 * $(REF Tag, sparkles,crypto,concepts)`!ChaCha20Poly1305` are well-formed.
 *
 * The free functions are templated on a crypto backend ($(D B = DefaultBackend))
 * and constrained on $(REF hasChaCha20Poly1305, sparkles,crypto,backend,traits),
 * forwarding to `B.chaCha20Poly1305Encrypt` / `B.chaCha20Poly1305Decrypt`:
 *
 * $(UL
 *   $(LI $(LREF aeadSeal) — encrypt-and-authenticate: writes
 *     `plaintext.length + 16` bytes (ciphertext ‖ tag) into the caller's
 *     buffer;)
 *   $(LI $(LREF aeadOpen) — verify-and-decrypt: returns `false` on a failed
 *     authentication, leaving the plaintext buffer undefined;)
 *   $(LI $(LREF aeadSealZero) / $(LREF aeadOpenZero) — the same with an
 *     all-zero 12-byte nonce, the form age uses to wrap the file key in each
 *     stanza (a fresh key makes the constant nonce safe).)
 * )
 *
 * $(LREF StreamNonce) is the 12-byte nonce of the age STREAM payload AEAD: an
 * 11-byte big-endian chunk counter followed by a 1-byte last-chunk flag.
 *
 * Like the rest of the libsodium-backed surface, these functions are
 * `@safe nothrow @nogc` but $(B not) `pure` (see §6). `StreamNonce` itself is
 * pure value manipulation and stays `@safe pure nothrow @nogc`.
 *
 * See `docs/specs/age/SPEC.md` §6 (primitives) for the normative description.
 *
 * Copyright: © 2026, Petar Kirov
 * License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Authors: Petar Kirov
 */
module sparkles.crypto.aead;

import sparkles.crypto.backend : DefaultBackend, hasChaCha20Poly1305, isCryptoBackend;
import sparkles.crypto.concepts : isAead, Key, Nonce;

/**
 * Algorithm tag for ChaCha20-Poly1305 (IETF, 12-byte nonce).
 *
 * A zero-size marker carrying the fixed sizes as compile-time constants;
 * never instantiated. It satisfies $(REF isAead, sparkles,crypto,concepts),
 * so the size aliases $(REF Key, sparkles,crypto,concepts)`!ChaCha20Poly1305`
 * (32), $(REF Nonce, sparkles,crypto,concepts)`!ChaCha20Poly1305` (12) and
 * $(REF Tag, sparkles,crypto,concepts)`!ChaCha20Poly1305` (16) resolve to the
 * right fixed-size arrays.
 */
struct ChaCha20Poly1305
{
    /// 32-byte key.
    enum size_t KEY_SIZE = 32;
    /// 12-byte (IETF) nonce.
    enum size_t NONCE_SIZE = 12;
    /// 16-byte Poly1305 authentication tag.
    enum size_t TAG_SIZE = 16;
}

/// `ChaCha20Poly1305` is a valid AEAD tag.
static assert(isAead!ChaCha20Poly1305);

@safe nothrow @nogc:

/**
 * Encrypt-and-authenticate `plaintext` with ChaCha20-Poly1305 (IETF).
 *
 * Writes the ciphertext followed by the 16-byte Poly1305 tag into
 * `ciphertext`, which the caller MUST size as `plaintext.length + 16`. The
 * `aad` (associated data) is authenticated but not encrypted.
 *
 * Params:
 *   key        = 32-byte key
 *   nonce      = 12-byte nonce; MUST be unique per key
 *   plaintext  = message to encrypt (may be empty)
 *   aad        = associated data to authenticate (may be empty)
 *   ciphertext = output, exactly `plaintext.length + 16` bytes
 *
 * See_Also: $(LREF aeadOpen), $(LREF aeadSealZero)
 */
void aeadSeal(B = DefaultBackend)(
    in Key!ChaCha20Poly1305 key, in Nonce!ChaCha20Poly1305 nonce,
    scope const(ubyte)[] plaintext, scope const(ubyte)[] aad, scope ubyte[] ciphertext)
if (isCryptoBackend!B && hasChaCha20Poly1305!B)
in (ciphertext.length == plaintext.length + ChaCha20Poly1305.TAG_SIZE,
    "aeadSeal: ciphertext.length must equal plaintext.length + 16")
{
    B.chaCha20Poly1305Encrypt(key, nonce, plaintext, aad, ciphertext);
}

/**
 * Verify-and-decrypt a ChaCha20-Poly1305 (IETF) ciphertext.
 *
 * Authenticates the trailing 16-byte tag against `key`/`nonce`/`aad` and, on
 * success, writes the recovered plaintext into `plaintext` (which the caller
 * MUST size as `ciphertext.length - 16`).
 *
 * Params:
 *   key        = 32-byte key
 *   nonce      = 12-byte nonce
 *   ciphertext = ciphertext ‖ tag, at least 16 bytes
 *   aad        = associated data that was authenticated at seal time
 *   plaintext  = output, exactly `ciphertext.length - 16` bytes
 * Returns: `true` if authentication succeeds; `false` otherwise, in which case
 *   `plaintext` MUST be treated as undefined.
 *
 * See_Also: $(LREF aeadSeal), $(LREF aeadOpenZero)
 */
bool aeadOpen(B = DefaultBackend)(
    in Key!ChaCha20Poly1305 key, in Nonce!ChaCha20Poly1305 nonce,
    scope const(ubyte)[] ciphertext, scope const(ubyte)[] aad, scope ubyte[] plaintext)
if (isCryptoBackend!B && hasChaCha20Poly1305!B)
in (ciphertext.length >= ChaCha20Poly1305.TAG_SIZE,
    "aeadOpen: ciphertext must be at least 16 bytes (the tag)")
in (plaintext.length == ciphertext.length - ChaCha20Poly1305.TAG_SIZE,
    "aeadOpen: plaintext.length must equal ciphertext.length - 16")
{
    return B.chaCha20Poly1305Decrypt(key, nonce, ciphertext, aad, plaintext);
}

/**
 * The all-zero 12-byte nonce used for stanza file-key wrapping.
 *
 * age wraps the file key under a per-recipient key with a constant nonce; this
 * is safe because that wrapping key is fresh for every recipient, so the
 * (key, nonce) pair is never reused.
 */
private enum Nonce!ChaCha20Poly1305 zeroNonce = 0;

/**
 * $(LREF aeadSeal) with the all-zero nonce (stanza file-key wrap).
 *
 * Equivalent to $(LREF aeadSeal) with a 12-byte zero nonce and no associated
 * data — the form age uses to wrap the file key in each recipient stanza. Safe
 * only because the wrapping `key` is fresh per recipient.
 *
 * Params:
 *   key        = 32-byte per-recipient wrapping key (MUST be fresh)
 *   plaintext  = the file key to wrap (may be any length)
 *   ciphertext = output, exactly `plaintext.length + 16` bytes
 *
 * See_Also: $(LREF aeadSeal), $(LREF aeadOpenZero)
 */
void aeadSealZero(B = DefaultBackend)(
    in Key!ChaCha20Poly1305 key, scope const(ubyte)[] plaintext, scope ubyte[] ciphertext)
if (isCryptoBackend!B && hasChaCha20Poly1305!B)
in (ciphertext.length == plaintext.length + ChaCha20Poly1305.TAG_SIZE,
    "aeadSealZero: ciphertext.length must equal plaintext.length + 16")
{
    aeadSeal!B(key, zeroNonce, plaintext, null, ciphertext);
}

/**
 * $(LREF aeadOpen) with the all-zero nonce (stanza file-key unwrap).
 *
 * Equivalent to $(LREF aeadOpen) with a 12-byte zero nonce and no associated
 * data.
 *
 * Params:
 *   key        = 32-byte per-recipient wrapping key
 *   ciphertext = wrapped file key ‖ tag, at least 16 bytes
 *   plaintext  = output, exactly `ciphertext.length - 16` bytes
 * Returns: `true` if authentication succeeds; `false` otherwise.
 *
 * See_Also: $(LREF aeadOpen), $(LREF aeadSealZero)
 */
bool aeadOpenZero(B = DefaultBackend)(
    in Key!ChaCha20Poly1305 key, scope const(ubyte)[] ciphertext, scope ubyte[] plaintext)
if (isCryptoBackend!B && hasChaCha20Poly1305!B)
in (ciphertext.length >= ChaCha20Poly1305.TAG_SIZE,
    "aeadOpenZero: ciphertext must be at least 16 bytes (the tag)")
in (plaintext.length == ciphertext.length - ChaCha20Poly1305.TAG_SIZE,
    "aeadOpenZero: plaintext.length must equal ciphertext.length - 16")
{
    return aeadOpen!B(key, zeroNonce, ciphertext, null, plaintext);
}

/**
 * The 12-byte nonce of the age STREAM payload AEAD.
 *
 * STREAM splits the plaintext into fixed-size chunks, each encrypted with
 * ChaCha20-Poly1305 under a nonce that encodes the chunk's position. The nonce
 * layout is, in order:
 *
 * $(UL
 *   $(LI bytes `0 … 10` — an 11-byte $(B big-endian) chunk counter, starting
 *     at 0 and incremented for each chunk;)
 *   $(LI byte `11` — the last-chunk flag: `0x01` for the final chunk, `0x00`
 *     otherwise.)
 * )
 *
 * Encoding the position in the nonce binds each chunk to its index and the
 * last-chunk flag prevents truncation: an attacker cannot drop trailing chunks
 * without the final flag failing to authenticate.
 *
 * `StreamNonce` is pure value manipulation and is `@safe pure nothrow @nogc`.
 */
struct StreamNonce
{
@safe pure nothrow @nogc:

    /// Byte index of the last-chunk flag within the 12-byte nonce.
    private enum size_t flagIndex = ChaCha20Poly1305.NONCE_SIZE - 1; // 11
    /// Width of the big-endian counter field (bytes `0 … 10`).
    private enum size_t counterBytes = flagIndex; // 11
    /// Last-chunk flag byte value.
    private enum ubyte lastFlag = 0x01;

    /// The 12 raw nonce bytes; counter starts at 0, not the last chunk.
    private ubyte[ChaCha20Poly1305.NONCE_SIZE] _bytes = 0;

    /**
     * Set the chunk counter to `value`, big-endian, in bytes `0 … 10`.
     *
     * `value` fits comfortably: the 11-byte field holds up to `2^88 - 1`, far
     * beyond a `ulong`, so the top 3 counter bytes are always cleared to zero
     * by this write. The last-chunk flag (byte 11) is left untouched.
     *
     * Params:
     *   value = the chunk index to encode
     */
    void setCounter(ulong value)
    {
        // High counter bytes above the 64-bit `value` are always zero.
        foreach (i; 0 .. counterBytes)
            _bytes[i] = 0;

        // Big-endian: the most-significant byte of `value` lands at the
        // right-most counter byte (index 10), the least-significant at the
        // lower indices, filling only the low 8 bytes of the 11-byte field.
        foreach (i; 0 .. ulong.sizeof)
            _bytes[flagIndex - 1 - i] = cast(ubyte)(value >> (8 * i));
    }

    /**
     * Increment the big-endian chunk counter by one.
     *
     * Asserts the 11-byte counter field does not overflow (an age file cannot
     * have `2^88` chunks). The last-chunk flag is left untouched.
     */
    void incrementCounter()
    {
        // Add 1 with carry, from the least-significant (right-most) byte.
        size_t i = counterBytes; // one past the field; loop steps to flagIndex-1
        do
        {
            --i;
            if (++_bytes[i] != 0)
                return; // no carry out of this byte
        }
        while (i != 0);

        // Wrapped all 11 bytes back to zero: overflow.
        assert(false, "StreamNonce.incrementCounter: 11-byte counter overflow");
    }

    /**
     * Set or clear the last-chunk flag (byte 11).
     *
     * Params:
     *   last = `true` to mark this the final chunk (`0x01`), `false` to clear
     *     it (`0x00`).
     */
    void setLast(bool last)
    {
        _bytes[flagIndex] = last ? lastFlag : 0x00;
    }

    /// Returns: `true` iff the last-chunk flag is set.
    bool isLast() const
        => _bytes[flagIndex] == lastFlag;

    /**
     * The 12 raw nonce bytes, ready to pass to $(LREF aeadSeal)/$(LREF aeadOpen).
     *
     * Returns: a `const` view of the internal 12-byte buffer.
     */
    const(ubyte)[ChaCha20Poly1305.NONCE_SIZE] bytes() const
        => _bytes;
}

// ─────────────────────────────────────────────────────────────────────────
// Tests — RFC 7539 §2.8.2 known-answer vector for the AEAD, plus the
// StreamNonce byte-layout invariants.
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

/// `aeadSeal` produces the documented RFC 7539 §2.8.2 ciphertext+tag and
/// `aeadOpen` round-trips it back to the plaintext.
@("crypto.aead.aeadSeal.rfc7539")
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
    assert(pt.length == 114);

    // RFC 7539 §2.8.2: 114-byte ciphertext followed by the 16-byte Poly1305
    // tag — 130 bytes total.
    const expectedCt = fromHex!130(
        "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d6"
        ~ "3dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b36"
        ~ "92ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc"
        ~ "3ff4def08e4b7a9de576d26586cec64b6116"
        ~ "1ae10b594f09e26a7e902ecbd0600691");

    ubyte[130] ct = void; // 114 plaintext + 16 tag
    aeadSeal(key, nonce, pt, aad[], ct[]);
    assert(ct == expectedCt);

    ubyte[114] recovered = void; // 130 - 16
    assert(aeadOpen(key, nonce, ct[], aad[], recovered[]));
    assert(recovered[] == pt);
}

/// Tampering with a single ciphertext byte makes `aeadOpen` report an
/// authentication failure (`false`).
@("crypto.aead.aeadOpen.tampered")
@safe nothrow @nogc
unittest
{
    const key = fromHex!32(
        "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f");
    const nonce = fromHex!12("070000004041424344454647");
    const aad = fromHex!12("50515253c0c1c2c3c4c5c6c7");

    static immutable ubyte[5] pt = ['h', 'e', 'l', 'l', 'o'];
    ubyte[21] ct = void; // 5 + 16
    aeadSeal(key, nonce, pt[], aad[], ct[]);

    // Round-trips before tampering.
    ubyte[5] ok = void;
    assert(aeadOpen(key, nonce, ct[], aad[], ok[]));
    assert(ok[] == pt[]);

    // Flip a ciphertext byte: authentication must fail.
    ubyte[21] tampered = ct;
    tampered[0] ^= 0x01;
    ubyte[5] discard = void;
    assert(!aeadOpen(key, nonce, tampered[], aad[], discard[]));

    // Flipping a tag byte (last byte) also fails.
    ubyte[21] tamperedTag = ct;
    tamperedTag[$ - 1] ^= 0x01;
    assert(!aeadOpen(key, nonce, tamperedTag[], aad[], discard[]));
}

/// The zero-nonce convenience pair seals and opens with the all-zero nonce and
/// no associated data; the ciphertext equals an explicit zero-nonce
/// `aeadSeal`.
@("crypto.aead.aeadSealZero.roundTrip")
@safe nothrow @nogc
unittest
{
    const key = fromHex!32(
        "0001020304050607000102030405060700010203040506070001020304050607");
    static immutable ubyte[16] fileKey =
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];

    ubyte[32] wrapped = void; // 16 + 16
    aeadSealZero(key, fileKey[], wrapped[]);

    // Same as an explicit all-zero nonce, empty AAD.
    ubyte[12] zero = 0;
    ubyte[32] explicit = void;
    aeadSeal(key, zero, fileKey[], null, explicit[]);
    assert(wrapped == explicit);

    ubyte[16] recovered = void;
    assert(aeadOpenZero(key, wrapped[], recovered[]));
    assert(recovered[] == fileKey[]);

    // A tampered wrap fails to open.
    ubyte[32] tampered = wrapped;
    tampered[3] ^= 0x80;
    ubyte[16] discard = void;
    assert(!aeadOpenZero(key, tampered[], discard[]));
}

/// A counter of 0 yields an all-zero nonce; counter 1 sets only the
/// least-significant counter byte (index 10), leaving the flag byte clear.
@("crypto.aead.StreamNonce.counterLayout")
@safe pure nothrow @nogc
unittest
{
    StreamNonce n;
    // Default-constructed: counter 0, not last.
    const zero = fromHex!12("000000000000000000000000");
    assert(n.bytes == zero);
    assert(!n.isLast);

    n.setCounter(1);
    // Big-endian: the 1 lands in the right-most counter byte (index 10),
    // i.e. just before the flag byte; flag stays 0.
    const one = fromHex!12("000000000000000000000100");
    assert(n.bytes == one);
    assert(!n.isLast);

    // A larger value spans multiple counter bytes, big-endian, still within
    // the 11-byte field and never touching the flag byte.
    n.setCounter(0x0102_0304);
    const big = fromHex!12("000000000000000102030400");
    assert(n.bytes == big);
    assert(!n.isLast);
}

/// `setLast` toggles only byte 11 and `isLast` reflects it, independent of the
/// counter.
@("crypto.aead.StreamNonce.lastFlag")
@safe pure nothrow @nogc
unittest
{
    StreamNonce n;
    n.setCounter(0);
    n.setLast(true);
    assert(n.isLast);
    // Counter 0, last flag set: only byte 11 is 0x01.
    const lastZero = fromHex!12("000000000000000000000001");
    assert(n.bytes == lastZero);

    // The flag is independent of the counter value.
    n.setCounter(1);
    assert(n.isLast); // setCounter must not clear the flag
    const lastOne = fromHex!12("000000000000000000000101");
    assert(n.bytes == lastOne);

    // Clearing it sets byte 11 back to 0.
    n.setLast(false);
    assert(!n.isLast);
    const cleared = fromHex!12("000000000000000000000100");
    assert(n.bytes == cleared);
}

/// `incrementCounter` carries correctly across byte boundaries and never
/// disturbs the last-chunk flag.
@("crypto.aead.StreamNonce.increment")
@safe pure nothrow @nogc
unittest
{
    StreamNonce n;
    n.incrementCounter();
    // 0 -> 1
    assert(n.bytes == fromHex!12("000000000000000000000100"));

    // Set up a value that carries: 0x00FF, incrementing rolls the low byte to
    // 0 and bumps the next byte to 0x01 -> 0x0100.
    n.setCounter(0x00FF);
    n.incrementCounter();
    assert(n.bytes == fromHex!12("000000000000000000010000"));

    // The carry must not bleed into the last-chunk flag. Set the flag, take a
    // value whose low byte is 0xFF, increment, and confirm the flag survives.
    n.setCounter(0xFF);
    n.setLast(true);
    n.incrementCounter();
    // counter 0xFF -> 0x0100 (byte index 9 = 0x01, index 10 = 0x00), flag 0x01.
    assert(n.bytes == fromHex!12("000000000000000000010001"));
    assert(n.isLast);
}

/// A `StreamNonce` drives the payload AEAD end-to-end: two chunks at counter 0
/// and 1 (the second marked last) round-trip, and swapping their nonces makes
/// authentication fail (proving the position binding).
@("crypto.aead.StreamNonce.payloadBinding")
@safe nothrow @nogc
unittest
{
    const key = fromHex!32(
        "0f0e0d0c0b0a09080706050403020100000102030405060708090a0b0c0d0e0f");

    static immutable ubyte[4] chunk0 = ['c', 'h', 'k', '0'];
    static immutable ubyte[4] chunk1 = ['c', 'h', 'k', '1'];

    StreamNonce n0;
    n0.setCounter(0);
    StreamNonce n1;
    n1.setCounter(1);
    n1.setLast(true);

    ubyte[20] ct0 = void, ct1 = void; // 4 + 16
    aeadSeal(key, n0.bytes, chunk0[], null, ct0[]);
    aeadSeal(key, n1.bytes, chunk1[], null, ct1[]);

    ubyte[4] r0 = void, r1 = void;
    assert(aeadOpen(key, n0.bytes, ct0[], null, r0[]));
    assert(aeadOpen(key, n1.bytes, ct1[], null, r1[]));
    assert(r0[] == chunk0[]);
    assert(r1[] == chunk1[]);

    // Opening chunk 1 (the last chunk) under chunk 0's nonce must fail: the
    // counter and last-chunk flag are bound into the AEAD nonce.
    ubyte[4] discard = void;
    assert(!aeadOpen(key, n0.bytes, ct1[], null, discard[]));
}
