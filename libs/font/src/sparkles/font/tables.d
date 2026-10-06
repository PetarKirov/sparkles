/**
Typed views of the fixed-layout tables (FTP23, FTP24, FTP32).

Each view is a plain struct whose fields carry their OpenType names, so a
reflection walk lists them (FTI1). A field the stored version lacks holds
OpenType's default, and a `has…` flag says so (FTP33). Views of tables with
arrays (`hmtx`, `fvar`, `avar`, `STAT`) borrow the face's bytes.
*/
module sparkles.font.tables;

import sparkles.font.bytes : be16, be32, bes16, bes32, fits, slice;
import sparkles.font.errors : FontError, FontErrorKind, FontResult, fontErr, fontOk, Tag, tableError;
import sparkles.font.face : Face;

@safe pure nothrow @nogc:

/// The bytes of `tag` and its absolute start, or the lookup error.
private struct Located
{
    const(ubyte)[] data;
    ulong start;
}

private FontResult!Located locate(return scope const Face face, Tag tag)
{
    auto t = face.table(tag);
    if (t.hasError)
        return fontErr!Located(t.error);
    return fontOk(Located(t.value, face.record(face.find(tag)).offset));
}

private FontResult!T shortTable(T)(Tag tag, in Located at, ulong needed)
    => fontErr!T(tableError(FontErrorKind.truncated, tag, at.start, at.data.length < needed
        ? at.data.length : needed));

// ---------------------------------------------------------------------------
// head, hhea, maxp
// ---------------------------------------------------------------------------

/// `head`, checked at open.
struct Head
{
    ushort majorVersion, minorVersion;
    int fontRevision; /// 16.16 fixed
    uint checksumAdjustment, magicNumber;
    ushort flags, unitsPerEm;
    long created, modified;
    short xMin, yMin, xMax, yMax;
    ushort macStyle, lowestRecPPEM;
    short fontDirectionHint, indexToLocFormat, glyphDataFormat;
}

/// The face's `head` table.
FontResult!Head head(scope const Face face)
{
    const at = locate(face, Tag("head"));
    if (at.hasError)
        return fontErr!Head(at.error);
    const d = at.value.data;
    // Open checked its length (54) and major version.
    return fontOk(Head(be16(d, 0), be16(d, 2), bes32(d, 4), be32(d, 8), be32(d, 12), be16(d, 16),
        be16(d, 18), (long(bes32(d, 20)) << 32) | be32(d, 24), (long(bes32(d, 28)) << 32) | be32(d, 32),
        bes16(d, 36), bes16(d, 38), bes16(d, 40), bes16(d, 42), be16(d, 44), be16(d, 46),
        bes16(d, 48), bes16(d, 50), bes16(d, 52)));
}

/// `hhea`, at least 36 bytes.
struct Hhea
{
    ushort majorVersion, minorVersion;
    short ascender, descender, lineGap;
    ushort advanceWidthMax;
    short minLeftSideBearing, minRightSideBearing, xMaxExtent;
    short caretSlopeRise, caretSlopeRun, caretOffset;
    short metricDataFormat;
    ushort numberOfHMetrics;
}

/// The face's `hhea` table.
FontResult!Hhea hhea(scope const Face face)
{
    const at = locate(face, Tag("hhea"));
    if (at.hasError)
        return fontErr!Hhea(at.error);
    const d = at.value.data;
    if (d.length < 36)
        return shortTable!Hhea(Tag("hhea"), at.value, 36);
    return fontOk(Hhea(be16(d, 0), be16(d, 2), bes16(d, 4), bes16(d, 6), bes16(d, 8), be16(d, 10),
        bes16(d, 12), bes16(d, 14), bes16(d, 16), bes16(d, 18), bes16(d, 20), bes16(d, 22),
        bes16(d, 32), be16(d, 34)));
}

