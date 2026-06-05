/**
The native age $(B scrypt) (passphrase) recipient and identity (§9.2).

This is the passphrase-based recipient type: anyone holding the passphrase can
decrypt the file. A faithful port of rage's `age/src/native/scrypt.rs` and the
C2SP spec's "scrypt recipient type" (`https://c2sp.org/age`).

The wrap derives a one-shot key from the passphrase with scrypt
(`r = 8`, `p = 1`, `N = 2^logN`) over a fresh 16-byte salt, then seals the file
key under it with the zero-nonce AEAD:

```
inner   = "age-encryption.org/v1/scrypt" ‖ salt16
wrapKey = scrypt(passphrase, inner, logN)        // 32 bytes
body    = ChaCha20-Poly1305(wrapKey, file key)   // 12-zero nonce, 32 bytes
stanza  = -> scrypt <base64(salt16)> <logN>
          <base64(body)>
```

# Sole-recipient constraint

An scrypt stanza, if present, MUST be the **only** stanza in the header (spec
§9.2): it can neither be mixed with stanzas of other types nor repeated. The
recipient enforces this on the encrypt side by returning a single $(I random)
label — `Encryptor` requires every recipient's label set to be identical, and no
other recipient produces this random label, so an scrypt recipient can only ever
be combined with itself, which the identical-set rule then forbids in turn
(every random label differs). The identity enforces it on the decrypt side via
the whole-header $(REF hasUnwrapStanzas, sparkles,age,identity) capability:
$(LREF ScryptIdentity.unwrapStanzas) rejects a header that mixes an scrypt
stanza with any other stanza.

This layer MAY use the GC: the owned $(REF Stanza, sparkles,age,format,stanza)
arrays, the base64 salt/decimal-`logN` argument strings, and the random label
are GC-allocated.

See `docs/specs/age/SPEC.md` §9.2 and `https://c2sp.org/age`.

Copyright: © 2026, Petar Kirov
License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
Authors: Petar Kirov
*/
module sparkles.age.recipients.scrypt;

import sparkles.crypto.aead : aeadOpenZero, aeadSealZero;
import sparkles.crypto.encoding.base64 :
    base64MaxDecodedLength, decodeBase64, encodeBase64;
import sparkles.crypto.random : randomArray;
import sparkles.crypto.scrypt : scrypt;
import sparkles.crypto.secret : SecretString, fromString;

import sparkles.age.errors :
    DecryptError, DecryptErrorCode, EncryptExpected, encryptOk;
import sparkles.age.format.stanza : Stanza;
import sparkles.age.identity : UnwrapOutcome, unwrapDone, unwrapFail, unwrapSkip;
import sparkles.age.keys : FileKey;
import sparkles.age.recipient : WrapResult;

@safe:

// ─────────────────────────────────────────────────────────────────────────────
// Shared constants
// ─────────────────────────────────────────────────────────────────────────────

/// The stanza tag for the scrypt recipient type.
private enum string scryptTag = "scrypt";

/// The fixed scrypt salt prefix: the derived salt is this label ‖ the random
/// 16-byte salt (§9.2).
private enum string scryptSaltLabel = "age-encryption.org/v1/scrypt";

/// Length of the random per-stanza salt, in bytes (§9.2).
private enum size_t saltLen = 16;

/// Length of the AEAD-wrapped file key body: 16 file-key bytes + 16-byte tag.
private enum size_t wrappedFileKeyLen = FileKey.length + 16;

/// Length of the random label that forces scrypt to be the sole recipient.
private enum size_t labelLen = 32;

/**
The default scrypt work factor (`logN`) used when constructing a
$(LREF ScryptRecipient) without an explicit factor.

rage picks this by timing the device to target ~1 second; we use a fixed `18`
(rage's own fallback when timing is unavailable), the conventional age default.
*/
enum ubyte defaultWorkFactor = 18;

/**
The default maximum scrypt work factor a $(LREF ScryptIdentity) will accept.

A malicious header could request an arbitrarily large `logN`, forcing the
decryptor into a multi-second / multi-gigabyte scrypt computation. The identity
caps the accepted factor at this value (rage targets ~16 seconds, i.e. a few
factors above its ~1-second target); a header demanding more fails with
$(REF DecryptErrorCode.excessiveWork, sparkles,age,errors).
*/
enum ubyte defaultMaxWorkFactor = 22;

// ─────────────────────────────────────────────────────────────────────────────
// ScryptRecipient
// ─────────────────────────────────────────────────────────────────────────────

