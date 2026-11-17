/**
A cell-grid paragraph layout and the editor context that answers from it
(`EDT7`; editor application `EAP17`–`EAP18`).

`ParagraphLayout` lays out one logical line — a bidi paragraph — as grapheme
clusters on terminal cells: base resolves the paragraph's levels (UAX #9),
its line opportunities (UAX #14) and each cluster's width, and the layout
wraps greedily at the opportunities, resolves each visual row's levels and
orders its clusters (L1, L2). It owns no Unicode algorithm of its own.

`LayoutContext` is an `isEditContext` that answers every editor query —
visual rows, vertical columns, visual Left/Right, Home/End and the input
method's caret area — from that one layout. A view draws the same rows with
`visualRowSpans` (`sparkles.ui.components.editor`) and hit-tests through
`caretAtColumn`, so drawing, hits and motion share one result for a revision.
Layouts are a pure function of the text's bytes and the options, so a result
is reused only for byte-equal text: a stale layout cannot direct an edit.

Cells are the toolkit's cell grid. Proportional shaped flow belongs to
`sparkles:text-layout` and is not attempted here; within a cluster, a font
still shapes, but joining across clusters on the grid is the renderer's.

Specification: `docs/specs/editor/SPEC.md` §5, `docs/specs/ui/editor.md` §2.
*/
module sparkles.ui.editor.layout;

import core.time : MonoTime;

import sparkles.base.buffer : SharedBuffer, UniqueBuffer;
import sparkles.base.text.bidi : BidiCell, BidiDirection, BidiLineWorkspace, BidiParagraph, BidiWorkspace,
    bidiRemovedLevel, resolveBidiLine, resolveBidiParagraph;
import sparkles.base.text.line_break : LineBreakWorkspaceEntry, lineOpportunities;
import sparkles.base.text.seek : nextGraphemeBoundary;
import sparkles.base.text.unicode_algorithm : UnicodeBoundary, UnicodeBoundaryKind;
import sparkles.base.text.unicode_tables : BidiClass, bidiClass, bidiMirror;
import sparkles.base.text.utf : UtfMode, UtfToken, decodeToken;
import sparkles.base.text.width : ClusterWidthState;
import sparkles.text_buffer.summary : Affinity;
import sparkles.text_buffer.text : Text;
import sparkles.ui.editor.command : Boundary;
import sparkles.ui.editor.context : CaretTarget, VisualLine, isEditContext;
import sparkles.ui.editor.selection : EditRange;
import sparkles.ui.geometry : Rect;

/// One grapheme cluster of a paragraph, in logical order.
struct LayoutCluster
{
    /// Source bytes `[start, end)`.
    size_t start;
    /// ditto
    size_t end;
    /// Terminal cells it occupies.
    uint cells;
    /// Its resolved bidi level on its row: odd is right-to-left.
    ubyte level;
    /// Its index in its row's visual order, from the left.
    uint visual;
    /// The L4 mirrored glyph a right-to-left single scalar draws, or 0.
    dchar mirrored;
    /// It is white space a soft wrap may leave hanging past the row's end.
    bool space;

@safe pure nothrow @nogc:
    /// Whether it reads right to left.
    bool rtl() const scope => (level & 1) != 0;
    /// The caret at its visual left edge.
    CaretTarget leftEdge() const scope
        => rtl ? CaretTarget(end, Affinity.before) : CaretTarget(start, Affinity.after);
    /// The caret at its visual right edge.
    CaretTarget rightEdge() const scope
        => rtl ? CaretTarget(start, Affinity.after) : CaretTarget(end, Affinity.before);
}

/// One visual row: the clusters `[first, last)` of its paragraph.
struct LayoutRow
{
    /// Source bytes `[start, end)`; `end` is before any line break.
    size_t start;
    /// ditto
    size_t end;
    /// Logical cluster indices `[first, last)`.
    size_t first;
    /// ditto
    size_t last;
    /// Total cells.
    uint cells;
    /// Whether any cluster on the row reads right to left.
    bool mixed;

@safe pure nothrow @nogc:
    /// Caret stops: one more than the clusters.
    size_t stops() const scope => last - first + 1;
    /// As the step's visual line.
    VisualLine line() const scope => VisualLine(start, end);
}

/// How paragraphs are laid out.
struct LayoutOptions
{
    /// Wrap rows at this many cells; 0 never wraps.
    size_t wrapCells;
    /// The paragraph direction (UAX #9 P2–P3 when `automatic`).
    BidiDirection direction = BidiDirection.automatic;
}

/**
One paragraph laid out in visual rows. Buffers are reference-counted and
copied on write, so a layout copies cheaply and a context holding one stays
copyable.
*/
struct ParagraphLayout
{
    /// The logical line, `[start, end)` before its break.
    size_t start;
    /// ditto
    size_t end;
    /// The logical line's index.
    size_t line;
    /// The paragraph embedding level: 1 for a right-to-left paragraph.
    ubyte baseLevel;
    SharedBuffer!(LayoutCluster, 8) clusters;
    SharedBuffer!(LayoutRow, 1) rows;
    /// Per row, logical cluster indices from the left: row `r`'s are
    /// `order[r.first .. r.last]`.
    SharedBuffer!(uint, 8) order;

@safe pure nothrow @nogc:

    /// Lay out logical line `line` of `text`.
    static ParagraphLayout of(in Text text, size_t line, in LayoutOptions options)
    {
        ParagraphLayout p;
        p.line = line;
        p.start = text.lineStart(line);
        p.end = text.lineEnd(line);
        UniqueBuffer!(char, 256) bytes;
        bytes.length = p.end - p.start;
        text.copyTo(p.start, p.end, bytes[]);
        p.build(bytes[], options);
        return p;
    }

    /// Lay out `bytes`, one paragraph with no break, at source offset `start`.
    static ParagraphLayout ofBytes(scope const(char)[] bytes, in LayoutOptions options,
        size_t start = 0)
    {
        ParagraphLayout p;
        p.start = start;
        p.end = start + bytes.length;
        p.build(bytes, options);
        return p;
    }

    /// Whether it reads right to left.
    bool rtl() const scope => (baseLevel & 1) != 0;

    /// The row holding the caret `position` with `affinity`: at a soft wrap,
    /// `before` is the earlier row's end and `after` the later row's start.
    size_t rowOf(size_t position, Affinity affinity) const scope
    {
        size_t lo = 0, hi = rows.length;
        while (hi - lo > 1)
        {
            const mid = (lo + hi) / 2;
            if (rows[mid].start <= position) lo = mid;
            else hi = mid;
        }
        if (lo > 0 && rows[lo].start == position && affinity == Affinity.before)
            --lo;
        return lo;
    }

