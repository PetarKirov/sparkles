/**
The `Expected`-based error vocabulary for the `sparkles:age` wire format.

The age format layer never throws: every fallible operation returns an
[expected.Expected] carrying either a value or one of the three domain error
types defined here. Each error type names a machine-readable `code` plus, where
relevant, a little extra context (the scrypt work factors for
$(LREF DecryptErrorCode.excessiveWork), the byte `offset` for an
$(LREF ArmorError)), and renders a human-readable message via an
output-range `toString`.

This is a faithful port of the message wording in rage's `age/src/error.rs`
and `age/src/primitives/armor.rs` (`ArmoredReadError`); the three enums mirror
the variants that the `sparkles:age` wire-format layer can actually produce.

See `docs/specs/age/SPEC.md` §7 for the wire format these errors describe.
*/
module sparkles.age.errors;

import expected : Expected, err, ok;
import sparkles.core_cli.text.errors : NoGcHook;

@safe:

// ─────────────────────────────────────────────────────────────────────────────
// Decryption errors
// ─────────────────────────────────────────────────────────────────────────────

/// Machine-readable reason a decryption operation failed.
///
/// Ports the relevant variants of rage's `DecryptError` (`age/src/error.rs`).
enum DecryptErrorCode
{
    /// The age file's payload (or a wrapped key) failed to decrypt — a
    /// ChaCha20-Poly1305 / wrap-key authentication failure.
    decryptionFailed,
    /// The file used an excessive scrypt work factor for passphrase
    /// encryption. See $(LREF DecryptError.requiredWork) /
    /// $(LREF DecryptError.targetWork).
    excessiveWork,
    /// The age header was structurally invalid.
    invalidHeader,
    /// The MAC in the age header did not verify.
    invalidMac,
    /// None of the provided keys could unwrap the file key.
    noMatchingKeys,
    /// An unknown age format, probably from a newer version.
    unknownFormat,
    /// The STREAM payload ended before a valid final chunk was reached.
    truncatedPayload,
    /// A STREAM payload chunk failed to decrypt or violated the chunking
    /// rules (e.g. an empty non-final chunk).
    payloadError,
}

/**
A decryption failure: a $(LREF DecryptErrorCode) plus, for
$(LREF DecryptErrorCode.excessiveWork), the scrypt work factors involved.

`requiredWork` and `targetWork` are only meaningful when
`code == DecryptErrorCode.excessiveWork`; they are zero otherwise. As in rage,
the human-readable message estimates the decryption duration as
`2^(requiredWork - targetWork)` seconds.
*/
struct DecryptError
{
    /// What went wrong.
    DecryptErrorCode code;
    /// scrypt work factor the file demands (only for `excessiveWork`).
    ubyte requiredWork;
    /// scrypt work factor this device targets, ~1 second (only for
    /// `excessiveWork`).
    ubyte targetWork;

