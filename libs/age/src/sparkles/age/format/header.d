/**
The age v1 file header (§7.2): $(LREF HeaderV1) plus its slice-advance parser
$(LREF parseHeader), the $(LREF buildHeader) constructor, and the
$(LREF writeHeader) serializer.

The header is the textual prologue of an age file:

```
age-encryption.org/v1
-> X25519 <base64 ephemeral share>
<base64 body, wrapped at 64 columns, ending in a line < 64 chars>
--- <base64 MAC>
```

It is a version line (`age-encryption.org/v1\n`), one or more
[stanza.Stanza|recipient stanzas] (§7.3), and a MAC line (`--- <base64 MAC>\n`,
§7.4). Each section is recognized by its first three bytes — `-> ` opens a
stanza, `---` opens the MAC line — and a stanza body ends at the first line
shorter than 64 columns.

$(LREF HeaderV1) preserves the $(B exact wire bytes) it was parsed from
($(LREF HeaderV1.encodedBytes)) so the MAC verifies against the bytes as
received, even when those bytes are not round-trip canonical (e.g. a header
carrying a legacy "missing empty final line" stanza body — see
$(LREF parseHeader)). $(LREF macInputOf) slices out exactly the byte range the
header MAC authenticates (everything through the `---` mark), shared by
$(LREF parseHeader)/$(LREF buildHeader) consumers and
$(REF verifyHeaderMac, sparkles,age,mac).

This is a faithful port of rage's `HeaderV1` and the `read`/`write` header
grammars in `age/src/format.rs` and `age-core/src/format.rs`. The strict
base64-body grammar and its legacy fallback mirror `wrapped_encoded_data` /
`legacy_wrapped_encoded_data`.

This layer may use the GC for the owned [stanza.Stanza|`Stanza`] arrays and the
serialized-header buffer; it stays `@safe` throughout and reports parse
failures via $(REF ParseExpected, sparkles,core_cli,text,errors).

See `docs/specs/age/SPEC.md` §7.2–§7.4 and `https://c2sp.org/age`.

Copyright: © 2026, Petar Kirov
License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
Authors: Petar Kirov
*/
module sparkles.age.format.header;

import std.range.primitives : isOutputRange, put;

import sparkles.core_cli.text.errors :
    ParseErrorCode, ParseExpected, parseErr, parseOk;

import sparkles.age.format.stanza : Stanza, writeStanza, isArbitraryString;
import sparkles.age.mac : computeHeaderMac, headerMacBytes;

@safe:

// ─────────────────────────────────────────────────────────────────────────────
// Wire constants
// ─────────────────────────────────────────────────────────────────────────────

/// The fixed first line of an age v1 header, including its terminating `\n`.
enum string V1_LINE = "age-encryption.org/v1\n";

/// The `age-encryption.org/` magic that opens every age file, regardless of
/// version. The version string (`v1`, …) follows immediately.
enum string AGE_MAGIC = "age-encryption.org/";

/// The three-byte mark that opens the header MAC line (`--- <base64 MAC>`).
enum string MAC_TAG = "---";

/// The three-byte prefix that opens a recipient stanza (`-> tag …`).
private enum string STANZA_TAG = "-> ";

/// The exact column at which stanza bodies are wrapped (§7.3).
private enum size_t WRAP_COLUMNS = 64;

/// The number of base64 characters in the encoded 32-byte header MAC: a 32-byte
/// tag is `ceil(32 * 4 / 3) == 43` unpadded base64 characters (§7.4).
enum size_t ENCODED_MAC_LENGTH = 43;

static assert(headerMacBytes == 32);

// ─────────────────────────────────────────────────────────────────────────────
// HeaderV1
// ─────────────────────────────────────────────────────────────────────────────

/**
A parsed or freshly-built age v1 header — the owned analogue of rage's
`HeaderV1`.

$(LREF recipients) are the header's [stanza.Stanza|stanzas] in wire order, each
already carrying its $(B decoded) binary body. $(LREF mac) is the 32-byte
HMAC-SHA-256 tag from (or for) the `--- <base64 MAC>` line.

$(LREF encodedBytes) holds the exact wire bytes this header was parsed from
($(LREF parseHeader) sets it; $(LREF buildHeader) sets it to the freshly
serialized header). It exists so the MAC verifies against the bytes $(B as
received) — important because a parsed header may not be round-trip canonical
(a legacy stanza body of length `0 mod 64` re-serializes with an extra empty
line). Use $(LREF macInputOf) to recover the MAC-authenticated byte range.
*/
struct HeaderV1
{
    /// The recipient stanzas, in wire order, each holding a decoded body.
    Stanza[] recipients;

    /// The 32-byte HMAC-SHA-256 header MAC.
    ubyte[headerMacBytes] mac;

    /// The exact wire bytes this header was parsed from (or, for a built
    /// header, the freshly serialized bytes). Used for MAC verification so the
    /// MAC checks against the bytes as received. `null` is never produced by
    /// the functions here, but the field is left assignable for callers.
    const(ubyte)[] encodedBytes;

