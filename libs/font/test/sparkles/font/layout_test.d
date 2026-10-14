/**
Layout inspection (FTI7–FTI9, FTM13, FTA11) on hand-built `GSUB` and `GPOS`
tables, hostile truncations and corruptions of them, and every bundled face.

Fixtures have 100 glyphs and, when variable, one `TEST` axis whose user
values equal their normalized values.
*/
module sparkles.font.layout_test;

import std.algorithm.searching : endsWith;
import std.file : dirEntries, SpanMode;
import std.path : baseName;

import sparkles.base.text.layout_units : LayoutUnit;
import sparkles.test_runner.skip : skipTest;

import sparkles.font.corpus : bundled, fontsPath;
import sparkles.font.errors : FontError, FontErrorKind, FontResult, Tag;
import sparkles.font.face : Face, openFace;
import sparkles.font.fixtures;
import sparkles.font.instance : Instance, instance, InstanceSize, UserCoordinate;
import sparkles.font.layout;

private enum one = 65_536; // 1.0 in F16.16
private enum f2one = 16_384; // 1.0 in F2Dot14
private enum gsub = LayoutTable.gsub, gpos = LayoutTable.gpos;

private immutable twelvePoints = InstanceSize.physical(LayoutUnit(12 * LayoutUnit.ticksPerPoint));

/// A face holding `gsub` and `gpos` (each when not null) and, when `variable`, the `TEST` axis.
private ubyte[] build(const(ubyte)[] gsubData, const(ubyte)[] gposData = null, bool variable = false)
    @safe pure nothrow
{
    auto tables = minimalTables(100);
    if (gposData !is null)
        tables ~= TableData("GPOS", gposData);
    if (gsubData !is null)
        tables ~= TableData("GSUB", gsubData);
    if (variable)
        tables ~= TableData("fvar", fvarTable([FvarAxis("TEST", -one, 0, one)]));
    return sfnt(tables);
}

private Face face(const(ubyte)[] bytes) @safe pure nothrow
{
    auto r = openFace(bytes);
    assert(r.hasValue);
    return r.value;
}

/// The instance of `bytes` at `TEST` = `coord` (F16.16).
private Instance at(const(ubyte)[] bytes, int coord) @safe pure nothrow
{
    auto r = face(bytes).instance(twelvePoints, [UserCoordinate(Tag("TEST"), coord)]);
    assert(r.hasValue);
    return r.value;
}

private FontErrorKind kind(R)(in R r) => r.error.kind;

/// The lookup indices of a feature, each checked to be readable.
private uint[] values(LayoutIndices indices) @safe pure nothrow
{
    uint[] r;
    foreach (i; indices)
        r ~= i.value;
    return r;
}

private uint[] glyphs(GlyphSequence s) @safe pure nothrow
{
    uint[] r;
    foreach (g; s)
        r ~= g;
    return r;
}

// ---------------------------------------------------------------------------
// The header (FTI7)
// ---------------------------------------------------------------------------

/// Two scripts: `DFLT` (default only) and `latn` (default, `DEU `, `TRK `); five features, four lookups.
private ubyte[] sampleLayout(const(ubyte)[] variations = null, uint minor = 0) @safe pure nothrow
{
    const scripts = scriptList([
        LayoutScriptSpec("DFLT", true, LayoutLangSysSpec("", 0xFFFF, [0, 1])),
        LayoutScriptSpec("latn", true, LayoutLangSysSpec("", 2, [0, 1]), [
            LayoutLangSysSpec("DEU ", 0xFFFF, [3, 9, 1]),
            LayoutLangSysSpec("TRK ", 4, []),
        ]),
    ]);
    const features = featureList([
        FeatureSpec("liga", [0, 1]),
        FeatureSpec("kern", [2]),
        FeatureSpec("rlig", [3]),
        FeatureSpec("locl", [1, 7]),
        FeatureSpec("ccmp", []),
    ]);
    const lookups = lookupList([
        LookupSpec(1, 0, [singleSubst1(coverage1([5]), 1)]),
        LookupSpec(1, 0x0010, [singleSubst1(coverage1([6]), 1)], 3),
        LookupSpec(4, 0x0008, null),
        LookupSpec(1, 0, [singleSubst1(coverage1([7]), 1)]),
    ]);
    return layoutTable(scripts, features, lookups, variations, minor);
}

@("layout.header.versions")
@safe pure nothrow
unittest
{
    assert(kind(layout(face(build(null)), gsub)) == FontErrorKind.missingTable);
    assert(kind(layoutScripts(face(build(null)), gpos)) == FontErrorKind.missingTable);
    assert(kind(layout(face(build(sampleLayout(null, 0)[0 .. 9])), gsub)) == FontErrorKind.truncated);
    assert(kind(layout(face(build(layoutTable(null, null, null, null, 1)[0 .. 13])), gsub))
        == FontErrorKind.truncated);
    auto v2 = sampleLayout();
    v2[0 .. 2] = [0, 2]; // major version 2
    assert(kind(layout(face(build(v2)), gsub)) == FontErrorKind.unsupportedVersion);
    const l = layout(face(build(sampleLayout())), gsub).value;
    assert(l.majorVersion == 1 && l.minorVersion == 0 && !l.hasFeatureVariations);
    assert(l.scriptCount == 2 && l.featureCount == 5 && l.lookupCount == 4);
    // Null lists are empty.
    const empty = layout(face(build(layoutTable(null, null, null))), gsub).value;
    assert(empty.scriptCount == 0 && empty.featureCount == 0 && empty.lookupCount == 0);
    assert(layoutScripts(face(build(layoutTable(null, null, null))), gsub).value.empty);
    // GPOS reads the same way.
    assert(layout(face(build(null, sampleLayout())), gpos).value.table == gpos);
    assert(kind(layout(face(build(null, sampleLayout())), gsub)) == FontErrorKind.missingTable);
}

