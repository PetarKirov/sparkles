/**
`MdDoc` → `sparkles:ui` widgets — the $(B composable) markdown view (`UIA6`,
`XFM3`, `WGT2`): one pure, re-entrant mapping from the structural model to a
widget subtree, shared by every consumer — hue's document preview, a twoslash
popup's JSDoc, a fenced block inside either. The sibling of
$(MREF sparkles,syntax,md,render_html): same model, different target.

Re-entrancy is the contract: $(LREF viewMarkdownInto) $(B appends) to a caller's
$(REF Builder, sparkles,ui,widget), so any view may embed a markdown subtree at
any depth, and a `ctx.depth` cap keeps markdown ⊃ fence ⊃ markdown recursion
total (unknown or over-deep content degrades to plain text, never a crash).

Prose wraps as $(B rich runs) — the engine breaks styled spans, inline-`code`
pills are unbreakable spans, and the wrap width is the node's width maximum
(`LAY10`: the view owns no packing loop).
*/
module sparkles.syntax.md.render_widgets;

import sparkles.base.term_color : RgbColor, toRgb;
import sparkles.base.term_style : UnderlineStyle;
import sparkles.syntax.event : byStyledLine, HighlightEvent;
import sparkles.syntax.md.model : ColAlign, MdBlock, MdBlockKind, MdDoc,
    MdInline, MdInlineKind, Span;
import sparkles.syntax.theme : ResolvedTheme;
import sparkles.syntax.ts.highlighter : highlightInjected;
import sparkles.syntax.ts.injection : TsConfigCache;
import sparkles.syntax.ts.registry : canonicalLanguage;
import sparkles.ui.geometry : Insets, SizeSpec;
import sparkles.ui.style : BorderStyle, Decoration, FontRole, Slot, TextStyle;
import sparkles.ui.widget : Builder, TextSpan, Widget, WidgetKind, WidgetTree;
import sparkles.ui.wrap : TextWrap;

@safe:

/// The view's configuration: measure, identity and recursion budget.
struct MdViewOptions
{
    /// Wrap width maximum in cells (`0` = unbounded; the viewport constrains).
    int maxWidth = 0;
    /// Hit identity stamped on every produced node (`0` = not hit-testable) —
    /// a popup's docs keep the popup's hover identity.
    size_t hitId = 0;
    /// Base text style for prose (a popup passes its docs face/scale).
    TextStyle baseStyle;
    /// Prose slot (`inherit` = the page text; a popup passes `docs`).
    Slot proseSlot = Slot.inherit;
    /// Nesting budget: markdown ⊃ fence ⊃ markdown recursion stops here and
    /// degrades to plain text (totality — `RND5`).
    int depthBudget = 8;

    /// Optional fence-body renderer (`XFM3`'s nested pipeline at the view
    /// level): `(infoLang, body) → per-line styled spans` — e.g. syntax
    /// highlighting through `highlightInjected`, or a twoslash sub-view.
    /// `null` (or an empty result) renders the fence as plain code lines.
    TextSpan[][] delegate(const(char)[] infoLang, const(char)[] body_) @safe
        fenceRenderer;
}

/// The whole document as its own tree (the common non-embedded case).
WidgetTree viewMarkdown(const MdDoc doc, MdViewOptions opt = MdViewOptions.init)
{
    auto b = Builder();
    const root = viewMarkdownInto(b, doc, opt);
    return b.finish(root);
}

/// Appends the document's view to `b` and returns its root index — the
/// re-entrant form every embedding view calls.
uint viewMarkdownInto(ref Builder b, const MdDoc doc,
    MdViewOptions opt = MdViewOptions.init)
    => blocksColumn(b, doc.root.children, doc.source, opt);

