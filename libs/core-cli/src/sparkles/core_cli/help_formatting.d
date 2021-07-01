module sparkles.core_cli.help_formatting;

import std.algorithm : filter, map, joiner;
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

string formatProgramManual(HelpInfo info, Option[] options)
{
    return "%-(%s\n%)".format(
        [
            formatSection("name", [info.programName.sty.bold ~ " - " ~ info.shortDescription]),
            formatSection("synopsis", [formatSynopsis(info.programName, options)]),
        ].chain(
            info.sections.byPair.map!(pair => formatSection(pair.expand)),
            [formatSection("options", options.map!formatOption.array, false)],
        )
    );
}

string formatSynopsis(string programName, Option[] options)
{
    return "%s %-(%s %)".format(
        programName,
        options.map!(o => o.required ? o.optLong : '[' ~ o.optLong ~ ']')
    );
}

auto optional(string s)
{
    return choose(!s.ptr || !s.length, string[].init, [s]);
}

string formatOption(Option o)
{
    return "\n\t%-(%s, %)\n%s".format(
        o.optShort.optional.chain(o.optLong.optional).map!(x => x.sty.bold),
        o.help.wrap(80, "\t    ", "\t    ")
    );
}

string formatSection(
    string name,
    string[] text,
    bool autoWrap = true,
    string indent = "\t")
{
    return "%s\n%-(%s\n%)".format(
        name.toUpper.sty.bold,
        text.map!(t => autoWrap ? t.wrap(80, indent, indent) : t)
    );
}
