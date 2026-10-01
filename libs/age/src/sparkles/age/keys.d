/**
The age key schedule (§9): generating the file key and deriving the two keys
that hang off it — the header-MAC key and the per-file STREAM payload key.

Every age file is encrypted under a fresh 16-byte $(I file key) (a
[secret.SecretArray]`!16`, re-exported here as $(LREF FileKey)). The recipient
stanzas wrap this file key; everything else in the format is derived from it
with HKDF-SHA-256 ([hkdf.hkdfSha256]) under two fixed labels:

$(UL
    $(LI the $(B header MAC key) — `HKDF-SHA-256(ikm = file key, salt = "",
        info = "header")`, a 32-byte HMAC key that authenticates the header
        (§7.4); see $(LREF macKey).)
    $(LI the $(B payload key) — `HKDF-SHA-256(ikm = file key, salt = nonce,
        info = "payload")`, the 32-byte STREAM key, salted by the 16-byte
        payload nonce that follows the header on the wire (§7.5); see
        $(LREF payloadKey).))

$(LREF payloadKey) is the decrypt-side gate: before it hands back a payload key
it $(B verifies the header MAC) (via [mac.verifyHeaderMac] under
$(LREF macKey)), failing with `DecryptErrorCode.invalidMac` if the header was
tampered with. This mirrors rage's `v1_payload_key`, which calls
`header.verify_mac(mac_key(file_key))?` before deriving the payload key.

Faithful port of rage's `age/src/keys.rs` (`new_file_key`, `mac_key`,
`v1_payload_key`). Conventions: `@safe`; these functions wrap libsodium-backed
HKDF/CSPRNG so they are `@safe nothrow @nogc` but $(B not) `pure` (and
$(LREF newFileKey), which runs the `SecretArray` zeroizing-destructor machinery,
is `@safe` only).

See `docs/specs/age/SPEC.md` §9 and `https://c2sp.org/age`.

Copyright: © 2026, Petar Kirov
License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
Authors: Petar Kirov
*/
module sparkles.age.keys;

import sparkles.crypto.hkdf : hkdfSha256;
import sparkles.crypto.random : randomBytes;
import sparkles.crypto.secret : SecretArray;

import sparkles.age.errors : DecryptError, DecryptErrorCode, DecryptExpected,
    decryptErr, decryptOk;
import sparkles.age.mac : headerMacBytes, verifyHeaderMac;

@safe:

/**
The age $(B file key): 16 secret bytes, one per encrypted file (§9).

A re-export of [secret.SecretArray]`!16`. It is non-copyable
(`@disable this(this)`) and zeroizes on destruction, so it is passed by `in`
reference (never through `Expected`/`Nullable`) and filled in place on the
decrypt side. The recipient stanzas wrap it; $(LREF macKey) and
$(LREF payloadKey) derive the header-MAC and payload keys from it.
*/
alias FileKey = SecretArray!16;

/// The fixed HKDF `info` label for the header-MAC key derivation (§7.4 / §9).
private enum string headerKeyLabel = "header";

/// The fixed HKDF `info` label for the STREAM payload-key derivation (§7.5 / §9).
private enum string payloadKeyLabel = "payload";

/**
Generates a fresh 16-byte file key from the OS CSPRNG (§9).

Fills a new [FileKey]'s inline storage directly via
[secret.SecretArray.initWithMut] + [random.randomBytes], so the 16 random bytes
never live in an intermediate stack buffer. Returned by value (NRVO/move) — the
file key is non-copyable, so it is consumed by reference everywhere else.

This is the only key-schedule function that is $(B not) `nothrow @nogc`: it runs
through `SecretArray`'s `initWithMut` delegate machinery and zeroizing
destructor, which carry no such attributes.

Returns: a fresh, random [FileKey].
*/
FileKey newFileKey()
{
    return FileKey.initWithMut((ref ubyte[16] bytes) => randomBytes(bytes[]));
}

/**
Derives the 32-byte header-MAC key from `fileKey` (§7.4).

`macKey = HKDF-SHA-256(ikm = fileKey bytes, salt = "", info = "header")`. The
empty salt selects RFC 5869's 32-byte zero salt (handled by
[hkdf.hkdfSha256]). The result is the HMAC-SHA-256 key that
[mac.computeHeaderMac]/[mac.verifyHeaderMac] use to authenticate the header.

Params:
    fileKey = the file key (consumed by `in` reference, never copied)
Returns: the 32-byte header-MAC (HMAC) key.
*/
ubyte[32] macKey(in FileKey fileKey) nothrow @nogc
{
    ubyte[32] key = void;
    hkdfSha256(
        /* salt */ null,
        /* info */ cast(const(ubyte)[]) headerKeyLabel,
        /* ikm  */ fileKey.exposeSecret(),
        key[]);
    return key;
}

