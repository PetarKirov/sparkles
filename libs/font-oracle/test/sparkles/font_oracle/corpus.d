/**
What every differential suite shares: the bundled corpus and a HarfBuzz face
and font over borrowed bytes.
*/
module sparkles.font_oracle.corpus;

import std.algorithm : endsWith, filter, map, sort;
import std.array : array;
import std.file : dirEntries, exists, SpanMode;
import std.path : buildPath;
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
    /**
    The test corpus's directories of M2's gates, in name order: `base/` (real
    `BASE` tables), `math/` (`MATH` faces) and `harfbuzz/` (HarfBuzz's API
    test fonts); empty when unset.
    */
    package immutable string[] baseCorpus = listCorpus(subdir("base")).idup;
    /// ditto
    package immutable string[] mathCorpus = listCorpus(subdir("math")).idup;
    /// ditto
    package immutable string[] harfbuzzCorpus = listCorpus(subdir("harfbuzz")).idup;
};

private string subdir(string name) @safe
    => testFontsDir is null ? null : buildPath(testFontsDir, name);

/**
`bytes`, a single-face font, with an empty `cmap` (version 0, no encoding
records) added: `openFace` requires a `cmap` header (FTP3), and some of
HarfBuzz's test fonts carry the table under test with nothing else, such as
`base-minmax.ttf`, whose `BASE` holds the only real MinMax records in the
corpus. Every other table keeps its bytes; the directory is rewritten in tag
order and the checksums are left zero, which no reader here checks.
*/
package ubyte[] withEmptyCmap(const(ubyte)[] bytes) @safe pure
{
    static uint be(scope const(ubyte)[] b, size_t at) => (uint(b[at]) << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];
    static void put(ref ubyte[] b, size_t at, uint v, size_t n)
    {
        foreach (i; 0 .. n)
            b[at + i] = cast(ubyte)(v >> 8 * (n - 1 - i));
    }
    struct Table { uint tag; const(ubyte)[] data; }
    const count = (uint(bytes[4]) << 8) | bytes[5];
    Table[] tables = [Table(0x636D6170, [0, 0, 0, 0])];
    foreach (i; 0 .. count)
    {
        const r = 12 + 16 * i;
        tables ~= Table(be(bytes, r), bytes[be(bytes, r + 8) .. be(bytes, r + 8) + be(bytes, r + 12)]);
    }
    tables.sort!((a, b) => a.tag < b.tag);
    auto r = new ubyte[12 + 16 * tables.length];
    r[0 .. 4] = bytes[0 .. 4];
    put(r, 4, cast(uint) tables.length, 2);
    foreach (i, t; tables)
    {
        put(r, 12 + 16 * i, t.tag, 4);
        put(r, 12 + 16 * i + 8, cast(uint) r.length, 4);
        put(r, 12 + 16 * i + 12, cast(uint) t.data.length, 4);
        r ~= t.data;
        r.length = (r.length + 3) & ~3;
    }
    return r;
}

private string[] listCorpus(string dir) @safe
{
    if (dir is null || !dir.exists)
        return null;
    return dirEntries(dir, SpanMode.shallow)
        .filter!(e => e.name.endsWith(".ttf") || e.name.endsWith(".otf") || e.name.endsWith(".ttc"))
        .map!(e => e.name).array.sort.release;
}
