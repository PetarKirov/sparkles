/**
Compile-time concepts and optional-capability vocabulary for version
schemes.

A version is totally ordered and renders to text — that is the entire
required surface ($(LREF isVersion)). Everything else is an independently
detectable, opt-in capability: a type that provides one enables a fast path
or an extra feature; a type that omits one still works through the required
surface. Generic algorithms `static if` on the capability traits and fall
back to `opCmp`/`toString` when a capability is absent.

See `docs/specs/versions/SPEC.md` §3 (the Version concept), §4 (the Range
concept), and §6 (the Scheme concept).
*/
module sparkles.versions.traits;

import std.traits : isUnsigned;

import sparkles.versions.parsing : ParseExpected;

// ---------------------------------------------------------------------------
// §3.1 — Required surface: isVersion
// ---------------------------------------------------------------------------

/// `T` offers a three-way, `int`-convertible `opCmp` (a total order).
/// One half of $(LREF isVersion); reports which side is missing.
enum hasOpCmp(T) = __traits(compiles, (const T a, const T b) {
    int r = a.opCmp(b);                   // three-way order, int-convertible
});

/// `T` renders via an output-range `toString(sink)`. The other half of
/// $(LREF isVersion).
enum hasToString(T) = __traits(compiles, (const T v) {
    void delegate(scope const(char)[]) @safe sink;
    v.toString(sink);                     // exact output-range call
});

/**
A type is a version when it offers a three-way `opCmp` (a total order) and
an output-range `toString`. The named sub-checks $(LREF hasOpCmp) /
$(LREF hasToString) report which half is missing.
*/
enum isVersion(T) = hasOpCmp!T && hasToString!T;

// ---------------------------------------------------------------------------
// §3.2 — Optional capability vocabulary
// ---------------------------------------------------------------------------

/**
Monotonic unsigned-integer key of any width (`ubyte` … `ulong`): the scheme
picks the narrowest type that fits its components, so a compact scheme can
expose a `uint` (or smaller) key for narrower comparisons and tighter
`Ranges!T` bound storage. Where present,
`sign(a.orderKey <=> b.orderKey) == sign(a <=> b)` whenever the keys differ;
equal keys fall through to `opCmp`. (`isUnsigned` excludes `bool` and the
character types, so a stray `bool`/`char` member does not accidentally
qualify.)
*/
enum hasOrderKey(T) =
    is(typeof(T.init.orderKey()) KeyT) && isUnsigned!KeyT;

/**
The unsigned integer type a scheme's `orderKey` returns — `uint` for a
4-byte scheme, `ulong` for SemVer. Only valid when `hasOrderKey!T`; generic
code uses it to size compact key storage.
*/
alias OrderKeyType(T) = typeof(T.init.orderKey());

/// True when `T` exposes a `bool isPrerelease` accessor, gating the
/// prerelease-in-range rule in `satisfies`.
enum supportsPrerelease(T) =
    is(typeof({ const T v; bool b = v.isPrerelease; }));

/**
A version exposing an ordered list of named numeric components.

`T.components` is a compile-time `string[]` of readable unsigned-int member
names, most-significant first (the order `opCmp` compares and `toString`
prints them in). Arity is free: 3 for SemVer, 4 for .NET / Windows,
`["year","month","day"]` for CalVer. Generic code iterates the list to
compare, truncate, and bucket without hardcoding names.
*/
template hasComponents(T)
{
    static if (is(typeof(T.components) : const(string)[]))
        enum hasComponents = T.components.length >= 1 && allComponentsUnsigned!T;
    else
        enum hasComponents = false;
}

// The value type produced by *reading* a component, whether the component
// is a plain field or a (const) accessor method — `typeof` of the bare
// member would otherwise be the function type, never an unsigned integer.
private alias ComponentReadType(T, string name) =
    typeof(() { const T v; return __traits(getMember, v, name); }());

private enum bool allComponentsUnsigned(T) = () {
    bool ok = true;
    static foreach (name; T.components)
        static if (!__traits(hasMember, T, name)
                || !isUnsigned!(ComponentReadType!(T, name)))
            ok = false;
    return ok;
}();

/**
True when the list begins with the SemVer triple, so caret `^` / tilde `~`
have their conventional "compatible within major/minor" meaning. A
4-component or calendar scheme has `hasComponents` but not this, so it
correctly gets no caret operator.
*/
enum hasSemVerComponents(T) =
    hasComponents!T && T.components.length >= 3
    && T.components[0] == "major"
    && T.components[1] == "minor"
    && T.components[2] == "patch";

/// True when `T` exposes build metadata (`.build` returning
/// `const(char)[]`), enabling build-aware comparison.
enum hasBuildMetadata(T) =
    is(typeof({ const T v; const(char)[] b = v.build; }));

// ---------------------------------------------------------------------------
// Component helpers (driven by `T.components`)
// ---------------------------------------------------------------------------

/// Number of named components `T` declares. Only valid when
/// `hasComponents!T`.
enum size_t componentCount(T) = T.components.length;

/// Reads the `i`-th component of `v` (in `components` order) as a `ulong`.
ulong componentAt(T)(in T v, size_t i) @safe pure nothrow @nogc
if (hasComponents!T)
{
    static foreach (idx, name; T.components)
        if (idx == i)
            return cast(ulong) __traits(getMember, v, name);
    return 0;
}

