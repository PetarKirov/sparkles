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
        import std.process : environment;

        return resolveImportPaths(environment.get("SPARKLES_DMD_IMPORT_PATH", ""));
    }

    /// The pure resolution rule behind `effectiveImportPaths` (separated so
    /// tests never mutate the process environment — the parallel test runner
    /// makes that a race against every env-gated analyzer test).
    string[] resolveImportPaths(scope const(char)[] envValue) const @safe pure
    {
        import std.algorithm.iteration : splitter;
        import std.array : array;

        if (importPaths.length)
            return importPaths.dup;
        return envValue.length ? envValue.idup.splitter(':').array : null;
    }
}

@("dmd_lsp.options.resolveImportPaths")
@safe pure unittest
{
    assert(AnalyzerConfig(importPaths: ["/a", "/b"]).resolveImportPaths("/x:/y")
        == ["/a", "/b"]);
    assert(AnalyzerConfig().resolveImportPaths("/x:/y") == ["/x", "/y"]);
    assert(AnalyzerConfig().resolveImportPaths("").length == 0);
}
