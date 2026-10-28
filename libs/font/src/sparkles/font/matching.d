/**
Font matching (`docs/specs/font/discovery.md` FTD25–FTD30, SPEC.md FTD4):
CSS Fonts Level 4 §5.2 step 4 over a catalog's records.

The first requested family a record answers to selects its records; width,
then style, then weight narrow them, each step searching the values the
remaining records support phase by phase. A record's ranges support every
value in them, so a variable face takes part as every face it can be. Values
are F16.16 fixed point and compared exactly. The match carries the record,
the values found, the user coordinates that realize them, the synthesis the
request still needs, and a score. Nothing here allocates.
*/
module sparkles.font.matching;

import sparkles.font.catalog : Catalog, FamilyEntry;
import sparkles.font.errors : FontError, FontErrorKind, FontResult, fontErr, fontOk, Tag;
import sparkles.font.face_record : AxisRecord, FaceRecord;
import sparkles.font.instance : Synthesis, UserCoordinate;

@safe pure nothrow @nogc:

/// 1.0 in F16.16.
enum int fixedOne = 65_536;

/// The style a request asks for (FTD25).
enum StyleRequest : ubyte
{
    normal,
    italic,
    oblique,
}

/// A matching request (FTD25). Values are F16.16.
struct MatchRequest
{
    /// Family names in order; generic families are the caller's to resolve.
    const(char[])[] families;
    /// 1–1,000.
    int weight = 400 * fixedOne;
    /// 50–200 percent.
    int width = 100 * fixedOne;
    StyleRequest style;
    /// For `oblique`: −90° to 90°, clockwise.
    int obliqueAngle = 14 * fixedOne;
    bool synthesizeWeight = true;
    bool synthesizeStyle = true;
    /// CSS's `oblique-only`: an italic request is never synthesized.
    bool obliqueOnly;
}

/// One step's distance from the request: the phase found in, then how far (FTD28).
struct StepScore
{
    ubyte phase;
    uint distance;
}

/// A match's score; lower is closer (FTD28).
struct MatchScore
{
    @safe pure nothrow @nogc:

    /// The family's position in the request.
    uint family;
    StepScore width, style, weight;

    /// Lexicographic order: family, width, style, weight.
    int opCmp(in MatchScore o) const
    {
        static int cmp(ulong a, ulong b) => a < b ? -1 : a > b;
        static int step(in StepScore a, in StepScore b)
            => a.phase != b.phase ? cmp(a.phase, b.phase) : cmp(a.distance, b.distance);
        if (family != o.family)
            return cmp(family, o.family);
        if (const c = step(width, o.width))
            return c;
        if (const c = step(style, o.style))
            return c;
        return step(weight, o.weight);
    }
}

/// The result of `matchFont` (FTD28).
struct Match
{
    @safe pure nothrow @nogc:

    /// False when no requested family names a record (`noMatch`).
    bool found;
    /// The record's index in the catalog.
    uint record;
    /// The values found: F16.16 width percent, weight, italic (0 or 1) and oblique angle.
    int width, weight, italic, oblique;
    /// The variable-axis coordinates that realize them, `coordinateCount` of them.
    UserCoordinate[4] coordinates;
    ubyte coordinateCount;
    Synthesis synthesis;
    bool syntheticBold, syntheticOblique;
    MatchScore score;

    /// The coordinates as a slice.
    const(UserCoordinate)[] userCoordinates() const return => coordinates[0 .. coordinateCount];
}

/// The correctly rounded tangents of 0°–89° in F16.16 (FTD29).
private immutable int[90] tangent = [
    0, 1144, 2289, 3435, 4583, 5734, 6888, 8047, 9210, 10380,
    11556, 12739, 13930, 15130, 16340, 17560, 18792, 20036, 21294, 22566,
    23853, 25157, 26478, 27818, 29179, 30560, 31964, 33392, 34846, 36327,
    37837, 39378, 40951, 42560, 44205, 45889, 47615, 49385, 51202, 53070,
    54991, 56970, 59009, 61113, 63287, 65536, 67865, 70279, 72785, 75391,
    78103, 80930, 83882, 86969, 90203, 93595, 97161, 100917, 104880, 109070,
    113512, 118230, 123255, 128622, 134369, 140542, 147196, 154393, 162207, 170727,
    180059, 190330, 201699, 214359, 228551, 244584, 262851, 283868, 308323, 337153,
    371673, 413778, 466313, 533748, 623533, 749080, 937208, 1250501, 1876705, 3754555,
];

