/++
End-to-end integration tests over a real pseudo-terminal.

A pty pair is allocated in-process with libc (`posix_openpt`; no `libutil`), the
terminal backend / input reader are pointed at the $(B slave) fd, and the test
drives the $(B master) — exactly what a terminal emulator sees and types. This
exercises the whole stack (raw mode, the lifecycle sequences, the cell-diff on the
wire, and input decoding) through the kernel's tty layer, not a mock.

No `fork` / no thread is used — the terminal runs in the test's own process on the
slave fd while the test reads/writes the master — so it is safe under the parallel
test runner. Whole-module `version (unittest)`, so it adds nothing to the library.
+/
module sparkles.tui.integration;

version (unittest):
version (Posix):

import core.stdc.errno : errno;
import core.sys.posix.fcntl : open, O_NOCTTY, O_RDWR;
import core.sys.posix.poll : poll, pollfd, POLLIN;
import core.sys.posix.stdlib : grantpt, posix_openpt, ptsname, unlockpt;
import core.sys.posix.unistd : closeFd = close, read, write;

import expected : Expected, ok, err;

import sparkles.base.text.errors : NoGcHook;
import sparkles.tui.cell : Cell, CellStyle, Color, Grid;
import sparkles.tui.input : charEvent, Event, FocusEvent, Key, keyEvent, Mods, NoEvent, Point,
    PointerAction, PointerButton, PointerEvent, PosixEvents;
import sparkles.tui.terminal : Terminal, TerminalOptions;

/// Which libc step failed while opening a pty.
enum IoErrorCode : ubyte { openpt, grantpt, unlockpt, ptsname, openSlave }

/// A minimal, allocation-free IO error: the failing step + the captured `errno`.
/// Test-local; mirrors `apps/terminal`'s `ProcessError` (the same shape a future
/// `sparkles.core_cli` IO error would take).
struct IoError
{
    IoErrorCode code;
    int errnoValue;
}

/// Subsystem alias + `ok`/`err` helpers (the `procOk`/`procErr` idiom).
alias IoExpected(T) = Expected!(T, IoError, NoGcHook);
IoExpected!T ioOk(T)(T value) => ok!(IoError, NoGcHook)(value);
/// ditto
IoExpected!T ioErr(T)(IoErrorCode code, int errnoValue)
    => err!(T, NoGcHook)(IoError(code, errnoValue));

/// The raw fds of a freshly-opened pty — the `Expected` payload from $(LREF openPty).
/// (`Pty` below is the move-only RAII owner built from these; `expected` 0.4.1 can't
/// hold a move-only value, so the fd pair is what the `Expected` carries.)
struct PtyFds { int master; int slave; }

/// Open a pty with pure libc (no libutil openpty/forkpty) — the fallible step,
/// reporting the failing syscall (with `errno`) via `Expected` rather than a
/// sentinel. On success only a valid fd pair is produced, so the RAII `Pty` built
/// from it is always in the valid state (the type-state — no `ok()` to check).
IoExpected!PtyFds openPty() @trusted
{
    const m = posix_openpt(O_RDWR | O_NOCTTY);
    if (m < 0)
        return ioErr!PtyFds(IoErrorCode.openpt, errno);
    if (grantpt(m) != 0)
        return ioErr!PtyFds(IoErrorCode.grantpt, errno);
    if (unlockpt(m) != 0)
        return ioErr!PtyFds(IoErrorCode.unlockpt, errno);
    auto name = ptsname(m);
    if (name is null)
        return ioErr!PtyFds(IoErrorCode.ptsname, errno);
    const s = open(name, O_RDWR | O_NOCTTY);
    if (s < 0)
    {
        closeFd(m);
        return ioErr!PtyFds(IoErrorCode.openSlave, errno);
    }
    return ioOk(PtyFds(m, s));
}

/// A master/slave pseudo-terminal pair. RAII: the sole owner closes both fds on
/// destruction; move-only, so they are never double-closed. Built from a
/// successfully-opened $(LREF PtyFds).
private struct Pty
{
    int master = -1;
    int slave = -1;

    /// Adopt an opened fd pair.
    this(PtyFds fds) @safe pure nothrow @nogc
    {
        master = fds.master;
        slave = fds.slave;
    }

    @disable this(this);

    ~this() @trusted nothrow
    {
        close();
    }

    /// Close both fds now (idempotent); also runs from the destructor. Kept so a
    /// test can release the pty before the end of its scope.
    void close() @trusted nothrow
    {
        if (slave >= 0)
            closeFd(slave);
        if (master >= 0)
            closeFd(master);
        slave = master = -1;
    }
}

