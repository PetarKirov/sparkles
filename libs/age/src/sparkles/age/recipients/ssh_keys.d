/**
The SSH key-material parsers shared by the `ssh-ed25519` (§9.3) and (gated)
`ssh-rsa` (§9.4) recipient types: `authorized_keys` public-key lines and
unencrypted OpenSSH private keys, plus the low-level SSH wire-format readers
they are built on.

This module is the parsing-only half of age's SSH support — the cryptographic
wrapping/unwrapping lives in `sparkles.age.recipients.ssh_ed25519`. It is a
faithful port of the binary parsing in rage's `age/src/ssh.rs`
(`read_ssh::string`, `string_tag`, `ed25519_pubkey`, `openssh_privkey`,
`openssh_ed25519_privkey`, `comment_and_padding`, `encryption_header`) and
`age/src/ssh/identity.rs` (the `authorized_keys` / OpenSSH PEM framing).

# SSH wire format (RFC 4251 §5)

The OpenSSH serializations are built from a single composite type, the SSH
$(B string): a `uint32` $(B big-endian) length prefix followed by exactly that
many bytes. An ed25519 public key on the wire is therefore

```
[00 00 00 0b] "ssh-ed25519" [00 00 00 20] <32 raw public-key bytes>
```

a fixed 51 bytes ($(LREF sshWritePubkey) reproduces it; $(LREF sshReadString) /
$(LREF sshReadU32) read it back, bounds-checked).

# Public keys — `authorized_keys`

$(LREF parseAuthorizedKeyLine) parses one `ssh-ed25519 <base64> [comment]` line.
The middle token is $(B `=`-padded standard) base64 (the `authorized_keys`
flavour, not the unpadded age wire flavour); it decodes to the 51-byte SSH wire
form, from which the 32-byte ed25519 point is read. Non-ed25519 key types
(`ssh-rsa`, `ecdsa-…`, `sk-ssh-…`) are rejected here — they belong to §9.4 (M9)
or are unsupported — with a distinct $(LREF SshKeyParseReason).

# Private keys — OpenSSH PEM

$(LREF parseOpenSshPrivateKey) parses an
`-----BEGIN OPENSSH PRIVATE KEY-----` … `-----END OPENSSH PRIVATE KEY-----`
block (PROTOCOL.key). For M8 only $(B unencrypted) ed25519 keys
(`cipher == "none" && kdf == "none"`) are supported; an encrypted key (any other
cipher/KDF) is rejected with the distinct
$(LREF SshKeyParseReason.encryptedKey) — decrypting it needs bcrypt-pbkdf +
AES, a second crypto backend that is M9. The 64-byte private value is the
libsodium secret-key form `seed(32) ‖ pub(32)`, and `priv[32 .. 64]` is verified
to equal the embedded public key.

# Error reporting

These parsers return $(REF ParseExpected, sparkles,core_cli,text,errors), whose
$(REF ParseError, sparkles,core_cli,text,errors) carries a scheme-agnostic
$(REF ParseErrorCode, sparkles,core_cli,text,errors). To surface the
$(I SSH-specific) reason a structurally-recognised key was rejected (a
non-ed25519 type vs. an encrypted key vs. a malformed body) — the "distinct,
clear code" §9.3/§9.4 calls for — the reason is also packed into the
`ParseError.offset` field as an $(LREF SshKeyParseReason). Recover it with
$(LREF sshReason). For a $(I generic truncation/bounds) failure the code is
`unexpectedEnd` and the offset is the genuine byte position; for an
SSH-classified rejection the code is `invalidIdentifier` and the offset is the
`SshKeyParseReason` ordinal (see $(LREF sshKeyError)).

This layer MAY use the GC: $(LREF SshPublicKey) / $(LREF SshEd25519PrivateKey)
own their `wirePubkey` byte arrays.

Copyright: © 2026, Petar Kirov
License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
Authors: Petar Kirov
*/
module sparkles.age.recipients.ssh_keys;

import std.typecons : Nullable, nullable;

import sparkles.crypto.encoding.base64 :
    base64MaxDecodedLength, decodeBase64Padded;

import sparkles.core_cli.text.errors :
    ParseError, ParseErrorCode, ParseExpected, parseErr, parseOk;

@safe:

// ─────────────────────────────────────────────────────────────────────────────
// Shared constants
// ─────────────────────────────────────────────────────────────────────────────

/// The SSH/age key-type prefix for an ed25519 key, on the wire and in
/// `authorized_keys` lines (rage's `SSH_ED25519_KEY_PREFIX`).
enum string SSH_ED25519_KEY_PREFIX = "ssh-ed25519";

/// The OpenSSH private-key container magic, including its trailing NUL
/// (`openssh-key-v1\0`).
private enum string OPENSSH_MAGIC = "openssh-key-v1\0";

/// PEM markers framing an OpenSSH private key.
private enum string OPENSSH_PEM_BEGIN = "-----BEGIN OPENSSH PRIVATE KEY-----";
/// ditto
private enum string OPENSSH_PEM_END = "-----END OPENSSH PRIVATE KEY-----";

/// Length of a raw ed25519 public key / seed.
private enum size_t ED25519_PUB_BYTES = 32;

/// Length of the libsodium ed25519 secret key (`seed(32) ‖ pub(32)`).
private enum size_t ED25519_SECRET_BYTES = 64;

// ─────────────────────────────────────────────────────────────────────────────
// SSH-specific error classification
// ─────────────────────────────────────────────────────────────────────────────

/**
Why an SSH key that was $(I structurally) recognised was nonetheless rejected.

When a parser here returns a `ParseError` whose
$(REF ParseErrorCode, sparkles,core_cli,text,errors) is `invalidIdentifier`, the
error's `offset` field holds one of these ordinals instead of a byte position
(see the module summary and $(LREF sshReason)). A `ParseError` with any other
code (e.g. `unexpectedEnd` for a truncated input) carries a genuine offset and
is $(I not) one of these classified rejections.
*/
enum SshKeyParseReason
{
    /// The textual framing was wrong: a missing/garbled `authorized_keys`
    /// prefix, a bad PEM marker, or a corrupt base64 body.
    malformed,
    /// The key type is not `ssh-ed25519` (e.g. `ssh-rsa`, `ecdsa-sha2-…`).
    /// `ssh-rsa` is gated behind §9.4 (M9); the rest are unsupported.
    unsupportedKeyType,
    /// A `sk-…` hardware-security-key type (stored on a FIDO/U2F token), which
    /// age cannot use for decryption.
    hardwareKey,
    /// The OpenSSH private key is $(B encrypted) (a cipher/KDF other than
    /// `none`). Decrypting it needs bcrypt-pbkdf + AES — a second crypto
    /// backend that is M9, not M8.
    encryptedKey,
    /// The OpenSSH container or wire structure was internally inconsistent
    /// (mismatched check-ints, a private value of the wrong length, a public
    /// key that does not match the embedded private value, or bad padding).
    invalidStructure,
}

