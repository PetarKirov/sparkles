/**
 * Display (terminal cell) width of code points and grapheme clusters.
 *
 * Width follows the [kitty Text Sizing Protocol](https://sw.kovidgoyal.net/kitty/text-sizing-protocol/)
 * (the modern terminal consensus; see `docs/specs/base/text/`), not legacy
 * `wcwidth`. `codepointWidth` assigns, in decreasing priority: regional
 * indicators 2 (EAW marks them neutral, but a flag half is 2); noncharacters and
 * controls 0; all Marks (`Mn | Mc | Me`) and `Cf` 0; East-Asian Wide/Fullwidth
 * (UAX #11) 2 (this also covers emoji-presentation bases and skin-tone
 * modifiers); everything else (incl. ambiguous) 1.
 *
 * The crucial rule: `codepointWidth` is the width of a code point *in isolation*
 * and must NOT be summed across a cluster. A grapheme cluster occupies one cell
 * whose width is that of its **leading** code point, adjusted only by the UTS #51
 * variation selectors (VS16 promotes an emoji base to 2, VS15 demotes it to 1);
 * combining members never add width. So a flag (two regional indicators), a ZWJ
 * sequence, or base+VS16 each occupy one cell. Use `graphemeClusterWidth` (or
 * `visibleWidth`, in `sparkles.base.text.grapheme`) for strings.
 *
 * The East-Asian-Width and emoji-VS-base tables live in the generated
 * `sparkles.base.text.unicode_tables`; the zero-width set is built from
 * `std.uni`'s `Mn | Mc | Me | Cf` plus the few conjoining ranges Phobos's
 * categories miss. Pinned to Unicode 17.0 (see the generator).
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

/// Zero-width code points: all Marks `Mn | Mc | Me` plus `Cf`, and conjoining /
/// format ranges that fall outside those general categories. Built once at
/// compile time; `[cp]` membership is `@safe pure nothrow @nogc`.
private immutable CodepointSet zeroWidthSet = makeZeroWidthSet();

private CodepointSet makeZeroWidthSet() @safe pure
{
    auto s = unicode.Mn | unicode.Mc | unicode.Me | unicode.Cf;
    s.add(0x1160, 0x1200);   // Hangul Jamo medial + final (compose onto the lead)
    s.add(0x1BCA0, 0x1BCA4); // Shorthand Format Controls
    s.add(0x13430, 0x13440); // Egyptian Hieroglyph Format Controls
    s.add(0xE0000, 0xE0080); // Tags
    return s;
}

/// Display width of one code point **in isolation**, by the kitty width classes
/// in decreasing priority: 2 for a regional indicator (flag half); 0 for a
/// noncharacter, control, line/paragraph separator, or zero-width code point
/// (`Mn | Mc | Me | Cf` + conjoining ranges); 2 for East-Asian Wide/Fullwidth
/// (which also covers emoji-presentation bases and skin-tone modifiers);
/// otherwise 1 (ambiguous defaults to narrow). Not valid to sum across a grapheme
/// cluster -- see `graphemeClusterWidth`.
int codepointWidth(dchar cp) @safe pure nothrow @nogc
{
    if (cp == 0)
        return 0;
    if (isControl(cp))               // C0/C1 controls (incl. tab, newline)
        return 0;
    if (cp == lineSeparator || cp == paragraphSeparator)
        return 0;
    if (isNoncharacter(cp))          // U+FDD0..FDEF and U+xxFFFE/xxFFFF: discarded
        return 0;
    if (isRegionalIndicator(cp))     // flag half: EAW-neutral but width 2
        return 2;
    if (zeroWidthSet[cp])            // Mn | Mc | Me | Cf + conjoining/format ranges
        return 0;
    if (isEastAsianWide(cp))         // UAX #11 Wide/Fullwidth (incl. emoji modifiers)
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

/// Display width of a whole grapheme cluster (a single UAX #29 cluster as a slice
/// of code points). The cluster occupies one cell whose width is that of its
/// **leading** code point, adjusted only by the variation selectors: VS16
/// promotes an emoji-VS base to 2, VS15 demotes one to 1. Combining members never
/// add width (a flag's second regional indicator, an emoji modifier, and ordinary
/// combining marks all leave the leading width unchanged).
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
        {
            if (isEmojiVsBase(cluster[0]))
                w = 1;
        }
    }
    return w; // codepointWidth and the VS rules only ever yield 0, 1, or 2
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

/// Horizontal alignment of text within a fixed-width field. `inherit` means "defer
/// to a caller-supplied default" (e.g. a table column's default alignment) and is
/// treated as `left` if it reaches `alignField` unresolved.
enum Align { inherit, left, center, right }

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
        case Align.left:   trail = pad;                        break;
        case Align.right:  lead = pad;                         break;
        case Align.center: lead = pad / 2; trail = pad - lead; break;
    }

    foreach (_; 0 .. lead)
        put(w, ' ');
    put(w, content);
    foreach (_; 0 .. trail)
        put(w, ' ');
    return w;
}

/// Convenience overload returning a freshly GC-allocated `string`. Prefer the
/// output-range form in `@nogc` code.
string alignField(scope const(char)[] content, size_t width, Align align_) @safe
{
    import std.array : appender;

    auto w = appender!string;
    alignField(w, content, width, align_);
    return w[];
}

@("width.alignField.horizontal")
@safe pure nothrow @nogc unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 64) b;
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
    import sparkles.base.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 64) b;
    alignField(b, "hello", 5, Align.center); // already exact -> no pad
    assert(b[] == "hello");

    b.clear();
    alignField(b, "toolong", 3, Align.right); // wider than field -> verbatim, no truncation
    assert(b[] == "toolong");
}

@("width.alignField.styledAndWide")
@safe pure nothrow @nogc unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    // ANSI escapes cost nothing: "OK" is 2 visible cells, padded to 5.
    SmallBuffer!(char, 64) b;
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
    import sparkles.base.smallbuffer : SmallBuffer;

    foreach (a; [Align.left, Align.center, Align.right, Align.inherit])
    {
        SmallBuffer!(char, 64) b;
        alignField(b, "abc", 7, a);
        assert(alignField("abc", 7, a) == b[]);
    }
}
