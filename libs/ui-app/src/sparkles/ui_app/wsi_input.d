/**
The native arm's input adapter (WSI `INT5`): `sparkles:wsi`'s lossless window
events in, the toolkit's `sparkles:input` events out, translated once, here.

The WSI vocabulary keeps everything a platform said — physical and logical
keys, logical and physical positions, scroll sources and phases, text by
handle. An application sees the smaller vocabulary every target shares, in
cells, and must not be able to tell which target produced it. So this
produces what the raylib arm's synthesizer produces from the same input:

$(UL
    $(LI $(B Positions) are device pixels divided by the cell (`cellW`,
    `cellH`), floored; a host that reports pixels (`PointerUnit.pixels`)
    passes a 1×1 cell.)
    $(LI $(B Pointer) phases map to press, release, move, drag and leave; a
    move with a button held is a drag of the first button held.)
    $(LI $(B Scrolls) follow the web's signs, as the WSI's already do. A
    wheel's notches become `linesPerNotch` cells each; a continuous source's
    distance becomes cells at the cell size, accumulated until whole, marked
    `precise`, its fractions on `fdx`/`fdy` when asked for.)
    $(LI $(B Keys) come in the two grades `INP16` names. The default grade is
    the classic stream: named keys press and repeat; typed text arrives as
    character events, never while Ctrl, Alt or Super is held; a printable key
    under those modifiers is a character event of its unshifted code point.
    The terminal grade (`capabilities.keyRelease`) reports every key's press,
    repeat and release with its unshifted code point, and pairs the text a
    keystroke typed onto it — the WSI delivers that text as the next event —
    so a pty encoder knows which stroke produced it (`INP15`).)
    $(LI $(B Window state): a ready or resized surface is a `ResizeEvent` with
    a zero size, which the host fills in; focus is a `FocusEvent`.)
)

Named keys are read from the platform's logical key code: an xkb keysym on
Wayland and X11, a virtual-key code on Win32. macOS keeps the raylib arm.
*/
module sparkles.ui_app.wsi_input;

version (UiAppGuiVulkan):

import core.time : MonoTime, msecs;

import sparkles.base.pool.text_pool : retain;
import sparkles.base.text.utf : decodeToken, UtfMode;
import sparkles.input;
import sparkles.wsi.events : CloseRequestedEvent, FocusChangedEvent, KeyboardEvent,
    LogicalKeyKind, PointerPhase, ReadyEvent, ScrollEvent, ScrollUnit,
    SurfaceMetricsChangedEvent, TextCommittedEvent, TextId, WindowEvent;
static import sparkles.wsi.events;

/// A pause longer than this between two scroll events starts a new gesture
/// (`WheelEvent.begins`).
enum scrollGesturePause = 300.msecs;

/**
The adapter's state across events: the buttons held, the scroll remainder,
and — on the terminal grade — a keystroke waiting for its text. One per
window.
*/
struct WsiInput
{
    /// What the window offers; `keyRelease` selects the terminal grade.
    InputCapabilities capabilities = mousePointer;

    /// Deliver every scroll with its exact distance (`RunConfig.fractionalScroll`).
    bool fractionalScroll;

    /// Physical pixels per logical unit, from the surface's metrics: what a
    /// scroll measured in logical units is scaled by.
    double scale = 1;

    private Mods mods_;
    private bool[PointerButton.max + 1] held_;
    private float scrollX_ = 0, scrollY_ = 0;
    private MonoTime lastScroll_;
    private bool scrolled_;
    private KeyEvent pending_;
    private bool hasPending_;
    private InputTextPool* texts_;
    private sparkles.input.events.TextId[] issued_;
    private bool drained_;

    /// The modifiers the last event reported held (`HST17`).
    Mods modifiers() const @safe pure nothrow @nogc => mods_;

