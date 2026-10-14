/**
Metrics at an instance (`docs/specs/font/variation-metrics.md` § 4, FTV14,
FTM8–FTM19).

Every measurement is a `Measurement`: a `DesignValue` (FTM8) together with
the instance's size, from which `physical` gives base's `LayoutUnit` (FTM9)
and `pixels` a fractional pixel value (FTM10). `verticalSets`, `lineMetrics`
and `decorations` read `hhea`, `OS/2` and `post` and add the `MVAR` delta of
each value; `advance` and `measureRun` read `hmtx` and add the `HVAR` delta;
`cellMetrics` rounds to whole pixels by FTM19's table.

`HVAR` and `MVAR` views (`hvar`, `mvar`) are built per query from the face,
an O(1) header read; nothing is cached. At an instance whose coordinates are
all zero, neither table is read (FTM14). Nothing here allocates.
*/
module sparkles.font.metrics;

import std.math.rounding : ceil, floor;

import sparkles.base.text.layout_units : LayoutUnit, Rational;

import sparkles.font.bytes : be16, be32, fits;
import sparkles.font.cmap : CharMap;
import sparkles.font.errors : FontError, FontErrorKind, FontResult, fontErr, fontOk, Tag, tableError;
import sparkles.font.face : Face;
import sparkles.font.instance : Instance, InstanceSize;
import sparkles.font.tables : hhea, Hhea, hmtx, Hmtx, os2, Os2, post;
import sparkles.font.units : checkedAdd, DesignValue, Ppem, toLayoutUnit, toPixels;
import sparkles.font.variations : DeltaSetIndex, DeltaSetIndexMap, ItemVariationStore, NormalizedCoords;

@safe pure nothrow @nogc:

// ---------------------------------------------------------------------------
// Measurements (FTM8–FTM10)
// ---------------------------------------------------------------------------

/**
One value at an instance, in all three forms (FTM8–FTM10): the exact
`design` value, and the instance's `size`, which `physical` and `pixels`
convert it at. Each conversion rounds once.
*/
struct Measurement
{
    @safe pure nothrow @nogc:

    /// The value in 1/65,536 font units, deltas included.
    DesignValue design;
    /// The size of the instance the value was measured at.
    InstanceSize size;

    /**
    The value in `LayoutUnit` at the instance's physical em (FTM9):
    `unsupportedCapability` for an instance sized in pixels,
    `arithmeticExhausted` past `LayoutUnit`'s range. Costs O(1).
    */
    FontResult!LayoutUnit physical() const scope
    {
        if (size.unit != InstanceSize.Unit.physical)
            return fontErr!LayoutUnit(FontError(FontErrorKind.unsupportedCapability));
        return toLayoutUnit(design, size.em);
    }

    /**
    The value in fractional pixels at the ppem of an instance sized in pixels
    (FTM10). A physically sized instance needs a device scale and returns
    `unsupportedCapability`; pass `dotsPerInch` instead. Costs O(1).
    */
    FontResult!double pixels() const scope
    {
        if (size.unit != InstanceSize.Unit.pixels)
            return fontErr!double(FontError(FontErrorKind.unsupportedCapability));
        return fontOk(toPixels(design, size.ppem));
    }

    /**
    The value in fractional pixels for a physically sized instance on a
    device of `dotsPerInch`, at `ppem = em · dpi / 72` (FTM10). An instance
    sized in pixels has no physical em and returns `unsupportedCapability`; a
    scale that is not positive is `badValue`. The physical value does not
    depend on the scale. Costs O(1).
    */
    FontResult!double pixels(Rational dotsPerInch) const scope
    {
        if (size.unit != InstanceSize.Unit.physical)
            return fontErr!double(FontError(FontErrorKind.unsupportedCapability));
        const ppem = Ppem.fromPhysical(size.em, dotsPerInch);
        if (ppem.hasError)
            return fontErr!double(ppem.error);
        return fontOk(toPixels(design, ppem.value));
    }

    /// ditto
    FontResult!double pixels(long dotsPerInch) const scope
    {
        if (size.unit != InstanceSize.Unit.physical)
            return fontErr!double(FontError(FontErrorKind.unsupportedCapability));
        const ppem = Ppem.fromPhysical(size.em, dotsPerInch);
        if (ppem.hasError)
            return fontErr!double(ppem.error);
        return fontOk(toPixels(design, ppem.value));
    }

