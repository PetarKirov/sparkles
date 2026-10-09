/**
Terminal-cell measurements under the named `terminalKitty` revision-1 profile.

The profile assigns the leading scalar's width to an extended grapheme and
applies its last eligible VS15/VS16 presentation selector. Unicode properties
come exclusively from the manifest-identified generated tables. This is a local
measurement policy, not a claim about every terminal or a replacement for a
VT engine's actual grid. Cells are not typographic lengths.
*/
module sparkles.base.text.width;

import sparkles.base.text.unicode_tables : GeneralCategory, generalCategory,
    isEastAsianWide, isEmojiVsBase;

/// Named cached cell geometry. `none` deliberately has no cell coordinates.
enum CellPolicy : ubyte { none, terminalKitty }

/// Revision of the only implemented terminal-cell policy.
enum uint terminalKittyRevision = 1;

/// Variation selectors that switch emoji vs text presentation (UTS #51).
private enum dchar vs15 = '\uFE0E'; // text presentation
private enum dchar vs16 = '\uFE0F'; // emoji presentation

/// Regional indicators (flag halves): `U+1F1E6`..`U+1F1FF`. EAW marks them
/// neutral, but kitty's algorithm gives each width 2.
private enum dchar regionalIndicatorFirst = '\U0001F1E6';
private enum dchar regionalIndicatorLast = '\U0001F1FF';

private bool isRegionalIndicator(dchar cp) @safe pure nothrow @nogc
    => cp >= regionalIndicatorFirst && cp <= regionalIndicatorLast;

/// Unicode noncharacters: `U+FDD0`..`U+FDEF` and the last two code points of
/// every plane (`U+xxFFFE`, `U+xxFFFF`). kitty discards these (width 0).
private bool isNoncharacter(dchar cp) @safe pure nothrow @nogc
    => (cp >= 0xFDD0 && cp <= 0xFDEF) || (cp & 0xFFFE) == 0xFFFE;


/// Display width of one code point **in isolation**, by the kitty width classes
/// in decreasing priority: 2 for a regional indicator (flag half); 0 for a
/// noncharacter, control, line/paragraph separator, or zero-width code point
/// (`Mn | Mc | Me | Cf` + conjoining ranges); 2 for East-Asian Wide/Fullwidth
/// (which also covers emoji-presentation bases and skin-tone modifiers);
/// otherwise 1 (ambiguous defaults to narrow). Not valid to sum across a grapheme
/// cluster -- see `graphemeClusterWidth`.
int codepointWidth(dchar cp) @safe pure nothrow @nogc
in (cp <= 0x10FFFF && (cp < 0xD800 || cp > 0xDFFF),
    "Cell width requires a Unicode scalar")
{
    if (cp < 0x80)
        return cp >= 0x20 && cp < 0x7F ? 1 : 0;
    if (isRegionalIndicator(cp))
        return 2;
    if (isNoncharacter(cp) || (cp >= 0x1160 && cp < 0x1200)
        || (cp >= 0x1BCA0 && cp < 0x1BCA4)
        || (cp >= 0x13430 && cp < 0x13440)
        || (cp >= 0xE0000 && cp < 0xE0080))
        return 0;
    const category = generalCategory(cp);
    if (category == GeneralCategory.Cc || category == GeneralCategory.Zl
        || category == GeneralCategory.Zp || category == GeneralCategory.Mn
        || category == GeneralCategory.Mc || category == GeneralCategory.Me
        || category == GeneralCategory.Cf)
        return 0;
    return isEastAsianWide(cp) ? 2 : 1;
}


@("width.codepointWidth.basics")
@safe pure nothrow @nogc unittest
{
    assert(codepointWidth('A') == 1);
    assert(codepointWidth('\u4E16') == 2);   // CJK ideograph (Wide)
    assert(codepointWidth('\uFF21') == 2);   // Fullwidth Latin A
    assert(codepointWidth('\u0301') == 0);   // combining acute (Mn)
    assert(codepointWidth('\u0903') == 0);   // Devanagari sign visarga (Mc -> 0)
    assert(codepointWidth('\u093E') == 0);   // Devanagari vowel sign AA (Mc -> 0)
    assert(codepointWidth('\u200B') == 0);   // zero-width space (Cf)
    assert(codepointWidth('\u2029') == 0);   // paragraph separator (Zp)
    assert(codepointWidth('\t') == 0);       // control (tab)
    assert(codepointWidth('\u1160') == 0);   // Hangul Jamo medial (conjoining)
    assert(codepointWidth('\U0001F1FA') == 2); // regional indicator (flag half)
    assert(codepointWidth('\uFDD0') == 0);   // noncharacter
    assert(codepointWidth('\uFFFF') == 0);   // plane-0 noncharacter
}