/**
Verifies the header MAC, then derives the 32-byte STREAM payload key (§7.5).

First recomputes and constant-time-compares the header MAC
([mac.verifyHeaderMac] under $(LREF macKey)); a mismatch is the
`DecryptErrorCode.invalidMac` gate that rejects a tampered header before any
payload key is exposed. On success, derives
`payloadKey = HKDF-SHA-256(ikm = fileKey bytes, salt = nonce, info = "payload")`,
where `nonce` is the 16-byte payload nonce that follows the header on the wire.

Mirrors rage's `v1_payload_key`: `header.verify_mac(mac_key(file_key))?` then
`hkdf(nonce, "payload", file_key)`.

Params:
    fileKey   = the file key (consumed by `in` reference, never copied)
    macInput  = the header's exact wire bytes through `---` (see
                [mac.computeHeaderMac])
    headerMac = the 32-byte tag parsed from the `--- <base64 MAC>` line
    nonce     = the 16-byte STREAM payload nonce (HKDF salt)
Returns: the 32-byte payload key on success, or
    `DecryptErrorCode.invalidMac` if the header MAC does not verify.
*/
DecryptExpected!(ubyte[32]) payloadKey(
    in FileKey fileKey,
    scope const(ubyte)[] macInput,
    in ubyte[headerMacBytes] headerMac,
    in ubyte[16] nonce) nothrow @nogc
{
    // The MAC gate: reject a tampered header before deriving anything.
    if (!verifyHeaderMac(macKey(fileKey), macInput, headerMac))
        return decryptErr!(ubyte[32])(DecryptErrorCode.invalidMac);

    ubyte[32] key = void;
    hkdfSha256(
        /* salt */ nonce[],
        /* info */ cast(const(ubyte)[]) payloadKeyLabel,
        /* ikm  */ fileKey.exposeSecret(),
        key[]);
    return decryptOk(key);
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit Tests
// ─────────────────────────────────────────────────────────────────────────────

/// $(LREF newFileKey) yields 16 bytes that differ between calls (a fresh CSPRNG
/// draw each time, never all-zero).
@("age.keys.newFileKey.freshAndDistinct")
@safe
unittest
{
    auto a = newFileKey();
    auto b = newFileKey();

    assert(a.exposeSecret().length == 16);
    assert(b.exposeSecret().length == 16);

    // Probabilistically: never the all-zero key and never equal to each other.
    static immutable ubyte[16] allZero = 0;
    assert(a.exposeSecret() != allZero[]);
    assert(b.exposeSecret() != allZero[]);
    assert(a.exposeSecret() != b.exposeSecret(),
        "two file keys collided (CSPRNG failure?)");
}

/// $(LREF macKey) is a deterministic function of the file key: a fixed file key
/// always derives the same 32-byte MAC key, while a different file key derives a
/// different one.
@("age.keys.macKey.deterministic")
@safe
unittest
{
    // A fixed file key (bytes 0..15) derives a stable MAC key.
    ubyte[16] raw = void;
    foreach (i; 0 .. 16)
        raw[i] = cast(ubyte) i;
    auto fk = FileKey.fromBytes(raw);

    const k1 = macKey(fk);
    const k2 = macKey(fk);
    assert(k1 == k2, "macKey is not deterministic for a fixed file key");

    // A one-bit-different file key derives a different MAC key.
    raw[0] ^= 0x01;
    auto fk2 = FileKey.fromBytes(raw);
    assert(macKey(fk2) != k1, "distinct file keys derived the same MAC key");
}

/// $(LREF payloadKey) rejects a header whose MAC does not verify
/// (`invalidMac`), and on a correctly-MAC'd header returns a 32-byte payload
/// key. The valid MAC is constructed in-test via [mac.computeHeaderMac] under
/// the very [macKey] this module derives, so the round-trip is self-consistent.
@("age.keys.payloadKey.macGate")
@safe
unittest
{
    import sparkles.age.mac : computeHeaderMac;

    // A fixed file key and a representative header-minus-MAC slice.
    ubyte[16] raw = void;
    foreach (i; 0 .. 16)
        raw[i] = cast(ubyte)(0xA0 + i);
    auto fk = FileKey.fromBytes(raw);

    static immutable string headerMinusMac =
        "age-encryption.org/v1\n"
        ~ "-> X25519 abc\n"
        ~ "GbcEAQ\n"
        ~ "---";
    immutable(ubyte)[] macInput = cast(immutable(ubyte)[]) headerMinusMac;

    // A 16-byte payload nonce (the HKDF salt).
    ubyte[16] nonce = void;
    foreach (i; 0 .. 16)
        nonce[i] = cast(ubyte)(i * 7);

    // The correct MAC under the key this module derives.
    const goodMac = computeHeaderMac(macKey(fk), macInput);

    // Valid MAC -> a 32-byte payload key.
    {
        auto pk = payloadKey(fk, macInput, goodMac, nonce);
        assert(pk.hasValue, "payloadKey rejected a correctly-MAC'd header");
        assert(pk.value.length == 32);
    }

    // The derived payload key is deterministic and equals the direct HKDF.
    {
        import sparkles.crypto.hkdf : hkdfSha256;

        ubyte[32] expected = void;
        hkdfSha256(nonce[], cast(const(ubyte)[]) "payload",
            fk.exposeSecret(), expected[]);

        auto pk = payloadKey(fk, macInput, goodMac, nonce);
        assert(pk.hasValue);
        assert(pk.value == expected, "payload key did not match direct HKDF");
    }

    // A tampered MAC (one bit flipped) -> invalidMac, no key exposed.
    {
        ubyte[headerMacBytes] badMac = goodMac;
        badMac[0] ^= 0x01;
        auto pk = payloadKey(fk, macInput, badMac, nonce);
        assert(!pk.hasValue, "payloadKey accepted a tampered header MAC");
        assert(pk.error.code == DecryptErrorCode.invalidMac);
    }

    // A MAC valid under a *different* file key must not verify here either.
    {
        ubyte[16] otherRaw = raw;
        otherRaw[5] ^= 0x80;
        auto otherFk = FileKey.fromBytes(otherRaw);
        const otherMac = computeHeaderMac(macKey(otherFk), macInput);

        auto pk = payloadKey(fk, macInput, otherMac, nonce);
        assert(!pk.hasValue, "a MAC from the wrong file key verified");
        assert(pk.error.code == DecryptErrorCode.invalidMac);
    }
}
