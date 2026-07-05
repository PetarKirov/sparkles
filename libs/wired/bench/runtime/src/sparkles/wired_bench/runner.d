/**
The harness core: engines × datasets × ops.

Per engine and dataset: an untimed fingerprint verification against the
`std.json` reference walk, then one timed row per op the engine's traits
expose. An engine failure (verification mismatch or a thrown exception)
produces an error row instead of aborting the whole run.
*/
module sparkles.wired_bench.runner;

import core.memory : GC;

import sparkles.wired_bench.config : BenchOptions;
import sparkles.wired_bench.data : Dataset;
import sparkles.wired_bench.fingerprint : Fingerprint, diffFingerprints,
    referenceFingerprint;
import sparkles.wired_bench.timing : OpStats, mbPerSec, measureOp;
import sparkles.wired_bench.traits;
import sparkles.wired_bench.twitter : TwitterStats, diffTwitterStats,
    referenceTwitterStats;

/// The dataset the typed decode op runs on (the only one with a shared
/// cross-language struct definition).
private enum decodeDataset = "twitter";

/// One row of the report: an (engine, dataset, op) measurement.
struct OpResult
{
    string dataset;   /// dataset name
    string engine;    /// engine name
    string op;        /// `parse`, `parse-insitu`, `serialize`, `validate`, `decode`
    ulong bytes;      /// per-iteration payload (input bytes; output bytes for serialize)
    long medianNs;    /// median per-iteration time
    long minNs;       /// fastest iteration
    long meanNs;      /// mean per-iteration time
    ulong iters;      /// measured iterations
    double mbPerSec = 0; /// throughput derived from the median
    string notes;     /// engine caveats (from `E.notes`)
    string error;     /// non-empty = the engine failed; timing fields are zero
}

/// Runs every selected engine over every dataset, appending rows in
/// registry order (the `std.json` baseline rows first per dataset).
OpResult[] runAll(Engines...)(const Dataset[] datasets, const BenchOptions opts)
{
    OpResult[] results;
    foreach (ds; datasets)
    {
        const reference = opts.skipVerify ? Fingerprint() : referenceFingerprint(ds.text);
        static foreach (E; Engines)
        {{
            if (opts.engineEnabled(E.name))
            {
                try
                    runEngine!E(ds, reference, opts, results);
                catch (Exception e)
                    results ~= failedRow(ds.name, E.name, "-", e.msg);
                GC.collect();
                GC.minimize();
            }
        }}
    }
    return results;
}

/// Benchmarks one engine over one dataset: verify, then time each
/// trait-supported op that passes the `--ops` filter. The dataset is a plain
/// `const` parameter (not `in`): its name and text legitimately flow into
/// the returned rows, which a dip1000 `scope` parameter would reject.
/// An engine may also be decode-only (`canDecodeTwitter` without
/// `isJsonEngine`, e.g. the `wired` row) — it gets only the decode path.
void runEngine(E)(const Dataset ds, in Fingerprint reference, const BenchOptions opts,
    ref OpResult[] results)
