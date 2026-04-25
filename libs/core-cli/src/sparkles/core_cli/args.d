module sparkles.core_cli.args;

public import sparkles.core_cli.help_formatting : HelpInfo, Sections;

import std.algorithm : among, canFind, countUntil, map, startsWith;
import std.array : array, join, split;
import std.conv : to;
import std.format : format;
import std.meta : AliasSeq;
import std.path : baseName, buildPath, stripExtension;
import std.range : empty;
import std.string : stripRight, toLower, toUpper, wrap;
import std.sumtype : match, SumType;
import std.traits : FieldNameTuple, getUDAs, isDynamicArray, isIntegral, isSomeString;

import expected : Expected, err, ok;

import sparkles.core_cli.term_style : sty = stylizedTextBuilder;

struct Command
{
    string name;
    string[] aliases;
    string description;
    string shortDescription;
    string usage;
    string epilog;
    Sections sections;
    bool hidden;
    bool default_;

    this(string name, string[] aliases...) @safe
    {
        this.name = name;
        this.aliases = aliases.dup;
    }

    Command Description(string text) @safe
    {
        auto result = this;
        result.description = text;
        return result;
    }

    Command ShortDescription(string text) @safe
    {
        auto result = this;
        result.shortDescription = text;
        return result;
    }

    Command Usage(string text) @safe
    {
        auto result = this;
        result.usage = text;
        return result;
    }

    Command Epilog(string text) @safe
    {
        auto result = this;
        result.epilog = text;
        return result;
    }

    Command HelpSections(Sections value) @safe
    {
        auto result = this;
        result.sections = value;
        return result;
    }

    Command Hidden(bool value = true) @safe
    {
        auto result = this;
        result.hidden = value;
        return result;
    }

    Command Default(bool value = true) @safe
    {
        auto result = this;
        result.default_ = value;
        return result;
    }
}

struct Option
{
    string aliases;
    string description;
    string placeholder;
    bool required;
    bool hidden;
    bool counter;
    string[] allowedValues;

    this(string aliases) @safe
    {
        this.aliases = aliases;
    }

    this(string aliases, string description) @safe
    {
        this.aliases = aliases;
        this.description = description;
    }

    Option Description(string text) @safe
    {
        auto result = this;
        result.description = text;
        return result;
    }

    Option Placeholder(string text) @safe
    {
        auto result = this;
        result.placeholder = text;
        return result;
    }

    Option Required(bool value = true) @safe
    {
        auto result = this;
        result.required = value;
        return result;
    }

    Option Hidden(bool value = true) @safe
    {
        auto result = this;
        result.hidden = value;
        return result;
    }

    Option Counter(bool value = true) @safe
    {
        auto result = this;
        result.counter = value;
        return result;
    }

    Option AllowedValues(string[] values...) @safe
    {
        auto result = this;
        result.allowedValues = values.dup;
        return result;
    }
}

struct Argument
{
    size_t position = size_t.max;
    string placeholder;
    string description;
    bool optional;
    bool hidden;

    this(string placeholder) @safe
    {
        this.placeholder = placeholder;
    }

    this(size_t position, string placeholder = null) @safe
    {
        this.position = position;
        this.placeholder = placeholder;
    }

    Argument Description(string text) @safe
    {
        auto result = this;
        result.description = text;
        return result;
    }

    Argument Optional(bool value = true) @safe
    {
        auto result = this;
        result.optional = value;
        return result;
    }

    Argument Hidden(bool value = true) @safe
    {
        auto result = this;
        result.hidden = value;
        return result;
    }
}

struct Subcommands {}

enum CliErrorKind
{
    parse,
    help,
}

struct CliError
{
    CliErrorKind kind;
    string message;
    string help;
    int exitCode = 1;

    bool isHelp() const => kind == CliErrorKind.help;
}

alias CliExpected(T) = Expected!(T, CliError);

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

template option(string subPath, string aliases, string file = __FILE__)
{
    enum option = Option(aliases, helpTextViaImport!(file, aliases, subPath));
}

template option(string aliases, string file = __FILE__)
{
    enum option = Option(aliases, helpTextViaImport!(file, aliases, null));
}

