/++
Input: decode a terminal byte stream into structured $(LREF Event)s (spec I1/I2/I3)
— an expanded key vocabulary (arrows, Home/End, PageUp/Down, Insert/Delete,
F1–F12, with Ctrl/Alt/Shift modifiers, plus printable Unicode), SGR-1006 mouse
(press/release/drag/wheel), and terminal resize delivered as an event.

The escape/mouse $(B decoding) ($(LREF decodeEscape), $(LREF decodeMouse)) is pure
and unit-tested over byte slices. The $(LREF PosixEvents) reader is the thin fd
layer that assembles sequences from stdin and turns a SIGWINCH into a
$(LREF EventKind.resize) event (a no-op signal handler with no `SA_RESTART`, so a
blocking read returns `EINTR` on resize). Posix-only.
+/
module sparkles.tui.input;

import sparkles.core_cli.term_caps : TermSize, TermPosition;

/// A decoded key. `char_` carries a printable code point in `Event.ch`; the rest
/// are named keys. `none` is an unrecognized / incomplete sequence.
enum Key : ubyte
{
    none, char_,
    up, down, left, right,
    home, end, pageUp, pageDown, insert, delete_,
    enter, tab, backspace, escape,
    f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
}

/// Keyboard modifiers carried on a key or mouse event.
struct Mods
{
    bool ctrl;
    bool alt;
    bool shift;
}

/// The mouse button of a $(LREF EventKind.mouse) event.
enum MouseButton : ubyte { left, middle, right, none }

/// What the mouse did.
enum MouseAction : ubyte { press, release, drag, wheelUp, wheelDown }

/// The kind of an $(LREF Event) (selects which fields are meaningful).
enum EventKind : ubyte { none, key, mouse, resize, eof }

/// One input event. A flat tagged record: `kind` selects the live fields.
struct Event
{
    EventKind kind;

    // kind == key
    Key key;
    dchar ch;   /// the code point when `key == Key.char_`
    Mods mods;

    // kind == mouse
    MouseButton button;
    MouseAction action;
    TermPosition mouse; /// 1-based cell coordinates (`.col` / `.row`)

    // kind == resize
    TermSize size;
}

/// A named-key event.
Event keyEvent(Key k, Mods m = Mods()) @safe pure nothrow @nogc
    => Event(kind: EventKind.key, key: k, mods: m);

/// A printable code-point event.
Event charEvent(dchar c, Mods m = Mods()) @safe pure nothrow @nogc
    => Event(kind: EventKind.key, key: Key.char_, ch: c, mods: m);

// ── Pure decoding ────────────────────────────────────────────────────────────

