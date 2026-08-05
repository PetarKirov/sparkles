/++
Input: decode a terminal byte stream into the $(B shared)
$(REF Event, sparkles,input,events) vocabulary of `sparkles:input` (spec
I1/I2/I3 + `INP7`) — an expanded key vocabulary (arrows, Home/End, PageUp/Down,
Insert/Delete, F1–F12, with Ctrl/Alt/Shift modifiers, plus printable Unicode),
SGR-1006 mouse (press/release/drag/move + wheel), and terminal resize delivered as
an event. The library keeps no private key/modifier/event types: what the
toolkit's state machines consume is exactly what the decoder produces.

Pointer positions are converted from the wire's 1-based cells to the toolkit's
0-based $(REF Point, sparkles,input,events) at the decode boundary, so nothing
downstream ever re-subtracts 1.

The escape/mouse $(B decoding) ($(LREF decodeEscape), $(LREF decodeMouse)) is pure
and unit-tested over byte slices. The $(LREF PosixEvents) reader is the thin fd
layer that assembles sequences from stdin and turns a SIGWINCH into a
$(REF ResizeEvent, sparkles,input,events) (a no-op signal handler with no
`SA_RESTART`, so a blocking read returns `EINTR` on resize). Posix-only.
+/
module sparkles.tui.input;

/// The shared vocabulary is the module's surface: importing `sparkles.tui.input`
/// gives you `Event`, `Key`, `Mods`, `match` and friends.
public import sparkles.input;

// ── Pure decoding ────────────────────────────────────────────────────────────

