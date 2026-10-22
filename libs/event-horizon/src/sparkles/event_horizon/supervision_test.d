/** Shared supervision parity probes, rather than one copy per POSIX backend. */
module sparkles.event_horizon.supervision_test;

version (unittest):
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