// Read whatever the terminal wrote to the master, until `idleMs` of silence.
private const(char)[] drain(int fd, ref char[] buf, int idleMs = 120) @trusted
{
    size_t total;
    for (;;)
    {
        pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLIN;
        if (poll(&pfd, 1, idleMs) <= 0)
            break;
        if (buf.length < total + 4096)
            buf.length = total + 4096;
        const n = read(fd, buf.ptr + total, 4096);
        if (n <= 0)
            break;
        total += cast(size_t) n;
    }
    return buf[0 .. total];
}

private void feed(int fd, string s) @trusted
{
    cast(void) write(fd, s.ptr, s.length);
}

@("integration.pty.lifecycleAndCellDiff")
@system
unittest
{
    import std.algorithm.searching : canFind;
    import sparkles.test_runner.skip : skipTest;

    auto r = openPty();
    if (r.hasError)
        skipTest("no pty available");
    auto pty = Pty(r.value); // RAII owner; its dtor closes the fds at scope exit
    char[] rb;

    auto term = Terminal.open(TerminalOptions(), pty.slave, pty.slave);
    assert(term.active, "raw mode on the pty slave");

    // The setup sequences reached the master.
    const setup = drain(pty.master, rb);
    assert(setup.canFind("\x1b[?1049h"), setup);         // alt-screen
    assert(setup.canFind("\x1b[?1000;1002;1006h"), setup); // SGR mouse
    assert(setup.canFind("\x1b[?7l"), setup);            // autowrap off
    assert(setup.canFind("\x1b[>13u"), setup);           // Kitty flags 1|4|8


    // First frame: a full paint, sync-framed, with the content.
    const st = CellStyle(fg: Color.fromRgb(200, 200, 200));
    Grid g;
    g.resize(6, 2);
    g.putText(0, 0, "hello", st);
    term.draw(g);
    const full = drain(pty.master, rb);
    assert(full.canFind("\x1b[?2026h") && full.canFind("\x1b[?2026l"), full); // sync frame
    assert(full.canFind("hello"), full);

    // Change ONE cell. The diff must be smaller than a full repaint, position the
    // cursor at the changed cell, emit it, and NOT re-send the unchanged tail.
    g[0, 0].setCodepoint('J', 1, st);
    term.draw(g);
    const diff = drain(pty.master, rb);
    assert(diff.canFind("J"), diff);
    assert(diff.canFind("\x1b[1;1H"), diff);   // CUP to the changed (row 1, col 1)
    assert(!diff.canFind("ello"), diff);       // the unchanged tail is NOT re-emitted
    assert(diff.length < full.length, "a one-cell diff must be smaller than a full paint");

    // Teardown restores the terminal in reverse.
    term.close();
    const teardown = drain(pty.master, rb);
    assert(teardown.canFind("\x1b[?1000;1002;1006l"), teardown); // mouse off
    assert(teardown.canFind("\x1b[?25h"), teardown);             // cursor shown
    assert(teardown.canFind("\x1b[<u"), teardown);               // pop keyboard mode
    assert(teardown.canFind("\x1b[?1049l"), teardown);           // alt-screen exit
}

@("integration.pty.inputRoundTrip")
@system
unittest
{
    import sparkles.test_runner.skip : skipTest;

    auto r = openPty();
    if (r.hasError)
        skipTest("no pty available");
    auto pty = Pty(r.value); // RAII owner; its dtor closes the fds at scope exit

    // A Terminal puts the slave in raw mode so reads return bytes immediately
    // (a fresh pty slave is canonical + echoing). No alt-screen / mouse chrome.
    auto term = Terminal.open(TerminalOptions(altScreen: false, hideCursor: false, mouse: false),
        pty.slave, pty.slave);
    assert(term.active);
    scope (exit) term.close();
    char[] rb;
    drain(pty.master, rb); // discard the autowrap-off setup byte

    auto events = PosixEvents.start(pty.slave);

    // An arrow key typed at the master decodes on the slave. Events are Regular
    // values, so the assertions are whole-event equality — no field poking.
    feed(pty.master, "\x1b[A");
    assert(events.next() == keyEvent(Key.up), "up arrow");

    // A Ctrl-modified nav key.
    feed(pty.master, "\x1b[6;5~");
    assert(events.next() == keyEvent(Key.pageDown, Mods(ctrl: true)), "Ctrl+PageDown");

    // An SGR mouse press: wire 1-based (5,3) decodes to toolkit 0-based (4,2).
    feed(pty.master, "\x1b[<0;5;3M");
    assert(events.next() == Event(PointerEvent(action: PointerAction.press,
        button: PointerButton.left, pos: Point(4, 2))), "left press @ 5,3");

    // A printable key.
    feed(pty.master, "q");
    assert(events.next() == charEvent('q'), "q");
}

