/**
Baselines and extents from `BASE` (`docs/specs/font/variation-metrics.md`
§ 6, FTM7, FTM11, FTM13, FTM22–FTM24).

The `BASE` view (`base`) reads the header and, from version 1.1, the item
variation store; its two axes are each optional. `baselineTags` is an axis's
tag list as a random-access range. `baseline` finds the requested script, or
else `DFLT`, by binary search and resolves the coordinate the baseline tag
indexes; `extents` resolves a language's (or the script's default) minimum
and maximum, refined by a feature. Every coordinate is a `BaseCoord`: its
stored value plus a VariationIndex delta as a `Measurement`, a format-2
reference point kept as data, and a Device table's whole-pixel delta kept
apart (FTM11).

Views are built per query, an O(1) header read; nothing is cached. At an
instance whose coordinates are all zero, no item variation store is read
(FTM14). Nothing here allocates.
*/
module sparkles.font.baseline;

import sparkles.font.bytes : be16, be32, bes16, fits;
import sparkles.font.errors : FontError, FontErrorKind, FontResult, fontErr, fontOk, Tag, tableError;
import sparkles.font.face : Face;
import sparkles.font.instance : Instance, InstanceSize;
import sparkles.font.metrics : Measurement, measured;
import sparkles.font.tables : locate, shortTable;
import sparkles.font.units : checkedAdd, DesignValue, Ppem;
import sparkles.font.variations : deviceDelta, DeviceDelta, ItemVariationStore;

@safe pure nothrow @nogc:

private enum baseTag = Tag("BASE");

/// Which `BASE` axis: the horizontal one holds baselines for horizontal text.
enum BaselineAxis : ubyte
{
    horizontal,
    vertical,
}

/// The index of `tag` among `count` records `stride` bytes apart from `at`, or -1 (binary search).
private ptrdiff_t searchTag(scope const(ubyte)[] data, ulong at, size_t count, size_t stride, Tag tag)
{
    size_t lo = 0, hi = count;
    while (lo < hi)
    {
        const mid = lo + (hi - lo) / 2;
        const value = be32(data, cast(size_t)(at + stride * mid));
        if (value == tag.value)
            return mid;
        if (value < tag.value)
            lo = mid + 1;
        else
            hi = mid;
    }
    return -1;
}

// ---------------------------------------------------------------------------
// The BASE view (FTM22)
// ---------------------------------------------------------------------------

/**
The `BASE` view: major version 1; minor 0 or 1, a later minor read as 1. The
item variation store offset exists from 1.1.
*/
struct Base
{
    @safe pure nothrow @nogc:

    private const(ubyte)[] data_;
    private ulong start_;
    private ushort major_, minor_;
    private ushort[2] axisOffsets_;
    private ItemVariationStore store_;

    /// The stored version.
    ushort majorVersion() const scope => major_;
    /// ditto
    ushort minorVersion() const scope => minor_;

    /// The item variation store, `present` only from version 1.1 with a non-null offset.
    ItemVariationStore variationStore() const return scope => store_;

    /**
    The axis `which`: not `present` when its offset is null. An offset past
    the table is `badOffset`, a header past it `truncated`. A malformed tag
    list or script list is recorded and returned by `tags` or `scripts`, so
    the other stays readable. Costs O(1).
    */
    FontResult!BaseAxis axis(BaselineAxis which) const return scope
    {
        const offset = axisOffsets_[which];
        BaseAxis a;
        if (offset == 0)
            return fontOk(a);
        const d = data_;
        const fieldAt = 4 + 2 * which;
        if (offset >= d.length)
            return fontErr!BaseAxis(tableError(FontErrorKind.badOffset, baseTag, start_, fieldAt));
        if (!fits(d.length, offset, 4))
            return fontErr!BaseAxis(tableError(FontErrorKind.truncated, baseTag, start_, offset));
        a.data_ = data_;
        a.start_ = start_;
        a.present_ = true;
        a.tags_ = BaseList.read(d, start_, offset, offset, 4);
        a.scripts_ = BaseList.read(d, start_, offset, offset + 2, 6);
        return fontOk(a);
    }
}

