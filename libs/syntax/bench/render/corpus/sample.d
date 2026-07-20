/**
The theme layer: label selectors → styles, resolved once per vocabulary.

A $(LREF Theme) is plain data — ordered $(LREF ThemeRule)s mapping dotted
selectors to $(LREF StyleSpec)s. $(LREF resolveTheme) folds it against a
`LabelSet` into a $(LREF ResolvedTheme): a flat `labelId → StyleSpec` table
indexed in O(1) on the render path. Resolution is longest-dot-prefix (the
same rule `LabelSet.resolve` applies to capture names), whole-spec-wins (no
attribute cascade), and last-rule-wins among equal selectors.

`ResolvedTheme` is public API for every backend — including future
non-markup consumers (a GPU text renderer indexes it with `StyledSpan.label`
directly). Theme files (TOML/JSON) are a future seam: only a parser
producing `ThemeRule[]` is missing.
*/
module sparkles.syntax.theme;

import sparkles.syntax.color : Color;
import sparkles.syntax.event : LabelId;
import sparkles.syntax.label : LabelSet;

@safe:

/// Font-style flags, backend-neutral (they select faces/decorations, not
/// escape codes).
enum FontStyle : ubyte
{
    none = 0,
    bold = 1 << 0,
    dim = 1 << 1,
    italic = 1 << 2,
    underline = 1 << 3,
    strikethrough = 1 << 4,
}

/// `true` iff `flags` contains every bit of `bit`.
bool hasFont(FontStyle flags, FontStyle bit) pure nothrow @nogc
    => (flags & bit) == bit && bit != FontStyle.none;

/// The style a theme assigns to one label: optional fore-/background colors
/// plus font flags. `Color.Kind.unset` means "not specified".
struct StyleSpec
{
    Color fg;       /// foreground; unset = unspecified
    Color bg;       /// background; unset = unspecified
    FontStyle font; /// font flags

    /// `true` iff the spec specifies nothing at all (renders unstyled).
    bool empty() const scope pure nothrow @nogc
        => !fg.isSet && !bg.isSet && font == FontStyle.none;
}

/// One theme rule: a dotted label selector and the style it assigns.
struct ThemeRule
{
    string selector; /// dotted label name, matched by longest-dot-prefix
    StyleSpec style; /// the whole spec assigned on match (no cascade)
}

/// A theme as plain data. See the module header for resolution semantics.
struct Theme
{
    string name;                             /// display name
    Color defaultFg = Color.defaultColor;    /// unlabeled-text foreground
    Color defaultBg = Color.defaultColor;    /// document background
    ThemeRule[] rules;                       /// ordered; later wins among equal selectors
}

/**
A theme resolved against a label vocabulary: `labelId → StyleSpec` in O(1).
The single style bundle every backend takes.
*/
struct ResolvedTheme
{
    LabelSet labels;                 /// the vocabulary this was resolved against
    immutable(StyleSpec)[] styles;   /// parallel to `labels`; `.init` if unmatched
    StyleSpec defaults;              /// style of unlabeled text (`LabelId.none`)

    /// The style for `id`; `defaults` for `LabelId.none`. Ids outside this
    /// vocabulary (a producer configured against a different `LabelSet`)
    /// render as defaults — renderers are total.
    StyleSpec opIndex(LabelId id) const scope pure nothrow @nogc
        => id && id.value < styles.length ? styles[id.value] : defaults;
}

/**
Resolves `theme` against `labels`: for every vocabulary name, the longest
rule selector that is a dot-prefix of the name wins (last rule wins among
equal selectors); unmatched names get `StyleSpec.init`.

Configure-time only (allocates the table once). A `defaultFg`/`defaultBg` of
`Color.defaultColor` is normalized to unset in `defaults` — for a renderer,
"the terminal default" and "unspecified" both mean "emit nothing".
*/
ResolvedTheme resolveTheme(in Theme theme, LabelSet labels) pure nothrow
{
    auto styles = new StyleSpec[](labels.length);
    foreach (i; 0 .. labels.length)
    {
        const labelName = labels.name(LabelId(cast(ushort) i));
        size_t bestLen = 0;
        bool found = false;
        StyleSpec best;
        foreach (rule; theme.rules)
        {
            if (rule.selector.length >= bestLen && isDotPrefix(rule.selector, labelName))
            {
                bestLen = rule.selector.length;
                best = rule.style;
                found = true;
            }
        }
        styles[i] = found ? best : StyleSpec.init;
    }

    const defaults = StyleSpec(
        fg: normalizeDefault(theme.defaultFg),
        bg: normalizeDefault(theme.defaultBg));
    return ResolvedTheme(labels, styles.idup, defaults);
}

