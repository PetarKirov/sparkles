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
import sparkles.base.term_style : TextAttr, UnderlineStyle;
import sparkles.ui.geometry : Insets;

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
    hoverUnderline,  /// hoverable-token underline (`.twoslash-hover`, always on)
    shadow,          /// popup drop shadow
    matched,         /// matched prefix in a completion list (inherits page fg)
    unmatched,       /// unmatched remainder in a completion list (muted)
    caret,           /// query caret / cursor marker
    muted,           /// generic de-emphasized text
    chip,            /// a JSDoc `@tag` name pill in a popup (muted text on a grey bg)

    // Application-chrome slots (the widened vocabulary the component catalog
    // requires — `THM2`): bands, gutters and scroll affordances.
    chrome,          /// header / status-bar band (its background + text)
    chromeAccent,    /// emphasized chrome text (title, active segment, key hints)
    gutter,          /// line-number / marker column
    track,           /// scrollbar track
    thumb,           /// scrollbar thumb
    selection,       /// selected-content tint (background only)
    chromeFocused,   /// the focused pane's header band (accented background)
}

private enum slotCount = Slot.max + 1;

/// How a box edge is stroked. Mirrors the CSS `border-style` keywords the
/// twoslash chrome uses (the `.twoslash-hover` bottom border is `dotted`; the
/// popup / accent bars are `solid`). A text-decoration underline uses the base
/// $(REF UnderlineStyle, sparkles,base,term_style) instead.
enum BorderStyle : ubyte
{
    none,   /// no edge drawn
    solid,  /// a solid rule (popup border, 3px accent bars, docs top divider)
    dotted, /// a dotted rule (the `.twoslash-hover` 1px underline)
    dashed, /// a dashed rule (available; unused by twoslash today)
}

/// Which font family a text run wants. The concrete faces live in the backend
/// (`sparkles:raylib-text`'s `FontSet`, the browser's monospace/sans stacks);
/// the model only names the role — CSS `--twoslash-code-font` (mono / `inherit`)
/// vs `--twoslash-docs-font` (`sans-serif`).
enum FontRole : ubyte
{
    inherit, /// the surrounding text font (monospace code)
    code,    /// the code/monospace face
    docs,    /// the documentation/sans face
}

/// A resolved box border: per-side widths in device px, one stroke style, and
/// the already-resolved edge color+alpha. A zero-width side draws nothing; the
/// `alpha` channel drives the `.twoslash-hover` underline's 0.3s fade-in.
struct BoxBorder
{
    Insets width;       /// per-side widths in px (top / right / bottom / left)
    BorderStyle style;  /// how present edges are stroked
    RgbColor color;     /// resolved edge color
    ubyte alpha = 0xFF; /// edge opacity

    /// `true` iff any edge is actually drawn.
    bool any() const scope @safe pure nothrow @nogc
        => style != BorderStyle.none
            && (width.top | width.right | width.bottom | width.left) != 0;
}

/// A resolved drop shadow (CSS `box-shadow: color dx dy blur`), offsets in px.
struct Shadow
{
    int dx;             /// horizontal offset in px
    int dy;             /// vertical offset in px
    int blur;           /// blur radius in px
    RgbColor color;     /// resolved shadow color
    ubyte alpha;        /// shadow opacity (0 ⇒ no shadow)

    /// `true` iff the shadow is visible.
    bool any() const scope @safe pure nothrow @nogc => alpha != 0;
}

/// A fully-resolved appearance: concrete RGB fore/background with alpha, whether
/// a background should be painted at all, packed text-style bits
/// ($(REF TextAttr, sparkles,base,term_style)), and — new — the resolved box
/// chrome (border / radius / shadow / arrow) and text chrome (font role / size /
/// underline). Produced by $(LREF resolveSlot) (colors only) or $(LREF resolveVisual)
/// (colors + chrome); consumed by every backend painter.
struct Visual
{
    RgbColor fg;          /// foreground RGB (already resolved against the page)
    ubyte fgAlpha = 0xFF; /// foreground opacity (0xFF = opaque)
    RgbColor bg;          /// background RGB (valid only when `hasBg`)
    ubyte bgAlpha = 0xFF; /// background opacity
    bool hasBg;           /// paint a background rectangle?
    ushort styleBits;     /// packed `TextAttr` flags (bold/italic/strikethrough/…)