    /// The value in fractional pixels at an explicit, `valid` `ppem`, whatever the instance's size.
    double pixelsAt(Ppem ppem) const scope
    in (ppem.valid)
        => toPixels(design, ppem);
}

///
@("metrics.Measurement.forms")
unittest
{
    const twelvePoints = InstanceSize.physical(LayoutUnit(12 * LayoutUnit.ticksPerPoint));
    const m = Measurement(DesignValue.fromUnits(1_024, 2_048), twelvePoints);
    assert(m.physical.value == LayoutUnit(6 * LayoutUnit.ticksPerPoint));
    assert(m.pixels(96).value == 8.0 && m.pixels(192).value == 16.0);
    assert(m.pixels.error.kind == FontErrorKind.unsupportedCapability);

    const px = Measurement(m.design, InstanceSize.pixels(Ppem.fromInteger(20).value));
    assert(px.pixels.value == 10.0);
    assert(px.physical.error.kind == FontErrorKind.unsupportedCapability);
}

package Measurement measured(in Instance inst, DesignValue d) => Measurement(d, inst.size);

// ---------------------------------------------------------------------------
// MVAR (FTV14)
// ---------------------------------------------------------------------------

/// The `MVAR` value tags this module reads (OpenType's value-tag table).
enum MvarTag : Tag
{
    horizontalAscender = Tag("hasc"),
    horizontalDescender = Tag("hdsc"),
    horizontalLineGap = Tag("hlgp"),
    horizontalClippingAscent = Tag("hcla"),
    horizontalClippingDescent = Tag("hcld"),
    xHeight = Tag("xhgt"),
    capHeight = Tag("cpht"),
    underlineOffset = Tag("undo"),
    underlineSize = Tag("unds"),
    strikeoutOffset = Tag("stro"),
    strikeoutSize = Tag("strs"),
    verticalAscender = Tag("vasc"),
    verticalDescender = Tag("vdsc"),
    verticalLineGap = Tag("vlgp"),
}

/**
The `MVAR` view (FTV14): major version 1, `valueRecordSize` at least 8, the
value records inside the table. Records are searched by tag; their item
variation store is read only by `delta`.
*/
struct Mvar
{
    @safe pure nothrow @nogc:

    private const(ubyte)[] data_;
    private ulong start_;
    private ushort recordSize_, recordCount_;
    private ItemVariationStore store_;

    /// `valueRecordSize` and `valueRecordCount`.
    ushort valueRecordSize() const scope => recordSize_;
    /// ditto
    ushort valueRecordCount() const scope => recordCount_;

    /**
    The delta of value `tag` at `coords` for a face of `unitsPerEm` (FTV14):
    zero when no record has the tag, otherwise its item variation store's
    delta (FTV12). A record with no store is `badValue`. Records are binary
    searched `valueRecordSize` bytes apart; costs O(log n + r · a).
    */
    FontResult!DesignValue delta(Tag tag, scope NormalizedCoords coords, ushort unitsPerEm) const scope
    in (unitsPerEm != 0)
    {
        size_t lo = 0, hi = recordCount_;
        while (lo < hi)
        {
            const mid = lo + (hi - lo) / 2;
            const at = 12 + size_t(recordSize_) * mid;
            const value = be32(data_, at);
            if (value == tag.value)
            {
                if (!store_.present)
                    return fontErr!DesignValue(tableError(FontErrorKind.badValue, Tag("MVAR"), start_, 10));
                return store_.delta(DeltaSetIndex(be16(data_, at + 4), be16(data_, at + 6)), coords, unitsPerEm);
            }
            if (value < tag.value)
                lo = mid + 1;
            else
                hi = mid;
        }
        return fontOk(DesignValue(0, unitsPerEm));
    }
}

