/++
Terminal capability probing: the synchronous size query ($(LREF terminalSize))
and resize notifications ($(LREF setTermWindowSizeHandler)).

Per the `docs/specs/core-cli/tui-components` decision ledger this module is the
single place the "what can this terminal do" *decision* is made; UI components
stay pure producers that take explicit widths/flags.
+/
module sparkles.core_cli.term_caps;

import sparkles.math : ScreenSize;

// The SIGWINCH resize-notification machinery is POSIX-only; `terminalSize`
// below is cross-platform. Guarding the POSIX import keeps the module
// compilable on Windows (where the runner's size query still works).
version (Posix)
{
    // TODO: upstream
    version (linux)  enum SIGWINCH = 28;
    version (OSX)    enum SIGWINCH = 28;

    import core.sys.posix.signal : signal;

    /// Resize callback: receives the new size on every SIGWINCH. Runs in signal
    /// context, hence the `nothrow @nogc` requirement — keep handlers to
    /// async-signal-safe work (storing the size, setting a flag).
    alias Handler = void delegate(ScreenSize!ushort size) nothrow @nogc;

    @nogc nothrow
    void setTermWindowSizeHandler(Handler handler)
    in (handler)
    {
        if (_handler)
            _handler = handler;
        else
        {
            _handler = handler;
            signal(SIGWINCH, &onTerminalWindowChange);
        }
    }

    private Handler _handler;

    // Handler for SIGWINCH
    private extern (C) nothrow @nogc
    void onTerminalWindowChange(int sig)
    {
        import core.sys.posix.sys.ioctl : ioctl, winsize, TIOCGWINSZ;
        import core.sys.posix.unistd : STDIN_FILENO;

        if (sig != SIGWINCH) return;

        winsize s;
        ioctl(STDIN_FILENO, TIOCGWINSZ, &s);

        assert (_handler, "No user-defined handler for SIGWINCH set");
        _handler(ScreenSize!ushort(s.ws_col, s.ws_row));
    }
}

/// Current terminal size in cells (columns × rows). A `0` component means that
/// axis can't be determined — output not a tty, redirected to a pipe/file, or
/// the OS query failed; `ScreenSize!ushort.init` (0×0) is the fully-unknown
/// value. A synchronous one-shot query, distinct from the async
/// `setTermWindowSizeHandler` above. Callers use `0` to mean "unknown, don't
/// wrap/truncate/clamp".
ScreenSize!ushort terminalSize() @safe nothrow @nogc
{
    version (Posix)
    {
        import core.sys.posix.sys.ioctl : ioctl, winsize, TIOCGWINSZ;
        import core.sys.posix.unistd : STDOUT_FILENO;

        // The ioctl and its out-parameter are one unsafe unit; scope trust to
        // it (capturing nothing, so no `@nogc` closure) and hand back a plain
        // value.
        return () @trusted {
            winsize s;
            if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &s) != 0)
                return ScreenSize!ushort.init;
            return ScreenSize!ushort(s.ws_col, s.ws_row);
        }();
    }
    else version (Windows)
    {
        import core.sys.windows.windows : CONSOLE_SCREEN_BUFFER_INFO,
            GetConsoleScreenBufferInfo, GetStdHandle, INVALID_HANDLE_VALUE,
            STD_OUTPUT_HANDLE;

        // Same: the handle lookup and console query are the unsafe unit.
        return () @trusted {
            auto handle = GetStdHandle(STD_OUTPUT_HANDLE);
            if (handle is null || handle == INVALID_HANDLE_VALUE)
                return ScreenSize!ushort.init;
            CONSOLE_SCREEN_BUFFER_INFO info;
            if (!GetConsoleScreenBufferInfo(handle, &info))
                return ScreenSize!ushort.init;
            const width = info.srWindow.Right - info.srWindow.Left + 1;
            const height = info.srWindow.Bottom - info.srWindow.Top + 1;
            if (width <= 0 || height <= 0)
                return ScreenSize!ushort.init;
            return ScreenSize!ushort(cast(ushort) width, cast(ushort) height);
        }();
    }
    else
        return ScreenSize!ushort.init;
}

/// The query is `@safe nothrow @nogc` and never throws; the value itself is
/// environment-dependent (0×0 under a piped `dub test`, the cell counts on a
/// real terminal), so this only pins the contract.
@("terminalSize.callable")
@safe nothrow @nogc
unittest
{
    const size = terminalSize();
    assert(size.width == 0 || size.width >= 1);
    assert(size.height == 0 || size.height >= 1);
}
