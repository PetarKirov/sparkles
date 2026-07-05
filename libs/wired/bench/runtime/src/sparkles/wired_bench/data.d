/**
Benchmark corpus loading.

Datasets are the canonical JSON benchmark corpora pinned by
`nix/packages/wired-bench-data.nix` and exposed to the devshell as
`$WIRED_BENCH_DATA`; `--data-dir` overrides the environment.
*/
module sparkles.wired_bench.data;

import std.exception : enforce;
import std.file : exists, readText;
import std.path : buildPath;
import std.process : environment;

/// One loaded benchmark corpus.
struct Dataset
{
    string name;        /// dataset name, e.g. `twitter`
    string text;        /// the raw JSON text
}

/// The corpus directory: the CLI value if given, else `$WIRED_BENCH_DATA`.
string resolveDataDir(string cliValue) @safe
{
    if (cliValue.length)
        return cliValue;
    const env = environment.get("WIRED_BENCH_DATA");
    enforce(env !is null && env.length,
        "no data directory: pass --data-dir or enter the devshell (which sets $WIRED_BENCH_DATA)");
    return env;
}

/// Loads `<dataDir>/<name>.json` for every selected dataset name.
Dataset[] loadDatasets(const string[] names, string dataDir) @safe
{
    Dataset[] result;
    result.reserve(names.length);
    foreach (name; names)
    {
        const path = dataDir.buildPath(name ~ ".json");
        enforce(path.exists, "dataset not found: " ~ path);
        result ~= Dataset(name, readText(path));
    }
    return result;
}

@("data.resolveDataDir.cliWins")
@safe unittest
{
    assert(resolveDataDir("/some/dir") == "/some/dir");
}