@("integration.pty.probeAnswersAndKeepsTypedKeys")
@system
unittest
{
    import std.algorithm.searching : canFind;
    import sparkles.base.term_caps : ImageProtocol;
    import sparkles.test_runner.skip : skipTest;
    import sparkles.base.term_replies : ModeReply, queryBattery, TcapReply;

    auto r = openPty();
    if (r.hasError)
        skipTest("no pty available");
    auto pty = Pty(r.value);
    auto term = Terminal.open(TerminalOptions(altScreen: false, hideCursor: false, mouse: false),
        pty.slave, pty.slave);
    assert(term.active);
    scope (exit) term.close();
    char[] rb;
    drain(pty.master, rb);

    // The scripted peer: a key typed early, then Ghostty's measured replies
    // — the graphics query answered, then the DA1 fence.
    feed(pty.master, "j\x1b_Gi=31;OK\x1b\\\x1b[?0u\x1b[?2026;2$y\x1b[?2027;1$y"
        ~ "\x1bP1+r5463\x1b\\\x1b[?62;22;52c");
    const replies = term.probe(1000, false);
    assert(term.imageProtocol == ImageProtocol.kitty);
    // Every row of the battery comes back, not just images.
    assert(replies.fenced && replies.kittyKeyboard && replies.kittyGraphics);
    assert(replies.sync == ModeReply.reset && replies.graphemes == ModeReply.set);
    assert(replies.tc == TcapReply.valid && replies.da1 == "62;22;52");
    assert(drain(pty.master, rb).canFind(queryBattery), "the battery went out");

    // The key typed during the probe is not lost: it is the first event.
    auto events = PosixEvents.start(pty.slave);
    events.unread(term.takeTypedAhead());
    assert(events.next() == charEvent('j'));
}

@("integration.pty.probeSilentTerminalCostsTheTimeout")
@system
unittest
{
    import core.time : MonoTime;
    import sparkles.base.term_caps : ImageProtocol;
    import sparkles.test_runner.skip : skipTest;

    auto r = openPty();
    if (r.hasError)
        skipTest("no pty available");
    auto pty = Pty(r.value);
    auto term = Terminal.open(TerminalOptions(altScreen: false, hideCursor: false, mouse: false),
        pty.slave, pty.slave);
    scope (exit) term.close();

    // Nothing answers (a bare pty): `none`, after the timeout and not forever.
    const t0 = MonoTime.currTime;
    cast(void) term.probe(60);
    assert(term.imageProtocol == ImageProtocol.none);
    assert((MonoTime.currTime - t0).total!"msecs" < 1000);
}

@("integration.pty.imagesGoOutInsideTheFrame")
@system
unittest
{
    import std.algorithm.searching : canFind, countUntil;
    import sparkles.test_runner.skip : skipTest;
    import sparkles.tui.images : ImagePlacement;

    auto r = openPty();
    if (r.hasError)
        skipTest("no pty available");
    auto pty = Pty(r.value);
    auto term = Terminal.open(TerminalOptions(altScreen: false, hideCursor: false, mouse: false),
        pty.slave, pty.slave);
    char[] rb;
    drain(pty.master, rb);
    // The terminal answered for kitty — draw speaks what the probe found.
    feed(pty.master, "\x1b_Gi=31;OK\x1b\\\x1b[?62;52c");
    cast(void) term.probe(1000, false);
    drain(pty.master, rb);

    static immutable ubyte[4] px = [1, 2, 3, 255];
    const place = [ImagePlacement(image: 3, rgba: px[], width: 1, height: 1,
        x: 1, y: 0, cols: 2, rows: 1)];
    Grid g;
    g.resize(4, 1);
    term.draw(g, null, place);
    const first = drain(pty.master, rb).idup;
    // Transmitted and placed inside the synchronized frame.
    const begin = first.countUntil("\x1b[?2026h"), end = first.countUntil("\x1b[?2026l");
    const t = first.countUntil("\x1b_Ga=t"), p = first.countUntil("\x1b_Ga=p");
    assert(begin >= 0 && t > begin && p > t && end > p, first);

    // A steady frame: no graphics at all.
    term.draw(g, null, place);
    assert(!drain(pty.master, rb).canFind("\x1b_G"));

    // Teardown frees the pixels.
    term.close();
    assert(drain(pty.master, rb).canFind("\x1b_Ga=d,d=I,i=3,q=2\x1b\\"));
}

