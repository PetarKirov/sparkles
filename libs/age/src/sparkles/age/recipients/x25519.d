/**
The native age $(B X25519) recipient and identity types (§8) — the classic,
anonymous public-key recipient that every age implementation supports.

An $(LREF X25519Recipient) is a 32-byte Curve25519 public key, serialized as a
bech32 `age1…` string; the matching $(LREF X25519Identity) is a 32-byte secret
scalar, serialized as an uppercase bech32 `AGE-SECRET-KEY-1…` string. Together
they implement the recipient/identity protocol from
$(REF isRecipient, sparkles,age,recipient) /
$(REF isIdentity, sparkles,age,identity):

$(UL
    $(LI $(B Wrapping) (encrypt side, $(LREF X25519Recipient.wrapFileKey)) draws a
        fresh ephemeral secret `esk`, computes the ephemeral share
        `epk = X25519(esk, basepoint)` and the shared secret
        `X25519(esk, recipient)`, derives a wrap key with HKDF-SHA-256 over the
        label `"age-encryption.org/v1/X25519"` and the salt `epk ‖ recipient`,
        and ChaCha20-Poly1305-seals the file key under it (zero nonce). The
        stanza is `-> X25519 <base64(epk)>` with the 32-byte sealed body, and the
        recipient's label set is $(B empty).)
    $(LI $(B Unwrapping) (decrypt side, $(LREF X25519Identity.unwrapStanza))
        ignores any non-`X25519` stanza; rejects a malformed one
        (`args.length != 1`, a non-canonical base64 share, or a body that is not
        exactly 32 bytes) as `invalidHeader`; recomputes the shared secret
        `X25519(identity, epk)` ($(B aborting) on an all-zero result); re-derives
        the same wrap key; and tries to open the body. An AEAD failure is
        $(B not) fatal — it just means the stanza belongs to another recipient
        (the identity returns the not-mine `null` outcome).)
)

This is a faithful port of rage's `age/src/native/x25519.rs`; the exact
derivation strings and the canonicality requirements come from the
$(LINK2 https://c2sp.org/age, C2SP age spec) "X25519 recipient type" section and
`docs/specs/age/SPEC.md` §8.

This layer MAY use the GC: $(LREF X25519Recipient.wrapFileKey) returns a
$(REF WrapResult, sparkles,age,recipient) whose `Stanza[]` / `string[]` arrays
and the stanza body are GC-owned.

Copyright: © 2026, Petar Kirov
License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
Authors: Petar Kirov
*/
module sparkles.age.recipients.x25519;

import std.typecons : nullable;

import sparkles.crypto.aead : aeadOpenZero, aeadSealZero, ChaCha20Poly1305;
import sparkles.crypto.encoding.base64 :
    base64MaxDecodedLength, decodeBase64, encodeBase64;
import sparkles.crypto.encoding.bech32 :
    bech32EncodedLength, bech32MaxDecodedLength, decodeBech32, encodeBech32;
import sparkles.crypto.hkdf : hkdfSha256;
import sparkles.crypto.random : randomArray;
import sparkles.crypto.secret : SecretArray;
import sparkles.crypto.x25519 : x25519, x25519Base;

import sparkles.core_cli.text.errors :
    NoGcHook, ParseErrorCode, ParseExpected, parseErr, parseOk;

import sparkles.age.errors :
    EncryptErrorCode, EncryptExpected, encryptErr, encryptOk;
import sparkles.age.format.stanza : Stanza;
import sparkles.age.identity : isIdentity, UnwrapOutcome, unwrapDone, unwrapFail, unwrapSkip;
import sparkles.age.keys : FileKey;
import sparkles.age.recipient : isRecipient, WrapResult;

@safe:

// ─────────────────────────────────────────────────────────────────────────────
// Shared constants (§8 / C2SP "X25519 recipient type")
// ─────────────────────────────────────────────────────────────────────────────

/// The stanza tag for an X25519 recipient stanza (the first first-line token).
private enum string X25519_TAG = "X25519";

/// The fixed HKDF `info` label for the X25519 wrap-key derivation (§8).
private enum string X25519_KEY_LABEL = "age-encryption.org/v1/X25519";