    // --- box chrome (resolved from a widget's Decoration) ---
    BoxBorder border;     /// resolved box border (default: none)
    int borderRadius;     /// corner radius in px (0 = square corners)
    Shadow shadow;        /// resolved drop shadow (default: none)
    bool arrow;           /// draw a popup arrow/tail off this box's top edge?
    int arrowOffset;      /// arrow horizontal offset from the left, in cells

    // --- text chrome (resolved from a widget's TextStyle) ---
    FontRole fontRole;      /// which font family the run wants
    ushort fontScale = 100; /// font size as a percentage of 1em (100 = 1em)
    UnderlineStyle underline; /// text-decoration underline (default: none)
    ubyte underlineAlpha = 0xFF; /// underline opacity (hover-fade)
}

/// A widget's declared box decoration — slot-referencing and presentation-free
/// (the palette resolves the border/shadow colors). Widths, radius, and offsets
/// are the literal CSS px values, so a reviewer can read them against
/// `views/twoslash.css`. $(LREF resolveVisual) folds it into a $(LREF Visual).
struct Decoration
{
    Insets borderWidth;             /// per-side border widths in px
    BorderStyle borderStyle;        /// how the border is stroked (none ⇒ off)
    Slot borderSlot = Slot.border;  /// palette slot the border color comes from
    int borderRadius;               /// corner radius in px
    bool shadow;                    /// draw the palette's popup drop shadow?
    bool arrow;                     /// draw a popup arrow/tail (backends place it)
    int arrowOffset;                /// arrow horizontal offset from the left, in cells
}

/// A widget's declared text style — font role, relative size, weight/italic/
/// strike, and a text-decoration underline. $(LREF resolveVisual) packs the
/// boolean flags into $(LREF Visual)'s `styleBits`.
struct TextStyle
{
    FontRole fontRole;          /// code (mono) / docs (sans) / inherit
    ushort fontScale = 100;     /// percent of 1em
    bool bold;
    bool italic;
    bool strikethrough;
    UnderlineStyle underline;   /// text-decoration underline shape
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

    /// The widest a hover popup may grow, in cells. The backend narrows this
    /// further to the room actually left at the popup's anchor — the metric is
    /// the ceiling, not the width (`LAY10`: a view never invents one).
    int popupMaxWidth = 120;

    /// Popup docs width maximum, in cells. Handed to the layout engine as
    /// `Widget.width.max`, which wraps the run itself rather than the view
    /// packing lines.
    int docsMaxWidth = 56;

    /// Continuation indent, in cells, for a signature broken across rows.
    int sigIndent = 4;

    /// The narrowest a hover popup may be squeezed to. Below this a popup
    /// stops informing and starts shredding words, so a backend with less room
    /// than this shifts the popup instead of shrinking it further.
    int popupMinWidth = 24;

