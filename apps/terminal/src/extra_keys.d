/**
The extra-keys row (docs/specs/terminal/android.md, `NOD10`): what the soft
keyboard lacks — Esc, Tab, Ctrl, Alt, arrows, paging — as a row of buttons
above it, configured the way Termux configures it, so nix-on-droid's users
keep their `~/.termux/termux.properties`.

This module is the pure half: the Termux properties format, the key
vocabulary, and the latching modifiers. Drawing and hit-testing are
`droid_terminal.d`'s.
*/
module extra_keys;

import sparkles.input : Key, KeyAction, KeyEvent, Mods;

import settings : ExtraKeysVisibility;

/// What a button does.
enum ExtraKeyKind
{
    key, /// a named key (`ESC`, `UP`, `F5`)
    text, /// a literal string (`-`, `/`, `~`)
    modifier, /// `CTRL`, `ALT`, `SHIFT`: latch for the next key
    keyboard, /// `KEYBOARD`: show/hide the soft keyboard
    menu, /// `MENU`: the key guide at the root (`TKM7`)
}

/// One button.
struct ExtraKey
{
    ExtraKeyKind kind;
    Key key; /// `key` and `modifier` kinds
    string text; /// `text` kind
    string label; /// what the button shows
}

/// The default layout: Termux's (`TermuxPropertyConstants`) with `PGDN`
/// giving its place to `MENU`, the key guide (`TKM7`, mockup E) — on a phone the
/// guide is the only way to the terminal's commands.
enum defaultExtraKeysSpec = `[['ESC','/','-','HOME','UP','END','PGUP'],` ~
    ` ['TAB','CTRL','ALT','LEFT','DOWN','RIGHT','MENU']]`;

/// The rows `termux.properties` asks for, or the default layout when the file
/// has no (or an unparsable) `extra-keys` entry. An explicit empty layout
/// (`extra-keys = []`) is honoured: no row at all.
ExtraKey[][] extraKeysFrom(const(char)[] propertiesText) @safe pure
{
    const spec = propertyValue(propertiesText, "extra-keys");
    if (spec !is null)
    {
        ExtraKey[][] rows;
        if (parseExtraKeysSpec(spec, rows))
            return rows;
    }
    ExtraKey[][] defaults;
    const ok = parseExtraKeysSpec(defaultExtraKeysSpec, defaults);
    assert(ok);
    return defaults;
}

///
@("extra_keys.extraKeysFrom")
@safe pure unittest
{
    const def = extraKeysFrom("");
    assert(def.length == 2 && def[0].length == 7);
    assert(def[0][0] == ExtraKey(ExtraKeyKind.key, Key.escape, null, "ESC"));
    assert(def[0][1] == ExtraKey(ExtraKeyKind.text, Key.none, "/", "/"));
    assert(def[1][1] == ExtraKey(ExtraKeyKind.modifier, Key.ctrl, null, "CTRL"));
    assert(def[1][6] == ExtraKey(ExtraKeyKind.menu, Key.none, null, "☰"), "MENU by default");

    // The emulator test's layout (nix-on-droid tests/emulator), across a
    // continuation line, with a `{key: …}` object.
    const custom = extraKeysFrom("# mine\nextra-keys = [['PGUP', {key: F12, display: 'f12'}], \\\n  ['KEYBOARD']]\n");
    assert(custom.length == 2);
    assert(custom[0][0].key == Key.pageUp);
    assert(custom[0][1] == ExtraKey(ExtraKeyKind.key, Key.f12, null, "f12"));
    assert(custom[1][0].kind == ExtraKeyKind.keyboard);

    assert(extraKeysFrom("extra-keys = []").length == 0, "an empty layout is a choice");
    assert(extraKeysFrom("extra-keys = [[oops").length == 2, "garbage falls back");
}

