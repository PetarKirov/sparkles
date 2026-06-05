/**
The age testkit conformance driver (§12) — runs all 114 official vectors.

The vendored testkit lives under `libs/age/tests/testkit/<name>` (resolved through
`stringImportPaths "tests"` in `libs/age/dub.sdl`); the vector names are listed in
$(REF testkitVectorNames, sparkles,age,testkit_vectors). This module string-imports
each vector body at compile time and generates one `@("testkit.<name>")` unittest per
vector via a `static foreach`.

# Vector file format

Each file is a sequence of header lines, then $(B one) blank line, then the raw binary
age file (which may itself be ASCII-armored). The header lines, each `prefix: value`,
are (any subset, any order):

$(UL
    $(LI `expect:` — `success` / `header failure` / `HMAC failure` / `armor failure` /
        `no match` / `payload failure`;)
    $(LI `payload:` — hex SHA-256 of the expected plaintext (success / payload-failure);)
    $(LI `file key:` — hex 16-byte file key (informational, ignored here);)
    $(LI `identity:` — an `AGE-SECRET-KEY-1…` X25519 identity (0..N lines);)
    $(LI `passphrase:` — a scrypt passphrase (mutually exclusive with `identity:`,
        except the deliberately-malformed `scrypt_and_x25519` / `scrypt_uppercase`
        vectors);)
    $(LI `armored:` — `yes` if the body is ASCII-armored;)
    $(LI `comment:` — free text.))

The blank-line separator is the $(B first) empty line; everything after it (to EOF) is
the binary age payload, preserved byte-for-byte (it may contain CR / LF / NUL).

# Outcome mapping

This driver is a faithful port of rage's `age/tests/testkit.rs` harness — both the
decrypt flow (sniff/strip armor → $(REF Decryptor.parse, sparkles,age,protocol) →
$(REF Decryptor.decrypt, sparkles,age,protocol), choosing the scrypt-vs-X25519 path by
$(REF Decryptor.isScrypt, sparkles,age,protocol), $(B not) by which key the file
carries) and the expectation check (`check_decrypt_success` / `check_decrypt_error`),
including its documented special cases:

$(UL
    $(LI the legacy `stanza_missing_body` / `stanza_missing_final_line` vectors are
        declared `header failure` upstream but our parser deliberately tolerates the
        missing-final-line stanza body, so they decrypt to `success` — accepted;)
    $(LI four armored vectors with a $(I broken begin marker)
        (`armor_garbage_leading`, `armor_lowercase`, `armor_whitespace_begin`,
        `armor_wrong_type`) are declared `armor failure`, but de-armoring never starts
        so they surface as a header failure — accepted as the armor failure they are;)
    $(LI `armor_whitespace_outside` is declared `success` upstream but rage (and we)
        cannot sniff armor behind leading non-LF whitespace, so a header failure is
        accepted.))

The error-code → outcome map (our $(REF DecryptErrorCode, sparkles,age,errors) →
testkit `Expect`) is:

$(UL
    $(LI `invalidHeader` / `unknownFormat` / `excessiveWork` → header failure;)
    $(LI `invalidMac` → HMAC failure;)
    $(LI `decryptionFailed` / `noMatchingKeys` → no match;)
    $(LI `truncatedPayload` / `payloadError` → payload failure;)
    $(LI an $(REF ArmorError, sparkles,age,errors) from de-armoring → armor failure.))

Conventions: each generated unittest is `@safe`; the driver MAY use the GC (the
decoded armor, the recovered plaintext, the diagnostic strings). On a mismatch a
descriptive `AssertError` naming the vector plus the expected-vs-actual outcome is
thrown.

See `docs/specs/age/SPEC.md` §12 and rage's `age/tests/testkit.rs`.

Copyright: © 2026, Petar Kirov
License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
Authors: Petar Kirov
*/
module sparkles.age.testkit_runner;

version (unittest):

import sparkles.age.identity : AnyIdentity;
import sparkles.age.protocol : Decryptor;
import sparkles.age.testkit_vectors : testkitVectorNames;

