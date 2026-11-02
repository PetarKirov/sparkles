/**
The live layer every host shares (SPEC §11, §13.2, §13.4): `RingClock`,
`capture`, `RingProc` and the `Env` row that `liveEnv` builds. The spawn
primitives under them are per platform — `live` on POSIX, `live_windows` on
Windows — and `live` re-exports this module on both, so consumer spellings do
not change.
*/
module sparkles.event_horizon.live_shared;

version (Posix) version = EhLiveShared;
version (Windows) version = EhLiveShared;
version (EhLiveShared)  :

import core.time : Duration, MonoTime;

import sparkles.event_horizon.backend.concept : canSubmitOp;
import sparkles.event_horizon.backend.select : DefaultBackend;
import sparkles.event_horizon.capability : CtxOf;
import sparkles.event_horizon.cause : Cause;
import sparkles.event_horizon.errors : ioError, IoError, IoErrorStage, IoResult, OpKind,
    ioErr, ioOk;
import sparkles.event_horizon.op : OpWaitHandle, OpWaitid;
import sparkles.event_horizon.proc : ExitStatus, ProcessConfig, StdioMode, StdioSpec;
import sparkles.event_horizon.sched : Sched;
import sparkles.event_horizon.sys.descriptor : BorrowedFd;
import sparkles.event_horizon.vfs : RingVfs;

version (Windows)
    import sparkles.event_horizon.live_windows : ChildProcess, RingNet, spawnProcess;
else
    import sparkles.event_horizon.live : ChildProcess, RingNet, spawnProcess;

/// Whether this backend lowers a process wait: `WAITID` on POSIX, a wait
/// completion packet (`OpWaitHandle`) on Windows.
enum bool canWaitProcesses = canSubmitOp!(DefaultBackend, OpWaitid)
    || canSubmitOp!(DefaultBackend, OpWaitHandle);

/// The live clock capability: monotonic time and an in-ring timer sleep.
struct RingClock
{
    enum string capName = "clock";

    private Sched* _sched;

    /// Binds to the scheduler whose ring backs the timer.
    this(Sched* sched) @safe pure nothrow @nogc
    {
        _sched = sched;
    }

    /// The current monotonic time.
    MonoTime now() const @safe nothrow @nogc => MonoTime.currTime;

    /// Parks the calling fiber for `d` on an in-ring `TIMEOUT`.
    IoResult!void sleep(Duration d)
    {
        import sparkles.event_horizon.io : sleep_ = sleep;

        return sleep_(*_sched, d);
    }
}

/// The run-to-completion outcome of `capture` (SPEC §13.2).
struct CapturedOutput
{
    import sparkles.base.buffer : SharedBuffer;

    ExitStatus status;
    SharedBuffer!(ubyte, 256) stdout_; /// empty unless stdoutSpec piped
    SharedBuffer!(ubyte, 256) stderr_; /// empty unless stderrSpec piped
}

