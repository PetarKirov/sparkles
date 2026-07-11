/**
Theme colors and terminal color-depth folding.

$(LREF Color) is a proper sum type for what highlighting themes actually
express: an RGB value, a terminal-palette index, "the terminal's default", or
"not specified". bat encodes the same four cases into `#RRGGBBAA` hex strings
(alpha 0 ⇒ palette index in the red channel, alpha 1 ⇒ terminal default) —
$(LREF parseHexColor) understands that convention at the boundary and turns
it into structure instead of propagating the trick.

The depth fold ($(LREF ansi256FromRgb), $(LREF ansi16FromRgb)) reifies bat's
rendering tiers: themes author in 24-bit RGB; terminals that only speak 256
or 16 colors get the nearest approximation. `Color.Kind.rgb` is also the
GPU-usable kind — a future non-terminal backend consumes it directly and a
`toRgb(Color, palette)` concretizer is the recorded seam for resolving the
palette/default kinds against a concrete palette table.

Detection is split per repo doctrine: the pure, testable classifier
$(REF classifyColorDepth, sparkles,base,term_color) (re-exported here) picks the
tier from `$COLORTERM`/`$TERM` values; $(LREF detectColorDepth) is the thin
environment-reading wrapper an application calls at its edge.
*/
module sparkles.syntax.color;

import sparkles.base.text.errors : ParseErrorCode, ParseExpected, parseErr, parseOk;
import sparkles.base.text.readers : hexNibble, isHexDigit;

// The color-depth tier lives in base so core-cli's TermCaps shares one
// classifier; re-exported so `sparkles.syntax.color.ColorDepth` still resolves.
public import sparkles.base.term_color : ColorDepth, classifyColorDepth;

@safe:

/// A 24-bit RGB color value.
struct RgbColor
{
    ubyte r, g, b;
}

/**
A theme color: one of four cases.

$(LIST
    * `unset` — the theme does not specify this channel (the default);
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
        unset,    /// not specified by the theme
        default_, /// the terminal's default color
        palette,  /// a terminal-palette index (`index`)
        rgb,      /// a 24-bit value (`rgb`)
    }

    Kind kind;    /// which case this color is
    ubyte index;  /// palette index (kind == palette)
    RgbColor rgb; /// 24-bit value (kind == rgb)

    /// The terminal-default color.
    enum Color defaultColor = Color(Kind.default_);

    /// Constructs an RGB color.
    static Color fromRgb(ubyte r, ubyte g, ubyte b) pure nothrow @nogc
        => Color(kind: Kind.rgb, rgb: RgbColor(r, g, b));

    /// ditto
    static Color fromRgb(RgbColor c) pure nothrow @nogc
        => Color(kind: Kind.rgb, rgb: c);

    /// Constructs a terminal-palette color.
    static Color fromPalette(ubyte index) pure nothrow @nogc
        => Color(kind: Kind.palette, index: index);

    /// `true` iff the theme specified this color at all.
    bool isSet() const scope pure nothrow @nogc
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
for the bright half); the ANSI renderer derives them.
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

/// Reads `$COLORTERM`/`$TERM` and classifies via
/// $(REF classifyColorDepth, sparkles,base,term_color). The thin env-reading
/// edge for standalone use; an app already holding a
/// $(REF TermCaps, sparkles,core_cli,term_caps) reads `.colorDepth` instead.
ColorDepth detectColorDepth()
{
    import std.process : environment;

    return classifyColorDepth(environment.get("COLORTERM", ""), environment.get("TERM", ""));
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
