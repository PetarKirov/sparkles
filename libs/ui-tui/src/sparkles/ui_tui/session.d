/**
The terminal session and frame lifecycle behind a named seam (`UIA8`).

The cell target's mirror of `sparkles.ui_raylib.window`: an application should
not have to name `sparkles:tui` to open a terminal, ask how big it is, read
input, or present a frame. This module is that boundary — raw-mode entry and
restore, the surface size, the input source, and the draw.

$(B Deliberately thin,) for the same reason the raylib window seam is: it moves
calls behind names and invents no policy. The
$(LINK2 ../../../../docs/research/window-system-integration/index.md, window-system research)
is designing a replacement for the event loop, and a seam that guessed at a
richer abstraction now would be re-cut then.

$(B What it does not yet own:) the $(REF Grid, sparkles,tui,cell) itself. An
application that still paints cells by hand needs one, and hue does — though
less than a raw grep suggests: $(B eight) production paint sites — two
`fillRect` and two `clearTo` (pane and page backgrounds), one `fill` and two
`putText` (a status bar and the pane divider), and one cell-style write (the
selection tint) — beside 16 `paintGrid` calls.

Most other `g[x, y]` uses are $(I reads), and they are not violations: a dozen
in unittests, which is exactly what a test verifying painting must do, plus one
loop in `twoslash_tui` that serializes the surface to HTML and belongs beside
`sparkles.ui.interp.html` rather than here.

Moving the grid in here is therefore the same change as widget-ising those eight
sites (`UIA2`), so it waits for it; until then `session.grid` hands the surface
out deliberately rather than by omission.
*/
module sparkles.ui_tui.session;

import sparkles.tui : Grid, PosixEvents, Terminal, TerminalOptions;
import sparkles.base.term_caps : TermSize;

import sparkles.input : Event;

/**
What the caller wants of a terminal.

Mirrors `TerminalOptions` rather than re-inventing it — the fields are the
terminal's real capabilities, and renaming them would buy nothing.
*/
struct TerminalRequest
{
    bool altScreen = true;  /// use the alternate screen buffer
    bool hideCursor = true; /// hide the cursor for the session
    bool mouse = true;      /// SGR mouse reporting (press + drag + wheel)
    /// Any-event tracking (1003) rather than drag-only (1002), so bare motion
    /// reports too — what a hover affordance needs, at one event per move.
    bool motion;
}

/**
An open terminal session. Construct with $(LREF open); it restores on scope
exit.

Non-copyable: two handles to one terminal would let a stale copy restore it
out from under the live one.
*/
struct TerminalSession
{
    private Terminal term;
    private PosixEvents events;
    private bool opened;

    /// The cell surface this session presents. Public because an application
    /// painting chrome by hand still needs it — see the module note.
    Grid grid;

    @disable this(this);

    /// Enters raw mode and starts the input reader.
    static TerminalSession open(in TerminalRequest r) @system
    {
        TerminalSession s;
        s.term = Terminal.open(TerminalOptions(
            altScreen: r.altScreen, hideCursor: r.hideCursor,
            mouse: r.mouse, motion: r.motion));
        if (!s.term.active)
            return s; // `active` stays false; the caller bails out
        s.events = PosixEvents.start();
        s.opened = true;
        return s;
    }

    ~this() @system
    {
        if (opened)
            term.close();
    }

    /// `false` when the terminal could not be put into raw mode — the caller's
    /// cue to fall back rather than paint into nothing.
    bool active() const @safe pure @nogc => term.active;

    /// The surface size in cells.
    TermSize size() @system => term.size();

    /// Resizes the surface to the terminal's current size and reports it, so a
    /// caller never holds a grid that disagrees with the screen.
    TermSize resizeToTerminal() @system
    {
        const sz = size();
        grid.resize(sz.width, sz.height);
        return sz;
    }

    /// Presents the surface — the retained diff, so only changed cells go out.
    void present() @system => term.draw(grid);

    /**
    Writes a control sequence straight to the terminal, outside the cell diff.

    For the things that are not cells: OSC 52 clipboard, OSC 22 pointer shape.
    The retained diff must not see them — they address the terminal itself, not
    the surface.
    */
    void writeOutOfBand(scope const(char)[] seq) @system => term.writeRaw(seq);

    /// `true` if input is available within `ms` — for a caller that wants to
    /// wait on something else (a background refresh) without dropping input.
    bool ready(int ms) @system
    {
        import core.time : msecs;

        return events.ready(ms.msecs);
    }

    /// The next input event, or `EndOfInput` when the stream closes.
    /// `timeoutMs < 0` blocks.
    Event next(int timeoutMs = -1) @system
    {
        import core.time : msecs;

        return timeoutMs < 0 ? events.next() : events.next(timeoutMs.msecs);
    }

    /// The declared input capabilities of this target (`TGT5`/`IXB10`): a
    /// terminal has hover and one whole-cell pointer.
    static auto capabilities() @safe pure nothrow @nogc => PosixEvents.capabilities;
}