@safe:

// ─────────────────────────────────────────────────────────────────────────────
// Parsed vector
// ─────────────────────────────────────────────────────────────────────────────

/// The testkit `expect:` outcomes — the verdict a vector asserts.
enum Expect
{
    /// `expect: success` — parse + decrypt OK and sha256(plaintext) == payload.
    success,
    /// `expect: header failure` — the header was rejected (parse / structure /
    /// excessive work). rage groups some malformed-header cases here.
    headerFailure,
    /// `expect: HMAC failure` — the header MAC did not verify.
    hmacFailure,
    /// `expect: armor failure` — ASCII-armor de-wrap failed.
    armorFailure,
    /// `expect: no match` — no identity / passphrase could unwrap the file key.
    noMatch,
    /// `expect: payload failure` — header + MAC OK but the STREAM payload was
    /// truncated or corrupt.
    payloadFailure,
}

/**
A parsed testkit vector: the `expect:` verdict, the (optional) expected-plaintext
hash, the X25519 identity strings, the scrypt passphrase, whether the body is
armored, and the raw binary age `body_`.

`body_` is the slice after the first blank line (everything to EOF), preserved
byte-for-byte. `hasPayload` distinguishes "no `payload:` line" (e.g. an armor /
header failure) from an all-zero hash.
*/
struct Vector
{
    /// The asserted outcome (`expect:` field).
    Expect expect;
    /// SHA-256 of the expected plaintext (only meaningful when `hasPayload`).
    ubyte[32] payloadHash;
    /// Whether a `payload:` line was present (success / payload-failure vectors).
    bool hasPayload;
    /// The `identity:` X25519 secret-key strings, in file order (0..N).
    string[] identities;
    /// The `passphrase:` string, or empty if none.
    string passphrase;
    /// Whether the body is ASCII-armored (`armored: yes`).
    bool armored;
    /// The raw binary age file: everything after the first blank line.
    const(ubyte)[] body_;
}

// ─────────────────────────────────────────────────────────────────────────────
// Parsing
// ─────────────────────────────────────────────────────────────────────────────

/**
Parses a vector blob into a $(LREF Vector).

Splits at the $(B first) blank line: the bytes before it are header lines
(`prefix: value`, dispatched by prefix regardless of order), and the bytes after it
(to EOF) are the binary age `body_`, preserved exactly. The `name` is used only to
make a parse error (a missing blank line, an unknown `expect:`, a bad `payload:`
hex) descriptive.

Header-line handling mirrors rage's `TestFile::parse`: a line is split at its first
`": "`; `identity` lines accumulate; `armored` is true iff its value is `"yes"`;
`expect` / `payload` are parsed into $(LREF Vector.expect) / $(LREF Vector.payloadHash).
A header line with no `": "` (other than the `expect:` / `file key:` forms, which do
have one) is ignored rather than rejected, keeping the parser tolerant of future
metadata.
*/
Vector parseVector(string name, const(ubyte)[] blob)
{
    import core.exception : AssertError;

    Vector v;

    // ── 1. Locate the first blank line (the header/body separator). ───────────
    // A "blank line" is an LF immediately following an LF (an empty line), or a
    // leading LF (an empty first line — not expected, but handled). We scan for
    // the first "\n\n" boundary; the body begins right after it.
    size_t sep = size_t.max;
    foreach (i; 0 .. blob.length)
    {
        if (blob[i] == '\n')
        {
            // The line that just ended started at `lineStart`; if the next byte
            // is also '\n' (or we are at a position where the *current* line was
            // empty) we found the separator.
            if (i + 1 < blob.length && blob[i + 1] == '\n')
            {
                sep = i + 1; // the empty line's LF
                break;
            }
        }
    }
    if (sep == size_t.max)
        throw new AssertError(
            "testkit vector '" ~ name ~ "': no blank-line header/body separator");

    const headerBytes = blob[0 .. sep]; // header lines, up to (not incl.) blank LF
    v.body_ = blob[sep + 1 .. $];        // everything after the blank LF

    // ── 2. Parse the header lines. ────────────────────────────────────────────
    bool sawExpect = false;
    foreach (line; lineSplit(cast(const(char)[]) headerBytes))
    {
        if (line.length == 0)
            continue;

        // Split at the first ": " — the testkit's prefix/value delimiter.
        const colon = indexOfColonSpace(line);
        if (colon == size_t.max)
            continue; // tolerate a stray line with no "prefix: value" shape.

        const prefix = line[0 .. colon];
        const value = line[colon + 2 .. $];

        switch (prefix)
        {
        case "expect":
            v.expect = parseExpect(name, value);
            sawExpect = true;
            break;
        case "payload":
            decodeHash(name, value, v.payloadHash);
            v.hasPayload = true;
            break;
        case "file key":
            break; // informational only.
        case "identity":
            v.identities ~= value.idup;
            break;
        case "passphrase":
            v.passphrase = value.idup;
            break;
        case "armored":
            v.armored = value == "yes";
            break;
        case "comment":
            break;
        default:
            break; // unknown metadata — ignore (forward-compatible).
        }
    }

    if (!sawExpect)
        throw new AssertError(
            "testkit vector '" ~ name ~ "': missing 'expect:' line");

    return v;
}

