/**
The M2 inspection differentials (`variation-metrics.md` § 9): `GSUB` and
`GPOS` scripts, language systems, features and lookups (FTI7), the glyphs of
`GSUB` substitution records (FTI9), and colour capabilities (FTI10), against
HarfBuzz over every bundled face. Each listed divergence is excluded where it
arises and counted, and each test prints its counts.
*/
module sparkles.font_oracle.inspection;

import std.file : read;
import std.path : baseName;
import std.stdio : stderr;

import sparkles.font;
import sparkles.font_oracle.corpus : corpus, Oracle;
import sparkles.font_oracle.harfbuzz_c;
import sparkles.test_runner.skip : skipTest;

/// The bundled faces with their HarfBuzz faces; `skipTest` when unset.
private void eachFace(scope void delegate(string file, const Face face, ref Oracle hb) @system body_)
{
    const files = corpus();
    if (files is null)
        skipTest("SPARKLES_FONTS_PATH is unset");
    foreach (path; files)
    {
        const bytes = cast(const(ubyte)[]) read(path);
        auto hb = Oracle(bytes, 0);
        scope (exit) hb.close();
        const opened = openFace(bytes);
        assert(opened.hasValue, path.baseName);
        body_(path.baseName, opened.value, hb);
    }
}

/// HarfBuzz's whole list from a `start_offset`/`count` getter.
private T[] all(T)(scope uint delegate(uint start, uint* count, T* items) @system get)
{
    uint total = get(0, null, null);
    // Called with a null count, HarfBuzz returns the total without writing.
    auto r = new T[total];
    uint count = total;
    get(0, &count, r.ptr);
    assert(count == total);
    return r;
}

/// The stored values of `indices`.
private uint[] raw(in LayoutIndices indices)
{
    uint[] r;
    foreach (v; indices.raw)
        r ~= v;
    return r;
}

@("oracle.layout.scriptsFeaturesLookups")
@system
unittest
{
    size_t tables, absent, rejected, scripts, langSystems, features, lookupLists;
    eachFace((file, face, ref hb) {
        foreach (table; [LayoutTable.gsub, LayoutTable.gpos])
        {
            const tag = layoutTag(table).value;
            const hbScripts = all!uint((s, c, t) => hb_ot_layout_table_get_script_tags(hb.face, tag, s, c, t));
            const ours = face.layoutScripts(table);
            if (ours.hasError && ours.error.kind == FontErrorKind.missingTable)
            {
                assert(hbScripts.length == 0, file);
                ++absent;
                continue;
            }
            assert(ours.hasValue, file);
            const list = ours.value;
            // § 9: HarfBuzz rejects a whole table when one part fails its checks.
            if (list.length > 0 && hbScripts.length == 0)
            {
                ++rejected;
                continue;
            }
            ++tables;
            const featureTags = all!uint((s, c, t) => hb_ot_layout_table_get_feature_tags(hb.face, tag, s, c, t));
            assert(face.layout(table).value.featureCount == featureTags.length, file);
            assert(face.layout(table).value.lookupCount == hb_ot_layout_table_get_lookup_count(hb.face, tag),
                file);
            assert(list.length == hbScripts.length, file);
            foreach (si; 0 .. list.length)
            {
                assert(list.tag(si).value == hbScripts[si], file);
                const script = list[si];
                assert(script.hasValue, file);
                ++scripts;
                const languages = script.value.languages;
                const hbLanguages = all!uint((s, c, t)
                    => hb_ot_layout_script_get_language_tags(hb.face, tag, cast(uint) si, s, c, t));
                assert(languages.length == hbLanguages.length, file);
                foreach (li; 0 .. languages.length)
                    assert(languages.tag(li).value == hbLanguages[li], file);

                // The default language system, then each listed one.
                foreach (li; -1 .. cast(long) languages.length)
                {
                    const hbIndex = li < 0 ? HB_OT_LAYOUT_DEFAULT_LANGUAGE_INDEX : cast(uint) li;
                    const ls = li < 0 ? script.value.defaultLanguage : languages[cast(size_t) li];
                    assert(ls.hasValue, file);
                    const sys = ls.value;
                    const hbFeatures = all!uint((s, c, t) => hb_ot_layout_language_get_feature_indexes(hb.face,
                        tag, cast(uint) si, hbIndex, s, c, t));
                    uint hbRequired;
                    hb_tag_t hbRequiredTag;
                    const hasRequired = hb_ot_layout_language_get_required_feature(hb.face, tag,
                        cast(uint) si, hbIndex, &hbRequired, &hbRequiredTag) != 0;
                    if (!sys.present)
                    {
                        // HarfBuzz reads an absent default language system as empty.
                        assert(hbFeatures.length == 0 && !hasRequired, file);
                        continue;
                    }
                    ++langSystems;
                    assert(raw(sys.featureIndices) == hbFeatures, file);
                    assert(sys.hasRequiredFeature == hasRequired, file);
                    if (hasRequired)
                        assert(sys.requiredFeatureIndex == hbRequired, file);

                    // Each feature's tag and default lookups (no variation applied).
                    const langTag = li < 0 ? Tag.init : languages.tag(cast(size_t) li);
                    auto fs = face.features(table, list.tag(si), langTag);
                    assert(fs.hasValue && fs.value.found, file);
                    Features range = fs.value;
                    foreach (f; range)
                    {
                        assert(f.hasValue, file);
                        ++features;
                        assert(f.value.tag.value == featureTags[f.value.index], file);
                        const hbLookups = all!uint((s, c, t)
                            => hb_ot_layout_feature_get_lookups(hb.face, tag, f.value.index, s, c, t));
                        assert(raw(f.value.lookups) == hbLookups, file);
                        ++lookupLists;
                    }
                }
            }
        }
    });
    stderr.writefln("oracle.layout.scriptsFeaturesLookups: %s tables, %s scripts, %s language systems, "
        ~ "%s features, %s lookup lists agree; %s tables absent on both sides; excluded: %s tables "
        ~ "HarfBuzz rejected whole",
        tables, scripts, langSystems, features, lookupLists, absent, rejected);
    assert(tables > 100 && features > 1_000);
}

