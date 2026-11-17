/**
The editor's view (`EDR1`, `EDR2`, `EDR5`): an `EditorState` drawn through
the standard widget pipeline, alike on every backend.

Each logical line is one rich run. It is cut at every selection edge,
caret and read-only edge. Selected text paints on the `selection` slot,
read-only text on the read-only slot, and each caret is the `caret` slot's
`▏` where the primary range's head is, or every range's head with several.
Every span carries its source byte range, so the layout's hit test
(`sourceOffsetAt`) maps a pointer back to a text position, and the caret
is drawn where motion believes it is.

Specification: `docs/specs/ui/editor.md` §7.
*/
module sparkles.ui.components.editor;

import sparkles.base.term_style : UnderlineStyle;
import sparkles.input.events : CompositionStyle;
import sparkles.text_buffer.text : Text;
import sparkles.ui.editor.selection : EditRange;
import sparkles.ui.editor.layout : ParagraphLayout;
import sparkles.ui.editor.state : EditorState, ReadOnlySpan;
import sparkles.ui.style : Slot;
import sparkles.ui.geometry : SizeSpec;
import sparkles.ui.widget : Builder, TextSpan, Widget, WidgetKind;

/// How an editor is drawn.
struct EditorViewOptions
{
    /// Draw carets: the editor has focus and the blink (`STM6`) is on.
    bool caretVisible = true;
    /// Shown, muted, while the text is empty.
    string placeholder;
    /// The editable text's slot.
    Slot textSlot = Slot.inherit;
    /// Read-only spans' slot, distinct from editable text (`EDR5`).
    Slot readOnlySlot = Slot.muted;
    /// Lines to show from `firstLine` (multi-line); 0 shows all.
    size_t visibleLines;
    /// The first line shown.
    size_t firstLine;
    /**
    Leave the caret to the host (ui-app `HST20`): no `▏` is inserted, so no
    character moves with the caret, and the caret line's node carries the
    primary caret's column in `caretColumn`. Only the primary caret is shown
    this way; while composing, the preedit's own caret is drawn as before.
    */
    bool hostCursor;
}

/// The caret glyph.
enum string caretGlyph = "▏";

/**
The spans of logical line `line` of `state`. Text spans borrow nothing: they
hold copies, so the tree outlives the state.
*/
TextSpan[] editorLineSpans(in EditorState state, size_t line, in EditorViewOptions options)
    @safe pure nothrow
{
    import sparkles.base.text.seek : nextGraphemeBoundary;

    const text = state.text;
    const start = text.lineStart(line);
    const end = text.lineEnd(line);
    const ranges = state.selection.ranges;
    const several = ranges.length > 1;
    const primaryIndex = state.selection.primaryIndex;
    const composing = state.composition.active;

    // With the host's cursor (`HST20`) the primary caret needs no cut and
    // no glyph. A secondary caret marks the grapheme under it as a block, so
    // every caret is visible and still no character moves.
    bool secondaryBlock(size_t j, in EditRange r)
        => options.hostCursor && options.caretVisible && several && !composing && r.empty
            && j != primaryIndex && r.head < end;

    // Every place the styling can change, sorted and unique.
    size_t[] cuts = [start, end];
    foreach (j, r; ranges)
    {
        if (secondaryBlock(j, r))
            cuts ~= [r.head, nextGraphemeBoundary(text, r.head)];
        else if (!(options.hostCursor && r.empty))
            cuts ~= [r.start, r.end, r.head]; // the host's cursor needs no cut
    }
    foreach (span; state.readOnly[])
        cuts ~= [span.start, span.end];
    size_t[] inLine;
    foreach (c; cuts)
        if (c >= start && c <= end)
            inLine ~= c;
    sortUnique(inLine);

    // EDI3: while composing, each range shows the preedit in its place, and
    // the caret is the preedit's cursor (the host's, in host-cursor mode).
    TextSpan[] spans;
    foreach (i, at; inLine)
    {
        foreach (j, r; ranges)
            if (composing && r.start == at)
            {
                const caret = options.caretVisible && !options.hostCursor
                    && (several || j == primaryIndex);
                preeditSpans(state, options, caret, spans);
                break;
            }
            else if (!composing && options.caretVisible && !options.hostCursor && r.head == at
                && (several || j == primaryIndex))
            {
                spans ~= TextSpan(text: caretGlyph, slot: Slot.caret);
                break;
            }
        if (i + 1 == inLine.length)
            break;
        const next = inLine[i + 1];
        if (next == at || composing && insideRange(ranges, at, next))
            continue;
        auto bytes = new char[next - at];
        text.copyTo(at, next, bytes);
        auto span = TextSpan(text: bytes, slot: options.textSlot, srcStart: at, srcEnd: next);
        foreach (ro; state.readOnly[])
            if (at >= ro.start && next <= ro.end)
                span.slot = options.readOnlySlot;
        foreach (r; ranges)
            if (!r.empty && at >= r.start && next <= r.end)
            {
                span.slot = Slot.selection;
                span.paintBackground = true;
            }
        foreach (j, r; ranges)
            if (secondaryBlock(j, r) && at == r.head)
            {
                span.slot = Slot.caret;
                span.paintBackground = true;
            }
        spans ~= span;
    }
    return spans;
}

