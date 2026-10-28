/**
The correction registry (`docs/specs/font/SPEC.md` FTD8–FTD12,
`docs/specs/font/discovery.md` FTD44–FTD46).

Some widely installed fonts store values their authors did not mean, and
HarfBuzz and FreeType correct them on recognizing the font. The registry
lists each such correction this library applies: its identifier, the engine
and revision it follows, its signature and its effect. `openFace` recognizes
a face's entries under `CorrectionPolicy.apply`, from the table directory and
table headers; a result an entry changes carries the entry's `Correction`.
With `CorrectionPolicy.off` every result is the stored value.

The signatures' data (the `GDEF` blocklist, the legacy Arabic code pages and
FreeType's tricky fonts) is generated into `sparkles.font.correction_data`.
Nothing here allocates.
*/
module sparkles.font.corrections;

import sparkles.font.bytes : be16, be32, fits;
import sparkles.font.correction_data : arabicPuaSimplified, arabicPuaTraditional, GdefLengths,
    gdefBlocklist, PuaPair, trickyNames, trickyTables;
import sparkles.font.errors : Tag;
import sparkles.font.face : Face, OutlineFormat;
import sparkles.font.names : name, NameRecord;
import sparkles.font.tables : os2;

@safe pure nothrow @nogc:

/// An entry of the registry (FTD8); `none` marks a result no entry changed.
enum Correction : ubyte
{
    none,
    /// FTD9: Cambria Math's two minimum heights, stored swapped.
    cambriaMathMinHeights,
    /// FTD10: a `GDEF` HarfBuzz ignores, read as absent.
    blocklistedGdef,
    /// FTD11: Simplified Arabic's legacy code page in a symbol character map.
    arabicSimplifiedPage,
    /// FTD11: Traditional Arabic's legacy code page in a symbol character map.
    arabicTraditionalPage,
    /// FTD12: a face only its hinting bytecode draws correctly.
    requiresBytecode,
}

/// Whether `openFace` applies the registry (FTD44).
enum CorrectionPolicy : ubyte
{
    apply,
    off,
}

/// What the registry records about an entry (FTD8).
struct CorrectionInfo
{
    /// A stable identifier, `engine.name`.
    string identifier;
    /// The engine and revision whose behaviour the entry follows.
    string engine;
    /// How a face is recognized.
    string signature;
    /// What the entry changes.
    string effect;
}

/// The registry, indexed by `Correction`.
immutable CorrectionInfo[Correction.max + 1] correctionRegistry = [
    CorrectionInfo("none", "", "", ""),
    CorrectionInfo("harfbuzz.cambria-math-min-heights", "HarfBuzz 14.6.0 (MATH::is_bad_cambria, harfbuzz#4653)",
        "MATH is 25,722 bytes, delimitedSubFormulaMinHeight 3,000 and displayOperatorMinHeight 2,500",
        "the two minimum heights are reported swapped"),
    CorrectionInfo("harfbuzz.gdef-blocklist", "HarfBuzz 14.6.0 (OT::GDEF::is_blocklisted)",
        "the lengths of GDEF, GSUB and GPOS match a blocklisted triple",
        "every GDEF reading reports the table absent"),
    CorrectionInfo("harfbuzz.arabic-pua-simplified", "HarfBuzz 14.6.0 (_hb_arabic_pua_simp_map)",
        "a symbol cmap (3, 0) and OS/2 version 0 with fsSelection high byte 0xB2",
        "Arabic scalars map through the Simplified Arabic private-use code page"),
    CorrectionInfo("harfbuzz.arabic-pua-traditional", "HarfBuzz 14.6.0 (_hb_arabic_pua_trad_map)",
        "a symbol cmap (3, 0) and OS/2 version 0 with fsSelection high byte 0xB3",
        "Arabic scalars map through the Traditional Arabic private-use code page"),
    CorrectionInfo("freetype.tricky", "FreeType 2.14.3 (tt_check_trickyness)",
        "a tricky family name, or cvt, fpgm and prep matching a tricky face by length and checksum",
        "the face requires hinting bytecode; the rasterizer refuses it"),
];

/// The registry's record of `c`.
CorrectionInfo correctionInfo(Correction c) => correctionRegistry[c];

/// A set of registry entries.
struct Corrections
{
    @safe pure nothrow @nogc:

    private ubyte bits_;

    /// Whether `c` is in the set.
    bool has(Correction c) const scope => c != Correction.none && (bits_ & (1 << c)) != 0;

