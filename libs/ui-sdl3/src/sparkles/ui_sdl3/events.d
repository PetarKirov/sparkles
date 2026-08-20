/**
Turning SDL's event queue into the shared `sparkles:input` vocabulary.

The peer backend, `sparkles:ui-raylib`, has to $(I derive) edges: raylib
exposes polled state, so its `events.d` diffs "is the button down now" against
"was it down last frame" to recover press and release. SDL has a real queue and
reports the edges itself, so this module is a $(B translation) rather than a
reconstruction — and that difference is why almost all of it is testable.

$(B `translate` takes one `SDL_Event` and emits toolkit events.) Nothing in it
calls SDL, so a unit test constructs an `SDL_Event` by hand, pushes it through,
and asserts on the result with no window, no video driver and no display. The
only part that must talk to SDL is $(LREF Sdl3Events.poll), which is a loop
around `SDL_PollEvent` — three lines that cannot be got wrong in an interesting
way.

$(B Text input must be switched on, or none arrives.) SDL3 delivers
`SDL_EVENT_TEXT_INPUT` only between `SDL_StartTextInput` and
`SDL_StopTextInput`, and the failure mode is silent: named keys keep working
and typing produces nothing. $(REF Window.textInput, sparkles,ui_sdl3,window)
is where that is turned on.
*/
module sparkles.ui_sdl3.events;

import sparkles.input;
import sparkles.ui_sdl3.sdl3_c;

/**
SDL's `SDLK_SCANCODE_MASK`: the bit that marks a keycode with no character.

Spelled out because it is a function-like macro in
`SDL3/SDL_keycode.h` (`SDL_SCANCODE_TO_KEYCODE`), which ImportC does not fold —
the same reason `WindowFlags` is re-declared in
$(MREF sparkles,ui_sdl3,window). Pinned below against a key that carries it.
*/
private enum uint scancodeMask = 1u << 30;

static assert((SDLK_UP & scancodeMask) != 0,
    "SDLK_UP must carry the scancode mask — SDL renumbered its keycodes");
static assert((SDLK_A & scancodeMask) == 0,
    "SDLK_A is a character keycode and must not carry the mask");

/**
Per-window input translation. Construct once; call $(LREF poll) each frame.

Mirrors `RaylibEvents` deliberately, down to `poll`'s parameter list: `A6`
makes the two interchangeable behind `isWindowSystem!R`, and a seam is easier
to cut when the things either side of it already agree.
*/
struct Sdl3Events
{
    /**
    What this window's input actually offers (`IXB10`/`TGT5`).

    $(B A declaration, not a fact about SDL.) SDL can report key releases on
    every platform, so this could default to the full grade — and must not.
    The grade decides which $(I events a consumer sees), so defaulting it
    differently from the raylib peer would mean the same application receives
    different keyboard events depending on which backend it was built with,
    which is the one thing the shared vocabulary exists to prevent. A host that
    wants the full grade asks for it, on either backend.
    */
    InputCapabilities capabilities = mousePointer;

    private
    {
        Mods _mods;
        Point _lastPos;
        float _wheelAccumX = 0, _wheelAccumY = 0;

        // The full grade holds one keystroke back so this frame's typed text
        // can ride on it — see `translate`.
        KeyEvent _pending;
        bool _hasPending;
    }

    /**
    The modifier keys held as of the last event seen.

    A LEVEL, not an edge, matching the raylib peer's `modifiers`: events carry
    their own `mods` for the moment they occurred; this answers for now.
    */
    Mods modifiers() const @safe pure nothrow @nogc => _mods;

    /**
    Drain SDL's queue into `sink`.

    The only member that talks to SDL. `SDL_GetModState` is read once up front
    so that a pointer event — which SDL does not stamp with modifiers — still
    reports them; keyboard events override it with their own, which is exact
    for the moment they occurred.
    */
    void poll(Sink)(scope Sink sink, int cellW, int cellH,
        int originX = 0, int originY = 0) @system
    {
        const m = CellMetrics(cellW, cellH, originX, originY);
        _mods = toMods(cast(ushort) SDL_GetModState());

        SDL_Event ev;
        while (SDL_PollEvent(&ev))
            translate(ev, sink, m);

        // A keystroke held for text that never came still has to be delivered,
        // and the queue draining is the last moment we can know that.
        flush(sink);
    }

