module sparkles.core_cli.args;

public import sparkles.core_cli.help_formatting : HelpInfo, Sections, formatParagraph, formatSection;

import std.algorithm : among, canFind, countUntil, map, splitter, startsWith;
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
    string description_;
    string shortDescription_;
    string usage_;
    string epilog_;
    Sections sections_;
    string[] sectionsToImport_;
    bool hidden_;
    string viewsRoot_;

    this(string name, string[] aliases...) @safe
    {
        this.name = name;
        this.aliases = aliases.dup;
    }

    Command description(string text) @safe
    {
        auto result = this;
        result.description_ = text;
        return result;
    }

    Command shortDescription(string text) @safe
    {
        auto result = this;
        result.shortDescription_ = text;
        return result;
    }

    Command usage(string text) @safe
    {
        auto result = this;
        result.usage_ = text;
        return result;
    }

    Command epilog(string text) @safe
    {
        auto result = this;
        result.epilog_ = text;
        return result;
    }

    Command helpSections(Sections value) @safe
    {
        auto result = this;
        result.sections_ = value;
        result.sectionsToImport_ = null;
        return result;
    }

    Command helpSections(sections...)() @safe
    {
        auto result = this;
        result.sectionsToImport_ = [sections];
        return result;
    }

    Command hidden(bool value = true) @safe
    {
        auto result = this;
        result.hidden_ = value;
        return result;
    }

    /// Override the views root used to resolve string-imported help texts
    /// (defaults to the root command's `name`).
    Command viewsRoot(string root) @safe
    {
        auto result = this;
        result.viewsRoot_ = root;
        return result;
    }
}

struct Option
{
    string aliases;
    string description_;
    string placeholder_;
    bool required_;
    bool hidden_;
    bool counter_;
    string[] allowedValues_;

    this(string aliases) @safe
    {
        this.aliases = aliases;
    }

    this(string aliases, string description) @safe
    {
        this.aliases = aliases;
        this.description_ = description;
    }

    Option description(string text) @safe
    {
        auto result = this;
        result.description_ = text;
        return result;
    }

    Option placeholder(string text) @safe
    {
        auto result = this;
        result.placeholder_ = text;
        return result;
    }

    Option required(bool value = true) @safe
    {
        auto result = this;
        result.required_ = value;
        return result;
    }

    Option hidden(bool value = true) @safe
    {
        auto result = this;
        result.hidden_ = value;
        return result;
    }

    Option counter(bool value = true) @safe
    {
        auto result = this;
        result.counter_ = value;
        return result;
    }

    Option allowedValues(string[] values...) @safe
    {
        auto result = this;
        result.allowedValues_ = values.dup;
        return result;
    }
}

struct Argument
{
    size_t position = size_t.max;
    string placeholder_;
    string description_;
    bool optional_;
    bool hidden_;

    this(string placeholder) @safe
    {
        this.placeholder_ = placeholder;
    }

    this(size_t position, string placeholder = null) @safe
    {
        this.position = position;
        this.placeholder_ = placeholder;
    }

    Argument description(string text) @safe
    {
        auto result = this;
        result.description_ = text;
        return result;
    }

    Argument optional(bool value = true) @safe
    {
        auto result = this;
        result.optional_ = value;
        return result;
    }

    Argument hidden(bool value = true) @safe
    {
        auto result = this;
        result.hidden_ = value;
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

/// Build a `Sections` map by string-importing a list of section files.
///
/// `subPath` is joined under the views root; pass an empty/null `subPath`
/// for sections that live directly under the views root. The views root is
/// taken from the source file's basename, mirroring the legacy default —
/// callers that want the root-`@Command(name)`-driven default should let
/// the framework resolve sections via `@Command(...).helpSections!(...)`
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
    auto parsed = parseCommand!(Cli, Cli)(receiver, args, info);
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
    auto parsed = parseCommand!(Cli, Cli)(receiver, args, info, true);
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

        // Pure help requests carry no error message; everything else
        // surfaces the diagnostic before any accompanying help text so
        // the cause stays visible even when help is verbose.
        if (parsed.error.message.length && !parsed.error.isHelp)
            stderr.writeln("Error: ", parsed.error.message);
        if (parsed.error.help.length)
            writeln(parsed.error.help);
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
            // Recurse so nested subcommand trees (root → group → leaf)
            // are fully unwrapped before dispatching to `run()`. A group
            // struct typically has no `run()` of its own — only the leaf
            // does.
            return runParsedCli(command);
        });
    }
    else
        return callRun(cli);
}

