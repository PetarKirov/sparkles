// `hue --gui` — the raylib GPU rendering backend.
//
// A third consumer of hue's (source, events, theme) triple: instead of folding
// the highlight-event stream into ANSI escapes or HTML markup, it folds it into
// raylib draw calls — "styled runs as data", the GPU backend sparkles:syntax was
// designed for (docs/specs/syntax §2). A read-only, windowed, syntax-highlighted
// view with a live theme previewer, mirroring hue's terminal Previewer on the GPU.
//
// Compiled only by the `gui` build configuration (version(HueGui)); the default
// terminal build never references raylib. Build: dub build :hue -c gui.
//
// The raylib scaffolding here (FontSet, glyph fallback, the draw primitive) is a
// deliberate COPY of apps/terminal's text-rendering core, authored in the shape
// the shared sparkles:raylib-text library will own (issue #121 M5) so the
// extraction is a move, not a redesign. The pure text-layout logic lives in the
// raylib-free `gui_text` module (unit-tested by `dub test :hue`).
module gui;

version (HueGui):

import raylib;

import core.stdc.stdarg : va_list; // for the TraceLogCallback bridge (NFR7)

// The shared raylib text core (extracted in M5). Pulls raylib-d + libs
// "raylib" transitively, so it is present only in the `gui` build.
import sparkles.raylib_text : TextStyle, FontSet, drawText;

// hue-specific viewport/search layout (raylib-free, so it stays testable).
import gui_text : columnWidth, lineCount, Match, buildLineStarts, findMatches;

// Markdown-preview model + layout (raylib-free) and the ANSI attribute bits.
import gui_preview : PreviewModel, PreviewLine, PreviewRun, BandKind, PreviewDoc,
    TableView, flattenPreview, wrapPreview, buildRawPlines, quoteBarColors,
    quoteBarCycle, stripSgr;
import gui_ansi : Attr;

// 2D table grid selection (TBL): the screen↔cell map + pure region/serialize logic.
import sparkles.ui.components.table : GridHit, CellSpan;
import table_select : TableRegion, TableCopyFormat, tableSelection, serializeTable;

// Selective import avoids sparkles.syntax.Color clashing with raylib.Color:
// bare `Color` is unambiguously raylib's; the theme color type is reached only
// through StyleSpec.fg/bg (never named here).
import sparkles.syntax : HighlightEvent, LabelId, LabelSet, Theme, StyleSpec, TextAttr, UnderlineStyle,
    ResolvedTheme, resolveTheme, byStyledLine, byStyledSpan, RgbColor, toRgb;
import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.term_color : mix;

import sparkles.syntax.ts.injection : TsConfigCache;
import sparkles.twoslash.protocol : Completion, Node, NodeType, TwoslashReturn;
import sparkles.twoslash.overlay : BelowBlock, errIsWarning, highlightSignature,
    InlineDecoration, planTwoslash, TwoslashPlan, withoutQuickinfoPrefix;
import sparkles.twoslash.render_widgets : viewHoverPopup;

// The shared visual language: the twoslash palette is the single source for the
// error/warn/tag/highlight colors this backend used to hand-copy as literals, and
// the widget views drive the hover popup (so the GUI matches the TUI/HTML chrome).
import sparkles.ui.style : defaultTwoslashPalette, Palette, resolveSlot,
    schemeForBackground, Slot, Visual;
import sparkles.ui.geometry : Point, Rect;
import sparkles.ui.canvas : LineStyle, OpKind;
import sparkles.ui.layout : layout;
import sparkles.ui.state : scrollbarThumb, Timeline;
import sparkles.ui.display_list : buildDisplayList;
import sparkles.ui.interp.immediate : paint;
import sparkles.ui_raylib : RaylibCanvas, rlBg;

// The multi-document set the twoslash view navigates with `[`/`]` (`GNV1`), plus
// the two entry points a navigation reload needs.
import source_set : SourceEntry, SourceSet;
import sparkles.twoslash.ingest : loadTwoslashFile;
import sparkles.syntax.ts.highlighter : highlightInjected;

/// The window's default font size in pixels (Ctrl-±/theme cycling arrive in M3).
private enum defaultFontSize = 18;

/// A short tag for a raylib `TraceLogLevel`, embedded in the bridged message.
private string raylibLevelTag(int logLevel) @safe pure nothrow @nogc
{
    switch (logLevel)
    {
        case TraceLogLevel.LOG_TRACE:   return "trace";
        case TraceLogLevel.LOG_DEBUG:   return "debug";
        case TraceLogLevel.LOG_INFO:    return "info";
        case TraceLogLevel.LOG_WARNING: return "warning";
        case TraceLogLevel.LOG_ERROR:   return "error";
        case TraceLogLevel.LOG_FATAL:   return "fatal";
        default:                        return "log";
    }
}

/// Bridges raylib's `TraceLog` output into `sparkles.base.logger` (hue spec
/// `NFR7`). raylib hands us a printf-style format + `va_list`; we render it
/// into a stack buffer and emit through the logger at $(B trace) level, so its
/// chatter obeys hue's log level — silent under the default warning threshold
/// (`DEG1`) — instead of going straight to stderr. `extern(C) @nogc nothrow`
/// to match `TraceLogCallback`; installed before `InitWindow`.
extern (C) private void raylibTraceLog(int logLevel, const(char)* text, va_list args)
    @nogc nothrow
{
    import core.stdc.stdio : vsnprintf;
    import sparkles.base.logger : trace;

    char[1024] buf = void;
    const written = () @trusted { return vsnprintf(buf.ptr, buf.length, text, args); }();
    if (written <= 0)
        return;
    const len = written < cast(int) buf.length ? cast(size_t) written : buf.length - 1;
    const msg = () @trusted { return cast(const(char)[]) buf[0 .. len]; }();
    trace(i"raylib[$(raylibLevelTag(logLevel))]: $(msg)");
}

/// Sane concrete fallbacks when a theme leaves the page fore-/background unset
/// (the GPU has no "terminal default" to defer to, unlike the ANSI backend).
private enum RgbColor hardFallbackFg = RgbColor(0xcd, 0xd6, 0xf4);
private enum RgbColor hardFallbackBg = RgbColor(0x1e, 0x1e, 0x2e);

/// Translucent overlays for search matches: all matches, and the current one.
private enum Color matchTint = Color(255, 215, 0, 70);
private enum Color currentMatchTint = Color(255, 145, 0, 130);

/// The interactive input mode (M4): normal keys, or typing a search / goto line.
private enum Mode
{
    normal,
    search,
    gotoLine,
}

/// A loaded document — the highlight inputs the viewer needs to show one file.
struct LoadedDoc
{
    const(char)[] source;
    const(HighlightEvent)[] events;
    PreviewModel preview;
}

/// Loads a document by path. Supplied by `app.d`, which owns the grammar registry
/// and cache, so the GUI navigates a set (`GNV1`) without duplicating that
/// pipeline — the same delegate seam `gallery.writeGallery` uses.
alias DocLoader = LoadedDoc delegate(string path) @system;

