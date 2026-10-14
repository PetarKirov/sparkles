/**
Math data from `MATH` (`docs/specs/font/variation-metrics.md` § 7, FTP34–FTP38,
FTM11–FTM14; `SPEC.md` FTP13).

The module is `math_table`, not `math`, so that it never reads as Phobos's
`std.math` in an import list.

`mathConstants` reads the 56 constants, each its own result (FTA11):
percentages as signed integers, never scaled; the two minimum heights as
design values without a device table; the 51 MathValueRecords as design
values with their VariationIndex delta (resolved against `GDEF`'s item
variation store) and a Device table's whole-pixel delta kept apart, as
`baseline` does. `italicsCorrection`, `topAccentAttachment`,
`isExtendedShape` and `mathKern` find a glyph by its coverage; `mathVariants`,
`mathAssemblyLength` and `mathAssembly` read its vertical or horizontal
construction. Nothing is invented: a glyph without a record is absent, a
stored zero is a value, and the library never composes an assembly.

Views are built per query, an O(1) header read; nothing is cached. At an
instance whose coordinates are all zero no item variation store is read
(FTM14). Nothing here allocates or asserts on font data.
*/
module sparkles.font.math_table;

import sparkles.font.bytes : be16, bes16, fits;
import sparkles.font.coverage : Coverage;
import sparkles.font.errors : callerStorageError, FontError, FontErrorKind, FontResult, fontErr, fontOk, Tag,
    tableError;
import sparkles.font.face : Face;
import sparkles.font.gdef : gdefVariationStore;
import sparkles.font.instance : Instance, InstanceSize;
import sparkles.font.metrics : Measurement, measured;
import sparkles.font.tables : locate, shortTable;
import sparkles.font.units : checkedAdd, DesignValue, Ppem;
import sparkles.font.variations : deviceDelta, DeviceDelta, ItemVariationStore;

@safe pure nothrow @nogc:

private enum mathTag = Tag("MATH");

// ---------------------------------------------------------------------------
// The MATH header (FTP34)
// ---------------------------------------------------------------------------

/**
The `MATH` header: major version 1 (any minor), and the offsets of its three
subtables, each optional.
*/
struct MathTable
{
    @safe pure nothrow @nogc:

    private const(ubyte)[] data_;
    private ulong start_;
    private ushort major_, minor_;

    /// The stored version.
    ushort majorVersion() const scope => major_;
    /// ditto
    ushort minorVersion() const scope => minor_;

    private FontError error(FontErrorKind kind, ulong relative) const scope
        => tableError(kind, mathTag, start_, relative);
}

/**
The face's `MATH` header (FTP34): `missingTable` without one; `truncated`
for a header past the table (10 bytes); `unsupportedVersion` for a major
version other than 1. Every query below returns these errors. Costs O(1).
*/
FontResult!MathTable mathTable(return scope const Face face)
{
    auto at = locate(face, mathTag);
    if (at.hasError)
        return fontErr!MathTable(at.error);
    const d = at.value.data;
    if (d.length < 4)
        return shortTable!MathTable(mathTag, at.value, 10);
    MathTable m;
    m.data_ = d;
    m.start_ = at.value.start;
    m.major_ = be16(d, 0);
    m.minor_ = be16(d, 2);
    if (m.major_ != 1)
        return fontErr!MathTable(m.error(FontErrorKind.unsupportedVersion, 0));
    if (d.length < 10)
        return shortTable!MathTable(mathTag, at.value, 10);
    return fontOk(m);
}

/// A subtable reached through an offset field: absent when the offset is null.
private struct Child
{
    bool present;
    ulong at;
}

/**
The subtable the 16-bit offset field at `fieldAt` points to, from `parentAt`:
absent for a null offset, `badOffset` (at the field) past the table,
`truncated` when its first `needed` bytes are.
*/
private FontResult!Child child(scope const ref MathTable m, ulong parentAt, ulong fieldAt, ulong needed)
{
    if (!fits(m.data_.length, fieldAt, 2))
        return fontErr!Child(m.error(FontErrorKind.truncated, fieldAt));
    const offset = be16(m.data_, cast(size_t) fieldAt);
    if (offset == 0)
        return fontOk(Child.init);
    const at = parentAt + offset;
    if (at >= m.data_.length)
        return fontErr!Child(m.error(FontErrorKind.badOffset, fieldAt));
    if (!fits(m.data_.length, at, needed))
        return fontErr!Child(m.error(FontErrorKind.truncated, at));
    return fontOk(Child(true, at));
}

