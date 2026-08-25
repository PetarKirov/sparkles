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

import sparkles.base.meta : isVersion;
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

/// Distinguishes modifier keys from general keys.
enum KeyRole : ubyte
{
    key,
    modifier,
}

/// Explicit primary wire/text name for an enum member or field.
struct WireName
{
    string name;
}

/// Explicit secondary/alias wire/text names for an enum member or field.
struct WireAliases
{
    string[] names;
    this(Args...)(Args args) if (Args.length > 0)
    {
        this.names = [args];
    }
}

/// Explicit UI display name for an enum member.
struct WireDisplayName
{
    string name;
}

/// Canonical Unicode symbols representing a key.
struct KeySymbols
{
    string[] symbols;
    this(Args...)(Args args) if (Args.length > 0)
    {
        this.symbols = [args];
    }
}

/// A decoded key. `char_` carries a printable code point in `KeyEvent.ch`; the
/// rest are named keys.
enum Key : ubyte
{
    none, char_,
    @WireName("up")        @WireDisplayName("Up")   @KeySymbols("↑") up,
    @WireName("down")      @WireDisplayName("Down") @KeySymbols("↓") down,
    @WireName("left")      @WireDisplayName("Left") @KeySymbols("←") left,
    @WireName("right")     @WireDisplayName("Right")@KeySymbols("→") right,
    @WireName("home")      @WireDisplayName("Home") @KeySymbols("↖") home,
    @WireName("end")       @WireDisplayName("End")  @KeySymbols("↘") end,
    @WireName("pageup")    @WireAliases("pgup")     @WireDisplayName("PgUp") @KeySymbols("⇞") pageUp,
    @WireName("pagedown")  @WireAliases("pgdn")     @WireDisplayName("PgDn") @KeySymbols("⇟") pageDown,
    @WireName("insert")    @WireAliases("ins")      @WireDisplayName("Ins")  insert,
    @WireName("delete")    @WireAliases("del")      @WireDisplayName("Del")  @KeySymbols("⌦") delete_,
    @WireName("enter")     @WireAliases("return")   @WireDisplayName("↵")    @KeySymbols("⏎", "↩", "↵", "⌤") enter,
    @WireName("tab")                                @WireDisplayName("⇥")    @KeySymbols("⇥") tab,
    @WireName("backspace")                          @WireDisplayName("⌫")    @KeySymbols("⌫") backspace,
    @WireName("escape")    @WireAliases("esc")      @WireDisplayName("Esc")  @KeySymbols("⎋") escape,

    @WireName("f1")  @WireDisplayName("F1")  f1,
    @WireName("f2")  @WireDisplayName("F2")  f2,
    @WireName("f3")  @WireDisplayName("F3")  f3,
    @WireName("f4")  @WireDisplayName("F4")  f4,
    @WireName("f5")  @WireDisplayName("F5")  f5,
    @WireName("f6")  @WireDisplayName("F6")  f6,
    @WireName("f7")  @WireDisplayName("F7")  f7,
    @WireName("f8")  @WireDisplayName("F8")  f8,
    @WireName("f9")  @WireDisplayName("F9")  f9,
    @WireName("f10") @WireDisplayName("F10") f10,
    @WireName("f11") @WireDisplayName("F11") f11,
    @WireName("f12") @WireDisplayName("F12") f12,

    @WireName("back") @WireDisplayName("Back") back,
    @WireName("menu") @WireDisplayName("Menu") menu,

    @WireName("ctrl")
    @WireAliases("control")
    @WireDisplayName("Ctrl")
    @KeySymbols("⌃", "⎈")
    @(KeyRole.modifier)
    ctrl,

    @WireName("alt")
    @WireAliases("opt", "option", "meta")
    @WireDisplayName(isVersion!"Apple" ? "Option" : "Alt")
    @KeySymbols("⌥", "⎇")
    @(KeyRole.modifier)
    alt,

    @WireName("shift")
    @WireAliases("Shift")
    @WireDisplayName("Shift")
    @KeySymbols("⇧")
    @(KeyRole.modifier)
    shift,