// One column of blocks with a blank line's worth of gap between them.
private uint blocksColumn(ref Builder b, in MdBlock[] blocks,
    const(char)[] src, in MdViewOptions opt)
{
    auto rows = new uint[](0);
    foreach (ref const blk; blocks)
        rows ~= viewBlock(b, blk, src, opt);
    return b.container(WidgetKind.column, rows, gap: 1);
}

private uint viewBlock(ref Builder b, ref const MdBlock blk, const(char)[] src,
    in MdViewOptions opt)
{
    if (opt.depthBudget <= 0) // recursion cap: degrade to the raw source slice
        return proseRow(b, [TextSpan(sliceOf(src, blk.span), opt.proseSlot,
            opt.baseStyle)], opt);

    final switch (blk.kind) with (MdBlockKind)
    {
        case document:
            return blocksColumn(b, blk.children, src, opt);

        case heading:
            TextSpan[] spans;
            TextStyle style = opt.baseStyle;
            style.bold = true;
            inlinesToSpans(blk.inlines, src, style, Slot.chromeAccent, spans);
            return proseRow(b, spans, opt);

        case paragraph:
            TextSpan[] spans;
            inlinesToSpans(blk.inlines, src, opt.baseStyle, opt.proseSlot, spans);
            return proseRow(b, spans, opt);

        case blockQuote:
        {
            MdViewOptions inner = opt;
            inner.depthBudget = opt.depthBudget - 1;
            const body_ = blocksColumn(b, blk.children, src, inner);
            // The quote bar: a left border on a padded panel.
            return b.add(Widget(kind: WidgetKind.panel, children: [body_],
                padding: Insets(0, 0, 0, 2), hitId: opt.hitId,
                decoration: Decoration(borderWidth: Insets(0, 0, 0, 1),
                    borderStyle: BorderStyle.solid, borderSlot: Slot.border)));
        }

        case list:
        {
            auto rows = new uint[](0);
            foreach (ref const item; blk.children)
            {
                TextSpan[] spans;
                spans ~= TextSpan("• ", Slot.gutter, opt.baseStyle, noBreak: true);
                const inls = item.inlines.length ? item.inlines
                    : (item.children.length ? item.children[0].inlines : null);
                inlinesToSpans(inls, src, opt.baseStyle, opt.proseSlot, spans);
                rows ~= proseRow(b, spans, opt);
            }
            return b.container(WidgetKind.column, rows);
        }

        case codeFence:
        {
            // A bordered code panel. The body's lines come from the nested
            // pipeline when a fenceRenderer is supplied (syntax highlighting,
            // a twoslash sub-view); plain pre-formatted code otherwise.
            auto rows = new uint[](0);
            const code = sliceOf(src, blk.codeBody);

            TextSpan[][] styled;
            if (opt.fenceRenderer !is null)
                styled = opt.fenceRenderer(blk.infoLang, code);
            if (styled.length)
            {
                foreach (line; styled)
                    rows ~= b.add(Widget(kind: WidgetKind.rich,
                        spans: line.length ? line
                            : [TextSpan(" ", Slot.code, codeStyle(opt))],
                        slot: Slot.code, hitId: opt.hitId,
                        textStyle: codeStyle(opt)));
            }
            else
            {
                size_t start = 0;
                void line(const(char)[] t) @safe
                {
                    rows ~= b.add(Widget(kind: WidgetKind.text,
                        text: t.length ? t : " ", slot: Slot.code,
                        hitId: opt.hitId, textStyle: codeStyle(opt)));
                }

                foreach (i, char c; code)
                    if (c == '\n')
                    {
                        line(code[start .. i]);
                        start = i + 1;
                    }
                if (start < code.length)
                    line(code[start .. $]);
            }
            const body_ = b.container(WidgetKind.column, rows);
            return b.add(Widget(kind: WidgetKind.panel, children: [body_],
                slot: Slot.surface, paintBackground: true, stretch: true,
                padding: Insets.symmetric(0, 1), hitId: opt.hitId,
                decoration: Decoration(borderWidth: Insets.all(1),
                    borderStyle: BorderStyle.solid, borderSlot: Slot.border)));
        }

        case thematicBreak:
            // A full-width rule: a stretch box with a bottom border.
            return b.add(Widget(kind: WidgetKind.box, stretch: true,
                height: SizeSpec.fixed(1), hitId: opt.hitId,
                decoration: Decoration(borderWidth: Insets(0, 0, 1, 0),
                    borderStyle: BorderStyle.solid, borderSlot: Slot.border)));

        case table:
        {
            // Slice 1: rows as gutter-separated text (the track-sizer view —
            // LAY9 — replaces this; totality first).
            auto rows = new uint[](0);
            foreach (ref const row; blk.children)
            {
                TextSpan[] spans;
                foreach (ci, ref const cell; row.children)
                {
                    if (ci)
                        spans ~= TextSpan("  ", opt.proseSlot, opt.baseStyle);
                    inlinesToSpans(cell.inlines, src, opt.baseStyle,
                        opt.proseSlot, spans);
                }
                rows ~= proseRow(b, spans, opt);
            }
            return b.container(WidgetKind.column, rows);
        }

        case listItem, tableRow, tableCell:
            // Handled by their parents; standalone appearance degrades.
            return blocksColumn(b, blk.children, src, opt);

        case htmlBlock:
            return proseRow(b, [TextSpan(sliceOf(src, blk.span), Slot.muted,
                opt.baseStyle)], opt);
    }
}

