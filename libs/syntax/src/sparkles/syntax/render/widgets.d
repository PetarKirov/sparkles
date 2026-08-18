/**
The raw highlighted document as one widget tree — the code counterpart of
$(MREF sparkles,syntax,md,render_widgets)'s markdown view and the code-line
core of the twoslash document view: every source line is a rich run of
resolved-color spans carrying the identity channel (`srcStart`/`srcEnd`), so
any backend gets char-precise selection ($(REF sourceOffsetAt,
sparkles,ui,state)), search tints ($(REF selectionRects, sparkles,ui,state)),
and source-derived gutter numbers ($(REF documentRows, sparkles,ui,state))
with no per-backend line model.
*/
module sparkles.syntax.render.widgets;

import sparkles.base.term_color : RgbColor;
import sparkles.base.term_style : TextAttr;
import sparkles.syntax.color : toRgb;
import sparkles.syntax.event : byStyledLine, HighlightEvent;
import sparkles.syntax.md.model : Span;
import sparkles.syntax.theme : ResolvedTheme, StyleSpec;
import sparkles.ui.style : Slot, TextStyle;
import sparkles.ui.widget : Builder, TextSpan, Widget, WidgetKind, WidgetTree;
import sparkles.ui.wrap : TextWrap;

@safe:

/// A resolved style's attribute bits as the toolkit's per-span text chrome.
private TextStyle specStyle(in StyleSpec spec) pure nothrow @nogc
    => TextStyle(
        bold: (spec.attrs & TextAttr.bold) != TextAttr.none,
        italic: (spec.attrs & TextAttr.italic) != TextAttr.none,
        strikethrough: (spec.attrs & TextAttr.strikethrough) != TextAttr.none);

/// The vim `listchars` vocabulary for `CodeViewOptions.listWhitespace`.
struct WhitespaceGlyphs
{
    string space = "\u00B7"; /// `·` — every space
    string tab = "\u2192";   /// `→` — a tab's first column (the rest fills)
    string trail = "\u00B7"; /// `·` — trailing whitespace
    string nbsp = "\u2423";  /// `␣` — a no-break space
}

/// The raw code view's presentation options.
struct CodeViewOptions
{
    TextWrap wrap = TextWrap.greedy;
    const(Span)[] foldedRegions;  /// collapsed regions (`FLD`)
    size_t foldHitBase;           /// unfold hit-id base (0 = not clickable)
    /// Tab stops: a tab advances to the next multiple of this many columns.
    int tabWidth = 4;
    /// The fold placeholder's leading `▸ ` marker. A host with a gutter
    /// fold column (the GUI) disables it — the column carries the
    /// affordance, and the placeholder shows unobstructed content.
    bool inlineFoldMarker = true;

    /// vim's `list`: render whitespace visibly with `glyphs`, in
    /// `whitespaceFg` (when set) so the marks read as chrome, not content.
    bool listWhitespace;
    WhitespaceGlyphs glyphs;
    RgbColor whitespaceFg;
    bool hasWhitespaceFg;

    /// Per-line gutter cells, indexed by 0-based source line (`OVL7`). An
    /// index past the end, or an empty `text`, renders as blank padding, so
    /// a producer only has to describe the lines it has something to say
    /// about and the column still lines up.
    const(GutterCell)[] gutter;

    /// Gutter column width in cells, including the one-cell separator before
    /// the code. `0` means no gutter column at all — the default, so a view
    /// that wants none pays nothing.
    int gutterWidth;

    /// Source byte ranges to tint, for decorations finer than a line
    /// (`OVL1`'s inline-span channel). Ranges are applied in order, so a
    /// later one wins where they overlap — which is how a nested,
    /// more-specific range paints over the broader one containing it.
    const(TintedRange)[] tintedRanges;
}

