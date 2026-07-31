// The GUI viewer's Whole (`PRN1`/`MIG9`, Sean Parent's C1 diagnosis): one
// value that owns the document, its theme-resolved colors, the widget-pipeline
// artifacts, folding, scroll, and search — the state `runGui` used to keep as
// ~25 free locals related only by lexical scope. Raylib-free, so the whole
// view/relayout/search/fold surface is unit-testable without a window; gui.d
// keeps windowing, input translation, and painting.
module viewer_model;

import ansi_model : AnsiLine, Attr;
import document : hueFenceRenderer;
import gui_preview : PreviewModel, quoteBarColors, quoteBarCycle;
import gui_text : buildLineStarts, findMatches, lineCount, Match;

import sparkles.base.term_color : mix;
import sparkles.base.term_style : UnderlineStyle;
import sparkles.syntax : HighlightEvent, LabelSet, ResolvedTheme, resolveTheme,
    RgbColor, Theme, toRgb;
import sparkles.syntax.md.model : MdBlock, MdBlockKind, Span;
import sparkles.syntax.md.render_widgets : foldableSpans, MdViewOptions,
    MdViewTheme, viewMarkdown;
import sparkles.syntax.render.widgets : CodeViewOptions, viewCodeDocument;
import sparkles.syntax.ts.injection : TsConfigCache;
import sparkles.twoslash.protocol : TwoslashReturn;
import sparkles.twoslash.render_widgets : viewTwoslashDocument;

import sparkles.ui.canvas : DrawOp, OpKind;
import sparkles.ui.display_list : buildDisplayList;
import sparkles.ui.geometry : Constraints, Rect;
import sparkles.ui.layout : Frame, layout;
import sparkles.ui.state : ScrollAxis, ScrollbarState, DisclosureState, DocRow, documentRows, HoverTarget,
    hoverTargets, KeyedRect, keyedRects, selectionRects;
import sparkles.ui.style : defaultTwoslashPalette, schemeForBackground,
    TextStyle;
import sparkles.ui.widget : TextSpan, WidgetTree;

/// Sane concrete fallbacks when a theme leaves the page fore-/background unset
/// (a GPU/grid surface has no "terminal default" to defer to).
enum RgbColor hardFallbackFg = RgbColor(0xcd, 0xd6, 0xf4);
/// ditto
enum RgbColor hardFallbackBg = RgbColor(0x1e, 0x1e, 0x2e);

/// A fenced code block's identity artifacts: its body span and whether it is
/// a pre-styled ` ```ansi ` fence (copy honors the ansi-copy mode for those).
struct MdFence
{
    Span body;
    bool isAnsi;
}

/// One table cell in document order: its table index, grid position, and
/// source span — the resolving context for keyed-cell hits and table copy.
struct MdCell
{
    int table;
    size_t row, col;
    Span span;
}

/// A table's grid dimensions.
struct Dims
{
    size_t rows, cols;
}

/// A gutter fold marker (`FLD5`): the visual row a foldable region begins
/// on (the outermost when several start there), its fold key, and whether
/// the region is currently open (`▾`) or folded (`▸`).
struct FoldMarker
{
    size_t row;
    size_t key;
    bool open;
}

/// Maps `gui_ansi.Attr` bits onto the toolkit's per-span text chrome — the
/// decoded-ANSI fence renderer stamps these on its resolved-color spans.
TextStyle attrsToTextStyle(ubyte attrs) pure nothrow @nogc @safe
{
    TextStyle t;
    t.bold = (attrs & Attr.bold) != 0;
    t.italic = (attrs & Attr.italic) != 0;
    t.strikethrough = (attrs & Attr.strikethrough) != 0;
    if (attrs & Attr.underline)
        t.underline = UnderlineStyle.single;
    return t;
}

/**
The viewer's document + view-state Whole. The host configures the theme
list once, feeds documents through $(LREF setDocument), and drives
$(LREF applyTheme) / $(LREF relayout); every derived artifact (the laid-out
tree, its ops, the row identity index, hit targets, keyed cells, fence and
cell structure, match rects) is owned here and stays mutually consistent —
there is no second copy for a painter to disagree with.
*/
struct ViewerModel
{
    // ── configuration (set once by the host) ────────────────────────────────
    const(string)[] names;          /// theme names, parallel to `themes`
    immutable(Theme)[] themes;
    LabelSet labels;
    TsConfigCache* cache;           /// fence highlighting (null ⇒ plain bodies)
    /// Optional ` ```ansi ` fence decoder (the GUI's off-screen VT); without
    /// it ansi fences degrade to SGR-stripped plain text (hueFenceRenderer).
    AnsiLine[] delegate(const(char)[]) @system decodeAnsi;