@("layout.header.badLists")
@safe pure nothrow
unittest
{
    // A script list offset past the table: recorded, returned by the operations that read it.
    auto bytes = layoutTable(null, null, null);
    bytes[4 .. 6] = [0x40, 0x00];
    const f = face(build(bytes));
    assert(layout(f, gsub).hasValue);
    assert(kind(layoutScripts(f, gsub)) == FontErrorKind.badOffset);
    assert(kind(features(f, gsub, Tag("latn"), Tag.init)) == FontErrorKind.badOffset);
    // A lookup list whose offsets run past the table.
    const short_ = layoutTable(null, null, u16(5) ~ u16(0));
    assert(kind(lookup(face(build(short_)), gsub, 0)) == FontErrorKind.truncated);
}

// ---------------------------------------------------------------------------
// Scripts and language systems (FTI7)
// ---------------------------------------------------------------------------

@("layout.scripts.enumerate")
@safe pure nothrow
unittest
{
    const f = face(build(sampleLayout()));
    auto scripts = layoutScripts(f, gsub).value;
    assert(scripts.length == 2 && scripts.tag(0) == Tag("DFLT") && scripts.tag(1) == Tag("latn"));
    const dflt = scripts[0].value;
    assert(dflt.tag == Tag("DFLT") && dflt.hasDefaultLanguage && dflt.languages.empty);
    const dl = dflt.defaultLanguage.value;
    assert(dl.present && dl.tag.isNone && !dl.hasRequiredFeature && dl.requiredFeatureIndex == 0xFFFF);
    assert(values(dl.featureIndices) == [0, 1]);

    const latn = scripts[1].value;
    assert(latn.defaultLanguage.value.hasRequiredFeature && latn.defaultLanguage.value.requiredFeatureIndex == 2);
    auto langs = latn.languages;
    assert(langs.length == 2 && langs.tag(0) == Tag("DEU ") && langs.tag(1) == Tag("TRK "));
    assert(langs[0].value.tag == Tag("DEU "));
    // Index 9 is past the five features: that entry's badValue, the others readable.
    const deu = langs[0].value.featureIndices;
    assert(deu[0].value == 3 && kind(deu[1]) == FontErrorKind.badValue && deu[2].value == 1);
    assert(deu.raw[1] == 9);
    // Binary search by tag; Tag.init is the default; an unlisted language is absent.
    assert(latn.language(Tag("TRK ")).value.requiredFeatureIndex == 4);
    assert(latn.language(Tag.init).value.requiredFeatureIndex == 2);
    assert(!latn.language(Tag("FRA ")).value.present);
    // The range walks both ways.
    size_t n;
    foreach_reverse (s; layoutScripts(f, gsub).value)
        n += s.hasValue;
    assert(n == 2);
}

@("layout.scripts.partial")
@safe pure nothrow
unittest
{
    // Script 0's offset lies outside the table: that entry's badOffset; script 1 readable.
    const scripts = scriptList([
        LayoutScriptSpec("arab", true, LayoutLangSysSpec("", 0xFFFF, [0])),
        LayoutScriptSpec("latn", false, LayoutLangSysSpec.init, [
            LayoutLangSysSpec("DEU ", 0xFFFF, [0]),
            LayoutLangSysSpec("NLD ", 0xFFFF, [0]),
        ], 0, 0x7000),
    ], 0, 0x7000);
    const f = face(build(layoutTable(scripts, featureList([FeatureSpec("liga", [])]), null)));
    auto list = layoutScripts(f, gsub).value;
    assert(kind(list[0]) == FontErrorKind.badOffset && list.tag(0) == Tag("arab"));
    const latn = list[1].value;
    // No default language system: absent, not an error.
    assert(!latn.hasDefaultLanguage && !latn.defaultLanguage.value.present);
    assert(kind(latn.languages[0]) == FontErrorKind.badOffset && latn.languages[1].value.present);
    assert(kind(features(f, gsub, Tag("arab"), Tag.init)) == FontErrorKind.badOffset);
    assert(kind(features(f, gsub, Tag("latn"), Tag("DEU "))) == FontErrorKind.badOffset);
    assert(features(f, gsub, Tag("latn"), Tag("NLD ")).value.length == 1);
    // The default language system is absent: no features, not found.
    const none = features(f, gsub, Tag("latn"), Tag.init).value;
    assert(!none.found && none.empty);
}

// ---------------------------------------------------------------------------
// Features (FTI7)
// ---------------------------------------------------------------------------