    /**
    Delivers to `sink` the input events `event` translates to, positions in
    cells of `cellW`×`cellH` pixels. `wsi` reads the text an event names; it
    is called during the drain that delivered `event`.
    */
    void translate(Wsi, Sink)(ref Wsi wsi, in WindowEvent event, int cellW, int cellH,
        scope Sink sink)
    {
        import sparkles.wsi.events : match;

        // The previous drain's preedits stop resolving as this one starts.
        if (drained_)
        {
            foreach (id; issued_)
                cast(void) texts.release(id);
            issued_.length = 0;
            drained_ = false;
        }

        // A keystroke waits only for the text that immediately follows it.
        if (hasPending_ && !isText(event))
            flush(sink);

        event.payload.match!(
            (in ReadyEvent r) { scale = r.metrics.scale.value; sink(Event(ResizeEvent())); },
            (in SurfaceMetricsChangedEvent m)
            {
                scale = m.metrics.scale.value;
                sink(Event(ResizeEvent()));
            },
            (in FocusChangedEvent f)
            {
                if (!f.focused)
                    held_[] = false;
                sink(Event(FocusEvent(f.focused)));
            },
            (in sparkles.wsi.events.PointerEvent p) { pointer(p, cellW, cellH, sink); },
            (in ScrollEvent s) { scroll(s, event.timestamp, cellW, cellH, sink); },
            (in KeyboardEvent k) { key(k, sink); },
            (in TextCommittedEvent t)
            {
                // Copied out: the WSI reads text only through a `@safe`
                // callback, and the sink is the application's.
                string text;
                cast(void) wsi.withText(t.text, (scope const(char)[] s, bool) @safe {
                    text = s.idup;
                });
                typed(text, sink);
            },
            (in sparkles.wsi.events.CompositionEvent c)
            {
                // `EDI7`: the preedit leaves the WSI's queue for this
                // adapter's pool, where it resolves until the next drain.
                sparkles.input.events.TextId preedit;
                if (c.preedit != TextId.init)
                {
                    auto kept = retain(wsi, c.preedit, texts);
                    if (!kept.hasValue)
                        return; // stale or full: the next update replaces it
                    preedit = kept.value;
                    issued_ ~= preedit;
                }
                sink(Event(inputComposition(c, preedit)));
            },
            (in _) {},
        );
    }

    /**
    The pool this adapter's `CompositionEvent`s name their preedits in
    (`INP24`): read one here before the next drain begins.
    */
    ref InputTextPool texts() return @safe
    {
        if (texts_ is null)
            texts_ = new InputTextPool;
        return *texts_;
    }

    /**
    The end of a drain: delivers a keystroke still waiting for text, as
    `flush` does, and lets go of this drain's preedits, which stop resolving
    when the next drain starts.
    */
    void endDrain(Sink)(scope Sink sink)
    {
        flush(sink);
        drained_ = true;
    }

    /// Delivers a keystroke still waiting for text. The host calls it at the
    /// end of every drain.
    void flush(Sink)(scope Sink sink)
    {
        if (!hasPending_)
            return;
        hasPending_ = false;
        sink(Event(pending_));
    }

    private static bool isText(in WindowEvent event)
    {
        import sparkles.wsi.events : match;

        return event.payload.match!((in TextCommittedEvent _) => true, (in _) => false);
    }

    private void pointer(Sink)(in sparkles.wsi.events.PointerEvent p, int cellW, int cellH,
        scope Sink sink)
    {
        mods_ = p.modifiers;
        const pos = cellAt(p.physicalPosition.x, p.physicalPosition.y, cellW, cellH);
        final switch (p.phase)
        {
            case PointerPhase.entered:
                break;
            case PointerPhase.left:
                sink(Event(PointerEvent(action: PointerAction.leave, pos: pos)));
                break;
            case PointerPhase.pressed:
                held_[p.button] = true;
                sink(Event(PointerEvent(action: PointerAction.press, button: p.button, pos: pos,
                    mods: p.modifiers)));
                break;
            case PointerPhase.released:
                held_[p.button] = false;
                sink(Event(PointerEvent(action: PointerAction.release, button: p.button,
                    pos: pos, mods: p.modifiers)));
                break;
            case PointerPhase.moved:
                const button = firstHeld();
                sink(Event(PointerEvent(
                    action: button == PointerButton.none ? PointerAction.move : PointerAction.drag,
                    button: button, pos: pos, mods: p.modifiers)));
                break;
        }
    }

