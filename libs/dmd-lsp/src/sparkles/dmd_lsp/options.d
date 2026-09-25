/**
Analysis configuration for `sparkles:dmd-lsp` — the trimmed, non-COM
counterpart of `dmdserver`'s `Options` (`vdc/dmdserver/dmdinit.d`, Boost-1.0).

Only the knobs the batch semantic core consumes survive the port: source
import paths, string-import paths, version/debug identifiers, and a small
`-dflags`-style flag list (see `sparkles.dmd_lsp.init_.applyDflags` for the
supported subset), plus the `TargetProfile` that says which compiler, and
which side of a dcompute build, the analysis stands in for. Everything else
project-shaped (x64/msvcrt targets, GDC emulation) is out of scope.
*/
module sparkles.dmd_lsp.options;

/**
The compiler an analysis emulates (spec `TGT1`).

The frontend is DMD's either way; a profile changes what it is told about
the target: the vendor version identifier it predefines, whether it accepts
the vector shapes an LLVM backend lowers, and which runtime sources it reads
`object` and `ldc.*` from.
*/
enum TargetProfile
{
    /// DMD: `DigitalMars`, x86 SIMD vector rules, `$SPARKLES_DMD_IMPORT_PATH`.
    dmd,
    /// LDC, host code: `LDC`, any-size `__vector`s, `$SPARKLES_LDC_IMPORT_PATH`.
    ldc,
    /// LDC compiling dcompute device code: `ldc` plus `LDC_DCompute` — what
    /// `-mdcompute-targets=` selects on the real compiler.
    ldcDevice,
}

/// The environment variable holding a profile's runtime (druntime + phobos)
/// import paths, colon-separated.
string runtimeImportVariable(TargetProfile profile) @safe pure nothrow @nogc
    => profile == TargetProfile.dmd ? "SPARKLES_DMD_IMPORT_PATH" : "SPARKLES_LDC_IMPORT_PATH";

/// A profile's runtime import paths, from its environment variable (unset ⇒
/// empty; callers gate on that, spec `COR6`).
string[] runtimeImportPaths(TargetProfile profile) @safe
{
    import std.process : environment;

    return splitImportPaths(environment.get(runtimeImportVariable(profile), ""));
}

private string[] splitImportPaths(scope const(char)[] envValue) @safe pure
{
    import std.algorithm.iteration : splitter;
    import std.array : array;

    return envValue.length ? envValue.idup.splitter(':').array : null;
}

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

    /// The compiler the analysis emulates. A `-mdcompute-targets=` dflag
    /// raises it to `ldcDevice` (see `effectiveProfile`).
    TargetProfile profile;

    /// `profile`, or `ldcDevice` when `dflags` name dcompute targets — so a
    /// flag list copied from a real device build selects the device profile
    /// on its own.
    TargetProfile effectiveProfile() const @safe pure nothrow @nogc
    {
        import std.algorithm.searching : any, startsWith;

        return dflags.any!(f => f.startsWith("-mdcompute-targets="))
            ? TargetProfile.ldcDevice : profile;
    }

    /// Resolves the effective import paths: explicit ones win, otherwise the
    /// profile's runtime variable (`$SPARKLES_DMD_IMPORT_PATH` for DMD,
    /// `$SPARKLES_LDC_IMPORT_PATH` for LDC; unset ⇒ empty — callers gate on
    /// this for environment-dependent behavior, spec `COR6`).
    string[] effectiveImportPaths() const @safe
    {
        import std.process : environment;

        return resolveImportPaths(
            environment.get(runtimeImportVariable(effectiveProfile), ""));
    }

    /// The pure resolution rule behind `effectiveImportPaths` (separated so
    /// tests never mutate the process environment — the parallel test runner
    /// makes that a race against every env-gated analyzer test).
    string[] resolveImportPaths(scope const(char)[] envValue) const @safe pure
        => importPaths.length ? importPaths.dup : splitImportPaths(envValue);
}

@("dmd_lsp.options.effectiveProfile")
@safe pure nothrow unittest
{
    assert(AnalyzerConfig().effectiveProfile == TargetProfile.dmd);
    assert(AnalyzerConfig(profile: TargetProfile.ldc).effectiveProfile == TargetProfile.ldc);
    assert(AnalyzerConfig(dflags: ["-O2", "-mdcompute-targets=vulkan-130"]).effectiveProfile
        == TargetProfile.ldcDevice);
    assert(runtimeImportVariable(TargetProfile.dmd) == "SPARKLES_DMD_IMPORT_PATH");
    assert(runtimeImportVariable(TargetProfile.ldcDevice) == "SPARKLES_LDC_IMPORT_PATH");
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
string runtimeSourcesProblem(scope const string[] importPaths,
    TargetProfile profile = TargetProfile.dmd) @safe
{
    import std.algorithm.searching : any;
    import std.array : join;
    import std.conv : text;
    import std.file : exists;
    import std.path : buildPath;

    const hint = profile == TargetProfile.dmd
        ? "$SPARKLES_DMD_IMPORT_PATH must point at the druntime/phobos " ~
            "sources matching the pinned frontend (`nix develop` exports it)"
        : "$SPARKLES_LDC_IMPORT_PATH must point at the dcompute LDC's " ~
            "druntime/phobos sources (`nix develop` exports it on Linux)";

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
    import sparkles.test_utils.tmpfs : TmpFS;
    import std.algorithm.searching : canFind;
    import std.uuid : randomUUID;

    assert(runtimeSourcesProblem(null).canFind("SPARKLES_DMD_IMPORT_PATH"));

    // A UUID rather than the default per-function prefix: the first assertion
    // needs the directory *empty*, so a concurrent run of this same test in
    // another process must not be sharing it.
    auto tmp = TmpFS.create("sparkles-dmd-lsp");

    assert(runtimeSourcesProblem([tmp.dir]).canFind("object.d"));

    tmp.writeFileAt("object.d", "module object;");
    assert(runtimeSourcesProblem([tmp.dir]) is null);
}