/**
Opens the raylib window and paints the highlighted file. M1 draws the whole
file with the initially selected theme; scrolling/gutter (M2), sizing/resize
and live theme cycling (M3), and search (M4) build on top.

`names`/`themes` are the sorted, parallel built-in theme arrays; `startIdx` is
the initially selected theme. Returns a process exit code.
*/
int runGui(
    string title,
    const(char)[] source,
    const(HighlightEvent)[] events,
    LabelSet labels,
    const(string)[] names,
    immutable(Theme)[] themes,
    size_t startIdx,
    PreviewModel preview = PreviewModel.init,
    string fontName = "monospace",
    int fontSize = defaultFontSize,
    int windowWidth = 800,
    int windowHeight = 600,
    bool lineNumbers = true,
    bool codeLineNumbers = true,
    bool ansiCopyStrip = false,          // --ansi-copy=strip (SEL7/CLI10); default raw
    TableCopyFormat tableCopy = TableCopyFormat.tsv, // --table-copy (TBL2/CLI11)
    SourceSet* set = null,               // the document set to navigate (GNV1)
    DocLoader loadDoc = null,            // loads a set entry (supplied by app.d)
) @system
{
    import std.stdio : stderr;
    import std.string : toStringz;
    import std.process : environment;
    import std.conv : to, text;

    // Debug/CI capture: HUE_GUI_SCREENSHOT=<path> renders a few frames, writes a
    // PNG, and exits — the golden-frame harness the syntax spec's totality and
    // M5's byte-identical-render checks rely on (skipTest-gated when headless).
    const shotPath = environment.get("HUE_GUI_SCREENSHOT", "");
    // Debug/CI: HUE_GUI_TOP=<n> sets the initial scroll line (clamped) so a
    // golden capture can exercise the culled viewport; HUE_GUI_FONTSIZE overrides
    // the --font-size for deterministic captures.
    // `--font-size` arrives in points; convert to pixels (96-DPI, 1pt = 1/72in)
    // exactly like apps/terminal so both raylib apps size a font identically.
    int fontSizePx = cast(int)(fontSize * 96.0 / 72.0 + 0.5);
    long initialTop;
    try
    {
        initialTop = environment.get("HUE_GUI_TOP", "0").to!long;
        // HUE_GUI_FONTSIZE stays in pixels so golden captures are deterministic.
        if (environment.get("HUE_GUI_FONTSIZE", null).length)
            fontSizePx = environment.get("HUE_GUI_FONTSIZE").to!int;
    }
    catch (Exception)
    {
    }
    if (fontSizePx < 6)
        fontSizePx = 6;

    // Route raylib's own trace log through sparkles' logger (NFR7) before it
    // opens anything, so its init chatter obeys hue's log level instead of
    // writing to stderr. Its default LOG_INFO threshold still gates what it
    // hands us; everything bridged lands at trace level (silent by default).
    SetTraceLogCallback(&raylibTraceLog);

    InitWindow(800, 600, ("hue — " ~ title).toStringz);
    scope (exit) CloseWindow();
    SetWindowState(ConfigFlags.FLAG_WINDOW_RESIZABLE);
    SetTargetFPS(60);
    SetExitKey(KeyboardKey.KEY_NULL); // arrow/close-button handling only (M3 adds keys)

    // LoadFontEx uploads a GPU texture, so the FontSet must load after InitWindow.
    // `fontName` may be a path, a family, or a fontconfig preference list.
    FontSet fonts;
    if (!FontSet.tryLoad(fontName, fontSizePx, fonts))
    {
        stderr.writeln("hue --gui: could not load a font from '", fontName,
            "' (is fontconfig available?)");
        return 1;
    }
    scope (exit) fonts.unload();

    // `--window-width`/`--window-height` are in cells (like apps/terminal); size
    // the window to the loaded cell metrics.
    if (windowWidth > 0 && windowHeight > 0)
        SetWindowSize(windowWidth * fonts.cellW(), windowHeight * fonts.cellH());

    // The current document. Mutable so a document set can be navigated in place
    // (`GNV1`) — the window, font atlas and grammar cache are reused; only these
    // change. With no set they are simply the arguments, unchanged.
    const(char)[] curSource = source;
    const(HighlightEvent)[] curEvents = events;
    PreviewModel curPreview = preview;
    string curName = title;
    string curSummary = set !is null && !set.empty ? set.current.summary : "";
    size_t srcTotal = lineCount(curSource);

    // Markdown-preview state (M4). A markdown file opens in preview by default;
    // Tab toggles to the raw highlighted-source view. `HUE_GUI_PREVIEW=0/1`
    // pins the initial mode for deterministic golden captures.
    bool showPreview = curPreview.present;
    if (environment.get("HUE_GUI_PREVIEW", "") == "0")
        showPreview = false;
    else if (environment.get("HUE_GUI_PREVIEW", "") == "1")
        showPreview = curPreview.present;
    PreviewLine[] plines;
    TableView[] tables; // per-table screen↔cell maps for 2D selection (TBL); markdown preview only
    int lastWidthCols = -1;
    // Resize debounce: during a drag the column count changes almost every frame,
    // so re-wrap only once the width has held steady for a few frames — the drag
    // pays one relayout when it settles instead of one per frame. Discrete width
    // changes (theme / font size / gutter toggles) relayout immediately, so this
    // branch only ever debounces a live window resize.
    int prevWidthCols = -1;
    int resizeSettle;
    enum resizeSettleFrames = 4; // ~66 ms at 60 FPS
    // The width-independent flattened preview, cached per theme. A resize / font-
    // size change / gutter toggle only re-wraps this (`relayout`), never re-flattens
    // it (`reflatten`) — flattening (inline layout, prose tokenization, code
    // highlighting) is the expensive part and depends only on the model + theme.
    PreviewDoc flatDoc;

    // The live theme state: ←/→ browse `themes`, re-resolving and repainting —
    // the GPU counterpart of hue's terminal Previewer.
    size_t themeIdx = startIdx;
    ResolvedTheme current;
    RgbColor pageFg, pageBg, gutterFg;
    RgbColor[quoteBarCycle] quoteBars;   // per-depth block-quote gutter colors
    RgbColor scrollbarTrack, scrollbarThumb; // link-tinted — distinct from the
    // grayscale structural bands (page / code header / code panel)

    // Line-number gutter width in cells (0 when off) — a stable size from the
    // source line count so toggling wrapping never oscillates the layout.
    int gutterCols() => lineNumbers ? digitCount(srcTotal) + 1 : 0;

    // The right gutter reserved for the scrollbar == its expanded (hover) width,
    // so the expanded handle fills the gutter exactly instead of overlapping text.
    int scrollbarGutter() => cast(int)(fonts.cellW() * 1.5f);

    // Preview columns available for the current window/font: the screen minus the
    // 1-cell left text padding, the scrollbar gutter on the right, and the line-
    // number gutter. Re-laying-out on change keeps wrapping correct.
    int widthCols()
    {
        const cw = fonts.cellW();
        const w = (GetScreenWidth() - cw - scrollbarGutter() - gutterCols() * cw) / cw;
        return w < 8 ? 8 : w;
    }

    // Rebuild the width-independent flattened preview (model + theme dependent).
    // Called on theme change and at startup — NOT on resize.
    void reflatten()
    {
        if (curPreview.present)
            flatDoc = flattenPreview(curPreview, current, pageFg, pageBg);
    }

    // Both views are wrapped visual-line lists (`PreviewLine[]`) so long lines
    // reflow on resize and line numbers track the source (physical) line. The
    // markdown preview re-wraps the cached `flatDoc` (the resize hot path); the raw
    // view wraps the highlighted source directly.
    void relayout()
    {
        lastWidthCols = widthCols();
        if (showPreview && curPreview.present)
        {
            auto wp = wrapPreview(flatDoc, lastWidthCols, codeLineNumbers);
            plines = wp.lines;
            tables = wp.tables;
        }
        else
        {
            plines = buildRawPlines(curSource, curEvents, current, pageFg, pageBg, lastWidthCols);
            tables = null; // the raw view has no table maps
        }
    }

    void applyTheme(size_t i)
    {
        themeIdx = i;
        current = resolveTheme(themes[i], labels);
        pageFg = toRgb(current.defaults.fg, hardFallbackFg);
        pageBg = toRgb(current.defaults.bg, hardFallbackBg);
        gutterFg = mix(pageFg, pageBg, 0.5); // muted line numbers
        quoteBars = quoteBarColors(current, pageFg, pageBg);
        // Scrollbar chrome: tint toward the theme's link color so the hover track
        // and thumb read as a distinct hue against the grayscale bg/code bands.
        const linkC = toRgb(current[current.labels.resolve("markup.link")].fg, pageFg);
        scrollbarTrack = mix(pageBg, linkC, 0.22);
        scrollbarThumb = mix(pageBg, linkC, 0.5);
        SetWindowTitle(text("hue — ", title, " — ", names[i],
            " (", i + 1, "/", names.length, ")").toStringz);
        reflatten(); // theme colors change → re-flatten, then re-wrap
        relayout();  // preview colors follow the theme
    }

    applyTheme(themeIdx);

    auto lineStarts = buildLineStarts(curSource);

    SmallBuffer!(char, 4096) buf; // reused, NUL-terminated for raylib
    long top = initialTop; // index of the first visible line

    // Search / goto state (M4).
    Mode mode = Mode.normal;
    SmallBuffer!(char, 256) query;
    Match[] matches;
    size_t curMatch;

    // The index view (`GAL5`): a directory target opens on the list of documents.
    // A deliberately minimal list — the file-tree explorer (`TVU1`) supersedes it.
    bool indexMode = set !is null && !set.empty && loadDoc !is null;
    long indexTop;

    /// Loads the set's currently-selected document in place (`GNV1`): re-read,
    /// re-highlight, rebuild the preview model, relayout. Scroll and search reset;
    /// the theme and the view toggles persist (`GNV3`). A document that fails to
    /// load is reported and the previous one stays on screen.
    bool loadSelected()
    {
        if (set is null || set.empty || loadDoc is null)
            return false;
        const entry = set.current;
        LoadedDoc doc;
        try
            doc = loadDoc(entry.path);
        catch (Exception ex)
        {
            stderr.writeln("hue: ", entry.path, ": ", ex.msg);
            return false;
        }

        curSource = doc.source;
        curEvents = doc.events;
        curPreview = doc.preview;
        curName = entry.name;
        curSummary = entry.summary;
        srcTotal = lineCount(curSource);
        lineStarts = buildLineStarts(curSource);
        showPreview = curPreview.present;

        top = 0;            // a new document starts at the top (`GNV3`)
        query.clear();
        matches = null;
        curMatch = 0;
        mode = Mode.normal;

        // The flattened preview is width-independent but model+theme dependent, so
        // a new document must re-flatten before the width-only re-wrap.
        reflatten();
        lastWidthCols = -1; // force the re-wrap even at an unchanged width
        relayout();
        SetWindowTitle(("hue — " ~ curName).toStringz);
        return true;
    }

    // Recompute all match ranges for the current query — an extra decoration
    // layer over the styled spans (the pure mapping lives in gui_text).
    void recompute()
    {
        matches = findMatches(curSource, query[], lineStarts);
        curMatch = 0;
    }

    // Lines wrap, so source coordinates must be mapped to visual (`plines`) rows.
    // The first visual row at/after source line `srcLine`.
    long visualOfSrc(size_t srcLine)
    {
        foreach (idx, ref pl; plines)
            if (pl.showNumber && pl.srcLine >= srcLine)
                return cast(long) idx;
        return plines.length ? cast(long) plines.length - 1 : 0;
    }

    // The visual row a match falls on (its source line's wrapped row covering the
    // match column), else that source line's first row.
    long visualOfMatch(in Match m)
    {
        foreach (idx, ref pl; plines)
            if (pl.srcLine == m.line && pl.wrapColOffset <= cast(long) m.col
                && cast(long) m.col < pl.wrapColOffset + lineCols(pl))
                return cast(long) idx;
        return visualOfSrc(m.line);
    }

    // Center the given match in the viewport (as far as clamping allows).
    void jumpToMatch(size_t i, int visibleRows)
    {
        if (matches.length == 0)
            return;
        curMatch = i % matches.length;
        top = visualOfMatch(matches[curMatch]) - visibleRows / 2;
    }

    // Debug/CI: HUE_GUI_SEARCH=<text> preselects a search (highlights + jump to
    // the first match) so a golden capture exercises the match overlay.
    foreach (ch; environment.get("HUE_GUI_SEARCH", ""))
        query ~= ch;
    if (query.length)
    {
        recompute();
        if (matches.length)
            top = visualOfMatch(matches[0]);
    }

    Scrollbar sb;

    // Fullscreen (F11): a manual borderless toggle. raylib's
    // ToggleBorderlessWindowed forces the primary monitor and, on some
    // compositors, drops the window decorations on the way back. Managing the
    // undecorated flag + geometry ourselves restores decorations reliably and
    // keeps the window on its current monitor (on X11; on Wayland the app can't
    // set its own position, so it stays put — never yanked to the primary).
    bool isFullscreen;
    int savedX, savedY, savedW, savedH;

    // Code-block copy button: the fence just copied + the STM6 timeline for
    // the brief "copied" checkmark feedback.
    int copiedFence = -1;
    int copiedTable = -1;
    Timeline copiedFlash;

    // Mouse selection has two regimes (a drag stays in the one it starts in, TBL4):
    //  • text  (SEL): a source byte range [selMin, selMax). Prose/code map a click
    //    char-precisely; an ANSI body line selects its whole fence-body span (SEL6).
    //  • table (TBL): a 2D grid selection inside one table, resolved from anchor +
    //    head cells (from the table map) under Shift/Alt.
    enum Regime { none, text, table }
    Regime regime;
    bool selecting;
    // text regime — anchor/head each a source span (char ⇒ lo==hi; ANSI ⇒ block).
    long anchorLo, anchorHi, headLo, headHi;
    // table regime.
    int selTable = -1;
    GridHit tblAnchor, tblHead;
    bool tblShift, tblAlt;

    // Copy modes (SEL7/TBL2), toggleable at runtime ('y' ANSI, 't' table); a
    // toggle flashes the new mode in the status bar for a moment.
    bool ansiStrip = ansiCopyStrip;
    TableCopyFormat tableFmt = tableCopy;
    string copyModeMsg;
    Timeline toast;

    // The text-regime selection as a source range [selMin, selMax) — the union of
    // the anchor and head spans (a char point is a zero-width span).
    long selMin() => anchorLo < headLo ? anchorLo : headLo;
    long selMax() => anchorHi > headHi ? anchorHi : headHi;

    // Copy the current selection: a text range → `source[min..max]` (SGR-stripped
    // when `ansiStrip`); a table region → TSV / markdown cells (SEL7/TBL2).
    void copySelection()
    {
        if (regime == Regime.text && selMax() > selMin() && selMax() <= source.length)
        {
            auto txt = source[cast(size_t) selMin() .. cast(size_t) selMax()];
            SetClipboardText((ansiStrip ? stripSgr(txt) : txt).toStringz);
        }
        else if (regime == Regime.table && selTable >= 0 && selTable < tables.length)
        {
            const tv = tables[selTable];
            const reg = tableSelection(tblAnchor, tblHead, tblShift, tblAlt,
                tv.map.numRows, tv.map.numCols);
            const txt = serializeTable(reg,
                (size_t r, size_t c) => tv.map.cellText(r, c), tableFmt);
            if (txt.length)
                SetClipboardText(txt.toStringz);
        }
    }

    int frame = 0;
    while (!WindowShouldClose())
    {
        const cellW = fonts.cellW();
        const cellH = fonts.cellH();
        const screenW = GetScreenWidth();
        const screenH = GetScreenHeight();
        const visibleRows = screenH / cellH;

        // The index view (`GAL5`): the document list a directory target opens on.
        // ↑/↓ (j/k) move, Enter/click opens, `i` returns here from a document.
        if (indexMode)
        {
            const rows = set.entries.length;
            if (pressed(KeyboardKey.KEY_DOWN) || pressed(KeyboardKey.KEY_J))
                set.move(1);
            if (pressed(KeyboardKey.KEY_UP) || pressed(KeyboardKey.KEY_K))
                set.move(-1);
            if (IsKeyPressed(KeyboardKey.KEY_HOME))
                set.index = 0;
            if (IsKeyPressed(KeyboardKey.KEY_END) && rows)
                set.index = rows - 1;

            // Keep the selection in view.
            const listRows = visibleRows - 2;
            if (cast(long) set.index < indexTop)
                indexTop = cast(long) set.index;
            if (listRows > 0 && cast(long) set.index >= indexTop + listRows)
                indexTop = cast(long) set.index - listRows + 1;

            const my = GetMouseY();
            const hoveredRow = indexTop + (my - 2 * cellH) / cellH;
            if (IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_LEFT)
                && hoveredRow >= 0 && hoveredRow < cast(long) rows)
            {
                set.index = cast(size_t) hoveredRow;
                if (loadSelected())
                    indexMode = false;
            }
            if (IsKeyPressed(KeyboardKey.KEY_ENTER) || IsKeyPressed(KeyboardKey.KEY_SPACE))
                if (loadSelected())
                    indexMode = false;

            BeginDrawing();
            ClearBackground(rl(pageBg));

            drawText(fonts, cstrOf(buf, text(rows, " documents   ↑↓ move   enter open   q quit")),
                cast(float) cellW, 0, TextStyle(0), rl(gutterFg));

            foreach (r; 0 .. listRows)
            {
                const e = indexTop + r;
                if (e < 0 || e >= cast(long) rows)
                    break;
                const yy = cast(float)((r + 2) * cellH);
                const selected = cast(size_t) e == set.index;
                if (selected)
                    DrawRectangle(0, cast(int) yy, screenW, cellH,
                        rl(mix(pageBg, pageFg, 0.14)));
                drawText(fonts, cstrOf(buf, set.entries[e].name), cast(float) cellW, yy,
                    TextStyle(selected ? TextStyle.bold : 0), rl(pageFg));
                const sx = cast(float)((2 + maxNameCols(set.entries)) * cellW);
                drawText(fonts, cstrOf(buf, set.entries[e].summary), sx, yy,
                    TextStyle(0), rl(gutterFg));
            }

            EndDrawing();
            fonts.flushPending();

            // The index is a capturable frame too, so the QA harness can golden it.
            if (shotPath.length)
            {
                if (++frame == 20)
                    TakeScreenshot(shotPath.toStringz);
                if (frame >= 21)
                    break;
            }

            if (IsKeyPressed(KeyboardKey.KEY_Q) || IsKeyPressed(KeyboardKey.KEY_ESCAPE))
                break;
            continue;
        }

        // Reflow (both views wrap) when the window width in columns changes — but
        // debounced: only once the width has held steady for `resizeSettleFrames`
        // frames, so a drag that sweeps many widths re-wraps once at the end. While
        // the drag is in flight the (slightly stale) wrapped lines keep painting.
        const wc = widthCols();
        if (wc != lastWidthCols)
        {
            resizeSettle = (wc == prevWidthCols) ? resizeSettle + 1 : 0;
            if (resizeSettle >= resizeSettleFrames)
                relayout();
        }
        prevWidthCols = wc;
        const total = plines.length;
        const maxTop = total > visibleRows ? cast(long)(total - visibleRows) : 0;

        // F11 toggles borderless fullscreen on the window's current monitor;
        // active in any input mode. Reflow-on-resize keeps working because the
        // screen size changes.
        if (IsKeyPressed(KeyboardKey.KEY_F11))
        {
            if (!isFullscreen)
            {
                const wp = GetWindowPosition();
                savedX = cast(int) wp.x;
                savedY = cast(int) wp.y;
                savedW = GetScreenWidth();
                savedH = GetScreenHeight();
                const mon = GetCurrentMonitor();
                const mp = GetMonitorPosition(mon);
                SetWindowState(ConfigFlags.FLAG_WINDOW_UNDECORATED);
                SetWindowPosition(cast(int) mp.x, cast(int) mp.y);
                SetWindowSize(GetMonitorWidth(mon), GetMonitorHeight(mon));
                isFullscreen = true;
            }
            else
            {
                ClearWindowState(ConfigFlags.FLAG_WINDOW_UNDECORATED);
                SetWindowSize(savedW, savedH);
                SetWindowPosition(savedX, savedY);
                isFullscreen = false;
            }
        }

        const inputMode = mode != Mode.normal;
        if (inputMode)
        {
            // Typing a search query or a goto-line number.
            for (int c = GetCharPressed(); c > 0; c = GetCharPressed())
            {
                if (c < 32 || c >= 127)
                    continue;
                if (mode == Mode.gotoLine && (c < '0' || c > '9'))
                    continue;
                if (query.length < 255)
                    query ~= cast(char) c;
                if (mode == Mode.search)
                    recompute();
            }
            if (IsKeyPressed(KeyboardKey.KEY_BACKSPACE) && query.length)
            {
                query.popBack();
                if (mode == Mode.search)
                    recompute();
            }
            if (IsKeyPressed(KeyboardKey.KEY_ENTER))
            {
                if (mode == Mode.search)
                {
                    // Jump to the first match whose visual row is at/after the
                    // current top (matches are in source order → visual order), wrap.
                    size_t i;
                    while (i < matches.length && visualOfMatch(matches[i]) < top)
                        ++i;
                    jumpToMatch(i < matches.length ? i : 0, visibleRows);
                }
                else if (query.length) // gotoLine → the source line's visual row
                {
                    try
                    {
                        const n = query[].to!long;
                        top = visualOfSrc(cast(size_t)(n > 0 ? n - 1 : 0));
                    }
                    catch (Exception)
                    {
                    }
                }
                mode = Mode.normal;
            }
            if (IsKeyPressed(KeyboardKey.KEY_ESCAPE))
            {
                mode = Mode.normal;
                query.clear(); // cancelling clears the query (and search highlights)
                matches = null;
            }
        }
        else
        {
            // Normal mode: scroll, theme cycling, font sizing, match nav, and the
            // keys that enter the input modes.
            // Scroll: wheel, ↑/↓ (one line), j/k, PageUp/Down, Home/End.
            top -= cast(long)(GetMouseWheelMove() * 3);
            if (pressed(KeyboardKey.KEY_PAGE_DOWN))
                top += visibleRows;
            if (pressed(KeyboardKey.KEY_PAGE_UP))
                top -= visibleRows;
            if (pressed(KeyboardKey.KEY_J) || pressed(KeyboardKey.KEY_DOWN))
                ++top;
            if (pressed(KeyboardKey.KEY_K) || pressed(KeyboardKey.KEY_UP))
                --top;
            if (pressed(KeyboardKey.KEY_HOME))
                top = 0;
            if (pressed(KeyboardKey.KEY_END))
                top = maxTop;

            // Live theme cycling (← previous, → next, wrapping).
            if (pressed(KeyboardKey.KEY_RIGHT))
                applyTheme(themeIdx + 1 == themes.length ? 0 : themeIdx + 1);
            if (pressed(KeyboardKey.KEY_LEFT))
                applyTheme(themeIdx == 0 ? themes.length - 1 : themeIdx - 1);

            // Font sizing: Ctrl-'=' / Ctrl-'-' (reload faces + re-measure). A
            // discrete keypress, so reflow immediately (the cell size — and thus
            // the column count — changed) rather than waiting out the resize debounce.
            const ctrl = IsKeyDown(KeyboardKey.KEY_LEFT_CONTROL)
                || IsKeyDown(KeyboardKey.KEY_RIGHT_CONTROL);
            if (ctrl && pressed(KeyboardKey.KEY_EQUAL))
            {
                fonts.reload(fonts.size() + 2);
                relayout();
            }
            else if (ctrl && pressed(KeyboardKey.KEY_MINUS) && fonts.size() > 6)
            {
                fonts.reload(fonts.size() - 2);
                relayout();
            }

            // Match navigation: n next, Shift-n previous.
            if (matches.length && pressed(KeyboardKey.KEY_N))
            {
                const shift = IsKeyDown(KeyboardKey.KEY_LEFT_SHIFT)
                    || IsKeyDown(KeyboardKey.KEY_RIGHT_SHIFT);
                jumpToMatch(shift ? curMatch + matches.length - 1 : curMatch + 1, visibleRows);
            }

            // `[` / `]` (and the mouse back/forward buttons) walk the document
            // set; `i` returns to the index view (`GNV1`/`GAL5`).
            if (set !is null && !set.empty && loadDoc !is null)
            {
                const back = IsKeyPressed(KeyboardKey.KEY_LEFT_BRACKET)
                    || IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_BACK);
                const fwd = IsKeyPressed(KeyboardKey.KEY_RIGHT_BRACKET)
                    || IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_FORWARD);
                if ((back || fwd) && set.move(back ? -1 : 1))
                    loadSelected();
                if (IsKeyPressed(KeyboardKey.KEY_I))
                {
                    indexMode = true;
                    continue;
                }
            }

            // Tab toggles markdown preview ↔ raw highlighted source.
            if (curPreview.present && IsKeyPressed(KeyboardKey.KEY_TAB))
            {
                showPreview = !showPreview;
                lastWidthCols = -1; // force a reflow on next frame
                relayout();
            }

            // 'l' toggles the file line-number gutter (changes the wrap width).
            if (pressed(KeyboardKey.KEY_L))
            {
                lineNumbers = !lineNumbers;
                lastWidthCols = -1; // gutter width changed → reflow
                relayout();
            }

            // Ctrl-C copies the current selection to the clipboard; plain 'c'
            // toggles the in-panel code-block line numbers.
            if (ctrl && IsKeyPressed(KeyboardKey.KEY_C))
                copySelection();
            else if (!ctrl && pressed(KeyboardKey.KEY_C))
            {
                codeLineNumbers = !codeLineNumbers;
                lastWidthCols = -1;
                relayout();
            }

            // Copy-mode toggles (SEL7/TBL2): 'y' ANSI raw↔strip, 't' table
            // TSV↔markdown. They only change how a copy renders — no relayout.
            if (pressed(KeyboardKey.KEY_Y))
            {
                ansiStrip = !ansiStrip;
                copyModeMsg = ansiStrip ? "ansi-copy: strip" : "ansi-copy: raw";
                toast = Timeline.triggered(toastCfg);
            }
            if (pressed(KeyboardKey.KEY_T))
            {
                tableFmt = tableFmt == TableCopyFormat.tsv
                    ? TableCopyFormat.markdown : TableCopyFormat.tsv;
                copyModeMsg = tableFmt == TableCopyFormat.tsv
                    ? "table-copy: tsv" : "table-copy: markdown";
                toast = Timeline.triggered(toastCfg);
            }

            // Enter an input mode: '/' search (raw view only), 'g' goto-line.
            if (!showPreview && IsKeyPressed(KeyboardKey.KEY_SLASH))
            {
                mode = Mode.search;
                query.clear();
                matches = null;
            }
            else if (IsKeyPressed(KeyboardKey.KEY_G))
            {
                mode = Mode.gotoLine;
                query.clear();
            }
        }

        // Interactive scrollbar (hover-expand + thumb drag + track click),
        // adapted from apps/terminal's ScrollbarState. Runs every frame so the
        // width animates even while a search is being typed.
        {
            // Both widths scale with the font: the expanded (hover) handle equals
            // the reserved scrollbar gutter (1.5 cells) so it fills the gutter
            // without overlapping text; the idle rail is a thin ~⅓ cell.
            const float hoverW = cast(float) scrollbarGutter();
            const float idleW = cellW / 3.0f < 2.0f ? 2.0f : cellW / 3.0f;
            const float sbMaxW = hoverW;
            if (maxTop > 0)
            {
                const trackH = cast(float) screenH;
                const g = thumbGeometry(total, visibleRows, top, maxTop, screenH);
                const pos = GetMousePosition();
                const hoverTrack = pos.x >= screenW - sbMaxW;
                const hoverThumb = hoverTrack && pos.y >= g.y && pos.y <= g.y + g.h;
                sb.isHovered = hoverTrack || sb.isDragging;
                sb.targetWidth = sb.isHovered ? hoverW : idleW;

                if (IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_LEFT) && hoverTrack)
                {
                    if (hoverThumb)
                    {
                        sb.isDragging = true;
                        sb.dragStartY = pos.y;
                        sb.dragStartOffset = top;
                    }
                    else // click on the track: center the viewport on the click
                        top = cast(long)(pos.y / trackH * total) - visibleRows / 2;
                }
                if (sb.isDragging)
                {
                    if (IsMouseButtonReleased(MouseButton.MOUSE_BUTTON_LEFT))
                        sb.isDragging = false;
                    else if (g.movable > 0)
                        top = sb.dragStartOffset
                            + cast(long)((pos.y - sb.dragStartY) * maxTop / g.movable);
                }
            }
            else
            {
                sb.isHovered = false;
                sb.targetWidth = idleW;
            }
            // Ease the width toward its target (matches the terminal's 15/s rate).
            sb.currentWidth += (sb.targetWidth - sb.currentWidth) * 15.0f * GetFrameTime();
        }

        top = top < 0 ? 0 : (top > maxTop ? maxTop : top);
        const topLine = cast(size_t) top;

        BeginDrawing();
        ClearBackground(rl(pageBg));

        // One-cell background padding on the left, the scrollbar gutter on the
        // right, plus the optional line-number gutter; text starts at `contentX`.
        const padX = cellW;
        const rightPad = scrollbarGutter();
        const gcols = gutterCols();
        const gutterPx = padX + gcols * cellW; // == contentX (text column start)

        // Both views draw through the same wrapped-line painter (bands/leaders are
        // absent from raw lines, so it just paints runs + the line-number gutter).
        drawPreview(fonts, plines, topLine, visibleRows, cellW, cellH,
            pageFg, pageBg, gutterFg, quoteBars, padX, rightPad, gcols, buf);

        copiedFlash = copiedFlash.stepped(frameMs(), copiedCfg);

        bool copyClicked; // a click landing on a copy button is not a selection

        // Copy-to-clipboard button in a code-header row's cutout — and, the same
        // way, a whole-table copy button in a table's top-border cutout. Both sit
        // in the right-side cutout (the middle of the three-space gap, `lineCols-3`,
        // a space on each side) and flip to a checkmark for ~1.2s on click.
        if (showPreview)
        {
            const mp = GetMousePosition();
            foreach (row; 0 .. visibleRows)
            {
                const vi = topLine + row;
                if (vi >= plines.length)
                    break;
                const pl = plines[vi];
                const isCode = pl.band == BandKind.codeHeader && pl.copyFence >= 0;
                const isTable = pl.copyTable >= 0;
                if (!isCode && !isTable)
                    continue;
                const iconX = gutterPx + (runStartCells(pl) + lineCols(pl) - 3) * cellW;
                const iy = row * cellH;
                const hovered = mp.x >= iconX && mp.x < iconX + cellW
                    && mp.y >= iy && mp.y < iy + cellH;
                const clicked = hovered && IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_LEFT);
                bool copied;
                if (isCode)
                {
                    if (clicked && pl.copyFence < cast(int) preview.fences.length)
                    {
                        auto fbody = preview.fences[pl.copyFence].body;
                        // Match the selection copy mode: strip SGR from an ANSI fence.
                        const txt = (ansiStrip && preview.fences[pl.copyFence].isAnsi)
                            ? stripSgr(fbody) : fbody;
                        SetClipboardText(txt.toStringz);
                        copiedFence = pl.copyFence;
                        copiedTable = -1;
                        copiedFlash = Timeline.triggered(copiedCfg);
                        copyClicked = true;
                    }
                    copied = pl.copyFence == copiedFence && copiedFlash.visible;
                }
                else // whole-table copy: the raw markdown source (like the code button)
                {
                    if (clicked && pl.selSrcStart != size_t.max
                        && pl.selSrcEnd <= source.length)
                    {
                        SetClipboardText(source[pl.selSrcStart .. pl.selSrcEnd].toStringz);
                        copiedTable = pl.copyTable;
                        copiedFence = -1;
                        copiedFlash = Timeline.triggered(copiedCfg);
                        copyClicked = true;
                    }
                    copied = pl.copyTable == copiedTable && copiedFlash.visible;
                }
                const icon = copied ? "\U0000F00C" : "\U0000F0C5"; //  /
                const col = copied ? quoteBars[2] : (hovered ? pageFg : gutterFg);
                drawText(fonts, cstrOf(buf, icon), iconX, iy, TextStyle(0), rl(col));
            }
        }

        // Mouse selection (both views). `hitAt` classifies the cursor: over a
        // table → a grid cell (`TBL`); else a source byte span (`SEL`) — a char
        // point for prose/code, or an ANSI body line's whole fence-body span
        // (`SEL6`, block-granular).
        struct Hit { bool ok, table; long lo, hi; int tableIdx; GridHit cell; }
        Hit hitAt(float mx, float my)
        {
            Hit h;
            if (my < 0)
                return h;
            const row = cast(int)(my / cellH);
            if (row < 0 || topLine + row >= plines.length)
                return h;
            const pl = plines[topLine + row];
            const rx = gutterPx + runStartCells(pl) * cellW;
            const x = mx <= rx ? 0 : cast(int)((mx - rx) / cellW);
            // A table line yields both a grid cell (for a drag that STARTS here →
            // the 2D regime) and the table's whole source span (for a text-regime
            // drag that merely CROSSES it, TBL4).
            if (pl.tableIndex >= 0 && pl.tableIndex < tables.length)
            {
                const tv = tables[pl.tableIndex];
                auto gh = tv.map.hit(cast(size_t)((topLine + row) - tv.firstLine), cast(size_t) x);
                if (!gh.isNull)
                {
                    h.table = true;
                    h.tableIdx = pl.tableIndex;
                    h.cell = gh.get;
                    // Char-level source offset for a text-regime drag crossing the
                    // table: the cell's source start + the char within it.
                    h.lo = h.hi = cast(long)(tv.cellSrc[gh.get.row][gh.get.col] + gh.get.charInCell);
                    h.ok = true;
                    return h;
                }
            }
            if (pl.selSrcStart != size_t.max) // table border/gutter → block span (fallback)
            {
                h.lo = cast(long) pl.selSrcStart;
                h.hi = cast(long) pl.selSrcEnd;
                h.ok = true;
                return h;
            }
            const o = srcOffsetAtCol(pl, x);
            if (o >= 0)
            {
                h.ok = true;
                h.lo = o;
                h.hi = o;
            }
            return h;
        }

        {
            const mp = GetMousePosition();
            const overSb = mp.x >= screenW - scrollbarGutter();
            const shiftMod = IsKeyDown(KeyboardKey.KEY_LEFT_SHIFT) || IsKeyDown(KeyboardKey.KEY_RIGHT_SHIFT);
            const altMod = IsKeyDown(KeyboardKey.KEY_LEFT_ALT) || IsKeyDown(KeyboardKey.KEY_RIGHT_ALT);
            if (IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_LEFT) && !overSb && !copyClicked)
            {
                const h = hitAt(mp.x, mp.y);
                selecting = h.ok;
                if (h.table)
                {
                    regime = Regime.table;
                    selTable = h.tableIdx;
                    tblAnchor = tblHead = h.cell;
                    tblShift = tblAlt = false;
                }
                else if (h.ok)
                {
                    regime = Regime.text;
                    anchorLo = headLo = h.lo;
                    anchorHi = headHi = h.hi;
                }
                else
                    regime = Regime.none;
            }
            if (selecting && IsMouseButtonDown(MouseButton.MOUSE_BUTTON_LEFT))
            {
                const h = hitAt(mp.x, mp.y);
                if (regime == Regime.table && h.table && h.tableIdx == selTable)
                {
                    tblHead = h.cell;
                    tblShift = shiftMod;
                    tblAlt = altMod;
                }
                else if (regime == Regime.text && h.ok)
                {
                    // Extend over anything with a source span — including a table
                    // line's block span, so a drag from outside sweeps across it.
                    headLo = h.lo;
                    headHi = h.hi;
                }
            }
            if (IsMouseButtonReleased(MouseButton.MOUSE_BUTTON_LEFT))
                selecting = false;
        }

        // Selection highlight — a translucent tint. `tintRow` takes content columns
        // (0 = the content origin, i.e. after `gutterPx`).
        void tintRow(long screenRow, int xStartCol, int xEndCol)
        {
            if (screenRow < 0 || screenRow >= visibleRows || xEndCol <= xStartCol)
                return;
            DrawRectangle(gutterPx + xStartCol * cellW, cast(int)(screenRow * cellH),
                (xEndCol - xStartCol) * cellW, cellH, alpha(quoteBars[1], 80));
        }
        // A cell/char span from a table map → its on-screen rect (its content
        // columns sit after the table line's own indent/quote gutter).
        void tintTableSpan(in TableView tv, CellSpan sp)
        {
            const startCol = runStartCells(plines[tv.firstLine]);
            tintRow(cast(long)(tv.firstLine + sp.line) - topLine,
                startCol + cast(int) sp.xStart, startCol + cast(int) sp.xEnd);
        }
        if (regime == Regime.text && selMax() > selMin())
        {
            const smin = selMin(), smax = selMax();
            foreach (row; 0 .. visibleRows)
            {
                const vi = topLine + row;
                if (vi >= plines.length)
                    break;
                const pl = plines[vi];
                if (pl.tableIndex >= 0)
                    continue; // tables tinted per-cell below
                const startCol = runStartCells(pl);
                int c;
                foreach (r; pl.runs)
                {
                    const rc = cast(int) columnWidth(r.text);
                    if (r.srcStart != size_t.max)
                    {
                        const rStart = cast(long) r.srcStart;
                        const rEnd = rStart + cast(long) r.text.length;
                        if (rEnd > smin && rStart < smax)
                        {
                            const bStart = (smin > rStart ? smin : rStart) - rStart;
                            const bEnd = (smax < rEnd ? smax : rEnd) - rStart;
                            const colStart = cast(int) columnWidth(r.text[0 .. bStart]);
                            const colEnd = cast(int) columnWidth(r.text[0 .. bEnd]);
                            tintRow(row, startCol + c + colStart, startCol + c + colEnd);
                        }
                    }
                    c += rc;
                }
            }
            // Tables the text selection crosses: tint the covered part of each
            // cell — character-precise (clip to [smin, smax) within the cell), so
            // a selection ending mid-cell highlights only up to that character.
            foreach (ref tv; tables)
                foreach (rr; 0 .. tv.map.numRows)
                    foreach (cc; 0 .. tv.map.numCols)
                    {
                        const cLo = cast(long) tv.cellSrc[rr][cc];
                        const cHi = cLo + cast(long) tv.map.cellText(rr, cc).length;
                        if (cHi <= smin || cLo >= smax)
                            continue;
                        const lo = cast(size_t)((smin > cLo ? smin : cLo) - cLo);
                        const hi = cast(size_t)((smax < cHi ? smax : cHi) - cLo);
                        foreach (sp; tv.map.charSpans(rr, cc, lo, hi))
                            tintTableSpan(tv, sp);
                    }
        }
        else if (regime == Regime.table && selTable >= 0 && selTable < tables.length)
        {
            const tv = tables[selTable];
            const reg = tableSelection(tblAnchor, tblHead, tblShift, tblAlt,
                tv.map.numRows, tv.map.numCols);
            if (reg.subCell)
                foreach (sp; tv.map.charSpans(reg.row, reg.col, reg.charLo, reg.charHi))
                    tintTableSpan(tv, sp);
            else
                foreach (rr; reg.rowLo .. reg.rowHi + 1)
                    foreach (cc; reg.colLo .. reg.colHi + 1)
                        foreach (sp; tv.map.cellSpans(rr, cc))
                            tintTableSpan(tv, sp);
        }

        // Search-match overlay (raw view only): translucent tint over each visible
        // match, remapped onto the wrapped visual line via each line's srcLine +
        // wrapColOffset (the current match brighter).
        if (!showPreview)
            foreach (i, m; matches)
                foreach (row; 0 .. visibleRows)
                {
                    const vi = topLine + row;
                    if (vi >= plines.length)
                        break;
                    const pl = plines[vi];
                    const off = pl.wrapColOffset;
                    const rowCols = lineCols(pl);
                    if (pl.srcLine != m.line || cast(long) m.col < off
                        || cast(long) m.col >= off + rowCols)
                        continue;
                    const vc = cast(int) m.col - off;
                    const remain = off + rowCols - cast(int) m.col;
                    const cols = cast(int) m.cols < remain ? cast(int) m.cols : remain;
                    DrawRectangle(gutterPx + vc * cellW, cast(int)(row * cellH),
                        cols * cellW, cellH, i == curMatch ? currentMatchTint : matchTint);
                    break; // the match starts on this visual row
                }

        // Scrollbar: an animated-width thumb, plus a faint track while hovered
        // or dragging. Colors follow the theme's muted gutter tone.
        if (maxTop > 0)
        {
            const g = thumbGeometry(total, visibleRows, top, maxTop, screenH);
            const w = sb.currentWidth;
            const x = screenW - w;
            // Distinct link-tinted chrome (the gutter behind it is empty page bg):
            // a subtle full-height track on hover, a brighter thumb on top.
            if (sb.isHovered || sb.isDragging)
                DrawRectangle(cast(int) x, 0, cast(int) w, screenH, rl(scrollbarTrack));
            DrawRectangle(cast(int) x, cast(int) g.y, cast(int) w, cast(int) g.h,
                rl(scrollbarThumb));
        }

        // A header bar when navigating a document set (`GNV2`): the entry name and
        // summary on the left, the set position + keys on the right. Drawn over the
        // top row so scrolled content passes under it.
        if (set !is null && !set.empty && loadDoc !is null)
        {
            DrawRectangle(0, 0, screenW, cellH, rl(mix(pageBg, pageFg, 0.12)));
            DrawRectangle(0, cellH - 1, screenW, 1, rl(gutterFg));
            const left = curSummary.length ? curName ~ "  " ~ curSummary : curName;
            drawText(fonts, cstrOf(buf, left), cast(float) cellW, 0, TextStyle(0), rl(pageFg));
            const pos = text(set.index + 1, "/", set.length, "   [ ] prev/next   i index");
            const px = cast(float)(screenW - cast(int)((pos.length + 1) * cellW));
            drawText(fonts, cstrOf(buf, pos), px, 0, TextStyle(0), rl(gutterFg));
        }

        // Input line at the bottom: '/query' while searching, ':n' while going
        // to a line. Shows a match count for searches.
        if (inputMode)
        {
            const barY = screenH - cellH;
            DrawRectangle(0, barY, screenW, cellH, rl(gutterFg));
            auto lineText = mode == Mode.search
                ? text("/", query[], "   ", matches.length, " matches")
                : text(":", query[]);
            drawText(fonts, cstrOf(buf, lineText), 4, cast(float) barY, TextStyle(0), rl(pageBg));
        }
        // Copy-mode toast (when not typing): flashes the mode after a 'y'/'t' toggle.
        else if (toast.visible)
        {
            toast = toast.stepped(frameMs(), toastCfg);
            const barY = screenH - cellH;
            DrawRectangle(0, barY, screenW, cellH, rl(gutterFg));
            drawText(fonts, cstrOf(buf, copyModeMsg), 4, cast(float) barY, TextStyle(0), rl(pageBg));
        }

        EndDrawing();

        // On-demand atlas growth: drawText requests any covered-but-unrasterized
        // codepoints (emoji, CJK, higher-plane icons) as it draws; grow the atlas
        // after EndDrawing so the reupload never lands mid-frame.
        fonts.flushPending();

        if (shotPath.length)
        {
            // Warm up for a number of frames before capturing: the glyph atlas
            // uploads over the first frames, and under a headless GL context the
            // framebuffer swap lags the draw, so an early TakeScreenshot grabs a
            // black frame. ~20 frames is reliably past both.
            if (++frame == 20)
                TakeScreenshot(shotPath.toStringz);
            if (frame >= 21)
                break;
        }
    }

    return 0;
}

