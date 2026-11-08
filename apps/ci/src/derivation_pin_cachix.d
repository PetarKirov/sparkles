/**
The Cachix side of a pin run: which pin-set outputs the cache serves
(`--check`, TC23's gate) and which of its pins fall outside the set (TC24).

Each operation takes its HTTP verb as a template argument, so tests script
the responses; `liveHead`, `liveGet` and `liveDelete` are the `std.net.curl`
implementations. The auth token travels in a request header, never on a
command line.
*/
module derivation_pin_cachix;

import std.algorithm.iteration : filter, map;
import std.array : array, join;
import std.format : format;

import sparkles.base.expected : Expected, err, ok;

import derivation_pin_set : Target, narinfoUrl, parsePinList, pinUrl, pinsUrl, stalePins;

/// Whether the cache serves one output.
enum Presence : ubyte
{
    cached,
    missing,
    unknown, /// The question got no answer: a network error or an unexpected status.
}

/// One output's narinfo query.
struct CachedCheck
{
    Target target;
    Presence presence;
    string detail; /// The narinfo URL, or why the query has no answer.
}

/**
Query `<cacheUri>/<hash>.narinfo` for every target's out path. `head` takes a
URL and returns its HTTP status: 200 is cached, 404 is missing, anything else
(and a transport error) is unknown.
*/
CachedCheck[] checkCached(alias head)(Target[] targets, string cacheUri)
{
    CachedCheck check(Target target)
    {
        const url = narinfoUrl(cacheUri, target.outPath);
        if (url.hasError)
            return CachedCheck(target, Presence.unknown, url.error);
        const status = head(url.value);
        if (status.hasError)
            return CachedCheck(target, Presence.unknown, status.error);
        if (status.value == 200)
            return CachedCheck(target, Presence.cached, url.value);
        if (status.value == 404)
            return CachedCheck(target, Presence.missing, url.value);
        return CachedCheck(target, Presence.unknown, format("HTTP %d from %s", status.value, url.value));
    }

    return targets.map!check.array;
}

/**
`checkCached` across several caches, asked in order: an output is cached when
any of them serves it (and the later ones are not asked), missing when every
one answers 404, and unknown otherwise. A missing output's detail lists every
URL asked.
*/
CachedCheck[] checkCachedAny(alias head)(Target[] targets, string[] cacheUris)
{
    CachedCheck check(Target target)
    {
        CachedCheck[] answers;
        foreach (uri; cacheUris)
        {
            auto answer = checkCached!head([target], uri)[0];
            if (answer.presence == Presence.cached)
                return answer;
            answers ~= answer;
        }
        foreach (answer; answers)
            if (answer.presence == Presence.unknown)
                return answer;
        return CachedCheck(target, Presence.missing,
            answers.map!(answer => answer.detail).join(", "));
    }

    return targets.map!check.array;
}

@("pinCachix.checkCachedAny.firstServingCacheWins")
@safe
unittest
{
    enum cachix = "https://sparkles.cachix.org";
    enum r2 = "https://cache.sparkles.petar-kirov.dev";
    auto targets = [
        Target("toolchain-dmd", "x86_64-linux", "/nix/store/45iz365bm9kwm02x4ll7njn7vfqphq8h-dmd"),
        Target("toolchain-input-llvm-sparkles", "x86_64-linux",
            "/nix/store/v18d7sbkm3f85gdgskn10dbv1hz327m7-source"),
        Target("harfbuzz", "aarch64-linux", "/nix/store/ydgp3y3s65fgbv1gg5r6f3biay85sh5m-harfbuzz"),
        Target("skia-sparkles", "aarch64-darwin", "/nix/store/p0q348b2znkvndgmf15dhg11li4kilik-skia"),
    ];
    string[] asked;
    Expected!(ushort, string) head(string url)
    {
        asked ~= url;
        switch (url)
        {
            case cachix ~ "/45iz365bm9kwm02x4ll7njn7vfqphq8h.narinfo":
                return ok(cast(ushort) 200);
            case r2 ~ "/v18d7sbkm3f85gdgskn10dbv1hz327m7.narinfo":
                return ok(cast(ushort) 200);
            case cachix ~ "/p0q348b2znkvndgmf15dhg11li4kilik.narinfo":
                return err!ushort("connection reset");
            default:
                return ok(cast(ushort) 404);
        }
    }

    const checks = checkCachedAny!head(targets, [cachix, r2]);
    assert(asked.length == 7, "a hit in the first cache does not ask the second");
    assert(checks[0].presence == Presence.cached);
    assert(checks[1].presence == Presence.cached && checks[1].detail == r2
        ~ "/v18d7sbkm3f85gdgskn10dbv1hz327m7.narinfo", "served by the second cache alone");
    assert(checks[2].presence == Presence.missing);
    assert(checks[2].detail == cachix ~ "/ydgp3y3s65fgbv1gg5r6f3biay85sh5m.narinfo, "
        ~ r2 ~ "/ydgp3y3s65fgbv1gg5r6f3biay85sh5m.narinfo");
    assert(checks[3].presence == Presence.unknown,
        "no answer from one cache and a 404 from the other is not proof of absence");
}