/// `maxp`, version 0.5 or 1.0; checked at open.
struct Maxp
{
    uint version_; /// 16.16: 0x00005000 or 0x00010000
    ushort numGlyphs;
    /// Whether the version-1.0 fields below are present.
    bool hasVersion1Fields;
    ushort maxPoints, maxContours, maxCompositePoints, maxCompositeContours, maxZones,
        maxTwilightPoints, maxStorage, maxFunctionDefs, maxInstructionDefs, maxStackElements,
        maxSizeOfInstructions, maxComponentElements, maxComponentDepth;
}

/// The face's `maxp` table.
FontResult!Maxp maxp(scope const Face face)
{
    const at = locate(face, Tag("maxp"));
    if (at.hasError)
        return fontErr!Maxp(at.error);
    const d = at.value.data;
    Maxp m;
    m.version_ = be32(d, 0);
    m.numGlyphs = be16(d, 4);
    if (m.version_ == 0x0001_0000)
    {
        m.hasVersion1Fields = true;
        ushort[13] f;
        foreach (i, ref v; f) v = be16(d, 6 + 2 * i);
        m.maxPoints = f[0]; m.maxContours = f[1]; m.maxCompositePoints = f[2];
        m.maxCompositeContours = f[3]; m.maxZones = f[4]; m.maxTwilightPoints = f[5];
        m.maxStorage = f[6]; m.maxFunctionDefs = f[7]; m.maxInstructionDefs = f[8];
        m.maxStackElements = f[9]; m.maxSizeOfInstructions = f[10];
        m.maxComponentElements = f[11]; m.maxComponentDepth = f[12];
    }
    return fontOk(m);
}

// ---------------------------------------------------------------------------
// OS/2 and post
// ---------------------------------------------------------------------------

/// `OS/2`, versions 0–5; a later version is read as version 5.
struct Os2
{
    ushort version_;
    short xAvgCharWidth;
    ushort usWeightClass, usWidthClass, fsType;
    short ySubscriptXSize, ySubscriptYSize, ySubscriptXOffset, ySubscriptYOffset;
    short ySuperscriptXSize, ySuperscriptYSize, ySuperscriptXOffset, ySuperscriptYOffset;
    short yStrikeoutSize, yStrikeoutPosition, sFamilyClass;
    ubyte[10] panose;
    uint ulUnicodeRange1, ulUnicodeRange2, ulUnicodeRange3, ulUnicodeRange4;
    Tag achVendID;
    ushort fsSelection, usFirstCharIndex, usLastCharIndex;
    short sTypoAscender, sTypoDescender, sTypoLineGap;
    ushort usWinAscent, usWinDescent;
    /// Version 1 and later.
    bool hasCodePageRanges;
    uint ulCodePageRange1, ulCodePageRange2;
    /// Version 2 and later.
    bool hasXHeight;
    short sxHeight, sCapHeight;
    ushort usDefaultChar, usBreakChar, usMaxContext;
    /// Version 5 and later.
    bool hasOpticalSizes;
    ushort usLowerOpticalPointSize, usUpperOpticalPointSize;
}

/// The bytes each `OS/2` version needs.
private ulong os2Length(uint version_) => version_ >= 5 ? 100 : version_ >= 2 ? 96 : version_ == 1 ? 86 : 78;