/**
The rows an `extraKeys.layout` setting asks for (`TCF7`): Termux syntax, an
empty list honoured as "no row". An unparsable layout falls back to the
default and leaves a warning saying so.
*/
ExtraKey[][] extraKeysFromLayout(const(char)[] layout, ref string[] warnings) @safe pure
{
    ExtraKey[][] rows;
    if (parseExtraKeysSpec(layout, rows))
        return rows;
    warnings ~= "config: $.extraKeys.layout: \"" ~ layout.idup
        ~ "\" is not an extra-keys layout — the default layout is used";
    const ok = parseExtraKeysSpec(defaultExtraKeysSpec, rows);
    assert(ok);
    return rows;
}

@("extra_keys.extraKeysFromLayout")
@safe pure unittest
{
    string[] warnings;
    assert(extraKeysFromLayout("[['ESC']]", warnings).length == 1);
    assert(extraKeysFromLayout("[]", warnings).length == 0, "an empty layout is a choice");
    assert(warnings.length == 0);
    assert(extraKeysFromLayout("[[oops", warnings).length == 2, "garbage falls back");
    assert(warnings.length == 1);
}

/**
Whether the row shows (`TCF7`). `automatic` shows it while the soft keyboard
is up, and while no hardware keyboard is attached; `dismissed` is the
row swiped away, which holds until it is swiped back, whatever the setting.
*/
bool extraKeysShown(ExtraKeysVisibility v, bool softKeyboardShown,
    bool hardwareKeyboard, bool dismissed) @safe pure nothrow @nogc
{
    if (dismissed)
        return false;
    final switch (v)
    {
        case ExtraKeysVisibility.automatic:
            return softKeyboardShown || !hardwareKeyboard;
        case ExtraKeysVisibility.always:
            return true;
        case ExtraKeysVisibility.never:
            return false;
    }
}

@("extra_keys.extraKeysShown")
@safe pure nothrow @nogc unittest
{
    alias V = ExtraKeysVisibility;
    // auto: a hardware keyboard with the soft one down hides the row ...
    assert(!extraKeysShown(V.automatic, false, true, false));
    // ... and the soft keyboard brings it back, as does detaching.
    assert(extraKeysShown(V.automatic, true, true, false));
    assert(extraKeysShown(V.automatic, false, false, false));
    assert(extraKeysShown(V.always, false, true, false));
    assert(!extraKeysShown(V.never, true, false, false));
    assert(!extraKeysShown(V.always, true, false, true), "a swipe-away holds");
}

/**
A Java-properties value: `key = value`, `key: value` or `key value`, `#`/`!`
comments, `\` continuing a line (the continuation's leading blanks dropped).
`null` when the key is absent. Escapes other than the continuation are kept
verbatim — Termux's values do not use them.
*/
string propertyValue(const(char)[] text, const(char)[] key) @safe pure
{
    import std.string : indexOfAny, lineSplitter, strip, stripLeft;

    string logical;
    bool continuing;
    string found;
    foreach (raw; text.lineSplitter)
    {
        auto line = raw.stripLeft;
        if (!continuing && (line.length == 0 || line[0] == '#' || line[0] == '!'))
            continue;
        continuing = line.length && line[$ - 1] == '\\';
        logical ~= continuing ? line[0 .. $ - 1] : line;
        if (continuing)
            continue;

        const sep = logical.indexOfAny("=: \t");
        const k = sep < 0 ? logical : logical[0 .. sep];
        if (k == key)
        {
            auto v = sep < 0 ? "" : logical[sep + 1 .. $].stripLeft;
            if (v.length && (v[0] == '=' || v[0] == ':'))
                v = v[1 .. $];
            found = v.strip.idup;
        }
        logical = null;
    }
    return found;
}

///
@("extra_keys.propertyValue")
@safe pure unittest
{
    assert(propertyValue("a=1\nb : two\nc three\n", "b") == "two");
    assert(propertyValue("c three", "c") == "three");
    assert(propertyValue("# a=1\n", "a") is null);
    assert(propertyValue("a = x \\\n    y", "a") == "x y");
    assert(propertyValue("a=1\na=2", "a") == "2", "the last definition wins");
}