CliExpected!Cli parseCli(Cli)(
    string[] argv,
    HelpInfo helpInfo = HelpInfo.init,
)
{
    Cli result;
    return parseCli(argv, result, helpInfo);
}

CliExpected!Cli parseCli(Cli)(
    string[] argv,
    ref Cli receiver,
    HelpInfo helpInfo = HelpInfo.init,
)
{
    auto info = normalizeHelpInfo!Cli(argv, helpInfo);
    auto args = argv.length > 0 ? argv[1 .. $] : argv;
    auto parsed = parseCommand(receiver, args, info);
    if (!parsed)
        return err!Cli(parsed.error);

    return ok!CliError(receiver);
}

CliExpected!Cli parseKnownCli(Cli)(
    ref string[] argv,
    ref Cli receiver,
    HelpInfo helpInfo = HelpInfo.init,
)
{
    auto info = normalizeHelpInfo!Cli(argv, helpInfo);
    auto args = argv.length > 0 ? argv[1 .. $] : argv;
    auto parsed = parseCommand(receiver, args, info, true);
    if (!parsed)
        return err!Cli(parsed.error);

    argv = argv.length > 0
        ? argv[0 .. 1] ~ parsed.value
        : parsed.value;
    return ok!CliError(receiver);
}

int runCli(Cli)(
    string[] argv,
    HelpInfo helpInfo = HelpInfo.init,
)
{
    auto parsed = parseCli!Cli(argv, helpInfo);
    if (!parsed)
    {
        import std.stdio : stderr, writeln;

        if (parsed.error.help.length)
            writeln(parsed.error.help);
        else if (parsed.error.message.length)
            stderr.writeln("Error: ", parsed.error.message);
        return parsed.error.exitCode;
    }

    auto value = parsed.value;
    return runParsedCli(value);
}

int runParsedCli(Cli)(ref Cli cli)
{
    static if (hasSubcommands!Cli)
    {
        enum field = subcommandsFieldName!Cli;
        return __traits(getMember, cli, field).match!((ref command) {
            return callRun(command);
        });
    }
    else
        return callRun(cli);
}

private template helpTextViaImport(string file, string optionAliases, string subPath = null)
{
    import std.ascii : isUpper;

    enum programName = file.baseName[0 .. $ - 2];
    enum shortOptionName = optionAliases.split("|")[0];
    static assert(shortOptionName.length == 1);

    enum safeName = shortOptionName[0].isUpper
        ? shortOptionName ~ "_"
        : shortOptionName;

    enum path = subPath.length
        ? buildPath(programName, subPath, "options", safeName ~ ".txt")
        : buildPath(programName, "options", safeName ~ ".txt");

    enum helpTextViaImport = tryImport!path;
}

private CliExpected!(string[]) parseCommand(Cli)(
    ref Cli receiver,
    string[] args,
    HelpInfo helpInfo,
    bool keepUnknown = false,
)
{
    bool[string] seen;
    string[] unknown;
    string[] positionals;
    bool namedArgsEnded;

    size_t index;
    while (index < args.length)
    {
        auto arg = args[index];

        if (!namedArgsEnded && arg == "--")
        {
            namedArgsEnded = true;
            index++;
            continue;
        }

        if (!namedArgsEnded && isHelpToken(arg))
        {
            return err!(string[])(CliError(
                kind: CliErrorKind.help,
                help: formatHelp!Cli(helpInfo),
                exitCode: 0,
            ));
        }

        static if (hasSubcommands!Cli)
        {
            if (!namedArgsEnded && !arg.startsWith("-"))
            {
                enum field = subcommandsFieldName!Cli;
                auto subArgs = args[index + 1 .. $];
                auto selected = parseSubcommand(
                    __traits(getMember, receiver, field),
                    arg,
                    subArgs,
                    helpInfo,
                    keepUnknown,
                );
                if (selected)
                {
                    args = args[0 .. index + 1] ~ subArgs;
                    return selected;
                }

                if (selected.error.isHelp || selected.error.message.length)
                    return err!(string[])(selected.error);
            }
        }

        if (!namedArgsEnded && arg.startsWith("-") && arg.length > 1)
        {
            auto parsed = parseNamedOption(receiver, args, index, seen);
            if (parsed)
            {
                if (parsed.value)
                    continue;

                if (keepUnknown)
                {
                    unknown ~= arg;
                    index++;
                    continue;
                }

                return err!(string[])(CliError(
                    kind: CliErrorKind.parse,
                    message: "Unknown option " ~ arg,
                ));
            }
            else
                return err!(string[])(parsed.error);
        }

        positionals ~= arg;
        index++;
    }

    auto assignedPositionals = assignPositionals(receiver, positionals, seen);
    if (!assignedPositionals)
        return err!(string[])(assignedPositionals.error);

    auto required = validateRequired!Cli(seen);
    if (!required)
        return err!(string[])(required.error);

    static if (hasSubcommands!Cli)
    {
        return err!(string[])(CliError(
            kind: CliErrorKind.parse,
            message: "Missing subcommand",
            help: formatHelp!Cli(helpInfo),
        ));
    }
    else
        return ok!CliError(unknown);
}

