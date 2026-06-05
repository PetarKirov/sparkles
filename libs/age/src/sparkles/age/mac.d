/**
The age header MAC (§7.4): $(LREF computeHeaderMac) and $(LREF verifyHeaderMac).

The final header line is `--- <base64 MAC>`, where the MAC authenticates the
entire header up to and including the `---` mark (excluding the space that
follows it and the base64 MAC itself). It is computed with HMAC-SHA-256 (RFC
2104) over those exact wire bytes, under a 32-byte key derived from the file
key via HKDF (`HMAC key = HKDF-SHA-256(ikm = file key, salt = empty,
info = "header")`; the derivation lives in `sparkles.age.keys`, M6).

This module is the thin §7.4 layer over the
[hmac.HmacWriter]/[hmac.hmacSha256] primitive: it names the `macInput`
convention shared by `parseHeader`/`buildHeader` (M6) and verifies an
attacker-supplied tag in $(B constant time) via [ct.ctEquals]. The 32-byte tag
base64-encodes (unpadded) to exactly 43 characters — the `43base64char` in the
MAC-line grammar.

Faithful port of rage's `HmacWriter` (`age/src/primitives.rs`) and the
`HeaderV1::verify_mac` MAC bytes-range (`age/src/format.rs`).

See `docs/specs/age/SPEC.md` §7.4 and `https://c2sp.org/age` ("Header MAC").

Copyright: © 2026, Petar Kirov
License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
Authors: Petar Kirov
*/
module sparkles.age.mac;

import sparkles.crypto.ct : ctEquals;
import sparkles.crypto.hmac : hmacSha256, hmacSha256TagBytes;

@safe nothrow @nogc:

/// Width of the header MAC tag, in bytes (HMAC-SHA-256 output).
enum size_t headerMacBytes = hmacSha256TagBytes;

static assert(headerMacBytes == 32,
    "the age header MAC is a 32-byte HMAC-SHA-256 tag");

/**
Computes the age header MAC over `macInput` under the 32-byte `hmacKey`.

`macInput` is the header's exact wire bytes from `age-encryption.org/v1\n`
$(B through) the `---` mark — that is, everything the MAC line authenticates,
$(B excluding) the space following `---`, the base64-encoded MAC, and that
line's terminating `\n`. Callers obtain this slice from the header layer
(`parseHeader` preserves `encodedBytes` and exposes a `macInput` helper;
`buildHeader` serializes the header-minus-MAC for signing).

The MAC is `HMAC-SHA-256(hmacKey, macInput)` (RFC 2104, §7.4); the result
base64-encodes (unpadded) to exactly 43 characters.

Params:
    hmacKey  = the 32-byte HMAC key (HKDF-derived from the file key, §7.4)
    macInput = the header wire bytes through `---` (see above); may be any length
Returns: the 32-byte HMAC-SHA-256 tag.
*/
ubyte[headerMacBytes] computeHeaderMac(
    in ubyte[32] hmacKey, scope const(ubyte)[] macInput)
{
    ubyte[headerMacBytes] tag = void;
    hmacSha256(hmacKey[], macInput, tag);
    return tag;
}

