/**
Vertical metrics at an instance (`docs/specs/font/variation-metrics.md` § 5,
FTV14, FTM20, FTM21).

`vhea`, `vmtx`, `VORG` and `VVAR` views borrow the face's bytes.
`verticalLineMetrics` reads `vhea` plus the `vasc`, `vdsc` and `vlgp` `MVAR`
deltas; `verticalAdvance` reads `vmtx` with `FTP24`'s leniency plus the `VVAR`
advance delta, or without `VVAR` the `gvar` phantom points; `verticalOrigin`
reads `VORG` plus the `VVAR` origin delta, or without `VORG` a `glyf` glyph's
top phantom point, and says which it used. Nothing is synthesized: without
the tables a result is absent (FTM12), and a layout that needs a fallback
chooses its own.

Views are built per query, each an O(1) header read; nothing is cached. At an
instance whose coordinates are all zero, neither `VVAR` nor `MVAR` is read
(FTM14). Phantom points decode into a caller's `PointWorkspace`; nothing here
allocates.
*/
module sparkles.font.vertical;

import sparkles.font.bytes : be16, be32, bes16, fits;
import sparkles.font.errors : FontError, FontErrorKind, FontResult, fontErr, fontOk, Tag, tableError;
import sparkles.font.face : Face;
import sparkles.font.instance : Instance;
import sparkles.font.metrics : Measurement, measured, MvarAt, MvarTag;
import sparkles.font.outlines : phantomTop, phantomVerticalAdvance, PointWorkspace;
import sparkles.font.tables : locate, shortTable;
import sparkles.font.units : checkedAdd, DesignValue;
import sparkles.font.variations : DeltaSetIndexMap, ItemVariationStore, NormalizedCoords;

@safe pure nothrow @nogc:

// ---------------------------------------------------------------------------
// vhea and vmtx (FTM20)
// ---------------------------------------------------------------------------

/**
`vhea`, at least 36 bytes, version 1.0 (`0x00010000`) or 1.1 (`0x00011000`).
Version 1.1 names the first three fields `vertTypoAscender`,
`vertTypoDescender` and `vertTypoLineGap`; both versions are reported as
stored.
*/
struct Vhea
{
    /// The 16.16 version: `0x00010000` or `0x00011000`.
    uint version_;
    short ascender, descender, lineGap;
    ushort advanceHeightMax;
    short minTopSideBearing, minBottomSideBearing, yMaxExtent;
    short caretSlopeRise, caretSlopeRun, caretOffset;
    short metricDataFormat;
    ushort numOfLongVerMetrics;
}

/**
The face's `vhea` table: `missingTable` without one, `truncated` below 36
bytes, `unsupportedVersion` for a version other than 1.0 or 1.1. Costs O(1).
*/
FontResult!Vhea vhea(scope const Face face)
{
    enum tag = Tag("vhea");
    const at = locate(face, tag);
    if (at.hasError)
        return fontErr!Vhea(at.error);
    const d = at.value.data;
    if (d.length < 36)
        return shortTable!Vhea(tag, at.value, 36);
    const version_ = be32(d, 0);
    if (version_ != 0x0001_0000 && version_ != 0x0001_1000)
        return fontErr!Vhea(tableError(FontErrorKind.unsupportedVersion, tag, at.value.start, 0));
    return fontOk(Vhea(version_, bes16(d, 4), bes16(d, 6), bes16(d, 8), be16(d, 10), bes16(d, 12),
        bes16(d, 14), bes16(d, 16), bes16(d, 18), bes16(d, 20), bes16(d, 22), bes16(d, 32), be16(d, 34)));
}

/// A glyph's vertical metrics in font units.
struct VerticalMetric
{
    ushort advanceHeight;
    short topSideBearing;
}

/// The `vmtx` view: lenient where real fonts are short, as `hmtx` is (FTP24).
struct Vmtx
{
    @safe pure nothrow @nogc:

    private const(ubyte)[] data_;
    private ulong start_;
    private ushort numOfLongVerMetrics_;
    private ushort numGlyphs_;

    /// `numOfLongVerMetrics`, read as at most `numGlyphs`.
    ushort numOfLongVerMetrics() const scope => numOfLongVerMetrics_;

