/**
The release tag → APK version mapping.

Android needs two version fields: a human-facing `versionName`, and a
`versionCode` — a monotonic integer that every distribution channel orders
builds by. `sparkles:versions` already has a name for the second concept:
$(D_INLINECODE orderKey), specified as "a monotonic unsigned-integer key"
obeying `sign(a.orderKey <=> b.orderKey) == sign(a <=> b)`. So this module
invents no arithmetic; it composes two shipped schemes.

$(UL
$(LI `SemVer` parses the tag. Its loose parser accepts the `v` prefix, and it
    models prereleases — which is how they are rejected rather than silently
    flattened.)
$(LI `Tiny` produces the code: a 4-byte scheme whose `orderKey` packs
    `major:16 | minor:8 | patch:8`, with `tiny.orderKey.matchesOpCmp` already
    asserting the monotonicity law across a corpus.)
)

The composition also produces Android's bound for free. A `versionCode` is a
$(I signed) int32, so it must not exceed 2147483647 — and `SemVer` independently
caps `major` at 32767 (15 bits), while `Tiny` caps `minor` and `patch` at 255.
The largest value this mapping can emit is therefore
`(32767 << 16) | (255 << 8) | 255 == 2147483647`: exactly `int.max`, and never
past it. Nothing here has to range-check the result.

See `docs/specs/hue/fdroid.md` § Version mapping (`FDR5`).
*/
module sparkles.release.store.version_map;

import sparkles.versions.schemes.semver : SemVer;
import sparkles.versions.schemes.tiny : Tiny;

@safe:

/// The two version fields aapt2 stamps into an APK.
struct ApkVersion
{
    /// Human-facing, and what F-Droid displays: the tag without its `v`.
    string name;

    /// The monotonic ordering key. `Tiny.orderKey` of the same triple.
    uint code;
}

/// Why a tag could not be mapped. Each case is a refusal to publish something
/// ambiguous, not a parser limitation to work around.
enum VersionMapError
{
    /// Not a version at all (`SemVer` rejected it).
    unparseable,
    /// `1.2.3-rc.1`. A prerelease has no business on a public app channel, and
    /// `Tiny` cannot represent one, so it would silently compare equal to the
    /// release it precedes.
    prerelease,
    /// `1.2.3+build.5`. Build metadata is ignored in SemVer ordering, so two
    /// distinct tags would map to one `versionCode`.
    buildMetadata,
    /// `minor` or `patch` above 255 — outside the packed key's field widths.
    componentTooLarge,
}

/// The outcome of $(LREF apkVersionForTag).
struct VersionMapResult
{
    ApkVersion version_;
    VersionMapError error;
    bool ok;

    /// The offending input, for a message the caller can print verbatim.
    string tag;
}

/**
Maps a release tag to its APK version fields.

Accepts `v0.4.0` and `0.4.0` alike. Returns a failed result — never throws —
for anything that cannot be published unambiguously.
*/
VersionMapResult apkVersionForTag(string tag)
{
    import std.conv : text;

    auto fail(VersionMapError e) => VersionMapResult(ApkVersion.init, e, false, tag);

    auto parsed = SemVer.parseLoose(tag);
    if (!parsed.hasValue)
        return fail(VersionMapError.unparseable);

    const sv = parsed.value;
    if (sv.prerelease.length)
        return fail(VersionMapError.prerelease);
    if (sv.build.length)
        return fail(VersionMapError.buildMetadata);

    // Round-trip the numeric triple through `Tiny` rather than packing it here,
    // so the field-width bounds stay the library's business and are enforced by
    // the parser that documents them.
    const triple = text(sv.major, ".", sv.minor, ".", sv.patch);
    auto tiny = Tiny.parse(triple);
    if (!tiny.hasValue)
        return fail(VersionMapError.componentTooLarge);

    return VersionMapResult(ApkVersion(triple, tiny.value.orderKey), VersionMapError.init, true, tag);
}

/// A one-line explanation suitable for printing to a user.
string describe(VersionMapError e) pure nothrow @nogc
{
    final switch (e)
    {
    case VersionMapError.unparseable:
        return "not a SemVer version (expected vMAJOR.MINOR.PATCH)";
    case VersionMapError.prerelease:
        return "prereleases are not published to the app stores";
    case VersionMapError.buildMetadata:
        return "build metadata is ignored in ordering, so it cannot distinguish two releases";
    case VersionMapError.componentTooLarge:
        return "minor and patch must each be <= 255 to fit the packed versionCode";
    }
}

@("store.version_map.tagsFromTheRepo")
@safe unittest
{
    // The tags this repository has actually cut, and the next few shapes.
    static struct Case { string tag; string name; uint code; }
    static immutable cases = [
        Case("v0.0.1", "0.0.1", 1),
        Case("v0.1.0", "0.1.0", 256),
        Case("v0.4.0", "0.4.0", 1024),
        Case("v0.4.1", "0.4.1", 1025),
        Case("v0.5.0", "0.5.0", 1280),
        Case("v1.0.0", "1.0.0", 65536),
        // Without the `v`, as a convenience.
        Case("0.4.0", "0.4.0", 1024),
    ];

    foreach (c; cases)
    {
        const r = apkVersionForTag(c.tag);
        assert(r.ok, c.tag);
        assert(r.version_.name == c.name, c.tag);
        assert(r.version_.code == c.code, c.tag);
    }
}

@("store.version_map.isMonotonicInTagOrder")
@safe unittest
{
    // The property the whole scheme rests on: a later release must never sort
    // below an earlier one, or F-Droid will not offer it as an update.
    static immutable ascending = [
        "v0.0.1", "v0.0.2", "v0.1.0", "v0.2.0", "v0.3.0",
        "v0.4.0", "v0.4.1", "v0.5.0", "v1.0.0", "v1.0.1", "v2.0.0",
    ];

    uint previous = 0;
    foreach (tag; ascending)
    {
        const r = apkVersionForTag(tag);
        assert(r.ok, tag);
        assert(r.version_.code > previous, tag);
        previous = r.version_.code;
    }
}

@("store.version_map.staysWithinAndroidsSignedInt32")
@safe unittest
{
    // A versionCode is a SIGNED int32. The largest triple this mapping can
    // accept is SemVer's major ceiling with Tiny's minor/patch ceilings, and it
    // lands exactly on int.max — so the bound holds by construction rather than
    // by a range check.
    const r = apkVersionForTag("32767.255.255");
    assert(r.ok);
    assert(r.version_.code == 2147483647);
    assert(r.version_.code <= int.max);

    // One past SemVer's 15-bit major is refused by the parser, not by us.
    assert(!apkVersionForTag("32768.0.0").ok);
}

@("store.version_map.refusesWhatCannotBePublished")
@safe unittest
{
    static struct Case { string tag; VersionMapError error; }
    static immutable cases = [
        Case("v0.4.0-rc.1", VersionMapError.prerelease),
        Case("v0.4.0+build.5", VersionMapError.buildMetadata),
        // Tiny packs minor/patch into 8 bits each.
        Case("v0.256.0", VersionMapError.componentTooLarge),
        Case("v0.0.256", VersionMapError.componentTooLarge),
        Case("not-a-tag", VersionMapError.unparseable),
        Case("", VersionMapError.unparseable),
    ];

    foreach (c; cases)
    {
        const r = apkVersionForTag(c.tag);
        assert(!r.ok, c.tag);
        assert(r.error == c.error, c.tag);
        assert(describe(r.error).length);
    }
}
