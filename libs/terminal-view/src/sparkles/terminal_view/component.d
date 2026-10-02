/**
The terminal as a `runApp` component (`TVW2`, `TVW5`, `TVW6`).

$(REF TerminalView, sparkles,terminal_view,component) is the whole emulator as
a value: `open` spawns the shell on a pty and wires the VT effects, `view`
drains the pty and makes the dirty/skip decision, `handle` maps
`sparkles:input` events onto the byte-oracle-pinned encoder seam, and `paint`
runs the per-cell renderer inside the host's draw phase (`HST13`). `main`
shrinks to CLI-parse-then-`runApp`.

$(B What stays polled:) the mouse. `handle_mouse` still combines terminal
selection and hover re-scan and is called from `view` exactly as the polling
loop called it. Its scrollbar now runs the toolkit `ScrollView` machine over
the laid-out pane extents (`TVW9`); converting the remaining mouse path to
events is a later, separately-measured step (`TVW6`'s discipline, applied to
input).
Clipboard $(B reads) bypass the host (it has no clipboard-read errand yet):
raylib's `GetClipboardText` on the desktop, the JNI `ClipboardManager` bridge
on Android, where raylib's is a no-op.

$(B Ordering parity:) the polling loop drained the pty before encoding input,
so the encoders always saw the current frame's mode changes. Events arrive
before `view` runs, so the first input event of a frame triggers the drain
lazily and `view` drains again for the render — the same
drain → input → render order, event-shaped.
*/
module sparkles.terminal_view.component;

import core.sys.posix.fcntl : F_GETFD, F_GETFL, F_SETFD, F_SETFL, fcntl,
    FD_CLOEXEC, O_NONBLOCK;
import core.sys.posix.sys.ioctl : ioctl, TIOCSWINSZ, winsize;
import core.sys.posix.sys.types : pid_t;
import core.sys.posix.unistd : chdir, execv, execve, getuid, read, _exit;

import raylib;

import sparkles.base.term_color : RgbColor;
import sparkles.ghostty.c;
import sparkles.input : EndOfInput, Event, FocusEvent, Key, KeyAction, PasteEvent,
    KeyEvent, match, Mods, mousePointer, PointerAction, PointerEvent;
import sparkles.raylib_text : FontSet;
import sparkles.terminal_view.child_env : sanitizeChildEnv;
import sparkles.terminal_view.core;
import sparkles.terminal_view.event_map : encodeKeyEvent, ghosttyButtonOf,
    ghosttyKeyOf, ghosttyModsOf, isDetachedText, utf8Of, withKeyIdentity;
import sparkles.terminal_view.input : ExitBehavior, handle_mouse,
    mouse_encode_and_write, pty_write;
import sparkles.terminal_view.notification_log : NotificationLog,
    NotificationRecord, NotificationRoute, routeNotification;
import sparkles.terminal_view.osc_scan : maxIconBytes, maxTitleBytes, Notification;
import sparkles.terminal_view.protocols : ClipboardReadAnswer, ClipboardReadPolicy,
    ColorScheme, PasteConfirm, PasteConfirmRequest, ProtocolPolicy, TerminalViewHooks;
import sparkles.ui.geometry : Rect;
import sparkles.ui.layout : Frame;
import sparkles.ui.widget : WidgetTree;

/**
Default colours to install over the emulator's: any of the foreground,
background and cursor, and any subset of the 16 ANSI palette entries
(`paletteMask` bit `i` set ⇒ `palette[i]` applies). `ColorOverrides.init`
changes nothing.
*/
struct ColorOverrides
{
    RgbColor foreground, background, cursor;
    bool hasForeground, hasBackground, hasCursor;
    RgbColor[16] palette;
    ushort paletteMask;

    /// Whether anything is overridden.
    bool any() const @safe pure nothrow @nogc
        => hasForeground || hasBackground || hasCursor || paletteMask != 0;
}

private void applyColorOverrides(GhosttyTerminal terminal, in ColorOverrides c) @system nothrow @nogc
{
    if (!c.any)
        return;
    static GhosttyColorRgb rgb(RgbColor x) => GhosttyColorRgb(x.r, x.g, x.b);

    if (c.hasForeground)
    {
        auto v = rgb(c.foreground);
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &v);
    }
    if (c.hasBackground)
    {
        auto v = rgb(c.background);
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &v);
    }
    if (c.hasCursor)
    {
        auto v = rgb(c.cursor);
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &v);
    }
    if (c.paletteMask != 0)
    {
        // The whole 256-entry table is the option's unit: start from the
        // default one and replace the entries the scheme names.
        GhosttyColorRgb[256] palette;
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT,
            cast(void*) &palette);
        foreach (i; 0 .. 16)
            if (c.paletteMask & (1 << i))
                palette[i] = rgb(c.palette[i]);
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, &palette);
    }
}

/// The system clipboard's text (see the module comment: reads bypass the
/// host); empty when it holds none.
private const(char)[] readClipboard() @system
{
    version (Android)
    {
        import sparkles.android.clipboard : getClipboardText;

        return getClipboardText();
    }
    else
    {
        import core.stdc.string : strlen;

        const(char)* clip = GetClipboardText();
        return clip is null ? null : clip[0 .. strlen(clip)];
    }
}

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
    bool cursorMoved;       /// the cursor moved, showed, hid or changed style
    bool warmup;            /// first frames / a pending atlas flush
    bool forced;            /// bench force-redraw or the debug screenshot hook
}

/// Where the cursor is and how it looks, as the render state reports it —
/// what a frame compares to decide whether the cursor alone needs a repaint.
struct CursorSnapshot
{
    ushort x, y;
    bool visible;
    bool inViewport;
    int style;

    /// Read from `state` (after `ghostty_render_state_update`).
    static CursorSnapshot of(GhosttyRenderState state) @system nothrow @nogc
    {
        CursorSnapshot c;
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, cast(void*) &c.visible);
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, cast(void*) &c.inViewport);
        if (c.inViewport)
        {
            ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, cast(void*) &c.x);
            ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, cast(void*) &c.y);
        }
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, cast(void*) &c.style);
        return c;
    }
}

@("terminal_view.component.CursorSnapshot.aCursorOnlyMoveIsSeen")
@system
unittest
{
    // A shell's Ctrl+A over an unchanged line is a carriage return: the
    // cursor moves, no cell changes. That must read as a reason to repaint.
    GhosttyTerminal term;
    GhosttyTerminalOptions topts = { cols: 10, rows: 3 };
    ghostty_terminal_new(null, &term, topts);
    scope (exit) ghostty_terminal_free(term);
    GhosttyRenderState state;
    ghostty_render_state_new(null, &state);
    scope (exit) ghostty_render_state_free(state);

    void write(string bytes)
    {
        ghostty_terminal_vt_write(term, cast(const(ubyte)*) bytes.ptr, cast(uint) bytes.length);
        ghostty_render_state_update(state, term);
    }

    write("$ abc");
    const before = CursorSnapshot.of(state);
    assert(before.inViewport && before.x == 5 && before.y == 0);
    GhosttyRenderStateDirty clean = GHOSTTY_RENDER_STATE_DIRTY_FALSE;
    ghostty_render_state_set(state, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &clean);

    write("\r");
    const after = CursorSnapshot.of(state);
    assert(after.x == 0 && after.y == 0);
    assert(after != before, "the move is visible to the redraw decision");

    // Why the snapshot exists: libghostty-vt reports no dirt for this.
    GhosttyRenderStateDirty dirty;
    ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty);
    assert(dirty == GHOSTTY_RENDER_STATE_DIRTY_FALSE);
}

/// The frame's repaint answer: any reason at all says paint.
bool redrawDecision(in RedrawInputs i) @safe pure nothrow @nogc
    => i.forced || i.contentDirty || i.overlayActive || i.overlayWasActive
    || i.gridChanged || i.exitEdge || i.cursorMoved || i.warmup;

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
    assert(redrawDecision(RedrawInputs(cursorMoved: true)));
    assert(redrawDecision(RedrawInputs(warmup: true)));
    assert(redrawDecision(RedrawInputs(forced: true)));
}

/**
Does a non-blocking `waitpid` result mean this child needs nothing further?

The three outcomes are not interchangeable, and collapsing them into `!= 0` is
a live bug: `-1`/`EINTR` says a signal arrived mid-call and says $(B nothing)
about the child, so treating it as "done" abandons one that is still running.
`EINTR` is therefore not answered here at all — the caller retries it.
*/
private bool reapDone(int rc, int err) @safe pure nothrow @nogc
{
    import core.stdc.errno : ECHILD;

    return rc > 0            // status collected
        || (rc < 0 && err == ECHILD); // not ours — someone else already reaped it
}

@("terminal_view.component.reapDone.outcomesAreNotInterchangeable")
@safe pure nothrow @nogc
unittest
{
    import core.stdc.errno : ECHILD, EINTR, EINVAL;

    // Reaped: the pid comes back.
    assert(reapDone(4242, 0));

    // Alive and unchanged — the whole point of WNOHANG. Nothing to do yet.
    assert(!reapDone(0, 0));

    // Never ours (already reaped elsewhere): nothing left to wait for.
    assert(reapDone(-1, ECHILD));

    // Interrupted: carries no information about the child, so it must NOT read
    // as done — the caller retries. This is the case `!= 0` got wrong, and it
    // is the one that leaves a live shell behind.
    assert(!reapDone(-1, EINTR));

    // Any other failure keeps the escalation going rather than declaring
    // victory on an error we did not anticipate.
    assert(!reapDone(-1, EINVAL));
}

