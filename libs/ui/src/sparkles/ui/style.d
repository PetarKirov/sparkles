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
import std.traits : EnumMembers;

import sparkles.base.term_style : TextAttr, UnderlineStyle;
import sparkles.wired.policy : CaseStyle, WireCase, WireName;
import sparkles.ui.geometry : Insets;

@safe:

/**
A semantic style role. Widgets and display-list ops carry a `Slot`, and a
$(LREF Palette) turns it into a concrete $(LREF Visual). Roles are intentionally
generic (an app palette can reuse them) even though the seed values come from
twoslash.

Every member carries its design-system $(B token path) as `@WireName` data
(`TOK2`): the one spelling wired resolves for JSON and the DTCG theme file, and
from which `sparkles.ui.tokens.cssName` derives the CSS custom property. The
semantic groups (`text`, `status`, `surface`, `border`, `accent`, `link`,
`selection`, `focus`, `shadow`) and the component namespaces (`chrome`,
`gutter`, `scrollbar`, `completion`, `input`, `twoslash`, `diff`, `coverage`)
are the spec's tiers; `inherit` is the one single-segment path.

The semantic roles are `TOK3`'s minimum set. A theme may leave any of them
unset: $(LREF defaultTwoslashPalette) supplies the scheme default and a theme
that pins its page colors derives them (`Theme.effectivePalette`), so every
role is total for every theme.
*/
@WireCase(CaseStyle.kebabCase)
enum Slot : ubyte
{
    /// no styling of its own — use the page fg/bg
    @WireName("inherit") inherit,
    /// code text inside a popup (inherits page fg)
    @WireName("text.code") code,
    /// documentation prose (muted)
    @WireName("text.docs") docs,
    /// error text + its translucent background
    @WireName("status.error") error,
    /// warning text + background
    @WireName("status.warning") warn,
    /// informational / `@tag` text + background
    @WireName("status.info") info,
    /// success text + background (`TOK3`; the diff-added hue)
    @WireName("status.success") success,
    /// `@annotate`-family tag text + background
    @WireName("twoslash.annotate") annotate,
    /// highlighted-range tint (background only)
    @WireName("twoslash.highlight") highlight,
    /// highlighted-range border
    @WireName("twoslash.highlight.border") highlightBorder,
    /// popup / panel background (opaque)
    @WireName("surface.overlay") surface,
    /// the page itself (`TOK3`; unset ⇒ no fill, the page shows through)
    @WireName("surface.base") surfaceBase,
    /// a card or panel one step above the page
    @WireName("surface.raised") surfaceRaised,
    /// a well or input field one step below the page
    @WireName("surface.sunken") surfaceSunken,
    /// popup / panel border line
    @WireName("border.default") border,
    /// an emphasized border (a selected card, a table header rule)
    @WireName("border.strong") borderStrong,
    /// the border of the focused element (`TOK3`; the accent by default)
    @WireName("border.focus") borderFocus,
    /// the interactive accent: links, the active tab, primary actions
    @WireName("accent.primary") accentPrimary,
    /// a second accent for contrast with the first (badges, secondary actions)
    @WireName("accent.secondary") accentSecondary,
    /// link text (`TOK3`; the primary accent by default)
    @WireName("link.fg") link,
    /// the focus ring drawn around the focused element
    @WireName("focus.ring") focusRing,
    /// hoverable-token underline (`.twoslash-hover`, always on)
    @WireName("link.underline") hoverUnderline,
    /// popup drop shadow
    @WireName("shadow.overlay") shadow,
    /// matched prefix in a completion list (inherits page fg)
    @WireName("completion.matched") matched,
    /// unmatched remainder in a completion list (muted)
    @WireName("completion.unmatched") unmatched,
    /// query caret / cursor marker
    @WireName("input.caret") caret,
    /// generic de-emphasized text
    @WireName("text.muted") muted,
    /// body text — the page foreground (`TOK3`; unset ⇒ page fg)
    @WireName("text.primary") textPrimary,
    /// supporting text: one step toward the page background
    @WireName("text.secondary") textSecondary,
    /// text of a control that cannot be interacted with
    @WireName("text.disabled") textDisabled,
    /// text drawn over an accent or inverted band: the page background's tone
    @WireName("text.inverse") textInverse,
    /// a JSDoc `@tag` name pill in a popup (muted text on a grey bg)
    @WireName("twoslash.chip") chip,

