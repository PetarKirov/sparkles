/**
Test helpers for `sparkles:dmd-lsp` consumers and its own suite.

Semantic analysis needs frontend-matched druntime/phobos sources at runtime
(spec `COR6`/`BLD3`); `analyzerConfigForTest` gates on
`$SPARKLES_DMD_IMPORT_PATH` with a $(B skip) — never an early-`return` pass,
never a failure — following the `loadGrammarForTest` pattern from
`sparkles:tree-sitter`.

`checkErrors` is the port of `dmdserver`'s `semanalysis.do_unittests` helper
of the same name, against the structured `Diagnostic` model instead of a
rendered wire string.
*/
module sparkles.dmd_lsp.testing;

import sparkles.dmd_lsp.api : AnalyzedModule, Analyzer, AnalyzerConfig, DiagKind;

/// An `AnalyzerConfig` for tests; skips the test when the environment cannot
/// support semantic analysis.
AnalyzerConfig analyzerConfigForTest(string[] dflags = null) @system
{
    import std.process : environment;

    import sparkles.test_runner.skip : skipTest;

    if (!environment.get("SPARKLES_DMD_IMPORT_PATH", "").length)
        skipTest("SPARKLES_DMD_IMPORT_PATH not set (enter `nix develop`)");
    return AnalyzerConfig(dflags: dflags);
}

/// Analyzes `source` and asserts its error messages: `expected` are
/// substrings, one per expected error, matched in order. An empty `expected`
/// asserts a clean analysis.
AnalyzedModule checkErrors(string source, string[] expected = null,
    string[] dflags = null,
    string file = __FILE__, size_t line = __LINE__) @system
{
    import core.exception : AssertError;
    import std.algorithm.searching : canFind;
    import std.conv : text;

    auto analyzer = Analyzer(analyzerConfigForTest(dflags));
    auto result = analyzer.analyze("test.d", source);

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
    return result;
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
