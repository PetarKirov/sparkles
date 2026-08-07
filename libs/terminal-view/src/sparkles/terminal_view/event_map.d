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
import sparkles.input : Key, KeyAction, KeyEvent, Mods;
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
