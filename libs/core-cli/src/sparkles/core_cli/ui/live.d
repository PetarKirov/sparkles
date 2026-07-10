/++
A live region: a block of lines at the bottom of the normal scrollback flow that
is repainted in place (no alternate screen), with a *static* channel for lines
that graduate into scrollback above it — the log-update pattern (Ink/Bubble
Tea/Mosaic) per `docs/specs/core-cli/tui-components` §5.

Every repaint is framed in DEC 2026 synchronized-output markers (no tearing),
each frame line is truncated to the terminal width (a wrapped line would break
the cursor-up arithmetic), and the region re-reads the width every update so
resizes are picked up. On a non-interactive sink (piped output) `update` is a
no-op and `printAbove` degrades to plain appended lines, so redirected runs see
only the permanent output.

The region writes through an injected sink (testable without a terminal); use
$(LREF stdoutLiveRegion) for the real thing, and `scope (exit) region.finish();`
so a thrown exception never leaves the cursor hidden.
+/
module sparkles.core_cli.ui.live;

import sparkles.base.term_control : CtlSeq, writeCursorUp;

/// See the module documentation. Not copyable — the region owns cursor state.
struct LiveRegion
{
    /// Byte sink; must reach the terminal unbuffered (or flush per call).
    alias Sink = void delegate(scope const(char)[] bytes);
    /// Terminal width provider, re-read every repaint (`0` = unknown, no clamp).
    alias WidthProvider = ushort delegate();

    private
    {
        Sink _sink;
        WidthProvider _width;
        bool _interactive;
        bool _cursorHidden;
        bool _finished;
        size_t _prevRows;
        string[] _frame;
    }

    @disable this(this);

    /// `interactive: false` (non-tty) keeps only the `printAbove` channel.
    this(Sink sink, WidthProvider width, bool interactive)
    in (sink !is null && width !is null)
    {
        _sink = sink;
        _width = width;
        _interactive = interactive;
    }

    /// Whether frames are actually painted (false on a non-tty sink).
    bool interactive() const @safe pure nothrow @nogc => _interactive;

    /// Repaint the live block as `lines` (each clamped to the terminal width).
    /// No-op when non-interactive.
    void update(string[] lines)
    {
        if (_interactive)
        {
            _sink(CtlSeq.syncBegin);
            if (!_cursorHidden)
            {
                _sink(CtlSeq.hideCursor);
                _cursorHidden = true;
            }
            moveToFrameTop();
            paintLines(lines);
            _sink(CtlSeq.eraseBelow); // clear leftover rows when the frame shrank
            _sink(CtlSeq.syncEnd);
            _prevRows = lines.length;
        }
        _frame = lines.dup;
    }

    /// Emit a permanent line into the scrollback above the live block (the
    /// completed-task channel). Non-interactive: just appends the line.
    void printAbove(scope const(char)[] line)
    {
        if (!_interactive)
        {
            _sink(line);
            _sink("\n");
            return;
        }
        _sink(CtlSeq.syncBegin);
        moveToFrameTop();
        _sink(CtlSeq.eraseBelow);
        _sink(line);
        _sink("\n");
        paintLines(_frame); // the block itself is unchanged, just pushed down
        _sink(CtlSeq.syncEnd);
        _prevRows = _frame.length;
    }

    /// End the region: restore the cursor and either keep the last frame as
    /// permanent output (default) or erase it. Idempotent; call it from a
    /// `scope (exit)` so exceptions can't leave the cursor hidden.
    void finish(bool keepFrame = true)
    {
        if (_finished || !_interactive)
        {
            _finished = true;
            return;
        }
        if (!keepFrame)
        {
            moveToFrameTop();
            _sink(CtlSeq.eraseBelow);
            _prevRows = 0;
        }
        if (_cursorHidden)
        {
            _sink(CtlSeq.showCursor);
            _cursorHidden = false;
        }
        _finished = true;
    }

    ~this()
    {
        // Best-effort restore if the owner forgot `finish` (or threw before it).
        if (_sink !is null && !_finished)
            finish();
    }

    private void moveToFrameTop()
    {
        import sparkles.base.smallbuffer : SmallBuffer;

        SmallBuffer!(char, 16) b;
        writeCursorUp(b, cast(uint) _prevRows);
        if (b.length)
            _sink(b[]);
        _sink(CtlSeq.carriageReturn);
    }

