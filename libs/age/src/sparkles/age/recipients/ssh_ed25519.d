/**
The age $(B ssh-ed25519) recipient and identity types (§9.3) — reuse of an
existing OpenSSH Ed25519 key pair as an age recipient/identity.

Unlike the native $(REF X25519Recipient, sparkles,age,recipients,x25519), an
`ssh-ed25519` stanza is $(B not) anonymous: it carries a 4-byte hint
(`tag = SHA-256(ssh-wire-pubkey)[:4]`) identifying which SSH key it was wrapped
for. The Ed25519 (twisted-Edwards) key is mapped onto its birationally
equivalent X25519 (Montgomery) key, and a per-key $(I tweak) derived from the
full SSH wire public key binds the otherwise-standard ephemeral X25519 handshake
to that specific key.

$(UL
    $(LI $(LREF SshEd25519Recipient) is parsed from an `authorized_keys`
        `ssh-ed25519 …` line (via
        $(REF parseAuthorizedKeyLine, sparkles,age,recipients,ssh_keys)). Its
        $(LREF SshEd25519Recipient.wrapFileKey) draws a fresh ephemeral secret
        `esk`, computes `epk = X25519(esk, basepoint)`, the raw shared secret
        `X25519(esk, pkX)` (where `pkX` is the Montgomery form of the recipient's
        Ed25519 point), then the $(I tweaked) shared secret
        `X25519(tweak, rawShared)`. It derives a wrap key with HKDF-SHA-256 over
        the label `"age-encryption.org/v1/ssh-ed25519"` and salt `epk ‖ pkX`, and
        ChaCha20-Poly1305-seals the file key under it (zero nonce). The stanza is
        `-> ssh-ed25519 <base64(tag)> <base64(epk)>` with the 32-byte sealed body,
        and the recipient's label set is $(B empty) — so it may be mixed with
        X25519 recipients.)
    $(LI $(LREF SshEd25519Identity) is parsed from an $(B unencrypted) OpenSSH PEM
        private key (via
        $(REF parseOpenSshPrivateKey, sparkles,age,recipients,ssh_keys)). Its
        $(LREF SshEd25519Identity.unwrapStanza) ignores any non-`ssh-ed25519`
        stanza; rejects a malformed one (`args.length != 2`, a non-canonical
        base64 argument, or a body that is not exactly 32 bytes) as
        `invalidHeader`; checks the 4-byte tag hint against its own key (a
        mismatch is the not-mine `null`); recomputes the tweaked shared secret
        `X25519(tweak, X25519(skX, epk))` ($(B aborting) on an all-zero result);
        re-derives the same wrap key; and tries to open the body. An AEAD failure
        is $(B not) fatal — it just means a tag collision against another key
        (the identity returns the not-mine `null` outcome, matching rage).)
)

This is a faithful port of rage's `age/src/ssh/recipient.rs`
(`Recipient::wrap_file_key` for `SshEd25519`) and `age/src/ssh/identity.rs`
(`UnencryptedKey::unwrap_stanza` for `SshEd25519`); the derivation strings and
canonicality requirements come from `docs/specs/age/SPEC.md` §9.3 and the
$(LINK2 https://c2sp.org/age, C2SP age spec) "ssh-ed25519 recipient type"
section.

This layer MAY use the GC: the parsed key structs own their `wirePubkey` byte
arrays, and $(LREF SshEd25519Recipient.wrapFileKey) returns a
$(REF WrapResult, sparkles,age,recipient) whose `Stanza[]` / `string[]` arrays
and the stanza body are GC-owned.

Copyright: © 2026, Petar Kirov
License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
Authors: Petar Kirov
*/
module sparkles.age.recipients.ssh_ed25519;

import sparkles.crypto.aead : aeadOpenZero, aeadSealZero, ChaCha20Poly1305;
import sparkles.crypto.ed25519 : ed25519PkToX25519, ed25519SkToX25519;
import sparkles.crypto.encoding.base64 :
    base64MaxDecodedLength, decodeBase64, encodeBase64;
import sparkles.crypto.hash : sha256;
import sparkles.crypto.hkdf : hkdfSha256;
import sparkles.crypto.random : randomArray;
import sparkles.crypto.x25519 : x25519, x25519Base;

import sparkles.core_cli.text.errors : ParseExpected, parseErr, parseOk;

import sparkles.age.errors :
    EncryptErrorCode, EncryptExpected, encryptErr, encryptOk;
import sparkles.age.format.stanza : Stanza;
import sparkles.age.identity :
    isIdentity, UnwrapOutcome, unwrapDone, unwrapFail, unwrapSkip;
