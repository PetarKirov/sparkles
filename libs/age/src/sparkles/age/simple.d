/**
The one-shot, single-recipient/single-identity convenience API (§7) — the
smallest surface a caller needs to encrypt or decrypt an in-memory age file.

This is a faithful port of rage's `age/src/simple.rs` (`encrypt`,
`encrypt_and_armor`, `decrypt`). Each helper is a thin wrapper over the full
protocol layer ($(REF Encryptor, sparkles,age,protocol) /
$(REF Decryptor, sparkles,age,protocol)) specialised to exactly one recipient
(encrypt) or one identity (decrypt):

$(UL
    $(LI $(LREF encrypt) — encrypts `plaintext` to a single recipient, returning
        the binary age file. Equivalent to
        `Encryptor.withRecipients([AnyRecipient(recipient)]).encryptToBytes(...)`.)
    $(LI $(LREF encryptAndArmor) — the same, but ASCII-armored (§7.6): the binary
        output of $(LREF encrypt) wrapped in a PEM
        `-----BEGIN AGE ENCRYPTED FILE-----` block via
        [armor.armorEncode], returned as a `string`.)
    $(LI $(LREF decrypt) — decrypts `ciphertext` (binary $(I or) armored —
        detected transparently via [armor.looksArmored]) with a single identity,
        returning the recovered plaintext.)
)

To encrypt to more than one recipient, or attempt decryption with more than one
identity, drop down to $(REF Encryptor.withRecipients, sparkles,age,protocol) /
$(REF Decryptor, sparkles,age,protocol) directly.

The recipient/identity arguments are accepted by their concrete type (any type
satisfying $(REF isRecipient, sparkles,age,recipient) /
$(REF isIdentity, sparkles,age,identity)) and erased into an
$(REF AnyRecipient, sparkles,age,recipient) /
$(REF AnyIdentity, sparkles,age,identity) for the protocol layer. They are taken
by `in` (`scope const ref`) so a non-copyable recipient/identity (e.g. the
secret-holding $(REF ScryptRecipient, sparkles,age,recipients,scrypt) /
$(REF X25519Identity, sparkles,age,recipients,x25519)) is never copied.

Conventions: `@safe` throughout; this layer MAY use the GC (the returned
`ubyte[]` / `string`, the decoded armor). Errors are reported via
$(REF EncryptExpected, sparkles,age,errors) /
$(REF DecryptExpected, sparkles,age,errors); nothing here throws.

See `docs/specs/age/SPEC.md` §7 and `https://c2sp.org/age`.

Copyright: © 2026, Petar Kirov
License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
Authors: Petar Kirov
*/
module sparkles.age.simple;

import sparkles.age.armor : armorDecode, armorEncode, looksArmored;
import sparkles.age.errors :
    DecryptErrorCode, DecryptExpected, decryptErr,
    EncryptExpected, encryptErr, encryptOk;
import sparkles.age.identity : AnyIdentity, isIdentity;
import sparkles.age.protocol : Decryptor, Encryptor;
import sparkles.age.recipient : AnyRecipient, isRecipient;

@safe:

// ─────────────────────────────────────────────────────────────────────────────
// Encryption
// ─────────────────────────────────────────────────────────────────────────────

