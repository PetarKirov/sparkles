/**
Real-world preset layouts for the $(LREF Version) engine.

This module maps real-world versioning schemes (Ubuntu, Arch Linux,
Vim, Node.js, Rust, Linux, …) to layouts the engine can drive. Most
strict-SemVer products use the standard $(LREF SemVerLayout); three
new layouts capture width-padded forms.

All preset layouts share the SemVer bitfield shape — `stableFlag:1,
patch:24, minor:24, major:15` — and differ only in static
`@Component.printWidth`. This is the DbI design's headline
demonstration: same storage, different format hooks.

See `docs/specs/versions/PRESETS.md` for the per-product coverage map
and provenance.
*/
module sparkles.versions.presets;

import sparkles.versions.engine;
import sparkles.versions.layouts : SemVerLayout, DmdLayout;
public import sparkles.versions.layouts : SemVerLayout, DmdLayout, SemVer, DmdVer;

@safe:

// ---------------------------------------------------------------------------
// CalVerYYMMLayout — Ubuntu-style `YY.MM.Patch`
// ---------------------------------------------------------------------------

/**
Calendar versioning with 2-digit year and 2-digit zero-padded month.
Validates with Ubuntu `24.04.1`.
*/
struct CalVerYYMMLayout
{
    enum hasPrerelease = true;
    enum hasBuild = true;

    mixin layoutBody!(
        InternalFlag,                            bool,  "stableFlag", 1,
        Component(printOrder: 2),                ulong, "patch",     24,
        Component(printOrder: 1, printWidth: 2), ulong, "minor",     24,
        Component(printOrder: 0),                ulong, "major",     15,
    );
}

/// Ubuntu-style calendar version.
alias CalVerYYMM = Version!CalVerYYMMLayout;

// ---------------------------------------------------------------------------
// CalVerYYYYMMDDLayout — Arch-style `YYYY.MM.DD`
// ---------------------------------------------------------------------------

/**
Calendar versioning with 4-digit year, 2-digit zero-padded month, and
2-digit zero-padded day. Validates with Arch Linux `2024.05.01`. Year
fits within 15 bits (≤ 32767).
*/
struct CalVerYYYYMMDDLayout
{
    enum hasPrerelease = true;
    enum hasBuild = true;

    mixin layoutBody!(
        InternalFlag,                            bool,  "stableFlag", 1,
        Component(printOrder: 2, printWidth: 2), ulong, "patch",     24,
        Component(printOrder: 1, printWidth: 2), ulong, "minor",     24,
        Component(printOrder: 0),                ulong, "major",     15,
    );
}

/// Arch-style calendar version.
alias CalVerYYYYMMDD = Version!CalVerYYYYMMDDLayout;

// ---------------------------------------------------------------------------
// VimLayout — Vim's 4-digit zero-padded patch
// ---------------------------------------------------------------------------

/**
Vim-style versioning with a 4-digit zero-padded patch component
(Vim ships running patch counters like `9.1.0400`). Major and minor
are unpadded.
*/
struct VimLayout
{
    enum hasPrerelease = true;
    enum hasBuild = true;

    mixin layoutBody!(
        InternalFlag,                            bool,  "stableFlag", 1,
        Component(printOrder: 2, printWidth: 4), ulong, "patch",     24,
        Component(printOrder: 1),                ulong, "minor",     24,
        Component(printOrder: 0),                ulong, "major",     15,
    );
}

/// Vim-style version.
alias VimVer = Version!VimLayout;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("presets.SemVer.realWorldVersions")
@safe pure nothrow @nogc
unittest
{
    import sparkles.versions.parser : parse, SemVerParseMode;
    import sparkles.core_cli.smallbuffer : checkToString;

    // 17 strict-SemVer products from PRESETS.md §2 round-trip through
    // SemVerLayout in strict mode.
    static immutable cases = [
        "20.13.1",  // Node.js
        "1.78.0",   // Rust
        "1.30.0",   // Kubernetes
        "17.3.0",   // Angular
        "18.3.1",   // React
        "6.8.9",    // Linux Kernel
        "26.1.1",   // Docker
        "2.45.1",   // Git
        "8.3.7",    // PHP
        "3.3.1",    // Ruby
        "1.26.0",   // Nginx
        "2.4.59",   // Apache HTTP
        "7.2.4",    // Redis
        "7.0.8",    // MongoDB
        "3.45.3",   // SQLite
        "8.7.1",    // cURL
        "7.0.1",    // FFmpeg
        "14.5.1",   // macOS
    ];

    foreach (s; cases)
    {
        auto v = parse!SemVerLayout(s, SemVerParseMode.strict);
        assert(v.hasValue, s);
        checkToString(v.value, s);
    }
}

@("presets.SemVer.postgresLooseMode")
@safe pure nothrow @nogc
unittest
{
    import sparkles.versions.parser : parse, SemVerParseMode;
    import sparkles.core_cli.smallbuffer : checkToString;

    // PostgreSQL ships 2-part versions (16.3). Loose mode infills patch=0.
    auto v = parse!SemVerLayout("16.3", SemVerParseMode.loose);
    assert(v.hasValue);
    checkToString(v.value, "16.3.0");
    assert(v.value.core.major == 16);
    assert(v.value.core.minor == 3);
    assert(v.value.core.patch == 0);
}

