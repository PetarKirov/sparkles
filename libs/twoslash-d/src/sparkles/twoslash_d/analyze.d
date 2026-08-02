/**
The D twoslash pipeline: annotated source → notation → one `sparkles:dmd-lsp`
analysis → twoslash nodes (spec `NTN2`/`NTN3`, `DOC2`).

Node construction is two-phase: every node is first anchored in `fullSource`
bytes (converted from the oracle's 1-based line/column at the seam, via
`sparkles.base.text.lineindex`), then remapped through the notation's cut
`removals` — nodes inside hidden code are dropped, and surviving positions
resolve `line`/`character` against `displayCode`.

Hover enumeration walks the source's identifier occurrences (a tiny lexical
scan that skips comments and string literals) filtered by the semantic
classification (`identifierSpans` names every real identifier, which keeps
keywords and stray comment words out without a keyword table), matching each
against the oracle's one-walk tip table (`allTips`) and falling back to a
positional `tipAt` query for the few positions that table does not carry —
the TS-twoslash "hover every identifier" shape.
*/
module sparkles.twoslash_d.analyze;

import sparkles.base.text.lineindex : LineIndex;

import sparkles.dmd_lsp.api : AnalyzedModule, Analyzer, AnalyzerConfig, DiagKind,
    SignatureInfo, Tip;

import sparkles.twoslash.protocol : Node, NodeType, TwoslashReturn,
    WireAbbrev = Abbrev, WireBreakGroup = BreakGroup, WireBreakPoint = BreakPoint,
    WireContract = Contract, WireEffectSpan = EffectSpan,
    WireSignature = SignatureLayout;

import sparkles.twoslash_d.notation : ParsedNotation, parseNotation;

/// The pipeline result: the payload plus non-fatal drop notes.
struct AnalyzeResult
{
    TwoslashReturn payload;

    /// One entry per node that fell inside cut code (kept out of the payload)
    /// or diagnostic reported outside the sample file.
    string[] warnings;
}

/// Runs the whole pipeline over one annotated sample. One call per process
/// in batch use (`EXT2`); `baseConfig`'s paths/flags merge with the sample's
/// `@import:`/`@dflags:` directives.
AnalyzeResult analyzeTwoslash(string filename, string annotatedSource,
    AnalyzerConfig baseConfig = AnalyzerConfig(), bool lazyHovers = false) @system
{
    auto prep = prepare(filename, annotatedSource, baseConfig);
    auto analyzer = Analyzer(prep.config);
    auto analyzed = analyzer.analyze(prep.entryName, prep.entrySource, prep.extra);
    size_t[size_t] unused;
    return buildNodes(analyzed, prep, lazyHovers, unused);
}

/**
A resident analysis session for live viewing: analyze once (`EXT2` — one
analysis per process), publish a lazy payload immediately (spans-only hovers:
underlines render at once), then resolve individual hovers on demand at
single-position cost (~4 ms). The `--serve` oracle and hue's live overlay
are its consumers. Heap-allocate via `start` — the underlying `Analyzer`
holds the process-wide DMD session for the object's whole lifetime;
`shutdown` (or destruction) releases it.
*/
struct LiveTwoslash
{
    /// The lazy result (hover spans without content; queries, errors,
    /// completions, and tags fully resolved).
    AnalyzeResult result;

    private Analyzer* _analyzer;
    private AnalyzedModule _analyzed;
    private Prepared _prep;
    private LineIndex _entryIndex;
    private size_t[size_t] _siteOfNode;

    @disable this(this);

    /// Analyzes `source` and builds the lazy payload.
    static LiveTwoslash* start(string filename, string source,
        AnalyzerConfig baseConfig = AnalyzerConfig()) @system
    {
        auto live = new LiveTwoslash;
        live._prep = prepare(filename, source, baseConfig);
        live._analyzer = new Analyzer(live._prep.config);
        live._analyzed = live._analyzer.analyze(
            live._prep.entryName, live._prep.entrySource, live._prep.extra);
        live._entryIndex = LineIndex(live._prep.entrySource);
        live.result = buildNodes(live._analyzed, live._prep, lazyHovers: true,
            live._siteOfNode);
        return live;
    }

