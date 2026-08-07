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
import sparkles.syntax.md.model : ColAlign, MdBlock, MdBlockKind, MdDecoration,
    MdDiffStatus, MdDoc, MdInline, MdInlineKind, Span;
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

    /// `codeBody.start` of the fence showing in each code group (`MDP22`).
    /// Source-anchored like `foldedSpans`, so a selection survives a
    /// rebuild and no per-group counter exists to drift; a group whose
    /// fences are all absent from this set shows its first.
    size_t[] activeCodeTabs;
    /// Whether a fence's header repeats its `[label]`. A code group's tab
    /// carries it instead, so the group's active fence clears this.
    bool fenceLabelInHeader = true;
    /// Non-zero makes a group's tabs click targets:
    /// `hitId = codeTabHitBase + fence.codeBody.start`, so an activation
    /// names the fence itself rather than an index into a list that a
    /// re-parse may have renumbered.
    size_t codeTabHitBase = 0;

    /// In-panel fence line numbers (`COD`): each code-fence body line gets
    /// a muted 1-based number gutter inside the panel.
    bool codeLineNumbers;

    /// `DVN6`: per-block diff verdicts, sorted by `spanStart`. A block whose
    /// `span.start` appears here renders decorated — added/removed tint the
    /// whole subtree through `proseSlot`, changed marks its `emphasis` ranges
    /// — and the verdict is inherited by everything nested inside it.
    const(MdDecoration)[] diffBlocks;

    /// The emphasis in force for the subtree being rendered (set by
    /// `viewBlock` from `diffBlocks`; not something a caller fills in).
    private MdEmphasis diffEmphasis;

    /// The emphasis to hand the inline mapper, or `null` when none is armed.
    private const(MdEmphasis)* emph() const return @safe pure nothrow @nogc
        => diffEmphasis.spans.length != 0 ? &diffEmphasis : null;

    /// Non-zero stamps every table cell wrapper with
    /// `key = tableKeyBase + cell.span.start` — source-anchored identity an
    /// interactive backend resolves back to the document's cell structure
    /// (2-D table selection, per-cell copy) via the cells' frames.
    size_t tableKeyBase = 0;

    /// Non-zero punches the whole-table copy button into a cutout of the
    /// table's top border, just before the corner (`╭──   ╮` — `TBL6`):
    /// `hitId = tableCopyHitBase + table.span.start`, source-anchored like
    /// the fence copy targets.
    size_t tableCopyHitBase = 0;

    /// The `span.start` of the table just copied (`size_t.max` = none): its
    /// cutout shows the copied glyph — feedback state lives in the app, like
    /// `copiedFence`.
    size_t copiedTable = size_t.max;
}

/// The emphasis in force while rendering a subtree: which source ranges are
/// marked and with what slot.
struct MdEmphasis
{
    const(Span)[] spans;
    Slot slot = Slot.inherit;
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

/**
Views a `::: code-group` (`MDP22`): a tab strip over exactly one fence.

The showing fence is named by its own `codeBody.start` in
`MdViewOptions.activeCodeTabs`, so the selection is source-anchored like a
fold and survives a rebuild; a group with no selection shows its first
fence. A tab's title is the fence's `[label]` with the brackets peeled,
falling back to its language — which is what an unlabelled ` ```ansi `
output fence inside a group needs, and what VitePress does.
*/
private uint viewCodeGroup(ref Builder b, ref const MdBlock blk,
    const(char)[] src, MdViewOptions opt)
{
    import sparkles.ui.components.chrome : tabStrip;
    import sparkles.ui.state : PressState;

    if (!blk.children.length)
        return blocksColumn(b, blk.children, src, opt);

    size_t active;
    string[] titles;
    size_t[] ids;
    foreach (i, ref const f; blk.children)
    {
        foreach (a; opt.activeCodeTabs)
            if (a == f.codeBody.start)
                active = i;
        titles ~= tabTitle(f);
        ids ~= opt.codeTabHitBase != 0
            ? opt.codeTabHitBase + f.codeBody.start : 0;
    }

    const strip = tabStrip(b, titles, active, 0, PressState.init,
        fitLabels: true, ids: ids);
    MdViewOptions inner = opt;
    inner.fenceLabelInHeader = false;
    const body = viewBlock(b, blk.children[active], src, inner);
    return b.add(Widget(kind: WidgetKind.column, children: [strip, body],
        width: SizeSpec.grow()));
}

/// A fence's tab title: its `[label]` unbracketed, else its language.
private string tabTitle(ref const MdBlock fence) @safe pure nothrow
{
    const(char)[] l = fence.label;
    if (l.length >= 2 && l[0] == '[' && l[$ - 1] == ']')
        l = l[1 .. $ - 1];
    if (!l.length)
        l = fence.infoLang;
    return l.idup;
}

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
            // Capture the folded block's identity BEFORE the sibling scan
            // advances `i`: re-reading blocks[i] inside the loop compared
            // every next heading against the just-consumed block (usually a
            // level-0 paragraph), so the scan swallowed the rest of the
            // document — and the placeholder then carried the LAST consumed
            // block's start as its unfold key, so the fold could never be
            // reopened.
            const foldIdx = i;
            const foldStart = blocks[i].span.start;
            const foldLevel = blocks[i].level;
            size_t srcEnd = blocks[i].span.end;
            if (blocks[i].kind == MdBlockKind.heading)
                while (i + 1 < blocks.length
                    && !(blocks[i + 1].kind == MdBlockKind.heading
                        && blocks[i + 1].level <= foldLevel))
                {
                    ++i;
                    srcEnd = blocks[i].span.end;
                }
            rows ~= collapsedFace(b, blocks[foldIdx], foldStart, srcEnd, src,
                opt, listDepth, quoteDepth);
            continue;
        }
        rows ~= viewBlock(b, blocks[i], src, opt, listDepth, quoteDepth);
    }
    // `grow`: fill the viewport (or the parent's content box) so full-width
    // chrome — heading bands, fence panels, rules — really is full-width.
    // Under an unbounded root the natural size still shrink-wraps, so a
    // hover popup keeps its content-sized measure.
    return b.add(Widget(kind: WidgetKind.column, children: rows, gap: 1,
        width: SizeSpec.grow()));
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
                case codeGroup:
                    walk(blocks[i].children);
                    break;

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

