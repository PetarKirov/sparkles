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

/**
Why `importPaths` cannot support a semantic analysis, or `null` when they can
(spec `COR6`/`BLD3`).

Every analysis resolves `import object;` first, and when the frontend cannot
find it, it reports through the diagnostic handler and then calls `fatal()` —
which, with a collecting sink installed, is an `exit(1)` with nothing printed
anywhere. Checking the paths up front turns that mute death into a message
that names the actual problem (typically: the environment was never set up).
*/
string runtimeSourcesProblem(scope const string[] importPaths) @safe
{
    import std.algorithm.searching : any;
    import std.array : join;
    import std.conv : text;
    import std.file : exists;
    import std.path : buildPath;

    enum hint = "$SPARKLES_DMD_IMPORT_PATH must point at the druntime/phobos " ~
        "sources matching the pinned frontend (`nix develop` exports it)";

    if (!importPaths.length)
        return "no analysis import paths: " ~ hint;

    if (!importPaths.any!(p => buildPath(p, "object.d").exists))
    {
        // Only the head of the list: under `--dub` these are the whole
        // project's import paths, and a 20-entry dump buries the message.
        if (importPaths.length > 3)
            return text("no druntime `object.d` under the ", importPaths.length,
                " analysis import paths (", importPaths[0 .. 3].join(", "),
                ", …): ", hint);
        return "no druntime `object.d` under the analysis import paths (" ~
            importPaths.join(", ") ~ "): " ~ hint;
    }

    return null;
}

@("dmd_lsp.options.runtimeSourcesProblem")
@system unittest
{
    import std.algorithm.searching : canFind;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    assert(runtimeSourcesProblem(null).canFind("SPARKLES_DMD_IMPORT_PATH"));

    const dir = buildPath(tempDir, "sparkles-dmd-lsp-" ~ randomUUID.toString);
    mkdirRecurse(dir);
    scope (exit)
        rmdirRecurse(dir);

    assert(runtimeSourcesProblem([dir]).canFind("object.d"));

    write(buildPath(dir, "object.d"), "module object;");
    assert(runtimeSourcesProblem([dir]) is null);
}