    /// Resolves one payload node's tip content (hover or query index into
    /// `payload.nodes`). `Tip.init` when the node has no resolvable content.
    Tip tipForNode(size_t index) @system
    {
        if (_analyzer is null || index >= result.payload.nodes.length)
            return Tip.init;

        // A lazy hover answers from the walk that emitted its span. Going back
        // through a position query instead would disagree with that walk in
        // the shapes it cannot reach (an alias's function-type parameters, for
        // one) and answer nothing, leaving an underline with no popup.
        if (auto site = index in _siteOfNode)
            return _analyzed.resolveTipSite(*site);

        const n = result.payload.nodes[index];
        const full = _prep.notation.mapToFull(n.start);
        if (full < _prep.entryStart || full >= _prep.entryEnd)
            return Tip.init;
        const pos = _entryIndex.lineColAt(full - _prep.entryStart);
        return _analyzed.tipAt(cast(uint) pos.line + 1, cast(uint) pos.column + 1);
    }

    /// Releases the DMD session (idempotent).
    void shutdown() @system
    {
        if (_analyzer is null)
            return;
        destroy(*_analyzer);
        _analyzer = null;
    }

    ~this() @system
    {
        shutdown();
    }
}

/// The compiler-free front half of the pipeline: notation, config merge, and
/// the multi-file segmentation (`@filename:` — the last segment is the entry
/// module; earlier segments resolve through its imports as in-memory virtual
/// modules; a single-file sample is the degenerate one-segment case).
private struct Prepared
{
    import sparkles.dmd_lsp.api : VirtualModule;

    ParsedNotation notation;
    AnalyzerConfig config;
    string entryName;
    size_t entryStart;
    size_t entryEnd;
    string entrySource;
    VirtualModule[] extra;
}

private Prepared prepare(string filename, string annotatedSource,
    AnalyzerConfig baseConfig) @system
{
    import sparkles.dmd_lsp.api : VirtualModule;

    Prepared prep;
    prep.notation = parseNotation(annotatedSource);

    prep.config = baseConfig;
    prep.config.importPaths = prep.config.effectiveImportPaths
        ~ prep.notation.importPaths;
    prep.config.dflags ~= prep.notation.dflags;

    const files = prep.notation.files;
    prep.entryName = files.length ? files[$ - 1].name : filename;
    prep.entryStart = files.length ? files[$ - 1].contentStart : 0;
    prep.entryEnd = files.length ? files[$ - 1].contentEnd
        : prep.notation.fullSource.length;
    prep.entrySource = prep.notation.fullSource[prep.entryStart .. prep.entryEnd];
    foreach (f; files.length ? files[0 .. $ - 1] : null)
        prep.extra ~= VirtualModule(f.name,
            prep.notation.fullSource[f.contentStart .. f.contentEnd]);
    return prep;
}

