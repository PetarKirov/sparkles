module sparkles.core_cli.args;

public import sparkles.core_cli.help_formatting : HelpInfo, Sections;

import std.meta, std.traits, std.typecons;

struct CliOption { string aliases; string description; }

Sections importSections(string[] sections, string file = __FILE__)()
{
    import std.algorithm.iteration : map;
    import std.array : array;
    import std.path : baseName, buildPath, stripExtension;
    import std.string : split, stripRight, tr;
    Sections result;
    enum dir = file.baseName.stripExtension;
    static foreach (section; sections)
    {{
        enum text = tryImport!(buildPath(dir, "sections", section ~ ".txt"));
        static if (text.length)
            result[section] = text.split("\n\n");//.map!(x => x.tr(" \t\n", " ", "ds")).array;
    }}
    return result;
}

template tryImport(string path)
{
    import std.string : stripRight;
    static if (__traits(compiles, import(path)))
        enum string tryImport = import(path).stripRight();
    else
    {
        debug pragma (msg, __MODULE__, ": failed to import: '", path, "'");
        enum string tryImport = null;
    }
}

@property CliOption cliOption(string aliases, string file = __FILE__)()
{
    return CliOption(aliases, helpTextViaImport!(file, aliases));
}

CliParams parseCliArgs(CliParams)(ref string[] argv, HelpInfo helpInfo)
if (__traits(isPOD, CliParams))
{
    import std.format;
    CliParams result;
    mixin(
        `argv.parseCliArgs(helpInfo,`,
        CliParamsStructToDescription!CliParams,
        `);
    `);
    return result;
}

void parseCliArgs(CliOptions...)(
    ref string[] argv,
    HelpInfo helpInfo,
    CliOptions options,
)
{
    import core.stdc.stdlib : exit;
    import std.getopt : getopt;
    import std.stdio : writeln;
    import sparkles.core_cli.help_formatting : formatProgramManual;

    auto getOptResult = argv.getopt(options);

    if (getOptResult.helpWanted)
    {
        helpInfo
            .formatProgramManual(getOptResult.options)
            .writeln;
        exit(0);
    }
}

private template helpTextViaImport(string file, string optionAliases)
{
    import std.path : baseName, buildPath;
    import std.string : split;

    enum programName = file.baseName[0..$-2];
    enum shortOptionName = optionAliases.split("|")[0];
    enum path = programName.buildPath("options", shortOptionName  ~ ".txt");

    enum helpTextViaImport = tryImport!path;
}

enum getOption(alias symbol) = tuple(
    getUDAs!(symbol, CliOption)[0].tupleof,
    __traits(identifier, symbol)
);

template CliParamsStructToDescription(alias S)
{
    import std.format, std.meta, std.traits;
    enum CliParamsStructToDescription = [staticMap!(
        getOption,
        getSymbolsByUDA!(S, CliOption)
    )].format!"%(%(\"%s\", \"%s\", &result.%s%),\n%)";
}
