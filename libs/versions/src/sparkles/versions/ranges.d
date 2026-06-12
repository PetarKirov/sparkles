/**
`Ranges!V` — the single concrete version-range type.

A version range is a set of versions expressed as set algebra. `Ranges!V`
stores a sorted, disjoint sequence of intervals and maintains those
invariants on every operation: segments stay sorted, no segment is empty,
and adjacent mergeable intervals coalesce. So two ranges built from
different but equivalent expressions compare equal.

The interval algebra is a direct port of
[pubgrub's `version-ranges`](https://github.com/pubgrub-rs/pubgrub) crate:
each interval is a `(lower, upper)` pair of $(LREF Bound)s (unbounded, or a
value with an inclusive flag). The required set-algebra basis
(`empty`/`singleton`/`complement`/`intersection`/`contains`) is implemented
directly; `full`/`union_`/`isDisjoint`/`subsetOf` and the interval
conveniences round out the [`isVersionRange`](sparkles.versions.traits)
surface. `toString` emits VERS constraint syntax (SPEC §9).

`Ranges!V` is generic over any
[`isVersion!V`](sparkles.versions.traits): the algebra uses only `opCmp`
(via D's `<`/`==`), never scheme internals.

See `docs/specs/versions/SPEC.md` §4 (the Range concept) and §9 (VERS
constraint syntax).
*/
module sparkles.versions.ranges;

import sparkles.versions.traits : isVersion;

// ---------------------------------------------------------------------------
// Bound
// ---------------------------------------------------------------------------

/// Which kind of endpoint an interval bound is.
private enum BoundKind : ubyte
{
    /// `-∞` (as a lower bound) or `+∞` (as an upper bound).
    unbounded,
    /// The endpoint value is part of the interval (`[v` or `v]`).
    included,
    /// The endpoint value is excluded from the interval (`(v` or `v)`).
    excluded,
}

/**
One endpoint of an interval: either unbounded, or a concrete version with an
inclusive/exclusive flag.

The version value is stored as `const(V)`: bounds are logically immutable
snapshots, so this lets schemes whose value carries mutable indirection
(e.g. PyPI's `uint[] release`) be used as bounds without an illegal
`const(V) -> V` copy. The interval algorithms never reassign a `Bound` in
place — they build fresh segments — so the const field is no obstacle.
*/
private struct Bound(V)
{
    BoundKind kind;
    const(V) value;

    static Bound unbounded() @safe pure nothrow
        => Bound(BoundKind.unbounded);
    static Bound included(const V v) @safe pure nothrow
        => Bound(BoundKind.included, v);
    static Bound excluded(const V v) @safe pure nothrow
        => Bound(BoundKind.excluded, v);

    bool isUnbounded() const @safe pure nothrow @nogc
        => kind == BoundKind.unbounded;
}

// ---------------------------------------------------------------------------
// Interval
// ---------------------------------------------------------------------------

private struct Interval(V)
{
    Bound!V lower;
    Bound!V upper;
}

/// A valid segment is one where at least one version fits between the
/// bounds. (Singletons `[v, v]` are valid.)
private bool validSegment(V)(const Bound!V lo, const Bound!V hi) @safe pure nothrow
{
    if (lo.isUnbounded || hi.isUnbounded)
        return true;
    // Both concrete.
    if (lo.kind == BoundKind.included && hi.kind == BoundKind.included)
        return !(hi.value < lo.value);          // lo <= hi
    return lo.value < hi.value;                  // any exclusive end ⇒ lo < hi
}

/// `left.end <= right.end` for upper bounds. Mirror of pubgrub's
/// `left_end_is_smaller`.
private bool endLE(V)(const Bound!V left, const Bound!V right) @safe pure nothrow
{
    if (right.isUnbounded)
        return true;
    if (left.isUnbounded)
        return false;
    // Excluded < Included at the same value (the excluded end is "earlier").
    if (left.kind == BoundKind.included && right.kind == BoundKind.excluded)
        return left.value < right.value;
    return !(right.value < left.value);          // left.value <= right.value
}

// ---------------------------------------------------------------------------
// Ranges
// ---------------------------------------------------------------------------