/// True when every output is cached: the gate passes.
bool allCached(in CachedCheck[] checks) @safe pure nothrow @nogc
{
    foreach (check; checks)
        if (check.presence != Presence.cached)
            return false;
    return true;
}

/// One line per output that is not cached, for the failure report.
string[] uncachedLines(in CachedCheck[] checks) @safe pure
{
    return checks
        .filter!(check => check.presence != Presence.cached)
        .map!(check => format("%-8s %s  %s  (%s)",
            check.presence == Presence.missing ? "missing" : "unknown",
            check.target.pinName, check.target.outPath, check.detail))
        .array;
}

@("pinCachix.checkCached.statusClasses")
@safe
unittest
{
    enum uri = "https://sparkles.cachix.org";
    auto targets = [
        Target("toolchain-dmd", "x86_64-linux", "/nix/store/45iz365bm9kwm02x4ll7njn7vfqphq8h-dmd"),
        Target("harfbuzz", "aarch64-linux", "/nix/store/ydgp3y3s65fgbv1gg5r6f3biay85sh5m-harfbuzz"),
        Target("skia-sparkles", "aarch64-darwin", "/nix/store/p0q348b2znkvndgmf15dhg11li4kilik-skia"),
        Target("maple-mono", "x86_64-linux", "not-a-store-path"),
    ];
    string[] asked;
    Expected!(ushort, string) head(string url)
    {
        asked ~= url;
        if (url == uri ~ "/45iz365bm9kwm02x4ll7njn7vfqphq8h.narinfo")
            return ok(cast(ushort) 200);
        if (url == uri ~ "/ydgp3y3s65fgbv1gg5r6f3biay85sh5m.narinfo")
            return ok(cast(ushort) 404);
        return err!ushort("connection reset");
    }

    const checks = checkCached!head(targets, uri);
    assert(asked.length == 3, "an unparsable path asks nothing");
    assert(checks[0].presence == Presence.cached);
    assert(checks[1].presence == Presence.missing);
    assert(checks[2].presence == Presence.unknown && checks[2].detail == "connection reset");
    assert(checks[3].presence == Presence.unknown);
    assert(!allCached(checks));
    assert(allCached(checks[0 .. 1]));
    const lines = uncachedLines(checks);
    assert(lines.length == 3);
    assert(lines[0] == "missing  harfbuzz-aarch64-linux  /nix/store/ydgp3y3s65fgbv1gg5r6f3biay85sh5m-harfbuzz"
        ~ "  (https://sparkles.cachix.org/ydgp3y3s65fgbv1gg5r6f3biay85sh5m.narinfo)");
}

/// What pruning found, and what it did with it.
struct PruneReport
{
    string[] stale; /// Pins outside the set.
    string[] deleted; /// Of those, the ones the cache deleted. Empty in a dry run.
    string[] failures; /// One message per deletion the cache refused.
}

/**
Delete every pin of `cache` that `set` does not name; in a dry run, only find
them. `get` fetches a URL's body, `del` deletes a URL; both take the token,
which may be empty for `get` (the pin list of a public cache is public).
A pin list that cannot be read is an error, and nothing is deleted.
*/
Expected!(PruneReport, string) prunePins(alias get, alias del)(
    string cache,
    in Target[] set,
    string token,
    bool dryRun,
)
{
    auto body_ = get(pinsUrl(cache), token);
    if (body_.hasError)
        return err!PruneReport("listing the cache's pins failed: " ~ body_.error);
    auto listed = parsePinList(body_.value);
    if (listed.hasError)
        return err!PruneReport(listed.error);

    auto report = PruneReport(stale: stalePins(listed.value, set));
    if (dryRun)
        return ok(report);
    foreach (pin; report.stale)
    {
        const deleted = del(pinUrl(cache, pin), token);
        if (deleted.hasError)
            report.failures ~= format("deleting pin %s failed: %s", pin, deleted.error);
        else
            report.deleted ~= pin;
    }
    return ok(report);
}

