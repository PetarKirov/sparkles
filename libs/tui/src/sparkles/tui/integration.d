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
import sparkles.tui.input : EventKind, Key, MouseAction, MouseButton, PosixEvents;
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

    // An arrow key typed at the master decodes on the slave.
    feed(pty.master, "\x1b[A");
    const up = events.next();
    assert(up.kind == EventKind.key && up.key == Key.up, "up arrow");

    // A Ctrl-modified nav key.
    feed(pty.master, "\x1b[6;5~");
    const cpgdn = events.next();
    assert(cpgdn.key == Key.pageDown && cpgdn.mods.ctrl, "Ctrl+PageDown");

    // An SGR mouse press.
    feed(pty.master, "\x1b[<0;5;3M");
    const m = events.next();
    assert(m.kind == EventKind.mouse && m.button == MouseButton.left
        && m.action == MouseAction.press && m.mouse.col == 5 && m.mouse.row == 3, "left press @ 5,3");

    // A printable key.
    feed(pty.master, "q");
    const q = events.next();
    assert(q.kind == EventKind.key && q.key == Key.char_ && q.ch == 'q', "q");
}