@("layout.features.defaults")
@safe pure nothrow
unittest
{
    const f = face(build(sampleLayout()));
    // DFLT: no required feature.
    auto dflt = features(f, gsub, Tag("DFLT"), Tag.init).value;
    assert(dflt.found && dflt.length == 2 && dflt.langSys.present);
    assert(dflt[0].value.tag == Tag("liga") && dflt[0].value.index == 0 && !dflt[0].value.required);
    assert(values(dflt[0].value.lookups) == [0, 1] && dflt[0].value.lookups.raw.length == 2);
    assert(dflt[1].value.tag == Tag("kern") && values(dflt[1].value.lookups) == [2]);
    assert(!dflt.variation.value.applied);
    // latn default: the required feature first.
    auto latn = features(f, gsub, Tag("latn"), Tag.init).value;
    assert(latn.length == 3 && latn[0].value.required && latn[0].value.tag == Tag("rlig"));
    assert(latn[1].value.tag == Tag("liga") && !latn[1].value.required);
    // DEU: feature index 9 is badValue; lookup index 7 of `locl` is badValue; the rest readable.
    auto deu = features(f, gsub, Tag("latn"), Tag("DEU ")).value;
    assert(deu.length == 3 && deu[0].value.tag == Tag("locl"));
    const locl = deu[0].value.lookups;
    assert(locl[0].value == 1 && kind(locl[1]) == FontErrorKind.badValue);
    assert(kind(deu[1]) == FontErrorKind.badValue && deu[2].value.tag == Tag("kern"));
    // TRK: a required feature and no others.
    auto trk = features(f, gsub, Tag("latn"), Tag("TRK ")).value;
    assert(trk.length == 1 && trk[0].value.required && trk[0].value.tag == Tag("ccmp")
        && trk[0].value.lookups.empty);
    // An unlisted script or language: not found, empty.
    assert(!features(f, gsub, Tag("cyrl"), Tag.init).value.found);
    assert(!features(f, gsub, Tag("latn"), Tag("FRA ")).value.found);
    // As a range.
    size_t n;
    foreach (feature; latn)
        n += feature.hasValue;
    assert(n == 3);
}

@("layout.features.requiredOutOfRange")
@safe pure nothrow
unittest
{
    // A required feature index past the list is badValue; a bad feature record offset is badOffset.
    const scripts = scriptList([LayoutScriptSpec("latn", true, LayoutLangSysSpec("", 7, [0, 1]))]);
    const list = featureList([FeatureSpec("liga", [0]), FeatureSpec("kern", [0])], 1, 0x7000);
    const f = face(build(layoutTable(scripts, list, lookupList([LookupSpec(1, 0, null)]))));
    auto all = features(f, gsub, Tag("latn"), Tag.init).value;
    assert(all.length == 3 && kind(all[0]) == FontErrorKind.badValue);
    assert(all[1].value.tag == Tag("liga") && kind(all[2]) == FontErrorKind.badOffset);
    // A feature list that is unreadable: each feature its error.
    const broken = face(build(layoutTable(scripts, u16(9), null)));
    assert(kind(features(broken, gsub, Tag("latn"), Tag.init).value[1]) == FontErrorKind.truncated);
    // A lookup list that is unreadable: each lookup index its error.
    const noLookups = face(build(layoutTable(scripts, featureList([FeatureSpec("liga", [0]),
        FeatureSpec("kern", [])]), u16(9))));
    assert(kind(features(noLookups, gsub, Tag("latn"), Tag.init).value[1].value.lookups[0])
        == FontErrorKind.truncated);
}

// ---------------------------------------------------------------------------
// Lookups (FTI7)
// ---------------------------------------------------------------------------

@("layout.lookup.headers")
@safe pure nothrow
unittest
{
    const f = face(build(sampleLayout()));
    const l0 = lookup(f, gsub, 0).value;
    assert(l0.index == 0 && l0.type == 1 && l0.flag == 0 && l0.subtableCount == 1 && !l0.hasMarkFilteringSet);
    const l1 = lookup(f, gsub, 1).value;
    assert(l1.hasMarkFilteringSet && l1.markFilteringSet == 3 && l1.flag == 0x10);
    const l2 = lookup(f, gsub, 2).value;
    assert(l2.type == 4 && l2.flag == 8 && l2.subtableCount == 0);
    // A caller index past the list.
    assert(kind(lookup(f, gsub, 4)) == FontErrorKind.indexOutOfRange);
    assert(kind(substitutions(f, 4)) == FontErrorKind.indexOutOfRange);
    // A lookup offset outside the table; a mark filtering set past it.
    const bad = face(build(layoutTable(null, null, lookupList([LookupSpec(1, 0, null)], 0, 0x7000))));
    assert(kind(lookup(bad, gsub, 0)) == FontErrorKind.badOffset);
    const cut = layoutTable(null, null, lookupList([LookupSpec(1, 0x10, null, 2)]));
    assert(kind(lookup(face(build(cut[0 .. $ - 2])), gsub, 0)) == FontErrorKind.truncated);
}

// ---------------------------------------------------------------------------
// Feature variations (FTI8)
// ---------------------------------------------------------------------------

/**
`sampleLayout` 1.1 with three records: 0 holds for `TEST` in [0.5, 1.0] and
gives `liga` lookups [3]; 1 holds when an axis past the instance's reads 0
(and has a bad substitution index); 2 has an empty condition set and gives
`kern` lookups [0].
*/
private ubyte[] variedLayout() @safe pure nothrow
    => sampleLayout(featureVariations([
        FeatureVariationSpec([condition1(0, f2one / 2, f2one)], [FeatureSubstitutionSpec(0, [3])]),
        FeatureVariationSpec([condition1(0, -f2one, -f2one / 2), condition1(5, -100, 100)],
            [FeatureSubstitutionSpec(1, [1]), FeatureSubstitutionSpec(9, [2])]),
        FeatureVariationSpec(null, [FeatureSubstitutionSpec(1, [0])]),
    ]), 1);

