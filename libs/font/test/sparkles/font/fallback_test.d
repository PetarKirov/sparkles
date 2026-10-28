/**
Fallback chains (FTD31–FTD34, FTD38) over catalogs of fixture faces with
known coverage, and the face store (FTD32) over `MemVfs`: entry order,
routes, repeats, presentation, identity, the character cache, staleness and
the box-drawing face per ppem.
*/
module sparkles.font.fallback_test;

import std.conv : to;

import sparkles.base.vfs : ambientAuthority, MemNode, MemVfs;

import sparkles.font.box_face : boxFaceFamily;
import sparkles.font.catalog;
import sparkles.font.cmap : charMap, CodepointRange;
import sparkles.font.fallback;
import sparkles.font.fixtures;
import sparkles.font.matching;

private enum one = fixedOne;

private struct World
{
    MemVfs* vfs;
    Catalog catalog;
    BuildReport report;
}

/// A catalog of `faces` written as files under `f/`, named by index.
private World* worldOf(const(StyledFace)[] faces, const(ubyte[])[] raw = null) @safe
{
    auto w = new World;
    w.vfs = new MemVfs(new MemNode[64], new ubyte[1 << 20]);
    w.vfs.mkdirs("f");
    foreach (i, f; faces)
        w.vfs.writeFile("f/" ~ (10 + i).to!string ~ ".ttf", styledFont(f));
    foreach (i, bytes; raw)
        w.vfs.writeFile("f/" ~ (50 + i).to!string ~ ".ttf", bytes);
    assert(!buildCatalog(w.vfs, [FontSource.directory("f", "f", false)], BuildOptions.init, ambientAuthority(),
        w.catalog, w.report).hasError);
    assert(w.report.failed == 0, w.report.outcomes.length.to!string);
    return w;
}

private MatchRequest family(string name) @safe
{
    MatchRequest r;
    r.families = [name];
    return r;
}

/// Latin (A–Z) primary, a Greek face, a second Latin face with identical coverage, an emoji-coloured face.
private World* standard() @safe
{
    auto colour = styledTables(StyledFace("Colour", "Regular", 400, 5, 0, 0, 'a', 'z'));
    colour ~= TableData("COLR", colrV0([[1, 0, 1]], [[2, 0]]));
    colour ~= TableData("CPAL", cpalColours([[[255, 0, 0, 255]]]));
    import std.algorithm : sort;

    colour.sort!((a, b) => a.tag < b.tag);
    return worldOf([StyledFace("Latin"), StyledFace("Greek", "Regular", 400, 5, 0, 0, 'Α', 'Ω'),
        StyledFace("Twin"), StyledFace("Text", "Regular", 400, 5, 0, 0, 'a', 'z')], [sfnt(colour)]);
}

private string familyOf(ref const FallbackChain c, size_t i) @safe
    => c.poolsOf(c.entries[i]).text(c.recordOf(c.entries[i]).family).idup;

@("fallback.FTD31.orderRepeatsAndEverything")
@safe unittest
{
    auto w = standard();
    FallbackChain c;
    const latin = family("Latin");
    const routes = [CodepointRange('X', 'Z')];
    assert(buildChain(w.catalog, latin, [ChainItem.route(routes, family("Greek")), ChainItem.primary,
        ChainItem.family(family("Twin")), ChainItem.family(family("Latin")), ChainItem.family(family("Nope")),
        ChainItem.everything], c).hasValue);
    string[] got;
    foreach (i; 0 .. c.entries.length)
        got ~= familyOf(c, i);
    // The route first; Latin once (the repeated family adds nothing); Twin stays despite identical coverage;
    // `everything` adds the rest in folded-name order.
    assert(got == ["Greek", "Latin", "Twin", "Colour", "Greek", "Text"], got.to!string);
    assert(c.primary == 1 && c.entries[0].kind == ChainItemKind.route);
    assert(c.outcomes.length == 1 && c.outcomes[0].item == 4 && c.outcomes[0].noMatch);
    assert(c.familyOf(c.entries[2]) == "Twin");

    // Routes must come first, then primary.
    FallbackChain bad;
    assert(buildChain(w.catalog, latin, [ChainItem.family(family("Twin")), ChainItem.primary], bad).hasError);
    assert(buildChain(w.catalog, latin, [ChainItem.primary, ChainItem.route(routes, family("Greek"))], bad).hasError);
}