    /**
    Translate one SDL event into zero or more toolkit events.

    `@system` rather than `@trusted`: an `SDL_EVENT_TEXT_INPUT` carries a
    `const(char)*` that this reads to its NUL, and the caller supplies the
    event. Trusting a caller-supplied pointer would be a lie — from SDL it is
    always a valid NUL-terminated UTF-8 string, and from a test it is whatever
    the test wrote.
    */
    void translate(Sink)(in SDL_Event ev, scope Sink sink, in CellMetrics m) @system
    {
        switch (ev.type)
        {
            case SDL_EventType.SDL_EVENT_KEY_DOWN:
            case SDL_EventType.SDL_EVENT_KEY_UP:
                _mods = toMods(ev.key.mod);
                onKey(ev.key, sink);
                return;

            case SDL_EventType.SDL_EVENT_TEXT_INPUT:
                onText(ev.text, sink);
                return;

            case SDL_EventType.SDL_EVENT_MOUSE_MOTION:
                flush(sink);
                _lastPos = m.toCell(ev.motion.x, ev.motion.y);
                // SDL reports the held-button mask on the motion itself, so
                // drag and move are distinguished without tracking presses.
                const held = heldButton(ev.motion.state);
                sink(Event(PointerEvent(
                    action: held == PointerButton.none
                        ? PointerAction.move : PointerAction.drag,
                    button: held,
                    pos: _lastPos,
                    mods: _mods)));
                return;

            case SDL_EventType.SDL_EVENT_MOUSE_BUTTON_DOWN:
            case SDL_EventType.SDL_EVENT_MOUSE_BUTTON_UP:
                flush(sink);
                _lastPos = m.toCell(ev.button.x, ev.button.y);
                sink(Event(PointerEvent(
                    action: ev.button.down
                        ? PointerAction.press : PointerAction.release,
                    button: toButton(ev.button.button),
                    pos: _lastPos,
                    mods: _mods)));
                return;

            case SDL_EventType.SDL_EVENT_MOUSE_WHEEL:
                flush(sink);
                onWheel(ev.wheel, sink, m);
                return;

            case SDL_EventType.SDL_EVENT_WINDOW_MOUSE_LEAVE:
                flush(sink);
                // No position of its own: the pointer left, and the last place
                // it was seen is the only honest answer.
                sink(Event(PointerEvent(action: PointerAction.leave,
                    pos: _lastPos)));
                return;

            case SDL_EventType.SDL_EVENT_WINDOW_FOCUS_GAINED:
                flush(sink);
                sink(Event(FocusEvent(focused: true)));
                return;

            case SDL_EventType.SDL_EVENT_WINDOW_FOCUS_LOST:
                flush(sink);
                sink(Event(FocusEvent(focused: false)));
                return;

            case SDL_EventType.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
                flush(sink);
                // Zero size: the caller re-queries, exactly as the raylib peer
                // and the terminal's resize signal do. The pixel size is the
                // one that matters — `SDL_EVENT_WINDOW_RESIZED` is in logical
                // units, which are not pixels under display scaling.
                sink(Event(ResizeEvent()));
                return;

            default:
                return;
        }
    }

    /**
    Emit a keystroke held back for text pairing, if any.

    Idempotent, and called before every non-keyboard event: a held stroke must
    not overtake the pointer or focus event that followed it.
    */
    void flush(Sink)(scope Sink sink) @safe
    {
        if (!_hasPending)
            return;
        _hasPending = false;
        sink(Event(_pending));
    }

    private void onKey(Sink)(in SDL_KeyboardEvent k, scope Sink sink) @safe
    {
        const named = namedKey(k.key);
        const action = !k.down ? KeyAction.release
            : k.repeat ? KeyAction.repeat : KeyAction.press;

        // The basic grade is what every consumer saw before the full one
        // existed: named keys only, and typed characters arriving as their own
        // events out of `SDL_EVENT_TEXT_INPUT`. A release has no spelling in
        // it at all.
        if (!capabilities.keyRelease)
        {
            if (action != KeyAction.release && named != Key.none)
                sink(Event(KeyEvent(key: named, ch: 0, mods: _mods,
                    action: action)));
            return;
        }

        flush(sink);

        auto e = KeyEvent(
            key: named != Key.none ? named : Key.char_,
            ch: 0,
            mods: _mods,
            action: action,
            unshifted: unshiftedCodepoint(k.key));

        // Hold a press or repeat back one event: SDL sends the keystroke
        // first and the text it produced immediately after, so the pairing
        // `INP15` requires — which stroke produced which text — is knowable
        // only by looking one event ahead. A release never carries text.
        if (action == KeyAction.release)
            sink(Event(e));
        else
        {
            _pending = e;
            _hasPending = true;
        }
    }

