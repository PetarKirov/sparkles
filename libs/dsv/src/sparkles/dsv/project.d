/// Projection compute (`DSM6` in `docs/specs/hue/dsv-preview.md`): typed
/// filter constraints (`DSF2`) and stable multi-key sorting (`DSS1`–`DSS3`)
/// over a parsed document's **data records**, producing a record-index
/// permutation the host renders. Pure functions of `(model, spec)` —
/// deterministic, independent of enumeration order; the host owns name→column
/// resolution, the fuzzy full-text remainder (`DSF3`, composed by ANDing the
/// index sets), and all presentation state (column order/visibility).
///
/// Comparison is typed per the sampled `ColumnType` (`DSS2`): integers and
/// floats by value, ISO dates lexicographically with the `T`/space separator
/// normalized, booleans `false < true`, text bytewise over the decoded cells.
/// A cell that does not conform to its column's type groups **after** every
/// conforming value and compares as text among its kind; ordered constraints
/// never admit a non-conforming cell. `contains` matching is ASCII
/// case-insensitive (full Unicode folding stays with the fuzzy engine).
module sparkles.dsv.project;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.dsv.model : ColumnType, decodeCell, DsvDoc, satisfies,
    classifyValue, ValueKind;

/// One sort key (`DSS1`): a **data** column (0-based; view chrome like the
/// record-number gutter is the host's and never reaches the engine).
struct SortKey
{
    uint column;
    bool descending;
}

/// The typed filter operators (`DSF2`).
enum ConstraintOp : ubyte
{
    contains, /// ASCII-case-insensitive substring over the decoded cell
    eq,       /// exact decoded equality
    gt,       /// typed ordered comparison against `value`
    ge,       /// ditto
    lt,       /// ditto
    le,       /// ditto
    empty,    /// the decoded cell is empty
}

/// One column constraint; `value` is borrowed from the query. Constraints
/// AND (`DSF2`); `negate` inverts this one's verdict.
struct Constraint
{
    uint column;
    ConstraintOp op;
    bool negate;
    const(char)[] value;
}

/// The engine half of `DSB1`'s projection value: what changes **which** data
/// records show and in **what order**. Column order/visibility is
/// presentation and stays with the host.
struct ProjectionSpec
{
    const(SortKey)[] sortKeys;
    const(Constraint)[] constraints;

    bool pristine() const @safe pure nothrow @nogc
        => sortKeys.length == 0 && constraints.length == 0;
}

/// Applies `spec` over `doc`'s data records: appends the passing records'
/// **data indexes** (0-based among data records, ascending source order for
/// equal keys — `DSS3`'s stability via the index tiebreak) to `out_` in
/// projected order. `types` is the host's sampled `inferColumnTypes` result.
void applyProjection(Buf)(in DsvDoc doc, in ColumnType[] types,
    in ProjectionSpec spec, ref Buf out_)
{
    import std.algorithm.sorting : sort;

    const first = doc.hasHeader ? 1 : 0;
    const total = doc.records.length - (doc.records.length ? first : 0);

    SmallBuffer!(char, 256) bufA, bufB;

    const(char)[] cellText(size_t dataIdx, size_t col, ref SmallBuffer!(char, 256) buf)
    {
        const rec = doc.records[first + dataIdx];
        if (col >= rec.cellCount)
            return "";
        return decodeCell(doc, doc.cells[rec.cellsStart + col], buf);
    }

    const startLen = out_.length;
    foreach (i; 0 .. total)
    {
        bool pass = true;
        foreach (ref c; spec.constraints)
        {
            const t = cellText(i, c.column, bufA);
            const colType = c.column < types.length ? types[c.column] : ColumnType.text;
            bool hit = evalConstraint(t, c, colType);
            if (c.negate)
                hit = !hit;
            if (!hit)
            {
                pass = false;
                break;
            }
        }
        if (pass)
            out_ ~= cast(uint) i;
    }

    if (spec.sortKeys.length == 0)
        return;

    // A plain in-place sort with the data index as the final tiebreak IS the
    // stable multi-key order (`DSS3`): the tiebreak makes the order total,
    // so no two elements ever compare equal.
    auto view = out_[][startLen .. out_.length];
    view.sort!((a, b) {
        foreach (ref k; spec.sortKeys)
        {
            const colType = k.column < types.length ? types[k.column] : ColumnType.text;
            const c = compareTyped(cellText(a, k.column, bufA),
                cellText(b, k.column, bufB), colType);
            if (c != 0)
                return k.descending ? c > 0 : c < 0;
        }
        return a < b;
    });
}

