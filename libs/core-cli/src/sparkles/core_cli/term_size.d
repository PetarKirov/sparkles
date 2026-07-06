module sparkles.core_cli.term_size;

// The SIGWINCH resize-notification machinery is POSIX-only; `terminalWidth`
// below is cross-platform. Guarding the POSIX import keeps the module
// compilable on Windows (where the runner's width query still works).
version (Posix)
{
    // TODO: upstream
    version (linux)  enum SIGWINCH = 28;
    version (OSX)    enum SIGWINCH = 28;

    import core.sys.posix.signal : signal;

    alias Handler = void delegate(ushort width, ushort height) nothrow @nogc;

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
        _handler(s.ws_col, s.ws_row);
    }
}

/// Current terminal width in columns (cells), or `0` when it can't be
/// determined — output not a tty, redirected to a pipe/file, or the OS query
/// failed. A synchronous one-shot query, distinct from the async
/// `setTermWindowSizeHandler` above. Callers use `0` to mean "unknown, don't
/// wrap/truncate".
ushort terminalWidth() @safe nothrow @nogc
{
    version (Posix)
    {
        import core.sys.posix.sys.ioctl : ioctl, winsize, TIOCGWINSZ;
        import core.sys.posix.unistd : STDOUT_FILENO;

        // The ioctl and its out-parameter are one unsafe unit; scope trust to
        // it (capturing nothing, so no `@nogc` closure) and hand back a plain
        // `ushort`.
        return () @trusted {
            winsize s;
            if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &s) != 0)
                return ushort(0);
            return s.ws_col;
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
                return ushort(0);
            CONSOLE_SCREEN_BUFFER_INFO info;
            if (!GetConsoleScreenBufferInfo(handle, &info))
                return ushort(0);
            const width = info.srWindow.Right - info.srWindow.Left + 1;
            return width > 0 ? cast(ushort) width : ushort(0);
        }();
    }
    else
        return 0;
}

/// The query is `@safe nothrow @nogc` and never throws; the value itself is
/// environment-dependent (`0` under a piped `dub test`, the column count on a
/// real terminal), so this only pins the contract.
@("terminalWidth.callable")
@safe nothrow @nogc
unittest
{
    const width = terminalWidth();
    assert(width == 0 || width >= 1);
}
