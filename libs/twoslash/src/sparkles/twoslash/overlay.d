/**
The backend-agnostic overlay planner: turns a
$(REF TwoslashReturn, sparkles,twoslash,protocol) into positioned decorations
the HTML, ANSI, and raylib-GUI renderers all consume.

Twoslash nodes decorate a snippet two ways:

$(LIST
    * $(B inline) — a span of a single line gets an in-place treatment: a
        $(D hover) dotted underline + popup, a $(D highlight) box, or an
        $(D error) wavy underline. $(LREF InlineDecoration) captures these.
    * $(B below-line) — a block rendered after the line: an $(D error) message,
        a $(D query) popup, a $(D completion) list, or a `// @tag` line.
        $(LREF BelowBlock) captures these.
)

An $(D error) is both (a wavy span $(I and) a message below). Everything else is
one or the other. $(LREF planTwoslash) partitions the flat node list into the
two sorted work-lists once; each renderer walks them in its own idiom.

The reentrant popup re-highlighter $(LREF highlightSignature) is shared here too
— all three backends re-color a hover/query type signature by calling
`sparkles:syntax` again on it (Shiki does exactly this).
*/
module sparkles.twoslash.overlay;

import sparkles.syntax.event : HighlightEvent;
import sparkles.syntax.ts.injection : TsConfigCache;
import sparkles.syntax.ts.highlighter : highlightInjected, HighlightOptions;

import sparkles.twoslash.protocol : Node, NodeType, TwoslashReturn;

/// The language name the popup re-highlighter resolves in the grammar bundle.
/// Type signatures are TypeScript regardless of the snippet's own dialect.
enum popupLanguage = "typescript";

/// `true` iff `kind` decorates an inline span (hover / highlight / error).
bool hasInlineDecoration(NodeType kind) @safe pure nothrow @nogc
{
    final switch (kind)
    {
        case NodeType.hover:
        case NodeType.highlight:
        case NodeType.error:
            return true;
        case NodeType.query:
        case NodeType.completion:
        case NodeType.tag:
            return false;
    }
}

/// `true` iff `kind` renders a block below its line (error / query /
/// completion / tag).
bool hasBelowBlock(NodeType kind) @safe pure nothrow @nogc
{
    final switch (kind)
    {
        case NodeType.error:
        case NodeType.query:
        case NodeType.completion:
        case NodeType.tag:
            return true;
        case NodeType.hover:
        case NodeType.highlight:
            return false;
    }
}

/// An in-place decoration over `code[start .. end]`, all on line `line`.
struct InlineDecoration
{
    size_t start;     /// byte offset into `code`
    size_t end;       /// exclusive byte offset
    size_t line;      /// 0-based line
    size_t character; /// 0-based start column
    NodeType kind;    /// hover | highlight | error
    size_t node;      /// index into `TwoslashReturn.nodes`
}

/// A block rendered after line `line`, from node `node`.
struct BelowBlock
{
    size_t line;   /// 0-based line the block follows
    NodeType kind; /// error | query | completion | tag
    size_t node;   /// index into `TwoslashReturn.nodes`
}

/**
The partitioned overlay: inline decorations (sorted by `start` ascending, then
`end` descending so an enclosing span opens before an enclosed one) and
below-line blocks (sorted by `line`, stable within a line). Borrows the
`TwoslashReturn` — do not outlive it.
*/
struct TwoslashPlan
{
    InlineDecoration[] inlineDecorations; /// sorted, outer-first on ties
    BelowBlock[] belowBlocks;             /// sorted by line, stable
}

/// Partitions `tw.nodes` into the inline / below-line work-lists.
TwoslashPlan planTwoslash(in TwoslashReturn tw)
{
    import std.algorithm.sorting : sort;

    // A `^?` query yields BOTH a hover and a query node on the same token; the
    // query's below-line popup supersedes the hover's inline popup, so the
    // redundant inline hover is dropped (matches @shikijs/twoslash).
    bool queryCoversToken(size_t start, size_t line)
    {
        foreach (ref const n; tw.nodes)
            if (n.type == NodeType.query && n.start == start && n.line == line)
                return true;
        return false;
    }

    TwoslashPlan plan;
    foreach (i, ref const n; tw.nodes)
    {
        if (hasInlineDecoration(n.type)
            && !(n.type == NodeType.hover && queryCoversToken(n.start, n.line)))
            plan.inlineDecorations ~= InlineDecoration(
                start: n.start, end: n.end, line: n.line, character: n.character,
                kind: n.type, node: i);
        if (hasBelowBlock(n.type))
            plan.belowBlocks ~= BelowBlock(line: n.line, kind: n.type, node: i);
    }

    // Outer-first ordering lets the HTML overlay open an enclosing decoration
    // before a nested one at the same offset (and the ANSI/GUI backends read a
    // stable order). `sort` is not stable, but the (start, -end, node) key is a
    // total order, so ties never collapse.
    plan.inlineDecorations.sort!((a, b) =>
        a.start != b.start ? a.start < b.start
        : a.end != b.end ? a.end > b.end
        : a.node < b.node);

    // Below blocks: by line, then original node order (a total order via node).
    plan.belowBlocks.sort!((a, b) =>
        a.line != b.line ? a.line < b.line : a.node < b.node);

    return plan;
}

