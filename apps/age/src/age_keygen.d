/++
`age-keygen` command-line tool: generate age X25519 identities and convert an
identity file to its `age1…` recipients.

This is a thin entry point. It parses the command line (`-o/--output`, `-y`, and
the optional positional `INPUT`) and hands a
$(REF KeygenOptions, sparkles,age_cli,keygen_flow) to
$(REF runKeygen, sparkles,age_cli,keygen_flow), which holds the testable flow.
On any failure it prints rage's `Error: <message>` block — the message body, a
blank line, and the shared UX footer — to standard error and exits with status
`1`. (The flow modules live under `sparkles.age_cli.*`; this file is excluded
from the `unittest` configuration, so it carries no tests of its own.)

# Usage

```
age-keygen [-o OUTPUT]
age-keygen -y [-o OUTPUT] [INPUT]
```

$(UL
    $(LI With no `-y`: generate a fresh identity file. Written to `OUTPUT`
        (mode `0600`, never overwriting an existing file) or standard output;
        when the output is not a terminal the public key is echoed to standard
        error.)
    $(LI With `-y`: read the identity file `INPUT` (or standard input) and write
        one `age1…` recipient per native identity to `OUTPUT` / standard output.)
)

Copyright: © 2026, Petar Kirov
License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
Authors: Petar Kirov
+/
module age_keygen_main;

import std.stdio : stderr;

import sparkles.age_cli.keygen_flow : KeygenError, KeygenOptions, runKeygen;
import sparkles.age_cli.usage : keygenUsage, requestedHelp;

/++
The `age-keygen` entry point.

Parses `args`, runs the keygen flow, and maps any thrown error onto rage's
`Error: …` diagnostic + UX footer on standard error.

Returns: `0` on success, `1` on any error (usage, I/O, or conversion failure).
+/
int main(string[] args) @system
{
    // Handle help BEFORE anything else — critically, before the default flow,
    // which would otherwise generate and print a private key on `--help`.
    if (requestedHelp(args))
    {
        import std.stdio : write;
        write(keygenUsage);
        return 0;
    }

    KeygenOptions opts;
    try
        opts = parseKeygenArgs(args);
    catch (Exception e)
    {
        // A malformed command line: print the usage error like any other.
        printError(e.msg);
        return 1;
    }

    try
        runKeygen(opts);
    catch (Exception e)
    {
        printError(e.msg);
        return 1;
    }

    return 0;
}

// ─────────────────────────────────────────────────────────────────────────────
// Argument parsing
// ─────────────────────────────────────────────────────────────────────────────

/++
Parses the `age-keygen` command line into a
$(REF KeygenOptions, sparkles,age_cli,keygen_flow).

Recognises `-o/--output <F>` and the `-y` convert toggle via `std.getopt`
(case-sensitive, bundling), then recovers the single optional positional
`INPUT` from the leftover args. More than one positional is a usage error.

Params:
    args = the full process argument vector (including `args[0]`); modified in
        place by `getopt`.

Returns: the parsed options.

Throws: `std.getopt.GetOptException` on an unknown option / missing argument, or
    `Exception` if more than one positional is supplied.
+/
KeygenOptions parseKeygenArgs(ref string[] args) @system
{
    import std.getopt : config, getopt;

    KeygenOptions opts;
    args.getopt(
        config.caseSensitive,
        config.bundling,
        "output|o", &opts.output,
        "y", &opts.convert,
    );

    // getopt leaves args[0] (the program name) plus any positionals.
    auto positionals = args.length > 1 ? args[1 .. $] : null;
    if (positionals.length > 1)
        throw new Exception(
            "Too many positional arguments; age-keygen accepts at most one INPUT file.");
    if (positionals.length == 1)
        opts.input = positionals[0];

    return opts;
}

// ─────────────────────────────────────────────────────────────────────────────
// Error reporting
// ─────────────────────────────────────────────────────────────────────────────

// rage's shared UX footer, printed after every error (`rage.ftl` err-ux-*).
private enum string UX_FOOTER =
    "[ Did rage not do what you expected? Could an error be more useful? ]\n"
    ~ "[ Tell us: https://str4d.xyz/rage/report                            ]";

// Print a rage-style error block to stderr: `Error: <body>`, a blank line, then
// the UX footer. Isolated in @trusted because `stderr` is @system.
private void printError(scope const(char)[] body_) @trusted
{
    stderr.writeln("Error: ", body_);
    stderr.writeln();
    stderr.writeln(UX_FOOTER);
}