/// Paint the markdown preview: `plines` index-culled to the viewport. Each line
/// draws its full-width band, then `quoteDepth` gutter bars, its muted `leader`
/// (bullet/marker), and its styled runs (per-run background + `drawText`). The
/// gutter/scrollbar/search of the raw view are intentionally absent (glow-like).
private void drawPreview(
    ref FontSet fonts,
    const(PreviewLine)[] plines,
    size_t topLine,
    int visibleRows,
    int cellW,
    int cellH,
    RgbColor pageFg,
    RgbColor pageBg,
    RgbColor gutterFg,
    const RgbColor[quoteBarCycle] quoteBars,
    int padX,
    int rightPad,
    int gutterCols,
    ref SmallBuffer!(char, 4096) buf,
) @system
{
    const screenW = GetScreenWidth();
    // Content starts after the 1-cell left padding and the line-number gutter;
    // bands span from there to the scrollbar gutter on the right.
    const originX = padX + gutterCols * cellW;
    const bandW = (screenW - rightPad) - originX;
    foreach (row; 0 .. visibleRows)
    {
        const li = topLine + row;
        if (li >= plines.length)
            break;
        const pl = plines[li];
        const y = row * cast(float) cellH;

        // Band behind the line (code panel / header / table / heading), inset to
        // the padded content column so the padding stays page-background.
        if (pl.band != BandKind.none && pl.band != BandKind.rule)
            DrawRectangle(originX, cast(int) y, bandW, cellH, rl(pl.bandBg));

        // Source (physical) line number in the gutter, right-aligned — only on the
        // first visual row of a wrapped physical line.
        if (gutterCols > 0 && pl.showNumber)
        {
            const s = cstrOf(buf, uintToBuf(pl.srcLine + 1));
            drawText(fonts, s, originX - (s.length + 1) * cast(float) cellW, y,
                TextStyle(0), rl(gutterFg));
        }

        // Quote gutter: one `│` bar per depth (2 cols each). A callout paints
        // every bar in its accent (`barFg`); otherwise each depth takes its color
        // from the theme-derived cycle.
        foreach (d; 0 .. pl.quoteDepth)
        {
            const barColor = pl.hasBarFg ? pl.barFg : quoteBars[d % quoteBarCycle];
            drawText(fonts, cstrOf(buf, "│"), originX + d * 2 * cast(float) cellW, y,
                TextStyle(0), rl(barColor));
        }

        const contentCol = pl.quoteDepth * 2 + pl.indentCols;
        float x = originX + contentCol * cast(float) cellW;

        // Leader (bullet / number / checkbox / heading marker) — colored when the
        // layouter gave it an accent (heading icon, checked box, callout icon).
        if (pl.leader.length)
        {
            const lfg = pl.hasLeaderFg ? pl.leaderFg : gutterFg;
            drawText(fonts, cstrOf(buf, pl.leader), x, y, TextStyle(0), rl(lfg));
            x += columnWidth(pl.leader) * cellW;
        }

        // Styled runs.
        foreach (r; pl.runs)
        {
            if (r.text.length == 0)
                continue;
            const wpx = cast(int)(columnWidth(r.text) * cellW);
            if (r.hasBg)
                DrawRectangle(cast(int) x, cast(int) y, wpx, cellH, rl(r.bg));
            drawText(fonts, cstrOf(buf, r.text), x, y, mapAttrs(r.attrs), rl(r.fg));
            x += wpx;
        }
    }
}

