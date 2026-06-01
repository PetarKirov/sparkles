/**
`AnyVersion` / `AnyRange` — runtime sum types over every shipped scheme.

Callers that handle versions of a statically-unknown scheme (purl-driven
workflows, SBOM ingestion, vulnerability matching) erase the concrete scheme
into one of these sum types. $(LREF AnyVersion) wraps any of the eleven
version structs; $(LREF AnyRange) wraps the matching `Ranges!S`. The runtime
interop entry points — `parsePurlVersion` (pURL, SPEC §10) and `parseVersAny`
(VERS, SPEC §9) — return these.

Because there is no universal order across schemes (SPEC §6.3), cross-scheme
comparison is partial: $(LREF compareAny) returns a `Nullable!int` that is
null whenever the two operands hold different active schemes. A null result is
the defined contract, not a failure mode (see the cross-scheme-order explanation).

The type lists are derived from
$(REF allSchemes, sparkles,versions,schemes,registry) via `staticMap`, so a
new scheme added to the registry joins both sum types automatically — there is
no second list to keep in sync.

See `docs/specs/versions/SPEC.md` §11.
*/
module sparkles.versions.any;

import std.meta : staticMap;
import std.sumtype : SumType, match;
import std.typecons : Nullable, nullable;

import sparkles.versions.ranges : Ranges;
import sparkles.versions.schemes.registry : allSchemes;

// Re-export the concrete scheme structs so `AnyVersion`'s members are nameable
// by callers that only import this module (SPEC §11/§12).
public import sparkles.versions.schemes.semver : SemVer;
public import sparkles.versions.schemes.dmd : Dmd;
public import sparkles.versions.schemes.dmd_compact : DmdCompact;
public import sparkles.versions.schemes.tiny : Tiny;
public import sparkles.versions.schemes.calver_yymm : CalVerYYMM;
public import sparkles.versions.schemes.calver_yyyymmdd : CalVerYYYYMMDD;
public import sparkles.versions.schemes.vim : VimVer;
public import sparkles.versions.schemes.pypi : PypiVersion;
public import sparkles.versions.schemes.maven : MavenVersion;
public import sparkles.versions.schemes.deb : DebianVersion;
public import sparkles.versions.schemes.generic : Generic;

@safe:

// ---------------------------------------------------------------------------
// The sum types
// ---------------------------------------------------------------------------

/// Maps a scheme struct `S` to its range type `Ranges!S`.
private alias RangeOf(S) = Ranges!S;

/**
A version of statically-unknown scheme: a `SumType` over every shipped
version struct (`SemVer`, `Dmd`, …, `Generic`). The member list is derived
from $(REF allSchemes, sparkles,versions,schemes,registry), so it always
covers the full eleven-scheme catalogue.

Build one by wrapping a concrete version (`AnyVersion(SemVer.parse("1.2.3")
.value)`); inspect it with `std.sumtype.match`; order two with
$(LREF compareAny).
*/
alias AnyVersion = SumType!allSchemes;

/**
A range of statically-unknown scheme: a `SumType` over every shipped
`Ranges!S`, one per entry in
$(REF allSchemes, sparkles,versions,schemes,registry).
*/
alias AnyRange = SumType!(staticMap!(RangeOf, allSchemes));

// ---------------------------------------------------------------------------
// Cross-scheme comparison
// ---------------------------------------------------------------------------

/**
Partial three-way comparison of two $(LREF AnyVersion)s.

$(UL
    $(LI When `a` and `b` hold the $(B same) active scheme, returns
        `Nullable!int(a.opCmp(b))` — the scheme's own three-way order.)
    $(LI When they hold $(B different) schemes, returns a null `Nullable!int`:
        there is no cross-scheme order (SPEC §6.3). A null result is the
        defined contract, not an error.)
)
*/
Nullable!int compareAny(in AnyVersion a, in AnyVersion b)
    @safe pure nothrow @nogc
{
    // Dispatch on `a`'s active type; inside, dispatch on `b` and compare only
    // when `b` holds the same scheme. A SumType holding a different type
    // yields the null branch.
    return a.match!((ref lhs) =>
        b.match!(
            (ref typeof(lhs) rhs) => nullable(lhs.opCmp(rhs)),
            (ref _) => Nullable!int.init,
        )
    );
}

// ---------------------------------------------------------------------------
// toString dispatch
// ---------------------------------------------------------------------------

/**
Writes the active version's canonical string into the output range `w`,
dispatching on the held scheme. The per-scheme `toString` (SPEC §3.2) does
the formatting; this just routes to it.
*/
void toString(W)(in AnyVersion v, ref W w)
{
    v.match!((ref active) => active.toString(w));
}

/// ditto — for `AnyRange`, emitting VERS constraint syntax (SPEC §9).
void toString(W)(in AnyRange r, ref W w)
{
    r.match!((ref active) => active.toString(w));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("any.AnyVersion.coversAllSchemes")
@safe pure nothrow @nogc
unittest
{
    import std.meta : staticIndexOf;

    // Every shipped scheme is a member of both sum types, in registry order.
    static assert(allSchemes.length == 11);
    static foreach (i, S; allSchemes)
    {
        static assert(staticIndexOf!(S, AnyVersion.Types) == i);
        static assert(staticIndexOf!(Ranges!S, AnyRange.Types) == i);
    }
}

@("any.compareAny.sameSchemeOrders")
@safe pure
unittest
{
    const a = AnyVersion(SemVer.parse("1.2.3").value);
    const b = AnyVersion(SemVer.parse("1.3.0").value);
    const c = AnyVersion(SemVer.parse("1.2.3").value);

    const lt = compareAny(a, b);
    assert(!lt.isNull);
    assert(lt.get < 0);

    const gt = compareAny(b, a);
    assert(!gt.isNull);
    assert(gt.get > 0);

    const eq = compareAny(a, c);
    assert(!eq.isNull);
    assert(eq.get == 0);
}

@("any.compareAny.crossSchemeIsNull")
@safe pure
unittest
{
    const sem = AnyVersion(SemVer.parse("1.2.3").value);
    const py = AnyVersion(PypiVersion.parse("1.2.3").value);

    // No cross-scheme order exists (SPEC §6.3): null in either direction.
    assert(compareAny(sem, py).isNull);
    assert(compareAny(py, sem).isNull);
}

@("any.compareAny.otherSchemesSameType")
@safe pure
unittest
{
    // A non-SemVer scheme still orders against its own kind.
    const a = AnyVersion(MavenVersion.parse("1.0.0").value);
    const b = AnyVersion(MavenVersion.parse("2.0.0").value);

    const r = compareAny(a, b);
    assert(!r.isNull);
    assert(r.get < 0);
}

@("any.toString.dispatchesToActiveScheme")
@safe pure
unittest
{
    import std.array : appender;

    auto v = AnyVersion(SemVer.parse("1.2.3-rc.1").value);
    auto w = appender!string;
    toString(v, w);
    assert(w[] == "1.2.3-rc.1");
}

@("any.toString.rangeEmitsVersConstraint")
@safe
unittest
{
    import std.array : appender;

    auto range = SemVer.parseNativeRange("^1.2.0").value;
    auto r = AnyRange(range);
    auto w = appender!string;
    toString(r, w);
    assert(w[] == ">=1.2.0|<2.0.0");
}
