/**
The ring-driven terminal input source (event-horizon SPEC §15.3, the TUI
shape): chunked reads of the raw-mode stdin feed a $(B resumable)
escape-sequence assembler built on `sparkles.tui`'s pure decoders, and the
decoded `sparkles:input` events go into a `Channel` the UI fiber takes
from. `SIGWINCH` arrives as a resize event through a `signalfd` fiber —
never as an `EINTR` side effect.

The assembler exists because the blocking reader (`PosixEvents`) pulls one
byte at a time, which a completion-based reader cannot do: a ring read
delivers a $(I chunk), and an escape sequence (or a UTF-8 code point) may
straddle two chunks. `EscapeAssembler` is the pure, chunk-oriented
re-statement of that state machine — `feed` bytes in, complete events come
out, partial state is retained; `flush` resolves a trailing bare `ESC` when
the follow-up deadline expires (the classic Esc-vs-escape-sequence
disambiguation, expressed as a deadline on the next read instead of a
per-byte poll).
*/
module sparkles.ui_app.event_source;

version (UiAppTui)  :  // needs sparkles:tui's decoders (the tui/full configs)
version (Posix)  :

import sparkles.input : Event, EndOfInput, Key, ResizeEvent, charEvent, keyEvent, match,
    pasteChunks;
import sparkles.tui.input : classifyByte, decodeEscape;

/**
The chunk-oriented escape/UTF-8 assembler. Pure and allocation-free; all
state fits in the struct, so it parks on the caller's frame between
chunks.
*/
struct EscapeAssembler
{
    /// Feeds one chunk; emits every event completed by it.
    void feed(Sink)(scope const(ubyte)[] chunk, scope Sink sink)
    {
        foreach (b; chunk)
            step(cast(char) b, sink);
    }

    /// `true` while a partial escape sequence or UTF-8 code point is
    /// buffered — the caller's cue to bound the next read with the
    /// escape-disambiguation deadline.
    bool pending() const @safe pure nothrow @nogc
        => _state != State.idle && _state != State.paste; // a paste is not ambiguous

    /// Resolves buffered state at a deadline: a bare `ESC` becomes the
    /// escape key; a partial sequence decodes best-effort; a truncated
    /// UTF-8 code point is dropped (there is nothing sound to emit).
    void flush(Sink)(scope Sink sink)
    {
        final switch (_state)
        {
            case State.idle:
                break;
            case State.escape:
                sink(decodeEscape(_buf[0 .. _len]));
                break;
            case State.utf8:
                break;
            case State.paste:
                return; // a paste waits for its end marker, however long it takes
            case State.controlString:
                // An introducer and nothing after it within the window was
                // Alt+key after all; a string cut off by the deadline is a
                // reply's, and is dropped.
                if (!_inString)
                    sink(decodeEscape(_buf[0 .. 1]));
                break;
        }
        _state = State.idle;
        _len = 0;
        _inString = false;
        _stringEsc = false;
    }

private:
    enum State : ubyte
    {
        idle,
        escape, /// after ESC: accumulating intro + params until the final byte
        utf8,   /// accumulating continuation bytes
        /// after `ESC P`/`_`/`]`/`^`/`X`: a control string (a DCS, APC, OSC,
        /// PM or SOS — a terminal's reply, never a keystroke) until its
        /// terminator, `ESC \` or, for OSC, BEL
        controlString,
        /// inside a bracketed paste (`CSI 200~`): every byte is text until
        /// `CSI 201~`
        paste,
    }

