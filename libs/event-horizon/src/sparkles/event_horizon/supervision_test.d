/** Shared supervision parity probes, rather than one copy per POSIX backend. */
module sparkles.event_horizon.supervision_test;

version (unittest):

// ── Windows (SPEC §13.9): the M19 gate's cases against Job Objects, the
// console break and wait completion packets. The child is the test binary
// itself (`live_windows.childArgv`), so bytes, codes and trees are exact.
version (Windows)
{
    import core.stdc.errno : ENOBUFS, ENOENT;
    import core.time : Duration, MonoTime, msecs, seconds;

    import sparkles.event_horizon.errors : ioOk;
    import sparkles.event_horizon.live_windows : childArgv, killedExitCode,
        requireProcessWait;
    import sparkles.event_horizon.proc : EnvironmentChange, MetricSource, ProcessEnd,
        ProcessEvent, ProcessEventKind, ReapOutcome, ResidualPolicy, StdioMode,
        StdioSpec, SupervisedProcessConfig;
    import sparkles.event_horizon.sched : Sched, SchedOptions, schedOrSkip;
    import sparkles.event_horizon.scope_ : JoinHandle, withScope;
    import sparkles.event_horizon.supervise : supervise;

    /// `STATUS_CONTROL_C_EXIT`: how the default console handler ends a child.
    private enum int consoleBreakExit = cast(int) 0xC000_013A;

    private struct Tally
    {
        uint exits, lines;
        ubyte[][] bytes;
        bool partial;
        void put(in ProcessEvent event)
        {
            if (event.kind == ProcessEventKind.line)
            {
                ++lines;
                bytes ~= event.line.bytes.dup;
                partial |= !event.line.terminated;
            }
            if (event.kind == ProcessEventKind.exited)
                ++exits;
        }
    }

    private SupervisedProcessConfig quiet() @safe pure nothrow
    {
        SupervisedProcessConfig config;
        config.process.stdinSpec = StdioSpec(StdioMode.nullDev);
        return config;
    }

    /// LF/CRLF, a line split across writes, a final partial and binary
    /// bytes on separate streams; exact raw capture; one exit; job samples.
    @("supervision.windows.linesStatusSamplesAndReap")
    @system unittest
    {
        requireProcessWait();
        Sched s;
        schedOrSkip(s);
        Tally tally;
        auto ran = s.run(() {
            auto config = quiet();
            config.sampleInterval = Duration.zero;
            auto result = supervise(s, childArgv("lines"), config, null, &tally.put);
            assert(result.hasValue, result.hasError ? result.error.context : "");
            assert(result.value.end == ProcessEnd.exited && result.value.status.ok);
            assert(result.value.reap == ReapOutcome.reaped && tally.exits == 1);
            assert(result.value.stdout_[] == cast(const(ubyte)[]) "a\r\nbc\nlast");
            assert(result.value.stderr_[] == [0, 255, 10]);
            assert(tally.lines == 4 && tally.partial);
            assert(tally.bytes[0] == cast(const(ubyte)[]) "a", "CRLF strips the CR");
            const usage = result.value.usage;
            assert(usage.wallTime > Duration.zero);
            assert(usage.sampled && usage.sampleCount >= 1 && usage.peakProcesses >= 1);
            assert(usage.cpuSource == MetricSource.jobObject);
        });
        assert(!ran.hasError);
    }

    /// Separate streams keep their own bytes under a chatty child; merged,
    /// one pipe carries both in output order.
    @("supervision.windows.separateAndMergedStreams")
    @system unittest
    {
        requireProcessWait();
        Sched s;
        schedOrSkip(s);
        auto ran = s.run(() {
            auto separate = supervise(s, childArgv("chatty", "2000"), quiet());
            assert(separate.hasValue && separate.value.status.ok);
            assert(separate.value.stdout_.length == 2000 * 4);
            assert(separate.value.stderr_.length == 2000 * 4);

            auto config = quiet();
            config.process.stderrSpec = StdioSpec(StdioMode.mergeStdout);
            auto merged = supervise(s, childArgv("chatty", "3"), config);
            assert(merged.hasValue && merged.value.status.ok);
            assert(merged.value.stdout_[] == cast(const(ubyte)[]) "out\nerr\nout\nerr\nout\nerr\n");
            assert(merged.value.stderr_.length == 0);
        });
        assert(!ran.hasError);
    }

    /// Exit codes are data; a missing program is `spawnFailed` with no
    /// child and no event; the overlay and stdin reach the child.
    @("supervision.windows.exitCodeSpawnFailureEnvAndStdin")
    @system unittest
    {
        requireProcessWait();
        Sched s;
        schedOrSkip(s);
        Tally tally;
        auto ran = s.run(() {
            auto exited = supervise(s, childArgv("exit", "7"), quiet());
            assert(exited.hasValue && exited.value.status.code == 7);
            assert(!exited.value.status.signaled && exited.value.end == ProcessEnd.exited);

            auto missing = supervise(s, ["eh-no-such-program"], quiet(), null, &tally.put);
            assert(missing.hasValue && missing.value.end == ProcessEnd.spawnFailed);
            assert(missing.value.spawnError.code == ENOENT && tally.exits == 0);

            auto config = quiet();
            config.process.envOverlay = [EnvironmentChange("EH_SUPERVISED", "yes")];
            auto env = supervise(s, childArgv("env", "eh_supervised"), config);
            assert(env.hasValue && env.value.stdout_[] == cast(const(ubyte)[]) "yes\n");

            auto fed = supervise(s, childArgv("cat"), SupervisedProcessConfig(),
                cast(const(ubyte)[]) "fed\r\nthrough stdin");
            assert(fed.hasValue && fed.value.stdout_[]
                == cast(const(ubyte)[]) "fed\r\nthrough stdin");
        });
        assert(!ran.hasError);
    }

    /// A child that survives the console break is killed through its job
    /// once the grace expires; the root reports the kill's exit code.
    @("supervision.windows.timeoutGraceExpiryKillsTheJob")
    @system unittest
    {
        requireProcessWait();
        Sched s;
        schedOrSkip(s);
        Tally tally;
        auto ran = s.run(() {
            auto config = quiet();
            config.timeout = 100.msecs;
            config.terminateGrace = 300.msecs;
            const before = MonoTime.currTime;
            auto result = supervise(s, childArgv("ignore-break", "30000"), config,
                null, &tally.put);
            assert(result.hasValue, result.hasError ? result.error.context : "");
            assert(result.value.end == ProcessEnd.timedOut);
            assert(result.value.status.code == killedExitCode);
            assert(result.value.reap == ReapOutcome.reaped && tally.exits == 1);
            assert(!result.value.terminationDegraded);
            assert(MonoTime.currTime - before < 10.seconds);
        });
        assert(!ran.hasError);
    }

    /// The graceful stage: with a console shared with the child, the break
    /// ends it within the grace (its default handler's exit code); with
    /// none, the run records that no soft signal was deliverable, still
    /// waits the grace, and kills.
    @("supervision.windows.consoleBreakOrRecordedUndeliverable")
    @system unittest
    {
        requireProcessWait();
        Sched s;
        schedOrSkip(s);
        auto ran = s.run(() {
            auto config = quiet();
            config.timeout = 100.msecs;
            config.terminateGrace = 2.seconds;
            const before = MonoTime.currTime;
            auto result = supervise(s, childArgv("sleep", "30000"), config);
            assert(result.hasValue, result.hasError ? result.error.context : "");
            const took = MonoTime.currTime - before;
            assert(result.value.end == ProcessEnd.timedOut);
            assert(result.value.reap == ReapOutcome.reaped);
            if (result.value.softSignalUndelivered)
            {
                assert(result.value.status.code == killedExitCode);
                assert(took >= 2.seconds, "the grace runs without a soft signal");
            }
            else
            {
                assert(result.value.status.code == consoleBreakExit);
                assert(took < 2.seconds, "the break ended it inside the grace");
            }
        });
        assert(!ran.hasError);
    }

    /// A grandchild holds the output pipes after the root exits: the root's
    /// own status stands, the output grace ends with the job's termination,
    /// and both pipes reach a real EOF.
    @("supervision.windows.descendantHoldsPipeUntilTheJobEnds")
    @system unittest
    {
        requireProcessWait();
        Sched s;
        schedOrSkip(s);
        Tally tally;
        auto ran = s.run(() {
            auto config = quiet();
            config.outputGrace = 200.msecs;
            const before = MonoTime.currTime;
            auto result = supervise(s, childArgv("grandchild", "30000"), config,
                null, &tally.put);
            assert(result.hasValue, result.hasError ? result.error.context : "");
            assert(result.value.end == ProcessEnd.exited && result.value.status.ok);
            // Both the root and the grandchild print `ready`.
            assert(result.value.stdout_[] == cast(const(ubyte)[]) "ready\nready\n");
            assert(!result.value.eofForced, "the job's end closed the pipe");
            assert(result.value.usage.peakProcesses >= 1 && tally.exits == 1);
            assert(MonoTime.currTime - before < 10.seconds);
        });
        assert(!ran.hasError);
    }

    /// Cancellation from a streamed line converges through the same
    /// protected kill, drain and reap.
    @("supervision.windows.lineTriggeredCancellation")
    @system unittest
    {
        requireProcessWait();
        Sched s;
        schedOrSkip(s);
        bool cancelled;
        Tally tally;
        auto ran = s.run(() {
            auto outcome = withScope!((ref scope_) {
                JoinHandle!void handle;
                scope_.fork(handle, () {
                    auto config = quiet();
                    config.terminateGrace = 100.msecs;
                    auto result = supervise(s, childArgv("ignore-break", "30000"), config,
                        null, (in ProcessEvent event) {
                            tally.put(event);
                            if (event.kind == ProcessEventKind.line)
                                scope_.cancel();
                        });
                    assert(result.hasValue, result.hasError ? result.error.context : "");
                    cancelled = result.value.end == ProcessEnd.cancelled;
                    assert(result.value.reap == ReapOutcome.reaped);
                    return ioOk();
                });
                cast(void) handle.join(s);
            })(s);
            assert(!outcome.hasError);
        });
        assert(!ran.hasError && cancelled && tally.exits == 1);
    }

    /// Worker admission failure runs the emergency phase: kill, observe,
    /// reap, and `ENOBUFS`.
    @("supervision.windows.admissionFailureReaps")
    @system unittest
    {
        requireProcessWait();
        Sched s;
        SchedOptions options;
        options.maxFibers = 2;
        schedOrSkip(s, options);
        auto ran = s.run(() {
            auto result = supervise(s, childArgv("sleep", "30000"), quiet());
            assert(result.hasError && result.error.code == ENOBUFS);
        });
        assert(!ran.hasError);
    }
}

