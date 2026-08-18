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
import sparkles.diff.model : DiffDoc;
import diff_session : DiffSession, SessionEntry;
import diff_view : TypeOverlay;
import sparkles.syntax.md.render_widgets : FenceScroll;
import table_select : serializeTable, TableCopyFormat, TableRegion;
import core.time : Duration;
import keymap : Binding, bindingsAt, Command, InputMode, KeyContext;
import lantern : LanternState, ltnStep = step, ltnTick = tick,
    untilShown, LtnStepKind = StepKind;
import lantern_view : BoxLayout, LabelArena, LanternStyle, Placement,
    viewLantern;
import document : DiffEmphasis, DiffSides;
import staging : StageAction;
import sparkles.base.text.writers : writeInteger;

import sparkles.syntax : ColorDepth, HighlightEvent, LabelSet, ResolvedTheme,
    RgbColor, Theme, toRgb;

import sparkles.syntax.md.model : MdBlock, MdBlockKind, Span;
import sparkles.syntax.ts.injection : TsConfigCache;
import sparkles.twoslash.protocol : NodeType, TwoslashReturn;
import sparkles.twoslash.render_widgets : viewHoverPopup, viewTwoslashDocument;
import sparkles.twoslash.signature_layout : ExpandedRegions;

import sparkles.base.term_style : TextAttr, UnderlineStyle;
import sparkles.input : EndOfInput, Event, isEndOfInput, Key, KeyEvent,
    match, PointerAction, PointerButton, PointerEvent, ResizeEvent, WheelEvent;
import sparkles.ui.canvas : DrawOp;
import sparkles.ui.components.chrome : headerBar;
import sparkles.ui.display_list : buildDisplayList;
import sparkles.ui.geometry : Constraints, Point, Rect, SizeSpec;
import sparkles.ui.layout : Frame, layout;
import sparkles.ui.state : DisclosureState, DocRow, HoverTarget,
    ScrollbarState, scrollbarThumb, Selection, selectionRects, sourceOffsetAt;
import sparkles.ui.style : defaultTwoslashPalette, schemeForBackground, Slot,
    TextStyle;
import sparkles.ui.widget : Builder, Widget, WidgetKind, WidgetTree;
import sparkles.ui_tui : Cell, CellStyle, Color, Grid, paintGrid;

