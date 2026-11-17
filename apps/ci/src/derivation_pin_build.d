/**
Which missing pin-set outputs CI builds, and where (TC23): the plan the
`pin-plan` job hands to the `pin-build` matrix.

An output the caches lack is built in CI when its recorded build cost fits a
job's budget, on a runner of its system. One whose cost exceeds the budget is
left to a developer host, and so is one whose derivation closure needs such an
output. An output with no recorded cost is attempted: `ci/with-cache.sh`
pushes each derivation as it finishes, so a timed-out attempt still keeps its
progress. A flake input's source is fetched rather than built; the mirror
step copies it.

Nothing here runs a command or touches the network: the plan job evaluates the
set, asks the caches and the store, then hands the answers to these functions.
*/
module derivation_pin_build;

import std.algorithm.iteration : filter, map;
import std.algorithm.searching : canFind, startsWith;
import std.algorithm.sorting : sort;
import std.array : array, join;
import std.format : format;
import std.json : JSONException, JSONType, JSONValue, parseJSON;

import sparkles.base.expected : Expected, err, ok;

import derivation_pin_set : Target, pinSystems;

/// The job limit of a GitHub-hosted runner, in minutes.
enum uint jobLimitMinutes = 360;

/// One pin-set entry as the plan evaluates it: its outputs and, for a
/// derivation, the `.drv` that builds it (empty for a flake input's source).
struct PlanTarget
{
    Target target;
    string drvPath;

    bool buildable() const @safe pure nothrow @nogc => drvPath.length > 0;
}

/// Argv that evaluates every entry's out path and derivation for `system`.
string[] pinSetPlanEvalArgs(string system) @safe pure nothrow => [
    "nix", "eval", "--json", ".#legacyPackages." ~ system ~ ".pinTargets",
    "--apply", "builtins.mapAttrs (_: d: { out = d.outPath; drv = d.drvPath or null; })",
];

/**
The entries of one system from `nix eval` output: an object from entry name
to `{ "out": <store path>, "drv": <store path> | null }`, sorted by name.
Anything else is an error, and so is an empty set.
*/
Expected!(PlanTarget[], string) parsePlanSet(string system, string json) @safe
{
    JSONValue root;
    try
        root = parseJSON(json);
    catch (JSONException e)
        return err!(PlanTarget[])(format("pinTargets for %s is not JSON: %s", system, e.msg));
    if (root.type != JSONType.object)
        return err!(PlanTarget[])(format("pinTargets for %s is not an object", system));

    PlanTarget[] entries;
    foreach (name, value; (() @trusted => root.object)())
    {
        const where = format("pinTargets.%s for %s", name, system);
        if (value.type != JSONType.object || "out" !in value || "drv" !in value)
            return err!(PlanTarget[])(where ~ " has no out and drv");
        const out_ = value["out"];
        const drv = value["drv"];
        if (out_.type != JSONType.string || !out_.str.startsWith("/nix/store/"))
            return err!(PlanTarget[])(where ~ " has no store path");
        string drvPath;
        if (drv.type == JSONType.string && drv.str.startsWith("/nix/store/"))
            drvPath = drv.str;
        else if (drv.type != JSONType.null_)
            return err!(PlanTarget[])(where ~ " has a drv that is not a store path");
        entries ~= PlanTarget(Target(name: name, system: system, outPath: out_.str), drvPath);
    }
    if (entries.length == 0)
        return err!(PlanTarget[])(format("pinTargets for %s is empty", system));
    entries.sort!((a, b) => a.target.name < b.target.name);
    return ok(entries);
}

@("pinBuild.parsePlanSet.derivationsAndSources")
@safe
unittest
{
    const parsed = parsePlanSet("x86_64-linux",
        `{"toolchain-dmd":{"out":"/nix/store/b-dmd","drv":"/nix/store/b-dmd.drv"},`
        ~ `"toolchain-input-dmd-src":{"out":"/nix/store/a-src","drv":null}}`);
    assert(parsed.hasValue);
    assert(parsed.value[0].target.name == "toolchain-dmd" && parsed.value[0].buildable);
    assert(parsed.value[1].target.outPath == "/nix/store/a-src" && !parsed.value[1].buildable,
        "a flake input's source has no derivation");

    assert(parsePlanSet("x86_64-linux", `{}`).hasError, "an empty set is not a set");
    assert(parsePlanSet("x86_64-linux", `{"a":"/nix/store/a"}`).hasError);
    assert(parsePlanSet("x86_64-linux", `{"a":{"out":"/nix/store/a"}}`).hasError);
    assert(parsePlanSet("x86_64-linux", `{"a":{"out":"rel","drv":null}}`).hasError);
    assert(parsePlanSet("x86_64-linux", `{"a":{"out":"/nix/store/a","drv":1}}`).hasError);
}

/// The recorded cost of building one entry for one system.
struct BuildCost
{
    uint minutes;
    string source; /// How the figure was obtained: a measurement, or an estimate and its basis.
}