    // ── the document ────────────────────────────────────────────────────────
    string title;
    string summary;
    const(char)[] source;
    string lang;                    /// canonical language (CST fold provider)
    const(HighlightEvent)[] events;
    PreviewModel preview;
    TwoslashReturn tw;              /// empty `code` ⇒ not a twoslash document
    size_t srcTotal;                /// source (physical) line count
    size_t[] lineStarts;
    bool showPreview;               /// decorated view vs raw source (Tab)
    int tabWidth = 4;               /// tab stops in the raw view (--tab-width)
    bool listWhitespace;            /// vim `list` (--list-whitespace)
    bool codeLineNumbers = true;    /// in-panel fence numbers ('c' toggles)
    /// Fold placeholders keep their inline `▸ ` prefix — the TUI's one fold
    /// affordance; the GUI leaves this false (its gutter column carries it).
    bool inlineFoldMarker;

    // ── theme-resolved values ───────────────────────────────────────────────
    size_t themeIdx;
    ResolvedTheme current;
    RgbColor pageFg, pageBg, gutterFg;
    RgbColor gutterBg;              /// the gutter strip's theme-derived band
    RgbColor[quoteBarCycle] quoteBars;
    RgbColor sbTrack, sbThumb;      /// link-tinted scrollbar chrome

    // ── the widget pipeline (derived; rebuilt as one) ───────────────────────
    WidgetTree tree;
    Frame[] frames;
    DrawOp[] ops;
    DocRow[] rows;                  /// the identity channel, per visual row
    HoverTarget[] targets;
    KeyedRect[] cells;              /// source-keyed table-cell rects
    MdFence[] fences;
    MdCell[] cellList;
    size_t copiedFenceSrc = size_t.max; /// body start of the just-copied fence
    DisclosureState!size_t folds = DisclosureState!size_t(true);
    Span[] foldable;
    /// Horizontal overflow (IXB2): the widest laid-out right edge in doc
    /// cells, and the horizontal bar's machine (offset in cells).
    int contentCols;
    ScrollbarState hsb = ScrollbarState(ScrollAxis.horizontal);
    FoldMarker[] foldMarkers;       /// gutter markers, derived with the rows
    int widthCols = -1;             /// the width the pipeline is laid out for

    // Source-anchored identity bases (disjoint id spaces — see the md view).
    enum size_t fenceHitBase = size_t.max / 2 + 1;
    enum size_t foldHitBase = size_t.max / 4 * 3 + 1;
    enum size_t tableKeyBase = 1;

    // ── scroll + search ─────────────────────────────────────────────────────
    long top;                       /// first visible visual row
    Match[] matches;
    size_t curMatch;
    Rect[][] matchRects;            /// per-match rects via the identity channel

@system:

    /// Replaces the viewed document: content swaps, scroll/search/folds
    /// reset, the pipeline rebuilds at the current width.
    void setDocument(string title_, string summary_, const(char)[] source_,
        const(HighlightEvent)[] events_, PreviewModel preview_,
        TwoslashReturn tw_, string lang_ = null)
    {
        title = title_;
        summary = summary_;
        source = source_;
        lang = lang_;
        events = events_;
        preview = preview_;
        tw = tw_;
        srcTotal = lineCount(source);
        lineStarts = buildLineStarts(source);
        showPreview = preview.present || tw.code.length != 0;
        top = 0;
        matches = null;
        matchRects = null;
        curMatch = 0;
        copiedFenceSrc = size_t.max;
        folds = DisclosureState!size_t(true);
        rebuild();
    }

    /// Whether the horizontal bar is live (content wider than the pane).
    bool hOverflows() const @safe pure nothrow @nogc
        => contentCols > widthCols && widthCols > 2;

