module sparkles.core_cli.help_formatting;

import std.algorithm : canFind, filter, map, joiner, splitter;
import std.array : array, byPair;
import std.conv : to;
import std.format : format;
import std.getopt : Option;
import std.range : chain, choose;
import std.string : join, toUpper;

import sparkles.base.term_style : sty = stylizedTextBuilder;
import sparkles.base.text.wrap : wrapText, WrapOptions, WhitespaceMode;

/// Wrap help prose to `cols` visible columns with `indent` on every line. Like
/// the Phobos `wrap` it replaces (trailing newline, tab-aware indent), but ANSI-
/// aware: it measures visible width, so styled help text wraps at the right place.
private string wrapHelp(string text, uint cols, string indent) @safe
{
    return text.wrapText(WrapOptions(
        width: cols,
        indent: indent,
        firstIndent: indent,
        whitespace: WhitespaceMode.collapse,
    )) ~ "\n";
}

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
    // Long-only options have an empty `optShort`; fall back to `optLong` so they show
    // up as e.g. `[--title]` rather than a bare `[]`.
    static string flag(Option o) => o.optShort.length ? o.optShort : o.optLong;
    return "%s %-(%s %)".format(
        programName,
        options.map!(o => o.required ? flag(o) : '[' ~ flag(o) ~ ']')
    );
}

@("help.formatSynopsis.longOnlyFallsBackToLong")
@system unittest
{
    Option shortAndLong = { optShort: "-w", optLong: "--max-width" };
    Option longOnly = { optLong: "--title" };
    Option requiredOpt = { optShort: "-f", optLong: "--file", required: true };
    assert(formatSynopsis("prog", [shortAndLong, longOnly, requiredOpt])
        == "prog [-w] [--title] -f");
}

auto optional(string s)
{
    return !s.ptr || !s.length ? string[].init : [s];
}

string formatOption(Option o, uint wrapColumn = 80)
{
    return "\t%-(%s, %)\n%s".format(
        o.optShort.optional.chain(o.optLong.optional).map!(x => x.sty.bold),
        o.help.wrapHelp(wrapColumn, "\t    ")
    );
}

string formatSection(
    string name,
    string[] text,
    uint wrapColumn = 80,
    string indent = "\t",
    string paragraphSeparator = "\n",
    ) @safe
{
    if (!text)
        return null;
    return name.toUpper.sty.bold ~ "\n"
        ~ text.map!(t => formatParagraph(t, wrapColumn, indent)).join(paragraphSeparator);
}

/**
 * Renders one paragraph of a help section: indented, and wrapped unless it
 * already carries its own line structure.
 *
 * Every branch ends in a newline, so `formatSection` separates paragraphs with a
 * single `\n` and still leaves a blank line between them. Three cases, in the
 * order they are tested:
 *
 * $(LIST
 *   * `wrapColumn == 0` — the text is already formatted (the options section
 *     passes rendered `formatOption` blocks); emit it untouched. Testing this
 *     first is what keeps those blocks from being indented a second time.
 *   * the text contains newlines — a hand-laid-out block such as a subcommand
 *     listing. Indent each line and keep the author's breaks.
 *   * otherwise — ordinary prose; wrap it to `wrapColumn` visible columns.
 * )
 */
package(sparkles.core_cli) string formatParagraph(string text, uint wrapColumn, string indent) @safe
{
    if (!wrapColumn)
        return text;

    if (text.canFind('\n'))
        return text.splitter('\n').map!(line => indent ~ line).join("\n") ~ "\n";

    return text.wrapHelp(wrapColumn, indent);
}

@("help_formatting.formatParagraph.multiline.preservesNewlines")
@system unittest
{
    assert(formatParagraph("add\n    Add file contents to the index.", 80, "\t")
        == "\tadd\n\t    Add file contents to the index.\n");
}

@("help_formatting.formatParagraph.multiline.emptyLines")
@system unittest
{
    assert(formatParagraph("title\n\ndescription", 80, "\t")
        == "\ttitle\n\t\n\tdescription\n");
}

@("help_formatting.formatParagraph.singleline.wraps")
@system unittest
{
    auto result = formatParagraph(
        "This is a long single line that should be wrapped at twenty columns", 20, "\t");
    assert(result.canFind('\n'));
    assert(result.canFind('\t'));
}

// `wrapColumn == 0` means "already formatted" — the options section relies on it.
@("help_formatting.formatParagraph.preformatted.passesThrough")
@system unittest
{
    enum block = "\t-f, --force\n\t    Force it.\n";
    assert(formatParagraph(block, 0, "\t") == block);
}

@("help_formatting.formatSection.blankLineBetweenParagraphs")
@system unittest
{
    import sparkles.core_cli.term_unstyle : unstyle;

    auto section = formatSection("description", ["First para.", "Second para."]);
    assert(section.unstyle == "DESCRIPTION\n\tFirst para.\n\n\tSecond para.\n");
}

// The case `formatParagraph`'s middle branch exists for: a paragraph that laid
// itself out, whose breaks must survive the section.
@("help_formatting.formatSection.withStructuredText")
@system unittest
{
    import sparkles.core_cli.term_unstyle : unstyle;

    auto section = formatSection("commands", [
        "add\n    Add files to the index.",
        "commit\n    Record changes.",
    ]).unstyle;

    assert(section.canFind("COMMANDS"));
    assert(section.canFind("\tadd\n\t    Add files to the index."));
    assert(section.canFind("\tcommit\n\t    Record changes."));
}

// `wrapColumn == 0` means the caller already formatted the rows — the options
// and commands sections pass rendered blocks through. Indenting them a second
// time is the bug this ordering avoids.
@("help_formatting.formatSection.preformattedRowsAreNotReindented")
@system unittest
{
    import sparkles.core_cli.term_unstyle : unstyle;

    enum row = "\t-f, --force\n\t    Force it.\n";
    assert(formatSection("options", [row], 0).unstyle == "OPTIONS\n" ~ row);
}
