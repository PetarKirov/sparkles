module sparkles.core_cli.help_formatting;

import std.algorithm : filter, map, joiner;
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
private string wrapHelp(string text, uint cols, string indent)
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
    )
{
    return !text ? null : "%s\n%-(%s\n%)".format(
        name.toUpper.sty.bold,
        text.map!(t => wrapColumn ? t.wrapHelp(wrapColumn, indent) : t)
    );
}