/// Decode the bytes $(I after) an `ESC` — a CSI (`[…`) or SS3 (`O…`) sequence, or
/// a bare printable (Alt+key). An empty slice is a lone `Esc`; an unrecognized
/// or incomplete sequence is `NoEvent`.
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
        return Event(NoEvent()); // incomplete
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
                default:    return Event(NoEvent());
            }
        default: return Event(NoEvent());
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
/// `b ; x ; y (M|m)`. `b`'s low bits select the button, bit 5 is drag/motion
/// (motion + no button → `PointerAction.move`; motion + button → drag),
/// bit 6 is the wheel; a trailing `m` is a release. Wire coordinates are
/// 1-based; the returned position is the toolkit's 0-based cell.
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
        return Event(NoEvent());

    const pos = Point(x > 0 ? cast(int) x - 1 : 0, y > 0 ? cast(int) y - 1 : 0);
    const mods = modsFromParam(1 + ((b >> 2) & 7));

    if (b & 64) // wheel: 64=up 65=down 66=left 67=right (deltaY/deltaX signs)
        switch (b & 3)
        {
            // The notch→cells multiplication happens HERE, at the producer
            // (INP12): consumers scroll by `dy` as given, so a source with no
            // notches (a touch drag, already whole rows) can emit the same
            // event without every consumer having to know which it was.
            case 0: return Event(WheelEvent(dy: -linesPerNotch, pos: pos, mods: mods));
            case 1: return Event(WheelEvent(dy: +linesPerNotch, pos: pos, mods: mods));
            case 2: return Event(WheelEvent(dx: -linesPerNotch, pos: pos, mods: mods));
            default: return Event(WheelEvent(dx: +linesPerNotch, pos: pos, mods: mods));
        }

    const button = cast(PointerButton)(b & 3);
    const action = fin == 'm' ? PointerAction.release
        : (b & 32) ? (button == PointerButton.none
            ? PointerAction.move : PointerAction.drag)
        : PointerAction.press;
    return Event(PointerEvent(action: action, button: button, pos: pos, mods: mods));
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
        /**
        What a terminal's input offers (`IXB10`/`TGT5`): SGR-1006 reports
        motion without a button, so hover is real — but positions arrive as
        whole cells and there is exactly one pointer.

        Fixed rather than settable: unlike a raylib window, which is a mouse
        target or a touch target depending on the device, every terminal this
        decoder drives has the same shape.
        */
        enum InputCapabilities capabilities = cellPointer;

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

        /// True when input is ready within `timeout`, without consuming any —
        /// a bounded idle tick for callers that also harvest async work
        /// (e.g. the explorer's git-status refresh) between events.
        bool ready(Duration timeout) @trusted nothrow
        {
            import core.sys.posix.poll : poll, pollfd, POLLIN;

            pollfd pfd;
            pfd.fd = _fd;
            pfd.events = POLLIN;
            return poll(&pfd, 1, cast(int) timeout.total!"msecs") > 0;
        }

        /// Block for the next event. A SIGWINCH mid-read yields a `ResizeEvent`
        /// (with a zero size — the caller re-queries the terminal); EOF / read
        /// error yields `EndOfInput`.
        Event next() @trusted nothrow
        {
            char b;
            const n = read(_fd, &b, 1);
            if (n < 0)
                return errno == EINTR
                    ? Event(ResizeEvent()) : Event(EndOfInput());
            if (n == 0)
                return Event(EndOfInput());
            if (b == 0x1b)
                return readEscape();
            if ((cast(ubyte) b) >= 0x80)
                return readUtf8(b);
            return classifyByte(b);
        }

        /**
        Wait at most `timeout` for the next event; `NoEvent` when it elapses.

        The seam an event loop needs when something other than the terminal
        also has to make progress (a background subprocess feeding the view):
        the loop keeps blocking on input, but wakes on a deadline instead of
        only on a keystroke. A zero timeout polls. `next()` itself is
        unchanged — a loop that never passes a timeout blocks exactly as before.
        */
        Event next(Duration timeout) @trusted nothrow
        {
            import core.sys.posix.poll : poll, pollfd, POLLIN;

            pollfd pfd;
            pfd.fd = _fd;
            pfd.events = POLLIN;
            const ms = timeout.total!"msecs";
            const r = poll(&pfd, 1, ms > int.max ? int.max : cast(int) ms);
            if (r == 0)
                return Event(NoEvent()); // the deadline, not input
            if (r < 0)
                return errno == EINTR
                    ? Event(ResizeEvent()) : Event(EndOfInput());
            return next(); // readable (or hung up): the blocking path decodes it
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

    @("input.PosixEvents.nextWithTimeout")
    @system unittest
    {
        import core.sys.posix.unistd : close, pipe, write;

        // A pipe stands in for the terminal (`start` takes the fd), so the
        // deadline behavior is testable with no tty and no raw mode.
        int[2] fds;
        assert(pipe(fds) == 0);
        scope (exit) close(fds[0]);

        auto ev = PosixEvents.start(fds[0]);

        // Nothing to read: the deadline expires with no event (not EOF).
        assert(ev.next(0.msecs) == Event(NoEvent()));
        assert(ev.next(10.msecs) == Event(NoEvent()));

        // A byte within the window decodes exactly as the blocking path does.
        immutable char[1] a = "a";
        assert(write(fds[1], a.ptr, 1) == 1);
        assert(ev.next(1000.msecs) == charEvent('a'));

        // The writer closing is end-of-input, not another timeout.
        close(fds[1]);
        assert(ev.next(1000.msecs).isEndOfInput);
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
    assert(decodeEscape("[1;5A") == keyEvent(Key.up, Mods(ctrl: true)));
    // Shift+Alt+Left = param 4 (bits 3 = shift|alt).
    assert(decodeEscape("[1;4D") == keyEvent(Key.left, Mods(alt: true, shift: true)));
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
    // Wire cells are 1-based; the decoded position is 0-based toolkit cells.
    assert(decodeMouse("0;10;5M") == Event(PointerEvent(
        action: PointerAction.press, button: PointerButton.left, pos: Point(9, 4))));
    assert(decodeMouse("0;1;1m") == Event(PointerEvent(
        action: PointerAction.release, button: PointerButton.left, pos: Point(0, 0))));
    assert(decodeMouse("32;3;4M") == Event(PointerEvent(  // motion bit + left
        action: PointerAction.drag, button: PointerButton.left, pos: Point(2, 3))));
    assert(decodeMouse("35;5;6M") == Event(PointerEvent(  // motion bit + none → free move
        action: PointerAction.move, button: PointerButton.none, pos: Point(4, 5))));
    assert(decodeMouse("2;1;1M") == Event(PointerEvent(
        action: PointerAction.press, button: PointerButton.right, pos: Point(0, 0))));
    // Wheel signs follow the web's deltaY/deltaX: up/left negative.
    // Wheel deltas are CELLS, not notches: the decoder applies
    // `linesPerNotch` so every consumer scrolls by `dy` as given (INP12).
    assert(decodeMouse("64;1;1M") == Event(WheelEvent(dy: -linesPerNotch)));
    assert(decodeMouse("65;1;1M") == Event(WheelEvent(dy: +linesPerNotch)));
    assert(decodeMouse("66;1;1M") == Event(WheelEvent(dx: -linesPerNotch)));
    assert(decodeMouse("67;1;1M") == Event(WheelEvent(dx: +linesPerNotch)));
    // A notch is more than one cell — the property that makes the producer,
    // not the consumer, the right place to apply it.
    assert(linesPerNotch > 1);
}

@("input.classifyByte.controlAndPrintable")
@safe pure nothrow @nogc
unittest
{
    assert(classifyByte('\r') == keyEvent(Key.enter));
    assert(classifyByte('\t') == keyEvent(Key.tab));
    assert(classifyByte(0x7f) == keyEvent(Key.backspace));
    assert(classifyByte('a') == charEvent('a'));
    assert(classifyByte(0x01) == charEvent('a', Mods(ctrl: true))); // Ctrl-A
}