/// Maps `gui_ansi.Attr` bits (used by the preview model) onto raylib-text's
/// `TextStyle` — the preview counterpart of `mapStyle`.
private TextStyle mapAttrs(ubyte attrs) pure nothrow @nogc @safe
{
    TextStyle t;
    if (attrs & Attr.bold)
        t.bits |= TextStyle.bold;
    if (attrs & Attr.italic)
        t.bits |= TextStyle.italic;
    if (attrs & Attr.underline)
        t.bits |= TextStyle.underline;
    if (attrs & Attr.strikethrough)
        t.bits |= TextStyle.strikethrough;
    return t;
}

/// Animated, draggable scrollbar state (mirrors apps/terminal's ScrollbarState):
/// `currentWidth` eases toward `targetWidth` (4 idle → 12 on hover/drag); a drag
/// records the grab point so the thumb tracks the cursor.
private struct Scrollbar
{
    float currentWidth = 4.0f;
    float targetWidth = 4.0f;
    bool isHovered;
    bool isDragging;
    float dragStartY = 0.0f;
    long dragStartOffset = 0;
}

/// The scrollbar thumb's vertical geometry for the current viewport.
private struct ThumbGeometry
{
    float y;       /// thumb top (px)
    float h;       /// thumb height (px, min 24)
    float movable; /// track travel available to the thumb (px)
}

