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

import sparkles.tui : Grid, ImagePlacement, PosixEvents, Terminal, TerminalOptions;
import sparkles.base.term_caps : detectTermCaps, ImageProtocol, TermCaps, TermSize;
import sparkles.base.term_replies : applyReplies, TerminalReplies;
import sparkles.ui.geometry : Size;
import sparkles.base.term_color : ColorDepth;
import sparkles.ui.tokens : TargetCapabilities, terminalCapabilities;

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
    /// Ask the terminal what it can do (`CAP3`) before the first frame: the
    /// query battery, fenced by DA1. Off by default: see
    /// $(REF Terminal.probe, sparkles,tui,terminal).
    bool probe;
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

    /// What this terminal declares (`CAP1`), fixed at $(LREF open) — pass it
    /// to `paintGrid` so the frame is painted for this terminal rather than
    /// for the grid's full reach. See $(LREF sessionCapabilities).
    TargetCapabilities target;

    /// The frame's OSC 8 URI table, indexed from 1 by a cell's `linkId` — set
    /// it while painting and the terminal itself makes those cells clickable.
    /// Public for the same reason `grid` is, and empty by default, so a
    /// surface with no hyperlinks emits no hyperlink sequences.
    const(char)[][] links;

    /// The frame's kitty image placements (`IMG5`), drawn over the cells by
    /// $(LREF present) — set while painting, by a canvas that knows the
    /// terminal draws kitty images. Empty by default.
    ImagePlacement[] placements;

    /// What the terminal answered, when the session asked (`TerminalRequest.probe`)
    /// — every row of the battery, the input modes it does not apply included.
    TerminalReplies replies;

    // Input that arrived during the probe, for whichever reader goes first.
    private ubyte[] typedAhead;

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
        auto caps = detectTermCaps();
        if (r.probe)
        {
            // The answers' output rows — depth, sync, graphemes, scheme
            // reports, images, the cell size — onto the environment's
            // snapshot, by the one mapping presets use too. The image
            // protocol is the one the terminal will actually draw: a sixel
            // answer it cannot size is `none`.
            s.replies = s.term.probe();
            applyReplies(caps, s.replies);
            caps.images = s.term.imageProtocol;
            const px = s.term.cellPixels();
            caps.cellPixelSize = px.width != 0 && px.height != 0;
            s.typedAhead = s.term.takeTypedAhead();
        }
        s.target = sessionCapabilities(caps);
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

    /// Presents the surface — the retained diff, so only changed cells go out,
    /// and the frame's image placements over them.
    void present() @system => term.draw(grid, links, placements);

    /// The cell size in pixels, where the terminal reports it; `0`s where it
    /// does not.
    Size cellPixels() @system
    {
        const c = term.cellPixels();
        return Size(c.width, c.height);
    }

    /// The input that arrived during the probe, for a caller reading the
    /// terminal itself; $(LREF next) replays whatever this did not take.
    ubyte[] takeTypedAhead() @safe pure
    {
        auto t = typedAhead;
        typedAhead = null;
        return t;
    }

    /// The color depth the diff folds to — normally `target.colorDepth`, and
    /// narrower when a host previews a smaller profile. A change repaints the
    /// next frame in full, so every cell is folded the same way.
    void colorDepth(ColorDepth d) @system => term.colorDepth(d);

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

        replayTypedAhead();
        return events.ready(ms.msecs);
    }

    /// The next input event, or `EndOfInput` when the stream closes.
    /// `timeoutMs < 0` blocks.
    Event next(int timeoutMs = -1) @system
    {
        import core.time : msecs;

        replayTypedAhead();
        return timeoutMs < 0 ? events.next() : events.next(timeoutMs.msecs);
    }

    private void replayTypedAhead() @safe nothrow
    {
        if (typedAhead.length)
        {
            events.unread(typedAhead);
            typedAhead = null;
        }
    }

    /// The declared input capabilities of this target (`TGT5`/`IXB10`): a
    /// terminal has hover and one whole-cell pointer.
    static auto capabilities() @safe pure nothrow @nogc => PosixEvents.capabilities;
}

/**
A live session's declaration (`CAP1`): the environment's answers from `t`, with
two standing adjustments that are debts, not policy.

$(LIST
    * $(B Input) is $(LREF TerminalSession.capabilities) — the same answer the
        host already reports, so the two cannot disagree — until the session
        records the modes it negotiates and `fromTerminal` derives the axes
        (design-system M7, `CAP3`).
    * $(B `hyperlinks` and `extendedUnderline`) stay on when color is: the
        terminal backend has always emitted OSC 8 and SGR 4:3 without asking,
        and a declaration that turned them off before a probe exists would
        regress every capable terminal to fix the incapable ones. Each goes
        when its M7 probe row lands.
)

Everything the environment does answer — `colorDepth`, `unicode` — is taken as
is: a non-UTF-8 locale now gets ASCII chrome (`CAP8`).
*/
TargetCapabilities sessionCapabilities(in TermCaps t) @safe pure nothrow @nogc
{
    auto c = terminalCapabilities(t);
    c.input = TerminalSession.capabilities;
    // What was negotiated, and nothing more: the decoder can read focus
    // reports, but only a terminal asked for them sends any.
    c.input.focusEvents = t.focusReporting;
    c.input.pasteEvents = t.bracketedPaste;
    c.hyperlinks = c.hyperlinks || t.colors;
    c.extendedUnderline = c.extendedUnderline || t.colors;
    return c;
}

@("ui_tui.session.sessionCapabilities")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.term_color : ColorDepth;

    TermCaps color;
    color.tty = true;
    color.colorDepth = ColorDepth.ansi256;
    color.unicode = true;
    const c = sessionCapabilities(color);
    assert(c.colorDepth == ColorDepth.ansi256 && c.unicode);
    assert(c.hyperlinks && c.extendedUnderline, "the unprobed rows keep today's output");
    assert(c.input == TerminalSession.capabilities);

    // No color, no locale: nothing is assumed, and the chrome goes ASCII.
    TermCaps dumb;
    dumb.tty = true;
    const d = sessionCapabilities(dumb);
    assert(!d.unicode && !d.hyperlinks && !d.extendedUnderline);
    assert(d.colorDepth == ColorDepth.none);
}

@("ui_tui.session.declaresOnlyWhatWasNegotiated")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.term_color : ColorDepth;

    // The decoder can read focus reports and a paste, but a terminal sends
    // neither unless asked: nothing negotiated, nothing declared.
    TermCaps t;
    t.tty = true;
    t.colorDepth = ColorDepth.ansi256;
    t.unicode = true;
    auto c = sessionCapabilities(t);
    assert(!c.input.focusEvents && !c.input.pasteEvents);
    // Focus reports negotiated: declared.
    t.focusReporting = true;
    c = sessionCapabilities(t);
    assert(c.input.focusEvents && !c.input.pasteEvents);
}
