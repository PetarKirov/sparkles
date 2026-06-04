/**
The age ASCII-armor format (§7.6) — strict PEM (RFC 7468, Section 3) with the
case-sensitive label `AGE ENCRYPTED FILE` and `=`-padded standard base64
wrapped at 64 columns.

This is a faithful port of rage's `age/src/primitives/armor.rs`
(`ArmoredWriter` / `ArmoredReader`), collapsed to two one-shot helpers plus a
sniffer:

$(UL
    $(LI $(LREF armorEncode) — writes the begin marker, the `=`-padded base64
        body wrapped at exactly 64 columns, and the end marker, all with LF
        line endings, into a caller output range.)
    $(LI $(LREF armorDecode) — strictly parses an armored block back to the raw
        age bytes, rejecting every malleability vector age cares about
        (§7.6).)
    $(LI $(LREF looksArmored) — sniffs whether a buffer is armored, used by the
        simple decrypt API to strip armor transparently.)
)

Unlike the rest of the wire format, armor uses **`=`-padded** base64 (RFC 4648
§4), so the body is encoded with
$(REF encodeBase64Padded, sparkles,crypto,encoding,base64) and decoded with
$(REF decodeBase64Padded, sparkles,crypto,encoding,base64).

Decoding is **strict**: CRLF (`\r\n`) is accepted as a line terminator, but a CR
that is not the trailing CR of a CRLF terminator (i.e. embedded in line content)
is rejected ($(LREF ArmorErrorCode.crlf)); every base64 line but the last MUST be exactly
64 columns ($(LREF ArmorErrorCode.longLine)); the base64 MUST be canonical
($(LREF ArmorErrorCode.nonCanonical)); non-whitespace before the begin marker
or after the end marker is rejected ($(LREF ArmorErrorCode.trailingGarbage));
a missing end marker is $(LREF ArmorErrorCode.missingEndMarker); a truncated
begin marker is $(LREF ArmorErrorCode.unexpectedEof). Whitespace around the
PEM block is allowed.

This layer MAY use the GC: $(LREF armorDecode) returns a freshly-allocated
`ubyte[]`. See `docs/specs/age/SPEC.md` §7.6.
*/
module sparkles.age.armor;

import sparkles.age.errors :
    ArmorError, ArmorErrorCode, ArmorExpected, armorErr, armorOk;
import sparkles.crypto.encoding.base64 :
    base64MaxDecodedLength, decodeBase64Padded, encodeBase64Padded;

@safe:

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

/// The PEM begin marker for an armored age file (RFC 7468 label
/// `AGE ENCRYPTED FILE`).
enum string ARMOR_BEGIN = "-----BEGIN AGE ENCRYPTED FILE-----";

/// The PEM end marker for an armored age file.
enum string ARMOR_END = "-----END AGE ENCRYPTED FILE-----";

/// Columns of base64 per body line. The body is wrapped at exactly this many
/// characters; only the final line may be shorter.
private enum size_t COLUMNS_PER_LINE = 64;

/// Raw bytes that a full 64-column base64 line encodes (`64 / 4 * 3`).
private enum size_t BYTES_PER_LINE = COLUMNS_PER_LINE / 4 * 3;

// ─────────────────────────────────────────────────────────────────────────────
// Encoding
// ─────────────────────────────────────────────────────────────────────────────

