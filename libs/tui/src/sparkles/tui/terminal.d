/++
The terminal backend: the lifecycle owner for a full-screen TUI (spec B1).

$(LREF Terminal.open) enters cbreak raw mode and, per its
$(LREF TerminalOptions), switches to the alternate screen, hides the cursor,
disables autowrap, and enables SGR mouse reporting; $(LREF Terminal.close)
restores every one of those in reverse, and the destructor calls it, so a crash
or early return never leaves the terminal in raw / alt-screen / mouse mode.

Each frame is diffed by a $(REF Screen, sparkles,tui,render) and written wrapped
in synchronized-output markers (DEC 2026) so the terminal composites the whole
frame atomically — no tearing. Output is buffered and flushed with a single
`write(2)`.

Posix-only (termios raw mode + `write`); a Windows console backend is a separate
future concern.
+/
module sparkles.tui.terminal;

version (Posix):

import core.stdc.stdlib : getenv;
import core.stdc.string : strlen;
import core.sys.posix.termios : ECHO, ICANON, IEXTEN, ISIG, tcgetattr, TCSAFLUSH,
    TCSANOW, tcsetattr, termios, VMIN, VTIME;
import core.sys.posix.unistd : STDIN_FILENO, STDOUT_FILENO, write;

import sparkles.base.buffer : SharedBuffer;
import sparkles.base.term_color : classifyColorDepth, ColorDepth;
import sparkles.base.term_control : CtlSeq, DecMode, writeEscapeSeq, writeMouseTracking;
import sparkles.base.term_caps : ImageProtocol, StdStream, terminalSize, TermSize;
import sparkles.base.term_replies : TerminalReplies;

import sparkles.tui.cell : Grid;
import sparkles.tui.images : ImagePlacement, KittyImages;
import sparkles.tui.sixel : CellPixels, SixelImages;
import sparkles.tui.render : Screen;

/// What $(LREF Terminal.open) sets up (and $(LREF Terminal.close) tears down).
struct TerminalOptions
{
    bool altScreen = true;   /// switch to the alternate screen buffer
    bool hideCursor = true;  /// hide the cursor for the session
    bool mouse = true;       /// enable SGR mouse reporting (press + drag + wheel)
    /// With `mouse`: any-event tracking (1003) instead of drag-only (1002),
    /// so bare motion reports too (hover affordances — a divider's resize
    /// cursor). Costs one input event per pointer move.
    bool motion;
}

/// A raw-mode, alt-screen terminal session. Move-only; owns the restore.
struct Terminal
{
    private
    {
        termios _orig;
        TerminalOptions _opts;
        Screen _screen;
        KittyImages _images;
        SixelImages _sixel;
        ImageProtocol _protocol; // what the probe found, and draw speaks
        bool _focusReporting;    // mode 1004 negotiated, to reset on close
        CellPixels _answeredCell; // the terminal's own answer to `CSI 16 t`
        ubyte[] _typedAhead; // input that arrived during a probe, for replay
        SharedBuffer!char _buf;
        int _inFd = STDIN_FILENO;
        int _outFd = STDOUT_FILENO;
        bool _active;
    }

    @disable this(this); // move-only: exactly one owner restores the terminal

    // Every terminal method is `nothrow` (a TUI must not unwind through raw-mode
    // teardown), so it factors out here. Safety / `@nogc` / `pure` genuinely vary
    // per method and stay explicit; `@trusted` is always applied narrowly, never
    // hoisted into this label.
    nothrow:

    /// Enter raw mode on `inFd` and apply `opts`, writing setup to `outFd` (both
    /// default to stdin/stdout; pass an explicit tty fd to drive, say, a pty).
    /// `active` is false if `inFd` isn't a real terminal (nothing was changed).
    static Terminal open(TerminalOptions opts = TerminalOptions(),
        int inFd = STDIN_FILENO, int outFd = STDOUT_FILENO) @trusted
    {
        Terminal t;
        t._opts = opts;
        t._inFd = inFd;
        t._outFd = outFd;
        if (tcgetattr(inFd, &t._orig) != 0)
            return t; // not a tty — leave inactive

        auto raw = t._orig;
        raw.c_lflag &= ~(ECHO | ICANON | ISIG | IEXTEN);
        raw.c_cc[VMIN] = 1;
        raw.c_cc[VTIME] = 0;
        tcsetattr(inFd, TCSAFLUSH, &raw);
        t._active = true;
        t._screen.colorDepth(detectColorDepthEnv()); // fold styles to the real depth

        SharedBuffer!char s;
        if (opts.altScreen)
            writeEscapeSeq!(CtlSeq.enterAltScreen)(s);
        if (opts.hideCursor)
            writeEscapeSeq!(CtlSeq.hideCursor)(s);
        writeEscapeSeq!(DecMode.autowrap, false)(s); // a full-width cell must not wrap/scroll
        if (opts.mouse)
            writeMouseTracking(s, true, opts.motion); // SGR mouse: click + drag + wheel
        writeEscapeSeq!(CtlSeq.pushKeyboardMode)(s); // Kitty progressive keyboard enhancement
        writeAll(outFd, s[]);
        return t;
    }