    /// The row whose start is `start`, or the nearest before it.
    size_t rowStarting(size_t start) const scope => rowOf(start, Affinity.after);

    /// The cluster index with `end == position` (`before`) or
    /// `start == position` (`after`) on row `row`, or `size_t.max`.
    private size_t clusterAt(in LayoutRow row, size_t position, Affinity affinity) const scope
    {
        size_t lo = row.first, hi = row.last;
        while (lo < hi)
        {
            const mid = (lo + hi) / 2;
            const at = affinity == Affinity.before ? clusters[mid].end : clusters[mid].start;
            if (at < position) lo = mid + 1;
            else hi = mid;
        }
        if (lo < row.last)
        {
            const at = affinity == Affinity.before ? clusters[lo].end : clusters[lo].start;
            if (at == position) return lo;
        }
        return size_t.max;
    }

    /// The caret stop, from 0 at the row's left edge, of `position` and
    /// `affinity` on row `r`; the other affinity answers when its own has no
    /// cluster on the row.
    size_t stopOf(size_t r, size_t position, Affinity affinity) const scope
    {
        const row = rows[r];
        foreach (attempt; 0 .. 2)
        {
            const a = attempt == 0 ? affinity : affinity == Affinity.before ? Affinity.after : Affinity.before;
            const c = clusterAt(row, position, a);
            if (c == size_t.max) continue;
            const cluster = clusters[c];
            const rightSide = cluster.rtl ? a == Affinity.after : a == Affinity.before;
            return cluster.visual + (rightSide ? 1 : 0);
        }
        return 0;
    }

    /// The cluster `k` places from the left on row `r`.
    ref const(LayoutCluster) visualCluster(size_t r, size_t k) const return scope
        => clusters[order[rows[r].first + k]];

    /// The caret at stop `k` of row `r`: the right edge of the cluster before
    /// it, or at the left edge the first cluster's left edge.
    CaretTarget stopTarget(size_t r, size_t k) const scope
    {
        const row = rows[r];
        if (row.first == row.last)
            return CaretTarget(row.start, Affinity.before);
        return k == 0 ? visualCluster(r, 0).leftEdge : visualCluster(r, k - 1).rightEdge;
    }

    /// The cells left of stop `k` on row `r`.
    size_t stopCells(size_t r, size_t k) const scope
    {
        size_t x;
        foreach (i; 0 .. k)
            x += visualCluster(r, i).cells;
        return x;
    }

    /// The stop on row `r` nearest `column` cells from its left; past a
    /// cluster's middle counts as after it.
    size_t stopAtColumn(size_t r, size_t column) const scope
    {
        const count = rows[r].last - rows[r].first;
        size_t x;
        foreach (k; 0 .. count)
        {
            const cells = visualCluster(r, k).cells;
            if (x + cells > column)
                return cells && 2 * (column - x) >= cells ? k + 1 : k;
            x += cells;
        }
        return count;
    }

    /// The stop where row `r` begins in reading order: its left edge in a
    /// left-to-right paragraph, its right edge otherwise.
    size_t readingStart(size_t r) const scope => rtl ? rows[r].last - rows[r].first : 0;
    /// The stop where row `r` ends in reading order.
    size_t readingEnd(size_t r) const scope => rtl ? 0 : rows[r].last - rows[r].first;

