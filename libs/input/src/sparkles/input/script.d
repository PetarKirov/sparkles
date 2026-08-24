/**
Input as text (`INP22`): a line-oriented spelling of
$(REF Event, sparkles,input,events), so a session can be $(B fed) to an
application instead of being set up behind its back.

$(H3 Why this exists)

An application whose state can only be reached by hand — a popup opened by a
method call, a hover forced by a flag, a pointer position written into the
frame after the fold — is an application whose interesting states have no
reproduction. hue accumulated thirteen `HUE_GUI_*` hooks that way, nine of them
injecting state $(I behind) `handle`, and five implemented as direct method
calls that bypass event dispatch entirely. Each one is a second way to reach a
state the real input path can also reach, and the two drift: the golden that
photographs a hovered scrollbar hovers it by assignment, so it cannot fail when
hovering by pointer stops working.

The alternative is the MVU one — transitions are `step(state, input) → state`
(`PRN7`), so the way to put an application in a state is to $(B send it the
input that gets there). That needs input to be writable, which is this module.

$(H3 The grammar)

One event per line. `#` starts a comment; blank lines and comments parse to
`NoEvent`, which every consumer already drops.

$(TABLE
$(TR $(TH Line) $(TH Event))
$(TR $(TD `key down`)            $(TD a named key, pressed))
$(TR $(TD `key enter ctrl`)      $(TD …with modifiers, `+`-joined))
$(TR $(TD `key f5 repeat`)       $(TD …auto-repeat; also `release`))
$(TR $(TD `char a`)              $(TD a printable code point (text input)))
$(TR $(TD `char 0x2713`)         $(TD …by number, for anything unwritable))
$(TR $(TD `move 10,4`)           $(TD pointer motion, no button))
$(TR $(TD `press left 10,4`)     $(TD …and `release`, `drag`))
$(TR $(TD `leave`)               $(TD the pointer left the surface))
$(TR $(TD `wheel 0,-3 10,4`)     $(TD `dx,dy` cells at a position))
$(TR $(TD `wheel 0,-3 10,4 precise`) $(TD …from a continuous source))
$(TR $(TD `focus in`)            $(TD …and `out`))
$(TR $(TD `resize 100x40`)       $(TD ))
$(TR $(TD `end`)                 $(TD `EndOfInput` — the shell quits))
)

Positions are the toolkit's 0-based cells, like every other position in this
package: a script is written against the layout, not against a device.

$(H3 What it deliberately does not spell)

`GestureEvent` has no spelling. A recognizer's output is derived from pointer
samples, so scripting it would let a test assert a pinch that no sequence of
real events could produce — the same hole the state injection above is. Feed
the pointers; let the recognizer do its job.

`KeyEvent.text`/`unshifted` are likewise absent: they exist for a terminal
emulator's encoder, are derived from the platform's layout, and a script that
set them independently of `ch` could describe a keystroke no keyboard emits.
`char a` fills `ch`, which is what every consumer above the encoder reads.

$(H3 Round-tripping)

$(LREF writeEvent) emits the canonical spelling of anything $(LREF parseEvent)
accepts, and the pair round-trips: `parseEvent(writeEvent(e)) == e` for every
event this grammar covers. That is a property test below, not a promise — it is
what makes a recorded session replayable, which is the point of writing it down.
*/
module sparkles.input.script;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.text.errors : ParseError, ParseErrorCode, ParseExpected,
    parseErr, parseOk;
import sparkles.base.text.readers : readInteger;
import sparkles.base.text.writers : writeInteger;

import sparkles.input.events : Event, EndOfInput, FocusEvent, Key, KeyAction,
    KeyEvent, Mods, NoEvent, PointerAction, PointerButton, PointerEvent, Point,
    ResizeEvent, Size, WheelEvent;

import std.sumtype : match;

@safe pure nothrow @nogc:

// ─────────────────────────────────────────────────────────────────────────────
// Parsing
// ─────────────────────────────────────────────────────────────────────────────

