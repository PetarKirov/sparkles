/**
The age $(B identity file) parser (§10.4): the small text format that holds a
user's decryption keys, as understood by `age -i FILE` / `rage -i FILE`.

An identity file is $(B one of two shapes), and $(LREF parseIdentityFileText)
distinguishes them by content:

$(UL
    $(LI a list of $(B native age identities) — blank lines and `#` comment lines
        are skipped, and every other line is an `AGE-SECRET-KEY-1…` bech32 string
        parsed into an $(REF X25519Identity, sparkles,age,recipients,x25519); or)
    $(LI a $(B single OpenSSH private key) — an
        `-----BEGIN OPENSSH PRIVATE KEY-----` … PEM block, parsed in its entirety
        into one $(REF SshEd25519Identity, sparkles,age,recipients,ssh_ed25519).))

A file never mixes the two: `ssh-keygen` writes a private key as a standalone
PEM (with its own comment/structure that is not line-oriented), so the moment
the text opens with the OpenSSH PEM marker the whole input is handed to the SSH
parser; otherwise it is treated as age-identity lines.

This mirrors rage's identity handling, split across
`age/src/identity.rs` (`IdentityFile::parse_identities`, which loops
`x25519::Identity` per line, skipping blank/`#` lines) and the CLI's
`read_identities`/`parse_identity_files` (which detects an OpenSSH PEM and parses
the whole file as an SSH key). The §10.4 wording in `docs/specs/age/SPEC.md`
combines both into this one entry point.

$(LREF toAnyIdentities) erases the parsed file into the runtime
$(REF AnyIdentity, sparkles,age,identity) sum type the decrypt path consumes.
Because $(REF X25519Identity, sparkles,age,recipients,x25519) is non-copyable
(its scalar is a zeroizing $(REF SecretArray, sparkles,crypto,secret)), the
X25519 entries are $(I cloned) — serialized to their `AGE-SECRET-KEY-1…` string
and rebuilt from the decoded scalar — rather than copied out of the (`const`)
file.

This layer MAY use the GC: $(LREF IdentityFile) owns its identity arrays.

Copyright: © 2026, Petar Kirov
License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
Authors: Petar Kirov
*/
module sparkles.age.identity_file;

import sparkles.core_cli.text.errors :
    ParseErrorCode, ParseExpected, parseErr, parseOk;

import sparkles.age.identity : AnyIdentity;
import sparkles.age.recipients.ssh_ed25519 : SshEd25519Identity;
import sparkles.age.recipients.x25519 : X25519Identity;

@safe:

// ─────────────────────────────────────────────────────────────────────────────
// Shared constants
// ─────────────────────────────────────────────────────────────────────────────

/// The PEM marker that opens an OpenSSH private key. Its presence at the start
/// of the (whitespace-stripped) text switches the whole input to the SSH parser.
private enum string OPENSSH_PEM_BEGIN = "-----BEGIN OPENSSH PRIVATE KEY-----";

// ─────────────────────────────────────────────────────────────────────────────
// IdentityFile
// ─────────────────────────────────────────────────────────────────────────────

/**
The parsed contents of an age identity file: the native age identities and the
SSH identities it carried.

For an age-identity file $(LREF sshEd25519) is empty and $(LREF x25519) holds one
entry per `AGE-SECRET-KEY-1…` line; for an OpenSSH private key file
$(LREF x25519) is empty and $(LREF sshEd25519) holds the single parsed key. (The
two are never populated together — see the module summary.)

$(REF X25519Identity, sparkles,age,recipients,x25519) is non-copyable, but its
non-copyability does $(I not) propagate here: the entries are held by $(I slice)
($(D X25519Identity[])), and a slice is a reference (pointer + length), so
copying an `IdentityFile` aliases — never duplicates — the backing identities.
The struct is therefore an ordinary copyable value, which lets it travel through
the `ParseExpected!IdentityFile` that $(LREF parseIdentityFileText) returns. The
owned arrays are GC-managed, so the aliasing is sound.
*/
struct IdentityFile
{
    /// The native age (`AGE-SECRET-KEY-1…`) identities, in file order.
    X25519Identity[] x25519;

