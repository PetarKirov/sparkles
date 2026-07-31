// hue's terminal document viewer — the `workspace` split's right pane (and the
// whole screen when the explorer is hidden). Every view — the markdown
// preview, the twoslash overlay, and the raw highlighted source — renders
// through the composable widget pipeline. Painted into a `sparkles.tui.Grid`
// at the pane's origin; the workspace's `Terminal` cell-diffs each frame.
//
// Covers scrolling, a raw/preview toggle, live theme cycling, a cell scrollbar,
// mouse (wheel + scrollbar + drag-selection → OSC 52), incremental search,
// folding, and reflow on resize. Posix-only.
module tui;

version (Posix):

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.term_color : mix;
import sparkles.base.text.writers : writeInteger;

import sparkles.syntax : ColorDepth, HighlightEvent, LabelSet, ResolvedTheme,
    resolveTheme, RgbColor, Theme, toRgb;

import sparkles.syntax.md.model : MdBlock, MdBlockKind, Span;
import sparkles.syntax.md.render_widgets : foldableSpans, MdViewOptions,
    MdViewTheme, viewMarkdown;
import sparkles.syntax.render.widgets : CodeViewOptions, viewCodeDocument;
import sparkles.syntax.ts.injection : TsConfigCache;
import sparkles.twoslash.protocol : NodeType, TwoslashReturn;
import sparkles.twoslash.render_widgets : viewHoverPopup, viewTwoslashDocument;

import sparkles.tui : Cell, CellStyle, Color, Grid, PosixEvents, Terminal,
    TerminalOptions, TextAttr, UnderlineStyle;
import sparkles.tui.input : EndOfInput, Event, isEndOfInput, Key, KeyEvent,
    match, PointerAction, PointerButton, PointerEvent, ResizeEvent, WheelEvent;
import sparkles.ui.canvas : DrawOp;
import sparkles.ui.components.chrome : headerBar;
import sparkles.ui.display_list : buildDisplayList;
import sparkles.ui.geometry : Constraints, Point, Rect, SizeSpec;
import sparkles.ui.layout : Frame, layout;
import sparkles.ui.state : DisclosureState, DocRow, documentRows, HoverTarget,
    hoverTargets, scrollbarThumb, ScrollState, Selection, selectionRects,
    sourceOffsetAt;
import sparkles.ui.style : defaultTwoslashPalette, schemeForBackground, Slot;
import sparkles.ui.widget : Builder, Widget, WidgetKind, WidgetTree;
import sparkles.ui_tui : paintGrid;

import ansi_model : Attr, BackgroundMode;
import document : hueFenceRenderer;
import gui_preview : PreviewModel, quoteBarColors, quoteBarCycle;

private enum RgbColor fallbackFg = RgbColor(0xcc, 0xcc, 0xcc);
private enum RgbColor fallbackBg = RgbColor(0x1e, 0x1e, 0x1e);

// A cell style from the preview's neutral RgbColor + `Attr` bits (underline is a
// first-class field on the compact style, not a `TextAttr` bit).
private CellStyle cellStyle(RgbColor fg, bool hasBg, RgbColor bg, ubyte attrs)
    @safe pure nothrow @nogc
{
    TextAttr ta;
    if (attrs & Attr.bold)          ta = ta | TextAttr.bold;
    if (attrs & Attr.italic)        ta = ta | TextAttr.italic;
    if (attrs & Attr.strikethrough) ta = ta | TextAttr.strikethrough;
    return CellStyle(
        fg: Color.fromRgb(fg),
        bg: hasBg ? Color.fromRgb(bg) : Color.init,
        attrs: ta,
        underline: (attrs & Attr.underline) ? UnderlineStyle.single : UnderlineStyle.none);
}

private char lowerAscii(char c) @safe pure nothrow @nogc
    => (c >= 'A' && c <= 'Z') ? cast(char)(c + 32) : c;

// Case-insensitive substring test (ASCII fold; allocation-free).
private bool containsIC(scope const(char)[] hay, scope const(char)[] needle) @safe pure nothrow @nogc
{
    if (needle.length == 0 || needle.length > hay.length)
        return needle.length == 0;
    foreach (i; 0 .. hay.length - needle.length + 1)
    {
        size_t j;
        while (j < needle.length && lowerAscii(hay[i + j]) == lowerAscii(needle[j]))
            ++j;
        if (j == needle.length)
            return true;
    }
    return false;
}

/// The scrolling viewer state: the document (markdown model or raw source), the
/// theme list, and the current scroll / theme / view-mode. The active view's
/// widget tree is laid out once per theme / width / view change; each frame
/// paints its precomputed ops into a cell grid with a scroll offset.
struct PreviewTui
{
    string title;
    const(char)[] source;
    const(HighlightEvent)[] events;
    string lang;                    // canonical language (CST fold provider)
    PreviewModel model;             // present ⇒ a markdown file (preview available)
    TwoslashReturn tw;              // non-empty code ⇒ a twoslash document
    TsConfigCache* cache;           // fence highlighting for the widget markdown
                                    // path (null ⇒ plain fence bodies)
    LabelSet labels;
    const(string)[] names;          // theme names, parallel to `themes`
    immutable(Theme)[] themes;
    BackgroundMode background;      // (kept for the caller; the viewer paints full-bg)
    ColorDepth depth;               // (unused: the cell renderer emits truecolor)

    int tabWidth = 4;               // tab stops in the raw view
    bool listWhitespace;            // vim `list` whitespace glyphs
    bool codeLineNumbers = true;    // in-panel fence numbers

