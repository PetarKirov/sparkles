/**
The shared input vocabulary of `sparkles:input` (`INP1`–`INP4`): input is
$(B values) — one $(LREF Event) sum type over $(LREF KeyEvent),
$(LREF PointerEvent), $(LREF WheelEvent), $(LREF FocusEvent) and
$(LREF ResizeEvent) — not callbacks registered on widgets. A sum type rather
than a `kind` + dead fields record, so an illegal combination (a key event with
a mouse button) is unrepresentable and `==` compares only what is live.

Every event is a Regular value — copyable, comparable — so interaction tests
record byte streams, decode them, and assert on plain equality with no live
terminal or window in sight.

Positions are $(LREF Point) — the $(B same) `sparkles:math` instantiation the
toolkit's geometry uses (`INP3`) — in the toolkit's 0-based cell convention, so
no conversion happens at the widget boundary. Producers convert their native
coordinates (the SGR mouse wire is 1-based; a pixel backend divides by the cell
size) when they construct the event.
*/
module sparkles.input.events;

import std.sumtype : SumType;

import sparkles.math : ScreenPosition, ScreenSize;

/// Re-exported so consumers dispatch with `event.match!(…)` without importing
/// `std.sumtype` themselves.
public import std.sumtype : match;

@safe:

/// The toolkit's 2-D vocabulary — the same `sparkles:math` instantiations
/// `sparkles.ui.geometry` aliases, so the types are identical across the seam.
alias Point = ScreenPosition!int;
/// ditto
alias Size = ScreenSize!int;

/// A decoded key. `char_` carries a printable code point in `KeyEvent.ch`; the
/// rest are named keys.
enum Key : ubyte
{
    none, char_,
    up, down, left, right,
    home, end, pageUp, pageDown, insert, delete_,
    enter, tab, backspace, escape,
    f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
    back, /// the platform "go back / dismiss" key (Android's system back)
    menu, /// the platform menu key (Android); no desktop spelling
}

/// Keyboard modifiers carried on a key or pointer event.
struct Mods
{
    bool ctrl;
    bool alt;
    bool shift;
}

/// A key press: a named key, or a printable code point (`key == Key.char_`,
/// code point in `ch`) — which is also how text input arrives.
struct KeyEvent
{
    Key key;
    dchar ch;
    Mods mods;
}

/// The button of a $(LREF PointerEvent) (`none` for pure motion).
enum PointerButton : ubyte
{
    left,
    middle,
    right,
    none,
    back,    /// the thumb "back" button (set navigation)
    forward, /// the thumb "forward" button
}

/// What the pointer did.
enum PointerAction : ubyte
{
    press,   /// a button went down at `pos`
    release, /// a button came up at `pos`
    move,    /// motion with no button held
    drag,    /// motion with a button held
    leave,   /// the pointer left the viewport (nothing can be hot)
}

/// A pointer event at a 0-based cell position.
struct PointerEvent
{
    PointerAction action;
    PointerButton button = PointerButton.none;
    Point pos;
    Mods mods;
    /**
    Which pointer this is — `0` for the mouse, or the platform's stable finger
    id on a multi-touch target (`INP11`).

    Single-pointer producers leave it `0`, and so does everything above the
    gesture layer: the toolkit's state machines (`HoverState`, `ScrollState`'s
    grab) are single-pointer by construction, so a recognizer owns the ids and
    hands onward only the primary. The field exists because multi-touch is
    otherwise not expressible in the shared vocabulary at all — which would
    strand pinch in the app forever.
    */
    ubyte pointerId;
}

/**
A scroll step at `pos`. Sign convention matches the web's `deltaY`: scrolling
$(B up) is negative `dy`, down is positive; `dx` likewise (left negative).

`dx`/`dy` are the $(B cells to scroll), already multiplied — never a raw notch
count. The producer applies $(LREF linesPerNotch); a consumer that multiplies
again is a bug (`INP12`).

That rule exists so a producer with no notches can participate. A touch drag
resolves to whole rows by construction, and a high-resolution trackpad reports
pixels; both set `precise` and pass their own step, and every consumer scrolls
by exactly what it is given. Without it, touch could not reuse this event at
all — the historical ×3 applied by each consumer would have tripled a drag.
*/
struct WheelEvent
{
    int dx;
    int dy;
    Point pos;
    Mods mods;
    /// `true` when `dx`/`dy` came from a continuous source (a touch drag, a
    /// pixel-precise trackpad) rather than a discrete notch. Informational —
    /// consumers scroll by `dx`/`dy` either way; it exists so a host can, for
    /// example, decline to animate a precise scroll.
    bool precise;
}

/// Rows a discrete wheel notch scrolls. Applied by the $(B producer) so that
/// notch-derived and continuous scroll events arrive commensurable (`INP12`).
enum int linesPerNotch = 3;