private CliExpected!(string[]) parseSubcommand(Sub)(
    ref Sub destination,
    string name,
    ref string[] args,
    HelpInfo parentHelp,
    bool keepUnknown,
)
if (isSumType!Sub)
{
    alias Commands = Sub.Types;
    static foreach (CommandType; Commands)
    {{
        if (commandNames!CommandType.canFind(name))
        {
            CommandType command;
            auto info = childHelpInfo!CommandType(parentHelp);
            auto parsed = parseCommand(command, args, info, keepUnknown);
            if (!parsed)
                return parsed;

            destination = command;
            return parsed;
        }
    }}

    if (isHelpToken(name))
        return err!(string[])(CliError(
            kind: CliErrorKind.help,
            help: formatSubcommandsHelp!Sub(parentHelp),
            exitCode: 0,
        ));

    return err!(string[])(CliError.init);
}

private CliExpected!bool parseNamedOption(Cli)(
    ref Cli receiver,
    ref string[] args,
    ref size_t index,
    ref bool[string] seen,
)
{
    auto arg = args[index];
    bool isLong;
    bool hasInlineValue;
    string name;
    string inlineValue;

    if (arg.startsWith("--"))
    {
        isLong = true;
        auto body = arg[2 .. $];
        auto equals = body.countUntil("=");
        if (equals >= 0)
        {
            name = body[0 .. equals];
            inlineValue = body[equals + 1 .. $];
            hasInlineValue = true;
        }
        else
            name = body;
    }
    else if (arg.startsWith("-"))
    {
        auto body = arg[1 .. $];
        auto equals = body.countUntil("=");
        if (equals >= 0)
        {
            name = body[0 .. equals];
            inlineValue = body[equals + 1 .. $];
            hasInlineValue = true;
        }
        else
        {
            name = body;
            // Support bundling if first char matches an option but length > 1
            if (name.length > 1)
            {
                bool matchesFirst;
                static foreach (field; FieldNameTuple!Cli)
                {{
                    alias symbol = __traits(getMember, Cli, field);
                    enum options = getUDAs!(symbol, Option);
                    static if (options.length)
                    {{
                        enum optionInfo = options[0];
                        foreach (candidate; optionNames(optionInfo, field))
                        {
                            if (candidate == name[0 .. 1])
                                matchesFirst = true;
                        }
                    }}
                }}

                if (matchesFirst)
                {
                    // Split bundled options: -abc -> -a -b -c
                    string[] bundled;
                    foreach (c; name)
                        bundled ~= "-" ~ c;

                    args = args[0 .. index] ~ bundled ~ args[index + 1 .. $];
                    // Retry with the first split option
                    return parseNamedOption(receiver, args, index, seen);
                }
            }
        }
    }

    static foreach (field; FieldNameTuple!Cli)
    {{
        alias symbol = __traits(getMember, Cli, field);
        enum options = getUDAs!(symbol, Option);
        static if (options.length)
        {{
            enum optionInfo = options[0];
            if (matchesOption(optionInfo, field, name, isLong))
            {
                auto effectiveInlineValue = inlineValue;
                auto effectiveHasInlineValue = hasInlineValue;
                if (isLong && name.startsWith("no-"))
                {
                    effectiveInlineValue = "false";
                    effectiveHasInlineValue = true;
                }

                auto parsed = applyOption(
                    __traits(getMember, receiver, field),
                    optionInfo,
                    args,
                    index,
                    effectiveInlineValue,
                    effectiveHasInlineValue,
                );
                if (!parsed)
                    return err!bool(parsed.error);

                seen[field] = true;
                return ok!CliError(true);
            }
        }}
    }}

    return ok!CliError(false);
}