// Shared by scalar-array measurement and the borrowed UTF-8 scanner. Only
// presentation state is retained; a long cluster never needs a copied array.
package(sparkles) struct ClusterWidthState
{
    dchar first = 0;
    int width;
    size_t unclustered;
    size_t codepoints;
    private bool _emojiBase;

    void push(dchar scalar, bool metadata = true) scope @safe pure nothrow @nogc
    {
        const standalone = codepoints == 0 || metadata ? codepointWidth(scalar) : 0;
        if (codepoints == 0)
        {
            first = scalar;
            width = standalone;
            _emojiBase = isEmojiVsBase(scalar);
        }
        else if (_emojiBase && scalar == vs16)
            width = 2;
        else if (_emojiBase && scalar == vs15)
            width = 1;
        if (metadata)
            unclustered += isRegionalIndicator(scalar) ? 1 : standalone;
        ++codepoints;
    }
}

/// Display width of a whole grapheme cluster (a single UAX #29 cluster as a slice
/// of code points). The cluster occupies one cell whose width is that of its
/// **leading** code point, adjusted only by the variation selectors: VS16
/// promotes an emoji-VS base to 2, VS15 demotes one to 1. Combining members never
/// add width (a flag's second regional indicator, an emoji modifier, and ordinary
/// combining marks all leave the leading width unchanged).
int graphemeClusterWidth(in dchar[] cluster) @safe pure nothrow @nogc
{
    ClusterWidthState state;
    foreach (scalar; cluster)
        state.push(scalar, false);
    return state.width;
}

@("width.graphemeClusterWidth.combining")
@safe pure nothrow @nogc unittest
{
    assert(graphemeClusterWidth("A\u0301"d) == 1); // 'A' + combining acute
    assert(graphemeClusterWidth("\u4E16"d) == 2);  // CJK
    assert(graphemeClusterWidth(""d) == 0);
    // Brahmic syllable: base + spacing vowel sign (Mc) stays one 1-cell cluster.
    assert(graphemeClusterWidth("\u0915\u093E"d) == 1); // \u0915 + \u093E
    assert(graphemeClusterWidth("\u0915\u0940"d) == 1); // \u0915\u0940
}

@("width.graphemeClusterWidth.emoji")
@safe pure nothrow @nogc unittest
{
    assert(graphemeClusterWidth("\u2764\uFE0F"d) == 2); // heart + VS16 -> wide
    assert(graphemeClusterWidth("\u2764"d) == 1);          // heart bare (ambiguous -> narrow)
    assert(graphemeClusterWidth("A\uFE0F"d) == 1);         // VS16 gated: 'A' not emoji base
    assert(graphemeClusterWidth("\u2764\uFE0E"d) == 1); // VS15 forces text width
}

@("width.graphemeClusterWidth.sequences")
@safe pure nothrow @nogc unittest
{
    // Flag: two regional indicators -> one 2-cell cluster (US flag).
    assert(graphemeClusterWidth("\U0001F1FA\U0001F1F8"d) == 2);
    // Emoji + skin-tone modifier -> 2 (thumbs up + type-5).
    assert(graphemeClusterWidth("\U0001F44D\U0001F3FE"d) == 2);
    // ZWJ family sequence -> 2 (woman + ZWJ + girl).
    assert(graphemeClusterWidth("\U0001F469\u200D\U0001F467"d) == 2);
}

/**
Cells a terminal that does $(B not) cluster advances for `cluster`: each code
point by its own width, as a per-code-point `wcwidth` has it — a regional
indicator narrow, a joiner or variation selector nothing. Where this differs
from $(LREF graphemeClusterWidth), such a terminal draws the cluster wider or
narrower than the cell the grid gave it, and every later cell on the row
moves: XTerm lays a ZWJ family out in 6 cells, not 2, and a heart with VS16
in 1 (measured by cursor report, as the capability probe does).
*/
size_t unclusteredWidth(in dchar[] cluster) @safe pure nothrow @nogc
{
    size_t width;
    foreach (scalar; cluster)
        width += isRegionalIndicator(scalar) ? 1 : codepointWidth(scalar);
    return width;
}