/// Decode the bytes $(I after) an `ESC` — a CSI (`[…`) or SS3 (`O…`) sequence, or
/// a bare printable (Alt+key). An empty slice is a lone `Esc`.
Event decodeEscape(scope const(char)[] s) @safe pure nothrow @nogc
{
    if (s.length == 0)
        return keyEvent(Key.escape);
    if (s[0] != '[' && s[0] != 'O')
        return charEvent(s[0], Mods(alt: true)); // ESC + key = Alt+key
    if (s.length >= 2 && s[0] == '[' && s[1] == '<')
        return decodeMouse(s[2 .. $]);

    // Parse `p1 [; p2 …] final`. Params are decimal; the final is the last byte.
    uint[3] p;
    size_t np;
    size_t i = 1;
    bool sawDigit;
    for (; i < s.length; ++i)
    {
        const c = s[i];
        if (c >= '0' && c <= '9')
        {
            if (np < p.length)
                p[np] = p[np] * 10 + (c - '0');
            sawDigit = true;
        }
        else if (c == ';')
        {
            if (np < p.length)
                ++np;
            sawDigit = false;
        }
        else
            break; // the final byte
    }
    if (sawDigit && np < p.length)
        ++np;
    if (i >= s.length)
        return keyEvent(Key.none); // incomplete
    const f = s[i];
    // The modifier param (`[1;<m><final>`), 1-based: m-1 is the modifier bitset.
    const mods = np >= 2 ? modsFromParam(p[1]) : Mods();

    switch (f)
    {
        case 'A': return keyEvent(Key.up, mods);
        case 'B': return keyEvent(Key.down, mods);
        case 'C': return keyEvent(Key.right, mods);
        case 'D': return keyEvent(Key.left, mods);
        case 'H': return keyEvent(Key.home, mods);
        case 'F': return keyEvent(Key.end, mods);
        case 'P': return keyEvent(Key.f1, mods); // SS3 F1–F4
        case 'Q': return keyEvent(Key.f2, mods);
        case 'R': return keyEvent(Key.f3, mods);
        case 'S': return keyEvent(Key.f4, mods);
        case '~':
            switch (np >= 1 ? p[0] : 0)
            {
                case 1, 7:  return keyEvent(Key.home, mods);
                case 2:     return keyEvent(Key.insert, mods);
                case 3:     return keyEvent(Key.delete_, mods);
                case 4, 8:  return keyEvent(Key.end, mods);
                case 5:     return keyEvent(Key.pageUp, mods);
                case 6:     return keyEvent(Key.pageDown, mods);
                case 11:    return keyEvent(Key.f1, mods);
                case 12:    return keyEvent(Key.f2, mods);
                case 13:    return keyEvent(Key.f3, mods);
                case 14:    return keyEvent(Key.f4, mods);
                case 15:    return keyEvent(Key.f5, mods);
                case 17:    return keyEvent(Key.f6, mods);
                case 18:    return keyEvent(Key.f7, mods);
                case 19:    return keyEvent(Key.f8, mods);
                case 20:    return keyEvent(Key.f9, mods);
                case 21:    return keyEvent(Key.f10, mods);
                case 23:    return keyEvent(Key.f11, mods);
                case 24:    return keyEvent(Key.f12, mods);
                default:    return keyEvent(Key.none);
            }
        default: return keyEvent(Key.none);
    }
}

private Mods modsFromParam(uint m) @safe pure nothrow @nogc
{
    if (m == 0)
        return Mods();
    const bits = m - 1;
    return Mods(ctrl: (bits & 4) != 0, alt: (bits & 2) != 0, shift: (bits & 1) != 0);
}

/// Decode the tail of an SGR-1006 mouse report (the bytes after `ESC [ <`):
/// `b ; x ; y (M|m)`. `b`'s low bits select the button, bit 5 is drag/motion,
/// bit 6 is the wheel; a trailing `m` is a release.
Event decodeMouse(scope const(char)[] s) @safe pure nothrow @nogc
{
    uint b, x, y, field;
    char fin;
    foreach (c; s)
    {
        if (c >= '0' && c <= '9')
        {
            const v = c - '0';
            if (field == 0) b = b * 10 + v;
            else if (field == 1) x = x * 10 + v;
            else y = y * 10 + v;
        }
        else if (c == ';')
            ++field;
        else
        {
            fin = c;
            break;
        }
    }
    if (fin != 'M' && fin != 'm')
        return keyEvent(Key.none);

    Event e = {kind: EventKind.mouse, mouse: TermPosition(cast(ushort) x, cast(ushort) y),
        mods: modsFromParam(1 + ((b >> 2) & 7))};
    if (b & 64) // wheel
        e.action = (b & 1) ? MouseAction.wheelDown : MouseAction.wheelUp;
    else
    {
        e.button = cast(MouseButton)(b & 3);
        e.action = fin == 'm' ? MouseAction.release
            : (b & 32) ? MouseAction.drag : MouseAction.press;
    }
    return e;
}

/// Classify a single non-escape input byte: control bytes to named keys /
/// Ctrl-letters, printable ASCII to a char event. (Multi-byte UTF-8 is assembled
/// by the reader before it reaches here.)
Event classifyByte(char b) @safe pure nothrow @nogc
{
    switch (b)
    {
        case '\r', '\n': return keyEvent(Key.enter);
        case '\t':       return keyEvent(Key.tab);
        case 0x7f, 0x08: return keyEvent(Key.backspace);
        case 0x1b:       return keyEvent(Key.escape); // bare ESC (no follow-up)
        default:
            if (b >= 1 && b <= 26) // Ctrl-A .. Ctrl-Z
                return charEvent(cast(dchar)('a' + b - 1), Mods(ctrl: true));
            return charEvent(cast(dchar)(cast(ubyte) b));
    }
}