/// Whether `[from, to)` lies inside a non-empty range: text a composition
/// shows its preedit in place of.
private bool insideRange(scope const(EditRange)[] ranges, size_t from, size_t to)
    @safe pure nothrow @nogc
{
    foreach (r; ranges)
        if (!r.empty && from >= r.start && to <= r.end)
            return true;
    return false;
}

/**
The preedit's spans (`EDR1`), cut at its styled runs and its cursor: an
`underline` run is underlined, a `converted` one underlined twice, and a
`selected` one painted as a selection.
*/
private void preeditSpans(in EditorState state, in EditorViewOptions options, bool caret,
    ref TextSpan[] spans) @safe pure nothrow
{
    const composition = state.composition;
    size_t[] cuts = [0, composition.preedit.length, composition.cursor];
    foreach (run; composition.styled)
        cuts ~= [run.start, run.start + run.length];
    sortUnique(cuts);
    foreach (i, at; cuts)
    {
        if (caret && at == composition.cursor)
            spans ~= TextSpan(text: caretGlyph, slot: Slot.caret);
        if (i + 1 == cuts.length)
            break;
        const next = cuts[i + 1];
        auto bytes = new char[next - at];
        composition.preedit.copyTo(at, next, bytes);
        auto span = TextSpan(text: bytes, slot: options.textSlot);
        foreach (run; composition.styled)
            if (at >= run.start && next <= run.start + run.length)
                final switch (run.style)
                {
                case CompositionStyle.none:
                    break;
                case CompositionStyle.underline:
                    span.textStyle.underline = UnderlineStyle.single;
                    break;
                case CompositionStyle.converted:
                    span.textStyle.underline = UnderlineStyle.double_;
                    break;
                case CompositionStyle.selected:
                    span.slot = Slot.selection;
                    span.paintBackground = true;
                    break;
                }
        spans ~= span;
    }
}

/// One visual row of a laid-out line, ready to draw (`EAP17`).
struct VisualRow
{
    /// The row's index in its paragraph.
    size_t row;
    /// Its spans, left to right.
    TextSpan[] spans;
    /// Inserted spans (carets, a preedit) as `[stop, cells, hidden]`, left to
    /// right: drawn cells that are not the layout's, and the layout cells of
    /// the text a preedit hides in their place.
    size_t[3][] inserted;
    /// The primary caret's drawn column on this row, for the host's cursor
    /// (`HST20`): after the row's inserted cells and a preedit's cursor; -1
    /// where the caret is on another row.
    int caretColumn = -1;
}

