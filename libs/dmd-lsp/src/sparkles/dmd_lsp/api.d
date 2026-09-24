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
public import sparkles.dmd_lsp.signature : Abbrev, AbbrevKind, BreakGroup,
    BreakPoint, Contract, ContractKind, EffectSpan, Effects, SigTrust,
    SignatureInfo;
public import sparkles.dmd_lsp.support : TypeReferenceKind;

import sparkles.dmd_lsp.diag : DiagnosticSink;
import sparkles.dmd_lsp.visitor : TipOccurrence;

import dmd.dmodule : Module;
import dmd.dsymbol : Dsymbol;

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

    /**
    Throws: `Exception` when the configured import paths cannot support an
    analysis (no druntime `object.d`). Checked here, before the lock: the
    frontend's own reaction is `fatal()` — a silent `exit(1)` under a
    collecting sink, which would also never release the lock.
    */
    this(AnalyzerConfig config) @system
    {
        import sparkles.dmd_lsp.init_ : dmdGlobalsLock, initAnalyzer;
        import sparkles.dmd_lsp.options : runtimeSourcesProblem;

        if (const problem = runtimeSourcesProblem(config.effectiveImportPaths))
            throw new Exception(problem);

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

        Module.loadModuleHandler = null;
        deinitializeDMD();
        _initialized = false;
        dmdGlobalsLock.unlock();
    }

    /// Parses + fully analyzes `source` as `filename`, entirely in memory.
    /// The result's `module_` stays valid until this `Analyzer` is destroyed.
    /// `virtualModules` are additional in-memory files the entry module's
    /// imports resolve against (before falling back to the import paths) —
    /// the `@filename:` multi-file seam.
    AnalyzedModule analyze(string filename, string source,
        VirtualModule[] virtualModules = null) @system
    in (_initialized, "construct the Analyzer with a config first")
    in (!_analyzed, "Analyzer is single-use: one analyze() per session (COR2)")
    {
        import dmd.frontend : fullSemantic, parseModule;

        _analyzed = true;

        // Always installed, virtual modules or not: the handler's fallback
        // loads imports with `doDocComment = 1`, where DMD's own default is 0
        // (`Module.load`). That flag is what makes the lexer attach doc
        // comments to declarations, so without it *nothing* outside the root
        // module has a `.comment` — hovering `import std.stdio;`, a selective
        // import, or a Phobos call site showed a type and no documentation
        // (spec `DOC4`).
        auto provided = virtualModules.dup;
        Module.loadModuleHandler = (const ref loc, packages, ident)
        {
            if (packages.length == 0)
                foreach (vm; provided)
                    if (moduleBaseName(vm.filename) == ident.toString)
                        return parseModule(vm.filename, vm.source).module_;
            return Module.loadFromFile(loc, packages, ident, 1, 0);
        };

        auto parsed = parseModule(filename, source);
        // parseModule stops short of Module.resolvePackage, leaving the
        // module named after its file and outside the global symbol table —
        // a sample's own `module pkg.name;` declaration would have no effect
        // and every tip would carry the filename-derived name.
        auto mod = parsed.module_.resolvePackage();
        Module.rootModule = mod;
        if (!_sink.hasErrors)
            fullSemantic(mod);

        return AnalyzedModule(mod, _sink.diagnostics);
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

    // The batch walk's raw result, kept for `tipSites`/`resolveTipSite`.
    private TipOccurrence[] _occurrences;
    private bool _walked;

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
        import sparkles.dmd_lsp.ddoc : renderDdocText;
        import sparkles.dmd_lsp.visitor : findTipData;

        auto data = findTipData(module_, line, col, line, col + 1, addsize: false);
        return composeTip(data,
            (string comment, Dsymbol sym) => renderDdocText(comment, sym));
    }

    /**
    Every identifier occurrence in the module with its tip, from one AST walk.

    The batch counterpart of `tipAt`, for the "hover every identifier" pass:
    `tipAt` costs a full-module walk $(I per query), so a large module spends
    minutes answering itself. This shares one walk, one tip rendering per
    distinct symbol, and one DDoc rendering per distinct documented symbol.

    Coverage is a subset of what a `tipAt` sweep would find — see
    $(REF collectTips, sparkles,dmd_lsp,visitor) — so a caller that needs
    every position should fall back to `tipAt` for the ones missing here.
    Positions that resolve to nothing are omitted.
    */
    TipHit[] allTips() @system
    {
        import sparkles.dmd_lsp.ddoc : DdocRendered, renderDdocText;
        import sparkles.dmd_lsp.visitor : collectTips;

        // DDoc rendering is the other per-occurrence cost: one documented
        // symbol used a hundred times rendered its comment a hundred times.
        static struct DocKey
        {
            const(void)* symbol;
            const(char)* comment;
            size_t length;
        }

        DdocRendered[DocKey] rendered;
        auto render = (string comment, Dsymbol sym)
        {
            const key = DocKey(cast(const(void)*) sym, comment.ptr, comment.length);
            if (auto memoized = key in rendered)
                return *memoized;
            auto doc = renderDdocText(comment, sym);
            rendered[key] = doc;
            return doc;
        };

        TipHit[] hits;
        foreach (ref occurrence; collectTips(module_))
        {
            auto tip = composeTip(occurrence.tip, render);
            if (tip.found)
                hits ~= TipHit(cast(uint) occurrence.line, cast(uint) occurrence.col, tip);
        }
        return hits;
    }

    /**
    Where the batch walk has something to say, with the content left
    unresolved — `allTips` split in half so a caller can decide $(I whether) a
    position has a tooltip long before paying to render one (spec `EXT7`).

    The lazy `--serve` payload is built from this: a hover span it emits is a
    span `resolveTipSite` can answer, so the viewer never underlines a token
    whose popup would turn out empty. Resolving through the same walk also
    keeps the two in agreement, which a position query cannot promise — see
    the residual disagreements on $(REF collectTips, sparkles,dmd_lsp,visitor).

    The walk runs once and is cached for `resolveTipSite`.
    */
    TipSite[] tipSites() @system
    {
        ensureOccurrences();

        TipSite[] sites;
        foreach (i, ref occurrence; _occurrences)
            if (occurrence.tip.kind.length || occurrence.tip.code.length)
                sites ~= TipSite(cast(uint) occurrence.line, cast(uint) occurrence.col, i);
        return sites;
    }

    /**
    Resolves one `tipSites` entry, rendering its DDoc — the half `tipSites`
    deferred. `index` is `TipSite.index`; out-of-range answers `Tip.init`.
    */
    Tip resolveTipSite(size_t index) @system
    {
        import sparkles.dmd_lsp.ddoc : renderDdocText;

        ensureOccurrences();
        if (index >= _occurrences.length)
            return Tip.init;
        return composeTip(_occurrences[index].tip,
            (string comment, Dsymbol sym) => renderDdocText(comment, sym));
    }

    private void ensureOccurrences() @system
    {
        import sparkles.dmd_lsp.visitor : collectTips;

        if (!_walked)
        {
            _occurrences = collectTips(module_);
            _walked = true;
        }
    }

    // tipAt's rendering half, shared with allTips: `render` is the plain DDoc
    // renderer for a single query and a memoizing one for the batch walk.
    private Tip composeTip(TipDataT, Render)(auto ref TipDataT data, scope Render render) @system
    {
        import std.string : strip;

        if (data.doc.length && data.symbol !is null)
        {
            // Real DDoc rendering (sections -> chips, macros -> CommonMark).
            auto doc = render(data.doc, data.symbol);
            return Tip(kind: data.kind, code: data.code,
                doc: doc.docs, tags: doc.tags, sig: data.sig);
        }
        if (data.kind == "parameter" && data.symbol !is null)
        {
            auto tip = parameterTip(data, render);
            if (tip.found)
                return tip;
        }
        return Tip(kind: data.kind, code: data.code, doc: data.doc.strip,
            sig: data.sig);
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

    // A parameter inherits its docs from the enclosing function's `Params:`
    // row (the JSDoc/twoslash reference does exactly this for `@param`).
    private Tip parameterTip(TipDataT, Render)(auto ref TipDataT data, scope Render render) @system
    {
        import core.stdc.string : strlen;

        import sparkles.dmd_lsp.ddoc : paramDocFor;

        auto fn = data.symbol.parent;
        while (fn !is null && fn.isFuncDeclaration() is null
            && fn.isTemplateDeclaration() is null)
            fn = fn.parent;
        if (fn is null || fn.comment is null || data.symbol.ident is null)
            return Tip.init;

        const comment = fn.comment[0 .. strlen(fn.comment)].idup;
        auto rendered = render(comment, fn);
        const name = data.symbol.ident.toString.idup;
        const doc = paramDocFor(rendered, name);
        if (doc is null)
            return Tip.init;
        // The row *is* this parameter's documentation, so it lands in `doc`
        // alone. A `@param` chip beside it repeats the text verbatim and adds
        // only the name, which the signature line above already shows.
        return Tip(kind: data.kind, code: data.code, doc: doc);
    }

    /**
    Completion candidates at `line`:`col` (both 1-based), prefix-filtered by
    `prefix` (the identifier characters already typed). Backed by the ported
    `findExpansions` scope walk; sorted by name.
    */
    CompletionItem[] completionsAt(uint line, uint col, string prefix = "") @system
    {
        import std.algorithm.sorting : sort;

        import sparkles.dmd_lsp.visitor : findExpansions;

        CompletionItem[] items;
        foreach (entry; findExpansions(module_, cast(int) line, cast(int) col, prefix))
        {
            // entry = "name:KIND[:tip…]"
            import std.string : indexOf;

            const c1 = entry.indexOf(':');
            if (c1 < 0)
                continue;
            auto rest = entry[c1 + 1 .. $];
            const c2 = rest.indexOf(':');
            const code = c2 < 0 ? rest : rest[0 .. c2];
            items ~= CompletionItem(entry[0 .. c1], completionKind(code));
        }
        items.sort!((a, b) => a.name < b.name);
        return items;
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

    /// The declaration's documentation, rendered from DDoc to CommonMark
    /// (summary + description + Examples + custom sections; spec `DOC1`/
    /// `DOC2`); empty when the declaration carries none.
    string doc;

    /// `[name, text]` chip pairs from the standard DDoc sections: one
    /// `["param", "x desc"]` per `Params:` row, plus returns/throws/see/
    /// deprecated/authors/… (spec `DOC3`).
    string[][] tags;

    /// Where `code` may break, what of it collapses, and the effects and
    /// contracts lifted out of it (`TIP5`). Empty for everything but a
    /// function, and every offset indexes `code`.
    SignatureInfo sig;

    /// Whether the query resolved to anything.
    bool found() const @safe pure nothrow @nogc => kind.length != 0 || code.length != 0;
}

/// One resolved tooltip and where it applies. See `AnalyzedModule.allTips`.
struct TipHit
{
    /// 1-based line, as the oracle's positions are spelled.
    uint line;

    /// 1-based column of the identifier's first character.
    uint col;

    /// What `AnalyzedModule.tipAt` answers at that position.
    Tip tip;
}

/// A position the batch walk can answer, before its content is resolved.
/// See `AnalyzedModule.tipSites`.
struct TipSite
{
    /// 1-based line.
    uint line;

    /// 1-based column of the identifier's first character.
    uint col;

    /// Hand back to `AnalyzedModule.resolveTipSite` for the content.
    size_t index;
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

@("dmd_lsp.api.allTips.agreesWithTipAt")
@system unittest
{
    import std.conv : text;

    import sparkles.dmd_lsp.testing : withAnalysis;

    // Every position the batch walk reports must render exactly what a
    // single `tipAt` query renders there, DDoc memoization included.
    withAnalysis(q{                                   // Line 1
        /// Doubles a number.
        /// Params:
        ///     x = the number to double
        int twice(int x) => x * 2;                    // Line 5
        void use()
        {
            auto a = twice(1);
            auto b = twice(2);
        }                                             // Line 10
    }, (m) {
        auto hits = m.allTips;
        assert(hits.length, "no tips collected");

        bool sawDocs, sawParam;
        foreach (hit; hits)
        {
            const one = m.tipAt(hit.line, hit.col);
            assert(hit.tip == one, text("at ", hit.line, ":", hit.col,
                "\n  allTips: ", hit.tip, "\n  tipAt:   ", one));
            if (hit.tip.doc == "Doubles a number.")
                sawDocs = true;                        // rendered, not raw DDoc
            if (hit.tip.kind == "parameter" && hit.tip.doc == "the number to double")
                sawParam = true;                       // the Params: row hover
        }
        assert(sawDocs && sawParam);

        // `twice` is one symbol but three occurrences (declaration + two calls).
        size_t twiceCount;
        foreach (hit; hits)
            if (hit.tip.code == "int test.twice(int x)")
                twiceCount++;
        assert(twiceCount == 3, twiceCount.text);
    });
}

/// An in-memory file the entry module's imports can resolve to (matched by
/// the file's base name against the imported module identifier).
struct VirtualModule
{
    string filename;
    string source;
}

private string moduleBaseName(string filename) @safe pure
{
    import std.path : baseName, stripExtension;

    return filename.baseName.stripExtension;
}

/// One completion candidate: the inserted name plus a renderer-facing kind
/// (the TS/twoslash icon vocabulary where a counterpart exists — unknown
/// kinds fall back to the property icon by the render contract).
struct CompletionItem
{
    string name;
    string kind;
}

private string completionKind(scope const(char)[] code) @safe pure nothrow @nogc
{
    switch (code)
    {
        case "MTHD": return "method";
        case "FUNC": return "function";
        case "PROP": return "property";
        case "VAR": return "variable";
        case "CLSS": return "class";
        case "IFAC": return "interface";
        case "STRU": return "struct";
        case "UNIO": return "union";
        case "ENUM": return "enum";
        case "EVAL": return "enum member";
        case "ALIA": return "alias";
        case "TMPL": return "template";
        case "NMIX": return "mixin";
        case "MOD": return "module";
        case "PKG": return "module";
        case "OVR": return "function";
        default: return "text";
    }
}
