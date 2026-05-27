/**
Design-by-Introspection versioning engine.

The $(LREF Version) template is parameterised by a $(I Layout) type whose
bitfield members are declared via the $(LREF layoutBody) mixin. The mixin
emits both the bit storage and a static `descriptor` describing every
component and the optional internal flag.

See `docs/specs/versions/SPEC.md` for the full specification.
*/
module sparkles.versions.engine;

import std.bitmanip : bitfields;
import std.traits : isIntegral, isUnsigned;

@safe:

// ---------------------------------------------------------------------------
// DbI vocabulary
// ---------------------------------------------------------------------------

/**
Tags a layout component that participates in the version's printed form
and (by default) in comparison.

`printOrder` controls the formatting sequence; smaller values print first.
`printWidth` is the minimum number of digits emitted by `toString` and
required by the parser. `printWidth == 0` means "no padding, no width
constraint" and is the natural default. Width is a $(B static) property
of the layout, not a per-instance value.
*/
struct Component
{
    int printOrder;     /// Formatting sequence (smaller = earlier).
    int printWidth = 0; /// Minimum-digit width (0 = unpadded / unconstrained).
}

/**
Marker UDA for a 1-bit layout member that participates in ordering but is
not printed. Conventional use: the "has-no-prerelease" tiebreaker. The
engine requires it to sit at the LSB of the packed core.
*/
enum InternalFlag;

// ---------------------------------------------------------------------------
// Layout descriptor types
// ---------------------------------------------------------------------------

/// Per-component metadata recorded by $(LREF layoutBody).
struct ComponentDesc
{
    string name;          /// Bitfield member name.
    Component component;  /// Original `@Component` UDA value.
    int bitOffset;        /// LSB-relative bit offset in the packed core.
    int bitWidth;         /// Bit width.
}

/// Per-internal-flag metadata recorded by $(LREF layoutBody).
struct InternalFlagDesc
{
    string name;     /// Bitfield member name; empty if no flag.
    int bitOffset;   /// Always 0 when present.
}

/**
Compile-time description of a layout's components and optional internal
flag. The $(LREF Version) engine reads this via `Layout.descriptor`.
*/
struct LayoutDescriptor
{
    /// Components sorted by `Component.printOrder`.
    ComponentDesc[] components;

    /// Internal flag (name empty if not declared).
    InternalFlagDesc internalFlag;

    /// Total bit budget the layout consumes.
    int totalBitWidth;
}

// ---------------------------------------------------------------------------
// Layout-body mixin
// ---------------------------------------------------------------------------

/**
Mixes a bitfield layout body into a struct. Takes a flat tuple of
`(uda, type, name, width)` groups, declared from LSB to MSB.

Each group emits one bitfield. Permitted UDA values:

$(UL
    $(LI `Component(printOrder, printWidth)` — a printed/comparison
        component.)
    $(LI `InternalFlag` — the LSB tiebreaker bit (at most one per layout).)
    $(LI `void` — a padding bit that participates in neither comparison
        nor formatting.)
)

The mixin emits:

$(OL
    $(LI The underlying `std.bitmanip.bitfields` storage.)
    $(LI A static `descriptor` of type $(LREF LayoutDescriptor) that
        records each component's bit offset, bit width, and original
        `Component` UDA.)
)

Example:
---
struct SemVerLayout
{
    mixin layoutBody!(
        InternalFlag,                          bool,  "stableFlag", 1,
        Component(printOrder: 2),              ulong, "patch",     24,
        Component(printOrder: 1),              ulong, "minor",     24,
        Component(printOrder: 0),              ulong, "major",     15,
    );

    string prerelease;
    string build;
}
---
*/
mixin template layoutBody(Spec...)
{
    import std.bitmanip;  // needed by the generated bitfields! mixin

    // The bitfields mixin and the descriptor are both derived from the
    // same `Spec` tuple at compile time.
    private alias _layoutSpec = Spec;
    mixin(sparkles.versions.engine.__layoutBuildBitfieldsMixin!Spec());

    /// Compile-time descriptor of this layout.
    static enum LayoutDescriptor descriptor =
        sparkles.versions.engine.__layoutBuildDescriptor!Spec();
}