/**
Builds a `ParseError` for an SSH-classified rejection: code
`invalidIdentifier`, with the `SshKeyParseReason` packed into `offset`.

Recover the reason from such an error with $(LREF sshReason). This is the
"distinct, clear code" path the SSH spec sections call for, kept within the
pinned $(REF ParseExpected, sparkles,core_cli,text,errors) return type.
*/
ParseError sshKeyError(SshKeyParseReason reason) pure nothrow @nogc
    => ParseError(ParseErrorCode.invalidIdentifier, cast(size_t) reason);

/// ditto — the `ParseExpected!T`-wrapped form a parser returns directly.
ParseExpected!T sshKeyErr(T)(SshKeyParseReason reason) pure nothrow @nogc
    => parseErr!T(ParseErrorCode.invalidIdentifier, cast(size_t) reason);

/**
Recovers the $(LREF SshKeyParseReason) from a `ParseError` produced by
$(LREF sshKeyError). Returns the classified reason iff the error's code is
`invalidIdentifier` (the SSH-classified path); for any other code there is no
SSH reason and the result is `null`.
*/
Nullable!SshKeyParseReason sshReason(in ParseError e) pure nothrow @nogc
{
    if (e.code != ParseErrorCode.invalidIdentifier)
        return Nullable!SshKeyParseReason.init;
    if (e.offset > cast(size_t) SshKeyParseReason.max)
        return Nullable!SshKeyParseReason.init;
    return nullable(cast(SshKeyParseReason) e.offset);
}

// ─────────────────────────────────────────────────────────────────────────────
// SSH wire-format readers (RFC 4251 §5)
// ─────────────────────────────────────────────────────────────────────────────

/**
Reads a big-endian `uint32` from the front of `data` and advances the cursor
past it. Mirrors rage/nom's `be_u32`.

`data` is taken by `ref` and, on success, sliced forward past the 4 consumed
bytes (the cursor $(I is) the remaining input). On truncation (`< 4` bytes
available) `data` is left untouched and the result is `unexpectedEnd` at the
current position.

Params:
    data = the input cursor; advanced past the 4 bytes on success
    out_ = receives the decoded value
Returns: a successful `ParseExpected!void`, or `unexpectedEnd`.
*/
ParseExpected!void sshReadU32(ref const(ubyte)[] data, out uint out_)
    pure nothrow @nogc
{
    if (data.length < 4)
        return parseErr!void(ParseErrorCode.unexpectedEnd, 0);
    out_ = (cast(uint) data[0] << 24)
        | (cast(uint) data[1] << 16)
        | (cast(uint) data[2] << 8)
        | (cast(uint) data[3]);
    data = data[4 .. $];
    return parseOk();
}

/**
Reads an SSH $(B string) — a big-endian `uint32` length prefix followed by that
many bytes — from the front of `data`, advancing the cursor past the whole
field. Mirrors rage's `read_ssh::string` (`length_data(be_u32)`).

The returned slice aliases into `data` (no copy). On a truncated length prefix
or a body that runs past the end of `data`, the cursor is left untouched and the
result is `unexpectedEnd`.

The cursor is a plain (non-`scope`) `const(ubyte)[]`: callers parse from a
GC-owned copy of the decoded key bytes, so the borrowed slices have the buffer's
(non-stack) lifetime and need no `scope` tracking.

Params:
    data = the input cursor; advanced past the length prefix and body on success
Returns: the body slice (aliasing `data`), or `unexpectedEnd`.
*/
ParseExpected!(const(ubyte)[]) sshReadString(ref const(ubyte)[] data)
    pure nothrow @nogc
{
    // Decode the length prefix without committing the cursor until the whole
    // field (prefix + body) is confirmed in range, so a truncated field leaves
    // `data` untouched.
    if (data.length < 4)
        return parseErr!(const(ubyte)[])(ParseErrorCode.unexpectedEnd, 0);
    const len = (cast(uint) data[0] << 24)
        | (cast(uint) data[1] << 16)
        | (cast(uint) data[2] << 8)
        | (cast(uint) data[3]);

    if (data.length - 4 < len)
        return parseErr!(const(ubyte)[])(ParseErrorCode.unexpectedEnd, 0);

    const(ubyte)[] body_ = data[4 .. 4 + len];
    data = data[4 + len .. $];
    return parseOk(body_);
}

/**
Reads an SSH string and checks that it equals `expected`, advancing the cursor
past it only on a match. Mirrors rage's `read_ssh::string_tag`.

On a length/bounds failure the result is `unexpectedEnd`; on a well-formed
string whose contents differ from `expected` the result is `unexpectedCharacter`
and the cursor is left untouched.
*/
private ParseExpected!void sshReadStringTag(
    ref const(ubyte)[] data, scope const(char)[] expected) pure nothrow @nogc
{
    // Remember the start so we can rewind on a content mismatch (the cursor must
    // only advance on a match).
    const(ubyte)[] start = data;
    auto s = sshReadString(data);
    if (s.hasError)
        return parseErr!void(s.error);
    if (s.value != cast(const(ubyte)[]) expected)
    {
        data = start;
        return parseErr!void(ParseErrorCode.unexpectedCharacter, 0);
    }
    return parseOk();
}

// ─────────────────────────────────────────────────────────────────────────────
// SSH wire-format writer
// ─────────────────────────────────────────────────────────────────────────────

/**
Serializes a 32-byte ed25519 public key into its 51-byte SSH wire form,
`sshString("ssh-ed25519") ‖ sshString(pub)`, returning a fresh GC-owned array.

This is the exact byte string that `authorized_keys` base64-encodes and that the
`ssh-ed25519` recipient hashes for its 4-byte key tag (rage builds the same wire
form from a `CompressedEdwardsY`).
*/
ubyte[] sshWritePubkey(in ubyte[ED25519_PUB_BYTES] ed25519Pub)
{
    // 4 + 11 (prefix) + 4 + 32 (key) = 51 bytes.
    auto buf = new ubyte[4 + SSH_ED25519_KEY_PREFIX.length + 4 + ED25519_PUB_BYTES];
    size_t i = 0;
    writeU32(buf, i, cast(uint) SSH_ED25519_KEY_PREFIX.length);
    buf[i .. i + SSH_ED25519_KEY_PREFIX.length] = cast(const(ubyte)[]) SSH_ED25519_KEY_PREFIX;
    i += SSH_ED25519_KEY_PREFIX.length;
    writeU32(buf, i, cast(uint) ED25519_PUB_BYTES);
    buf[i .. i + ED25519_PUB_BYTES] = ed25519Pub[];
    return buf;
}