if (isJsonEngine!E || canDecodeTwitter!E)
{
    E e;
    static if (hasSetup!E)
        e.setup();
    scope (exit)
    {
        static if (hasTeardown!E)
            e.teardown();
    }

    const cfg = opts.timing;

    static if (isJsonEngine!E)
    {
        if (!opts.skipVerify)
        {
            e.parse(ds.text);
            const actual = e.fingerprint();
            static if (hasFreeDoc!E)
                e.freeDoc();
            if (!reference.matches(actual))
            {
                results ~= failedRow(ds.name, E.name, "verify",
                    "fingerprint mismatch vs std.json reference:"
                    ~ diffFingerprints(reference, actual));
                return;
            }
        }

        if (opts.opEnabled("parse"))
        {
            const stats = measureOp(() { e.parse(ds.text); },
                () { freeDocOf(e); }, cfg);
            results ~= row!E(ds.name, "parse", ds.text.length, stats);
        }

        static if (hasParseInsitu!E)
            if (opts.opEnabled("insitu"))
            {
                const stats = measureOp(() { e.parseInsitu(ds.text); },
                    () { freeDocOf(e); }, cfg);
                results ~= row!E(ds.name, "parse-insitu", ds.text.length, stats);
            }

        static if (hasValidate!E)
            if (opts.opEnabled("validate"))
            {
                const stats = measureOp(() { e.validate(ds.text); }, () {}, cfg);
                results ~= row!E(ds.name, "validate", ds.text.length, stats);
            }

        static if (hasSerialize!E)
            if (opts.opEnabled("serialize"))
            {
                e.parse(ds.text); // the document under serialization; untimed
                const outBytes = e.serialize().length;
                const stats = measureOp(() { cast(void) e.serialize(); }, () {}, cfg);
                freeDocOf(e);
                results ~= row!E(ds.name, "serialize", outBytes, stats);
            }
    }

    static if (canDecodeTwitter!E)
        if (opts.opEnabled("decode") && ds.name == decodeDataset)
        {
            if (!opts.skipVerify)
            {
                e.decodeTwitter(ds.text);
                const actual = e.twitterStats();
                const expected = referenceTwitterStats(ds.text);
                if (actual != expected)
                {
                    results ~= failedRow(ds.name, E.name, "decode",
                        "twitter stats mismatch vs std.json reference:"
                        ~ diffTwitterStats(expected, actual));
                    return;
                }
            }
            const stats = measureOp(() { e.decodeTwitter(ds.text); }, () {}, cfg);
            results ~= row!E(ds.name, "decode", ds.text.length, stats);
        }
}

/// Releases the engine's held document when the engine exposes the primitive.
private void freeDocOf(E)(ref E e)
{
    static if (hasFreeDoc!E)
        e.freeDoc();
}

private OpResult row(E)(string dataset, string op, ulong bytes, in OpStats stats)
{
    static if (hasNotes!E)
        enum notes = E.notes;
    else
        enum notes = "";
    return OpResult(dataset, E.name, op, bytes, stats.medianNs, stats.minNs,
        stats.meanNs, stats.iters, mbPerSec(bytes, stats.medianNs), notes);
}

private OpResult failedRow(string dataset, string engine, string op, string error)
    @safe pure nothrow @nogc
{
    return OpResult(dataset, engine, op, 0, 0, 0, 0, 0, 0, "", error);
}

@("runner.runEngine.opsAndVerification")
@safe unittest
{
    import core.time : msecs;
    import std.algorithm : canFind, map;
    import std.array : array;
    import sparkles.wired_bench.fingerprint : accumulate;
    import std.json : parseJSON;

    static struct FakeEngine
    {
        enum name = "fake";
        string held;
        uint frees;
        void parse(const(char)[] s) { held = s.idup; }
        void freeDoc() { frees++; }
        const(char)[] serialize() => held;
        Fingerprint fingerprint() @safe
        {
            Fingerprint f;
            const doc = parseJSON(held);
            accumulate(doc, f);
            return f;
        }
    }

    const ds = Dataset("mini", `{"a": [1, 2]}`);
    BenchOptions opts;
    opts.minIters = 2;
    opts.minTimeMs = 0;
    opts.warmup = 1;

    OpResult[] results;
    runEngine!FakeEngine(ds, referenceFingerprint(ds.text), opts, results);

    const ops = results.map!(r => r.op).array;
    assert(ops.canFind("parse") && ops.canFind("serialize"));
    assert(!ops.canFind("parse-insitu") && !ops.canFind("validate"));
    foreach (r; results)
        assert(r.error.length == 0 && r.iters >= 2 && r.mbPerSec > 0);
}

@("runner.runEngine.fingerprintMismatchFails")
@safe unittest
{
    static struct LyingEngine
    {
        enum name = "liar";
        void parse(const(char)[]) {}
        Fingerprint fingerprint() => Fingerprint(); // always empty — never matches
    }

    const ds = Dataset("mini", `{"a": 1}`);
    BenchOptions opts;

    OpResult[] results;
    runEngine!LyingEngine(ds, referenceFingerprint(ds.text), opts, results);

    assert(results.length == 1);
    assert(results[0].op == "verify");
    assert(results[0].error.length > 0);
}
