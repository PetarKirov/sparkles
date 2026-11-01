/**
Supervised command execution for derivation pins. Streams stay on the result
whether or not the child succeeded. Commands inherit the environment with a
local token overlay, never a mutation of the parent process.
*/
module derivation_pin_process;

version (Posix):

import core.stdc.errno : ECANCELED;
import core.time : Duration;

import std.conv : text;

import sparkles.base.expected : Expected, err, ok;

import sparkles.event_horizon.proc : EnvironmentChange, ExitStatus, ProcessConfig,
    ProcessEnd, ReapOutcome, StdioMode, StdioSpec, SupervisedProcessConfig,
    SupervisedProcessResult;
import sparkles.event_horizon.sched : currentScheduler;
import sparkles.event_horizon.supervise : supervise;
import sparkles.event_horizon.blocking_pool : BlockingPool;
import sparkles.event_horizon.cause : interruptRequested;

/// Child streams. `ok` is false for a non-zero exit or a supervision problem;
/// both streams are still the fields callers read.
struct Captured
{
    string stdout;
    string stderr;
    bool ok;
}

/// Why this child cannot be treated as a clean exit, or null.
private string supervisionProblem(in SupervisedProcessResult result) @safe pure
{
    if (result.end == ProcessEnd.spawnFailed)
        return text(i"spawn failed: errno $(result.spawnError.code) ($(result.spawnError.context))");
    if (result.end == ProcessEnd.cancelled)
        return "command cancelled";
    if (result.end == ProcessEnd.timedOut)
        return "command timed out";
    if (result.reap != ReapOutcome.reaped)
        return "child exit status unavailable";
    if (result.stdoutTruncated || result.stderrTruncated || result.eofForced)
        return "command output incomplete";
    if (result.terminationDegraded || result.residualPolicyDegraded || result.cgroupCleanupLeaked)
        return "command cleanup degraded";
    if (result.status.signaled)
        return text("killed by signal ", result.status.code);
    return null;
}

/// A supervision problem replaces stderr with the reason. A non-zero exit keeps both streams.
Captured interpret(in SupervisedProcessResult result, string stdout, string stderr) @safe pure
{
    const why = supervisionProblem(result);
    if (why.length)
        return Captured(stdout, why, false);
    return Captured(stdout, stderr, result.status.ok);
}

///
@("toolchainPin.interpret.evidenceAndNonZeroOutput")
@safe pure
unittest
{
    SupervisedProcessResult result;
    result.end = ProcessEnd.exited;
    auto missing = interpret(result, "kept", "diag");
    assert(!missing.ok && missing.stderr == "child exit status unavailable" && missing.stdout == "kept");

    result.reap = ReapOutcome.reaped;
    result.status = ExitStatus(signaled: false, code: 0);
    assert(interpret(result, "out", "err").ok);

    result.stdoutTruncated = true;
    auto incomplete = interpret(result, "partial", "err");
    assert(!incomplete.ok && incomplete.stdout == "partial");

    result.stdoutTruncated = false;
    result.end = ProcessEnd.cancelled;
    assert(interpret(result, null, null).stderr == "command cancelled");

    result.end = ProcessEnd.exited;
    result.status = ExitStatus(signaled: false, code: 7);
    auto failed = interpret(result, `{"/nix/store/root":null}`, "diagnostic");
    assert(!failed.ok && failed.stdout == `{"/nix/store/root":null}` && failed.stderr == "diagnostic");
}

/// Child configuration shared by every stage, with non-interactive stdin.
SupervisedProcessConfig commandConfig(string repoRoot, string token) @safe pure
{
    return SupervisedProcessConfig(
        process: ProcessConfig(
            stdinSpec: StdioSpec(mode: StdioMode.nullDev),
            cwd: repoRoot,
            envOverlay: token.length
                ? [EnvironmentChange(name: "CACHIX_AUTH_TOKEN", value: token, unset: false)]
                : null,
        ),
        sampleInterval: Duration.zero,
    );
}

///
@("toolchainPin.commandConfig.overlayAndCwd")
@safe pure
unittest
{
    const cfg = commandConfig(repoRoot: "/repo", token: "synthetic-token");
    assert(cfg.process.cwd == "/repo");
    assert(cfg.process.env is null);
    assert(cfg.process.stdinSpec.mode == StdioMode.nullDev);
    assert(cfg.process.envOverlay == [
        EnvironmentChange(name: "CACHIX_AUTH_TOKEN", value: "synthetic-token", unset: false),
    ]);
    assert(commandConfig(repoRoot: "/repo", token: null).process.envOverlay.length == 0);
}