/**
The analyzer's signature structure, as the wire model.

Two POD shapes for one idea: `sparkles:dmd-lsp` speaks in frontend enums, and
`sparkles:twoslash-protocol` must not depend on the frontend at all, so the
translation lands here — the one package that already sees both.

Offsets pass through untouched: they index the tip's `code`, which is exactly
the `text` the node carries.
*/
private WireSignature toWire(const SignatureInfo info) @safe pure
{
    import sparkles.dmd_lsp.api : AbbrevKind, ContractKind, SigTrust;

    WireSignature w;

    foreach (g; info.groups)
        w.groups ~= WireBreakGroup(g.open, g.close, g.stage);
    foreach (b; info.breaks)
        w.breaks ~= WireBreakPoint(b.offset, b.group);
    foreach (a; info.abbrevs)
        w.abbrevs ~= WireAbbrev(a.offset, a.length, a.shortText,
            a.kind == AbbrevKind.nestedTemplateArgs ? "template" : "module");

    final switch (info.effects.trust)
    {
        case SigTrust.unspecified: w.effects.trust = null;       break;
        case SigTrust.system:      w.effects.trust = "@system";  break;
        case SigTrust.trusted:     w.effects.trust = "@trusted"; break;
        case SigTrust.safe:        w.effects.trust = "@safe";    break;
    }
    w.effects.isPure = info.effects.isPure;
    w.effects.isNothrow = info.effects.isNothrow;
    w.effects.isNogc = info.effects.isNogc;
    w.effects.inferred = info.effects.inferred;
    foreach (sp; info.effects.spans)
        w.effects.spans ~= WireEffectSpan(sp.offset, sp.length);

    foreach (c; info.contracts)
        w.contracts ~= WireContract(c.kind == ContractKind.in_ ? "in" : "out",
            c.resultId, c.text, c.isBlock);

    w.constraint = info.constraint;
    return w;
}

/// Whether a tip's structure describes the text the node will carry.
///
/// Every offset indexes the tip's `code`, and `tipText` prefixes `"(kind) "`
/// for everything that has a kind — a function has none, which is exactly the
/// set the producer records structure for. Anything else would carry offsets
/// pointing where they no longer say.
private bool structureMatchesText(const Tip tip) @safe pure nothrow @nogc
    => tip.kind.length == 0;

