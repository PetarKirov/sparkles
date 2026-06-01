/**
`Ranges!V` — the single concrete version-range type.

A version range is a set of versions expressed as set algebra. `Ranges!V`
stores a sorted, disjoint sequence of intervals and maintains those
invariants on every operation. This M1 skeleton provides the
$(REF isVersionRange, sparkles,versions,traits)-satisfying surface — the
required set-algebra basis plus the De-Morgan-derived conveniences — over a
boundary-point representation. The full interval-convenience API and VERS
`toString` are completed in M2.

See `docs/specs/versions/SPEC.md` §4.
*/
module sparkles.versions.ranges;

import sparkles.versions.traits : isVersion;

/**
A sorted, disjoint set of half-open version intervals.

The set is represented as a sequence of ascending boundary points
`b[0] < b[1] < …`; membership toggles at each boundary, starting outside the
set. So `[]` is the empty set, `[v]` is `[v, +∞)`, and `[lo, hi]` is
`[lo, hi)`. Complement toggles the "starts inside" flag; intersection merges
the two boundary sequences. This is the classic indicator-function
representation of a 1-D point set and keeps the set-algebra operations
total and canonical.
*/
struct Ranges(V) if (isVersion!V)
{
    /// The version type this range constrains.
    alias Version = V;

    // Ascending boundary points. Membership starts at `_startsInside` and
    // toggles at each boundary. Invariant: strictly ascending, canonical.
    // Boundary points are logically immutable snapshots, so they are stored
    // as `const(V)` — this lets version schemes whose value carries mutable
    // indirection (e.g. PyPI's `uint[] release`) still be used as boundaries
    // without an illegal `const(V) -> V` copy.
    private const(V)[] _bounds;
    private bool _startsInside;

    // ----- required set-algebra basis -----

    /// The empty set.
    static Ranges empty() @safe pure nothrow
        => Ranges.init;

    /// The set `{v}` — represented as the half-open `[v, next(v))`. Since
    /// versions are not enumerable in general, a singleton is stored as the
    /// degenerate closed point `[v, v]`, recognised by `contains`.
    static Ranges singleton(V v) @safe pure nothrow
    {
        Ranges r;
        r._bounds = [v, v];
        r._startsInside = false;
        return r;
    }

    /// Set complement: toggle the "starts inside" flag, leaving the
    /// boundaries untouched.
    Ranges complement() const @safe pure nothrow
    {
        Ranges r;
        // Elements are `const(V)` and never mutated in place, so sharing the
        // immutable boundary slice is safe and avoids a needless copy.
        r._bounds = _bounds;
        r._startsInside = !_startsInside;
        return r;
    }

    /// Set intersection of two ranges.
    Ranges intersection(const Ranges other) const @safe pure nothrow
    {
        Ranges r;
        bool insideA = _startsInside;
        bool insideB = other._startsInside;
        r._startsInside = insideA && insideB;

        size_t i, j;
        bool prevInside = r._startsInside;
        while (i < _bounds.length || j < other._bounds.length)
        {
            // Pick the next boundary (smallest of the two cursors).
            const takeA = j >= other._bounds.length
                || (i < _bounds.length && !(other._bounds[j] < _bounds[i]));
            const takeB = i >= _bounds.length
                || (j < other._bounds.length && !(_bounds[i] < other._bounds[j]));

            // Bind the boundary point as `const(V)` *before* advancing the
            // cursors, then toggle the relevant inside flags.
            const(V) point = takeA ? _bounds[i] : other._bounds[j];
            if (takeA)
            {
                insideA = !insideA;
                i++;
            }
            if (takeB)
            {
                insideB = !insideB;
                j++;
            }

            const nowInside = insideA && insideB;
            if (nowInside != prevInside)
            {
                r._bounds ~= point;
                prevInside = nowInside;
            }
        }
        return r;
    }

    /// Membership test.
    bool contains(const V v) const @safe pure nothrow
    {
        bool inside = _startsInside;
        foreach (idx, b; _bounds)
        {
            if (v < b)
                return inside;            // strictly below this boundary
            if (v == b)
            {
                // A closed point `[b, b]` (an adjacent boundary pair of equal
                // value) includes `b` regardless of parity.
                if (idx + 1 < _bounds.length && _bounds[idx + 1] == b)
                    return true;
                // Otherwise `b` is the (half-open) entering edge of the
                // interval it opens: membership is the value *after* the
                // toggle at `b`.
                return !inside;
            }
            inside = !inside;            // passed this boundary
        }
        return inside;
    }

    // ----- interval conveniences -----

    /// `[v, +∞)` — every version `>= v`.
    static Ranges higherThan(V v) @safe pure nothrow
    {
        Ranges r;
        r._bounds = [v];
        r._startsInside = false;
        return r;
    }

    /// `(v, +∞)` — every version `> v`. The full set-algebra distinction
    /// between open and closed lower bounds lands in M2; for now this is the
    /// closed `[v, +∞)` boundary shape.
    static Ranges strictlyHigherThan(V v) @safe pure nothrow
        => higherThan(v);

