/**
The appearance files nix-on-droid's `terminal` module writes into `~/.termux`
(docs/specs/terminal/android.md, `NOD11`): `colors.properties`, Termux's colour
scheme format. (`font.ttf` needs no parsing — it is a font path.) Pure, and
host-tested.
*/
module termux_config;

import sparkles.base.term_color : RgbColor;
import sparkles.terminal_view.component : ColorOverrides;

/**
Parse `colors.properties`: `foreground`, `background`, `cursor` and
`color0`…`color15`, each `#rrggbb` or `#rgb`. Unknown keys and unparsable
values are skipped — a scheme with one typo still applies the rest.
*/
ColorOverrides parseTermuxColors(const(char)[] text) @safe pure
{
    import std.conv : to;
    import std.string : startsWith;

    import extra_keys : propertyValue;

    ColorOverrides c;
    RgbColor v;
    if (parseHexColor(propertyValue(text, "foreground"), v))
    {
        c.foreground = v;
        c.hasForeground = true;
    }
    if (parseHexColor(propertyValue(text, "background"), v))
    {
        c.background = v;
        c.hasBackground = true;
    }
    if (parseHexColor(propertyValue(text, "cursor"), v))
    {
        c.cursor = v;
        c.hasCursor = true;
    }
    foreach (i; 0 .. 16)
        if (parseHexColor(propertyValue(text, "color" ~ i.to!string), v))
        {
            c.palette[i] = v;
            c.paletteMask |= cast(ushort)(1 << i);
        }
    return c;
}

///
@("termux_config.parseTermuxColors")
@safe pure unittest
{
    const c = parseTermuxColors(
        "# dracula\nforeground=#f8f8f2\nbackground = #282a36\ncursor=#fff\n" ~
        "color1=#ff5555\ncolor15=#ffffff\ncolor3=nonsense\n");
    assert(c.hasForeground && c.foreground == RgbColor(0xf8, 0xf8, 0xf2));
    assert(c.hasBackground && c.background == RgbColor(0x28, 0x2a, 0x36));
    assert(c.hasCursor && c.cursor == RgbColor(0xff, 0xff, 0xff), "#rgb expands");
    assert(c.paletteMask == ((1 << 1) | (1 << 15)), "an unparsable entry is skipped");
    assert(c.palette[1] == RgbColor(0xff, 0x55, 0x55));
    assert(!parseTermuxColors("").any);
}

/// `#rrggbb` or `#rgb` (surrounding blanks allowed).
bool parseHexColor(const(char)[] s, out RgbColor c) @safe pure nothrow @nogc
{
    import std.ascii : isHexDigit;

    static ubyte nibble(char ch) => cast(ubyte)(ch <= '9' ? ch - '0'
        : (ch | 0x20) - 'a' + 10);

    while (s.length && (s[0] == ' ' || s[0] == '\t'))
        s = s[1 .. $];
    while (s.length && (s[$ - 1] == ' ' || s[$ - 1] == '\t'))
        s = s[0 .. $ - 1];
    if (s.length < 1 || s[0] != '#')
        return false;
    s = s[1 .. $];
    foreach (ch; s)
        if (!ch.isHexDigit)
            return false;
    if (s.length == 6)
    {
        c = RgbColor(cast(ubyte)(nibble(s[0]) << 4 | nibble(s[1])),
            cast(ubyte)(nibble(s[2]) << 4 | nibble(s[3])),
            cast(ubyte)(nibble(s[4]) << 4 | nibble(s[5])));
        return true;
    }
    if (s.length == 3)
    {
        c = RgbColor(cast(ubyte)(nibble(s[0]) * 17), cast(ubyte)(nibble(s[1]) * 17),
            cast(ubyte)(nibble(s[2]) * 17));
        return true;
    }
    return false;
}