/**
The visual rows of one logical line: `logical` (from `editorLineSpans` or a
decorated form of it, such as highlighted spans) projected onto `layout`.

Each cluster draws with the styling of the span covering its source bytes, in
the row's visual order; a right-to-left cluster is its own span, and a lone
mirrored scalar draws its L4 mirror. Spans without source bytes — carets and
a preedit — are drawn at the caret stop of their position, on the side of a
soft wrap or bidi boundary that the range's affinity names. A preedit stands
at its range's start, in place of the selected text it replaces.
*/
VisualRow[] visualRows(scope const(TextSpan)[] logical, in ParagraphLayout layout, in EditorState state,
    size_t firstRow = 0, size_t rowLimit = size_t.max) @safe pure nothrow
{
    import sparkles.text_buffer.summary : Affinity;

    static struct Group { size_t position; size_t first, last; size_t row, stop, hidden; Affinity affinity; }
    Group[] groups;
    size_t[] textSpans;
    size_t cursor = layout.start;
    const composing = state.composition.active;
    foreach (i, ref span; logical)
    {
        if (span.srcStart != size_t.max && span.srcEnd - span.srcStart == span.text.length)
        {
            textSpans ~= i;
            cursor = span.srcEnd;
            continue;
        }
        // Adjacent inserted spans (a preedit and its cursor) are one group.
        if (groups.length && groups[$ - 1].last == i)
        {
            groups[$ - 1].last = i + 1;
            continue;
        }
        Group g = Group(cursor, i, i + 1);
        foreach (j, r; state.selection.ranges)
        {
            const primary = j == state.selection.primaryIndex;
            if (composing && r.start == cursor)
            {
                // The preedit replaces `[start, end)`: drawn from its start.
                g.affinity = r.empty ? r.affinity : Affinity.before;
                if (!r.empty)
                {
                    foreach (c; layout.clusters[])
                        if (c.start >= r.start && c.end <= r.end) g.hidden += c.cells;
                    cursor = r.end;
                }
                break;
            }
            if (!composing && r.head == cursor && (primary || g.affinity == Affinity.before))
                g.affinity = r.affinity;
        }
        groups ~= g;
    }
    foreach (ref g; groups)
    {
        g.row = layout.rowOf(g.position, g.affinity);
        g.stop = layout.stopOf(g.row, g.position, g.affinity);
    }

    // Where the primary caret is drawn: a preedit stands at its range's start.
    const primary = state.selection.primary;
    const caretAt = composing ? primary.start : primary.head;
    const caretAffinity = composing && !primary.empty ? Affinity.before : primary.affinity;
    size_t caretRow = size_t.max, caretStop;
    long preeditCells;
    if (caretAt >= layout.start && caretAt <= layout.end)
    {
        caretRow = layout.rowOf(caretAt, caretAffinity);
        caretStop = layout.stopOf(caretRow, caretAt, caretAffinity);
        if (composing)
        {
            auto before = new char[state.composition.cursor];
            state.composition.preedit.copyTo(0, before.length, before);
            preeditCells = textCells(before);
        }
    }

    VisualRow[] rows;
    // Only the rows asked for are projected: a long paragraph costs its window.
    const rowCount = layout.rows.length;
    const beginRow = firstRow < rowCount ? firstRow : rowCount;
    const endRow = rowLimit < rowCount - beginRow ? beginRow + rowLimit : rowCount;
    foreach (r; beginRow .. endRow)
    {
        VisualRow row;
        row.row = r;
        const count = layout.rows[r].last - layout.rows[r].first;
        size_t previous = size_t.max; // the logical span the last emitted LTR run came from
        void insertAt(size_t k)
        {
            foreach (g; groups)
                if (g.row == r && g.stop == k)
                {
                    size_t cells;
                    foreach (s; logical[g.first .. g.last])
                    {
                        row.spans ~= s;
                        cells += textCells(s.text);
                    }
                    row.inserted ~= [k, cells, g.hidden];
                    previous = size_t.max;
                }
        }
        foreach (k; 0 .. count)
        {
            insertAt(k);
            const cluster = layout.visualCluster(r, k);
            // The text span covering the cluster's first byte: text spans are
            // in source order, so the last one starting at or before it.
            size_t covering = size_t.max;
            {
                size_t lo = 0, hi = textSpans.length;
                while (lo < hi)
                {
                    const mid = (lo + hi) / 2;
                    if (logical[textSpans[mid]].srcStart <= cluster.start) lo = mid + 1;
                    else hi = mid;
                }
                if (lo && cluster.start < logical[textSpans[lo - 1]].srcEnd)
                    covering = textSpans[lo - 1];
            }
            if (covering == size_t.max)
            {
                previous = size_t.max;
                continue; // hidden: a preedit replaces it
            }
            const span = logical[covering];
            if (!cluster.rtl && previous == covering && row.spans.length
                && row.spans[$ - 1].srcEnd == cluster.start && cluster.end <= span.srcEnd)
            {
                auto last = &row.spans[$ - 1];
                last.text = span.text[last.srcStart - span.srcStart .. cluster.end - span.srcStart];
                last.srcEnd = cluster.end;
                continue;
            }
            TextSpan drawn = span;
            drawn.srcStart = cluster.start;
            drawn.srcEnd = cluster.end;
            if (cluster.mirrored)
                drawn.text = encodeScalar(cluster.mirrored);
            else if (cluster.end <= span.srcEnd)
                drawn.text = span.text[cluster.start - span.srcStart .. cluster.end - span.srcStart];
            else
            {
                // A cluster split between spans draws whole, styled as its start.
                char[] bytes = span.text[cluster.start - span.srcStart .. $].dup;
                foreach (t; textSpans)
                    if (logical[t].srcStart > span.srcStart && logical[t].srcStart < cluster.end)
                        bytes ~= logical[t].text[0 .. (cluster.end < logical[t].srcEnd ? cluster.end : logical[t].srcEnd)
                            - logical[t].srcStart];
                drawn.text = bytes;
            }
            row.spans ~= drawn;
            previous = cluster.rtl ? size_t.max : covering;
        }
        insertAt(count);
        // The primary caret's drawn column: its stop's cells, the inserted
        // cells left of it, and while composing the preedit's cursor.
        if (r == caretRow)
        {
            long x = layout.stopCells(r, caretStop);
            foreach (inserted; row.inserted)
                if (inserted[0] < caretStop) x += cast(long) inserted[1] - cast(long) inserted[2];
            row.caretColumn = cast(int)(x + preeditCells);
        }
        rows ~= row;
    }
    return rows;
}