@("integration.pty.sixelNeedsPixelsAndRedrawsWhatItLeft")
@system
unittest
{
    import core.sys.posix.sys.ioctl : ioctl, TIOCSWINSZ, winsize;
    import std.algorithm.searching : canFind;
    import sparkles.base.term_caps : ImageProtocol;
    import sparkles.test_runner.skip : skipTest;
    import sparkles.tui.images : ImagePlacement;
    import sparkles.tui.sixel : CellPixels;

    auto r = openPty();
    if (r.hasError)
        skipTest("no pty available");
    auto pty = Pty(r.value);
    auto term = Terminal.open(TerminalOptions(altScreen: false, hideCursor: false, mouse: false),
        pty.slave, pty.slave);
    scope (exit) term.close();
    char[] rb;
    drain(pty.master, rb);

    // foot's measured reply: sixel in DA1, no kitty. A pty reports no pixel
    // size and nothing answered `CSI 16 t`, so sixel cannot be sized, and is
    // not claimed.
    feed(pty.master, "\x1b[?62;4;22;28;52c");
    cast(void) term.probe(1000, false);
    assert(term.imageProtocol == ImageProtocol.none);
    drain(pty.master, rb);

    // The terminal's own answer to `CSI 16 t` is enough, before the window
    // has a size (foot, freshly started under a compositor).
    feed(pty.master, "\x1b[6;13;6t\x1b[?62;4;22;28;52c");
    cast(void) term.probe(1000, false);
    assert(term.imageProtocol == ImageProtocol.sixel);
    assert(term.cellPixels() == CellPixels(6, 13));
    drain(pty.master, rb);

    // With the window's pixels known (8×16 cells), it is.
    winsize ws;
    ws.ws_col = 10;
    ws.ws_row = 4;
    ws.ws_xpixel = 80;
    ws.ws_ypixel = 64;
    ioctl(pty.master, TIOCSWINSZ, &ws);
    feed(pty.master, "\x1b[?62;4;22;28;52c");
    cast(void) term.probe(1000, false);
    assert(term.imageProtocol == ImageProtocol.sixel);
    drain(pty.master, rb);

    static immutable ubyte[4] px = [200, 0, 0, 255];
    auto at = ImagePlacement(image: 5, rgba: px[], width: 1, height: 1,
        x: 2, y: 0, cols: 2, rows: 1);
    Grid g;
    g.resize(10, 4);
    term.draw(g, null, [at]);
    const first = drain(pty.master, rb).idup;
    assert(first.canFind("\x1b[1;3H\x1bP0;1;0q\"1;1;16;16"), first);

    // Steady: no sixel. Gone: no sixel, and the cells it covered are
    // repainted — the diff rewrites row 1 from column 3.
    term.draw(g, null, [at]);
    assert(!drain(pty.master, rb).canFind("\x1bP"));
    term.draw(g, null, null);
    const gone = drain(pty.master, rb).idup;
    assert(!gone.canFind("\x1bP") && gone.canFind("\x1b[1;3H"), gone);
}

@("integration.pty.lateRepliesAreNotKeys")
@system
unittest
{
    import sparkles.test_runner.skip : skipTest;

    auto r = openPty();
    if (r.hasError)
        skipTest("no pty available");
    auto pty = Pty(r.value);
    auto term = Terminal.open(TerminalOptions(altScreen: false, hideCursor: false, mouse: false),
        pty.slave, pty.slave);
    assert(term.active);
    scope (exit) term.close();
    char[] rb;
    drain(pty.master, rb);

    // foot, freshly started, answered after the probe had given up: its
    // `XTGETTCAP` replies reached the input stream, and were decoded as
    // Alt+P, `1`, `+`, `r`… Measured. They are a terminal's, and dropped.
    auto events = PosixEvents.start(pty.slave);
    feed(pty.master, "\x1bP1+r524742=38\x1b\\\x1b]11;rgb:0/0/0\x07q");
    Event e;
    do
        e = events.next();
    while (e == Event(NoEvent()));
    assert(e == charEvent('q'), "the key after the replies, and nothing before it");
}

