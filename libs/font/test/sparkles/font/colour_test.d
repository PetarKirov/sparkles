/**
Colour capability (FTI4, FTI10) on hand-built colour tables, their edges and
truncations, and every bundled face.
*/
module sparkles.font.colour_test;

import std.algorithm.searching : endsWith;
import std.file : dirEntries, SpanMode;
import std.path : baseName;

import sparkles.test_runner.skip : skipTest;

import sparkles.font.colour;
import sparkles.font.corpus : bundled, fontsPath;
import sparkles.font.errors : FontErrorKind, Tag;
import sparkles.font.face : openFace;
import sparkles.font.fixtures;

/// The capability of a face holding `tables` beside the minimal ones.
private ColourCapability of(const(TableData)[] tables) @safe pure nothrow
{
    auto all = minimalTables(10) ~ tables;
    const face = openFace(sfnt(all));
    assert(face.hasValue);
    return colourCapability(face.value);
}

/// Whether `s` is present and `has` is `expected`.
private bool holds(in ColourSupport s, bool expected) @safe pure nothrow @nogc
    => s.present && s.has.hasValue && s.has.value == expected && s.usable == expected;

/// Whether `s` is present with an error of `kind`.
private bool fails(in ColourSupport s, FontErrorKind kind) @safe pure nothrow @nogc
    => s.present && s.has.hasError && s.has.error.kind == kind && !s.usable;

@("colour.none")
@safe pure nothrow
unittest
{
    const c = of(null);
    foreach (s; [c.colrLayers, c.colrPaint, c.cpal, c.cbdt, c.sbix, c.svg])
        assert(!s.present && s.has.hasValue && !s.has.value && !s.usable);
}

@("colour.colr")
@safe pure nothrow
unittest
{
    // Version 0 with layers; version 0 with no base glyph records.
    auto c = of([TableData("COLR", colrTable(0, 2, 3))]);
    assert(holds(c.colrLayers, true) && holds(c.colrPaint, false));
    c = of([TableData("COLR", colrTable(0, 0, 0))]);
    assert(holds(c.colrLayers, false) && holds(c.colrPaint, false));
    // Version 1 with paint, with an empty BaseGlyphList, and with a null one.
    c = of([TableData("COLR", colrTable(1, 0, 0, 3))]);
    assert(holds(c.colrLayers, false) && holds(c.colrPaint, true));
    c = of([TableData("COLR", colrTable(1, 1, 1, 0))]);
    assert(holds(c.colrLayers, true) && holds(c.colrPaint, false));
    c = of([TableData("COLR", colrTable(1, 0, 0))]);
    assert(holds(c.colrPaint, false));
    // Version 2: present, unsupported, never claimed.
    c = of([TableData("COLR", colrTable(2, 1, 1, 1))]);
    assert(fails(c.colrLayers, FontErrorKind.unsupportedVersion) && fails(c.colrPaint,
        FontErrorKind.unsupportedVersion));
}

@("colour.colr.malformed")
@safe pure nothrow
unittest
{
    // A header shorter than 14 (version 0) or 34 (version 1) bytes.
    foreach (n; [0, 1, 2, 13])
    {
        const c = of([TableData("COLR", colrTable(0, 1, 1)[0 .. n])]);
        assert(fails(c.colrLayers, FontErrorKind.truncated) && fails(c.colrPaint, FontErrorKind.truncated));
    }
    assert(fails(of([TableData("COLR", colrTable(1, 0, 0, 1)[0 .. 33])]).colrPaint, FontErrorKind.truncated));
    // Base glyph records past the table; layer records past it.
    auto bytes = colrTable(0, 2, 0);
    assert(fails(of([TableData("COLR", bytes[0 .. $ - 1])]).colrLayers, FontErrorKind.truncated));
    bytes = colrTable(0, 1, 2);
    assert(fails(of([TableData("COLR", bytes[0 .. $ - 1])]).colrLayers, FontErrorKind.truncated));
    // A base glyph offset outside the table.
    bytes = colrTable(0, 1, 1);
    bytes[4 .. 8] = [0, 0, 0x70, 0];
    assert(fails(of([TableData("COLR", bytes)]).colrLayers, FontErrorKind.badOffset));
    // A BaseGlyphList outside the table, or whose records run past it.
    bytes = colrTable(1, 0, 0, 2);
    assert(fails(of([TableData("COLR", bytes[0 .. $ - 1])]).colrPaint, FontErrorKind.truncated));
    assert(fails(of([TableData("COLR", bytes[0 .. 36])]).colrPaint, FontErrorKind.truncated));
    bytes[14 .. 18] = [0, 0, 0x70, 0];
    const far = of([TableData("COLR", bytes)]);
    assert(fails(far.colrPaint, FontErrorKind.badOffset) && holds(far.colrLayers, false));
}

@("colour.cpal")
@safe pure nothrow
unittest
{
    assert(holds(of([TableData("CPAL", cpalTable(2))]).cpal, true));
    assert(holds(of([TableData("CPAL", cpalTable(1, 3, 1))]).cpal, true));
    assert(holds(of([TableData("CPAL", cpalTable(0))]).cpal, false));
    assert(fails(of([TableData("CPAL", cpalTable(1, 2, 2))]).cpal, FontErrorKind.unsupportedVersion));
    foreach (n; [0, 11, 13])
        assert(fails(of([TableData("CPAL", cpalTable(2)[0 .. n])]).cpal, FontErrorKind.truncated));
    // Colour records past the table.
    const bytes = cpalTable(1, 4);
    assert(fails(of([TableData("CPAL", bytes[0 .. $ - 1])]).cpal, FontErrorKind.truncated));
}