/**
Encrypts `plaintext` to a single `recipient`, returning the binary age file.

Equivalent to
`Encryptor.withRecipients([AnyRecipient(recipient)]).encryptToBytes(plaintext)`:
it erases `recipient` into an $(REF AnyRecipient, sparkles,age,recipient),
constructs a single-recipient $(REF Encryptor, sparkles,age,protocol) (generating
the file key, wrapping it, building the MAC'd header, and deriving the payload
key), and one-shots `plaintext` into a complete age file
(`header ‖ nonce ‖ STREAM ciphertext`).

This returns $(B binary) ciphertext; for an ASCII-armored text string use
$(LREF encryptAndArmor). To encrypt to more than one recipient, use
$(REF Encryptor.withRecipients, sparkles,age,protocol) directly.

Faithful port of rage's `age::encrypt`.

Params:
    recipient = the recipient to encrypt to (any $(REF isRecipient,
        sparkles,age,recipient) type; taken $(B by value) and `move`d into
        the encryptor — pass an rvalue or `std.algorithm.mutation.move`,
        since a passphrase recipient holds a non-copyable secret)
    plaintext = the payload to encrypt (may be empty)
Returns: the complete binary age file, or the
    $(REF EncryptError, sparkles,age,errors) from constructing the encryptor (in
    practice a single valid recipient never fails the label-compatibility check,
    but a recipient's own `wrapFileKey` may still fail).
*/
EncryptExpected!(ubyte[]) encrypt(R)(R recipient, scope const(ubyte)[] plaintext)
if (isRecipient!R)
{
    import std.algorithm.mutation : move;

    // Erase to AnyRecipient for the protocol layer. A single recipient can
    // never trip the label-compatibility check, so any error here is a genuine
    // wrap failure surfaced from `withRecipients` (rage's `.expect(...)`
    // covers only the "we provided a recipient" non-emptiness, not wrapping).
    //
    // `recipient` is taken by value (the caller passes an rvalue or `move`s in)
    // and `move`d into the sum type: `ScryptRecipient` holds a non-copyable
    // secret, so it can never be copied through an `in`/`const` parameter.
    AnyRecipient[1] recipients = [AnyRecipient(move(recipient))];
    auto enc = Encryptor.withRecipients(recipients[]);
    if (!enc.hasValue)
        return encryptErr!(ubyte[])(enc.error);

    return encryptOk(enc.value.encryptToBytes(plaintext));
}

/**
Encrypts `plaintext` to a single `recipient` and ASCII-armors the result (§7.6).

Equivalent to $(LREF encrypt) followed by [armor.armorEncode]: the binary age
file is wrapped in a strict PEM `-----BEGIN AGE ENCRYPTED FILE-----` block
(`=`-padded standard base64 wrapped at 64 columns, LF line endings) and returned
as a `string`. The result always begins with `ARMOR_BEGIN` and round-trips back
through $(LREF decrypt) (which transparently strips the armor).

To encrypt to more than one recipient, use
$(REF Encryptor.withRecipients, sparkles,age,protocol) together with
[armor.armorEncode] directly.

Faithful port of rage's `age::encrypt_and_armor`.

Params:
    recipient = the recipient to encrypt to (any $(REF isRecipient,
        sparkles,age,recipient) type; taken $(B by value) and `move`d on —
        pass an rvalue or `std.algorithm.mutation.move`)
    plaintext = the payload to encrypt (may be empty)
Returns: the ASCII-armored age file, or the
    $(REF EncryptError, sparkles,age,errors) from $(LREF encrypt).
*/
EncryptExpected!string encryptAndArmor(R)(R recipient, scope const(ubyte)[] plaintext)
if (isRecipient!R)
{
    import std.algorithm.mutation : move;
    import std.array : appender;

    // Taken by value and `move`d on, for the same non-copyable-secret reason as
    // $(LREF encrypt).
    auto binary = encrypt(move(recipient), plaintext);
    if (!binary.hasValue)
        return encryptErr!string(binary.error);

    auto w = appender!string;
    armorEncode(binary.value, w);
    return encryptOk(w[]);
}

// ─────────────────────────────────────────────────────────────────────────────
// Decryption
// ─────────────────────────────────────────────────────────────────────────────