/// The face's `OS/2` table.
FontResult!Os2 os2(scope const Face face)
{
    const at = locate(face, Tag("OS/2"));
    if (at.hasError)
        return fontErr!Os2(at.error);
    const d = at.value.data;
    if (d.length < 78)
        return shortTable!Os2(Tag("OS/2"), at.value, 78);
    Os2 o;
    o.version_ = be16(d, 0);
    if (d.length < os2Length(o.version_))
        return shortTable!Os2(Tag("OS/2"), at.value, os2Length(o.version_));
    o.xAvgCharWidth = bes16(d, 2);
    o.usWeightClass = be16(d, 4);
    o.usWidthClass = be16(d, 6);
    o.fsType = be16(d, 8);
    short[11] s;
    foreach (i, ref v; s) v = bes16(d, 10 + 2 * i);
    o.ySubscriptXSize = s[0]; o.ySubscriptYSize = s[1]; o.ySubscriptXOffset = s[2];
    o.ySubscriptYOffset = s[3]; o.ySuperscriptXSize = s[4]; o.ySuperscriptYSize = s[5];
    o.ySuperscriptXOffset = s[6]; o.ySuperscriptYOffset = s[7]; o.yStrikeoutSize = s[8];
    o.yStrikeoutPosition = s[9]; o.sFamilyClass = s[10];
    o.panose[] = d[32 .. 42];
    o.ulUnicodeRange1 = be32(d, 42);
    o.ulUnicodeRange2 = be32(d, 46);
    o.ulUnicodeRange3 = be32(d, 50);
    o.ulUnicodeRange4 = be32(d, 54);
    o.achVendID = Tag(be32(d, 58));
    o.fsSelection = be16(d, 62);
    o.usFirstCharIndex = be16(d, 64);
    o.usLastCharIndex = be16(d, 66);
    o.sTypoAscender = bes16(d, 68);
    o.sTypoDescender = bes16(d, 70);
    o.sTypoLineGap = bes16(d, 72);
    o.usWinAscent = be16(d, 74);
    o.usWinDescent = be16(d, 76);
    if (o.version_ >= 1)
    {
        o.hasCodePageRanges = true;
        o.ulCodePageRange1 = be32(d, 78);
        o.ulCodePageRange2 = be32(d, 82);
    }
    if (o.version_ >= 2)
    {
        o.hasXHeight = true;
        o.sxHeight = bes16(d, 86);
        o.sCapHeight = bes16(d, 88);
        o.usDefaultChar = be16(d, 90);
        o.usBreakChar = be16(d, 92);
        o.usMaxContext = be16(d, 94);
    }
    if (o.version_ >= 5)
    {
        o.hasOpticalSizes = true;
        o.usLowerOpticalPointSize = be16(d, 96);
        o.usUpperOpticalPointSize = be16(d, 98);
    }
    return fontOk(o);
}

/// The fixed `post` header, at least 32 bytes.
struct Post
{
    uint version_; /// 16.16: 0x00010000, 0x00020000, 0x00025000, 0x00030000, …
    int italicAngle; /// 16.16 fixed
    short underlinePosition, underlineThickness;
    uint isFixedPitch;
    uint minMemType42, maxMemType42, minMemType1, maxMemType1;
}

/// The face's `post` header.
FontResult!Post post(scope const Face face)
{
    const at = locate(face, Tag("post"));
    if (at.hasError)
        return fontErr!Post(at.error);
    const d = at.value.data;
    if (d.length < 32)
        return shortTable!Post(Tag("post"), at.value, 32);
    return fontOk(Post(be32(d, 0), bes32(d, 4), bes16(d, 8), bes16(d, 10), be32(d, 12), be32(d, 16),
        be32(d, 20), be32(d, 24), be32(d, 28)));
}

// ---------------------------------------------------------------------------
// hmtx (FTP24) and spacing (FTP32)
// ---------------------------------------------------------------------------

/// A glyph's horizontal metrics in font units.
struct HorizontalMetric
{
    ushort advanceWidth;
    short lsb;
}

/// The `hmtx` view: lenient where real fonts are short (FTP24).
struct Hmtx
{
    @safe pure nothrow @nogc:

    private const(ubyte)[] data_;
    private ulong start_;
    private ushort numberOfHMetrics_;
    private ushort numGlyphs_;

    /// `numberOfHMetrics`, read as at most `numGlyphs`.
    ushort numberOfHMetrics() const scope => numberOfHMetrics_;

    /// The metrics of glyph `gid` (FTP24).
    FontResult!HorizontalMetric metric(uint gid) const scope
    {
        if (gid >= numGlyphs_)
            return fontErr!HorizontalMetric(FontError(FontErrorKind.indexOutOfRange, Tag("hmtx")));
        const last = numberOfHMetrics_ - 1u;
        // The advance repeats the last long metric past numberOfHMetrics.
        const advanceAt = 4UL * (gid < numberOfHMetrics_ ? gid : last);
        const lsbAt = gid < numberOfHMetrics_ ? 4UL * gid + 2
            : 4UL * numberOfHMetrics_ + 2UL * (gid - numberOfHMetrics_);
        if (!fits(data_.length, advanceAt, 2))
            return fontErr!HorizontalMetric(tableError(FontErrorKind.truncated, Tag("hmtx"),
                start_, advanceAt));
        if (!fits(data_.length, lsbAt, 2))
            return fontErr!HorizontalMetric(tableError(FontErrorKind.truncated, Tag("hmtx"),
                start_, lsbAt));
        return fontOk(HorizontalMetric(be16(data_, cast(size_t) advanceAt),
            bes16(data_, cast(size_t) lsbAt)));
    }