import ansi_model : Attr, BackgroundMode;
import viewer_model : ViewerModel;
import gui_preview : PreviewModel;

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
    /// The one document-pane Whole (`IXB5`): document, theme-resolved
    /// colors, the widget pipeline, folds, scroll and search live in the
    /// SAME model the GUI drives — this pane keeps only what is genuinely
    /// terminal-shaped (grid painting, key decode, OSC 52, the scrollbar
    /// machines, the search input buffer).
    ViewerModel vm;

    /// Embedded panes let `DockContainer` reserve, paint and drive their
    /// outer bars. A standalone viewer leaves this false and keeps the same
    /// self-contained component it has always been.
    bool externalScroll;

    BackgroundMode background;      // (kept for the caller; the viewer paints full-bg)
    ColorDepth depth;               // (unused: the cell renderer emits truecolor)

    /// The vertical scrollbar machine — the model's ScrollView axis
    /// (SCV1: one value, both backends), kept under its pane-local name;
    /// the workspace reads `sb.dragging`/`sb.shape` for capture/pointers.
    ref inout(ScrollbarState) sb() inout return @safe pure nothrow @nogc
        => vm.scroll.v;
    private int width, height;      // pane size in cells
    /// Grid column of the pane's left edge — 0 when full-screen; the split
    /// workspace places the viewer right of the explorer. Pointer events are
    /// translated to pane-local coordinates by the caller.
    int originX;

    /// Whether this pane holds the workspace focus (a standalone viewer is
    /// always focused). The header title renders accented when focused,
    /// muted otherwise — the at-a-glance focus indicator.
    bool focused = true;

    /// Set by the `toggleInspector` command arm; the workspace drains it and
    /// flips the pane (the pane arrangement is the workspace's, not this
    /// viewer's — the `tree.picked` handoff pattern). A standalone viewer
    /// (no workspace) simply never reads it.
    bool inspectorToggleRequested;

    /// ditto — the `pickerFiles` command arm (`<leader>ff`): the corpus and
    /// the loader are the workspace's, so the pane reports the intent.
    bool pickerRequested;

    /// The source byte at pane-local `p`, else `-1` — the inspector's
    /// hover-sync feed. Char-precise through the identity channel where the
    /// point carries one; else the row's whole span (the TUI's granularity).
    long offsetAt(Point p) @system
    {
        import sparkles.ui.state : sourceOffsetAt;

        const bodyRows = height > 2 ? height - 2 : 1;
        if (p.y < 1 || p.y > bodyRows || vm.rows.length == 0)
            return -1;
        const line = vm.top + (p.y - 1);
        if (line < 0 || line >= cast(long) vm.rows.length)
            return -1;
        const hx = vm.hOverflows() ? cast(int) vm.hsb.offset : 0;
        const off = sourceOffsetAt(vm.tree, vm.frames,
            Point(p.x + hx, cast(int) line));
        if (off >= 0)
            return off;
        const r = vm.rows[cast(size_t) line];
        return r.srcStart != size_t.max ? cast(long) r.srcStart : -1;
    }

    // Incremental search (`/`): `searching` is input mode; `qbuf[0 .. qlen]` is
    // the query, reused by `n`/`N` (one line editor pending — IXB6).
    private bool searching;
    private char[256] qbuf;
    private size_t qlen;

    // Selection (mouse drag) → OSC 52 copy: the shared STM3 machine over
    // visual line indices; `selBg` tints the selected lines. `clip` holds a
    // pending OSC 52 sequence that the loop flushes after a copy.
    private Selection!long sel;
    private RgbColor selBg;
    private SmallBuffer!char clip;
    private bool clipReady;

    /// `DST2`/`DST4`: the answer to the reviewer's last write action, shown
    /// in the status bar until the next keystroke. A write that reports
    /// nothing is indistinguishable from a key that is not bound.
    private string notice;
    /// `DST4`: a discard is armed but not yet confirmed. Destroying work
    /// takes two deliberate keystrokes, and the second is `y` — never the
    /// same key again, so a repeated `X` cannot run away with the file.
    private bool discardArmed;
    /// The host's "the diff changed underneath us" hook: applying a patch
    /// invalidates the document, and only the host owns the loader that
    /// produced it.
    void delegate() @system onStaged;
    /// The repository the patches apply in (the host's working directory
    /// when empty).
    string repoRoot;

    /// The key guide's pending path (`LTN2`) — what `zPending` used to be,
    /// except it handles every prefix, three levels deep, and can say what
    /// follows.
    private LanternState lantern;

    /// How long until the guide's panel appears (`LTN4`); `Duration.max` when
    /// nothing is pending. The host uses it as its poll timeout, so the panel
    /// opens on time with no keystroke to wake it.
    Duration untilLanternShown() const @safe pure nothrow @nogc
        => .untilShown(lantern);

    /// ditto — advances the clock when that wait expires.
    void tickLantern(Duration elapsed) @safe pure nothrow @nogc
    {
        ltnTick(lantern, elapsed);
    }
    /// The guide's label arena, reused across frames (`NFR2`).
    private LabelArena ltnLabels;

    // Twoslash hover popups in the pane: the hover-typed node indices (for
    // `p` cycling) and the selected one (-1 = none; click toggles).
    private size_t[] hoverNodes;
    private int hoverSel = -1;
    // Which collapsed runs of the focused popup's signature are open. Per
    // popup: moving to another node asks a fresh question.
    private ExpandedRegions hoverExpanded;

    // ── the model's vocabulary, forwarded (IXB5) ─────────────────────────────
    // The old field names keep working for the methods below and every host
    // and test; the storage is the model's — one copy, no disagreement.
    ref inout(string) title() inout return @safe pure nothrow @nogc => vm.title;
    ref inout(const(char)[]) source() inout return @safe pure nothrow @nogc => vm.source;
    ref inout(const(HighlightEvent)[]) events() inout return @safe pure nothrow @nogc => vm.events;
    ref inout(string) lang() inout return @safe pure nothrow @nogc => vm.lang;
    ref inout(PreviewModel) model() inout return @safe pure nothrow @nogc => vm.preview;
    ref inout(TwoslashReturn) tw() inout return @safe pure nothrow @nogc => vm.tw;
    ref inout(TsConfigCache*) cache() inout return @safe pure nothrow @nogc => vm.cache;
    ref inout(LabelSet) labels() inout return @safe pure nothrow @nogc => vm.labels;
    ref inout(const(string)[]) names() inout return @safe pure nothrow @nogc => vm.names;
    ref inout(immutable(Theme)[]) themes() inout return @safe pure nothrow @nogc => vm.themes;
    ref inout(int) tabWidth() inout return @safe pure nothrow @nogc => vm.tabWidth;
    ref inout(bool) listWhitespace() inout return @safe pure nothrow @nogc => vm.listWhitespace;
    ref inout(bool) codeLineNumbers() inout return @safe pure nothrow @nogc => vm.codeLineNumbers;

    private ref inout(size_t) themeIdx() inout return @safe pure nothrow @nogc => vm.themeIdx;
    private ref inout(long) top() inout return @safe pure nothrow @nogc => vm.top;
    private ref inout(bool) showPreview() inout return @safe pure nothrow @nogc => vm.showPreview;
    private ref inout(ResolvedTheme) theme() inout return @safe pure nothrow @nogc => vm.current;
    private RgbColor pageFg() const @safe pure nothrow @nogc => vm.pageFg;
    private RgbColor pageBg() const @safe pure nothrow @nogc => vm.pageBg;
    private RgbColor gutterFg() const @safe pure nothrow @nogc => vm.gutterFg;
    private RgbColor sbTrack() const @safe pure nothrow @nogc => vm.sbTrack;
    private RgbColor sbThumb() const @safe pure nothrow @nogc => vm.sbThumb;
    private ref const(WidgetTree) mdTree() const return @safe pure nothrow @nogc => vm.tree;
    private const(Frame)[] mdFrames() const @safe pure nothrow @nogc => vm.frames;
    private const(DrawOp)[] mdOps() const @safe pure nothrow @nogc => vm.ops;
    private const(DocRow)[] mdRows() const @safe pure nothrow @nogc => vm.rows;
    private const(HoverTarget)[] mdTargets() const @safe pure nothrow @nogc => vm.targets;
    private alias FoldOp = ViewerModel.FoldOp;
    private enum size_t fenceHitBase = ViewerModel.fenceHitBase;
    private enum size_t codeTabHitBase = ViewerModel.codeTabHitBase;
    private enum size_t foldHitBase = ViewerModel.foldHitBase;
    private enum size_t tableCopyHitBase = ViewerModel.tableCopyHitBase;
    private enum size_t fenceHBarHitBase = ViewerModel.fenceHBarHitBase;
    private enum size_t fenceVBarHitBase = ViewerModel.fenceVBarHitBase;

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

    /// The text waiting to reach the system clipboard, if any (cleared by the
    /// take). The frame hands it to the host, which knows how this target
    /// carries one — OSC 52 on a terminal, the window system's own call in a
    /// window. Empty when nothing was copied.
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
    /// run on a theme, resize, or toggle change — never per frame). One column
    /// narrower than the pane — the last column holds the scrollbar.
    void relayout() @system
    {
        vm.inlineFoldMarker = true; // the placeholder ▸ is the TUI affordance
        const contentWidth = externalScroll ? width : width - 1;
        vm.widthCols = contentWidth < 8 ? 8 : contentWidth;
        vm.viewRows = bodyRows();
        vm.applyTheme(themeIdx);
        // Selection tint: toward the theme link color, like the scrollbars.
        const linkC = toRgb(theme[theme.labels.resolve("markup.link")].fg, pageFg);
        selBg = mix(pageBg, linkC, 0.4);
        refreshHover();
        clampTop();
    }

    // The twoslash hover-typed node indices (for `p` cycling) follow the
    // document; the model owns everything else the rebuild derives.
    private void refreshHover() @safe pure nothrow
    {
        hoverNodes.length = 0;
        if (tw.code.length && showPreview)
            foreach (ni, ref const n; tw.nodes)
                if (n.type == NodeType.hover)
                    hoverNodes ~= ni;
    }

    private int bodyRows() const @safe pure nothrow @nogc
        => height > 2 ? height - 2 : 1;

    private long maxTop() const @safe pure nothrow @nogc
    {
        const over = lineCount - bodyRows();
        return over > 0 ? over : 0;
    }

    /**
    A wheel notch, in whichever axis it names.

    Sideways is a horizontal axis (`WheelEvent.dx` — the terminal has decoded
    SGR buttons 66/67 into it since mouse input went in) or Shift plus a
    vertical notch, the convention every browser answers to and the one a
    phone can actually produce: a touch translation layer emits vertical
    notches, and the modifier is a key the soft keyboard has.

    $(B The innermost thing under the pointer wins.) A fence body scrolls its
    own viewport (`COD`); only when there is no fence there, or it is already
    at that edge, does the notch reach the document's own offset (`IXB2`).
    That is the same rule the vertical axis already follows, and it is what
    makes a wide table inside a fence and a wide document behave alike.
    */
    private bool handleWheel(in WheelEvent w) @system
    {
        const dx = w.dx + (w.mods.shift ? w.dy : 0);
        if (dx != 0)
        {
            const fb = vm.fenceBodyAtRow(top + (w.pos.y - 1));
            if (fb != size_t.max && vm.scrollFence(fb, dx))
                return true;
            vm.scrollHorizontal(dx);
            return true;
        }
        if (w.mods.shift)
            return true; // a shifted notch never scrolls vertically
        // A vertical notch over a TALL fence scrolls the fence until its
        // edge; only then does it reach the document.
        const fbV = vm.fenceBodyAtRow(top + (w.pos.y - 1));
        if (fbV != size_t.max && vm.scrollFenceV(fbV, w.dy))
            return true;
        top += w.dy;
        clampTop();
        return true;
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

    // Queue `text` for the system clipboard. The PAYLOAD, not a sequence:
    // OSC 52 is how a terminal carries one, and the host owns that (`HST`)
    // because a window carries the same text a different way entirely.
    private void writeClipboard(scope const(char)[] text) @system
    {
        clip.clear();
        clip.put(text);
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
        string lang_ = null, DiffDoc diff_ = DiffDoc.init,
        const(DiffSides)[] diffSides_ = null,
        DiffSession diffSession_ = DiffSession.init,
        DiffEmphasis diffEmphasis_ = DiffEmphasis.init) @system
    {
        hoverSel = -1;
        sel = Selection!long.cleared;
        searching = false;
        qlen = 0;
        vm.inlineFoldMarker = true;
        vm.widthCols = width < 9 ? 8 : width - 1;
        vm.viewRows = bodyRows();
        if (vm.current.labels.length == 0 && themes.length)
            vm.applyTheme(themeIdx); // first document: resolve the theme once
        vm.setDocument(title_, null, source_, events_, model_, tw_, lang_,
            diff_, diffSides_, diffSession_, diffEmphasis_);
        if (!startPreview && vm.showPreview)
        {
            vm.showPreview = false;
            vm.rebuild();
        }
        refreshHover();
        clampTop();
    }

    /**
    Attaches a live twoslash payload to the open document (`PRJ12`/`PRJ14`):
    the source is unchanged, the decorations arrive. The pane switches to the
    document view, so every hover span shows its discoverability underline
    even while the types behind them are still lazy.
    */
    void attachTwoslash(TwoslashReturn tw_) @system
    {
        tw = tw_;
        hoverSel = -1;
        showPreview = tw.code.length != 0 || model.present;
        relayout(); // clamps the scroll to the document view's row count
    }

    /// The payload the pane renders — the live oracle fills lazy hover nodes
    /// in it in place, and the next popup reads them (no relayout: the
    /// document body draws the spans, not their text).
    ref TwoslashReturn twoslashPayload() return @safe pure nothrow @nogc => tw;

    /// The node index of the hover popup the user opened (`p` cycles, a click
    /// toggles), or -1 — what the live oracle resolves on demand.
    long selectedHoverNode() const @safe pure nothrow @nogc
        => hoverSel >= 0 && hoverSel < cast(int) hoverNodes.length
            ? cast(long) hoverNodes[hoverSel] : -1;

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
        if (!externalScroll)
            paintScrollbar(g);
        paintStatus(g);
        paintLantern(g);
    }

    /**
    The key guide (`LTN5`), over everything and along the bottom edge.

    The same widget tree the window paints — `viewLantern` builds it, the
    cell canvas interprets it — so the two backends cannot drift the way the
    scrollbars and the selection tint did. Nothing here measures a label or
    divides a width.
    */
    private void paintLantern(ref Grid g) @system
    {
        if (!lantern.shown)
            return;
        SmallBuffer!(Binding, 128) listed;
        bindingsAt(listed, keyContext(), lantern.pending[]);
        if (listed.length == 0)
            return;

        Builder b;
        BoxLayout box;
        const root = viewLantern(b, ltnLabels, listed[],
            lantern.pending.length, width, box, Placement.classic,
            LanternStyle.init, 0, lantern.scroll);
        auto tree = b.finish(root);
        auto frames = layout(tree, Constraints(maxW: width));
        const panel = frames[tree.root].rect;
        const y = height - panel.height;
        paintGrid(g, pageBg, buildDisplayList(tree, frames,
            defaultTwoslashPalette(schemeForBackground(pageBg)), pageFg, pageBg),
            originX, y > 0 ? y : 0, Rect(0, 0, width, panel.height));
    }

    // Paint the markdown widget tree's precomputed ops with a scroll offset:
    // ops are in document cell coordinates, the viewport shows doc rows
    // `top .. top+rows` at grid rows `1 ..`, and the base clip keeps the body
    // out of the chrome rows. Selection tints the painted rows in place.
    private void paintMarkdown(ref Grid g) @system
    {
        const rows = bodyRows();
        const hx = vm.hOverflows() ? cast(int) vm.hsb.offset : 0;
        const contentWidth = externalScroll ? width : width - 1;
        paintGrid(g, pageBg, mdOps, originX - hx, cast(int)(1 - top),
            Rect(hx, cast(int) top, contentWidth, rows));

        // The horizontal bar (IXB2): the last body row, when wide content
        // (a fence line, a table) clips — the same component/machine as
        // the vertical bar, horizontal axis.
        if (!externalScroll && vm.hOverflows())
        {
            import sparkles.ui.components.chrome : scrollbar, ScrollbarGlyphs;

            auto hb = Builder();
            const bar = scrollbar(hb, vm.hsb, vm.contentCols, vm.widthCols,
                width - 1, ScrollbarGlyphs('━', '─'));
            auto hbt = hb.finish(bar);
            paintGrid(g, pageBg, buildDisplayList(hbt, layout(hbt),
                vm.palette, pageFg, pageBg), originX, height - 2);
        }
        // The inspector's extent tint (TSI2): the selected CST node's rects,
        // through the same identity channel the search matches use — a
        // fainter band than the line selection, char-precise.
        if (vm.inspectRects.length)
        {
            const inspFill = Color.fromRgb(mix(pageBg, selBg, 0.55));
            foreach (ref const r; vm.inspectRects)
            {
                const gy = 1 + r.y - top;
                if (gy < 1 || gy > rows)
                    continue;
                foreach (x; r.x - hx .. r.x - hx + r.width)
                    if (x >= 0 && x < contentWidth)
                        g[cast(ushort)(originX + x), cast(ushort) gy]
                            .style.bg = inspFill;
            }
        }

        if (!sel.active)
            return;
        const selFill = Color.fromRgb(selBg);
        foreach (i; sel.lo .. sel.hi + 1)
        {
            const gy = 1 + i - top;
            if (gy < 1 || gy > rows)
                continue;
            foreach (x; 0 .. (contentWidth > 0 ? contentWidth : 0))
                g[cast(ushort)(originX + x), cast(ushort) gy].style.bg = selFill;
        }
    }

    // The selected hover token's popup (twoslash documents), composited over
    // the pane below the token — the shared viewHoverPopup chrome. The token
    // rect comes from the identity channel.
    /// Open every collapsed run of the focused popup, or close them all if
    /// they are already open. Answers whether there was a popup to act on.
    private bool toggleHoverRegions() @safe
    {
        if (hoverSel < 0 || hoverSel >= cast(int) hoverNodes.length)
            return false;
        const ni = hoverNodes[hoverSel];
        const abbrevs = tw.nodes[ni].signature.abbrevs.length;
        if (abbrevs == 0)
            return false;
        bool anyClosed;
        foreach (r; 0 .. abbrevs)
            if (!hoverExpanded.get(r, false))
                anyClosed = true;
        foreach (r; 0 .. abbrevs)
            hoverExpanded[r] = anyClosed;
        return true;
    }

    private void paintHoverPopup(ref Grid g) @system
    {
        if (hoverSel < 0 || hoverSel >= cast(int) hoverNodes.length)
            return;
        import sparkles.twoslash.overlay : withoutQuickinfoPrefix;
        import sparkles.syntax.md.render_widgets : highlightedFenceRenderer,
            MdViewTheme;
        import sparkles.twoslash.render_widgets : clampOrigin,
            effectivePopupWidth, HoverViewOptions, signatureSpans;
        import sparkles.ui.geometry : Rect;
        import sparkles.ui.widget : TextSpan;

        const n = tw.nodes[hoverNodes[hoverSel]];
        auto rs = selectionRects(mdTree, mdFrames, n.start, n.start + n.length);
        if (!rs.length)
            return;
        // With a grammar cache the signature renders as resolved-color spans
        // inside the widget model (the same mapping the GUI uses).
        TextSpan[] sig = cache !is null
            ? signatureSpans(*cache, tw.effectiveLanguage,
                (() @trusted => &vm.current)(), pageFg,
                withoutQuickinfoPrefix(n.text)) : null;
        // The room actually left at the anchor, capped by the theme's ceiling.
        // Without this the popup grows to whatever the signature measures and
        // walks off the pane.
        const pal = defaultTwoslashPalette(schemeForBackground(pageBg));
        const avail = width - rs[0].x - 1;
        // Through the *registry* overload: the ddoc is markdown, and without
        // it the popup shows `### Examples` and fence markers as literal text
        // while the document one pane over renders them properly. The theme
        // and fence highlighter are the same ones the preview uses, so a
        // documented unittest arrives with its `unittest` fence label.
        auto opts = HoverViewOptions(
            maxWidth: effectivePopupWidth(pal, avail), sigSpans: sig,
            expanded: hoverExpanded, nodeKey: hoverNodes[hoverSel] + 1,
            mdTheme: MdViewTheme.derive(vm.current, pageFg, pageBg),
            fenceRenderer: highlightedFenceRenderer(cache,
                (() @trusted => &vm.current)(), pageFg));
        auto tree = cache !is null
            ? viewHoverPopup(tw, hoverNodes[hoverSel], cache.registry, opts)
            : viewHoverPopup(tw, hoverNodes[hoverSel], opts);
        // A lazy hover span (live types: underlined, type not yet resolved)
        // views as an empty tree — nothing to paint until the answer lands.
        if (!tree.nodes.length)
            return;
        auto frames = layout(tree);
        auto ops = buildDisplayList(tree, frames, pal, pageFg, pageBg);

        // Keep it inside the pane on both axes: shift left rather than shrink
        // when it would overhang the right edge (a narrower popup would only
        // move the problem into the text), and clip so it can never spill
        // across the divider into the explorer — `paintGrid` clips in
        // canvas-local cells, so the rect is expressed relative to the origin.
        const box = frames[tree.root].rect;
        const ox = clampOrigin(rs[0].x, box.width, width);
        const oy = cast(int)(rs[0].y - top + 2);
        paintGrid(g, pageBg, ops, originX + ox, oy,
            Rect(-ox, -oy, width, height));
    }

    // Paint a one-row chrome bar (the shared WGT17 headerBar view) at grid row
    // `y` through the full widget pipeline: view → layout → display list →
    // the ui-tui GridCanvas. The slots resolve against the theme's palette.
    private void paintBar(ref Grid g, int y, uint[] leading, uint[] center,
        uint[] trailing, ref Builder b, bool focusedBar = false) @system
    {
        const bar = headerBar(b, leading, center, trailing, focusedBar);
        Widget colW = Widget(kind: WidgetKind.column, children: [bar],
            width: SizeSpec.fixed(width));
        const col = b.add(colW);
        auto tree = b.finish(col);
        auto ops = buildDisplayList(tree, layout(tree),
            vm.palette, pageFg, pageBg);
        paintGrid(g, pageBg, ops, originX, y);
    }

    private void paintHeader(ref Grid g) @system
    {
        import std.conv : text;

        auto b = Builder();
        const name = b.add(Widget(kind: WidgetKind.text, text: title,
            slot: focused ? Slot.chromeAccent : Slot.gutter,
            textStyle: TextStyle(bold: focused)));
        const mid = b.add(Widget(kind: WidgetKind.text, text: text(
            names[themeIdx], " (", themeIdx + 1, "/", names.length, ")  ·  ",
            (showPreview && model.present) ? "preview"
            : vm.plainSyntax ? "plain" : "raw")));
        const pos = b.add(Widget(kind: WidgetKind.text,
            text: text(top + 1, "/", lineCount), slot: Slot.gutter));
        paintBar(g, 0, [name], [mid], [pos], b, focused);
    }

    private void paintStatus(ref Grid g) @system
    {
        import std.conv : text;

        const y = height > 0 ? height - 1 : 0;
        auto b = Builder();
        // A notice outranks the key hints: it is the answer to what the
        // reviewer just did, and the hints are always true anyway.
        const line = b.add(Widget(kind: WidgetKind.text,
            text: searching ? text("/", query, "▏")
                : notice.length ? notice
                : "scroll ↑↓ · ←→ theme · Tab raw/preview · / search · za fold · drag+y copy · q quit",
            slot: searching || notice.length ? Slot.inherit : Slot.gutter));
        paintBar(g, y, [line], null, null, b);
    }

    // A cell scrollbar in the last column across the body rows, sized/positioned
    // to the visible fraction. Only shown when the document overflows the viewport.
    private void paintScrollbar(ref Grid g) @system
    {
        const rows = bodyRows();
        if (lineCount <= rows || g.cols < 2 || originX + width > g.cols)
            return;
        // The one component (WGT10) over the one machine (STM9), tinted by
        // the palette's track/thumb entries (B-1) — the GUI renders the
        // same state through its animated px painter.
        import sparkles.ui.components.chrome : scrollbar, ScrollbarGlyphs;

        auto vb = Builder();
        const vbar = scrollbar(vb, sb.scrolledTo(top),
            cast(size_t) lineCount, rows, rows, ScrollbarGlyphs('█', '░'));
        auto vbt = vb.finish(vbar);
        paintGrid(g, pageBg, buildDisplayList(vbt, layout(vbt), vm.palette,
            pageFg, pageBg), originX + width - 1, 1);
    }

    // ── Input ────────────────────────────────────────────────────────────────

    // Copy a fence's raw body to the clipboard (OSC 52), resolved from its
    // source-anchored hit id, and rebuild so its header shows the ✔ glyph.
    private void copyFenceAt(size_t bodyStart) @system
    {
        foreach (ref const f; vm.fences)
            if (f.body.start == bodyStart)
            {
                // The body as CODE — a quoted fence's `> ` prefixes dropped.
                writeClipboard(f.text);
                vm.markCopied(bodyStart);
                return;
            }
    }

    // Copy a whole table (TBL6) as TSV, resolved from the top-border
    // cutout's source-anchored hit id; the cutout then shows the ✔ glyph.
    private void copyTableAt(size_t spanStart) @system
    {
        const ti = vm.tableIndexOfSpan(spanStart);
        if (ti < 0)
            return;
        const dims = vm.tableDims(ti);
        TableRegion reg = {
            rowLo: 0, colLo: 0,
            rowHi: dims.rows ? dims.rows - 1 : 0,
            colHi: dims.cols ? dims.cols - 1 : 0,
        };
        const(char)[] cellText(size_t r, size_t c)
        {
            foreach (ref const mc; vm.cellList)
                if (mc.table == ti && mc.row == r && mc.col == c
                    && mc.span.end <= vm.source.length)
                    return vm.source[mc.span.start .. mc.span.end];
            return "";
        }

        const txt = serializeTable(reg, &cellText, TableCopyFormat.tsv);
        if (txt.length)
            writeClipboard(txt);
        vm.markTableCopied(spanStart);
    }

    // Press on a fence scrollbar (`COD6`): the same ScrollbarState math the
    // pane bars use, keyed to the fence via `vm.fenceSvOwner`. The semantic
    // h-bar target is already the corner-free track.
    private void fenceBarPress(in HoverTarget t, Point p) @system
    {
        const isH = t.hitId >= fenceHBarHitBase;
        const owner = t.hitId - (isH ? fenceHBarHitBase : fenceVBarHitBase);
        vm.fenceSvOwner = owner;
        const ex = vm.fenceExtent(owner);
        const cur = vm.fenceScrollAt.get(owner, FenceScroll(owner, 0, 0));
        if (isH)
        {
            vm.fenceSv.h = vm.fenceSv.h.pressed(p.x - t.rect.x,
                ex.widest, ex.innerW, t.rect.width);
            vm.setFenceScroll(owner, vm.fenceSv.h.offset, cur.y);
        }
        else
        {
            vm.fenceSv.v = vm.fenceSv.v.pressed(p.y - t.rect.y,
                ex.lines, ex.shownRows, t.rect.height);
            vm.setFenceScroll(owner, cur.x, vm.fenceSv.v.offset);
        }
        vm.syncFenceHot(); // grab feedback even when the offset didn't move
    }

    /// ditto — the drag tracks wherever the pointer strays until release.
    private void fenceBarDrag(Point p) @system
    {
        const owner = vm.fenceSvOwner;
        if (owner == size_t.max)
            return;
        const isH = vm.fenceSv.h.dragging;
        const wantId = (isH ? fenceHBarHitBase : fenceVBarHitBase) + owner;
        foreach (ref const t; mdTargets)
        {
            if (t.hitId != wantId)
                continue;
            const ex = vm.fenceExtent(owner);
            const cur = vm.fenceScrollAt.get(owner, FenceScroll(owner, 0, 0));
            if (isH)
            {
                vm.fenceSv.h = vm.fenceSv.h.dragged(p.x - t.rect.x,
                    ex.widest, ex.innerW, t.rect.width);
                vm.setFenceScroll(owner, vm.fenceSv.h.offset, cur.y);
            }
            else
            {
                vm.fenceSv.v = vm.fenceSv.v.dragged(p.y - t.rect.y,
                    ex.lines, ex.shownRows, t.rect.height);
                vm.setFenceScroll(owner, cur.x, vm.fenceSv.v.offset);
            }
            return;
        }
    }

    // Applies `op` at the selection (else the top row), over the row's
    // source identity — the model owns the innermost-region policy (FLD5).
    /// `DVG1`/`DVG3`: whether the diff session is the thing the fold and
    /// bracket keys should act on — only while the diff view is showing, since
    /// Tab drops to the raw patch text where a file is not a navigable unit.
    bool diffNav() const @safe pure nothrow @nogc
        => vm.showPreview && !vm.diffSession.empty;

    private void foldAt(FoldOp op) @system
    {
        if (diffNav())
        {
            // A diff has no CST fold ranges; its fold unit is the file.
            vm.diffToggleFile();
            clampTop();
            return;
        }
        const rowIdx = sel.active ? sel.lo : top;
        if (rowIdx < 0 || rowIdx >= cast(long) mdRows.length
            || mdRows[cast(size_t) rowIdx].srcStart == size_t.max)
            return;
        vm.foldAt(cast(long) mdRows[cast(size_t) rowIdx].srcStart, op);
        clampTop();
    }

    // `zR` / `zM`: open every fold, or fold every foldable region.
    private void setAllFolds(bool folded) @system
    {
        if (diffNav())
            vm.diffSetAllFiles(folded);
        else
            vm.setAllFolds(folded);
        clampTop();
    }

    /// `DVG1`: `[`/`]` walk the session's changed files.
    void moveDiffFile(int delta) @system
    {
        if (!diffNav())
            return;
        vm.diffMoveFile(delta);
        clampTop();
    }

    /// `DVT1`: makes room for `n` files' type overlays (idempotent).
    void ensureDiffTypes(size_t n) @safe
    {
        if (vm.diffTypes.length < n)
            vm.diffTypes.length = n;
    }

    /// `DVT1`: attaches one side's payload to file `fileIndex`, then rebuilds
    /// so the decorations appear. The attach itself enforces the anchoring
    /// contract, so a payload that does not describe that side is a no-op.
    void attachDiffTypes(size_t fileIndex, bool oldSide, TwoslashReturn tw) @system
    {
        if (fileIndex >= vm.diffTypes.length || fileIndex >= vm.diffSides.length)
            return;
        const sideText = oldSide
            ? vm.diffSides[fileIndex].oldText : vm.diffSides[fileIndex].newText;
        auto overlay = TypeOverlay.attach(tw, sideText);
        if (oldSide)
            vm.diffTypes[fileIndex].old_ = overlay;
        else
            vm.diffTypes[fileIndex].new_ = overlay;
        vm.rebuild();
    }

    /// `TVU6`: jump to a session file the explorer picked.
    void selectDiffFile(size_t i) @system
    {
        if (!diffNav())
            return;
        vm.diffSelectFile(i);
        clampTop();
    }

    /// The session the explorer's changed-files tree lists (`TVU6`); empty
    /// when the open document is not a diff.
    const(SessionEntry)[] diffEntries() const @safe pure nothrow @nogc
        => diffNav() ? vm.diffSession.entries : null;

    /**
    `DST2`/`DST4`: stage, unstage or discard the hunk under the cursor.

    The host supplies `onStaged`, because applying a patch changes the diff
    the reviewer is looking at and only the host can re-run the loader that
    produced it. Without the hook the keys are inert rather than misleading.

    A discard destroys work, so it asks first — `DST4`'s explicit
    confirmation, and the reason it is never the same keystroke as a stage.
    */
    void applyStaging(StageAction action) @system
    {
        import staging : applyPatch;

        if (!diffNav())
            return;
        scope (exit) discardArmed = action == StageAction.discard && discardArmed;
        if (!vm.diffSession.stageable)
        {
            notice = "this diff has no index to stage into";
            return;
        }
        const patch = vm.diffCursorPatch();
        if (patch.length == 0)
        {
            notice = "nothing to stage here";
            return;
        }
        if (action == StageAction.discard && !discardArmed)
        {
            discardArmed = true;
            notice = "discard this hunk? press y to confirm";
            return;
        }

        discardArmed = false;
        auto res = applyPatch(patch, action, repoRoot);
        if (res.hasError)
        {
            notice = res.error.detail;
            return;
        }
        notice = action == StageAction.stage ? "staged this hunk"
            : action == StageAction.unstage ? "unstaged this hunk"
            : "discarded this hunk";
        if (onStaged !is null)
            onStaged(); // the diff changed underneath us
    }

    /// `DVG2`: expand or re-fold the one unchanged region in view.
    void toggleDiffGap() @system
    {
        if (!diffNav())
            return;
        vm.diffToggleGapNearCursor();
        clampTop();
    }

    /// `DVG2`: expand or re-fold the unchanged regions between hunks.
    void toggleDiffContext() @system
    {
        if (!diffNav())
            return;
        vm.diffToggleContext();
        clampTop();
    }

    /// `DVL3`: switch between the unified and split layouts.
    void toggleDiffLayout() @system
    {
        if (!diffNav())
            return;
        vm.diffToggleLayout();
        clampTop();
    }

    /// `DVN2`: show or fold the formatting-only hunks.
    void toggleFormattingHunks() @system
    {
        if (!diffNav())
            return;
        vm.diffToggleFormatting();
        clampTop();
    }

    /// `DVG1`: `{`/`}` step hunk to hunk across the whole session.
    void moveDiffHunk(int delta) @system
    {
        if (!diffNav())
            return;
        vm.diffMoveHunk(delta);
        clampTop();
    }

    // `z1`-`z9`: fold to nesting level (vim's foldlevel).
    private void foldToLevel(int level) @system
    {
        vm.foldToLevel(level);
        clampTop();
    }

    /// Apply an event; returns false to quit.
    bool handle(in Event e) @system
    {
        if (vm.copiedFenceSrc != size_t.max)
            vm.clearCopied(); // the copy flash lasts until the next event
        if (searching)
            return handleSearch(e);
        return e.match!(
            (in PointerEvent p) => handlePointer(p),
            (in WheelEvent w) => handleWheel(w),
            (in KeyEvent k) => handleKey(k),
            (in EndOfInput _) => false,
            _ => true,
        );
    }

    /**
    The viewer's keys — resolved by the ONE table (`KEY1`), not a switch.

    What was here before was hue's third copy of the keyboard policy, and it
    had drifted from the other two: `g`/`G` meant top/bottom while the GUI's
    `g` started go-to-line, `y` copied where the GUI toggled a mode, and `q`
    quit only here. Those are resolved in the table now (vim-correct: `gg`,
    `Shift-G`, `gl`, `y` copies, `q` quits everywhere), so this is a dispatch
    and nothing else.

    Keys arrive through `lantern.step`, so the terminal gets the prefix
    machine and the guide for free — `z`, `g` and `<leader>` behave here
    exactly as they do in the window, because they are the same table walked
    by the same code.
    */
    private bool handleKey(in KeyEvent e) @system
    {
        const rows = bodyRows();

        // `DST4`: an armed discard is answered before anything else looks at
        // the key. `y` goes through; ANY other key disarms, so a reviewer who
        // reaches for something else has already said no.
        if (discardArmed)
        {
            const confirmed = e.key == Key.char_ && e.ch == 'y';
            discardArmed = false;
            notice = null;
            if (confirmed)
            {
                discardArmed = true; // the second pass performs it
                applyStaging(StageAction.discard);
                return true;
            }
        }
        // A notice answers the previous keystroke, not this one.
        notice = null;

        // Escape closes an open popup before it means anything else; the
        // guide only sees it when there is nothing to close.
        if (e.key == Key.escape && hoverSel >= 0 && !lantern.active)
        {
            hoverSel = -1;
            return true;
        }

        const st = ltnStep(lantern, e, keyContext());
        if (st.kind != LtnStepKind.execute)
            return true;

        final switch (st.cmd.cmd)
        {
            case Command.none:
            case Command.dismiss:
            case Command.inputBackspace:
            case Command.inputAccept:
            case Command.inputCancel:
            case Command.toggleFullscreen:
            case Command.lanternAll:
                break;

            // The explorer pane owns these; a focused tree never routes here.
            case Command.treeDown:  case Command.treeUp:
            case Command.treeHome:  case Command.treeEnd:
            case Command.treePageDown: case Command.treePageUp:
            case Command.treeActivate: case Command.treeRefresh:
            case Command.treeReroot: case Command.treeToggleIgnored:
            case Command.treeParent: case Command.treeNextChange:
            case Command.treePrevChange: case Command.treeCloseAll:
            case Command.treeToggleHidden: case Command.treeCollapseOrUp:
            case Command.treeFilter: case Command.toggleExplorer:
                break;

            case Command.toggleInspector:
                inspectorToggleRequested = true;
                break;

            case Command.pickerFiles:
                // The workspace owns the corpus and the loader; the pane only
                // reports the intent — the `inspectorToggleRequested` shape.
                pickerRequested = true;
                break;

            case Command.quit: return false;

            case Command.viewDown:     top += 1; clampTop(); break;
            case Command.viewUp:       top -= 1; clampTop(); break;
            case Command.viewPageDown: top += rows; clampTop(); break;
            case Command.viewPageUp:   top -= rows; clampTop(); break;
            case Command.viewHome:
            case Command.viewTop:      top = 0; break;
            case Command.viewEnd:
            case Command.viewBottom:   top = maxTop; break;

            case Command.themePrev:
                themeIdx = themeIdx == 0 ? names.length - 1 : themeIdx - 1;
                relayout();
                break;
            case Command.themeNext:
                themeIdx = themeIdx + 1 == names.length ? 0 : themeIdx + 1;
                relayout();
                break;

            case Command.toggleView:
                vm.cycleView();
                relayout();
                break;

            case Command.toggleHoverRegions:
                if (!toggleHoverRegions())
                {
                    // Nothing to expand: Enter/Space fall back to page-down,
                    // which is what a reader pressing Space actually wants.
                    top += rows;
                    clampTop();
                }
                break;
            case Command.cycleHoverPopup:
                if (hoverNodes.length)
                {
                    hoverSel = (hoverSel + 1) % cast(int) hoverNodes.length;
                    hoverExpanded = null;
                }
                break;

            case Command.startSearch: searching = true; qlen = 0; break;
            case Command.startGoto:   break; // the TUI has no go-to bar yet
            case Command.matchNext:   jumpMatch(top + 1, true); break;
            case Command.matchPrev:   jumpMatch(top - 1, false); break;

            case Command.copySelection: copySelection(); break;

            // Settings the terminal viewer does not own (the workspace and
            // the GUI do), reachable from the guide but inert here.
            case Command.toggleLineNumbers:
            case Command.toggleCodeLineNumbers:
            case Command.toggleAnsiCopy:
            case Command.toggleTableCopy:
            case Command.fontBigger: case Command.fontSmaller:
            case Command.setNext: case Command.setPrev: case Command.setIndex:
                break;

            case Command.foldToggle:   foldAt(FoldOp.toggle); break;
            case Command.foldClose:    foldAt(FoldOp.close); break;
            case Command.foldOpen:     foldAt(FoldOp.open); break;
            case Command.foldOpenAll:  setAllFolds(false); break;
            case Command.foldCloseAll: setAllFolds(true); break;
            case Command.foldLevel:    foldToLevel(st.cmd.arg); break;

            case Command.diffToggleLayout:     toggleDiffLayout(); break;
            case Command.diffToggleGap:        toggleDiffGap(); break;
            case Command.diffStage:   applyStaging(StageAction.stage); break;
            case Command.diffUnstage: applyStaging(StageAction.unstage); break;
            case Command.diffDiscard: applyStaging(StageAction.discard); break;
            case Command.diffToggleContext:    toggleDiffContext(); break;
            case Command.diffToggleFormatting: toggleFormattingHunks(); break;
            case Command.diffToggleStructural: vm.diffToggleStructural(); break;
            case Command.viewScrollLeft:  vm.scrollHorizontal(-ViewerModel.hScrollStep); break;
            case Command.viewScrollRight: vm.scrollHorizontal(ViewerModel.hScrollStep); break;
            case Command.viewScrollHome:  vm.scrollHomeHorizontal(); break;
            case Command.viewScrollEnd:   vm.scrollEndHorizontal(); break;
            case Command.diffPrevFile: moveDiffFile(-1); break;
            case Command.diffNextFile: moveDiffFile(+1); break;
            case Command.diffPrevHunk: moveDiffHunk(-1); break;
            case Command.diffNextHunk: moveDiffHunk(+1); break;
            case Command.diffToggleFile:
            case Command.diffCollapseAll:
            case Command.diffExpandAll:
                break; // the file list lives in the workspace, not here
        }
        return true;
    }

    /// The facts the table may consult, assembled from this viewer's state.
    /// One place, so a binding's gate cannot mean something different here
    /// than it does in the window.
    private KeyContext keyContext() const @safe pure nothrow @nogc
        => KeyContext(
            mode: searching ? InputMode.search : InputMode.normal,
            // The terminal viewer searches line-by-line rather than
            // materialising a match list, so a live query IS the
            // condition `n`/`N` are gated on.
            hasMatches: qlen > 0,
            hasDiffSession: vm.showPreview && !vm.diffSession.empty,
            showPreview: vm.showPreview,
        );

    private bool handlePointer(in PointerEvent e) @system
    {
        const rows = bodyRows();
        if (e.button == PointerButton.left
            && e.action == PointerAction.release)
        {
            if (!externalScroll)
            {
                sb = sb.released();
                vm.hsb = vm.hsb.released();
            }
            vm.fenceSv.h = vm.fenceSv.h.released();
            vm.fenceSv.v = vm.fenceSv.v.released();
            vm.syncFenceHot(); // the thumb's accent feedback follows
            return true;
        }
        // The fence scrollbars (`COD6`): a grab owns the pointer; the drag
        // tracks wherever it strays, like every scrollbar grab.
        if (e.button == PointerButton.left
            && e.action == PointerAction.drag
            && (vm.fenceSv.h.dragging || vm.fenceSv.v.dragging))
        {
            fenceBarDrag(Point(e.pos.x + (vm.hOverflows()
                ? cast(int) vm.hsb.offset : 0),
                cast(int)(top + (e.pos.y - 1))));
            return true;
        }
        // The horizontal bar (IXB2): its row is the last body row; the
        // grab owns the pointer, like every scrollbar grab.
        if (!externalScroll && e.button == PointerButton.left
            && ((e.action == PointerAction.press && vm.hOverflows()
                    && e.pos.y == rows && e.pos.x >= 0 && e.pos.x < width - 1)
                || (e.action == PointerAction.drag && vm.hsb.dragging)))
        {
            vm.hsb = e.action == PointerAction.press && !vm.hsb.dragging
                ? vm.hsb.pressed(e.pos.x, vm.contentCols, vm.widthCols,
                    width - 1)
                : vm.hsb.dragged(e.pos.x, vm.contentCols, vm.widthCols,
                    width - 1);
            return true;
        }
        // A scrollbar grab OWNS the pointer: the press must land on the
        // last column, but the drag tracks wherever the pointer strays
        // (never falling into the selection branch) until release —
        // and symmetrically, a selection drag crossing the last column
        // never jumps the scroll.
        if (!externalScroll && e.button == PointerButton.left
            && ((e.action == PointerAction.press && e.pos.x == width - 1
                    && e.pos.y >= 1 && e.pos.y <= rows)
                || (e.action == PointerAction.drag && sb.dragging)))
        {
            // The one scrollbar machine (STM9): a press on the handle grabs
            // in place, on the track it jumps; drags move grab-relative and
            // own the pointer until release.
            sb = e.action == PointerAction.press && !sb.dragging
                ? sb.scrolledTo(top).pressed(e.pos.y - 1,
                    cast(size_t) lineCount, rows, rows)
                : sb.scrolledTo(top).dragged(e.pos.y - 1,
                    cast(size_t) lineCount, rows, rows);
            top = sb.offset;
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
            // Content hits live in the (possibly) horizontally scrolled
            // space — the paint shifts left by the bar's offset (IXB2).
            const hx = vm.hOverflows() ? cast(int) vm.hsb.offset : 0;
            if (showPreview && e.action == PointerAction.press
                && tw.code.length)
            {
                const off = sourceOffsetAt(mdTree, mdFrames,
                    Point(e.pos.x + hx, cast(int) line));
                if (off >= 0)
                    foreach (i, ni; hoverNodes)
                        if (off >= cast(long) tw.nodes[ni].start
                            && off < cast(long)(tw.nodes[ni].start
                                + tw.nodes[ni].length))
                        {
                            hoverSel = hoverSel == cast(int) i
                                ? -1 : cast(int) i;
                            hoverExpanded = null;
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
                const p = Point(e.pos.x + hx, cast(int) line);
                foreach_reverse (ref const t; mdTargets)
                {
                    if (t.hitId >= foldHitBase && t.rect.contains(p))
                    {
                        vm.folds = vm.folds.toggled(t.hitId - foldHitBase);
                        vm.rebuild();
                        return true;
                    }
                    if (t.hitId >= fenceHitBase && t.rect.contains(p))
                    {
                        copyFenceAt(t.hitId - fenceHitBase);
                        return true;
                    }
                    // Below the fence range — see the GUI's note on order.
                    if (t.hitId >= codeTabHitBase && t.hitId < fenceHitBase
                        && t.rect.contains(p))
                    {
                        vm.activateCodeTab(t.hitId - codeTabHitBase);
                        return true;
                    }
                    if (t.hitId >= tableCopyHitBase
                        && t.hitId < codeTabHitBase && t.rect.contains(p))
                    {
                        copyTableAt(t.hitId - tableCopyHitBase);
                        return true;
                    }
                    // The fence scrollbars (COD6): press grabs, the border
                    // line is the track (track-click jumps included).
                    if (t.hitId >= fenceVBarHitBase
                        && t.hitId < tableCopyHitBase && t.rect.contains(p))
                    {
                        fenceBarPress(t, p);
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
    assert(t.sb.dragging);
    const grabbed = t.top;
    assert(!t.sel.active, "a scrollbar press never starts a selection");

    // ...and the drag keeps scrolling even off the column — no selection.
    assert(t.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.drag, pos: Point(10, 4)))));
    assert(t.top > grabbed, "the drag kept scrolling off the column");
    assert(!t.sel.active, "a scrollbar drag never selects text");
    assert(t.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.release, pos: Point(10, 4)))));
    assert(!t.sb.dragging);

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