    private size_t themeIdx;
    private long top;               // first visible visual line
    private bool sbDragging;        // a scrollbar grab owns the pointer
    private bool showPreview;       // preview vs raw source (Tab)
    private int width, height;      // pane size in cells
    /// Grid column of the pane's left edge — 0 when full-screen; the split
    /// workspace places the viewer right of the explorer. Pointer events are
    /// translated to pane-local coordinates by the caller.
    int originX;
    private ResolvedTheme theme;
    private RgbColor pageFg, pageBg, gutterFg;
    private RgbColor[quoteBarCycle] bars;
    private RgbColor sbTrack, sbThumb; // scrollbar track / thumb (theme-tinted)

    // Incremental search (`/`): `searching` is input mode; `qbuf[0 .. qlen]` is
    // the query, reused by `n`/`N`.
    private bool searching;
    private char[256] qbuf;
    private size_t qlen;

    // Selection (mouse drag) → OSC 52 copy: the shared STM3 machine over
    // visual line indices ("no selection" is a mode, not -1); `selBg` tints
    // the selected lines. `clip` holds a pending OSC 52 sequence that the
    // loop flushes after a copy.
    private Selection!long sel;
    private RgbColor selBg;
    private SmallBuffer!char clip;
    private bool clipReady;

    // The widget markdown path (M10): the preview is one laid-out widget tree,
    // painted from precomputed ops with a scroll offset. `mdRows` (the identity
    // channel aggregated per visual row) drives search and selection; the hit
    // targets carry the fences' source-anchored copy identity.
    private WidgetTree mdTree;
    private Frame[] mdFrames;
    private DrawOp[] mdOps;
    private DocRow[] mdRows;
    private HoverTarget[] mdTargets;
    private Span[] mdFences;        // codeFence body spans, resolved on copy

    // Copy feedback: the just-copied fence's body start (its header shows the
    // ✔ glyph) until the next event — the loop is event-driven, no timed flash.
    private size_t copiedFenceSrc = size_t.max;

    // Fence hit ids live above this base: `hitId - fenceHitBase` is the fence
    // body's source byte offset (source-anchored identity, no counters).
    private enum size_t fenceHitBase = size_t.max / 2 + 1;

    // Fold placeholders live above this (disjoint) base; `hitId - foldHitBase`
    // is the folded region's span start — the fold key (`FLD2`/`STM5`).
    private enum size_t foldHitBase = size_t.max / 4 * 3 + 1;

    // Content folding (`FLD`): the one disclosure machine, keyed by source
    // span start (default open; the exceptions are the folded regions), plus
    // the document's foldable spans (the `FSR3` provider) and the pending
    // 'z' of the vim fold sequences (za/zz, zc, zo, zR, zM).
    private DisclosureState!size_t folds = DisclosureState!size_t(true);
    private Span[] foldable;
    private char zPending;

    // Twoslash hover popups in the pane: the hover-typed node indices (for
    // `p` cycling) and the selected one (-1 = none; click toggles).
    private size_t[] hoverNodes;
    private int hoverSel = -1;

    private const(char)[] query() const return @safe pure nothrow @nogc => qbuf[0 .. qlen];

    /// The pane is consuming typed text (the workspace must not steal keys).
    bool inputActive() const @safe pure nothrow @nogc => searching;

    /// Selects the theme by index (the workspace initializes the pane; the
    /// first `relayout` resolves it).
    void setTheme(size_t idx) @safe pure nothrow @nogc
    {
        themeIdx = idx < names.length ? idx : 0;
    }

    /// The active theme index — the workspace watches it to re-skin the
    /// explorer pane when ←/→ cycles the theme (`XPL5`).
    size_t themeIndex() const @safe pure nothrow @nogc => themeIdx;

    /// The active line selection, read-only — the workspace (and its tests)
    /// observe it to verify pointer-capture routing.
    Selection!long selection() const @safe pure nothrow @nogc => sel;

    /// Sets the pane size in cells (the workspace arranges; `relayout` after).
    void resize(int w, int h) @safe pure nothrow @nogc
    {
        width = w;
        height = h;
    }

    /// The pending OSC 52 clipboard write, if any (cleared by the take) — the
    /// event loop flushes it out of band after the frame.
    const(char)[] takeClipboard() return @safe pure nothrow @nogc
    {
        if (!clipReady)
            return null;
        clipReady = false;
        return clip[];
    }

    /// Visual line count of the active view — the scroll/selection/search space.
    private long lineCount() const @safe pure nothrow @nogc
        => cast(long) mdRows.length;

    /// Rebuild the laid-out lines for the current theme / width / view mode (GC;
    /// run on a theme, resize, or toggle change — never per frame).
    void relayout() @system
    {
        theme = resolveTheme(themes[themeIdx], labels);
        pageFg = toRgb(theme.defaults.fg, fallbackFg);
        pageBg = toRgb(theme.defaults.bg, fallbackBg);
        gutterFg = mix(pageFg, pageBg, 0.5); // muted leader / decorations
        bars = quoteBarColors(theme, pageFg, pageBg);
        // Scrollbar chrome + selection: tint toward the theme link color (gui.d).
        const linkC = toRgb(theme[theme.labels.resolve("markup.link")].fg, pageFg);
        sbTrack = mix(pageBg, linkC, 0.22);
        sbThumb = mix(pageBg, linkC, 0.5);
        selBg = mix(pageBg, linkC, 0.4);
        rebuildMd();
        clampTop();
    }

