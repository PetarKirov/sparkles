/// The codepoint set seeded into a face's atlas at load. Kept small so the
/// first frame of `hue --gui` (and every other `FontSet` consumer) is not
/// dominated by `LoadFontEx`: the previous seed rasterized ~8,480 glyphs
/// (the whole of U+2000–U+2BFF plus several Nerd-Font PUA planes) into every
/// face before the window could paint.
///
/// The seed is what a first frame actually draws — ASCII/Latin-1, general
/// punctuation, arrows, box-drawing / block elements / geometric shapes
/// (chrome, scrollbars, `drawBox`), and the short Powerline range. Everything
/// else (Greek, Cyrillic, the rest of the Nerd PUA, CJK, emoji) is requested
/// by `FontSet.requestGlyph` as cells reference it and lands on the next
/// `flushPending`, which already existed for higher-plane icons.
module sparkles.raylib_text.atlas;

/// Build the startup atlas seed (see the module header). CTFE-evaluated once
/// into $(LREF baseCodepoints).
int[] buildCodepoints() @safe pure nothrow
{
    int[] cps;
    for (int i = 32; i <= 0xFF; i++) cps ~= i;
    // General punctuation (quotes, dashes, ellipsis, bullets).
    for (int i = 0x2000; i <= 0x206F; i++) cps ~= i;
    // Arrows.
    for (int i = 0x2190; i <= 0x21FF; i++) cps ~= i;
    // Box drawing, block elements — header rules, scroll thumbs, `drawBox`.
    for (int i = 0x2500; i <= 0x259F; i++) cps ~= i;
    // Geometric shapes (▶ ▼ used as disclosure marks).
    for (int i = 0x25A0; i <= 0x25FF; i++) cps ~= i;
    // Powerline / vim-airline Nerd glyphs (status-bar chevrons).
    for (int i = 0xE0A0; i <= 0xE0D4; i++) cps ~= i;
    return cps;
}

/// The startup atlas seed, built once at compile time.
static immutable int[] baseCodepoints = buildCodepoints();

@("raylib_text.atlas.baseCodepoints")
@safe pure nothrow
unittest
{
    import std.algorithm.searching : canFind;

    assert(baseCodepoints.length > 0);
    assert(baseCodepoints[0] == 32); // starts at space
    assert(baseCodepoints.canFind(0x2588)); // █  (scrollbar thumb + white texel)
    assert(baseCodepoints.canFind(0x2500)); // ─
    assert(baseCodepoints.canFind(0x2502)); // │
    assert(baseCodepoints.canFind(0xE0A0)); // a Powerline Nerd glyph
    // Greek / the wide Nerd PUA planes are on-demand, not in the seed —
    // seeding them was ~8k glyphs × every face at `tryLoad`.
    assert(!baseCodepoints.canFind(0x394));
    assert(!baseCodepoints.canFind(0xF000));
    // A regression guard: the old seed was 8480 codepoints and dominated
    // GUI startup. Stay well under a thousand.
    assert(baseCodepoints.length < 1000);
}
