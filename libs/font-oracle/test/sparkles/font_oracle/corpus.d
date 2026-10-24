/**
What every differential suite shares: the bundled corpus and a HarfBuzz face
and font over borrowed bytes.
*/
module sparkles.font_oracle.corpus;

import std.algorithm : endsWith, filter, map, sort;
import std.array : array;
import std.file : dirEntries, exists, SpanMode;
import std.process : environment;

import sparkles.base.static_init : StaticBlock;
import sparkles.font_oracle;

/**
A HarfBuzz blob, face and font over borrowed bytes, released when the value
goes out of scope. It cannot be copied, so each HarfBuzz object is destroyed
exactly once; pass it by `ref`.
*/
package struct Oracle
{
    hb_blob_t* blob;
    hb_face_t* face;
    hb_font_t* font;

    @disable this();
    @disable this(this);

    /// HarfBuzz's view of face `index` of `bytes`, which must outlive it.
    this(const(ubyte)[] bytes, uint index) @trusted
    {
        blob = hb_blob_create(cast(const(char)*) bytes.ptr, cast(uint) bytes.length,
            hb_memory_mode_t.HB_MEMORY_MODE_READONLY, null, null);
        face = hb_face_create(blob, index);
        font = hb_font_create(face);
    }

    ~this() @trusted
    {
        hb_font_destroy(font);
        hb_face_destroy(face);
        hb_blob_destroy(blob);
    }
}

mixin StaticBlock!q{
    /// `$SPARKLES_FONTS_PATH`, or null when the corpus is unset.
    package immutable string fontsDir = environment.get("SPARKLES_FONTS_PATH");
    /// The bundled outline fonts in name order; empty when the corpus is unset.
    package immutable string[] corpus = listCorpus(fontsDir).idup;
    /// `$SPARKLES_FONT_TEST_CORPUS`: faces tested against but not shipped (the variable CFF2 and the `JSTF` faces).
    package immutable string testFontsDir = environment.get("SPARKLES_FONT_TEST_CORPUS");
    /// The test-only faces in name order, a collection standing for its first face; empty when unset.
    package immutable string[] testCorpus = listCorpus(testFontsDir).idup;
};

private string[] listCorpus(string dir) @safe
{
    if (dir is null || !dir.exists)
        return null;
    return dirEntries(dir, SpanMode.shallow)
        .filter!(e => e.name.endsWith(".ttf") || e.name.endsWith(".otf") || e.name.endsWith(".ttc"))
        .map!(e => e.name).array.sort.release;
}
