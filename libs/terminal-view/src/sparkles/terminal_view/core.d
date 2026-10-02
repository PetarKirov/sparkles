/**
The terminal core (`TVW1`, second slice): the libghostty state bundle, the VT
effect callbacks, the pty feed with its OSC color-query replies, and the
per-cell frame renderer — everything `apps/terminal`'s loop drives, moved
verbatim from its `app.d` so the loop can next become a `runApp` component
(`TVW2`) without touching the render or the protocol behavior.
*/
module sparkles.terminal_view.core;

import core.sys.posix.sys.types : pid_t;

import raylib;

import sparkles.base.buffer : HeapBuffer, UniqueBuffer;
import sparkles.base.term_color : RgbColor;
import sparkles.ghostty.c;
import sparkles.raylib_text : FontSet, LoadedFont, drawGrapheme, drawSolid;
import sparkles.terminal_view.input : ExitBehavior, SelectionState,
    OverlayScrollbar, HoverState;
import sparkles.terminal_view.kitty_images : KittyImageRenderer;
import sparkles.terminal_view.osc_query : OscScanner;
import sparkles.terminal_view.osc_scan : maxTitleBytes;
import sparkles.terminal_view.protocols : ColorScheme, ProtocolInbox;
import sparkles.terminal_view.synchronized_output : SynchronizedOutput;

// Context threaded to every terminal effect callback via the userdata pointer
// so they can reach the pty and the current geometry without globals.
struct EffectsContext
{
    int pty_fd = -1;
    int cellWidth;
    int cellHeight;
    ushort cols;
    ushort rows;
    int bellFlashFrames; // > 0 flashes the screen for a visual bell.

    // OSC 0/2 title, captured rather than applied: the effect fires inside
    // vt_write, where the owner (a window title? an embedder's tab label?)
    // is not this layer's to know. Sanitized and capped (`TPR2`), then
    // NUL-terminated for SetWindowTitle. Multiple changes in one chunk
    // coalesce to the last — whoever consumes titleDirty sees only the newest.
    char[maxTitleBytes + 1] titleBuf = '\0';
    size_t titleLen;
    bool titleDirty;

    // OSC 7 (and ConEmu's/iTerm2's bare-path forms), raw as the engine
    // stores it; `pwdTooLong` marks a value that did not fit, which is
    // ignored rather than truncated into a different path.
    char[4096] pwdBuf = '\0';
    size_t pwdLen;
    bool pwdDirty;
    bool pwdTooLong;

    // The light/dark scheme `CSI ? 996 n` reports (`TPR14`): the embedder's
    // when it set one, else the default background's lightness.
    ColorScheme scheme;
    bool schemeSet;
}

// Device-attribute constants from <ghostty/vt/device.h>. They are C #defines,
// which ImportC does not reliably expose, so we mirror the values here.
private enum DA_CONFORMANCE_VT220 = 62;
private enum DA_FEATURE_COLUMNS_132 = 1;
private enum DA_FEATURE_SELECTIVE_ERASE = 6;
private enum DA_FEATURE_ANSI_COLOR = 22;
private enum DA_DEVICE_TYPE_VT220 = 1;

// write_pty: the terminal calls this whenever a VT sequence needs a response
// written back to the application (DSR, mode/DA queries, …). Without it,
// programs like vim and tmux that probe terminal capabilities would hang.
extern(C) nothrow @nogc
void effect_write_pty(GhosttyTerminal terminal, void* userdata, const(ubyte)* data, size_t len)
{
    import sparkles.terminal_view.input : pty_write;
    auto ctx = cast(EffectsContext*) userdata;
    pty_write(ctx.pty_fd, data, len);
}

// size: responds to XTWINOPS size queries (CSI 14/16/18 t).
extern(C) nothrow @nogc
bool effect_size(GhosttyTerminal terminal, void* userdata, GhosttySizeReportSize* out_size)
{
    auto ctx = cast(EffectsContext*) userdata;
    out_size.rows = ctx.rows;
    out_size.columns = ctx.cols;
    out_size.cell_width = cast(uint) ctx.cellWidth;
    out_size.cell_height = cast(uint) ctx.cellHeight;
    return true;
}

// device_attributes: responds to DA1/DA2/DA3 so applications can identify the
// terminal. We report VT220-level conformance with a modest feature set.
extern(C) nothrow @nogc
bool effect_device_attributes(GhosttyTerminal terminal, void* userdata, GhosttyDeviceAttributes* out_attrs)
{
    out_attrs.primary.conformance_level = DA_CONFORMANCE_VT220;
    out_attrs.primary.features[0] = DA_FEATURE_COLUMNS_132;
    out_attrs.primary.features[1] = DA_FEATURE_SELECTIVE_ERASE;
    out_attrs.primary.features[2] = DA_FEATURE_ANSI_COLOR;
    out_attrs.primary.num_features = 3;

    out_attrs.secondary.device_type = DA_DEVICE_TYPE_VT220;
    out_attrs.secondary.firmware_version = 1;
    out_attrs.secondary.rom_cartridge = 0;

    out_attrs.tertiary.unit_id = 0;
    return true;
}

// xtversion: responds to CSI > q with our application name.
extern(C) nothrow @nogc
GhosttyString effect_xtversion(GhosttyTerminal terminal, void* userdata)
{
    static immutable name = "sparkles";
    return GhosttyString(cast(const(ubyte)*) name.ptr, name.length);
}