    /**
    The metrics of glyph `gid` (FTP24's rules): `indexOutOfRange` for
    `gid ≥ numGlyphs`; past `numOfLongVerMetrics` the last long metric's
    advance and the glyph's own top side bearing; `truncated` for a glyph
    whose entry lies past the table, that glyph only. Costs O(1).
    */
    FontResult!VerticalMetric metric(uint gid) const scope
    {
        enum tag = Tag("vmtx");
        if (gid >= numGlyphs_)
            return fontErr!VerticalMetric(FontError(FontErrorKind.indexOutOfRange, tag));
        const n = numOfLongVerMetrics_;
        const advanceAt = 4UL * (gid < n ? gid : n - 1u);
        const tsbAt = gid < n ? 4UL * gid + 2 : 4UL * n + 2UL * (gid - n);
        if (!fits(data_.length, advanceAt, 2))
            return fontErr!VerticalMetric(tableError(FontErrorKind.truncated, tag, start_, advanceAt));
        if (!fits(data_.length, tsbAt, 2))
            return fontErr!VerticalMetric(tableError(FontErrorKind.truncated, tag, start_, tsbAt));
        return fontOk(VerticalMetric(be16(data_, cast(size_t) advanceAt), bes16(data_, cast(size_t) tsbAt)));
    }

    /// The advance height of glyph `gid`.
    FontResult!ushort advance(uint gid) const scope
    {
        const m = metric(gid);
        return m.hasError ? fontErr!ushort(m.error) : fontOk!ushort(m.value.advanceHeight);
    }

    /// The top side bearing of glyph `gid`.
    FontResult!short topSideBearing(uint gid) const scope
    {
        const m = metric(gid);
        return m.hasError ? fontErr!short(m.error) : fontOk!short(m.value.topSideBearing);
    }
}

/**
The face's `vmtx` view, which needs a readable `vhea`: its error when it is
not (`missingTable` included), `badValue` for `numOfLongVerMetrics` 0 in a
face with glyphs, `missingTable` without `vmtx`. Costs O(1).
*/
FontResult!Vmtx vmtx(return scope const Face face)
{
    const h = vhea(face);
    if (h.hasError)
        return fontErr!Vmtx(h.error);
    if (h.value.numOfLongVerMetrics == 0 && face.numGlyphs > 0)
        return fontErr!Vmtx(tableError(FontErrorKind.badValue, Tag("vhea"),
            face.record(face.find(Tag("vhea"))).offset, 34));
    auto at = locate(face, Tag("vmtx"));
    if (at.hasError)
        return fontErr!Vmtx(at.error);
    const n = h.value.numOfLongVerMetrics < face.numGlyphs ? h.value.numOfLongVerMetrics : face.numGlyphs;
    return fontOk(Vmtx(at.value.data, at.value.start, n, face.numGlyphs));
}

// ---------------------------------------------------------------------------
// VORG (FTM21)
// ---------------------------------------------------------------------------

/// A `VORG` value and whether a glyph record supplied it.
struct VorgValue
{
    short vertOriginY;
    /// True for the glyph's record, false for `defaultVertOriginY`.
    bool fromRecord;
}

/**
The `VORG` view: version 1.0, `defaultVertOriginY` and the
`vertOriginYMetrics` records, sorted by glyph ID.
*/
struct Vorg
{
    @safe pure nothrow @nogc:

    private const(ubyte)[] data_;
    private short default_;
    private ushort count_;

    /// `defaultVertOriginY`.
    short defaultVertOriginY() const scope => default_;
    /// `numVertOriginYMetrics`.
    ushort numVertOriginYMetrics() const scope => count_;

    /**
    The vertical origin of glyph `gid`: its record, found by binary search,
    else `defaultVertOriginY`. Costs O(log n).
    */
    VorgValue originY(uint gid) const scope
    {
        size_t lo = 0, hi = count_;
        while (lo < hi)
        {
            const mid = lo + (hi - lo) / 2;
            const at = 8 + 4 * mid;
            const g = be16(data_, at);
            if (g == gid)
                return VorgValue(bes16(data_, at + 2), true);
            if (g < gid)
                lo = mid + 1;
            else
                hi = mid;
        }
        return VorgValue(default_, false);
    }
}