/**
A sorted, disjoint set of version intervals.

The set is an ascending list of non-overlapping, non-adjacent intervals.
The empty set has no intervals; `full` is the single unbounded interval
`(-∞, +∞)`. Every operation re-establishes the invariants (sorted,
non-empty segments, gap between segments), so the representation is
canonical and drives a structural `opEquals`.
*/
struct Ranges(V) if (isVersion!V)
{
    /// The version type this range constrains.
    alias Version = V;

    private alias Bnd = Bound!V;
    private alias Seg = Interval!V;

    // Invariant: ascending, disjoint, non-empty, gap-separated segments.
    private Seg[] _segs;

    // ----- required set-algebra basis -----

    /// The empty set.
    static Ranges empty() @safe pure nothrow
        => Ranges.init;

    /// The set `{v}`, stored as the closed point `[v, v]`.
    ///
    /// `v` is taken as `const V` (like the underlying `Bound`) so a scheme
    /// whose value carries mutable indirection (Maven's `Token[]`, PyPI's
    /// `uint[] release`) can be used as a bound without an illegal
    /// `const(V) -> V` copy.
    static Ranges singleton(const V v) @safe pure nothrow
    {
        Ranges r;
        r._segs = [Seg(Bnd.included(v), Bnd.included(v))];
        return r;
    }

    /// Set complement. Walks the sorted intervals, emitting the gaps between
    /// them (a direct port of pubgrub's `complement`/`negate_segments`).
    Ranges complement() const @safe pure nothrow
    {
        if (_segs.length == 0)
            return full();

        Ranges r;
        // The complement is the sequence of gaps: (-∞, first.lower), each
        // (prev.upper, next.lower), and (last.upper, +∞). A gap is emitted
        // only when both its ends are concrete-or-infinite in a way that
        // leaves room; an interval that already reaches an infinity drops the
        // corresponding gap. We never reassign a `Bound` in place — each gap's
        // ends are built fresh from the adjacent segments' flipped bounds.

        // Leading gap (-∞, first.lower), unless the first interval opens at -∞.
        if (!_segs[0].lower.isUnbounded)
            r._segs ~= Seg(Bnd.unbounded(), flip(_segs[0].lower));

        // Interior gaps (prev.upper, next.lower).
        foreach (k; 1 .. _segs.length)
            r._segs ~= Seg(flip(_segs[k - 1].upper), flip(_segs[k].lower));

        // Trailing gap (last.upper, +∞), unless the last interval reaches +∞.
        if (!_segs[$ - 1].upper.isUnbounded)
            r._segs ~= Seg(flip(_segs[$ - 1].upper), Bnd.unbounded());

        return r;
    }

    /// Set intersection of two ranges. Walks both sorted interval lists,
    /// emitting candidate intersections with increasing `end` (a port of
    /// pubgrub's `intersection`).
    Ranges intersection(const Ranges other) const @safe pure nothrow
    {
        Ranges r;
        size_t i, j;
        while (i < _segs.length && j < other._segs.length)
        {
            const a = _segs[i];
            const b = other._segs[j];

            // The smaller `end` decides which interval to advance. We bind
            // `end`/`otherStart` once (no in-place `Bound` reassignment, which
            // the const value field forbids) and step the chosen cursor.
            const aEndSmaller = endLE(a.upper, b.upper);
            const Bnd end = aEndSmaller ? a.upper : b.upper;
            const Bnd otherStart = aEndSmaller ? b.lower : a.lower;
            if (aEndSmaller)
                i++;
            else
                j++;

            // The other interval's lower bound must fit under `end`.
            if (!validSegment(otherStart, end))
                continue;

            // Start = the larger (later) of the two lower bounds.
            const start = laterLower(a.lower, b.lower);
            r._segs ~= Seg(start, end);
        }
        return r;
    }

    /// Membership test. Binary-search-free linear walk: a version is in the
    /// set iff it falls within one of the sorted intervals.
    bool contains(const V v) const @safe pure nothrow
    {
        foreach (seg; _segs)
        {
            // Below this interval's lower bound ⇒ below all later ones too.
            if (belowLower(v, seg.lower))
                return false;
            if (withinUpper(v, seg.upper))
                return true;
            // else: above this interval, keep scanning.
        }
        return false;
    }

