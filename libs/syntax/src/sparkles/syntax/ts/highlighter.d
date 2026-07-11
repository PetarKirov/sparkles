/**
The precise-mode highlighter: query captures → the highlight-event stream.

$(LREF highlight) parses a whole buffer with the configured grammar, runs
the highlights query over the tree, and pushes
$(REF HighlightEvent, sparkles,syntax,event)s into any output-range sink —
a single-layer port of the reference `tree-sitter-highlight` event loop:

$(LIST
    * captures arrive in position order from one query cursor, filtered by
        the pattern's text predicates (rejected matches are removed);
    * at equal offsets, open highlights close before new ones open
        (`ends-before-starts` — the nesting discipline);
    * when several patterns capture the $(B same node), the last one wins
        (the reference rule; captures per node arrive by pattern index);
    * unresolved captures (no `LabelId`) emit nothing;
    * cancellation/budget is checked every 100 events (the reference's
        `CANCELLATION_CHECK_INTERVAL`) plus inside the C query execution via
        its progress callback.
)

The internal `parse` → $(LREF highlightTree) split is the incremental seam:
an interactive consumer keeps the `TsTree` alive, edits + re-parses it, and
calls `highlightTree` per viewport. v1 is batch.

What v1 deliberately skips: injection layers (`injections.scm` — the next
milestone; markdown-inline etc.), locals, and UTF-16 sources.
*/
module sparkles.syntax.ts.highlighter;

import core.time : Duration, msecs;
import std.range.primitives : put;

import sparkles.base.smallbuffer : SmallBuffer;

import sparkles.syntax.event : HighlightEvent, LabelId;
import sparkles.syntax.ts.config : TsHighlightConfig;
import sparkles.syntax.ts.predicates : satisfies;
import sparkles.tree_sitter.errors : TsError, TsErrorCode, TsExpected, tsErr, tsOk;
import sparkles.tree_sitter.tree_sitter_c : TSNode, TSQueryMatch,
    ts_node_end_byte, ts_node_start_byte;
import sparkles.tree_sitter.wrappers : CancelCtx, ParseGuards, TsParser,
    TsQueryCursor, TsTree;

/// The reference crate's cancellation-check cadence.
private enum size_t cancellationCheckInterval = 100;

/// Guards and knobs for one highlight run (named-argument defaults; every
/// bound has a recorded rationale in `docs/specs/syntax/`).
struct HighlightOptions
{
    /// Refuse larger inputs. 512 MiB is Helix's cap; a 2 GiB ceiling is
    /// structural regardless (32-bit indices).
    size_t maxSourceBytes = 512UL << 20;

    /// Wall-clock parse budget (progress-callback cancellation).
    /// `Duration.zero` = unlimited.
    Duration parseBudget = 500.msecs;

    /// Query-cursor match limit (Helix's tuned 256; Neovim's 64 breaks
    /// Erlang). Exceeding it silently drops the earliest in-progress match —
    /// surfaced via `matchLimitExceeded`, not an error.
    uint matchLimit = 256;

    /// Wall-clock budget for query execution + event assembly.
    /// `Duration.zero` = unlimited.
    Duration queryBudget;

    /// Host cancellation flag, polled by every guard above.
    const(shared(bool))* cancelFlag = null;

    /// When non-null, set to `true` if the cursor exceeded `matchLimit`.
    bool* matchLimitExceeded = null;
}

/**
Batch entry point: guards → parse → $(LREF highlightTree). `sink` is any
output range of `HighlightEvent`. The event stream is only written on
success (`tsOk`); on any error the sink is untouched or partially written —
callers render the plain source instead (totality lives in the caller's
fallback, not in half-colored output).
*/
TsExpected!void highlight(Sink)(
    ref const TsHighlightConfig config,
    scope const(char)[] source,
    ref Sink sink,
    HighlightOptions options = HighlightOptions())