/**
Parse Termux's `extra-keys` syntax: a JSON-ish array of rows, each an array of
buttons; a button is a key name or string (single or double quotes, or bare),
or an object whose `key` names it and whose optional `display` labels it.
Returns `false` on anything malformed.
*/
bool parseExtraKeysSpec(const(char)[] spec, out ExtraKey[][] rows) @safe pure
{
    auto p = SpecParser(spec);
    if (!p.expect('['))
        return false;
    for (;;)
    {
        if (p.peek(']'))
            return p.expect(']') && p.atEnd;
        ExtraKey[] row;
        if (!p.expect('['))
            return false;
        while (!p.peek(']'))
        {
            string name, display;
            if (p.peek('{'))
            {
                if (!p.object(name, display))
                    return false;
            }
            else if (!p.scalar(name))
                return false;
            row ~= extraKey(name, display);
            if (!p.comma())
                break;
        }
        if (!p.expect(']'))
            return false;
        rows ~= row;
        if (!p.comma())
            return p.expect(']') && p.atEnd;
    }
}

/// The button a Termux key name (or literal) stands for.
ExtraKey extraKey(string name, string display = null) @safe pure
{
    import sparkles.base.text.case_text : asciiUpper;

    const label = display.length ? display : name;
    const upper = name.asciiUpper;
    Key k;
    switch (upper)
    {
        case "ESC", "ESCAPE": k = Key.escape; break;
        case "TAB": k = Key.tab; break;
        case "HOME": k = Key.home; break;
        case "END": k = Key.end; break;
        case "PGUP": k = Key.pageUp; break;
        case "PGDN": k = Key.pageDown; break;
        case "INS": k = Key.insert; break;
        case "DEL": k = Key.delete_; break;
        case "BKSP": k = Key.backspace; break;
        case "ENTER": k = Key.enter; break;
        case "UP": k = Key.up; break;
        case "DOWN": k = Key.down; break;
        case "LEFT": k = Key.left; break;
        case "RIGHT": k = Key.right; break;
        case "F1": k = Key.f1; break;
        case "F2": k = Key.f2; break;
        case "F3": k = Key.f3; break;
        case "F4": k = Key.f4; break;
        case "F5": k = Key.f5; break;
        case "F6": k = Key.f6; break;
        case "F7": k = Key.f7; break;
        case "F8": k = Key.f8; break;
        case "F9": k = Key.f9; break;
        case "F10": k = Key.f10; break;
        case "F11": k = Key.f11; break;
        case "F12": k = Key.f12; break;
        case "CTRL": return ExtraKey(ExtraKeyKind.modifier, Key.ctrl, null, label);
        case "ALT": return ExtraKey(ExtraKeyKind.modifier, Key.alt, null, label);
        case "SHIFT": return ExtraKey(ExtraKeyKind.modifier, Key.shift, null, label);
        case "KEYBOARD": return ExtraKey(ExtraKeyKind.keyboard, Key.none, null, label);
        case "MENU": return ExtraKey(ExtraKeyKind.menu, Key.none, null, display.length ? display : "☰");
        case "SPACE": return ExtraKey(ExtraKeyKind.text, Key.none, " ", display.length ? display : "␣");
        case "BACKSLASH": return ExtraKey(ExtraKeyKind.text, Key.none, "\\", display.length ? display : "\\");
        case "QUOTE": return ExtraKey(ExtraKeyKind.text, Key.none, "\"", display.length ? display : "\"");
        case "APOSTROPHE": return ExtraKey(ExtraKeyKind.text, Key.none, "'", display.length ? display : "'");
        default:
            return ExtraKey(ExtraKeyKind.text, Key.none, name, label);
    }
    return ExtraKey(ExtraKeyKind.key, k, null, label);
}

/**
The modifiers latched by the row's CTRL/ALT/SHIFT buttons. A latch applies to
the next key — from the row or the keyboard — and is then released; tapping a
latched modifier again releases it without a key.
*/
struct Latch
{
    Mods mods;