/// Generates the `mixin(bitfields!(...))` call for the layout spec.
string __layoutBuildBitfieldsMixin(Spec...)()
{
    static assert(Spec.length % 4 == 0,
        "sparkles.versions.layoutBody: spec length must be a multiple "
        ~ "of 4 (uda, type, name, width)");

    string result = "mixin(std.bitmanip.bitfields!(";
    string sep = "";
    static foreach (i; 0 .. Spec.length / 4)
    {{
        alias Type = Spec[i * 4 + 1];
        enum string name = Spec[i * 4 + 2];
        enum size_t width = Spec[i * 4 + 3];
        result ~= sep ~ Type.stringof ~ ", \"" ~ name ~ "\", "
            ~ widthToStr(width);
        sep = ", ";
    }}
    result ~= "));";
    return result;
}

package string widthToStr(size_t n) pure
{
    if (n == 0) return "0";
    char[20] buf;
    size_t pos = buf.length;
    while (n > 0)
    {
        buf[--pos] = cast(char)('0' + (n % 10));
        n /= 10;
    }
    return buf[pos .. $].idup;
}

/// Builds the static LayoutDescriptor at compile time.
LayoutDescriptor __layoutBuildDescriptor(Spec...)()
{
    LayoutDescriptor d;
    int bitOffset = 0;
    int internalFlagCount = 0;

    static foreach (i; 0 .. Spec.length / 4)
    {{
        enum string name = Spec[i * 4 + 2];
        enum int width = cast(int) Spec[i * 4 + 3];

        // The UDA slot may be a type (InternalFlag / void) or a value
        // (Component(...)). Avoid `alias` since it cannot bind to a value;
        // use direct `static if` on the tuple element instead.
        static if (is(Spec[i * 4 + 0] == InternalFlag))
        {
            assert(internalFlagCount == 0,
                "Layout declares more than one @InternalFlag member.");
            assert(bitOffset == 0,
                "Layout's @InternalFlag must be the first declared bitfield "
                ~ "(at LSB offset 0).");
            assert(width == 1,
                "Layout's @InternalFlag bit width must be 1.");
            internalFlagCount++;
            d.internalFlag = InternalFlagDesc(name: name, bitOffset: 0);
        }
        else static if (is(typeof(Spec[i * 4 + 0]) == Component))
        {
            d.components ~= ComponentDesc(
                name: name,
                component: Spec[i * 4 + 0],
                bitOffset: bitOffset,
                bitWidth: width,
            );
        }
        else static if (is(Spec[i * 4 + 0] == void))
        {
            // Padding bit; no descriptor entry.
        }
        else
        {
            static assert(false,
                "sparkles.versions.layoutBody: unsupported UDA at position "
                ~ i.stringof ~ " (expected Component, InternalFlag, or void).");
        }

        bitOffset += width;
    }}

    d.totalBitWidth = bitOffset;

    // Sort components by printOrder (insertion sort at CTFE).
    for (size_t i = 1; i < d.components.length; i++)
    {
        const cur = d.components[i];
        size_t j = i;
        while (j > 0 && d.components[j - 1].component.printOrder
                            > cur.component.printOrder)
        {
            d.components[j] = d.components[j - 1];
            j--;
        }
        d.components[j] = cur;
    }

    return d;
}

// ---------------------------------------------------------------------------
// Core-type selector
// ---------------------------------------------------------------------------

/**
Maps a layout's $(D sizeof) to the unsigned integer used for packed
reinterpretation. Supported sizes are 1, 2, 4, and 8 bytes; other sizes
fail with a static assertion.
*/
template GetCoreType(size_t bytes)
{
    static if (bytes == 1) alias GetCoreType = ubyte;
    else static if (bytes == 2) alias GetCoreType = ushort;
    else static if (bytes == 4) alias GetCoreType = uint;
    else static if (bytes == 8) alias GetCoreType = ulong;
    else
        static assert(false,
            "sparkles.versions.GetCoreType: unsupported Layout size "
            ~ bytes.stringof ~ " bytes (allowed: 1, 2, 4, 8).");
}