    // Rebuild the active view's widget pipeline: view → layout → display
    // list, plus the derived row index (search/selection) and hit targets
    // (fence copy). Lays out one column narrower — the last column holds the
    // scrollbar.
    private void rebuildMd() @system
    {
        const w = width < 9 ? 8 : width - 1;
        if (!showPreview || (!model.present && !tw.code.length))
        {
            // The raw view: the highlighted source as the same widget
            // pipeline (one painter for every view kind). Fold ranges come
            // from the CST provider (FSR1/FSR2) when a grammar is known.
            import sparkles.syntax.ts.folds : foldableSpansCst;
            import sparkles.ui.wrap : TextWrap;

            foldable = cache !is null && lang.length
                ? foldableSpansCst(*cache, lang, source) : null;
            Span[] closed;
            foreach (sp; foldable)
                if (!folds.isOpen(sp.start))
                    closed ~= sp;
            mdTree = viewCodeDocument(source, events, &theme, pageFg,
                CodeViewOptions(foldedRegions: closed,
                    foldHitBase: foldHitBase, tabWidth: tabWidth,
                    listWhitespace: listWhitespace,
                    whitespaceFg: gutterFg, hasWhitespaceFg: true));
            mdFrames = layout(mdTree, Constraints(maxW: w));
            mdOps = buildDisplayList(mdTree, mdFrames,
                themes[themeIdx].effectivePalette, pageFg, pageBg);
            mdRows = documentRows(mdTree, mdFrames);
            mdTargets = hoverTargets(mdTree, mdFrames);
            mdFences.length = 0;
            hoverNodes.length = 0;
            return;
        }
        if (tw.code.length)
        {
            // A twoslash document: the whole-document widget view (code as
            // resolved spans + fused decorations + interleaved blocks).
            mdTree = viewTwoslashDocument(tw, events, &theme, pageFg, cache);
            mdFrames = layout(mdTree, Constraints(maxW: w));
            mdOps = buildDisplayList(mdTree, mdFrames,
                defaultTwoslashPalette(schemeForBackground(pageBg)),
                pageFg, pageBg);
            mdRows = documentRows(mdTree, mdFrames);
            mdTargets = hoverTargets(mdTree, mdFrames);
            mdFences.length = 0;
            foldable = null;
            hoverNodes.length = 0;
            foreach (ni, ref const n; tw.nodes)
                if (n.type == NodeType.hover)
                    hoverNodes ~= ni;
            return;
        }
        MdViewOptions opt = {
            theme: MdViewTheme.derive(theme, pageFg, pageBg),
            fenceHitBase: fenceHitBase,
            copiedFence: copiedFenceSrc,
            foldedSpans: folds.exceptions,
            foldHitBase: foldHitBase,
            codeLineNumbers: codeLineNumbers,
        };
        foldable = foldableSpans(model.doc);
        if (cache !is null)
            opt.fenceRenderer = hueFenceRenderer(cache, &theme, pageFg);
        mdTree = viewMarkdown(model.doc, opt);
        mdFrames = layout(mdTree, Constraints(maxW: w));
        mdOps = buildDisplayList(mdTree, mdFrames,
            themes[themeIdx].effectivePalette, pageFg, pageBg);
        mdRows = documentRows(mdTree, mdFrames);
        mdTargets = hoverTargets(mdTree, mdFrames);
        mdFences.length = 0;
        collectFences(model.doc.root, mdFences);
    }

    private static void collectFences(in MdBlock b, ref Span[] fences) @safe
    {
        if (b.kind == MdBlockKind.codeFence)
            fences ~= b.codeBody;
        foreach (ref const c; b.children)
            collectFences(c, fences);
    }

    private int bodyRows() const @safe pure nothrow @nogc
        => height > 2 ? height - 2 : 1;

    private long maxTop() const @safe pure nothrow @nogc
    {
        const over = lineCount - bodyRows();
        return over > 0 ? over : 0;
    }

    private void clampTop() @safe pure nothrow @nogc
    {
        if (top > maxTop) top = maxTop;
        if (top < 0) top = 0;
    }

    private void clampSel() @safe pure nothrow @nogc
    {
        if (!sel.active)
            return;
        const last = lineCount - 1;
        long clamp(long v) => v > last ? last : (v < 0 ? 0 : v);
        sel = Selection!long(true, clamp(sel.anchor), clamp(sel.focus));
    }

    // Copy the selected visual lines' **original source** (SEL parity): the min
    // src offset .. max src end over the selected lines' content runs (decoration
    // runs have no src offset and are excluded), written to the system clipboard
    // via OSC 52. Clears the selection.
    private void copySelection() @system
    {
        if (!sel.active || lineCount == 0)
            return;
        const lo = sel.lo, hi = sel.hi;
        size_t a = size_t.max, b;
        bool any;
        foreach (i; lo .. hi + 1)
        {
            if (i < 0 || i >= lineCount)
                continue;
            // The aggregated identity channel: one source range per row.
            const r = mdRows[cast(size_t) i];
            if (r.srcStart == size_t.max)
                continue; // decoration-only row (band, border, rule)
            any = true;
            if (r.srcStart < a)
                a = r.srcStart;
            if (r.srcEnd > b)
                b = r.srcEnd;
        }
        if (!any || a >= b || b > source.length)
        {
            sel = Selection!long.cleared;
            return;
        }
        writeClipboard(source[a .. b]);
        sel = Selection!long.cleared;
    }

    // Queue `text` for the system clipboard via OSC 52 (`ESC ] 52 ; c ; <b64> BEL`),
    // the only portable in-band terminal clipboard; the loop flushes `clip` after.
    private void writeClipboard(scope const(char)[] text) @system
    {
        import std.base64 : Base64;

        clip.clear();
        clip.put("\x1b]52;c;");
        clip.put(Base64.encode(cast(const(ubyte)[]) text));
        clip.put("\x07");
        clipReady = true;
    }

    // Does visual line `i` contain the query (case-insensitive)? Every view
    // searches the aggregated row text.
    private bool lineMatches(size_t i) @safe
        => qlen != 0 && containsIC(mdRows[i].text, query);

