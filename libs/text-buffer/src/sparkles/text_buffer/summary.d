/**
The measures every node of a text's tree caches for its subtree.

A measure is additive under concatenation, so a node's summary is the sum
of its children's and a position can be located by descending the tree.
Malformed UTF-8 counts as the replacement characters `UtfMode.replacement`
reads: one scalar and one UTF-16 unit per maximal subpart.

Specification: `docs/specs/text-buffer/SPEC.md` (TXB-TEXT4, TXB-OWN4).
*/
module sparkles.text_buffer.summary;

import sparkles.base.text.utf : UtfMode, decodeToken;

/// Which side of an ambiguous boundary a position belongs to.
enum Affinity : ubyte
{
    before,
    after,
}

/// The measures of a byte sequence.
struct TextSummary
{
    size_t bytes;
    size_t scalars;
    size_t utf16;
    size_t lineFeeds;
    /// Bytes after the last line feed: the length of the last line.
    size_t lastLineBytes;

    /// The summary of the concatenation `this ~ rhs`.
    TextSummary opBinary(string op : "~")(in TextSummary rhs) const
        @safe pure nothrow @nogc
        => TextSummary(bytes + rhs.bytes, scalars + rhs.scalars, utf16 + rhs.utf16,
            lineFeeds + rhs.lineFeeds,
            rhs.lineFeeds ? rhs.lastLineBytes : lastLineBytes + rhs.bytes);
}

/// One decoded token: a scalar, or U+FFFD for a malformed maximal subpart.
package struct Token
{
    dchar scalar;
    size_t length;
}

/// Decode the token at the start of `bytes`, which must not be empty.
package Token tokenAt(scope const(char)[] bytes) @safe pure nothrow @nogc
in (bytes.length, "no token in an empty slice")
{
    if (bytes[0] < 0x80)
        return Token(bytes[0], 1);
    const decoded = decodeToken(bytes[0 .. bytes.length < 4 ? bytes.length : 4],
        UtfMode.replacement);
    return Token(decoded.token.scalar, decoded.result.consumed);
}

/// UTF-16 code units of a token's scalar.
package size_t utf16Units(dchar scalar) @safe pure nothrow @nogc => scalar >= 0x10000 ? 2 : 1;

/// The measures of `bytes`, which must start at a token boundary.
TextSummary measure(scope const(char)[] bytes) @safe pure nothrow @nogc
{
    TextSummary summary;
    summary.bytes = bytes.length;
    size_t lastFeed = size_t.max;
    for (size_t i; i < bytes.length;)
    {
        const token = tokenAt(bytes[i .. $]);
        ++summary.scalars;
        summary.utf16 += utf16Units(token.scalar);
        if (token.scalar == '\n')
        {
            ++summary.lineFeeds;
            lastFeed = i;
        }
        i += token.length;
    }
    summary.lastLineBytes = lastFeed == size_t.max ? bytes.length : bytes.length - lastFeed - 1;
    return summary;
}

///
@("summary.measure.mixed")
@safe pure nothrow @nogc
unittest
{
    const s = measure("aé\n\U0001F600\xE0\xA0x");
    assert(s.bytes == 11);
    assert(s.scalars == 6, "the truncated E0 A0 is one replacement scalar");
    assert(s.utf16 == 7, "the emoji takes a surrogate pair");
    assert(s.lineFeeds == 1 && s.lastLineBytes == 7);
}

/// Concatenation adds the measures and keeps the last line's length right.
@("summary.concatenation")
@safe pure nothrow @nogc
unittest
{
    static immutable string[] parts = ["ab\ncd", "ef", "\n", "gé\nh", ""];
    foreach (i; 0 .. parts.length)
        foreach (j; 0 .. parts.length)
        {
            char[32] joined;
            const n = parts[i].length + parts[j].length;
            joined[0 .. parts[i].length] = parts[i];
            joined[parts[i].length .. n] = parts[j];
            assert((measure(parts[i]) ~ measure(parts[j])) == measure(joined[0 .. n]));
        }
}