    @WireName("super")
    @WireAliases("Super", "Command", "Cmd", "WinKey", "win", "windows")
    @WireDisplayName(isVersion!"Apple" ? "Cmd" : "Super")
    @KeySymbols("⌘", "")
    @(KeyRole.modifier)
    super_,
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

/// The platform-idiomatic name for the `super_` modifier key ("Cmd" on Apple, "Super" elsewhere).
enum string superModifierName = isVersion!"Apple" ? "Cmd" : "Super";

/// The platform-idiomatic name for the `alt` modifier key ("Option" on Apple, "Alt" elsewhere).
enum string altModifierName = isVersion!"Apple" ? "Option" : "Alt";

/// Whether a binding cares about Shift.
enum ShiftReq : ubyte
{
    ignore, /// Shift is not part of the binding
    no,     /// binds only when Shift is not held
    yes,    /// binds only when Shift is held
}

/// The longest binding path a sequence/table may hold.
enum maxPathLength = 3;

/// One key in a binding's path.
struct Chord
{
    Key key = Key.none;
    dchar ch = 0;    /// the code point, when `key == Key.char_`
    dchar chEnd = 0; /// inclusive range end; `0` for a single code point
    ShiftReq shift;
    bool ctrl;
    bool alt;
    bool super_;
}

/// A `char_` chord.
Chord chord(dchar ch, ShiftReq shift = ShiftReq.ignore) @safe pure nothrow @nogc
    => Chord(key: Key.char_, ch: ch, shift: shift);

/// A named-key chord.
Chord chord(Key key, ShiftReq shift = ShiftReq.ignore) @safe pure nothrow @nogc
    => Chord(key: key, shift: shift);

/// A `char_` chord spanning `lo`..`hi` inclusive.
Chord chordRange(dchar lo, dchar hi) @safe pure nothrow @nogc
    => Chord(key: Key.char_, ch: lo, chEnd: hi);

/// A binding path in its typed form; the wire form is the space-separated chord string.
struct ChordPath
{
    Chord[maxPathLength] path;
    ubyte depth = 1;
}

/// Checks whether `k` represents a modifier key.
bool isModifierKey(Key k) @safe pure nothrow @nogc
{
    import std.traits : EnumMembers, hasUDA;
    switch (k)
    {
        static foreach (m; EnumMembers!Key)
        {
            static if (hasUDA!(__traits(getMember, Key, __traits(identifier, m)), KeyRole.modifier))
            {
                case m: return true;
            }
        }
        default: return false;
    }
}

private bool iequal(in char[] a, in char[] b) @safe pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    foreach (i; 0 .. a.length)
    {
        char ca = a[i];
        char cb = b[i];
        if (ca >= 'A' && ca <= 'Z') ca += 'a' - 'A';
        if (cb >= 'A' && cb <= 'Z') cb += 'a' - 'A';
        if (ca != cb)
            return false;
    }
    return true;
}

/// Parses a key token or symbol into a Key enum value using @WireName/@WireAliases/@KeySymbols introspection.
bool parseKey(string name, out Key key) @safe pure nothrow
{
    import std.traits : EnumMembers, getUDAs;

    static foreach (k; EnumMembers!Key)
    {
        static if (k != Key.none && k != Key.char_)
        {
            static foreach (uda; getUDAs!(__traits(getMember, Key, __traits(identifier, k)), WireName))
            {
                if (name == uda.name || (uda.name.length > 1 && iequal(name, uda.name)))
                {
                    key = k;
                    return true;
                }
            }
            static foreach (uda; getUDAs!(__traits(getMember, Key, __traits(identifier, k)), WireAliases))
            {
                static foreach (aliasName; uda.names)
                {
                    if (name == aliasName || (aliasName.length > 1 && iequal(name, aliasName)))
                    {
                        key = k;
                        return true;
                    }
                }
            }
            static foreach (uda; getUDAs!(__traits(getMember, Key, __traits(identifier, k)), KeySymbols))
            {
                static foreach (sym; uda.symbols)
                {
                    if (name == sym)
                    {
                        key = k;
                        return true;
                    }
                }
            }
        }
    }
    return false;
}