/**
The face's `VORG` view: `missingTable` without one, `truncated` for a header
or record array past the table, `unsupportedVersion` for a version other than
1.0. Costs O(1).
*/
FontResult!Vorg vorg(return scope const Face face)
{
    enum tag = Tag("VORG");
    auto at = locate(face, tag);
    if (at.hasError)
        return fontErr!Vorg(at.error);
    const d = at.value.data;
    if (d.length < 8)
        return shortTable!Vorg(tag, at.value, 8);
    if (be16(d, 0) != 1 || be16(d, 2) != 0)
        return fontErr!Vorg(tableError(FontErrorKind.unsupportedVersion, tag, at.value.start, 0));
    const count = be16(d, 6);
    if (!fits(d.length, 8, 4UL * count))
        return fontErr!Vorg(tableError(FontErrorKind.truncated, tag, at.value.start, 8));
    return fontOk(Vorg(d, bes16(d, 4), count));
}

// ---------------------------------------------------------------------------
// VVAR (FTV14)
// ---------------------------------------------------------------------------

/**
The `VVAR` view (FTV14), the vertical analogue of `HVAR`: major version 1,
its item variation store, its advance-height map (the identity on the glyph
ID when its offset is 0) and its vertical-origin map. The top and bottom side
bearing maps belong to M3 and are not read.
*/
struct Vvar
{
    @safe pure nothrow @nogc:

    private ItemVariationStore store_;
    private DeltaSetIndexMap advanceMap_, originMap_;
    private ulong start_;
    private bool hasStore_, hasOriginMap_;

    /// Whether the table has a vertical-origin map.
    bool hasOriginMap() const scope => hasOriginMap_;

    /**
    The advance-height delta of glyph `gid` at `coords` for a face of
    `unitsPerEm`: the store's delta (FTV12) of the item the advance map gives
    `gid` (FTV13). A null store offset is `badValue`. Costs O(r · a).
    */
    FontResult!DesignValue advanceDelta(uint gid, scope NormalizedCoords coords, ushort unitsPerEm) const scope
    in (unitsPerEm != 0)
        => delta(advanceMap_, gid, coords, unitsPerEm);

    /**
    The vertical-origin delta of glyph `gid`, through the origin map: zero
    without one, otherwise as `advanceDelta`. Costs O(r · a).
    */
    FontResult!DesignValue originDelta(uint gid, scope NormalizedCoords coords, ushort unitsPerEm) const scope
    in (unitsPerEm != 0)
    {
        if (!hasOriginMap_)
            return fontOk(DesignValue(0, unitsPerEm));
        return delta(originMap_, gid, coords, unitsPerEm);
    }

    private FontResult!DesignValue delta(scope const ref DeltaSetIndexMap map, uint gid,
        scope NormalizedCoords coords, ushort unitsPerEm) const scope
    {
        if (!hasStore_)
            return fontErr!DesignValue(tableError(FontErrorKind.badValue, Tag("VVAR"), start_, 4));
        const index = map.map(gid);
        if (index.hasError)
            return fontErr!DesignValue(index.error);
        return store_.delta(index.value, coords, unitsPerEm);
    }
}

/**
The face's `VVAR` view for a face of `fvarAxisCount` axes: `missingTable`
without one, `truncated` for a header (24 bytes) past the table,
`unsupportedVersion` for a major version other than 1. A malformed store or
map is reported by the deltas that read it. Costs O(1).
*/
FontResult!Vvar vvar(return scope const Face face, ushort fvarAxisCount)
{
    enum tag = Tag("VVAR");
    auto at = locate(face, tag);
    if (at.hasError)
        return fontErr!Vvar(at.error);
    const d = at.value.data;
    const start = at.value.start;
    if (d.length < 24)
        return shortTable!Vvar(tag, at.value, 24);
    if (be16(d, 0) != 1)
        return fontErr!Vvar(tableError(FontErrorKind.unsupportedVersion, tag, start, 0));
    Vvar v;
    v.start_ = start;
    const storeOffset = be32(d, 4), advanceOffset = be32(d, 8), originOffset = be32(d, 20);
    if (storeOffset != 0)
    {
        v.hasStore_ = true;
        v.store_ = ItemVariationStore.read(d, tag, start, storeOffset, fvarAxisCount);
    }
    if (advanceOffset != 0)
        v.advanceMap_ = DeltaSetIndexMap.read(d, tag, start, advanceOffset);
    if (originOffset != 0)
    {
        v.hasOriginMap_ = true;
        v.originMap_ = DeltaSetIndexMap.read(d, tag, start, originOffset);
    }
    return fontOk(v);
}

// ---------------------------------------------------------------------------
// Queries at an instance (FTM20, FTM21)
// ---------------------------------------------------------------------------

