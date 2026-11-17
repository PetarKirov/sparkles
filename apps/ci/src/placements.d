/++
Placements: where CI runs a test mode, in how many shards, and which packages
each shard runs (CIC14, before `ci pipeline`: PLAN M3a).

`ci/placements.json` declares each placement. A placement's shards are packed
longest first by the median `task.wall` of each package's last five recorded
runs on that placement, read from `refs/perf/data` (OD21). A package with no
record takes the median of the placement's recorded packages, so a new one is
neither free nor dominant. Every input that decides the packing is ordered, so
every shard of a run, packing on its own, arrives at the same partition.

This module is the pure half: the file, the medians, the packing. Reading the
history lives in `perf_history`.
+/
module placements;

import std.algorithm.iteration : filter, map;
import std.algorithm.searching : startsWith;
import std.algorithm.sorting : sort;
import std.array : array;
import std.conv : ConvException, to;
import std.format : format;
import std.json : JSONException, JSONType, JSONValue, parseJSON;
import std.string : indexOf;

import sparkles.base.expected : Expected, err, ok;

/// What a placement runs: the `ci` test mode, and the task-id mode it records.
enum PlacementMode : ubyte
{
    test, /// `ci test`; tasks `test:<package>:unittest:<leg>`
    sanitize, /// `ci test --sanitize address`; tasks `test:<package>:sanitize:<leg>`
    extracted, /// `ci test --special-modes all`; tasks `test:<package>:betterc|wasm:<leg>`
}

/// One placement of `ci/placements.json`.
struct Placement
{
    string name; /// `x86_64-linux-ldc2`: also the `placement` fact of its records
    string system; /// The Nix system it runs on.
    string compiler; /// `$DC` for its tests.
    PlacementMode mode;
    uint shards;
    uint timeoutMinutes;
    string[string] runners; /// Runner label per CI provider (`github`, `circleci`).
    /// Which `ci test` legs run (`ci` CIC11): `-t 1`, on each worker's main
    /// thread, and `-t N`. Default: the parallel leg alone (OD22).
    bool serialLeg;
    /// ditto
    bool parallelLeg = true;
    /// Whether the placement builds with `-cov` and reports coverage: one
    /// placement does (OD22).
    bool coverage;
}

/// The placements file.
struct Placements
{
    Placement[] placements;
    /// The minutes a toolchain pin build may take in a CI job before the build
    /// plan leaves it to a developer host (toolchain TC23).
    uint pinBuildBudgetMinutes = 300;

    /// The placement called `name`, or null.
    const(Placement)* find(string name) const @safe pure nothrow
    {
        foreach (ref p; placements)
            if (p.name == name)
                return &p;
        return null;
    }
}

private PlacementMode modeOf(string text, out bool known) @safe pure nothrow @nogc
{
    known = true;
    switch (text)
    {
        case "test": return PlacementMode.test;
        case "sanitize": return PlacementMode.sanitize;
        case "extracted": return PlacementMode.extracted;
        default:
            known = false;
            return PlacementMode.test;
    }
}