    /// Toggle the modifier `k` (`Key.ctrl`, `Key.alt`, `Key.shift`).
    void toggle(Key k) @safe pure nothrow @nogc
    {
        switch (k)
        {
            case Key.ctrl: mods.ctrl = !mods.ctrl; break;
            case Key.alt: mods.alt = !mods.alt; break;
            case Key.shift: mods.shift = !mods.shift; break;
            default: break;
        }
    }

    /// Whether `k`'s latch is on (for drawing the button).
    bool isOn(Key k) const @safe pure nothrow @nogc
        => k == Key.ctrl ? mods.ctrl : k == Key.alt ? mods.alt
            : k == Key.shift ? mods.shift : false;

    /// Whether anything is latched.
    bool any() const @safe pure nothrow @nogc => mods.ctrl || mods.alt || mods.shift;

    /**
    `e` with the latched modifiers applied, releasing them. A typed ASCII
    character becomes the chord a physical keyboard would send: Ctrl+c is
    the `c` key with Ctrl held and no text (the encoder turns it into 0x03),
    exactly the full-keyboard grade's shape on the desktop.
    */
    KeyEvent apply(KeyEvent e) @safe pure nothrow @nogc
    {
        if (!any || e.action == KeyAction.release)
            return e;
        e.mods.ctrl |= mods.ctrl;
        e.mods.alt |= mods.alt;
        e.mods.shift |= mods.shift;
        if (e.key == Key.char_ && (mods.ctrl || mods.alt))
        {
            dchar c = e.unshifted ? e.unshifted : e.ch;
            if (c == 0 && e.text.length == 1)
                c = e.text[0];
            if (c >= 'A' && c <= 'Z')
                c += 'a' - 'A';
            e.unshifted = c;
            e.ch = 0;
            e.text = null;
        }
        mods = Mods.init;
        return e;
    }
}

///
@("extra_keys.Latch")
@safe pure nothrow @nogc unittest
{
    Latch l;
    l.toggle(Key.ctrl);
    assert(l.isOn(Key.ctrl));

    KeyEvent typed;
    typed.key = Key.char_;
    typed.unshifted = 'c';
    typed.text = "c";
    const chord = l.apply(typed);
    assert(chord.mods.ctrl && chord.unshifted == 'c' && chord.text.length == 0,
        "a typed c under a Ctrl latch is Ctrl+c");
    assert(!l.any, "the latch is one-shot");

    KeyEvent plain;
    plain.key = Key.char_;
    plain.text = "x";
    assert(l.apply(plain).text == "x", "no latch, no change");

    l.toggle(Key.alt);
    l.toggle(Key.alt);
    assert(!l.any, "a second tap releases");
}

private struct SpecParser
{
    const(char)[] s;
    size_t i;

    @safe pure:

    void skip()
    {
        while (i < s.length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r'))
            ++i;
    }

    bool atEnd()
    {
        skip();
        return i == s.length;
    }

    bool peek(char c)
    {
        skip();
        return i < s.length && s[i] == c;
    }

    bool expect(char c)
    {
        if (!peek(c))
            return false;
        ++i;
        return true;
    }

    /// Consume a `,` if there is one; `true` when there was.
    bool comma() => expect(',');

    bool scalar(out string v)
    {
        skip();
        if (i >= s.length)
            return false;
        const q = s[i];
        if (q == '\'' || q == '"')
        {
            const start = ++i;
            while (i < s.length && s[i] != q)
                ++i;
            if (i >= s.length)
                return false;
            v = s[start .. i].idup;
            ++i;
            return true;
        }
        const start = i;
        while (i < s.length && s[i] != ',' && s[i] != ']' && s[i] != '}'
            && s[i] != ':' && s[i] != ' ' && s[i] != '\t' && s[i] != '\n')
            ++i;
        v = s[start .. i].idup;
        return v.length > 0;
    }

    bool object(out string key, out string display)
    {
        if (!expect('{'))
            return false;
        while (!peek('}'))
        {
            string name, value;
            if (!scalar(name) || !expect(':') || !scalar(value))
                return false;
            if (name == "key")
                key = value;
            else if (name == "display")
                display = value;
            if (!comma())
                break;
        }
        return expect('}') && key.length > 0;
    }
}
