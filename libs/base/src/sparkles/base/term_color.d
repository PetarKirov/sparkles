/**
Terminal color foundation: the `Color` type, capability tiers, depth folding,
and SGR color-parameter emission.

This is the single home for how sparkles models a terminal color and turns it
into SGR bytes.

$(LREF Color) is a four-case value (`unset`, `default_`, `palette`, `rgb`)
covering everything a theme or style expresses; `unset` (`Color.init`) is "not
specified", `default_` is "the terminal's own default". It is the shared type
consumed by `sparkles.base.styled_template`, `sparkles.syntax` (re-exported as
`sparkles.syntax.color.Color`), and any future cell-grid backend.

$(LREF ColorDepth) + $(LREF classifyColorDepth) name the capability tiers and
their pure, CTFE-able classifier; $(LREF detectColorDepth) is the thin
environment-reading edge for standalone use. $(LREF ansi256FromRgb),
$(LREF ansi16FromRgb), and $(LREF xterm256ToRgb) are the depth fold — themes
author in 24-bit RGB and terminals that speak only 256 or 16 colors get the
nearest approximation.

$(LREF writeSgrColor) emits the SGR *parameters* selecting a color on a
$(LREF ColorChannel) (foreground/background/underline), depth-folded. The escape
`ESC[`/`m` wrapper and the transition diff live in
`sparkles.base.term_style.writeStyleTransition`.

`#RRGGBBAA` hex parsing ($(LREF parseHexColor)) understands bat's alpha
convention (alpha 0 ⇒ palette index, alpha 1 ⇒ terminal default) at the
boundary, turning the encoding trick into structure.
*/
module sparkles.base.term_color;

import sparkles.base.text.errors : ParseErrorCode, ParseExpected, parseErr, parseOk;
import sparkles.base.text.readers : hexNibble, isHexDigit;

@safe:

/// Terminal color capability tiers, most capable last.
enum ColorDepth : ubyte
{
    none,      /// no color output (TERM=dumb, redirected without force, …)
    ansi16,    /// the classic 16 SGR colors
    ansi256,   /// the xterm 256-color palette
    trueColor, /// 24-bit `38;2;r;g;b` SGR sequences
}

/**
Pure classification of terminal color depth from `$COLORTERM` and `$TERM`
values (testable, CTFE-able): `COLORTERM=truecolor|24bit` or a `-direct`
`TERM` ⇒ `trueColor`; a `256color` `TERM` ⇒ `ansi256`; `TERM=dumb` ⇒ `none`;
anything else ⇒ `ansi16`.

Whether color should be emitted $(I at all) is a separate decision the caller
owns; this classifier only picks the tier.
*/
ColorDepth classifyColorDepth(scope const(char)[] colorterm, scope const(char)[] term)
    pure nothrow @nogc
{
    import std.algorithm.searching : canFind;

    if (term == "dumb")
        return ColorDepth.none;
    if (colorterm == "truecolor" || colorterm == "24bit")
        return ColorDepth.trueColor;
    if (term.canFind("direct"))
        return ColorDepth.trueColor;
    if (term.canFind("256color"))
        return ColorDepth.ansi256;
    return ColorDepth.ansi16;
}

///
@("term_color.classifyColorDepth")
unittest
{
    assert(classifyColorDepth("truecolor", "xterm-256color") == ColorDepth.trueColor);
    assert(classifyColorDepth("24bit", "xterm") == ColorDepth.trueColor);
    assert(classifyColorDepth("", "xterm-direct") == ColorDepth.trueColor);
    assert(classifyColorDepth("", "xterm-256color") == ColorDepth.ansi256);
    assert(classifyColorDepth("", "xterm") == ColorDepth.ansi16);
    assert(classifyColorDepth("", "dumb") == ColorDepth.none);
    assert(classifyColorDepth("truecolor", "dumb") == ColorDepth.none);
}

@("term_color.classifyColorDepth.ctfe")
unittest
{
    // The classifier is CTFE-able (no environment reads).
    static assert(classifyColorDepth("truecolor", "xterm") == ColorDepth.trueColor);
    static assert(classifyColorDepth("", "screen-256color") == ColorDepth.ansi256);
}

