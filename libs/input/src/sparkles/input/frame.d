/**
One frame's input, folded from an event stream (`INP17`).

A polling host reads input in many places — "is the left button down here",
"where is the pointer", "did the wheel move" — each a separate question. An
event stream cannot be asked twenty-three times: it is drained once. This module
is the fold between the two shapes. $(LREF InputFrame) is the flags those sites
want; $(LREF foldFrame) derives them from a sequence of events.

$(B It is a pure function of a sequence,) which is the point. A host's frame
loop is entangled with a live window and cannot be unit-tested; the fold has no
window in it, so feeding it a scripted event list is how a click-then-drag, or a
press that leaves its target before release, becomes a test.

$(B Unit-agnostic.) Positions pass through in whatever unit the producer emits —
a host polling in pixels gets pixels back, one working in cells gets cells.
$(LREF pointerFor) converts when a consumer needs cells.

Levels versus edges: `pressed`/`released` are true only on the frame they occur,
while `down` is carried across frames by the `prior` argument, because a stream
reports transitions and a caller asking "is it held" wants the state.
*/
module sparkles.input.frame;

import sparkles.input.capability : InputCapabilities;
import sparkles.input.events : Event, GestureEvent, Gesture, Key, KeyAction,
    KeyEvent, match, Mods, PointerAction, PointerButton, PointerEvent, Point,
    WheelEvent;
import sparkles.input.gesture : PointF;

@safe:

/// The most simultaneously-held printable keys $(LREF InputFrame) tracks.
enum size_t maxHeldChars = 8;

/// One button's edges and level within a frame.
struct ButtonState
{
    bool pressed;  /// went down this frame
    bool released; /// came up this frame
    bool down;     /// is held (level, carried across frames)
}

/**
The pointer / wheel / gesture / modifier state of one frame.

Every $(REF PointerButton, sparkles,input,events) is tracked, not just the
primary one: a diagram pans on the middle button and a document set navigates on
the thumb buttons, and neither should have to re-fold the stream to find out.
*/
struct InputFrame
{
    /// Last reported pointer position, in the producer's own unit.
    PointF pos;
    /// Modifier level as of the last event that carried one.
    Mods mods;
    /// Per-button edges and level, indexed by `PointerButton`.
    ButtonState[PointerButton.max + 1] buttons;
    /// Rows to scroll — already in cells (`INP12`), accumulated over the frame.
    int wheelCells;
    /// Columns to scroll — a horizontal wheel/trackpad axis, plus a
    /// Shift-modified vertical notch (the universal "scroll sideways"
    /// spelling), accumulated the same way.
    int wheelCellsX;

    // Resolved touch gestures. A tap arrives as press+release in the button
    // fields above; these are the two that have no other spelling.
    bool longPress;
    float pinch = 0; /// scale ratio; 0 = no pinch this frame
    PointF anchor;   /// where the gesture began, not where it is now

    // Held keys, tracked only where the target reports releases — see
    // `foldFrame`. A named key is a flag; printable keys are a small set.
    private bool[Key.max + 1] _namedHeld;
    private dchar[maxHeldChars] _charsHeld = 0;
    private ubyte _charsHeldCount;

    /// The primary button's edges and level — the common case, named.
    bool leftPressed() const pure nothrow @nogc => buttons[PointerButton.left].pressed;
    /// ditto
    bool leftReleased() const pure nothrow @nogc => buttons[PointerButton.left].released;
    /// ditto
    bool leftDown() const pure nothrow @nogc => buttons[PointerButton.left].down;

    /// The thumb buttons, which navigate a document set rather than click.
    bool backPressed() const pure nothrow @nogc => buttons[PointerButton.back].pressed;
    /// ditto
    bool forwardPressed() const pure nothrow @nogc => buttons[PointerButton.forward].pressed;

    /**
    Whether `k` is currently held.

    Always `false` where the target does not report key releases
    (`InputCapabilities.keyRelease`), because a press with no matching release
    would latch forever — a held-key affordance must ask the capability and
    offer another route, not read a level that cannot be maintained.
    */
    bool keyHeld(Key k) const pure nothrow @nogc
        => k <= Key.max && _namedHeld[k];

    /// ditto
    bool charHeld(dchar c) const pure nothrow @nogc
    {
        foreach (i; 0 .. _charsHeldCount)
            if (_charsHeld[i] == c)
                return true;
        return false;
    }

