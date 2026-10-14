/**
Instances: a face at a size and a point in its design space
(`docs/specs/font/variation-metrics.md` § 2, FTA3, FTV6–FTV11, FTM13, FTM14).

`face.axes` and `face.namedInstances` list `fvar`'s axes and named instances.
`face.instance(size, coordinates, synthesis)` builds an `Instance`: a copyable
value holding the face, a unit-tagged size, each axis's user value and its
normalized F2Dot14 coordinate, and a synthesis value. Normalization is exact
integer arithmetic (FTV8): clamp, divide with F16.16 rounding to nearest, ties
away from zero, apply `avar` (version 1 segment maps, FTV9; version 2's item
variation store, FTV10), and round to F2Dot14 as `(x + 2) >> 2`.

Problems that do not stop an instance from being built (an unspecified
`badValue` axis, an `avar` that is unreadable or does not match `fvar`, a
decreasing segment map) are recorded in it: `recordedErrors` counts them and
`firstRecordedError` names the first. Nothing here allocates.
*/
module sparkles.font.instance;

import sparkles.base.text.layout_units : LayoutUnit;

import sparkles.font.errors : FontError, FontErrorKind, FontLimit, FontResult, fontErr, fontOk, limitError,
    Tag, tableError;
import sparkles.font.face : Face;
import sparkles.font.tables : Avar, avar, Fvar, fvar, NamedInstance, SegmentMap, VariationAxis;
import sparkles.font.units : Ppem;
import sparkles.font.variations : allZero, NormalizedCoords;

@safe pure nothrow @nogc:

/// The most `fvar` axes an instance carries (FTM13's `variationAxes`).
enum size_t maxVariationAxes = 64;

// ---------------------------------------------------------------------------
// Axes and named instances (FTV6)
// ---------------------------------------------------------------------------