/// Maps an `expect:` value to an $(LREF Expect). Throws a descriptive
/// `AssertError` on an unknown value.
private Expect parseExpect(string name, const(char)[] value)
{
    import core.exception : AssertError;

    switch (value)
    {
    case "success":
        return Expect.success;
    case "header failure":
        return Expect.headerFailure;
    case "HMAC failure":
        return Expect.hmacFailure;
    case "armor failure":
        return Expect.armorFailure;
    case "no match":
        return Expect.noMatch;
    case "payload failure":
        return Expect.payloadFailure;
    default:
        throw new AssertError(
            "testkit vector '" ~ name ~ "': unknown expect value '" ~ value.idup ~ "'");
    }
}

/// Decodes a 32-byte SHA-256 hex hash into `out_`. Throws on a malformed hash.
private void decodeHash(string name, const(char)[] hex, ref ubyte[32] out_)
{
    import core.exception : AssertError;
    import sparkles.crypto.encoding.hex : decodeHex, hexMaxDecodedLength;

    ubyte[hexMaxDecodedLength(64)] buf = void;
    if (hex.length > 64)
        throw new AssertError(
            "testkit vector '" ~ name ~ "': payload hash too long");
    auto r = decodeHex(hex, buf[0 .. hexMaxDecodedLength(hex.length)]);
    if (!r.hasValue || r.value.length != 32)
        throw new AssertError(
            "testkit vector '" ~ name ~ "': payload hash is not 32 hex bytes");
    out_[] = r.value[0 .. 32];
}

/// Returns the index of the first `": "` (colon followed by space) in `line`, or
/// `size_t.max` if absent.
private size_t indexOfColonSpace(const(char)[] line) @safe pure nothrow @nogc
{
    foreach (i; 0 .. line.length)
        if (line[i] == ':' && i + 1 < line.length && line[i + 1] == ' ')
            return i;
    return size_t.max;
}

/**
Lazily splits `text` into LF-delimited lines, dropping a single trailing CR from
each line (so a CRLF-terminated header line yields the same token as an LF one).

The testkit's header section uses LF endings, but tolerating a trailing CR keeps the
parser robust; the body bytes (after the separator) are never touched by this.
*/
private auto lineSplit(const(char)[] text) @safe pure nothrow
{
    import std.algorithm.iteration : map, splitter;

    return text.splitter('\n').map!((const(char)[] l) =>
        l.length > 0 && l[$ - 1] == '\r' ? l[0 .. $ - 1] : l);
}

// ─────────────────────────────────────────────────────────────────────────────
// Running a vector
// ─────────────────────────────────────────────────────────────────────────────