/**
The layout column under drawn column `column` of `row`: inserted cells to
its left are not the layout's, text a preedit hides is, and a column inside
an inserted span is the stop it was inserted at.
*/
size_t layoutColumn(in VisualRow row, in ParagraphLayout layout, size_t column) @safe pure nothrow @nogc
{
    long shift; // drawn minus layout cells left of the column
    foreach (inserted; row.inserted)
    {
        const at = cast(long) layout.stopCells(row.row, inserted[0]) + shift;
        if (column < at)
            break;
        if (column < at + cast(long) inserted[1])
            return cast(size_t)(at - shift);
        shift += cast(long) inserted[1] - cast(long) inserted[2];
    }
    const result = cast(long) column - shift;
    return result < 0 ? 0 : cast(size_t) result;
}

/// A source range painted over a line's text; see `sparkles.ui.editor.presentation`.
public import sparkles.ui.editor.presentation : TextMark;

/**
`logical` with `marks` painted: text spans are cut at mark edges and the
marked part fills its mark's background, keeping its syntax ink. Selected
text and carets keep their own slot, so a selection stays legible over a
match; where marks overlap, the later one wins. Inserted spans pass through.
*/
TextSpan[] markSpans(scope const(TextSpan)[] logical, scope const(TextMark)[] marks)
    @safe pure nothrow
{
    TextSpan[] result;
    foreach (ref span; logical)
    {
        const isText = span.srcStart != size_t.max && span.srcEnd - span.srcStart == span.text.length;
        bool touched;
        foreach (m; marks)
            touched |= m.start < m.end && m.start < span.srcEnd && m.end > span.srcStart;
        if (!isText || !touched || span.slot == Slot.selection || span.slot == Slot.caret)
        {
            result ~= span;
            continue;
        }
        size_t[] cuts = [span.srcStart, span.srcEnd];
        foreach (m; marks)
        {
            if (m.start > span.srcStart && m.start < span.srcEnd) cuts ~= m.start;
            if (m.end > span.srcStart && m.end < span.srcEnd) cuts ~= m.end;
        }
        sortUnique(cuts);
        foreach (i; 0 .. cuts.length - 1)
        {
            TextSpan piece = span;
            piece.text = span.text[cuts[i] - span.srcStart .. cuts[i + 1] - span.srcStart];
            piece.srcStart = cuts[i];
            piece.srcEnd = cuts[i + 1];
            foreach (m; marks)
                if (m.start < m.end && m.start <= cuts[i] && cuts[i + 1] <= m.end)
                {
                    piece.slot = m.slot;
                    piece.paintBackground = true;
                    piece.hasBg = false;
                }
            result ~= piece;
        }
    }
    return result;
}

/// A match paints its bytes and keeps syntax ink; a selection stays on top.
@("editor.view.markSpans")
@safe pure nothrow unittest
{
    import sparkles.ui.editor.testing : parse;
    auto state = parse("[ab]cdef|");
    TextMark[2] marks = [TextMark(1, 3), TextMark(4, 5, Slot.error)];
    auto logical = editorLineSpans(state, 0, EditorViewOptions(hostCursor: true));
    logical[$ - 1].hasFg = true;
    const spans = markSpans(logical, marks[]);
    string drawn;
    foreach (s; spans)
        drawn ~= s.slot == Slot.selection ? "[" ~ s.text ~ "]"
            : s.slot == Slot.highlight ? "{" ~ s.text ~ "}"
            : s.slot == Slot.error ? "<" ~ s.text ~ ">" : s.text;
    assert(drawn == "[ab]{c}d<e>f", drawn);
    foreach (s; spans)
        if (s.slot == Slot.error) assert(s.hasFg && s.paintBackground);
}

