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
import sparkles.raylib_text : displayMetrics, DisplayMetrics, FontSet,
    LoadedFont, drawGrapheme, drawSolid, drawBox, pixelsForPoints,
    resolveFontInDirs;
import sparkles.terminal_view.input : ExitBehavior, SelectionState, ScrollbarState, HoverState;
import sparkles.terminal_view.osc_query : OscScanner;
import child_env : sanitizeChildEnv;

extern(C) int forkpty(int *amaster, char *name, const termios *termp, const winsize *winp);

import sparkles.terminal_view.core;

// One-time setup (CLI, fonts, terminal, pty). GC and exceptions are fine here;
// the steady-state work happens in the `nothrow @nogc` runCoreLoop below.
int main(string[] args)
{
    import std.getopt;
    import std.file : exists;
    import std.process : execute;
    import std.string : strip;
    import std.stdio : stderr, writeln;
    import sparkles.terminal_view.input : parseExitBehavior;

    string fontOpt = "monospace";
    int fontSizePt = 13;
    int windowCols = 100;
    int windowRows = 30;
    size_t scrollbackLimit = size_t.max;
    bool debugScreenshotAndExit = false;
    string exitBehaviorOpt = "hold-on-failure";
    string[] codepointMapOpt;
    string[] fontDirOpt;

    auto helpInfo = getopt(
        args,
        // Stop at the first non-option so a trailing command (and its own flags)
        // is left untouched: `terminal --font-size 14 -- vim file -R`.
        config.stopOnFirstNonOption,
        "font|f", "Font path or name (e.g. '/path/to/font.ttf' or 'Fira Code')", &fontOpt,
        "font-size|s", "Font size in points (default: 13)", &fontSizePt,
        "window-width", "Initial window width in columns (default: 100)", &windowCols,
        "window-height", "Initial window height in rows (default: 30)", &windowRows,
        "scrollback-limit", "Maximum number of lines to keep in scrollback history (0 to disable, default: infinite)", &scrollbackLimit,
        "font-codepoint-map", "Render codepoints from a specific font (repeatable): 'U+XXXX-U+YYYY,U+ZZZZ=Family'", &codepointMapOpt,
        "font-dir", "Resolve fonts by scanning this directory instead of fontconfig (repeatable). Makes a build portable and its font selection deterministic: no fc-match subprocess, no dependence on the host's fontconfig configuration. Pair with the bundle from `nix build .#sparkles-fonts`.", &fontDirOpt,
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

    // --font-dir switches the whole FontSet to directory scanning: no
    // fc-match, no fc-query, no fc-scan. Three things that buys, all of which
    // the Android port needed first and a desktop build wants too: it works
    // where fontconfig is absent, it is deterministic (fc-match's answer
    // varies with the host's fontconfig configuration, which is a
    // golden-screenshot hazard), and it drops up to six subprocesses from
    // startup.
    auto fontSources = FontSet.FontSources(fontDirOpt, useFontconfig: fontDirOpt.length == 0);

    string fontPath = fontOpt;
    if (!fontPath.exists)
    {
        if (fontSources.useFontconfig)
        {
            auto res = execute(["fc-match", "-f", "%{file}", fontOpt]);
            if (res.status == 0 && res.output.strip().length > 0)
                fontPath = res.output.strip();
        }
        else
            fontPath = resolveFontInDirs(fontOpt, fontDirOpt);
    }
    if (fontPath.length == 0 || !fontPath.exists)
    {
        stderr.writeln("Error: Could not resolve font '", fontOpt, "'. Please provide a valid path or installed font name.");
        if (fontDirOpt.length)
            stderr.writeln("  (searched: ", fontDirOpt.join(", "), ")");
        return 1;
    }

    CoreState s;
    // The face set, owned here and borrowed by CoreState — the same shape the
    // runApp component uses with the host session's set (one atlas per
    // window, whoever drives the loop). Non-copyable; stack-pinned for the
    // whole run.
    FontSet fonts;
    // Point size → pixels for raylib's pixel-based rasterizer (96-DPI points:
    // 1pt = 1/72in, 96px/in). Converted once; the rest of the renderer works in
    // pixels (Ctrl +/- then adjusts the pixel size directly).
    // Resolved after InitWindow, below, once the panel is known.
    s.fontSize = pixelsForPoints(fontSizePt, DisplayMetrics.init);
    s.cols = cast(ushort) (windowCols > 0 ? windowCols : 1);
    s.rows = cast(ushort) (windowRows > 0 ? windowRows : 1);
    s.exitBehavior = parseExitBehavior(exitBehaviorOpt);
    s.debugScreenshotAndExit = debugScreenshotAndExit;
    InitWindow(800, 600, "Sparkles Terminal");
    // Allow the user to resize the window; the loop recomputes the grid and
    // sends TIOCSWINSZ on IsWindowResized().
    SetWindowState(ConfigFlags.FLAG_WINDOW_RESIZABLE);
    SetTargetFPS(60);
    // Disable raylib's default "Escape closes the window" behavior — Esc must be
    // forwarded to the terminal application (vim, less, …) like any other key.
    SetExitKey(KeyboardKey.KEY_NULL);

    // Now the window exists, resolve the point size against the ACTUAL panel.
    // The terminal had no DPI factor at all — it computed pt→px at a nominal
    // 96 dpi and rendered unreadably on a HiDPI display where hue was legible
    // (IXR28). Same conversion, same clamp, one library.
    s.fontSize = pixelsForPoints(fontSizePt, displayMetrics());

    // Load the whole face set via the shared library: primary + real bold/italic/
    // bold-italic variants, a regular and a Nerd-Font fallback, any
    // --font-codepoint-map faces, and the on-demand base atlas. Must run after
    // InitWindow (LoadFontEx needs the GL context).
    if (!FontSet.tryLoad(fontPath, s.fontSize, fonts, codepointMapOpt,
        FontSet.FaceOverrides.init, fontSources))
    {
        stderr.writeln("Error: could not load font: ", fontPath);
        CloseWindow();
        return 1;
    }
    s.fonts = &fonts;
    // The library measures and zero-guards the cell metric internally.
    s.cellWidth = s.fonts.cellW();
    s.cellHeight = s.fonts.cellH();
    SetWindowSize(s.cols * s.cellWidth, s.rows * s.cellHeight);

    // Install the PNG decoder via the sys interface so the terminal can handle
    // PNG images in the Kitty Graphics Protocol. This is process-global and
    // must be done before any terminal is created.
    ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, cast(const(void)*)&decode_png);

    GhosttyTerminalOptions opts = { cols: s.cols, rows: s.rows, max_scrollback: scrollbackLimit };
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

    // Sanitize the environment in the parent; the child inherits it (so we
    // don't need a non-async-signal-safe setenv between fork and exec).
    sanitizeChildEnv();

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
        s.fonts.unload();
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
        s.fonts.unload();
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

    // Promote the render-state fallback colors to terminal-level defaults. The
    // render state always falls back to a built-in theme, but the terminal
    // itself keeps unset colors as "no value", so the effective color getters
    // (which feed the OSC 10/11/12 color-query responder, see feedPtyChunk)
    // would have nothing to report. Registering the colors we render as the
    // terminal defaults keeps color reports in sync with the screen.
    {
        GhosttyRenderStateColors colors;
        colors.size = GhosttyRenderStateColors.sizeof;
        ghostty_render_state_update(s.render_state, s.terminal);
        if (ghostty_render_state_colors_get(s.render_state, &colors) == GHOSTTY_SUCCESS)
        {
            ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &colors.foreground);
            ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &colors.background);
        }
    }
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

    s.fonts.unload();
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
    import sparkles.terminal_view.input : handle_input, handle_mouse, pty_write;

    // Initialize from the actual window state to avoid a spurious focus event
    // on the first frame.
    bool prev_focused = IsWindowFocused();
    char[4096] pty_buf = void;
    int frameCount = 0;

    // Benchmark hook: when set, redraw every frame regardless of dirty state, so
    // the render path can be measured in isolation (a static screen otherwise
    // skips, and a stream workload is parse-bound). See apps/terminal-benchmark.
    import core.stdc.stdlib : getenv;
    const forceRedraw = getenv("SPARKLES_BENCH_FORCE_REDRAW") !is null;

    // Dirty-frame skipping state. The terminal redraws the whole grid every
    // frame, so when nothing has changed we skip the (expensive) draw and just
    // pace + poll input, leaving the last frame on screen. `prevOverlayActive`
    // forces one extra redraw when an app-side overlay (selection, hover,
    // scrollbar, bell) turns off so it gets cleared; `forceFirstFrames` paints
    // the opening frames unconditionally.
    bool prevOverlayActive = false;
    bool prevChildExited = false;
    int forceFirstFrames = 2;

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
            // Reload every face at the new size and re-measure (the library
            // reloads primary+styled with the grown atlas, fallbacks/maps with
            // their own sets).
            s.fonts.reload(s.fontSize);
            s.cellWidth = s.fonts.cellW();
            s.cellHeight = s.fonts.cellH();
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
                    feedPtyChunk(s, pty_buf[0 .. n]);
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

        // --- Snapshot the terminal into the render state. Always update so the
        //     terminal's dirty state is consumed; the query below decides
        //     whether this frame needs a redraw at all. ---
        ghostty_render_state_update(s.render_state, s.terminal);

        // --- Dirty-frame skipping. When the terminal content is clean and no
        //     app-side overlay/animation is active (or just ended), the last
        //     fully-drawn frame is still on screen, so skip the whole-grid
        //     redraw and only pace + poll input. This drops idle CPU to near
        //     zero. We pace and poll manually (EndDrawing normally does both)
        //     but deliberately do NOT swap buffers, keeping the last frame. ---
        GhosttyRenderStateDirty dirty = GHOSTTY_RENDER_STATE_DIRTY_FULL;
        ghostty_render_state_get(s.render_state, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty);

        const bool overlayActive =
            s.effects_ctx.bellFlashFrames > 0
            || s.selState.isSelecting
            || s.hoverState.isHoveringUrl
            || s.sbState.isHovered || s.sbState.isDragging
            || s.sbState.currentWidth != s.sbState.targetWidth;

        const bool redraw =
            forceRedraw
            || dirty != GHOSTTY_RENDER_STATE_DIRTY_FALSE
            || overlayActive || prevOverlayActive
            || fontChanged || IsWindowResized()
            || s.childExited != prevChildExited
            || forceFirstFrames > 0
            || s.debugScreenshotAndExit; // debug path wants full-rate frames

        prevOverlayActive = overlayActive;
        prevChildExited = s.childExited;
        if (forceFirstFrames > 0) forceFirstFrames--;

        if (!redraw)
        {
            PollInputEvents();    // register input so next frame's keys/mouse are fresh
            WaitTime(1.0 / 60.0); // pace to the 60 FPS target without a buffer swap
            continue;
        }

        // The frame: two-pass cells, kitty layers, scrollbar, cursor, banner,
        // bell flash, dirty reset, buffer swap, texture flush — all in the
        // library now (renderFrame). It reports whether the on-demand atlas
        // grew, which needs one extra frame so the new glyphs get painted.
        if (renderFrame(s) && forceFirstFrames < 1)
            forceFirstFrames = 1;

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