/**
The face's `MVAR` view for a face of `fvarAxisCount` axes: `missingTable`
without one; `truncated` for a header or record array past the table;
`unsupportedVersion` for a major version other than 1; `badValue` for a
`valueRecordSize` below 8. Costs O(1).
*/
FontResult!Mvar mvar(return scope const Face face, ushort fvarAxisCount)
{
    enum tag = Tag("MVAR");
    auto t = face.table(tag);
    if (t.hasError)
        return fontErr!Mvar(t.error);
    const d = t.value;
    const start = face.record(face.find(tag)).offset;
    if (d.length < 12)
        return fontErr!Mvar(tableError(FontErrorKind.truncated, tag, start, d.length));
    if (be16(d, 0) != 1)
        return fontErr!Mvar(tableError(FontErrorKind.unsupportedVersion, tag, start, 0));
    Mvar m;
    m.data_ = d;
    m.start_ = start;
    m.recordSize_ = be16(d, 6);
    m.recordCount_ = be16(d, 8);
    if (m.recordSize_ < 8)
        return fontErr!Mvar(tableError(FontErrorKind.badValue, tag, start, 6));
    if (!fits(d.length, 12, ulong(m.recordSize_) * m.recordCount_))
        return fontErr!Mvar(tableError(FontErrorKind.truncated, tag, start, 12));
    const storeOffset = be16(d, 10);
    if (storeOffset != 0)
        m.store_ = ItemVariationStore.read(d, tag, start, storeOffset, fvarAxisCount);
    return fontOk(m);
}

/**
`MVAR` as an instance sees it: at all-zero coordinates or without the table
every delta is zero and nothing more is read (FTM14); an unreadable table makes
every delta its error.
*/
package struct MvarAt
{
    @safe pure nothrow @nogc:

    private Mvar view_;
    private bool active_, broken_;
    private FontError error_;

    static MvarAt of(return scope const Face face, scope const ref Instance inst)
    {
        if (inst.allZero)
            return MvarAt.init;
        auto v = mvar(face, inst.axisCount);
        if (v.hasError)
            return v.error.kind == FontErrorKind.missingTable ? MvarAt.init
                : MvarAt(Mvar.init, false, true, v.error);
        return MvarAt(v.value, true);
    }

    /// `stored` font units plus the delta of `tag`.
    FontResult!DesignValue value(int stored, Tag tag, scope const ref Instance inst) const scope
    {
        const base = DesignValue.fromUnits(stored, inst.unitsPerEm);
        if (broken_)
            return fontErr!DesignValue(error_);
        if (!active_)
            return fontOk!DesignValue(base);
        const d = view_.delta(tag, inst.coords, inst.unitsPerEm);
        if (d.hasError)
            return d;
        return checkedAdd(base, d.value);
    }
}

// ---------------------------------------------------------------------------
// The vertical sets (FTM15) and line metrics (FTM16)
// ---------------------------------------------------------------------------

/// An ascender, descender and line gap, as stored plus their `MVAR` deltas.
struct VerticalSet
{
    Measurement ascender, descender, lineGap;
}

/// The `OS/2` Windows ascent and descent, as stored (both normally positive) plus `hcla` and `hcld`.
struct WindowsSet
{
    Measurement ascent, descent;
}

/**
The three vertical sets of FTM15 and the `USE_TYPO_METRICS` flag (`fsSelection`
bit 7). The `hhea` set is present with `hhea`; the typographic and Windows
sets with `OS/2`.
*/
struct VerticalSets
{
    bool hasHhea;
    /// `hhea` ascender, descender and line gap, with `hasc`, `hdsc`, `hlgp`.
    VerticalSet hhea;
    bool hasOs2;
    /// `sTypoAscender`, `sTypoDescender`, `sTypoLineGap`, with `hasc`, `hdsc`, `hlgp`.
    VerticalSet typographic;
    /// `usWinAscent`, `usWinDescent`, with `hcla`, `hcld`.
    WindowsSet windows;
    /// `OS/2.fsSelection` bit 7; false without `OS/2`.
    bool useTypoMetrics;
}

/// `hhea` and `OS/2` as stored; a missing table is absent, an unreadable one an error.
private struct StoredSets
{
    @safe pure nothrow @nogc:

    bool hasHhea;
    Hhea hhea;
    bool hasOs2;
    Os2 os2;

    bool useTypoMetrics() const => hasOs2 && (os2.fsSelection & 0x80) != 0;
}

private FontResult!StoredSets storedSets(scope const Face face)
{
    StoredSets s;
    const h = hhea(face);
    if (h.hasValue)
    {
        s.hasHhea = true;
        s.hhea = h.value;
    }
    else if (h.error.kind != FontErrorKind.missingTable)
        return fontErr!StoredSets(h.error);
    const o = os2(face);
    if (o.hasValue)
    {
        s.hasOs2 = true;
        s.os2 = o.value;
    }
    else if (o.error.kind != FontErrorKind.missingTable)
        return fontErr!StoredSets(o.error);
    return fontOk(s);
}

