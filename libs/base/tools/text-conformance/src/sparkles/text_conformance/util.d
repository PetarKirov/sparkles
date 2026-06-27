/**
 * Small helpers shared by the layer modules. Each was duplicated verbatim across
 * several layers; consolidating keeps the classification and wire-encoding
 * identical everywhere. (The clean-room `oracle.d` deliberately keeps its own
 * copies of the spec constants so it stays self-contained.)
 */
module sparkles.text_conformance.util;

import std.digest : toHexString;
import std.range : walkLength;
import std.string : representation;
import std.utf : byDchar;

import sparkles.base.text.grapheme : byGraphemeCluster;
import sparkles.base.text.width : codepointWidth;

import sparkles.text_conformance.ucd : WidthData;

/// Uppercase hex of a string's UTF-8 bytes — the corpus key and the hex line a
/// subprocess oracle reads.
string hexOf(string s) @safe
    => toHexString(cast(const(ubyte)[]) s.representation).idup;

/// Unicode noncharacters (`U+FDD0..FDEF`, `U+xxFFFE`, `U+xxFFFF`).
bool isNoncharacter(dchar cp) @safe pure nothrow @nogc
    => (cp >= 0xFDD0 && cp <= 0xFDEF) || (cp & 0xFFFE) == 0xFFFE;

/// True if `s` contains a code point that moves the cursor or otherwise makes a
/// placement-based width (ghostty cursor column, notcurses ncstrwidth) not a
/// pure column count: C0/C1 controls, DEL, and the line/paragraph separators.
bool hasCursorControl(string s) @safe
{
    foreach (cp; s.byDchar)
        if (cp < 0x20 || cp == 0x7F || (cp >= 0x80 && cp <= 0x9F)
            || cp == 0x2028 || cp == 0x2029)
            return true;
    return false;
}

/// Cluster lengths (in code points) `byGraphemeCluster` produces for `s` — the
/// segmentation a width/segmentation oracle is compared against.
size_t[] libClusters(string s) @safe
{
    size_t[] got;
    foreach (u; s.byGraphemeCluster)
        if (!u.isEscape)
            got ~= u.slice.byDchar.walkLength;
    return got;
}

/// Short class label for a per-code-point width divergence, for the summary
/// buckets (Layers 5 / 9 / 10). The `control/zero-width` case only ever fires
/// for Layer 10 (Python returns -1 for non-printables); the others agree there.
string cpClass(dchar cp, in WidthData d) @safe nothrow
{
    if (cp >= 0x1F1E6 && cp <= 0x1F1FF) return "regional-indicator";
    if (isNoncharacter(cp)) return "noncharacter";
    if (cp >= 0x1160 && cp <= 0x11FF) return "hangul-jamo";
    if (d.mn[cp] || d.mc[cp] || d.me[cp] || d.cf[cp]) return "mark/format";
    if (codepointWidth(cp) == 0) return "control/zero-width";
    return "other";
}