/// The set of `glyphs`.
private hb_set_t* toSet(const(uint)[] glyphs)
{
    auto s = hb_set_create();
    foreach (g; glyphs)
        hb_set_add(s, g);
    return s;
}

@("oracle.layout.substitutionGlyphs")
@system
unittest
{
    size_t lookups, equalInput, equalOutput, supersetInput, supersetOutput, records, broken, other;
    eachFace((file, face, ref hb) {
        const header = face.layout(LayoutTable.gsub);
        if (header.hasError)
            return;
        enum gsub = Tag("GSUB").value;
        if (hb_ot_layout_table_get_lookup_count(hb.face, gsub) == 0)
            return; // HarfBuzz rejected the table (counted by scriptsFeaturesLookups)
        foreach (li; 0 .. header.value.lookupCount)
        {
            auto subs = face.substitutions(li);
            if (subs.hasError)
            {
                ++broken;
                continue;
            }
            uint[] input, output;
            bool bad, simple = true;
            size_t n;
            Substitutions range = subs.value;
            foreach (s; range)
            {
                if (s.hasError)
                {
                    bad = true;
                    break;
                }
                const r = s.value;
                if (r.lookupType < 1 || r.lookupType > 4)
                {
                    simple = false;
                    break;
                }
                GlyphSequence inSeq = r.input, outSeq = r.output;
                foreach (g; inSeq)
                    input ~= g;
                foreach (g; outSeq)
                    output ~= g;
                ++n;
            }
            if (bad)
            {
                ++broken;
                continue;
            }
            if (!simple)
            {
                ++other;
                continue;
            }
            auto ours = [toSet(input), toSet(output)];
            auto theirs = [hb_set_create(), hb_set_create()];
            scope (exit)
                foreach (s; ours ~ theirs)
                    hb_set_destroy(s);
            hb_ot_layout_lookup_collect_glyphs(hb.face, gsub, li, null, theirs[0], null, theirs[1]);
            // HarfBuzz's sets hold every glyph our records name; equal unless
            // a coverage lists a glyph no record follows.
            assert(hb_set_is_subset(ours[0], theirs[0]), file);
            assert(hb_set_is_subset(ours[1], theirs[1]), file);
            if (hb_set_is_equal(ours[0], theirs[0])) ++equalInput; else ++supersetInput;
            if (hb_set_is_equal(ours[1], theirs[1])) ++equalOutput; else ++supersetOutput;
            ++lookups;
            records += n;
        }
    });
    stderr.writefln("oracle.layout.substitutionGlyphs: %s GSUB type 1-4 lookups (%s records) within "
        ~ "hb_ot_layout_lookup_collect_glyphs; input sets equal %s / strict subset %s, output equal %s / "
        ~ "strict subset %s; not compared: %s contextual or reverse lookups, %s lookups with an error element",
        lookups, records, equalInput, supersetInput, equalOutput, supersetOutput, other, broken);
    assert(lookups > 100);
}

@("oracle.colour.capabilities")
@system
unittest
{
    size_t faces, colourFaces, compared, cbdtWithoutCblc, colrAboveOne;
    eachFace((file, face, ref hb) {
        ++faces;
        const c = face.colourCapability;
        // § 9: HarfBuzz counts CBDT without CBLC, and reads COLR above 1 as 1.
        const noCblc = c.cbdt.present && c.cbdt.has.hasError
            && c.cbdt.has.error.kind == FontErrorKind.missingTable;
        const colrNewer = c.colrLayers.present && c.colrLayers.has.hasError
            && c.colrLayers.has.error.kind == FontErrorKind.unsupportedVersion;
        cbdtWithoutCblc += noCblc;
        colrAboveOne += colrNewer;
        if (c.colrLayers.present || c.colrPaint.present || c.cpal.present || c.cbdt.present
            || c.sbix.present || c.svg.present)
            ++colourFaces;
        if (!colrNewer)
        {
            assert(c.colrLayers.usable == (hb_ot_color_has_layers(hb.face) != 0), file);
            assert(c.colrPaint.usable == (hb_ot_color_has_paint(hb.face) != 0), file);
            compared += 2;
        }
        assert(c.cpal.usable == (hb_ot_color_has_palettes(hb.face) != 0), file);
        assert(c.svg.usable == (hb_ot_color_has_svg(hb.face) != 0), file);
        compared += 2;
        if (!noCblc)
        {
            assert((c.cbdt.usable || c.sbix.usable) == (hb_ot_color_has_png(hb.face) != 0), file);
            ++compared;
        }
    });
    stderr.writefln("oracle.colour.capabilities: %s faces (%s with a colour table), %s flags agree; "
        ~ "excluded: %s CBDT without CBLC, %s COLR above version 1",
        faces, colourFaces, compared, cbdtWithoutCblc, colrAboveOne);
    assert(compared > 0);
}