    // The nearest matching line from `from` in the given direction (wrapping);
    // scrolls it to the top when found.
    private void jumpMatch(long from, bool forward) @safe
    {
        const n = lineCount;
        if (n == 0 || qlen == 0)
            return;
        foreach (step; 0 .. n)
        {
            const i = forward ? (from + step) % n : ((from - step) % n + n) % n;
            if (lineMatches(cast(size_t) i))
            {
                top = i;
                clampTop();
                return;
            }
        }
    }

    // ── Painting into the cell grid ──────────────────────────────────────────

    /// Replaces the viewed document (the workspace's pane reuses the session):
    /// content swaps, scroll/search/selection/folds reset, layout rebuilds.
    void setDocument(string title_, const(char)[] source_,
        const(HighlightEvent)[] events_, PreviewModel model_,
        bool startPreview, TwoslashReturn tw_ = TwoslashReturn.init,
        string lang_ = null) @system
    {
        title = title_;
        source = source_;
        events = events_;
        model = model_;
        tw = tw_;
        lang = lang_;
        hoverSel = -1;
        showPreview = startPreview && (model.present || tw.code.length != 0);
        top = 0;
        sel = Selection!long.cleared;
        searching = false;
        qlen = 0;
        copiedFenceSrc = size_t.max;
        folds = DisclosureState!size_t(true);
        relayout();
    }

    /// Paint the whole frame into `g` (immediate mode). The library diffs it
    /// against the last frame, so only changed cells reach the wire.
    void paint(ref Grid g) @system
    {
        // Fill the pane with the theme background (the full-screen look).
        g.fillRect(cast(ushort) originX, 0, cast(ushort) width,
            cast(ushort) height, cellStyle(pageFg, true, pageBg, 0));
        paintHeader(g);

        paintMarkdown(g);
        paintHoverPopup(g);
        paintScrollbar(g);
        paintStatus(g);
    }

    // Paint the markdown widget tree's precomputed ops with a scroll offset:
    // ops are in document cell coordinates, the viewport shows doc rows
    // `top .. top+rows` at grid rows `1 ..`, and the base clip keeps the body
    // out of the chrome rows. Selection tints the painted rows in place.
    private void paintMarkdown(ref Grid g) @system
    {
        const rows = bodyRows();
        paintGrid(g, pageBg, mdOps, originX, cast(int)(1 - top),
            Rect(0, cast(int) top, width, rows));
        if (!sel.active)
            return;
        const selFill = Color.fromRgb(selBg);
        foreach (i; sel.lo .. sel.hi + 1)
        {
            const gy = 1 + i - top;
            if (gy < 1 || gy > rows)
                continue;
            foreach (x; 0 .. (width > 1 ? width - 1 : 0))
                g[cast(ushort)(originX + x), cast(ushort) gy].style.bg = selFill;
        }
    }

    // The selected hover token's popup (twoslash documents), composited over
    // the pane below the token — the shared viewHoverPopup chrome. The token
    // rect comes from the identity channel.
    private void paintHoverPopup(ref Grid g) @system
    {
        if (hoverSel < 0 || hoverSel >= cast(int) hoverNodes.length)
            return;
        import sparkles.twoslash.overlay : withoutQuickinfoPrefix;
        import sparkles.twoslash.render_widgets : signatureSpans;
        import sparkles.ui.widget : TextSpan;

        const n = tw.nodes[hoverNodes[hoverSel]];
        auto rs = selectionRects(mdTree, mdFrames, n.start, n.start + n.length);
        if (!rs.length)
            return;
        // With a grammar cache the signature renders as resolved-color spans
        // inside the widget model (the same mapping the GUI uses).
        TextSpan[] sig = cache !is null
            ? signatureSpans(*cache, (() @trusted => &theme)(), pageFg,
                withoutQuickinfoPrefix(n.text)) : null;
        auto tree = viewHoverPopup(tw, hoverNodes[hoverSel], sig);
        auto frames = layout(tree);
        auto ops = buildDisplayList(tree, frames,
            defaultTwoslashPalette(schemeForBackground(pageBg)), pageFg, pageBg);
        paintGrid(g, pageBg, ops, originX + rs[0].x,
            cast(int)(rs[0].y - top + 2));
    }

    // Paint a one-row chrome bar (the shared WGT17 headerBar view) at grid row
    // `y` through the full widget pipeline: view → layout → display list →
    // the ui-tui GridCanvas. The slots resolve against the theme's palette.
    private void paintBar(ref Grid g, int y, uint[] leading, uint[] center,
        uint[] trailing, ref Builder b) @system
    {
        const bar = headerBar(b, leading, center, trailing);
        Widget colW = Widget(kind: WidgetKind.column, children: [bar],
            width: SizeSpec.fixed(width));
        const col = b.add(colW);
        auto tree = b.finish(col);
        auto ops = buildDisplayList(tree, layout(tree),
            themes[themeIdx].effectivePalette, pageFg, pageBg);
        paintGrid(g, pageBg, ops, originX, y);
    }

    private void paintHeader(ref Grid g) @system
    {
        import std.conv : text;

        auto b = Builder();
        const name = b.add(Widget(kind: WidgetKind.text, text: title,
            slot: Slot.chromeAccent));
        const mid = b.add(Widget(kind: WidgetKind.text, text: text(
            names[themeIdx], " (", themeIdx + 1, "/", names.length, ")  ·  ",
            (showPreview && model.present) ? "preview" : "raw")));
        const pos = b.add(Widget(kind: WidgetKind.text,
            text: text(top + 1, "/", lineCount), slot: Slot.gutter));
        paintBar(g, 0, [name], [mid], [pos], b);
    }

    private void paintStatus(ref Grid g) @system
    {
        import std.conv : text;

        const y = height > 0 ? height - 1 : 0;
        auto b = Builder();
        const line = b.add(Widget(kind: WidgetKind.text,
            text: searching ? text("/", query, "▏")
                : "scroll ↑↓ · ←→ theme · Tab raw/preview · / search · za fold · drag+y copy · q quit",
            slot: searching ? Slot.inherit : Slot.gutter));
        paintBar(g, y, [line], null, null, b);
    }