// One wrapping rich run with the view's width maximum (LAY10).
private uint proseRow(ref Builder b, TextSpan[] spans, in MdViewOptions opt)
{
    if (!spans.length)
        spans = [TextSpan(" ", opt.proseSlot, opt.baseStyle)];
    Widget w = Widget(kind: WidgetKind.rich, spans: spans, hitId: opt.hitId,
        slot: opt.proseSlot, wrap: TextWrap.greedy, textStyle: opt.baseStyle);
    if (opt.maxWidth > 0)
        w.width.max = opt.maxWidth;
    return b.add(w);
}

private TextStyle codeStyle(in MdViewOptions opt)
{
    TextStyle s = opt.baseStyle;
    s.fontRole = FontRole.code;
    return s;
}

/**
Inline markdown → styled spans, threading style through
emphasis/strong/strikethrough/link and slicing leaves from `src`. Inline
`code` is an unbreakable pill span. $(B The) inline mapper — the twoslash
popup and the document view share it, which is what "JSDoc renders through
the same markdown view" means concretely.
*/
void inlinesToSpans(in MdInline[] inls, const(char)[] src, TextStyle base,
    Slot slot, ref TextSpan[] spans)
{
    foreach (ref const inl; inls)
        final switch (inl.kind) with (MdInlineKind)
        {
            case text:
                pushProse(sliceOf(src, inl.span), base, slot, spans);
                break;
            case strong:
            {
                auto s = base;
                s.bold = true;
                inlinesToSpans(inl.children, src, s, slot, spans);
                break;
            }
            case emphasis:
            {
                auto s = base;
                s.italic = true;
                inlinesToSpans(inl.children, src, s, slot, spans);
                break;
            }
            case strikethrough:
            {
                auto s = base;
                s.strikethrough = true;
                inlinesToSpans(inl.children, src, s, slot, spans);
                break;
            }
            case codeSpan:
            {
                auto s = base;
                s.fontRole = FontRole.code;
                const t = sliceOf(src, inl.span);
                if (t.length)
                    spans ~= TextSpan(t, Slot.chip, s,
                        paintBackground: true, noBreak: true);
                break;
            }
            case link:
            {
                auto s = base;
                s.underline = UnderlineStyle.single;
                inlinesToSpans(inl.children, src, s, Slot.info, spans);
                break;
            }
            case image:
                inlinesToSpans(inl.children, src, base, slot, spans);
                break;
            case lineBreak:
                spans ~= TextSpan("\n", slot, base); // hard break
                break;
        }
}