@("fallback.FTD33.characterLookup")
@safe unittest
{
    auto w = standard();
    FallbackChain c;
    assert(buildChain(w.catalog, family("Latin"), [ChainItem.route([CodepointRange('X', 'Z')], family("Greek")),
        ChainItem.primary, ChainItem.family(family("Greek")), ChainItem.family(family("Text")),
        ChainItem.family(family("Colour"))], c).hasValue);
    // The route answers only inside its ranges, and only for what its face covers (Greek has no 'X').
    assert(familyOf(c, c.characterEntry('A')) == "Latin");
    assert(familyOf(c, c.characterEntry('X')) == "Latin");
    assert(familyOf(c, c.characterEntry('Δ')) == "Greek" && c.characterEntry('Δ') == 2);
    assert(c.characterEntry('€') == noEntry);
    // Presentation: emoji prefers the coloured face, text the uncoloured one.
    assert(familyOf(c, c.characterEntry('a')) == "Text");
    assert(familyOf(c, c.characterEntry('a', Presentation.emoji)) == "Colour");
    assert(familyOf(c, c.characterEntry('a', Presentation.text)) == "Text");

    CharacterCache!64 cache;
    foreach (_; 0 .. 2)
        assert(cache.characterEntry(c, 'a', Presentation.emoji) == c.characterEntry('a', Presentation.emoji));
}

@("fallback.FTD34.identity")
@safe unittest
{
    auto w = standard();
    FallbackChain a, b, other;
    assert(buildChain(w.catalog, family("Latin"), [ChainItem.primary], a).hasValue);
    assert(buildChain(w.catalog, family("Latin"), [ChainItem.primary], b).hasValue);
    assert(buildChain(w.catalog, family("Latin"), [ChainItem.primary, ChainItem.family(family("Greek"))], other)
        .hasValue);
    assert(a.identity == b.identity && a.identity != other.identity);
}

@("fallback.FTD32.storeOpensAndStales")
@safe unittest
{
    auto w = standard();
    FallbackChain c;
    assert(buildChain(w.catalog, family("Latin"), [ChainItem.primary, ChainItem.family(family("Greek"))], c)
        .hasValue);
    auto store = FaceStore!MemVfs(w.vfs, c, ambientAuthority());
    BuildOutcome o;
    const latin = store.face(0, o);
    assert(latin !is null && charMap(*latin).value.glyph('A') == 1);
    assert(store.face(0, o) is latin); // opened once

    // Greek's file is replaced after the build: its entry is stale and stays so.
    w.vfs.writeFile("f/11.ttf", styledFont(StyledFace("Greek", "Bold", 700, 5, 0, 0, 'Α', 'Ω')));
    assert(store.face(1, o) is null && o.kind == OutcomeKind.stale);
    w.vfs.writeFile("f/11.ttf", styledFont(StyledFace("Greek", "Regular", 400, 5, 0, 0, 'Α', 'Ω')));
    assert(store.face(1, o) is null && o.kind == OutcomeKind.stale);
}

@("fallback.FTD38.boxDrawingEntry")
@safe unittest
{
    auto w = standard();
    FallbackChain c;
    assert(buildChain(w.catalog, family("Latin"), [ChainItem.primary, ChainItem.boxDrawing], c).hasValue);
    assert(c.entries[1].isBoxDrawing && c.familyOf(c.entries[1]) == boxFaceFamily);
    assert(c.characterEntry('─') == 1 && c.characterEntry('A') == 0);
    assert(c.poolsOf(c.entries[1]).text(c.recordOf(c.entries[1]).family) == boxFaceFamily);

    auto store = FaceStore!MemVfs(w.vfs, c, ambientAuthority());
    const at16 = store.boxFace(16);
    assert(at16.hasValue, at16.error.kind.to!string);
    assert(charMap(*at16.value).value.glyph('─') != 0);
    const again = store.boxFace(16);
    assert(again.value is at16.value);
    const at24 = store.boxFace(24);
    assert(at24.hasValue && at24.value !is at16.value && at24.value.unitsPerEm == 24 * 64);
    // The face of 16 px stays valid after 24 px was built.
    assert(at16.value.unitsPerEm == 16 * 64);

    // Without a primary match there is no box-drawing entry.
    FallbackChain none;
    assert(buildChain(w.catalog, family("Nope"), [ChainItem.primary, ChainItem.boxDrawing], none).hasValue);
    assert(none.entries.length == 0 && none.outcomes.length == 2);
}

@("fallback.FTD33.routeEntry")
@safe unittest
{
    auto w = standard();
    FallbackChain c;
    // Greek routed over Α–Ω and over A–C, where Greek has no glyphs: the latter falls through.
    assert(buildChain(w.catalog, family("Latin"), [ChainItem.route([CodepointRange('A', 'C')], family("Greek")),
        ChainItem.route([CodepointRange('Α', 'Ω')], family("Greek")), ChainItem.primary], c).hasValue);
    assert(c.routeEntry('Δ') == 1 && c.routeEntry('B') == noEntry && c.routeEntry('x') == noEntry);
    // The primary keeps every scalar no route claims.
    assert(c.characterEntry('B') == 2);
}