/// Reads `$COLORTERM`/`$TERM` and classifies via $(LREF classifyColorDepth).
/// The thin environment-reading edge for standalone use; an app already holding
/// a $(REF TermCaps, sparkles,core_cli,term_caps) reads `.colorDepth` instead.
ColorDepth detectColorDepth()
{
    import std.process : environment;

    return classifyColorDepth(environment.get("COLORTERM", ""), environment.get("TERM", ""));
}

/// A 24-bit RGB color value.
struct RgbColor
{
    ubyte r, g, b;
}

/**
A terminal color: one of four cases.

$(LIST
    * `unset` — not specified (the default, `Color.init`);
    * `default_` — use the terminal's default fore-/background;
    * `palette` — a terminal-palette index (0–255) in `index`;
    * `rgb` — a 24-bit value in `rgb`.
)
*/
struct Color
{
    /// Discriminates the four cases.
    enum Kind : ubyte
    {
        unset,    /// not specified
        default_, /// the terminal's default color
        palette,  /// a terminal-palette index (`index`)
        rgb,      /// a 24-bit value (`rgb`)
    }

    Kind kind;    /// which case this color is
    ubyte index;  /// palette index (kind == palette)
    RgbColor rgb; /// 24-bit value (kind == rgb)

@safe pure nothrow @nogc:

    /// The terminal-default color.
    enum Color defaultColor = Color(Kind.default_);

    /// Constructs an RGB color from three bytes, or a single `ubyte[3]` — which a
    /// `x"…"` hex-string literal converts to, giving a lightweight hex spelling.
    /// ---
    /// auto mauve = Color.fromRgb(0xcb, 0xa6, 0xf7);
    /// auto same  = Color.fromRgb(x"cba6f7");
    /// assert(mauve == same);
    /// ---
    static Color fromRgb(const ubyte[3] rgb...)
        => Color(kind: Kind.rgb, rgb: RgbColor(rgb[0], rgb[1], rgb[2]));

    /// ditto
    static Color fromRgb(RgbColor c)
        => Color(kind: Kind.rgb, rgb: c);

    /// Constructs a terminal-palette color.
    static Color fromPalette(ubyte index)
        => Color(kind: Kind.palette, index: index);

    /// `true` iff this color is specified at all (not `unset`).
    bool isSet() const scope
        => kind != Kind.unset;
}

///
@("color.Color.cases")
pure nothrow @nogc
unittest
{
    assert(!Color.init.isSet);
    assert(Color.defaultColor.kind == Color.Kind.default_);

    const c = Color.fromRgb(0x1e, 0x1e, 0x2e);
    assert(c.kind == Color.Kind.rgb && c.rgb == RgbColor(0x1e, 0x1e, 0x2e));

    // A hex-string literal is a `ubyte[3]` (2.108) — same as three bytes.
    assert(Color.fromRgb(x"1e1e2e") == c);

    const p = Color.fromPalette(4);
    assert(p.kind == Color.Kind.palette && p.index == 4);
}

/**
Parses `#RGB`, `#RRGGBB`, or `#RRGGBBAA` at the front of `input`, advancing
it past the parsed color on success (the `readers.d` cursor convention).

`#RGB` expands each nibble (`#fa0` ⇒ `#ffaa00`). `#RRGGBBAA` follows bat's
alpha conventions: alpha `00` ⇒ palette index `RR`; alpha `01` ⇒ the
terminal-default color; any other alpha ⇒ the RGB value (alpha discarded).
*/
ParseExpected!Color parseHexColor(ref scope const(char)[] input) pure nothrow @nogc
{
    if (input.length == 0)
        return parseErr!Color(ParseErrorCode.emptyInput, 0);
    if (input[0] != '#')
        return parseErr!Color(ParseErrorCode.unexpectedCharacter, 0, "expected '#'");

    size_t n = 1;
    while (n < input.length && isHexDigit(input[n]))
        ++n;

    Color result;
    switch (n - 1)
    {
        case 3:
            result = Color.fromRgb(
                cast(ubyte)(hexNibble(input[1]) * 17),
                cast(ubyte)(hexNibble(input[2]) * 17),
                cast(ubyte)(hexNibble(input[3]) * 17));
            break;
        case 6:
            result = Color.fromRgb(hexByte(input[1], input[2]),
                hexByte(input[3], input[4]), hexByte(input[5], input[6]));
            break;
        case 8:
        {
            const r = hexByte(input[1], input[2]);
            const alpha = hexByte(input[7], input[8]);
            if (alpha == 0)
                result = Color.fromPalette(r);
            else if (alpha == 1)
                result = Color.defaultColor;
            else
                result = Color.fromRgb(r, hexByte(input[3], input[4]),
                    hexByte(input[5], input[6]));
            break;
        }
        default:
            return parseErr!Color(ParseErrorCode.widthMismatch, 1,
                "expected 3, 6, or 8 hex digits after '#'");
    }

    input = input[n .. $];
    return parseOk(result);
}