/**
Indentation guides on the first row of a left-to-right line (`EAP5`): each
leading space at an indentation stop (`0`, `width`, `2 * width`, …) before the
line's first other character draws `glyph` in `slot`. The glyph is one cell
and keeps its source bytes, so no text moves and hits are unchanged. A tab, a
preedit or any other character ends the leading run.
*/
void drawIndentGuides(ref VisualRow row, in ParagraphLayout layout, size_t width,
    Slot slot = Slot.textDisabled, string glyph = "│") @safe pure nothrow
{
    if (row.row != 0 || layout.rtl || width == 0)
        return;
    TextSpan[] spans;
    size_t column;
    bool leading = true;
    foreach (ref span; row.spans)
    {
        if (!leading || span.srcStart == size_t.max || span.srcEnd - span.srcStart != span.text.length)
        {
            leading = false;
            spans ~= span;
            continue;
        }
        size_t blanks;
        while (blanks < span.text.length && span.text[blanks] == ' ') ++blanks;
        size_t from;
        foreach (i; 0 .. blanks)
        {
            if ((column + i) % width != 0)
                continue;
            if (i > from)
                spans ~= piece(span, from, i);
            auto guide = piece(span, i, i + 1);
            guide.text = glyph;
            guide.slot = slot;
            guide.hasFg = false;
            guide.srcEnd = guide.srcStart + 1;
            spans ~= guide;
            from = i + 1;
        }
        if (from < span.text.length)
            spans ~= piece(span, from, span.text.length);
        column += blanks;
        leading = blanks == span.text.length;
    }
    row.spans = spans;
}

private TextSpan piece(return scope const TextSpan span, size_t from, size_t to) @safe pure nothrow @nogc
{
    TextSpan result = span;
    result.text = span.text[from .. to];
    result.srcStart = span.srcStart + from;
    result.srcEnd = span.srcStart + to;
    return result;
}

/// Guides stand at each stop of the leading spaces; text keeps its columns.
@("editor.view.indentGuides")
@safe pure nothrow unittest
{
    import sparkles.ui.editor.layout : LayoutOptions, ParagraphLayout;
    import sparkles.ui.editor.testing : parse;
    auto state = parse("|      x  y");
    const layout = ParagraphLayout.of(state.text, 0, LayoutOptions.init);
    auto rows = visualRows(editorLineSpans(state, 0, EditorViewOptions(hostCursor: true)), layout, state);
    drawIndentGuides(rows[0], layout, 4);
    string drawn;
    size_t cells;
    foreach (s; rows[0].spans)
    {
        drawn ~= s.text;
        cells += s.srcEnd - s.srcStart;
    }
    assert(drawn == "│   │ x  y", drawn);
    assert(cells == 10);
}

/// A preedit replacing selected text: hits past it land on the text after
/// the hidden selection.
@("editor.view.visualRows.compositionHidesSelection")
@safe pure nothrow unittest
{
    import sparkles.ui.editor.layout : LayoutOptions, ParagraphLayout;
    import sparkles.ui.editor.testing : parse;

    auto state = parse("a[bc]d");
    state.composition.preedit = Text("にほ");
    state.composition.cursor = 3;
    const layout = ParagraphLayout.of(state.text, 0, LayoutOptions.init);
    const rows = visualRows(editorLineSpans(state, 0, EditorViewOptions.init), layout, state);
    string drawn;
    foreach (s; rows[0].spans) drawn ~= s.text;
    assert(drawn == "aに" ~ caretGlyph ~ "ほd", drawn);
    assert(rows[0].inserted == [[1, 5, 2]]);
    // Drawn cell 6 is `d`: layout column 3.
    assert(layoutColumn(rows[0], layout, 6) == 3);
    assert(layoutColumn(rows[0], layout, 3) == 1, "inside the preedit: its stop");
}

private size_t textCells(scope const(char)[] text) @safe pure nothrow
{
    import sparkles.base.text.seek : nextGraphemeBoundary;
    import sparkles.ui.editor.context : clusterCells;

    const whole = Text(text);
    size_t cells;
    for (size_t at; at < text.length;)
    {
        const next = nextGraphemeBoundary(text, at);
        cells += clusterCells(whole, at, next);
        at = next;
    }
    return cells;
}

private string encodeScalar(dchar c) @safe pure nothrow
{
    char[] bytes;
    if (c < 0x80)
        bytes = [cast(char) c];
    else if (c < 0x800)
        bytes = [cast(char)(0xC0 | c >> 6), cast(char)(0x80 | c & 0x3F)];
    else if (c < 0x10000)
        bytes = [cast(char)(0xE0 | c >> 12), cast(char)(0x80 | c >> 6 & 0x3F), cast(char)(0x80 | c & 0x3F)];
    else
        bytes = [cast(char)(0xF0 | c >> 18), cast(char)(0x80 | c >> 12 & 0x3F),
            cast(char)(0x80 | c >> 6 & 0x3F), cast(char)(0x80 | c & 0x3F)];
    return (() @trusted => cast(string) bytes)(); // unique and never written again
}

