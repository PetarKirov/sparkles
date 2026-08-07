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

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.ghostty.c;
import sparkles.raylib_text : FontSet, LoadedFont, drawGrapheme, drawSolid,
    drawBox;
import sparkles.terminal_view.input : ExitBehavior, SelectionState,
    ScrollbarState, HoverState;
import sparkles.terminal_view.osc_query : OscScanner;

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

// title_changed: updates the window title on OSC 0 / OSC 2.
extern(C) nothrow @nogc
void effect_title_changed(GhosttyTerminal terminal, void* userdata)
{
    GhosttyString title;
    if (ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &title) != GHOSTTY_SUCCESS)
        return;

    import core.stdc.string : memcpy;
    char[256] buf;
    size_t n = title.len < buf.length - 1 ? title.len : buf.length - 1;
    if (n > 0) memcpy(buf.ptr, title.ptr, n);
    buf[n] = '\0';
    SetWindowTitle(buf.ptr);
}

// color_scheme: raylib can't query the OS scheme, so ignore the query.
extern(C) nothrow @nogc
bool effect_color_scheme(GhosttyTerminal terminal, void* userdata, GhosttyColorScheme* out_scheme)
{
    return false;
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

// Deferred texture cleanup: textures uploaded mid-frame can't be freed until
// after EndDrawing() flushes the draw commands to the GPU.
private enum MAX_DEFERRED_TEXTURES = 256;
private __gshared Texture2D[MAX_DEFERRED_TEXTURES] deferred_textures;
private __gshared int deferred_texture_count = 0;

@system nothrow @nogc
private void defer_unload_texture(Texture2D tex)
{
    if (deferred_texture_count < MAX_DEFERRED_TEXTURES)
        deferred_textures[deferred_texture_count++] = tex;
    else
        UnloadTexture(tex); // overflow fallback — may glitch but won't leak.
}

@system nothrow @nogc
void flush_deferred_textures()
{
    foreach (i; 0 .. deferred_texture_count)
        UnloadTexture(deferred_textures[i]);
    deferred_texture_count = 0;
}

// Draw all Kitty graphics placements for one z-layer. Deliberately simple and
// inefficient: every visible image is re-uploaded to the GPU each frame and
// freed right after (a real implementation would cache textures by image id).
// Mirrors ghostling's render_kitty_images; this port uses no grid padding.
@system nothrow @nogc
private void render_kitty_images(GhosttyTerminal terminal, GhosttyKittyGraphics graphics,
    GhosttyKittyGraphicsPlacementIterator placement_iter,
    int cellWidth, int cellHeight, GhosttyKittyPlacementLayer layer)
{
    // Filter the iterator to this layer, then repopulate it for the scan.
    ghostty_kitty_graphics_placement_iterator_set(placement_iter,
        GHOSTTY_KITTY_GRAPHICS_PLACEMENT_ITERATOR_OPTION_LAYER, &layer);
    if (ghostty_kitty_graphics_get(graphics, GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR, &placement_iter) != GHOSTTY_SUCCESS)
        return;

    while (ghostty_kitty_graphics_placement_next(placement_iter)) {
        uint image_id = 0;
        ghostty_kitty_graphics_placement_get(placement_iter, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID, &image_id);

        GhosttyKittyGraphicsImage image_handle = ghostty_kitty_graphics_image(graphics, image_id);
        if (image_handle is null) continue;

        // Viewport-relative position. NO_VALUE when off-screen or a virtual
        // placeholder placement, so both cases are skipped in one check.
        int vp_col = 0, vp_row = 0;
        if (ghostty_kitty_graphics_placement_viewport_pos(placement_iter, image_handle, terminal, &vp_col, &vp_row) != GHOSTTY_SUCCESS)
            continue;

        uint img_w = 0, img_h = 0;
        ghostty_kitty_graphics_image_get(image_handle, GHOSTTY_KITTY_IMAGE_DATA_WIDTH, &img_w);
        ghostty_kitty_graphics_image_get(image_handle, GHOSTTY_KITTY_IMAGE_DATA_HEIGHT, &img_h);
        if (img_w == 0 || img_h == 0) continue;

        GhosttyKittyImageFormat fmt = GHOSTTY_KITTY_IMAGE_FORMAT_RGBA;
        ghostty_kitty_graphics_image_get(image_handle, GHOSTTY_KITTY_IMAGE_DATA_FORMAT, &fmt);
        if (fmt != GHOSTTY_KITTY_IMAGE_FORMAT_RGBA) continue;

        const(ubyte)* data_ptr = null;
        size_t data_len = 0;
        ghostty_kitty_graphics_image_get(image_handle, GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR, &data_ptr);
        ghostty_kitty_graphics_image_get(image_handle, GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN, &data_len);
        if (data_ptr is null || data_len < cast(size_t) img_w * img_h * 4) continue;

        uint grid_cols = 0, grid_rows = 0;
        if (ghostty_kitty_graphics_placement_grid_size(placement_iter, image_handle, terminal, &grid_cols, &grid_rows) != GHOSTTY_SUCCESS)
            continue;
        if (grid_cols == 0 || grid_rows == 0) continue;

        uint dest_w = grid_cols * cast(uint) cellWidth;
        uint dest_h = grid_rows * cast(uint) cellHeight;

        // Resolved source rectangle (handles "0 = full image" and clamping).
        uint src_x = 0, src_y = 0, src_w = 0, src_h = 0;
        if (ghostty_kitty_graphics_placement_source_rect(placement_iter, image_handle, &src_x, &src_y, &src_w, &src_h) != GHOSTTY_SUCCESS)
            continue;

        uint x_offset = 0, y_offset = 0;
        ghostty_kitty_graphics_placement_get(placement_iter, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_X_OFFSET, &x_offset);
        ghostty_kitty_graphics_placement_get(placement_iter, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Y_OFFSET, &y_offset);

        Image img = {
            data: cast(void*) data_ptr,
            width: cast(int) img_w,
            height: cast(int) img_h,
            mipmaps: 1,
            format: PixelFormat.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
        };
        Texture2D tex = LoadTextureFromImage(img);
        SetTextureFilter(tex, TextureFilter.TEXTURE_FILTER_BILINEAR);

        int dest_x = cast(int) vp_col * cellWidth + cast(int) x_offset;
        int dest_y = cast(int) vp_row * cellHeight + cast(int) y_offset;

        Rectangle src_rect = Rectangle(cast(float) src_x, cast(float) src_y, cast(float) src_w, cast(float) src_h);
        Rectangle dst_rect = Rectangle(cast(float) dest_x, cast(float) dest_y, cast(float) dest_w, cast(float) dest_h);
        DrawTexturePro(tex, src_rect, dst_rect, Vector2(0, 0), 0.0f, Color(255, 255, 255, 255));

        defer_unload_texture(tex);
    }
}

// Per-cell render data resolved by `resolveCell` and consumed by both passes of
// the two-pass renderer (backgrounds first, then glyphs).
struct ResolvedCell
{
    bool hasGrapheme;     // cell has a grapheme cluster to draw
    uint graphemeLen;
    uint[16] codepoints;
    GhosttyStyle style;
    Color fgCol;
    Color bgCol;
    bool hasBg;           // a background rect should be painted for this cell
    bool isHoveredLink;   // cell is under a hovered OSC 8 link (drawn underlined)
}

// Resolve one cell's colors, style, and grapheme into a `ResolvedCell`. Both the
// background pass and the glyph pass call this for the same cell so the
// selection / hovered-link / reverse-video swaps are computed identically in
// each — keeping the two passes from drifting out of sync. It re-queries the
// cell rather than caching across passes; the queries are cheap relative to the
// per-cell draw calls, and redraws only happen on dirty frames.
@system nothrow @nogc
private ResolvedCell resolveCell(
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

    uint graphemeLen;
    ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &graphemeLen);

    if (graphemeLen == 0)
    {
        // Empty cell with no text may still carry a background color (e.g. an
        // erase with a color set). BG_COLOR returns INVALID_VALUE otherwise.
        GhosttyColorRgb bgRgb;
        if (ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bgRgb) == GHOSTTY_SUCCESS)
        {
            r.bgCol = Color(bgRgb.r, bgRgb.g, bgRgb.b, 255);
            r.hasBg = true;
        }
        return r;
    }

    r.hasGrapheme = true;
    r.graphemeLen = graphemeLen;
    ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, r.codepoints.ptr);

    // Seed fg/bg from the terminal defaults; the per-cell queries overwrite them
    // only when the cell has an explicit color and return INVALID_VALUE otherwise.
    GhosttyColorRgb fgRgb = colors.foreground;
    ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fgRgb);

    GhosttyColorRgb bgRgb = colors.background;
    bool hasBg = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bgRgb) == GHOSTTY_SUCCESS;

    Color bgCol = Color(bgRgb.r, bgRgb.g, bgRgb.b, 255);
    Color fgCol = Color(fgRgb.r, fgRgb.g, fgRgb.b, 255);

    // Read the cell style for SGR attribute flags. Colors are already resolved
    // above via the FG/BG_COLOR queries.
    r.style.size = GhosttyStyle.sizeof;
    ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &r.style);

    // Reverse video: swap fg/bg up front so the selection/hover swap below
    // composes on top of it correctly.
    if (r.style.inverse)
    {
        Color inv = bgCol;
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
        Color tmp = bgCol;
        bgCol = fgCol;
        fgCol = tmp;
        hasBg = true;
    }

    r.fgCol = fgCol;
    r.bgCol = bgCol;
    r.hasBg = hasBg;
    r.isHoveredLink = isHoveredLink;
    return r;
}