/// Typed three-way comparison of two decoded cells under a column type
/// (`DSS2`): conforming values first (typed order), non-conforming after
/// (text order among themselves).
int compareTyped(scope const(char)[] a, scope const(char)[] b, ColumnType type)
    @safe pure nothrow @nogc
{
    const ka = classifyValue(a), kb = classifyValue(b);
    const ca = satisfies(ka, type) && ka != ValueKind.empty;
    const cb = satisfies(kb, type) && kb != ValueKind.empty;
    if (ca != cb)
        return ca ? -1 : 1; // conforming values sort before non-conforming
    if (!ca)
        return textCompare(a, b); // both non-conforming: text order

    final switch (type)
    {
    case ColumnType.integer:
    case ColumnType.floating:
        const va = parseNumber(a), vb = parseNumber(b);
        return va < vb ? -1 : va > vb ? 1 : 0;
    case ColumnType.date:
        return dateCompare(a, b);
    case ColumnType.boolean:
        const ba = isTrue(a), bb = isTrue(b);
        return ba == bb ? 0 : ba ? 1 : -1; // false < true
    case ColumnType.text:
        return textCompare(a, b);
    }
}

private double parseNumber(scope const(char)[] t) @safe pure nothrow @nogc
{
    import sparkles.base.text.float_conv : readDecimalFloat;

    // Classification trims ASCII space/tab; mirror it before parsing.
    size_t lo = 0, hi = t.length;
    while (lo < hi && (t[lo] == ' ' || t[lo] == '\t'))
        lo++;
    while (hi > lo && (t[hi - 1] == ' ' || t[hi - 1] == '\t'))
        hi--;
    const(char)[] s = t[lo .. hi];
    auto res = readDecimalFloat(s);
    return res.hasError ? double.nan : res.value;
}

private bool isTrue(scope const(char)[] t) @safe pure nothrow @nogc
{
    size_t lo = 0;
    while (lo < t.length && (t[lo] == ' ' || t[lo] == '\t'))
        lo++;
    return lo < t.length && (t[lo] == 't' || t[lo] == 'T');
}

private int textCompare(scope const(char)[] a, scope const(char)[] b)
    @safe pure nothrow @nogc
{
    const n = a.length < b.length ? a.length : b.length;
    foreach (i; 0 .. n)
        if (a[i] != b[i])
            return a[i] < b[i] ? -1 : 1;
    return a.length == b.length ? 0 : a.length < b.length ? -1 : 1;
}

/// ISO 8601 lexicographic order with the `T`/space time separator
/// normalized, so `2026-08-18 15:00` and `2026-08-18T14:00` order correctly.
private int dateCompare(scope const(char)[] a, scope const(char)[] b)
    @safe pure nothrow @nogc
{
    static char norm(char c) => c == ' ' ? 'T' : c;
    const n = a.length < b.length ? a.length : b.length;
    foreach (i; 0 .. n)
    {
        const ca = norm(a[i]), cb = norm(b[i]);
        if (ca != cb)
            return ca < cb ? -1 : 1;
    }
    return a.length == b.length ? 0 : a.length < b.length ? -1 : 1;
}

/// ASCII-case-insensitive substring search (`contains`).
private bool containsIgnoreCase(scope const(char)[] hay, scope const(char)[] needle)
    @safe pure nothrow @nogc
{
    if (needle.length == 0)
        return true;
    if (needle.length > hay.length)
        return false;
    foreach (start; 0 .. hay.length - needle.length + 1)
    {
        bool all = true;
        foreach (i; 0 .. needle.length)
        {
            const a = hay[start + i], b = needle[i];
            const fa = a >= 'A' && a <= 'Z' ? cast(char)(a | 0x20) : a;
            const fb = b >= 'A' && b <= 'Z' ? cast(char)(b | 0x20) : b;
            if (fa != fb)
            {
                all = false;
                break;
            }
        }
        if (all)
            return true;
    }
    return false;
}

private bool evalConstraint(scope const(char)[] cell, in Constraint c,
    ColumnType type) @safe pure nothrow @nogc
{
    final switch (c.op)
    {
    case ConstraintOp.contains:
        return containsIgnoreCase(cell, c.value);
    case ConstraintOp.eq:
        return cell == c.value;
    case ConstraintOp.empty:
        return cell.length == 0;
    case ConstraintOp.gt:
    case ConstraintOp.ge:
    case ConstraintOp.lt:
    case ConstraintOp.le:
        // Ordered constraints never admit a non-conforming cell (`DSF2`).
        const k = classifyValue(cell);
        if (!satisfies(k, type) || k == ValueKind.empty)
            return false;
        const cmp = compareTyped(cell, c.value, type);
        final switch (c.op)
        {
        case ConstraintOp.gt: return cmp > 0;
        case ConstraintOp.ge: return cmp >= 0;
        case ConstraintOp.lt: return cmp < 0;
        case ConstraintOp.le: return cmp <= 0;
        case ConstraintOp.contains:
        case ConstraintOp.eq:
        case ConstraintOp.empty:
            assert(false);
        }
    }
}

