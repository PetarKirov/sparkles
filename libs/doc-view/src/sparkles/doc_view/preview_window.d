/**
The markdown preview's segment index: where each of a document's segments
sits, whether it has been laid out at the current width or only estimated,
and which of them a window of the pane needs built.

A large preview is laid out as a window around the pane ($(REF
viewMarkdownWindowInto, sparkles,source_view,markdown)); every other segment
is only placed, by a height that is exact once some layout measured it at
the current options and an estimate until then. The estimates make the
document's length, and so the scrollbar, approximate for a few frames after
a resize; they never move what the pane shows, which is always laid out.
*/
module sparkles.doc_view.preview_window;

import sparkles.source_view.markdown : MdSegment, mdSegments;
import sparkles.syntax.md.model : MdBlock, MdBlockKind;

@safe:

/// The rows `[top, bottom)` a window covers, and its segments `[first, end)`.
struct PreviewWindow
{
    size_t first, end; /// segments, by index
    long top, bottom;  /// rows
    /// Whether the window holds any segment.
    bool empty() const pure nothrow @nogc => first >= end;
}

/// See the module documentation.
struct SegmentIndex
{
    /// The segments, in document order.
    MdSegment[] segments;
    /// Each segment's height in rows, exact or estimated.
    int[] height;
    /// Whether `height` was measured at the current options.
    bool[] exact;
    // The content width each height was measured or estimated at.
    private int[] widthOf;
    // Each segment's first row (the column's gap of one row after each
    // segment included), valid while `!dirty`: `commit` brings it up to date
    // after `measured`, every other change commits itself.
    private long[] tops = [0];
    private bool dirty;

    /// The number of segments.
    size_t length() const pure nothrow @nogc => segments.length;

    /**
    Re-segments `blocks` under the fold set `folded`, keeping the height of
    every segment that survives unchanged; a new one is estimated from its
    source at `width`.
    */
    void resegment(in MdBlock[] blocks, in size_t[] folded, const(char)[] source,
        int width) pure nothrow
    {
        auto next = mdSegments(blocks, folded);
        auto h = new int[](next.length);
        auto x = new bool[](next.length);
        auto w = new int[](next.length);
        size_t old;
        foreach (i, seg; next)
        {
            while (old < segments.length && segments[old].first < seg.first)
                ++old;
            if (old < segments.length && segments[old] == seg)
            {
                h[i] = height[old];
                x[i] = exact[old];
                w[i] = widthOf[old];
            }
            else
            {
                h[i] = estimateFromSource(blocks[seg.first .. seg.end], source, width,
                    seg.end - seg.first > 1 || folded.contains(blocks[seg.first].span.start));
                w[i] = width;
            }
        }
        segments = next;
        height = h;
        exact = x;
        widthOf = w;
        dirty = true;
        commit();
    }

    /// Drops every height: a new document.
    void clear() pure nothrow
    {
        segments = null;
        height = null;
        exact = null;
        widthOf = null;
        dirty = true;
        commit();
    }

    /**
    Every height becomes an estimate at `width`. A height measured at another
    width is scaled when the segment's text re-wraps with the width — prose,
    headings, lists, quotes — and kept for one whose rows the width does not
    reach (a fence's or a table's are its own lines).
    */
    void reflow(in MdBlock[] blocks, int width) pure nothrow
    {
        foreach (i, ref seg; segments)
        {
            exact[i] = false;
            if (widthOf[i] != width && widthOf[i] > 0 && width > 0
                && rewraps(blocks[seg.first].kind) && seg.end - seg.first == 1)
            {
                const scaled = (cast(long) height[i] * widthOf[i] + width / 2) / width;
                height[i] = scaled < 1 ? 1 : cast(int) scaled;
            }
            widthOf[i] = width;
        }
        dirty = true;
        commit();
    }

    /// Every height becomes an estimate, kept as it is: options other than
    /// the width changed.
    void invalidate() pure nothrow @nogc
    {
        exact[] = false;
    }

    /// Records a laid-out segment's height at `width`; `commit` places the
    /// segments after it again.
    void measured(size_t seg, int rows, int width) pure nothrow @nogc
    {
        if (height[seg] != rows)
            dirty = true;
        height[seg] = rows;
        exact[seg] = true;
        widthOf[seg] = width;
    }