/// The node-building back half over a live analysis. `lazyHovers` emits
/// hover nodes as bare spans (empty `text`/`docs` — the documented lazy
/// convention): underlines render, content resolves on demand
/// (`LiveTwoslash.tipForNode`). Queries, completions, errors, and tags stay
/// eager in every mode — they are few and always visible.
private AnalyzeResult buildNodes(ref AnalyzedModule analyzed, ref Prepared prep,
    bool lazyHovers, out size_t[size_t] siteOfNode) @system
{
    auto notation = prep.notation;
    const entryName = prep.entryName;
    const entryStart = prep.entryStart;
    const entryEnd = prep.entryEnd;
    const entrySource = prep.entrySource;
    const files = notation.files;

    // Oracle coordinates are local to the entry segment; node offsets are
    // global (`fullSource`) — `entryStart` is the shift between them.
    const entryIndex = LineIndex(entrySource);

    AnalyzeResult result;
    Node[] nodes;

    // --- hovers: every identifier occurrence the semantics classified.
    bool[string] knownIdents;
    foreach (span; analyzed.identifierSpans)
        knownIdents[span.ident] = true;

    // One walk for all of them: `tipAt` costs a full-module AST walk per
    // call, which on a large file is minutes. `allTips` answers most
    // positions from a single walk; the rest fall back below, so coverage is
    // unchanged either way. Lazy mode skips tip content entirely.
    Tip[ulong] batchTips;
    if (!lazyHovers)
        foreach (ref hit; analyzed.allTips)
            batchTips[posKey(hit.line, hit.col)] = hit.tip;

    // Lazy mode asks the same walk *where* it has something to say, without
    // paying to render it. Emitting a span the oracle cannot answer is what
    // put a twoslash underline under `CoreLogEntry` in an alias's function
    // type with no popup behind it: the lexical scan finds the identifier,
    // but a position query into a type's parameter list resolves nothing.
    size_t[ulong] siteAt;
    if (lazyHovers)
        foreach (ref site; analyzed.tipSites)
            siteAt[posKey(site.line, site.col)] = site.index;

    foreach (word; identifierOccurrences(notation.fullSource))
    {
        if (word.text !in knownIdents)
            continue;
        // Only the entry segment is tippable (aux virtual files have their
        // own modules; per-file oracles are follow-up work).
        if (word.offset < entryStart || word.offset >= entryEnd)
            continue;
        const pos = entryIndex.lineColAt(word.offset - entryStart);
        const line = cast(uint) pos.line + 1, col = cast(uint) pos.column + 1;
        if (lazyHovers)
        {
            // Note the walk's site when it has one: answering from the same
            // walk that classified the identifier keeps the span and its
            // content in agreement, and costs a lookup instead of the
            // full-module walk a position query repeats per request. Spans
            // without a site stay — a position query reaches shapes the walk
            // does not (`collectTips`' documented under-coverage), and
            // `tipForNode` falls back to it.
            if (auto site = posKey(line, col) in siteAt)
                siteOfNode[nodes.length] = *site;
            nodes ~= Node(
                type: NodeType.hover,
                start: word.offset,
                length: word.text.length);
            continue;
        }
        const batched = posKey(line, col) in batchTips;
        const tip = batched ? *batched : analyzed.tipAt(line, col);
        if (!tip.found)
            continue;
        nodes ~= Node(
            type: NodeType.hover,
            start: word.offset,
            length: word.text.length,
            text: tipText(tip),
            docs: tip.doc,
            tags: tip.tags.toMutableTags,
            signature: structureMatchesText(tip)
                ? toWire(tip.sig) : WireSignature.init);
    }

    // --- `^?` queries: same oracle, persisted below the line.
    foreach (q; notation.queries)
    {
        if (q.offset < entryStart || q.offset >= entryEnd)
        {
            result.warnings ~= "query at offset " ~ q.offset.toStr
                ~ " lies outside the entry file — skipped";
            continue;
        }
        const pos = entryIndex.lineColAt(q.offset - entryStart);
        const tip = analyzed.tipAt(cast(uint) pos.line + 1, cast(uint) pos.column + 1);
        if (!tip.found)
        {
            result.warnings ~= "query at offset " ~ q.offset.toStr
                ~ " resolved to nothing";
            continue;
        }
        // Snap to the identifier's start: the caret may point at any of its
        // characters (TS twoslash is equally forgiving).
        const anchor = identifierStartAt(notation.fullSource, q.offset);
        nodes ~= Node(
            type: NodeType.query,
            start: anchor,
            length: identifierLengthAt(notation.fullSource, anchor),
            text: tipText(tip),
            docs: tip.doc,
            tags: tip.tags.toMutableTags);
    }

    // --- diagnostics → error nodes (D has no stable numeric codes: `code`
    // stays 0 and `id` is synthetic, spec `EXT3`).
    size_t errIndex;
    foreach (d; analyzed.diagnostics)
    {
        // Resolve the diagnostic's file to its segment (entry or a virtual
        // aux file); anything else is outside the sample.
        size_t segBase = size_t.max;
        LineIndex segIndex;
        if (d.pos.filename == entryName)
        {
            segBase = entryStart;
            segIndex = LineIndex(entrySource);
        }
        else
            foreach (f; files.length ? files[0 .. $ - 1] : null)
                if (d.pos.filename == f.name)
                {
                    segBase = f.contentStart;
                    segIndex = LineIndex(
                        notation.fullSource[f.contentStart .. f.contentEnd]);
                    break;
                }
        if (segBase == size_t.max)
        {
            result.warnings ~= "diagnostic outside the sample ("
                ~ d.pos.filename ~ "): " ~ d.message;
            continue;
        }
        const start = segBase + segIndex.offsetOfDmd(d.pos.line, d.pos.column);
        auto node = Node(
            type: NodeType.error,
            start: start,
            length: identifierLengthAt(notation.fullSource, start),
            text: d.message,
            level: d.kind == DiagKind.error ? "error"
                : d.kind == DiagKind.warning ? "warning"
                : d.kind == DiagKind.deprecation ? "warning" : "message",
            id: "err-" ~ (errIndex++).toStr);
        foreach (note; d.notes)
            node.text ~= "\n" ~ note.message;
        nodes ~= node;
    }

    // --- `^|` completion lists: candidates at the caret, filtered by the
    // identifier prefix already typed before it (TS semantics).
    foreach (c; notation.completions)
    {
        import sparkles.twoslash.protocol : Completion;

        if (c.offset < entryStart || c.offset >= entryEnd)
        {
            result.warnings ~= "completion at offset " ~ c.offset.toStr
                ~ " lies outside the entry file — skipped";
            continue;
        }
        const prefixStart = identifierStartAt(notation.fullSource,
            c.offset ? c.offset - 1 : 0);
        const prefix = prefixStart < c.offset
            ? notation.fullSource[prefixStart .. c.offset] : "";
        const pos = entryIndex.lineColAt(c.offset - entryStart);
        auto items = analyzed.completionsAt(
            cast(uint) pos.line + 1, cast(uint) pos.column + 1, prefix.idup);
        if (!items.length)
        {
            result.warnings ~= "completion at offset " ~ c.offset.toStr
                ~ " produced no candidates";
            continue;
        }
        Completion[] entries;
        foreach (it; items)
            entries ~= Completion(name: it.name, kind: it.kind);
        nodes ~= Node(
            type: NodeType.completion,
            start: c.offset,
            length: 0,
            completions: entries,
            completionsPrefix: prefix.idup);
    }

    // --- `^^^` highlight spans (pure notation; no oracle involved).
    foreach (h; notation.highlights)
        nodes ~= Node(
            type: NodeType.highlight,
            start: h.offset,
            length: h.length,
            text: h.text);

    // --- custom tag lines.
    foreach (t; notation.tags)
        nodes ~= Node(
            type: NodeType.tag,
            start: t.offset,
            name: t.name,
            text: t.text);

    // --- phase 2: cut remap + display line/character resolution.
    const displayIndex = LineIndex(notation.displayCode);
    Node[] visible;
    foreach (node; nodes)
    {
        const mapped = notation.mapToDisplay(node.start);
        if (mapped < 0)
        {
            if (node.type != NodeType.hover) // hidden hovers are expected
                result.warnings ~= nodeKindName(node.type) ~ " node at offset "
                    ~ node.start.toStr ~ " lies in cut code — dropped";
            continue;
        }
        node.start = mapped;
        const pos = displayIndex.lineColAt(node.start);
        node.line = pos.line;
        node.character = pos.column;
        visible ~= node;
    }

    import std.algorithm.sorting : sort;

    // Deterministic output: by position, then by kind for co-anchored nodes.
    visible.sort!((a, b) => a.start != b.start ? a.start < b.start : a.type < b.type);

    result.payload = TwoslashReturn(
        code: notation.displayCode,
        nodes: visible,
        language: "d",
        offsetEncoding: "utf-8");
    return result;
}