/// The `MATH` subtable whose offset is the header's field `field` (0 constants, 1 glyph info, 2 variants).
private FontResult!Child top(scope const ref MathTable m, uint field, ulong needed)
    => child(m, 0, 4 + 2 * field, needed);

/// The item variation store `MATH` reads (FTM11): `GDEF`'s, never read at the default (FTM14).
private ItemVariationStore mathStore(return scope const ref Instance inst)
    => inst.allZero ? ItemVariationStore.init : gdefVariationStore(inst.face, inst.axisCount);

/// The ppem a Device table applies at for `inst`: its ppem when sized in pixels, otherwise none.
private Ppem devicePpem(in Instance inst)
    => inst.size.unit == InstanceSize.Unit.pixels ? inst.size.ppem : Ppem.init;

// ---------------------------------------------------------------------------
// Values (FTM11, FTM12)
// ---------------------------------------------------------------------------

/// What a math value is, in its native unit (FTP13).
enum MathValueKind : ubyte
{
    /// A signed integer percentage, never scaled.
    percentage,
    /// A design value with no device table: the two minimum heights.
    length,
    /// A MathValueRecord: a design value with an optional Device or VariationIndex table.
    record,
}

/**
One math value. `present` is false when the font has no record for the
request (FTM12); a stored zero is present. A `percentage` is in
`percentage`; the other kinds in `value`, which includes a VariationIndex
delta, while a Device table's whole-pixel delta stays in `device` and only
`pixels` adds it (FTM11).
*/
struct MathValue
{
    @safe pure nothrow @nogc:

    /// Whether there is a value at all.
    bool present;
    MathValueKind kind;
    /// The percentage, for `MathValueKind.percentage`.
    short percentage;
    /// The value in design units, VariationIndex delta included.
    Measurement value;
    /// Whether a MathValueRecord has a Device or VariationIndex table.
    bool hasDevice;
    /// That table's adjustment; `device.variation` is already in `value`.
    DeviceDelta device;

    /**
    The value in fractional pixels at a pixel-sized instance, plus the
    Device table's delta when it applied at that (integer) ppem; errors as
    `Measurement.pixels`. A percentage is no length: `unsupportedCapability`.
    */
    FontResult!double pixels() const scope
    {
        if (kind == MathValueKind.percentage)
            return fontErr!double(FontError(FontErrorKind.unsupportedCapability));
        const p = value.pixels;
        if (p.hasError || !device.deviceApplied)
            return p;
        return fontOk(p.value + device.devicePixels);
    }
}

/**
The MathValueRecord at `recordAt`, its device offset from `parentAt`,
resolved at `inst` with `store`; a Device table applies at `ppem` only.
*/
private FontResult!MathValue record(scope const ref MathTable m, ulong recordAt, ulong parentAt,
    in Instance inst, scope const ref ItemVariationStore store, Ppem ppem)
{
    const d = m.data_;
    if (!fits(d.length, recordAt, 4))
        return fontErr!MathValue(m.error(FontErrorKind.truncated, recordAt));
    const p = cast(size_t) recordAt;
    MathValue v;
    v.present = true;
    v.kind = MathValueKind.record;
    auto value = DesignValue.fromUnits(bes16(d, p), inst.unitsPerEm);
    const deviceOffset = be16(d, p + 2);
    if (deviceOffset != 0)
    {
        const dd = deviceDelta(d, mathTag, m.start_, parentAt + deviceOffset, store, inst.coords,
            inst.unitsPerEm, ppem);
        if (dd.hasError)
            return fontErr!MathValue(dd.error);
        v.hasDevice = true;
        v.device = dd.value;
        const sum = checkedAdd(value, dd.value.variation);
        if (sum.hasError)
            return fontErr!MathValue(sum.error);
        value = sum.value;
    }
    v.value = measured(inst, value);
    return fontOk(v);
}