/**
Writes `data` as an armored age block into the output range `w`.

The output is the begin marker, the `=`-padded standard base64 of `data`
wrapped at exactly 64 columns (only the final line shorter), and the end
marker — every line, including the markers, terminated by a single LF
(`0x0A`), exactly as rage's `ArmoredWriter` emits on a Unix platform.

A zero-length `data` produces just the two markers (and an empty body), which
round-trips back to the empty slice.

Params:
    data = the raw age bytes to armor.
    w    = an output range accepting `char` / `const(char)[]`.
*/
void armorEncode(Writer)(scope const(ubyte)[] data, ref Writer w)
{
    w.put(ARMOR_BEGIN);
    w.put('\n');

    // Wrap the padded base64 at 64 columns. We feed BYTES_PER_LINE (48) raw
    // bytes per line, which encodes to exactly 64 base64 chars, then a LF.
    // The final group of < 48 bytes yields the (possibly shorter) last line.
    // Encoding each line independently is valid because 48 is a multiple of 3,
    // so no padding ever appears except on the final, short line.
    size_t i = 0;
    for (; i + BYTES_PER_LINE <= data.length; i += BYTES_PER_LINE)
    {
        encodeBase64Padded(data[i .. i + BYTES_PER_LINE], w);
        w.put('\n');
    }
    // Final (possibly empty) line: the remaining 1 .. 47 bytes, or nothing.
    // rage always emits a trailing newline after the last body line, even when
    // it is empty, so the end marker is on its own line.
    encodeBase64Padded(data[i .. $], w);
    w.put('\n');

    w.put(ARMOR_END);
    w.put('\n');
}

///
@("age.armor.armorEncode.basic")
@safe unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    // base64's encoder is hard-`@nogc`, so the armor writer must be a
    // `@nogc`-compatible output range (a `SmallBuffer`, not an `Appender`).
    SmallBuffer!(char, 256) w;
    armorEncode(cast(const(ubyte)[]) "hello age", w);

    assert(w[] ==
        "-----BEGIN AGE ENCRYPTED FILE-----\n"
        ~ "aGVsbG8gYWdl\n"
        ~ "-----END AGE ENCRYPTED FILE-----\n");
}

@("age.armor.armorEncode.empty")
@safe unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 128) w;
    armorEncode(null, w);

    // Empty body: begin marker, an empty body line, end marker.
    assert(w[] ==
        "-----BEGIN AGE ENCRYPTED FILE-----\n"
        ~ "\n"
        ~ "-----END AGE ENCRYPTED FILE-----\n");
}