in (config.configured, "TsHighlightConfig.configure must run before highlight")
{
    if (source.length > options.maxSourceBytes || source.length > cast(size_t) int.max)
        return tsErr!void(TsErrorCode.sourceTooLarge);

    auto parser = TsParser.create();
    auto languageSet = parser.setLanguage(config.grammar.language);
    if (languageSet.hasError)
        return tsErr!void(languageSet.error);

    TsError parseError;
    auto tree = parser.parse(source, parseError,
        ParseGuards(budget: options.parseBudget, cancelFlag: options.cancelFlag));
    if (!tree.valid)
        return tsErr!void(parseError);

    return highlightTree(config, tree, source, sink, options);
}

/// The tree-consuming half (see the module header for the loop semantics).
TsExpected!void highlightTree(Sink)(
    ref const TsHighlightConfig config,
    ref const TsTree tree,
    scope const(char)[] source,
    ref Sink sink,
    HighlightOptions options = HighlightOptions())
in (config.configured, "TsHighlightConfig.configure must run before highlight")
in (tree.valid, "highlightTree needs a valid tree")
{
    auto cursor = TsQueryCursor.create();
    cursor.setMatchLimit(options.matchLimit);

    auto ctx = CancelCtx.from(options.queryBudget, options.cancelFlag);
    if (ctx.armed)
        cursor.execWithCancellation(config.query, tree.rootNode, ctx);
    else
        cursor.exec(config.query, tree.rootNode);

    size_t byteOffset = 0;
    SmallBuffer!(size_t, 64) endStack;
    size_t iterations = 0;

    // Everything a capture contributes, copied out eagerly: TSQueryMatch's
    // `captures` pointer aliases cursor-internal storage that the next
    // `ts_query_cursor_next_capture` call invalidates.
    static struct PendingCapture
    {
        uint matchId;
        uint captureId; // capture-name id → captureToLabel index
        TSNode node;
        size_t start, end;
    }

    bool havePeeked = false;
    PendingCapture peeked;

    // Predicate-filtered lookahead; rejected matches leave the cursor.
    bool peek()
    {
        while (!havePeeked)
        {
            TSQueryMatch match;
            uint captureIndex;
            if (!cursor.nextCapture(match, captureIndex))
                return false;
            if (match.pattern_index < config.predicates.length
                && !satisfies(config.predicates[match.pattern_index], match, source))
            {
                cursor.removeMatch(match.id);
                continue;
            }
            auto node = captureNode(match, captureIndex);
            peeked = PendingCapture(match.id, captureIdOf(match, captureIndex),
                node, cast(size_t) nodeStart(node), cast(size_t) nodeEnd(node));
            havePeeked = true;
        }
        return true;
    }

    void emitSourceUpTo(size_t offset)
    {
        if (byteOffset < offset)
        {
            put(sink, HighlightEvent.sourceSpan(byteOffset, offset));
            byteOffset = offset;
        }
    }

    for (;;)
    {
        if (++iterations % cancellationCheckInterval == 0 && ctx.armed && ctx.shouldCancel())
            return tsErr!void(ctx.toError(TsErrorCode.highlightTimeout,
                TsErrorCode.highlightCancelled));

        if (!peek())
            break;

        // ends close before starts open at equal offsets
        if (endStack.length)
        {
            const closeAt = endStack[endStack.length - 1];
            if (closeAt <= peeked.start)
            {
                emitSourceUpTo(closeAt);
                put(sink, HighlightEvent.popLabel());
                endStack.popBack();
                continue;
            }
        }

        auto current = peeked;
        havePeeked = false;

        // stale capture — only possible with overlapping, non-nested
        // captures; skipped defensively (renderers are total)
        if (current.end <= byteOffset)
            continue;

        // same-node last-wins (the reference rule)
        while (peek())
        {
            if (peeked.node.id !is current.node.id)
                break;
            cursor.removeMatch(current.matchId);
            current = peeked;
            havePeeked = false;
        }

        const label = current.captureId < config.captureToLabel.length
            ? config.captureToLabel[current.captureId]
            : LabelId.none;
        if (label)
        {
            emitSourceUpTo(current.start > byteOffset ? current.start : byteOffset);
            put(sink, HighlightEvent.pushLabel(label));
            endStack ~= current.end;
        }
    }

    while (endStack.length)
    {
        emitSourceUpTo(endStack[endStack.length - 1]);
        put(sink, HighlightEvent.popLabel());
        endStack.popBack();
    }
    emitSourceUpTo(source.length);

    if (options.matchLimitExceeded !is null && cursor.didExceedMatchLimit)
        *options.matchLimitExceeded = true;

    return tsOk();
}