/// One 1-based oracle position as a lookup key.
private ulong posKey(uint line, uint col) @safe pure nothrow @nogc
    => (cast(ulong) line << 32) | col;

private string[][] toMutableTags(in string[][] tags) @safe pure
{
    string[][] copy;
    foreach (t; tags)
        copy ~= t.dup;
    return copy;
}

/// The popup signature in the reference shape: `(kind) code` — the same
/// parenthesized-kind prefix TS quickinfo uses (and `dmdserver` renders).
private string tipText(const Tip tip) @safe pure
    => tip.kind.length ? "(" ~ tip.kind ~ ") " ~ tip.code : tip.code;

private string nodeKindName(NodeType t) @safe pure nothrow @nogc
{
    final switch (t)
    {
        case NodeType.hover: return "hover";
        case NodeType.query: return "query";
        case NodeType.completion: return "completion";
        case NodeType.error: return "error";
        case NodeType.highlight: return "highlight";
        case NodeType.tag: return "tag";
    }
}

private string toStr(size_t v) @safe pure nothrow
{
    import std.conv : to;

    try
        return v.to!string;
    catch (Exception)
        return "?";
}

/// One identifier word found by the lexical scan.
private struct Word
{
    size_t offset;
    string text;
}

private bool isIdentStart(char c) @safe pure nothrow @nogc
    => c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');

private bool isIdentChar(char c) @safe pure nothrow @nogc
    => isIdentStart(c) || (c >= '0' && c <= '9');