/// bech32 human-readable part for a public `age1…` recipient.
private enum string PUBLIC_KEY_HRP = "age";

/// bech32 human-readable part for an `AGE-SECRET-KEY-1…` identity. Encoding uses
/// this lowercase form (the bech32 checksum is computed over the lowercased
/// hrp), then the whole string is uppercased; decoding compares the recovered
/// hrp against it case-insensitively.
private enum string SECRET_KEY_HRP = "age-secret-key-";

/// Length of the Curve25519 public key / ephemeral share / secret scalar.
private enum size_t KEY_BYTES = 32;

/// Length of the wrapped (sealed) file key: 16 plaintext bytes + the 16-byte
/// Poly1305 tag.
private enum size_t WRAPPED_FILE_KEY_BYTES = FileKey.length + ChaCha20Poly1305.TAG_SIZE;

// ─────────────────────────────────────────────────────────────────────────────
// Wrap-key derivation (shared by both sides)
// ─────────────────────────────────────────────────────────────────────────────

/**
Derives the 32-byte X25519 wrap key from a `sharedSecret`, the ephemeral share
`epk`, and the `recipient` public key.

`wrapKey = HKDF-SHA-256(ikm = sharedSecret, salt = epk ‖ recipient,
info = "age-encryption.org/v1/X25519")`. Both the encrypt side (which knows the
shared secret as `X25519(esk, recipient)`) and the decrypt side (which knows it
as `X25519(identity, epk)`) call this with the $(I same) `epk`/`recipient`
ordering, so they derive the same key.
*/
private ubyte[32] x25519WrapKey(
    in ubyte[KEY_BYTES] sharedSecret,
    in ubyte[KEY_BYTES] epk,
    in ubyte[KEY_BYTES] recipient) nothrow @nogc
{
    // salt = ephemeral share (32) ‖ recipient public key (32).
    ubyte[2 * KEY_BYTES] salt = void;
    salt[0 .. KEY_BYTES] = epk[];
    salt[KEY_BYTES .. $] = recipient[];

    ubyte[32] wrapKey = void;
    hkdfSha256(
        /* salt */ salt[],
        /* info */ cast(const(ubyte)[]) X25519_KEY_LABEL,
        /* ikm  */ sharedSecret[],
        wrapKey[]);
    return wrapKey;
}

// ─────────────────────────────────────────────────────────────────────────────
// X25519Recipient
// ─────────────────────────────────────────────────────────────────────────────

/**
The classic age recipient: a 32-byte Curve25519 public key, serialized as a
bech32 `age1…` string (a faithful port of rage's `x25519::Recipient`).

This recipient type is $(I anonymous): an attacker cannot tell from the
encrypted file alone whether it was encrypted to a particular recipient. The
public key is not secret, so this struct is a plain copyable value.

Build one with $(LREF parse) (from an `age1…` string) or
$(REF X25519Identity.toPublic, sparkles,age,recipients,x25519); serialize it
back with $(LREF toString); and wrap a file key for it with
$(LREF wrapFileKey), which satisfies $(REF isRecipient, sparkles,age,recipient).
*/
struct X25519Recipient
{
    /// The 32-byte Curve25519 public key.
    private ubyte[KEY_BYTES] _publicKey;

    /**
    Constructs a recipient directly from its 32 raw public-key bytes.

    The bytes are taken as-is (no validation — every 32-byte string is a valid
    Curve25519 public key encoding). Prefer $(LREF parse) for the textual
    `age1…` form.
    */
    this(in ubyte[KEY_BYTES] publicKey) pure nothrow @nogc
    {
        _publicKey = publicKey;
    }

    /// The 32 raw public-key bytes (a copy).
    ubyte[KEY_BYTES] publicKey() const pure nothrow @nogc
        => _publicKey;

