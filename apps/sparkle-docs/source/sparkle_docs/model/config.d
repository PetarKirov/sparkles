/// Configuration and top-level output types for the documentation generator.
module sparkle_docs.model.config;

import sparkle_docs.model.module_ : ModuleDoc;
import sparkle_docs.model.symbol : SearchIndexEntry, TypeGraph;

@safe:

/// CLI and config-file options controlling documentation generation.
struct Config
{
    /// Package name shown in generated docs.
    string name;
    string version_;
    /// Root paths to scan for `.d` source files.
    string[] sourcePaths;
    /// Directory where JSON output files are written.
    string outputPath;
    /// Base URL template for source-file hyperlinks.
    string sourceUrl;
    /// URL for a "Run" button linking to an online compiler.
    string runnerUrl;
    /// When true, emit minified JSON without indentation.
    bool outputCompact;
    /// Glob patterns for files to skip during parsing.
    string[] excludePatterns;
    /// When true, include private symbols in the output.
    bool includePrivate;
    string[] ddocMacros;
    string[] customCss;
}

/// Aggregate output of a documentation generation run.
struct Output
{
    string version_;
    /// ISO 8601 timestamp of when the docs were generated.
    string generated;
    /// Parsed modules keyed by qualified name.
    ModuleDoc[string] modules;
    /// Flat list of every symbol for search functionality.
    SearchIndexEntry[] searchIndex;
    /// Type inheritance / composition graph.
    TypeGraph typeGraph;
}