/// Three-way compares the numeric components of `a` and `b`
/// most-significant-first. Used by schemes inside their `opCmp` and by
/// generic algorithms that need a component-only compare.
int compareComponents(T)(in T a, in T b) @safe pure nothrow @nogc
if (hasComponents!T)
{
    static foreach (name; T.components)
    {{
        const x = cast(ulong) __traits(getMember, a, name);
        const y = cast(ulong) __traits(getMember, b, name);
        if (x != y)
            return x < y ? -1 : 1;
    }}
    return 0;
}

// ---------------------------------------------------------------------------
// §4.1 — Required surface: isVersionRange
// ---------------------------------------------------------------------------

/**
A range is the minimal set-algebra basis: an associated `Version`, the
`empty`/`singleton` constructors, `complement`, `intersection`, and the
`contains` membership test. `full`, `union_`, `isDisjoint`, and `subsetOf`
are derived by default and need not be hand-written.
*/
template isVersionRange(R)
{
    enum isVersionRange =
        is(R.Version) && isVersion!(R.Version) &&
        is(typeof(R.empty()) == R) &&
        is(typeof(R.singleton(R.Version.init)) == R) &&
        is(typeof({ const R r; return r.complement(); }()) : R) &&
        is(typeof({ const R a, b; return a.intersection(b); }()) : R) &&
        is(typeof({
            const R r; const R.Version v; return r.contains(v);
        }()) : bool);
}

// ---------------------------------------------------------------------------
// §6.1 — Required surface: isVersionScheme
// ---------------------------------------------------------------------------

/**
A scheme is the handle the library parses through and identifies by pURL
type. The struct is both the version value and the scheme handle: it carries
the `Version` alias, a non-empty `purlType` string, and a static `parse`
returning `ParseExpected!(S.Version)`.
*/
template isVersionScheme(S)
{
    enum isVersionScheme =
        is(S.Version) && isVersion!(S.Version) &&
        is(typeof(S.purlType) : string) && S.purlType.length > 0 &&
        is(typeof(S.parse("")) : ParseExpected!(S.Version));
}

// ---------------------------------------------------------------------------
// §6.2 — Optional scheme capabilities
// ---------------------------------------------------------------------------

/// True when `S` parses its ecosystem's native range grammar via
/// `parseNativeRange`, returning a `ParseExpected!(Ranges!(S.Version))`.
enum supportsNativeRange(S) =
    is(typeof(S.parseNativeRange("")) : ParseExpected!(rangeTypeOf!S));

/// True when `S` accepts compatibility forms via `parseLoose`
/// (`v1.2`, `1`, …), returning a `ParseExpected!(S.Version)`.
enum supportsLooseParse(S) =
    is(typeof(S.parseLoose("")) : ParseExpected!(S.Version));

/// The `Ranges!(S.Version)` type, named via the scheme's own `Range` alias
/// so the trait does not import `ranges` (avoiding a cycle).
private alias rangeTypeOf(S) = S.Range;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.versions.parsing : NoGcHook, ParseError, ParseErrorCode;
    import sparkles.versions.parsing : parseOk, parseErr;

    // A minimal conforming version + scheme used to exercise the traits
    // without depending on a concrete scheme module.
    private struct ProbeVersion
    {
        uint major, minor, patch;
        alias Version = ProbeVersion;
        enum string purlType = "probe";
        enum string[] components = ["major", "minor", "patch"];

        int opCmp(in ProbeVersion o) const @safe pure nothrow @nogc
            => compareComponents(this, o);
        bool opEquals(in ProbeVersion o) const @safe pure nothrow @nogc
            => opCmp(o) == 0;
        size_t toHash() const @safe pure nothrow @nogc
            => major ^ minor ^ patch;
        void toString(W)(ref W w) const
        {
            import std.range.primitives : put;
            put(w, "probe");
        }

        ulong orderKey() const @safe pure nothrow @nogc => major;

        static ParseExpected!ProbeVersion parse(string)
            => parseOk(ProbeVersion.init);
    }
}

@("traits.isVersion.probe")
@safe pure nothrow @nogc
unittest
{
    static assert(isVersion!ProbeVersion);
    static assert(hasOpCmp!ProbeVersion);
    static assert(hasToString!ProbeVersion);
    static assert(!isVersion!int);
    static assert(!hasOpCmp!int);
    static assert(!hasToString!int);
}

@("traits.isVersionScheme.probe")
@safe pure nothrow @nogc
unittest
{
    static assert(isVersionScheme!ProbeVersion);
}

@("traits.capabilities.probe")
@safe pure nothrow @nogc
unittest
{
    static assert(hasOrderKey!ProbeVersion);
    static assert(is(OrderKeyType!ProbeVersion == ulong));
    static assert(hasComponents!ProbeVersion);
    static assert(hasSemVerComponents!ProbeVersion);
    static assert(componentCount!ProbeVersion == 3);
    static assert(!supportsPrerelease!ProbeVersion);
    static assert(!hasBuildMetadata!ProbeVersion);
    static assert(!supportsNativeRange!ProbeVersion);
    static assert(!supportsLooseParse!ProbeVersion);
}

@("traits.componentHelpers")
@safe pure nothrow @nogc
unittest
{
    ProbeVersion a = {major: 1, minor: 2, patch: 3};
    ProbeVersion b = {major: 1, minor: 5, patch: 0};
    assert(componentAt(a, 0) == 1);
    assert(componentAt(a, 1) == 2);
    assert(componentAt(a, 2) == 3);
    assert(compareComponents(a, b) < 0);
    assert(compareComponents(b, a) > 0);
    assert(compareComponents(a, a) == 0);
}
