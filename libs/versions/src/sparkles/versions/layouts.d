/**
Concrete layouts for the $(LREF Version) engine.

Four layouts are shipped:

$(UL
    $(LI $(LREF SemVerLayout) — strict Semantic Versioning 2.0.0.)
    $(LI $(LREF DmdLayout) — DMD-style with 3-digit-padded minor.)
    $(LI $(LREF DmdOptimized) — 4-byte DMD with bitfield-encoded
        `(phase, num)` prerelease and no string slots.)
    $(LI $(LREF TinyLayout) — 4-byte no-prerelease compact layout.)
)

See `docs/specs/versions/SPEC.md` §7 for the per-layout specification.
*/
module sparkles.versions.layouts;

import sparkles.versions.engine;
import sparkles.versions.semver_rules : semVerBuildSlot, semVerPrereleaseSlot;

@safe:

// ---------------------------------------------------------------------------
// SemVerLayout — strict SemVer 2.0.0
// ---------------------------------------------------------------------------

/**
Strict Semantic Versioning 2.0.0 layout.

Bits (LSB → MSB): `stableFlag:1, patch:24, minor:24, major:15`. Major
fits up to 32767; minor and patch each up to 16,777,215. Prerelease and
build metadata are stored as plain GC `string` slots.
*/
struct SemVerLayout
{
    mixin layoutBody!(
        InternalFlag,             bool,  "stableFlag", 1,
        Component(printOrder: 2), ulong, "patch",     24,
        Component(printOrder: 1), ulong, "minor",     24,
        Component(printOrder: 0), ulong, "major",     15,
    );

    static immutable StringSlot[] stringSlots = [
        semVerPrereleaseSlot,
        semVerBuildSlot,
    ];
}

/// Standard SemVer 2.0.0 version type.
alias SemVer = Version!SemVerLayout;

// ---------------------------------------------------------------------------
// DmdLayout — DMD-style with zero-padded 3-digit minor
// ---------------------------------------------------------------------------

/**
DMD-style versioning. Same bitfield shape as $(LREF SemVerLayout) but
minor carries `printWidth: 3`. `toString` emits minor as at least 3
digits (padding `79` → `079`, leaving `111` unchanged); major and patch
are unpadded. Matches real DMD versioning across eras (`2.079.0`,
`2.111.0`, `2.111.0-beta.1`).
*/
struct DmdLayout
{
    mixin layoutBody!(
        InternalFlag,                              bool,  "stableFlag", 1,
        Component(printOrder: 2),                  ulong, "patch",     24,
        Component(printOrder: 1, printWidth: 3),   ulong, "minor",     24,
        Component(printOrder: 0),                  ulong, "major",     15,
    );

    static immutable StringSlot[] stringSlots = [
        semVerPrereleaseSlot,
        semVerBuildSlot,
    ];
}

/// DMD-style version type with 3-digit zero-padded minor.
alias DmdVer = Version!DmdLayout;

// ---------------------------------------------------------------------------
// DmdOptimized — 4-byte compact DMD with bitfield-encoded prerelease
// ---------------------------------------------------------------------------

/**
Compact 4-byte DMD layout. Exploits two facts about DMD's actual
versioning to fit a fully ordered, fully formatted version into 32 bits
with zero string allocations:

$(OL
    $(LI DMD releases carry no build metadata.)
    $(LI DMD prereleases follow the constrained grammar `beta.N` or
        `rc.N` (e.g. `2.111.0-beta.2`, `2.111.0-rc.3`); the prerelease
        is encoded as a 2-bit phase plus a 6-bit number rather than a
        general string.)
)

Phase encoding (monotone for ordering):

$(TABLE
$(TR $(TH `prereleasePhase`) $(TH meaning) $(TH canonical `prereleaseNum`))
$(TR $(TD `00`) $(TD beta)     $(TD 1–63))
$(TR $(TD `01`) $(TD rc)       $(TD 1–63))
$(TR $(TD `10`) $(TD stable)   $(TD 0))
$(TR $(TD `11`) $(TD reserved) $(TD parser rejects))
)

Because `prereleasePhase` sits just above `prereleaseNum`, single-
integer comparison yields `2.111.0-beta.N < 2.111.0-rc.M < 2.111.0`.
*/
struct DmdOptimized
{
    // No `stringSlots` declared — this layout encodes prerelease as
    // bitfield (phase, num) entirely within its 32-bit packed core.

