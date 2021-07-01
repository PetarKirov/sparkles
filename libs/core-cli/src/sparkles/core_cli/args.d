module sparkles.core_cli.args;

public import sparkles.core_cli.help_formatting : HelpInfo;

void parseCliArgs(CliOptions...)(
    ref string[] argv,
    HelpInfo helpInfo,
    CliOptions options,
)
{
    import core.stdc.stdlib : exit;
    import std.getopt : getopt;
    import std.stdio : writeln;
    import sparkles.core_cli.help_formatting : formatProgramManual;

    auto getOptResult = argv.getopt(options);

    if (getOptResult.helpWanted)
    {
        helpInfo
            .formatProgramManual(getOptResult.options)
            .writeln;
        exit(0);
    }
}