/// `stored` plus the delta of `tag`, as a measurement; `out` the error on failure.
private bool take(ref Measurement result, ref FontError error, scope const ref MvarAt deltas, int stored,
    Tag tag, scope const ref Instance inst)
{
    const v = deltas.value(stored, tag, inst);
    if (v.hasError)
    {
        error = v.error;
        return false;
    }
    result = measured(inst, v.value);
    return true;
}

/**
The `hhea`, typographic and Windows sets at `inst` (FTM15), each value as
stored plus its `MVAR` delta (FTV14): the `hhea` and typographic sets take
`hasc`, `hdsc` and `hlgp`, the Windows set `hcla` and `hcld` only. Signs are
kept as stored. A missing table leaves its sets absent; an unreadable `hhea`,
`OS/2` or (at nonzero coordinates) `MVAR` is its error. Costs O(1) plus one
`MVAR` lookup per value.
*/
FontResult!VerticalSets verticalSets(in Instance inst)
{
    const face = inst.face;
    const stored = storedSets(face);
    if (stored.hasError)
        return fontErr!VerticalSets(stored.error);
    const s = stored.value;
    const deltas = MvarAt.of(inst.face, inst);
    VerticalSets r;
    FontError e;
    r.useTypoMetrics = s.useTypoMetrics;
    if (s.hasHhea)
    {
        r.hasHhea = true;
        if (!take(r.hhea.ascender, e, deltas, s.hhea.ascender, MvarTag.horizontalAscender, inst)
            || !take(r.hhea.descender, e, deltas, s.hhea.descender, MvarTag.horizontalDescender, inst)
            || !take(r.hhea.lineGap, e, deltas, s.hhea.lineGap, MvarTag.horizontalLineGap, inst))
            return fontErr!VerticalSets(e);
    }
    if (s.hasOs2)
    {
        r.hasOs2 = true;
        if (!take(r.typographic.ascender, e, deltas, s.os2.sTypoAscender, MvarTag.horizontalAscender, inst)
            || !take(r.typographic.descender, e, deltas, s.os2.sTypoDescender, MvarTag.horizontalDescender, inst)
            || !take(r.typographic.lineGap, e, deltas, s.os2.sTypoLineGap, MvarTag.horizontalLineGap, inst)
            || !take(r.windows.ascent, e, deltas, s.os2.usWinAscent, MvarTag.horizontalClippingAscent, inst)
            || !take(r.windows.descent, e, deltas, s.os2.usWinDescent, MvarTag.horizontalClippingDescent, inst))
            return fontErr!VerticalSets(e);
    }
    return fontOk(r);
}

/// Which vertical set line metrics came from (FTM2, FTM16).
enum LineMetricsSource : ubyte
{
    /// No set remains: the line metrics are absent.
    none,
    typographic,
    hhea,
    windows,
}

/**
Line metrics (FTM16): an ascender, a descender (negative below the baseline)
and a line gap, and the set they came from. `source` is `none` when they are
absent.
*/
struct LineMetrics
{
    @safe pure nothrow @nogc:

    LineMetricsSource source;
    Measurement ascender, descender, lineGap;

    /// Whether a set was found.
    bool present() const scope => source != LineMetricsSource.none;
}

