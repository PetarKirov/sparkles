module sparkles.core_cli.args;

public import sparkles.core_cli.args.error :
    CliError,
    CliExpected,
    Expected,
    RunError,
    RunExpected,
    error,
    failRun,
    ok,
    ranOk,
    skipRun;

public import sparkles.core_cli.args.help_formatting :
    importSections,
    tryImport;

public import sparkles.core_cli.args.internal :
    CommandNode,
    ParsedCommand,
    commandChildren,
    parseCli,
    parseKnownCli,
    reportCliError,
    runCli,
    runParsedCli;

public import sparkles.core_cli.args.switches : isSwitches, Switches;

public import sparkles.core_cli.args.uda :
    Argument,
    Command,
    Description,
    Flatten,
    Option,
    SubCommandRegistration,
    SubCommandRegistrationWithHandler,
    Subcommands,
    addSubCommand,
    getFlatten,
    hasFlatten,
    identifierSafe;

public import sparkles.core_cli.help_formatting :
    HelpInfo,
    Sections,
    formatParagraph,
    formatSection;

public import sparkles.base.assert_handler :
    AssertHandlerKind,
    abortAssertHandler,
    installAssertHandler,
    preScanAndInstallAssertHandler;
