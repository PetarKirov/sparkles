/**
 * High-performance string, comment, brace-matching, and delimiter scanning utilities.
 *
 * Every function here is `@safe pure nothrow @nogc` — the writer-based ones by
 * inference, given a writer that is — so the module compiles under `-betterC`
 * and the whole set is usable for zero-allocation lexical scanning across
 * tools, compilers, and test frameworks. A caller that needs a
 * garbage-collected string builds one at its own boundary; nothing here
 * allocates on its behalf.
 */
module sparkles.base.text.scan;

import sparkles.test_runner.attributes : betterC;

/// The byte offset where line `line` (1-based) starts in `source`.
size_t lineOffset(scope const(char)[] source, size_t line) @safe pure nothrow @nogc
{
    if (line <= 1)
        return 0;
    size_t current = 1;
    foreach (i, c; source)
    {
        if (c == '\n')
        {
            current++;
            if (current >= line)
                return i + 1;
        }
    }
    return source.length;
}

/// Whether character `c` is an ASCII identifier character (`[a-zA-Z0-9_]`).
bool isIdentChar(char c) @safe pure nothrow @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_';
}

/// Advances past a comment starting at `i` (which points at `/`), or one
/// character when it is a lone slash. Handles line comments `//`, block
/// comments `/* */`, and nesting block comments `/+ +/`.
size_t skipComment(scope const(char)[] source, size_t i) @safe pure nothrow @nogc
{
    if (i + 1 >= source.length)
        return i + 1;
    switch (source[i + 1])
    {
        case '/':
            i += 2;
            while (i < source.length && source[i] != '\n')
                i++;
            return i;
        case '*':
            i += 2;
            while (i + 1 < source.length && !(source[i] == '*' && source[i + 1] == '/'))
                i++;
            return i + 2 <= source.length ? i + 2 : source.length;
        case '+':
            i += 2;
            size_t depth = 1;
            while (i + 1 < source.length && depth > 0)
            {
                if (source[i] == '/' && source[i + 1] == '+')
                {
                    depth++;
                    i += 2;
                }
                else if (source[i] == '+' && source[i + 1] == '/')
                {
                    depth--;
                    i += 2;
                }
                else
                    i++;
            }
            return i <= source.length ? i : source.length;
        default:
            return i + 1;
    }
}

/// Advances past a string/character literal starting at `i` (which points at
/// the opening `quote`).
size_t skipString(scope const(char)[] source, size_t i, char quote, bool escapes)
@safe pure nothrow @nogc
{
    i++;
    while (i < source.length)
    {
        if (escapes && source[i] == '\\')
            i += 2;
        else if (source[i] == quote)
            return i + 1;
        else
            i++;
    }
    return source.length;
}

/// Advances past a delimited string literal `q"…"` starting at `i` (which
/// points at the quote after the `q`). Handles the nesting bracket delimiters
/// (`()`, `[]`, `{}`, `<>`), identifier (heredoc) delimiters
/// (`q"EOS … EOS"`), and single-character punctuation delimiters (`q"/…/"`).
size_t skipDelimitedString(scope const(char)[] source, size_t i) @safe pure nothrow @nogc
{
    i++; // past the opening quote
    if (i >= source.length)
        return i;
    const d = source[i];

    char closer = 0;
    switch (d)
    {
        case '(': closer = ')'; break;
        case '[': closer = ']'; break;
        case '{': closer = '}'; break;
        case '<': closer = '>'; break;
        default: break;
    }
    if (closer)
    {
        i++;
        size_t depth = 1;
        while (i < source.length && depth)
        {
            if (source[i] == d)
                depth++;
            else if (source[i] == closer)
                depth--;
            i++;
        }
        return i < source.length && source[i] == '"' ? i + 1 : i;
    }

    if (isIdentChar(d) && !(d >= '0' && d <= '9'))
    {
        // Heredoc: q"IDENT … up to a line starting with IDENT"
        const start = i;
        while (i < source.length && isIdentChar(source[i]))
            i++;
        const ident = source[start .. i];
        while (i < source.length)
        {
            if (source[i] == '\n'
                && i + 1 + ident.length < source.length
                && source[i + 1 .. i + 1 + ident.length] == ident
                && source[i + 1 + ident.length] == '"')
                return i + 2 + ident.length;
            i++;
        }
        return source.length;
    }

    // Single punctuation delimiter: ends at delimiter followed by quote
    i++;
    while (i + 1 < source.length)
    {
        if (source[i] == d && source[i + 1] == '"')
            return i + 2;
        i++;
    }
    return source.length;
}

