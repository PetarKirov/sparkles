/++
SemVer bump policy.

`suggestBump` encodes the rule documented in `docs/guidelines/release.md`:
pre-1.0 a breaking change or a feature suggests a *minor* bump (a breaking change
does not force a major while the major is still `0`); from 1.0 on the usual SemVer
mapping applies. `applyBump` builds the next $(REF SemVer,
sparkles,versions,schemes,semver) by hand — the versions library has no increment
helper.
+/
module bump;

import std.typecons : Nullable, nullable;

import sparkles.versions.schemes.semver : SemVer;

import stats : CommitTally;

@safe pure nothrow @nogc:

/// The three SemVer bump magnitudes.
enum BumpKind
{
    patch,
    minor,
    major,
}

/// Suggests a bump from the commit tally and the current version, following the
/// release-guide policy (pre-1.0: breaking OR feat ⇒ minor, else patch;
/// post-1.0: breaking ⇒ major, feat ⇒ minor, else patch).
BumpKind suggestBump(in CommitTally t, in SemVer current)
{
    const pre1 = current.major == 0;
    if (pre1)
    {
        if (t.breaking > 0 || t.feat > 0)
            return BumpKind.minor;
        return BumpKind.patch;
    }

    if (t.breaking > 0)
        return BumpKind.major;
    if (t.feat > 0)
        return BumpKind.minor;
    return BumpKind.patch;
}

/// Applies `kind` to `v`, zeroing the lower components (and dropping any
/// prerelease/build, since the result is a fresh stable release).
SemVer applyBump(in SemVer v, BumpKind kind)
{
    final switch (kind)
    {
        case BumpKind.major:
            return SemVer(major: v.major + 1, minor: 0, patch: 0);
        case BumpKind.minor:
            return SemVer(major: v.major, minor: v.minor + 1, patch: 0);
        case BumpKind.patch:
            return SemVer(major: v.major, minor: v.minor, patch: v.patch + 1);
    }
}

/// The version suggested when there are no prior tags (the first release).
SemVer firstReleaseVersion() => SemVer(major: 0, minor: 1, patch: 0);

/// Parses a `--bump` token (`major`/`minor`/`patch`); null on an unknown token.
Nullable!BumpKind parseBumpKind(scope const(char)[] s)
{
    switch (s)
    {
        case "major": return nullable(BumpKind.major);
        case "minor": return nullable(BumpKind.minor);
        case "patch": return nullable(BumpKind.patch);
        default:      return Nullable!BumpKind.init;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("bump.suggest.pre1")
@safe pure nothrow @nogc
unittest
{
    const v0 = SemVer(major: 0, minor: 4, patch: 0);
    assert(suggestBump(CommitTally(breaking: 1), v0) == BumpKind.minor);
    assert(suggestBump(CommitTally(feat: 2), v0) == BumpKind.minor);
    assert(suggestBump(CommitTally(fix: 3), v0) == BumpKind.patch);
    assert(suggestBump(CommitTally(total: 1), v0) == BumpKind.patch);
}

@("bump.suggest.post1")
@safe pure nothrow @nogc
unittest
{
    const v1 = SemVer(major: 1, minor: 2, patch: 3);
    assert(suggestBump(CommitTally(breaking: 1, feat: 1), v1) == BumpKind.major);
    assert(suggestBump(CommitTally(feat: 1), v1) == BumpKind.minor);
    assert(suggestBump(CommitTally(fix: 1), v1) == BumpKind.patch);
}

@("bump.apply.zeroesLowerComponents")
@safe pure nothrow @nogc
unittest
{
    const v = SemVer(major: 0, minor: 4, patch: 7);
    assert(applyBump(v, BumpKind.major) == SemVer(major: 1, minor: 0, patch: 0));
    assert(applyBump(v, BumpKind.minor) == SemVer(major: 0, minor: 5, patch: 0));
    assert(applyBump(v, BumpKind.patch) == SemVer(major: 0, minor: 4, patch: 8));
}

@("bump.parseBumpKind")
@safe pure nothrow @nogc
unittest
{
    assert(parseBumpKind("minor").get == BumpKind.minor);
    assert(parseBumpKind("major").get == BumpKind.major);
    assert(parseBumpKind("patch").get == BumpKind.patch);
    assert(parseBumpKind("nonsense").isNull);
}