// ---------------------------------------------------------------------------
// Layout traits
// ---------------------------------------------------------------------------

/**
True if `Layout` opts into a prerelease slot via
`enum hasPrerelease = true;`. The engine adds a `string prerelease;`
member to $(LREF Version) when this is set.
*/
package template hasPrerelease(Layout)
{
    static if (__traits(hasMember, Layout, "hasPrerelease"))
        enum hasPrerelease = Layout.hasPrerelease;
    else
        enum hasPrerelease = false;
}

/**
True if `Layout` opts into a build-metadata slot via
`enum hasBuild = true;`. The engine adds a `string build;` member to
$(LREF Version) when this is set.
*/
package template hasBuild(Layout)
{
    static if (__traits(hasMember, Layout, "hasBuild"))
        enum hasBuild = Layout.hasBuild;
    else
        enum hasBuild = false;
}

// ---------------------------------------------------------------------------
// The engine
// ---------------------------------------------------------------------------

/**
DbI versioning value parameterised by a layout type.

`Layout` must be a struct that mixes in $(LREF layoutBody) and exposes a
`descriptor` of type $(LREF LayoutDescriptor). The engine reinterprets
the layout's bits as a single unsigned integer for hardware-fast
comparison.

See `docs/specs/versions/SPEC.md` §4 for the validation rules.
*/
struct Version(Layout)
{
    static assert(Layout.sizeof == 1 || Layout.sizeof == 2
            || Layout.sizeof == 4 || Layout.sizeof == 8,
        "sparkles.versions.Version!" ~ Layout.stringof
        ~ ": Layout.sizeof must be 1, 2, 4, or 8.");

    static assert(__traits(hasMember, Layout, "descriptor"),
        "sparkles.versions.Version!" ~ Layout.stringof
        ~ ": Layout must declare a `descriptor` static member "
        ~ "(use `mixin layoutBody!(...)`).");

    /// Unsigned integer used for packed reinterpretation.
    alias CoreType = GetCoreType!(Layout.sizeof);

    /// Compile-time layout descriptor.
    enum LayoutDescriptor descriptor = Layout.descriptor;

    static assert(descriptor.components.length >= 1,
        "sparkles.versions.Version!" ~ Layout.stringof
        ~ ": Layout must declare at least one @Component member.");

    static assert(descriptor.totalBitWidth <= cast(int)(CoreType.sizeof * 8),
        "sparkles.versions.Version!" ~ Layout.stringof
        ~ ": declared bit widths exceed the layout's container size.");

    union
    {
        /// Direct layout access.
        Layout core;
        /// Packed integer view (for `opCmp` and `truncateTo`).
        CoreType packed;
    }

    static if (hasPrerelease!Layout)
    {
        /// Optional prerelease string slot (precedence-relevant).
        string prerelease;
    }

    static if (hasBuild!Layout)
    {
        /// Optional build-metadata string slot (precedence-irrelevant).
        string build;
    }

    // ------------------------------------------------------------------
    // Operations
    // ------------------------------------------------------------------

    /**
    Compares versions by SemVer §11 precedence:

    $(OL
        $(LI The packed core (major, minor, patch, internal flag) is
            compared as a single unsigned integer.)
        $(LI On a tie, if the layout declares a prerelease slot, the
            prerelease identifier lists are compared lexicographically
            per SemVer §11.)
    )

    Build metadata is ignored.
    */
    int opCmp(in typeof(this) other) const @safe pure nothrow @nogc
    {
        if (packed != other.packed)
            return packed < other.packed ? -1 : 1;
        static if (hasPrerelease!Layout)
            return comparePrereleaseLists(prerelease, other.prerelease);
        else
            return 0;
    }