    // Sub-cell chrome geometry, in device px, authored to match `twoslash.css`
    // (the CSS-lockstep test guards these against the stylesheet). The TUI cell
    // grid approximates: any non-zero border → a 1-cell box-drawing rule; radius
    // and shadow are ignored (and logged), since a cell grid has no sub-cell edge.
    int borderWidth = 1;   /// hairline border (popup / `.twoslash-hover` underline)
    int accentBorder = 3;  /// left accent bar (error / warn / tag / query lines)
    int shadowDx = 0;      /// popup drop-shadow x offset (`box-shadow` 0 1px 4px)
    int shadowDy = 1;      /// popup drop-shadow y offset
    int shadowBlur = 4;    /// popup drop-shadow blur radius
    ushort codeFontScale = 100; /// popup code/signature size (`--twoslash-code-font-size` 1em)
    ushort docsFontScale = 80;  /// popup docs size (`.twoslash-popup-docs` 0.8em)
    ushort tagFontScale = 92;   /// JSDoc `@tag` chip size (`.twoslash-popup-docs-tag-name` 0.92em)
    int arrowSize = 6;     /// popup arrow square size (`.twoslash-popup-arrow` 6px)

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
        // The hoverable-token underline: the same neutral grey as the popup
        // border, but fainter — it is always on, under every hover span, so it
        // must read as a hint rather than as chrome.
        p.fg[hoverUnderline] = Color.fromRgb(0x88, 0x88, 0x88);
        p.fgAlpha[hoverUnderline] = 0x55;
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