version (Posix)
{
    import core.sys.posix.termios : termios;
    import core.sys.posix.unistd : read, STDIN_FILENO;
    import core.sys.posix.signal : sigaction, sigaction_t;
    import core.stdc.errno : EINTR, errno;
    import core.time : Duration, msecs;

    version (linux) private enum SIGWINCH = 28;
    version (OSX)   private enum SIGWINCH = 28;

    // How long `readEscape` waits for a byte after a lone `ESC` before deciding it
    // was the Escape key rather than the introducer of a control sequence.
    private enum Duration escapeTimeout = 40.msecs;

    // A no-op SIGWINCH handler installed without SA_RESTART, so a resize
    // interrupts a blocking read() with EINTR (surfaced as a resize event).
    private extern (C) void tuiWinchNoop(int) nothrow @nogc @system {}

    /// Reads and decodes events from stdin. Install once for the session; the
    /// destructor removes the SIGWINCH handler. `Terminal` should already have put
    /// stdin in raw mode.
    struct PosixEvents
    {
        private sigaction_t _oldWinch;
        private bool _installed;
        private int _fd = STDIN_FILENO;

        @disable this(this);

        /// Begin: install the SIGWINCH handler so resizes surface as events, and
        /// read from `fd` (default stdin; pass a pty slave fd to drive a test).
        static PosixEvents start(int fd = STDIN_FILENO) @trusted nothrow
        {
            PosixEvents e;
            e._fd = fd;
            sigaction_t sa;
            sa.sa_handler = &tuiWinchNoop;
            if (sigaction(SIGWINCH, &sa, &e._oldWinch) == 0)
                e._installed = true;
            return e;
        }

        ~this() @trusted nothrow
        {
            if (_installed)
                sigaction(SIGWINCH, &_oldWinch, null);
        }

        /// Block for the next event. A SIGWINCH mid-read yields a `resize` event
        /// (with a zero size — the caller re-queries the terminal); EOF / read
        /// error yields `eof`.
        Event next() @trusted nothrow
        {
            char b;
            const n = read(_fd, &b, 1);
            if (n < 0)
                return errno == EINTR
                    ? Event(kind: EventKind.resize) : Event(kind: EventKind.eof);
            if (n == 0)
                return Event(kind: EventKind.eof);
            if (b == 0x1b)
                return readEscape();
            if ((cast(ubyte) b) >= 0x80)
                return readUtf8(b);
            return classifyByte(b);
        }

        // Assemble an escape sequence: introducer, then params/coords until a
        // final byte (letter or `~`, or `M`/`m` for mouse). A lone ESC (nothing
        // within the poll window) decodes as Esc.
        private Event readEscape() @trusted nothrow
        {
            char[32] buf = void;
            size_t n;
            char intro;
            if (!readTimed(intro, escapeTimeout))
                return keyEvent(Key.escape);
            buf[n++] = intro;
            if (intro == '[' || intro == 'O')
            {
                char c;
                while (n < buf.length && readRaw(c))
                {
                    buf[n++] = c;
                    // Final byte: a letter, `~`, or a mouse terminator.
                    if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '~')
                        break;
                }
            }
            return decodeEscape(buf[0 .. n]);
        }

        // Assemble a UTF-8 multi-byte code point starting at lead byte `lead`.
        private Event readUtf8(char lead) @trusted nothrow
        {
            const nc = (cast(ubyte) lead) >= 0xF0 ? 3
                : (cast(ubyte) lead) >= 0xE0 ? 2
                : (cast(ubyte) lead) >= 0xC0 ? 1 : 0;
            dchar cp = (cast(ubyte) lead) & (0x7F >> nc);
            foreach (_; 0 .. nc)
            {
                char c;
                if (!readRaw(c))
                    break;
                cp = (cp << 6) | ((cast(ubyte) c) & 0x3F);
            }
            return charEvent(cp);
        }

        private bool readRaw(ref char b) @trusted nothrow
        {
            return read(_fd, &b, 1) == 1;
        }

        private bool readTimed(ref char b, Duration timeout) @trusted nothrow
        {
            import core.sys.posix.poll : poll, pollfd, POLLIN;

            pollfd pfd;
            pfd.fd = _fd;
            pfd.events = POLLIN;
            if (poll(&pfd, 1, cast(int) timeout.total!"msecs") <= 0)
                return false;
            return read(_fd, &b, 1) == 1;
        }
    }
}

