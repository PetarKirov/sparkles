/**
The narrow cluster-shaping seam (`sparkles.font.cluster_shaping`) tested
directly: its documented failure paths (no shaper, no instance, a bad
ppem, too little room, more glyphs than the seam's cap) publish nothing,
and a shaped cluster agrees with the face's character map.
*/
module sparkles.font.cluster_shaping_test;

import sparkles.font;
import sparkles.font.cluster_shaping;
import sparkles.font.corpus : bundled, fontsPath;
import sparkles.test_runner.skip : skipTest;

@("cluster_shaping.shapesOneClusterInPixels")
@system unittest
{
    if (fontsPath() is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    const bytes = bundled("DejaVuSansMono.ttf");
    const face = openFace(bytes).value;
    auto inst = face.instance(InstanceSize.pixels(Ppem.fromInteger(16).value), null).value;
    auto shaper = openClusterShaper(&inst);
    if (shaper is null)
        return skipTest("the engine cannot shape this face");
    scope (exit)
        closeClusterShaper(shaper);

    ClusterGlyph[64] glyphs;
    const map = face.charMap.value;
    const one = shapeCluster(shaper, "a", 16, 1, glyphs[]);
    assert(one == 1 && glyphs[0].glyph == map.glyph('a'), "one glyph, the map's");
    assert(glyphs[0].advance > 0, "with a pixel advance");

    // `q` + combining acute (no precomposed form): two glyphs, one cluster.
    const two = shapeCluster(shaper, "q\u0301", 16, 1, glyphs[]);
    assert(two == 2 && glyphs[0].glyph == map.glyph('q') && glyphs[1].glyph != 0);
}

@("cluster_shaping.failurePathsPublishNothing")
@system unittest
{
    if (fontsPath() is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    const bytes = bundled("DejaVuSansMono.ttf");
    const face = openFace(bytes).value;
    auto inst = face.instance(InstanceSize.pixels(Ppem.fromInteger(16).value), null).value;
    auto shaper = openClusterShaper(&inst);
    if (shaper is null)
        return skipTest("the engine cannot shape this face");
    scope (exit)
        closeClusterShaper(shaper);

    ClusterGlyph[64] glyphs;
    glyphs[0].glyph = 4242;
    assert(shapeCluster(null, "a", 16, 1, glyphs[]) == 0, "no shaper");
    assert(shapeCluster(shaper, "", 16, 1, glyphs[]) == 0, "no text");
    assert(shapeCluster(shaper, "a", 16, 0, glyphs[]) == 0, "a ppem with no denominator");
    assert(shapeCluster(shaper, "a", 0, 1, glyphs[]) == 0, "a zero ppem");
    assert(glyphs[0].glyph == 4242, "a failure writes nothing");

    // Room for one glyph, a cluster of two: refused whole, not truncated.
    assert(shapeCluster(shaper, "q\u0301", 16, 1, glyphs[0 .. 1]) == 0, "too short");

    // More glyphs than the seam's cap, however much room the caller has.
    ClusterGlyph[128] wide;
    char[100] run = 'a';
    assert(shapeCluster(shaper, run[], 16, 1, wide[]) == 0, "past the cap");
    assert(maxClusterGlyphs == 64, "the seam's named cap");
}

@("cluster_shaping.nullInstanceOpensNothing")
@system unittest
{
    assert(openClusterShaper(null) is null);
    closeClusterShaper(null); // ignored, and must not crash
}
