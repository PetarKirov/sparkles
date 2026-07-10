/++
Raw-mode keyboard input: entering/restoring cbreak terminal mode and decoding
arrow-key escape sequences into a small, closed $(LREF Key) vocabulary.

The sole consumer is $(REF select, sparkles,core_cli,prompts)'s arrow-key
navigation; this is deliberately not a general input/event framework (see
`docs/specs/core-cli/tui-components` §F) — just enough to turn a blocking
byte stream from a real terminal into up/down/enter/cancel.

POSIX and Windows share the same byte-decoding ($(LREF classifyByte),
$(LREF decodeEscapeTail)) — Windows opts into the same CSI escape bytes via
`ENABLE_VIRTUAL_TERMINAL_INPUT`; only raw-mode enter/restore and the blocking
byte-read/timeout-wait primitives are platform-specific.
+/
module sparkles.core_cli.key_input;

/// The closed set of keys `select`'s arrow-key navigation reacts to. `cancel`
/// covers Esc, Ctrl+C, Ctrl+D, and a real EOF on the input stream; `other` is
/// every unrecognized byte/sequence (ignored by the caller).
enum Key { up, down, enter, cancel, other }

/// A raw-mode key-reading session: `next` blocks for one decoded key,
/// `finish` restores the terminal's original mode and is idempotent — call it
/// from `scope (exit)` (mirrors $(REF LiveRegion, sparkles,core_cli,ui,live)'s
/// enter/use/finish lifecycle).
struct KeySession
{
    Key delegate() next;
    void delegate() finish;
}

/// Begins a raw-mode key session on stdin, or `null` when arrow-key
/// navigation isn't available (stdin/stdout aren't both real terminals).
KeySession delegate() stdioKeySession() @safe nothrow
{
    import sparkles.core_cli.term_caps : isTerminal, StdStream;

    if (!isTerminal(StdStream.stdin) || !isTerminal(StdStream.stdout))
        return null;
    return () => beginRawKeySession();
}

/// The query never throws; the returned delegate is `null` unless both
/// stdin and stdout are real terminals (never true under `dub test`'s piped
/// harness), so this only pins the "doesn't crash" contract — like
/// `isTerminal`'s own test in `term_caps.d`.
@("stdioKeySession.callable")
@safe nothrow
unittest
{
    cast(void) stdioKeySession();
}

// ---------------------------------------------------------------------------
// Shared byte decoding (platform-independent)
// ---------------------------------------------------------------------------

/// Classifies a single input byte; `readEscape` is only invoked for a lone
/// ESC (`0x1b`), and decides between a bare Esc keypress and the start of a
/// CSI/SS3 escape sequence (typically via a short read timeout).
private Key classifyByte(char b, scope Key delegate() @safe nothrow readEscape) @safe nothrow
{
    switch (b)
    {
        case 0x03, 0x04: return Key.cancel; // Ctrl+C / Ctrl+D
        case '\r', '\n': return Key.enter;
        case 0x1b:       return readEscape();
        default:         return Key.other;
    }
}

/// Maps the two bytes following ESC (introducer + final) to a key, for both
/// the CSI (`ESC [`) and SS3 (`ESC O`) forms some terminals send in
/// application-cursor-key mode. Pure and syscall-free — the escape *table* is
/// unit-tested directly here; the timeout/read plumbing that feeds it is
/// exercised only by manual/interactive testing (see the release guide).
private Key decodeEscapeTail(char introducer, char final_) @safe pure nothrow @nogc
{
    if (introducer != '[' && introducer != 'O')
        return Key.other;
    switch (final_)
    {
        case 'A': return Key.up;
        case 'B': return Key.down;
        default:  return Key.other;
    }
}

@("keyInput.classifyByte.controlAndPlainBytes")
@safe nothrow
unittest
{
    assert(classifyByte(0x03, () => Key.other) == Key.cancel);
    assert(classifyByte(0x04, () => Key.other) == Key.cancel);
    assert(classifyByte('\r', () => Key.other) == Key.enter);
    assert(classifyByte('\n', () => Key.other) == Key.enter);
    assert(classifyByte('q', () => Key.other) == Key.other);
    assert(classifyByte(0x1b, () => Key.up) == Key.up); // delegates to the escape reader
}

@("keyInput.decodeEscapeTail.arrowsAndUnknown")
@safe pure nothrow @nogc
unittest
{
    assert(decodeEscapeTail('[', 'A') == Key.up);
    assert(decodeEscapeTail('[', 'B') == Key.down);
    assert(decodeEscapeTail('O', 'A') == Key.up);    // SS3 application-cursor-key form
    assert(decodeEscapeTail('O', 'B') == Key.down);
    assert(decodeEscapeTail('[', 'C') == Key.other); // right arrow: unhandled by this picker
    assert(decodeEscapeTail('X', 'A') == Key.other); // not CSI/SS3 at all
}

// ---------------------------------------------------------------------------
// POSIX: termios raw mode + blocking read + poll-based Esc disambiguation
// ---------------------------------------------------------------------------

