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

import sparkles.base.term_color : mix, RgbColor, toRgb;
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

    /// The document's resolved theme colors (`MdViewTheme.derive`). Absent
    /// (`theme.present == false`), decorations fall back to palette slots.
    MdViewTheme theme;

    /// The decoration charset (Nerd-glyph defaults; the theme glyph channel).
    MdViewGlyphs glyphs;

    /// Non-zero makes fence header bands copy targets: a fence's header gets
    /// `hitId = fenceHitBase + codeBody.start` and shows the copy glyph, so an
    /// interactive backend maps a click back to the fence's source span with
    /// no per-fence counter — identity is source-anchored, like fold keys.
    size_t fenceHitBase = 0;

    /// The `codeBody.start` of the fence just copied (`size_t.max` = none):
    /// its header shows the copied glyph instead of the copy glyph — the
    /// feedback state lives in the app, the view stays a pure function of it.
    size_t copiedFence = size_t.max;

    /// Span starts (`MdBlock.span.start`) of folded regions — each renders
    /// as a one-row placeholder (first source line + a `⋯ N lines` chip)
    /// carrying the whole region's source identity, so selection/copy over a
    /// fold still yields the folded source (`FLD` under `D1`: a fold is a
    /// subtree swapped for a placeholder, so it nests correctly).
    size_t[] foldedSpans;
    /// Non-zero makes fold placeholders click targets:
    /// `hitId = foldHitBase + span.start` (unfold on click).
    size_t foldHitBase = 0;

    /// The placeholder's leading `▸ ` marker. A host with a gutter fold
    /// column (the GUI) disables it — the column carries the affordance,
    /// and the placeholder shows unobstructed content.
    bool inlineFoldMarker = true;

    /// Non-zero stamps every table cell wrapper with
    /// `key = tableKeyBase + cell.span.start` — source-anchored identity an
    /// interactive backend resolves back to the document's cell structure
    /// (2-D table selection, per-cell copy) via the cells' frames.
    size_t tableKeyBase = 0;
}

/**
Theme-derived document colors — hue's render-markdown design language, resolved
once per (theme, page) pair: role colors from the theme's `markup.*` labels,
accent hues borrowed from stable syntax roles (functions blue, strings green,
numbers red, types yellow, keywords purple), and the mixed panel/band tints.
This is the $(B syntax channel) at document scope; the view stamps these as
resolved overrides (`TextSpan.fg`, `Widget.*Override`), bypassing the palette.
*/
struct MdViewTheme
{
    bool present;
    RgbColor pageFg, pageBg;
    RgbColor headingFg, codeFg, linkFg, quoteFg;
    RgbColor codePanelBg, codeHeaderBg, inlineCodeBg, ruleFg;
    RgbColor accentBlue, accentGreen, accentRed, accentYellow, accentPurple;
    RgbColor[6] headingAccents; /// per heading level (index = level-1)
    RgbColor[4] quoteBars;      /// nested quote-bar colors, by depth (mod 4)

    /// Resolves the set from `theme` against the page colors.
    static MdViewTheme derive(const ResolvedTheme theme, RgbColor pageFg,
        RgbColor pageBg) @safe
    {
        RgbColor role(string name, RgbColor fallback)
        {
            const spec = theme[theme.labels.resolve(name)];
            return toRgb(spec.fg, fallback);
        }

        MdViewTheme v = {present: true, pageFg: pageFg, pageBg: pageBg};
        v.headingFg = role("markup.heading", pageFg);
        v.codeFg = role("markup.raw", pageFg);
        v.linkFg = role("markup.link", pageFg);
        v.quoteFg = role("markup.quote", mix(pageFg, pageBg, 0.35));
        v.codePanelBg = mix(pageBg, pageFg, 0.08);
        v.codeHeaderBg = mix(pageBg, pageFg, 0.16);
        v.inlineCodeBg = mix(pageBg, pageFg, 0.12);
        v.ruleFg = mix(pageBg, pageFg, 0.4);
        v.accentBlue = role("function", v.linkFg);
        v.accentGreen = role("string", RgbColor(0x40, 0xc0, 0x60));
        v.accentRed = role("number", RgbColor(0xe0, 0x60, 0x50));
        v.accentYellow = role("type", RgbColor(0xd8, 0xb0, 0x40));
        v.accentPurple = role("keyword", RgbColor(0xb0, 0x70, 0xd0));
        v.headingAccents = [v.headingFg, v.accentBlue, v.accentPurple,
            v.accentGreen, v.accentYellow, v.accentRed];
        v.quoteBars = [v.quoteFg, v.accentBlue, v.accentGreen, v.accentPurple];
        return v;
    }
}