// The collapsed face of a folded region (`FLD3`): the block keeps its
// styled look — a heading its icon/accent/band, a themed fence its header
// band — with the `⋯ N lines` chip appended; the face is the unfold click
// target and its last identity span stretches over the whole region, so
// selection-copy of a fold yields the folded source. Blocks without a
// styled one-row face keep the raw-first-line placeholder.
private uint collapsedFace(ref Builder b, ref const MdBlock blk,
    size_t start, size_t end, const(char)[] src, MdViewOptions opt,
    int listDepth, int quoteDepth)
{
    const clampedEnd = end > src.length ? src.length : end;
    const foldHit = opt.foldHitBase != 0 ? opt.foldHitBase + start : opt.hitId;

    uint styledFace(Widget w)
    {
        import sparkles.ui.wrap : TextWrap;

        w.hitId = foldHit;
        // A face never wraps: the wrap engine re-derives sliced fragments'
        // srcEnd, which would clip the region identity back to the text.
        w.wrap = TextWrap.none;
        w.spans ~= TextSpan("  " ~ foldChip(src, start, clampedEnd),
            Slot.gutter, opt.baseStyle, noBreak: true);
        foreach_reverse (ref sp; w.spans)
            if (sp.srcStart != size_t.max)
            {
                sp.srcEnd = clampedEnd; // block-granular region identity
                break;
            }
        return b.add(w);
    }

    if (blk.kind == MdBlockKind.heading && opt.theme.present)
    {
        // Render the heading through its normal case, then re-shape the
        // produced rich node into the face (chip + hit id + identity).
        const id = viewBlock(b, blk, src, opt, listDepth, quoteDepth);
        Widget w = b.nodes[id];
        b.nodes = b.nodes[0 .. id]; // reclaim; styledFace re-adds
        return styledFace(w);
    }
    if (blk.kind == MdBlockKind.codeFence && opt.theme.present)
        return styledFace(themedFenceHeader(blk, opt));

    return foldPlaceholder(b, start, end, src, opt);
}

// The `⋯ N lines` chip text for a folded region.
private string foldChip(const(char)[] src, size_t start, size_t end) @safe
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.base.text.writers : writeInteger;

    size_t lines = 1;
    foreach (char ch; src[start .. end])
        if (ch == '\n')
            ++lines;
    SmallBuffer!(char, 32) n;
    writeInteger(n, lines);
    return "\u22EF " ~ n[].idup ~ " lines";
}

// The themed fence header band: devicon + language label, carrying the
// fence's opening line as identity — shared by the open panel (which
// composes the copy affordance beside it, `fenceHeaderRow`) and the
// collapsed face (which re-shapes this widget alone).
private Widget themedFenceHeader(ref const MdBlock blk, MdViewOptions opt)
{
    const icon = langIcon(blk.infoLang);
    const(char)[] lbl = (icon.length ? icon ~ " " : "")
        ~ (blk.infoLang.length ? blk.infoLang : "code");
    // Inside a code group the tab already says the label, so repeating it
    // in the header is noise; the language and copy affordance stay.
    if (blk.label.length && opt.fenceLabelInHeader)
        lbl = lbl ~ " " ~ blk.label;
    // With a fence hit base the whole band is a copy target, its identity
    // anchored at the body's source position.
    const headerHit = opt.fenceHitBase != 0
        ? opt.fenceHitBase + blk.codeBody.start : opt.hitId;
    return Widget(kind: WidgetKind.rich, spans: [
            TextSpan(lbl, Slot.code, codeStyle(opt),
                srcStart: blk.span.start,
                srcEnd: blk.codeBody.start)],
        slot: Slot.code, hitId: headerHit, stretch: true,
        paintBackground: true, padding: Insets.symmetric(0, 1),
        textStyle: codeStyle(opt),
        bgOverride: opt.theme.codeHeaderBg, hasBgOverride: true,
        fgOverride: opt.theme.codeFg, hasFgOverride: true);
}