// The TVW8 ring capabilities, decided per backend at compile time: parked
// master reads need `OpRead`; the in-ring reap needs `OpWaitid` (io_uring
// today — the kqueue lowering is event-horizon's O26). Each degrades
// independently: without `OpWaitid` the pump still parks and the per-frame
// `WNOHANG` reap stays; without a ring-driven host the whole sync path stays.
private
{
    import sparkles.event_horizon.backend.concept : canSubmitOp;
    import sparkles.event_horizon.backend.select : DefaultBackend;
    import sparkles.event_horizon.op : OpRead, OpWaitid;

    enum bool ringPumpCapable = canSubmitOp!(DefaultBackend, OpRead);
    enum bool ringReapCapable = canSubmitOp!(DefaultBackend, OpWaitid);
}

/// The `HST15` presence probe, owned here rather than imported: this library
/// must not depend on `sparkles:ui-app`, and the errand is structural — any
/// host-shaped embedder offering `spawnDaemon`/`wake` qualifies.
private enum bool hostSpawnsDaemons(H) = __traits(compiles, (ref H h) {
    bool live = h.spawnDaemon(delegate void() {});
    h.wake();
});

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

    /// An explicit program to run instead of the user's shell: the executable
    /// (an absolute path — no `PATH` search) and its whole argv, `argv[0]`
    /// included (so a login shell spells its `-login` there), null-terminated.
    /// `shellCommand` is ignored when set. Owned by the caller; must outlive
    /// `open`.
    const(char)* program = null;
    /// ditto
    const(char)*[] argv = null;
    /// The child's working directory; null inherits the parent's.
    const(char)* cwd = null;
    /// The child's whole environment, NUL-terminated `KEY=VALUE` entries and
    /// a null terminator; null inherits the parent's (sanitized) environment.
    const(char)*[] env = null;
    /// Default colours replacing the emulator's own — a user colour scheme
    /// (Android's `~/.termux/colors.properties`). Programs may still change
    /// them at run time (OSC 4/10/11/12); these are what a reset returns to.
    ColorOverrides colors;
    /// Adopt this pty master instead of spawning anything: the embedder owns
    /// whatever holds the slave (an in-process installer), and the session
    /// ends when the slave's last holder closes it (EOF/EIO on the master).
    /// The component takes ownership of the fd and closes it. `-1` spawns.
    int adoptMaster = -1;
    /// Poll raylib's mouse each frame (selection, hover, wheel, mouse
    /// reporting). A touch embedder turns it off and routes its own gestures
    /// — `scrollViewport`, `routePointer` — since raylib reports a finger as
    /// a mouse and a drag would otherwise select instead of scroll.
    bool pollMouse = true;
    /// Handle the emulator's own chords — Ctrl+Shift+C/V and Ctrl+=/− — before
    /// the key encoder. An embedder with a binding table of its own turns this
    /// off, resolves those keys itself and calls 100 1 17 62 67 100 131 974 979 986 987 989 990 994 995 997 998LREF TerminalView.copy),
    /// 100 1 17 62 67 100 131 974 979 986 987 989 990 994 995 997 998LREF TerminalView.pasteClipboard) and the host's `fontSize`.
    bool builtinChords = true;

    /// The protocol policy (`TPR9`, `TPR19`–`TPR21`): the application's
    /// `notifications`, `paste` and `clipboard.osc52` settings.
    ProtocolPolicy policy;
    /// What protocol events do — the application's hooks, called from
    /// $(LREF TerminalView.deliverEvents). All optional.
    TerminalViewHooks hooks;
    /// The application's notification log (`TPG9`), shared by its panes and
    /// outliving them; null, the pane records into a log of its own
    /// (`TerminalView.notificationLog`).
    NotificationLog* notificationLog = null;
    /// Whether the target has a Nerd Font, for process icons (`TPR3`).
    bool nerdFont = true;
}

/**
The emulator as a component. Non-copyable once opened: the VT effects hold a
pointer into the embedded state, so the instance must stay put (stack-pin it,
as `main` pins its `CoreState` today, or heap-pin it as an embedder's tabs
do).

Multiple instances may coexist on one thread (`TVW7` — an embedder's tabs):
per-instance state is fully embedded; the process-global PNG decoder registration
is idempotent. Not thread-safe.
*/
struct TerminalView
{
    CoreState s;
    TerminalViewOptions opts;

    private bool opened;
    private bool prevFocused = true;
    private char[] pasteBuf; // a paste's chunks so far, until the last one
    private bool prevOverlayActive;
    private bool prevChildExited;
    // The cursor as last painted (`cursorMoved`): libghostty-vt's dirty flag
    // tracks cells, and a shell moving only the cursor (Ctrl+A, the arrow
    // keys over an unchanged line) dirties none of them.
    private CursorSnapshot prevCursor;
    // Frames painted unconditionally at startup, before dirty-tracking is
    // allowed to skip any. AppKit needs a longer runway than X11/Wayland: it
    // does not present the first swaps until the NSWindow has finished being
    // ordered in, so a two-frame burst is spent on frames nobody sees and the
    // window then stays blank until something else dirties the screen.
    version (OSX)
        private int forceFirstFrames = 30;
    else
        private int forceFirstFrames = 2;
    private bool forceRedrawEnv;
    private bool drainedThisFrame;
    private bool pendingForce;
    /// The default foreground and background `open` installed, before any
    /// overrides: what `recolor` returns to where a new scheme is silent.
    private GhosttyColorRgb baseForeground, baseBackground;
    private bool haveBaseColors;
    private int frameCount;
    /// `TVW8`: a pump daemon owns the pty drain for this run — the sync
    /// `drainPty` becomes a no-op (two readers on one fd would interleave
    /// the byte stream), and where the ring can also reap, the per-frame
    /// `WNOHANG` poll retires with it.
    private bool ringPump;

    // ── protocol state (`TPR`) ──
    // The icon string OSC 0/1 last set (empty: none, the process decides).
    private char[maxIconBytes] iconBuf = 0;
    private size_t iconLen;
    // The validated OSC 7 directory, NUL-terminated.
    private char[4096] cwdBuf = 0;
    private size_t cwdLen;
    // A user rename pins the label against OSC 0/2 until cleared (`TPR3`).
    private char[maxTitleBytes + 1] renamedBuf = 0;
    private size_t renamedLen;
    private bool renamed;
    private bool renameEdge; // a rename or its clearing, not yet taken
    // Can the user see this pane now (`TPR9`)? The embedder says.
    private bool paneSeen = true;
    // An OSC 52 read awaiting the embedder's answer, and the pane's grant.
    private bool readPending;
    private char[12] readSelectors = 0;
    private size_t readSelectorsLen;
    private bool readEndedWithBel;
    private bool readAlways;
    // A paste awaiting confirmation (`TPR19`).
    private char[] pendingPaste;
    private bool pastePending;
    // The log used when the embedder supplies none.
    private NotificationLog* ownLog;

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
        if (opts.adoptMaster >= 0)
        {
            // An embedder's own pty (Android's installer thread holds the
            // slave): no child to fork, and none to reap.
            s.pty_fd = opts.adoptMaster;
            s.child = 0;
            s.childReaped = true;
            winsize ws = {
                ws_row: s.rows,
                ws_col: s.cols,
                ws_xpixel: s.fonts is null ? 0 : cast(ushort)(s.cols * s.cellWidth),
                ws_ypixel: s.fonts is null ? 0 : cast(ushort)(s.rows * s.cellHeight),
            };
            cast(void) ioctl(s.pty_fd, TIOCSWINSZ, &ws);
        }
        else if (!spawnChild())
        {
            ghostty_terminal_free(s.terminal);
            s.terminal = null;
            return false;
        }

        // Close-on-exec, before anything else can fork: `forkpty` returns a
        // plain master, so the NEXT terminal opened in this process hands its
        // shell a copy of THIS one's master. Audited live in the gallery,
        // which is the first embedder to open more than one: the second tab's
        // shell listed `5 -> /dev/ptmx` — the first tab's master, readable and
        // writable by an unrelated shell, and (the functional half) an extra
        // holder keeping that pty open. A hangup is delivered when the LAST
        // master closes, so closing the first tab would not have hung its
        // shell up while the second one lived; the tab would go and the
        // process would stay. `apps/terminal` never saw it — one pty, no
        // second fork. This flag is on the fd the parent keeps, so the child
        // already forked is unaffected: its 0/1/2 are the slave.
        if (fcntl(s.pty_fd, F_SETFD, fcntl(s.pty_fd, F_GETFD) | FD_CLOEXEC) < 0)
        {
            import core.sys.posix.unistd : close;

            close(s.pty_fd);
            s.pty_fd = -1;
            hangUpAndReap();
            s.childReaped = true;
            ghostty_terminal_free(s.terminal);
            s.terminal = null;
            return false;
        }

