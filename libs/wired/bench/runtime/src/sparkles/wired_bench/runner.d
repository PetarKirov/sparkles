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
    const datasets = loadDatasets(defaultDatasets, resolveDataDir(null));
    foreach (ref ds; datasets)
    {
        const reference = referenceFingerprint(ds.text);
        static foreach (E; AllEngines)
            registerEngine!E(ds, reference); // `ds` copied by value → fresh capture
    }
}

/// Registers the trait-supported op cases for one engine over one dataset. Under
/// `--bench` the cases run later, in a schedule the runner picks, so each must be
/// self-contained: `ds` arrives by value (a fresh binding per call, not the shared
/// loop variable), every case owns a heap engine, and all untimed setup/release
/// lives in `setup`/`teardown` (which run around that case's measurement) — never
/// bracketing the call, whose scope has long exited by execution time.
private void registerEngine(E)(Dataset ds, Fingerprint reference)
{
    static if (isJsonEngine!E)
    {
        registerParse!E(ds, reference);
        static if (hasParseInsitu!E)
            registerParseInsitu!E(ds);
        static if (hasValidate!E)
            registerValidate!E(ds);
        static if (hasSerialize!E)
            registerSerialize!E(ds);
    }
    // Decode-only engines (e.g. `wired`) have no `parse`/`fingerprint`.
    static if (canDecodeTwitter!E)
        if (ds.name == "twitter")
            registerDecode!E(ds);
}

// Each op is registered from its own helper (a fresh frame per call), so its
// closures capture their own engine and `ds` copy — never a shared loop variable.

/// parse — the fingerprint check rides the (untimed) `after`, verified once; a
/// mismatch turns this into an isolated error row. Each timed parse allocates a
/// document that `after` releases.
private void registerParse(E)(Dataset ds, Fingerprint reference)
{
    auto e = new E;
    bool verified;
    benchCase(
        name: E.name,
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
            freeDocOf(*e);
            return error.length ? err!bool(error) : ok!string(true);
        },
        metrics: [bytes(ds.text.length)],
        labels: ["dataset": ds.name, "operation": "parse"],
        setup: engineSetup(e),
        teardown: engineTeardown(e),
    );
}

private void registerParseInsitu(E)(Dataset ds)
{
    auto e = new E;
    benchCase(
        name: E.name,
        timed: () { e.parseInsitu(ds.text); },
        after: () { freeDocOf(*e); },
        metrics: [bytes(ds.text.length)],
        labels: ["dataset": ds.name, "operation": "parse-insitu"],
        setup: engineSetup(e),
        teardown: engineTeardown(e),
    );
}

private void registerValidate(E)(Dataset ds)
{
    auto e = new E;
    benchCase(
        name: E.name,
        timed: () { e.validate(ds.text); },
        after: () {},
        metrics: [bytes(ds.text.length)],
        labels: ["dataset": ds.name, "operation": "validate"],
        setup: engineSetup(e),
        teardown: engineTeardown(e),
    );
}

private void registerSerialize(E)(Dataset ds)
{
    // Output size for the metric: parse + serialize once now (untimed, released),
    // since it is unknown until a document exists.
    size_t outBytes;
    {
        auto probe = new E;
        static if (hasSetup!E)
            probe.setup();
        probe.parse(ds.text);
        outBytes = probe.serialize().length;
        freeDocOf(*probe);
        static if (hasTeardown!E)
            probe.teardown();
    }
    auto e = new E;
    benchCase(
        name: E.name,
        timed: () { cast(void) e.serialize(); },
        after: () {}, // the document persists across iterations
        metrics: [bytes(outBytes)],
        labels: ["dataset": ds.name, "operation": "serialize"],
        // Hold one parsed document across the whole case (untimed).
        setup: () {
            static if (hasSetup!E)
                e.setup();
            e.parse(ds.text);
        },
        teardown: () {
            freeDocOf(*e);
            static if (hasTeardown!E)
                e.teardown();
        },
    );
}

private void registerDecode(E)(Dataset ds)
{
    auto e = new E;
    const expected = referenceTwitterStats(ds.text);
    bool verified;
    benchCase(
        name: E.name,
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
        labels: ["dataset": ds.name, "operation": "decode"],
        setup: engineSetup(e),
        teardown: engineTeardown(e),
    );
}

/// A case `setup` that initializes the engine `*e` (untimed), or `null` when the
/// engine needs no setup. Takes the heap engine by pointer so the returned closure
/// shares the case's engine instance.
private void delegate() engineSetup(E)(E* e)
{
    static if (hasSetup!E)
        return () { e.setup(); };
    else
        return null;
}

/// A case `teardown` that tears the engine down (untimed), or `null` when the
/// engine needs none. Document release is the timed op's per-iteration `after`
/// (parse/-insitu) or the serialize case's own teardown — not here.
private void delegate() engineTeardown(E)(E* e)
{
    static if (hasTeardown!E)
        return () { e.teardown(); };
    else
        return null;
}