    // A cell scrollbar in the last column across the body rows, sized/positioned
    // to the visible fraction. Only shown when the document overflows the viewport.
    private void paintScrollbar(ref Grid g) @system
    {
        const rows = bodyRows();
        if (lineCount <= rows || g.cols < 2 || originX + width > g.cols)
            return;
        // The one thumb formula (STM2) — the GUI renders the same geometry.
        const thumb = scrollbarThumb(cast(size_t) lineCount, rows, top, rows);

        const col = cast(ushort)(originX + width - 1);
        foreach (r; 0 .. rows)
        {
            const inThumb = r >= thumb.start && r < thumb.start + thumb.extent;
            g.putText(col, cast(ushort)(r + 1), inThumb ? "█" : "░",
                cellStyle(inThumb ? sbThumb : sbTrack, true, pageBg, 0));
        }
    }

    // ── Input ────────────────────────────────────────────────────────────────

    // Copy a fence's raw body to the clipboard (OSC 52), resolved from its
    // source-anchored hit id, and rebuild so its header shows the ✔ glyph.
    private void copyFenceAt(size_t bodyStart) @system
    {
        foreach (sp; mdFences)
            if (sp.start == bodyStart && sp.end <= source.length)
            {
                writeClipboard(source[sp.start .. sp.end]);
                copiedFenceSrc = bodyStart;
                rebuildMd();
                return;
            }
    }

    /// The fold family's directed op (`FLD5`, mirroring the GUI's).
    enum FoldOp : ubyte
    {
        toggle, /// `za`/`zz`: unfold the innermost folded region, else fold
        close,  /// `zc`: fold the innermost still-open foldable region
        open,   /// `zo`: unfold the innermost folded region
    }

    // Applies `op` at the selection (else the top row), over the row's
    // source identity.
    private void foldAt(FoldOp op) @system
    {
        const rowIdx = sel.active ? sel.lo : top;
        if (rowIdx < 0 || rowIdx >= cast(long) mdRows.length
            || mdRows[cast(size_t) rowIdx].srcStart == size_t.max)
            return;
        const off = mdRows[cast(size_t) rowIdx].srcStart;

        size_t innermost(bool wantOpen)
        {
            size_t best = size_t.max, bestLen = size_t.max;
            foreach (sp; foldable)
                if (folds.isOpen(sp.start) == wantOpen && off >= sp.start
                    && off < sp.end && sp.end - sp.start < bestLen)
                {
                    best = sp.start;
                    bestLen = sp.end - sp.start;
                }
            return best;
        }

        size_t best = op == FoldOp.close ? innermost(true) : innermost(false);
        if (best == size_t.max && op == FoldOp.toggle)
            best = innermost(true);
        if (best == size_t.max)
            return;
        folds = folds.toggled(best);
        rebuildMd();
        clampTop();
    }

    // `zR` / `zM`: open every fold, or fold every foldable region.
    private void setAllFolds(bool folded) @system
    {
        folds = DisclosureState!size_t(true);
        if (folded)
            foreach (sp; foldable)
                folds = folds.closed(sp.start);
        rebuildMd();
        clampTop();
    }

    // `z1`–`z9`: fold to nesting level (vim's foldlevel) — regions nested
    // `level` deep or deeper fold, shallower ones open. Depth via an
    // enclosing-ends stack over the source-ordered, properly nested regions.
    private void foldToLevel(int level) @system
    {
        folds = DisclosureState!size_t(true);
        size_t[] ends;
        foreach (sp; foldable)
        {
            while (ends.length && ends[$ - 1] <= sp.start)
                ends = ends[0 .. $ - 1];
            if (cast(int) ends.length >= level)
                folds = folds.closed(sp.start);
            ends ~= sp.end;
        }
        rebuildMd();
        clampTop();
    }

    /// Apply an event; returns false to quit.
    bool handle(in Event e) @system
    {
        if (copiedFenceSrc != size_t.max)
        {
            copiedFenceSrc = size_t.max; // the ✔ flash lasts until the next event
            rebuildMd();
        }
        if (searching)
            return handleSearch(e);
        return e.match!(
            (in PointerEvent p) => handlePointer(p),
            (in WheelEvent w) { top += 3 * w.dy; clampTop(); return true; },
            (in KeyEvent k) => handleKey(k),
            (in EndOfInput _) => false,
            _ => true,
        );
    }