/// Live adapter. Must run on a scheduler fiber; each call owns its child to reap.
struct SupervisedCommands
{
    string repoRoot;
    string token;
    bool haveCachix;
    BlockingPool* blocking;

    bool cancelled() @system nothrow @nogc =>
        interruptRequested(*currentScheduler().currentContext());

    /// Local store existence. A filesystem or pool failure is not "absent".
    Expected!(bool, string) exists(string path) @system
    {
        struct Probe
        {
            string path;
            bool exists;
            bool failed;
            string message;
        }

        Probe probe = Probe(path: path);
        static void check(void* context) nothrow
        {
            import std.file : exists;

            auto value = cast(Probe*) context;
            try
                value.exists = value.path.exists;
            catch (Exception e)
            {
                value.failed = true;
                value.message = e.msg;
            }
        }

        auto checked = blocking.run(currentScheduler(), &check, &probe);
        if (checked.hasError)
            return err!bool(checked.error.context);
        if (probe.failed)
            return err!bool(probe.message);
        return ok(probe.exists);
    }

    Captured run(const(string)[] argv) @system
    {
        auto result = supervise(currentScheduler(), argv, commandConfig(repoRoot: repoRoot, token: token));
        if (result.hasError)
        {
            const error = result.error;
            return Captured(
                stdout: null,
                stderr: error.code == ECANCELED
                    ? "command cancelled"
                    : text(i"command I/O failed: errno $(error.code) ($(error.context))"),
                ok: false,
            );
        }
        auto value = result.value;
        // Fresh owned strings preserve arbitrary child bytes, including invalid UTF-8.
        const output = (cast(const(char)[]) value.stdout_[]).idup;
        const diagnostic = (cast(const(char)[]) value.stderr_[]).idup;
        return interpret(value, output, diagnostic);
    }
}

@("toolchainPin.supervisedCommands.separateStreamsTokenCwdAndExit")
@system
unittest
{
    import core.stdc.stdlib : free;
    import core.sys.posix.stdlib : realpath;
    import std.string : fromStringz;

    import sparkles.event_horizon.sched : Sched;
    import sparkles.test_runner.skip : skipTest;

    Sched scheduler;
    auto created = Sched.create(scheduler);
    if (created.hasError)
        skipTest("completion backend unavailable: " ~ created.error.context);
    scope (exit) scheduler.destroy();
    // The child reports its physical directory: on macOS `/tmp` is a symlink
    // to `/private/tmp`.
    auto resolved = realpath("/tmp", null);
    assert(resolved !is null);
    const tmp = resolved.fromStringz.idup;
    free(resolved);
    auto commands = SupervisedCommands(repoRoot: "/tmp", token: "synthetic-token");
    auto ran = scheduler.run(() {
        auto result = commands.run(["sh", "-c",
            `printf '%s\n' "$CACHIX_AUTH_TOKEN"; pwd -P; printf diagnostic >&2; exit 7`]);
        assert(!result.ok && result.stdout == "synthetic-token\n" ~ tmp ~ "\n" && result.stderr == "diagnostic");
        result = commands.run(["sh", "-c", "printf stdout; printf stderr >&2"]);
        assert(result.ok && result.stdout == "stdout" && result.stderr == "stderr");
    });
    assert(!ran.hasError);
}

@("toolchainPin.supervisedCommands.cancellationReapsBeforeReturning")
@system
unittest
{
    import core.time : msecs;

    import sparkles.event_horizon.sched : Sched;
    import sparkles.event_horizon.scope_ : withDeadline;
    import sparkles.test_runner.skip : skipTest;

    Sched scheduler;
    auto created = Sched.create(scheduler);
    if (created.hasError)
        skipTest("completion backend unavailable: " ~ created.error.context);
    scope (exit) scheduler.destroy();
    auto commands = SupervisedCommands(repoRoot: "/tmp", token: null);
    bool interrupted;
    auto ran = scheduler.run(() {
        auto outcome = withDeadline!((ref sc) {
            const result = commands.run(["sleep", "30"]);
            interrupted = !result.ok && result.stderr == "command cancelled";
        })(scheduler, 20.msecs);
        assert(outcome.hasError && outcome.error.isTimeout);
        // A fresh command after deadline teardown proves the latch was consumed
        // at its scope and the scheduler remains usable.
        assert(commands.run(["true"]).ok);
    });
    assert(!ran.hasError && interrupted);
}