    /// Resolves theme `i` (colors + quote bars + scrollbar tint) and rebuilds
    /// the pipeline so the view follows.
    void applyTheme(size_t i)
    {
        themeIdx = i;
        current = resolveTheme(themes[i], labels);
        pageFg = toRgb(current.defaults.fg, hardFallbackFg);
        pageBg = toRgb(current.defaults.bg, hardFallbackBg);
        gutterFg = mix(pageFg, pageBg, 0.5); // muted line numbers
        gutterBg = mix(pageBg, pageFg, 0.08); // the gutter's distinct band
        quoteBars = quoteBarColors(current, pageFg, pageBg);
        // Scrollbar chrome: tint toward the theme's link color so the hover
        // track and thumb read as a distinct hue against the grayscale bands.
        const linkC = toRgb(current[current.labels.resolve("markup.link")].fg,
            pageFg);
        sbTrack = mix(pageBg, linkC, 0.22);
        sbThumb = mix(pageBg, linkC, 0.5);
        rebuild();
    }

    /// Lays the pipeline out for a new width.
    void relayout(int widthCols_)
    {
        widthCols = widthCols_;
        rebuild();
    }

    /// Rebuilds the active view's pipeline: view → layout → display list,
    /// plus the derived row index, hit targets, keyed cells, document
    /// structure, and the search-match rects — all in lockstep.
    void rebuild()
    {
        if (showPreview && tw.code.length)
        {
            // A twoslash document: the whole-document widget view (code lines
            // as resolved spans + fused decorations + interleaved blocks).
            tree = viewTwoslashDocument(tw, events, thisCurrent(), pageFg,
                cache);
            frames = layout(tree, Constraints(maxW: widthCols));
            ops = buildDisplayList(tree, frames,
                defaultTwoslashPalette(schemeForBackground(pageBg)),
                pageFg, pageBg);
            derive(withTargets: true);
            cells = null;
            fences.length = 0;
            cellList.length = 0;
            foldable = null;
            return;
        }
        if (!showPreview || !preview.present)
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
            tree = viewCodeDocument(source, events, thisCurrent(), pageFg,
                CodeViewOptions(foldedRegions: closed,
                    foldHitBase: foldHitBase, tabWidth: tabWidth,
                    listWhitespace: listWhitespace,
                    whitespaceFg: gutterFg, hasWhitespaceFg: true,
                    inlineFoldMarker: inlineFoldMarker));
            frames = layout(tree, Constraints(maxW: widthCols));
            ops = buildDisplayList(tree, frames,
                themes[themeIdx].effectivePalette, pageFg, pageBg);
            derive(withTargets: foldable.length != 0);
            cells = null;
            fences.length = 0;
            cellList.length = 0;
            return;
        }
        MdViewOptions opt = {
            theme: MdViewTheme.derive(current, pageFg, pageBg),
            fenceHitBase: fenceHitBase,
            tableKeyBase: tableKeyBase,
            copiedFence: copiedFenceSrc,
            fenceRenderer: fenceRenderer(),
            foldedSpans: folds.exceptions,
            foldHitBase: foldHitBase,
            inlineFoldMarker: inlineFoldMarker,
            codeLineNumbers: codeLineNumbers,
        };
        foldable = foldableSpans(preview.doc);
        tree = viewMarkdown(preview.doc, opt);
        frames = layout(tree, Constraints(maxW: widthCols));
        ops = buildDisplayList(tree, frames,
            themes[themeIdx].effectivePalette, pageFg, pageBg);
        derive(withTargets: true);
        cells = keyedRects(tree, frames);
        collectStructure();
    }

    private void derive(bool withTargets)
    {
        // The widest painted right edge: TEXT ops carry their natural
        // extent even where the pane clips them (a fence line, a table row
        // — emitSpanRow advances past the clamp and the scissor crops), so
        // the display list, not the frames, knows what the horizontal bar
        // must reach (IXB2).
        contentCols = 0;
        foreach (ref const op; ops)
            if ((op.kind == OpKind.textRun || op.kind == OpKind.glyph)
                && op.rect.x + op.rect.width > contentCols)
                contentCols = op.rect.x + op.rect.width;
        if (cast(long) contentCols <= widthCols)
            hsb = hsb.scrolledTo(0);
        rows = documentRows(tree, frames);
        targets = withTargets ? hoverTargets(tree, frames) : null;
        rebuildMatchRects();

        // Gutter fold markers: the row each foldable region begins on.
        // Both lists are ordered by source position, so one two-pointer
        // pass suffices; same-row nested starts keep the outermost. The
        // marker lands on the FIRST identity-carrying row at-or-after the
        // region's start that still lies inside it — a markdown section
        // starts at `##` while its heading row's identity starts after the
        // marker text, and a fence's opening line renders as a header row.
        foldMarkers = null;
        size_t ri = 0;
        foreach (sp; foldable)
        {
            while (ri < rows.length && (rows[ri].srcStart == size_t.max
                || rows[ri].srcEnd <= sp.start))
                ++ri;
            if (ri < rows.length && rows[ri].srcStart != size_t.max
                && rows[ri].srcStart < sp.end
                && (!foldMarkers.length || foldMarkers[$ - 1].row != ri))
                foldMarkers ~= FoldMarker(ri, sp.start, folds.isOpen(sp.start));
        }
    }

    // The address of `current` for the view functions — a small @trusted
    // escape because `this` is addressable for the model's whole life.
    private const(ResolvedTheme)* thisCurrent() @trusted
        => &current;

    // The fence renderer: ` ```ansi ` fences decode through the host's
    // off-screen VT (resolved fg + bg + attrs) when it supplied a decoder;
    // every other language goes through the shared injection-aware
    // highlighter; without a cache, plain bodies.
    private TextSpan[][] delegate(const(char)[], const(char)[]) @safe
        fenceRenderer()
    {
        if (decodeAnsi is null)
            return cache !is null
                ? hueFenceRenderer(cache, thisCurrent(), pageFg) : null;
        auto highlight = cache !is null
            ? hueFenceRenderer(cache, thisCurrent(), pageFg) : null;
        auto decode = decodeAnsi;
        auto fg = pageFg;
        return delegate TextSpan[][] (const(char)[] lang, const(char)[] body_)
            @trusted {
            if (lang != "ansi")
                return highlight !is null ? highlight(lang, body_) : null;
            TextSpan[][] lines;
            foreach (ref ln; decode(body_))
            {
                TextSpan[] spans;
                foreach (ref sp; ln.spans)
                    spans ~= TextSpan(sp.text,
                        textStyle: attrsToTextStyle(sp.attrs),
                        fg: sp.fgDefault ? fg : sp.fg, hasFg: true,
                        bg: sp.bg, hasBg: !sp.bgDefault);
                lines ~= spans;
            }
            return lines;
        };
    }

    // Document structure resolved once per rebuild: fence bodies (for the
    // copy affordance) and table cells in document order.
    private void collectStructure()
    {
        fences.length = 0;
        cellList.length = 0;
        int tableIdx = -1;
        void collect(in MdBlock blk)
        {
            if (blk.kind == MdBlockKind.codeFence)
                fences ~= MdFence(blk.codeBody, blk.infoLang == "ansi");
            if (blk.kind == MdBlockKind.table)
            {
                ++tableIdx;
                foreach (ri, ref const row; blk.children)
                    foreach (ci, ref const cell; row.children)
                        cellList ~= MdCell(tableIdx, ri, ci, cell.span);
            }
            foreach (ref const c; blk.children)
                collect(c);
        }
        collect(preview.doc.root);
    }

    /// A table's grid dimensions from the collected cell list.
    Dims tableDims(int table) const @safe pure nothrow @nogc
    {
        Dims d;
        foreach (ref const mc; cellList)
            if (mc.table == table)
            {
                if (mc.row + 1 > d.rows)
                    d.rows = mc.row + 1;
                if (mc.col + 1 > d.cols)
                    d.cols = mc.col + 1;
            }
        return d;
    }

    // ── search ──────────────────────────────────────────────────────────────

    /// Recomputes the match set (and its on-screen rects) for `query`.
    void search(scope const(char)[] query)
    {
        matches = findMatches(source, query, lineStarts);
        curMatch = 0;
        rebuildMatchRects();
    }

    /// Clears the query's matches (Esc).
    void clearSearch()
    {
        matches = null;
        matchRects = null;
        curMatch = 0;
    }

    private void rebuildMatchRects()
    {
        matchRects.length = matches.length;
        foreach (i, ref const m; matches)
            matchRects[i] = selectionRects(tree, frames, m.start, m.end);
    }

    /// The first visual row at/after source line `srcLine` (goto-line).
    long visualOfSrc(size_t srcLine) const @safe pure nothrow @nogc
    {
        const target = srcLine < lineStarts.length
            ? lineStarts[srcLine] : source.length;
        foreach (idx, ref const r; rows)
            if (r.srcStart != size_t.max
                && (r.srcStart >= target || r.srcEnd > target))
                return cast(long) idx;
        return rows.length ? cast(long) rows.length - 1 : 0;
    }

    /// The visual row a match falls on (the row whose source range covers
    /// its byte offset), else its source line's first row.
    long visualOfMatch(in Match m) const @safe pure nothrow @nogc
    {
        foreach (idx, ref const r; rows)
            if (r.srcStart != size_t.max && r.srcStart <= m.start
                && m.start < r.srcEnd)
                return cast(long) idx;
        return visualOfSrc(m.line);
    }

    // ── folding ─────────────────────────────────────────────────────────────

    /// A directed fold operation at a byte offset (`FLD5`'s vim family).
    enum FoldOp : ubyte
    {
        toggle, /// `za`: unfold the innermost folded region, else fold
        close,  /// `zc`: fold the innermost still-open foldable region
        open,   /// `zo`: unfold the innermost folded region
    }

    /// Applies `op` to the innermost qualifying region containing byte
    /// `off`. Returns true (and rebuilds) when a region changed.
    bool foldAt(long off, FoldOp op = FoldOp.toggle)
    {
        if (off < 0)
            return false;
        // The innermost region containing `off` in the given disclosure
        // state — folded regions for open/toggle, open ones for close.
        size_t innermost(bool wantOpen)
        {
            size_t best = size_t.max, bestLen = size_t.max;
            foreach (sp; foldable)
                if (folds.isOpen(sp.start) == wantOpen
                    && off >= cast(long) sp.start && off < cast(long) sp.end
                    && sp.end - sp.start < bestLen)
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
            return false;
        folds = folds.toggled(best);
        rebuild();
        return true;
    }

    /// ditto — the unfold-first toggle (`za`).
    bool toggleFoldAt(long off) => foldAt(off, FoldOp.toggle);

    /// `zR` / `zM`: open every fold, or fold every foldable region — O(1)
    /// resets on the disclosure machine's polarity + exception set.
    void setAllFolds(bool folded)
    {
        folds = DisclosureState!size_t(true);
        if (folded)
            foreach (sp; foldable)
                folds = folds.closed(sp.start);
        rebuild();
    }

    /// `z1`–`z9`: fold to nesting level (vim's foldlevel) — regions nested
    /// `level` deep or deeper fold, shallower ones open. `level` 0 folds
    /// everything (`zM`); a level past the deepest nesting opens all (`zR`).
    void foldToLevel(int level)
    {
        folds = DisclosureState!size_t(true);
        // Depth via an enclosing-ends stack: the regions are source-ordered
        // and properly nested, so the stack depth at each region's start is
        // its nesting level.
        size_t[] ends;
        foreach (sp; foldable)
        {
            while (ends.length && ends[$ - 1] <= sp.start)
                ends = ends[0 .. $ - 1];
            if (cast(int) ends.length >= level)
                folds = folds.closed(sp.start);
            ends ~= sp.end;
        }
        rebuild();
    }

    /// `FLD6`: unfolds every folded region containing byte `off` (a search
    /// or goto target inside a fold becomes visible before the jump).
    /// Returns true (and rebuilds) when anything opened.
    bool revealOffset(size_t off)
    {
        bool changed;
        foreach (sp; foldable)
            if (!folds.isOpen(sp.start) && off >= sp.start && off < sp.end)
            {
                folds = folds.opened(sp.start);
                changed = true;
            }
        if (changed)
            rebuild();
        return changed;
    }

    /// Marks fence `bodyStart` as just-copied (its header shows the ✔) and
    /// rebuilds; `clearCopied` reverts when the host's flash ends.
    void markCopied(size_t bodyStart)
    {
        copiedFenceSrc = bodyStart;
        rebuild();
    }

    /// ditto
    void clearCopied()
    {
        copiedFenceSrc = size_t.max;
        rebuild();
    }
}