/**
The face's `BASE` view for a face of `fvarAxisCount` axes: `missingTable`
without one; `truncated` for a header past the table (8 bytes, 12 from
version 1.1); `unsupportedVersion` for a major version other than 1. A
malformed store is reported by the coordinates whose VariationIndex reads it.
Costs O(1).
*/
FontResult!Base base(return scope const Face face, ushort fvarAxisCount)
{
    auto at = locate(face, baseTag);
    if (at.hasError)
        return fontErr!Base(at.error);
    const d = at.value.data;
    if (d.length < 8)
        return shortTable!Base(baseTag, at.value, 8);
    Base b;
    b.data_ = d;
    b.start_ = at.value.start;
    b.major_ = be16(d, 0);
    b.minor_ = be16(d, 2);
    if (b.major_ != 1)
        return fontErr!Base(tableError(FontErrorKind.unsupportedVersion, baseTag, b.start_, 0));
    b.axisOffsets_[0] = be16(d, 4);
    b.axisOffsets_[1] = be16(d, 6);
    if (b.minor_ >= 1)
    {
        if (d.length < 12)
            return shortTable!Base(baseTag, at.value, 12);
        const storeOffset = be32(d, 8);
        if (storeOffset != 0)
            b.store_ = ItemVariationStore.read(d, baseTag, b.start_, storeOffset, fvarAxisCount);
    }
    return fontOk(b);
}

/// A counted array (`BaseTagList`, `BaseScriptList`) reached through an offset field.
private struct BaseList
{
    @safe pure nothrow @nogc:

    ulong at; // the first record
    ushort count;
    bool broken;
    FontError error;

    /**
    The list of `stride`-byte records the offset field at `fieldAt` points
    to, its offset from `parentAt`; a null offset is an empty list.
    */
    static BaseList read(scope const(ubyte)[] d, ulong start, ulong parentAt, ulong fieldAt, size_t stride)
    {
        BaseList l;
        const offset = be16(d, cast(size_t) fieldAt);
        if (offset == 0)
            return l;
        const listAt = parentAt + offset;
        if (listAt >= d.length)
            return l.fail(FontErrorKind.badOffset, start, fieldAt);
        if (!fits(d.length, listAt, 2))
            return l.fail(FontErrorKind.truncated, start, listAt);
        l.count = be16(d, cast(size_t) listAt);
        l.at = listAt + 2;
        if (!fits(d.length, l.at, ulong(stride) * l.count))
            return l.fail(FontErrorKind.truncated, start, l.at);
        return l;
    }

    private BaseList fail(FontErrorKind kind, ulong start, ulong relative)
    {
        broken = true;
        count = 0;
        error = tableError(kind, baseTag, start, relative);
        return this;
    }
}

/**
One `BASE` axis: its baseline tag list and its script list, each null (empty)
or readable on its own.
*/
struct BaseAxis
{
    @safe pure nothrow @nogc:

    private const(ubyte)[] data_;
    private ulong start_;
    private bool present_;
    private BaseList tags_, scripts_;

    /// Whether the table has this axis.
    bool present() const scope => present_;

    /// The baseline tag list (FTM22); empty when its offset is null, its error when it is malformed.
    FontResult!BaselineTags tags() const return scope
    {
        if (tags_.broken)
            return fontErr!BaselineTags(tags_.error);
        return fontOk(BaselineTags(data_, tags_.at, 0, tags_.count, present_));
    }

    /**
    The script records (FTM22, FTA11): each the script's tag, or `badOffset`
    for a record whose BaseScript offset is null or past the table while the
    others stay readable. A malformed list is its error.
    */
    FontResult!BaseScripts scripts() const return scope
    {
        if (scripts_.broken)
            return fontErr!BaseScripts(scripts_.error);
        return fontOk(BaseScripts(data_, start_, scripts_.at, 0, scripts_.count));
    }
}

/**
An axis's baseline tags as a random-access range of `Tag`, O(1) per element.
`axisPresent` is false, and the range empty, when the table has no such axis.
*/
struct BaselineTags
{
    @safe pure nothrow @nogc:

    private const(ubyte)[] data_;
    private ulong at_;
    private size_t begin_, end_;
    private bool axisPresent_;

    /// Whether the table has the axis.
    bool axisPresent() const scope => axisPresent_;

    bool empty() const scope => begin_ == end_;
    size_t length() const scope => end_ - begin_;

    Tag front() const scope
    in (!empty)
        => this[0];

    Tag back() const scope
    in (!empty)
        => this[length - 1];

    Tag opIndex(size_t i) const scope
    in (i < length)
        => Tag(be32(data_, cast(size_t)(at_ + 4 * (begin_ + i))));

