/**
 * Canonical 8-byte text byte range primitive.
 *
 * `TextSpan` records an inclusive start byte offset and an exclusive end byte
 * offset `[startOffset, endOffset)` into a source text. Stored as two 32-bit
 * unsigned integers (`uint`), it fits in a single 64-bit CPU register and is
 * passed by value with zero heap overhead.
 *
 * The sentinel value `uint.max` represents an invalid or uninitialized span.
 *
 * Pair with $(REF LineIndex, sparkles,base,text,lineindex) to project line and
 * column numbers on demand in `O(log N)` time without inflating data structures.
 */
module sparkles.base.text.span;

import sparkles.test_runner.attributes : betterC;

/// An 8-byte byte range `[startOffset, endOffset)` into a source text.
struct TextSpan
{
    uint startOffset = uint.max;
    uint endOffset = uint.max;

    /**
    Constructs a span from a range that may not be well-formed, yielding the
    invalid sentinel when it is not.

    The struct literal `TextSpan(start, end)` does not run the `invariant` —
    D checks it on public member entry and exit, not on field-wise
    construction — so an inverted range builds silently and the assertion
    fires later, at whichever accessor a caller happens to reach first, far
    from the data that caused it. Worse, with assertions compiled out it
    never fires at all: `length` then returns `end - start` wrapped around,
    and a caller slicing by it faults.

    A parser reading offsets it did not produce should build through this and
    check $(LREF isValid), so a bad range is rejected where it enters.

    Params:
        start = inclusive start byte offset
        end = exclusive end byte offset

    Returns: the span, or `TextSpan.init` when `start > end`.
    */
    static TextSpan of(uint start, uint end) @safe pure nothrow @nogc
        => start <= end ? TextSpan(start, end) : TextSpan.init;

    /// Whether this span represents a valid, initialized range.
    bool isValid() const @safe pure nothrow @nogc
        => startOffset != uint.max && endOffset != uint.max;

    /// Byte length of the span (0 if invalid).
    size_t length() const @safe pure nothrow @nogc
        => isValid ? (endOffset - startOffset) : 0;

    /// Whether the span is a valid range covering no bytes. An invalid span
    /// is not empty — it is nothing at all — which is why this checks
    /// $(LREF isValid) as `length` and `contains` do.
    bool empty() const @safe pure nothrow @nogc
        => isValid && startOffset == endOffset;

    /// Whether `offset` falls within `[startOffset, endOffset)`.
    bool contains(uint offset) const @safe pure nothrow @nogc
        => isValid && offset >= startOffset && offset < endOffset;

    /// Whether this span overlaps with `other`.
    bool overlaps(in TextSpan other) const @safe pure nothrow @nogc
        => isValid && other.isValid && startOffset < other.endOffset && other.startOffset < endOffset;

    /// The intersection of this span and `other`, or `TextSpan.init` if disjoint.
    TextSpan intersect(in TextSpan other) const @safe pure nothrow @nogc
    {
        if (!overlaps(other))
            return TextSpan.init;
        const s = startOffset > other.startOffset ? startOffset : other.startOffset;
        const e = endOffset < other.endOffset ? endOffset : other.endOffset;
        return TextSpan(s, e);
    }

    /// The minimal bounding span enclosing both this span and `other`.
    TextSpan hull(in TextSpan other) const @safe pure nothrow @nogc
    {
        if (!isValid)
            return other;
        if (!other.isValid)
            return this;
        const s = startOffset < other.startOffset ? startOffset : other.startOffset;
        const e = endOffset > other.endOffset ? endOffset : other.endOffset;
        return TextSpan(s, e);
    }

    /// Slices `text` by this span.
    scope const(char)[] sliceOf(return scope const(char)[] text) const @safe pure nothrow @nogc
    in (isValid, "cannot slice an invalid TextSpan")
    in (endOffset <= text.length, "TextSpan endOffset past end of text")
        => text[startOffset .. endOffset];

    invariant
    {
        assert((startOffset == uint.max && endOffset == uint.max) || startOffset <= endOffset,
            "TextSpan: startOffset must be <= endOffset");
    }
}

@("text.span.basic")
@betterC
unittest
{
    const span = TextSpan(5, 12);
    assert(span.isValid);
    assert(span.length == 7);
    assert(!span.empty);
    assert(span.contains(5));
    assert(span.contains(11));
    assert(!span.contains(12));
    assert(!span.contains(4));

    enum text = "0123456789abcdef";
    assert(span.sliceOf(text) == "56789ab");
}

@("text.span.invalid")
@betterC
unittest
{
    const inv = TextSpan.init;
    assert(!inv.isValid);
    assert(inv.length == 0);
    assert(!inv.contains(0));
    assert(!inv.overlaps(TextSpan(0, 10)));
    // Not "an empty range" — no range at all.
    assert(!inv.empty);
}

@("text.span.ofRejectsInvertedRanges")
@betterC
unittest
{
    // The checked factory a parser reading untrusted offsets should use: an
    // inverted range becomes the sentinel here, rather than a literal that
    // trips the invariant at some later accessor — or, with assertions
    // compiled out, silently reports a wrapped-around length.
    const good = TextSpan.of(5, 12);
    assert(good.isValid && good.length == 7);

    const degenerate = TextSpan.of(5, 5);
    assert(degenerate.isValid && degenerate.empty);

    const inverted = TextSpan.of(20, 5);
    assert(!inverted.isValid);
    assert(inverted == TextSpan.init);
}

@("text.span.overlapsAndIntersect")
@betterC
unittest
{
    const a = TextSpan(10, 20);
    const b = TextSpan(15, 25);
    const c = TextSpan(20, 30);
    const d = TextSpan(0, 5);

    assert(a.overlaps(b));
    assert(b.overlaps(a));
    assert(!a.overlaps(c), "adjacent spans do not overlap");
    assert(!a.overlaps(d));

    assert(a.intersect(b) == TextSpan(15, 20));
    assert(a.intersect(c) == TextSpan.init);

    assert(a.hull(b) == TextSpan(10, 25));
    assert(a.hull(d) == TextSpan(0, 20));
}