    /// Phase values participating in ordering. Values are monotone:
    /// stable > rc > beta.
    enum Phase : ubyte
    {
        beta = 0,
        rc = 1,
        stable = 2,
        reserved = 3,
    }

    mixin layoutBody!(
        Component(printOrder: 4),                ubyte, "prereleaseNum",   6,
        Component(printOrder: 3),                ubyte, "prereleasePhase", 2,
        Component(printOrder: 2),                ulong, "patch",           6,
        Component(printOrder: 1, printWidth: 3), ulong, "minor",          10,
        Component(printOrder: 0),                ulong, "major",           8,
    );

    /// Layout-supplied formatter: emits `major.minor.patch` with
    /// optional `-beta.N` / `-rc.N` suffix.
    void customToString(Writer)(ref Writer w) const
    {
        import sparkles.versions.engine : putPaddedNumber;
        import std.range.primitives : put;

        putPaddedNumber!(Writer, ulong)(w, major, 0);
        put(w, '.');
        putPaddedNumber!(Writer, ulong)(w, minor, 3);
        put(w, '.');
        putPaddedNumber!(Writer, ulong)(w, patch, 0);

        switch (prereleasePhase)
        {
            case Phase.beta:
                put(w, "-beta.");
                putPaddedNumber!(Writer, ubyte)(w, prereleaseNum, 0);
                break;
            case Phase.rc:
                put(w, "-rc.");
                putPaddedNumber!(Writer, ubyte)(w, prereleaseNum, 0);
                break;
            case Phase.stable:
                break;
            default:
                // Reserved phase code — should not occur for valid values;
                // emit a marker so the caller can spot it.
                put(w, "-?");
                break;
        }
    }
}

// ---------------------------------------------------------------------------
// TinyLayout — 4-byte no-prerelease compact layout
// ---------------------------------------------------------------------------

/**
A 4-byte layout with neither prerelease nor build metadata, and no
`stableFlag`. Major ≤ 65535, minor ≤ 255, patch ≤ 255. Useful for
storage-sensitive internal use. Validates the DbI "void-hook"
baseline — the smallest meaningful layout.
*/
struct TinyLayout
{
    mixin layoutBody!(
        Component(printOrder: 2), ulong, "patch",  8,
        Component(printOrder: 1), ulong, "minor",  8,
        Component(printOrder: 0), ulong, "major", 16,
    );
}

/// Compact 4-byte version type.
alias TinyVer = Version!TinyLayout;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("layouts.SemVerLayout.descriptor")
@safe pure nothrow @nogc
unittest
{
    enum d = SemVerLayout.descriptor;
    assert(d.components.length == 3);
    assert(d.components[0].name == "major");
    assert(d.components[1].name == "minor");
    assert(d.components[2].name == "patch");
    assert(d.totalBitWidth == 64);
    assert(d.internalFlag.name == "stableFlag");
}

@("layouts.SemVerLayout.precedenceChain")
@safe pure nothrow @nogc
unittest
{
    // SemVer §11.4 precedence chain via the SemVer prerelease comparator
    // (numeric < alphanumeric at same position; numeric segments compare
    // numerically). The engine treats this as opaque — SemVerLayout's
    // semVerPrereleaseSlot supplies the comparator.
    import sparkles.versions.parser : parse, ParseMode;
    static immutable chain = [
        "1.0.0-alpha",
        "1.0.0-alpha.1",
        "1.0.0-alpha.beta",
        "1.0.0-beta",
        "1.0.0-beta.2",
        "1.0.0-beta.11",
        "1.0.0-rc.1",
        "1.0.0",
    ];

    foreach (i; 0 .. chain.length - 1)
    {
        auto lhs = parse!SemVerLayout(chain[i], ParseMode.strict).value;
        auto rhs = parse!SemVerLayout(chain[i + 1], ParseMode.strict).value;
        assert(lhs < rhs);
    }
}