/// ditto — the one STM2 formula (the TUI renders the same geometry), with the
/// GUI's 24 px grabbable minimum; the float fields only carry the animation.
private ThumbGeometry thumbGeometry(size_t total, int visibleRows, long top,
    long maxTop, int screenH) pure nothrow @nogc @safe
{
    const g = scrollbarThumb(total, visibleRows, top, screenH, minExtent: 24);
    return ThumbGeometry(g.start, g.extent, screenH - g.extent);
}

/// An RGB triple as a raylib color with an explicit alpha (for overlays).
private Color alpha(RgbColor c, ubyte a) pure nothrow @nogc @trusted
    => Color(c.r, c.g, c.b, a);

/// The margin left of the code column, in cells (breathing room for decorations).
private enum twoslashPadCells = 1;

/**
`hue --gui --twoslash`: the raylib overlay backend. Draws the highlighted
snippet, then the twoslash decorations on top — highlight spans as translucent
tint boxes, error spans as a wavy underline, and the below-line blocks
(error / query / completion / tag) as annotation rows interleaved between the
code lines. Hover popups (with the re-highlighted type signature) appear on
mouse-over, the GPU counterpart of the HTML `:hover` popup.

`theme` is already resolved and `cache` drives the reentrant popup highlight;
unlike `runGui` this view does not cycle themes (a twoslash payload is a fixed
annotated snippet, not a theme browser).
*/
int runGuiTwoslash(
    string title,
    in TwoslashReturn tw,
    const(HighlightEvent)[] events,
    LabelSet labels,
    in ResolvedTheme theme,
    ref TsConfigCache cache,
    SourceSet* set = null,
    bool lineNumbers = true,
) @system
{
    import std.stdio : stderr;
    import std.string : toStringz;
    import std.process : environment;
    import std.conv : text, to;

    const shotPath = environment.get("HUE_GUI_SCREENSHOT", "");
    int fontSize = defaultFontSize;
    try
        fontSize = environment.get("HUE_GUI_FONTSIZE", null).length
            ? environment.get("HUE_GUI_FONTSIZE").to!int : defaultFontSize;
    catch (Exception)
    {
    }
    // Golden-capture hook: force the Nth hover popup open (no live mouse needed).
    int forceHover = -1;
    try
        forceHover = environment.get("HUE_GUI_HOVER", null).length
            ? environment.get("HUE_GUI_HOVER").to!int : -1;
    catch (Exception)
    {
    }

    InitWindow(900, 640, ("hue twoslash — " ~ title).toStringz);
    scope (exit) CloseWindow();
    SetWindowState(ConfigFlags.FLAG_WINDOW_RESIZABLE);
    SetTargetFPS(60);
    SetExitKey(KeyboardKey.KEY_ESCAPE);

    FontSet fonts;
    if (!FontSet.tryLoad("monospace", fontSize, fonts))
    {
        stderr.writeln("hue --gui: could not load a monospace font (is fontconfig available?)");
        return 1;
    }
    scope (exit) fonts.unload();

    const pageFg = toRgb(theme.defaults.fg, hardFallbackFg);
    const pageBg = toRgb(theme.defaults.bg, hardFallbackBg);

    // Twoslash brand colors from the single-source palette (retiring the four
    // hand-copied literals). error/warn/tag are theme-independent; the highlight
    // tint is a translucent background. The popup surface stays theme-derived
    // (pageBg), so a dark GUI theme isn't forced onto the light CSS surface.
    const pal = defaultTwoslashPalette(schemeForBackground(pageBg));
    const errVis = resolveSlot(pal, Slot.error, pageFg, pageBg);
    const warnVis = resolveSlot(pal, Slot.warn, pageFg, pageBg);
    const highlightVis = resolveSlot(pal, Slot.highlight, pageFg, pageBg);

    // The current document. A pointer-to-const so navigating a set can rebind it
    // (`Node[]` is mutable, so a const payload cannot be copied into a mutable
    // local — the same constraint `TwoslashTui` hit).
    const(TwoslashReturn)* cur = &tw;
    const(HighlightEvent)[] curEvents = events;
    string curName = title;
    string curSummary = set !is null && !set.empty ? set.current.summary : "";

    auto plan = planTwoslash(*cur);
    // Per-line styled runs, bucketed for a top-to-bottom draw with annotation
    // rows interleaved (so `y` cannot be `line * cellH` — it accumulates).
    size_t lineTotal;
    StyledRun[][] runsByLine;

    void rebuild()
    {
        plan = planTwoslash(*cur);
        lineTotal = lineCount(cur.code) + 1;
        runsByLine = new StyledRun[][](lineTotal);
        foreach (ls; byStyledLine(cur.code, curEvents))
            runsByLine[ls.line] ~= StyledRun(ls.span.start, ls.span.end, ls.span.label);
    }

    rebuild();

    SmallBuffer!(char, 4096) buf;
    float scrollY = 0;
    int shotFrame = 0;

    /// Loads the set's currently-selected payload in place (`GNV1`): re-read,
    /// re-highlight, re-plan. The window, font atlas and grammar cache are reused —
    /// only the document changes. A payload that fails to load is reported and the
    /// previous one stays on screen.
    bool loadSelected()
    {
        if (set is null || set.empty)
            return false;
        const entry = set.current;
        auto res = loadTwoslashFile(entry.path);
        if (res.hasError)
        {
            stderr.writeln("hue: ", res.error.msg);
            return false;
        }
        auto owned = new TwoslashReturn;
        *owned = res.value;

        SmallBuffer!HighlightEvent ev;
        if (highlightInjected(cache, "typescript", owned.code, ev).hasError)
            ev ~= HighlightEvent.sourceSpan(0, owned.code.length);

        cur = owned;
        curEvents = ev[].dup;
        curName = entry.name;
        curSummary = entry.summary;
        rebuild();
        scrollY = 0; // a new document starts at the top (`GNV3`)
        SetWindowTitle(("hue twoslash — " ~ curName).toStringz);
        return true;
    }

    // Hover latch, persisted across frames: the open popup's node (+1; 0 = none),
    // its on-screen rect (for pointer hysteresis — the popup stays open while the
    // pointer is over token-or-popup), and the hovered-token underline fade (0..1
    // over 0.3s, matching the CSS `.twoslash-hover` `border-color 0.3s` affordance).
    size_t hotNode = 0;
    Rectangle hotPopup;
    bool havePopup = false;
    Timeline fade;

    while (!WindowShouldClose())
    {
        const cellW = fonts.cellW();
        const cellH = fonts.cellH();

        // `[` / `]` (and the mouse back/forward buttons) walk the document set —
        // the reload primitive navigation (`LNK3`/`LNK4`) will reuse (`GNV1`).
        if (set !is null && !set.empty)
        {
            const back = IsKeyPressed(KeyboardKey.KEY_LEFT_BRACKET)
                || IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_BACK);
            const fwd = IsKeyPressed(KeyboardKey.KEY_RIGHT_BRACKET)
                || IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_FORWARD);
            if ((back || fwd) && set.move(back ? -1 : 1))
                loadSelected();
        }

        // A header bar (name · summary · i/n) when navigating a set (`GNV2`), and
        // the physical-line gutter (`GNV4`) — both shift the code's origin.
        const headerH = set !is null && !set.empty ? cast(float) cellH : 0.0f;
        const gutterCols = lineNumbers ? cast(int)(digitCount(lineTotal - 1) + 1) : 0;
        const padPx = cast(float)((twoslashPadCells + gutterCols) * cellW);
        scrollY -= GetMouseWheelMove() * 3 * cellH;
        if (scrollY < 0)
            scrollY = 0;

        // The sparkles:ui raylib backend — cell-space primitives (highlight
        // fill, error squiggle, below-line rows) route through it; its origin is
        // moved per use to the current row's screen position.
        auto canvas = RaylibCanvas(&fonts, &buf, cellW, cellH);

        BeginDrawing();
        ClearBackground(rl(pageBg));

        // Hover token rects captured this frame for the mouse hit-test.
        HoverHit[] hovers;

        float y = headerH - scrollY;
        foreach (line; 0 .. lineTotal)
        {
            // The physical source-line number, right-aligned in the gutter and
            // muted — the same rule the raw view uses (`NUM1`), so the GUI, the
            // TUI and the HTML gallery number lines alike (`GNV4`).
            if (gutterCols > 0 && y >= headerH - cellH && y < GetScreenHeight())
            {
                const numText = text(line + 1);
                const nx = padPx - cast(float)((numText.length + 1) * cellW);
                drawText(fonts, cstrOf(buf, numText), nx, y, TextStyle(0),
                    rl(mix(pageFg, pageBg, 0.5)));
            }

            // Code runs for this line.
            float x = padPx;
            foreach (ref const r; runsByLine[line])
            {
                const run = cur.code[r.start .. r.end];
                if (run.length == 0)
                    continue;
                const spec = theme[r.label];
                const wpx = cast(int)(columnWidth(run) * cellW);
                if (spec.bg.isSet)
                    DrawRectangle(cast(int) x, cast(int) y, wpx, cellH, rl(toRgb(spec.bg, pageBg)));
                drawText(fonts, cstrOf(buf, run), x, y, mapStyle(spec), rl(toRgb(spec.fg, pageFg)));
                x += wpx;
            }

            // Inline decorations on this line.
            foreach (ref const d; plan.inlineDecorations)
            {
                if (d.line != line)
                    continue;
                const dx = cast(int)(padPx + d.character * cellW);
                const dcols = cast(int) columnWidth(cur.code[d.start .. d.end]);
                canvas.originX = padPx;
                canvas.originY = y;
                final switch (d.kind)
                {
                    case NodeType.highlight:
                        canvas.fillRect(Rect(cast(int) d.character, 0, dcols, 1), highlightVis);
                        break;
                    case NodeType.error:
                        canvas.line(Point(cast(int) d.character, 0),
                            Point(cast(int) d.character + dcols, 0), errVis, LineStyle.wavy);
                        break;
                    case NodeType.hover:
                        hovers ~= HoverHit(dx, cast(int) y, dcols * cellW, cellH, d.node);
                        break;
                    case NodeType.query:
                    case NodeType.completion:
                    case NodeType.tag:
                        break;
                }
            }
            y += cellH;

            // Below-line meta blocks, from the shared `viewBelowBlock` widget view
            // (caret + message / ^? / completion list / @tag chip), so the GUI grows
            // the same chrome as the TUI/HTML. Each block is multiple rows.
            foreach (ref const b; plan.belowBlocks)
            {
                if (b.line != line)
                    continue;
                y += drawBelowBlock(fonts, buf, *cur, b.node, padPx, y, cellW, cellH,
                    theme, cache, pal, pageFg, pageBg) * cellH;
            }
        }

        // Hover: latch the token under the pointer — or keep the open popup while
        // the pointer is over IT (hysteresis, so you can move down into the popup)
        // — fade in the token's dotted underline, and draw the popup last (on top).
        // HUE_GUI_HOVER=<index> force-shows the Nth popup (golden captures).
        const mouse = GetMousePosition();
        size_t overNode = 0;
        foreach (ref const h; hovers)
            if (mouse.x >= h.x && mouse.x <= h.x + h.w
                    && mouse.y >= h.y && mouse.y <= h.y + h.h)
                overNode = h.node + 1;
        if (overNode == 0 && hotNode != 0 && havePopup
                && mouse.x >= hotPopup.x && mouse.x <= hotPopup.x + hotPopup.width
                && mouse.y >= hotPopup.y && mouse.y <= hotPopup.y + hotPopup.height)
            overNode = hotNode; // still over the open popup → keep it open
        bool forced = false;
        if (forceHover >= 0 && forceHover < cast(int) hovers.length)
        {
            overNode = hovers[forceHover].node + 1;
            forced = true;
        }

        // Advance the underline fade while the same token stays hot; reset on change.
        if (overNode != hotNode)
            fade = Timeline.init;
        hotNode = overNode;
        if (hotNode != 0)
        {
            if (!fade.visible)
                fade = Timeline.triggered(fadeCfg);
            fade = forced ? Timeline(Timeline.Phase.hold, 0)
                : fade.stepped(frameMs(), fadeCfg);
        }

        havePopup = false;
        if (hotNode != 0)
            foreach (ref const h; hovers)
                if (h.node + 1 == hotNode)
                {
                    // The hovered token's dotted underline (currentColor), faded in.
                    const uy = h.y + h.h - 2;
                    const uc = Color(pageFg.r, pageFg.g, pageFg.b, cast(ubyte)(fade.alphaPercent(fadeCfg) * 255 / 100));
                    for (int i = 0; i + 2 <= h.w; i += 4)
                        DrawRectangle(h.x + i, uy, 2, 1, uc);
                    // The popup on top; remember its rect for next-frame hysteresis.
                    hotPopup = drawPopup(fonts, buf, *cur, h.node,
                        cast(float) h.x, cast(float)(h.y + h.h),
                        cellW, cellH, theme, cache, pal, pageFg, pageBg);
                    havePopup = true;
                    break;
                }

        // The header bar last, so scrolled code passes UNDER it (`GNV2`):
        // `name · summary` on the left, the set position on the right.
        if (headerH > 0)
        {
            const w = GetScreenWidth();
            DrawRectangle(0, 0, w, cast(int) headerH, rl(mix(pageBg, pageFg, 0.12)));
            DrawRectangle(0, cast(int) headerH - 1, w, 1, rl(mix(pageFg, pageBg, 0.5)));

            const left = curSummary.length ? curName ~ "  " ~ curSummary : curName;
            drawText(fonts, cstrOf(buf, left), cast(float) cellW, 0,
                TextStyle(0), rl(pageFg));

            const pos = text(set.index + 1, "/", set.length, "   [ ] prev/next");
            const px = cast(float)(w - cast(int)((pos.length + 1) * cellW));
            drawText(fonts, cstrOf(buf, pos), px, 0, TextStyle(0), rl(mix(pageFg, pageBg, 0.5)));
        }

        EndDrawing();

        if (shotPath.length)
        {
            // Warm up ~20 frames before capturing (the glyph atlas uploads over
            // the first frames and a headless GL swap lags the draw — see runGui).
            if (++shotFrame == 20)
                TakeScreenshot(shotPath.toStringz);
            if (shotFrame >= 21)
                break;
        }
    }
    return 0;
}

