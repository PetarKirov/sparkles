/**
 * Clean-room width oracle.
 *
 * Re-implements the kitty Text Sizing Protocol width classes from the spec
 * prose (see `docs/specs/base/text/index.md` §5–§7), driven entirely by raw
 * UCD data (`WidthData`) — it does **not** import `sparkles.base.text.width`,
 * nor does it consult Phobos `std.uni` for general categories. That
 * independence is the whole point of Layer 1: a shared bug or a Phobos-vs-UCD
 * version skew shows up as a divergence instead of cancelling out.
 *
 * Honest limitation: the regional-indicator range, the noncharacter formula,
 * and the four conjoining/format ranges are *spec constants*, not UCD-derived
 * properties. Both this oracle and `width.d` encode the same literals, so
 * Layer 1 asserts them rather than differentially testing them. What it does
 * differentially test is the data-driven East-Asian-Width and general-category
 * classes.
 */
module sparkles.text_conformance.oracle;

import sparkles.text_conformance.ucd : WidthData;

/// Variation selectors (UTS #51) and the line/paragraph separators (Zl / Zp).
private enum dchar vs15 = cast(dchar) 0xFE0E;            // text presentation
private enum dchar vs16 = cast(dchar) 0xFE0F;            // emoji presentation
private enum dchar lineSeparator = cast(dchar) 0x2028;
private enum dchar paragraphSeparator = cast(dchar) 0x2029;

/// Conjoining / format ranges that fall outside `Mn|Mc|Me|Cf` but are still
/// zero-width. Copied verbatim from `width.d`'s `makeZeroWidthSet` — a shared
/// spec constant (see module note).
private bool inConjoiningRange(dchar cp) pure nothrow @safe @nogc
    => (cp >= 0x1160 && cp < 0x1200)     // Hangul Jamo medial + final
    || (cp >= 0x1BCA0 && cp < 0x1BCA4)   // Shorthand Format Controls
    || (cp >= 0x13430 && cp < 0x13440)   // Egyptian Hieroglyph Format Controls
    || (cp >= 0xE0000 && cp < 0xE0080);  // Tags

private bool isRegionalIndicator(dchar cp) pure nothrow @safe @nogc
    => cp >= 0x1F1E6 && cp <= 0x1F1FF;

private bool isNoncharacter(dchar cp) pure nothrow @safe @nogc
    => (cp >= 0xFDD0 && cp <= 0xFDEF) || (cp & 0xFFFE) == 0xFFFE;

/// Independent display width of one code point in isolation, by the kitty width
/// classes in decreasing priority. Mirrors `width.d`'s `codepointWidth` order,
/// but every data-driven test is answered from `d` (raw UCD), not `std.uni`.
int oracleCodepointWidth(dchar cp, in WidthData d) @safe nothrow
{
    if (cp == 0)
        return 0;                       // NUL
    if (d.controls[cp])
        return 0;                       // Cc controls (= std.uni.isControl coverage)
    if (cp == lineSeparator || cp == paragraphSeparator)
        return 0;                       // Zl / Zp
    if (isNoncharacter(cp))
        return 0;
    if (isRegionalIndicator(cp))
        return 2;                       // flag half (EAW-neutral, but width 2)
    if (d.zeroCat[cp] || inConjoiningRange(cp))
        return 0;                       // Mn | Mc | Me | Cf + conjoining ranges
    if (d.wide[cp])
        return 2;                       // East-Asian Wide / Fullwidth
    return 1;
}

/// Independent display width of a grapheme cluster: the leading code point's
/// width, with VS16 promoting an emoji-VS base to 2 and VS15 demoting it to 1.
int oracleClusterWidth(const(dchar)[] cluster, in WidthData d) @safe nothrow
{
    if (cluster.length == 0)
        return 0;

    int w = oracleCodepointWidth(cluster[0], d);
    foreach (cp; cluster[1 .. $])
    {
        if (cp == vs16 && d.emojiVsBase[cluster[0]])
            w = 2;
        else if (cp == vs15 && d.emojiVsBase[cluster[0]])
            w = 1;
    }
    return w;
}

@("oracle.codepointWidth.branches")
@safe unittest
{
    // Synthetic UCD data exercising each branch without touching the network.
    WidthData d;
    d.controls.add(0x00, 0x20);          // C0 controls
    d.wide.add(0x4E00, 0x4E01);          // one CJK ideograph
    d.zeroCat.add(0x0301, 0x0302);       // combining acute (a Mark)
    d.emojiVsBase.add(0x2764, 0x2765);   // heart is an emoji-VS base

    assert(oracleCodepointWidth('A', d) == 1);                     // default
    assert(oracleCodepointWidth(cast(dchar) 0x4E00, d) == 2);      // EAW wide
    assert(oracleCodepointWidth(cast(dchar) 0x0301, d) == 0);      // mark
    assert(oracleCodepointWidth(cast(dchar) 0x09, d) == 0);        // control (tab)
    assert(oracleCodepointWidth(cast(dchar) 0x2028, d) == 0);      // line separator
    assert(oracleCodepointWidth(cast(dchar) 0x1F1FA, d) == 2);     // regional indicator
    assert(oracleCodepointWidth(cast(dchar) 0xFDD0, d) == 0);      // noncharacter
    assert(oracleCodepointWidth(cast(dchar) 0xFFFE, d) == 0);      // plane noncharacter
    assert(oracleCodepointWidth(cast(dchar) 0x1160, d) == 0);      // conjoining range
}

@("oracle.clusterWidth.variationSelectors")
@safe unittest
{
    WidthData d;
    d.emojiVsBase.add(0x2764, 0x2765); // heart

    auto heart      = [cast(dchar) 0x2764];
    auto heartVs16  = [cast(dchar) 0x2764, cast(dchar) 0xFE0F];
    auto heartVs15  = [cast(dchar) 0x2764, cast(dchar) 0xFE0E];
    auto aVs16      = [cast(dchar) 0x0041, cast(dchar) 0xFE0F]; // 'A' not an emoji base

    assert(oracleClusterWidth(heart, d) == 1);     // bare (ambiguous → narrow)
    assert(oracleClusterWidth(heartVs16, d) == 2); // VS16 promotes
    assert(oracleClusterWidth(heartVs15, d) == 1); // VS15 demotes
    assert(oracleClusterWidth(aVs16, d) == 1);     // gated: 'A' not a VS base
}
