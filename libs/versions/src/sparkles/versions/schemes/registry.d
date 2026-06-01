/**
Compile-time scheme registry — the CTFE association from a published pURL/VERS
scheme label to its built-in scheme struct.

The VERS and pURL interop layers (`sparkles.versions.vers`,
`sparkles.versions.purl`) dispatch through this registry. It is purely a
compile-time facility: there is no runtime lookup table and no virtual
dispatch — the runtime `parseVersAny` / `parsePurlVersion` entry points (M5)
generate their `switch` over $(LREF publishedSchemes) at compile time.

Two views over the shipped schemes:

$(UL
    $(LI $(LREF allSchemes) — every shipped scheme struct, including the
        D-internal compact schemes (`Dmd`, `Tiny`, the CalVer schemes,
        `VimVer`). Used by code that must enumerate the whole catalogue, e.g.
        building the `AnyVersion`/`AnyRange` sum types (M5).)
    $(LI $(LREF publishedSchemes) — only the schemes that carry a real,
        published Package-URL type (`semver`, `pypi`, `maven`, `deb`,
        `generic`). The D-internal schemes declare a synthetic, scheme-named
        `purlType` solely to satisfy `isVersionScheme`; per SPEC §6.1 those
        synthetic identifiers are $(B not) published pURL types, so an
        incoming `pkg:dmd/…` or `vers:dmd/…` is never resolved to an internal
        scheme. $(LREF schemeForPurlType) resolves against this view only.)
)

See `docs/specs/versions/SPEC.md` §9 (VERS interop) and §6.1 (synthetic
purlTypes must not shadow published types).
*/
module sparkles.versions.schemes.registry;

import std.meta : AliasSeq, Filter;

import sparkles.versions.schemes.semver : SemVer;
import sparkles.versions.schemes.dmd : Dmd;
import sparkles.versions.schemes.dmd_compact : DmdCompact;
import sparkles.versions.schemes.tiny : Tiny;
import sparkles.versions.schemes.calver_yymm : CalVerYYMM;
import sparkles.versions.schemes.calver_yyyymmdd : CalVerYYYYMMDD;
import sparkles.versions.schemes.vim : VimVer;
import sparkles.versions.schemes.pypi : PypiVersion;
import sparkles.versions.schemes.maven : MavenVersion;
import sparkles.versions.schemes.deb : DebianVersion;
import sparkles.versions.schemes.generic : Generic;

import sparkles.versions.traits : isVersionScheme;

// ---------------------------------------------------------------------------
// The two scheme views
// ---------------------------------------------------------------------------

/**
Every shipped scheme struct, as an `AliasSeq` — the full eleven-scheme
catalogue, internal compact schemes included. Code that enumerates all
schemes (e.g. assembling the `AnyVersion`/`AnyRange` sum types in M5) walks
this list; $(LREF schemeForPurlType) does $(B not) — it resolves only the
$(LREF publishedSchemes) view, so an internal synthetic `purlType` cannot
shadow a real ecosystem type.
*/
alias allSchemes = AliasSeq!(
    SemVer, Dmd, DmdCompact, Tiny,
    CalVerYYMM, CalVerYYYYMMDD, VimVer,
    PypiVersion, MavenVersion, DebianVersion, Generic);

/// The pURL types the project treats as published (real ecosystem types). A
/// shipped scheme participates in runtime `vers:`/`pkg:` resolution iff its
/// `purlType` is in this set; the D-internal schemes' synthetic identifiers
/// are deliberately absent (SPEC §6.1).
enum string[] publishedPurlTypes =
    ["semver", "pypi", "maven", "deb", "generic"];

private enum bool isPublished(S) = () {
    foreach (t; publishedPurlTypes)
        if (S.purlType == t)
            return true;
    return false;
}();

/**
The schemes carrying a real published pURL type, as an `AliasSeq` — the
subset of $(LREF allSchemes) whose `purlType` is in
$(LREF publishedPurlTypes). This is the view the VERS/pURL layers dispatch
through; $(LREF schemeForPurlType) resolves against it.
*/
alias publishedSchemes = Filter!(isPublished, allSchemes);

// ---------------------------------------------------------------------------
// purlType → scheme resolution
// ---------------------------------------------------------------------------