/// A styled run within one line (byte offsets into the whole source).
private struct StyledRun
{
    size_t start, end;
    LabelId label;
}

/// A hover token's on-screen rect + its node index, for the mouse hit-test.
private struct HoverHit
{
    int x, y, w, h;
    size_t node;
}

/// Draws styled text `text` (highlighted into `ev`) run-by-run starting at
/// `(x, y)`; returns the ending pen x. Used for popup / query type signatures.
private float drawStyledRuns(ref FontSet fonts, ref SmallBuffer!(char, 4096) buf,
    scope const(char)[] text, const(HighlightEvent)[] ev, float x, float y,
    in ResolvedTheme theme, RgbColor fallbackFg) @system
{
    const cellW = fonts.cellW();
    float cx = x;
    foreach (sp; byStyledSpan(ev))
    {
        const run = text[sp.start .. sp.end];
        if (run.length == 0)
            continue;
        const spec = theme[sp.label];
        drawText(fonts, cstrOf(buf, run), cx, y, mapStyle(spec), rl(toRgb(spec.fg, fallbackFg)));
        cx += columnWidth(run) * cellW;
    }
    return cx;
}

/// One below-line meta block (error / query / completion / tag), built from the
/// shared `viewBelowBlock` widget view and painted at `(padPx, y)` through
/// `RaylibCanvas`; returns its height in rows so the caller advances `y`. A query's
/// type signature is a single `Slot.code` run in the widget model, so it is
/// overpainted with the per-token re-highlighted signature (the painter's job).
private int drawBelowBlock(ref FontSet fonts, ref SmallBuffer!(char, 4096) buf,
    in TwoslashReturn tw, size_t nodeIndex, float padPx, float y, int cellW, int cellH,
    in ResolvedTheme theme, ref TsConfigCache cache, in Palette pal,
    RgbColor pageFg, RgbColor pageBg) @system
{
    import sparkles.twoslash.render_widgets : viewBelowBlock;

    const node = tw.nodes[nodeIndex];
    auto tree = viewBelowBlock(tw, nodeIndex);
    auto frames = layout(tree);
    auto ops = buildDisplayList(tree, frames, pal, pageFg, pageBg);

    auto canvas = RaylibCanvas(&fonts, &buf, cellW, cellH, padPx, y);
    paint(canvas, ops);

    // Re-highlight the query signature (its `Slot.code` run), clearing to the page
    // background first so the flat widget glyphs don't double-strike.
    if (node.type == NodeType.query)
        foreach (ref op; ops)
            if (op.kind == OpKind.textRun && op.slot == Slot.code)
            {
                const sx = padPx + op.rect.x * cellW;
                const sy = y + op.rect.y * cellH;
                DrawRectangle(cast(int) sx, cast(int) sy, op.rect.width * cellW, cellH, rl(pageBg));
                SmallBuffer!HighlightEvent sig;
                highlightSignature(cache, node.text, sig);
                drawStyledRuns(fonts, buf, node.text, sig[], sx, sy, theme, pageFg);
                break;
            }

    return frames[tree.root].rect.height;
}