    // Application-chrome slots (the widened vocabulary the component catalog
    // requires — `THM2`): bands, gutters and scroll affordances.
    /// header / status-bar band (its background + text)
    @WireName("chrome.band") chrome,
    /// emphasized chrome text (title, active segment, key hints)
    @WireName("chrome.accent") chromeAccent,
    /// line-number / marker column (foreground only)
    @WireName("gutter.fg") gutter,
    /// the line-number gutter STRIP: its own band, distinct from both the
    /// page and a code panel's surface
    @WireName("gutter.band") gutterBand,
    /// scrollbar track
    @WireName("scrollbar.track") track,
    /// scrollbar thumb
    @WireName("scrollbar.thumb") thumb,
    /// selected-content tint (background only)
    @WireName("selection.bg") selection,
    /// the focused pane's header band (accented background)
    @WireName("chrome.focused") chromeFocused,

    // Diff slots (the diff viewer's design language — hue diff-view `DVL5`):
    // row tints layered OVER syntax colors (alpha-composited, the
    // git-split-diffs recipe), a second emphasis tier for changed word
    // segments (delta's two-tone emphasis), the hunk header, and the filler
    // opposite unmatched split rows.
    /// added-row tint (background only)
    @WireName("diff.added") diffAdded,
    /// removed-row tint (background only)
    @WireName("diff.removed") diffRemoved,
    /// changed word segments within an added/paired row
    @WireName("diff.emph.added") diffEmphAdded,
    /// changed word segments within a removed/paired row
    @WireName("diff.emph.removed") diffEmphRemoved,
    /// hunk-header line (`@@ … @@`) text + faint band
    @WireName("diff.hunk") diffHunk,
    /// filler opposite an unmatched row in a split layout
    @WireName("diff.fill") diffFill,

    // Coverage slots (the code-coverage overlay's gutter column — hue
    // `COV2`/`OVL7`). Foreground only: the column is text, and tinting its
    // background would fight the diff row tints it can appear beside.
    // Deliberately the same three hues as the diff and diagnostic slots, so
    // "ran / never ran / partly ran" reads in the design language a viewer
    // already knows rather than a fourth private palette.
    /// a line that executed at least once
    @WireName("coverage.covered") covCovered,
    /// a line that emitted code and never ran
    @WireName("coverage.uncovered") covUncovered,
    /// a line that ran, but not every branch out of it
    @WireName("coverage.partial") covPartial,
}

private enum slotCount = Slot.max + 1;

// ── interaction states (TOK4, TOK5) ─────────────────────────────────────────

/**
The second axis of slot resolution (`TOK4`). Declaration order $(B is) the
precedence (`TOK5`): when several states are active, the override of the
highest one that has an override wins. `rest` is the absence of every other
state, never a bit of its own.
*/
@WireCase(CaseStyle.kebabCase)
enum InteractionState : ubyte
{
    rest,     /// nothing else applies — the value a theme always sets
    hover,    /// the pointer rests on it
    focused,  /// it owns keyboard focus
    selected, /// it is part of the selection
    pressed,  /// the pointer/key is down on it
    disabled, /// it cannot be interacted with
}

/// The set of currently active states — a bitset over every state but
/// `rest`, which is the empty set.
struct StateSet
{
    private ubyte bits;

@safe pure nothrow @nogc:

    /// Builds a set from the listed states; `rest` contributes nothing.
    static StateSet of(scope const InteractionState[] states...)
    {
        StateSet r;
        foreach (s; states)
            r = r.with_(s);
        return r;
    }

    private static ubyte bit(InteractionState s)
        => s == InteractionState.rest ? 0 : cast(ubyte)(1u << (s - 1));

    bool empty() const => bits == 0;

