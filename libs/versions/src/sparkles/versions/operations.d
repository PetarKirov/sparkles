/**
Generic operations over the version concepts: `order`, `sort`, `satisfies`,
the caret/tilde range desugarings, and `truncateTo`.

Each operation pairs a baseline that needs only the required surface
($(REF isVersion, sparkles,versions,traits)) with an opt-in fast path or
extra behaviour gated on an optional capability — `hasOrderKey` for
`order`/`sort`, `supportsPrerelease` for the prerelease-in-range rule in
`satisfies`, and `hasSemVerComponents` for `caret`/`tilde`. `truncateTo`
needs only `hasComponents` (any arity).

See `docs/specs/versions/SPEC.md` §5.
*/
module sparkles.versions.operations;

import sparkles.versions.ranges : Ranges;
import sparkles.versions.traits :
    componentAt, hasComponents, hasOrderKey, hasSemVerComponents,
    isVersion, supportsPrerelease;

@safe:

// ---------------------------------------------------------------------------
// §5.1 — order: fast-path / fallback compare
// ---------------------------------------------------------------------------

/**
Three-way compares two versions, returning the same result as `a.opCmp(b)`
for any $(REF isVersion, sparkles,versions,traits). When `T` provides
`hasOrderKey`, the unsigned keys decide first and `opCmp` is consulted only
on a key tie; otherwise `order` is exactly `opCmp`.
*/
int order(T)(const T a, const T b) @safe pure nothrow @nogc
if (isVersion!T)
{
    static if (hasOrderKey!T)
    {
        const ka = a.orderKey, kb = b.orderKey;
        if (ka != kb)
            return ka < kb ? -1 : 1;   // keys differ → decisive
    }
    return a.opCmp(b);                  // fallback / tie-break
}

// ---------------------------------------------------------------------------
// §5.4 — sort
// ---------------------------------------------------------------------------

/**
Sorts a slice of versions ascending, in place, using $(LREF order) (so the
`hasOrderKey` fast path applies). Returns the same slice for chaining.
*/
T[] sort(T)(T[] versions) @safe
if (isVersion!T)
{
    import std.algorithm.sorting : sort;
    versions.sort!((a, b) => order(a, b) < 0);
    return versions;
}

// ---------------------------------------------------------------------------
// §5.2 — satisfies: version-in-range, prerelease-gated
// ---------------------------------------------------------------------------

/**
Reports whether `v` is admitted by `range`.

The base case is `range.contains(v)`. When `T` provides
`supportsPrerelease`, the node-semver **prerelease-in-range rule** applies:
a prerelease version satisfies the range only when at least one comparator
in the range names a prerelease of the same `(major, minor, patch)` triple.
A stable release is governed by plain containment.

The rule is defined over the `(major, minor, patch)` triple, so it also
requires `hasSemVerComponents`. A prerelease-capable scheme that lacks that
triple (e.g. `MavenVersion`, whose qualifiers have no major/minor/patch)
intentionally falls back to plain containment. When `T` models no
prereleases at all the rule is statically inert.
*/
bool satisfies(T)(const T v, in Ranges!T range) @safe
if (isVersion!T)
{
    if (!range.contains(v))
        return false;

    static if (supportsPrerelease!T && hasSemVerComponents!T)
    {
        if (v.isPrerelease)
        {
            // A prerelease is admitted only when a comparator names a
            // prerelease of the same major.minor.patch triple.
            bool sawSibling = false;
            const probe = v;
            range.eachBoundVersion((in T bound) @safe {
                if (boundIsPrerelease(bound) && sameTriple(bound, probe))
                    sawSibling = true;
            });
            return sawSibling;
        }
    }

    return true;
}

/// `v.isPrerelease` behind a non-scope param, so the membership lambda can
/// query a scope-`in` bound without tripping dip1000.
private bool boundIsPrerelease(T)(const T v) @safe pure nothrow @nogc
if (supportsPrerelease!T)
    => v.isPrerelease;

/// True when `a` and `b` share their first three (`major.minor.patch`)
/// components. Only valid for `hasSemVerComponents!T`.
private bool sameTriple(T)(const T a, const T b) @safe pure nothrow @nogc
if (hasSemVerComponents!T)
    => componentAt(a, 0) == componentAt(b, 0)
        && componentAt(a, 1) == componentAt(b, 1)
        && componentAt(a, 2) == componentAt(b, 2);

// ---------------------------------------------------------------------------
// §5.3 — caret / tilde
// ---------------------------------------------------------------------------