@("age.armor.armorEncode.wrapsAt64Columns")
@safe unittest
{
    import std.algorithm.iteration : splitter;
    import std.array : array;
    import std.range : drop, dropBack;
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    // 48 bytes -> exactly one 64-column line; 49 bytes -> a 64-column line plus
    // a short final line. Use 100 bytes: 64 + 36 columns over two body lines.
    ubyte[100] data = void;
    foreach (i; 0 .. data.length)
        data[i] = cast(ubyte) i;

    SmallBuffer!(char, 256) w;
    armorEncode(data[], w);

    auto lines = w[].idup.splitter('\n').array;
    // lines: [BEGIN, body0(64), body1(36), END, ""(trailing after final LF)]
    assert(lines[0] == ARMOR_BEGIN);
    assert(lines[$ - 2] == ARMOR_END);

    // Every body line except the last must be exactly 64 columns; the last may
    // be shorter. Body lines are everything between the markers.
    auto body_ = lines.drop(1).dropBack(2); // drop BEGIN; drop END + trailing ""
    foreach (idx, line; body_)
    {
        if (idx + 1 < body_.length)
            assert(line.length == 64);
        else
            assert(line.length <= 64);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sniffing
// ─────────────────────────────────────────────────────────────────────────────

/**
Returns `true` if `text` looks like an armored age file: after skipping any
leading ASCII whitespace, it begins with $(LREF ARMOR_BEGIN).

Used by the simple decrypt API to decide whether to strip armor before
parsing the binary header. A binary age file (`age-encryption.org/v1…`) is
never mistaken for armor.
*/
bool looksArmored(scope const(char)[] text) @safe pure nothrow @nogc
{
    size_t i = 0;
    while (i < text.length && isAsciiWhitespace(text[i]))
        i++;
    const rest = text[i .. $];
    return rest.length >= ARMOR_BEGIN.length
        && rest[0 .. ARMOR_BEGIN.length] == ARMOR_BEGIN;
}

@("age.armor.looksArmored.true")
@safe pure nothrow @nogc
unittest
{
    assert(looksArmored(ARMOR_BEGIN ~ "\nbody\n" ~ ARMOR_END ~ "\n"));
    // Leading whitespace is tolerated.
    assert(looksArmored("  \n\t" ~ ARMOR_BEGIN ~ "\n"));
}

@("age.armor.looksArmored.false")
@safe pure nothrow @nogc
unittest
{
    // A binary age header is not armored.
    assert(!looksArmored("age-encryption.org/v1\n-> X25519 abc\n"));
    // Arbitrary binary.
    assert(!looksArmored(cast(const(char)[]) "\x00\x01\x02\x03"));
    // Too short to contain the marker.
    assert(!looksArmored("-----BEGIN"));
    assert(!looksArmored(""));
}

// ─────────────────────────────────────────────────────────────────────────────
// Decoding
// ─────────────────────────────────────────────────────────────────────────────

/**
Strictly parses an armored age block out of `text`, returning the raw age
bytes.

The parser ports rage's `ArmoredReader` line-validation logic exactly:

$(UL
    $(LI Leading and trailing ASCII whitespace around the PEM block is allowed
        and skipped.)
    $(LI The first non-whitespace content MUST be the begin marker
        ($(LREF ARMOR_BEGIN)); otherwise $(LREF ArmorErrorCode.trailingGarbage)
        (or $(LREF ArmorErrorCode.unexpectedEof) if the block is truncated).)
    $(LI A line MAY be terminated by either LF or CRLF; the CR of a `\r\n`
        terminator is tolerated, but a CR (`0x0D`) embedded in line content is
        rejected ($(LREF ArmorErrorCode.crlf)).)
    $(LI Every base64 line MUST be exactly 64 columns, except the final line
        which MAY be shorter; a violation is $(LREF ArmorErrorCode.longLine).
        A non-final line whose length is not a multiple of four is
        $(LREF ArmorErrorCode.nonCanonical) (it cannot be a canonical
        64-column line).)
    $(LI The base64 itself MUST be canonical and `=`-padded
        ($(LREF ArmorErrorCode.nonCanonical) otherwise).)
    $(LI A missing end marker is $(LREF ArmorErrorCode.missingEndMarker).)
    $(LI Non-whitespace after the end marker is
        $(LREF ArmorErrorCode.trailingGarbage).)
)

Returns: an $(REF ArmorExpected, sparkles,age,errors) carrying the decoded
`ubyte[]` (GC-allocated) on success, or an $(LREF ArmorError) with the byte
`offset` (relative to `text`) at which the failure was detected.
*/
ArmorExpected!(ubyte[]) armorDecode(scope const(char)[] text) @safe
{
    import std.array : appender;

    // ── 1. Skip leading whitespace and locate the begin marker. ───────────
    size_t pos = 0;
    while (pos < text.length && isAsciiWhitespace(text[pos]))
        pos++;

    if (pos >= text.length)
        return armorErr!(ubyte[])(ArmorErrorCode.unexpectedEof, text.length);

    if (text.length - pos < ARMOR_BEGIN.length)
        return armorErr!(ubyte[])(ArmorErrorCode.unexpectedEof, pos);

    if (text[pos .. pos + ARMOR_BEGIN.length] != ARMOR_BEGIN)
        return armorErr!(ubyte[])(ArmorErrorCode.trailingGarbage, pos);
    pos += ARMOR_BEGIN.length;

    // The begin marker must be followed by a line ending — either a bare LF or a
    // CRLF (age permits CRLF as the line terminator throughout an armored file).
    if (pos < text.length && text[pos] == '\r')
        pos++; // tolerate the CR of a CRLF terminator; the LF is required next.
    if (pos >= text.length || text[pos] != '\n')
        // No newline after the begin marker: either truncated, or garbage.
        return pos >= text.length
            ? armorErr!(ubyte[])(ArmorErrorCode.unexpectedEof, pos)
            : armorErr!(ubyte[])(ArmorErrorCode.longLine, pos);
    pos++; // consume the LF after the begin marker.

    // ── 2. Read body lines until the end marker. ──────────────────────────
    auto outBuf = appender!(ubyte[]);
    bool foundShortLine = false;
    bool foundEnd = false;

    while (pos < text.length)
    {
        // Extract the next line [lineStart, lineEnd), with `pos` advanced past
        // its LF (if any).
        const lineStart = pos;
        size_t lineEnd = pos;
        while (lineEnd < text.length && text[lineEnd] != '\n')
            lineEnd++;
        // Advance `pos` past the line and its newline (if present).
        pos = lineEnd < text.length ? lineEnd + 1 : lineEnd;

        // Strip a single trailing CR: a CRLF (`\r\n`) is a permitted line
        // terminator, so the CR immediately before the LF is part of the EOL, not
        // the line content. (rage's `validate_line` does the same `\r\n` trim.)
        size_t contentEnd = lineEnd;
        if (contentEnd > lineStart && text[contentEnd - 1] == '\r')
            contentEnd--;
        auto line = text[lineStart .. contentEnd];

        // Any CR *within* the line content (i.e. not the trailing CRLF) is
        // rejected — only CRLF-as-terminator is tolerated.
        foreach (k, c; line)
            if (c == '\r')
                return armorErr!(ubyte[])(ArmorErrorCode.crlf, lineStart + k);

        // The end marker terminates the body.
        if (line == ARMOR_END)
        {
            foundEnd = true;
            break;
        }

        // Enforce the canonical wrapping (rage's parse_armor_line match).
        const n = line.length;
        if (!foundShortLine)
        {
            if (n == COLUMNS_PER_LINE)
            {
                // A full 64-column line — keep going.
            }
            else if (n % 4 != 0)
            {
                // A non-final line whose length is not a multiple of four can
                // never be a canonical 64-column line (rage: MissingPadding).
                return armorErr!(ubyte[])(ArmorErrorCode.nonCanonical, lineStart);
            }
            else if (n < COLUMNS_PER_LINE)
            {
                // The single permitted short (final) line.
                foundShortLine = true;
            }
            else
            {
                // n > 64: not wrapped at 64 columns.
                return armorErr!(ubyte[])(ArmorErrorCode.longLine, lineStart);
            }
        }
        else
        {
            // We have already seen the final short line; any further base64
            // line is a short line in the middle of the encoding.
            return armorErr!(ubyte[])(ArmorErrorCode.longLine, lineStart);
        }

        // Decode this body line (strict, canonical, `=`-padded).
        ubyte[base64MaxDecodedLength(COLUMNS_PER_LINE)] lineBytes = void;
        auto decoded = decodeBase64Padded(line, lineBytes[]);
        if (!decoded.hasValue)
            return armorErr!(ubyte[])(ArmorErrorCode.nonCanonical,
                lineStart + decoded.error.offset);
        outBuf.put(decoded.value);
    }

    if (!foundEnd)
        return armorErr!(ubyte[])(ArmorErrorCode.missingEndMarker, text.length);

    // ── 3. Only ASCII whitespace may follow the end marker. ───────────────
    foreach (k; pos .. text.length)
        if (!isAsciiWhitespace(text[k]))
            return armorErr!(ubyte[])(ArmorErrorCode.trailingGarbage, k);

    return armorOk(outBuf[]);
}

///
@("age.armor.armorDecode.basic")
@safe unittest
{
    auto r = armorDecode(
        "-----BEGIN AGE ENCRYPTED FILE-----\n"
        ~ "aGVsbG8gYWdl\n"
        ~ "-----END AGE ENCRYPTED FILE-----\n");
    assert(r.hasValue);
    assert(r.value == cast(const(ubyte)[]) "hello age");
}

// ─────────────────────────────────────────────────────────────────────────────
// Round-trip
// ─────────────────────────────────────────────────────────────────────────────

@("age.armor.roundTrip.variousLengths")
@safe unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    // Cover boundaries around the 48-byte / 64-column line: empty, sub-line,
    // exactly one line, just over a line, several lines, and a non-aligned
    // multi-line size. A LCG gives reproducible pseudo-random bytes.
    static immutable size_t[] lengths =
        [0, 1, 2, 3, 47, 48, 49, 95, 96, 97, 144, 145, 1000];

    foreach (len; lengths)
    {
        auto data = new ubyte[len];
        uint state = 0x1234_5678u ^ cast(uint) len;
        foreach (ref b; data)
        {
            state = state * 1_103_515_245u + 12_345u;
            b = cast(ubyte)(state >> 16);
        }

        SmallBuffer!(char, 2048) w;
        armorEncode(data, w);

        auto r = armorDecode(w[]);
        assert(r.hasValue);
        assert(r.value == data);
    }
}

@("age.armor.roundTrip.leadingTrailingWhitespaceAccepted")
@safe unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 256) w;
    armorEncode(cast(const(ubyte)[]) "whitespace ok", w);

    // Surround the PEM block with assorted whitespace; it must still decode.
    const wrapped = "\n\n   \t" ~ w[].idup ~ "\n\t \n  ";
    auto r = armorDecode(wrapped);
    assert(r.hasValue);
    assert(r.value == cast(const(ubyte)[]) "whitespace ok");
}

