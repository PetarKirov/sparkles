/**
What a desktop says about how its applications should look: the vocabulary
every source of it fills, and the parsers for the strings it arrives in.

Absence is first-class. A source sets `has…` for each preference it could
read; a desktop that answers three of four keys is described without
inventing the fourth (`libadwaita`'s `adw_settings_get_has_*` family is the
model).
*/
module sparkles.appearance.types;

import sparkles.base.buffer : InlineBuffer;
import sparkles.base.term_color : RgbColor;

@safe pure nothrow @nogc:

/// The colour scheme the user prefers.
enum SchemePreference : ubyte
{
    noPreference, ///
    light,        ///
    dark,         ///
}

/// How much contrast the user asks for.
enum ContrastLevel : ubyte
{
    standard, ///
    high,     ///
}

/// A control in a window's title bar.
enum WindowButton : ubyte
{
    close,    ///
    minimize, ///
    maximize, ///
    menu,     /// the window or application menu (`appmenu`, `menu`, `icon`)
}

/**
Which title-bar controls a window shows, in order, at its start (left) and
end (right) — GNOME's `button-layout`.
*/
struct ButtonLayout
{
    WindowButton[4] start, end; ///
    ubyte startCount, endCount; ///

@safe pure nothrow @nogc:

    /// The controls at the start, in order.
    const(WindowButton)[] atStart() const return => start[0 .. startCount];

    /// The controls at the end, in order.
    const(WindowButton)[] atEnd() const return => end[0 .. endCount];

    /// Whether `button` is shown at either end.
    bool shows(WindowButton button) const
    {
        foreach (b; atStart)
            if (b == button)
                return true;
        foreach (b; atEnd)
            if (b == button)
                return true;
        return false;
    }

    /// GNOME's default, `appmenu:close`.
    static ButtonLayout gnomeDefault()
    {
        ButtonLayout l;
        l.start[l.startCount++] = WindowButton.menu;
        l.end[l.endCount++] = WindowButton.close;
        return l;
    }
}

/**
Reads a `button-layout` string: names separated by commas, a colon between
the start's and the end's (`appmenu:minimize,maximize,close`). Without a
colon every control is at the start, as GTK places them. Unknown names
(`spacer`, a future control) and repeats are skipped, and at most four per
side are kept.
*/
ButtonLayout parseButtonLayout(scope const(char)[] text)
{
    ButtonLayout layout;
    bool atEnd;
    bool[WindowButton.max + 1] seen;
    size_t i;
    while (i <= text.length)
    {
        size_t j = i;
        while (j < text.length && text[j] != ',' && text[j] != ':')
            ++j;
        const name = trim(text[i .. j]);
        WindowButton b;
        bool known = true;
        switch (name)
        {
            case "close": b = WindowButton.close; break;
            case "minimize": b = WindowButton.minimize; break;
            case "maximize": b = WindowButton.maximize; break;
            case "appmenu", "menu", "icon": b = WindowButton.menu; break;
            default: known = false;
        }
        if (known && !seen[b])
        {
            seen[b] = true;
            if (atEnd && layout.endCount < layout.end.length)
                layout.end[layout.endCount++] = b;
            else if (!atEnd && layout.startCount < layout.start.length)
                layout.start[layout.startCount++] = b;
        }
        if (j < text.length && text[j] == ':')
            atEnd = true;
        i = j + 1;
    }
    return layout;
}

///
@("appearance.types.parseButtonLayout")
unittest
{
    auto l = parseButtonLayout("appmenu:minimize,maximize,close");
    assert(l.atStart == [WindowButton.menu]);
    assert(l.atEnd == [WindowButton.minimize, WindowButton.maximize, WindowButton.close]);
    l = parseButtonLayout("close,minimize:");
    assert(l.atStart == [WindowButton.close, WindowButton.minimize] && l.endCount == 0);
    l = parseButtonLayout(" close , spacer , close ");
    assert(l.atStart == [WindowButton.close], "no colon: the start; unknowns and repeats go");
    assert(parseButtonLayout("").startCount == 0);
    assert(!parseButtonLayout("appmenu:close").shows(WindowButton.maximize));
}

/**
A font as a desktop names it — Pango's `Family Style Size`, as
`org.gnome.desktop.interface font-name` holds it (`Adwaita Sans 11`).
*/
struct FontDescription
{
    InlineBuffer!(char, 64) family; /// may be a comma-separated list
    float size = 0;                 /// 0 where none was given
    bool sizeInPixels;              /// `px` after the size, else points
    bool bold, italic;              ///
}