    private void onText(Sink)(in SDL_TextInputEvent t, scope Sink sink) @system
    {
        import std.string : fromStringz;
        import std.utf : byDchar;

        const text = t.text is null ? "" : t.text.fromStringz.idup;
        if (text.length == 0)
        {
            flush(sink);
            return;
        }

        // Pair onto the held stroke when the whole burst fits inline. It may
        // not: a paste or an IME commit arrives as one `TEXT_INPUT` and is not
        // a keystroke's output, so it falls back to character events rather
        // than being truncated onto one.
        if (_hasPending && text.length <= maxKeyText)
        {
            _pending.text(text);

            // A single typed code point is also the stroke's `ch`. Every other
            // producer delivers the typed character there, and a consumer that
            // switches on `ch` must not go deaf the moment a target upgrades
            // to the full grade.
            //
            // Asked as "one, then none" rather than with a counter, and not
            // only because it reads better: a bare `size_t` here does not
            // compile on macOS. This module imports an ImportC surface, which
            // brings its own `size_t` alongside `object`'s — glibc collapses
            // the two, darwin does not — so the name is ambiguous there and
            // nowhere else. See the note in `sparkles.ui_sdl3`.
            auto rest = text.byDchar;
            const first = rest.front;
            rest.popFront();
            if (rest.empty)
                _pending.ch = first;

            flush(sink);
            return;
        }

        flush(sink);
        foreach (c; text.byDchar)
            sink(Event(KeyEvent(key: Key.char_, ch: c, mods: _mods)));
    }

    private void onWheel(Sink)(in SDL_MouseWheelEvent w, scope Sink sink,
        in CellMetrics m) @safe
    {
        // SDL reports positive `y` for scrolling away from the user; the
        // toolkit follows the web's `deltaY`, where up is negative. A
        // "flipped" wheel is SDL telling us the platform already inverted it
        // for natural scrolling, so undoing that here would fight the user's
        // own setting.
        const sign = w.direction == SDL_MouseWheelDirection.SDL_MOUSEWHEEL_FLIPPED
            ? 1.0f : -1.0f;

        const dx = wheelSteps(_wheelAccumX, sign * w.x) * linesPerNotch;
        const dy = wheelSteps(_wheelAccumY, sign * w.y) * linesPerNotch;
        if (dx == 0 && dy == 0)
            return;

        _lastPos = m.toCell(w.mouse_x, w.mouse_y);
        sink(Event(WheelEvent(dx: dx, dy: dy, pos: _lastPos, mods: _mods)));
    }
}

/// Maps SDL's named keys onto the shared `Key` vocabulary. A key that spells a
/// character has no named form — `Key.none` — and reaches a consumer either as
/// typed text or, in the full grade, through `KeyEvent.unshifted`.
Key namedKey(uint keycode) @safe pure nothrow @nogc
{
    switch (keycode)
    {
        case SDLK_UP:        return Key.up;
        case SDLK_DOWN:      return Key.down;
        case SDLK_LEFT:      return Key.left;
        case SDLK_RIGHT:     return Key.right;
        case SDLK_HOME:      return Key.home;
        case SDLK_END:       return Key.end;
        case SDLK_PAGEUP:    return Key.pageUp;
        case SDLK_PAGEDOWN:  return Key.pageDown;
        case SDLK_INSERT:    return Key.insert;
        case SDLK_DELETE:    return Key.delete_;
        // The keypad's Enter is the same key to everything above this layer.
        case SDLK_RETURN:
        case SDLK_KP_ENTER:  return Key.enter;
        case SDLK_TAB:       return Key.tab;
        case SDLK_BACKSPACE: return Key.backspace;
        case SDLK_ESCAPE:    return Key.escape;
        case SDLK_F1:        return Key.f1;
        case SDLK_F2:        return Key.f2;
        case SDLK_F3:        return Key.f3;
        case SDLK_F4:        return Key.f4;
        case SDLK_F5:        return Key.f5;
        case SDLK_F6:        return Key.f6;
        case SDLK_F7:        return Key.f7;
        case SDLK_F8:        return Key.f8;
        case SDLK_F9:        return Key.f9;
        case SDLK_F10:       return Key.f10;
        case SDLK_F11:       return Key.f11;
        case SDLK_F12:       return Key.f12;
        // Android's system keys, which SDL surfaces on every platform.
        case SDLK_AC_BACK:   return Key.back;
        case SDLK_MENU:      return Key.menu;
        default:             return Key.none;
    }
}