// ---------------------------------------------------------------------------
// Constants (FTP35)
// ---------------------------------------------------------------------------

/// The 56 math constants, in `MathConstants` table order (HarfBuzz's `hb_ot_math_constant_t`).
enum MathConstant : ubyte
{
    scriptPercentScaleDown,
    scriptScriptPercentScaleDown,
    delimitedSubFormulaMinHeight,
    displayOperatorMinHeight,
    mathLeading,
    axisHeight,
    accentBaseHeight,
    flattenedAccentBaseHeight,
    subscriptShiftDown,
    subscriptTopMax,
    subscriptBaselineDropMin,
    superscriptShiftUp,
    superscriptShiftUpCramped,
    superscriptBottomMin,
    superscriptBaselineDropMax,
    subSuperscriptGapMin,
    superscriptBottomMaxWithSubscript,
    spaceAfterScript,
    upperLimitGapMin,
    upperLimitBaselineRiseMin,
    lowerLimitGapMin,
    lowerLimitBaselineDropMin,
    stackTopShiftUp,
    stackTopDisplayStyleShiftUp,
    stackBottomShiftDown,
    stackBottomDisplayStyleShiftDown,
    stackGapMin,
    stackDisplayStyleGapMin,
    stretchStackTopShiftUp,
    stretchStackBottomShiftDown,
    stretchStackGapAboveMin,
    stretchStackGapBelowMin,
    fractionNumeratorShiftUp,
    fractionNumeratorDisplayStyleShiftUp,
    fractionDenominatorShiftDown,
    fractionDenominatorDisplayStyleShiftDown,
    fractionNumeratorGapMin,
    fractionNumDisplayStyleGapMin,
    fractionRuleThickness,
    fractionDenominatorGapMin,
    fractionDenomDisplayStyleGapMin,
    skewedFractionHorizontalGap,
    skewedFractionVerticalGap,
    overbarVerticalGap,
    overbarRuleThickness,
    overbarExtraAscender,
    underbarVerticalGap,
    underbarRuleThickness,
    underbarExtraDescender,
    radicalVerticalGap,
    radicalDisplayStyleVerticalGap,
    radicalRuleThickness,
    radicalExtraAscender,
    radicalKernBeforeDegree,
    radicalKernAfterDegree,
    radicalDegreeBottomRaisePercent,
}

/// The number of math constants.
enum size_t mathConstantCount = MathConstant.max + 1;

static assert(mathConstantCount == 56);

/// The native kind of constant `c` (FTP35).
MathValueKind kindOf(MathConstant c)
{
    if (c <= MathConstant.scriptScriptPercentScaleDown || c == MathConstant.radicalDegreeBottomRaisePercent)
        return MathValueKind.percentage;
    if (c <= MathConstant.displayOperatorMinHeight)
        return MathValueKind.length;
    return MathValueKind.record;
}

/// The byte offset of constant `c` in the MathConstants table: 2 bytes each before the records, 4 each in them.
private uint constantOffset(MathConstant c)
    => c < MathConstant.mathLeading ? 2 * c : 8 + 4 * (c - MathConstant.mathLeading);

///
@("math.kindOf")
unittest
{
    assert(kindOf(MathConstant.scriptPercentScaleDown) == MathValueKind.percentage);
    assert(kindOf(MathConstant.displayOperatorMinHeight) == MathValueKind.length);
    assert(kindOf(MathConstant.axisHeight) == MathValueKind.record);
    assert(kindOf(MathConstant.radicalDegreeBottomRaisePercent) == MathValueKind.percentage);
    assert(constantOffset(MathConstant.radicalDegreeBottomRaisePercent) == 212);
}

/**
The math constants at an instance (FTP35), indexed by `MathConstant`. Each
constant is its own result, so one malformed constant leaves the others
readable (FTA11). `present` is false when `MATH` has no MathConstants table;
every constant is then absent.
*/
struct MathConstants
{
    @safe pure nothrow @nogc:

    private MathTable table_;
    private ulong at_;
    private bool present_;
    private Instance inst_;

    /// Whether `MATH` has a MathConstants table.
    bool present() const scope => present_;