/**
A source byte range to wash with a slot's background.

The line gutter says what happened to a whole line; this says what happened
to part of one. V8 block coverage is the case that needs it: a line holding
both a condition that ran and a block that did not is `partial`, and the
gutter can only report that much — the range is what locates it.
*/
struct TintedRange
{
    size_t start;              /// inclusive source byte offset
    size_t end;                /// exclusive source byte offset
    Slot slot = Slot.highlight; /// the background to wash with
}

/**
One cell of the per-line gutter column.

The column is a decoration channel, not content: its spans carry no source
identity, so selection, copy and goto-line see the code exactly as they would
without it. Whoever fills it has already decided the text (a hit count, a
marker); this only places and colours it.
*/
struct GutterCell
{
    /// Text to show, right-aligned in the column. Longer than the column
    /// truncates rather than pushing the code sideways.
    const(char)[] text;

    /// The slot colouring it — `Slot.covCovered` and friends for coverage,
    /// `Slot.gutter` for neutral chrome.
    Slot slot = Slot.gutter;

    /// Fill the cell with the slot's background as well as colouring its
    /// text, so the column reads as a tinted band at a glance rather than
    /// only on inspection. Off for chrome, which should stay invisible.
    bool paintBackground;
}

/**
Builds the whole highlighted `source` as one widget tree: a column of rich
rows, one per source line, each span resolved against `theme` (foreground,
background when the rule sets one, bold/italic/strikethrough) and stamped
with its source byte range. A blank line carries a zero-width identity at its
line start, so line numbering and goto-line cover every line.

Rows wrap with `wrap` (greedy by default — the raw view reflows to the pane
width; a token wider than the pane overflows its row and clips, like a fence
panel's). Pass `TextWrap.none` for a non-reflowing view.

`foldedRegions` (source byte spans, `FSR4`) collapse line-wise to one
placeholder row each — `▸ first-line ⋯ N lines` — carrying the whole
region's identity (selection-copy over a fold yields the folded source) and,
with a non-zero `foldHitBase`, the unfold hit id `foldHitBase + span.start`
(the same contract as the markdown view's placeholders).
*/
/**
Splits `spans` at `ranges` boundaries, washing the covered parts.

A span is only split by byte offset when its text still corresponds to its
source range one-for-one. Tab expansion and the `list` whitespace glyphs
rewrite a span's text without changing its (single-byte) source range, so an
offset-based split inside one would cut in the wrong place; those are tinted
whole or not at all.
*/
TextSpan[] applyTints(TextSpan[] spans, const(TintedRange)[] ranges) @safe
{
    if (ranges.length == 0 || spans.length == 0)
        return spans;

    TextSpan[] result;
    foreach (ref const spConst; spans)
    {
        TextSpan sp = spConst;
        if (sp.srcStart == size_t.max || sp.srcEnd <= sp.srcStart)
        {
            result ~= sp;
            continue;
        }

        // Last writer wins, so a nested range paints over its container.
        const(TintedRange)* hit = null;
        foreach (ref const r; ranges)
            if (r.start < sp.srcEnd && sp.srcStart < r.end)
                hit = (() @trusted => &r)();
        if (hit is null)
        {
            result ~= sp;
            continue;
        }

        const exact = sp.text.length == sp.srcEnd - sp.srcStart;
        if (!exact || (hit.start <= sp.srcStart && hit.end >= sp.srcEnd))
        {
            // Wholly inside the range, or not splittable: tint it entire.
            auto whole = sp;
            whole.slot = hit.slot;
            whole.paintBackground = true;
            result ~= whole;
            continue;
        }

        // Straddles a boundary: cut into up to three pieces, tinting the
        // middle one.
        const lo = hit.start > sp.srcStart ? hit.start : sp.srcStart;
        const hi = hit.end < sp.srcEnd ? hit.end : sp.srcEnd;

        TextSpan slice(size_t from, size_t to, bool tinted)
        {
            auto piece = sp;
            piece.text = sp.text[from - sp.srcStart .. to - sp.srcStart];
            piece.srcStart = from;
            piece.srcEnd = to;
            if (tinted)
            {
                piece.slot = hit.slot;
                piece.paintBackground = true;
            }
            return piece;
        }

        if (lo > sp.srcStart)
            result ~= slice(sp.srcStart, lo, false);
        result ~= slice(lo, hi, true);
        if (hi < sp.srcEnd)
            result ~= slice(hi, sp.srcEnd, false);
    }
    return result;
}