/**
Scans `source` for identifier-shaped words outside comments and string
literals. A deliberately small lexer: it understands line comments, block
comments, nesting `+`-comments, and double-/back-/single-quoted literals
(with backslash escapes where D honors them) — enough to keep comment prose
and string contents from producing hover probes. ASCII identifiers only (v1;
Unicode identifiers are rare in samples and simply get no hover).
*/
private Word[] identifierOccurrences(string source) @safe pure
{
    Word[] words;
    size_t i = 0;
    const n = source.length;

    while (i < n)
    {
        const c = source[i];

        // comments
        if (c == '/' && i + 1 < n)
        {
            const d = source[i + 1];
            if (d == '/')
            {
                while (i < n && source[i] != '\n')
                    i++;
                continue;
            }
            if (d == '*')
            {
                i += 2;
                while (i + 1 < n && !(source[i] == '*' && source[i + 1] == '/'))
                    i++;
                i = i + 2 <= n ? i + 2 : n;
                continue;
            }
            if (d == '+')
            {
                size_t depth = 1;
                i += 2;
                while (i + 1 < n && depth)
                {
                    if (source[i] == '/' && source[i + 1] == '+')
                    {
                        depth++;
                        i += 2;
                    }
                    else if (source[i] == '+' && source[i + 1] == '/')
                    {
                        depth--;
                        i += 2;
                    }
                    else
                        i++;
                }
                continue;
            }
        }

        // string / character literals
        if (c == '"' || c == '\'' || c == '`')
        {
            const quote = c;
            i++;
            while (i < n && source[i] != quote)
            {
                if (quote != '`' && source[i] == '\\' && i + 1 < n)
                    i++;
                i++;
            }
            if (i < n)
                i++;
            continue;
        }

        // identifiers
        if (isIdentStart(c))
        {
            const start = i;
            while (i < n && isIdentChar(source[i]))
                i++;
            words ~= Word(start, source[start .. i]);
            continue;
        }

        i++;
    }
    return words;
}

/// The start of the identifier covering `offset` (or `offset` itself when it
/// is not on one).
private size_t identifierStartAt(string source, size_t offset) @safe pure nothrow @nogc
{
    if (offset >= source.length || !isIdentChar(source[offset]))
        return offset;
    size_t start = offset;
    while (start > 0 && isIdentChar(source[start - 1]))
        start--;
    return start;
}

/// The identifier extent starting at `offset` (≥ 1, so zero-width anchors
/// still underline one character).
private size_t identifierLengthAt(string source, size_t offset) @safe pure nothrow @nogc
{
    if (offset >= source.length || !isIdentStart(source[offset]))
        return 1;
    size_t end = offset;
    while (end < source.length && isIdentChar(source[end]))
        end++;
    return end - offset;
}

// -- pure tests (no DMD) -----------------------------------------------------

@("analyze.identifierOccurrences")
@safe pure unittest
{
    const words = identifierOccurrences(
        "auto x = f(y); // not_this\n/* nor_this */ `nor \"me\"` z");
    string[] names;
    foreach (w; words)
        names ~= w.text;
    assert(names == ["auto", "x", "f", "y", "z"], names.toStrJoined);
}

@("analyze.identifierLengthAt")
@safe pure unittest
{
    assert(identifierLengthAt("answer + 1", 0) == 6);
    assert(identifierLengthAt("a + b", 2) == 1); // punctuation: minimum 1
}

version (unittest)
private string toStrJoined(string[] ss) @safe pure
{
    import std.array : join;

    return ss.join(",");
}

// -- semantic tests (env-gated) ----------------------------------------------

// Local gating rather than dmd-lsp's analyzerConfigForTest: that helper's
// skipTest fallback resolves in *its* package's build context (a plain
// library dependency here, no runner), so from this suite it would throw a
// failure instead of a skip. Our unittest configuration has the runner.
version (unittest) private AnalyzerConfig gatedConfig() @system
{
    import std.process : environment;

    import sparkles.test_runner.skip : skipTest;

    if (!environment.get("SPARKLES_DMD_IMPORT_PATH", "").length)
        skipTest("SPARKLES_DMD_IMPORT_PATH not set (enter `nix develop`)");
    return AnalyzerConfig();
}

