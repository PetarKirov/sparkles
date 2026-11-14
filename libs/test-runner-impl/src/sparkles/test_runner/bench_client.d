/**
 * The runner's side of the bench commands (process-model TRP18–TRP21): a
 * worker opens the measurement sources, registers each `@benchmark` test's
 * cases, measures them one at a time, and runs the `@workload` tests, and the
 * runner gets back plain values to render.
 */
module sparkles.test_runner.bench_client;

import std.json : JSONValue;

import sparkles.test_runner.bench : BenchConfig, BenchStats, Metric;
import sparkles.test_runner.bench_session : BenchOptions, BenchProbe, MetricsListing;
import sparkles.test_runner.client : decodeResult, Worker;
import sparkles.test_runner.model : Test, TestResult, Thrown;
import sparkles.test_runner.protocol : fromJson, frameOf, toJson;
import sparkles.test_runner.workload : WorkloadOutcome, WorkloadWindow;

/// One registered case, as the runner sees it: everything but its closures,
/// which stay in the worker.
struct BenchCase
{
    size_t id;   /// the worker's case id, for `measure`
    size_t test; /// the registering test's id
    string name;
    string[string] labels;
    Metric[] metrics;
}

/// What registering one test produced.
struct Registered
{
    BenchCase[] cases;
    TestResult result;
    string[] provenance;
}

/// Opens the sources `options` select (TRP21); with `list`, also fills
/// `listing` for `--list-metrics`.
BenchProbe probe(Worker worker, in BenchOptions options, bool list, out MetricsListing listing)
{
    import sparkles.profiling.counters.raw : RawEvent;

    BenchProbe result;
    foreach (ref frame; worker.request(frameOf("probe", [
            "options": toJson(options),
            "list": JSONValue(list),
        ]), "probed"))
    {
        switch (frame["t"].str)
        {
            case "note":
                result.notes ~= frame["text"].str;
                break;
            case "catalog":
                listing = fromJson!MetricsListing(frame);
                break;
            case "probed":
                result.syscallNames = fromJson!(string[])(frame["syscallNames"]);
                result.rawEvents = fromJson!(RawEvent[])(frame["rawEvents"]);
                break;
            default:
                break;
        }
    }
    return result;
}

/// Registers `test`'s cases under `config` (TRP18).
Registered register(Worker worker, Test test, in BenchConfig config)
{
    Registered registered;
    foreach (ref frame; worker.request(frameOf("register", [
            "ids": JSONValue([JSONValue(test.id)]),
            "config": toJson(config),
        ]), "registered"))
    {
        switch (frame["t"].str)
        {
            case "case":
                registered.cases ~= BenchCase(
                    id: fromJson!size_t(frame["case"]),
                    test: fromJson!size_t(frame["test"]),
                    name: fromJson!string(frame["name"]),
                    labels: fromJson!(string[string])(frame["labels"]),
                    metrics: fromJson!(Metric[])(frame["metrics"]),
                );
                break;
            case "result":
                registered.result = decodeResult(test, frame);
                break;
            case "provenance":
                registered.provenance ~= frame["line"].str;
                break;
            default:
                break;
        }
    }
    return registered;
}

/// Measures registered case `id` (TRP19); `thrown` holds what a hard throw
/// during the measurement carried.
BenchStats measure(Worker worker, size_t id, in BenchConfig config,
    out immutable(Thrown)[] thrown)
{
    BenchStats row;
    foreach (ref frame; worker.request(frameOf("measure", [
            "case": JSONValue(id),
            "config": toJson(config),
        ]), "measured"))
        if (frame["t"].str == "row")
        {
            row = fromJson!BenchStats(frame["stats"]);
            thrown = fromJson!(immutable(Thrown)[])(frame["thrown"]);
        }
    return row;
}

/// Runs `@workload` test `test` (TRP20); `notes` holds a disclosure the
/// worker made while opening the workload sources.
WorkloadOutcome workload(Worker worker, Test test, ref string[] notes)
{
    WorkloadOutcome outcome;
    foreach (ref frame; worker.request(frameOf("workload", [
            "id": JSONValue(test.id),
        ]), "result"))
    {
        switch (frame["t"].str)
        {
            case "note":
                notes ~= frame["text"].str;
                break;
            case "window":
                outcome.windows ~= fromJson!WorkloadWindow(frame["window"]);
                break;
            case "result":
                outcome.result = decodeResult(test, frame);
                break;
            default:
                break;
        }
    }
    return outcome;
}
