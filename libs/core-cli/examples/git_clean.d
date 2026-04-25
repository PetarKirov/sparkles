#!/usr/bin/env dub

/+ dub.sdl:
name "git-clean"
dependency "sparkles:core-cli" path="../../.."
targetPath "build"
+/

import sparkles.core_cli.args;

struct CliParams
{
    @(option!`d`)
    bool deleteDirectories;

    @(option!`f|force`)
    bool force;

    @(option!`i|interactive`)
    bool interactive;

    @(Option(`n|dry-run`, "Don’t actually remove anything, just show what would be done."))
    bool dryRun;

    @(option!`q|quiet`)
    bool quiet;

    @(option!`e|exclude`)
    string excludePattern;

    @(option!`x`)
    bool deleteUntracked;

    @(option!`X`)
    bool deleteIgnored;
}

void main(string[] args)
{
    const parsed = parseCli!CliParams(
        args,
        HelpInfo(
            "git clean",
            "Remove untracked files from the working tree",
            importSections!([
                "description",
                "interactive mode"
            ])
        ),
    );
    if (!parsed)
    {
        import std.stdio : stderr, writeln;

        if (parsed.error.help.length)
            writeln(parsed.error.help);
        else
            stderr.writeln("Error: ", parsed.error.message);
        return;
    }

    import std.stdio : writeln;
    const cli = parsed.value;
    cli.writeln;
}