    // ----- interval conveniences -----

    /// `[v, +∞)` — every version `>= v`. Bounds are taken as `const V` (see
    /// $(LREF singleton)) so schemes with mutable indirection work as bounds.
    static Ranges higherThan(const V v) @safe pure nothrow
        => single(Bnd.included(v), Bnd.unbounded());

    /// `(v, +∞)` — every version `> v`.
    static Ranges strictlyHigherThan(const V v) @safe pure nothrow
        => single(Bnd.excluded(v), Bnd.unbounded());

    /// `(-∞, v]` — every version `<= v`.
    static Ranges lowerThan(const V v) @safe pure nothrow
        => single(Bnd.unbounded(), Bnd.included(v));

    /// `(-∞, v)` — every version `< v`.
    static Ranges strictlyLowerThan(const V v) @safe pure nothrow
        => single(Bnd.unbounded(), Bnd.excluded(v));

    /// `[lo, hi)` — every version `>= lo` and `< hi`.
    static Ranges between(const V lo, const V hi) @safe pure nothrow
        => single(Bnd.included(lo), Bnd.excluded(hi));

    // ----- defaulted via De Morgan -----

    /// The universal set `(-∞, +∞)`.
    static Ranges full() @safe pure nothrow
        => single(Bnd.unbounded(), Bnd.unbounded());

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

    /// Compares canonical (sorted, merged) interval sequences, so two ranges
    /// built from equivalent expressions compare equal.
    bool opEquals(const Ranges other) const @safe pure nothrow
    {
        if (_segs.length != other._segs.length)
            return false;
        foreach (idx, seg; _segs)
        {
            const o = other._segs[idx];
            if (!boundEq(seg.lower, o.lower) || !boundEq(seg.upper, o.upper))
                return false;
        }
        return true;
    }

    /// Hash consistent with $(LREF opEquals).
    size_t toHash() const @safe nothrow
    {
        size_t h = _segs.length;
        foreach (seg; _segs)
        {
            h = h * 31 + seg.lower.kind;
            if (!seg.lower.isUnbounded)
                h = h * 31 + seg.lower.value.toHash();
            h = h * 31 + seg.upper.kind;
            if (!seg.upper.isUnbounded)
                h = h * 31 + seg.upper.value.toHash();
        }
        return h;
    }

    // ----- formatting -----

    /**
    Emits VERS constraint syntax (SPEC §9): a `>=`/`>`/`<=`/`<` comparator per
    interval bound (or a bare version for a singleton, or `*` for `full`), with
    every comparator separated by `|`. A bounded interval `[lo, hi)` therefore
    renders as two `|`-joined comparators `>=lo|<hi` — VERS has no AND-comma;
    the sorted-constraint fold in $(REF parseVersAs, sparkles,versions,vers)
    re-pairs the flat `|`-list back into intervals.

    The empty set has no satisfying version and so no comparator; it renders
    as the empty string. (VERS has no canonical literal for the empty
    constraint; the `vers:` URI layer is responsible for handling a
    constraint-less segment.)
    */
    void toString(W)(ref W w) const
    {
        import std.range.primitives : put;

        if (_segs.length == 0)
            return;                              // empty set ⇒ no comparators

        foreach (idx, seg; _segs)
        {
            if (idx > 0)
                put(w, "|");
            writeSegment(w, seg);
        }
    }

    // ----- bound inspection (package-internal) -----

    /**
    Calls `sink(v)` for every concrete bound version appearing in the
    interval list (lower and upper endpoints; unbounded endpoints are
    skipped). Used by `sparkles.versions.operations.satisfies` to apply the
    prerelease-in-range rule, which inspects the versions a range's
    comparators name without exposing the private interval representation.
    */
    package void eachBoundVersion(scope void delegate(in V) @safe sink) const @safe
    {
        foreach (seg; _segs)
        {
            if (!seg.lower.isUnbounded)
                sink(seg.lower.value);
            if (!seg.upper.isUnbounded)
                sink(seg.upper.value);
        }
    }