/// Prose text as one styled span: whitespace runs (markdown soft wraps, tabs,
/// newlines) collapse to single spaces, edges included — the line breaker then
/// owns every breaking decision.
void pushProse(const(char)[] text, TextStyle style, Slot slot,
    ref TextSpan[] spans)
{
    if (!text.length)
        return;
    char[] norm;
    norm.reserve(text.length);
    bool ws;
    foreach (char c; text)
    {
        if (c == ' ' || c == '\t' || c == '\n')
        {
            ws = true;
            continue;
        }
        if (ws)
        {
            norm ~= ' ';
            ws = false;
        }
        norm ~= c;
    }
    if (ws)
        norm ~= ' ';
    if (norm.length)
        spans ~= TextSpan(norm, slot, style); // freshly allocated, never mutated
}

private const(char)[] sliceOf(const(char)[] src, Span s) pure nothrow @nogc
    => s.start <= s.end && s.end <= src.length ? src[s.start .. s.end] : null;

/**
A `fenceRenderer` backed by the injection-aware highlighter — the real nested
pipeline (`XFM3`): the fence body highlights in its info language (unknown or
unbundled → one plain span), colors resolved from `theme` with `pageFg` for
unstyled text. Spans carry $(B resolved) colors — the theme's syntax channel
bypasses the slot vocabulary, exactly the split the unified theme makes.

`cache` and `theme` are borrowed; the returned delegate must not outlive them.
*/
TextSpan[][] delegate(const(char)[], const(char)[]) @safe highlightedFenceRenderer(
    TsConfigCache* cache, const(ResolvedTheme)* theme, RgbColor pageFg)
{
    return delegate TextSpan[][] (const(char)[] lang, const(char)[] body_) @trusted {
        import sparkles.base.smallbuffer : SmallBuffer;

        SmallBuffer!HighlightEvent ev;
        if (highlightInjected(*cache, canonicalLanguage(lang), body_, ev).hasError)
            ev ~= HighlightEvent.sourceSpan(0, body_.length);

        TextSpan[][] lines;
        foreach (ls; byStyledLine(body_, ev[]))
        {
            while (lines.length <= ls.line)
                lines ~= new TextSpan[](0); // empty lines advance the counter
            const spec = (*theme)[ls.span.label];
            lines[ls.line] ~= TextSpan(
                body_[ls.span.start .. ls.span.end], Slot.code,
                TextStyle.init, fg: toRgb(spec.fg, pageFg), hasFg: true);
        }
        return lines;
    };
}

// ---------------------------------------------------------------------------
// Tests (hand-built models — no grammar bundle needed)
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.base.term_color : RgbColor;
    import sparkles.base.term_style : TextAttr;
    import sparkles.ui.canvas : OpKind, RecordingCanvas;
    import sparkles.ui.display_list : buildDisplayList;
    import sparkles.ui.interp.immediate : paint;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette;

    private RecordingCanvas renderDoc(const MdDoc doc, MdViewOptions opt = MdViewOptions.init) @safe
    {
        auto tree = viewMarkdown(doc, opt);
        auto ops = buildDisplayList(tree, layout(tree), defaultTwoslashPalette(),
            RgbColor(0xcc, 0xcc, 0xcc), RgbColor(0x1e, 0x1e, 0x1e));
        RecordingCanvas c;
        paint(c, ops);
        return c;
    }
}