    /// Whether the set is empty.
    bool empty() const scope => bits_ == 0;

    /// The set with `c` added.
    Corrections with_(Correction c) const scope
        => c == Correction.none ? this : Corrections(cast(ubyte)(bits_ | (1 << c)));

    /// The entries in registry order.
    auto opSlice() const scope => CorrectionRange(bits_, 1);

    /// The raw bits, one per entry; for serialization.
    ubyte bits() const scope => bits_;

    /// The set the raw `bits` name; unknown entries are dropped.
    static Corrections fromBits(ubyte bits)
        => Corrections(cast(ubyte)(bits & ((1 << (Correction.max + 1)) - 2)));
}

/// The entries of a `Corrections`, in registry order.
struct CorrectionRange
{
    @safe pure nothrow @nogc:

    private ubyte bits_;
    private uint next_;

    private this(ubyte bits, uint from)
    {
        bits_ = bits;
        next_ = from;
        skip();
    }

    private void skip() scope
    {
        while (next_ <= Correction.max && (bits_ & (1 << next_)) == 0)
            ++next_;
    }

    bool empty() const scope => next_ > Correction.max;
    Correction front() const scope => cast(Correction) next_;
    void popFront() scope
    {
        ++next_;
        skip();
    }
}

///
@("corrections.set")
unittest
{
    auto s = Corrections.init.with_(Correction.requiresBytecode).with_(Correction.cambriaMathMinHeights);
    assert(s.has(Correction.requiresBytecode) && !s.has(Correction.blocklistedGdef) && !s.empty);
    Correction[2] seen;
    size_t n;
    foreach (c; s[])
        seen[n++] = c;
    assert(n == 2 && seen == [Correction.cambriaMathMinHeights, Correction.requiresBytecode]);
    assert(Corrections.fromBits(s.bits) == s && Corrections.fromBits(0xFF).bits == 0b11_1110);
    assert(correctionInfo(Correction.blocklistedGdef).identifier == "harfbuzz.gdef-blocklist");
}

// ---------------------------------------------------------------------------
// Recognition at open (FTD44, FTD46)
// ---------------------------------------------------------------------------

/**
The entries `face` triggers (FTD46), read from its table directory and
headers. Costs O(1) per entry, except `requiresBytecode`, which decodes the
family name records and sums a `cvt `, `fpgm` or `prep` whose length a tricky
face lists, at most 97,337 bytes.
*/
package Corrections recognizeCorrections(scope const Face face)
{
    Corrections s;
    if (cambriaMath(face))
        s = s.with_(Correction.cambriaMathMinHeights);
    if (blocklistedGdef(face))
        s = s.with_(Correction.blocklistedGdef);
    s = s.with_(arabicPage(face));
    if (face.outlines == OutlineFormat.trueType && tricky(face))
        s = s.with_(Correction.requiresBytecode);
    return s;
}

/// The directory length of `tag`, or 0 without the table.
private uint tableLength(scope const Face face, Tag tag)
{
    const i = face.find(tag);
    return i == face.tableCount ? 0 : face.record(i).length;
}

/// FTD9: `MATH` is 25,722 bytes and its two stored minimum heights are 3,000 and 2,500.
private bool cambriaMath(scope const Face face)
{
    if (tableLength(face, Tag("MATH")) != 25_722)
        return false;
    const t = face.table(Tag("MATH"));
    if (t.hasError || t.value.length < 6)
        return false;
    const d = t.value;
    const constants = be16(d, 4);
    // delimitedSubFormulaMinHeight and displayOperatorMinHeight are constants 2 and 3.
    if (constants == 0 || !fits(d.length, constants + 4, 4))
        return false;
    return be16(d, constants + 4) == 3_000 && be16(d, constants + 6) == 2_500;
}

/// FTD10: the `GDEF`, `GSUB` and `GPOS` lengths are a blocklisted triple.
private bool blocklistedGdef(scope const Face face)
{
    const key = GdefLengths(tableLength(face, Tag("GDEF")), tableLength(face, Tag("GSUB")),
        tableLength(face, Tag("GPOS")));
    if (key.gdef == 0)
        return false;
    size_t lo = 0, hi = gdefBlocklist.length;
    while (lo < hi)
    {
        const mid = (lo + hi) / 2;
        const m = gdefBlocklist[mid];
        if (m == key)
            return true;
        if (m.gdef < key.gdef || m.gdef == key.gdef && (m.gsub < key.gsub
                || m.gsub == key.gsub && m.gpos < key.gpos))
            lo = mid + 1;
        else
            hi = mid;
    }
    return false;
}

