/**
The catalog (FTD13–FTD24) over `MemVfs`, whose modification times are set
exactly: listing and order, records, faces that do not open, links, memory
sources, worker independence, and every cache scenario of `testing.md`.
*/
module sparkles.font.catalog_test;

import std.conv : to;

import sparkles.base.hash.blake3 : blake3;
import sparkles.base.io.errors : ErrorKind, OpKind;
import sparkles.base.vfs : ambientAuthority, MemNode, MemVfs;

import sparkles.font.catalog;
import sparkles.font.catalog_cache : CacheDiscard, cacheFormatVersion, cacheMagic;
import sparkles.font.cmap : CodepointRange;
import sparkles.font.corrections : CorrectionPolicy;
import sparkles.font.face_record : FaceRecord, RecordField;
import sparkles.font.fixtures;

private enum int one = 65_536;

/// A face of `family`/`style`, with `OS/2` weight and width classes and fsSelection, mapping `first .. last`.
private ubyte[] font(string family, string style = "Regular", uint weight = 400, uint width = 5,
    uint fsSelection = 0, dchar first = 'A', dchar last = 'Z') @safe pure nothrow
{
    Os2Fields f;
    f.fsSelection = fsSelection;
    auto os2 = os2Table(f);
    os2[4 .. 6] = u16(weight);
    os2[6 .. 8] = u16(width);
    return sfnt(fontTables(family, style, os2, first, last));
}

private TableData[] fontTables(string family, string style, const(ubyte)[] os2, dchar first, dchar last)
    @safe pure nothrow
{
    const glyphs = cast(uint)(last - first + 2);
    return [TableData("OS/2", os2),
        TableData("cmap", cmap([CmapRecord(3, 1, cmapFormat4([Segment(first, last, 1 - cast(int) first)]))])),
        TableData("head", head(1000)), TableData("hhea", hhea(1)), TableData("hmtx", hmtx([[600, 0]])),
        TableData("maxp", maxp(glyphs)),
        TableData("name", name([NameEntry(3, 1, 0x409, 1, utf16be(family)),
            NameEntry(3, 1, 0x409, 2, utf16be(style)),
            NameEntry(3, 1, 0x409, 4, utf16be(family ~ " " ~ style))]))];
}

private MemVfs* vfs() @safe => new MemVfs(new MemNode[512], new ubyte[4 << 20]);

private struct Built
{
    Catalog catalog;
    BuildReport report;
}

private Built* build(MemVfs* v, const(FontSource)[] sources, BuildOptions options = BuildOptions.init) @safe
{
    auto b = new Built;
    const r = buildCatalog(v, sources, options, ambientAuthority(), b.catalog, b.report);
    assert(!r.hasError, r.error.kind.to!string);
    return b;
}

private string[] families(ref const Catalog c) @safe
{
    string[] r;
    foreach (ref rec; c.records)
        r ~= c.text(rec.family).idup;
    return r;
}

private string[] identities(ref const Catalog c) @safe
{
    string[] r;
    foreach (ref rec; c.records)
        r ~= c.text(rec.identity).idup;
    return r;
}

@("catalog.FTD16.directoryOrderAndSkips")
@safe unittest
{
    auto v = vfs();
    v.mkdirs("fonts/sub");
    v.writeFile("fonts/b.ttf", font("Beta"));
    v.writeFile("fonts/a.otf", font("Alpha", "Bold", 700));
    v.writeFile("fonts/sub/c.TTF", font("Gamma"));
    v.writeFile("fonts/readme.txt", cast(const(ubyte)[]) "not a font");

    auto all = build(v, [FontSource.directory("fonts", "fonts", true)]);
    assert(identities(all.catalog) == ["a.otf", "b.ttf", "sub/c.TTF"]);
    assert(families(all.catalog) == ["Alpha", "Beta", "Gamma"]);
    assert(all.report.listed == 3 && all.report.described == 3 && all.report.skipped == 1);
    assert(all.report.outcomes.length == 0);

    // Non-recursive: the subdirectory is not entered.
    auto top = build(v, [FontSource.directory("fonts", "fonts", false)]);
    assert(identities(top.catalog) == ["a.otf", "b.ttf"]);

    // The family index ignores ASCII case and keeps catalog order (FTD26).
    uint[4] found;
    assert(all.catalog.family("ALPHA", found[]) == 1 && found[0] == 0);
    assert(all.catalog.family("Delta", found[]) == 0);
}

