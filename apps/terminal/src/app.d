module app;

import core.sys.posix.unistd;
import core.sys.posix.termios;
import core.sys.posix.sys.ioctl;
import core.sys.posix.fcntl;
import std.process : environment;
import std.string : toStringz;

import raylib;

import sparkles.ghostty.c;

extern(C) int forkpty(int *amaster, char *name, const termios *termp, const winsize *winp);

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
extern(C) void effect_write_pty(GhosttyTerminal terminal, void* userdata, const(ubyte)* data, size_t len) @nogc nothrow
{
    import input : pty_write;
    auto ctx = cast(EffectsContext*) userdata;
    pty_write(ctx.pty_fd, data, len);
}

// size: responds to XTWINOPS size queries (CSI 14/16/18 t).
extern(C) bool effect_size(GhosttyTerminal terminal, void* userdata, GhosttySizeReportSize* out_size) @nogc nothrow
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
extern(C) bool effect_device_attributes(GhosttyTerminal terminal, void* userdata, GhosttyDeviceAttributes* out_attrs) @nogc nothrow
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
extern(C) GhosttyString effect_xtversion(GhosttyTerminal terminal, void* userdata) @nogc nothrow
{
    static immutable name = "sparkles";
    return GhosttyString(cast(const(ubyte)*) name.ptr, name.length);
}

// enquiry: answerback for the ENQ control (0x05). We send nothing.
extern(C) GhosttyString effect_enquiry(GhosttyTerminal terminal, void* userdata) @nogc nothrow
{
    return GhosttyString(null, 0);
}

// title_changed: updates the window title on OSC 0 / OSC 2.
extern(C) void effect_title_changed(GhosttyTerminal terminal, void* userdata) @nogc nothrow
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
extern(C) bool effect_color_scheme(GhosttyTerminal terminal, void* userdata, GhosttyColorScheme* out_scheme) @nogc nothrow
{
    return false;
}

// bell: BEL (0x07) — trigger a brief screen flash as a visual bell.
extern(C) void effect_bell(GhosttyTerminal terminal, void* userdata) @nogc nothrow
{
    auto ctx = cast(EffectsContext*) userdata;
    ctx.bellFlashFrames = 4;
}

// decode_png: decodes raw PNG data into RGBA pixels using raylib's stb_image
// decoder so the terminal can display images via the Kitty Graphics Protocol.
// The output buffer is allocated through the provided GhosttyAllocator so the
// library can free it later. Installed process-globally via ghostty_sys_set.
extern(C) bool decode_png(void* userdata, GhosttyAllocator* allocator, const(ubyte)* data, size_t data_len, GhosttySysImage* outImg) @nogc nothrow
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

private void defer_unload_texture(Texture2D tex)
{
    if (deferred_texture_count < MAX_DEFERRED_TEXTURES)
        deferred_textures[deferred_texture_count++] = tex;
    else
        UnloadTexture(tex); // overflow fallback — may glitch but won't leak.
}

private void flush_deferred_textures()
{
    foreach (i; 0 .. deferred_texture_count)
        UnloadTexture(deferred_textures[i]);
    deferred_texture_count = 0;
}

// Draw all Kitty graphics placements for one z-layer. Deliberately simple and
// inefficient: every visible image is re-uploaded to the GPU each frame and
// freed right after (a real implementation would cache textures by image id).
// Mirrors ghostling's render_kitty_images; this port uses no grid padding.
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

bool fontHasGlyph(ref Font font, int codepoint) {
    if (font.glyphs == null) return false;
    for (int i = 0; i < font.glyphCount; i++) {
        if (font.glyphs[i].value == codepoint) {
            return true;
        }
    }
    return false;
}