/// The markdown decoration charset — Nerd-glyph defaults (the theme's glyph
/// channel; pass an ASCII set for glyph-poor terminals).
struct MdViewGlyphs
{
    /// nf-md-format-header-1..6, painted per-level accent.
    string[6] headingIcons = [
        "\U000F0CA1", "\U000F0CA3", "\U000F0CA5",
        "\U000F0CA7", "\U000F0CA9", "\U000F0CAB",
    ];
    string checkedBox = "\U000F0C52 ";   /// 󰱒
    string uncheckedBox = "\U000F0131 "; /// 󰄱
    string[4] bullets = ["●", "○", "◆", "◇"]; /// unordered, cycled by depth
    string noteIcon = "\U000F02FD";      /// 󰋽
    string tipIcon = "\U000F0336";       /// 󰌶
    string importantIcon = "\U000F017E"; /// 󰅾
    string warningIcon = "\U000F002A";   /// 󰀪
    string cautionIcon = "\U000F0CE6";   /// 󰳦
    string copyIcon = "\U0000F0C5";      ///  (fence header copy affordance)
    string copiedIcon = "\U0000F00C";    ///  (feedback after a copy)
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

// One column of blocks with a blank line's worth of gap between them. A
// folded block collapses to its placeholder; a folded HEADING folds its whole
// section (the sibling run up to the next heading of the same or higher level).
private uint blocksColumn(ref Builder b, in MdBlock[] blocks,
    const(char)[] src, MdViewOptions opt, int listDepth = 0,
    int quoteDepth = 0)
{
    import std.algorithm.searching : canFind;

    auto rows = new uint[](0);
    for (size_t i = 0; i < blocks.length; ++i)
    {
        if (opt.foldedSpans.canFind(blocks[i].span.start))
        {
            size_t srcEnd = blocks[i].span.end;
            if (blocks[i].kind == MdBlockKind.heading)
                while (i + 1 < blocks.length
                    && !(blocks[i + 1].kind == MdBlockKind.heading
                        && blocks[i + 1].level <= blocks[i].level))
                {
                    ++i;
                    srcEnd = blocks[i].span.end;
                }
            rows ~= foldPlaceholder(b, blocks[i].span.start, srcEnd, src, opt);
            continue;
        }
        rows ~= viewBlock(b, blocks[i], src, opt, listDepth, quoteDepth);
    }
    return b.container(WidgetKind.column, rows, gap: 1);
}

// A folded region's one-row stand-in: `▸ <first source line> ⋯ N lines`,
// carrying the whole region's source identity (selection copies the fold).
private uint foldPlaceholder(ref Builder b, size_t start, size_t end,
    const(char)[] src, MdViewOptions opt)
{
    import sparkles.base.text.writers : writeInteger;
    import sparkles.base.smallbuffer : SmallBuffer;

    const clampedEnd = end > src.length ? src.length : end;
    const body_ = src[start .. clampedEnd];
    size_t firstLen = body_.length;
    size_t lines = 1;
    foreach (i, ch; body_)
        if (ch == '\n')
        {
            if (lines == 1)
                firstLen = i;
            ++lines;
        }

    SmallBuffer!(char, 32) n;
    writeInteger(n, lines);
    TextSpan[] spans;
    if (opt.inlineFoldMarker)
        spans ~= TextSpan("▸ ", opt.proseSlot, opt.baseStyle, noBreak: true);
    spans ~= TextSpan(body_[0 .. firstLen], opt.proseSlot, opt.baseStyle,
        noBreak: true, srcStart: start, srcEnd: clampedEnd);
    spans ~= TextSpan("  ⋯ " ~ n[].idup ~ " lines", Slot.gutter,
        opt.baseStyle, noBreak: true);
    Widget w = Widget(kind: WidgetKind.rich, spans: spans,
        slot: opt.proseSlot, textStyle: opt.baseStyle,
        hitId: opt.foldHitBase != 0 ? opt.foldHitBase + start : opt.hitId);
    return b.add(w);
}

/**
The markdown fold-range provider (`FSR3`): the foldable regions of `doc` as
source byte spans, document order — heading sections (heading start → the end
of the sibling run before the next same-or-higher heading), fenced code,
block quotes, lists, and tables. Spans are the fold keys (the same
source-anchored identity the copy targets use), consumed by
$(REF DisclosureState, sparkles,ui,state) + `MdViewOptions.foldedSpans`.
*/
Span[] foldableSpans(const MdDoc doc) @safe
{
    Span[] spans;

    void walk(in MdBlock[] blocks)
    {
        for (size_t i = 0; i < blocks.length; ++i)
        {
            final switch (blocks[i].kind) with (MdBlockKind)
            {
                case heading:
                {
                    size_t end = blocks[i].span.end;
                    size_t j = i + 1;
                    while (j < blocks.length
                        && !(blocks[j].kind == heading
                            && blocks[j].level <= blocks[i].level))
                        end = blocks[j++].span.end;
                    if (j > i + 1) // an empty section has nothing to fold
                        spans ~= Span(blocks[i].span.start, end);
                    break;
                }
                case codeFence, blockQuote, list, table:
                    spans ~= blocks[i].span;
                    break;
                case document, paragraph, listItem, tableRow, tableCell,
                    thematicBreak, htmlBlock:
                    break;
            }
            walk(blocks[i].children);
        }
    }

    walk(doc.root.children);
    return spans;
}

private uint viewBlock(ref Builder b, ref const MdBlock blk, const(char)[] src,
    MdViewOptions opt, int listDepth = 0, int quoteDepth = 0)
{
    if (opt.depthBudget <= 0) // recursion cap: degrade to the raw source slice
        return proseRow(b, [TextSpan(sliceOf(src, blk.span), opt.proseSlot,
            opt.baseStyle)], opt);

    final switch (blk.kind) with (MdBlockKind)
    {
        case document:
            return blocksColumn(b, blk.children, src, opt);

        case heading:
        {
            TextSpan[] spans;
            TextStyle style = opt.baseStyle;
            style.bold = true;
            if (opt.theme.present)
            {
                // Per-level icon + accent text + a subtle full-width band.
                const lvl = blk.level < 1 ? 1 : (blk.level > 6 ? 6 : blk.level);
                const accent = opt.theme.headingAccents[lvl - 1];
                spans ~= TextSpan(opt.glyphs.headingIcons[lvl - 1] ~ " ",
                    opt.proseSlot, style, fg: accent, hasFg: true, noBreak: true);
                inlinesToSpans(blk.inlines, src, style, opt.proseSlot, spans,
                    &opt.theme);
                foreach (ref s; spans[1 .. $])
                    if (!s.hasFg)
                    {
                        s.fg = accent;
                        s.hasFg = true;
                    }
                auto w = richWidget(spans, opt, leaderHang(spans[0]));
                w.stretch = true;
                w.paintBackground = true;
                w.bgOverride = mix(opt.theme.pageBg, accent, 0.12);
                w.hasBgOverride = true;
                return b.add(w);
            }
            inlinesToSpans(blk.inlines, src, style, Slot.chromeAccent, spans);
            return proseRow(b, spans, opt);
        }

        case paragraph:
        {
            TextSpan[] spans;
            inlinesToSpans(blk.inlines, src, opt.baseStyle, opt.proseSlot, spans,
                opt.theme.present ? &opt.theme : null);
            return proseRow(b, spans, opt);
        }

        case blockQuote:
        {
            MdViewOptions inner = opt;
            inner.depthBudget = opt.depthBudget - 1;

            Callout co;
            if (opt.theme.present && detectCallout(blk, src, opt, co))
                return calloutPanel(b, blk, src, inner, co, listDepth, quoteDepth);

            const body_ = blocksColumn(b, blk.children, src, inner,
                listDepth, quoteDepth + 1);
            // The quote bar: a left border on a padded panel, its color cycling
            // by nesting depth when a theme is present.
            Widget w = Widget(kind: WidgetKind.panel, children: [body_],
                padding: Insets(0, 0, 0, 2), hitId: opt.hitId,
                decoration: Decoration(borderWidth: Insets(0, 0, 0, 1),
                    borderStyle: BorderStyle.solid, borderSlot: Slot.border));
            if (opt.theme.present)
            {
                w.borderOverride = opt.theme.quoteBars[quoteDepth % 4];
                w.hasBorderOverride = true;
            }
            return b.add(w);
        }

        case list:
        {
            import std.conv : text;

            auto rows = new uint[](0);
            int ord = 1;
            foreach (ref const item; blk.children)
            {
                if (item.kind != MdBlockKind.listItem)
                    continue;
                // Leader: a checkbox (green when checked), an ordinal, or a
                // depth-cycled bullet.
                TextSpan leader;
                if (item.checkbox == 1)
                    leader = TextSpan(opt.glyphs.checkedBox, Slot.gutter,
                        opt.baseStyle, noBreak: true,
                        fg: opt.theme.accentGreen, hasFg: opt.theme.present);
                else if (item.checkbox == 0)
                    leader = TextSpan(opt.glyphs.uncheckedBox, Slot.gutter,
                        opt.baseStyle, noBreak: true);
                else if (blk.ordered)
                    leader = TextSpan(text(ord, ". "), Slot.gutter,
                        opt.baseStyle, noBreak: true);
                else
                    leader = TextSpan(opt.glyphs.bullets[listDepth % 4] ~ " ",
                        Slot.gutter, opt.baseStyle, noBreak: true);
                ++ord;

                TextSpan[] spans = [leader];
                const inls = item.inlines.length ? item.inlines
                    : (item.children.length ? item.children[0].inlines : null);
                inlinesToSpans(inls, src, opt.baseStyle, opt.proseSlot, spans,
                    opt.theme.present ? &opt.theme : null);
                rows ~= proseRow(b, spans, opt, leaderHang(leader));
                // Nested blocks (a sub-list, a nested paragraph) after the first.
                bool first = true;
                foreach (ref const c; item.children)
                {
                    if (c.kind == MdBlockKind.paragraph && first)
                    {
                        first = false;
                        continue;
                    }
                    rows ~= viewBlock(b, c, src, opt, listDepth + 1, quoteDepth);
                }
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
                {
                    // Renderer offsets are body-relative; anchor them to the
                    // fence body's source position (the identity channel).
                    foreach (ref s; line)
                        if (s.srcStart != size_t.max)
                        {
                            s.srcStart += blk.codeBody.start;
                            s.srcEnd += blk.codeBody.start;
                        }
                    rows ~= b.add(Widget(kind: WidgetKind.rich,
                        spans: line.length ? line
                            : [TextSpan(" ", Slot.code, codeStyle(opt))],
                        slot: Slot.code, hitId: opt.hitId,
                        textStyle: codeStyle(opt)));
                }
            }
            else
            {
                size_t start = 0;
                void line(const(char)[] t, size_t at) @safe
                {
                    rows ~= b.add(Widget(kind: WidgetKind.rich, spans: [
                        TextSpan(t.length ? t : " ", Slot.code, codeStyle(opt),
                            srcStart: blk.codeBody.start + at,
                            srcEnd: blk.codeBody.start + at + t.length)],
                        slot: Slot.code, hitId: opt.hitId,
                        textStyle: codeStyle(opt)));
                }

                foreach (i, char c; code)
                    if (c == '\n')
                    {
                        line(code[start .. i], start);
                        start = i + 1;
                    }
                if (start < code.length)
                    line(code[start .. $], start);
            }
            const body_ = b.container(WidgetKind.column, rows);
            // Padded on every side so a cell backend's box-glyph perimeter
            // never overwrites content; rounded corners (╭…╯ on cells).
            Widget panel = Widget(kind: WidgetKind.panel, children: [body_],
                slot: Slot.surface, paintBackground: true, stretch: true,
                padding: Insets(1, 2, 1, 2), hitId: opt.hitId,
                decoration: Decoration(borderWidth: Insets.all(1),
                    borderStyle: BorderStyle.solid, borderSlot: Slot.border,
                    borderRadius: 4));
            if (!opt.theme.present)
                return b.add(panel);

            // Themed: a language-label header band over the tinted panel.
            panel.bgOverride = opt.theme.codePanelBg;
            panel.hasBgOverride = true;
            const icon = langIcon(blk.infoLang);
            const(char)[] lbl = (icon.length ? icon ~ " " : "")
                ~ (blk.infoLang.length ? blk.infoLang : "code");
            if (blk.label.length)
                lbl = lbl ~ " " ~ blk.label;
            // With a fence hit base the whole band is a copy target, its
            // identity anchored at the body's source position; the glyph is
            // the affordance, the copied state comes from the app.
            size_t headerHit = opt.hitId;
            if (opt.fenceHitBase != 0)
            {
                headerHit = opt.fenceHitBase + blk.codeBody.start;
                lbl = lbl ~ "  " ~ (opt.copiedFence == blk.codeBody.start
                    ? opt.glyphs.copiedIcon : opt.glyphs.copyIcon);
            }
            // The header row carries the fence's opening line as identity
            // (gutter fold markers + block-granular selection anchor here).
            Widget header = Widget(kind: WidgetKind.rich, spans: [
                    TextSpan(lbl, Slot.code, codeStyle(opt),
                        srcStart: blk.span.start,
                        srcEnd: blk.codeBody.start)],
                slot: Slot.code, hitId: headerHit, stretch: true,
                paintBackground: true, padding: Insets.symmetric(0, 1),
                textStyle: codeStyle(opt),
                bgOverride: opt.theme.codeHeaderBg, hasBgOverride: true,
                fgOverride: opt.theme.codeFg, hasFgOverride: true);
            const hdr = b.add(header);
            const pnl = b.add(panel);
            return b.container(WidgetKind.column, [hdr, pnl]);
        }

        case thematicBreak:
        {
            // A full-width rule: a stretch box with a bottom border.
            Widget w = Widget(kind: WidgetKind.box, stretch: true,
                height: SizeSpec.fixed(1), hitId: opt.hitId,
                decoration: Decoration(borderWidth: Insets(0, 0, 1, 0),
                    borderStyle: BorderStyle.solid, borderSlot: Slot.border));
            if (opt.theme.present)
            {
                w.borderOverride = opt.theme.ruleFg;
                w.hasBorderOverride = true;
            }
            return b.add(w);
        }

        case table:
        {
            import sparkles.ui.geometry : cellsOf;
            import sparkles.ui.tracks : resolveTracks, TrackSpec;
            import sparkles.ui.widget : Alignment;

            // The LAY9 track sizer: measure every cell, resolve auto tracks,
            // lay each row as fixed-width aligned cells. The delimiter row's
            // ColAlign drives per-column alignment; the header row is bold.
            size_t cols;
            foreach (ref const row; blk.children)
                if (row.children.length > cols)
                    cols = row.children.length;
            if (cols == 0)
                return b.container(WidgetKind.column, null);

            // Cell spans (built once) + per-column content maxima.
            auto cellSpans = new TextSpan[][](blk.children.length * cols);
            auto content = new int[](cols);
            foreach (ri, ref const row; blk.children)
                foreach (ci, ref const cell; row.children)
                {
                    TextSpan[] spans;
                    TextStyle style = opt.baseStyle;
                    style.bold = ri == 0; // the header row
                    inlinesToSpans(cell.inlines, src, style, opt.proseSlot,
                        spans, opt.theme.present ? &opt.theme : null);
                    cellSpans[ri * cols + ci] = spans;
                    int w;
                    foreach (ref s; spans)
                        w += cast(int) cellsOf(s.text);
                    if (w > content[ci])
                        content[ci] = w;
                }

            auto tracks = new TrackSpec[](cols);
            tracks[] = TrackSpec.auto_;
            const widths = resolveTracks(tracks, content, 0, 2);

            auto rows = new uint[](0);
            foreach (ri; 0 .. blk.children.length)
            {
                auto cells = new uint[](0);
                foreach (ci; 0 .. cols)
                {
                    auto spans = cellSpans[ri * cols + ci];
                    if (!spans.length)
                        spans = [TextSpan(" ", opt.proseSlot, opt.baseStyle)];
                    Widget cellW = Widget(kind: WidgetKind.rich, spans: spans,
                        hitId: opt.hitId, slot: opt.proseSlot,
                        textStyle: opt.baseStyle);
                    const a = ci < blk.aligns.length ? blk.aligns[ci]
                        : ColAlign.none;
                    // Alignment via a fixed-width single-child column (LAY8).
                    const inner = b.add(cellW);
                    Widget colW = Widget(kind: WidgetKind.column,
                        children: [inner], width: SizeSpec.fixed(widths[ci]),
                        alignX: a == ColAlign.right ? Alignment.end
                            : a == ColAlign.center ? Alignment.center
                            : Alignment.start);
                    // Source-anchored cell identity for interactive backends.
                    if (opt.tableKeyBase != 0
                        && ci < blk.children[ri].children.length)
                        colW.key = opt.tableKeyBase
                            + blk.children[ri].children[ci].span.start;
                    cells ~= b.add(colW);
                }
                rows ~= b.container(WidgetKind.row, cells, gap: 2);
            }
            const grid = b.container(WidgetKind.column, rows);
            // A perimeter border panel (inner grid rules are a later fidelity
            // step — the cell backends draw full boxes, not single sides).
            Widget panel = Widget(kind: WidgetKind.panel, children: [grid],
                padding: Insets.all(1), hitId: opt.hitId,
                decoration: Decoration(borderWidth: Insets.all(1),
                    borderStyle: BorderStyle.solid, borderSlot: Slot.border));
            if (opt.theme.present)
            {
                panel.borderOverride = opt.theme.ruleFg;
                panel.hasBorderOverride = true;
            }
            return b.add(panel);
        }

        case listItem, tableRow, tableCell:
            // Handled by their parents; standalone appearance degrades.
            return blocksColumn(b, blk.children, src, opt, listDepth, quoteDepth);

        case htmlBlock:
            return proseRow(b, [TextSpan(sliceOf(src, blk.span), Slot.muted,
                opt.baseStyle)], opt);
    }
}

// One wrapping rich run with the view's width maximum (LAY10). `hang` > 0
// indents wrapped continuations (a leader's width — bullet, heading icon,
// callout icon — so they align under the text, not under the marker).
private Widget richWidget(TextSpan[] spans, MdViewOptions opt, int hang = 0)
{
    if (!spans.length)
        spans = [TextSpan(" ", opt.proseSlot, opt.baseStyle)];
    Widget w = Widget(kind: WidgetKind.rich, spans: spans, hitId: opt.hitId,
        slot: opt.proseSlot, wrap: TextWrap.greedy, textStyle: opt.baseStyle,
        hangIndent: hang);
    if (opt.maxWidth > 0)
        w.width.max = opt.maxWidth;
    return w;
}

/// ditto
private uint proseRow(ref Builder b, TextSpan[] spans, MdViewOptions opt,
    int hang = 0)
    => b.add(richWidget(spans, opt, hang));

// The hang for a leader span: its own column width.
private int leaderHang(in TextSpan leader) @safe
{
    import sparkles.ui.geometry : cellsOf;

    return cast(int) cellsOf(leader.text);
}

private TextStyle codeStyle(MdViewOptions opt)
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
    Slot slot, ref TextSpan[] spans, scope const(MdViewTheme)* vt = null)
{
    foreach (ref const inl; inls)
        final switch (inl.kind) with (MdInlineKind)
        {
            case text:
                pushProse(sliceOf(src, inl.span), base, slot, spans,
                    inl.span.start);
                break;
            case strong:
            {
                auto s = base;
                s.bold = true;
                inlinesToSpans(inl.children, src, s, slot, spans, vt);
                break;
            }
            case emphasis:
            {
                auto s = base;
                s.italic = true;
                inlinesToSpans(inl.children, src, s, slot, spans, vt);
                break;
            }
            case strikethrough:
            {
                auto s = base;
                s.strikethrough = true;
                inlinesToSpans(inl.children, src, s, slot, spans, vt);
                break;
            }
            case codeSpan:
            {
                auto s = base;
                s.fontRole = FontRole.code;
                const t = sliceOf(src, inl.span);
                if (t.length)
                    spans ~= TextSpan(t, Slot.chip, s,
                        paintBackground: true, noBreak: true,
                        fg: vt !is null ? vt.codeFg : RgbColor.init,
                        hasFg: vt !is null,
                        srcStart: inl.span.start, srcEnd: inl.span.end);
                break;
            }
            case link:
            {
                auto s = base;
                s.underline = UnderlineStyle.single;
                const before = spans.length;
                inlinesToSpans(inl.children, src, s, Slot.info, spans, vt);
                if (vt !is null)
                    foreach (ref sp; spans[before .. $])
                        if (!sp.hasFg)
                        {
                            sp.fg = vt.linkFg;
                            sp.hasFg = true;
                        }
                break;
            }
            case image:
                inlinesToSpans(inl.children, src, base, slot, spans, vt);
                break;
            case lineBreak:
                spans ~= TextSpan("\n", slot, base); // hard break
                break;
        }
}