/**
The line metrics at `inst` (FTM16), by FTM2's order on the sets that are
present: the typographic set when `USE_TYPO_METRICS` is set; otherwise `hhea`
when its ascender or descender is nonzero; otherwise the typographic set when
its ascender or descender is nonzero; otherwise the Windows set, whose
descender is the negated `usWinDescent` (with `hcld`) and whose line gap is
zero. The set is chosen on its stored values; its `MVAR` deltas are then
added. With no set left the result is not `present`. Errors as
`verticalSets`. Costs O(1) plus three `MVAR` lookups.
*/
FontResult!LineMetrics lineMetrics(in Instance inst)
{
    const face = inst.face;
    const stored = storedSets(face);
    if (stored.hasError)
        return fontErr!LineMetrics(stored.error);
    const s = stored.value;

    LineMetrics r;
    int ascender, descender, lineGap;
    if (s.useTypoMetrics)
        r.source = LineMetricsSource.typographic;
    else if (s.hasHhea && (s.hhea.ascender != 0 || s.hhea.descender != 0))
        r.source = LineMetricsSource.hhea;
    else if (s.hasOs2 && (s.os2.sTypoAscender != 0 || s.os2.sTypoDescender != 0))
        r.source = LineMetricsSource.typographic;
    else if (s.hasOs2)
        r.source = LineMetricsSource.windows;
    else
        return fontOk(r);

    const deltas = MvarAt.of(inst.face, inst);
    FontError e;
    final switch (r.source)
    {
        case LineMetricsSource.none:
            assert(0);
        case LineMetricsSource.hhea:
            if (!take(r.ascender, e, deltas, s.hhea.ascender, MvarTag.horizontalAscender, inst)
                || !take(r.descender, e, deltas, s.hhea.descender, MvarTag.horizontalDescender, inst)
                || !take(r.lineGap, e, deltas, s.hhea.lineGap, MvarTag.horizontalLineGap, inst))
                return fontErr!LineMetrics(e);
            break;
        case LineMetricsSource.typographic:
            if (!take(r.ascender, e, deltas, s.os2.sTypoAscender, MvarTag.horizontalAscender, inst)
                || !take(r.descender, e, deltas, s.os2.sTypoDescender, MvarTag.horizontalDescender, inst)
                || !take(r.lineGap, e, deltas, s.os2.sTypoLineGap, MvarTag.horizontalLineGap, inst))
                return fontErr!LineMetrics(e);
            break;
        case LineMetricsSource.windows:
            Measurement descent;
            if (!take(r.ascender, e, deltas, s.os2.usWinAscent, MvarTag.horizontalClippingAscent, inst)
                || !take(descent, e, deltas, s.os2.usWinDescent, MvarTag.horizontalClippingDescent, inst))
                return fontErr!LineMetrics(e);
            // -(stored + delta): the raw count's magnitude is far below long.max.
            r.descender = measured(inst, DesignValue(-descent.design.raw, inst.unitsPerEm));
            r.lineGap = measured(inst, DesignValue(0, inst.unitsPerEm));
            break;
    }
    return fontOk(r);
}

// ---------------------------------------------------------------------------
// Decorations (FTM17)
// ---------------------------------------------------------------------------

/**
x-height, cap height, underline and strikeout (FTM17), each with its `MVAR`
delta. A value whose `has…` flag is false is absent (FTM3); a stored zero is
a value.
*/
struct Decorations
{
    /// `OS/2` version 2 or later: `sxHeight` with `xhgt`, `sCapHeight` with `cpht`.
    bool hasXHeight;
    /// ditto
    Measurement xHeight;
    /// ditto
    bool hasCapHeight;
    /// ditto
    Measurement capHeight;
    /// `post` present: `underlinePosition` with `undo`, `underlineThickness` with `unds`.
    bool hasUnderline;
    /// ditto
    Measurement underlinePosition, underlineThickness;
    /// `OS/2` present: `yStrikeoutPosition` with `stro`, `yStrikeoutSize` with `strs`.
    bool hasStrikeout;
    /// ditto
    Measurement strikeoutPosition, strikeoutSize;
}

/**
The decorations at `inst` (FTM17). A missing `OS/2` or `post` leaves its
values absent; an unreadable one, or (at nonzero coordinates) an unreadable
`MVAR`, is its error. Costs O(1) plus one `MVAR` lookup per value.
*/
FontResult!Decorations decorations(in Instance inst)
{
    const face = inst.face;
    const deltas = MvarAt.of(inst.face, inst);
    Decorations r;
    FontError e;
    const o = os2(face);
    if (o.hasError && o.error.kind != FontErrorKind.missingTable)
        return fontErr!Decorations(o.error);
    if (o.hasValue)
    {
        const v = o.value;
        if (v.hasXHeight)
        {
            r.hasXHeight = r.hasCapHeight = true;
            if (!take(r.xHeight, e, deltas, v.sxHeight, MvarTag.xHeight, inst)
                || !take(r.capHeight, e, deltas, v.sCapHeight, MvarTag.capHeight, inst))
                return fontErr!Decorations(e);
        }
        r.hasStrikeout = true;
        if (!take(r.strikeoutPosition, e, deltas, v.yStrikeoutPosition, MvarTag.strikeoutOffset, inst)
            || !take(r.strikeoutSize, e, deltas, v.yStrikeoutSize, MvarTag.strikeoutSize, inst))
            return fontErr!Decorations(e);
    }
    const p = post(face);
    if (p.hasError && p.error.kind != FontErrorKind.missingTable)
        return fontErr!Decorations(p.error);
    if (p.hasValue)
    {
        r.hasUnderline = true;
        if (!take(r.underlinePosition, e, deltas, p.value.underlinePosition, MvarTag.underlineOffset, inst)
            || !take(r.underlineThickness, e, deltas, p.value.underlineThickness, MvarTag.underlineSize, inst))
            return fontErr!Decorations(e);
    }
    return fontOk(r);
}