/// Writes a big-endian `uint32` into `buf` at `i`, advancing `i` by 4.
private void writeU32(ubyte[] buf, ref size_t i, uint v) pure nothrow @nogc
{
    buf[i + 0] = cast(ubyte)(v >> 24);
    buf[i + 1] = cast(ubyte)(v >> 16);
    buf[i + 2] = cast(ubyte)(v >> 8);
    buf[i + 3] = cast(ubyte)(v);
    i += 4;
}

// ─────────────────────────────────────────────────────────────────────────────
// SshPublicKey — authorized_keys parsing
// ─────────────────────────────────────────────────────────────────────────────

/**
A parsed SSH public key from an `authorized_keys` line.

For M8 the only $(LREF keyType) is `"ssh-ed25519"`; $(LREF ed25519Pub) holds the
32-byte point and $(LREF wirePubkey) the full 51-byte SSH wire form
($(LREF sshWritePubkey)) that the recipient hashes for its key tag and uses as
the HKDF tweak salt.
*/
struct SshPublicKey
{
    /// The SSH key type (`"ssh-ed25519"` for M8).
    string keyType;
    /// The 32-byte raw ed25519 public key.
    ubyte[ED25519_PUB_BYTES] ed25519Pub;
    /// The full 51-byte SSH wire public key, GC-owned.
    ubyte[] wirePubkey;
}

/**
Parses a single `authorized_keys` line: `ssh-ed25519 <base64> [comment]`.

Surrounding ASCII whitespace and an optional trailing comment are tolerated. The
middle token is `=`-padded standard base64 (the `authorized_keys` flavour); it
decodes to the SSH wire form `sshString("ssh-ed25519") ‖ sshString(pub32)`, and
the inner key type MUST match the leading `ssh-ed25519` token.

Non-ed25519 key types are rejected with a distinct
$(LREF SshKeyParseReason) (`unsupportedKeyType`, or `hardwareKey` for an
`sk-…` token): `ssh-rsa` is §9.4/M9, the rest are unsupported. A malformed line
(missing token, bad base64, truncated wire form) is `SshKeyParseReason.malformed`
or, for a clean-but-truncated wire body, `unexpectedEnd`.

Params:
    line = one `authorized_keys` line (no trailing newline required)
Returns: the parsed $(LREF SshPublicKey), or a `ParseError`.
*/
ParseExpected!SshPublicKey parseAuthorizedKeyLine(scope const(char)[] line)
{
    alias R = SshPublicKey;

    // Trim leading/trailing ASCII whitespace.
    line = stripAsciiWs(line);
    if (line.length == 0)
        return sshKeyErr!R(SshKeyParseReason.malformed);

    // First SP-separated token: the key type.
    const sp1 = indexOfSpace(line);
    if (sp1 == line.length)
        // No base64 blob at all.
        return sshKeyErr!R(SshKeyParseReason.malformed);
    const(char)[] keyType = line[0 .. sp1];

    // Reject non-ed25519 key types up front (matching rage's per-type dispatch).
    if (keyType != SSH_ED25519_KEY_PREFIX)
        return sshKeyErr!R(classifyKeyType(keyType));

    // Second token: the base64 blob (everything up to the next space, if any).
    const(char)[] rest = stripLeadingSpaces(line[sp1 .. $]);
    const sp2 = indexOfSpace(rest);
    const(char)[] blob = rest[0 .. sp2];
    // (rest[sp2 .. $] is the optional comment; tolerated and ignored.)
    if (blob.length == 0)
        return sshKeyErr!R(SshKeyParseReason.malformed);

    // authorized_keys base64 is '='-padded standard base64.
    ubyte[base64MaxDecodedLength(MAX_PUBKEY_BLOB_CHARS)] decodeBuf = void;
    if (blob.length > MAX_PUBKEY_BLOB_CHARS)
        return sshKeyErr!R(SshKeyParseReason.malformed);
    auto decoded = decodeBase64Padded(blob, decodeBuf[0 .. base64MaxDecodedLength(blob.length)]);
    if (decoded.hasError)
        return sshKeyErr!R(SshKeyParseReason.malformed);

    // Materialize the decoded wire form into a GC-owned array up front: it
    // becomes the key's owned `wirePubkey`, and all wire-reader cursors borrow
    // from it (non-stack lifetime, no `scope` tracking needed).
    auto wire = new ubyte[decoded.value.length];
    wire[] = decoded.value[];

    const(ubyte)[] cursor = wire;

    auto kt = sshReadStringTag(cursor, SSH_ED25519_KEY_PREFIX);
    if (kt.hasError)
        // A clean wire form whose inner type differs is unsupported; a
        // truncated one is malformed.
        return kt.error.code == ParseErrorCode.unexpectedCharacter
            ? sshKeyErr!R(SshKeyParseReason.unsupportedKeyType)
            : sshKeyErr!R(SshKeyParseReason.malformed);

    auto pk = sshReadString(cursor);
    if (pk.hasError || pk.value.length != ED25519_PUB_BYTES)
        return sshKeyErr!R(SshKeyParseReason.malformed);

    // Reject trailing garbage after the public key (a canonical wire form ends
    // exactly here).
    if (cursor.length != 0)
        return sshKeyErr!R(SshKeyParseReason.malformed);

    R result;
    result.keyType = SSH_ED25519_KEY_PREFIX;
    result.ed25519Pub[] = pk.value[0 .. ED25519_PUB_BYTES];
    result.wirePubkey = wire;
    return parseOk(result);
}

/// The longest base64 blob $(LREF parseAuthorizedKeyLine) will consider: a
/// generous bound over the 51-byte ed25519 wire form (68 padded chars), with
/// slack so a slightly-larger malformed blob is still decoded-then-rejected
/// rather than refused outright.
private enum size_t MAX_PUBKEY_BLOB_CHARS = 128;

// ─────────────────────────────────────────────────────────────────────────────
// SshEd25519PrivateKey — OpenSSH PEM parsing
// ─────────────────────────────────────────────────────────────────────────────

/**
A parsed $(B unencrypted) OpenSSH ed25519 private key.

$(LREF ed25519Secret) is the 64-byte libsodium secret key (`seed(32) ‖ pub(32)`)
and $(LREF wirePubkey) the matching 51-byte SSH wire public key (the encryption
side derives both the key tag and the HKDF tweak from it).
*/
struct SshEd25519PrivateKey
{
    /// The 64-byte libsodium secret key (`seed ‖ pub`).
    ubyte[ED25519_SECRET_BYTES] ed25519Secret;
    /// The full SSH wire public key, GC-owned.
    ubyte[] wirePubkey;
}