    // The first button held, in the order the raylib arm checks them.
    private PointerButton firstHeld() const
    {
        foreach (b; [PointerButton.left, PointerButton.middle, PointerButton.right,
                PointerButton.back, PointerButton.forward])
            if (held_[b])
                return b;
        return PointerButton.none;
    }

    private void scroll(Sink)(in ScrollEvent s, MonoTime at, int cellW, int cellH,
        scope Sink sink)
    {
        import sparkles.wsi.events : ScrollPhase;

        mods_ = s.modifiers;
        const pos = cellAt(s.physicalPosition.x, s.physicalPosition.y, cellW, cellH);
        const begins = s.phase == ScrollPhase.began || !scrolled_
            || (s.phase == ScrollPhase.none && at - lastScroll_ > scrollGesturePause);
        scrolled_ = true;
        lastScroll_ = at;

        if (s.discreteX != 0 || s.discreteY != 0)
        {
            // A wheel: whole notches, `linesPerNotch` cells each (`INP12`).
            const dx = s.discreteX * linesPerNotch, dy = s.discreteY * linesPerNotch;
            sink(Event(WheelEvent(dx: dx, dy: dy, pos: pos, mods: s.modifiers, begins: begins,
                fdx: fractionalScroll ? dx : 0, fdy: fractionalScroll ? dy : 0)));
            return;
        }

        // A continuous source: its distance in pixels, then cells.
        const toPixels = s.unit == ScrollUnit.logical ? scale : 1.0;
        const fx = cast(float)(s.dx * toPixels / cellW);
        const fy = cast(float)(s.dy * toPixels / cellH);
        scrollX_ += fx;
        scrollY_ += fy;
        const dx = cast(int) scrollX_, dy = cast(int) scrollY_;
        scrollX_ -= dx;
        scrollY_ -= dy;
        const moved = fx != 0 || fy != 0;
        if (fractionalScroll ? moved : dx != 0 || dy != 0)
            sink(Event(WheelEvent(dx: dx, dy: dy, pos: pos, mods: s.modifiers, precise: true,
                fdx: fractionalScroll ? fx : 0, fdy: fractionalScroll ? fy : 0, begins: begins)));
    }

    private void key(Sink)(in KeyboardEvent k, scope Sink sink)
    {
        mods_ = k.modifiers;
        const named = namedKey(k.logical);
        const unshifted = k.logical.kind == LogicalKeyKind.character ? k.logical.character : 0;

        if (capabilities.keyRelease)
        {
            if (named == Key.none && unshifted == 0)
                return;
            auto e = KeyEvent(key: named != Key.none ? named : Key.char_, ch: 0,
                mods: k.modifiers, action: k.action, unshifted: unshifted);
            if (k.action == KeyAction.release)
                return sink(Event(e));
            // Held for the text the stroke typed, which comes next.
            pending_ = e;
            hasPending_ = true;
            return;
        }

        if (k.action == KeyAction.release || isModifier(named))
            return;
        if (named != Key.none)
            return sink(keyEvent(named, k.modifiers, k.action));
        // A printable key types text, unless a modifier made it a command:
        // then it is the command's character, unshifted (Ctrl+C, Super+C).
        if (k.action == KeyAction.press && unshifted != 0
            && (k.modifiers.ctrl || k.modifiers.alt || k.modifiers.super_))
            sink(Event(KeyEvent(Key.char_, unshifted, k.modifiers, KeyAction.press, unshifted)));
    }

    private void typed(Sink)(scope const(char)[] text, scope Sink sink)
    {
        // Text a command keystroke produced (a control character, or Alt's
        // letter) is the command's, not typing.
        if (mods_.ctrl || mods_.alt || mods_.super_)
        {
            if (hasPending_)
                flush(sink);
            return;
        }
        if (hasPending_)
        {
            if (text.length <= maxKeyText)
            {
                pending_.text = text;
                dchar only;
                if (singleCodePoint(text, only))
                    pending_.ch = only;
                flush(sink);
                return;
            }
            flush(sink);
        }
        for (size_t at; at < text.length;)
        {
            const decoded = decodeToken(text[at .. $], UtfMode.replacement);
            at += decoded.result.consumed;
            const cp = decoded.token.scalar;
            if (cp >= 0x20 && cp != 0x7F)
                sink(charEvent(cp, mods_));
        }
    }
}

