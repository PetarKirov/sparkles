// Tree-sitter fold-range providers (`FSR1`/`FSR2`): fold ranges for a code
// document as source byte spans (`FSR4`), the same currency selection and the
// markdown provider (`FSR3`) use.
//
// Where the grammar bundle ships a `folds.scm` query (the nvim-treesitter
// `@fold` convention) its captures are preferred — precise, language-tuned
// ranges. Absent one, the CST heuristic covers every language with a grammar:
// any named node spanning more than one line is foldable, deduplicated so a
// wrapper node sharing its child's start byte yields one region (the
// outermost — regions still nest at distinct starts, and the fold key is the
// span start).
module sparkles.syntax.ts.folds;

import sparkles.syntax.md.model : Span;
import sparkles.syntax.ts.injection : TsConfigCache;
import sparkles.tree_sitter : nodeNamedChild, nodeNamedChildCount, nodeRange,
    ParseGuards, TsError, TSNode, TsParser, TSQueryMatch, TsQuery,
    TsQueryCursor, TsTree;

@system:

/**
The fold ranges of `source` in `language`: the `folds.scm` captures when the
bundle ships that query, else the CST heuristic. Returns no spans when the
language has no configured grammar (totality — folding is simply absent).
*/
Span[] foldableSpansCst(ref TsConfigCache cache, const(char)[] language,
    scope const(char)[] source)
{
    if (!source.length)
        return null;

    const cfg = cache.resolve(language);
    if (cfg is null)
        return null;

    auto parser = TsParser.create();
    if (parser.setLanguage(cfg.grammar.language).hasError)
        return null;
    TsError parseError;
    auto tree = parser.parse(source, parseError, ParseGuards());
    if (!tree.valid)
        return null;

    return foldableSpansFromTree(cache, language, tree);
}

/**
ditto, over a tree the caller already holds — the retained-parse path: an
interactive consumer that keeps the document's `TsTree` alive (the
tree-sitter inspector's seam) derives its fold ranges from that tree instead
of paying a second parse per rebuild.
*/
Span[] foldableSpansFromTree(ref TsConfigCache cache, const(char)[] language,
    ref const TsTree tree)
{
    const cfg = cache.resolve(language);
    if (cfg is null || !tree.valid)
        return null;

    // FSR2: a shipped folds.scm defines the ranges (whatever its capture
    // names — nvim-treesitter uses a single `@fold`).
    auto scm = cache.registry.queryText(language, "folds");
    if (!scm.hasError)
    {
        TsError queryError;
        auto query = TsQuery.create(cfg.grammar.language, scm.value,
            queryError);
        if (!queryError && query.valid)
        {
            auto cursor = TsQueryCursor.create();
            cursor.exec(query, tree.rootNode);
            Span[] spans;
            size_t lastStart = size_t.max;
            TSQueryMatch match;
            uint captureIndex;
            while (cursor.nextCapture(match, captureIndex))
            {
                // Copy eagerly: `match.captures` aliases cursor storage.
                const r = nodeRange(match.captures[captureIndex].node);
                if (r.end_point.row <= r.start_point.row)
                    continue; // a single-line region folds nothing
                if (r.start_byte == lastStart)
                    continue;
                spans ~= Span(r.start_byte, r.end_byte);
                lastStart = r.start_byte;
            }
            return spans;
        }
    }

    // FSR1: the heuristic — any named node spanning more than one line. A
    // single-line node cannot contain a multi-line child, so those subtrees
    // prune; the root (the whole document) is skipped as noise.
    Span[] spans;
    size_t lastStart = size_t.max;
    void walk(TSNode n, int depth)
    {
        const r = nodeRange(n);
        if (r.end_point.row <= r.start_point.row)
            return;
        if (r.start_byte != lastStart)
        {
            spans ~= Span(r.start_byte, r.end_byte);
            lastStart = r.start_byte;
        }
        if (depth >= 400) // a pathological tree stops folding, not the app
            return;
        foreach (i; 0 .. nodeNamedChildCount(n))
            walk(nodeNamedChild(n, i), depth + 1);
    }

    TSNode root = tree.rootNode;
    foreach (i; 0 .. nodeNamedChildCount(root))
        walk(nodeNamedChild(root, i), 0);
    return spans;
}

@("ts.folds.cstHeuristicMultiLineNamedNodes")
@system unittest
{
    import std.process : environment;
    import sparkles.syntax.label : LabelSet;
    import sparkles.syntax.ts.registry : GrammarRegistry;
    import sparkles.test_runner.skip : skipTest;

    if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    auto reg = GrammarRegistry.fromEnvironment();
    auto cache = TsConfigCache.create(&reg, LabelSet.standard());

    const src = "void f()\n{\n    int a;\n    int b;\n}\n\nint g() => 1;\n";
    auto spans = foldableSpansCst(cache, "d", src);

    // The multi-line function (and its block) fold; the one-liner does not.
    assert(spans.length >= 1, "multi-line regions found");
    bool sawFn, sawOneLiner;
    foreach (sp; spans)
    {
        if (sp.start == 0 && sp.end >= 33)
            sawFn = true;
        if (sp.start >= 35)
            sawOneLiner = true;
    }
    assert(sawFn, "the multi-line function is foldable");
    assert(!sawOneLiner, "a single-line declaration is not");

    // Distinct nested starts survive (the block under the function), and
    // starts are unique — the fold key is the span start.
    foreach (i, a; spans)
        foreach (b; spans[i + 1 .. $])
            assert(a.start != b.start, "unique fold keys");

    // An unknown language degrades to no folds, not an error.
    assert(foldableSpansCst(cache, "no-such-lang", src).length == 0);
}