// ─────────────────────────────────────────────────────────────────────────────
// Strict-rejection tests
// ─────────────────────────────────────────────────────────────────────────────

@("age.armor.armorDecode.acceptsCrlfTerminator")
@safe unittest
{
    // CRLF is a permitted line terminator throughout an armored file (testkit
    // `armor_crlf`): the CR before each LF is part of the EOL, not content.
    auto r = armorDecode(
        "-----BEGIN AGE ENCRYPTED FILE-----\r\n"
        ~ "aGVsbG8gYWdl\r\n"
        ~ "-----END AGE ENCRYPTED FILE-----\r\n");
    assert(r.hasValue);
    assert(r.value == cast(const(ubyte)[]) "hello age");
}

@("age.armor.armorDecode.rejectsEmbeddedCr")
@safe unittest
{
    // A CR that is *not* the trailing CR of a CRLF terminator (i.e. embedded in
    // the line content) is still rejected outright.
    auto r = armorDecode(
        "-----BEGIN AGE ENCRYPTED FILE-----\n"
        ~ "aGVs\rbG8gYWdl\n"
        ~ "-----END AGE ENCRYPTED FILE-----\n");
    assert(!r.hasValue);
    assert(r.error.code == ArmorErrorCode.crlf);
}

@("age.armor.armorDecode.rejectsLongLineInMiddle")
@safe unittest
{
    // A full 64-column line following the final short line is a short line in
    // the middle of the encoding -> longLine.
    //
    // Build: short line (4 cols) then a full 64-col line. "QQ==" decodes 'A'.
    immutable full = "QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFB"; // 64 cols
    assert(full.length == 64);
    auto r = armorDecode(
        "-----BEGIN AGE ENCRYPTED FILE-----\n"
        ~ "QQ==\n"   // 4-column short final line
        ~ full ~ "\n" // a full line afterwards -> short-line-in-middle
        ~ "-----END AGE ENCRYPTED FILE-----\n");
    assert(!r.hasValue);
    assert(r.error.code == ArmorErrorCode.longLine);
}