/// The 0-based cell under device pixel `(x, y)`.
private Point cellAt(int x, int y, int cellW, int cellH) @safe pure nothrow @nogc
{
    static int floorDiv(int a, int b) => a >= 0 ? a / b : -((-a + b - 1) / b);
    return Point(floorDiv(x, cellW < 1 ? 1 : cellW), floorDiv(y, cellH < 1 ? 1 : cellH));
}

private bool singleCodePoint(scope const(char)[] text, out dchar cp) @safe pure nothrow @nogc
{
    if (!text.length)
        return false;
    const decoded = decodeToken(text, UtfMode.replacement);
    cp = decoded.token.scalar;
    return decoded.result.consumed == text.length;
}

private bool isModifier(Key k) @safe pure nothrow @nogc
    => k == Key.shift || k == Key.ctrl || k == Key.alt || k == Key.super_;

/**
The named key a platform's logical key code spells, or `Key.none` for a key
with a printable base character or one the toolkit does not name.
*/
Key namedKey(in sparkles.wsi.events.LogicalKey logical) @safe pure nothrow @nogc
{
    if (logical.kind != LogicalKeyKind.named)
        return Key.none;
    version (Windows)
        return virtualKey(logical.nativeCode);
    else
        return keysymKey(logical.nativeCode);
}

/// An xkb keysym's named key (Wayland, X11).
Key keysymKey(uint keysym) @safe pure nothrow @nogc
{
    switch (keysym)
    {
        case 0xFF08: return Key.backspace;
        case 0xFF09, 0xFE20: return Key.tab; // Tab, ISO_Left_Tab (Shift+Tab)
        case 0xFF0D, 0xFF8D: return Key.enter; // Return, KP_Enter
        case 0xFF1B: return Key.escape;
        case 0xFF50, 0xFF95: return Key.home;
        case 0xFF51, 0xFF96: return Key.left;
        case 0xFF52, 0xFF97: return Key.up;
        case 0xFF53, 0xFF98: return Key.right;
        case 0xFF54, 0xFF99: return Key.down;
        case 0xFF55, 0xFF9A: return Key.pageUp;
        case 0xFF56, 0xFF9B: return Key.pageDown;
        case 0xFF57, 0xFF9C: return Key.end;
        case 0xFF63, 0xFF9E: return Key.insert;
        case 0xFFFF, 0xFF9F: return Key.delete_;
        case 0xFF67: return Key.menu;
        case 0xFFE1, 0xFFE2: return Key.shift;
        case 0xFFE3, 0xFFE4: return Key.ctrl;
        case 0xFFE7, 0xFFE8, 0xFFE9, 0xFFEA: return Key.alt; // Meta, Alt
        case 0xFFEB, 0xFFEC: return Key.super_;
        default:
            return keysym >= 0xFFBE && keysym <= 0xFFC9 ? cast(Key)(Key.f1 + (keysym - 0xFFBE))
                : Key.none;
    }
}

/// A Win32 virtual-key code's named key.
Key virtualKey(uint vk) @safe pure nothrow @nogc
{
    switch (vk)
    {
        case 0x08: return Key.backspace;
        case 0x09: return Key.tab;
        case 0x0D: return Key.enter;
        case 0x1B: return Key.escape;
        case 0x21: return Key.pageUp;
        case 0x22: return Key.pageDown;
        case 0x23: return Key.end;
        case 0x24: return Key.home;
        case 0x25: return Key.left;
        case 0x26: return Key.up;
        case 0x27: return Key.right;
        case 0x28: return Key.down;
        case 0x2D: return Key.insert;
        case 0x2E: return Key.delete_;
        case 0x5D: return Key.menu;
        case 0x10, 0xA0, 0xA1: return Key.shift;
        case 0x11, 0xA2, 0xA3: return Key.ctrl;
        case 0x12, 0xA4, 0xA5: return Key.alt;
        case 0x5B, 0x5C: return Key.super_;
        default:
            return vk >= 0x70 && vk <= 0x7B ? cast(Key)(Key.f1 + (vk - 0x70)) : Key.none;
    }
}

