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

/// A standard stream, for tty queries.
enum StdStream { stdin, stdout, stderr }

/// Is `stream` attached to a terminal? POSIX: `isatty`; Windows: `GetConsoleMode`
/// succeeds (it fails when the handle is redirected — the non-tty check).
bool isTerminal(StdStream stream = StdStream.stdout) @trusted nothrow @nogc
{
    version (Posix)
    {
        import core.sys.posix.unistd : isatty, STDERR_FILENO, STDIN_FILENO, STDOUT_FILENO;

        final switch (stream)
        {
            case StdStream.stdin:  return isatty(STDIN_FILENO) != 0;
            case StdStream.stdout: return isatty(STDOUT_FILENO) != 0;
            case StdStream.stderr: return isatty(STDERR_FILENO) != 0;
        }
    }
    else version (Windows)
    {
        import core.sys.windows.windows : DWORD, GetConsoleMode, GetStdHandle,
            INVALID_HANDLE_VALUE, STD_ERROR_HANDLE, STD_INPUT_HANDLE, STD_OUTPUT_HANDLE;

        DWORD id;
        final switch (stream)
        {
            case StdStream.stdin:  id = STD_INPUT_HANDLE;  break;
            case StdStream.stdout: id = STD_OUTPUT_HANDLE; break;
            case StdStream.stderr: id = STD_ERROR_HANDLE;  break;
        }
        auto handle = GetStdHandle(id);
        if (handle is null || handle == INVALID_HANDLE_VALUE)
            return false;
        DWORD mode;
        return GetConsoleMode(handle, &mode) != 0;
    }
    else
        return false;
}

/// The query never throws and is `@nogc`; the value is environment-dependent.
@("isTerminal.callable")
@safe nothrow @nogc
unittest
{
    cast(void) isTerminal();
    cast(void) isTerminal(StdStream.stderr);
}

/// One-shot capability snapshot: the single place the color/glyph *decision* is
/// made. Renderers stay pure producers taking explicit bools/options; apps call
/// $(LREF detectTermCaps) once at startup and thread the fields through.
struct TermCaps
{
    bool tty;                 /// stdout is attached to a terminal
    bool colors;              /// emit SGR color/attribute escapes
    bool unicode;             /// emit non-ASCII glyphs (box drawing, ✓/✗ marks)
    ScreenSize!ushort size;   /// terminal size; `0` components mean unknown
}

/// Detects capabilities and prepares the console.
///
/// Colors are on only when stdout is a terminal and neither `noColors`,
/// `$NO_COLOR`, nor `TERM=dumb` disables them; a non-empty, non-`"0"`
/// `$CLICOLOR_FORCE` forces them on for a non-tty (but never overrides an
/// explicit disable). On Windows this additionally sets the output code page to
/// UTF-8 (so `✓ ✗ ⚙` render even without colors) and enables virtual-terminal
/// processing (so ANSI escapes are interpreted rather than printed literally);
/// colors stay off when stdout is redirected or VT can't be enabled.
TermCaps detectTermCaps(bool noColors = false) @safe
{
    import std.process : environment;

    TermCaps caps;
    caps.tty = isTerminal(StdStream.stdout);
    caps.size = terminalSize();

    const forceVar = environment.get("CLICOLOR_FORCE", "");
    const force = forceVar.length != 0 && forceVar != "0";
    const disabled = noColors
        || environment.get("NO_COLOR", "").length != 0
        || environment.get("TERM", "") == "dumb";

    version (Windows)
    {
        import core.sys.windows.windows : DWORD,
            ENABLE_VIRTUAL_TERMINAL_PROCESSING, GetConsoleMode, GetStdHandle,
            INVALID_HANDLE_VALUE, SetConsoleMode, SetConsoleOutputCP,
            STD_OUTPUT_HANDLE;

        enum uint CP_UTF8 = 65_001;
        const vt = () @trusted {
            SetConsoleOutputCP(CP_UTF8);
            auto handle = GetStdHandle(STD_OUTPUT_HANDLE);
            if (handle is null || handle == INVALID_HANDLE_VALUE)
                return false;
            DWORD mode;
            if (!GetConsoleMode(handle, &mode))
                return false;
            return SetConsoleMode(handle, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING) != 0;
        }();
        caps.unicode = true; // output code page is now UTF-8
        caps.colors = !disabled && (force || (caps.tty && vt));
    }
    else
    {
        caps.unicode = localeIsUtf8();
        caps.colors = !disabled && (force || caps.tty);
    }
    return caps;
}

/// UTF-8 locale heuristic: `LC_ALL` > `LC_CTYPE` > `LANG`, matching `utf-8` /
/// `utf8` case-insensitively. No locale variable at all defaults to `true`
/// (every modern terminal is UTF-8); only an explicit non-UTF-8 locale opts out.
private bool localeIsUtf8() @safe
{
    import std.algorithm.searching : canFind;
    import std.process : environment;
    import std.uni : toLower;

    foreach (name; ["LC_ALL", "LC_CTYPE", "LANG"])
    {
        const v = environment.get(name, "");
        if (v.length == 0)
            continue;
        const lower = v.toLower;
        return lower.canFind("utf-8") || lower.canFind("utf8");
    }
    return true;
}

/// `noColors: true` wins over everything (including `$CLICOLOR_FORCE`); the
/// other fields are environment-dependent, so only their relations are pinned.
@("detectTermCaps.contract")
@safe
unittest
{
    const caps = detectTermCaps(noColors: true);
    assert(!caps.colors);
    assert(caps.tty == isTerminal());
}