/**
Builds the gutter span for 0-based source line `line`.

Right-aligned with a one-cell separator before the code, `noBreak` so a
wrapping row keeps it attached to the first visual row, and carrying no
`srcStart`/`srcEnd` — the column is chrome, and identity-bearing spans are
what selection and goto-line walk.

Public because $(LREF viewCodeDocument) is not the only document producer: the
twoslash view renders the same source with the same per-line rows, and a reader
who turned an overlay on does not expect it to vanish because a second one
arrived. One channel, one implementation, however many producers.
*/
TextSpan gutterSpan(in CodeViewOptions opt, size_t line) @safe
{
    const cell = line < opt.gutter.length ? opt.gutter[line] : GutterCell.init;
    const width = cast(size_t) opt.gutterWidth;
    const avail = width > 1 ? width - 1 : width;

    auto buf = new char[](width);
    buf[] = ' ';
    const text = cell.text.length > avail ? cell.text[0 .. avail] : cell.text;
    if (text.length)
        buf[avail - text.length .. avail] = text[];

    // `TextSpan.text` is `const(char)[]`, so the freshly allocated buffer
    // goes in as it is — no cast, and it outlives the tree as the field
    // requires because nothing else holds it.
    // A cell with no text still paints its tint: an unbroken band beside a
    // run of covered lines is the point, and a gap in it would read as a
    // change of state rather than as a line with no count to show.
    return TextSpan(buf, cell.slot, noBreak: true,
        paintBackground: cell.paintBackground);
}

