module app;

import core.sys.posix.unistd;
import core.sys.posix.sys.types : pid_t;
import core.sys.posix.termios;
import core.sys.posix.sys.ioctl;
import core.sys.posix.fcntl;
import std.string : toStringz;

import raylib;

import sparkles.ghostty.c;
import sparkles.base.smallbuffer : SmallBuffer;
import input : ExitBehavior, SelectionState, ScrollbarState, HoverState;

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
extern(C) nothrow @nogc
void effect_write_pty(GhosttyTerminal terminal, void* userdata, const(ubyte)* data, size_t len)
{
    import input : pty_write;
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

// A loaded raylib font plus a sorted set of the codepoints it actually has a
// glyph for, so glyph lookups are an O(log n) binary search instead of a linear
// scan of every glyph per cell per frame. NUL-terminated `pathZ` lets the core
// loop reload the font on a font-size change without touching the GC.
struct LoadedFont
{
    Font font;
    SmallBuffer!(int, 256) glyphValues;  // ascending codepoint values present
    SmallBuffer!(int, 256) glyphIndices; // font.glyphs index aligned with glyphValues
    int fallbackIndex;                   // index of the '?' glyph (value 63), or 0
    const(char)* pathZ;
    bool present;
}

// (Re)load `lf` from `lf.pathZ` at `fontSize`, requesting `cps`, and rebuild its
// sorted glyph-value set. Unloads any previously loaded font first.
@system nothrow @nogc
private void loadFontInto(ref LoadedFont lf, int fontSize, const(int)[] cps)
{
    if (lf.present)
    {
        UnloadFont(lf.font);
        lf.present = false;
    }
    if (lf.pathZ is null)
        return;

    lf.font = LoadFontEx(lf.pathZ, fontSize, cps.ptr, cast(int) cps.length);
    lf.present = lf.font.texture.id != 0;

    // Rebuild the sorted (codepoint -> glyph-index) map. raylib does not
    // guarantee ascending glyph order, so copy the value/index pairs then
    // insertion-sort by value, carrying the indices in parallel (done at most a
    // few times: at startup and on each font-size change). The map lets the core
    // loop look up a glyph in O(log n) instead of paying raylib's O(glyphCount)
    // GetGlyphIndex linear scan per codepoint per cell per frame.
    lf.glyphValues.clear();
    lf.glyphIndices.clear();
    lf.fallbackIndex = 0;
    if (lf.present && lf.font.glyphs !is null)
    {
        foreach (i; 0 .. lf.font.glyphCount)
        {
            lf.glyphValues ~= lf.font.glyphs[i].value;
            lf.glyphIndices ~= i;
            if (lf.font.glyphs[i].value == 63) lf.fallbackIndex = i; // '?'
        }
        auto gv = lf.glyphValues[];
        auto gi = lf.glyphIndices[];
        foreach (i; 1 .. gv.length)
        {
            const v = gv[i];
            const vi = gi[i];
            size_t j = i;
            while (j > 0 && gv[j - 1] > v) { gv[j] = gv[j - 1]; gi[j] = gi[j - 1]; j--; }
            gv[j] = v;
            gi[j] = vi;
        }
    }
}

// O(log n) presence test over the sorted glyph-value set.
@safe pure nothrow @nogc
private bool fontHasGlyph(ref LoadedFont lf, int codepoint)
{
    import std.range : assumeSorted;
    return lf.glyphValues[].assumeSorted.contains(codepoint);
}

// O(log n) codepoint -> glyph-index lookup over the sorted map, falling back to
// the font's '?' glyph when the codepoint is absent (mirroring raylib's
// GetGlyphIndex fallback). Replaces that function's O(glyphCount) linear scan.
@safe pure nothrow @nogc
private int glyphIndexFor(ref LoadedFont lf, int codepoint)
{
    import std.range : assumeSorted;
    const lower = lf.glyphValues[].assumeSorted.lowerBound(codepoint).length;
    if (lower < lf.glyphValues.length && lf.glyphValues[][lower] == codepoint)
        return lf.glyphIndices[][lower];
    return lf.fallbackIndex;
}

// Draw a grapheme cluster (base codepoint plus any combining marks) at (x, y),
// glyph by glyph, using the O(log n) glyph-index map above. This is a drop-in
// replacement for raylib's DrawTextEx (spacing 0): it reproduces the same
// DrawTextCodepoint placement/advance math but avoids both GetGlyphIndex's
// linear scan and DrawTextEx's per-call UTF-8 re-decode.
@system nothrow @nogc
private void drawGrapheme(ref LoadedFont lf, scope const(uint)[] cps,
    float x, float y, int fontSize, Color tint)
{
    const font = lf.font;
    const float scale = font.baseSize > 0 ? cast(float) fontSize / font.baseSize : 1.0f;
    const float pad = cast(float) font.glyphPadding;

    float ox = x;
    foreach (cp; cps)
    {
        const idx = glyphIndexFor(lf, cast(int) cp);
        const Rectangle rec = font.recs[idx];

        // Whitespace and other zero-area glyphs draw nothing; just advance.
        if (rec.width > 0 && rec.height > 0)
        {
            const Rectangle src = Rectangle(
                rec.x - pad, rec.y - pad, rec.width + 2 * pad, rec.height + 2 * pad);
            const Rectangle dst = Rectangle(
                ox + font.glyphs[idx].offsetX * scale - pad * scale,
                y + font.glyphs[idx].offsetY * scale - pad * scale,
                (rec.width + 2 * pad) * scale,
                (rec.height + 2 * pad) * scale);
            DrawTexturePro(font.texture, src, dst, Vector2(0, 0), 0.0f, tint);
        }

        const adv = font.glyphs[idx].advanceX;
        ox += adv == 0 ? rec.width * scale : adv * scale;
    }
}

// Codepoints requested from every font. Built once at compile time (CTFE) into
// static read-only data, so there is no startup GC allocation and no GC root.
@safe pure nothrow
private int[] buildCodepoints()
{
    int[] cps;
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

private static immutable int[] loadedCodepoints = buildCodepoints();

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

    immutable(int)[] codepoints;

    int fontSize = 20;
    int cellWidth = 1;
    int cellHeight = 1;
    ushort cols;
    ushort rows;

    LoadedFont font;
    LoadedFont regularFallback;
    LoadedFont nerdFallback;

    SelectionState selState;
    ScrollbarState sbState;
    HoverState hoverState;

    // Child-process lifecycle. childExited is set when the pty signals EOF/EIO;
    // childReaped once waitpid() collects the exit status.
    bool childExited;
    bool childReaped;
    int childStatus = -1;
}

@system nothrow @nogc
private void freeFonts(ref CoreState s)
{
    if (s.font.present) { UnloadFont(s.font.font); s.font.present = false; }
    if (s.regularFallback.present) { UnloadFont(s.regularFallback.font); s.regularFallback.present = false; }
    if (s.nerdFallback.present) { UnloadFont(s.nerdFallback.font); s.nerdFallback.present = false; }
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

// One-time setup (CLI, fonts, terminal, pty). GC and exceptions are fine here;
// the steady-state work happens in the `nothrow @nogc` runCoreLoop below.
int main(string[] args)
{
    import std.getopt;
    import std.file : exists;
    import std.process : execute;
    import std.string : strip;
    import std.stdio : stderr, writeln;
    import input : parseExitBehavior;

    string fontOpt = "monospace";
    int fontSize = 20;
    bool debugScreenshotAndExit = false;
    string exitBehaviorOpt = "hold-on-failure";

    auto helpInfo = getopt(
        args,
        // Stop at the first non-option so a trailing command (and its own flags)
        // is left untouched: `terminal --size 14 -- vim file -R`.
        config.stopOnFirstNonOption,
        "font|f", "Font path or name (e.g. '/path/to/font.ttf' or 'Fira Code')", &fontOpt,
        "size|s", "Font size in pixels (default: 20)", &fontSize,
        "exit-behavior", "On child exit: close | wait-for-key | hold | hold-on-failure (default)", &exitBehaviorOpt,
        "debug-take-screenshot-and-exit", "Takes a screenshot after 2 seconds and exits", &debugScreenshotAndExit
    );

    if (helpInfo.helpWanted)
    {
        defaultGetoptPrinter(
            "A minimal terminal emulator using libghostty-vt.\n\n" ~
            "Usage: terminal [options] [-- command [args...]]\n\n" ~
            "With no command, the login shell runs interactively. With a command,\n" ~
            "the shell runs it via `-c` and then exits (e.g. `terminal -- vim file`).",
            helpInfo.options);
        return 0;
    }

    // Any arguments left after the options are an optional command to run in the
    // shell. A leading `--` separator is accepted and stripped. The command is
    // joined and passed to the shell via `-c`, so builtins, aliases, PATH
    // lookup, and pipes all work; the shell exits when the command finishes.
    string[] command = args[1 .. $];
    if (command.length && command[0] == "--")
        command = command[1 .. $];

    import std.array : join;
    const(char)* shellCommand = command.length ? command.join(" ").toStringz : null;

    logBuildInfo();

    string fontPath = fontOpt;
    if (!fontPath.exists)
    {
        auto res = execute(["fc-match", "-f", "%{file}", fontOpt]);
        if (res.status == 0 && res.output.strip().length > 0)
            fontPath = res.output.strip();
    }
    if (!fontPath.exists)
    {
        stderr.writeln("Error: Could not resolve font '", fontOpt, "'. Please provide a valid path or installed font name.");
        return 1;
    }

    CoreState s;
    s.fontSize = fontSize;
    s.cols = 100;
    s.rows = 30;
    s.exitBehavior = parseExitBehavior(exitBehaviorOpt);
    s.debugScreenshotAndExit = debugScreenshotAndExit;
    s.codepoints = loadedCodepoints;

    InitWindow(800, 600, "Sparkles Terminal");
    // Allow the user to resize the window; the loop recomputes the grid and
    // sends TIOCSWINSZ on IsWindowResized().
    SetWindowState(ConfigFlags.FLAG_WINDOW_RESIZABLE);
    SetTargetFPS(60);
    // Disable raylib's default "Escape closes the window" behavior — Esc must be
    // forwarded to the terminal application (vim, less, …) like any other key.
    SetExitKey(KeyboardKey.KEY_NULL);

    // Load the primary font (cache its NUL-terminated path for in-loop reloads).
    s.font.pathZ = fontPath.toStringz;
    loadFontInto(s.font, s.fontSize, s.codepoints);
    if (!s.font.present)
    {
        stderr.writeln("Error: Raylib failed to load font: ", fontPath);
        CloseWindow();
        return 1;
    }

    // Resolve fallback fonts via fc-match: the first Nerd Font and the first
    // common regular monospace, used when the primary lacks a glyph.
    auto fbRes = execute(["fc-match", "-f", "%{file}\\n", "monospace", "-s"]);
    if (fbRes.status == 0)
    {
        import std.algorithm : canFind;
        import std.string : splitLines;
        foreach (line; fbRes.output.splitLines())
        {
            string path = line.strip().idup;
            if (path.length == 0 || path == fontPath) continue;

            bool isNerd = path.canFind("NerdFont") || path.canFind("Nerd Font");
            if (isNerd && !s.nerdFallback.present)
            {
                s.nerdFallback.pathZ = path.toStringz;
                loadFontInto(s.nerdFallback, s.fontSize, s.codepoints);
            }
            else if (!isNerd && !s.regularFallback.present && (path.canFind("DejaVu") || path.canFind("FreeMono") || path.canFind("LiberationMono")))
            {
                s.regularFallback.pathZ = path.toStringz;
                loadFontInto(s.regularFallback, s.fontSize, s.codepoints);
            }

            if (s.nerdFallback.present && s.regularFallback.present) break;
        }
    }

    Vector2 mSize = MeasureTextEx(s.font.font, "M", s.fontSize, 0);
    s.cellWidth = cast(int) mSize.x;
    s.cellHeight = cast(int) mSize.y;
    // Guard against a zero-sized cell (degenerate font metrics): every grid
    // computation below divides by these, so a 0 would mean division by zero.
    if (s.cellWidth < 1) s.cellWidth = 1;
    if (s.cellHeight < 1) s.cellHeight = 1;
    SetWindowSize(s.cols * s.cellWidth, s.rows * s.cellHeight);

    // Install the PNG decoder via the sys interface so the terminal can handle
    // PNG images in the Kitty Graphics Protocol. This is process-global and
    // must be done before any terminal is created.
    ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, cast(const(void)*)&decode_png);

    GhosttyTerminalOptions opts = { cols: s.cols, rows: s.rows, max_scrollback: 1000 };
    ghostty_terminal_new(null, &s.terminal, opts);

    // The terminal options carry no cell pixel size, so set it up front with an
    // initial resize. Without this, kitty-graphics placement math and pixel-size
    // reports would see zero cell dimensions until the first window resize.
    ghostty_terminal_resize(s.terminal, s.cols, s.rows, s.cellWidth, s.cellHeight);

    // Resolve the shell and build argv in the PARENT, before forkpty, so the
    // forked child does only async-signal-safe work (execv + _exit) — no GC, no
    // getpwuid/setenv. Every fork here happens after InitWindow created GL and
    // window threads, so a GC allocation in the child could deadlock.
    import core.stdc.stdlib : getenv;
    import core.sys.posix.stdlib : setenv;
    import core.stdc.string : strrchr;
    const(char)* shellZ = getenv("SHELL".ptr);
    if (shellZ is null || *shellZ == '\0')
    {
        import core.sys.posix.pwd : getpwuid, passwd;
        passwd* pw = getpwuid(getuid());
        if (pw !is null && pw.pw_shell !is null && *pw.pw_shell != '\0')
            shellZ = pw.pw_shell;
        else
            shellZ = "/bin/sh".ptr;
    }
    const(char)* shellName = strrchr(shellZ, '/');
    shellName = shellName ? shellName + 1 : shellZ;

    // Set TERM in the parent; the child inherits the environment (so we don't
    // need a non-async-signal-safe setenv between fork and exec).
    setenv("TERM".ptr, "xterm-256color".ptr, 1);

    const(char)*[4] argv;
    if (shellCommand !is null)
        argv = [shellName, "-c".ptr, shellCommand, null];
    else
        argv = [shellName, null, null, null];

    winsize ws = {
        ws_row: s.rows,
        ws_col: s.cols,
        ws_xpixel: cast(ushort)(s.cols * s.cellWidth),
        ws_ypixel: cast(ushort)(s.rows * s.cellHeight),
    };
    s.child = forkpty(&s.pty_fd, null, null, &ws);

    if (s.child < 0)
    {
        stderr.writeln("Error: forkpty failed to spawn the shell.");
        freeFonts(s);
        ghostty_terminal_free(s.terminal);
        CloseWindow();
        return 1;
    }

    if (s.child == 0)
    {
        // Child: async-signal-safe only.
        execv(shellZ, cast(char**) argv.ptr);
        _exit(127);
    }

    // Parent: make the master fd non-blocking so read() returns EAGAIN instead
    // of stalling the render loop when there's no pending output.
    int flags = fcntl(s.pty_fd, F_GETFL);
    if (flags < 0 || fcntl(s.pty_fd, F_SETFL, flags | O_NONBLOCK) < 0)
    {
        stderr.writeln("Error: failed to set the pty master non-blocking.");
        // Reap the child we just forked so it doesn't linger.
        import core.sys.posix.signal : kill, SIGHUP;
        import core.sys.posix.sys.wait : waitpid;
        kill(s.child, SIGHUP);
        waitpid(s.child, null, 0);
        freeFonts(s);
        ghostty_terminal_free(s.terminal);
        CloseWindow();
        return 1;
    }

    // Register effects so the terminal can respond to the VT queries that
    // programs like vim, tmux, and htop send at startup (device attributes,
    // size, xtversion, …). The userdata pointer aims at the stack-pinned
    // CoreState's effects_ctx, which outlives the loop.
    s.effects_ctx.pty_fd = s.pty_fd;
    s.effects_ctx.cellWidth = s.cellWidth;
    s.effects_ctx.cellHeight = s.cellHeight;
    s.effects_ctx.cols = s.cols;
    s.effects_ctx.rows = s.rows;
    ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_USERDATA, cast(const(void)*)&s.effects_ctx);
    ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, cast(const(void)*)&effect_write_pty);
    ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_SIZE, cast(const(void)*)&effect_size);
    ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, cast(const(void)*)&effect_device_attributes);
    ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_XTVERSION, cast(const(void)*)&effect_xtversion);
    ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_ENQUIRY, cast(const(void)*)&effect_enquiry);
    ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, cast(const(void)*)&effect_title_changed);
    ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, cast(const(void)*)&effect_color_scheme);
    ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_BELL, cast(const(void)*)&effect_bell);

    // Enable Kitty graphics: a storage limit is required (otherwise the terminal
    // rejects all image data), plus the file / temp-file / shared-memory
    // transmission mediums in addition to the default inline medium.
    ulong kitty_storage_limit = 64 * 1024 * 1024; // 64 MiB
    ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &kitty_storage_limit);
    bool kitty_medium = true;
    ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE, &kitty_medium);
    ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE, &kitty_medium);
    ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM, &kitty_medium);

    ghostty_render_state_new(null, &s.render_state);
    ghostty_render_state_row_iterator_new(null, &s.row_iter);
    ghostty_render_state_row_cells_new(null, &s.cells);
    ghostty_kitty_graphics_placement_iterator_new(null, &s.placement_iter);
    ghostty_key_event_new(null, &s.key_event);
    ghostty_key_encoder_new(null, &s.key_encoder);
    ghostty_mouse_event_new(null, &s.mouse_event);
    ghostty_mouse_encoder_new(null, &s.mouse_encoder);

    // Steady state: everything below runs allocation-free and non-throwing.
    runCoreLoop(s);

    // Reap the child to avoid a zombie. If it's still alive (the user closed the
    // window first), hang up its process group, then block until it exits.
    if (s.child > 0 && !s.childReaped)
    {
        import core.sys.posix.signal : kill, SIGHUP;
        import core.sys.posix.unistd : getpgid;
        import core.sys.posix.sys.wait : waitpid;
        if (!s.childExited)
        {
            auto pgid = getpgid(s.child);
            if (pgid <= 0) pgid = s.child;
            kill(cast(pid_t)(-pgid), SIGHUP); // SIGHUP the whole foreground group.
        }
        waitpid(s.child, null, 0);
    }

    freeFonts(s);
    ghostty_kitty_graphics_placement_iterator_free(s.placement_iter);
    ghostty_render_state_row_cells_free(s.cells);
    ghostty_render_state_row_iterator_free(s.row_iter);
    ghostty_render_state_free(s.render_state);
    ghostty_key_event_free(s.key_event);
    ghostty_key_encoder_free(s.key_encoder);
    ghostty_mouse_event_free(s.mouse_event);
    ghostty_mouse_encoder_free(s.mouse_encoder);
    s.selState.free();
    ghostty_terminal_free(s.terminal);
    CloseWindow();
    return 0;
}