    /// Equality by SemVer precedence (ignores build metadata).
    bool opEquals(in typeof(this) other) const @safe pure nothrow @nogc
        => opCmp(other) == 0;

    /// Hash consistent with $(LREF opEquals).
    size_t toHash() const @trusted pure nothrow @nogc
    {
        import core.internal.hash : hashOf;
        auto h = hashOf(packed);
        static if (hasPrerelease!Layout)
            h = hashOf(prerelease, h);
        return h;
    }

    /**
    Writes the formatted version to an output range.

    The default implementation walks the layout's `@Component` members
    in `printOrder` and emits each as a decimal integer with optional
    zero-padding per `printWidth`. If the layout defines its own
    `customToString(Writer)(ref Writer w) const` member, the engine
    defers to it entirely.
    */
    void toString(Writer)(ref Writer w) const
    {
        static if (__traits(hasMember, Layout, "customToString"))
            core.customToString(w);
        else
            defaultToString(w);
    }

    private void defaultToString(Writer)(ref Writer w) const
    {
        import std.range.primitives : put;

        static foreach (i, comp; descriptor.components)
        {{
            static if (i > 0) put(w, '.');
            const value = __traits(getMember, core, comp.name);
            putPaddedNumber(w, value, comp.component.printWidth);
        }}

        static if (hasPrerelease!Layout)
        {
            if (prerelease.length != 0)
            {
                put(w, '-');
                put(w, prerelease);
            }
        }

        static if (hasBuild!Layout)
        {
            if (build.length != 0)
            {
                put(w, '+');
                put(w, build);
            }
        }
    }

    /**
    Returns a copy of this version with every bit below the named
    component zeroed. Useful for grouping (e.g.
    `v.truncateTo!"minor"` buckets versions by `major.minor`).

    Prerelease and build slots are cleared in the result.
    */
    Version truncateTo(string name)() const @safe pure nothrow @nogc
    {
        enum compIdx = findComponentIdx(name);
        static assert(compIdx >= 0,
            "sparkles.versions.truncateTo: no component named `" ~ name
            ~ "` in layout `" ~ Layout.stringof ~ "`.");
        enum int bitOffset = descriptor.components[compIdx].bitOffset;
        enum CoreType mask = cast(CoreType)(~CoreType(0) << bitOffset);

        Version result;
        result.packed = packed & mask;
        return result;
    }

    private static long findComponentIdx(string name)
    {
        foreach (i, c; descriptor.components)
            if (c.name == name)
                return cast(long) i;
        return -1;
    }
}

// ---------------------------------------------------------------------------
// Support helpers
// ---------------------------------------------------------------------------

/// Writes `value` as decimal digits with at least `minWidth` characters,
/// left-padded with `'0'`. `minWidth == 0` means no padding.
package void putPaddedNumber(Writer, T)(ref Writer w, T value, int minWidth)
if (isIntegral!T && isUnsigned!T)
{
    import std.conv : toChars;
    import std.range.primitives : put;
    import std.traits : Unqual;

    Unqual!T n = value / 10;
    int digits = 1;
    while (n > 0) { digits++; n /= 10; }

    for (int i = digits; i < minWidth; i++)
        put(w, '0');
    put(w, toChars(value));
}

/// Compares two prerelease identifier lists per SemVer §11.
/// Empty (`""`) ranks higher than any non-empty list.
package int comparePrereleaseLists(in string lhs, in string rhs)
    @safe pure nothrow @nogc
{
    if (lhs.length == 0) return rhs.length == 0 ? 0 : 1;
    if (rhs.length == 0) return -1;

    size_t li, ri;
    while (li < lhs.length || ri < rhs.length)
    {
        if (li >= lhs.length) return -1;
        if (ri >= rhs.length) return 1;

        size_t lEnd = li;
        while (lEnd < lhs.length && lhs[lEnd] != '.') lEnd++;
        size_t rEnd = ri;
        while (rEnd < rhs.length && rhs[rEnd] != '.') rEnd++;

        if (auto c = comparePrereleaseSegment(lhs[li .. lEnd], rhs[ri .. rEnd]))
            return c;

        li = lEnd < lhs.length ? lEnd + 1 : lEnd;
        ri = rEnd < rhs.length ? rEnd + 1 : rEnd;
    }
    return 0;
}

