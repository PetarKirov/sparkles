/**
Test helpers for `sparkles:dmd-lsp` consumers and its own suite.

Semantic analysis needs frontend-matched druntime/phobos sources at runtime
(spec `COR6`/`BLD3`); `analyzerConfigForTest` gates on
`$SPARKLES_DMD_IMPORT_PATH` with a $(B skip) — never an early-`return` pass,
never a failure — following the `loadGrammarForTest` pattern from
`sparkles:tree-sitter`.

`checkErrors` and `checkTip` are ports of `dmdserver`'s
`semanalysis.do_unittests` helpers of the same name — `checkErrors` against
the structured `Diagnostic` model instead of a rendered wire string.
*/
module sparkles.dmd_lsp.testing;

import sparkles.dmd_lsp.api : AnalyzedModule, Analyzer, AnalyzerConfig, DiagKind;
import sparkles.dmd_lsp.options : TargetProfile, runtimeImportVariable;

/// An `AnalyzerConfig` for tests; skips the test when the environment cannot
/// support semantic analysis under `profile` — its runtime variable
/// (`$SPARKLES_DMD_IMPORT_PATH`, or `$SPARKLES_LDC_IMPORT_PATH` for LDC) is
/// unset.
AnalyzerConfig analyzerConfigForTest(string[] dflags = null,
    TargetProfile profile = TargetProfile.dmd) @system
{
    import std.process : environment;

    const variable = runtimeImportVariable(profile);
    const reason = variable ~ " not set (enter `nix develop`)";

    if (!environment.get(variable, "").length)
    {
        // The runner is a `configuration "unittest"` dependency, so it is
        // absent from the plain `library` build this module is also compiled
        // into. Without the guard that build fails outright on the import.
        version (Have_sparkles_test_runner)
        {
            import sparkles.test_runner.skip : skipTest;

            skipTest(reason);
        }
        else
            throw new Exception(reason);
    }
    return AnalyzerConfig(dflags: dflags, profile: profile);
}

/// Analyzes `source` and asserts its error messages: `expected` are
/// substrings, one per expected error, matched in order. An empty `expected`
/// asserts a clean analysis.
AnalyzedModule checkErrors(string source, string[] expected = null,
    string[] dflags = null, TargetProfile profile = TargetProfile.dmd,
    string file = __FILE__, size_t line = __LINE__) @system
{
    auto analyzer = Analyzer(analyzerConfigForTest(dflags, profile));
    auto result = analyzer.analyze("test.d", source);
    assertErrors(result, expected, file, line);
    return result;
}

/**
Analyzes `source` and runs `queries` against it $(B while the session is still
alive).

Use this, not `checkErrors`, for anything that walks the AST. `Analyzer`'s
destructor calls `deinitializeDMD`, which resets `dmd.location`'s global line
table among other things, so the `AnalyzedModule` `checkErrors` returns is
only good for its `diagnostics` afterwards — and because the destructor also
releases the process-wide lock, a concurrently running test can reinitialize
those globals underneath a late AST walk. (Symptom: the suite wedges, spinning
inside `Loc.filename`'s file-table search.)
*/
void withAnalysis(string source, scope void delegate(AnalyzedModule) @system queries,
    string[] expected = null, string[] dflags = null,
    TargetProfile profile = TargetProfile.dmd,
    string file = __FILE__, size_t line = __LINE__) @system
{
    auto analyzer = Analyzer(analyzerConfigForTest(dflags, profile));
    auto result = analyzer.analyze("test.d", source);
    assertErrors(result, expected, file, line);
    queries(result);
}

private void assertErrors(in AnalyzedModule result, in string[] expected,
    string file, size_t line) @system
{
    import core.exception : AssertError;
    import std.algorithm.searching : canFind;
    import std.conv : text;

    const(string)[] errors;
    foreach (ref d; result.diagnostics)
        if (d.kind == DiagKind.error)
            errors ~= text(d.pos.line, ",", d.pos.column, ": ", d.message);

    if (errors.length != expected.length)
        throw new AssertError(text("expected ", expected.length, " error(s), got ",
            errors.length, ":\n", errors), file, line);
    foreach (i, want; expected)
        if (!errors[i].canFind(want))
            throw new AssertError(text("error ", i, " mismatch:\n  expected: …",
                want, "…\n  actual:   ", errors[i]), file, line);
}