/**
The npm caret operator: `^1.2.3` admits every version `>= 1.2.3` and
`< 2.0.0` (compatible within the major). Constrained to schemes with the
SemVer triple (`hasSemVerComponents!V`); other schemes don't match, so
`caret` is a compile error for them — build the range explicitly instead.
*/
Ranges!V caret(V)(in V v) @safe
if (hasSemVerComponents!V)
{
    const upper = bumpComponent!(V, 0)(v); // next major, minor/patch zeroed
    return Ranges!V.between(stripExtras(v), upper);
}

/**
The npm tilde operator: `~1.2.3` admits every version `>= 1.2.3` and
`< 1.3.0` (compatible within the minor). Requires the SemVer triple.
*/
Ranges!V tilde(V)(in V v) @safe
if (hasSemVerComponents!V)
{
    const upper = bumpComponent!(V, 1)(v); // next minor, patch zeroed
    return Ranges!V.between(stripExtras(v), upper);
}

/// A copy of `v` with the `which`-th component incremented and every lower
/// component zeroed. Prerelease/build slots are cleared so the upper bound
/// is a clean stable boundary.
private V bumpComponent(V, size_t which)(const V v) @safe
if (hasComponents!V)
{
    V r;
    static foreach (i, name; V.components)
    {{
        alias FieldT = typeof(__traits(getMember, r, name));
        static if (i < which)
            __traits(getMember, r, name) = __traits(getMember, v, name);
        else static if (i == which)
            __traits(getMember, r, name) =
                cast(FieldT)(__traits(getMember, v, name) + 1);
        else
            __traits(getMember, r, name) = FieldT(0);
    }}
    return r;
}

/// A copy of `v` keeping only its numeric components — prerelease/build
/// slots dropped — so the lower bound of a caret/tilde range is the bare
/// triple the operator named.
private V stripExtras(V)(const V v) @safe
if (hasComponents!V)
{
    V r;
    static foreach (name; V.components)
        __traits(getMember, r, name) = __traits(getMember, v, name);
    static if (__traits(hasMember, V, "prerelease"))
        __traits(getMember, r, "prerelease") = __traits(getMember, v, "prerelease");
    return r;
}

// ---------------------------------------------------------------------------
// §5.5 — truncateTo
// ---------------------------------------------------------------------------

/**
Returns a copy of `v` with every component below `name` (in `components`
order) zeroed — useful for bucketing (group SemVer by `major.minor`, a
CalVer by `"month"`). `name` must appear in `T.components`, so this requires
`hasComponents!T` (any arity) and is a compile-time error otherwise.
*/
T truncateTo(string name, T)(in T v) @safe
if (hasComponents!T)
{
    static assert(componentIndex!(T, name) != size_t.max,
        "truncateTo!\"" ~ name ~ "\" requires \"" ~ name
        ~ "\" to appear in " ~ T.stringof ~ ".components.");

    enum keep = componentIndex!(T, name);
    T r;
    static foreach (i, comp; T.components)
        static if (i <= keep)
            __traits(getMember, r, comp) = __traits(getMember, v, comp);
    // Components below `keep` stay at their `.init` (zero) value.
    return r;
}

/// Index of `name` within `T.components`, or `size_t.max` when absent.
private template componentIndex(T, string name)
{
    enum componentIndex = () {
        static foreach (i, comp; T.components)
            if (comp == name)
                return i;
        return size_t.max;
    }();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.versions.schemes.semver : SemVer;
    import sparkles.versions.testing : checkParse;

    private SemVer sv(string s) @safe => checkParse!SemVer(s);
}

@("operations.order.matchesOpCmp")
@safe pure nothrow @nogc
unittest
{
    static immutable corpus = [
        "0.0.0", "0.0.1", "0.1.0", "1.0.0", "1.2.3", "2.0.0",
        "1.0.0-alpha", "1.0.0-beta", "1.0.0",
    ];
    foreach (i; 0 .. corpus.length)
        foreach (j; 0 .. corpus.length)
        {
            const a = SemVer.parse(corpus[i]).value;
            const b = SemVer.parse(corpus[j]).value;
            const o = order(a, b);
            const c = a.opCmp(b);
            // Same sign as opCmp.
            assert((o < 0) == (c < 0));
            assert((o > 0) == (c > 0));
            assert((o == 0) == (c == 0));
        }
}

@("operations.sort.ascending")
@safe
unittest
{
    auto xs = [sv("2.0.0"), sv("1.0.0-alpha"), sv("1.0.0"), sv("1.2.3")];
    sort(xs);
    foreach (i; 1 .. xs.length)
        assert(order(xs[i - 1], xs[i]) <= 0);
    assert(xs[0] == sv("1.0.0-alpha"));
    assert(xs[$ - 1] == sv("2.0.0"));
}

