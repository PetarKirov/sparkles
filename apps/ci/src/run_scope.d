/**
A heavy `ci` command's containment (task-DAG PLAN M7, item 1): on Linux
under systemd, `ci` re-executes itself in a transient user scope whose
memory controller is delegated to it, with `MemoryMax` set, then moves itself
into a leaf of the scope so each action's cgroup is accounted (Event Horizon
§13.7). At `MemoryMax` its OOM killer chooses only among the run's processes,
never the desktop that started it. There is no `MemoryHigh`: a run past it is
throttled on every allocation and crawls instead of failing, and a prediction
too low must end in a kill the next run learns from, not in a stall.

Without systemd's user manager, or with `--memory-max=none`, the command runs
unconfined and says so. A `ci` already in a memory-limited scope (one it made,
which `$SPARKLES_CI_SCOPE` names to its children, or one its caller made)
enters no other.
*/
module run_scope;

import std.conv : to;
import std.string : endsWith;

import sparkles.base.expected : Expected, err, ok;

/// The variable a contained `ci` runs with: the scope's unit name, then,
/// once that `ci` adopted it, the name with `adoptedSuffix`, so a nested
/// `ci` neither enters a scope nor adopts one.
enum scopeVariable = "SPARKLES_CI_SCOPE";

/// ditto
enum adoptedSuffix = "+adopted";

/// The scope's memory limits, in bytes; `none` runs unconfined.
struct MemoryLimits
{
    ulong max;  /// `MemoryMax`: the OOM killer acts, inside the scope, at it
    bool none;  ///
}

/// The smallest `MemoryMax` a run gets: `ci` itself needs about 2 GiB.
enum ulong memoryFloor = 256UL << 20;

/**
`--memory-max`'s value: empty for the default (`MemoryMax` at 85 % of total
memory); `none`; a byte count with an optional `K`, `M`, `G` or `T` suffix
(powers of 1024); or a percentage of total memory. A relative limit with
total memory unknown (`total` 0) runs unconfined.
*/
Expected!(MemoryLimits, string) memoryLimits(string spec, ulong total) @safe pure
{
    import core.checkedint : mulu;

    if (spec == "none")
        return ok(MemoryLimits(none: true));
    const relative = !spec.length || spec.endsWith("%");
    if (relative && total == 0)
        return ok(MemoryLimits(none: true));
    ulong max;
    if (!spec.length)
        max = total / 100 * 85;
    else
    {
        try
        {
            if (spec.endsWith("%"))
            {
                const percent = spec[0 .. $ - 1].to!ulong;
                if (percent == 0 || percent > 100)
                    return err!MemoryLimits("--memory-max: a percentage is 1% to 100%");
                max = total / 100 * percent;
            }
            else
            {
                ulong unit = 1;
                string digits = spec;
                switch (spec[$ - 1])
                {
                case 'K', 'k': unit = 1UL << 10; break;
                case 'M', 'm': unit = 1UL << 20; break;
                case 'G', 'g': unit = 1UL << 30; break;
                case 'T', 't': unit = 1UL << 40; break;
                default: break;
                }
                if (unit != 1)
                    digits = spec[0 .. $ - 1];
                bool overflow;
                max = mulu(digits.to!ulong, unit, overflow);
                if (overflow)
                    return err!MemoryLimits("--memory-max is too large: " ~ spec);
            }
        }
        catch (Exception)
            return err!MemoryLimits("--memory-max takes none, a byte count (K, M, G or T suffix) or a percentage: "
                ~ spec);
    }
    if (max < memoryFloor)
        return err!MemoryLimits("--memory-max: at least 256M");
    return ok(MemoryLimits(max));
}