@("layouts.SemVerLayout.size")
@safe pure nothrow @nogc
unittest
{
    static assert(SemVerLayout.sizeof == 8);
    static assert(is(Version!SemVerLayout.CoreType == ulong));
}

@("layouts.DmdLayout.printsZeroPaddedMinor")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    DmdVer v;
    v.core.stableFlag = true;
    v.core.major = 2;
    v.core.minor = 79;
    v.core.patch = 0;
    checkToString(v, "2.079.0");

    v.core.minor = 111;
    checkToString(v, "2.111.0");

    v.core.minor = 9;
    checkToString(v, "2.009.0");
}

@("layouts.DmdLayout.sharesStorageWithSemVer")
@safe pure nothrow @nogc
unittest
{
    // Same bitfield shape — different format hooks.
    static assert(DmdLayout.sizeof == SemVerLayout.sizeof);
    static assert(DmdLayout.descriptor.totalBitWidth
        == SemVerLayout.descriptor.totalBitWidth);
}

@("layouts.DmdOptimized.size")
@safe pure nothrow @nogc
unittest
{
    static assert(DmdOptimized.sizeof == 4);
    static assert(is(Version!DmdOptimized.CoreType == uint));
}

@("layouts.DmdOptimized.ordering")
@safe pure nothrow @nogc
unittest
{
    // 2.111.0-beta.N < 2.111.0-rc.M < 2.111.0 for all N, M ≤ 63.
    Version!DmdOptimized beta2, rc1, stable;

    beta2.core.major = 2; beta2.core.minor = 111; beta2.core.patch = 0;
    beta2.core.prereleasePhase = DmdOptimized.Phase.beta;
    beta2.core.prereleaseNum = 2;

    rc1.core.major = 2; rc1.core.minor = 111; rc1.core.patch = 0;
    rc1.core.prereleasePhase = DmdOptimized.Phase.rc;
    rc1.core.prereleaseNum = 1;

    stable.core.major = 2; stable.core.minor = 111; stable.core.patch = 0;
    stable.core.prereleasePhase = DmdOptimized.Phase.stable;
    stable.core.prereleaseNum = 0;

    assert(beta2 < rc1);
    assert(rc1 < stable);

    // Cross-major: 3.0.0-beta.1 > 2.999.0
    Version!DmdOptimized newer, older;
    newer.core.major = 3;
    newer.core.prereleasePhase = DmdOptimized.Phase.beta;
    newer.core.prereleaseNum = 1;
    older.core.major = 2; older.core.minor = 999;
    older.core.prereleasePhase = DmdOptimized.Phase.stable;
    assert(newer > older);
}

@("layouts.DmdOptimized.toString")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    Version!DmdOptimized v;
    v.core.major = 2; v.core.minor = 111; v.core.patch = 0;
    v.core.prereleasePhase = DmdOptimized.Phase.stable;
    checkToString(v, "2.111.0");

    v.core.prereleasePhase = DmdOptimized.Phase.beta;
    v.core.prereleaseNum = 2;
    checkToString(v, "2.111.0-beta.2");

    v.core.prereleasePhase = DmdOptimized.Phase.rc;
    v.core.prereleaseNum = 3;
    checkToString(v, "2.111.0-rc.3");

    // Zero-padded minor (printWidth: 3).
    v.core.minor = 79;
    v.core.prereleasePhase = DmdOptimized.Phase.stable;
    v.core.prereleaseNum = 0;
    checkToString(v, "2.079.0");
}

@("layouts.TinyLayout.voidHookBaseline")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    // TinyLayout: no flag, no SSO. Proves the engine accepts the
    // degenerate layout shape.
    static assert(TinyLayout.sizeof == 4);
    static assert(TinyLayout.descriptor.internalFlag.name == "");

    TinyVer v;
    v.core.major = 7; v.core.minor = 8; v.core.patch = 9;
    checkToString(v, "7.8.9");
}