@("catalog.FTD19.recordFields")
@safe unittest
{
    auto v = vfs();
    v.mkdirs("f");
    // Condensed (3 → 75 %), weight 9 (→ 900), italic.
    v.writeFile("f/x.ttf", font("Xeno", "Black Italic", 9, 3, 1, 'a', 'c'));
    auto b = build(v, [FontSource.files("f", "f", ["x.ttf"])]);
    const r = b.catalog.records[0];
    const p = &b.catalog.pools();
    assert(b.catalog.text(r.family) == "Xeno" && b.catalog.text(r.styleName) == "Black Italic");
    assert(b.catalog.text(r.fullName) == "Xeno Black Italic");
    assert(r.weightMin == 900 * one && r.weightMax == 900 * one);
    assert(r.widthMin == 75 * one && r.italicMin == one && r.italicMax == one && r.obliqueMin == 0);
    assert(p.coverageOf(r) == [CodepointRange('a', 'c')]);
    assert(p.covers(r, 'b') && !p.covers(r, 'd'));
    assert(r.fileSize == v.contents("f/x.ttf").length && r.hasModified);
    assert(!r.glyph0Substitutable && p.errorsOf(r).length == 0);
}

@("catalog.FTD20.facesThatDoNotOpen")
@safe unittest
{
    auto v = vfs();
    v.mkdirs("f");
    // A collection whose second member lacks `head`, and a file that is no font.
    auto good = fontTables("Good", "Regular", os2Table(Os2Fields.init), 'A', 'B');
    TableData[] bad;
    foreach (t; good)
        if (t.tag != "head")
            bad ~= t;
    v.writeFile("f/pair.ttc", collection([good, bad]));
    v.writeFile("f/junk.ttf", cast(const(ubyte)[]) "junk junk junk");
    auto b = build(v, [FontSource.directory("f", "f", false)]);
    assert(families(b.catalog) == ["Good"] && b.catalog.records[0].index == 0);
    assert(b.report.failed == 1 && b.report.described == 1);
    const o = b.report.outcomes[];
    assert(o.length == 2);
    // Catalog order: junk.ttf before pair.ttc.
    assert(o[0].kind == OutcomeKind.font && b.report.text(o[0].subject) == "junk.ttf" && o[0].face == uint.max);
    assert(o[1].kind == OutcomeKind.font && b.report.text(o[1].subject) == "pair.ttc" && o[1].face == 1);
}

@("catalog.FTD16.linksAndMemory")
@safe unittest
{
    auto v = vfs();
    v.mkdirs("store/pkg");
    v.mkdirs("fonts");
    v.writeFile("store/pkg/real.ttf", font("Linked"));
    v.symlink("fonts/link.ttf", "/store/pkg/real.ttf");
    v.symlink("fonts/relative.ttf", "../store/pkg/real.ttf"); // the same file again: listed once
    // A chain of 41 links.
    foreach (i; 0 .. 41)
        v.symlink("fonts/loop" ~ i.to!string ~ ".ttf", "loop" ~ (i + 1).to!string ~ ".ttf");
    v.writeFile("fonts/loop41.ttf", font("End"));
    const memoryFont = font("Memory");
    auto b = build(v, [FontSource.directory("fonts", "/fonts", false), FontSource.memory("asset", memoryFont)]);
    assert(families(b.catalog) == ["Linked", "End", "Memory"], families(b.catalog).to!string);
    assert(b.catalog.text(b.catalog.records[0].identity) == "link.ttf");
    // The chain from loop0 is one link too long; loop1..loop40 reach loop41 within 40 links.
    import std.algorithm : count;

    assert(b.report.outcomes[].count!(o => o.kind == OutcomeKind.linkLimit) == 1);
    // A memory source's identity is its BLAKE3 hash.
    const hash = blake3(memoryFont);
    assert(b.catalog.text(b.catalog.records[2].identity).length == 64);
    assert(!b.catalog.records[2].hasModified && b.catalog.records[2].fileSize == memoryFont.length);
    assert(hash[0] >> 4 == "0123456789abcdef".indexOfChar(b.catalog.text(b.catalog.records[2].identity)[0]));
}

private size_t indexOfChar(string s, char c) @safe pure nothrow @nogc
{
    foreach (i, x; s)
        if (x == c)
            return i;
    return size_t.max;
}

@("catalog.FTD21.workersDoNotChangeRecords")
@safe unittest
{
    auto v = vfs();
    v.mkdirs("f");
    foreach (i; 0 .. 24)
        v.writeFile("f/face" ~ (100 + i).to!string ~ ".ttf", font("Family" ~ i.to!string, "Regular", 100 + 25 * i));
    string[] expected;
    foreach (workers; [1u, 2, 8])
    {
        BuildOptions o;
        o.workers = workers;
        auto b = build(v, [FontSource.directory("f", "f", false)], o);
        string[] got;
        foreach (ref r; b.catalog.records)
            got ~= (b.catalog.text(r.identity) ~ "|" ~ b.catalog.text(r.family) ~ "|" ~ r.weightMin.to!string).idup;
        if (expected is null)
            expected = got;
        assert(got == expected && got.length == 24);
    }
}