///
@("run_scope.memoryLimits")
@safe pure unittest
{
    enum gib = 1UL << 30;
    assert(memoryLimits("", 100 * gib).value == MemoryLimits(85 * gib));
    assert(memoryLimits("none", 100 * gib).value.none);
    assert(memoryLimits("20G", 100 * gib).value == MemoryLimits(20 * gib));
    assert(memoryLimits("50%", 100 * gib).value.max == 50 * gib);
    assert(memoryLimits("512M", gib).value.max == 512UL << 20);
    assert(memoryLimits("2048", gib).hasError, "below 256M");
    assert(memoryLimits("lots", gib).hasError);
    assert(memoryLimits("0%", gib).hasError);
    assert(memoryLimits("", 0).value.none, "total memory unknown: unconfined, never a 0-byte limit");
    assert(memoryLimits("50%", 0).value.none);
    assert(memoryLimits("", 200UL << 20).hasError, "the default under the floor is refused");
    assert(memoryLimits("16777216T", gib).hasError, "the suffix's product overflows");
}

/// What `$SPARKLES_CI_SCOPE` says this `ci` is to do: enter a scope, adopt
/// the one it was re-executed in, or neither (an ancestor `ci` adopted it).
enum ScopeState
{
    outside,  ///
    entered,  /// re-executed in the scope, not yet adopted
    adopted,  /// an ancestor `ci` adopted it
}

/// ditto
ScopeState scopeState(string value) @safe pure nothrow @nogc
    => !value.length ? ScopeState.outside : value.endsWith(adoptedSuffix) ? ScopeState.adopted : ScopeState.entered;

///
@("run_scope.scopeState")
@safe pure nothrow @nogc unittest
{
    assert(scopeState(null) == ScopeState.outside);
    assert(scopeState("") == ScopeState.outside, "an empty value is no scope");
    assert(scopeState("sparkles-ci-42-1a2b") == ScopeState.entered);
    assert(scopeState("sparkles-ci-42-1a2b+adopted") == ScopeState.adopted);
}

version (linux):

/**
Re-executes this `ci` in a transient systemd user scope with `limits`, when
it is not in a memory-limited one and the host can make one. On success it
does not return. Returns why the command runs as it does: unconfined, or in
the caller's limited cgroup; null when the scope is its own, for
$(LREF adoptScope).
*/
string enterScope(scope const string[] args, MemoryLimits limits) @system
{
    import core.sys.posix.unistd : execv, getpid;
    import std.conv : text;
    import std.file : thisExePath;
    import std.process : Config, environment, execute, ProcessException;
    import std.random : uniform;
    import std.string : toStringz;

    final switch (scopeState(environment.get(scopeVariable, "")))
    {
    case ScopeState.entered:
        return null;
    case ScopeState.adopted:
        return "in the scope " ~ environment.get(scopeVariable, "")[0 .. $ - adoptedSuffix.length]
            ~ " its parent ci made";
    case ScopeState.outside:
        break;
    }
    if (limits.none)
        return "unconfined: --memory-max=none, or total memory unknown";
    if (const limited = callerLimit())
        return "in the caller's cgroup " ~ limited ~ ", which already limits memory";
    const systemdRun = onPath("systemd-run");
    if (!systemdRun.length)
        return "unconfined: no executable systemd-run on PATH";
    // --expand-environment=no: systemd-run otherwise expands `$VAR` in the
    // command it starts, which would change the arguments ci was given.
    const unit = text("sparkles-ci-", getpid(), "-", uniform!uint);
    string[] common = [systemdRun, "--user", "--scope", "--quiet", "--collect", "--no-ask-password",
        "--expand-environment=no", "-p", "Delegate=yes", "-p", text("MemoryMax=", limits.max)];
    // Probe with every option the real run takes, so a user manager that
    // refuses one of them (none, a container, a CI runner without a user
    // session, an older systemd) leaves the command running, unconfined.
    try
    {
        const probe = execute(common ~ ["--", "true"], null, Config.none, 4096);
        if (probe.status != 0)
            return "unconfined: systemd-run --user cannot make a delegated scope here";
    }
    catch (ProcessException e)
        return "unconfined: systemd-run failed to start: " ~ e.msg;
    string[] argv = common ~ ["--unit=" ~ unit, "--", thisExePath] ~ (args.length > 1 ? args[1 .. $] : null);
    environment[scopeVariable] = unit;
    const(char)*[] cargv;
    foreach (a; argv)
        cargv ~= a.toStringz;
    cargv ~= null;
    execv(cargv[0], cargv.ptr);
    environment.remove(scopeVariable);
    return "unconfined: could not execute systemd-run";
}