@("layout.variations.selection")
@safe pure nothrow
unittest
{
    const bytes = build(variedLayout(), null, true);
    // On a face: the default lookups, no record.
    auto onFace = features(face(bytes), gsub, Tag("DFLT"), Tag.init).value;
    assert(!onFace.variation.value.applied && values(onFace[0].value.lookups) == [0, 1]);
    assert(layout(face(bytes), gsub).value.hasFeatureVariations);
    // At 0: record 0 fails, record 1 fails its first condition, record 2 (empty) holds.
    auto atZero = at(bytes, 0).features(gsub, Tag("DFLT"), Tag.init).value;
    assert(atZero.variation.value == VariationChoice(true, 2));
    assert(!atZero[0].value.substituted && values(atZero[0].value.lookups) == [0, 1]);
    assert(atZero[1].value.substituted && values(atZero[1].value.lookups) == [0]);
    // At 0.75 and both inclusive bounds: record 0.
    foreach (coord; [one / 2, 3 * one / 4, one])
    {
        auto fs = at(bytes, coord).features(gsub, Tag("DFLT"), Tag.init).value;
        assert(fs.variation.value == VariationChoice(true, 0));
        assert(fs[0].value.substituted && values(fs[0].value.lookups) == [3]);
        assert(!fs[1].value.substituted && values(fs[1].value.lookups) == [2]);
    }
    // At -0.75: record 1 holds, axis 5 past the instance reading 0 inside [-100, 100].
    auto low = at(bytes, -3 * one / 4).features(gsub, Tag("DFLT"), Tag.init).value;
    assert(low.variation.value == VariationChoice(true, 1));
    assert(values(low[1].value.lookups) == [1]);
    // Just outside record 0's lower bound.
    auto below = at(bytes, one / 2 - 4).features(gsub, Tag("DFLT"), Tag.init).value;
    assert(below.variation.value.recordIndex == 2);
}

@("layout.variations.inspection")
@safe pure nothrow
unittest
{
    const bytes = build(variedLayout(), null, true);
    const f = face(bytes);
    assert(featureVariationCount(f, gsub).value == 3);
    assert(featureVariationCount(face(build(sampleLayout(), null, true)), gsub).value == 0);
    const inst = at(bytes, 3 * one / 4);
    assert(featureVariation(inst, gsub, 0).value == FeatureVariationRecord(0, true));
    assert(featureVariation(inst, gsub, 1).value == FeatureVariationRecord(1, false));
    assert(featureVariation(inst, gsub, 2).value.holds);
    assert(kind(featureVariation(inst, gsub, 3)) == FontErrorKind.indexOutOfRange);
    // Record 1's second substitution names feature 9, past the five: badValue; the first is readable.
    auto subs = featureSubstitutions(f, gsub, 1).value;
    assert(subs.length == 2 && subs.featureIndex(1) == 9);
    assert(subs[0].value.featureIndex == 1 && values(subs[0].value.lookups) == [1]);
    assert(kind(subs[1]) == FontErrorKind.badValue);
    assert(kind(featureSubstitutions(f, gsub, 3)) == FontErrorKind.indexOutOfRange);
}

@("layout.variations.unsupportedCondition")
@safe pure nothrow
unittest
{
    // Record 0 has a format-2 condition: it never holds and inspection reports
    // unsupportedVersion; record 1 (empty) is chosen.
    const format2 = u16(2) ~ u16(0) ~ u16(0) ~ u16(0);
    const bytes = build(sampleLayout(featureVariations([
        FeatureVariationSpec([format2], [FeatureSubstitutionSpec(0, [3])]),
        FeatureVariationSpec([], [FeatureSubstitutionSpec(0, [2])]),
    ]), 1), null, true);
    const inst = at(bytes, 0);
    assert(kind(featureVariation(inst, gsub, 0)) == FontErrorKind.unsupportedVersion);
    assert(featureVariation(inst, gsub, 1).value.holds);
    auto fs = inst.features(gsub, Tag("DFLT"), Tag.init).value;
    assert(fs.variation.value == VariationChoice(true, 1) && values(fs[0].value.lookups) == [2]);
}

@("layout.variations.substitutedFeatureIndexPastList")
@safe pure nothrow
unittest
{
    // A chosen record whose only substitution names feature 9: badValue there, and every feature keeps its
    // default lookups.
    const bytes = build(sampleLayout(featureVariations([
        FeatureVariationSpec(null, [FeatureSubstitutionSpec(9, [3])]),
    ]), 1), null, true);
    auto fs = at(bytes, 0).features(gsub, Tag("DFLT"), Tag.init).value;
    assert(fs.variation.value == VariationChoice(true, 0));
    assert(!fs[0].value.substituted && values(fs[0].value.lookups) == [0, 1]);
    assert(kind(featureSubstitutions(face(bytes), gsub, 0).value[0]) == FontErrorKind.badValue);
}

