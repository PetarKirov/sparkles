/**
The style layer for $(MREF sparkles,ui) — the single source of truth the three
twoslash backends (CSS, raylib GUI, ANSI) had triplicated.

A widget names a semantic $(LREF Slot) (`error`, `warn`, `surface`, …), never a
concrete color. A $(LREF Palette) maps every slot to a foreground/background
$(REF Color, sparkles,base,term_color) plus per-channel alpha and a handful of
scalar chrome knobs (popup radius/padding, detach gap, chrome glyphs).
$(LREF defaultTwoslashPalette) authors the canonical twoslash hexes $(B once).

Three generators consume a palette:

$(LIST
    * $(LREF resolveSlot) → a concrete $(LREF Visual) (RGB + alpha) for the GUI
        and the display list, deferring "inherit" to the page fg/bg;
    * $(LREF writeTwoslashVars) → the CSS `:root { --twoslash-* }` block, kept in
        lockstep with `views/twoslash.css` by a unittest;
    * $(LREF writeSlotSgr) → the SGR parameters for the terminal renderer.
)
*/
module sparkles.ui.style;

import sparkles.base.term_color :
    Color, ColorChannel, ColorDepth, RgbColor, toRgb, writeSgrColor;

@safe:

/**
A semantic style role. Widgets and display-list ops carry a `Slot`, and a
$(LREF Palette) turns it into a concrete $(LREF Visual). Roles are intentionally
generic (an app palette can reuse them) even though the seed values come from
twoslash.
*/
enum Slot : ubyte
{
    inherit,         /// no styling of its own — use the page fg/bg
    code,            /// code text inside a popup (inherits page fg)
    docs,            /// documentation prose (muted)
    error,           /// error text + its translucent background
    warn,            /// warning text + background
    info,            /// informational / `@tag` text + background
    annotate,        /// `@annotate`-family tag text + background
    highlight,       /// highlighted-range tint (background only)
    highlightBorder, /// highlighted-range border
    surface,         /// popup / panel background (opaque)
    border,          /// popup / panel border line
    shadow,          /// popup drop shadow
    matched,         /// matched prefix in a completion list (inherits page fg)
    unmatched,       /// unmatched remainder in a completion list (muted)
    caret,           /// query caret / cursor marker
    muted,           /// generic de-emphasized text
    chip,            /// a JSDoc `@tag` name pill in a popup (muted text on a grey bg)
}

private enum slotCount = Slot.max + 1;

/// A fully-resolved appearance: concrete RGB fore/background with alpha, whether
/// a background should be painted at all, and packed text-style bits
/// ($(REF TextAttr, sparkles,base,term_style)). Produced by $(LREF resolveSlot);
/// consumed by every backend painter.
struct Visual
{
    RgbColor fg;          /// foreground RGB (already resolved against the page)
    ubyte fgAlpha = 0xFF; /// foreground opacity (0xFF = opaque)
    RgbColor bg;          /// background RGB (valid only when `hasBg`)
    ubyte bgAlpha = 0xFF; /// background opacity
    bool hasBg;           /// paint a background rectangle?
    ushort styleBits;     /// packed `TextAttr` flags (bold/italic/…)
}

/**
Maps every $(LREF Slot) to a fore/background color and alpha, plus scalar chrome
constants shared by the backends. `fg`/`bg` are $(REF Color, sparkles,base,term_color)s:
an $(I unset) `fg` means "inherit the page foreground", an $(I unset) `bg` means
"no background". Alpha is stored separately because `Color` carries none.
*/
struct Palette
{
    /// Per-slot foreground; `Color.init` (unset) ⇒ inherit page fg.
    Color[slotCount] fg;
    /// Per-slot foreground opacity (0xFF opaque).
    ubyte[slotCount] fgAlpha = 0xFF;
    /// Per-slot background; `Color.init` (unset) ⇒ no background.
    Color[slotCount] bg;
    /// Per-slot background opacity (only meaningful when `bg` is set).
    ubyte[slotCount] bgAlpha = 0xFF;

    // --- scalar chrome (shared across GUI/HTML/TUI) ---
    int popupRadius = 4; /// popup corner radius (px in GUI, ignored in cells)
    int popupPadX = 1;   /// popup horizontal padding, in cells
    int popupPadY = 1;   /// popup vertical padding, in cells
    int detachGap = 1;   /// blank rows between code and a detached meta block