@("input.decodeEscape.arrowsAndModifiers")
@safe pure nothrow @nogc
unittest
{
    assert(decodeEscape("[A") == keyEvent(Key.up));
    assert(decodeEscape("OB") == keyEvent(Key.down)); // SS3 form
    assert(decodeEscape("[C") == keyEvent(Key.right));
    // Ctrl+Up = `ESC [ 1 ; 5 A` (modifier param 5 → ctrl).
    const ctrlUp = decodeEscape("[1;5A");
    assert(ctrlUp.key == Key.up && ctrlUp.mods.ctrl && !ctrlUp.mods.alt);
    // Shift+Alt+Left = param 4 (bits 3 = shift|alt).
    const saLeft = decodeEscape("[1;4D");
    assert(saLeft.key == Key.left && saLeft.mods.shift && saLeft.mods.alt && !saLeft.mods.ctrl);
}

@("input.decodeEscape.navAndFunctionKeys")
@safe pure nothrow @nogc
unittest
{
    static struct Case { string input; Event want; }
    // `static immutable` (not a runtime AA literal) keeps this `@nogc`; the modifier
    // and Alt cases fold in via `keyEvent`/`charEvent` rather than staying loose.
    static immutable Case[] cases = [
        Case("[5~",  keyEvent(Key.pageUp)),
        Case("[6~",  keyEvent(Key.pageDown)),
        Case("[3~",  keyEvent(Key.delete_)),
        Case("[2~",  keyEvent(Key.insert)),
        Case("[H",   keyEvent(Key.home)),
        Case("[15~", keyEvent(Key.f5)),
        Case("[24~", keyEvent(Key.f12)),
        Case("OP",   keyEvent(Key.f1)),
        Case("",     keyEvent(Key.escape)),          // lone Esc
        Case("a",    charEvent('a', Mods(alt: true))), // ESC + a = Alt+a
    ];
    foreach (c; cases)
        assert(decodeEscape(c.input) == c.want, c.input);
}

@("input.decodeMouse.buttonsWheelDrag")
@safe pure nothrow @nogc
unittest
{
    const press = decodeMouse("0;10;5M");
    assert(press.kind == EventKind.mouse && press.button == MouseButton.left
        && press.action == MouseAction.press && press.mouse.col == 10 && press.mouse.row == 5);
    assert(decodeMouse("0;1;1m").action == MouseAction.release);
    assert(decodeMouse("32;3;4M").action == MouseAction.drag);  // motion bit
    assert(decodeMouse("64;1;1M").action == MouseAction.wheelUp);
    assert(decodeMouse("65;1;1M").action == MouseAction.wheelDown);
    assert(decodeMouse("2;1;1M").button == MouseButton.right);
}

@("input.classifyByte.controlAndPrintable")
@safe pure nothrow @nogc
unittest
{
    assert(classifyByte('\r') == keyEvent(Key.enter));
    assert(classifyByte('\t') == keyEvent(Key.tab));
    assert(classifyByte(0x7f) == keyEvent(Key.backspace));
    assert(classifyByte('a').ch == 'a');
    const cA = classifyByte(0x01); // Ctrl-A
    assert(cA.ch == 'a' && cA.mods.ctrl);
}
