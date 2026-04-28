module sparkles.core_cli.help_formatting;

import std.algorithm : canFind, filter, map, joiner;
import std.array : array, byPair;
import std.conv : to;
import std.format : format;
import std.getopt : Option;
import std.range : chain, choose;
import std.string : join, toUpper, wrap;

import sparkles.core_cli.term_style : sty = stylizedTextBuilder;

alias SectionName = string;
alias SectionText = string[];
alias Sections = SectionText[SectionName];
struct HelpInfo { string programName, shortDescription; Sections sections; }

string formatProgramManual(HelpInfo info, Option[] options, uint wrapColumn = 80)
{
    auto fmtSection(string name, string[] text) { return formatSection(name, text, wrapColumn); }
    auto fmtOption(Option o) { return formatOption(o, wrapColumn); }

    return "%-(%s\n%)".format(
        [
            fmtSection("name", [info.programName.sty.bold ~ " - " ~ info.shortDescription]),
            fmtSection("synopsis", [formatSynopsis(info.programName, options)]),
            fmtSection("description", info.sections.get("description", null)),
            formatSection("options", options.map!(o => o.formatOption(wrapColumn)).array, 0)
        ].chain(
            info.sections.byPair.filter!(x => x.key != "description").map!(pair => fmtSection(pair.expand)),
        )
    );
}

string formatSynopsis(string programName, Option[] options)
{
    return "%s %-(%s %)".format(
        programName,
        options.map!(o => o.required ? o.optShort : '[' ~ o.optShort ~ ']')
    );
}

auto optional(string s)
{
    return !s.ptr || !s.length ? string[].init : [s];
}

string formatOption(Option o, uint wrapColumn = 80)
{
    return "\t%-(%s, %)\n%s".format(
        o.optShort.optional.chain(o.optLong.optional).map!(x => x.sty.bold),
        o.help.wrap(wrapColumn, "\t    ", "\t    ")
    );
}

string formatSection(
    string name,
    string[] text,
    uint wrapColumn = 80,
    string indent = "\t",
    string paragraphSeparator = "\n\n",
)
{
    if (!text)
        return null;
    auto formatted = text.map!(t => formatParagraph(t, wrapColumn, indent));
    return name.toUpper.sty.bold ~ "\n" ~ formatted.join(paragraphSeparator);
}

package(sparkles.core_cli) string formatParagraph(string text, uint wrapColumn, string indent)
{
    // If text contains newlines, preserve the structure and just add indent
    // Otherwise, wrap the text normally
    if (text.canFind('\n'))
    {
        import std.algorithm : splitter;
        import std.array : join;
        return text.splitter('\n').map!(line => indent ~ line).join('\n');
    }
    else
    {
        return wrapColumn ? text.wrap(wrapColumn, indent, indent) : text;
    }
}

///
@("help_formatting.formatParagraph.multiline.preservesNewlines")
@system
unittest
{
    string text = "add\n    Add file contents to the index.";
    string result = formatParagraph(text, 80, "\t");
    assert(result == "\tadd\n\t    Add file contents to the index.");
}

///
@("help_formatting.formatParagraph.multiline.emptyLines")
@system
unittest
{
    string text = "title\n\ndescription";
    string result = formatParagraph(text, 80, "\t");
    assert(result == "\ttitle\n\t\n\tdescription");
}

///
@("help_formatting.formatParagraph.singleline.wrapping")
@system
unittest
{
    string text = "This is a long single line that should be wrapped at 20 characters";
    string result = formatParagraph(text, 20, "\t");
    // Should wrap but include the tab indent
    assert(result.canFind('\n'));
    assert(result.canFind('\t'));
}

///
@("help_formatting.formatSection.withStructuredText")
@system
unittest
{
    string[] text = [
        "add\n    Add files to the index.",
        "commit\n    Record changes."
    ];
    string result = formatSection("commands", text, 80, "\t");
    assert(result.canFind("COMMANDS"));
    assert(result.canFind("\tadd"));
    assert(result.canFind("\t    Add files"));
    assert(result.canFind("\tcommit"));
}

///
@("help_formatting.formatSection.separatesParagraphsWithBlankLines")
@system
unittest
{
    string[] text = [
        "clean\n    Start cleaning.",
        "filter by pattern\n    Show options."
    ];
    string result = formatSection("commands", text, 80, "\t");
    // Should have blank line between paragraphs (double newline)
    assert(result.canFind("\n\n\tfilter"));
}

auto wrap2(bool dbg = false, S)(S input, in size_t maxColumns = 80, S indent = null, in size_t tabsize = 8)
{
    import std.algorithm.iteration : chunkBy;
    import std.array : array;
    import std.conv : to;
    import std.range : len = walkLength;
    import std.uni : isWhite;
    import std.string : column;
    static if (dbg) import std.stdio;

    const indentSize = column(indent, tabsize);

    typeof(input.dup) result;
    size_t col = 0;
    auto parts = input.chunkBy!isWhite.array;
    foreach (idx, part; parts)
    {
        const ws = part[0];
        const curLen = part[1].len;
        auto chunk = part[1].to!S;

        static if (dbg)
            writefln!"   col: %s | ws: %s | curLen: %s | chunk: `%s`"(col, ws, curLen, chunk);
        if (!ws)
        {
            if (col + curLen < maxColumns)
            {
                // append word to the current line
            }
            else
            {
                // start a new line
                result ~= '\n';
                result ~= indent;
                col = indentSize;
            }
        }
        else
        {
            if (idx + 1 < parts.length)
            {
                // not trailing whitespace
                auto next = parts[idx + 1][1];
                if (col + curLen + next.len < maxColumns)
                {
                    // pass
                }
            }
            // trailing whitespace
            else if (col + curLen < maxColumns)
            {
                // pass
            }
        }
        result ~= chunk;
        col += curLen;
    }

    return result;
}

unittest
{
    const wrap7 = (string s) => wrap2(s, 7);
    assert(
        "".wrap2(7) ==
        "");
    assert(
        " ".wrap2(7) ==
        " ");
    assert(
        "1 ".wrap2(7) ==
        "1 ");
    assert(
        " 2".wrap2(7) ==
        " 2");
    assert(
        " 2 ".wrap2(7) ==
        " 2 ");
    assert(
        "  3 5 ".wrap2(7) ==
        "  3 5 ");
    assert(
        "  3 56".wrap2(7) ==
        "  3 56");
    assert(
        "  3 5 7".wrap2(7) ==
        "  3 5 \n7");
    assert(
        "  3  67".wrap2(7) ==
        "  3  \n67");
    assert(
        "  3  678901234567".wrap2(7) ==
        "  3  \n678901234567");

    // assert(wrap2("a short string", 7) == "a short\nstring");
    // assert(wrap2("a short string", 7) == "a short\nstring");
    // assert(wrap2("a short string", 7) == "a short\nstring");

    // wrap will not break inside of a word, but at the next space
    // assert(wrap2("a short string", 4) == "a\nshort\nstring\n");

    // assert(wrap2("a short string", 7, "\t") == "\ta\nshort\nstring\n");
    // assert(wrap2("a short string", 7, "\t", "    ") == "\ta\n    short\n    string\n");

}
