/**
What every differential suite shares: the bundled corpus and a HarfBuzz face
and font over borrowed bytes.
*/
module sparkles.font_oracle.corpus;

import std.algorithm : endsWith, filter, map, sort;
import std.array : array;
import std.file : dirEntries, SpanMode;
import std.process : environment;

import sparkles.font_oracle.harfbuzz;

/// A HarfBuzz face and font over borrowed bytes.
package struct Oracle
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
package string[] corpus() @safe
{
    const dir = environment.get("SPARKLES_FONTS_PATH");
    if (dir is null)
        return null;
    return dirEntries(dir, SpanMode.shallow)
        .filter!(e => e.name.endsWith(".ttf") || e.name.endsWith(".otf"))
        .map!(e => e.name).array.sort.release;
}
