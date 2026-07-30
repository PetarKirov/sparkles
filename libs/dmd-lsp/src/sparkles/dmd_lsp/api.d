/**
The public facade of `sparkles:dmd-lsp` — a DMD-frontend-as-a-library semantic
core, ported from VisualD's `dmdserver` (Boost-1.0). See
`docs/specs/dmd-lsp/` for the architecture and requirement inventory.

This module is the only one dependents should import. One `Analyzer` performs
$(B one) full semantic pass over one in-memory module and answers queries from
it; it is deliberately single-use (spec `COR2`) — batch isolation comes from
one-analysis-per-process, so there is no global-state reset machinery here.

The type-oracle queries (`tipAt`, `identifierSpans`, `definitionAt` — spec
`TIP*`/`DOC1`) are thin, position-typed wrappers over
$(MREF sparkles,dmd_lsp,visitor), the `semvisitor` port; reach for that module
directly for the queries this facade does not surface (completion expansions,
references, the module outline).
*/
module sparkles.dmd_lsp.api;

public import sparkles.dmd_lsp.diag : Diagnostic, DiagKind, DiagPos;
public import sparkles.dmd_lsp.options : AnalyzerConfig;
public import sparkles.dmd_lsp.support : TypeReferenceKind;

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
        import sparkles.dmd_lsp.init_ : dmdGlobalsLock, initAnalyzer;

        dmdGlobalsLock.lock();
        _config = config;
        initAnalyzer(_sink, _config);
        _initialized = true;
    }

    ~this() @system
    {
        if (!_initialized)
            return;
        import dmd.frontend : deinitializeDMD;
        import sparkles.dmd_lsp.init_ : dmdGlobalsLock;

        deinitializeDMD();
        _initialized = false;
        dmdGlobalsLock.unlock();
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

    /**
    The type oracle's answer for the position `line`:`col` (both 1-based).

    Returns `Tip.init` — `found` is `false` — when nothing resolves there,
    which is the common case for punctuation and whitespace.
    */
    Tip tipAt(uint line, uint col) @system
    {
        import std.string : strip;

        import sparkles.dmd_lsp.visitor : findTipData;

        auto data = findTipData(module_, line, col, line, col + 1, addsize: false);
        return Tip(kind: data.kind, code: data.code, doc: data.doc.strip);
    }

    /**
    How each identifier in the module is classified, as position-ordered
    $(I transitions).

    This is `findIdentifierTypes`' model, and it is run-length, not
    per-occurrence: an entry says "from here on, this spelling means `kind`",
    and the visitor only records a new one where the meaning changes. A name
    used consistently — a type, a local — therefore yields exactly one entry,
    at its first position; a name that is a method here and a free function
    there yields one per switch. Consumers colour by walking the list and
    carrying the last `kind` for a spelling forward.

    Entries carry only a start: an occurrence's extent is
    `[col, col + ident.length)`, which is all the underlying model records.
    */
    IdentSpan[] identifierSpans() @system
    {
        import std.algorithm.sorting : sort;

        import sparkles.dmd_lsp.visitor : findIdentifierTypes;

        IdentSpan[] spans;
        foreach (ident, positions; findIdentifierTypes(module_))
            foreach (p; positions)
                spans ~= IdentSpan(
                    ident: ident.idup,
                    line: cast(uint) p.line,
                    col: cast(uint) p.col,
                    kind: cast(TypeReferenceKind) p.type);

        // The visitor keys by identifier name, so iteration order is the AA's.
        // Source order is what every consumer wants and is a stable contract.
        spans.sort!((a, b) => a.line != b.line ? a.line < b.line
            : a.col != b.col ? a.col < b.col
            : a.ident < b.ident);
        return spans;
    }

    /// Where the symbol at `line`:`col` (both 1-based) is declared, or
    /// `DefinitionPos.init` — `found` is `false` — if nothing resolves there.
    DefinitionPos definitionAt(uint line, uint col) @system
    {
        import sparkles.dmd_lsp.visitor : findDefinition;

        int l = cast(int) line, c = cast(int) col;
        auto filename = findDefinition(module_, l, c);
        return filename.length
            ? DefinitionPos(filename: filename, line: cast(uint) l, col: cast(uint) c)
            : DefinitionPos.init;
    }
}

/**
A resolved tooltip: `dmdserver`'s `TipData` minus the size/alignment field,
which only the Visual D "show size" toggle populated.

`kind` is the category word `dmdserver` parenthesizes — `"parameter"`,
`"local variable"`, `"struct"`, `"enum value"`, … — and is empty for
functions, which render as a bare signature.
*/
struct Tip
{
    /// The category word, or empty (functions, and anything unclassified).
    string kind;

    /// The rendered declaration, e.g. `int test.S.fun(int par)`.
    string code;

    /// The declaration's DDoc comment, stripped (spec `DOC1`); empty when the
    /// declaration carries none.
    string doc;

    /// Whether the query resolved to anything.
    bool found() const @safe pure nothrow @nogc => kind.length != 0 || code.length != 0;
}

/// One identifier-classification transition. See the run-length semantics on
/// `AnalyzedModule.identifierSpans`.
struct IdentSpan
{
    /// The identifier's spelling; also its length in the source.
    string ident;

    /// 1-based line where this classification starts applying.
    uint line;

    /// 1-based column of the identifier's first character.
    uint col;

    /// What the identifier means from here on.
    TypeReferenceKind kind;
}

/// A declaration site. See `AnalyzedModule.definitionAt`.
struct DefinitionPos
{
    /// The declaring file, as the frontend spells it; empty when not found.
    string filename;

    /// 1-based line.
    uint line;

    /// 1-based column.
    uint col;

    /// Whether the query resolved to anything.
    bool found() const @safe pure nothrow @nogc => filename.length != 0;
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