    /**
    Parses a recipient from its bech32 `age1…` string.

    The string is bech32-decoded; the human-readable part MUST be `"age"` and
    the payload MUST be exactly 32 bytes. A bech32 error (bad checksum,
    mixed case, etc.) is propagated; a wrong hrp or payload length is reported
    as `ParseErrorCode.invalidIdentifier`.

    Params:
        s = the `age1…` recipient string
    Returns: the parsed $(LREF X25519Recipient), or a `ParseError`.
    */
    static ParseExpected!X25519Recipient parse(scope const(char)[] s) nothrow @nogc
    {
        alias R = X25519Recipient;

        ubyte[bech32MaxDecodedLength(maxParseLen)] buf = void;
        if (s.length > maxParseLen)
            return parseErr!R(ParseErrorCode.invalidIdentifier, 0);

        const(char)[] hrp;
        auto decoded = decodeBech32(s, hrp, buf[0 .. bech32MaxDecodedLength(s.length)]);
        if (!decoded.hasValue)
            return parseErr!R(decoded.error);

        if (!equalsAsciiCI(hrp, PUBLIC_KEY_HRP) || decoded.value.length != KEY_BYTES)
            return parseErr!R(ParseErrorCode.invalidIdentifier, 0);

        ubyte[KEY_BYTES] pk = decoded.value[0 .. KEY_BYTES];
        return parseOk!R(R(pk));
    }

    /**
    Renders this recipient as its canonical lowercase bech32 `age1…` string into
    the output range `w`. `@safe`, and `@nogc` when `w` is.
    */
    void toString(W)(ref W w) const
    {
        encodeBech32(PUBLIC_KEY_HRP, _publicKey[], w);
    }

    /**
    Wraps `fileKey` for this recipient, producing a single `X25519` stanza and an
    $(B empty) label set (§8).

    Draws a fresh 32-byte ephemeral secret `esk`, computes the ephemeral share
    `epk = X25519(esk, basepoint)` and the shared secret
    `X25519(esk, recipient)`, derives the wrap key (see $(LREF x25519WrapKey)),
    and ChaCha20-Poly1305-seals the file key under it with a zero nonce. The
    stanza body is the 32-byte sealed key; the single argument is the
    base64-encoded ephemeral share.

    Returns: a $(REF WrapResult, sparkles,age,recipient) with one stanza and no
        labels, or `EncryptErrorCode.wrapFailed` on the vanishingly unlikely
        all-zero shared secret (a sign of a failing CSPRNG; rage panics here).
    */
    EncryptExpected!WrapResult wrapFileKey(in FileKey fileKey) const
    {
        // Fresh ephemeral key pair for this stanza (a new one per stanza/file).
        const esk = randomArray!KEY_BYTES();
        ubyte[KEY_BYTES] epk = void;
        x25519Base(esk, epk);

        // shared secret = X25519(esk, recipient). An all-zero result is a
        // non-contributory exchange; rage panics ("OS RNG is likely failing"),
        // we surface it as a hard wrap failure rather than abort the process.
        ubyte[KEY_BYTES] shared_ = void;
        if (!x25519(esk, _publicKey, shared_))
            return encryptErr!WrapResult(EncryptErrorCode.wrapFailed);

        const wrapKey = x25519WrapKey(shared_, epk, _publicKey);

        // body = ChaCha20-Poly1305(wrapKey, fileKey) under the zero nonce.
        auto body_ = new ubyte[WRAPPED_FILE_KEY_BYTES];
        aeadSealZero(wrapKey, fileKey.exposeSecret(), body_);

        // arg = base64(epk), unpadded — built as an owned immutable string.
        const string epkArg = base64String(epk[]);

        auto stanzas = [Stanza(X25519_TAG, [epkArg], body_)];
        return encryptOk(WrapResult(stanzas, null));
    }

    /// The longest `age1…` string $(LREF parse) will consider before rejecting
    /// it outright: an `age1` prefix wrapping a generous over-estimate of a
    /// 32-byte payload. Anything longer cannot be a valid 32-byte recipient.
    private enum size_t maxParseLen = bech32EncodedLength(PUBLIC_KEY_HRP.length, KEY_BYTES) + 8;
}

// ─────────────────────────────────────────────────────────────────────────────
// X25519Identity
// ─────────────────────────────────────────────────────────────────────────────