// enquiry: answerback for the ENQ control (0x05). We send nothing.
extern(C) nothrow @nogc
GhosttyString effect_enquiry(GhosttyTerminal terminal, void* userdata)
{
    return GhosttyString(null, 0);
}

// title_changed: captures the OSC 0 / OSC 2 title into the context; the
// component applies it (window title, tab label) at frame time.
extern(C) nothrow @nogc
void effect_title_changed(GhosttyTerminal terminal, void* userdata)
{
    GhosttyString title;
    if (ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &title) != GHOSTTY_SUCCESS)
        return;

    import sparkles.terminal_view.osc_scan : sanitizeTitle;

    auto ctx = cast(EffectsContext*) userdata;
    const raw = title.ptr is null ? null : (cast(const(char)*) title.ptr)[0 .. title.len];
    const n = sanitizeTitle(raw, ctx.titleBuf[0 .. maxTitleBytes]);
    ctx.titleBuf[n] = '\0';
    ctx.titleLen = n;
    ctx.titleDirty = true;
}

// pwd_changed: captures the raw OSC 7 value; the component validates it
// (local host, existing directory — `TPR4`) at frame time.
extern(C) nothrow @nogc
void effect_pwd_changed(GhosttyTerminal terminal, void* userdata)
{
    GhosttyString pwd;
    if (ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_PWD, &pwd) != GHOSTTY_SUCCESS)
        return;
    auto ctx = cast(EffectsContext*) userdata;
    ctx.pwdTooLong = pwd.len > ctx.pwdBuf.length;
    ctx.pwdLen = ctx.pwdTooLong ? 0 : pwd.len;
    if (ctx.pwdLen)
        ctx.pwdBuf[0 .. ctx.pwdLen] = (cast(const(char)*) pwd.ptr)[0 .. ctx.pwdLen];
    ctx.pwdDirty = true;
}

// color_scheme: answers `CSI ? 996 n` (`TPR14`) from the scheme the embedder
// set, else from the default background — what the pane shows.
extern(C) nothrow @nogc
bool effect_color_scheme(GhosttyTerminal terminal, void* userdata, GhosttyColorScheme* out_scheme)
{
    auto ctx = cast(EffectsContext*) userdata;
    *out_scheme = schemeInEffect(terminal, *ctx) == ColorScheme.dark
        ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT;
    return true;
}

/// The scheme a pane reports: the one set, else its default background's.
@system nothrow @nogc
ColorScheme schemeInEffect(GhosttyTerminal terminal, in EffectsContext ctx)
{
    if (ctx.schemeSet)
        return ctx.scheme;
    GhosttyColorRgb bg;
    if (ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND, &bg) != GHOSTTY_SUCCESS)
        return ColorScheme.dark;
    return schemeOfBackground(bg.r, bg.g, bg.b);
}

/// A background is light when its relative luminance (Rec. 709) exceeds ½.
ColorScheme schemeOfBackground(ubyte r, ubyte g, ubyte b) @safe pure nothrow @nogc
    => 2126 * r + 7152 * g + 722 * b > 10_000 * 255 / 2 ? ColorScheme.light : ColorScheme.dark;

@("terminal_view.core.schemeOfBackground")
@safe pure nothrow @nogc unittest
{
    assert(schemeOfBackground(0, 0, 0) == ColorScheme.dark);
    assert(schemeOfBackground(0x28, 0x2c, 0x34) == ColorScheme.dark);
    assert(schemeOfBackground(255, 255, 255) == ColorScheme.light);
    assert(schemeOfBackground(0xfd, 0xf6, 0xe3) == ColorScheme.light); // solarized light
}

// bell: BEL (0x07) — trigger a brief screen flash as a visual bell.
extern(C) nothrow @nogc
void effect_bell(GhosttyTerminal terminal, void* userdata)
{
    auto ctx = cast(EffectsContext*) userdata;
    ctx.bellFlashFrames = 4;
}

// decode_png: decodes raw PNG data into RGBA pixels using raylib's stb_image
// decoder so the terminal can display images via the Kitty Graphics Protocol.
// The output buffer is allocated through the provided GhosttyAllocator so the
// library can free it later. Installed process-globally via ghostty_sys_set.
extern(C) nothrow @nogc
bool decode_png(void* userdata, GhosttyAllocator* allocator, const(ubyte)* data, size_t data_len, GhosttySysImage* outImg)
{
    Image img = LoadImageFromMemory(".png".ptr, data, cast(int) data_len);
    if (img.data is null) return false;

    // Convert to uncompressed RGBA so we have a known pixel layout.
    ImageFormat(&img, PixelFormat.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8);

    const size_t pixel_len = cast(size_t) img.width * cast(size_t) img.height * 4;
    ubyte* pixels = ghostty_alloc(allocator, pixel_len);
    if (pixels is null) {
        UnloadImage(img);
        return false;
    }

    import core.stdc.string : memcpy;
    memcpy(pixels, img.data, pixel_len);
    UnloadImage(img);

    outImg.width = cast(uint) img.width;
    outImg.height = cast(uint) img.height;
    outImg.data = pixels;
    outImg.data_len = pixel_len;
    return true;
}

// The raylib boundary. `ResolvedCell` carries backend-neutral `RgbColor`;
// raylib's draw calls want its own `Color`. Every colour the VT resolves is
// opaque, so alpha is supplied here rather than carried per cell.
private Color rl(in RgbColor c) @safe pure nothrow @nogc
    => Color(c.r, c.g, c.b, 255);