private CliExpected!void applyOption(T)(
    ref T target,
    Option optionInfo,
    string[] args,
    ref size_t index,
    string inlineValue,
    bool hasInlineValue,
)
{
    auto originalArg = args[index];
    static if (is(T == bool))
    {
        if (hasInlineValue)
        {
            auto parsed = parseBool(inlineValue);
            if (!parsed)
                return err(parsed.error);
            target = parsed.value;
        }
        else
            target = true;

        index++;
        return ok!CliError();
    }
    else static if (isDynamicArray!T && !isSomeString!T)
    {
        alias Element = typeof(T.init[0]);
        auto values = collectValues(args, index, inlineValue, hasInlineValue, true);
        if (values.empty)
            return err(CliError(
                kind: CliErrorKind.parse,
                message: "Missing value for " ~ originalArg,
            ));

        foreach (value; values)
        {
            static if (is(Element == string))
                target ~= value;
            else
            {
                auto parsed = parseValue!Element(value, optionInfo);
                if (!parsed)
                    return err(parsed.error);
                target ~= parsed.value;
            }
        }

        return ok!CliError();
    }
    else static if (isIntegral!T && !is(T == enum) && !is(T == bool))
    {
        if (optionInfo.counter && !hasInlineValue && isNextValueMissing(args, index))
        {
            target++;
            index++;
            return ok!CliError();
        }

        auto values = collectValues(args, index, inlineValue, hasInlineValue, false);
        if (values.empty)
            return err(CliError(
                kind: CliErrorKind.parse,
                message: "Missing value for " ~ originalArg,
            ));

        auto parsed = parseValue!T(values[0], optionInfo);
        if (!parsed)
            return err(parsed.error);
        target = parsed.value;
        return ok!CliError();
    }
    else
    {
        auto values = collectValues(args, index, inlineValue, hasInlineValue, false);
        if (values.empty)
            return err(CliError(
                kind: CliErrorKind.parse,
                message: "Missing value for " ~ originalArg,
            ));

        auto parsed = parseValue!T(values[0], optionInfo);
        if (!parsed)
            return err(parsed.error);
        target = parsed.value;
        return ok!CliError();
    }
}

private string[] collectValues(
    string[] args,
    ref size_t index,
    string inlineValue,
    bool hasInlineValue,
    bool variadic,
)
{
    if (hasInlineValue)
    {
        index++;
        return inlineValue.split(",");
    }

    string[] result;
    index++;
    while (index < args.length)
    {
        if (args[index].startsWith("-"))
            break;

        result ~= args[index];
        index++;

        if (!variadic)
            break;
    }

    return result;
}

private bool isNextValueMissing(string[] args, size_t index)
{
    return index + 1 >= args.length || args[index + 1].startsWith("-");
}

private CliExpected!void assignPositionals(Cli)(
    ref Cli receiver,
    string[] values,
    ref bool[string] seen,
)
{
    size_t valueIndex;
    static foreach (field; FieldNameTuple!Cli)
    {{
        alias symbol = __traits(getMember, Cli, field);
        enum args = getUDAs!(symbol, Argument);
        static if (args.length)
        {{
            enum argumentInfo = args[0];
            if (valueIndex >= values.length)
            {
                static if (!argumentInfo.optional)
                {
                    return err(CliError(
                        kind: CliErrorKind.parse,
                        message: "Missing positional argument " ~ positionalName(field, argumentInfo),
                    ));
                }
            }
            else
            {
                alias FieldType = typeof(__traits(getMember, receiver, field));
                static if (isDynamicArray!FieldType && !isSomeString!FieldType)
                {
                    alias Element = typeof(FieldType.init[0]);
                    foreach (v; values[valueIndex .. $])
                    {
                        static if (is(Element == string))
                            __traits(getMember, receiver, field) ~= v;
                        else
                        {
                            auto parsed = parseValue!Element(v, Option.init);
                            if (!parsed)
                                return err(parsed.error);
                            __traits(getMember, receiver, field) ~= parsed.value;
                        }
                    }
                    valueIndex = values.length;
                }
                else
                {
                    auto parsed = parseValue!FieldType(
                        values[valueIndex],
                        Option.init,
                    );
                    if (!parsed)
                        return err(parsed.error);
                    __traits(getMember, receiver, field) = parsed.value;
                    valueIndex++;
                }
                seen[field] = true;
            }
        }}
    }}

    if (valueIndex < values.length)
        return err(CliError(
            kind: CliErrorKind.parse,
            message: "Unexpected positional argument " ~ values[valueIndex],
        ));

    return ok!CliError();
}