    /// Renders a human-readable message into an output range `w`.
    void toString(W)(ref W w) const
    {
        import sparkles.core_cli.text.writers : writeInteger;

        final switch (code)
        {
        case DecryptErrorCode.decryptionFailed:
            w.put("decryption failed");
            break;
        case DecryptErrorCode.excessiveWork:
            w.put("excessive work parameter for passphrase; "
                ~ "decryption would take around ");
            // 2^(required - target) seconds. Guard the shift against an
            // inverted pair (required < target) so it never goes negative.
            const exp = requiredWork > targetWork
                ? requiredWork - targetWork
                : 0;
            const ulong seconds = 1UL << exp;
            writeInteger(w, seconds);
            w.put(" seconds");
            break;
        case DecryptErrorCode.invalidHeader:
            w.put("the age header was invalid");
            break;
        case DecryptErrorCode.invalidMac:
            w.put("the header MAC was invalid");
            break;
        case DecryptErrorCode.noMatchingKeys:
            w.put("no matching keys found");
            break;
        case DecryptErrorCode.unknownFormat:
            w.put("unknown age format; "
                ~ "have you tried upgrading to the latest version?");
            break;
        case DecryptErrorCode.truncatedPayload:
            w.put("the encrypted payload was truncated");
            break;
        case DecryptErrorCode.payloadError:
            w.put("the encrypted payload was invalid");
            break;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Encryption errors
// ─────────────────────────────────────────────────────────────────────────────

/// Machine-readable reason an encryption operation failed.
///
/// Ports the relevant variants of rage's `EncryptError` (`age/src/error.rs`).
enum EncryptErrorCode
{
    /// The encryptor was given no recipients.
    missingRecipients,
    /// Recipients declared themselves mutually incompatible (label mismatch).
    incompatibleRecipients,
    /// A passphrase (scrypt) recipient was mixed with other recipient types.
    mixedRecipientAndPassphrase,
    /// Wrapping the file key for a recipient failed.
    wrapFailed,
}

/// An encryption failure: a $(LREF EncryptErrorCode).
struct EncryptError
{
    /// What went wrong.
    EncryptErrorCode code;

    /// Renders a human-readable message into an output range `w`.
    void toString(W)(ref W w) const
    {
        final switch (code)
        {
        case EncryptErrorCode.missingRecipients:
            w.put("missing recipients");
            break;
        case EncryptErrorCode.incompatibleRecipients:
            w.put("cannot encrypt to recipients with incompatible labels");
            break;
        case EncryptErrorCode.mixedRecipientAndPassphrase:
            w.put("a passphrase can't be used with other recipients");
            break;
        case EncryptErrorCode.wrapFailed:
            w.put("failed to wrap the file key for a recipient");
            break;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Armor errors
// ─────────────────────────────────────────────────────────────────────────────

/// Machine-readable reason ASCII-armor (PEM) decoding failed.
///
/// Ports rage's `ArmoredReadError` (`age/src/primitives/armor.rs`).
enum ArmorErrorCode
{
    /// A line contained a carriage return (`\r`); armor uses LF endings only.
    crlf,
    /// An invalid character was encountered (bad base64 / bad marker).
    invalidCharacter,
    /// A full base64 line was longer than the 64-column wrap, or a non-final
    /// line was short ("not wrapped at 64 characters").
    longLine,
    /// The `-----END AGE ENCRYPTED FILE-----` marker was missing.
    missingEndMarker,
    /// The base64 body was valid but non-canonical (bad padding / trailing
    /// bits).
    nonCanonical,
    /// The armor ended before the expected structure was complete.
    unexpectedEof,
    /// Non-whitespace characters appeared before BEGIN or after END.
    trailingGarbage,
}

/**
An ASCII-armor decoding failure: an $(LREF ArmorErrorCode) plus the byte
`offset` within the armored text at which the problem was detected.
*/
struct ArmorError
{
    /// What went wrong.
    ArmorErrorCode code;
    /// Byte offset within the armored text where the failure was detected.
    size_t offset;

    /// Renders a human-readable message into an output range `w`.
    void toString(W)(ref W w) const
    {
        import sparkles.core_cli.text.writers : writeInteger;

        final switch (code)
        {
        case ArmorErrorCode.crlf:
            w.put("invalid armor (line contains CR)");
            break;
        case ArmorErrorCode.invalidCharacter:
            w.put("invalid armor (invalid character)");
            break;
        case ArmorErrorCode.longLine:
            w.put("invalid armor (not wrapped at 64 characters)");
            break;
        case ArmorErrorCode.missingEndMarker:
            w.put("invalid armor (missing end marker)");
            break;
        case ArmorErrorCode.nonCanonical:
            w.put("invalid armor (non-canonical base64)");
            break;
        case ArmorErrorCode.unexpectedEof:
            w.put("invalid armor (unexpected end of input)");
            break;
        case ArmorErrorCode.trailingGarbage:
            w.put("invalid armor (non-whitespace characters after end marker)");
            break;
        }
        w.put(" at offset ");
        writeInteger(w, offset);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Expected aliases and constructor helpers
// ─────────────────────────────────────────────────────────────────────────────

/// `Expected!` specialised for $(LREF DecryptError).
alias DecryptExpected(T) = Expected!(T, DecryptError, NoGcHook);

/// `Expected!` specialised for $(LREF EncryptError).
alias EncryptExpected(T) = Expected!(T, EncryptError, NoGcHook);

/// `Expected!` specialised for $(LREF ArmorError).
alias ArmorExpected(T) = Expected!(T, ArmorError, NoGcHook);

/// Constructs a successful $(LREF DecryptExpected) carrying `value`.
DecryptExpected!T decryptOk(T)(T value)
    => ok!(DecryptError, NoGcHook)(value);

/// ditto — success with no payload (`DecryptExpected!void`).
DecryptExpected!void decryptOk() @safe pure nothrow @nogc
    => ok!(DecryptError, NoGcHook)();

/// Constructs a failed $(LREF DecryptExpected)`!T` carrying `error`.
DecryptExpected!T decryptErr(T)(DecryptError error)
    => err!(T, NoGcHook)(error);

/// ditto — the common bare-`code` form (for everything but `excessiveWork`).
DecryptExpected!T decryptErr(T)(DecryptErrorCode code)
    => err!(T, NoGcHook)(DecryptError(code));

/// Constructs a successful $(LREF EncryptExpected) carrying `value`.
EncryptExpected!T encryptOk(T)(T value)
    => ok!(EncryptError, NoGcHook)(value);

/// ditto — success with no payload (`EncryptExpected!void`).
EncryptExpected!void encryptOk() @safe pure nothrow @nogc
    => ok!(EncryptError, NoGcHook)();

/// Constructs a failed $(LREF EncryptExpected)`!T` carrying `error`.
EncryptExpected!T encryptErr(T)(EncryptError error)
    => err!(T, NoGcHook)(error);

/// ditto — the common bare-`code` form.
EncryptExpected!T encryptErr(T)(EncryptErrorCode code)
    => err!(T, NoGcHook)(EncryptError(code));

/// Constructs a successful $(LREF ArmorExpected) carrying `value`.
ArmorExpected!T armorOk(T)(T value)
    => ok!(ArmorError, NoGcHook)(value);

/// ditto — success with no payload (`ArmorExpected!void`).
ArmorExpected!void armorOk() @safe pure nothrow @nogc
    => ok!(ArmorError, NoGcHook)();

/// Constructs a failed $(LREF ArmorExpected)`!T` carrying `error`.
ArmorExpected!T armorErr(T)(ArmorError error)
    => err!(T, NoGcHook)(error);

/// ditto — the common `code` + `offset` form.
ArmorExpected!T armorErr(T)(ArmorErrorCode code, size_t offset)
    => err!(T, NoGcHook)(ArmorError(code, offset));

// ─────────────────────────────────────────────────────────────────────────────
// Unit Tests
// ─────────────────────────────────────────────────────────────────────────────

@("age.errors.DecryptError.invalidMac")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    checkToString(DecryptError(DecryptErrorCode.invalidMac),
        "the header MAC was invalid");
}

@("age.errors.DecryptError.decryptionFailed")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    checkToString(DecryptError(DecryptErrorCode.decryptionFailed),
        "decryption failed");
}

@("age.errors.DecryptError.invalidHeader")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    checkToString(DecryptError(DecryptErrorCode.invalidHeader),
        "the age header was invalid");
}

@("age.errors.DecryptError.noMatchingKeys")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    checkToString(DecryptError(DecryptErrorCode.noMatchingKeys),
        "no matching keys found");
}

@("age.errors.DecryptError.unknownFormat")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    checkToString(DecryptError(DecryptErrorCode.unknownFormat),
        "unknown age format; have you tried upgrading to the latest version?");
}

@("age.errors.DecryptError.truncatedPayload")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    checkToString(DecryptError(DecryptErrorCode.truncatedPayload),
        "the encrypted payload was truncated");
}

@("age.errors.DecryptError.payloadError")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    checkToString(DecryptError(DecryptErrorCode.payloadError),
        "the encrypted payload was invalid");
}

@("age.errors.DecryptError.excessiveWork")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    // 2^(20 - 18) == 4 seconds.
    checkToString(
        DecryptError(DecryptErrorCode.excessiveWork, requiredWork: 20, targetWork: 18),
        "excessive work parameter for passphrase; "
            ~ "decryption would take around 4 seconds");
}

