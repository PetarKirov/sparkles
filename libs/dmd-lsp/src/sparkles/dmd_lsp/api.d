/**
The public facade of `sparkles:dmd-lsp` — a DMD-frontend-as-a-library semantic
core, ported from VisualD's `dmdserver` (Boost-1.0). See
`docs/specs/dmd-lsp/` for the architecture and requirement inventory.

This module is the only one dependents should import. One `Analyzer` performs
$(B one) full semantic pass over one in-memory module and answers queries from
it; it is deliberately single-use (spec `COR2`) — batch isolation comes from
one-analysis-per-process, so there is no global-state reset machinery here.

The type-oracle queries (`tipAt`, `identifierSpans` — the `semvisitor` port,
spec `TIP*`) land in milestone L7.
*/
module sparkles.dmd_lsp.api;

public import sparkles.dmd_lsp.diag : Diagnostic, DiagKind, DiagPos;
public import sparkles.dmd_lsp.options : AnalyzerConfig;

import sparkles.dmd_lsp.diag : DiagnosticSink;

import dmd.dmodule : Module;

/**
One semantic analysis session (single-use; see the module docs).

DMD's frontend is one big global: while an `Analyzer` is alive it holds a
process-wide lock, and its destructor tears the globals down again
(`deinitializeDMD`), so $(I sequential) sessions in one process work — which
is what lets a multi-test suite run — while concurrent ones serialize. The
batch extractor still runs one analysis per process (`EXT2`): the
deinit/reinit cycle does not reset DMD's function-local `static` caches (the
gap `dmdserver`'s mangled-name table papered over), so cross-session bleed,
while unobserved in our suite, is not contractually excluded.
*/
struct Analyzer
{
    private AnalyzerConfig _config;
    private DiagnosticSink _sink;
    private bool _initialized;
    private bool _analyzed;

    @disable this(this);

    this(AnalyzerConfig config) @system
    {
        import sparkles.dmd_lsp.init_ : initAnalyzer;

        dmdLock.lock();
        _config = config;
        initAnalyzer(_sink, _config);
        _initialized = true;
    }

    ~this() @system
    {
        if (!_initialized)
            return;
        import dmd.frontend : deinitializeDMD;

        deinitializeDMD();
        _initialized = false;
        dmdLock.unlock();
    }

    /// Parses + fully analyzes `source` as `filename`, entirely in memory.
    /// The result's `module_` stays valid until this `Analyzer` is destroyed.
    AnalyzedModule analyze(string filename, string source) @system
    in (_initialized, "construct the Analyzer with a config first")
    in (!_analyzed, "Analyzer is single-use: one analyze() per session (COR2)")
    {
        import dmd.frontend : fullSemantic, parseModule;

        _analyzed = true;

        auto parsed = parseModule(filename, source);
        Module.rootModule = parsed.module_;
        if (!_sink.hasErrors)
            fullSemantic(parsed.module_);

        return AnalyzedModule(parsed.module_, _sink.diagnostics);
    }
}

private
{
    import core.sync.mutex : Mutex;

    __gshared Mutex dmdLock;

    shared static this() { dmdLock = new Mutex; }
}

/// The result of `Analyzer.analyze`: the analyzed module + its diagnostics.
struct AnalyzedModule
{
    /// The semantically-analyzed module (the type oracle's input, L7).
    Module module_;

    /// Everything the frontend reported, in emission order, with
    /// `errorSupplemental` chains attached as `notes` (spec `COR3`).
    Diagnostic[] diagnostics;

    bool hasErrors() const @safe pure nothrow @nogc
    {
        foreach (ref d; diagnostics)
            if (d.kind == DiagKind.error)
                return true;
        return false;
    }
}

@("dmd_lsp.api.languageServerEnabled")
@safe pure nothrow @nogc unittest
{
    // The version identifier must propagate up from the dependency's manifest
    // (BLD1): without it this package would compile the dmd.* headers with
    // different declarations than the prebuilt library exports.
    version (LanguageServer) {}
    else static assert(false,
        "dmd:frontend must be the LanguageServer flavor (dmdserver-dub branch)");
}

@("dmd_lsp.api.analyze.clean")
@system unittest
{
    import sparkles.dmd_lsp.testing : analyzerConfigForTest;

    auto analyzer = Analyzer(analyzerConfigForTest());
    auto result = analyzer.analyze("smoke.d", q{
        module smoke;
        int twice(int x) { return x * 2; }
    });
    assert(!result.hasErrors);
    assert(result.module_ !is null);
}
