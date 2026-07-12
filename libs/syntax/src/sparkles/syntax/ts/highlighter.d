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

$(LREF highlightInjected) adds embedded languages (M7): it discovers
injections per layer, parses each over its byte ranges, and folds all layers
into one position-ordered stream (the reference layer stack). `highlight`
stays the single-language entry point.

Still deferred: `injection.combined`, locals scope-tracking, and UTF-16 sources.
*/
module sparkles.syntax.ts.highlighter;

import core.lifetime : move;
import core.time : Duration, msecs;
import std.range.primitives : put;

import sparkles.base.smallbuffer : SmallBuffer;

import sparkles.syntax.event : HighlightEvent, LabelId;
import sparkles.syntax.ts.config : TsHighlightConfig;
import sparkles.syntax.ts.injection : injectionForMatch, intersectRanges, TsConfigCache;
import sparkles.syntax.ts.predicates : satisfies;
import sparkles.tree_sitter.errors : TsError, TsErrorCode, TsExpected, tsErr, tsOk;
import sparkles.tree_sitter.tree_sitter_c : TSNode, TSQueryMatch, TSRange,
    ts_node_end_byte, ts_node_start_byte;
import sparkles.tree_sitter.wrappers : CancelCtx, nodeEndByte, nodeStartByte,
    ParseGuards, TsParser, TsQueryCursor, TsTree;

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

// ── Injection layers (M7) ───────────────────────────────────────────────────

/// Hard cap on injection nesting — the reference has none (it relies on ranges
/// strictly shrinking), but a self-injection over a node's full range could
/// recurse unbounded, so we bound depth defensively.
private enum size_t maxInjectionDepth = 8;

/// One parsed language over a set of byte ranges, plus its interleave cursor
/// state. Heap-allocated (owns non-copyable `TsTree`/`TsQueryCursor`); freed by
/// the GC finalizer at end of run.
private struct Layer
{
    TsTree tree;                         /// this layer's parse (kept alive for its cursor)
    TsQueryCursor cursor;                /// the highlights capture stream
    const(TsHighlightConfig)* config;    /// the language config
    size_t depth;                        /// injection nesting depth (root = 0)
    const(TSRange)[] ranges;             /// included ranges (empty = whole buffer)
    SmallBuffer!(size_t, 16) endStack;   /// pending highlight-end byte offsets (LIFO)
    bool havePeeked;                     /// `peeked` holds the next highlights capture
    LayerCapture peeked;                 /// predicate-filtered lookahead

    @disable this(this);
}

/// A highlights capture copied out of cursor storage (same discipline as the
/// single-layer loop).
private struct LayerCapture
{
    uint matchId;
    uint captureId;
    TSNode node;
    size_t start, end;
}

/**
Injection-aware batch highlighting: parses `rootLanguage`, discovers embedded
languages via each layer's injections query, parses those over their byte
ranges, and folds all layers' captures into one $(REF HighlightEvent,
sparkles,syntax,event) stream ordered by position — the reference crate's
layer-stack model (non-combined injections; combined + locals deferred).

`cache` resolves every language (root and injected) to a configured
$(REF TsHighlightConfig, sparkles,syntax,ts,config) and owns the results.
Totality holds: an injection whose grammar/queries are missing renders as plain
text; only a size-guard trip or a failed $(I root) parse returns an error.
*/
TsExpected!void highlightInjected(Sink)(
    ref TsConfigCache cache,
    const(char)[] rootLanguage,
    scope const(char)[] source,
    ref Sink sink,
    HighlightOptions options = HighlightOptions()) @system
{
    if (source.length > options.maxSourceBytes || source.length > cast(size_t) int.max)
        return tsErr!void(TsErrorCode.sourceTooLarge);

    auto rootConfig = cache.resolve(rootLanguage);
    if (rootConfig is null)
        return tsErr!void(TsErrorCode.grammarNotFound);

    Layer*[] layers;
    auto built = buildLayers(cache, rootConfig, source, options, layers);
    if (built.hasError)
        return tsErr!void(built.error);

    return interleaveLayers(layers, source, sink, options);
}