/**
Asserts the tooltip the type oracle renders at `line`:`col` (both 1-based).

Upstream's convention is preserved: an `expected` ending in `...` is a prefix
match, for tips whose tail is a Phobos/druntime doc comment that would make
the assertion brittle. Everything else must match exactly, `""` included —
that is the assertion that a position resolves to nothing.
*/
void checkTip(AnalyzedModule m, uint line, uint col, string expected,
    string file = __FILE__, size_t assertLine = __LINE__) @system
{
    import core.exception : AssertError;
    import std.algorithm.comparison : min;
    import std.algorithm.searching : endsWith;
    import std.conv : text;

    import sparkles.dmd_lsp.visitor : findTip;

    const tip = findTip(m.module_, line, col, line, col + 1,
        addlinks: false, addsize: false);

    if (expected.endsWith("..."))
    {
        const want = expected[0 .. $ - 3];
        const got = tip[0 .. min($, want.length)];
        if (got != want)
            throw new AssertError(text("tip at ", line, ":", col,
                " prefix mismatch:\n  expected: ", want, "…\n  actual:   ", tip),
                file, assertLine);
    }
    else if (tip != expected)
        throw new AssertError(text("tip at ", line, ":", col,
            " mismatch:\n  expected: ", expected, "\n  actual:   ", tip),
            file, assertLine);
}

// The first slice of the dmdserver `do_unittests` corpus (77 checkErrors
// cases upstream); grown alongside the L7 visitor port.

@("dmd_lsp.testing.checkErrors.clean")
@system unittest
{
    checkErrors(q{
        module test;
        struct S { int x; }
        int use(S s) { return s.x; }
    });
}

@("dmd_lsp.testing.checkErrors.conversion")
@system unittest
{
    checkErrors(q{
        module test;
        void broken() { int x = "not an int"; }
    }, ["cannot implicitly convert expression"]);
}

@("dmd_lsp.testing.checkErrors.undefinedIdentifier")
@system unittest
{
    checkErrors(q{
        module test;
        void f() { return unknownSymbol; }
    }, ["undefined identifier `unknownSymbol`"]);
}

@("dmd_lsp.testing.checkErrors.multipleInOrder")
@system unittest
{
    checkErrors(q{
        module test;
        void f()
        {
            int a = "one";
            int b = "two";
        }
    }, ["cannot implicitly convert", "cannot implicitly convert"]);
}

@("dmd_lsp.testing.checkErrors.phobosImport")
@system unittest
{
    // Exercises real import resolution through the configured paths: object,
    // std.algorithm, and template instantiation through Phobos.
    checkErrors(q{
        module test;
        import std.algorithm.iteration : map;
        auto squares(int[] xs) { return xs.map!(x => x * x); }
    });
}

@("dmd_lsp.testing.checkErrors.unittestDflagPredefinesTheVersion")
@system unittest
{
    // `-unittest` is two things in the driver: analyze `unittest` bodies and
    // predefine the `unittest` version. Doing only the first analyzes bodies
    // whose `version (unittest)` imports never arrived, so every test-only
    // import reads as an undefined identifier.
    checkErrors(q{
        module test;
        version (unittest) import std.range : iota;
        unittest { auto r = iota(3); }
    }, null, dflags: ["-unittest"]);
}

@("dmd_lsp.testing.checkErrors.dflagsReachAnalysis")
@system unittest
{
    // The same source is clean normally and an error under -betterC — the
    // `@dflags:` subset must actually reach the analysis (COR5).
    enum src = q{
        module test;
        void f() { throw new Exception("boom"); }
    };
    checkErrors(src, null);
    checkErrors(src, ["cannot use `throw` statements with `-betterC`"],
        dflags: ["-betterC"]);
}

