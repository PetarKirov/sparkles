/**
The rapidjson engine — the pre-simdjson C++ speed standard: scalar
recursive-descent with SIMD only for whitespace/string scanning, in-situ
parsing, and a pool allocator. Always parses with `kParseFullPrecisionFlag`
so its numbers are comparable with the other engines.
*/
module sparkles.wired_bench.engines.rapidjson_json;

version (BenchCpp):

import std.exception : enforce;

import sparkles.bench_shim;

import sparkles.wired_bench.engines.shim_support : shimError, toFingerprint;
import sparkles.wired_bench.fingerprint : Fingerprint;

/// Adapter over the rapidjson shim.
struct RapidjsonEngine
{
    enum name = "rapidjson";
    enum notes = "kParseFullPrecisionFlag (default parser allows 3 ULP)";

    private jb_rj_ctx* ctx;

    void setup() @trusted
    {
        ctx = jb_rj_new();
        enforce(ctx !is null, "jb_rj_new failed");
    }

    void teardown() @trusted
    {
        if (ctx !is null)
        {
            jb_rj_free(ctx);
            ctx = null;
        }
    }

    /// Full DOM parse (rapidjson copies decoded strings into its pool).
    void parse(scope const(char)[] text) @trusted
    {
        enforce(jb_rj_parse(ctx, text.ptr, text.length) == 0,
            shimError(jb_rj_error(ctx)));
    }

    /// Destructive in-place parse over a shim-owned scratch copy (timed).
    void parseInsitu(scope const(char)[] text) @trusted
    {
        enforce(jb_rj_parse_insitu(ctx, text.ptr, text.length) == 0,
            shimError(jb_rj_error(ctx)));
    }

    /// Clears the document and releases the pool allocator's chunks.
    void freeDoc() @trusted
    {
        jb_rj_doc_free(ctx);
    }

    /// The held document as minified JSON (shim-owned buffer).
    const(char)[] serialize() @trusted
    {
        size_t len;
        const p = jb_rj_serialize(ctx, &len);
        enforce(p !is null, shimError(jb_rj_error(ctx)));
        return p[0 .. len];
    }

    /// Structural fingerprint of the held document.
    Fingerprint fingerprint() @trusted
    {
        jb_fingerprint c;
        enforce(jb_rj_fingerprint(ctx, &c) == 0, shimError(jb_rj_error(ctx)));
        return toFingerprint(c);
    }
}