/// Prose text as one styled span: whitespace runs (markdown soft wraps, tabs,
/// newlines) collapse to single spaces, edges included — the line breaker then
/// owns every breaking decision. `srcStart` (when given) stamps the source
/// identity the normalized text came from.
void pushProse(const(char)[] text, TextStyle style, Slot slot,
    ref TextSpan[] spans, size_t srcStart = size_t.max)
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
        spans ~= TextSpan(norm, slot, style, // freshly allocated, never mutated
            srcStart: srcStart,
            srcEnd: srcStart != size_t.max ? srcStart + text.length : 0);
}

// ── Callouts (GitHub admonitions) ───────────────────────────────────────────

private struct Callout
{
    string icon;
    RgbColor accent;
    string title;
    size_t markerLen; /// bytes of `[!TYPE]` (incl. leading ws) to strip
}

// Recognize `> [!NOTE]` (and TIP/IMPORTANT/WARNING/CAUTION) on the quote's
// first paragraph. Detection reads the paragraph's RAW SOURCE — `[!NOTE]`
// parses as a *shortcut link*, not text, so the inline tree can't be trusted.
private bool detectCallout(ref const MdBlock b, const(char)[] src,
    MdViewOptions opt, out Callout co)
{
    Span paraSpan;
    bool found;
    foreach (ref const c; b.children)
        if (c.kind == MdBlockKind.paragraph)
        {
            paraSpan = c.span;
            found = true;
            break;
        }
    if (!found)
        return false;

    const txt = sliceOf(src, paraSpan);
    size_t i;
    while (i < txt.length && (txt[i] == ' ' || txt[i] == '\t'))
        ++i;
    if (i + 2 >= txt.length || txt[i] != '[' || txt[i + 1] != '!')
        return false;
    const s = i + 2;
    size_t e = s;
    while (e < txt.length && txt[e] != ']')
        ++e;
    if (e >= txt.length)
        return false;
    switch (upperAscii(txt[s .. e]))
    {
        case "NOTE":
            co = Callout(opt.glyphs.noteIcon, opt.theme.accentBlue, "Note");
            break;
        case "TIP":
            co = Callout(opt.glyphs.tipIcon, opt.theme.accentGreen, "Tip");
            break;
        case "IMPORTANT":
            co = Callout(opt.glyphs.importantIcon, opt.theme.accentPurple,
                "Important");
            break;
        case "WARNING":
            co = Callout(opt.glyphs.warningIcon, opt.theme.accentYellow,
                "Warning");
            break;
        case "CAUTION":
            co = Callout(opt.glyphs.cautionIcon, opt.theme.accentRed, "Caution");
            break;
        default:
            return false;
    }
    co.markerLen = e + 1; // through the closing `]` (incl. leading ws)
    return true;
}

