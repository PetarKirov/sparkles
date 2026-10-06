module sparkles.font.names_test;

import sparkles.font.corpus : bundled, fontsPath;
import sparkles.font.errors : FontErrorKind, Tag;
import sparkles.font.face : openFace;
import sparkles.font.fixtures;
import sparkles.font.names;
import sparkles.test_runner.skip : skipTest;

private ubyte[] fontWithNames(const(NameEntry)[] entries) @safe pure nothrow
    => sfnt(minimalTables ~ TableData("name", name(entries)));

@("names.utf16be.decodesPairsAndRejectsSurrogates")
@safe pure nothrow
unittest
{
    static immutable ubyte[6] good = [0x00, 0x41, 0xD8, 0x3D, 0xDE, 0x00];
    static immutable ubyte[6] lone = [0x00, 0x41, 0xD8, 0x3D, 0x00, 0x42];
    const bytes = fontWithNames([NameEntry(3, 1, 0x409, 4, good[]), NameEntry(3, 1, 0x409, 1, lone[]),
        NameEntry(0, 4, 0, 2, utf16be("Regular"))]);
    const table = openFace(bytes).value.name.value;
    assert(table.count == 3);

    char[16] out_ = 'x';
    const r0 = table.record(0).value;
    assert(r0.decodedLength.value == 5);
    assert(r0.decode(out_[]).value == "A😀");

    // The trace of testing.md: an unpaired high surrogate at string byte 2.
    const r1 = table.record(1).value;
    out_[] = 'x';
    const e = r1.decode(out_[]);
    assert(e.hasError && e.error.kind == FontErrorKind.invalidEncoding && e.error.tag == Tag("name"));
    const storage = 6 + 12 * 3;
    assert(e.error.tableOffset == storage + 6 + 2);
    assert(r1.decodedLength.error.kind == FontErrorKind.invalidEncoding);
    foreach (c; out_) assert(c == 'x');
    assert(r1.bytes == lone[]); // raw bytes stay inspectable

    assert(table.record(2).value.decode(out_[]).value == "Regular");
}

@("names.utf16be.oddLengthAndReversedPair")
@safe pure nothrow
unittest
{
    static immutable ubyte[3] odd = [0x00, 0x41, 0x00];
    static immutable ubyte[4] reversed = [0xDE, 0x00, 0xD8, 0x3D];
    const table = openFace(fontWithNames([NameEntry(3, 1, 0x409, 1, odd[]),
        NameEntry(3, 1, 0x409, 2, reversed[])])).value.name.value;
    char[8] out_;
    assert(table.record(0).value.decode(out_[]).error.kind == FontErrorKind.invalidEncoding);
    assert(table.record(1).value.decode(out_[]).error.kind == FontErrorKind.invalidEncoding);
}

@("names.macRomanAndUnsupported")
@safe pure nothrow
unittest
{
    static immutable ubyte[3] mac = ['A', 0xDB, 0x8A]; // A € ä
    const table = openFace(fontWithNames([NameEntry(1, 0, 0, 1, mac[]), NameEntry(1, 0, 15, 1, mac[]),
        NameEntry(3, 3, 0, 1, mac[])])).value.name.value;
    char[16] out_;
    const r = table.record(0).value;
    assert(r.encoding == NameEncoding.macRoman && r.decodedLength.value == 6);
    assert(r.decode(out_[]).value == "A€ä");
    assert(r.decode(out_[0 .. 5]).error.kind == FontErrorKind.limitExceeded);
    // Icelandic Mac Roman and Windows Big5 are not decoded.
    assert(table.record(1).value.decode(out_[]).error.kind == FontErrorKind.unsupportedCapability);
    assert(table.record(2).value.decode(out_[]).error.kind == FontErrorKind.unsupportedCapability);
}

@("names.recordOutsideStorageStaysLocal")
@safe pure nothrow
unittest
{
    auto n = name([NameEntry(3, 1, 0x409, 1, utf16be("Ok")), NameEntry(3, 1, 0x409, 2, utf16be("Ok"))]);
    // Second record: string offset far outside the table.
    n[6 + 12 + 10 .. 6 + 12 + 12] = u16(0x7000);
    const table = openFace(sfnt(minimalTables ~ TableData("name", n))).value.name.value;
    assert(table.record(0).hasValue);
    assert(table.record(1).error.kind == FontErrorKind.badOffset);
    size_t errors;
    foreach (r; table.records) errors += r.hasError;
    assert(errors == 1);
}

@("names.version1LanguageTags")
@safe pure nothrow
unittest
{
    // One record with languageID 0x8000 naming tag 0, "en".
    const tag = utf16be("en"), text = utf16be("Hi");
    const storage = 6 + 12 + 2 + 4;
    const t = u16(1) ~ u16(1) ~ u16(storage)
        ~ u16(3) ~ u16(1) ~ u16(0x8000) ~ u16(1) ~ u16(cast(uint) text.length) ~ u16(0)
        ~ u16(1) ~ u16(cast(uint) tag.length) ~ u16(cast(uint) text.length)
        ~ text ~ tag;
    const table = openFace(sfnt(minimalTables ~ TableData("name", t))).value.name.value;
    const r = table.record(0).value;
    assert(r.hasLanguageTag && r.languageTag == tag);
}

@("names.missing")
@safe pure nothrow
unittest
{
    assert(openFace(sfnt(minimalTables)).value.name.error.kind == FontErrorKind.missingTable);
}

@("names.corpus.everyRecordDecodesOrIsUnsupported")
@system
unittest
{
    if (fontsPath is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    foreach (file; ["MapleMono-NF-CN-Regular.ttf", "NotoSans.ttf", "DejaVuSansMono.ttf"])
    {
        const table = openFace(bundled(file)).value.name.value;
        char[4096] buffer;
        foreach (r; table.records)
        {
            assert(r.hasValue, file);
            const text = r.value.decode(buffer[]);
            assert(text.hasValue || text.error.kind == FontErrorKind.unsupportedCapability, file);
        }
    }
}
