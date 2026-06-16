module sparkles.core_cli.term_unstyle;

import sparkles.base.text.ansi : byAnsiToken;
import sparkles.base.text.grapheme : visibleWidth;

@safe:

/// Returns `s` with every ANSI/VT escape sequence removed (CSI/SGR, OSC
/// including OSC 8 hyperlinks, DCS/SOS/PM/APC, …). Built on the shared escape
/// scanner in `sparkles.base.text.ansi`, so stripping and width measurement
/// always agree (the old regex only matched CSI + OSC 8).
string unstyle(in char[] s) pure nothrow
{
    import std.array : appender;

    auto a = appender!string;
    foreach (t; s.byAnsiToken)
        if (!t.isEscape)
            a ~= t.slice;
    return a[];
}

version (unittest)
{
    import std.traits : EnumMembers;
    import sparkles.base.term_style : Style, stylize;

    alias Seq(T...) = T;

    alias nonColorStyles = Seq!(Style.bold, Style.dim, Style.italic,
        Style.underline, Style.inverse, Style.strikethrough);
    static immutable colorStyles = [EnumMembers!Style[9 .. $]];

    @safe string[] styleInAllPossibleWays(string text)
    {
        string[] table;
        foreach (i, color; colorStyles)
            static foreach (j; 0 .. nonColorStyles.length)
                table ~= text
                    .stylize(nonColorStyles[j])
                    .stylize(color);
        return table;
    }
}

unittest
{
    import sparkles.base.term_style : stylizedTextBuilder;

    const styledText = "Format me"
        .stylizedTextBuilder
        .bold
        .underline
        .bgWhite
        .italic
        .blue
        .strikethrough;

    assert(
        styledText ==
        "\x1B[9m\x1B[34m\x1B[3m\x1B[47m\x1B[4m\x1B[1mFormat me\x1B[22m\x1B[24m\x1B[49m\x1B[23m\x1B[39m\x1B[29m"
    );

    assert(styledText.payload.unstyle == "Format me");

    const text = "42";
    const table = styleInAllPossibleWays(text);

    foreach (el; table)
        assert(el.unstyle == text);
}

/// OSC 8 hyperlink with BEL terminator is stripped.
@("unstyle.oscLink.basic")
@safe unittest
{
    const link = "\x1b]8;;https://example.com\x07Click\x1b]8;;\x07";
    assert(link.unstyle == "Click");
}

/// OSC 8 hyperlink with ST terminator is stripped.
@("unstyle.oscLink.withST")
@safe unittest
{
    const link = "\x1b]8;;https://example.com\x1b\\Click\x1b]8;;\x1b\\";
    assert(link.unstyle == "Click");
}

/// OSC 8 hyperlink with id parameter is stripped.
@("unstyle.oscLink.withId")
@safe unittest
{
    const link = "\x1b]8;id=mylink;https://example.com\x07Click\x1b]8;;\x07";
    assert(link.unstyle == "Click");
}

/// OSC 8 hyperlink combined with SGR styles is fully stripped.
@("unstyle.oscLink.withStyles")
@safe unittest
{
    import sparkles.base.term_style : Style, stylize;

    const styledLink = "\x1b]8;;https://example.com\x07"
        ~ "Click".stylize(Style.blue).stylize(Style.underline)
        ~ "\x1b]8;;\x07";
    assert(styledLink.unstyle == "Click");
}

/// `unstyledLength` correctly counts only visible characters for OSC links.
@("unstyledLength.oscLink")
@safe unittest
{
    const link = "\x1b]8;;https://example.com\x07Click here\x1b]8;;\x07";
    assert(link.unstyledLength == 10);
}

/// Visible width of `s` in terminal cells, ignoring ANSI escapes. Forwards to
/// the grapheme- and East-Asian-width-aware `sparkles.base.text.visibleWidth`
/// (prefer that name in new code); kept for backward compatibility. Unlike the
/// old code-point count, this is correct for CJK (wide), combining marks (zero),
/// and emoji / flags (one 2-cell cluster).
size_t unstyledLength(in char[] s) pure nothrow @nogc => s.visibleWidth;