/**
The code point a key spells with no modifiers, or `0`.

SDL3 makes this nearly free: a keycode $(I is) the unmodified character —
`SDLK_A` is `'a'`, whatever the shift state — with a mask bit set on the keys
that spell nothing.

Control characters are excluded even though SDL gives them a keycode. Return is
`13` and Backspace is `8`, but both already have a named $(REF Key,
sparkles,input,events), and reporting a control code as "the character this key
produces" would have a consumer insert one. This matches the raylib peer, whose
`unshiftedCodepoint` covers letters, digits, punctuation and space and nothing
else.

$(B Layout follows the user, not the hardware.) An SDL keycode is what the
active layout says the key spells, so on AZERTY the key where a US keyboard has
`Q` reports `'a'`. That is the more useful answer for a keymap a human
configured, and it differs from the raylib peer, which reports US-physical
positions.
*/
dchar unshiftedCodepoint(uint keycode) @safe pure nothrow @nogc
{
    if (keycode & scancodeMask)
        return 0;
    if (keycode < 0x20 || keycode == 0x7F)
        return 0;
    return cast(dchar) keycode;
}

/// SDL's modifier bitmask as the toolkit's four flags.
Mods toMods(ushort sdlMod) @safe pure nothrow @nogc
    => Mods(
        ctrl: (sdlMod & SDL_KMOD_CTRL) != 0,
        alt: (sdlMod & SDL_KMOD_ALT) != 0,
        shift: (sdlMod & SDL_KMOD_SHIFT) != 0,
        // Command on macOS, Windows/Super elsewhere.
        super_: (sdlMod & SDL_KMOD_GUI) != 0);

/**
SDL's 1-based button index as a $(REF PointerButton, sparkles,input,events).

Never an index cast: `PointerButton.none` sits mid-enum and SDL's thumb buttons
are `X1`/`X2` rather than a continuation of the first three, so arithmetic on
the index silently produces the wrong button.
*/
PointerButton toButton(ubyte sdlButton) @safe pure nothrow @nogc
{
    switch (sdlButton)
    {
        case SDL_BUTTON_LEFT:   return PointerButton.left;
        case SDL_BUTTON_MIDDLE: return PointerButton.middle;
        case SDL_BUTTON_RIGHT:  return PointerButton.right;
        case SDL_BUTTON_X1:     return PointerButton.back;
        case SDL_BUTTON_X2:     return PointerButton.forward;
        default:                return PointerButton.none;
    }
}

/**
The bit `button` occupies in one of SDL's held-button masks.

`SDL_BUTTON_MASK` is a function-like macro, which ImportC does not fold — the
same limitation that re-declares `WindowFlags` in
$(MREF sparkles,ui_sdl3,window) and $(D scancodeMask) above. SDL numbers its
buttons from 1, so the bit is one less.
*/
private uint buttonMask(ubyte button) @safe pure nothrow @nogc
    => button == 0 ? 0 : 1u << (button - 1);

/**
The lowest-numbered button held in one of SDL's motion-event masks, or `none`.

A drag reports the button that started it; with several held, the primary one
wins, which is what a single-pointer consumer expects.
*/
PointerButton heldButton(uint state) @safe pure nothrow @nogc
{
    static immutable ubyte[5] order = [
        SDL_BUTTON_LEFT, SDL_BUTTON_MIDDLE, SDL_BUTTON_RIGHT,
        SDL_BUTTON_X1, SDL_BUTTON_X2,
    ];
    foreach (b; order)
        if (state & buttonMask(b))
            return toButton(b);
    return PointerButton.none;
}

// -----------------------------------------------------------------------------
// Tests
//
// Every one of these runs with no window, no video driver and no display: an
// `SDL_Event` is a plain struct, and `translate` never calls SDL. That is the
// whole reason the translation was separated from the queue drain — the raylib
// peer's equivalent logic can only be exercised against a live window.
// -----------------------------------------------------------------------------