@("analyze.analyzeTwoslash.endToEnd")
@system unittest
{
    auto r = analyzeTwoslash("sample.d", "module sample;\n"
        ~ "// ---cut---\n"
        ~ "/// Doubles a number.\n"
        ~ "int twice(int x) => x * 2;\n"
        ~ "auto answer = twice(21);\n"
        ~ "//     ^?\n",
        gatedConfig());

    const tw = r.payload;
    assert(tw.language == "d");
    assert(tw.offsetEncoding == "utf-8");
    // The module declaration is cut: display starts at the doc comment.
    assert(tw.code[0 .. 3] == "///", tw.code);

    // The `^?` query resolved `answer` and carries the inferred type.
    size_t queryIdx = size_t.max;
    foreach (i, ref nd; tw.nodes)
        if (nd.type == NodeType.query)
            queryIdx = i;
    assert(queryIdx != size_t.max);
    const query = tw.nodes[queryIdx];
    assert(query.length == "answer".length);
    import std.algorithm.searching : canFind;

    assert(query.text.canFind("int"), query.text);

    // Hovers exist for visible identifiers, and the ddoc travelled onto the
    // `twice` hover (spec DOC2 via DOC1).
    bool sawDocs;
    foreach (nd; tw.nodes)
        if (nd.type == NodeType.hover
            && tw.code[nd.start .. nd.start + nd.length] == "twice"
            && nd.docs.canFind("Doubles a number"))
            sawDocs = true;
    assert(sawDocs);

    // Nothing anchors inside cut code; every node's span is within the display.
    foreach (nd; tw.nodes)
        assert(nd.start + nd.length <= tw.code.length);
}

@("analyze.analyzeTwoslash.errors")
@system unittest
{
    import std.algorithm.searching : canFind;

    auto r = analyzeTwoslash("sample.d", "module sample;\n"
        ~ "void f() { int x = \"oops\"; }\n",
        gatedConfig());

    size_t errIdx = size_t.max;
    foreach (i, ref nd; r.payload.nodes)
        if (nd.type == NodeType.error)
            errIdx = i;
    assert(errIdx != size_t.max);
    const err = r.payload.nodes[errIdx];
    assert(err.text.canFind("cannot implicitly convert"), err.text);
    assert(err.level == "error");
    assert(err.line == 1); // 0-based display line of the offending code
}

@("analyze.analyzeTwoslash.completions")
@system unittest
{
    // The caret sits right after a typed prefix that is itself a valid
    // identifier, so the sample stays compilable while `^|` asks "what
    // could continue here" — expect both prefix-matching symbols.
    auto r = analyzeTwoslash("sample.d", "module sample;\n"
        ~ "int alpha = 1;\n"
        ~ "int alphabet = 2;\n"
        ~ "auto x = alpha;\n"
        ~ "//            ^|\n",
        gatedConfig());

    size_t idx = size_t.max;
    foreach (i, ref nd; r.payload.nodes)
        if (nd.type == NodeType.completion)
            idx = i;
    assert(idx != size_t.max, "no completion node emitted");
    const node = r.payload.nodes[idx];
    assert(node.completionsPrefix == "alpha", node.completionsPrefix);
    assert(node.length == 0);

    bool sawAlpha, sawAlphabet;
    foreach (c; node.completions)
    {
        if (c.name == "alpha") sawAlpha = true;
        if (c.name == "alphabet") sawAlphabet = true;
    }
    assert(sawAlpha && sawAlphabet, node.completions.length.toStr);
}

