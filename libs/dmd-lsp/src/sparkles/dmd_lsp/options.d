/**
Analysis configuration for `sparkles:dmd-lsp` — the trimmed, non-COM
counterpart of `dmdserver`'s `Options` (`vdc/dmdserver/dmdinit.d`, Boost-1.0).

Only the knobs the batch semantic core consumes survive the port: source
import paths, string-import paths, version/debug identifiers, and a small
`-dflags`-style flag list (see `sparkles.dmd_lsp.init_.applyDflags` for the
supported subset). Everything project-shaped (x64/msvcrt targets, unittest
toggles, the LDC/GDC predefine emulation) is out of scope for v1.
*/
module sparkles.dmd_lsp.options;

/// Configuration for one `Analyzer` (spec `COR5`/`COR6`).
struct AnalyzerConfig
{
    /// Source import dirs (druntime/phobos + sample-declared `@import:`).
    /// Empty means "default from `$SPARKLES_DMD_IMPORT_PATH`".
    string[] importPaths;

    /// String-import dirs (`import("...")`).
    string[] stringImportPaths;

    /// `-version=<ident>` identifiers.
    string[] versionIds;

    /// `-debug=<ident>` identifiers.
    string[] debugIds;

    /// Compiler flags (the `// @dflags:` subset — `-preview=*`, `-betterC`, …).
    string[] dflags;

    /// Resolves the effective import paths: explicit ones win, otherwise the
    /// colon-separated `$SPARKLES_DMD_IMPORT_PATH` (unset ⇒ empty — callers
    /// gate on this for environment-dependent behavior, spec `COR6`).
    string[] effectiveImportPaths() const @safe
    {
        import std.algorithm.iteration : splitter;
        import std.array : array;
        import std.process : environment;

        if (importPaths.length)
            return importPaths.dup;
        const env = environment.get("SPARKLES_DMD_IMPORT_PATH", "");
        return env.length ? env.splitter(':').array : null;
    }
}

@("dmd_lsp.options.effectiveImportPaths")
@system unittest
{
    import std.process : environment;

    assert(AnalyzerConfig(importPaths: ["/a", "/b"]).effectiveImportPaths
        == ["/a", "/b"]);

    const saved = environment.get("SPARKLES_DMD_IMPORT_PATH");
    scope (exit) environment["SPARKLES_DMD_IMPORT_PATH"] = saved is null ? "" : saved;

    environment["SPARKLES_DMD_IMPORT_PATH"] = "/x:/y";
    assert(AnalyzerConfig().effectiveImportPaths == ["/x", "/y"]);
    environment["SPARKLES_DMD_IMPORT_PATH"] = "";
    assert(AnalyzerConfig().effectiveImportPaths.length == 0);
}
