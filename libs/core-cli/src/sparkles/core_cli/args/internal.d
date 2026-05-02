module sparkles.core_cli.args.internal;

public import sparkles.core_cli.args.error;
public import sparkles.core_cli.args.uda;
public import sparkles.core_cli.help_formatting : HelpInfo, Sections, formatParagraph, formatSection;

import std.algorithm : among, canFind, countUntil, map, sort, splitter, startsWith;
import std.array : array, join, split;
import std.conv : to;
import std.format : format;
import std.meta : AliasSeq, staticMap;
import std.path : baseName, buildPath, stripExtension;
import std.range : empty;
import std.string : stripRight, toLower, toUpper, wrap;
import std.sumtype : match, SumType;
import std.traits : FieldNameTuple, getUDAs, isDynamicArray, isIntegral, isSomeString;

import sparkles.core_cli.term_style : sty = stylizedTextBuilder;

struct CommandNode(Command_)
{
    alias Command = Command_;
    enum __sparklesCommandNodeMarker = true;

    Command value;

    static if (hasCommandChildren!Command)
    {
        SumType!(staticMap!(CommandNode, commandChildren!Command)) command;
        bool commandSelected;
    }
}

template ParsedCommand(Command)
{
    static if (usesSynthesizedSubcommands!Command)
        alias ParsedCommand = CommandNode!Command;
    else
        alias ParsedCommand = Command;
}

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

// `parseCli` and `parseKnownCli` are NOT marked `@safe`: although the
// pure parsing logic itself is safe, the user-supplied `Cli` struct may
// hold a `SumType` whose `opAssign` is `@system` (it becomes `@system`
// whenever any variant has a destructor that touches `@system` state).
// That `opAssign` is reached transitively from `parseSubcommand`, so
// the inferred attribute set of `parseCli!Cli` is keyed on `Cli`. We
// therefore leave the attributes inferred per instantiation rather
// than locking the public surface to `@safe`.
CliExpected!(ParsedCommand!Cli) parseCli(Cli)(
    string[] argv,
    HelpInfo helpInfo = HelpInfo.init,
)
{
    ParsedCommand!Cli result;
    return parseCli!Cli(argv, result, helpInfo);
}

CliExpected!(ParsedCommand!Cli) parseCli(Cli)(
    string[] argv,
    ref ParsedCommand!Cli receiver,
    HelpInfo helpInfo = HelpInfo.init,
)
{
    auto info = normalizeHelpInfo!Cli(argv, helpInfo);
    auto args = argv.length > 0 ? argv[1 .. $] : argv;
    auto parsed = parseCommandImpl!(Cli, Cli)(receiver, args, info);
    if (!parsed)
        return error!(ParsedCommand!Cli)(parsed.error);

    return ok(receiver);
}

CliExpected!(ParsedCommand!Cli) parseKnownCli(Cli)(
    ref string[] argv,
    ref ParsedCommand!Cli receiver,
    HelpInfo helpInfo = HelpInfo.init,
)
{
    auto info = normalizeHelpInfo!Cli(argv, helpInfo);
    auto args = argv.length > 0 ? argv[1 .. $] : argv;
    auto parsed = parseCommandImpl!(Cli, Cli)(receiver, args, info, true);
    if (!parsed)
        return error!(ParsedCommand!Cli)(parsed.error);

    argv = argv.length > 0
        ? argv[0 .. 1] ~ parsed.value
        : parsed.value;
    return ok(receiver);
}

// `runCli` and `runParsedCli` ultimately dispatch to user-supplied
// `run()` methods on leaf command structs. Those methods may be
// `@system` (e.g. shelling out, touching the filesystem, etc.), so the
// dispatcher itself can't claim `@safe` — its safety follows from the
// leaves it eventually calls. The pure parsing path (`parseCli`,
// `parseKnownCli`) is `@safe` because it never crosses that boundary.
int runCli(Cli)(
    string[] argv,
)
{
    auto parsed = parseCli!Cli(argv);
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
    return runParsedCliImpl!(void, Cli, Cli)(cli, cli);
}