@("age.armor.armorDecode.rejectsLineLongerThan64")
@safe unittest
{
    // A first body line longer than 64 columns -> longLine.
    char[68] longLine = void;
    longLine[] = 'A';
    auto r = armorDecode(
        "-----BEGIN AGE ENCRYPTED FILE-----\n"
        ~ longLine[].idup ~ "\n"
        ~ "-----END AGE ENCRYPTED FILE-----\n");
    assert(!r.hasValue);
    assert(r.error.code == ArmorErrorCode.longLine);
}

@("age.armor.armorDecode.rejectsTrailingGarbage")
@safe unittest
{
    auto r = armorDecode(
        "-----BEGIN AGE ENCRYPTED FILE-----\n"
        ~ "aGVsbG8gYWdl\n"
        ~ "-----END AGE ENCRYPTED FILE-----\n"
        ~ "this is garbage");
    assert(!r.hasValue);
    assert(r.error.code == ArmorErrorCode.trailingGarbage);
}

@("age.armor.armorDecode.rejectsGarbageBeforeBegin")
@safe unittest
{
    // Non-whitespace before the begin marker -> trailingGarbage (the
    // first-non-whitespace-is-not-BEGIN case).
    auto r = armorDecode(
        "junk\n"
        ~ "-----BEGIN AGE ENCRYPTED FILE-----\n"
        ~ "aGVsbG8gYWdl\n"
        ~ "-----END AGE ENCRYPTED FILE-----\n");
    assert(!r.hasValue);
    assert(r.error.code == ArmorErrorCode.trailingGarbage);
}

