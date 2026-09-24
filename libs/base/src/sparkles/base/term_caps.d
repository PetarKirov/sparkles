/++
Terminal capability probing: the synchronous size query ($(LREF terminalSize)),
tty and color detection ($(LREF detectTermCaps)), and resize notifications
($(LREF setTermWindowSizeHandler)).

This is the single place the "what can this terminal do" *decision* is made;
renderers stay pure producers that take explicit widths/flags. It lives in
`sparkles:base` rather than a UI package because it is an **environment query**,
not a presentation concern — a logger, a CLI tool and a full-screen UI all need
it, and none of them should pull in a UI stack to ask.

$(LREF TermSize) is deliberately a plain POD rather than a
$(REF Vector, sparkles,math,vector) specialization: `base` sits below
`sparkles:math`, and a capability snapshot never does vector arithmetic. The
terminal's *geometry* types — positions you add offsets to — live in
`sparkles:tui` (`TermPosition`), which is free to specialize `Vector`.
+/
module sparkles.base.term_caps;

import sparkles.base.term_color : ColorDepth, classifyColorDepth;

/// A terminal size in cells. A `0` component means that axis is unknown — see
/// $(LREF terminalSize).
struct TermSize
{
    ushort width;  /// columns
    ushort height; /// rows
}

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
    alias Handler = void delegate(TermSize size) nothrow @nogc;

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
        _handler(TermSize(s.ws_col, s.ws_row));
    }
}

