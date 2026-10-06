/**
The glyph channel's tiers and ladders (design-system
[`GLY1`–`GLY3`](../../../../../docs/specs/design-system/glyphs.md)).

A glyph needs something of its target: a box-drawing stroke needs `unicode`,
an eighth-block needs a `blocks` tier, a braille cell needs `braille`, a Private
Use Area icon needs `nerdFont`. $(LREF needOf) classifies a code point by that
need, $(LREF admits) answers it against a declaration, and $(LREF fallbackOf)
names the published substitution one rung down — always one cell wide, always
ending in ASCII. $(LREF projectGlyph) walks the ladder until the target admits
the glyph, which is what a cell painter calls on every glyph it writes: the
theme and the components ask for the richest glyph they want, and the target's
declaration caps it at paint time (`CAP4`: never at theme time).

$(LREF Mark) is the status-mark vocabulary (`GLY3`, `ACC3`): one glyph per
status in each of three charsets, declared on the member and consistent with
the ladder by test, and $(LREF ActionIcon) the action icons, in the same three.
*/
module sparkles.ui.glyphs;

import std.traits : EnumMembers, getUDAs;

import sparkles.base.term_caps : BlockTier;
import sparkles.ui.icons : Icon;
public import sparkles.ui.style : MarkCharset;
import sparkles.ui.interp.cells : asciiStroke;
import sparkles.ui.tokens : TargetCapabilities;

@safe pure nothrow @nogc:

/// What a code point needs of its target (`GLY1`), weakest first.
enum GlyphNeed : ubyte
{
    ascii,          /// always renders
    unicode,        /// any non-ASCII glyph: box drawing, marks, arrows, text
    blocksHalf,     /// half and eighth blocks, shades (`BlockTier.half`)
    blocksQuadrant, /// the 2×2 quadrants
    blocksSextant,  /// the 2×3 sextants (Symbols for Legacy Computing)
    blocksOctant,   /// the 2×4 octants (Unicode 16)
    braille,        /// the U+2800 block as a 2×4 dot grid
    nerdFont,       /// a Private Use Area icon
}

/// The need of `g` — by range, so it holds for code points no table lists.
GlyphNeed needOf(dchar g)
{
    if (g < 0x80)
        return GlyphNeed.ascii;
    if (g >= 0x2596 && g <= 0x259F)
        return GlyphNeed.blocksQuadrant;
    if (g >= 0x2580 && g <= 0x2595)
        return GlyphNeed.blocksHalf;
    // The sextants, and the quarter blocks of the same Unicode 13 block the
    // octant raster borrows (a font with one has the other).
    if (g >= 0x1FB00 && g <= 0x1FB3B || g == 0x1FB82 || g == 0x1FB85
        || g == 0x1FBE6 || g == 0x1FBE7)
        return GlyphNeed.blocksSextant;
    // The octants, and the Unicode 16 quarter blocks they draw corners with.
    if (g >= 0x1CD00 && g <= 0x1CDE5 || g >= 0x1CEA0 && g <= 0x1CEAF)
        return GlyphNeed.blocksOctant;
    if (g >= 0x2800 && g <= 0x28FF)
        return GlyphNeed.braille;
    if ((g >= 0xE000 && g <= 0xF8FF) || (g >= 0xF0000 && g <= 0x10FFFD))
        return GlyphNeed.nerdFont;
    return GlyphNeed.unicode;
}

/// Whether a target declaring `caps` can show a glyph of need `n`. Every tier
/// above `ascii` also needs `unicode`: a block or an icon is still UTF-8.
bool admits(in TargetCapabilities caps, GlyphNeed n)
{
    final switch (n) with (GlyphNeed)
    {
        case ascii:          return true;
        case unicode:        return caps.unicode;
        case blocksHalf:     return caps.unicode && caps.blocks >= BlockTier.half;
        case blocksQuadrant: return caps.unicode && caps.blocks >= BlockTier.quadrant;
        case blocksSextant:  return caps.unicode && caps.blocks >= BlockTier.sextant;
        case blocksOctant:   return caps.unicode && caps.blocks >= BlockTier.octant;
        case braille:        return caps.unicode && caps.braille;
        case nerdFont:       return caps.unicode && caps.nerdFont;
    }
}