// A titled, iconed admonition: accent bar + icon + Title, then the quoted
// body with the `[!TYPE]` marker dropped from its first paragraph.
private uint calloutPanel(ref Builder b, ref const MdBlock blk,
    const(char)[] src, MdViewOptions opt, Callout co,
    int listDepth, int quoteDepth)
{
    TextStyle bold = opt.baseStyle;
    bold.bold = true;
    auto title = richWidget([
        TextSpan(co.icon ~ " ", opt.proseSlot, bold, fg: co.accent, hasFg: true,
            noBreak: true),
        TextSpan(co.title, opt.proseSlot, bold, fg: co.accent, hasFg: true),
    ], opt);
    auto rows = [b.add(title)];

    bool firstPara = true;
    foreach (ref const c; blk.children)
    {
        if (c.kind == MdBlockKind.paragraph && firstPara)
        {
            firstPara = false;
            TextSpan[] spans;
            inlinesToSpans(trimLeadingBytes(c.inlines,
                    c.span.start + co.markerLen), src,
                opt.baseStyle, opt.proseSlot, spans,
                opt.theme.present ? &opt.theme : null);
            if (spans.length)
                rows ~= proseRow(b, spans, opt);
            continue;
        }
        rows ~= viewBlock(b, c, src, opt, listDepth, quoteDepth + 1);
    }
    const body_ = b.container(WidgetKind.column, rows, gap: 1);
    return b.add(Widget(kind: WidgetKind.panel, children: [body_],
        padding: Insets(0, 0, 0, 2), hitId: opt.hitId,
        decoration: Decoration(borderWidth: Insets(0, 0, 0, 1),
            borderStyle: BorderStyle.solid, borderSlot: Slot.border),
        borderOverride: co.accent, hasBorderOverride: true));
}

