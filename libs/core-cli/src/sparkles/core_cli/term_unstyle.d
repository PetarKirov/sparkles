module sparkles.core_cli.term_unstyle;

@safe:

auto unstyle(R)(R range)
{
    import std.regex : regex, replaceAll;
    const re = "\x1B\\[([0-9]{1,2}(;[0-9]{1,2})*)?[m|K]";
    return range.replaceAll(regex(re), "");
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
}

size_t unstyledLength(R)(R range)
{
    import std.range : walkLength;
    return range.unstyle.walkLength;
}