    /// The advance of glyph `gid`.
    FontResult!ushort advance(uint gid) const scope
    {
        const m = metric(gid);
        return m.hasError ? fontErr!ushort(m.error) : fontOk!ushort(m.value.advanceWidth);
    }

    /// The left side bearing of glyph `gid`.
    FontResult!short lsb(uint gid) const scope
    {
        const m = metric(gid);
        return m.hasError ? fontErr!short(m.error) : fontOk!short(m.value.lsb);
    }
}

/// The face's `hmtx` view; needs a readable `hhea` and `numberOfHMetrics ≥ 1`.
FontResult!Hmtx hmtx(return scope const Face face)
{
    const h = hhea(face);
    if (h.hasError)
        return fontErr!Hmtx(h.error);
    if (h.value.numberOfHMetrics == 0 && face.numGlyphs > 0)
        return fontErr!Hmtx(tableError(FontErrorKind.badValue, Tag("hhea"),
            face.record(face.find(Tag("hhea"))).offset, 34));
    auto at = locate(face, Tag("hmtx"));
    if (at.hasError)
        return fontErr!Hmtx(at.error);
    const n = h.value.numberOfHMetrics < face.numGlyphs ? h.value.numberOfHMetrics : face.numGlyphs;
    return fontOk(Hmtx(at.value.data, at.value.start, n, face.numGlyphs));
}

/// How a face spaces its glyphs, measured from `hmtx` (FTP12).
enum Spacing : ubyte
{
    mono,
    dual,
    proportional,
}

/// A spacing classification and what it was measured from (FTP32).
struct SpacingReport
{
    Spacing spacing;
    /// The distinct nonzero advances, when there are at most two.
    ushort[2] advances;
    ubyte advanceCount;
    /// Glyphs whose `hmtx` entry is truncated, left out of the classification.
    uint truncatedGlyphs;
}

/// Classifies the face's spacing by walking `hmtx` once (FTP32).
FontResult!SpacingReport spacing(scope const Face face)
{
    const m = hmtx(face);
    if (m.hasError)
        return fontErr!SpacingReport(m.error);
    SpacingReport r;
    bool proportional;
    foreach (gid; 0 .. face.numGlyphs)
    {
        const a = m.value.advance(gid);
        if (a.hasError) { ++r.truncatedGlyphs; continue; }
        const v = a.value;
        if (v == 0 || proportional)
            continue;
        if (r.advanceCount > 0 && r.advances[0] == v) continue;
        if (r.advanceCount > 1 && r.advances[1] == v) continue;
        if (r.advanceCount == 2) { proportional = true; continue; }
        r.advances[r.advanceCount++] = v;
    }
    if (proportional)
    {
        r.advanceCount = 0;
        r.advances = 0;
        r.spacing = Spacing.proportional;
    }
    else if (r.advanceCount <= 1)
        r.spacing = Spacing.mono;
    else
    {
        const lo = r.advances[0] < r.advances[1] ? r.advances[0] : r.advances[1];
        const hi = r.advances[0] < r.advances[1] ? r.advances[1] : r.advances[0];
        r.spacing = hi == 2 * lo ? Spacing.dual : Spacing.proportional;
    }
    return fontOk(r);
}

// ---------------------------------------------------------------------------
// fvar, avar, STAT
// ---------------------------------------------------------------------------

/// One `fvar` variation axis; values are 16.16 fixed.
struct VariationAxis
{
    Tag axisTag;
    int minValue, defaultValue, maxValue;
    ushort flags, axisNameID;
}