    /**
    Constant `c`: a percentage as stored; a minimum height as its unsigned
    design value; a MathValueRecord with its VariationIndex delta, read from
    `GDEF`'s store (`badValue` without one, at nonzero coordinates), and its
    Device table's delta, applied by `MathValue.pixels` only at a pixel-sized
    instance at an integer ppem inside the table's range. Another delta
    format is `unsupportedVersion`, a device offset outside the table
    `badOffset`, and a constant past the end of a short table `truncated`.
    Costs O(1) plus the constant's variation delta.
    */
    FontResult!MathValue opIndex(MathConstant c) const scope
    {
        if (!present_)
            return fontOk(MathValue.init);
        const kind = kindOf(c);
        const fieldAt = at_ + constantOffset(c);
        const d = table_.data_;
        if (!fits(d.length, fieldAt, kind == MathValueKind.record ? 4 : 2))
            return fontErr!MathValue(table_.error(FontErrorKind.truncated, fieldAt));
        const p = cast(size_t) fieldAt;
        MathValue v;
        v.present = true;
        v.kind = kind;
        final switch (kind)
        {
            case MathValueKind.percentage:
                v.percentage = bes16(d, p);
                return fontOk(v);
            case MathValueKind.length:
                v.value = measured(inst_, DesignValue.fromUnits(be16(d, p), inst_.unitsPerEm));
                return fontOk(v);
            case MathValueKind.record:
                const store = mathStore(inst_);
                return record(table_, fieldAt, at_, inst_, store, devicePpem(inst_));
        }
    }
}

/**
The math constants of `inst` (FTP35): `mathTable`'s errors; a MathConstants
offset outside the table is `badOffset`. Costs O(1); each constant is
resolved when indexed.
*/
FontResult!MathConstants mathConstants(return scope const Instance inst)
{
    const m = mathTable(inst.face);
    if (m.hasError)
        return fontErr!MathConstants(m.error);
    const c = top(m.value, 0, 0);
    if (c.hasError)
        return fontErr!MathConstants(c.error);
    MathConstants r;
    r.table_ = m.value;
    r.at_ = c.value.at;
    r.present_ = c.value.present;
    r.inst_ = inst;
    return fontOk(r);
}

// ---------------------------------------------------------------------------
// Glyph information (FTP36)
// ---------------------------------------------------------------------------

/// The MathGlyphInfo subtables, in header order.
private enum GlyphInfoPart : uint
{
    italicsCorrection,
    topAccentAttachment,
    extendedShapeCoverage,
    kernInfo,
}

/// The MathGlyphInfo subtable `part`: absent when MathGlyphInfo or the subtable is.
private FontResult!Child glyphInfoPart(scope const ref MathTable m, GlyphInfoPart part, ulong needed)
{
    const info = top(m, 1, 8);
    if (info.hasError || !info.value.present)
        return info;
    return child(m, info.value.at, info.value.at + 2 * part, needed);
}

/// The coverage index of `gid` in the Coverage the field at `fieldAt` points to (from `parentAt`).
private FontResult!long coverageIndex(scope const ref MathTable m, ulong parentAt, ulong fieldAt, uint gid)
{
    const offset = be16(m.data_, cast(size_t) fieldAt);
    if (offset == 0)
        return fontOk(-1L);
    const cov = Coverage.read(m.data_, mathTag, m.start_, parentAt + offset);
    const i = cov.index(gid);
    if (i.hasError)
        return fontErr!long(i.error);
    return fontOk(i.value.covered ? long(i.value.index) : -1L);
}

/// A MathItalicsCorrectionInfo or MathTopAccentAttachment lookup (FTP36's first two rows).
private FontResult!MathValue glyphValue(in Instance inst, uint gid, GlyphInfoPart part)
{
    const m = mathTable(inst.face);
    if (m.hasError)
        return fontErr!MathValue(m.error);
    const view = m.value;
    const sub = glyphInfoPart(view, part, 4);
    if (sub.hasError)
        return fontErr!MathValue(sub.error);
    if (!sub.value.present)
        return fontOk(MathValue.init);
    const at = sub.value.at;
    const index = coverageIndex(view, at, at, gid);
    if (index.hasError)
        return fontErr!MathValue(index.error);
    if (index.value < 0)
        return fontOk(MathValue.init);
    if (index.value >= be16(view.data_, cast(size_t) at + 2))
        return fontErr!MathValue(view.error(FontErrorKind.badValue, at + 2));
    const store = mathStore(inst);
    return record(view, at + 4 + 4 * index.value, at, inst, store, devicePpem(inst));
}

