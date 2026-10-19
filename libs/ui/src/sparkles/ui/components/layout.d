/++
Horizontal composition of pre-rendered blocks: `hjoin` zips the lines of
several multi-line strings side by side (top-aligned), padding every line of a
block to that block's visible width so columns stay straight — boxes next to
tables next to plain text, ANSI styling and all.
+/
module sparkles.ui.components.layout;

import sparkles.base.buffer : SharedBuffer;

/// `hjoin` for blocks that write themselves (`drawBox(…)`, `drawTable(…)`): each
/// is rendered, then joined.
string hjoin(Block)(const(Block)[] blocks, size_t gap = 2)
if (imported!"sparkles.base.text.value_form".isWritableValue!Block)
{
    import std.algorithm.iteration : map;
    import std.array : array;

    return hjoin(blocks.map!(b => b.toString).array, gap);
}

/// `hjoin` over blocks of mixed kinds, each a string or a value that writes
/// itself, joined with the default gap: `hjoin(drawBox(…), drawTable(…), "notes")`.
string hjoin(Blocks...)(Blocks blocks)
if (Blocks.length > 1 && isBlockList!Blocks)
{
    import std.conv : text;

    auto rendered = new string[Blocks.length];
    static foreach (i; 0 .. Blocks.length)
        rendered[i] = text(blocks[i]);
    return hjoin(rendered);
}

private template isBlockList(Blocks...)
{
    import std.meta : allSatisfy;

    enum isBlock(T) = is(T : const(char)[])
        || imported!"sparkles.base.text.value_form".isWritableValue!T;
    enum isBlockList = allSatisfy!(isBlock, Blocks);
}

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
        SharedBuffer!(char, 256) line;
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
private const(char)[] stripTrailing(return scope const(char)[] s) @safe pure nothrow @nogc
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

/// Aligned label/value lines without a frame (a key-value list): every label is
/// padded to the widest one (by visible width, so styled labels align), then
/// `gap` spaces, then the value verbatim. Feed the result to `drawBox` for a
/// framed receipt, or print it bare.
string[] kvList(in string[2][] pairs, size_t gap = 2) @safe
{
    import std.algorithm.comparison : max;
    import std.array : appender;
    import sparkles.base.text.grapheme : visibleWidth;
    import sparkles.base.text.width : Align, alignField;

    size_t labelWidth = 0;
    foreach (ref pair; pairs)
        labelWidth = max(labelWidth, visibleWidth(pair[0]));

    string[] lines;
    lines.reserve(pairs.length);
    foreach (ref pair; pairs)
    {
        auto w = appender!string;
        alignField(w, pair[0], labelWidth, Align.left);
        foreach (_; 0 .. gap)
            w.put(' ');
        w.put(pair[1]);
        lines ~= w[];
    }
    return lines;
}

@("layout.kvList.alignsLabels")
@safe unittest
{
    assert(kvList([["tag", "v0.1.0"], ["subject", "v0.1.0 — first"]]) == [
        "tag      v0.1.0",
        "subject  v0.1.0 — first",
    ]);
    assert(kvList([["a", "1"]], 4) == ["a    1"]);
    assert(kvList([]) == cast(string[]) []);
}

@("layout.hjoin.writableBlocks")
@safe unittest
{
    import sparkles.ui.components.box : drawBox;

    const joined = hjoin([drawBox(["a"], "x"), drawBox(["b"], "y")]);
    assert(joined == hjoin(drawBox(["a"], "x"), drawBox(["b"], "y")));
    // Mixed kinds, side by side.
    assert(hjoin(drawBox(["a"], "x"), "notes")
        == hjoin([drawBox(["a"], "x").toString, "notes"]));
}