// The steady-state frame loop. nothrow @nogc: it allocates nothing and cannot
// throw, so a long-running session has no GC pauses from this code.
@system nothrow @nogc
private void runCoreLoop(ref CoreState s)
{
    import core.sys.posix.sys.wait : waitpid, WNOHANG, WIFEXITED, WEXITSTATUS, WIFSIGNALED, WTERMSIG;
    import input : handle_input, handle_mouse, pty_write;

    // Initialize from the actual window state to avoid a spurious focus event
    // on the first frame.
    bool prev_focused = IsWindowFocused();
    char[4096] pty_buf = void;
    int frameCount = 0;

    while (!WindowShouldClose())
    {
        // --- Font-size hotkeys (Ctrl +/-) and window/grid resize. Done first so
        //     the new cell metrics feed input and rendering this frame. ---
        bool fontChanged = false;
        const ctrlDown = IsKeyDown(KeyboardKey.KEY_LEFT_CONTROL) || IsKeyDown(KeyboardKey.KEY_RIGHT_CONTROL);
        if (ctrlDown && IsKeyPressed(KeyboardKey.KEY_EQUAL))
        {
            s.fontSize += 2;
            fontChanged = true;
        }
        else if (ctrlDown && IsKeyPressed(KeyboardKey.KEY_MINUS))
        {
            if (s.fontSize > 6) { s.fontSize -= 2; fontChanged = true; }
        }

        if (fontChanged)
        {
            loadFontInto(s.font, s.fontSize, s.codepoints);
            if (s.regularFallback.pathZ !is null) loadFontInto(s.regularFallback, s.fontSize, s.codepoints);
            if (s.nerdFallback.pathZ !is null) loadFontInto(s.nerdFallback, s.fontSize, s.codepoints);
            Vector2 mSize = MeasureTextEx(s.font.font, "M", s.fontSize, 0);
            s.cellWidth = cast(int) mSize.x;
            s.cellHeight = cast(int) mSize.y;
            if (s.cellWidth < 1) s.cellWidth = 1;
            if (s.cellHeight < 1) s.cellHeight = 1;
        }

        if (fontChanged || IsWindowResized())
        {
            s.cols = cast(ushort)(GetScreenWidth() / s.cellWidth);
            s.rows = cast(ushort)(GetScreenHeight() / s.cellHeight);
            if (s.cols == 0) s.cols = 1;
            if (s.rows == 0) s.rows = 1;

            ghostty_terminal_resize(s.terminal, s.cols, s.rows, s.cellWidth, s.cellHeight);
            // Keep the effects context in sync so size/DA reports are accurate.
            s.effects_ctx.cols = s.cols;
            s.effects_ctx.rows = s.rows;
            s.effects_ctx.cellWidth = s.cellWidth;
            s.effects_ctx.cellHeight = s.cellHeight;
            winsize new_ws = {
                ws_row: s.rows,
                ws_col: s.cols,
                ws_xpixel: cast(ushort)(s.cols * s.cellWidth),
                ws_ypixel: cast(ushort)(s.rows * s.cellHeight),
            };
            ioctl(s.pty_fd, TIOCSWINSZ, &new_ws);
        }

        // --- Focus in/out reporting (DECSET 1004). Only emit when the
        //     application enabled focus events, else we'd inject stray CSI I/O. ---
        bool focused = IsWindowFocused();
        if (focused != prev_focused)
        {
            bool focus_mode = false;
            if (ghostty_terminal_mode_get(s.terminal, cast(GhosttyMode) 1004, &focus_mode) == GHOSTTY_SUCCESS && focus_mode)
            {
                char[8] fbuf;
                size_t fwritten = 0;
                auto fev = focused ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST;
                if (ghostty_focus_encode(fev, fbuf.ptr, fbuf.length, &fwritten) == GHOSTTY_SUCCESS && fwritten > 0)
                    pty_write(s.pty_fd, fbuf.ptr, fwritten);
            }
            prev_focused = focused;
        }

        // --- Drain the pty BEFORE handling input, so the key/mouse encoders see
        //     this frame's mode changes. Non-blocking: read until EAGAIN. ---
        if (!s.childExited)
        {
            while (true)
            {
                auto n = read(s.pty_fd, pty_buf.ptr, pty_buf.length);
                if (n > 0)
                {
                    ghostty_terminal_vt_write(s.terminal, cast(const(ubyte)*)pty_buf.ptr, cast(uint)n);
                }
                else if (n == 0)
                {
                    s.childExited = true; // Child closed its end of the pty (EOF).
                    break;
                }
                else
                {
                    import core.stdc.errno : errno, EAGAIN, EWOULDBLOCK, EINTR;
                    if (errno == EAGAIN || errno == EWOULDBLOCK)
                        break; // Nothing more available this frame.
                    if (errno == EINTR)
                        continue; // Interrupted by a signal — retry the read.
                    s.childExited = true; // EIO (slave closed on Linux) or error.
                    break;
                }
            }
        }

        // --- Reap the child once it has exited (retry until WNOHANG succeeds). ---
        if (s.childExited && !s.childReaped)
        {
            int wstatus;
            if (waitpid(s.child, &wstatus, WNOHANG) == s.child)
            {
                s.childReaped = true;
                if (WIFEXITED(wstatus))
                    s.childStatus = WEXITSTATUS(wstatus);
                else if (WIFSIGNALED(wstatus))
                    s.childStatus = 128 + WTERMSIG(wstatus);
            }
        }

        // --- Decide whether to close based on the configured exit behavior. ---
        if (s.childExited)
        {
            bool closeNow = false;
            final switch (s.exitBehavior)
            {
                case ExitBehavior.close:
                    closeNow = true;
                    break;
                case ExitBehavior.holdOnFailure:
                    closeNow = s.childReaped && s.childStatus == 0; // close on clean exit.
                    break;
                case ExitBehavior.hold:
                    break; // Stay open until the window is closed.
                case ExitBehavior.waitForKey:
                    closeNow = GetKeyPressed() != 0; // any key closes.
                    break;
            }
            if (closeNow)
                break;
        }

        // --- Forward keyboard/mouse only while the child is alive. ---
        if (!s.childExited)
        {
            handle_input(s.pty_fd, s.key_encoder, s.key_event, s.terminal, s.selState);
            handle_mouse(s.pty_fd, s.mouse_encoder, s.mouse_event, s.terminal, s.cellWidth, s.cellHeight, s.selState, s.sbState, s.hoverState);
        }

        if (s.hoverState.isHoveringUrl)
            SetMouseCursor(MouseCursor.MOUSE_CURSOR_POINTING_HAND);
        else
            SetMouseCursor(MouseCursor.MOUSE_CURSOR_DEFAULT);

        // --- Snapshot the terminal into the render state, then draw. ---
        ghostty_render_state_update(s.render_state, s.terminal);

        // Resolved default colors (used for the window clear, default cell
        // colors, and the cursor) instead of hardcoded white-on-black.
        GhosttyRenderStateColors colors;
        colors.size = GhosttyRenderStateColors.sizeof;
        ghostty_render_state_colors_get(s.render_state, &colors);

        BeginDrawing();
        ClearBackground(Color(colors.background.r, colors.background.g, colors.background.b, 255));

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

        ghostty_render_state_get(s.render_state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &s.row_iter);

        int y = 0;
        while (ghostty_render_state_row_iterator_next(s.row_iter))
        {
            ghostty_render_state_row_get(s.row_iter, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &s.cells);

            BeginScissorMode(0, y, GetScreenWidth(), s.cellHeight);

            int x = 0;
            while (ghostty_render_state_row_cells_next(s.cells))
            {
                uint grapheme_len;
                ghostty_render_state_row_cells_get(s.cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &grapheme_len);

                if (grapheme_len > 0)
                {
                    uint[16] codepoints;
                    ghostty_render_state_row_cells_get(s.cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, codepoints.ptr);

                    // Seed fg/bg from the terminal defaults; the per-cell queries
                    // overwrite them only when the cell has an explicit color and
                    // return INVALID_VALUE otherwise. The bg is painted only when
                    // the cell actually has one (or a swap below forces it).
                    GhosttyColorRgb fg_rgb = colors.foreground;
                    ghostty_render_state_row_cells_get(s.cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg_rgb);

                    GhosttyColorRgb bg_rgb = colors.background;
                    bool has_bg = ghostty_render_state_row_cells_get(s.cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg_rgb) == GHOSTTY_SUCCESS;

                    Color bg_col = Color(bg_rgb.r, bg_rgb.g, bg_rgb.b, 255);
                    Color fg_col = Color(fg_rgb.r, fg_rgb.g, fg_rgb.b, 255);

                    // Read the cell style for SGR attribute flags. Colors are
                    // already resolved above via the FG/BG_COLOR queries.
                    GhosttyStyle style;
                    style.size = GhosttyStyle.sizeof;
                    ghostty_render_state_row_cells_get(s.cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);

                    // Reverse video: swap fg/bg up front so the selection/hover
                    // swap below composes on top of it correctly.
                    if (style.inverse)
                    {
                        Color inv = bg_col;
                        bg_col = fg_col;
                        fg_col = inv;
                        has_bg = true;
                    }

                    int cell_x = x / s.cellWidth;
                    int cell_y = y / s.cellHeight;

                    bool is_selected = false;
                    if (has_selection)
                    {
                        if (s.selState.isRectangular)
                        {
                            int min_x = sel_start_pt.x < sel_end_pt.x ? sel_start_pt.x : sel_end_pt.x;
                            int max_x = sel_start_pt.x > sel_end_pt.x ? sel_start_pt.x : sel_end_pt.x;
                            if (cell_y >= sel_start_pt.y && cell_y <= sel_end_pt.y && cell_x >= min_x && cell_x <= max_x)
                                is_selected = true;
                        }
                        else
                        {
                            if (cell_y > sel_start_pt.y && cell_y < sel_end_pt.y)
                                is_selected = true;
                            else if (cell_y == sel_start_pt.y && cell_y == sel_end_pt.y)
                                is_selected = cell_x >= sel_start_pt.x && cell_x <= sel_end_pt.x;
                            else if (cell_y == sel_start_pt.y)
                                is_selected = cell_x >= sel_start_pt.x;
                            else if (cell_y == sel_end_pt.y)
                                is_selected = cell_x <= sel_end_pt.x;
                        }
                    }

                    bool is_hovered_link = s.hoverState.isHoveringUrl && cell_y == s.hoverState.y && cell_x >= s.hoverState.start_x && cell_x <= s.hoverState.end_x;

                    // Selection and hovered-link both render as inverted. Swap
                    // once if either is set (swapping per-condition would cancel
                    // out when both are true).
                    if (is_selected || is_hovered_link)
                    {
                        Color tmp = bg_col;
                        bg_col = fg_col;
                        fg_col = tmp;
                        has_bg = true;
                    }

                    if (has_bg)
                        DrawRectangle(x, y, s.cellWidth, s.cellHeight, bg_col);

                    LoadedFont* activeFont = &s.font;
                    if (codepoints[0] >= 128)
                    {
                        if (!fontHasGlyph(s.font, codepoints[0]))
                        {
                            if (s.regularFallback.present && fontHasGlyph(s.regularFallback, codepoints[0]))
                                activeFont = &s.regularFallback;
                            else if (s.nerdFallback.present && fontHasGlyph(s.nerdFallback, codepoints[0]))
                                activeFont = &s.nerdFallback;
                        }
                    }

                    // Draw the whole grapheme cluster (base codepoint plus any
                    // combining marks, ZWJ joiners, variation selectors, …) as one
                    // unit. Drawing only codepoints[0] would drop accents and emoji
                    // modifiers.
                    const cp_count = grapheme_len < 16 ? grapheme_len : 16;

                    // Italic: shift the glyph right by a fraction of the font
                    // size (a crude slant; raylib can't shear a glyph).
                    const italic_offset = style.italic ? (s.fontSize / 6) : 0;
                    drawGrapheme(*activeFont, codepoints[0 .. cp_count],
                        cast(float)(x + italic_offset), cast(float)y, s.fontSize, fg_col);

                    // Bold: redraw 1px to the right to thicken strokes (fake bold).
                    if (style.bold)
                        drawGrapheme(*activeFont, codepoints[0 .. cp_count],
                            cast(float)(x + italic_offset + 1), cast(float)y, s.fontSize, fg_col);

                    // Underline (any SGR underline style) and strikethrough.
                    if (style.underline != 0)
                        DrawRectangle(x, y + s.cellHeight - 2, s.cellWidth, 1, fg_col);
                    if (style.strikethrough)
                        DrawRectangle(x, y + s.cellHeight / 2, s.cellWidth, 1, fg_col);

                    GhosttyCell raw_cell;
                    bool has_hyperlink = false;
                    if (ghostty_render_state_row_cells_get(s.cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, cast(void*)&raw_cell) == GHOSTTY_SUCCESS)
                        ghostty_cell_get(raw_cell, GHOSTTY_CELL_DATA_HAS_HYPERLINK, cast(void*)&has_hyperlink);

                    if (has_hyperlink || is_hovered_link)
                    {
                        int thickness = is_hovered_link ? 2 : 1;
                        DrawRectangle(x, y + s.cellHeight - thickness, s.cellWidth, thickness, fg_col);
                    }
                }
                else
                {
                    // Empty cell with no text may still carry a background color
                    // (e.g. an erase with a color set). BG_COLOR returns
                    // INVALID_VALUE when the cell has no background.
                    GhosttyColorRgb bg_rgb;
                    if (ghostty_render_state_row_cells_get(s.cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg_rgb) == GHOSTTY_SUCCESS)
                        DrawRectangle(x, y, s.cellWidth, s.cellHeight, Color(bg_rgb.r, bg_rgb.g, bg_rgb.b, 255));
                }

                x += s.cellWidth;
            }

            EndScissorMode();

            // Clear this row's dirty flag now that it has been drawn.
            bool rowClean = false;
            ghostty_render_state_row_set(s.row_iter, GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &rowClean);

            y += s.cellHeight;
        }

        // Images below text (drawn after cell backgrounds/text in this
        // single-pass renderer, but before the cursor and above-text images).
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
                DrawRectangle(c_x, c_y, 2, s.cellHeight, c_color);
            else if (cursor_style == 1) // Block
                DrawRectangle(c_x, c_y, s.cellWidth, s.cellHeight, c_color);
            else if (cursor_style == 2) // Underline
                DrawRectangle(c_x, c_y + s.cellHeight - 2, s.cellWidth, 2, c_color);
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

            Vector2 msgSize = MeasureTextEx(s.font.font, msg.ptr, s.fontSize, 0);
            int screenW = GetScreenWidth();
            int screenH = GetScreenHeight();
            int bannerH = cast(int) msgSize.y + 8;
            DrawRectangle(0, screenH - bannerH, screenW, bannerH, Color(0, 0, 0, 180));
            DrawTextEx(s.font.font, msg.ptr, Vector2((screenW - msgSize.x) / 2, screenH - bannerH + 4), s.fontSize, 0, Color(255, 255, 255, 255));
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

        EndDrawing();

        // Free textures uploaded during this frame's kitty rendering, now that
        // EndDrawing() has flushed all draw commands to the GPU.
        flush_deferred_textures();

        if (s.debugScreenshotAndExit)
        {
            frameCount++;
            if (frameCount == 120)
                TakeScreenshot("test_screenshot.png".ptr);
            if (frameCount == 130)
                break;
        }
    }
}