@("width.unclusteredWidth.measured")
@safe pure nothrow @nogc unittest
{
    // XTerm's cursor reports: where a cluster keeps its cell, and where not.
    assert(unclusteredWidth("\U0001F468\u200D\U0001F469\u200D\U0001F467"d) == 6);
    assert(unclusteredWidth("\u2764\uFE0F"d) == 1);
    assert(unclusteredWidth("\U0001F1FA\U0001F1F8"d) == 2);
    assert(unclusteredWidth("A\u0301"d) == 1);
    // Those that keep it need no clustering.
    assert(unclusteredWidth("\U0001F1FA\U0001F1F8"d) == graphemeClusterWidth("\U0001F1FA\U0001F1F8"d));
    assert(unclusteredWidth("A\u0301"d) == graphemeClusterWidth("A\u0301"d));
}

/// Horizontal alignment of text within a fixed-width field. `inherit` means "defer
/// to a caller-supplied default" (e.g. a table column's default alignment) and is
/// treated as `left` if it reaches `alignField` unresolved. `decimal` aligns a
/// *column* of numbers on their last `.` — inherently columnar (a lone field has
/// no shared dot position), so `alignField` treats it as `right`; the columnar
/// pad is applied by the consumer (see `drawTable`'s per-column handling).
enum Align { inherit, left, center, right, decimal }

/// Pad `content` to `width` visible columns into the output range `w`, per `align_`.
///
/// The pad amount is `width - visibleWidth(content)` (clamped at 0), distributed by
/// `align_`: `left`/`inherit` put it after the content, `right` before, `center`
/// splits it (floor left, remainder right). Padding is measured in terminal cells via
/// `visibleWidth`, so ANSI escapes cost nothing and CJK/emoji clusters count 2 \u2014
/// styled content aligns by what the reader sees. Content already at or wider than
/// `width` is emitted unpadded (never truncated). Only the pad is added; the content
/// bytes pass through verbatim. Attributes infer from `Writer`.
ref Writer alignField(Writer)(
    return ref Writer w, scope const(char)[] content, size_t width, Align align_)
{
    import std.range.primitives : put;
    import sparkles.base.text.grapheme : visibleWidth;

    const vw = visibleWidth(content);
    const pad = width > vw ? width - vw : 0;

    size_t lead, trail;
    final switch (align_)
    {
        case Align.inherit:
        case Align.left:    trail = pad;                        break;
        case Align.right:
        case Align.decimal: lead = pad;                         break;
        case Align.center:  lead = pad / 2; trail = pad - lead; break;
    }

    foreach (_; 0 .. lead)
        put(w, ' ');
    put(w, content);
    foreach (_; 0 .. trail)
        put(w, ' ');
    return w;
}

@("width.alignField.horizontal")
@safe pure nothrow @nogc unittest
{
    import sparkles.base.buffer : SharedBuffer;

    SharedBuffer!(char, 64) b;
    alignField(b, "hi", 5, Align.left);
    assert(b[] == "hi   ");

    b.clear();
    alignField(b, "hi", 5, Align.right);
    assert(b[] == "   hi");

    b.clear();
    alignField(b, "hi", 5, Align.center); // pad 3 -> 1 left, 2 right
    assert(b[] == " hi  ");

    b.clear();
    alignField(b, "hi", 6, Align.center); // pad 4 -> 2 left, 2 right
    assert(b[] == "  hi  ");

    b.clear();
    alignField(b, "hi", 5, Align.inherit); // inherit == left
    assert(b[] == "hi   ");
}

@("width.alignField.zeroPadAndOverflow")
@safe pure nothrow @nogc unittest
{
    import sparkles.base.buffer : SharedBuffer;

    SharedBuffer!(char, 64) b;
    alignField(b, "hello", 5, Align.center); // already exact -> no pad
    assert(b[] == "hello");

    b.clear();
    alignField(b, "toolong", 3, Align.right); // wider than field -> verbatim, no truncation
    assert(b[] == "toolong");
}

@("width.alignField.styledAndWide")
@safe pure nothrow @nogc unittest
{
    import sparkles.base.buffer : SharedBuffer;

    // ANSI escapes cost nothing: "OK" is 2 visible cells, padded to 5.
    SharedBuffer!(char, 64) b;
    alignField(b, "\x1b[32mOK\x1b[39m", 5, Align.left);
    assert(b[] == "\x1b[32mOK\x1b[39m   ");

    // A CJK ideograph is 2 cells wide, so width-5 leaves 3 pad.
    b.clear();
    alignField(b, "\u4E16", 5, Align.right);
    assert(b[] == "   \u4E16");
}

@("width.alignField.stringFormMatchesRange")
@safe unittest
{
    import sparkles.base.buffer : SharedBuffer;

    foreach (a; [Align.left, Align.center, Align.right, Align.inherit])
    {
        SharedBuffer!(char, 64) b;
        alignField(b, "abc", 7, a);
        assert(b[].length == 7);
    }
}