/// Resolve the views-tree root (a directory under the dub package's string
/// import path) used when looking up help text for `Root` and its
/// descendants. Defaults to the root command's `name`; can be overridden
/// per-program with `Command(...).viewsRoot("...")`.
private template viewsRootFor(Root)
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
private string[] subcommandPath(Root, Leaf)()
{
    static if (is(Root == Leaf))
        return [];
    else static if (hasSubcommands!Root)
    {
        enum field = subcommandsFieldName!Root;
        alias Sub = typeof(__traits(getMember, Root.init, field));
        static foreach (Variant; Sub.Types)
        {{
            static if (is(Variant == Leaf))
                return [commandPrimaryName!Variant];
            else static if (hasSubcommands!Variant)
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
private template optionHelpText(Root, Cli, string field)
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
private Sections sectionsForCommand(Root, Cli)()
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

private CliExpected!(string[]) parseCommand(Root, Cli)(
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
                help: formatHelp!(Root, Cli)(helpInfo),
                exitCode: 0,
            ));
        }

        static if (hasSubcommands!Cli)
        {
            if (!namedArgsEnded && !arg.startsWith("-"))
            {
                enum field = subcommandsFieldName!Cli;
                auto subArgs = args[index + 1 .. $];
                auto selected = parseSubcommand!Root(
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

                // No variant matched the given subcommand name. In a
                // subcommand-bearing context this is an unknown command,
                // not a stray positional argument.
                return err!(string[])(CliError(
                    kind: CliErrorKind.parse,
                    message: "Unknown command: " ~ arg,
                    help: formatHelp!(Root, Cli)(helpInfo),
                ));
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
            help: formatHelp!(Root, Cli)(helpInfo),
        ));
    }
    else
        return ok!CliError(unknown);
}

private CliExpected!(string[]) parseSubcommand(Root, Sub)(
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
            auto info = childHelpInfo!(Root, CommandType)(parentHelp);
            auto parsed = parseCommand!(Root, CommandType)(command, args, info, keepUnknown);
            if (!parsed)
                return parsed;

            destination = command;
            return parsed;
        }
    }}

    if (isHelpToken(name))
        return err!(string[])(CliError(
            kind: CliErrorKind.help,
            help: formatSubcommandsHelp!(Root, Sub)(parentHelp),
            exitCode: 0,
        ));

    return err!(string[])(CliError.init);
}

/// True iff every character in `name` corresponds to a single-character
/// short option defined on `Cli`. Used as the gating condition for
/// splitting `-abc` into `-a -b -c`: when even one char isn't a known
/// short flag the token is left intact so the caller can report a
/// single "Unknown option" diagnostic instead of mid-bundle confusion.
private bool isShortOptionBundle(Cli)(string name)
{
    foreach (c; name)
    {
        bool matched;
        immutable single = [c];
        static foreach (field; FieldNameTuple!Cli)
        {{
            alias symbol = __traits(getMember, Cli, field);
            enum options = getUDAs!(symbol, Option);
            static if (options.length)
            {{
                enum optionInfo = options[0];
                foreach (candidate; optionNames(optionInfo, field))
                    if (candidate == single)
                        matched = true;
            }}
        }}
        if (!matched)
            return false;
    }
    return true;
}

