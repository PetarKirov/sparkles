/**
Face records (`docs/specs/font/discovery.md` FTD19–FTD20): what the catalog
stores about one face, read with this library's parser only (FTD1).

A `FaceRecord` holds fixed-size fields and references into `RecordPools`,
which own its strings, coverage ranges, axes and field errors; the catalog
keeps one set of pools for all its records. `describeFace` reads a face into
a record, appending to the pools; a field it cannot read is defaulted and its
error listed, so one bad table never loses the face (FTD20). Storage comes
from base's buffers, never the garbage collector.
*/
module sparkles.font.face_record;

import sparkles.base.buffer : UniqueBuffer;

import sparkles.font.bytes : be16, be32, fits;
import sparkles.font.cmap : charMap, CodepointRange;
import sparkles.font.colour : colourCapability;
import sparkles.font.corrections : Correction, Corrections;
import sparkles.font.coverage : Coverage;
import sparkles.font.errors : FontError, FontErrorKind, Tag;
import sparkles.font.face : Face, OutlineFormat;
import sparkles.font.instance : axes;
import sparkles.font.names : name, NameRecord;
import sparkles.font.tables : head, os2, post, Spacing, spacing;

@safe nothrow @nogc:

/// The longest name a record keeps, in UTF-8 bytes (FTD19).
enum size_t maxRecordNameBytes = 1_024;
/// The most family aliases a record keeps (FTD19).
enum size_t maxFamilyAliases = 32;
/// 1.0 in F16.16.
private enum int one = 65_536;

/// A string in `RecordPools.strings`.
struct StringRef
{
    uint offset, length;
}

/// A run of elements in one of `RecordPools`' arrays.
struct PoolSpan
{
    uint offset, count;
}

/// One `fvar` axis of a record: user values in F16.16.
struct AxisRecord
{
    Tag tag;
    int minValue, defaultValue, maxValue;
}

/// A record field `describeFace` defaulted, and why (FTD20).
enum RecordField : ubyte
{
    names,
    os2,
    post,
    axes,
    characterMap,
    spacing,
    colour,
    substitutions,
}

/// One field error (FTD20).
struct FieldError
{
    RecordField field;
    FontError error;
}

/// The colour formats of a record, as bits (FTD19).
enum ColourFormat : ubyte
{
    colrLayers = 1,
    colrPaint = 2,
    cbdt = 4,
    sbix = 8,
    svg = 16,
}

/// Bits of `FaceRecord.truncatedNames`: which names were cut at `maxRecordNameBytes`.
enum NameSlot : ubyte
{
    family,
    styleName,
    fullName,
    postScriptName,
    alias_,
}

/**
What the catalog stores about one face (FTD19). Value ranges are F16.16:
weight in CSS units, width in percent, italic 0 or 1, oblique angles in
degrees clockwise. `source`, `identity`, `size` and the time are filled by
the catalog build; `describeFace` fills the rest.
*/
struct FaceRecord
{
    /// The source's position in the build's list.
    uint source;
    /// The file's identity within its source (FTD17).
    StringRef identity;
    /// The face's index in its collection.
    uint index;
    ulong fileSize;
    long modifiedNs;
    bool hasModified;

    StringRef family, styleName, fullName, postScriptName;
    /// `StringRef`s in `RecordPools.aliases`, the family first.
    PoolSpan aliases;
    /// One bit per `NameSlot` that was cut.
    ubyte truncatedNames;

    int weightMin = 400 * one, weightMax = 400 * one;
    int widthMin = 100 * one, widthMax = 100 * one;
    int italicMin, italicMax;
    int obliqueMin, obliqueMax;
    /// Whether the style ranges come from `ital` and `slnt` axes.
    bool hasItalAxis, hasSlntAxis, hasWghtAxis, hasWdthAxis;

    Spacing spacing = Spacing.proportional;
    bool spacingKnown;
    /// `CodepointRange`s in `RecordPools.ranges`, sorted and disjoint.
    PoolSpan coverage;
    /// `ColourFormat` bits.
    ubyte colourFormats;
    /// `AxisRecord`s in `RecordPools.axes`.
    PoolSpan axes;
    Corrections corrections;
    OutlineFormat outlines;
    ushort unitsPerEm, numGlyphs;
    /// Whether a substitution may see glyph 0, so coverage cannot prove `.notdef` (FTD40).
    bool glyph0Substitutable;
    /// `FieldError`s in `RecordPools.errors`.
    PoolSpan errors;

    /// Whether the face requires hinting bytecode to draw (FTD12).
    bool requiresBytecode() const pure => corrections.has(Correction.requiresBytecode);
}