@("age.errors.DecryptError.excessiveWork.invertedPair")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    // required <= target clamps the exponent to 0 -> 2^0 == 1 second.
    checkToString(
        DecryptError(DecryptErrorCode.excessiveWork, requiredWork: 5, targetWork: 18),
        "excessive work parameter for passphrase; "
            ~ "decryption would take around 1 seconds");
}

@("age.errors.EncryptError.missingRecipients")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    checkToString(EncryptError(EncryptErrorCode.missingRecipients),
        "missing recipients");
}

@("age.errors.EncryptError.incompatibleRecipients")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    checkToString(EncryptError(EncryptErrorCode.incompatibleRecipients),
        "cannot encrypt to recipients with incompatible labels");
}

@("age.errors.EncryptError.mixedRecipientAndPassphrase")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    checkToString(EncryptError(EncryptErrorCode.mixedRecipientAndPassphrase),
        "a passphrase can't be used with other recipients");
}

@("age.errors.EncryptError.wrapFailed")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    checkToString(EncryptError(EncryptErrorCode.wrapFailed),
        "failed to wrap the file key for a recipient");
}

@("age.errors.ArmorError.crlf")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    checkToString(ArmorError(ArmorErrorCode.crlf, 3),
        "invalid armor (line contains CR) at offset 3");
}