    bool has(InteractionState s) const
        => s == InteractionState.rest ? empty : (bits & bit(s)) != 0;

    StateSet with_(InteractionState s) const => StateSet(cast(ubyte)(bits | bit(s)));

    StateSet without(InteractionState s) const => StateSet(cast(ubyte)(bits & ~bit(s)));

    /**
    The state whose override wins (`TOK5`): the highest-precedence active
    state — or `rest` for the empty set. A resolver that consults overrides
    walks from `highest` downward and stops at the first override set, so a
    theme that sets none yields exactly `rest` (`TOK4`).
    */
    InteractionState highest() const
    {
        static foreach_reverse (s; EnumMembers!InteractionState)
            if (has(s))
                return s;
        return InteractionState.rest;
    }
}

@("ui.style.StateSet.precedence")
@safe pure nothrow @nogc
unittest
{
    // TOK4: the empty set is `rest`.
    StateSet none;
    assert(none.empty);
    assert(none.has(InteractionState.rest));
    assert(none.highest == InteractionState.rest);

    // TOK5: disabled > pressed > selected > focused > hover.
    const hf = StateSet.of(InteractionState.hover, InteractionState.focused);
    assert(hf.highest == InteractionState.focused);
    assert(!hf.has(InteractionState.rest));
    assert(hf.with_(InteractionState.disabled).highest == InteractionState.disabled);
    assert(hf.with_(InteractionState.pressed).without(InteractionState.pressed) == hf);
    assert(StateSet.of(InteractionState.selected, InteractionState.hover).highest
        == InteractionState.selected);
    // `rest` never contributes a bit.
    assert(StateSet.of(InteractionState.rest).empty);
}


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
    /// two parallel rules: CSS `double`, box-drawing `═║╔╗╚╝` on a cell target
    /// (design-system `GLY2`; the underscore because `double` is a keyword)
    double_,
}

/// A box edge, in CSS order. This is the toolkit's $(I one) side vocabulary
/// ($(REF PRN8, docs,specs,ui,principles)): `sparkles.ui.overlay.place.Side` is
/// an alias of it, so a placement solve's resolved side and the edge a backend
/// draws an arrow on cannot drift into two enums that disagree.
enum BoxSide : ubyte
{
    top,    /// the box's top edge
    right,  /// the box's right edge
    bottom, /// the box's bottom edge
    left,   /// the box's left edge
}

/// The edge opposite `s` — what a placement flip mirrors to (`PLC6`).
BoxSide opposite(BoxSide s) @safe pure nothrow @nogc
    => cast(BoxSide)((s + 2) & 3);

/// Whether `s` is a vertical edge, i.e. whether flipping it moves the box on
/// the $(I y) axis.
bool isVertical(BoxSide s) @safe pure nothrow @nogc
    => s == BoxSide.top || s == BoxSide.bottom;