/// Truncate `content` to at most `width` visible columns into the output range
/// `w`, ending in `ellipsis` (default `…`, 1 cell) when truncation occurs — the
/// companion of `alignField`, which pads and never cuts.
///
/// Content at or under `width` passes through verbatim. Otherwise the longest
/// grapheme-cluster prefix that leaves room for the ellipsis is emitted, any
/// open SGR style is reset (`\x1b[0m`) before the ellipsis so color cannot
/// bleed past it, and the ellipsis follows. Widths are terminal cells via the
/// grapheme segmenter, so ANSI escapes cost nothing and CJK/emoji clusters
/// count 2; a cluster is never split. When `width` is smaller than the
/// ellipsis itself, a bare prefix of `width` cells is emitted (the `<= width`
/// invariant always holds). Attributes infer from `Writer`.
ref Writer truncateField(Writer)(
    return ref Writer w, scope const(char)[] content, size_t width,
    scope const(char)[] ellipsis = "…")
{
    import std.range.primitives : put;
    import sparkles.base.text.grapheme : fitCells, visibleWidth;

    if (visibleWidth(content) <= width)
    {
        put(w, content);
        return w;
    }

    const ellipsisWidth = visibleWidth(ellipsis);
    const withEllipsis = width >= ellipsisWidth;
    const budget = withEllipsis ? width - ellipsisWidth : width;

    const fitted = fitCells(content, budget);
    const prefix = content[0 .. fitted.bytes];
    put(w, prefix);
    bool sawEscape;
    foreach (i; 0 .. prefix.length)
        if (prefix[i] == '\x1b')
        {
            sawEscape = true;
            break;
        }
    if (sawEscape)
        put(w, "\x1b[0m"); // reset before the ellipsis: no style bleed past the cut
    if (withEllipsis)
        put(w, ellipsis);
    return w;
}

@("width.truncateField.stylesCannotSplitClusterBudget")
@safe pure nothrow @nogc unittest
{
    import sparkles.base.buffer : checkWriter;
    checkWriter!((ref w) => truncateField(w, "\u2764\x1b[31m\uFE0FX", 2))("…");
    checkWriter!((ref w) => truncateField(w, "\U0001F1FA\x1b[31m\U0001F1F8X", 2))("…");
    checkWriter!((ref w) => truncateField(w, "1\x1b[31m\uFE0F\u20E3X", 2))("…");
}

@("width.truncateField.basic")
@safe pure nothrow @nogc unittest
{
    import sparkles.base.buffer : SharedBuffer;

    SharedBuffer!(char, 64) b;
    truncateField(b, "hello", 10); // fits -> verbatim, no ellipsis
    assert(b[] == "hello");

    b.clear();
    truncateField(b, "hello world", 8); // 7 cells + '…'
    assert(b[] == "hello w…");

    b.clear();
    truncateField(b, "hello", 5); // exact fit -> verbatim
    assert(b[] == "hello");
}

@("width.truncateField.tinyWidths")
@safe pure nothrow @nogc unittest
{
    import sparkles.base.buffer : SharedBuffer;

    SharedBuffer!(char, 64) b;
    truncateField(b, "hello", 1); // just the ellipsis
    assert(b[] == "…");

    b.clear();
    truncateField(b, "hello", 0); // narrower than the ellipsis -> bare cut
    assert(b[] == "");
}

@("width.truncateField.wideClustersNeverSplit")
@safe pure nothrow @nogc unittest
{
    import sparkles.base.buffer : SharedBuffer;
    import sparkles.base.text.grapheme : visibleWidth;

    // "世界" is 2+2 cells; width 4 leaves budget 3 -> only one ideograph fits
    // (a wide cluster is never split), so the result is 3 cells, not 4.
    SharedBuffer!(char, 64) b;
    truncateField(b, "世界丂", 4);
    assert(b[] == "世…");
    assert(visibleWidth(b[]) == 3);
}

@("width.truncateField.styledNoBleed")
@safe pure nothrow @nogc unittest
{
    import sparkles.base.buffer : SharedBuffer;

    // The kept prefix contains an opening SGR -> a reset precedes the ellipsis.
    SharedBuffer!(char, 64) b;
    truncateField(b, "\x1b[31mred red red\x1b[39m", 6);
    assert(b[] == "\x1b[31mred r\x1b[0m…");
}

@("width.truncateField.customEllipsis")
@safe unittest
{
    import sparkles.base.buffer : checkWriter;

    checkWriter!((ref b) => truncateField(b, "hello world", 8, "..."))("hello...");
    checkWriter!((ref b) => truncateField(b, "hello", 8, "..."))("hello");
}
