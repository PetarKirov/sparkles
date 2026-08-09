/**
The terminal as a `runApp` component (`TVW2`, `TVW5`, `TVW6`).

$(REF TerminalView, sparkles,terminal_view,component) is the whole emulator as
a value: `open` spawns the shell on a pty and wires the VT effects, `view`
drains the pty and makes the dirty/skip decision, `handle` maps
`sparkles:input` events onto the byte-oracle-pinned encoder seam, and `paint`
runs the per-cell renderer inside the host's draw phase (`HST13`). `main`
shrinks to CLI-parse-then-`runApp`.

$(B What stays polled:) the mouse. `handle_mouse` is deeply level-coupled
(scrollbar drag, selection auto-scroll, hover re-scan) and is called from
`view` exactly as the polling loop called it — converting it to events is a
later, separately-measured step (`TVW6`'s discipline, applied to input).
Clipboard $(B reads) also stay raylib's (`GetClipboardText`): the host has no
clipboard-read errand yet.

$(B Ordering parity:) the polling loop drained the pty before encoding input,
so the encoders always saw the current frame's mode changes. Events arrive
before `view` runs, so the first input event of a frame triggers the drain
lazily and `view` drains again for the render — the same
drain → input → render order, event-shaped.
*/
module sparkles.terminal_view.component;

import core.sys.posix.fcntl : F_GETFL, F_SETFL, fcntl, O_NONBLOCK;
import core.sys.posix.sys.ioctl : ioctl, TIOCSWINSZ, winsize;
import core.sys.posix.sys.types : pid_t;
import core.sys.posix.unistd : execv, getuid, read, _exit;

import raylib;

import sparkles.base.term_color : RgbColor;
import sparkles.ghostty.c;
import sparkles.input : EndOfInput, Event, FocusEvent, Key, KeyAction,
    KeyEvent, match, Mods;
import sparkles.raylib_text : FontSet;
import sparkles.terminal_view.child_env : sanitizeChildEnv;
import sparkles.terminal_view.core;
import sparkles.terminal_view.event_map : encodeKeyEvent, ghosttyKeyOf,
    withKeyIdentity;
import sparkles.terminal_view.input : ExitBehavior, handle_mouse, pty_write;
import sparkles.ui.geometry : Rect;
import sparkles.ui.layout : Frame;
import sparkles.ui.widget : WidgetTree;

extern (C) private int forkpty(int* amaster, char* name, const void* termp,
    const winsize* winp);

/// A pane's scrollback geometry (see `TerminalView.scrollback`).
struct Scrollback
{
    long total;  /// history + screen rows
    long len;    /// the viewport's rows
    long offset; /// the viewport's first row, from the top of history
}

/// Everything the frame's dirty/skip decision reads (`TVW5`), as one plain
/// value — the decision itself is $(LREF redrawDecision), a pure function
/// over it.
struct RedrawInputs
{
    bool contentDirty;      /// libghostty reported dirt since the last snapshot
    bool overlayActive;     /// selection / URL hover / scrollbar / bell live now
    bool overlayWasActive;  /// last frame's overlay — its trailing edge repaints
    bool gridChanged;       /// a resize landed this frame
    bool exitEdge;          /// `childExited` flipped since last frame
    bool warmup;            /// first frames / a pending atlas flush
    bool forced;            /// bench force-redraw or the debug screenshot hook
}

/// The frame's repaint answer: any reason at all says paint.
bool redrawDecision(in RedrawInputs i) @safe pure nothrow @nogc
    => i.forced || i.contentDirty || i.overlayActive || i.overlayWasActive
    || i.gridChanged || i.exitEdge || i.warmup;

