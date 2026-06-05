/**
The age encryption/decryption protocol (§7, §9): $(LREF Encryptor) and
$(LREF Decryptor).

This is the top-level orchestration layer that ties the key schedule
([keys.newFileKey], [keys.macKey], [keys.payloadKey]), the recipient/identity
concepts ($(REF AnyRecipient, sparkles,age,recipient) /
$(REF AnyIdentity, sparkles,age,identity)), the header
([header.buildHeader], [header.parseHeader], [header.writeHeader]) and the
STREAM payload codec ([stream.streamEncrypt], [stream.streamDecrypt]) into the
two end-to-end operations a caller cares about: turning a plaintext into an age
file, and turning an age file back into a plaintext.

$(UL
    $(LI $(LREF Encryptor) — constructed from a recipient list
        ($(LREF Encryptor.withRecipients)) or a passphrase
        ($(LREF Encryptor.withPassphrase)). Construction generates a fresh file
        key, wraps it for every recipient, validates that the recipients are
        mutually compatible (identical label sets, §8), builds the MAC'd header,
        and derives the STREAM payload key from a fresh 16-byte nonce. The
        resulting encryptor then either streams a payload through
        $(LREF Encryptor.wrapOutput) or one-shots it through
        $(LREF Encryptor.encryptToBytes).)
    $(LI $(LREF Decryptor) — constructed from an in-memory age file
        ($(LREF Decryptor.parse)), which parses and structurally validates the
        v1 header and reads the 16-byte payload nonce. $(LREF Decryptor.decrypt)
        walks a list of identities to recover the file key, re-derives the
        payload key (verifying the header MAC in the process), and STREAM-decrypts
        the body.)
)

This is a faithful port of rage's `age/src/protocol.rs` (`Encryptor`,
`Decryptor`). The wire bytes of an age file are exactly

```
<header> <16-byte nonce> <STREAM ciphertext>
```

where `<header>` ends at the `--- <base64 MAC>\n` line.

Conventions: `@safe` throughout; this layer MAY use the GC (the owned header
stanzas, the one-shot ciphertext / plaintext slices). Errors are reported via
$(REF EncryptExpected, sparkles,age,errors) /
$(REF DecryptExpected, sparkles,age,errors); nothing here throws.

The "grease" stanza rage injects when no scrypt recipient is present is
$(B deferred): decryptors already ignore unknown stanzas, so omitting it does
not affect interoperability.

See `docs/specs/age/SPEC.md` §7, §9 and `https://c2sp.org/age`.

Copyright: © 2026, Petar Kirov
License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
Authors: Petar Kirov
*/
module sparkles.age.protocol;

import std.range.primitives : isOutputRange, put;

import sparkles.crypto.random : randomArray;

import sparkles.age.errors :
    DecryptError, DecryptErrorCode, DecryptExpected, decryptErr, decryptOk,
    EncryptError, EncryptErrorCode, EncryptExpected, encryptErr, encryptOk;
import sparkles.age.format.header :
    buildHeader, HeaderV1, macInputOf, parseHeader, writeHeader;
import sparkles.age.format.stanza : Stanza;
import sparkles.age.identity : AnyIdentity, unwrapStanzas;
import sparkles.age.keys : FileKey, macKey, newFileKey, payloadKey;
import sparkles.age.recipient : AnyRecipient, WrapResult, wrapFileKey;
import sparkles.age.stream : streamEncrypt, streamWriter, streamDecrypt;

@safe:

// ─────────────────────────────────────────────────────────────────────────────
// Wire constants
// ─────────────────────────────────────────────────────────────────────────────

/// The size of the per-file STREAM payload nonce that follows the header on the
/// wire and salts the payload-key derivation (§7.5).
enum size_t PAYLOAD_NONCE_BYTES = 16;

/// The stanza tag for an scrypt (passphrase) recipient — used to distinguish a
/// label mismatch caused by mixing a passphrase recipient with others from a
/// plain incompatible-labels mismatch (§8).
private enum string SCRYPT_TAG = "scrypt";

// ─────────────────────────────────────────────────────────────────────────────
// Encryptor
// ─────────────────────────────────────────────────────────────────────────────

