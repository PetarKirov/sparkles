/**
The simdjson On-Demand engine — the lazy forward-only cursor that made
simdjson's modern numbers. A bare "parse" would only run stage 1, so the
timed op is parse **plus a full-document walk** that materializes every
string and number; the walk doubles as the fingerprint computation.
*/
module sparkles.wired_bench.engines.simdjson_ondemand;

version (BenchCpp):

import std.exception : enforce;

import sparkles.bench_shim;

import sparkles.wired_bench.engines.shim_support : shimError, toFingerprint;
import sparkles.wired_bench.fingerprint : Fingerprint;

/// Adapter over the simdjson On-Demand shim.
struct SimdjsonOndemandEngine
{
    enum name = "simdjson-ondemand";
    enum notes = "parse = parse + full walk (lazy cursor must be consumed)";

    private jb_sj_od_ctx* ctx;
    private Fingerprint lastWalk;

    void setup() @trusted
    {
        ctx = jb_sj_od_new();
        enforce(ctx !is null, "jb_sj_od_new failed");
    }

    void teardown() @trusted
    {
        if (ctx !is null)
        {
            jb_sj_od_free(ctx);
            ctx = null;
        }
    }

    /// Stage 1 + a full lazy walk materializing all values (timed as one op;
    /// the copy into the reused padded buffer is included).
    void parse(scope const(char)[] text) @trusted
    {
        jb_fingerprint c;
        enforce(jb_sj_od_parse_walk(ctx, text.ptr, text.length, &c) == 0,
            shimError(jb_sj_od_error(ctx)));
        lastWalk = toFingerprint(c);
    }

    /// Structural skip: containers traversed, scalars never decoded — the
    /// cost profile of a lazy parser over untouched fields (weaker than a
    /// full well-formedness check).
    void validate(scope const(char)[] text) @trusted
    {
        enforce(jb_sj_od_validate(ctx, text.ptr, text.length) == 0,
            shimError(jb_sj_od_error(ctx)));
    }

    /// The fingerprint computed by the walk `parse` already performed.
    Fingerprint fingerprint() const @safe pure nothrow @nogc
    {
        return lastWalk;
    }
}