    private void paintLines(string[] lines)
    {
        import sparkles.base.text.width : truncateField;
        import std.array : appender;

        const w = _width();
        foreach (line; lines)
        {
            if (w > 0)
            {
                auto clamped = appender!string;
                truncateField(clamped, line, w);
                _sink(clamped[]);
            }
            else
                _sink(line);
            _sink(CtlSeq.eraseToEnd);
            _sink("\n");
        }
    }
}

/// A `LiveRegion` on stdout: interactive iff stdout is a terminal (each write is
/// flushed so frames appear atomically), width from `terminalSize()` per repaint.
LiveRegion stdoutLiveRegion()
{
    import std.stdio : stdout;
    import sparkles.core_cli.term_caps : isTerminal, terminalSize;

    return LiveRegion(
        (scope const(char)[] bytes) { stdout.rawWrite(bytes); stdout.flush(); },
        () => terminalSize().width,
        isTerminal(),
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    private struct Recorder
    {
        string bytes;
        LiveRegion.Sink sink() return
            => (scope const(char)[] b) { bytes ~= b; };
    }
}

@("live.update.paintsAndRepaints")
@system
unittest
{
    Recorder rec;
    auto region = LiveRegion(rec.sink, () => ushort(80), true);

    region.update(["one", "two"]);
    // First frame: sync begin, hide cursor, (no cursor-up), both rows, shrink-
    // erase, sync end.
    assert(rec.bytes ==
        "\x1b[?2026h\x1b[?25l\r" ~
        "one\x1b[0K\ntwo\x1b[0K\n" ~
        "\x1b[0J\x1b[?2026l");

    rec.bytes = null;
    region.update(["three"]);
    // Second frame: cursor up over the 2 previous rows; the erase-below clears
    // the row the shrunken frame no longer covers.
    assert(rec.bytes ==
        "\x1b[?2026h\x1b[2A\r" ~
        "three\x1b[0K\n" ~
        "\x1b[0J\x1b[?2026l");

    region.finish();
}

@("live.printAbove.graduatesLineAndRepaintsFrame")
@system
unittest
{
    Recorder rec;
    auto region = LiveRegion(rec.sink, () => ushort(80), true);
    region.update(["working"]);

    rec.bytes = null;
    region.printAbove("✔ step done");
    assert(rec.bytes ==
        "\x1b[?2026h\x1b[1A\r\x1b[0J" ~
        "✔ step done\n" ~
        "working\x1b[0K\n" ~
        "\x1b[?2026l");

    region.finish();
}

@("live.finish.restoresCursorAndCanErase")
@system
unittest
{
    Recorder rec;
    {
        auto region = LiveRegion(rec.sink, () => ushort(80), true);
        region.update(["gone"]);
        rec.bytes = null;
        region.finish(keepFrame: false);
        assert(rec.bytes == "\x1b[1A\r\x1b[0J\x1b[?25h");
        rec.bytes = null;
    } // destructor after finish: no further bytes
    assert(rec.bytes.length == 0);
}

@("live.destructor.restoresWhenFinishForgotten")
@system
unittest
{
    Recorder rec;
    {
        auto region = LiveRegion(rec.sink, () => ushort(80), true);
        region.update(["x"]);
        rec.bytes = null;
    }
    // The dtor keeps the frame but shows the cursor again.
    assert(rec.bytes == "\x1b[?25h");
}

@("live.nonInteractive.appendOnly")
@system
unittest
{
    Recorder rec;
    auto region = LiveRegion(rec.sink, () => ushort(0), false);

    region.update(["spinner ⠋"]); // frames are skipped entirely
    assert(rec.bytes.length == 0);

    region.printAbove("✔ step done");
    assert(rec.bytes == "✔ step done\n"); // no escapes on a piped sink

    region.finish();
    assert(rec.bytes == "✔ step done\n");
}

@("live.update.clampsToWidth")
@system
unittest
{
    Recorder rec;
    auto region = LiveRegion(rec.sink, () => ushort(6), true);

    region.update(["a very long status line"]);
    // 5 cells + '…' = 6 -> the row can never wrap, keeping cursor-up accurate.
    assert(rec.bytes ==
        "\x1b[?2026h\x1b[?25l\r" ~
        "a ver…\x1b[0K\n" ~
        "\x1b[0J\x1b[?2026l");

    region.finish();
}