/**
Parses one script line into an $(REF Event, sparkles,input,events).

A blank line or a comment yields `NoEvent`, so a caller can feed every line
through without pre-filtering and rely on the drain sentinel it already handles.
Offsets in a returned $(REF ParseError, sparkles,base,text,errors) are relative
to `line`.
*/
ParseExpected!Event parseEvent(const(char)[] line)
{
    // Not `scope`: dip1000 would then infer that the result borrows from the
    // line, and it does not — every event this returns is self-contained
    // (`INP4`), `KeyEvent.text` inline rather than sliced. A script read from
    // a file and dropped leaves its events valid, which is the whole reason
    // the vocabulary stores text inline in the first place.
    auto s = Scanner(line);
    const verb = s.word();
    if (verb.length == 0 || verb[0] == '#')
        return parseOk(Event(NoEvent()));

    switch (verb)
    {
        case "key":     return parseKey(s);
        case "char":    return parseChar(s);
        case "move":    return parsePointer(s, PointerAction.move, false);
        case "press":   return parsePointer(s, PointerAction.press, true);
        case "release": return parsePointer(s, PointerAction.release, true);
        case "drag":    return parsePointer(s, PointerAction.drag, true);
        case "leave":   return finish(s, Event(PointerEvent(
                            action: PointerAction.leave)));
        case "wheel":   return parseWheel(s);
        case "focus":   return parseFocus(s);
        case "resize":  return parseResize(s);
        case "end":     return finish(s, Event(EndOfInput()));
        default:
            return parseErr!Event(ParseError(ParseErrorCode.unknownValue,
                s.wordStart, "expected one of: key char move press release "
                ~ "drag leave wheel focus resize end"));
    }
}

private ParseExpected!Event parseKey(ref Scanner s)
{
    const name = s.word();
    Key k;
    if (!keyFromName(name, k))
        return parseErr!Event(ParseError(ParseErrorCode.unknownValue,
            s.wordStart, "not a named key (use `char` for a code point)"));

    KeyEvent e;
    e.key = k;
    e.ch = 0;
    // Modifiers and the action are order-free and both optional, because a
    // line reads better as `key enter ctrl` than as a fixed arity with holes.
    for (auto t = s.word(); t.length; t = s.word())
    {
        KeyAction a;
        if (actionFromName(t, a))
            e.action = a;
        else if (!modsFromName(t, e.mods))
            return parseErr!Event(ParseError(ParseErrorCode.unknownValue,
                s.wordStart, "expected modifiers or press/repeat/release"));
    }
    return parseOk(Event(e));
}

private ParseExpected!Event parseChar(ref Scanner s)
{
    const lit = s.word();
    dchar ch;
    if (!codePointFromName(lit, ch))
        return parseErr!Event(ParseError(ParseErrorCode.unexpectedCharacter,
            s.wordStart, "expected one character or 0x<hex>"));

    KeyEvent e;
    e.key = Key.char_;
    e.ch = ch;
    for (auto t = s.word(); t.length; t = s.word())
    {
        KeyAction a;
        if (actionFromName(t, a))
            e.action = a;
        else if (!modsFromName(t, e.mods))
            return parseErr!Event(ParseError(ParseErrorCode.unknownValue,
                s.wordStart, "expected modifiers or press/repeat/release"));
    }
    return parseOk(Event(e));
}

private ParseExpected!Event parsePointer(ref Scanner s, PointerAction action,
    bool wantsButton)
{
    PointerEvent e;
    e.action = action;
    if (wantsButton)
    {
        const b = s.word();
        if (!buttonFromName(b, e.button))
            return parseErr!Event(ParseError(ParseErrorCode.unknownValue,
                s.wordStart,
                "expected a button: left middle right none back forward"));
    }
    if (!s.point(e.pos))
        return parseErr!Event(ParseError(ParseErrorCode.unexpectedCharacter,
            s.wordStart, "expected a position as `x,y`"));
    for (auto t = s.word(); t.length; t = s.word())
        if (!modsFromName(t, e.mods))
            return parseErr!Event(ParseError(ParseErrorCode.unknownValue,
                s.wordStart, "expected modifiers"));
    return parseOk(Event(e));
}

