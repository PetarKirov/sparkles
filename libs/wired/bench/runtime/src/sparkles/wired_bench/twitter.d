/**
The canonical partial Twitter document for the typed `decode` op.

Every engine decodes `twitter.json` into this exact field subset (identical
mirrors exist in the Rust and C++ shims); the field names deliberately match
the JSON keys so no engine needs per-field renaming. Unknown JSON keys are
ignored everywhere — the struct-level UDAs opt mir-ion
(`@serdeIgnoreUnexpectedKeys`) and jsoniopipe (`@ignoreExtras`) into the
behavior the other engines already default to.

`TwitterStats` is the decode op's verification vehicle: wrapping 64-bit sums
and byte counts that every engine must reproduce exactly (id sums exceed
`ulong.max`, so *wrapping* addition is part of the contract — D and C++
wrap naturally, the Rust shim uses `wrapping_add`).
*/
module sparkles.wired_bench.twitter;

import std.json : JSONValue, parseJSON;

import iopipe.json.serialize : ignoreExtras;
import mir.serde : serdeIgnoreUnexpectedKeys;

@serdeIgnoreUnexpectedKeys @ignoreExtras
struct TwitterUser
{
    long id;
    string screen_name;
    long followers_count;
}

@serdeIgnoreUnexpectedKeys @ignoreExtras
struct TwitterStatus
{
    string created_at;
    long id;
    string text;
    TwitterUser user;
    long retweet_count;
    long favorite_count;
}

@serdeIgnoreUnexpectedKeys @ignoreExtras
struct Twitter
{
    TwitterStatus[] statuses;
}

/// The decode op's cross-engine checksum (all sums wrap on overflow).
struct TwitterStats
{
    ulong statusCount;
    ulong idSum;
    ulong userIdSum;
    ulong followersSum;
    ulong retweetSum;
    ulong favoriteSum;
    ulong textBytes;
    ulong screenNameBytes;
    ulong createdAtBytes;
}

/// The checksum of a decoded document.
TwitterStats statsOf(in Twitter t) @safe pure nothrow @nogc
{
    TwitterStats s;
    s.statusCount = t.statuses.length;
    foreach (const ref st; t.statuses)
    {
        s.idSum += cast(ulong) st.id;
        s.userIdSum += cast(ulong) st.user.id;
        s.followersSum += cast(ulong) st.user.followers_count;
        s.retweetSum += cast(ulong) st.retweet_count;
        s.favoriteSum += cast(ulong) st.favorite_count;
        s.textBytes += st.text.length;
        s.screenNameBytes += st.user.screen_name.length;
        s.createdAtBytes += st.created_at.length;
    }
    return s;
}

/// Manual extraction from a `std.json` DOM — the reference implementation
/// (and the `std.json` engine's own decode path). Parameters are
/// `const ref`, not `in`: `JSONValue.opIndex` is not `scope`-annotated, so
/// dip1000 rejects calling it on a `scope` value.
Twitter extractTwitter(const ref JSONValue root) @safe
{
    import std.algorithm : map;
    import std.array : array;

    static TwitterUser user(const ref JSONValue v) @safe
    {
        return TwitterUser(v["id"].integer, v["screen_name"].str,
            v["followers_count"].integer);
    }

    return Twitter(root["statuses"].arrayNoRef
        .map!(st => TwitterStatus(st["created_at"].str, st["id"].integer,
            st["text"].str, user(st["user"]), st["retweet_count"].integer,
            st["favorite_count"].integer))
        .array);
}

/// The reference checksum every engine's decode must reproduce.
TwitterStats referenceTwitterStats(const(char)[] text) @safe
{
    const doc = parseJSON(text);
    return statsOf(extractTwitter(doc));
}

/// A human-readable field-by-field mismatch summary (empty when matching).
string diffTwitterStats(in TwitterStats expected, in TwitterStats actual) @safe pure
{
    import std.conv : to;

    string s;
    static foreach (i, _; TwitterStats.init.tupleof)
        if (expected.tupleof[i] != actual.tupleof[i])
            s ~= "\n    " ~ __traits(identifier, TwitterStats.tupleof[i])
                ~ ": expected " ~ expected.tupleof[i].to!string
                ~ ", got " ~ actual.tupleof[i].to!string;
    return s;
}

@("twitter.extractTwitter.statsOf")
@safe unittest
{
    enum sample = `{"statuses": [{
        "metadata": {"iso_language_code": "ja"},
        "created_at": "Mon Sep 24 03:35:21 +0000 2012",
        "id": 250075927172759552,
        "text": "hi",
        "user": {"id": 7, "name": "x", "screen_name": "ab", "followers_count": 12},
        "retweet_count": 3,
        "favorite_count": 4,
        "favorited": false
    }], "search_metadata": {"count": 1}}`;

    const stats = referenceTwitterStats(sample);
    assert(stats.statusCount == 1);
    assert(stats.idSum == 250075927172759552UL);
    assert(stats.userIdSum == 7 && stats.followersSum == 12);
    assert(stats.retweetSum == 3 && stats.favoriteSum == 4);
    assert(stats.textBytes == 2 && stats.screenNameBytes == 2);
    assert(stats.createdAtBytes == 30);

    // The stats detect a divergent decode.
    const doc = parseJSON(sample);
    auto t = extractTwitter(doc);
    t.statuses[0].retweet_count = 0;
    assert(diffTwitterStats(stats, statsOf(t)).length > 0);
}