    private bool handleKey(in KeyEvent e) @system
    {
        const rows = bodyRows();
        switch (e.key)
        {
            case Key.up:       top -= 1; clampTop(); break;
            case Key.down:     top += 1; clampTop(); break;
            case Key.pageUp:   top -= rows; clampTop(); break;
            case Key.pageDown: top += rows; clampTop(); break;
            case Key.home:     top = 0; break;
            case Key.end:      top = maxTop; break;
            case Key.left:
                themeIdx = themeIdx == 0 ? names.length - 1 : themeIdx - 1;
                relayout();
                break;
            case Key.right:
                themeIdx = themeIdx + 1 == names.length ? 0 : themeIdx + 1;
                relayout();
                break;
            case Key.tab:
                if (model.present)
                {
                    showPreview = !showPreview;
                    relayout();
                }
                break;
            case Key.escape:
                if (hoverSel >= 0)
                {
                    hoverSel = -1;
                    break;
                }
                return false;
            case Key.char_:
            {
                const pk = zPending;
                zPending = 0;
                switch (e.ch)
                {
                    case 'q': return false;
                    case 'p': // cycle the twoslash hover popups
                        if (hoverNodes.length)
                            hoverSel = (hoverSel + 1) % cast(int) hoverNodes.length;
                        break;
                    case 'j': top += 1; clampTop(); break;
                    case 'k': top -= 1; clampTop(); break;
                    case 'g': top = 0; break;
                    case 'G': top = maxTop; break;
                    case '/': searching = true; qlen = 0; break;
                    case 'n': jumpMatch(top + 1, true); break;
                    case 'N': jumpMatch(top - 1, false); break;
                    case 'y': copySelection(); break;
                    // The vim fold family (FLD5): z arms; then a/z toggle,
                    // c close, o open, R open-all, M fold-all.
                    case 'z':
                        if (pk == 'z')
                            foldAt(FoldOp.toggle);
                        else
                            zPending = 'z';
                        break;
                    case 'a':
                        if (pk == 'z')
                            foldAt(FoldOp.toggle);
                        break;
                    case 'c':
                        if (pk == 'z')
                            foldAt(FoldOp.close);
                        break;
                    case 'o':
                        if (pk == 'z')
                            foldAt(FoldOp.open);
                        break;
                    case 'R':
                        if (pk == 'z')
                            setAllFolds(false);
                        break;
                    case 'M':
                        if (pk == 'z')
                            setAllFolds(true);
                        break;
                    case '1': .. case '9':
                        if (pk == 'z')
                            foldToLevel(cast(int)(e.ch - '0'));
                        break;
                    default: break;
                }
                break;
            }
            default: break;
        }
        return true;
    }

    private bool handlePointer(in PointerEvent e) @system
    {
        const rows = bodyRows();
        if (e.button == PointerButton.left
            && e.action == PointerAction.release)
        {
            sbDragging = false;
            return true;
        }
        // A scrollbar grab OWNS the pointer: the press must land on the
        // last column, but the drag tracks wherever the pointer strays
        // (never falling into the selection branch) until release —
        // and symmetrically, a selection drag crossing the last column
        // never jumps the scroll.
        if (e.button == PointerButton.left
            && ((e.action == PointerAction.press && e.pos.x == width - 1
                    && e.pos.y >= 1 && e.pos.y <= rows)
                || (e.action == PointerAction.drag && sbDragging)))
        {
            sbDragging = true;
            // The STM2 inverse mapping: thumb-aware, so a drag lands the
            // thumb's leading edge where the pointer is.
            top = ScrollState(top)
                .draggedTo(e.pos.y - 1, cast(size_t) lineCount, rows, rows)
                .offset;
            clampTop();
            return true;
        }
        // 0-based cells: row 0 is the header, the body spans rows 1 .. rows.
        if (e.button == PointerButton.left
            && (e.action == PointerAction.press || e.action == PointerAction.drag)
            && e.pos.y >= 1 && e.pos.y <= rows)
        {
            // Body — a click on a fence header band copies its body (and
            // doesn't select): the hit targets are in document cell
            // coordinates, topmost last, and a fence's id encodes its
            // body's source offset. Otherwise start (press) or extend
            // (drag) a line selection.
            const line = top + (e.pos.y - 1);
            if (showPreview && e.action == PointerAction.press
                && tw.code.length)
            {
                const off = sourceOffsetAt(mdTree, mdFrames,
                    Point(e.pos.x, cast(int) line));
                if (off >= 0)
                    foreach (i, ni; hoverNodes)
                        if (off >= cast(long) tw.nodes[ni].start
                            && off < cast(long)(tw.nodes[ni].start
                                + tw.nodes[ni].length))
                        {
                            hoverSel = hoverSel == cast(int) i
                                ? -1 : cast(int) i;
                            return true;
                        }
                if (hoverSel >= 0)
                {
                    hoverSel = -1; // a click elsewhere dismisses the popup
                    return true;
                }
            }
            if (e.action == PointerAction.press)
            {
                const p = Point(e.pos.x, cast(int) line);
                foreach_reverse (ref const t; mdTargets)
                {
                    if (t.hitId >= foldHitBase && t.rect.contains(p))
                    {
                        folds = folds.toggled(t.hitId - foldHitBase);
                        rebuildMd();
                        return true;
                    }
                    if (t.hitId >= fenceHitBase && t.rect.contains(p))
                    {
                        copyFenceAt(t.hitId - fenceHitBase);
                        return true;
                    }
                }
            }
            sel = e.action == PointerAction.press
                ? Selection!long.started(line) : sel.extended(line);
            clampSel();
        }
        return true;
    }

    // Key handling while typing a search query (`/…`): printable keys extend it,
    // backspace trims, Enter commits, Esc cancels; the view live-jumps to the
    // first match as the query changes.
    private bool handleSearch(in Event ev) @system
    {
        return ev.match!((in KeyEvent e) {
            searchKey(e);
            return true;
        }, (in EndOfInput _) => false, _ => true);
    }

    private void searchKey(in KeyEvent e) @system
    {
        switch (e.key)
        {
            case Key.char_:
                if (qlen < qbuf.length)
                    qbuf[qlen++] = cast(char) e.ch;
                jumpMatch(top, true);
                break;
            case Key.backspace:
                if (qlen)
                    --qlen;
                jumpMatch(top, true);
                break;
            case Key.enter:
                searching = false;
                jumpMatch(top + 1, true); // move off the current match
                break;
            case Key.escape:
                searching = false;
                qlen = 0;
                break;
            default: break;
        }
    }
}

