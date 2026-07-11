/**
The engine-agnostic highlight-event seam.

Every token producer (the tree-sitter precise engine today, a TextMate-style
line engine later) emits one stream type — $(LREF HighlightEvent) — and every
rendering backend (ANSI, HTML, future GPU styled-run consumers) folds over it.
Events are offset-based (byte ranges into the source slice, never stored
slices), so stream state carries no lifetime coupling to the source buffer.

$(B Stream contract) (producers must uphold it; consumers handle violations
defensively rather than erroring):

$(LIST
    * events are ordered; `source` ranges are ascending and non-overlapping;
    * `push`/`pop` pairs are balanced and never split a `source` span — a
        span's style is the innermost open label for its whole extent;
    * the stream is infallible: engine failures surface before or around the
        stream (e.g. as an `Expected` from the engine entry point), never as
        element-level errors. Renderers are total — the worst legal output is
        uncolored text.
)

The flattening fold $(LREF byStyledSpan) and its element $(LREF StyledSpan)
are public API on purpose: a GPU/text-engine backend consumes maximal
innermost-wins runs plus resolved theme styles directly — data, not markup.
See `docs/specs/syntax/` for the design.
*/
module sparkles.syntax.event;

import std.range.primitives : ElementType, empty, front, isInputRange, popFront;

import sparkles.base.smallbuffer : SmallBuffer;

/// Index into a configured `LabelSet` vocabulary. `LabelId.none` (the
/// default) means unresolved/uncolored.
struct LabelId
{
    ushort value = ushort.max;

    /// The sentinel: no label. Renders unstyled.
    enum LabelId none = LabelId.init;

    /// `true` iff this is a real label (not $(LREF none)).
    bool opCast(T : bool)() const @safe pure nothrow @nogc
        => value != ushort.max;
}

@("event.LabelId.truthiness")
@safe pure nothrow @nogc
unittest
{
    assert(!LabelId.none);
    assert(!LabelId.init);
    assert(LabelId(0));
    assert(LabelId(42));
}

/**
One step in rendering a highlighted document.

Deliberately a flat POD (no union): trivially `@safe`, named-argument
constructible, and cheap to buffer. `start`/`end` are byte offsets into the
source slice and are meaningful only for `kind == source`; `label` only for
`kind == push`.
*/
struct HighlightEvent
{
    /// Discriminates the three event shapes.
    enum Kind : ubyte
    {
        source, /// emit `source[start .. end]`
        push,   /// open `label`; it stays innermost until the matching `pop`
        pop,    /// close the innermost open label
    }

    Kind kind;    /// which event this is
    size_t start; /// byte offset (kind == source)
    size_t end;   /// byte offset, exclusive (kind == source)
    LabelId label; /// the opened label (kind == push)

    /// Constructs a `source` event covering `source[start .. end]`.
    static HighlightEvent sourceSpan(size_t start, size_t end) @safe pure nothrow @nogc
    in (start <= end, "source span range must be non-decreasing")
    {
        return HighlightEvent(kind: Kind.source, start: start, end: end);
    }

    /// Constructs a `push` event opening `label`.
    static HighlightEvent pushLabel(LabelId label) @safe pure nothrow @nogc
        => HighlightEvent(kind: Kind.push, label: label);

    /// Constructs a `pop` event closing the innermost open label.
    static HighlightEvent popLabel() @safe pure nothrow @nogc
        => HighlightEvent(kind: Kind.pop);
}

///
@("event.HighlightEvent.factories")
@safe pure nothrow @nogc
unittest
{
    const src = HighlightEvent.sourceSpan(2, 5);
    assert(src.kind == HighlightEvent.Kind.source);
    assert(src.start == 2 && src.end == 5);

    const open = HighlightEvent.pushLabel(LabelId(7));
    assert(open.kind == HighlightEvent.Kind.push);
    assert(open.label == LabelId(7));

    const close = HighlightEvent.popLabel();
    assert(close.kind == HighlightEvent.Kind.pop);
}

/// The concept both engines target and both renderers accept: any input
/// range of $(LREF HighlightEvent)s.
enum isHighlightEventRange(R) =
    isInputRange!R && is(const(ElementType!R) : const(HighlightEvent));

@("event.isHighlightEventRange")
@safe pure nothrow @nogc
unittest
{
    static assert(isHighlightEventRange!(HighlightEvent[]));
    static assert(isHighlightEventRange!(const(HighlightEvent)[]));
    static assert(!isHighlightEventRange!(int[]));
    static assert(!isHighlightEventRange!int);
}

/// A maximal run of source text with one resolved label (innermost open
/// label wins). `label` may be $(LREF LabelId.none) for unstyled runs.
struct StyledSpan
{
    size_t start;  /// byte offset into the source slice
    size_t end;    /// byte offset, exclusive
    LabelId label; /// innermost open label over the whole run
}

/**
Lazily flattens a highlight-event stream into $(LREF StyledSpan)s.

Maintains the label stack across `push`/`pop` events and yields one span per
`source` event, tagged with the innermost open label. This fold is the
third-backend contract: a consumer that wants styled runs as data (e.g. a GPU
text renderer) iterates this instead of the raw events.

Unbalanced `pop`s are ignored defensively (the stream contract forbids them,
but renderers are total).
*/
auto byStyledSpan(Events)(Events events)
if (isHighlightEventRange!Events)
{
    return StyledSpanRange!Events(events);
}