/// ditto
bool admits(in TargetCapabilities caps, dchar g) => admits(caps, needOf(g));

/// The substitution for a glyph nothing more specific names: one cell, and
/// unmistakably a stand-in.
enum dchar replacementGlyph = '?';

/**
The published substitution for `g` one rung down its ladder (`GLY1`, `CAP6`):
a one-cell glyph of strictly weaker need, so repeated application reaches
ASCII. Marks step through their own charsets ($(LREF Mark)); box drawing
folds to its ASCII stroke; blocks thin to the box stroke of the same weight or
to a shade; finer rasters and braille coarsen to a shade; the common arrows
and bullets have ASCII look-alikes; an $(LREF ActionIcon) steps down its own rungs;
anything else — an icon with neither a mark nor an $(LREF ActionIcon), a
letter the target cannot encode — becomes $(LREF replacementGlyph).
*/
dchar fallbackOf(dchar g)
{
    foreach (ref mg; markTable)
    {
        if (g == mg.nerdFont)
            return mg.unicode;
        if (g == mg.unicode && mg.unicode >= 0x80
                && !(g >= 0x2500 && g <= 0x257F)) // a box stroke folds as a stroke
            return mg.ascii;
    }
    // An icon steps down its own ladder (a shared Unicode stand-in, such as
    // `▶` or `✕`, folds as the switch below would).
    foreach (ref ig; iconTable)
    {
        if (g == ig.nerdFont)
            return ig.unicode;
        if (g == ig.unicode)
            return ig.ascii;
    }
    if (g >= 0x2500 && g <= 0x257F)
        return asciiStroke(g);
    switch (g)
    {
        // Bars: the stroke of the same weight.
        case '▏', '▎', '▕':
            return '│';
        case '▍', '▌', '▐':
            return '┃';
        // Fills and shades, by density; a raster cell coarsens to a shade.
        case '░':
            return '.';
        case '▒':
            return ':';
        case '▓', '█', '▉', '▊', '▋', '▀', '▄', '▅', '▆', '▇':
            return '#';
        case '▁', '▂', '▃':
            return '_';
        case '▔':
            return '-';
        // Pointers, arrows and bullets.
        case '▸', '▶', '►', '→', '›', '»', '⟩':
            return '>';
        case '◂', '◀', '◄', '←', '‹', '«', '⟨', '⏎':
            return '<';
        case '⇄', '↔':
            return '=';
        case '▾', '▼', '↓':
            return 'v';
        case '▴', '▲', '↑':
            return '^';
        case '·', '•', '∙', '▪', '■', '◆', '♦':
            return '*';
        case '▫', '□', '◇':
            return '.';
        case '—', '–', '‒', '―':
            return '-';
        case '…':
            return '~';
        case '✕', '×', '✗':
            return 'x';
        case '✓':
            return '+';
        case '●', '◉':
            return '@';
        case '○', '◌', '◯', '⊘':
            return 'o';
        default:
            break;
    }
    const n = needOf(g);
    if (n >= GlyphNeed.blocksQuadrant && n <= GlyphNeed.braille)
        return g == 0x2800 ? ' ' : '▒'; // blank braille is a blank cell
    return replacementGlyph;
}

/// `g` as a target declaring `caps` can show it: `g` itself when admitted,
/// else the first rung of its ladder that is.
dchar projectGlyph(dchar g, in TargetCapabilities caps)
{
    // Bounded: every rung is strictly weaker, and there are eight needs.
    foreach (_; 0 .. GlyphNeed.max + 2)
    {
        if (admits(caps, g))
            return g;
        g = fallbackOf(g);
    }
    assert(0, "a fallback ladder that never reached ASCII");
}

// ── status marks (GLY3, ACC3) ───────────────────────────────────────────────

/// One mark's glyph in each charset — a UDA on each $(LREF Mark) member.
struct markGlyphs
{
    dchar nerdFont; /// Nerd Font (Font Awesome range, stable across 3.x)
    dchar unicode;  /// plain Unicode
    dchar ascii;    /// the one-cell ASCII stand-in
}