@("viewer_model.rawAndPreviewShareOnePipeline")
@system unittest
{
    import std.process : environment;
    import sparkles.syntax : builtinDark;
    import sparkles.test_runner.skip : skipTest;

    if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    // A tiny markdown document; no grammar cache (plain fences).
    ViewerModel vm;
    vm.names = ["dark"];
    vm.themes = [builtinDark];
    vm.labels = LabelSet.standard();
    vm.widthCols = 40;
    vm.applyTheme(0);

    const src = "# Title\n\nbody text\n";
    PreviewModel pm;
    import sparkles.syntax : extractMarkdown, GrammarRegistry;

    auto reg = GrammarRegistry.fromEnvironment();
    pm.doc = extractMarkdown(reg, src);
    pm.present = true;
    vm.setDocument("t.md", "", src,
        [HighlightEvent.sourceSpan(0, src.length)], pm, TwoslashReturn.init);

    // The preview view: decorated rows, foldable sections.
    assert(vm.showPreview && vm.rows.length);
    assert(vm.foldable.length); // the heading section folds

    // Tab to raw: the same pipeline, code rows with identity.
    vm.showPreview = false;
    vm.rebuild();
    assert(vm.rows.length == 3);
    assert(vm.rows[0].srcStart == 0);
    assert(vm.foldable.length == 0);

    // Search runs on the source and lands on the raw rows.
    vm.search("body");
    assert(vm.matches.length == 1);
    assert(vm.visualOfMatch(vm.matches[0]) == 2);
    assert(vm.matchRects.length == 1 && vm.matchRects[0].length == 1);
}