/**
The italics correction of glyph `gid` at `inst` (FTP36): absent when the
glyph is not covered or the font has no MathItalicsCorrectionInfo; `badValue`
when its coverage index is past the value array; otherwise its
MathValueRecord, resolved as a constant's is. Costs O(log n) plus the
variation delta.
*/
FontResult!MathValue italicsCorrection(in Instance inst, uint gid)
    => glyphValue(inst, gid, GlyphInfoPart.italicsCorrection);

/**
The top accent attachment of glyph `gid` at `inst` (FTP36), with
`italicsCorrection`'s rows. An uncovered glyph is absent, never half its
advance. Costs O(log n) plus the variation delta.
*/
FontResult!MathValue topAccentAttachment(in Instance inst, uint gid)
    => glyphValue(inst, gid, GlyphInfoPart.topAccentAttachment);

/**
Whether glyph `gid` is an extended shape (FTP36): covered by the extended
shape coverage; `false` without one. A malformed coverage is its error.
Costs O(log n).
*/
FontResult!bool isExtendedShape(in Instance inst, uint gid)
{
    const m = mathTable(inst.face);
    if (m.hasError)
        return fontErr!bool(m.error);
    const view = m.value;
    const info = top(view, 1, 8);
    if (info.hasError)
        return fontErr!bool(info.error);
    if (!info.value.present)
        return fontOk(false);
    const index = coverageIndex(view, info.value.at, info.value.at + 4, gid);
    if (index.hasError)
        return fontErr!bool(index.error);
    return fontOk(index.value >= 0);
}

// ---------------------------------------------------------------------------
// Math kerns (FTP36, FTP37)
// ---------------------------------------------------------------------------

/// A glyph corner a math kern applies to, in MathKernInfoRecord order.
enum MathKernCorner : ubyte
{
    topRight,
    topLeft,
    bottomRight,
    bottomLeft,
}

/**
One corner's MathKern: `heightCount` correction heights and one more kern
value, each a MathValueRecord. `present` is false when the glyph has no kern
at that corner (FTP36). Heights are kept in stored order; `heightsAscending`
reports whether they are sorted.
*/
struct MathKernTable
{
    @safe pure nothrow @nogc:

    private MathTable table_;
    private ulong at_;
    private ushort count_;
    private bool present_;
    private Instance inst_;

    /// Whether the glyph has a kern at this corner.
    bool present() const scope => present_;

    /// The number of correction heights; there is one more kern value.
    ushort heightCount() const scope => count_;

    /**
    Correction height `i` at the instance, as a MathValueRecord whose Device
    table only `MathValue.pixels` applies. Costs O(r · a).
    */
    FontResult!MathValue height(size_t i) const scope
    in (i < count_)
        => resolve(i, devicePpem(inst_));

    /// Kern value `i` (`0 .. heightCount + 1`), resolved like `height`.
    FontResult!MathValue value(size_t i) const scope
    in (i <= count_)
        => resolve(count_ + i, devicePpem(inst_));

    private FontResult!MathValue resolve(size_t i, Ppem ppem) const scope
    {
        const store = mathStore(inst_);
        return record(table_, at_ + 2 + 4 * i, at_, inst_, store, ppem);
    }

    /**
    Whether the correction heights, resolved at the instance with their
    variation deltas and no device delta, never decrease in stored order: an
    inspection result, as `lookup` does not reorder them (FTP37). The first
    height that fails is the error. Costs O(n · r · a).
    */
    FontResult!bool heightsAscending() const scope
    {
        long previous = long.min;
        foreach (i; 0 .. count_)
        {
            const h = resolve(i, Ppem.init);
            if (h.hasError)
                return fontErr!bool(h.error);
            if (h.value.value.design.raw < previous)
                return fontOk(false);
            previous = h.value.value.design.raw;
        }
        return fontOk(true);
    }