// All per-run state the @nogc core loop touches. Holds non-copyable SmallBuffers
// (font glyph sets, hover URL), so it lives as a single stack-pinned instance in
// main() and is passed only by `ref`.
struct CoreState
{
    GhosttyTerminal terminal;
    GhosttyRenderState render_state;
    GhosttyRenderStateRowIterator row_iter;
    GhosttyRenderStateRowCells cells;
    GhosttyKittyGraphicsPlacementIterator placement_iter;
    GhosttyKeyEvent key_event;
    GhosttyKeyEncoder key_encoder;
    GhosttyMouseEvent mouse_event;
    GhosttyMouseEncoder mouse_encoder;

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
    ScrollbarState sbState;
    HoverState hoverState;

    // Streaming OSC scanner answering OSC 10/11/12 color queries (see
    // feedPtyChunk); persists across pty read chunks.
    OscScanner oscScan;

    // Child-process lifecycle. childExited is set when the pty signals EOF/EIO;
    // childReaped once waitpid() collects the exit status.
    bool childExited;
    bool childReaped;
    int childStatus = -1;
}

// Log compile-time build info from libghostty-vt so we can quickly tell whether
// the library was built with SIMD and in which optimization mode.
void logBuildInfo()
{
    bool simd = false;
    ghostty_build_info(GHOSTTY_BUILD_INFO_SIMD, &simd);

    GhosttyOptimizeMode opt = GHOSTTY_OPTIMIZE_DEBUG;
    ghostty_build_info(GHOSTTY_BUILD_INFO_OPTIMIZE, &opt);

    const(char)* opt_str;
    switch (opt) {
        case GHOSTTY_OPTIMIZE_DEBUG:         opt_str = "Debug".ptr;        break;
        case GHOSTTY_OPTIMIZE_RELEASE_SAFE:  opt_str = "ReleaseSafe".ptr;  break;
        case GHOSTTY_OPTIMIZE_RELEASE_SMALL: opt_str = "ReleaseSmall".ptr; break;
        case GHOSTTY_OPTIMIZE_RELEASE_FAST:  opt_str = "ReleaseFast".ptr;  break;
        default:                             opt_str = "Unknown".ptr;      break;
    }

    TraceLog(TraceLogLevel.LOG_INFO, "ghostty-vt: simd:     %s", simd ? "enabled".ptr : "disabled".ptr);
    TraceLog(TraceLogLevel.LOG_INFO, "ghostty-vt: optimize: %s", opt_str);
}