    private void build(scope const(char)[] bytes, in LayoutOptions options)
    {
        const n = bytes.length;
        UniqueBuffer!(UtfToken, 64) tokens;
        bool needsBidi = options.direction == BidiDirection.rtl;
        for (size_t i = 0; i < n;)
        {
            const decoded = decodeToken(bytes[i .. $], UtfMode.replacement, true, start + i);
            const consumed = decoded.result.consumed ? decoded.result.consumed : 1;
            UtfToken token = decoded.token;
            token.start = start + i;
            token.end = start + i + consumed;
            tokens.put(token);
            if (!needsBidi && token.scalar >= 0x0590)
                needsBidi = strongOrExplicit(bidiClass(token.scalar));
            i += consumed;
        }

        // Clusters, with the first token of each so levels and breaks map back.
        UniqueBuffer!(size_t, 64) firstToken;
        {
            size_t t;
            for (size_t at = 0; at < n;)
            {
                const next = nextGraphemeBoundary(bytes, at);
                ClusterWidthState width;
                firstToken.put(t);
                size_t scalars;
                dchar first;
                while (t < tokens.length && tokens[t].start < start + next)
                {
                    if (scalars == 0) first = tokens[t].scalar;
                    width.push(tokens[t].scalar, false);
                    ++scalars;
                    ++t;
                }
                LayoutCluster cluster;
                cluster.start = start + at;
                cluster.end = start + next;
                cluster.cells = width.width < 0 ? 0 : width.width;
                const cls = bidiClass(first);
                cluster.space = cls == BidiClass.WS || cls == BidiClass.S;
                cluster.mirrored = scalars == 1 && bidiMirror(first) != first ? bidiMirror(first) : 0;
                clusters.put(cluster);
                at = next;
            }
            firstToken.put(tokens.length);
        }

        // Rows: greedy over UAX #14 opportunities; white space may hang.
        UniqueBuffer!(UnicodeBoundary, 64) breaks;
        if (options.wrapCells && clusters.length)
        {
            UniqueBuffer!(LineBreakWorkspaceEntry, 1) scratch;
            scratch.length = tokens.length;
            breaks.length = tokens.length + 1;
            if (!lineOpportunities(tokens[], breaks[], scratch[]).succeeded)
                breaks.clear();
        }
        bool breakAfter(size_t c)
            => breaks.length && breaks[firstToken[c + 1]].kind != UnicodeBoundaryKind.prohibited;

        size_t rowFirst;
        size_t width;
        size_t lastBreak = size_t.max;
        foreach (c; 0 .. clusters.length)
        {
            const cells = clusters[c].cells;
            if (options.wrapCells && c > rowFirst && !clusters[c].space && width + cells > options.wrapCells)
            {
                const stop = lastBreak != size_t.max && lastBreak > rowFirst ? lastBreak : c;
                addRow(rowFirst, stop);
                rowFirst = stop;
                width = 0;
                foreach (k; stop .. c) width += clusters[k].cells;
                lastBreak = size_t.max;
                // What followed the opportunity may itself not fit with this cluster.
                if (c > rowFirst && width + cells > options.wrapCells)
                {
                    addRow(rowFirst, c);
                    rowFirst = c;
                    width = 0;
                }
            }
            width += cells;
            if (c + 1 < clusters.length && breakAfter(c))
                lastBreak = c + 1;
        }
        addRow(rowFirst, clusters.length);

        // Levels (UAX #9). A paragraph separator (B) inside the line — a lone
        // CR, NEL, U+2029 — ends a bidi paragraph, so each piece is resolved
        // on its own; the first sets the line's reading direction.
        if (needsBidi)
        {
            BidiWorkspace bidi;
            UniqueBuffer!(BidiCell, 1) bidiCells;
            UniqueBuffer!(size_t, 1) bidiSequence, bidiOrder;
            bidiCells.length = tokens.length;
            bidiSequence.length = tokens.length;
            bidiOrder.length = tokens.length;
            BidiLineWorkspace lineScratch;
            UniqueBuffer!(ubyte, 64) lineLevels;
            UniqueBuffer!(size_t, 64) lineForward, lineBackward;
            lineLevels.length = tokens.length;
            lineForward.length = tokens.length;
            lineBackward.length = tokens.length;
            if (options.direction == BidiDirection.rtl) baseLevel = 1;
            foreach (ref cluster; clusters[]) cluster.level = bidiRemovedLevel;

            size_t s0;
            bool first = true;
            while (s0 < tokens.length)
            {
                size_t s1 = s0;
                while (s1 < tokens.length && bidiClass(tokens[s1].scalar) != BidiClass.B) ++s1;
                if (s1 < tokens.length) ++s1; // the separator ends its paragraph
                bidi.cells = bidiCells[s0 .. s1];
                bidi.sequence = bidiSequence[s0 .. s1];
                bidi.visualToLogical = bidiOrder[s0 .. s1];
                const result = resolveBidiParagraph(tokens[s0 .. s1], options.direction, bidi);
                if (result.outcome.succeeded)
                {
                    if (first) baseLevel = result.paragraph.baseLevel;
                    foreach (r; 0 .. rows.length)
                    {
                        const t0 = firstToken[rows[r].first], t1 = firstToken[rows[r].last];
                        const from = t0 > s0 ? t0 : s0, to = t1 < s1 ? t1 : s1;
                        if (from >= to) continue;
                        lineScratch.levels = lineLevels[0 .. to - from];
                        lineScratch.logicalToVisual = lineForward[0 .. to - from];
                        lineScratch.visualToLogical = lineBackward[0 .. to - from];
                        const line = resolveBidiLine(result.paragraph, from - s0, to - s0, lineScratch);
                        if (!line.outcome.succeeded) continue;
                        foreach (c; rows[r].first .. rows[r].last)
                        {
                            if (firstToken[c] < from || firstToken[c] >= to) continue;
                            foreach (t; firstToken[c] .. firstToken[c + 1])
                                if (t < to && line.line.levels[t - from] != bidiRemovedLevel)
                                {
                                    clusters[c].level = line.line.levels[t - from];
                                    break;
                                }
                        }
                    }
                }
                first = false;
                s0 = s1;
            }
            // X9-removed clusters (BN, explicit embeddings) take the level of
            // the cluster before them on their row, else after, so they never
            // split a run (UAX #9 §5.2).
            foreach (r; 0 .. rows.length)
            {
                ubyte carry = bidiRemovedLevel;
                foreach (c; rows[r].first .. rows[r].last)
                    if (clusters[c].level == bidiRemovedLevel) clusters[c].level = carry;
                    else carry = clusters[c].level;
                carry = baseLevel;
                foreach_reverse (c; rows[r].first .. rows[r].last)
                    if (clusters[c].level == bidiRemovedLevel) clusters[c].level = carry;
                    else carry = clusters[c].level;
            }
        }

        // Row summaries and visual order (L2) at cluster granularity.
        foreach (r; 0 .. rows.length)
        {
            ref row = rows[r];
            foreach (c; row.first .. row.last)
            {
                if (!clusters[c].rtl) clusters[c].mirrored = 0;
                row.mixed |= clusters[c].rtl;
                row.cells += clusters[c].cells;
            }
            reorderRow(row);
        }
    }

    private void addRow(size_t first, size_t last)
    {
        LayoutRow row;
        row.first = first;
        row.last = last;
        row.start = first < last ? clusters[first].start
            : rows.length ? rows[rows.length - 1].end : start;
        row.end = first < last ? clusters[last - 1].end : row.start;
        if (rows.length == 0) row.start = start;
        rows.put(row);
        foreach (c; first .. last)
            order.put(cast(uint) c);
    }

    /// L2: from the highest level down to the lowest odd one, reverse every
    /// run at or above it.
    private void reorderRow(in LayoutRow row)
    {
        auto map = order[row.first .. row.last];
        ubyte highest, lowestOdd = ubyte.max;
        foreach (c; row.first .. row.last)
        {
            const level = clusters[c].level;
            if (level > highest) highest = level;
            if ((level & 1) && level < lowestOdd) lowestOdd = level;
        }
        if (lowestOdd != ubyte.max)
            for (int level = highest; level >= lowestOdd; --level)
            {
                size_t i;
                while (i < map.length)
                {
                    if (clusters[map[i]].level < level) { ++i; continue; }
                    size_t j = i;
                    while (j < map.length && clusters[map[j]].level >= level) ++j;
                    for (size_t a = i, b = j - 1; a < b; ++a, --b)
                    {
                        const swap = map[a];
                        map[a] = map[b];
                        map[b] = swap;
                    }
                    i = j;
                }
            }
        foreach (k, c; map)
            clusters[c].visual = cast(uint) k;
    }
}

/// Classes that make a paragraph need the full algorithm: anything else
/// resolves to level 0 in left-to-right order.
private bool strongOrExplicit(BidiClass c) @safe pure nothrow @nogc
{
    with (BidiClass) switch (c)
    {
    case R, AL, AN, RLE, RLO, RLI, LRE, LRO, LRI, FSI, PDF, PDI:
        return true;
    default:
        return false;
    }
}

/**
An edit context that answers from `ParagraphLayout` (`EAP17`): soft-wrapped
visual rows, visual Left/Right and Home/End, and caret columns with affinity.

The few most recently used paragraphs are kept, keyed by their bytes'
revision: a cached layout answers only while the text is byte-equal.
*/
struct LayoutContext
{
    MonoTime now;
    size_t viewportLines = 24;
    /// The host answers clipboard reads (`INP25`).
    bool clipboardRead;
    /// The host writes the clipboard.
    bool clipboardWrite;
    /// How paragraphs are laid out; a change discards cached layouts.
    LayoutOptions options;
    /// The logical line and row `caretArea` measures from: the view's top.
    size_t originLine;
    /// ditto
    size_t originRow;