///
@("color.parseHexColor.forms")
pure nothrow @nogc
unittest
{
    const(char)[] s = "#fa0 rest";
    auto short3 = parseHexColor(s);
    assert(short3.hasValue && short3.value == Color.fromRgb(0xff, 0xaa, 0x00));
    assert(s == " rest");

    s = "#1e1e2e";
    assert(parseHexColor(s).value == Color.fromRgb(0x1e, 0x1e, 0x2e));
    assert(s.length == 0);

    // bat alpha conventions
    s = "#0400000f"; // alpha 0x0f: plain RGB, alpha discarded
    assert(parseHexColor(s).value == Color.fromRgb(0x04, 0x00, 0x00));
    s = "#04000000"; // alpha 00: palette index 0x04
    assert(parseHexColor(s).value == Color.fromPalette(0x04));
    s = "#00000001"; // alpha 01: terminal default
    assert(parseHexColor(s).value == Color.defaultColor);
}

@("color.parseHexColor.rejects")
pure nothrow @nogc
unittest
{
    static ParseErrorCode errorOf(string text) pure nothrow @nogc
    {
        const(char)[] s = text;
        return parseHexColor(s).error.code;
    }

    assert(errorOf("") == ParseErrorCode.emptyInput);
    assert(errorOf("fff") == ParseErrorCode.unexpectedCharacter);
    assert(errorOf("#") == ParseErrorCode.widthMismatch);
    assert(errorOf("#ff") == ParseErrorCode.widthMismatch);
    assert(errorOf("#ffff") == ParseErrorCode.widthMismatch);
    assert(errorOf("#fffffff") == ParseErrorCode.widthMismatch);
    assert(errorOf("#fffffffff") == ParseErrorCode.widthMismatch);

    // failed parses must not advance the cursor
    const(char)[] s = "#zz";
    assert(parseHexColor(s).hasError);
    assert(s == "#zz");
}

/**
Nearest xterm-256 palette index for an RGB value: the 6×6×6 color cube
(levels 0, 95, 135, 175, 215, 255; indices 16–231) or the 24-step grayscale
ramp (values 8–238; indices 232–255), whichever is closer.
*/
ubyte ansi256FromRgb(in RgbColor c) pure nothrow @nogc
{
    static immutable ubyte[6] cubeLevels = [0, 95, 135, 175, 215, 255];

    static size_t nearestCubeIndex(ubyte v) pure nothrow @nogc @safe
    {
        // midpoints between consecutive levels: 47.5, 115, 155, 195, 235
        if (v < 48)
            return 0;
        if (v < 115)
            return 1;
        return (v - 35) / 40;
    }

    const ri = nearestCubeIndex(c.r);
    const gi = nearestCubeIndex(c.g);
    const bi = nearestCubeIndex(c.b);
    const cube = RgbColor(cubeLevels[ri], cubeLevels[gi], cubeLevels[bi]);

    const avg = (c.r + c.g + c.b) / 3;
    const grayIndex = avg < 8 ? 0
        : avg > 238 ? 23
        : (avg - 3) / 10;
    const grayValue = cast(ubyte)(8 + 10 * grayIndex);
    const gray = RgbColor(grayValue, grayValue, grayValue);

    return colorDistanceSq(c, cube) <= colorDistanceSq(c, gray)
        ? cast(ubyte)(16 + 36 * ri + 6 * gi + bi)
        : cast(ubyte)(232 + grayIndex);
}