/// Split `<name>[=<value>]` at the first `=`, populating the three output
/// parameters. Shared by the long-option (`--foo=bar`) and short-option
/// (`-x=2`) branches of `parseNamedOption`.
private void splitOptionToken(
    string token,
    out string name,
    out string inlineValue,
    out bool hasInlineValue,
) @safe pure
{
    auto equals = token.countUntil("=");
    if (equals >= 0)
    {
        name = token[0 .. equals];
        inlineValue = token[equals + 1 .. $];
        hasInlineValue = true;
    }
    else
        name = token;
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
        splitOptionToken(arg[2 .. $], name, inlineValue, hasInlineValue);
    }
    else if (arg.startsWith("-"))
    {
        splitOptionToken(arg[1 .. $], name, inlineValue, hasInlineValue);
        // Bundle splitting (e.g. `-abc` -> `-a -b -c`) is only safe when
        // every character in `name` is itself a defined short option;
        // otherwise tokens like `-help` (against a struct exposing `-h`)
        // would splat into `-h -e -l -p` and produce a confusing
        // mid-bundle error. When at least one char doesn't match, leave
        // `name` intact so the lookup below produces a single
        // "Unknown option -help" diagnostic for the whole token.
        if (!hasInlineValue && name.length > 1 && isShortOptionBundle!Cli(name))
        {
            string[] bundled;
            foreach (c; name)
                bundled ~= "-" ~ c;

            args = args[0 .. index] ~ bundled ~ args[index + 1 .. $];
            // Retry with the first split option
            return parseNamedOption(receiver, args, index, seen);
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
        if (optionInfo.counter_ && !hasInlineValue && isNextValueMissing(args, index))
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
                static if (!argumentInfo.optional_)
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
        static if (options.length && options[0].required_)
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
    if (optionInfo.allowedValues_.length && !optionInfo.allowedValues_.canFind(value))
        return err!T(CliError(
            kind: CliErrorKind.parse,
            message: "Invalid value `" ~ value ~ "`; expected one of: " ~ optionInfo.allowedValues_.join(", "),
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

    auto command = commandInfo!(Cli, Cli);
    if (command.description_.length && helpInfo.shortDescription.length == 0)
        helpInfo.shortDescription = command.description_;

    // Merge command sections into helpInfo
    foreach (key, value; command.sections_)
        if (key !in helpInfo.sections)
            helpInfo.sections[key] = value;

    return helpInfo;
}

private HelpInfo childHelpInfo(Root, Cli)(HelpInfo parent)
{
    auto command = commandInfo!(Root, Cli);
    parent.programName = parent.programName ~ " " ~ commandPrimaryName!Cli;
    parent.shortDescription = command.description_.length
        ? command.description_
        : command.shortDescription_;
    parent.sections = command.sections_;
    return parent;
}

private string formatHelp(Root, Cli)(HelpInfo info)
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

    static if (hasSubcommands!Cli)
    {
        enum field = subcommandsFieldName!Cli;
        alias Sub = typeof(__traits(getMember, Cli.init, field));
        auto commands = formatSubcommands!(Root, Sub);
        if (commands.length)
            sections ~= formatSection("commands", commands, 0, "", "\n");
    }

    foreach (name, text; info.sections)
        if (name != "description")
            sections ~= formatSection(name, text);

    if (command.epilog_.length)
        sections ~= command.epilog_;

    return sections.join("\n");
}

private string formatSubcommandsHelp(Root, Sub)(HelpInfo info)
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

    static if (hasSubcommands!Cli)
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

private string[] formatSubcommands(Root, Sub)()
if (isSumType!Sub)
{
    string[] lines;
    static foreach (CommandType; Sub.Types)
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
        auto placeholder = optionInfo.placeholder_.length
            ? optionInfo.placeholder_
            : field.toUpper;
        return " " ~ placeholder;
    }
}

private string positionalName(string field, Argument argumentInfo)
{
    return argumentInfo.placeholder_.length ? argumentInfo.placeholder_ : field.toUpper;
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

/// Read the raw `@Command` UDA from `T`, with no section resolution.
/// Falls back to a default-named `Command` when `T` lacks a UDA.
private Command commandInfoRaw(T)()
{
    enum udas = getUDAs!(T, Command);
    static if (udas.length == 0)
        return Command(T.stringof);
    else
        return udas[0];
}

/// Read the `@Command` UDA from `Cli` and resolve any deferred
/// `helpSections!()` import list, using `Root`'s views root and the
/// subcommand chain `Root → … → Cli` to compute import paths.
private Command commandInfo(Root, Cli)()
{
    auto result = commandInfoRaw!Cli();
    if (result.sectionsToImport_.length > 0)
    {
        result.sections_ = sectionsForCommand!(Root, Cli)();
        result.sectionsToImport_ = null;
    }
    return result;
}

private string[] commandNames(T)()
{
    enum info = commandInfoRaw!T();
    return [info.name] ~ info.aliases;
}

private string commandPrimaryName(T)()
{
    return commandInfoRaw!T().name;
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
        @(Option("v|verbose").counter())
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
    @(Command("init").shortDescription("Create files"))
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
    @(Command("tool").description("Example tool"))
    struct Cli
    {
        @(Option("v|verbose").description("Increase verbosity."))
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

@("args.parseCli.unknownCommand")
@system
unittest
{
    @(Command("init"))
    static struct Init {}

    @(Command("tool"))
    struct Cli
    {
        @Subcommands()
        SumType!Init command;
    }

    auto parsed = parseCli!Cli(["tool", "frob"]);
    assert(!parsed);
    assert(parsed.error.message == "Unknown command: frob");
}

@("args.parseCli.shortOptionBundleSplitsOnlyWhenAllCharsAreKnownFlags")
@system
unittest
{
    struct Cli
    {
        @(Option("h|host"))
        bool host;
    }

    // `-help` is NOT a valid bundle (`-e`, `-l`, `-p` aren't defined)
    // so it must surface as a single "Unknown option" rather than
    // splatting into `-h -e -l -p` and confusing mid-bundle.
    auto parsed = parseCli!Cli(["tool", "-help"]);
    assert(!parsed);
    assert(parsed.error.message == "Unknown option -help");
}

@("args.parseCli.shortOptionBundleSplitsWhenAllCharsKnown")
@system
unittest
{
    struct Cli
    {
        @(Option("a"))
        bool a;
        @(Option("b"))
        bool b;
        @(Option("c"))
        bool c;
    }

    auto parsed = parseCli!Cli(["tool", "-abc"]);
    assert(parsed);
    assert(parsed.value.a);
    assert(parsed.value.b);
    assert(parsed.value.c);
}

@("args.subcommandPath.flat")
@safe
unittest
{
    @(Command("init")) static struct Init {}
    @(Command("build")) static struct Build {}

    @(Command("tool"))
    static struct Tool
    {
        @Subcommands()
        SumType!(Init, Build) command;
    }

    static assert(subcommandPath!(Tool, Tool) == []);
    static assert(subcommandPath!(Tool, Init) == ["init"]);
    static assert(subcommandPath!(Tool, Build) == ["build"]);
}

@("args.subcommandPath.nested")
@safe
unittest
{
    @(Command("create")) static struct PrCreate {}
    @(Command("list")) static struct PrList {}

    @(Command("pr"))
    static struct Pr
    {
        @Subcommands()
        SumType!(PrCreate, PrList) command;
    }

    @(Command("auth")) static struct Auth {}

    @(Command("gh"))
    static struct Gh
    {
        @Subcommands()
        SumType!(Auth, Pr) command;
    }

    static assert(subcommandPath!(Gh, Gh) == []);
    static assert(subcommandPath!(Gh, Pr) == ["pr"]);
    static assert(subcommandPath!(Gh, PrCreate) == ["pr", "create"]);
    static assert(subcommandPath!(Gh, Auth) == ["auth"]);
}

@("args.viewsRootFor.defaultsToCommandName")
@safe
unittest
{
    @(Command("docker"))
    static struct Docker {}

    static assert(viewsRootFor!Docker == "docker");
}

@("args.viewsRootFor.respectsOverride")
@safe
unittest
{
    @(Command("docker").viewsRoot("custom-views"))
    static struct Docker {}

    static assert(viewsRootFor!Docker == "custom-views");
}

@("args.runParsedCli.nestedSubcommandsUnwrapToLeaf")
@system
unittest
{
    @(Command("create"))
    static struct PrCreate
    {
        int run() => 17;
    }

    @(Command("pr"))
    static struct Pr
    {
        @Subcommands
        SumType!PrCreate command;
    }

    @(Command("gh"))
    struct Gh
    {
        @Subcommands
        SumType!Pr command;
    }

    auto parsed = parseCli!Gh(["gh", "pr", "create"]);
    assert(parsed);
    assert(runParsedCli(parsed.value) == 17);
}

@("args.formatHelp.hiddenOptionAbsentFromSynopsis")
@system
unittest
{
    @(Command("tool"))
    struct Cli
    {
        @(Option("visible"))
        bool visible;

        @(Option("secret").hidden())
        bool secret;
    }

    auto parsed = parseCli!Cli(["tool", "--help"]);
    assert(!parsed);
    assert(parsed.error.isHelp);
    auto help = parsed.error.help;
    assert(help.canFind("--visible"));
    // The synopsis line and the OPTIONS section both omit --secret.
    assert(!help.canFind("--secret"));
}