@("operations.satisfies.stableContainment")
@safe
unittest
{
    // >=1.2.0
    auto r = Ranges!SemVer.higherThan(sv("1.2.0"));
    assert(satisfies(sv("1.3.0"), r));   // stable release ≥ bound
    assert(satisfies(sv("1.2.0"), r));
    assert(!satisfies(sv("1.1.0"), r));
}

@("operations.satisfies.prereleaseRule")
@safe
unittest
{
    // >=1.2.0 (stable bound) — 1.3.0-beta.1 is numerically inside but no
    // comparator names a prerelease of the 1.3.0 triple.
    auto stableBound = Ranges!SemVer.higherThan(sv("1.2.0"));
    assert(!satisfies(sv("1.3.0-beta.1"), stableBound));

    // >=1.2.0-alpha — names a prerelease of the 1.2.0 triple, so a
    // prerelease of that same triple is admitted.
    auto preBound = Ranges!SemVer.higherThan(sv("1.2.0-alpha"));
    assert(satisfies(sv("1.2.0-beta.1"), preBound));
    // …but a prerelease of a *different* triple is still excluded.
    assert(!satisfies(sv("1.3.0-beta.1"), preBound));
}

@("operations.caret.range")
@safe
unittest
{
    // ^1.2.3 → [1.2.3, 2.0.0)
    auto r = caret(sv("1.2.3"));
    assert(r == Ranges!SemVer.between(sv("1.2.3"), sv("2.0.0")));
    assert(satisfies(sv("1.2.3"), r));
    assert(satisfies(sv("1.9.9"), r));
    assert(!satisfies(sv("2.0.0"), r));
    assert(!satisfies(sv("1.2.2"), r));
}

@("operations.tilde.range")
@safe
unittest
{
    // ~1.2.3 → [1.2.3, 1.3.0)
    auto r = tilde(sv("1.2.3"));
    assert(r == Ranges!SemVer.between(sv("1.2.3"), sv("1.3.0")));
    assert(satisfies(sv("1.2.3"), r));
    assert(satisfies(sv("1.2.9"), r));
    assert(!satisfies(sv("1.3.0"), r));
    assert(!satisfies(sv("1.2.2"), r));
}

@("operations.truncateTo.semver")
@safe
unittest
{
    // Bucket by major.minor: zero the patch.
    assert(truncateTo!"minor"(sv("1.2.3")) == sv("1.2.0"));
    // Bucket by major: zero minor and patch.
    assert(truncateTo!"major"(sv("1.2.3")) == sv("1.0.0"));
    // truncateTo!"patch" is a no-op on the numeric core.
    assert(truncateTo!"patch"(sv("1.2.3")).major == 1);
    assert(truncateTo!"patch"(sv("1.2.3")).minor == 2);
    assert(truncateTo!"patch"(sv("1.2.3")).patch == 3);
}

// A minimal non-SemVer component scheme, to verify caret/tilde reject it and
// truncateTo still works on its named components.
version (unittest)
{
    import sparkles.versions.traits : compareComponents;

    private struct CalDate
    {
        uint year, month, day;
        alias Version = CalDate;
        enum string[] components = ["year", "month", "day"];

        int opCmp(in CalDate o) const @safe pure nothrow @nogc
            => compareComponents(this, o);
        bool opEquals(in CalDate o) const @safe pure nothrow @nogc
            => opCmp(o) == 0;
        size_t toHash() const @safe pure nothrow @nogc
            => year ^ month ^ day;
        void toString(W)(ref W w) const
        {
            import std.range.primitives : put;
            put(w, "cal");
        }
    }
}

@("operations.caret.rejectsNonSemVer")
@safe pure nothrow @nogc
unittest
{
    import sparkles.versions.traits : hasComponents, hasSemVerComponents;
    static assert(hasComponents!CalDate);
    static assert(!hasSemVerComponents!CalDate);
    // caret/tilde must not instantiate for a calendar scheme.
    static assert(!__traits(compiles, caret(CalDate(2024, 5, 1))));
    static assert(!__traits(compiles, tilde(CalDate(2024, 5, 1))));
}

@("operations.truncateTo.calendar")
@safe pure nothrow @nogc
unittest
{
    // Bucket a calendar version by month: zero the day.
    assert(truncateTo!"month"(CalDate(2024, 5, 13)) == CalDate(2024, 5, 0));
    assert(truncateTo!"year"(CalDate(2024, 5, 13)) == CalDate(2024, 0, 0));
    // A name absent from components is a compile-time error.
    static assert(!__traits(compiles, truncateTo!"patch"(CalDate(2024, 5, 1))));
}