    void popFront() scope
    in (!empty)
    {
        ++begin_;
    }

    void popBack() scope
    in (!empty)
    {
        --end_;
    }

    typeof(this) save() const return scope => this;
}

/// An axis's script records as a random-access range of `FontResult!Tag` (FTA11).
struct BaseScripts
{
    @safe pure nothrow @nogc:

    private const(ubyte)[] data_;
    private ulong start_, at_;
    private size_t begin_, end_;

    bool empty() const scope => begin_ == end_;
    size_t length() const scope => end_ - begin_;

    FontResult!Tag front() const scope
    in (!empty)
        => this[0];

    FontResult!Tag back() const scope
    in (!empty)
        => this[length - 1];

    /// The `i`th record's tag, or `badOffset` at its offset field.
    FontResult!Tag opIndex(size_t i) const scope
    in (i < length)
    {
        const recordAt = at_ + 6 * (begin_ + i);
        const listAt = at_ - 2;
        const offset = be16(data_, cast(size_t) recordAt + 4);
        if (offset == 0 || listAt + offset >= data_.length)
            return fontErr!Tag(tableError(FontErrorKind.badOffset, baseTag, start_, recordAt + 4));
        return fontOk(Tag(be32(data_, cast(size_t) recordAt)));
    }

    void popFront() scope
    in (!empty)
    {
        ++begin_;
    }

    void popBack() scope
    in (!empty)
    {
        --end_;
    }

    typeof(this) save() const return scope => this;
}

/**
The baseline tags of axis `axis` (FTM22): `missingTable` without `BASE`, the
header's error when it is unreadable, an empty range with `axisPresent` false
without the axis, and the tag list's error when it is malformed. Costs O(1).
*/
FontResult!BaselineTags baselineTags(return scope const Instance inst, BaselineAxis axis)
{
    const b = base(inst.face, inst.axisCount);
    if (b.hasError)
        return fontErr!BaselineTags(b.error);
    const a = b.value.axis(axis);
    if (a.hasError)
        return fontErr!BaselineTags(a.error);
    return a.value.tags;
}

// ---------------------------------------------------------------------------
// Coordinates (FTM23's coordinate rows, FTM11)
// ---------------------------------------------------------------------------

/**
One resolved BaseCoord. `coordinate` is the stored value plus, for format 3,
its VariationIndex delta; a Device table's whole-pixel delta stays in
`device` and only `pixels` adds it.
*/
struct BaseCoord
{
    @safe pure nothrow @nogc:

    /// The BaseCoord format: 1, 2 or 3.
    ushort format;
    /// The coordinate in design units, VariationIndex delta included.
    Measurement coordinate;
    /// Format 2: the reference glyph and its contour point.
    ushort referenceGlyph;
    /// ditto
    ushort pointIndex;
    /**
    Format 2: the point is not resolved, as that needs outlines (M3), so
    `coordinate` is the stored fallback.
    */
    bool unresolvedPoint;
    /// Format 3: whether a Device or VariationIndex table is attached.
    bool hasDevice;
    /// Format 3: that table's adjustment (FTM11); `device.variation` is already in `coordinate`.
    DeviceDelta device;

    /**
    The coordinate in fractional pixels at a pixel-sized instance, plus the
    Device table's delta when it applied at that (integer) ppem; errors as
    `Measurement.pixels`.
    */
    FontResult!double pixels() const scope
    {
        const p = coordinate.pixels;
        if (p.hasError || !device.deviceApplied)
            return p;
        return fontOk(p.value + device.devicePixels);
    }
}

/// The ppem a Device table applies at for `inst`: its integer ppem when sized in pixels, otherwise none.
private Ppem devicePpem(in Instance inst)
    => inst.size.unit == InstanceSize.Unit.pixels ? inst.size.ppem : Ppem.init;