    /// How many printable keys are held.
    size_t heldCharCount() const pure nothrow @nogc => _charsHeldCount;

    private void holdChar(dchar c) pure nothrow @nogc
    {
        if (charHeld(c) || _charsHeldCount >= maxHeldChars)
            return;
        _charsHeld[_charsHeldCount++] = c;
    }

    private void releaseChar(dchar c) pure nothrow @nogc
    {
        foreach (i; 0 .. _charsHeldCount)
            if (_charsHeld[i] == c)
            {
                _charsHeld[i] = _charsHeld[_charsHeldCount - 1];
                _charsHeld[--_charsHeldCount] = 0;
                return;
            }
    }
}

/**
Folds `events` into one frame's state, carrying levels from `prior`.

Pointer position tracks the last event that carried one — including the release,
so a site reading `pos` after `released` sees where the release landed rather
than a stale motion.

Params:
    events = this frame's drained events
    prior = the previous frame, for the levels a stream does not repeat
    caps = the producing target's declared capabilities. Held keys are tracked
        only when `caps.keyRelease`; see `InputFrame.keyHeld`.
*/
InputFrame foldFrame(R)(R events, in InputFrame prior = InputFrame.init,
    in InputCapabilities caps = InputCapabilities.init)
{
    InputFrame f;
    f.pos = prior.pos;
    f.anchor = prior.anchor;
    f.mods = prior.mods;
    // Levels survive; edges do not.
    foreach (i, ref b; f.buttons)
        b.down = prior.buttons[i].down;
    if (caps.keyRelease)
    {
        f._namedHeld = prior._namedHeld;
        f._charsHeld = prior._charsHeld;
        f._charsHeldCount = prior._charsHeldCount;
    }

    foreach (e; events)
        e.match!(
            (in PointerEvent p) {
                f.pos = PointF(p.pos.x, p.pos.y);
                f.mods = p.mods;
                if (p.button <= PointerButton.max)
                {
                    auto b = &f.buttons[p.button];
                    if (p.action == PointerAction.press)
                    {
                        b.pressed = true;
                        b.down = true;
                    }
                    else if (p.action == PointerAction.release)
                    {
                        b.released = true;
                        b.down = false;
                    }
                }
            },
            (in WheelEvent w) {
                // Already cells (INP12) — accumulate, never re-multiply.
                // Shift turns a vertical notch sideways (the universal
                // spelling on mice without a horizontal axis).
                if (w.mods.shift)
                    f.wheelCellsX += w.dy;
                else
                    f.wheelCells += w.dy;
                f.wheelCellsX += w.dx;
                f.pos = PointF(w.pos.x, w.pos.y);
                f.mods = w.mods;
            },
            (in GestureEvent g) {
                f.anchor = PointF(g.pos.x, g.pos.y);
                if (g.gesture == Gesture.longPress)
                    f.longPress = true;
                else
                    f.pinch = g.scale;
            },
            (in KeyEvent k) {
                f.mods = k.mods;
                if (!caps.keyRelease)
                    return; // a press with no release would latch forever
                const held = k.action != KeyAction.release;
                if (k.key == Key.char_)
                {
                    if (held)
                        f.holdChar(k.ch);
                    else
                        f.releaseChar(k.ch);
                }
                else if (k.key <= Key.max)
                    f._namedHeld[k.key] = held;
            },
            (in _) {},
        );
    return f;
}

/**
The frame's pointer state as the single event a container consumes, in CELLS.

A container — a dock, a pane — is written against an event stream, but a polling
host has a frame. The gap is exactly this projection: the fold's level and edge
flags pick one action (a press and a release in the same frame resolve to the
press, because the press is what starts a gesture the release then completes),
and the position divides down into the container's unit.

Pure, so the wiring a GPU host cannot unit-test is checkable here instead.
*/
PointerEvent pointerFor(in InputFrame f, int cellW, int cellH)
    pure nothrow @nogc
{
    const action = f.leftPressed ? PointerAction.press
        : f.leftReleased ? PointerAction.release
            : f.leftDown ? PointerAction.drag
                : PointerAction.move;
    return PointerEvent(action: action, button: PointerButton.left,
        pos: Point(cast(int)(f.pos.x / (cellW < 1 ? 1 : cellW)),
            cast(int)(f.pos.y / (cellH < 1 ? 1 : cellH))),
        mods: f.mods);
}