///
@("theme.resolveTheme.longestPrefixLastWins")
unittest
{
    const theme = Theme(
        name: "test",
        rules: [
            ThemeRule("string", StyleSpec(fg: Color.fromPalette(2))),
            ThemeRule("string.special", StyleSpec(fg: Color.fromPalette(5))),
            ThemeRule("string", StyleSpec(fg: Color.fromPalette(3))), // last wins
        ]);
    const labels = LabelSet.standard();
    const resolved = resolveTheme(theme, labels);

    // longest prefix beats rule order
    assert(resolved[labels.find("string.special.key")].fg == Color.fromPalette(5));
    // last rule wins among equal selectors
    assert(resolved[labels.find("string")].fg == Color.fromPalette(3));
    assert(resolved[labels.find("string.escape")].fg == Color.fromPalette(3));
    // unmatched label → empty spec
    assert(resolved[labels.find("keyword")].empty);
    // no-label text → defaults (normalized to unset here)
    assert(resolved[LabelId.none].empty);
}

@("theme.resolveTheme.noPartialSegmentMatch")
unittest
{
    // "str" must not match "string" — prefixes are whole dotted segments.
    const theme = Theme(name: "test", rules: [
        ThemeRule("str", StyleSpec(fg: Color.fromPalette(1))),
    ]);
    const labels = LabelSet.standard();
    const resolved = resolveTheme(theme, labels);
    assert(resolved[labels.find("string")].empty);
}

@("theme.StyleSpec.empty")
pure nothrow @nogc
unittest
{
    assert(StyleSpec.init.empty);
    assert(!StyleSpec(fg: Color.fromPalette(1)).empty);
    assert(!StyleSpec(font: FontStyle.bold).empty);
    assert(!StyleSpec(fg: Color.defaultColor).empty); // default_ counts as set
}

@("theme.hasFont")
pure nothrow @nogc
unittest
{
    const flags = cast(FontStyle)(FontStyle.bold | FontStyle.italic);
    assert(hasFont(flags, FontStyle.bold));
    assert(hasFont(flags, FontStyle.italic));
    assert(!hasFont(flags, FontStyle.underline));
    assert(!hasFont(flags, FontStyle.none));
}

/// `prefix` matches `full` iff equal, or `full` continues with `.` right
/// after `prefix` (whole-segment prefix matching).
private bool isDotPrefix(scope const(char)[] prefix, scope const(char)[] full) pure nothrow @nogc
{
    import std.algorithm.searching : startsWith;

    return full.startsWith(prefix)
        && (full.length == prefix.length || full[prefix.length] == '.');
}

private Color normalizeDefault(Color c) pure nothrow @nogc
    => c.kind == Color.Kind.default_ ? Color.init : c;

// ---- color.d ----

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

// ---- render/ansi.d ----

/**
The ANSI rendering backend: folds a highlight-event stream into SGR-styled
terminal output.

Renders through $(REF byStyledSpan, sparkles,syntax,event) (maximal
innermost-wins runs), emitting the $(B minimal SGR transition) between
adjacent runs ($(LREF writeStyleTransition)) at the requested
$(REF ColorDepth, sparkles,syntax,color) tier — 24-bit, 256-color, or
classic-16, with palette colors kept palette-native so the user's terminal
scheme is respected (the bat discipline).

$(B Per-line validity:) any active style is reset before every `'\n'` and
lazily re-established after it, so each output line carries its own styling
and survives being sliced, paged, or reflowed line-wise. The invariant is
verified in tests by re-scanning the output with
`sparkles.base.text.ansi.SgrState`.

Totality: the renderer never fails on any event stream; `ColorDepth.none`
degrades to verbatim source passthrough.
*/
module sparkles.syntax.render.ansi;

import std.range.primitives : put;

import sparkles.base.text.writers : writeInteger;
import sparkles.base.text.ansi : writeSgrReset;
import sparkles.base.term_style : Style;