private ParseExpected!Event parseWheel(ref Scanner s)
{
    WheelEvent e;
    Point d;
    if (!s.point(d))
        return parseErr!Event(ParseError(ParseErrorCode.unexpectedCharacter,
            s.wordStart, "expected a delta as `dx,dy`"));
    e.dx = d.x;
    e.dy = d.y;
    if (!s.point(e.pos))
        return parseErr!Event(ParseError(ParseErrorCode.unexpectedCharacter,
            s.wordStart, "expected a position as `x,y`"));
    for (auto t = s.word(); t.length; t = s.word())
    {
        if (t == "precise")
            e.precise = true;
        else if (!modsFromName(t, e.mods))
            return parseErr!Event(ParseError(ParseErrorCode.unknownValue,
                s.wordStart, "expected `precise` or modifiers"));
    }
    return parseOk(Event(e));
}

private ParseExpected!Event parseFocus(ref Scanner s)
{
    const t = s.word();
    if (t == "in")
        return finish(s, Event(FocusEvent(true)));
    if (t == "out")
        return finish(s, Event(FocusEvent(false)));
    return parseErr!Event(ParseError(ParseErrorCode.unknownValue, s.wordStart,
        "expected `in` or `out`"));
}

private ParseExpected!Event parseResize(ref Scanner s)
{
    const t = s.word();
    const x = indexOfByte(t, 'x');
    if (x <= 0 || x + 1 >= t.length)
        return parseErr!Event(ParseError(ParseErrorCode.unexpectedCharacter,
            s.wordStart, "expected a size as `<cols>x<rows>`"));
    long w, h;
    if (!wholeInteger(t[0 .. x], w) || !wholeInteger(t[x + 1 .. $], h)
        || w < 0 || h < 0 || w > ushort.max || h > ushort.max)
        return parseErr!Event(ParseError(ParseErrorCode.unexpectedCharacter,
            s.wordStart, "expected a size as `<cols>x<rows>`"));
    return finish(s, Event(ResizeEvent(Size(cast(ushort) w, cast(ushort) h))));
}

/// Accepts `e` only if nothing follows on the line — so a typo in a trailing
/// token is reported rather than ignored.
private ParseExpected!Event finish(ref Scanner s, Event e)
{
    if (s.word().length)
        return parseErr!Event(ParseError(ParseErrorCode.trailingContent,
            s.wordStart, "nothing may follow this event"));
    return parseOk(e);
}

// ─────────────────────────────────────────────────────────────────────────────
// Writing
// ─────────────────────────────────────────────────────────────────────────────

/**
Writes `e`'s canonical script spelling — the inverse of $(LREF parseEvent), with
no trailing newline.

`NoEvent` writes nothing at all, which keeps a recorded stream free of blank
placeholders for the sentinel every producer emits when it has nothing to say.
*/
void writeEvent(Writer)(ref Writer w, in Event e)
{
    e.match!(
        (in NoEvent _) {},
        (in EndOfInput _) { put(w, "end"); },
        (in KeyEvent k) {
            if (k.key == Key.char_)
            {
                put(w, "char ");
                writeCodePoint(w, k.ch);
            }
            else
            {
                put(w, "key ");
                put(w, keyName(k.key));
            }
            writeMods(w, k.mods);
            if (k.action != KeyAction.press)
            {
                put(w, " ");
                put(w, actionName(k.action));
            }
        },
        (in PointerEvent p) {
            if (p.action == PointerAction.leave)
            {
                put(w, "leave");
                return;
            }
            put(w, actionName(p.action));
            if (p.action != PointerAction.move)
            {
                put(w, " ");
                put(w, buttonName(p.button));
            }
            put(w, " ");
            writePoint(w, p.pos);
            writeMods(w, p.mods);
        },
        (in WheelEvent v) {
            put(w, "wheel ");
            writePoint(w, Point(v.dx, v.dy));
            put(w, " ");
            writePoint(w, v.pos);
            if (v.precise)
                put(w, " precise");
            writeMods(w, v.mods);
        },
        (in FocusEvent f) { put(w, f.focused ? "focus in" : "focus out"); },
        (in ResizeEvent r) {
            put(w, "resize ");
            writeInteger(w, cast(uint) r.size.width);
            put(w, "x");
            writeInteger(w, cast(uint) r.size.height);
        },
        (in GestureEvent _) {
            // No spelling by design (see the module docs): a gesture is a
            // recognizer's conclusion, not an input. Recorded as a comment so a
            // round-trip through a stream containing one is lossy VISIBLY.
            put(w, "# gesture (not scriptable)");
        },
    );
}

