/**
The Cachix side of a pin run: which of the cache's pins fall outside the set
(TC24).

Each operation takes its HTTP verb as a template argument, so tests script
the responses; `liveGet` and `liveDelete` are the `std.net.curl`
implementations. The auth token travels in a request header, never on a
command line.
*/
module derivation_pin_cachix;

import std.format : format;

import expected : Expected, err, ok;

import derivation_pin_set : Target, parsePinList, pinUrl, pinsUrl, stalePins;

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