@("terminal_view.component.redrawDecision.anyReasonPaints")
@safe pure nothrow @nogc
unittest
{
    assert(!redrawDecision(RedrawInputs()));

    // Each input alone is sufficient — no reason may be masked by another's
    // absence (the bug class: a clean-content frame eating a resize).
    assert(redrawDecision(RedrawInputs(contentDirty: true)));
    assert(redrawDecision(RedrawInputs(overlayActive: true)));
    assert(redrawDecision(RedrawInputs(overlayWasActive: true)));
    assert(redrawDecision(RedrawInputs(gridChanged: true)));
    assert(redrawDecision(RedrawInputs(exitEdge: true)));
    assert(redrawDecision(RedrawInputs(warmup: true)));
    assert(redrawDecision(RedrawInputs(forced: true)));
}

/// What the caller wants of a terminal pane.
struct TerminalViewOptions
{
    /// A command for the shell's `-c`, or null for an interactive shell.
    const(char)* shellCommand = null;
    /// Scrollback lines kept (0 disables; the default is unbounded).
    size_t scrollbackLimit = size_t.max;
    /// What happens when the shell exits.
    ExitBehavior exitBehavior = ExitBehavior.holdOnFailure;
    /// Debug hook: screenshot at frame 120, quit at 130.
    bool debugScreenshotAndExit = false;
    /// The emulator's own overlay scrollbar. An embedding application draws
    /// its bar beside the pane and turns this one off (`TVW7`).
    bool internalScrollbar = true;
}

/**
The emulator as a component. Non-copyable once opened: the VT effects hold a
pointer into the embedded state, so the instance must stay put (stack-pin it,
as `main` pins its `CoreState` today, or heap-pin it as an embedder's tabs
do).

Multiple instances may coexist on one thread (`TVW7` — an embedder's tabs):
per-instance state is fully embedded, and the only process-global pieces are
safe there — the deferred-texture list's flushes all run pre-bracket, and
re-registering the same PNG decoder is idempotent. Not thread-safe.
*/
struct TerminalView
{
    CoreState s;
    TerminalViewOptions opts;

    private bool opened;
    private bool prevFocused = true;
    private bool prevOverlayActive;
    private bool prevChildExited;
    private int forceFirstFrames = 2;
    private bool forceRedrawEnv;
    private bool drainedThisFrame;
    private bool pendingForce;
    private int frameCount;

    @disable this(this);

    /**
    Spawns the shell on a pty and wires the terminal — everything the app's
    `main` did after loading fonts, driven by the `opts` the caller filled in
    beforehand. `fonts` is borrowed (the window session owns it, `HST14`);
    `cols`/`rows` size the initial grid.

    Called lazily by the first `view` — the fonts exist only once the host
    opened its session, which happens inside `runApp`.

    Returns `false` when the pty could not be opened; the terminal is freed
    and the instance reusable.
    */
    bool open(FontSet* fonts, ushort cols, ushort rows) @system
    {
        s.fonts = fonts;
        s.fontSize = fonts.size;
        if (!openCore(cols, rows, fonts.cellW(), fonts.cellH()))
            return false;
        prevFocused = IsWindowFocused();
        return true;
    }

    /**
    The pty/VT half of `open`, with the cell metrics as plain values — no
    fonts and no window, so a fontless embedder (a cell-grid pane on the
    terminal arm, `TVW7`) can spawn too. Fontless, the pty reports no pixel
    size (`ws_xpixel`/`ws_ypixel` 0, the standard answer of pixel-less
    terminals) and kitty graphics stay unwired — nothing could paint them.
    */
    bool openCore(ushort cols, ushort rows, int cellWidthPx, int cellHeightPx) @system
    {
        import core.stdc.stdlib : getenv;
        import core.stdc.string : strrchr;

        s.cellWidth = cellWidthPx > 0 ? cellWidthPx : 1;
        s.cellHeight = cellHeightPx > 0 ? cellHeightPx : 1;
        s.cols = cols > 0 ? cols : 1;
        s.rows = rows > 0 ? rows : 1;
        s.exitBehavior = opts.exitBehavior;
        s.internalScrollbar = opts.internalScrollbar;
        s.debugScreenshotAndExit = opts.debugScreenshotAndExit;
        forceRedrawEnv = getenv("SPARKLES_BENCH_FORCE_REDRAW") !is null;

        // The PNG decoder for kitty graphics: process-global, before any
        // terminal exists. Fontless there is no way to paint an image, so
        // the raylib-backed decoder stays out of the picture entirely.
        if (s.fonts !is null)
            ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, cast(const(void)*) &decode_png);

