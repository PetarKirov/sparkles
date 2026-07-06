/**
The yyjson engine — the scalar-C counterpoint to the SIMD parsers: GB/s
throughput from careful branch layout and a single-allocation document, no
SIMD at all. Reached directly through the ImportC binding sub-package
(`bindings/yyjson`); no hand-written shim.
*/
module sparkles.wired_bench.engines.yyjson_json;

version (BenchYyjson):

import core.stdc.stdlib : free;

import std.exception : enforce;

import sparkles.yyjson;

import sparkles.wired_bench.fingerprint : Fingerprint;
import sparkles.wired_bench.twitter : Twitter, TwitterStats, TwitterStatus,
    TwitterUser, statsOf;

/// Adapter over the yyjson C API (immutable-document read path).
struct YyjsonEngine
{
    enum name = "yyjson";

    private yyjson_doc* doc;
    private char[] insituBuf;
    private char* rendered;

    /// Full parse; yyjson copies + pads the input internally (timed — the
    /// immutable-input contract).
    void parse(scope const(char)[] text) @trusted
    {
        releaseDoc();
        doc = yyjson_read(text.ptr, text.length, 0);
        enforce(doc !is null, "yyjson_read failed");
    }

    /// Destructive in-place parse: the scratch copy (timed) is parsed with
    /// `YYJSON_READ_INSITU`, so strings are unescaped inside the buffer.
    void parseInsitu(scope const(char)[] text) @trusted
    {
        releaseDoc();
        const padded = text.length + YYJSON_PADDING_SIZE;
        if (insituBuf.length < padded)
            insituBuf.length = padded;
        insituBuf[0 .. text.length] = text[];
        insituBuf[text.length .. padded] = '\0';
        doc = yyjson_read_opts(insituBuf.ptr, text.length, YYJSON_READ_INSITU,
            null, null);
        enforce(doc !is null, "yyjson_read_opts(INSITU) failed");
    }

    /// Frees the held document.
    void freeDoc() @trusted
    {
        releaseDoc();
    }

    /// Releases the document and any pending serialize buffer.
    void teardown() @trusted
    {
        releaseDoc();
        insituBuf = null;
    }

    /// The held document as minified JSON (buffer owned by the engine,
    /// valid until the next call).
    const(char)[] serialize() @trusted
    {
        releaseRendered();
        size_t len;
        rendered = yyjson_write(doc, 0, &len);
        enforce(rendered !is null, "yyjson_write failed");
        return rendered[0 .. len];
    }

    /// Structural fingerprint of the held document.
    Fingerprint fingerprint() @trusted
    {
        Fingerprint f;
        accumulateYyjson(yyjson_doc_get_root(doc), f);
        return f;
    }

    /// Typed decode: parse + accessor-walk extraction into the D structs
    /// (string fields are duplicated out of the document, like every other
    /// engine's owned strings).
    void decodeTwitter(scope const(char)[] text) @trusted
    {
        static string str(yyjson_val* v) @trusted
        {
            return yyjson_get_str(v)[0 .. yyjson_get_len(v)].idup;
        }

        parse(text);
        auto statuses = yyjson_obj_get(yyjson_doc_get_root(doc), "statuses");
        enforce(statuses !is null, "decode: no statuses array");

        twitter = Twitter.init;
        twitter.statuses.reserve(yyjson_arr_size(statuses));
        yyjson_arr_iter iter;
        yyjson_arr_iter_init(statuses, &iter);
        for (auto st = yyjson_arr_iter_next(&iter); st !is null;
            st = yyjson_arr_iter_next(&iter))
        {
            auto user = yyjson_obj_get(st, "user");
            twitter.statuses ~= TwitterStatus(
                str(yyjson_obj_get(st, "created_at")),
                yyjson_get_sint(yyjson_obj_get(st, "id")),
                str(yyjson_obj_get(st, "text")),
                TwitterUser(
                    yyjson_get_sint(yyjson_obj_get(user, "id")),
                    str(yyjson_obj_get(user, "screen_name")),
                    yyjson_get_sint(yyjson_obj_get(user, "followers_count"))),
                yyjson_get_sint(yyjson_obj_get(st, "retweet_count")),
                yyjson_get_sint(yyjson_obj_get(st, "favorite_count")));
        }
        releaseDoc();
    }

    /// Checksum of the held decoded document.
    TwitterStats twitterStats() const @safe pure nothrow @nogc
    {
        return statsOf(twitter);
    }

    private Twitter twitter;

    private void releaseDoc() @trusted
    {
        if (doc !is null)
        {
            yyjson_doc_free(doc);
            doc = null;
        }
        releaseRendered();
    }

    private void releaseRendered() @trusted
    {
        if (rendered !is null)
        {
            free(rendered);
            rendered = null;
        }
    }
}

/// Accumulates one `yyjson_val` subtree into `f`.
private void accumulateYyjson(yyjson_val* v, ref Fingerprint f) @trusted
{
    if (yyjson_is_null(v))
        f.nulls++;
    else if (yyjson_is_bool(v))
    {
        if (yyjson_get_bool(v))
            f.trues++;
        else
            f.falses++;
    }
    else if (yyjson_is_num(v))
    {
        f.numbers++;
        f.numberSum += yyjson_get_num(v);
    }
    else if (yyjson_is_str(v))
    {
        f.strings++;
        f.stringBytes += yyjson_get_len(v);
    }
    else if (yyjson_is_arr(v))
    {
        f.arrays++;
        f.arrayElems += yyjson_arr_size(v);
        yyjson_arr_iter iter;
        yyjson_arr_iter_init(v, &iter);
        for (auto e = yyjson_arr_iter_next(&iter); e !is null;
            e = yyjson_arr_iter_next(&iter))
            accumulateYyjson(e, f);
    }
    else if (yyjson_is_obj(v))
    {
        f.objects++;
        f.objectMembers += yyjson_obj_size(v);
        yyjson_obj_iter iter;
        yyjson_obj_iter_init(v, &iter);
        for (auto key = yyjson_obj_iter_next(&iter); key !is null;
            key = yyjson_obj_iter_next(&iter))
        {
            f.keyBytes += yyjson_get_len(key);
            accumulateYyjson(yyjson_obj_iter_get_val(key), f);
        }
    }
}

@("YyjsonEngine.parseSerializeRoundTrip")
@system unittest
{
    YyjsonEngine e;
    scope (exit)
        e.teardown();

    e.parse(`{"a": [1, true, "x", 2.5, null]}`);

    const f = e.fingerprint();
    assert(f.numbers == 2 && f.trues == 1 && f.strings == 1 && f.nulls == 1);
    assert(f.arrays == 1 && f.arrayElems == 5);
    assert(f.objects == 1 && f.objectMembers == 1 && f.keyBytes == 1);
    assert(f.numberSum == 3.5);

    assert(e.serialize == `{"a":[1,true,"x",2.5,null]}`);

    e.parseInsitu(`{"esc": "a\nb"}`);
    const g = e.fingerprint();
    assert(g.strings == 1 && g.stringBytes == 3);
}