import sparkles.age.keys : FileKey;
import sparkles.age.recipient : isRecipient, WrapResult;
import sparkles.age.recipients.ssh_keys :
    parseAuthorizedKeyLine, parseOpenSshPrivateKey;

@safe:

// ─────────────────────────────────────────────────────────────────────────────
// Shared constants (§9.3 / C2SP "ssh-ed25519 recipient type")
// ─────────────────────────────────────────────────────────────────────────────

/// The stanza tag for an `ssh-ed25519` recipient stanza (the first first-line
/// token), identical to the SSH key-type prefix (rage's
/// `SSH_ED25519_RECIPIENT_TAG`).
private enum string SSH_ED25519_TAG = "ssh-ed25519";

/**
The fixed HKDF `info` label for the `ssh-ed25519` tweak and wrap-key derivations
(§9.3). It is used twice: once as the `info` for the per-key tweak
(`HKDF(salt = wire pubkey, info = label, ikm = "")`), and once as the `info` for
the final wrap key (`HKDF(salt = epk ‖ pkX, info = label, ikm = shared)`).

Ports rage's `SSH_ED25519_RECIPIENT_KEY_LABEL`.
*/
enum string SSH_ED25519_LABEL = "age-encryption.org/v1/ssh-ed25519";

/// Length of an X25519 public key / ephemeral share / secret scalar / shared
/// secret.
private enum size_t KEY_BYTES = 32;

/// Length of the 4-byte key-tag hint, `SHA-256(wire pubkey)[:4]` (rage's
/// `TAG_LEN_BYTES`).
private enum size_t TAG_BYTES = 4;

/// Length of the libsodium Ed25519 secret key (`seed(32) ‖ pub(32)`).
private enum size_t ED25519_SECRET_BYTES = 64;

/// Length of the wrapped (sealed) file key: 16 plaintext bytes + the 16-byte
/// Poly1305 tag.
private enum size_t WRAPPED_FILE_KEY_BYTES = FileKey.length + ChaCha20Poly1305.TAG_SIZE;

// ─────────────────────────────────────────────────────────────────────────────
// Shared derivation helpers (used by both sides)
// ─────────────────────────────────────────────────────────────────────────────

/**
Computes the 4-byte key-tag hint `SHA-256(wirePubkey)[:4]`.

This is the short, non-secret identifier placed in (and matched against) the
first stanza argument, letting the decrypt side cheaply skip stanzas wrapped for
other keys. It is only a hint — a 32-bit collision is resolved by the AEAD open.
Ports rage's `ssh_tag`.
*/
private ubyte[TAG_BYTES] sshTag(scope const(ubyte)[] wirePubkey) nothrow @nogc
{
    ubyte[32] digest = void;
    sha256(wirePubkey, digest);
    ubyte[TAG_BYTES] tag = digest[0 .. TAG_BYTES];
    return tag;
}

/**
Derives the 32-byte per-key tweak,
`HKDF-SHA-256(salt = wirePubkey, info = SSH_ED25519_LABEL, ikm = "")`.

The tweak is used as an X25519 scalar applied to the raw ephemeral DH result; it
binds the otherwise-standard handshake to this specific SSH key. Both sides
compute it identically from the (public) SSH wire public key. Ports rage's
`hkdf(ssh_key, SSH_ED25519_RECIPIENT_KEY_LABEL, &[])`.
*/
private ubyte[KEY_BYTES] sshTweak(scope const(ubyte)[] wirePubkey) nothrow @nogc
{
    ubyte[KEY_BYTES] tweak = void;
    hkdfSha256(
        /* salt */ wirePubkey,
        /* info */ cast(const(ubyte)[]) SSH_ED25519_LABEL,
        /* ikm  */ null,
        tweak[]);
    return tweak;
}

/**
Derives the 32-byte wrap key from the tweaked `sharedSecret`, the ephemeral
share `epk`, and the recipient's Montgomery public key `pkX`.

`wrapKey = HKDF-SHA-256(salt = epk ‖ pkX, info = SSH_ED25519_LABEL,
ikm = sharedSecret)`. Both the encrypt side (which knows `pkX` directly) and the
decrypt side (which recomputes `pkX = X25519(skX, basepoint)`) call this with the
$(I same) `epk`/`pkX` ordering, so they derive the same key. Ports rage's final
`hkdf(&salt, SSH_ED25519_RECIPIENT_KEY_LABEL, shared_secret.as_bytes())`.
*/
private ubyte[KEY_BYTES] sshWrapKey(
    in ubyte[KEY_BYTES] sharedSecret,
    in ubyte[KEY_BYTES] epk,
    in ubyte[KEY_BYTES] pkX) nothrow @nogc
{
    // salt = ephemeral share (32) ‖ recipient Montgomery key (32).
    ubyte[2 * KEY_BYTES] salt = void;
    salt[0 .. KEY_BYTES] = epk[];
    salt[KEY_BYTES .. $] = pkX[];

    ubyte[KEY_BYTES] wrapKey = void;
    hkdfSha256(
        /* salt */ salt[],
        /* info */ cast(const(ubyte)[]) SSH_ED25519_LABEL,
        /* ikm  */ sharedSecret[],
        wrapKey[]);
    return wrapKey;
}