// Per-cell render data resolved by `resolveCell` and consumed by both passes of
// the two-pass renderer (backgrounds first, then glyphs).
struct ResolvedCell
{
    bool hasGrapheme;     // cell has a grapheme cluster to draw
    uint graphemeLen;
    uint codepoint;
    uint width = 1;
    bool hasHyperlink;
    GhosttyStyle style;
    // Backend-neutral on purpose: `resolveCell` is shared with `cell_paint.d`,
    // which paints through any `isCanvas` target and must not see raylib's
    // `Color`. The conversion happens at the raylib call sites in `paintFrame`,
    // where it belongs. Alpha is not carried because every colour the VT
    // resolves is opaque.
    RgbColor fgCol;
    RgbColor bgCol;
    RgbColor underlineCol;
    bool hasBg;           // a background rect should be painted for this cell
    bool isHoveredLink;   // cell is under a hovered OSC 8 link (drawn underlined)
}

// Resolve colors/style once per painted cell. The background pass retains
// these values for the glyph pass; the cell-canvas path consumes them directly.
@system nothrow @nogc
package(sparkles.terminal_view) ResolvedCell resolveCell(
    GhosttyRenderStateRowCells cells,
    in GhosttyRenderStateColors colors,
    int cellX, int cellY,
    bool hasSelection,
    in GhosttyPointCoordinate selStart,
    in GhosttyPointCoordinate selEnd,
    in SelectionState selState,
    in HoverState hoverState)
{
    ResolvedCell r;

    ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &r.graphemeLen);
    r.hasGrapheme = r.graphemeLen != 0;
    GhosttyCell raw;
    if (ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw) == GHOSTTY_SUCCESS)
    {
        ghostty_cell_get(raw, GHOSTTY_CELL_DATA_CODEPOINT, &r.codepoint);
        ghostty_cell_get(raw, GHOSTTY_CELL_DATA_HAS_HYPERLINK, &r.hasHyperlink);
        GhosttyCellWide wide;
        ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide);
        r.width = wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : 1;
    }

    // Seed fg/bg from the terminal defaults; the per-cell queries overwrite them
    // only when the cell has an explicit color and return INVALID_VALUE otherwise.
    GhosttyColorRgb fgRgb = colors.foreground;
    ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fgRgb);

    GhosttyColorRgb bgRgb = colors.background;
    bool hasBg = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bgRgb) == GHOSTTY_SUCCESS;

    RgbColor bgCol = RgbColor(bgRgb.r, bgRgb.g, bgRgb.b);
    RgbColor fgCol = RgbColor(fgRgb.r, fgRgb.g, fgRgb.b);

    // Read the cell style for SGR attribute flags. Colors are already resolved
    // above via the FG/BG_COLOR queries.
    r.style.size = GhosttyStyle.sizeof;
    ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &r.style);

    // Reverse video: swap fg/bg up front so the selection/hover swap below
    // composes on top of it correctly.
    if (r.style.inverse)
    {
        RgbColor inv = bgCol;
        bgCol = fgCol;
        fgCol = inv;
        hasBg = true;
    }

    bool isSelected = false;
    if (hasSelection)
    {
        if (selState.isRectangular)
        {
            int minX = selStart.x < selEnd.x ? selStart.x : selEnd.x;
            int maxX = selStart.x > selEnd.x ? selStart.x : selEnd.x;
            if (cellY >= selStart.y && cellY <= selEnd.y && cellX >= minX && cellX <= maxX)
                isSelected = true;
        }
        else
        {
            if (cellY > selStart.y && cellY < selEnd.y)
                isSelected = true;
            else if (cellY == selStart.y && cellY == selEnd.y)
                isSelected = cellX >= selStart.x && cellX <= selEnd.x;
            else if (cellY == selStart.y)
                isSelected = cellX >= selStart.x;
            else if (cellY == selEnd.y)
                isSelected = cellX <= selEnd.x;
        }
    }

    bool isHoveredLink = hoverState.isHoveringUrl && cellY == hoverState.y
        && cellX >= hoverState.start_x && cellX <= hoverState.end_x;

    // Selection and hovered-link both render as inverted. Swap once if either is
    // set (swapping per-condition would cancel out when both are true).
    if (isSelected || isHoveredLink)
    {
        RgbColor tmp = bgCol;
        bgCol = fgCol;
        fgCol = tmp;
        hasBg = true;
    }
    // Faint affects the displayed ink, after inverse/selection color swaps.
    if (r.style.faint)
        fgCol = RgbColor(cast(ubyte)(fgCol.r / 2), cast(ubyte)(fgCol.g / 2),
            cast(ubyte)(fgCol.b / 2));

    r.fgCol = fgCol;
    r.bgCol = bgCol;
    r.hasBg = hasBg;
    r.isHoveredLink = isHoveredLink;
    r.underlineCol = fgCol;
    if (r.style.underline_color.tag == GHOSTTY_STYLE_COLOR_RGB)
    {
        const c = r.style.underline_color.value.rgb;
        r.underlineCol = RgbColor(c.r, c.g, c.b);
    }
    else if (r.style.underline_color.tag == GHOSTTY_STYLE_COLOR_PALETTE)
    {
        const c = colors.palette[r.style.underline_color.value.palette];
        r.underlineCol = RgbColor(c.r, c.g, c.b);
    }
    return r;
}

private const(uint)[] cellGrapheme(GhosttyRenderStateRowCells cells,
    ref UniqueBuffer!(uint, 16) storage) @system nothrow @nogc
{
    uint length;
    ghostty_render_state_row_cells_get(cells,
        GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &length);
    storage.length = length;
    if (length)
        ghostty_render_state_row_cells_get(cells,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, storage[].ptr);
    return storage[];
}

