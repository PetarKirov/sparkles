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
keywords and stray comment words out without a keyword table), querying the
type oracle per occurrence — the TS-twoslash "hover every identifier" shape.
*/
module sparkles.twoslash_d.analyze;

import sparkles.base.text.lineindex : LineIndex;

import sparkles.dmd_lsp.api : Analyzer, AnalyzerConfig, DiagKind, Tip;

import sparkles.twoslash.protocol : Node, NodeType, TwoslashReturn;

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
    AnalyzerConfig baseConfig = AnalyzerConfig()) @system
{
    auto notation = parseNotation(annotatedSource);

    auto config = baseConfig;
    config.importPaths = config.effectiveImportPaths ~ notation.importPaths;
    config.dflags ~= notation.dflags;

    auto analyzer = Analyzer(config);
    auto analyzed = analyzer.analyze(filename, notation.fullSource);

    const fullIndex = LineIndex(notation.fullSource);

    AnalyzeResult result;
    Node[] nodes;

    // --- hovers: every identifier occurrence the semantics classified.
    bool[string] knownIdents;
    foreach (span; analyzed.identifierSpans)
        knownIdents[span.ident] = true;

    foreach (word; identifierOccurrences(notation.fullSource))
    {
        if (word.text !in knownIdents)
            continue;
        const pos = fullIndex.lineColAt(word.offset);
        const tip = analyzed.tipAt(cast(uint) pos.line + 1, cast(uint) pos.column + 1);
        if (!tip.found)
            continue;
        nodes ~= Node(
            type: NodeType.hover,
            start: word.offset,
            length: word.text.length,
            text: tipText(tip),
            docs: tip.doc,
            tags: tip.tags.toMutableTags);
    }

    // --- `^?` queries: same oracle, persisted below the line.
    foreach (q; notation.queries)
    {
        const pos = fullIndex.lineColAt(q.offset);
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
        if (d.pos.filename != filename)
        {
            result.warnings ~= "diagnostic outside the sample ("
                ~ d.pos.filename ~ "): " ~ d.message;
            continue;
        }
        const start = fullIndex.offsetOfDmd(d.pos.line, d.pos.column);
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

        const prefixStart = identifierStartAt(notation.fullSource,
            c.offset ? c.offset - 1 : 0);
        const prefix = prefixStart < c.offset
            ? notation.fullSource[prefixStart .. c.offset] : "";
        const pos = fullIndex.lineColAt(c.offset);
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
