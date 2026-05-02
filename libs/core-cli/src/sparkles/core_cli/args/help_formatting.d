module sparkles.core_cli.args.help_formatting;

import std.algorithm : map, sort, startsWith;
import std.array : array, join, split;
import std.format : format;
import std.path : baseName, buildPath, stripExtension;
import std.string : stripRight, toUpper, wrap;
import std.traits : FieldNameTuple, getUDAs;

import sparkles.core_cli.help_formatting : HelpInfo, Sections, formatSection;
import sparkles.core_cli.term_style : sty = stylizedTextBuilder;

import sparkles.core_cli.args.uda;
import sparkles.core_cli.args.internal :
    commandChildren,
    commandInfo,
    commandInfoRaw,
    commandNames,
    commandPrimaryName,
    hasCommandChildren,
    hasSubcommands,
    isSumType,
    subcommandsFieldName;

/// Build a `Sections` map by string-importing a list of section files.
///
/// `subPath` is joined under the views root; pass an empty/null `subPath`
/// for sections that live directly under the views root. The views root is
/// taken from the source file's basename, mirroring the legacy default —
/// callers that want the root-`@Command(name)`-driven default should let
/// the framework resolve sections via `@Command(...).helpSections(...)`
/// instead of building a `Sections` map by hand.
Sections importSections(string subPath = null, string[] sections, string file = __FILE__)()
{
    Sections result;
    enum dir = subPath.length
        ? buildPath(file.baseName.stripExtension, subPath)
        : file.baseName.stripExtension;
    static foreach (section; sections)
    {{
        enum text = tryImport!(buildPath(dir, "sections", section ~ ".txt"));
        static if (text.length)
            result[section] = text.split("\n\n");
    }}
    return result;
}

Sections importSections(string[] sections, string file = __FILE__)()
{
    return importSections!(null, sections, file);
}

template tryImport(string path)
{
    static if (__traits(compiles, import(path)))
        enum string tryImport = import(path).stripRight();
    else
    {
        debug pragma (msg, __MODULE__, ": failed to import: '", path, "'");
        enum string tryImport = null;
    }
}

/// Resolve the views-tree root (a directory under the dub package's string
/// import path) used when looking up help text for `Root` and its
/// descendants. Defaults to the root command's `name`; can be overridden
/// per-program with `Command(...).viewsRoot("...")`.
package template viewsRootFor(Root)
{
    enum cmd = commandInfoRaw!Root();
    enum viewsRootFor = cmd.viewsRoot_.length ? cmd.viewsRoot_ : cmd.name;
}

/// Compute the chain of `@Command` names from `Root`'s direct children
/// down to `Leaf`, walking `@Subcommands` SumTypes. Returns `[]` when
/// `Root == Leaf`, and `null` when `Leaf` is not reachable from `Root`.
///
/// By contract, each leaf type appears at most once in the subcommand
/// tree of a given root — when multiple paths exist, the first one
/// encountered (in `SumType.Types` order) wins.
package string[] subcommandPath(Root, Leaf)() @safe
{
    static if (is(Root == Leaf))
        return [];
    else static if (hasSubcommands!Root || hasCommandChildren!Root)
    {
        static foreach (Variant; subcommandChildTypes!Root)
        {{
            static if (is(Variant == Leaf))
                return [commandPrimaryName!Variant];
            else static if (hasSubcommands!Variant || hasCommandChildren!Variant)
            {{
                enum inner = subcommandPath!(Variant, Leaf);
                static if (inner.length > 0)
                    return [commandPrimaryName!Variant] ~ inner;
            }}
        }}
        return null;
    }
    else
        return null;
}

/// Resolve the help text for the option declared on `Cli.<field>` within
/// the program rooted at `Root`. Inline descriptions on the `@Option` UDA
/// take precedence; when the description is empty the framework falls
/// back to a string-import lookup at
/// `views/<root>/<chain>/options/<short>.txt`, where `<short>` is the
/// option's first alias (uppercase short flags get a trailing underscore
/// in the filename to avoid collisions on case-insensitive filesystems).
package template optionHelpText(Root, Cli, string field)
{
    alias symbol = __traits(getMember, Cli, field);
    enum opt = getUDAs!(symbol, Option)[0];
    static if (opt.description_.length)
        enum optionHelpText = opt.description_;
    else
    {
        enum chain = subcommandPath!(Root, Cli);
        enum subPath = chain.length ? chain.join("/") : "";
        enum viewsRoot = viewsRootFor!Root;
        enum aliasShort = opt.aliases.split("|")[0];
        enum safeName = isUpperShortFlag(aliasShort)
            ? aliasShort ~ "_"
            : aliasShort;
        enum path = subPath.length
            ? buildPath(viewsRoot, subPath, "options", safeName ~ ".txt")
            : buildPath(viewsRoot, "options", safeName ~ ".txt");
        enum optionHelpText = tryImport!path;
    }
}