    /// The first row of segment `seg` (`length` gives the document's length
    /// plus one gap row).
    long topOf(size_t seg) const pure nothrow @nogc
        in (!dirty, "measured heights not committed")
        => tops[seg];

    /// The document's length in rows.
    long total() const pure nothrow @nogc
        in (!dirty, "measured heights not committed")
        => segments.length ? tops[$ - 1] - 1 : 0;

    /// The segment showing row `row` (its gap row counted as its own).
    size_t segmentAtRow(long row) const pure nothrow @nogc
        in (!dirty, "measured heights not committed")
    {
        if (!segments.length)
            return 0;
        // The last segment whose top is at or before `row`.
        size_t lo, hi = segments.length;
        while (hi - lo > 1)
        {
            const mid = (lo + hi) / 2;
            if (tops[mid] <= row)
                lo = mid;
            else
                hi = mid;
        }
        return lo;
    }

    /// The segment holding source offset `src`: the last one starting at or
    /// before it.
    size_t segmentOfSource(in MdBlock[] blocks, size_t src) const pure nothrow @nogc
    {
        if (!segments.length)
            return 0;
        size_t lo, hi = segments.length;
        while (hi - lo > 1)
        {
            const mid = (lo + hi) / 2;
            if (blocks[segments[mid].first].span.start <= src)
                lo = mid;
            else
                hi = mid;
        }
        return lo;
    }

    /**
    The window that lays out about `before` rows above segment `anchor`'s top
    and `after` rows from it on, by the current heights.
    */
    PreviewWindow around(size_t anchor, long before, long after) const pure nothrow @nogc
        in (!dirty, "measured heights not committed")
    {
        if (!segments.length)
            return PreviewWindow.init;
        if (anchor >= segments.length)
            anchor = segments.length - 1;
        size_t first = anchor;
        while (first > 0 && tops[anchor] - tops[first] < before)
            --first;
        size_t end = anchor + 1;
        while (end < segments.length && tops[end] - tops[anchor] < after)
            ++end;
        return PreviewWindow(first, end, tops[first], tops[end] - 1);
    }

    /// Places every segment by the current heights.
    void commit() pure nothrow
    {
        if (!dirty && tops.length == segments.length + 1)
            return;
        tops.length = segments.length + 1;
        long y;
        foreach (i, h; height)
        {
            tops[i] = y;
            y += h + 1;
        }
        tops[$ - 1] = y;
        dirty = false;
    }
}

// Whether a block's rows re-wrap with the width.
private bool rewraps(MdBlockKind kind) pure nothrow @nogc
{
    with (MdBlockKind) final switch (kind)
    {
        case paragraph, heading, blockQuote, list, listItem, htmlBlock, document:
            return true;
        case codeFence, codeGroup, table, tableRow, tableCell, thematicBreak:
            return false;
    }
}

private bool contains(in size_t[] set, size_t x) pure nothrow @nogc
{
    foreach (e; set)
        if (e == x)
            return true;
    return false;
}

/**
A segment's height before anything has laid it out: its source lines, each
wrapped at `width`, with a fence's or a table's border rows. A folded
segment is its one placeholder row.
*/
int estimateFromSource(in MdBlock[] blocks, const(char)[] source, int width,
    bool folded) pure nothrow @nogc
{
    if (folded)
        return 1;
    if (!blocks.length)
        return 1;
    const start = blocks[0].span.start;
    const end = blocks[$ - 1].span.end;
    const text = start <= end && end <= source.length ? source[start .. end] : null;
    const boxed = blocks[0].kind == MdBlockKind.codeFence || blocks[0].kind == MdBlockKind.table
        || blocks[0].kind == MdBlockKind.codeGroup;
    const w = width > 4 ? width : 4;
    long rows;
    size_t lineLen;
    void line() pure nothrow @nogc
    {
        rows += boxed || lineLen == 0 ? 1 : (lineLen + w - 1) / w;
        lineLen = 0;
    }

    foreach (char c; text)
    {
        if (c == '\n')
            line();
        else if ((c & 0xC0) != 0x80)
            ++lineLen;
    }
    if (lineLen)
        line();
    if (rows < 1)
        rows = 1;
    return cast(int)(rows > int.max / 2 ? int.max / 2 : rows);
}

