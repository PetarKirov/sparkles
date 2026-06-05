/**
The age recipient $(LREF Stanza) — the unit of the age header that wraps the
file key for a single recipient — plus its wire serializer.

A stanza is a section of the age header (§7.3 of `docs/specs/age/SPEC.md`):

    -> tag arg1 arg2
    <base64 body, wrapped at 64 columns, ending in a line < 64 chars>

This module is a faithful port of the `write` half of rage's
`age-core/src/format.rs` (`age_stanza` / `wrapped_encoded_data`). Decoding a
stanza body out of received header bytes is the parser's job (see
`sparkles.age.format.header`); here a $(LREF Stanza) already holds the
**decoded** binary `body_`, and $(LREF writeStanza) re-encodes it.

The wire grammar a stanza must obey:

$(UL
    $(LI The first line is `-> ` followed by the $(LREF Stanza.tag) and each of
        $(LREF Stanza.args), all SP-separated, then `LF`. The tag and every
        argument are an age "arbitrary string": `1*VCHAR`, i.e. one or more
        printable-ASCII bytes in the range `33 … 126`.)
    $(LI The body is **unpadded** standard base64 (see
        $(REF encodeBase64, sparkles,crypto,encoding,base64)) wrapped at
        **exactly** 64 columns. The body MUST always end with a line shorter
        than 64 characters — when the encoded length is a multiple of 64 (i.e.
        the raw body length is a multiple of 48), that final short line is an
        empty line.)
)

This layer may use the GC for the owned `string` / `ubyte[]` fields of an
owned $(LREF Stanza); the serializer itself allocates nothing beyond the
caller's output range.
*/
module sparkles.age.format.stanza;

import std.range.primitives : isOutputRange, put;

import sparkles.crypto.encoding.base64 : encodeBase64;

@safe:

/// The age stanza first-line prefix: `->` and a single space.
private enum string STANZA_TAG = "-> ";

/// The exact column at which a stanza body's base64 is wrapped (§7.3).
enum size_t STANZA_WRAP_COLUMNS = 64;

// ─────────────────────────────────────────────────────────────────────────────
// Stanza
// ─────────────────────────────────────────────────────────────────────────────

/**
A section of the age header that encapsulates the file key as encrypted to a
specific recipient — the owned analogue of rage's `Stanza`.

The $(LREF tag) names the stanza type (e.g. `"X25519"`, `"scrypt"`); it is the
first SP-separated token on the stanza's first line and is itself an age
"arbitrary string". $(LREF args) are the remaining first-line tokens. $(LREF
body_) is the **decoded** binary body — not the base64 text — so a freshly
built stanza carries the wrapped file-key bytes directly, and $(LREF
writeStanza) base64-encodes them on the way out.
*/
struct Stanza
{
    /// A tag identifying this stanza type (e.g. `"X25519"`). This is the first
    /// SP-separated argument on the stanza's first line.
    string tag;

    /// Zero or more SP-separated arguments following the tag.
    string[] args;

    /// The **decoded** binary body, holding the wrapped file key. Empty for a
    /// stanza whose body is the empty line.
    ubyte[] body_;

