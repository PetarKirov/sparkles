/**
The wired-native engine — sparkles.wired's own arena parser (SPEC §11),
the row this benchmark exists to make competitive with yyjson. No
version gate: it must always build (it is the product under test).
*/
module sparkles.wired_bench.engines.wired_native;

import std.exception : enforce;

import sparkles.wired.json.document : JsonKind, JsonValue;
import sparkles.wired.json.reader : JsonParseResult, parseJsonDocument;

import sparkles.wired_bench.fingerprint : Fingerprint;
import sparkles.wired_bench.twitter : Twitter, TwitterStats, TwitterStatus,
    TwitterUser, statsOf;

/// Adapter over the native arena document reader.
struct WiredNativeEngine
{
    enum name = "wired-native";

    private JsonParseResult!() result;

    /// Full parse; the reader copies + pads the input into the document's
    /// string pool internally (timed — the immutable-input contract).
    void parse(scope const(char)[] text) @safe
    {
        result = parseJsonDocument(text);
        enforce(result.hasValue, "wired-native parse failed");
    }

    /// Drops the held document (frees both arena blocks).
    void freeDoc() @safe
    {
        result = JsonParseResult!().init;
    }

    /// ditto
    void teardown() @safe
    {
        freeDoc();
    }

    /// Structural fingerprint of the held document.
    Fingerprint fingerprint() @safe
    {
        Fingerprint f;
        accumulateNative(result.document.root, f);
        return f;
    }

    /// Typed decode: parse + view-walk extraction into the D structs
    /// (string fields are duplicated out of the document, like every
    /// other engine's owned strings).
    void decodeTwitter(scope const(char)[] text) @safe
    {
        parse(text);
        auto statuses = result.document.root.objectGet("statuses");
        enforce(statuses.kind == JsonKind.array, "decode: no statuses array");

        twitter = Twitter.init;
        twitter.statuses.reserve(statuses.length);
        foreach (st; statuses.byElement)
        {
            auto user = st.objectGet("user");
            twitter.statuses ~= TwitterStatus(
                st.objectGet("created_at").str.idup,
                st.objectGet("id").integer,
                st.objectGet("text").str.idup,
                TwitterUser(
                    user.objectGet("id").integer,
                    user.objectGet("screen_name").str.idup,
                    user.objectGet("followers_count").integer),
                st.objectGet("retweet_count").integer,
                st.objectGet("favorite_count").integer);
        }
        freeDoc();
    }

    /// Checksum of the held decoded document.
    TwitterStats twitterStats() const @safe pure nothrow @nogc
    {
        return statsOf(twitter);
    }

    private Twitter twitter;
}

/// Accumulates one view subtree into `f`.
private void accumulateNative(scope JsonValue v, ref Fingerprint f) @safe
{
    final switch (v.kind) with (JsonKind)
    {
    case null_:
        f.nulls++;
        break;
    case bool_:
        if (v.boolean)
            f.trues++;
        else
            f.falses++;
        break;
    case integer:
        f.numbers++;
        f.numberSum += v.integer;
        break;
    case uinteger:
        f.numbers++;
        f.numberSum += v.uinteger;
        break;
    case floating:
        f.numbers++;
        f.numberSum += v.floating;
        break;
    case string_:
        f.strings++;
        f.stringBytes += v.str.length;
        break;
    case array:
        f.arrays++;
        f.arrayElems += v.length;
        foreach (e; v.byElement)
            accumulateNative(e, f);
        break;
    case object:
        f.objects++;
        f.objectMembers += v.length;
        foreach (m; v.byKeyValue)
        {
            f.keyBytes += m.key.length;
            accumulateNative(m.value, f);
        }
        break;
    case none, rawNumber:
        assert(false, "unexpected kind in a parsed document");
    }
}

@("WiredNativeEngine.parseFingerprint")
@system unittest
{
    WiredNativeEngine e;
    scope (exit)
        e.teardown();

    e.parse(`{"a": [1, true, "x", 2.5, null]}`);

    const f = e.fingerprint();
    assert(f.numbers == 2 && f.trues == 1 && f.strings == 1 && f.nulls == 1);
    assert(f.arrays == 1 && f.arrayElems == 5);
    assert(f.objects == 1 && f.objectMembers == 1 && f.keyBytes == 1);
    assert(f.numberSum == 3.5);
}