/**
Parses an OpenSSH PEM private key (`-----BEGIN OPENSSH PRIVATE KEY-----` …).

The PEM body is `=`-padded standard base64; it decodes to the PROTOCOL.key
container, which is parsed as:

```
magic   "openssh-key-v1\0"
string  cipher        // MUST be "none" for M8
string  kdf           // MUST be "none" for M8
string  kdfoptions    // MUST be empty for an unencrypted key
uint32  numKeys       // MUST be 1 (OpenSSH only ever writes one)
string  publicKey     // the SSH wire public key
string  privateSection
```

and the private section as:

```
uint32  check1
uint32  check2        // MUST equal check1
string  "ssh-ed25519"
string  pub(32)
string  priv(64)      // seed ‖ pub
string  comment
byte    1, 2, 3, …    // deterministic padding
```

For M8 only `cipher == "none" && kdf == "none"` is accepted; any other
cipher/KDF is an $(B encrypted) key and is rejected with the distinct
$(LREF SshKeyParseReason.encryptedKey) (decrypting it is M9). A non-ed25519
inner key type is `unsupportedKeyType` (`hardwareKey` for `sk-…`); a structural
inconsistency (mismatched check-ints, wrong-length private value,
`priv[32 .. 64] != pub`, bad padding) is `invalidStructure`.

Params:
    pem = the full PEM text including BEGIN/END markers
Returns: the parsed $(LREF SshEd25519PrivateKey), or a `ParseError`.
*/
ParseExpected!SshEd25519PrivateKey parseOpenSshPrivateKey(scope const(char)[] pem)
{
    alias R = SshEd25519PrivateKey;

    // Strip PEM framing into the base64 body.
    const(char)[] body64 = stripAsciiWs(pem);
    if (body64.length < OPENSSH_PEM_BEGIN.length + OPENSSH_PEM_END.length
        || body64[0 .. OPENSSH_PEM_BEGIN.length] != OPENSSH_PEM_BEGIN
        || body64[$ - OPENSSH_PEM_END.length .. $] != OPENSSH_PEM_END)
        return sshKeyErr!R(SshKeyParseReason.malformed);

    body64 = body64[OPENSSH_PEM_BEGIN.length .. $ - OPENSSH_PEM_END.length];

    // Concatenate the base64 lines (PEM wraps at 70 columns), dropping ASCII
    // whitespace, into a scratch buffer before decoding.
    if (body64.length > MAX_PEM_BODY_CHARS)
        return sshKeyErr!R(SshKeyParseReason.malformed);

    char[MAX_PEM_BODY_CHARS] joinBuf = void;
    size_t jn = 0;
    foreach (c; body64)
        if (!isAsciiWs(c))
            joinBuf[jn++] = c;
    const(char)[] joined = joinBuf[0 .. jn];

    ubyte[base64MaxDecodedLength(MAX_PEM_BODY_CHARS)] decodeBuf = void;
    auto decoded = decodeBase64Padded(joined, decodeBuf[0 .. base64MaxDecodedLength(jn)]);
    if (decoded.hasError)
        return sshKeyErr!R(SshKeyParseReason.malformed);

    // Materialize the decoded container into a GC-owned array so the wire-reader
    // cursors borrow from a non-stack buffer (no `scope` tracking needed).
    auto container = new ubyte[decoded.value.length];
    container[] = decoded.value[];
    return parseOpenSshContainer(container);
}

/// Parses the decoded PROTOCOL.key container bytes (everything after the PEM
/// base64 decode). Split out so the wire-level parsing is testable from a raw
/// binary blob, mirroring rage's `read_ssh::openssh_privkey`. `data` is a
/// non-`scope` (GC-owned) array, so the borrowed cursors carry its lifetime.
private ParseExpected!SshEd25519PrivateKey parseOpenSshContainer(const(ubyte)[] data)
{
    alias R = SshEd25519PrivateKey;

    // magic "openssh-key-v1\0"
    if (data.length < OPENSSH_MAGIC.length
        || data[0 .. OPENSSH_MAGIC.length] != cast(const(ubyte)[]) OPENSSH_MAGIC)
        return sshKeyErr!R(SshKeyParseReason.malformed);
    const(ubyte)[] cursor = data[OPENSSH_MAGIC.length .. $];

    // string cipher; string kdf; string kdfoptions.
    auto cipher = sshReadString(cursor);
    if (cipher.hasError)
        return sshKeyErr!R(SshKeyParseReason.malformed);
    auto kdf = sshReadString(cursor);
    if (kdf.hasError)
        return sshKeyErr!R(SshKeyParseReason.malformed);
    auto kdfopts = sshReadString(cursor);
    if (kdfopts.hasError)
        return sshKeyErr!R(SshKeyParseReason.malformed);

    // M8 supports only unencrypted keys. Per OpenSSH, if either of cipher/kdf
    // is "none" both must be; any other cipher/kdf means an encrypted key (M9).
    const bool unencrypted =
        cipher.value == cast(const(ubyte)[]) "none"
        && kdf.value == cast(const(ubyte)[]) "none"
        && kdfopts.value.length == 0;
    if (!unencrypted)
        return sshKeyErr!R(SshKeyParseReason.encryptedKey);

    // uint32 numKeys (OpenSSH only ever writes a single key).
    uint numKeys;
    auto nk = sshReadU32(cursor, numKeys);
    if (nk.hasError)
        return sshKeyErr!R(SshKeyParseReason.malformed);
    if (numKeys != 1)
        return sshKeyErr!R(SshKeyParseReason.invalidStructure);

    // string publicKey (the SSH wire public key).
    auto publicKey = sshReadString(cursor);
    if (publicKey.hasError)
        return sshKeyErr!R(SshKeyParseReason.malformed);

    // string privateSection (unencrypted, so it is the cleartext key list).
    auto privSection = sshReadString(cursor);
    if (privSection.hasError)
        return sshKeyErr!R(SshKeyParseReason.malformed);

    return parsePrivateSection(privSection.value, publicKey.value);
}