/// The owned storage records refer into.
struct RecordPools
{
    @safe nothrow @nogc:

    UniqueBuffer!char strings;
    UniqueBuffer!StringRef aliases;
    UniqueBuffer!CodepointRange ranges;
    UniqueBuffer!AxisRecord axes;
    UniqueBuffer!FieldError errors;

    @disable this(this);

    /// The text of `s`.
    const(char)[] text(StringRef s) const return scope pure => strings[][s.offset .. s.offset + s.length];
    /// The aliases of `r`.
    const(StringRef)[] aliasesOf(in FaceRecord r) const return scope pure
        => aliases[][r.aliases.offset .. r.aliases.offset + r.aliases.count];
    /// The coverage of `r`.
    const(CodepointRange)[] coverageOf(in FaceRecord r) const return scope pure
        => ranges[][r.coverage.offset .. r.coverage.offset + r.coverage.count];
    /// The axes of `r`.
    const(AxisRecord)[] axesOf(in FaceRecord r) const return scope pure
        => axes[][r.axes.offset .. r.axes.offset + r.axes.count];
    /// The field errors of `r`.
    const(FieldError)[] errorsOf(in FaceRecord r) const return scope pure
        => errors[][r.errors.offset .. r.errors.offset + r.errors.count];

    /// Appends `s` and returns its reference.
    StringRef add(scope const(char)[] s) scope pure
    {
        const at = cast(uint) strings.length;
        strings.put(s);
        return StringRef(at, cast(uint) s.length);
    }

    /// Whether `r` covers `cp`. Costs O(log k).
    bool covers(in FaceRecord r, dchar cp) const scope pure
    {
        const c = coverageOf(r);
        size_t lo = 0, hi = c.length;
        while (lo < hi)
        {
            const mid = (lo + hi) / 2;
            if (c[mid].last < cp)
                lo = mid + 1;
            else
                hi = mid;
        }
        return lo < c.length && c[lo].first <= cp;
    }
}

// ---------------------------------------------------------------------------
// Describing a face (FTD19)
// ---------------------------------------------------------------------------

/**
Reads `face` into `record`, appending its strings, aliases, coverage, axes
and field errors to `pools`. A field whose table is absent keeps its
default; one whose table is malformed keeps its default and lists the error
(FTD20). Costs O(names + ranges + axes) plus one scan of `GSUB` (FTD40),
all linear in the tables read.
*/
void describeFace(scope const Face face, ref RecordPools pools, ref FaceRecord record)
{
    const errorsAt = cast(uint) pools.errors.length;
    record.index = face.index;
    record.corrections = face.corrections;
    record.outlines = face.outlines;
    record.unitsPerEm = face.unitsPerEm;
    record.numGlyphs = face.numGlyphs;

    void fail(RecordField field, FontError e)
    {
        if (e.kind != FontErrorKind.missingTable)
            pools.errors.put(FieldError(field, e));
    }

    describeNames(face, pools, record, &fail);
    describeStyle(face, pools, record, &fail);

    const map = charMap(face);
    if (map.hasValue)
    {
        const at = cast(uint) pools.ranges.length;
        foreach (r; map.value.ranges)
            pools.ranges.put(r);
        record.coverage = PoolSpan(at, cast(uint)(pools.ranges.length - at));
    }
    else
        fail(RecordField.characterMap, map.error);

    const s = spacing(face);
    if (s.hasValue)
    {
        record.spacing = s.value.spacing;
        record.spacingKnown = true;
    }
    else
        fail(RecordField.spacing, s.error);

    const colour = colourCapability(face);
    record.colourFormats = cast(ubyte)((colour.colrLayers.usable ? ColourFormat.colrLayers : 0)
        | (colour.colrPaint.usable ? ColourFormat.colrPaint : 0) | (colour.cbdt.usable ? ColourFormat.cbdt : 0)
        | (colour.sbix.usable ? ColourFormat.sbix : 0) | (colour.svg.usable ? ColourFormat.svg : 0));

    record.glyph0Substitutable = glyph0Substitutable(face);
    record.errors = PoolSpan(errorsAt, cast(uint)(pools.errors.length - errorsAt));
}

private alias Fail = void delegate(RecordField, FontError) @safe nothrow @nogc;

/// A name choice candidate's rank: lower wins (FTD19).
private int nameRank(in NameRecord r)
{
    if (r.platformID == 3 && r.languageID == 0x0409)
        return 0;
    if (r.platformID == 3 && (r.languageID & 0x3FF) == 9)
        return 1;
    if (r.platformID == 1 && r.encodingID == 0 && r.languageID == 0)
        return 2;
    return 3;
}