/**
The classic age identity: a 32-byte Curve25519 secret scalar, serialized as an
uppercase bech32 `AGE-SECRET-KEY-1…` string (a faithful port of rage's
`x25519::Identity`).

The scalar is held in a $(REF SecretArray, sparkles,crypto,secret)`!32`, so it
zeroizes on destruction and is non-copyable; an $(LREF X25519Identity) therefore
moves rather than copies (it can still live inside the
$(REF AnyIdentity, sparkles,age,identity) sum type, which is constructed by
move).

Create one with $(LREF generate) (fresh CSPRNG scalar) or $(LREF parse) (from an
`AGE-SECRET-KEY-1…` string); recover its public recipient with $(LREF toPublic);
serialize it with $(LREF toString); and unwrap a header stanza with
$(LREF unwrapStanza), which satisfies
$(REF isIdentity, sparkles,age,identity).
*/
struct X25519Identity
{
    /// The 32-byte secret scalar, zeroized on destruction.
    private SecretArray!KEY_BYTES _scalar;

    @disable this(this);

    /**
    Constructs an identity directly from its 32 raw scalar bytes.

    The bytes are copied into the secret storage; the caller remains responsible
    for wiping any temporary holding `scalar`.
    */
    static X25519Identity fromScalar(in ubyte[KEY_BYTES] scalar) nothrow @nogc
    {
        X25519Identity id;
        id._scalar = SecretArray!KEY_BYTES.fromBytes(scalar);
        return id;
    }

    /**
    Generates a fresh identity from the OS CSPRNG.

    The 32 random bytes are drawn directly into the secret storage (no
    intermediate stack copy), matching $(REF newFileKey, sparkles,age,keys).
    Curve25519 clamps the scalar internally on use, so any 32-byte draw is a
    valid secret key.
    */
    static X25519Identity generate()
    {
        X25519Identity id;
        id._scalar = SecretArray!KEY_BYTES.initWithMut((ref ubyte[KEY_BYTES] b) {
            import sparkles.crypto.random : randomBytes;

            randomBytes(b[]);
        });
        return id;
    }

    /**
    Returns the public $(LREF X25519Recipient) for this identity:
    `recipient = X25519(scalar, basepoint)`.
    */
    X25519Recipient toPublic() const nothrow @nogc
    {
        ubyte[KEY_BYTES] pk = void;
        ubyte[KEY_BYTES] scalar = _scalar.exposeSecret()[0 .. KEY_BYTES];
        x25519Base(scalar, pk);
        return X25519Recipient(pk);
    }

    /**
    Parses an identity from its bech32 `AGE-SECRET-KEY-1…` string.

    The string is bech32-decoded (the decoder accepts the uppercase form); the
    human-readable part is compared case-insensitively against
    `"age-secret-key-"` and the payload MUST be exactly 32 bytes. A bech32 error
    is propagated; a wrong hrp or payload length is reported as
    `ParseErrorCode.invalidIdentifier`.

    Because `X25519Identity` is non-copyable (its scalar is a zeroizing
    $(REF SecretArray, sparkles,crypto,secret)), it never travels through an
    `Expected` — that would copy it by value. Instead, on success the parsed
    identity is written into the caller-provided `out_` reference and the
    returned `ParseExpected!void` carries only the ok/error status, mirroring
    the $(REF FileKey, sparkles,age,keys) out-parameter convention used by
    $(LREF X25519Identity.unwrapStanza).

    Params:
        s = the `AGE-SECRET-KEY-1…` identity string
        out_ = on success, receives the parsed $(LREF X25519Identity)
    Returns: a successful `ParseExpected!void`, or a `ParseError`.
    */
    static ParseExpected!void parse(scope const(char)[] s, ref X25519Identity out_) nothrow @nogc
    {
        if (s.length > maxParseLen)
            return parseErr!void(ParseErrorCode.invalidIdentifier, 0);

        ubyte[bech32MaxDecodedLength(maxParseLen)] buf = void;
        const(char)[] hrp;
        auto decoded = decodeBech32(s, hrp, buf[0 .. bech32MaxDecodedLength(s.length)]);
        if (!decoded.hasValue)
            return parseErr!void(decoded.error);

        if (!equalsAsciiCI(hrp, SECRET_KEY_HRP) || decoded.value.length != KEY_BYTES)
            return parseErr!void(ParseErrorCode.invalidIdentifier, 0);

        ubyte[KEY_BYTES] scalar = decoded.value[0 .. KEY_BYTES];
        out_ = X25519Identity.fromScalar(scalar);
        return parseOk();
    }

