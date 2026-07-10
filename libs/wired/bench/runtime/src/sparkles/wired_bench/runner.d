/**
The benchmark body: engines × datasets × ops, driven through
`sparkles:test-runner`'s `benchCase`.

Each op is one `benchCase` row; per-op document release is the untimed `after`,
and correctness is checked there too — a fingerprint / `TwitterStats` mismatch
returns an `Expected` error, so a wrong engine becomes an isolated error row
instead of aborting the matrix. Hardware counters come from the runner's
`--perf`; there is no private perf backend any more.

The benchmark is one `@benchmark unittest` per op (`wired.parse`,
`wired.validate`, `wired.serialize`, `wired.decode`): skipped by a normal
`dub test`, measured by `dub test -b bench -- --bench` (add `--perf` for
counters) — so `-i 'wired\.serialize'` measures one op, and a registration
failure in one op's body cannot abort the others. Engines and datasets subset
at run time via `$WIRED_BENCH_ENGINES` / `$WIRED_BENCH_DATASETS` (comma lists;
empty = all). Corpora load from `$WIRED_BENCH_DATA` (see
$(MREF sparkles,wired_bench,data)).
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

/// Whether the runtime env filters (`$WIRED_BENCH_ENGINES` /
/// `$WIRED_BENCH_DATASETS` — the old `--engines`/`--datasets` flags) allow a
/// name: a comma list allows its members, empty/unset allows everything.
private bool envListAllows(string envVar, string name) @safe
{
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : canFind;
    import std.process : environment;

    const list = environment.get(envVar, "");
    return !list.length || list.splitter(',').canFind(name);
}

private bool engineEnabled(string name) @safe
    => envListAllows("WIRED_BENCH_ENGINES", name);

private bool datasetEnabled(string name) @safe
    => envListAllows("WIRED_BENCH_DATASETS", name);

/// The corpora this run measures: the canonical list filtered by
/// `$WIRED_BENCH_DATASETS`, freshly loaded (each `@benchmark` body runs once).
private Dataset[] benchDatasets()
{
    import std.algorithm.iteration : filter;
    import std.array : array;

    return loadDatasets(defaultDatasets.filter!(n => datasetEnabled(n)).array,
        resolveDataDir(null));
}

/// The env filters can empty an op's matrix; an explicitly-labeled marker row
/// beats the runner's zero-case whole-body fallback, which would silently
/// measure this registration body instead.
private void markFilteredOut(string operation)
{
    benchCase(name: "(filtered out)", timed: () {}, after: () {},
        labels: ["operation": operation]);
}

/// Whether any compiled-in engine supports the op (gates the op's unittest).
private enum bool anyValidate = () {
    bool any;
    static foreach (E; AllEngines)
        static if (isJsonEngine!E && hasValidate!E)
            any = true;
    return any;
}();

/// ditto
private enum bool anySerialize = () {
    bool any;
    static foreach (E; AllEngines)
        static if (isJsonEngine!E && hasSerialize!E)
            any = true;
    return any;
}();

/// ditto
private enum bool anyDecode = () {
    bool any;
    static foreach (E; AllEngines)
        static if (canDecodeTwitter!E)
            any = true;
    return any;
}();

// Each op is registered from its own helper (a fresh frame per call), so its
// closures capture their own engine and `ds` copy — never a shared loop
// variable. Under `--bench` the cases run later, in a schedule the runner
// picks, so each is self-contained: every case owns a heap engine, and all
// untimed setup/release lives in `setup`/`teardown`.

@("wired.parse")
@benchmark
@system
unittest
{
    size_t registered;
    foreach (ref ds; benchDatasets)
    {
        const reference = referenceFingerprint(ds.text);
        static foreach (E; AllEngines)
            static if (isJsonEngine!E)
                if (engineEnabled(E.name))
                {
                    registerParse!E(ds, reference);
                    static if (hasParseInsitu!E)
                        registerParseInsitu!E(ds, reference);
                    registered++;
                }
    }
    if (!registered)
        markFilteredOut("parse");
}

static if (anyValidate)
@("wired.validate")
@benchmark
@system
unittest
{
    size_t registered;
    foreach (ref ds; benchDatasets)
        static foreach (E; AllEngines)
            static if (isJsonEngine!E && hasValidate!E)
                if (engineEnabled(E.name))
                {
                    registerValidate!E(ds);
                    registered++;
                }
    if (!registered)
        markFilteredOut("validate");
}

static if (anySerialize)
@("wired.serialize")
@benchmark
@system
unittest
{
    size_t registered;
    foreach (ref ds; benchDatasets)
    {
        const reference = referenceFingerprint(ds.text);
        static foreach (E; AllEngines)
            static if (isJsonEngine!E && hasSerialize!E)
                if (engineEnabled(E.name))
                {
                    registerSerialize!E(ds, reference);
                    registered++;
                }
    }
    if (!registered)
        markFilteredOut("serialize");
}

static if (anyDecode)
@("wired.decode")
@benchmark
@system
unittest
{
    size_t registered;
    if (datasetEnabled("twitter"))
        foreach (ref ds; loadDatasets(["twitter"], resolveDataDir(null)))
            static foreach (E; AllEngines)
                static if (canDecodeTwitter!E)
                    if (engineEnabled(E.name))
                    {
                        registerDecode!E(ds);
                        registered++;
                    }
    if (!registered)
        markFilteredOut("decode");
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

/// parse-insitu — verified like `parse`: the in-place parse must still produce
/// the reference document (a wrong-parsing engine must never "look faster").
private void registerParseInsitu(E)(Dataset ds, Fingerprint reference)
{
    auto e = new E;
    bool verified;
    benchCase(
        name: E.name,
        timed: () { e.parseInsitu(ds.text); },
        after: () {
            string error;
            if (!verified)
            {
                verified = true;
                const fp = e.fingerprint();
                if (!reference.matches(fp))
                    error = "in-situ fingerprint mismatch vs std.json:"
                        ~ diffFingerprints(reference, fp);
            }
            freeDocOf(*e);
            return error.length ? err!bool(error) : ok!string(true);
        },
        metrics: [bytes(ds.text.length)],
        labels: ["dataset": ds.name, "operation": "parse-insitu"],
        setup: engineSetup(e),
        teardown: engineTeardown(e),
    );
}

/// validate — the corpora are valid JSON, so an engine rejecting one is wrong;
/// a bool-returning validate is checked once in the untimed `after` (one extra
/// validate per case). A void validate signals rejection by throwing, which
/// the runner already surfaces as an error row from the timed body itself.
private void registerValidate(E)(Dataset ds)
{
    auto e = new E;
    bool verified;
    benchCase(
        name: E.name,
        timed: () { cast(void) e.validate(ds.text); },
        after: () {
            string error;
            if (!verified)
            {
                verified = true;
                static if (is(typeof(e.validate(ds.text)) == bool))
                    if (!e.validate(ds.text))
                        error = "engine rejects a valid corpus";
            }
            return error.length ? err!bool(error) : ok!string(true);
        },
        metrics: [bytes(ds.text.length)],
        labels: ["dataset": ds.name, "operation": "validate"],
        setup: engineSetup(e),
        teardown: engineTeardown(e),
    );
}

/// serialize — the output must still fingerprint to the reference document
/// (structural check via std.json, format-independent); verified once in the
/// untimed `after`, so a wrong serialization can't post a competitive B/s row.
private void registerSerialize(E)(Dataset ds, Fingerprint reference)
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
    bool verified;
    benchCase(
        name: E.name,
        timed: () { cast(void) e.serialize(); },
        after: () {
            string error;
            if (!verified)
            {
                verified = true;
                try
                {
                    const fp = referenceFingerprint(e.serialize());
                    if (!reference.matches(fp))
                        error = "serialize output mismatch vs std.json:"
                            ~ diffFingerprints(reference, fp);
                }
                catch (Exception ex)
                    error = "serialize output is not valid JSON: " ~ ex.msg;
            }
            return error.length ? err!bool(error) : ok!string(true);
        },
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