/**
`ci/placements.json`: `{"schema": "sparkles.ci.placements", "version": 1,
"placements": [ … ]}`. Every member of a placement is required, names are
unique, and a shard count is between 1 and 16.
*/
Expected!(Placements, string) parsePlacements(string json) @safe
{
    JSONValue root;
    try
        root = parseJSON(json);
    catch (JSONException e)
        return err!Placements("the placements are not JSON: " ~ e.msg);
    if (root.type != JSONType.object || "schema" !in root || root["schema"].type != JSONType.string
        || root["schema"].str != "sparkles.ci.placements")
        return err!Placements(`the placements file needs "schema": "sparkles.ci.placements"`);
    if ("version" !in root || root["version"].type != JSONType.integer || root["version"].integer != 1)
        return err!Placements("the placements file's version must be 1");
    if ("placements" !in root || root["placements"].type != JSONType.array)
        return err!Placements("placements is not an array");

    Placements parsed;
    foreach (entry; (() @trusted => root["placements"].array)())
    {
        static bool isString(const JSONValue v, string key) @safe =>
            key in v && v[key].type == JSONType.string && v[key].str.length > 0;
        static bool isCount(const JSONValue v, string key) @safe =>
            key in v && v[key].type == JSONType.integer && v[key].integer > 0;

        if (entry.type != JSONType.object || !isString(entry, "name"))
            return err!Placements("a placement has no name");
        const name = entry["name"].str;
        foreach (key; ["system", "compiler", "mode"])
            if (!isString(entry, key))
                return err!Placements(format("placement %s has no %s", name, key));
        foreach (key; ["shards", "timeoutMinutes"])
            if (!isCount(entry, key))
                return err!Placements(format("placement %s needs a positive %s", name, key));
        if (entry["shards"].integer > 16)
            return err!Placements(format("placement %s asks for more than 16 shards", name));
        bool known;
        const mode = modeOf(entry["mode"].str, known);
        if (!known)
            return err!Placements(format("placement %s has an unknown mode %s", name, entry["mode"].str));
        if ("runners" !in entry || entry["runners"].type != JSONType.object)
            return err!Placements(format("placement %s has no runners", name));
        string[string] runners;
        foreach (provider, label; (() @trusted => entry["runners"].object)())
        {
            if (label.type != JSONType.string || label.str.length == 0)
                return err!Placements(format("placement %s's %s runner is not a label", name, provider));
            runners[provider] = label.str;
        }
        if (parsed.find(name) !is null)
            return err!Placements("two placements are called " ~ name);
        bool serialLeg, parallelLeg = true, coverage;
        if ("legs" in entry)
        {
            if (entry["legs"].type != JSONType.array || (() @trusted => entry["legs"].array.length)() == 0)
                return err!Placements(format("placement %s's legs must be a non-empty list", name));
            parallelLeg = false;
            foreach (leg; (() @trusted => entry["legs"].array)())
            {
                if (leg.type == JSONType.string && leg.str == "serial")
                    serialLeg = true;
                else if (leg.type == JSONType.string && leg.str == "parallel")
                    parallelLeg = true;
                else
                    return err!Placements(format("placement %s has an unknown leg; legs are serial and parallel", name));
            }
        }
        if ("coverage" in entry)
        {
            if (entry["coverage"].type != JSONType.true_ && entry["coverage"].type != JSONType.false_)
                return err!Placements(format("placement %s's coverage must be true or false", name));
            coverage = entry["coverage"].type == JSONType.true_;
        }
        parsed.placements ~= Placement(name, entry["system"].str, entry["compiler"].str, mode,
            cast(uint) entry["shards"].integer, cast(uint) entry["timeoutMinutes"].integer, runners,
            serialLeg, parallelLeg, coverage);
    }
    if ("pinBuildBudgetMinutes" in root)
    {
        const budget = root["pinBuildBudgetMinutes"];
        if (budget.type != JSONType.integer || budget.integer <= 0 || budget.integer >= 360)
            return err!Placements("pinBuildBudgetMinutes must be between 1 and 359");
        parsed.pinBuildBudgetMinutes = cast(uint) budget.integer;
    }
    if (parsed.placements.length == 0)
        return err!Placements("the placements file declares no placement");
    return ok(parsed);
}