@("age.errors.ArmorError.longLine")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    checkToString(ArmorError(ArmorErrorCode.longLine, 128),
        "invalid armor (not wrapped at 64 characters) at offset 128");
}

@("age.errors.ArmorError.nonCanonical")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    checkToString(ArmorError(ArmorErrorCode.nonCanonical, 0),
        "invalid armor (non-canonical base64) at offset 0");
}

@("age.errors.ArmorError.missingEndMarker")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    checkToString(ArmorError(ArmorErrorCode.missingEndMarker, 42),
        "invalid armor (missing end marker) at offset 42");
}

@("age.errors.ArmorError.trailingGarbage")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    checkToString(ArmorError(ArmorErrorCode.trailingGarbage, 200),
        "invalid armor (non-whitespace characters after end marker) at offset 200");
}

@("age.errors.ArmorError.invalidCharacter")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    checkToString(ArmorError(ArmorErrorCode.invalidCharacter, 7),
        "invalid armor (invalid character) at offset 7");
}

@("age.errors.ArmorError.unexpectedEof")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    checkToString(ArmorError(ArmorErrorCode.unexpectedEof, 64),
        "invalid armor (unexpected end of input) at offset 64");
}

@("age.errors.DecryptExpected.ok")
@safe pure nothrow @nogc
unittest
{
    auto good = decryptOk(7);
    assert(good.hasValue);
    assert(good.value == 7);

    auto voidGood = decryptOk();
    assert(!voidGood.hasError);   // `Expected!void` exposes `hasError`, not `hasValue`
}

@("age.errors.DecryptExpected.err")
@safe pure nothrow @nogc
unittest
{
    auto bad = decryptErr!int(DecryptErrorCode.invalidMac);
    assert(!bad.hasValue);
    assert(bad.error.code == DecryptErrorCode.invalidMac);

    auto bad2 = decryptErr!int(
        DecryptError(DecryptErrorCode.excessiveWork, requiredWork: 22, targetWork: 18));
    assert(!bad2.hasValue);
    assert(bad2.error.code == DecryptErrorCode.excessiveWork);
    assert(bad2.error.requiredWork == 22);
    assert(bad2.error.targetWork == 18);
}

@("age.errors.EncryptExpected.okErr")
@safe pure nothrow @nogc
unittest
{
    auto good = encryptOk("ciphertext");
    assert(good.hasValue);
    assert(good.value == "ciphertext");

    auto voidGood = encryptOk();
    assert(!voidGood.hasError);   // `Expected!void` exposes `hasError`, not `hasValue`

    auto bad = encryptErr!int(EncryptErrorCode.missingRecipients);
    assert(!bad.hasValue);
    assert(bad.error.code == EncryptErrorCode.missingRecipients);
}

@("age.errors.ArmorExpected.okErr")
@safe pure nothrow @nogc
unittest
{
    auto good = armorOk(123);
    assert(good.hasValue);
    assert(good.value == 123);

    auto voidGood = armorOk();
    assert(!voidGood.hasError);   // `Expected!void` exposes `hasError`, not `hasValue`

    auto bad = armorErr!int(ArmorErrorCode.longLine, 96);
    assert(!bad.hasValue);
    assert(bad.error.code == ArmorErrorCode.longLine);
    assert(bad.error.offset == 96);
}