/**
Inside the scope this `ci` entered: moves it into a leaf of the scope, so
each action's cgroup gets the memory and pids controllers (Event Horizon
`delegateRuns`), and marks the scope adopted for the processes it starts.
Returns what the kernel gave the run, read back rather than assumed: the
scope's `memory.max`, and whether its children have both controllers an
accounted action needs. Null when this `ci` entered no scope.
*/
string adoptScope() @system
{
    import std.algorithm.searching : canFind;
    import std.array : join;
    import std.conv : text;
    import std.file : readText;
    import std.process : environment;
    import std.string : split, strip;
    import sparkles.base.buffer : SharedBuffer;
    import sparkles.event_horizon.cgroup : delegateRuns;

    const name = environment.get(scopeVariable, "");
    if (scopeState(name) != ScopeState.entered)
        return null;
    environment[scopeVariable] = name ~ adoptedSuffix;
    SharedBuffer!(char, 256) parent;
    const failed = delegateRuns(parent);
    if (!parent.length)
        return text("in ", name, ", but ci could not leave its cgroup (errno ", failed, "): no action is accounted");
    string control(string file)
    {
        try
            return readText("/sys/fs/cgroup" ~ parent[].idup ~ "/" ~ file).strip;
        catch (Exception)
            return null;
    }
    const limit = control("memory.max");
    const children = control("cgroup.subtree_control").split;
    const accounted = children.canFind("memory") && children.canFind("pids");
    return text("contained by ", name, limit.length && limit != "max" ? ", MemoryMax " ~ limit ~ " bytes"
        : ", with no memory limit enforced", accounted ? ", each action accounted"
        : ", actions not accounted (its children have: " ~ (children.length ? children.join(" ") : "nothing") ~ ")");
}

/**
Raises `ci`'s own `oom_score_adj` to 900 (task-DAG M7, item 2): every process
it starts inherits at least that, a descendant an action forks before its
own score is written included, and each supervised action is then raised to
1000. A shortage takes the run's actions first, then `ci`, before any other
program. A score already higher is left, as lowering one needs privilege.
*/
void preferRunForOom() @system
{
    import core.sys.posix.unistd : getpid;
    import std.file : readText;
    import std.string : strip;
    import sparkles.event_horizon.cgroup : writeOomScoreAdj;

    try
        if (readText("/proc/self/oom_score_adj").strip.to!int >= 900)
            return;
    catch (Exception)
        return;
    cast(void) writeOomScoreAdj(getpid(), 900);
}

// The cgroup this process runs in, when an ancestor of it up to its user
// manager's limits memory (a caller's own `systemd-run -p MemoryMax=…`):
// `ci` then stays where it was put rather than escaping into a scope of
// 85 % of the host. Null otherwise.
private string callerLimit() @system
{
    import std.algorithm.searching : startsWith;
    import std.file : exists, readText;
    import std.path : baseName, dirName;
    import std.string : lineSplitter, strip;

    string own;
    try
        foreach (line; readText("/proc/self/cgroup").lineSplitter)
            if (line.startsWith("0::"))
                own = line[3 .. $].idup;
    catch (Exception)
        return null;
    // Below the user manager (`user@<uid>.service`): the cgroups a caller made.
    for (string dir = own; dir.length > 1; dir = dir.dirName)
    {
        if (dir.baseName.startsWith("user@") && dir.endsWith(".service"))
            break;
        const max = "/sys/fs/cgroup" ~ dir ~ "/memory.max";
        try
            if (exists(max) && readText(max).strip != "max")
                return dir;
        catch (Exception)
            return null;
    }
    return null;
}

// The first executable `name` on `PATH`, or null.
private string onPath(string name) @system
{
    import core.sys.posix.unistd : access, X_OK;
    import std.algorithm.iteration : splitter;
    import std.file : exists, isFile;
    import std.path : buildPath;
    import std.process : environment;
    import std.string : toStringz;

    foreach (dir; environment.get("PATH", "").splitter(':'))
    {
        if (!dir.length)
            continue;
        const path = buildPath(dir, name);
        if (exists(path) && isFile(path) && access(path.toStringz, X_OK) == 0)
            return path;
    }
    return null;
}
