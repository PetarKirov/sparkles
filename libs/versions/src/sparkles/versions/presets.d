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
import sparkles.versions.semver_rules : semVerBuildSlot, semVerPrereleaseSlot;
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
    mixin layoutBody!(
        InternalFlag,                            bool,  "stableFlag", 1,
        Component(printOrder: 2),                ulong, "patch",     24,
        Component(printOrder: 1, printWidth: 2), ulong, "minor",     24,
        Component(printOrder: 0),                ulong, "major",     15,
    );

    @semVerPrereleaseSlot string prerelease;
    @semVerBuildSlot       string build;
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
    mixin layoutBody!(
        InternalFlag,                            bool,  "stableFlag", 1,
        Component(printOrder: 2, printWidth: 2), ulong, "patch",     24,
        Component(printOrder: 1, printWidth: 2), ulong, "minor",     24,
        Component(printOrder: 0),                ulong, "major",     15,
    );

    @semVerPrereleaseSlot string prerelease;
    @semVerBuildSlot       string build;
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
    mixin layoutBody!(
        InternalFlag,                            bool,  "stableFlag", 1,
        Component(printOrder: 2, printWidth: 4), ulong, "patch",     24,
        Component(printOrder: 1),                ulong, "minor",     24,
        Component(printOrder: 0),                ulong, "major",     15,
    );

    @semVerPrereleaseSlot string prerelease;
    @semVerBuildSlot       string build;
}