/**
Resolves a published pURL/VERS scheme label to its built-in scheme struct at
compile time, or fails to compile when no published scheme matches.

Resolution is over $(LREF publishedSchemes) only: a D-internal scheme's
synthetic `purlType` (e.g. `"dmd"`, `"tiny"`, `"calver_yymm"`) does $(B not)
resolve, so `schemeForPurlType!"dmd"` is a compile error (SPEC §6.1). This is
the static counterpart of the runtime dispatch the M5 `parseVersAny` /
`parsePurlVersion` entry points perform;
`parseVersAs!(schemeForPurlType!"semver")` ties the two together.
*/
template schemeForPurlType(string purlType)
{
    private enum bool matches(S) = S.purlType == purlType;
    private alias hits = Filter!(matches, publishedSchemes);

    static assert(hits.length > 0,
        "No published built-in scheme has pURL type \"" ~ purlType ~ "\". "
        ~ "The D-internal schemes (Dmd, Tiny, the CalVer schemes, VimVer) "
        ~ "declare synthetic purlTypes that are not resolvable here "
        ~ "(SPEC §6.1).");
    alias schemeForPurlType = hits[0];
}

/// `true` when `purlType` resolves to a published scheme — the non-failing
/// probe behind $(LREF schemeForPurlType), useful in `static if`.
enum bool hasSchemeForPurlType(string purlType) =
    __traits(compiles, schemeForPurlType!purlType);

// ---------------------------------------------------------------------------
// (purlType, Scheme) pair enumeration (for M4/M5)
// ---------------------------------------------------------------------------

/**
The published scheme catalogue as a compile-time array of
$(LREF SchemePurlEntry) — `(purlType, schemeName)` pairs, in
$(LREF publishedSchemes) order. M4/M5 enumerate this to generate a runtime
label → scheme `switch`; the `Scheme` alias itself is recovered statically
via `schemeForPurlType!(entry.purlType)`.
*/
struct SchemePurlEntry
{
    /// The scheme's published pURL type (e.g. `"semver"`).
    string purlType;
    /// The scheme struct's `.stringof` name (e.g. `"SemVer"`), for
    /// diagnostics and code generation.
    string schemeName;
}

/// ditto
enum SchemePurlEntry[] publishedSchemeEntries = () {
    SchemePurlEntry[] entries;
    static foreach (S; publishedSchemes)
        entries ~= SchemePurlEntry(S.purlType, S.stringof);
    return entries;
}();

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("schemes.registry.allSchemes.count")
@safe pure nothrow @nogc
unittest
{
    static assert(allSchemes.length == 11);
    static foreach (S; allSchemes)
        static assert(isVersionScheme!S);
}

@("schemes.registry.schemeForPurlType.published")
@safe pure nothrow @nogc
unittest
{
    static assert(is(schemeForPurlType!"semver" == SemVer));
    static assert(is(schemeForPurlType!"pypi" == PypiVersion));
    static assert(is(schemeForPurlType!"maven" == MavenVersion));
    static assert(is(schemeForPurlType!"deb" == DebianVersion));
    static assert(is(schemeForPurlType!"generic" == Generic));
}

@("schemes.registry.schemeForPurlType.internalSyntheticNotResolved")
@safe pure nothrow @nogc
unittest
{
    // The D-internal schemes declare synthetic purlTypes (SPEC §6.1) that
    // must not shadow / masquerade as published types: they do not resolve.
    static assert(!hasSchemeForPurlType!"dmd");
    static assert(!hasSchemeForPurlType!"dmd_compact");
    static assert(!hasSchemeForPurlType!"tiny");
    static assert(!hasSchemeForPurlType!"calver_yymm");
    static assert(!hasSchemeForPurlType!"calver_yyyymmdd");
    static assert(!hasSchemeForPurlType!"vim");

    // A wholly unknown type also fails to resolve.
    static assert(!hasSchemeForPurlType!"nonexistent");
}

@("schemes.registry.publishedSchemes.view")
@safe pure nothrow @nogc
unittest
{
    static assert(publishedSchemes.length == 5);
    static assert(is(publishedSchemes[0] == SemVer));

    // Every published scheme's purlType is in the published set.
    static foreach (S; publishedSchemes)
        static assert(hasSchemeForPurlType!(S.purlType));
}

@("schemes.registry.publishedSchemeEntries.pairs")
@safe pure nothrow @nogc
unittest
{
    static assert(publishedSchemeEntries.length == 5);
    static assert(publishedSchemeEntries[0] == SchemePurlEntry("semver", "SemVer"));

    // Each entry round-trips back to its scheme struct via schemeForPurlType.
    static foreach (e; publishedSchemeEntries)
        static assert(schemeForPurlType!(e.purlType).stringof == e.schemeName);
}