/**
Decrypts `ciphertext` with a single `identity`, returning the recovered
plaintext.

`ciphertext` may be either a $(B binary) age file or an $(B ASCII-armored) one
(§7.6); the armor is detected transparently via [armor.looksArmored] and
stripped with [armor.armorDecode] before parsing. After de-armoring (if needed),
this is equivalent to
`Decryptor.parse(binary).decrypt([AnyIdentity(identity)])`: the v1 header and
payload nonce are parsed and validated, the file key is unwrapped using
`identity` (verifying the header MAC), and the STREAM body is decrypted.

To attempt decryption with more than one identity, use
$(REF Decryptor, sparkles,age,protocol) directly.

Faithful port of rage's `age::decrypt`.

Params:
    identity  = the identity to decrypt with (any $(REF isIdentity,
        sparkles,age,identity) type; taken $(B by value) and `move`d into
        the decryptor — pass an rvalue or `std.algorithm.mutation.move`,
        since an `X25519Identity` holds a non-copyable zeroizing scalar)
    ciphertext = the binary or armored age file
Returns: the recovered plaintext, or
    $(UL
        $(LI an `invalidHeader` if `ciphertext` looked armored but the armor failed
            to decode (an armor decode failure is reported as a malformed header,
            matching rage's collapse of the armor reader's error into the header
            parse);)
        $(LI any $(REF DecryptError, sparkles,age,errors) from
            $(REF Decryptor.parse, sparkles,age,protocol) /
            $(REF Decryptor.decrypt, sparkles,age,protocol) — `unknownFormat`,
            `invalidHeader`, `noMatchingKeys`, `invalidMac`, a STREAM error, etc.))
*/
DecryptExpected!(ubyte[]) decrypt(I)(I identity, scope const(ubyte)[] ciphertext)
if (isIdentity!I)
{
    import std.algorithm.mutation : move;

    // Transparently strip ASCII armor if present (rage's `ArmoredReader`).
    // `looksArmored` / `armorDecode` work on `char`; the bytes are reinterpreted
    // (armor is a strict ASCII PEM block).
    //
    // `identity` is taken by value and `move`d into the chosen branch: an
    // `X25519Identity` is non-copyable (zeroizing scalar), so it can never be
    // copied through an `in`/`const` parameter. Only one branch ever runs, so
    // the per-branch `move` is sound.
    if (looksArmored(cast(const(char)[]) ciphertext))
    {
        auto decoded = armorDecode(cast(const(char)[]) ciphertext);
        if (!decoded.hasValue)
            // An armor decode failure presents as a malformed file: rage folds
            // the armor reader's error into the header-parse error path.
            return decryptErr!(ubyte[])(DecryptErrorCode.invalidHeader);

        // `decoded.value` is a fresh owned slice; it implicitly converts to the
        // `scope` parameter and outlives the `Decryptor` it backs.
        return decryptBinary(move(identity), decoded.value);
    }

    return decryptBinary(move(identity), ciphertext);
}