/// The index of the `}` matching the `{` at `open`, skipping comments and
/// string/character literals; `size_t.max` when unbalanced.
size_t matchingBrace(scope const(char)[] source, size_t open) @safe pure nothrow @nogc
in (open < source.length && source[open] == '{', "open must point at '{'")
{
    size_t depth = 0;
    for (size_t i = open; i < source.length;)
    {
        const c = source[i];
        switch (c)
        {
            case '{':
                depth++;
                i++;
                break;
            case '}':
                depth--;
                if (depth == 0)
                    return i;
                i++;
                break;
            case '/':
                i = skipComment(source, i);
                break;
            case '"':
                if (i > 0 && source[i - 1] == 'q'
                    && (i < 2 || !isIdentChar(source[i - 2])))
                    i = skipDelimitedString(source, i);
                else
                    i = skipString(source, i, '"',
                        escapes: !(i > 0 && (source[i - 1] == 'r' || source[i - 1] == 'x')));
                break;
            case '`':
                i = skipString(source, i, '`', escapes: false);
                break;
            case '\'':
                i = skipString(source, i, '\'', escapes: true);
                break;
            default:
                i++;
        }
    }
    return size_t.max;
}

/**
Writes `value` to `writer` as a double-quoted string literal, escaping `\` and
`"` — the two characters whose escaping rules D and JavaScript share.

Takes an output range rather than returning a string so the escaping stays
allocation-free and usable from `@nogc` and `-betterC` code; render into a
$(REF SmallBuffer, sparkles,base,smallbuffer) and `idup` the result at the one
boundary that needs a garbage-collected string:
---
SmallBuffer!(char, 256) buf;
buf.putQuotedStringLiteral(path);
string literal = buf[].idup;
---

$(B Not a general escaper.) Only `\` and `"` are escaped, so a control
character in `value` is emitted raw. That is legal in a D string literal but
not in JSON, whose grammar forbids a literal newline inside a string.

Params:
    writer = Output range of `char` receiving the quoted literal.
    value  = Text to quote; emitted between the delimiters.
*/
void putQuotedStringLiteral(Writer)(ref Writer writer, scope const(char)[] value)
{
    writer.put('"');
    foreach (char c; value)
    {
        if (c == '\\' || c == '"')
            writer.put('\\');
        writer.put(c);
    }
    writer.put('"');
}

@("text.scan.lineOffset")
@betterC
unittest
{
    enum src = "line1\nline2\nline3\n";
    assert(lineOffset(src, 1) == 0);
    assert(lineOffset(src, 2) == 6);
    assert(lineOffset(src, 3) == 12);
    assert(lineOffset(src, 4) == 18);
    assert(lineOffset(src, 100) == 18);
}

@("text.scan.matchingBrace")
@betterC
unittest
{
    enum src = `{ int x = 1; { int y = 2; } /* { */ }`;
    assert(matchingBrace(src, 0) == src.length - 1);
    assert(matchingBrace(src, 13) == 26);
}

@("text.scan.delimitedString")
@betterC
unittest
{
    enum src = `{ auto s = q"(} unbalanced )"; return 1; }`;
    assert(matchingBrace(src, 0) == src.length - 1);
}

@("text.scan.putQuotedStringLiteral")
@betterC
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : checkWriter;

    checkWriter!((ref b) => b.putQuotedStringLiteral(`hello "world" \`))(
        `"hello \"world\" \\"`);
    checkWriter!((ref b) => b.putQuotedStringLiteral(""))(`""`);
}
