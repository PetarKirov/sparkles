/++
The impure half of the placements (`placements`): reading `ci/placements.json`
and the history, choosing a shard's packages, and listing the placements for a
CI provider's matrix (CIC14, before `ci pipeline`: PLAN M3a).

Every shard of a run reads the same `refs/perf/data` commit: the one the
planning job passes as `--history-tip`, or else the newest commit whose
committer time is not later than the measured commit's. A history that cannot
be read leaves every package at an equal weight, reported as a run
degradation, so a shard still runs a deterministic share of the packages.
+/
module placements_run;

import std.array : array, join;
import std.conv : to;
import std.file : exists, readText;
import std.format : format;
import std.path : baseName, buildPath;
import std.string : strip;

import sparkles.base.expected : Expected, err, ok;
import sparkles.build_primitives.git_env : runGitStdout;

import perf_history : canonicalRemote, historyCacheDir, historyTip, openHistory, placementWallTimes;
import placements : Placement, PlacementMode, Placements, pack, packageWeights, parsePlacements, weightWindow;

/// `ci/placements.json` of the repository at `repoRoot`.
Expected!(Placements, string) loadPlacements(string repoRoot) @trusted
{
    const path = buildPath(repoRoot, "ci", "placements.json");
    if (!exists(path))
        return err!Placements("no " ~ path);
    try
        return parsePlacements(readText(path));
    catch (Exception e)
        return err!Placements("cannot read " ~ path ~ ": " ~ e.msg);
}

/// What a shard runs, and what the choice rested on.
struct ShardChoice
{
    string[] packages; /// Sub-package directories, as `subPackageDirectories` names them.
    string historyTip; /// The `refs/perf/data` commit read, or empty.
    size_t records; /// How many records the weights came from.
    string[] degradations;
}

/**
The packages of shard `k` (1-based) of `placementName`: `allPackages` packed
by their recorded weights at the run's history tip. `requestedTip` is the
planning job's `--history-tip`, or empty.
*/
Expected!(ShardChoice, string) chooseShard(string repoRoot, string[] allPackages, string placementName,
    uint k, uint n, string requestedTip, string remote) @trusted
{
    auto loaded = loadPlacements(repoRoot);
    if (loaded.hasError)
        return err!ShardChoice(loaded.error);
    const p = loaded.value.find(placementName);
    if (p is null)
        return err!ShardChoice("ci/placements.json has no placement " ~ placementName);

    ShardChoice choice;
    ulong[string][] records;
    const from = remote.length ? remote : canonicalRemote;
    auto history = openHistory(historyCacheDir(from), from,
        buildPath(repoRoot, "nix", "perf-data-signers"));
    if (history.hasError)
        choice.degradations ~= history.error ~ "; packing on equal weights";
    else
    {
        choice.degradations ~= history.value.degradations;
        const head = runGitStdout(["log", "-1", "--format=%ct", "HEAD"], workDir: repoRoot);
        const notAfter = head.status == 0 ? head.output.strip.to!long : long.max;
        choice.historyTip = historyTip(history.value, requestedTip, notAfter);
        if (choice.historyTip.length)
        {
            string[] ignored;
            records = placementWallTimes(history.value, choice.historyTip, placementName,
                weightWindow * p.shards * 2, ignored);
            foreach (c; ignored)
                choice.degradations ~= "ignored the runs of " ~ c ~ ": unsigned or signed by an unlisted key";
        }
        else if (requestedTip.length)
            return err!ShardChoice("--history-tip " ~ requestedTip ~ " is not a commit of the history");
        else
            choice.degradations ~= "no history to pack from; packing on equal weights";
    }
    choice.records = records.length;

    // Weights are keyed by package name; the shard runs directories.
    string[string] dirOf;
    string[] names;
    foreach (dir; allPackages)
    {
        dirOf[dir.baseName] = dir;
        names ~= dir.baseName;
    }
    const shards = pack(names, packageWeights(names, records, p.mode), n);
    foreach (name; shards[k - 1])
        choice.packages ~= dirOf[name];
    return ok(choice);
}