private int comparePrereleaseSegment(in string lhs, in string rhs)
    @safe pure nothrow @nogc
{
    import std.algorithm.comparison : cmp;

    const lhsNumeric = isNumericIdentifier(lhs);
    const rhsNumeric = isNumericIdentifier(rhs);

    if (lhsNumeric && rhsNumeric)
    {
        if (lhs.length != rhs.length)
            return lhs.length < rhs.length ? -1 : 1;
        return cmp(lhs, rhs);
    }

    if (lhsNumeric) return -1;
    if (rhsNumeric) return 1;

    return cmp(lhs, rhs);
}

package bool isNumericIdentifier(in string value) @safe pure nothrow @nogc
{
    import std.algorithm.searching : all;
    import std.ascii : isDigit;
    import std.utf : byCodeUnit;

    return value.length > 0 && value.byCodeUnit.all!isDigit;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    private struct DemoLayout
    {
        enum hasPrerelease = true;
        enum hasBuild = true;
        mixin layoutBody!(
            InternalFlag,             bool,  "stableFlag", 1,
            Component(printOrder: 2), ulong, "patch",     24,
            Component(printOrder: 1), ulong, "minor",     24,
            Component(printOrder: 0), ulong, "major",     15,
        );
    }

    private struct TinyDemo
    {
        mixin layoutBody!(
            Component(printOrder: 2), ulong, "patch", 8,
            Component(printOrder: 1), ulong, "minor", 8,
            Component(printOrder: 0), ulong, "major", 16,
        );
    }
}

@("Version.engine.GetCoreType")
@safe pure nothrow @nogc
unittest
{
    static assert(is(GetCoreType!1 == ubyte));
    static assert(is(GetCoreType!2 == ushort));
    static assert(is(GetCoreType!4 == uint));
    static assert(is(GetCoreType!8 == ulong));
    static assert(!__traits(compiles, GetCoreType!16));
    static assert(!__traits(compiles, GetCoreType!3));
}

@("Version.engine.descriptor")
@safe pure nothrow @nogc
unittest
{
    enum d = DemoLayout.descriptor;
    static assert(d.components.length == 3);
    static assert(d.components[0].name == "major");
    static assert(d.components[0].bitOffset == 49);
    static assert(d.components[0].bitWidth == 15);
    static assert(d.components[1].name == "minor");
    static assert(d.components[1].bitOffset == 25);
    static assert(d.components[1].bitWidth == 24);
    static assert(d.components[2].name == "patch");
    static assert(d.components[2].bitOffset == 1);
    static assert(d.components[2].bitWidth == 24);
    static assert(d.internalFlag.name == "stableFlag");
    static assert(d.internalFlag.bitOffset == 0);
    static assert(d.totalBitWidth == 64);
}

@("Version.engine.instantiate")
@safe pure nothrow @nogc
unittest
{
    Version!DemoLayout v;
    v.core.major = 1;
    v.core.minor = 2;
    v.core.patch = 3;
    v.core.stableFlag = true;
    assert(v.core.major == 1);
    assert(v.core.minor == 2);
    assert(v.core.patch == 3);
    assert(v.core.stableFlag == true);
}

@("Version.engine.packed-overlay")
@safe pure nothrow @nogc
unittest
{
    // The union overlay exposes the packed integer view. We verify
    // that field bit positions match the descriptor.
    Version!DemoLayout v;
    v.core.stableFlag = true;
    assert(v.packed == 1, "stableFlag at LSB");

    v = Version!DemoLayout.init;
    v.core.major = 1;
    assert(v.packed == (1UL << 49), "major at bit 49");

    v = Version!DemoLayout.init;
    v.core.minor = 1;
    assert(v.packed == (1UL << 25), "minor at bit 25");

    v = Version!DemoLayout.init;
    v.core.patch = 1;
    assert(v.packed == (1UL << 1), "patch at bit 1");
}