/**
The status marks (`GLY3`): what a status is when color cannot say it
(`ACC3`). Every charset's form is one cell wide, so a column of marks does not
shift between a Nerd Font terminal and a pipe.
*/
enum Mark : ubyte
{
    @markGlyphs(Icon.faCheck, '✔', '+') ok,                 /// `fa-check`
    @markGlyphs(Icon.faXmark, '✖', 'x') fail,               /// `fa-xmark`
    @markGlyphs(Icon.faTriangleExclamation, '⚠', '!') warn, /// `fa-triangle_exclamation`
    @markGlyphs(Icon.faCircleInfo, '•', '*') info,          /// `fa-circle_info`
    @markGlyphs(Icon.faCircleO, '○', 'o') pending,          /// `fa-circle_o`
    @markGlyphs(Icon.faSpinner, '◐', '~') running,          /// `fa-spinner`
    @markGlyphs(Icon.faMinus, '┄', '.') skipped,            /// `fa-minus`
}


/// Each mark's glyphs, by ordinal — read from the members' UDAs, so the table
/// is spelled once, on the enum.
static immutable markGlyphs[] markTable = () {
    markGlyphs[] t;
    static foreach (m; EnumMembers!Mark)
        t ~= getUDAs!(m, markGlyphs)[0];
    return t;
}();

static foreach (i, m; EnumMembers!Mark)
    static assert(m == i, "Mark must stay a contiguous 0-based enum");

/// `m` in `preferred`, capped by what `caps` admits.
dchar markGlyph(Mark m, MarkCharset preferred, in TargetCapabilities caps)
{
    const mg = markTable[m];
    const g = preferred == MarkCharset.nerdFont ? mg.nerdFont
        : preferred == MarkCharset.unicode ? mg.unicode : mg.ascii;
    return projectGlyph(g, caps);
}

// ── action icons (GLY1, GLY4) ───────────────────────────────────────────────

/// One icon's glyph in each charset — the same three rungs as a mark's.
alias iconGlyphs = markGlyphs;

/**
The action icons buttons and menus name (`GLY1`): a Nerd Font icon, a
Unicode stand-in a target without Nerd Font icons draws instead, and a
one-cell ASCII stand-in below that, so an icon steps down its own ladder
rather than to $(LREF replacementGlyph). The `nf-*` names are those of the
Nerd Fonts release the flake pins (`GLY4`).
*/
enum ActionIcon : ubyte
{
    @iconGlyphs('', '↗', '^') share,             /// nf-fa-share_alt
    @iconGlyphs('', '⇗', '>') open,              /// nf-fa-folder_open_o
    @iconGlyphs('', '⧉', '=') copy,              /// nf-fa-copy
    @iconGlyphs('', '⎘', 'v') paste,             /// nf-fa-clipboard_alt
    @iconGlyphs('', '⌕', '/') search,            /// nf-fa-search
    @iconGlyphs('', '▶', '>') run,               /// nf-fa-play_circle_o
    @iconGlyphs('', '↻', 'r') rerun,             /// nf-fa-repeat
    @iconGlyphs('', '❯', '$') shell,             /// nf-cod-terminal
    @iconGlyphs('\U000F07F5', '⚿', '*') autofill,      /// nf-md-form_textbox_password
    @iconGlyphs('', '✔', '+') allowOnce,         /// nf-fa-check (`Mark.ok`'s)
    @iconGlyphs('', '∞', '&') alwaysAllow,       /// nf-fa-check_double
    @iconGlyphs('', '✕', 'x') deny,              /// nf-fa-ban
}

/// Each icon's glyphs, by ordinal, read from the members' UDAs.
static immutable iconGlyphs[] iconTable = () {
    iconGlyphs[] t;
    static foreach (i; EnumMembers!ActionIcon)
        t ~= getUDAs!(i, iconGlyphs)[0];
    return t;
}();

static foreach (n, i; EnumMembers!ActionIcon)
    static assert(i == n, "ActionIcon must stay a contiguous 0-based enum");