import sparkles.syntax.color : Color, ColorDepth, RgbColor, ansi16FromRgb,
    ansi256FromRgb, xterm256ToRgb;
import sparkles.syntax.event : byStyledSpan, isHighlightEventRange;
import sparkles.syntax.theme : FontStyle, ResolvedTheme, StyleSpec, hasFont;

/// Options for $(LREF renderAnsi).
struct AnsiOptions
{
    /// Color tier to emit. `none` = verbatim passthrough.
    ColorDepth depth = ColorDepth.ansi256;

    /// Emit per-run theme backgrounds. Off by default: respect the
    /// terminal's own background.
    bool emitBackground = false;

    /// Emit italics. Off by default (bat's defensive gate — some terminals
    /// render italics poorly); italic font flags are dropped when off.
    bool italics = false;
}

/**
Folds `events` over `source`, writing SGR-styled text to `w`.

`w` is any `char` output range. Attributes infer: with a `@nogc` writer and
event range the whole render path is `@safe pure nothrow @nogc`.
*/
ref Writer renderAnsi(Writer, Events)(
    scope const(char)[] source,
    Events events,
    in ResolvedTheme theme,
    return ref Writer w,
    in AnsiOptions options = AnsiOptions(),
)
if (isHighlightEventRange!Events)
{
    import std.algorithm.comparison : min;
    import std.algorithm.searching : countUntil;
    import std.utf : byCodeUnit;

    if (options.depth == ColorDepth.none)
    {
        put(w, source);
        return w;
    }

    StyleSpec current;

    void transitionTo(in StyleSpec target)
    {
        if (current != target)
        {
            writeStyleTransition(w, current, target, options.depth);
            current = target;
        }
    }

    foreach (span; byStyledSpan(events))
    {
        auto spec = theme[span.label];
        if (!options.italics)
            spec.font = cast(FontStyle)(spec.font & ~FontStyle.italic);
        if (!options.emitBackground)
            spec.bg = Color.init;

        // Defensive clamp: a misbehaving producer must not crash a renderer.
        const lo = min(span.start, source.length);
        const hi = min(span.end, source.length);
        const(char)[] text = lo < hi ? source[lo .. hi] : null;

        while (text.length)
        {
            const nlPos = text.byCodeUnit.countUntil('\n');
            if (nlPos < 0)
            {
                transitionTo(spec);
                put(w, text);
                break;
            }

            const nl = cast(size_t) nlPos;
            if (nl > 0)
            {
                transitionTo(spec);
                put(w, text[0 .. nl]);
            }
            // reset before the newline; re-open lazily at the next text
            transitionTo(StyleSpec.init);
            put(w, '\n');
            text = text[nl + 1 .. $];
        }
    }

    transitionTo(StyleSpec.init);
    return w;
}

/**
Emits the minimal SGR sequence transitioning the terminal from style `from`
to style `to` at `depth`; nothing when they are equal, a single `ESC[0m`
when `to` is empty.

Font bits are diffed per flag (off-codes `22`/`23`/`24`/`29` for cleared
bits, on-codes for set bits — `22` clears both bold and dim, so a surviving
one is re-issued); colors are emitted only when changed, an unset/default
target as `39`/`49`.
*/
void writeStyleTransition(Writer)(ref Writer w, in StyleSpec from, in StyleSpec to, ColorDepth depth)
{
    if (from == to)
        return;
    if (to.empty)
    {
        if (!from.empty)
            writeSgrReset(w);
        return;
    }

    put(w, "\x1b[");
    bool first = true;

    // Emit one `;`-separated SGR parameter. Codes are sourced from
    // `base.term_style.Style` ([on, off] pairs) so the numbers have one home.
    void pieceCode(uint code)
    {
        if (!first)
            put(w, ';');
        first = false;
        writeInteger(w, code);
    }

    // bold/dim share the off-code 22 (Style.bold[1] == Style.dim[1]): if either
    // is cleared, clear both and re-issue the survivor.
    const fromBD = from.font & (FontStyle.bold | FontStyle.dim);
    const toBD = to.font & (FontStyle.bold | FontStyle.dim);
    if (fromBD != toBD)
    {
        if (fromBD & ~toBD)
        {
            pieceCode(Style.bold[1]);
            if (toBD & FontStyle.bold)
                pieceCode(Style.bold[0]);
            if (toBD & FontStyle.dim)
                pieceCode(Style.dim[0]);
        }
        else
        {
            if ((toBD & FontStyle.bold) && !(fromBD & FontStyle.bold))
                pieceCode(Style.bold[0]);
            if ((toBD & FontStyle.dim) && !(fromBD & FontStyle.dim))
                pieceCode(Style.dim[0]);
        }
    }

    static struct FlagCodes
    {
        FontStyle flag;
        uint on, off;
    }

    static immutable FlagCodes[3] flagCodes = [
        FlagCodes(FontStyle.italic, Style.italic[0], Style.italic[1]),
        FlagCodes(FontStyle.underline, Style.underline[0], Style.underline[1]),
        FlagCodes(FontStyle.strikethrough, Style.strikethrough[0], Style.strikethrough[1]),
    ];

    foreach (fc; flagCodes)
    {
        const had = hasFont(from.font, fc.flag);
        const has = hasFont(to.font, fc.flag);
        if (had != has)
            pieceCode(has ? fc.on : fc.off);
    }

    if (from.fg != to.fg)
    {
        if (!first)
            put(w, ';');
        first = false;
        writeSgrColor(w, to.fg, depth, background: false);
    }
    if (from.bg != to.bg)
    {
        if (!first)
            put(w, ';');
        first = false;
        writeSgrColor(w, to.bg, depth, background: true);
    }

    put(w, 'm');
}

