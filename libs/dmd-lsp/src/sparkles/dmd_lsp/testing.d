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

/// An `AnalyzerConfig` for tests; skips the test when the environment cannot
/// support semantic analysis.
AnalyzerConfig analyzerConfigForTest(string[] dflags = null) @system
{
    import std.process : environment;

    enum reason = "SPARKLES_DMD_IMPORT_PATH not set (enter `nix develop`)";

    if (!environment.get("SPARKLES_DMD_IMPORT_PATH", "").length)
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
    return AnalyzerConfig(dflags: dflags);
}

/// Analyzes `source` and asserts its error messages: `expected` are
/// substrings, one per expected error, matched in order. An empty `expected`
/// asserts a clean analysis.
AnalyzedModule checkErrors(string source, string[] expected = null,
    string[] dflags = null,
    string file = __FILE__, size_t line = __LINE__) @system
{
    auto analyzer = Analyzer(analyzerConfigForTest(dflags));
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
    string file = __FILE__, size_t line = __LINE__) @system
{
    auto analyzer = Analyzer(analyzerConfigForTest(dflags));
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