/**
A passphrase-based recipient (§9.2): anyone with the passphrase can decrypt the
file.

Holds the passphrase as a zeroizing $(REF SecretString, sparkles,crypto,secret)
(so the struct is non-copyable) plus the scrypt work factor `logN`. Use it only
with a passphrase supplied by, or generated for, a human; for programmatic use
cases prefer an X25519 identity.

$(LREF wrapFileKey) emits exactly one `scrypt` stanza and a single random label
that constrains this recipient to be the file's $(I sole) recipient (see the
module summary). Satisfies $(REF isRecipient, sparkles,age,recipient).
*/
struct ScryptRecipient
{
    private SecretString _passphrase;
    private ubyte _logN = defaultWorkFactor;

    @disable this(this);

    /**
    Constructs a recipient for `passphrase` with the given work factor.

    Params:
        passphrase = the passphrase characters (copied into a zeroizing
            `SecretString`; the caller wipes any temporary holding them)
        logN       = base-2 log of the scrypt cost `N = 2^logN`; must be in
            `1 … 63` (the scrypt primitive rejects `logN >= 64`)
    */
    this(scope const(char)[] passphrase, ubyte logN = defaultWorkFactor)
    in (0 < logN && logN < 64, "scrypt logN must be in 1 … 63")
    {
        _passphrase = fromString(passphrase);
        _logN = logN;
    }

