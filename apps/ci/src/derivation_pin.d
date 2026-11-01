/**
 * Push and pin Sparkles' pin set to Cachix (TC24), delete the cache's pins
 * outside it, and check that the set's outputs are cached (TC23).
 *
 * The set is the flake output `legacyPackages.<system>.pinTargets`
 * (`nix/pin-targets.nix`) for every system of `derivation_pin_set.pinSystems`;
 * each entry is pinned as `<name>-<system>` from
 * `.#legacyPackages.<system>.pinTargets.<name>`. The selectors filter it by
 * name: `--toolchains` keeps the `toolchain-` prefix, `--android` the
 * `-android` suffix, `--libs` the rest; positional names and `--system`
 * narrow further.
 *
 * Target choice, storage totals, the deletion set and the summary table are
 * pure values. Nix and Cachix run as supervised children of bounded worker
 * fibers; one reporter fiber owns the live checklist. Scope exit joins all work.
 *
 * Usage:
 *   dub run --single ci/toolchain-pin.d -- [--dry-run|-n] [-j N]
 *   dub run --single ci/toolchain-pin.d -- [--dry-run|-n] [--toolchains|-t] [--libs|-l] [--android|-a]
 *   dub run --single ci/toolchain-pin.d -- [--dry-run|-n] [--system <system>]... [<name>...]
 *   dub run --single ci/toolchain-pin.d -- --check [--system <system>]... [<name>...]
 */
module derivation_pin;

version (Posix):

import core.time : msecs;
import core.lifetime : move;

import std.algorithm.comparison : max, min;
import std.algorithm.iteration : filter, joiner, map, sum;
import std.algorithm.searching : all, any, maxElement, startsWith;
import std.array : array;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.range : enumerate;
import std.stdio : stderr, stdout, write, writefln, writeln;
import std.string : indexOf, lineSplitter, strip;

import sparkles.base.expected : Expected, andThen, err, ok;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.term_caps : detectTermCaps;
import sparkles.base.text.width : Align;
import sparkles.base.text.writers : formatted, writeBytes;
import sparkles.core_cli.args : Argument, Command, Option;
import sparkles.core_cli.process_utils : isInPath, runCaptured;
import sparkles.event_horizon.cause : Interrupt, InterruptKind;
import sparkles.event_horizon.blocking_pool : BlockingPool;
import sparkles.event_horizon.sched : Sched, SchedOptions;
import sparkles.event_horizon.io : sleep, read;
import sparkles.event_horizon.sys.descriptor : BorrowedFd;
import sparkles.event_horizon.scope_ : checkCancellation, withScope;
import sparkles.ui.components.live : stdoutLiveRegion;
import sparkles.ui.components.table :
    Cell, TableProps, VAlign, drawTable, drawTableChunks;
import sparkles.ui.components.tasklist : TaskReporter;
import sparkles.ui.components.theme : makeTheme;

import derivation_pin_cachix : allCached, checkCached, liveDelete, liveGet, liveHead,
    prunePins, uncachedLines;
import derivation_pin_process : Captured, SupervisedCommands;
import derivation_pin_set : Category, Selection, Target, cacheUri, capReport,
    expandPinSet, parsePinSet, pinSetEvalArgs, pinSystems, selectTargets;
import derivation_pin_signals : ShutdownSignals;

/**
CLI arguments. `run` resolves the environment, evaluates the pin set, then
either checks it or drives every selected pin and deletes the pins outside the
set. It returns a message without an `Error:` prefix — `runCli` adds that prefix.
*/
@(Command("toolchain-pin",
    shortDescription: "Push and pin Sparkles' pin set (nix/pin-targets.nix) to Cachix, or check that it is cached.",
))
struct ToolchainPin
{
    @(Option("dry-run|n", description: "Evaluate store paths, list the pins a run would delete, and display "
        ~ "the summary without pushing, pinning or deleting."))
    bool dryRun;

    @(Option("check", description: "Exit non-zero unless the cache serves every selected output "
        ~ "(a narinfo query per out path; needs no token, builds nothing)."))
    bool check;

    @(Option("jobs|j", description: "Number of concurrent workers for evaluation and cache queries (default: 4)."))
    int jobs = 4;

    @(Option("toolchains|t", description: "Select the entries named toolchain-*."))
    bool toolchains;

    @(Option("libs|l", description: "Select the entries named neither toolchain-* nor *-android."))
    bool libs;

    @(Option("android|a", description: "Select the entries named *-android."))
    bool android;

    @(Option("system", description: "Select only this system's entries (repeatable)."))
    string[] systems;

    @(Option("cache", description: "Cachix cache name (default: from $CACHIX_CACHE or 'sparkles')."))
    string cache;

    @(Option("token", description: "Cachix auth token (default: from $CACHIX_AUTH_TOKEN)."))
    string token;

    @(Option("revisions", description: "Revisions to keep per pin (default: from $CI_PIN_REVISIONS or 1)."))
    int revisions = 1;

    @(Argument("names", description: "Select only these pin-set entries, by name (toolchain-dmd).", optional: true))
    string[] names;

    /// Resolve, pin, and render. Parse and usage errors stay with `runCli`.
    Expected!(void, string) run() @system
    {
        import std.process : environment;

        const selection = Selection(
            categories: cast(ubyte) ((toolchains ? Category.toolchain : 0)
                | (libs ? Category.library : 0)
                | (android ? Category.android : 0)),
            names: names,
            systems: systems,
        );
        return resolveRun(
            cli: this,
            envCache: environment.get("CACHIX_CACHE"),
            envToken: environment.get("CACHIX_AUTH_TOKEN"),
            envDry: environment.get("CI_DRY_RUN", "0"),
            envRevisions: environment.get("CI_PIN_REVISIONS"),
        ).andThen!((RunPlan plan) {
            const repoRoot = findRepoRoot();
            return evaluatePinSet(repoRoot).andThen!((Target[] set) =>
                selectTargets(set, selection).andThen!((Target[] chosen) {
                    if (check)
                        return checkTargets(chosen, plan.cache);
                    if (plan.announcedDryRun)
                        stderr.writeln("NOTICE: CACHIX_AUTH_TOKEN is unset; running in dry-run summary mode.");
                    auto pinned = drive(chosen, plan, repoRoot);
                    renderSummary(pinned.reports, plan, pinned.interactive);
                    return announce(plan, pinned.reports)
                        .andThen!(() => prune(set, plan));
                }));
        });
    }
}

