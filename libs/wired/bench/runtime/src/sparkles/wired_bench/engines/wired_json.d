/**
The `wired` engine — the library this whole benchmark exists to improve. A
decode-only row: `std.json.parseJSON` + `sparkles.wired.fromJSON!Twitter`,
the exact pipeline a wired user runs today. The gap between this row and
the fastest typed decoders is the target the replacement parser must close.
*/
module sparkles.wired_bench.engines.wired_json;

import std.exception : enforce;
import std.json : parseJSON;

import sparkles.wired.json : fromJSON;

import sparkles.wired_bench.twitter : Twitter, TwitterStats, statsOf;

/// Decode-only adapter over wired's current std.json-based pipeline.
struct WiredEngine
{
    enum name = "wired";
    enum notes = "parseJSON + fromJSON!Twitter — wired's current pipeline";

    private Twitter twitter;

    /// The full text → struct pipeline through wired.
    void decodeTwitter(const(char)[] text)
    {
        auto decoded = parseJSON(text).fromJSON!Twitter;
        enforce(!decoded.hasError, decoded.hasError ? decoded.error.msg : "");
        twitter = decoded.value;
    }

    /// Checksum of the held decoded document.
    TwitterStats twitterStats() const @safe pure nothrow @nogc
    {
        return statsOf(twitter);
    }
}

@("WiredEngine.decodeTwitter")
@system unittest
{
    WiredEngine e;
    e.decodeTwitter(`{"statuses": [{
        "created_at": "x", "id": 5, "text": "hey",
        "user": {"id": 2, "screen_name": "ab", "followers_count": 7},
        "retweet_count": 1, "favorite_count": 0, "extra": null
    }]}`);
    const s = e.twitterStats();
    assert(s.statusCount == 1 && s.idSum == 5 && s.userIdSum == 2);
    assert(s.textBytes == 3 && s.screenNameBytes == 2);
}