/// Parses the (unencrypted) private key section: two equal check-ints, the
/// single ed25519 key, comment, and deterministic padding. `wirePub` is the
/// container's public-key string, retained verbatim as the key's `wirePubkey`.
/// Mirrors rage's `openssh_unencrypted_privkey` + `openssh_ed25519_privkey` +
/// `comment_and_padding`.
private ParseExpected!SshEd25519PrivateKey parsePrivateSection(
    const(ubyte)[] section, const(ubyte)[] wirePub)
{
    alias R = SshEd25519PrivateKey;

    const(ubyte)[] cursor = section;

    // uint32 check1; uint32 check2 — must be equal (intended as a decryption
    // sanity check; we still enforce it for an unencrypted key).
    uint c1, c2;
    if (sshReadU32(cursor, c1).hasError || sshReadU32(cursor, c2).hasError)
        return sshKeyErr!R(SshKeyParseReason.malformed);
    if (c1 != c2)
        return sshKeyErr!R(SshKeyParseReason.invalidStructure);

    // string "ssh-ed25519" — reject any other inner key type.
    auto kt = sshReadStringTag(cursor, SSH_ED25519_KEY_PREFIX);
    if (kt.hasError)
    {
        if (kt.error.code != ParseErrorCode.unexpectedCharacter)
            return sshKeyErr!R(SshKeyParseReason.malformed);
        // Re-read the actual type to classify it (rsa/ecdsa/sk-…).
        auto innerType = sshReadString(cursor);
        if (innerType.hasError)
            return sshKeyErr!R(SshKeyParseReason.malformed);
        return sshKeyErr!R(classifyKeyType(cast(const(char)[]) innerType.value));
    }

    // string pub(32); string priv(64).
    auto pub = sshReadString(cursor);
    if (pub.hasError)
        return sshKeyErr!R(SshKeyParseReason.malformed);
    auto priv = sshReadString(cursor);
    if (priv.hasError)
        return sshKeyErr!R(SshKeyParseReason.malformed);

    // The private value is seed(32) ‖ pub(32); its tail MUST equal the public
    // key (rage's `pubkey_bytes == &privkey_bytes[32..64]`).
    if (pub.value.length != ED25519_PUB_BYTES
        || priv.value.length != ED25519_SECRET_BYTES
        || priv.value[32 .. 64] != pub.value)
        return sshKeyErr!R(SshKeyParseReason.invalidStructure);

    // string comment, then deterministic padding 1, 2, 3, … (verify it).
    auto comment = sshReadString(cursor);
    if (comment.hasError)
        return sshKeyErr!R(SshKeyParseReason.malformed);
    foreach (i, b; cursor)
        if (b != cast(ubyte)((i + 1) & 0xFF))
            return sshKeyErr!R(SshKeyParseReason.invalidStructure);

    R result;
    result.ed25519Secret[] = priv.value[0 .. ED25519_SECRET_BYTES];
    auto owned = new ubyte[wirePub.length];
    owned[] = wirePub[];
    result.wirePubkey = owned;
    return parseOk(result);
}

/// The longest PEM base64 body $(LREF parseOpenSshPrivateKey) will consider,
/// including embedded newlines: an unencrypted ed25519 key is ~310 base64
/// chars, so 1024 leaves generous slack for comments/padding while bounding the
/// stack scratch buffers.
private enum size_t MAX_PEM_BODY_CHARS = 1024;

// ─────────────────────────────────────────────────────────────────────────────
// Small text helpers
// ─────────────────────────────────────────────────────────────────────────────

/// True for an ASCII whitespace byte (SP, TAB, LF, CR, VT, FF).
private bool isAsciiWs(char c) pure nothrow @nogc
    => c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f';

/// Strips leading and trailing ASCII whitespace from `s` (no allocation).
private const(char)[] stripAsciiWs(return scope const(char)[] s) pure nothrow @nogc
{
    size_t lo = 0, hi = s.length;
    while (lo < hi && isAsciiWs(s[lo]))
        ++lo;
    while (hi > lo && isAsciiWs(s[hi - 1]))
        --hi;
    return s[lo .. hi];
}

/// Strips only leading SP/TAB (used between `authorized_keys` tokens).
private const(char)[] stripLeadingSpaces(return scope const(char)[] s) pure nothrow @nogc
{
    size_t lo = 0;
    while (lo < s.length && (s[lo] == ' ' || s[lo] == '\t'))
        ++lo;
    return s[lo .. $];
}

/// Index of the first SP/TAB in `s`, or `s.length` if there is none.
private size_t indexOfSpace(scope const(char)[] s) pure nothrow @nogc
{
    foreach (i, c; s)
        if (c == ' ' || c == '\t')
            return i;
    return s.length;
}

