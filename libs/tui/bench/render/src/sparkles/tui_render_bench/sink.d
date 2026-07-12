/++
The reused, growable byte sink every renderer emits into.

It is deliberately $(I not) a file descriptor: a real in-memory buffer forces the
encoding cost (formatting cursor moves, SGR runs) to actually be paid, without a
per-flush syscall polluting the measurement. `reset` clears the length between
frames but keeps capacity — exactly what a renderer's owned output scratch does —
so steady-state rendering allocates nothing. Alongside the bytes it tallies the
diagnostics that explain a byte count: cursor moves and SGR writes.

It is a `char` output range (`put`), so `sparkles.base.term_control`'s
`writeCursor*` writers emit straight into it.
+/
module sparkles.tui_render_bench.sink;

/// A reused output buffer with byte/cursor-move/SGR-write counters.
struct Sink
{
    private
    {
        char[] _buf;
        size_t _len;
    }

    /// Bytes emitted since construction (never reset by `reset`).
    size_t bytesTotal;
    /// `writeCursorTo`/absolute-position emissions since construction.
    uint cursorMoves;
    /// SGR (style) sequences emitted since construction.
    uint sgrWrites;

    /// Clear the current frame's bytes, keeping capacity (zero-alloc steady state).
    void reset() @safe pure nothrow @nogc
    {
        _len = 0;
    }

    /// Reset both the frame buffer and all counters (between whole scenarios).
    void resetAll() @safe pure nothrow @nogc
    {
        _len = 0;
        bytesTotal = 0;
        cursorMoves = 0;
        sgrWrites = 0;
    }

    /// The current frame's emitted bytes.
    const(char)[] frame() const @safe pure nothrow @nogc return => _buf[0 .. _len];

    /// Bytes in the current frame.
    size_t length() const @safe pure nothrow @nogc => _len;

    /// Append one byte.
    void put(char c) @safe nothrow
    {
        ensure(1);
        _buf[_len++] = c;
        bytesTotal++;
    }

    /// Append a byte slice.
    void put(scope const(char)[] s) @safe nothrow
    {
        if (s.length == 0)
            return;
        ensure(s.length);
        _buf[_len .. _len + s.length] = s[];
        _len += s.length;
        bytesTotal += s.length;
    }

    /// Append an unsigned integer in decimal (no allocation).
    void putUint(uint v) @safe nothrow
    {
        char[10] tmp = void;
        size_t i = tmp.length;
        do
        {
            tmp[--i] = cast(char)('0' + (v % 10));
            v /= 10;
        }
        while (v != 0);
        put(tmp[i .. $]);
    }

    private void ensure(size_t extra) @safe nothrow
    {
        if (_len + extra <= _buf.length)
            return;
        auto want = _buf.length ? _buf.length : 4096;
        while (want < _len + extra)
            want *= 2;
        _buf.length = want;
    }
}

@("sink.put.countsAndReuses")
@safe nothrow
unittest
{
    Sink s;
    s.put("ab");
    s.put('c');
    s.putUint(42);
    assert(s.frame == "abc42");
    assert(s.bytesTotal == 5);

    const cap = &s.frame()[0];
    s.reset();
    assert(s.length == 0);
    assert(s.bytesTotal == 5); // total survives a frame reset
    s.put("xy");
    assert(s.frame == "xy");
    assert(&s.frame()[0] is cap); // capacity reused — no realloc
}
