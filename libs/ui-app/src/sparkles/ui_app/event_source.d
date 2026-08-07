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

import sparkles.input : Event, EndOfInput, Key, ResizeEvent, charEvent, keyEvent;
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
    bool pending() const @safe pure nothrow @nogc => _state != State.idle;

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
        }
        _state = State.idle;
        _len = 0;
    }

private:
    enum State : ubyte
    {
        idle,
        escape, /// after ESC: accumulating intro + params until the final byte
        utf8,   /// accumulating continuation bytes
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
                    sink(decodeEscape(_buf[0 .. _len]));
                    _state = State.idle;
                    _len = 0;
                }
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
    uint _need;
    dchar _cp;
}

// ── the fiber pumps ─────────────────────────────────────────────────────────

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.event_horizon.channel : Channel;
import sparkles.event_horizon.io : FileHandle, read;
import sparkles.event_horizon.sched : Sched;
import sparkles.event_horizon.scope_ : withDeadline;
import sparkles.event_horizon.signals : SignalFd;

/// The channel type the loop arms share.
alias EventChannel = Channel!(Event, 64);

/**
The input pump (spawned as a daemon fiber): ring-reads `fd` in chunks,
assembles, and puts events. A pending partial sequence bounds the next
read with `escapeTimeoutMs`; expiry flushes it (a bare `ESC` becomes the
escape key). On EOF or a read error, one `EndOfInput` and the pump ends.
*/
void pumpTerminalInput(ref Sched sched, ref EventChannel events, int fd,
    int escapeTimeoutMs = 40)
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

    for (;;)
    {
        SmallBuffer!(ubyte, 128) buf;
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
