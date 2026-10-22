/**
FTS11 JSTF tests: script, extender-glyph and priority enumeration over
a fixture table, and absence on a face without one.
*/
module sparkles.font.jstf_test;

import sparkles.font;
import sparkles.font.fixtures;

/// A feature-index list: count, then indices.
private ubyte[] featureList(const(ushort)[] indices) @safe pure nothrow
{
    ubyte[] t = u16(cast(uint) indices.length);
    foreach (i; indices)
        t ~= u16(i);
    return t;
}

/**
A `JSTF` with one `DFLT` script: extenders {3, 5}, a default language
system whose priority enables GSUB feature 7 for shrinkage and GPOS
feature 9 for extension, with a shrinkage maximum.
*/
private ubyte[] jstfTable() @safe pure nothrow
{
    const shrinkGsub = featureList([7]);
    const extendGpos = featureList([9]);
    // Priority: 10 offset fields, then the two lists.
    const priority = u16(20) ~ u16(0) ~ u16(0) ~ u16(0) ~ u16(20 + 4)
        ~ u16(0) ~ u16(0) ~ u16(cast(uint)(20 + shrinkGsub.length)) ~ u16(0) ~ u16(0)
        ~ shrinkGsub ~ extendGpos;
    // JstfLangSys starts with a priority count, then its offset array.
    const langSys = u16(1) ~ u16(4) ~ priority;
    const extenders = u16(2) ~ u16(3) ~ u16(5); // ExtenderGlyph: count, then glyph IDs
    // Script layout: 12-byte header (extender, default langsys, count,
    // one record), then ExtenderGlyph, then the language system.
    const scriptHeader = 6 + 6;
    const langSysAt = cast(uint)(scriptHeader + extenders.length);
    const script = u16(scriptHeader) ~ u16(langSysAt) ~ u16(1)
        ~ cast(const(ubyte)[]) "ROM " ~ u16(langSysAt) ~ extenders ~ langSys;
    return u32(0x0001_0000) ~ u16(1) ~ cast(const(ubyte)[]) "DFLT" ~ u16(12) ~ script;
}

@("jstf.enumeration.fixture")
@safe pure nothrow
unittest
{
    auto tables = minimalTables(6);
    tables ~= TableData("JSTF", jstfTable());
    const bytes = sfnt(tables);
    const face = openFace(bytes).value;
    assert(hasJstf(face));
    Tag[4] scripts;
    assert(jstfScripts(face, scripts[]).value == 1 && scripts[0] == Tag("DFLT"));
    uint[8] extenders;
    const n = jstfExtenderGlyphs(face, Tag("DFLT"), extenders[]);
    assert(n.hasValue && n.value == 2 && extenders[0] == 3 && extenders[1] == 5);
    const priority = jstfPriority(face, Tag("DFLT"), Tag.init).value;
    assert(priority.present && priority.hasShrinkageMaximum
        && !priority.hasExtensionMaximum);
    assert(priority.shrinkEnableGsubCount == 1 && priority.shrinkEnableGsub[0] == 7);
    assert(priority.extendEnableGposCount == 1 && priority.extendEnableGpos[0] == 9);
    // An unknown language and an unknown script are absent, not errors.
    assert(!jstfPriority(face, Tag("DFLT"), Tag("JAN ")).value.present);
    assert(!jstfPriority(face, Tag("latn"), Tag.init).value.present);
}

@("jstf.enumeration.absent")
@safe pure nothrow
unittest
{
    const bytes = sfnt(minimalTables(2));
    const face = openFace(bytes).value;
    assert(!hasJstf(face));
    Tag[2] scripts;
    assert(jstfScripts(face, scripts[]).value == 0);
    assert(!jstfPriority(face, Tag("DFLT"), Tag.init).value.present);
}