/// Variable-length clusters retain every codepoint without overwriting style
/// data; color resolution still honors inverse, faint and underline colors.
@("terminal_view.resolveCell.longClusterAndStyle")
@system nothrow @nogc
unittest
{
    CoreState s;
    GhosttyTerminalOptions options = { cols: 8, rows: 2 };
    assert(ghostty_terminal_new(null, &s.terminal, options) == GHOSTTY_SUCCESS);
    scope (exit) ghostty_terminal_free(s.terminal);
    assert(ghostty_render_state_new(null, &s.render_state) == GHOSTTY_SUCCESS);
    scope (exit) ghostty_render_state_free(s.render_state);
    assert(ghostty_render_state_row_iterator_new(null, &s.row_iter) == GHOSTTY_SUCCESS);
    scope (exit) ghostty_render_state_row_iterator_free(s.row_iter);
    assert(ghostty_render_state_row_cells_new(null, &s.cells) == GHOSTTY_SUCCESS);
    scope (exit) ghostty_render_state_row_cells_free(s.cells);
    static immutable style = "\x1b[38;2;120;80;40;48;2;20;40;60;58;2;10;20;30;4:3;2;7mA";
    ghostty_terminal_vt_write(s.terminal, cast(const(ubyte)*) style.ptr, style.length);
    foreach (_; 0 .. 24)
        ghostty_terminal_vt_write(s.terminal, cast(const(ubyte)*) "\u0301".ptr, 2);
    ghostty_render_state_update(s.render_state, s.terminal);
    ghostty_render_state_get(s.render_state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &s.row_iter);
    assert(ghostty_render_state_row_iterator_next(s.row_iter));
    ghostty_render_state_row_get(s.row_iter, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &s.cells);
    assert(ghostty_render_state_row_cells_next(s.cells));
    GhosttyRenderStateColors colors;
    colors.size = GhosttyRenderStateColors.sizeof;
    ghostty_render_state_colors_get(s.render_state, &colors);
    const cell = resolveCell(s.cells, colors, 0, 0, false,
        GhosttyPointCoordinate.init, GhosttyPointCoordinate.init, s.selState, s.hoverState);
    assert(cell.codepoint == 'A' && cell.graphemeLen == 25);
    const cluster = cellGrapheme(s.cells, s.grapheme);
    assert(cluster.length == 25 && cluster[0] == 'A');
    foreach (cp; cluster[1 .. $])
        assert(cp == 0x301);
    assert(cell.fgCol == RgbColor(10, 20, 30));
    assert(cell.bgCol == RgbColor(120, 80, 40));
    assert(cell.underlineCol == RgbColor(10, 20, 30));
    assert(cell.style.underline == GHOSTTY_SGR_UNDERLINE_CURLY);
}

// Decorations use cell geometry, not the font's glyph bounds; a wide cell
// carries one continuous line and the phase continues across adjacent cells.
private void drawCellDecorations(ref LoadedFont white, in ResolvedCell cell,
    int x, int y, int width, int height) @system nothrow @nogc
{
    import std.algorithm.comparison : max, min;

    const thickness = max(1, height / 16);
    const underlineY = y + height - thickness - 1;
    const ink = rl(cell.fgCol);
    const underlineInk = rl(cell.underlineCol);
    switch (cell.style.underline)
    {
        case GHOSTTY_SGR_UNDERLINE_SINGLE:
            drawSolid(white, x, underlineY, width, thickness, underlineInk);
            break;
        case GHOSTTY_SGR_UNDERLINE_DOUBLE:
            drawSolid(white, x, underlineY, width, thickness, underlineInk);
            drawSolid(white, x, max(y, underlineY - 2 * thickness),
                width, thickness, underlineInk);
            break;
        case GHOSTTY_SGR_UNDERLINE_CURLY:
            // A six-step wave keeps its trough inside the cell even at small
            // font sizes. Absolute x keeps neighbouring cell phases aligned.
            static immutable int[6] wave = [0, 0, 1, 2, 2, 1];
            foreach (dx; 0 .. width)
                drawSolid(white, x + dx,
                    max(y, underlineY - wave[((x + dx) / thickness) % wave.length] * thickness),
                    1, thickness, underlineInk);
            break;
        case GHOSTTY_SGR_UNDERLINE_DOTTED:
        case GHOSTTY_SGR_UNDERLINE_DASHED:
            const dash = cell.style.underline == GHOSTTY_SGR_UNDERLINE_DOTTED
                ? thickness : 3 * thickness;
            const period = dash + thickness;
            for (int dx = 0; dx < width;)
            {
                const phase = (x + dx) % period;
                const length = min(width - dx, phase < dash ? dash - phase : period - phase);
                if (phase < dash)
                    drawSolid(white, x + dx, underlineY, length, thickness, underlineInk);
                dx += length;
            }
            break;
        default:
            break;
    }
    if (cell.style.strikethrough)
        drawSolid(white, x, y + height / 2, width, thickness, ink);
    if (cell.style.overline)
        drawSolid(white, x, y, width, thickness, ink);
    if (cell.hasHyperlink || cell.isHoveredLink)
    {
        const weight = cell.isHoveredLink ? 2 * thickness : thickness;
        drawSolid(white, x, y + height - weight, width, weight, ink);
    }
}