/**
Vertical line metrics (FTM20): `vhea`'s ascender, descender and line gap as
stored plus their `MVAR` deltas. Absent (`present` false) without `vhea`.
*/
struct VerticalLineMetrics
{
    bool present;
    Measurement ascender, descender, lineGap;
}

/**
The vertical line metrics of `inst` (FTM20): `vhea`'s three values plus the
`vasc`, `vdsc` and `vlgp` deltas (FTV14), signs as stored. Absent without
`vhea`; an unreadable `vhea`, or at nonzero coordinates an unreadable `MVAR`,
is its error. Costs O(1) plus three `MVAR` lookups.
*/
FontResult!VerticalLineMetrics verticalLineMetrics(in Instance inst)
{
    VerticalLineMetrics r;
    const h = vhea(inst.face);
    if (h.hasError)
        return h.error.kind == FontErrorKind.missingTable ? fontOk(r) : fontErr!VerticalLineMetrics(h.error);
    const deltas = MvarAt.of(inst.face, inst);
    const a = deltas.value(h.value.ascender, MvarTag.verticalAscender, inst);
    if (a.hasError)
        return fontErr!VerticalLineMetrics(a.error);
    const d = deltas.value(h.value.descender, MvarTag.verticalDescender, inst);
    if (d.hasError)
        return fontErr!VerticalLineMetrics(d.error);
    const g = deltas.value(h.value.lineGap, MvarTag.verticalLineGap, inst);
    if (g.hasError)
        return fontErr!VerticalLineMetrics(g.error);
    r.present = true;
    r.ascender = measured(inst, a.value);
    r.descender = measured(inst, d.value);
    r.lineGap = measured(inst, g.value);
    return fontOk(r);
}

/// A vertical advance (FTM20); `present` is false without `vhea` or `vmtx`.
struct VerticalAdvance
{
    bool present;
    Measurement advance;
}

/**
The vertical advance of glyph `gid` at `inst` (FTM20): the `vmtx` advance
under FTP24's rules with `vhea`'s `numOfLongVerMetrics`, plus at nonzero
coordinates the `VVAR` delta (FTV14).

`gid ≥ numGlyphs` is `indexOutOfRange`, checked first. Without `vhea` or
`vmtx` the advance is absent. At nonzero coordinates a face without `VVAR`
takes the span of its `gvar` phantom points (FTO5), decoded into `ws`, or
the stored advance without `gvar`, as HarfBuzz does; an unreadable `VVAR`
is its error, with no fallback. A negative varied advance is returned as
computed. At the default the stored advance is returned and `VVAR` is not
read (FTM14). Costs O(r · a), or `phantomVerticalAdvance`'s on the phantom
path.
*/
FontResult!VerticalAdvance verticalAdvance(in Instance inst, uint gid, scope ref PointWorkspace ws)
{
    const face = inst.face;
    if (gid >= face.numGlyphs)
        return fontErr!VerticalAdvance(FontError(FontErrorKind.indexOutOfRange, Tag("vmtx")));
    VerticalAdvance r;
    if (!face.has(Tag("vhea")) || !face.has(Tag("vmtx")))
        return fontOk(r);
    const m = vmtx(face);
    if (m.hasError)
        return fontErr!VerticalAdvance(m.error);
    const a = m.value.advance(gid);
    if (a.hasError)
        return fontErr!VerticalAdvance(a.error);
    auto value = DesignValue.fromUnits(a.value, inst.unitsPerEm);
    if (!inst.allZero)
    {
        const v = vvar(face, inst.axisCount);
        if (v.hasError && v.error.kind != FontErrorKind.missingTable)
            return fontErr!VerticalAdvance(v.error);
        if (v.hasError)
        {
            // No VVAR: the gvar phantom points, as for `advance` (FTO5).
            if (face.has(Tag("gvar")) && face.has(Tag("glyf")))
            {
                const p = phantomVerticalAdvance(inst, gid, ws);
                if (p.hasError)
                    return fontErr!VerticalAdvance(p.error);
                value = p.value;
            }
            r.present = true;
            r.advance = measured(inst, value);
            return fontOk(r);
        }
        const d = v.value.advanceDelta(gid, inst.coords, inst.unitsPerEm);
        if (d.hasError)
            return fontErr!VerticalAdvance(d.error);
        const sum = checkedAdd(value, d.value);
        if (sum.hasError)
            return fontErr!VerticalAdvance(sum.error);
        value = sum.value;
    }
    r.present = true;
    r.advance = measured(inst, value);
    return fontOk(r);
}