static if (canWaitProcesses)
{
    /**
    Runs `argv` to completion (SPEC §13.2): spawn per `cfg`, feed
    `stdinBytes` (a non-null value upgrades a default `inherit` stdin to a
    pipe), drain the piped outputs **concurrently** — parked reads, so a
    chatty child can never deadlock against an undrained pipe (the hazard
    `runCaptured`'s temp files work around) — then reap.

    The scope join is the lifetime argument: the drain fibers borrow this
    frame's locals and are all joined before it returns.

    No exit leaves a zombie. A drain fiber that cannot be admitted, a read
    that fails, and a cancellation that interrupts the run each end the
    child (`SIGKILL`) and reap it — on the shared pool's termination-critical
    lane, under `protect`, so a latched interrupt is delivered at the
    caller's next checkpoint and never between the kill and the reap. The
    error returned is the first cause: the admission error, the read error,
    or the interrupt as `ECANCELED`. A failed read is never mistaken for EOF.
    */
    IoResult!CapturedOutput capture(ref Sched s, scope const(char[])[] argv,
        in ProcessConfig cfg = ProcessConfig(),
        scope const(ubyte)[] stdinBytes = null) @trusted
    {
        import core.lifetime : move;
        import core.stdc.errno : ECHILD;
        // Scoped: on POSIX `wait` sits behind `live`'s own `static if`,
        // which a module-level import from this cycle cannot see yet.
        import sparkles.event_horizon.live : wait;

        import sparkles.base.buffer : SharedBuffer;
        import sparkles.event_horizon.blocking_pool : sharedBlockingPool;
        import sparkles.event_horizon.cause : Cause;
        import sparkles.event_horizon.io : read, write;
        import sparkles.event_horizon.scope_ : protect, withScope;

        scope ProcessConfig effective = cfg;
        if (stdinBytes !is null && effective.stdinSpec.mode == StdioMode.inherit)
            effective.stdinSpec = StdioSpec(StdioMode.pipe);

        // The reap must never depend on a resource acquired after the child
        // exists (SPEC §13.8): the shared pool and this scheduler's inbox
        // waker are secured first — either failure means no child was made.
        auto pool = sharedBlockingPool();
        if (pool.hasError)
            return ioErr!CapturedOutput(pool.error);
        auto prepared = pool.value.prepare(s);
        if (prepared.hasError)
            return ioErr!CapturedOutput(prepared.error);

        auto spawned = spawnProcess(argv, effective);
        if (spawned.hasError)
            return ioErr!CapturedOutput(spawned.error);
        auto child = move(spawned.value);
        version (unittest)
            testLastCapturePid = child.pid;
        scope (exit)
        {
            child.stdinW.close();
            child.stdoutR.close();
            child.stderrR.close();
            child.ptyMaster.close();
        }

        // Fibers capture plain locals, never `ref`/`scope` parameters (a
        // captured parameter slot outlives nothing — the tui-loop lesson).
        CapturedOutput out_;
        SharedBuffer!(ubyte, 256) stdinCopy;
        if (stdinBytes !is null)
            stdinCopy ~= stdinBytes;
        CaptureDrainState drainState = {child: &child};
        auto childP = &child;
        auto outP = &out_;
        auto stdinP = &stdinCopy;
        auto drainP = &drainState;
        const feedStdin = stdinBytes !is null && child.stdinW.valid;

        static void drain(CaptureDrainState* st, BorrowedFd from,
            SharedBuffer!(ubyte, 256)* into)
        {
            for (;;)
            {
                SharedBuffer!(ubyte, 512) chunk;
                chunk.length = 512;
                auto got = read(from, move(chunk));
                chunk = move(got.buf);
                version (unittest)
                {
                    if (testCaptureReadErrno != 0 && !got.res.hasError)
                        got.res = ioErr!uint(testCaptureReadErrno, OpKind.read,
                            IoErrorStage.completion, "injected capture read error");
                }
                if (got.res.hasError)
                {
                    // Not EOF: the output can no longer be complete, so the
                    // run ends now — a child blocked on this pipe would
                    // otherwise never let the other stream reach EOF.
                    if (!st.failed)
                    {
                        st.failed = true;
                        st.error = got.res.error;
                    }
                    endChild(*st.child);
                    return;
                }
                if (got.res.value == 0)
                    return; // EOF
                *into ~= chunk[][0 .. got.res.value];
            }
        }

        auto joined = withScope!((ref sc) {
            // A rejected drain is a failed run, not a silently missing
            // stream: the scope records ENOBUFS and cancels its siblings.
            if (childP.stdoutR.valid
                && !sc.spawn(() { drain(drainP, childP.stdoutR.borrowFd(), &outP.stdout_); }))
                return;
            if (childP.stderrR.valid
                && !sc.spawn(() { drain(drainP, childP.stderrR.borrowFd(), &outP.stderr_); }))
                return;
            // The body is a member fiber: feed stdin concurrently with the
            // drains, then signal EOF.
            if (feedStdin)
                cast(void) write(childP.stdinW, move(*stdinP));
            if (childP.stdinW.valid)
                childP.stdinW.close();
        })(s);

        child.stdoutR.close();
        child.stderrR.close();
        if (joined.hasError)
        {
            // The join proves no read is in flight on this frame's pipes;
            // the child may be live, blocked, or already a zombie — end it
            // and consume the reap right before the interrupt is delivered.
            killAndReapProtected(s, child);
            if (joined.error.kind == Cause!IoError.Kind.die)
                throw joined.error.defect;
            return ioErr!CapturedOutput(captureCauseError(joined.error));
        }

        auto st = wait(s, child);
        if (st.hasError)
        {
            // Only ECHILD proves the reap right is gone; anything else
            // (a cancellation landing on the reap itself) leaves the child
            // ours to end and consume.
            if (st.error.code != ECHILD)
                killAndReapProtected(s, child);
            return ioErr!CapturedOutput(st.error);
        }
        if (drainState.failed)
            return ioErr!CapturedOutput(drainState.error);
        out_.status = st.value;
        return ioOk(move(out_));
    }

    /// The drain fibers' shared frame state: the first read failure wins.
    private struct CaptureDrainState
    {
        ChildProcess* child;
        bool failed;
        IoError error;
    }

    /// Maps a capture scope's cause to the error `capture` reports: a
    /// failure carries its own error (a drain's ENOBUFS admission); an
    /// interrupt is the cancellation it was.
    private IoError captureCauseError(Cause!IoError cause)
        @safe pure nothrow @nogc
    {
        import core.stdc.errno : ECANCELED;

        return cause.kind == Cause!IoError.Kind.fail
            ? cause.failure
            : ioError(ECANCELED, OpKind.none, IoErrorStage.completion,
                "capture scope interrupted");
    }

    /// Ends a still-owned child and consumes its reap right on the shared
    /// pool's termination-critical lane, under `protect` so that a pending
    /// interrupt cannot split the kill from the reap. `pid` is nulled once
    /// the right is consumed — or proven lost to an external reaper.
    private void killAndReapProtected(ref Sched s, ref ChildProcess child)
        @trusted
    {
        import core.stdc.errno : ECHILD;
        version (Windows)
            import sparkles.event_horizon.live_windows : reapOnLane;
        else
            import sparkles.event_horizon.live : waitPidOnLane;

        import sparkles.event_horizon.scope_ : protect;

        if (child.pid <= 0)
            return;
        auto childP = &child;
        auto sP = &s;
        protect!(() {
            endChild(*childP);
            version (Windows)
                auto reaped = reapOnLane(*sP, *childP);
            else
                auto reaped = waitPidOnLane(*sP, childP.pid);
            if (!reaped.hasError || reaped.error.code == ECHILD)
                childP.pid = -1;
            return 0;
        })(s);
    }

    /// The hard end of a child the run still owns: `SIGKILL` on POSIX; the
    /// whole job on Windows, so no descendant keeps a pipe open.
    private void endChild(ref ChildProcess child) @trusted nothrow @nogc
    {
        version (Windows)
            cast(void) child.killGroup();
        else
        {
            import core.sys.posix.signal : SIGKILL;

            cast(void) child.kill(SIGKILL);
        }
    }

    /// The live proc capability (SPEC §13.4): `isProc` over the real spawn
    /// machinery, `Child = ChildProcess`.
    struct RingProc
    {
        enum string capName = "proc";

        /// The live child handle type.
        alias Child = ChildProcess;

        private Sched* _sched;

        /// Binds to the scheduler whose ring reaps the children.
        this(Sched* sched) @safe pure nothrow @nogc
        {
            _sched = sched;
        }

        /// Spawns per `cfg` (SPEC §13.2).
        IoResult!ChildProcess spawn(scope const(char[])[] argv,
            in ProcessConfig cfg = ProcessConfig())
            => spawnProcess(argv, cfg);

        /// Parks until the child exits (in-ring `WAITID` or a wait packet).
        IoResult!ExitStatus wait(ref ChildProcess child)
        {
            import sparkles.event_horizon.live : wait_ = wait;

            return wait_(*_sched, child);
        }
    }

    /// The default live capability row handed to the root fiber (SPEC §11).
    /// `fs` is on every backend: `RingVfs` needs no ring file operations
    /// (SPEC §10.5).
    alias Env = CtxOf!(RingClock, RingNet, RingProc, RingVfs);
}
else
{
    /// On a backend without a process-wait lowering the row carries no proc
    /// capability.
    alias Env = CtxOf!(RingClock, RingNet, RingVfs);
}

/// Builds the live capability row for a scheduler — the one place that
/// knows which capabilities this backend can actually field (`LoopGroup`
/// calls this; SPEC §11).
Env liveEnv(Sched* sched) @safe pure nothrow @nogc
{
    static if (canWaitProcesses)
        return Env(RingClock(sched), RingVfs(), RingNet(sched), RingProc(sched));
    else
        return Env(RingClock(sched), RingVfs(), RingNet(sched));
}

version (unittest)
{
    /// Fault injection for `capture`'s drains: a non-zero errno replaces the
    /// result of every successful read while set.
    package int testCaptureReadErrno;
    /// The pid of the child the last `capture` spawned — for the
    /// no-zombie postconditions.
    package int testLastCapturePid;
}