/// Keyboard focus entered (`focused`) or left the surface.
struct FocusEvent
{
    bool focused;
}

/// The surface was resized. A zero size means "re-query" (a terminal resize
/// signal carries no dimensions; the reader re-asks the terminal).
struct ResizeEvent
{
    Size size;
}

/**
What a recognizer resolved a multi-sample pointer sequence into.

Taps and drags are deliberately $(B absent): they already have a spelling, so a
recognizer emits a tap as `PointerEvent(press)`+`(release)` and a drag or fling
as a `WheelEvent` (`GST2`). That is what keeps modality out of consumer code —
nothing downstream asks "was this a finger?".

Only gestures with no existing spelling appear here.
*/
enum Gesture : ubyte
{
    longPress, /// held past the threshold, within the slop radius
    pinch,     /// two pointers changed separation; `scale` is the ratio
}

/**
A recognized gesture at `pos` — the $(B anchor), i.e. where the gesture began,
not where the pointer is now.

One case rather than one per gesture, so `Event`'s arity stays stable and a
gesture stream stays recordable through the same seam as all other input
(`INP4`). `scale` is `1.0` for gestures that do not scale, which is a
legitimate value rather than a dead field.
*/
struct GestureEvent
{
    Gesture gesture;
    Point pos;
    float scale = 1.0;
    Mods mods;
}

/// An unrecognized or incomplete input sequence — ignorable, but its presence
/// is visible (e.g. to a raw-input debugger) rather than silently dropped.
struct NoEvent
{
}

/// The input stream closed (EOF / window closed): the shell's cue to quit.
struct EndOfInput
{
}

/// One input event (`INP1`): dispatch with
/// `event.match!((in KeyEvent k) => …, …)`. `Event.init` is `NoEvent`.
alias Event = SumType!(
    NoEvent, KeyEvent, PointerEvent, WheelEvent, FocusEvent, ResizeEvent,
    GestureEvent, EndOfInput);

/// A named-key event.
Event keyEvent(Key k, Mods m = Mods()) pure nothrow @nogc
    => Event(KeyEvent(k, 0, m));

/// A printable code-point event (also text input).
Event charEvent(dchar c, Mods m = Mods()) pure nothrow @nogc
    => Event(KeyEvent(Key.char_, c, m));

/// `true` iff the stream ended — the one test every event-loop shell makes.
bool isEndOfInput(in Event e) pure nothrow @nogc
    => e.match!((in EndOfInput _) => true, _ => false);

/**
`true` for the platform spellings of "go back / dismiss" (`INP13`): `Escape`
on desktop and in the terminal, the system back key on Android.

The framework owns the $(I equivalence); the application owns the chain. hue
dismisses a hover popup, then the explorer, then quits — that ordering is
hue's, and a different app would nest differently. `q` is deliberately not
here: "q quits" is a keybinding, not a platform spelling of dismiss.
*/
bool isDismiss(in KeyEvent k) pure nothrow @nogc
    => k.key == Key.escape || k.key == Key.back;

@("input.events.isDismiss")
@safe pure nothrow @nogc unittest
{
    assert(isDismiss(KeyEvent(Key.escape)));
    assert(isDismiss(KeyEvent(Key.back)));
    assert(!isDismiss(KeyEvent(Key.menu)));
    assert(!isDismiss(KeyEvent(Key.char_, 'q')));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("input.events.regularValues")
@safe pure nothrow unittest
{
    // Events are Regular: copyable, comparable, usable as plain data.
    const a = charEvent('x', Mods(ctrl: true));
    const b = charEvent('x', Mods(ctrl: true));
    assert(a == b);
    assert(a != keyEvent(Key.up));

    // Different kinds never compare equal, and `==` sees only live fields.
    assert(Event(PointerEvent(action: PointerAction.press,
        button: PointerButton.left, pos: Point(3, 4)))
        != Event(WheelEvent(dy: 1, pos: Point(3, 4))));

    assert(Event.init == Event(NoEvent()));
}

@("input.events.matchDispatch")
@safe pure nothrow @nogc unittest
{
    // The dispatch shape every consumer uses.
    static int classify(in Event e) => e.match!(
        (in KeyEvent k) => 1,
        (in PointerEvent p) => 2,
        (in WheelEvent w) => 3,
        _ => 0,
    );

    assert(classify(keyEvent(Key.enter)) == 1);
    assert(classify(Event(PointerEvent(action: PointerAction.move,
        pos: Point(1, 1)))) == 2);
    assert(classify(Event(WheelEvent(dy: -1))) == 3);
    assert(classify(Event(ResizeEvent())) == 0);
    assert(!isEndOfInput(keyEvent(Key.escape)));
    assert(isEndOfInput(Event(EndOfInput())));
}