/**
The BaseCoord the offset field at `fieldAt` points to, at `coordAt`: an
offset past the table is `badOffset` at the field; a coordinate of format 1,
2 or 3 is resolved, another format is `unsupportedVersion`.
*/
private FontResult!BaseCoord resolveCoord(scope const ref Base b, ulong fieldAt, ulong coordAt, in Instance inst)
{
    const d = b.data_;
    if (coordAt >= d.length)
        return fontErr!BaseCoord(tableError(FontErrorKind.badOffset, baseTag, b.start_, fieldAt));
    if (!fits(d.length, coordAt, 4))
        return fontErr!BaseCoord(tableError(FontErrorKind.truncated, baseTag, b.start_, coordAt));
    const p = cast(size_t) coordAt;
    BaseCoord c;
    c.format = be16(d, p);
    auto value = DesignValue.fromUnits(bes16(d, p + 2), inst.unitsPerEm);
    switch (c.format)
    {
        case 1:
            break;
        case 2:
            if (!fits(d.length, coordAt, 8))
                return fontErr!BaseCoord(tableError(FontErrorKind.truncated, baseTag, b.start_, coordAt));
            c.referenceGlyph = be16(d, p + 4);
            c.pointIndex = be16(d, p + 6);
            c.unresolvedPoint = true;
            break;
        case 3:
            if (!fits(d.length, coordAt, 6))
                return fontErr!BaseCoord(tableError(FontErrorKind.truncated, baseTag, b.start_, coordAt));
            const deviceOffset = be16(d, p + 4);
            if (deviceOffset == 0)
                break;
            const dd = deviceDelta(d, baseTag, b.start_, coordAt + deviceOffset, b.store_, inst.coords,
                inst.unitsPerEm, devicePpem(inst));
            if (dd.hasError)
                return fontErr!BaseCoord(dd.error);
            c.hasDevice = true;
            c.device = dd.value;
            const sum = checkedAdd(value, dd.value.variation);
            if (sum.hasError)
                return fontErr!BaseCoord(sum.error);
            value = sum.value;
            break;
        default:
            return fontErr!BaseCoord(tableError(FontErrorKind.unsupportedVersion, baseTag, b.start_, coordAt));
    }
    c.coordinate = measured(inst, value);
    return fontOk(c);
}

// ---------------------------------------------------------------------------
// Script lookup (FTM23)
// ---------------------------------------------------------------------------

/// Which script record answered a query (FTM23).
enum ScriptSource : ubyte
{
    /// Neither the script nor `DFLT` has a record.
    none,
    /// The requested script's record.
    requested,
    /// The `DFLT` script's record, as the requested script has none.
    defaultScript,
}

/// The BaseScript a query reads: its source, and its header's position.
private struct FoundScript
{
    ScriptSource source;
    ulong at; // the BaseScript table
    ushort valuesOffset, defaultMinMaxOffset, langSysCount;
}

/// The axis `which` and its script `script`, else `DFLT`; `none` when either is missing.
private FontResult!FoundScript findScript(scope const ref Base b, BaselineAxis which, Tag script)
{
    FoundScript f;
    const a = b.axis(which);
    if (a.hasError)
        return fontErr!FoundScript(a.error);
    if (!a.value.present)
        return fontOk(f);
    const list = a.value.scripts_;
    if (list.broken)
        return fontErr!FoundScript(list.error);
    const d = b.data_;
    auto i = searchTag(d, list.at, list.count, 6, script);
    f.source = ScriptSource.requested;
    if (i < 0)
    {
        i = searchTag(d, list.at, list.count, 6, Tag("DFLT"));
        f.source = ScriptSource.defaultScript;
    }
    if (i < 0)
        return fontOk(FoundScript.init);
    const fieldAt = list.at + 6 * i + 4;
    const offset = be16(d, cast(size_t) fieldAt);
    f.at = list.at - 2 + offset;
    if (offset == 0 || f.at >= d.length)
        return fontErr!FoundScript(tableError(FontErrorKind.badOffset, baseTag, b.start_, fieldAt));
    if (!fits(d.length, f.at, 6))
        return fontErr!FoundScript(tableError(FontErrorKind.truncated, baseTag, b.start_, f.at));
    const p = cast(size_t) f.at;
    f.valuesOffset = be16(d, p);
    f.defaultMinMaxOffset = be16(d, p + 2);
    f.langSysCount = be16(d, p + 4);
    if (!fits(d.length, f.at + 6, 6UL * f.langSysCount))
        return fontErr!FoundScript(tableError(FontErrorKind.truncated, baseTag, b.start_, f.at + 6));
    return fontOk(f);
}

// ---------------------------------------------------------------------------
// baseline (FTM23)
// ---------------------------------------------------------------------------