// ---------------------------------------------------------------------------
// Tests — the input oracle a live host cannot provide for itself.
// ---------------------------------------------------------------------------

version (unittest)
{
    private Event press(int x, int y, PointerButton b = PointerButton.left,
        Mods m = Mods.init)
        => Event(PointerEvent(action: PointerAction.press, button: b,
            pos: Point(x, y), mods: m));

    private Event release(int x, int y, PointerButton b = PointerButton.left)
        => Event(PointerEvent(action: PointerAction.release, button: b,
            pos: Point(x, y)));

    private Event drag(int x, int y)
        => Event(PointerEvent(action: PointerAction.drag,
            button: PointerButton.left, pos: Point(x, y)));

    private enum withReleases = InputCapabilities(keyRelease: true);
}

@("input.frame.edgesAreOneFrame")
@safe
unittest
{
    // A press is an edge and a level; the NEXT frame keeps the level only.
    const down = foldFrame([press(10, 20)]);
    assert(down.leftPressed && down.leftDown && !down.leftReleased);
    assert(down.pos == PointF(10, 20));

    const held = foldFrame([drag(12, 22)], down);
    assert(!held.leftPressed, "an edge must not survive its frame");
    assert(held.leftDown, "the level must survive");
    assert(held.pos == PointF(12, 22));

    const up = foldFrame([release(14, 24)], held);
    assert(up.leftReleased && !up.leftDown);
    // The release position is what a site reads after it — not a stale motion.
    assert(up.pos == PointF(14, 24));

    const idle = foldFrame(Event[].init, up);
    assert(!idle.leftReleased && !idle.leftDown);
    assert(idle.pos == PointF(14, 24), "position persists when nothing moves");
}

@("input.frame.pressAndReleaseInOneFrame")
@safe
unittest
{
    // A tap arrives as both in one drain — the touch recogniser's spelling.
    // Both edges must be visible, and the level must end low: a site that only
    // checked `leftDown` would miss the tap entirely.
    const tap = foldFrame([press(5, 5), release(5, 5)]);
    assert(tap.leftPressed && tap.leftReleased && !tap.leftDown);
}

@("input.frame.everyButtonIsTracked")
@safe
unittest
{
    // Not just the primary one: a middle-drag pans, and the thumb buttons
    // navigate. Each keeps its own edges and level.
    auto f = foldFrame([
        press(1, 1, PointerButton.middle),
        press(1, 1, PointerButton.right),
        press(0, 0, PointerButton.back),
    ]);
    assert(f.buttons[PointerButton.middle].down);
    assert(f.buttons[PointerButton.right].down);
    assert(f.backPressed && !f.forwardPressed);
    assert(!f.leftDown && !f.leftPressed, "an unrelated button is not a click");

    // The middle button's level survives a frame the left button acts in.
    const next = foldFrame([press(2, 2)], f);
    assert(next.buttons[PointerButton.middle].down && next.leftDown);
    assert(!next.buttons[PointerButton.middle].pressed, "edges do not survive");
}

@("input.frame.wheelAccumulatesInCells")
@safe
unittest
{
    // INP12: the producer already multiplied, so the fold sums and never
    // scales. Two notches in one frame is one scroll of six.
    const w = foldFrame([
        Event(WheelEvent(dy: 3, pos: Point(1, 1))),
        Event(WheelEvent(dy: 3, pos: Point(1, 1))),
    ]);
    assert(w.wheelCells == 6);

    // The horizontal channel: a dx axis accumulates directly; Shift turns
    // a vertical notch sideways instead of scrolling.
    auto hw = foldFrame([
        Event(WheelEvent(dx: 2, dy: 0)),
        Event(WheelEvent(dy: 3, mods: Mods(shift: true))),
    ]);
    assert(hw.wheelCells == 0);
    assert(hw.wheelCellsX == 5);

    // Opposite directions cancel rather than fighting.
    const z = foldFrame([Event(WheelEvent(dy: 3)), Event(WheelEvent(dy: -3))]);
    assert(z.wheelCells == 0);
    // And a frame with no wheel reports none, rather than inheriting.
    assert(foldFrame(Event[].init, w).wheelCells == 0);
}

@("input.frame.modifiersAreALevel")
@safe
unittest
{
    // A modifier-drag reads the level, and the level is whatever the last
    // event carrying one said — so it survives a frame with no input.
    const f = foldFrame([press(1, 1, PointerButton.left, Mods(alt: true))]);
    assert(f.mods.alt && !f.mods.ctrl);
    assert(foldFrame(Event[].init, f).mods.alt, "the level persists");
}