/**
 * The whole pin set, evaluated once per system in the repository at
 * `repoRoot`. Any system that fails to evaluate fails the run: a partial set
 * would mark the missing system's pins for deletion.
 */
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

/// One store path and its nar size. A path with an unknown size contributes 0.
struct PathSize
{
    string path;
    ulong narSize;
}

/**
 * Closure storage that is not already on cache.nixos.org.
 *
 * `known` is false when the measurement could not be made. A known, non-partial
 * impact with empty `paths` is a real zero (the closure is entirely upstream).
 * Partial measurements may omit paths/sizes or include unclassified paths.
 */
struct StorageImpact
{
    bool known;
    PathSize[] paths;
    bool partial; /// True when closure, size, or upstream evidence is incomplete.

    /// Sum of recorded nar sizes.
    ulong bytes() const @safe pure => paths.map!(entry => entry.narSize).sum;
}

/// One pin a worker should resolve. The run plan is shared, not copied per job.
struct JobRequest
{
    size_t id;
    string name;
    string system;
    string installable;
}

/// What one attempt produced. `error` is empty when it finished.
struct JobReport
{
    size_t id;
    string name;
    string system;
    string installable;
    string storePath;
    StorageImpact impact;
    string error;

    bool succeeded() const @safe pure nothrow @nogc => error.length == 0;
    bool sizeKnown() const @safe pure nothrow @nogc => impact.known;
    bool sizePartial() const @safe pure nothrow @nogc => impact.partial;
    ulong bytes() const @safe pure => impact.bytes;
}

/// Resolved CLI and environment. Unusable input is an error, not a field.
struct RunPlan
{
    string cache;
    bool dryRun;
    bool announcedDryRun;
    int revisions;
    int jobs;
    string token;
}

/// One pin name and the system rows that belong to it, in input order.
struct PinGroup
{
    string name;
    JobReport[] jobs;
}

private enum nixosCache = "https://cache.nixos.org";

private enum remoteCaches = [
    "https://sparkles.cachix.org",
    "https://dlang-community.cachix.org",
];

/// Last `/nix/store/…` line in `output`, or the stripped text when there is none.
string extractStorePath(string output) @safe pure
{
    const matches = output.lineSplitter
        .map!strip
        .filter!(line => line.startsWith("/nix/store/"))
        .array;
    if (matches.length > 0)
        return matches[$ - 1];
    return output.strip;
}

@("extractStorePath.lastLine")
@safe pure
unittest
{
    assert(extractStorePath("warning: slow\n/nix/store/abc\n") == "/nix/store/abc");
    assert(extractStorePath("  /nix/store/a\n/nix/store/b\n") == "/nix/store/b");
    assert(extractStorePath("no path\n") == "no path");
}

/**
 * Combine the parsed flags with the environment strings they fall back to.
 *
 * `--cache` wins over `$CACHIX_CACHE`, which wins over `sparkles`. Dry-run is
 * on when the flag is set, when `$CI_DRY_RUN` is `1`, or when no auth token
 * is available. The last case sets `announcedDryRun`. `--revisions` left at
 * its default of 1 takes `$CI_PIN_REVISIONS` when that is a positive integer.
 * `jobs` is at least 1.
 */
Expected!(RunPlan, string) resolveRun(
    ToolchainPin cli,
    string envCache,
    string envToken,
    string envDry,
    string envRevisions,
) @safe pure
{
    const cache = cli.cache.length ? cli.cache : (envCache.length ? envCache : "sparkles");
    const token = cli.token.length ? cli.token : envToken;
    auto dryRun = cli.dryRun || envDry == "1";
    auto announced = false;
    if (token.length == 0 && !dryRun)
    {
        announced = true;
        dryRun = true;
    }

    const jobs = max(1, cli.jobs);
    RunPlan plan(int revisions) => RunPlan(cache, dryRun, announced, revisions, jobs, token);
    if (cli.revisions < 1)
        return err!(RunPlan)("--revisions must be a positive integer.");
    if (cli.revisions != 1 || envRevisions.length == 0)
        return ok(plan(cli.revisions));

    import std.conv : ConvException, to;

    try
    {
        const count = envRevisions.to!int;
        if (count < 1)
            return err!(RunPlan)("CI_PIN_REVISIONS must be a positive integer, not '" ~ envRevisions ~ "'.");
        return ok(plan(count));
    }
    catch (ConvException)
        return err!(RunPlan)("CI_PIN_REVISIONS must be a positive integer, not '" ~ envRevisions ~ "'.");
}

@("resolveRun.fallbacks")
@safe
unittest
{
    const dry = resolveRun(
        cli: ToolchainPin.init, envCache: null, envToken: null, envDry: "1", envRevisions: null);
    assert(dry.hasValue);
    assert(dry.value.dryRun);
    assert(!dry.value.announcedDryRun);
    assert(dry.value.cache == "sparkles");
    assert(dry.value.revisions == 1);
    assert(dry.value.jobs == 4);

    const forced = resolveRun(
        cli: ToolchainPin.init, envCache: "from-env", envToken: null, envDry: "0", envRevisions: null);
    assert(forced.value.dryRun);
    assert(forced.value.announcedDryRun);
    assert(forced.value.cache == "from-env");

    ToolchainPin cli;
    cli.cache = "other";
    cli.revisions = 5;
    cli.token = "t";
    cli.jobs = 0;
    const explicit = resolveRun(
        cli: cli, envCache: "sparkles", envToken: null, envDry: "0", envRevisions: "9");
    assert(explicit.value.cache == "other");
    assert(explicit.value.revisions == 5);
    assert(!explicit.value.dryRun);
    assert(explicit.value.jobs == 1);

    const fromEnv = resolveRun(
        cli: ToolchainPin.init, envCache: null, envToken: "tok", envDry: "0", envRevisions: "4");
    assert(fromEnv.value.revisions == 4);
    assert(!fromEnv.value.dryRun);
    assert(fromEnv.hasValue);

    const bad = resolveRun(
        cli: ToolchainPin.init, envCache: null, envToken: "tok", envDry: "0", envRevisions: "nope");
    assert(bad.hasError);
    assert(!bad.error.startsWith("Error:"));
    cli.revisions = 0;
    assert(resolveRun(cli: cli, envCache: null, envToken: "tok", envDry: "0", envRevisions: null).hasError);
    cli.revisions = 5;
    assert(resolveRun(
        cli: cli, envCache: null, envToken: "env-token", envDry: "0", envRevisions: null,
    ).value.token == "t");
}