/// One `fvar` named instance; coordinates borrow the table.
struct NamedInstance
{
    @safe pure nothrow @nogc:

    ushort subfamilyNameID, flags;
    /// Present when `instanceSize ≥ 4·axisCount + 6`.
    bool hasPostScriptNameID;
    ushort postScriptNameID;
    private const(ubyte)[] coordinates_;

    /// The 16.16 coordinate on axis `i`, `i < axisCount`.
    int coordinate(size_t i) const scope
    in (4 * i + 4 <= coordinates_.length)
        => bes32(coordinates_, 4 * i);
}

/// The `fvar` view (FTP23).
struct Fvar
{
    @safe pure nothrow @nogc:

    ushort majorVersion, minorVersion, axisCount, instanceCount, instanceSize;
    private const(ubyte)[] data_;
    private ulong start_;
    private ushort axesOffset_;

    /// Axis `i`: a `badValue` entry when its minimum, default and maximum are out of order.
    FontResult!VariationAxis axis(size_t i) const scope
    in (i < axisCount)
    {
        const at = axesOffset_ + 20 * i;
        const a = VariationAxis(Tag(be32(data_, at)), bes32(data_, at + 4), bes32(data_, at + 8),
            bes32(data_, at + 12), be16(data_, at + 16), be16(data_, at + 18));
        if (a.minValue > a.defaultValue || a.defaultValue > a.maxValue)
            return fontErr!VariationAxis(tableError(FontErrorKind.badValue, Tag("fvar"), start_, at + 4));
        return fontOk!VariationAxis(a);
    }

    /// Named instance `i`, `i < instanceCount`.
    NamedInstance instance(size_t i) const return scope
    in (i < instanceCount)
    {
        const at = axesOffset_ + 20UL * axisCount + ulong(instanceSize) * i;
        const coords = slice(data_, at + 4, 4UL * axisCount);
        const withPs = instanceSize >= 4 * axisCount + 6;
        return NamedInstance(be16(data_, cast(size_t) at), be16(data_, cast(size_t) at + 2), withPs,
            withPs ? be16(data_, cast(size_t)(at + 4 + 4 * axisCount)) : 0xFFFF, coords);
    }
}

/// The face's `fvar` view.
FontResult!Fvar fvar(return scope const Face face)
{
    auto at = locate(face, Tag("fvar"));
    if (at.hasError)
        return fontErr!Fvar(at.error);
    const d = at.value.data;
    if (d.length < 16)
        return shortTable!Fvar(Tag("fvar"), at.value, 16);
    Fvar f;
    f.majorVersion = be16(d, 0);
    f.minorVersion = be16(d, 2);
    if (f.majorVersion != 1)
        return fontErr!Fvar(tableError(FontErrorKind.unsupportedVersion, Tag("fvar"), at.value.start, 0));
    f.axesOffset_ = be16(d, 4);
    f.axisCount = be16(d, 8);
    const axisSize = be16(d, 10);
    f.instanceCount = be16(d, 12);
    f.instanceSize = be16(d, 14);
    if (axisSize != 20)
        return fontErr!Fvar(tableError(FontErrorKind.badValue, Tag("fvar"), at.value.start, 10));
    if (f.instanceSize < 4UL * f.axisCount + 4)
        return fontErr!Fvar(tableError(FontErrorKind.badValue, Tag("fvar"), at.value.start, 14));
    const arrays = 20UL * f.axisCount + ulong(f.instanceSize) * f.instanceCount;
    if (!fits(d.length, f.axesOffset_, arrays))
        return shortTable!Fvar(Tag("fvar"), at.value, f.axesOffset_ + arrays);
    f.data_ = d;
    f.start_ = at.value.start;
    return fontOk(f);
}

/// One `avar` segment map: pairs of F2Dot14 `(fromCoordinate, toCoordinate)`.
struct SegmentMap
{
    @safe pure nothrow @nogc:

    private const(ubyte)[] pairs_;

    /// The number of axis value maps.
    size_t length() const scope => pairs_.length / 4;
    /// Map `i` as `[from, to]` in F2Dot14.
    short[2] map(size_t i) const scope
    in (i < length)
        => [bes16(pairs_, 4 * i), bes16(pairs_, 4 * i + 2)];
}