    void step(Sink)(char c, scope Sink sink)
    {
        final switch (_state)
        {
            case State.idle:
                if (c == '\x1b')
                {
                    _state = State.escape;
                    _len = 0;
                    return;
                }
                const ub = cast(ubyte) c;
                if (ub >= 0xC0)
                {
                    _state = State.utf8;
                    _need = ub >= 0xF0 ? 3 : ub >= 0xE0 ? 2 : 1;
                    _cp = ub & (0x7F >> _need);
                    return;
                }
                sink(classifyByte(c));
                return;

            case State.escape:
                if (_len == 0)
                {
                    // The introducer decides the shape: `[`/`O` open a
                    // sequence; anything else is Alt+key, complete now.
                    _buf[_len++] = c;
                    if (c == 'P' || c == '_' || c == ']' || c == '^' || c == 'X')
                    {
                        _state = State.controlString;
                        return;
                    }
                    if (c != '[' && c != 'O')
                    {
                        sink(decodeEscape(_buf[0 .. 1]));
                        _state = State.idle;
                        _len = 0;
                    }
                    return;
                }
                if (_len < _buf.length)
                    _buf[_len++] = c;
                // Final byte: a letter or `~` (mouse finals `M`/`m` are
                // letters too) — same predicate as the blocking reader.
                if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '~')
                {
                    if (_buf[0 .. _len] == "[200~")
                    {
                        // Bracketed paste begins: text, not keys, until the end.
                        _state = State.paste;
                        _len = 0;
                        _paste.length = 0;
                        return;
                    }
                    sink(decodeEscape(_buf[0 .. _len]));
                    _state = State.idle;
                    _len = 0;
                }
                return;

            case State.paste:
                _paste ~= c;
                enum end = "\x1b[201~";
                if (_paste.length >= end.length && _paste[$ - end.length .. $] == end)
                {
                    pasteChunks(_paste[0 .. $ - end.length], sink);
                    _state = State.idle;
                    _paste.length = 0;
                }
                return;

            case State.controlString:
                _inString = true;
                if (_stringEsc)
                {
                    _stringEsc = false;
                    if (c == '\\')
                    {
                        _state = State.idle; // ST: the string, dropped whole
                        return;
                    }
                    // Not ST: the string was unterminated; this ESC starts
                    // whatever comes next.
                    _state = State.escape;
                    _len = 0;
                    step(c, sink);
                    return;
                }
                if (c == '\x1b')
                    _stringEsc = true;
                else if (c == '\x07')
                    _state = State.idle; // BEL ends an OSC
                return;

            case State.utf8:
                _cp = (_cp << 6) | ((cast(ubyte) c) & 0x3F);
                if (--_need == 0)
                {
                    sink(charEvent(_cp));
                    _state = State.idle;
                }
                return;
        }
    }

    char[32] _buf;
    size_t _len;
    State _state;
    char[] _paste;   // a bracketed paste so far, end marker not yet seen
    bool _inString;  // a control string has at least one byte past its introducer
    bool _stringEsc; // an ESC inside a control string: ST if `\\` follows
    uint _need;
    dchar _cp;
}

// ── the fiber pumps ─────────────────────────────────────────────────────────

import sparkles.base.buffer : SharedBuffer;
import sparkles.event_horizon.channel : Channel;
import sparkles.event_horizon.io : FileHandle, read;
import sparkles.event_horizon.sched : Sched;
import sparkles.event_horizon.scope_ : withDeadline;

/// The channel type the loop arms share.
alias EventChannel = Channel!(Event, 64);