@("layout.variations.broken")
@safe pure nothrow
unittest
{
    // A FeatureVariations offset past the table: the face's features keep their defaults; at an instance each
    // feature, and the choice, is the error.
    auto bytes = sampleLayout(null, 1);
    bytes[10 .. 14] = [0, 0, 0x70, 0];
    const b = build(bytes, null, true);
    assert(features(face(b), gsub, Tag("DFLT"), Tag.init).value[0].hasValue);
    auto fs = at(b, 0).features(gsub, Tag("DFLT"), Tag.init).value;
    assert(kind(fs.variation) == FontErrorKind.badOffset && kind(fs[0]) == FontErrorKind.badOffset);
    assert(kind(featureVariationCount(face(b), gsub)) == FontErrorKind.badOffset);
    // A chosen record whose substitution table has major version 2: every feature is unsupportedVersion.
    const v2 = build(sampleLayout(featureVariations([
        FeatureVariationSpec(null, [FeatureSubstitutionSpec(0, [3])], false, false, 2),
    ]), 1), null, true);
    auto chosen = at(v2, 0).features(gsub, Tag("DFLT"), Tag.init).value;
    assert(kind(chosen.variation) == FontErrorKind.unsupportedVersion);
    assert(kind(chosen[1]) == FontErrorKind.unsupportedVersion);
    // A null substitution offset: the record holds and substitutes nothing.
    const nullSubst = build(sampleLayout(featureVariations([
        FeatureVariationSpec(null, null, false, true),
    ]), 1), null, true);
    auto plain = at(nullSubst, 0).features(gsub, Tag("DFLT"), Tag.init).value;
    assert(plain.variation.value.applied && !plain[0].value.substituted);
    assert(featureSubstitutions(face(nullSubst), gsub, 0).value.empty);
}

// ---------------------------------------------------------------------------
// Substitutions (FTI9)
// ---------------------------------------------------------------------------

/// A face whose `GSUB` has one lookup per entry of `lookups`, and no scripts or features.
private Face gsubFace(const(LookupSpec)[] lookups) @safe pure nothrow
    => face(build(layoutTable(null, null, lookupList(lookups))));

/// Every record of lookup `index`: a value's input and output glyphs, or an error's kind.
private struct Walked
{
    uint[][] inputs, outputs;
    FontErrorKind[] errors;
    size_t[] errorAt; // the element index of each error
    Substitution[] records;
}

private Walked walk(const Face f, uint index) @safe pure nothrow
{
    Walked w;
    size_t n;
    foreach (r; substitutions(f, index).value)
    {
        if (r.hasValue)
        {
            w.inputs ~= glyphs(r.value.input);
            w.outputs ~= glyphs(r.value.output);
            w.records ~= r.value;
        }
        else
        {
            w.errors ~= r.error.kind;
            w.errorAt ~= n;
        }
        ++n;
    }
    return w;
}

@("layout.substitutions.single")
@safe pure nothrow
unittest
{
    const f = gsubFace([
        LookupSpec(1, 0, [singleSubst1(coverage2([[10, 12, 0]]), 5), singleSubst1(coverage1([3, 0xFFFF]), -4)]),
        LookupSpec(1, 0, [singleSubst2(coverage1([20, 21, 22]), [30, 31])]),
    ]);
    // Format 1: (g + delta) mod 65,536, both ways round.
    const w = walk(f, 0);
    assert(w.inputs == [[10], [11], [12], [3], [0xFFFF]]);
    assert(w.outputs == [[15], [16], [17], [0xFFFF], [0xFFFB]]);
    assert(w.records[0].lookupType == 1 && w.records[0].format == 1 && w.records[3].subtable == 1);
    assert(w.records[0].output.hasLeadingGlyph && w.records[0].output.run.empty);
    // Format 2: glyph 22's coverage index 2 is past the two substitutes — that record's badValue.
    const w2 = walk(f, 1);
    assert(w2.inputs == [[20], [21]] && w2.outputs == [[30], [31]]);
    assert(w2.errors == [FontErrorKind.badValue] && w2.errorAt == [2]);
}

@("layout.substitutions.multipleAndAlternate")
@safe pure nothrow
unittest
{
    const f = gsubFace([
        LookupSpec(2, 0, [multipleSubst(coverage1([4, 5, 6]), [[40, 41, 42], []])]),
        LookupSpec(3, 0, [alternateSubst(coverage1([7, 8]), [[70, 71, 72], [80]])]),
    ]);
    // A sequence may be empty (a deletion); glyph 6 has no sequence: badValue, and the walk continues.
    const w = walk(f, 0);
    assert(w.inputs == [[4], [5]] && w.outputs == [[40, 41, 42], []]);
    assert(w.errors == [FontErrorKind.badValue]);
    const seq = w.records[0].output;
    assert(seq.length == 3 && seq[1] == 41 && seq.back == 42 && !seq.hasLeadingGlyph && seq.run.length == 3);
    // One record per alternate.
    const a = walk(f, 1);
    assert(a.inputs == [[7], [7], [7], [8]] && a.outputs == [[70], [71], [72], [80]]);
    assert(a.records[2].alternateIndex == 2 && a.records[3].alternateIndex == 0);
}

@("layout.substitutions.ligature")
@safe pure nothrow
unittest
{
    const f = gsubFace([LookupSpec(4, 0, [ligatureSubst(coverage1([1, 2]), [
        [LigatureSpec(50, [2, 3]), LigatureSpec(51, [2])],
        [LigatureSpec(52, [])],
    ])])]);
    const w = walk(f, 0);
    assert(w.inputs == [[1, 2, 3], [1, 2], [2]] && w.outputs == [[50], [51], [52]]);
    // The input is the coverage glyph, then a borrowed run of the components.
    const input = w.records[0].input;
    assert(input.hasLeadingGlyph && input.leadingGlyph == 1 && input.run.length == 2 && input.length == 3);
    assert(input[0] == 1 && input[2] == 3);
    // A component count of 0 is that ligature's badValue; the next one is readable.
    auto bytes = ligatureSubst(coverage1([1]), [[LigatureSpec(60, [5]), LigatureSpec(61, [6])]]);
    // The first ligature's componentCount: subtable 8 + coverage-less set (2 + 2·2) + glyph.
    bytes[8 + 6 + 2 .. 8 + 6 + 4] = [0, 0];
    const z = walk(gsubFace([LookupSpec(4, 0, [bytes])]), 0);
    assert(z.errors == [FontErrorKind.badValue] && z.outputs == [[61]]);
}