/// Parses a single key chord string (e.g. "ctrl+c", "⌘C", "⌥+f", "⌃⌥Space", "1-9", "⎋").
bool parseChord(string text, out Chord chord, out string err, dchar leader = ' ') @safe pure
{
    import std.string : indexOf;
    import std.utf : byDchar, count;

    Chord c;
    string rest = text;

    // 1. Process '+'-separated modifier tokens
    while (true)
    {
        const plus = rest.indexOf('+');
        if (plus < 0 || plus + 1 >= rest.length)
            break; // no '+', or a trailing '+' names the '+' key itself
        const mod = rest[0 .. plus];
        Key k;
        if (parseKey(mod, k) && isModifierKey(k))
        {
            switch (k)
            {
                case Key.ctrl:   c.ctrl = true; break;
                case Key.alt:    c.alt = true; break;
                case Key.shift:  c.shift = ShiftReq.yes; break;
                case Key.super_: c.super_ = true; break;
                default: break;
            }
        }
        else
        {
            err = "unknown modifier '" ~ mod ~ "' (ctrl, cmd/super, alt/option, shift)";
            return false;
        }
        rest = rest[plus + 1 .. $];
    }

    if (!rest.length)
    {
        err = "chord names no key";
        return false;
    }

    // 2. Process leading Unicode modifier symbols without '+' (e.g. ⌃⌥⇧⌘Q)
    while (rest.length > 0)
    {
        import std.utf : decode;
        size_t idx = 0;
        const dchar cp = rest.decode(idx);
        if (cp == '⌃' || cp == '⎈')
        {
            c.ctrl = true;
            rest = rest[idx .. $];
        }
        else if (cp == '⌥' || cp == '⎇')
        {
            c.alt = true;
            rest = rest[idx .. $];
        }
        else if (cp == '⇧')
        {
            c.shift = ShiftReq.yes;
            rest = rest[idx .. $];
        }
        else if (cp == '⌘' || cp == '')
        {
            c.super_ = true;
            rest = rest[idx .. $];
        }
        else
            break;
    }

    if (!rest.length)
    {
        err = "chord names no key";
        return false;
    }

    // 3. Special single-symbol mappings (e.g. ⇤ for Shift+Tab, ␣ for leader)
    if (rest == "⇤")
    {
        c.key = Key.tab;
        c.shift = ShiftReq.yes;
        chord = c;
        return true;
    }
    if (rest == "␣" || rest == "space" || rest == "leader")
    {
        c.key = Key.char_;
        c.ch = leader;
        chord = c;
        return true;
    }

    // 4. Contiguous range (e.g. 1-9 or a-z)
    const units = rest.count;
    if (units == 3)
    {
        dchar[3] cp;
        size_t ci;
        foreach (d; rest.byDchar)
            cp[ci++] = d;
        if (cp[1] == '-')
        {
            if (cp[0] >= cp[2])
            {
                err = "range '" ~ rest ~ "' is not ascending";
                return false;
            }
            if (c.shift != ShiftReq.ignore)
            {
                err = "a range cannot take shift";
                return false;
            }
            c.key = Key.char_;
            c.ch = cp[0];
            c.chEnd = cp[2];
            chord = c;
            return true;
        }
    }

    // 5. Named key or symbol lookup
    Key namedKey;
    if (parseKey(rest, namedKey) && !isModifierKey(namedKey))
    {
        c.key = namedKey;
        chord = c;
        return true;
    }

    // 6. Single character
    if (units == 1)
    {
        dchar d;
        foreach (u; rest.byDchar)
            d = u;
        if (d >= 'A' && d <= 'Z')
        {
            d = d - 'A' + 'a';
            c.shift = ShiftReq.yes;
        }
        c.key = Key.char_;
        c.ch = d;
        chord = c;
        return true;
    }

    err = "unknown key '" ~ rest ~ "'";
    return false;
}

/// Returns the primary wire/text name of a Key.
string keyWireName(Key k) @safe pure nothrow @nogc
{
    import std.traits : EnumMembers, getUDAs;
    switch (k)
    {
        static foreach (m; EnumMembers!Key)
        {
            case m:
                static if (getUDAs!(__traits(getMember, Key, __traits(identifier, m)), WireName).length > 0)
                    return getUDAs!(__traits(getMember, Key, __traits(identifier, m)), WireName)[0].name;
                else
                    return __traits(identifier, m);
        }
        default:
            return "?";
    }
}