@("md.render_widgets.headingParagraphQuote")
@safe unittest
{
    // "# Title\n\nbody **bold**\n\n> quoted"
    const src = "Title body bold quoted";
    const doc = MdDoc(MdBlock(kind: MdBlockKind.document, children: [
        MdBlock(kind: MdBlockKind.heading, level: 1, inlines: [
            MdInline(kind: MdInlineKind.text, span: Span(0, 5))]),
        MdBlock(kind: MdBlockKind.paragraph, inlines: [
            MdInline(kind: MdInlineKind.text, span: Span(6, 11)),
            MdInline(kind: MdInlineKind.strong, span: Span(11, 15), children: [
                MdInline(kind: MdInlineKind.text, span: Span(11, 15))]),
        ]),
        MdBlock(kind: MdBlockKind.blockQuote, children: [
            MdBlock(kind: MdBlockKind.paragraph, inlines: [
                MdInline(kind: MdInlineKind.text, span: Span(16, 22))]),
        ]),
    ]), src);

    auto c = renderDoc(doc);
    bool sawTitle, sawBold, sawQuoteBar, sawQuoted;
    foreach (ref op; c.ops)
    {
        if (op.kind == OpKind.textRun && op.text == "Title")
            sawTitle = (op.visual.styleBits & TextAttr.bold.bits) != 0;
        if (op.kind == OpKind.textRun && op.text == "bold"
            && (op.visual.styleBits & TextAttr.bold.bits))
            sawBold = true;
        if (op.kind == OpKind.fillRect && op.visual.border.any
            && op.visual.border.width == Insets(0, 0, 0, 1))
            sawQuoteBar = true;
        if (op.kind == OpKind.textRun && op.text == "quoted")
            sawQuoted = true;
    }
    assert(sawTitle && sawBold && sawQuoteBar && sawQuoted);
}

@("md.render_widgets.fencePanelAndWrapWidth")
@safe unittest
{
    const src = "let x = 1\nlet y = 2\n";
    const doc = MdDoc(MdBlock(kind: MdBlockKind.document, children: [
        MdBlock(kind: MdBlockKind.codeFence, codeBody: Span(0, src.length)),
    ]), src);

    auto c = renderDoc(doc);
    bool sawPanel, sawLine1, sawLine2;
    foreach (ref op; c.ops)
    {
        if (op.kind == OpKind.fillRect && op.visual.hasBg && op.visual.border.any)
            sawPanel = true;
        if (op.text == "let x = 1")
            sawLine1 = true;
        if (op.text == "let y = 2")
            sawLine2 = true;
    }
    assert(sawPanel && sawLine1 && sawLine2);

    // A paragraph under a width maximum wraps in the ENGINE (LAY10).
    const prose = "aaaa bbbb cccc dddd";
    const pdoc = MdDoc(MdBlock(kind: MdBlockKind.document, children: [
        MdBlock(kind: MdBlockKind.paragraph, inlines: [
            MdInline(kind: MdInlineKind.text, span: Span(0, prose.length))]),
    ]), prose);
    auto tree = viewMarkdown(pdoc, MdViewOptions(maxWidth: 9));
    auto frames = layout(tree);
    assert(frames[tree.root].rect.height > 1); // wrapped into rows
    assert(frames[tree.root].rect.width <= 9);
}

@("md.render_widgets.reentrantEmbedding")
@safe unittest
{
    // The WGT2 contract: another view embeds a markdown subtree mid-build.
    const src = "hello";
    const doc = MdDoc(MdBlock(kind: MdBlockKind.document, children: [
        MdBlock(kind: MdBlockKind.paragraph, inlines: [
            MdInline(kind: MdInlineKind.text, span: Span(0, 5))]),
    ]), src);

    auto b = Builder();
    const before = b.add(Widget(kind: WidgetKind.text, text: "before"));
    const md = viewMarkdownInto(b, doc);
    const after = b.add(Widget(kind: WidgetKind.text, text: "after"));
    auto tree = b.finish(b.container(WidgetKind.column, [before, md, after]));

    auto ops = buildDisplayList(tree, layout(tree), defaultTwoslashPalette(),
        RgbColor(0, 0, 0), RgbColor(255, 255, 255));
    bool sawB, sawH, sawA;
    foreach (ref op; ops)
    {
        sawB |= op.text == "before";
        sawH |= op.text == "hello";
        sawA |= op.text == "after";
    }
    assert(sawB && sawH && sawA);
}