private int runParsedCliImpl(Parent, Cli, Program)(ref Cli cli, ref Program program)
{
    static if (isCommandNode!Cli)
    {
        alias CommandType = Cli.Command;
        static if (hasCommandChildren!CommandType)
        {
            if (cli.commandSelected)
                return cli.command.match!((ref command) {
                    return runParsedCliImpl!(CommandType, typeof(command), Program)(command, program);
                });
        }

        static if (hasCommandChildren!CommandType && !commandInfoRaw!CommandType().isDefault_)
        {
            assert(false, "Command group reached dispatch without a selected subcommand.");
        }
        else
            return callRun!(Parent, CommandType, Program)(cli.value, program);
    }
    else static if (hasSubcommands!Cli)
    {
        enum field = subcommandsFieldName!Cli;
        return __traits(getMember, cli, field).match!((ref command) {
            // Recurse so nested subcommand trees (root → group → leaf)
            // are fully unwrapped before dispatching to `run()`. A group
            // struct typically has no `run()` of its own — only the leaf
            // does.
            return runParsedCliImpl!(Cli, typeof(command), Program)(command, program);
        });
    }
    else
        return callRun!(Parent, Cli, Program)(cli, program);
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
private string[] subcommandPath(Root, Leaf)() @safe
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
    else static if (hasCommandChildren!Root)
    {
        static foreach (Variant; commandChildren!Root)
        {{
            static if (is(Variant == Leaf))
                return [commandPrimaryName!Variant];
            else static if (hasCommandChildren!Variant || hasSubcommands!Variant)
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
private Sections sectionsForCommand(Root, Cli)() @safe
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

/// Shared parser for a single command level. Handles both the legacy
/// `@Subcommands SumType!(...)` storage model and the graph-based
/// `CommandNode!Cli` model — the receiver type drives the differences via
/// `static if`. The two outer entry points (`parseCli` for the root and
/// `parseChildCommand` for nested levels) are thin enough that there is
/// no benefit to additional wrappers.
private CliExpected!(string[]) parseCommandImpl(Root, Cli, Receiver)(
    ref Receiver receiver,
    string[] args,
    HelpInfo helpInfo,
    bool keepUnknown = false,
)
{
    enum isNode = isCommandNode!Receiver;
    static if (isNode)
        enum hasChildren = hasCommandChildren!Cli;
    else
        enum hasChildren = hasSubcommands!Cli;

    // Field-storage receiver: the user-defined struct holding `@Option`
    // and `@Argument` fields. For graph-based parsing the user struct is
    // wrapped in a `CommandNode`; for the legacy model it *is* the
    // receiver.
    static if (isNode)
        ref valueOf() return @trusted => receiver.value;
    else
        ref valueOf() return @trusted => receiver;

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
            return error!(string[])(CliError(
                kind: CliErrorKind.help,
                help: formatHelp!(Root, Cli)(helpInfo),
                exitCode: 0,
            ));
        }

        static if (hasChildren)
        {
            if (!namedArgsEnded && !arg.startsWith("-"))
            {
                auto subArgs = args[index + 1 .. $];
                static if (isNode)
                {
                    auto selected = dispatchChild!(Root, Cli)(
                        receiver.command,
                        receiver.commandSelected,
                        arg, subArgs, helpInfo, keepUnknown,
                    );
                }
                else
                {
                    enum field = subcommandsFieldName!Cli;
                    auto selected = dispatchSubcommand!Root(
                        __traits(getMember, receiver, field),
                        arg, subArgs, helpInfo, keepUnknown,
                    );
                }

                if (selected)
                    return selected;

                if (selected.error.isHelp || selected.error.message.length)
                    return error!(string[])(selected.error);

                // No variant matched the given subcommand name. In a
                // subcommand-bearing context this is an unknown command,
                // not a stray positional argument.
                return error!(string[])(CliError(
                    kind: CliErrorKind.parse,
                    message: "Unknown command: " ~ arg,
                    help: formatHelp!(Root, Cli)(helpInfo),
                ));
            }
        }

        if (!namedArgsEnded && arg.startsWith("-") && arg.length > 1)
        {
            auto parsed = parseNamedOption(valueOf(), args, index, seen);
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

                return error!(string[])(CliError(
                    kind: CliErrorKind.parse,
                    message: "Unknown option " ~ arg,
                ));
            }
            else
                return error!(string[])(parsed.error);
        }

        positionals ~= arg;
        index++;
    }

    auto assignedPositionals = assignPositionals(valueOf(), positionals, seen);
    if (!assignedPositionals)
        return error!(string[])(assignedPositionals.error);

    auto required = validateRequired!Cli(seen);
    if (!required)
        return error!(string[])(required.error);

    static if (hasChildren)
    {
        enum command = commandInfoRaw!Cli();
        static if (isNode)
        {
            // Graph-based model: `isDefault_` means the parent itself can
            // run when no subcommand is selected. Dispatch picks that up
            // by inspecting `commandSelected` in `runParsedCliImpl`.
            static if (command.isDefault_)
                return ok(unknown);
            else
                return error!(string[])(CliError(
                    kind: CliErrorKind.parse,
                    message: "Missing subcommand",
                    help: formatHelp!(Root, Cli)(helpInfo),
                ));
        }
        else
        {
            // Legacy `@Subcommands SumType!(...)` storage cannot represent
            // "no variant selected" at runtime — `std.sumtype` default-
            // initialises to its first variant, indistinguishable from an
            // explicit selection. Reject `makeDefault()` here so the
            // limitation surfaces at the declaration site instead of
            // silently dispatching to the first variant.
            static assert(!command.isDefault_,
                "`makeDefault()` is not supported on `" ~ Cli.stringof
                ~ "` because it uses the legacy `@Subcommands SumType!(...)` "
                ~ "storage model. Use the graph-based subcommand model "
                ~ "(nested `@(Command)` structs or `mixin addSubCommand!T`) "
                ~ "to opt into default command groups.");
            return error!(string[])(CliError(
                kind: CliErrorKind.parse,
                message: "Missing subcommand",
                help: formatHelp!(Root, Cli)(helpInfo),
            ));
        }
    }
    else
        return ok(unknown);
}

private CliExpected!(string[]) dispatchChild(Root, Parent)(
    ref SumType!(staticMap!(CommandNode, commandChildren!Parent)) destination,
    ref bool commandSelected,
    string name,
    ref string[] args,
    HelpInfo parentHelp,
    bool keepUnknown,
)
{
    static foreach (CommandType; commandChildren!Parent)
    {{
        if (commandNames!CommandType.canFind(name))
        {
            CommandNode!CommandType command;
            auto info = childHelpInfo!(Root, CommandType)(parentHelp);
            auto parsed = parseCommandImpl!(Root, CommandType)(command, args, info, keepUnknown);
            if (!parsed)
                return parsed;

            destination = command;
            commandSelected = true;
            return parsed;
        }
    }}

    if (isHelpToken(name))
        return error!(string[])(CliError(
            kind: CliErrorKind.help,
            help: formatSubcommandsHelp!(Root, Parent)(parentHelp),
            exitCode: 0,
        ));

    return error!(string[])(CliError.init);
}

private CliExpected!(string[]) dispatchSubcommand(Root, Sub)(
    ref Sub destination,
    string name,
    ref string[] args,
    HelpInfo parentHelp,
    bool keepUnknown,
)
if (isSumType!Sub)
{
    static foreach (CommandType; Sub.Types)
    {{
        if (commandNames!CommandType.canFind(name))
        {
            CommandType command;
            auto info = childHelpInfo!(Root, CommandType)(parentHelp);
            auto parsed = parseCommandImpl!(Root, CommandType)(command, args, info, keepUnknown);
            if (!parsed)
                return parsed;

            destination = command;
            return parsed;
        }
    }}

    if (isHelpToken(name))
        return error!(string[])(CliError(
            kind: CliErrorKind.help,
            help: formatSubcommandsHelp!(Root, Sub)(parentHelp),
            exitCode: 0,
        ));

    return error!(string[])(CliError.init);
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
            const match = matchesOption(optionInfo, field, name, isLong);
            if (match != OptionMatch.none)
            {
                auto effectiveInlineValue = inlineValue;
                auto effectiveHasInlineValue = hasInlineValue;
                // Only apply the boolean-negation override when we matched the
                // `no-`-stripped alias. A user-defined option literally named
                // `no-color` matches `OptionMatch.direct`, and must not be
                // silently coerced to `false`.
                if (match == OptionMatch.negated)
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
                    return error!bool(parsed.error);

                seen[field] = true;
                return ok(true);
            }
        }}
    }}

    return ok(false);
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
                return error(parsed.error);
            target = parsed.value;
        }
        else
            target = true;

        index++;
        return ok();
    }
    else static if (isDynamicArray!T && !isSomeString!T)
    {
        alias Element = typeof(T.init[0]);
        auto values = collectValues(args, index, inlineValue, hasInlineValue, true);
        if (values.empty)
            return error(CliError(
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
                    return error(parsed.error);
                target ~= parsed.value;
            }
        }

        return ok();
    }
    else static if (isIntegral!T && !is(T == enum) && !is(T == bool))
    {
        if (optionInfo.counter_ && !hasInlineValue && isNextValueMissing(args, index))
        {
            target++;
            index++;
            return ok();
        }

        auto values = collectValues(args, index, inlineValue, hasInlineValue, false);
        if (values.empty)
            return error(CliError(
                kind: CliErrorKind.parse,
                message: "Missing value for " ~ originalArg,
            ));

        auto parsed = parseValue!T(values[0], optionInfo);
        if (!parsed)
            return error(parsed.error);
        target = parsed.value;
        return ok();
    }
    else
    {
        auto values = collectValues(args, index, inlineValue, hasInlineValue, false);
        if (values.empty)
            return error(CliError(
                kind: CliErrorKind.parse,
                message: "Missing value for " ~ originalArg,
            ));

        auto parsed = parseValue!T(values[0], optionInfo);
        if (!parsed)
            return error(parsed.error);
        target = parsed.value;
        return ok();
    }
}