    private enum cacheSize = 4;
    private Text[cacheSize] cachedText;
    private ParagraphLayout[cacheSize] cached;
    private LayoutOptions[cacheSize] cachedOptions;
    private bool[cacheSize] cachedValid;
    private size_t nextSlot;

@safe pure nothrow @nogc:

    /// Logical line `line`'s layout for `text`.
    ref const(ParagraphLayout) paragraph(in Text text, size_t line) return
    {
        foreach (i; 0 .. cacheSize)
            if (cachedValid[i] && cached[i].line == line && cachedOptions[i] == options
                && cachedText[i] == text)
                return cached[i];
        const slot = nextSlot;
        nextSlot = (nextSlot + 1) % cacheSize;
        cached[slot] = ParagraphLayout.of(text, line, options);
        cachedText[slot] = Text(text);
        cachedOptions[slot] = options;
        cachedValid[slot] = true;
        return cached[slot];
    }

    VisualLine lineAt(in Text text, size_t position, Affinity affinity)
    {
        ref p = paragraph(text, text.lineOf(position));
        return p.rows[p.rowOf(position, affinity)].line;
    }

    bool lineAbove(in Text text, VisualLine line, out VisualLine above)
    {
        const index = text.lineOf(line.start);
        ref p = paragraph(text, index);
        const r = p.rowStarting(line.start);
        if (r > 0)
        {
            above = p.rows[r - 1].line;
            return true;
        }
        if (index == 0)
            return false;
        ref q = paragraph(text, index - 1);
        above = q.rows[q.rows.length - 1].line;
        return true;
    }

    bool lineBelow(in Text text, VisualLine line, out VisualLine below)
    {
        const index = text.lineOf(line.start);
        ref p = paragraph(text, index);
        const r = p.rowStarting(line.start);
        if (r + 1 < p.rows.length)
        {
            below = p.rows[r + 1].line;
            return true;
        }
        if (index + 1 >= text.lineCount)
            return false;
        below = paragraph(text, index + 1).rows[0].line;
        return true;
    }

    /// The column of `position` on `line`, attached to the row's own side.
    size_t columnOf(in Text text, VisualLine line, size_t position)
        => caretColumn(text, line, CaretTarget(position,
            position == line.start ? Affinity.after : Affinity.before));

    /// The column of `caret` on `line`, honouring its affinity.
    size_t caretColumn(in Text text, VisualLine line, CaretTarget caret)
    {
        ref p = paragraph(text, text.lineOf(line.start));
        const r = p.rowStarting(line.start);
        return p.stopCells(r, p.stopOf(r, caret.position, caret.affinity));
    }

    size_t positionAt(in Text text, VisualLine line, size_t column)
        => caretAt(text, line, column).position;

    /**
    The caret nearest `column` on `line`, with the affinity that draws it there.
    Where two carets share a stop (a bidi boundary), the click's side decides:
    a column on the cluster right of the stop takes that cluster's left edge.
    */
    CaretTarget caretAt(in Text text, VisualLine line, size_t column)
    {
        ref p = paragraph(text, text.lineOf(line.start));
        const r = p.rowStarting(line.start);
        const count = p.rows[r].last - p.rows[r].first;
        const k = p.stopAtColumn(r, column);
        CaretTarget target;
        if (count == 0)
            target = p.stopTarget(r, 0);
        else if (k < count && (k == 0 || column >= p.stopCells(r, k)))
            target = p.visualCluster(r, k).leftEdge;
        else
            target = p.visualCluster(r, k - 1).rightEdge;
        // A row's logical edges belong to the row itself.
        if (target.position == line.start && line.start != p.start)
            target.affinity = Affinity.after;
        else if (target.position == line.end && line.end != p.end)
            target.affinity = Affinity.before;
        return target;
    }

    /// A row's width in cells.
    size_t lineCells(in Text text, VisualLine line)
    {
        ref p = paragraph(text, text.lineOf(line.start));
        return p.rows[p.rowStarting(line.start)].cells;
    }

    /**
    Visual Left/Right (`EAD9`): collapse a nonempty selection to its visual
    edge, else cross the adjacent cluster.

    Past a row's edge the caret continues on the paragraph's next row in
    reading order. Past the paragraph, Right goes to the next logical line's
    first row at its left edge and Left to the previous line's last row at
    its right edge, so held keys always progress through mixed-direction
    paragraphs. A landing on the byte just left is skipped; a byte at a bidi
    soft wrap may still be visited at two different cells.
    */
    CaretTarget horizontalCaret(in Text text, in EditRange range, int direction, bool extend)
    {
        const head = CaretTarget(range.head, range.affinity);
        if (!extend && !range.empty)
        {
            // Each endpoint on the selection's inner side: what it draws next to.
            const anchor = CaretTarget(range.anchor, range.forward ? Affinity.after : Affinity.before);
            const inner = CaretTarget(range.head, range.forward ? Affinity.before : Affinity.after);
            const start = range.forward ? anchor : inner;
            const end = range.forward ? inner : anchor;
            const ls = text.lineOf(start.position), le = text.lineOf(end.position);
            if (ls == le)
            {
                ref p = paragraph(text, ls);
                const rs = p.rowOf(start.position, start.affinity);
                const re = p.rowOf(end.position, end.affinity);
                if (rs == re)
                {
                    const ks = p.stopOf(rs, start.position, start.affinity);
                    const ke = p.stopOf(re, end.position, end.affinity);
                    if (ks != ke)
                        return (direction < 0) == (ks < ke) ? start : end;
                }
            }
            return (direction < 0) != paragraph(text, ls).rtl ? start : end;
        }
        size_t line = text.lineOf(head.position);
        size_t r;
        size_t landing;
        bool crossed;
        {
            ref p = paragraph(text, line);
            r = p.rowOf(head.position, head.affinity);
            const k = p.stopOf(r, head.position, head.affinity);
            const count = p.rows[r].last - p.rows[r].first;
            if (direction > 0 ? k < count : k > 0)
                return direction > 0 ? p.visualCluster(r, k).rightEdge : p.visualCluster(r, k - 1).leftEdge;

            // Past the edge: the paragraph's next row in reading order...
            const forward = (direction > 0) != p.rtl;
            if (forward ? r + 1 < p.rows.length : r > 0)
            {
                r = forward ? r + 1 : r - 1;
                landing = forward ? p.readingStart(r) : p.readingEnd(r);
            }
            // ... else the next or previous logical line, in document order.
            else if (direction > 0 ? line + 1 < text.lineCount : line > 0)
            {
                line = direction > 0 ? line + 1 : line - 1;
                crossed = true;
            }
            else
                return head;
        }
        ref p = paragraph(text, line);
        if (crossed)
        {
            r = direction > 0 ? 0 : p.rows.length - 1;
            landing = direction > 0 ? 0 : p.rows[r].last - p.rows[r].first;
        }
        const target = p.stopTarget(r, landing);
        if (target.position != head.position)
            return target;
        const rowCount = p.rows[r].last - p.rows[r].first;
        if (direction > 0 ? landing < rowCount : landing > 0)
            return direction > 0 ? p.visualCluster(r, landing).rightEdge
                : p.visualCluster(r, landing - 1).leftEdge;
        return target;
    }