/**
Reads a Pango font description: the family, then style words, then a size
(`Cantarell Bold Italic 11`, `Monospace 10px`). Style words are taken from
the end only, so a family containing one (`Noto Sans Mono`) stays whole.
*/
FontDescription parseFontDescription(scope const(char)[] text)
{
    FontDescription f;
    auto rest = trim(text);
    // The size: the last word, a number with an optional `px`.
    const lastStart = lastWordStart(rest);
    auto word = rest[lastStart .. $];
    bool px;
    if (word.length > 2 && word[$ - 2 .. $] == "px")
    {
        px = true;
        word = word[0 .. $ - 2];
    }
    float size;
    if (parseNumber(word, size))
    {
        f.size = size;
        f.sizeInPixels = px;
        rest = trim(rest[0 .. lastStart]);
    }
    for (;;)
    {
        const at = lastWordStart(rest);
        if (at == 0)
            break; // the family's first word is never a style
        const style = rest[at .. $];
        if (style == "Bold")
            f.bold = true;
        else if (style == "Italic" || style == "Oblique")
            f.italic = true;
        else if (style != "Regular" && style != "Normal" && style != "Book")
            break;
        rest = trim(rest[0 .. at]);
    }
    if (rest.length && rest[$ - 1] == ',')
        rest = rest[0 .. $ - 1];
    // At most what the buffer holds, cut before a list's family that does
    // not fit whole, else on a UTF-8 boundary.
    if (rest.length > f.family.capacity)
    {
        size_t cut = f.family.capacity;
        size_t comma = cut;
        while (comma > 0 && rest[comma - 1] != ',')
            --comma;
        if (comma > 1)
            cut = comma - 1;
        else
            while (cut > 0 && (rest[cut] & 0xC0) == 0x80)
                --cut;
        rest = trim(rest[0 .. cut]);
    }
    cast(void) f.family.assign(rest);
    return f;
}

///
@("appearance.types.parseFontDescription")
unittest
{
    auto f = parseFontDescription("Adwaita Sans 11");
    assert(f.family[] == "Adwaita Sans" && f.size == 11 && !f.sizeInPixels && !f.bold);
    f = parseFontDescription("Cantarell Bold Italic 10.5");
    assert(f.family[] == "Cantarell" && f.size == 10.5 && f.bold && f.italic);
    f = parseFontDescription("Monospace 12px");
    assert(f.family[] == "Monospace" && f.size == 12 && f.sizeInPixels);
    f = parseFontDescription("Noto Sans Mono");
    assert(f.family[] == "Noto Sans Mono" && f.size == 0);
    f = parseFontDescription("Bold 11");
    assert(f.family[] == "Bold", "the first word is the family's");
    assert(parseFontDescription("Sans .").family[] == "Sans .", "no digits: no size");
    assert(parseFontDescription("Sans 0").size == 0 && parseFontDescription("Sans 9999").size == 0);
    f = parseFontDescription("Noto Sans, Noto Sans CJK JP, Noto Sans Symbols 2, Noto Color Emoji 11");
    assert(f.family[] == "Noto Sans, Noto Sans CJK JP, Noto Sans Symbols 2" && f.size == 11,
        "a long list is cut before the family that does not fit");
}

/**
The desktop's preferences, each with whether a source could read it.
*/
struct SystemAppearance
{
    SchemePreference scheme; ///
    RgbColor accent;         ///
    ContrastLevel contrast;  ///
    bool reducedMotion;      ///
    ButtonLayout buttons;    /// the title bar's controls
    FontDescription font;    /// the interface font
    FontDescription titleFont; /// a title bar's

    bool hasScheme, hasAccent, hasContrast, hasReducedMotion, hasButtons, hasFont,
        hasTitleFont; ///

@safe pure nothrow @nogc:

    /// Whether the user prefers dark: `false` for light and for no
    /// preference, as GNOME draws "default" light.
    bool prefersDark() const => hasScheme && scheme == SchemePreference.dark;
}

/**
`SPARKLES_APPEARANCE`'s value (`dark`, `light`, `high-contrast`, comma
separated) laid over `a`: what a golden capture or a test pins, whatever the
desktop says. Unknown words are ignored.
*/
SystemAppearance overriddenBy(SystemAppearance a, scope const(char)[] value)
{
    size_t i;
    while (i < value.length)
    {
        size_t j = i;
        while (j < value.length && value[j] != ',')
            ++j;
        switch (trim(value[i .. j]))
        {
            case "dark": a.scheme = SchemePreference.dark; a.hasScheme = true; break;
            case "light": a.scheme = SchemePreference.light; a.hasScheme = true; break;
            case "high-contrast": a.contrast = ContrastLevel.high; a.hasContrast = true; break;
            case "reduced-motion": a.reducedMotion = a.hasReducedMotion = true; break;
            default: break;
        }
        i = j + 1;
    }
    return a;
}

///
@("appearance.types.overriddenBy")
unittest
{
    SystemAppearance a;
    a.scheme = SchemePreference.light;
    a.hasScheme = true;
    const o = a.overriddenBy("dark, high-contrast, sepia");
    assert(o.prefersDark && o.contrast == ContrastLevel.high && o.hasContrast);
    assert(!a.overriddenBy("").prefersDark);
}

private const(char)[] trim(return scope const(char)[] s)
{
    while (s.length && (s[0] == ' ' || s[0] == '\t'))
        s = s[1 .. $];
    while (s.length && (s[$ - 1] == ' ' || s[$ - 1] == '\t'))
        s = s[0 .. $ - 1];
    return s;
}

private size_t lastWordStart(scope const(char)[] s)
{
    size_t i = s.length;
    while (i > 0 && s[i - 1] != ' ')
        --i;
    return i;
}

private bool parseNumber(scope const(char)[] s, out float value)
{
    if (s.length == 0)
        return false;
    bool digits;
    double v = 0, scale = 0;
    foreach (c; s)
    {
        if (c == '.' && scale == 0)
            scale = 1;
        else if (c >= '0' && c <= '9')
        {
            digits = true;
            if (scale > 0)
            {
                scale /= 10;
                v += (c - '0') * scale;
            }
            else
                v = v * 10 + (c - '0');
        }
        else
            return false;
    }
    // A size a font can have: some digits, and short of absurd.
    if (!digits || v <= 0 || v > 1000)
        return false;
    value = cast(float) v;
    return true;
}