// Each icon's richest glyph as UTF-8, for a component's text.
private static immutable string[] iconStrings = () {
    import std.utf : encode;

    string[] t;
    foreach (ref ig; iconTable)
    {
        char[4] buf;
        t ~= buf[0 .. encode(buf, ig.nerdFont)].idup;
    }
    return t;
}();

/**
`i`'s richest glyph, as text: what a component asks for. A cell target caps
it at paint time ($(LREF projectGlyph)): the Unicode stand-in without Nerd
Font icons, the ASCII one without Unicode.
*/
string iconText(ActionIcon i) => iconStrings[i];

// ── tests ───────────────────────────────────────────────────────────────────

version (unittest)
{
    import sparkles.base.term_color : ColorDepth;
    import sparkles.base.text.width : codepointWidth;
    import sparkles.ui.tokens : capabilitiesOf, Profile;

    // The cell tables' own glyphs and every glyph this module names — the
    // vocabulary the exhaustive ladder test walks.
    private immutable dstring vocabulary =
        "─━│┃┄┅┆┇┈┉┊┋┌┍┎┏┐┑┒┓└┕┖┗┘┙┚┛├┝┠┣┤┥┨┫┬┯┰┳┴┷┸┻┼┿╂╋"
        ~ "╌╍╎╏═║╒╓╔╕╖╗╘╙╚╛╜╝╞╟╠╡╢╣╤╥╦╧╨╩╪╫╬╭╮╯╰╴╵╶╷╸╹╺╻"
        ~ "▀▁▂▃▄▅▆▇█▉▊▋▌▍▎▏▐░▒▓▔▕▖▗▘▙▚▛▜▝▞▟"
        ~ "\U0001FB00\U0001FB1E\U0001FB3B\U0001CD00\U0001CDE5⠀⠁⣿"
        ~ "▸▶►→›»⟩◂◀◄←‹«⟨⏎⇄↔▾▼↓▴▲↑·•∙▪■◆♦▫□◇—–‒―…✕×✗✓●◉○◌◯⊘✔✖⚠◐"
        ~ "\uF00C\uF00D\uF071\uF05A\uF10C\uF110\uF068\uE0B0\U000F0001"
        ~ "\uF1E0\uF115\uF0C5\uF07F\uF002\uF01D\uF01E\uEA85\U000F07F5\uEE29\uF05E"
        ~ "\u2197\u21D7\u29C9\u2398\u2315\u21BB\u276F\u26BF\u221E"
        ~ "日é€π";
}

@("ui.glyphs.needOf.byRange")
unittest
{
    assert(needOf('a') == GlyphNeed.ascii);
    assert(needOf('─') == GlyphNeed.unicode && needOf('╭') == GlyphNeed.unicode);
    assert(needOf('▏') == GlyphNeed.blocksHalf && needOf('█') == GlyphNeed.blocksHalf);
    assert(needOf('▚') == GlyphNeed.blocksQuadrant);
    assert(needOf('\U0001FB00') == GlyphNeed.blocksSextant);
    assert(needOf('\U0001CD00') == GlyphNeed.blocksOctant);
    assert(needOf('⣿') == GlyphNeed.braille);
    assert(needOf('\uE0B0') == GlyphNeed.nerdFont); // a powerline separator
    assert(needOf('日') == GlyphNeed.unicode);
}

@("ui.glyphs.ladder.everyRungIsOneCellAndWeaker")
unittest
{
    // `O7` for the glyph channel: exhaustive over the vocabulary. Each rung
    // is strictly weaker than the glyph it replaces and one cell wide, so no
    // ladder can loop and no fallback can shift a column.
    foreach (g; vocabulary)
    {
        const f = fallbackOf(g);
        assert(needOf(f) < needOf(g) || needOf(g) == GlyphNeed.ascii);
        assert(codepointWidth(f) == 1, "a rung must be one cell wide");
    }
}