/**
Emits the SGR parameter(s) selecting `color` (without the `ESC[`/`m`
wrapper): `38;2;r;g;b` / `38;5;n` / classic codes by `depth`, `39`/`49` for
unset or terminal-default, palette entries kept palette-native (indices
0–15 as classic codes at any depth; 16–255 as `38;5;n`, downsampled through
the xterm palette only when the terminal can't address them).
*/
void writeSgrColor(Writer)(ref Writer w, in Color color, ColorDepth depth, bool background)
{
    final switch (color.kind)
    {
        case Color.Kind.unset:
        case Color.Kind.default_:
            put(w, background ? "49" : "39");
            return;

        case Color.Kind.palette:
            if (color.index < 16)
                writeClassicCode(w, color.index, background);
            else if (depth >= ColorDepth.ansi256)
            {
                put(w, background ? "48;5;" : "38;5;");
                writeInteger(w, color.index);
            }
            else
                writeClassicCode(w, ansi16FromRgb(xterm256ToRgb(color.index)), background);
            return;

        case Color.Kind.rgb:
            final switch (depth)
            {
                case ColorDepth.none:
                case ColorDepth.ansi16:
                    writeClassicCode(w, ansi16FromRgb(color.rgb), background);
                    return;
                case ColorDepth.ansi256:
                    put(w, background ? "48;5;" : "38;5;");
                    writeInteger(w, ansi256FromRgb(color.rgb));
                    return;
                case ColorDepth.trueColor:
                    put(w, background ? "48;2;" : "38;2;");
                    writeInteger(w, color.rgb.r);
                    put(w, ';');
                    writeInteger(w, color.rgb.g);
                    put(w, ';');
                    writeInteger(w, color.rgb.b);
                    return;
            }
    }
}

private void writeClassicCode(Writer)(ref Writer w, ubyte index, bool background)
in (index < 16)
{
    const base = index < 8
        ? (background ? 40 : 30) + index
        : (background ? 100 : 90) + index - 8;
    writeInteger(w, cast(uint) base);
}

version (unittest)
{
    import sparkles.base.smallbuffer : SmallBuffer, checkWriter;
    import sparkles.syntax.event : HighlightEvent, LabelId;
    import sparkles.syntax.label : LabelSet;
    import sparkles.syntax.theme : Theme, ThemeRule, resolveTheme;

    // A tiny fixed vocabulary/theme pair shared by the renderer tests.
    private ResolvedTheme testTheme() @safe pure nothrow
    {
        const theme = Theme(
            name: "test",
            rules: [
                ThemeRule("keyword", StyleSpec(
                    fg: Color.fromRgb(0xcb, 0xa6, 0xf7), font: FontStyle.bold)),
                ThemeRule("string", StyleSpec(fg: Color.fromRgb(0xa6, 0xe3, 0xa1))),
                ThemeRule("comment", StyleSpec(
                    fg: Color.fromPalette(8), font: FontStyle.italic)),
            ]);
        return resolveTheme(theme, LabelSet.standard());
    }

    private LabelId lbl(string name) @safe pure nothrow
    {
        const id = LabelSet.standard().find(name);
        assert(id, name);
        return id;
    }
}