/// The cost file `ci --write-pin-costs` writes: the budget a CI build may take,
/// and each pin's median recorded build from `refs/perf/data`,
/// keyed by pin name (`<name>-<system>`).
struct BuildCosts
{
    uint budgetMinutes;
    BuildCost[string] costs;
}

/**
The cost file. The budget must leave a margin below the job limit; every cost
must name its source, so an estimate is never mistaken for a measurement.
*/
Expected!(BuildCosts, string) parseBuildCosts(string json) @safe
{
    JSONValue root;
    try
        root = parseJSON(json);
    catch (JSONException e)
        return err!BuildCosts("the build costs are not JSON: " ~ e.msg);
    if (root.type != JSONType.object || "budgetMinutes" !in root || "costs" !in root)
        return err!BuildCosts("the build costs need budgetMinutes and costs");
    const budget = root["budgetMinutes"];
    if (budget.type != JSONType.integer || budget.integer <= 0 || budget.integer >= jobLimitMinutes)
        return err!BuildCosts(format("budgetMinutes must be between 1 and %d", jobLimitMinutes - 1));
    if (root["costs"].type != JSONType.object)
        return err!BuildCosts("costs is not an object");

    BuildCosts parsed;
    parsed.budgetMinutes = cast(uint) budget.integer;
    foreach (pin, entry; (() @trusted => root["costs"].object)())
    {
        if (entry.type != JSONType.object || "minutes" !in entry || "source" !in entry
            || entry["minutes"].type != JSONType.integer || entry["minutes"].integer <= 0
            || entry["source"].type != JSONType.string || entry["source"].str.length == 0)
            return err!BuildCosts(format("the cost of %s needs positive minutes and a source", pin));
        parsed.costs[pin] = BuildCost(cast(uint) entry["minutes"].integer, entry["source"].str);
    }
    return ok(parsed);
}

@("pinBuild.parseBuildCosts.strict")
@safe
unittest
{
    const parsed = parseBuildCosts(`{"budgetMinutes":300,"costs":`
        ~ `{"toolchain-llvm-spirv-vulkan-x86_64-linux":{"minutes":480,"source":"estimate"}}}`);
    assert(parsed.hasValue && parsed.value.budgetMinutes == 300);
    assert(parsed.value.costs["toolchain-llvm-spirv-vulkan-x86_64-linux"].minutes == 480);

    assert(parseBuildCosts(`{"budgetMinutes":360,"costs":{}}`).hasError, "no margin below the job limit");
    assert(parseBuildCosts(`{"costs":{}}`).hasError);
    assert(parseBuildCosts(`{"budgetMinutes":300,"costs":{"a":{"minutes":5}}}`).hasError,
        "a cost without a source");
    assert(parseBuildCosts(`{"budgetMinutes":300,"costs":{"a":{"minutes":0,"source":"x"}}}`).hasError);
}

/// Why an output is not built in CI.
enum Deferral : ubyte
{
    overBudget, /// Its own recorded cost exceeds the budget.
    needsOverBudget, /// Its closure needs a missing output that is over budget.
}

/// A missing output left to a developer host, and why.
struct Deferred
{
    Target target;
    Deferral reason;
    string detail; /// The cost and its source, or the over-budget output it needs.
}

/// The plan: what CI builds, what it defers, and the sources the mirror fetches.
struct BuildPlan
{
    PlanTarget[] build;
    Deferred[] deferred;
    Target[] sources;
}

/**
Plan the missing outputs. `needs(a, b)` answers whether `a`'s derivation
closure contains `b`'s derivation; the plan asks it only for pairs of the same
system, with `b` over budget.
*/
BuildPlan planBuilds(alias needs)(PlanTarget[] missing, in BuildCosts costs)
{
    bool overBudget(const PlanTarget entry)
    {
        auto cost = entry.target.pinName in costs.costs;
        return cost !is null && cost.minutes > costs.budgetMinutes;
    }

    BuildPlan plan;
    auto heavy = missing.filter!(entry => entry.buildable && overBudget(entry)).array;
    foreach (entry; missing)
    {
        if (!entry.buildable)
        {
            plan.sources ~= entry.target;
            continue;
        }
        if (overBudget(entry))
        {
            const cost = costs.costs[entry.target.pinName];
            plan.deferred ~= Deferred(entry.target, Deferral.overBudget,
                format("%d min, over the %d min budget (%s)", cost.minutes, costs.budgetMinutes, cost.source));
            continue;
        }
        auto blocker = heavy.filter!(h => h.target.system == entry.target.system && needs(entry, h));
        if (!blocker.empty)
        {
            plan.deferred ~= Deferred(entry.target, Deferral.needsOverBudget,
                "needs " ~ blocker.front.target.pinName);
            continue;
        }
        plan.build ~= entry;
    }
    return plan;
}

version (unittest) private PlanTarget planTarget(string name, string system, bool buildable = true)
    @safe pure nothrow =>
    PlanTarget(Target(name, system, "/nix/store/" ~ name), buildable ? "/nix/store/" ~ name ~ ".drv" : null);

