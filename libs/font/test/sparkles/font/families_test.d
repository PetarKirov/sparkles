/**
Families for a picker (FTD47–FTD51): grouping synthetic families' records
into real style members, and the bundled and corpus faces' spacing, styles,
axes and ligatures.
*/
module sparkles.font.families_test;

import std.conv : to;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.vfs : ambientAuthority, MemNode, MemVfs;
import sparkles.event_horizon.sys.vfs : BlockingVfs;
import sparkles.test_runner.skip : skipTest;

import sparkles.font.catalog;
import sparkles.font.corpus : bundled, fontsPath, testFontsPath;
import sparkles.font.errors : Tag;
import sparkles.font.face : openFace;
import sparkles.font.families;
import sparkles.font.fixtures : StyledFace, styledFont;
import sparkles.font.instance : UserCoordinate;
import sparkles.font.matching : fixedOne;

/// A catalog of memory sources, one per face.
private Catalog* memoryCatalog(const(StyledFace)[] faces) @safe
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

/// A catalog of the named files under `dir`.
private Catalog* fileCatalog(string dir, const(char[])[] names) @system
{
    auto c = new Catalog;
    auto r = new BuildReport;
    const sources = [FontSource.files("files", dir, names)];
    assert(!buildCatalog(new BlockingVfs, sources, BuildOptions.init, ambientAuthority(), *c, *r).hasError);
    assert(r.failed == 0 && r.listed == names.length, r.listed.to!string);
    return c;
}

/// The family named `name` among `families`.
private const(FontFamily) named(ref const Catalog c, const(FontFamily)[] families, string name) @safe
{
    foreach (f; families)
        if (c.text(f.name) == name)
            return f;
    assert(false, "no family " ~ name);
}

private string styleName(ref const Catalog c, in StyleFace s) @safe => c.text(c.records[s.record].styleName).idup;

@("families.collect.realMembersOnly")
@safe unittest
{
    auto c = memoryCatalog([
        StyledFace("Four", "Regular", 400),
        StyledFace("Four", "Bold", 700, 5, 0x20),
        StyledFace("Four", "Italic", 400, 5, 1),
        StyledFace("Four", "Bold Italic", 700, 5, 0x21),
        StyledFace("Pair", "Regular", 400),
        StyledFace("Pair", "Italic", 400, 5, 1),
        StyledFace("Semi", "Medium", 500),
        StyledFace("Semi", "SemiBold", 600),
        StyledFace("Slant", "Regular", 400),
        StyledFace("Slant", "Oblique", 400, 5, 0x200, -10),
        StyledFace("Back", "Backslant", 400, 5, 0x200, 10),
    ]);
    UniqueBuffer!FontFamily families;
    collectFamilies(*c, families);
    assert(families.length == 5);
    // ASCII-folded name order.
    assert(c.text(families[][0].name) == "Back" && c.text(families[][4].name) == "Slant");

    const four = named(*c, families[], "Four");
    foreach (style, expected; ["Regular", "Bold", "Italic", "Bold Italic"])
        assert(styleName(*c, four[cast(FamilyStyle) style]) == expected, expected);
    assert(!four.variable && !four.weight.declared && !four.opticalSize.declared);

    const pair = named(*c, families[], "Pair");
    assert(styleName(*c, pair[FamilyStyle.italic]) == "Italic");
    assert(!pair[FamilyStyle.bold].present && !pair[FamilyStyle.boldItalic].present, "no faux bold");
    const controls = fontControls(pair);
    assert(controls.state(FontControl.bold) == ControlState.unsupported && controls.supports(FontControl.italic));

    const semi = named(*c, families[], "Semi");
    assert(styleName(*c, semi[FamilyStyle.regular]) == "Medium");
    assert(styleName(*c, semi[FamilyStyle.bold]) == "SemiBold", "600 is bold enough");
    assert(!semi[FamilyStyle.italic].present);

    // A forward oblique is an italic; a backslant is not.
    assert(styleName(*c, named(*c, families[], "Slant")[FamilyStyle.italic]) == "Oblique");
    const back = named(*c, families[], "Back");
    assert(back[FamilyStyle.regular].present && !back[FamilyStyle.italic].present);
}

@("families.ligatures.absentGsub")
@safe unittest
{
    const bytes = styledFont(StyledFace("Plain"));
    const face = openFace(bytes, 0);
    assert(face.hasValue && ligatureSupport(face.value) == LigatureSupport.none);
}