WidgetTree viewCodeDocument(const(char)[] source,
    const(HighlightEvent)[] events, scope const(ResolvedTheme)* theme,
    RgbColor pageFg, CodeViewOptions opt = CodeViewOptions())
{
    const foldedRegions = opt.foldedRegions;
    const foldHitBase = opt.foldHitBase;
    const wrap = opt.wrap;

    // Tab expansion + the vim `list` glyphs: rewrite a line's spans so a
    // tab becomes a `noBreak` fill span reaching the next tab stop (its
    // identity stays the tab's single byte), and — when listing — spaces,
    // trailing runs and no-break spaces become their glyphs in the
    // whitespace color. Lines without any of that pass through untouched.
    TextSpan[] expandLine(TextSpan[] line, size_t lineStart, size_t lineStop)
    {
        const(char)[] lineText = lineStart < lineStop
            ? source[lineStart .. lineStop] : null;
        bool needs;
        foreach (char ch; lineText)
            if (ch == '\t'
                || (opt.listWhitespace && (ch == ' ' || ch == '\xc2')))
            {
                needs = true;
                break;
            }
        if (!needs)
            return line;

        // Where the line's trailing-whitespace run begins (a source byte).
        size_t trailAt = lineStop;
        while (trailAt > lineStart)
        {
            const ch = source[trailAt - 1];
            if (ch != ' ' && ch != '\t')
                break;
            --trailAt;
        }

        static void appendFill(ref char[] buf, string glyph, int n)
        {
            foreach (_; 0 .. n)
                buf ~= glyph;
        }

        TextSpan whitespaceSpan(ref const TextSpan src_, const(char)[] text,
            size_t srcStart, size_t srcEnd)
        {
            TextSpan w = src_;
            w.text = text;
            w.noBreak = true;
            w.srcStart = srcStart;
            w.srcEnd = srcEnd;
            if (opt.listWhitespace && opt.hasWhitespaceFg)
            {
                w.fg = opt.whitespaceFg;
                w.hasFg = true;
            }
            return w;
        }

        import sparkles.ui.geometry : cellsOf;

        TextSpan[] outSpans;
        int col = 0;
        foreach (ref const sp; line)
        {
            const t = sp.text;
            size_t seg = 0;

            void flush(size_t end)
            {
                if (end <= seg)
                    return;
                TextSpan piece = sp;
                piece.text = t[seg .. end];
                if (piece.srcStart != size_t.max)
                {
                    piece.srcStart += seg;
                    piece.srcEnd = piece.srcStart + (end - seg);
                }
                outSpans ~= piece;
                col += cast(int) cellsOf(piece.text);
            }

            size_t i = 0;
            while (i < t.length)
            {
                const srcByte = sp.srcStart != size_t.max
                    ? sp.srcStart + i : size_t.max;
                if (t[i] == '\t')
                {
                    flush(i);
                    const fill = opt.tabWidth > 0
                        ? opt.tabWidth - (col % opt.tabWidth) : 1;
                    char[] txt;
                    if (opt.listWhitespace)
                    {
                        txt ~= srcByte != size_t.max && srcByte >= trailAt
                            ? opt.glyphs.trail : opt.glyphs.tab;
                        appendFill(txt, " ", fill - 1);
                    }
                    else
                        appendFill(txt, " ", fill);
                    outSpans ~= whitespaceSpan(sp, txt, srcByte,
                        srcByte == size_t.max ? size_t.max : srcByte + 1);
                    col += fill;
                    seg = ++i;
                    continue;
                }
                if (opt.listWhitespace && t[i] == ' ')
                {
                    flush(i);
                    size_t j = i;
                    char[] txt;
                    while (j < t.length && t[j] == ' ')
                    {
                        const b = sp.srcStart != size_t.max
                            ? sp.srcStart + j : size_t.max;
                        txt ~= b != size_t.max && b >= trailAt
                            ? opt.glyphs.trail : opt.glyphs.space;
                        ++j;
                    }
                    outSpans ~= whitespaceSpan(sp, txt, srcByte,
                        srcByte == size_t.max ? size_t.max
                            : srcByte + (j - i));
                    col += cast(int)(j - i);
                    seg = i = j;
                    continue;
                }
                if (opt.listWhitespace && t[i] == '\xc2'
                    && i + 1 < t.length && t[i + 1] == '\xa0')
                {
                    flush(i);
                    outSpans ~= whitespaceSpan(sp, opt.glyphs.nbsp, srcByte,
                        srcByte == size_t.max ? size_t.max : srcByte + 2);
                    ++col;
                    seg = (i += 2);
                    continue;
                }
                ++i;
            }
            flush(t.length);
        }
        return outSpans;
    }

    // Line starts, with `lineCount` semantics: a trailing newline does not
    // open an extra line; an empty source has none.
    size_t[] starts;
    if (source.length)
        starts ~= 0;
    foreach (i, char c; source)
        if (c == '\n' && i + 1 < source.length)
            starts ~= i + 1;
    const n = starts.length;

    // Styled runs bucketed per source line, as identity-carrying spans.
    auto byLine = new TextSpan[][](n);
    foreach (ls; byStyledLine(source, events))
    {
        if (ls.line >= n)
            continue;
        const spec = (*theme)[ls.span.label];
        byLine[ls.line] ~= TextSpan(source[ls.span.start .. ls.span.end],
            Slot.code, specStyle(spec),
            fg: toRgb(spec.fg, pageFg), hasFg: true,
            bg: toRgb(spec.bg, RgbColor.init), hasBg: spec.bg.isSet,
            srcStart: ls.span.start, srcEnd: ls.span.end);
    }

    size_t lineEnd(size_t li) => li + 1 < n ? starts[li + 1] : source.length;

    auto b = Builder();
    auto rows = new uint[](0);
    for (size_t li = 0; li < n; ++li)
    {
        // A folded region starting on this line collapses line-wise to one
        // placeholder (the outermost when several start here).
        const(Span)* fr = null;
        foreach (ref const r; foldedRegions)
            if (r.start >= starts[li] && r.start < lineEnd(li)
                && (fr is null || r.end > fr.end))
                fr = (() @trusted => &r)();
        if (fr !is null)
        {
            import sparkles.base.smallbuffer : SmallBuffer;
            import sparkles.base.text.writers : writeInteger;

            const first = li;
            while (li + 1 < n && starts[li + 1] < fr.end)
                ++li;
            const lines = li - first + 1;
            size_t firstLen = lineEnd(first) - starts[first];
            if (firstLen && source[starts[first] + firstLen - 1] == '\n')
                --firstLen;
            SmallBuffer!(char, 32) cnt;
            writeInteger(cnt, lines);
            const clampedEnd = fr.end > source.length ? source.length : fr.end;
            TextSpan[] ph;
            if (opt.inlineFoldMarker)
                ph ~= TextSpan("▸ ", Slot.code, noBreak: true);
            ph ~= TextSpan(source[starts[first] .. starts[first] + firstLen],
                Slot.code, noBreak: true,
                srcStart: starts[first], srcEnd: clampedEnd);
            ph ~= TextSpan("  ⋯ " ~ cnt[].idup ~ " lines", Slot.gutter,
                noBreak: true);
            if (opt.gutterWidth > 0)
                ph = gutterSpan(opt, first) ~ ph;
            rows ~= b.add(Widget(kind: WidgetKind.rich, spans: ph,
                slot: Slot.code,
                hitId: foldHitBase != 0 ? foldHitBase + fr.start : 0));
            continue;
        }
        const blank = !byLine[li].length;
        auto spans = blank
            ? [TextSpan(" ", Slot.code,
                srcStart: starts[li], srcEnd: starts[li])]
            : expandLine(byLine[li], starts[li],
                lineEnd(li) > starts[li] && source[lineEnd(li) - 1] == '\n'
                    ? lineEnd(li) - 1 : lineEnd(li));
        // Indentation survives wrapping as a `noBreak` prefix span: the
        // breaker treats leading spaces as droppable glue (prose semantics),
        // but a noBreak span is a token that the first word joins — so the
        // line keeps its leading whitespace, identity intact.
        if (!blank)
        {
            const t = spans[0].text;
            size_t ws;
            while (ws < t.length && (t[ws] == ' ' || t[ws] == '\t'))
                ++ws;
            if (ws == t.length)
                spans[0].noBreak = true; // an all-whitespace lead span
            else if (ws)
            {
                auto head = spans[0], rest = spans[0];
                head.text = t[0 .. ws];
                head.noBreak = true;
                rest.text = t[ws .. $];
                if (head.srcStart != size_t.max)
                {
                    head.srcEnd = head.srcStart + ws;
                    rest.srcStart += ws;
                }
                spans = [head, rest] ~ spans[1 .. $];
            }
        }
        // After the indentation split (which indexes `spans[0]`), before the
        // gutter (which is not part of the line's text).
        spans = applyTints(spans, opt.tintedRanges);
        // Prepended last: the indentation split above indexes `spans[0]`,
        // and the gutter is not part of the line's text.
        if (opt.gutterWidth > 0)
            spans = gutterSpan(opt, li) ~ spans;
        // A blank row never wraps: the greedy breaker consumes a lone space
        // (a break eats its space), which would drop the row's identity.
        rows ~= b.add(Widget(kind: WidgetKind.rich, spans: spans,
            slot: Slot.code, wrap: blank ? TextWrap.none : wrap));
    }
    return b.finish(b.container(WidgetKind.column, rows));
}