// Write an xterm-style color report for `code` (10/11/12) to the pty:
// `ESC ] code ; rgb:rrrr/gggg/bbbb` plus the query's own terminator, 16 bits
// per channel (value × 257) — Ghostty's default report format. The cursor
// color falls back to the foreground when unset, as in Ghostty.
@system nothrow @nogc
void replyColorQuery(ref CoreState s, int code)
{
    import core.stdc.stdio : snprintf;
    import sparkles.terminal_view.input : pty_write;

    GhosttyColorRgb rgb;
    const data = code == 11 ? GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND
        : code == 12 ? GHOSTTY_TERMINAL_DATA_COLOR_CURSOR
        : GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND;
    if (ghostty_terminal_get(s.terminal, data, &rgb) != GHOSTTY_SUCCESS
        && (code != 12
            || ghostty_terminal_get(s.terminal, GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND, &rgb) != GHOSTTY_SUCCESS))
        return;

    char[48] buf;
    const len = snprintf(buf.ptr, buf.length, "\x1b]%d;rgb:%04x/%04x/%04x%s",
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
    foreach (i, b; chunk)
    {
        if (oscScanByte(s.oscScan, b))
        {
            ghostty_terminal_vt_write(s.terminal,
                cast(const(ubyte)*) chunk.ptr + segStart, cast(uint)(i + 1 - segStart));
            segStart = i + 1;
            if (!s.oscScan.overflowed)
            {
                SmallBuffer!(int, 4, true) codes;
                oscColorQueryCodes(s.oscScan.payload[], codes);
                foreach (code; codes[])
                    replyColorQuery(s, code);
            }
        }
    }
    if (segStart < chunk.length)
        ghostty_terminal_vt_write(s.terminal,
            cast(const(ubyte)*) chunk.ptr + segStart, cast(uint)(chunk.length - segStart));
}

// The frame's draw calls, bracket-free — callable from a raylib
// BeginDrawing/EndDrawing pair or from a host's draw
// phase (`HST13`), which owns its own bracket: background fill, kitty image
// layers, the two-pass cell render, scrollbar, cursor styles, exit banner,
// bell flash, and the per-row + global dirty reset. The caller owns the
// bracket and the deferred-texture flush (textures freed only after the
// bracket's commands reach the GPU).
@system nothrow @nogc
void paintFrame(ref CoreState s)
{
        // Resolved default colors (used for the background fill, default cell
        // colors, and the cursor) instead of hardcoded white-on-black.
        GhosttyRenderStateColors colors;
        colors.size = GhosttyRenderStateColors.sizeof;
        ghostty_render_state_colors_get(s.render_state, &colors);

        // The page: a full-surface fill rather than ClearBackground, because
        // inside a host's bracket the clear already happened (to the host's
        // page) and clearing is not a draw call the hook may make.
        drawSolid(s.fonts.whiteFace, 0, 0, GetScreenWidth(), GetScreenHeight(),
            Color(colors.background.r, colors.background.g, colors.background.b, 255));

        // Kitty graphics storage (borrowed; valid until the next mutating
        // terminal call). Images draw in three z-layers around the text.
        GhosttyKittyGraphics kitty_gfx = null;
        bool has_kitty = ghostty_terminal_get(s.terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &kitty_gfx) == GHOSTTY_SUCCESS && kitty_gfx !is null;
        if (has_kitty)
            render_kitty_images(s.terminal, kitty_gfx, s.placement_iter, s.cellWidth, s.cellHeight, GHOSTTY_KITTY_PLACEMENT_LAYER_BELOW_BG);

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
        // every background lands before any glyph is drawn. Both passes resolve
        // each cell via `resolveCell` so selection/hover/inverse stay identical.

        // --- Pass 1: backgrounds. ---
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
                if (rc.hasBg)
                    drawSolid(s.fonts.whiteFace, bgX, bgY, s.cellWidth, s.cellHeight, rc.bgCol);
                bgX += s.cellWidth;
            }

            bgY += s.cellHeight;
        }

        // --- Pass 2: glyphs and per-cell decorations. Re-fetching the row
        //     iterator rewinds it to the first row. ---
        ghostty_render_state_get(s.render_state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &s.row_iter);
        int y = 0;
        while (ghostty_render_state_row_iterator_next(s.row_iter))
        {
            ghostty_render_state_row_get(s.row_iter, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &s.cells);

            int x = 0;
            while (ghostty_render_state_row_cells_next(s.cells))
            {
                const rc = resolveCell(s.cells, colors, x / s.cellWidth, y / s.cellHeight,
                    has_selection, sel_start_pt, sel_end_pt, s.selState, s.hoverState);

                if (rc.hasGrapheme)
                {
                    // Draw the whole grapheme cluster (base codepoint plus any
                    // combining marks, ZWJ joiners, variation selectors, …) as one
                    // unit. Drawing only codepoints[0] would drop accents and emoji
                    // modifiers.
                    const cp_count = rc.graphemeLen < 16 ? rc.graphemeLen : 16;

                    // A single box-drawing codepoint is rendered procedurally so its
                    // arms fill the cell and connect across neighbouring cells (font
                    // glyphs leave gaps); everything else goes through the face-
                    // routing + fake-bold/italic glyph path.
                    if (cp_count != 1 || !drawBox(s.fonts.whiteFace, rc.codepoints[0],
                            cast(float) x, cast(float) y, s.cellWidth, s.cellHeight, rc.fgCol))
                    {
                        // Route the cell's base codepoint to its face — codepoint-map
                        // override → real bold/italic face → regular/Nerd fallback →
                        // on-demand request — all in the shared library (identical
                        // routing to the pre-extraction inline version).
                        bool fakeBold, fakeItalic;
                        LoadedFont* activeFont = s.fonts.resolveFace(
                            rc.codepoints[0], rc.style.bold, rc.style.italic, fakeBold, fakeItalic);

                        // Fake italic only when no real italic face is in use: shift
                        // the glyph right by a fraction of the font size (a crude
                        // slant; raylib can't shear a glyph).
                        const italic_offset = fakeItalic ? (s.fontSize / 6) : 0;
                        drawGrapheme(*activeFont, rc.codepoints[0 .. cp_count],
                            cast(float)(x + italic_offset), cast(float)y, s.fontSize, rc.fgCol);

                        // Fake bold only when no real bold face is in use: redraw 1px
                        // to the right to thicken strokes.
                        if (fakeBold)
                            drawGrapheme(*activeFont, rc.codepoints[0 .. cp_count],
                                cast(float)(x + italic_offset + 1), cast(float)y, s.fontSize, rc.fgCol);
                    }

                    // Underline (any SGR underline style) and strikethrough.
                    if (rc.style.underline != 0)
                        drawSolid(s.fonts.whiteFace, x, y + s.cellHeight - 2, s.cellWidth, 1, rc.fgCol);
                    if (rc.style.strikethrough)
                        drawSolid(s.fonts.whiteFace, x, y + s.cellHeight / 2, s.cellWidth, 1, rc.fgCol);

                    GhosttyCell raw_cell;
                    bool has_hyperlink = false;
                    if (ghostty_render_state_row_cells_get(s.cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, cast(void*)&raw_cell) == GHOSTTY_SUCCESS)
                        ghostty_cell_get(raw_cell, GHOSTTY_CELL_DATA_HAS_HYPERLINK, cast(void*)&has_hyperlink);

                    if (has_hyperlink || rc.isHoveredLink)
                    {
                        int thickness = rc.isHoveredLink ? 2 : 1;
                        drawSolid(s.fonts.whiteFace, x, y + s.cellHeight - thickness, s.cellWidth, thickness, rc.fgCol);
                    }
                }

                x += s.cellWidth;
            }

            // Clear this row's dirty flag now that it has been drawn.
            bool rowClean = false;
            ghostty_render_state_row_set(s.row_iter, GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &rowClean);

            y += s.cellHeight;
        }

        // Images below text (drawn after cell backgrounds/text, but before the
        // cursor and above-text images).
        if (has_kitty)
            render_kitty_images(s.terminal, kitty_gfx, s.placement_iter, s.cellWidth, s.cellHeight, GHOSTTY_KITTY_PLACEMENT_LAYER_BELOW_TEXT);

        // Render scrollbar
        GhosttyTerminalScrollbar sb;
        ghostty_terminal_get(s.terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, cast(void*)&sb);

        if (sb.total > sb.len)
        {
            float track_height = cast(float)GetScreenHeight();
            float thumb_height = track_height * (cast(float)sb.len / cast(float)sb.total);
            if (thumb_height < 20.0f) thumb_height = 20.0f;

            float movable_pixels = track_height - thumb_height;
            long total_movable_rows = sb.total - sb.len;

            float thumb_y = 0.0f;
            if (total_movable_rows > 0)
                thumb_y = movable_pixels * (cast(float)sb.offset / cast(float)total_movable_rows);

            float w = s.sbState.currentWidth;
            float x = GetScreenWidth() - w;

            if (s.sbState.isHovered || s.sbState.isDragging)
                DrawRectangle(cast(int)x, 0, cast(int)w, cast(int)track_height, Color(255, 255, 255, 30));
            DrawRectangle(cast(int)x, cast(int)thumb_y, cast(int)w, cast(int)thumb_height, Color(255, 255, 255, 120));
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
        if (has_kitty)
            render_kitty_images(s.terminal, kitty_gfx, s.placement_iter, s.cellWidth, s.cellHeight, GHOSTTY_KITTY_PLACEMENT_LAYER_ABOVE_TEXT);

        // Banner shown once the child has exited, so the user knows the shell
        // is gone (they can still scroll / inspect the final output).
        if (s.childExited)
        {
            import core.stdc.stdio : snprintf;
            char[128] msg;
            if (s.childReaped && s.childStatus >= 0)
                snprintf(msg.ptr, msg.length, "[process exited with status %d]", s.childStatus);
            else
                snprintf(msg.ptr, msg.length, "[process exited]");

            Vector2 msgSize = MeasureTextEx(s.fonts.primaryFont(), msg.ptr, s.fontSize, 0);
            int screenW = GetScreenWidth();
            int screenH = GetScreenHeight();
            int bannerH = cast(int) msgSize.y + 8;
            DrawRectangle(0, screenH - bannerH, screenW, bannerH, Color(0, 0, 0, 180));
            DrawTextEx(s.fonts.primaryFont(), msg.ptr, Vector2((screenW - msgSize.x) / 2, screenH - bannerH + 4), s.fontSize, 0, Color(255, 255, 255, 255));
        }

        // Visual bell: a brief translucent flash over the whole window.
        if (s.effects_ctx.bellFlashFrames > 0)
        {
            DrawRectangle(0, 0, GetScreenWidth(), GetScreenHeight(), Color(255, 255, 255, 40));
            s.effects_ctx.bellFlashFrames--;
        }

        // Reset global dirty state so the next update reports changes accurately.
        GhosttyRenderStateDirty clean_state = GHOSTTY_RENDER_STATE_DIRTY_FALSE;
        ghostty_render_state_set(s.render_state, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &clean_state);
}
