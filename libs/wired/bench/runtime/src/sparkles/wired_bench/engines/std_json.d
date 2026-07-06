/**
The `std.json` baseline engine — the GC `JSONValue` DOM every faster engine
is measured against, and the parser `sparkles:wired` currently sits on.
*/
module sparkles.wired_bench.engines.std_json;

import std.json : JSONValue, parseJSON;

import sparkles.wired_bench.fingerprint : Fingerprint, accumulate;
import sparkles.wired_bench.twitter : Twitter, TwitterStats, extractTwitter,
    statsOf;

/// Baseline adapter over `std.json.parseJSON` / `JSONValue.toString`.
struct StdJsonEngine
{
    enum name = "std.json";

    private JSONValue doc;
    private string rendered;

    /// Full DOM parse into a GC `JSONValue` tree.
    void parse(const(char)[] text) @safe
    {
        assign(parseJSON(text));
    }

    /// Drops the held document (the GC reclaims it on the next collection).
    void freeDoc() @safe nothrow
    {
        assign(JSONValue.init);
        rendered = null;
    }

    /// The held document as minified JSON.
    const(char)[] serialize() @safe
    {
        // JSONValue.toString is @system in this Phobos front-end; it only
        // renders into a fresh appender, which is memory-safe.
        rendered = (() @trusted => doc.toString)();
        return rendered;
    }

    // JSONValue's templated opAssign is @system (Phobos infelicity);
    // overwriting the whole union with a fresh value is memory-safe.
    private void assign(JSONValue v) @trusted pure nothrow @nogc
    {
        doc = v;
    }

    /// Structural fingerprint of the held document.
    Fingerprint fingerprint() @safe
    {
        Fingerprint f;
        accumulate(doc, f);
        return f;
    }

    /// Typed decode: `parseJSON` + manual field extraction — the code a
    /// std.json user writes by hand today (the reference implementation).
    void decodeTwitter(const(char)[] text) @safe
    {
        const parsed = parseJSON(text);
        twitter = extractTwitter(parsed);
    }

    /// Checksum of the held decoded document.
    TwitterStats twitterStats() const @safe pure nothrow @nogc
    {
        return statsOf(twitter);
    }

    private Twitter twitter;
}

@("StdJsonEngine.parseSerializeRoundTrip")
@safe unittest
{
    StdJsonEngine e;
    e.parse(`{"a": [1, true, "x"]}`);

    const f = e.fingerprint();
    assert(f.numbers == 1 && f.trues == 1 && f.strings == 1);

    assert(e.serialize == `{"a":[1,true,"x"]}`);
    e.freeDoc();
}