        // Application chrome: a neutral band, muted gutters/tracks, a solid
        // thumb, a cool selection tint. Colors only — the glyphs (thumb/track
        // characters) are the theme's glyph channel.
        p.bg[chrome] = Color.fromRgb(0x7f, 0x7f, 0x7f);
        p.bgAlpha[chrome] = 0x20;
        // The focused pane's header band: the accent, translucent — clearly
        // apart from the neutral `chrome` band at a glance.
        p.bg[chromeFocused] = Color.fromRgb(0x37, 0x72, 0xcf);
        p.bgAlpha[chromeFocused] = 0x48;
        p.fg[chromeAccent] = Color.fromRgb(0x37, 0x72, 0xcf);
        p.fg[gutter] = Color.fromRgb(0x88, 0x88, 0x88);
        p.fg[track] = Color.fromRgb(0x88, 0x88, 0x88);
        p.fgAlpha[track] = 0x50;
        p.fg[thumb] = Color.fromRgb(0x88, 0x88, 0x88);
        p.bg[selection] = Color.fromRgb(0x37, 0x72, 0xcf);
        p.bgAlpha[selection] = 0x30;
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
Resolves a slot $(I plus) a widget's box $(LREF Decoration) and $(LREF TextStyle)
into a full $(LREF Visual): the slot supplies fore/background (via
$(LREF resolveSlot)); the decoration's border/shadow colors are resolved from
$(I their) slots against the same page colors; the palette's scalar shadow
geometry fills a requested drop shadow; and the text flags pack into `styleBits`.
This is the display-list path (colors + chrome); $(LREF resolveSlot) stays the
colors-only path used by the CSS-var and SGR generators.
*/
Visual resolveVisual(in Palette pal, Slot slot, in Decoration deco, in TextStyle text,
    in RgbColor pageFg, in RgbColor pageBg) pure nothrow @nogc
{
    Visual v = resolveSlot(pal, slot, pageFg, pageBg);

    // Box border: resolve the edge color from the decoration's own slot.
    if (deco.borderStyle != BorderStyle.none)
    {
        const bc = resolveSlot(pal, deco.borderSlot, pageFg, pageBg);
        v.border = BoxBorder(
            width: deco.borderWidth,
            style: deco.borderStyle,
            color: bc.fg,
            alpha: bc.fgAlpha,
        );
    }
    v.borderRadius = deco.borderRadius;

    // Drop shadow: the palette owns the geometry (0 1px 4px), Slot.shadow the color.
    if (deco.shadow)
    {
        const sc = resolveSlot(pal, Slot.shadow, pageFg, pageBg);
        v.shadow = Shadow(
            dx: pal.shadowDx, dy: pal.shadowDy, blur: pal.shadowBlur,
            color: sc.fg, alpha: sc.fgAlpha,
        );
    }

    v.arrow = deco.arrow;
    v.arrowOffset = deco.arrowOffset;

    // Text chrome.
    v.fontRole = text.fontRole;
    v.fontScale = text.fontScale;
    v.underline = text.underline;
    TextAttr attrs;
    if (text.bold)
        attrs = attrs | TextAttr.bold;
    if (text.italic)
        attrs = attrs | TextAttr.italic;
    if (text.strikethrough)
        attrs = attrs | TextAttr.strikethrough;
    v.styleBits = attrs.bits;

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
    VarBinding("--twoslash-underline-color", Slot.hoverUnderline, false),
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

@("ui.style.resolveVisual.popupChrome")
@safe pure nothrow @nogc
unittest
{
    const pal = defaultTwoslashPalette();
    const pageFg = RgbColor(0x22, 0x22, 0x22);
    const pageBg = RgbColor(0xff, 0xff, 0xff);

    // A popup: surface fill + a 1px solid border (Slot.border) + radius 4 + shadow.
    const deco = Decoration(
        borderWidth: Insets.all(pal.borderWidth),
        borderStyle: BorderStyle.solid,
        borderSlot: Slot.border,
        borderRadius: pal.popupRadius,
        shadow: true,
    );
    const v = resolveVisual(pal, Slot.surface, deco, TextStyle.init, pageFg, pageBg);

    // Colors come from the slot, chrome from the decoration + palette.
    assert(v.hasBg && v.bg == RgbColor(0xf8, 0xf8, 0xf8));
    assert(v.border.any);
    assert(v.border.style == BorderStyle.solid && v.border.width == Insets.all(1));
    assert(v.border.color == RgbColor(0x88, 0x88, 0x88) && v.border.alpha == 0x88);
    assert(v.borderRadius == 4);
    assert(v.shadow.any);
    assert(v.shadow.dx == 0 && v.shadow.dy == 1 && v.shadow.blur == 4);
    assert(v.shadow.color == RgbColor(0, 0, 0) && v.shadow.alpha == 0x14);
}

@("ui.style.resolveVisual.textStyleAndHoverUnderline")
@safe pure nothrow @nogc
unittest
{
    const pal = defaultTwoslashPalette();
    const pageFg = RgbColor(0x22, 0x22, 0x22);
    const pageBg = RgbColor(0xff, 0xff, 0xff);

    // Docs prose: sans face, 0.8em, italic → fontRole/scale carried, italic packed.
    const docs = resolveVisual(pal, Slot.docs,
        Decoration.init, TextStyle(fontRole: FontRole.docs, fontScale: 80, italic: true),
        pageFg, pageBg);
    assert(docs.fontRole == FontRole.docs && docs.fontScale == 80);
    assert((docs.styleBits & TextAttr.italic.bits) != 0);
    assert((docs.styleBits & TextAttr.bold.bits) == 0);

    // The `.twoslash-hover` token: a bottom-only 1px dotted border (currentColor),
    // which the TUI later degrades to a dotted cell underline.
    const hover = resolveVisual(pal, Slot.code,
        Decoration(borderWidth: Insets(0, 0, pal.borderWidth, 0),
            borderStyle: BorderStyle.dotted, borderSlot: Slot.code),
        TextStyle.init, pageFg, pageBg);
    assert(hover.border.any && hover.border.style == BorderStyle.dotted);
    assert(hover.border.width == Insets(0, 0, 1, 0));
    assert(hover.border.color == pageFg); // Slot.code inherits currentColor
}

@("ui.style.boxBorderAndShadow.anyPredicates")
@safe pure nothrow @nogc
unittest
{
    // A zero-width or BorderStyle.none border draws nothing.
    assert(!BoxBorder.init.any);
    assert(!BoxBorder(width: Insets.all(2), style: BorderStyle.none).any);
    assert(BoxBorder(width: Insets(0, 0, 1, 0), style: BorderStyle.dotted).any);
    // A zero-alpha shadow is invisible.
    assert(!Shadow.init.any);
    assert(Shadow(dy: 1, blur: 4, alpha: 0x14).any);
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
    assert(s.canFind("  --twoslash-underline-color: #88888855;\n")); // fainter than the border
}