// ---------------------------------------------------------------------------
// HVAR and advances (FTV14, FTM18)
// ---------------------------------------------------------------------------

/**
The `HVAR` view (FTV14): major version 1, its item variation store, and its
advance-width map, the identity on the glyph ID when its offset is 0. Only
advances are read; the side-bearing maps belong to M3.
*/
struct Hvar
{
    @safe pure nothrow @nogc:

    private ItemVariationStore store_;
    private DeltaSetIndexMap advanceMap_;
    private ulong start_;
    private bool hasStore_;

    /**
    The advance delta of glyph `gid` at `coords` for a face of `unitsPerEm`:
    the store's delta (FTV12) of the item the advance map gives `gid`
    (FTV13). A null store offset is `badValue`. Costs O(r · a).
    */
    FontResult!DesignValue advanceDelta(uint gid, scope NormalizedCoords coords, ushort unitsPerEm) const scope
    in (unitsPerEm != 0)
    {
        if (!hasStore_)
            return fontErr!DesignValue(tableError(FontErrorKind.badValue, Tag("HVAR"), start_, 4));
        const index = advanceMap_.map(gid);
        if (index.hasError)
            return fontErr!DesignValue(index.error);
        return store_.delta(index.value, coords, unitsPerEm);
    }
}

/**
The face's `HVAR` view for a face of `fvarAxisCount` axes: `missingTable`
without one, `truncated` for a header past the table, `unsupportedVersion`
for a major version other than 1. A malformed store or map is reported by
`advanceDelta`. Costs O(1).
*/
FontResult!Hvar hvar(return scope const Face face, ushort fvarAxisCount)
{
    enum tag = Tag("HVAR");
    auto t = face.table(tag);
    if (t.hasError)
        return fontErr!Hvar(t.error);
    const d = t.value;
    const start = face.record(face.find(tag)).offset;
    if (d.length < 20)
        return fontErr!Hvar(tableError(FontErrorKind.truncated, tag, start, d.length));
    if (be16(d, 0) != 1)
        return fontErr!Hvar(tableError(FontErrorKind.unsupportedVersion, tag, start, 0));
    Hvar h;
    h.start_ = start;
    const storeOffset = be32(d, 4), mapOffset = be32(d, 8);
    if (storeOffset != 0)
    {
        h.hasStore_ = true;
        h.store_ = ItemVariationStore.read(d, tag, start, storeOffset, fvarAxisCount);
    }
    if (mapOffset != 0)
        h.advanceMap_ = DeltaSetIndexMap.read(d, tag, start, mapOffset);
    return fontOk(h);
}

/**
What advances at an instance read, prepared once: `hmtx`, and at nonzero
coordinates `HVAR` or the error every varied advance gives.
*/
private struct AdvanceSource
{
    @safe pure nothrow @nogc:

    private Hmtx hmtx_;
    private Hvar hvar_;
    private bool varied_, broken_;
    private FontError error_;

    static FontResult!AdvanceSource of(return scope const Face face, scope const ref Instance inst)
    {
        auto m = hmtx(face);
        if (m.hasError)
            return fontErr!AdvanceSource(m.error);
        if (inst.allZero)
            return fontOk(AdvanceSource(m.value));
        auto h = hvar(face, inst.axisCount);
        if (h.hasError)
            // No HVAR: phantom points are M3's (FTV14).
            return fontOk(AdvanceSource(m.value, Hvar.init, true, true,
                h.error.kind == FontErrorKind.missingTable
                    ? FontError(FontErrorKind.unsupportedCapability, Tag("HVAR")) : h.error));
        return fontOk(AdvanceSource(m.value, h.value, true));
    }

    FontResult!DesignValue advance(uint gid, scope const ref Instance inst) const scope
    {
        const a = hmtx_.advance(gid);
        if (a.hasError)
            return fontErr!DesignValue(a.error);
        const stored = DesignValue.fromUnits(a.value, inst.unitsPerEm);
        if (!varied_)
            return fontOk!DesignValue(stored);
        if (broken_)
            return fontErr!DesignValue(error_);
        const d = hvar_.advanceDelta(gid, inst.coords, inst.unitsPerEm);
        if (d.hasError)
            return d;
        return checkedAdd(stored, d.value);
    }
}

