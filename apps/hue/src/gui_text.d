// Pure viewport/search layout logic for `hue --gui` — hue-specific (the
// terminal has no gutter/search), so it stays in the app rather than the shared
// sparkles:raylib-text library. Deliberately raylib-free so `dub test :hue`
// exercises it with no GL context and no native raylib (the library, which
// links raylib, is not a test-config dependency). Compiled in every hue config
// except `application`.
//
// `columnWidth` is a small, self-contained copy of the same monospace metric
// the library owns; duplicating four lines keeps hue's tests off the raylib
// dependency, which is the right trade for the coupling it avoids.
module gui_text;

@safe:

/// The monospace column width of a UTF-8 run: the number of codepoints (each
/// non-continuation byte begins one). Keeps runs and match highlights on a
/// fixed grid. Combining marks / wide / tab characters count as one column (v1).
size_t columnWidth(scope const(char)[] run) pure nothrow @nogc
{
    size_t cols;
    foreach (ubyte c; run)
        if ((c & 0xC0) != 0x80) // not a UTF-8 continuation byte
            ++cols;
    return cols;
}

///
@("gui_text.columnWidth.codepoints")
pure nothrow @nogc
unittest
{
    assert(columnWidth("") == 0);
    assert(columnWidth("main()") == 6);
    assert(columnWidth("  int") == 5);
    assert(columnWidth("a\u2192b") == 3); // '\u2192' is one 3-byte codepoint
    assert(columnWidth("\u00e9") == 1);    // precomposed \u00e9: one codepoint
    assert(columnWidth("e\u0301") == 2);   // decomposed: base + combining mark
}

/// The number of display lines in `source`, matching `byStyledLine`'s line
/// indexing: one per `\n`, plus a final line for trailing content. A trailing
/// newline does not add an empty last line; empty source is zero lines. Drives
/// viewport clamping, the gutter, and the scrollbar.
size_t lineCount(scope const(char)[] source) pure nothrow @nogc
{
    if (source.length == 0)
        return 0;
    size_t n;
    foreach (c; source)
        if (c == '\n')
            ++n;
    if (source[$ - 1] != '\n')
        ++n;
    return n;
}

///
@("gui_text.lineCount.conventions")
pure nothrow @nogc
unittest
{
    assert(lineCount("") == 0);
    assert(lineCount("a") == 1);
    assert(lineCount("a\n") == 1); // trailing newline is not an extra line
    assert(lineCount("a\nb") == 2);
    assert(lineCount("a\nb\n") == 2);
    assert(lineCount("\n") == 1);
    assert(lineCount("\n\n") == 2);
}

/// A search hit resolved to monospace grid coordinates for drawing.
struct Match
{
    size_t line; /// 0-based line the match starts on
    int col;     /// start column (display cells) within the line
    int cols;    /// width in display cells (clipped at the line end)
}

/// Byte offset where each display line starts (line 0 at 0, then after each
/// `\n`). Sorted ascending, so a byte offset's line is a binary search away.
size_t[] buildLineStarts(scope const(char)[] source)
{
    size_t[] starts = [0];
    foreach (i, c; source)
        if (c == '\n')
            starts ~= i + 1;
    return starts;
}

/// All non-overlapping occurrences of `query` in `source`, each mapped to grid
/// coordinates (line/col/width in display cells) via `lineStarts` — the extra
/// decoration layer the GUI tints over the styled spans. A match spanning a
/// newline is clipped to its first line. Empty query → no matches.
Match[] findMatches(scope const(char)[] source, scope const(char)[] query,
    scope const(size_t)[] lineStarts)
{
    import std.string : indexOf;
    import std.range : assumeSorted;

    Match[] matches;
    if (query.length == 0)
        return matches;

    size_t from;
    while (from <= source.length)
    {
        const rel = source[from .. $].indexOf(query);
        if (rel < 0)
            break;
        const start = from + cast(size_t) rel;
        const line = lineStarts.assumeSorted.lowerBound(start + 1).length - 1;
        const lineStart = lineStarts[line];
        const nl = source[start .. $].indexOf('\n');
        const end = nl < 0 || cast(size_t) nl >= query.length
            ? start + query.length : start + cast(size_t) nl;
        matches ~= Match(line, cast(int) columnWidth(source[lineStart .. start]),
            cast(int) columnWidth(source[start .. end]));
        from = start + query.length;
    }
    return matches;
}

///
@("gui_text.findMatches.locatesAndMaps")
unittest
{
    const src = "ab\n  abc\nx";      // line 0 "ab", line 1 "  abc", line 2 "x"
    const ls = buildLineStarts(src); // [0, 3, 9]

    auto m = findMatches(src, "ab", ls);
    assert(m.length == 2);
    assert(m[0] == Match(0, 0, 2));  // first "ab" at line 0, column 0
    assert(m[1] == Match(1, 2, 2));  // "ab" inside "abc" at line 1, column 2

    assert(findMatches(src, "zzz", ls).length == 0);
    assert(findMatches(src, "", ls).length == 0);

    const dots = "....";
    assert(findMatches(dots, "..", buildLineStarts(dots)).length == 2);
}
