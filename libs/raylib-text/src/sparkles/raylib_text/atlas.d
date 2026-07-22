/// The base codepoint set seeded into a face's atlas at load. Extracted from
/// `apps/terminal` (PR #63): ASCII + Latin-1, Latin Extended + combining
/// diacritics, Greek/Cyrillic, General Punctuation → Misc Symbols & Arrows, and
/// the common Nerd-Font private-use ranges. Anything beyond this (icons in the
/// higher PUA planes, CJK, emoji) is loaded on demand by `FontSet` as the text
/// actually references it, so the atlas stays bounded to what a session touches.
module sparkles.raylib_text.atlas;

/// Build the base codepoint set (see the module header). CTFE-evaluated once
/// into $(LREF baseCodepoints).
int[] buildCodepoints() @safe pure nothrow
{
    int[] cps;
    for (int i = 32; i <= 0xFF; i++) cps ~= i;
    // Latin Extended-A/B, IPA, spacing modifiers, combining diacritics.
    for (int i = 0x100; i <= 0x36F; i++) cps ~= i;
    // Greek and Coptic, Cyrillic, and Cyrillic Supplement.
    for (int i = 0x370; i <= 0x52F; i++) cps ~= i;
    // General Punctuation up to Misc Symbols and Arrows.
    for (int i = 0x2000; i <= 0x2BFF; i++) cps ~= i;
    for (int i = 0xE0A0; i <= 0xE0D4; i++) cps ~= i;
    for (int i = 0xE200; i <= 0xE2A9; i++) cps ~= i;
    for (int i = 0xE300; i <= 0xE3E3; i++) cps ~= i;
    for (int i = 0xE5FA; i <= 0xE6B1; i++) cps ~= i;
    for (int i = 0xE700; i <= 0xE7C5; i++) cps ~= i;
    for (int i = 0xF000; i <= 0xF2E0; i++) cps ~= i;
    for (int i = 0xF300; i <= 0xF372; i++) cps ~= i;
    for (int i = 0xF400; i <= 0xF533; i++) cps ~= i;
    for (int i = 0xF500; i <= 0xFD46; i++) cps ~= i;
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