version (Posix):

import core.stdc.errno : ECHILD, ENOBUFS, errno;
import core.thread : Thread;
import core.sys.posix.sys.wait : WNOHANG, waitpid;
import core.time : Duration, msecs;

import sparkles.event_horizon.errors : ioOk;
import sparkles.event_horizon.proc : MetricSource, ProcessEnd, ProcessEvent,
    ProcessEventKind, ReapOutcome, StdioMode, StdioSpec, SupervisedProcessConfig;
import sparkles.event_horizon.sched : Sched, SchedOptions, schedOrSkip;
import sparkles.event_horizon.scope_ : JoinHandle, withScope;
import sparkles.event_horizon.supervise : supervise, testLastSupervisedPid;
import sparkles.test_runner.skip : skipTest;

// The existing no-zombie observation hook is process-global. Do not pretend
// another concurrently running test's root is this probe's reap evidence.
private void requireSerialReapEvidence() @system
{
    foreach (thread; Thread.getAll())
        if (thread !is Thread.getThis() && !thread.isDaemon)
            skipTest("the process-global reap evidence hook requires -t 1");
}

private bool reaped(int pid) @system nothrow @nogc
{
    int status;
    return waitpid(pid, &status, WNOHANG) < 0 && errno == ECHILD;
}

/// Separate stream framing (CRLF, split lines, final partial and binary bytes),
/// exact raw collection, one terminal event and real resource samples.
@("supervision.parity.linesStatusSamplesAndReap")
@system unittest
{
    requireSerialReapEvidence();
    Sched s;
    schedOrSkip(s);
    uint exits;
    ubyte[][] lines;
    bool partial;
    auto ran = s.run(() {
        SupervisedProcessConfig config;
        config.process.stdinSpec = StdioSpec(StdioMode.nullDev);
        config.sampleInterval = Duration.zero;
        auto result = supervise(s, ["sh", "-c",
            `printf 'a\r\nb'; printf '\000\377\n' >&2; printf 'c\nlast'`],
            config, null, (in ProcessEvent event) {
                if (event.kind == ProcessEventKind.line)
                {
                    lines ~= event.line.bytes.dup;
                    partial |= !event.line.terminated;
                }
                if (event.kind == ProcessEventKind.exited)
                    ++exits;
            });
        assert(result.hasValue, result.hasError ? result.error.context : "");
        assert(result.value.end == ProcessEnd.exited && result.value.status.ok);
        assert(result.value.reap == ReapOutcome.reaped && exits == 1);
        assert(result.value.stdout_[] == cast(const(ubyte)[]) "a\r\nbc\nlast");
        assert(result.value.stderr_[] == [0, 255, 10]);
        assert(lines.length == 4 && partial);
        assert(result.value.usage.wallTime > Duration.zero);
        assert(result.value.usage.sampled && result.value.usage.sampleCount >= 1);
        assert(result.value.usage.peakProcesses >= 1);
        version (OSX)
            assert(result.value.usage.cpuSource == MetricSource.rusage);
        assert(reaped(testLastSupervisedPid));
    });
    assert(!ran.hasError);
}