        GhosttyTerminalOptions topts = {
            cols: s.cols, rows: s.rows, max_scrollback: opts.scrollbackLimit,
        };
        ghostty_terminal_new(null, &s.terminal, topts);
        // The options carry no cell pixel size; set it up front so kitty
        // placement math and pixel-size reports never see zeros.
        ghostty_terminal_resize(s.terminal, s.cols, s.rows, s.cellWidth, s.cellHeight);

        // Resolve the shell and build argv BEFORE forkpty, so the child does
        // only async-signal-safe work (execv + _exit).
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

        // Sanitize in the parent; the child inherits (no setenv between fork
        // and exec).
        sanitizeChildEnv();

        const(char)*[4] argv;
        if (opts.shellCommand !is null)
            argv = [shellName, "-c".ptr, opts.shellCommand, null];
        else
            argv = [shellName, null, null, null];

        winsize ws = {
            ws_row: s.rows,
            ws_col: s.cols,
            ws_xpixel: s.fonts is null ? 0 : cast(ushort)(s.cols * s.cellWidth),
            ws_ypixel: s.fonts is null ? 0 : cast(ushort)(s.rows * s.cellHeight),
        };
        s.child = forkpty(&s.pty_fd, null, null, &ws);
        if (s.child < 0)
        {
            ghostty_terminal_free(s.terminal);
            s.terminal = null;
            return false;
        }
        if (s.child == 0)
        {
            execv(shellZ, cast(char**) argv.ptr);
            _exit(127);
        }

        // Non-blocking master: read() must return EAGAIN, never stall a frame.
        int flags = fcntl(s.pty_fd, F_GETFL);
        if (flags < 0 || fcntl(s.pty_fd, F_SETFL, flags | O_NONBLOCK) < 0)
        {
            import core.sys.posix.signal : kill, SIGHUP;
            import core.sys.posix.sys.wait : waitpid;

            kill(s.child, SIGHUP);
            waitpid(s.child, null, 0);
            ghostty_terminal_free(s.terminal);
            s.terminal = null;
            return false;
        }

