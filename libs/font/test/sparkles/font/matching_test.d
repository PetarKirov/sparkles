/**
Matching (FTD25–FTD30) traced by hand through CSS Fonts Level 4 §5.2 step 4
over synthetic families: `Syn` has nine weights at 100 %, two at 75 %, two
italics and a 10° oblique; smaller families isolate single phases; a variable
family must answer as the static family of all its values would.
*/
module sparkles.font.matching_test;

import std.conv : to;

import sparkles.base.vfs : ambientAuthority, MemNode, MemVfs;

import sparkles.font.catalog;
import sparkles.font.errors : FontErrorKind, Tag;
import sparkles.font.fixtures;
import sparkles.font.matching;

private enum one = fixedOne;

/// A catalog of memory sources, one per face.
private Catalog* catalogOf(const(StyledFace)[] faces) @safe
{
    FontSource[] sources;
    foreach (i, f; faces)
        sources ~= FontSource.memory(f.family ~ "/" ~ f.style ~ "/" ~ i.to!string, styledFont(f));
    auto c = new Catalog;
    auto r = new BuildReport;
    auto v = new MemVfs(new MemNode[8], new ubyte[16]);
    assert(!buildCatalog(v, sources, BuildOptions.init, ambientAuthority(), *c, *r).hasError);
    assert(r.failed == 0);
    return c;
}

/// The `Syn` family and the small families.
private Catalog* synthetic() @safe
{
    StyledFace[] faces;
    foreach (w; 1 .. 10)
        faces ~= StyledFace("Syn", "W" ~ (w * 100).to!string, w * 100);
    faces ~= StyledFace("Syn", "Condensed Light", 300, 3);
    faces ~= StyledFace("Syn", "Condensed Bold", 700, 3);
    faces ~= StyledFace("Syn", "Italic", 400, 5, 1);
    faces ~= StyledFace("Syn", "Bold Italic", 700, 5, 1);
    faces ~= StyledFace("Syn", "Oblique 10", 400, 5, 0x200, -10);
    faces ~= StyledFace("Medium", "Medium", 500);
    faces ~= StyledFace("Pair", "Regular", 400);
    faces ~= StyledFace("Pair", "Italic", 400, 5, 1);
    faces ~= StyledFace("Back", "Backslant", 400, 5, 0x200, 10);
    faces ~= StyledFace("Slants", "Eight", 400, 5, 0x200, -8);
    faces ~= StyledFace("Slants", "Twelve", 400, 5, 0x200, -12);
    return catalogOf(faces);
}

private Match matched(ref const Catalog c, MatchRequest r) @safe
{
    const m = matchFont(c, r);
    assert(m.hasValue);
    return m.value;
}

private string styleOf(ref const Catalog c, in Match m) @safe
    => c.text(c.records[m.record].styleName).idup;

private MatchRequest req(string family, uint weight = 400, int widthPercent = 100,
    StyleRequest style = StyleRequest.normal, int angle = 14) @safe
{
    MatchRequest r;
    r.families = [family];
    r.weight = weight * one;
    r.width = widthPercent * one;
    r.style = style;
    r.obliqueAngle = angle * one;
    return r;
}

@("matching.FTD27.weightPhases")
@safe unittest
{
    auto c = synthetic();
    // 400–500: at least it up to 500, ascending; then below, descending; then above 500.
    assert(styleOf(*c, matched(*c, req("Syn", 400))) == "W400");
    assert(styleOf(*c, matched(*c, req("Syn", 450))) == "W500");
    // Below 400: at most it, descending.
    assert(styleOf(*c, matched(*c, req("Syn", 350))) == "W300");
    assert(styleOf(*c, matched(*c, req("Syn", 50))) == "W100");
    // Above 500: at least it, ascending; then below, descending.
    assert(styleOf(*c, matched(*c, req("Syn", 550))) == "W600");
    assert(styleOf(*c, matched(*c, req("Syn", 950))) == "W900");
    // A 500-only family: every request finds 500.
    foreach (w; [400u, 500, 600, 100])
        assert(matched(*c, req("Medium", w)).weight == 500 * one);
    const m = matched(*c, req("Medium", 450));
    assert(m.score.weight.phase == 0 && m.score.weight.distance == 50 * one);
    assert(matched(*c, req("Medium", 350)).score.weight.phase == 1);
}

@("matching.FTD27.widthPhases")
@safe unittest
{
    auto c = synthetic();
    // At most 100 %: narrower-or-equal descending. 80 % finds 75 %, where only 300 and 700 exist.
    const m = matched(*c, req("Syn", 400, 80));
    assert(m.width == 75 * one && styleOf(*c, m) == "Condensed Light");
    assert(m.score.width.phase == 0 && m.score.width.distance == 5 * one);
    // Above 100 %: wider ascending, none, then narrower descending: 100 %.
    const wide = matched(*c, req("Syn", 400, 112));
    assert(wide.width == 100 * one && wide.score.width.phase == 1 && styleOf(*c, wide) == "W400");
    // 75 % exactly, weight 600: above 500, at least it ascending → 700.
    assert(styleOf(*c, matched(*c, req("Syn", 600, 75))) == "Condensed Bold");
}

