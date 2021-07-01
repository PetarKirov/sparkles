import sparkles.core_cli.args;

void main()
{
    args.parseCliArgs(
        HelpInfo(
            "git-clean",
            "Remove untracked files from the working tree",
        ),
        "c|count", "How many contracts to verify", &count,
        "s|skip", "How many contracts to skip verifying from the list. Default is 0.", &skipContractsCount,
        "n|network", "Network id identifying the 'networks/<id>[_args].json' file to use", &network,
        "p|parallel", "Enable parallel verification", &parallel,
    );
}