    dchar caretGlyph = '^';   /// query caret marker (the `^` twoslash draws)
    dchar arrowGlyph = '─';   /// leader from a meta line up to its column
    dchar queryGlyph = '│';   /// vertical connector under a `^?` query
}

/// Light or dark color scheme — only the popup surface and docs text differ (the
/// brand colors are shared), matching `views/twoslash.css`'s dark `@media` block.
enum ColorScheme : ubyte
{
    light, /// the default `:root`
    dark,  /// the `@media (prefers-color-scheme: dark)` overrides
}

/// Picks the scheme a page background implies (dark bg ⇒ dark scheme), by
/// perceptual luminance. Backends resolve the popup surface against their theme.
ColorScheme schemeForBackground(in RgbColor bg) pure nothrow @nogc
{
    // Rec. 601 luma; < ~40% brightness reads as a dark surface.
    const luma = (bg.r * 299 + bg.g * 587 + bg.b * 114) / 1000;
    return luma < 110 ? ColorScheme.dark : ColorScheme.light;
}

/// The canonical twoslash palette — the $(B one) place the twoslash hexes are
/// authored. Mirrors `libs/twoslash/src/sparkles/twoslash/views/twoslash.css`
/// (`:root` + its dark `@media` overrides), which a unittest checks byte-for-value
/// via $(LREF writeTwoslashVars). `scheme` selects the surface/docs pair.
Palette defaultTwoslashPalette(ColorScheme scheme = ColorScheme.light) pure nothrow @nogc
{
    Palette p;
    with (Slot)
    {
        // error / warn / info / annotate: colored text over a 0x20 tint.
        p.fg[error] = Color.fromRgb(0xd4, 0x56, 0x56);
        p.bg[error] = Color.fromRgb(0xd4, 0x56, 0x56);
        p.bgAlpha[error] = 0x20;

        p.fg[warn] = Color.fromRgb(0xc3, 0x7d, 0x0d);
        p.bg[warn] = Color.fromRgb(0xc3, 0x7d, 0x0d);
        p.bgAlpha[warn] = 0x20;

        p.fg[info] = Color.fromRgb(0x37, 0x72, 0xcf);
        p.bg[info] = Color.fromRgb(0x37, 0x72, 0xcf);
        p.bgAlpha[info] = 0x20;

        p.fg[annotate] = Color.fromRgb(0x1b, 0xa6, 0x73);
        p.bg[annotate] = Color.fromRgb(0x1b, 0xa6, 0x73);
        p.bgAlpha[annotate] = 0x20;

        // highlighted range: a warm tint + border, no text color of its own.
        p.bg[highlight] = Color.fromRgb(0xc3, 0x7d, 0x0d);
        p.bgAlpha[highlight] = 0x20;
        p.fg[highlightBorder] = Color.fromRgb(0xc3, 0x7d, 0x0d);
        p.fgAlpha[highlightBorder] = 0x50;

        // popup surface / border / shadow. Surface + docs are the only
        // scheme-dependent slots (the dark `@media` block overrides just these two).
        const dark = scheme == ColorScheme.dark;
        p.bg[surface] = dark ? Color.fromRgb(0x23, 0x23, 0x23) : Color.fromRgb(0xf8, 0xf8, 0xf8);
        p.fg[docs] = dark ? Color.fromRgb(0xa0, 0xa0, 0xa0) : Color.fromRgb(0x88, 0x88, 0x88);
        p.fg[border] = Color.fromRgb(0x88, 0x88, 0x88);
        p.fgAlpha[border] = 0x88;
        p.fg[shadow] = Color.fromRgb(0x00, 0x00, 0x00);
        p.fgAlpha[shadow] = 0x14; // rgba(0,0,0,0.08)

        // JSDoc `@tag` name pill — muted text on a subtle grey fill (the CSS
        // `.twoslash-popup-docs-tag-name` background: rgba(127,127,127,0.18)).
        p.fg[chip] = Color.fromRgb(0x88, 0x88, 0x88);
        p.bg[chip] = Color.fromRgb(0x7f, 0x7f, 0x7f);
        p.bgAlpha[chip] = 0x2e; // 0.18 * 255

        // completion / caret (scheme-independent).
        p.fg[unmatched] = Color.fromRgb(0x88, 0x88, 0x88);
        p.fg[caret] = Color.fromRgb(0x88, 0x88, 0x88);
        p.fgAlpha[caret] = 0x88;
        p.fg[muted] = Color.fromRgb(0x88, 0x88, 0x88);

        // code / matched / inherit stay unset ⇒ page foreground.
    }
    return p;
}