/// The bytes of `s` up to `maxRecordNameBytes`, cut at a scalar boundary at or before it.
private const(char)[] capped(return scope const(char)[] s, out bool cut) pure
{
    if (s.length <= maxRecordNameBytes)
        return s;
    cut = true;
    size_t end = maxRecordNameBytes;
    while (end > 0 && (s[end] & 0xC0) == 0x80)
        --end;
    return s[0 .. end];
}

/// Decodes `r` and returns its text capped, or null when it does not decode; `scratch` holds it.
private const(char)[] decodeCapped(in NameRecord r, ref UniqueBuffer!char scratch, out bool cut)
{
    const length = r.decodedLength;
    if (length.hasError)
        return null;
    scratch.clear(false);
    foreach (_; 0 .. length.value)
        scratch.put('\0');
    const text = r.decode(scratch[]);
    if (text.hasError)
        return null;
    return capped(scratch[][0 .. text.value.length], cut);
}

private void describeNames(scope const Face face, ref RecordPools pools, ref FaceRecord record, scope Fail fail)
{
    const table = name(face);
    if (table.hasError)
    {
        fail(RecordField.names, table.error);
        return;
    }
    UniqueBuffer!char scratch;

    // The best record of `id` by `nameRank`, ties to the first that decodes.
    StringRef chosen(ushort id, NameSlot slot)
    {
        foreach (rank; 0 .. 4)
            foreach (r; table.value.records)
            {
                if (r.hasError || r.value.nameID != id || nameRank(r.value) != rank)
                    continue;
                bool cut;
                const text = decodeCapped(r.value, scratch, cut);
                if (text is null)
                    continue;
                if (cut)
                    record.truncatedNames |= 1 << slot;
                return pools.add(text);
            }
        return StringRef.init;
    }

    record.family = chosen(16, NameSlot.family);
    if (record.family.length == 0)
        record.family = chosen(1, NameSlot.family);
    record.styleName = chosen(17, NameSlot.styleName);
    if (record.styleName.length == 0)
        record.styleName = chosen(2, NameSlot.styleName);
    record.fullName = chosen(4, NameSlot.fullName);
    record.postScriptName = chosen(6, NameSlot.postScriptName);

    // Aliases: the family, then every distinct value of IDs 1, 16 and 21 in table order.
    const at = cast(uint) pools.aliases.length;
    bool known(scope const(char)[] text)
    {
        foreach (a; pools.aliases[][at .. $])
            if (pools.text(a) == text)
                return true;
        return false;
    }
    if (record.family.length)
        pools.aliases.put(record.family);
    foreach (r; table.value.records)
    {
        if (pools.aliases.length - at >= maxFamilyAliases)
            break;
        if (r.hasError || (r.value.nameID != 1 && r.value.nameID != 16 && r.value.nameID != 21))
            continue;
        bool cut;
        const text = decodeCapped(r.value, scratch, cut);
        if (text is null || text.length == 0 || known(text))
            continue;
        if (cut)
            record.truncatedNames |= 1 << NameSlot.alias_;
        pools.aliases.put(pools.add(text));
    }
    record.aliases = PoolSpan(at, cast(uint)(pools.aliases.length - at));
}

/// `usWidthClass` 1–9 as percentages (FTD19).
private immutable int[9] widthPercent = [50 * one, 62 * one + one / 2, 75 * one, 87 * one + one / 2,
    100 * one, 112 * one + one / 2, 125 * one, 150 * one, 200 * one];

private int clampTo(int v, int lo, int hi) pure => v < lo ? lo : v > hi ? hi : v;