version (unittest)
{
    /// Collects what a translation emitted, so a test can assert on a sequence.
    private struct Recorder
    {
        Event[] events;

        /// The sink to hand `translate`. A delegate rather than the struct
        /// itself: the sink is called as `sink(e)`, and a pointer to a struct
        /// with `opCall` is not callable that way.
        void delegate(Event) @safe sink() return @safe
            => (Event e) { events ~= e; };

        /// The single event recorded, asserting there is exactly one.
        Event only() @safe
        {
            assert(events.length == 1, "expected exactly one event");
            return events[0];
        }
    }

    // `@system`: `SDL_Event` is a union, and writing one arm's fields — which
    // overlap pointers in another — is exactly what `@safe` forbids. Building
    // one by hand is the whole point here, so the builders own that.
    private SDL_Event keyEventOf(uint keycode, bool down, bool repeat = false,
        ushort mod = 0) @system pure nothrow @nogc
    {
        SDL_Event ev;
        ev.type = down
            ? SDL_EventType.SDL_EVENT_KEY_DOWN : SDL_EventType.SDL_EVENT_KEY_UP;
        ev.key.key = keycode;
        ev.key.down = down;
        ev.key.repeat = repeat;
        ev.key.mod = mod;
        return ev;
    }

    private SDL_Event textEventOf(const(char)* text) @system pure nothrow @nogc
    {
        SDL_Event ev;
        ev.type = SDL_EventType.SDL_EVENT_TEXT_INPUT;
        ev.text.text = text;
        return ev;
    }

    private SDL_Event mouseButtonOf(ubyte button, bool down, float x, float y)
        @system pure nothrow @nogc
    {
        SDL_Event ev;
        ev.type = down
            ? SDL_EventType.SDL_EVENT_MOUSE_BUTTON_DOWN
            : SDL_EventType.SDL_EVENT_MOUSE_BUTTON_UP;
        ev.button.button = button;
        ev.button.down = down;
        ev.button.x = x;
        ev.button.y = y;
        return ev;
    }

    /// The full-keyboard grade, which is opt-in on both backends.
    private enum InputCapabilities fullKeyboard = () {
        InputCapabilities c = mousePointer;
        c.keyRelease = true;
        return c;
    }();
}

@("ui_sdl3.events.cellMappingDividesAndOffsets")
@safe pure nothrow @nogc unittest
{
    const m = CellMetrics(cellW: 10, cellH: 20, originX: 5, originY: 7);
    assert(m.toCell(5, 7) == Point(0, 0));
    assert(m.toCell(25, 47) == Point(2, 2));
    // Sub-cell positions land in the cell they are inside, not the next one.
    assert(m.toCell(14.9f, 26.9f) == Point(0, 0));

    // A zero cell size is a caller error the mapping must not divide by: a
    // font that failed to load leaves these zero, and a crash there would be
    // blamed on input rather than on the font.
    const degenerate = CellMetrics(cellW: 0, cellH: 0);
    assert(degenerate.toCell(3, 4) == Point(3, 4));
}

@("ui_sdl3.events.basicGradeReportsNamedKeysAndTypedText")
@system unittest
{
    Sdl3Events ev;              // the default grade
    Recorder rec;

    // A named key arrives as itself...
    ev.translate(keyEventOf(SDLK_UP, down: true), rec.sink, CellMetrics.init);
    assert(rec.only.match!((KeyEvent k) => k.key, _ => Key.none) == Key.up);

    // ... and its release is not reported at all in this grade, which is the
    // contract a terminal-backed consumer was written against.
    rec.events = null;
    ev.translate(keyEventOf(SDLK_UP, down: false), rec.sink, CellMetrics.init);
    assert(rec.events.length == 0);

    // A character key has no named form, so nothing comes from the keystroke;
    // the character arrives from SDL's own text event.
    rec.events = null;
    ev.translate(keyEventOf(SDLK_A, down: true), rec.sink, CellMetrics.init);
    assert(rec.events.length == 0);

    ev.translate(textEventOf("a"), rec.sink, CellMetrics.init);
    const typed = rec.only.match!((KeyEvent k) => k, _ => KeyEvent.init);
    assert(typed.key == Key.char_ && typed.ch == 'a');
}

@("ui_sdl3.events.fullGradePairsTypedTextOntoItsKeystroke")
@system unittest
{
    // `INP15`: a pty key encoder must know WHICH keystroke produced the text,
    // and SDL sends them as two events — the keystroke first. So the stroke is
    // held one event to see whether text follows.
    Sdl3Events ev;
    ev.capabilities = fullKeyboard;
    Recorder rec;

    ev.translate(keyEventOf(SDLK_A, down: true), rec.sink, CellMetrics.init);
    assert(rec.events.length == 0, "the stroke is held until the text can join it");

    ev.translate(textEventOf("a"), rec.sink, CellMetrics.init);
    const k = rec.only.match!((KeyEvent e) => e, _ => KeyEvent.init);
    assert(k.action == KeyAction.press);
    assert(k.text == "a");
    assert(k.unshifted == 'a');
    // A single typed code point is also the stroke's `ch`, so a consumer that
    // switches on `ch` keeps working when a target upgrades to this grade.
    assert(k.ch == 'a');
}