    // ----- internals -----

    private static Ranges single(Bnd lo, Bnd hi) @safe pure nothrow
    {
        Ranges r;
        r._segs = [Seg(lo, hi)];
        return r;
    }

    /// Flips an inclusive bound to exclusive and vice versa (for complement).
    private static Bnd flip(const Bnd b) @safe pure nothrow
    {
        final switch (b.kind)
        {
        case BoundKind.included:
            return Bnd.excluded(b.value);
        case BoundKind.excluded:
            return Bnd.included(b.value);
        case BoundKind.unbounded:
            return Bnd.unbounded();              // unreachable in practice
        }
    }

    /// The later (greater) of two lower bounds — the intersection's start.
    private static Bnd laterLower(const Bnd a, const Bnd b) @safe pure nothrow
    {
        if (a.isUnbounded)
            return b;
        if (b.isUnbounded)
            return a;
        if (a.kind == b.kind)
            return (a.value < b.value) ? b : a;
        // One included, one excluded.
        const inc = a.kind == BoundKind.included ? a : b;
        const exc = a.kind == BoundKind.included ? b : a;
        // At the same value the excluded bound is the later (stricter) start.
        return !(exc.value < inc.value) ? exc : inc;  // exc.value >= inc.value
    }

    /// Is `v` strictly below this interval's lower bound?
    private static bool belowLower(const V v, const Bnd lo) @safe pure nothrow
    {
        final switch (lo.kind)
        {
        case BoundKind.unbounded:
            return false;
        case BoundKind.included:
            return v < lo.value;
        case BoundKind.excluded:
            return !(lo.value < v);              // v <= lo.value
        }
    }

    /// Is `v` within (at or below) this interval's upper bound?
    private static bool withinUpper(const V v, const Bnd hi) @safe pure nothrow
    {
        final switch (hi.kind)
        {
        case BoundKind.unbounded:
            return true;
        case BoundKind.included:
            return !(hi.value < v);              // v <= hi.value
        case BoundKind.excluded:
            return v < hi.value;
        }
    }

    private static bool boundEq(const Bnd a, const Bnd b) @safe pure nothrow
    {
        if (a.kind != b.kind)
            return false;
        if (a.isUnbounded)
            return true;
        return a.value == b.value;
    }