/// A mixed row draws Bet left of Alef, and the caret at its affinity's side.
@("editor.view.visualRows.mixed")
@safe pure nothrow unittest
{
    import sparkles.text_buffer.summary : Affinity;
    import sparkles.ui.editor.layout : LayoutOptions, ParagraphLayout;
    import sparkles.ui.editor.selection : SelectionSet;

    auto state = EditorState.create("ab אב");
    state.selection = SelectionSet.single(EditRange(3, 3, Affinity.after));
    const layout = ParagraphLayout.of(state.text, 0, LayoutOptions.init);
    const rows = visualRows(editorLineSpans(state, 0, EditorViewOptions.init), layout, state);
    assert(rows.length == 1);
    string drawn;
    foreach (s; rows[0].spans)
        drawn ~= s.text;
    // Byte 3 after: before Alef, which is drawn rightmost.
    assert(drawn == "ab בא" ~ caretGlyph, drawn);
    assert(rows[0].inserted == [[5, 1, 0]]);
    assert(layoutColumn(rows[0], layout, 6) == 5);
    // Before: after the space.
    state.selection = SelectionSet.single(EditRange(3, 3, Affinity.before));
    drawn = null;
    foreach (s; visualRows(editorLineSpans(state, 0, EditorViewOptions.init), layout, state)[0].spans)
        drawn ~= s.text;
    assert(drawn == "ab " ~ caretGlyph ~ "בא", drawn);
}

/// Wrapped rows each draw their own clusters; selection styling follows the bytes.
@("editor.view.visualRows.wrapped")
@safe pure nothrow unittest
{
    import sparkles.ui.editor.layout : LayoutOptions, ParagraphLayout;
    import sparkles.ui.editor.selection : SelectionSet;

    auto state = EditorState.create("aaa bbb");
    state.selection = SelectionSet.single(EditRange(2, 5));
    const layout = ParagraphLayout.of(state.text, 0, LayoutOptions(4));
    const rows = visualRows(editorLineSpans(state, 0, EditorViewOptions.init), layout, state);
    assert(rows.length == 2);
    string first, second;
    foreach (s; rows[0].spans) first ~= s.text ~ (s.slot == Slot.selection ? "#" : "") ~ "|";
    foreach (s; rows[1].spans) second ~= s.text ~ (s.slot == Slot.selection ? "#" : "") ~ "|";
    assert(first == "aa|a #|", first);
    assert(second == "b#|" ~ caretGlyph ~ "|bb|", second);
}

/// The editor as one node: a rich run for a single line, else a column of
/// them from `options.firstLine`.
uint editorView(ref Builder b, in EditorState state, EditorViewOptions options = EditorViewOptions.init)
    @safe
{
    if (state.text.length == 0 && !state.composition.active && options.placeholder.length)
    {
        TextSpan[] spans;
        if (options.caretVisible && !options.hostCursor)
            spans ~= TextSpan(text: caretGlyph, slot: Slot.caret);
        spans ~= TextSpan(text: options.placeholder, slot: Slot.muted);
        // The host's cursor stands before the placeholder, at column 0.
        return b.add(Widget(kind: WidgetKind.rich, spans: spans, width: SizeSpec.grow(),
            caretColumn: options.hostCursor && options.caretVisible ? 0 : -1));
    }
    const lines = state.text.lineCount;
    const caretLine = state.text.lineOf(state.selection.primary.head);
    // The host's cursor (`HST20`) goes on the caret's line, at its column.
    Widget row(size_t line)
    {
        auto w = Widget(kind: WidgetKind.rich, spans: editorLineSpans(state, line, options),
            width: SizeSpec.grow());
        if (options.hostCursor && options.caretVisible && !state.composition.active
            && line == caretLine)
            w.caretColumn = caretColumnOf(state);
        return w;
    }

    if (lines == 1)
        return b.add(row(0));
    const first = options.firstLine < lines ? options.firstLine : lines - 1;
    const last = options.visibleLines && first + options.visibleLines < lines
        ? first + options.visibleLines : lines;
    uint[] rows;
    foreach (line; first .. last)
        rows ~= b.add(row(line));
    return b.add(Widget(kind: WidgetKind.column, children: rows, width: SizeSpec.grow()));
}