private bool isUpperShortFlag(string flag) @safe pure nothrow @nogc
{
    return flag.length == 1 && flag[0] >= 'A' && flag[0] <= 'Z';
}

/// Resolve the deferred section list declared by `Cli`'s @Command.helpSections
/// builder, looking each section up at
/// `views/<root>/<chain>/sections/<name>.txt`.
package Sections sectionsForCommand(Root, Cli)() @safe
{
    Sections result;
    enum cmd = commandInfoRaw!Cli();
    enum chain = subcommandPath!(Root, Cli);
    enum subPath = chain.length ? chain.join("/") : "";
    enum viewsRoot = viewsRootFor!Root;
    static foreach (section; cmd.sectionsToImport_)
    {{
        enum path = subPath.length
            ? buildPath(viewsRoot, subPath, "sections", section ~ ".txt")
            : buildPath(viewsRoot, "sections", section ~ ".txt");
        enum text = tryImport!path;
        static if (text.length)
            result[section] = text.split("\n\n");
    }}
    return result;
}

package HelpInfo normalizeHelpInfo(Cli)(string[] argv, HelpInfo helpInfo)
{
    if (helpInfo.programName.length == 0)
        helpInfo.programName = argv.length > 0 ? argv[0].baseName : commandPrimaryName!Cli;

    auto command = commandInfo!(Cli, Cli);
    if (helpInfo.shortDescription.length == 0)
    {
        if (command.description_.length)
            helpInfo.shortDescription = command.description_;
        else
            helpInfo.shortDescription = command.shortDescription_;
    }

    // Merge command sections into helpInfo
    foreach (key, value; command.sections_)
        if (key !in helpInfo.sections)
            helpInfo.sections[key] = value;

    return helpInfo;
}

package HelpInfo childHelpInfo(Root, Cli)(HelpInfo parent)
{
    auto command = commandInfo!(Root, Cli);
    parent.programName = parent.programName ~ " " ~ commandPrimaryName!Cli;
    parent.shortDescription = command.description_.length
        ? command.description_
        : command.shortDescription_;
    parent.sections = command.sections_;
    return parent;
}

package string formatHelp(Root, Cli)(HelpInfo info)
{
    auto command = commandInfo!(Root, Cli);
    auto description = command.description_.length
        ? command.description_
        : info.shortDescription;

    string[] sections;
    sections ~= formatSection("name", [
        info.programName.sty.bold ~ (description.length ? " - " ~ description : null),
    ]);
    sections ~= formatSection("synopsis", [command.usage_.length ? command.usage_ : formatUsage!Cli(info.programName)]);

    if (info.sections.get("description", null).length)
        sections ~= formatSection("description", info.sections["description"]);

    auto positionals = formatPositionals!Cli;
    if (positionals.length)
        sections ~= formatSection("arguments", positionals, 0, "", "\n");

    auto options = formatOptions!(Root, Cli);
    if (options.length)
        sections ~= formatSection("options", options, 0, "", "\n");

    static if (hasSubcommands!Cli || hasCommandChildren!Cli)
    {
        auto commands = formatSubcommands!(Root, Cli);
        if (commands.length)
            sections ~= formatSection("commands", commands, 0, "", "\n");
    }

    // Iterate sorted by key so help output is deterministic across runs;
    // associative-array iteration order is otherwise unspecified.
    foreach (name; info.sections.keys.sort)
        if (name != "description")
            sections ~= formatSection(name, info.sections[name]);

    if (command.epilog_.length)
        sections ~= command.epilog_;

    return sections.join("\n");
}

package string formatSubcommandsHelp(Root, Sub)(HelpInfo info)
{
    return formatSection("commands", formatSubcommands!(Root, Sub), 0);
}