/// Group reports by pin name. First-seen name order; jobs keep input order.
PinGroup[] groupByName(JobReport[] jobs) @safe pure
out (groups; groups.map!(group => group.jobs.length).sum == jobs.length)
{
    PinGroup[] groups;
    size_t[string] indexOf;
    foreach (job; jobs)
    {
        if (auto found = job.name in indexOf)
            groups[*found].jobs ~= job;
        else
        {
            indexOf[job.name] = groups.length;
            groups ~= PinGroup(job.name, [job]);
        }
    }
    return groups;
}

private JobReport sampleReport(string name, string system, string storePath, bool known, ulong bytes_) @safe pure
{
    PathSize[] paths;
    if (known)
        paths = [PathSize(path: storePath, narSize: bytes_)];
    return JobReport(0, name, system, name, storePath, StorageImpact(known, paths));
}

@("groupByName.preservesFirstSeen")
@safe pure
unittest
{
    const groups = groupByName([
        sampleReport("b", "linux", "/nix/store/b1", true, 10),
        sampleReport("a", "linux", "/nix/store/a", true, 4),
        sampleReport("b", "darwin", "/nix/store/b2", true, 12),
    ]);
    assert(groups.map!(group => group.name).array == ["b", "a"]);
    assert(groups[0].jobs.map!(job => job.system).array == ["linux", "darwin"]);
    assert(groups[1].jobs.length == 1);
}

/// Nar sizes keyed by path. A repeated path keeps the last recorded size.
ulong[string] uniqueNarSizes(JobReport[] reports) @safe
{
    ulong[string] sizes;
    foreach (report; reports.filter!(item => item.sizeKnown))
    {
        foreach (entry; report.impact.paths)
            sizes[entry.path] = entry.narSize;
    }
    return sizes;
}

/// Sum of $(LREF uniqueNarSizes).
ulong totalUniqueBytes(JobReport[] reports) @safe =>
    uniqueNarSizes(reports).byValue.sum;

@("uniqueNarSizes.dedup")
@safe
unittest
{
    auto reports = [
        JobReport(0, "n", "s", "i", "/p", StorageImpact(true, [
            PathSize("/nix/store/a", 3), PathSize("/nix/store/b", 5),
        ])),
        JobReport(1, "n", "t", "i", "/q", StorageImpact(true, [
            PathSize("/nix/store/b", 5), PathSize("/nix/store/c", 7),
        ])),
        JobReport(2, "m", "s", "i", null, StorageImpact.init, "evaluation failed: no"),
    ];
    const sizes = uniqueNarSizes(reports);
    assert(sizes.length == 3);
    assert(sizes["/nix/store/a"] == 3);
    assert(sizes["/nix/store/b"] == 5);
    assert(totalUniqueBytes(reports) == 15);
}

string sizeCell(const JobReport report) @safe
{
    if (!report.sizeKnown)
        return "-";
    return format("%s%s", formatted!writeBytes(report.bytes), report.sizePartial ? "*" : "");
}

string pathCell(const JobReport report) @safe =>
    report.storePath.length ? report.storePath : "(eval failed)";

string completionDetail(const JobReport report, bool dryRun) @safe
{
    if (report.sizeKnown)
    {
        return format("%s%s  [%s]",
            formatted!writeBytes(report.bytes),
            report.sizePartial ? " (partial)" : "",
            report.storePath);
    }
    if (dryRun)
        return format("(size unavailable)  [%s]", report.storePath);
    return format("[%s]", report.storePath);
}

@("completionDetail.wording")
@safe
unittest
{
    const known = sampleReport("n", "s", "/nix/store/p", true, 1024);
    assert(completionDetail(known, true) == "1.0KiB  [/nix/store/p]");
    assert(sizeCell(known) == "1.0KiB");
    const missing = JobReport(0, "n", "s", "i", "/nix/store/p");
    assert(completionDetail(missing, true) == "(size unavailable)  [/nix/store/p]");
    assert(completionDetail(missing, false) == "[/nix/store/p]");
    assert(sizeCell(missing) == "-");
    assert(pathCell(JobReport.init) == "(eval failed)");
}

private Cell[] headerRow() @safe pure => [
    Cell("PIN NAME"), Cell("SYSTEM"), Cell("SIZE (CACHE)"), Cell("STORE PATH"),
];

private Cell[] rowOf(PinGroup group, size_t index, JobReport job) @safe
{
    if (index == 0)
    {
        return [
            Cell(group.name, rowSpan: group.jobs.length, valign: VAlign.middle),
            Cell(job.system),
            Cell(sizeCell(job)),
            Cell(pathCell(job)),
        ];
    }
    return [Cell(job.system), Cell(sizeCell(job)), Cell(pathCell(job))];
}

private Cell[][] rowsFor(PinGroup group) @safe =>
    group.jobs.enumerate.map!(item => rowOf(group, item.index, item.value)).array;

/// Header plus one body row per report. The first row of a pin spans its systems.
Cell[][] summaryRows(PinGroup[] groups) @safe =>
    [headerRow()] ~ groups.map!rowsFor.joiner.array;

@("summaryRows.rowSpan")
@safe
unittest
{
    auto groups = groupByName([
        sampleReport("b", "linux", "/nix/store/b1", true, 1024),
        sampleReport("a", "linux", null, false, 0),
        sampleReport("b", "darwin", "/nix/store/b2", true, 2048),
    ]);
    const rows = summaryRows(groups);
    assert(rows.length == 4);
    assert(rows[0][0].content == "PIN NAME");
    assert(rows[1].length == 4);
    assert(rows[1][0].content == "b");
    assert(rows[1][0].rowSpan == 2);
    assert(rows[1][0].valign == VAlign.middle);
    assert(rows[2].length == 3);
    assert(rows[2][0].content == "darwin");
    assert(rows[3].length == 4);
    assert(rows[3][0].content == "a");
    assert(rows[3][2].content == "-");
    assert(rows[3][3].content == "(eval failed)");
}

/// True when `root` is an object that contains `path` with a non-null value.
bool hasEntry(JSONValue root, string path) @safe
{
    return root.type == JSONType.object && (path in root) !is null && !root[path].isNull;
}