@("input.frame.heldKeysNeedTheCapability")
@safe
unittest
{
    import sparkles.input.events : charEvent, keyEvent;

    auto downEv = charEvent(' ');
    auto upEv = charEvent(' ', Mods.init, KeyAction.release);

    // Where the target reports releases, a held key is a level like a button.
    auto held = foldFrame([downEv], InputFrame.init, withReleases);
    assert(held.charHeld(' ') && held.heldCharCount == 1);
    assert(foldFrame(Event[].init, held, withReleases).charHeld(' '),
        "the level survives a quiet frame");

    const let = foldFrame([upEv], held, withReleases);
    assert(!let.charHeld(' ') && let.heldCharCount == 0);

    // Named keys likewise.
    auto shifted = foldFrame([keyEvent(Key.tab)], InputFrame.init, withReleases);
    assert(shifted.keyHeld(Key.tab));
    assert(!foldFrame([keyEvent(Key.tab, Mods.init, KeyAction.release)],
        shifted, withReleases).keyHeld(Key.tab));

    // Where it does NOT — a terminal — nothing is ever held. Tracking a press
    // with no possible release would latch it forever, which is worse than
    // reporting the absence the capability already declares.
    const terminal = foldFrame([downEv]);
    assert(!terminal.charHeld(' ') && terminal.heldCharCount == 0);
}

@("input.frame.heldCharsSaturate")
@safe
unittest
{
    import sparkles.input.events : charEvent;

    // A fixed set cannot grow without bound; beyond the cap further keys are
    // dropped rather than overrunning, and a repeat is not a second entry.
    Event[] many;
    foreach (c; "abcdefghijkl")
        many ~= charEvent(c);
    many ~= charEvent('a');

    const f = foldFrame(many, InputFrame.init, withReleases);
    assert(f.heldCharCount == maxHeldChars);
    assert(f.charHeld('a') && !f.charHeld('l'));
}

@("input.frame.gesturesCarryTheirAnchor")
@safe
unittest
{
    // The anchor is where the gesture BEGAN: slop can exceed half a toolbar
    // segment, so acting on the live pointer aims at the wrong thing.
    const lp = foldFrame([Event(GestureEvent(Gesture.longPress, Point(40, 90)))]);
    assert(lp.longPress && lp.anchor == PointF(40, 90));
    assert(lp.pinch == 0, "a long press does not scale");

    const pz = foldFrame([Event(GestureEvent(Gesture.pinch, Point(7, 8), 1.5))]);
    assert(pz.pinch == 1.5 && !pz.longPress);

    // A quiet frame clears the gesture flags but keeps the anchor, so a handler
    // reacting one frame later still knows where it happened.
    const after = foldFrame(Event[].init, lp);
    assert(!after.longPress && after.anchor == PointF(40, 90));
}

@("input.frame.pointerForProjectsFlagsAndCells")
@safe
unittest
{
    // The four actions, in the priority a polled frame implies.
    InputFrame f;
    f.pos = PointF(325, 300);
    assert(pointerFor(f, 10, 19).action == PointerAction.move);
    f.buttons[PointerButton.left].down = true;
    assert(pointerFor(f, 10, 19).action == PointerAction.drag);
    f.buttons[PointerButton.left].pressed = true;
    assert(pointerFor(f, 10, 19).action == PointerAction.press);
    // A press and a release in one frame is a press: the gesture starts here,
    // and the release that ends it is the next frame's business.
    f.buttons[PointerButton.left].released = true;
    assert(pointerFor(f, 10, 19).action == PointerAction.press);
    f.buttons[PointerButton.left].pressed = false;
    assert(pointerFor(f, 10, 19).action == PointerAction.release);

    // Pixels divide into cells: 325 px is the 32nd cell of a 10 px grid.
    const e = pointerFor(f, 10, 19);
    assert(e.pos == Point(32, 15) && e.button == PointerButton.left);

    // A degenerate cell size must not divide by zero.
    assert(pointerFor(f, 0, 0).pos == Point(325, 300));

    // The modifier level rides along, so a container sees the same chord the
    // host did.
    f.mods = Mods(ctrl: true);
    assert(pointerFor(f, 10, 19).mods.ctrl);
}