/// The `avar` view: version 1.0, its own axis count (FTP23).
struct Avar
{
    @safe pure nothrow @nogc:

    ushort majorVersion, minorVersion, axisCount;
    private const(ubyte)[] data_;
    private ulong start_;

    /// The segment maps in axis order, as a forward range of results.
    AvarMaps maps() const return scope => AvarMaps(data_, start_, 8, axisCount);
}

/// The segment maps of `avar`; a map past the table ends the range with `truncated`.
struct AvarMaps
{
    @safe pure nothrow @nogc:

    private const(ubyte)[] data_;
    private ulong start_;
    private ulong at_;
    private uint remaining_;

    bool empty() const scope => remaining_ == 0;

    /// The current map, `badValue` when `fromCoordinate` decreases.
    FontResult!SegmentMap front() const return scope
    {
        if (!fits(data_.length, at_, 2))
            return fontErr!SegmentMap(tableError(FontErrorKind.truncated, Tag("avar"), start_, at_));
        const count = be16(data_, cast(size_t) at_);
        if (!fits(data_.length, at_ + 2, 4UL * count))
            return fontErr!SegmentMap(tableError(FontErrorKind.truncated, Tag("avar"), start_, at_ + 2));
        const map = SegmentMap(slice(data_, at_ + 2, 4UL * count));
        foreach (i; 1 .. map.length)
            if (map.map(i)[0] < map.map(i - 1)[0])
                return fontErr!SegmentMap(tableError(FontErrorKind.badValue, Tag("avar"), start_,
                    at_ + 2 + 4 * i));
        return fontOk!SegmentMap(map);
    }

    void popFront()
    {
        if (!fits(data_.length, at_, 2)
            || !fits(data_.length, at_ + 2, 4UL * be16(data_, cast(size_t) at_)))
        {
            remaining_ = 0;
            return;
        }
        at_ += 2 + 4UL * be16(data_, cast(size_t) at_);
        --remaining_;
    }
}

/// The face's `avar` view.
FontResult!Avar avar(return scope const Face face)
{
    auto at = locate(face, Tag("avar"));
    if (at.hasError)
        return fontErr!Avar(at.error);
    const d = at.value.data;
    if (d.length < 8)
        return shortTable!Avar(Tag("avar"), at.value, 8);
    const major = be16(d, 0);
    if (major != 1)
        return fontErr!Avar(tableError(FontErrorKind.unsupportedVersion, Tag("avar"), at.value.start, 0));
    return fontOk(Avar(major, be16(d, 2), be16(d, 6), d, at.value.start));
}

/// One `STAT` design axis.
struct DesignAxis
{
    Tag axisTag;
    ushort axisNameID, axisOrdering;
}

/// One `STAT` axis value table, formats 1–4; values are 16.16 fixed.
struct AxisValue
{
    @safe pure nothrow @nogc:

    ushort format, axisIndex, flags, valueNameID;
    int value, nominalValue, rangeMinValue, rangeMaxValue, linkedValue;
    /// Format 4: the number of `(axisIndex, value)` records.
    ushort axisCount;
    private const(ubyte)[] records_;

    /// Format 4 record `i` as `(axisIndex, value)`.
    void record(size_t i, out ushort index, out int recordValue) const scope
    in (i < axisCount)
    {
        index = be16(records_, 6 * i);
        recordValue = bes32(records_, 6 * i + 2);
    }
}

/// The `STAT` view (FTP23).
struct Stat
{
    @safe pure nothrow @nogc:

    ushort majorVersion, minorVersion, designAxisSize, designAxisCount, axisValueCount;
    /// Present from version 1.1.
    bool hasElidedFallbackNameID;
    ushort elidedFallbackNameID;
    private const(ubyte)[] data_;
    private ulong start_;
    private uint designAxesOffset_, axisValuesOffset_;

    /// Design axis `i`, `i < designAxisCount`.
    DesignAxis designAxis(size_t i) const scope
    in (i < designAxisCount)
    {
        const at = designAxesOffset_ + designAxisSize * i;
        return DesignAxis(Tag(be32(data_, at)), be16(data_, at + 4), be16(data_, at + 6));
    }