@("placements.parsePlacements.strict")
@safe
unittest
{
    enum one = `{"name":"x86_64-linux-ldc2","system":"x86_64-linux","compiler":"ldc2","mode":"test",`
        ~ `"shards":2,"timeoutMinutes":120,"runners":{"github":"ubuntu-latest"}}`;
    const parsed = parsePlacements(`{"schema":"sparkles.ci.placements","version":1,"placements":[` ~ one ~ `]}`);
    assert(parsed.hasValue);
    const p = parsed.value.find("x86_64-linux-ldc2");
    assert(p !is null && p.shards == 2 && p.mode == PlacementMode.test);
    assert(p.runners["github"] == "ubuntu-latest");

    assert(parsePlacements(`{"schema":"other","version":1,"placements":[]}`).hasError);
    assert(parsePlacements(`{"schema":"sparkles.ci.placements","version":2,"placements":[]}`).hasError);
    assert(parsePlacements(`{"schema":"sparkles.ci.placements","version":1,"placements":[]}`).hasError,
        "no placement");
    assert(parsePlacements(`{"schema":"sparkles.ci.placements","version":1,"placements":[`
        ~ one ~ "," ~ one ~ `]}`).hasError, "duplicate names");
    import std.array : replace;

    assert(parsePlacements(`{"schema":"sparkles.ci.placements","version":1,"placements":[`
        ~ one.replace(`"shards":2`, `"shards":17`) ~ `]}`).hasError);
    assert(parsePlacements(`{"schema":"sparkles.ci.placements","version":1,"placements":[`
        ~ one.replace(`"mode":"test"`, `"mode":"bench"`) ~ `]}`).hasError);

    // Legs and coverage: the parallel leg alone and no coverage unless asked.
    assert(!p.serialLeg && p.parallelLeg && !p.coverage);
    const both = parsePlacements(`{"schema":"sparkles.ci.placements","version":1,"placements":[`
        ~ one.replace(`"shards":2`, `"shards":2,"legs":["serial","parallel"],"coverage":true`) ~ `]}`);
    assert(both.hasValue && both.value.placements[0].serialLeg && both.value.placements[0].coverage);
    assert(parsePlacements(`{"schema":"sparkles.ci.placements","version":1,"placements":[`
        ~ one.replace(`"shards":2`, `"shards":2,"legs":["fast"]`) ~ `]}`).hasError);
    assert(parsePlacements(`{"schema":"sparkles.ci.placements","version":1,"placements":[`
        ~ one.replace(`"shards":2`, `"shards":2,"legs":[]`) ~ `]}`).hasError);
}

/**
The median of `samples`, the mean of the middle two for an even count, in
the samples' integer unit. `samples` is left unchanged.
*/
ulong median(in ulong[] samples) @safe pure nothrow
in (samples.length > 0)
{
    auto sorted = samples.dup.sort;
    const n = sorted.length;
    return n % 2 ? sorted[n / 2] : sorted[n / 2 - 1] / 2 + sorted[n / 2] / 2
        + (sorted[n / 2 - 1] % 2 + sorted[n / 2] % 2) / 2;
}

@("placements.median.oddAndEven")
@safe pure nothrow
unittest
{
    assert(median([5]) == 5);
    assert(median([9, 1, 5]) == 5);
    assert(median([1, 4, 2, 10]) == 3);
    assert(median([ulong.max, ulong.max]) == ulong.max, "no overflow");
}

/// How many of a package's most recent records its weight takes.
enum uint weightWindow = 5;

/**
A package's weight on a placement: per record, the sum of the `task.wall`
of its tasks (both test legs, every extracted mode), in nanoseconds;
then the median over its `weightWindow` most recent records that measured
it. `recordsNewestFirst` holds, per record, a map from task id to wall time.
Absent from every record: `ulong.max`, which `pack` resolves.
*/
ulong[string] packageWeights(in string[] packages, in ulong[string][] recordsNewestFirst,
    PlacementMode mode) @safe pure
{
    const prefixFor = (string pkg) => "test:" ~ pkg ~ ":";
    ulong[string] weights;
    foreach (pkg; packages)
    {
        ulong[] samples;
        foreach (record; recordsNewestFirst)
        {
            if (samples.length == weightWindow)
                break;
            ulong total;
            bool seen;
            foreach (id, wall; record)
                if (id.startsWith(prefixFor(pkg)) && modeMatches(id[prefixFor(pkg).length .. $], mode))
                {
                    total += wall;
                    seen = true;
                }
            if (seen)
                samples ~= total;
        }
        weights[pkg] = samples.length ? median(samples) : ulong.max;
    }
    return weights;
}

private bool modeMatches(string rest, PlacementMode mode) @safe pure nothrow @nogc
{
    final switch (mode)
    {
        case PlacementMode.test: return rest.startsWith("unittest:");
        case PlacementMode.sanitize: return rest.startsWith("sanitize:");
        case PlacementMode.extracted: return rest.startsWith("betterc:") || rest.startsWith("wasm:");
    }
}