/**
A baseline (FTM23). `script` says which script record answered, even when no
coordinate was found; `present` says whether one was. `defaultIndex` is the
BaseValues' default baseline index, reported when `hasBaseValues` and never
used to answer another tag.
*/
struct Baseline
{
    ScriptSource script;
    bool hasBaseValues;
    /// `BaseValues.defaultBaselineIndex`: an index into the axis's tag list.
    ushort defaultIndex;
    bool present;
    BaseCoord value;
}

/**
The baseline `tag` of `script` on axis `axis` at `inst` (FTM23). The script
is found by binary search, else `DFLT`; the language does not select
baselines. In FTM23's order:

$(UL
    $(LI no `BASE`: `missingTable`;)
    $(LI no such axis, neither the script nor `DFLT` with a record, a script
        record without BaseValues, or `tag` not in the axis's tag list: absent;)
    $(LI the tag's index past the BaseValues coordinate count: `badValue`;)
    $(LI otherwise the BaseCoord: format 1 its coordinate; format 2 its
        coordinate, reference glyph and point index with `unresolvedPoint`;
        format 3 its coordinate plus its VariationIndex delta (read from
        `BASE`'s own store), with a Device table's delta kept in `device`;
        another format `unsupportedVersion`.)
)

A Device table applies only at an instance sized in pixels at an integer
ppem inside its range (FTM11). A script record whose offset lies outside the
table is `badOffset`; truncated structures are `truncated`. A zero coordinate
is a value. Costs O(log s + log t + r · a).
*/
FontResult!Baseline baseline(in Instance inst, BaselineAxis axis, Tag script, Tag tag)
{
    const b = base(inst.face, inst.axisCount);
    if (b.hasError)
        return fontErr!Baseline(b.error);
    const view = b.value;
    const found = findScript(view, axis, script);
    if (found.hasError)
        return fontErr!Baseline(found.error);
    const f = found.value;
    Baseline r;
    r.script = f.source;
    if (f.source == ScriptSource.none || f.valuesOffset == 0)
        return fontOk(r);

    const d = view.data_;
    const start = view.start_;
    const valuesAt = f.at + f.valuesOffset;
    if (valuesAt >= d.length)
        return fontErr!Baseline(tableError(FontErrorKind.badOffset, baseTag, start, f.at));
    if (!fits(d.length, valuesAt, 4))
        return fontErr!Baseline(tableError(FontErrorKind.truncated, baseTag, start, valuesAt));
    r.hasBaseValues = true;
    r.defaultIndex = be16(d, cast(size_t) valuesAt);
    const coordCount = be16(d, cast(size_t) valuesAt + 2);
    if (!fits(d.length, valuesAt + 4, 2UL * coordCount))
        return fontErr!Baseline(tableError(FontErrorKind.truncated, baseTag, start, valuesAt + 4));

    const tags = view.axis(axis).value.tags_;
    if (tags.broken)
        return fontErr!Baseline(tags.error);
    const index = searchTag(d, tags.at, tags.count, 4, tag);
    if (index < 0)
        return fontOk(r);
    if (index >= coordCount)
        return fontErr!Baseline(tableError(FontErrorKind.badValue, baseTag, start, valuesAt + 2));
    const fieldAt = valuesAt + 4 + 2 * index;
    const offset = be16(d, cast(size_t) fieldAt);
    if (offset == 0)
        return fontErr!Baseline(tableError(FontErrorKind.badOffset, baseTag, start, fieldAt));
    const c = resolveCoord(view, fieldAt, valuesAt + offset, inst);
    if (c.hasError)
        return fontErr!Baseline(c.error);
    r.present = true;
    r.value = c.value;
    return fontOk(r);
}

// ---------------------------------------------------------------------------
// extents (FTM24)
// ---------------------------------------------------------------------------

/// One extent of a MinMax record: absent (a null offset), a coordinate, or that value's error.
struct Extent
{
    @safe pure nothrow @nogc:

    private enum State : ubyte { absent, value, error }

    private State state_;
    private BaseCoord value_;
    private FontError error_;

    /// Whether the offset was null: no value, never zero.
    bool absent() const scope => state_ == State.absent;
    /// Whether the coordinate resolved.
    bool hasValue() const scope => state_ == State.value;
    /// Whether the coordinate is malformed.
    bool hasError() const scope => state_ == State.error;

    /// The coordinate, when `hasValue`.
    BaseCoord value() const scope
    in (hasValue)
        => value_;