    /**
    Home and End (`EAD9`): the visual left and right edge of the caret's
    row. A row with no right-to-left text keeps the logical smart Home:
    from the row's start, the first non-blank, and an all-blank row's end.
    */
    CaretTarget lineBoundaryCaret(in Text text, size_t position, Affinity affinity, Boundary boundary)
    {
        ref p = paragraph(text, text.lineOf(position));
        const r = p.rowOf(position, affinity);
        const row = p.rows[r];
        if (!row.mixed && !p.rtl)
        {
            CaretTarget target;
            if (boundary == Boundary.end)
                target = CaretTarget(row.end, Affinity.before);
            else if (position != row.start)
                target = CaretTarget(row.start, Affinity.after);
            else
            {
                size_t c = row.first;
                while (c < row.last && p.clusters[c].space) ++c;
                target = c < row.last ? CaretTarget(p.clusters[c].start, Affinity.after)
                    : CaretTarget(row.end, Affinity.before);
            }
            // Staying put is not a motion (`EDT5`): keep the caret's own side.
            if (target.position == position && p.rowOf(position, affinity) == r)
                target.affinity = affinity;
            return target;
        }
        return p.stopTarget(r, boundary == Boundary.start ? 0 : row.last - row.first);
    }

    /// The caret at `position`, before any boundary; see the `CaretTarget` overload.
    Rect caretArea(in Text text, size_t position, size_t extra)
        => caretArea(text, CaretTarget(position, Affinity.before), extra);

    /**
    The caret `caret`, `extra` cells further right (a preedit's cursor), in
    cells and visual rows from `originLine`/`originRow`: where `visualRows`
    draws it. An origin past the text is read as its last line. Rows are
    exact within `viewportLines` logical lines of the origin; farther away,
    each line counts one row, as the caret is off screen either way.
    */
    Rect caretArea(in Text text, CaretTarget caret, size_t extra)
    {
        const line = text.lineOf(caret.position);
        size_t x;
        size_t r;
        {
            ref p = paragraph(text, line);
            r = p.rowOf(caret.position, caret.affinity);
            x = p.stopCells(r, p.stopOf(r, caret.position, caret.affinity)) + extra;
        }
        const last = text.lineCount - 1;
        const fromLine = originLine > last ? last : originLine;
        const fromRow = originLine > last ? 0 : originRow;
        const y = rowsBetween(text, fromLine, fromRow, line, r, viewportLines + 1);
        return Rect(cast(int) x, cast(int) y, 1, 1);
    }

    /**
    Visual rows from (`fromLine`, `fromRow`) to (`toLine`, `toRow`), negative
    when before. Lines past `exactLines` from the start count one row each.
    */
    long rowsBetween(in Text text, size_t fromLine, size_t fromRow, size_t toLine, size_t toRow,
        size_t exactLines = size_t.max)
    {
        if (toLine < fromLine || toLine == fromLine && toRow < fromRow)
            return -rowsBetween(text, toLine, toRow, fromLine, fromRow, exactLines);
        long rows = cast(long) toRow - cast(long) fromRow;
        foreach (line; fromLine .. toLine)
            rows += line - fromLine < exactLines ? rowCount(text, line) : 1;
        return rows;
    }

    /// Rows of logical line `line` (0 past the text), laid out without disturbing the cache.
    size_t rowCount(in Text text, size_t line)
    {
        if (line >= text.lineCount) return 0;
        foreach (i; 0 .. cacheSize)
            if (cachedValid[i] && cached[i].line == line && cachedOptions[i] == options
                && cachedText[i] == text)
                return cached[i].rows.length;
        if (!options.wrapCells) return 1;
        // No grapheme is wider than two cells or shorter than one byte, so a
        // line of at most `wrapCells / 2` bytes is one row, without a layout.
        const start = text.lineStart(line), length = text.lineEnd(line) - start;
        if (2 * length <= options.wrapCells) return 1;
        // Printable ASCII is one cell a byte: a line of it that fits is one row.
        if (length <= options.wrapCells && printableAscii(text, start, start + length)) return 1;
        return ParagraphLayout.of(text, line, options).rows.length;
    }
}

static assert(isEditContext!LayoutContext);

/// Whether `[from, to)` of `text` is printable ASCII, a cell per byte.
private bool printableAscii(in Text text, size_t from, size_t to) @safe pure nothrow @nogc
{
    while (from < to)
    {
        const chunk = text.chunkAt(from);
        const end = chunk.start + chunk.bytes.length < to ? chunk.start + chunk.bytes.length : to;
        foreach (c; chunk.bytes[from - chunk.start .. end - chunk.start])
            if (c < 0x20 || c > 0x7e) return false;
        from = end;
    }
    return true;
}

private bool before(size_t lineA, size_t rowA, size_t lineB, size_t rowB) @safe pure nothrow @nogc
    => lineA < lineB || lineA == lineB && rowA < rowB;

/**
The top (`line`, `row`) that keeps the primary caret's row in a view of
`visible` rows (`EDR2`), moving as little as possible. It lays out at most
the `visible` rows above the caret, wherever the top was.
*/
void scrollToCaret(ref LayoutContext context, in Text text, CaretTarget caret, size_t visible,
    ref size_t line, ref size_t row) @safe pure nothrow @nogc
{
    if (visible == 0) return;
    const caretLine = text.lineOf(caret.position);
    size_t caretRow;
    {
        ref p = context.paragraph(text, caretLine);
        caretRow = p.rowOf(caret.position, caret.affinity);
    }
    if (line >= text.lineCount) { line = text.lineCount - 1; row = 0; }
    if (row >= context.rowCount(text, line)) row = 0;
    if (before(caretLine, caretRow, line, row))
    {
        line = caretLine;
        row = caretRow;
        return;
    }
    // The highest top that still shows the caret: `visible - 1` rows above it.
    size_t topLine = caretLine, topRow = caretRow, budget = visible - 1;
    while (budget)
    {
        if (topRow >= budget) { topRow -= budget; break; }
        if (topLine == 0) { topRow = 0; break; }
        budget -= topRow + 1;
        --topLine;
        topRow = context.rowCount(text, topLine) - 1;
    }
    if (before(line, row, topLine, topRow))
    {
        line = topLine;
        row = topRow;
    }
}