    /**
    The kern value for correction height `h` (FTP37): the value at index `k`,
    the position of the first height, in stored order, that is greater than
    `h`, or `heightCount` when none is. A height equal to `h` selects the
    value above it. Heights are resolved at the instance with their variation
    deltas and without device deltas, so a ppem never changes the step, and
    only until one is greater than `h`; the first error met is the result.
    `h` must be in the face's units per em, else `badValue`. An absent table
    gives an absent value. Costs O(n · r · a).
    */
    FontResult!MathValue lookup(DesignValue h) const scope
    {
        if (!present_)
            return fontOk(MathValue.init);
        if (h.unitsPerEm != inst_.unitsPerEm)
            return fontErr!MathValue(FontError(FontErrorKind.badValue));
        size_t k = count_;
        foreach (i; 0 .. count_)
        {
            const height = resolve(i, Ppem.init);
            if (height.hasError)
                return fontErr!MathValue(height.error);
            if (height.value.value.design.raw > h.raw)
            {
                k = i;
                break;
            }
        }
        return value(k);
    }
}

/**
The math kern of glyph `gid` at corner `corner` (FTP36): absent (`present`
false) when the glyph is not covered, the font has no MathKernInfo, or the
corner's offset is null; `badValue` when the coverage index is past the
MathKernInfoRecord array; `truncated` for a record or MathKern past the
table. Costs O(log n).
*/
FontResult!MathKernTable mathKernTable(return scope const Instance inst, uint gid, MathKernCorner corner)
{
    const m = mathTable(inst.face);
    if (m.hasError)
        return fontErr!MathKernTable(m.error);
    const view = m.value;
    MathKernTable r;
    r.table_ = view;
    r.inst_ = inst;
    const sub = glyphInfoPart(view, GlyphInfoPart.kernInfo, 4);
    if (sub.hasError)
        return fontErr!MathKernTable(sub.error);
    if (!sub.value.present)
        return fontOk(r);
    const at = sub.value.at;
    const index = coverageIndex(view, at, at, gid);
    if (index.hasError)
        return fontErr!MathKernTable(index.error);
    if (index.value < 0)
        return fontOk(r);
    if (index.value >= be16(view.data_, cast(size_t) at + 2))
        return fontErr!MathKernTable(view.error(FontErrorKind.badValue, at + 2));
    const recordAt = at + 4 + 8 * index.value;
    if (!fits(view.data_.length, recordAt, 8))
        return fontErr!MathKernTable(view.error(FontErrorKind.truncated, recordAt));
    const kern = child(view, at, recordAt + 2 * corner, 2);
    if (kern.hasError)
        return fontErr!MathKernTable(kern.error);
    if (!kern.value.present)
        return fontOk(r);
    r.at_ = kern.value.at;
    r.count_ = be16(view.data_, cast(size_t) r.at_);
    if (!fits(view.data_.length, r.at_ + 2, 4UL * (2UL * r.count_ + 1)))
        return fontErr!MathKernTable(view.error(FontErrorKind.truncated, r.at_ + 2));
    r.present_ = true;
    return fontOk(r);
}

/**
The math kern of glyph `gid` at corner `corner` for correction height `h`
(FTP36, FTP37): `mathKernTable`'s absences and errors, then
`MathKernTable.lookup`. Costs O(log n + n · r · a).
*/
FontResult!MathValue mathKern(in Instance inst, uint gid, MathKernCorner corner, DesignValue h)
{
    const t = mathKernTable(inst, gid, corner);
    if (t.hasError)
        return fontErr!MathValue(t.error);
    return t.value.lookup(h);
}

// ---------------------------------------------------------------------------
// Variants and assemblies (FTP38)
// ---------------------------------------------------------------------------

/// The direction a glyph is stretched in.
enum MathDirection : ubyte
{
    vertical,
    horizontal,
}

/// A glyph's MathGlyphConstruction, when it has one, and the MathVariants header's facts.
private struct Construction
{
    bool variantsPresent;
    ushort minConnectorOverlap;
    bool present;
    ulong at;
}