/// The concrete outcome of attempting to decrypt a vector — the runtime analogue
/// of $(LREF Expect), produced by $(LREF runVector) and compared against the
/// vector's declared $(LREF Vector.expect) by $(LREF checkVector).
struct Outcome
{
    /// The category this attempt fell into.
    Expect kind;
    /// The recovered plaintext (only when `kind == Expect.success`).
    const(ubyte)[] plaintext;
}

/**
Runs the decrypt flow for a parsed `v`, mirroring rage's `testkit` body.

For an armored body, de-armors first (an $(REF ArmorError, sparkles,age,errors) →
$(LREF Expect.armorFailure)); a body that does not even sniff as armored is passed
through raw (rage's `ArmoredReader` does the same — it only de-armors when it sees
the begin marker, otherwise the inner header parser rejects the armor text as a
header failure). It then $(REF Decryptor.parse, sparkles,age,protocol)s, chooses the
scrypt-vs-X25519 identity path by
$(REF Decryptor.isScrypt, sparkles,age,protocol) (so `scrypt_uppercase`, whose tag is
`Scrypt`, takes the X25519 path and finds no match — exactly as upstream), and
decrypts, classifying any $(REF DecryptError, sparkles,age,errors) per the module's
outcome map.
*/
Outcome runVector(in Vector v)
{
    import sparkles.age.armor : armorDecode, looksArmored;

    const(ubyte)[] binary = v.body_;

    if (v.armored)
    {
        const text = cast(const(char)[]) v.body_;
        if (looksArmored(text))
        {
            auto decoded = armorDecode(text);
            if (!decoded.hasValue)
                return Outcome(Expect.armorFailure);
            binary = decoded.value;
        }
        // else: the begin marker did not sniff (a broken / hidden marker). Fall
        // through with the raw bytes — the header parser will reject them, which
        // `checkVector` maps via the upstream armored-begin-marker special cases.
    }

    return decryptBinary(v, binary);
}

/// Parses `binary`, then decrypts using the path
/// $(REF Decryptor.isScrypt, sparkles,age,protocol) selects, classifying the result.
private Outcome decryptBinary(in Vector v, scope const(ubyte)[] binary)
{
    auto dec = Decryptor.parse(binary);
    if (!dec.hasValue)
        return classifyDecryptError(dec.error);

    // Bind to a local lvalue: `Decryptor.decrypt` cannot be called on the
    // `Expected.value` temporary directly. The local is `scope` because the
    // `Decryptor` borrows a view of the (scope) `binary` ciphertext.
    scope Decryptor decryptor = dec.value;
    if (decryptor.isScrypt)
        return decryptWithPassphrase(v, decryptor);
    return decryptWithIdentities(v, decryptor);
}

/// Decrypts a passphrase (scrypt) file. Caps the work factor at 16, matching
/// rage's `identity.set_max_work_factor(16)`.
private Outcome decryptWithPassphrase(in Vector v, scope ref Decryptor decryptor)
{
    import sparkles.age.identity : AnyIdentity;
    import sparkles.age.recipients.scrypt : ScryptIdentity;

    // The testkit guarantees exactly one passphrase for a real scrypt file. (A
    // missing one would be a malformed vector; the empty passphrase below would
    // then simply fail to unwrap, which still surfaces as a decrypt error.)
    AnyIdentity[1] identities = [AnyIdentity(ScryptIdentity(v.passphrase, /*maxWorkFactor*/ 16))];
    auto pt = decryptor.decrypt(identities[]);
    return classifyDecryptResult(pt);
}

