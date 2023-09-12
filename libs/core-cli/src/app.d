import sparkles.core_cli.args;

import std.stdio;

enum Network
{
    mainnet = 1,
    ropsten = 3,
    kovan = 42,
}

void main(string[] args)
{
    uint count = uint.max;
    uint skipContractsCount = 0;
    Network network = Network.kovan;
    bool parallel = false;

    args.parseCliArgs(
        HelpInfo(
            "verify-contracts",
            "verifies contracts on Etherscan, based on 'networks/<id>[_args].json' files",
        ),
        "c|count", "How many contracts to verify", &count,
        "s|skip", "How many contracts to skip verifying from the list. Default is 0.", &skipContractsCount,
        "n|network", "Network id identifying the 'networks/<id>[_args].json' file to use", &network,
        "p|parallel", "Enable parallel verification", &parallel,
    );

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