/**
Encrypts a plaintext into an age file for a fixed set of recipients (§7, §8).

Build one with $(LREF withRecipients) (an explicit recipient list) or
$(LREF withPassphrase) (a single scrypt recipient). Construction does all the
key-schedule work — generating the file key, wrapping it for every recipient,
checking recipient compatibility, building the MAC'd header, and deriving the
STREAM payload key from a fresh nonce — so the only state an `Encryptor` carries
afterward is the finished $(LREF header), the 16-byte payload $(LREF nonce), and
the 32-byte payload key. The file key itself is $(B not) retained: once the
header and payload key are derived it is no longer needed, and dropping it early
shrinks the window in which it lives in memory (rage likewise keeps only
`header`, `nonce`, `payload_key`).

Emit the file with either the streaming $(LREF wrapOutput) (for large payloads
that should not be fully buffered) or the one-shot $(LREF encryptToBytes).
*/
struct Encryptor
{
    /// The finished, MAC'd v1 header (its `encodedBytes` are the exact wire
    /// bytes written before the nonce).
    private HeaderV1 _header;

    /// The 16-byte STREAM payload nonce written immediately after the header.
    private ubyte[PAYLOAD_NONCE_BYTES] _nonce;

    /// The 32-byte STREAM payload key (HKDF-derived from the file key and the
    /// nonce, §7.5).
    private ubyte[32] _payloadKey;

    /**
    Constructs an `Encryptor` for `recipients` (§7, §8).

    Generates a fresh file key, wraps it for every recipient (collecting the
    resulting stanzas into the header in recipient order), and requires that
    every recipient declare an $(B identical) label set — the age compatibility
    rule (§8) that, in particular, forces an scrypt recipient to be a file's
    sole recipient. It then builds the header (computing its MAC under
    `macKey(fileKey)`), draws a fresh 16-byte payload nonce, and derives the
    STREAM payload key.

    Faithful port of rage's `Encryptor::with_recipients`.

    Params:
        recipients = the recipients to encrypt to; must be non-empty
    Returns: the constructed $(LREF Encryptor), or
        $(UL
            $(LI `EncryptErrorCode.missingRecipients` if `recipients` is empty;)
            $(LI `EncryptErrorCode.mixedRecipientAndPassphrase` if a passphrase
                (scrypt) recipient was mixed with any other recipient;)
            $(LI `EncryptErrorCode.incompatibleRecipients` if two non-passphrase
                recipients declared differing label sets;)
            $(LI the error from a recipient's `wrapFileKey` if wrapping failed.))
    */
    static EncryptExpected!Encryptor withRecipients(scope AnyRecipient[] recipients)
    {
        if (recipients.length == 0)
            return encryptErr!Encryptor(EncryptErrorCode.missingRecipients);

        // The file key wrapped into every recipient's stanza(s). Non-copyable:
        // consumed by reference throughout, and never retained on the encryptor.
        auto fileKey = newFileKey();

        Stanza[] stanzas;

        // The label set the first recipient established; every later recipient
        // must match it exactly (compared as a set). `null` until set.
        string[] control;
        bool haveControl = false;

        foreach (ref recipient; recipients)
        {
            auto wrapped = wrapFileKey(recipient, fileKey);
            if (!wrapped.hasValue)
                return encryptErr!Encryptor(wrapped.error);

            WrapResult r = wrapped.value;

            if (haveControl)
            {
                if (!labelsEqual(control, r.labels))
                {
                    // Improve the error message: a label mismatch that involves
                    // an scrypt stanza is really "a passphrase can't be combined
                    // with other recipients" (§8); any other mismatch is a plain
                    // incompatible-labels failure.
                    const mixed = anyScryptStanza(stanzas) || anyScryptStanza(r.stanzas);
                    return encryptErr!Encryptor(mixed
                        ? EncryptErrorCode.mixedRecipientAndPassphrase
                        : EncryptErrorCode.incompatibleRecipients);
                }
            }
            else
            {
                control = r.labels;
                haveControl = true;
            }

            stanzas ~= r.stanzas;
        }

        // Build the MAC'd header over the collected stanzas.
        auto header = buildHeader(stanzas, macKey(fileKey));

        // A fresh per-file STREAM payload nonce.
        const ubyte[PAYLOAD_NONCE_BYTES] nonce = randomArray!PAYLOAD_NONCE_BYTES();

        // Derive the payload key. `payloadKey` verifies the header MAC first;
        // here the header was just built so the MAC is correct by construction
        // (rage's `.expect("MAC is correct")`), but we surface any failure
        // rather than asserting — this layer never panics.
        auto pk = payloadKey(fileKey, macInputOf(header.encodedBytes), header.mac, nonce);
        if (!pk.hasValue)
            return encryptErr!Encryptor(EncryptErrorCode.wrapFailed);

        return encryptOk(Encryptor(header, nonce, pk.value));
    }