/**
Verifies, in constant time, that `expectedMac` is the correct header MAC for
`macInput` under `hmacKey`.

Recomputes `HMAC-SHA-256(hmacKey, macInput)` and compares it against the
attacker-supplied `expectedMac` with [ct.ctEquals], so the running time leaks
nothing about which (if any) byte first differs — the verification path runs
on header bytes an attacker may have tampered with (§7.4). A mismatch maps to
`DecryptErrorCode.invalidMac` at the header layer.

Params:
    hmacKey     = the 32-byte HMAC key (HKDF-derived from the file key, §7.4)
    macInput    = the header wire bytes through `---` (see $(LREF computeHeaderMac))
    expectedMac = the 32-byte tag parsed from the `--- <base64 MAC>` line
Returns: `true` iff the recomputed MAC equals `expectedMac`.
*/
bool verifyHeaderMac(
    in ubyte[32] hmacKey, scope const(ubyte)[] macInput, in ubyte[32] expectedMac)
{
    const computed = computeHeaderMac(hmacKey, macInput);
    return ctEquals(computed[], expectedMac[]);
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit Tests
// ─────────────────────────────────────────────────────────────────────────────

/// $(LREF computeHeaderMac) agrees with the one-shot [hmac.hmacSha256]
/// primitive over a fixed `macInput` and key (computed in-test, not pinned to
/// a magic constant), and $(LREF verifyHeaderMac) accepts the right tag while
/// rejecting a single-bit-flipped one.
@("age.mac.computeHeaderMac.matchesPrimitive")
@safe nothrow @nogc
unittest
{
    // A representative header-minus-MAC: the v1 version line, a single X25519
    // stanza, then the "---" mark — exactly the bytes §7.4 authenticates.
    static immutable string headerMinusMac =
        "age-encryption.org/v1\n"
        ~ "-> X25519 abc\n"
        ~ "GbcEAQ \n"
        ~ "---";
    immutable(ubyte)[] macInput = cast(immutable(ubyte)[]) headerMinusMac;

    // A fixed, non-trivial 32-byte key (bytes 0..31).
    ubyte[32] hmacKey = void;
    foreach (i; 0 .. 32)
        hmacKey[i] = cast(ubyte) i;

    // Reference tag straight from the underlying primitive.
    ubyte[32] reference = void;
    hmacSha256(hmacKey[], macInput, reference);

    const tag = computeHeaderMac(hmacKey, macInput);
    assert(tag == reference, "computeHeaderMac disagrees with hmacSha256");

    // verifyHeaderMac accepts the correct tag …
    assert(verifyHeaderMac(hmacKey, macInput, reference),
        "verifyHeaderMac rejected the correct MAC");

    // … and rejects a tag with a single bit flipped (first and last bytes).
    {
        ubyte[32] tampered = reference;
        tampered[0] ^= 0x01;
        assert(!verifyHeaderMac(hmacKey, macInput, tampered),
            "verifyHeaderMac accepted a tampered MAC (first byte)");
    }
    {
        ubyte[32] tampered = reference;
        tampered[$ - 1] ^= 0x80;
        assert(!verifyHeaderMac(hmacKey, macInput, tampered),
            "verifyHeaderMac accepted a tampered MAC (last byte)");
    }
}

/// The MAC is keyed: the same `macInput` under a different key yields a
/// different tag, and a tag computed under key A does not verify under key B.
@("age.mac.computeHeaderMac.keyDependent")
@safe nothrow @nogc
unittest
{
    immutable(ubyte)[] macInput =
        cast(immutable(ubyte)[]) "age-encryption.org/v1\n---";

    ubyte[32] keyA = 0x11;
    ubyte[32] keyB = 0x11;
    keyB[7] ^= 0x01; // differ in one key byte

    const tagA = computeHeaderMac(keyA, macInput);
    const tagB = computeHeaderMac(keyB, macInput);
    assert(tagA != tagB, "distinct keys produced the same MAC");

    assert(verifyHeaderMac(keyA, macInput, tagA));
    assert(!verifyHeaderMac(keyB, macInput, tagA),
        "a MAC verified under the wrong key");
}

/// The MAC tag base64-encodes (unpadded) to exactly 43 characters — the
/// `43base64char` field width of the `--- <base64 MAC>` line (§7.4).
@("age.mac.computeHeaderMac.encodesTo43Chars")
@safe nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;
    import sparkles.crypto.encoding.base64 : encodeBase64;

    ubyte[32] hmacKey = 0x2a;
    immutable(ubyte)[] macInput = cast(immutable(ubyte)[]) "header-bytes---";

    const tag = computeHeaderMac(hmacKey, macInput);

    // Unpadded standard base64 is the age wire form for the MAC line.
    SmallBuffer!(char, 64) buf;
    encodeBase64(tag[], buf);
    assert(buf[].length == 43,
        "a 32-byte MAC must encode (unpadded) to exactly 43 base64 chars");
}