// Drop any inline fully within `[0, cutoff)` (absolute source offset) —
// removes the `[!TYPE]` marker (which parses as a leading link).
private const(MdInline)[] trimLeadingBytes(in MdInline[] inlines, size_t cutoff)
{
    const(MdInline)[] kept;
    foreach (ref const inl; inlines)
        if (inl.span.end > cutoff)
            kept ~= inl;
    return kept;
}

private string upperAscii(const(char)[] s) pure nothrow
{
    auto r = new char[](s.length);
    foreach (i, c; s)
        r[i] = c >= 'a' && c <= 'z' ? cast(char)(c - 32) : c;
    return () @trusted { return cast(string) r; }();
}

/// A devicon glyph for a fenced-code language, else a generic code glyph;
/// empty when the fence has no language. (Glyph data — the theme's channel.)
string langIcon(const(char)[] lang) @safe pure nothrow @nogc
{
    switch (lang)
    {
        case "python": return "\U0000E606";
        case "rust": return "\U0000E7A8";
        case "javascript", "typescript", "jsx", "tsx": return "\U0000E781";
        case "bash", "shell", "sh", "zsh", "fish": return "\U0000E795";
        case "nix": return "\U000F1105";
        case "json": return "\U0000E60B";
        case "markdown", "md": return "\U0000E609";
        case "c", "cpp", "c++": return "\U0000E61E";
        case "html": return "\U0000E736";
        case "css": return "\U0000E749";
        case "go": return "\U0000E627";
        case "d": return "\U0000E7AF";
        case "": return "";
        default: return "\U0000F121"; // generic code
    }
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
                TextStyle.init, fg: toRgb(spec.fg, pageFg), hasFg: true,
                srcStart: ls.span.start, srcEnd: ls.span.end); // body-relative
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