/**
The construction of `gid` in `direction`: the coverage, then the offset at
its index among that direction's offsets (vertical ones first). An index
past the direction's count is `badValue`; a null offset is no construction.
*/
private FontResult!Construction construction(scope const ref MathTable m, uint gid, MathDirection direction)
{
    Construction c;
    const mv = top(m, 2, 10);
    if (mv.hasError)
        return fontErr!Construction(mv.error);
    if (!mv.value.present)
        return fontOk(c);
    const at = mv.value.at;
    const d = m.data_;
    c.variantsPresent = true;
    c.minConnectorOverlap = be16(d, cast(size_t) at);
    const vertical = direction == MathDirection.vertical;
    const index = coverageIndex(m, at, at + (vertical ? 2 : 4), gid);
    if (index.hasError)
        return fontErr!Construction(index.error);
    if (index.value < 0)
        return fontOk(c);
    const countAt = at + (vertical ? 6 : 8);
    if (index.value >= be16(d, cast(size_t) countAt))
        return fontErr!Construction(m.error(FontErrorKind.badValue, countAt));
    const slot = vertical ? index.value : be16(d, cast(size_t) at + 6) + index.value;
    const glyph = child(m, at, at + 10 + 2 * slot, 4);
    if (glyph.hasError)
        return fontErr!Construction(glyph.error);
    c.present = glyph.value.present;
    c.at = glyph.value.at;
    return fontOk(c);
}

/// One size variant: its glyph and its advance in the construction's direction.
struct MathVariant
{
    ushort glyph;
    Measurement advance;
}

/**
A glyph's size variants in one direction (FTP38), as a random-access range
of `MathVariant`, O(1) per element, with the MathVariants table's
`minConnectorOverlap` beside it. A glyph without a construction has an empty
range; `variantsPresent` is false, and `minConnectorOverlap` meaningless,
when the font has no MathVariants table.
*/
struct MathVariants
{
    @safe pure nothrow @nogc:

    private const(ubyte)[] data_;
    private ulong at_; // the first MathGlyphVariantRecord
    private size_t begin_, end_;
    private InstanceSize size_;
    private ushort unitsPerEm_ = 1;
    private bool variantsPresent_;
    private Measurement overlap_;

    /// Whether `MATH` has a MathVariants table.
    bool variantsPresent() const scope => variantsPresent_;

    /// The minimum connector overlap of every assembly, a design value without device.
    Measurement minConnectorOverlap() const scope => overlap_;

    bool empty() const scope => begin_ == end_;
    size_t length() const scope => end_ - begin_;

    MathVariant front() const scope
    in (!empty)
        => this[0];

    MathVariant back() const scope
    in (!empty)
        => this[length - 1];