/// `narSize` of a path-info object, or 0 when the field is absent.
ulong narSize(JSONValue obj) @safe
{
    import std.exception : enforce;

    enforce(obj.type == JSONType.object, "path-info entry must be an object");
    if ("narSize" !in obj)
        return 0;
    const size = obj["narSize"];
    if (size.type == JSONType.uinteger)
        return size.uinteger;
    enforce(size.type == JSONType.integer && size.integer >= 0,
        "narSize must be a non-negative integer");
    return cast(ulong) size.integer;
}

/// Non-empty stripped lines.
string[] nonEmptyLines(string text) @safe pure
{
    return text.lineSplitter
        .map!strip
        .filter!(line => line.length > 0)
        .array;
}

struct CachixCommands
{
    string[] push;
    string[] pin;
}

/// Argv for `cachix push` and `cachix pin`. Without a `cachix` binary the
/// commands go through `nix run nixpkgs#cachix`.
CachixCommands cachixCommands(
    bool haveCachix,
    string cache,
    string pinName,
    string path,
    int revisions,
    string repoRoot,
) @safe pure
in (path.length > 0)
out (cmds; cmds.push.length > 0 && cmds.pin.length > 0)
{
    const rev = format("%d", revisions);
    if (haveCachix)
    {
        return CachixCommands(
            ["cachix", "push", cache, path],
            ["cachix", "pin", cache, pinName, path, "--keep-revisions", rev],
        );
    }
    string[] prefix = [
        "nix", "--extra-experimental-features", "nix-command flakes",
        "run", "--inputs-from", repoRoot, "nixpkgs#cachix", "--",
    ];
    return CachixCommands(
        prefix ~ ["push", cache, path],
        prefix ~ ["pin", cache, pinName, path, "--keep-revisions", rev],
    );
}

@("cachixCommands.argv")
@safe pure
unittest
{
    const direct = cachixCommands(true, "sparkles", "pin-sys", "/nix/store/abc", 3, "/repo");
    assert(direct.push == ["cachix", "push", "sparkles", "/nix/store/abc"]);
    assert(direct.pin[$ - 2 .. $] == ["--keep-revisions", "3"]);

    const viaNix = cachixCommands(
        false, "sparkles", "skia-sparkles-x86_64-linux", "/nix/store/abc", 3, "/repo");
    assert(viaNix.push == [
        "nix", "--extra-experimental-features", "nix-command flakes",
        "run", "--inputs-from", "/repo", "nixpkgs#cachix", "--",
        "push", "sparkles", "/nix/store/abc",
    ]);
    assert(viaNix.pin == [
        "nix", "--extra-experimental-features", "nix-command flakes",
        "run", "--inputs-from", "/repo", "nixpkgs#cachix", "--",
        "pin", "sparkles", "skia-sparkles-x86_64-linux", "/nix/store/abc",
        "--keep-revisions", "3",
    ]);
}

private string findRepoRoot() @safe
{
    const res = runCaptured(["git", "rev-parse", "--show-toplevel"]);
    if (res.succeeded && res.stdout.length > 0)
        return res.stdout.strip;
    return ".";
}

private string[] nixEvalArgs(string repoRoot, string installable) @safe pure => [
    "nix", "eval", "--raw", "--inputs-from", repoRoot, installable,
];

private string[] nixBuildArgs(string repoRoot, string installable) @safe pure => [
    "nix", "build", "--no-link", "--print-out-paths", "--inputs-from", repoRoot, installable,
];

private JobReport finished(
    JobRequest req,
    string storePath = null,
    StorageImpact impact = StorageImpact.init,
    string error = null,
) @safe pure => JobReport(req.id, req.name, req.system, req.installable, storePath, impact, error);

private StorageImpact measureLocal(Commands)(ref Commands commands, string path)
{
    const closureRes = commands.run(["nix-store", "-qR", path]);
    if (!closureRes.ok)
        return StorageImpact.init;
    const closure = nonEmptyLines(closureRes.stdout);
    if (closure.length == 0)
        return StorageImpact.init;

    const localRes = commands.run(["nix", "path-info", "--json"] ~ closure);
    if (!localRes.ok)
        return StorageImpact.init;

    try
    {
        const local = parseJSON(localRes.stdout);
        const nixosRes = commands.run(
            ["nix", "path-info", "--store", nixosCache, "--json"] ~ closure);
        auto haveNixos = false;
        JSONValue nixos;
        if (nixosRes.stdout.length > 0)
        {
            try
            {
                nixos = parseJSON(nixosRes.stdout);
                haveNixos = nixos.type == JSONType.object;
            }
            catch (Exception)
            {
            }
        }
        auto impact = StorageImpact(true);
        foreach (entry; closure)
        {
            if (haveNixos && hasEntry(nixos, entry))
                continue;
            // Explicit null is a confirmed miss even when nix exits non-zero
            // for a mixed present/missing query. Omitted keys are not evidence.
            if (!haveNixos || entry !in nixos)
                impact.partial = true;
            if (!hasEntry(local, entry))
            {
                impact.partial = true;
                continue;
            }
            try
            {
                if ("narSize" !in local[entry])
                    impact.partial = true;
                impact.paths ~= PathSize(entry, narSize(local[entry]));
            }
            catch (Exception)
                impact.partial = true;
        }
        return impact;
    }
    catch (Exception)
    {
        return StorageImpact.init;
    }
}

private string[] referencePaths(JSONValue info) @safe
{
    import std.exception : enforce;

    enforce(info.type == JSONType.object, "path-info entry must be an object");
    if ("references" !in info)
        throw new Exception("path-info references missing");
    enforce(info["references"].type == JSONType.array, "references must be an array");
    // Validate the external type before accessing Phobos' system accessor.
    const items = () @trusted { return info["references"].array; }();
    return items.map!(item => item.str).array;
}