/**
The visual rows before each logical line of a text, at a layout context's
wrap width (`EDR6`): the scroll position and length of a long document in
rows are lookups, not a walk over its lines. The count is redone in full when
the text or the wrap width changes, and only then.
*/
struct RowIndex
{
    private UniqueBuffer!long prefix;
    private Text counted;
    private size_t countedWrap = size_t.max;

@safe pure nothrow @nogc:

    /// Recount when `text` or `context`'s wrap width changed since the last call.
    void refresh(ref LayoutContext context, in Text text)
    {
        if (countedWrap == context.options.wrapCells && counted == text && prefix.length)
            return;
        const count = text.lineCount;
        prefix.clear(releaseStorage: false);
        long total;
        foreach (line; 0 .. count)
        {
            prefix.put(total);
            total += cast(long) context.rowCount(text, line);
        }
        prefix.put(total);
        counted = Text(text);
        countedWrap = context.options.wrapCells;
    }

    /// Visual rows before logical line `line`; the total past the last line.
    long rowsBefore(size_t line) const
        => !prefix.length ? 0 : line + 1 < prefix.length ? prefix[line] : prefix[prefix.length - 1];

    /// The index of visual row `row` of logical line `line`, from the top of the text.
    long rowOf(size_t line, size_t row) const => rowsBefore(line) + cast(long) row;

    /// The text's visual rows.
    long total() const => rowsBefore(size_t.max - 1);
}

/// A wrapped line counts its rows; the index follows the text and the width.
@("editor.layout.rowIndex")
@safe pure nothrow @nogc unittest
{
    LayoutContext context;
    context.options.wrapCells = 10;
    auto text = Text("short\nalpha beta gamma delta\nend");
    RowIndex index;
    index.refresh(context, text);
    const wrapped = cast(long) context.rowCount(text, 1);
    assert(wrapped > 1);
    assert(index.rowsBefore(0) == 0 && index.rowsBefore(1) == 1 && index.rowsBefore(2) == 1 + wrapped);
    assert(index.rowOf(2, 0) == 1 + wrapped && index.total == 2 + wrapped);
    assert(index.rowsBefore(99) == index.total);
    context.options.wrapCells = 0;
    index.refresh(context, text);
    assert(index.total == 3, "unwrapped: a row a line");
    text = Text("one");
    index.refresh(context, text);
    assert(index.total == 1);
}

/// Move the top (`line`, `row`) by `delta` visual rows (a wheel), within the text.
void scrollRows(ref LayoutContext context, in Text text, long delta, ref size_t line, ref size_t row)
    @safe pure nothrow @nogc
{
    if (line >= text.lineCount) { line = text.lineCount - 1; row = 0; }
    for (; delta > 0; --delta)
    {
        if (row + 1 < context.rowCount(text, line)) ++row;
        else if (line + 1 < text.lineCount) { ++line; row = 0; }
        else break;
    }
    for (; delta < 0; ++delta)
    {
        if (row > 0) --row;
        else if (line > 0) { --line; row = context.rowCount(text, line) - 1; }
        else break;
    }
}

version (unittest)
{
    import sparkles.base.text.seek : isGraphemeBoundary;

    /// A layout of `s` at `wrap` cells.
    ParagraphLayout layoutOf(string s, size_t wrap = 0,
        BidiDirection direction = BidiDirection.automatic) @safe pure nothrow @nogc
        => ParagraphLayout.ofBytes(s, LayoutOptions(wrap, direction));

    /// Row `r`'s clusters left to right, as their start offsets.
    size_t[16] visualStarts(in ParagraphLayout p, size_t r, out size_t n) @safe pure nothrow @nogc
    {
        size_t[16] result;
        n = p.rows[r].last - p.rows[r].first;
        foreach (k; 0 .. n)
            result[k] = p.visualCluster(r, k).start;
        return result;
    }
}

/// Worked example: in `ab אב` (Alef 3–5, Bet 5–7), Bet is drawn left of Alef.
@("editor.layout.mixedRowOrder")
@safe pure nothrow @nogc unittest
{
    const p = layoutOf("ab אב");
    assert(p.rows.length == 1 && !p.rtl && p.rows[0].mixed);
    size_t n;
    const starts = visualStarts(p, 0, n);
    assert(n == 5 && starts[0 .. 5] == [0, 1, 2, 5, 3]);
    // Byte 5 sits between the two letters, at stop 4, whichever side it attaches to.
    assert(p.stopOf(0, 5, Affinity.before) == 4 && p.stopOf(0, 5, Affinity.after) == 4);
    // Byte 3 is ambiguous: after the space (stop 3) or before Alef (stop 5).
    assert(p.stopOf(0, 3, Affinity.before) == 3 && p.stopOf(0, 3, Affinity.after) == 5);
    // EOF follows Bet logically and so draws at Bet's left edge, stop 3.
    assert(p.stopOf(0, 7, Affinity.before) == 3);
}

/// Worked example: an RTL paragraph places its first letter at the right.
@("editor.layout.rtlParagraph")
@safe pure nothrow @nogc unittest
{
    const p = layoutOf("אב");
    assert(p.rtl);
    size_t n;
    const starts = visualStarts(p, 0, n);
    assert(n == 2 && starts[0 .. 2] == [2, 0]);
    assert(p.stopTarget(0, 0) == CaretTarget(4, Affinity.before));
    assert(p.stopTarget(0, 2) == CaretTarget(0, Affinity.after));
}

/// L4: a paired bracket in a right-to-left run draws mirrored.
@("editor.layout.mirroredBrackets")
@safe pure nothrow @nogc unittest
{
    const p = layoutOf("א(ב)");
    assert(p.rtl);
    assert(p.clusters[1].mirrored == ')' && p.clusters[3].mirrored == '(');
    const ltr = layoutOf("a(b)");
    assert(ltr.clusters[1].mirrored == 0);
}

/// Numbers inside an RTL run keep left-to-right order (W/N/I rules, L2).
@("editor.layout.digitsInRtl")
@safe pure nothrow @nogc unittest
{
    // Alef, space, 1, 2: the digits read left to right, left of Alef.
    const p = layoutOf("א 12");
    size_t n;
    const starts = visualStarts(p, 0, n);
    assert(n == 4 && starts[0 .. 4] == [3, 4, 2, 0]);
}

