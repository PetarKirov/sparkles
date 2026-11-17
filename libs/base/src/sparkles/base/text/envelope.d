/**
A text file's envelope: the bytes around its text that an editor must keep
but must not show. A UTF-8 byte-order mark is held apart from the content, so
it cannot become an editable glyph, and the file's predominant line ending is
recorded, so a new line can follow the file's convention. The content bytes
themselves, mixed endings included, are never normalized.
*/
module sparkles.base.text.envelope;

import sparkles.base.expected : Expected, err, ok;
import sparkles.base.text.utf8 : validateUtf8;

/// A line ending a new line can be given.
enum LineEnding : ubyte
{
    /// `\n`.
    lf,
    /// `\r\n`.
    crlf,
}

/// The bytes of `ending`.
string lineEndingText(LineEnding ending) @safe pure nothrow @nogc
    => ending == LineEnding.crlf ? "\r\n" : "\n";

/// The ending whose bytes are `bytes`, or `fallback` when they are neither.
LineEnding lineEndingOf(scope const(char)[] bytes, LineEnding fallback = LineEnding.lf)
    @safe pure nothrow @nogc
    => bytes == "\r\n" ? LineEnding.crlf : bytes == "\n" ? LineEnding.lf : fallback;

///
@("text.envelope.lineEndingText")
@safe pure nothrow @nogc unittest
{
    assert(lineEndingText(LineEnding.crlf) == "\r\n" && lineEndingText(LineEnding.lf) == "\n");
    assert(lineEndingOf("\r\n") == LineEnding.crlf && lineEndingOf("\n") == LineEnding.lf);
    assert(lineEndingOf("\r", LineEnding.crlf) == LineEnding.crlf);
}

/// The UTF-8 byte-order mark.
enum string utf8Bom = "\xEF\xBB\xBF";

/// A text file split into its editable content and its envelope.
struct TextEnvelope
{
    /// The bytes after any byte-order mark, exactly as stored.
    string content;
    /// The file began with a UTF-8 byte-order mark.
    bool bom;
    /// The ending most of the content's lines use; `lf` on a tie or without lines.
    LineEnding predominant;
}

/**
Split `bytes` into content and envelope. Fails when `bytes` is not valid
UTF-8; the content is a slice of `bytes`, not a copy.
*/
Expected!TextEnvelope decodeEnvelope(return scope string bytes) @safe pure nothrow @nogc
{
    if (validateUtf8(bytes).hasError) return err!TextEnvelope("The text is not valid UTF-8.");
    TextEnvelope result;
    result.bom = bytes.length >= utf8Bom.length && bytes[0 .. utf8Bom.length] == utf8Bom;
    result.content = result.bom ? bytes[utf8Bom.length .. $] : bytes;
    size_t lf, crlf;
    foreach (i, char c; result.content)
        if (c == '\n')
        {
            if (i && result.content[i - 1] == '\r') ++crlf;
            else ++lf;
        }
    result.predominant = crlf > lf ? LineEnding.crlf : LineEnding.lf;
    return ok(result);
}

/// The file bytes of `envelope`: its mark, if any, then the content unchanged.
string encodeEnvelope(TextEnvelope envelope) @safe pure nothrow
    => envelope.bom ? utf8Bom ~ envelope.content : envelope.content;

/// The mark and mixed endings survive a round trip; invalid UTF-8 is refused.
@("text.envelope.roundTrip")
@safe pure nothrow unittest
{
    const decoded = decodeEnvelope(utf8Bom ~ "first\r\nsecond\nlast\r\n");
    assert(decoded.hasValue && decoded.value.bom);
    assert(decoded.value.content == "first\r\nsecond\nlast\r\n");
    assert(decoded.value.predominant == LineEnding.crlf);
    assert(encodeEnvelope(decoded.value) == utf8Bom ~ "first\r\nsecond\nlast\r\n");
    assert(decodeEnvelope("bad\xff").hasError);
    assert(decodeEnvelope("").value.predominant == LineEnding.lf);
    assert(decodeEnvelope("a\r\nb\n").value.predominant == LineEnding.lf, "a tie is LF");
}

/**
The ending a new line inserted at `position` takes: the ending of the line
holding `position`, when that line has one, else `predominant`.

`text` is any line-indexed text: it has `length`, `lineOf(position)`,
`lineEnd(line)` (the byte offset of the line's break, or `length` on the last
line) and `byteAt(offset)`, as `sparkles.text_buffer.text.Text` does.
*/
LineEnding enterEnding(T)(in T text, size_t position, LineEnding predominant)
if (is(typeof(text.lineEnd(text.lineOf(position))) : size_t) && is(typeof(text.byteAt(position)) : char))
{
    const length = text.length;
    const end = text.lineEnd(text.lineOf(position < length ? position : length));
    if (end < length)
    {
        if (text.byteAt(end) == '\r' && end + 1 < length && text.byteAt(end + 1) == '\n')
            return LineEnding.crlf;
        if (text.byteAt(end) == '\n') return LineEnding.lf;
    }
    return predominant;
}

/// The current line's ending wins over the predominant one.
@("text.envelope.enterEnding")
@safe pure nothrow @nogc unittest
{
    static struct Lines
    {
        string bytes;
        size_t length() const @safe pure nothrow @nogc => bytes.length;
        char byteAt(size_t at) const @safe pure nothrow @nogc => bytes[at];
        size_t lineOf(size_t at) const @safe pure nothrow @nogc
        {
            size_t line;
            foreach (c; bytes[0 .. at]) if (c == '\n') ++line;
            return line;
        }
        size_t lineEnd(size_t line) const @safe pure nothrow @nogc
        {
            size_t at;
            for (; at < bytes.length; ++at)
                if (bytes[at] == '\n' || (bytes[at] == '\r' && at + 1 < bytes.length && bytes[at + 1] == '\n'))
                {
                    if (!line) return at;
                    --line;
                    if (bytes[at] == '\r') ++at;
                }
            return bytes.length;
        }
    }
    const text = Lines("first\r\nsecond\nlast");
    assert(enterEnding(text, 3, LineEnding.lf) == LineEnding.crlf);
    assert(enterEnding(text, 9, LineEnding.crlf) == LineEnding.lf);
    assert(enterEnding(text, text.length, LineEnding.crlf) == LineEnding.crlf);
    assert(enterEnding(Lines(""), 0, LineEnding.lf) == LineEnding.lf);
}
