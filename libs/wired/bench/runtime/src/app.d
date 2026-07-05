/**
`runtime-bench` — runtime JSON benchmark for `sparkles:wired`.

Compares JSON engines across D (`std.json` baseline, mir-ion, asdf,
jsoniopipe), C (yyjson via ImportC), C++ (simdjson DOM + On-Demand,
rapidjson via an `extern "C"` shim), and Rust (serde_json, simd-json,
sonic-rs via a staticlib shim) over the canonical benchmark corpora, to
establish the performance targets for replacing `std.json` inside
`sparkles:wired`.

Every engine must reproduce the `std.json` structural fingerprint of each
dataset before its timings are trusted. Ops: `parse`, `parse-insitu`,
`serialize`, `validate`, `decode` — each engine only gets the rows its
adapter's capabilities (design-by-introspection traits) support.

Run (canonical — release codegen tuned to the host CPU):
---
dub run -b bench -- [--datasets=twitter,canada] [--engines=std.json,yyjson]
    [--ops=parse,serialize] [--min-time-ms=2000] [--json=FILE]
---
*/
module sparkles.wired_bench.app;

import std.stdio : stderr, writefln, writeln;

import sparkles.core_cli.args : parseCliArgs;
import sparkles.core_cli.help_formatting : HelpInfo;

import sparkles.wired_bench.config : BenchOptions;
import sparkles.wired_bench.data : loadDatasets, resolveDataDir;
import sparkles.wired_bench.engines : AllEngines;
import sparkles.wired_bench.report : BenchReport, collectEnvInfo, dumpJson,
    reportEnvironment, reportResults;
import sparkles.wired_bench.runner : runAll;

int main(string[] args)
{
    const opts = args.parseCliArgs!BenchOptions(
        HelpInfo("runtime-bench", "Runtime JSON benchmark for sparkles:wired."));

    version (assert)
        stderr.writeln("warning: assert-enabled build — benchmark numbers are "
            ~ "meaningless; use `dub run -b bench`");

    const datasets = loadDatasets(opts.datasetNames, resolveDataDir(opts.dataDir));
    const env = collectEnvInfo();
    reportEnvironment(env, datasets);

    auto results = runAll!AllEngines(datasets, opts);
    reportResults(results, datasets);

    if (opts.json.length)
    {
        dumpJson(BenchReport(env, results), opts.json);
        writefln!"\nreport written to %s"(opts.json);
    }

    // A verification failure poisons the whole comparison — reflect it in
    // the exit status so scripted runs can't miss it.
    foreach (r; results)
        if (r.error.length)
            return 1;
    return 0;
}