@("ui_sdl3.events.fullGradeReleasesNeverCarryTextAndNeverWait")
@system unittest
{
    Sdl3Events ev;
    ev.capabilities = fullKeyboard;
    Recorder rec;

    // A release is emitted immediately: no text can follow it, so holding it
    // back would only delay it behind the next event.
    ev.translate(keyEventOf(SDLK_A, down: false), rec.sink, CellMetrics.init);
    const k = rec.only.match!((KeyEvent e) => e, _ => KeyEvent.init);
    assert(k.action == KeyAction.release);
    assert(k.text.length == 0);

    // Two presses with no text between them: the first must not be swallowed
    // by the second's arrival.
    rec.events = null;
    ev.translate(keyEventOf(SDLK_A, down: true), rec.sink, CellMetrics.init);
    ev.translate(keyEventOf(SDLK_B, down: true), rec.sink, CellMetrics.init);
    assert(rec.events.length == 1, "the held stroke is flushed by the next one");
    ev.flush(rec.sink);
    assert(rec.events.length == 2);
}

@("ui_sdl3.events.aHeldStrokeNeverOvertakesTheEventAfterIt")
@system unittest
{
    // The ordering hazard the one-event lookahead creates: a keystroke waiting
    // for text must not be delivered AFTER the pointer event that genuinely
    // came later. Every non-keyboard arm flushes first.
    Sdl3Events ev;
    ev.capabilities = fullKeyboard;
    Recorder rec;

    ev.translate(keyEventOf(SDLK_A, down: true), rec.sink, CellMetrics.init);
    ev.translate(mouseButtonOf(SDL_BUTTON_LEFT, down: true, 0, 0), rec.sink,
        CellMetrics.init);

    assert(rec.events.length == 2);
    assert(rec.events[0].match!((KeyEvent _) => true, _ => false),
        "the keystroke happened first and must be reported first");
    assert(rec.events[1].match!((PointerEvent _) => true, _ => false));
}

@("ui_sdl3.events.anOversizeBurstFallsBackToCharacterEvents")
@system unittest
{
    // A paste or an IME commit arrives as one `TEXT_INPUT` and is not a
    // keystroke's output. Truncating it onto the event's inline storage would
    // silently drop input, so it becomes character events instead.
    Sdl3Events ev;
    ev.capabilities = fullKeyboard;
    Recorder rec;

    ev.translate(keyEventOf(SDLK_V, down: true, repeat: false,
        mod: SDL_KMOD_LCTRL), rec.sink, CellMetrics.init);
    ev.translate(textEventOf("abcdefghij"), rec.sink, CellMetrics.init);

    // The stroke, then one event per code point — and the stroke keeps no text.
    assert(rec.events.length == 1 + 10);
    const stroke = rec.events[0].match!((KeyEvent k) => k, _ => KeyEvent.init);
    assert(stroke.text.length == 0);
    assert(rec.events[1].match!((KeyEvent k) => k.ch, _ => dchar.init) == 'a');
}

@("ui_sdl3.events.modifiersComeFromTheKeystrokesOwnState")
@system unittest
{
    Sdl3Events ev;
    Recorder rec;

    ev.translate(keyEventOf(SDLK_UP, down: true, repeat: false,
        mod: cast(ushort)(SDL_KMOD_LCTRL | SDL_KMOD_RSHIFT)), rec.sink,
        CellMetrics.init);

    const k = rec.only.match!((KeyEvent e) => e, _ => KeyEvent.init);
    assert(k.mods.ctrl && k.mods.shift);
    assert(!k.mods.alt && !k.mods.super_);

    // Left and right variants are the same modifier to everything above here.
    assert(toMods(SDL_KMOD_LCTRL) == toMods(SDL_KMOD_RCTRL));
    assert(toMods(SDL_KMOD_LGUI).super_, "Command/Windows is `super_`");
}

