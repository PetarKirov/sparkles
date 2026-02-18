/// Module-level documentation model.
module sparkle_docs.model.module_;

import sparkle_docs.model.symbol : Symbol;

@safe:

/// Documentation extracted from a single D module.
struct ModuleDoc
{
    /// Dot-separated module name (e.g. `sparkles.core_cli.json`).
    string qualifiedName;
    /// Filesystem path used to discover this module.
    string fileName;
    /// First paragraph of the module-level DDoc comment.
    string summary;
    /// Full module-level DDoc comment.
    string description;
    /// Top-level symbols declared in this module.
    Symbol[] symbols;
    string[] imports;
    string[] publicImports;
    string[] attributes;
    /// Canonical source file path reported by DMD.
    string sourceFile;
    size_t line;
}