// All per-run state the @nogc core loop touches. Holds non-copyable UniqueBuffers
// (font glyph sets, hover URL), so it lives as a single stack-pinned instance in
// main() and is passed only by `ref`.
struct CoreState
{
    GhosttyTerminal terminal;
    GhosttyRenderState render_state;
    GhosttyRenderStateRowIterator row_iter;
    GhosttyRenderStateRowCells cells;
    GhosttyKittyGraphicsPlacementIterator placement_iter;
    KittyImageRenderer images;
    ulong imageMutationEpoch;
    GhosttyKeyEvent key_event;
    GhosttyKeyEncoder key_encoder;
    GhosttyMouseEvent mouse_event;
    GhosttyMouseEncoder mouse_encoder;
    // Reused for variable-length graphemes; the C getter has no capacity
    // parameter, so callers must size this from GRAPHEMES_LEN before writing.
    UniqueBuffer!(uint, 16) grapheme;
    HeapBuffer!ResolvedCell resolvedCells;

    int pty_fd = -1;
    pid_t child = -1;

    EffectsContext effects_ctx;

    ExitBehavior exitBehavior;
    bool debugScreenshotAndExit;

    // The shared multi-face font resource (sparkles:raylib-text): primary + real
    // bold/italic/bold-italic variants, regular/Nerd fallbacks, --font-codepoint-map
    // faces, on-demand atlas growth, and per-face O(log n) glyph maps.
    /// Borrowed: the window session owns the face set (one atlas per window,
    /// whoever drives the loop). The polling loop points this at its own
    /// stack instance; the runApp component at the host session's.
    FontSet* fonts;

    int fontSize = 20;
    int cellWidth = 1;
    int cellHeight = 1;
    ushort cols;
    ushort rows;

    SelectionState selState;
    OverlayScrollbar sbState;
    HoverState hoverState;

    // Streaming OSC scanner answering palette/default color queries (see
    // feedPtyChunk); persists across pty read chunks.
    OscScanner oscScan;
    // What the OSC traffic asked of the host (icons, notifications, OSC 52),
    // recorded by the feed and delivered at frame time (`TPR`).
    ProtocolInbox protocol;
    SynchronizedOutput synchronizedOutput;

    // The emulator's own overlay scrollbar (mouse-driven). The standalone
    // app wants it; an embedding application draws its own bar beside the
    // pane and turns this one off.
    bool internalScrollbar = true;

    // Child-process lifecycle. childExited is set when the pty signals EOF/EIO;
    // childReaped once waitpid() collects the exit status.
    bool childExited;
    bool childReaped;
    int childStatus = -1;
    // What the exited banner offers, after the status (an embedder's exit
    // prompt, `TSS2`); empty shows the status alone.
    const(char)[] exitHint;
}

/**
Which build is running, logged at `info` (terminal `TPG2`, `TPG7`): the
application's version and commit as the build stamped them — `dev` for a plain
`dub build` — and how libghostty-vt was built (SIMD, optimization mode).

The stamp is read in $(I this) compilation: terminal-view is a source library,
so it is the embedding application's `-J` that supplies it
($(REF buildStampOf, sparkles,base,build_stamp)).
*/
void logBuildInfo(string appName = "sparkles:terminal") @system nothrow @nogc
{
    import sparkles.base.build_stamp : buildStampOf;
    import sparkles.base.logger : info;

    enum stamp = buildStampOf!();
    enum commit = stamp.commitLabel;
    info(i"$(appName) $(stamp.version_) ($(commit))");

    bool simd = false;
    ghostty_build_info(GHOSTTY_BUILD_INFO_SIMD, &simd);

    GhosttyOptimizeMode opt = GHOSTTY_OPTIMIZE_DEBUG;
    ghostty_build_info(GHOSTTY_BUILD_INFO_OPTIMIZE, &opt);

    string optName;
    switch (opt) {
        case GHOSTTY_OPTIMIZE_DEBUG:         optName = "Debug";        break;
        case GHOSTTY_OPTIMIZE_RELEASE_SAFE:  optName = "ReleaseSafe";  break;
        case GHOSTTY_OPTIMIZE_RELEASE_SMALL: optName = "ReleaseSmall"; break;
        case GHOSTTY_OPTIMIZE_RELEASE_FAST:  optName = "ReleaseFast";  break;
        default:                             optName = "Unknown";      break;
    }

    const simdName = simd ? "enabled" : "disabled";
    info(i"ghostty-vt: simd $(simdName), optimize $(optName)");
}

// Write an xterm-style dynamic color report, or an OSC 4 palette report when
// the caller supplies the current palette. Match the query's terminator and
// expand 8-bit channels to 16 bits. An unset cursor uses the foreground.
@system nothrow @nogc
void replyColorQuery(ref CoreState s, int code, scope const(GhosttyColorRgb)[] palette = null)
{
    import core.stdc.stdio : snprintf;
    import sparkles.terminal_view.input : pty_write;

    GhosttyColorRgb rgb;
    if (palette.length)
        rgb = palette[code];
    else
    {
        const data = code == 11 ? GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND
            : code == 12 ? GHOSTTY_TERMINAL_DATA_COLOR_CURSOR
            : GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND;
        if (ghostty_terminal_get(s.terminal, data, &rgb) != GHOSTTY_SUCCESS
            && (code != 12
                || ghostty_terminal_get(s.terminal, GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND, &rgb) != GHOSTTY_SUCCESS))
            return;
    }

    char[48] buf;
    const len = snprintf(buf.ptr, buf.length,
        palette.length ? "\x1b]4;%d;rgb:%04x/%04x/%04x%s".ptr
            : "\x1b]%d;rgb:%04x/%04x/%04x%s".ptr,
        code, rgb.r * 257, rgb.g * 257, rgb.b * 257,
        s.oscScan.endedWithBel ? "\x07".ptr : "\x1b\\".ptr);
    if (len > 0)
        pty_write(s.pty_fd, buf.ptr, cast(size_t) len);
}