/**
Decrypts a $(B binary) age file `binary` with a single `identity`.

Shared back end for $(LREF decrypt) after any armor has been stripped. `binary`
is borrowed by $(REF Decryptor.parse, sparkles,age,protocol) (the ciphertext
tail is a slice into it), so it must outlive the `Decryptor`; this helper keeps
`binary` alive for the full `parse`+`decrypt` call, then returns the owned
plaintext.
*/
private DecryptExpected!(ubyte[]) decryptBinary(I)(
    I identity,
    scope const(ubyte)[] binary,
)
if (isIdentity!I)
{
    import std.algorithm.mutation : move;

    auto dec = Decryptor.parse(binary);
    if (!dec.hasValue)
        return decryptErr!(ubyte[])(dec.error);

    // `identity` is taken by value and `move`d into the sum type — see
    // $(LREF decrypt) for why a non-copyable identity can't go through `in`.
    AnyIdentity[1] identities = [AnyIdentity(move(identity))];
    // Bind the parsed `Decryptor` to a local lvalue first: `Expected.value`
    // returns a `scope`-inferred temporary, and `Decryptor.decrypt` is a
    // non-`scope` member, so it cannot be called on that temporary directly.
    auto decryptor = dec.value;
    return decryptor.decrypt(identities[]);
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import sparkles.age.armor : ARMOR_BEGIN;
    import sparkles.age.recipients.scrypt : ScryptIdentity, ScryptRecipient;
    import sparkles.age.recipients.x25519 : X25519Identity, X25519Recipient;

    /// A small, fast scrypt work factor for the round-trip test (the default 18
    /// would dominate the suite). `N = 2^10` derives in well under a millisecond.
    private enum ubyte fastWorkFactor = 10;

    /// The fixed plaintext used across the round-trip tests (rage's `test_msg`).
    private enum string TEST_MSG = "This is a test message. For testing.";

    /// Reconstructs an `X25519Identity` from another's `AGE-SECRET-KEY-1…`
    /// serialization. The identity is non-copyable (its scalar is a zeroizing
    /// secret), so tests needing "the same" key on the encrypt and decrypt sides
    /// rebuild it from the decoded scalar rather than copying the value.
    private X25519Identity cloneIdentity(in X25519Identity id) @safe
    {
        import std.array : appender;
        import sparkles.crypto.encoding.bech32 : bech32MaxDecodedLength, decodeBech32;

        auto w = appender!string;
        id.toString(w);

        ubyte[bech32MaxDecodedLength(128)] buf = void;
        const(char)[] hrp;
        auto decoded = decodeBech32(w[], hrp, buf[0 .. bech32MaxDecodedLength(w[].length)]);
        assert(decoded.hasValue, "the secret-key string must decode");
        assert(decoded.value.length == 32, "the scalar payload must be 32 bytes");
        ubyte[32] scalar = decoded.value[0 .. 32];
        return X25519Identity.fromScalar(scalar);
    }
}

/// `encrypt(X25519Recipient, msg)` then `decrypt(X25519Identity, ct)` recovers
/// the plaintext exactly (rage's `simple::x25519_round_trip`).
@("age.simple.roundTrip.x25519")
@safe
unittest
{
    auto id = X25519Identity.generate();

    auto ct = encrypt(id.toPublic(), cast(const(ubyte)[]) TEST_MSG);
    assert(ct.hasValue, "encrypt to an X25519 recipient must succeed");

    // Binary ciphertext is a v1 age file, not armored.
    assert(cast(const(char)[]) ct.value[0 .. "age-encryption.org/v1".length]
        == "age-encryption.org/v1");

    auto pt = decrypt(cloneIdentity(id), ct.value);
    assert(pt.hasValue, "decrypt with the matching identity must succeed");
    assert(cast(const(char)[]) pt.value == TEST_MSG, "round-trip plaintext mismatch");
}

/// `encryptAndArmor` then `decrypt` (armor auto-detected) recovers the plaintext
/// (rage's `simple::x25519_round_trip_armor`).
@("age.simple.roundTrip.x25519Armor")
@safe
unittest
{
    auto id = X25519Identity.generate();

    auto armored = encryptAndArmor(id.toPublic(), cast(const(ubyte)[]) TEST_MSG);
    assert(armored.hasValue, "encryptAndArmor must succeed");

    // The result is a PEM-armored block.
    assert(armored.value.length >= ARMOR_BEGIN.length);
    assert(armored.value[0 .. ARMOR_BEGIN.length] == ARMOR_BEGIN,
        "encryptAndArmor output must begin with the PEM marker");

    // `decrypt` strips the armor transparently (it is fed the armored bytes).
    auto pt = decrypt(cloneIdentity(id), cast(const(ubyte)[]) armored.value);
    assert(pt.hasValue, "decrypt of an armored file must succeed");
    assert(cast(const(char)[]) pt.value == TEST_MSG, "armored round-trip mismatch");
}

/// `encrypt(ScryptRecipient(small logN), msg)` then `decrypt(ScryptIdentity)`
/// recovers the plaintext (rage's passphrase simple round-trip, with a fast work
/// factor so the test stays sub-millisecond).
@("age.simple.roundTrip.scrypt")
@safe
unittest
{
    enum string PASSPHRASE = "correct horse battery staple";

    auto ct = encrypt(ScryptRecipient(PASSPHRASE, fastWorkFactor),
        cast(const(ubyte)[]) TEST_MSG);
    assert(ct.hasValue, "encrypt to a passphrase recipient must succeed");

    auto pt = decrypt(ScryptIdentity(PASSPHRASE), ct.value);
    assert(pt.hasValue, "decrypt with the passphrase must succeed");
    assert(cast(const(char)[]) pt.value == TEST_MSG, "passphrase round-trip mismatch");
}