// ─────────────────────────────────────────────────────────────────────────────
// SshEd25519Recipient
// ─────────────────────────────────────────────────────────────────────────────

/**
An `ssh-ed25519` recipient: an OpenSSH Ed25519 public key reused as an age
recipient (a faithful port of rage's `Recipient::SshEd25519`).

It holds the 32-byte Ed25519 point and the full 51-byte SSH wire public key
($(LREF wirePubkey)) — the latter is what gets hashed for the 4-byte key tag and
used as the HKDF tweak salt, so it must be retained verbatim. The public key is
not secret, so this struct is a plain copyable value.

Build one with $(LREF parse) (from an `authorized_keys` `ssh-ed25519 …` line);
wrap a file key for it with $(LREF wrapFileKey), which satisfies
$(REF isRecipient, sparkles,age,recipient).
*/
struct SshEd25519Recipient
{
    /// The 32-byte raw Ed25519 public key.
    ubyte[KEY_BYTES] ed25519Pub;

    /// The full 51-byte SSH wire public key, GC-owned (hashed for the key tag
    /// and used as the HKDF tweak salt).
    ubyte[] wirePubkey;

    /**
    Parses a recipient from a single `authorized_keys` line
    (`ssh-ed25519 <base64> [comment]`).

    Forwards to
    $(REF parseAuthorizedKeyLine, sparkles,age,recipients,ssh_keys); a
    non-`ssh-ed25519` key type (or a malformed line) is rejected there with a
    distinct $(REF SshKeyParseReason, sparkles,age,recipients,ssh_keys).

    Params:
        authorizedKeyLine = one `authorized_keys` line
    Returns: the parsed $(LREF SshEd25519Recipient), or a `ParseError`.
    */
    static ParseExpected!SshEd25519Recipient parse(scope const(char)[] authorizedKeyLine)
    {
        alias R = SshEd25519Recipient;

        auto pub = parseAuthorizedKeyLine(authorizedKeyLine);
        if (pub.hasError)
            return parseErr!R(pub.error);

        R result;
        result.ed25519Pub = pub.value.ed25519Pub;
        result.wirePubkey = pub.value.wirePubkey;
        return parseOk(result);
    }

