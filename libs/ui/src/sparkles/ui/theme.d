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

import sparkles.base.term_color : Color, mix, RgbColor;
import sparkles.ui.style : ColorScheme, defaultTwoslashPalette, Palette, Slot,
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
        const bg = defaultBg.toRgbOr(RgbColor(0, 0, 0));
        const scheme = schemeForBackground(bg);
        auto p = defaultTwoslashPalette(scheme);
        if (defaultBg.kind != Color.Kind.rgb)
            return p; // nothing personal to derive from — the scheme default

        // A theme that pins its page colors gets a palette DERIVED from
        // them, in the same design language the markdown view mixes
        // (`MdViewTheme.derive` — one set of formulas, two consumers), so
        // chrome bands, tab strips, panels, and rules all track the theme
        // instead of collapsing onto one shared grey per scheme. An
        // explicit palette still wins above.
        const fg = defaultFg.toRgbOr(scheme == ColorScheme.dark
            ? RgbColor(0xcc, 0xcc, 0xcc) : RgbColor(0x30, 0x30, 0x30));
        void set(Slot s, Color slotFg, Color slotBg) @safe pure nothrow @nogc
        {
            if (slotFg.kind == Color.Kind.rgb)
                p.fg[s] = slotFg;
            if (slotBg.kind == Color.Kind.rgb)
                p.bg[s] = slotBg;
        }

        Color rgb(RgbColor c) => Color.fromRgb(c);
        set(Slot.surface, Color.init, rgb(mix(bg, fg, 0.08)));      // panel
        set(Slot.chip, Color.init, rgb(mix(bg, fg, 0.12)));         // inline code
        set(Slot.chrome, rgb(mix(fg, bg, 0.25)), rgb(mix(bg, fg, 0.16)));
        set(Slot.chromeFocused, rgb(fg), rgb(mix(bg, fg, 0.24)));   // > chrome
        set(Slot.gutter, rgb(mix(fg, bg, 0.5)), Color.init);
        set(Slot.border, rgb(mix(bg, fg, 0.4)), Color.init);        // rules
        set(Slot.muted, rgb(mix(fg, bg, 0.35)), Color.init);
        // Emphasized chrome (the active tab, key hints): the theme's own
        // accent where its rules pin one — its bg an accent TINT, so an
        // accented selection is unmistakably not the panel surface.
        const accent = ruleFgFor("function", ruleFgFor("markup.link"));
        if (accent.kind == Color.Kind.rgb)
            set(Slot.chromeAccent, accent, rgb(mix(bg, accent.rgb, 0.20)));
        else
            set(Slot.chromeAccent, Color.init, rgb(mix(bg, fg, 0.30)));
        return p;
    }

    /// The fg of the first rule whose selector is exactly `label` (the
    /// palette derivation's accent probe — no LabelSet resolution here),
    /// else `fallback`.
    private Color ruleFgFor(string label, Color fallback = Color.init)
        const pure nothrow @nogc
    {
        foreach (ref const r; rules)
            if (r.selector == label && r.style.fg.kind == Color.Kind.rgb)
                return r.style.fg;
        return fallback;
    }
}

/// A `Color` that may be unset, as a concrete `RgbColor` — `fallback` when the
/// color carries no RGB value (unset, or a terminal-default/indexed color the
/// theme did not pin). Used to pick a light/dark scheme from a page background.
private RgbColor toRgbOr(in Color c, RgbColor fallback) pure nothrow @nogc
    => c.kind == Color.Kind.rgb ? c.rgb : fallback;

@("ui.theme.effectivePalette.derivesFromBackground")
@safe unittest
{
    // A theme that PINS its page background derives a PERSONALIZED palette
    // (the md design language's mixes over its own bg/fg) — chrome bands,
    // panels and rules track the theme instead of collapsing onto one
    // shared grey per scheme.
    const bgA = RgbColor(0x1e, 0x1e, 0x2e);
    const fgFall = RgbColor(0xcc, 0xcc, 0xcc); // dark scheme's fg fallback
    const dark = Theme(name: "d", defaultBg: Color.fromRgb(bgA));
    const p = dark.effectivePalette();
    assert(p.bg[Slot.chrome] == Color.fromRgb(mix(bgA, fgFall, 0.16)));
    assert(p.bg[Slot.chromeFocused] == Color.fromRgb(mix(bgA, fgFall, 0.24)));
    assert(p.bg[Slot.surface] == Color.fromRgb(mix(bgA, fgFall, 0.08)));

    // Two different dark backgrounds now disagree.
    const dark2 = Theme(name: "d2",
        defaultBg: Color.fromRgb(RgbColor(0x10, 0x14, 0x18)));
    assert(dark2.effectivePalette().bg[Slot.chrome] != p.bg[Slot.chrome]);

    // A pinned fg is honored over the scheme fallback.
    const fgB = RgbColor(0xee, 0xdd, 0xcc);
    const pinned = Theme(name: "p", defaultBg: Color.fromRgb(bgA),
        defaultFg: Color.fromRgb(fgB));
    assert(pinned.effectivePalette().bg[Slot.chrome]
        == Color.fromRgb(mix(bgA, fgB, 0.16)));

    // The accent probe: a `function` rule's fg becomes the chrome accent.
    const accent = RgbColor(0x89, 0xb4, 0xfa);
    const ruled = Theme(name: "r", defaultBg: Color.fromRgb(bgA),
        rules: [ThemeRule("function", StyleSpec(fg: Color.fromRgb(accent)))]);
    assert(ruled.effectivePalette().fg[Slot.chromeAccent]
        == Color.fromRgb(accent));
    // …and its bg is the accent TINT — an accented selection (the active
    // tab) is never the panel surface.
    assert(ruled.effectivePalette().bg[Slot.chromeAccent]
        == Color.fromRgb(mix(bgA, accent, 0.20)));
    assert(ruled.effectivePalette().bg[Slot.chromeAccent]
        != ruled.effectivePalette().bg[Slot.surface]);

    // No pinned background: the scheme default, untouched.
    assert(Theme(name: "n").effectivePalette()
        == defaultTwoslashPalette(ColorScheme.dark));
    const light = Theme(name: "l",
        defaultBg: Color.fromRgb(RgbColor(0xff, 0xff, 0xff)));
    assert(light.effectivePalette().bg[Slot.chrome]
        == Color.fromRgb(mix(RgbColor(0xff, 0xff, 0xff),
            RgbColor(0x30, 0x30, 0x30), 0.16)));
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