/**
The advance of glyph `gid` at `inst` (FTM18): the `hmtx` advance (FTP24)
plus, at nonzero coordinates, the `HVAR` delta (FTV14). A face without
`HVAR` at nonzero coordinates is `unsupportedCapability`; an unreadable
`HVAR` is its error, with no fallback. A negative varied advance is returned
as computed. Costs O(r · a).
*/
FontResult!Measurement advance(in Instance inst, uint gid)
{
    const source = AdvanceSource.of(inst.face, inst);
    if (source.hasError)
        return fontErr!Measurement(source.error);
    const a = source.value.advance(gid, inst);
    if (a.hasError)
        return fontErr!Measurement(a.error);
    return fontOk(measured(inst, a.value));
}

/**
The summed advances of the run `gids` at `inst` (FTM18), added as design
values and checked (`arithmeticExhausted` on overflow), so a conversion of
the result rounds once (FTM6). Kerning is not included. The first error any
glyph gives is returned and nothing else. Costs O(n · r · a) for `n` glyphs.
*/
FontResult!Measurement measureRun(in Instance inst, scope const(uint)[] gids)
{
    const source = AdvanceSource.of(inst.face, inst);
    if (source.hasError)
        return fontErr!Measurement(source.error);
    auto total = DesignValue(0, inst.unitsPerEm);
    foreach (gid; gids)
    {
        const a = source.value.advance(gid, inst);
        if (a.hasError)
            return fontErr!Measurement(a.error);
        const sum = checkedAdd(total, a.value);
        if (sum.hasError)
            return fontErr!Measurement(sum.error);
        total = sum.value;
    }
    return fontOk(measured(inst, total));
}

// ---------------------------------------------------------------------------
// Cell metrics (FTM19)
// ---------------------------------------------------------------------------

/**
Cell metrics in whole device pixels (FTM5, FTM19). `baseline` and
`underlinePosition` are measured down from the cell's top.
*/
struct CellMetrics
{
    /// Where `width` came from.
    enum WidthSource : ubyte
    {
        /// The advance of the glyph U+0030 DIGIT ZERO maps to.
        digitZero,
        /// `OS/2.xAvgCharWidth`, as U+0030 is unmapped.
        averageCharWidth,
    }

    /// The ppem the metrics were rounded at.
    uint ppem;
    long width;
    WidthSource widthSource;
    long ascent, descent, lineGap, height, baseline;
    /// Which vertical set the line metrics came from.
    LineMetricsSource lineSource;
    /// Whether the face has an underline (`post`); the two values are 0 otherwise.
    bool hasUnderline;
    long underlinePosition, underlineThickness;
}

/// Pixel magnitudes from 2^53 on are refused: a `double` stops holding every integer there.
private enum double maxCellPixels = 9_007_199_254_740_992.0;

/// `x` rounded to the nearest integer, ties to even, whatever the FPU rounding mode.
private double roundHalfEven(double x)
{
    const f = floor(x);
    const fraction = x - f; // exact for any finite double
    if (fraction > 0.5)
        return f + 1;
    if (fraction < 0.5)
        return f;
    return floor(f / 2) * 2 == f ? f : f + 1;
}

///
@("metrics.roundHalfEven")
unittest
{
    assert(roundHalfEven(2.5) == 2 && roundHalfEven(3.5) == 4 && roundHalfEven(-2.5) == -2);
    assert(roundHalfEven(-3.5) == -4 && roundHalfEven(2.4999) == 2 && roundHalfEven(0.5) == 0);
}

/// `x` as a `long`, or `arithmeticExhausted` when it is not below 2^53 in magnitude.
private FontResult!long wholePixels(double x)
    => x < maxCellPixels && x > -maxCellPixels ? fontOk(cast(long) x)
        : fontErr!long(FontError(FontErrorKind.arithmeticExhausted));