    /// Whether raw mode was entered (false ⇒ stdin isn't a tty).
    bool active() const @safe pure @nogc => _active;

    ~this() @trusted
    {
        close();
    }

    /// Restore the terminal (idempotent): undo mouse, autowrap, cursor, and the
    /// alt-screen, then the original termios. Safe to call from `scope (exit)`.
    void close() @trusted
    {
        if (!_active)
            return;
        _active = false;

        SharedBuffer!char s;
        if (_opts.mouse)
            writeMouseTracking(s, false, _opts.motion);
        writeEscapeSeq!(DecMode.autowrap, true)(s); // autowrap on
        if (_opts.hideCursor)
            writeEscapeSeq!(CtlSeq.showCursor)(s);
        writeEscapeSeq!(CtlSeq.popKeyboardMode)(s);
        if (_focusReporting)
            writeEscapeSeq!(DecMode.focusReporting, false)(s);
        _images.clear(s); // the terminal need not keep our pixels
        if (_opts.altScreen)
            writeEscapeSeq!(CtlSeq.exitAltScreen)(s);
        writeAll(_outFd, s[]);

        tcsetattr(_inFd, TCSANOW, &_orig);
    }

    /// The current terminal size (falls back to 80×24 if it can't be queried).
    TermSize size() @safe @nogc
    {
        const sz = terminalSize(StdStream.stdout);
        return TermSize(sz.width ? sz.width : 80, sz.height ? sz.height : 24);
    }

    /// Diff `grid` against the last frame and write the minimal update, wrapped in
    /// synchronized-output markers so the terminal composites it atomically.
    ///
    /// `links` is the frame's OSC 8 URI table, indexed from 1 by a cell's
    /// `linkId` (see $(REF Screen.render, sparkles,tui,render)); omit it and no
    /// hyperlink sequence is emitted.
    ///
    /// `images` are the frame's image placements (`IMG5`), drawn inside the
    /// same synchronized frame in the protocol $(LREF probe) found:
    /// kitty places them over the cells (each transmitted once, placed when
    /// new or moved, deleted when gone —
    /// $(REF KittyImages, sparkles,tui,images)); sixel writes them into the
    /// cells, so the cells an image leaves are repainted and an image whose
    /// cells were rewritten is drawn again ($(REF SixelImages,
    /// sparkles,tui,sixel)). A terminal that answered neither draws none.
    /// A hardware scroll moves what the terminal drew, so after one every
    /// image is placed again.
    void draw(in Grid grid, scope const(char)[][] links = null,
        in ImagePlacement[] images = null) @trusted
    {
        _buf.clear();
        writeEscapeSeq!(CtlSeq.syncBegin)(_buf);
        const full = _screen.repaintsFully(grid);
        const none = _protocol != ImageProtocol.kitty && _protocol != ImageProtocol.sixel;
        const ImagePlacement[] shown = none ? null : images;

        bool[] rewritten;
        if (_protocol == ImageProtocol.sixel)
        {
            _sixel.prepare(shown, (int x, int y, int c, int r) { _screen.damage(x, y, c, r); });
            rewritten = new bool[](shown.length);
            foreach (i, ref f; shown)
                rewritten[i] = _screen.changedWithin(grid, f.x, f.y, f.cols, f.rows);
        }
        _screen.render(grid, _buf, links);
        const replace = full || _screen.scrolled;
        if (_protocol == ImageProtocol.sixel)
            _sixel.emit(_buf, shown, cellPixels(), replace, rewritten);
        else
            _images.update(_buf, shown, replace);
        writeEscapeSeq!(CtlSeq.syncEnd)(_buf);
        writeAll(_outFd, _buf[]);
    }

