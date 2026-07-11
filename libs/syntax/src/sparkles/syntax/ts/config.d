/**
The per-language highlight configuration: a compiled query plus the
capture → label mapping.

Built once per (grammar, query, vocabulary) and reused for every buffer —
the reference crate's `HighlightConfiguration` shape. `create` compiles the
`highlights.scm` text and parses predicates (unsupported dialect predicates
disable their one pattern with a warning — degrade, never fail the
language); `configure` resolves every capture name through the core's
longest-dot-prefix `LabelSet.resolve`, so engine output speaks `LabelId`s.

The `injectionsScm`/`localsScm` parameters are recorded seams for the
injection milestone (the reference concatenates injections → locals →
highlights into one query and tracks pattern-index boundaries); v1 compiles
the highlights query alone.
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
        // Recorded seams for the injection milestone — see the module header.
        cast(void) injectionsScm;
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
                import std.conv : text;

                config.query.disablePattern(p);
                config.warnings ~= text("pattern ", p, " disabled: unsupported predicate ",
                    parsed.unsupported);
            }
            config.predicates[p] = parsed.predicates;
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
}