    /**
    Renders this stanza to its canonical age wire form into the output range
    `w` — exactly what $(LREF writeStanza) emits. `@safe`; `@nogc` when `w` is.

    See $(LREF writeStanza) for the precise format.
    */
    void toString(W)(ref W w) const
    if (isOutputRange!(W, const(char)[]))
    {
        writeStanza(w, this);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// arbitrary-string validation
// ─────────────────────────────────────────────────────────────────────────────

/**
Returns `true` iff `s` is a valid age "arbitrary string" — `1*VCHAR` in ABNF,
i.e. a non-empty sequence of printable-ASCII bytes with values `33 … 126`
(`'!'` through `'~'`, excluding SP and control bytes).

Ports rage's `is_arbitrary_string`. The stanza tag and every argument must
satisfy this; SP (`0x20`) is excluded because it separates the first-line
tokens.
*/
bool isArbitraryString(scope const(char)[] s) pure nothrow @nogc
{
    if (s.length == 0)
        return false;
    foreach (c; s)
        if (c < 33 || c > 126)
            return false;
    return true;
}

///
@("age.format.stanza.isArbitraryString.cases")
@safe pure nothrow @nogc
unittest
{
    assert(isArbitraryString("X25519"));
    assert(isArbitraryString("example.com/enigma"));
    assert(isArbitraryString("!"));               // lowest VCHAR
    assert(isArbitraryString("~"));               // highest VCHAR

    assert(!isArbitraryString(""));               // 1*VCHAR: non-empty
    assert(!isArbitraryString("has space"));      // SP (0x20) excluded
    assert(!isArbitraryString("tab\there"));      // control byte excluded
    assert(!isArbitraryString("\x7f"));           // DEL (127) excluded
}

// ─────────────────────────────────────────────────────────────────────────────
// writeStanza
// ─────────────────────────────────────────────────────────────────────────────

/**
Writes `s` to the output range `w` in canonical age wire form.

The serialization (a faithful port of rage's `write::age_stanza`):

$(OL
    $(LI the first line — `-> `, then $(D s.tag) and each of $(D s.args)
        separated by single spaces, then `\n`;)
    $(LI the body — $(D s.body_) re-encoded as **unpadded** standard base64 and
        wrapped at exactly $(LREF STANZA_WRAP_COLUMNS) (64) columns, with each
        full 64-character line followed by `\n`;)
    $(LI a final body line shorter than 64 characters, also `\n`-terminated.
        This final short line is **always** emitted: when the encoded body is a
        whole number of 64-column lines (raw body length a multiple of 48
        bytes, including an empty body), the final short line is an empty line.)
)

`@safe`, and `@nogc` when `w` is. Allocates nothing of its own. The caller is
responsible for `s.tag` / `s.args` being valid age arbitrary strings (see
$(LREF isArbitraryString)); this writer does not re-validate them.
*/
void writeStanza(W)(ref W w, in Stanza s)
if (isOutputRange!(W, const(char)[]))
{
    // First line: "-> " tag (SP arg)* "\n".
    put(w, STANZA_TAG);
    put(w, s.tag);
    foreach (arg; s.args)
    {
        put(w, ' ');
        put(w, arg);
    }
    put(w, '\n');

    // Body: unpadded base64, wrapped at exactly 64 columns. Each 48 raw bytes
    // encode to exactly 64 base64 characters — one full wrapped line — so the
    // body is streamed one 48-byte chunk at a time through a fixed `@nogc`
    // line buffer. This keeps the `@nogc` `encodeBase64` call driving a `@nogc`
    // sink regardless of whether the outer `w` allocates (e.g. an `Appender`):
    // routing the encoder straight into `w` would force `w.put` to be `@nogc`,
    // which an allocating range can never satisfy.
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    enum size_t BYTES_PER_LINE = 48;   // 48 raw bytes → 64 base64 chars
    size_t i = 0;
    for (; i + BYTES_PER_LINE <= s.body_.length; i += BYTES_PER_LINE)
    {
        SmallBuffer!(char, STANZA_WRAP_COLUMNS) line;
        encodeBase64(s.body_[i .. i + BYTES_PER_LINE], line);
        put(w, line[]);
        put(w, '\n');
    }

    // The mandatory trailing short line: the final chunk (< 48 bytes, possibly
    // empty) base64-encodes to < 64 characters and is always emitted with its
    // own `\n`. When the body is a whole number of full lines (its length a
    // multiple of 48, including the empty body), this final chunk is empty and
    // the lone `\n` forms the required empty final line.
    SmallBuffer!(char, STANZA_WRAP_COLUMNS) tail;
    encodeBase64(s.body_[i .. $], tail);
    put(w, tail[]);
    put(w, '\n');
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests
// ─────────────────────────────────────────────────────────────────────────────

/// A short single-line body needs no trailing empty line; with args it
/// round-trips its exact wire bytes. (rage's `parse_age_stanza` vector.)
@("age.format.stanza.writeStanza.singleShortLine")
@safe
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;
    import sparkles.crypto.encoding.base64 : decodeBase64, base64MaxDecodedLength;

    // "C3ZAeY64NXS4QFrksLm3EGz+uPRyI0eQsWw7LWbbYig" — 43 chars → 32 raw bytes.
    enum bodyB64 = "C3ZAeY64NXS4QFrksLm3EGz+uPRyI0eQsWw7LWbbYig";
    ubyte[base64MaxDecodedLength(bodyB64.length)] raw = void;
    auto dec = decodeBase64(bodyB64, raw[]);
    assert(dec.hasValue);

    auto s = Stanza(
        "X25519",
        ["CJM36AHmTbdHSuOQL+NESqyVQE75f2e610iRdLPEN20"],
        dec.value.dup,
    );

    // 43 < 64, so the single body line is itself the final short line.
    checkToString(s,
        "-> X25519 CJM36AHmTbdHSuOQL+NESqyVQE75f2e610iRdLPEN20\n"
        ~ "C3ZAeY64NXS4QFrksLm3EGz+uPRyI0eQsWw7LWbbYig\n");
}

/// An empty body is represented by an empty final line (rage's
/// `age_stanza_with_empty_body`). Multiple args are SP-separated.
@("age.format.stanza.writeStanza.emptyBody")
@safe
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    auto s = Stanza("empty-body", ["some", "arguments"], []);

    // Body is empty → one empty final line.
    checkToString(s, "-> empty-body some arguments\n\n");
}

/// A body whose base64 fills exactly one 64-column line (raw length a multiple
/// of 48 bytes) requires a trailing empty final line (rage's
/// `age_stanza_with_full_body`).
@("age.format.stanza.writeStanza.fullLineGetsEmptyFinalLine")
@safe
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;
    import sparkles.crypto.encoding.base64 : decodeBase64, base64MaxDecodedLength;