// The open fence's header: the label band with the copy affordance at its
// right edge — the top-right corner the old top-border cutout put it in
// (`COD3`). Without a fence hit base there is nothing to click, so the
// band renders alone.
private uint fenceHeaderRow(ref Builder b, ref const MdBlock blk,
    MdViewOptions opt)
{
    if (opt.fenceHitBase == 0)
        return b.add(themedFenceHeader(blk, opt));

    const hit = opt.fenceHitBase + blk.codeBody.start;
    Widget lblW = themedFenceHeader(blk, opt);
    lblW.width = SizeSpec.grow();
    Widget iconW = Widget(kind: WidgetKind.rich, spans: [
            TextSpan(opt.copiedFence == blk.codeBody.start
                ? opt.glyphs.copiedIcon : opt.glyphs.copyIcon,
                Slot.code, codeStyle(opt), noBreak: true)],
        slot: Slot.code, hitId: hit, paintBackground: true,
        padding: Insets.symmetric(0, 1), textStyle: codeStyle(opt),
        bgOverride: opt.theme.codeHeaderBg, hasBgOverride: true,
        fgOverride: opt.theme.codeFg, hasFgOverride: true);
    return b.add(Widget(kind: WidgetKind.row,
        children: [b.add(lblW), b.add(iconW)],
        width: SizeSpec.grow(), hitId: hit));
}