    /// The device size of one cell: the kernel's window size where it carries
    /// pixels, else what the terminal answered to the probe's `CSI 16 t` — a
    /// terminal can know its cell before its window has a size — else `0`s.
    CellPixels cellPixels() @trusted @nogc
    {
        import core.sys.posix.sys.ioctl : ioctl, TIOCGWINSZ, winsize;

        winsize ws;
        if (ioctl(_outFd, TIOCGWINSZ, &ws) == 0 && ws.ws_col && ws.ws_row
            && ws.ws_xpixel && ws.ws_ypixel)
            return CellPixels(cast(ushort)(ws.ws_xpixel / ws.ws_col),
                cast(ushort)(ws.ws_ypixel / ws.ws_row));
        return _answeredCell;
    }

    /**
    Asks the terminal what it can do (`CAP3`): writes
    $(REF queryBattery, sparkles,base,term_replies) and reads until the DA1
    fence or `timeoutMs`, and returns the answers — with the environment they
    came with (`$TERM`, `$COLORTERM`, and whether a `multiplexer` sits in
    between; by default $(LREF underMultiplexer)). A terminal that answers
    nothing costs the timeout and answers nothing. The default is a second,
    as the capability case study's probe used: the fence ends it as soon as a
    terminal answers, and a terminal that has just started can take longer
    than a quarter of one (measured: foot, fresh under a compositor). Replies
    that arrive after it anyway are dropped by the input decoders, which
    never read a control string as keys.

    Not asked at all: Apple Terminal, which prints the queries' payloads as
    text (the capability case study caught it doing so), and the Linux
    console, which is not known to swallow them.

    The answers also set what $(LREF draw) speaks: the image protocol
    $(REF applyReplies, sparkles,base,term_replies) derives from them, except
    sixel where no cell pixel size is known ($(LREF cellPixels)) — its
    pixels could not be sized. See $(LREF imageProtocol).

    Anything else that arrives meanwhile — a key typed during the probe — is
    kept, and handed to the input decoder by $(LREF takeTypedAhead).
    */
    TerminalReplies probe(int timeoutMs = 1000, bool multiplexer = underMultiplexer()) @trusted
    {
        import core.sys.posix.poll : poll, pollfd, POLLIN;
        import core.sys.posix.unistd : read;
        import core.time : MonoTime, msecs;
        import sparkles.base.term_caps : TermCaps;
        import sparkles.base.term_replies : applyReplies, parseReplies, queryBattery;

        TerminalReplies r;
        r.term = env("TERM").idup;
        r.colorterm = env("COLORTERM").idup;
        r.multiplexer = multiplexer;
        if (!_active || env("TERM_PROGRAM") == "Apple_Terminal" || r.term == "linux")
            return r;

        writeAll(_outFd, queryBattery);
        const deadline = MonoTime.currTime + timeoutMs.msecs;
        ubyte[] got;
        ubyte[] rest;
        for (;;)
        {
            const left = (deadline - MonoTime.currTime).total!"msecs";
            if (left <= 0)
                break;
            pollfd pfd;
            pfd.fd = _inFd;
            pfd.events = POLLIN;
            if (poll(&pfd, 1, cast(int) left) <= 0)
                break;
            ubyte[256] chunk = void;
            const n = read(_inFd, chunk.ptr, chunk.length);
            if (n <= 0)
                break;
            got ~= chunk[0 .. n];
            rest = null;
            auto again = TerminalReplies(term: r.term, colorterm: r.colorterm,
                multiplexer: r.multiplexer);
            parseReplies(got, again, rest);
            r = again;
            if (r.fenced)
                break;
        }
        if (!r.fenced && rest is null)
            rest = got;
        _typedAhead ~= rest;
        _answeredCell = CellPixels(r.cellWidth, r.cellHeight);

        TermCaps derived;
        applyReplies(derived, r);
        auto p = derived.images;
        // Sixel draws real pixels: without the cell's pixel size there is no
        // way to size one, so the terminal is taken not to draw them.
        if (p == ImageProtocol.sixel)
        {
            const c = cellPixels();
            if (c.width == 0 || c.height == 0)
                p = ImageProtocol.none;
        }
        _protocol = p;
        return r;
    }