/// Transitive remote closure traversal. A visited set handles shared/self refs.
private StorageImpact measureOneStore(Commands)(ref Commands commands, string path, string store)
{
    auto impact = StorageImpact(true);
    string[] pending = [path];
    bool[string] visited;
    for (size_t next; next < pending.length; ++next)
    {
        if (commands.cancelled)
            return StorageImpact.init;
        const current = pending[next];
        if (current in visited)
            continue;
        visited[current] = true;
        const info = commands.run(["nix", "path-info", "--store", store, "--json", current]);
        if (!info.ok)
        {
            if (current == path)
                return StorageImpact.init;
            impact.partial = true;
            continue;
        }
        try
        {
            const remote = parseJSON(info.stdout);
            if (!hasEntry(remote, current))
            {
                if (current == path)
                    return StorageImpact.init;
                impact.partial = true;
                continue;
            }
            const upstream = commands.run(
                ["nix", "path-info", "--store", nixosCache, "--json", current]);
            JSONValue nixos;
            try
                nixos = parseJSON(upstream.stdout);
            catch (Exception)
                impact.partial = true;
            if (hasEntry(nixos, current))
                continue; // an upstream root brings its upstream closure
            if (nixos.type != JSONType.object || current !in nixos)
                impact.partial = true;
            if ("narSize" !in remote[current])
                impact.partial = true;
            impact.paths ~= PathSize(current, narSize(remote[current]));
            pending ~= referencePaths(remote[current]);
        }
        catch (Exception)
        {
            if (current == path && impact.paths.length == 0)
                return StorageImpact.init;
            impact.partial = true;
        }
    }
    return impact;
}

private StorageImpact measureRemote(Commands)(ref Commands commands, string path)
{
    foreach (store; remoteCaches)
    {
        auto impact = measureOneStore(commands, path, store);
        if (impact.known)
            return impact;
    }
    return StorageImpact.init;
}

/**
 * Storage this cache would hold for `path`.
 *
 * A path that exists locally is measured from its closure. Anything that
 * measurement cannot answer falls through to the sparkles and dlang-community
 * binary caches, in that order.
 */
private StorageImpact measureStorageImpact(Commands)(ref Commands commands, string path)
{
    auto present = commands.exists(path);
    if (present.hasError)
        return StorageImpact.init;
    if (present.value)
    {
        auto local = measureLocal(commands, path);
        if (local.known)
            return local;
    }
    return measureRemote(commands, path);
}

/// Push, then pin. A failed push does not attempt the pin.
private Expected!(void, string) pushAndPin(Commands, Note)(
    ref Commands commands,
    string cache,
    string pinName,
    string path,
    int revisions,
    string repoRoot,
    scope Note note,
)
{
    auto present = commands.exists(path);
    if (present.hasError)
        return err!void(present.error);
    if (!present.value)
        return err!void(format("store path does not exist locally: %s", path));

    const cmds = cachixCommands(
        haveCachix: commands.haveCachix,
        cache: cache,
        pinName: pinName,
        path: path,
        revisions: revisions,
        repoRoot: repoRoot,
    );
    const pushed = commands.run(cmds.push);
    if (!pushed.ok)
        return err!void(format("cachix push failed: %s", pushed.stderr.strip));
    note("pinning " ~ pinName ~ "...");
    const pinned = commands.run(cmds.pin);
    if (!pinned.ok)
        return err!void(format("cachix pin failed: %s", pinned.stderr.strip));
    return ok();
}

private JobReport executeJob(Commands, Note)(
    ref Commands commands,
    JobRequest req,
    RunPlan plan,
    string repoRoot,
    scope Note note,
)
{
    if (commands.cancelled)
        return finished(req, error: "pin cancelled before starting");
    note((plan.dryRun ? "resolving " : "building ") ~ req.installable ~ "...");
    const ran = commands.run(plan.dryRun
            ? nixEvalArgs(repoRoot, req.installable)
            : nixBuildArgs(repoRoot, req.installable));
    if (!ran.ok)
    {
        const prefix = plan.dryRun ? "evaluation failed: " : "build failed: ";
        return finished(req, error: prefix ~ ran.stderr.strip);
    }

    auto storePath = extractStorePath(ran.stdout);
    if (!storePath.startsWith("/nix/store/") || storePath.indexOf('\n') >= 0)
        return finished(req, error: "command did not return a store path");
    if (!plan.dryRun)
    {
        auto built = commands.exists(storePath);
        if (built.hasError)
            return finished(req, storePath, error: built.error);
        if (!built.value)
            return finished(req, storePath, error: "store path missing locally after build: " ~ storePath);
    }

    note("measuring cache impact...");
    auto impact = measureStorageImpact(commands, storePath);
    if (commands.cancelled)
        return finished(req, storePath, impact, "pin cancelled after resolving store path");
    if (plan.dryRun)
        return finished(req, storePath, impact);

    note("pushing to " ~ plan.cache ~ "...");
    auto problem = pushAndPin(
        commands, plan.cache, req.name ~ "-" ~ req.system,
        storePath, plan.revisions, repoRoot, note,
    );
    if (problem.hasError)
        return finished(req, storePath, impact, problem.error);
    return finished(req, storePath, impact);
}

private enum JobState { pending, running, finished }

/// All mutable batch state belongs to one executor. Claim never suspends.
private class PinBatch
{
    JobRequest[] requests;
    JobReport[] reports;
    JobState[] states;
    string[] details;
    size_t next;

    this(JobRequest[] requests) @safe
    {
        this.requests = requests;
        reports = new JobReport[](requests.length);
        states = new JobState[](requests.length);
        details = new string[](requests.length);
    }

    bool claim(out size_t index) @safe nothrow @nogc
    {
        if (next == requests.length)
            return false;
        index = next++;
        states[index] = JobState.running;
        return true;
    }

    void finishMissing(string problem) @safe
    {
        foreach (i, state; states)
            if (state != JobState.finished)
            {
                reports[i] = finished(requests[i], error: problem);
                states[i] = JobState.finished;
            }
    }
}

/// Heap-owned worker state avoids capturing a spawning function's parameter frame.
private class BatchWorker(X, Job)
{
    X* executor;
    PinBatch batch;
    Job job;

    this(X* executor, PinBatch batch, Job job)
    {
        this.executor = executor;
        this.batch = batch;
        this.job = job;
    }

    void run()
    {
        size_t index;
        while (!checkCancellation(*executor).hasError && batch.claim(index))
        {
            const req = batch.requests[index];
            try
                batch.reports[index] = job(req,
                    (string detail) { batch.details[index] = detail; });
            catch (Exception e)
                batch.reports[index] = finished(req, error: e.msg);
            // A capability may return a result while cancellation is latched.
            // Never publish that as successful completion or claim another job.
            if (checkCancellation(*executor).hasError && batch.reports[index].succeeded)
                batch.reports[index].error = "pin cancelled";
            batch.states[index] = JobState.finished;
        }
    }
}