private void describeStyle(scope const Face face, ref RecordPools pools, ref FaceRecord record, scope Fail fail)
{
    // Axes first: they override the static fields.
    const axesAt = cast(uint) pools.axes.length;
    foreach (a; axes(face))
    {
        if (a.hasError)
        {
            fail(RecordField.axes, a.error);
            break;
        }
        const v = a.value;
        pools.axes.put(AxisRecord(v.axisTag, v.minValue, v.defaultValue, v.maxValue));
        if (v.axisTag == Tag("wght"))
        {
            record.hasWghtAxis = true;
            record.weightMin = clampTo(v.minValue, one, 1_000 * one);
            record.weightMax = clampTo(v.maxValue, one, 1_000 * one);
        }
        else if (v.axisTag == Tag("wdth"))
        {
            record.hasWdthAxis = true;
            record.widthMin = clampTo(v.minValue, 50 * one, 200 * one);
            record.widthMax = clampTo(v.maxValue, 50 * one, 200 * one);
        }
        else if (v.axisTag == Tag("ital"))
        {
            record.hasItalAxis = true;
            record.italicMin = clampTo(v.minValue, 0, one);
            record.italicMax = clampTo(v.maxValue, 0, one);
        }
        else if (v.axisTag == Tag("slnt"))
        {
            record.hasSlntAxis = true;
            record.obliqueMin = clampTo(-v.maxValue, -90 * one, 90 * one);
            record.obliqueMax = clampTo(-v.minValue, -90 * one, 90 * one);
        }
    }
    record.axes = PoolSpan(axesAt, cast(uint)(pools.axes.length - axesAt));

    const o = os2(face);
    if (o.hasError)
        fail(RecordField.os2, o.error);
    if (!record.hasWghtAxis && o.hasValue)
    {
        uint w = o.value.usWeightClass;
        if (w >= 1 && w <= 9)
            w *= 100;
        if (w == 0 || w > 1_000)
            w = 400;
        record.weightMin = record.weightMax = cast(int) w * one;
    }
    if (!record.hasWdthAxis && o.hasValue)
    {
        const c = o.value.usWidthClass;
        record.widthMin = record.widthMax = c >= 1 && c <= 9 ? widthPercent[c - 1] : 100 * one;
    }
    if (record.hasItalAxis || record.hasSlntAxis)
        return;
    if (o.hasValue && o.value.version_ >= 4 && (o.value.fsSelection & 0x200))
    {
        const p = post(face);
        if (p.hasError)
            fail(RecordField.post, p.error);
        const angle = p.hasValue ? -p.value.italicAngle : 0;
        record.obliqueMin = record.obliqueMax = angle != 0 ? clampTo(angle, -90 * one, 90 * one) : 14 * one;
        return;
    }
    bool italic;
    if (o.hasValue)
        italic = (o.value.fsSelection & 1) != 0;
    else
    {
        const h = head(face);
        italic = h.hasValue && (h.value.macStyle & 2) != 0;
    }
    if (italic)
        record.italicMin = record.italicMax = one;
}

// ---------------------------------------------------------------------------
// Whether a substitution can see glyph 0 (FTD40)
// ---------------------------------------------------------------------------

/**
Whether `face` has `morx`, or a `GSUB` subtable (extensions unwrapped) with
a Coverage covering glyph 0, glyph 0 among ligature components or in a
contextual rule's glyph sequence, or class 0 in a class-based rule's input
after its first position. A table it cannot read counts as yes: pruning must
be proven. Costs O(size of `GSUB`).
*/
bool glyph0Substitutable(scope const Face face) pure
{
    if (face.has(Tag("morx")))
        return true;
    const t = face.table(Tag("GSUB"));
    if (t.hasError)
        return t.error.kind != FontErrorKind.missingTable;
    const d = t.value;
    if (d.length < 10)
        return true;
    const listAt = be16(d, 8);
    if (listAt == 0)
        return false;
    if (!fits(d.length, listAt, 2))
        return true;
    const lookups = be16(d, listAt);
    if (!fits(d.length, listAt + 2, 2UL * lookups))
        return true;
    foreach (i; 0 .. lookups)
    {
        const lookupAt = listAt + be16(d, listAt + 2 + 2 * i);
        if (!fits(d.length, lookupAt, 6))
            return true;
        const type = be16(d, lookupAt);
        const count = be16(d, lookupAt + 4);
        if (!fits(d.length, lookupAt + 6, 2UL * count))
            return true;
        foreach (k; 0 .. count)
            if (subtableSeesGlyph0(d, type, lookupAt + be16(d, lookupAt + 6 + 2 * k)))
                return true;
    }
    return false;
}