@("dmd_lsp.testing.importCResolvesIncludedHeaders")
@system unittest
{
    import std.algorithm.searching : canFind;
    import std.conv : text;
    import std.exception : collectException;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : thisProcessID;

    import sparkles.dmd_lsp.api : Analyzer, AnalyzerConfig, DiagKind;

    const root = tempDir.buildPath("sparkles-dmd-lsp-importc-" ~ thisProcessID.text);
    const include = root.buildPath("include");
    mkdirRecurse(include);
    scope (exit)
        collectException(rmdirRecurse(root));

    // The whole point in one file pair: nothing the sample needs is visible
    // without running the preprocessor, and the header is reachable only
    // through a `-P-I` switch — the spelling a dub `libs` entry arrives as
    // (`PRJ18`).
    write(include.buildPath("probe_header.h"),
        "typedef int probe_answer_t;\n#define PROBE_ANSWER 42\n");
    write(root.buildPath("cprobe.c"),
        "#include <probe_header.h>\nprobe_answer_t probe_value(void);\n");

    auto config = analyzerConfigForTest(["-P-I" ~ include]); // skips if unusable
    config.importPaths = root ~ AnalyzerConfig().effectiveImportPaths;

    auto analyzer = Analyzer(config);
    auto result = analyzer.analyze("test.d", "import cprobe;\n"
        ~ "static assert(PROBE_ANSWER == 42);\n"
        ~ "probe_answer_t answer;\n");

    string[] errors;
    foreach (ref d; result.diagnostics)
        if (d.kind == DiagKind.error)
            errors ~= d.message;
    assert(!errors.canFind!(e => e.canFind("#include")),
        text("the C preprocessor did not run: ", errors));
    assert(errors.length == 0, errors.text);
}

@("dmd_lsp.testing.checkErrors.editionReachesAnalysis")
@system unittest
{
    // The 2024 edition's discarded struct-rvalue assignment: silent by
    // default, an error under `-edition=2024`. The edition is not a
    // `-preview=` switch — it is set on `global.params` and copied onto each
    // `Module` — so this pins that path (COR5).
    enum src = q{
        module test;
        struct S { int i; void opAssign(S s) {} }
        S foo() { return S(0); }
        void main() { foo() = S(2); }
    };
    checkErrors(src, null);
    checkErrors(src, ["assignment to struct rvalue `foo()` is discarded"],
        dflags: ["-edition=2024"]);
}

@("dmd_lsp.testing.betterCPredefinesItsVersion")
@system unittest
{
    // `-betterC` reaches the params before the predefined set is derived
    // from them, as on the real compiler.
    checkErrors(q{
        version (D_BetterC) {} else static assert(0, "no D_BetterC");
        version (D_ModuleInfo) static assert(0, "D_ModuleInfo under -betterC");
    }, null, ["-betterC"]);
}

@("dmd_lsp.testing.profile.dmdRejectsNarrowVectors")
@system unittest
{
    // The regression direction of `TGT2`: DMD's own x86 rules still apply.
    checkErrors(q{
        __vector(float[2]) v;
    }, ["not supported"]);
}

@("dmd_lsp.testing.profile.ldcPredefinesAndVectors")
@system unittest
{
    checkErrors(q{
        version (LDC) {} else static assert(0, "no LDC");
        version (DigitalMars) static assert(0, "DigitalMars under LDC");
        version (LDC_DCompute) static assert(0, "LDC_DCompute on the host");

        alias vec2 = __vector(float[2]);
        alias vec3 = __vector(float[3]);
        vec2 f(vec2 a, vec2 b) => a * b + a / b - a;
        vec3 g(vec3 a) => -a * a;
    }, null, null, TargetProfile.ldc);
}

@("dmd_lsp.testing.profile.ldcDeviceResolvesDcompute")
@system unittest
{
    // The device profile predefines `LDC_DCompute` and reads `ldc.dcompute`
    // from the LDC runtime — including the vector-gated `sample`.
    checkErrors(q{
        @compute(CompileFor.deviceOnly) module test;
        import ldc.dcompute;

        version (LDC_DCompute) {} else static assert(0, "no LDC_DCompute");

        alias vec2 = __vector(float[2]);
        alias vec4 = __vector(float[4]);

        @fragment vec4 shade(@input vec2 uv, Sampler2D tex) => tex.sample(uv);
    }, null, null, TargetProfile.ldcDevice);
}

@("dmd_lsp.testing.profile.dcomputeTargetsSelectDevice")
@system unittest
{
    // A flag list copied from a real device build selects the profile.
    checkErrors(q{
        version (LDC_DCompute) {} else static assert(0, "no LDC_DCompute");
    }, null, ["-mdcompute-targets=vulkan-130"], TargetProfile.ldc);
}
