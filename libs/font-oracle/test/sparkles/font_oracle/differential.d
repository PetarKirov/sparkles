/**
The M1 differential suite: for every bundled font, `sparkles:font` and
HarfBuzz must agree on the face's units per em and glyph count, every
character mapping, `name` text, glyph names and advances. The deliberate
divergences of `parsing.md` § 7 are applied where they arise and counted.
*/
module sparkles.font_oracle.differential;

import std.algorithm : canFind, endsWith, sort;
import std.array : array;
import std.file : dirEntries, read, SpanMode;
import std.path : baseName;
import std.process : environment;
import std.string : fromStringz;

import sparkles.font;
import sparkles.font_oracle.harfbuzz;
import sparkles.test_runner.skip : skipTest;

/// A HarfBuzz face and font over borrowed bytes.
private struct Oracle
{
    hb_blob_t* blob;
    hb_face_t* face;
    hb_font_t* font;

    this(const(ubyte)[] bytes, uint index) @trusted
    {
        blob = hb_blob_create(cast(const(char)*) bytes.ptr, cast(uint) bytes.length,
            hb_memory_mode_t.HB_MEMORY_MODE_READONLY, null, null);
        face = hb_face_create(blob, index);
        font = hb_font_create(face);
    }

    void close() @trusted
    {
        hb_font_destroy(font);
        hb_face_destroy(face);
        hb_blob_destroy(blob);
    }
}

/// The bundled outline fonts, or null when the corpus is unset.
private string[] corpus() @safe
{
    const dir = environment.get("SPARKLES_FONTS_PATH");
    if (dir is null)
        return null;
    return dirEntries(dir, SpanMode.shallow)
        .filter!(e => e.name.endsWith(".ttf") || e.name.endsWith(".otf"))
        .map!(e => e.name).array.sort.release;
}

import std.algorithm : filter, map;

@("oracle.layout.nameEntry")
@safe pure nothrow @nogc
unittest
{
    // hb_ot_name_entry_t: uint, hb_var_int_t (4 bytes), pointer.
    static assert(hb_ot_name_entry_t.sizeof == 8 + (void*).sizeof);
    static assert(hb_ot_name_entry_t.language.offsetof == 8);
}

@("oracle.parsing.everyBundledFace")
@system
unittest
{
    const files = corpus();
    if (files is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    assert(files.length > 100, "the bundle holds about 180 fonts");
    size_t faces, mappings, names, glyphNames, macNameSkips;
    foreach (path; files)
    {
        const bytes = cast(const(ubyte)[]) read(path);
        const file = path.baseName;
        auto hb = Oracle(bytes, 0);
        scope (exit) hb.close();
        const opened = openFace(bytes);
        assert(opened.hasValue, file);
        const face = opened.value;
        ++faces;

        // FTP18: units per em and glyph count. HarfBuzz reports 1000 for an
        // out-of-range unitsPerEm; none is expected in the bundle.
        assert(face.unitsPerEm == hb_face_get_upem(hb.face), file);
        assert(face.numGlyphs == hb_face_get_glyph_count(hb.face), file);

        // FTP25–FTP27: every codepoint either side maps equals per-codepoint
        // hb_font_get_nominal_glyph, mappings past numGlyphs dropped (§ 7).
        uint hbGlyph(dchar cp)
        {
            hb_codepoint_t g;
            if (!hb_font_get_nominal_glyph(hb.font, cp, &g)) return 0;
            return g < face.numGlyphs ? g : 0;
        }
        const map = face.charMap;
        if (map.hasValue)
        {
            foreach (r; map.value.ranges)
                foreach (cp; r.first .. r.last + 1)
                {
                    assert(map.value.glyph(cp) == hbGlyph(cp), file);
                    ++mappings;
                }
            auto set = hb_set_create();
            scope (exit) hb_set_destroy(set);
            hb_face_collect_unicodes(hb.face, set);
            hb_codepoint_t cp = HB_SET_VALUE_INVALID;
            while (hb_set_next(set, &cp))
                assert(map.value.glyph(cp) == hbGlyph(cp), file);
        }

        // FTP28, FTP29: every name HarfBuzz decodes matches one of our records
        // with that name ID; HarfBuzz reads Mac Roman as ASCII (§ 7), so a name ID
        // with a Mac Roman record may differ there and is skipped.
        const table = face.name;
        uint count;
        const entries = hb_ot_name_list_names(hb.face, &count);
        foreach (e; entries[0 .. count])
        {
            char[4096] hbText;
            uint size = hbText.length;
            hb_ot_name_get_utf8(hb.face, e.name_id, e.language, &size, hbText.ptr);
            const expected = hbText[0 .. size];
            bool found, macRecord;
            char[4096] buffer;
            foreach (r; table.value.records)
            {
                if (!r.hasValue || r.value.nameID != e.name_id) continue;
                if (r.value.encoding == NameEncoding.macRoman) macRecord = true;
                const text = r.value.decode(buffer[]);
                if (text.hasValue && text.value == expected) { found = true; break; }
            }
            if (!found && macRecord) { ++macNameSkips; continue; }
            assert(found, file);
            ++names;
        }

        // FTP30, FTP31: where HarfBuzz names a glyph, the name is ours.
        foreach (gid; 0 .. face.numGlyphs)
        {
            char[256] hbName;
            const hbHas = hb_font_get_glyph_name(hb.font, gid, hbName.ptr, hbName.length);
            const ours = face.glyphName(gid);
            if (hbHas)
            {
                assert(ours.hasValue && ours.value.present, file);
                assert(ours.value.text == fromStringz(hbName.ptr), file);
                ++glyphNames;
            }
        }

        // FTP24: advances at the default instance, in font units.
        const metrics = face.hmtx;
        if (metrics.hasValue)
            foreach (gid; 0 .. face.numGlyphs)
                assert(metrics.value.advance(gid).value == hb_font_get_glyph_h_advance(hb.font, gid), file);
    }
    assert(faces == files.length && mappings > 100_000 && names > 1_000 && glyphNames > 10_000);
}
