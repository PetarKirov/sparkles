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

// The shared raylib text core (extracted in M5). Pulls raylib-d + libs
// "raylib" transitively, so it is present only in the `gui` build.
import sparkles.raylib_text : TextStyle, FontSet, drawText;

// hue-specific viewport/search layout (raylib-free, so it stays testable).
import gui_text : columnWidth, lineCount, Match, buildLineStarts, findMatches;

// Markdown-preview model + layout (raylib-free) and the ANSI attribute bits.
import gui_preview : PreviewModel, PreviewLine, PreviewRun, BandKind, layoutPreview,
    buildRawPlines, quoteBarColors, quoteBarCycle;
import gui_ansi : Attr;

// Selective import avoids sparkles.syntax.Color clashing with raylib.Color:
// bare `Color` is unambiguously raylib's; the theme color type is reached only
// through StyleSpec.fg/bg (never named here).
import sparkles.syntax : HighlightEvent, LabelSet, Theme, StyleSpec, TextAttr, UnderlineStyle,
    ResolvedTheme, resolveTheme, byStyledLine, RgbColor, toRgb;
import sparkles.base.smallbuffer : SmallBuffer;

/// The window's default font size in pixels (Ctrl-±/theme cycling arrive in M3).
private enum defaultFontSize = 18;

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

    // Markdown-preview state (M4). A markdown file opens in preview by default;
    // Tab toggles to the raw highlighted-source view. `HUE_GUI_PREVIEW=0/1`
    // pins the initial mode for deterministic golden captures.
    bool showPreview = preview.present;
    if (environment.get("HUE_GUI_PREVIEW", "") == "0")
        showPreview = false;
    else if (environment.get("HUE_GUI_PREVIEW", "") == "1")
        showPreview = preview.present;
    PreviewLine[] plines;
    int lastWidthCols = -1;

    // The live theme state: ←/→ browse `themes`, re-resolving and repainting —
    // the GPU counterpart of hue's terminal Previewer.
    size_t themeIdx = startIdx;
    ResolvedTheme current;
    RgbColor pageFg, pageBg, gutterFg;
    RgbColor[quoteBarCycle] quoteBars;   // per-depth block-quote gutter colors
    RgbColor scrollbarTrack, scrollbarThumb; // link-tinted — distinct from the
    // grayscale structural bands (page / code header / code panel)

    const srcTotal = lineCount(source);
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

    // Both views are wrapped visual-line lists (`PreviewLine[]`) so long lines
    // reflow on resize and line numbers track the source (physical) line. The
    // markdown preview lays out the rendered model; the raw view wraps the
    // highlighted source.
    void relayout()
    {
        lastWidthCols = widthCols();
        if (showPreview && preview.present)
            plines = layoutPreview(preview, current, pageFg, pageBg, lastWidthCols, codeLineNumbers);
        else
            plines = buildRawPlines(source, events, current, pageFg, pageBg, lastWidthCols);
    }

    void applyTheme(size_t i)
    {
        themeIdx = i;
        current = resolveTheme(themes[i], labels);
        pageFg = toRgb(current.defaults.fg, hardFallbackFg);
        pageBg = toRgb(current.defaults.bg, hardFallbackBg);
        gutterFg = mix(pageFg, pageBg); // muted line numbers
        quoteBars = quoteBarColors(current, pageFg, pageBg);
        // Scrollbar chrome: tint toward the theme's link color so the hover track
        // and thumb read as a distinct hue against the grayscale bg/code bands.
        const linkC = toRgb(current[current.labels.resolve("markup.link")].fg, pageFg);
        scrollbarTrack = mix(pageBg, linkC, 0.22);
        scrollbarThumb = mix(pageBg, linkC, 0.5);
        SetWindowTitle(text("hue — ", title, " — ", names[i],
            " (", i + 1, "/", names.length, ")").toStringz);
        relayout(); // preview colors follow the theme
    }

    applyTheme(themeIdx);

    const lineStarts = buildLineStarts(source);

    SmallBuffer!(char, 4096) buf; // reused, NUL-terminated for raylib
    long top = initialTop; // index of the first visible line

    // Search / goto state (M4).
    Mode mode = Mode.normal;
    SmallBuffer!(char, 256) query;
    Match[] matches;
    size_t curMatch;

    // Recompute all match ranges for the current query — an extra decoration
    // layer over the styled spans (the pure mapping lives in gui_text).
    void recompute()
    {
        matches = findMatches(source, query[], lineStarts);
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

    int frame = 0;
    while (!WindowShouldClose())
    {
        const cellW = fonts.cellW();
        const cellH = fonts.cellH();
        const screenW = GetScreenWidth();
        const screenH = GetScreenHeight();
        const visibleRows = screenH / cellH;

        // Reflow (both views wrap) when the window width in columns changes.
        if (widthCols() != lastWidthCols)
            relayout();
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

            // Font sizing: Ctrl-'=' / Ctrl-'-' (reload faces + re-measure).
            const ctrl = IsKeyDown(KeyboardKey.KEY_LEFT_CONTROL)
                || IsKeyDown(KeyboardKey.KEY_RIGHT_CONTROL);
            if (ctrl && pressed(KeyboardKey.KEY_EQUAL))
                fonts.reload(fonts.size() + 2);
            else if (ctrl && pressed(KeyboardKey.KEY_MINUS) && fonts.size() > 6)
                fonts.reload(fonts.size() - 2);

            // Match navigation: n next, Shift-n previous.
            if (matches.length && pressed(KeyboardKey.KEY_N))
            {
                const shift = IsKeyDown(KeyboardKey.KEY_LEFT_SHIFT)
                    || IsKeyDown(KeyboardKey.KEY_RIGHT_SHIFT);
                jumpToMatch(shift ? curMatch + matches.length - 1 : curMatch + 1, visibleRows);
            }

            // Tab toggles markdown preview ↔ raw highlighted source.
            if (preview.present && IsKeyPressed(KeyboardKey.KEY_TAB))
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

            // 'c' toggles the in-panel code-block line numbers.
            if (pressed(KeyboardKey.KEY_C))
            {
                codeLineNumbers = !codeLineNumbers;
                lastWidthCols = -1;
                relayout();
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

/// ditto — thumb sized to the visible fraction, positioned by scroll progress.
private ThumbGeometry thumbGeometry(size_t total, int visibleRows, long top,
    long maxTop, int screenH) pure nothrow @nogc @safe
{
    const trackH = cast(float) screenH;
    float h = trackH * visibleRows / cast(float) total;
    if (h < 24.0f)
        h = 24.0f;
    const movable = trackH - h;
    const y = maxTop > 0 ? movable * top / cast(float) maxTop : 0.0f;
    return ThumbGeometry(y, h, movable);
}

/// An RGB triple as a raylib color with an explicit alpha (for overlays).
private Color alpha(RgbColor c, ubyte a) pure nothrow @nogc @trusted
    => Color(c.r, c.g, c.b, a);

/// `IsKeyPressed` plus auto-repeat while held, so PageDown/j/k etc. repeat.
private bool pressed(int key) @system
    => IsKeyPressed(key) || IsKeyPressedRepeat(key);

/// Midpoint of two colors — used for muted gutter numbers and the scrollbar.
private RgbColor mix(RgbColor a, RgbColor b) pure nothrow @nogc @safe
    => RgbColor(cast(ubyte)((a.r + b.r) / 2), cast(ubyte)((a.g + b.g) / 2),
        cast(ubyte)((a.b + b.b) / 2));

/// `a` blended `t` of the way toward `b` (0 = `a`, 1 = `b`).
private RgbColor mix(RgbColor a, RgbColor b, double t) pure nothrow @nogc @safe
{
    ubyte ch(ubyte x, ubyte y) => cast(ubyte)(x + (y - x) * t);
    return RgbColor(ch(a.r, b.r), ch(a.g, b.g), ch(a.b, b.b));
}

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

/// An RGB triple as a raylib color (fully opaque).
Color rl(RgbColor c) pure nothrow @nogc @trusted => Color(c.r, c.g, c.b, 255);