@("viewer_model.cstFoldsInTheRawView")
@system unittest
{
    import std.algorithm.searching : canFind;
    import std.process : environment;
    import sparkles.syntax : builtinDark, GrammarRegistry;
    import sparkles.test_runner.skip : skipTest;

    if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    auto reg = GrammarRegistry.fromEnvironment();
    const labels = LabelSet.standard();
    auto cache = TsConfigCache.create(&reg, labels);

    ViewerModel vm;
    vm.names = ["dark"];
    vm.themes = [builtinDark];
    vm.labels = labels;
    vm.cache = &cache;
    vm.widthCols = 60;
    vm.applyTheme(0);

    const src = "void f()\n{\n    int a;\n    int b;\n}\nint tail;\n";
    vm.setDocument("f.d", "", src,
        [HighlightEvent.sourceSpan(0, src.length)], PreviewModel.init,
        TwoslashReturn.init, "d");

    // The raw code view has CST fold ranges (FSR1) and full rows, and the
    // gutter markers land on the regions' first rows, open (FLD5).
    assert(!vm.showPreview && vm.foldable.length, "CST regions found");
    const openRows = vm.rows.length;
    assert(openRows == 6);
    assert(vm.foldMarkers.length, "gutter markers derived");
    assert(vm.foldMarkers[0].row == 0 && vm.foldMarkers[0].open);

    // zc at the function body folds it to a placeholder row.
    assert(vm.foldAt(2, ViewerModel.FoldOp.close));
    assert(vm.rows.length < openRows);
    bool sawPlaceholder;
    foreach (ref const r; vm.rows)
        if (r.text.canFind("lines") && !r.text.canFind("▸"))
            sawPlaceholder = true; // unobstructed: the ▸ lives in the gutter
    assert(sawPlaceholder, "fold placeholder rendered");

    // The folded region's marker flips to ▸ on the placeholder row.
    bool sawFolded;
    foreach (ref const fm; vm.foldMarkers)
        if (!fm.open)
            sawFolded = true;
    assert(sawFolded, "a folded marker");

    // zR restores everything.
    vm.setAllFolds(false);
    assert(vm.rows.length == openRows);

    // z1 (foldlevel 1): the top-level function stays open, its nested
    // regions (the body block and deeper) fold; z9 opens everything.
    vm.foldToLevel(1);
    assert(vm.rows.length < openRows && vm.rows.length > 2,
        "nested regions folded, the top level open");
    vm.foldToLevel(9);
    assert(vm.rows.length == openRows);
    // z0-equivalent: level 0 folds every region (zM).
    vm.foldToLevel(0);
    bool topFolded;
    foreach (ref const fm; vm.foldMarkers)
        if (fm.row == 0 && !fm.open)
            topFolded = true;
    assert(topFolded, "level 0 folds the top-level region");
}