/**
The cell metrics of `inst` at the integer `ppem` (FTM19), from the pixel
values of FTM10 at that ppem and the instance's coordinates (its size is not
used). `cmap` is the face's character map, built once by the caller: FTA5
forbids a hidden cache, and building one costs O(L + 65,536), so the
proposed `cellMetrics(ppem)` takes it as a parameter.

$(UL
    $(LI width: the advance of U+0030's glyph, else `OS/2.xAvgCharWidth`,
        rounded to nearest with ties to even, at least 1; `widthSource` names
        which. An error from the U+0030 advance is returned, not replaced.)
    $(LI ascent: the line ascender rounded up; descent: the negated line
        descender rounded up, at least 0; line gap: rounded to nearest with
        ties to even, at least 0; height: their sum.)
    $(LI baseline: ascent + ⌊line gap / 2⌋ from the cell's top.)
    $(LI underline: `baseline − underlinePosition` rounded to nearest with
        ties to even (the difference is rounded, not the position), and the
        thickness rounded the same way, at least 1; absent without `post`.)
)

A zero `ppem` is `badValue`. A face that maps no U+0030 and has no `OS/2`,
or whose line metrics are absent, is `unsupportedCapability`; a pixel value
of 2^53 or more is `arithmeticExhausted`. Costs one `cmap` lookup, one
advance, one line-metrics query and two `MVAR` lookups for the underline.
*/
FontResult!CellMetrics cellMetrics(in Instance inst, scope const ref CharMap cmap, uint ppem)
{
    if (ppem == 0)
        return fontErr!CellMetrics(FontError(FontErrorKind.badValue));
    const scale = Ppem.fromInteger(ppem).value;
    CellMetrics r;
    r.ppem = ppem;

    double widthPixels;
    const zero = cmap.glyph('0');
    if (zero != 0)
    {
        const a = advance(inst, zero);
        if (a.hasError)
            return fontErr!CellMetrics(a.error);
        widthPixels = a.value.pixelsAt(scale);
        r.widthSource = CellMetrics.WidthSource.digitZero;
    }
    else
    {
        const o = os2(inst.face);
        if (o.hasError)
            return fontErr!CellMetrics(o.error.kind == FontErrorKind.missingTable
                ? FontError(FontErrorKind.unsupportedCapability, Tag("OS/2")) : o.error);
        widthPixels = toPixels(DesignValue.fromUnits(o.value.xAvgCharWidth, inst.unitsPerEm), scale);
        r.widthSource = CellMetrics.WidthSource.averageCharWidth;
    }

    const lines = lineMetrics(inst);
    if (lines.hasError)
        return fontErr!CellMetrics(lines.error);
    if (!lines.value.present)
        return fontErr!CellMetrics(FontError(FontErrorKind.unsupportedCapability));
    const l = lines.value;
    r.lineSource = l.source;

    const width = wholePixels(roundHalfEven(widthPixels));
    const ascent = wholePixels(ceil(l.ascender.pixelsAt(scale)));
    const descent = wholePixels(ceil(-l.descender.pixelsAt(scale)));
    const gap = wholePixels(roundHalfEven(l.lineGap.pixelsAt(scale)));
    if (width.hasError || ascent.hasError || descent.hasError || gap.hasError)
        return fontErr!CellMetrics(FontError(FontErrorKind.arithmeticExhausted));
    r.width = width.value < 1 ? 1 : width.value;
    r.ascent = ascent.value;
    r.descent = descent.value < 0 ? 0 : descent.value;
    r.lineGap = gap.value < 0 ? 0 : gap.value;
    r.height = r.ascent + r.descent + r.lineGap;
    // floor(gap / 2) of a gap that is at least 0.
    r.baseline = r.ascent + r.lineGap / 2;

    const p = post(inst.face);
    if (p.hasError && p.error.kind != FontErrorKind.missingTable)
        return fontErr!CellMetrics(p.error);
    if (p.hasValue)
    {
        const deltas = MvarAt.of(inst.face, inst);
        Measurement position, thickness;
        FontError e;
        if (!take(position, e, deltas, p.value.underlinePosition, MvarTag.underlineOffset, inst)
            || !take(thickness, e, deltas, p.value.underlineThickness, MvarTag.underlineSize, inst))
            return fontErr!CellMetrics(e);
        const at = wholePixels(roundHalfEven(r.baseline - position.pixelsAt(scale)));
        const size = wholePixels(roundHalfEven(thickness.pixelsAt(scale)));
        if (at.hasError || size.hasError)
            return fontErr!CellMetrics(FontError(FontErrorKind.arithmeticExhausted));
        r.hasUnderline = true;
        r.underlinePosition = at.value;
        r.underlineThickness = size.value < 1 ? 1 : size.value;
    }
    return fontOk(r);
}