@("md.render_widgets.themedDecorations")
@safe unittest
{
    import sparkles.syntax.label : LabelSet;
    import sparkles.syntax.theme : resolveTheme;
    import sparkles.syntax.themes : builtinDark;

    const labels = LabelSet.standard();
    const rt = resolveTheme(builtinDark, labels);
    const pageFg = RgbColor(0xcc, 0xcc, 0xcc);
    const pageBg = RgbColor(0x1e, 0x1e, 0x1e);
    const vt = MdViewTheme.derive(rt, pageFg, pageBg);
    assert(vt.present && vt.headingAccents[0] == vt.headingFg);

    // "# Title" + "- [x] done" + a d fence: band, icon, checkbox, header.
    const src = "Title done let x = 1";
    const doc = MdDoc(MdBlock(kind: MdBlockKind.document, children: [
        MdBlock(kind: MdBlockKind.heading, level: 2, inlines: [
            MdInline(kind: MdInlineKind.text, span: Span(0, 5))]),
        MdBlock(kind: MdBlockKind.list, children: [
            MdBlock(kind: MdBlockKind.listItem, checkbox: 1, inlines: [
                MdInline(kind: MdInlineKind.text, span: Span(6, 10))]),
        ]),
        MdBlock(kind: MdBlockKind.codeFence, infoLang: "d",
            codeBody: Span(11, src.length)),
    ]), src);

    MdViewOptions opt = {theme: vt};
    auto c = renderDoc(doc, opt);

    bool sawIcon, sawBand, sawCheck, sawHeader, sawHeaderBand;
    const glyphs = MdViewGlyphs.init;
    foreach (ref op; c.ops)
    {
        if (op.kind == OpKind.textRun
            && op.text == glyphs.headingIcons[1] ~ " "
            && op.visual.fg == vt.headingAccents[1])
            sawIcon = true;
        if (op.kind == OpKind.fillRect
            && op.visual.bg == mixBand(vt, vt.headingAccents[1]))
            sawBand = true;
        if (op.kind == OpKind.textRun && op.text == glyphs.checkedBox
            && op.visual.fg == vt.accentGreen)
            sawCheck = true;
        // The header is a rich run now (it carries the fence's opening-line
        // identity); its band is the widget's own fill in codeHeaderBg.
        if (op.kind == OpKind.textRun && op.text == langIcon("d") ~ " d")
            sawHeader = true;
        if (op.kind == OpKind.fillRect && op.visual.bg == vt.codeHeaderBg)
            sawHeaderBand = true;
    }
    assert(sawIcon && sawBand && sawCheck && sawHeader && sawHeaderBand);
}