/// Whether the subtable of lookup `type` at `at` can see glyph 0; malformed counts as yes.
private bool subtableSeesGlyph0(scope const(ubyte)[] d, uint type, size_t at) pure
{
    if (!fits(d.length, at, 4))
        return true;
    if (type == 7)
    {
        if (!fits(d.length, at, 8))
            return true;
        const inner = be16(d, at + 2);
        const target = at + be32(d, at + 4);
        return inner == 7 || target > d.length || subtableSeesGlyph0(d, inner, cast(size_t) target);
    }
    const format = be16(d, at);
    bool coverageAt(size_t field) => coversGlyph0(d, at + be16(d, field));
    bool zeroIn(size_t from, size_t count)
    {
        if (!fits(d.length, from, 2 * count))
            return true;
        foreach (j; 0 .. count)
            if (be16(d, from + 2 * j) == 0)
                return true;
        return false;
    }
    // Each set's rules, by `rule(ruleAt)`; malformed counts as yes.
    bool rules(size_t setsField, size_t countField, scope bool delegate(size_t) pure @safe nothrow @nogc rule)
    {
        if (!fits(d.length, countField, 2))
            return true;
        const sets = be16(d, countField);
        if (!fits(d.length, setsField, 2UL * sets))
            return true;
        foreach (s; 0 .. sets)
        {
            const off = be16(d, setsField + 2 * s);
            if (off == 0)
                continue;
            const setAt = at + off;
            if (!fits(d.length, setAt, 2))
                return true;
            const n = be16(d, setAt);
            if (!fits(d.length, setAt + 2, 2UL * n))
                return true;
            foreach (r; 0 .. n)
                if (rule(setAt + be16(d, setAt + 2 + 2 * r)))
                    return true;
        }
        return false;
    }
    switch (type)
    {
        case 1, 2, 3:
            return coverageAt(at + 2);
        case 4:
            if (coverageAt(at + 2))
                return true;
            return rules(at + 6, at + 4, (ligAt) {
                if (!fits(d.length, ligAt, 4))
                    return true;
                const components = be16(d, ligAt + 2);
                return components > 1 && zeroIn(ligAt + 4, components - 1);
            });
        case 5:
            if (format == 1 || format == 2)
            {
                if (coverageAt(at + 2))
                    return true;
                const setsField = format == 1 ? at + 6 : at + 8;
                const countField = format == 1 ? at + 4 : at + 6;
                return rules(setsField, countField, (ruleAt) {
                    if (!fits(d.length, ruleAt, 4))
                        return true;
                    const glyphs = be16(d, ruleAt);
                    return glyphs > 1 && zeroIn(ruleAt + 4, glyphs - 1);
                });
            }
            if (format == 3)
            {
                const glyphs = be16(d, at + 2);
                if (!fits(d.length, at + 6, 2UL * glyphs))
                    return true;
                foreach (j; 0 .. glyphs)
                    if (coverageAt(at + 6 + 2 * j))
                        return true;
                return false;
            }
            return true;
        case 6:
            if (format == 1 || format == 2)
            {
                if (coverageAt(at + 2))
                    return true;
                const setsField = format == 1 ? at + 6 : at + 12;
                const countField = format == 1 ? at + 4 : at + 10;
                const glyphIds = format == 1;
                return rules(setsField, countField, (ruleAt) {
                    // backtrack, input (after the first), lookahead.
                    if (!fits(d.length, ruleAt, 2))
                        return true;
                    const back = be16(d, ruleAt);
                    const inputAt = ruleAt + 2 + 2 * back;
                    if (!fits(d.length, inputAt, 2))
                        return true;
                    const input = be16(d, inputAt);
                    const aheadAt = inputAt + 2 + 2 * (input > 0 ? input - 1 : 0);
                    if (!fits(d.length, aheadAt, 2))
                        return true;
                    const ahead = be16(d, aheadAt);
                    if (input > 1 && zeroIn(inputAt + 2, input - 1))
                        return true;
                    return glyphIds && (zeroIn(ruleAt + 2, back) || zeroIn(aheadAt + 2, ahead));
                });
            }
            if (format == 3)
            {
                size_t cursor = at + 2;
                foreach (part; 0 .. 3)
                {
                    if (!fits(d.length, cursor, 2))
                        return true;
                    const n = be16(d, cursor);
                    if (!fits(d.length, cursor + 2, 2UL * n))
                        return true;
                    foreach (j; 0 .. n)
                        if (coverageAt(cursor + 2 + 2 * j))
                            return true;
                    cursor += 2 + 2 * n;
                }
                return false;
            }
            return true;
        case 8:
        {
            if (coverageAt(at + 2))
                return true;
            size_t cursor = at + 4;
            foreach (part; 0 .. 2)
            {
                if (!fits(d.length, cursor, 2))
                    return true;
                const n = be16(d, cursor);
                if (!fits(d.length, cursor + 2, 2UL * n))
                    return true;
                foreach (j; 0 .. n)
                    if (coverageAt(cursor + 2 + 2 * j))
                        return true;
                cursor += 2 + 2 * n;
            }
            return false;
        }
        default:
            return true;
    }
}

/// Whether the Coverage at `at` covers glyph 0; unreadable counts as yes.
private bool coversGlyph0(scope const(ubyte)[] d, size_t at) pure
{
    const c = Coverage.read(d, Tag("GSUB"), 0, at);
    const i = c.index(0);
    return i.hasError || i.value.covered;
}
