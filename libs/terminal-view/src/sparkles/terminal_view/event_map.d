/**
`sparkles:input` events → the pty encoder (`TVW4`).

The migration's input seam: a `KeyEvent` from the terminal-grade keyboard
(press/repeat/release, `unshifted` codepoint, paired text) carries everything
$(REF KeyStroke, sparkles,terminal_view,input) needs, and this module is the
mapping — tested against the $(B same byte-oracle fixtures) as the polling
path, so swapping the input source cannot silently change an encoding.
*/
module sparkles.terminal_view.event_map;

import sparkles.ghostty.c;
import sparkles.input : Key, KeyAction, KeyEvent, Mods, PointerButton;
import sparkles.terminal_view.input : encodeKeyStroke, KeyStroke;

/// The physical key the encoder addresses, from the event's named key or —
/// for `Key.char_` — its layout-independent unshifted codepoint.
@safe pure nothrow @nogc
GhosttyKey ghosttyKeyOf(in KeyEvent k)
{
    final switch (k.key)
    {
        case Key.none:      return GHOSTTY_KEY_UNIDENTIFIED;
        case Key.char_:     return ghosttyKeyOfCodepoint(k.unshifted);
        case Key.up:        return GHOSTTY_KEY_ARROW_UP;
        case Key.down:      return GHOSTTY_KEY_ARROW_DOWN;
        case Key.left:      return GHOSTTY_KEY_ARROW_LEFT;
        case Key.right:     return GHOSTTY_KEY_ARROW_RIGHT;
        case Key.home:      return GHOSTTY_KEY_HOME;
        case Key.end:       return GHOSTTY_KEY_END;
        case Key.pageUp:    return GHOSTTY_KEY_PAGE_UP;
        case Key.pageDown:  return GHOSTTY_KEY_PAGE_DOWN;
        case Key.insert:    return GHOSTTY_KEY_INSERT;
        case Key.delete_:   return GHOSTTY_KEY_DELETE;
        case Key.enter:     return GHOSTTY_KEY_ENTER;
        case Key.tab:       return GHOSTTY_KEY_TAB;
        case Key.backspace: return GHOSTTY_KEY_BACKSPACE;
        case Key.escape:    return GHOSTTY_KEY_ESCAPE;
        case Key.f1, Key.f2, Key.f3, Key.f4, Key.f5, Key.f6, Key.f7, Key.f8,
            Key.f9, Key.f10, Key.f11, Key.f12:
            return cast(GhosttyKey)(GHOSTTY_KEY_F1 + (k.key - Key.f1));
        // The platform keys have no VT spelling; the component handles them
        // (Android back = dismiss) before anything reaches the encoder.
        case Key.back:      return GHOSTTY_KEY_UNIDENTIFIED;
        case Key.menu:      return GHOSTTY_KEY_UNIDENTIFIED;
    }
}

/// ditto
@safe pure nothrow @nogc
private GhosttyKey ghosttyKeyOfCodepoint(dchar u)
{
    if (u >= 'a' && u <= 'z')
        return cast(GhosttyKey)(GHOSTTY_KEY_A + (u - 'a'));
    if (u >= '0' && u <= '9')
        return cast(GhosttyKey)(GHOSTTY_KEY_DIGIT_0 + (u - '0'));

    switch (u)
    {
        case ' ':  return GHOSTTY_KEY_SPACE;
        case '-':  return GHOSTTY_KEY_MINUS;
        case '=':  return GHOSTTY_KEY_EQUAL;
        case '[':  return GHOSTTY_KEY_BRACKET_LEFT;
        case ']':  return GHOSTTY_KEY_BRACKET_RIGHT;
        case '\\': return GHOSTTY_KEY_BACKSLASH;
        case ';':  return GHOSTTY_KEY_SEMICOLON;
        case '\'': return GHOSTTY_KEY_QUOTE;
        case ',':  return GHOSTTY_KEY_COMMA;
        case '.':  return GHOSTTY_KEY_PERIOD;
        case '/':  return GHOSTTY_KEY_SLASH;
        case '`':  return GHOSTTY_KEY_BACKQUOTE;
        default:   return GHOSTTY_KEY_UNIDENTIFIED;
    }
}

/**
The fallback fill for a terminal-decoded char event (`TVW7`): a tui decoder
delivers only `ch` — it has no layout oracle and no separate text channel —
where the GUI arm's events carry `unshifted` and paired text. The encoder
addresses a key by its unshifted identity and writes a printable through its
text, so hand it both when nothing better exists: identity from `ch` always,
text from `ch` except under ctrl/alt (whose byte spellings — `0x03`, ESC
prefixes — are the encoder's business) and on release. Events already
carrying the fields (the GUI arm's, the oracle fixtures) pass through
untouched.
*/
@safe pure nothrow @nogc
KeyEvent withKeyIdentity(in KeyEvent k)
{
    if (k.key != Key.char_)
        return k;
    KeyEvent patched = k;
    if (patched.unshifted == 0)
        patched.unshifted = k.ch;
    if (patched.text.length == 0 && k.ch != 0
        && !k.mods.ctrl && !k.mods.alt && k.action != KeyAction.release)
    {
        char[4] ub = void;
        const n = utf8Of(ub, k.ch);
        if (n > 0)
            patched.text(ub[0 .. n]);
    }
    return patched;
}

