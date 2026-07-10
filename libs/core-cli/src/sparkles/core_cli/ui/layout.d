/++
Horizontal composition of pre-rendered blocks: `hjoin` zips the lines of
several multi-line strings side by side (top-aligned), padding every line of a
block to that block's visible width so columns stay straight — boxes next to
tables next to plain text, ANSI styling and all.
+/
module sparkles.core_cli.ui.layout;

/// Join `blocks` (each a rendered multi-line string) side by side with `gap`
/// spaces between columns. Blocks are top-aligned; a block shorter than the
/// tallest one contributes blank space below. Trailing whitespace on each
/// output line is trimmed. Empty input yields an empty string.
string hjoin(const(string)[] blocks, size_t gap = 2) @safe
{
    import std.algorithm.comparison : max;
    import std.algorithm.iteration : map;
    import std.array : appender, array;
    import std.string : splitLines;
    import sparkles.base.text.grapheme : visibleWidth;
    import sparkles.base.text.width : Align, alignField;

    if (blocks.length == 0)
        return "";

    auto columns = blocks.map!(b => b.splitLines).array;
    size_t[] widths;
    size_t height = 0;
    foreach (col; columns)
    {
        size_t w = 0;
        foreach (line; col)
            w = max(w, visibleWidth(line));
        widths ~= w;
        height = max(height, col.length);
    }

    auto out_ = appender!string;
    foreach (row; 0 .. height)
    {
        auto line = appender!string;
        foreach (c, col; columns)
        {
            if (c)
                foreach (_; 0 .. gap)
                    line.put(' ');
            alignField(line, row < col.length ? col[row] : "", widths[c], Align.left);
        }
        out_ ~= stripTrailing(line[]);
        if (row + 1 < height)
            out_ ~= '\n';
    }
    return out_[];
}

/// Trim trailing spaces (never touching ANSI escapes mid-line: only the plain
/// right-pad `alignField` appended can trail).
private string stripTrailing(string s) @safe pure nothrow @nogc
{
    size_t end = s.length;
    while (end > 0 && s[end - 1] == ' ')
        end--;
    return s[0 .. end];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("layout.hjoin.zipsAndPads")
@safe unittest
{
    const left = "aa\nb";
    const right = "XXX\nYY\nZ";
    assert(hjoin([left, right]) ==
        "aa  XXX\n" ~
        "b   YY\n" ~
        "    Z");
}

@("layout.hjoin.gapAndDegenerates")
@safe unittest
{
    assert(hjoin([]) == "");
    assert(hjoin(["solo\nblock"]) == "solo\nblock");
    assert(hjoin(["a", "b"], 0) == "ab");
    assert(hjoin(["a", "b"], 4) == "a    b");
}

@("layout.hjoin.ansiTransparentWidths")
@safe unittest
{
    import sparkles.base.term_style : Style, stylize;

    // The styled label is 2 visible cells; the column is padded by visible
    // width, so the plain second row lines up under it.
    const styled = "ok".stylize(Style.green) ~ "\nxx";
    const joined = hjoin([styled, "R"]);
    assert(joined ==
        "ok".stylize(Style.green) ~ "  R\n" ~
        "xx");
}