@("analyze.analyzeTwoslash.multiFile")
@system unittest
{
    import std.algorithm.searching : canFind;

    // Two virtual files: the entry (last) imports the helper; the helper's
    // symbol resolves through the in-memory module and the entry's query
    // shows its type. Marker lines stay in the display.
    auto r = analyzeTwoslash("sample.d",
        "// @filename: helper.d\n"
        ~ "module helper;\n"
        ~ "/// The lucky constant.\n"
        ~ "enum lucky = 7;\n"
        ~ "// @filename: app.d\n"
        ~ "module app;\n"
        ~ "import helper;\n"
        ~ "auto value = lucky * 6;\n"
        ~ "//    ^?\n",
        gatedConfig());

    const tw = r.payload;
    assert(tw.code.canFind("// @filename: helper.d"), tw.code);

    size_t queryIdx = size_t.max;
    foreach (i, ref nd; tw.nodes)
        if (nd.type == NodeType.query)
            queryIdx = i;
    assert(queryIdx != size_t.max, "no query node");
    const q = tw.nodes[queryIdx];
    assert(tw.code[q.start .. q.start + q.length] == "value");
    assert(q.text.canFind("int"), q.text);

    // A hover on `lucky` in the entry file carries the helper's ddoc across
    // the module boundary.
    bool sawLuckyDocs;
    foreach (ref nd; tw.nodes)
        // Auto-emphasis backticks the in-scope symbol: "The `lucky` constant."
        if (nd.type == NodeType.hover
            && tw.code[nd.start .. nd.start + nd.length] == "lucky"
            && nd.docs.canFind("The `lucky` constant."))
            sawLuckyDocs = true;
    assert(sawLuckyDocs);
}

@("analyze.analyzeTwoslash.multiFileAuxError")
@system unittest
{
    import std.algorithm.searching : canFind;

    // A diagnostic inside the helper file anchors within the helper's own
    // display segment, not the entry's.
    auto r = analyzeTwoslash("sample.d",
        "// @filename: helper.d\n"
        ~ "module helper;\n"
        ~ "int bad = \"oops\";\n"
        ~ "// @filename: app.d\n"
        ~ "module app;\n"
        ~ "import helper;\n",
        gatedConfig());

    size_t errIdx = size_t.max;
    foreach (i, ref nd; r.payload.nodes)
        if (nd.type == NodeType.error)
            errIdx = i;
    assert(errIdx != size_t.max, "no error node");
    const err = r.payload.nodes[errIdx];
    assert(err.text.canFind("cannot implicitly convert"), err.text);
    // The anchor sits inside helper.d's segment (line 2, 0-based, of the
    // display: the marker line is line 0).
    assert(err.line == 2, "unexpected error line");
}

@("analyze.LiveTwoslash.lazyPayloadAndOnDemandTips")
@system unittest
{
    import std.algorithm.searching : canFind;

    auto live = LiveTwoslash.start("sample.d", "module sample;\n"
        ~ "/// Doubles.\n"
        ~ "int twice(int x) => x * 2;\n"
        ~ "auto answer = twice(21);\n"
        ~ "//     ^?\n",
        gatedConfig());
    scope (exit) live.shutdown();

    const tw = live.result.payload;
    size_t hoverIdx = size_t.max;
    bool sawEagerQuery;
    foreach (i, ref nd; tw.nodes)
    {
        if (nd.type == NodeType.hover)
        {
            // Lazy convention: spans only, no content.
            assert(nd.text.length == 0 && nd.docs.length == 0);
            if (tw.code[nd.start .. nd.start + nd.length] == "twice")
                hoverIdx = i;
        }
        if (nd.type == NodeType.query && nd.text.canFind("int"))
            sawEagerQuery = true;
    }
    assert(hoverIdx != size_t.max, "no hover span for `twice`");
    assert(sawEagerQuery, "queries must stay eager in lazy mode");

    // On-demand resolution carries the full content, ddoc included.
    const tip = live.tipForNode(hoverIdx);
    assert(tip.found);
    assert(tip.code.canFind("twice"), tip.code);
    assert(tip.doc.canFind("Doubles"), tip.doc);
}