@("tui.paint.rawGridContent")
@system
unittest
{
    import sparkles.syntax : builtinDark, HighlightEvent, LabelSet;
    import std.algorithm.searching : canFind;

    static immutable src = "hello\nworld\n";
    static HighlightEvent[1] ev = [HighlightEvent.sourceSpan(0, src.length)];
    static immutable(Theme)[1] themes = [builtinDark];
    static immutable string[1] names = ["dark"];

    PreviewTui t;
    t.title = "doc.md";
    t.source = src;
    t.events = ev[];
    t.labels = LabelSet.standard();
    t.names = names[];
    t.themes = themes[];
    t.width = 60;
    t.height = 6;
    t.relayout(); // raw view (no markdown model present)

    Grid g;
    g.resize(60, 6);
    t.paint(g);

    string row(ushort y)
    {
        string s;
        foreach (x; 0 .. g.cols)
            s ~= g[cast(ushort) x, y].grapheme;
        return s;
    }

    assert(row(0).canFind("doc.md"), row(0)); // header: title
    assert(row(0).canFind("dark"), row(0));   // header: theme name
    assert(row(0).canFind("raw"), row(0));    // header: view mode
    assert(row(1).canFind("hello"), row(1));  // first source line, painted into the grid
    assert(row(2).canFind("world"), row(2));  // second source line
}

@("tui.pointer.scrollbarGrabOwnsThePointer")
@system
unittest
{
    import sparkles.syntax : builtinDark, HighlightEvent, LabelSet;

    string src;
    foreach (i; 0 .. 40)
        src ~= "line\n";
    HighlightEvent[1] ev = [HighlightEvent.sourceSpan(0, src.length)];
    static immutable(Theme)[1] themes = [builtinDark];
    static immutable string[1] names = ["dark"];

    PreviewTui t;
    t.title = "doc.d";
    t.source = src;
    t.events = ev[];
    t.labels = LabelSet.standard();
    t.names = names[];
    t.themes = themes[];
    t.width = 60;
    t.height = 6; // bodyRows = 4
    t.relayout();

    // A press on the scrollbar column grabs the thumb...
    assert(t.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.press, pos: Point(59, 3)))));
    assert(t.sbDragging);
    const grabbed = t.top;
    assert(!t.sel.active, "a scrollbar press never starts a selection");

    // ...and the drag keeps scrolling even off the column — no selection.
    assert(t.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.drag, pos: Point(10, 4)))));
    assert(t.top > grabbed, "the drag kept scrolling off the column");
    assert(!t.sel.active, "a scrollbar drag never selects text");
    assert(t.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.release, pos: Point(10, 4)))));
    assert(!t.sbDragging);

    // Symmetrically: a selection drag crossing the scrollbar column keeps
    // selecting and never jumps the scroll.
    const topBefore = t.top;
    assert(t.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.press, pos: Point(5, 2)))));
    assert(t.sel.active);
    assert(t.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.drag, pos: Point(59, 3)))));
    assert(t.sel.active && t.sel.lo != t.sel.hi, "the selection extended");
    assert(t.top == topBefore, "a selection drag never scrolls the thumb");
}

@("tui.paint.markdownWidgets.fenceCopy")
@system
unittest
{
    import sparkles.syntax : builtinDark, MdBlock, MdBlockKind, MdDoc,
        MdInline, MdInlineKind, Span, LabelSet;
    import std.algorithm.searching : canFind;

    // A markdown model with one paragraph and one fence, rendered in preview
    // mode through the widget tree (no grammar / no highlight cache needed).
    static immutable src = "hello there\nlet x = 1\nlet y = 2";
    auto doc = MdDoc(MdBlock(kind: MdBlockKind.document, children: [
        MdBlock(kind: MdBlockKind.paragraph, inlines: [
            MdInline(kind: MdInlineKind.text, span: Span(0, 11))]),
        MdBlock(kind: MdBlockKind.codeFence, infoLang: "d",
            codeBody: Span(12, src.length)),
    ]), src);

    static immutable(Theme)[1] themes = [builtinDark];
    static immutable string[1] names = ["dark"];
    PreviewTui t;
    t.title = "t.md";
    t.source = src;
    t.model = PreviewModel(present: true, doc: doc);
    t.labels = LabelSet.standard();
    t.names = names[];
    t.themes = themes[];
    t.width = 40;
    t.height = 12;
    t.showPreview = true;
    t.relayout();

    Grid g;
    g.resize(40, 12);
    t.paint(g);

    string row(ushort y)
    {
        string s;
        foreach (x; 0 .. g.cols)
            s ~= g[cast(ushort) x, y].grapheme;
        return s;
    }

    // Prose, the fence header's copy affordance (), and the fence body all
    // render through the widget path.
    assert(row(1).canFind("hello there"), row(1));
    int hdrY = -1;
    foreach (y; 0 .. g.rows)
        if (row(cast(ushort) y).canFind("\U0000F0C5"))
            hdrY = y;
    assert(hdrY > 0, "fence header copy affordance not painted");
    bool sawBody;
    foreach (y; 0 .. g.rows)
        if (row(cast(ushort) y).canFind("let x = 1"))
            sawBody = true;
    assert(sawBody, "fence body not painted");

    // Search runs over the aggregated row text; a match scrolls to its row
    // (shrink the viewport so the document overflows and the jump sticks).
    t.qbuf[0 .. 5] = "y = 2";
    t.qlen = 5;
    t.height = 5;
    t.jumpMatch(0, true);
    assert(t.top > 0, "search did not jump to the fence's second line");
    t.top = 0;
    t.qlen = 0;
    t.height = 12;

    // A click on the header band copies the fence body (OSC 52) and flips the
    // affordance to the ✔ glyph until the next event.
    const clicked = t.handle(Event(PointerEvent(action: PointerAction.press,
        button: PointerButton.left, pos: Point(2, hdrY))));
    assert(clicked && t.clipReady);
    import std.base64 : Base64;
    assert((cast(string) t.clip[]).canFind(
        Base64.encode(cast(const(ubyte)[]) src[12 .. $])));
    t.paint(g);
    assert(row(cast(ushort) hdrY).canFind("\U0000F00C"),
        "copied feedback glyph not shown");

    // Drag-selecting the paragraph row and pressing `y` copies its source.
    t.clipReady = false;
    t.handle(Event(PointerEvent(action: PointerAction.press,
        button: PointerButton.left, pos: Point(1, 1))));
    t.copySelection();
    assert(t.clipReady);
    assert((cast(string) t.clip[]).canFind(
        Base64.encode(cast(const(ubyte)[]) src[0 .. 11])));
}