///
@("render.widgets.viewCodeDocument.identityAndResolvedColors")
@safe unittest
{
    import sparkles.syntax.label : LabelSet;
    import sparkles.syntax.theme : resolveTheme;
    import sparkles.syntax.themes : builtinDark;
    import sparkles.ui.state : documentRows;
    import sparkles.ui.layout : layout;

    const src = "int x;\n\nreturn x;\n";
    const labels = LabelSet.standard();
    const rt = resolveTheme(builtinDark, labels);
    // One keyword span over "int"; the rest is unstyled source.
    const kw = labels.resolve("keyword");
    const ev = [
        HighlightEvent.pushLabel(kw), HighlightEvent.sourceSpan(0, 3),
        HighlightEvent.popLabel(), HighlightEvent.sourceSpan(3, src.length),
    ];

    auto tree = viewCodeDocument(src, ev, (() @trusted => &rt)(),
        RgbColor(0xcc, 0xcc, 0xcc));

    // Three rows (the trailing newline opens no fourth), each identity-carrying;
    // the blank line holds a zero-width identity at its own start offset.
    auto rows = documentRows(tree, layout(tree));
    assert(rows.length == 3);
    assert(rows[0].srcStart == 0 && rows[0].srcEnd == 6);
    assert(rows[1].srcStart == 7 && rows[1].srcEnd == 7);
    assert(rows[2].srcStart == 8);

    // The keyword span carries the theme's resolved color, not a slot lookup.
    const kwFg = toRgb(rt[kw].fg, RgbColor(0xcc, 0xcc, 0xcc));
    bool sawKw;
    foreach (ref const w; tree.nodes)
        foreach (ref const s; w.spans)
            if (s.text == "int")
            {
                assert(s.hasFg && s.fg == kwFg);
                assert(s.srcStart == 0 && s.srcEnd == 3);
                sawKw = true;
            }
    assert(sawKw);
}