/// Decrypts an X25519 file using every `identity:` string in the vector.
private Outcome decryptWithIdentities(in Vector v, scope ref Decryptor decryptor)
{
    import core.exception : AssertError;
    import core.lifetime : move;
    import sparkles.age.recipients.x25519 : X25519Identity;

    auto identities = new AnyIdentity[v.identities.length];
    foreach (i, idStr; v.identities)
    {
        X25519Identity id;
        auto parsed = X25519Identity.parse(idStr, id);
        if (parsed.hasError)
            throw new AssertError(
                "testkit identity failed to parse: " ~ idStr);
        // Move-construct the sum-type element in place. `SumType.opAssign` over a
        // member type holding indirections is `@system` (a documented Phobos
        // workaround), whereas move-constructing an `AnyIdentity` from one of its
        // members goes through the `@safe` constructor. `X25519Identity` is
        // non-copyable (`@disable this(this)`), so the identity is `move`d into
        // the `AnyIdentity`; `&identities[i]` points into a freshly heap-allocated,
        // default-initialised array element that we own, so the placement is safe.
        placeIdentity(&identities[i], AnyIdentity(move(id)));
    }

    auto pt = decryptor.decrypt(identities[]);
    return classifyDecryptResult(pt);
}

/// Move-constructs `src` into the default-initialised slot at `dst`. Wraps the
/// raw placement (a byte-wise move) in `@trusted` because `*dst` is a slot we own
/// (a fresh array element) and `SumType`'s elaborate `opAssign` is `@system` for
/// member types with indirections (see $(LREF decryptWithIdentities)).
private void placeIdentity(AnyIdentity* dst, AnyIdentity src) @trusted
{
    import core.lifetime : moveEmplace;

    moveEmplace(src, *dst);
}

/// Maps a $(REF DecryptExpected, sparkles,age,errors)`!(ubyte[])` to an
/// $(LREF Outcome): a value is a success carrying the plaintext; an error is
/// classified by $(LREF classifyDecryptError).
private Outcome classifyDecryptResult(R)(R result)
{
    if (result.hasValue)
        return Outcome(Expect.success, result.value);
    return classifyDecryptError(result.error);
}

