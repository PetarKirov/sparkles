#!/usr/bin/env dub

/+ dub.sdl:
name "git-clean"
dependency "sparkles:core-cli" version="*"
targetPath "build"
+/

import sparkles.core_cli.args;

struct CliParams
{
    @cliOption!`d`
    bool deleteDirectories;

    @cliOption!`f|force`
    bool force;

    @cliOption!`i|interactive`
    bool interactive;

    @CliOption(`n|dry-run`, "Don’t actually remove anything, just show what would be done.")
    bool dryRun;

    @cliOption!`q|quiet`
    bool quiet;

    @cliOption!`e|exclude`
    string excludePattern;

    @cliOption!`x`
    bool deleteUntracked;

    @cliOption!`X`
    bool deleteIgnored;
}

void main(string[] args)
{
    import std.string : split, stripRight;
    const cli = args.parseCliArgs!CliParams(
        HelpInfo(
            "git clean",
            "Remove untracked files from the working tree",
            importSections!([
                "description",
                "interactive mode"
            ])
        ),
    );

    import std.stdio : writeln;
    cli.writeln;
}