@("pinBuild.planBuilds.costsDecide")
@safe
unittest
{
    auto costs = BuildCosts(300, [
        "toolchain-llvm-x86_64-linux": BuildCost(480, "estimate"),
        "toolchain-ldc-android-x86_64-linux": BuildCost(20, "measured"),
    ]);
    auto missing = [
        planTarget("toolchain-llvm", "x86_64-linux"),
        planTarget("toolchain-ldc", "x86_64-linux"),
        planTarget("toolchain-ldc", "aarch64-darwin"),
        planTarget("toolchain-ldc-android", "x86_64-linux"),
        planTarget("toolchain-input-llvm", "x86_64-linux", buildable: false),
    ];
    // LDC needs the LLVM; the Android wrapper and the Darwin LDC do not.
    static bool needs(const PlanTarget a, const PlanTarget b) =>
        a.target.name == "toolchain-ldc" && b.target.name == "toolchain-llvm";
    const plan = planBuilds!needs(missing, costs);

    assert(plan.build.map!(e => e.target.pinName).array
        == ["toolchain-ldc-aarch64-darwin", "toolchain-ldc-android-x86_64-linux"],
        "an unrecorded cost is attempted, and a fitting one is built");
    assert(plan.deferred.length == 2);
    assert(plan.deferred[0].target.pinName == "toolchain-llvm-x86_64-linux"
        && plan.deferred[0].reason == Deferral.overBudget);
    assert(plan.deferred[0].detail == "480 min, over the 300 min budget (estimate)");
    assert(plan.deferred[1].target.pinName == "toolchain-ldc-x86_64-linux"
        && plan.deferred[1].reason == Deferral.needsOverBudget
        && plan.deferred[1].detail == "needs toolchain-llvm-x86_64-linux",
        "a build that would rebuild an over-budget output is deferred with it");
    assert(plan.sources.map!(t => t.name).array == ["toolchain-input-llvm"]);
}

/// The hosted runner that builds `system`'s outputs, as `ci.yml`'s other jobs name it.
string runnerFor(string system) @safe pure nothrow
in (pinSystems.canFind(system))
{
    switch (system)
    {
        case "x86_64-linux":
            return "ubuntu-latest";
        case "aarch64-linux":
            return "ubuntu-24.04-arm";
        default:
            return "macos-latest";
    }
}

/**
The `pin-build` job's matrix: one entry per system with outputs to build, in
$(LREF pinSystems) order, holding its runner, its installables (space
separated) and its pin names. `{"include":[]}` when there is nothing to build.
*/
string buildMatrix(const BuildPlan plan) @safe
{
    JSONValue[] include;
    foreach (system; pinSystems)
    {
        auto mine = plan.build.filter!(e => e.target.system == system).array;
        if (mine.length == 0)
            continue;
        JSONValue entry = [
            "system": JSONValue(system),
            "runner": JSONValue(runnerFor(system)),
            "installables": JSONValue(mine.map!(e => e.target.installable).join(" ")),
            "pins": JSONValue(mine.map!(e => e.target.pinName).join(" ")),
        ];
        include ~= entry;
    }
    JSONValue matrix = ["include": JSONValue(include)];
    return matrix.toString;
}

@("pinBuild.buildMatrix.perSystem")
@safe
unittest
{
    BuildPlan plan;
    plan.build = [
        planTarget("toolchain-ldc", "aarch64-darwin"),
        planTarget("toolchain-dmd", "x86_64-linux"),
        planTarget("toolchain-ldc-android", "x86_64-linux"),
    ];
    const matrix = parseJSON(buildMatrix(plan));
    const include = (() @trusted => matrix["include"].array)();
    assert(include.length == 2);
    assert(include[0]["system"].str == "x86_64-linux" && include[0]["runner"].str == "ubuntu-latest");
    assert(include[0]["installables"].str == ".#legacyPackages.x86_64-linux.pinTargets.toolchain-dmd "
        ~ ".#legacyPackages.x86_64-linux.pinTargets.toolchain-ldc-android");
    assert(include[1]["runner"].str == "macos-latest");
    assert(include[1]["pins"].str == "toolchain-ldc-aarch64-darwin");

    assert(buildMatrix(BuildPlan.init) == `{"include":[]}`);
}

/// The command a developer host runs to build, push and pin a deferred output.
string localCommand(const Target target) @safe pure nothrow =>
    "dub run --single ci/toolchain-pin.d -b checked -- --system=" ~ target.system ~ " -- " ~ target.name;

@("pinBuild.localCommand.oneEntry")
@safe pure nothrow
unittest
{
    assert(localCommand(Target("toolchain-llvm-spirv-vulkan", "aarch64-darwin"))
        == "dub run --single ci/toolchain-pin.d -b checked -- --system=aarch64-darwin -- toolchain-llvm-spirv-vulkan");
}