/// Vim-style version.
alias VimVer = Version!VimLayout;

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.core_cli.lifetime : recycledErrorInstance;
    import sparkles.core_cli.smallbuffer : checkToString;
    import sparkles.versions.parser : parse, ParseMode;
    import core.exception : AssertError;

    /// Throws a recycled AssertError with a fixed message. The body is
    /// `@trusted` because `recycledErrorInstance` is `@system`
    /// (it parks the Error object in a static buffer).
    private void throwAssert(in char[] msg, string file, size_t line)
        @trusted pure nothrow @nogc
    {
        throw recycledErrorInstance!AssertError(msg, file, line);
    }

    /// Parses `s` for `Layout`; throws a recycled `AssertError` on parse
    /// failure so the caller stays `@safe pure nothrow @nogc`. The
    /// `file`/`line` defaults capture the call site of the helper.
    /// Takes `s` non-`scope` because the returned value may alias the
    /// input via the prerelease/build slots; tests pass immutable
    /// globals so this is safe in practice.
    Version!Layout checkParse(Layout)(
        string s,
        ParseMode mode = ParseMode.strict,
        string file = __FILE__, size_t line = __LINE__,
    ) @safe pure nothrow @nogc
    {
        auto result = parse!Layout(s, mode);
        if (result.hasError)
            throwAssert("parse failed", file, line);
        return result.value;
    }

    /// Parses `s` and asserts `toString` reproduces `expected` (or `s`
    /// itself when `expected` is null).
    void checkRoundTrip(Layout)(
        string s,
        string expected = null,
        ParseMode mode = ParseMode.strict,
        string file = __FILE__, size_t line = __LINE__,
    ) @safe pure nothrow @nogc
    {
        auto v = checkParse!Layout(s, mode, file, line);
        checkToString(v, expected.length ? expected : s, file, line);
    }

    /// Asserts that `s` is rejected by `Layout`'s parser in `mode`.
    void checkRejects(Layout)(
        string s,
        ParseMode mode = ParseMode.strict,
        string file = __FILE__, size_t line = __LINE__,
    ) @safe pure nothrow @nogc
    {
        if (parse!Layout(s, mode).hasValue)
            throwAssert("expected rejection", file, line);
    }

    /// Parses each string and asserts the resulting versions form a
    /// strictly ascending chain. Uses a typesafe variadic so callers
    /// write `checkAscending!Layout("a", "b", "c")` without an
    /// intermediate array literal.
    void checkAscending(Layout)(string[] series...)
        @safe pure nothrow @nogc
    {
        foreach (i; 1 .. series.length)
        {
            const lhs = checkParse!Layout(series[i - 1]);
            const rhs = checkParse!Layout(series[i]);
            if (!(lhs < rhs))
                throwAssert("ascending order violated", __FILE__, __LINE__);
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("presets.SemVer.realWorldVersions")
@safe pure
unittest
{
    // 18 strict-SemVer products from PRESETS.md §2 round-trip through
    // SemVerLayout in strict mode. Each version is associated with its
    // product so a failure points back to the catalogue entry.
    static immutable string[string] cases = [
        "Node.js":      "20.13.1",
        "Rust":         "1.78.0",
        "Kubernetes":   "1.30.0",
        "Angular":      "17.3.0",
        "React":        "18.3.1",
        "Linux Kernel": "6.8.9",
        "Docker":       "26.1.1",
        "Git":          "2.45.1",
        "PHP":          "8.3.7",
        "Ruby":         "3.3.1",
        "Nginx":        "1.26.0",
        "Apache HTTP":  "2.4.59",
        "Redis":        "7.2.4",
        "MongoDB":      "7.0.8",
        "SQLite":       "3.45.3",
        "cURL":         "8.7.1",
        "FFmpeg":       "7.0.1",
        "macOS":        "14.5.1",
    ];

    foreach (product, s; cases)
    {
        auto v = parse!SemVerLayout(s, ParseMode.strict);
        assert(v.hasValue, product);
        checkToString(v.value, s);
    }
}

@("presets.SemVer.postgresLooseMode")
@safe pure nothrow @nogc
unittest
{
    // PostgreSQL ships 2-part versions (16.3); loose mode infills patch=0.
    auto v = checkParse!SemVerLayout("16.3", ParseMode.loose);
    checkToString(v, "16.3.0");
    assert(v.major == 16);
    assert(v.minor == 3);
    assert(v.patch == 0);
}

@("presets.Dmd.parsesDlangHistoricalAndCurrent")
@safe pure nothrow @nogc
unittest
{
    // Real Dlang/DMD versions across eras: historical (zero-padded minor),
    // current, and very old.
    checkRoundTrip!DmdLayout("2.079.0");
    checkRoundTrip!DmdLayout("2.111.0");
    checkRoundTrip!DmdLayout("1.075.0");
}

@("presets.Dmd.ordering")
@safe pure nothrow @nogc
unittest
{
    checkAscending!DmdLayout("2.079.0", "2.111.0");
}

@("presets.CalVerYYMM.ubuntu")
@safe pure nothrow @nogc
unittest
{
    // Ubuntu 24.04.1 LTS (real release, Aug 2024).
    auto v = checkParse!CalVerYYMMLayout("24.04.1");
    checkToString(v, "24.04.1");
    assert(v.major == 24);
    assert(v.minor == 4);
    assert(v.patch == 1);

    // Unpadded month is rejected.
    checkRejects!CalVerYYMMLayout("24.4.1");
}

@("presets.CalVerYYMM.ordering")
@safe pure nothrow @nogc
unittest
{
    checkAscending!CalVerYYMMLayout(
        "24.04.1", "24.04.2", "24.10.1", "25.04.1");
}

@("presets.CalVerYYYYMMDD.arch")
@safe pure nothrow @nogc
unittest
{
    // Arch Linux 2024.05.01 (real release).
    auto v = checkParse!CalVerYYYYMMDDLayout("2024.05.01");
    checkToString(v, "2024.05.01");
    assert(v.major == 2024);
    assert(v.minor == 5);
    assert(v.patch == 1);

    // Day must be 2 digits.
    checkRejects!CalVerYYYYMMDDLayout("2024.05.1");
}

@("presets.CalVerYYYYMMDD.ordering")
@safe pure nothrow @nogc
unittest
{
    checkAscending!CalVerYYYYMMDDLayout(
        "2024.05.01", "2024.05.02", "2024.06.01", "2025.01.01");
}

@("presets.Vim.fourDigitPatch")
@safe pure nothrow @nogc
unittest
{
    // Vim 9.1.0400 (real patch from github.com/vim/vim).
    auto v = checkParse!VimLayout("9.1.0400");
    checkToString(v, "9.1.0400");
    assert(v.major == 9);
    assert(v.minor == 1);
    assert(v.patch == 400);

    // 3-digit patch rejected by width rule.
    checkRejects!VimLayout("9.1.400");

    // Higher patch comes through unpadded since natural width > 4.
    checkRoundTrip!VimLayout("9.1.10000");
}

@("presets.Vim.ordering")
@safe pure nothrow @nogc
unittest
{
    checkAscending!VimLayout("9.1.0399", "9.1.0400", "9.2.0001");
}