/// The primary caret's column in its line, in cells: the display width of
/// the line's text before it.
int caretColumnOf(in EditorState state) @safe pure nothrow
{
    import sparkles.base.text.grapheme : visibleWidth;

    const head = state.selection.primary.head;
    const start = state.text.lineStart(state.text.lineOf(head));
    auto bytes = new char[head - start];
    state.text.copyTo(start, head, bytes);
    return cast(int) visibleWidth(bytes);
}

/// The host-cursor mode inserts nothing and reports the caret's column, so
/// moving the caret moves no character.
@("editor.view.hostCursor")
@safe
unittest
{
    import sparkles.ui.editor.testing : parse;

    EditorViewOptions host;
    host.hostCursor = true;
    assert(spansOf("ab|cd", host) == "abcd", "one span: no caret, no cut");
    assert(spansOf("a|bcd", host) == spansOf("abc|d", host), "the line is the same wherever the caret is");
    assert(caretColumnOf(parse("日本|語")) == 4, "wide characters count two cells");

    auto b = Builder();
    const tree = b.finish(editorView(b, parse("one\ntw|o"), host));
    int columns;
    foreach (ref n; tree.nodes)
        if (n.caretColumn >= 0)
            columns += n.caretColumn + 100;
    assert(columns == 102, "only the caret's line carries it, at column 2");
}

/**
The first line to show so the primary caret stays in view (`EDR2`, on
`scrollToPrimary`): unchanged while the caret's line is inside
`[firstLine, firstLine + visibleLines)`, else the nearest start that brings it in.
*/
size_t scrollToPrimary(in EditorState state, size_t firstLine, size_t visibleLines)
    @safe pure nothrow @nogc
{
    if (visibleLines == 0)
        return 0;
    const line = state.text.lineOf(state.selection.primary.head);
    if (line < firstLine)
        return line;
    if (line >= firstLine + visibleLines)
        return line + 1 - visibleLines;
    return firstLine;
}

private void sortUnique(ref size_t[] values) @safe pure nothrow
{
    foreach (i; 1 .. values.length)
    {
        const v = values[i];
        size_t j = i;
        while (j > 0 && values[j - 1] > v)
        {
            values[j] = values[j - 1];
            --j;
        }
        values[j] = v;
    }
    size_t n;
    foreach (i, v; values)
        if (i == 0 || v != values[n - 1])
            values[n++] = v;
    values = values[0 .. n];
}

version (unittest)
{
    import sparkles.ui.editor.testing : parse;

    /// The spans of `marked`'s first line, as `text/slot` pairs joined by `|`.
    string spansOf(string marked, EditorViewOptions options = EditorViewOptions.init)
        @safe pure nothrow
    {
        const state = parse(marked);
        string result;
        foreach (i, s; editorLineSpans(state, 0, options))
        {
            if (i)
                result ~= " ";
            result ~= s.text;
            if (s.slot == Slot.selection)
                result ~= "#sel";
            else if (s.slot == Slot.caret)
                result ~= "#caret";
            else if (s.slot == Slot.muted)
                result ~= "#ro";
        }
        return result;
    }
}

/// EDR1: text, selection and caret as spans; the caret at the range's head.
@("editor.view.spans")
@safe pure nothrow
unittest
{
    assert(spansOf("ab|cd") == "ab ▏#caret cd");
    assert(spansOf("a[bc]d") == "a bc#sel ▏#caret d");
    assert(spansOf("a]bc[d") == "a ▏#caret bc#sel d");
    EditorViewOptions blinkOff;
    blinkOff.caretVisible = false;
    assert(spansOf("ab|cd", blinkOff) == "ab cd");
}

/// EDR1: with several ranges every head shows a caret.
@("editor.view.everyCaret")
@safe pure nothrow
unittest
{
    assert(spansOf("a|b|c") == "a ▏#caret b ▏#caret c");
}

/// EDR5: read-only spans draw on their own slot.
@("editor.view.readOnlyDistinct")
@safe pure nothrow
unittest
{
    auto state = parse("ab|cdef");
    state.readOnly.put(ReadOnlySpan(4, 6));
    string shown;
    foreach (s; editorLineSpans(state, 0, EditorViewOptions.init))
        shown ~= s.text ~ (s.slot == Slot.muted ? "#ro " : " ");
    assert(shown == "ab ▏ cd ef#ro ");
}

