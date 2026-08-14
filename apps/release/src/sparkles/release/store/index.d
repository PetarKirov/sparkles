/**
Reading the published `index-v2.json`.

Two questions are asked of it, and both are safety checks rather than
conveniences:

$(UL
$(LI $(I What is already published?) — a new `versionCode` must be strictly
    greater than every code already in `repo/` and `archive/`, and republishing
    an existing one must fail rather than overwrite bytes users already have
    (`FDR7`).)
$(LI $(I Did the app survive indexing?) — an `AllowedAPKSigningKeys` mismatch
    is a WARNING in fdroidserver: `fdroid update` exits 0 and writes a valid,
    signed index containing no packages at all. The exit code cannot be
    trusted; the index has to be read back.)
)

The DOM is walked directly rather than decoded into a model: only two fields are
needed, and index-v2 grows new ones between fdroidserver releases.
*/
module sparkles.release.store.index;

import std.json : JSONValue, JSONType;

@safe:

/// What an index says about one application.
struct IndexedApp
{
    /// Every `versionCode` the index lists, unordered.
    uint[] versionCodes;

    /// True when the application appears at all.
    bool present;

    /// The highest code present, or 0 when there are none.
    uint highestVersionCode() const pure nothrow @nogc
    {
        uint best = 0;
        foreach (c; versionCodes)
            if (c > best)
                best = c;
        return best;
    }
}

/**
Extracts one application's entry from parsed index-v2 JSON.

A missing `packages` object, a missing application, or a malformed entry all
yield `present == false` rather than throwing: an empty repository is the normal
state of a first publish.
*/
// NOTE: `const JSONValue`, not `in JSONValue`. `-preview=in` implies `scope`,
// and `JSONValue`'s accessors are not `scope`-annotated, so the `in` form does
// not compile under dip1000 — the clash documented in AGENTS.md.
IndexedApp appFromIndex(const JSONValue index, string applicationId) pure
{
    import std.array : appender;

    IndexedApp result;

    if (index.type != JSONType.object || "packages" !in index)
        return result;

    const packages = index["packages"];
    if (packages.type != JSONType.object || applicationId !in packages)
        return result;

    result.present = true;

    const app = packages[applicationId];
    if (app.type != JSONType.object || "versions" !in app)
        return result;

    const versions = app["versions"];
    if (versions.type != JSONType.object)
        return result;

    auto codes = appender!(uint[]);
    // `objectNoRef`, not `object`: the latter returns by `ref` and is `@system`.
    foreach (_, entry; versions.objectNoRef)
    {
        if (entry.type != JSONType.object || "manifest" !in entry)
            continue;
        const manifest = entry["manifest"];
        if (manifest.type != JSONType.object || "versionCode" !in manifest)
            continue;
        const code = manifest["versionCode"];
        if (code.type == JSONType.integer && code.integer >= 0 && code.integer <= uint.max)
            codes ~= cast(uint) code.integer;
    }
    result.versionCodes = codes[];
    return result;
}

/// Why a version cannot be published over what is already there.
enum PublishRefusal
{
    none,
    /// This exact `versionCode` is already published. Replacing published bytes
    /// is never the fix for a bad release; cut a new tag.
    alreadyPublished,
    /// A lower code than something already published — F-Droid orders by code,
    /// so clients would never offer it as an update.
    wouldGoBackwards,
}

/// Checks a candidate `versionCode` against what an index already carries.
PublishRefusal checkPublishable(const IndexedApp published, uint candidate) pure nothrow @nogc
{
    foreach (c; published.versionCodes)
        if (c == candidate)
            return PublishRefusal.alreadyPublished;

    if (candidate < published.highestVersionCode)
        return PublishRefusal.wouldGoBackwards;

    return PublishRefusal.none;
}

/// A one-line explanation suitable for printing to a user.
string describe(PublishRefusal r) pure nothrow @nogc
{
    final switch (r)
    {
    case PublishRefusal.none:
        return "publishable";
    case PublishRefusal.alreadyPublished:
        return "this versionCode is already published — cut a new tag rather than "
            ~ "replacing bytes users already have";
    case PublishRefusal.wouldGoBackwards:
        return "a higher versionCode is already published — clients order by it "
            ~ "and would never offer this as an update";
    }
}

version (unittest)
{
    import std.json : parseJSON;

    // Shaped like the real index-v2.json fdroidserver 2.4.2 emits.
    private enum sampleIndex = `{
        "repo": {"name": {"en-US": "sparkles"}},
        "packages": {
            "dev.sparkles.hue": {
                "metadata": {"license": "BSL-1.0"},
                "versions": {
                    "abc123": {"manifest": {"versionCode": 1024, "versionName": "0.4.0"}},
                    "def456": {"manifest": {"versionCode": 1025, "versionName": "0.4.1"}}
                }
            }
        }
    }`;
}

@("store.index.readsPublishedVersionCodes")
@safe unittest
{
    import std.algorithm : canFind;

    const app = appFromIndex(parseJSON(sampleIndex), "dev.sparkles.hue");
    assert(app.present);
    assert(app.versionCodes.length == 2);
    assert(app.versionCodes.canFind(1024u));
    assert(app.versionCodes.canFind(1025u));
    assert(app.highestVersionCode == 1025);
}

@("store.index.emptyRepositoryIsNormal")
@safe unittest
{
    // A first publish, and the shape fdroidserver leaves behind when an
    // AllowedAPKSigningKeys mismatch drops every APK — the case the exit code
    // does not report.
    const none = appFromIndex(parseJSON(`{"repo": {}, "packages": {}}`), "dev.sparkles.hue");
    assert(!none.present);
    assert(none.highestVersionCode == 0);

    const other = appFromIndex(parseJSON(sampleIndex), "dev.sparkles.other");
    assert(!other.present);

    // Malformed input degrades to "absent" rather than throwing.
    assert(!appFromIndex(parseJSON(`{}`), "dev.sparkles.hue").present);
    assert(!appFromIndex(parseJSON(`[]`), "dev.sparkles.hue").present);
}

@("store.index.refusesRepublishAndDowngrade")
@safe unittest
{
    const app = appFromIndex(parseJSON(sampleIndex), "dev.sparkles.hue");

    assert(checkPublishable(app, 1280) == PublishRefusal.none);
    assert(checkPublishable(app, 1025) == PublishRefusal.alreadyPublished);
    assert(checkPublishable(app, 1024) == PublishRefusal.alreadyPublished);
    assert(checkPublishable(app, 1000) == PublishRefusal.wouldGoBackwards);

    // Against an empty repository anything goes.
    IndexedApp fresh;
    assert(checkPublishable(fresh, 1) == PublishRefusal.none);
}