        // Non-blocking master: read() must return EAGAIN, never stall a frame.
        int flags = fcntl(s.pty_fd, F_GETFL);
        if (flags < 0 || fcntl(s.pty_fd, F_SETFL, flags | O_NONBLOCK) < 0)
        {
            import core.sys.posix.unistd : close;

            // Master first, then the reap — the same ordering `close` documents:
            // the child's hangup does not arrive while a master fd is open.
            close(s.pty_fd);
            s.pty_fd = -1;
            hangUpAndReap();
            s.childReaped = true;
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
        ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_PWD_CHANGED, cast(const(void)*) &effect_pwd_changed);
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
                baseForeground = colors.foreground;
                baseBackground = colors.background;
                haveBaseColors = true;
            }
        }
        applyColorOverrides(s.terminal, opts.colors);
        ghostty_kitty_graphics_placement_iterator_new(null, &s.placement_iter);
        ghostty_key_event_new(null, &s.key_event);
        ghostty_key_encoder_new(null, &s.key_encoder);
        ghostty_mouse_event_new(null, &s.mouse_event);
        ghostty_mouse_encoder_new(null, &s.mouse_encoder);

        opened = true;
        return true;
    }

    /// Resolves the program and forks it on a fresh pty (`s.pty_fd`,
    /// `s.child`); `false` when `forkpty` failed. The child does only
    /// async-signal-safe work between fork and exec.
    private bool spawnChild() @system
    {
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
            return false;
        if (s.child == 0)
        {
            // Only async-signal-safe calls between fork and exec.
            if (opts.cwd !is null)
                cast(void) chdir(opts.cwd);
            const(char)* prog = opts.program !is null ? opts.program : shellZ;
            auto args = opts.program !is null ? cast(char**) opts.argv.ptr
                : cast(char**) argv.ptr;
            if (opts.env !is null)
                execve(prog, args, cast(char**) opts.env.ptr);
            else
                execv(prog, args);
            _exit(127);
        }
        return true;
    }

    /**
    Reaps the child (hanging up its group first if still alive) and frees every
    handle. The fonts and the window belong to the host. Call while its
    graphics context is still alive; `runApp` does this through `shutdown`.

    $(B The master is closed before the child is signalled.) A well-behaved
    shell exits on the EOF/EIO its side reports once the master is gone, and
    macOS will not deliver that hangup while any master fd is still open — so
    on that platform signalling first and closing later meant the child never
    noticed and shutdown blocked in `waitpid` forever.
    */
    void close() @system
    {
        if (!opened)
            return;
        if (s.pty_fd >= 0)
        {
            import core.sys.posix.unistd : close;

            close(s.pty_fd);
            s.pty_fd = -1;
        }
        if (s.child > 0 && !s.childReaped)
        {
            hangUpAndReap();
            s.childReaped = true;
        }
        s.images.release();
        s.synchronizedOutput = typeof(s.synchronizedOutput).init;
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

    /// `runApp` calls this before the graphics context and borrowed fonts close.
    void shutdown(H)(ref H h) @system
    {
        close();
    }

    /**
    Hangs up the child's process group and reaps it, escalating rather than
    blocking.

    A plain `waitpid(child, null, 0)` is a shutdown that never finishes if the
    child ignores `SIGHUP` — a shell with a trap, a foreground process that
    detached from the group. Polling with `WNOHANG` and then sending `SIGKILL`
    bounds it: a cooperative child still exits on its own terms, and an
    uncooperative one cannot hold the window open.

    $(B Every wait here is bounded, including the one after `SIGKILL`.) That
    last one used to block, on the reasoning that an uncatchable signal makes
    the status collectable immediately. It does so almost always — and a
    shutdown path is exactly where "almost" is not good enough: a sampled hang
    caught the process parked in that `wait4` long after the window had closed,
    with the app still running. Nothing here may be unbounded.
    */
    private void hangUpAndReap() @system
    {
        import core.sys.posix.signal : kill, SIGHUP, SIGKILL;
        import core.sys.posix.unistd : getpgid, getpgrp, usleep;

        // No child of ours (an adopted pty): `getpgid(0)` is OUR group, and
        // the hangup below would signal the application itself.
        if (s.child <= 0)
            return;
        if (!s.childExited)
        {
            // The whole foreground group — unless the child has not reached
            // `setsid` yet: a close right after the fork races it, and until
            // then `getpgid(child)` is OUR group, whose hangup would take the
            // application (and whatever launched it) down. The child alone
            // is the right target then.
            const pgid = getpgid(s.child);
            if (pgid <= 0 || pgid == getpgrp())
                kill(s.child, SIGHUP);
            else
                kill(cast(pid_t)(-pgid), SIGHUP);
        }

        // ~50 ms for the shell to notice the hangup (or the EOF its side got
        // when the master closed) and leave on its own terms.
        foreach (_; 0 .. 10)
        {
            if (nothingLeftToReap())
                return;
            usleep(5_000);
        }

        kill(s.child, SIGKILL);

        // ~100 ms for an uncatchable signal to land. If the status is still
        // uncollected after that, give up rather than block: the process is on
        // its way out, and init reaps whatever it orphans. An extra zombie for
        // the moments before exit is a far smaller defect than an application
        // that cannot exit.
        foreach (_; 0 .. 20)
        {
            if (nothingLeftToReap())
                return;
            usleep(5_000);
        }
    }

    /**
    One non-blocking reap attempt: `true` once this child needs nothing further
    — its status was collected, or it was never ours to collect. Retries an
    interrupted call, which is the only outcome that carries no information.
    */
    private bool nothingLeftToReap() @system
    {
        import core.stdc.errno : EINTR, errno;
        import core.sys.posix.sys.wait : waitpid, WNOHANG;

        for (;;)
        {
            const rc = waitpid(s.child, null, WNOHANG);
            if (rc < 0 && errno == EINTR)
                continue;
            return reapDone(rc, errno);
        }
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
            startRingPump(h);
        }

        // Last frame's bracket ended after our paint ran (HST13), so pending
        // font atlas growth can replace its GPU textures here.
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
        wakeForSynchronizedOutput(h);

        // The whole surface is the window: it can be seen while focused and
        // not minimized (`TPR9`). An embedder says so per pane instead.
        setSeen(IsWindowFocused() && !IsWindowMinimized());
        deliverEvents(h);

        // A captured OSC title becomes the window's — the whole surface IS
        // the window here; an embedder consumes takeTitleChanged for its tab
        // (or sets `hooks.titleChanged`, which `deliverEvents` serves first).
        if (takeTitleChanged())
        {
            const t = title;
            char[maxTitleBytes + 1] z = 0;
            z[0 .. t.length] = t[];
            SetWindowTitle(z.ptr);
        }

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
        if (!s.childExited && opts.pollMouse)
            handle_mouse(s.pty_fd, s.mouse_encoder, s.mouse_event, s.terminal,
                s.cellWidth, s.cellHeight, paneCols * s.cellWidth,
                paneRows * s.cellHeight, s.selState, s.sbState,
                s.hoverState);

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
            // Through the host, not raylib's `TakeScreenshot`: the capture has
            // to happen between the last draw call and the buffer swap, and
            // only the arm owning the frame bracket knows when that is. Called
            // directly here it wrote an all-black PNG on macOS, where the swap
            // discards the pixels a post-`EndDrawing` read goes looking for.
            static if (__traits(hasMember, H, "screenshot"))
                if (frameCount == 120)
                    h.screenshot("test_screenshot.png");
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
            (in PasteEvent p) { onPaste(p); },
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
        paintPanePx(h, rect.x * s.cellWidth, rect.y * s.cellHeight,
            rect.width * s.cellWidth, rect.height * s.cellHeight);
    }

    /// $(LREF paintPane) at a pixel rect — for a pane whose origin is not a
    /// whole number of cells from the window's (Android's content rect sits
    /// under a status bar of arbitrary height).
    void paintPanePx(H)(ref H h, int px, int py, int pw, int ph)
    {
        import raylib.rlgl : rlPopMatrix, rlPushMatrix, rlTranslatef;

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
        if (s.synchronizedOutput.held)
        {
            if (s.childExited)
                s.synchronizedOutput.release(s.terminal);
            else
                s.synchronizedOutput.releaseExpired(s.terminal);
        }
    }

    /// Embedded hosts must arm this after pumping, including ring-driven panes:
    /// a child that forgets DECRST may never produce another wake of its own.
    void wakeForSynchronizedOutput(H)(ref H h)
    {
        static if (__traits(hasMember, H, "wakeIn"))
            if (s.synchronizedOutput.held)
                h.wakeIn(s.synchronizedOutput.remaining());
    }

    /**
    Snapshots the render state and answers whether this frame must repaint —
    dirty content, a live/trailing overlay, a resize's force bit, an exit
    edge, or warmup. Advances the edge/warmup bookkeeping, so call it exactly
    once per frame. The whole-surface `frame` turns a `false` into
    `h.skipFrame()`; an embedder folds it into its own frame decision.
    While mode 2026 is held, presentation uses the completed snapshot captured
    at the begin transition; input, queries and timeout recovery stay live.
    */
    bool decideRedraw() @system nothrow @nogc
    {
        if (s.synchronizedOutput.held)
        {
            if (s.childExited)
                s.synchronizedOutput.release(s.terminal);
            else
                s.synchronizedOutput.releaseExpired(s.terminal);
        }
        // The begin transition captured the completed prefix at its exact
        // stream position. Overlay/forced paints use that same immutable
        // snapshot, never an in-progress synchronized update.
        if (!s.synchronizedOutput.held)
            ghostty_render_state_update(s.render_state, s.terminal);

        GhosttyRenderStateDirty dirty = GHOSTTY_RENDER_STATE_DIRTY_FULL;
        ghostty_render_state_get(s.render_state, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty);

        const overlayActive =
            s.effects_ctx.bellFlashFrames > 0
            || s.selState.isSelecting
            || s.hoverState.isHoveringUrl
            || s.sbState.view.v.hovered || s.sbState.view.v.dragging
            || s.sbState.view.vAnim.percent !=
                (s.sbState.view.v.expanded(mousePointer) ? 100 : 0);

        const cursor = CursorSnapshot.of(s.render_state);

        const redraw = redrawDecision(RedrawInputs(
            contentDirty: dirty != GHOSTTY_RENDER_STATE_DIRTY_FALSE
                || (!s.synchronizedOutput.held && s.images.repaintPending),
            overlayActive: overlayActive,
            overlayWasActive: prevOverlayActive,
            gridChanged: pendingForce,
            exitEdge: s.childExited != prevChildExited,
            cursorMoved: cursor != prevCursor,
            warmup: forceFirstFrames > 0,
            forced: forceRedrawEnv || s.debugScreenshotAndExit,
        ));

        pendingForce = false;
        prevOverlayActive = overlayActive;
        prevChildExited = s.childExited;
        prevCursor = cursor;
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

        // Text no key produced, under a pushed kitty mode (`TPR17`, `D23`):
        // a soft keyboard's letters become the press and release of the key
        // that types them, anything else associated text. Without a pushed
        // mode the bytes stay what they always were.
        ubyte kittyFlags;
        if (isDetachedText(k)
            && ghostty_terminal_get(s.terminal, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS,
                &kittyFlags) == GHOSTTY_SUCCESS
            && kittyFlags != 0)
            return sendDetachedText(k);

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

    // ditto — the synthesis. One code point with a key: press + release of
    // it. Otherwise the text alone, which the encoder reports with key 0
    // where associated text is on, and which is written raw where no
    // escape form exists for it.
    private bool sendDetachedText(in KeyEvent k) @system nothrow @nogc
    {
        import sparkles.terminal_view.event_map : softKeyPress;

        dchar c = k.ch;
        size_t cps;
        if (k.text.length)
        {
            // Count code points (lead bytes); a multi-point text has no key.
            foreach (b; k.text)
                cps += (b & 0xC0) != 0x80;
            if (cps == 1 && c == 0)
            {
                import sparkles.base.text.utf : decodeFirstUtf8;

                c = decodeFirstUtf8(k.text);
            }
        }
        else
            cps = 1;

        ghostty_key_encoder_setopt_from_terminal(s.key_encoder, s.terminal);
        char[128] buf;
        KeyEvent press;
        if (cps == 1 && softKeyPress(c, press))
        {
            const down = encodeKeyEvent(s.key_encoder, s.key_event, press, buf);
            if (down.length)
                pty_write(s.pty_fd, down.ptr, down.length);
            else if (press.text.length)
                pty_write(s.pty_fd, press.text.ptr, press.text.length);
            KeyEvent release = press;
            release.action = KeyAction.release;
            release.text(null);
            const up = encodeKeyEvent(s.key_encoder, s.key_event, release, buf);
            if (up.length)
                pty_write(s.pty_fd, up.ptr, up.length);
            return true;
        }

        char[4] ub = void;
        const text = k.text.length ? k.text : ub[0 .. utf8Of(ub, c)];
        if (text.length == 0)
            return false;
        ubyte flags;
        ghostty_terminal_get(s.terminal, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &flags);
        const out_ = kittyTextEvent(text, flags, buf);
        pty_write(s.pty_fd, out_.ptr, out_.length);
        return true;
    }

    /// Install `c` as the default colours of the running terminal (a user
    /// scheme reloaded), and repaint. The scheme replaces the previous one:
    /// what `c` does not name returns to the defaults the terminal opened
    /// with (the cursor and palette to the built-in ones), so an empty `c`
    /// restores them all. `opts.colors` follows, so a later `open` of this
    /// instance starts from the same scheme.
    void recolor(in ColorOverrides c) @system nothrow @nogc
    {
        opts.colors = c;
        if (!opened)
            return;
        ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND,
            haveBaseColors ? &baseForeground : null);
        ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND,
            haveBaseColors ? &baseBackground : null);
        ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, null);
        ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, null);
        applyColorOverrides(s.terminal, c);
        pendingForce = true;
    }

    /// The embedder's own chrome changed (a latched modifier, a moved key
    /// row): the next `decideRedraw` repaints even if the terminal did not.
    void invalidate() @safe pure nothrow @nogc
    {
        pendingForce = true;
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

    /**
    Routes one pointer event — pane-relative $(B cell) coordinates — into
    the pty's mouse encoder (`TVW7`). Mode-aware end to end: nothing is
    written unless the application asked for mouse reporting (DECSET
    1000/1002/1003), so an embedder forwards unconditionally and keeps its
    own routing whenever this returns `false`. Selection, OSC 8 hover and
    the ctrl-click opener remain the whole-surface polled mouse's for now.
    */
    bool sendPointer(in PointerEvent p) @system nothrow @nogc
    {
        if (p.action == PointerAction.leave || !prepMouse(
                p.pos.x, p.pos.y, p.mods,
                p.action == PointerAction.press || p.action == PointerAction.drag))
            return false;

        const btn = ghosttyButtonOf(p.button);
        final switch (p.action)
        {
            case PointerAction.press:
                ghostty_mouse_event_set_action(s.mouse_event, GHOSTTY_MOUSE_ACTION_PRESS);
                ghostty_mouse_event_set_button(s.mouse_event, btn);
                break;
            case PointerAction.release:
                ghostty_mouse_event_set_action(s.mouse_event, GHOSTTY_MOUSE_ACTION_RELEASE);
                ghostty_mouse_event_set_button(s.mouse_event, btn);
                break;
            case PointerAction.move:
            case PointerAction.drag:
                ghostty_mouse_event_set_action(s.mouse_event, GHOSTTY_MOUSE_ACTION_MOTION);
                if (p.action == PointerAction.drag
                    && btn != GHOSTTY_MOUSE_BUTTON_UNKNOWN)
                    ghostty_mouse_event_set_button(s.mouse_event, btn);
                else
                    ghostty_mouse_event_clear_button(s.mouse_event);
                break;
            case PointerAction.leave:
                assert(0);
        }
        mouse_encode_and_write(s.pty_fd, s.mouse_encoder, s.mouse_event);
        return true;
    }

    /**
    The wheel at pane-relative cell `x`,`y`: the scroll buttons when the
    application tracks the mouse; `false` hands the wheel back to the
    embedder — its scrollback to walk.
    */
    bool sendWheel(int dy, int x, int y) @system nothrow @nogc
    {
        if (dy == 0 || !prepMouse(x, y, Mods(), false))
            return false;
        ghostty_mouse_event_set_button(s.mouse_event,
            dy < 0 ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE);
        ghostty_mouse_event_set_action(s.mouse_event, GHOSTTY_MOUSE_ACTION_PRESS);
        mouse_encode_and_write(s.pty_fd, s.mouse_encoder, s.mouse_event);
        ghostty_mouse_event_set_action(s.mouse_event, GHOSTTY_MOUSE_ACTION_RELEASE);
        mouse_encode_and_write(s.pty_fd, s.mouse_encoder, s.mouse_event);
        return true;
    }

    /// The shared half of the mouse seam: the tracking gate, the encoder's
    /// mode/size sync, mods and position (cells → the grid's pixel space).
    private bool prepMouse(int cellX, int cellY, in Mods mods, bool anyPressed)
        @system nothrow @nogc
    {
        if (!opened || s.childExited)
            return false;
        bool tracking = false;
        ghostty_terminal_get(s.terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING,
            cast(void*) &tracking);
        if (!tracking)
            return false;

        ghostty_mouse_encoder_setopt_from_terminal(s.mouse_encoder, s.terminal);
        GhosttyMouseEncoderSize encSize = {
            size: GhosttyMouseEncoderSize.sizeof,
            screen_width: cast(uint)(s.cols * s.cellWidth),
            screen_height: cast(uint)(s.rows * s.cellHeight),
            cell_width: cast(uint) s.cellWidth,
            cell_height: cast(uint) s.cellHeight,
        };
        ghostty_mouse_encoder_setopt(s.mouse_encoder,
            GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &encSize);
        ghostty_mouse_encoder_setopt(s.mouse_encoder,
            GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &anyPressed);
        bool trackCell = true;
        ghostty_mouse_encoder_setopt(s.mouse_encoder,
            GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, &trackCell);

        ghostty_mouse_event_set_mods(s.mouse_event, ghosttyModsOf(mods));
        GhosttyMousePosition gpos = {
            x: cellX * s.cellWidth, y: cellY * s.cellHeight };
        ghostty_mouse_event_set_position(s.mouse_event, gpos);
        return true;
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

    /// The pane's title — the user's rename while one is pinned, else the
    /// last OSC 0/2 title the program set, sanitized (`TPR1`, `TPR2`; empty
    /// until one arrives). An embedding application's tab label.
    const(char)[] title() const scope return @safe pure nothrow @nogc
        => renamed ? renamedBuf[0 .. renamedLen] : programTitle;

    /// The last title the program set, whatever a rename pins.
    const(char)[] programTitle() const scope return @safe pure nothrow @nogc
        => s.effects_ctx.titleBuf[0 .. s.effects_ctx.titleLen];

    /// True once per change of $(LREF title) — the whole-surface `frame`
    /// turns it into `SetWindowTitle`; an embedder refreshes its tab label
    /// instead. While a rename is pinned, program titles change nothing.
    bool takeTitleChanged() @safe pure nothrow @nogc
    {
        const was = s.effects_ctx.titleDirty;
        s.effects_ctx.titleDirty = false;
        const edge = renameEdge;
        renameEdge = false;
        return (was && !renamed) || edge;
    }

    /**
    Pins the pane's title to `name` (a user rename, `TPR3`): OSC 0/2 titles
    keep arriving ($(LREF programTitle)) but no longer label the pane until
    $(LREF clearRename). Sanitized and capped like a program's title.
    */
    void rename(scope const(char)[] name) @safe pure nothrow @nogc
    {
        import sparkles.terminal_view.osc_scan : sanitizeTitle;

        renamedLen = sanitizeTitle(name, renamedBuf[0 .. maxTitleBytes]);
        renamed = true;
        renameEdge = true;
    }

    /// ditto — the program's title labels the pane again.
    void clearRename() @safe pure nothrow @nogc
    {
        renamed = false;
        renameEdge = true;
    }

    /// ditto
    bool isRenamed() const @safe pure nothrow @nogc => renamed;

    /**
    The pane's icon (`TPR3`, `D21`): the icon string OSC 0/1 set (one
    grapheme cluster, at most two cells), else the Nerd Font icon of the
    foreground process, else the generic terminal glyph — and with
    `opts.nerdFont` off, nothing but an OSC icon.
    */
    const(char)[] icon() @system nothrow @nogc
    {
        import sparkles.terminal_view.process_info : foregroundProcess,
            iconForProcess, processName;

        if (iconLen)
            return iconBuf[0 .. iconLen];
        char[64] name;
        const n = processName(foregroundProcess(s.pty_fd), name);
        return iconForProcess(name[0 .. n], opts.nerdFont);
    }

    /// The foreground process's executable name, `null` if unknown (`TPG9`).
    string foregroundProcessName() @system
    {
        import sparkles.terminal_view.process_info : foregroundProcess, processName;

        char[64] name;
        const n = processName(foregroundProcess(s.pty_fd), name);
        return n ? name[0 .. n].idup : null;
    }

    /// The pane's working directory as OSC 7 last reported it (an existing
    /// local directory), empty until one arrives (`TPR4`) — where a tab or
    /// split opened from this pane starts.
    const(char)[] cwd() const scope return @safe pure nothrow @nogc
        => cwdBuf[0 .. cwdLen];

    /**
    Whether the user can see this pane now (`TPR9`) — false while the
    application is in the background or the screen is off, or the pane sits
    on another tab or is zoomed away. The embedder keeps it current; the
    whole-surface `frame` follows window focus.
    */
    void setSeen(bool seen) @safe pure nothrow @nogc
    {
        paneSeen = seen;
    }

    /// ditto
    bool seen() const @safe pure nothrow @nogc => paneSeen;

    /// The log this pane records notifications into (`TPG9`): the
    /// application's when given, else its own.
    NotificationLog* notificationLog() @safe nothrow
    {
        if (opts.notificationLog !is null)
            return opts.notificationLog;
        if (ownLog is null)
            ownLog = new NotificationLog;
        return ownLog;
    }

    /**
    Delivers what the pty asked of the host since the last call (`TPR`):
    the title, icon and working directory to their hooks, notifications
    routed (`TPR9`), logged (`TPG9`) and handed to `hooks.notify`, OSC 52
    writes and reads under `opts.policy` (`TPR20`, `TPR21`). Call it after
    `pump`, from the frame — never from inside a hook. The whole-surface
    `frame` does.
    */
    void deliverEvents(H)(ref H h)
    {
        import sparkles.base.logger : warning;

        if (!opened)
            return;
        auto hooks = &opts.hooks;
        auto inbox = &s.protocol;

        if (hooks.titleChanged !is null && takeTitleChanged())
            hooks.titleChanged(title);

        if (inbox.iconDirty)
        {
            inbox.iconDirty = false;
            iconLen = inbox.iconLen;
            iconBuf[0 .. iconLen] = inbox.icon[0 .. iconLen];
            if (hooks.iconChanged !is null)
                hooks.iconChanged(iconBuf[0 .. iconLen]);
        }

        if (s.effects_ctx.pwdDirty)
        {
            s.effects_ctx.pwdDirty = false;
            if (acceptWorkingDirectory() && hooks.cwdChanged !is null)
                hooks.cwdChanged(cwd);
        }

        if (inbox.notifications.length)
        {
            foreach (ref n; inbox.notifications[])
                deliverNotification(n);
            inbox.notifications.clear(releaseStorage: false);
        }
        if (inbox.droppedNotifications)
        {
            warning(i"terminal: $(inbox.droppedNotifications) notifications dropped (more than 32 in one frame)");
            inbox.droppedNotifications = 0;
        }

        // OSC 52. The payload is never logged (`TPR20`).
        if (inbox.clipboardOversize)
        {
            inbox.clipboardOversize = false;
            warning(i"terminal: an OSC 52 clipboard write over 1 MiB was ignored");
        }
        if (inbox.clipboardWrite)
        {
            inbox.clipboardWrite = false;
            const text = cast(const(char)[]) inbox.clipboard[];
            if (opts.policy.osc52Write)
            {
                if (hooks.clipboardWrite !is null)
                    hooks.clipboardWrite(text);
                else static if (__traits(hasMember, H, "clipboard"))
                    h.clipboard(text);
            }
            inbox.clipboard.clear();
        }
        if (inbox.clipboardRead)
        {
            inbox.clipboardRead = false;
            readSelectorsLen = inbox.readSelectorsLen;
            readSelectors[0 .. readSelectorsLen] = inbox.readSelectors[0 .. readSelectorsLen];
            readEndedWithBel = inbox.readEndedWithBel;
            final switch (opts.policy.osc52Read)
            {
                case ClipboardReadPolicy.deny:
                    break;
                case ClipboardReadPolicy.allow:
                    answerClipboard();
                    break;
                case ClipboardReadPolicy.ask:
                    if (readAlways)
                        answerClipboard();
                    else if (hooks.clipboardReadRequest !is null)
                    {
                        readPending = true;
                        hooks.clipboardReadRequest();
                    }
                    break;
            }
        }
    }

    /**
    The embedder's answer to `hooks.clipboardReadRequest` (`TPR21`): deny
    sends nothing; allowing answers the read with the clipboard's text, and
    `allowAlways` answers every later read from this pane unasked. Without a
    read pending, nothing happens.
    */
    void answerClipboardRead(ClipboardReadAnswer answer) @system
    {
        if (!readPending)
            return;
        readPending = false;
        if (answer == ClipboardReadAnswer.deny)
            return;
        if (answer == ClipboardReadAnswer.allowAlways)
            readAlways = true;
        answerClipboard();
    }

    /// Whether an OSC 52 read awaits `answerClipboardRead`.
    bool clipboardReadPending() const @safe pure nothrow @nogc => readPending;

    // `OSC 52 ; Pc ; base64 ST` — xterm echoes the selection letters it
    // read from and the query's terminator.
    private void answerClipboard() @system
    {
        import std.array : appender;
        import sparkles.base.text.base_codecs : encodeBase64;

        if (s.childExited)
            return;
        const text = opts.hooks.clipboardText !is null
            ? opts.hooks.clipboardText() : readClipboard();
        auto w = appender!(char[]);
        w.put("\x1b]52;");
        w.put(readSelectors[0 .. readSelectorsLen]);
        w.put(';');
        encodeBase64(w, cast(const(ubyte)[]) text);
        w.put(readEndedWithBel ? "\x07" : "\x1b\\");
        pty_write(s.pty_fd, w[].ptr, w[].length);
    }

    private void deliverNotification(in Notification n) @system
    {
        import std.datetime.systime : Clock;

        const route = routeNotification(opts.policy.notifyWhen, paneSeen);
        const tab = opts.hooks.tabTitle !is null ? opts.hooks.tabTitle() : title;
        notificationLog.record(NotificationRecord(
            time: Clock.currTime,
            tabTitle: tab.idup,
            paneTitle: title.idup,
            process: foregroundProcessName(),
            cwd: cwd.idup,
            title: n.title.idup,
            body: n.body.idup,
            protocol: n.protocol,
            route: opts.hooks.notify !is null ? route : NotificationRoute.none,
        ));
        if (opts.hooks.notify !is null)
            opts.hooks.notify(n, route);
    }

    // OSC 7 (`TPR4`): a `file:` URI on this host, or a bare absolute path,
    // naming a directory that exists. Anything else leaves `cwd` as it was.
    private bool acceptWorkingDirectory() @system nothrow @nogc
    {
        import core.sys.posix.sys.stat : S_ISDIR, stat, stat_t;
        import core.sys.posix.unistd : gethostname;
        import sparkles.terminal_view.osc_scan : parseWorkingDirectory;

        if (s.effects_ctx.pwdTooLong)
            return false;
        char[256] host = 0;
        if (gethostname(host.ptr, host.length - 1) != 0)
            host[0] = 0;
        size_t hostLen;
        while (hostLen < host.length && host[hostLen])
            ++hostLen;

        char[4096] path = 0;
        const n = parseWorkingDirectory(s.effects_ctx.pwdBuf[0 .. s.effects_ctx.pwdLen],
            host[0 .. hostLen], path[0 .. $ - 1]);
        if (n == 0)
            return false;
        stat_t st;
        if (stat(path.ptr, &st) != 0 || !S_ISDIR(st.st_mode))
            return false;
        cwdBuf[0 .. n] = path[0 .. n];
        cwdBuf[n] = 0;
        cwdLen = n;
        return true;
    }

    /**
    Follows a light/dark switch (`TPR13`, `TPR14`): installs `colors` as
    the scheme's colours (see $(LREF recolor)) and makes `scheme` the one
    `CSI ? 996 n` reports. When the scheme changed and the program enabled
    mode 2031, it is told once, unsolicited: `CSI ? 997 ; 1 n` (dark) or
    `CSI ? 997 ; 2 n` (light). Calling again with the same scheme recolours
    without reporting.
    */
    void setColorScheme(ColorScheme scheme, in ColorOverrides colors) @system nothrow @nogc
    {
        const before = opened ? schemeInEffect(s.terminal, s.effects_ctx)
            : s.effects_ctx.scheme;
        recolor(colors);
        s.effects_ctx.scheme = scheme;
        s.effects_ctx.schemeSet = true;
        if (!opened || before == scheme || s.childExited)
            return;
        bool report = false;
        if (ghostty_terminal_mode_get(s.terminal, cast(GhosttyMode) 2031, &report) == GHOSTTY_SUCCESS
            && report)
        {
            static immutable dark = "\x1b[?997;1n", light = "\x1b[?997;2n";
            const bytes = scheme == ColorScheme.dark ? dark : light;
            pty_write(s.pty_fd, bytes.ptr, bytes.length);
        }
    }

    /// The scheme `CSI ? 996 n` reports now.
    ColorScheme colorScheme() @system nothrow @nogc
        => opened ? schemeInEffect(s.terminal, s.effects_ctx) : s.effects_ctx.scheme;

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

    /**
    `TVW8`: hand the pty to a daemon on the loop's own scope, where the host
    offers one (`HST15`) and the backend can park a read. The daemon feeds
    `feedPtyChunk` as bytes arrive and wakes the loop; on hangup it marks
    the exit, reaps in-ring where `OpWaitid` exists, and returns. Where any
    piece is missing — a blocking arm, the recorder, a backend without the
    op — the per-frame sync path simply stays, which is why `open` needs no
    answer from this.

    Public because it is the $(B embedder's) hookup too: an application that
    calls `open`/`openCore` itself (the gallery's tabs) calls this right
    after, with its own host, and its per-frame `pump()` degrades to a
    no-op. Idempotent per instance; both `this` and `h` must stay
    address-pinned for the run (the component already is by contract).
    */
    void startRingPump(H)(ref H h)
    {
        static if (ringPumpCapable && hostSpawnsDaemons!H)
        {
            if (ringPump || !opened)
                return;
            // Plain locals for the closure: `this` and `h` are both
            // references whose SLOTS a closure would capture; the referents
            // are address-pinned for the run (the component by contract,
            // the host by its loop's frame).
            auto self = (() @trusted => &this)();
            auto hp = (() @trusted => &h)();
            ringPump = h.spawnDaemon(() { pumpFiber(self, hp); });
        }
    }

    /**
    ditto — whether a daemon carries this instance's pty right now.

    What an $(B embedder) needs to size its own wake: a pane the ring drives
    wakes the loop when bytes arrive, and one still on the sync `pump()` only
    catches up when something else wakes it, so a host running both wants a
    timed wake for exactly as long as it has panes of the second kind. The
    answer changes over a run — `startRingPump` may decline, and the daemon
    clears it on an unexpected error — so it is a question per frame, not a
    fact per open.
    */
    bool ringPumped() const @safe pure nothrow @nogc => ringPump;

    @("terminal_view.component.ringPumpNeedsAnOpenPtyAndAWillingHost")
    @safe unittest
    {
        // Heap, not the stack: this value is far larger than the 512 KiB a
        // non-main thread gets on macOS, and the test runner runs on one.
        auto tv = new TerminalView;

        // Never opened: nothing to read, so no daemon may be spawned — the
        // guard that stops a fiber parking on a fd that does not exist. A
        // host that would happily supply one changes nothing here.
        static struct EagerHost
        {
            size_t asks;
            bool spawnDaemon(scope void delegate() body_) { ++asks; return true; }
            void wake() {}
        }

        EagerHost h;
        tv.startRingPump(h);
        assert(h.asks == 0, "an unopened view must not spawn a pump");
        assert(!tv.ringPumped);

        // And a host with no errand at all leaves the sync path in place
        // rather than failing to compile at the call site — which is what
        // lets one embedder serve the recorder and a live loop alike.
        static struct PlainHost {}

        PlainHost p;
        tv.startRingPump(p);
        assert(!tv.ringPumped);
    }

    /// ditto — the daemon body.
    private static void pumpFiber(H)(TerminalView* tv, H* h)
    {
        import core.lifetime : move;
        import core.stdc.errno : EAGAIN, EINTR, errno, EIO, EWOULDBLOCK;

        import sparkles.base.buffer : SharedBuffer;
        import sparkles.event_horizon.io : FileHandle, ringRead = read;

        bool hangup = false;
        while (!hangup && tv.opened && !tv.s.childExited)
        {
            SharedBuffer!(ubyte, 4096) chunk;
            chunk.length = 4096;
            auto got = ringRead(FileHandle(tv.s.pty_fd), move(chunk));
            chunk = move(got.buf);
            if (got.res.hasError)
            {
                // Only the pty's own hangup means the shell is gone. A
                // cancelled read — the scope tearing down around a live
                // child — must not claim an exit, or `close` would skip
                // the SIGHUP and then block reaping a running shell. Any
                // such error also hands the drain back to the sync path:
                // a dead pump with `ringPump` still set would freeze the
                // terminal, and during teardown the flag no longer matters.
                if (got.res.error.errnoValue != EIO)
                {
                    tv.ringPump = false;
                    h.wake();
                    return;
                }
                break;
            }
            if (got.res.value == 0)
                break; // EOF: the child closed its end
            feedPtyChunk(tv.s, cast(const(char)[]) chunk[][0 .. got.res.value]);

            // Burst drain: the parked read paid the ring round-trip for the
            // burst's FIRST chunk; the rest is read synchronously until
            // `EAGAIN` — the old tight loop, on the fiber that owns the fd.
            // Without this, churn-rate output costs a ring round-trip and
            // two fiber switches per 4 KiB (measured: 97.8% → 109.5% CPU on
            // the churn scenario); with it, one round-trip per burst.
            char[4096] buf = void;
            for (;;)
            {
                const n = read(tv.s.pty_fd, buf.ptr, buf.length);
                if (n > 0)
                {
                    feedPtyChunk(tv.s, buf[0 .. n]);
                    continue;
                }
                if (n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK
                    && errno != EINTR))
                {
                    hangup = true; // EOF or EIO: fall through to the reap
                    break;
                }
                if (errno == EINTR)
                    continue;
                break; // EAGAIN: burst drained, park again
            }
            h.wake();
        }
        if (!tv.opened)
            return;
        tv.s.childExited = true;

        // The in-ring reap (`TVW8`): the same decode the sync `reapChild`
        // makes, parked instead of polled. On a cancelled teardown the op
        // errors and the sync/teardown paths still hold the reap contract.
        static if (ringReapCapable)
            if (!tv.s.childReaped && tv.s.child > 0)
            {
                import sparkles.event_horizon.live : waitPid;

                auto st = waitPid(tv.s.child);
                if (!st.hasError)
                {
                    tv.s.childReaped = true;
                    tv.s.childStatus = st.value.signaled
                        ? 128 + st.value.code : st.value.code;
                }
            }
        h.wake();
    }

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
        if (opts.builtinChords && k.mods == Mods(ctrl: true, shift: true)
            && k.action == KeyAction.press)
        {
            if (k.unshifted == 'c' && copySelection(h))
                return;
            if (k.unshifted == 'v')
            {
                sendPaste(readClipboard());
                return;
            }
        }

        // Font hotkeys (HST14). Deliberately NOT consuming: the polling loop
        // also forwarded the (harmless) encoded stroke, and identical
        // behavior is the gate.
        if (opts.builtinChords && k.mods.ctrl && k.action == KeyAction.press)
        {
            if (k.unshifted == '=')
                h.fontSize(h.fontSizePx + 2);
            else if (k.unshifted == '-' && h.fontSizePx > 6)
                h.fontSize(h.fontSizePx - 2);
        }

        // The encoder seam (its drain-once no-ops — this method drained above).
        sendKey(k);
    }

    /**
    A paste reaching the pane (`INP21`): its chunks are collected until the
    last one, then the whole of it goes to the shell by $(LREF sendPaste).
    */
    void onPaste(in PasteEvent p) @system
    {
        if (s.childExited)
            return;
        pasteBuf ~= p.text[];
        if (!p.last)
            return;
        sendPaste(pasteBuf);
        pasteBuf.length = 0;
    }

    /**
    Writes pasted `text` to the shell the way a terminal does (`TPR18`):
    C0 controls other than HT, LF and CR removed first — so no byte sequence
    in it can close a bracket (`ESC [ 201 ~` loses its `ESC`) — then
    libghostty's paste encoder, which wraps it in `CSI 200~` … `CSI 201~`
    when the program turned bracketed paste on (DECSET 2004), else turns
    newlines into carriage returns.

    Without bracketed paste, a paste the policy says to confirm (`TPR19`,
    `opts.policy.pasteConfirm`: a line break by default) is held and
    `hooks.pasteConfirm` asked; $(LREF confirmPaste) sends or drops it.
    */
    void sendPaste(in char[] text) @system
    {
        if (text.length == 0 || s.childExited)
            return;
        auto clean = stripPasteControls(text);
        if (clean.length == 0)
            return;
        if (!bracketedPaste && opts.hooks.pasteConfirm !is null
            && pasteNeedsConfirm(opts.policy.pasteConfirm, clean))
        {
            pendingPaste = clean;
            pastePending = true;
            opts.hooks.pasteConfirm(PasteConfirmRequest(pasteLines(clean), clean));
            return;
        }
        writePaste(clean);
    }

    /// The embedder's answer to `hooks.pasteConfirm`: `send` writes the held
    /// paste (bracketed if the program has meanwhile enabled it), otherwise
    /// it is dropped and nothing is sent (`TPR19`).
    void confirmPaste(bool send) @system
    {
        if (!pastePending)
            return;
        pastePending = false;
        auto text = pendingPaste;
        pendingPaste = null;
        if (send && !s.childExited)
            writePaste(text);
    }

    /// Whether a paste awaits `confirmPaste`.
    bool pasteConfirmPending() const @safe pure nothrow @nogc => pastePending;

    private bool bracketedPaste() @system nothrow @nogc
    {
        bool bracketed = false;
        ghostty_terminal_mode_get(s.terminal, cast(GhosttyMode) 2004, &bracketed);
        return bracketed;
    }

    private void writePaste(in char[] clean) @system
    {
        const encoded = encodedPaste(clean, bracketedPaste);
        if (encoded.length)
            pty_write(s.pty_fd, encoded.ptr, encoded.length);
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

    /**
    The terminal's text as plain lines — scrollback and screen, soft wraps
    joined, trailing blanks trimmed; `null` when unopened or on failure. What
    a test (or an on-device oracle) reads instead of pixels.
    */
    string screenText() @system
    {
        if (!opened)
            return null;

        GhosttyFormatterTerminalOptions fmtOpts;
        fmtOpts.size = GhosttyFormatterTerminalOptions.sizeof;
        fmtOpts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
        fmtOpts.unwrap = true;
        fmtOpts.trim = true;

        GhosttyFormatter fmt;
        if (ghostty_formatter_terminal_new(null, &fmt, s.terminal, fmtOpts) != GHOSTTY_SUCCESS)
            return null;
        scope (exit) ghostty_formatter_free(fmt);

        ubyte* outPtr;
        size_t outLen;
        if (ghostty_formatter_format_alloc(fmt, null, &outPtr, &outLen) != GHOSTTY_SUCCESS)
            return null;
        scope (exit) ghostty_free(null, outPtr, outLen);
        return (cast(const(char)[]) outPtr[0 .. outLen]).idup;
    }

    /**
    Copies the selection to the clipboard (the `copy` command of an embedder
    that resolves its own keys); false when nothing is selected.
    */
    bool copy(H)(ref H h) => copySelection(h);

    /// Pastes the clipboard into the program, through the paste guard
    /// (`TPR18`, `TPR19`) — the `paste` command of such an embedder.
    void pasteClipboard() @system
    {
        sendPaste(opts.hooks.clipboardText !is null
            ? opts.hooks.clipboardText() : readClipboard());
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
        // libghostty explicitly ends synchronization on resize. Retire our
        // matching gate as well; the new dimensions must be visible now.
        s.synchronizedOutput.observe(s.terminal, s.render_state);
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
        // `TVW8`: the pump daemon owns the fd — a second reader would
        // interleave the byte stream. Everything already fed by the daemon
        // is in; the drain-before-encode guarantee holds by arrival order.
        if (ringPump)
            return;
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

        // `TVW8`: where the ring can reap, the pump daemon does — a second
        // `waitpid` here would race it for the same pid. Without `OpWaitid`
        // the daemon only marks the exit and this poll keeps the reap.
        static if (ringReapCapable)
            if (ringPump)
                return;
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

/**
`text` as a pane writes it to its shell: libghostty's paste encoding —
unsafe control bytes replaced, wrapped in `CSI 200~` … `CSI 201~` when
`bracketed`, else newlines turned into carriage returns.
*/
char[] encodedPaste(in char[] text, bool bracketed) @trusted
{
    auto data = text.dup; // the encoder rewrites its input in place
    size_t needed = 0;
    ghostty_paste_encode(data.ptr, data.length, bracketed, null, 0, &needed);
    auto encoded = new char[](needed);
    size_t written = 0;
    if (ghostty_paste_encode(data.ptr, data.length, bracketed,
            encoded.ptr, encoded.length, &written) != GHOSTTY_SUCCESS)
        return null;
    return encoded[0 .. written];
}

/**
A pure text event — text no key produced — under kitty flags `flags`
(`TPR17`): "If no known key is associated with the text the key number 0
must be used", so with report-all-keys (`0b1000`) it is `CSI 0 u`, its code
points appended as the third field when associated text (`0b10000`) is on;
without report-all-keys, the text itself. The same shapes as kitty's own
encoder (`key_encoding.c`, `serialize`). libghostty's key encoder emits
nothing for a key-less event, hence this.
*/
const(char)[] kittyTextEvent(scope const(char)[] text, ubyte flags, return scope char[] buf)
    @safe pure nothrow @nogc
{
    import sparkles.base.text.utf8 : utf8SequenceLength;

    if (!(flags & 8))
    {
        const n = text.length <= buf.length ? text.length : buf.length;
        buf[0 .. n] = text[0 .. n];
        return buf[0 .. n];
    }
    size_t len;
    void put(scope const(char)[] s)
    {
        foreach (ch; s)
            if (len < buf.length)
                buf[len++] = ch;
    }
    void putNumber(uint v)
    {
        char[10] d;
        size_t i = d.length;
        do
        {
            d[--i] = cast(char)('0' + v % 10);
            v /= 10;
        }
        while (v);
        put(d[i .. $]);
    }

    put("\x1b[0");
    if (flags & 16)
    {
        put(";;");
        bool first = true;
        for (size_t i = 0; i < text.length;)
        {
            uint cp = text[i];
            size_t n = 1;
            if (cp >= 0x80)
            {
                n = utf8SequenceLength(text, i);
                if (n == 0)
                {
                    ++i;
                    continue;
                }
                cp &= n == 2 ? 0x1F : n == 3 ? 0x0F : 0x07;
                foreach (b; text[i + 1 .. i + n])
                    cp = (cp << 6) | (b & 0x3F);
            }
            i += n;
            if (cp < 0x20 || (cp >= 0x7F && cp <= 0x9F))
                continue; // "must not contain control codes"
            if (!first)
                put(":");
            first = false;
            putNumber(cp);
        }
    }
    put("u");
    return buf[0 .. len];
}

///
@("terminal_view.component.kittyTextEvent")
@safe pure nothrow @nogc unittest
{
    char[64] b;
    // kitty keyboard-protocol.rst: `alt+a -> CSI 0 ; ; 229 u` (text 'å').
    assert(kittyTextEvent("å", 8 | 16, b) == "\x1b[0;;229u");
    assert(kittyTextEvent("👍🏽", 8 | 16, b) == "\x1b[0;;128077:127997u");
    assert(kittyTextEvent("©", 8, b) == "\x1b[0u");
    assert(kittyTextEvent("©", 1 | 2, b) == "©");
}

/// `text` without the C0 controls a paste may not carry (`TPR18`): all but
/// HT, LF and CR.
char[] stripPasteControls(in char[] text) @safe pure nothrow
{
    char[] clean;
    clean.reserve(text.length);
    foreach (c; text)
        if (c >= 0x20 || c == '\t' || c == '\n' || c == '\r')
            clean ~= c;
    return clean;
}

/// The lines a paste spans: its line breaks (CR LF counts once), plus the
/// unterminated last line if any.
size_t pasteLines(in char[] text) @safe pure nothrow @nogc
{
    size_t lines;
    foreach (i, c; text)
        if (c == '\n' || (c == '\r' && (i + 1 == text.length || text[i + 1] != '\n')))
            ++lines;
    const last = text.length ? text[$ - 1] : '\n';
    return lines + (last != '\n' && last != '\r' ? 1 : 0);
}

/// Whether `policy` asks before sending `text` without bracketed paste.
bool pasteNeedsConfirm(PasteConfirm policy, in char[] text) @safe pure nothrow @nogc
{
    final switch (policy)
    {
        case PasteConfirm.never:
            return false;
        case PasteConfirm.always:
            return true;
        case PasteConfirm.multiline:
            foreach (c; text)
                if (c == '\n' || c == '\r')
                    return true;
            return false;
    }
}

///
@("terminal_view.component.pasteHelpers")
@safe pure nothrow unittest
{
    assert(stripPasteControls("a\x1b[201~b\x00\x07\tc\r\nd\x7f") == "a[201~b\tc\r\nd\x7f");
    assert(pasteLines("one") == 1);
    assert(pasteLines("one\n") == 1);
    assert(pasteLines("one\r\ntwo") == 2);
    assert(pasteLines("a\rb\nc\n") == 3);
    assert(pasteLines("") == 0);
    assert(pasteNeedsConfirm(PasteConfirm.multiline, "a\nb"));
    assert(!pasteNeedsConfirm(PasteConfirm.multiline, "ab"));
    assert(pasteNeedsConfirm(PasteConfirm.always, "ab"));
    assert(!pasteNeedsConfirm(PasteConfirm.never, "a\nb"));
}

@("terminal_view.component.pasteIsTextForTheShell")
@safe unittest
{
    // With bracketed paste on, a multi-line paste is one bracketed text —
    // not a run of commands — and an escape inside it cannot end the
    // bracket early.
    assert(encodedPaste("ls\nrm -rf x\x1b[201~", true)
        == "\x1b[200~ls\nrm -rf x [201~\x1b[201~");
    // Without it, newlines become carriage returns, as a keyboard sends.
    assert(encodedPaste("a\nb", false) == "a\rb");
}

@("terminal_view.component.explicitProgramRunsWithItsOwnCwdAndEnv")
@system unittest
{
    import core.thread : Thread;
    import core.time : msecs;
    import std.algorithm.searching : canFind;

    // What a launcher that is not a login shell needs (Android's
    // nix-on-droid `login`): an absolute program, argv[0] of its choosing,
    // a working directory and a whole environment — none of them inherited.
    static immutable(char)*[4] argv = [
        "-probe", "-c", `printf '%s|%s|%s' "$0" "$(pwd)" "$PROBE_VAR"`, null,
    ];
    static immutable(char)*[3] env = ["PROBE_VAR=from-env", "PATH=/usr/bin:/bin", null];

    TerminalView tv;
    tv.opts = TerminalViewOptions(
        program: "/bin/sh",
        argv: cast(const(char)*[]) argv[],
        cwd: "/",
        env: cast(const(char)*[]) env[],
        exitBehavior: ExitBehavior.hold,
    );
    assert(tv.openCore(80, 4, 0, 0), "the pty and the child spawned");
    scope (exit) tv.close();

    foreach (_; 0 .. 200)
    {
        tv.pump();
        if (tv.s.childExited)
            break;
        Thread.sleep(10.msecs);
    }
    tv.pump(); // anything written just before the exit
    const text = tv.screenText();
    assert(text.canFind("-probe|/|from-env"), text);
}

@("terminal_view.component.anAdoptedPtyEndsWhenItsSlaveCloses")
@system unittest
{
    import core.sys.posix.fcntl : O_NOCTTY, O_RDWR, open;
    import core.sys.posix.unistd : close, write;
    import core.thread : Thread;
    import core.time : msecs;
    import std.algorithm.searching : canFind;
    import sparkles.terminal_view.protocol_oracle : openTestPty;

    // What an in-process program (Android's installer) looks like to the
    // component: a pty whose slave some thread of ours holds — no child.
    char[128] slavePath = 0;
    const master = openTestPty(slavePath);
    const slave = open(slavePath.ptr, O_RDWR | O_NOCTTY);
    assert(slave >= 0);

    TerminalView tv;
    tv.opts = TerminalViewOptions(adoptMaster: master, exitBehavior: ExitBehavior.hold);
    assert(tv.openCore(40, 4, 0, 0));
    scope (exit) tv.close();

    enum hello = "from the installer\r\n";
    assert(write(slave, hello.ptr, hello.length) == hello.length);
    foreach (_; 0 .. 100)
    {
        tv.pump();
        if (tv.screenText().canFind("from the installer"))
            break;
        Thread.sleep(5.msecs);
    }
    assert(tv.screenText().canFind("from the installer"));
    assert(!tv.s.childExited);

    close(slave);
    foreach (_; 0 .. 100)
    {
        tv.pump();
        if (tv.s.childExited)
            break;
        Thread.sleep(5.msecs);
    }
    assert(tv.s.childExited, "the last slave holder closing ends the session");
    assert(tv.s.childReaped, "and there is no child to reap");
}

@("terminal_view.component.colorOverridesBecomeTheDefaults")
@system unittest
{
    // A user scheme (Termux's colors.properties on Android) replaces the
    // defaults a reset returns to: foreground and one ANSI entry here, the
    // rest untouched.
    ColorOverrides c;
    c.foreground = RgbColor(1, 2, 3);
    c.hasForeground = true;
    c.palette[1] = RgbColor(9, 8, 7);
    c.paletteMask = 1 << 1;

    TerminalView tv;
    tv.opts = TerminalViewOptions(program: "/bin/sh",
        argv: [cast(const(char)*) "sh", "-c", "exit 0", null], colors: c);
    assert(tv.openCore(20, 2, 0, 0));
    scope (exit) tv.close();

    GhosttyColorRgb[256] palette, defaults;
    ghostty_terminal_get(tv.s.terminal, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT,
        cast(void*) &palette);
    assert(palette[1] == GhosttyColorRgb(9, 8, 7));
    assert(palette[2] != GhosttyColorRgb(9, 8, 7), "only the named entry changes");

    GhosttyRenderStateColors colors;
    colors.size = GhosttyRenderStateColors.sizeof;
    ghostty_render_state_update(tv.s.render_state, tv.s.terminal);
    assert(ghostty_render_state_colors_get(tv.s.render_state, &colors) == GHOSTTY_SUCCESS);
    assert(colors.foreground == GhosttyColorRgb(1, 2, 3));
}

@("terminal_view.component.recolorReplacesTheScheme")
@system unittest
{
    // `termux-reload-settings` after deleting colors.properties: an empty
    // scheme must restore the colours the terminal opened with, not keep the
    // last one's.
    TerminalView tv;
    tv.opts = TerminalViewOptions(program: "/bin/sh",
        argv: [cast(const(char)*) "sh", "-c", "exit 0", null]);
    assert(tv.openCore(20, 2, 0, 0));
    scope (exit) tv.close();

    GhosttyRenderStateColors colors;
    colors.size = GhosttyRenderStateColors.sizeof;
    GhosttyRenderStateColors current()
    {
        ghostty_render_state_update(tv.s.render_state, tv.s.terminal);
        assert(ghostty_render_state_colors_get(tv.s.render_state, &colors) == GHOSTTY_SUCCESS);
        return colors;
    }
    const opened = current();

    ColorOverrides red;
    red.background = RgbColor(170, 0, 0);
    red.hasBackground = true;
    red.palette[1] = RgbColor(9, 8, 7);
    red.paletteMask = 1 << 1;
    tv.recolor(red);
    assert(current().background == GhosttyColorRgb(170, 0, 0));
    assert(current().palette[1] == GhosttyColorRgb(9, 8, 7));

    tv.recolor(ColorOverrides.init);
    assert(current().background == opened.background, "the background is restored");
    assert(current().foreground == opened.foreground);
    assert(current().palette[1] == opened.palette[1], "and the palette");
}

@("terminal_view.component.synchronizedOutputPreservesCompletedFrames")
@system unittest
{
    import core.sys.posix.unistd : pipe, close;
    import core.time : Duration;

    TerminalView tv;
    tv.forceFirstFrames = 0;
    GhosttyTerminalOptions options = { cols: 30, rows: 3 };
    assert(ghostty_terminal_new(null, &tv.s.terminal, options) == GHOSTTY_SUCCESS);
    scope (exit) ghostty_terminal_free(tv.s.terminal);
    ghostty_render_state_new(null, &tv.s.render_state);
    scope (exit) ghostty_render_state_free(tv.s.render_state);
    ghostty_render_state_row_iterator_new(null, &tv.s.row_iter);
    scope (exit) ghostty_render_state_row_iterator_free(tv.s.row_iter);
    ghostty_render_state_row_cells_new(null, &tv.s.cells);
    scope (exit) ghostty_render_state_row_cells_free(tv.s.cells);

    int[2] replies;
    assert(pipe(replies) == 0);
    scope (exit)
    {
        close(replies[0]);
        close(replies[1]);
    }
    assert(fcntl(replies[0], F_SETFL, O_NONBLOCK) == 0);
    tv.s.effects_ctx.pty_fd = replies[1];
    ghostty_terminal_set(tv.s.terminal, GHOSTTY_TERMINAL_OPT_USERDATA,
        cast(const(void)*) &tv.s.effects_ctx);
    ghostty_terminal_set(tv.s.terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY,
        cast(const(void)*) &effect_write_pty);

    uint firstCell()
    {
        ghostty_render_state_get(tv.s.render_state,
            GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &tv.s.row_iter);
        assert(ghostty_render_state_row_iterator_next(tv.s.row_iter));
        ghostty_render_state_row_get(tv.s.row_iter,
            GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &tv.s.cells);
        assert(ghostty_render_state_row_cells_next(tv.s.cells));
        uint count;
        ghostty_render_state_row_cells_get(tv.s.cells,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &count);
        assert(count == 1);
        uint codepoint;
        ghostty_render_state_row_cells_get(tv.s.cells,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &codepoint);
        return codepoint;
    }

    void painted()
    {
        ghostty_render_state_get(tv.s.render_state,
            GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &tv.s.row_iter);
        bool clean = false;
        while (ghostty_render_state_row_iterator_next(tv.s.row_iter))
            ghostty_render_state_row_set(tv.s.row_iter,
                GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &clean);
        GhosttyRenderStateDirty dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE;
        ghostty_render_state_set(tv.s.render_state,
            GHOSTTY_RENDER_STATE_OPTION_DIRTY, &dirty);
    }

    feedPtyChunk(tv.s, "old");
    assert(tv.decideRedraw() && firstCell() == 'o');
    painted();
    feedPtyChunk(tv.s, "\x1b[?20");
    assert(!tv.decideRedraw());
    feedPtyChunk(tv.s, "26h\rpartial");
    assert(tv.s.synchronizedOutput.held);
    assert(!tv.decideRedraw() && firstCell() == 'o');
    assert(CursorSnapshot.of(tv.s.render_state).x == 3);

    // Queries consume the live state and reply immediately, without exposing
    // the partial frame to the renderer or blocking the pty pump.
    feedPtyChunk(tv.s, "\x1b[?2026$p\x1b[6n");
    char[80] reply;
    const count = read(replies[0], reply.ptr, reply.length);
    assert(count > 0);
    assert(reply[0 .. count] == "\x1b[?2026;1$y\x1b[1;8R");
    assert(!tv.decideRedraw() && firstCell() == 'o');

    feedPtyChunk(tv.s, "\rfinal\x1b[?2026l");
    assert(!tv.s.synchronizedOutput.held);
    assert(tv.decideRedraw() && firstCell() == 'f');
    painted();

    // Text preceding a begin in the SAME read is already complete. It must
    // become the snapshot, not the older painted frame or the partial body.
    feedPtyChunk(tv.s, "\rprefix\x1b[?2026h\runfinished");
    assert(tv.decideRedraw() && firstCell() == 'p');
    painted();
    assert(!tv.decideRedraw());
    tv.pendingForce = true;
    assert(tv.decideRedraw() && firstCell() == 'p',
        "forced and overlay paints retain the held snapshot");
    painted();

    // End and another begin within one read capture the intervening complete
    // frame, even when the host never gets a turn between those bytes.
    feedPtyChunk(tv.s, "\x1b[?2026l\x1b[?2026h\rsecond");
    assert(tv.s.synchronizedOutput.held);
    assert(tv.decideRedraw() && firstCell() == 'u');
    painted();

    feedPtyChunk(tv.s, "\x1bcreset");
    assert(!tv.s.synchronizedOutput.held);
    assert(tv.decideRedraw() && firstCell() == 'r');
    painted();

    feedPtyChunk(tv.s, "\x1b[?2026h\rresized");
    tv.resizeGrid(35, 4);
    assert(!tv.s.synchronizedOutput.held);
    assert(tv.decideRedraw() && firstCell() == 'r');
    assert(CursorSnapshot.of(tv.s.render_state).x == 7);
    painted();

    feedPtyChunk(tv.s, "\x1b[?2026h\reof");
    tv.s.childExited = true;
    assert(tv.decideRedraw() && firstCell() == 'e');
    assert(!tv.s.synchronizedOutput.held);
    assert(tv.s.synchronizedOutput.remaining() == Duration.max);
}