/**
Resolves `slot` against `pal` and the page fore/background to a concrete
$(LREF Visual). Unset slot colors defer: an unset `fg` becomes `pageFg`, an
unset `bg` yields `hasBg == false`.
*/
Visual resolveSlot(in Palette pal, Slot slot, in RgbColor pageFg, in RgbColor pageBg)
    pure nothrow @nogc
{
    const i = cast(size_t) slot;
    Visual v;
    v.fg = toRgb(pal.fg[i], pageFg);
    v.fgAlpha = pal.fgAlpha[i];
    v.hasBg = pal.bg[i].isSet;
    v.bg = toRgb(pal.bg[i], pageBg);
    v.bgAlpha = pal.bgAlpha[i];
    return v;
}

/**
Writes the SGR parameter(s) selecting `slot`'s `channel` color at `depth`
(without the `ESC[`/`m` wrapper) — the terminal generator, layered on
$(REF writeSgrColor, sparkles,base,term_color). An unset color emits the
channel reset (`39`/`49`). Alpha is dropped (terminals have none).
*/
void writeSlotSgr(Writer)(ref Writer w, in Palette pal, Slot slot,
    ColorChannel channel, ColorDepth depth)
{
    const i = cast(size_t) slot;
    const c = channel == ColorChannel.background ? pal.bg[i] : pal.fg[i];
    writeSgrColor(w, c, depth, channel);
}

/// The palette-owned CSS custom properties, in `views/twoslash.css` source
/// order: the `--twoslash-*` name, its slot, and which channel it draws from.
private struct VarBinding
{
    string name;
    Slot slot;
    bool background;
}

private static immutable VarBinding[] twoslashVars = [
    VarBinding("--twoslash-border-color", Slot.border, false),
    VarBinding("--twoslash-highlighted-border", Slot.highlightBorder, false),
    VarBinding("--twoslash-highlighted-bg", Slot.highlight, true),
    VarBinding("--twoslash-popup-bg", Slot.surface, true),
    VarBinding("--twoslash-docs-color", Slot.docs, false),
    VarBinding("--twoslash-unmatched-color", Slot.unmatched, false),
    VarBinding("--twoslash-cursor-color", Slot.caret, false),
    VarBinding("--twoslash-error-color", Slot.error, false),
    VarBinding("--twoslash-error-bg", Slot.error, true),
    VarBinding("--twoslash-warn-color", Slot.warn, false),
    VarBinding("--twoslash-warn-bg", Slot.warn, true),
    VarBinding("--twoslash-tag-color", Slot.info, false),
    VarBinding("--twoslash-tag-bg", Slot.info, true),
    VarBinding("--twoslash-tag-annotate-color", Slot.annotate, false),
    VarBinding("--twoslash-tag-annotate-bg", Slot.annotate, true),
];

/// Writes one lowercase `#rrggbb` / `#rrggbbaa` hex color (alpha omitted when
/// fully opaque) into `w`.
private void writeHexColor(Writer)(ref Writer w, in RgbColor c, ubyte alpha)
{
    static immutable char[16] digits = "0123456789abcdef";
    void byte_(ubyte v)
    {
        char[2] pair = [digits[v >> 4], digits[v & 0x0F]];
        w.put(pair[]);
    }

    w.put('#');
    byte_(c.r);
    byte_(c.g);
    byte_(c.b);
    if (alpha != 0xFF)
        byte_(alpha);
}