/// Classifies a non-ed25519 SSH key type into the matching
/// $(LREF SshKeyParseReason), mirroring rage's `UnsupportedKey::from_key_type`
/// (an `sk-…` token is a hardware key; everything else is an unsupported type).
private SshKeyParseReason classifyKeyType(scope const(char)[] keyType) pure nothrow @nogc
{
    if (keyType.length >= 3 && keyType[0 .. 3] == "sk-")
        return SshKeyParseReason.hardwareKey;
    return SshKeyParseReason.unsupportedKeyType;
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests — wire helpers
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    // rage's published ssh-ed25519 test key (str4d@carbon), from
    // age/src/ssh/identity.rs and age/src/ssh/recipient.rs.
    //
    // The authorized_keys public-key line:
    private enum string RAGE_PK_LINE =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHsKLqeplhpW+uObz5dvMgjz1OxfM/XXUB+VHtZ6isGN alice@rust";

    // The matching unencrypted OpenSSH private key:
    private enum string RAGE_SK_PEM =
        "-----BEGIN OPENSSH PRIVATE KEY-----\n"
        ~ "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\n"
        ~ "QyNTUxOQAAACB7Ci6nqZYaVvrjm8+XbzII89TsXzP111AflR7WeorBjQAAAJCfEwtqnxML\n"
        ~ "agAAAAtzc2gtZWQyNTUxOQAAACB7Ci6nqZYaVvrjm8+XbzII89TsXzP111AflR7WeorBjQ\n"
        ~ "AAAEADBJvjZT8X6JRJI8xVq/1aU8nMVgOtVnmdwqWwrSlXG3sKLqeplhpW+uObz5dvMgjz\n"
        ~ "1OxfM/XXUB+VHtZ6isGNAAAADHN0cjRkQGNhcmJvbgE=\n"
        ~ "-----END OPENSSH PRIVATE KEY-----";

    // An aes256-cbc *encrypted* OpenSSH key for the same identity (M9 territory).
    private enum string RAGE_ENCRYPTED_PEM =
        "-----BEGIN OPENSSH PRIVATE KEY-----\n"
        ~ "b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jYmMAAAAGYmNyeXB0AAAAGAAAABC0OgNmiw\n"
        ~ "QW/kJ8kCmmTA2TAAAAEAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIHsKLqeplhpW+uOb\n"
        ~ "z5dvMgjz1OxfM/XXUB+VHtZ6isGNAAAAkPhBKsZoNmaeuWYJQxOl+ofEmue/sFJnW+4IOt\n"
        ~ "oTrS/orMBJ4b/phQcv/ejWYJ4RYYVhSLiI6hf0KwNGefxI90E8iG/yDOKcrxb34tqDEYrY\n"
        ~ "FARDaJVRd9QtWLEqoP7pgdBR2BTP7aK1y6Mx3eFDgiQI9f/0Sjxd8V0apOPXv4i4kuQ1Nt\n"
        ~ "LF7kNlDznn/nyZlg==\n"
        ~ "-----END OPENSSH PRIVATE KEY-----";

    // An ecdsa-sha2-nistp256 key (a recognised-but-unsupported type).
    private enum string RAGE_ECDSA_PEM =
        "-----BEGIN OPENSSH PRIVATE KEY-----\n"
        ~ "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS\n"
        ~ "1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQQQ0odKVFtwOmuCl6RXfwzExGs9dP9a\n"
        ~ "V9H5xAfETILMd7sLFgqyOxz1FA84EZV0vKdW5c0HPB7/JxQw0vFmNSWeAAAAqGOGFFJjhh\n"
        ~ "RSAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBBDSh0pUW3A6a4KX\n"
        ~ "pFd/DMTEaz10/1pX0fnEB8RMgsx3uwsWCrI7HPUUDzgRlXS8p1blzQc8Hv8nFDDS8WY1JZ\n"
        ~ "4AAAAgBQ5LA+stpdk3TYwB/4xhiOaDHzxaacv+u47ciigD8bQAAAAKc3RyNGRAY3ViZQEC\n"
        ~ "AwQFBg==\n"
        ~ "-----END OPENSSH PRIVATE KEY-----";

    // The exact 32-byte ed25519 point of the rage key (sha256(wire)[:4] = 3d85f8a3).
    private static immutable ubyte[32] RAGE_ED25519_PUB = [
        0x7b, 0x0a, 0x2e, 0xa7, 0xa9, 0x96, 0x1a, 0x56,
        0xfa, 0xe3, 0x9b, 0xcf, 0x97, 0x6f, 0x32, 0x08,
        0xf3, 0xd4, 0xec, 0x5f, 0x33, 0xf5, 0xd7, 0x50,
        0x1f, 0x95, 0x1e, 0xd6, 0x7a, 0x8a, 0xc1, 0x8d,
    ];

    // The exact 64-byte libsodium secret key (seed ‖ pub) of the rage key.
    private static immutable ubyte[64] RAGE_ED25519_SECRET = [
        0x03, 0x04, 0x9b, 0xe3, 0x65, 0x3f, 0x17, 0xe8,
        0x94, 0x49, 0x23, 0xcc, 0x55, 0xab, 0xfd, 0x5a,
        0x53, 0xc9, 0xcc, 0x56, 0x03, 0xad, 0x56, 0x79,
        0x9d, 0xc2, 0xa5, 0xb0, 0xad, 0x29, 0x57, 0x1b,
        0x7b, 0x0a, 0x2e, 0xa7, 0xa9, 0x96, 0x1a, 0x56,
        0xfa, 0xe3, 0x9b, 0xcf, 0x97, 0x6f, 0x32, 0x08,
        0xf3, 0xd4, 0xec, 0x5f, 0x33, 0xf5, 0xd7, 0x50,
        0x1f, 0x95, 0x1e, 0xd6, 0x7a, 0x8a, 0xc1, 0x8d,
    ];

    // A fresh real `ssh-keygen -t ed25519` pair (tester@sparkles), for an
    // independent round-trip against actual OpenSSH tooling output.
    private enum string FRESH_PK_LINE =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAscYI5rUkQ/L1teWEffdZ4nZdsxPaEfp+1gU4H4USzw tester@sparkles";

    private enum string FRESH_SK_PEM =
        "-----BEGIN OPENSSH PRIVATE KEY-----\n"
        ~ "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\n"
        ~ "QyNTUxOQAAACALHGCOa1JEPy9bXlhH33WeJ2XbMT2hH6ftYFOB+FEs8AAAAJheKpyYXiqc\n"
        ~ "mAAAAAtzc2gtZWQyNTUxOQAAACALHGCOa1JEPy9bXlhH33WeJ2XbMT2hH6ftYFOB+FEs8A\n"
        ~ "AAAEB5tTO9gIDfkszqfynnTKzwEr/aFRHcwwM5gsRMpI24xgscYI5rUkQ/L1teWEffdZ4n\n"
        ~ "ZdsxPaEfp+1gU4H4USzwAAAAD3Rlc3RlckBzcGFya2xlcwECAwQFBg==\n"
        ~ "-----END OPENSSH PRIVATE KEY-----";

    private static immutable ubyte[32] FRESH_ED25519_PUB = [
        0x0b, 0x1c, 0x60, 0x8e, 0x6b, 0x52, 0x44, 0x3f,
        0x2f, 0x5b, 0x5e, 0x58, 0x47, 0xdf, 0x75, 0x9e,
        0x27, 0x65, 0xdb, 0x31, 0x3d, 0xa1, 0x1f, 0xa7,
        0xed, 0x60, 0x53, 0x81, 0xf8, 0x51, 0x2c, 0xf0,
    ];
}

/// $(LREF sshReadU32) reads big-endian and advances the cursor; a short input
/// is `unexpectedEnd`.
@("age.recipients.ssh_keys.sshReadU32.bigEndianAndBounds")
@safe pure nothrow @nogc
unittest
{
    static immutable ubyte[5] raw = [0x00, 0x00, 0x00, 0x0b, 0xAA];
    const(ubyte)[] data = raw[];
    uint v;
    auto r = sshReadU32(data, v);
    assert(!r.hasError);
    assert(v == 11);
    assert(data.length == 1 && data[0] == 0xAA);

    static immutable ubyte[3] rawShort = [0x00, 0x00, 0x00];
    const(ubyte)[] tooShort = rawShort[];
    uint w;
    auto r2 = sshReadU32(tooShort, w);
    assert(r2.hasError);
    assert(r2.error.code == ParseErrorCode.unexpectedEnd);
    assert(tooShort.length == 3); // cursor untouched on failure
}

/// $(LREF sshReadString) reads a length-prefixed string and advances; a body
/// that runs past the end is `unexpectedEnd`, leaving the cursor untouched.
@("age.recipients.ssh_keys.sshReadString.lengthPrefixedAndBounds")
@safe pure nothrow @nogc
unittest
{
    // [00 00 00 03] "abc" [trailing 0xFF]
    static immutable ubyte[8] raw = [0x00, 0x00, 0x00, 0x03, 'a', 'b', 'c', 0xFF];
    const(ubyte)[] data = raw[];
    auto r = sshReadString(data);
    assert(!r.hasError);
    assert(r.value == cast(const(ubyte)[]) "abc");
    assert(data.length == 1 && data[0] == 0xFF);

    // A length that exceeds the remaining bytes.
    static immutable ubyte[6] rawBad = [0x00, 0x00, 0x00, 0x05, 'a', 'b'];
    const(ubyte)[] bad = rawBad[];
    auto r2 = sshReadString(bad);
    assert(r2.hasError);
    assert(r2.error.code == ParseErrorCode.unexpectedEnd);
    assert(bad.length == 6); // cursor untouched
}