/// Current terminal size in cells (columns × rows). A `0` component means that
/// axis can't be determined — `stream` not a tty, redirected to a pipe/file, or
/// the OS query failed; `TermSize.init` (0×0) is the fully-unknown
/// value. A synchronous one-shot query, distinct from the async
/// `setTermWindowSizeHandler` above. Callers use `0` to mean "unknown, don't
/// wrap/truncate/clamp". The streams can point at different terminals (or none):
/// `dub test -- --bench > file` leaves stderr — a progress line — on the
/// terminal while stdout is a file, so the line's budget is stderr's width.
TermSize terminalSize(StdStream stream = StdStream.stdout) @safe nothrow @nogc
{
    version (Posix)
    {
        import core.sys.posix.sys.ioctl : ioctl, winsize, TIOCGWINSZ;
        import core.sys.posix.unistd : STDERR_FILENO, STDIN_FILENO, STDOUT_FILENO;

        int fd;
        final switch (stream)
        {
            case StdStream.stdin:  fd = STDIN_FILENO;  break;
            case StdStream.stdout: fd = STDOUT_FILENO; break;
            case StdStream.stderr: fd = STDERR_FILENO; break;
        }
        // The ioctl and its out-parameter are one unsafe unit; scope trust to
        // it (capturing nothing, so no `@nogc` closure) and hand back a plain
        // value.
        return (int fd) @trusted {
            winsize s;
            if (ioctl(fd, TIOCGWINSZ, &s) != 0)
                return TermSize.init;
            return TermSize(s.ws_col, s.ws_row);
        }(fd);
    }
    else version (Windows)
    {
        import core.sys.windows.windows : CONSOLE_SCREEN_BUFFER_INFO, DWORD,
            GetConsoleScreenBufferInfo, GetStdHandle, INVALID_HANDLE_VALUE,
            STD_ERROR_HANDLE, STD_INPUT_HANDLE, STD_OUTPUT_HANDLE;

        DWORD id;
        final switch (stream)
        {
            case StdStream.stdin:  id = STD_INPUT_HANDLE;  break;
            case StdStream.stdout: id = STD_OUTPUT_HANDLE; break;
            case StdStream.stderr: id = STD_ERROR_HANDLE;  break;
        }
        // Same: the handle lookup and console query are the unsafe unit.
        return (DWORD id) @trusted {
            auto handle = GetStdHandle(id);
            if (handle is null || handle == INVALID_HANDLE_VALUE)
                return TermSize.init;
            CONSOLE_SCREEN_BUFFER_INFO info;
            if (!GetConsoleScreenBufferInfo(handle, &info))
                return TermSize.init;
            const width = info.srWindow.Right - info.srWindow.Left + 1;
            const height = info.srWindow.Bottom - info.srWindow.Top + 1;
            if (width <= 0 || height <= 0)
                return TermSize.init;
            return TermSize(cast(ushort) width, cast(ushort) height);
        }(id);
    }
    else
        return TermSize.init;
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

    // The stderr query is just as callable; both streams may or may not be
    // terminals here, so again only the "0 = unknown" contract is pinned.
    const errSize = terminalSize(StdStream.stderr);
    assert(errSize.width == 0 || errSize.width >= 1);
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

/// How fine the block-element tier a terminal's font covers
/// ($(LREF OutputCapabilities.blocks)).
enum BlockTier : ubyte
{
    none,     /// no block elements
    half,     /// `▀▄█` and the eighth-blocks `▏…▉` / `▁…▇`
    quadrant, /// the 2×2 quadrants (U+2596–U+259F)
    sextant,  /// the 2×3 sextants (Symbols for Legacy Computing)
    octant,   /// the 2×4 octants (Unicode 16)
}

/**
How a target shows raster images ($(LREF OutputCapabilities.images)): a
terminal's inline-image protocol, or `pixels` for a target that composites
decoded pixels itself — a window, which shows anything any protocol could.
*/
enum ImageProtocol : ubyte
{
    none,
    sixel,  /// DEC sixel
    iterm2, /// OSC 1337
    kitty,  /// the kitty graphics protocol
    pixels, /// the target draws decoded pixels itself (a window)
}

/**
What an output target can $(B render and carry) — the affordances a renderer
degrades on, named abstractly (`clipboard`, not "OSC 52") because a window
serves most of them too, by other means. A terminal's answers arrive through
$(LREF TermCaps); a GUI or HTML target declares its own constants. Every
default is the conservative answer, so a producer that has not thought about
a field claims nothing.

This is the vocabulary the design system's capability table is written in
(`docs/specs/design-system/capabilities.md`, `CAP1`–`CAP3`); its input-side
counterpart is `sparkles.input.capability.InputCapabilities`.
*/
struct OutputCapabilities
{
    ColorDepth colorDepth;   /// color tier to emit; `none` means no SGR color at all
    bool unicode;            /// emit non-ASCII glyphs (box drawing, ✓/✗ marks)
    BlockTier blocks;        /// block-element coverage (configured; a font fact)
    bool braille;            /// U+2800 renders as a 2×4 grid (configured)
    bool nerdFont;           /// Nerd Font PUA glyphs available (configured; unqueryable)

    bool hyperlinks;         /// clickable links (OSC 8 on a terminal)
    bool clipboard;          /// a clipboard write can be carried (OSC 52)
    bool notifications;      /// desktop notifications (OSC 99 / 9 / 777)
    bool pointerShape;       /// the pointer shape can be set (OSC 22)
    bool textSizing;         /// multi-cell / scaled text (OSC 66)
    ImageProtocol images;    /// inline images
    bool syncOutput;         /// atomic frame presentation (mode 2026)
    bool progress;           /// a taskbar progress mirror (OSC 9;4)
    bool extendedUnderline;  /// curly/colored underlines (SGR 4:3 + 58)
    bool cellPixelSize;      /// the cell's pixel size is known (CSI 16 t)
    bool graphemeClusters;   /// the terminal segments by grapheme (mode 2027)
    bool colorSchemeNotify;  /// scheme changes are pushed (mode 2031 / OSC 11)

    /// `true` iff any SGR color may be emitted — a view of `colorDepth`, not a
    /// second field that could disagree with it.
    bool colors() const @safe pure nothrow @nogc => colorDepth != ColorDepth.none;
}

/**
One-shot terminal capability snapshot: the single place the color/glyph
$(I decision) is made. Renderers stay pure producers taking explicit
bools/options; apps call $(LREF detectTermCaps) once at startup and thread the
fields through.

The output affordances are the embedded $(LREF OutputCapabilities) (reachable
directly: `caps.colors`, `caps.unicode`); the raw terminal $(B input modes)
below are what `sparkles.input.capability.fromTerminal` turns into the
target-neutral `InputCapabilities`. $(LREF detectTermCaps) fills what the
environment answers; the query-derived fields (DA1, DECRQM, XTGETTCAP) are
`sparkles:tui`'s to fill, on the same value.
*/
struct TermCaps
{
    bool tty;                  /// stdout is attached to a terminal
    TermSize size;             /// terminal size; `0` components mean unknown
    OutputCapabilities output; /// what may be emitted
    alias output this;

    // Raw terminal input modes — protocol facts, not yet input affordances.
    bool mouseSgr;        /// SGR-1006 button events
    bool anyMotion;       /// mode 1003: motion without a button held
    bool pixelMouse;      /// mode 1016: pixel coordinates
    bool focusReporting;  /// mode 1004
    bool bracketedPaste;  /// mode 2004
    bool kittyKeyboard;   /// the kitty keyboard protocol (release/repeat, CSI u)
}

/// Detects capabilities and prepares the console.
///
/// Colors are on only when stdout is a terminal and neither `noColors`,
/// `$NO_COLOR`, nor `TERM=dumb` disables them; a non-empty, non-`"0"`
/// `$CLICOLOR_FORCE` forces them on for a non-tty (but never overrides an
/// explicit disable). `colorDepth` is the tier
/// ($(REF classifyColorDepth, sparkles,base,term_color) over `$COLORTERM`/`$TERM`)
/// when colors are on, else `none`. On Windows this additionally sets the output code page to
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
        const colors = !disabled && (force || (caps.tty && vt));
    }
    else
    {
        caps.unicode = localeIsUtf8();
        const colors = !disabled && (force || caps.tty);
    }

    // Block elements are a font fact no query answers; every monospace font
    // that renders box drawing also carries the half and eighth blocks, so a
    // Unicode terminal is assumed to have that tier and no finer one.
    caps.blocks = caps.unicode ? BlockTier.half : BlockTier.none;

    // The color tier, folded through the emit decision: the classifier picks
    // the tier from $COLORTERM/$TERM, but a snapshot with colors off reports
    // `none` — `caps.colors` is a view of this one field.
    caps.colorDepth = colors
        ? classifyColorDepth(environment.get("COLORTERM", ""), environment.get("TERM", ""))
        : ColorDepth.none;
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
    assert(caps.colorDepth == ColorDepth.none); // colors off ⇒ no tier
    assert(caps.tty == isTerminal());

    // When colors are on, colorDepth is the classified tier; when off, none.
    const auto_ = detectTermCaps();
    if (!auto_.colors)
        assert(auto_.colorDepth == ColorDepth.none);
    // The block tier is assumed from Unicode and nothing finer.
    assert(auto_.blocks == (auto_.unicode ? BlockTier.half : BlockTier.none));
}

/// `colors` is a view of `colorDepth`, and the embedded output affordances
/// read as the snapshot's own fields.
@("TermCaps.outputIsAliasThis")
@safe pure nothrow @nogc
unittest
{
    TermCaps caps;
    assert(!caps.colors);
    caps.colorDepth = ColorDepth.ansi16;
    assert(caps.colors && caps.output.colors);
    caps.output.unicode = true;
    assert(caps.unicode);
    // A default snapshot claims no affordance and no input mode.
    assert(TermCaps.init.output == OutputCapabilities.init && !TermCaps.init.mouseSgr);
}