    /// The coordinate's error, when `hasError`.
    FontError error() const scope
    in (hasError)
        => error_;
}

/// Which MinMax record extents came from (FTM24); `none` is absent.
enum MinMaxSource : ubyte
{
    none,
    /// The language's own MinMax record.
    language,
    /// The script's default MinMax.
    scriptDefault,
}

/**
Extents (FTM24): a minimum and a maximum, the script and MinMax record that
supplied them, and whether a feature's record refined them.
*/
struct Extents
{
    @safe pure nothrow @nogc:

    ScriptSource script;
    MinMaxSource record;
    /// Whether the requested feature had a FeatMinMax record.
    bool fromFeature;
    Extent min, max;

    /// Whether a MinMax record was found.
    bool present() const scope => record != MinMaxSource.none;
}

/**
The extents of `script`, `language` and `feature` on axis `axis` at `inst`
(FTM24). The script is found as in `baseline` (with its errors and
absences); then the language's MinMax record by binary search, else the
script's default MinMax (absent when null); then within the record the
feature's FeatMinMax record by binary search, else the record's own minimum
and maximum. A language record with a null MinMax offset has both values
absent. A null minimum or maximum offset leaves that value absent, never zero;
an offset outside the table is `badOffset` for that value, and each value is
resolved by FTM23's coordinate rows on its own. A MinMax offset outside the
table, or a truncated MinMax, is the query's error. Pass `Tag.init` for no
language or feature. Costs O(log s + log l + log f + r · a).
*/
FontResult!Extents extents(in Instance inst, BaselineAxis axis, Tag script, Tag language, Tag feature)
{
    const b = base(inst.face, inst.axisCount);
    if (b.hasError)
        return fontErr!Extents(b.error);
    const view = b.value;
    const found = findScript(view, axis, script);
    if (found.hasError)
        return fontErr!Extents(found.error);
    const f = found.value;
    Extents r;
    r.script = f.source;
    if (f.source == ScriptSource.none)
        return fontOk(r);

    const d = view.data_;
    const start = view.start_;
    ulong fieldAt;
    ushort offset;
    const lang = searchTag(d, f.at + 6, f.langSysCount, 6, language);
    if (lang >= 0)
    {
        r.record = MinMaxSource.language;
        fieldAt = f.at + 6 + 6 * lang + 4;
        offset = be16(d, cast(size_t) fieldAt);
    }
    else if (f.defaultMinMaxOffset != 0)
    {
        r.record = MinMaxSource.scriptDefault;
        fieldAt = f.at + 2;
        offset = f.defaultMinMaxOffset;
    }
    if (r.record == MinMaxSource.none || offset == 0)
        return fontOk(r);

    const minMaxAt = f.at + offset;
    if (minMaxAt >= d.length)
        return fontErr!Extents(tableError(FontErrorKind.badOffset, baseTag, start, fieldAt));
    if (!fits(d.length, minMaxAt, 6))
        return fontErr!Extents(tableError(FontErrorKind.truncated, baseTag, start, minMaxAt));
    const m = cast(size_t) minMaxAt;
    const featureCount = be16(d, m + 4);
    if (!fits(d.length, minMaxAt + 6, 8UL * featureCount))
        return fontErr!Extents(tableError(FontErrorKind.truncated, baseTag, start, minMaxAt + 6));
    ulong minField = minMaxAt, maxField = minMaxAt + 2;
    const feat = searchTag(d, minMaxAt + 6, featureCount, 8, feature);
    if (feat >= 0)
    {
        r.fromFeature = true;
        minField = minMaxAt + 6 + 8 * feat + 4;
        maxField = minField + 2;
    }
    r.min = extent(view, minField, minMaxAt, inst);
    r.max = extent(view, maxField, minMaxAt, inst);
    return fontOk(r);
}

/// The extent the offset field at `fieldAt` (from the MinMax at `minMaxAt`) points to.
private Extent extent(scope const ref Base b, ulong fieldAt, ulong minMaxAt, in Instance inst)
{
    Extent e;
    const offset = be16(b.data_, cast(size_t) fieldAt);
    if (offset == 0)
        return e;
    const c = resolveCoord(b, fieldAt, minMaxAt + offset, inst);
    if (c.hasError)
    {
        e.state_ = Extent.State.error;
        e.error_ = c.error;
    }
    else
    {
        e.state_ = Extent.State.value;
        e.value_ = c.value;
    }
    return e;
}
