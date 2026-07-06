/**
The benchmark body: engines × datasets × ops, driven through
`sparkles:test-runner`'s `benchCase`.

Each op is one `benchCase` row; per-op document release is the untimed `after`,
and correctness is checked there too — a fingerprint / `TwitterStats` mismatch
returns an `Expected` error, so a wrong engine becomes an isolated error row
instead of aborting the matrix. Hardware counters come from the runner's
`--perf`; there is no private perf backend any more.

The whole benchmark is a `@benchmark unittest`: skipped by a normal `dub test`,
measured by `dub test -- --bench` (add `--perf` for counters). Corpora load at
run time from `$WIRED_BENCH_DATA` (see $(MREF sparkles,wired_bench,data)).
*/
module sparkles.wired_bench.runner;

import expected : err, ok;

import sparkles.test_runner.attributes : benchmark;
import sparkles.test_runner.bench : benchCase, Metric, Unit;

import sparkles.wired_bench.data : Dataset, loadDatasets, resolveDataDir;
import sparkles.wired_bench.engines;
import sparkles.wired_bench.fingerprint : diffFingerprints, Fingerprint,
    referenceFingerprint;
import sparkles.wired_bench.traits;
import sparkles.wired_bench.twitter : diffTwitterStats, referenceTwitterStats;

/// The canonical corpora (the old `--datasets` default), loaded from
/// `$WIRED_BENCH_DATA`. `twitter` is the one with a typed decode path.
private immutable string[] defaultDatasets =
    ["twitter", "citm_catalog", "canada", "github_events"];

/// A `B/s` throughput metric for `n` input/output bytes per iteration.
private Metric bytes(size_t n) @safe pure nothrow
    => Metric(unit: Unit("B"), amount: double(n), mode: Metric.Mode.rate);

/// Releases the engine's held document when it exposes the primitive.
private void freeDocOf(E)(ref E e)
{
    static if (hasFreeDoc!E)
        e.freeDoc();
}

@("wired.runtime")
@benchmark
@system
unittest
{
    import core.memory : GC;

    const datasets = loadDatasets(defaultDatasets, resolveDataDir(null));
    foreach (ref ds; datasets)
    {
        const reference = referenceFingerprint(ds.text);
        static foreach (E; AllEngines)
        {
            benchEngine!E(ds, reference);
            GC.collect();
            GC.minimize();
        }
    }
}

/// Emits the trait-supported op rows for one engine over one dataset. Setup and
/// teardown (reusable parser state) bracket the whole engine×dataset, untimed.
private void benchEngine(E)(in Dataset ds, const Fingerprint reference)
{
    E e;
    static if (hasSetup!E)
        e.setup();
    scope (exit)
        static if (hasTeardown!E)
            e.teardown();

    static if (isJsonEngine!E)
    {
        // parse — the fingerprint check rides the (untimed) `after`, verified
        // once; a mismatch turns this into an isolated error row.
        {
            bool verified;
            benchCase(
                name: E.name ~ "/" ~ ds.name ~ "/parse",
                timed: () { e.parse(ds.text); },
                after: () {
                    string error;
                    if (!verified)
                    {
                        verified = true;
                        const fp = e.fingerprint();
                        if (!reference.matches(fp))
                            error = "fingerprint mismatch vs std.json:"
                                ~ diffFingerprints(reference, fp);
                    }
                    freeDocOf(e);
                    return error.length ? err!bool(error) : ok!string(true);
                },
                metrics: [bytes(ds.text.length)],
            );
        }

        static if (hasParseInsitu!E)
            benchCase(
                name: E.name ~ "/" ~ ds.name ~ "/parse-insitu",
                timed: () { e.parseInsitu(ds.text); },
                after: () { freeDocOf(e); },
                metrics: [bytes(ds.text.length)],
            );

        static if (hasValidate!E)
            benchCase(
                name: E.name ~ "/" ~ ds.name ~ "/validate",
                timed: () { e.validate(ds.text); },
                after: () {},
                metrics: [bytes(ds.text.length)],
            );

        static if (hasSerialize!E)
        {
            e.parse(ds.text); // hold the document (untimed)
            const outBytes = e.serialize().length; // output size (untimed)
            benchCase(
                name: E.name ~ "/" ~ ds.name ~ "/serialize",
                timed: () { cast(void) e.serialize(); },
                after: () {}, // the document persists across iterations
                metrics: [bytes(outBytes)],
            );
            freeDocOf(e);
        }
    }

    // Decode-only engines (e.g. `wired`) have no `parse`/`fingerprint`; the
    // TwitterStats check rides `after`, again verified once.
    static if (canDecodeTwitter!E)
        if (ds.name == "twitter")
        {
            const expected = referenceTwitterStats(ds.text);
            bool verified;
            benchCase(
                name: E.name ~ "/" ~ ds.name ~ "/decode",
                timed: () { e.decodeTwitter(ds.text); },
                after: () {
                    string error;
                    if (!verified)
                    {
                        verified = true;
                        const actual = e.twitterStats();
                        if (actual != expected)
                            error = "twitter stats mismatch vs std.json:"
                                ~ diffTwitterStats(expected, actual);
                    }
                    return error.length ? err!bool(error) : ok!string(true);
                },
                metrics: [bytes(ds.text.length)],
            );
        }
}