private CliExpected!void validateRequired(Cli)(bool[string] seen)
{
    static foreach (field; FieldNameTuple!Cli)
    {{
        alias symbol = __traits(getMember, Cli, field);
        enum options = getUDAs!(symbol, Option);
        static if (options.length && options[0].required)
        {{
            if (!seen.get(field, false))
                return err(CliError(
                    kind: CliErrorKind.parse,
                    message: "Missing required option " ~ displayOption(options[0], field),
                ));
        }}
    }}

    return ok!CliError();
}

private CliExpected!T parseValue(T)(string value, Option optionInfo)
{
    if (optionInfo.allowedValues.length && !optionInfo.allowedValues.canFind(value))
        return err!T(CliError(
            kind: CliErrorKind.parse,
            message: "Invalid value `" ~ value ~ "`; expected one of: " ~ optionInfo.allowedValues.join(", "),
        ));

    static if (is(T == string))
        return ok!CliError(value);
    else static if (is(T == enum))
    {
        try
            return ok!CliError(value.to!T);
        catch (Exception)
        {
            return err!T(CliError(
                kind: CliErrorKind.parse,
                message: "Invalid value `" ~ value ~ "` for " ~ T.stringof,
            ));
        }
    }
    else
    {
        try
            return ok!CliError(value.to!T);
        catch (Exception)
        {
            return err!T(CliError(
                kind: CliErrorKind.parse,
                message: "Invalid value `" ~ value ~ "` for " ~ T.stringof,
            ));
        }
    }
}

private CliExpected!bool parseBool(string value)
{
    switch (value.toLower)
    {
        case "true":
        case "yes":
        case "y":
        case "1":
            return ok!CliError(true);
        case "false":
        case "no":
        case "n":
        case "0":
            return ok!CliError(false);
        default:
            return err!bool(CliError(
                kind: CliErrorKind.parse,
                message: "Invalid boolean value `" ~ value ~ "`",
            ));
    }
}

private HelpInfo normalizeHelpInfo(Cli)(string[] argv, HelpInfo helpInfo)
{
    if (helpInfo.programName.length == 0)
        helpInfo.programName = argv.length > 0 ? argv[0].baseName : commandPrimaryName!Cli;

    auto command = commandInfo!Cli;
    if (command.description.length && helpInfo.shortDescription.length == 0)
        helpInfo.shortDescription = command.description;

    return helpInfo;
}

private HelpInfo childHelpInfo(Cli)(HelpInfo parent)
{
    auto command = commandInfo!Cli;
    parent.programName = parent.programName ~ " " ~ commandPrimaryName!Cli;
    parent.shortDescription = command.description.length
        ? command.description
        : command.shortDescription;
    parent.sections = command.sections;
    return parent;
}

private string formatHelp(Cli)(HelpInfo info)
{
    auto command = commandInfo!Cli;
    auto description = command.description.length
        ? command.description
        : info.shortDescription;

    string[] sections;
    sections ~= formatSection("name", [
        info.programName.sty.bold ~ (description.length ? " - " ~ description : null),
    ]);
    sections ~= formatSection("synopsis", [command.usage.length ? command.usage : formatUsage!Cli(info.programName)]);

    if (info.sections.get("description", null).length)
        sections ~= formatSection("description", info.sections["description"]);

    auto positionals = formatPositionals!Cli;
    if (positionals.length)
        sections ~= formatSection("arguments", positionals, 0);

    auto options = formatOptions!Cli;
    if (options.length)
        sections ~= formatSection("options", options, 0);

    static if (hasSubcommands!Cli)
    {
        enum field = subcommandsFieldName!Cli;
        alias Sub = typeof(__traits(getMember, Cli.init, field));
        auto commands = formatSubcommands!Sub;
        if (commands.length)
            sections ~= formatSection("commands", commands, 0);
    }

    foreach (name, text; info.sections)
        if (name != "description")
            sections ~= formatSection(name, text);

    if (command.epilog.length)
        sections ~= command.epilog;

    return sections.join("\n");
}

