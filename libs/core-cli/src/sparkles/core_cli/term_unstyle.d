module sparkles.core_cli.term_unstyle;

@safe:

auto unstyle(R)(R range)
{
    import std.regex : regex, replaceAll;
    const pattern = regex(`\x1B\[[0-9;]*[A-Za-z]`);
    return range.replaceAll(pattern, "");
}

version (unittest)
{
    import std.traits : EnumMembers;
    import sparkles.core_cli.term_style : Style, stylize;

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
    import sparkles.core_cli.term_style : stylizedTextBuilder;

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

size_t unstyledLength(R)(R range)
{
    import std.range : walkLength;
    return range.unstyle.walkLength;
}