private string[] collectValues(
    string[] args,
    ref size_t index,
    string inlineValue,
    bool hasInlineValue,
    bool variadic,
) @safe
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

private bool isNextValueMissing(string[] args, size_t index) @safe
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
                    return error(CliError(
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
                                return error(parsed.error);
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
                        return error(parsed.error);
                    __traits(getMember, receiver, field) = parsed.value;
                    valueIndex++;
                }
                seen[field] = true;
            }
        }}
    }}

    if (valueIndex < values.length)
        return error(CliError(
            kind: CliErrorKind.parse,
            message: "Unexpected positional argument " ~ values[valueIndex],
        ));

    return ok();
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
                return error(CliError(
                    kind: CliErrorKind.parse,
                    message: "Missing required option " ~ displayOption(options[0], field),
                ));
        }}
    }}

    return ok();
}

private CliExpected!T parseValue(T)(string value, Option optionInfo)
{
    if (optionInfo.allowedValues_.length && !optionInfo.allowedValues_.canFind(value))
        return error!T(CliError(
            kind: CliErrorKind.parse,
            message: "Invalid value `" ~ value ~ "`; expected one of: " ~ optionInfo.allowedValues_.join(", "),
        ));

    static if (is(T == string))
        return ok(value);
    else static if (is(T == enum))
    {
        try
            return ok(value.to!T);
        catch (Exception)
        {
            return error!T(CliError(
                kind: CliErrorKind.parse,
                message: "Invalid value `" ~ value ~ "` for " ~ T.stringof,
            ));
        }
    }
    else
    {
        try
            return ok(value.to!T);
        catch (Exception)
        {
            return error!T(CliError(
                kind: CliErrorKind.parse,
                message: "Invalid value `" ~ value ~ "` for " ~ T.stringof,
            ));
        }
    }
}

