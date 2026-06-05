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

extern(C) void effect_write_pty(GhosttyTerminal terminal, void* userdata, const(ubyte)* data, size_t len) @nogc nothrow
{
    import input : pty_write;
    int pty_fd = *cast(int*)userdata;
    pty_write(pty_fd, data, len);
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

    GhosttyTerminal terminal;
    GhosttyTerminalOptions opts = { cols: cols, rows: rows, max_scrollback: 1000 };
    ghostty_terminal_new(null, &terminal, opts);

    int pty_fd = -1;
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, cast(const(void)*)&pty_fd);
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, cast(const(void)*)&effect_write_pty);

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

    GhosttyRenderState render_state;
    ghostty_render_state_new(null, &render_state);

    GhosttyRenderStateRowIterator row_iter;
    ghostty_render_state_row_iterator_new(null, &row_iter);

    GhosttyRenderStateRowCells cells;
    ghostty_render_state_row_cells_new(null, &cells);

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

    while (!WindowShouldClose())
    {
        import input : handle_input, handle_mouse;

        handle_input(pty_fd, key_encoder, key_event, terminal, selState);
        handle_mouse(pty_fd, mouse_encoder, mouse_event, terminal, cellWidth, cellHeight, selState, sbState, hoverState);

        if (hoverState.isHoveringUrl) {
            SetMouseCursor(MouseCursor.MOUSE_CURSOR_POINTING_HAND);
        } else {
            SetMouseCursor(MouseCursor.MOUSE_CURSOR_DEFAULT);
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


                    DrawTextCodepoint(activeFont, codepoints[0], Vector2(cast(float)x, cast(float)y), fontSize, fg_col);

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

                x += cellWidth;
            }

            EndScissorMode();
            y += cellHeight;
        }

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

        EndDrawing();

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