@("layout.substitutions.context")
@safe pure nothrow
unittest
{
    const f = gsubFace([
        // Format 1: glyph 10 has two rules; glyph 11 a null rule set.
        LookupSpec(5, 0, [contextSubst1(coverage1([10, 11]), [
            [RuleSpec([12, 13], [[0, 1], [2, 0]]), RuleSpec([], [[0, 1]])],
            null,
        ])]),
        // Format 2: class 0 has no rule set, class 1 one rule over classes.
        LookupSpec(5, 0, [contextSubst2(coverage1([10]), [null, [RuleSpec([2], [[1, 1]])]])]),
        // Format 3: three input coverages.
        LookupSpec(5, 0, [contextSubst3([coverage1([1]), coverage1([2]), coverage1([3])], [[2, 0], [5, 1]])]),
    ]);
    const w = walk(f, 0);
    assert(w.inputs == [[10, 12, 13], [10]] && w.errors.length == 0);
    const r = w.records[0];
    assert(r.contextInput == ContextInput.glyphs && r.inputCount == 3 && !r.hasContext);
    assert(r.lookups.length == 2 && r.lookups[0].value == SequenceLookup(0, 1));
    // Lookup index 1 of the three is fine; sequence index 2 within the three inputs too.
    assert(r.lookups[1].value == SequenceLookup(2, 0));
    assert(w.records[1].inputCount == 1 && w.records[1].lookups.length == 1);
    // Format 2: the leading class is the rule set's.
    const c = walk(f, 1);
    assert(c.inputs == [[1, 2]] && c.records[0].contextInput == ContextInput.classes);
    // Format 3: one record with counts; sequence index 5 is past the three inputs (badValue).
    const t = walk(f, 2);
    assert(t.records.length == 1 && t.records[0].contextInput == ContextInput.coverages);
    assert(t.records[0].inputCount == 3 && t.records[0].input.empty);
    assert(t.records[0].lookups[0].value == SequenceLookup(2, 0));
    assert(kind(t.records[0].lookups[1]) == FontErrorKind.badValue);
}

@("layout.substitutions.chainedContext")
@safe pure nothrow
unittest
{
    const f = gsubFace([
        LookupSpec(6, 0, [contextSubst1(coverage1([10]), [[RuleSpec([11], [[1, 0]], [8, 9], [12])]], true)]),
        LookupSpec(6, 0, [contextSubst2(coverage1([10]), [[RuleSpec([3], [[0, 7]], [1], [])]], true)]),
        LookupSpec(6, 0, [chainContextSubst3([coverage1([1])], [coverage1([2]), coverage1([3])], [],
            [[1, 2]])]),
    ]);
    const r = walk(f, 0).records[0];
    assert(glyphs(r.input) == [10, 11] && glyphs(r.backtrack) == [8, 9] && glyphs(r.lookahead) == [12]);
    assert(r.backtrackCount == 2 && r.lookaheadCount == 1 && r.hasContext && r.inputCount == 2);
    assert(r.lookups[0].value == SequenceLookup(1, 0));
    // Format 2: lookup index 7 is past the three lookups: badValue.
    const c = walk(f, 1).records[0];
    assert(glyphs(c.input) == [0, 3] && glyphs(c.backtrack) == [1] && c.contextInput == ContextInput.classes);
    assert(kind(c.lookups[0]) == FontErrorKind.badValue);
    // Format 3: counts only.
    const t = walk(f, 2).records[0];
    assert(t.backtrackCount == 1 && t.inputCount == 2 && t.lookaheadCount == 0 && t.backtrack.empty);
    assert(t.lookups[0].value == SequenceLookup(1, 2));
}

@("layout.substitutions.reverseChain")
@safe pure nothrow
unittest
{
    const f = gsubFace([LookupSpec(8, 0, [
        reverseChainSubst(coverage1([5, 6, 7]), [coverage1([1])], [coverage1([2]), coverage1([3])], [50, 60]),
        reverseChainSubst(coverage1([9]), [], [], [90]),
    ])]);
    const w = walk(f, 0);
    assert(w.inputs == [[5], [6], [9]] && w.outputs == [[50], [60], [90]]);
    assert(w.errors == [FontErrorKind.badValue] && w.errorAt == [2]);
    assert(w.records[0].backtrackCount == 1 && w.records[0].lookaheadCount == 2 && w.records[0].hasContext);
    assert(w.records[0].contextInput == ContextInput.coverages && w.records[0].lookupType == 8);
    assert(!w.records[2].hasContext);
}

@("layout.substitutions.extension")
@safe pure nothrow
unittest
{
    const single = singleSubst1(coverage1([3]), 1);
    const f = gsubFace([
        LookupSpec(7, 0, [extensionSubst(1, single), extensionSubst(1, singleSubst2(coverage1([4]), [40]))]),
        // An extension of an extension, then a type differing from the first: each its subtable's badValue.
        LookupSpec(7, 0, [extensionSubst(1, single), extensionSubst(7, extensionSubst(1, single)),
            extensionSubst(2, multipleSubst(coverage1([4]), [[1, 2]])), extensionSubst(1, single)]),
        // An extension of format 2: unsupportedVersion.
        LookupSpec(7, 0, [extensionSubst(1, single, 2)]),
    ]);
    const w = walk(f, 0);
    assert(w.inputs == [[3], [4]] && w.outputs == [[4], [40]]);
    assert(w.records[0].extension && w.records[0].lookupType == 1 && w.records[1].format == 2);
    const bad = walk(f, 1);
    assert(bad.outputs == [[4], [4]]);
    assert(bad.errors == [FontErrorKind.badValue, FontErrorKind.badValue] && bad.errorAt == [1, 2]);
    assert(walk(f, 2).errors == [FontErrorKind.unsupportedVersion]);
}

