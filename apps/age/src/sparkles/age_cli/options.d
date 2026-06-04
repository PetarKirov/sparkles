/++
Command-line option parsing for the `age` tool.

Defines $(LREF AgeOptions) — the parsed-options struct mirroring rage's
`AgeOptions` (`rage/src/bin/rage/cli.rs`) — and $(LREF parseAgeOptions), a
`std.getopt`-based parser.

# Why `std.getopt` directly (not `sparkles.core_cli.args`)

`age` has $(B repeatable) value flags (`-r`, `-R`, `-i` may each appear many
times and accumulate into a list). `std.getopt`'s `config.append` handles that
natively when the bound field is a `string[]`, so this module drives `getopt`
directly rather than going through the UDA-table front-end in
`sparkles.core_cli.args`. The remaining surface (bool flags, a single optional
`-o`/`-j`, and `--max-work-factor`) maps onto plain `getopt` bindings, and the
sole positional `INPUT` is recovered from the leftover args by hand.

# Positional INPUT

After `getopt` consumes the recognised options it leaves any positionals in the
`argv` slice (with `argv[0]` still the program name). `age` accepts $(B at most
one) positional, the input path; absent or `"-"` means standard input. A second
positional is a usage error.

Copyright: © 2026, Petar Kirov
License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
Authors: Petar Kirov
+/
module sparkles.age_cli.options;

import std.typecons : Nullable;

/++
The parsed command line for the `age` tool.

Field meanings track rage's `AgeOptions` one-for-one. The repeatable flags
(`recipients`, `recipientsFiles`, `identities`) accumulate in command-line
order. `input` and `output` use `null` to mean "not given"; an explicit `"-"`
(meaning stdin/stdout) is preserved verbatim so the I/O layer can distinguish
it from a real path.

Booleans default to `false`; `maxWorkFactor` and the optional path/string
fields default to their `.init` (`Nullable` null / empty `string`).
+/
struct AgeOptions
{
    /// `-e/--encrypt`: encrypt the input (the default mode when neither
    /// `-e` nor `-d` is given).
    bool encrypt;

    /// `-d/--decrypt`: decrypt the input.
    bool decrypt;

    /// `-p/--passphrase`: encrypt with a passphrase instead of recipients.
    bool passphrase;

    /// `-a/--armor`: encrypt to the PEM "armored" encoding.
    bool armor;

    /// `--max-work-factor <N>`: cap the scrypt work factor accepted when
    /// decrypting a passphrase-encrypted file. `Nullable` null when unset.
    Nullable!ubyte maxWorkFactor;

    /// `-r/--recipient <R>` (repeatable): explicit recipients.
    string[] recipients;

    /// `-R/--recipients-file <F>` (repeatable): files listing recipients.
    string[] recipientsFiles;

    /// `-i/--identity <F>` (repeatable): identity files (`"-"` = stdin).
    string[] identities;

    /// `-j <PLUGIN>`: plugin name. Unsupported in this build (see
    /// `sparkles.age_cli.errors.CliError.pluginsUnsupported`); captured so
    /// validation can report the dedicated error. `null` when unset.
    string pluginName;

    /// `-o/--output <F>`: output path (`"-"` = stdout). `null` when unset.
    string output;

    /// The positional INPUT path. `null` (or `"-"`) means standard input.
    string input;
}

/++
Parse `argv` into an $(LREF AgeOptions).

Drives `std.getopt` with `config.bundling` (so short flags such as `-ea` can be
combined) and `config.caseSensitive` (rage distinguishes `-r` from `-R`).
Repeatable value flags use `config.append`. After option processing the single
optional positional INPUT is extracted from the leftover args.

This function is `@system` because `std.getopt` is `@system`; that is fine for
an application entry point. On a malformed command line (`getopt` throws a
`GetOptException`, or more than one positional is supplied) the exception
propagates / a descriptive `Exception` is thrown for the caller's top-level
handler to print.

Params:
    argv = the full process argument vector ($(B including) `argv[0]`); modified
        in place by `getopt` as it removes recognised options.

Returns: the populated $(LREF AgeOptions).

Throws: `std.getopt.GetOptException` on an unknown option or a missing option
        argument; `Exception` if more than one positional argument is given.
+/
AgeOptions parseAgeOptions(ref string[] argv) @system
{
    import std.conv : to;
    import std.getopt : getopt, config;

    AgeOptions opts;

    // `--max-work-factor` is optional, and a literal `0` is a meaningful value,
    // so we can't use a sentinel default to detect presence. A delegate handler
    // sets the `Nullable` field only when the flag actually appears.
    void onMaxWorkFactor(string, string value)
    {
        opts.maxWorkFactor = value.to!ubyte;
    }

    argv.getopt(
        config.caseSensitive,
        config.bundling,
        "encrypt|e", &opts.encrypt,
        "decrypt|d", &opts.decrypt,
        "passphrase|p", &opts.passphrase,
        "armor|a", &opts.armor,
        "max-work-factor", &onMaxWorkFactor,
        // Array-valued options accumulate across repeated occurrences
        // automatically in std.getopt (no `config` flag needed).
        "recipient|r", &opts.recipients,
        "recipients-file|R", &opts.recipientsFiles,
        "identity|i", &opts.identities,
        "j", &opts.pluginName,
        "output|o", &opts.output,
    );

    extractPositionalInput(argv, opts);
    return opts;
}