private import sparkles.input.events : GestureEvent;

/// Renders one event to a fixed buffer — the convenience behind
/// $(LREF writeEvent) for a caller that just wants the line.
SmallBuffer!(char, 64) eventLine(in Event e)
{
    SmallBuffer!(char, 64) buf;
    writeEvent(buf, e);
    return buf;
}

// ─────────────────────────────────────────────────────────────────────────────
// Token vocabulary — one table per enum, both directions from one place.
// ─────────────────────────────────────────────────────────────────────────────

// Written as paired functions over a single `static foreach` rather than two
// literal tables: a name that parses but does not write (or the reverse) breaks
// the round-trip property silently, and the only way to be sure is to have one
// source for both directions.
private static immutable string[30] keyNames = [
    "none", "char", "up", "down", "left", "right",
    "home", "end", "pageup", "pagedown", "insert", "delete",
    "enter", "tab", "backspace", "escape",
    "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
    "back", "menu",
];

private string keyName(Key k)
    => keyNames[cast(size_t) k];

private bool keyFromName(scope const(char)[] s, out Key k)
{
    foreach (i, n; keyNames)
        if (s == n)
        {
            // `char` and `none` are not named keys on a line: `char` has its
            // own verb (it needs a code point) and `none` is not an event.
            if (i == cast(size_t) Key.char_ || i == cast(size_t) Key.none)
                return false;
            k = cast(Key) i;
            return true;
        }
    return false;
}

private string actionName(KeyAction a)
{
    final switch (a)
    {
        case KeyAction.press:   return "press";
        case KeyAction.repeat:  return "repeat";
        case KeyAction.release: return "release";
    }
}

private string actionName(PointerAction a)
{
    final switch (a)
    {
        case PointerAction.press:   return "press";
        case PointerAction.release: return "release";
        case PointerAction.move:    return "move";
        case PointerAction.drag:    return "drag";
        case PointerAction.leave:   return "leave";
    }
}

private bool actionFromName(scope const(char)[] s, out KeyAction a)
{
    switch (s)
    {
        case "press":   a = KeyAction.press;   return true;
        case "repeat":  a = KeyAction.repeat;  return true;
        case "release": a = KeyAction.release; return true;
        default:        return false;
    }
}

private string buttonName(PointerButton b)
{
    final switch (b)
    {
        case PointerButton.left:    return "left";
        case PointerButton.middle:  return "middle";
        case PointerButton.right:   return "right";
        case PointerButton.none:    return "none";
        case PointerButton.back:    return "back";
        case PointerButton.forward: return "forward";
    }
}

private bool buttonFromName(scope const(char)[] s, out PointerButton b)
{
    switch (s)
    {
        case "left":    b = PointerButton.left;    return true;
        case "middle":  b = PointerButton.middle;  return true;
        case "right":   b = PointerButton.right;   return true;
        case "none":    b = PointerButton.none;    return true;
        case "back":    b = PointerButton.back;    return true;
        case "forward": b = PointerButton.forward; return true;
        default:        return false;
    }
}