/// `Synthesis.emboldenStrength` for 1/24 em (FTD29).
enum int emboldenOneTwentyFourth = 2_731;

/// The F16.16 tangent of `angle` (F16.16 degrees) rounded to a whole degree and clamped to ±89°.
int slantOf(int angle)
{
    long degrees = (cast(long) angle + (angle < 0 ? -fixedOne / 2 : fixedOne / 2)) / fixedOne;
    if (degrees > 89)
        degrees = 89;
    if (degrees < -89)
        degrees = -89;
    return degrees < 0 ? -tangent[cast(size_t) -degrees] : tangent[cast(size_t) degrees];
}

///
@("matching.slantOf")
unittest
{
    assert(slantOf(14 * fixedOne) == 16_340 && slantOf(-45 * fixedOne) == -65_536);
    assert(slantOf(90 * fixedOne) == 3_754_555 && slantOf(fixedOne / 2) == 1_144);
}

// ---------------------------------------------------------------------------
// Search phases (FTD27)
// ---------------------------------------------------------------------------

private enum int minusInfinity = int.min, plusInfinity = int.max;

/**
One phase of a search: the values in `[lo, hi]` (open ends already moved
one unit in), searched ascending (the smallest supported value wins) or
descending (the largest).
*/
private struct Phase
{
    int lo, hi;
    bool ascending;
}

/// `[lo, hi]`, `(lo, hi]` and so on, as `Phase`s over F16.16 integers.
private Phase closed(int lo, int hi, bool ascending) => Phase(lo, hi, ascending);
private Phase openLow(int lo, int hi, bool ascending) => Phase(lo == plusInfinity ? lo : lo + 1, hi, ascending);
private Phase openHigh(int lo, int hi, bool ascending) => Phase(lo, hi == minusInfinity ? hi : hi - 1, ascending);

/// The value of `[a, b]` a phase reaches first, or false when the range misses it.
private bool reach(in Phase p, int a, int b, out int value)
{
    const lo = a > p.lo ? a : p.lo;
    const hi = b < p.hi ? b : p.hi;
    if (lo > hi)
        return false;
    value = p.ascending ? lo : hi;
    return true;
}

/// The phases of a width search (FTD27 step 1).
private size_t widthPhases(int d, ref Phase[4] p)
{
    if (d <= 100 * fixedOne)
    {
        p[0] = closed(minusInfinity, d, false);
        p[1] = openLow(d, plusInfinity, true);
    }
    else
    {
        p[0] = closed(d, plusInfinity, true);
        p[1] = openHigh(minusInfinity, d, false);
    }
    return 2;
}

/// The phases of a weight search (FTD27 step 3).
private size_t weightPhases(int d, ref Phase[4] p)
{
    if (d >= 400 * fixedOne && d <= 500 * fixedOne)
    {
        p[0] = closed(d, 500 * fixedOne, true);
        p[1] = openHigh(minusInfinity, d, false);
        p[2] = openLow(500 * fixedOne, plusInfinity, true);
        return 3;
    }
    if (d < 400 * fixedOne)
    {
        p[0] = closed(minusInfinity, d, false);
        p[1] = openLow(d, plusInfinity, true);
        return 2;
    }
    p[0] = closed(d, plusInfinity, true);
    p[1] = openHigh(minusInfinity, d, false);
    return 2;
}

/// A style phase: the italic phase, or an oblique phase over angles.
private struct StylePhase
{
    bool italic;
    Phase angles;
}