/// The range plumbing `Axes` and `NamedInstances` share: indices into `fvar`.
private mixin template FvarRange()
{
    private Fvar fvar_;
    private size_t begin_, end_;
    private bool hasError_;
    private FontError error_;

    /// Whether `fvar` is unreadable; the range is then empty.
    bool hasError() const scope => hasError_;

    /// Why `fvar` is unreadable, when `hasError`.
    FontError error() const scope
    in (hasError_)
        => error_;

    bool empty() const scope => begin_ == end_;
    size_t length() const scope => end_ - begin_;
    alias opDollar = length;

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
`fvar`'s axes as a random-access range of `FontResult!VariationAxis` (FTV6):
an axis whose minimum, default and maximum are out of order is its `badValue`
entry. A face without `fvar` has an empty range; an unreadable `fvar` gives
an empty range whose `hasError` is set and whose `error` is `fvar`'s.
*/
struct Axes
{
    @safe pure nothrow @nogc:

    mixin FvarRange;

    FontResult!VariationAxis front() const scope
    in (!empty)
        => fvar_.axis(begin_);

    FontResult!VariationAxis back() const scope
    in (!empty)
        => fvar_.axis(end_ - 1);

    FontResult!VariationAxis opIndex(size_t i) const scope
    in (i < length)
        => fvar_.axis(begin_ + i);
}

/**
`fvar`'s named instances as a random-access range of `NamedInstance` (FTV6):
subfamily name ID, the PostScript name ID when `instanceSize` carries it, and
user coordinates. Absent and unreadable `fvar` behave as for `Axes`.
*/
struct NamedInstances
{
    @safe pure nothrow @nogc:

    mixin FvarRange;

    NamedInstance front() const return scope
    in (!empty)
        => fvar_.instance(begin_);

    NamedInstance back() const return scope
    in (!empty)
        => fvar_.instance(end_ - 1);

    NamedInstance opIndex(size_t i) const return scope
    in (i < length)
        => fvar_.instance(begin_ + i);
}

/// A range over all of `face`'s `fvar` axes or named instances; O(1).
private R fvarRange(R)(return scope const Face face)
{
    const fv = face.fvar;
    R r;
    if (fv.hasError)
    {
        if (fv.error.kind != FontErrorKind.missingTable)
        {
            r.hasError_ = true;
            r.error_ = fv.error;
        }
        return r;
    }
    r.fvar_ = fv.value;
    static if (is(R == Axes))
        r.end_ = fv.value.axisCount;
    else
        r.end_ = fv.value.instanceCount;
    return r;
}

/// The face's variation axes (FTV6). Costs O(1); each element O(1).
Axes axes(return scope const Face face) => fvarRange!Axes(face);

/// The face's named instances (FTV6). Costs O(1); each element O(1).
NamedInstances namedInstances(return scope const Face face) => fvarRange!NamedInstances(face);

// ---------------------------------------------------------------------------
// Instance inputs
// ---------------------------------------------------------------------------

/**
An instance's size, tagged with its unit (FTA3): a physical em as a
`LayoutUnit`, or pixels per em as a `Ppem`. `InstanceSize.init` is a physical
em of zero, which `instance` refuses.
*/
struct InstanceSize
{
    @safe pure nothrow @nogc:

    /// Which unit the size is in.
    enum Unit : ubyte
    {
        physical,
        pixels,
    }

    private Unit unit_;
    private LayoutUnit em_;
    private Ppem ppem_;

    /// A physical em size.
    static InstanceSize physical(LayoutUnit em) => InstanceSize(Unit.physical, em, Ppem.init);

    /// A pixel size in pixels per em.
    static InstanceSize pixels(Ppem ppem) => InstanceSize(Unit.pixels, LayoutUnit.init, ppem);

    /// The size's unit.
    Unit unit() const scope => unit_;

    /// The physical em, for a physical size.
    LayoutUnit em() const scope
    in (unit_ == Unit.physical)
        => em_;

    /// The ppem, for a pixel size.
    Ppem ppem() const scope
    in (unit_ == Unit.pixels)
        => ppem_;

    /// Whether the size is positive: an em above zero, or a constructed ppem.
    bool valid() const scope => unit_ == Unit.physical ? em_.raw > 0 : ppem_.valid;
}

///
@("instance.InstanceSize")
@safe pure nothrow @nogc
unittest
{
    const twelvePoints = InstanceSize.physical(LayoutUnit(12 * LayoutUnit.ticksPerPoint));
    assert(twelvePoints.unit == InstanceSize.Unit.physical && twelvePoints.valid);
    const sixteenPixels = InstanceSize.pixels(Ppem.fromInteger(16).value);
    assert(sixteenPixels.unit == InstanceSize.Unit.pixels && sixteenPixels.ppem.isInteger);
    assert(!InstanceSize.init.valid && !InstanceSize.pixels(Ppem.init).valid);
}

/**
Synthetic emboldening and slant (FTV11), both F16.16 and zero by default. An
instance stores it unchanged; outlines and rasterization apply it.
*/
struct Synthesis
{
    /// Emboldening strength, F16.16.
    int emboldenStrength;
    /// Oblique slant, F16.16.
    int obliqueSlant;
}

/// A user coordinate for `instance`: an axis tag and an F16.16 user-space value.
struct UserCoordinate
{
    Tag tag;
    /// F16.16, in the axis's user units (`wght` 650 is `650 << 16`).
    int value;
}

// ---------------------------------------------------------------------------
// Normalization (FTV8, FTV9)
// ---------------------------------------------------------------------------

/// `n / d` for `d > 0`, rounded to nearest with ties away from zero.
private long divideRounded(long n, long d)
in (d > 0)
    => n < 0 ? -((-n + d / 2) / d) : (n + d / 2) / d;

/// `x` clamped to `[lo, hi]`.
private long clamped(long x, long lo, long hi) => x < lo ? lo : x > hi ? hi : x;

/**
FTV8 steps 1 and 2: user value `user` (F16.16) on an axis whose minimum,
default and maximum are in order, normalized to F16.16 in [−65,536, 65,536]:
clamped, then divided with ties rounded away from zero. Costs O(1).
*/
int normalizeAxisValue(in VariationAxis axis, int user)
in (axis.minValue <= axis.defaultValue && axis.defaultValue <= axis.maxValue)
{
    const def = long(axis.defaultValue);
    const u = clamped(user, axis.minValue, axis.maxValue);
    if (u == def)
        return 0;
    const divisor = u < def ? def - axis.minValue : axis.maxValue - def;
    return cast(int) divideRounded((u - def) * 65_536, divisor);
}

///
@("instance.normalizeAxisValue")
@safe pure nothrow @nogc
unittest
{
    const wght = VariationAxis(Tag("wght"), 100 << 16, 400 << 16, 900 << 16);
    assert(normalizeAxisValue(wght, 250 << 16) == -32_768); // −0.5
    assert(normalizeAxisValue(wght, 900 << 16) == 65_536);
    assert(normalizeAxisValue(wght, 1_000 << 16) == 65_536); // clamped
    assert(normalizeAxisValue(wght, 400 << 16) == 0);
}

/**
FTV9: the `avar` segment map `map` applied to the F16.16 value `v` with
HarfBuzz's rule, every quotient rounded to F16.16 with ties away from zero:
end caps trimmed, no pairs the identity, one pair a shift, exact matches
resolved by count and sign, a shift outside the first or last pair, and
otherwise linear interpolation. `map` must be well ordered (`AvarMaps` reports
one that is not). Costs O(n) for its `n` pairs.
*/
int mapCoordinate(in SegmentMap map, int v)
{
    static int from(in SegmentMap m, size_t i) => m.map(i)[0] * 4;
    static int to(in SegmentMap m, size_t i) => m.map(i)[1] * 4;

    const len = map.length;
    if (len == 0)
        return v;
    if (len == 1)
        return v - from(map, 0) + to(map, 0);

    enum one = 65_536;
    size_t start = 0, end = len;
    if (from(map, 0) == -one && to(map, 0) == -one && from(map, 1) == -one)
        ++start;
    if (from(map, end - 1) == one && to(map, end - 1) == one && from(map, end - 2) == one)
        --end;

    size_t i = start;
    while (i < end && from(map, i) != v)
        ++i;
    if (i < end)
    {
        size_t j = i;
        while (j + 1 < end && from(map, j + 1) == v)
            ++j;
        if (i == j)
            return to(map, i);
        if (i + 2 == j)
            return to(map, i + 1);
        if (v < 0)
            return to(map, j);
        if (v > 0)
            return to(map, i);
        const ti = to(map, i), tj = to(map, j);
        return (ti < 0 ? -ti : ti) < (tj < 0 ? -tj : tj) ? ti : tj;
    }

    size_t k = start;
    while (k < end && v >= from(map, k))
        ++k;
    if (k == start)
        return v - from(map, start) + to(map, start);
    if (k == end)
        return v - from(map, end - 1) + to(map, end - 1);
    const bf = from(map, k - 1), bt = to(map, k - 1), af = from(map, k), at = to(map, k);
    return bt + cast(int) divideRounded(long(at - bt) * (v - bf), af - bf);
}

/// FTV8 step 4: F16.16 `x` rounded to F2Dot14 as `(x + 2) >> 2`, saturated to `short`.
short toF2Dot14(int x) => cast(short) clamped((long(x) + 2) >> 2, short.min, short.max);

///
@("instance.toF2Dot14")
@safe pure nothrow @nogc
unittest
{
    assert(toF2Dot14(65_536) == 16_384 && toF2Dot14(-65_536) == -16_384);
    assert(toF2Dot14(2) == 1 && toF2Dot14(-2) == 0); // ties toward +∞
    assert(toF2Dot14(int.max) == short.max); // saturated
}

// ---------------------------------------------------------------------------
// Instance (FTA3, FTV7)
// ---------------------------------------------------------------------------

/**
A face at a size and a point in its design space (FTA3): a copyable value
with no indirection beyond the face's bytes and no mutable state. Per axis it
keeps the user value it was built from, or the axis default, and the
normalized F2Dot14 coordinate. It is the only place variation coordinates are
stored.
*/
struct Instance
{
    @safe pure nothrow @nogc:

    private Face face_;
    private InstanceSize size_;
    private Synthesis synthesis_;
    private short[maxVariationAxes] coords_;
    private int[maxVariationAxes] user_;
    private ushort axisCount_;
    private bool avarApplied_;
    private size_t ignored_;
    private uint recorded_;
    private FontError firstRecorded_;

    /// The face.
    Face face() const return scope => face_;

    /// The size, with its unit.
    InstanceSize size() const scope => size_;

    /// The synthesis value, as given (FTV11).
    Synthesis synthesis() const scope => synthesis_;

    /// `face.unitsPerEm`.
    ushort unitsPerEm() const scope => face_.unitsPerEm;

    /// The number of `fvar` axes; 0 for a face without `fvar`.
    ushort axisCount() const scope => axisCount_;

    /// The normalized F2Dot14 coordinates, one per axis, borrowed from the instance.
    NormalizedCoords coords() const scope return => coords_[0 .. axisCount_];

    /// The F16.16 user value of axis `i` (FTV4): as given, or the axis's stored default.
    int userValue(size_t i) const scope
    in (i < axisCount_)
        => user_[i];

    /// Whether every coordinate is 0, the default instance (FTM14).
    bool allZero() const scope => .allZero(coords_[0 .. axisCount_]);

    /// How many given coordinates matched no axis (or were given to a face without `fvar`).
    size_t ignoredCoordinates() const scope => ignored_;

    /// Whether `avar` was applied; a decreasing map leaves only its own axis unmapped.
    bool avarApplied() const scope => avarApplied_;

    /// How many problems the instance was built around (FTV7, FTV9, FTV10).
    uint recordedErrors() const scope => recorded_;

    /// The first problem recorded, when `recordedErrors > 0`.
    FontError firstRecordedError() const scope
    in (recorded_ > 0)
        => firstRecorded_;

    private void record(FontError e) scope
    {
        if (recorded_++ == 0)
            firstRecorded_ = e;
    }
}

/**
Builds the instance of `face` at `size` and user `coordinates` (FTV7), with
`synthesis` stored unchanged (FTV11):

$(UL
    $(LI a size or ppem that is zero or negative is `badValue`;)
    $(LI a face without `fvar` gives an instance with no coordinates, and
        every coordinate given is ignored and counted; an unreadable `fvar` is
        its error; more than 64 axes is `limitExceeded` naming `variationAxes`;)
    $(LI a tag no axis has is ignored and counted; of a tag given twice the
        last value wins; a tag that several axes share sets every one; an axis
        left unspecified takes its default, normalized to 0;)
    $(LI a value given for a `badValue` axis is that axis's error; an
        unspecified `badValue` axis is normalized to 0 and the error recorded;)
    $(LI an `avar` that is unreadable, whose axis count differs from `fvar`'s,
        or whose version-2 index map or store fails, is not applied, and its
        error is recorded; a decreasing segment map leaves its axis unmapped
        and is recorded.)
)

Values are normalized as `normalizeAxisValue`, mapped as `mapCoordinate`, put
through version 2's store (FTV10), and rounded as `toF2Dot14`. Costs
O(c · a + m + v) for `c` coordinates, `a` axes, `m` `avar` map entries and
version 2's O(a · r · a) work `v`; never allocates.
*/
FontResult!Instance instance(return scope const Face face, InstanceSize size,
    scope const(UserCoordinate)[] coordinates, Synthesis synthesis = Synthesis.init)
{
    if (!size.valid)
        return fontErr!Instance(FontError(FontErrorKind.badValue));
    Instance inst;
    inst.face_ = face;
    inst.size_ = size;
    inst.synthesis_ = synthesis;

    const fv = face.fvar;
    if (fv.hasError)
    {
        if (fv.error.kind != FontErrorKind.missingTable)
            return fontErr!Instance(fv.error);
        inst.ignored_ = coordinates.length;
        return fontOk(inst);
    }
    const f = fv.value;
    if (f.axisCount > maxVariationAxes)
        return fontErr!Instance(limitError(FontLimit.variationAxes, Tag("fvar"), f.tableStart + 8));
    const n = f.axisCount;
    inst.axisCount_ = n;

    Tag[maxVariationAxes] tags;
    bool[maxVariationAxes] bad;
    foreach (i; 0 .. n)
    {
        const record = f.axisRecord(i);
        tags[i] = record.axisTag;
        inst.user_[i] = record.defaultValue;
        bad[i] = f.axis(i).hasError;
    }
    foreach (c; coordinates)
    {
        bool matched;
        foreach (i; 0 .. n)
            if (tags[i] == c.tag)
            {
                if (bad[i])
                    return fontErr!Instance(f.axis(i).error);
                inst.user_[i] = c.value;
                matched = true;
            }
        if (!matched)
            ++inst.ignored_;
    }

    int[maxVariationAxes] x; // F16.16
    foreach (i; 0 .. n)
    {
        if (bad[i])
            inst.record(f.axis(i).error);
        else
            x[i] = normalizeAxisValue(f.axisRecord(i), inst.user_[i]);
    }
    applyAvar(face, x[0 .. n], inst);
    foreach (i; 0 .. n)
        inst.coords_[i] = toF2Dot14(x[i]);
    return fontOk(inst);
}

/**
Applies `face`'s `avar` to the F16.16 values `x`, one per `fvar` axis, in
place (FTV9, FTV10); on failure leaves `x` as it was and records why.
*/
private void applyAvar(scope const Face face, scope int[] x, ref Instance inst)
{
    const av = face.avar;
    if (av.hasError)
    {
        if (av.error.kind != FontErrorKind.missingTable)
            inst.record(av.error);
        return;
    }
    const a = av.value;
    if (a.axisCount != x.length)
    {
        inst.record(tableError(FontErrorKind.badValue, Tag("avar"), a.tableStart, 6));
        return;
    }

    int[maxVariationAxes] y;
    y[0 .. x.length] = x[];
    uint mapErrors;
    FontError firstMapError;
    size_t i;
    foreach (map; a.maps)
    {
        if (map.hasValue)
            y[i] = mapCoordinate(map.value, x[i]);
        else if (map.error.kind == FontErrorKind.badValue)
        {
            if (mapErrors++ == 0)
                firstMapError = map.error;
        }
        else
        {
            inst.record(map.error);
            return;
        }
        ++i;
    }

    if (a.majorVersion == 2)
    {
        const applied = applyAvar2(a, inst.unitsPerEm, y[0 .. x.length]);
        if (applied.hasError)
        {
            inst.record(applied.error);
            return;
        }
    }

    if (mapErrors > 0)
    {
        inst.record(firstMapError);
        inst.recorded_ += mapErrors - 1;
    }
    x[] = y[0 .. x.length];
    inst.avarApplied_ = true;
}

/**
FTV10 on the F16.16 values `y` (after the segment maps): every axis takes the
delta of its index-map entry against the shared vector of `y / 4` rounded to
F2Dot14, ties away from zero; adds `4δ`, rounded the same way and clamped to
±131,072; and clamps to ±65,536. A version 2 `avar` without a store adds
nothing but still clamps, as HarfBuzz. Returns the error of the index map or
store, leaving `y` unchanged, or `true`.
*/
private FontResult!bool applyAvar2(in Avar a, ushort unitsPerEm, scope int[] y)
{
    const n = y.length;
    short[maxVariationAxes] vector;
    foreach (i; 0 .. n)
        vector[i] = cast(short) clamped(divideRounded(y[i], 4), short.min, short.max);
    const indexMap = a.axisIndexMap;
    const store = a.varStore(cast(ushort) n);

    int[maxVariationAxes] result;
    foreach (i; 0 .. n)
    {
        long scaled;
        if (store.present)
        {
            const index = indexMap.map(cast(uint) i);
            if (index.hasError)
                return fontErr!bool(index.error);
            const delta = store.delta(index.value, vector[0 .. n], unitsPerEm);
            if (delta.hasError)
                return fontErr!bool(delta.error);
            // raw is δ in 1/65,536 F2Dot14 units; 4δ in F16.16 is raw / 16,384.
            scaled = clamped(divideRounded(delta.value.raw, 16_384), -131_072, 131_072);
        }
        result[i] = cast(int) clamped(y[i] + scaled, -65_536, 65_536);
    }
    y[] = result[0 .. n];
    return fontOk(true);
}