    /**
    Renders this identity as its canonical uppercase bech32
    `AGE-SECRET-KEY-1…` string into the output range `w`.

    The bytes are bech32-encoded with the lowercase `"age-secret-key-"` hrp (the
    checksum is computed over the lowercased hrp regardless), then the whole
    string is uppercased on the way out — matching rage's
    `bech32_encode(…).to_uppercase()`. `@safe`, and `@nogc` when `w` is.
    */
    void toString(W)(ref W w) const
    {
        import sparkles.core_cli.smallbuffer : SmallBuffer;
        import std.range.primitives : put;

        // Encode lowercase into a scratch buffer, then emit it uppercased.
        SmallBuffer!(char, 128) lower;
        ubyte[KEY_BYTES] scalar = _scalar.exposeSecret()[0 .. KEY_BYTES];
        encodeBech32(SECRET_KEY_HRP, scalar[], lower);
        foreach (c; lower[])
            put(w, toUpperAscii(c));
    }

    /**
    Attempts to unwrap the file key from a single recipient `stanza` (§8).

    Reports the not-mine / malformed / success trichotomy as an
    $(REF UnwrapOutcome, sparkles,age,identity):

    $(UL
        $(LI a non-`X25519` `stanza.tag` → `null` (skip);)
        $(LI `args.length != 1`, an argument that is not the canonical base64
            encoding of a 32-byte ephemeral share, or a body that is not exactly
            32 bytes → a non-null `invalidHeader` error;)
        $(LI an all-zero `X25519(identity, epk)` shared secret (a low-order share) →
            a non-null `invalidHeader` error (the spec mandates aborting here, and
            rage classifies it as a header failure);)
        $(LI a body that opens under the derived wrap key → success: `fileKeyOut`
            is filled and a non-null OK outcome is returned;)
        $(LI a body that fails to open → `null` (the stanza is another
            recipient's, indistinguishable from not-mine).))

    Params:
        stanza     = a single recipient stanza from the header
        fileKeyOut = filled with the recovered file key on success
    */
    UnwrapOutcome unwrapStanza(in Stanza stanza, ref FileKey fileKeyOut) const
    {
        import sparkles.age.errors : DecryptErrorCode;

        if (stanza.tag != X25519_TAG)
            return unwrapSkip();

        // Exactly one argument: the base64 ephemeral share.
        if (stanza.args.length != 1)
            return unwrapFail(DecryptErrorCode.invalidHeader);

        // The argument MUST be the canonical base64 of a 32-byte value.
        ubyte[KEY_BYTES] epk = void;
        if (!decodeCanonicalKey(stanza.args[0], epk))
            return unwrapFail(DecryptErrorCode.invalidHeader);

        // The body MUST be exactly 32 bytes (wrapped 16-byte key + 16-byte tag),
        // checked before any decryption (partitioning-oracle mitigation).
        if (stanza.body_.length != WRAPPED_FILE_KEY_BYTES)
            return unwrapFail(DecryptErrorCode.invalidHeader);

        // shared secret = X25519(identity, epk); an all-zero result (a low-order
        // ephemeral share) MUST abort. rage classifies this as `InvalidHeader`
        // (testkit `x25519_low_order` / `x25519_identity`), so it surfaces as a
        // header failure rather than a non-matching key.
        ubyte[KEY_BYTES] scalar = _scalar.exposeSecret()[0 .. KEY_BYTES];
        ubyte[KEY_BYTES] shared_ = void;
        if (!x25519(scalar, epk, shared_))
            return unwrapFail(DecryptErrorCode.invalidHeader);

        const ubyte[KEY_BYTES] recipientPk = toPublic().publicKey;
        const wrapKey = x25519WrapKey(shared_, epk, recipientPk);

        // Try to open the body. A failure is non-fatal: it just means this
        // stanza was wrapped for a different recipient.
        ubyte[FileKey.length] plaintext = void;
        if (!aeadOpenZero(wrapKey, stanza.body_, plaintext[]))
            return unwrapSkip();

        // It's ours: fill the caller's file key.
        fileKeyOut.exposeSecretMut()[] = plaintext[];
        return unwrapDone();
    }