@("ui.glyphs.projectGlyph.perProfile")
unittest
{
    const b = capabilitiesOf(Profile.baseline);
    const e = capabilitiesOf(Profile.enhanced);
    const f = capabilitiesOf(Profile.full);
    foreach (g; vocabulary)
    {
        // `GLY1`'s violation clause: nothing above the tier reaches the canvas.
        foreach (caps; [b, e, f])
            assert(admits(caps, projectGlyph(g, caps)));
        assert(projectGlyph(g, b) < 0x80, "baseline is ASCII, every glyph");
        if (admits(f, g))
            assert(projectGlyph(g, f) == g, "an admitted glyph is untouched");
    }
    assert(projectGlyph('╭', b) == '+' && projectGlyph('╭', e) == '╭');
    assert(projectGlyph('▏', e) == '▏', "enhanced has half blocks");
    assert(projectGlyph('▚', e) == '▒' && projectGlyph('▚', b) == ':');
    assert(projectGlyph('⣿', e) == '▒' && projectGlyph('⣿', f) == '⣿');
    assert(projectGlyph('\uF00C', e) == '✔' && projectGlyph('\uF00C', b) == '+');
    assert(projectGlyph('日', b) == replacementGlyph);

    TargetCapabilities noBlocks = e;
    noBlocks.blocks = BlockTier.none;
    assert(projectGlyph('▏', noBlocks) == '│' && projectGlyph('▌', noBlocks) == '┃');
    assert(projectGlyph('█', noBlocks) == '#');
}

@("ui.glyphs.marks.oneCellAndConsistentWithTheLadder")
unittest
{
    const b = capabilitiesOf(Profile.baseline);
    const e = capabilitiesOf(Profile.enhanced);
    const f = capabilitiesOf(Profile.full);
    static foreach (m; EnumMembers!Mark)
    {{
        enum mg = getUDAs!(m, markGlyphs)[0];
        // `GLY3`: one cell in every charset.
        assert(codepointWidth(mg.nerdFont) == 1 && codepointWidth(mg.unicode) == 1
            && mg.ascii < 0x80);
        // The ladder and the table agree, so a mark painted in its richest
        // form lands on the table's own form wherever the target caps it.
        assert(projectGlyph(mg.nerdFont, e) == mg.unicode);
        assert(projectGlyph(mg.nerdFont, b) == mg.ascii);
        assert(projectGlyph(mg.unicode, b) == mg.ascii);
        // A preference is a ceiling too: a theme asking for ASCII gets it.
        assert(markGlyph(m, MarkCharset.nerdFont, f) == mg.nerdFont);
        assert(markGlyph(m, MarkCharset.nerdFont, e) == mg.unicode);
        assert(markGlyph(m, MarkCharset.ascii, f) == mg.ascii);
    }}
    // `ACC3`: the marks are pairwise distinct in every charset, so a
    // monochrome status column still tells ok from fail.
    static foreach (i, a; EnumMembers!Mark)
        static foreach (j, c; EnumMembers!Mark)
            static if (i < j)
            {
                assert(markGlyph(a, MarkCharset.ascii, b) != markGlyph(c, MarkCharset.ascii, b));
                assert(markGlyph(a, MarkCharset.unicode, e) != markGlyph(c, MarkCharset.unicode, e));
            }
}

@("ui.glyphs.icons.oneCellAndConsistentWithTheLadder")
unittest
{
    const b = capabilitiesOf(Profile.baseline);
    const e = capabilitiesOf(Profile.enhanced);
    const f = capabilitiesOf(Profile.full);
    static foreach (i; EnumMembers!ActionIcon)
    {{
        enum ig = getUDAs!(i, iconGlyphs)[0];
        // One cell in every charset, as a mark is, so a button's width does
        // not change with the target.
        assert(codepointWidth(ig.nerdFont) == 1 && codepointWidth(ig.unicode) == 1
            && ig.ascii < 0x80);
        assert(needOf(ig.nerdFont) == GlyphNeed.nerdFont);
        // The icon's own ladder, not the `?` an unknown icon falls to.
        assert(projectGlyph(ig.nerdFont, f) == ig.nerdFont);
        assert(projectGlyph(ig.nerdFont, e) == ig.unicode);
        assert(projectGlyph(ig.nerdFont, b) == ig.ascii);
    }}
}

@("ui.glyphs.iconText.theRichestGlyph")
@safe pure nothrow @nogc
unittest
{
    assert(iconText(ActionIcon.share) == "");
    assert(iconText(ActionIcon.autofill) == "\U000F07F5", "a code point beyond the BMP");
}