@("render.widgets.viewCodeDocument.gutterColumn")
@safe unittest
{
    import sparkles.syntax.label : LabelSet;
    import sparkles.syntax.theme : resolveTheme;
    import sparkles.syntax.themes : builtinDark;
    import sparkles.ui.layout : layout;
    import sparkles.ui.state : documentRows;

    const src = "a;\nb;\nc;\n";
    const labels = LabelSet.standard();
    const rt = resolveTheme(builtinDark, labels);
    const ev = [HighlightEvent.sourceSpan(0, src.length)];

    CodeViewOptions opt;
    opt.gutterWidth = 5;
    opt.gutter = [
        GutterCell("12", Slot.covCovered),
        GutterCell("0", Slot.covUncovered),
        // Line 3 is deliberately absent: a producer describes only the lines
        // it knows about, and the column still lines up.
    ];

    auto tree = viewCodeDocument(src, ev, (() @trusted => &rt)(),
        RgbColor(0xcc, 0xcc, 0xcc), opt);

    // The gutter is chrome: it must not disturb the rows' source identity,
    // which is what selection, copy and goto-line walk.
    // `srcEnd` excludes the newline, as it does without a gutter.
    auto rows = documentRows(tree, layout(tree));
    assert(rows.length == 3);
    assert(rows[0].srcStart == 0 && rows[0].srcEnd == 2);
    assert(rows[1].srcStart == 3 && rows[1].srcEnd == 5);
    assert(rows[2].srcStart == 6);

    // The row widgets, in source order, out of the flat arena.
    TextSpan[][] rowSpans;
    foreach (ref node; tree.nodes)
        if (node.kind == WidgetKind.rich)
            rowSpans ~= node.spans;
    assert(rowSpans.length == 3);

    // Right-aligned into `gutterWidth - 1`, with the separator cell after.
    assert(rowSpans[0][0].text == "  12 ");
    assert(rowSpans[0][0].slot == Slot.covCovered);
    assert(rowSpans[0][0].noBreak);
    assert(rowSpans[0][0].srcStart == size_t.max, "the gutter carries no identity");

    assert(rowSpans[1][0].text == "   0 ");
    assert(rowSpans[1][0].slot == Slot.covUncovered);

    // A line the producer said nothing about is blank padding in neutral
    // chrome, not a hole that shifts the code left.
    assert(rowSpans[2][0].text == "     ");
    assert(rowSpans[2][0].slot == Slot.gutter);
}