/// Spans carry their source bytes, so a hit maps back to a text position.
@("editor.view.sourceRanges")
@safe pure nothrow
unittest
{
    const state = parse("a[bc]d");
    foreach (s; editorLineSpans(state, 0, EditorViewOptions.init))
        if (s.slot != Slot.caret)
        {
            char[8] bytes;
            state.text.copyTo(s.srcStart, s.srcEnd, bytes[0 .. s.srcEnd - s.srcStart]);
            assert(bytes[0 .. s.srcEnd - s.srcStart] == s.text);
        }
}

/// EDR2: the view scrolls just enough to keep the primary caret in view.
@("editor.view.scrollToPrimary")
@safe pure nothrow
unittest
{
    const state = parse("0\n1\n2\n3\n4|\n5");
    assert(scrollToPrimary(state, 0, 3) == 2);
    assert(scrollToPrimary(state, 2, 3) == 2);
    assert(scrollToPrimary(state, 5, 3) == 4);
}

/// EDR1 and EDI3: a preedit shows in place of each range, styled by its runs,
/// with the caret at its cursor; the hidden selection is not drawn.
@("editor.view.composition")
@safe pure nothrow
unittest
{
    import sparkles.base.term_style : UnderlineStyle;
    import sparkles.input.events : CompositionRun, CompositionStyle;
    import sparkles.ui.editor.testing : parse;

    auto state = parse("a[bc]d");
    state.composition.preedit = Text("にほ");
    state.composition.cursor = 3;
    state.composition.runs[0] = CompositionRun(0, 3, CompositionStyle.selected);
    state.composition.runs[1] = CompositionRun(3, 3, CompositionStyle.underline);
    state.composition.runCount = 2;
    string shown;
    UnderlineStyle[] underlines;
    foreach (s; editorLineSpans(state, 0, EditorViewOptions.init))
    {
        shown ~= s.text;
        shown ~= s.slot == Slot.selection ? "#sel " : s.slot == Slot.caret ? "#caret " : " ";
        underlines ~= s.textStyle.underline;
    }
    assert(shown == "a に#sel ▏#caret ほ d ", shown);
    assert(underlines[3] == UnderlineStyle.single);
}

/// Host-cursor rows insert nothing: the primary caret is a column, a
/// secondary one a block on its grapheme, and the text is the same wherever
/// the carets are (`HST20`).
@("editor.view.visualRows.hostCursor")
@safe pure nothrow unittest
{
    import sparkles.ui.editor.layout : LayoutOptions, ParagraphLayout;
    import sparkles.ui.editor.selection : SelectionSet;

    EditorViewOptions host;
    host.hostCursor = true;
    auto state = EditorState.create("abcd");
    EditRange[2] carets = [EditRange.caret(1), EditRange.caret(3)];
    state.selection = SelectionSet.of(carets[], 0);
    const layout = ParagraphLayout.of(state.text, 0, LayoutOptions.init);
    const rows = visualRows(editorLineSpans(state, 0, host), layout, state);
    string drawn;
    foreach (s; rows[0].spans)
        drawn ~= s.text ~ (s.slot == Slot.caret ? "#" : "") ~ "|";
    assert(drawn == "abc|d#|", drawn);
    assert(rows[0].caretColumn == 1 && rows[0].inserted.length == 0);
    // Moving the primary caret changes only the column.
    carets = [EditRange.caret(2), EditRange.caret(3)];
    state.selection = SelectionSet.of(carets[], 0);
    const moved = visualRows(editorLineSpans(state, 0, host), layout, state);
    assert(moved[0].caretColumn == 2);
}

/// A row window projects exactly the rows a full projection has there.
@("editor.view.visualRows.window")
@safe pure nothrow unittest
{
    import sparkles.ui.editor.layout : LayoutOptions, ParagraphLayout;
    import sparkles.ui.editor.testing : parse;
    auto state = parse("aaaa bbbb cccc dddd eeee|");
    LayoutOptions options;
    options.wrapCells = 5;
    const layout = ParagraphLayout.of(state.text, 0, options);
    const logical = editorLineSpans(state, 0, EditorViewOptions(hostCursor: true));
    const all = visualRows(logical, layout, state);
    assert(all.length == 5);
    const window = visualRows(logical, layout, state, 2, 2);
    assert(window.length == 2 && window[0].row == 2 && window[1].row == 3);
    assert(window[0].spans == all[2].spans && window[1].caretColumn == all[3].caretColumn);
    assert(visualRows(logical, layout, state, 4, 10).length == 1);
    assert(visualRows(logical, layout, state, 9, 1).length == 0);
    assert(visualRows(logical, layout, state, 4, 10)[0].caretColumn == all[4].caretColumn);
}