    /// Axis value `i`; another format, or one outside the table, is an error entry.
    FontResult!AxisValue axisValue(size_t i) const return scope
    in (i < axisValueCount)
    {
        const offsetAt = axisValuesOffset_ + 2 * i;
        const at = ulong(axisValuesOffset_) + be16(data_, offsetAt);
        if (!fits(data_.length, at, 2))
            return fontErr!AxisValue(tableError(FontErrorKind.badOffset, Tag("STAT"), start_, offsetAt));
        AxisValue v;
        v.format = be16(data_, cast(size_t) at);
        const needed = v.format == 1 ? 12 : v.format == 2 ? 20 : v.format == 3 ? 16 : v.format == 4 ? 8 : 0;
        if (needed == 0)
            return fontErr!AxisValue(tableError(FontErrorKind.unsupportedVersion, Tag("STAT"), start_, at));
        if (!fits(data_.length, at, needed))
            return fontErr!AxisValue(tableError(FontErrorKind.truncated, Tag("STAT"), start_, at));
        const p = cast(size_t) at;
        if (v.format == 4)
        {
            v.axisCount = be16(data_, p + 2);
            v.flags = be16(data_, p + 4);
            v.valueNameID = be16(data_, p + 6);
            if (!fits(data_.length, at + 8, 6UL * v.axisCount))
                return fontErr!AxisValue(tableError(FontErrorKind.truncated, Tag("STAT"), start_, at + 8));
            v.records_ = slice(data_, at + 8, 6UL * v.axisCount);
            return fontOk(v);
        }
        v.axisIndex = be16(data_, p + 2);
        v.flags = be16(data_, p + 4);
        v.valueNameID = be16(data_, p + 6);
        if (v.format == 1)
            v.value = bes32(data_, p + 8);
        else if (v.format == 2)
        {
            v.nominalValue = bes32(data_, p + 8);
            v.rangeMinValue = bes32(data_, p + 12);
            v.rangeMaxValue = bes32(data_, p + 16);
        }
        else
        {
            v.value = bes32(data_, p + 8);
            v.linkedValue = bes32(data_, p + 12);
        }
        return fontOk(v);
    }
}

/// The face's `STAT` view.
FontResult!Stat stat(return scope const Face face)
{
    auto at = locate(face, Tag("STAT"));
    if (at.hasError)
        return fontErr!Stat(at.error);
    const d = at.value.data;
    if (d.length < 18)
        return shortTable!Stat(Tag("STAT"), at.value, 18);
    Stat s;
    s.majorVersion = be16(d, 0);
    s.minorVersion = be16(d, 2);
    if (s.majorVersion != 1 || s.minorVersion > 2)
        return fontErr!Stat(tableError(FontErrorKind.unsupportedVersion, Tag("STAT"), at.value.start, 0));
    s.designAxisSize = be16(d, 4);
    s.designAxisCount = be16(d, 6);
    s.designAxesOffset_ = be32(d, 8);
    s.axisValueCount = be16(d, 12);
    s.axisValuesOffset_ = be32(d, 14);
    if (s.minorVersion >= 1)
    {
        if (d.length < 20)
            return shortTable!Stat(Tag("STAT"), at.value, 20);
        s.hasElidedFallbackNameID = true;
        s.elidedFallbackNameID = be16(d, 18);
    }
    if (s.designAxisCount && (s.designAxisSize < 8
            || !fits(d.length, s.designAxesOffset_, ulong(s.designAxisSize) * s.designAxisCount)))
        return fontErr!Stat(tableError(FontErrorKind.truncated, Tag("STAT"), at.value.start, 8));
    if (s.axisValueCount && !fits(d.length, s.axisValuesOffset_, 2UL * s.axisValueCount))
        return fontErr!Stat(tableError(FontErrorKind.truncated, Tag("STAT"), at.value.start, 14));
    s.data_ = d;
    s.start_ = at.value.start;
    return fontOk(s);
}