@("colour.cbdt")
@safe pure nothrow
unittest
{
    assert(holds(of([TableData("CBDT", cbdtTable()), TableData("CBLC", cblcTable(1))]).cbdt, true));
    assert(holds(of([TableData("CBDT", cbdtTable(2)), TableData("CBLC", cblcTable(2, 2))]).cbdt, true));
    assert(holds(of([TableData("CBDT", cbdtTable()), TableData("CBLC", cblcTable(0))]).cbdt, false));
    // CBDT alone: present but missingTable naming CBLC. CBLC alone: no CBDT.
    const alone = of([TableData("CBDT", cbdtTable())]).cbdt;
    assert(fails(alone, FontErrorKind.missingTable) && alone.has.error.tag == Tag("CBLC"));
    assert(!of([TableData("CBLC", cblcTable(1))]).cbdt.present);
    // Versions and truncations.
    assert(fails(of([TableData("CBDT", cbdtTable(4)), TableData("CBLC", cblcTable(1))]).cbdt,
        FontErrorKind.unsupportedVersion));
    assert(fails(of([TableData("CBDT", cbdtTable()), TableData("CBLC", cblcTable(1, 1))]).cbdt,
        FontErrorKind.unsupportedVersion));
    assert(fails(of([TableData("CBDT", cbdtTable()[0 .. 3]), TableData("CBLC", cblcTable(1))]).cbdt,
        FontErrorKind.truncated));
    foreach (n; [0, 7, 55])
        assert(fails(of([TableData("CBDT", cbdtTable()), TableData("CBLC", cblcTable(1)[0 .. n])]).cbdt,
            FontErrorKind.truncated));
}

@("colour.sbixAndSvg")
@safe pure nothrow
unittest
{
    assert(holds(of([TableData("sbix", sbixTable(2))]).sbix, true));
    assert(holds(of([TableData("sbix", sbixTable(0))]).sbix, false));
    assert(fails(of([TableData("sbix", sbixTable(1, 2))]).sbix, FontErrorKind.unsupportedVersion));
    foreach (n; [0, 7, 9])
        assert(fails(of([TableData("sbix", sbixTable(1)[0 .. n])]).sbix, FontErrorKind.truncated));

    assert(holds(of([TableData("SVG ", svgTable(2))]).svg, true));
    assert(holds(of([TableData("SVG ", svgTable(0))]).svg, false));
    assert(fails(of([TableData("SVG ", svgTable(1, 1))]).svg, FontErrorKind.unsupportedVersion));
    foreach (n; [0, 9])
        assert(fails(of([TableData("SVG ", svgTable(1)[0 .. n])]).svg, FontErrorKind.truncated));
    // A document list at the very end, and one outside the table.
    assert(fails(of([TableData("SVG ", svgTable(1)[0 .. 11])]).svg, FontErrorKind.truncated));
    assert(fails(of([TableData("SVG ", svgTable(1)[0 .. 10])]).svg, FontErrorKind.badOffset));
    assert(fails(of([TableData("SVG ", svgTable(2)[0 .. 20])]).svg, FontErrorKind.truncated));
}

@("colour.everyTable")
@safe pure nothrow
unittest
{
    // All six at once are independent.
    const c = of([TableData("CBDT", cbdtTable()), TableData("CBLC", cblcTable(1)),
        TableData("COLR", colrTable(1, 1, 1, 1)), TableData("CPAL", cpalTable(1)),
        TableData("SVG ", svgTable(1)), TableData("sbix", sbixTable(1))]);
    foreach (s; [c.colrLayers, c.colrPaint, c.cpal, c.cbdt, c.sbix, c.svg])
        assert(holds(s, true));
}

@("colour.hostile.truncations")
@safe pure nothrow
unittest
{
    // Every prefix of every table, and every byte set to 0xFF: a defined outcome, no assertion.
    const(ubyte)[][string] tables = [
        "COLR": colrTable(1, 2, 2, 2), "CPAL": cpalTable(2, 2, 1), "CBLC": cblcTable(1),
        "sbix": sbixTable(2), "SVG ": svgTable(2),
    ];
    foreach (tag, full; tables)
        foreach (n; 0 .. full.length)
        {
            cast(void) of([TableData(tag, full[0 .. n]), TableData("CBDT", cbdtTable())]);
            auto bytes = full.dup;
            bytes[n] = 0xFF;
            cast(void) of([TableData(tag, bytes), TableData("CBDT", cbdtTable())]);
        }
}

// ---------------------------------------------------------------------------
// The corpus
// ---------------------------------------------------------------------------

/// Every bundled face gives a defined outcome, and Noto Color Emoji reports its colour tables.
@("colour.corpus.everyFace")
@system
unittest
{
    if (fontsPath is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    size_t faces;
    foreach (entry; dirEntries(fontsPath, SpanMode.shallow))
    {
        if (!entry.name.endsWith(".ttf") && !entry.name.endsWith(".otf"))
            continue;
        const opened = openFace(bundled(baseName(entry.name)));
        if (!opened.hasValue)
            continue;
        ++faces;
        const c = colourCapability(opened.value);
        foreach (s; [c.colrLayers, c.colrPaint, c.cpal, c.cbdt, c.sbix, c.svg])
            assert(s.present || (s.has.hasValue && !s.has.value), entry.name);
    }
    assert(faces > 50);

    // The bundled Noto Color Emoji is the CBDT build: bitmaps, no COLR, CPAL, sbix or SVG.
    const emoji = colourCapability(openFace(bundled("NotoColorEmoji.ttf")).value);
    assert(emoji.cbdt.usable);
    foreach (s; [emoji.colrLayers, emoji.colrPaint, emoji.cpal, emoji.sbix, emoji.svg])
        assert(!s.present);
}