/// Where a vertical origin came from (FTM21); `none` is absent.
enum VerticalOriginSource : ubyte
{
    /// No `VORG`, and no `vmtx` with `glyf`: the origin is absent.
    none,
    /// The glyph's `VORG` record.
    vorgRecord,
    /// `VORG.defaultVertOriginY`, as the glyph has no record.
    vorgDefault,
    /**
    No `VORG`: the glyph's top phantom point (FTO5), its stored `yMax` plus
    the `vmtx` top side bearing, moved by `gvar`.
    */
    vmtxGlyph,
}

/**
A vertical origin's y coordinate with its provenance (FTM7, FTM21). `varied`
says whether a `VVAR` origin delta was read and added.
*/
struct VerticalOrigin
{
    @safe pure nothrow @nogc:

    VerticalOriginSource source;
    Measurement y;
    bool varied;

    /// Whether the face supplies an origin.
    bool present() const scope => source != VerticalOriginSource.none;
}

/**
The vertical origin of glyph `gid` at `inst` (FTM21), by FTM21's table:

$(UL
    $(LI `VORG` 1.0: the glyph's record by binary search, else
        `defaultVertOriginY`; at nonzero coordinates plus the `VVAR` origin
        delta when `VVAR` has an origin map. A missing `VVAR` or one without
        an origin map adds nothing; an unreadable one is its error.)
    $(LI `VORG` of another version: `unsupportedVersion`; a truncated one
        `truncated`.)
    $(LI No `VORG`, with `vmtx` and `glyf`: the glyph's top phantom point
        (FTO5), decoded into `ws` — the stored `yMax` (0 for a glyph without
        points) plus the top side bearing, moved by `gvar` at the instance —
        reported with source `vmtxGlyph`. This is HarfBuzz's origin.)
    $(LI Otherwise absent: nothing is synthesized.)
)

`gid ≥ numGlyphs` is `indexOutOfRange`, checked first. Costs
O(log n + r · a), or `phantomTop`'s on the phantom row.
*/
FontResult!VerticalOrigin verticalOrigin(in Instance inst, uint gid, scope ref PointWorkspace ws)
{
    const face = inst.face;
    if (gid >= face.numGlyphs)
        return fontErr!VerticalOrigin(FontError(FontErrorKind.indexOutOfRange, Tag("VORG")));
    VerticalOrigin r;
    const o = vorg(face);
    if (o.hasError)
    {
        if (o.error.kind != FontErrorKind.missingTable)
            return fontErr!VerticalOrigin(o.error);
        if (face.has(Tag("vmtx")) && face.has(Tag("glyf")))
        {
            // FTM21: the top phantom point, whose stored place reads the
            // glyph's vmtx entry.
            auto vm = vmtx(face);
            if (vm.hasError)
                return fontErr!VerticalOrigin(vm.error);
            const metric = vm.value.metric(gid);
            if (metric.hasError)
                return fontErr!VerticalOrigin(metric.error);
            const top = phantomTop(inst, gid, ws);
            if (top.hasError)
                return fontErr!VerticalOrigin(top.error);
            r.source = VerticalOriginSource.vmtxGlyph;
            r.y = measured(inst, top.value);
            return fontOk(r);
        }
        return fontOk(r);
    }
    const stored = o.value.originY(gid);
    r.source = stored.fromRecord ? VerticalOriginSource.vorgRecord : VerticalOriginSource.vorgDefault;
    auto value = DesignValue.fromUnits(stored.vertOriginY, inst.unitsPerEm);
    if (!inst.allZero)
    {
        const v = vvar(face, inst.axisCount);
        if (v.hasError && v.error.kind != FontErrorKind.missingTable)
            return fontErr!VerticalOrigin(v.error);
        if (v.hasValue && v.value.hasOriginMap)
        {
            const d = v.value.originDelta(gid, inst.coords, inst.unitsPerEm);
            if (d.hasError)
                return fontErr!VerticalOrigin(d.error);
            const sum = checkedAdd(value, d.value);
            if (sum.hasError)
                return fontErr!VerticalOrigin(sum.error);
            value = sum.value;
            r.varied = true;
        }
    }
    r.y = measured(inst, value);
    return fontOk(r);
}