/// Parses a `+`-joined modifier token (`ctrl+shift`) into `m`. Additive, so
/// several tokens on one line compose.
private bool modsFromName(scope const(char)[] s, ref Mods m)
{
    if (s.length == 0)
        return false;
    size_t i = 0;
    while (i <= s.length)
    {
        size_t j = i;
        while (j < s.length && s[j] != '+')
            ++j;
        const part = s[i .. j];
        switch (part)
        {
            case "ctrl":  m.ctrl = true;   break;
            case "alt":   m.alt = true;    break;
            case "shift": m.shift = true;  break;
            case "super": m.super_ = true; break;
            default:      return false;
        }
        if (j >= s.length)
            return true;
        i = j + 1;
    }
    return true;
}

/// Writes ` ctrl+shift` (leading space) or nothing. Order is fixed so the
/// round-trip is an equality rather than a set comparison.
private void writeMods(Writer)(ref Writer w, in Mods m)
{
    if (!m.ctrl && !m.alt && !m.shift && !m.super_)
        return;
    put(w, " ");
    bool first = true;
    void one(string s)
    {
        if (!first)
            put(w, "+");
        put(w, s);
        first = false;
    }
    if (m.ctrl)   one("ctrl");
    if (m.alt)    one("alt");
    if (m.shift)  one("shift");
    if (m.super_) one("super");
}

// ─────────────────────────────────────────────────────────────────────────────
// Scalars
// ─────────────────────────────────────────────────────────────────────────────

/// A Unicode scalar value: in range and not half of a surrogate pair.
///
/// The surrogate hole is the half of this test that is easy to forget and
/// expensive to omit. `D800`–`DFFF` are not code points — they exist only
/// inside UTF-16 — so a `KeyEvent.ch` holding one is malformed, and the
/// encoder here would happily turn it into WTF-8 that the decoder reads back.
/// The value would then ROUND-TRIP, which is the property this module sells,
/// while being something no keyboard can produce and `std.utf` throws on.
private bool isScalar(dchar c) pure nothrow @nogc
    => c <= 0x10_FFFF && !(c >= 0xD800 && c <= 0xDFFF);

