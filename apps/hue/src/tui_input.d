// Raw-terminal input for hue's full-screen TUI viewer (tui.d) — a hue-local
// input layer richer than the shared `sparkles.core_cli.key_input` (which is
// deliberately a closed up/down/enter/cancel vocabulary for `select`). It decodes
// the keys a document viewer needs — arrows, PageUp/Down, Home/End, Tab, printable
// characters — plus a SIGWINCH-driven resize event, so the viewer reflows on a
// terminal resize (tui.md `TIN1`/`TSF2`). Posix-only; the caller degrades to the
// non-interactive preview emit elsewhere.
module tui_input;

version (Posix):

import core.sys.posix.termios : ECHO, ICANON, ISIG, tcgetattr, TCSAFLUSH,
    TCSANOW, tcsetattr, termios, VMIN, VTIME;
import core.sys.posix.unistd : read, STDIN_FILENO;
import core.sys.posix.signal : sigaction, sigaction_t;
import core.stdc.errno : EINTR, errno;

version (linux) private enum SIGWINCH = 28;
version (OSX)   private enum SIGWINCH = 28;

// A no-op SIGWINCH handler installed *without* SA_RESTART, so a terminal resize
// interrupts a blocking read() with EINTR (which `next` surfaces as a resize
// event) instead of being silently restarted. glibc's `signal()` sets
// SA_RESTART; `sigaction` with sa_flags == 0 does not.
private extern (C) void hueWinchNoop(int) nothrow @nogc @system {}

/// The decoded key kinds the viewer reacts to. `resize` is a SIGWINCH interrupt;
/// `eof` is Ctrl-C / Ctrl-D / a read error; `character` carries a printable byte
/// in `TuiKey.ch`.
enum TuiKind : ubyte
{
    character,
    up, down, left, right,
    pageUp, pageDown, home, end,
    enter, tab, escape, resize, eof,
}

/// One decoded key. `ch` is meaningful only when `kind == character`.
struct TuiKey
{
    TuiKind kind;
    char ch = 0;
}

/// A raw-mode reading session over stdin: `next` blocks for one decoded key,
/// `finish` restores the original terminal mode (idempotent — call from
/// `scope (exit)`). Construct with $(LREF beginTuiInput).
struct TuiInput
{
    private termios original;
    bool active;            /// whether raw mode was entered (false ⇒ not a tty)
    private bool restored;
    private sigaction_t oldWinch;
    private bool winchInstalled;

    /// Blocks for the next key. Returns `TuiKind.resize` when a signal (SIGWINCH)
    /// interrupts the read, so the caller can re-measure and reflow.
    TuiKey next() @trusted @nogc nothrow
    {
        char b;
        const n = read(STDIN_FILENO, &b, 1);
        if (n < 0)
            return errno == EINTR ? TuiKey(TuiKind.resize) : TuiKey(TuiKind.eof);
        if (n == 0)
            return TuiKey(TuiKind.eof);
        return classify(b);
    }

    /// Restores the terminal's original mode and SIGWINCH disposition.
    void finish() @trusted @nogc nothrow
    {
        if (restored || !active)
            return;
        restored = true;
        tcsetattr(STDIN_FILENO, TCSANOW, &original);
        if (winchInstalled)
            sigaction(SIGWINCH, &oldWinch, null);
    }

    private TuiKey classify(char b) @trusted @nogc nothrow
    {
        switch (b)
        {
            case 0x03, 0x04: return TuiKey(TuiKind.eof);      // Ctrl-C / Ctrl-D
            case '\r', '\n': return TuiKey(TuiKind.enter);
            case '\t':       return TuiKey(TuiKind.tab);
            case 0x1b:       return readEscape();
            default:         return TuiKey(TuiKind.character, b);
        }
    }

    // Decode ESC-introduced sequences: CSI (`ESC [`) / SS3 (`ESC O`) cursor and
    // navigation keys, including the `ESC [ n ~` numeric forms. A lone ESC (no
    // follow-up within the poll window) reads as `escape` (quit).
    private TuiKey readEscape() @trusted @nogc nothrow
    {
        char intro;
        if (!readTimed(intro))
            return TuiKey(TuiKind.escape);
        if (intro != '[' && intro != 'O')
            return TuiKey(TuiKind.escape);

        char c;
        if (!readRaw(c))
            return TuiKey(TuiKind.escape);

        switch (c)
        {
            case 'A': return TuiKey(TuiKind.up);
            case 'B': return TuiKey(TuiKind.down);
            case 'C': return TuiKey(TuiKind.right);
            case 'D': return TuiKey(TuiKind.left);
            case 'H': return TuiKey(TuiKind.home);
            case 'F': return TuiKey(TuiKind.end);
            default: break;
        }
        if (c < '1' || c > '9')
            return TuiKey(TuiKind.escape);

        // `ESC [ n ~` — read the digit(s) up to the trailing `~`.
        const first = c;
        char t;
        if (!readRaw(t))
            return TuiKey(TuiKind.escape);
        // (single-digit codes cover the keys we use; skip any extra digits)
        while (t >= '0' && t <= '9')
            if (!readRaw(t))
                return TuiKey(TuiKind.escape);
        if (t != '~')
            return TuiKey(TuiKind.escape);
        switch (first)
        {
            case '1', '7': return TuiKey(TuiKind.home);
            case '4', '8': return TuiKey(TuiKind.end);
            case '5':      return TuiKey(TuiKind.pageUp);
            case '6':      return TuiKey(TuiKind.pageDown);
            default:       return TuiKey(TuiKind.escape);
        }
    }

    // Read one byte, blocking (retrying EINTR here would swallow a resize mid
    // escape; an interrupted escape just aborts to `escape`, which the caller
    // ignores harmlessly).
    private bool readRaw(ref char b) @trusted @nogc nothrow
    {
        return read(STDIN_FILENO, &b, 1) == 1;
    }

    // Read one byte only if it arrives within a short window — distinguishes a
    // lone ESC keypress from the start of an escape sequence.
    private bool readTimed(ref char b) @trusted @nogc nothrow
    {
        import core.sys.posix.poll : poll, pollfd, POLLIN;

        pollfd pfd;
        pfd.fd = STDIN_FILENO;
        pfd.events = POLLIN;
        if (poll(&pfd, 1, 40) <= 0)
            return false;
        return read(STDIN_FILENO, &b, 1) == 1;
    }
}

/// Enter cbreak raw mode on stdin (no echo, no line buffering, signals off) and
/// return the session. `active` is false when the mode couldn't be set (not a
/// tty); the caller should check before using it.
TuiInput beginTuiInput() @trusted @nogc nothrow
{
    TuiInput s;
    if (tcgetattr(STDIN_FILENO, &s.original) != 0)
        return s;
    auto raw = s.original;
    raw.c_lflag &= ~(ECHO | ICANON | ISIG);
    raw.c_cc[VMIN] = 1;
    raw.c_cc[VTIME] = 0;
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw);
    s.active = true;

    // Install a no-op SIGWINCH handler (sa_flags == 0 ⇒ no SA_RESTART) so a
    // resize interrupts the blocking read() and the viewer reflows.
    sigaction_t sa;
    sa.sa_handler = &hueWinchNoop;
    if (sigaction(SIGWINCH, &sa, &s.oldWinch) == 0)
        s.winchInstalled = true;

    return s;
}
