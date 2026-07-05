/**
The Rust engines — serde_json (the ecosystem standard), simd-json (the
simdjson port), and sonic-rs (ByteDance's compile-time-SIMD library) —
through the `jb_serde_*` / `jb_simdj_*` / `jb_sonic_*` shim surfaces, which
share one shape; a single adapter template instantiates all three.
*/
module sparkles.wired_bench.engines.rust_engines;

version (BenchRust):

import std.exception : enforce;

import sparkles.bench_shim;

import sparkles.wired_bench.engines.shim_support : shimError, toFingerprint;
import sparkles.wired_bench.fingerprint : Fingerprint;

/// Adapter over one Rust shim engine (the seven-function `jb_<id>_*` shape).
struct RustShimEngine(string id, Ctx, alias ctxNew, alias ctxFree,
    alias parseFn, alias docFreeFn, alias fingerprintFn, alias serializeFn,
    alias errorFn, string noteText = "")
{
    enum name = id;
    static if (noteText.length)
        enum notes = noteText;

    private Ctx* ctx;

    void setup() @trusted
    {
        ctx = ctxNew();
        enforce(ctx !is null, id ~ ": context allocation failed");
    }

    void teardown() @trusted
    {
        if (ctx !is null)
        {
            ctxFree(ctx);
            ctx = null;
        }
    }

    /// Full parse of immutable input (any engine-required copy is inside).
    void parse(scope const(char)[] text) @trusted
    {
        enforce(parseFn(ctx, text.ptr, text.length) == 0, shimError(errorFn(ctx)));
    }

    /// Drops the held document.
    void freeDoc() @trusted
    {
        docFreeFn(ctx);
    }

    /// The held document as minified JSON (shim-owned buffer).
    const(char)[] serialize() @trusted
    {
        size_t len;
        const p = serializeFn(ctx, &len);
        enforce(p !is null, shimError(errorFn(ctx)));
        return p[0 .. len];
    }

    /// Structural fingerprint of the held document.
    Fingerprint fingerprint() @trusted
    {
        jb_fingerprint c;
        enforce(fingerprintFn(ctx, &c) == 0, shimError(errorFn(ctx)));
        return toFingerprint(c);
    }
}

/// serde_json — `from_slice::<Value>` / `to_writer`.
alias SerdeJsonEngine = RustShimEngine!("serde_json", jb_serde_ctx,
    jb_serde_new, jb_serde_free, jb_serde_parse, jb_serde_doc_free,
    jb_serde_fingerprint, jb_serde_serialize, jb_serde_error);

/// simd-json — parse = required mutable copy + borrowed value with reused
/// buffers (then dropped); the verify/serialize document re-parses untimed.
alias SimdJsonEngine = RustShimEngine!("simd-json", jb_simdj_ctx,
    jb_simdj_new, jb_simdj_free, jb_simdj_parse, jb_simdj_doc_free,
    jb_simdj_fingerprint, jb_simdj_serialize, jb_simdj_error,
    "parse = &mut copy + borrowed value (doc for verify re-parsed untimed)");

/// sonic-rs — `from_slice::<Value>` / `to_writer` (own SIMD writer).
alias SonicRsEngine = RustShimEngine!("sonic-rs", jb_sonic_ctx,
    jb_sonic_new, jb_sonic_free, jb_sonic_parse, jb_sonic_doc_free,
    jb_sonic_fingerprint, jb_sonic_serialize, jb_sonic_error);
