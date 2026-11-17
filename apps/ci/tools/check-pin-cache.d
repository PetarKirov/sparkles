/**
 * Standalone toolchain pin cache checker (TC23's gate, the `pin-cache` job),
 * and the planner of the `pin-build` matrix that runs before it.
 *
 * The R2 cache is the cache of record: CI pushes everything it builds there,
 * and R2 does not evict. Cachix is best effort: it holds the pins (TC24) and
 * evicts the rest, so an output it serves is only a cheaper source to copy
 * from.
 *
 * Without `--plan` it evaluates the repo's pinTargets for all supported
 * systems and verifies, with HTTP HEAD requests, that R2 serves every
 * toolchain output.
 *
 * With `--plan` it asks the same question and plans what to do about each
 * output R2 lacks (`derivation_pin_build`): one Cachix serves is left to the
 * mirror step (ci/push-pin-set-r2.sh), which copies it; of the rest, those
 * whose recorded build cost fits a CI job become the `pin-build` matrix, one
 * entry per system, and each one over budget is reported with the command
 * that builds it on a developer host. The plan never fails the run; the gate
 * does.
 *
 * Environment:
 *   CACHIX_CACHE   Cachix cache name (default: sparkles).
 *   R2_CACHE_URL   The R2 cache's URL (default:
 *                  https://cache.sparkles.petar-kirov.dev).
 */
module check_pin_cache;

import std.algorithm.iteration : map;
import std.array : array, join;
import std.file : append, readText;
import std.format : format;
import std.process : environment;
import std.stdio : stderr, stdout, writefln, writeln;
import std.string : strip;

import sparkles.base.expected : Expected, andThen, err, ok;
import sparkles.core_cli.process_utils : runCaptured;

import derivation_pin_build : PlanTarget, buildMatrix, localCommand,
    parseBuildCosts, parsePlanSet, pinSetPlanEvalArgs, planBuilds;
import derivation_pin_cachix : Presence, allCached, checkCachedAny, liveHead, uncachedLines;
import derivation_pin_set :
    Category, Selection, Target, cacheUri, categoriesOf, expandPinSet, parsePinSet, pinSetEvalArgs,
    pinSystems, selectTargets;

string findRepoRoot() @safe
{
    const root = runCaptured(["git", "rev-parse", "--show-toplevel"]);
    return root.succeeded && root.stdout.length > 0 ? root.stdout.strip : ".";
}

private Expected!(Target[], string) evaluatePinSet(string repoRoot) @safe
{
    Target[][] perSystem;
    foreach (system; pinSystems)
    {
        const evaluated = runCaptured(pinSetEvalArgs(system), workDir: repoRoot);
        if (!evaluated.succeeded)
            return err!(Target[])(format("evaluating pinTargets for %s failed: %s",
                system, evaluated.stderr.strip));
        auto parsed = parsePinSet(system, evaluated.stdout);
        if (parsed.hasError)
            return err!(Target[])(parsed.error);
        perSystem ~= parsed.value;
    }
    return ok(expandPinSet(perSystem));
}

private Expected!(void, string) checkTargets(Target[] targets, string[] uris) @system
{
    const checks = checkCachedAny!liveHead(targets, uris);
    const where = uris.join(" or ");
    if (allCached(checks))
    {
        writefln("All %d pin-set outputs are cached in %s.", checks.length, where);
        return ok();
    }
    const lines = uncachedLines(checks);
    foreach (line; lines)
        writeln(line);
    stdout.flush();
    return err!void(format("%d of %d pin-set outputs are not cached in %s.",
        lines.length, checks.length, where));
}

Expected!(void, string) checkToolchainCached(string[] uris) @system =>
    evaluatePinSet(findRepoRoot())
        .andThen!((Target[] set) => selectTargets(set, Selection(categories: Category.toolchain)))
        .andThen!((Target[] toolchain) => checkTargets(toolchain, uris));

/// Every system's toolchain entries, with their derivations.
private Expected!(PlanTarget[], string) evaluatePlanSet(string repoRoot) @safe
{
    PlanTarget[] set;
    foreach (system; pinSystems)
    {
        const evaluated = runCaptured(pinSetPlanEvalArgs(system), workDir: repoRoot);
        if (!evaluated.succeeded)
            return err!(PlanTarget[])(format("evaluating pinTargets for %s failed: %s",
                system, evaluated.stderr.strip));
        auto parsed = parsePlanSet(system, evaluated.stdout);
        if (parsed.hasError)
            return err!(PlanTarget[])(parsed.error);
        foreach (entry; parsed.value)
            if (categoriesOf(entry.target.name) & Category.toolchain)
                set ~= entry;
    }
    return ok(set);
}

/// Whether `a`'s derivation closure holds `b`'s derivation. Evaluation wrote
/// both `.drv` files to the local store, so the query needs no builder.
private bool closureNeeds(const PlanTarget a, const PlanTarget b) @safe
{
    import std.algorithm.searching : canFind;
    import std.string : lineSplitter;

    const requisites = runCaptured(["nix-store", "--query", "--requisites", a.drvPath]);
    // An unanswered query defers nothing: the build is attempted, and its job
    // reports what it could not build.
    return requisites.succeeded && requisites.stdout.lineSplitter.canFind(b.drvPath);
}