    /**
    Wraps `fileKey` into a single `scrypt` stanza (§9.2).

    Generates a fresh 16-byte salt, derives the wrapping key with scrypt over
    `"age-encryption.org/v1/scrypt" ‖ salt` at this recipient's `logN`, seals the
    file key under it with the zero-nonce AEAD, and returns the stanza plus a
    single random 32-character alphanumeric label (the sole-recipient marker).

    Returns: a $(REF WrapResult, sparkles,age,recipient) with one stanza and one
    label. Never fails for a valid `logN` (the scrypt primitive only fails for
    `logN >= 64`, excluded by the constructor contract); the `Expected` shape is
    required by $(REF isRecipient, sparkles,age,recipient).
    */
    EncryptExpected!WrapResult wrapFileKey(in FileKey fileKey) const
    {
        // Fresh per-stanza salt and the derived inner salt = label ‖ salt.
        ubyte[saltLen] salt = randomArray!saltLen();

        ubyte[scryptSaltLabel.length + saltLen] inner = void;
        inner[0 .. scryptSaltLabel.length] = cast(const(ubyte)[]) scryptSaltLabel;
        inner[scryptSaltLabel.length .. $] = salt[];

        ubyte[32] wrapKey = void;
        // logN < 64 is guaranteed by the constructor contract, so scrypt
        // succeeds; the boolean is asserted rather than surfaced.
        const ok = scrypt(_passphrase.exposeSecret().byteView, inner[], _logN, wrapKey);
        assert(ok, "scrypt failed for a valid logN");

        ubyte[wrappedFileKeyLen] body_ = void;
        aeadSealZero(wrapKey, fileKey.exposeSecret(), body_[]);

        auto stanza = Stanza(scryptTag, [encodeSalt(salt), decimalString(_logN)], body_.dup);
        return encryptOk(WrapResult([stanza], [randomLabel()]));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// ScryptIdentity
// ─────────────────────────────────────────────────────────────────────────────

/**
A passphrase-based identity (§9.2): anyone with the passphrase can decrypt the
file.

Holds the passphrase as a zeroizing $(REF SecretString, sparkles,crypto,secret)
(so the struct is non-copyable) plus `maxWorkFactor`, the largest scrypt `logN`
it will attempt — a malicious header demanding more is rejected with
$(REF DecryptErrorCode.excessiveWork, sparkles,age,errors) before any expensive
computation runs.

Because an scrypt stanza must be a file's sole stanza, this identity provides
the whole-header $(REF hasUnwrapStanzas, sparkles,age,identity) capability: it
sees every stanza so it can verify it is alone. $(LREF unwrapStanza) simply
forwards a single stanza to $(LREF unwrapStanzas). Satisfies
$(REF isIdentity, sparkles,age,identity).
*/
struct ScryptIdentity
{
    private SecretString _passphrase;
    private ubyte _maxWorkFactor = defaultMaxWorkFactor;
    private ubyte _targetWorkFactor = defaultWorkFactor;

    @disable this(this);

    /**
    Constructs an identity for `passphrase`, accepting work factors up to
    `maxWorkFactor`.

    Params:
        passphrase    = the passphrase characters (copied into a zeroizing
            `SecretString`; the caller wipes any temporary)
        maxWorkFactor = the largest scrypt `logN` this identity will attempt; a
            header demanding more fails with
            $(REF DecryptErrorCode.excessiveWork, sparkles,age,errors)
    */
    this(scope const(char)[] passphrase, ubyte maxWorkFactor = defaultMaxWorkFactor)
    {
        _passphrase = fromString(passphrase);
        _maxWorkFactor = maxWorkFactor;
    }

    /**
    Whole-header unwrap (§9.2) — the $(REF hasUnwrapStanzas, sparkles,age,identity)
    capability.

    Reports an $(REF UnwrapOutcome, sparkles,age,identity):

    $(UL
    $(LI `null` (skip) — no `scrypt` stanza is present, so this identity does
        not apply;)
    $(LI non-null error — a malformed header (an scrypt stanza mixed with any
        other stanza, or a structurally invalid scrypt stanza), an excessive
        work factor, or a passphrase that does not unwrap the file key;)
    $(LI non-null success — the file key was recovered into `fileKeyOut`.))

    The sole-recipient rule (spec §9.2) is checked first: if an scrypt stanza
    appears alongside any other stanza the header is rejected with
    $(REF DecryptErrorCode.invalidHeader, sparkles,age,errors).
    */
    UnwrapOutcome unwrapStanzas(in Stanza[] stanzas, ref FileKey fileKeyOut) const
    {
        // Is an scrypt stanza present at all? If not, this identity doesn't apply.
        bool sawScrypt = false;
        foreach (ref s; stanzas)
            if (s.tag == scryptTag)
            {
                sawScrypt = true;
                break;
            }

        if (!sawScrypt)
            return unwrapSkip();

        // An scrypt stanza, if present, MUST be the sole stanza in the header.
        // Anything else (a second scrypt stanza, or any other-typed stanza)
        // makes the header malformed.
        if (stanzas.length != 1)
            return unwrapFail(DecryptErrorCode.invalidHeader);

        return unwrapOne(stanzas[0], fileKeyOut);
    }

    /**
    Per-stanza unwrap — delegates to $(LREF unwrapStanzas) over a single-element
    header, so the sole-recipient invariant is upheld even when called with one
    stanza at a time. Satisfies $(REF isIdentity, sparkles,age,identity).
    */
    UnwrapOutcome unwrapStanza(in Stanza stanza, ref FileKey fileKeyOut) const
    {
        // A header consisting of exactly this one stanza trivially satisfies the
        // sole-recipient invariant `unwrapStanzas` enforces, so we apply the same
        // per-stanza logic directly rather than slicing a local static array
        // (which `@safe` + dip1000 rejects as an escaping stack reference).
        if (stanza.tag != scryptTag)
            return unwrapSkip();
        return unwrapOne(stanza, fileKeyOut);
    }

    /// Unwraps a confirmed-sole `scrypt` stanza, parsing and validating its
    /// arguments per spec §9.2 before doing any scrypt work.
    private UnwrapOutcome unwrapOne(in Stanza stanza, ref FileKey fileKeyOut) const
    {
        // Exactly two arguments: the base64 salt and the decimal logN. (The
        // spec counts the `scrypt` tag as the first of "three arguments"; in our
        // Stanza model the tag is separate, so args.length must be 2.)
        if (stanza.args.length != 2)
            return unwrapFail(DecryptErrorCode.invalidHeader);

        // Argument 1: a canonical base64 encoding of exactly 16 salt bytes.
        ubyte[saltLen] salt = void;
        if (!decodeSalt(stanza.args[0], salt))
            return unwrapFail(DecryptErrorCode.invalidHeader);

        // Argument 2: a decimal logN with no leading zero, in 1 … 63.
        ubyte logN;
        if (!parseLogN(stanza.args[1], logN))
            return unwrapFail(DecryptErrorCode.invalidHeader);

        // Cap the work factor before touching scrypt.
        if (logN > _maxWorkFactor)
            return unwrapFail(DecryptError(
                DecryptErrorCode.excessiveWork,
                requiredWork: logN,
                targetWork: _targetWorkFactor));

        // The body MUST be exactly the wrapped file-key length (16 + 16 tag)
        // before we attempt to decrypt it (mitigates partitioning oracles).
        if (stanza.body_.length != wrappedFileKeyLen)
            return unwrapFail(DecryptErrorCode.invalidHeader);

        // Derive the wrapping key and open the body.
        ubyte[scryptSaltLabel.length + saltLen] inner = void;
        inner[0 .. scryptSaltLabel.length] = cast(const(ubyte)[]) scryptSaltLabel;
        inner[scryptSaltLabel.length .. $] = salt[];

        ubyte[32] wrapKey = void;
        if (!scrypt(_passphrase.exposeSecret().byteView, inner[], logN, wrapKey))
            // logN <= maxWorkFactor (< 64 in practice) above, so a scrypt failure
            // here means the work factor exceeded available memory.
            return unwrapFail(DecryptError(
                DecryptErrorCode.excessiveWork,
                requiredWork: logN,
                targetWork: _targetWorkFactor));

        // Open the AEAD straight into the file key's inline storage. A failure
        // means the passphrase was wrong: the stanza was addressed to a scrypt
        // recipient, so this is a hard decryption failure, not a "not mine".
        bool opened = false;
        fileKeyOut = FileKey.initWithMut((ref ubyte[FileKey.length] dst) {
            opened = aeadOpenZero(wrapKey, stanza.body_, dst[]);
        });
        if (!opened)
            return unwrapFail(DecryptErrorCode.decryptionFailed);

        return unwrapDone();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Argument helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Reinterprets a `char[]` passphrase slice as the `ubyte[]` scrypt wants.
private const(ubyte)[] byteView(return scope const(char)[] s) @trusted nothrow @nogc
    => cast(const(ubyte)[]) s;

/// Encodes the 16-byte salt as unpadded standard base64 (the stanza argument).
private string encodeSalt(in ubyte[saltLen] salt)
{
    import std.array : appender;

    auto w = appender!string;
    encodeBase64(salt[], w);
    return w[];
}

/// Renders a `ubyte` as its plain decimal string (the `logN` stanza argument).
private string decimalString(ubyte value)
{
    import std.conv : to;

    return to!string(value);
}

/// Decodes the salt argument, returning `true` iff `arg` is a canonical base64
/// encoding of exactly $(LREF saltLen) (16) bytes, filling `out_`.
private bool decodeSalt(scope const(char)[] arg, ref ubyte[saltLen] out_) @safe nothrow @nogc
{
    // A 16-byte unpadded base64 encoding is exactly 22 characters; reject any
    // longer input outright so the fixed decode buffer always suffices.
    enum size_t maxChars = (saltLen * 8 + 5) / 6 + 4; // 22 + slack
    if (arg.length > maxChars)
        return false;

    ubyte[base64MaxDecodedLength(maxChars)] buf = void;
    auto decoded = decodeBase64(arg, buf[]);
    if (!decoded.hasValue || decoded.value.length != saltLen)
        return false;
    out_[] = decoded.value[];
    return true;
}

/// Parses the `logN` argument: a decimal integer with no leading zero, in the
/// range `1 … 63`. Returns `true` and fills `out_` on success.
private bool parseLogN(scope const(char)[] arg, out ubyte out_) @safe nothrow @nogc
{
    // `%x31-39 *DIGIT`: non-empty, first digit 1-9, the rest 0-9.
    if (arg.length == 0 || arg[0] < '1' || arg[0] > '9')
        return false;

    uint value = 0;
    foreach (c; arg)
    {
        if (c < '0' || c > '9')
            return false;
        value = value * 10 + (c - '0');
        if (value > 63)        // any valid scrypt logN is < 64
            return false;
    }

    out_ = cast(ubyte) value;
    return value >= 1;
}

/// A fresh random 32-character alphanumeric label (the scrypt sole-recipient
/// marker). Drawn rejection-free from a 62-symbol alphabet using a per-character
/// CSPRNG byte reduced modulo 62 — the slight modulo bias is irrelevant for a
/// label whose only requirement is uniqueness.
private string randomLabel()
{
    static immutable char[62] alphabet =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

    ubyte[labelLen] bytes = randomArray!labelLen();
    char[labelLen] label = void;
    foreach (i, b; bytes)
        label[i] = alphabet[b % alphabet.length];
    return label.idup;
}

// ─────────────────────────────────────────────────────────────────────────────
// Conformance
// ─────────────────────────────────────────────────────────────────────────────

import sparkles.age.recipient : isRecipient;
import sparkles.age.identity : isIdentity, hasUnwrapStanzas;

static assert(isRecipient!ScryptRecipient && isIdentity!ScryptIdentity
    && hasUnwrapStanzas!ScryptIdentity,
    "ScryptRecipient/ScryptIdentity must satisfy the recipient/identity surface");

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    // A small, fast work factor for round-trip tests (scrypt at logN=18 would
    // dominate the suite). N = 2^10 derives in well under a millisecond.
    private enum ubyte fastWorkFactor = 10;

    // A fixed file key (bytes 0 … 15) so round-trips can assert byte-for-byte
    // recovery without depending on the CSPRNG.
    private FileKey fixedFileKey() @safe
    {
        ubyte[FileKey.length] raw = void;
        foreach (i; 0 .. FileKey.length)
            raw[i] = cast(ubyte) i;
        return FileKey.fromBytes(raw);
    }
}

/// A wrap then whole-header unwrap round-trips the file key, and the stanza
/// carries the documented shape: tag `scrypt`, two arguments (base64 salt and
/// decimal `logN`), and a 32-byte body.
@("age.recipients.scrypt.roundTrip.recoversFileKey")
@safe
unittest
{
    auto fk = fixedFileKey();
    auto recipient = ScryptRecipient("correct horse battery staple", fastWorkFactor);

    auto wrapped = recipient.wrapFileKey(fk);
    assert(wrapped.hasValue);
    assert(wrapped.value.stanzas.length == 1);

    const stanza = wrapped.value.stanzas[0];
    assert(stanza.tag == "scrypt");
    assert(stanza.args.length == 2);
    assert(stanza.args[1] == "10");                 // decimal logN
    assert(stanza.body_.length == wrappedFileKeyLen); // 16 + 16 tag

    auto identity = ScryptIdentity("correct horse battery staple");
    FileKey recovered;
    auto outcome = identity.unwrapStanzas(wrapped.value.stanzas, recovered);

    assert(!outcome.isNull, "scrypt stanza must be recognised");
    assert(!outcome.get.hasError, "round-trip unwrap must succeed");
    assert(recovered == fk, "recovered file key must equal the original");
}

/// `unwrapStanza` (the single-stanza entry point) delegates to the whole-header
/// path and recovers the file key for a lone scrypt stanza.
@("age.recipients.scrypt.unwrapStanza.delegatesToWholeHeader")
@safe
unittest
{
    auto fk = fixedFileKey();
    auto recipient = ScryptRecipient("hunter2", fastWorkFactor);
    auto wrapped = recipient.wrapFileKey(fk);
    assert(wrapped.hasValue);

    auto identity = ScryptIdentity("hunter2");
    FileKey recovered;
    auto outcome = identity.unwrapStanza(wrapped.value.stanzas[0], recovered);

    assert(!outcome.isNull && !outcome.get.hasError);
    assert(recovered == fk);
}

/// A wrong passphrase yields a non-null error outcome with
/// `DecryptErrorCode.decryptionFailed` (the AEAD open fails).
@("age.recipients.scrypt.unwrap.wrongPassphraseFails")
@safe
unittest
{
    auto fk = fixedFileKey();
    auto recipient = ScryptRecipient("the right passphrase", fastWorkFactor);
    auto wrapped = recipient.wrapFileKey(fk);
    assert(wrapped.hasValue);

    auto identity = ScryptIdentity("the WRONG passphrase");
    FileKey recovered;
    auto outcome = identity.unwrapStanzas(wrapped.value.stanzas, recovered);

    assert(!outcome.isNull, "the stanza is addressed to scrypt, so not skipped");
    assert(outcome.get.hasError);
    assert(outcome.get.error.code == DecryptErrorCode.decryptionFailed);
}

/// A header whose scrypt stanza demands a work factor above the identity's
/// `maxWorkFactor` is rejected with `excessiveWork` before any scrypt runs, and
/// the error carries the required / target factors.
@("age.recipients.scrypt.unwrap.excessiveWork")
@safe
unittest
{
    auto fk = fixedFileKey();
    // The recipient wraps at logN=12, but the identity caps acceptance at 10.
    auto recipient = ScryptRecipient("pass", 12);
    auto wrapped = recipient.wrapFileKey(fk);
    assert(wrapped.hasValue);
    assert(wrapped.value.stanzas[0].args[1] == "12");

    auto identity = ScryptIdentity("pass", /* maxWorkFactor */ 10);
    FileKey recovered;
    auto outcome = identity.unwrapStanzas(wrapped.value.stanzas, recovered);

    assert(!outcome.isNull);
    assert(outcome.get.hasError);
    assert(outcome.get.error.code == DecryptErrorCode.excessiveWork);
    assert(outcome.get.error.requiredWork == 12);
    assert(outcome.get.error.targetWork == defaultWorkFactor);
}

/// The wrap labels are a single, non-empty, 32-character alphanumeric string,
/// and two wraps draw distinct labels (the sole-recipient marker is random).
@("age.recipients.scrypt.wrap.singleRandomLabel")
@safe
unittest
{
    import std.ascii : isAlphaNum;

    auto fk = fixedFileKey();
    auto recipient = ScryptRecipient("p", fastWorkFactor);

    auto a = recipient.wrapFileKey(fk);
    auto b = recipient.wrapFileKey(fk);
    assert(a.hasValue && b.hasValue);

    assert(a.value.labels.length == 1, "scrypt must return exactly one label");
    const label = a.value.labels[0];
    assert(label.length == labelLen);
    foreach (c; label)
        assert(isAlphaNum(c), "label must be alphanumeric");

    // Two wraps draw independent labels (and independent salts), so collide
    // only with negligible probability.
    assert(a.value.labels[0] != b.value.labels[0],
        "two scrypt labels collided (CSPRNG failure?)");
}

/// An scrypt stanza mixed with any other stanza violates the sole-recipient
/// rule and is rejected with `invalidHeader` — the whole-header capability
/// must catch this, not the per-stanza loop.
@("age.recipients.scrypt.unwrap.mixedStanzaRejected")
@safe
unittest
{
    auto fk = fixedFileKey();
    auto recipient = ScryptRecipient("pw", fastWorkFactor);
    auto wrapped = recipient.wrapFileKey(fk);
    assert(wrapped.hasValue);

    // Append a foreign stanza (e.g. an X25519 one) to the scrypt stanza.
    auto mixed = wrapped.value.stanzas ~ Stanza("X25519", ["abc"], new ubyte[32]);

    auto identity = ScryptIdentity("pw");
    FileKey recovered;
    auto outcome = identity.unwrapStanzas(mixed, recovered);

    assert(!outcome.isNull, "a present scrypt stanza is recognised");
    assert(outcome.get.hasError);
    assert(outcome.get.error.code == DecryptErrorCode.invalidHeader);
}

/// A header with no scrypt stanza is skipped (`null`): this identity does not
/// apply, leaving other identities to try.
@("age.recipients.scrypt.unwrap.noScryptStanzaSkips")
@safe
unittest
{
    auto identity = ScryptIdentity("whatever", fastWorkFactor);
    FileKey recovered;

    auto stanzas = [Stanza("X25519", ["abc"], new ubyte[32])];
    assert(identity.unwrapStanzas(stanzas, recovered).isNull);

    // An empty header is likewise not addressed to scrypt.
    assert(identity.unwrapStanzas([], recovered).isNull);
}

/// A structurally invalid scrypt stanza (wrong argument count, non-canonical /
/// wrong-length salt, malformed `logN`, or wrong body length) is reported as
/// `invalidHeader` — and never as a "not mine" skip, since the tag is scrypt.
@("age.recipients.scrypt.unwrap.malformedStanzaInvalidHeader")
@safe
unittest
{
    auto identity = ScryptIdentity("pw");
    FileKey recovered;

    void expectInvalid(Stanza s)
    {
        auto o = identity.unwrapStanzas([s], recovered);
        assert(!o.isNull, "a scrypt-tagged stanza is never skipped");
        assert(o.get.hasError);
        assert(o.get.error.code == DecryptErrorCode.invalidHeader);
    }

    // Wrong argument count (one arg, or three).
    expectInvalid(Stanza("scrypt", ["c2FsdHNhbHRzYWx0c2FsdA"], new ubyte[32]));
    expectInvalid(Stanza("scrypt", ["c2FsdHNhbHRzYWx0c2FsdA", "10", "extra"], new ubyte[32]));

    // Salt that is valid base64 but not 16 bytes ("Zm9v" → 3 bytes).
    expectInvalid(Stanza("scrypt", ["Zm9v", "10"], new ubyte[32]));

    // logN with a leading zero is non-canonical.
    expectInvalid(Stanza("scrypt", ["c2FsdHNhbHRzYWx0c2FsdA", "010"], new ubyte[32]));

    // logN that is not all digits.
    expectInvalid(Stanza("scrypt", ["c2FsdHNhbHRzYWx0c2FsdA", "1x"], new ubyte[32]));

    // Body length other than 32 bytes (here 16) — checked before any scrypt.
    expectInvalid(Stanza("scrypt", ["c2FsdHNhbHRzYWx0c2FsdA", "10"], new ubyte[16]));
}