int[] getRequiredCodepoints() {
    int[] cps;
    cps.reserve(10000);
    for (int i = 32; i <= 0xFF; i++) cps ~= i;
    // General Punctuation up to Misc Symbols and Arrows
    for (int i = 0x2000; i <= 0x2BFF; i++) cps ~= i;
    for (int i = 0xE0A0; i <= 0xE0D4; i++) cps ~= i;
    for (int i = 0xE200; i <= 0xE2A9; i++) cps ~= i;
    for (int i = 0xE300; i <= 0xE3E3; i++) cps ~= i;
    for (int i = 0xE5FA; i <= 0xE6B1; i++) cps ~= i;
    for (int i = 0xE700; i <= 0xE7C5; i++) cps ~= i;
    for (int i = 0xF000; i <= 0xF2E0; i++) cps ~= i;
    for (int i = 0xF300; i <= 0xF372; i++) cps ~= i;
    for (int i = 0xF400; i <= 0xF533; i++) cps ~= i;
    for (int i = 0xF500; i <= 0xFD46; i++) cps ~= i;
    return cps;
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

int main(string[] args)
{
    import std.getopt;
    import std.file : exists;
    import std.process : execute;
    import std.string : strip;
    import std.stdio : stderr, writeln;

    string fontOpt = "monospace";
    int fontSize = 20;
    bool debugScreenshotAndExit = false;

    auto helpInfo = getopt(
        args,
        "font|f", "Font path or name (e.g. '/path/to/font.ttf' or 'Fira Code')", &fontOpt,
        "size|s", "Font size in pixels (default: 20)", &fontSize,
        "debug-take-screenshot-and-exit", "Takes a screenshot after 2 seconds and exits", &debugScreenshotAndExit
    );

    if (helpInfo.helpWanted)
    {
        defaultGetoptPrinter("A minimal terminal emulator using libghostty-vt", helpInfo.options);
        return 0;
    }

    logBuildInfo();

    string fontPath = fontOpt;
    if (!fontPath.exists)
    {
        auto res = execute(["fc-match", "-f", "%{file}", fontOpt]);
        if (res.status == 0 && res.output.strip().length > 0)
        {
            fontPath = res.output.strip();
        }
    }

    if (!fontPath.exists)
    {
        stderr.writeln("Error: Could not resolve font '", fontOpt, "'. Please provide a valid path or installed font name.");
        return 1;
    }

    ushort cols = 100;
    ushort rows = 30;

    InitWindow(800, 600, "Sparkles Terminal");
    // Allow the user to resize the window; the loop recomputes the grid and
    // sends TIOCSWINSZ on IsWindowResized().
    SetWindowState(ConfigFlags.FLAG_WINDOW_RESIZABLE);
    SetTargetFPS(60);
    // Disable raylib's default "Escape closes the window" behavior — Esc must be
    // forwarded to the terminal application (vim, less, …) like any other key.
    SetExitKey(KeyboardKey.KEY_NULL);

    // Load Font
    import std.string : toStringz;
    int[] loadedCodepoints = getRequiredCodepoints();

    Font font = LoadFontEx(fontPath.toStringz, fontSize, loadedCodepoints.ptr, cast(int)loadedCodepoints.length);
    if (font.texture.id == 0)
    {
        stderr.writeln("Error: Raylib failed to load font: ", fontPath);
        CloseWindow();
        return 1;
    }

    Font regularFallback;
    bool hasRegularFallback = false;
    string regularFallbackPathStr = "";

    Font nerdFallback;
    bool hasNerdFallback = false;
    string nerdFallbackPathStr = "";

    auto fbRes = execute(["fc-match", "-f", "%{file}\\n", "monospace", "-s"]);
    if (fbRes.status == 0) {
        import std.algorithm : canFind;
        import std.string : splitLines;
        foreach (line; fbRes.output.splitLines()) {
            string path = line.strip().idup;
            if (path.length == 0 || path == fontPath) continue;

            bool isNerd = path.canFind("NerdFont") || path.canFind("Nerd Font");
            if (isNerd && !hasNerdFallback) {
                nerdFallbackPathStr = path;
                nerdFallback = LoadFontEx(nerdFallbackPathStr.toStringz, fontSize, loadedCodepoints.ptr, cast(int)loadedCodepoints.length);
                if (nerdFallback.texture.id != 0) hasNerdFallback = true;
            } else if (!isNerd && !hasRegularFallback && (path.canFind("DejaVu") || path.canFind("FreeMono") || path.canFind("LiberationMono"))) {
                regularFallbackPathStr = path;
                regularFallback = LoadFontEx(regularFallbackPathStr.toStringz, fontSize, loadedCodepoints.ptr, cast(int)loadedCodepoints.length);
                if (regularFallback.texture.id != 0) hasRegularFallback = true;
            }

            if (hasNerdFallback && hasRegularFallback) break;
        }
    }

    Vector2 mSize = MeasureTextEx(font, "M", fontSize, 0);
    int cellWidth = cast(int)mSize.x;
    int cellHeight = cast(int)mSize.y;
    // Guard against a zero-sized cell (degenerate font metrics): every grid
    // computation below divides by these, so a 0 would mean division by zero.
    if (cellWidth < 1) cellWidth = 1;
    if (cellHeight < 1) cellHeight = 1;
    SetWindowSize(cols * cellWidth, rows * cellHeight);

    // Install the PNG decoder via the sys interface so the terminal can handle
    // PNG images in the Kitty Graphics Protocol. This is process-global and
    // must be done before any terminal is created.
    ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, cast(const(void)*)&decode_png);

    GhosttyTerminal terminal;
    GhosttyTerminalOptions opts = { cols: cols, rows: rows, max_scrollback: 1000 };
    ghostty_terminal_new(null, &terminal, opts);

    int pty_fd = -1;

    winsize ws = {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: cast(ushort)(cols * cellWidth),
        ws_ypixel: cast(ushort)(rows * cellHeight),
    };
    pid_t child = forkpty(&pty_fd, null, null, &ws);

    if (child < 0)
    {
        stderr.writeln("Error: forkpty failed to spawn the shell.");
        UnloadFont(font);
        if (hasRegularFallback) UnloadFont(regularFallback);
        if (hasNerdFallback) UnloadFont(nerdFallback);
        ghostty_terminal_free(terminal);
        CloseWindow();
        return 1;
    }

    if (child == 0)
    {
        import core.sys.posix.stdlib : setenv;
        setenv("TERM", "xterm-256color", 1);
        string shell = environment.get("SHELL", null);
        if (shell.length == 0)
        {
            import core.sys.posix.pwd : getpwuid, passwd;
            import core.sys.posix.unistd : getuid;
            import std.string : fromStringz;

            passwd* pw = getpwuid(getuid());
            if (pw && pw.pw_shell)
            {
                shell = fromStringz(pw.pw_shell).idup;
            }
            if (shell.length == 0)
            {
                shell = "/bin/sh";
            }
        }

        import core.stdc.string : strrchr;
        const(char)* shell_ptr = shell.toStringz();
        const(char)* shell_name = strrchr(shell_ptr, '/');
        shell_name = shell_name ? shell_name + 1 : shell_ptr;

        execl(shell_ptr, shell_name, null);
        _exit(127);
    }

    // Parent: make the master fd non-blocking so read() returns EAGAIN instead
    // of stalling the render loop when there's no pending output.
    int flags = fcntl(pty_fd, F_GETFL);
    if (flags < 0 || fcntl(pty_fd, F_SETFL, flags | O_NONBLOCK) < 0)
    {
        stderr.writeln("Error: failed to set the pty master non-blocking.");
        UnloadFont(font);
        if (hasRegularFallback) UnloadFont(regularFallback);
        if (hasNerdFallback) UnloadFont(nerdFallback);
        ghostty_terminal_free(terminal);
        CloseWindow();
        return 1;
    }

    // Register effects so the terminal can respond to the VT queries that
    // programs like vim, tmux, and htop send at startup (device attributes,
    // size, xtversion, …). Without these, those queries are silently dropped
    // and the programs may hang or fall back to degraded behavior.
    EffectsContext effects_ctx = {
        pty_fd: pty_fd,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        cols: cols,
        rows: rows,
    };
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, cast(const(void)*)&effects_ctx);
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, cast(const(void)*)&effect_write_pty);
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SIZE, cast(const(void)*)&effect_size);
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, cast(const(void)*)&effect_device_attributes);
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_XTVERSION, cast(const(void)*)&effect_xtversion);
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_ENQUIRY, cast(const(void)*)&effect_enquiry);
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, cast(const(void)*)&effect_title_changed);
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, cast(const(void)*)&effect_color_scheme);
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_BELL, cast(const(void)*)&effect_bell);

    // Enable Kitty graphics: a storage limit is required (otherwise the terminal
    // rejects all image data), plus the file / temp-file / shared-memory
    // transmission mediums in addition to the default inline medium.
    ulong kitty_storage_limit = 64 * 1024 * 1024; // 64 MiB
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &kitty_storage_limit);
    bool kitty_medium = true;
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE, &kitty_medium);
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE, &kitty_medium);
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM, &kitty_medium);

    GhosttyRenderState render_state;
    ghostty_render_state_new(null, &render_state);

    GhosttyRenderStateRowIterator row_iter;
    ghostty_render_state_row_iterator_new(null, &row_iter);

    GhosttyRenderStateRowCells cells;
    ghostty_render_state_row_cells_new(null, &cells);

    GhosttyKittyGraphicsPlacementIterator placement_iter;
    ghostty_kitty_graphics_placement_iterator_new(null, &placement_iter);

    GhosttyKeyEvent key_event;
    ghostty_key_event_new(null, &key_event);
    GhosttyKeyEncoder key_encoder;
    ghostty_key_encoder_new(null, &key_encoder);

    GhosttyMouseEvent mouse_event;
    ghostty_mouse_event_new(null, &mouse_event);
    GhosttyMouseEncoder mouse_encoder;
    ghostty_mouse_encoder_new(null, &mouse_encoder);

    import input : SelectionState, ScrollbarState, HoverState;
    SelectionState selState;
    ScrollbarState sbState;
    HoverState hoverState;

    char[4096] pty_buf;

    // Initialize from the actual window state to avoid a spurious focus event
    // on the first frame.
    bool prev_focused = IsWindowFocused();

    while (!WindowShouldClose())
    {
        import input : handle_input, handle_mouse, pty_write;

        handle_input(pty_fd, key_encoder, key_event, terminal, selState);
        handle_mouse(pty_fd, mouse_encoder, mouse_event, terminal, cellWidth, cellHeight, selState, sbState, hoverState);

        if (hoverState.isHoveringUrl) {
            SetMouseCursor(MouseCursor.MOUSE_CURSOR_POINTING_HAND);
        } else {
            SetMouseCursor(MouseCursor.MOUSE_CURSOR_DEFAULT);
        }

        // Focus in/out reporting (DECSET 1004). Only emit when the application
        // has enabled focus events, otherwise we'd inject stray CSI I / CSI O
        // into shells that never asked for them. GHOSTTY_MODE_FOCUS_EVENT is
        // ghostty_mode_new(1004, false), which for a DEC private mode is 1004.
        bool focused = IsWindowFocused();
        if (focused != prev_focused) {
            bool focus_mode = false;
            if (ghostty_terminal_mode_get(terminal, cast(GhosttyMode) 1004, &focus_mode) == GHOSTTY_SUCCESS && focus_mode) {
                char[8] fbuf;
                size_t fwritten = 0;
                auto fev = focused ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST;
                if (ghostty_focus_encode(fev, fbuf.ptr, fbuf.length, &fwritten) == GHOSTTY_SUCCESS && fwritten > 0)
                    pty_write(pty_fd, fbuf.ptr, fwritten);
            }
            prev_focused = focused;
        }

        // Drain all output currently available from the pty in one frame.
        // The master fd is non-blocking, so we read in a loop until EAGAIN
        // (kernel buffer empty) instead of once per frame — a single read
        // would cap throughput and make fast output (cat, yes) crawl.
        bool eof = false;
        while (true)
        {
            auto n = read(pty_fd, pty_buf.ptr, pty_buf.length);
            if (n > 0)
            {
                ghostty_terminal_vt_write(terminal, cast(const(ubyte)*)pty_buf.ptr, cast(uint)n);
            }
            else if (n == 0)
            {
                eof = true; // Child closed its end of the pty (EOF).
                break;
            }
            else
            {
                import core.stdc.errno : errno, EAGAIN, EWOULDBLOCK, EINTR;
                if (errno == EAGAIN || errno == EWOULDBLOCK)
                    break; // Nothing more available this frame.
                if (errno == EINTR)
                    continue; // Interrupted by a signal — retry the read.
                eof = true; // EIO (slave closed on Linux) or a real error.
                break;
            }
        }
        if (eof)
            break;

        // Font size control
        bool fontChanged = false;
        if ((IsKeyDown(KeyboardKey.KEY_LEFT_CONTROL) || IsKeyDown(KeyboardKey.KEY_RIGHT_CONTROL)) && IsKeyPressed(KeyboardKey.KEY_EQUAL)) {
            fontSize += 2;
            fontChanged = true;
        }
        else if ((IsKeyDown(KeyboardKey.KEY_LEFT_CONTROL) || IsKeyDown(KeyboardKey.KEY_RIGHT_CONTROL)) && IsKeyPressed(KeyboardKey.KEY_MINUS)) {
            if (fontSize > 6) {
                fontSize -= 2;
                fontChanged = true;
            }
        }

        if (fontChanged) {
            UnloadFont(font);
            font = LoadFontEx(fontPath.toStringz, fontSize, loadedCodepoints.ptr, cast(int)loadedCodepoints.length);
            if (hasRegularFallback) {
                UnloadFont(regularFallback);
                regularFallback = LoadFontEx(regularFallbackPathStr.toStringz, fontSize, loadedCodepoints.ptr, cast(int)loadedCodepoints.length);
            }
            if (hasNerdFallback) {
                UnloadFont(nerdFallback);
                nerdFallback = LoadFontEx(nerdFallbackPathStr.toStringz, fontSize, loadedCodepoints.ptr, cast(int)loadedCodepoints.length);
            }
            mSize = MeasureTextEx(font, "M", fontSize, 0);
            cellWidth = cast(int)mSize.x;
            cellHeight = cast(int)mSize.y;
            if (cellWidth < 1) cellWidth = 1;
            if (cellHeight < 1) cellHeight = 1;
        }

        if (fontChanged || IsWindowResized()) {
            cols = cast(ushort)(GetScreenWidth() / cellWidth);
            rows = cast(ushort)(GetScreenHeight() / cellHeight);
            if (cols == 0) cols = 1;
            if (rows == 0) rows = 1;

            ghostty_terminal_resize(terminal, cols, rows, cellWidth, cellHeight);
            // Keep the effects context in sync so size/DA reports are accurate.
            effects_ctx.cols = cols;
            effects_ctx.rows = rows;
            effects_ctx.cellWidth = cellWidth;
            effects_ctx.cellHeight = cellHeight;
            winsize new_ws = {
                ws_row: rows,
                ws_col: cols,
                ws_xpixel: cast(ushort)(cols * cellWidth),
                ws_ypixel: cast(ushort)(rows * cellHeight),
            };
            ioctl(pty_fd, TIOCSWINSZ, &new_ws);
        }

        // Update render state
        ghostty_render_state_update(render_state, terminal);

        BeginDrawing();
        ClearBackground(Colors.BLACK);

        // Obtain the Kitty graphics storage (a borrowed pointer valid until the
        // next mutating terminal call). Images are drawn in three z-layers:
        // below backgrounds, below text, and above text.
        GhosttyKittyGraphics kitty_gfx = null;
        bool has_kitty = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &kitty_gfx) == GHOSTTY_SUCCESS && kitty_gfx !is null;
        if (has_kitty)
            render_kitty_images(terminal, kitty_gfx, placement_iter, cellWidth, cellHeight, GHOSTTY_KITTY_PLACEMENT_LAYER_BELOW_BG);

        GhosttyPointCoordinate sel_start_pt, sel_end_pt;
        bool has_selection = false;
        if (selState.start && selState.end) {
            if (ghostty_tracked_grid_ref_point(selState.start, GHOSTTY_POINT_TAG_VIEWPORT, &sel_start_pt) == GHOSTTY_SUCCESS &&
                ghostty_tracked_grid_ref_point(selState.end, GHOSTTY_POINT_TAG_VIEWPORT, &sel_end_pt) == GHOSTTY_SUCCESS) {
                has_selection = true;

                // ensure start is before end
                if (sel_start_pt.y > sel_end_pt.y || (sel_start_pt.y == sel_end_pt.y && sel_start_pt.x > sel_end_pt.x)) {
                    auto temp = sel_start_pt;
                    sel_start_pt = sel_end_pt;
                    sel_end_pt = temp;
                }
            }
        }

        ghostty_render_state_get(render_state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &row_iter);

        int y = 0;
        while (ghostty_render_state_row_iterator_next(row_iter))
        {
            ghostty_render_state_row_get(row_iter, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells);

            BeginScissorMode(0, y, GetScreenWidth(), cellHeight);

            int x = 0;
            while (ghostty_render_state_row_cells_next(cells))
            {
                uint grapheme_len;
                ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &grapheme_len);

                if (grapheme_len > 0)
                {
                    uint[16] codepoints;
                    ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, codepoints.ptr);

                    // Get background color
                    GhosttyColorRgb bg_rgb;
                    ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg_rgb);

                    // Get foreground color
                    GhosttyColorRgb fg_rgb = { r: 255, g: 255, b: 255 }; // Default fallback
                    ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg_rgb);

                    Color bg_col = Color(bg_rgb.r, bg_rgb.g, bg_rgb.b, 255);
                    Color fg_col = Color(fg_rgb.r, fg_rgb.g, fg_rgb.b, 255);

                    // Read the cell style for SGR attribute flags. Colors are
                    // already resolved above via the FG/BG_COLOR queries.
                    GhosttyStyle style;
                    style.size = GhosttyStyle.sizeof;
                    ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);

                    // Reverse video: swap fg/bg up front so the selection and
                    // hovered-link swaps below compose on top of it correctly.
                    if (style.inverse) {
                        Color inv = bg_col;
                        bg_col = fg_col;
                        fg_col = inv;
                    }

                    int cell_x = x / cellWidth;
                    int cell_y = y / cellHeight;

                    bool is_selected = false;
                    if (has_selection) {
                        if (selState.isRectangular) {
                            int min_x = sel_start_pt.x < sel_end_pt.x ? sel_start_pt.x : sel_end_pt.x;
                            int max_x = sel_start_pt.x > sel_end_pt.x ? sel_start_pt.x : sel_end_pt.x;
                            if (cell_y >= sel_start_pt.y && cell_y <= sel_end_pt.y && cell_x >= min_x && cell_x <= max_x) {
                                is_selected = true;
                            }
                        } else {
                            if (cell_y > sel_start_pt.y && cell_y < sel_end_pt.y) {
                                is_selected = true;
                            } else if (cell_y == sel_start_pt.y && cell_y == sel_end_pt.y) {
                                is_selected = cell_x >= sel_start_pt.x && cell_x <= sel_end_pt.x;
                            } else if (cell_y == sel_start_pt.y) {
                                is_selected = cell_x >= sel_start_pt.x;
                            } else if (cell_y == sel_end_pt.y) {
                                is_selected = cell_x <= sel_end_pt.x;
                            }
                        }
                    }

                    if (is_selected) {
                        Color tmp = bg_col;
                        bg_col = fg_col;
                        fg_col = tmp;
                    }

                    bool is_hovered_link = hoverState.isHoveringUrl && cell_y == hoverState.y && cell_x >= hoverState.start_x && cell_x <= hoverState.end_x;
                    if (is_hovered_link) {
                        Color tmp = bg_col;
                        bg_col = fg_col;
                        fg_col = tmp;
                    }

                    DrawRectangle(x, y, cellWidth, cellHeight, bg_col);

                    Font activeFont = font;
                    if (codepoints[0] >= 128) {
                        if (!fontHasGlyph(font, codepoints[0])) {
                            if (hasRegularFallback && fontHasGlyph(regularFallback, codepoints[0])) {
                                activeFont = regularFallback;
                            } else if (hasNerdFallback && fontHasGlyph(nerdFallback, codepoints[0])) {
                                activeFont = nerdFallback;
                            }
                        }
                    }

                    // Encode the whole grapheme cluster (base codepoint plus any
                    // combining marks, ZWJ joiners, variation selectors, …) into a
                    // single UTF-8 string and draw it as one unit. Drawing only
                    // codepoints[0] would drop accents and emoji modifiers.
                    import std.utf : encode;
                    import std.typecons : Yes;
                    char[64] text = void;
                    size_t text_len = 0;
                    const cp_count = grapheme_len < 16 ? grapheme_len : 16;
                    foreach (i; 0 .. cp_count) {
                        char[4] u8;
                        const u8n = encode!(Yes.useReplacementDchar)(u8, cast(dchar)codepoints[i]);
                        if (text_len + u8n >= text.length) break;
                        text[text_len .. text_len + u8n] = u8[0 .. u8n];
                        text_len += u8n;
                    }
                    text[text_len] = '\0';

                    // Italic: shift the glyph right by a fraction of the font
                    // size (a crude slant; raylib can't shear a glyph).
                    const italic_offset = style.italic ? (fontSize / 6) : 0;
                    DrawTextEx(activeFont, text.ptr, Vector2(cast(float)(x + italic_offset), cast(float)y), fontSize, 0, fg_col);

                    // Bold: redraw 1px to the right to thicken strokes (fake bold).
                    if (style.bold)
                        DrawTextEx(activeFont, text.ptr, Vector2(cast(float)(x + italic_offset + 1), cast(float)y), fontSize, 0, fg_col);

                    // Underline (any SGR underline style) and strikethrough.
                    if (style.underline != 0)
                        DrawRectangle(x, y + cellHeight - 2, cellWidth, 1, fg_col);
                    if (style.strikethrough)
                        DrawRectangle(x, y + cellHeight / 2, cellWidth, 1, fg_col);

                    GhosttyCell raw_cell;
                    bool has_hyperlink = false;
                    if (ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, cast(void*)&raw_cell) == GHOSTTY_SUCCESS) {
                        ghostty_cell_get(raw_cell, GHOSTTY_CELL_DATA_HAS_HYPERLINK, cast(void*)&has_hyperlink);
                    }

                    if (has_hyperlink || is_hovered_link) {
                        int thickness = is_hovered_link ? 2 : 1;
                        DrawRectangle(x, y + cellHeight - thickness, cellWidth, thickness, fg_col);
                    }
                }
                else
                {
                    // Empty cell with no text may still carry a background color
                    // (e.g. an erase with a color set). BG_COLOR returns
                    // INVALID_VALUE when the cell has no background.
                    GhosttyColorRgb bg_rgb;
                    if (ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg_rgb) == GHOSTTY_SUCCESS) {
                        DrawRectangle(x, y, cellWidth, cellHeight, Color(bg_rgb.r, bg_rgb.g, bg_rgb.b, 255));
                    }
                }

                x += cellWidth;
            }

            EndScissorMode();
            y += cellHeight;
        }

        // Images below text (drawn after cell backgrounds/text in this
        // single-pass renderer, but before the cursor and above-text images).
        if (has_kitty)
            render_kitty_images(terminal, kitty_gfx, placement_iter, cellWidth, cellHeight, GHOSTTY_KITTY_PLACEMENT_LAYER_BELOW_TEXT);

        // Render scrollbar
        GhosttyTerminalScrollbar sb;
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, cast(void*)&sb);

        if (sb.total > sb.len) {
            float track_height = cast(float)GetScreenHeight();
            float thumb_height = track_height * (cast(float)sb.len / cast(float)sb.total);
            if (thumb_height < 20.0f) thumb_height = 20.0f;

            float movable_pixels = track_height - thumb_height;
            long total_movable_rows = sb.total - sb.len;

            float thumb_y = 0.0f;
            if (total_movable_rows > 0)
                thumb_y = movable_pixels * (cast(float)sb.offset / cast(float)total_movable_rows);

            float w = sbState.currentWidth;
            float x = GetScreenWidth() - w;

            if (sbState.isHovered || sbState.isDragging) {
                DrawRectangle(cast(int)x, 0, cast(int)w, cast(int)track_height, Color(255, 255, 255, 30));
            }
            DrawRectangle(cast(int)x, cast(int)thumb_y, cast(int)w, cast(int)thumb_height, Color(255, 255, 255, 120));
        }

        // Draw the cursor
        bool cursor_visible = false;
        ghostty_render_state_get(render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, cast(void*)&cursor_visible);
        bool cursor_in_viewport = false;
        ghostty_render_state_get(render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, cast(void*)&cursor_in_viewport);

        if (cursor_visible && cursor_in_viewport) {
            ushort cx = 0, cy = 0;
            ghostty_render_state_get(render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, cast(void*)&cx);
            ghostty_render_state_get(render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, cast(void*)&cy);

            GhosttyRenderStateColors colors;
            colors.size = GhosttyRenderStateColors.sizeof;
            ghostty_render_state_colors_get(render_state, &colors);

            GhosttyColorRgb cur_rgb = colors.foreground;
            if (colors.cursor_has_value)
                cur_rgb = colors.cursor;

            int cursor_style = 1; // Block
            ghostty_render_state_get(render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, cast(void*)&cursor_style);

            int c_x = cx * cellWidth;
            int c_y = cy * cellHeight;
            Color c_color = Color(cur_rgb.r, cur_rgb.g, cur_rgb.b, 160);

            if (cursor_style == 0) // Bar
                DrawRectangle(c_x, c_y, 2, cellHeight, c_color);
            else if (cursor_style == 1) // Block
                DrawRectangle(c_x, c_y, cellWidth, cellHeight, c_color);
            else if (cursor_style == 2) // Underline
                DrawRectangle(c_x, c_y + cellHeight - 2, cellWidth, 2, c_color);
            else if (cursor_style == 3) // Hollow block
                DrawRectangleLines(c_x, c_y, cellWidth, cellHeight, c_color);
        }

        // Images above text (z >= 0): drawn last, over everything else.
        if (has_kitty)
            render_kitty_images(terminal, kitty_gfx, placement_iter, cellWidth, cellHeight, GHOSTTY_KITTY_PLACEMENT_LAYER_ABOVE_TEXT);

        // Visual bell: a brief translucent flash over the whole window.
        if (effects_ctx.bellFlashFrames > 0) {
            DrawRectangle(0, 0, GetScreenWidth(), GetScreenHeight(), Color(255, 255, 255, 40));
            effects_ctx.bellFlashFrames--;
        }

        EndDrawing();

        // Free textures uploaded during this frame's kitty rendering, now that
        // EndDrawing() has flushed all draw commands to the GPU.
        flush_deferred_textures();

        if (debugScreenshotAndExit) {
            static int frameCount = 0;
            frameCount++;
            if (frameCount == 120) {
                TakeScreenshot("test_screenshot.png".ptr);
            }
            if (frameCount == 130) {
                break;
            }
        }
    }

    UnloadFont(font);
    if (hasRegularFallback) UnloadFont(regularFallback);
    if (hasNerdFallback) UnloadFont(nerdFallback);
    ghostty_kitty_graphics_placement_iterator_free(placement_iter);
    ghostty_render_state_row_cells_free(cells);
    ghostty_render_state_row_iterator_free(row_iter);
    ghostty_render_state_free(render_state);

    ghostty_key_event_free(key_event);
    ghostty_key_encoder_free(key_encoder);
    ghostty_mouse_event_free(mouse_event);
    ghostty_mouse_encoder_free(mouse_encoder);

    selState.free();
    ghostty_terminal_free(terminal);
    CloseWindow();
    return 0;
}