/++
Pull the single optional positional INPUT out of the post-`getopt` `argv`.

`getopt` leaves `argv[0]` (the program name) plus any positionals. `age`
accepts at most one positional; more than one is a usage error.

Params:
    argv = the leftover arguments after `getopt` (still including `argv[0]`).
    opts = the options struct whose `input` field is filled.

Throws: `Exception` when more than one positional is present.
+/
private void extractPositionalInput(ref string[] argv, ref AgeOptions opts) @safe pure
{
    // argv[0] is the program name; positionals follow.
    auto positionals = argv.length > 1 ? argv[1 .. $] : null;

    if (positionals.length > 1)
        throw new Exception(
            "Too many positional arguments; age accepts at most one INPUT file.");

    if (positionals.length == 1)
        opts.input = positionals[0];
}

@("cli.options.defaults")
@safe pure nothrow @nogc
unittest
{
    AgeOptions opts;
    assert(!opts.encrypt);
    assert(!opts.decrypt);
    assert(!opts.passphrase);
    assert(!opts.armor);
    assert(opts.maxWorkFactor.isNull);
    assert(opts.recipients.length == 0);
    assert(opts.recipientsFiles.length == 0);
    assert(opts.identities.length == 0);
    assert(opts.pluginName is null);
    assert(opts.output is null);
    assert(opts.input is null);
}

@("cli.options.parse.basicEncrypt")
@system
unittest
{
    auto argv = ["age", "-e", "-r", "age1abc", "-o", "out.age", "in.txt"];
    auto opts = parseAgeOptions(argv);

    assert(opts.encrypt);
    assert(!opts.decrypt);
    assert(opts.recipients == ["age1abc"]);
    assert(opts.output == "out.age");
    assert(opts.input == "in.txt");
}

@("cli.options.parse.repeatableFlags")
@system
unittest
{
    auto argv = [
        "age",
        "-r", "age1a", "-r", "age1b",
        "-R", "rec1.txt", "-R", "rec2.txt",
        "-i", "id1.txt", "-i", "-",
    ];
    auto opts = parseAgeOptions(argv);

    assert(opts.recipients == ["age1a", "age1b"]);
    assert(opts.recipientsFiles == ["rec1.txt", "rec2.txt"]);
    assert(opts.identities == ["id1.txt", "-"]);
}

@("cli.options.parse.longForms")
@system
unittest
{
    auto argv = [
        "age", "--decrypt", "--identity", "key.txt", "--output", "plain.txt",
    ];
    auto opts = parseAgeOptions(argv);

    assert(opts.decrypt);
    assert(opts.identities == ["key.txt"]);
    assert(opts.output == "plain.txt");
}

@("cli.options.parse.caseSensitiveShortFlags")
@system
unittest
{
    // -r and -R are distinct (case-sensitive).
    auto argv = ["age", "-r", "lower", "-R", "upper.txt"];
    auto opts = parseAgeOptions(argv);

    assert(opts.recipients == ["lower"]);
    assert(opts.recipientsFiles == ["upper.txt"]);
}

@("cli.options.parse.pluginName")
@system
unittest
{
    auto argv = ["age", "-d", "-j", "yubikey"];
    auto opts = parseAgeOptions(argv);

    assert(opts.decrypt);
    assert(opts.pluginName == "yubikey");
}

@("cli.options.parse.dashInputIsStdin")
@system
unittest
{
    auto argv = ["age", "-d", "-"];
    auto opts = parseAgeOptions(argv);

    assert(opts.input == "-");
}

@("cli.options.parse.noPositionalLeavesInputNull")
@system
unittest
{
    auto argv = ["age", "-e", "-p"];
    auto opts = parseAgeOptions(argv);

    assert(opts.input is null);
}

@("cli.options.parse.tooManyPositionalsThrows")
@system
unittest
{
    auto argv = ["age", "-d", "a.age", "b.age"];
    bool threw;
    try
        cast(void) parseAgeOptions(argv);
    catch (Exception)
        threw = true;
    assert(threw);
}

@("cli.options.parse.maxWorkFactor")
@system
unittest
{
    auto argv = ["age", "-d", "--max-work-factor", "20"];
    auto opts = parseAgeOptions(argv);

    assert(!opts.maxWorkFactor.isNull);
    assert(opts.maxWorkFactor.get == 20);
}

@("cli.options.parse.maxWorkFactorZeroIsPresent")
@system
unittest
{
    // A literal 0 must register as "given" (delegate-based presence detection),
    // not be confused with the unset default.
    auto argv = ["age", "-d", "--max-work-factor", "0"];
    auto opts = parseAgeOptions(argv);

    assert(!opts.maxWorkFactor.isNull);
    assert(opts.maxWorkFactor.get == 0);

    auto argv2 = ["age", "-d"];
    auto opts2 = parseAgeOptions(argv2);
    assert(opts2.maxWorkFactor.isNull);
}
