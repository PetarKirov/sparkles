/**
The benchmark body: engines × datasets × ops, driven through
`sparkles:test-runner`'s `benchCase`.

Each op is one `benchCase` row; per-op document release is the untimed `after`,
and correctness is checked there too — a fingerprint / `TwitterStats` mismatch
returns an `Expected` error, so a wrong engine becomes an isolated error row
instead of aborting the matrix. Hardware counters come from the runner's
`--perf`; there is no private perf backend any more.

The benchmark is one `@benchCases unittest` per op (`wired.parse`,
`wired.parse-stream`, `wired.validate`, `wired.serialize`, `wired.decode`):
skipped by a normal `dub test`, measured by `dub test -b bench -- --bench`
(add `--perf` for counters) — so `-i 'wired\.serialize'` measures one op, and
a registration failure in one op's body cannot abort the others. Engines and
datasets subset at run time via `$WIRED_BENCH_ENGINES` /
`$WIRED_BENCH_DATASETS` (comma lists; an empty dataset list selects the bundled
default). Corpora load from `$WIRED_BENCH_DATA` and
`$WIRED_BENCH_EXTERNAL_DATA` (see
$(MREF sparkles,wired_bench,data)).
*/
module sparkles.wired_bench.runner;

import core.lifetime : move;

import sparkles.base.expected : err, ok;
import std.conv : to;

import sparkles.test_runner.attributes : benchCases;
import sparkles.test_runner.bench : benchCase, Metric, Unit;

import sparkles.wired_bench.allocator : allocatorLevelled;
import sparkles.wired_bench.data : Dataset, DatasetFormat,
    datasetSource, defaultDatasetNames, loadDatasets, resolveDataDir;
import sparkles.wired_bench.engines;
import sparkles.wired_bench.fingerprint : diffFingerprints, Fingerprint,
    referenceFingerprint;
import sparkles.wired_bench.traits;
import sparkles.wired_bench.twitter : diffTwitterStats, referenceTwitterStats,
    TwitterStats;

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

private string[] selectedDatasetNames() @safe
{
    import core.runtime : Runtime;
    import std.algorithm.iteration : filter, splitter;
    import std.algorithm.searching : any, startsWith;
    import std.array : array;
    import std.process : environment;
    import sparkles.wired_bench.data : datasetSources, defaultDatasetNames;
    import sparkles.test_runner.metrics : matchesMetricGlob;

    string selected;
    const args = () @trusted { return Runtime.args; }();
    foreach (arg; args)
        if (arg.startsWith("--datasets="))
            selected = arg["--datasets=".length .. $];

    if (!selected.length)
        selected = environment.get("WIRED_BENCH_DATASETS", "");

    if (!selected.length)
        return defaultDatasetNames.dup;

    if (selected == "all" || selected == "help" || selected == "?")
    {
        string[] all;
        foreach (s; datasetSources)
            all ~= s.name;
        return all;
    }

    string[] result;
    const patterns = selected.splitter(',').array;
    foreach (source; datasetSources)
        if (patterns.any!(p => matchesMetricGlob(source.name, p)))
            result ~= source.name;

    return result;
}

private bool datasetEnabled(string name) @safe
{
    import std.algorithm.searching : canFind;
    return selectedDatasetNames.canFind(name);
}

/// The corpora this run measures: the canonical list filtered by
/// `$WIRED_BENCH_DATASETS`, freshly loaded (each `@benchmark` body runs once).
private Dataset[] benchDatasets(DatasetFormat format = DatasetFormat.document)
{
    import std.algorithm.iteration : filter;
    import std.algorithm.searching : any;
    import std.array : array;
    import sparkles.wired_bench.data : datasetSource, loadDatasets,
        resolveDataDir, resolveExternalDataDir;

    const extDir = resolveExternalDataDir(null);
    const names = selectedDatasetNames
        .filter!(n => datasetSource(n).format == format)
        .filter!(n => datasetSource(n).bundled || extDir.length)
        .array;
    if (!names.length)
        return null;
    const needsBundled = names.any!(n => datasetSource(n).bundled);
    return loadDatasets(names, needsBundled ? resolveDataDir(null) : null, extDir);
}