@("ui.style.BoxSide.oppositeIsAnInvolution")
@safe pure nothrow @nogc unittest
{
    static foreach (s; [BoxSide.top, BoxSide.right, BoxSide.bottom, BoxSide.left])
    {
        assert(s.opposite.opposite == s, "opposite must be its own inverse");
        assert(s.opposite != s, "no edge is its own opposite");
        assert(s.isVertical == s.opposite.isVertical, "a flip keeps the axis");
    }
    assert(BoxSide.top.opposite == BoxSide.bottom);
    assert(BoxSide.left.opposite == BoxSide.right);
    assert(BoxSide.top.isVertical && !BoxSide.left.isVertical);
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
    bool arrow;           /// draw a popup arrow/tail off this box?
    /// Which edge the tail hangs off. Resolved by the placement solve
    /// ($(REF place, sparkles,ui,overlay,place)) and carried here, so a backend
    /// draws what it is told rather than assuming `top` (`PLC10`).
    BoxSide arrowSide;
    /// The tail's cell along `arrowSide`'s edge, measured from the box origin
    /// with the border inset included — so the legal interval is
    /// `[1, extent - 2]` and a caret can never land on a corner glyph (`ANC4`).
    int arrowOffset;

    // --- text chrome (resolved from a widget's TextStyle) ---
    FontRole fontRole;      /// which font family the run wants
    ushort fontScale = 100; /// font size as a percentage of 1em (100 = 1em)
    UnderlineStyle underline; /// text-decoration underline (default: none)
    ubyte underlineAlpha = 0xFF; /// underline opacity (hover-fade)
    /// The hyperlink this run belongs to — an index into the frame's URI
    /// table, `0` for none. Carried from $(REF TextSpan.linkId, sparkles,ui,wrap);
    /// a cell backend turns it into OSC 8, a GPU backend ignores it.
    ushort linkId;
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
    /// Draw a popup arrow/tail? The resolved side and the clamped cell come
    /// from the placement solve; a backend draws what it is told and never
    /// picks an edge of its own (`PLC10`).
    bool arrow;
    BoxSide arrowSide;              /// which edge the tail hangs off (`PLC10`)
    /// The tail's cell along `arrowSide`'s edge, from the box origin, border
    /// inset included. Legal interval `[1, extent - 2]` (`ANC4`).
    int arrowOffset;
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
/// A sparse per-state color overlay — see `Palette.states`.
struct StateColors
{
    Color[slotCount] fg;             /// set ⇒ replaces the rest fg in this state
    ubyte[slotCount] fgAlpha = 0xFF; /// the fg's opacity when `fg` is set
    Color[slotCount] bg;             /// set ⇒ replaces the rest bg in this state
    ubyte[slotCount] bgAlpha = 0xFF; /// the bg's opacity when `bg` is set
}

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

    /**
    The interaction-state dimension (`TOK4`/`TOK5`): one sparse overlay per
    state but `rest`, indexed by `state - 1`. A set `fg`/`bg` replaces the
    rest value for that state; an unset one falls through, so a theme that
    sets none resolves every state exactly as `rest`. Attributes and metrics
    per state are not carried yet (design-system D22 admits them; they land
    with their first consumer).
    */
    StateColors[InteractionState.max] states;

    /// The overlay for `s` (never `rest`, whose colors are the arrays above).
    ref inout(StateColors) overlay(InteractionState s) inout return
        pure nothrow @nogc
    in (s != InteractionState.rest, "rest has no overlay; set fg/bg directly")
        => states[s - 1];

    // --- scalar chrome (shared across GUI/HTML/TUI) ---
    // Metrics are named by ROLE, not by the feature that first needed them
    // (design-system `TOK8`), and each carries its token path as `@WireName`
    // data — the key it serializes under, and the DTCG token it becomes.
    // Cell-typed metrics are the layout's own unit; px-typed ones (radius,
    // weights, shadow) carry a projection onto a cell target (`TOK7`/`GLY2`).
    /// popup corner radius (px in GUI, ignored in cells)
    @WireName("radius.overlay") int overlayRadius = 4;
    /// popup horizontal padding, in cells
    @WireName("pad.overlay.x") int overlayPadX = 1;
    /// popup vertical padding, in cells
    @WireName("pad.overlay.y") int overlayPadY = 1;
    /// blank rows between code and a detached meta block
    @WireName("gap.detach") int detachGap = 1;

    /// The widest a hover popup may grow, in cells. The backend narrows this
    /// further to the room actually left at the popup's anchor — the metric is
    /// the ceiling, not the width (`LAY10`: a view never invents one).
    @WireName("width.overlay.max") int overlayMaxWidth = 120;

    /// Popup docs width maximum, in cells. Handed to the layout engine as
    /// `Widget.width.max`, which wraps the run itself rather than the view
    /// packing lines.
    @WireName("width.docs.max") int docsMaxWidth = 56;

    /// Continuation indent, in cells, for a signature broken across rows.
    @WireName("indent.signature") int signatureIndent = 4;

    /// The tallest a hover popup may grow, in rows. Like `overlayMaxWidth`
    /// this is a ceiling handed to the placement solve as a size $(I bound),
    /// never a height: the side is chosen from the bound before the content is
    /// measured (`PLC9`), and content beyond what the solve grants scrolls
    /// rather than overflowing the surface.
    @WireName("height.overlay.max") int overlayMaxHeight = 24;

    /// The narrowest a hover popup may be squeezed to. Below this a popup stops
    /// informing and starts shredding words.
    ///
    /// This is the floor of the placement solve's $(I last) step. The fixed
    /// precedence is **flip, then slide, then resize** (`PLC5`): a popup that
    /// does not fit first tries the opposite side of its anchor, then slides
    /// along the edge, and only then gives up extent — down to this floor, and
    /// no further. A solve that still cannot fit reports `refused` instead of
    /// returning a width nobody can read.
    @WireName("width.overlay.min") int overlayMinWidth = 24;

    /// The shortest a hover popup may be squeezed to, in rows: a border pair
    /// and one row of content. `PLC5`'s resize floors here on the other axis.
    @WireName("height.overlay.min") int overlayMinHeight = 3;

    // Sub-cell chrome geometry, in device px, authored to match `twoslash.css`
    // (the CSS-lockstep test guards these against the stylesheet). The TUI cell
    // grid approximates: any non-zero border → a 1-cell box-drawing rule; radius
    // and shadow are ignored (and logged), since a cell grid has no sub-cell edge.
    /// hairline border (popup / `.twoslash-hover` underline)
    @WireName("border.weight") int borderWeight = 1;
    /// left accent bar (error / warn / tag / query lines)
    @WireName("border.accent") int accentWeight = 3;
    /// popup drop-shadow x offset (`box-shadow` 0 1px 4px)
    @WireName("shadow.dx") int shadowDx = 0;
    /// popup drop-shadow y offset
    @WireName("shadow.dy") int shadowDy = 1;
    /// popup drop-shadow blur radius
    @WireName("shadow.blur") int shadowBlur = 4;
    /// popup code/signature size (`--twoslash-code-font-size` 1em)
    @WireName("font.scale.code") ushort codeFontScale = 100;
    /// popup docs size (`.twoslash-popup-docs` 0.8em)
    @WireName("font.scale.docs") ushort docsFontScale = 80;
    /// JSDoc `@tag` chip size (`.twoslash-popup-docs-tag-name` 0.92em)
    @WireName("font.scale.tag") ushort tagFontScale = 92;
    /// popup arrow square size (`.twoslash-popup-arrow` 6px)
    @WireName("arrow.size") int arrowSize = 6;

    dchar caretGlyph = '^';   /// query caret marker (the `^` twoslash draws)
    dchar arrowGlyph = '─';   /// leader from a meta line up to its column
    dchar queryGlyph = '│';   /// vertical connector under a `^?` query
    /// The close affordance on a persistent overlay. A theme that cannot render
    /// `×` overrides it, the same way `theme.d`'s border charsets do.
    dchar closeGlyph = '×';
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

        p.fg[success] = Color.fromRgb(0x1b, 0xa6, 0x73);
        p.bg[success] = Color.fromRgb(0x1b, 0xa6, 0x73);
        p.bgAlpha[success] = 0x20;

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

        // code / matched / inherit / textPrimary stay unset ⇒ page foreground.

        // The TOK3 roles a scheme can answer without knowing the page colors:
        // greys for the text steps, the neutral surfaces, the shared accent.
        // A theme that pins its page colors replaces every one of these with
        // a mix of its own (`Theme.effectivePalette`).
        p.fg[textSecondary] = Color.fromRgb(0x99, 0x99, 0x99);
        p.fg[textDisabled] = Color.fromRgb(0x88, 0x88, 0x88);
        p.fgAlpha[textDisabled] = 0x80;
        p.fg[textInverse] = dark ? Color.fromRgb(0x1e, 0x1e, 0x1e) : Color.fromRgb(0xf8, 0xf8, 0xf8);
        // surfaceBase stays unset: the page shows through.
        p.bg[surfaceRaised] = dark ? Color.fromRgb(0x2a, 0x2a, 0x2a) : Color.fromRgb(0xff, 0xff, 0xff);
        p.bg[surfaceSunken] = dark ? Color.fromRgb(0x16, 0x16, 0x16) : Color.fromRgb(0xee, 0xee, 0xee);
        p.fg[borderStrong] = Color.fromRgb(0x88, 0x88, 0x88);
        p.fg[borderFocus] = Color.fromRgb(0x37, 0x72, 0xcf);
        p.fg[accentPrimary] = Color.fromRgb(0x37, 0x72, 0xcf);
        p.fg[accentSecondary] = Color.fromRgb(0x98, 0x6e, 0xe2);
        p.fg[link] = Color.fromRgb(0x37, 0x72, 0xcf);
        p.fg[focusRing] = Color.fromRgb(0x37, 0x72, 0xcf);

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
        // The number-gutter strip: the muted number fg over a faint neutral
        // wash that reads on any page — a personalized theme overrides both
        // with opaque mixes of its own page colors (`THM7`).
        p.fg[gutterBand] = Color.fromRgb(0x88, 0x88, 0x88);
        p.bg[gutterBand] = Color.fromRgb(0x7f, 0x7f, 0x7f);
        p.bgAlpha[gutterBand] = 0x14;
        p.fg[track] = Color.fromRgb(0x88, 0x88, 0x88);
        p.fgAlpha[track] = 0x50;
        p.fg[thumb] = Color.fromRgb(0x88, 0x88, 0x88);
        p.bg[selection] = Color.fromRgb(0x37, 0x72, 0xcf);
        p.bgAlpha[selection] = 0x30;

        // Diff rows: the shared brand green/red as translucent row tints,
        // with a stronger second tier for word-level emphasis (delta's
        // emph/non-emph distinction as alpha, not a second hue). The hunk
        // header reads as chrome-adjacent info text; the split-layout filler
        // is a faint neutral wash.
        // `0x43`, not `0x24`: a row tint is painted ONCE, by the row, so its
        // alpha has to carry the whole wash. It used to land on a cell that
        // had already been tinted, and two 0x24 passes compose to ~0x43 — so
        // this is the colour a diff has always had, now reached in one paint
        // instead of depending on how many surfaces happened to stack.
        p.bg[diffAdded] = Color.fromRgb(0x1b, 0xa6, 0x73);
        p.bgAlpha[diffAdded] = 0x43;
        p.bg[diffRemoved] = Color.fromRgb(0xd4, 0x56, 0x56);
        p.bgAlpha[diffRemoved] = 0x43;
        p.bg[diffEmphAdded] = Color.fromRgb(0x1b, 0xa6, 0x73);
        p.bgAlpha[diffEmphAdded] = 0x58;
        p.bg[diffEmphRemoved] = Color.fromRgb(0xd4, 0x56, 0x56);
        p.bgAlpha[diffEmphRemoved] = 0x58;
        p.fg[diffHunk] = Color.fromRgb(0x37, 0x72, 0xcf);
        p.bg[diffHunk] = Color.fromRgb(0x37, 0x72, 0xcf);
        p.bgAlpha[diffHunk] = 0x14;
        p.bg[diffFill] = Color.fromRgb(0x7f, 0x7f, 0x7f);
        p.bgAlpha[diffFill] = 0x14;

        // Coverage gutter, sharing the diff/diagnostic hues: a tint behind
        // the column so coverage is scannable without reading a single
        // number, and the count itself on top of it. The alpha matches the
        // diff row tints — this is the same "a band of colour states what
        // happened to this line" idea, one column narrower.
        p.fg[covCovered] = Color.fromRgb(0x1b, 0xa6, 0x73);
        p.bg[covCovered] = Color.fromRgb(0x1b, 0xa6, 0x73);
        p.bgAlpha[covCovered] = 0x24;
        p.fg[covUncovered] = Color.fromRgb(0xd4, 0x56, 0x56);
        p.bg[covUncovered] = Color.fromRgb(0xd4, 0x56, 0x56);
        p.bgAlpha[covUncovered] = 0x24;
        p.fg[covPartial] = Color.fromRgb(0xc3, 0x7d, 0x0d);
        p.bg[covPartial] = Color.fromRgb(0xc3, 0x7d, 0x0d);
        p.bgAlpha[covPartial] = 0x24;
    }
    return p;
}

