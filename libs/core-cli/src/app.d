import sparkles.core_cli.args;

import std.stdio;

enum Network
{
    mainnet = 1,
    ropsten = 3,
    kovan = 42,
}

struct CliParams
{
    @(Option("c|count", "How many contracts to verify"))
    uint count = uint.max;

    @(Option("s|skip", "How many contracts to skip verifying from the list. Default is 0."))
    uint skipContractsCount;

    @(Option("n|network", "Network id identifying the 'networks/<id>[_args].json' file to use"))
    Network network = Network.kovan;

    @(Option("p|parallel", "Enable parallel verification"))
    bool parallel;
}

void main(string[] args)
{
    auto parsed = parseCli!CliParams(
        args,
        HelpInfo(
            "verify-contracts",
            "verifies contracts on Etherscan, based on 'networks/<id>[_args].json' files",
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

    import sparkles.core_cli.term_size : setTermWindowSizeHandler;
    setTermWindowSizeHandler((ushort width, ushort height) {
        import core.stdc.stdio : printf;
        printf("New window size: %dx%d\n", width, height);
    });

    foreach (i; 0 .. int.max)
    {
        import core.thread : Thread;
        import core.time : msecs;
        Thread.sleep(2500.msecs);
        writefln("Awoken #%s", i);
    }
}