@("age.armor.armorDecode.rejectsMissingEnd")
@safe unittest
{
    auto r = armorDecode(
        "-----BEGIN AGE ENCRYPTED FILE-----\n"
        ~ "aGVsbG8gYWdl\n");
    assert(!r.hasValue);
    assert(r.error.code == ArmorErrorCode.missingEndMarker);
}

@("age.armor.armorDecode.rejectsNonCanonicalBase64")
@safe unittest
{
    // "aGVsbG8gYWdm" decodes "hello agf"; flip the final group to be
    // non-canonical: "Zh==" sets the low bits of the partial group.
    // We need the offending line to be a valid *final* short line in length
    // (multiple of four, < 64) so it reaches the base64 decoder, where the
    // non-canonical trailing bits are caught.
    auto r = armorDecode(
        "-----BEGIN AGE ENCRYPTED FILE-----\n"
        ~ "Zh==\n"
        ~ "-----END AGE ENCRYPTED FILE-----\n");
    assert(!r.hasValue);
    assert(r.error.code == ArmorErrorCode.nonCanonical);
}

@("age.armor.armorDecode.rejectsNonMultipleOfFourLine")
@safe unittest
{
    // A non-final body line whose length is not a multiple of four can never
    // be a canonical 64-column line -> nonCanonical (rage's MissingPadding).
    // "aaa" is 3 chars: not a multiple of four and < 64, and it is followed by
    // another (full) line so it is not the final short line.
    immutable full = "QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFB"; // 64 cols
    auto r = armorDecode(
        "-----BEGIN AGE ENCRYPTED FILE-----\n"
        ~ "aaa\n"
        ~ full ~ "\n"
        ~ "-----END AGE ENCRYPTED FILE-----\n");
    assert(!r.hasValue);
    assert(r.error.code == ArmorErrorCode.nonCanonical);
}

@("age.armor.armorDecode.rejectsTruncatedBegin")
@safe unittest
{
    // A partial begin marker (no following newline / truncated) -> unexpectedEof.
    auto r = armorDecode("-----BEGIN AGE ENCRYPTED");
    assert(!r.hasValue);
    assert(r.error.code == ArmorErrorCode.unexpectedEof);
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// ASCII whitespace per Rust's `u8::is_ascii_whitespace` (space, tab, LF, CR,
/// form feed) — the set rage's `ArmoredReader` treats as ignorable around the
/// PEM block.
private bool isAsciiWhitespace(char c) @safe pure nothrow @nogc
    => c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\x0c';

@("age.armor.isAsciiWhitespace")
@safe pure nothrow @nogc
unittest
{
    assert(isAsciiWhitespace(' '));
    assert(isAsciiWhitespace('\t'));
    assert(isAsciiWhitespace('\n'));
    assert(isAsciiWhitespace('\r'));
    assert(isAsciiWhitespace('\x0c'));
    assert(!isAsciiWhitespace('A'));
    assert(!isAsciiWhitespace('-'));
}