private TSNode captureNode(in TSQueryMatch match, uint captureIndex) @trusted pure nothrow @nogc
in (captureIndex < match.capture_count)
{
    return cast(TSNode) match.captures[captureIndex].node;
}

private uint captureIdOf(in TSQueryMatch match, uint captureIndex) @trusted pure nothrow @nogc
in (captureIndex < match.capture_count)
{
    return match.captures[captureIndex].index;
}

private uint nodeStart(TSNode node) @trusted nothrow @nogc
    => ts_node_start_byte(node);

private uint nodeEnd(TSNode node) @trusted nothrow @nogc
    => ts_node_end_byte(node);

version (unittest)
{
    import sparkles.syntax.label : LabelSet;
    import sparkles.syntax.ts.registry : GrammarRegistry;

    /// Builds a configured json highlight config from the test bundle, or
    /// skips the calling test outside the devshell.
    package TsHighlightConfig jsonConfigForTest(string queryOverride = null) @system
    {
        import std.process : environment;
        import sparkles.test_runner.skip : skipTest;

        if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
            skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

        auto registry = GrammarRegistry.fromEnvironment();
        auto grammar = registry.grammar("json");
        assert(!grammar.hasError);

        string queryText = queryOverride;
        if (queryText is null)
        {
            auto highlights = registry.queryText("json");
            assert(!highlights.hasError);
            queryText = highlights.value;
        }

        TsError error;
        auto config = TsHighlightConfig.create(grammar.value, queryText, error);
        assert(!error, queryText);
        const labels = LabelSet.standard();
        config.configure(labels);
        return config;
    }

    /// Collects the event stream for `source` under `config`.
    package HighlightEvent[] eventsForTest(ref const TsHighlightConfig config,
        string source, HighlightOptions options = HighlightOptions()) @system
    {
        import std.array : appender;

        auto sink = appender!(HighlightEvent[]);
        auto result = highlight(config, source, sink, options);
        assert(!result.hasError);
        return sink[];
    }

    /// The labeled span texts of an event stream, as "label:text" strings.
    package string[] labeledSpans(const(HighlightEvent)[] events, string source) @safe
    {
        import std.array : appender;
        import sparkles.syntax.event : byStyledSpan;

        auto result = appender!(string[]);
        const labels = LabelSet.standard();
        foreach (span; byStyledSpan(events))
            if (span.label)
                result ~= labels.name(span.label).idup ~ ":" ~ source[span.start .. span.end];
        return result[];
    }

    /// Structural invariants every event stream must satisfy.
    package void assertWellFormed(const(HighlightEvent)[] events, string source) @safe
    {
        size_t depth = 0;
        size_t offset = 0;
        foreach (ev; events)
        {
            final switch (ev.kind)
            {
                case HighlightEvent.Kind.source:
                    assert(ev.start == offset, "source spans must be contiguous in coverage order");
                    assert(ev.start <= ev.end && ev.end <= source.length);
                    offset = ev.end;
                    break;
                case HighlightEvent.Kind.push:
                    assert(ev.label, "push must carry a label");
                    ++depth;
                    break;
                case HighlightEvent.Kind.pop:
                    assert(depth > 0, "unbalanced pop");
                    --depth;
                    break;
            }
        }
        assert(depth == 0, "unbalanced push at end of stream");
        assert(offset == source.length, "source not fully covered");
    }
}

@("ts.highlighter.jsonEndToEnd")
@system
unittest
{
    auto config = jsonConfigForTest();
    const source = `{"a": [1, true]}`;
    auto events = eventsForTest(config, source);
    assertWellFormed(events, source);

    const spans = labeledSpans(events, source);
    // Bundled json highlights: numbers and constants are unambiguous.
    import std.algorithm.searching : canFind;

    assert(spans.canFind("number:1"), spans.length ? spans[0] : "no spans");
    assert(spans.canFind("constant.builtin:true"));
}