    /**
    Constructs an `Encryptor` that encrypts to a passphrase (§9.2).

    Equivalent to `withRecipients([AnyRecipient(ScryptRecipient(passphrase))])`.
    A single scrypt recipient can never fail the label-compatibility check (it is
    the only recipient), so this path always succeeds and unwraps the `Expected`.

    This API should only be used with a passphrase provided by, or generated for,
    a human; for programmatic use generate an
    $(REF X25519Identity, sparkles,age,recipients,x25519) and use
    $(LREF withRecipients). Faithful port of rage's
    `Encryptor::with_user_passphrase`.

    Params:
        passphrase = the passphrase characters (copied into the scrypt recipient's
            zeroizing secret store; the caller wipes any temporary)
    Returns: the constructed $(LREF Encryptor).
    */
    static Encryptor withPassphrase(scope const(char)[] passphrase)
    {
        import sparkles.age.recipients.scrypt : ScryptRecipient;

        AnyRecipient[1] recipients = [AnyRecipient(ScryptRecipient(passphrase))];
        auto e = withRecipients(recipients[]);
        // A lone scrypt recipient can never trip the label check, and its
        // `wrapFileKey` cannot fail for the default work factor (logN < 64), so
        // construction is infallible here (rage's `.expect(...)`).
        assert(e.hasValue, "passphrase encryptor construction cannot fail");
        return e.value;
    }

    /// The finished, MAC'd v1 header this encryptor will write.
    ref const(HeaderV1) header() const scope return @safe pure nothrow @nogc
        => _header;

    /// The 16-byte STREAM payload nonce written immediately after the header.
    ubyte[PAYLOAD_NONCE_BYTES] nonce() const @safe pure nothrow @nogc
        => _nonce;

    /**
    Streams an encrypted age file into the byte output range `sink`.

    Writes the header (via [header.writeHeader]) and the 16-byte payload nonce,
    then returns a $(REF StreamWriter, sparkles,age,stream) wrapping `sink`. The
    caller writes the plaintext into the returned writer and $(B MUST) call its
    `finish()` to emit the final STREAM chunk — without it the produced file is
    truncated and will fail to decrypt.

    `sink` is held $(B by pointer) for the returned writer's lifetime (a
    [smallbuffer.SmallBuffer] / `Appender` is non-copyable / must not be copied),
    so the caller keeps it alive until after `finish()`.

    Faithful port of rage's `Encryptor::wrap_output`.

    Params:
        sink = a byte output range that receives the header, nonce, and ciphertext
    Returns: a `StreamWriter!W` sealing the payload into `sink`.
    */
    auto wrapOutput(W)(return ref W sink) const
    if (isOutputRange!(W, const(ubyte)[]))
    {
        writeHeader(sink, _header);
        put(sink, cast(const(ubyte)[]) _nonce[]);
        return streamWriter(_payloadKey, sink);
    }