        // The VT effects. userdata aims at the embedded effects context, which
        // is why the instance is non-copyable.
        s.effects_ctx.pty_fd = s.pty_fd;
        s.effects_ctx.cellWidth = s.cellWidth;
        s.effects_ctx.cellHeight = s.cellHeight;
        s.effects_ctx.cols = s.cols;
        s.effects_ctx.rows = s.rows;
        ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_USERDATA, cast(const(void)*) &s.effects_ctx);
        ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, cast(const(void)*) &effect_write_pty);
        ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_SIZE, cast(const(void)*) &effect_size);
        ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, cast(const(void)*) &effect_device_attributes);
        ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_XTVERSION, cast(const(void)*) &effect_xtversion);
        ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_ENQUIRY, cast(const(void)*) &effect_enquiry);
        ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, cast(const(void)*) &effect_title_changed);
        ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, cast(const(void)*) &effect_color_scheme);
        ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_BELL, cast(const(void)*) &effect_bell);

        // Kitty graphics: a storage limit is required, plus the file mediums.
        // Fontless (no renderer for them), the protocol stays disabled.
        if (s.fonts !is null)
        {
            ulong kittyStorage = 64 * 1024 * 1024;
            ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &kittyStorage);
            bool kittyMedium = true;
            ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE, &kittyMedium);
            ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE, &kittyMedium);
            ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM, &kittyMedium);
        }

        ghostty_render_state_new(null, &s.render_state);
        ghostty_render_state_row_iterator_new(null, &s.row_iter);
        ghostty_render_state_row_cells_new(null, &s.cells);

        // Promote the render-state fallback colors to terminal defaults so the
        // OSC 10/11/12 color-query responder reports what is on screen.
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

        opened = true;
        return true;
    }

    /// Reaps the child (SIGHUP to its group first if still alive) and frees
    /// every handle. The fonts and the window belong to the host.
    void close() @system
    {
        if (!opened)
            return;
        if (s.child > 0 && !s.childReaped)
        {
            import core.sys.posix.signal : kill, SIGHUP;
            import core.sys.posix.sys.wait : waitpid;
            import core.sys.posix.unistd : getpgid;

            if (!s.childExited)
            {
                auto pgid = getpgid(s.child);
                if (pgid <= 0)
                    pgid = s.child;
                kill(cast(pid_t)(-pgid), SIGHUP);
            }
            waitpid(s.child, null, 0);
        }
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
        opened = false;
    }

    // ── the component contract ──────────────────────────────────────────────

    /// The frame's pre-render half: last frame's deferred cleanup, grid
    /// follow, pty drain, child reaping, the exit policy, the polled mouse,
    /// and the dirty/skip decision. The pane is the whole surface, so the
    /// tree is empty — an embedding application wraps this component and
    /// keys a pane instead (`TVW7`).
    WidgetTree view(H)(ref H h)
    {
        frame(h, h.size.width, h.size.height);
        // The pane is the whole surface for the standalone app, so the tree
        // is empty; an embedding application calls `frame`/`paintPane` itself
        // and lays the pane out in its own tree (`TVW7`).
        return WidgetTree.init;
    }

    /**
    The frame's pre-render half at an explicit pane size (in cells) — what an
    embedding application calls from its own `view`, with the cell size its
    layout gave the pane last frame. The standalone `view` above passes the
    whole surface.
    */
    void frame(H)(ref H h, int paneCols, int paneRows)
    {
        // First frame: the host's session exists now, so the pty can open
        // against its fonts and the pane's size. A failed open ends the run.
        if (!opened)
        {
            auto c = h.canvas;
            if (!open(c.fonts, cast(ushort) paneCols, cast(ushort) paneRows))
            {
                h.quit();
                h.skipFrame();
                return;
            }
        }

        // Last frame's bracket ended after our paint ran (HST13), so its
        // deferred kitty textures and any atlas growth resolve here — the
        // same after-the-bracket point the polling loop reached in-line.
        flush_deferred_textures();
        if (s.fonts !is null && s.fonts.flushPending() && forceFirstFrames < 1)
            forceFirstFrames = 1;

        // Grid follow: the pane's size (cells) is authoritative — window
        // resizes and font-size changes both arrive as a size change.
        bool gridChanged = false;
        const newFontSize = h.fontSizePx;
        if (newFontSize > 0 && newFontSize != s.fontSize)
        {
            s.fontSize = newFontSize;
            s.cellWidth = s.fonts.cellW();
            s.cellHeight = s.fonts.cellH();
            gridChanged = true;
        }
        if (paneCols > 0 && paneRows > 0
            && (paneCols != s.cols || paneRows != s.rows))
            gridChanged = true;
        if (gridChanged)
            resizeGrid(cast(ushort) (paneCols > 0 ? paneCols : 1),
                cast(ushort) (paneRows > 0 ? paneRows : 1));

        pump();

        // A captured OSC title becomes the window's — the whole surface IS
        // the window here; an embedder consumes takeTitleChanged for its tab.
        if (takeTitleChanged())
            SetWindowTitle(s.effects_ctx.titleBuf.ptr);

        // The exit policy's frame-level half (waitForKey closes in `handle`).
        if (s.childExited)
        {
            bool closeNow = false;
            final switch (s.exitBehavior)
            {
                case ExitBehavior.close:
                    closeNow = true;
                    break;
                case ExitBehavior.holdOnFailure:
                    closeNow = s.childReaped && s.childStatus == 0;
                    break;
                case ExitBehavior.hold:
                case ExitBehavior.waitForKey:
                    break;
            }
            if (closeNow)
                h.quit();
        }

        // The mouse, still polled (see the module header): identical routing,
        // selection, scrollbar and hover behavior to the pre-component loop.
        if (!s.childExited)
            handle_mouse(s.pty_fd, s.mouse_encoder, s.mouse_event, s.terminal,
                s.cellWidth, s.cellHeight, s.selState, s.sbState, s.hoverState);

        import sparkles.base.term_control : PointerShape;

        h.pointerShape(s.hoverState.isHoveringUrl
            ? PointerShape.pointer : PointerShape.default_);

        // Snapshot, then decide: clean content + no live overlay = skip the
        // whole draw (the arms keep the last frame up and skip our paint too).
        // The pane owning the surface, a "no" becomes the frame's skip; an
        // embedding application folds `decideRedraw` into its own frame.
        if (!decideRedraw())
            h.skipFrame();

        // The debug screenshot hook (the golden capture): full-rate frames,
        // shot at 120, gone at 130.
        if (s.debugScreenshotAndExit)
        {
            frameCount++;
            if (frameCount == 120)
                TakeScreenshot("test_screenshot.png".ptr);
            if (frameCount == 130)
                h.quit();
        }
    }

    /// Keys: the hotkeys and clipboard chords first (consuming, exactly as
    /// the polling loop consumed them), then the byte-oracle-pinned encoder
    /// seam; focus edges become DECSET 1004 reports.
    void handle(H)(ref H h, in Event e)
    {
        e.match!(
            (in KeyEvent k) { onKey(h, k); },
            (in FocusEvent f) { notifyFocus(f.focused); },
            (in EndOfInput _) { h.quit(); },
            (in _) {},
        );
    }

    /// The renderer, inside the host's frame bracket (`HST13`): the per-cell
    /// paint, byte-identical to the polling loop's, over the whole surface.
    void paint(H)(ref H h, in WidgetTree, in Frame[])
    {
        paintFrame(s, GetScreenWidth(), GetScreenHeight());
    }

    /**
    The renderer at a laid-out pane (`TVW7`): translate + scissor to the
    pane's pixel rect, then the same per-cell paint. What an embedding
    application calls from its own `paint`, with the rect `keyedRects`
    reported for the pane it keyed. `rect` is in cells.

    Mouse routing inside an embedded pane is NOT wired yet — `handle_mouse`
    reads absolute window coordinates; it lands with the mouse-event
    conversion.
    */
    void paintPane(H)(ref H h, in Rect rect)
    {
        import raylib.rlgl : rlPopMatrix, rlPushMatrix, rlTranslatef;

        const px = rect.x * s.cellWidth;
        const py = rect.y * s.cellHeight;
        const pw = rect.width * s.cellWidth;
        const ph = rect.height * s.cellHeight;
        if (pw <= 0 || ph <= 0)
            return;

        BeginScissorMode(px, py, pw, ph);
        rlPushMatrix();
        rlTranslatef(px, py, 0);
        paintFrame(s, pw, ph);
        rlPopMatrix();
        EndScissorMode();
    }

    // ── the embedded surface (TVW7) ─────────────────────────────────────────
    // Host-free pieces the whole-surface members above recompose. An embedding
    // application drives them itself, because the host calls are its to make:
    // a clean pane must not skip the frame its chrome needs, a dead shell must
    // not quit the application, and a failed spawn is its error to report
    // (pre-open with `open`, so `frame`'s open-failure quit never runs).

    /**
    Drains the pty and reaps the child — the per-frame half every terminal
    needs whether or not it paints. An embedding application pumps $(B every)
    live pane each frame, not just the visible one, or a background child
    blocks on a full pty buffer.
    */
    void pump() @system nothrow @nogc
    {
        drainPty();
        drainedThisFrame = false; // next frame's first event re-drains
        reapChild();
    }

    /**
    Snapshots the render state and answers whether this frame must repaint —
    dirty content, a live/trailing overlay, a resize's force bit, an exit
    edge, or warmup. Advances the edge/warmup bookkeeping, so call it exactly
    once per frame. The whole-surface `frame` turns a `false` into
    `h.skipFrame()`; an embedder folds it into its own frame decision.
    */
    bool decideRedraw() @system nothrow @nogc
    {
        ghostty_render_state_update(s.render_state, s.terminal);

        GhosttyRenderStateDirty dirty = GHOSTTY_RENDER_STATE_DIRTY_FULL;
        ghostty_render_state_get(s.render_state, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty);

        const overlayActive =
            s.effects_ctx.bellFlashFrames > 0
            || s.selState.isSelecting
            || s.hoverState.isHoveringUrl
            || s.sbState.isHovered || s.sbState.isDragging
            || s.sbState.currentWidth != s.sbState.targetWidth;

        const redraw = redrawDecision(RedrawInputs(
            contentDirty: dirty != GHOSTTY_RENDER_STATE_DIRTY_FALSE,
            overlayActive: overlayActive,
            overlayWasActive: prevOverlayActive,
            gridChanged: pendingForce,
            exitEdge: s.childExited != prevChildExited,
            warmup: forceFirstFrames > 0,
            forced: forceRedrawEnv || s.debugScreenshotAndExit,
        ));

        pendingForce = false;
        prevOverlayActive = overlayActive;
        prevChildExited = s.childExited;
        if (forceFirstFrames > 0)
            forceFirstFrames--;
        return redraw;
    }

    /**
    Encodes one key event and writes it to the pty — the byte-oracle-pinned
    encoder seam alone (`TVW4`), for an embedding application's own key
    routing. The application-level layers (clipboard chords, font hotkeys,
    the exit-policy key) stay with the caller — the whole-surface `handle`
    stacks them on top of this. Returns `false` when nothing was written
    (child gone, or an unencodable event with no text).
    */
    bool sendKey(in KeyEvent k) @system nothrow @nogc
    {
        // Mode changes must reach the encoder before this frame's first
        // encode — the polling loop's drain-before-input order (the frame's
        // own drain then covers the render).
        if (!drainedThisFrame)
        {
            drainPty();
            drainedThisFrame = true;
        }
        if (s.childExited)
            return false;

        // A terminal-decoded char event carries only `ch`; give the encoder
        // the key identity and the text channel it works through. The GUI
        // arm's events already carry both, so the oracle path is untouched.
        const ke = withKeyIdentity(k);

        ghostty_key_encoder_setopt_from_terminal(s.key_encoder, s.terminal);
        char[128] buf;
        const bytes = encodeKeyEvent(s.key_encoder, s.key_event, ke, buf);
        if (bytes.length > 0)
        {
            pty_write(s.pty_fd, bytes.ptr, bytes.length);
            return true;
        }
        // Text with no encodable key (IME/compose, or a typed code point the
        // key map has no name for — 'A', '!', 'é'), and never on release:
        // written raw, as the polling loop wrote leftover typed bytes.
        if (ke.action != KeyAction.release
            && ghosttyKeyOf(ke) == GHOSTTY_KEY_UNIDENTIFIED && ke.text.length > 0)
        {
            pty_write(s.pty_fd, ke.text.ptr, ke.text.length);
            return true;
        }
        return false;
    }

    /// Scrolls the viewport by `deltaLines` — negative into history. New
    /// output re-pins the viewport to the bottom, as the emulator always has.
    void scrollViewport(int deltaLines) @system nothrow @nogc
    {
        if (!opened || deltaLines == 0)
            return;
        GhosttyTerminalScrollViewport sv;
        sv.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA;
        sv.value.delta = deltaLines;
        ghostty_terminal_scroll_viewport(s.terminal, sv);
    }

    /// The terminal's resolved default background — what an embedder paints
    /// the padding around the pane in, exactly as terminal emulators treat
    /// their own window padding.
    RgbColor background() @system nothrow @nogc
    {
        if (!opened)
            return RgbColor(0, 0, 0);
        GhosttyRenderStateColors colors;
        colors.size = GhosttyRenderStateColors.sizeof;
        ghostty_render_state_colors_get(s.render_state, &colors);
        return RgbColor(colors.background.r, colors.background.g,
            colors.background.b);
    }

    /// The scrollback geometry an embedder's own bar draws from: total rows
    /// (history + screen), the viewport's extent, and its offset from the top.
    Scrollback scrollback() @system nothrow @nogc
    {
        if (!opened)
            return Scrollback();
        GhosttyTerminalScrollbar sb;
        ghostty_terminal_get(s.terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR,
            cast(void*) &sb);
        return Scrollback(total: cast(long) sb.total, len: cast(long) sb.len,
            offset: cast(long) sb.offset);
    }

    /// The last OSC 0/2 title the shell set (empty until one arrives) — an
    /// embedding application's tab label.
    const(char)[] title() const scope return @safe pure nothrow @nogc
        => s.effects_ctx.titleBuf[0 .. s.effects_ctx.titleLen];

    /// True once per title change — the whole-surface `frame` turns it into
    /// `SetWindowTitle`; an embedder refreshes its tab label instead.
    bool takeTitleChanged() @safe pure nothrow @nogc
    {
        const was = s.effects_ctx.titleDirty;
        s.effects_ctx.titleDirty = false;
        return was;
    }

    /**
    Resizes the pty and the VT grid to `cols`×`rows` cells — the embedder's
    grid follow, driven by the pane rect its layout produced (one frame
    behind, by design). Refreshes the cell pixel metrics from the fonts when
    present, no-ops when nothing changed, and leaves a force-redraw for the
    next `decideRedraw`.
    */
    void resize(ushort cols, ushort rows) @system nothrow @nogc
    {
        if (!opened || cols == 0 || rows == 0)
            return;
        int cw = s.cellWidth, ch = s.cellHeight;
        if (s.fonts !is null)
        {
            s.fontSize = s.fonts.size;
            cw = s.fonts.cellW();
            ch = s.fonts.cellH();
        }
        if (cols == s.cols && rows == s.rows
            && cw == s.cellWidth && ch == s.cellHeight)
            return;
        s.cellWidth = cw;
        s.cellHeight = ch;
        resizeGrid(cols, rows);
    }

    // ── internals ───────────────────────────────────────────────────────────

    private void onKey(H)(ref H h, in KeyEvent k)
    {
        // Mode changes must reach the encoder before this frame's first
        // encode — the polling loop's drain-before-input order (`view`'s
        // drain then covers the render).
        if (!drainedThisFrame)
        {
            drainPty();
            drainedThisFrame = true;
        }

        // waitForKey: any key press closes.
        if (s.childExited && s.exitBehavior == ExitBehavior.waitForKey
            && k.action != KeyAction.release)
        {
            h.quit();
            return;
        }
        if (s.childExited)
            return; // nothing to forward to

        // Ctrl+Shift chords: copy / paste, consuming.
        if (k.mods == Mods(ctrl: true, shift: true) && k.action == KeyAction.press)
        {
            if (k.unshifted == 'c' && copySelection(h))
                return;
            if (k.unshifted == 'v')
            {
                const(char)* clip = GetClipboardText();
                if (clip !is null)
                {
                    import core.stdc.string : strlen;

                    pty_write(s.pty_fd, clip, strlen(clip));
                }
                return;
            }
        }

        // Font hotkeys (HST14). Deliberately NOT consuming: the polling loop
        // also forwarded the (harmless) encoded stroke, and identical
        // behavior is the gate.
        if (k.mods.ctrl && k.action == KeyAction.press)
        {
            if (k.unshifted == '=')
                h.fontSize(h.fontSizePx + 2);
            else if (k.unshifted == '-' && h.fontSizePx > 6)
                h.fontSize(h.fontSizePx - 2);
        }

        // The encoder seam (its drain-once no-ops — this method drained above).
        sendKey(k);
    }

    /// Reports a focus edge to the pty when DECSET 1004 is on — the
    /// whole-surface `handle` feeds it window focus; an embedding
    /// application feeds it its own pane-focus edges.
    void notifyFocus(bool focused) @system nothrow @nogc
    {
        if (focused == prevFocused)
            return;
        prevFocused = focused;
        bool focusMode = false;
        if (ghostty_terminal_mode_get(s.terminal, cast(GhosttyMode) 1004, &focusMode) == GHOSTTY_SUCCESS
            && focusMode)
        {
            char[8] fbuf;
            size_t written = 0;
            const fev = focused ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST;
            if (ghostty_focus_encode(fev, fbuf.ptr, fbuf.length, &written) == GHOSTTY_SUCCESS
                && written > 0)
                pty_write(s.pty_fd, fbuf.ptr, written);
        }
    }

    private bool copySelection(H)(ref H h)
    {
        if (!s.selState.start || !s.selState.end)
            return false;

        GhosttyGridRef startSnap, endSnap;
        if (ghostty_tracked_grid_ref_snapshot(s.selState.start, &startSnap) != GHOSTTY_SUCCESS
            || ghostty_tracked_grid_ref_snapshot(s.selState.end, &endSnap) != GHOSTTY_SUCCESS)
            return false;

        GhosttySelection sel;
        sel.start = startSnap;
        sel.end = endSnap;
        sel.rectangle = s.selState.isRectangular;

        GhosttyFormatterTerminalOptions fmtOpts;
        fmtOpts.size = GhosttyFormatterTerminalOptions.sizeof;
        fmtOpts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
        fmtOpts.unwrap = true;
        fmtOpts.trim = true;
        fmtOpts.selection = &sel;

        GhosttyFormatter fmt;
        if (ghostty_formatter_terminal_new(null, &fmt, s.terminal, fmtOpts) != GHOSTTY_SUCCESS)
            return false;
        scope (exit) ghostty_formatter_free(fmt);

        ubyte* outPtr;
        size_t outLen;
        if (ghostty_formatter_format_alloc(fmt, null, &outPtr, &outLen) != GHOSTTY_SUCCESS)
            return false;
        scope (exit) ghostty_free(null, outPtr, outLen);

        // The host's clipboard errand — recorder-assertable, unlike the raw
        // SetClipboardText the polling loop made.
        h.clipboard(cast(const(char)[]) outPtr[0 .. outLen]);
        return true;
    }

    private void resizeGrid(ushort cols, ushort rows) @system nothrow @nogc
    {
        pendingForce = true; // the next decideRedraw must repaint
        s.cols = cols > 0 ? cols : 1;
        s.rows = rows > 0 ? rows : 1;
        ghostty_terminal_resize(s.terminal, s.cols, s.rows, s.cellWidth, s.cellHeight);
        s.effects_ctx.cols = s.cols;
        s.effects_ctx.rows = s.rows;
        s.effects_ctx.cellWidth = s.cellWidth;
        s.effects_ctx.cellHeight = s.cellHeight;
        winsize ws = {
            ws_row: s.rows,
            ws_col: s.cols,
            ws_xpixel: s.fonts is null ? 0 : cast(ushort)(s.cols * s.cellWidth),
            ws_ypixel: s.fonts is null ? 0 : cast(ushort)(s.rows * s.cellHeight),
        };
        ioctl(s.pty_fd, TIOCSWINSZ, &ws);
    }

    private void drainPty() @system nothrow @nogc
    {
        if (s.childExited)
            return;
        char[4096] buf = void;
        while (true)
        {
            const n = read(s.pty_fd, buf.ptr, buf.length);
            if (n > 0)
            {
                feedPtyChunk(s, buf[0 .. n]);
            }
            else if (n == 0)
            {
                s.childExited = true; // EOF: the child closed its end.
                break;
            }
            else
            {
                import core.stdc.errno : EAGAIN, EINTR, errno, EWOULDBLOCK;

                if (errno == EAGAIN || errno == EWOULDBLOCK)
                    break;
                if (errno == EINTR)
                    continue;
                s.childExited = true; // EIO or a real error.
                break;
            }
        }
    }

    private void reapChild() @system nothrow @nogc
    {
        import core.sys.posix.sys.wait : waitpid, WEXITSTATUS, WIFEXITED,
            WIFSIGNALED, WNOHANG, WTERMSIG;

        if (!s.childExited || s.childReaped)
            return;
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
}