private RgbColor mixBand(in MdViewTheme vt, RgbColor accent) @safe
    => mix(vt.pageBg, accent, 0.12);

@("md.render_widgets.identityChannel.srcOffsetsAndFenceHit")
@safe unittest
{
    import sparkles.syntax.label : LabelSet;
    import sparkles.syntax.theme : resolveTheme;
    import sparkles.syntax.themes : builtinDark;
    import sparkles.ui.widget : WidgetKind;

    // The identity channel: prose spans carry their source byte offsets, a
    // plain fence line carries body-exact offsets, and with a fenceHitBase
    // the (themed) header band's hit id is anchored at the body's source
    // position. Un-themed fences have no header band and so no copy target.
    const src = "hello world x = 1\ny = 2";
    const doc = MdDoc(MdBlock(kind: MdBlockKind.document, children: [
        MdBlock(kind: MdBlockKind.paragraph, inlines: [
            MdInline(kind: MdInlineKind.text, span: Span(0, 11))]),
        MdBlock(kind: MdBlockKind.codeFence, infoLang: "d",
            codeBody: Span(12, src.length)),
    ]), src);

    const labels = LabelSet.standard();
    const vt = MdViewTheme.derive(resolveTheme(builtinDark, labels),
        RgbColor(0xcc, 0xcc, 0xcc), RgbColor(0x1e, 0x1e, 0x1e));
    MdViewOptions opt = {fenceHitBase: 1 << 20, theme: vt};
    auto tree = viewMarkdown(doc, opt);

    bool sawProse, sawFenceLine2, sawHit;
    foreach (ref const n; tree.nodes)
    {
        if (n.kind == WidgetKind.rich)
            foreach (ref const s; n.spans)
            {
                if (s.text == "hello world"
                    && s.srcStart == 0 && s.srcEnd == 11)
                    sawProse = true;
                if (s.text == "y = 2" && s.srcStart == 18
                    && s.srcEnd == src.length)
                    sawFenceLine2 = true;
            }
        if (n.hitId == (1 << 20) + 12)
            sawHit = true;
    }
    assert(sawProse && sawFenceLine2 && sawHit);
}

@("md.render_widgets.identityChannel.tableCellKeys")
@safe unittest
{
    import sparkles.ui.widget : WidgetKind;

    // A 2×2 table: with a tableKeyBase every cell wrapper is stamped with a
    // source-anchored key a backend maps back to the document's cell.
    const src = "a b\nc d";
    static MdBlock cell(size_t a, size_t b)
        => MdBlock(kind: MdBlockKind.tableCell, span: Span(a, b),
            inlines: [MdInline(kind: MdInlineKind.text, span: Span(a, b))]);
    const doc = MdDoc(MdBlock(kind: MdBlockKind.document, children: [
        MdBlock(kind: MdBlockKind.table, span: Span(0, src.length), children: [
            MdBlock(kind: MdBlockKind.tableRow, children: [cell(0, 1), cell(2, 3)]),
            MdBlock(kind: MdBlockKind.tableRow, children: [cell(4, 5), cell(6, 7)]),
        ]),
    ]), src);

    MdViewOptions opt = {tableKeyBase: 1 << 20};
    auto tree = viewMarkdown(doc, opt);

    size_t[] keys;
    foreach (ref const n; tree.nodes)
        if (n.key != 0)
            keys ~= n.key - (1 << 20);
    assert(keys == [0, 2, 4, 6], "one source-anchored key per cell");
}