@("layout.substitutions.errorsContinue")
@safe pure nothrow
unittest
{
    // A null subtable offset, an unknown format, a broken coverage, then a good subtable.
    auto brokenCoverage = singleSubst1(coverage1([3]), 1);
    brokenCoverage[6 .. 8] = [0, 9]; // coverage format 9
    const f = gsubFace([
        LookupSpec(1, 0, [null, u16(3) ~ u16(0) ~ u16(0), brokenCoverage, singleSubst1(coverage1([8]), 1)]),
        LookupSpec(9, 0, [singleSubst1(coverage1([8]), 1)]),
        LookupSpec(4, 0, [setSubst(1, coverage1([1, 2]), [null, u16(0)])]),
    ]);
    const w = walk(f, 0);
    assert(w.errors == [FontErrorKind.badOffset, FontErrorKind.unsupportedVersion,
        FontErrorKind.unsupportedVersion]);
    assert(w.outputs == [[9]]);
    // A lookup type outside 1–8.
    assert(kind(substitutions(f, 1)) == FontErrorKind.badValue);
    // A null ligature set is that entry's badOffset; an empty set yields nothing.
    assert(walk(f, 2).errors == [FontErrorKind.badOffset] && walk(f, 2).records.length == 0);
    // Not a GSUB face, and GPOS is never walked.
    assert(kind(substitutions(face(build(null, sampleLayout())), 0)) == FontErrorKind.missingTable);
}

@("layout.substitutions.lazyAndSave")
@safe pure nothrow
unittest
{
    const f = gsubFace([LookupSpec(1, 0, [singleSubst1(coverage2([[0, 0xFFFF, 0]]), 1)])]);
    // A coverage of every glyph is walked lazily: take three, save, and continue independently.
    auto s = substitutions(f, 0).value;
    s.popFront();
    auto copy = s.save;
    s.popFront();
    assert(glyphs(copy.front.value.input) == [1] && glyphs(s.front.value.input) == [2]);
    size_t n;
    foreach (r; substitutions(f, 0).value)
        ++n;
    assert(n == 65_536);
}

// ---------------------------------------------------------------------------
// Hostile input (FTB1–FTB3)
// ---------------------------------------------------------------------------

/// Every operation on `bytes`, with walks capped at `cap` records; no assertion is reachable.
private void exercise(const(ubyte)[] bytes, size_t cap = 512) @safe pure nothrow
{
    const opened = openFace(bytes);
    if (!opened.hasValue)
        return;
    const f = opened.value;
    const inst = f.instance(twelvePoints, [UserCoordinate(Tag("TEST"), one / 2)]);
    foreach (table; [gsub, gpos])
    {
        const scripts = layoutScripts(f, table);
        if (scripts.hasValue)
            foreach (i; 0 .. scripts.value.length)
            {
                const tag = scripts.value.tag(i);
                const s = scripts.value[i];
                if (s.hasValue)
                {
                    cast(void) s.value.defaultLanguage;
                    foreach (lang; s.value.languages)
                        if (lang.hasValue)
                            foreach (index; lang.value.featureIndices) {}
                    foreach (langTag; [Tag.init, Tag("DEU "), Tag("TRK ")])
                        foreach (fs; [features(f, table, tag, langTag), inst.hasValue
                            ? inst.value.features(table, tag, langTag) : features(f, table, tag, langTag)])
                            if (fs.hasValue)
                            {
                                cast(void) fs.value.variation;
                                foreach (feature; fs.value)
                                    if (feature.hasValue)
                                        foreach (l; feature.value.lookups) {}
                            }
                }
            }
        const count = featureVariationCount(f, table);
        if (count.hasValue)
            foreach (r; 0 .. count.value < 8 ? count.value : 8)
            {
                if (inst.hasValue)
                    cast(void) featureVariation(inst.value, table, r);
                auto subs = featureSubstitutions(f, table, r);
                if (subs.hasValue)
                    foreach (sub; subs.value) {}
            }
        foreach (i; 0 .. 8)
            cast(void) lookup(f, table, i);
    }
    foreach (i; 0 .. 16)
    {
        auto subs = substitutions(f, i);
        if (!subs.hasValue)
            continue;
        size_t n;
        foreach (r; subs.value)
        {
            if (++n > cap)
                break;
            if (!r.hasValue)
                continue;
            foreach (g; r.value.input) {}
            foreach (g; r.value.output) {}
            foreach (g; r.value.backtrack) {}
            foreach (g; r.value.lookahead) {}
            foreach (l; r.value.lookups) {}
        }
    }
}