@("tui.pointer.horizontalBarScrollsWideContent")
@system
unittest
{
    import sparkles.syntax : builtinDark, MdBlock, MdBlockKind, MdDoc,
        MdInline, MdInlineKind, Span, LabelSet;

    // A table whose one cell is 120 cells wide in a 40-column pane: table
    // cells never wrap, so the laid-out frames extend past the pane and the
    // model reports horizontal overflow (IXB2). (A wide FENCE no longer
    // qualifies — its body scrolls inside its own panel viewport, `COD`.)
    string src = "wide\n";
    foreach (i; 0 .. 120)
        src ~= "x";
    auto doc = MdDoc(MdBlock(kind: MdBlockKind.document, children: [
        MdBlock(kind: MdBlockKind.paragraph, inlines: [
            MdInline(kind: MdInlineKind.text, span: Span(0, 4))]),
        MdBlock(kind: MdBlockKind.table, children: [
            MdBlock(kind: MdBlockKind.tableRow, children: [
                MdBlock(kind: MdBlockKind.tableCell, span: Span(5, src.length),
                    inlines: [MdInline(kind: MdInlineKind.text,
                        span: Span(5, src.length))]),
            ]),
        ]),
    ]), src);

    static immutable(Theme)[1] themes = [builtinDark];
    static immutable string[1] names = ["dark"];
    PreviewTui t;
    t.labels = LabelSet.standard();
    t.names = names[];
    t.themes = themes[];
    t.width = 40;
    t.height = 8; // bodyRows = 6; the h-bar row is y == 6
    t.relayout();
    t.setDocument("wide.md", src, null, PreviewModel(present: true, doc: doc),
        startPreview: true);
    assert(t.vm.hOverflows(), "the 120-cell fence line overflows the pane");

    // A press on the bar's row grabs it; the drag scrolls the columns and
    // owns the pointer; release ends the grab.
    assert(t.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.press, pos: Point(2, 6)))));
    assert(t.vm.hsb.dragging);
    assert(t.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.drag, pos: Point(30, 3)))));
    assert(t.vm.hsb.offset > 0, "the drag scrolled the columns");
    assert(!t.selection.active, "a bar grab never selects text");
    assert(t.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.release, pos: Point(30, 3)))));
    assert(!t.vm.hsb.dragging);
}