    /**
    One-shot encryption of an in-memory `plaintext` into a complete age file.

    Returns `header ‖ nonce ‖ streamEncrypt(payloadKey, plaintext)` as a single
    GC-allocated `ubyte[]`. This is the buffer-everything convenience used by the
    simple API; for large payloads prefer the streaming $(LREF wrapOutput).

    Params:
        plaintext = the payload to encrypt (may be empty)
    Returns: the complete age file bytes.
    */
    ubyte[] encryptToBytes(scope const(ubyte)[] plaintext) const
    {
        import std.array : appender;

        auto buf = appender!(ubyte[]);
        writeHeader(buf, _header);
        buf.put(cast(const(ubyte)[]) _nonce[]);
        buf.put(streamEncrypt(_payloadKey, plaintext));
        return buf[];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Decryptor
// ─────────────────────────────────────────────────────────────────────────────

/**
Decrypts an in-memory age file (§7, §9).

Build one with $(LREF parse), which reads and structurally validates the v1
header and the 16-byte payload nonce that follows it, retaining a borrowed view
of the remaining ciphertext. $(LREF decrypt) then recovers the file key using a
list of identities, re-derives the payload key (verifying the header MAC in the
process), and STREAM-decrypts the body.

Faithful port of rage's `Decryptor` (the slice-backed, fully-in-memory variant).
The borrowed ciphertext slice MUST outlive the decryptor.
*/
struct Decryptor
{
    /// The parsed, structurally-valid v1 header.
    private HeaderV1 _header;

    /// The 16-byte STREAM payload nonce read immediately after the header.
    private ubyte[PAYLOAD_NONCE_BYTES] _nonce;

    /// A borrowed view of the STREAM ciphertext (everything after the nonce).
    private const(ubyte)[] _ciphertext;

    /**
    Parses an age file from `input`: the v1 header, the 16-byte payload nonce,
    and the trailing ciphertext.

    Rejects a non-v1 file with `unknownFormat` (rage's `UnknownFormat`), a
    structurally invalid header with `invalidHeader` (the scrypt sole-recipient
    rule, §9.2, checked via [header.HeaderV1.isValidStructure]), and a file too
    short to contain the payload nonce with `invalidHeader`.

    The header parser reports an unknown $(B version) as
    `ParseErrorCode.invalidIdentifier`; this maps it to `unknownFormat`. Every
    other header parse failure maps to `invalidHeader`.

    The remaining ciphertext is borrowed from `input` (not copied), so `input`
    MUST outlive the returned `Decryptor`.

    Params:
        input = the complete age file bytes (binary, not armored)
    Returns: the constructed $(LREF Decryptor), or a $(LREF DecryptError).
    */
    static DecryptExpected!Decryptor parse(return scope const(ubyte)[] input)
    {
        import sparkles.core_cli.text.errors : ParseErrorCode;

        size_t consumed;
        auto parsed = parseHeader(input, consumed);
        if (!parsed.hasValue)
        {
            // An unknown version (valid magic, non-"v1") is `unknownFormat`;
            // every other parse failure is a malformed header.
            const code = parsed.error.code == ParseErrorCode.invalidIdentifier
                ? DecryptErrorCode.unknownFormat
                : DecryptErrorCode.invalidHeader;
            return decryptErr!Decryptor(code);
        }

        HeaderV1 header = parsed.value;

        // Enforce the v1 structural rule (an scrypt stanza must be the sole
        // stanza): rage's `from_v1_header` gate.
        if (!header.isValidStructure)
            return decryptErr!Decryptor(DecryptErrorCode.invalidHeader);

        // The 16-byte payload nonce follows the header.
        const rest = input[consumed .. $];
        if (rest.length < PAYLOAD_NONCE_BYTES)
            return decryptErr!Decryptor(DecryptErrorCode.invalidHeader);

        ubyte[PAYLOAD_NONCE_BYTES] nonce = rest[0 .. PAYLOAD_NONCE_BYTES];
        const ciphertext = rest[PAYLOAD_NONCE_BYTES .. $];

        return decryptOk(Decryptor(header, nonce, ciphertext));
    }

    /**
    Returns `true` iff this age file is encrypted to a passphrase — i.e. its
    header carries an scrypt stanza.

    Mirrors rage's `Decryptor::is_scrypt`. Because $(LREF parse) already enforced
    the structural rule, an scrypt stanza (if present) is the file's only stanza.
    */
    bool isScrypt() const scope @safe pure nothrow @nogc
    {
        foreach (ref r; _header.recipients)
            if (r.tag == SCRYPT_TAG)
                return true;
        return false;
    }

    /// The parsed v1 header.
    ref const(HeaderV1) header() const scope return @safe pure nothrow @nogc
        => _header;

    /**
    Decrypts the age file using `identities`, returning the recovered plaintext.

    Walks `identities` in order; for each, attempts to unwrap the file key from
    the header's stanzas via the whole-header
    $(REF unwrapStanzas, sparkles,age,identity) dispatcher (which uses an
    identity's whole-header capability — e.g. scrypt's sole-recipient check —
    when present, and otherwise loops the per-stanza unwrap). The first identity
    that produces a non-`null` outcome decides the result: a success fills the
    file key and decryption proceeds; a malformed/failed outcome returns its
    $(LREF DecryptError) immediately (matching rage's `find_map`).

    Once the file key is recovered, re-derives the payload key with
    [keys.payloadKey] — which $(B verifies the header MAC) (failing with
    `invalidMac` on a tampered header) — and STREAM-decrypts the body.

    Faithful port of rage's `Decryptor::obtain_payload_key` + `decrypt`.

    Params:
        identities = the identities to try, in order
    Returns: the recovered plaintext, or
        $(UL
            $(LI `noMatchingKeys` if no identity matched any stanza;)
            $(LI the malformed-stanza error from the first matching identity;)
            $(LI `invalidMac` if the header MAC does not verify under the recovered
                file key;)
            $(LI a STREAM error (`truncatedPayload` / `payloadError`) from the
                payload decode.))
    */
    DecryptExpected!(ubyte[]) decrypt(scope AnyIdentity[] identities) scope
    {
        // Recover the file key from the first matching identity.
        FileKey fileKey;
        bool matched = false;

        foreach (ref identity; identities)
        {
            auto outcome = unwrapStanzas(identity, _header.recipients, fileKey);
            if (outcome.isNull)
                continue; // not addressed to this identity — try the next.

            // The stanza(s) were addressed to this identity. A non-null error
            // means malformed/failed: surface it (rage's `find_map` stops here).
            if (outcome.get.hasError)
                return decryptErr!(ubyte[])(outcome.get.error);

            matched = true;
            break;
        }

        if (!matched)
            return decryptErr!(ubyte[])(DecryptErrorCode.noMatchingKeys);

        // Re-derive the payload key — this verifies the header MAC (→ invalidMac
        // on a tampered header) before deriving anything.
        auto pk = payloadKey(fileKey, macInputOf(_header.encodedBytes), _header.mac, _nonce);
        if (!pk.hasValue)
            return decryptErr!(ubyte[])(pk.error);

        return streamDecrypt(pk.value, _ciphertext);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Label-set helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Returns `true` iff `a` and `b` are equal as $(B sets) of labels: every label
/// in one appears in the other, regardless of order or duplicates. Mirrors
/// rage's `HashSet<String>` equality used to compare recipient label sets (§8).
private bool labelsEqual(scope const(string)[] a, scope const(string)[] b)
    @safe pure nothrow
{
    return containsAll(a, b) && containsAll(b, a);
}

/// Returns `true` iff every element of `needles` appears in `haystack`.
private bool containsAll(scope const(string)[] haystack, scope const(string)[] needles)
    @safe pure nothrow
{
    foreach (n; needles)
    {
        bool found = false;
        foreach (h; haystack)
            if (h == n)
            {
                found = true;
                break;
            }
        if (!found)
            return false;
    }
    return true;
}

/// Returns `true` iff any stanza in `stanzas` is an scrypt (passphrase) stanza —
/// used to refine a label mismatch into the
/// `mixedRecipientAndPassphrase` error (§8).
private bool anyScryptStanza(scope const(Stanza)[] stanzas) @safe pure nothrow @nogc
{
    foreach (ref s; stanzas)
        if (s.tag == SCRYPT_TAG)
            return true;
    return false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import sparkles.age.recipients.x25519 : X25519Identity, X25519Recipient;
    import sparkles.age.recipients.scrypt : ScryptIdentity, ScryptRecipient;

    /// A small, fast scrypt work factor for the protocol tests (the default 18
    /// would dominate the suite). `N = 2^10` derives in well under a millisecond.
    private enum ubyte fastWorkFactor = 10;

    /// A fixed plaintext used across the round-trip tests.
    private enum string TEST_MSG = "This is a test message. For testing.";

    /// Clones an `X25519Identity` by serializing it to its `AGE-SECRET-KEY-1…`
    /// string and rebuilding from the decoded scalar. The identity is
    /// non-copyable (its scalar is a zeroizing `SecretArray`), so tests that need
    /// "the same" key on both the encrypt and decrypt sides reconstruct it this
    /// way — going through `fromScalar` (never through a copyable `.value`).
    private X25519Identity cloneIdentity(in X25519Identity id) @safe
    {
        import std.array : appender;

        auto w = appender!string;
        id.toString(w);
        return X25519Identity.fromScalar(scalarBytes(w[]));
    }

    /// Decodes the 32-byte scalar payload from an uppercase `AGE-SECRET-KEY-1…`
    /// string (bech32, hrp `age-secret-key-`). Used only to move a non-copyable
    /// identity's secret into a fresh `X25519Identity` (see `cloneIdentity`).
    private ubyte[32] scalarBytes(scope const(char)[] s) @safe
    {
        import sparkles.crypto.encoding.bech32 : bech32MaxDecodedLength, decodeBech32;

        ubyte[bech32MaxDecodedLength(128)] buf = void;
        const(char)[] hrp;
        auto decoded = decodeBech32(s, hrp, buf[0 .. bech32MaxDecodedLength(s.length)]);
        assert(decoded.hasValue, "the secret-key string must decode");
        assert(decoded.value.length == 32, "the scalar payload must be 32 bytes");
        ubyte[32] scalar = decoded.value[0 .. 32];
        return scalar;
    }
}

/// A full X25519 round-trip: `withRecipients([X25519]) → encryptToBytes →
/// Decryptor.parse → decrypt([X25519 identity])` recovers the plaintext exactly
/// (rage's `x25519_round_trip`).
@("age.protocol.roundTrip.x25519")
@safe
unittest
{
    auto id = X25519Identity.generate();

    AnyRecipient[1] recipients = [AnyRecipient(id.toPublic())];
    auto enc = Encryptor.withRecipients(recipients[]);
    assert(enc.hasValue, "withRecipients([X25519]) must succeed");

    const file = enc.value.encryptToBytes(cast(const(ubyte)[]) TEST_MSG);

    auto dec = Decryptor.parse(file);
    assert(dec.hasValue, "the produced age file must parse");
    assert(!dec.value.isScrypt, "an X25519 file is not a passphrase file");

    // Decrypt with the matching identity (a clone of the one that owns the
    // recipient — the original is non-copyable).
    AnyIdentity[1] identities = [AnyIdentity(cloneIdentity(id))];

    auto plaintext = dec.value.decrypt(identities[]);
    assert(plaintext.hasValue, "decrypt with the matching identity must succeed");
    assert(cast(const(char)[]) plaintext.value == TEST_MSG,
        "round-trip plaintext mismatch");
}

/// A passphrase round-trip: `withPassphrase → encryptToBytes → Decryptor.parse →
/// decrypt([ScryptIdentity])` recovers the plaintext, and `isScrypt()` reports
/// the header is a passphrase file (rage's `scrypt_round_trip`).
@("age.protocol.roundTrip.passphrase")
@safe
unittest
{
    // Build the scrypt encryptor explicitly so we can use a fast work factor
    // (withPassphrase would use the slow default 18).
    AnyRecipient[1] recipients = [AnyRecipient(ScryptRecipient("passphrase", fastWorkFactor))];
    auto enc = Encryptor.withRecipients(recipients[]);
    assert(enc.hasValue, "withRecipients([scrypt]) must succeed");

    const file = enc.value.encryptToBytes(cast(const(ubyte)[]) TEST_MSG);

    auto dec = Decryptor.parse(file);
    assert(dec.hasValue, "the produced passphrase age file must parse");
    assert(dec.value.isScrypt, "a passphrase file must report isScrypt()");

    AnyIdentity[1] identities = [AnyIdentity(ScryptIdentity("passphrase"))];
    auto plaintext = dec.value.decrypt(identities[]);
    assert(plaintext.hasValue, "decrypt with the passphrase identity must succeed");
    assert(cast(const(char)[]) plaintext.value == TEST_MSG,
        "passphrase round-trip plaintext mismatch");
}

/// `wrapOutput` (the streaming API) produces a byte-identical age file to the
/// one-shot `encryptToBytes`, and the result decrypts.
@("age.protocol.wrapOutput.matchesEncryptToBytes")
@safe
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    auto id = X25519Identity.generate();
    AnyRecipient[1] recipients = [AnyRecipient(id.toPublic())];
    auto enc = Encryptor.withRecipients(recipients[]);
    assert(enc.hasValue);

    // Stream the same plaintext through wrapOutput.
    SmallBuffer!(ubyte, 256) sink;
    {
        auto w = enc.value.wrapOutput(sink);
        w.put(cast(const(ubyte)[]) TEST_MSG);
        w.finish();
    }

    // Byte-for-byte identical to the one-shot path (same header, nonce, and
    // payload key are reused; the STREAM codec is deterministic given the key).
    const oneShot = enc.value.encryptToBytes(cast(const(ubyte)[]) TEST_MSG);
    assert(sink[] == oneShot,
        "wrapOutput diverged from encryptToBytes for the same encryptor");

    // And it decrypts back to the plaintext.
    auto dec = Decryptor.parse(sink[].dup);
    assert(dec.hasValue);
    AnyIdentity[1] identities = [AnyIdentity(cloneIdentity(id))];
    auto plaintext = dec.value.decrypt(identities[]);
    assert(plaintext.hasValue);
    assert(cast(const(char)[]) plaintext.value == TEST_MSG);
}

/// Decrypting with an identity that owns none of the header's stanzas fails with
/// `noMatchingKeys`.
@("age.protocol.decrypt.nonMatchingIdentity")
@safe
unittest
{
    auto alice = X25519Identity.generate();
    auto bob = X25519Identity.generate();

    // Encrypt for Alice.
    AnyRecipient[1] recipients = [AnyRecipient(alice.toPublic())];
    auto enc = Encryptor.withRecipients(recipients[]);
    assert(enc.hasValue);
    const file = enc.value.encryptToBytes(cast(const(ubyte)[]) TEST_MSG);

    auto dec = Decryptor.parse(file);
    assert(dec.hasValue);

    // Try to decrypt with Bob — none of his keys match.
    AnyIdentity[1] identities = [AnyIdentity(cloneIdentity(bob))];
    auto plaintext = dec.value.decrypt(identities[]);
    assert(!plaintext.hasValue, "an unrelated identity must not decrypt");
    assert(plaintext.error.code == DecryptErrorCode.noMatchingKeys,
        "no identity matched any stanza → noMatchingKeys");
}

/// A corrupted header MAC is caught during payload-key derivation and surfaces
/// as `invalidMac` (the right identity matches the stanza, but the MAC fails).
@("age.protocol.decrypt.corruptedMacInvalidMac")
@safe
unittest
{
    auto id = X25519Identity.generate();
    AnyRecipient[1] recipients = [AnyRecipient(id.toPublic())];
    auto enc = Encryptor.withRecipients(recipients[]);
    assert(enc.hasValue);
    auto file = enc.value.encryptToBytes(cast(const(ubyte)[]) TEST_MSG);

    // Corrupt the base64 MAC field of the header so the recomputed MAC no longer
    // matches. The MAC line is the last header line: "--- <43 base64 chars>\n".
    // We locate the "--- " mark and replace the *first* MAC character with a
    // different base64 letter. Any of the first 42 MAC characters carries a full
    // 6-bit group, so swapping it for another alphabet character keeps the field
    // canonical (only the 43rd char is bit-constrained) — the file still parses,
    // and the MAC check fails on a different-but-well-formed tag.
    size_t macMark = locateMacMark(file);
    assert(macMark != size_t.max, "the header must contain a --- MAC mark");
    const size_t macChar0 = macMark + 4; // skip "--- "
    file[macChar0] = file[macChar0] == 'A' ? 'B' : 'A';

    auto dec = Decryptor.parse(file);
    assert(dec.hasValue, "a header with a wrong-but-well-formed MAC still parses");

    AnyIdentity[1] identities = [AnyIdentity(cloneIdentity(id))];
    auto plaintext = dec.value.decrypt(identities[]);
    assert(!plaintext.hasValue, "a tampered header MAC must not decrypt");
    assert(plaintext.error.code == DecryptErrorCode.invalidMac,
        "a corrupted header MAC must surface as invalidMac");
}

/// Mixing an X25519 recipient with an scrypt (passphrase) recipient is rejected:
/// the differing label sets refine to `mixedRecipientAndPassphrase` (rage's
/// `mixed_recipient_and_passphrase`).
@("age.protocol.withRecipients.mixedRecipientAndPassphrase")
@safe
unittest
{
    auto id = X25519Identity.generate();

    AnyRecipient[2] recipients = [
        AnyRecipient(id.toPublic()),
        AnyRecipient(ScryptRecipient("passphrase", fastWorkFactor)),
    ];
    auto enc = Encryptor.withRecipients(recipients[]);
    assert(!enc.hasValue, "X25519 + passphrase must be rejected");
    assert(enc.error.code == EncryptErrorCode.mixedRecipientAndPassphrase,
        "mixing a passphrase with another recipient → mixedRecipientAndPassphrase");
}

/// Two scrypt recipients also clash — each draws an independent random label, so
/// the second never matches the first's label set, and since both stanzas are
/// scrypt the mismatch refines to `mixedRecipientAndPassphrase`.
@("age.protocol.withRecipients.twoPassphrasesClash")
@safe
unittest
{
    AnyRecipient[2] recipients = [
        AnyRecipient(ScryptRecipient("one", fastWorkFactor)),
        AnyRecipient(ScryptRecipient("two", fastWorkFactor)),
    ];
    auto enc = Encryptor.withRecipients(recipients[]);
    assert(!enc.hasValue, "two scrypt recipients must be rejected");
    assert(enc.error.code == EncryptErrorCode.mixedRecipientAndPassphrase);
}

/// An empty recipient list is rejected with `missingRecipients`.
@("age.protocol.withRecipients.emptyMissingRecipients")
@safe
unittest
{
    AnyRecipient[] empty;
    auto enc = Encryptor.withRecipients(empty);
    assert(!enc.hasValue);
    assert(enc.error.code == EncryptErrorCode.missingRecipients);
}

/// `withPassphrase` is an infallible shorthand for a single scrypt recipient;
/// the produced file round-trips through a `ScryptIdentity` (uses the default
/// work factor, so this is the slower path — still sub-second at the default).
@("age.protocol.withPassphrase.roundTrip")
@safe
unittest
{
    auto enc = Encryptor.withPassphrase("hunter2");
    const file = enc.encryptToBytes(cast(const(ubyte)[]) "secret");

    auto dec = Decryptor.parse(file);
    assert(dec.hasValue);
    assert(dec.value.isScrypt);

    AnyIdentity[1] identities = [AnyIdentity(ScryptIdentity("hunter2"))];
    auto plaintext = dec.value.decrypt(identities[]);
    assert(plaintext.hasValue);
    assert(cast(const(char)[]) plaintext.value == "secret");
}

/// A non-v1 / non-age input is rejected by `parse`: an unknown version maps to
/// `unknownFormat`, and a truncated file (no room for the payload nonce) maps to
/// `invalidHeader`.
@("age.protocol.parse.rejectsBadInput")
@safe
unittest
{
    // Unknown version → unknownFormat.
    {
        immutable(ubyte)[] input = cast(immutable(ubyte)[])
            ("age-encryption.org/v2\n"
            ~ "-> X25519 abc\nAAAA\n"
            ~ "--- fgMiVLJHMlg9fW7CVG/hPS5EAU4Zeg19LyCP7SoH5nA\n");
        auto dec = Decryptor.parse(input);
        assert(!dec.hasValue);
        assert(dec.error.code == DecryptErrorCode.unknownFormat);
    }

    // A real v1 header but no payload nonce after it → invalidHeader.
    {
        auto id = X25519Identity.generate();
        AnyRecipient[1] recipients = [AnyRecipient(id.toPublic())];
        auto enc = Encryptor.withRecipients(recipients[]);
        assert(enc.hasValue);
        auto file = enc.value.encryptToBytes([]);

        // Truncate to exactly the header (drop the nonce + ciphertext). Find the
        // end of the header (the byte just after the MAC line's '\n').
        const headerLen = enc.value.header.encodedBytes.length;
        auto truncated = file[0 .. headerLen + 3]; // header + 3 of the 16 nonce bytes
        auto dec = Decryptor.parse(truncated);
        assert(!dec.hasValue, "a file with a partial payload nonce must be rejected");
        assert(dec.error.code == DecryptErrorCode.invalidHeader);
    }
}

version (unittest)
{
    /// Returns the byte offset of the `---` MAC mark in a binary age file, or
    /// `size_t.max` if not found. The MAC line is the last header line; we scan
    /// for the first `---` followed by a space at the start of a line.
    private size_t locateMacMark(scope const(ubyte)[] file) @safe pure nothrow @nogc
    {
        // Look for a line that begins with "--- " (preceded by '\n').
        foreach (i; 0 .. file.length)
        {
            if (i + 4 <= file.length
                && file[i] == '-' && file[i + 1] == '-' && file[i + 2] == '-'
                && file[i + 3] == ' ')
            {
                // Must be at the start of a line (i == 0 or preceded by '\n').
                if (i == 0 || file[i - 1] == '\n')
                    return i;
            }
        }
        return size_t.max;
    }
}