/// The floating hover popup: a bordered box with the re-highlighted type
/// signature and (if present) the docs, anchored at `(x, y)`.
/// The floating hover popup, built from the shared `viewHoverPopup` widget view
/// (surface panel + docs + `@param` chips — the same chrome as the TUI/HTML) and
/// painted through `RaylibCanvas`. The type signature (row 0) is a single
/// `Slot.code` run in the widget model, so it is overpainted with the per-token
/// re-highlighted signature — the one thing the widget model leaves to the painter.
private Rectangle drawPopup(ref FontSet fonts, ref SmallBuffer!(char, 4096) buf,
    in TwoslashReturn tw, size_t nodeIndex, float x, float y, int cellW, int cellH,
    in ResolvedTheme theme, ref TsConfigCache cache, in Palette pal,
    RgbColor pageFg, RgbColor pageBg) @system
{
    // Render JSDoc docs as markdown (bold/italic/code/links/lists/fences), via the
    // grammar registry — falls back to plain lines without it.
    auto tree = viewHoverPopup(tw, nodeIndex, cache.registry);
    auto frames = layout(tree);
    auto ops = buildDisplayList(tree, frames, pal, pageFg, pageBg);

    auto canvas = RaylibCanvas(&fonts, &buf, cellW, cellH, x, y);
    paint(canvas, ops);

    // Overpaint the signature row with the re-highlighted signature (same text
    // and cell position the widget reserved), clearing its `Slot.code` glyphs
    // back to the surface first so nothing double-strikes.
    const sigText = withoutQuickinfoPrefix(tw.nodes[nodeIndex].text);
    const surf = resolveSlot(pal, Slot.surface, pageFg, pageBg);
    foreach (ref op; ops)
        if (op.kind == OpKind.textRun)
        {
            const sx = x + op.rect.x * cellW;
            const sy = y + op.rect.y * cellH;
            DrawRectangle(cast(int) sx, cast(int) sy, op.rect.width * cellW, cellH, rlBg(surf));
            SmallBuffer!HighlightEvent sig;
            highlightSignature(cache, sigText, sig);
            drawStyledRuns(fonts, buf, sigText, sig[], sx, sy, theme, pageFg);
            break;
        }

    // The popup's on-screen rect (px), for the caller's pointer hysteresis.
    const box = frames[tree.root].rect;
    return Rectangle(x, y, cast(float)(box.width * cellW), cast(float)(box.height * cellH));
}