/// A `GSUB` 1.1 with scripts, features, variations and one lookup of every type and format.
private ubyte[] hostileGsub() @safe pure nothrow
{
    const lookups = lookupList([
        LookupSpec(1, 0, [singleSubst1(coverage1([3]), 1), singleSubst2(coverage2([[4, 5, 0]]), [40, 50])]),
        LookupSpec(2, 0, [multipleSubst(coverage1([4]), [[1, 2]])]),
        LookupSpec(3, 0x10, [alternateSubst(coverage1([7]), [[70, 71]])], 1),
        LookupSpec(4, 0, [ligatureSubst(coverage1([1]), [[LigatureSpec(50, [2, 3])]])]),
        LookupSpec(5, 0, [contextSubst1(coverage1([10]), [[RuleSpec([12], [[0, 1]])]]),
            contextSubst2(coverage1([10]), [null, [RuleSpec([2], [[1, 1]])]]),
            contextSubst3([coverage1([1]), coverage1([2])], [[1, 0]])]),
        LookupSpec(6, 0, [contextSubst1(coverage1([10]), [[RuleSpec([11], [[1, 0]], [8], [12])]], true),
            contextSubst2(coverage1([10]), [[RuleSpec([3], [[0, 0]], [1], [2])]], true),
            chainContextSubst3([coverage1([1])], [coverage1([2])], [coverage1([3])], [[0, 2]])]),
        LookupSpec(7, 0, [extensionSubst(4, ligatureSubst(coverage1([1]), [[LigatureSpec(52, [9])]]))]),
        LookupSpec(8, 0, [reverseChainSubst(coverage1([5]), [coverage1([1])], [coverage1([2])], [55])]),
    ]);
    const variations = featureVariations([
        FeatureVariationSpec([condition1(0, f2one / 4, f2one)], [FeatureSubstitutionSpec(0, [3])]),
        FeatureVariationSpec(null, [FeatureSubstitutionSpec(1, [2])]),
    ]);
    const scripts = scriptList([
        LayoutScriptSpec("DFLT", true, LayoutLangSysSpec("", 1, [0])),
        LayoutScriptSpec("latn", true, LayoutLangSysSpec("", 0xFFFF, [0, 1]), [LayoutLangSysSpec("DEU ", 0, [1])]),
    ]);
    return layoutTable(scripts, featureList([FeatureSpec("liga", [0, 3]), FeatureSpec("ccmp", [1, 7])]), lookups,
        variations, 1);
}

@("layout.hostile.truncations")
@safe pure nothrow
unittest
{
    const full = hostileGsub();
    foreach (n; 0 .. full.length)
        exercise(build(full[0 .. n], full[0 .. n], true));
}

@("layout.hostile.corruptions")
@safe pure nothrow
unittest
{
    // Every byte set to 0xFF, then to 0x00, one at a time.
    const full = hostileGsub();
    foreach (i; 0 .. full.length)
        foreach (ubyte value; [0xFF, 0x00])
        {
            auto bytes = full.dup;
            bytes[i] = value;
            exercise(build(bytes, null, true), 256);
        }
}

@("layout.hostile.wellFormed")
@safe pure nothrow
unittest
{
    // The intact table reads without errors in every walk.
    const f = face(build(hostileGsub(), null, true));
    foreach (i; 0 .. 8)
        foreach (r; substitutions(f, i).value)
            assert(r.hasValue);
    auto fs = features(f, gsub, Tag("latn"), Tag("DEU ")).value;
    assert(fs.length == 2 && fs[0].value.required && fs[0].value.tag == Tag("liga"));
}

// ---------------------------------------------------------------------------
// The corpus
// ---------------------------------------------------------------------------

/**
Every bundled face's scripts, features and lookups enumerate, and every `GSUB`
lookup's substitutions walk, with a defined outcome. The HarfBuzz
differential comes with the oracle slice.
*/
@("layout.corpus.everyFace")
@system
unittest
{
    if (fontsPath is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    size_t faces, withGsub, records, errors;
    foreach (entry; dirEntries(fontsPath, SpanMode.shallow))
    {
        if (!entry.name.endsWith(".ttf") && !entry.name.endsWith(".otf"))
            continue;
        const opened = openFace(bundled(baseName(entry.name)));
        if (!opened.hasValue)
            continue;
        const f = opened.value;
        ++faces;
        const inst = f.instance(twelvePoints, null).value;
        foreach (table; [gsub, gpos])
        {
            const scripts = layoutScripts(f, table);
            if (!scripts.hasValue)
                continue;
            foreach (i; 0 .. scripts.value.length)
            {
                const s = scripts.value[i];
                if (!s.hasValue)
                    continue;
                foreach (lang; s.value.languages)
                    if (lang.hasValue)
                    {
                        auto fs = inst.features(table, s.value.tag, lang.value.tag);
                        if (fs.hasValue)
                            foreach (feature; fs.value)
                                if (feature.hasValue)
                                    foreach (l; feature.value.lookups) {}
                    }
                auto fs = features(f, table, s.value.tag, Tag.init);
                if (fs.hasValue)
                    foreach (feature; fs.value) {}
            }
            const l = layout(f, table).value;
            foreach (i; 0 .. l.lookupCount)
                cast(void) lookup(f, table, i);
        }
        if (!f.has(Tag("GSUB")))
            continue;
        ++withGsub;
        const count = layout(f, gsub);
        if (!count.hasValue)
            continue;
        foreach (i; 0 .. count.value.lookupCount)
        {
            auto subs = substitutions(f, i);
            if (!subs.hasValue)
                continue;
            foreach (r; subs.value)
            {
                ++records;
                errors += r.hasError;
                if (r.hasValue)
                    foreach (g; r.value.input) {}
            }
        }
    }
    assert(faces > 50 && withGsub > 10 && records > 1_000);
}