    /// The longest `AGE-SECRET-KEY-1…` string $(LREF parse) will consider.
    private enum size_t maxParseLen = bech32EncodedLength(SECRET_KEY_HRP.length, KEY_BYTES) + 8;
}

// ─────────────────────────────────────────────────────────────────────────────
// Small helpers
// ─────────────────────────────────────────────────────────────────────────────

/// ASCII uppercaser (no locale, no allocation).
private char toUpperAscii(char c) pure nothrow @nogc
    => (c >= 'a' && c <= 'z') ? cast(char)(c - 32) : c;

/// ASCII lowercaser (no locale, no allocation).
private char toLowerAscii(char c) pure nothrow @nogc
    => (c >= 'A' && c <= 'Z') ? cast(char)(c + 32) : c;

/// Case-insensitive ASCII equality of two slices.
private bool equalsAsciiCI(scope const(char)[] a, scope const(char)[] b) pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    foreach (i; 0 .. a.length)
        if (toLowerAscii(a[i]) != toLowerAscii(b[i]))
            return false;
    return true;
}

/// Base64-encodes `data` (unpadded) into a fresh GC-owned immutable `string`.
///
/// The encode runs through a fixed `@nogc` stack buffer (a 32-byte key is 43
/// characters), then the bytes are copied into a freshly allocated `char[]`
/// that nothing else aliases, so handing it back as `string` via
/// `assumeUnique` is sound.
private string base64String(scope const(ubyte)[] data)
{
    import std.exception : assumeUnique;

    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 64) enc;
    encodeBase64(data, enc);

    auto buf = new char[enc[].length];
    buf[] = enc[];
    // `buf` was just freshly allocated and nothing else aliases it (see the
    // doc comment), so reinterpreting it as `immutable` is sound — but
    // `assumeUnique`'s cast is `@system`, so wrap the hand-off in `@trusted`.
    return () @trusted { return assumeUnique(buf); }();
}

/**
Decodes `arg` as the $(B canonical) unpadded base64 of exactly a 32-byte value
into `out_`, returning `true` only if it decodes cleanly to exactly 32 bytes.

This is the D analogue of rage's `base64_arg::<_, 32, 33>`: a non-canonical
encoding (trailing non-zero bits, an over-long input, padding) or a decoded
length other than 32 fails. The 32-byte value canonically encodes to 43
characters; the strict $(REF decodeBase64, sparkles,crypto,encoding,base64)
rejects anything non-canonical.
*/
private bool decodeCanonicalKey(scope const(char)[] arg, ref ubyte[KEY_BYTES] out_)
    pure nothrow @nogc
{
    // Size the scratch buffer to the maximum the input could decode to, then
    // require the decode to yield exactly KEY_BYTES.
    ubyte[base64MaxDecodedLength(64)] buf = void;
    if (arg.length > 64)
        return false;
    auto r = decodeBase64(arg, buf[0 .. base64MaxDecodedLength(arg.length)]);
    if (!r.hasValue || r.value.length != KEY_BYTES)
        return false;
    out_[] = r.value[0 .. KEY_BYTES];
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// Conformance
// ─────────────────────────────────────────────────────────────────────────────

static assert(isRecipient!X25519Recipient && isIdentity!X25519Identity,
    "X25519Recipient/X25519Identity must satisfy the recipient/identity concepts");

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    // The published rage X25519 key pair (age/src/native/x25519.rs tests).
    private enum string TEST_SK =
        "AGE-SECRET-KEY-1GQ9778VQXMMJVE8SK7J6VT8UJ4HDQAJUVSFCWCM02D8GEWQ72PVQ2Y5J33";
    private enum string TEST_PK =
        "age1t7rxyev2z3rw82stdlrrepyc39nvn86l5078zqkf5uasdy86jp6svpy7pa";
}

/// A known `age1…` recipient round-trips through $(LREF X25519Recipient.parse)
/// and $(LREF X25519Recipient.toString) (rage's `pubkey_encoding` vector).
@("age.recipients.x25519.recipient.parseToStringRoundTrip")
@safe
unittest
{
    import std.array : appender;

    auto r = X25519Recipient.parse(TEST_PK);
    assert(r.hasValue, "TEST_PK failed to parse");

    auto w = appender!string;
    r.value.toString(w);
    assert(w[] == TEST_PK, "recipient did not round-trip to its age1… string");
}