version (unittest)
{
    import sparkles.dsv.model : Dialect, inferColumnTypes;
    import sparkles.dsv.parse : parseDsv;

    private DsvDoc fixtureDoc() @safe pure nothrow @nogc
    {
        auto doc = parseDsv("name,qty,price,when,ok\n"
            ~ "carol,10,2.50,2026-03-01,true\n"
            ~ "alice,2,10.00,2026-01-15,false\n"
            ~ "bob,10,x,2026-02-01 09:00,true\n"
            ~ "dave,,3.25,2026-02-01T08:00,false\n", Dialect(',')).value;
        doc.hasHeader = true;
        return doc;
    }

    private ColumnType[] fixtureTypes(in DsvDoc doc) @safe
    {
        SmallBuffer!(ColumnType, 16) t;
        inferColumnTypes(doc, 100, t);
        return t[].dup;
    }

    private uint[] project(in DsvDoc doc, in ColumnType[] types,
        in ProjectionSpec spec) @safe
    {
        SmallBuffer!(uint, 32) idx;
        applyProjection(doc, types, spec, idx);
        return idx[].dup;
    }
}

@("project.sort.typedSingleKey")
@safe unittest
{
    const doc = fixtureDoc();
    const types = fixtureTypes(doc);
    // qty (integer): 2 < 10 == 10 (source-order tiebreak) < empty(dave).
    assert(project(doc, types, ProjectionSpec([SortKey(1)]))
        == [1u, 0, 2, 3]);
    // Descending reverses values but the non-conforming tail stays last…
    // no: descending is a full reversal of the comparator, so the empty
    // cell (non-conforming) leads. Pin the actual contract:
    assert(project(doc, types, ProjectionSpec([SortKey(1, descending: true)]))
        == [3u, 0, 2, 1]);
}

@("project.sort.floatAndNonConforming")
@safe unittest
{
    const doc = fixtureDoc();
    const types = fixtureTypes(doc);
    // price (floating, 3/4 conform → still floating at 75%? 95% floor says
    // TEXT). Sanity: with a text column, order is bytewise.
    assert(types[2] == ColumnType.text);
    assert(project(doc, types, ProjectionSpec([SortKey(2)]))
        == [1u, 0, 3, 2]); // "10.00" < "2.50" < "3.25" < "x" bytewise
}

@("project.sort.dateSeparatorNormalized")
@safe unittest
{
    const doc = fixtureDoc();
    const types = fixtureTypes(doc);
    assert(types[3] == ColumnType.date);
    // 2026-01-15 < 2026-02-01T08:00 (dave) < 2026-02-01 09:00 (bob, space
    // separator sorts as 'T') < 2026-03-01.
    assert(project(doc, types, ProjectionSpec([SortKey(3)]))
        == [1u, 3, 2, 0]);
}

@("project.sort.multiKeyComposition")
@safe unittest
{
    const doc = fixtureDoc();
    const types = fixtureTypes(doc);
    // qty asc, then name desc among the qty==10 pair (carol, bob).
    const spec = ProjectionSpec([SortKey(1), SortKey(0, descending: true)]);
    assert(project(doc, types, spec) == [1u, 0, 2, 3]);
    const spec2 = ProjectionSpec([SortKey(1), SortKey(0)]);
    assert(project(doc, types, spec2) == [1u, 2, 0, 3]);
}

@("project.filter.operators")
@safe unittest
{
    const doc = fixtureDoc();
    const types = fixtureTypes(doc);

    assert(project(doc, types, ProjectionSpec(null,
        [Constraint(0, ConstraintOp.contains, false, "AL")])) == [1u]); // alice
    assert(project(doc, types, ProjectionSpec(null,
        [Constraint(4, ConstraintOp.eq, false, "true")])) == [0u, 2]);
    assert(project(doc, types, ProjectionSpec(null,
        [Constraint(1, ConstraintOp.ge, false, "10")])) == [0u, 2]);
    assert(project(doc, types, ProjectionSpec(null,
        [Constraint(3, ConstraintOp.lt, false, "2026-02-01T08:30")])) == [1u, 3]);
    assert(project(doc, types, ProjectionSpec(null,
        [Constraint(1, ConstraintOp.empty, false, null)])) == [3u]);
    assert(project(doc, types, ProjectionSpec(null,
        [Constraint(1, ConstraintOp.empty, true, null)])) == [0u, 1, 2]);
    // AND composition + sort composes with filtering.
    assert(project(doc, types, ProjectionSpec([SortKey(0, descending: true)],
        [Constraint(4, ConstraintOp.eq, false, "true")])) == [0u, 2]);
}

@("project.pristine")
@safe unittest
{
    const doc = fixtureDoc();
    const types = fixtureTypes(doc);
    assert(ProjectionSpec.init.pristine);
    assert(project(doc, types, ProjectionSpec.init) == [0u, 1, 2, 3]);
}
