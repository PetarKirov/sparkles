/++
Live progress rendering: a spinner frame set, a one-line
`spinner [done/total] (elapsed)` component, and the ANSI cursor / erase-line
control sequences a redraw-in-place caller needs.

Everything here is a pure producer — `ProgressLine` renders into any output
range (so a `@nogc` `SmallBuffer` works and the result is unit-testable), and
`AnsiControl` just names the escape strings. Doing the actual terminal write,
tty gating, and redraw cadence is left to the caller (see the test-runner's
benchmark progress, which frames a `ProgressLine` with
`AnsiControl.carriageReturn` + `AnsiControl.eraseLine`).

Base `sparkles.base.term_style` covers SGR styling; the cursor / erase-line
sequences below are the terminal-control piece it deliberately omits.
+/
module sparkles.core_cli.ui.progress;

import core.time : Duration;

/// Terminal control escape sequences for a redraw-in-place progress display.
/// (SGR colour/attribute escapes live in `sparkles.base.term_style`.)
enum AnsiControl : string
{
    csi = "\x1b[",             /// Control Sequence Introducer.
    eraseLine = "\x1b[2K",     /// Erase the entire current line.
    hideCursor = "\x1b[?25l",  /// Hide the cursor.
    showCursor = "\x1b[?25h",  /// Show the cursor.
    carriageReturn = "\r",     /// Return to column 0 (redraw the current line).
}

/// The spinner glyph for animation step `i` (cycles every 10 frames).
string spinnerFrame(size_t i) @safe pure nothrow @nogc
{
    static immutable string[10] frames = [
        "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏",
    ];
    return frames[i % frames.length];
}

@("progress.spinnerFrame.cycles")
@safe pure nothrow @nogc
unittest
{
    assert(spinnerFrame(0) == "⠋");
    assert(spinnerFrame(2) == "⠹");
    assert(spinnerFrame(10) == "⠋"); // wraps
}

/// A single progress line: `⠹ 12/40` — a spinner frame, then `done`
/// right-justified in `total`'s digit width over `/total`, plus a trailing
/// ` (elapsed)` when `elapsed > 0`. Dim-styled when `colored`. Renders into any
/// output range via `toString`, so it stays `@nogc` for a `SmallBuffer` writer
/// and is unit-testable without a terminal. The caller supplies any trailing
/// label and the carriage-return / erase-line framing.
struct ProgressLine
{
    size_t frame;   /// Spinner animation step.
    size_t done;    /// Completed units.
    size_t total;   /// Total units.
    bool colored = false;             /// Dim-style the line when true.
    Duration elapsed = Duration.zero; /// Shown as ` (…)` when positive.

    void toString(Writer)(ref Writer w) const
    {
        import std.range.primitives : put;
        import sparkles.base.smallbuffer : SmallBuffer;
        import sparkles.base.term_style : Style;
        import sparkles.base.text.width : Align, alignField;
        import sparkles.base.text.writers : writeDuration, writeEscapeSeq, writeInteger;

        if (colored)
            writeEscapeSeq(w, Style.dim[0]);

        put(w, spinnerFrame(frame));
        put(w, ' ');

        SmallBuffer!(char, 20) doneBuf;
        writeInteger(doneBuf, done);

        SmallBuffer!(char, 20) totalBuf;
        writeInteger(totalBuf, total);

        alignField(w, doneBuf[], totalBuf.length, Align.right);
        put(w, '/');
        put(w, totalBuf[]);

        if (elapsed > Duration.zero)
        {
            put(w, " (");
            writeDuration(w, elapsed);
            put(w, ')');
        }

        if (colored)
            writeEscapeSeq(w, Style.dim[1]);
    }
}

/// Plain, equal-width counter: no padding, no elapsed.
@("progress.ProgressLine.plain")
@safe unittest
{
    import sparkles.base.smallbuffer : checkToString;

    checkToString(ProgressLine(2, 12, 40), "⠹ 12/40");
}

/// `done` is right-justified in `total`'s digit width (space-padded).
@("progress.ProgressLine.rightJustified")
@safe unittest
{
    import sparkles.base.smallbuffer : checkToString;

    checkToString(ProgressLine(0, 5, 40), "⠋  5/40");
}

/// A positive `elapsed` appends ` (…)`; `colored` wraps the line in dim SGR.
@("progress.ProgressLine.elapsedAndColored")
@safe unittest
{
    import core.time : msecs;
    import sparkles.base.smallbuffer : checkToString;
    import sparkles.base.term_style : Style;
    import sparkles.base.text.writers : writeEscapeSeq;

    checkToString(ProgressLine(0, 1, 2, false, 1500.msecs), "⠋ 1/2 (1.5s)");

    import sparkles.base.smallbuffer : SmallBuffer;
    SmallBuffer!(char, 32) on, off;
    writeEscapeSeq(on, Style.dim[0]);
    writeEscapeSeq(off, Style.dim[1]);
    checkToString(ProgressLine(2, 12, 40, true), on[] ~ "⠹ 12/40" ~ off[]);
}