private CliExpected!bool parseBool(string value) @safe
{
    switch (value.toLower)
    {
        case "true":
        case "yes":
        case "y":
        case "1":
            return ok(true);
        case "false":
        case "no":
        case "n":
        case "0":
            return ok(false);
        default:
            return error!bool(CliError(
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
    else static if (hasCommandChildren!Cli)
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

/// Subcommand types directly under `Container`. Resolves to either the
/// `SumType` variants (legacy `@Subcommands SumType!(...)` model) or the
/// `commandChildren!Container` graph (nested `@(Command)` structs and
/// `mixin addSubCommand!T` registrations).
private template subcommandChildTypes(Container)
{
    static if (isSumType!Container)
        alias subcommandChildTypes = Container.Types;
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

private enum OptionMatch
{
    none,
    direct,
    negated,
}

private OptionMatch matchesOption(Option optionInfo, string field, string name, bool isLong) @safe
{
    foreach (candidate; optionNames(optionInfo, field))
        if (candidate == name)
            return OptionMatch.direct;

    if (isLong && name.startsWith("no-"))
    {
        foreach (candidate; optionNames(optionInfo, field))
            if (candidate == name["no-".length .. $])
                return OptionMatch.negated;
    }

    return OptionMatch.none;
}

private string[] optionNames(Option optionInfo, string field) @safe
{
    return optionInfo.aliases.length
        ? optionInfo.aliases.split("|")
        : [field];
}

private string displayOption(Option optionInfo, string field) @safe
{
    return optionDisplayName(optionNames(optionInfo, field)[$ - 1]);
}

private string optionDisplayName(string name) @safe pure nothrow
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

private string positionalName(string field, Argument argumentInfo) @safe
{
    return argumentInfo.placeholder_.length ? argumentInfo.placeholder_ : field.toUpper;
}

private bool isHelpToken(string arg) @safe pure nothrow @nogc
{
    return arg.among("-h", "--help") != 0;
}

private enum isSumType(T) = __traits(compiles, AliasSeq!(T.Types));

private enum isCommandNode(T) = __traits(hasMember, T, "__sparklesCommandNodeMarker");

private enum hasSubcommands(T) = subcommandsFieldName!T.length != 0;

private enum hasCommandChildren(T) = commandChildren!T.length != 0;

private enum usesSynthesizedSubcommands(T) = !hasSubcommands!T && hasCommandChildren!T;

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

template commandChildren(T)
{
    alias children = commandChildrenImpl!(T, __traits(allMembers, T));
    static assert(!hasDuplicateCommandTypes!children,
        "Duplicate subcommand type registered under `" ~ T.stringof ~ "`.");
    static assert(!hasDuplicateCommandNames!children,
        "Duplicate subcommand name registered under `" ~ T.stringof ~ "`.");
    alias commandChildren = children;
}

private template commandChildrenImpl(T, names...)
{
    static if (names.length == 0)
        alias commandChildrenImpl = AliasSeq!();
    else
        alias commandChildrenImpl = AliasSeq!(
            commandChildForMember!(T, names[0]),
            commandChildrenImpl!(T, names[1 .. $]),
        );
}

private template commandChildForMember(T, string name)
{
    static if (!__traits(compiles, __traits(getMember, T, name)))
        alias commandChildForMember = AliasSeq!();
    else
    {
        alias symbol = __traits(getMember, T, name);
        static if (__traits(compiles, typeof(symbol)))
        {
            alias MemberType = typeof(symbol);
            static if (is(MemberType == SubCommandRegistration!CommandType, CommandType))
                alias commandChildForMember = AliasSeq!CommandType;
            else static if (is(MemberType == SubCommandRegistrationWithHandler!(CommandType, handler), CommandType, alias handler))
                alias commandChildForMember = AliasSeq!CommandType;
            else
                alias commandChildForMember = AliasSeq!();
        }
        else static if (__traits(compiles, getUDAs!(symbol, Command))
            && getUDAs!(symbol, Command).length)
        {
            alias commandChildForMember = AliasSeq!symbol;
        }
        else
            alias commandChildForMember = AliasSeq!();
    }
}

private template registeredHandler(Parent, Child)
{
    static if (is(Parent == void))
        static assert(false, "No parent command is available for handler lookup.");
    else
        alias registeredHandler = registeredHandlerImpl!(Parent, Child, __traits(allMembers, Parent));
}

private template registeredHandlerImpl(Parent, Child, names...)
{
    static if (names.length == 0)
    {
        static assert(false, "No registered handler found.");
    }
    else static if (!__traits(compiles, __traits(getMember, Parent, names[0])))
    {
        alias registeredHandlerImpl = registeredHandlerImpl!(Parent, Child, names[1 .. $]);
    }
    else
    {
        alias symbol = __traits(getMember, Parent, names[0]);
        static if (__traits(compiles, typeof(symbol)))
        {
            alias MemberType = typeof(symbol);
            static if (is(MemberType == SubCommandRegistrationWithHandler!(CommandType, handler), CommandType, alias handler)
                && is(CommandType == Child))
            {
                alias registeredHandlerImpl = handler;
            }
            else
                alias registeredHandlerImpl = registeredHandlerImpl!(Parent, Child, names[1 .. $]);
        }
        else
            alias registeredHandlerImpl = registeredHandlerImpl!(Parent, Child, names[1 .. $]);
    }
}

private enum hasRegisteredHandler(Parent, Child) = !is(Parent == void)
    && __traits(compiles, registeredHandler!(Parent, Child));

private template hasDuplicateCommandTypes(commands...)
{
    static if (commands.length < 2)
        enum hasDuplicateCommandTypes = false;
    else
        enum hasDuplicateCommandTypes = commandTypeIn!(commands[0], commands[1 .. $])
            || hasDuplicateCommandTypes!(commands[1 .. $]);
}

private template commandTypeIn(Command, commands...)
{
    static if (commands.length == 0)
        enum commandTypeIn = false;
    else
        enum commandTypeIn = is(Command == commands[0])
            || commandTypeIn!(Command, commands[1 .. $]);
}

private template hasDuplicateCommandNames(commands...)
{
    static if (commands.length < 2)
        enum hasDuplicateCommandNames = false;
    else
        enum hasDuplicateCommandNames = commandNameIn!(commandPrimaryName!(commands[0]), commands[1 .. $])
            || hasDuplicateCommandNames!(commands[1 .. $]);
}

private template commandNameIn(string name, commands...)
{
    static if (commands.length == 0)
        enum commandNameIn = false;
    else
        enum commandNameIn = commandPrimaryName!(commands[0]) == name
            || commandNameIn!(name, commands[1 .. $]);
}

/// Read the raw `@Command` UDA from `T`, with no section resolution.
/// Falls back to a default-named `Command` when `T` lacks a UDA.
private Command commandInfoRaw(T)() @safe
{
    enum udas = getUDAs!(T, Command);
    static if (udas.length == 0)
        return Command(T.stringof);
    else
        return udas[0];
}

/// Read the `@Command` UDA from `Cli` and resolve any deferred
/// `helpSections(...)` import list, using `Root`'s views root and the
/// subcommand chain `Root → … → Cli` to compute import paths.
private Command commandInfo(Root, Cli)() @safe
{
    auto result = commandInfoRaw!Cli();
    if (result.sectionsToImport_.length > 0)
    {
        result.sections_ = sectionsForCommand!(Root, Cli)();
        result.sectionsToImport_ = null;
    }
    return result;
}

private string[] commandNames(T)() @safe
{
    enum info = commandInfoRaw!T();
    return [info.name] ~ info.aliases;
}

private string commandPrimaryName(T)() @safe
{
    return commandInfoRaw!T().name;
}

private int callRun(Parent, T, Program)(ref T value, ref Program program)
{
    static if (hasRegisteredHandler!(Parent, T))
        return callHandler!(registeredHandler!(Parent, T), T, Program)(value, program);
    else static if (__traits(compiles, T.run!Program(program)))
    {
        static if (is(typeof(T.run!Program(program)) == int))
            return T.run!Program(program);
        else
        {
            T.run!Program(program);
            return 0;
        }
    }
    else static if (__traits(compiles, T.run(program)))
    {
        static if (is(typeof(T.run(program)) == int))
            return T.run(program);
        else
        {
            T.run(program);
            return 0;
        }
    }
    else static if (__traits(compiles, value.run()))
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
    {
        static assert(false,
            "Terminal CLI struct `" ~ T.stringof ~ "` is missing a runnable "
            ~ "handler. Expected a registered handler, "
            ~ "`static int run(Program)(in Program program)`, "
            ~ "`static void run(Program)(in Program program)`, "
            ~ "`int run()`, or `void run()`.");
    }
}

private int callHandler(alias handler, T, Program)(ref T value, ref Program program)
{
    static if (__traits(compiles, handler!Program(program)))
    {
        static if (is(typeof(handler!Program(program)) == int))
            return handler!Program(program);
        else
        {
            handler!Program(program);
            return 0;
        }
    }
    else static if (__traits(compiles, handler(program)))
    {
        static if (is(typeof(handler(program)) == int))
            return handler(program);
        else
        {
            handler(program);
            return 0;
        }
    }
    else static if (__traits(compiles, handler()))
    {
        static if (is(typeof(handler()) == int))
            return handler();
        else
        {
            handler();
            return 0;
        }
    }
    else
    {
        static assert(false,
            "Registered handler for `" ~ T.stringof ~ "` has an unsupported "
            ~ "signature. Expected the same callable shapes as `run`.");
    }
}

///
@("args.Command.helpSections.repeatedCallsAppend")
@safe
unittest
{
    @(Command("tool")
        .helpSections("description", "examples")
        .helpSections("environment"))
    static struct Cli {}

    enum command = commandInfoRaw!Cli();
    assert(command.sectionsToImport_ == [
        "description",
        "examples",
        "environment",
    ]);
}

///
@("args.parseCli.namedArguments")
@system
unittest
{
    @(Command("tool", shortDescription: "Example tool"))
    struct Cli
    {
        @(Option("v|verbose", counter: true))
        uint verbose;

        @(Option("mode", allowedValues: ["fast", "slow"]))
        string mode;

        @(Argument("path", optional: true))
        string path;
    }

    auto parsed = parseCli!Cli(["tool", "-v", "-v", "--mode", "fast", "README.md"]);
    assert(parsed);
    assert(parsed.value.verbose == 2);
    assert(parsed.value.mode == "fast");
    assert(parsed.value.path == "README.md");
}

///
@("args.parseCli.options")
@system
unittest
{
    struct Cli
    {
        @(Option("v|verbose", counter: true))
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
    @(Command("init", shortDescription: "Create files"))
    static struct Init
    {
        @(Option("force"))
        bool force;

        int run() => force ? 7 : 3;
    }

    @(Command("build", aliases: ["b"]))
    static struct Build
    {
        @(Option("release"))
        bool release_;

        int run() => 0;
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
    @(Command("tool", description: "Example tool"))
    struct Cli
    {
        @(Option("v|verbose", description: "Increase verbosity."))
        bool verbose;
    }

    auto parsed = parseCli!Cli(["tool", "--help"]);
    assert(!parsed);
    assert(parsed.error.isHelp);
    assert(parsed.error.help.canFind("NAME"));
    assert(parsed.error.help.canFind("--verbose"));
}

@("args.parseCli.explicitNoPrefixedOptionWins")
@system
unittest
{
    // `--no-color` here is an explicit user-defined option, not a negation
    // of `--color`. The matcher must take the direct alias and leave the
    // value alone instead of silently coercing it to "false".
    struct Cli
    {
        @(Option("no-color"))
        bool noColor;
    }

    auto parsed = parseCli!Cli(["tool", "--no-color"]);
    assert(parsed);
    assert(parsed.value.noColor);
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

@("args.callRun.staticAssertsOnMissingRun")
@safe
unittest
{
    @(Command("leaf"))
    static struct Leaf
    {
        // intentionally no `run()` method
    }

    @(Command("tool"))
    static struct Tool
    {
        @Subcommands
        SumType!Leaf command;
    }

    Tool tool;
    static assert(!__traits(compiles, runParsedCli(tool)),
        "runParsedCli should fail to compile when a leaf lacks run()");
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
    @(Command("docker", viewsRoot: "custom-views"))
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

@("args.parseCli.nestedCommandStructs")
@system
unittest
{
    @(Command("git"))
    static struct Git
    {
        @(Option(`C`))
        string directory;

        @(Command("worktree"))
        static struct Worktree
        {
            @(Option("verbose"))
            bool verbose;

            @(Command("list"))
            static struct List
            {
                @(Option("porcelain"))
                bool porcelain;

                static int run(Program)(in Program program)
                {
                    return program.value.directory == "repo" ? 19 : 3;
                }
            }
        }
    }

    auto parsed = parseCli!Git(["git", "-C", "repo", "worktree", "--verbose", "list", "--porcelain"]);
    assert(parsed);
    assert(parsed.value.value.directory == "repo");
    parsed.value.command.match!((ref worktree) {
        assert(worktree.value.verbose);
        worktree.command.match!((ref list) {
            assert(list.value.porcelain);
            return 0;
        });
        return 0;
    });
    assert(runParsedCli(parsed.value) == 19);
}

@("args.parseCli.mixedNestedAndExternalSubcommands")
@system
unittest
{
    @(Command("status"))
    static struct Status
    {
        @(Option(`s|short`))
        bool short_;
    }

    static int statusHandler(Program)(in Program program)
    {
        return 41;
    }

    @(Command("git"))
    static struct Git
    {
        mixin addSubCommand!(Status, statusHandler);

        @(Command("worktree"))
        static struct Worktree
        {
            static int run(Program)(in Program program)
            {
                return 5;
            }
        }
    }

    static assert(commandChildren!Git.length == 2);

    auto parsed = parseCli!Git(["git", "status", "--short"]);
    assert(parsed);
    parsed.value.command.match!((ref command) {
        static if (is(typeof(command.value) == Status))
            assert(command.value.short_);
        return 0;
    });
    assert(runParsedCli(parsed.value) == 41);
}

@("args.parseCli.defaultCommandGroup")
@system
unittest
{
    @(Command("git"))
    static struct Git
    {
        @(Command("worktree", isDefault: true))
        static struct Worktree
        {
            @(Option("verbose"))
            bool verbose;

            static int run(Program)(in Program program)
            {
                return 23;
            }

            @(Command("list"))
            static struct List
            {
                int run() => 7;
            }
        }
    }

    auto parsed = parseCli!Git(["git", "worktree", "--verbose"]);
    assert(parsed);
    assert(runParsedCli(parsed.value) == 23);
}

@("args.parseCli.makeDefaultRejectedOnLegacySumTypeModel")
@safe
unittest
{
    @(Command("init"))
    static struct Init
    {
        int run() => 0;
    }

    @(Command("tool", isDefault: true))
    static struct Tool
    {
        @Subcommands
        SumType!Init command;
    }

    // `makeDefault()` cannot be honored under the legacy
    // `@Subcommands SumType` model — instantiating `parseCli` should fail
    // at compile time with a clear diagnostic.
    static assert(!__traits(compiles, parseCli!Tool([])));
}

@("args.parseCli.commandGroupRequiresSubcommandWithoutDefault")
@system
unittest
{
    @(Command("git"))
    static struct Git
    {
        @(Command("worktree"))
        static struct Worktree
        {
            @(Command("list"))
            static struct List
            {
                int run() => 7;
            }
        }
    }

    auto parsed = parseCli!Git(["git", "worktree"]);
    assert(!parsed);
    assert(parsed.error.message == "Missing subcommand");
    assert(parsed.error.help.canFind("git worktree"));
    assert(parsed.error.help.canFind("list"));
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

        @(Option("secret", hidden: true))
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
