module sparkles.core_cli.args;

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

import expected : Expected, err, ok;

import sparkles.core_cli.term_style : sty = stylizedTextBuilder;

private struct NamedOnly {}

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
    bool isDefault_;

    this(
        string name,
        NamedOnly _ = NamedOnly.init,
        string[] aliases = null,
        string shortDescription = null,
        string description = null,
        string usage = null,
        string epilog = null,
        Sections sections = Sections.init,
        string[] helpSections = null,
        bool hidden = false,
        string viewsRoot = null,
        bool isDefault = false,
    ) @safe
    {
        this.name = name;
        this.aliases = aliases.dup;
        this.shortDescription_ = shortDescription;
        this.description_ = description;
        this.usage_ = usage;
        this.epilog_ = epilog;
        this.sections_ = sections;
        this.sectionsToImport_ = helpSections.dup;
        this.hidden_ = hidden;
        this.viewsRoot_ = viewsRoot;
        this.isDefault_ = isDefault;
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

    Command helpSections(string[] sectionFileNamesToImport...) @safe
    {
        auto result = this;
        result.sectionsToImport_ ~= sectionFileNamesToImport.dup;
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

    Command makeDefault(bool value = true) @safe
    {
        auto result = this;
        result.isDefault_ = value;
        return result;
    }
}

@("args.Command.namedArguments")
@safe
unittest
{
    Sections sections;
    sections["notes"] = ["Inline section"];

    auto info = Command(
        "git",
        aliases: ["g"],
        shortDescription: "Distributed version control system",
        description: "Track source history",
        usage: "git <command>",
        epilog: "See also git help.",
        helpSections: ["description", "examples"],
        sections: sections,
        hidden: true,
        viewsRoot: "git-cli",
        isDefault: true,
    );

    assert(info.name == "git");
    assert(info.aliases == ["g"]);
    assert(info.shortDescription_ == "Distributed version control system");
    assert(info.description_ == "Track source history");
    assert(info.usage_ == "git <command>");
    assert(info.epilog_ == "See also git help.");
    assert(info.sectionsToImport_ == ["description", "examples"]);
    assert(info.sections_ == sections);
    assert(info.hidden_);
    assert(info.viewsRoot_ == "git-cli");
    assert(info.isDefault_);
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

    this(
        string aliases,
        NamedOnly _ = NamedOnly.init,
        string description = null,
        string placeholder = null,
        bool required = false,
        bool hidden = false,
        bool counter = false,
        string[] allowedValues = null,
    ) @safe
    {
        this.aliases = aliases;
        this.description_ = description;
        this.placeholder_ = placeholder;
        this.required_ = required;
        this.hidden_ = hidden;
        this.counter_ = counter;
        this.allowedValues_ = allowedValues.dup;
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

@("args.Option.namedArguments")
@safe
unittest
{
    auto info = Option(
        "L|log-level",
        description: "Set the log level.",
        placeholder: "LEVEL",
        required: true,
        hidden: true,
        counter: true,
        allowedValues: ["trace", "info"],
    );

    assert(info.aliases == "L|log-level");
    assert(info.description_ == "Set the log level.");
    assert(info.placeholder_ == "LEVEL");
    assert(info.required_);
    assert(info.hidden_);
    assert(info.counter_);
    assert(info.allowedValues_ == ["trace", "info"]);
}

struct Argument
{
    size_t position = size_t.max;
    string placeholder_;
    string description_;
    bool optional_;
    bool hidden_;

    this(
        string placeholder,
        NamedOnly _ = NamedOnly.init,
        string description = null,
        bool optional = false,
        bool hidden = false,
        size_t position = size_t.max,
    ) @safe
    {
        this.placeholder_ = placeholder;
        this.description_ = description;
        this.optional_ = optional;
        this.hidden_ = hidden;
        this.position = position;
    }

    this(
        size_t position,
        NamedOnly _ = NamedOnly.init,
        string placeholder = null,
        string description = null,
        bool optional = false,
        bool hidden = false,
    ) @safe
    {
        this.position = position;
        this.placeholder_ = placeholder;
        this.description_ = description;
        this.optional_ = optional;
        this.hidden_ = hidden;
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

@("args.Argument.namedArguments")
@safe
unittest
{
    auto byPlaceholder = Argument(
        "path",
        description: "Path to inspect.",
        optional: true,
        hidden: true,
        position: 2,
    );

    assert(byPlaceholder.placeholder_ == "path");
    assert(byPlaceholder.description_ == "Path to inspect.");
    assert(byPlaceholder.optional_);
    assert(byPlaceholder.hidden_);
    assert(byPlaceholder.position == 2);

    auto byPosition = Argument(
        0,
        placeholder: "source",
        description: "Source path.",
        optional: true,
        hidden: true,
    );

    assert(byPosition.position == 0);
    assert(byPosition.placeholder_ == "source");
    assert(byPosition.description_ == "Source path.");
    assert(byPosition.optional_);
    assert(byPosition.hidden_);
}

struct Subcommands {}

struct SubCommandRegistration(T)
{
    alias command = T;
}

struct SubCommandRegistrationWithHandler(T, alias handler_)
{
    alias command = T;
    alias handler = handler_;
}

string identifierSafe(string value) @safe pure nothrow
{
    string result;
    foreach (c; value)
    {
        immutable isLower = c >= 'a' && c <= 'z';
        immutable isUpper = c >= 'A' && c <= 'Z';
        immutable isDigit = c >= '0' && c <= '9';
        result ~= (isLower || isUpper || isDigit) ? c : '_';
    }
    return result;
}

mixin template addSubCommand(T)
{
    import sparkles.core_cli.args : identifierSafe;

    enum fieldName = "__sparklesSubCommand_" ~ identifierSafe(T.mangleof);
    mixin("private import sparkles.core_cli.args : SubCommandRegistration; "
        ~ "private SubCommandRegistration!T "
        ~ fieldName
        ~ ";");
}

mixin template addSubCommand(T, alias handler)
{
    import sparkles.core_cli.args : identifierSafe;

    enum fieldName = "__sparklesSubCommand_" ~ identifierSafe(T.mangleof);
    mixin("private import sparkles.core_cli.args : SubCommandRegistrationWithHandler; "
        ~ "private SubCommandRegistrationWithHandler!(T, handler) "
        ~ fieldName
        ~ ";");
}

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

    bool isHelp() const @safe pure nothrow @nogc => kind == CliErrorKind.help;
}

alias CliExpected(T) = Expected!(T, CliError);

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
    static if (usesSynthesizedSubcommands!Cli)
        auto parsed = parseCommandNode!(Cli, Cli)(receiver, args, info);
    else
        auto parsed = parseCommand!(Cli, Cli)(receiver, args, info);
    if (!parsed)
        return err!(ParsedCommand!Cli)(parsed.error);

    return ok!CliError(receiver);
}

CliExpected!(ParsedCommand!Cli) parseKnownCli(Cli)(
    ref string[] argv,
    ref ParsedCommand!Cli receiver,
    HelpInfo helpInfo = HelpInfo.init,
)
{
    auto info = normalizeHelpInfo!Cli(argv, helpInfo);
    auto args = argv.length > 0 ? argv[1 .. $] : argv;
    static if (usesSynthesizedSubcommands!Cli)
        auto parsed = parseCommandNode!(Cli, Cli)(receiver, args, info, true);
    else
        auto parsed = parseCommand!(Cli, Cli)(receiver, args, info, true);
    if (!parsed)
        return err!(ParsedCommand!Cli)(parsed.error);

    argv = argv.length > 0
        ? argv[0 .. 1] ~ parsed.value
        : parsed.value;
    return ok!CliError(receiver);
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

private CliExpected!(string[]) parseCommandNode(Root, Cli)(
    ref CommandNode!Cli receiver,
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

        static if (hasCommandChildren!Cli)
        {
            if (!namedArgsEnded && !arg.startsWith("-"))
            {
                auto subArgs = args[index + 1 .. $];
                auto selected = parseCommandChild!(Root, Cli)(
                    receiver.command,
                    receiver.commandSelected,
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

                return err!(string[])(CliError(
                    kind: CliErrorKind.parse,
                    message: "Unknown command: " ~ arg,
                    help: formatHelp!(Root, Cli)(helpInfo),
                ));
            }
        }

        if (!namedArgsEnded && arg.startsWith("-") && arg.length > 1)
        {
            auto parsed = parseNamedOption(receiver.value, args, index, seen);
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

    auto assignedPositionals = assignPositionals(receiver.value, positionals, seen);
    if (!assignedPositionals)
        return err!(string[])(assignedPositionals.error);

    auto required = validateRequired!Cli(seen);
    if (!required)
        return err!(string[])(required.error);

    static if (hasCommandChildren!Cli)
    {
        enum command = commandInfoRaw!Cli();
        static if (command.isDefault_)
            return ok!CliError(unknown);
        else
            return err!(string[])(CliError(
                kind: CliErrorKind.parse,
                message: "Missing subcommand",
                help: formatHelp!(Root, Cli)(helpInfo),
            ));
    }
    else
        return ok!CliError(unknown);
}

private CliExpected!(string[]) parseCommandChild(Root, Parent)(
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
            auto parsed = parseCommandNode!(Root, CommandType)(command, args, info, keepUnknown);
            if (!parsed)
                return parsed;

            destination = command;
            commandSelected = true;
            return parsed;
        }
    }}

    if (isHelpToken(name))
        return err!(string[])(CliError(
            kind: CliErrorKind.help,
            help: formatSubcommandsHelp!(Root, Parent)(parentHelp),
            exitCode: 0,
        ));

    return err!(string[])(CliError.init);
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
        // The legacy `@Subcommands SumType!(...)` storage model has no way
        // to represent "no variant selected" at runtime — `std.sumtype`
        // default-initialises to its first variant, indistinguishable from
        // an explicit selection. Surfacing that ambiguity at the
        // `makeDefault()` declaration site is clearer than silently
        // dispatching to the first variant when the user omits a
        // subcommand. Migrate to the graph-based model (nested
        // `@(Command)` structs or `mixin addSubCommand!T`) for default
        // command groups.
        enum command = commandInfoRaw!Cli();
        static assert(!command.isDefault_,
            "`makeDefault()` is not supported on `" ~ Cli.stringof
            ~ "` because it uses the legacy `@Subcommands SumType!(...)` "
            ~ "storage model. Use the graph-based subcommand model "
            ~ "(nested `@(Command)` structs or `mixin addSubCommand!T`) "
            ~ "to opt into default command groups.");
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

private CliExpected!bool parseBool(string value) @safe
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

private string[] formatSubcommands(Root, Parent)()
if (!isSumType!Parent)
{
    string[] lines;
    static foreach (CommandType; commandChildren!Parent)
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