/// ditto
private struct StyledSpanRange(Events)
{
    private Events _events;
    private HighlightStack _stack;
    private StyledSpan _front;
    private bool _empty;

    this(Events events)
    {
        _events = events;
        advance();
    }

    bool empty() const => _empty;

    StyledSpan front() const
    in (!_empty, "front on an empty StyledSpanRange")
    {
        return _front;
    }

    void popFront()
    in (!_empty, "popFront on an empty StyledSpanRange")
    {
        advance();
    }

    private void advance()
    {
        while (!_events.empty)
        {
            const ev = _events.front;
            _events.popFront();
            final switch (ev.kind)
            {
                case HighlightEvent.Kind.source:
                    _front = StyledSpan(ev.start, ev.end, _stack.top);
                    return;
                case HighlightEvent.Kind.push:
                    _stack.push(ev.label);
                    break;
                case HighlightEvent.Kind.pop:
                    _stack.pop();
                    break;
            }
        }
        _empty = true;
    }
}

///
@("event.byStyledSpan.nesting")
@safe pure nothrow @nogc
unittest
{
    alias E = HighlightEvent;
    // "ab<k1>cd<k2>ef</k2></k1>gh" — innermost label wins per source span.
    static immutable E[8] events = [
        E.sourceSpan(0, 2),
        E.pushLabel(LabelId(1)),
        E.sourceSpan(2, 4),
        E.pushLabel(LabelId(2)),
        E.sourceSpan(4, 6),
        E.popLabel(),
        E.popLabel(),
        E.sourceSpan(6, 8),
    ];

    auto spans = byStyledSpan(events[]);
    assert(!spans.empty && spans.front == StyledSpan(0, 2, LabelId.none));
    spans.popFront();
    assert(!spans.empty && spans.front == StyledSpan(2, 4, LabelId(1)));
    spans.popFront();
    assert(!spans.empty && spans.front == StyledSpan(4, 6, LabelId(2)));
    spans.popFront();
    assert(!spans.empty && spans.front == StyledSpan(6, 8, LabelId.none));
    spans.popFront();
    assert(spans.empty);
}

@("event.byStyledSpan.emptyStream")
@safe pure nothrow @nogc
unittest
{
    const(HighlightEvent)[] events;
    assert(byStyledSpan(events).empty);
}

@("event.byStyledSpan.unbalancedPopIsIgnored")
@safe pure nothrow @nogc
unittest
{
    alias E = HighlightEvent;
    static immutable E[3] events = [
        E.popLabel(), // stray pop: contract violation, handled defensively
        E.pushLabel(LabelId(3)),
        E.sourceSpan(0, 1),
    ];

    auto spans = byStyledSpan(events[]);
    assert(spans.front == StyledSpan(0, 1, LabelId(3)));
    spans.popFront();
    assert(spans.empty);
}

@("event.byStyledSpan.deepNesting")
@safe pure nothrow @nogc
unittest
{
    // Deeper than the stack's inline capacity: exercises the heap spill.
    alias E = HighlightEvent;
    SmallBuffer!(HighlightEvent, 8) events;
    foreach (i; 0 .. 32)
        events ~= E.pushLabel(LabelId(cast(ushort) i));
    events ~= E.sourceSpan(0, 1);
    foreach (i; 0 .. 32)
        events ~= E.popLabel();
    events ~= E.sourceSpan(1, 2);

    auto spans = byStyledSpan(events[]);
    assert(spans.front == StyledSpan(0, 1, LabelId(31)));
    spans.popFront();
    assert(spans.front == StyledSpan(1, 2, LabelId.none));
    spans.popFront();
    assert(spans.empty);
}

/**
The label stack shared by $(LREF byStyledSpan) and the HTML renderer's
close/reopen logic. Package-internal: consumers see only its effects.
*/
package struct HighlightStack
{
    private SmallBuffer!(LabelId, 16) _stack;

    void push(LabelId label) @safe pure nothrow @nogc
    {
        _stack ~= label;
    }

    /// Defensive: popping an empty stack is a no-op.
    void pop() @safe pure nothrow @nogc
    {
        if (_stack.length)
            _stack.popBack();
    }

    /// The innermost open label, or `LabelId.none` when nothing is open.
    LabelId top() const @safe pure nothrow @nogc
        => _stack.length ? _stack[_stack.length - 1] : LabelId.none;

    size_t depth() const @safe pure nothrow @nogc
        => _stack.length;
}

@("event.HighlightStack.basics")
@safe pure nothrow @nogc
unittest
{
    HighlightStack stack;
    assert(stack.top == LabelId.none);
    assert(stack.depth == 0);

    stack.push(LabelId(1));
    stack.push(LabelId(2));
    assert(stack.top == LabelId(2));
    assert(stack.depth == 2);

    stack.pop();
    assert(stack.top == LabelId(1));
    stack.pop();
    stack.pop(); // defensive: no-op on empty
    assert(stack.top == LabelId.none);
}