@("md.render_widgets.calloutDetectedFromRawSource")
@safe unittest
{
    import sparkles.syntax.label : LabelSet;
    import sparkles.syntax.theme : resolveTheme;
    import sparkles.syntax.themes : builtinDark;

    // "> [!WARNING]\n> careful" — the marker parses as a shortcut LINK, so
    // detection must read the raw span (the documented trap).
    const src = "[!WARNING] careful";
    const doc = MdDoc(MdBlock(kind: MdBlockKind.document, children: [
        MdBlock(kind: MdBlockKind.blockQuote, span: Span(0, src.length), children: [
            MdBlock(kind: MdBlockKind.paragraph, span: Span(0, src.length), inlines: [
                // the marker as a parsed *link*, then the body text
                MdInline(kind: MdInlineKind.link, span: Span(1, 9), children: [
                    MdInline(kind: MdInlineKind.text, span: Span(1, 9))]),
                MdInline(kind: MdInlineKind.text, span: Span(10, src.length)),
            ]),
        ]),
    ]), src);

    const labels = LabelSet.standard();
    const rt = resolveTheme(builtinDark, labels);
    const vt = MdViewTheme.derive(rt,
        RgbColor(0xcc, 0xcc, 0xcc), RgbColor(0x1e, 0x1e, 0x1e));
    MdViewOptions opt = {theme: vt};
    auto c = renderDoc(doc, opt);

    bool sawTitle, sawBody, sawMarkerLeak;
    foreach (ref op; c.ops)
    {
        if (op.kind == OpKind.textRun && op.text == "Warning"
            && op.visual.fg == vt.accentYellow)
            sawTitle = true;
        if (op.kind == OpKind.textRun && op.text == "careful")
            sawBody = true;
        if (op.kind == OpKind.textRun && op.text == "!WARNING")
            sawMarkerLeak = true; // the stripped marker must NOT render
    }
    assert(sawTitle && sawBody && !sawMarkerLeak);
}

@("md.render_widgets.tableTracksAndAlignment")
@safe unittest
{
    import sparkles.ui.layout : layout;

    // | name | n |   with n right-aligned; "worker" is the widest name.
    const src = "name n worker 10 x 5";
    static MdBlock cell(size_t a, size_t b2)
        => MdBlock(kind: MdBlockKind.tableCell,
            inlines: [MdInline(kind: MdInlineKind.text, span: Span(a, b2))]);
    const doc = MdDoc(MdBlock(kind: MdBlockKind.document, children: [
        MdBlock(kind: MdBlockKind.table,
            aligns: [ColAlign.left, ColAlign.right], children: [
                MdBlock(kind: MdBlockKind.tableRow, children: [cell(0, 4), cell(5, 6)]),
                MdBlock(kind: MdBlockKind.tableRow, children: [cell(7, 13), cell(14, 16)]),
                MdBlock(kind: MdBlockKind.tableRow, children: [cell(17, 18), cell(19, 20)]),
            ]),
    ]), src);

    auto tree = viewMarkdown(doc);
    auto frames = layout(tree);
    auto ops = buildDisplayList(tree, frames, defaultTwoslashPalette(),
        RgbColor(0xcc, 0xcc, 0xcc), RgbColor(0x1e, 0x1e, 0x1e));

    // Track widths: col0 = "worker" (6), col1 = "10" (2). The right-aligned
    // "5" sits flush right in its 2-cell track; rows share column origins.
    import sparkles.base.term_style : TextAttr;

    int col5x = -1, col10x = -1;
    bool headerBold;
    foreach (ref op; ops)
    {
        if (op.text == "5")
            col5x = op.rect.x;
        if (op.text == "10")
            col10x = op.rect.x;
        if (op.text == "name" && (op.visual.styleBits & TextAttr.bold.bits))
            headerBold = true;
    }
    assert(headerBold);
    assert(col10x >= 0 && col5x == col10x + 1); // "5" right-aligned over "10"
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

@("md.render_widgets.folding.providerAndPlaceholder")
@safe unittest
{
    import sparkles.ui.widget : WidgetKind;

    // "# Title\n\npara\n\n```d\na\nb\n```" — the provider yields the heading
    // SECTION (title through fence) and the fence itself.
    const src = "# Title\n\npara\n\n```d\na\nb\n```";
    const doc = MdDoc(MdBlock(kind: MdBlockKind.document, children: [
        MdBlock(kind: MdBlockKind.heading, level: 1, span: Span(0, 7), inlines: [
            MdInline(kind: MdInlineKind.text, span: Span(2, 7))]),
        MdBlock(kind: MdBlockKind.paragraph, span: Span(9, 13), inlines: [
            MdInline(kind: MdInlineKind.text, span: Span(9, 13))]),
        MdBlock(kind: MdBlockKind.codeFence, infoLang: "d",
            span: Span(15, src.length), codeBody: Span(20, 24)),
    ]), src);

    const folds = foldableSpans(doc);
    assert(folds == [Span(0, src.length), Span(15, src.length)]);

    // Folding the fence: its panel is gone; a placeholder row carries the
    // whole region's identity and the unfold hit id.
    MdViewOptions opt = {foldedSpans: [15UL], foldHitBase: 1 << 20};
    auto tree = viewMarkdown(doc, opt);
    bool sawPlaceholder, sawPanel;
    foreach (ref const n; tree.nodes)
    {
        if (n.kind == WidgetKind.rich && n.hitId == (1 << 20) + 15)
            foreach (ref const s; n.spans)
                if (s.srcStart == 15 && s.srcEnd == src.length
                    && s.text == "```d")
                    sawPlaceholder = true;
        if (n.kind == WidgetKind.panel)
            sawPanel = true;
    }
    assert(sawPlaceholder && !sawPanel);

    // Folding the heading folds its whole SECTION: one placeholder row for
    // the sibling run, nothing else.
    MdViewOptions opt2 = {foldedSpans: [0UL]};
    auto t2 = viewMarkdown(doc, opt2);
    size_t rich;
    foreach (ref const n; t2.nodes)
        if (n.kind == WidgetKind.rich)
            ++rich;
    assert(rich == 1, "the folded section renders as exactly one row");
}