    // 64 base64 chars → 48 raw bytes (48 * 8 / 6 == 64).
    enum bodyB64 =
        "xD7o4VEOu1t7KZQ1gDgq2FPzBEeSRqbnqvQEXdLRYy143BxR6oFxsUUJCRB0ErXA";
    static assert(bodyB64.length == 64);

    ubyte[base64MaxDecodedLength(bodyB64.length)] raw = void;
    auto dec = decodeBase64(bodyB64, raw[]);
    assert(dec.hasValue);
    assert(dec.value.length == 48);

    auto s = Stanza("full-body", ["some", "arguments"], dec.value.dup);

    checkToString(s,
        "-> full-body some arguments\n"
        ~ bodyB64 ~ "\n"     // the full 64-column line
        ~ "\n");             // the mandatory empty final line
}

/// A body spanning more than one line: a full 64-column line, then a short
/// final line. Verifies the wrap point is exactly 64.
@("age.format.stanza.writeStanza.wrapsAtExactly64")
@safe
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    // 50 bytes → 67 base64 chars (50 * 8 / 6 == 66.7 → 67): one full 64-char
    // line plus a 3-char short final line.
    ubyte[50] body_ = void;
    foreach (i, ref b; body_)
        b = cast(ubyte) i;

    import sparkles.core_cli.smallbuffer : SmallBuffer;
    import sparkles.crypto.encoding.base64 : encodeBase64;

    SmallBuffer!(char, 128) encBuf;
    encodeBase64(body_[], encBuf);
    const enc = encBuf[];
    assert(enc.length == 67);

    auto s = Stanza("wrap", [], body_.dup);

    checkToString(s,
        "-> wrap\n"
        ~ enc[0 .. 64] ~ "\n"
        ~ enc[64 .. $] ~ "\n");
}

/// A tag with no arguments writes just `-> tag\n` on the first line.
@("age.format.stanza.writeStanza.tagOnly")
@safe
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    auto s = Stanza("lone", [], []);
    checkToString(s, "-> lone\n\n");
}

/// A body that is a multiple of 48 bytes but spans several full lines still
/// terminates with an empty final line.
@("age.format.stanza.writeStanza.multipleFullLinesEmptyFinal")
@safe
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString, SmallBuffer;
    import sparkles.crypto.encoding.base64 : encodeBase64;

    // 96 bytes → 128 base64 chars → exactly two 64-column lines, then an empty
    // final line.
    ubyte[96] body_ = void;
    foreach (i, ref b; body_)
        b = cast(ubyte)(i * 7 + 1);

    SmallBuffer!(char, 256) encBuf;
    encodeBase64(body_[], encBuf);
    const enc = encBuf[];
    assert(enc.length == 128);

    auto s = Stanza("two-lines", ["a"], body_.dup);

    checkToString(s,
        "-> two-lines a\n"
        ~ enc[0 .. 64] ~ "\n"
        ~ enc[64 .. 128] ~ "\n"
        ~ "\n");
}

/// `writeStanza` works against a `@nogc` `SmallBuffer` output range, and
/// `Stanza.toString` agrees with it. Both paths render via $(LREF checkWriter)
/// so the whole test stays `@safe pure nothrow @nogc`.
@("age.format.stanza.writeStanza.nogcSmallBuffer")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkWriter;

    ubyte[3] body_ = [0x00, 0x01, 0x02];   // "AAEC" — 4 chars, single short line
    // A stack-allocated static array sliced into `args` keeps the test `@nogc`
    // (a `["arg"]` dynamic-array literal would GC-allocate).
    string[1] args = ["arg"];
    auto s = Stanza("X25519", args[], body_[]);

    enum wire = "-> X25519 arg\nAAEC\n";

    // Free-function writer and the struct's toString must produce the same bytes.
    checkWriter!((ref b) => writeStanza(b, s))(wire);
    checkWriter!((ref b) => s.toString(b))(wire);
}
