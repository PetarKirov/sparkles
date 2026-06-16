/**
 * Display (terminal cell) width of code points and grapheme clusters.
 *
 * Width follows the modern terminal consensus (kitty / wezterm / Ghostty), not
 * legacy `wcwidth`: East-Asian Wide/Fullwidth (UAX #11) gives 2, combining /
 * format / control give 0, everything else 1, with UTS #51 emoji-presentation
 * handled per grapheme cluster (VS16 promotes an emoji base to 2, VS15 forces 1,
 * an emoji modifier widens its base). Ambiguous width defaults to 1.
 *
 * The crucial rule: `codepointWidth` is the width of a code point *in isolation*
 * and must NOT be summed across a cluster -- a flag (two regional indicators), a
 * ZWJ sequence, or base+VS16 each occupy one 2-cell cluster, which summation
 * would over-count. Use `graphemeClusterWidth` (or `visibleWidth`, in
 * `sparkles.base.text.grapheme`) for strings.
 *
 * The East-Asian-Width and emoji-VS-base tables live in the generated
 * `sparkles.base.text.unicode_tables`; the zero-width set is built from
 * `std.uni`'s `Mn | Me | Cf` plus the few conjoining ranges Phobos's categories
 * miss. Pinned to Unicode 17.0 (see the generator).
 */
module sparkles.base.text.width;

import std.uni : CodepointSet, isControl, unicode;

import sparkles.base.text.unicode_tables : isEastAsianWide, isEmojiVsBase;

/// Variation selectors that switch emoji vs text presentation (UTS #51).
private enum dchar vs15 = '\uFE0E'; // text presentation
private enum dchar vs16 = '\uFE0F'; // emoji presentation

/// Line / paragraph separators (general category Zl / Zp).
private enum dchar lineSeparator = '\u2028';
private enum dchar paragraphSeparator = '\u2029';

/// Zero-width code points: `Mn | Me | Cf` plus conjoining / format ranges that
/// fall outside those general categories. Built once at compile time; `[cp]`
/// membership is `@safe pure nothrow @nogc`.
private immutable CodepointSet zeroWidthSet = makeZeroWidthSet();

private CodepointSet makeZeroWidthSet() @safe pure
{
    auto s = unicode.Mn | unicode.Me | unicode.Cf;
    s.add(0x1160, 0x1200);   // Hangul Jamo medial + final (compose onto the lead)
    s.add(0x1BCA0, 0x1BCA4); // Shorthand Format Controls
    s.add(0x13430, 0x13440); // Egyptian Hieroglyph Format Controls
    s.add(0xE0000, 0xE0080); // Tags
    return s;
}

/// Display width of one code point **in isolation**: 0 for control / combining /
/// format / zero-width, 2 for East-Asian Wide/Fullwidth, otherwise 1 (ambiguous
/// defaults to narrow). Not valid to sum across a grapheme cluster -- see
/// `graphemeClusterWidth`.
int codepointWidth(dchar cp) @safe pure nothrow @nogc
{
    if (cp == 0)
        return 0;
    if (isControl(cp))               // C0/C1 controls (incl. tab, newline)
        return 0;
    if (cp == lineSeparator || cp == paragraphSeparator)
        return 0;
    if (zeroWidthSet[cp])
        return 0;
    if (isEastAsianWide(cp))
        return 2;
    return 1;
}

@("width.codepointWidth.basics")
@safe pure nothrow @nogc unittest
{
    assert(codepointWidth('A') == 1);
    assert(codepointWidth('\u4E16') == 2);   // CJK ideograph (Wide)
    assert(codepointWidth('\uFF21') == 2);   // Fullwidth Latin A
    assert(codepointWidth('\u0301') == 0);   // combining acute (Mn)
    assert(codepointWidth('\u0903') == 1);   // Devanagari sign visarga (Mc, spacing!)
    assert(codepointWidth('\u200B') == 0);   // zero-width space (Cf)
    assert(codepointWidth('\u2029') == 0);   // paragraph separator (Zp)
    assert(codepointWidth('\t') == 0);       // control (tab)
    assert(codepointWidth('\u1160') == 0);   // Hangul Jamo medial (conjoining)
}

/// Display width of a whole grapheme cluster (a single UAX #29 cluster as a slice
/// of code points). Folds emoji presentation: VS16 promotes an emoji-VS base to
/// 2, VS15 forces 1, and any non-VS spacing member (e.g. an emoji modifier)
/// widens the cluster to 2. Clamped to `[0, 2]`.
int graphemeClusterWidth(in dchar[] cluster) @safe pure nothrow @nogc
{
    if (cluster.length == 0)
        return 0;

    int w = codepointWidth(cluster[0]);
    foreach (cp; cluster[1 .. $])
    {
        if (cp == vs16)
        {
            if (isEmojiVsBase(cluster[0]))
                w = 2;
        }
        else if (cp == vs15)
            w = 1;
        else if (codepointWidth(cp) > 0) // a spacing in-cluster member -> wide
            w = 2;
    }
    return w > 2 ? 2 : w; // clamp (e.g. the rare width-3 dash)
}

@("width.graphemeClusterWidth.combining")
@safe pure nothrow @nogc unittest
{
    assert(graphemeClusterWidth("A\u0301"d) == 1); // 'A' + combining acute
    assert(graphemeClusterWidth("\u4E16"d) == 2);  // CJK
    assert(graphemeClusterWidth(""d) == 0);
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