    /// The SSH (`ssh-ed25519`) identities, in file order (at most one for M8).
    SshEd25519Identity[] sshEd25519;
}

// ─────────────────────────────────────────────────────────────────────────────
// parseIdentityFileText
// ─────────────────────────────────────────────────────────────────────────────

/**
Parses the text of an age identity file into an $(LREF IdentityFile).

The shape is chosen by content (see the module summary):

$(UL
    $(LI if the whitespace-stripped text opens with
        `-----BEGIN OPENSSH PRIVATE KEY-----`, the $(B whole) input is parsed as a
        single $(REF SshEd25519Identity, sparkles,age,recipients,ssh_ed25519)
        (the PEM is not line-oriented, so it is never split); otherwise)
    $(LI the text is treated as age-identity lines: blank lines and lines whose
        first non-blank character is `#` are skipped, and every remaining line is
        parsed as an $(REF X25519Identity, sparkles,age,recipients,x25519)
        `AGE-SECRET-KEY-1…` string.))

Both `\n` and `\r\n` line endings are accepted. A line that is neither blank, a
comment, nor a valid age secret key — or an OpenSSH PEM the SSH parser rejects —
fails the parse, propagating the underlying
$(REF ParseError, sparkles,core_cli,text,errors). An input with no identities at
all (only blanks/comments, or empty) is an error
(`ParseErrorCode.emptyInput`), matching the "non-identity data" / empty-file
rejection in rage.

Params:
    text = the identity file's full UTF-8 text
Returns: the parsed $(LREF IdentityFile), or a `ParseError`.
*/
ParseExpected!IdentityFile parseIdentityFileText(scope const(char)[] text)
{
    alias R = IdentityFile;

    // An OpenSSH PEM is parsed whole — never line-split — so detect it first.
    if (startsWithOpenSshPem(text))
    {
        auto sk = SshEd25519Identity.parse(text);
        if (sk.hasError)
            return parseErr!R(sk.error);

        R file;
        file.sshEd25519 = [sk.value];
        return parseOk!R(file);
    }

    // Otherwise: age-identity lines. Collect one X25519Identity per non-blank,
    // non-comment line; reject the first line that is not a valid secret key.
    // The scan is index-based (rather than a borrowed line-range) so every
    // sub-slice of the `scope` input stays scope-local with no dip1000 escape.
    import core.lifetime : moveEmplace;

    X25519Identity[] ids;
    size_t pos = 0;
    while (pos < text.length)
    {
        // Carve out the next line up to (not including) the next '\n'.
        size_t nl = pos;
        while (nl < text.length && text[nl] != '\n')
            ++nl;

        // `stripAsciiWs` also drops a trailing '\r', so "\r\n" endings are handled.
        const(char)[] line = stripAsciiWs(text[pos .. nl]);
        pos = nl < text.length ? nl + 1 : text.length;

        if (line.length == 0 || line[0] == '#')
            continue;

        X25519Identity id;
        auto parsed = X25519Identity.parse(line, id);
        if (parsed.hasError)
            return parseErr!R(parsed.error);

        // Grow the owned array by one default-initialised slot, then move the
        // freshly parsed (non-copyable) identity into it. `ids[$ - 1]` is a slot
        // we exclusively own, so the byte-wise placement is sound.
        ids.length += 1;
        () @trusted { moveEmplace(id, ids[$ - 1]); }();
    }

    if (ids.length == 0)
        // No identities at all (empty file or only blanks/comments).
        return parseErr!R(ParseErrorCode.emptyInput, 0);

    R file;
    file.x25519 = ids;
    return parseOk!R(file);
}

// ─────────────────────────────────────────────────────────────────────────────
// toAnyIdentities
// ─────────────────────────────────────────────────────────────────────────────