/// Bounded fan-out; scope exit joins children, including cancellation and defects.
private auto runBatch(X, Job)(ref X executor, PinBatch batch, size_t workers, Job job)
{
    auto exec = &executor;
    return withScope!((ref scope_) {
        foreach (_; 0 .. min(workers, batch.requests.length))
        {
            auto worker = new BatchWorker!(X, Job)(exec, batch, job);
            if (!scope_.spawn(&worker.run))
                break;
        }
    })(executor);
}

@("toolchainPin.runBatch.boundedOrderedAndContinuesFailures")
@system
unittest
{
    import sparkles.event_horizon.testing : TestSched, advanceAndSettle;
    import sparkles.event_horizon.clock : TestClock;

    TestSched scheduler;
    auto clock = TestClock!(TestSched.Waker)(scheduler.waker());
    JobRequest[] requests;
    foreach (i; 0 .. 5)
        requests ~= JobRequest(id: i, name: "pin", system: "linux");
    auto batch = new PinBatch(requests);
    size_t active, peak;
    size_t[] completed;
    bool joined;
    scheduler.run(() {
        auto outcome = runBatch(scheduler, batch, 2,
            (JobRequest req, scope void delegate(string) note) {
                ++active;
                peak = max(peak, active);
                note("working");
                cast(void) clock.sleep(req.id == 0 ? 20.msecs : 1.msecs);
                --active;
                completed ~= req.id;
                return finished(req, error: req.id == 1 ? "expected failure" : null);
            });
        assert(!outcome.hasError);
        joined = true;
    });
    advanceAndSettle(scheduler, clock);
    assert(joined && scheduler.liveFibers == 0);
    assert(peak == 2 && active == 0);
    assert(completed[0] == 1 && completed[$ - 1] == 0);
    assert(batch.reports.map!(report => report.id).array == [0, 1, 2, 3, 4]);
    assert(batch.reports[1].error == "expected failure");
    assert(batch.states.all!(state => state == JobState.finished));
}

@("toolchainPin.runBatch.cancellationStopsClaimsAndJoins")
@system
unittest
{
    import sparkles.event_horizon.testing : TestSched, advanceAndSettle;
    import sparkles.event_horizon.clock : TestClock;

    TestSched scheduler;
    auto clock = TestClock!(TestSched.Waker)(scheduler.waker());
    auto batch = new PinBatch([
        JobRequest(id: 0), JobRequest(id: 1), JobRequest(id: 2),
    ]);
    bool joined;
    scheduler.run(() {
        auto outcome = withScope!((ref root) {
            root.spawn(() {
                cast(void) clock.sleep(1.msecs);
                root.cancel();
            });
            auto jobs = runBatch(scheduler, batch, 1,
                (JobRequest req, scope void delegate(string) note) {
                    auto asleep = clock.sleep(30.msecs);
                    return finished(req, error: asleep.hasError ? "cancelled" : null);
                });
            joined = true;
        })(scheduler);
    });
    advanceAndSettle(scheduler, clock);
    assert(joined && scheduler.liveFibers == 0);
    assert(batch.next == 1);
    batch.finishMissing("cancelled before starting");
    assert(batch.reports[0].error == "pin cancelled");
    assert(batch.reports[2].error == "cancelled before starting");
}

version (unittest)
private struct ScriptedCommands
{
    struct Step
    {
        const(string)[] argv;
        Captured result;
    }

    Step[] steps;
    size_t next;
    bool local = true;
    bool haveCachix = true;
    bool cancelled;
    bool existsFails;

    Expected!(bool, string) exists(string) @safe pure =>
        existsFails ? err!bool("stat failed") : ok(local);

    Captured run(const(string)[] argv) @safe
    {
        assert(next < steps.length, "unexpected extra command");
        assert(argv == steps[next].argv, "unexpected command or command ordering");
        return steps[next++].result;
    }
}

@("toolchainPin.executeJob.dryRunAndPushBeforePin")
@safe
unittest
{
    enum path = "/nix/store/root";
    enum repo = "/repo";
    auto req = JobRequest(0, "pin", "linux", ".#packages.linux.pin");
    auto plan = RunPlan("sparkles", true, false, 3, 1);
    const resolved = Captured(path, null, true);
    const closure = Captured(path ~ "\n", null, true);
    const sized = Captured(`{"/nix/store/root":{"narSize":10}}`, null, true);
    const absent = Captured(`{"/nix/store/root":null}`, null, false);
    const published = Captured(null, null, true);
    ScriptedCommands commands;
    commands.steps = [
        ScriptedCommands.Step(argv: nixEvalArgs(repo, req.installable), result: resolved),
        ScriptedCommands.Step(argv: ["nix-store", "-qR", path], result: closure),
        ScriptedCommands.Step(argv: ["nix", "path-info", "--json", path], result: sized),
        ScriptedCommands.Step(
            argv: ["nix", "path-info", "--store", nixosCache, "--json", path],
            result: absent,
        ),
    ];
    auto report = executeJob(commands, req, plan, repo, delegate void(string detail) @safe {});
    assert(report.succeeded && report.bytes == 10 && !report.sizePartial);
    assert(commands.next == commands.steps.length, "dry-run stops before publishing");

    plan.dryRun = false;
    commands.next = 0;
    commands.steps[0].argv = nixBuildArgs(repo, req.installable);
    const publish = cachixCommands(
        haveCachix: true, cache: plan.cache, pinName: "pin-linux",
        path: path, revisions: plan.revisions, repoRoot: repo);
    commands.steps ~= ScriptedCommands.Step(argv: publish.push, result: published);
    commands.steps ~= ScriptedCommands.Step(argv: publish.pin, result: published);
    report = executeJob(commands, req, plan, repo, delegate void(string detail) @safe {});
    assert(report.succeeded && commands.next == 6);

    commands.next = 0;
    commands.steps[4].result = Captured(null, "push refused", false);
    report = executeJob(commands, req, plan, repo, delegate void(string detail) @safe {});
    assert(!report.succeeded && commands.next == 5, "failed push prevents pin");
    assert(report.storePath == path && report.bytes == 10);

    commands.next = 0;
    commands.steps[4].result = published;
    commands.steps[5].result = Captured(null, "pin refused", false);
    report = executeJob(commands, req, plan, repo, delegate void(string detail) @safe {});
    assert(!report.succeeded && commands.next == 6);
    assert(report.storePath == path && report.bytes == 10);

    commands.next = 0;
    commands.steps[0].result = Captured(null, "evaluation refused", false);
    report = executeJob(commands, req, plan, repo, delegate void(string detail) @safe {});
    assert(!report.succeeded && commands.next == 1, "failed resolution stops the pipeline");
    commands.cancelled = true;
    commands.next = 0;
    report = executeJob(commands, req, plan, repo, delegate void(string detail) @safe {});
    assert(!report.succeeded && commands.next == 0, "cancelled job starts no command");
}