///
@("color.ansi256FromRgb.corners")
pure nothrow @nogc
unittest
{
    // cube corners
    assert(ansi256FromRgb(RgbColor(0, 0, 0)) == 16);
    assert(ansi256FromRgb(RgbColor(255, 255, 255)) == 231);
    assert(ansi256FromRgb(RgbColor(255, 0, 0)) == 196);
    assert(ansi256FromRgb(RgbColor(0, 255, 0)) == 46);
    assert(ansi256FromRgb(RgbColor(0, 0, 255)) == 21);
    // exact cube levels
    assert(ansi256FromRgb(RgbColor(95, 135, 175)) == 16 + 36 * 1 + 6 * 2 + 3);
    // grays land on the ramp, not the cube
    assert(ansi256FromRgb(RgbColor(8, 8, 8)) == 232);
    assert(ansi256FromRgb(RgbColor(128, 128, 128)) == 232 + 12);
    assert(ansi256FromRgb(RgbColor(238, 238, 238)) == 255);
}

/// The xterm default values for the classic 16 palette entries.
private static immutable RgbColor[16] base16Palette = [
    RgbColor(0, 0, 0),       // black
    RgbColor(205, 0, 0),     // red
    RgbColor(0, 205, 0),     // green
    RgbColor(205, 205, 0),   // yellow
    RgbColor(0, 0, 238),     // blue
    RgbColor(205, 0, 205),   // magenta
    RgbColor(0, 205, 205),   // cyan
    RgbColor(229, 229, 229), // white
    RgbColor(127, 127, 127), // bright black
    RgbColor(255, 0, 0),     // bright red
    RgbColor(0, 255, 0),     // bright green
    RgbColor(255, 255, 0),   // bright yellow
    RgbColor(92, 92, 255),   // bright blue
    RgbColor(255, 0, 255),   // bright magenta
    RgbColor(0, 255, 255),   // bright cyan
    RgbColor(255, 255, 255), // bright white
];

/**
Nearest classic-16 palette index (0–15) for an RGB value, measured against
the xterm default palette. Foreground SGR codes are `30 + i` (or `90 + i - 8`
for the bright half); $(LREF writeSgrColor) derives them.
*/
ubyte ansi16FromRgb(in RgbColor c) pure nothrow @nogc
{
    import std.algorithm.searching : minIndex;

    // nearest palette entry by squared distance (first min wins on ties). The
    // distances are materialised into a stack array rather than a lazy `map`
    // over a `c`-capturing lambda, which would allocate a closure under @nogc.
    uint[base16Palette.length] dists = void;
    foreach (i, entry; base16Palette)
        dists[i] = colorDistanceSq(c, entry);
    return cast(ubyte) dists[].minIndex;
}

/**
The RGB value behind an xterm-256 palette index (xterm defaults for the
classic 16). Inverse of $(LREF ansi256FromRgb) on palette-exact values, and
the concretization step a non-terminal (e.g. GPU) backend uses to resolve
`Color.Kind.palette` against a concrete palette.
*/
RgbColor xterm256ToRgb(ubyte index) pure nothrow @nogc
{
    static immutable ubyte[6] cubeLevels = [0, 95, 135, 175, 215, 255];

    if (index < 16)
        return base16Palette[index];
    if (index < 232)
    {
        const i = index - 16;
        return RgbColor(cubeLevels[i / 36], cubeLevels[(i / 6) % 6], cubeLevels[i % 6]);
    }
    const gray = cast(ubyte)(8 + 10 * (index - 232));
    return RgbColor(gray, gray, gray);
}

@("color.xterm256ToRgb.roundTrip")
pure nothrow @nogc
unittest
{
    // Every cube/gray entry maps back to itself through the nearest fold.
    foreach (i; 16 .. 256)
        assert(ansi256FromRgb(xterm256ToRgb(cast(ubyte) i)) == i);

    assert(xterm256ToRgb(0) == RgbColor(0, 0, 0));
    assert(xterm256ToRgb(196) == RgbColor(255, 0, 0));
    assert(xterm256ToRgb(244) == RgbColor(128, 128, 128));
}