/**
Emits the palette-owned `--twoslash-*` custom properties as
`  --name: #hex;\n` lines (the body of the CSS `:root` block). The colors are
authored here in D; `views/twoslash.css` keeps them in a hand-written `:root`
for the browser, and a unittest asserts the two agree so they can never drift.
Unset (inherited) colors resolve against `pageFg`/`pageBg` first.
*/
void writeTwoslashVars(Writer)(ref Writer w, in Palette pal,
    in RgbColor pageFg = RgbColor(0, 0, 0), in RgbColor pageBg = RgbColor(255, 255, 255))
{
    foreach (v; twoslashVars)
    {
        const vis = resolveSlot(pal, v.slot, pageFg, pageBg);
        w.put("  ");
        w.put(v.name);
        w.put(": ");
        if (v.background)
            writeHexColor(w, vis.bg, vis.bgAlpha);
        else
            writeHexColor(w, vis.fg, vis.fgAlpha);
        w.put(";\n");
    }
}

// ---------------------------------------------------------------------------

@("ui.style.resolveSlot.inheritAndTint")
@safe pure nothrow @nogc
unittest
{
    const pal = defaultTwoslashPalette();
    const pageFg = RgbColor(0x22, 0x22, 0x22);
    const pageBg = RgbColor(0xff, 0xff, 0xff);

    // error: opaque red fg over a 0x20 red tint.
    const e = resolveSlot(pal, Slot.error, pageFg, pageBg);
    assert(e.fg == RgbColor(0xd4, 0x56, 0x56));
    assert(e.fgAlpha == 0xFF);
    assert(e.hasBg && e.bg == RgbColor(0xd4, 0x56, 0x56) && e.bgAlpha == 0x20);

    // code inherits the page foreground and paints no background.
    const c = resolveSlot(pal, Slot.code, pageFg, pageBg);
    assert(c.fg == pageFg && !c.hasBg);

    // surface: opaque light background.
    const s = resolveSlot(pal, Slot.surface, pageFg, pageBg);
    assert(s.hasBg && s.bg == RgbColor(0xf8, 0xf8, 0xf8) && s.bgAlpha == 0xFF);
}

@("ui.style.scheme.darkSurfaceAndDocs")
@safe pure nothrow @nogc
unittest
{
    const dark = defaultTwoslashPalette(ColorScheme.dark);
    const fg = RgbColor(0xcd, 0xd6, 0xf4), bg = RgbColor(0x1e, 0x1e, 0x2e);

    // Dark scheme flips only the surface + docs (matches the CSS dark @media block).
    assert(resolveSlot(dark, Slot.surface, fg, bg).bg == RgbColor(0x23, 0x23, 0x23));
    assert(resolveSlot(dark, Slot.docs, fg, bg).fg == RgbColor(0xa0, 0xa0, 0xa0));
    // Brand colors are shared across schemes.
    assert(resolveSlot(dark, Slot.error, fg, bg).fg == RgbColor(0xd4, 0x56, 0x56));

    // A dark page background selects the dark scheme; a light one the light scheme.
    assert(schemeForBackground(bg) == ColorScheme.dark);
    assert(schemeForBackground(RgbColor(0xf5, 0xf5, 0xf5)) == ColorScheme.light);
}

@("ui.style.writeSlotSgr.viaBase")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    const pal = defaultTwoslashPalette();
    SmallBuffer!(char, 64) buf;
    writeSlotSgr(buf, pal, Slot.error, ColorChannel.foreground, ColorDepth.trueColor);
    assert(buf[] == "38;2;212;86;86"); // 0xd4 0x56 0x56

    SmallBuffer!(char, 64) buf2;
    writeSlotSgr(buf2, pal, Slot.code, ColorChannel.foreground, ColorDepth.trueColor);
    assert(buf2[] == "39"); // unset ⇒ default-foreground reset
}

@("ui.style.writeTwoslashVars.hexShapes")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import std.algorithm.searching : canFind;

    const pal = defaultTwoslashPalette();
    SmallBuffer!(char, 1024) buf;
    writeTwoslashVars(buf, pal);
    const s = buf[];

    assert(s.canFind("  --twoslash-error-color: #d45656;\n"));
    assert(s.canFind("  --twoslash-error-bg: #d4565620;\n"));   // alpha kept
    assert(s.canFind("  --twoslash-highlighted-border: #c37d0d50;\n"));
    assert(s.canFind("  --twoslash-popup-bg: #f8f8f8;\n"));     // opaque ⇒ no alpha
    assert(s.canFind("  --twoslash-border-color: #88888888;\n")); // CSS #8888 = rgba, alpha 0x88
}
