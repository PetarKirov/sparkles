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

/**
Builds the whole highlighted `source` as one widget tree: a column of rich
rows, one per source line, each span resolved against `theme` (foreground,
background when the rule sets one, bold/italic/strikethrough) and stamped
with its source byte range. A blank line carries a zero-width identity at its
line start, so line numbering and goto-line cover every line.

Rows wrap with `wrap` (greedy by default — the raw view reflows to the pane
width; a token wider than the pane overflows its row and clips, like a fence
panel's). Pass `TextWrap.none` for a non-reflowing view.
*/
WidgetTree viewCodeDocument(const(char)[] source,
    const(HighlightEvent)[] events, scope const(ResolvedTheme)* theme,
    RgbColor pageFg, TextWrap wrap = TextWrap.greedy)
{
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

    auto b = Builder();
    auto rows = new uint[](0);
    foreach (li; 0 .. n)
    {
        const blank = !byLine[li].length;
        auto spans = blank
            ? [TextSpan(" ", Slot.code,
                srcStart: starts[li], srcEnd: starts[li])]
            : byLine[li];
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
