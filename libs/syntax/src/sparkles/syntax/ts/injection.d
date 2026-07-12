/**
Injection discovery: turning `injections.scm` matches into embedded-language
layers.

Three pieces the layered highlighter ($(REF highlightInjected,
sparkles,syntax,ts,highlighter)) composes:

$(LIST
    * $(LREF injectionForMatch) — reads one injection-query match into a
        `(language, content node, include-children)` triple (the reference
        crate's `injection_for_match`);
    * $(LREF intersectRanges) — turns a content node into the `TSRange[]` an
        injected parser is restricted to (whole node, or the gaps between its
        children when `include-children` is off), clipped to the parent layer's
        own ranges (`intersect_ranges`);
    * $(LREF TsConfigCache) — the reference's `injection_callback`: maps a
        language name to a configured $(REF TsHighlightConfig,
        sparkles,syntax,ts,config), loading grammar + queries through a
        $(REF GrammarRegistry, sparkles,syntax,ts,registry) once and caching
        the result (misses included, so a missing grammar is looked up once and
        thereafter renders as plain text).
)

Scope (M7): non-combined injections with `injection.language` (captured node
text or `#set!` directive) and `injection.include-children`. `injection.combined`
and locals scope-tracking are deferred (PLAN §4).
*/
module sparkles.syntax.ts.injection;

import sparkles.syntax.ts.config : TsHighlightConfig;
import sparkles.syntax.ts.registry : GrammarRegistry, canonicalLanguage;
import sparkles.syntax.label : LabelSet;
import sparkles.tree_sitter.errors : TsError;
import sparkles.tree_sitter.tree_sitter_c : TSNode, TSPoint, TSQueryMatch, TSRange;
import sparkles.tree_sitter.wrappers : nodeEndByte, nodeNamedChild,
    nodeNamedChildCount, nodeRange, nodeStartByte;

/// One resolved injection: the embedded language, the node whose text it
/// covers, and whether the injected parse spans the node's children too.
struct InjectionMatch
{
    const(char)[] language;   /// injected language name (empty ⇒ unresolved)
    TSNode contentNode;       /// the `@injection.content` node
    bool hasContent;          /// `true` iff a content node was captured
    bool includeChildren;     /// `#set! injection.include-children`
}

/**
Reads one match of the injections query into an $(LREF InjectionMatch).

The language is the text of the `@injection.language` capture if present,
otherwise the pattern's `#set! injection.language "…"` value (a captured node
beats the directive — the reference rule). `injection.include-children` is read
from the directives. `injection.combined`/`injection.self`/`injection.parent`
are not handled (deferred).
*/
InjectionMatch injectionForMatch(ref const TsHighlightConfig config,
    in TSQueryMatch match, scope const(char)[] source) @system
{
    InjectionMatch result;

    foreach (i; 0 .. match.capture_count)
    {
        const cap = match.captures[i];
        // ImportC keeps TSNode const here; strip it as the engine does elsewhere
        // (TSNode is a non-owning handle — highlighter.d:244).
        auto node = cast(TSNode) cap.node;
        if (cap.index == config.injectionLanguageIndex)
        {
            const s = nodeStartByte(node);
            const e = nodeEndByte(node);
            if (s <= e && e <= source.length)
                result.language = source[s .. e];
        }
        else if (cap.index == config.injectionContentIndex)
        {
            result.contentNode = node;
            result.hasContent = true;
        }
    }

    if (match.pattern_index < config.injectionPredicates.length)
        foreach (setting; config.injectionPredicates[match.pattern_index].settings)
        {
            if (setting.key == "injection.language" && result.language.length == 0)
                result.language = setting.value;
            else if (setting.key == "injection.include-children")
                result.includeChildren = true;
        }

    return result;
}