@("presets.Dmd.parsesDlangHistoricalAndCurrent")
@safe pure nothrow @nogc
unittest
{
    import sparkles.versions.parser : parse, SemVerParseMode;
    import sparkles.core_cli.smallbuffer : checkToString;

    // Real Dlang/DMD versions across eras.
    static immutable cases = [
        ["2.079.0",  "2.079.0"],   // historical (zero-padded minor)
        ["2.111.0",  "2.111.0"],   // current
        ["1.075.0",  "1.075.0"],   // very old
    ];

    foreach (testCase; cases)
    {
        auto v = parse!DmdLayout(testCase[0], SemVerParseMode.strict);
        assert(v.hasValue, testCase[0]);
        checkToString(v.value, testCase[1]);
    }
}

@("presets.Dmd.ordering")
@safe pure nothrow @nogc
unittest
{
    import sparkles.versions.parser : parse, SemVerParseMode;

    auto v079 = parse!DmdLayout("2.079.0", SemVerParseMode.strict).value;
    auto v111 = parse!DmdLayout("2.111.0", SemVerParseMode.strict).value;
    assert(v079 < v111);
}

@("presets.CalVerYYMM.ubuntu")
@safe pure nothrow @nogc
unittest
{
    import sparkles.versions.parser : parse, SemVerParseMode;
    import sparkles.core_cli.smallbuffer : checkToString;

    // Ubuntu 24.04.1 LTS (real release, Aug 2024).
    auto v = parse!CalVerYYMMLayout("24.04.1", SemVerParseMode.strict);
    assert(v.hasValue);
    checkToString(v.value, "24.04.1");
    assert(v.value.core.major == 24);
    assert(v.value.core.minor == 4);
    assert(v.value.core.patch == 1);

    // Unpadded month should be rejected.
    assert(parse!CalVerYYMMLayout("24.4.1", SemVerParseMode.strict).hasError);
}

@("presets.CalVerYYMM.ordering")
@safe pure nothrow @nogc
unittest
{
    import sparkles.versions.parser : parse, SemVerParseMode;

    auto early = parse!CalVerYYMMLayout("24.04.1", SemVerParseMode.strict).value;
    auto later = parse!CalVerYYMMLayout("24.04.2", SemVerParseMode.strict).value;
    auto next  = parse!CalVerYYMMLayout("24.10.1", SemVerParseMode.strict).value;
    auto major = parse!CalVerYYMMLayout("25.04.1", SemVerParseMode.strict).value;
    assert(early < later);
    assert(later < next);
    assert(next < major);
}

@("presets.CalVerYYYYMMDD.arch")
@safe pure nothrow @nogc
unittest
{
    import sparkles.versions.parser : parse, SemVerParseMode;
    import sparkles.core_cli.smallbuffer : checkToString;

    // Arch Linux 2024.05.01 (real release).
    auto v = parse!CalVerYYYYMMDDLayout("2024.05.01", SemVerParseMode.strict);
    assert(v.hasValue);
    checkToString(v.value, "2024.05.01");
    assert(v.value.core.major == 2024);
    assert(v.value.core.minor == 5);
    assert(v.value.core.patch == 1);

    // Day must be 2 digits.
    assert(parse!CalVerYYYYMMDDLayout("2024.05.1", SemVerParseMode.strict)
        .hasError);
}

@("presets.CalVerYYYYMMDD.ordering")
@safe pure nothrow @nogc
unittest
{
    import sparkles.versions.parser : parse, SemVerParseMode;

    auto d1 = parse!CalVerYYYYMMDDLayout("2024.05.01", SemVerParseMode.strict)
        .value;
    auto d2 = parse!CalVerYYYYMMDDLayout("2024.05.02", SemVerParseMode.strict)
        .value;
    auto d3 = parse!CalVerYYYYMMDDLayout("2024.06.01", SemVerParseMode.strict)
        .value;
    auto d4 = parse!CalVerYYYYMMDDLayout("2025.01.01", SemVerParseMode.strict)
        .value;
    assert(d1 < d2);
    assert(d2 < d3);
    assert(d3 < d4);
}

@("presets.Vim.fourDigitPatch")
@safe pure nothrow @nogc
unittest
{
    import sparkles.versions.parser : parse, SemVerParseMode;
    import sparkles.core_cli.smallbuffer : checkToString;

    // Vim 9.1.0400 (real patch from github.com/vim/vim).
    auto v = parse!VimLayout("9.1.0400", SemVerParseMode.strict);
    assert(v.hasValue);
    checkToString(v.value, "9.1.0400");
    assert(v.value.core.major == 9);
    assert(v.value.core.minor == 1);
    assert(v.value.core.patch == 400);

    // 3-digit patch rejected by width rule.
    assert(parse!VimLayout("9.1.400", SemVerParseMode.strict).hasError);

    // Higher patch comes through unpadded since natural width > 4.
    auto big = parse!VimLayout("9.1.10000", SemVerParseMode.strict);
    assert(big.hasValue);
    checkToString(big.value, "9.1.10000");
}

@("presets.Vim.ordering")
@safe pure nothrow @nogc
unittest
{
    import sparkles.versions.parser : parse, SemVerParseMode;

    auto a = parse!VimLayout("9.1.0399", SemVerParseMode.strict).value;
    auto b = parse!VimLayout("9.1.0400", SemVerParseMode.strict).value;
    auto c = parse!VimLayout("9.2.0001", SemVerParseMode.strict).value;
    assert(a < b);
    assert(b < c);
}