@("tui.fold.zTogglesInnermostRegion")
@system
unittest
{
    import sparkles.syntax : builtinDark, MdBlock, MdBlockKind, MdDoc,
        MdInline, MdInlineKind, Span, LabelSet;

    // A paragraph + a 3-line fence; folding at the fence collapses it to one
    // placeholder row, and toggling again restores it.
    static immutable src = "hello there\n```d\na\nb\nc\n```";
    auto doc = MdDoc(MdBlock(kind: MdBlockKind.document, children: [
        MdBlock(kind: MdBlockKind.paragraph, span: Span(0, 11), inlines: [
            MdInline(kind: MdInlineKind.text, span: Span(0, 11))]),
        MdBlock(kind: MdBlockKind.codeFence, infoLang: "d",
            span: Span(12, src.length), codeBody: Span(17, 23)),
    ]), src);

    static immutable(Theme)[1] themes = [builtinDark];
    static immutable string[1] names = ["dark"];
    PreviewTui t;
    t.title = "t.md";
    t.source = src;
    t.model = PreviewModel(present: true, doc: doc);
    t.labels = LabelSet.standard();
    t.names = names[];
    t.themes = themes[];
    t.width = 40;
    t.height = 14;
    t.showPreview = true;
    t.relayout();

    const openRows = t.mdRows.length;
    assert(openRows > 4, "fence body rows expected");

    // Select a row inside the fence body and fold ('z').
    long bodyRow = -1;
    foreach (i, r; t.mdRows)
        if (r.srcStart >= 17 && r.srcStart != size_t.max && r.srcEnd <= 23)
            bodyRow = i;
    assert(bodyRow > 0);
    t.sel = Selection!long.started(bodyRow);
    t.handle(Event(KeyEvent(key: Key.char_, ch: 'z')));
    t.handle(Event(KeyEvent(key: Key.char_, ch: 'z')));
    assert(t.mdRows.length < openRows, "the fold collapsed the fence");

    // The placeholder row carries the region's identity; 'z' on it unfolds.
    long ph = -1;
    foreach (i, r; t.mdRows)
        if (r.srcStart == 12)
            ph = i;
    assert(ph >= 0, "placeholder row with the fold's source identity");
    t.sel = Selection!long.started(ph);
    t.handle(Event(KeyEvent(key: Key.char_, ch: 'z')));
    t.handle(Event(KeyEvent(key: Key.char_, ch: 'a'))); // za, like zz
    assert(t.mdRows.length == openRows, "the fold reopened");

    // zM folds every foldable region; zR opens them all again (FLD5).
    t.handle(Event(KeyEvent(key: Key.char_, ch: 'z')));
    t.handle(Event(KeyEvent(key: Key.char_, ch: 'M')));
    assert(t.mdRows.length < openRows, "zM folded the fence");
    t.handle(Event(KeyEvent(key: Key.char_, ch: 'z')));
    t.handle(Event(KeyEvent(key: Key.char_, ch: 'R')));
    assert(t.mdRows.length == openRows, "zR reopened everything");
}

@("tui.twoslash.paneRendersAndPopups")
@system
unittest
{
    import sparkles.syntax : builtinDark, LabelSet;
    import sparkles.twoslash.protocol : Node;
    import std.algorithm.searching : canFind;

    // A twoslash document in the viewer pane: squiggle + message + a hover
    // token whose popup toggles by 'p' and by click.
    const code = "const b = a\n";
    TwoslashReturn tw = {code: code, nodes: [
        Node(type: NodeType.error, start: 10, length: 1, line: 0,
            character: 10, text: "Cannot find name 'a'.", level: "error"),
        Node(type: NodeType.hover, start: 6, length: 1, line: 0,
            character: 6, text: "const b: any"),
    ]};

    static immutable(Theme)[1] themes = [builtinDark];
    static immutable string[1] names = ["dark"];
    PreviewTui t;
    t.labels = LabelSet.standard();
    t.names = names[];
    t.themes = themes[];
    t.resize(60, 14);
    t.setDocument("x.twoslash.json", code,
        [HighlightEvent.sourceSpan(0, code.length)], PreviewModel.init,
        startPreview: true, tw);

    Grid g;
    g.resize(60, 14);
    t.paint(g);

    string row(ushort y)
    {
        string s;
        foreach (x; 0 .. g.cols)
            s ~= g[cast(ushort) x, y].grapheme;
        return s;
    }
    assert(row(1).canFind("const b = a"), row(1));
    assert(row(3).canFind("Cannot find name 'a'."), row(3));

    // 'p' cycles the hover popups: the signature composites over the pane.
    t.handle(Event(KeyEvent(key: Key.char_, ch: 'p')));
    t.paint(g);
    bool sawSig;
    foreach (y; 0 .. g.rows)
        if (row(cast(ushort) y).canFind("const b: any"))
            sawSig = true;
    assert(sawSig, "hover popup signature composited");

    // Esc dismisses the popup first (and only then would quit).
    assert(t.handle(Event(KeyEvent(key: Key.escape))));
    t.paint(g);
    sawSig = false;
    foreach (y; 0 .. g.rows)
        if (row(cast(ushort) y).canFind("const b: any"))
            sawSig = true;
    assert(!sawSig, "popup dismissed");
}
