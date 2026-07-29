/**
The theme level of $(MREF sparkles,ui): an application's whole design language as
$(B one runtime-swappable value).

A theme has four channels, and the point of unifying them is that they are all
the same kind of decision — whether a keyword is mauve, whether a popup border is
rounded, and whether a table draws with heavy or light box-drawing are choices a
user should be able to make together:

$(LIST
    $(ITEM $(B syntax) — ordered $(LREF ThemeRule)s mapping dotted label
        selectors to $(LREF StyleSpec)s.)
    $(ITEM $(B slots) — the semantic $(REF Palette, sparkles,ui,style): a
        $(REF Slot, sparkles,ui,style) resolves to a concrete appearance.)
    $(ITEM $(B metrics) — scalar chrome (radii, paddings, border widths, font
        scales), carried by the same `Palette`.)
    $(ITEM $(B glyphs) — $(LREF GlyphSet): box-drawing charsets, status marks
        and the like.)
)

$(B The syntax channel is opaque here.) This module carries the rules but cannot
resolve them: resolution needs a label vocabulary, which is a syntax-highlighting
concept, so `LabelSet`, `ResolvedTheme` and `resolveTheme` stay in
$(MREF sparkles,syntax,theme). Moving them here would invert the dependency —
`sparkles:syntax` consumes this toolkit, never the reverse. That also keeps this
module free of every syntax type: a rule is a `string` and a
$(REF TermStyle, sparkles,base,term_style), both of which `sparkles:base` owns.
*/
module sparkles.ui.theme;

import sparkles.base.term_color : Color, RgbColor;
import sparkles.ui.style : ColorScheme, defaultTwoslashPalette, Palette,
    schemeForBackground;

// The resolved-style vocabulary lives in `base` so `styled_template`, `syntax`
// and this toolkit share one type; re-exported so `sparkles.ui.theme.StyleSpec`
// (and `TextAttr`/`UnderlineStyle`) resolve for every backend.
public import sparkles.base.term_style : TermStyle, TextAttr, UnderlineStyle;

@safe:

/// The style a theme assigns to one label — $(REF TermStyle, sparkles,base,term_style):
/// optional fore-/background/underline colors, font flags, and underline shape.
/// `Color.Kind.unset` means "not specified".
alias StyleSpec = TermStyle;

/// One syntax rule: a dotted label selector and the style it assigns.
///
/// Matching is longest-dot-prefix, whole-spec-wins (no attribute cascade), and
/// last-rule-wins among equal selectors — but that resolution is performed by
/// $(REF resolveTheme, sparkles,syntax,theme), which owns the label vocabulary.
struct ThemeRule
{
    string selector; /// dotted label name, matched by longest-dot-prefix
    StyleSpec style; /// the whole spec assigned on match (no cascade)
}

/**
Glyph sets a theme selects — box-drawing charsets, table rules, status marks.

$(B Declared, not yet populated.) The concrete glyph vocabulary currently lives
with the terminal components in `sparkles:core-cli`, expressed in terms of their
own box and table types; it lands here when those components move. Declaring the
channel now fixes the shape of $(LREF Theme) so that move is additive rather than
another breaking change.
*/
struct GlyphSet
{
    /// Whether non-ASCII glyphs may be used at all. A target that cannot render
    /// them selects the ASCII charset regardless of what the theme asks for —
    /// but that decision belongs to the *target's* declared capabilities, not to
    /// this flag, which only records the theme's preference.
    bool unicode = true;
}

/**
A theme as plain data: all four channels in one value.

Every field defaults, so a theme that only sets syntax rules is valid and
$(LREF effectivePalette) derives the rest from the page background.
*/
struct Theme
{
    string name;                          /// display name
    Color defaultFg = Color.defaultColor; /// unlabeled-text foreground
    Color defaultBg = Color.defaultColor; /// document background
    ThemeRule[] rules;                    /// syntax channel; later wins among equal selectors

    /// Slot + metric channels. Left at `.init` a theme derives them from
    /// `defaultBg` — see $(LREF effectivePalette).
    Palette palette;
    bool hasPalette; /// ditto — `true` once `palette` was set explicitly

    GlyphSet glyphs; /// glyph channel

    /**
    The palette to resolve slots against: the explicitly configured one, or —
    when a theme carries only syntax rules — one derived from `defaultBg`, so
    light themes get light surfaces without every theme restating the whole slot
    table.
    */
    Palette effectivePalette() const pure nothrow @nogc
    {
        if (hasPalette)
            return palette;
        return defaultTwoslashPalette(schemeForBackground(defaultBg.toRgbOr(RgbColor(0, 0, 0))));
    }
}

/// A `Color` that may be unset, as a concrete `RgbColor` — `fallback` when the
/// color carries no RGB value (unset, or a terminal-default/indexed color the
/// theme did not pin). Used to pick a light/dark scheme from a page background.
private RgbColor toRgbOr(in Color c, RgbColor fallback) pure nothrow @nogc
    => c.kind == Color.Kind.rgb ? c.rgb : fallback;

@("ui.theme.effectivePalette.derivesFromBackground")
@safe pure nothrow @nogc
unittest
{
    // A theme carrying only syntax rules still resolves slots: a dark page
    // background selects the dark scheme.
    const dark = Theme(name: "d", defaultBg: Color.fromRgb(RgbColor(0x1e, 0x1e, 0x2e)));
    const light = Theme(name: "l", defaultBg: Color.fromRgb(RgbColor(0xff, 0xff, 0xff)));
    assert(dark.effectivePalette() == defaultTwoslashPalette(ColorScheme.dark));
    assert(light.effectivePalette() == defaultTwoslashPalette(ColorScheme.light));
}

@("ui.theme.effectivePalette.explicitWins")
@safe pure nothrow @nogc
unittest
{
    // An explicit palette is used verbatim, whatever the background suggests.
    auto t = Theme(name: "x", defaultBg: Color.fromRgb(RgbColor(0, 0, 0)));
    t.palette = defaultTwoslashPalette(ColorScheme.light);
    t.hasPalette = true;
    assert(t.effectivePalette() == defaultTwoslashPalette(ColorScheme.light));
}