@("placements.packageWeights.windowAndMode")
@safe pure
unittest
{
    // Newest first: six records of `base`; the oldest one falls outside the window.
    ulong[string][] records = [
        ["test:base:unittest:serial": 10, "test:base:unittest:parallel": 5, "test:base:sanitize:parallel": 99],
        ["test:base:unittest:serial": 20],
        ["test:ui:unittest:serial": 7],
        ["test:base:unittest:serial": 30],
        ["test:base:unittest:serial": 40],
        ["test:base:unittest:serial": 50],
        ["test:base:unittest:serial": 1_000],
    ];
    const weights = packageWeights(["base", "ui", "new"], records, PlacementMode.test);
    assert(weights["base"] == 30, "median of 15, 20, 30, 40, 50: legs summed, the sanitizer task left out");
    assert(weights["ui"] == 7);
    assert(weights["new"] == ulong.max, "never recorded");
    assert(packageWeights(["base"], records, PlacementMode.sanitize)["base"] == 99);
}

/**
Partition `packages` into `shards` lists: longest first, each onto the
least-loaded shard, ties going to the lower-numbered shard and, between
equal weights, to the earlier name. An unrecorded package (`ulong.max`)
weighs the median of the recorded ones, or 1 when none is recorded. Each
shard's list comes out in name order.
*/
string[][] pack(in string[] packages, in ulong[string] weights, uint shards) @safe pure
in (shards > 0)
{
    auto recorded = packages.map!(p => weights.get(p, ulong.max)).filter!(w => w != ulong.max).array;
    const fallback = recorded.length ? median(recorded) : 1;
    ulong weightOf(string p) @safe pure
    {
        const w = weights.get(p, ulong.max);
        return w == ulong.max ? fallback : w;
    }

    auto order = packages.dup.sort!((a, b) => weightOf(a) > weightOf(b) || (weightOf(a) == weightOf(b) && a < b)).release;
    auto load = new ulong[](shards);
    auto members = new string[][](shards);
    foreach (p; order)
    {
        size_t best;
        foreach (i; 1 .. shards)
            if (load[i] < load[best])
                best = i;
        load[best] += weightOf(p);
        members[best] ~= p;
    }
    foreach (ref m; members)
        m.sort();
    return members;
}

@("placements.pack.longestFirstAndDeterministic")
@safe pure
unittest
{
    const weights = ["a": 50UL, "b": 30, "c": 20, "d": 10, "e": ulong.max];
    const shards = pack(["e", "d", "c", "b", "a"], weights, 2);
    // "e" weighs 25, the median of 50, 30, 20 and 10: a → 0, b → 1, e → 1, c → 0, d → 1.
    assert(shards == [["a", "c"], ["b", "d", "e"]]);
    assert(pack(["e", "d", "c", "b", "a"], weights, 2) == pack(["a", "b", "c", "d", "e"], weights, 2),
        "the input order does not matter");
    assert(pack(["x", "y", "z"], null, 3) == [["x"], ["y"], ["z"]], "no records: equal weights");
    assert(pack(["x"], null, 2) == [["x"], []], "a shard may be empty");
}

/// `K/N`, 1-based, as `--shard` takes it.
Expected!(uint[2], string) parseShard(string text) @safe pure
{

    const slash = text.indexOf('/');
    if (slash <= 0 || slash == text.length - 1)
        return err!(uint[2])("--shard takes K/N, such as 2/3: " ~ text);
    uint k, n;
    try
    {
        k = text[0 .. slash].to!uint;
        n = text[slash + 1 .. $].to!uint;
    }
    catch (ConvException)
        return err!(uint[2])("--shard takes K/N, such as 2/3: " ~ text);
    if (n == 0 || k == 0 || k > n)
        return err!(uint[2])(format("--shard %s: K must be between 1 and N", text));
    return ok(cast(uint[2])[k, n]);
}

@("placements.parseShard.bounds")
@safe pure
unittest
{
    assert(parseShard("2/3").value == [2, 3]);
    assert(parseShard("1/1").value == [1, 1]);
    assert(parseShard("0/3").hasError);
    assert(parseShard("4/3").hasError);
    assert(parseShard("2").hasError);
    assert(parseShard("a/b").hasError);
}