    /**
    Turns on focus reports (mode 1004): the terminal sends `CSI I` / `CSI O`
    as its window gains and loses focus, which the input decoders read as
    `FocusEvent`s. $(LREF close) turns them off again.

    Negotiation, not detection: call it for a terminal that answered for the
    mode ($(LREF probe)'s `focus`), and then — and only then — may the target
    declare focus events.
    */
    void enableFocusReporting() @trusted
    {
        if (!_active || _focusReporting)
            return;
        SharedBuffer!char s;
        writeEscapeSeq!(DecMode.focusReporting, true)(s);
        writeAll(_outFd, s[]);
        _focusReporting = true;
    }

    /// Whether focus reports were turned on ($(LREF enableFocusReporting)).
    bool focusReporting() const @safe pure @nogc => _focusReporting;

    /// The image protocol $(LREF draw) speaks: what $(LREF probe) found and
    /// this terminal can draw, `none` before a probe.
    ImageProtocol imageProtocol() const @safe pure @nogc => _protocol;

    /// What arrived on the input stream during a probe that was not a reply,
    /// in order — the caller's input decoder takes it before reading more.
    ubyte[] takeTypedAhead() @safe pure
    {
        auto t = _typedAhead;
        _typedAhead = null;
        return t;
    }

    /// Force the next $(LREF draw) to repaint in full (after out-of-band output,
    /// or a requested hard redraw).
    void invalidate() @safe
    {
        _screen.invalidate();
    }

    /// Write a raw byte sequence straight to the terminal (an out-of-band control
    /// like an OSC 52 clipboard write or an OSC 0 title set — not screen content).
    void writeRaw(scope const(char)[] s) @trusted
    {
        writeAll(_outFd, s);
    }

    /// Override the color depth used to fold styles (auto-detected from
    /// `$COLORTERM`/`$TERM` at open). The next frame repaints in full.
    void colorDepth(ColorDepth d) @safe
    {
        _screen.colorDepth(d);
    }
}

/// Classify the terminal's color depth from `$COLORTERM`/`$TERM` without the
/// throwing/GC `std.process` path, so `open` stays `nothrow @nogc`.
private ColorDepth detectColorDepthEnv() @trusted nothrow @nogc
    => classifyColorDepth(env("COLORTERM"), env("TERM"));

/// Whether this process runs under a terminal multiplexer (`$TMUX`, `$STY`,
/// `$ZELLIJ`) — whose answers describe it, not the terminal behind it (`CAP7`).
bool underMultiplexer() @safe nothrow @nogc
    => env("TMUX").length || env("STY").length || env("ZELLIJ").length;

// An environment variable, without `std.process`'s throwing, allocating path.
private const(char)[] env(const(char)* name) @trusted nothrow @nogc
{
    const p = getenv(name);
    return p ? p[0 .. strlen(p)] : null;
}

/// Write all of `data` to `fd`, looping over partial / EINTR-interrupted writes.
private void writeAll(int fd, scope const(char)[] data) @trusted nothrow @nogc
{
    import core.stdc.errno : EINTR, errno;

    size_t off;
    while (off < data.length)
    {
        const n = write(fd, data.ptr + off, data.length - off);
        if (n > 0)
            off += n;
        else if (n < 0 && errno == EINTR)
            continue;
        else
            break; // write error; nothing a nothrow sink can do
    }
}

@("terminal.draw.syncFramedDiff")
@safe nothrow
unittest
{
    // We can't open a real terminal under the test harness, but the frame
    // assembly (sync markers + a diffed grid) is exercised through the Screen
    // directly to lock the byte-framing contract the backend relies on.
    import sparkles.base.buffer : SharedBuffer;
    import sparkles.tui.cell : CellStyle;
    import std.algorithm.searching : canFind;

    Grid g;
    g.resize(4, 1);
    g.putText(0, 0, "ok", CellStyle.init);

    Screen scr;
    SharedBuffer!char buf;
    buf.put(cast(string) CtlSeq.syncBegin);
    scr.render(g, buf);
    buf.put(cast(string) CtlSeq.syncEnd);

    assert(buf[].canFind("\x1b[?2026h")); // sync begin
    assert(buf[].canFind("ok"));
    assert(buf[].canFind("\x1b[?2026l")); // sync end
}