/// Greedy soft wrap at UAX #14 opportunities; trailing spaces hang.
@("editor.layout.softWrap")
@safe pure nothrow @nogc unittest
{
    const p = layoutOf("aaa bbb ccc", 7);
    assert(p.rows.length == 2);
    assert(p.rows[0].start == 0 && p.rows[0].end == 8);
    assert(p.rows[1].start == 8 && p.rows[1].end == 11);
    // A word longer than a row breaks at a grapheme.
    const long_ = layoutOf("abcdefgh", 3);
    assert(long_.rows.length == 3 && long_.rows[2].start == 6);
    // At the wrap, `before` is the first row's end and `after` the second's start.
    assert(p.rowOf(8, Affinity.before) == 0 && p.rowOf(8, Affinity.after) == 1);
}

/// Wide clusters wrap by cells, not bytes; whole graphemes stay together.
@("editor.layout.wideAndCombining")
@safe pure nothrow @nogc unittest
{
    const p = layoutOf("世界世界", 5);
    assert(p.rows.length == 2 && p.rows[0].cells == 4 && p.rows[1].cells == 4);
    const marks = layoutOf("ééé", 2);
    assert(marks.rows.length == 2 && marks.rows[0].end == 6);
    foreach (r; 0 .. marks.rows.length)
        assert(isGraphemeBoundary("ééé", marks.rows[r].start));
}

/// Worked motion: the step's queries through the layout context.
@("editor.layout.context.visualMotion")
@safe pure nothrow @nogc unittest
{
    const text = Text("ab אב");
    LayoutContext c;
    // Rightwards from byte 2: space, Bet, Alef; the row's right edge stops.
    auto at = c.horizontalCaret(text, EditRange.caret(2), 1, false);
    assert(at == CaretTarget(3, Affinity.before));
    at = c.horizontalCaret(text, EditRange(3, 3, Affinity.before), 1, false);
    assert(at == CaretTarget(5, Affinity.after));
    at = c.horizontalCaret(text, EditRange(5, 5, Affinity.after), 1, false);
    assert(at == CaretTarget(3, Affinity.after));
    at = c.horizontalCaret(text, EditRange(3, 3, Affinity.after), 1, false);
    assert(at == CaretTarget(3, Affinity.after), "no row past the right edge");
    // And back.
    at = c.horizontalCaret(text, EditRange(3, 3, Affinity.after), -1, false);
    assert(at == CaretTarget(5, Affinity.before));
    at = c.horizontalCaret(text, EditRange(5, 5, Affinity.before), -1, false);
    assert(at == CaretTarget(7, Affinity.before));
    at = c.horizontalCaret(text, EditRange(7, 7, Affinity.before), -1, false);
    assert(at == CaretTarget(2, Affinity.after));
}

/// Collapse goes to the selection's visual edge on its row.
@("editor.layout.context.collapse")
@safe pure nothrow @nogc unittest
{
    const text = Text("ab אב");
    LayoutContext c;
    // Alef selected forwards, [3, 5): visually Alef's left edge is byte 5.
    const range = EditRange(3, 5, Affinity.before);
    assert(c.horizontalCaret(text, range, -1, false).position == 5);
    assert(c.horizontalCaret(text, range, 1, false).position == 3);
}

/// Soft-wrapped rows: Right crosses the wrap without resting twice on one byte.
@("editor.layout.context.wrapCrossing")
@safe pure nothrow @nogc unittest
{
    const text = Text("aaa bbb\nc");
    LayoutContext c;
    c.options.wrapCells = 4;
    // Rows: "aaa " [0,4), "bbb" [4,7); then line 1 "c".
    const end = CaretTarget(4, Affinity.before);
    assert(c.horizontalCaret(text, EditRange(4, 4, Affinity.before), 1, false)
        == CaretTarget(5, Affinity.before));
    assert(c.lineAt(text, 4, Affinity.before) == VisualLine(0, 4));
    assert(c.lineAt(text, 4, Affinity.after) == VisualLine(4, 7));
    // Across the logical break, Right lands on the next line's start.
    assert(c.horizontalCaret(text, EditRange(7, 7), 1, false) == CaretTarget(8, Affinity.after));
    // End and Home on the second row.
    assert(c.lineBoundaryCaret(text, 5, Affinity.before, Boundary.end) == CaretTarget(7, Affinity.before));
    assert(c.lineBoundaryCaret(text, 6, Affinity.before, Boundary.start) == CaretTarget(4, Affinity.after));
    cast(void) end;
    // Rows below and above cross paragraphs.
    VisualLine below;
    assert(c.lineBelow(text, VisualLine(4, 7), below) && below == VisualLine(8, 9));
    VisualLine above;
    assert(c.lineAbove(text, VisualLine(8, 9), above) && above == VisualLine(4, 7));
    // A goal column on the next row keeps the row's own side of the wrap.
    assert(c.caretAt(text, VisualLine(4, 7), 0) == CaretTarget(4, Affinity.after));
    assert(c.caretAt(text, VisualLine(0, 4), 9) == CaretTarget(4, Affinity.before));
}

/// Home/End on an RTL row are its visual left and right edges.
@("editor.layout.context.rtlHomeEnd")
@safe pure nothrow @nogc unittest
{
    const text = Text("אב");
    LayoutContext c;
    assert(c.lineBoundaryCaret(text, 2, Affinity.before, Boundary.start) == CaretTarget(4, Affinity.before));
    assert(c.lineBoundaryCaret(text, 2, Affinity.before, Boundary.end) == CaretTarget(0, Affinity.after));
    // An LTR row keeps smart Home.
    const indented = Text("  x");
    assert(c.lineBoundaryCaret(indented, 0, Affinity.before, Boundary.start).position == 2);
    assert(c.lineBoundaryCaret(indented, 3, Affinity.before, Boundary.start).position == 0);
}

/// Scrolling counts visual rows and moves the top as little as possible.
@("editor.layout.scrollToCaret")
@safe pure nothrow @nogc unittest
{
    const text = Text("aaaa bbbb cccc\nd");
    LayoutContext c;
    c.options.wrapCells = 5;
    size_t line, row;
    scrollToCaret(c, text, CaretTarget(15, Affinity.before), 2, line, row);
    assert(line == 0 && row == 2);
    scrollToCaret(c, text, CaretTarget(0, Affinity.before), 2, line, row);
    assert(line == 0 && row == 0);
    c.originLine = 0;
    assert(c.caretArea(text, 15, 0) == Rect(0, 3, 1, 1));
}

// ------------------------------------------------- review regressions (agy, 2026-11-14)