version (Posix)
{
    private enum escTimeoutMs = 35;

    private KeySession beginRawKeySession() @trusted nothrow
    {
        import core.sys.posix.termios : ECHO, ICANON, ISIG, tcgetattr, TCSANOW,
            TCSAFLUSH, tcsetattr, termios, VMIN, VTIME;
        import core.sys.posix.unistd : STDIN_FILENO;

        termios original;
        if (tcgetattr(STDIN_FILENO, &original) != 0)
            return KeySession(() => Key.cancel, () {});

        auto raw = original;
        raw.c_lflag &= ~(ECHO | ICANON | ISIG);
        raw.c_cc[VMIN] = 1;
        raw.c_cc[VTIME] = 0;
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw);

        auto restored = false;
        void finish()
        {
            if (restored) return;
            restored = true;
            tcsetattr(STDIN_FILENO, TCSANOW, &original);
        }
        return KeySession(() => readKeyPosix(), &finish);
    }

    /// Reads one byte, retrying on `EINTR` (a `SIGWINCH` resize — see
    /// `term_caps.d`'s handler — must not spuriously cancel the prompt).
    /// Returns `1` (byte read), `0` (real EOF), or `-1` (other error).
    private ptrdiff_t readBytePosix(ref char b) @trusted nothrow
    {
        import core.stdc.errno : EINTR, errno;
        import core.sys.posix.unistd : read, STDIN_FILENO;

        for (;;)
        {
            const n = read(STDIN_FILENO, &b, 1);
            if (n >= 0 || errno != EINTR)
                return n;
        }
    }

    private Key readKeyPosix() @trusted nothrow
    {
        char b;
        if (readBytePosix(b) != 1)
            return Key.cancel; // EOF or read error
        return classifyByte(b, () => decodeEscapePosix());
    }

    private Key decodeEscapePosix() @trusted nothrow
    {
        import core.sys.posix.poll : poll, pollfd, POLLIN;
        import core.sys.posix.unistd : STDIN_FILENO;

        pollfd pfd;
        pfd.fd = STDIN_FILENO;
        pfd.events = POLLIN;
        if (poll(&pfd, 1, escTimeoutMs) <= 0)
            return Key.cancel; // lone Esc: no follow-up bytes within the window

        char introducer;
        if (readBytePosix(introducer) != 1)
            return Key.other;
        char final_;
        if (readBytePosix(final_) != 1)
            return Key.other;
        return decodeEscapeTail(introducer, final_);
    }
}

// ---------------------------------------------------------------------------
// Windows: console mode raw input + ReadFile + WaitForSingleObject timeout
// ---------------------------------------------------------------------------

version (Windows)
{
    import core.sys.windows.windows : HANDLE;

    private enum escTimeoutMs = 35;

    private KeySession beginRawKeySession() @trusted nothrow
    {
        import core.sys.windows.windows : DWORD, ENABLE_ECHO_INPUT,
            ENABLE_LINE_INPUT, ENABLE_PROCESSED_INPUT,
            ENABLE_VIRTUAL_TERMINAL_INPUT, GetConsoleMode, GetStdHandle,
            INVALID_HANDLE_VALUE, SetConsoleMode, STD_INPUT_HANDLE;

        auto handle = GetStdHandle(STD_INPUT_HANDLE);
        DWORD original;
        if (handle is null || handle == INVALID_HANDLE_VALUE || !GetConsoleMode(handle, &original))
            return KeySession(() => Key.cancel, () {});

        // Keep the same CSI byte stream POSIX decodes, minus line editing/echo.
        const raw = (original & ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT))
            | ENABLE_VIRTUAL_TERMINAL_INPUT;
        SetConsoleMode(handle, raw);

        auto restored = false;
        void finish()
        {
            if (restored) return;
            restored = true;
            SetConsoleMode(handle, original);
        }
        return KeySession(() => readKeyWindows(handle), &finish);
    }

    /// Returns `1` (byte read), `0`/`-1` on EOF/error (mirrors `readBytePosix`).
    private ptrdiff_t readByteWindows(HANDLE handle, ref char b) @trusted nothrow
    {
        import core.sys.windows.windows : DWORD, ReadFile;

        DWORD n;
        if (!ReadFile(handle, &b, 1, &n, null))
            return -1;
        return n;
    }

    private Key readKeyWindows(HANDLE handle) @trusted nothrow
    {
        char b;
        if (readByteWindows(handle, b) != 1)
            return Key.cancel;
        return classifyByte(b, () => decodeEscapeWindows(handle));
    }

    private Key decodeEscapeWindows(HANDLE handle) @trusted nothrow
    {
        import core.sys.windows.windows : WAIT_OBJECT_0, WaitForSingleObject;

        // A console input handle is waitable: signaled once unread input is
        // available. Anything but WAIT_OBJECT_0 (timeout or failure) means no
        // follow-up bytes arrived in the window ⇒ treat as a lone Esc.
        if (WaitForSingleObject(handle, escTimeoutMs) != WAIT_OBJECT_0)
            return Key.cancel;

        char introducer;
        if (readByteWindows(handle, introducer) != 1)
            return Key.other;
        char final_;
        if (readByteWindows(handle, final_) != 1)
            return Key.other;
        return decodeEscapeTail(introducer, final_);
    }
}