/// Unparses a Chord into canonical string form.
string unparseChord(in Chord c, dchar leader = ' ') @safe pure
{
    import std.conv : text;

    string s;
    if (c.ctrl) s ~= "ctrl+";
    if (c.alt) s ~= "alt+";
    if (c.shift == ShiftReq.yes) s ~= "shift+";
    if (c.super_) s ~= "super+";

    if (c.key == Key.char_)
    {
        if (c.ch == leader)
            s ~= "space";
        else if (c.chEnd)
            s ~= text(c.ch, "-", c.chEnd);
        else
            s ~= text(c.ch);
    }
    else
    {
        s ~= keyWireName(c.key);
    }
    return s;
}

/// Parses a space-separated sequence of chords into a ChordPath.
bool parseChordPath(string text, out ChordPath path, out string err, dchar leader = ' ') @safe pure
{
    import std.algorithm.iteration : splitter;

    ChordPath p;
    size_t n;
    foreach (part; text.splitter(' '))
    {
        if (!part.length)
        {
            err = "empty chord (double space?)";
            return false;
        }
        if (n >= maxPathLength)
        {
            err = "a binding path holds at most 3 chords";
            return false;
        }

        Chord c;
        if (!parseChord(part, c, err, leader))
            return false;

        p.path[n++] = c;
    }
    if (n == 0)
    {
        err = "empty binding path";
        return false;
    }
    p.depth = cast(ubyte) n;
    path = p;
    return true;
}

/// Unparses a ChordPath into a space-separated chord string.
string unparseChordPath(ChordPath path, dchar leader = ' ') @safe pure
{
    string s;
    foreach (i; 0 .. path.depth)
    {
        if (i > 0)
            s ~= ' ';
        s ~= unparseChord(path.path[i], leader);
    }
    return s;
}

/// Formats modifier flags into a standard prefix (e.g. "Ctrl+", "Alt+", "Shift+", "Cmd+" or "Super+").
string formatMods(in Mods m, bool trailingPlus = true) @safe pure nothrow
{
    string s;
    if (trailingPlus)
    {
        if (m.ctrl) s ~= "Ctrl+";
        if (m.alt) s ~= altModifierName ~ "+";
        if (m.shift) s ~= "Shift+";
        if (m.super_) s ~= superModifierName ~ "+";
    }
    else
    {
        if (m.ctrl) s ~= (s.length ? " ctrl" : "ctrl");
        if (m.alt) s ~= (s.length ? " " : "") ~ (altModifierName == "Option" ? "option" : "alt");
        if (m.shift) s ~= (s.length ? " shift" : "shift");
        if (m.super_) s ~= (s.length ? " " : "") ~ (superModifierName == "Cmd" ? "cmd" : "super");
    }
    return s;
}

/// Formats a key event into a descriptive string (e.g. `key Ctrl+'c'`, `key Cmd+'c'`, `key Enter`).
string describeKey(in KeyEvent e) @safe
{
    import std.conv : text;
    const m = formatMods(e.mods, true);
    if (e.key == Key.char_)
        return text("key ", m, "'", e.ch, "'");
    return text("key ", m, e.key);
}

/// ditto
string describeKey(in Event e) @safe
{
    return e.match!(
        (in KeyEvent k) => describeKey(k),
        _ => "not a key event",
    );
}

/// Returns the standard display name for a named Key (e.g. `Key.enter` -> `"↵"`, `Key.up` -> `"Up"`).
string namedKeyLabel(Key k) @safe pure nothrow @nogc
{
    import std.traits : EnumMembers, getUDAs;
    switch (k)
    {
        static foreach (m; EnumMembers!Key)
        {
            case m:
                static if (getUDAs!(__traits(getMember, Key, __traits(identifier, m)), WireDisplayName).length > 0)
                    return getUDAs!(__traits(getMember, Key, __traits(identifier, m)), WireDisplayName)[0].name;
                else
                    return "?";
        }
        default: return "?";
    }
}

/// Returns the canonical Unicode symbol for a Key.
string namedKeySymbol(Key k) @safe pure nothrow @nogc
{
    import std.traits : EnumMembers, getUDAs;
    switch (k)
    {
        static foreach (m; EnumMembers!Key)
        {
            case m:
                static if (getUDAs!(__traits(getMember, Key, __traits(identifier, m)), KeySymbols).length > 0)
                    return getUDAs!(__traits(getMember, Key, __traits(identifier, m)), KeySymbols)[0].symbols[0];
                else static if (getUDAs!(__traits(getMember, Key, __traits(identifier, m)), WireDisplayName).length > 0)
                    return getUDAs!(__traits(getMember, Key, __traits(identifier, m)), WireDisplayName)[0].name;
                else
                    return "?";
        }
        default: return "?";
    }
}

