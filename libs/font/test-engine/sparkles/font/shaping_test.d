/**
M4 shaping tests (FTS1–FTS11) over the bundled faces: advances against
the library's own metrics, at the default and nondefault coordinates;
hand-worked source spans; contextual runs and text-boundary flags;
validation and capacity errors that publish nothing; explicit
properties; break/concat reuse by recombining fragments; the engine
profile; and the shaper's lifetime.
*/
module sparkles.font.shaping_test;

import std.conv : text;

import sparkles.base.text.grapheme : byGraphemeCluster;
import sparkles.base.unique : makeUnique;

import sparkles.font;
import sparkles.font.corpus : bundled, fontsPath;
import sparkles.test_runner.skip : skipTest;

private Instance instanceOf(const(ubyte)[] bytes, const(UserCoordinate)[] coords = null) @safe
{
    auto face = openFace(bytes).value;
    return face.instance(InstanceSize.pixels(Ppem.fromInteger(16).value), coords).value;
}

private struct Outputs
{
    ShapedGlyph[64] glyphs;
    SourceSpan[64] spans;
    BoundarySafety[64] boundaries;
    char[64] language;

    FontResult!ShapeInfo shape(scope ref Shaper s, in ShapeRequest request) @safe
        => s.shape(request, glyphs[], spans[], boundaries[], language[]);
}

private SegmentProperties latin() @safe => SegmentProperties(ShapingDirection.leftToRight, Tag("Latn"), "en");
private SegmentProperties arabic() @safe => SegmentProperties(ShapingDirection.rightToLeft, Tag("Arab"), "ar");

/// Spans ascend in source order, partition `[start, end)`, and give every glyph to exactly one span.
private void assertPartition(in Outputs o, in ShapeInfo info, size_t start, size_t end) @safe
{
    size_t at = start, glyphsCovered;
    foreach (s; o.spans[0 .. info.spanCount])
    {
        assert(s.start == at && s.end > s.start, text("span ", s, " after ", at));
        glyphsCovered += s.glyphEnd - s.glyphStart;
        foreach (g; o.glyphs[s.glyphStart .. s.glyphEnd])
            assert(g.cluster == s.start);
        at = s.end;
    }
    assert(at == end && glyphsCovered == info.glyphCount);
}