private Expected!(void, string) plan(string costsPath, string githubOutput, string r2, string cachix) @system
{
    const repoRoot = findRepoRoot();
    // No cost file: no recorded cost, so every missing output is attempted.
    string costsText = `{"budgetMinutes":300,"costs":{}}`;
    if (costsPath.length)
    {
        try
            costsText = readText(costsPath);
        catch (Exception e)
            return err!void(format("cannot read the build costs %s: %s", costsPath, e.msg));
    }
    auto costs = parseBuildCosts(costsText);
    if (costs.hasError)
        return err!void(costs.error);
    auto set = evaluatePlanSet(repoRoot);
    if (set.hasError)
        return err!void(set.error);

    // R2 decides what is missing; an output only Cachix serves is copied, not built.
    auto inR2 = checkCachedAny!liveHead(set.value.map!(entry => entry.target).array, [r2]);
    PlanTarget[] notInR2;
    foreach (i, check; inR2)
        if (check.presence != Presence.cached)
            notInR2 ~= set.value[i];
    auto inCachix = cachix.length
        ? checkCachedAny!liveHead(notInR2.map!(entry => entry.target).array, [cachix])
        : null;
    PlanTarget[] missing;
    Target[] fromCachix;
    foreach (i, entry; notInR2)
        if (inCachix.length && inCachix[i].presence == Presence.cached)
            fromCachix ~= entry.target;
        else
            missing ~= entry;
    const built = planBuilds!closureNeeds(missing, costs.value);

    writefln("%d of %d toolchain outputs are in R2; %d to copy from Cachix, %d to build in CI, %d deferred, "
        ~ "%d sources to mirror.",
        inR2.length - notInR2.length, inR2.length, fromCachix.length, built.build.length,
        built.deferred.length, built.sources.length);
    foreach (target; fromCachix)
        writefln("copy     %s  %s", target.pinName, target.outPath);
    foreach (entry; built.build)
        writefln("build    %s  %s", entry.target.pinName, entry.target.outPath);
    foreach (entry; built.deferred)
        writefln("::error::%s is not built in CI: %s. Build and push it from a host of its system: %s",
            entry.target.pinName, entry.detail, localCommand(entry.target));
    foreach (target; built.sources)
        writefln("mirror   %s  %s", target.pinName, target.outPath);
    stdout.flush();

    const matrix = buildMatrix(built);
    const lines = format("matrix=%s\nany=%s\n", matrix, built.build.length > 0 ? "true" : "false");
    if (githubOutput.length == 0)
    {
        stdout.write(lines);
        return ok();
    }
    try
        append(githubOutput, lines);
    catch (Exception e)
        return err!void(format("cannot write %s: %s", githubOutput, e.msg));
    return ok();
}

// The options are read by hand: core-cli's parser brings `sparkles:wired` and
// its registry dependencies, and this checker's closure is kept to `base`.
private enum usage = `Usage: toolchain-pin-check [--plan] [--costs <file>] [--github-output <file>]

Check that the R2 cache serves every pinned toolchain output (TC23),
or plan the CI builds of those that are not.

    --plan                  Plan the pin-build matrix instead of checking:
                            list the missing outputs, and write matrix and
                            any as job outputs.
    --costs <file>          The recorded build costs
                            (ci cache pin-costs writes it; default: none).
    --github-output <file>  Append the plan's outputs to this file (the job's
                            $GITHUB_OUTPUT) rather than printing them.
    -h, --help              Show this help.
`;

int main(string[] args)
{
    bool planMode;
    string costs;
    string githubOutput;
    for (size_t i = 1; i < args.length; ++i)
    {
        const arg = args[i];
        if (arg == "-h" || arg == "--help")
        {
            stdout.write(usage);
            return 0;
        }
        if (arg == "--plan")
            planMode = true;
        else if ((arg == "--costs" || arg == "--github-output") && i + 1 < args.length)
            (arg == "--costs" ? costs : githubOutput) = args[++i];
        else
        {
            stderr.writeln("toolchain-pin-check: unexpected argument '", arg, "'\n\n", usage);
            return 2;
        }
    }

    const r2 = environment.get("R2_CACHE_URL", "https://cache.sparkles.petar-kirov.dev");
    if (r2.length == 0)
    {
        stderr.writeln("toolchain-pin-check: R2_CACHE_URL is empty, and R2 is the cache of record");
        return 2;
    }
    const cachixName = environment.get("CACHIX_CACHE", "sparkles");
    const cachix = cachixName.length ? cacheUri(cachixName) : null;
    auto done = planMode ? plan(costs, githubOutput, r2, cachix) : checkToolchainCached([r2]);
    if (!done.hasError)
        return 0;
    stderr.writeln(done.error);
    return 1;
}