///
@("render.ansi.basicRuns")
@safe pure nothrow
unittest
{
    const resolved = testTheme();
    alias E = HighlightEvent;
    const source = "if (x) // hi";
    const events = [
        E.pushLabel(lbl("keyword")),
        E.sourceSpan(0, 2),
        E.popLabel(),
        E.sourceSpan(2, 7),
        E.pushLabel(lbl("comment")),
        E.sourceSpan(7, 12),
        E.popLabel(),
    ];

    // trueColor: bold+fg for the keyword; palette 8 stays palette-native
    // (classic bright-black 90) at every depth; comment italic gated off.
    checkWriter!((ref w) => renderAnsi(source, events[], resolved, w,
        AnsiOptions(depth: ColorDepth.trueColor)))(
        "\x1b[1;38;2;203;166;247mif\x1b[0m (x) \x1b[90m// hi\x1b[0m");

    // ansi256: RGB folds to the nearest palette entry
    checkWriter!((ref w) => renderAnsi(source, events[], resolved, w,
        AnsiOptions(depth: ColorDepth.ansi256)))(
        "\x1b[1;38;5;183mif\x1b[0m (x) \x1b[90m// hi\x1b[0m");

    // ansi16: RGB folds to the classic palette (0xcba6f7 → white, 37)
    checkWriter!((ref w) => renderAnsi(source, events[], resolved, w,
        AnsiOptions(depth: ColorDepth.ansi16)))(
        "\x1b[1;37mif\x1b[0m (x) \x1b[90m// hi\x1b[0m");

    // none: verbatim passthrough
    checkWriter!((ref w) => renderAnsi(source, events[], resolved, w,
        AnsiOptions(depth: ColorDepth.none)))(source);
}

@("render.ansi.italicsGateAndBackground")
@safe pure nothrow
unittest
{
    const resolved = testTheme();
    alias E = HighlightEvent;
    const source = "x";
    const events = [
        E.pushLabel(lbl("comment")),
        E.sourceSpan(0, 1),
        E.popLabel(),
    ];

    // italics off (default): only the color survives
    checkWriter!((ref w) => renderAnsi(source, events[], resolved, w,
        AnsiOptions(depth: ColorDepth.ansi256)))(
        "\x1b[90mx\x1b[0m");

    // italics on: italic flag emitted
    checkWriter!((ref w) => renderAnsi(source, events[], resolved, w,
        AnsiOptions(depth: ColorDepth.ansi256, italics: true)))(
        "\x1b[3;90mx\x1b[0m");
}

@("render.ansi.adjacentRunsDiffMinimally")
@safe pure nothrow
unittest
{
    const resolved = testTheme();
    alias E = HighlightEvent;
    const source = "abcd";
    // keyword then string: same-bold? no — keyword is bold, string is not:
    // transition must clear bold (22) and change color in ONE sequence.
    const events = [
        E.pushLabel(lbl("keyword")),
        E.sourceSpan(0, 2),
        E.popLabel(),
        E.pushLabel(lbl("string")),
        E.sourceSpan(2, 4),
        E.popLabel(),
    ];

    checkWriter!((ref w) => renderAnsi(source, events[], resolved, w,
        AnsiOptions(depth: ColorDepth.trueColor)))(
        "\x1b[1;38;2;203;166;247mab\x1b[22;38;2;166;227;161mcd\x1b[0m");
}

@("render.ansi.perLineReset")
@safe pure nothrow
unittest
{
    import sparkles.base.text.ansi : SgrState, byAnsiToken;

    const resolved = testTheme();
    alias E = HighlightEvent;
    const source = "aa\nbb\ncc";
    const events = [
        E.pushLabel(lbl("string")),
        E.sourceSpan(0, 8), // one span across three lines
        E.popLabel(),
    ];

    SmallBuffer!(char, 256) buf;
    renderAnsi(source, events[], resolved, buf,
        AnsiOptions(depth: ColorDepth.trueColor));

    // style re-established after each newline
    checkWriter!((ref w) => renderAnsi(source, events[], resolved, w,
        AnsiOptions(depth: ColorDepth.trueColor)))(
        "\x1b[38;2;166;227;161maa\x1b[0m\n\x1b[38;2;166;227;161mbb\x1b[0m\n" ~
        "\x1b[38;2;166;227;161mcc\x1b[0m");

    // the machine-checked invariant: SGR state inactive at every newline
    SgrState state;
    foreach (token; byAnsiToken(buf[]))
    {
        if (token.isEscape)
            state.apply(token.slice);
        else
        {
            foreach (char ch; token.slice)
                if (ch == '\n')
                    assert(!state.active, "styled newline leaked");
        }
    }
    assert(!state.active, "unterminated style at end of output");
}