/**
FTD11: a symbol encoding record, and `OS/2` version 0 whose `fsSelection`
high byte names a legacy Arabic page. The symbol record is the first the
character map tries (FTP25), so it is the one in use unless it is malformed;
`CharMap` applies the page only to a symbol subtable it built.
*/
private Correction arabicPage(scope const Face face)
{
    const o = os2(face);
    if (o.hasError || o.value.version_ != 0)
        return Correction.none;
    const page = o.value.fsSelection >> 8;
    if (page != 0xB2 && page != 0xB3)
        return Correction.none;
    const t = face.table(Tag("cmap"));
    if (t.hasError)
        return Correction.none;
    const cmap = t.value;
    // Open checked the header and that every encoding record is inside the table.
    foreach (i; 0 .. be16(cmap, 2))
        if (be16(cmap, 4 + 8 * i) == 3 && be16(cmap, 6 + 8 * i) == 0)
            return page == 0xB2 ? Correction.arabicSimplifiedPage : Correction.arabicTraditionalPage;
    return Correction.none;
}

/// The private-use code `page` gives scalar `cp`, or 0 (`_hb_arabic_pua_*_map`).
package uint arabicPuaCode(Correction page, dchar cp)
in (page == Correction.arabicSimplifiedPage || page == Correction.arabicTraditionalPage)
{
    const table = page == Correction.arabicSimplifiedPage ? arabicPuaSimplified : arabicPuaTraditional;
    if (cp > 0xFFFF)
        return 0;
    size_t lo = 0, hi = table.length;
    while (lo < hi)
    {
        const mid = (lo + hi) / 2;
        if (table[mid].unicode < cp)
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo < table.length && table[lo].unicode == cp ? table[lo].pua : 0;
}

/// The scalars `page` maps, ascending, with their codes.
package immutable(PuaPair)[] arabicPuaPairs(Correction page)
    => page == Correction.arabicSimplifiedPage ? arabicPuaSimplified : arabicPuaTraditional;

///
@("corrections.arabicPuaCode")
unittest
{
    // ArabicPUASimplified.txt: 0xF10D	0x200D	# ZERO WIDTH JOINER.
    assert(arabicPuaCode(Correction.arabicSimplifiedPage, '‍') == 0xF10D);
    assert(arabicPuaCode(Correction.arabicSimplifiedPage, 'A') == 0);
    assert(arabicPuaCode(Correction.arabicTraditionalPage, '\U0001F600') == 0);
}

/// FTD12: FreeType's tricky-face test, by family name or by `cvt `, `fpgm` and `prep`.
private bool tricky(scope const Face face)
{
    char[256] buffer;
    const family = freeTypeFamily(face, buffer);
    if (family.length)
    {
        const stripped = skipSubsetTag(family);
        foreach (t; trickyNames)
            if (contains(stripped, t))
                return true;
    }
    return trickyTablesMatch(face);
}

/// Whether `hay` contains `needle`.
private bool contains(scope const(char)[] hay, scope const(char)[] needle)
{
    if (needle.length > hay.length)
        return false;
    foreach (i; 0 .. hay.length - needle.length + 1)
        if (hay[i .. i + needle.length] == needle)
            return true;
    return false;
}

/// `name` without a leading `ABCDEF+` subset tag, as `tt_skip_pdffont_random_tag`.
package const(char)[] skipSubsetTag(return scope const(char)[] name)
{
    if (name.length < 8 || name[6] != '+')
        return name;
    foreach (c; name[0 .. 6])
        if (c < 'A' || c > 'Z')
            return name;
    return name[7 .. $];
}

///
@("corrections.skipSubsetTag")
unittest
{
    assert(skipSubsetTag("ABCDEF+MingLiU") == "MingLiU");
    assert(skipSubsetTag("ABCDEF+") == "ABCDEF+" && skipSubsetTag("ABCDeF+X") == "ABCDeF+X");
}

/**
The family name FreeType gives `face`, as ASCII into `buffer` (cut at its
length): name ID 16, else 1, when `OS/2` exists with `fsSelection` bit 8;
otherwise 21, else 16, else 1. Empty without one.
*/
package const(char)[] freeTypeFamily(scope const Face face, return scope char[] buffer)
{
    const o = os2(face);
    static immutable ushort[2] wws = [16, 1];
    static immutable ushort[3] other = [21, 16, 1];
    const ids = o.hasValue && (o.value.fsSelection & 0x100) ? wws[] : other[];
    foreach (id; ids)
    {
        bool found;
        const n = freeTypeName(face, id, buffer, found);
        if (found)
            return buffer[0 .. n];
    }
    return buffer[0 .. 0];
}

/**
Name `id` as FreeType's `tt_face_get_name` chooses and converts it: the
last English Windows record of encoding 0, 1 or 10, else the first such
record, unless a Macintosh record (English, else Roman) exists and that
Windows record is not English; else the last Unicode or ISO record. Each code
below 32 or above 127 becomes `?`, and a NUL ends the name. Records whose
string lies outside the table, or is empty, do not count. Returns the length
written; `found` says whether a record was chosen.
*/
private size_t freeTypeName(scope const Face face, ushort id, scope char[] buffer, out bool found)
{
    const table = name(face);
    if (table.hasError)
        return 0;
    long win = -1, appleEnglish = -1, appleRoman = -1, unicode = -1;
    bool isEnglish;
    size_t i;
    foreach (r; table.value.records)
    {
        scope (exit)
            ++i;
        if (r.hasError || r.value.nameID != id || r.value.bytes.length == 0)
            continue;
        const rec = r.value;
        switch (rec.platformID)
        {
            case 0, 2:
                unicode = i;
                break;
            case 1:
                if (rec.languageID == 0)
                    appleEnglish = i;
                else if (rec.encodingID == 0)
                    appleRoman = i;
                break;
            case 3:
                const english = (rec.languageID & 0x3FF) == 0x009;
                if ((win == -1 || english) && (rec.encodingID == 0 || rec.encodingID == 1
                        || rec.encodingID == 10))
                {
                    isEnglish = english;
                    win = i;
                }
                break;
            default:
                break;
        }
    }
    const apple = appleEnglish >= 0 ? appleEnglish : appleRoman;
    long chosen = -1;
    bool wide;
    if (win >= 0 && !(apple >= 0 && !isEnglish))
    {
        chosen = win;
        wide = true;
    }
    else if (apple >= 0)
        chosen = apple;
    else if (unicode >= 0)
    {
        chosen = unicode;
        wide = true;
    }
    if (chosen < 0)
        return 0;
    found = true;
    const bytes = table.value.records[cast(size_t) chosen].value.bytes;
    size_t n;
    const step = wide ? 2 : 1;
    for (size_t at = 0; at + step <= bytes.length && n < buffer.length; at += step)
    {
        const code = wide ? be16(bytes, at) : bytes[at];
        if (code == 0)
            break;
        buffer[n++] = code < 32 || code > 127 ? '?' : cast(char) code;
    }
    return n;
}

/// Whether `cvt `, `fpgm` and `prep` match a tricky face (`tt_check_trickyness_sfnt_ids`).
private bool trickyTablesMatch(scope const Face face)
{
    static immutable Tag[3] tags = [Tag("cvt "), Tag("fpgm"), Tag("prep")];
    uint[trickyTables.length] matched;
    bool[3] has;
    foreach (k, tag; tags)
    {
        const i = face.find(tag);
        if (i == face.tableCount)
            continue;
        has[k] = true;
        const length = face.record(i).length;
        bool summed;
        uint sum;
        foreach (j, entry; trickyTables)
        {
            if (entry[k].length != length)
                continue;
            if (!summed)
            {
                sum = tableSum(face, tag);
                summed = true;
            }
            if (entry[k].checksum == sum && ++matched[j] == 3)
                return true;
        }
    }
    foreach (j, entry; trickyTables)
    {
        foreach (k; 0 .. 3)
            if (!has[k] && entry[k].length == 0)
                ++matched[j];
        if (matched[j] == 3)
            return true;
    }
    return false;
}

/// The table's checksum computed from its bytes, as `tt_synth_sfnt_checksum`; 0 when unreadable.
private uint tableSum(scope const Face face, Tag tag)
{
    const t = face.table(tag);
    if (t.hasError)
        return 0;
    const d = t.value;
    uint sum;
    size_t at;
    for (; at + 4 <= d.length; at += 4)
        sum += be32(d, at);
    uint shift = 24;
    for (; at < d.length; ++at, shift -= 8)
        sum += uint(d[at]) << shift;
    return sum;
}