/// Encodes `c` as UTF-8 into `buf`, returning the byte count — `0` for a
/// surrogate or out-of-range scalar. `@nogc` by construction, unlike
/// `std.utf.encode`, which throws.
@safe pure nothrow @nogc
size_t utf8Of(ref char[4] buf, dchar c)
{
    if (c < 0x80)
    {
        buf[0] = cast(char) c;
        return 1;
    }
    if (c < 0x800)
    {
        buf[0] = cast(char)(0xC0 | (c >> 6));
        buf[1] = cast(char)(0x80 | (c & 0x3F));
        return 2;
    }
    if (c >= 0xD800 && c <= 0xDFFF)
        return 0;
    if (c < 0x10000)
    {
        buf[0] = cast(char)(0xE0 | (c >> 12));
        buf[1] = cast(char)(0x80 | ((c >> 6) & 0x3F));
        buf[2] = cast(char)(0x80 | (c & 0x3F));
        return 3;
    }
    if (c <= 0x10FFFF)
    {
        buf[0] = cast(char)(0xF0 | (c >> 18));
        buf[1] = cast(char)(0x80 | ((c >> 12) & 0x3F));
        buf[2] = cast(char)(0x80 | ((c >> 6) & 0x3F));
        buf[3] = cast(char)(0x80 | (c & 0x3F));
        return 4;
    }
    return 0;
}

/// The pointer button, in the encoder's vocabulary (the same spellings the
/// raylib polling map uses for the side buttons).
@safe pure nothrow @nogc
GhosttyMouseButton ghosttyButtonOf(PointerButton b)
{
    final switch (b)
    {
        case PointerButton.left:    return GHOSTTY_MOUSE_BUTTON_LEFT;
        case PointerButton.middle:  return GHOSTTY_MOUSE_BUTTON_MIDDLE;
        case PointerButton.right:   return GHOSTTY_MOUSE_BUTTON_RIGHT;
        case PointerButton.none:    return GHOSTTY_MOUSE_BUTTON_UNKNOWN;
        case PointerButton.back:    return GHOSTTY_MOUSE_BUTTON_SEVEN;
        case PointerButton.forward: return GHOSTTY_MOUSE_BUTTON_SIX;
    }
}

@("terminal_view.event_map.ghosttyButtonOf")
@safe pure nothrow @nogc
unittest
{
    assert(ghosttyButtonOf(PointerButton.left) == GHOSTTY_MOUSE_BUTTON_LEFT);
    assert(ghosttyButtonOf(PointerButton.right) == GHOSTTY_MOUSE_BUTTON_RIGHT);
    assert(ghosttyButtonOf(PointerButton.none) == GHOSTTY_MOUSE_BUTTON_UNKNOWN);
}

/// The event's modifiers, in the encoder's vocabulary.
@safe pure nothrow @nogc
GhosttyMods ghosttyModsOf(in Mods m)
{
    GhosttyMods mods = 0;
    if (m.shift)  mods |= GHOSTTY_MODS_SHIFT;
    if (m.ctrl)   mods |= GHOSTTY_MODS_CTRL;
    if (m.alt)    mods |= GHOSTTY_MODS_ALT;
    if (m.super_) mods |= GHOSTTY_MODS_SUPER;
    return mods;
}

/// ditto
@safe pure nothrow @nogc
GhosttyKeyAction ghosttyActionOf(KeyAction a)
{
    final switch (a)
    {
        case KeyAction.press:   return GHOSTTY_KEY_ACTION_PRESS;
        case KeyAction.repeat:  return GHOSTTY_KEY_ACTION_REPEAT;
        case KeyAction.release: return GHOSTTY_KEY_ACTION_RELEASE;
    }
}

/**
Encodes one key event into `buf`, returning the bytes to write to the pty —
$(REF encodeKeyStroke, sparkles,terminal_view,input) over the mapped stroke,
so the two input sources share one encoder path and one oracle.

A `Key.char_` event with no unshifted codepoint (plain typed text — an IME
commit, a char event) maps to `GHOSTTY_KEY_UNIDENTIFIED`; the caller writes
its text to the pty directly, exactly as the polling loop wrote leftover
`GetCharPressed` bytes.
*/
@system nothrow @nogc
const(char)[] encodeKeyEvent(GhosttyKeyEncoder encoder, GhosttyKeyEvent event,
    in KeyEvent k, return scope char[] buf)
{
    const stroke = KeyStroke(
        key: ghosttyKeyOf(k),
        action: ghosttyActionOf(k.action),
        mods: ghosttyModsOf(k.mods),
        unshiftedCodepoint: k.unshifted,
        utf8: k.action == KeyAction.release ? null : k.text,
    );
    return encodeKeyStroke(encoder, event, stroke, buf);
}

