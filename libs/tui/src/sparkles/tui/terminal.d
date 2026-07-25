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

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.term_color : classifyColorDepth, ColorDepth;
import sparkles.base.term_control : CtlSeq, DecMode, writeEscapeSeq, writeMouseTracking;
import sparkles.core_cli.term_caps : StdStream, terminalSize, TermSize;

import sparkles.tui.cell : Grid;
import sparkles.tui.render : Screen;

/// What $(LREF Terminal.open) sets up (and $(LREF Terminal.close) tears down).
struct TerminalOptions
{
    bool altScreen = true;   /// switch to the alternate screen buffer
    bool hideCursor = true;  /// hide the cursor for the session
    bool mouse = true;       /// enable SGR mouse reporting (press + drag + wheel)
}

/// A raw-mode, alt-screen terminal session. Move-only; owns the restore.
struct Terminal
{
    private
    {
        termios _orig;
        TerminalOptions _opts;
        Screen _screen;
        SmallBuffer!char _buf;
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

        SmallBuffer!char s;
        if (opts.altScreen)
            writeEscapeSeq!(CtlSeq.enterAltScreen)(s);
        if (opts.hideCursor)
            writeEscapeSeq!(CtlSeq.hideCursor)(s);
        writeEscapeSeq!(DecMode.autowrap, false)(s); // a full-width cell must not wrap/scroll
        if (opts.mouse)
            writeMouseTracking(s, true); // SGR mouse: click + drag + wheel
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

        SmallBuffer!char s;
        if (_opts.mouse)
            writeMouseTracking(s, false);
        writeEscapeSeq!(DecMode.autowrap, true)(s); // autowrap on
        if (_opts.hideCursor)
            writeEscapeSeq!(CtlSeq.showCursor)(s);
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
    void draw(in Grid grid) @trusted
    {
        _buf.clear();
        writeEscapeSeq!(CtlSeq.syncBegin)(_buf);
        _screen.render(grid, _buf);
        writeEscapeSeq!(CtlSeq.syncEnd)(_buf);
        writeAll(_outFd, _buf[]);
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
{
    static const(char)[] env(const(char)* name) @trusted nothrow @nogc
    {
        const p = getenv(name);
        return p ? p[0 .. strlen(p)] : null;
    }

    return classifyColorDepth(env("COLORTERM"), env("TERM"));
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
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.tui.cell : CellStyle;
    import std.algorithm.searching : canFind;

    Grid g;
    g.resize(4, 1);
    g.putText(0, 0, "ok", CellStyle.init);

    Screen scr;
    SmallBuffer!char buf;
    buf.put(cast(string) CtlSeq.syncBegin);
    scr.render(g, buf);
    buf.put(cast(string) CtlSeq.syncEnd);

    assert(buf[].canFind("\x1b[?2026h")); // sync begin
    assert(buf[].canFind("ok"));
    assert(buf[].canFind("\x1b[?2026l")); // sync end
}
