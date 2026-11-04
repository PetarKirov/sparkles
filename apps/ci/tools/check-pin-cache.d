/**
 * Standalone toolchain pin cache checker.
 * Evaluates the repo's pinTargets for all supported systems and verifies
 * that the toolchain outputs are present in Cachix via HTTP HEAD requests.
 */
module check_pin_cache;

import std.format : format;
import std.process : environment;
import std.stdio : stderr, stdout, writefln, writeln;
import std.string : strip;

import sparkles.base.expected : Expected, andThen, err, ok;
import sparkles.core_cli.process_utils : runCaptured;

import derivation_pin_cachix : allCached, checkCached, liveHead, uncachedLines;
import derivation_pin_set :
    Category, Selection, Target, cacheUri, expandPinSet, parsePinSet, pinSetEvalArgs,
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

private Expected!(void, string) checkTargets(Target[] targets, string cache) @system
{
    const uri = cacheUri(cache);
    const checks = checkCached!liveHead(targets, uri);
    if (allCached(checks))
    {
        writefln("All %d pin-set outputs are cached in %s.", checks.length, uri);
        return ok();
    }
    const lines = uncachedLines(checks);
    foreach (line; lines)
        writeln(line);
    stdout.flush();
    return err!void(format("%d of %d pin-set outputs are not cached in %s.",
        lines.length, checks.length, uri));
}

Expected!(void, string) checkToolchainCached(string cache) @system =>
    evaluatePinSet(findRepoRoot())
        .andThen!((Target[] set) => selectTargets(set, Selection(categories: Category.toolchain)))
        .andThen!((Target[] toolchain) => checkTargets(toolchain, cache));

int main()
{
    const cache = environment.get("CACHIX_CACHE", "sparkles");
    auto checked = checkToolchainCached(cache);
    if (!checked.hasError)
        return 0;
    stderr.writeln(checked.error);
    return 1;
}