/**
Erases the identities in `f` into the runtime
$(REF AnyIdentity, sparkles,age,identity) sum type the decrypt path consumes,
preserving file order (all X25519 entries, then all SSH entries).

Because $(REF X25519Identity, sparkles,age,recipients,x25519) is non-copyable and
`f` is taken by `in` (`const`) reference, each X25519 identity is $(I cloned) —
serialized to its `AGE-SECRET-KEY-1…` string and rebuilt from the decoded scalar
(the same round-trip the protocol tests use) — rather than moved out of the
file. The (copyable) SSH identities are copied directly.

Params:
    f = the parsed identity file
Returns: a fresh `AnyIdentity[]`, one element per identity in `f`.
*/
AnyIdentity[] toAnyIdentities(in IdentityFile f)
{
    import core.lifetime : moveEmplace;

    auto result = new AnyIdentity[f.x25519.length + f.sshEd25519.length];
    size_t i = 0;

    foreach (ref id; f.x25519)
    {
        // `cloneX25519` yields a fresh non-copyable identity; move it into the
        // sum type (a `@safe` constructor), then place that into the slot we own.
        auto any = AnyIdentity(cloneX25519(id));
        () @trusted { moveEmplace(any, result[i]); }();
        ++i;
    }

    foreach (ref id; f.sshEd25519)
    {
        // `SshEd25519Identity` is copyable (plain `ubyte[64]`/`ubyte[]` fields),
        // but `f` is `in` (const), so a whole-struct copy would try to alias the
        // const `ubyte[]` slice into a mutable one (rejected by the compiler).
        // Rebuild an unqualified value field-by-field: the secret bytes copy
        // straight across, and the (GC-owned) wire pubkey is `.dup`ed into a
        // fresh mutable array. The SumType's by-value constructor then binds.
        SshEd25519Identity mut;
        mut.ed25519Secret = id.ed25519Secret;
        mut.wirePubkey = id.wirePubkey.dup;
        auto any = AnyIdentity(mut);
        () @trusted { moveEmplace(any, result[i]); }();
        ++i;
    }

    return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// Small helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Clones a (non-copyable) $(REF X25519Identity, sparkles,age,recipients,x25519)
/// by serializing it to its `AGE-SECRET-KEY-1…` string and rebuilding from the
/// decoded scalar — the same `toString` → reparse round-trip the protocol tests
/// use to move an identity's secret into a fresh value without copying it.
private X25519Identity cloneX25519(in X25519Identity id)
{
    import std.array : appender;

    auto w = appender!(char[]);
    id.toString(w);

    X25519Identity copy;
    auto parsed = X25519Identity.parse(w[], copy);
    // The string we just produced is, by construction, a canonical
    // `AGE-SECRET-KEY-1…` value, so it must re-parse.
    assert(!parsed.hasError, "an X25519Identity did not round-trip through its own string");
    return copy;
}

/// True iff the whitespace-stripped `text` begins with the OpenSSH PEM marker.
private bool startsWithOpenSshPem(scope const(char)[] text) pure nothrow @nogc
{
    const(char)[] s = stripAsciiWs(text);
    return s.length >= OPENSSH_PEM_BEGIN.length
        && s[0 .. OPENSSH_PEM_BEGIN.length] == OPENSSH_PEM_BEGIN;
}

/// True for an ASCII whitespace byte (SP, TAB, LF, CR, VT, FF).
private bool isAsciiWs(char c) pure nothrow @nogc
    => c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f';

/// Strips leading and trailing ASCII whitespace from `s` (no allocation). A
/// trailing `\r` is ASCII whitespace, so a line carved out before a `\n` is
/// cleaned of a `\r\n`'s carriage return here too.
private const(char)[] stripAsciiWs(return scope const(char)[] s) pure nothrow @nogc
{
    size_t lo = 0, hi = s.length;
    while (lo < hi && isAsciiWs(s[lo]))
        ++lo;
    while (hi > lo && isAsciiWs(s[hi - 1]))
        --hi;
    return s[lo .. hi];
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    // rage's published X25519 test key (age/src/identity.rs `TEST_SK`).
    private enum string TEST_SK =
        "AGE-SECRET-KEY-1GQ9778VQXMMJVE8SK7J6VT8UJ4HDQAJUVSFCWCM02D8GEWQ72PVQ2Y5J33";
    private enum string TEST_PK =
        "age1t7rxyev2z3rw82stdlrrepyc39nvn86l5078zqkf5uasdy86jp6svpy7pa";

    // rage's published unencrypted OpenSSH ed25519 private key
    // (age/src/ssh/identity.rs; the matching public key is `str4d@carbon`).
    private enum string RAGE_SK_PEM =
        "-----BEGIN OPENSSH PRIVATE KEY-----\n"
        ~ "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\n"
        ~ "QyNTUxOQAAACB7Ci6nqZYaVvrjm8+XbzII89TsXzP111AflR7WeorBjQAAAJCfEwtqnxML\n"
        ~ "agAAAAtzc2gtZWQyNTUxOQAAACB7Ci6nqZYaVvrjm8+XbzII89TsXzP111AflR7WeorBjQ\n"
        ~ "AAAEADBJvjZT8X6JRJI8xVq/1aU8nMVgOtVnmdwqWwrSlXG3sKLqeplhpW+uObz5dvMgjz\n"
        ~ "1OxfM/XXUB+VHtZ6isGNAAAADHN0cjRkQGNhcmJvbgE=\n"
        ~ "-----END OPENSSH PRIVATE KEY-----";

    // The 32-byte ed25519 point of the rage SSH key (priv[32..64]).
    private static immutable ubyte[32] RAGE_SSH_PUB = [
        0x7b, 0x0a, 0x2e, 0xa7, 0xa9, 0x96, 0x1a, 0x56,
        0xfa, 0xe3, 0x9b, 0xcf, 0x97, 0x6f, 0x32, 0x08,
        0xf3, 0xd4, 0xec, 0x5f, 0x33, 0xf5, 0xd7, 0x50,
        0x1f, 0x95, 0x1e, 0xd6, 0x7a, 0x8a, 0xc1, 0x8d,
    ];
}

/// An age-identity file with a `#` comment, a blank line, and one
/// `AGE-SECRET-KEY-1…` line parses to exactly one X25519 identity (no SSH ones),
/// and that identity derives the published recipient.
@("age.identity_file.parseIdentityFileText.x25519CommentsAndBlanks")
@safe
unittest
{
    import std.array : appender;

    const text =
        "# created: 2026-06-02T00:00:00Z\n"
        ~ "# public key: " ~ TEST_PK ~ "\n"
        ~ "\n"
        ~ TEST_SK ~ "\n";

    auto f = parseIdentityFileText(text);
    assert(f.hasValue, "an age-identity file failed to parse");
    assert(f.value.x25519.length == 1, "expected exactly one X25519 identity");
    assert(f.value.sshEd25519.length == 0, "expected no SSH identities");

    // The parsed identity round-trips to the published recipient.
    auto w = appender!string;
    f.value.x25519[0].toPublic().toString(w);
    assert(w[] == TEST_PK, "the parsed identity did not derive the published recipient");
}

/// Several `AGE-SECRET-KEY-1…` lines (here two copies, interspersed with a
/// comment) all parse, and CRLF endings are accepted.
@("age.identity_file.parseIdentityFileText.multipleAndCrlf")
@safe
unittest
{
    const text =
        TEST_SK ~ "\r\n"
        ~ "# a comment in the middle\r\n"
        ~ TEST_SK ~ "\r\n";

    auto f = parseIdentityFileText(text);
    assert(f.hasValue, "a multi-line CRLF identity file failed to parse");
    assert(f.value.x25519.length == 2, "expected two X25519 identities");
    assert(f.value.sshEd25519.length == 0);
}

/// An OpenSSH private key PEM parses, as a whole, to exactly one ssh-ed25519
/// identity (no X25519 ones), and that identity carries the expected public key.
@("age.identity_file.parseIdentityFileText.opensshPemSingleSsh")
@safe
unittest
{
    auto f = parseIdentityFileText(RAGE_SK_PEM);
    assert(f.hasValue, "an OpenSSH private key file failed to parse");
    assert(f.value.x25519.length == 0, "expected no X25519 identities");
    assert(f.value.sshEd25519.length == 1, "expected exactly one SSH identity");

    // priv[32..64] is the public key.
    assert(f.value.sshEd25519[0].ed25519Secret[32 .. 64] == RAGE_SSH_PUB[],
        "the parsed SSH identity carried the wrong public key");
}

/// Surrounding whitespace before the PEM marker still routes to the SSH parser
/// (the marker is detected on the stripped text).
@("age.identity_file.parseIdentityFileText.opensshPemLeadingBlankLines")
@safe
unittest
{
    auto f = parseIdentityFileText("\n\n  " ~ RAGE_SK_PEM ~ "\n");
    assert(f.hasValue, "an OpenSSH key with leading blank lines failed to parse");
    assert(f.value.sshEd25519.length == 1);
    assert(f.value.x25519.length == 0);
}

/// $(LREF toAnyIdentities) yields the right `AnyIdentity` variants, in file
/// order: an X25519 entry erases to the `X25519Identity` member and an SSH entry
/// to the `SshEd25519Identity` member.
@("age.identity_file.toAnyIdentities.variants")
@safe
unittest
{
    import std.sumtype : match;

    // An age-identity file → one X25519 AnyIdentity.
    {
        auto f = parseIdentityFileText(TEST_SK ~ "\n");
        assert(f.hasValue);
        auto anys = toAnyIdentities(f.value);
        assert(anys.length == 1);
        const isX25519 = anys[0].match!((ref active) {
            alias A = typeof(active);
            return is(A == X25519Identity);
        });
        assert(isX25519, "an AGE-SECRET-KEY identity must erase to X25519Identity");
    }

    // An OpenSSH key file → one ssh-ed25519 AnyIdentity.
    {
        auto f = parseIdentityFileText(RAGE_SK_PEM);
        assert(f.hasValue);
        auto anys = toAnyIdentities(f.value);
        assert(anys.length == 1);
        const isSsh = anys[0].match!((ref active) {
            alias A = typeof(active);
            return is(A == SshEd25519Identity);
        });
        assert(isSsh, "an OpenSSH identity must erase to SshEd25519Identity");
    }
}

/// A cloned X25519 identity (the round-trip $(LREF toAnyIdentities) performs)
/// can still unwrap a stanza wrapped for its own recipient — the clone preserves
/// the secret scalar, not just the public half.
@("age.identity_file.toAnyIdentities.x25519CloneStillUnwraps")
@safe
unittest
{
    import sparkles.age.identity : unwrapStanza;
    import sparkles.age.keys : FileKey;

    auto f = parseIdentityFileText(TEST_SK ~ "\n");
    assert(f.hasValue);

    // Wrap a fixed file key for the file's recipient.
    static immutable ubyte[16] raw = [
        9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 1, 2, 3, 4, 5, 6,
    ];
    auto fileKey = FileKey.fromBytes(raw);
    auto wrapped = f.value.x25519[0].toPublic().wrapFileKey(fileKey);
    assert(wrapped.hasValue);

    // The erased (cloned) identity unwraps it back to the same bytes.
    auto anys = toAnyIdentities(f.value);
    assert(anys.length == 1);
    FileKey recovered;
    auto outcome = unwrapStanza(anys[0], wrapped.value.stanzas[0], recovered);
    assert(!outcome.isNull, "the cloned identity did not recognise its own stanza");
    assert(!outcome.get.hasError, "the cloned identity failed to unwrap");
    assert(recovered.exposeSecret() == raw[], "the unwrapped file key did not match");
}

/// A file with no identities (empty, or only blanks and comments) is rejected as
/// `emptyInput`.
@("age.identity_file.parseIdentityFileText.rejectsNoIdentities")
@safe
unittest
{
    // Entirely empty.
    {
        auto f = parseIdentityFileText("");
        assert(f.hasError);
        assert(f.error.code == ParseErrorCode.emptyInput);
    }

    // Only comments and blank lines.
    {
        auto f = parseIdentityFileText("# just a comment\n\n#another\n");
        assert(f.hasError);
        assert(f.error.code == ParseErrorCode.emptyInput);
    }
}

/// A non-identity, non-comment line (here a recipient `age1…` string fed where a
/// secret key is required) fails the parse rather than being silently skipped.
@("age.identity_file.parseIdentityFileText.rejectsNonIdentityLine")
@safe
unittest
{
    auto f = parseIdentityFileText(TEST_PK ~ "\n");
    assert(f.hasError, "a recipient string is not a valid identity line");
}