@("ui_sdl3.events.repeatIsItsOwnAction")
@system unittest
{
    // SDL reports auto-repeat on the event; the raylib peer has to poll a
    // separate `IsKeyPressedRepeat` for a hardcoded set of keys to find it.
    Sdl3Events ev;
    Recorder rec;
    ev.translate(keyEventOf(SDLK_DOWN, down: true, repeat: true), rec.sink,
        CellMetrics.init);
    assert(rec.only.match!((KeyEvent k) => k.action, _ => KeyAction.press)
        == KeyAction.repeat);
}

@("ui_sdl3.events.pointerButtonsAreMappedNotCast")
@safe pure nothrow @nogc unittest
{
    // `PointerButton.none` sits mid-enum and SDL's thumb buttons are X1/X2
    // rather than a continuation of the first three, so arithmetic on the
    // index produces the wrong button rather than an error.
    assert(toButton(SDL_BUTTON_LEFT) == PointerButton.left);
    assert(toButton(SDL_BUTTON_MIDDLE) == PointerButton.middle);
    assert(toButton(SDL_BUTTON_RIGHT) == PointerButton.right);
    assert(toButton(SDL_BUTTON_X1) == PointerButton.back);
    assert(toButton(SDL_BUTTON_X2) == PointerButton.forward);
    assert(toButton(99) == PointerButton.none);

    // An index cast would have made X1 `PointerButton.none`, which reads as
    // "motion" to every consumer.
    static assert(cast(int) PointerButton.none < cast(int) PointerButton.back);
}

@("ui_sdl3.events.motionCarriesItsOwnHeldButton")
@system unittest
{
    // SDL stamps the held-button mask on the motion event, so drag and move
    // are distinguished without tracking presses — the raylib peer has to.
    Sdl3Events ev;
    Recorder rec;
    const m = CellMetrics(cellW: 8, cellH: 16);

    SDL_Event motion;
    motion.type = SDL_EventType.SDL_EVENT_MOUSE_MOTION;
    motion.motion.x = 24;
    motion.motion.y = 32;
    ev.translate(motion, rec.sink, m);

    auto p = rec.only.match!((PointerEvent e) => e, _ => PointerEvent.init);
    assert(p.action == PointerAction.move);
    assert(p.button == PointerButton.none);
    assert(p.pos == Point(3, 2));

    rec.events = null;
    motion.motion.state = 1u << (SDL_BUTTON_RIGHT - 1);
    ev.translate(motion, rec.sink, m);
    p = rec.only.match!((PointerEvent e) => e, _ => PointerEvent.init);
    assert(p.action == PointerAction.drag);
    assert(p.button == PointerButton.right);
}

@("ui_sdl3.events.heldButtonPrefersThePrimary")
@safe pure nothrow @nogc unittest
{
    enum uint left = 1u << (SDL_BUTTON_LEFT - 1);
    enum uint right = 1u << (SDL_BUTTON_RIGHT - 1);

    assert(heldButton(0) == PointerButton.none);
    assert(heldButton(left) == PointerButton.left);
    assert(heldButton(right) == PointerButton.right);
    // With both down a single-pointer consumer expects the primary.
    assert(heldButton(left | right) == PointerButton.left);
}

@("ui_sdl3.events.wheelFollowsTheWebSignAndTheUsersFlipSetting")
@system unittest
{
    Sdl3Events ev;
    Recorder rec;

    SDL_Event w;
    w.type = SDL_EventType.SDL_EVENT_MOUSE_WHEEL;
    w.wheel.y = 1;              // SDL: positive is away from the user
    ev.translate(w, rec.sink, CellMetrics.init);

    // The toolkit follows the web's `deltaY`, where scrolling UP is negative.
    auto scroll = rec.only.match!((WheelEvent e) => e, _ => WheelEvent.init);
    assert(scroll.dy == -linesPerNotch);

    // A flipped wheel is SDL saying the platform already inverted it for
    // natural scrolling; undoing that here would fight the user's own setting.
    rec.events = null;
    w.wheel.direction = SDL_MouseWheelDirection.SDL_MOUSEWHEEL_FLIPPED;
    ev.translate(w, rec.sink, CellMetrics.init);
    scroll = rec.only.match!((WheelEvent e) => e, _ => WheelEvent.init);
    assert(scroll.dy == linesPerNotch);
}