    private static void writeSegment(W)(ref W w, const Seg seg)
    {
        import std.range.primitives : put;

        const lo = seg.lower;
        const hi = seg.upper;

        // Full interval.
        if (lo.isUnbounded && hi.isUnbounded)
        {
            put(w, "*");
            return;
        }
        // Singleton `[v, v]` renders as a bare version.
        if (lo.kind == BoundKind.included && hi.kind == BoundKind.included
            && lo.value == hi.value)
        {
            lo.value.toString(w);
            return;
        }

        bool wroteLower;
        if (!lo.isUnbounded)
        {
            put(w, lo.kind == BoundKind.included ? ">=" : ">");
            lo.value.toString(w);
            wroteLower = true;
        }
        if (!hi.isUnbounded)
        {
            if (wroteLower)
                put(w, "|");
            put(w, hi.kind == BoundKind.included ? "<=" : "<");
            hi.value.toString(w);
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.versions.traits : isVersionRange;

    // A minimal conforming version: a single unsigned coordinate. Concrete
    // enough to exercise the interval algebra and `toString`.
    private struct U3
    {
        uint v;
        int opCmp(in U3 o) const @safe pure nothrow @nogc
            => v < o.v ? -1 : (v > o.v ? 1 : 0);
        bool opEquals(in U3 o) const @safe pure nothrow @nogc => v == o.v;
        size_t toHash() const @safe pure nothrow @nogc => v;
        void toString(W)(ref W w) const
        {
            import sparkles.base.text.writers : writeInteger;
            writeInteger(w, v);
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
    assert(f.complement() == e);
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

@("ranges.intervalConveniences")
@safe pure nothrow
unittest
{
    // [3, +inf)
    auto hi = Ranges!U3.higherThan(U3(3));
    assert(!hi.contains(U3(2)));
    assert(hi.contains(U3(3)));
    assert(hi.contains(U3(9)));

    // (3, +inf)
    auto sh = Ranges!U3.strictlyHigherThan(U3(3));
    assert(!sh.contains(U3(3)));
    assert(sh.contains(U3(4)));

    // (-inf, 3]
    auto le = Ranges!U3.lowerThan(U3(3));
    assert(le.contains(U3(3)));
    assert(!le.contains(U3(4)));

    // (-inf, 3)
    auto lo = Ranges!U3.strictlyLowerThan(U3(3));
    assert(lo.contains(U3(2)));
    assert(!lo.contains(U3(3)));

    // [2, 5)
    auto mid = Ranges!U3.between(U3(2), U3(5));
    assert(!mid.contains(U3(1)));
    assert(mid.contains(U3(2)));
    assert(mid.contains(U3(4)));
    assert(!mid.contains(U3(5)));
}

@("ranges.intersection")
@safe pure nothrow
unittest
{
    auto f = Ranges!U3.full();
    auto e = Ranges!U3.empty();
    assert(f.intersection(f) == f);
    assert(f.intersection(e) == e);

    // [2, 8) ∩ [5, 10) == [5, 8)
    auto a = Ranges!U3.between(U3(2), U3(8));
    auto b = Ranges!U3.between(U3(5), U3(10));
    auto x = a.intersection(b);
    assert(!x.contains(U3(4)));
    assert(x.contains(U3(5)));
    assert(x.contains(U3(7)));
    assert(!x.contains(U3(8)));
    assert(x == Ranges!U3.between(U3(5), U3(8)));
}

@("ranges.union")
@safe pure nothrow
unittest
{
    // [1, 3) ∪ [5, 7) is two disjoint segments.
    auto a = Ranges!U3.between(U3(1), U3(3));
    auto b = Ranges!U3.between(U3(5), U3(7));
    auto u = a.union_(b);
    assert(u.contains(U3(1)));
    assert(u.contains(U3(2)));
    assert(!u.contains(U3(3)));
    assert(!u.contains(U3(4)));
    assert(u.contains(U3(5)));
    assert(!u.contains(U3(7)));

    // Overlapping intervals merge.
    auto c = Ranges!U3.between(U3(1), U3(5));
    auto d = Ranges!U3.between(U3(3), U3(8));
    assert(c.union_(d) == Ranges!U3.between(U3(1), U3(8)));
}

@("ranges.deMorgan")
@safe pure nothrow
unittest
{
    auto a = Ranges!U3.between(U3(2), U3(6));
    auto b = Ranges!U3.between(U3(4), U3(9));

    // ¬(A ∪ B) == ¬A ∩ ¬B
    assert(a.union_(b).complement()
        == a.complement().intersection(b.complement()));
    // ¬(A ∩ B) == ¬A ∪ ¬B
    assert(a.intersection(b).complement()
        == a.complement().union_(b.complement()));
}

@("ranges.subsetAndDisjoint")
@safe pure nothrow
unittest
{
    auto small = Ranges!U3.between(U3(3), U3(5));
    auto big = Ranges!U3.between(U3(1), U3(9));
    assert(small.subsetOf(big));
    assert(!big.subsetOf(small));

    auto left = Ranges!U3.between(U3(1), U3(3));
    auto right = Ranges!U3.between(U3(5), U3(7));
    assert(left.isDisjoint(right));
    assert(!left.isDisjoint(big));
}

@("ranges.toString.versSyntax")
@safe pure nothrow
unittest
{
    import sparkles.base.smallbuffer : checkToString;

    checkToString(Ranges!U3.full(), "*");
    checkToString(Ranges!U3.singleton(U3(3)), "3");
    checkToString(Ranges!U3.higherThan(U3(2)), ">=2");
    checkToString(Ranges!U3.strictlyHigherThan(U3(2)), ">2");
    checkToString(Ranges!U3.lowerThan(U3(5)), "<=5");
    checkToString(Ranges!U3.strictlyLowerThan(U3(5)), "<5");
    checkToString(Ranges!U3.between(U3(2), U3(5)), ">=2|<5");

    // Disjoint union renders every comparator separated by `|` (VERS has no
    // AND-comma); the bounds of each interval are `|`-joined too.
    auto u = Ranges!U3.between(U3(1), U3(3))
        .union_(Ranges!U3.between(U3(5), U3(7)));
    checkToString(u, ">=1|<3|>=5|<7");
}

// ---------------------------------------------------------------------------
// Property tests — set-algebra laws over a concrete scheme.
// ---------------------------------------------------------------------------

version (unittest)
{
    // A small, deterministic corpus of ranges over `U3`, plus the universe of
    // points used to verify membership-level equivalences. Keeping the corpus
    // closed under the constructors exercises multi-segment cases.
    private Ranges!U3[] propCorpus() @safe pure nothrow
    {
        alias R = Ranges!U3;
        auto a = R.between(U3(2), U3(6));
        auto b = R.between(U3(4), U3(9));
        auto c = R.singleton(U3(7));
        auto d = R.higherThan(U3(5));
        auto e = R.strictlyLowerThan(U3(4));
        return [
            R.empty(), R.full(),
            a, b, c, d, e,
            a.union_(c),                 // two disjoint segments
            b.intersection(d),
            a.complement(),
            d.union_(e),                 // gap in the middle
        ];
    }

    private bool sameMembership(Ranges!U3 x, Ranges!U3 y) @safe pure nothrow
    {
        foreach (uint p; 0 .. 12)
            if (x.contains(U3(p)) != y.contains(U3(p)))
                return false;
        return true;
    }
}

@("ranges.laws.deMorgan")
@safe pure nothrow
unittest
{
    foreach (a; propCorpus())
        foreach (b; propCorpus())
        {
            // ¬(A ∪ B) == ¬A ∩ ¬B
            assert(a.union_(b).complement()
                == a.complement().intersection(b.complement()));
            // ¬(A ∩ B) == ¬A ∪ ¬B
            assert(a.intersection(b).complement()
                == a.complement().union_(b.complement()));
        }
}

@("ranges.laws.idempotenceAndDoubleComplement")
@safe pure nothrow
unittest
{
    foreach (a; propCorpus())
    {
        assert(a.intersection(a) == a);          // A ∩ A == A
        assert(a.union_(a) == a);                 // A ∪ A == A
        assert(a.complement().complement() == a); // ¬¬A == A
    }
}

@("ranges.laws.absorption")
@safe pure nothrow
unittest
{
    foreach (a; propCorpus())
        foreach (b; propCorpus())
        {
            // A ∪ (A ∩ B) == A
            assert(a.union_(a.intersection(b)) == a);
            // A ∩ (A ∪ B) == A
            assert(a.intersection(a.union_(b)) == a);
        }
}

@("ranges.laws.subsetDisjointConsistency")
@safe pure nothrow
unittest
{
    foreach (a; propCorpus())
        foreach (b; propCorpus())
        {
            assert(a.subsetOf(b) == (a == a.intersection(b)));
            assert(a.isDisjoint(b) == (a.intersection(b) == Ranges!U3.empty()));
            // Intersection is the meet ⇒ a subset of both inputs.
            assert(a.intersection(b).subsetOf(a));
            assert(a.intersection(b).subsetOf(b));
        }
}

@("ranges.laws.containsAgreesWithAlgebra")
@safe pure nothrow
unittest
{
    foreach (a; propCorpus())
        foreach (b; propCorpus())
        {
            // contains distributes over the set operations.
            foreach (uint p; 0 .. 12)
            {
                const v = U3(p);
                assert(a.intersection(b).contains(v)
                    == (a.contains(v) && b.contains(v)));
                assert(a.union_(b).contains(v)
                    == (a.contains(v) || b.contains(v)));
                assert(a.complement().contains(v) == !a.contains(v));
            }
            // subsetOf implies pointwise containment over the sampled points.
            if (a.subsetOf(b))
                assert(sameMembership(a, a.intersection(b)));
        }
}