@("render.widgets.viewCodeDocument.tintedRanges")
@safe unittest
{
    import sparkles.syntax.label : LabelSet;
    import sparkles.syntax.theme : resolveTheme;
    import sparkles.syntax.themes : builtinDark;

    //               0123456789012345678
    const src = "if (c) { miss(); }\n";
    const labels = LabelSet.standard();
    const rt = resolveTheme(builtinDark, labels);
    const ev = [HighlightEvent.sourceSpan(0, src.length)];

    CodeViewOptions opt;
    // The `{ miss(); }` block never ran, though the line did.
    opt.tintedRanges = [TintedRange(7, 18, Slot.covUncovered)];

    auto tree = viewCodeDocument(src, ev, (() @trusted => &rt)(),
        RgbColor(0xcc, 0xcc, 0xcc), opt);

    TextSpan[] row;
    foreach (ref node; tree.nodes)
        if (node.kind == WidgetKind.rich)
            row = node.spans;

    // Split at the range boundary: the condition untinted, the block washed.
    // Reassembled, the row is still exactly the source line — a decoration
    // must not add or drop a character.
    string joined;
    bool sawTint;
    foreach (ref sp; row)
    {
        joined ~= sp.text;
        if (sp.paintBackground && sp.slot == Slot.covUncovered)
        {
            sawTint = true;
            assert(sp.text == "{ miss(); }", sp.text);
            assert(sp.srcStart == 7 && sp.srcEnd == 18);
        }
    }
    assert(sawTint, "the range must be tinted");
    assert(joined == "if (c) { miss(); }", joined);
}

@("render.widgets.viewCodeDocument.tintedRangesNestLastWins")
@safe unittest
{
    import sparkles.syntax.label : LabelSet;
    import sparkles.syntax.theme : resolveTheme;
    import sparkles.syntax.themes : builtinDark;

    const src = "abcdefgh\n";
    const labels = LabelSet.standard();
    const rt = resolveTheme(builtinDark, labels);
    const ev = [HighlightEvent.sourceSpan(0, src.length)];

    CodeViewOptions opt;
    // A broad range with a narrower one inside it: the nested, more specific
    // range must show through rather than being painted over.
    opt.tintedRanges = [
        TintedRange(0, 8, Slot.covCovered),
        TintedRange(3, 5, Slot.covUncovered),
    ];

    auto tree = viewCodeDocument(src, ev, (() @trusted => &rt)(),
        RgbColor(0xcc, 0xcc, 0xcc), opt);

    TextSpan[] row;
    foreach (ref node; tree.nodes)
        if (node.kind == WidgetKind.rich)
            row = node.spans;

    string joined;
    foreach (ref sp; row)
        joined ~= sp.text;
    assert(joined == "abcdefgh", joined);

    bool sawNested;
    foreach (ref sp; row)
        if (sp.slot == Slot.covUncovered)
        {
            sawNested = true;
            assert(sp.text == "de", sp.text);
        }
    assert(sawNested, "the nested range wins where they overlap");
}

@("render.widgets.viewCodeDocument.emptySourceIsEmptyTree")
@safe unittest
{
    import sparkles.syntax.label : LabelSet;
    import sparkles.syntax.theme : resolveTheme;
    import sparkles.syntax.themes : builtinDark;

    const labels = LabelSet.standard();
    const rt = resolveTheme(builtinDark, labels);
    auto tree = viewCodeDocument("", null, (() @trusted => &rt)(),
        RgbColor(0xcc, 0xcc, 0xcc));
    // The childless column is a well-formed empty document.
    assert(tree.nodes.length == 1);
}