version (unittest)
{
    import sparkles.syntax.md.model : Span;

    private MdBlock block(MdBlockKind kind, size_t start, size_t end, ubyte level = 0)
        pure nothrow @nogc
        => MdBlock(kind: kind, span: Span(start, end), level: level);
}

@("preview_window.SegmentIndex.placesSegmentsByTheirHeights")
@safe pure nothrow unittest
{
    const src = "# A\n\npara\n\n```\ncode\n```\n";
    const blocks = [block(MdBlockKind.heading, 0, 3, 1),
        block(MdBlockKind.paragraph, 5, 9), block(MdBlockKind.codeFence, 11, 23)];
    SegmentIndex ix;
    ix.resegment(blocks, null, src, 40);
    assert(ix.length == 3 && !ix.exact[0]);
    ix.measured(0, 1, 40);
    ix.measured(1, 3, 40);
    ix.measured(2, 5, 40);
    ix.commit();
    assert(ix.topOf(0) == 0 && ix.topOf(1) == 2 && ix.topOf(2) == 6);
    assert(ix.total() == 11);
    assert(ix.segmentAtRow(0) == 0 && ix.segmentAtRow(1) == 0);
    assert(ix.segmentAtRow(2) == 1 && ix.segmentAtRow(5) == 1);
    assert(ix.segmentAtRow(6) == 2 && ix.segmentAtRow(100) == 2);
    assert(ix.segmentOfSource(blocks, 0) == 0 && ix.segmentOfSource(blocks, 7) == 1);
    assert(ix.segmentOfSource(blocks, 10) == 1 && ix.segmentOfSource(blocks, 30) == 2);

    const w = ix.around(1, before: 1, after: 2);
    assert(w.first == 0 && w.end == 2 && w.top == 0 && w.bottom == 5);
    const all = ix.around(1, before: 10, after: 100);
    assert(all.first == 0 && all.end == 3 && all.bottom == 11);
}

@("preview_window.SegmentIndex.reflowScalesOnlyWhatRewraps")
@safe pure nothrow unittest
{
    const src = "para para para\n\n```\na\nb\n```\n";
    const blocks = [block(MdBlockKind.paragraph, 0, 14), block(MdBlockKind.codeFence, 16, 28)];
    SegmentIndex ix;
    ix.resegment(blocks, null, src, 40);
    ix.measured(0, 4, 40);
    ix.measured(1, 4, 40);
    ix.commit();
    ix.reflow(blocks, 80);
    assert(!ix.exact[0] && !ix.exact[1]);
    assert(ix.height[0] == 2, "prose re-wraps with the width");
    assert(ix.height[1] == 4, "a fence keeps its rows");
    assert(ix.total() == 7);
}

@("preview_window.SegmentIndex.resegmentKeepsWhatAFoldDidNotTouch")
@safe pure nothrow unittest
{
    const src = "## A\n\nbody\n\n## B\n\nbody\n";
    const blocks = [block(MdBlockKind.heading, 0, 4, 2), block(MdBlockKind.paragraph, 6, 10),
        block(MdBlockKind.heading, 12, 16, 2), block(MdBlockKind.paragraph, 18, 22)];
    SegmentIndex ix;
    ix.resegment(blocks, null, src, 40);
    foreach (i; 0 .. 4)
        ix.measured(i, 2, 40);
    ix.commit();
    // Folding A merges its section into one segment, estimated as the
    // placeholder's single row; B's two segments keep their heights.
    ix.resegment(blocks, [0UL], src, 40);
    assert(ix.segments == [MdSegment(0, 2), MdSegment(2, 3), MdSegment(3, 4)]);
    assert(!ix.exact[0] && ix.height[0] == 1);
    assert(ix.exact[1] && ix.exact[2] && ix.height[1] == 2);
}

@("preview_window.estimateFromSource.wrapsProseAndBoxesFences")
@safe pure nothrow @nogc unittest
{
    const src = "0123456789abcdefghij\nxy\n";
    const MdBlock[1] para = [block(MdBlockKind.paragraph, 0, 23)];
    assert(estimateFromSource(para, src, 10, false) == 3);
    const MdBlock[1] fence = [block(MdBlockKind.codeFence, 0, 23)];
    assert(estimateFromSource(fence, src, 10, false) == 2);
    assert(estimateFromSource(para, src, 10, true) == 1);
}