@("toolchainPin.pushAndPin.existenceFailureIsNotAbsence")
@safe
unittest
{
    ScriptedCommands commands;
    commands.local = false;
    auto absent = pushAndPin(
        commands, "sparkles", "pin", "/nix/store/missing", 3, "/repo",
        delegate void(string detail) @safe {},
    );
    assert(absent.hasError);
    assert(absent.error.startsWith("store path does not exist locally:"));
    assert(commands.next == 0);

    commands.existsFails = true;
    commands.local = true;
    auto failed = pushAndPin(
        commands, "sparkles", "pin", "/nix/store/missing", 3, "/repo",
        delegate void(string detail) @safe {},
    );
    assert(failed.hasError && failed.error == "stat failed");
    assert(!failed.error.startsWith("store path does not exist"));
    assert(commands.next == 0, "a failed existence check does not publish");
}

@("toolchainPin.runBatch.admissionFailureIsTerminal")
@system
unittest
{
    import sparkles.test_runner.skip : skipTest;

    Sched scheduler;
    const created = Sched.create(scheduler, SchedOptions(maxFibers: 1));
    if (created.hasError)
        skipTest("completion backend unavailable: " ~ created.error.context);
    scope (exit) scheduler.destroy();
    auto batch = new PinBatch([JobRequest(id: 0)]);
    bool refused;
    const ran = scheduler.run(() {
        auto outcome = runBatch(scheduler, batch, 1,
            (JobRequest req, scope void delegate(string) note) {
                return finished(req);
            });
        refused = outcome.hasError;
    });
    assert(!ran.hasError && refused && batch.next == 0);
    batch.finishMissing("fiber admission failed");
    assert(!batch.reports[0].succeeded);
}

@("toolchainPin.measureRemote.transitiveSharedAndPartial")
@safe
unittest
{
    enum store = "https://sparkles.cachix.org";
    enum root = "/nix/store/root";
    enum child = "/nix/store/child";
    enum leaf = "/nix/store/leaf";
    ScriptedCommands commands;
    commands.local = false;
    string[] paths = [root, child, leaf];
    string[] json = [
        `{"/nix/store/root":{"narSize":10,"references":["/nix/store/root","/nix/store/child"]}}`,
        `{"/nix/store/child":{"narSize":20,"references":["/nix/store/leaf"]}}`,
        `{"/nix/store/leaf":{"narSize":30,"references":["/nix/store/child"]}}`,
    ];
    foreach (i, path; paths)
    {
        commands.steps ~= ScriptedCommands.Step(
            argv: ["nix", "path-info", "--store", store, "--json", path],
            result: Captured(json[i], null, true));
        commands.steps ~= ScriptedCommands.Step(
            argv: ["nix", "path-info", "--store", nixosCache, "--json", path],
            result: Captured("{\"" ~ path ~ "\":null}", null, false));
    }
    auto impact = measureOneStore(commands, root, store);
    assert(impact.known && !impact.partial && impact.bytes == 60);
    assert(impact.paths.map!(entry => entry.path).array == paths);
    assert(commands.next == 6, "self/shared refs queried once");
    commands.next = 0;
    commands.steps[5].result = Captured(null, "network failure", false);
    impact = measureOneStore(commands, root, store);
    assert(impact.known && impact.partial && impact.bytes == 60);
}

private struct PinRun
{
    JobReport[] reports;
    bool interactive;
}

/**
 * Run every request. The caller thread owns `TaskReporter` and only applies
 * messages; workers never touch it.
 */
private PinRun drive(Target[] targets, RunPlan plan, string repoRoot) @system
{
    const theme = makeTheme(detectTermCaps());
    auto region = stdoutLiveRegion();
    auto tasks = TaskReporter(&region, theme);

    JobRequest[] requests;
    requests.reserve(targets.length);
    const nameWidth = targets.length ? targets.map!(target => target.name.length).maxElement : 0;
    foreach (i, target; targets)
    {
        const label = format("%-*s  %-15s", nameWidth, target.name, target.system);
        const id = tasks.add(label);
        assert(id == i);
        requests ~= JobRequest(i, target.name, target.system, target.installable);
    }

    auto batch = new PinBatch(requests);
    scope (exit) region.finish();

    if (requests.length == 0)
        return PinRun(batch.reports, region.interactive);

    const workers = min(plan.jobs, requests.length);
    PinRun stopped(string problem)
    {
        batch.finishMissing(problem);
        foreach (i, report; batch.reports)
            if (report.error.length)
                tasks.fail(i, report.error);
        return PinRun(batch.reports, region.interactive);
    }
    ShutdownSignals signals;
    const signalSetup = ShutdownSignals.create(signals);
    if (signalSetup.hasError)
        return stopped("shutdown signal setup failed: " ~ signalSetup.error.context);
    scope (exit) signals.close();
    Sched scheduler;
    // One worker plus up to seven supervision children per active pin, root,
    // scope body, reporter, and spare admission capacity. Catalog bounds workers.
    const created = Sched.create(scheduler,
        SchedOptions(maxFibers: cast(uint) (16 + workers * 8)));
    if (created.hasError)
        return stopped("completion backend unavailable: " ~ created.error.context);
    scope (exit) scheduler.destroy();

    auto painted = new JobState[](requests.length);
    void refresh()
    {
        foreach (i, state; batch.states)
        {
            if (state == JobState.pending || painted[i] == JobState.finished)
                continue;
            if (painted[i] == JobState.pending)
                tasks.start(i);
            if (state == JobState.finished)
            {
                const report = batch.reports[i];
                if (report.succeeded)
                    tasks.succeed(i, completionDetail(report, plan.dryRun));
                else
                    tasks.fail(i, report.error);
            }
            else
                tasks.output(i, batch.details[i]);
            painted[i] = state;
        }
        tasks.tick();
    }

    BlockingPool blocking;
    const poolCreated = BlockingPool.create(blocking, workers: 1);
    if (poolCreated.hasError)
        return stopped("blocking pool unavailable: " ~ poolCreated.error.context);
    scope (exit) cast(void) blocking.shutdown();
    SupervisedCommands commands = SupervisedCommands(
        repoRoot: repoRoot,
        token: plan.token,
        haveCachix: isInPath("cachix"),
        blocking: &blocking,
    );
    auto sched = &scheduler;
    const ran = scheduler.run(() {
        auto outcome = withScope!((ref scope_) {
            // Capture the pinned scope address, not the body's ref-parameter
            // slot: daemons can still resume during the post-body join.
            auto rootScope = &scope_;
            if (!scope_.spawnDaemon(() {
                UniqueBuffer!(ubyte, 1) buffer;
                buffer.length = 1;
                auto signal = read(BorrowedFd(signals.reader), move(buffer));
                if (!signal.res.hasError)
                    rootScope.cancel(Interrupt(InterruptKind.shutdown));
            }))
                return;
            if (!scope_.spawnDaemon(() {
                while (!checkCancellation(*sched).hasError)
                {
                    refresh();
                    if (sleep(*sched, 80.msecs).hasError)
                        break;
                }
            }))
                return;
            auto completed = runBatch(*sched, batch, workers,
                (JobRequest req, scope void delegate(string) note) {
                    auto workerCommands = commands;
                    return executeJob(workerCommands, req, plan, repoRoot, note);
                });
            if (completed.hasError)
                scope_.fail(completed.error);
        })(*sched);
        if (outcome.hasError)
            batch.finishMissing("pin run interrupted or failed before completion");
    });
    if (ran.hasError)
        batch.finishMissing("scheduler failed before completion");
    batch.finishMissing("pin run stopped before completion");
    refresh();
    return PinRun(batch.reports, region.interactive);
}