@("tui.pointer.nestedFenceScrollsToTheEnd")
@system
unittest
{
    import sparkles.syntax : builtinDark, MdBlock, MdBlockKind, MdDoc,
        MdInline, MdInlineKind, Span, LabelSet;

    // A 120-cell code line, once top-level and once inside a BLOCK QUOTE,
    // in a 40-column pane. The quote card narrows the fence's box (2 left
    // + 1 right), and the x clamp must know that REAL interior — computed
    // against the top-level width it stops 3 columns short of the end.
    string src;
    foreach (i; 0 .. 120)
        src ~= "x";
    src ~= "\n";
    MdBlock fence() => MdBlock(kind: MdBlockKind.codeFence,
        span: Span(0, src.length), codeBody: Span(0, src.length));

    static immutable(Theme)[1] themes = [builtinDark];
    static immutable string[1] names = ["dark"];
    PreviewTui t;
    t.labels = LabelSet.standard();
    t.names = names[];
    t.themes = themes[];
    t.width = 40;
    t.height = 10;
    t.relayout();

    t.setDocument("top.md", src, null, PreviewModel(present: true,
        doc: MdDoc(MdBlock(kind: MdBlockKind.document,
            children: [fence()]), src)), startPreview: true);
    const top = t.vm.fenceExtent(0);
    assert(top.widest == 120 && top.innerW > 0);

    t.setDocument("quoted.md", src, null, PreviewModel(present: true,
        doc: MdDoc(MdBlock(kind: MdBlockKind.document, children: [
            MdBlock(kind: MdBlockKind.blockQuote, children: [fence()]),
        ]), src)), startPreview: true);
    const quoted = t.vm.fenceExtent(0);
    assert(quoted.innerW == top.innerW - 3,
        "the clamp reflects the card's 2-left + 1-right insets");
    assert(t.vm.setFenceScroll(0, long.max, 0));
    assert(t.vm.fenceScrollAt[0].x == quoted.widest - quoted.innerW,
        "the quoted fence scrolls all the way to its last column");
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

    // A click on the top-border copy cutout (` ⧉ ` before the corner)
    // copies the fence body (OSC 52) and flips the affordance to the ✔
    // glyph until the next event. The click lands on the hit target's own
    // rect — the affordance is the cutout, not the whole border row.
    int ix = -1, iy = -1;
    foreach (ref const tg; t.vm.targets)
        if (tg.hitId == ViewerModel.fenceHitBase + 12)
        {
            ix = tg.rect.x + 1;           // the icon cell inside the cutout
            iy = cast(int) tg.rect.y + 1; // content starts on pane row 1
        }
    assert(ix > 0, "no copy target on the top border");
    const clicked = t.handle(Event(PointerEvent(action: PointerAction.press,
        button: PointerButton.left, pos: Point(ix, iy))));
    assert(clicked && t.clipReady);
    // The PAYLOAD, not an OSC 52 sequence: how a target carries a clipboard
    // write is the host's to know (`HST`), and a window carries the same
    // text a different way entirely.
    assert((cast(string) t.clip[]).canFind(src[12 .. $]));
    t.paint(g);
    assert(row(cast(ushort) hdrY).canFind("\U0000F00C"),
        "copied feedback glyph not shown");

    // Drag-selecting the paragraph row and pressing `y` copies its source.
    t.clipReady = false;
    t.handle(Event(PointerEvent(action: PointerAction.press,
        button: PointerButton.left, pos: Point(1, 1))));
    t.copySelection();
    assert(t.clipReady);
    assert((cast(string) t.clip[]).canFind(src[0 .. 11]));
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

@("tui.keys.resolvedDivergencesFromTheGuiTable")
@system
unittest
{
    import sparkles.input : Mods;
    import sparkles.syntax : builtinDark, HighlightEvent, LabelSet;

    // Before this, the terminal viewer had its own copy of the keyboard
    // policy and had drifted: `g`/`G` were top/bottom while the window's `g`
    // started go-to-line, and `q` quit only here. Both now come from the one
    // table, and this pins the resolution so it cannot drift back.
    static immutable src = "l0\nl1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\n";
    static HighlightEvent[1] ev = [HighlightEvent.sourceSpan(0, src.length)];
    static immutable(Theme)[1] themes = [builtinDark];
    static immutable string[1] names = ["dark"];

    PreviewTui t;
    t.title = "d.txt";
    t.source = src;
    t.events = ev[];
    t.labels = LabelSet.standard();
    t.names = names[];
    t.themes = themes[];
    t.width = 40;
    t.height = 6;
    t.relayout();

    KeyEvent k(dchar c, bool shift = false)
        => KeyEvent(key: Key.char_, ch: c, mods: Mods(shift: shift));

    // `gg` goes to the top, `Shift-G` to the bottom — vim's motions, and the
    // first key of `gg` must do nothing on its own.
    t.handle(Event(k('j')));
    t.handle(Event(k('j')));
    assert(t.top == 2);
    t.handle(Event(k('g')));
    assert(t.top == 2, "a lone `g` is a prefix, not a motion");
    t.handle(Event(k('g')));
    assert(t.top == 0, "gg jumps to the top");
    t.handle(Event(k('g', true)));
    assert(t.top == t.maxTop, "Shift-G jumps to the bottom");

    // `q` quits — `handle` returning false is how this viewer says so.
    assert(!t.handle(Event(k('q'))), "q quits");

    // …and an unbound key is still unbound rather than swallowed.
    assert(t.handle(Event(k('w'))));
}

@("tui.lantern.panelPaintsIntoTheCellGrid")
@system
unittest
{
    import core.time : msecs;
    import sparkles.input : Mods;
    import sparkles.syntax : builtinDark, HighlightEvent, LabelSet;
    import std.algorithm.searching : canFind;

    // `UIA2`'s claim is that one widget tree serves both backends. That is
    // only worth anything if the terminal actually paints it, so: press the
    // prefix, let the delay elapse, and read the cells back.
    static immutable src = "alpha\nbeta\ngamma\n";
    static HighlightEvent[1] ev = [HighlightEvent.sourceSpan(0, src.length)];
    static immutable(Theme)[1] themes = [builtinDark];
    static immutable string[1] names = ["dark"];

    PreviewTui t;
    t.title = "d.txt";
    t.source = src;
    t.events = ev[];
    t.labels = LabelSet.standard();
    t.names = names[];
    t.themes = themes[];
    t.width = 70;
    t.height = 20;
    t.relayout();

    // Nothing pending: no panel, and nothing asking to be woken.
    assert(t.untilLanternShown == Duration.max);

    t.handle(Event(KeyEvent(key: Key.char_, ch: 'z')));
    assert(t.untilLanternShown < Duration.max,
        "a prefix must give the loop a deadline to wait on");

    Grid g;
    g.resize(70, 20);
    t.paint(g);
    assert(!panelText(g).canFind("close fold"),
        "the panel must not appear before the delay elapses");

    t.tickLantern(500.msecs);
    g.resize(70, 20);
    t.paint(g);
    const shown = panelText(g);
    assert(shown.canFind("close fold"), "zc must be listed once the delay is up");
    assert(shown.canFind("open fold"), "…and so must its siblings");
}

version (unittest)
{
    /// The grid's bottom rows as text — where the `classic` panel lands.
    private string panelText(ref Grid g) @system
    {
        string s;
        foreach (y; 0 .. g.rows)
        {
            foreach (x; 0 .. g.cols)
                s ~= g[cast(ushort) x, cast(ushort) y].grapheme;
            s ~= '\n';
        }
        return s;
    }
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

@("tui.wheel.horizontalNotchesAndShiftScrollSideways")
@system unittest
{
    import sparkles.syntax : builtinDark, ColAlign, LabelSet, MdBlock,
        MdBlockKind, MdDoc, MdInline, MdInlineKind, Span;
    import sparkles.input.events : Mods, WheelEvent;

    // The terminal has decoded horizontal wheel since SGR-1006 went in
    // (buttons 66/67 → `dx`); the viewer's handler dropped it on the floor.
    // A wide TABLE, repeated until it is also tall, so the two axes can be
    // told apart. Not a fence: a fence body scrolls its own viewport now
    // (`COD`) and never widens the document.
    string src;
    foreach (_; 0 .. 60)
        src ~= "a";
    foreach (_; 0 .. 60)
        src ~= "b";
    static MdBlock tcell(size_t s, size_t e)
        => MdBlock(kind: MdBlockKind.tableCell, span: Span(s, e),
            inlines: [MdInline(kind: MdInlineKind.text, span: Span(s, e))]);
    auto trow = MdBlock(kind: MdBlockKind.tableRow, span: Span(0, 120),
        children: [tcell(0, 60), tcell(60, 120)]);
    MdBlock[] rows;
    foreach (_; 0 .. 20)
        rows ~= trow;
    auto doc = MdDoc(MdBlock(kind: MdBlockKind.document, children: [
        MdBlock(kind: MdBlockKind.table, span: Span(0, 120),
            aligns: [ColAlign.none, ColAlign.none], children: rows),
    ]), src);

    static immutable(Theme)[1] themes = [builtinDark];
    static immutable string[1] names = ["dark"];
    PreviewTui t;
    t.labels = LabelSet.standard();
    t.names = names[];
    t.themes = themes[];
    t.width = 40;
    t.height = 8;
    t.relayout();
    t.setDocument("wide.md", src, null, PreviewModel(present: true, doc: doc),
        startPreview: true);
    assert(t.vm.hOverflows(), "precondition: the content overflows");

    assert(t.handle(Event(WheelEvent(dx: 6))));
    assert(t.vm.hsb.offset == 6, "a sideways notch scrolls sideways");
    assert(t.handle(Event(WheelEvent(dx: -6))));
    assert(t.vm.hsb.offset == 0);

    // Shift + a vertical notch does the same — the convention every browser
    // answers to, and the one a phone can actually produce.
    const before = t.vm.top;
    assert(t.handle(Event(WheelEvent(dy: 4, mods: Mods(shift: true)))));
    assert(t.vm.hsb.offset == 4, "shift redirects the wheel sideways");
    assert(t.vm.top == before, "and must not also scroll down");

    // Without the modifier it still scrolls vertically, as it always did.
    assert(t.handle(Event(WheelEvent(dy: 2))));
    assert(t.vm.hsb.offset == 4 && t.vm.top != before);
}