/// BFS layer construction: parse each layer, run its injections query, resolve
/// and enqueue child layers. A failed $(I root) parse errors; a failed child
/// parse (or unresolved injection) is skipped — that range stays plain text.
private TsExpected!void buildLayers(
    ref TsConfigCache cache, const(TsHighlightConfig)* rootConfig,
    scope const(char)[] source, in HighlightOptions options, out Layer*[] layers) @system
{
    static struct Work
    {
        const(TsHighlightConfig)* config;
        TSRange[] ranges;
        size_t depth;
    }

    Work[] queue = [Work(rootConfig, null, 0)];
    for (size_t qi = 0; qi < queue.length; ++qi)
    {
        auto w = queue[qi];

        auto parser = TsParser.create();
        auto langSet = parser.setLanguage(w.config.grammar.language);
        if (langSet.hasError)
        {
            if (w.depth == 0)
                return tsErr!void(langSet.error);
            continue;
        }
        if (w.ranges.length)
            parser.setIncludedRanges(w.ranges);

        TsError parseError;
        auto tree = parser.parse(source, parseError,
            ParseGuards(budget: options.parseBudget, cancelFlag: options.cancelFlag));
        if (!tree.valid)
        {
            if (w.depth == 0)
                return tsErr!void(parseError);
            continue;
        }

        auto layer = new Layer;
        layer.config = w.config;
        layer.depth = w.depth;
        layer.ranges = w.ranges;
        move(tree, layer.tree);
        layer.cursor = TsQueryCursor.create();
        layer.cursor.setMatchLimit(options.matchLimit);
        layer.cursor.exec(w.config.query, layer.tree.rootNode);
        layers ~= layer;

        // Discover this layer's injections (unless it injects nothing / too deep).
        if (!w.config.hasInjections || w.depth + 1 > maxInjectionDepth)
            continue;

        auto injCursor = TsQueryCursor.create();
        injCursor.setMatchLimit(options.matchLimit);
        injCursor.exec(w.config.injectionQuery, layer.tree.rootNode);

        TSQueryMatch m;
        while (injCursor.nextMatch(m))
        {
            if (m.pattern_index < w.config.injectionPredicates.length
                && !satisfies(w.config.injectionPredicates[m.pattern_index], m, source))
                continue;

            auto inj = injectionForMatch(*w.config, m, source);
            if (!inj.hasContent || inj.language.length == 0)
                continue;

            auto childConfig = cache.resolve(inj.language);
            if (childConfig is null)
                continue; // grammar/queries missing → plain text

            auto childRanges = intersectRanges(w.ranges, inj.contentNode, inj.includeChildren);
            if (childRanges.length == 0)
                continue;

            queue ~= Work(childConfig, childRanges, w.depth + 1);
        }
    }

    return tsOk();
}

/// Predicate-filtered lookahead for one layer's highlights cursor (the
/// single-layer `peek`, per layer).
private bool peekLayer(Layer* layer, scope const(char)[] source) @system
{
    while (!layer.havePeeked)
    {
        TSQueryMatch match;
        uint captureIndex;
        if (!layer.cursor.nextCapture(match, captureIndex))
            return false;
        if (match.pattern_index < layer.config.predicates.length
            && !satisfies(layer.config.predicates[match.pattern_index], match, source))
        {
            layer.cursor.removeMatch(match.id);
            continue;
        }
        auto node = cast(TSNode) match.captures[captureIndex].node;
        layer.peeked = LayerCapture(match.id, match.captures[captureIndex].index,
            node, nodeStartByte(node), nodeEndByte(node));
        layer.havePeeked = true;
    }
    return true;
}