@("render.ansi.nogcProof")
@safe pure nothrow @nogc
unittest
{
    // The whole render path is @nogc given @nogc inputs.
    static immutable HighlightEvent[3] events = [
        HighlightEvent.pushLabel(LabelId(0)),
        HighlightEvent.sourceSpan(0, 4),
        HighlightEvent.popLabel(),
    ];
    const ResolvedTheme theme; // empty: everything renders unstyled
    SmallBuffer!(char, 64) buf;
    renderAnsi("text", events[], theme, buf);
    assert(buf[] == "text");
}

@("render.ansi.writeSgrColor")
@safe pure nothrow @nogc
unittest
{
    checkWriter!((ref w) => writeSgrColor(w, Color.init, ColorDepth.trueColor, false))("39");
    checkWriter!((ref w) => writeSgrColor(w, Color.defaultColor, ColorDepth.trueColor, true))("49");
    checkWriter!((ref w) => writeSgrColor(w, Color.fromPalette(3), ColorDepth.trueColor, false))("33");
    checkWriter!((ref w) => writeSgrColor(w, Color.fromPalette(11), ColorDepth.ansi16, true))("103");
    checkWriter!((ref w) => writeSgrColor(w, Color.fromPalette(114), ColorDepth.ansi256, false))("38;5;114");
    // palette above 15 at ansi16: downsampled through the xterm palette
    checkWriter!((ref w) => writeSgrColor(w, Color.fromPalette(196), ColorDepth.ansi16, false))("91");
    checkWriter!((ref w) => writeSgrColor(w, Color.fromRgb(1, 2, 3), ColorDepth.trueColor, false))("38;2;1;2;3");
    checkWriter!((ref w) => writeSgrColor(w, Color.fromRgb(255, 0, 0), ColorDepth.ansi256, true))("48;5;196");
    checkWriter!((ref w) => writeSgrColor(w, Color.fromRgb(255, 0, 0), ColorDepth.ansi16, false))("91");
}

@("render.ansi.writeStyleTransition")
@safe pure nothrow @nogc
unittest
{
    const bold = StyleSpec(font: FontStyle.bold);
    const boldDim = StyleSpec(font: cast(FontStyle)(FontStyle.bold | FontStyle.dim));
    const dim = StyleSpec(font: FontStyle.dim);
    const plainRed = StyleSpec(fg: Color.fromPalette(1));

    // no-op
    checkWriter!((ref w) => writeStyleTransition(w, bold, bold, ColorDepth.ansi256))("");
    // to empty → single reset
    checkWriter!((ref w) => writeStyleTransition(w, bold, StyleSpec.init, ColorDepth.ansi256))("\x1b[0m");
    // from empty
    checkWriter!((ref w) => writeStyleTransition(w, StyleSpec.init, bold, ColorDepth.ansi256))("\x1b[1m");
    // bold→dim: 22 clears both, dim re-issued
    checkWriter!((ref w) => writeStyleTransition(w, bold, dim, ColorDepth.ansi256))("\x1b[22;2m");
    // bold→bold+dim: pure addition, no 22
    checkWriter!((ref w) => writeStyleTransition(w, bold, boldDim, ColorDepth.ansi256))("\x1b[2m");
    // bold+dim→bold: 22 then re-issue bold
    checkWriter!((ref w) => writeStyleTransition(w, boldDim, bold, ColorDepth.ansi256))("\x1b[22;1m");
    // color-only change
    checkWriter!((ref w) => writeStyleTransition(w, StyleSpec.init, plainRed, ColorDepth.ansi256))("\x1b[31m");
    // dropping the color while keeping nothing else → reset
    checkWriter!((ref w) => writeStyleTransition(w, plainRed, StyleSpec.init, ColorDepth.ansi256))("\x1b[0m");
}