/// The env filters can empty an op's matrix; skip the test cleanly.
private void markFilteredOut(string operation)
{
    import sparkles.test_runner.skip : skipTest;
    skipTest("no matching datasets or engines enabled for " ~ operation);
}

/// The labels every row of an op over `ds` carries.
private string[string] labelsFor(in Dataset ds, string operation)
    => ["dataset": ds.name, "tier": ds.tier.to!string, "operation": operation];

/// An `after` verdict: `error` as an error row, or none when it is empty.
private auto verdict(string error)
    => error.length ? err!bool(error) : ok!string(true);

/// Registers one engine × dataset case, isolating a registration-time throw
/// (outside `--bench` the case runs right here) into a soft error row — a
/// throw escaping the `@benchmark` body would otherwise abort registration of
/// every case after it in this op's matrix.
private void register(C)(C aCase, string engineName, Dataset ds, string operation)
{
    try
        benchCase(move(aCase), name: engineName, labels: labelsFor(ds, operation),
            metrics: [bytes(ds.byteSize)]);
    catch (Exception e)
        benchCase(RegistrationFailed(e.msg), name: engineName,
            labels: labelsFor(ds, operation));
}

/// The error row standing in for a case whose registration threw.
private struct RegistrationFailed
{
    string msg;

    void timed() {}

    auto after() => err!bool("registration failed: " ~ msg);
}