/// A known `AGE-SECRET-KEY-1…` identity parses, round-trips through
/// $(LREF X25519Identity.toString) (uppercase), and derives the published
/// public key via $(LREF X25519Identity.toPublic) (rage's
/// `pubkey_from_secret_key` vector).
@("age.recipients.x25519.identity.parseToStringAndPublic")
@safe
unittest
{
    import std.array : appender;

    X25519Identity id;
    auto status = X25519Identity.parse(TEST_SK, id);
    assert(!status.hasError, "TEST_SK failed to parse");

    // toString re-emits the uppercase AGE-SECRET-KEY-1… form.
    auto sw = appender!string;
    id.toString(sw);
    assert(sw[] == TEST_SK, "identity did not round-trip to its uppercase string");

    // toPublic derives the published recipient.
    auto pw = appender!string;
    id.toPublic().toString(pw);
    assert(pw[] == TEST_PK, "toPublic did not match the published recipient");
}

/// $(LREF X25519Recipient.parse) accepts a lowercase secret-key string too
/// (bech32 decoding is case-insensitive): parsing `TEST_SK` lowercased yields
/// the same scalar and hence the same public key.
@("age.recipients.x25519.identity.parseLowercase")
@safe
unittest
{
    import std.array : appender;
    import std.uni : toLower;

    X25519Identity id;
    auto status = X25519Identity.parse(toLower(TEST_SK), id);
    assert(!status.hasError, "lowercase TEST_SK failed to parse");

    auto pw = appender!string;
    id.toPublic().toString(pw);
    assert(pw[] == TEST_PK);
}

/// A freshly generated identity encrypts a file key for its own public
/// recipient and recovers exactly those 16 bytes on the unwrap side
/// (rage's `wrap_and_unwrap` round-trip).
@("age.recipients.x25519.wrapUnwrapRoundTrip")
@safe
unittest
{
    auto id = X25519Identity.generate();
    auto recipient = id.toPublic();

    // A fixed file key so we can compare exact bytes.
    static immutable ubyte[16] raw = [
        7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    ];
    auto fileKey = FileKey.fromBytes(raw);

    auto wrapped = recipient.wrapFileKey(fileKey);
    assert(wrapped.hasValue, "wrapFileKey failed");
    assert(wrapped.value.stanzas.length == 1);
    assert(wrapped.value.labels.length == 0, "X25519 must declare no labels");

    const stanza = wrapped.value.stanzas[0];
    assert(stanza.tag == "X25519");
    assert(stanza.args.length == 1);
    assert(stanza.body_.length == WRAPPED_FILE_KEY_BYTES);

    // Unwrap recovers the original file key.
    FileKey recovered;
    auto outcome = id.unwrapStanza(stanza, recovered);
    assert(!outcome.isNull, "unwrapStanza returned not-mine for our own stanza");
    assert(!outcome.get.hasError, "unwrapStanza reported an error for a valid stanza");
    assert(recovered.exposeSecret() == raw[], "recovered file key mismatch");
}

/// A stanza wrapped for one recipient is $(I not mine) to an unrelated identity:
/// the AEAD open fails, which $(LREF X25519Identity.unwrapStanza) reports as a
/// `null` (skip) outcome — never an error.
@("age.recipients.x25519.unwrapStanza.notMineReturnsNull")
@safe
unittest
{
    auto alice = X25519Identity.generate();
    auto bob = X25519Identity.generate();

    static immutable ubyte[16] raw = [
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
    ];
    auto fileKey = FileKey.fromBytes(raw);

    // Wrap for Alice, then ask Bob to unwrap it.
    auto wrapped = alice.toPublic().wrapFileKey(fileKey);
    assert(wrapped.hasValue);

    FileKey discard;
    auto outcome = bob.unwrapStanza(wrapped.value.stanzas[0], discard);
    assert(outcome.isNull, "another recipient's stanza must be not-mine (null)");
}