@("ui_sdl3.events.subNotchWheelDeltasAccumulateRatherThanVanish")
@system unittest
{
    // A high-resolution trackpad reports fractions of a notch. Truncating each
    // to an `int` is no scroll at all, which is what `wheelSteps` exists for —
    // here to prove this producer actually routes through it.
    Sdl3Events ev;
    Recorder rec;

    SDL_Event w;
    w.type = SDL_EventType.SDL_EVENT_MOUSE_WHEEL;
    w.wheel.y = 0.4f;

    ev.translate(w, rec.sink, CellMetrics.init);
    ev.translate(w, rec.sink, CellMetrics.init);
    assert(rec.events.length == 0, "no whole notch is due yet");

    ev.translate(w, rec.sink, CellMetrics.init);
    assert(rec.only.match!((WheelEvent e) => e.dy, _ => 0) == -linesPerNotch);
}

@("ui_sdl3.events.namedKeysCoverTheVocabulary")
@safe pure nothrow @nogc unittest
{
    assert(namedKey(SDLK_UP) == Key.up);
    assert(namedKey(SDLK_PAGEDOWN) == Key.pageDown);
    assert(namedKey(SDLK_F12) == Key.f12);

    // The keypad's Enter is the same key to everything above this layer.
    assert(namedKey(SDLK_RETURN) == Key.enter);
    assert(namedKey(SDLK_KP_ENTER) == Key.enter);

    // A character key has no named form; it reaches a consumer as text.
    assert(namedKey(SDLK_A) == Key.none);
    assert(namedKey(SDLK_SPACE) == Key.none);
}

@("ui_sdl3.events.unshiftedIsTheCharacterNotTheControlCode")
@safe pure nothrow @nogc unittest
{
    // SDL3 makes this nearly free: a keycode IS the unmodified character.
    assert(unshiftedCodepoint(SDLK_A) == 'a');
    assert(unshiftedCodepoint(SDLK_SPACE) == ' ');

    // Masked keycodes spell nothing.
    assert(unshiftedCodepoint(SDLK_UP) == 0);
    assert(unshiftedCodepoint(SDLK_F1) == 0);

    // Return is keycode 13 and Backspace 8, but both already have a named
    // `Key`. Reporting a control code as "the character this key produces"
    // would have a consumer insert one — the raylib peer excludes them too.
    assert(unshiftedCodepoint(SDLK_RETURN) == 0);
    assert(unshiftedCodepoint(SDLK_BACKSPACE) == 0);
    assert(unshiftedCodepoint(SDLK_ESCAPE) == 0);
    assert(unshiftedCodepoint(SDLK_TAB) == 0);
    assert(unshiftedCodepoint(SDLK_DELETE) == 0);
}

@("ui_sdl3.events.windowEventsBecomeFocusAndResize")
@system unittest
{
    Sdl3Events ev;
    Recorder rec;

    SDL_Event e;
    e.type = SDL_EventType.SDL_EVENT_WINDOW_FOCUS_GAINED;
    ev.translate(e, rec.sink, CellMetrics.init);
    assert(rec.only.match!((FocusEvent f) => f.focused, _ => false));

    // A zero size means "re-query", matching the raylib peer and a terminal's
    // resize signal. It is the PIXEL size event, not `SDL_EVENT_WINDOW_RESIZED`
    // — the latter is logical units, which are not pixels under scaling.
    rec.events = null;
    e.type = SDL_EventType.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED;
    ev.translate(e, rec.sink, CellMetrics.init);
    assert(rec.only.match!((ResizeEvent r) => true, _ => false));

    rec.events = null;
    e.type = SDL_EventType.SDL_EVENT_WINDOW_RESIZED;
    ev.translate(e, rec.sink, CellMetrics.init);
    assert(rec.events.length == 0, "logical-unit resizes are not the pixel size");
}

@("ui_sdl3.events.leaveReportsWhereThePointerLastWas")
@system unittest
{
    // The leave event carries no position of its own, and a consumer that
    // reads `pos` should not see whatever `Point.init` happens to be.
    Sdl3Events ev;
    Recorder rec;
    const m = CellMetrics(cellW: 10, cellH: 10);

    ev.translate(mouseButtonOf(SDL_BUTTON_LEFT, down: true, 35, 45), rec.sink, m);
    rec.events = null;

    SDL_Event leave;
    leave.type = SDL_EventType.SDL_EVENT_WINDOW_MOUSE_LEAVE;
    ev.translate(leave, rec.sink, m);

    const p = rec.only.match!((PointerEvent e) => e, _ => PointerEvent.init);
    assert(p.action == PointerAction.leave);
    assert(p.pos == Point(3, 4));
}