/**
The input pump (spawned as a daemon fiber): ring-reads `fd` in chunks,
assembles, and puts events. A pending partial sequence bounds the next
read with `escapeTimeoutMs`; expiry flushes it (a bare `ESC` becomes the
escape key). On EOF or a read error, one `EndOfInput` and the pump ends.
*/
void pumpTerminalInput(ref Sched sched, ref EventChannel events, int fd,
    scope const(ubyte)[] typedAhead = null, int escapeTimeoutMs = 40)
{
    import core.lifetime : move;
    import core.time : msecs;

    import sparkles.event_horizon.errors : IoResult, ioOk;

    auto handle = FileHandle(fd);
    EscapeAssembler assembler;

    void emit(Event e)
    {
        cast(void) events.put(sched, e);
    }

    // Input that arrived before this pump did (a capability probe read it),
    // decoded first so nothing typed at startup is lost.
    assembler.feed(typedAhead, &emit);

    for (;;)
    {
        SharedBuffer!(ubyte, 128) buf;
        buf.length = 128;

        uint got;
        bool ended;
        if (assembler.pending)
        {
            // Deadline-bounded continuation read: the Esc-vs-sequence
            // disambiguation window. The deadline cancels the read
            // (SPEC §8.3); the buffer still comes back (§6.2), and the
            // latched interrupt is authoritative even though the body
            // swallows the read's ECANCELED (§8.4).
            auto o = withDeadline!((ref _) {
                auto r = read(handle, move(buf));
                buf = move(r.buf);
                if (r.res.hasError)
                    ended = true;
                else
                    got = r.res.value;
            })(sched, escapeTimeoutMs.msecs);
            if (o.hasError)
            {
                assembler.flush(&emit); // deadline (or teardown): resolve
                if (o.error.isTimeout)
                    continue;
                return; // outside interrupt: unwind quietly
            }
        }
        else
        {
            auto r = read(handle, move(buf));
            buf = move(r.buf);
            if (r.res.hasError)
                ended = true;
            else
                got = r.res.value;
        }

        if (ended || got == 0)
        {
            emit(Event(EndOfInput()));
            return;
        }
        assembler.feed(buf[][0 .. got], &emit);
    }
}

// signalfd is Linux-only; on the kqueue platforms the async arm applies a
// resize on the next delivered event (session.resizeToTerminal runs per
// frame), and the immediate-repaint path arrives with the kqueue
// EVFILT_SIGNAL lowering (event-horizon open-issues O26's sibling
// refinement).
version (linux)
{
    import sparkles.event_horizon.signals : SignalFd;

    /**
    The resize pump (spawned as a daemon fiber): blocks `SIGWINCH` into a
    `signalfd` and delivers each one as a zero-size `ResizeEvent` (the loop
    normalizes it with the real size, `HST7`). Replaces the `EINTR` trick —
    ring reads must never rely on signal interruption.
    */
    void pumpResizeSignals(ref Sched sched, ref EventChannel events, ref SignalFd winch)
    {
        for (;;)
        {
            auto got = winch.nextSignal(sched);
            if (got.hasError)
                return; // cancelled at teardown
            cast(void) events.put(sched, Event(ResizeEvent()));
        }
    }
}

// ── assembler tests (pure, no ring, no tty) ─────────────────────────────────

version (unittest)
{
    import sparkles.input : Mods, PointerEvent;

    private Event[] feedChunks(scope const(char)[][] chunks...) @safe
    {
        EscapeAssembler a;
        Event[] got;
        foreach (c; chunks)
            a.feed(cast(const(ubyte)[]) c, (Event e) { got ~= e; });
        return got;
    }
}

@("ui_app.assembler.plainBytesAndControls")
@safe
unittest
{
    const got = feedChunks("ab\r");
    assert(got.length == 3);
    assert(got[0] == charEvent('a'));
    assert(got[1] == charEvent('b'));
    assert(got[2] == keyEvent(Key.enter));
}

@("ui_app.assembler.escapeSplitAcrossChunks")
@safe
unittest
{
    // The chunk boundary lands mid-sequence — exactly what a ring read can
    // produce and the byte-at-a-time reader never sees.
    const got = feedChunks("\x1b[1;", "5A");
    assert(got.length == 1);
    assert(got[0] == keyEvent(Key.up, Mods(ctrl: true)));
}

@("ui_app.assembler.mouseSgrSequence")
@safe
unittest
{
    import sparkles.tui.input : decodeEscape;

    const got = feedChunks("\x1b[<0;5;3M");
    assert(got.length == 1);
    assert(got[0] == decodeEscape("[<0;5;3M"),
        "the assembler and the blocking decoder agree on SGR mouse");
}