private string formatSubcommandsHelp(Sub)(HelpInfo info)
{
    return formatSection("commands", formatSubcommands!Sub, 0);
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
            static if (optionInfo.required)
                parts ~= displayOption(optionInfo, field) ~ valuePlaceholder!(typeof(__traits(getMember, Cli.init, field)))(optionInfo, field);
            else
                parts ~= "[" ~ displayOption(optionInfo, field) ~ valuePlaceholder!(typeof(__traits(getMember, Cli.init, field)))(optionInfo, field) ~ "]";
        }}

        enum args = getUDAs!(symbol, Argument);
        static if (args.length)
        {{
            enum name = positionalName(field, args[0]);
            static if (args[0].optional)
                parts ~= "[" ~ name ~ "]";
            else
                parts ~= name;
        }}
    }}

    static if (hasSubcommands!Cli)
        parts ~= "<command>";

    return parts.join(" ");
}

private string[] formatOptions(Cli)()
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
            static if (!optionInfo.hidden)
                lines ~= formatOptionLine!(typeof(__traits(getMember, Cli.init, field)))(optionInfo, field);
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
        static if (args.length && !args[0].hidden)
            lines ~= "\t%s\n%s".format(
                positionalName(field, args[0]).sty.bold,
                args[0].description.wrap(80, "\t    ", "\t    "),
            );
    }}

    return lines;
}

private string[] formatSubcommands(Sub)()
if (isSumType!Sub)
{
    string[] lines;
    static foreach (CommandType; Sub.Types)
    {{
        enum command = commandInfo!CommandType;
        static if (!command.hidden)
        {{
            enum names = commandNames!CommandType.join(", ");
            enum description = command.shortDescription.length
                ? command.shortDescription
                : command.description;
            lines ~= "\t%s\n%s".format(
                names.sty.bold,
                description.wrap(80, "\t    ", "\t    "),
            );
        }}
    }}
    return lines;
}

private string formatOptionLine(T)(Option optionInfo, string field)
{
    auto names = optionNames(optionInfo, field)
        .map!(name => "%s".format(optionDisplayName(name).sty.bold))
        .array
        .join(", ");
    return "\t%s%s\n%s".format(
        names,
        valuePlaceholder!T(optionInfo, field),
        optionInfo.description.wrap(80, "\t    ", "\t    "),
    );
}

private string formatSection(
    string name,
    string[] text,
    uint wrapColumn = 80,
    string indent = "\t",
)
{
    return !text ? null : "%s\n%-(%s\n%)".format(
        name.toUpper.sty.bold,
        text.map!(t => wrapColumn ? t.wrap(wrapColumn, indent, indent) : t),
    );
}

private bool matchesOption(Option optionInfo, string field, string name, bool isLong)
{
    foreach (candidate; optionNames(optionInfo, field))
    {
        if (candidate == name)
            return true;
    }

    if (isLong && name.startsWith("no-"))
    {
        foreach (candidate; optionNames(optionInfo, field))
            if (candidate == name["no-".length .. $])
                return true;
    }

    return false;
}

private string[] optionNames(Option optionInfo, string field)
{
    return optionInfo.aliases.length
        ? optionInfo.aliases.split("|")
        : [field];
}

private string displayOption(Option optionInfo, string field)
{
    return optionDisplayName(optionNames(optionInfo, field)[$ - 1]);
}

private string optionDisplayName(string name)
{
    return name.length == 1 ? "-" ~ name : "--" ~ name;
}