    /**
    Wraps `fileKey` for this recipient, producing a single `ssh-ed25519` stanza
    and an $(B empty) label set (§9.3).

    The tweaked-ECDH construction (a faithful port of rage's
    `Recipient::wrap_file_key` for `SshEd25519`):

    $(OL
        $(LI `tag = SHA-256(wirePubkey)[:4]`;)
        $(LI `pkX = ed25519PkToX25519(ed25519Pub)` — the recipient's Montgomery
            public key;)
        $(LI `tweak = HKDF(salt = wirePubkey, info = label, ikm = "")`;)
        $(LI draw a fresh `esk`; `epk = X25519(esk, basepoint)`;)
        $(LI `rawShared = X25519(esk, pkX)` ($(B abort) if all-zero);)
        $(LI `shared = X25519(tweak, rawShared)` ($(B abort) if all-zero);)
        $(LI `wrapKey = HKDF(salt = epk ‖ pkX, info = label, ikm = shared)`;)
        $(LI `body = ChaCha20-Poly1305(wrapKey, fileKey)` under the zero nonce.))

    The stanza is `-> ssh-ed25519 <base64(tag)> <base64(epk)>` with the 32-byte
    sealed body and no labels.

    Returns: a $(REF WrapResult, sparkles,age,recipient) with one stanza and no
        labels, or `EncryptErrorCode.wrapFailed` on an all-zero (non-contributory)
        shared secret (a sign of a failing CSPRNG; rage panics here).
    */
    EncryptExpected!WrapResult wrapFileKey(in FileKey fileKey) const
    {
        // 4-byte key tag and the recipient's Montgomery public key.
        const tag = sshTag(wirePubkey);
        ubyte[KEY_BYTES] pkX = void;
        ed25519PkToX25519(ed25519Pub, pkX);

        // Per-key tweak (binds the handshake to this specific SSH key).
        const tweak = sshTweak(wirePubkey);

        // Fresh ephemeral key pair for this stanza.
        const esk = randomArray!KEY_BYTES();
        ubyte[KEY_BYTES] epk = void;
        x25519Base(esk, epk);

        // rawShared = X25519(esk, pkX); shared = X25519(tweak, rawShared). An
        // all-zero result is non-contributory; rage panics ("OS RNG is likely
        // failing"), we surface it as a hard wrap failure.
        ubyte[KEY_BYTES] rawShared = void;
        if (!x25519(esk, pkX, rawShared))
            return encryptErr!WrapResult(EncryptErrorCode.wrapFailed);
        ubyte[KEY_BYTES] shared_ = void;
        if (!x25519(tweak, rawShared, shared_))
            return encryptErr!WrapResult(EncryptErrorCode.wrapFailed);

        const wrapKey = sshWrapKey(shared_, epk, pkX);

        // body = ChaCha20-Poly1305(wrapKey, fileKey) under the zero nonce.
        auto body_ = new ubyte[WRAPPED_FILE_KEY_BYTES];
        aeadSealZero(wrapKey, fileKey.exposeSecret(), body_);

        // args = [base64(tag), base64(epk)], unpadded standard base64.
        const string tagArg = base64String(tag[]);
        const string epkArg = base64String(epk[]);

        auto stanzas = [Stanza(SSH_ED25519_TAG, [tagArg, epkArg], body_)];
        return encryptOk(WrapResult(stanzas, null));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SshEd25519Identity
// ─────────────────────────────────────────────────────────────────────────────

/**
An `ssh-ed25519` identity: an OpenSSH Ed25519 private key reused as an age
identity (a faithful port of rage's `UnencryptedKey::SshEd25519`).

It holds the 64-byte libsodium Ed25519 secret key (`seed(32) ‖ pub(32)`) and the
matching 51-byte SSH wire public key ($(LREF wirePubkey)), from which both the
key tag and the HKDF tweak are derived. For M8 only $(B unencrypted) OpenSSH
keys are supported (encrypted ones are M9; see
$(REF parseOpenSshPrivateKey, sparkles,age,recipients,ssh_keys)).

Build one with $(LREF parse) (from an unencrypted OpenSSH PEM private key);
unwrap a header stanza with $(LREF unwrapStanza), which satisfies
$(REF isIdentity, sparkles,age,identity).
*/
struct SshEd25519Identity
{
    /// The 64-byte libsodium Ed25519 secret key (`seed ‖ pub`).
    ubyte[ED25519_SECRET_BYTES] ed25519Secret;

    /// The full 51-byte SSH wire public key, GC-owned.
    ubyte[] wirePubkey;

    /**
    Parses an identity from an $(B unencrypted) OpenSSH PEM private key.

    Forwards to
    $(REF parseOpenSshPrivateKey, sparkles,age,recipients,ssh_keys); an encrypted
    key, a non-ed25519 inner type, or a structural inconsistency is rejected
    there with a distinct
    $(REF SshKeyParseReason, sparkles,age,recipients,ssh_keys).

    Params:
        opensshPrivateKeyPem = the full PEM text including BEGIN/END markers
    Returns: the parsed $(LREF SshEd25519Identity), or a `ParseError`.
    */
    static ParseExpected!SshEd25519Identity parse(scope const(char)[] opensshPrivateKeyPem)
    {
        alias R = SshEd25519Identity;

        auto priv = parseOpenSshPrivateKey(opensshPrivateKeyPem);
        if (priv.hasError)
            return parseErr!R(priv.error);

        R result;
        result.ed25519Secret = priv.value.ed25519Secret;
        result.wirePubkey = priv.value.wirePubkey;
        return parseOk(result);
    }

    /**
    Attempts to unwrap the file key from a single recipient `stanza` (§9.3).

    Reports the not-mine / malformed / success trichotomy as an
    $(REF UnwrapOutcome, sparkles,age,identity):

    $(UL
        $(LI a non-`ssh-ed25519` `stanza.tag` → `null` (skip);)
        $(LI `args.length != 2`, an argument that is not the canonical base64 of
            the expected length (4-byte tag / 32-byte share), or a body that is
            not exactly 32 bytes → a non-null `invalidHeader` error;)
        $(LI a 4-byte tag argument that does not match `SHA-256(wirePubkey)[:4]` →
            `null` (this stanza was wrapped for a different SSH key — the tag is
            only a hint);)
        $(LI an all-zero tweaked shared secret → a non-null `decryptionFailed`
            error;)
        $(LI a body that opens under the derived wrap key → success: `fileKeyOut`
            is filled and a non-null OK outcome is returned;)
        $(LI a body that fails to open → `null` (a 32-bit tag collision against
            another key, indistinguishable from not-mine — matching rage's
            "we won't encounter 32-bit collisions" assumption).))

    Params:
        stanza     = a single recipient stanza from the header
        fileKeyOut = filled with the recovered file key on success
    */
    UnwrapOutcome unwrapStanza(in Stanza stanza, ref FileKey fileKeyOut) const
    {
        import sparkles.age.errors : DecryptErrorCode;

        if (stanza.tag != SSH_ED25519_TAG)
            return unwrapSkip();

        // Exactly two arguments: the base64 key tag and the base64 ephemeral
        // share.
        if (stanza.args.length != 2)
            return unwrapFail(DecryptErrorCode.invalidHeader);

        // arg[0]: the canonical base64 of a 4-byte tag hint.
        ubyte[TAG_BYTES] argTag = void;
        if (!decodeCanonical!TAG_BYTES(stanza.args[0], argTag))
            return unwrapFail(DecryptErrorCode.invalidHeader);

        // arg[1]: the canonical base64 of a 32-byte ephemeral share.
        ubyte[KEY_BYTES] epk = void;
        if (!decodeCanonical!KEY_BYTES(stanza.args[1], epk))
            return unwrapFail(DecryptErrorCode.invalidHeader);

        // The body MUST be exactly 32 bytes (wrapped 16-byte key + 16-byte tag),
        // checked before any decryption.
        if (stanza.body_.length != WRAPPED_FILE_KEY_BYTES)
            return unwrapFail(DecryptErrorCode.invalidHeader);

        // The tag is a 4-byte hint: if it does not match our key, this stanza is
        // not ours (skip). A match is not proof — the AEAD open resolves any
        // collision below.
        if (argTag != sshTag(wirePubkey))
            return unwrapSkip();

        // skX = ed25519SkToX25519(secret); pkX = X25519(skX, basepoint).
        ubyte[KEY_BYTES] skX = void;
        ed25519SkToX25519(ed25519Secret, skX);
        ubyte[KEY_BYTES] pkX = void;
        x25519Base(skX, pkX);

        // rawShared = X25519(skX, epk); shared = X25519(tweak, rawShared). An
        // all-zero tweaked result aborts as a decryption failure.
        const tweak = sshTweak(wirePubkey);
        ubyte[KEY_BYTES] rawShared = void;
        if (!x25519(skX, epk, rawShared))
            return unwrapFail(DecryptErrorCode.decryptionFailed);
        ubyte[KEY_BYTES] shared_ = void;
        if (!x25519(tweak, rawShared, shared_))
            return unwrapFail(DecryptErrorCode.decryptionFailed);

        const wrapKey = sshWrapKey(shared_, epk, pkX);

        // Try to open the body. A failure means a 32-bit tag collision against
        // another key — not-mine (null), never an error, matching rage.
        ubyte[FileKey.length] plaintext = void;
        if (!aeadOpenZero(wrapKey, stanza.body_, plaintext[]))
            return unwrapSkip();

        // It's ours: fill the caller's file key.
        fileKeyOut.exposeSecretMut()[] = plaintext[];
        return unwrapDone();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Small helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Base64-encodes `data` (unpadded standard base64) into a fresh GC-owned
/// immutable `string`, mirroring rage's `BASE64_STANDARD_NO_PAD.encode`.
///
/// The encode runs through a fixed `@nogc` stack buffer (a 32-byte value is 43
/// characters; the 4-byte tag is 6), then the bytes are copied into a freshly
/// allocated `char[]` that nothing else aliases, so handing it back as `string`
/// via `assumeUnique` is sound.
private string base64String(scope const(ubyte)[] data)
{
    import std.exception : assumeUnique;

    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 64) enc;
    encodeBase64(data, enc);

    auto buf = new char[enc[].length];
    buf[] = enc[];
    // `buf` was just freshly allocated and nothing else aliases it, so
    // reinterpreting it as `immutable` is sound — but `assumeUnique`'s cast is
    // `@system`, so wrap the hand-off in `@trusted`.
    return () @trusted { return assumeUnique(buf); }();
}

/**
Decodes `arg` as the $(B canonical) unpadded standard base64 of exactly `N`
bytes into `out_`, returning `true` only if it decodes cleanly to exactly `N`
bytes.

This is the D analogue of rage's `base64_arg::<_, N, …>`: a non-canonical
encoding (trailing non-zero bits, an over-long input, padding) or a decoded
length other than `N` fails. The strict
$(REF decodeBase64, sparkles,crypto,encoding,base64) rejects anything
non-canonical.
*/
private bool decodeCanonical(size_t N)(scope const(char)[] arg, ref ubyte[N] out_)
    pure nothrow @nogc
{
    // A generous upper bound on the encoded length of an N-byte value: an
    // N-byte value canonically encodes to ceil(N*8/6) characters; bound the
    // scratch buffer at the largest argument we ever read (a 32-byte share).
    enum size_t MAX_ARG_CHARS = 64;
    if (arg.length > MAX_ARG_CHARS)
        return false;
    ubyte[base64MaxDecodedLength(MAX_ARG_CHARS)] buf = void;
    auto r = decodeBase64(arg, buf[0 .. base64MaxDecodedLength(arg.length)]);
    if (!r.hasValue || r.value.length != N)
        return false;
    out_[] = r.value[0 .. N];
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// Conformance
// ─────────────────────────────────────────────────────────────────────────────

static assert(isRecipient!SshEd25519Recipient && isIdentity!SshEd25519Identity,
    "SshEd25519Recipient/SshEd25519Identity must satisfy the recipient/identity concepts");

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    // Two real `ssh-keygen -t ed25519` keys, supplied as the actual tooling
    // text (an `authorized_keys` line + the matching unencrypted OpenSSH PEM)
    // so the tests build a recipient and identity for the SAME key — or two
    // DIFFERENT keys — by going through the genuine parsers
    // ($(LREF SshEd25519Recipient.parse) / $(LREF SshEd25519Identity.parse)).
    // This keeps every (recipient, identity) pair perfectly self-consistent
    // without needing an Ed25519 keypair generator (the crypto layer exposes
    // only the Ed25519→X25519 conversions). Both keys also appear in the
    // `ssh_keys` parser tests.

    // KEY_A — rage's published str4d@carbon key
    // (age/src/ssh/{recipient,identity}.rs).
    private enum string KEY_A_PK =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHsKLqeplhpW+uObz5dvMgjz1OxfM/XXUB+VHtZ6isGN alice@rust";
    private enum string KEY_A_SK =
        "-----BEGIN OPENSSH PRIVATE KEY-----\n"
        ~ "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\n"
        ~ "QyNTUxOQAAACB7Ci6nqZYaVvrjm8+XbzII89TsXzP111AflR7WeorBjQAAAJCfEwtqnxML\n"
        ~ "agAAAAtzc2gtZWQyNTUxOQAAACB7Ci6nqZYaVvrjm8+XbzII89TsXzP111AflR7WeorBjQ\n"
        ~ "AAAEADBJvjZT8X6JRJI8xVq/1aU8nMVgOtVnmdwqWwrSlXG3sKLqeplhpW+uObz5dvMgjz\n"
        ~ "1OxfM/XXUB+VHtZ6isGNAAAADHN0cjRkQGNhcmJvbgE=\n"
        ~ "-----END OPENSSH PRIVATE KEY-----";

    // KEY_B — a second, independently generated tester@sparkles key.
    private enum string KEY_B_PK =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAscYI5rUkQ/L1teWEffdZ4nZdsxPaEfp+1gU4H4USzw tester@sparkles";
    private enum string KEY_B_SK =
        "-----BEGIN OPENSSH PRIVATE KEY-----\n"
        ~ "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\n"
        ~ "QyNTUxOQAAACALHGCOa1JEPy9bXlhH33WeJ2XbMT2hH6ftYFOB+FEs8AAAAJheKpyYXiqc\n"
        ~ "mAAAAAtzc2gtZWQyNTUxOQAAACALHGCOa1JEPy9bXlhH33WeJ2XbMT2hH6ftYFOB+FEs8A\n"
        ~ "AAAEB5tTO9gIDfkszqfynnTKzwEr/aFRHcwwM5gsRMpI24xgscYI5rUkQ/L1teWEffdZ4n\n"
        ~ "ZdsxPaEfp+1gU4H4USzwAAAAD3Rlc3RlckBzcGFya2xlcwECAwQFBg==\n"
        ~ "-----END OPENSSH PRIVATE KEY-----";

    // Parses a matched (recipient, identity) pair from a key's tooling text,
    // returning them via `out` parameters (both plain copyable structs). The two
    // halves share the same wire pubkey, so the tag hint matches and the
    // tweaked-ECDH handshake agrees.
    private void deriveSshPair(
        scope const(char)[] pkLine,
        scope const(char)[] skPem,
        out SshEd25519Recipient recipient,
        out SshEd25519Identity identity) @safe
    {
        auto r = SshEd25519Recipient.parse(pkLine);
        assert(r.hasValue, "test recipient key failed to parse");
        recipient = r.value;

        auto id = SshEd25519Identity.parse(skPem);
        assert(id.hasValue, "test identity key failed to parse");
        identity = id.value;
    }
}

/// A recipient and identity derived from the SAME Ed25519 key round-trip a
/// 16-byte file key: $(LREF SshEd25519Recipient.wrapFileKey) produces a
/// well-formed `ssh-ed25519` stanza (empty labels, two args, 32-byte body), and
/// the matching $(LREF SshEd25519Identity.unwrapStanza) recovers exactly those
/// 16 bytes.
@("age.recipients.ssh_ed25519.wrapUnwrapRoundTrip")
@safe
unittest
{
    SshEd25519Recipient recipient;
    SshEd25519Identity identity;
    deriveSshPair(KEY_A_PK, KEY_A_SK, recipient, identity);

    // A fixed file key so we can compare exact bytes.
    static immutable ubyte[16] raw = [
        7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    ];
    auto fileKey = FileKey.fromBytes(raw);

    auto wrapped = recipient.wrapFileKey(fileKey);
    assert(wrapped.hasValue, "wrapFileKey failed");
    assert(wrapped.value.stanzas.length == 1);
    assert(wrapped.value.labels.length == 0, "ssh-ed25519 must declare no labels");

    const stanza = wrapped.value.stanzas[0];
    assert(stanza.tag == "ssh-ed25519");
    assert(stanza.args.length == 2, "ssh-ed25519 stanza must carry tag + epk args");
    assert(stanza.body_.length == WRAPPED_FILE_KEY_BYTES);

    // Unwrap recovers the original file key.
    FileKey recovered;
    auto outcome = identity.unwrapStanza(stanza, recovered);
    assert(!outcome.isNull, "unwrapStanza returned not-mine for our own stanza");
    assert(!outcome.get.hasError, "unwrapStanza reported an error for a valid stanza");
    assert(recovered.exposeSecret() == raw[], "recovered file key mismatch");
}

/// A stanza wrapped for one SSH key is $(I not mine) to an identity built from a
/// different SSH key: the 4-byte tag hint does not match, so
/// $(LREF SshEd25519Identity.unwrapStanza) returns `null` (skip) — never an
/// error.
@("age.recipients.ssh_ed25519.unwrapStanza.tagMismatchReturnsNull")
@safe
unittest
{
    SshEd25519Recipient aliceR;
    SshEd25519Identity aliceId;
    deriveSshPair(KEY_A_PK, KEY_A_SK, aliceR, aliceId);

    SshEd25519Recipient bobR;
    SshEd25519Identity bobId;
    deriveSshPair(KEY_B_PK, KEY_B_SK, bobR, bobId);

    static immutable ubyte[16] raw = [
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
    ];
    auto fileKey = FileKey.fromBytes(raw);

    // Wrap for Alice, then ask Bob to unwrap it.
    auto wrapped = aliceR.wrapFileKey(fileKey);
    assert(wrapped.hasValue);

    FileKey discard;
    auto outcome = bobId.unwrapStanza(wrapped.value.stanzas[0], discard);
    assert(outcome.isNull, "another key's stanza must be not-mine (null)");
}

/// A stanza whose tag is not `ssh-ed25519` is skipped with a `null` outcome.
@("age.recipients.ssh_ed25519.unwrapStanza.wrongTagReturnsNull")
@safe
unittest
{
    SshEd25519Recipient recipient;
    SshEd25519Identity identity;
    deriveSshPair(KEY_A_PK, KEY_A_SK, recipient, identity);

    auto stanza = Stanza("X25519", ["abc"], new ubyte[WRAPPED_FILE_KEY_BYTES]);
    FileKey discard;
    assert(identity.unwrapStanza(stanza, discard).isNull,
        "a non-ssh-ed25519 tag must be skipped (null)");
}

/// A well-formed `ssh-ed25519` stanza (matching tag hint and args) but with a
/// wrong-length body is rejected as `invalidHeader` (a non-null error), before
/// any decryption is attempted.
@("age.recipients.ssh_ed25519.unwrapStanza.wrongBodyLengthInvalidHeader")
@safe
unittest
{
    import sparkles.age.errors : DecryptErrorCode;

    SshEd25519Recipient recipient;
    SshEd25519Identity identity;
    deriveSshPair(KEY_A_PK, KEY_A_SK, recipient, identity);

    static immutable ubyte[16] raw = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    ];
    auto wrapped = recipient.wrapFileKey(FileKey.fromBytes(raw));
    assert(wrapped.hasValue);

    // Same args (matching tag + canonical share), but truncate the body by one
    // byte so the length check trips before decryption.
    auto good = wrapped.value.stanzas[0];
    auto bad = Stanza(good.tag, good.args, good.body_[0 .. $ - 1]);

    FileKey discard;
    auto outcome = identity.unwrapStanza(bad, discard);
    assert(!outcome.isNull, "a malformed stanza must not be skipped");
    assert(outcome.get.hasError);
    assert(outcome.get.error.code == DecryptErrorCode.invalidHeader);
}

/// An `ssh-ed25519` stanza with the wrong number of arguments (one, or three)
/// is rejected as `invalidHeader`.
@("age.recipients.ssh_ed25519.unwrapStanza.wrongArgCountInvalidHeader")
@safe
unittest
{
    import sparkles.age.errors : DecryptErrorCode;

    SshEd25519Recipient recipient;
    SshEd25519Identity identity;
    deriveSshPair(KEY_A_PK, KEY_A_SK, recipient, identity);

    // One argument (only the tag).
    {
        auto stanza = Stanza("ssh-ed25519", ["AAAAAA"],
            new ubyte[WRAPPED_FILE_KEY_BYTES]);
        FileKey discard;
        auto o = identity.unwrapStanza(stanza, discard);
        assert(!o.isNull && o.get.hasError);
        assert(o.get.error.code == DecryptErrorCode.invalidHeader);
    }

    // Three arguments.
    {
        auto stanza = Stanza("ssh-ed25519",
            ["AAAAAA", "O6DLx/wDIawpUC978NSPjYvrfDtJVnZApXKp4FMPHCY", "extra"],
            new ubyte[WRAPPED_FILE_KEY_BYTES]);
        FileKey discard;
        auto o = identity.unwrapStanza(stanza, discard);
        assert(!o.isNull && o.get.hasError);
        assert(o.get.error.code == DecryptErrorCode.invalidHeader);
    }
}

/// A non-canonical / wrong-length base64 argument (here a tag that decodes to
/// more than 4 bytes) is rejected as `invalidHeader`.
@("age.recipients.ssh_ed25519.unwrapStanza.badArgInvalidHeader")
@safe
unittest
{
    import sparkles.age.errors : DecryptErrorCode;

    SshEd25519Recipient recipient;
    SshEd25519Identity identity;
    deriveSshPair(KEY_A_PK, KEY_A_SK, recipient, identity);

    // arg[0] decodes to a 32-byte value (43 chars), not the expected 4-byte tag.
    auto stanza = Stanza("ssh-ed25519",
        ["O6DLx/wDIawpUC978NSPjYvrfDtJVnZApXKp4FMPHCY",
         "O6DLx/wDIawpUC978NSPjYvrfDtJVnZApXKp4FMPHCY"],
        new ubyte[WRAPPED_FILE_KEY_BYTES]);
    FileKey discard;
    auto o = identity.unwrapStanza(stanza, discard);
    assert(!o.isNull && o.get.hasError);
    assert(o.get.error.code == DecryptErrorCode.invalidHeader);
}

/// $(LREF SshEd25519Recipient.parse) accepts a real `authorized_keys`
/// `ssh-ed25519 …` line and $(LREF SshEd25519Identity.parse) accepts the
/// matching unencrypted OpenSSH private key; wrapping with the parsed recipient
/// and unwrapping with the parsed identity round-trips a file key.
/// A second, independently generated real `ssh-keygen` key (KEY_B,
/// tester@sparkles) also round-trips a file key through its parsed recipient and
/// identity — an extra real-tooling vector distinct from rage's str4d key.
@("age.recipients.ssh_ed25519.secondRealKeyRoundTrip")
@safe
unittest
{
    auto r = SshEd25519Recipient.parse(KEY_B_PK);
    assert(r.hasValue, "real authorized_keys line failed to parse");

    auto id = SshEd25519Identity.parse(KEY_B_SK);
    assert(id.hasValue, "real OpenSSH private key failed to parse");

    // The parsed recipient and identity must share the same wire pubkey (same
    // key), so the tag hint matches and the handshake agrees.
    assert(r.value.wirePubkey == id.value.wirePubkey,
        "parsed recipient/identity describe different keys");

    static immutable ubyte[16] raw = [
        0xca, 0xfe, 0xba, 0xbe, 0xde, 0xad, 0xbe, 0xef,
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
    ];
    auto fileKey = FileKey.fromBytes(raw);

    auto wrapped = r.value.wrapFileKey(fileKey);
    assert(wrapped.hasValue);

    FileKey recovered;
    auto outcome = id.value.unwrapStanza(wrapped.value.stanzas[0], recovered);
    assert(!outcome.isNull && !outcome.get.hasError,
        "real-key wrap/unwrap did not round-trip");
    assert(recovered.exposeSecret() == raw[]);
}
