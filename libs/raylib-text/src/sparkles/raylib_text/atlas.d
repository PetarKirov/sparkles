/// The base codepoint set seeded into a face's atlas at load. Extracted from
/// `apps/terminal` (PR #63): ASCII + Latin-1, Latin Extended + combining
/// diacritics, Greek/Cyrillic, General Punctuation → Misc Symbols & Arrows, and
/// the common Nerd-Font private-use ranges. Anything beyond this (icons in the
/// higher PUA planes, CJK, emoji) is loaded on demand by `FontSet` as the text
/// actually references it, so the atlas stays bounded to what a session touches.
module sparkles.raylib_text.atlas;

/// Build the base codepoint set (see the module header). CTFE-evaluated once
/// into $(LREF baseCodepoints), in every compile that imports this module.
int[] buildCodepoints() @safe pure nothrow
{
    static immutable int[2][] ranges = [
        [32, 0xFF],
        // Latin Extended-A/B, IPA, spacing modifiers, combining diacritics.
        [0x100, 0x36F],
        // Greek and Coptic, Cyrillic, and Cyrillic Supplement.
        [0x370, 0x52F],
        // General Punctuation up to Misc Symbols and Arrows.
        [0x2000, 0x2BFF],
        [0xE0A0, 0xE0D4], [0xE200, 0xE2A9], [0xE300, 0xE3E3], [0xE5FA, 0xE6B1],
        [0xE700, 0xE7C5], [0xF000, 0xF2E0], [0xF300, 0xF372], [0xF400, 0xF533],
        [0xF500, 0xFD46],
    ];
    // Sized once: appending one at a time copies the array on each append
    // under CTFE, which made this 0.13 s of every importing compile.
    size_t total;
    foreach (r; ranges)
        total += r[1] - r[0] + 1;
    auto cps = new int[total];
    size_t at;
    foreach (r; ranges)
        for (int i = r[0]; i <= r[1]; i++)
            cps[at++] = i;
    return cps;
}

/// The base codepoint set, built once at compile time.
static immutable int[] baseCodepoints = buildCodepoints();

@("raylib_text.atlas.baseCodepoints")
@safe pure nothrow
unittest
{
    assert(baseCodepoints.length > 0);
    assert(baseCodepoints[0] == 32); // starts at space
    // Note: the list is not globally sorted — the last two Nerd-Font ranges
    // overlap/reorder (0xF400-0xF533 then 0xF500-0xFD46) — but LoadFontEx tolerates
    // any order and duplicate codepoints. Just check coverage.
    import std.algorithm.searching : canFind;
    assert(baseCodepoints.canFind(0x394)); // Δ  (Greek — the dae11f43 fix)
    assert(baseCodepoints.canFind(0x416)); // Ж  (Cyrillic)
    assert(baseCodepoints.canFind(0xE0A0)); // a Powerline Nerd glyph
}