// Feed one pty chunk to the terminal while scanning it for OSC color queries
// (see the osc_query module for why the emulator must answer them). The chunk
// is fed in segments split at each complete OSC sequence so that a query's
// reply is written only after the library consumed the query bytes, and
// before any response the library generates for later queries in the same
// chunk (yazi sends `OSC 11;?` followed by DA1 and stops reading at the DA1
// response, so the color report has to precede it).
@system nothrow @nogc
void feedPtyChunk(ref CoreState s, scope const(char)[] chunk)
{
    import sparkles.terminal_view.osc_query : oscScanByte, oscColorQueryCodes;

    size_t segStart = 0;
    for (size_t i = 0; i < chunk.length; ++i)
    {
        // Image payloads and ordinary text contain long inert ASCII runs.
        // Scan those once, not through all three control-state machines.
        if (s.oscScan.state == OscScanner.State.ground
            && s.synchronizedOutput.skipsPrintable && s.images.skipsPrintable)
        {
            while (i < chunk.length && chunk[i] >= ' ' && chunk[i] <= '~')
                ++i;
            if (i == chunk.length)
                break;
        }
        const b = chunk[i];
        s.images.observeByte(b);
        const oscBoundary = oscScanByte(s.oscScan, b);
        const syncBoundary = s.synchronizedOutput.scanByte(b);
        if (oscBoundary || syncBoundary)
        {
            ghostty_terminal_vt_write(s.terminal,
                cast(const(ubyte)*) chunk.ptr + segStart, cast(uint)(i + 1 - segStart));
            segStart = i + 1;
            if (syncBoundary && s.synchronizedOutput.observe(s.terminal, s.render_state))
            {
                s.images.capture(s.terminal, s.placement_iter, s.cellWidth, s.cellHeight);
                // Image-only work preceding this hold is a completed prefix,
                // even though Ghostty's grid snapshot has no image dirty bit.
                if (s.images.repaintPending)
                {
                    GhosttyRenderStateDirty dirty = GHOSTTY_RENDER_STATE_DIRTY_FULL;
                    ghostty_render_state_set(s.render_state, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &dirty);
                }
            }
            if (oscBoundary && !s.oscScan.overflowed)
            {
                UniqueBuffer!(int, 4) codes;
                const command = oscColorQueryCodes(s.oscScan.payload[], codes);
                if (command == 4 && codes.length)
                {
                    // Read once per OSC batch, directly from effective VT
                    // state: OSC overrides and resets are already applied.
                    GhosttyColorRgb[256] palette;
                    if (ghostty_terminal_get(s.terminal,
                            GHOSTTY_TERMINAL_DATA_COLOR_PALETTE, &palette) == GHOSTTY_SUCCESS)
                        foreach (code; codes[])
                            replyColorQuery(s, code, palette[]);
                }
                else
                    foreach (code; codes[])
                        replyColorQuery(s, code);
            }
            if (oscBoundary)
            {
                import sparkles.terminal_view.protocols : observeOsc;

                observeOsc(s.protocol, s.oscScan, s.pty_fd);
            }
        }
    }
    if (segStart < chunk.length)
        ghostty_terminal_vt_write(s.terminal,
            cast(const(ubyte)*) chunk.ptr + segStart, cast(uint)(chunk.length - segStart));
    if (chunk.length)
        ++s.imageMutationEpoch;
}