@("shaping.FTS1.clustersAndAdvances")
@system
unittest
{
    auto ws = makeUnique!PointWorkspace();
    if (fontsPath() is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    const bytes = bundled("DejaVuSansMono.ttf");
    const face = openFace(bytes).value;
    auto inst = instanceOf(bytes);
    Outputs o;
    const info = shapeText(inst, "abc", o.glyphs[], o.spans[], o.boundaries[], o.language[]);
    assert(info.hasValue, "shaping failed");
    assert(info.value.glyphCount == 3 && info.value.spanCount == 3);
    const map = face.charMap.value;
    foreach (i, c; "abc")
    {
        assert(o.glyphs[i].glyphId == map.glyph(c));
        assert(o.glyphs[i].cluster == i);
        assert(o.glyphs[i].xAdvance == advance(inst, o.glyphs[i].glyphId, *ws).value.design);
        assert(o.spans[i] == SourceSpan(i, i + 1, i, i + 1));
    }
    // The standalone call guesses and says so (FTS2).
    assert(info.value.direction == ShapingDirection.leftToRight && info.value.directionGuessed
        && info.value.scriptGuessed && info.value.script == Tag("Latn"));
    // FTM4: the pixel form of an advance at the instance's 16 ppem.
    const px = info.value.measured(o.glyphs[0].xAdvance).pixels.value;
    assert(px == advance(inst, o.glyphs[0].glyphId, *ws).value.pixels.value);
}

/// The vertical run of `text` in `script`, `vkrn` off so advances stay nominal.
private FontResult!ShapeInfo shapeVertical(scope ref Shaper s, ref Outputs o, const(char)[] text,
    Tag script) @safe
{
    static immutable ShapingFeature[1] noKern = [ShapingFeature.global(Tag("vkrn"), 0)];
    return o.shape(s, ShapeRequest(text, 0, text.length,
        SegmentProperties(ShapingDirection.topToBottom, script), true, noKern[], true, true));
}

/// HarfBuzz positions are 1/1,024 unit: 64 `DesignValue` steps.
private long toPositionSteps(long raw) @safe => (raw >= 0 ? raw + 32 : raw - 32) / 64;

/**
FTS1, FTM20, FTM21: vertical advances and origins are the library's, with
x at half the horizontal advance. (This face's `vmtx` advances are all 0;
`shaping.FTS1.verticalUnrounded` varies a real one.)
*/
@("shaping.FTS1.verticalVariable")
@system
unittest
{
    auto ws = makeUnique!PointWorkspace();
    if (fontsPath() is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    const bytes = bundled("NotoSansEthiopic.ttf");
    foreach (weight; [100, 437, 900])
    {
        auto inst = instanceOf(bytes, [UserCoordinate(Tag("wght"), weight << 16)]);
        auto s = Shaper(inst);
        Outputs o;
        const info = shapeVertical(s, o, "ሰላም ኢትዮጵያ", Tag("Ethi"));
        assert(info.hasValue, text(info.error));
        assert(info.value.direction == ShapingDirection.topToBottom);
        foreach (g; o.glyphs[0 .. info.value.glyphCount])
        {
            const v = verticalAdvance(inst, g.glyphId, *ws).value;
            assert(v.present);
            const diff = g.yAdvance.raw + v.advance.design.raw;
            assert(diff >= -32 && diff <= 32, text("wght ", weight, " gid ", g.glyphId));
            assert(g.xAdvance.raw == 0);
            const h = advance(inst, g.glyphId, *ws).value.design.raw;
            assert(g.xOffset.raw == -(toPositionSteps(h) / 2) * 64, text("gid ", g.glyphId));
            const origin = verticalOrigin(inst, g.glyphId, *ws).value;
            assert(origin.source == VerticalOriginSource.vmtxGlyph);
            const dy = g.yOffset.raw + origin.y.design.raw;
            assert(dy >= -32 && dy <= 32, text("wght ", weight, " gid ", g.glyphId));
        }
    }
}

/**
FTS1, FTM20: a `VVAR` delta of half a unit reaches the shaped advance, where
HarfBuzz's own vertical advance rounds it to a whole unit.
*/
@("shaping.FTS1.verticalUnrounded")
@system
unittest
{
    import sparkles.font.fixtures : FvarAxis, fvarTable, hhea, hmtx, itemVariationStore, minimalTables,
        sfnt, TableData, VarData, vheaTable, vmtxTable, vvarTable;

    auto ws = makeUnique!PointWorkspace();
    enum short f2one = 16_384;
    // Glyph 1 ('A') stands 1,000 units tall; its VVAR delta is 1 unit at TEST = 1.
    auto tables = minimalTables(2);
    tables ~= TableData("hhea", hhea(2));
    tables ~= TableData("hmtx", hmtx([[500, 0], [600, 0]]));
    tables ~= TableData("vhea", vheaTable(2));
    tables ~= TableData("vmtx", vmtxTable([[1_000, 0], [1_000, 0]]));
    tables ~= TableData("VVAR", vvarTable(itemVariationStore(1, [[[0, f2one, f2one]]],
        [VarData([0], 1, false, [[0], [1]])])));
    tables ~= TableData("fvar", fvarTable([FvarAxis("TEST", -65_536, 0, 65_536)]));
    const bytes = sfnt(tables);
    auto inst = instanceOf(bytes, [UserCoordinate(Tag("TEST"), 32_768)]);
    assert(verticalAdvance(inst, 1, *ws).value.advance.design.raw == 1_000L * 65_536 + 32_768);
    auto s = Shaper(inst);
    Outputs o;
    const info = shapeVertical(s, o, "A", Tag("Latn"));
    assert(info.hasValue && info.value.glyphCount == 1 && o.glyphs[0].glyphId == 1);
    assert(o.glyphs[0].yAdvance.raw == -(1_000L * 65_536 + 32_768));
}

/// FTM21: a `CFF` face's `VORG` origin, and a face without vertical metrics taking the engine's.
@("shaping.FTS1.verticalOrigins")
@system
unittest
{
    auto ws = makeUnique!PointWorkspace();
    if (fontsPath() is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    {
        auto inst = instanceOf(bundled("NotoSansSymbols2-Regular.otf"));
        auto s = Shaper(inst);
        Outputs o;
        const info = shapeVertical(s, o, "★☆♠", Tag("Zyyy"));
        assert(info.hasValue && info.value.glyphCount == 3);
        foreach (g; o.glyphs[0 .. 3])
        {
            const origin = verticalOrigin(inst, g.glyphId, *ws).value;
            assert(origin.source != VerticalOriginSource.none);
            assert(g.yOffset.raw == -origin.y.design.raw);
            assert(g.yAdvance.raw == -verticalAdvance(inst, g.glyphId, *ws).value.advance.design.raw);
        }
    }
    {
        // No vhea, vmtx or VORG: HarfBuzz's line height and centred origin stand in.
        auto inst = instanceOf(bundled("DejaVuSansMono.ttf"));
        assert(!verticalAdvance(inst, 1, *ws).value.present);
        auto s = Shaper(inst);
        Outputs o;
        const info = shapeVertical(s, o, "ab", Tag("Latn"));
        assert(info.hasValue && info.value.glyphCount == 2);
        assert(o.glyphs[0].yAdvance.raw < 0 && o.glyphs[0].yAdvance == o.glyphs[1].yAdvance);
    }
}

/// FTS1, FTS3: at nondefault coordinates the shaped advance is the library's FTM18 advance.
@("shaping.FTS3.variableAdvances")
@system
unittest
{
    auto ws = makeUnique!PointWorkspace();
    if (fontsPath() is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    const bytes = bundled("NotoSans.ttf");
    foreach (weight; [300, 437, 800])
    {
        auto inst = instanceOf(bytes, [UserCoordinate(Tag("wght"), weight << 16)]);
        auto s = Shaper(inst);
        Outputs o;
        // No kerning between these: the advances are the nominal ones.
        const info = o.shape(s, ShapeRequest("mHo", 0, 3, latin, true, [ShapingFeature.global(Tag("kern"), 0)],
            true, true));
        assert(info.hasValue);
        bool fractional;
        foreach (g; o.glyphs[0 .. info.value.glyphCount])
        {
            const expected = advance(inst, g.glyphId, *ws).value.design;
            // Shaped values are multiples of 1/1,024 unit, rounded once.
            const diff = g.xAdvance.raw - expected.raw;
            assert(diff >= -32 && diff <= 32, text("wght ", weight, " gid ", g.glyphId, ": ", g.xAdvance,
                " vs ", expected));
            fractional |= !expected.isWholeUnits;
        }
        assert(weight == 300 || weight == 800 || fractional, "an intermediate weight has fractional advances");
    }
}

@("shaping.ligature.featureOnOff")
@system
unittest
{
    if (fontsPath() is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    const bytes = bundled("MapleMono-NF-CN-Regular.ttf");
    auto inst = instanceOf(bytes);
    auto s = Shaper(inst);

    Outputs on, off;
    // Maple Mono forms its programming ligatures under `calt` (and
    // `liga`); toggle both. "!=" is a documented Maple ligature.
    const onInfo = on.shape(s, ShapeRequest("!=", 0, 2, latin, true,
        [ShapingFeature.global(Tag("liga"), 1), ShapingFeature.global(Tag("calt"), 1)]));
    const offInfo = off.shape(s, ShapeRequest("!=", 0, 2, latin, true,
        [ShapingFeature.global(Tag("liga"), 0), ShapingFeature.global(Tag("calt"), 0)]));
    assert(onInfo.hasValue && offInfo.hasValue);
    // FTX7: a programming ligature substitutes glyphs one-for-one, so
    // the count stands and the glyph IDs change.
    assert(onInfo.value.glyphCount == offInfo.value.glyphCount);
    bool substituted;
    foreach (i; 0 .. onInfo.value.glyphCount)
        substituted |= on.glyphs[i].glyphId != off.glyphs[i].glyphId;
    assert(substituted, "calt/liga substitute the != glyphs");
    assertPartition(on, onInfo.value, 0, 2);
    assertPartition(off, offInfo.value, 0, 2);

    // A ranged feature applies to its bytes only (FTS2): off on the
    // second "!=" of two, on for the first.
    Outputs ranged;
    const r = ranged.shape(s, ShapeRequest("!=!=", 0, 4, latin, true,
        [ShapingFeature(Tag("calt"), 0, 2, 4, true), ShapingFeature(Tag("liga"), 0, 2, 4, true)]));
    assert(r.hasValue && r.value.glyphCount == 4);
    assert(ranged.glyphs[0 .. 2] == on.glyphs[0 .. 2]);
    assert(ranged.glyphs[2].glyphId == off.glyphs[0].glyphId && ranged.glyphs[3].glyphId == off.glyphs[1].glyphId);
}

/// FTS4's hand-worked partitions.
@("shaping.FTS4.handWorkedSpans")
@system
unittest
{
    if (fontsPath() is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    Outputs o;

    // "aé": two scalars, two glyphs, spans [0,1) and [1,3).
    auto mono = instanceOf(bundled("DejaVuSansMono.ttf"));
    auto dejavu = Shaper(mono);
    auto info = o.shape(dejavu, ShapeRequest("aé", 0, 3, latin, true, null, true, true));
    assert(info.hasValue && info.value.glyphCount == 2 && info.value.spanCount == 2);
    assert(o.spans[0] == SourceSpan(0, 1, 0, 1) && o.spans[1] == SourceSpan(1, 3, 1, 2));

    // "e" + U+0301 composes to the font's é: one glyph, one three-byte span.
    info = o.shape(dejavu, ShapeRequest("é", 0, 3, latin, true, null, true, true));
    assert(info.hasValue && info.value.glyphCount == 1 && info.value.spanCount == 1);
    assert(o.glyphs[0].glyphId == openFace(bundled("DejaVuSansMono.ttf")).value.charMap.value.glyph('é'));
    assert(o.spans[0] == SourceSpan(0, 3, 0, 1));

    // "e" + U+0331 has no precomposed form: one grapheme, but two glyph
    // clusters and so two spans. Spans are not graphemes.
    info = o.shape(dejavu, ShapeRequest("e̱", 0, 3, latin, true, null, true, true));
    size_t graphemes;
    foreach (_; byGraphemeCluster("e̱"))
        ++graphemes;
    assert(graphemes == 1 && info.hasValue && info.value.spanCount == 2);
    assertPartition(o, info.value, 0, 3);

    // A default-ignorable-only run: one hidden glyph that still covers its bytes.
    info = o.shape(dejavu, ShapeRequest("​", 0, 3, latin, true, null, true, true));
    assert(info.hasValue && info.value.glyphCount == 1 && o.glyphs[0].xAdvance.raw == 0);
    assert(o.spans[0] == SourceSpan(0, 3, 0, 1));

    // A merging Latin ligature: Noto Sans's "fi" is one glyph for two bytes.
    auto sans = instanceOf(bundled("NotoSans.ttf"));
    auto noto = Shaper(sans);
    info = o.shape(noto, ShapeRequest("fi", 0, 2, latin, true, null, true, true));
    assert(info.hasValue && info.value.glyphCount == 1 && o.spans[0] == SourceSpan(0, 2, 0, 1));

    // Arabic lam-alef in RTL: Noto Sans Arabic draws it as two `rlig`
    // contextual glyphs (alef.fina, lam.init), as `hb-shape` does, not one
    // ligature. Pen order is alef then lam; the spans stay in source order.
    auto arab = instanceOf(bundled("NotoSansArabic.ttf"));
    auto noArab = Shaper(arab);
    info = o.shape(noArab, ShapeRequest("لا", 0, 4, arabic, true, null, true, true));
    assert(info.hasValue && info.value.glyphCount == 2);
    assert(o.glyphs[0].cluster == 2 && o.glyphs[1].cluster == 0);
    assert(o.spans[0] == SourceSpan(0, 2, 1, 2) && o.spans[1] == SourceSpan(2, 4, 0, 1));

    // RTL pen order descends while source spans ascend.
    info = o.shape(noArab, ShapeRequest("سلام", 0, 8, arabic, true, null, true, true));
    assert(info.hasValue && info.value.glyphCount >= 3);
    foreach (i; 1 .. info.value.glyphCount)
        assert(o.glyphs[i].cluster <= o.glyphs[i - 1].cluster);
    assertPartition(o, info.value, 0, 8);
    assert(info.value.direction == ShapingDirection.rightToLeft && !info.value.directionGuessed);

    // An Indic conjunct: ka + virama + ssa (9 bytes) forms fewer glyphs than scalars.
    auto deva = instanceOf(bundled("NotoSansDevanagari.ttf"));
    auto noDeva = Shaper(deva);
    const ksha = "क्ष";
    info = o.shape(noDeva, ShapeRequest(ksha, 0, ksha.length,
        SegmentProperties(ShapingDirection.leftToRight, Tag("Deva"), "hi"), true, null, true, true));
    assert(info.hasValue && info.value.glyphCount < 3);
    assertPartition(o, info.value, 0, ksha.length);
}

/// FTS7: context is visible, edges are explicit, offsets stay absolute.
@("shaping.FTS7.contextAndTextBoundaries")
@system
unittest
{
    if (fontsPath() is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    auto inst = instanceOf(bundled("NotoSansArabic.ttf"));
    auto s = Shaper(inst);
    const word = "سلام";
    // The middle two letters (bytes 2..6) with the word as context, then
    // the same bytes as a standalone word.
    Outputs withContext, standalone;
    const a = withContext.shape(s, ShapeRequest(word, 2, 6, arabic, true, null, false, false));
    const b = standalone.shape(s, ShapeRequest(word[2 .. 6], 0, 4, arabic, true, null, true, true));
    assert(a.hasValue && b.hasValue && a.value.glyphCount == b.value.glyphCount);
    assert(!a.value.beginningOfText && !a.value.endOfText && b.value.beginningOfText);
    bool differ;
    foreach (i; 0 .. a.value.glyphCount)
    {
        differ |= withContext.glyphs[i].glyphId != standalone.glyphs[i].glyphId;
        // Context-only bytes emit nothing; clusters are absolute.
        assert(withContext.glyphs[i].cluster >= 2 && withContext.glyphs[i].cluster < 6);
        assert(withContext.glyphs[i].cluster == standalone.glyphs[i].cluster + 2);
    }
    assert(differ, "context changes Arabic letter forms");
    assertPartition(withContext, a.value, 2, 6);

    // A style or fallback boundary is context, not a text boundary: the
    // same middle run shaped with its neighbours as context but no BOT/EOT
    // keeps the joined forms.
    Outputs again;
    const c = again.shape(s, ShapeRequest(word, 2, 6, arabic, true, null, false, false));
    assert(c.hasValue && again.glyphs[0 .. c.value.glyphCount] == withContext.glyphs[0 .. a.value.glyphCount]);

    // BOT matters: a lone mark gets a dotted circle only at a text start
    // (and only without pre-context, which would give it a base).
    auto mono = instanceOf(bundled("DejaVuSansMono.ttf"));
    auto dejavu = Shaper(mono);
    Outputs atStart, inside, afterBase;
    const atBot = atStart.shape(dejavu, ShapeRequest("́", 0, 2, latin, true, null, true, true));
    const notBot = inside.shape(dejavu, ShapeRequest("́", 0, 2, latin, true, null, false, true));
    const withBase = afterBase.shape(dejavu, ShapeRequest("á", 1, 3, latin, true, null, true, true));
    assert(atBot.hasValue && notBot.hasValue && withBase.hasValue);
    assert(withBase.value.glyphCount == 1 && afterBase.glyphs[0].cluster == 1);
    const circle = openFace(bundled("DejaVuSansMono.ttf")).value.charMap.value.glyph('◌');
    assert(atBot.value.glyphCount == 2 && atStart.glyphs[0].glyphId == circle);
    assert(notBot.value.glyphCount == 1);
}

/// FTS7: every error publishes nothing; exact capacities succeed and one short fails.
@("shaping.FTS7.errorsAndCapacity")
@system
unittest
{
    if (fontsPath() is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    auto inst = instanceOf(bundled("DejaVuSansMono.ttf"));
    auto s = Shaper(inst);

    Outputs o;
    void expectError(in ShapeRequest request, FontErrorKind kind, ulong offset = ulong.max)
    {
        o.glyphs[] = ShapedGlyph(7);
        o.spans[] = SourceSpan(7);
        const r = o.shape(s, request);
        assert(r.hasError && r.error.kind == kind, text(request.source, ": ", r.hasError ? r.error.kind : kind));
        assert(offset == ulong.max || r.error.offset == offset, text(r.error.offset));
        foreach (g; o.glyphs)
            assert(g == ShapedGlyph(7));
        foreach (sp; o.spans)
            assert(sp == SourceSpan(7));
    }

    expectError(ShapeRequest("a\xffb", 0, 3, latin, true), FontErrorKind.invalidEncoding, 1);
    expectError(ShapeRequest("abc", 2, 1, latin, true), FontErrorKind.invalidRange, 2);
    expectError(ShapeRequest("abc", 0, 4, latin, true), FontErrorKind.invalidRange, 4);
    // "aé": a run edge inside é, at either end, names that edge.
    expectError(ShapeRequest("aé", 2, 3, latin, true), FontErrorKind.splitScalar, 2);
    expectError(ShapeRequest("aéb", 0, 2, latin, true), FontErrorKind.splitScalar, 2);
    expectError(ShapeRequest("ab", 0, 2, latin, true, [ShapingFeature(Tag("liga"), 1, 0, 3, true)]),
        FontErrorKind.invalidFeatureRange, 0);
    expectError(ShapeRequest("ab", 0, 2, SegmentProperties(ShapingDirection.leftToRight), true),
        FontErrorKind.badValue);
    ShapingFeature[513] many;
    expectError(ShapeRequest("ab", 0, 2, latin, true, many[]), FontErrorKind.limitExceeded);

    // An empty run succeeds with nothing.
    const empty = o.shape(s, ShapeRequest("abc", 1, 1, latin, true));
    assert(empty.hasValue && empty.value.glyphCount == 0 && empty.value.spanCount == 0);

    // Exactly sufficient capacity commits; one short publishes nothing.
    ShapedGlyph[3] three;
    ShapedGlyph[2] two = ShapedGlyph(9);
    SourceSpan[3] spans;
    BoundarySafety[3] boundaries;
    char[2] language;
    const fits = s.shape(ShapeRequest("abc", 0, 3, latin, true), three[], spans[], boundaries[], language[]);
    assert(fits.hasValue && fits.value.glyphCount == 3 && fits.value.languageLength == 2
        && language == "en");
    const short_ = s.shape(ShapeRequest("abc", 0, 3, latin, true), two[], spans[], boundaries[], language[]);
    assert(short_.hasError && short_.error.limit == FontLimit.callerStorage && short_.error.needed == 3);
    assert(two == [ShapedGlyph(9), ShapedGlyph(9)]);
    SourceSpan[2] twoSpans;
    const shortSpans = s.shape(ShapeRequest("abc", 0, 3, latin, true), three[], twoSpans[], null, null);
    assert(shortSpans.hasError && shortSpans.error.needed == 3);
    // A language longer than its buffer is an error, not a truncation.
    char[3] tooShort;
    const shortLanguage = s.shape(ShapeRequest("abc", 0, 3, SegmentProperties(ShapingDirection.leftToRight,
        Tag("Latn"), "en-gb"), true), three[], spans[], null, tooShort[]);
    assert(shortLanguage.hasError && shortLanguage.error.needed == 5);

    // A default-initialized shaper refuses rather than crashing.
    Shaper unset;
    const refused = o.shape(unset, ShapeRequest("abc", 0, 3, latin, true));
    assert(refused.hasError && refused.error.kind == FontErrorKind.unsupportedEngine);
}

/// FTS8: explicit properties are used as given, even against the content.
@("shaping.FTS8.explicitPropertiesStand")
@system
unittest
{
    if (fontsPath() is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    auto inst = instanceOf(bundled("NotoSansArabic.ttf"));
    auto s = Shaper(inst);
    Outputs guessed, explicit;
    const g = shapeText(inst, "سلام", guessed.glyphs[], guessed.spans[], guessed.boundaries[],
        guessed.language[]);
    assert(g.hasValue && g.value.direction == ShapingDirection.rightToLeft && g.value.script == Tag("Arab")
        && g.value.directionGuessed);
    const e = explicit.shape(s, ShapeRequest("سلام", 0, 8, latin, true, null, true, true));
    assert(e.hasValue && e.value.direction == ShapingDirection.leftToRight && e.value.script == Tag("Latn"));
    assert(!e.value.directionGuessed && !e.value.scriptGuessed && !e.value.languageGuessed);
    assert(explicit.language[0 .. e.value.languageLength] == "en");
    // Left to right, clusters ascend.
    foreach (i; 1 .. e.value.glyphCount)
        assert(explicit.glyphs[i].cluster >= explicit.glyphs[i - 1].cluster);
}

/// FTS8: decomposition is one step, so a font without U+1E09 still gets ç + acute.
@("shaping.FTS8.singleStepDecomposition")
@system
unittest
{
    if (fontsPath() is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    const bytes = bundled("Uiua386.ttf");
    const map = openFace(bytes).value.charMap.value;
    assert(map.glyph('ḉ') == 0 && map.glyph('ç') != 0 && map.glyph('́') != 0);
    auto inst = instanceOf(bytes);
    auto s = Shaper(inst);
    Outputs o;
    const info = o.shape(s, ShapeRequest("ḉ", 0, 3, latin, true, null, true, true));
    assert(info.hasValue && info.value.glyphCount == 2);
    assert(o.glyphs[0].glyphId == map.glyph('ç') && o.glyphs[1].glyphId == map.glyph('́'));
    assert(info.value.spanCount == 1 && o.spans[0] == SourceSpan(0, 3, 0, 2));
}

/// Default ignorables are hidden, as stock HarfBuzz hides them: no `.notdef`, no advance.
@("shaping.defaultIgnorablesHidden")
@system
unittest
{
    if (fontsPath() is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    auto inst = instanceOf(bundled("DejaVuSansMono.ttf"));
    auto s = Shaper(inst);
    Outputs o;
    const info = o.shape(s, ShapeRequest("a‍b", 0, 5, latin, true, null, true, true));
    assert(info.hasValue && info.value.glyphCount == 3);
    assert(o.glyphs[1].glyphId != 0 && o.glyphs[1].xAdvance.raw == 0);
}

/**
FTS9: at every known boundary that is not unsafe-to-break, shaping the
two fragments with the full text as context reproduces the full run's
glyphs and positions; at an unsafe one, reshaping them as separate
lines changes the output, which is why the old glyphs cannot be cut.
*/
@("shaping.FTS9.fragmentsRecombine")
@system
unittest
{
    if (fontsPath() is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    static struct Sample
    {
        string face, source;
        SegmentProperties properties;
    }

    const samples = [
        Sample("NotoSansArabic.ttf", "سلام عليكم", arabic),
        Sample("NotoSans.ttf", "office affine", latin),
        Sample("NotoSansDevanagari.ttf", "क्षत्रिय हिन्दी",
            SegmentProperties(ShapingDirection.leftToRight, Tag("Deva"), "hi")),
    ];
    size_t reusable, unsafe, changed;
    foreach (sample; samples)
    {
        auto inst = instanceOf(bundled(sample.face));
        auto s = Shaper(inst);
        const src = sample.source;
        Outputs full;
        const whole = full.shape(s, ShapeRequest(src, 0, src.length, sample.properties, true, null, true, true));
        assert(whole.hasValue);
        const backward = isBackward(whole.value.direction);
        foreach (b; full.boundaries[0 .. whole.value.spanCount])
        {
            if (!b.known)
                continue;
            Outputs left, right;
            if (!b.unsafeToBreak)
            {
                // Fragments with context, no text boundary at the cut.
                const l = left.shape(s, ShapeRequest(src, 0, b.offset, sample.properties, true, null, true, false));
                const r = right.shape(s, ShapeRequest(src, b.offset, src.length, sample.properties, true, null,
                    false, true));
                assert(l.hasValue && r.hasValue);
                const n = l.value.glyphCount, m = r.value.glyphCount;
                assert(n + m == whole.value.glyphCount, text(sample.face, " at ", b.offset));
                // Pen order puts the later fragment first in a backward run.
                const first = backward ? right.glyphs[0 .. m] : left.glyphs[0 .. n];
                const second = backward ? left.glyphs[0 .. n] : right.glyphs[0 .. m];
                foreach (i, g; first ~ second)
                {
                    const w = full.glyphs[i];
                    assert(g.glyphId == w.glyphId && g.xAdvance == w.xAdvance && g.xOffset == w.xOffset
                        && g.yOffset == w.yOffset, text(sample.face, " at ", b.offset, " glyph ", i));
                }
                ++reusable;
            }
            else
            {
                // The cut becomes a line edge: reshape both sides as lines.
                const l = left.shape(s, ShapeRequest(src, 0, b.offset, sample.properties, true, null, true, true));
                const r = right.shape(s, ShapeRequest(src, b.offset, src.length, sample.properties, true, null,
                    true, true));
                assert(l.hasValue && r.hasValue);
                const first = backward ? right.glyphs[0 .. r.value.glyphCount] : left.glyphs[0 .. l.value.glyphCount];
                const second = backward ? left.glyphs[0 .. l.value.glyphCount] : right.glyphs[0 .. r.value.glyphCount];
                const joined = first ~ second;
                bool same = joined.length == whole.value.glyphCount;
                if (same)
                    foreach (i, g; joined)
                        same &= g.glyphId == full.glyphs[i].glyphId && g.xAdvance == full.glyphs[i].xAdvance;
                changed += !same;
                ++unsafe;
            }
        }
    }
    assert(reusable > 10 && unsafe > 0 && changed > 0, text(reusable, " reusable, ", unsafe, " unsafe, ",
        changed, " changed"));
}

/// FTS9: separately shaped joining fragments are unsafe to concatenate, and the engine says so.
@("shaping.FTS9.unsafeToConcat")
@system
unittest
{
    if (fontsPath() is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    auto inst = instanceOf(bundled("NotoSansArabic.ttf"));
    auto s = Shaper(inst);
    const word = "سلام";
    Outputs full;
    const whole = full.shape(s, ShapeRequest(word, 0, 8, arabic, true, null, true, true));
    assert(whole.hasValue);
    // Every interior boundary of a joined word is unsafe to concatenate.
    size_t interior;
    foreach (b; full.boundaries[0 .. whole.value.spanCount])
        if (b.known)
        {
            assert(b.unsafeToConcat, text("boundary at ", b.offset));
            ++interior;
        }
    assert(interior >= 2);
}

@("shaping.FTS11.justificationCandidates")
@system
unittest
{
    if (fontsPath() is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    auto inst = instanceOf(bundled("MapleMono-NF-CN-Regular.ttf"));
    auto s = Shaper(inst);
    Outputs candidate;
    foreach (mode; [JustificationMode.extenderInsertion, JustificationMode.kashidaInsertion,
            JustificationMode.maximumLookups])
    {
        const refused = measureJustificationCandidate(s, ShapeRequest("a!=b", 0, 4, latin, true), mode,
            candidate.glyphs[], candidate.spans[], candidate.boundaries[], candidate.language[]);
        assert(refused.hasError && refused.error.kind == FontErrorKind.unsupportedCapability);
    }
    // Both feature alternatives are measured by actual shaping.
    Outputs off;
    const on = measureJustificationCandidate(s, ShapeRequest("a!=b", 0, 4, latin, true),
        JustificationMode.featureSettings, candidate.glyphs[], candidate.spans[], candidate.boundaries[],
        candidate.language[]);
    const without = measureJustificationCandidate(s, ShapeRequest("a!=b", 0, 4, latin, true,
        [ShapingFeature.global(Tag("calt"), 0), ShapingFeature.global(Tag("liga"), 0)]),
        JustificationMode.featureSettings, off.glyphs[], off.spans[], off.boundaries[], off.language[]);
    assert(on.hasValue && without.hasValue && candidate.glyphs[1].glyphId != off.glyphs[1].glyphId);
}

/// FTS8: the dev shell runs the pinned engine, and a shaper refuses any other.
@("shaping.FTS8.profile")
@system
unittest
{
    const profile = engineProfile();
    assert(profile.compatible, text("the dev shell runs HarfBuzz ", profile.harfBuzzVersion));
    assert(profile.harfBuzzVersion == pinnedEngine.harfBuzzVersion);
    assert(profile.unicodeRelease == pinnedEngine.unicodeVersion);
}

/// FTS5: a shaper borrows its instance's bytes and cannot escape them in `@safe` code.
@("shaping.FTS5.cannotOutliveBytes")
@safe
unittest
{
    // Using a shaper over stack bytes is fine; returning it is not.
    static assert(__traits(compiles, () @safe {
        ubyte[64] stack;
        auto face = openFace(stack[]).value;
        auto inst = face.instance(InstanceSize.pixels(Ppem.fromInteger(16).value), null).value;
        auto s = Shaper(inst);
        return s.status;
    }));
    static assert(!__traits(compiles, () @safe {
        ubyte[64] stack;
        auto face = openFace(stack[]).value;
        auto inst = face.instance(InstanceSize.pixels(Ppem.fromInteger(16).value), null).value;
        return Shaper(inst);
    }));
}

/// FTS10: the carets of a shaped ligature name its glyph and source cluster, in record order.
@("shaping.FTS10.ligatureCarets")
@system
unittest
{
    auto ws = makeUnique!PointWorkspace();
    if (fontsPath() is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    foreach (weight; [400, 900])
    {
        auto inst = instanceOf(bundled("NotoSans.ttf"), [UserCoordinate(Tag("wght"), weight << 16)]);
        auto s = Shaper(inst);
        Outputs o;
        const info = o.shape(s, ShapeRequest("xfi", 0, 3, latin, true, null, true, true));
        assert(info.hasValue && info.value.glyphCount == 2);
        const ligature = o.glyphs[1];
        assert(ligature.cluster == 1);
        LigatureCaret[4] carets;
        const r = ligatureCarets(inst, ligature.glyphId, ligature.cluster, true, carets[], *ws);
        assert(r.hasValue && r.value.present && r.value.count >= 1);
        foreach (k, c; carets[0 .. r.value.count])
        {
            assert(c.glyphId == ligature.glyphId && c.cluster == 1 && c.recordIndex == k);
            // Inside the ligature's advance.
            assert(c.coordinate.raw > 0 && c.coordinate.raw < ligature.xAdvance.raw);
        }
        // The plain letter has none: absence, not synthesized spacing.
        const plain = ligatureCarets(inst, o.glyphs[0].glyphId, 0, true, carets[], *ws);
        assert(plain.hasValue && !plain.value.present);
    }
}

/**
The face for `operationBudget`: sixteen `A`s each run one contextual rule
whose `records` lookup records step the glyph id by one, so a glyph's id
says how many records reached it.
*/
private const(ubyte)[] budgetFace(uint records, bool positioning = false) @safe
{
    import sparkles.font.fixtures : contextSubst1, coverage1, coverage2, FeatureSpec, featureList, hhea,
        hmtx, layoutTable, LayoutLangSysSpec, LayoutScriptSpec, LookupSpec, lookupList, minimalTables,
        RuleSpec, scriptList, sfnt, singleSubst1, TableData, u16;

    auto steps = new uint[2][](records);
    steps[] = [0, 0]; // sequence index 0, lookup 0
    const step = LookupSpec(1, 0, [singleSubst1(coverage2([[1, records, 0]]), 1)]);
    const context = LookupSpec(5, 0, [contextSubst1(coverage1([1]), [[RuleSpec(null, steps)]])]);
    auto tables = minimalTables(records + 2);
    tables ~= TableData("hhea", hhea(1));
    tables ~= TableData("hmtx", hmtx([[500, 0]], new int[](records + 1)));
    const scripts = scriptList([LayoutScriptSpec("DFLT", true, LayoutLangSysSpec("", 0xFFFF, [0]))]);
    if (!positioning)
    {
        tables ~= TableData("GSUB", layoutTable(scripts, featureList([FeatureSpec("ccmp", [1])]),
            lookupList([step, context])));
        return sfnt(tables);
    }
    // The same rule in GPOS: each record adds one unit to the advance (SinglePos 1, XAdvance).
    const nudge = LookupSpec(1, 0, [u16(1) ~ u16(8) ~ u16(4) ~ u16(1) ~ coverage1([1])]);
    const contextPos = LookupSpec(7, 0, [contextSubst1(coverage1([1]), [[RuleSpec(null, steps)]])]);
    tables ~= TableData("GPOS", layoutTable(scripts, featureList([FeatureSpec("kern", [1])]),
        lookupList([nudge, contextPos])));
    return sfnt(tables);
}

/**
FTB3, FTS7: HarfBuzz's operation budget — 65,536 operations for this run of
sixteen glyphs — either holds or fails the call with `engineBuffer`; it never
stops applying lookups and returns the partial run as shaped. A substitution
record costs two operations and a positioning one, so the budget ends past
2,048 and 4,096 records. Unpatched, HarfBuzz returned the positioning runs
from 4,097 records on as shaped, the last glyph short of its records
(`nix/packages/harfbuzz-operation-budget.patch`).
*/
@("shaping.FTB3.operationBudget")
@system
unittest
{
    enum text16 = "AAAAAAAAAAAAAAAA";
    static immutable uint[2][] cases = [[100, 0], [2_048, 0], [2_049, 0], [3_000, 0],
        [100, 1], [4_096, 1], [4_097, 1], [5_000, 1]];
    foreach (c; cases)
    {
        const records = c[0], positioning = c[1] != 0;
        auto inst = instanceOf(budgetFace(records, positioning));
        auto s = Shaper(inst);
        Outputs o;
        const info = o.shape(s, ShapeRequest(text16, 0, text16.length, latin, true, null, true, true));
        const withinBudget = records <= (positioning ? 4_096 : 2_048);
        if (!withinBudget)
        {
            assert(info.hasError && info.error.kind == FontErrorKind.limitExceeded
                && info.error.limit == FontLimit.engineBuffer, text(c, " was returned as shaped"));
            continue;
        }
        assert(info.hasValue && info.value.glyphCount == 16, text(c));
        foreach (i, g; o.glyphs[0 .. 16])
        {
            // Every record reached every glyph.
            if (positioning)
                assert(g.glyphId == 1 && g.xAdvance.raw == (500L + records) << 16, text(c, " glyph ", i));
            else
                assert(g.glyphId == 1 + records, text(c, " glyph ", i));
        }
    }
}