/// The layer's next boundary: `min(next capture start, top pending end)`, ends
/// before starts at a tie. Returns `false` when the layer is exhausted.
private bool layerBoundary(Layer* layer, scope const(char)[] source,
    out size_t pos, out bool isStart) @system
{
    const hasCapture = peekLayer(layer, source);
    const hasEnd = layer.endStack.length != 0;
    if (!hasCapture && !hasEnd)
        return false;

    const nextStart = hasCapture ? layer.peeked.start : size_t.max;
    const nextEnd = hasEnd ? layer.endStack[layer.endStack.length - 1] : size_t.max;
    if (nextEnd <= nextStart)
    {
        pos = nextEnd;
        isStart = false;
    }
    else
    {
        pos = nextStart;
        isStart = true;
    }
    return true;
}

/// Folds every layer's boundaries into one event stream: at each step take the
/// globally earliest boundary (ends before starts; deeper layers first at a
/// tie), fill the `source` gap up to it, and emit the push/pop. Identical
/// `[start,end)` ranges are emitted once, by the deepest layer (the reference's
/// cross-layer dedup).
private TsExpected!void interleaveLayers(Sink)(
    Layer*[] layers, scope const(char)[] source, ref Sink sink, in HighlightOptions options) @system
{
    auto ctx = CancelCtx.from(options.queryBudget, options.cancelFlag);

    size_t byteOffset = 0;
    size_t lastStart = size_t.max, lastEnd = size_t.max, lastDepth = size_t.max;
    size_t iterations = 0;

    void emitSourceUpTo(size_t offset)
    {
        const clamped = offset < source.length ? offset : source.length;
        if (byteOffset < clamped)
        {
            put(sink, HighlightEvent.sourceSpan(byteOffset, clamped));
            byteOffset = clamped;
        }
    }

    for (;;)
    {
        if (++iterations % cancellationCheckInterval == 0 && ctx.armed && ctx.shouldCancel())
            return tsErr!void(ctx.toError(TsErrorCode.highlightTimeout,
                TsErrorCode.highlightCancelled));

        // Globally earliest boundary: (pos, ends-before-starts, deeper-first).
        Layer* best;
        size_t bestPos;
        bool bestStart;
        foreach (layer; layers)
        {
            size_t pos;
            bool isStart;
            if (!layerBoundary(layer, source, pos, isStart))
                continue;
            const better = best is null
                || pos < bestPos
                || (pos == bestPos && !isStart && bestStart)
                || (pos == bestPos && isStart == bestStart && layer.depth > best.depth);
            if (better)
            {
                best = layer;
                bestPos = pos;
                bestStart = isStart;
            }
        }
        if (best is null)
            break;

        emitSourceUpTo(bestPos);

        if (!bestStart)
        {
            put(sink, HighlightEvent.popLabel());
            best.endStack.popBack();
            continue;
        }

        auto current = best.peeked;
        best.havePeeked = false;
        if (current.end <= byteOffset)
            continue; // stale (overlapping non-nested capture); skip defensively

        // same-node last-wins within the layer (the reference rule)
        while (peekLayer(best, source))
        {
            if (best.peeked.node.id !is current.node.id)
                break;
            best.cursor.removeMatch(current.matchId);
            current = best.peeked;
            best.havePeeked = false;
        }

        // cross-layer identical-range dedup: deeper layer already emitted it
        if (current.start == lastStart && current.end == lastEnd && best.depth < lastDepth)
            continue;

        const label = current.captureId < best.config.captureToLabel.length
            ? best.config.captureToLabel[current.captureId]
            : LabelId.none;
        if (label)
        {
            lastStart = current.start;
            lastEnd = current.end;
            lastDepth = best.depth;
            put(sink, HighlightEvent.pushLabel(label));
            best.endStack ~= current.end;
        }
    }

    // Defensive: drain any unclosed ends (well-formed streams have none left).
    foreach (layer; layers)
        while (layer.endStack.length)
        {
            emitSourceUpTo(layer.endStack[layer.endStack.length - 1]);
            put(sink, HighlightEvent.popLabel());
            layer.endStack.popBack();
        }
    emitSourceUpTo(source.length);
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

version (unittest)
{
    import sparkles.syntax.ts.injection : TsConfigCache;

    /// Runs the layered path and returns the event stream (bundle-gated).
    package HighlightEvent[] injectedEventsForTest(string rootLanguage, string source) @system
    {
        import std.array : appender;
        import std.process : environment;
        import sparkles.test_runner.skip : skipTest;

        if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
            skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

        static GrammarRegistry registry;
        registry = GrammarRegistry.fromEnvironment();
        auto cache = TsConfigCache.create(&registry, LabelSet.standard());
        auto sink = appender!(HighlightEvent[]);
        auto result = highlightInjected(cache, rootLanguage, source, sink);
        assert(!result.hasError);
        return sink[];
    }
}

@("ts.highlighter.injectionAgreesWithSingleLayer")
@system
unittest
{
    // A language with no injections must yield the identical stream through the
    // layered path and the single-layer path — the regression guard that the
    // multi-layer loop degenerates exactly to the proven single-layer one.
    const source = `{"outer": {"inner": [1, true, null], "b": "x"}}`;
    auto config = jsonConfigForTest();
    auto single = eventsForTest(config, source);

    auto layered = injectedEventsForTest("json", source);
    assert(layered == single, "layered stream diverges from single-layer for json");
}

@("ts.highlighter.markdownFencedCode")
@system
unittest
{
    import std.algorithm.searching : canFind, endsWith;

    // A fenced D block inside markdown: the D grammar must highlight the fence
    // body (markdown treats `code_fence_content` as opaque, so any label on
    // `void`/`main` can only come from the injected D layer).
    const source = "# Title\n\n```d\nvoid main() {}\n```\n";
    auto events = injectedEventsForTest("markdown", source);
    assertWellFormed(events, source);

    const spans = labeledSpans(events, source);
    assert(spans.canFind!(s => s.endsWith(":void")),
        spans.length ? spans[0] : "no labeled spans — injection did not fire");
}

@("ts.highlighter.markdownInlineSelfInjection")
@system
unittest
{
    import std.algorithm.searching : canFind;

    // markdown injects its `(inline)` content into markdown_inline. A backslash
    // escape is inline-only and markdown_inline labels it `@string.escape`
    // (which resolves in our vocabulary — unlike its neovim-style
    // `@text.strong`), so the label proves the self-injection recursed.
    const source = "a paragraph with an escape \\* here\n";
    auto events = injectedEventsForTest("markdown", source);
    assertWellFormed(events, source);

    const spans = labeledSpans(events, source);
    assert(spans.canFind!(s => s.canFind("string.escape")),
        spans.length ? spans[0] : "no string.escape — inline injection did not fire");
}

@("ts.highlighter.markdownStaticSetLanguage")
@system
unittest
{
    import std.algorithm.searching : canFind;

    // An HTML block routes through `#set! injection.language "html"` (no
    // captured @injection.language node) — exercises the directive path.
    const source = "<div class=\"x\">hi</div>\n";
    auto events = injectedEventsForTest("markdown", source);
    assertWellFormed(events, source);

    const spans = labeledSpans(events, source);
    assert(spans.canFind!(s => s.canFind("tag")),
        spans.length ? spans[0] : "no tag label — html injection did not fire");
}

@("ts.highlighter.injectionRecursionIsBounded")
@system
unittest
{
    // A fenced markdown block injects markdown into markdown — recursion that
    // the depth cap must terminate. Well-formedness proves no crash/runaway.
    const source = "````markdown\n# Inner **b**\n````\n";
    auto events = injectedEventsForTest("markdown", source);
    assertWellFormed(events, source);
}