/**
The placements as a CI provider's matrix: one entry per shard of every
placement the provider has a runner for, and of `mode` when one is given, with
the history tip every shard
reads, when there is one. `{"include": [{"placement", "system", "compiler", "mode",
"shard", "runner", "timeout"}, …], "tip": …}`.
*/
string placementMatrix(in Placements placements, string provider, string tip, string mode = null) @safe
{
    import std.json : JSONValue;

    JSONValue[] include;
    foreach (p; placements.placements)
    {
        const runner = p.runners.get(provider, null);
        if (runner is null || (mode.length && p.mode.to!string != mode))
            continue;
        foreach (k; 1 .. p.shards + 1)
        {
            JSONValue entry = [
                "placement": JSONValue(p.name),
                "system": JSONValue(p.system),
                "compiler": JSONValue(p.compiler),
                "mode": JSONValue(p.mode.to!string),
                "shard": JSONValue(format("%d/%d", k, p.shards)),
                "runner": JSONValue(runner),
                "timeout": JSONValue(p.timeoutMinutes),
            ];
            include ~= entry;
        }
    }
    JSONValue matrix = ["include": JSONValue(include)];
    // A matrix's other top-level keys are dimensions, so a job's matrix leaves the tip out.
    if (tip.length)
        matrix["tip"] = JSONValue(tip);
    return matrix.toString;
}

@("placementsRun.placementMatrix.perProvider")
@safe
unittest
{
    import std.json : parseJSON;

    Placements ps;
    ps.placements = [
        Placement("a", "x86_64-linux", "ldc2", PlacementMode.test, 2, 90, ["github": "ubuntu-latest"]),
        Placement("b", "aarch64-linux", "ldc2", PlacementMode.test, 3, 90, ["circleci": "arm"]),
    ];
    const m = parseJSON(placementMatrix(ps, "github", "abc"));
    assert(m["tip"].str == "abc");
    const include = (() @trusted => m["include"].array)();
    assert(include.length == 2, "b has no GitHub runner");
    assert(include[1]["shard"].str == "2/2" && include[1]["runner"].str == "ubuntu-latest");
    assert(include[0]["mode"].str == "test" && include[0]["timeout"].integer == 90);
}

/// A test run's place in the placements: `--placement`, `--shard`,
/// `--history-tip` and `--history-remote`.
struct PlacementArgs
{
    string placement;
    string shard;
    string historyTip;
    string historyRemote;
}

/// The placement a toolchain pin build of `system` records under.
string pinBuildPlacement(string system) @safe pure nothrow => "pin-build-" ~ system;

/**
The toolchain build plan's cost file (`toolchain-pin-check --costs`, TC23),
from the history: per pin, the median wall time of its last five
`pin-build:<pin>` tasks on its system's placement, in whole minutes rounded
up, and `ci/placements.json`'s budget. Never fails for want of history: no
record leaves every cost unrecorded, which the plan attempts.
*/
Expected!(string, string) pinCostsJson(string repoRoot, string remote, out string[] degradations) @trusted
{
    import std.json : JSONValue;
    import placements : median;

    auto loaded = loadPlacements(repoRoot);
    if (loaded.hasError)
        return err!string(loaded.error);
    JSONValue costs = JSONValue(string[string].init);
    const from = remote.length ? remote : canonicalRemote;
    auto history = openHistory(historyCacheDir(from), from,
        buildPath(repoRoot, "nix", "perf-data-signers"));
    if (history.hasError)
        degradations ~= history.error;
    else
    {
        degradations ~= history.value.degradations;
        const tip = historyTip(history.value, null, long.max);
        if (tip.length)
            foreach (system; ["x86_64-linux", "aarch64-darwin", "aarch64-linux"])
            {
                string[] ignored;
                ulong[][string] samples;
                foreach (record; placementWallTimes(history.value, tip, pinBuildPlacement(system), 50, ignored))
                    foreach (id, wall; record)
                        if (id.length > "pin-build:".length && id[0 .. "pin-build:".length] == "pin-build:")
                        {
                            const pin = id["pin-build:".length .. $];
                            if (samples.get(pin, null).length < weightWindow)
                                samples[pin] ~= wall;
                        }
                foreach (pin, walls; samples)
                {
                    const minutes = (median(walls) + 59_999_999_999) / 60_000_000_000;
                    costs[pin] = JSONValue([
                        "minutes": JSONValue(minutes),
                        "source": JSONValue(format("median of %d pin-build record(s) at refs/perf/data %s",
                            walls.length, tip[0 .. 12])),
                    ]);
                }
            }
    }
    JSONValue file = [
        "about": JSONValue("generated by ci --write-pin-costs from refs/perf/data (toolchain TC23)"),
        "budgetMinutes": JSONValue(loaded.value.pinBuildBudgetMinutes),
        "costs": costs,
    ];
    return ok(file.toString);
}