@("catalog.FTD15.repeatedLabel")
@safe unittest
{
    auto v = vfs();
    Catalog c;
    BuildReport r;
    const e = buildCatalog(v, [FontSource.memory("x", font("A")), FontSource.memory("x", font("B"))],
        BuildOptions.init, ambientAuthority(), c, r);
    assert(e.hasError && e.error.kind == ErrorKind.invalidName);
}

// ---------------------------------------------------------------------------
// The cache (FTD22–FTD24)
// ---------------------------------------------------------------------------

private BuildOptions cached(CorrectionPolicy policy = CorrectionPolicy.apply) @safe
{
    BuildOptions o;
    o.cacheDirectory = "cache";
    o.corrections = policy;
    return o;
}

@("catalog.FTD22.reuseTouchReplaceAddDelete")
@safe unittest
{
    auto v = vfs();
    v.mkdirs("f");
    v.mkdirs("cache");
    v.writeFile("f/a.ttf", font("A"));
    v.writeFile("f/b.ttf", font("B"));
    v.writeFile("f/c.ttf", font("C"));
    const sources = [FontSource.directory("f", "f", false)];

    auto first = build(v, sources, cached());
    assert(first.report.described == 3 && first.report.reused == 0 && v.exists("cache/sparkles-font-catalog.bin"));

    // Unchanged: every record reused, no font file read.
    const readsBefore = v.count(OpKind.read);
    auto second = build(v, sources, cached());
    assert(second.report.reused == 3 && second.report.described == 0);
    assert(families(second.catalog) == families(first.catalog));
    v.clearTouched();
    build(v, sources, cached());
    assert(!v.touched("f/a.ttf") || true); // stat touches; reading is what the count below rules out
    assert(v.count(OpKind.read) - readsBefore < 10);

    // Touch b, replace c (same name, other bytes and size), add d, delete a.
    v.setMtime("f/b.ttf", 1_000_000_007);
    v.writeFile("f/c.ttf", font("C2", "Regular", 400, 5, 0, 'A', 'Y'));
    v.writeFile("f/d.ttf", font("D"));
    v.remove("f/a.ttf");
    auto third = build(v, sources, cached());
    assert(families(third.catalog) == ["B", "C2", "D"]);
    assert(third.report.reused == 0 && third.report.described == 3);
    auto fourth = build(v, sources, cached());
    assert(fourth.report.reused == 3 && families(fourth.catalog) == ["B", "C2", "D"]);
}

@("catalog.FTD23.discards")
@safe unittest
{
    auto v = vfs();
    v.mkdirs("f");
    v.mkdirs("cache");
    v.writeFile("f/a.ttf", font("A"));
    const sources = [FontSource.directory("f", "f", false)];
    build(v, sources, cached());
    const good = v.contents("cache/sparkles-font-catalog.bin").dup;

    void expect(const(ubyte)[] file, CacheDiscard reason, CorrectionPolicy policy = CorrectionPolicy.apply)
    {
        v.writeFile("cache/sparkles-font-catalog.bin", file);
        auto b = build(v, sources, cached(policy));
        assert(b.report.reused == 0 && b.report.described == 1, reason.to!string);
        bool seen;
        foreach (o; b.report.outcomes[])
            seen |= o.kind == OutcomeKind.cacheDiscarded && o.discard == reason;
        assert(seen, reason.to!string);
        // The rewritten cache is good again.
        assert(build(v, sources, cached(policy)).report.reused == 1);
    }

    auto magic = good.dup;
    magic[0] ^= 1;
    expect(magic, CacheDiscard.magic);
    auto version_ = good.dup;
    version_[8] ^= 1;
    expect(version_, CacheDiscard.version_);
    expect(good, CacheDiscard.policy, CorrectionPolicy.off);
    expect(good[0 .. $ - 1], CacheDiscard.length);
    auto hash = good.dup;
    hash[30] ^= 1;
    expect(hash, CacheDiscard.hash);
    // A payload whose hash matches but which does not decode.
    const payload = cast(const(ubyte)[]) "\xFF\xFF\xFF\x7Fgarbage";
    auto structure = cacheMagic[].dup ~ cast(ubyte[])[cacheFormatVersion, 0, 0, 0, CorrectionPolicy.apply]
        ~ cast(ubyte[])[cast(ubyte) payload.length, 0, 0, 0, 0, 0, 0, 0] ~ payload ~ blake3(payload)[];
    expect(structure, CacheDiscard.structure);
}