private string valuePlaceholder(T)(Option optionInfo, string field)
{
    static if (is(T == bool))
        return null;
    else
    {
        auto placeholder = optionInfo.placeholder.length
            ? optionInfo.placeholder
            : field.toUpper;
        return " " ~ placeholder;
    }
}

private string positionalName(string field, Argument argumentInfo)
{
    return argumentInfo.placeholder.length ? argumentInfo.placeholder : field.toUpper;
}

private bool isHelpToken(string arg)
{
    return arg.among("-h", "--help") != 0;
}

private enum isSumType(T) = __traits(compiles, AliasSeq!(T.Types));

private enum hasSubcommands(T) = subcommandsFieldName!T.length != 0;

private template subcommandsFieldName(T)
{
    enum subcommandsFieldName = findSubcommandsFieldName!T();
}

private string findSubcommandsFieldName(T)()
{
    static foreach (field; FieldNameTuple!T)
    {{
        alias symbol = __traits(getMember, T, field);
        alias subcommands = getUDAs!(symbol, Subcommands);
        static if (subcommands.length)
            return field;
    }}

    return null;
}

private Command commandInfo(T)()
{
    enum commands = getUDAs!(T, Command);
    static if (commands.length)
        return commands[0];
    else
        return Command(T.stringof);
}

private string[] commandNames(T)()
{
    auto info = commandInfo!T;
    return [info.name] ~ info.aliases;
}

private string commandPrimaryName(T)()
{
    return commandInfo!T.name;
}

private int callRun(T)(ref T value)
{
    static if (__traits(compiles, value.run()))
    {
        static if (is(typeof(value.run()) == int))
            return value.run();
        else
        {
            value.run();
            return 0;
        }
    }
    else
        return 0;
}

///
@("args.parseCli.options")
@system
unittest
{
    struct Cli
    {
        @(Option("v|verbose").Counter())
        uint verbose;

        @(Option("n|name"))
        string name;

        @(Option("flag"))
        bool flag;
    }

    auto parsed = parseCli!Cli(["tool", "-v", "-v", "--name", "sparkles", "--flag"]);
    assert(parsed);
    assert(parsed.value.verbose == 2);
    assert(parsed.value.name == "sparkles");
    assert(parsed.value.flag);
}

@("args.parseCli.positionals")
@system
unittest
{
    struct Cli
    {
        @(Argument("INPUT"))
        string input;
    }

    auto parsed = parseCli!Cli(["tool", "README.md"]);
    assert(parsed);
    assert(parsed.value.input == "README.md");
}

@("args.parseCli.subcommands")
@system
unittest
{
    @(Command("init").ShortDescription("Create files"))
    static struct Init
    {
        @(Option("force"))
        bool force;

        int run() => force ? 7 : 3;
    }

    @(Command("build", "b"))
    static struct Build
    {
        @(Option("release"))
        bool release_;
    }

    struct Cli
    {
        @Subcommands()
        SumType!(Init, Build) command;
    }

    auto parsed = parseCli!Cli(["tool", "init", "--force"]);
    assert(parsed);
    assert(runParsedCli(parsed.value) == 7);
}

@("args.parseCli.help")
@system
unittest
{
    @(Command("tool").Description("Example tool"))
    struct Cli
    {
        @(Option("v|verbose").Description("Increase verbosity."))
        bool verbose;
    }

    auto parsed = parseCli!Cli(["tool", "--help"]);
    assert(!parsed);
    assert(parsed.error.isHelp);
    assert(parsed.error.help.canFind("NAME"));
    assert(parsed.error.help.canFind("--verbose"));
}

@("args.parseCli.arraysAndBoolNegation")
@system
unittest
{
    struct Cli
    {
        @(Option("files"))
        string[] files;

        @(Option("color"))
        bool color = true;
    }

    auto parsed = parseCli!Cli(["tool", "--files", "a.d", "b.d", "--no-color"]);
    assert(parsed);
    assert(parsed.value.files == ["a.d", "b.d"]);
    assert(!parsed.value.color);
}

@("args.parseCli.missingArrayValue")
@system
unittest
{
    struct Cli
    {
        @(Option("files"))
        string[] files;
    }

    auto parsed = parseCli!Cli(["tool", "--files"]);
    assert(!parsed);
    assert(parsed.error.message == "Missing value for --files");
}