/// $(LREF sshWritePubkey) produces the canonical 51-byte ed25519 wire form, and
/// $(LREF sshReadString) reads its two component strings back exactly.
@("age.recipients.ssh_keys.sshWritePubkey.roundTrip")
@safe
unittest
{
    auto wire = sshWritePubkey(RAGE_ED25519_PUB);
    assert(wire.length == 51);

    // [00 00 00 0b] "ssh-ed25519" ...
    assert(wire[0 .. 4] == cast(const(ubyte)[])[0, 0, 0, 11]);
    assert(wire[4 .. 15] == cast(const(ubyte)[]) "ssh-ed25519");
    assert(wire[15 .. 19] == cast(const(ubyte)[])[0, 0, 0, 32]);
    assert(wire[19 .. 51] == RAGE_ED25519_PUB[]);

    const(ubyte)[] cursor = wire;
    auto kt = sshReadString(cursor);
    assert(!kt.hasError && kt.value == cast(const(ubyte)[]) "ssh-ed25519");
    auto pk = sshReadString(cursor);
    assert(!pk.hasError && pk.value == RAGE_ED25519_PUB[]);
    assert(cursor.length == 0);
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests — authorized_keys
// ─────────────────────────────────────────────────────────────────────────────

/// A hand-built ed25519 wire pubkey, base64-padded into an `authorized_keys`
/// line, round-trips through $(LREF parseAuthorizedKeyLine) to the same 32-byte
/// point and the same 51-byte wire form $(LREF sshWritePubkey) emits.
@("age.recipients.ssh_keys.parseAuthorizedKeyLine.handBuiltRoundTrip")
@safe
unittest
{
    import sparkles.crypto.encoding.base64 : encodeBase64Padded;
    import std.array : appender;

    // Build the wire form by hand, then base64(=-padded) it as authorized_keys.
    auto wire = sshWritePubkey(RAGE_ED25519_PUB);
    auto enc = appender!string;
    encodeBase64Padded(wire, enc);
    const line = "ssh-ed25519 " ~ enc[] ~ " some@comment";

    auto r = parseAuthorizedKeyLine(line);
    assert(r.hasValue, "hand-built authorized_keys line failed to parse");
    assert(r.value.keyType == "ssh-ed25519");
    assert(r.value.ed25519Pub == RAGE_ED25519_PUB);
    assert(r.value.wirePubkey == wire);
}

/// rage's published `authorized_keys` line parses to the exact ed25519 point of
/// its test key (a real-tooling vector, not a self-constructed one).
@("age.recipients.ssh_keys.parseAuthorizedKeyLine.ragePublishedKey")
@safe
unittest
{
    auto r = parseAuthorizedKeyLine(RAGE_PK_LINE);
    assert(r.hasValue, "rage's published PK line failed to parse");
    assert(r.value.ed25519Pub == RAGE_ED25519_PUB);
    // The wire form equals what we'd serialize from the point.
    assert(r.value.wirePubkey == sshWritePubkey(RAGE_ED25519_PUB));
}

/// Surrounding whitespace and a missing comment are both tolerated.
@("age.recipients.ssh_keys.parseAuthorizedKeyLine.whitespaceAndNoComment")
@safe
unittest
{
    // Leading/trailing whitespace, no comment token.
    auto r = parseAuthorizedKeyLine(
        "  ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHsKLqeplhpW+uObz5dvMgjz1OxfM/XXUB+VHtZ6isGN  \n");
    assert(r.hasValue);
    assert(r.value.ed25519Pub == RAGE_ED25519_PUB);
}

/// A non-ed25519 key type (`ssh-rsa`) is rejected with the distinct
/// `unsupportedKeyType` reason — it is M9, not a generic parse error.
@("age.recipients.ssh_keys.parseAuthorizedKeyLine.rejectsNonEd25519")
@safe
unittest
{
    auto r = parseAuthorizedKeyLine(
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDxxx user@host");
    assert(r.hasError);
    auto reason = sshReason(r.error);
    assert(!reason.isNull);
    assert(reason.get == SshKeyParseReason.unsupportedKeyType);

    // A hardware-security-key type classifies distinctly.
    auto sk = parseAuthorizedKeyLine(
        "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAA user@host");
    assert(sk.hasError);
    auto skReason = sshReason(sk.error);
    assert(!skReason.isNull);
    assert(skReason.get == SshKeyParseReason.hardwareKey);
}

/// A truncated base64 blob (a wire form cut short of its 32-byte point) is
/// rejected as malformed — the decode succeeds but the wire read runs out.
@("age.recipients.ssh_keys.parseAuthorizedKeyLine.rejectsTruncatedBlob")
@safe
unittest
{
    import sparkles.crypto.encoding.base64 : encodeBase64Padded;
    import std.array : appender;

    // A wire form truncated to its first 30 bytes (the point is incomplete).
    auto wire = sshWritePubkey(RAGE_ED25519_PUB);
    auto enc = appender!string;
    encodeBase64Padded(wire[0 .. 30], enc);
    const line = "ssh-ed25519 " ~ enc[];

    auto r = parseAuthorizedKeyLine(line);
    assert(r.hasError, "a truncated wire blob must be rejected");
    auto reason = sshReason(r.error);
    assert(!reason.isNull && reason.get == SshKeyParseReason.malformed);
}

/// Garbage base64 / an empty blob / a lone key type are all malformed.
@("age.recipients.ssh_keys.parseAuthorizedKeyLine.rejectsGarbage")
@safe
unittest
{
    // Not valid base64 at all.
    auto a = parseAuthorizedKeyLine("ssh-ed25519 !!!notbase64!!!");
    assert(a.hasError);
    assert(sshReason(a.error).get == SshKeyParseReason.malformed);

    // No blob token.
    auto b = parseAuthorizedKeyLine("ssh-ed25519");
    assert(b.hasError);
    assert(sshReason(b.error).get == SshKeyParseReason.malformed);

    // Empty input.
    auto c = parseAuthorizedKeyLine("   ");
    assert(c.hasError);
    assert(sshReason(c.error).get == SshKeyParseReason.malformed);
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests — OpenSSH private key
// ─────────────────────────────────────────────────────────────────────────────

/// rage's published unencrypted OpenSSH ed25519 key parses to the exact 64-byte
/// libsodium secret (`seed ‖ pub`) and the matching 51-byte wire pubkey.
@("age.recipients.ssh_keys.parseOpenSshPrivateKey.ragePublishedKey")
@safe
unittest
{
    auto r = parseOpenSshPrivateKey(RAGE_SK_PEM);
    assert(r.hasValue, "rage's published OpenSSH key failed to parse");
    assert(r.value.ed25519Secret == RAGE_ED25519_SECRET);
    // priv[32..64] is the public key.
    assert(r.value.ed25519Secret[32 .. 64] == RAGE_ED25519_PUB[]);
    // The wire pubkey is the canonical 51-byte form.
    assert(r.value.wirePubkey == sshWritePubkey(RAGE_ED25519_PUB));
}

/// A second, independently generated real `ssh-keygen` key parses correctly,
/// and its parsed wire pubkey matches the public key carried in its own
/// `authorized_keys` line (the .pub file `ssh-keygen` emitted alongside it).
@("age.recipients.ssh_keys.parseOpenSshPrivateKey.freshKeygenRoundTrip")
@safe
unittest
{
    auto priv = parseOpenSshPrivateKey(FRESH_SK_PEM);
    assert(priv.hasValue, "a fresh ssh-keygen key failed to parse");
    assert(priv.value.ed25519Secret[32 .. 64] == FRESH_ED25519_PUB[]);

    auto pub = parseAuthorizedKeyLine(FRESH_PK_LINE);
    assert(pub.hasValue);
    assert(pub.value.ed25519Pub == FRESH_ED25519_PUB);

    // The private key's stored wire pubkey equals the .pub line's wire form.
    assert(priv.value.wirePubkey == pub.value.wirePubkey);
}

/// An $(B encrypted) OpenSSH key (aes256-cbc + bcrypt) is rejected with the
/// distinct `encryptedKey` reason — decrypting it is M9, not M8.
@("age.recipients.ssh_keys.parseOpenSshPrivateKey.rejectsEncryptedKey")
@safe
unittest
{
    auto r = parseOpenSshPrivateKey(RAGE_ENCRYPTED_PEM);
    assert(r.hasError, "an encrypted OpenSSH key must be rejected for M8");
    auto reason = sshReason(r.error);
    assert(!reason.isNull, "encrypted-key rejection must carry an SSH reason");
    assert(reason.get == SshKeyParseReason.encryptedKey,
        "an encrypted key must report the distinct encryptedKey reason");
}

/// A recognised-but-unsupported inner key type (ecdsa-sha2-nistp256) is
/// rejected as `unsupportedKeyType` — the container is unencrypted and
/// structurally valid, but the key is not ed25519.
@("age.recipients.ssh_keys.parseOpenSshPrivateKey.rejectsNonEd25519Inner")
@safe
unittest
{
    auto r = parseOpenSshPrivateKey(RAGE_ECDSA_PEM);
    assert(r.hasError, "a non-ed25519 inner key must be rejected");
    auto reason = sshReason(r.error);
    assert(!reason.isNull);
    assert(reason.get == SshKeyParseReason.unsupportedKeyType);
}

/// A bad PEM frame (wrong/missing markers) is malformed.
@("age.recipients.ssh_keys.parseOpenSshPrivateKey.rejectsBadFrame")
@safe
unittest
{
    // Missing the END marker.
    auto a = parseOpenSshPrivateKey(
        "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEA\n");
    assert(a.hasError);
    assert(sshReason(a.error).get == SshKeyParseReason.malformed);

    // Entirely the wrong PEM type.
    auto b = parseOpenSshPrivateKey(
        "-----BEGIN RSA PRIVATE KEY-----\nMIIB\n-----END RSA PRIVATE KEY-----");
    assert(b.hasError);
    assert(sshReason(b.error).get == SshKeyParseReason.malformed);
}

/// A corrupted private value — `priv[32..64]` flipped so it no longer matches
/// the embedded public key — is rejected as `invalidStructure`. The blob is
/// rebuilt by hand from the rage container with one byte of the private tail
/// flipped, exercising the `priv[32..64] == pub` check directly.
@("age.recipients.ssh_keys.parseOpenSshPrivateKey.rejectsMismatchedPrivTail")
@safe
unittest
{
    // Build a minimal valid unencrypted container, then corrupt priv[32..64].
    auto container = buildMinimalEd25519Container(
        RAGE_ED25519_PUB, RAGE_ED25519_SECRET, "x");

    // Sanity: the untouched container parses.
    {
        auto good = parseOpenSshContainer(container);
        assert(good.hasValue, "self-built container must parse");
        assert(good.value.ed25519Secret == RAGE_ED25519_SECRET);
    }

    // Flip one byte of the public-key tail of the 64-byte private value so the
    // `priv[32..64] == pub` invariant fails.
    ubyte[64] badSecret = RAGE_ED25519_SECRET;
    badSecret[40] ^= 0x01;
    auto bad = buildMinimalEd25519Container(RAGE_ED25519_PUB, badSecret, "x");
    auto r = parseOpenSshContainer(bad);
    assert(r.hasError, "a mismatched private tail must be rejected");
    assert(sshReason(r.error).get == SshKeyParseReason.invalidStructure);
}

/// Mismatched check-ints in the private section are `invalidStructure`.
@("age.recipients.ssh_keys.parseOpenSshPrivateKey.rejectsBadCheckInts")
@safe
unittest
{
    auto container = buildMinimalEd25519Container(
        RAGE_ED25519_PUB, RAGE_ED25519_SECRET, "x", /* breakCheckInts */ true);
    auto r = parseOpenSshContainer(container);
    assert(r.hasError);
    assert(sshReason(r.error).get == SshKeyParseReason.invalidStructure);
}

version (unittest)
{
    // Builds a minimal *unencrypted* PROTOCOL.key container (cipher/kdf = none)
    // for an ed25519 key, with deterministic 1,2,3,… padding, so the structural
    // checks can be exercised from a hand-built blob. Optionally breaks the
    // two check-ints so they differ.
    private ubyte[] buildMinimalEd25519Container(
        in ubyte[32] pub, in ubyte[64] secret, scope const(char)[] comment,
        bool breakCheckInts = false) @safe
    {
        import std.array : Appender, appender;

        void putU32(ref Appender!(ubyte[]) a, uint v)
        {
            a.put(cast(ubyte)(v >> 24));
            a.put(cast(ubyte)(v >> 16));
            a.put(cast(ubyte)(v >> 8));
            a.put(cast(ubyte) v);
        }

        void putStr(ref Appender!(ubyte[]) a, scope const(ubyte)[] s)
        {
            putU32(a, cast(uint) s.length);
            a.put(s);
        }

        // The SSH wire public key.
        auto wire = sshWritePubkey(pub);

        // The private section.
        auto priv = appender!(ubyte[]);
        putU32(priv, 0xDEAD_BEEF);
        putU32(priv, breakCheckInts ? 0xFEED_FACE : 0xDEAD_BEEF);
        putStr(priv, cast(const(ubyte)[]) SSH_ED25519_KEY_PREFIX);
        putStr(priv, pub[]);
        putStr(priv, secret[]);
        putStr(priv, cast(const(ubyte)[]) comment);
        // Deterministic padding to the next 8-byte boundary (OpenSSH uses the
        // cipher block size; 8 is the unencrypted default).
        ubyte pad = 1;
        while (priv.data.length % 8 != 0)
            priv.put(pad++);

        // The full container.
        auto c = appender!(ubyte[]);
        c.put(cast(const(ubyte)[]) OPENSSH_MAGIC);
        putStr(c, cast(const(ubyte)[]) "none");      // cipher
        putStr(c, cast(const(ubyte)[]) "none");      // kdf
        putStr(c, cast(const(ubyte)[]) "");          // kdfoptions
        putU32(c, 1);                                 // numKeys
        putStr(c, wire);                              // public key
        putStr(c, priv.data);                         // private section
        return c.data;
    }
}