/// A descendant inherits the pipe and ignores TERM: the root's status remains
/// its own while the saved process group is killed and both pipes reach EOF.
@("supervision.parity.timeoutEscalatesAndDrainsDescendant")
@system unittest
{
    requireSerialReapEvidence();
    Sched s;
    schedOrSkip(s);
    auto ran = s.run(() {
        SupervisedProcessConfig config;
        config.process.stdinSpec = StdioSpec(StdioMode.nullDev);
        config.timeout = 80.msecs;
        config.terminateGrace = 100.msecs;
        auto result = supervise(s, ["sh", "-c",
            `{ trap '' TERM; while :; do sleep 30; done; } & echo ready; exit 0`], config);
        assert(result.hasValue, result.hasError ? result.error.context : "");
        assert(result.value.end == ProcessEnd.timedOut);
        assert(result.value.status.ok && result.value.reap == ReapOutcome.reaped);
        assert(!result.value.eofForced, "tree teardown produced real pipe EOF");
        assert(reaped(testLastSupervisedPid));
    });
    assert(!ran.hasError);
}

/// Cancellation triggered by a streamed line converges through the same
/// protected kill/drain/reap sequence, without a polling process executor.
@("supervision.parity.lineTriggeredCancellation")
@system unittest
{
    requireSerialReapEvidence();
    Sched s;
    schedOrSkip(s);
    bool cancelled;
    auto ran = s.run(() {
        auto outcome = withScope!((ref scope_) {
            JoinHandle!void handle;
            scope_.fork(handle, () {
                SupervisedProcessConfig config;
                config.process.stdinSpec = StdioSpec(StdioMode.nullDev);
                config.terminateGrace = 50.msecs;
                auto result = supervise(s, ["sh", "-c", "echo ready; sleep 30"],
                    config, null, (in ProcessEvent event) {
                        if (event.kind == ProcessEventKind.line)
                            scope_.cancel();
                    });
                assert(result.hasValue, result.hasError ? result.error.context : "");
                cancelled = result.value.end == ProcessEnd.cancelled;
                assert(result.value.reap == ReapOutcome.reaped);
                assert(reaped(testLastSupervisedPid));
                return ioOk();
            });
            cast(void) handle.join(s);
        })(s);
        assert(!outcome.hasError);
    });
    assert(!ran.hasError && cancelled);
}

/// Admission failure exercises the blocking-lane WNOWAIT probe. Its Darwin
/// siginfo storage must be the full native size, not druntime's short layout.
@("supervision.parity.admissionFailureReaps")
@system unittest
{
    requireSerialReapEvidence();
    Sched s;
    SchedOptions options;
    options.maxFibers = 2;
    schedOrSkip(s, options);
    auto ran = s.run(() {
        SupervisedProcessConfig config;
        config.process.stdinSpec = StdioSpec(StdioMode.nullDev);
        auto result = supervise(s, ["sh", "-c", "echo ready; sleep 30"], config);
        assert(result.hasError && result.error.code == ENOBUFS);
        assert(reaped(testLastSupervisedPid));
    });
    assert(!ran.hasError);
}