private string formatUsage(Cli)(string programName)
{
    string[] parts = [programName];
    static foreach (field; FieldNameTuple!Cli)
    {{
        alias symbol = __traits(getMember, Cli, field);
        enum options = getUDAs!(symbol, Option);
        static if (options.length)
        {{
            enum optionInfo = options[0];
            static if (!optionInfo.hidden_)
            {
                static if (optionInfo.required_)
                    parts ~= displayOption(optionInfo, field) ~ valuePlaceholder!(typeof(__traits(getMember, Cli.init, field)))(optionInfo, field);
                else
                    parts ~= "[" ~ displayOption(optionInfo, field) ~ valuePlaceholder!(typeof(__traits(getMember, Cli.init, field)))(optionInfo, field) ~ "]";
            }
        }}

        enum args = getUDAs!(symbol, Argument);
        static if (args.length && !args[0].hidden_)
        {{
            enum name = positionalName(field, args[0]);
            static if (args[0].optional_)
                parts ~= "[" ~ name ~ "]";
            else
                parts ~= name;
        }}
    }}

    static if (hasSubcommands!Cli || hasCommandChildren!Cli)
        parts ~= "<command>";

    return parts.join(" ");
}

private string[] formatOptions(Root, Cli)()
{
    string[] lines;
    lines ~= "\t%s, %s\n%s".format("-h".sty.bold, "--help".sty.bold, "Show this help text.".wrap(80, "\t    ", "\t    "));

    static foreach (field; FieldNameTuple!Cli)
    {{
        alias symbol = __traits(getMember, Cli, field);
        enum options = getUDAs!(symbol, Option);
        static if (options.length)
        {{
            enum optionInfo = options[0];
            static if (!optionInfo.hidden_)
            {
                enum description = optionHelpText!(Root, Cli, field);
                lines ~= formatOptionLine!(typeof(__traits(getMember, Cli.init, field)))(optionInfo, field, description);
            }
        }}
    }}

    return lines;
}

private string[] formatPositionals(Cli)()
{
    string[] lines;
    static foreach (field; FieldNameTuple!Cli)
    {{
        alias symbol = __traits(getMember, Cli, field);
        enum args = getUDAs!(symbol, Argument);
        static if (args.length && !args[0].hidden_)
            lines ~= "\t%s\n%s".format(
                positionalName(field, args[0]).sty.bold,
                args[0].description_.wrap(80, "\t    ", "\t    "),
            );
    }}

    return lines;
}

/// Subcommand types directly under `Container`. Resolves to:
/// - the `SumType` variants when `Container` is itself a `SumType`,
/// - the `SumType` variants of `Container`'s `@Subcommands` field
///   (legacy storage model), or
/// - `commandChildren!Container` (nested `@(Command)` structs and
///   `mixin addSubCommand!T` registrations).
package template subcommandChildTypes(Container)
{
    static if (isSumType!Container)
        alias subcommandChildTypes = Container.Types;
    else static if (hasSubcommands!Container)
    {
        enum field = subcommandsFieldName!Container;
        alias subcommandChildTypes = typeof(__traits(getMember, Container.init, field)).Types;
    }
    else
        alias subcommandChildTypes = commandChildren!Container;
}

private string[] formatSubcommands(Root, Container)()
{
    string[] lines;
    static foreach (CommandType; subcommandChildTypes!Container)
    {{
        enum command = commandInfo!(Root, CommandType);
        static if (!command.hidden_)
        {{
            enum names = commandNames!CommandType.join(", ");
            enum description = command.shortDescription_.length
                ? command.shortDescription_
                : command.description_;
            lines ~= "\t%s\n%s".format(
                names.sty.bold,
                description.wrap(80, "\t    ", "\t    "),
            );
        }}
    }}
    return lines;
}

private string formatOptionLine(T)(Option optionInfo, string field, string description)
{
    auto names = optionNames(optionInfo, field)
        .map!(name => "%s".format(optionDisplayName(name).sty.bold))
        .array
        .join(", ");
    return "\t%s%s\n%s".format(
        names,
        valuePlaceholder!T(optionInfo, field),
        description.wrap(80, "\t    ", "\t    "),
    );
}

package string[] optionNames(Option optionInfo, string field) @safe
{
    return optionInfo.aliases.length
        ? optionInfo.aliases.split("|")
        : [field];
}

package string displayOption(Option optionInfo, string field) @safe
{
    return optionDisplayName(optionNames(optionInfo, field)[$ - 1]);
}

package string optionDisplayName(string name) @safe pure nothrow
{
    return name.length == 1 ? "-" ~ name : "--" ~ name;
}

package string valuePlaceholder(T)(Option optionInfo, string field)
{
    static if (is(T == bool))
        return null;
    else
    {
        auto placeholder = optionInfo.placeholder_.length
            ? optionInfo.placeholder_
            : field.toUpper;
        return " " ~ placeholder;
    }
}

package string positionalName(string field, Argument argumentInfo) @safe
{
    return argumentInfo.placeholder_.length ? argumentInfo.placeholder_ : field.toUpper;
}
