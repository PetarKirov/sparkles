/// CLI entry point for the sparkle-docs API documentation generator.
module sparkle_docs.main;

import std.getopt : getopt;
import std.stdio : stderr, writeln;

import sparkle_docs.model : Config;
import sparkle_docs.output : OutputGenerator;
import sparkle_docs.parser : DmdJsonParser;
import sparkles.core_cli.json : readJsonFile;

/// Parse command-line arguments, load config, and run the documentation generator.
int main(string[] args)
{
    Config config;
    bool verbose;
    bool showHelp;
    string configFile;
    
    auto helpText = getHelpText();
    
    try
    {
        auto opt = getopt(
            args,
            "o|output", "Output directory for JSON files (default: docs/.vitepress/data/api/)", &config.outputPath,
            "c|config", "Configuration file (sparkle-docs.json)", &configFile,
            "p|package", "Package name for docs", &config.name,
            "exclude", "Exclude files matching pattern", &config.excludePatterns,
            "include-private", "Include private symbols", &config.includePrivate,
            "output-compact", "Write compact JSON output (no pretty printing)", &config.outputCompact,
            "source-url", "Base URL for source links", &config.sourceUrl,
            "runner-url", "URL for runnable examples service", &config.runnerUrl,
            "v|verbose", "Verbose output", &verbose,
            "h|help", "Show help", &showHelp
        );
        
        if (showHelp)
        {
            writeln(helpText);
            return 0;
        }
        
        Config fileConfig;
        if (configFile.length > 0)
            fileConfig = readJsonFile!Config(configFile);

        config = mergeConfig(fileConfig, config);
        if (args.length > 1)
            config.sourcePaths = args[1..$];
        
        if (config.sourcePaths.length == 0)
        {
            stderr.writeln("Error: No source paths specified");
            writeln(helpText);
            return 1;
        }
        
        if (config.outputPath.length == 0)
            config.outputPath = "docs/.vitepress/data/api/";

        if (verbose)
        {
            writeln("Configuration:");
            writeln("  Source paths: ", config.sourcePaths);
            writeln("  Output path: ", config.outputPath);
            writeln("  Output compact: ", config.outputCompact);
            writeln("  Include private: ", config.includePrivate);
            writeln("  Exclude patterns: ", config.excludePatterns);
        }
        
        return run(config, verbose);
    }
    catch (Exception e)
    {
        stderr.writeln("Error: ", e.msg);
        return 1;
    }
}

/// Execute the parse-and-generate pipeline with the given configuration.
int run(Config config, bool verbose)
{
    if (verbose)
        writeln("Parsing D source files...");
    
    auto parser = DmdJsonParser(
        config.sourcePaths,
        config.excludePatterns,
        config.includePrivate,
    );
    
    auto output = parser.parse();
    
    if (verbose)
    {
        writeln("Parsed ", output.modules.length, " modules");
        writeln("Found ", output.searchIndex.length, " symbols");
    }
    
    if (verbose)
        writeln("Writing JSON output...");
    
    auto generator = OutputGenerator(config.outputPath, config.outputCompact);
    generator.generate(output);
    
    if (verbose)
        writeln("Done! Output written to: ", config.outputPath);
    
    return 0;
}

@safe pure nothrow
string getHelpText()
{
    return `
sparkle-docs - API documentation generator for D projects

Usage:
  sparkle-docs [options] <source-paths...>

Options:
  -o, --output <dir>     Output directory for JSON files (default: docs/.vitepress/data/api/)
  -c, --config <file>    Configuration file (sparkle-docs.json)
  -p, --package <name>   Package name for docs
  --exclude <pattern>    Exclude files matching pattern
  --include-private      Include private symbols
  --output-compact       Write compact JSON output (no pretty printing)
  --source-url <url>     Base URL for source links (e.g., GitHub)
  --runner-url <url>     URL for runnable examples service
  -v, --verbose          Verbose output
  -h, --help             Show help

Examples:
  sparkle-docs libs/core-cli/src -o docs/.vitepress/data/api/
  sparkle-docs --config sparkle-docs.json
  sparkle-docs -v libs/core-cli/src libs/test-utils/src
`;
}

/** Merge a file-based config with CLI overrides.
 *
 * CLI values take precedence when non-empty/non-default.
 *
 * Params:
 *     fileConfig = configuration loaded from a JSON file
 *     cliConfig = configuration populated from command-line flags
 *
 * Returns: merged configuration
 */
@safe pure nothrow
Config mergeConfig(Config fileConfig, Config cliConfig)
{
    Config result = fileConfig;

    if (cliConfig.name.length > 0)
        result.name = cliConfig.name;
    if (cliConfig.version_.length > 0)
        result.version_ = cliConfig.version_;
    if (cliConfig.outputPath.length > 0)
        result.outputPath = cliConfig.outputPath;
    if (cliConfig.sourceUrl.length > 0)
        result.sourceUrl = cliConfig.sourceUrl;
    if (cliConfig.runnerUrl.length > 0)
        result.runnerUrl = cliConfig.runnerUrl;
    if (cliConfig.excludePatterns.length > 0)
        result.excludePatterns = cliConfig.excludePatterns;
    if (cliConfig.includePrivate)
        result.includePrivate = true;
    if (cliConfig.outputCompact)
        result.outputCompact = true;

    return result;
}