@("color.ansi16FromRgb.basics")
pure nothrow @nogc
unittest
{
    assert(ansi16FromRgb(RgbColor(0, 0, 0)) == 0);
    assert(ansi16FromRgb(RgbColor(255, 0, 0)) == 9);
    assert(ansi16FromRgb(RgbColor(200, 10, 10)) == 1);
    assert(ansi16FromRgb(RgbColor(255, 255, 255)) == 15);
    assert(ansi16FromRgb(RgbColor(120, 120, 120)) == 8);
}

// ─────────────────────────────────────────────────────────────────────────────
// SGR color-parameter emission
// ─────────────────────────────────────────────────────────────────────────────

/// The SGR color channel a $(LREF Color) applies to. The numbers differ per
/// channel: foreground `38`/`39`, background `48`/`49`, underline `58`/`59`.
enum ColorChannel : ubyte
{
    foreground, /// text foreground (38/39; classic 30–37, 90–97)
    background, /// text background (48/49; classic 40–47, 100–107)
    underline,  /// underline color (58/59; 256/truecolor only — no classic form)
}

/**
Emits the SGR parameter(s) selecting `color` on `channel` (without the `ESC[`/
`m` wrapper): `38;2;r;g;b` / `38;5;n` / classic codes by `depth`, `39`/`49`/`59`
for unset or terminal-default, palette entries kept palette-native (indices
0–15 as classic codes at any depth for fg/bg; 16–255 as `…;5;n`, downsampled
through the xterm palette only when the terminal can't address them).

The underline channel has no classic-16 form: below `ansi256` an underline
color resets to the terminal default (`59`).
*/
void writeSgrColor(Writer)(ref Writer w, in Color color, ColorDepth depth, ColorChannel channel)
{
    import std.range.primitives : put;
    import sparkles.base.text.writers : writeInteger;

    final switch (color.kind)
    {
        case Color.Kind.unset:
        case Color.Kind.default_:
            writeChannelReset(w, channel);
            return;

        case Color.Kind.palette:
            if (channel != ColorChannel.underline && color.index < 16)
                writeClassicCode(w, color.index, channel);
            else if (depth >= ColorDepth.ansi256)
            {
                writeChannelPrefix256(w, channel);
                writeInteger(w, color.index);
            }
            else if (channel == ColorChannel.underline)
                writeChannelReset(w, channel); // no low-depth underline color
            else
                writeClassicCode(w, ansi16FromRgb(xterm256ToRgb(color.index)), channel);
            return;

        case Color.Kind.rgb:
            final switch (depth)
            {
                case ColorDepth.none:
                case ColorDepth.ansi16:
                    if (channel == ColorChannel.underline)
                        writeChannelReset(w, channel);
                    else
                        writeClassicCode(w, ansi16FromRgb(color.rgb), channel);
                    return;
                case ColorDepth.ansi256:
                    writeChannelPrefix256(w, channel);
                    writeInteger(w, ansi256FromRgb(color.rgb));
                    return;
                case ColorDepth.trueColor:
                    writeChannelPrefix24(w, channel);
                    writeInteger(w, color.rgb.r);
                    put(w, ';');
                    writeInteger(w, color.rgb.g);
                    put(w, ';');
                    writeInteger(w, color.rgb.b);
                    return;
            }
    }
}

/// Reset-to-default parameter for `channel` (`39`/`49`/`59`).
private void writeChannelReset(Writer)(ref Writer w, ColorChannel channel)
{
    import std.range.primitives : put;

    final switch (channel)
    {
        case ColorChannel.foreground: put(w, "39"); return;
        case ColorChannel.background: put(w, "49"); return;
        case ColorChannel.underline:  put(w, "59"); return;
    }
}

/// 256-palette set prefix for `channel` (`38;5;`/`48;5;`/`58;5;`).
private void writeChannelPrefix256(Writer)(ref Writer w, ColorChannel channel)
{
    import std.range.primitives : put;

    final switch (channel)
    {
        case ColorChannel.foreground: put(w, "38;5;"); return;
        case ColorChannel.background: put(w, "48;5;"); return;
        case ColorChannel.underline:  put(w, "58;5;"); return;
    }
}

