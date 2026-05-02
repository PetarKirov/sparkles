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
    allChildren,
    commandInfo,
    commandInfoRaw,
    commandNames,
    commandPrimaryName,
    isSumType;

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
    else static if (allChildren!Root.length > 0)
    {
        static foreach (Variant; allChildren!Root)
        {{
            static if (is(Variant == Leaf))
                return [commandPrimaryName!Variant];
            else static if (allChildren!Variant.length > 0)
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

/// Build the string-import path used to look up help text under
/// `<viewsRoot>/<subcommand-chain>/<kind>/<name>.txt`.
private template viewsPath(Root, Cli, string kind, string name)
{
    private enum chain = subcommandPath!(Root, Cli);
    private enum head = chain.length
        ? buildPath(viewsRootFor!Root, chain.join("/"))
        : viewsRootFor!Root;
    enum viewsPath = buildPath(head, kind, name ~ ".txt");
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
        enum aliasShort = opt.aliases.split("|")[0];
        enum safeName = isUpperShortFlag(aliasShort) ? aliasShort ~ "_" : aliasShort;
        enum optionHelpText = tryImport!(viewsPath!(Root, Cli, "options", safeName));
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
    static foreach (section; cmd.sectionsToImport_)
    {{
        enum text = tryImport!(viewsPath!(Root, Cli, "sections", section));
        static if (text.length)
            result[section] = text.split("\n\n");
    }}
    return result;
}

private string preferredDescription(Command command) @safe
{
    return command.description_.length ? command.description_ : command.shortDescription_;
}

package HelpInfo normalizeHelpInfo(Cli)(string[] argv, HelpInfo helpInfo)
{
    if (helpInfo.programName.length == 0)
        helpInfo.programName = argv.length > 0 ? argv[0].baseName : commandPrimaryName!Cli;

    auto command = commandInfo!(Cli, Cli);
    if (helpInfo.shortDescription.length == 0)
        helpInfo.shortDescription = preferredDescription(command);

    foreach (key, value; command.sections_)
        if (key !in helpInfo.sections)
            helpInfo.sections[key] = value;

    return helpInfo;
}

package HelpInfo childHelpInfo(Root, Cli)(HelpInfo parent)
{
    auto command = commandInfo!(Root, Cli);
    parent.programName = parent.programName ~ " " ~ commandPrimaryName!Cli;
    parent.shortDescription = preferredDescription(command);
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

    static if (allChildren!Cli.length > 0)
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

private enum helpWrapColumn = 80;
private enum helpBodyIndent = "\t    ";

/// Help-section row: a tab-indented head line followed by the body
/// wrapped to `helpWrapColumn` and indented to align under the head.
private string helpRow(string head, string body_) @safe
{
    return "\t" ~ head ~ "\n" ~ body_.wrap(helpWrapColumn, helpBodyIndent, helpBodyIndent);
}

private string formatUsage(Cli)(string programName)
{
    string[] parts = [programName];
    static foreach (field; FieldNameTuple!Cli)
    {{
        alias symbol = __traits(getMember, Cli, field);
        enum options = getUDAs!(symbol, Option);
        static if (options.length && !options[0].hidden_)
        {{
            enum o = options[0];
            alias FT = typeof(__traits(getMember, Cli.init, field));
            enum body_ = displayOption(o, field) ~ valuePlaceholder!FT(o, field);
            parts ~= o.required_ ? body_ : "[" ~ body_ ~ "]";
        }}
        enum args = getUDAs!(symbol, Argument);
        static if (args.length && !args[0].hidden_)
        {{
            enum name = positionalName(field, args[0]);
            parts ~= args[0].optional_ ? "[" ~ name ~ "]" : name;
        }}
    }}

    static if (allChildren!Cli.length > 0)
        parts ~= "<command>";

    return parts.join(" ");
}

private string[] formatOptions(Root, Cli)()
{
    string[] lines = [helpRow("-h".sty.bold ~ ", " ~ "--help".sty.bold, "Show this help text.")];
    static foreach (field; FieldNameTuple!Cli)
    {{
        alias symbol = __traits(getMember, Cli, field);
        enum options = getUDAs!(symbol, Option);
        static if (options.length && !options[0].hidden_)
            lines ~= formatOptionLine!(typeof(__traits(getMember, Cli.init, field)))(
                options[0], field, optionHelpText!(Root, Cli, field));
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
            lines ~= helpRow(positionalName(field, args[0]).sty.bold, args[0].description_);
    }}
    return lines;
}

/// Subcommand types directly under `Container`. Mirrors `allChildren`,
/// with one extra case: when `Container` is itself a `SumType`, expand
/// to its variants directly (used by callers that already hold the
/// SumType rather than the wrapping struct).
package template subcommandChildTypes(Container)
{
    static if (isSumType!Container)
        alias subcommandChildTypes = Container.Types;
    else
        alias subcommandChildTypes = allChildren!Container;
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
            lines ~= helpRow(names.sty.bold, description);
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
    return helpRow(names ~ valuePlaceholder!T(optionInfo, field), description);
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
