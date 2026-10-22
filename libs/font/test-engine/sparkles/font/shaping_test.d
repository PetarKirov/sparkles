/**
M4 shaping tests (FTS1–FTS11) over the bundled faces: glyphs and
advances against the library's own `cmap`/`hmtx`, ligature merging,
RTL source spans, contextual range shaping, validation errors, and
the justification-candidate contract.
*/
module sparkles.font.shaping_test;

import std.file : read;
import std.path : buildPath;

import sparkles.font;
import sparkles.font.corpus : bundled, fontsPath;
import sparkles.test_runner.skip : skipTest;

private Instance instanceOf(const(ubyte)[] bytes) @safe
{
    auto face = openFace(bytes).value;
    return face.instance(InstanceSize.pixels(Ppem.fromInteger(16).value), null).value;
}

private struct Outputs
{
    ShapedGlyph[64] glyphs;
    SourceSpan[64] spans;
    BoundarySafety[64] boundaries;
    char[64] language;
}

@("shaping.basic.clustersAndAdvances")
@system
unittest
{
    if (fontsPath() is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    const bytes = bundled("DejaVuSansMono.ttf");
    const face = openFace(bytes).value;
    auto inst = instanceOf(bytes);
    Outputs o;
    const info = shapeText(inst, "abc", o.glyphs[], o.spans[], o.boundaries[], o.language[]);
    assert(info.hasValue, "shaping failed");
    assert(info.value.glyphCount == 3);
    const map = face.charMap.value;
    foreach (i, c; "abc")
    {
        assert(o.glyphs[i].glyphId == map.glyph(c));
        assert(o.glyphs[i].cluster == i);
        assert(o.glyphs[i].xAdvance == face.hmtx.value.advance(o.glyphs[i].glyphId).value);
    }
    // FTS4: three one-byte spans partition the source.
    assert(info.value.spanCount == 3);
    foreach (i; 0 .. 3)
    {
        assert(o.spans[i].start == i && o.spans[i].end == i + 1);
        assert(o.spans[i].glyphStart == i && o.spans[i].glyphEnd == i + 1);
    }
    assert(info.value.direction == ShapingDirection.leftToRight
        && !info.value.directionGuessed == false);
}

@("shaping.ligature.featureOnOff")
@system
unittest
{
    if (fontsPath() is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    const bytes = bundled("MapleMono-NF-CN-Regular.ttf");
    auto inst = instanceOf(bytes);
    auto owned = shaper(inst);

    Outputs on, off;
    auto props = SegmentProperties(ShapingDirection.leftToRight, Tag("Latn"), "en");
    // Maple Mono forms its programming ligatures under `calt` (and
    // `liga`); toggle both. "!=" is a documented Maple ligature.
    auto withLiga = ShapeRequest("!=", 0, 2, props, true,
        [ShapingFeature.global(Tag("liga"), 1), ShapingFeature.global(Tag("calt"), 1)],
        false, false);
    auto without = ShapeRequest("!=", 0, 2, props, true,
        [ShapingFeature.global(Tag("liga"), 0), ShapingFeature.global(Tag("calt"), 0)],
        false, false);
    const onInfo = owned.value.shape(withLiga, on.glyphs[], on.spans[], on.boundaries[], on.language[]);
    const offInfo = owned.value.shape(without, off.glyphs[], off.spans[], off.boundaries[], off.language[]);
    assert(onInfo.hasValue && offInfo.hasValue);
    // FTX7: a programming ligature substitutes glyphs one-for-one, so
    // the count stands and the glyph IDs change.
    assert(onInfo.value.glyphCount == offInfo.value.glyphCount);
    bool substituted;
    foreach (i; 0 .. onInfo.value.glyphCount)
        if (on.glyphs[i].glyphId != off.glyphs[i].glyphId)
            substituted = true;
    assert(substituted, "calt/liga substitute the ffi glyphs");
    // Every source byte is covered by the spans on both runs.
    const infos = [onInfo.value, offInfo.value];
    foreach (k; 0 .. 2)
    {
        const info = infos[k];
        Outputs* o = k == 0 ? &on : &off;
        size_t at = 0;
        foreach (s; o.spans[0 .. info.spanCount])
        {
            assert(s.start == at);
            at = s.end;
        }
        assert(at == 2);
    }
}

@("shaping.rtl.spansCoverSource")
@system
unittest
{
    if (fontsPath() is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    const bytes = bundled("NotoSansArabic.ttf");
    auto inst = instanceOf(bytes);
    auto owned = shaper(inst);
    // "سلام" — four Arabic letters, eight UTF-8 bytes.
    const word = "سلام";
    Outputs o;
    auto props = SegmentProperties(ShapingDirection.rightToLeft, Tag("Arab"), "ar");
    auto request = ShapeRequest(word, 0, word.length, props, true, null, true, true);
    const info = owned.value.shape(request, o.glyphs[], o.spans[], o.boundaries[], o.language[]);
    assert(info.hasValue);
    assert(info.value.glyphCount >= 3);
    // Pen order runs right to left: clusters descend.
    foreach (i; 1 .. info.value.glyphCount)
        assert(o.glyphs[i].cluster <= o.glyphs[i - 1].cluster);
    // Source spans ascend and partition the word.
    size_t at = 0;
    foreach (s; o.spans[0 .. info.value.spanCount])
    {
        assert(s.start == at && s.end > s.start);
        at = s.end;
    }
    assert(at == word.length);
    assert(info.value.direction == ShapingDirection.rightToLeft
        && !info.value.directionGuessed);
}

@("shaping.contextual.middleRun")
@system
unittest
{
    if (fontsPath() is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    const bytes = bundled("NotoSansArabic.ttf");
    auto inst = instanceOf(bytes);
    auto owned = shaper(inst);
    const word = "سلام";
    auto props = SegmentProperties(ShapingDirection.rightToLeft, Tag("Arab"), "ar");
    // The middle two letters (bytes 2..6) with the word as context.
    Outputs withContext, standalone;
    auto contextual = ShapeRequest(word, 2, 6, props, true, null, false, false);
    auto alone = ShapeRequest(word[2 .. 6], 0, 4, props, true, null, true, true);
    const a = owned.value.shape(contextual, withContext.glyphs[], withContext.spans[],
        withContext.boundaries[], withContext.language[]);
    const b = owned.value.shape(alone, standalone.glyphs[], standalone.spans[],
        standalone.boundaries[], standalone.language[]);
    assert(a.hasValue && b.hasValue);
    // Arabic joining changes the forms: the shaped glyphs differ, the
    // clusters stay absolute, and only run bytes are emitted.
    assert(a.value.glyphCount == b.value.glyphCount);
    bool differ;
    foreach (i; 0 .. a.value.glyphCount)
    {
        if (withContext.glyphs[i].glyphId != standalone.glyphs[i].glyphId)
            differ = true;
        assert(withContext.glyphs[i].cluster >= 2 && withContext.glyphs[i].cluster < 6);
    }
    assert(differ, "context changes Arabic letter forms");
}

@("shaping.validation.errors")
@system
unittest
{
    if (fontsPath() is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    const bytes = bundled("DejaVuSansMono.ttf");
    auto inst = instanceOf(bytes);
    auto owned = shaper(inst);
    Outputs o;
    auto props = SegmentProperties(ShapingDirection.leftToRight, Tag("Latn"), "en");

    const invalid = owned.value.shape(ShapeRequest("\xff", 0, 1, props, true),
        o.glyphs[], o.spans[], o.boundaries[], o.language[]);
    assert(invalid.hasError && invalid.error.kind == FontErrorKind.invalidEncoding);

    const inverted = owned.value.shape(ShapeRequest("abc", 2, 1, props, true),
        o.glyphs[], o.spans[], o.boundaries[], o.language[]);
    assert(inverted.hasError && inverted.error.kind == FontErrorKind.invalidRange);

    // "é" is two bytes: a run edge between them splits the scalar.
    const split = owned.value.shape(ShapeRequest("é", 0, 1, props, true),
        o.glyphs[], o.spans[], o.boundaries[], o.language[]);
    assert(split.hasError && split.error.kind == FontErrorKind.splitScalar);

    auto badFeature = ShapingFeature(Tag("liga"), 1, 0, 3, true);
    const feature = owned.value.shape(ShapeRequest("ab", 0, 2, props, true, [badFeature]),
        o.glyphs[], o.spans[], o.boundaries[], o.language[]);
    assert(feature.hasError && feature.error.kind == FontErrorKind.invalidFeatureRange);

    ShapedGlyph[1] tiny;
    const exhausted = owned.value.shape(ShapeRequest("abc", 0, 3, props, true),
        tiny[], o.spans[], o.boundaries[], o.language[]);
    assert(exhausted.hasError && exhausted.error.kind == FontErrorKind.limitExceeded
        && exhausted.error.limit == FontLimit.callerStorage && exhausted.error.needed == 3);
}

@("shaping.boundaries.andJustification")
@system
unittest
{
    if (fontsPath() is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    const bytes = bundled("DejaVuSansMono.ttf");
    auto inst = instanceOf(bytes);
    auto owned = shaper(inst);
    Outputs o;
    auto props = SegmentProperties(ShapingDirection.leftToRight, Tag("Latn"), "en");
    auto request = ShapeRequest("abcd", 0, 4, props, true, null, true, true);
    const info = owned.value.shape(request, o.glyphs[], o.spans[], o.boundaries[], o.language[]);
    assert(info.hasValue);
    // Run edges are unknown; an interior boundary of unjoined Latin is
    // known and safe.
    assert(!o.boundaries[0].known);
    foreach (b; o.boundaries[1 .. info.value.spanCount])
        assert(b.known && !b.unsafeToBreak && !b.unsafeToConcat);

    Outputs candidate;
    const inserted = measureJustificationCandidate(owned.value,
        ShapeRequest("abcd", 0, 4, props, true), JustificationMode.extenderInsertion,
        candidate.glyphs[], candidate.spans[], candidate.boundaries[], candidate.language[]);
    assert(inserted.hasError
        && inserted.error.kind == FontErrorKind.unsupportedCapability);
    const measured = measureJustificationCandidate(owned.value,
        ShapeRequest("abcd", 0, 4, props, true), JustificationMode.featureSettings,
        candidate.glyphs[], candidate.spans[], candidate.boundaries[], candidate.language[]);
    assert(measured.hasValue && measured.value.glyphCount == 4);
}

@("shaping.profile.engine")
@system
unittest
{
    const profile = engineProfile();
    assert(profile.compatible, "the pinned profile must match the dev shell");
    assert(profile.harfBuzzVersion == pinnedHarfBuzzVersion);
    assert(profile.unicodeRelease == pinnedUnicodeVersion);
}