@("integration.pty.focusReportsAreNegotiatedAndDecoded")
@system
unittest
{
    import std.algorithm.searching : canFind;
    import sparkles.test_runner.skip : skipTest;

    auto r = openPty();
    if (r.hasError)
        skipTest("no pty available");
    auto pty = Pty(r.value);
    auto term = Terminal.open(TerminalOptions(altScreen: false, hideCursor: false, mouse: false),
        pty.slave, pty.slave);
    assert(term.active);
    char[] rb;
    drain(pty.master, rb);

    // Not asked for, not on: nothing is written until the session negotiates.
    assert(!term.focusReporting);
    term.enableFocusReporting();
    assert(term.focusReporting);
    assert(drain(pty.master, rb).canFind("\x1b[?1004h"));

    // The terminal's reports decode as focus changes.
    auto events = PosixEvents.start(pty.slave);
    feed(pty.master, "\x1b[O\x1b[I");
    assert(events.next() == Event(FocusEvent(false)));
    assert(events.next() == Event(FocusEvent(true)));

    // And closing turns them off again.
    term.close();
    assert(drain(pty.master, rb).canFind("\x1b[?1004l"));
}

@("integration.pty.bracketedPasteIsOnePaste")
@system
unittest
{
    import std.algorithm.searching : canFind;
    import sparkles.input : match, PasteEvent;
    import sparkles.test_runner.skip : skipTest;

    auto r = openPty();
    if (r.hasError)
        skipTest("no pty available");
    auto pty = Pty(r.value);
    auto term = Terminal.open(TerminalOptions(altScreen: false, hideCursor: false, mouse: false),
        pty.slave, pty.slave);
    assert(term.active);
    scope (exit) term.close();
    char[] rb;
    drain(pty.master, rb);

    // A paste longer than a chunk, with a newline: chunks in order, the
    // text verbatim, then the key typed after it.
    // Negotiated: `CSI ?2004h`, and reset on close.
    assert(!term.bracketedPaste);
    term.enableBracketedPaste();
    assert(term.bracketedPaste);
    assert(drain(pty.master, rb).canFind("\x1b[?2004h"));

    auto events = PosixEvents.start(pty.slave);
    enum text = "first line of a longer paste\nsecond line, which overflows a chunk";
    feed(pty.master, "\x1b[200~" ~ text ~ "\x1b[201~q");
    string got;
    bool last;
    while (!last)
    {
        const e = events.next();
        const p = e.match!((in PasteEvent p) => p, _ => PasteEvent.init);
        got ~= p.text[];
        last = p.last;
    }
    assert(got == text);
    assert(events.next() == charEvent('q'));

    term.close();
    assert(drain(pty.master, rb).canFind("\x1b[?2004l"));
}

@("integration.pty.probeRecordedTerminals")
@system
unittest
{
    import std.array : replace;
    import std.file : dirEntries, readText, SpanMode;
    import std.path : baseName, buildNormalizedPath, dirName;
    import std.string : lineSplitter, startsWith;
    import sparkles.base.term_replies : parseReplies, TerminalReplies;
    import sparkles.test_runner.skip : skipTest;

    // `O5`: a scripted pty peer answers the probe with real terminals'
    // recorded replies (`sparkles:base`'s capture corpus), and the probe —
    // the whole of it: the write, the poll loop, the parse — must come back
    // with what those bytes say.
    const corpus = __FILE_FULL_PATH__.dirName
        .buildNormalizedPath("../../../../base/test/data/term_replies");
    size_t terminals;
    foreach (entry; dirEntries(corpus, "*.txt", SpanMode.shallow))
    {
        string bytes;
        bool multiplexer;
        foreach (line; readText(entry.name).lineSplitter)
        {
            if (line.startsWith("replies: "))
                bytes = line["replies: ".length .. $].replace("ESC", "\x1b").replace("BEL", "\x07");
            if (line.startsWith("TMUX: set") || line.startsWith("ZELLIJ: set"))
                multiplexer = true;
        }
        TerminalReplies want;
        ubyte[] rest;
        parseReplies(cast(const(ubyte)[]) bytes, want, rest);

        auto r = openPty();
        if (r.hasError)
            skipTest("no pty available");
        auto pty = Pty(r.value);
        auto term = Terminal.open(TerminalOptions(altScreen: false, hideCursor: false,
            mouse: false), pty.slave, pty.slave);
        assert(term.active);
        char[] rb;
        drain(pty.master, rb);
        feed(pty.master, bytes);
        auto got = term.probe(2000, multiplexer);
        term.close();

        // The environment fields are this process's, not the recording's.
        got.term = want.term;
        got.colorterm = want.colorterm;
        got.multiplexer = want.multiplexer;
        assert(got == want, entry.name.baseName);
        assert(got.fenced && term.takeTypedAhead().length == 0, entry.name.baseName);
        ++terminals;
    }
    assert(terminals == 11, "the whole corpus");
}