private TableProps summaryProps(RunPlan plan, ulong totalBytes, size_t pathCount,
    bool incomplete = false) @safe pure
{
    return TableProps(
        headerRows: 1,
        rowSeparators: true,
        columnSeparators: true,
        columnAligns: [Align.left, Align.left, Align.right, Align.left],
        title: plan.dryRun
            ? format(" Derivation Pin Summary (Dry Run) — Target: %s ", plan.cache)
            : format(" Derivation Pin Summary — Target: %s ", plan.cache),
        footer: format(
            " %sUnique Cache Storage: %s (%d non-upstream paths)%s ",
            incomplete ? "Partial " : "Total ",
            capReport(totalBytes),
            pathCount,
            incomplete ? " — * incomplete measurements" : "",
        ),
    );
}

@("toolchainPin.storageReporting.partialAndInvalidSizes")
@safe
unittest
{
    auto report = sampleReport("pin", "system", "/nix/store/root", true, 1024);
    report.impact.partial = true;
    assert(sizeCell(report) == "1.0KiB*");
    assert(completionDetail(report, true) == "1.0KiB (partial)  [/nix/store/root]");
    const props = summaryProps(RunPlan.init, 1024, 1, true);
    assert(props.footer == " Partial Unique Cache Storage: 1.0KiB of the 10.0GiB cap (0%) "
        ~ "(1 non-upstream paths) — * incomplete measurements ");
    bool rejected;
    try
        cast(void) narSize(parseJSON(`{"narSize":-1}`));
    catch (Exception)
        rejected = true;
    assert(rejected, "negative narSize must never wrap to ulong.max");
}

private void renderSummary(JobReport[] reports, RunPlan plan, bool interactive) @system
{
    import core.thread : Thread;

    auto rows = summaryRows(groupByName(reports));
    const sizes = uniqueNarSizes(reports);
    auto props = summaryProps(plan, sizes.byValue.sum, sizes.length,
        reports.any!(report => !report.sizeKnown || report.sizePartial));

    writeln();
    if (interactive)
    {
        foreach (line; drawTableChunks!true(rows, props))
        {
            stdout.write(line);
            stdout.flush();
            Thread.sleep(12.msecs);
        }
    }
    else
        writeln(drawTable(rows, props));
    writeln();
}

private Expected!(void, string) announce(RunPlan plan, JobReport[] reports) @system
{
    if (reports.any!(report => !report.succeeded))
        return err!void("Some targets failed to build, evaluate, or push.");
    if (plan.dryRun)
        writefln("Mode: Dry Run (no paths were pushed or pinned). Target cache: %s", plan.cache);
    else
    {
        writefln(
            "Successfully pushed and pinned all selected derivations to %s (keeping %d revision%s each).",
            plan.cache,
            plan.revisions,
            plan.revisions == 1 ? "" : "s",
        );
    }
    return ok();
}

/**
 * Delete the cache's pins outside `set`, the whole expansion; a dry run lists
 * them. Runs only after every selected pin succeeded.
 */
private Expected!(void, string) prune(in Target[] set, RunPlan plan) @system
{
    auto pruned = prunePins!(liveGet, liveDelete)(plan.cache, set, plan.token, plan.dryRun);
    if (pruned.hasError)
        return err!void(pruned.error);
    const report = pruned.value;
    if (report.stale.length == 0)
    {
        writefln("No pins outside the set in %s.", plan.cache);
        return ok();
    }
    writefln("%s %d pin%s outside the set from %s:",
        plan.dryRun ? "Would delete" : "Deleting",
        report.stale.length, report.stale.length == 1 ? "" : "s", plan.cache);
    foreach (pin; report.stale)
        writefln("  %s", pin);
    if (report.failures.length)
    {
        foreach (failure; report.failures)
            stderr.writeln(failure);
        return err!void(format("%d of %d stale pins were not deleted.",
            report.failures.length, report.stale.length));
    }
    return ok();
}

/**
 * TC23's gate: every target's out path has a narinfo in the cache. Prints the
 * outputs that do not, and fails when there are any.
 */
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

/**
 * TC23's gate as a `ci` mode (`ci --check-pin-cache`): every pinned system's
 * toolchain entries (`toolchain-*`) are in `cache`. The other entries change
 * with ordinary pull requests and are pinned after they merge, so the gate
 * leaves them to `toolchain-pin --check`.
 */
Expected!(void, string) checkToolchainCached(string cache) @system =>
    evaluatePinSet(findRepoRoot())
        .andThen!((Target[] set) => selectTargets(set, Selection(categories: Category.toolchain)))
        .andThen!((Target[] toolchain) => checkTargets(toolchain, cache));