/// Maps a $(REF DecryptError, sparkles,age,errors) to the testkit $(LREF Expect)
/// category, exactly as rage's `check_decrypt_error` does.
private Outcome classifyDecryptError(E)(E error)
{
    import sparkles.age.errors : DecryptErrorCode;

    final switch (error.code)
    {
    case DecryptErrorCode.invalidHeader:
    case DecryptErrorCode.unknownFormat:
    case DecryptErrorCode.excessiveWork:
        return Outcome(Expect.headerFailure);
    case DecryptErrorCode.invalidMac:
        return Outcome(Expect.hmacFailure);
    case DecryptErrorCode.decryptionFailed:
    case DecryptErrorCode.noMatchingKeys:
        return Outcome(Expect.noMatch);
    case DecryptErrorCode.truncatedPayload:
    case DecryptErrorCode.payloadError:
        return Outcome(Expect.payloadFailure);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Checking a vector against its expectation
// ─────────────────────────────────────────────────────────────────────────────

/**
Asserts the $(LREF Outcome) of running `v` matches its declared
$(LREF Vector.expect), throwing a descriptive `AssertError` (naming `name` and the
expected-vs-actual outcome) on a mismatch.

Replicates rage's `check_decrypt_success` / `check_decrypt_error` acceptance,
including the documented special cases (see the module summary):

$(UL
    $(LI a `success` outcome additionally requires `sha256(plaintext) == payloadHash`;)
    $(LI the legacy `stanza_missing_body` / `stanza_missing_final_line` vectors are
        declared `header failure` but our tolerant parser decrypts them — `success`
        is accepted;)
    $(LI the broken-begin-marker armored vectors and `armor_whitespace_outside`
        surface as `header failure` rather than their declared `armor failure` /
        `success`, because de-armoring never starts — accepted.))
*/
void checkVector(string name, in Vector v, in Outcome got)
{
    import core.exception : AssertError;

    // A genuine success must also match the expected plaintext hash.
    if (got.kind == Expect.success && v.expect == Expect.success)
    {
        assertPayloadMatches(name, v, got.plaintext);
        return;
    }

    if (got.kind == v.expect)
    {
        // For a payload-failure the spec also fixes the (partial) plaintext that
        // must have been emitted before the failure; our one-shot decrypt does
        // not surface partial output, so we follow rage's looser path and accept
        // the category match alone.
        return;
    }

    // ── rage's documented special cases ──────────────────────────────────────

    // (a) The legacy missing-final-line stanza bodies: declared `header failure`
    //     upstream, but our parser (like rage's `legacy_age_stanza`) tolerates
    //     them, so they decrypt. rage's `check_decrypt_success` accepts the
    //     `(Ok(_), HeaderFailure)` pair for exactly these two filenames *without*
    //     checking a payload hash (these vectors carry no `payload:` line), so we
    //     accept the success category alone — matching upstream's empty arm.
    if (v.expect == Expect.headerFailure && got.kind == Expect.success
        && (name == "stanza_missing_body" || name == "stanza_missing_final_line"))
        return;

    // (b) Armored vectors whose begin marker is broken: de-armoring never starts,
    //     so the raw armor text reaches the header parser → header failure. rage
    //     hard-codes these as the armor failures they really are.
    if (got.kind == Expect.headerFailure
        && (name == "armor_garbage_leading" || name == "armor_lowercase"
            || name == "armor_whitespace_begin" || name == "armor_wrong_type"))
    {
        // Their declared expectation is `armor failure`; accept the header-failure
        // surfacing as equivalent.
        if (v.expect == Expect.armorFailure)
            return;
    }

    // (c) `armor_whitespace_outside`: declared `success`, but leading non-LF
    //     whitespace defeats armor sniffing, so a header failure is expected and
    //     accepted (rage tolerates the same).
    if (name == "armor_whitespace_outside" && got.kind == Expect.headerFailure)
        return;

    throw new AssertError(
        "testkit vector '" ~ name ~ "': expected " ~ expectName(v.expect)
        ~ ", got " ~ expectName(got.kind));
}

/// Asserts `sha256(plaintext) == v.payloadHash`, throwing a descriptive
/// `AssertError` on a mismatch (or a missing `payload:` line).
private void assertPayloadMatches(string name, in Vector v, scope const(ubyte)[] plaintext)
{
    import core.exception : AssertError;
    import sparkles.crypto.hash : sha256;

    if (!v.hasPayload)
        throw new AssertError(
            "testkit vector '" ~ name ~ "': success outcome but no payload hash to check");

    ubyte[32] digest = void;
    sha256(plaintext, digest);
    if (digest != v.payloadHash)
        throw new AssertError(
            "testkit vector '" ~ name ~ "': plaintext sha256 mismatch (expected "
            ~ hexString(v.payloadHash) ~ ", got " ~ hexString(digest) ~ ")");
}

/// Renders a byte slice as a lowercase hex string (for diagnostic messages).
private string hexString(scope const(ubyte)[] bytes)
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;
    import sparkles.crypto.encoding.hex : encodeHex;

    SmallBuffer!(char, 128) buf;
    encodeHex(bytes, buf);
    return buf[].idup;
}

/// A human-readable name for an $(LREF Expect) (for diagnostic messages).
private string expectName(Expect e) @safe pure nothrow @nogc
{
    final switch (e)
    {
    case Expect.success:
        return "success";
    case Expect.headerFailure:
        return "header failure";
    case Expect.hmacFailure:
        return "HMAC failure";
    case Expect.armorFailure:
        return "armor failure";
    case Expect.noMatch:
        return "no match";
    case Expect.payloadFailure:
        return "payload failure";
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// The generated conformance tests
// ─────────────────────────────────────────────────────────────────────────────

static foreach (name; testkitVectorNames)
{
    @("testkit." ~ name)
    @safe
    unittest
    {
        // String-import the vector body at compile time (resolved through
        // `stringImportPaths "tests"`), then parse → run → check at runtime.
        enum string blob = import("testkit/" ~ name);
        const v = parseVector(name, cast(const(ubyte)[]) blob);
        const got = runVector(v);
        checkVector(name, v, got);
    }
}