/**
A window system's composition as the toolkit's (`EDI7`, `INP24`), its
preedit already re-interned as `preedit`.

Styles map one to one. A selection that no segment marks becomes a
`selected` run: Wayland's text-input-v3 reports its cursor span only as the
selection, beside a whole-preedit underline. Of more segments than
`maxCompositionRuns`, the first are kept, and a `selected` one always.
*/
CompositionEvent inputComposition(in sparkles.wsi.events.CompositionEvent c,
    sparkles.input.events.TextId preedit) @safe pure nothrow @nogc
{
    import sparkles.wsi.events : CompositionSegmentStyle;

    static CompositionStyle styleOf(CompositionSegmentStyle s)
    {
        final switch (s)
        {
            case CompositionSegmentStyle.none: return CompositionStyle.none;
            case CompositionSegmentStyle.underline: return CompositionStyle.underline;
            case CompositionSegmentStyle.selected: return CompositionStyle.selected;
            case CompositionSegmentStyle.converted: return CompositionStyle.converted;
        }
    }

    CompositionEvent result;
    if (!preedit.valid)
        return result;
    result.preedit = preedit;
    result.cursor = c.cursor;

    CompositionRun[c.segments.length + 1] all;
    ubyte count;
    bool marked;
    foreach (s; c.segments[0 .. c.segmentCount])
    {
        all[count++] = CompositionRun(s.start, s.length, styleOf(s.style));
        marked = marked || s.style == CompositionSegmentStyle.selected;
    }
    if (!marked && c.selectionLength)
        all[count++] = CompositionRun(c.selectionStart, c.selectionLength,
            CompositionStyle.selected);

    bool keptSelected;
    foreach (run; all[0 .. count])
    {
        if (result.runCount < result.runs.length)
        {
            result.runs[result.runCount++] = run;
            keptSelected = keptSelected || run.style == CompositionStyle.selected;
        }
        else if (run.style == CompositionStyle.selected && !keptSelected)
        {
            result.runs[$ - 1] = run;
            keptSelected = true;
        }
    }
    return result;
}

// ── tests ─────────────────────────────────────────────────────────────────────

version (unittest)
{
    import sparkles.wsi.events : LogicalKey, PhysicalKey, ScrollPhase, ScrollSource,
        WindowEventPayload;
    import sparkles.wsi.types : LogicalPosition, PhysicalPosition, WindowId;

    // A WSI's text: the ids are indices into `texts`.
    private struct FakeTexts
    {
        string[] texts;

        auto withText(Fn)(TextId id, scope Fn fn)
        {
            import sparkles.wsi.types : wsiOk;

            fn(texts[id.index], false);
            return wsiOk();
        }
    }

    // Everything `events` translate to, in order, the drain flushed after.
    private Event[] translated(ref WsiInput input, ref FakeTexts wsi, WindowEvent[] events,
        int cellW = 10, int cellH = 20)
    {
        Event[] got;
        foreach (e; events)
            input.translate(wsi, e, cellW, cellH, (Event x) { got ~= x; });
        input.flush((Event x) { got ~= x; });
        return got;
    }

    private WindowEvent ev(P)(P payload, MonoTime at = MonoTime.init)
    {
        WindowEvent e;
        e.window = WindowId(0, 1);
        e.payload = WindowEventPayload(payload);
        e.timestamp = at;
        return e;
    }

    private sparkles.wsi.events.PointerEvent ptr(PointerPhase phase, int x, int y,
        PointerButton button = PointerButton.none, Mods mods = Mods.init)
    {
        sparkles.wsi.events.PointerEvent p;
        p.phase = phase;
        p.button = button;
        p.physicalPosition = PhysicalPosition(x, y);
        p.modifiers = mods;
        return p;
    }

    private KeyboardEvent keysym(uint sym, KeyAction action = KeyAction.press,
        Mods mods = Mods.init)
        => KeyboardEvent(PhysicalKey.init, LogicalKey(LogicalKeyKind.named, 0, sym),
            action: action, modifiers: mods);

    private KeyboardEvent letter(dchar c, KeyAction action = KeyAction.press,
        Mods mods = Mods.init)
        => KeyboardEvent(PhysicalKey.init, LogicalKey(LogicalKeyKind.character, c, c),
            action: action, modifiers: mods);

    private TextCommittedEvent textNo(uint i)
        => TextCommittedEvent(TextId(i, 1));
}