@("ui_app.assembler.bareEscapeResolvesOnFlush")
@safe
unittest
{
    EscapeAssembler a;
    Event[] got;
    a.feed(cast(const(ubyte)[]) "\x1b", (Event e) { got ~= e; });
    assert(got.length == 0, "a bare ESC waits for the disambiguation window");
    assert(a.pending);

    a.flush((Event e) { got ~= e; });
    assert(got.length == 1);
    assert(got[0] == keyEvent(Key.escape));
    assert(!a.pending);
}

@("ui_app.assembler.altKeyAndUtf8Split")
@safe
unittest
{
    // ESC+key is Alt+key, complete without a final byte.
    auto got = feedChunks("\x1bx");
    assert(got.length == 1);
    assert(got[0] == charEvent('x', Mods(alt: true)));

    // A UTF-8 code point split across chunks assembles.
    got = feedChunks("\xc3", "\xa9"); // é
    assert(got.length == 1);
    assert(got[0] == charEvent('é'));
}

@("ui_app.assembler.controlStringsAreNeverKeys")
@safe
unittest
{
    // A terminal's late reply — here foot's `XTGETTCAP` answers, measured
    // arriving after a probe had given up — is a DCS, never keystrokes: it
    // is dropped whole, even split across chunks, and the key after it
    // still decodes.
    auto got = feedChunks("\x1bP1+r524742=38\x1b", "\\\x1bP1+r5463\x1b\\j");
    assert(got == [charEvent('j')]);
    // An OSC reply ends at BEL; an APC at ST.
    got = feedChunks("\x1b]11;rgb:2424/2424/2424\x07\x1b_Gi=31;OK\x1b\\k");
    assert(got == [charEvent('k')]);
}

@("ui_app.assembler.altIntroducerIsStillAKey")
@safe
unittest
{
    // `ESC P` with nothing after it within the window is Alt+P, as before:
    // only a burst makes it a string.
    EscapeAssembler a;
    Event[] got;
    a.feed(cast(const(ubyte)[]) "\x1bP", (Event e) { got ~= e; });
    assert(got.length == 0 && a.pending);
    a.flush((Event e) { got ~= e; });
    assert(got == [charEvent('P', Mods(alt: true))]);
}

@("ui_app.assembler.focusReports")
@safe
unittest
{
    import sparkles.input : FocusEvent;

    // Mode 1004's reports through the ring pump's assembler, as the
    // blocking reader decodes them.
    const got = feedChunks("\x1b[O", "\x1b[I");
    assert(got == [Event(FocusEvent(false)), Event(FocusEvent(true))]);
}

@("ui_app.assembler.bracketedPasteIsTextNotKeys")
@safe
unittest
{
    import sparkles.input : PasteEvent;

    // A paste with a newline and an escape-looking byte in it, split across
    // chunks: one paste, its text verbatim, the newline not an Enter.
    const got = feedChunks("\x1b[200~line one\nline", " two\x1b[201", "~q");
    assert(got.length == 2);
    assert(got[0].match!((in PasteEvent p) => p.last && p.text[] == "line one\nline two",
        _ => false));
    assert(got[1] == charEvent('q'));
}

@("ui_app.assembler.aPasteIsNotPending")
@safe
unittest
{
    // A paste waits for its end however long the terminal takes: the pump
    // must not bound the read with the escape deadline and cut it off.
    EscapeAssembler a;
    Event[] got;
    a.feed(cast(const(ubyte)[]) "\x1b[200~partial", (Event e) { got ~= e; });
    assert(!a.pending && got.length == 0);
    a.flush((Event e) { got ~= e; });
    assert(got.length == 0, "a flush does not end a paste");
    a.feed(cast(const(ubyte)[]) " rest\x1b[201~", (Event e) { got ~= e; });
    assert(got.length == 1);
}
