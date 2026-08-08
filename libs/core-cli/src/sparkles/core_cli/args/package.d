module sparkles.core_cli.args;

public import sparkles.core_cli.args.error :
    CliError,
    CliExpected,
    Expected,
    error,
    ok;

public import sparkles.core_cli.args.help_formatting :
    importSections,
    tryImport;

// The pre-subcommand parser. Superseded by `parseCli` below, but still the API
// nineteen call sites across the monorepo use; see `args.legacy`.
public import sparkles.core_cli.args.legacy :
    CliOption,
    cliOption,
    parseCliArgs;

public import sparkles.core_cli.args.internal :
    CommandNode,
    ParsedCommand,
    commandChildren,
    parseCli,
    parseKnownCli,
    runCli,
    runParsedCli;

public import sparkles.core_cli.args.uda :
    Argument,
    Command,
    Option,
    SubCommandRegistration,
    SubCommandRegistrationWithHandler,
    Subcommands,
    addSubCommand,
    identifierSafe;

public import sparkles.core_cli.help_formatting :
    HelpInfo,
    Sections,
    formatParagraph,
    formatSection;