@("ui_app.wsi_input.pointerPhasesInCells")
@system unittest
{
    WsiInput input;
    FakeTexts wsi;
    const got = translated(input, wsi, [
        ev(ptr(PointerPhase.entered, 5, 5)),
        ev(ptr(PointerPhase.moved, 25, 45)),
        ev(ptr(PointerPhase.pressed, 25, 45, PointerButton.left)),
        ev(ptr(PointerPhase.moved, 39, 61)),
        ev(ptr(PointerPhase.released, 39, 61, PointerButton.left)),
        ev(ptr(PointerPhase.left, -3, 61)),
    ]);
    assert(got == [
        Event(PointerEvent(action: PointerAction.move, pos: Point(2, 2))),
        Event(PointerEvent(action: PointerAction.press, button: PointerButton.left, pos: Point(2, 2))),
        Event(PointerEvent(action: PointerAction.drag, button: PointerButton.left, pos: Point(3, 3))),
        Event(PointerEvent(action: PointerAction.release, button: PointerButton.left, pos: Point(3, 3))),
        Event(PointerEvent(action: PointerAction.leave, pos: Point(-1, 3))),
    ], "the entry is silent; a negative pixel floors to a negative cell");
}

@("ui_app.wsi_input.pixelsWithAOneByOneCell")
@system unittest
{
    // `PointerUnit.pixels`: the host passes a 1×1 cell.
    WsiInput input;
    FakeTexts wsi;
    assert(translated(input, wsi, [ev(ptr(PointerPhase.moved, 25, 45))], 1, 1)
        == [Event(PointerEvent(action: PointerAction.move, pos: Point(25, 45)))]);
}

@("ui_app.wsi_input.wheelNotchesAndContinuousScrolls")
@system unittest
{
    import core.time : seconds;

    WsiInput input;
    FakeTexts wsi;
    ScrollEvent notch;
    notch.physicalPosition = PhysicalPosition(15, 25);
    notch.discreteY = 1;
    notch.dx = 0;
    notch.dy = 15;
    const t0 = MonoTime.currTime;
    auto got = translated(input, wsi, [ev(notch, t0), ev(notch, t0 + 50.msecs),
        ev(notch, t0 + 1.seconds)]);
    assert(got == [
        Event(WheelEvent(dy: 3, pos: Point(1, 1), begins: true)),
        Event(WheelEvent(dy: 3, pos: Point(1, 1))),
        Event(WheelEvent(dy: 3, pos: Point(1, 1), begins: true)),
    ], "linesPerNotch cells a notch; a pause begins a new gesture");

    // A touchpad: logical units at scale 2, cells of 20 px: 4 logical units
    // are 8 px, so the third event completes a cell.
    ScrollEvent pad;
    pad.source = ScrollSource.finger;
    pad.unit = ScrollUnit.logical;
    pad.dx = 0; // a backend sets both axes; a double defaults to NaN
    pad.dy = 4;
    pad.phase = ScrollPhase.began;
    WsiInput precise;
    precise.scale = 2;
    got = translated(precise, wsi, [ev(pad)]);
    assert(got.length == 0, "under a cell: nothing yet");
    pad.phase = ScrollPhase.changed;
    got = translated(precise, wsi, [ev(pad), ev(pad)]);
    assert(got == [Event(WheelEvent(dy: 1, pos: Point(0, 0), precise: true))]);

    // Asked for fractions, every movement arrives.
    WsiInput fractional;
    fractional.fractionalScroll = true;
    fractional.scale = 2;
    pad.phase = ScrollPhase.began;
    got = translated(fractional, wsi, [ev(pad)]);
    assert(got == [Event(WheelEvent(dy: 0, pos: Point(0, 0), precise: true, fdy: 0.4f,
        begins: true))]);
}