/// An armored round-trip through the passphrase path, too: the armor detection
/// is orthogonal to the recipient type.
@("age.simple.roundTrip.scryptArmor")
@safe
unittest
{
    enum string PASSPHRASE = "open sesame";

    auto armored = encryptAndArmor(ScryptRecipient(PASSPHRASE, fastWorkFactor),
        cast(const(ubyte)[]) TEST_MSG);
    assert(armored.hasValue);
    assert(armored.value[0 .. ARMOR_BEGIN.length] == ARMOR_BEGIN);

    auto pt = decrypt(ScryptIdentity(PASSPHRASE), cast(const(ubyte)[]) armored.value);
    assert(pt.hasValue);
    assert(cast(const(char)[]) pt.value == TEST_MSG);
}

/// An empty plaintext round-trips, too (the STREAM codec emits a single empty
/// final chunk; the simple API must not special-case it).
@("age.simple.roundTrip.emptyPlaintext")
@safe
unittest
{
    auto id = X25519Identity.generate();

    auto ct = encrypt(id.toPublic(), null);
    assert(ct.hasValue);

    auto pt = decrypt(cloneIdentity(id), ct.value);
    assert(pt.hasValue);
    assert(pt.value.length == 0, "empty plaintext must round-trip to empty");
}

/// Decrypting with an unrelated identity fails with `noMatchingKeys` — the
/// simple API surfaces the protocol layer's error unchanged.
@("age.simple.decrypt.wrongIdentityNoMatchingKeys")
@safe
unittest
{
    auto alice = X25519Identity.generate();
    auto bob = X25519Identity.generate();

    auto ct = encrypt(alice.toPublic(), cast(const(ubyte)[]) TEST_MSG);
    assert(ct.hasValue);

    auto pt = decrypt(cloneIdentity(bob), ct.value);
    assert(!pt.hasValue, "an unrelated identity must not decrypt");
    assert(pt.error.code == DecryptErrorCode.noMatchingKeys,
        "no identity matched any stanza → noMatchingKeys");
}

/// Decrypting with the wrong passphrase fails with `decryptionFailed` (the
/// scrypt identity matches the sole stanza but the AEAD open fails).
@("age.simple.decrypt.wrongPassphraseDecryptionFailed")
@safe
unittest
{
    auto ct = encrypt(ScryptRecipient("right", fastWorkFactor),
        cast(const(ubyte)[]) TEST_MSG);
    assert(ct.hasValue);

    auto pt = decrypt(ScryptIdentity("wrong"), ct.value);
    assert(!pt.hasValue, "the wrong passphrase must not decrypt");
    assert(pt.error.code == DecryptErrorCode.decryptionFailed,
        "a wrong passphrase → decryptionFailed");
}

/// Malformed armored input (a well-formed begin marker but a broken body) is
/// reported as `invalidHeader`: `decrypt` detects the armor, fails to decode it,
/// and folds that into the malformed-file error path.
@("age.simple.decrypt.malformedArmorInvalidHeader")
@safe
unittest
{
    auto id = X25519Identity.generate();

    // Looks armored (begins with the marker) but the body is not canonical and
    // there is no end marker → armorDecode fails.
    enum string BROKEN = "-----BEGIN AGE ENCRYPTED FILE-----\nnot base64 !!!\n";

    auto pt = decrypt(cloneIdentity(id), cast(const(ubyte)[]) BROKEN);
    assert(!pt.hasValue, "malformed armor must not decrypt");
    assert(pt.error.code == DecryptErrorCode.invalidHeader,
        "a broken armored block surfaces as invalidHeader");
}