@("md.render_widgets.fenceRendererIsTheNestedPipeline")
@safe unittest
{
    // A fake nested pipeline: "highlight" a fence body by styling each line's
    // first word — proving the hook shape without a grammar bundle (XFM3).
    const src = "let x = 1\nlet y = 2\n";
    const doc = MdDoc(MdBlock(kind: MdBlockKind.document, children: [
        MdBlock(kind: MdBlockKind.codeFence, infoLang: "d",
            codeBody: Span(0, src.length)),
    ]), src);

    TextSpan[][] fakeHighlight(const(char)[] lang, const(char)[] body_) @safe
    {
        TextSpan[][] lines;
        size_t start = 0;
        foreach (i, char c; body_)
            if (c == '\n')
            {
                lines ~= [TextSpan(body_[start .. start + 3], Slot.chromeAccent),
                    TextSpan(body_[start + 3 .. i], Slot.code)];
                start = i + 1;
            }
        return lines;
    }

    auto opt = MdViewOptions(fenceRenderer: &fakeHighlight);
    auto c = renderDoc(doc, opt);
    bool sawKeyword, sawRest;
    foreach (ref op; c.ops)
    {
        // chromeAccent resolves to the accent blue (the paint round-trip
        // keeps resolved visuals, not slots).
        if (op.kind == OpKind.textRun && op.text == "let"
            && op.visual.fg == RgbColor(0x37, 0x72, 0xcf))
            sawKeyword = true;
        if (op.kind == OpKind.textRun && op.text == " y = 2")
            sawRest = true;
    }
    assert(sawKeyword && sawRest);
}

@("md.render_widgets.highlightedFenceRendererFallsBackTotal")
@system unittest
{
    import sparkles.syntax.theme : resolveTheme;
    import sparkles.syntax.label : LabelSet;
    import sparkles.syntax.themes : builtinDark;
    import sparkles.syntax.ts.registry : GrammarRegistry;

    // An unknown language degrades to one plain resolved-color span per line —
    // the totality half of the nested pipeline, testable with no grammars.
    auto registry = GrammarRegistry(); // empty: every language misses
    const labels = LabelSet.standard();
    const theme = resolveTheme(builtinDark, labels);
    auto cache = TsConfigCache.create(&registry, labels);
    const pageFg = RgbColor(0xcc, 0xcc, 0xcc);

    auto render = highlightedFenceRenderer(&cache, &theme, pageFg);
    auto lines = render("no-such-language", "one\ntwo\n");
    assert(lines.length == 2);
    assert(lines[0].length == 1 && lines[0][0].text == "one");
    assert(lines[0][0].hasFg); // resolved color rides the span
    assert(lines[1][0].text == "two");
}

@("md.render_widgets.depthBudgetDegradesToPlainText")
@safe unittest
{
    const src = "deep";
    const doc = MdDoc(MdBlock(kind: MdBlockKind.document, children: [
        MdBlock(kind: MdBlockKind.blockQuote, span: Span(0, 4), children: [
            MdBlock(kind: MdBlockKind.paragraph, span: Span(0, 4), inlines: [
                MdInline(kind: MdInlineKind.text, span: Span(0, 4))]),
        ]),
    ]), src);

    // Budget 0: the quote renders as its raw source slice, no recursion.
    auto tree = viewMarkdown(doc, MdViewOptions(depthBudget: 0));
    auto ops = buildDisplayList(tree, layout(tree), defaultTwoslashPalette(),
        RgbColor(0, 0, 0), RgbColor(255, 255, 255));
    assert(ops.length >= 1);
    bool sawRaw;
    foreach (ref op; ops)
        sawRaw |= op.text == "deep";
    assert(sawRaw);
}