/**
Re-highlights a popup type signature `sig` into `sink` (any output range of
`HighlightEvent`), re-entering `sparkles:syntax` as TypeScript. On any engine
error the signature is emitted as a single unstyled source span, so a missing
grammar degrades to plain text — the overlay never fails.

`@system` (transitively, via `highlightInjected`); not `@nogc`.
*/
void highlightSignature(Sink)(ref TsConfigCache cache, scope const(char)[] sig, ref Sink sink) @system
{
    import std.range.primitives : put;

    auto res = highlightInjected(cache, popupLanguage, sig, sink);
    if (res.hasError)
        put(sink, HighlightEvent.sourceSpan(0, sig.length));
}

version (unittest)
{
    import sparkles.twoslash.protocol : Completion;

    private TwoslashReturn sampleReturn() @safe pure nothrow
    {
        return TwoslashReturn(
            code: "const a = 1\nconst b = a\n",
            nodes: [
                Node(type: NodeType.hover, start: 6, length: 1, line: 0, character: 6,
                    text: "const a: 1"),
                Node(type: NodeType.highlight, start: 0, length: 5, line: 0, character: 0),
                Node(type: NodeType.error, start: 18, length: 1, line: 1, character: 6,
                    text: "nope", level: "error", code: 2339),
                Node(type: NodeType.query, start: 18, length: 1, line: 1, character: 6,
                    text: "const b: number"),
                Node(type: NodeType.tag, start: 0, length: 0, line: 0, character: 0, name: "log"),
            ]);
    }
}

@("overlay.classification")
@safe pure nothrow @nogc
unittest
{
    assert(hasInlineDecoration(NodeType.hover));
    assert(hasInlineDecoration(NodeType.highlight));
    assert(hasInlineDecoration(NodeType.error));
    assert(!hasInlineDecoration(NodeType.query));
    assert(!hasInlineDecoration(NodeType.completion));
    assert(!hasInlineDecoration(NodeType.tag));

    assert(hasBelowBlock(NodeType.error));
    assert(hasBelowBlock(NodeType.query));
    assert(hasBelowBlock(NodeType.completion));
    assert(hasBelowBlock(NodeType.tag));
    assert(!hasBelowBlock(NodeType.hover));
    assert(!hasBelowBlock(NodeType.highlight));
}

@("overlay.planTwoslash.partition")
@system unittest
{
    const tw = sampleReturn();
    auto plan = planTwoslash(tw);

    // inline: hover, highlight, error (query/tag excluded). Error is ALSO below.
    assert(plan.inlineDecorations.length == 3);
    // below: error + query + tag.
    assert(plan.belowBlocks.length == 3);

    // Sorted by start asc: highlight(0) < hover(6) < error(18).
    assert(plan.inlineDecorations[0].kind == NodeType.highlight);
    assert(plan.inlineDecorations[1].kind == NodeType.hover);
    assert(plan.inlineDecorations[2].kind == NodeType.error);

    // Below sorted by line: tag(line 0) before error/query (line 1).
    assert(plan.belowBlocks[0].kind == NodeType.tag);
    assert(plan.belowBlocks[0].line == 0);
    assert(plan.belowBlocks[1].line == 1);
    assert(plan.belowBlocks[2].line == 1);
}

@("overlay.planTwoslash.hoverSuppressedByQuery")
@system unittest
{
    // A `^?` yields overlapping hover + query on one token; the inline hover
    // decoration is dropped, the query below-block kept.
    const tw = TwoslashReturn(code: "let b = 1\n", nodes: [
        Node(type: NodeType.hover, start: 4, length: 1, line: 0, character: 4,
            text: "let b: number"),
        Node(type: NodeType.query, start: 4, length: 1, line: 0, character: 4,
            text: "let b: number"),
    ]);
    auto plan = planTwoslash(tw);
    assert(plan.inlineDecorations.length == 0, "hover should be suppressed by the query");
    assert(plan.belowBlocks.length == 1);
    assert(plan.belowBlocks[0].kind == NodeType.query);
}

@("overlay.planTwoslash.hoverKeptWithoutQuery")
@system unittest
{
    // A hover with no query on the same token survives.
    const tw = TwoslashReturn(code: "let b = 1\n", nodes: [
        Node(type: NodeType.hover, start: 4, length: 1, line: 0, character: 4, text: "T"),
    ]);
    auto plan = planTwoslash(tw);
    assert(plan.inlineDecorations.length == 1);
    assert(plan.inlineDecorations[0].kind == NodeType.hover);
}

@("overlay.planTwoslash.outerFirstOnTies")
@system unittest
{
    // Two inline spans starting at the same offset — the wider one must sort
    // first so a renderer can nest the narrower inside it.
    const tw = TwoslashReturn(code: "abcdef", nodes: [
        Node(type: NodeType.highlight, start: 0, length: 3, line: 0, character: 0),
        Node(type: NodeType.hover, start: 0, length: 6, line: 0, character: 0, text: "T"),
    ]);
    auto plan = planTwoslash(tw);
    assert(plan.inlineDecorations[0].end == 6); // wider (hover) first
    assert(plan.inlineDecorations[1].end == 3);
}