/// The phases of a style search (FTD27 step 2's table).
private size_t stylePhases(StyleRequest style, int a, ref StylePhase[4] p)
{
    enum int right = 90 * fixedOne, left = -90 * fixedOne, eleven = 11 * fixedOne, fourteen = 14 * fixedOne;
    StylePhase italic = StylePhase(true);
    StylePhase oblique(Phase x) => StylePhase(false, x);
    if (style == StyleRequest.italic)
    {
        p[0] = italic;
        p[1] = oblique(closed(fourteen, right, true));
        p[2] = oblique(openHigh(0, fourteen, false));
        p[2].angles.lo = 1; // (0°, 14°)
        p[3] = oblique(closed(left, 0, false));
        return 4;
    }
    if (style == StyleRequest.normal || a == 0)
    {
        p[0] = oblique(closed(0, right, true));
        p[1] = italic;
        p[2] = oblique(openHigh(left, 0, false));
        return 3;
    }
    if (a > 0)
    {
        if (a >= eleven)
        {
            p[0] = oblique(closed(a, right, true));
            p[1] = oblique(Phase(1, a - 1, false));
        }
        else
        {
            p[0] = oblique(Phase(1, a, false));
            p[1] = oblique(openLow(a, right, true));
        }
        p[2] = italic;
        p[3] = oblique(closed(left, 0, false));
        return 4;
    }
    // A negative angle mirrors the rows for −a.
    if (a <= -eleven)
    {
        p[0] = oblique(closed(left, a, false));
        p[1] = oblique(Phase(a + 1, -1, true));
    }
    else
    {
        p[0] = oblique(Phase(a, -1, true));
        p[1] = oblique(openHigh(left, a, false));
    }
    p[2] = italic;
    p[3] = oblique(closed(0, right, true));
    return 4;
}

// ---------------------------------------------------------------------------
// Matching (FTD26–FTD30)
// ---------------------------------------------------------------------------

/// The found style: an italic point, or an oblique angle with italic 0.
private struct StyleValue
{
    bool italic;
    int angle;
}

private bool supportsStyle(in FaceRecord r, in StyleValue s)
    => s.italic ? r.italicMax >= fixedOne
        : r.italicMin == 0 && r.obliqueMin <= s.angle && s.angle <= r.obliqueMax;

private uint distance(int a, int b) => a > b ? cast(uint)(cast(long) a - b) : cast(uint)(cast(long) b - a);

/**
Matches `request` against `catalog` (FTD26–FTD29): `badValue` for a value
outside its range; a `Match` with `found` false when no requested family
names a record. Costs O(L log a + m) for `L` names, `a` aliases and `m`
records of the selected family; allocates nothing (FTD30).
*/
FontResult!Match matchFont(ref const Catalog catalog, in MatchRequest request)
{
    if (request.weight < fixedOne || request.weight > 1_000 * fixedOne || request.width < 50 * fixedOne
            || request.width > 200 * fixedOne || request.obliqueAngle < -90 * fixedOne
            || request.obliqueAngle > 90 * fixedOne)
        return fontErr!Match(FontError(FontErrorKind.badValue));
    foreach (familyIndex, name; request.families)
    {
        const entries = catalog.familyEntries(name);
        if (entries.length == 0)
            continue;
        auto m = narrow(catalog, entries, request);
        m.score.family = cast(uint) familyIndex;
        return fontOk(m);
    }
    return fontOk(Match.init);
}

