/**
 * Standalone toolchain pin cache checker (TC23's gate, the `pin-cache` job).
 * Evaluates the repo's pinTargets for all supported systems and verifies,
 * with HTTP HEAD requests, that every toolchain output is served by one of
 * Sparkles' binary caches: Cachix, where the pins live (TC24), or the R2
 * bucket behind it, where the job mirrors the pin set
 * (ci/push-pin-set-r2.sh) so that what Cachix evicts is still there.
 *
 * Environment:
 *   CACHIX_CACHE   Cachix cache name (default: sparkles).
 *   R2_CACHE_URL   The R2 cache's URL (default:
 *                  https://cache.sparkles.petar-kirov.dev); empty to ask
 *                  Cachix alone.
 */
module check_pin_cache;

import std.algorithm.iteration : filter;
import std.array : array, join;
import std.format : format;
import std.process : environment;
import std.stdio : stderr, stdout, writefln, writeln;
import std.string : strip;

import sparkles.base.expected : Expected, andThen, err, ok;
import sparkles.core_cli.process_utils : runCaptured;

import derivation_pin_cachix : allCached, checkCachedAny, liveHead, uncachedLines;
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

int main()
{
    auto uris = [
        cacheUri(environment.get("CACHIX_CACHE", "sparkles")),
        environment.get("R2_CACHE_URL", "https://cache.sparkles.petar-kirov.dev"),
    ].filter!(uri => uri.length > 0).array;
    auto checked = checkToolchainCached(uris);
    if (!checked.hasError)
        return 0;
    stderr.writeln(checked.error);
    return 1;
}
