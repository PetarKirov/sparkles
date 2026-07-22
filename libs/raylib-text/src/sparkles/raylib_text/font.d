/// A single loaded raylib face plus an O(log n) codepoint→glyph map — the unit
/// of the multi-face `FontSet`. Extracted from `apps/terminal` (PR #63): a font
/// carries a sorted set of the codepoints it actually rasterized, so glyph
/// lookups are a binary search instead of raylib's O(glyphCount) linear scan,
/// and a solid-white atlas texel so backgrounds/decorations batch on the glyph
/// texture. Loading needs an active raylib GL context (call after `InitWindow`).
module sparkles.raylib_text.font;

import raylib;

import sparkles.base.smallbuffer : SmallBuffer;

/// A loaded raylib font plus the sorted codepoints it has a glyph for. A
/// NUL-terminated `pathZ` lets the core loop reload the face on a size change /
/// on-demand atlas growth without touching the GC.
struct LoadedFont
{
    Font font;
    SmallBuffer!(int, 256, true) glyphValues;  /// ascending codepoint values present
    SmallBuffer!(int, 256, true) glyphIndices; /// font.glyphs index aligned with glyphValues
    int fallbackIndex;   /// index of the '?' glyph (value 63), or 0
    Rectangle whiteSrc;  /// a solid-white texel in the atlas (U+2588 centre)
    bool hasWhite;       /// whether whiteSrc is valid (full-block glyph present)
    const(char)* pathZ;
    bool present;
}

/// (Re)load `lf` from `lf.pathZ` at `fontSize`, requesting `cps`, and rebuild its
/// sorted glyph-value set. Unloads any previously loaded font first. No-op when
/// `pathZ` is null (an unavailable variant).
void loadFontInto(ref LoadedFont lf, int fontSize, const(int)[] cps) @system nothrow @nogc
{
    if (lf.present)
    {
        UnloadFont(lf.font);
        lf.present = false;
    }
    if (lf.pathZ is null)
        return;

    lf.font = LoadFontEx(lf.pathZ, fontSize, cps.ptr, cast(int) cps.length);
    lf.present = lf.font.texture.id != 0;

    // Rebuild the sorted (codepoint -> glyph-index) map. raylib does not
    // guarantee ascending glyph order, so copy the value/index pairs then
    // insertion-sort by value, carrying the indices in parallel (done at most a
    // few times: at startup and on each size change / on-demand growth). The map
    // makes glyph lookup O(log n) instead of raylib's O(glyphCount) GetGlyphIndex
    // scan per codepoint per cell per frame.
    lf.glyphValues.clear();
    lf.glyphIndices.clear();
    lf.fallbackIndex = 0;
    if (lf.present && lf.font.glyphs !is null)
    {
        foreach (i; 0 .. lf.font.glyphCount)
        {
            lf.glyphValues ~= lf.font.glyphs[i].value;
            lf.glyphIndices ~= i;
            if (lf.font.glyphs[i].value == 63) lf.fallbackIndex = i; // '?'
        }
        auto gv = lf.glyphValues[];
        auto gi = lf.glyphIndices[];
        foreach (i; 1 .. gv.length)
        {
            const v = gv[i];
            const vi = gi[i];
            size_t j = i;
            while (j > 0 && gv[j - 1] > v) { gv[j] = gv[j - 1]; gi[j] = gi[j - 1]; j--; }
            gv[j] = v;
            gi[j] = vi;
        }
    }

    // Locate a solid-white texel for drawing background/decoration quads from the
    // glyph atlas (so they share the glyph texture and the whole grid batches).
    // U+2588 FULL BLOCK is opaque white throughout; sample its centre.
    lf.hasWhite = false;
    if (lf.present && fontHasGlyph(lf, 0x2588))
    {
        const r = lf.font.recs[glyphIndexFor(lf, 0x2588)];
        if (r.width >= 2 && r.height >= 2)
        {
            lf.whiteSrc = Rectangle(r.x + r.width * 0.5f, r.y + r.height * 0.5f, 1, 1);
            lf.hasWhite = true;
        }
    }
}

/// O(log n) presence test over the sorted glyph-value set.
bool fontHasGlyph(ref LoadedFont lf, int codepoint) @safe pure nothrow @nogc
{
    import std.range : assumeSorted;
    return lf.glyphValues[].assumeSorted.contains(codepoint);
}

/// O(log n) codepoint→glyph-index lookup over the sorted map, falling back to the
/// font's '?' glyph when the codepoint is absent (mirroring raylib's
/// GetGlyphIndex fallback, minus its O(glyphCount) linear scan).
int glyphIndexFor(ref LoadedFont lf, int codepoint) @safe pure nothrow @nogc
{
    import std.range : assumeSorted;
    const lower = lf.glyphValues[].assumeSorted.lowerBound(codepoint).length;
    if (lower < lf.glyphValues.length && lf.glyphValues[][lower] == codepoint)
        return lf.glyphIndices[][lower];
    return lf.fallbackIndex;
}

/// True if `cp` falls within the ascending, non-overlapping ranges given by
/// matching `lo`/`hi` bound arrays. O(log n) binary search for the last range
/// start ≤ cp, then a bounds check against its end. A manual search (rather than
/// `assumeSorted`) keeps the slices `scope`-clean under dip1000.
bool rangesContain(scope const(int)[] lo, scope const(int)[] hi, int cp) @safe nothrow @nogc
{
    if (lo.length == 0)
        return false;
    size_t left = 0, right = lo.length; // find first index whose start > cp
    while (left < right)
    {
        const mid = (left + right) / 2;
        if (lo[mid] <= cp) left = mid + 1;
        else right = mid;
    }
    return left > 0 && cp <= hi[left - 1]; // cp is inside the last range starting ≤ cp
}

/// Load the font at `path` into `lf` with codepoint set `cps`; on failure leave
/// `lf` empty (`pathZ` cleared) so callers treat the variant as unavailable.
void loadVariantFile(ref LoadedFont lf, string path, int fontSize, const(int)[] cps) @system
{
    import std.file : exists;
    import std.string : toStringz;

    if (path.length == 0 || !path.exists)
        return;
    lf.pathZ = path.toStringz;
    loadFontInto(lf, fontSize, cps);
    if (!lf.present)
        lf.pathZ = null;
}

@("raylib_text.font.rangesContain")
@safe nothrow @nogc
unittest
{
    static immutable int[] lo = [0x100, 0x2000, 0xE000];
    static immutable int[] hi = [0x1FF, 0x20FF, 0xE0FF];
    assert(!rangesContain(lo, hi, 0x41));       // below all ranges
    assert(rangesContain(lo, hi, 0x100));       // range start
    assert(rangesContain(lo, hi, 0x1FF));       // range end
    assert(!rangesContain(lo, hi, 0x200));      // gap between ranges
    assert(rangesContain(lo, hi, 0x20A0));      // middle range
    assert(rangesContain(lo, hi, 0xE0FF));      // last range end
    assert(!rangesContain(lo, hi, 0xE100));     // above all ranges
    assert(!rangesContain(null, null, 0x41));   // empty
}