// ---------------------------------------------------------------------------
// The oracle, driven through events: the same expected bytes as the
// KeyStroke fixtures, arriving as the terminal-grade keyboard emits them.
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.terminal_view.input : EncoderFixture;

    private KeyEvent press(Key k, Mods m = Mods(), dchar unshifted = 0,
        const(char)[] text = null) @safe pure nothrow @nogc
    {
        auto e = KeyEvent(key: k, ch: 0, mods: m, action: KeyAction.press,
            unshifted: unshifted);
        if (text.length)
            e.text(text);
        return e;
    }
}

@("event_map.encodeKeyEvent.matchesTheOracle")
@system nothrow @nogc
unittest
{
    auto f = EncoderFixture.open();
    char[128] buf;

    const(char)[] enc(in KeyEvent k) @system nothrow @nogc
        => encodeKeyEvent(f.encoder, f.event, k, buf);

    // The legacy classics, as the event stream delivers them.
    assert(enc(press(Key.enter)) == "\r");
    assert(enc(press(Key.tab)) == "\t");
    assert(enc(press(Key.escape)) == "\x1b");
    assert(enc(press(Key.backspace)) == "\x7f");
    assert(enc(press(Key.up)) == "\x1b[A");
    assert(enc(press(Key.home)) == "\x1b[H");
    assert(enc(press(Key.pageDown)) == "\x1b[6~");
    assert(enc(press(Key.f1)) == "\x1bOP");
    assert(enc(press(Key.f12)) == "\x1b[24~");

    // A typed letter: char_ + unshifted + paired text.
    assert(enc(press(Key.char_, Mods(), 'a', "a")) == "a");

    // Shift consumed by the layout: 'A' is text, not a modified sequence.
    assert(enc(press(Key.char_, Mods(shift: true), 'a', "A")) == "A");

    // Ctrl+letter: NO text arrives (nothing is typed), the unshifted
    // codepoint identifies the key — the case the default event stream
    // could not express at all.
    assert(enc(press(Key.char_, Mods(ctrl: true), 'a')) == "\x01");
    assert(enc(press(Key.char_, Mods(ctrl: true), 'c')) == "\x03");

    // Modified cursor keys.
    assert(enc(press(Key.up, Mods(ctrl: true))) == "\x1b[1;5A");
    assert(enc(press(Key.left, Mods(shift: true))) == "\x1b[1;2D");

    // A release encodes to nothing under the legacy protocol — and its text
    // is never forwarded (the pairing rule excludes releases).
    auto rel = press(Key.enter);
    rel.action = KeyAction.release;
    assert(enc(rel).length == 0);

    // A repeat encodes like a press.
    auto rep = press(Key.down);
    rep.action = KeyAction.repeat;
    assert(enc(rep) == "\x1b[B");

    // Plain text with no physical key (IME/compose): UNIDENTIFIED — the
    // caller writes the text raw, as the polling loop did.
    assert(ghosttyKeyOf(press(Key.char_, Mods(), 0)) == GHOSTTY_KEY_UNIDENTIFIED);
}

@("event_map.encodeKeyEvent.kittyDisambiguate")
@system nothrow @nogc
unittest
{
    auto f = EncoderFixture.open();
    char[128] buf;

    ubyte flags = 1;
    ghostty_key_encoder_setopt(f.encoder, GHOSTTY_KEY_ENCODER_OPT_KITTY_FLAGS, &flags);

    assert(encodeKeyEvent(f.encoder, f.event, press(Key.escape), buf) == "\x1b[27u");
    assert(encodeKeyEvent(f.encoder, f.event,
        press(Key.char_, Mods(ctrl: true), 'a'), buf) == "\x1b[97;5u");
}

@("terminal_view.event_map.terminalDecodedCharsEncode")
@system nothrow @nogc
unittest
{
    import sparkles.terminal_view.input : EncoderFixture;

    // The tui decoder's spellings — `ch` only, no unshifted, no text. The
    // identity patch routes them through the encoder, mode-aware, so a
    // kitty-protocol application still sees the escapes it negotiated.
    auto f = EncoderFixture.open();
    char[128] buf;

    const plain = withKeyIdentity(KeyEvent(Key.char_, 'e'));
    assert(encodeKeyEvent(f.encoder, f.event, plain, buf) == "e");

    const ctrl = withKeyIdentity(KeyEvent(Key.char_, 'c', Mods(ctrl: true)));
    assert(encodeKeyEvent(f.encoder, f.event, ctrl, buf) == "\x03");

    // An event already carrying its identity passes through untouched.
    const gui = KeyEvent(Key.char_, 'E', Mods(shift: true), KeyAction.press, 'e');
    assert(withKeyIdentity(gui).unshifted == 'e');
}

@("terminal_view.event_map.utf8OfCoversThePlanes")
@safe pure nothrow @nogc
unittest
{
    char[4] b = void;
    assert(utf8Of(b, 'A') == 1 && b[0] == 'A');
    assert(utf8Of(b, 'é') == 2 && b[0 .. 2] == "é");
    assert(utf8Of(b, '│') == 3 && b[0 .. 3] == "│");
    assert(utf8Of(b, '🙂') == 4 && b[0 .. 4] == "🙂");
    assert(utf8Of(b, cast(dchar) 0xD800) == 0, "a surrogate is not a scalar");
}
