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
the ladder by test.
*/
module sparkles.ui.glyphs;

import std.traits : EnumMembers, getUDAs;

import sparkles.base.term_caps : BlockTier;
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
and bullets have ASCII look-alikes; anything else — an icon with no mark, a
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
    @markGlyphs('\uF00C', '✔', '+') ok,      /// nf-fa-check
    @markGlyphs('\uF00D', '✖', 'x') fail,    /// nf-fa-xmark
    @markGlyphs('\uF071', '⚠', '!') warn,    /// nf-fa-triangle_exclamation
    @markGlyphs('\uF05A', '•', '*') info,    /// nf-fa-circle_info
    @markGlyphs('\uF10C', '○', 'o') pending, /// nf-fa-circle (outline)
    @markGlyphs('\uF110', '◐', '~') running, /// nf-fa-spinner
    @markGlyphs('\uF068', '┄', '.') skipped, /// nf-fa-minus
}

/// Which charset a theme prefers its marks in (`GLY1`); the target caps it.
enum MarkCharset : ubyte
{
    ascii,    /// `+ x ! * o ~ .`
    unicode,  /// `✔ ✖ ⚠ • ○ ◐ ┄`
    nerdFont, /// the Font Awesome icons
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