@("pinCachix.prunePins.dryRunAndDelete")
@safe
unittest
{
    import std.algorithm.searching : endsWith;

    enum list = `[{"name":"skia-sparkles-x86_64-linux"},{"name":"toolchain-dub-x86_64-linux"},`
        ~ `{"name":"raylib-x86_64-linux"}]`;
    const set = [Target("skia-sparkles", "x86_64-linux")];
    string[] deletes;
    Expected!(string, string) get(string url, string token) =>
        url == "https://app.cachix.org/api/v1/cache/sparkles/pin" ? ok(list) : err!string("404");
    Expected!(void, string) del(string url, string token)
    {
        assert(token == "synthetic-token");
        deletes ~= url;
        return url.endsWith("/toolchain-dub-x86_64-linux") ? err!void("HTTP 403") : ok();
    }

    const dry = prunePins!(get, del)("sparkles", set, null, true);
    assert(dry.value.stale == ["raylib-x86_64-linux", "toolchain-dub-x86_64-linux"]);
    assert(dry.value.deleted.length == 0 && deletes.length == 0, "a dry run deletes nothing");

    const applied = prunePins!(get, del)("sparkles", set, "synthetic-token", false);
    assert(deletes == [
        "https://app.cachix.org/api/v1/cache/sparkles/pin/raylib-x86_64-linux",
        "https://app.cachix.org/api/v1/cache/sparkles/pin/toolchain-dub-x86_64-linux",
    ]);
    assert(applied.value.deleted == ["raylib-x86_64-linux"]);
    assert(applied.value.failures == ["deleting pin toolchain-dub-x86_64-linux failed: HTTP 403"]);

    deletes = null;
    const unreadable = prunePins!(get, del)("other", set, "synthetic-token", false);
    assert(unreadable.hasError && deletes.length == 0, "no list, no deletion");
}

/// HTTP status of a HEAD request to `url`.
Expected!(ushort, string) liveHead(string url) @system
{
    import std.net.curl : HTTP;

    try
    {
        auto http = HTTP(url);
        http.method = HTTP.Method.head;
        http.addRequestHeader("User-Agent", "sparkles-toolchain-pin");
        http.perform();
        return ok(http.statusLine.code);
    }
    catch (Exception e)
        return err!ushort(e.msg);
}

/// Body of a GET request to `url`; a non-2xx status is an error.
Expected!(string, string) liveGet(string url, string token) @system
{
    import std.net.curl : HTTP;

    try
    {
        auto http = HTTP(url);
        http.addRequestHeader("User-Agent", "sparkles-toolchain-pin");
        http.addRequestHeader("Accept", "application/json");
        if (token.length)
            http.addRequestHeader("Authorization", "Bearer " ~ token);
        ubyte[] received;
        http.onReceive = (ubyte[] data) { received ~= data; return data.length; };
        http.perform();
        const status = http.statusLine.code;
        if (status < 200 || status >= 300)
            return err!string(format("HTTP %d from %s", status, url));
        return ok(cast(string) received);
    }
    catch (Exception e)
        return err!string(e.msg);
}

/// A DELETE request to `url`; a non-2xx status is an error.
Expected!(void, string) liveDelete(string url, string token) @system
{
    import std.net.curl : HTTP;

    try
    {
        auto http = HTTP(url);
        http.method = HTTP.Method.del;
        http.addRequestHeader("User-Agent", "sparkles-toolchain-pin");
        http.addRequestHeader("Authorization", "Bearer " ~ token);
        http.onReceive = (ubyte[] data) => data.length;
        http.perform();
        const status = http.statusLine.code;
        if (status < 200 || status >= 300)
            return err!void(format("HTTP %d", status));
        return ok();
    }
    catch (Exception e)
        return err!void(e.msg);
}