/**
The `TSRange`s an injected parser is restricted to for `contentNode`.

With `includeChildren`, the whole node is one range. Otherwise the ranges are
the gaps between the node's $(I named) children — the "own text only" case
(e.g. the literal chunks of a template string around its `${…}` interpolations).
Every candidate is clipped to `parentRanges` so a child never covers bytes the
parent didn't; an empty `parentRanges` means the root layer (whole buffer), so
candidates pass through unclipped. Point coordinates come straight from the
nodes.

$(B Deviation from the reference:) the reference excludes $(I all) children
(named and anonymous), relying on the injection query to set
`injection.include-children` whenever the whole node is wanted — as Helix's
markdown query does for `(inline)`. Excluding only $(I named) children instead
makes injection work with queries that omit the directive (the bundled
nvim-treesitter markdown query does): anonymous token children — an escape's
`\`/`*`, a code span's backticks — stay part of the injected text, while
genuine sub-structure (a `template_substitution`) is still excluded. A query
that does set `include-children` still gets the whole node.
*/
TSRange[] intersectRanges(scope const(TSRange)[] parentRanges, TSNode contentNode,
    bool includeChildren) @system
{
    import std.algorithm.comparison : max, min;

    TSRange[] candidates;
    if (includeChildren)
        candidates ~= nodeRange(contentNode);
    else
    {
        const nr = nodeRange(contentNode);
        uint cursorByte = nr.start_byte;
        TSPoint cursorPoint = nr.start_point;
        foreach (ci; 0 .. nodeNamedChildCount(contentNode))
        {
            const cr = nodeRange(nodeNamedChild(contentNode, ci));
            if (cr.start_byte > cursorByte)
                candidates ~= mkRange(cursorByte, cursorPoint, cr.start_byte, cr.start_point);
            cursorByte = cr.end_byte;
            cursorPoint = cr.end_point;
        }
        if (nr.end_byte > cursorByte)
            candidates ~= mkRange(cursorByte, cursorPoint, nr.end_byte, nr.end_point);
    }

    if (parentRanges.length == 0)
        return candidates;

    TSRange[] result;
    foreach (cand; candidates)
        foreach (par; parentRanges)
        {
            const sb = max(cand.start_byte, par.start_byte);
            const eb = min(cand.end_byte, par.end_byte);
            if (sb < eb)
                result ~= mkRange(
                    sb, sb == cand.start_byte ? cand.start_point : par.start_point,
                    eb, eb == cand.end_byte ? cand.end_point : par.end_point);
        }
    return result;
}

private TSRange mkRange(uint startByte, TSPoint startPoint, uint endByte, TSPoint endPoint)
    @safe pure nothrow @nogc
{
    TSRange r;
    r.start_point = startPoint;
    r.end_point = endPoint;
    r.start_byte = startByte;
    r.end_byte = endByte;
    return r;
}

/**
Maps a language name to a configured $(REF TsHighlightConfig,
sparkles,syntax,ts,config) — the injection callback the layered highlighter
consults to parse embedded languages.

Owns the configs it builds (they are non-copyable and referenced by the
highlighter's cursors, so they are heap-allocated and kept alive for the
cache's lifetime). `resolve` caches misses too, so a language whose grammar or
queries are absent is looked up once and then renders as plain text (totality).
The backing $(REF GrammarRegistry, sparkles,syntax,ts,registry) is borrowed by
pointer and must outlive the cache.
*/
struct TsConfigCache
{
    private GrammarRegistry* _registry;
    private LabelSet _labels;
    private TsHighlightConfig*[string] _cache;

    @disable this(this);

    /// Builds a cache over `registry` (borrowed) resolving labels through
    /// `labels`.
    static TsConfigCache create(return GrammarRegistry* registry, LabelSet labels) @safe pure nothrow
    in (registry !is null)
    {
        TsConfigCache cache;
        cache._registry = registry;
        cache._labels = labels;
        return cache;
    }

    /**
    The configured config for `language` (canonicalized), or `null` on any miss
    — missing grammar, missing highlights query, or a query that failed to
    compile. Cached by canonical name, misses included.
    */
    const(TsHighlightConfig)* resolve(const(char)[] language) @system
    {
        const canon = canonicalLanguage(language);
        if (auto cached = canon in _cache)
            return *cached;

        TsHighlightConfig* built = null;
        auto grammar = _registry.grammar(canon);
        if (!grammar.hasError)
        {
            auto highlights = _registry.queryText(canon, "highlights");
            if (!highlights.hasError)
            {
                string injectionsScm = null;
                auto injections = _registry.queryText(canon, "injections");
                if (!injections.hasError)
                    injectionsScm = injections.value;

                TsError error;
                auto cfg = new TsHighlightConfig;
                *cfg = TsHighlightConfig.create(grammar.value, highlights.value,
                    error, injectionsScm);
                if (!error && cfg.valid)
                {
                    cfg.configure(_labels);
                    built = cfg;
                }
            }
        }

        _cache[canon.idup] = built;
        return built;
    }
}

@("ts.injection.configCache")
@system
unittest
{
    import std.process : environment;
    import sparkles.test_runner.skip : skipTest;

    if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    auto registry = GrammarRegistry.fromEnvironment();
    auto cache = TsConfigCache.create(&registry, LabelSet.standard());

    // markdown ships an injections.scm → resolvable, with injections wired.
    auto md = cache.resolve("markdown");
    assert(md !is null);
    assert(md.hasInjections);
    assert(md.injectionContentIndex != uint.max);

    // json ships no injections.scm → resolvable, but injects nothing.
    auto js = cache.resolve("json");
    assert(js !is null);
    assert(!js.hasInjections);

    // unknown language → null, and the miss is cached (stable across calls).
    assert(cache.resolve("no-such-lang-xyz") is null);
    assert(cache.resolve("no-such-lang-xyz") is null);

    // hits are cached: same pointer back for the same language.
    assert(cache.resolve("markdown") is md);

    // the underscore alias resolves to the markdown-inline grammar.
    assert(cache.resolve("markdown_inline") !is null);
}
