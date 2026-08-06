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
///
/// `super_` is the platform's Command / Windows / Super key. It is last so that
/// every existing positional construction keeps its meaning.
struct Mods
{
    bool ctrl;
    bool alt;
    bool shift;
    bool super_;
}

/**
What a key did (`INP15`).

A terminal cannot report `release` at all, so a consumer that needs the level of
a held key must ask `InputCapabilities.keyRelease` and offer another route where
it is absent — the `TGT5` rule, applied to keys. `press` is the default, so a
producer that has not thought about this reports what it always did.
*/
enum KeyAction : ubyte
{
    press,   /// the key went down
    repeat,  /// the platform's auto-repeat fired while it is held
    release, /// the key came up
}

/**
A key event: a named key, or a printable code point (`key == Key.char_`, code
point in `ch`) — which is also how text input arrives.

`unshifted` and `text` exist for the one consumer that cannot work without
them: a terminal emulator's key encoder, which reports the layout-independent
key that was struck $(I and) the characters it produced, together. Delivering
the text as a separate event cannot express that pairing — which keystroke
produced which text — so it rides here.

The three fields are appended, so every existing construction and helper keeps
its meaning; `KeyAction.press` and a zero `unshifted` describe what producers
reported before.
*/
struct KeyEvent
{
    Key key;
    dchar ch;
    Mods mods;
    KeyAction action;   /// press (the default), auto-repeat, or release
    /**
    The code point this key produces with no modifiers applied — `'a'` for the
    `A` key whatever the shift state, `0` where the key has no such spelling
    (arrows, function keys). Layout-independent identity, for a consumer that
    must name the physical key rather than the character.
    */
    /// `0` when the key has no such spelling. Explicit, because `dchar.init` is
    /// `0xFFFF` — which is why the constructors above pass `ch` as `0` by hand.
    dchar unshifted = 0;
    /**
    The UTF-8 this keystroke produced, or empty.

    $(B Stored inline,) not borrowed. A slice would cost the whole vocabulary
    its `INP4` guarantee — an event you can record now and assert on later
    cannot hold a pointer into a producer's per-frame buffer — and it makes the
    sum type's assignment `@system` under `dip1000`. One keystroke yields one
    code point (four bytes at most); the extra room covers a dead-key or IME
    composition that resolves to a couple. Text beyond that is not a keystroke's
    output and belongs in a composition event of its own.
    */
    private char[maxKeyText] _text = 0;
    private ubyte _textLength;

    /// The produced text, as a slice of this event's own storage.
    const(char)[] text() const return @safe pure nothrow @nogc
        => _text[0 .. _textLength];

    /// Sets the produced text, truncating beyond `maxKeyText`. Unused bytes are
    /// zeroed, so two events carrying the same text compare equal.
    void text(scope const(char)[] t) @safe pure nothrow @nogc
    {
        _text[] = 0;
        const n = t.length > maxKeyText ? maxKeyText : t.length;
        _text[0 .. n] = t[0 .. n];
        _textLength = cast(ubyte) n;
    }
}

/// The most UTF-8 a single `KeyEvent` carries — see `KeyEvent.text`.
enum size_t maxKeyText = 8;

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
Event keyEvent(Key k, Mods m = Mods(), KeyAction a = KeyAction.press) pure nothrow @nogc
    => Event(KeyEvent(k, 0, m, a));

/// A printable code-point event (also text input).
Event charEvent(dchar c, Mods m = Mods(), KeyAction a = KeyAction.press) pure nothrow @nogc
    => Event(KeyEvent(Key.char_, c, m, a));

/// `true` iff the stream ended — the one test every event-loop shell makes.
bool isEndOfInput(in Event e) pure nothrow @nogc
    => e.match!((in EndOfInput _) => true, _ => false);

/// `true` iff `e` carries nothing — the drain sentinel every recogniser and
/// decoder returns when it has no more events this frame.
bool isNoEvent(in Event e) pure nothrow @nogc
    => e.match!((in NoEvent _) => true, _ => false);

/**
`true` for the platform spellings of "go back / dismiss" (`INP13`): `Escape`
on desktop and in the terminal, the system back key on Android.

The framework owns the $(I equivalence); the application owns the chain. hue
dismisses a hover popup, then the explorer, then quits — that ordering is
hue's, and a different app would nest differently. `q` is deliberately not
here: "q quits" is a keybinding, not a platform spelling of dismiss.
*/
bool isDismiss(in KeyEvent k) pure nothrow @nogc
    => k.action != KeyAction.release && (k.key == Key.escape || k.key == Key.back);

@("input.events.isDismiss")
@safe pure nothrow @nogc unittest
{
    assert(isDismiss(KeyEvent(Key.escape)));
    assert(isDismiss(KeyEvent(Key.back)));
    assert(!isDismiss(KeyEvent(Key.menu)));
    assert(!isDismiss(KeyEvent(Key.char_, 'q')));

    // A release is not a second dismissal. Once a target reports releases, an
    // app that dismissed on the press would otherwise dismiss twice per stroke
    // — closing a popup and then quitting.
    auto up = KeyEvent(Key.escape);
    up.action = KeyAction.release;
    assert(!isDismiss(up));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("input.events.keyLevels")
@safe pure nothrow @nogc
unittest
{
    // Appended fields, so every existing construction still means what it did:
    // a bare key event is a press that produced no text.
    const plain = KeyEvent(Key.enter);
    assert(plain.action == KeyAction.press);
    assert(plain.unshifted == 0 && plain.text.length == 0);
    assert(!plain.mods.super_);

    // The three actions are distinct values on the same key.
    auto down = KeyEvent(Key.char_, 'a');
    auto rep = down;
    rep.action = KeyAction.repeat;
    auto up = down;
    up.action = KeyAction.release;
    assert(down != rep && rep != up && down != up);
}

@("input.events.keyTextIsInlineAndRegular")
@safe pure nothrow @nogc
unittest
{
    // The text is stored, not borrowed: an event recorded now can be asserted
    // on later, which a slice into a producer's frame buffer could not promise.
    KeyEvent a;
    a.text = "é"; // two UTF-8 bytes
    assert(a.text == "é" && a.text.length == 2);

    // Equality sees the text, and unused bytes are zeroed so two events built
    // from the same string compare equal whatever they held before.
    KeyEvent b;
    b.text = "longer";
    b.text = "é";
    assert(a == b);

    b.text = "e";
    assert(a != b);

    // Beyond the cap the text is truncated rather than overrunning: one
    // keystroke does not produce a paragraph.
    KeyEvent c;
    c.text = "0123456789";
    assert(c.text.length == maxKeyText);
    assert(c.text == "01234567");
}

@("input.events.superModifier")
@safe pure nothrow @nogc
unittest
{
    // `super_` is last, so positional construction of the older three is
    // unchanged — and a modifier set without it still compares equal to one
    // built the old way.
    assert(Mods(true, false, true) == Mods(ctrl: true, shift: true));
    assert(Mods(ctrl: true) != Mods(ctrl: true, super_: true));

    // It rides on pointer events too, which is where a modifier-drag reads it.
    const e = PointerEvent(action: PointerAction.drag, button: PointerButton.left,
        pos: Point(2, 3), mods: Mods(super_: true));
    assert(e.mods.super_ && !e.mods.ctrl);
}

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