/**
Resolves `slot` against `pal` and the page fore/background to a concrete
$(LREF Visual). Unset slot colors defer: an unset `fg` becomes `pageFg`, an
unset `bg` yields `hasBg == false`.
*/
Visual resolveSlot(in Palette pal, Slot slot, in RgbColor pageFg, in RgbColor pageBg,
    StateSet states = StateSet.init) pure nothrow @nogc
{
    const i = cast(size_t) slot;
    Visual v;
    v.fg = toRgb(pal.fg[i], pageFg);
    v.fgAlpha = pal.fgAlpha[i];
    v.hasBg = pal.bg[i].isSet;
    v.bg = toRgb(pal.bg[i], pageBg);
    v.bgAlpha = pal.bgAlpha[i];

    // TOK5: per channel, the highest-precedence ACTIVE state that sets the
    // channel wins; a state that sets only `fg` leaves `bg` to fall through.
    // Walked highest → lowest so the first hit is the answer.
    bool fgDone, bgDone;
    static foreach_reverse (s; EnumMembers!InteractionState)
        static if (s != InteractionState.rest)
            if (states.has(s))
            {
                const ref o = pal.states[s - 1];
                if (!fgDone && o.fg[i].isSet)
                {
                    v.fg = toRgb(o.fg[i], pageFg);
                    v.fgAlpha = o.fgAlpha[i];
                    fgDone = true;
                }
                if (!bgDone && o.bg[i].isSet)
                {
                    v.bg = toRgb(o.bg[i], pageBg);
                    v.bgAlpha = o.bgAlpha[i];
                    v.hasBg = true;
                    bgDone = true;
                }
            }
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
    in RgbColor pageFg, in RgbColor pageBg, StateSet states = StateSet.init)
    pure nothrow @nogc
{
    // The states apply to the slot's own colors; a border or shadow keeps its
    // rest appearance unless its own slot is resolved with states by a caller.
    Visual v = resolveSlot(pal, slot, pageFg, pageBg, states);

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
    v.arrowSide = deco.arrowSide;
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

@("ui.style.defaultTwoslashPalette.tok3RolesAreTotal")
@safe pure nothrow @nogc
unittest
{
    // TOK3: every semantic role resolves in both schemes without a theme
    // saying anything — the roles that mean "the page" stay unset by design.
    static foreach (scheme; [ColorScheme.light, ColorScheme.dark])
    {{
        const p = defaultTwoslashPalette(scheme);
        with (Slot)
        {
            static foreach (s; [textSecondary, textDisabled, textInverse,
                borderStrong, borderFocus, accentPrimary, accentSecondary, link,
                focusRing, success])
                assert(p.fg[s].isSet, "unset fg for a TOK3 role");
            static foreach (s; [surfaceRaised, surfaceSunken, success])
                assert(p.bg[s].isSet, "unset bg for a TOK3 role");
            assert(!p.fg[textPrimary].isSet && !p.bg[surfaceBase].isSet);
            // The steps order: disabled is fainter than secondary than primary.
            assert(p.fgAlpha[textDisabled] < p.fgAlpha[textSecondary]);
            // Inverse text is the scheme's page tone, not a grey.
            assert(p.fg[textInverse] != p.fg[muted]);
            // The interactive roles share one accent by default.
            assert(p.fg[link] == p.fg[accentPrimary]
                && p.fg[borderFocus] == p.fg[accentPrimary]
                && p.fg[focusRing] == p.fg[accentPrimary]);
            assert(p.fg[accentSecondary] != p.fg[accentPrimary]);
        }
    }}
}

@("ui.style.resolveSlot.statesFallThroughToRest")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.term_color : Color;

    const fg = RgbColor(0x10, 0x10, 0x10), bg = RgbColor(0xf0, 0xf0, 0xf0);
    auto pal = defaultTwoslashPalette();
    const rest = resolveSlot(pal, Slot.thumb, fg, bg);

    // TOK4: no overlay set ⇒ every state set resolves exactly as rest.
    const all = StateSet.of(InteractionState.hover, InteractionState.focused,
        InteractionState.selected, InteractionState.pressed, InteractionState.disabled);
    assert(resolveSlot(pal, Slot.thumb, fg, bg, all) == rest);
    assert(resolveSlot(pal, Slot.thumb, fg, bg, StateSet.of(InteractionState.hover)) == rest);

    // A hover overlay that sets only the fg: bg falls through to rest.
    pal.overlay(InteractionState.hover).fg[Slot.thumb] = Color.fromRgb(0x33, 0x66, 0x99);
    const hov = resolveSlot(pal, Slot.thumb, fg, bg, StateSet.of(InteractionState.hover));
    assert(hov.fg == RgbColor(0x33, 0x66, 0x99) && hov.fgAlpha == 0xFF);
    assert(hov.hasBg == rest.hasBg && hov.bg == rest.bg);
    // …and a state with no overlay still reads as rest.
    assert(resolveSlot(pal, Slot.thumb, fg, bg, StateSet.of(InteractionState.focused)) == rest);

    // TOK5: pressed outranks hover for the channel it sets; the channel it
    // does not set comes from the next state down that does.
    pal.overlay(InteractionState.pressed).bg[Slot.thumb] = Color.fromRgb(0xaa, 0x00, 0x00);
    pal.overlay(InteractionState.pressed).bgAlpha[Slot.thumb] = 0x80;
    const both = resolveSlot(pal, Slot.thumb, fg, bg,
        StateSet.of(InteractionState.hover, InteractionState.pressed));
    assert(both.fg == RgbColor(0x33, 0x66, 0x99), "fg: only hover sets it");
    assert(both.hasBg && both.bg == RgbColor(0xaa, 0x00, 0x00) && both.bgAlpha == 0x80,
        "bg: pressed sets it");
    // disabled outranks everything it sets.
    pal.overlay(InteractionState.disabled).fg[Slot.thumb] = Color.fromRgb(0x77, 0x77, 0x77);
    const dis = resolveSlot(pal, Slot.thumb, fg, bg, all);
    assert(dis.fg == RgbColor(0x77, 0x77, 0x77) && dis.bg == RgbColor(0xaa, 0x00, 0x00));
}

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
        borderWidth: Insets.all(pal.borderWeight),
        borderStyle: BorderStyle.solid,
        borderSlot: Slot.border,
        borderRadius: pal.overlayRadius,
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
        Decoration(borderWidth: Insets(0, 0, pal.borderWeight, 0),
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
    import sparkles.base.buffer : SharedBuffer;

    const pal = defaultTwoslashPalette();
    SharedBuffer!(char, 64) buf;
    writeSlotSgr(buf, pal, Slot.error, ColorChannel.foreground, ColorDepth.trueColor);
    assert(buf[] == "38;2;212;86;86"); // 0xd4 0x56 0x56

    SharedBuffer!(char, 64) buf2;
    writeSlotSgr(buf2, pal, Slot.code, ColorChannel.foreground, ColorDepth.trueColor);
    assert(buf2[] == "39"); // unset ⇒ default-foreground reset
}

@("ui.style.writeTwoslashVars.hexShapes")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.buffer : SharedBuffer;
    import std.algorithm.searching : canFind;

    const pal = defaultTwoslashPalette();
    SharedBuffer!(char, 1024) buf;
    writeTwoslashVars(buf, pal);
    const s = buf[];

    assert(s.canFind("  --twoslash-error-color: #d45656;\n"));
    assert(s.canFind("  --twoslash-error-bg: #d4565620;\n"));   // alpha kept
    assert(s.canFind("  --twoslash-highlighted-border: #c37d0d50;\n"));
    assert(s.canFind("  --twoslash-popup-bg: #f8f8f8;\n"));     // opaque ⇒ no alpha
    assert(s.canFind("  --twoslash-border-color: #88888888;\n")); // CSS #8888 = rgba, alpha 0x88
    assert(s.canFind("  --twoslash-underline-color: #88888855;\n")); // fainter than the border
}