@("ts.highlighter.predicateFiltering")
@system
unittest
{
    // #eq? keeps only the matching string node; the other one emits nothing.
    auto config = jsonConfigForTest(`((string) @string (#eq? @string "\"a\""))`);
    const source = `{"a": "b"}`;
    auto events = eventsForTest(config, source);
    assertWellFormed(events, source);

    const spans = labeledSpans(events, source);
    assert(spans == [`string:"a"`], spans.length ? spans[0] : "no spans");
}

@("ts.highlighter.matchPredicate")
@system
unittest
{
    // #match? via std.regex
    auto config = jsonConfigForTest(`((number) @number (#match? @number "^4"))`);
    const source = `[42, 17, 43]`;
    auto events = eventsForTest(config, source);
    assertWellFormed(events, source);
    assert(labeledSpans(events, source) == ["number:42", "number:43"]);
}

@("ts.highlighter.anyOfPredicate")
@system
unittest
{
    auto config = jsonConfigForTest(
        `((number) @number (#any-of? @number "1" "3"))`);
    const source = `[1, 2, 3]`;
    auto events = eventsForTest(config, source);
    assert(labeledSpans(events, source) == ["number:1", "number:3"]);
}

@("ts.highlighter.unsupportedPredicateDegrades")
@system
unittest
{
    // Editor-dialect predicate: the pattern is disabled with a warning; the
    // remaining patterns still highlight.
    auto config = jsonConfigForTest(
        "((string) @string (#lua-match? @string \"x\"))\n(number) @number");
    assert(config.warnings.length == 1);

    const source = `["s", 1]`;
    auto events = eventsForTest(config, source);
    assert(labeledSpans(events, source) == ["number:1"]);
}

@("ts.highlighter.invalidRegexDegrades")
@system
unittest
{
    auto config = jsonConfigForTest(
        "((string) @string (#match? @string \"[\"))\n(number) @number");
    assert(config.warnings.length == 1);

    const source = `["s", 1]`;
    auto events = eventsForTest(config, source);
    assert(labeledSpans(events, source) == ["number:1"]);
}

@("ts.highlighter.nestingIsWellFormed")
@system
unittest
{
    // Nested captures (array inside pair value inside document) must produce
    // balanced, contiguous events on a nontrivial fixture.
    auto config = jsonConfigForTest();
    const source = `{"outer": {"inner": [1, [2, {"deep": null}]], "b": "x"}}`;
    auto events = eventsForTest(config, source);
    assertWellFormed(events, source);
}

@("ts.highlighter.unresolvedCapturesEmitNothing")
@system
unittest
{
    // @nonstandard.capture.name resolves to no label → zero labeled spans.
    auto config = jsonConfigForTest(`(number) @zzz.not.a.label`);
    const source = `[1]`;
    auto events = eventsForTest(config, source);
    assertWellFormed(events, source);
    assert(labeledSpans(events, source).length == 0);
}

@("ts.highlighter.renderedEndToEnd")
@system
unittest
{
    import std.algorithm.searching : canFind;
    import std.array : appender;
    import sparkles.syntax.render.html : HtmlMode, HtmlOptions, renderHtml;
    import sparkles.syntax.theme : resolveTheme;
    import sparkles.syntax.themes : builtinDark;

    auto config = jsonConfigForTest();
    const source = `[1, true]`;
    auto events = eventsForTest(config, source);

    const resolved = resolveTheme(builtinDark, LabelSet.standard());
    auto html = appender!string;
    renderHtml(source, events, resolved, html,
        HtmlOptions(mode: HtmlMode.cssClasses));
    assert(html[].canFind(`<span class="syn-number">1</span>`), html[]);
    assert(html[].canFind(`<span class="syn-constant-builtin">true</span>`), html[]);
}

@("ts.highlighter.sourceTooLarge")
@system
unittest
{
    auto config = jsonConfigForTest();
    const(char)[] fake = (cast(const(char)*) null)[0 .. 600UL << 20];
    import std.array : appender;

    auto sink = appender!(HighlightEvent[]);
    auto result = highlight(config, fake, sink);
    assert(result.hasError);
    assert(result.error.code == TsErrorCode.sourceTooLarge);
    assert(sink[].length == 0);
}