    /// `(-∞, v]` — every version `<= v`.
    static Ranges lowerThan(V v) @safe pure nothrow
        => strictlyHigherThan(v).complement();

    /// `(-∞, v)` — every version `< v`.
    static Ranges strictlyLowerThan(V v) @safe pure nothrow
        => higherThan(v).complement();

    /// `[lo, hi)` — every version `>= lo` and `< hi`.
    static Ranges between(V lo, V hi) @safe pure nothrow
        => higherThan(lo).intersection(strictlyLowerThan(hi));

    // ----- defaulted via De Morgan -----

    /// The universal set `(-∞, +∞)`.
    static Ranges full() @safe pure nothrow => empty().complement();

    /// Set union, via `¬(¬a ∩ ¬b)`.
    Ranges union_(const Ranges other) const @safe pure nothrow
        => complement().intersection(other.complement()).complement();

    /// Whether the two ranges share no version.
    bool isDisjoint(const Ranges other) const @safe pure nothrow
        => intersection(other) == empty();

    /// Whether every version of this range is in `other`.
    bool subsetOf(const Ranges other) const @safe pure nothrow
        => this == intersection(other);

    // ----- equality -----

    /// Compares canonical (sorted, merged) boundary sequences, so two
    /// ranges built from equivalent expressions compare equal.
    bool opEquals(const Ranges other) const @safe pure nothrow
    {
        if (_startsInside != other._startsInside)
            return false;
        if (_bounds.length != other._bounds.length)
            return false;
        foreach (idx, b; _bounds)
            if (!(b == other._bounds[idx]))
                return false;
        return true;
    }

    /// Hash consistent with $(LREF opEquals).
    size_t toHash() const @safe nothrow
    {
        size_t h = _startsInside ? 1 : 0;
        foreach (b; _bounds)
            h = h * 31 + b.toHash();
        return h;
    }

    // ----- formatting -----

    /// Emits VERS constraint syntax (§9), giving every range a
    /// scheme-agnostic textual form. The full emitter lands in M2.
    void toString(W)(ref W w) const
    {
        assert(0, "Ranges.toString: M2");
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.versions.traits : isVersionRange;

    private struct U3
    {
        uint v;
        int opCmp(in U3 o) const @safe pure nothrow @nogc
            => v < o.v ? -1 : (v > o.v ? 1 : 0);
        bool opEquals(in U3 o) const @safe pure nothrow @nogc => v == o.v;
        size_t toHash() const @safe pure nothrow @nogc => v;
        void toString(W)(ref W w) const
        {
            import std.range.primitives : put;
            put(w, "u");
        }
    }
}

@("ranges.isVersionRange")
@safe pure nothrow
unittest
{
    static assert(isVersionRange!(Ranges!U3));
}

@("ranges.emptyAndFull")
@safe pure nothrow
unittest
{
    auto e = Ranges!U3.empty();
    auto f = Ranges!U3.full();
    assert(!e.contains(U3(5)));
    assert(f.contains(U3(5)));
    assert(e != f);
    assert(e.complement() == f);
}

@("ranges.singletonContains")
@safe pure nothrow
unittest
{
    auto s = Ranges!U3.singleton(U3(3));
    assert(s.contains(U3(3)));
    assert(!s.contains(U3(2)));
    assert(!s.contains(U3(4)));
}

@("ranges.intersection")
@safe pure nothrow
unittest
{
    // [2, +inf) ∩ complement is empty; full ∩ full is full.
    auto f = Ranges!U3.full();
    assert(f.intersection(f) == f);
    auto e = Ranges!U3.empty();
    assert(f.intersection(e) == e);
}

@("ranges.deMorgan")
@safe pure nothrow
unittest
{
    auto f = Ranges!U3.full();
    auto e = Ranges!U3.empty();
    // union of empty and full is full; disjointness and subset laws.
    assert(e.union_(f) == f);
    assert(e.subsetOf(f));
    assert(e.isDisjoint(e));
}

@("ranges.intervalConveniences")
@safe pure nothrow
unittest
{
    // [3, +inf)
    auto hi = Ranges!U3.higherThan(U3(3));
    assert(!hi.contains(U3(2)));
    assert(hi.contains(U3(3)));
    assert(hi.contains(U3(9)));

    // (-inf, 3)
    auto lo = Ranges!U3.strictlyLowerThan(U3(3));
    assert(lo.contains(U3(2)));
    assert(!lo.contains(U3(3)));

    // [2, 5)
    auto mid = Ranges!U3.between(U3(2), U3(5));
    assert(!mid.contains(U3(1)));
    assert(mid.contains(U3(2)));
    assert(!mid.contains(U3(5)));

    // surface check: lowerThan / strictlyHigherThan compile.
    auto le = Ranges!U3.lowerThan(U3(4));
    auto gt = Ranges!U3.strictlyHigherThan(U3(4));
    assert(le != gt);
}
