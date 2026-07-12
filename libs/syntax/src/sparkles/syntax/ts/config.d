/**
The per-language highlight configuration: a compiled query plus the
capture → label mapping.

Built once per (grammar, query, vocabulary) and reused for every buffer —
the reference crate's `HighlightConfiguration` shape. `create` compiles the
`highlights.scm` text and parses predicates (unsupported dialect predicates
disable their one pattern with a warning — degrade, never fail the
language); `configure` resolves every capture name through the core's
longest-dot-prefix `LabelSet.resolve`, so engine output speaks `LabelId`s.

`injectionsScm` (M7) compiles a second query used to discover embedded
languages (`@injection.content`/`@injection.language` + `#set!` directives);
`localsScm` stays a recorded seam (locals scope-tracking is deferred). Unlike
the reference — which concatenates injections → locals → highlights into one
query — the highlights and injections queries are kept separate here (batch
discovery runs the injections query up front, so a merged stream is unnecessary).
*/
module sparkles.syntax.ts.config;

import sparkles.syntax.event : LabelId;
import sparkles.syntax.ts.predicates : ParsedPattern, PatternPredicates,
    parsePatternPredicates;
import sparkles.tree_sitter.errors : TsError, TsErrorCode;
import sparkles.tree_sitter.loader : Grammar;
import sparkles.tree_sitter.wrappers : TsQuery;

/// See the module header. Non-copyable (owns the compiled query); pass by
/// `ref`.
struct TsHighlightConfig
{
    package Grammar grammar;                /// the language this highlights
    package TsQuery query;                  /// the compiled highlights query
    package LabelId[] captureToLabel;       /// capture id → label id (after `configure`)
    package PatternPredicates[] predicates; /// per pattern index
    string[] warnings;                      /// disabled-pattern diagnostics

    // Injections (M7). `injectionQuery` is invalid when the language ships no
    // `injections.scm` (or it failed to compile — a warning, never a hard fail:
    // the language still highlights, it just injects nothing).
    package TsQuery injectionQuery;                  /// the compiled injections query (may be invalid)
    package PatternPredicates[] injectionPredicates; /// per injection pattern (for `#set!` reads)
    package uint injectionContentIndex = uint.max;   /// `@injection.content` capture id (or `uint.max`)
    package uint injectionLanguageIndex = uint.max;  /// `@injection.language` capture id (or `uint.max`)

    @disable this(this);

    /**
    Compiles `highlightsScm` for `grammar`. On failure returns an invalid
    config with `error` set (query compile errors carry the byte offset);
    per-pattern predicate problems never fail creation — they disable the
    pattern and append to `warnings`.
    */
    static TsHighlightConfig create(Grammar grammar, string highlightsScm, out TsError error,
        string injectionsScm = null, string localsScm = null) @safe
    {
        import std.conv : text;

        // Locals scope-tracking stays a recorded seam (deferred — PLAN §4).
        cast(void) localsScm;

        TsHighlightConfig config;
        config.grammar = grammar;
        config.query = TsQuery.create(grammar.language, highlightsScm, error);
        if (!config.query.valid)
            return config;

        const patternCount = config.query.patternCount;
        config.predicates = new PatternPredicates[](patternCount);
        foreach (p; 0 .. patternCount)
        {
            auto parsed = parsePatternPredicates(config.query, p);
            if (parsed.unsupported.length)
            {
                config.query.disablePattern(p);
                config.warnings ~= text("pattern ", p, " disabled: unsupported predicate ",
                    parsed.unsupported);
            }
            config.predicates[p] = parsed.predicates;
        }

        // Injections (M7): compile the language's `injections.scm` when present.
        // A compile failure degrades to "no injections" with a warning — the
        // highlights query is unaffected, so the language still highlights.
        if (injectionsScm.length)
        {
            TsError injError;
            config.injectionQuery = TsQuery.create(grammar.language, injectionsScm, injError);
            if (config.injectionQuery.valid)
            {
                const injPatterns = config.injectionQuery.patternCount;
                config.injectionPredicates = new PatternPredicates[](injPatterns);
                foreach (p; 0 .. injPatterns)
                {
                    auto parsed = parsePatternPredicates(config.injectionQuery, p);
                    if (parsed.unsupported.length)
                    {
                        config.injectionQuery.disablePattern(p);
                        config.warnings ~= text("injection pattern ", p,
                            " disabled: unsupported predicate ", parsed.unsupported);
                    }
                    config.injectionPredicates[p] = parsed.predicates;
                }
                foreach (i; 0 .. config.injectionQuery.captureCount)
                {
                    const name = config.injectionQuery.captureName(i);
                    if (name == "injection.content")
                        config.injectionContentIndex = i;
                    else if (name == "injection.language")
                        config.injectionLanguageIndex = i;
                }
            }
            else
                config.warnings ~= text("injections query failed to compile (offset ",
                    injError.detail, "); no injections for this language");
        }

        error = TsError.init;
        return config;
    }

    /**
    Maps every capture name to a `LabelId` via `labels.resolve` (any type
    with longest-dot-prefix `resolve`; canonically the core `LabelSet`).
    Unresolved captures map to `LabelId.none` and emit nothing. Must run
    before highlighting; re-running with a different vocabulary is allowed.
    */
    void configure(LabelResolver)(ref const LabelResolver labels)
    in (valid, "configure on an invalid TsHighlightConfig")
    {
        const n = query.captureCount;
        auto table = new LabelId[](n);
        foreach (i; 0 .. n)
            table[i] = labels.resolve(query.captureName(i));
        captureToLabel = table;
    }

    /// `true` iff creation succeeded (a compiled query is held).
    bool valid() const scope @safe pure nothrow @nogc
        => query.valid;

    /// `true` iff `configure` ran (labels are mapped).
    bool configured() const scope @safe nothrow @nogc
        => valid && captureToLabel.length == query.captureCount;

    /// `true` iff a usable injections query was compiled (a valid query with an
    /// `@injection.content` capture). The engine skips injection discovery when
    /// this is `false`.
    bool hasInjections() const scope @safe nothrow @nogc
        => injectionQuery.valid && injectionContentIndex != uint.max;
}