@("render.widgets.viewCodeDocument.foldPlaceholder")
@safe unittest
{
    import sparkles.syntax.label : LabelSet;
    import sparkles.syntax.theme : resolveTheme;
    import sparkles.syntax.themes : builtinDark;
    import sparkles.ui.layout : layout;
    import sparkles.ui.state : documentRows, hoverTargets;

    const src = "void f()\n{\n    int a;\n    int b;\n}\nint tail;\n";
    const labels = LabelSet.standard();
    const rt = resolveTheme(builtinDark, labels);
    const ev = [HighlightEvent.sourceSpan(0, src.length)];

    // Fold the whole function (bytes 0..34 — through the closing brace).
    enum hitBase = size_t.max / 4 * 3 + 1;
    auto tree = viewCodeDocument(src, ev, (() @trusted => &rt)(),
        RgbColor(0xcc, 0xcc, 0xcc), CodeViewOptions(
            foldedRegions: [Span(0, 34)], foldHitBase: hitBase));
    auto frames = layout(tree);
    auto rows = documentRows(tree, frames);

    // Five folded lines collapse to one placeholder; the tail line remains.
    assert(rows.length == 2, "placeholder + tail");
    assert(rows[0].text.length && rows[0].srcStart == 0 && rows[0].srcEnd == 34,
        "the placeholder carries the whole region's identity");
    import std.algorithm.searching : canFind;
    assert(rows[0].text.canFind("5 lines"), rows[0].text);
    assert(rows[1].text.canFind("int tail;"));

    // The placeholder is an unfold click target keyed by the span start.
    bool sawHit;
    foreach (ref const t; hoverTargets(tree, frames))
        if (t.hitId == hitBase + 0)
            sawHit = true;
    assert(sawHit, "unfold hit id");
}

@("render.widgets.viewCodeDocument.tabStopsAndListWhitespace")
@safe unittest
{
    import std.algorithm.searching : canFind, startsWith;
    import sparkles.syntax.label : LabelSet;
    import sparkles.syntax.theme : resolveTheme;
    import sparkles.syntax.themes : builtinDark;
    import sparkles.ui.layout : layout;
    import sparkles.ui.state : documentRows;

    // A tab-indented line, a mid-line tab, a trailing space, an NBSP.
    const src = "\tx\na\tb  \nn n\n";
    const labels = LabelSet.standard();
    const rt = resolveTheme(builtinDark, labels);
    const ev = [HighlightEvent.sourceSpan(0, src.length)];

    // Default: tabs expand to 4-column stops (identity = the tab's byte).
    auto plain = viewCodeDocument(src, ev, (() @trusted => &rt)(),
        RgbColor(0xcc, 0xcc, 0xcc));
    auto rows = documentRows(plain, layout(plain));
    assert(rows[0].text == "    x", rows[0].text);
    // Stop at col 4; the breaker consumes the trailing glue (plain mode).
    assert(rows[1].text == "a   b", rows[1].text);
    bool sawTabIdentity;
    foreach (ref const w; plain.nodes)
        foreach (ref const s2; w.spans)
            if (s2.text == "    " && s2.srcStart == 0 && s2.srcEnd == 1)
                sawTabIdentity = true;
    assert(sawTabIdentity, "the fill span carries the tab's single byte");

    // list mode: → for tabs, · for spaces (trailing included), ␣ for NBSP,
    // all in the whitespace color.
    auto listed = viewCodeDocument(src, ev, (() @trusted => &rt)(),
        RgbColor(0xcc, 0xcc, 0xcc), CodeViewOptions(listWhitespace: true,
            whitespaceFg: RgbColor(0x60, 0x60, 0x60), hasWhitespaceFg: true));
    auto lrows = documentRows(listed, layout(listed));
    assert(lrows[0].text == "→   x", lrows[0].text);
    assert(lrows[1].text == "a→  b··", lrows[1].text);
    assert(lrows[2].text == "n␣n", lrows[2].text);
    bool sawWsFg;
    foreach (ref const w; listed.nodes)
        foreach (ref const s2; w.spans)
            if (s2.text.startsWith("→") && s2.hasFg
                && s2.fg == RgbColor(0x60, 0x60, 0x60))
                sawWsFg = true;
    assert(sawWsFg, "whitespace glyphs take the whitespace color");
}