/// An origin past the text (lines deleted while scrolled) is read as its last line.
@("editor.layout.review.caretAreaOriginPastText")
@safe pure nothrow @nogc unittest
{
    const text = Text("a");
    LayoutContext c;
    c.options.wrapCells = 10;
    c.originLine = 3;
    c.originRow = 2;
    assert(c.caretArea(text, 0, 0) == Rect(0, 0, 1, 1));
}

/// X9-removed clusters (ZWSP, word joiner) do not split a right-to-left run.
@("editor.layout.review.removedClustersKeepRun")
@safe pure nothrow @nogc unittest
{
    size_t n;
    auto p = layoutOf("ab א​ב");
    auto starts = visualStarts(p, 0, n);
    assert(n == 6 && starts[0 .. 6] == [0, 1, 2, 8, 5, 3]);
    p = layoutOf("ab א⁠ב");
    starts = visualStarts(p, 0, n);
    assert(n == 6 && starts[0 .. 6] == [0, 1, 2, 8, 5, 3]);
}

/// A paragraph separator inside the line (a lone CR) ends a bidi paragraph
/// rather than disabling bidi for the line.
@("editor.layout.review.separatorInsideLine")
@safe pure nothrow @nogc unittest
{
    const p = layoutOf("אב\rגד");
    assert(p.rtl);
    size_t n;
    const starts = visualStarts(p, 0, n);
    assert(n == 5 && starts[0 .. 5] == [7, 5, 4, 2, 0]);
}

/// A click on the cluster right of an ambiguous stop takes its left edge:
/// the logical end of `ab אב` is reachable.
@("editor.layout.review.clickSideAtBidiStop")
@safe pure nothrow @nogc unittest
{
    const text = Text("ab אב");
    LayoutContext c;
    const row = VisualLine(0, 7);
    assert(c.caretAt(text, row, 3) == CaretTarget(7, Affinity.before), "on Bet");
    assert(c.caretAt(text, row, 2) == CaretTarget(2, Affinity.after), "on the space");
    assert(c.caretAt(text, row, 9) == CaretTarget(3, Affinity.after), "past the row");
}

/// Collapse uses each endpoint's inner side, whichever way the selection runs.
@("editor.layout.review.collapseBackwardSelection")
@safe pure nothrow @nogc unittest
{
    const text = Text("ab אב");
    LayoutContext c;
    // [3, 7) selected backwards: visually stops 3 (byte 7) to 5 (byte 3).
    const backward = EditRange(7, 3, Affinity.before);
    assert(c.horizontalCaret(text, backward, 1, false) == CaretTarget(3, Affinity.after));
    assert(c.horizontalCaret(text, backward, -1, false) == CaretTarget(7, Affinity.before));
    // Across lines the same bytes collapse alike in either direction.
    const lines = Text("abc\nאב");
    assert(c.horizontalCaret(lines, EditRange(1, 6), -1, false).position
        == c.horizontalCaret(lines, EditRange(6, 1), -1, false).position);
}

/// Held Right progresses from an LTR line into an RTL one without bouncing.
@("editor.layout.review.noParagraphBounce")
@safe pure nothrow @nogc unittest
{
    const text = Text("abc\nאב");
    LayoutContext c;
    auto at = CaretTarget(3, Affinity.before);
    size_t[4] seen;
    foreach (i; 0 .. 4)
    {
        at = c.horizontalCaret(text, EditRange(at.position, at.position, at.affinity), 1, false);
        seen[i] = at.position;
    }
    // Bet's left edge (EOF), Alef's left edge, then the row's right edge, then stay.
    assert(seen == [8, 6, 4, 4]);
    // And Left from the RTL line's left edge returns to the line above.
    assert(c.horizontalCaret(text, EditRange(8, 8, Affinity.before), -1, false).position == 3);
}

/// A row after a break is checked again: no multi-cluster row exceeds the width.
@("editor.layout.review.wrapRecheck")
@safe pure nothrow @nogc unittest
{
    foreach (s; [" ((世", "​aaaaa"])
    {
        const p = layoutOf(s, s[0] == ' ' ? 3 : 4);
        foreach (r; 0 .. p.rows.length)
            assert(p.rows[r].cells <= (s[0] == ' ' ? 3 : 4) || p.rows[r].last - p.rows[r].first == 1);
    }
}

/// The IME area follows the caret's affinity across a soft wrap and a bidi boundary.
@("editor.layout.review.caretAreaAffinity")
@safe pure nothrow @nogc unittest
{
    LayoutContext c;
    c.options.wrapCells = 4;
    assert(c.caretArea(Text("aaa bbb"), CaretTarget(4, Affinity.after), 0) == Rect(0, 1, 1, 1));
    LayoutContext d;
    assert(d.caretArea(Text("ab אב"), CaretTarget(3, Affinity.after), 0) == Rect(5, 0, 1, 1));
}

/// Smart Home stays on an all-blank row and keeps the caret's side when it does not move.
@("editor.layout.review.homeEdges")
@safe pure nothrow @nogc unittest
{
    LayoutContext c;
    c.options.wrapCells = 4;
    const blank = Text("     abc");
    assert(c.lineBoundaryCaret(blank, 0, Affinity.after, Boundary.start) == CaretTarget(5, Affinity.before));
    LayoutContext d;
    assert(d.lineBoundaryCaret(Text("abc"), 0, Affinity.before, Boundary.start)
        == CaretTarget(0, Affinity.before));
}

/// Scrolling far lays out only the rows above the caret; the wheel moves by rows.
@("editor.layout.review.scrollByRows")
@safe pure nothrow @nogc unittest
{
    const text = Text("aaaa bbbb cccc\nd");
    LayoutContext c;
    c.options.wrapCells = 5;
    size_t line, row;
    scrollRows(c, text, 2, line, row);
    assert(line == 0 && row == 2);
    scrollRows(c, text, 5, line, row);
    assert(line == 1 && row == 0);
    scrollRows(c, text, -2, line, row);
    assert(line == 0 && row == 1);
}

/// A short line counts as one row without a layout, and agrees with one: wide
/// and combining clusters included, at the bound and either side of it.
@("editor.layout.rowCountShortLines")
@safe pure nothrow unittest
{
    foreach (content; ["ab", "日本", "éé", "a\tb", "👍🏽x", "abcd ef", "int x = 1; // y", "a\x01b c"])
        foreach (wrap; [1, 2, 3, 4, 6, 8, 12, 16])
        {
            const text = Text(content);
            LayoutContext c;
            c.options.wrapCells = wrap;
            assert(c.rowCount(text, 0) == ParagraphLayout.of(text, 0, c.options).rows.length, content);
        }
}