@("ui_app.wsi_input.classicKeysAndTypedText")
@system unittest
{
    WsiInput input;
    auto wsi = FakeTexts(["a", "\x03", "é"]);
    const ctrl = Mods(ctrl: true);
    const got = translated(input, wsi, [
        ev(keysym(0xFF52)),                                  // Up
        ev(keysym(0xFF52, KeyAction.repeat)),
        ev(keysym(0xFF52, KeyAction.release)),               // classic: no releases
        ev(keysym(0xFFE3, KeyAction.press, ctrl)),           // a modifier alone: nothing
        ev(letter('a')), ev(textNo(0)),                      // typing
        ev(letter('c', KeyAction.press, ctrl)), ev(textNo(1)), // Ctrl+C: the command, not ^C
        ev(keysym(0xFFE3, KeyAction.release)),
        ev(letter('e')), ev(textNo(2)),                      // a dead key's composed é
        ev(keysym(0xFFC1)),                                  // F4
    ]);
    // The release of Ctrl reports no modifiers held, so the é types again.
    assert(got == [
        keyEvent(Key.up),
        keyEvent(Key.up, Mods.init, KeyAction.repeat),
        charEvent('a'),
        Event(KeyEvent(Key.char_, 'c', ctrl, KeyAction.press, 'c')),
        charEvent('é'),
        keyEvent(Key.f4),
    ]);
}

@("ui_app.wsi_input.terminalGradePairsTextOntoTheStroke")
@system unittest
{
    WsiInput input;
    input.capabilities.keyRelease = true;
    auto wsi = FakeTexts(["a", "ab"]);
    const got = translated(input, wsi, [
        ev(letter('a')), ev(textNo(0)),
        ev(letter('a', KeyAction.release)),
        ev(keysym(0xFF0D)),                                  // Enter, typing nothing
        ev(keysym(0xFF0D, KeyAction.release)),
        ev(letter('x')), ev(textNo(1)),                      // an IME burst on one stroke
    ]);
    auto a = KeyEvent(Key.char_, 'a', Mods.init, KeyAction.press, 'a');
    a.text = "a";
    auto x = KeyEvent(Key.char_, 0, Mods.init, KeyAction.press, 'x');
    x.text = "ab";
    assert(got == [
        Event(a),
        Event(KeyEvent(Key.char_, 0, Mods.init, KeyAction.release, 'a')),
        Event(KeyEvent(Key.enter, 0, Mods.init, KeyAction.press)),
        Event(KeyEvent(Key.enter, 0, Mods.init, KeyAction.release)),
        Event(x),
    ], "a multi-code-point burst keeps `ch` 0");
}

@("ui_app.wsi_input.windowStateAndFocus")
@system unittest
{
    import sparkles.wsi.types : SurfaceMetrics;

    WsiInput input;
    FakeTexts wsi;
    WsiInput pressed;
    const got = translated(input, wsi, [
        ev(ReadyEvent(SurfaceMetrics.init)),
        ev(ptr(PointerPhase.pressed, 0, 0, PointerButton.left)),
        ev(FocusChangedEvent(false)),
        ev(ptr(PointerPhase.moved, 0, 0)),
        ev(CloseRequestedEvent()),
    ]);
    assert(got == [
        Event(ResizeEvent()),
        Event(PointerEvent(action: PointerAction.press, button: PointerButton.left)),
        Event(FocusEvent(false)),
        Event(PointerEvent(action: PointerAction.move)),
    ], "losing focus lets go of the buttons; a close request is the host's");
}

@("ui_app.wsi_input.namedKeysPerPlatform")
@safe pure nothrow @nogc unittest
{
    assert(keysymKey(0xFFBE) == Key.f1 && keysymKey(0xFFC9) == Key.f12);
    assert(keysymKey(0xFE20) == Key.tab && keysymKey(0xFF9F) == Key.delete_);
    assert(keysymKey(0x61) == Key.none);
    assert(virtualKey(0x70) == Key.f1 && virtualKey(0x26) == Key.up && virtualKey(0x41) == Key.none);
}