@("families.files.monospaceAndStyles")
@system unittest
{
    const dir = fontsPath;
    if (dir is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    auto c = fileCatalog(dir, ["DejaVuSansMono.ttf", "DejaVuSansMono-Bold.ttf", "DejaVuSansMono-Oblique.ttf",
        "DejaVuSansMono-BoldOblique.ttf", "Roboto-Regular.ttf", "Roboto-Bold.ttf",
        "FiraCodeNerdFontMono-Regular.ttf", "FiraCodeNerdFontMono-Bold.ttf"]);
    UniqueBuffer!FontFamily families;
    collectFamilies(*c, families);
    assert(families.length == 3, families.length.to!string);

    const dejavu = named(*c, families[], "DejaVu Sans Mono");
    assert(dejavu.monospace);
    foreach (style, expected; ["Book", "Bold", "Oblique", "Bold Oblique"])
        assert(styleName(*c, dejavu[cast(FamilyStyle) style]) == expected, styleName(*c, dejavu[cast(FamilyStyle) style]));

    const roboto = named(*c, families[], "Roboto");
    assert(!roboto.monospace, "a proportional face is not monospace");
    assert(roboto[FamilyStyle.bold].present && !roboto[FamilyStyle.italic].present);
    const controls = fontControls(roboto);
    assert(controls.state(FontControl.italic) == ControlState.unsupported
        && controls.state(FontControl.weight) == ControlState.unsupported);

    const fira = named(*c, families[], "FiraCode Nerd Font Mono");
    assert(fira.monospace && fira[FamilyStyle.bold].present && !fira[FamilyStyle.boldItalic].present);

    // The record's path names the file it was read from.
    UniqueBuffer!char path;
    assert(writeRecordPath(*c, dejavu[FamilyStyle.bold].record, path));
    assert(path[] == dir ~ "/DejaVuSansMono-Bold.ttf", path[].idup);
}

@("families.files.ligatures")
@system unittest
{
    if (fontsPath is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    const fira = bundled("FiraCodeNerdFontMono-Regular.ttf");
    assert(ligatureSupport(openFace(fira, 0).value) == LigatureSupport.declared, "Fira Code's calt");
    const maple = bundled("MapleMono-NF-CN-Regular.ttf");
    assert(ligatureSupport(openFace(maple, 0).value) == LigatureSupport.declared);
}

@("families.files.declaredAxes")
@system unittest
{
    const dir = testFontsPath;
    if (dir is null)
        return skipTest("SPARKLES_FONT_TEST_CORPUS is unset");
    auto c = fileCatalog(dir, ["SourceSerif4Variable-Roman.otf", "SourceSerif4Variable-Italic.otf"]);
    UniqueBuffer!FontFamily families;
    collectFamilies(*c, families);
    assert(families.length == 1, families.length.to!string);
    const f = families[][0];
    assert(f.variable && !f.monospace);
    assert(f.weight.declared && f.weight.minValue <= 400 * fixedOne && f.weight.maxValue >= 700 * fixedOne);
    assert(f.opticalSize.declared && f.opticalSize.minValue < f.opticalSize.maxValue);
    // The variable bold is the roman face at `wght` 700, a real instance.
    const bold = f[FamilyStyle.bold];
    assert(bold.record == f[FamilyStyle.regular].record);
    bool wght700;
    foreach (co; bold.userCoordinates)
        wght700 |= co.tag == Tag("wght") && co.value == 700 * fixedOne;
    assert(wght700);
    assert(f[FamilyStyle.italic].present && f[FamilyStyle.italic].record != f[FamilyStyle.regular].record);
    const controls = fontControls(f);
    assert(controls.supports(FontControl.weight) && controls.supports(FontControl.opticalSize)
        && controls.supports(FontControl.boldItalic));

    DocumentFont d;
    d.size = 300; // clamped to 72, then into the axis
    UserCoordinate[6] co;
    const n = instanceCoordinates(f, FamilyStyle.regular, d, co);
    assert(n >= 2);
    foreach (x; co[0 .. n])
        if (x.tag == Tag("opsz"))
            assert(x.value == f.opticalSize.clamp(72 * fixedOne));
}

@("families.files.bundleMonospaceFilter")
@system unittest
{
    const dir = fontsPath;
    if (dir is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    auto c = new Catalog;
    auto r = new BuildReport;
    const sources = [FontSource.bundle("bundle", dir)];
    assert(!buildCatalog(new BlockingVfs, sources, BuildOptions.init, ambientAuthority(), *c, *r).hasError);
    UniqueBuffer!FontFamily families;
    collectFamilies(*c, families);
    string[] mono;
    foreach (f; families[])
        if (f.monospace)
            mono ~= c.text(f.name).idup;
    // Emoji and SignWriting have one advance but no letters; Noto Sans and Roboto are proportional.
    assert(mono == ["DejaVu Sans Mono", "FiraCode Nerd Font Mono", "Maple Mono NF CN", "Uiua386"], mono.to!string);
    assert(families.length > 150);
}