/// The engine's own untimed `setup`/`teardown`, when it has them. Document
/// release is the timed op's per-call `after` (parse/-insitu) or the serialize
/// case's own teardown — not here.
private mixin template EngineLifecycle(E)
{
    static if (hasSetup!E)
        void setup() { engine.setup(); }

    static if (hasTeardown!E)
        void teardown() { engine.teardown(); }
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

/// Lazy reference fingerprint wrapper that evaluates std.json only when verification runs.
private final class LazyFingerprint
{
    private const(char)[] text;
    private Fingerprint cached;
    private bool computed;

    this(const(char)[] text) { this.text = text; }

    Fingerprint get()
    {
        if (!computed)
        {
            cached = referenceFingerprint(text);
            computed = true;
        }
        return cached;
    }
}

/// Lazy stream fingerprint wrapper.
private final class LazyStreamFingerprint
{
    private const Dataset ds;
    private Fingerprint cached;
    private bool computed;

    this(in Dataset ds) { this.ds = ds; }

    Fingerprint get()
    {
        if (!computed)
        {
            cached = referenceStream(ds).fingerprint;
            computed = true;
        }
        return cached;
    }
}

/// Lazy Twitter stats wrapper.
private final class LazyTwitterStats
{
    private const(char)[] text;
    private TwitterStats cached;
    private bool computed;

    this(const(char)[] text) { this.text = text; }

    TwitterStats get()
    {
        if (!computed)
        {
            cached = referenceTwitterStats(text);
            computed = true;
        }
        return cached;
    }
}

@("wired.parse")
@benchCases
@system
unittest
{
    size_t registered;
    foreach (ref ds; benchDatasets)
    {
        auto reference = new LazyFingerprint(ds.text);
        static foreach (E; AllEngines)
            static if (isJsonEngine!E)
                if (engineEnabled(E.name))
                {
                    register(ParseCase!E(ds, reference, new E), E.name, ds, "parse");
                    static if (hasParseInsitu!E)
                        register(ParseCase!(E, Insitu.yes)(ds, reference, new E), E.name, ds,
                            "parse-insitu");
                    registered++;
                }
    }
    if (!registered)
        markFilteredOut("parse");
}

@("wired.parse-stream")
@benchCases
@system
unittest
{
    size_t registered;
    foreach (format; [DatasetFormat.ndjson, DatasetFormat.jsonArrayLines])
        foreach (ref ds; benchDatasets(format))
        {
            auto reference = new LazyStreamFingerprint(ds);
            static foreach (E; AllEngines)
                static if (isJsonEngine!E)
                    if (engineEnabled(E.name))
                    {
                        register(ParseStreamCase!E(ds, reference, new E), E.name, ds, "parse-stream");
                        registered++;
                    }
        }
    if (!registered)
        markFilteredOut("parse-stream");
}

static if (anyValidate)
@("wired.validate")
@benchCases
@system
unittest
{
    size_t registered;
    foreach (ref ds; benchDatasets)
        static foreach (E; AllEngines)
            static if (isJsonEngine!E && hasValidate!E)
                if (engineEnabled(E.name))
                {
                    register(ValidateCase!E(ds, new E), E.name, ds, "validate");
                    registered++;
                }
    if (!registered)
        markFilteredOut("validate");
}

static if (anySerialize)
@("wired.serialize")
@benchCases
@system
unittest
{
    size_t registered;
    foreach (ref ds; benchDatasets)
    {
        auto reference = new LazyFingerprint(ds.text);
        static foreach (E; AllEngines)
            static if (isJsonEngine!E && hasSerialize!E)
                if (engineEnabled(E.name))
                {
                    register(SerializeCase!E(ds, reference, new E), E.name, ds, "serialize");
                    registered++;
                }
    }
    if (!registered)
        markFilteredOut("serialize");
}

static if (anyDecode)
@("wired.decode")
@benchCases
@system
unittest
{
    size_t registered;
    if (datasetEnabled("twitter"))
        foreach (ref ds; loadDatasets(["twitter"], resolveDataDir(null)))
        {
            auto expected = new LazyTwitterStats(ds.text);
            static foreach (E; AllEngines)
                static if (canDecodeTwitter!E)
                    if (engineEnabled(E.name))
                    {
                        register(DecodeCase!E(ds, expected, new E), E.name, ds, "decode");
                        registered++;
                    }
        }
    if (!registered)
        markFilteredOut("decode");
}

// Each case owns its engine and its copy of `ds`; the lazy references are
// shared by every engine's case over the same dataset, computed once.

/// Whether a parse case parses in place (`parseInsitu`).
private enum Insitu : bool { no, yes }

/**
parse / parse-insitu — the fingerprint check rides the (untimed) `after`,
verified once; a mismatch turns this into an isolated error row. Each timed
parse allocates a document that `after` releases. The in-place parse is held
to the same reference document: a wrong-parsing engine must never "look
faster".
*/
private struct ParseCase(E, Insitu insitu = Insitu.no)
{
    Dataset ds;
    LazyFingerprint reference;
    E* engine; // its own allocation, as the engines were always measured
    bool verified;

    mixin EngineLifecycle!E;

    void timed()
    {
        static if (insitu)
            engine.parseInsitu(ds.text);
        else
            engine.parse(ds.text);
    }

    auto after()
    {
        enum what = insitu ? "in-situ fingerprint" : "fingerprint";
        string error;
        if (!verified)
        {
            verified = true;
            const fp = engine.fingerprint();
            const refFp = reference.get();
            if (!refFp.matches(fp))
                error = what ~ " mismatch vs std.json:" ~ diffFingerprints(refFp, fp);
        }
        freeDocOf(*engine);
        return verdict(error);
    }
}

/// parse-stream — parse and release every record in an NDJSON corpus or in a
/// line-oriented top-level array. Framing and record parsing are both timed;
/// structural parity against `std.json` is checked once outside the clock.
private struct ParseStreamCase(E)
{
    Dataset ds;
    LazyStreamFingerprint reference;
    E* engine; // its own allocation, as the engines were always measured
    bool verified;

    mixin EngineLifecycle!E;

    void timed()
    {
        foreach (record; ds.records)
        {
            engine.parse(record);
            freeDocOf(*engine);
        }
    }

    auto after()
    {
        string error;
        if (!verified)
        {
            verified = true;
            Fingerprint actual;
            foreach (record; ds.records)
            {
                engine.parse(record);
                actual.add(engine.fingerprint());
                freeDocOf(*engine);
            }
            const refFp = reference.get();
            if (!refFp.matches(actual))
                error = "stream fingerprint mismatch vs std.json:"
                    ~ diffFingerprints(refFp, actual);
        }
        return verdict(error);
    }
}

/// validate — the corpora are valid JSON, so an engine rejecting one is wrong;
/// a bool-returning validate is checked once in the untimed `after` (one extra
/// validate per case). A void validate signals rejection by throwing, which
/// the runner already surfaces as an error row from the timed body itself.
private struct ValidateCase(E)
{
    Dataset ds;
    E* engine; // its own allocation, as the engines were always measured
    bool verified;

    mixin EngineLifecycle!E;

    void timed() { cast(void) engine.validate(ds.text); }

    auto after()
    {
        string error;
        if (!verified)
        {
            verified = true;
            static if (is(typeof(engine.validate(ds.text)) == bool))
                if (!engine.validate(ds.text))
                    error = "engine rejects a valid corpus";
        }
        return verdict(error);
    }
}

/// serialize — the output must still fingerprint to the reference document
/// (structural check via std.json, format-independent); verified once in the
/// untimed `after`, so a wrong serialization can't post a competitive B/s row.
/// One parsed document is held across the whole case (untimed).
private struct SerializeCase(E)
{
    Dataset ds;
    LazyFingerprint reference;
    E* engine; // its own allocation, as the engines were always measured
    bool verified;

    void setup()
    {
        static if (hasSetup!E)
            engine.setup();
        engine.parse(ds.text);
    }

    void timed() { cast(void) engine.serialize(); }

    auto after()
    {
        string error;
        if (!verified)
        {
            verified = true;
            try
            {
                const fp = referenceFingerprint(engine.serialize());
                const refFp = reference.get();
                if (!refFp.matches(fp))
                    error = "serialize output mismatch vs std.json:"
                        ~ diffFingerprints(refFp, fp);
            }
            catch (Exception ex)
                error = "serialize output is not valid JSON: " ~ ex.msg;
        }
        return verdict(error);
    }

    void teardown()
    {
        freeDocOf(*engine);
        static if (hasTeardown!E)
            engine.teardown();
    }
}

/// decode — typed decode of the twitter corpus, held once (untimed) to the
/// `std.json` reference's `TwitterStats`.
private struct DecodeCase(E)
{
    Dataset ds;
    LazyTwitterStats expected;
    E* engine; // its own allocation, as the engines were always measured
    bool verified;

    mixin EngineLifecycle!E;

    void timed() { engine.decodeTwitter(ds.text); }

    auto after()
    {
        string error;
        if (!verified)
        {
            verified = true;
            const actual = engine.twitterStats();
            const exp = expected.get();
            if (actual != exp)
                error = "twitter stats mismatch vs std.json:"
                    ~ diffTwitterStats(exp, actual);
        }
        return verdict(error);
    }
}

/// The `std.json` reference of a line-oriented corpus.
private struct StreamReference
{
    Fingerprint fingerprint;
    size_t records;
}

private StreamReference referenceStream(in Dataset ds)
{
    import core.memory : GC;

    // std.json owns its trees on the GC heap. Collect in bounded batches and
    // return unused pages before measurement, otherwise a multi-gig reference
    // pass would contaminate both the parser's starting heap and RSS profiling.
    scope (exit)
    {
        GC.collect();
        GC.minimize();
    }

    StreamReference result;
    foreach (record; ds.records)
    {
        result.fingerprint.add(referenceFingerprint(record));
        result.records++;
        if ((result.records & 255) == 0)
            GC.collect();
    }
    return result;
}