/// A code point as one literal character, or `0x<hex>` for anything a line
/// cannot hold — a space, a `#`, or a non-printable.
private bool codePointFromName(scope const(char)[] s, out dchar ch)
{
    if (s.length == 0)
        return false;
    if (s.length > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
    {
        dchar acc = 0;
        foreach (c; s[2 .. $])
        {
            uint d;
            if (c >= '0' && c <= '9')
                d = c - '0';
            else if (c >= 'a' && c <= 'f')
                d = c - 'a' + 10;
            else if (c >= 'A' && c <= 'F')
                d = c - 'A' + 10;
            else
                return false;
            if (acc > 0x10_FFFF)
                return false;
            acc = cast(dchar)((acc << 4) | d);
        }
        if (!isScalar(acc))
            return false;
        ch = acc;
        return true;
    }
    // One UTF-8 sequence, decoded by hand: `std.utf` throws, which this
    // package's `@nogc nothrow` surface cannot afford (`sparkles:base`'s
    // text package exists for exactly this reason).
    return decodeOne(s, ch);
}

/// ditto — writes the literal where it is unambiguous, the escape otherwise.
private void writeCodePoint(Writer)(ref Writer w, dchar ch)
{
    // A space would split the token, a `#` would start a comment, and a
    // control character would not survive a round-trip through a text file.
    if (ch <= 0x20 || ch == '#' || ch == 0x7F)
    {
        put(w, "0x");
        writeHex(w, cast(uint) ch);
        return;
    }
    encodeOne(w, ch);
}

private void writeHex(Writer)(ref Writer w, uint v)
{
    static immutable digits = "0123456789abcdef";
    char[8] tmp;
    size_t n;
    do
    {
        tmp[n++] = digits[v & 0xF];
        v >>= 4;
    }
    while (v != 0);
    foreach_reverse (i; 0 .. n)
    {
        char[1] c = tmp[i];
        put(w, c[]);
    }
}

private void writePoint(Writer)(ref Writer w, in Point p)
{
    writeSigned(w, p.x);
    put(w, ",");
    writeSigned(w, p.y);
}

private void writeSigned(Writer)(ref Writer w, int v)
{
    if (v < 0)
    {
        put(w, "-");
        writeInteger(w, cast(uint)(-cast(long) v));
    }
    else
        writeInteger(w, cast(uint) v);
}

/// A whole signed integer, rejecting anything with leftovers — so `10x` is an
/// error rather than a silent `10`.
private bool wholeInteger(scope const(char)[] s, out long v)
{
    if (s.length == 0)
        return false;
    bool neg;
    size_t i;
    if (s[0] == '-' || s[0] == '+')
    {
        neg = s[0] == '-';
        i = 1;
        if (s.length == 1)
            return false;
    }
    long acc;
    foreach (c; s[i .. $])
    {
        if (c < '0' || c > '9')
            return false;
        if (acc > (long.max - 9) / 10)
            return false;
        acc = acc * 10 + (c - '0');
    }
    v = neg ? -acc : acc;
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// The scanner
// ─────────────────────────────────────────────────────────────────────────────

/// Whitespace-separated words over one line, remembering where the last one
/// started so an error can point at the token rather than at the line.
private struct Scanner
{
    const(char)[] src;
    size_t pos;
    size_t wordStart;

    const(char)[] word() @safe pure nothrow @nogc
    {
        while (pos < src.length && isSpace(src[pos]))
            ++pos;
        wordStart = pos;
        if (pos >= src.length)
            return null;
        // A comment ends the line, wherever it starts.
        if (src[pos] == '#')
        {
            pos = src.length;
            return null;
        }
        const start = pos;
        while (pos < src.length && !isSpace(src[pos]) && src[pos] != '#')
            ++pos;
        return src[start .. pos];
    }

    bool point(out Point p) @safe pure nothrow @nogc
    {
        const t = word();
        const c = indexOfByte(t, ',');
        if (c <= 0 || c + 1 >= t.length)
            return false;
        long x, y;
        if (!wholeInteger(t[0 .. c], x) || !wholeInteger(t[c + 1 .. $], y))
            return false;
        if (x < int.min || x > int.max || y < int.min || y > int.max)
            return false;
        p = Point(cast(int) x, cast(int) y);
        return true;
    }
}

private bool isSpace(char c) => c == ' ' || c == '\t' || c == '\r';

private long indexOfByte(scope const(char)[] s, char c)
{
    foreach (i, b; s)
        if (b == c)
            return cast(long) i;
    return -1;
}

private bool decodeOne(scope const(char)[] s, out dchar ch)
{
    const b0 = cast(ubyte) s[0];
    size_t need;
    dchar acc;
    if (b0 < 0x80)
    {
        ch = b0;
        return s.length == 1;
    }
    else if ((b0 & 0xE0) == 0xC0) { need = 1; acc = b0 & 0x1F; }
    else if ((b0 & 0xF0) == 0xE0) { need = 2; acc = b0 & 0x0F; }
    else if ((b0 & 0xF8) == 0xF0) { need = 3; acc = b0 & 0x07; }
    else
        return false;
    if (s.length != need + 1)
        return false;
    foreach (b; s[1 .. $])
    {
        if ((b & 0xC0) != 0x80)
            return false;
        acc = (acc << 6) | (b & 0x3F);
    }
    if (!isScalar(acc))
        return false;
    ch = acc;
    return true;
}

private void encodeOne(Writer)(ref Writer w, dchar ch)
{
    char[4] b;
    size_t n;
    if (ch < 0x80)
        b[n++] = cast(char) ch;
    else if (ch < 0x800)
    {
        b[n++] = cast(char)(0xC0 | (ch >> 6));
        b[n++] = cast(char)(0x80 | (ch & 0x3F));
    }
    else if (ch < 0x1_0000)
    {
        b[n++] = cast(char)(0xE0 | (ch >> 12));
        b[n++] = cast(char)(0x80 | ((ch >> 6) & 0x3F));
        b[n++] = cast(char)(0x80 | (ch & 0x3F));
    }
    else
    {
        b[n++] = cast(char)(0xF0 | (ch >> 18));
        b[n++] = cast(char)(0x80 | ((ch >> 12) & 0x3F));
        b[n++] = cast(char)(0x80 | ((ch >> 6) & 0x3F));
        b[n++] = cast(char)(0x80 | (ch & 0x3F));
    }
    put(w, b[0 .. n]);
}

/// The one `put` this module uses — `std.range.primitives.put` is not
/// `@nogc`-clean for every writer, and `SmallBuffer` takes slices directly.
private void put(Writer)(ref Writer w, scope const(char)[] s)
{
    w ~= s;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

@("input.script.readsWhatAHumanWouldWrite")
@safe pure nothrow @nogc
unittest
{
    static Event ok(const(char)[] line)
    {
        auto r = parseEvent(line);
        assert(!r.hasError, "this line should have parsed");
        return r.value;
    }

    assert(ok("key down") == Event(KeyEvent(Key.down, 0)));
    assert(ok("key enter ctrl")
        == Event(KeyEvent(Key.enter, 0, Mods(ctrl: true))));
    assert(ok("key f5 repeat")
        == Event(KeyEvent(Key.f5, 0, Mods(), KeyAction.repeat)));
    assert(ok("char a") == Event(KeyEvent(Key.char_, 'a')));
    assert(ok("char 0x2713") == Event(KeyEvent(Key.char_, '✓')));
    assert(ok("move 10,4")
        == Event(PointerEvent(PointerAction.move, PointerButton.none,
            Point(10, 4))));
    assert(ok("press left 10,4")
        == Event(PointerEvent(PointerAction.press, PointerButton.left,
            Point(10, 4))));
    assert(ok("leave") == Event(PointerEvent(action: PointerAction.leave)));
    assert(ok("wheel 0,-3 10,4")
        == Event(WheelEvent(0, -3, Point(10, 4))));
    assert(ok("focus in") == Event(FocusEvent(true)));
    assert(ok("resize 100x40") == Event(ResizeEvent(Size(100, 40))));

    // A blank line and a comment are the drain sentinel every consumer
    // already drops, so a script may be laid out and annotated freely.
    assert(ok("") == Event(NoEvent()));
    assert(ok("   # just a note") == Event(NoEvent()));
    assert(ok("key down # why") == Event(KeyEvent(Key.down, 0)));
}

@("input.script.refusesWhatItCannotMean")
@safe pure nothrow @nogc
unittest
{
    // Every one of these would otherwise be a script that silently does
    // something other than what it says — the failure mode a replay harness
    // can least afford, because the output still looks like a session.
    assert(parseEvent("jump 1,2").hasError, "an unknown verb is not a no-op");
    assert(parseEvent("key a").hasError, "`a` is a code point, not a named key");
    assert(parseEvent("key char").hasError, "`char` is a verb, not a key name");
    assert(parseEvent("key none").hasError, "`none` is not an event");
    assert(parseEvent("press 10,4").hasError, "a press needs its button");
    assert(parseEvent("move 10").hasError, "a position needs both axes");
    assert(parseEvent("move 10,").hasError);
    assert(parseEvent("move 10,4x").hasError, "trailing junk is not a number");
    assert(parseEvent("resize 100").hasError);
    assert(parseEvent("resize 100x40x2").hasError);
    assert(parseEvent("focus sideways").hasError);
    assert(parseEvent("end now").hasError, "nothing may follow a bare event");
    assert(parseEvent("key down hyper").hasError, "not a modifier");
    assert(parseEvent("char ab").hasError, "one code point, not a word");

    // A lone surrogate is not a code point — it exists only inside UTF-16.
    // Worth its own assertions because the failure is quiet and durable: the
    // encoder below turns one into WTF-8, the decoder reads it back, and the
    // value ROUND-TRIPS. It would satisfy this module's central property while
    // being something no keyboard produces and `std.utf` throws on.
    assert(parseEvent("char 0xd800").hasError, "a lone high surrogate");
    assert(parseEvent("char 0xdfff").hasError, "a lone low surrogate");
    assert(parseEvent("char 0x110000").hasError, "past the last code point");
    assert(!parseEvent("char 0x10ffff").hasError, "…but the last one is fine");
    assert(!parseEvent("char 0xffff").hasError, "and so is the one below D800's block");
}

@("input.script.everyEventRoundTrips")
@safe pure nothrow @nogc
unittest
{
    // The property the replay harness rests on: an event written down and read
    // back is the SAME event. Anything less and a recorded session is a
    // description of a session rather than the session.
    //
    // Enumerated across each field's whole domain rather than sampled, because
    // the way this breaks is one enum member whose name parses but does not
    // write (or the reverse), which a sample of typical events never hits.
    static void trip(in Event e)
    {
        SmallBuffer!(char, 64) buf;
        writeEvent(buf, e);
        auto back = parseEvent(buf[]);
        assert(!back.hasError, "what was written did not parse");
        assert(back.value == e, "what was written parsed as something else");
    }

    static foreach (mi; 0 .. 16)
    {{
        const m = Mods(
            ctrl: (mi & 1) != 0, alt: (mi & 2) != 0,
            shift: (mi & 4) != 0, super_: (mi & 8) != 0);

        static foreach (k; __traits(allMembers, Key))
            static if (k != "none" && k != "char_")
                static foreach (a; __traits(allMembers, KeyAction))
                    trip(Event(KeyEvent(__traits(getMember, Key, k), 0, m,
                        __traits(getMember, KeyAction, a))));

        static foreach (b; __traits(allMembers, PointerButton))
        {
            trip(Event(PointerEvent(PointerAction.press,
                __traits(getMember, PointerButton, b), Point(3, -4), m)));
            trip(Event(PointerEvent(PointerAction.release,
                __traits(getMember, PointerButton, b), Point(0, 0), m)));
            trip(Event(PointerEvent(PointerAction.drag,
                __traits(getMember, PointerButton, b), Point(-7, 9), m)));
        }
        trip(Event(PointerEvent(PointerAction.move, PointerButton.none,
            Point(11, 2), m)));
        trip(Event(WheelEvent(-2, 6, Point(4, 5), m)));
        trip(Event(WheelEvent(0, -3, Point(1, 1), m, precise: true)));
    }}

    // `leave` carries no button or position, so it has its own spelling.
    trip(Event(PointerEvent(action: PointerAction.leave)));
    trip(Event(FocusEvent(true)));
    trip(Event(FocusEvent(false)));
    trip(Event(ResizeEvent(Size(0, 0))));
    trip(Event(ResizeEvent(Size(65535, 65535))));
    trip(Event(EndOfInput()));

    // Code points across the escape boundary: a literal where it survives a
    // line, the numeric form where it would not.
    static immutable dchar[7] printable =
        ['a', 'Z', '0', '~', 'é', '✓', '\U0001F600'];
    static immutable dchar[6] escaped = [' ', '#', '\t', '\n', '\x7f', '\0'];
    foreach (c; printable)
        trip(Event(KeyEvent(Key.char_, c)));
    foreach (c; escaped)
        trip(Event(KeyEvent(Key.char_, c)));
}

@("input.script.aGestureIsNotAnInput")
@safe pure nothrow @nogc
unittest
{
    import sparkles.input.events : Gesture, GestureEvent;

    // A gesture is a recognizer's CONCLUSION. Giving it a spelling would let a
    // script assert a pinch that no sequence of real pointers could produce —
    // the same hole as reaching past `handle` to set state, which this module
    // exists to close. It writes as a comment so the gap is visible in a
    // recording rather than silent.
    SmallBuffer!(char, 64) buf;
    writeEvent(buf, Event(GestureEvent(Gesture.pinch, Point(1, 2), 1.5)));
    assert(buf[] == "# gesture (not scriptable)");
    assert(parseEvent(buf[]).value == Event(NoEvent()),
        "…and reads back as nothing, not as a bad pinch");
}