@("matching.FTD27.stylePhases")
@safe unittest
{
    auto c = synthetic();
    // Italic first.
    assert(styleOf(*c, matched(*c, req("Syn", 400, 100, StyleRequest.italic))) == "Italic");
    assert(styleOf(*c, matched(*c, req("Syn", 700, 100, StyleRequest.italic))) == "Bold Italic");
    // Oblique below 11°: (0°, a] descending → 10°.
    auto m = matched(*c, req("Syn", 400, 100, StyleRequest.oblique, 10));
    assert(styleOf(*c, m) == "Oblique 10" && m.oblique == 10 * one && m.score.style == StepScore(0, 0));
    // Oblique 20°: at least 20° none; (0°, 20°) descending → 10°.
    m = matched(*c, req("Syn", 400, 100, StyleRequest.oblique, 20));
    assert(styleOf(*c, m) == "Oblique 10" && m.score.style == StepScore(1, 10 * one));
    // 11° against 8° and 12°: at least 11° ascending → 12°; 10° → (0°, 10°] descending → 8°.
    assert(styleOf(*c, matched(*c, req("Slants", 400, 100, StyleRequest.oblique, 11))) == "Twelve");
    assert(styleOf(*c, matched(*c, req("Slants", 400, 100, StyleRequest.oblique, 10))) == "Eight");
    // Normal against Regular and Italic: the upright face, never the italic (review blocker).
    assert(styleOf(*c, matched(*c, req("Pair"))) == "Regular");
    // Italic against a family with only a −10° backslant: found in the last phase.
    m = matched(*c, req("Back", 400, 100, StyleRequest.italic));
    assert(m.oblique == -10 * one && m.score.style.phase == 3 && !m.syntheticOblique);
    // Normal against Syn: the upright 400 even though italics and obliques exist.
    assert(styleOf(*c, matched(*c, req("Syn"))) == "W400");
    // A negative request mirrors: −10° against 8° and 12° (both positive) → italic none → upright none → 8°.
    m = matched(*c, req("Slants", 400, 100, StyleRequest.oblique, -10));
    assert(m.score.style.phase == 3 && styleOf(*c, m) == "Eight");
}

@("matching.FTD29.synthesis")
@safe unittest
{
    auto c = synthetic();
    // Bold from a 500-only family: emboldened at 1/24 em.
    auto m = matched(*c, req("Medium", 700));
    assert(m.syntheticBold && m.synthesis.emboldenStrength == emboldenOneTwentyFourth);
    assert(!matched(*c, req("Medium", 590)).syntheticBold);
    auto noBold = req("Medium", 700);
    noBold.synthesizeWeight = false;
    assert(!matched(*c, noBold).syntheticBold);
    // Italic from an upright-only family: slanted at 14°, unless oblique-only.
    m = matched(*c, req("Medium", 500, 100, StyleRequest.italic));
    assert(m.syntheticOblique && m.synthesis.obliqueSlant == 16_340);
    auto obliqueOnly = req("Medium", 500, 100, StyleRequest.italic);
    obliqueOnly.obliqueOnly = true;
    assert(!matched(*c, obliqueOnly).syntheticOblique);
    m = matched(*c, req("Medium", 500, 100, StyleRequest.oblique, 20));
    assert(m.synthesis.obliqueSlant == 23_853);
    // An italic face needs no slant.
    assert(!matched(*c, req("Syn", 400, 100, StyleRequest.italic)).syntheticOblique);
}

@("matching.FTD26.familiesAndErrors")
@safe unittest
{
    auto c = synthetic();
    MatchRequest r;
    r.families = ["Missing", "medium", "Syn"];
    const m = matched(*c, r);
    assert(m.found && m.score.family == 1 && c.text(c.records[m.record].family) == "Medium");
    r.families = ["Missing"];
    assert(!matched(*c, r).found);
    r.weight = 1_001 * one;
    assert(matchFont(*c, r).error.kind == FontErrorKind.badValue);
    r = req("Syn");
    r.width = 49 * one;
    assert(matchFont(*c, r).error.kind == FontErrorKind.badValue);
    // Scores order by family first, then width, style and weight.
    assert(matched(*c, req("Syn", 400)).score < matched(*c, req("Syn", 450)).score);
}

@("matching.FTD27.variableFamily")
@safe unittest
{
    // One face covering weights 100–900 and widths 75–100 %.
    StyledFace v = StyledFace("Var", "Regular");
    v.extra = [TableData("fvar", fvarTable([FvarAxis("wght", 100 * one, 400 * one, 900 * one),
        FvarAxis("wdth", 75 * one, 100 * one, 100 * one)]))];
    auto c = catalogOf([v]);
    auto m = matched(*c, req("Var", 450, 80));
    assert(m.weight == 450 * one && m.width == 80 * one && m.score.weight == StepScore(0, 0));
    assert(m.userCoordinates == [UserCoordinateOf("wdth", 80), UserCoordinateOf("wght", 450)]);
    m = matched(*c, req("Var", 950, 120));
    assert(m.weight == 900 * one && m.width == 100 * one && m.score.width.phase == 1);
}

private auto UserCoordinateOf(string tag, int value) @safe
{
    import sparkles.font.instance : UserCoordinate;

    return UserCoordinate(Tag(tag), value * one);
}