// The frame's draw calls, bracket-free — callable from a raylib
// BeginDrawing/EndDrawing pair or from a host's draw
// phase (`HST13`), which owns its own bracket: background fill, kitty image
// layers, the two-pass cell render, scrollbar, cursor styles, exit banner,
// bell flash, and the per-row + global dirty reset. The caller owns the
// bracket and the deferred-texture flush (textures freed only after the
// bracket's commands reach the GPU).
@system nothrow @nogc
void paintFrame(ref CoreState s, int viewW, int viewH)
{
        // Resolved default colors (used for the background fill, default cell
        // colors, and the cursor) instead of hardcoded white-on-black.
        GhosttyRenderStateColors colors;
        colors.size = GhosttyRenderStateColors.sizeof;
        ghostty_render_state_colors_get(s.render_state, &colors);

        // The page: a full-surface fill rather than ClearBackground, because
        // inside a host's bracket the clear already happened (to the host's
        // page) and clearing is not a draw call the hook may make.
        drawSolid(s.fonts.whiteFace, 0, 0, viewW, viewH,
            Color(colors.background.r, colors.background.g, colors.background.b, 255));

        // Images remain frozen alongside the text during synchronized output.
        if (s.synchronizedOutput.held)
            s.images.drawCapturedLayer(GHOSTTY_KITTY_PLACEMENT_LAYER_BELOW_BG);
        else
        {
            s.images.prepare(s.terminal, s.imageMutationEpoch, s.cellWidth, s.cellHeight);
            s.images.drawLayer(s.terminal, s.placement_iter, GHOSTTY_KITTY_PLACEMENT_LAYER_BELOW_BG);
        }

        GhosttyPointCoordinate sel_start_pt, sel_end_pt;
        bool has_selection = false;
        if (s.selState.start && s.selState.end)
        {
            if (ghostty_tracked_grid_ref_point(s.selState.start, GHOSTTY_POINT_TAG_VIEWPORT, &sel_start_pt) == GHOSTTY_SUCCESS &&
                ghostty_tracked_grid_ref_point(s.selState.end, GHOSTTY_POINT_TAG_VIEWPORT, &sel_end_pt) == GHOSTTY_SUCCESS)
            {
                has_selection = true;

                // ensure start is before end
                if (sel_start_pt.y > sel_end_pt.y || (sel_start_pt.y == sel_end_pt.y && sel_start_pt.x > sel_end_pt.x))
                {
                    auto temp = sel_start_pt;
                    sel_start_pt = sel_end_pt;
                    sel_end_pt = temp;
                }
            }
        }

        // Two-pass render: paint ALL cell backgrounds first, then ALL glyphs.
        // Full-height glyphs (powerline separators, box-drawing, tall Nerd Font
        // icons) can exceed the cell box. With a single interleaved pass the
        // next row's background would overwrite the previous row's glyph
        // overflow, clipping it ("cut in half"); separating the passes means
        // every background lands before any glyph is drawn. Resolve each cell
        // only once, sharing the retained result between the two passes.

        // --- Pass 1: backgrounds. ---
        s.resolvedCells.clear(releaseStorage: false);
        ghostty_render_state_get(s.render_state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &s.row_iter);
        int bgY = 0;
        while (ghostty_render_state_row_iterator_next(s.row_iter))
        {
            ghostty_render_state_row_get(s.row_iter, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &s.cells);

            int bgX = 0;
            while (ghostty_render_state_row_cells_next(s.cells))
            {
                const rc = resolveCell(s.cells, colors, bgX / s.cellWidth, bgY / s.cellHeight,
                    has_selection, sel_start_pt, sel_end_pt, s.selState, s.hoverState);
                s.resolvedCells ~= rc;
                if (rc.hasBg)
                    drawSolid(s.fonts.whiteFace, bgX, bgY, s.cellWidth, s.cellHeight, rl(rc.bgCol));
                bgX += s.cellWidth;
            }

            bgY += s.cellHeight;
        }

        // This layer covers cell backgrounds, never the glyphs above it.
        if (s.synchronizedOutput.held)
            s.images.drawCapturedLayer(GHOSTTY_KITTY_PLACEMENT_LAYER_BELOW_TEXT);
        else
            s.images.drawLayer(s.terminal, s.placement_iter, GHOSTTY_KITTY_PLACEMENT_LAYER_BELOW_TEXT);

        // --- Pass 2: glyphs and per-cell decorations. Re-fetching the row
        //     iterator rewinds it to the first row. ---
        ghostty_render_state_get(s.render_state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &s.row_iter);
        int y = 0;
        size_t resolvedIndex;
        while (ghostty_render_state_row_iterator_next(s.row_iter))
        {
            ghostty_render_state_row_get(s.row_iter, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &s.cells);

            int x = 0;
            while (ghostty_render_state_row_cells_next(s.cells))
            {
                const ref rc = s.resolvedCells[resolvedIndex++];

                if (rc.hasGrapheme && !rc.style.invisible)
                {
                    import sparkles.terminal_view.cell_graphics : drawCellGraphics;

                    const ink = rl(rc.fgCol);
                    if (rc.graphemeLen != 1
                        || !drawCellGraphics(s.fonts.whiteFace, rc.codepoint,
                            cast(float) x, cast(float) y, s.cellWidth, s.cellHeight, ink))
                    {
                        uint[1] single = [rc.codepoint];
                        const(uint)[] cluster = single[];
                        if (rc.graphemeLen > 1)
                            cluster = cellGrapheme(s.cells, s.grapheme);
                        if (!s.fonts.drawCluster(cluster, rc.style.bold, rc.style.italic,
                                cast(float) x, cast(float) y,
                                cast(int) rc.width * s.cellWidth, s.cellHeight, ink))
                        {
                            bool fakeBold, fakeItalic;
                            LoadedFont* face = s.fonts.resolveFace(
                                rc.codepoint, rc.style.bold, rc.style.italic, fakeBold, fakeItalic);
                            drawGrapheme(*face, cluster, cast(float) x, cast(float) y, s.fontSize, ink);
                            if (fakeBold)
                                drawGrapheme(*face, cluster, cast(float)(x + 1), cast(float) y,
                                    s.fontSize, ink);
                        }
                    }
                    drawCellDecorations(s.fonts.whiteFace, rc, x, y,
                        cast(int) rc.width * s.cellWidth, s.cellHeight);
                }

                x += s.cellWidth;
            }

            // Clear this row's dirty flag now that it has been drawn.
            bool rowClean = false;
            ghostty_render_state_row_set(s.row_iter, GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &rowClean);

            y += s.cellHeight;
        }

        // Render scrollbar
        GhosttyTerminalScrollbar sb;
        ghostty_terminal_get(s.terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, cast(void*)&sb);

        if (s.internalScrollbar && sb.total > sb.len)
        {
            const thumb = s.sbState.view.v.scrolledTo(sb.offset)
                .thumb(sb.total, sb.len, viewH, 20);
            float w = s.sbState.view.vAnim.extent(4.0f, 12.0f);
            float x = viewW - w;

            if (s.sbState.view.v.hovered || s.sbState.view.v.dragging)
                DrawRectangle(cast(int)x, 0, cast(int)w, viewH,
                    Color(255, 255, 255, 30));
            DrawRectangle(cast(int)x, thumb.start, cast(int)w, thumb.extent,
                Color(255, 255, 255, 120));
        }

        // Draw the cursor
        bool cursor_visible = false;
        ghostty_render_state_get(s.render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, cast(void*)&cursor_visible);
        bool cursor_in_viewport = false;
        ghostty_render_state_get(s.render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, cast(void*)&cursor_in_viewport);

        if (cursor_visible && cursor_in_viewport)
        {
            ushort cx = 0, cy = 0;
            ghostty_render_state_get(s.render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, cast(void*)&cx);
            ghostty_render_state_get(s.render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, cast(void*)&cy);

            GhosttyColorRgb cur_rgb = colors.foreground;
            if (colors.cursor_has_value)
                cur_rgb = colors.cursor;

            int cursor_style = 1; // Block
            ghostty_render_state_get(s.render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, cast(void*)&cursor_style);

            int c_x = cx * s.cellWidth;
            int c_y = cy * s.cellHeight;
            Color c_color = Color(cur_rgb.r, cur_rgb.g, cur_rgb.b, 160);

            if (cursor_style == 0) // Bar
                drawSolid(s.fonts.whiteFace, c_x, c_y, 2, s.cellHeight, c_color);
            else if (cursor_style == 1) // Block
                drawSolid(s.fonts.whiteFace, c_x, c_y, s.cellWidth, s.cellHeight, c_color);
            else if (cursor_style == 2) // Underline
                drawSolid(s.fonts.whiteFace, c_x, c_y + s.cellHeight - 2, s.cellWidth, 2, c_color);
            else if (cursor_style == 3) // Hollow block
                DrawRectangleLines(c_x, c_y, s.cellWidth, s.cellHeight, c_color);
        }

        // Images above text (z >= 0): drawn last, over everything else.
        if (s.synchronizedOutput.held)
            s.images.drawCapturedLayer(GHOSTTY_KITTY_PLACEMENT_LAYER_ABOVE_TEXT);
        else
            s.images.drawLayer(s.terminal, s.placement_iter, GHOSTTY_KITTY_PLACEMENT_LAYER_ABOVE_TEXT);

        // Banner shown once the child has exited, so the user knows the shell
        // is gone (they can still scroll / inspect the final output).
        if (s.childExited)
        {
            import core.stdc.stdio : snprintf;
            char[128] msg;
            if (s.childReaped && s.childStatus >= 0)
                snprintf(msg.ptr, msg.length, "[process exited with status %d]%s%.*s",
                    s.childStatus, s.exitHint.length ? "   ".ptr : "".ptr,
                    cast(int) s.exitHint.length, s.exitHint.ptr);
            else
                snprintf(msg.ptr, msg.length, "[process exited]");

            Vector2 msgSize = MeasureTextEx(s.fonts.primaryFont(), msg.ptr, s.fontSize, 0);
            int screenW = viewW;
            int screenH = viewH;
            int bannerH = cast(int) msgSize.y + 8;
            DrawRectangle(0, screenH - bannerH, screenW, bannerH, Color(0, 0, 0, 180));
            DrawTextEx(s.fonts.primaryFont(), msg.ptr,
                // Centred, or from the left edge when wider than the pane.
                Vector2(msgSize.x < screenW ? (screenW - msgSize.x) / 2 : 4, screenH - bannerH + 4), s.fontSize, 0, Color(255, 255, 255, 255));
        }

        // Visual bell: a brief translucent flash over the whole window.
        if (s.effects_ctx.bellFlashFrames > 0)
        {
            DrawRectangle(0, 0, viewW, viewH, Color(255, 255, 255, 40));
            s.effects_ctx.bellFlashFrames--;
        }

        // Reset global dirty state so the next update reports changes accurately.
        GhosttyRenderStateDirty clean_state = GHOSTTY_RENDER_STATE_DIRTY_FALSE;
        ghostty_render_state_set(s.render_state, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &clean_state);
        if (!s.synchronizedOutput.held)
            s.images.repaintPending = false;
}