version (unittest)
{
    import sparkles.wsi.events : CompositionSegment, CompositionSegmentStyle;

    alias WsiComposition = sparkles.wsi.events.CompositionEvent;

    // What each backend emits while composing にほん with ほん the clause
    // being converted, its preedit text id 0 — recorded from each mapping:
    // Wayland's `compositionFromPreedit`, AppKit's `appKitComposition`,
    // Win32's `emitComposition` over IMM32 clause attributes.
    private WsiComposition recorded(string backend)
    {
        WsiComposition c;
        c.preedit = TextId(0, 1);
        c.cursor = 3;
        c.selectionStart = 3;
        c.selectionLength = 6;
        final switch (backend)
        {
            case "wayland": // the cursor span, beside a whole underline
                c.segments[0] = CompositionSegment(0, 9, CompositionSegmentStyle.underline);
                c.segmentCount = 1;
                break;
            case "appkit": // the selection also marked as a segment
                c.segments[0] = CompositionSegment(0, 9, CompositionSegmentStyle.underline);
                c.segments[1] = CompositionSegment(3, 6, CompositionSegmentStyle.selected);
                c.segmentCount = 2;
                break;
            case "win32": // one segment per IMM32 clause
                c.segments[0] = CompositionSegment(0, 3, CompositionSegmentStyle.converted);
                c.segments[1] = CompositionSegment(3, 6, CompositionSegmentStyle.selected);
                c.segmentCount = 2;
                break;
        }
        return c;
    }
}

version (linux)
@("ui_app.wsi_input.waylandRecordingMatchesItsMapping")
@safe unittest
{
    import sparkles.wsi.platform.wayland : compositionFromPreedit;

    auto mapped = compositionFromPreedit("にほん", 3, 9);
    mapped.preedit = TextId(0, 1);
    assert(mapped == (() @trusted => recorded("wayland"))());
}

@("ui_app.wsi_input.compositionFromEachBackend")
@system unittest
{
    // `EDI7`: every backend's composition reaches the toolkit in one shape;
    // its preedit resolves in the adapter's pool until the next drain, and
    // the commit arrives as typed text.
    foreach (backend; ["wayland", "appkit", "win32"])
    {
        WsiInput input;
        auto wsi = FakeTexts(["にほん", "日本"]);
        Event[] got;
        foreach (e; [ev(recorded(backend)), ev(textNo(1)), ev(WsiComposition.init)])
            input.translate(wsi, e, 10, 20, (Event x) { got ~= x; });

        assert(got.length == 4, backend);
        const update = got[0].match!((CompositionEvent c) => c, _ => CompositionEvent.init);
        assert(update.cursor == 3, backend);
        const style = backend == "win32" ? CompositionStyle.converted : CompositionStyle.underline;
        const width = backend == "win32" ? 3 : 9;
        assert(update.runs[0 .. update.runCount] == [CompositionRun(0, cast(ushort) width, style),
            CompositionRun(3, 6, CompositionStyle.selected)], backend);
        string preedit;
        input.texts.withText(update.preedit, (scope const(char)[] s) { preedit = s.idup; });
        assert(preedit == "にほん", backend);
        assert(got[1] == Event(KeyEvent(Key.char_, '日')) && got[2] == Event(KeyEvent(Key.char_, '本')),
            backend);
        assert(got[3].match!((CompositionEvent c) => c.ends, _ => false), backend);

        input.endDrain((Event x) { got ~= x; });
        input.translate(wsi, ev(WsiComposition.init), 10, 20, (Event x) {});
        assert(input.texts.withText(update.preedit, (scope const(char)[] s) {}).hasError,
            "the preedit stops resolving when the next drain starts");
    }
}

@("ui_app.wsi_input.compositionKeepsTheSelectedRun")
@safe pure nothrow @nogc
unittest
{
    // More segments than the toolkit carries: the selected one survives.
    WsiComposition c;
    foreach (i; 0 .. 6)
        c.segments[i] = CompositionSegment(cast(ushort) i, 1, i == 5
            ? CompositionSegmentStyle.selected : CompositionSegmentStyle.underline);
    c.segmentCount = 6;
    const converted = inputComposition(c, sparkles.input.events.TextId(0, 1));
    assert(converted.runCount == 4);
    assert(converted.runs[3] == CompositionRun(5, 1, CompositionStyle.selected));
}