/// 24-bit set prefix for `channel` (`38;2;`/`48;2;`/`58;2;`).
private void writeChannelPrefix24(Writer)(ref Writer w, ColorChannel channel)
{
    import std.range.primitives : put;

    final switch (channel)
    {
        case ColorChannel.foreground: put(w, "38;2;"); return;
        case ColorChannel.background: put(w, "48;2;"); return;
        case ColorChannel.underline:  put(w, "58;2;"); return;
    }
}

/// Classic-16 SGR code for a fg/bg palette index (`30+i`/`90+i-8`/`40+i`/
/// `100+i-8`). The underline channel never reaches here (no classic form).
private void writeClassicCode(Writer)(ref Writer w, ubyte index, ColorChannel channel)
in (index < 16, "classic codes only exist for indices 0–15")
in (channel != ColorChannel.underline, "underline has no classic-16 form")
{
    import sparkles.base.text.writers : writeInteger;

    const bg = channel == ColorChannel.background;
    const base = index < 8
        ? (bg ? 40 : 30) + index
        : (bg ? 100 : 90) + index - 8;
    writeInteger(w, cast(uint) base);
}

///
@("term_color.writeSgrColor")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : checkWriter;

    checkWriter!((ref w) => writeSgrColor(w, Color.init, ColorDepth.trueColor, ColorChannel.foreground))("39");
    checkWriter!((ref w) => writeSgrColor(w, Color.defaultColor, ColorDepth.trueColor, ColorChannel.background))("49");
    checkWriter!((ref w) => writeSgrColor(w, Color.fromPalette(3), ColorDepth.trueColor, ColorChannel.foreground))("33");
    checkWriter!((ref w) => writeSgrColor(w, Color.fromPalette(11), ColorDepth.ansi16, ColorChannel.background))("103");
    checkWriter!((ref w) => writeSgrColor(w, Color.fromPalette(114), ColorDepth.ansi256, ColorChannel.foreground))("38;5;114");
    // palette above 15 at ansi16: downsampled through the xterm palette
    checkWriter!((ref w) => writeSgrColor(w, Color.fromPalette(196), ColorDepth.ansi16, ColorChannel.foreground))("91");
    checkWriter!((ref w) => writeSgrColor(w, Color.fromRgb(1, 2, 3), ColorDepth.trueColor, ColorChannel.foreground))("38;2;1;2;3");
    checkWriter!((ref w) => writeSgrColor(w, Color.fromRgb(255, 0, 0), ColorDepth.ansi256, ColorChannel.background))("48;5;196");
    checkWriter!((ref w) => writeSgrColor(w, Color.fromRgb(255, 0, 0), ColorDepth.ansi16, ColorChannel.foreground))("91");

    // underline channel: 256/truecolor only; drops (59) below ansi256.
    checkWriter!((ref w) => writeSgrColor(w, Color.init, ColorDepth.trueColor, ColorChannel.underline))("59");
    checkWriter!((ref w) => writeSgrColor(w, Color.fromRgb(1, 2, 3), ColorDepth.trueColor, ColorChannel.underline))("58;2;1;2;3");
    checkWriter!((ref w) => writeSgrColor(w, Color.fromPalette(114), ColorDepth.ansi256, ColorChannel.underline))("58;5;114");
    checkWriter!((ref w) => writeSgrColor(w, Color.fromPalette(3), ColorDepth.ansi256, ColorChannel.underline))("58;5;3");
    checkWriter!((ref w) => writeSgrColor(w, Color.fromRgb(255, 0, 0), ColorDepth.ansi16, ColorChannel.underline))("59");
}

private uint colorDistanceSq(in RgbColor a, in RgbColor b) pure nothrow @nogc
{
    const dr = cast(int) a.r - cast(int) b.r;
    const dg = cast(int) a.g - cast(int) b.g;
    const db = cast(int) a.b - cast(int) b.b;
    return cast(uint)(dr * dr + dg * dg + db * db);
}

// isHexDigit / hexNibble come from sparkles.base.text.readers.
private ubyte hexByte(char hi, char lo) pure nothrow @nogc
    => cast(ubyte)(hexNibble(hi) * 16 + hexNibble(lo));