    MathVariant opIndex(size_t i) const scope
    in (i < length)
    {
        const p = cast(size_t)(at_ + 4 * (begin_ + i));
        return MathVariant(be16(data_, p),
            Measurement(DesignValue.fromUnits(be16(data_, p + 2), unitsPerEm_), size_));
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
The size variants of glyph `gid` in `direction` at `inst` (FTP38): empty
when the glyph has no construction; `badValue` for a construction index past
its direction's count; `badOffset` for a construction outside the table;
`truncated` for a variant array past it. Costs O(log n), then O(1) per
element.
*/
FontResult!MathVariants mathVariants(return scope const Instance inst, uint gid, MathDirection direction)
{
    const m = mathTable(inst.face);
    if (m.hasError)
        return fontErr!MathVariants(m.error);
    const view = m.value;
    const c = construction(view, gid, direction);
    if (c.hasError)
        return fontErr!MathVariants(c.error);
    MathVariants r;
    r.data_ = view.data_;
    r.size_ = inst.size;
    r.unitsPerEm_ = inst.unitsPerEm;
    r.variantsPresent_ = c.value.variantsPresent;
    r.overlap_ = measured(inst, DesignValue.fromUnits(c.value.minConnectorOverlap, inst.unitsPerEm));
    if (!c.value.present)
        return fontOk(r);
    const count = be16(view.data_, cast(size_t) c.value.at + 2);
    r.at_ = c.value.at + 4;
    if (!fits(view.data_.length, r.at_, 4UL * count))
        return fontErr!MathVariants(view.error(FontErrorKind.truncated, r.at_));
    r.end_ = count;
    return fontOk(r);
}

/// The GlyphAssembly of `gid` in `direction`: absent without a construction or assembly.
private FontResult!Child assembly(scope const ref MathTable m, uint gid, MathDirection direction)
{
    const c = construction(m, gid, direction);
    if (c.hasError)
        return fontErr!Child(c.error);
    if (!c.value.present)
        return fontOk(Child.init);
    return child(m, c.value.at, c.value.at, 6);
}

/// A part count, or absent (FTP38).
struct MathAssemblyLength
{
    /// Whether the glyph has an assembly in that direction.
    bool present;
    ushort partCount;
}

/**
The number of parts of glyph `gid`'s assembly in `direction` (FTP38): absent
when the glyph has no assembly; `variants`' errors, and `badOffset` or
`truncated` for an assembly outside the table. Costs O(log n).
*/
FontResult!MathAssemblyLength mathAssemblyLength(in Instance inst, uint gid, MathDirection direction)
{
    const m = mathTable(inst.face);
    if (m.hasError)
        return fontErr!MathAssemblyLength(m.error);
    const a = assembly(m.value, gid, direction);
    if (a.hasError)
        return fontErr!MathAssemblyLength(a.error);
    if (!a.value.present)
        return fontOk(MathAssemblyLength.init);
    return fontOk(MathAssemblyLength(true, be16(m.value.data_, cast(size_t) a.value.at + 4)));
}

/// One part of a glyph assembly, as stored (FTP38).
struct GlyphPart
{
    @safe pure nothrow @nogc:

    ushort glyph;
    /// The connector lengths at the part's start and end, and its full advance: design values without device.
    Measurement startConnectorLength;
    /// ditto
    Measurement endConnectorLength;
    /// ditto
    Measurement fullAdvance;
    /// The `partFlags` word as stored, reserved bits included.
    ushort flags;

    /// Whether the extender bit (`0x0001`) is set: the part may be skipped or repeated.
    bool extender() const scope => (flags & 0x0001) != 0;
}

/**
An assembly (FTP38): `present` false when the glyph has none; otherwise the
written slice of the caller's array and the assembly's italics correction,
a MathValueRecord resolved as a constant's is (the record is always
stored; `italicsCorrection.hasDevice` is false when its device offset is
null).
*/
struct MathAssembly
{
    bool present;
    GlyphPart[] parts;
    MathValue italicsCorrection;
}

/**
Writes the parts of glyph `gid`'s assembly in `direction` into `parts`
(FTP38) and returns the written slice with the italics correction: absent
when the glyph has no assembly; `limitExceeded` naming `callerStorage` with
the part count as `needed` when `parts` is shorter, leaving it unchanged, as
every other error does; `truncated` for a part array past the table; the
italics correction's error. The parts are as stored: no assembly is
composed. Costs O(log n + p) for `p` parts.
*/
FontResult!MathAssembly mathAssembly(in Instance inst, uint gid, MathDirection direction,
    return scope GlyphPart[] parts)
{
    const m = mathTable(inst.face);
    if (m.hasError)
        return fontErr!MathAssembly(m.error);
    const view = m.value;
    const a = assembly(view, gid, direction);
    if (a.hasError)
        return fontErr!MathAssembly(a.error);
    if (!a.value.present)
        return fontOk(MathAssembly.init);
    const at = a.value.at;
    const d = view.data_;
    const count = be16(d, cast(size_t) at + 4);
    if (!fits(d.length, at + 6, 10UL * count))
        return fontErr!MathAssembly(view.error(FontErrorKind.truncated, at + 6));
    const store = mathStore(inst);
    const italics = record(view, at, at, inst, store, devicePpem(inst));
    if (italics.hasError)
        return fontErr!MathAssembly(italics.error);
    if (parts.length < count)
        return fontErr!MathAssembly(callerStorageError(count, mathTag, view.start_ + at + 4, at + 4));
    const upem = inst.unitsPerEm;
    foreach (i; 0 .. count)
    {
        const p = cast(size_t)(at + 6 + 10 * i);
        Measurement length(size_t field) => measured(inst, DesignValue.fromUnits(be16(d, p + field), upem));
        parts[i] = GlyphPart(be16(d, p), length(2), length(4), length(6), be16(d, p + 8));
    }
    return fontOk(MathAssembly(true, parts[0 .. count], italics.value));
}
