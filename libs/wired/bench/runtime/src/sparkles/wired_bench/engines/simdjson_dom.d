/**
The simdjson DOM engine — the classic two-stage SIMD pipeline (vectorized
structural index + tape builder), through the `jb_sj_dom_*` shim. The
`dom::parser` tape is reused across parses; `parse` copies into the parser's
padded internal buffer (the immutable-input contract).
*/
module sparkles.wired_bench.engines.simdjson_dom;

version (BenchCpp):

import std.exception : enforce;

import sparkles.bench_shim;

import sparkles.wired_bench.engines.shim_support : shimError, toFingerprint;
import sparkles.wired_bench.fingerprint : Fingerprint;

/// Adapter over the simdjson DOM shim.
struct SimdjsonDomEngine
{
    enum name = "simdjson-dom";

    private jb_sj_dom_ctx* ctx;

    void setup() @trusted
    {
        ctx = jb_sj_dom_new();
        enforce(ctx !is null, "jb_sj_dom_new failed");
    }

    void teardown() @trusted
    {
        if (ctx !is null)
        {
            jb_sj_dom_free(ctx);
            ctx = null;
        }
    }

    /// Full DOM parse onto the reused tape.
    void parse(scope const(char)[] text) @trusted
    {
        enforce(jb_sj_dom_parse(ctx, text.ptr, text.length) == 0,
            shimError(jb_sj_dom_error(ctx)));
    }

    /// The tape is reused; dropping the document is a flag reset.
    void freeDoc() @trusted
    {
        jb_sj_dom_doc_free(ctx);
    }

    /// The held document as minified JSON (shim-owned buffer).
    const(char)[] serialize() @trusted
    {
        size_t len;
        const p = jb_sj_dom_serialize(ctx, &len);
        enforce(p !is null, shimError(jb_sj_dom_error(ctx)));
        return p[0 .. len];
    }

    /// Structural fingerprint of the held document.
    Fingerprint fingerprint() @trusted
    {
        jb_fingerprint c;
        enforce(jb_sj_dom_fingerprint(ctx, &c) == 0,
            shimError(jb_sj_dom_error(ctx)));
        return toFingerprint(c);
    }
}