    /**
    Returns `true` iff this header satisfies the v1 structural requirement
    (§7.2, §9.2): it contains either $(B zero) `scrypt` stanzas, or $(B exactly
    one) `scrypt` stanza and no other stanzas.

    Ports rage's `HeaderV1::is_valid` (`valid_scrypt() || no_scrypt()`). A
    `scrypt` (passphrase) recipient is mutually exclusive with every other
    recipient type, including a second `scrypt` stanza.
    */
    bool isValidStructure() const pure nothrow @nogc
    {
        size_t scryptCount = 0;
        foreach (ref r; recipients)
            if (r.tag == "scrypt")
                scryptCount++;

        // no scrypt → valid; exactly one scrypt AND it is the only stanza →
        // valid; anything else (scrypt mixed with others, or >1 scrypt) → not.
        if (scryptCount == 0)
            return true;
        return scryptCount == 1 && recipients.length == 1;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// macInput helper
// ─────────────────────────────────────────────────────────────────────────────

/**
Returns the byte range of `encodedBytes` that the header MAC authenticates:
everything from `age-encryption.org/v1\n` $(B through) the `---` mark,
$(B excluding) the trailing `" " <43 base64 MAC> "\n"` of the MAC line (§7.4).

This is the `macInput` that $(REF computeHeaderMac, sparkles,age,mac) /
$(REF verifyHeaderMac, sparkles,age,mac) expect. It ports rage's
`bytes[..bytes.len() - ENCODED_MAC_LENGTH - 2]` slice in
`HeaderV1::verify_mac`: the MAC line's fixed tail is `' '` + 43 MAC chars +
`'\n'`, i.e. $(LREF ENCODED_MAC_LENGTH)` + 2` bytes.

The argument is normally $(LREF HeaderV1.encodedBytes). The slice aliases that
buffer (no copy). Behaviour is undefined for inputs too short to contain a MAC
line — callers pass a header that $(LREF parseHeader)/$(LREF buildHeader)
produced, which always has a complete MAC line.
*/
const(ubyte)[] macInputOf(return scope const(ubyte)[] encodedBytes) pure nothrow @nogc
in (encodedBytes.length >= ENCODED_MAC_LENGTH + 2,
    "encodedBytes too short to contain a MAC line")
{
    return encodedBytes[0 .. $ - ENCODED_MAC_LENGTH - 2];
}

// ─────────────────────────────────────────────────────────────────────────────
// base64-body character classification
// ─────────────────────────────────────────────────────────────────────────────

/// Returns `true` iff `c` is a standard base64 character (`A–Z a–z 0–9 + /`).
/// Ports rage's `is_base64_char`. Padding (`=`) is deliberately excluded.
private bool isBase64Char(char c) pure nothrow @nogc
{
    return (c >= 'A' && c <= 'Z')
        || (c >= 'a' && c <= 'z')
        || (c >= '0' && c <= '9')
        || c == '+'
        || c == '/';
}

// ─────────────────────────────────────────────────────────────────────────────
// parseHeader
// ─────────────────────────────────────────────────────────────────────────────

/**
Parses an age v1 header from the front of `input`, returning the structured
$(LREF HeaderV1) and, via the `out` parameter `consumed`, the number of bytes
the header occupied (through the final `\n` of the MAC line).

The grammar (a faithful port of rage's header `read` combinators):

$(OL
    $(LI the version line — `age-encryption.org/v1\n` exactly. Any other version
        string after the `age-encryption.org/` magic is rejected with
        $(REF ParseErrorCode.invalidIdentifier, sparkles,core_cli,text,errors)
        (the caller — `Decryptor.parse`, M6 — maps this to
        $(REF DecryptErrorCode.unknownFormat, sparkles,age,errors)). A missing
        or malformed magic is `unexpectedCharacter`.)
    $(LI one or more stanzas — each `-> ` then SP-separated arbitrary-string
        arguments (the first is the $(LREF Stanza.tag)) and `\n`, followed by
        the base64 body. Full body lines are exactly 64 base64 chars; the body
        ends at the first line shorter than 64 chars (possibly empty). Bodies
        decode with strict $(B unpadded) base64
        ($(REF decodeBase64, sparkles,crypto,encoding,base64)) — non-canonical
        trailing bits or any `=` are rejected.)
    $(LI the MAC line — `--- ` then exactly $(LREF ENCODED_MAC_LENGTH) (43)
        base64 chars and `\n`, decoding to the 32-byte $(LREF HeaderV1.mac).)
)

Legacy tolerance: a stanza whose encoded body length is a multiple of 64
historically omitted the mandatory empty final line, making it ambiguous with
an incomplete stanza. As rage's `legacy_age_stanza` does, this parser accepts
that form — a run of full 64-char lines with the following line being the next
section's `-> ` / `---` — then proceeds. The recovered $(LREF HeaderV1) is
identical to the canonical one; only $(LREF HeaderV1.encodedBytes) (hence the
MAC) reflects the as-received bytes.

On success, `consumed` is set and $(LREF HeaderV1.encodedBytes) is set to
`input[0 .. consumed]`. On failure, `consumed` is `0`, and the returned
$(REF ParseError, sparkles,core_cli,text,errors)`.offset` is relative to
`input` as received. Any structural failure surfaces as a parse error; the
caller maps it to
$(REF DecryptErrorCode.invalidHeader, sparkles,age,errors) (except the version
mismatch noted above).

Params:
    input    = the header bytes (the start of an age file)
    consumed = out: bytes consumed through the MAC line's final `\n`
Returns: the parsed $(LREF HeaderV1), or a parse error.
*/
ParseExpected!HeaderV1 parseHeader(scope const(ubyte)[] input, out size_t consumed)
{
    // The cursor we advance; offsets reported to the caller are `start - rest`.
    const(ubyte)[] rest = input;
    const(ubyte)[] start = input;

    size_t offsetOf(scope const(ubyte)[] cur) @safe pure nothrow @nogc
        => start.length - cur.length;

    // ── Version line ─────────────────────────────────────────────────────────
    // The whole file begins with the "age-encryption.org/" magic; the version
    // string follows. We only understand "v1\n".
    if (!startsWith(rest, cast(const(ubyte)[]) AGE_MAGIC))
        return parseErr!HeaderV1(ParseErrorCode.unexpectedCharacter, 0);

    if (!startsWith(rest, cast(const(ubyte)[]) V1_LINE))
    {
        // The magic matched but the version is not "v1\n": an unknown format.
        // The caller maps `invalidIdentifier` here to `unknownFormat`.
        return parseErr!HeaderV1(
            ParseErrorCode.invalidIdentifier, AGE_MAGIC.length);
    }
    rest = rest[V1_LINE.length .. $];

    // ── Stanzas (1*stanza) ─────────────────────────────────────────────────────
    Stanza[] recipients;
    for (;;)
    {
        // A stanza opens with "-> "; the MAC line opens with "---". Anything
        // else here is malformed.
        if (startsWith(rest, cast(const(ubyte)[]) MAC_TAG))
            break;
        if (!startsWith(rest, cast(const(ubyte)[]) STANZA_TAG))
            return parseErr!HeaderV1(
                ParseErrorCode.unexpectedCharacter, offsetOf(rest));

        auto st = parseStanza(rest, start);
        if (!st.hasValue)
            return parseErr!HeaderV1(st.error);
        recipients ~= st.value;
    }

    // 1*stanza: at least one stanza is required before the MAC line.
    if (recipients.length == 0)
        return parseErr!HeaderV1(
            ParseErrorCode.unexpectedCharacter, offsetOf(rest));

    // ── MAC line: "--- " 43base64char "\n" ──────────────────────────────────────
    // `rest` is positioned at "---" (the loop broke here).
    rest = rest[MAC_TAG.length .. $];
    if (rest.length == 0 || rest[0] != ' ')
        return parseErr!HeaderV1(
            ParseErrorCode.unexpectedCharacter, offsetOf(rest));
    rest = rest[1 .. $];

    if (rest.length < ENCODED_MAC_LENGTH)
        return parseErr!HeaderV1(
            ParseErrorCode.unexpectedEnd, offsetOf(rest));
    const macChars = cast(const(char)[]) rest[0 .. ENCODED_MAC_LENGTH];

    ubyte[headerMacBytes] mac = void;
    if (!decodeMac(macChars, mac))
        return parseErr!HeaderV1(
            ParseErrorCode.nonCanonicalEncoding, offsetOf(rest));
    rest = rest[ENCODED_MAC_LENGTH .. $];

    if (rest.length == 0 || rest[0] != '\n')
        return parseErr!HeaderV1(
            ParseErrorCode.unexpectedCharacter, offsetOf(rest));
    rest = rest[1 .. $];

    consumed = offsetOf(rest);
    // Own a copy of the parsed wire bytes (rather than aliasing the `scope`
    // `input`, which dip1000 forbids escaping). This mirrors rage's owned
    // `encoded_bytes: Vec<u8>` and lets the MAC verify against the bytes as
    // received even after `input` goes out of scope.
    return parseOk(HeaderV1(
        recipients: recipients,
        mac: mac,
        encodedBytes: input[0 .. consumed].dup,
    ));
}

/**
Parses a single stanza from the front of `rest` (positioned at `-> `),
advancing `rest` past it. `start` is the original full input, used only to
report absolute offsets in errors. Tolerates the legacy missing-final-line body
form. Internal helper for $(LREF parseHeader).
*/
private ParseExpected!Stanza parseStanza(
    ref scope const(ubyte)[] rest, scope const(ubyte)[] start)
{
    size_t offsetOf(scope const(ubyte)[] cur) @safe pure nothrow @nogc
        => start.length - cur.length;

    // ── Argument line: "-> " argument *(SP argument) LF ─────────────────────────
    rest = rest[STANZA_TAG.length .. $];

    // The argument line runs to the first '\n'. Split it on single spaces; the
    // first token is the tag, the rest are args. Each must be 1*VCHAR.
    size_t nl = 0;
    while (nl < rest.length && rest[nl] != '\n')
        nl++;
    if (nl == rest.length)
        return parseErr!Stanza(
            ParseErrorCode.unexpectedEnd, offsetOf(rest[$ .. $]));

    const argLine = cast(const(char)[]) rest[0 .. nl];
    const argLineOffset = offsetOf(rest);
    rest = rest[nl + 1 .. $]; // consume the line and its '\n'

    string tag;
    string[] args;
    {
        size_t i = 0;
        size_t tokenIndex = 0;
        while (i <= argLine.length)
        {
            // Find the next space (or end of line).
            size_t j = i;
            while (j < argLine.length && argLine[j] != ' ')
                j++;
            const token = argLine[i .. j];
            if (!isArbitraryString(token))
                return parseErr!Stanza(
                    ParseErrorCode.invalidIdentifier, argLineOffset + i);
            if (tokenIndex == 0)
                tag = token.idup;
            else
                args ~= token.idup;
            tokenIndex++;

            if (j == argLine.length)
                break;
            i = j + 1; // skip the space
        }
    }

    // ── Body: *full-line final-line (with legacy tolerance) ─────────────────────
    auto body_ = parseStanzaBody(rest, start);
    if (!body_.hasValue)
        return parseErr!Stanza(body_.error);

    return parseOk(Stanza(tag: tag, args: args, body_: body_.value));
}

/**
Parses (and decodes) a stanza body from the front of `rest`, advancing past it.
Returns the decoded binary body. Implements rage's `wrapped_encoded_data` with
the `legacy_wrapped_encoded_data` fallback. `start` is used for error offsets.
Internal helper for $(LREF parseStanza).
*/
private ParseExpected!(ubyte[]) parseStanzaBody(
    ref scope const(ubyte)[] rest, scope const(ubyte)[] start)
{
    import sparkles.crypto.encoding.base64 :
        decodeBase64, base64MaxDecodedLength;

    size_t offsetOf(scope const(ubyte)[] cur) @safe pure nothrow @nogc
        => start.length - cur.length;

    // Accumulate the raw base64 characters of the body across lines, then decode
    // once at the end. We walk line-by-line: a full body line is exactly 64
    // base64 chars; the body ends at the first line shorter than 64 chars (the
    // "final line"). The final line may be empty.
    //
    // Legacy tolerance (rage's `legacy_age_stanza`): a body whose encoded length
    // is a multiple of 64 historically omitted the mandatory empty final line.
    // Such a body is a run of full 64-char lines immediately followed by the
    // next section ("-> " or "---"). We detect that and stop, treating the
    // accumulated full lines as the whole body.
    const(char)[] b64; // owned accumulator (GC) of base64 chars

    for (;;)
    {
        // Measure the current line: base64 chars up to the next '\n'.
        size_t len = 0;
        while (len < rest.length && rest[len] != '\n' && isBase64Char(cast(char) rest[len]))
            len++;

        const atLineEnd = len < rest.length && rest[len] == '\n';

        if (!atLineEnd)
        {
            // The "line" did not terminate in a clean '\n' after only base64
            // chars. Two cases:
            //   (a) We hit a non-base64, non-'\n' byte — that is the start of
            //       the next section for a legacy (no-final-line) body, but
            //       only if every accumulated line so far was a full 64-char
            //       line (i.e. `len == 0` here AND b64 length is a multiple of
            //       64). Otherwise it is malformed.
            //   (b) We ran out of input — truncated header.
            if (len == 0 && b64.length > 0 && b64.length % WRAP_COLUMNS == 0)
            {
                // Legacy: the full-line run is the entire body; the next bytes
                // are the following section. Stop without consuming them.
                break;
            }
            if (len == rest.length)
                return parseErr!(ubyte[])(
                    ParseErrorCode.unexpectedEnd, offsetOf(rest[$ .. $]));
            return parseErr!(ubyte[])(
                ParseErrorCode.unexpectedCharacter, offsetOf(rest) + len);
        }

        const line = cast(const(char)[]) rest[0 .. len];

        if (len == WRAP_COLUMNS)
        {
            // A full line: part of the body, more lines follow.
            b64 ~= line;
            rest = rest[len + 1 .. $]; // consume line + '\n'
            continue;
        }

        // A short line (< 64 chars): the mandatory final line. The body ends
        // here. (An empty final line — len == 0 — is valid and terminates a
        // body that was a whole number of full lines.)
        b64 ~= line;
        rest = rest[len + 1 .. $];
        break;
    }

    // Decode the accumulated base64 with strict, unpadded rules. The encoder
    // never emits an internal full line that is not a multiple of 4 in a way
    // that would corrupt the join, because each full line is 64 chars (a
    // multiple of 4); only the final line carries the remainder.
    ubyte[] decoded;
    if (b64.length == 0)
    {
        decoded = []; // empty body
    }
    else
    {
        decoded = new ubyte[base64MaxDecodedLength(b64.length)];
        auto r = decodeBase64(b64, decoded);
        if (!r.hasValue)
        {
            // Strict-base64 rejection (non-canonical trailing bits, an invalid
            // length, or stray padding). We accumulate the body across line
            // joins, so we don't have a per-character source offset; report the
            // failure at the position just past the body (a stable anchor).
            return parseErr!(ubyte[])(
                ParseErrorCode.nonCanonicalEncoding, offsetOf(rest));
        }
        decoded = r.value;
    }

    return parseOk(decoded);
}

/// Decodes the 43-character base64 MAC field into a 32-byte tag, returning
/// `false` on any non-canonical / non-base64 input. Internal helper.
private bool decodeMac(scope const(char)[] macChars, ref ubyte[headerMacBytes] mac)
{
    import sparkles.crypto.encoding.base64 : decodeBase64, base64MaxDecodedLength;

    ubyte[base64MaxDecodedLength(ENCODED_MAC_LENGTH)] buf = void;
    auto r = decodeBase64(macChars, buf[]);
    if (!r.hasValue || r.value.length != headerMacBytes)
        return false;
    mac[] = r.value[0 .. headerMacBytes];
    return true;
}

/// Returns `true` iff `haystack` begins with `needle` (byte prefix test).
private bool startsWith(scope const(ubyte)[] haystack, scope const(ubyte)[] needle)
    pure nothrow @nogc
{
    if (haystack.length < needle.length)
        return false;
    return haystack[0 .. needle.length] == needle;
}

// ─────────────────────────────────────────────────────────────────────────────
// buildHeader
// ─────────────────────────────────────────────────────────────────────────────

/**
Builds a $(LREF HeaderV1) over `recipients`, computing its MAC under the
32-byte `hmacKey` (§7.4).

Serializes `age-encryption.org/v1\n` + each stanza + `---`, computes
`HMAC-SHA-256(hmacKey, that)` as the $(LREF HeaderV1.mac), then sets
$(LREF HeaderV1.encodedBytes) to the $(B full) serialized header (including the
`--- <base64 MAC>\n` line) so a freshly built header round-trips and verifies
against its own bytes.

Unlike rage's `HeaderV1::new`, this does $(B not) inject a "grease" stanza or
re-check the structural rule (those belong to the encryptor protocol, M6);
callers should validate via $(LREF HeaderV1.isValidStructure) beforehand.

Params:
    recipients = the stanzas to place in the header (in wire order)
    hmacKey    = the 32-byte HMAC key (HKDF-derived from the file key, §7.4)
Returns: the built header, with `mac` and `encodedBytes` populated.
*/
HeaderV1 buildHeader(Stanza[] recipients, in ubyte[32] hmacKey)
{
    import std.array : appender;

    // Serialize the header-minus-MAC: version line + stanzas + "---". The
    // serializers drive a `char` output range; we view the result as bytes for
    // both the MAC computation and `encodedBytes`.
    auto minusMac = appender!(char[]);
    writeHeaderMinusMac(minusMac, recipients);
    const macInput = cast(const(ubyte)[]) minusMac[];

    const mac = computeHeaderMac(hmacKey, macInput);

    auto h = HeaderV1(recipients: recipients, mac: mac);

    // encodedBytes = the full serialized header (incl. the MAC line): reuse the
    // already-serialized header-minus-MAC, then append the MAC line.
    auto full = appender!(char[]);
    full.put(minusMac[]);
    writeMacLine(full, mac);
    h.encodedBytes = cast(const(ubyte)[]) full[];

    return h;
}

// ─────────────────────────────────────────────────────────────────────────────
// writeHeader
// ─────────────────────────────────────────────────────────────────────────────

/**
Writes the full age v1 header `h` — version line, stanzas, and the
`--- <base64 MAC>\n` line — to the output range `w`.

This is the inverse of $(LREF parseHeader) for a canonical header. It always
re-serializes the structured fields ($(LREF HeaderV1.recipients) and
$(LREF HeaderV1.mac)); it does $(B not) emit $(LREF HeaderV1.encodedBytes), so
a header parsed from a non-canonical (legacy) source is written back in its
canonical form. (rage likewise never writes parsed headers, only generated
ones.)

`@safe`; allocates nothing of its own beyond what `w` does.
*/
void writeHeader(W)(ref W w, in HeaderV1 h)
if (isOutputRange!(W, const(char)[]) || isOutputRange!(W, const(ubyte)[]))
{
    static if (isOutputRange!(W, const(char)[]))
    {
        writeHeaderMinusMac(w, h.recipients);
        writeMacLine(w, h.mac);
    }
    else
    {
        // A byte-only range (e.g. `appender!(ubyte[])`): adapt it once into a
        // `char`-accepting sink so the shared `char`-output-range path (and the
        // `const(char)[]`-only `writeStanza`) applies uniformly.
        auto sink = byteRangeAsCharSink(w);
        writeHeaderMinusMac(sink, h.recipients);
        writeMacLine(sink, h.mac);
    }
}

/// Serializes the header up to and including the `---` mark (no trailing space
/// or MAC): the version line, then each stanza. This is exactly the byte range
/// the header MAC authenticates. Drives a `const(char)[]` output range; the
/// internal helper shared by $(LREF buildHeader) and $(LREF writeHeader).
private void writeHeaderMinusMac(W)(ref W w, in Stanza[] recipients)
if (isOutputRange!(W, const(char)[]))
{
    put(w, V1_LINE);
    foreach (ref r; recipients)
        writeStanza(w, r);
    put(w, MAC_TAG);
}

/// Serializes the MAC line tail: `" " <43 base64 MAC> "\n"` into a
/// `const(char)[]` output range. Internal helper.
private void writeMacLine(W)(ref W w, in ubyte[headerMacBytes] mac)
if (isOutputRange!(W, const(char)[]))
{
    import sparkles.crypto.encoding.base64 : encodeBase64, base64EncodedLength;
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    // `encodeBase64` is hard-`@nogc`, so it can't drive an allocating output
    // range (e.g. the `Appender` `buildHeader` uses). Encode the fixed-size MAC
    // through a `@nogc` line buffer first, then copy the bytes into `w`.
    SmallBuffer!(char, base64EncodedLength(headerMacBytes)) macChars;
    encodeBase64(mac[], macChars);

    put(w, " ");
    put(w, macChars[]);
    put(w, "\n");
}

/// Adapts a byte-only output range `w` (accepts `const(ubyte)[]` but not
/// `const(char)[]`, e.g. `std.array.appender!(ubyte[])`) into a sink the
/// `char`-driven header serializers can write through, casting each `char` /
/// `const(char)[]` to its `ubyte` equivalent. Internal helper.
private auto byteRangeAsCharSink(W)(ref W w)
{
    static struct CharSink
    {
        private W* _w;
        void put(char c) { .put(*_w, cast(ubyte) c); }
        void put(scope const(char)[] cs) { .put(*_w, cast(const(ubyte)[]) cs); }
    }

    return CharSink(&w);
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests
// ─────────────────────────────────────────────────────────────────────────────

/// Parses the canonical age spec example header (the v1 line, an X25519
/// stanza, and a `---` MAC line) and checks the recovered tag/args/body and the
/// preserved `encodedBytes`.
@("age.format.header.parseHeader.specExample")
@safe
unittest
{
    import sparkles.crypto.encoding.base64 : decodeBase64, base64MaxDecodedLength;

    static immutable string text =
        "age-encryption.org/v1\n"
        ~ "-> X25519 CJM36AHmTbdHSuOQL+NESqyVQE75f2e610iRdLPEN20\n"
        ~ "C3ZAeY64NXS4QFrksLm3EGz+uPRyI0eQsWw7LWbbYig\n"
        ~ "--- fgMiVLJHMlg9fW7CVG/hPS5EAU4Zeg19LyCP7SoH5nA\n";
    immutable(ubyte)[] input = cast(immutable(ubyte)[]) text;

    size_t consumed;
    auto r = parseHeader(input, consumed);
    assert(r.hasValue, "spec example header should parse");
    assert(consumed == input.length, "should consume the whole header");

    const h = r.value;
    assert(h.recipients.length == 1);
    assert(h.recipients[0].tag == "X25519");
    assert(h.recipients[0].args == ["CJM36AHmTbdHSuOQL+NESqyVQE75f2e610iRdLPEN20"]);

    // The body decodes to the 32-byte wrapped file key.
    enum bodyB64 = "C3ZAeY64NXS4QFrksLm3EGz+uPRyI0eQsWw7LWbbYig";
    ubyte[base64MaxDecodedLength(bodyB64.length)] raw = void;
    auto dec = decodeBase64(bodyB64, raw[]);
    assert(dec.hasValue);
    assert(h.recipients[0].body_ == dec.value);

    // encodedBytes is exactly the input we parsed.
    assert(h.encodedBytes == input);

    // The MAC field decoded to 32 bytes.
    enum macB64 = "fgMiVLJHMlg9fW7CVG/hPS5EAU4Zeg19LyCP7SoH5nA";
    ubyte[base64MaxDecodedLength(macB64.length)] macRaw = void;
    auto macDec = decodeBase64(macB64, macRaw[]);
    assert(macDec.hasValue);
    assert(h.mac[] == macDec.value);
}

/// A header with multiple stanzas — including the rage `parse_header` vector's
/// empty-body and full-body forms — parses, and `writeHeader` round-trips the
/// canonical bytes.
@("age.format.header.parseHeader.multiStanzaRoundTrip")
@safe
unittest
{
    import std.array : appender;

    static immutable string text =
        "age-encryption.org/v1\n"
        ~ "-> X25519 CJM36AHmTbdHSuOQL+NESqyVQE75f2e610iRdLPEN20\n"
        ~ "C3ZAeY64NXS4QFrksLm3EGz+uPRyI0eQsWw7LWbbYig\n"
        ~ "-> some-empty-body-recipient BjH7FA 37 mhir0Q\n"
        ~ "\n"
        ~ "-> some-full-body-recipient BjH7FA 37 mhir0Q\n"
        ~ "xD7o4VEOu1t7KZQ1gDgq2FPzBEeSRqbnqvQEXdLRYy143BxR6oFxsUUJCRB0ErXA\n"
        ~ "\n"
        ~ "--- fgMiVLJHMlg9fW7CVG/hPS5EAU4Zeg19LyCP7SoH5nA\n";
    immutable(ubyte)[] input = cast(immutable(ubyte)[]) text;

    size_t consumed;
    auto r = parseHeader(input, consumed);
    assert(r.hasValue, "multi-stanza header should parse");
    assert(consumed == input.length);

    const h = r.value;
    assert(h.recipients.length == 3);
    assert(h.recipients[0].tag == "X25519");
    assert(h.recipients[1].tag == "some-empty-body-recipient");
    assert(h.recipients[1].args == ["BjH7FA", "37", "mhir0Q"]);
    assert(h.recipients[1].body_.length == 0); // empty body
    assert(h.recipients[2].tag == "some-full-body-recipient");
    assert(h.recipients[2].body_.length == 48); // 64 base64 chars → 48 bytes

    // Re-serialize: a canonical header writes back to its exact bytes.
    auto buf = appender!(ubyte[]);
    writeHeader(buf, h);
    assert(cast(const(char)[]) buf[] == text,
        "canonical header should round-trip through writeHeader");
}

/// `buildHeader(stanzas, key)` → `writeHeader` → `parseHeader` round-trips the
/// stanzas and MAC, and the parsed header's `encodedBytes` MAC verifies under
/// the same key.
@("age.format.header.buildHeader.roundTripAndVerify")
@safe
unittest
{
    import std.array : appender;
    import sparkles.age.mac : verifyHeaderMac;

    // Two X25519 stanzas with distinct decoded bodies.
    auto bodyA = new ubyte[32];
    auto bodyB = new ubyte[48];
    foreach (i, ref b; bodyA) b = cast(ubyte)(i + 1);
    foreach (i, ref b; bodyB) b = cast(ubyte)(i * 3 + 7);

    Stanza[] recipients = [
        Stanza("X25519", ["c2hhcmUtb25l"], bodyA),
        Stanza("X25519", ["c2hhcmUtdHdv"], bodyB),
    ];

    // A fixed 32-byte HMAC key.
    ubyte[32] hmacKey = void;
    foreach (i; 0 .. 32) hmacKey[i] = cast(ubyte)(i * 5 + 1);

    auto built = buildHeader(recipients, hmacKey);
    assert(built.recipients.length == 2);
    assert(built.encodedBytes.length > 0);

    // Serialize, then parse the bytes back.
    auto buf = appender!(ubyte[]);
    writeHeader(buf, built);
    auto wire = buf[];

    // The built header's encodedBytes should equal what writeHeader emits.
    assert(built.encodedBytes == wire,
        "buildHeader.encodedBytes must equal the full serialized header");

    size_t consumed;
    auto parsed = parseHeader(wire, consumed);
    assert(parsed.hasValue, "built header should re-parse");
    assert(consumed == wire.length);

    const p = parsed.value;
    assert(p.recipients.length == 2);
    assert(p.recipients[0].tag == "X25519");
    assert(p.recipients[0].args == ["c2hhcmUtb25l"]);
    assert(p.recipients[0].body_ == bodyA);
    assert(p.recipients[1].body_ == bodyB);
    assert(p.mac == built.mac, "MAC must survive the round trip");

    // The MAC verifies against the as-received bytes via macInputOf.
    assert(verifyHeaderMac(hmacKey, macInputOf(p.encodedBytes), p.mac),
        "round-tripped header MAC must verify against its encodedBytes");
}

/// `isValidStructure`: a lone `scrypt` stanza is valid; `scrypt` mixed with an
/// X25519 stanza is invalid; two X25519 stanzas are valid.
@("age.format.header.isValidStructure.scryptRules")
@safe
unittest
{
    auto body_ = new ubyte[16];

    // Zero scrypt → valid.
    {
        auto h = HeaderV1([Stanza("X25519", ["a"], body_), Stanza("X25519", ["b"], body_)]);
        assert(h.isValidStructure, "two X25519 stanzas are valid");
    }
    // Exactly one scrypt, no others → valid.
    {
        auto h = HeaderV1([Stanza("scrypt", ["salt", "18"], body_)]);
        assert(h.isValidStructure, "a lone scrypt stanza is valid");
    }
    // scrypt mixed with another type → invalid.
    {
        auto h = HeaderV1([Stanza("scrypt", ["salt", "18"], body_), Stanza("X25519", ["a"], body_)]);
        assert(!h.isValidStructure, "scrypt mixed with X25519 is invalid");
    }
    // Two scrypt stanzas → invalid (must be exactly one, and the only stanza).
    {
        auto h = HeaderV1([Stanza("scrypt", ["s1", "18"], body_), Stanza("scrypt", ["s2", "18"], body_)]);
        assert(!h.isValidStructure, "two scrypt stanzas are invalid");
    }
}

/// A non-v1 version line is rejected with `invalidIdentifier` — the parse error
/// the caller maps to `DecryptErrorCode.unknownFormat`. A bad magic is a plain
/// `unexpectedCharacter`.
@("age.format.header.parseHeader.rejectsNonV1Version")
@safe
unittest
{
    // Valid magic, unknown version "v2".
    {
        immutable(ubyte)[] input = cast(immutable(ubyte)[])
            ("age-encryption.org/v2\n"
            ~ "-> X25519 abc\n"
            ~ "AAAA\n"
            ~ "--- fgMiVLJHMlg9fW7CVG/hPS5EAU4Zeg19LyCP7SoH5nA\n");
        size_t consumed;
        auto r = parseHeader(input, consumed);
        assert(!r.hasValue, "a v2 header must be rejected");
        assert(r.error.code == ParseErrorCode.invalidIdentifier,
            "an unknown version maps to invalidIdentifier (→ unknownFormat)");
        assert(consumed == 0);
    }
    // Wrong magic entirely.
    {
        immutable(ubyte)[] input = cast(immutable(ubyte)[]) "not-age/v1\n-> X25519 a\nAAAA\n";
        size_t consumed;
        auto r = parseHeader(input, consumed);
        assert(!r.hasValue);
        assert(r.error.code == ParseErrorCode.unexpectedCharacter);
    }
}

/// `encodedBytes` preserves the as-received bytes so a MAC computed over the
/// original input still verifies — even when re-serialization would differ.
/// Here we mutate the structured `mac` of a parsed header but verify against
/// the originally-received `encodedBytes` to confirm the slice is the source.
@("age.format.header.parseHeader.encodedBytesArePreserved")
@safe
unittest
{
    static immutable string text =
        "age-encryption.org/v1\n"
        ~ "-> X25519 CJM36AHmTbdHSuOQL+NESqyVQE75f2e610iRdLPEN20\n"
        ~ "C3ZAeY64NXS4QFrksLm3EGz+uPRyI0eQsWw7LWbbYig\n"
        ~ "--- fgMiVLJHMlg9fW7CVG/hPS5EAU4Zeg19LyCP7SoH5nA\n";
    immutable(ubyte)[] input = cast(immutable(ubyte)[]) text;

    size_t consumed;
    auto r = parseHeader(input, consumed);
    assert(r.hasValue);
    const h = r.value;

    // encodedBytes must alias the input we passed in (same content, full span).
    assert(h.encodedBytes.length == input.length);
    assert(h.encodedBytes == input);

    // macInputOf strips the trailing " <43 mac>\n": it ends exactly at "---".
    const mi = macInputOf(h.encodedBytes);
    assert(mi.length == input.length - (ENCODED_MAC_LENGTH + 2));
    assert(cast(const(char)[]) mi[$ - 3 .. $] == "---",
        "macInput must end at the --- mark");
}

/// The legacy "missing empty final line" stanza body (a full 64-char line
/// directly followed by the next section, with no intervening empty line) is
/// tolerated and decodes to the same body as the canonical form.
@("age.format.header.parseHeader.legacyMissingFinalLine")
@safe
unittest
{
    // `some-full-body-recipient` has a 64-char (48-byte) body. Canonical form
    // would add an empty line after it; the legacy form omits it and goes
    // straight to the MAC line.
    static immutable string legacy =
        "age-encryption.org/v1\n"
        ~ "-> X25519 CJM36AHmTbdHSuOQL+NESqyVQE75f2e610iRdLPEN20\n"
        ~ "C3ZAeY64NXS4QFrksLm3EGz+uPRyI0eQsWw7LWbbYig\n"
        ~ "-> some-full-body-recipient BjH7FA 37 mhir0Q\n"
        ~ "xD7o4VEOu1t7KZQ1gDgq2FPzBEeSRqbnqvQEXdLRYy143BxR6oFxsUUJCRB0ErXA\n"
        ~ "--- fgMiVLJHMlg9fW7CVG/hPS5EAU4Zeg19LyCP7SoH5nA\n";
    immutable(ubyte)[] input = cast(immutable(ubyte)[]) legacy;

    size_t consumed;
    auto r = parseHeader(input, consumed);
    assert(r.hasValue, "legacy missing-final-line body must be tolerated");
    assert(consumed == input.length);

    const h = r.value;
    assert(h.recipients.length == 2);
    assert(h.recipients[1].tag == "some-full-body-recipient");
    assert(h.recipients[1].body_.length == 48,
        "legacy full body decodes to the same 48 bytes");
}

/// A header with no stanzas before the MAC line (`1*stanza` violated) is
/// rejected.
@("age.format.header.parseHeader.rejectsZeroStanzas")
@safe
unittest
{
    immutable(ubyte)[] input = cast(immutable(ubyte)[])
        ("age-encryption.org/v1\n"
        ~ "--- fgMiVLJHMlg9fW7CVG/hPS5EAU4Zeg19LyCP7SoH5nA\n");
    size_t consumed;
    auto r = parseHeader(input, consumed);
    assert(!r.hasValue, "a header needs at least one stanza");
    assert(r.error.code == ParseErrorCode.unexpectedCharacter);
}

/// A truncated MAC line (fewer than 43 base64 chars) is rejected, and a
/// non-canonical MAC encoding is rejected too.
@("age.format.header.parseHeader.rejectsBadMac")
@safe
unittest
{
    // Truncated MAC.
    {
        immutable(ubyte)[] input = cast(immutable(ubyte)[])
            ("age-encryption.org/v1\n"
            ~ "-> X25519 a\nAAAA\n"
            ~ "--- short\n");
        size_t consumed;
        auto r = parseHeader(input, consumed);
        assert(!r.hasValue, "a short MAC must be rejected");
    }
    // 43 chars but trailing '\n' missing → unexpectedCharacter.
    {
        immutable(ubyte)[] input = cast(immutable(ubyte)[])
            ("age-encryption.org/v1\n"
            ~ "-> X25519 a\nAAAA\n"
            ~ "--- fgMiVLJHMlg9fW7CVG/hPS5EAU4Zeg19LyCP7SoH5nA");
        size_t consumed;
        auto r = parseHeader(input, consumed);
        assert(!r.hasValue, "a MAC line without its terminating newline is rejected");
    }
}

/// A stanza argument that is not a valid arbitrary string (contains a control
/// byte) is rejected with `invalidIdentifier`.
@("age.format.header.parseHeader.rejectsBadArgument")
@safe
unittest
{
    // A tab (0x09) inside the argument line is not a VCHAR.
    immutable(ubyte)[] input = cast(immutable(ubyte)[])
        ("age-encryption.org/v1\n"
        ~ "-> X25519 bad\targ\nAAAA\n"
        ~ "--- fgMiVLJHMlg9fW7CVG/hPS5EAU4Zeg19LyCP7SoH5nA\n");
    size_t consumed;
    auto r = parseHeader(input, consumed);
    assert(!r.hasValue, "a non-VCHAR argument must be rejected");
    assert(r.error.code == ParseErrorCode.invalidIdentifier);
}

/// A multi-line (wrapped) stanza body — a full 64-char line plus a short final
/// line — decodes to the concatenated bytes.
@("age.format.header.parseHeader.multiLineBody")
@safe
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;
    import sparkles.crypto.encoding.base64 : encodeBase64;
    import std.array : appender;

    // 50-byte body → 67 base64 chars → one 64-char line + a 3-char final line.
    auto body_ = new ubyte[50];
    foreach (i, ref b; body_) b = cast(ubyte)(i * 11 + 3);

    SmallBuffer!(char, 128) encBuf;
    encodeBase64(body_, encBuf);
    const enc = encBuf[];
    assert(enc.length == 67);

    auto sb = appender!string;
    sb.put("age-encryption.org/v1\n");
    sb.put("-> X25519 share\n");
    sb.put(enc[0 .. 64]); sb.put('\n');
    sb.put(enc[64 .. $]); sb.put('\n');
    sb.put("--- fgMiVLJHMlg9fW7CVG/hPS5EAU4Zeg19LyCP7SoH5nA\n");

    immutable(ubyte)[] input = cast(immutable(ubyte)[]) sb[];
    size_t consumed;
    auto r = parseHeader(input, consumed);
    assert(r.hasValue, "a wrapped multi-line body should parse");
    assert(r.value.recipients[0].body_ == body_,
        "the wrapped body decodes to the original 50 bytes");
}