@("terminal_view.core.titleCapture.oscTitleLandsInTheContext")
@system nothrow @nogc
unittest
{
    // No window, no pty: a bare terminal with the title effect wired at the
    // captured context, fed OSC 2 through vt_write — exactly `open`'s wiring.
    EffectsContext ctx;
    GhosttyTerminal term;
    GhosttyTerminalOptions topts = { cols: 20, rows: 5 };
    ghostty_terminal_new(null, &term, topts);
    assert(term !is null);
    scope (exit) ghostty_terminal_free(term);
    ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_USERDATA, cast(const(void)*) &ctx);
    ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED,
        cast(const(void)*) &effect_title_changed);

    static immutable seq = "\x1b]2;hello\x07";
    ghostty_terminal_vt_write(term, cast(const(ubyte)*) seq.ptr, cast(uint) seq.length);
    assert(ctx.titleDirty);
    assert(ctx.titleBuf[0 .. ctx.titleLen] == "hello");
    assert(ctx.titleBuf[ctx.titleLen] == '\0');

    // A later change overwrites — the consumer only ever sees the newest —
    // and an overlong title truncates at the buffer, still NUL-terminated.
    static immutable char[300] aaa = 'a';
    static immutable longSeq = "\x1b]2;" ~ aaa ~ "\x07";
    ghostty_terminal_vt_write(term, cast(const(ubyte)*) longSeq.ptr, cast(uint) longSeq.length);
    assert(ctx.titleLen == ctx.titleBuf.length - 1);
    assert(ctx.titleBuf[0] == 'a' && ctx.titleBuf[ctx.titleLen] == '\0');
}