/// Formats a key chord as GitHub-Flavored Markdown `<kbd>` tags
/// (e.g. `<kbd>Ctrl</kbd> + <kbd>Option</kbd> + <kbd>Shift</kbd> + <kbd>Cmd</kbd> + <kbd>Q</kbd>`).
string formatKbdChord(in Chord c) @safe
{
    import std.conv : text;
    string s;
    void addKey(string name) {
        if (s.length)
            s ~= " + ";
        s ~= "<kbd>" ~ name ~ "</kbd>";
    }
    if (c.ctrl)
        addKey("Ctrl");
    if (c.alt)
        addKey(altModifierName);
    if (c.shift == ShiftReq.yes)
        addKey("Shift");
    if (c.super_)
        addKey(superModifierName);

    if (c.key == Key.char_)
    {
        if (c.ch == ' ')
            addKey("Space");
        else if (c.chEnd)
            addKey(text(c.ch, "-", c.chEnd));
        else
            addKey(text(c.ch));
    }
    else
        addKey(namedKeyLabel(c.key));

    return s;
}

/// Formats a key chord compactly using Mac/Unicode symbols (e.g. "⌃⌥⇧⌘Q", "⌘C", "⎋", "⇥").
string formatSymbolChord(in Chord c) @safe
{
    import std.conv : text;
    string s;
    if (c.ctrl) s ~= "⌃";
    if (c.alt) s ~= "⌥";
    if (c.shift == ShiftReq.yes) s ~= "⇧";
    if (c.super_) s ~= "⌘";

    if (c.key == Key.char_)
    {
        if (c.ch == ' ')
            s ~= "Space";
        else if (c.chEnd)
            s ~= text(c.ch, "-", c.chEnd);
        else
            s ~= text(c.ch);
    }
    else
        s ~= namedKeySymbol(c.key);

    return s;
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

/**
Folds a (possibly fractional) wheel delta into `accum` and returns the whole
steps now due, keeping the remainder.

Every pixel backend needs this and none of them can skip it: a high-resolution
wheel or trackpad reports sub-step deltas, and truncating each one to an `int`
turns a slow scroll into no scroll at all.

The unit is $(B notches), not cells — a producer multiplies the result by
$(LREF linesPerNotch) before it reaches a $(LREF WheelEvent), because the
producer owns that multiplication (`INP12`). Anything reading this directly is
one step short of a scroll distance.

Pure, so the accumulation is testable with no window in sight.
*/
int wheelSteps(ref float accum, float delta) @safe pure nothrow @nogc
{
    accum += delta;
    const steps = cast(int) accum;
    accum -= steps;
    return steps;
}

@("input.events.wheelStepsAccumulation")
@safe pure nothrow @nogc
unittest
{
    float a = 0;
    // Sub-step deltas accumulate; the whole step fires once, remainder kept.
    assert(wheelSteps(a, 0.4f) == 0);
    assert(wheelSteps(a, 0.4f) == 0);
    assert(wheelSteps(a, 0.4f) == 1);
    assert(a > 0.19f && a < 0.21f);
    // A fast flick delivers every whole step at once.
    assert(wheelSteps(a, 3.0f) == 3);
    // Opposite-direction deltas cancel the remainder first.
    float b = 0;
    assert(wheelSteps(b, -0.6f) == 0);
    assert(wheelSteps(b, -0.6f) == -1);

    // The unit is notches: one notch is `linesPerNotch` cells of scroll, and
    // the producer applies that factor. Pinned because the two conventions
    // merged from opposite directions — the accumulator counts notches while
    // `INP12` moved the multiplier to the producer — and a consumer that
    // multiplied again (or a producer that stopped) would silently scroll by
    // the wrong distance.
    float c = 0;
    assert(wheelSteps(c, 1.0f) * linesPerNotch == linesPerNotch);
    static assert(linesPerNotch > 1);
}

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

@("input.events.describeAndFormatKey")
@safe unittest
{
    assert(formatMods(Mods(ctrl: true)) == "Ctrl+");
    assert(formatMods(Mods(alt: true, shift: true)) == altModifierName ~ "+Shift+");
    assert(formatMods(Mods(super_: true)) == superModifierName ~ "+");
    assert(formatMods(Mods(ctrl: true, super_: true), false) == (superModifierName == "Cmd" ? "ctrl cmd" : "ctrl super"));

    assert(describeKey(keyEvent(Key.enter, Mods(ctrl: true))) == "key Ctrl+enter");
    assert(describeKey(charEvent('c', Mods(super_: true))) == "key " ~ superModifierName ~ "+'c'");
    assert(namedKeyLabel(Key.enter) == "↵");
    assert(namedKeyLabel(Key.escape) == "Esc");
    assert(namedKeySymbol(Key.escape) == "⎋");
    assert(namedKeySymbol(Key.up) == "↑");
    assert(namedKeySymbol(Key.delete_) == "⌦");
}

@("input.events.parseAndFormatChords")
@safe unittest
{
    // Key parsing with aliases & symbols
    Key k;
    assert(parseKey("enter", k) && k == Key.enter);
    assert(parseKey("return", k) && k == Key.enter);
    assert(parseKey("⏎", k) && k == Key.enter);
    assert(parseKey("esc", k) && k == Key.escape);
    assert(parseKey("⎋", k) && k == Key.escape);
    assert(parseKey("del", k) && k == Key.delete_);
    assert(parseKey("⌦", k) && k == Key.delete_);
    assert(parseKey("opt", k) && k == Key.alt);
    assert(parseKey("⌥", k) && k == Key.alt);
    assert(parseKey("cmd", k) && k == Key.super_);
    assert(parseKey("⌘", k) && k == Key.super_);
    assert(parseKey("⌃", k) && k == Key.ctrl);
    assert(parseKey("⇧", k) && k == Key.shift);

    // Single chord parsing: text and symbols
    Chord c;
    string err;
    assert(parseChord("ctrl+c", c, err));
    assert(c.ctrl && c.key == Key.char_ && c.ch == 'c');

    assert(parseChord("⌘c", c, err));
    assert(c.super_ && c.key == Key.char_ && c.ch == 'c');

    assert(parseChord("⌥+f", c, err));
    assert(c.alt && c.key == Key.char_ && c.ch == 'f');

    assert(parseChord("⌃⌥⇧⌘Q", c, err));
    assert(c.ctrl && c.alt && c.shift == ShiftReq.yes && c.super_ && c.key == Key.char_ && c.ch == 'q');

    assert(parseChord("⇧⇥", c, err));
    assert(c.shift == ShiftReq.yes && c.key == Key.tab);

    assert(parseChord("⇤", c, err));
    assert(c.shift == ShiftReq.yes && c.key == Key.tab);

    assert(parseChord("⎋", c, err));
    assert(c.key == Key.escape);

    assert(parseChord("1-9", c, err));
    assert(c.key == Key.char_ && c.ch == '1' && c.chEnd == '9');

    // ChordPath parsing & unparsing
    ChordPath p;
    assert(parseChordPath("ctrl+x ctrl+s", p, err));
    assert(p.depth == 2);
    assert(unparseChordPath(p) == "ctrl+x ctrl+s");

    assert(parseChordPath("⌘c", p, err));
    assert(p.depth == 1);
    assert(unparseChordPath(p) == "super+c");

    // Formatting: kbd and symbols
    const sampleChord = Chord(key: Key.char_, ch: 'q', shift: ShiftReq.yes, ctrl: true, alt: true, super_: true);
    assert(formatKbdChord(sampleChord) == "<kbd>Ctrl</kbd> + <kbd>" ~ altModifierName ~ "</kbd> + <kbd>Shift</kbd> + <kbd>" ~ superModifierName ~ "</kbd> + <kbd>q</kbd>");
    assert(formatSymbolChord(sampleChord) == "⌃⌥⇧⌘q");
    assert(formatSymbolChord(Chord(key: Key.escape)) == "⎋");
    assert(formatSymbolChord(Chord(key: Key.char_, ch: 'c', super_: true)) == "⌘c");
}