private uint viewBlock(ref Builder b, ref const MdBlock blk, const(char)[] src,
    MdViewOptions opt, int listDepth = 0, int quoteDepth = 0)
{
    // `DVN6`: a decorated block hands its treatment to its whole subtree
    // through the options that already flow down it — an added or removed
    // block by taking over the prose slot (and, removed, the strike), a
    // changed one by arming the emphasis its words are marked with. No block
    // case below has to know a diff is being rendered.
    opt = decorated(opt, blk.span.start);

    if (opt.depthBudget <= 0) // recursion cap: degrade to the raw source slice
        return proseRow(b, [TextSpan(sliceOf(src, blk.span), opt.proseSlot,
            opt.baseStyle)], opt);

    final switch (blk.kind) with (MdBlockKind)
    {
        case document:
            return blocksColumn(b, blk.children, src, opt);

        case codeGroup:
            return viewCodeGroup(b, blk, src, opt);

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
                    &opt.theme, opt.emph);
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
            inlinesToSpans(blk.inlines, src, style, Slot.chromeAccent, spans,
                null, opt.emph);
            return proseRow(b, spans, opt);
        }

        case paragraph:
        {
            TextSpan[] spans;
            inlinesToSpans(blk.inlines, src, opt.baseStyle, opt.proseSlot, spans,
                opt.theme.present ? &opt.theme : null, opt.emph);
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
                    opt.theme.present ? &opt.theme : null, opt.emph);
                const lead = leaderHang(leader);
                rows ~= proseRow(b, spans, opt, lead);
                // Nested blocks (a sub-list, a nested paragraph) after the
                // first, indented by the item's leader width so depth reads
                // as the sum of ancestor leaders — 2 cells under "● ", 3
                // under "1. " — exactly where the item's own text starts.
                bool first = true;
                foreach (ref const c; item.children)
                {
                    if (c.kind == MdBlockKind.paragraph && first)
                    {
                        first = false;
                        continue;
                    }
                    const child = viewBlock(b, c, src, opt, listDepth + 1,
                        quoteDepth);
                    rows ~= b.add(Widget(kind: WidgetKind.panel,
                        children: [child], padding: Insets(0, 0, 0, lead)));
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

            // The in-panel number gutter (COD): 1-based, right-aligned over
            // the body's digit width, muted, synthetic (no identity).
            size_t bodyLines = 1;
            foreach (char c; code)
                if (c == '\n')
                    ++bodyLines;

            // `DVN6`: a fence is diffed by LINE, and its rows do not go
            // through the prose path, so a changed line is tinted as a whole
            // row. Offsets come from the body itself rather than from the
            // spans, which a fence renderer may leave unanchored.
            Slot rowSlot(size_t li) @safe
            {
                if (opt.diffEmphasis.spans.length == 0)
                    return Slot.code;
                size_t at, n;
                foreach (i, char c; code)
                {
                    if (c != '\n')
                        continue;
                    if (n++ == li)
                        return lineTouched(opt, blk.codeBody.start + at,
                            blk.codeBody.start + i);
                    at = i + 1;
                }
                return n == li
                    ? lineTouched(opt, blk.codeBody.start + at,
                        blk.codeBody.start + code.length)
                    : Slot.code;
            }
            int numW;
            for (auto n = bodyLines; n; n /= 10)
                ++numW;
            TextSpan numberSpan(size_t lineNo) @safe
            {
                import sparkles.base.smallbuffer : SmallBuffer;
                import sparkles.base.text.writers : writeInteger;

                SmallBuffer!(char, 24) t;
                writeInteger(t, lineNo);
                char[] cell;
                foreach (_; t[].length .. numW)
                    cell ~= ' ';
                cell ~= t[];
                cell ~= ' ';
                return TextSpan(cell.idup, Slot.gutter, codeStyle(opt),
                    noBreak: true);
            }

            if (styled.length)
            {
                foreach (li, line; styled)
                {
                    // Renderer offsets are body-relative; anchor them to the
                    // fence body's source position (the identity channel).
                    foreach (ref s; line)
                        if (s.srcStart != size_t.max)
                        {
                            s.srcStart += blk.codeBody.start;
                            s.srcEnd += blk.codeBody.start;
                        }
                    auto spans = line.length ? line
                        : [TextSpan(" ", Slot.code, codeStyle(opt))];
                    if (opt.codeLineNumbers)
                        spans = numberSpan(li + 1) ~ spans;
                    rows ~= b.add(Widget(kind: WidgetKind.rich, spans: spans,
                        slot: rowSlot(li), hitId: opt.hitId,
                        paintBackground: true, textStyle: codeStyle(opt)));
                }
            }
            else
            {
                size_t start = 0;
                size_t lineNo = 0;
                void line(const(char)[] t, size_t at) @safe
                {
                    auto spans = [
                        TextSpan(t.length ? t : " ", Slot.code, codeStyle(opt),
                            srcStart: blk.codeBody.start + at,
                            srcEnd: blk.codeBody.start + at + t.length)];
                    if (opt.codeLineNumbers)
                        spans = numberSpan(++lineNo) ~ spans;
                    rows ~= b.add(Widget(kind: WidgetKind.rich, spans: spans,
                        slot: lineTouched(opt, blk.codeBody.start + at,
                            blk.codeBody.start + at + t.length),
                        hitId: opt.hitId, paintBackground: true,
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
            const hdr = fenceHeaderRow(b, blk, opt);
            const pnl = b.add(panel);
            // Width-transparent wrapper: without `grow` this column would
            // shrink-wrap to the longest code line and the panel's own
            // `stretch` could never reach the viewport.
            return b.add(Widget(kind: WidgetKind.column, children: [hdr, pnl],
                width: SizeSpec.grow()));
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
                    // A cell is rendered here rather than through `viewBlock`,
                    // so its `DVN6` verdict has to be resolved here too — this
                    // is the level a re-aligned table's one real edit lands on.
                    const cellOpt = decorated(opt, cell.span.start);
                    TextStyle style = cellOpt.baseStyle;
                    style.bold = ri == 0; // the header row
                    inlinesToSpans(cell.inlines, src, style, cellOpt.proseSlot,
                        spans, opt.theme.present ? &opt.theme : null,
                        cellOpt.emph);
                    fillDiffTints(spans); // the cell path is not a prose row
                    trimCellEdges(spans); // measured text sizes the track
                    cellSpans[ri * cols + ci] = spans;
                    int w;
                    foreach (ref s; spans)
                        w += cast(int) cellsOf(s.text);
                    if (w > content[ci])
                        content[ci] = w;
                }

            auto tracks = new TrackSpec[](cols);
            tracks[] = TrackSpec.auto_;
            const widths = resolveTracks(tracks, content, 0);

            // The full table grid, as glyph runs (the old core-cli table
            // look): rounded outer corners, `│` column separators, a heavy
            // rule under the header row. Drawn as text rather than panel
            // decorations because the cell backends draw whole boxes, not
            // per-column inner rules — and glyphs render identically on
            // every backend (the GPU path draws box glyphs procedurally,
            // so they connect across cells).
            uint ruleRun(string text_)
            {
                Widget w = Widget(kind: WidgetKind.rich, spans: [
                        TextSpan(text_, Slot.border, opt.baseStyle,
                            noBreak: true)],
                    slot: Slot.border, wrap: TextWrap.none,
                    hitId: opt.hitId, textStyle: opt.baseStyle);
                if (opt.theme.present)
                {
                    w.fgOverride = opt.theme.ruleFg;
                    w.hasFgOverride = true;
                }
                return b.add(w);
            }

            string borderRow(string l, string fill, string mid, string r)
            {
                string s = l;
                foreach (ci; 0 .. cols)
                {
                    foreach (_; 0 .. widths[ci] + 2)
                        s ~= fill;
                    s ~= ci + 1 < cols ? mid : r;
                }
                return s;
            }

            auto rows = new uint[](0);
            // `TBL6`: the whole-table copy button sits in a 3-cell cutout of
            // the top border just before the corner (`╭──   ╮`), mirroring
            // the fence header's affordance; too-narrow tables skip it.
            const cutout = opt.tableCopyHitBase != 0
                && widths[cols - 1] + 2 >= 3;
            if (!cutout)
                rows ~= ruleRun(borderRow("╭", "─", "┬", "╮"));
            else
            {
                const hit = opt.tableCopyHitBase + blk.span.start;
                string prefix = "╭";
                foreach (ci; 0 .. cols)
                {
                    foreach (_; 0 .. widths[ci] + 2 - (ci + 1 == cols ? 3 : 0))
                        prefix ~= "─";
                    if (ci + 1 < cols)
                        prefix ~= "┬";
                }
                const copied = opt.copiedTable == blk.span.start;
                Widget iconW = Widget(kind: WidgetKind.rich, spans: [
                        TextSpan(" " ~ (copied ? opt.glyphs.copiedIcon
                            : opt.glyphs.copyIcon) ~ " ", Slot.gutter,
                            opt.baseStyle, noBreak: true)],
                    slot: Slot.gutter, wrap: TextWrap.none, hitId: hit,
                    textStyle: opt.baseStyle);
                if (opt.theme.present)
                {
                    iconW.fgOverride = copied ? opt.theme.accentGreen
                        : opt.theme.ruleFg;
                    iconW.hasFgOverride = true;
                }
                rows ~= b.container(WidgetKind.row,
                    [ruleRun(prefix), b.add(iconW), ruleRun("╮")]);
            }
            foreach (ri; 0 .. blk.children.length)
            {
                auto cells = new uint[](0);
                foreach (ci; 0 .. cols)
                {
                    cells ~= ruleRun("│");
                    auto spans = cellSpans[ri * cols + ci];
                    if (!spans.length)
                        spans = [TextSpan(" ", opt.proseSlot, opt.baseStyle)];
                    Widget cellW = Widget(kind: WidgetKind.rich, spans: spans,
                        hitId: opt.hitId, slot: opt.proseSlot,
                        textStyle: opt.baseStyle);
                    const a = ci < blk.aligns.length ? blk.aligns[ci]
                        : ColAlign.none;
                    // Alignment via a fixed-width single-child column (LAY8),
                    // one padding cell inside each separator.
                    const inner = b.add(cellW);
                    Widget colW = Widget(kind: WidgetKind.column,
                        children: [inner],
                        width: SizeSpec.fixed(widths[ci] + 2),
                        padding: Insets(0, 1, 0, 1),
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
                cells ~= ruleRun("│");
                rows ~= b.container(WidgetKind.row, cells);
                if (ri == 0)
                    rows ~= ruleRun(borderRow("┝", "━", "┿", "┥"));
            }
            rows ~= ruleRun(borderRow("╰", "─", "┴", "╯"));
            return b.container(WidgetKind.column, rows);
        }

        case listItem, tableRow, tableCell:
            // Handled by their parents; standalone appearance degrades.
            return blocksColumn(b, blk.children, src, opt, listDepth, quoteDepth);

        case htmlBlock:
            return proseRow(b, [TextSpan(sliceOf(src, blk.span), Slot.muted,
                opt.baseStyle)], opt);
    }
}

// A table cell's text, edge-trimmed: `| cell |` sources collapse to one
// leading/trailing space, which would widen the measured track and skew
// right/center alignment inside it. Collapsing guarantees at most one
// space per edge; the source identity of a trimmed span follows the text.
private void trimCellEdges(ref TextSpan[] spans) @safe
{
    while (spans.length && spans[0].text.length
        && spans[0].text[0] == ' ')
    {
        spans[0].text = spans[0].text[1 .. $];
        if (spans[0].srcStart != size_t.max)
            ++spans[0].srcStart;
        if (spans[0].text.length)
            break;
        spans = spans[1 .. $];
    }
    while (spans.length && spans[$ - 1].text.length
        && spans[$ - 1].text[$ - 1] == ' ')
    {
        spans[$ - 1].text = spans[$ - 1].text[0 .. $ - 1];
        if (spans[$ - 1].srcEnd != size_t.max && spans[$ - 1].srcEnd > 0)
            --spans[$ - 1].srcEnd;
        if (spans[$ - 1].text.length)
            break;
        spans = spans[0 .. $ - 1];
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
/// The slot for a fence body row covering `[start, end)`: the changed-line
/// tint when `DVN6` marked it, the plain code slot otherwise.
private Slot lineTouched(in MdViewOptions opt, size_t start, size_t end) @safe
{
    foreach (r; opt.diffEmphasis.spans)
        if (r.start < end && r.end > start)
            return opt.diffEmphasis.slot;
    return Slot.code;
}

/// `opt` with any verdict for the block starting at `spanStart` applied.
///
/// Added and removed take over the prose slot so every span the subtree emits
/// is tinted, and removed also strikes the base style: a deletion should read
/// as struck-out prose, not as a red paragraph the reviewer might mistake for
/// current text. Changed arms the word ranges instead, leaving the block
/// itself untinted — the words carry the answer.
private MdViewOptions decorated(MdViewOptions opt, size_t spanStart) @safe
{
    if (opt.diffBlocks.length == 0)
        return opt;

    size_t lo, hi = opt.diffBlocks.length;
    while (lo < hi)
    {
        const mid = lo + (hi - lo) / 2;
        if (opt.diffBlocks[mid].spanStart < spanStart)
            lo = mid + 1;
        else
            hi = mid;
    }
    if (lo >= opt.diffBlocks.length
        || opt.diffBlocks[lo].spanStart != spanStart)
        return opt;

    const d = opt.diffBlocks[lo];
    final switch (d.status) with (MdDiffStatus)
    {
        case unchanged:
            break;
        case added:
            opt.proseSlot = Slot.diffAdded;
            break;
        case removed:
            opt.proseSlot = Slot.diffRemoved;
            opt.baseStyle.strikethrough = true;
            break;
        case changed:
            opt.diffEmphasis = MdEmphasis(d.emphasis, Slot.diffEmphAdded);
            break;
    }
    return opt;
}

private uint proseRow(ref Builder b, TextSpan[] spans, MdViewOptions opt,
    int hang = 0)
{
    fillDiffTints(spans);
    return b.add(richWidget(spans, opt, hang));
}

/// A slot alone does not tint a span — a span's background is gated by
/// `paintBackground`, so that an inline-`code` pill is the only thing that
/// fills by default. `DVN6`'s tints are exactly the other case that should,
/// and this is the single funnel every prose row passes through.
private void fillDiffTints(TextSpan[] spans) @safe
{
    foreach (ref sp; spans)
        if (sp.slot == Slot.diffAdded || sp.slot == Slot.diffRemoved
            || sp.slot == Slot.diffEmphAdded || sp.slot == Slot.diffEmphRemoved)
            sp.paintBackground = true;
}

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
    Slot slot, ref TextSpan[] spans, scope const(MdViewTheme)* vt = null,
    scope const(MdEmphasis)* em = null)
{
    foreach (ref const inl; inls)
        final switch (inl.kind) with (MdInlineKind)
        {
            case text:
                pushProse(sliceOf(src, inl.span), base, slot, spans,
                    inl.span.start, em);
                break;
            case strong:
            {
                auto s = base;
                s.bold = true;
                inlinesToSpans(inl.children, src, s, slot, spans, vt, em);
                break;
            }
            case emphasis:
            {
                auto s = base;
                s.italic = true;
                inlinesToSpans(inl.children, src, s, slot, spans, vt, em);
                break;
            }
            case strikethrough:
            {
                auto s = base;
                s.strikethrough = true;
                inlinesToSpans(inl.children, src, s, slot, spans, vt, em);
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
                inlinesToSpans(inl.children, src, s, Slot.info, spans, vt, em);
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
                inlinesToSpans(inl.children, src, base, slot, spans, vt, em);
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
    ref TextSpan[] spans, size_t srcStart = size_t.max,
    scope const(MdEmphasis)* em = null)
{
    if (!text.length)
        return;
    char[] norm;
    norm.reserve(text.length);
    bool ws;
    // `DVN6`: emphasis is decided HERE because this is the one place that
    // still knows both the source offset and the output offset. Whitespace
    // collapsing makes them diverge, so a post-pass over the finished spans
    // could not place a boundary correctly.
    const marking = em !is null && em.spans.length != 0
        && srcStart != size_t.max;
    bool inEmph;
    size_t runStart;

    void flush(size_t at, bool emphasized)
    {
        if (norm.length == 0)
            return;
        spans ~= TextSpan(norm, emphasized ? em.slot : slot, style,
            srcStart: runStart,
            srcEnd: at);
        norm = null;
    }

    if (marking)
        runStart = srcStart;

    foreach (i, char c; text)
    {
        if (marking)
        {
            const here = srcStart + i;
            const nowEmph = covers(em.spans, here);
            if (nowEmph != inEmph)
            {
                if (ws && norm.length)
                    norm ~= ' ';
                ws = false;
                flush(here, inEmph);
                runStart = here;
                inEmph = nowEmph;
            }
        }
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
    if (marking)
    {
        flush(srcStart + text.length, inEmph);
        return;
    }
    if (norm.length)
        spans ~= TextSpan(norm, slot, style, // freshly allocated, never mutated
            srcStart: srcStart,
            srcEnd: srcStart != size_t.max ? srcStart + text.length : 0);
}

/// Is `offset` inside any of the (sorted, non-overlapping) ranges?
private bool covers(scope const(Span)[] ranges, size_t offset) @safe pure nothrow @nogc
{
    foreach (r; ranges)
    {
        if (offset < r.start)
            return false; // sorted: nothing later can contain it
        if (offset < r.end)
            return true;
    }
    return false;
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
                opt.theme.present ? &opt.theme : null, opt.emph);
            if (spans.length)
                rows ~= proseRow(b, spans, opt);
            continue;
        }
        rows ~= viewBlock(b, c, src, opt, listDepth, quoteDepth + 1);
    }
    // The title sits tight on the first body block (the old chrome — a
    // callout reads as one unit); further blocks keep the blank-line gap.
    if (rows.length > 1)
        rows = [b.container(WidgetKind.column, rows[0 .. 2])] ~ rows[2 .. $];
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

@("md.render_widgets.foldedHeadingSectionStopsAtTheNextPeer")
@safe unittest
{
    import std.algorithm.searching : canFind;
    import sparkles.ui.state : documentRows, hoverTargets;
    import sparkles.ui.layout : layout;

    // H2 A, its paragraph, a NESTED H3 with a paragraph, then a peer H2 C:
    // folding A must swallow through the H3 subsection and stop before C —
    // and the placeholder's unfold key must be A's start, not the last
    // consumed block's (the regression: the sibling scan re-read the level
    // and the start from the block it had just consumed).
    const src = "## A\n\nbody a\n\n### B\n\nbody b\n\n## C\n\nbody c\n";
    auto doc = MdDoc(MdBlock(kind: MdBlockKind.document, children: [
        MdBlock(kind: MdBlockKind.heading, level: 2, span: Span(0, 4),
            inlines: [MdInline(kind: MdInlineKind.text, span: Span(3, 4))]),
        MdBlock(kind: MdBlockKind.paragraph, span: Span(6, 12),
            inlines: [MdInline(kind: MdInlineKind.text, span: Span(6, 12))]),
        MdBlock(kind: MdBlockKind.heading, level: 3, span: Span(14, 19),
            inlines: [MdInline(kind: MdInlineKind.text, span: Span(18, 19))]),
        MdBlock(kind: MdBlockKind.paragraph, span: Span(21, 27),
            inlines: [MdInline(kind: MdInlineKind.text, span: Span(21, 27))]),
        MdBlock(kind: MdBlockKind.heading, level: 2, span: Span(29, 33),
            inlines: [MdInline(kind: MdInlineKind.text, span: Span(32, 33))]),
        MdBlock(kind: MdBlockKind.paragraph, span: Span(35, 41),
            inlines: [MdInline(kind: MdInlineKind.text, span: Span(35, 41))]),
    ]), src);

    enum hitBase = 1UL << 40;
    MdViewOptions opt = {foldedSpans: [0UL], foldHitBase: hitBase};
    auto tree = viewMarkdown(doc, opt);
    auto frames = layout(tree);
    auto rows = documentRows(tree, frames);

    // The placeholder spans A through B's body only; C and its body render.
    bool sawPlaceholder, sawC, sawBodyC, sawBodyA;
    foreach (ref const r; rows)
    {
        if (r.text.canFind("lines") && r.srcStart == 0 && r.srcEnd == 27)
            sawPlaceholder = true;
        if (r.text.canFind("C"))
            sawC = true;
        if (r.text.canFind("body c"))
            sawBodyC = true;
        if (r.text.canFind("body a"))
            sawBodyA = true;
    }
    assert(sawPlaceholder, "the placeholder covers exactly the section");
    assert(sawC && sawBodyC, "the peer section survives");
    assert(!sawBodyA, "the folded body is gone");

    // The unfold key is the FOLDED heading's start.
    bool sawKey;
    foreach (ref const t; hoverTargets(tree, frames))
        if (t.hitId == hitBase + 0)
            sawKey = true;
    assert(sawKey, "the placeholder unfolds the folded section");
}

@("md.render_widgets.codeGroup.oneFenceBehindTabs")
@safe unittest
{
    import sparkles.ui.widget : WidgetKind;

    // Two fences in a group: a labelled one and an unlabelled `ansi`
    // output block — the shape the repo's own docs use.
    const src = "::: code-group\n\n```js [config.js]\nA\n```\n\n```ansi\nB\n```\n\n:::";
    const doc = MdDoc(MdBlock(kind: MdBlockKind.document, children: [
        MdBlock(kind: MdBlockKind.codeGroup, span: Span(0, src.length),
            children: [
                MdBlock(kind: MdBlockKind.codeFence, infoLang: "js",
                    label: "[config.js]", span: Span(16, 39),
                    codeBody: Span(34, 36)),
                MdBlock(kind: MdBlockKind.codeFence, infoLang: "ansi",
                    span: Span(41, 54), codeBody: Span(49, 51)),
            ]),
    ]), src);

    // No selection: the first fence shows. Titles are the label with its
    // brackets peeled, falling back to the language for the unlabelled one.
    MdViewOptions opt = {codeTabHitBase: 1 << 21};
    auto tree = viewMarkdown(doc, opt);
    const(char)[][] titles;
    size_t[] ids;
    bool sawA, sawB;
    foreach (ref const n; tree.nodes)
    {
        if (n.kind == WidgetKind.text && n.hitId == 0 && n.text.length)
            titles ~= n.text;
        if (n.hitId >= (1 << 21))
            ids ~= n.hitId;
        foreach (ref const s; n.spans)
        {
            if (s.text == "A") sawA = true;
            if (s.text == "B") sawB = true;
        }
    }
    import std.algorithm.searching : canFind;
    assert(titles.canFind("config.js") && titles.canFind("ansi"));
    assert(sawA && !sawB, "only the active fence's body renders");

    // Tab ids are source-anchored to each fence's body, so two groups on a
    // page cannot mint the same id.
    assert(ids.canFind((1 << 21) + 34) && ids.canFind((1 << 21) + 49));

    // Selecting the second fence by ITS source offset swaps the body and
    // nothing else — the selection is not an index a re-parse can shift.
    MdViewOptions sel = {codeTabHitBase: 1 << 21, activeCodeTabs: [49UL]};
    auto t2 = viewMarkdown(doc, sel);
    bool sawA2, sawB2;
    foreach (ref const n; t2.nodes)
        foreach (ref const s; n.spans)
        {
            if (s.text == "A") sawA2 = true;
            if (s.text == "B") sawB2 = true;
        }
    assert(sawB2 && !sawA2);
}

@("render_widgets.diff.decoratedBlocksCarryTheirVerdict")
@safe unittest
{
    // `DVN6`: the view is told what happened to each block, keyed by span
    // start, and hands the verdict to that block's whole subtree.
    enum src = "kept\n\ngone\n\nfresh\n";
    MdDoc doc = {
        source: src,
        root: MdBlock(kind: MdBlockKind.document, children: [
            MdBlock(kind: MdBlockKind.paragraph, span: Span(0, 4),
                inlines: [MdInline(kind: MdInlineKind.text, span: Span(0, 4))]),
            MdBlock(kind: MdBlockKind.paragraph, span: Span(6, 10),
                inlines: [MdInline(kind: MdInlineKind.text, span: Span(6, 10))]),
            MdBlock(kind: MdBlockKind.paragraph, span: Span(12, 17),
                inlines: [MdInline(kind: MdInlineKind.text, span: Span(12, 17))]),
        ]),
    };

    MdViewOptions opt;
    opt.diffBlocks = [
        MdDecoration(6, MdDiffStatus.removed),
        MdDecoration(12, MdDiffStatus.added),
    ];
    auto tree = viewMarkdown(doc, opt);

    bool sawRemoved, sawAdded, sawPlain;
    foreach (ref n; tree.nodes)
        foreach (sp; n.spans)
        {
            if (sp.text == "gone")
            {
                sawRemoved = sp.slot == Slot.diffRemoved && sp.textStyle.strikethrough;
                // Struck, not merely tinted: a deletion must not read as text
                // that is still there.
            }
            else if (sp.text == "fresh")
                sawAdded = sp.slot == Slot.diffAdded;
            else if (sp.text == "kept")
                sawPlain = sp.slot != Slot.diffAdded && sp.slot != Slot.diffRemoved;
        }
    assert(sawRemoved, "a removed block renders struck through and tinted");
    assert(sawAdded, "an added block renders tinted");
    assert(sawPlain, "an undecorated block is untouched");
}

@("render_widgets.diff.changedWordsSplitTheirSpan")
@safe unittest
{
    // A changed block tints only the words that differ — and the split has to
    // land on the right bytes even though prose collapses whitespace on the
    // way to a span.
    enum src = "alpha beta gamma";
    MdDoc doc = {
        source: src,
        root: MdBlock(kind: MdBlockKind.document, children: [
            MdBlock(kind: MdBlockKind.paragraph, span: Span(0, src.length),
                inlines: [MdInline(kind: MdInlineKind.text,
                    span: Span(0, src.length))]),
        ]),
    };

    MdViewOptions opt;
    opt.diffBlocks = [MdDecoration(0, MdDiffStatus.changed, [Span(6, 10)])];
    auto tree = viewMarkdown(doc, opt);

    const(char)[] marked;
    const(char)[] plain;
    foreach (ref n; tree.nodes)
        foreach (sp; n.spans)
            if (sp.slot == Slot.diffEmphAdded)
                marked ~= sp.text;
            else
                plain ~= sp.text;
    assert(marked == "beta", "exactly the changed word is marked");
    assert(plain == "alpha  gamma" || plain == "alpha gamma",
        "the rest of the paragraph is untouched");
}
