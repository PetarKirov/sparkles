/**
 * The pre-subcommand argument parser, kept for the callers that still use it.
 *
 * This is the whole of the original `sparkles.core_cli.args`: a `@cliOption`
 * UDA over `std.getopt`, flat, one command deep. The subcommand-capable parser
 * in $(D sparkles.core_cli.args.internal) supersedes it — new code declares
 * `@Option`/`@Command` and calls `parseCli`.
 *
 * It stays because nineteen call sites across the monorepo still parse their
 * argv this way, and migrating them is a separate concern from landing the new
 * engine. Removing this module is the last step of that migration, not a
 * prerequisite for it.
 *
 * The two parsers share `Sections`, `HelpInfo` and `tryImport`; only the option
 * vocabulary differs, so a package may use one or the other but has no reason
 * to mix them.
 */
module sparkles.core_cli.args.legacy;

import std.meta, std.traits, std.typecons;

import sparkles.core_cli.args.help_formatting : tryImport;
import sparkles.core_cli.help_formatting : HelpInfo;

/// One option's spelling and its help text, attached to a field by $(LREF cliOption).
struct CliOption { string aliases; string description; }

/**
 * A `@cliOption` UDA whose description is read from the views directory.
 *
 * The text comes from `<program>/options/<short>.txt` next to the calling
 * module, so long help lives beside the program rather than inside a string
 * literal. An uppercase short name gains a `_` suffix, because a
 * case-insensitive filesystem cannot hold both `x.txt` and `X.txt`.
 */
@property CliOption cliOption(string aliases, string file = __FILE__)()
{
    return CliOption(aliases, helpTextViaImport!(file, aliases));
}

/// Parses `argv` into a POD whose fields carry `@cliOption` UDAs.
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

/// Parses `argv` against an explicit `std.getopt` option list, printing the
/// manual and exiting when `--help` is asked for.
void parseCliArgs(CliOptions...)(
    ref string[] argv,
    HelpInfo helpInfo,
    CliOptions options,
)
{
    import core.stdc.stdlib : exit;
    import std.getopt : getopt, config;
    import std.stdio : writeln;
    import sparkles.core_cli.help_formatting : formatProgramManual;

    auto getOptResult = argv.getopt(config.caseSensitive, options);

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
    import std.ascii : isUpper;
    import std.path : baseName, buildPath;
    import std.string : split;

    enum programName = file.baseName[0..$-2];
    enum shortOptionName = optionAliases.split("|")[0];
    static assert(shortOptionName.length == 1);

    // Append "_" to uppercase single-char options to avoid case-insensitive FS conflicts (e.g. x.txt vs X_.txt)
    enum safeName = shortOptionName[0].isUpper
        ? shortOptionName ~ "_"
        : shortOptionName;
    enum path = programName.buildPath("options", safeName ~ ".txt");

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