@("Version.engine.tiny-no-flag")
@safe pure nothrow @nogc
unittest
{
    // TinyDemo has no internal flag — engine accepts that.
    enum d = TinyDemo.descriptor;
    static assert(d.internalFlag.name == "");
    static assert(d.components.length == 3);

    Version!TinyDemo v;
    v.core.major = 7;
    assert(v.packed == (7U << 16));
}

@("Version.engine.opCmp.basic")
@safe pure nothrow @nogc
unittest
{
    Version!DemoLayout a, b;
    a.core.stableFlag = true; a.core.major = 1; a.core.minor = 2; a.core.patch = 3;
    b.core.stableFlag = true; b.core.major = 1; b.core.minor = 2; b.core.patch = 4;
    assert(a < b);
    assert(b > a);
    assert(a != b);

    b.core.patch = 3;
    assert(a == b);
    assert(a.toHash == b.toHash);
}

@("Version.engine.opCmp.stableBeatsPrerelease")
@safe pure nothrow @nogc
unittest
{
    Version!DemoLayout stable, pre;
    stable.core.stableFlag = true;
    stable.core.major = 1;
    pre.core.stableFlag = false;
    pre.core.major = 1;
    pre.prerelease = "alpha";
    assert(stable > pre);
}

@("Version.engine.opCmp.crossMajor")
@safe pure nothrow @nogc
unittest
{
    // SemVer §11: 2.0.0-alpha > 1.999.999 stable (major dominates).
    Version!DemoLayout earlier, later;
    earlier.core.stableFlag = true;
    earlier.core.major = 1;
    earlier.core.minor = 0xFFFFFF;
    earlier.core.patch = 0xFFFFFF;
    later.core.stableFlag = false;
    later.core.major = 2;
    later.prerelease = "alpha";
    assert(later > earlier);
}

@("Version.engine.opCmp.prereleaseChain")
@safe pure
unittest
{
    import std.algorithm.iteration : map;
    import std.algorithm.sorting : isSorted;

    // SemVer §11.4 precedence chain via prerelease lexicographic compare.
    static immutable preReleases = [
        "alpha",
        "alpha.1",
        "alpha.beta",
        "beta",
        "beta.2",
        "beta.11",
        "rc.1",
    ];

    Version!DemoLayout[7] versions;
    foreach (i, ref v; versions)
    {
        v.core.stableFlag = false;
        v.core.major = 1;
        v.prerelease = preReleases[i];
    }

    Version!DemoLayout stable;
    stable.core.stableFlag = true;
    stable.core.major = 1;

    // versions are in ascending order; stable goes last.
    foreach (i; 0 .. versions.length - 1)
        assert(versions[i] < versions[i + 1]);
    assert(versions[$ - 1] < stable);
}

@("Version.engine.toString.basic")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    Version!DemoLayout v;
    v.core.stableFlag = true;
    v.core.major = 1; v.core.minor = 2; v.core.patch = 3;
    checkToString(v, "1.2.3");

    v.prerelease = "alpha.1";
    v.build = "build.5";
    v.core.stableFlag = false;
    checkToString(v, "1.2.3-alpha.1+build.5");
}

@("Version.engine.truncateTo")
@safe pure nothrow @nogc
unittest
{
    Version!DemoLayout v;
    v.core.stableFlag = true;
    v.core.major = 1; v.core.minor = 2; v.core.patch = 3;
    v.prerelease = "alpha";

    auto truncMinor = v.truncateTo!"minor"();
    assert(truncMinor.core.major == 1);
    assert(truncMinor.core.minor == 2);
    assert(truncMinor.core.patch == 0);
    assert(truncMinor.core.stableFlag == false);
    assert(truncMinor.prerelease == "");

    auto truncMajor = v.truncateTo!"major"();
    assert(truncMajor.core.major == 1);
    assert(truncMajor.core.minor == 0);
    assert(truncMajor.core.patch == 0);
}