/// A stanza whose tag is not `X25519` is skipped with a `null` outcome.
@("age.recipients.x25519.unwrapStanza.wrongTagReturnsNull")
@safe
unittest
{
    auto id = X25519Identity.generate();

    auto stanza = Stanza("scrypt", ["c2FsdA", "18"], new ubyte[WRAPPED_FILE_KEY_BYTES]);
    FileKey discard;
    assert(id.unwrapStanza(stanza, discard).isNull,
        "a non-X25519 tag must be skipped (null)");
}

/// A well-formed `X25519` stanza with a wrong-length body is rejected as
/// `invalidHeader` (a non-null error), before any decryption is attempted.
@("age.recipients.x25519.unwrapStanza.wrongBodyLengthInvalidHeader")
@safe
unittest
{
    import sparkles.age.errors : DecryptErrorCode;

    auto id = X25519Identity.generate();

    // A valid 43-char base64 ephemeral share, but a 31-byte (too short) body.
    static immutable ubyte[16] raw = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    ];
    auto recipient = id.toPublic();
    auto wrapped = recipient.wrapFileKey(FileKey.fromBytes(raw));
    assert(wrapped.hasValue);

    // Same args (canonical share), but truncate the body by one byte.
    auto good = wrapped.value.stanzas[0];
    auto bad = Stanza(good.tag, good.args, good.body_[0 .. $ - 1]);

    FileKey discard;
    auto outcome = id.unwrapStanza(bad, discard);
    assert(!outcome.isNull, "a malformed stanza must not be skipped");
    assert(outcome.get.hasError);
    assert(outcome.get.error.code == DecryptErrorCode.invalidHeader);
}

/// An `X25519` stanza with the wrong number of arguments (zero, or two) is
/// rejected as `invalidHeader`.
@("age.recipients.x25519.unwrapStanza.wrongArgCountInvalidHeader")
@safe
unittest
{
    import sparkles.age.errors : DecryptErrorCode;

    auto id = X25519Identity.generate();

    // Zero arguments.
    {
        auto stanza = Stanza("X25519", [], new ubyte[WRAPPED_FILE_KEY_BYTES]);
        FileKey discard;
        auto o = id.unwrapStanza(stanza, discard);
        assert(!o.isNull && o.get.hasError);
        assert(o.get.error.code == DecryptErrorCode.invalidHeader);
    }

    // Two arguments.
    {
        auto stanza = Stanza("X25519",
            ["O6DLx/wDIawpUC978NSPjYvrfDtJVnZApXKp4FMPHCY", "extra"],
            new ubyte[WRAPPED_FILE_KEY_BYTES]);
        FileKey discard;
        auto o = id.unwrapStanza(stanza, discard);
        assert(!o.isNull && o.get.hasError);
        assert(o.get.error.code == DecryptErrorCode.invalidHeader);
    }
}

/// A non-canonical / wrong-length base64 ephemeral share is rejected as
/// `invalidHeader`.
@("age.recipients.x25519.unwrapStanza.badShareInvalidHeader")
@safe
unittest
{
    import sparkles.age.errors : DecryptErrorCode;

    auto id = X25519Identity.generate();

    // A base64 of a 16-byte value (22 chars) — not a 32-byte share.
    {
        auto stanza = Stanza("X25519", ["AAAAAAAAAAAAAAAAAAAAAA"],
            new ubyte[WRAPPED_FILE_KEY_BYTES]);
        FileKey discard;
        auto o = id.unwrapStanza(stanza, discard);
        assert(!o.isNull && o.get.hasError);
        assert(o.get.error.code == DecryptErrorCode.invalidHeader);
    }
}

/// $(LREF X25519Recipient.parse) rejects a recipient whose hrp is not `age`
/// (here, an `AGE-SECRET-KEY-1…` string fed to the recipient parser).
@("age.recipients.x25519.recipient.parseWrongHrp")
@safe
unittest
{
    auto r = X25519Recipient.parse(TEST_SK);
    assert(!r.hasValue, "a secret-key string must not parse as a recipient");
}

/// $(LREF X25519Identity.parse) rejects an identity whose hrp is not
/// `age-secret-key-` (here, an `age1…` recipient string).
@("age.recipients.x25519.identity.parseWrongHrp")
@safe
unittest
{
    X25519Identity id;
    auto status = X25519Identity.parse(TEST_PK, id);
    assert(status.hasError, "a recipient string must not parse as an identity");
}