/// The widest entry name in cells — the index view's summary column offset.
private size_t maxNameCols(scope const SourceEntry[] entries) @safe pure nothrow
{
    size_t w;
    foreach (ref const e; entries)
        if (e.name.length > w)
            w = e.name.length;
    return w;
}

/// `IsKeyPressed` plus auto-repeat while held, so PageDown/j/k etc. repeat.
private bool pressed(int key) @system
    => IsKeyPressed(key) || IsKeyPressedRepeat(key);

// Transient-effect configs (STM6): the copy-✔ flash, the copy-mode toast, and
// the hover-underline fade — one Timeline machine, three configurations. The
// TUI runs the same machine with `holdUntilDismissed` (no frame clock).
private enum copiedCfg = Timeline.Config(holdMs: 1200);
private enum toastCfg = Timeline.Config(holdMs: 1600);
private enum fadeCfg = Timeline.Config(fadeInMs: 300, holdUntilDismissed: true);

/// This frame's duration in Timeline milliseconds.
private int frameMs() @system => cast(int)(GetFrameTime() * 1000);

/// Decimal digit count (at least 1, for 0).
private int digitCount(size_t n) pure nothrow @nogc @safe
{
    int d = 1;
    while (n >= 10)
    {
        n /= 10;
        ++d;
    }
    return d;
}

/// Formats `v` into a thread-local buffer as decimal digits (no allocation).
private char[] uintToBuf(size_t v) @safe nothrow
{
    static char[20] buf;
    if (v == 0)
    {
        buf[0] = '0';
        return buf[0 .. 1];
    }
    size_t i = buf.length;
    while (v)
    {
        buf[--i] = cast(char)('0' + v % 10);
        v /= 10;
    }
    return buf[i .. $];
}

/// Copies `s` into `buf` with a trailing NUL, returning the NUL-terminated
/// slice (excluding the NUL) that raylib's `DrawTextEx` can read directly.
private const(char)[] cstrOf(ref SmallBuffer!(char, 4096) buf, scope const(char)[] s) @safe
{
    buf.clear();
    buf ~= s;
    buf ~= '\0';
    return buf[][0 .. $ - 1];
}

/// Translates sparkles:syntax's backend-neutral `TermStyle` attributes into the
/// renderer's `TextStyle`. On the shaped `TermStyle`, underline is a first-class
/// `UnderlineStyle` field (bit-3 of `attrs` is strikethrough). The terminal will
/// translate `GhosttyStyle` the same way onto the shared library type in M5.
TextStyle mapStyle(in StyleSpec spec) pure nothrow @nogc @safe
{
    TextStyle t;
    if (spec.attrs.has(TextAttr.bold))
        t.bits |= TextStyle.bold;
    if (spec.attrs.has(TextAttr.italic))
        t.bits |= TextStyle.italic;
    if (spec.attrs.has(TextAttr.strikethrough))
        t.bits |= TextStyle.strikethrough;
    if (spec.underline != UnderlineStyle.none)
        t.bits |= TextStyle.underline;
    return t;
}

/// Total display columns of a wrapped line's runs (for search-overlay remapping).
private int lineCols(in PreviewLine pl) @safe
{
    int c;
    foreach (r; pl.runs)
        c += cast(int) columnWidth(r.text);
    return c;
}

/// The byte index in `t` at display column `targetCol` (for column → file-offset).
private size_t byteAtColumn(const(char)[] t, int targetCol) @safe
{
    import std.utf : decode;
    size_t i;
    int c;
    while (i < t.length && c < targetCol)
    {
        const s = i;
        decode(t, i);
        c += cast(int) columnWidth(t[s .. i]);
    }
    return i;
}

/// The source-file offset at display column `col` within a line's runs — walking
/// only source-backed runs (decorations/gutters are skipped), so a click in a
/// gutter snaps to the adjacent content. -1 if the line has no selectable content.
private long srcOffsetAtCol(in PreviewLine pl, int col) @safe
{
    long lastEnd = -1;
    int c;
    foreach (r; pl.runs)
    {
        const rc = cast(int) columnWidth(r.text);
        if (r.srcStart != size_t.max)
        {
            if (col <= c)
                return cast(long) r.srcStart;
            if (col < c + rc)
                return cast(long) r.srcStart + cast(long) byteAtColumn(r.text, col - c);
            lastEnd = cast(long)(r.srcStart + r.text.length);
        }
        c += rc;
    }
    return lastEnd;
}

/// Columns from the content origin to where a line's runs begin (after the quote
/// gutter, indent, and leader), matching `drawPreview`'s layout.
private int runStartCells(in PreviewLine pl) @safe
    => pl.quoteDepth * 2 + pl.indentCols + cast(int) columnWidth(pl.leader);

/// An RGB triple as a raylib color (fully opaque).
Color rl(RgbColor c) pure nothrow @nogc @trusted => Color(c.r, c.g, c.b, 255);