/// FTD27's three steps over the family's `entries`, then the coordinates and synthesis.
private Match narrow(ref const Catalog catalog, scope const(FamilyEntry)[] entries, in MatchRequest request)
{
    const records = catalog.records;
    Match m;
    m.found = true;

    // 1. Width, over every record of the family.
    Phase[4] phases;
    const nw = widthPhases(request.width, phases);
    width: foreach (k, p; phases[0 .. nw])
    {
        bool any;
        int best;
        foreach (e; entries)
        {
            int v;
            if (reach(p, records[e.record].widthMin, records[e.record].widthMax, v)
                    && (!any || (p.ascending ? v < best : v > best)))
            {
                best = v;
                any = true;
            }
        }
        if (any)
        {
            m.width = best;
            m.score.width = StepScore(cast(ubyte) k, distance(best, request.width));
            break width;
        }
    }
    bool hasWidth(in FaceRecord r) => r.widthMin <= m.width && m.width <= r.widthMax;

    // 2. Style, over the records supporting the width.
    StylePhase[4] sp;
    const ns = stylePhases(request.style, request.obliqueAngle, sp);
    StyleValue style;
    const desiredAngle = request.style == StyleRequest.italic ? 14 * fixedOne
        : request.style == StyleRequest.normal ? 0 : request.obliqueAngle;
    style: foreach (k, p; sp[0 .. ns])
    {
        bool any;
        int best;
        foreach (e; entries)
        {
            const r = records[e.record];
            if (!hasWidth(r))
                continue;
            if (p.italic)
            {
                if (r.italicMax >= fixedOne)
                {
                    any = true;
                    break;
                }
                continue;
            }
            if (r.italicMin != 0)
                continue;
            int v;
            if (reach(p.angles, r.obliqueMin, r.obliqueMax, v) && (!any || (p.angles.ascending ? v < best : v > best)))
            {
                best = v;
                any = true;
            }
        }
        if (any)
        {
            style = p.italic ? StyleValue(true, 0) : StyleValue(false, best);
            m.score.style = StepScore(cast(ubyte) k, p.italic ? 0 : distance(best, desiredAngle));
            break style;
        }
    }
    bool hasStyle(in FaceRecord r) => hasWidth(r) && supportsStyle(r, style);

    // 3. Weight, over the records supporting both.
    const nwt = weightPhases(request.weight, phases);
    weight: foreach (k, p; phases[0 .. nwt])
    {
        bool any;
        int best;
        foreach (e; entries)
        {
            const r = records[e.record];
            int v;
            if (hasStyle(r) && reach(p, r.weightMin, r.weightMax, v) && (!any || (p.ascending ? v < best : v > best)))
            {
                best = v;
                any = true;
            }
        }
        if (any)
        {
            m.weight = best;
            m.score.weight = StepScore(cast(ubyte) k, distance(best, request.weight));
            break weight;
        }
    }

    // The first record, in catalog order, that supports all three.
    uint chosen = uint.max;
    foreach (e; entries)
    {
        const r = records[e.record];
        if (hasStyle(r) && r.weightMin <= m.weight && m.weight <= r.weightMax && e.record < chosen)
            chosen = e.record;
    }
    m.record = chosen;
    const r = records[chosen];
    m.italic = style.italic ? fixedOne : 0;
    if (style.italic)
        // An italic point's angle: 0 where the record allows it, else the nearest.
        m.oblique = r.obliqueMin > 0 ? r.obliqueMin : r.obliqueMax < 0 ? r.obliqueMax : 0;
    else
        m.oblique = style.angle;

    // Coordinates for the record's axes, clamped to them (FTD28).
    void coordinate(Tag tag, int value)
    {
        foreach (a; catalog.pools.axesOf(r))
            if (a.tag == tag)
            {
                const v = value < a.minValue ? a.minValue : value > a.maxValue ? a.maxValue : value;
                m.coordinates[m.coordinateCount++] = UserCoordinate(tag, v);
                return;
            }
    }
    if (r.hasWdthAxis)
        coordinate(Tag("wdth"), m.width);
    if (r.hasWghtAxis)
        coordinate(Tag("wght"), m.weight);
    if (r.hasSlntAxis)
        coordinate(Tag("slnt"), -m.oblique);
    if (r.hasItalAxis)
        coordinate(Tag("ital"), m.italic);

    // Synthesis (FTD29).
    if (request.synthesizeWeight && request.weight >= 600 * fixedOne && r.weightMax < 600 * fixedOne)
    {
        m.syntheticBold = true;
        m.synthesis.emboldenStrength = emboldenOneTwentyFourth;
    }
    const upright = !style.italic && style.angle == 0;
    const slantWanted = request.style == StyleRequest.italic ? !request.obliqueOnly
        : request.style == StyleRequest.oblique && request.obliqueAngle != 0;
    if (request.synthesizeStyle && slantWanted && upright)
    {
        m.syntheticOblique = true;
        m.synthesis.obliqueSlant = slantOf(request.style == StyleRequest.italic ? 14 * fixedOne
            : request.obliqueAngle);
    }
    return m;
}
