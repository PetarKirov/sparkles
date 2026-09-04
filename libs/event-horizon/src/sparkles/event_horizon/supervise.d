/**
Supervised runs (SPEC §13.5–§13.8): `supervise` — spawn, stdin feed,
concurrent line framing of both pipes, bounded raw collection, cumulative
tree samples, timeout / cancellation / residual-tree policy, and one
ownership boundary around teardown.

The control plane, in one sentence: $(B every) worker is a shielded child
of one scope (`Scope.spawnShielded`, SPEC §8.2) that only the supervising
fiber ends; the supervising fiber is the single owner of the tree-state
machine and of every kill; clocks and the sampler never block and never
initiate termination on their own — they publish level-triggered command
bits carrying the epoch they were armed under, and the supervisor
consumes them after every relay message.

$(UL
    $(LI $(B drains) (one per pipe) relay raw completions; a forced EOF
        ends one by an owner interrupt whose read reaches its guaranteed
        terminal completion (§5.2);)
    $(LI the $(B stdin worker) is the sole owner of the stdin descriptor
        while it lives; termination stops it and it closes the fd itself;)
    $(LI the $(B root observer) performs the one non-consuming `WNOWAIT`
        wait, through an explicit lifecycle so no second wait for the same
        child can ever be submitted;)
    $(LI the $(B clock) owns six one-shot, ring-free `Alarm`s — timeout,
        grace, descendant output grace, `wait`'s fallback grace, the
        post-kill drain window, the detach drain window — each armed at
        most once per run;)
    $(LI the $(B sampler) owns all sampling: each sample runs on the shared
        pool's public lane (never on the loop thread), missed instants
        coalesce, and the final sample is a request/ack handshake taken
        $(B before) the reap — the reap deletes `/proc/<pid>`;)
    $(LI under `ResidualPolicy.wait`, an $(B evidence observer) waits,
        bounded, on the run cgroup's `populated` bit.)
)

The tree-state machine (§13.7):

```
live ─(root observed)─┬─ bounded, streams terminal ───────▶ killQueued
    ├─ bounded, streams open ─▶ graceArmed(natural) ─(expiry)─▶ killQueued
    ├─ wait ──▶ waitPopulated ─(populated 0)─▶ waited
    │                         └─(evidence lost)─▶ graceArmed(fallback)
    └─ detach ─▶ detached ─(drain window)─▶ forceEof ─▶ detachedDrained
graceArmed(natural|fallback) + streams terminal ──▶ killQueued   [output grace ends]
requestTermination(any pre-kill state) ───────────▶ graceArmed(requested)
killQueued ─(pgid SIGKILL, then cgroup.kill)──────▶ killSettled | killFailedAwaitRoot
killFailedAwaitRoot ─(natural root observation)───▶ killSettled
killSettled + streams terminal ───────────────────▶ drainDone
resolved: waited | detachedDrained | drainDone
```

The reap predicate is the terminal predicate — streams terminal ∧ root
resolved ∧ tree resolved — so the WNOWAIT-observed zombie pins the process
group for the whole active run and no post-reap group signal is possible
by construction. Protection is a property of that boundary: from the
terminal decision through freeze, the sampler handshake, the reap and the
worker stop, and again for the shared post-join finalization, so an outer
cancellation is delivered only after cleanup and the final event.
*/
module sparkles.event_horizon.supervise;

version (Posix)  :

import core.lifetime : move;
import core.stdc.errno : EAGAIN, ECANCELED, ECHILD, EINTR, EINVAL, ENOBUFS,
    EOPNOTSUPP, ESRCH;
import core.sys.posix.signal : SIGCONT, SIGKILL, SIGTERM;
import core.time : Duration, MonoTime, msecs, seconds;

import sparkles.base.buffer : SharedBuffer;
import sparkles.event_horizon.backend.concept : canSubmitOp;
import sparkles.event_horizon.backend.select : DefaultBackend;
import sparkles.event_horizon.blocking_pool : BlockingPool, sharedBlockingPool;
import sparkles.event_horizon.cause : CancelContext, FiberContext, Interrupt,
    InterruptKind, cancelTree, interruptFiber;
import sparkles.event_horizon.channel : Channel;
import sparkles.event_horizon.errors : IoError, IoErrorStage, IoResult, OpKind,
    ioErr, ioOk;
import sparkles.event_horizon.io : FileHandle, read, sleep, write;
import sparkles.event_horizon.live : ChildProcess, observeExit, spawnProcess,
    wait, waitPidOnLane;
import sparkles.event_horizon.op : OpWaitid;
import sparkles.event_horizon.proc : ExitStatus, KillOutcome, KillResult,
    LineFramer, MetricQuality, MetricSource, ProcessConfig, ProcessEnd,
    ProcessEvent, ProcessEventKind, ProcessEventSink, ProcessLine,
    ProcessResourceUsage, ProcessStream, ReapOutcome, ResidualPolicy,
    SampleSource, StdioMode, StdioSpec, SupervisedProcessConfig,
    SupervisedProcessResult;
import sparkles.event_horizon.sampling : TreeSampler;
import sparkles.event_horizon.sched : Alarm, Sched;
import sparkles.event_horizon.scope_ : protect, withScope;

version (linux)
    import sparkles.event_horizon.cgroup : CgroupRun, CgroupTier, EvidenceJob,
        TreeEvidence, cgroupCleanup, cgroupCreate, cgroupKill, evidenceCall,
        migrateInto;

static if (canSubmitOp!(DefaultBackend, OpWaitid))  :

/**
Runs `argv` under full supervision (SPEC §13.5–§13.8). Guarantees:

$(UL
    $(LI both output streams are piped (stderr via `mergeStdout` when so
        configured) so they can always be drained;)
    $(LI a fresh process group exists regardless of
        `ProcessConfig.newProcessGroup`, and on Linux a run cgroup where the
        host delegates one (§13.7 tiers);)
    $(LI non-null `stdinBytes` upgrades an inherit stdin to a pipe, is fed
        fully, and closed for EOF;)
    $(LI spawn failure creates no child, emits no event, and returns
        `end == spawnFailed` with `spawnError`;)
    $(LI the first timeout/cancel trigger wins the reported `ProcessEnd`;
        TERM (+CONT) goes to the process group, KILL follows one monotonic
        grace; natural exit during grace suppresses the kill;)
    $(LI both pipes reach a terminal state and the child's reap right is
        consumed exactly once — or proven lost — on every path, including
        surrounding-scope cancellation, which is delivered only after
        cleanup and the final published event;)
    $(LI exactly one `exited` event, only after both streams are terminal
        and the reap; no callback runs after `supervise` returns;)
    $(LI the final sample runs before the reap, so a just-exited root stays
        observable; sampling never runs on the loop thread.)
)

Non-zero exit is data (`status`), never an `IoError`. Every callback runs
synchronously on the original supervising fiber.
*/
IoResult!SupervisedProcessResult supervise(ref Sched s,
    scope const(char[])[] argv,
    in SupervisedProcessConfig cfg = SupervisedProcessConfig(),
    scope const(ubyte)[] stdinBytes = null,
    scope ProcessEventSink onEvent = null)
    => superviseImpl(s, argv, cfg, stdinBytes, onEvent, null);

// ── vocabulary ──────────────────────────────────────────────────────────────

private enum TreeState : ubyte
{
    live,
    graceArmed,
    waitPopulated,
    waited,
    detached,
    detachedDrained,
    killQueued,
    killSettled,
    killFailedAwaitRoot,
    drainDone,
}

private enum GraceKind : ubyte
{
    none,
    natural,
    fallback,
    requested,
}

private enum ControlState : ubyte
{
    running,
    frozen,
    tearingDownEmergency,
}

private enum RootObserverState : ubyte
{
    notAdmitted,
    initializing,
    inFlight,
    observed,
    laneOwned,
    lost,
    failed,
}

private enum SamplerState : ubyte
{
    notAdmitted,
    initializing,
    skipped,
    running,
    finalRequested,
    acked,
    exited,
}

private enum FinalSampleMode : ubyte
{
    full,
    cgroupOnly,
}

/// The one-shot clocks; each armed at most once per run.
private enum ClockKind : ubyte
{
    timeout,
    grace,
    descendant,
    fallback,
    drain,
    detachDrain,
}

/// The level-triggered command bits (SPEC §13.7 mailbox rule).
private enum Pending : uint
{
    timeoutExpired = 1 << 0,
    graceExpired = 1 << 1,
    descendantExpired = 1 << 2,
    fallbackExpired = 1 << 3,
    drainExpired = 1 << 4,
    detachDrainExpired = 1 << 5,
    sampleReady = 1 << 6,
    samplerAck = 1 << 7,
    samplerExited = 1 << 8,
    evidenceEmpty = 1 << 9,
    evidenceFailed = 1 << 10,
}

private struct ClockSlot
{
    Alarm alarm;
    Duration after;
    uint epoch;
    bool requested;
    bool armed;
    bool fired;
}

private enum RelayKind : ubyte
{
    bytes,
    streamEof,
    readError,
    rootObserved,
    rootLost,
    rootFailed,
    workerDefect,
    wake,
}

/// Worker-to-supervisor messages. Workers never invoke application code.
private struct RelayMessage
{
    RelayKind kind;
    ProcessStream stream;
    SharedBuffer!(ubyte, 512) bytes;
    IoError error;
    ExitStatus status;
    Throwable defect;
}

package alias RelayTestHook = void delegate(RelayKind kind);

/// One supervised run's state: frame-resident, mutated by the supervising
/// fiber (and, for the ledger, by the sampler's accepted job).
private struct Run
{
    ChildProcess* child;
    Sched* sched;
    BlockingPool* pool;
    version (linux)
    {
        CgroupRun cgroup;
        bool cgroupOwned;   /// the run owns a directory with the kill capability
        bool migrated;      /// the root moved into the run cgroup
    }
    int processGroup;       /// pinned by the WNOWAIT zombie until the reap
    bool collect;
    size_t collectCap;
    bool stdoutTruncated, stderrTruncated;

    ProcessEnd end = ProcessEnd.exited;
    bool endDecided;
    bool termSent;
    ReapOutcome reap;
    ExitStatus status;
    ExitStatus observedStatus;

    SharedBuffer!(ubyte, 256) stdout_;
    SharedBuffer!(ubyte, 256) stderr_;

    TreeSampler sampler;
    ProcessResourceUsage lastUsage;
    MonoTime startedAt;

    // control plane
    ControlState control;
    TreeState tree;
    GraceKind grace;
    uint treeEpoch;
    bool stdoutFinished, stderrFinished;
    bool stdoutForced, stderrForced;
    RootObserverState observer;
    IoError observerError;
    SamplerState samplerState;
    bool samplerAcked;   /// sticky: the final sample was folded (the state moves on to `exited`)
    FinalSampleMode finalMode;
    uint pending;
    uint[ClockKind.max + 1] pendingEpoch;
    uint evidenceEpoch;
    ClockSlot[ClockKind.max + 1] clocks;
    Alarm sampleAlarm;
    Alarm probeAlarm;

    FiberContext* clockCtx, samplerCtx, stdinCtx, stdoutCtx, stderrCtx,
        observerCtx, evidenceCtx;
    bool stopClock, stopSampler, stopStdin, stopEvidence, evidenceActive;

    KillOutcome pgidKill, cgroupKillOutcome;
    bool killExecuted;
    bool terminationDegraded;
    IoError terminationError;
    bool residualDegraded;
    IoError residualError;
    bool eofForced;
    bool cleanupLeaked;

    IoError operationError;
    bool hasOperationError;
    bool cancelledLatched;
    bool internalAdmissionCancel;
    Throwable secondaryDefect;  /// a defect after the first: recorded, never rethrown
    uint secondaryDefectCount;

    Channel!(RelayMessage, 32) relay;
    ProcessEventSink sink;
    Throwable sinkDefect;
    LineFramer stdoutFramer, stderrFramer;
    Duration sampleInterval;
    SharedBuffer!(ubyte, 256) stdinCopy;

    /// A worker's blocking relay publication (never application code).
    bool publish(ref Sched s, RelayMessage msg)
        => !relay.put(s, move(msg)).hasError;

    /// A worker's wake token: best-effort, level-triggered by the bits.
    void wake() @safe nothrow
    {
        RelayMessage token = {kind: RelayKind.wake};
        cast(void) relay.tryPut(move(token));
    }

    version (unittest)
    {
        int* signalAttempts;
        RelayTestHook beforeHandle;
    }

    bool streamsTerminal() const @safe pure nothrow @nogc
        => stdoutFinished && stderrFinished;

    bool rootResolved() const @safe pure nothrow @nogc
        => observer == RootObserverState.observed
            || observer == RootObserverState.lost
            || observer == RootObserverState.failed;

    bool treeResolved() const @safe pure nothrow @nogc
        => tree == TreeState.waited || tree == TreeState.detachedDrained
            || tree == TreeState.drainDone;

    bool terminal() const @safe pure nothrow @nogc
        => streamsTerminal && rootResolved && treeResolved;

    bool killIssued() const @safe pure nothrow @nogc
        => tree == TreeState.killQueued || tree == TreeState.killSettled
            || tree == TreeState.killFailedAwaitRoot || tree == TreeState.drainDone;
}

// ── pure helpers (unit-tested) ──────────────────────────────────────────────

private void decideEnd(ref Run run, ProcessEnd which) @safe pure nothrow @nogc
{
    if (!run.endDecided)
    {
        run.endDecided = true;
        run.end = which;
    }
}

private bool waitLostReapRight(in IoError error) @safe pure nothrow @nogc
    => error.errnoValue == ECHILD;

private bool transientProcessError(in IoError error) @safe pure nothrow @nogc
    => error.errnoValue == EINTR || error.errnoValue == EAGAIN
        || error.errnoValue == ENOBUFS;

private bool retryProcessError(in IoError error, uint attempts) @safe pure nothrow @nogc
    => transientProcessError(error) && attempts < 8;

/// The exactly-once `exited` event needs both streams terminal and the reap
/// right consumed or proven lost — never a zero-initialized status.
private bool canPublishExited(ReapOutcome reap, bool stdoutFinished,
    bool stderrFinished) @safe pure nothrow @nogc
    => reap != ReapOutcome.notApplicable && stdoutFinished && stderrFinished;

/// The public telemetry truth table (SPEC §13.7): pgid failure is
/// degradation in every tier, even when `cgroup.kill` succeeded.
private void combineKill(in KillOutcome pgid, in KillOutcome cgroup,
    bool cgroupOwned, out bool degraded, out IoError error) @safe pure nothrow @nogc
{
    static bool bad(in KillOutcome o) @safe pure nothrow @nogc
        => o.kind == KillResult.failed || o.kind == KillResult.targetAbsent;

    degraded = false;
    if (bad(pgid))
    {
        degraded = true;
        error = IoError(pgid.errnoValue, OpKind.none, IoErrorStage.submit,
            "process-group SIGKILL failed");
        return;
    }
    if (cgroupOwned && bad(cgroup))
    {
        degraded = true;
        error = IoError(cgroup.errnoValue, OpKind.none, IoErrorStage.submit,
            "cgroup.kill failed");
    }
}

private IoResult!void validateConfig(in SupervisedProcessConfig cfg)
    @safe pure nothrow @nogc
{
    static bool finiteNonNegative(Duration d) @safe pure nothrow @nogc
        => d >= Duration.zero && d != Duration.max;

    if (cfg.residualPolicy > ResidualPolicy.detach)
        return ioErr!void(EINVAL, OpKind.none, IoErrorStage.setup,
            "residualPolicy is not a declared enumerator");
    if (!finiteNonNegative(cfg.timeout) || !finiteNonNegative(cfg.terminateGrace)
        || !finiteNonNegative(cfg.sampleInterval) || !finiteNonNegative(cfg.outputGrace)
        || !finiteNonNegative(cfg.killDrainWindow))
        return ioErr!void(EINVAL, OpKind.none, IoErrorStage.setup,
            "durations must be finite and non-negative");
    return ioOk();
}

private shared uint runCounter;

// ── signals (bounded syscalls; the supervisor is the only caller) ───────────

private KillOutcome signalGroup(ref Run run, int signal) @trusted nothrow
{
    import core.stdc.errno : errno;
    import core.sys.posix.signal : kill_ = kill;

    if (run.processGroup <= 0)
        return KillOutcome(KillResult.notAttempted, 0);
    version (unittest)
        if (run.signalAttempts !is null)
            ++*run.signalAttempts;
    if (kill_(-run.processGroup, signal) == 0)
        return KillOutcome(KillResult.delivered, 0);
    const err = errno;
    // The root-only fallback never proves the tree terminated.
    if (run.child.pid > 0)
        cast(void) kill_(run.child.pid, signal);
    return KillOutcome(err == ESRCH ? KillResult.targetAbsent : KillResult.failed, err);
}

/// The graceful request: TERM, then CONT so a stopped tree can act on it.
private void sendTerm(ref Run run) @trusted nothrow
{
    if (run.termSent)
        return;
    run.termSent = true;
    cast(void) signalGroup(run, SIGTERM);
    cast(void) signalGroup(run, SIGCONT);
}

// ── the run ─────────────────────────────────────────────────────────────────

package IoResult!SupervisedProcessResult superviseImpl(ref Sched s,
    scope const(char[])[] argv,
    in SupervisedProcessConfig cfg,
    scope const(ubyte)[] stdinBytes,
    scope ProcessEventSink onEvent,
    scope RelayTestHook beforeHandle,
    int* signalAttempts = null) @trusted
{
    import core.atomic : atomicOp;

    SupervisedProcessResult result;

    // ① pure validation, before any resource exists.
    auto valid = validateConfig(cfg);
    if (valid.hasError)
        return ioErr!SupervisedProcessResult(valid.error);

    // ② the reap must never depend on a resource acquired after the child
    // exists: the shared pool and this scheduler's inbox waker come first.
    auto poolGot = sharedBlockingPool();
    if (poolGot.hasError)
        return ioErr!SupervisedProcessResult(poolGot.error);
    auto pool = poolGot.value;
    auto prepared = pool.prepare(s);
    if (prepared.hasError)
        return ioErr!SupervisedProcessResult(prepared.error);

    Run run;
    run.sched = &s;
    run.pool = pool;
    run.collect = cfg.collectOutput;
    run.collectCap = cfg.maxCapturedBytes;
    run.sink = onEvent;
    run.stdoutFramer.maxLineBytes = cfg.maxLineBytes;
    run.stderrFramer.maxLineBytes = cfg.maxLineBytes;
    version (unittest)
    {
        run.signalAttempts = signalAttempts;
        run.beforeHandle = beforeHandle;
    }

    // ③ the run cgroup (Linux): created before the child, degraded — never
    // failed — when the host refuses; a partial creation still owns cleanup.
    version (linux)
    {
        const runId = atomicOp!"+="(runCounter, 1);
        auto created = cgroupCreate(s, pool, run.cgroup, runId);
        if (created.hasError)
            return ioErr!SupervisedProcessResult(created.error);
        run.cgroupOwned = run.cgroup.canKill;
        // Capability negotiation, after the probe and before the child.
        if (cfg.residualPolicy == ResidualPolicy.wait && !run.cgroupOwned)
        {
            if (run.cgroup.dirCreated)
                cast(void) cgroupCleanup(s, pool, run.cgroup, 10.msecs);
            return ioErr!SupervisedProcessResult(EOPNOTSUPP, OpKind.none,
                IoErrorStage.setup, "ResidualPolicy.wait needs an owned cgroup");
        }
    }
    else
    {
        if (cfg.residualPolicy == ResidualPolicy.wait)
            return ioErr!SupervisedProcessResult(EOPNOTSUPP, OpKind.none,
                IoErrorStage.setup, "ResidualPolicy.wait needs an owned cgroup");
    }

    // ④ spawn: supervise owns the group (§13.7) and pipes both streams
    // (§13.5) so they can always be drained.
    ProcessConfig spawnCfg = cfg.process;
    spawnCfg.newProcessGroup = true;
    spawnCfg.stdoutSpec = StdioSpec(StdioMode.pipe);
    spawnCfg.stderrSpec = cfg.process.stderrSpec.mode == StdioMode.mergeStdout
        ? cfg.process.stderrSpec : StdioSpec(StdioMode.pipe);
    if (stdinBytes !is null && spawnCfg.stdinSpec.mode == StdioMode.inherit)
        spawnCfg.stdinSpec = StdioSpec(StdioMode.pipe);

    auto spawned = spawnProcess(argv, spawnCfg);
    if (spawned.hasError)
    {
        version (linux)
            if (run.cgroup.dirCreated)
                cast(void) cgroupCleanup(s, pool, run.cgroup, 10.msecs);
        result.end = ProcessEnd.spawnFailed;
        result.spawnError = spawned.error;
        return ioOk(move(result));
    }
    auto child = spawned.value;
    version (unittest)
        testLastSupervisedPid = child.pid;
    run.child = &child;
    run.processGroup = child.pid;
    run.startedAt = MonoTime.currTime;
    scope (exit)
    {
        child.stdinW.close();
        child.stdoutR.close();
        child.stderrR.close();
        child.ptyMaster.close();
    }

    // ⑤ post-spawn migration, inline: a `cgroup.procs` write is a bounded
    // in-memory kernfs operation, and its latency is what closes the race
    // against a child that forks at once — a pool round trip would lose
    // it. Failure degrades sampling (and `wait`) only; the pgid is armed.
    version (linux)
    {
        if (run.cgroupOwned)
        {
            const err = migrateInto(run.cgroup, child.pid);
            run.migrated = err == 0;
            if (err != 0 && cfg.residualPolicy == ResidualPolicy.wait)
            {
                run.residualDegraded = true;
                run.residualError = IoError(err, OpKind.none, IoErrorStage.submit,
                    "cgroup: migration into the run cgroup failed");
            }
        }
        run.sampler.anchor(child.pid, run.migrated ? &run.cgroup : null);
    }
    else
        run.sampler.anchor(child.pid, null);
    scope (exit) run.sampler.finish();

    if (stdinBytes !is null)
        run.stdinCopy ~= stdinBytes;
    run.sampleInterval = cfg.sampleInterval;

    // The shield: an isProtected node on THIS frame; workers spawn beneath
    // it and only this fiber ends them. The unlink hook's context is this
    // frame too, which outlives the scope's join.
    CancelContext shield;
    shield.isProtected = true;
    auto unlinkShield = delegate() nothrow {
        if (shield.parent !is null)
            shield.parent.removeChild(&shield);
    };

    auto rp = &run;
    auto childP = &child;
    auto schedP = &s;
    const policy = cfg.residualPolicy;
    const config = cfg;

    Throwable primaryDefect;
    IoError admissionError;
    bool admissionFailed;

    auto outcome = withScope!((ref sc) {
        sc.node.addChild(&shield);
        sc.onExit(unlinkShield);

        // ── workers: heap objects, never frame captures ──────────────────
        // A fiber body that captured a nested function's parameters would
        // read a dead frame once that function returned (dip1000 infers the
        // delegate parameter `scope` and allocates no closure); bound
        // methods of heap objects carry their state explicitly.
        void spawnWorker(FiberContext** slot, void delegate() body)
        {
            auto shell = new WorkerShell(rp, schedP, slot, body);
            if (!sc.spawnShielded(&shell.run, &shield))
                admissionFailed = true;
        }

        // The root observer: exactly one WNOWAIT wait, ever.
        rp.observer = RootObserverState.initializing;
        spawnWorker(&rp.observerCtx, &(new ObserverWorker(rp, schedP, childP)).run);
        if (admissionFailed)
            rp.observer = RootObserverState.notAdmitted;

        if (!admissionFailed)
        {
            if (childP.stdoutR.fd >= 0)
                spawnWorker(&rp.stdoutCtx,
                    &(new DrainWorker(rp, schedP, childP.stdoutR, ProcessStream.stdout_)).run);
            else
                rp.stdoutFinished = true;
        }
        if (!admissionFailed)
        {
            if (childP.stderrR.fd >= 0)
                spawnWorker(&rp.stderrCtx,
                    &(new DrainWorker(rp, schedP, childP.stderrR, ProcessStream.stderr_)).run);
            else
                rp.stderrFinished = true;
        }

        // The stdin worker: sole owner of the descriptor while it lives.
        if (childP.stdinW.fd >= 0 && !admissionFailed)
            spawnWorker(&rp.stdinCtx, &(new StdinWorker(rp, schedP, childP)).run);

        // The clock: six one-shot alarms, armed on request, ring-free.
        if (!admissionFailed)
            spawnWorker(&rp.clockCtx, &(new ClockWorker(rp, schedP)).run);

        // The sampler: every sample on the public lane; final sample by
        // request/ack, before the reap.
        if (!admissionFailed)
        {
            rp.samplerState = SamplerState.initializing;
            spawnWorker(&rp.samplerCtx, &(new SamplerWorker(rp, schedP)).run);
            if (admissionFailed)
                rp.samplerState = SamplerState.notAdmitted;
        }

        // The evidence observer (`wait` only): bounded event-fd waits on the
        // public lane, reported with the epoch they were issued under.
        version (linux)
            if (policy == ResidualPolicy.wait && !admissionFailed)
                spawnWorker(&rp.evidenceCtx, &(new EvidenceWorker(rp, schedP)).run);

        // ── the supervisor: a nested struct so its methods may call each
        // other in any order (nested functions cannot be forward-referenced)
        struct Ctl
        {
            void armClock(ClockKind kind, Duration after)
            {
                auto slot = &rp.clocks[kind];
                if (slot.requested)
                    return; // one arming site per clock per run
                slot.after = after;
                slot.epoch = rp.treeEpoch;
                slot.requested = true;
                if (rp.clockCtx !is null)
                    schedP.wake(rp.clockCtx);
            }

            void stopStdinWorker()
            {
                rp.stopStdin = true;
                if (rp.stdinCtx !is null)
                    interruptFiber(rp.stdinCtx, Interrupt(InterruptKind.cancelled));
                else
                    childP.stdinW.close();
            }

            void invoke(ProcessEvent ev)
            {
                if (rp.sink is null || rp.sinkDefect !is null)
                    return;
                try
                    rp.sink(ev);
                catch (Throwable defect)
                {
                    rp.sinkDefect = defect;
                    rp.sink = null;
                    requestTermination(ProcessEnd.cancelled);
                }
            }

            void rememberError(IoError error)
            {
                if (!rp.hasOperationError)
                {
                    rp.hasOperationError = true;
                    rp.operationError = error;
                }
            }

            /// The hard kill: pgid SIGKILL, then `cgroup.kill` on the lane;
            /// recorded outcomes; the settle or the live-root block.
            void executeHardKill()
            {
                rp.tree = TreeState.killQueued;
                ++rp.treeEpoch;
                rp.killExecuted = true;
                rp.pgidKill = signalGroup(*rp, SIGKILL);
                version (linux)
                {
                    if (rp.cgroupOwned)
                    {
                        auto killed = cgroupKill(*schedP, rp.pool, rp.cgroup);
                        rp.cgroupKillOutcome = killed.hasError
                            ? KillOutcome(KillResult.failed, killed.error.errnoValue)
                            : KillOutcome(KillResult.delivered, 0);
                    }
                    combineKill(rp.pgidKill, rp.cgroupKillOutcome, rp.cgroupOwned,
                        rp.terminationDegraded, rp.terminationError);
                    const cgroupWorked = rp.cgroupOwned
                        && rp.cgroupKillOutcome.kind == KillResult.delivered;
                }
                else
                {
                    combineKill(rp.pgidKill, rp.cgroupKillOutcome, false,
                        rp.terminationDegraded, rp.terminationError);
                    enum cgroupWorked = false;
                }
                const pgidWorked = rp.pgidKill.kind == KillResult.delivered;
                if (!pgidWorked && !cgroupWorked && !rp.rootResolved)
                {
                    // No ownership boundary permits returning with a live root
                    // we could not kill: blocked pending its natural exit.
                    rp.tree = TreeState.killFailedAwaitRoot;
                    return;
                }
                settleKill();
            }

            void settleKill()
            {
                rp.tree = TreeState.killSettled;
                if (rp.streamsTerminal)
                    rp.tree = TreeState.drainDone;
                else
                    armClock(ClockKind.drain, config.killDrainWindow);
            }

            void fallbackEdge(IoError why)
            {
                if (!rp.residualDegraded)
                {
                    rp.residualDegraded = true;
                    rp.residualError = why;
                }
                rp.stopEvidence = true;
                if (rp.evidenceCtx !is null)
                    interruptFiber(rp.evidenceCtx, Interrupt(InterruptKind.cancelled));
                rp.tree = TreeState.graceArmed;
                rp.grace = GraceKind.fallback;
                ++rp.treeEpoch;
                if (rp.streamsTerminal)
                    executeHardKill();
                else
                    armClock(ClockKind.fallback, config.outputGrace);
            }

            void forceEof()
            {
                foreach (stream; [ProcessStream.stdout_, ProcessStream.stderr_])
                {
                    const isOut = stream == ProcessStream.stdout_;
                    if (isOut ? rp.stdoutFinished : rp.stderrFinished)
                        continue;
                    rp.eofForced = true;
                    if (isOut)
                    {
                        rp.stdoutFinished = rp.stdoutForced = true;
                        if (rp.stdoutCtx !is null)
                            interruptFiber(rp.stdoutCtx, Interrupt(InterruptKind.cancelled));
                    }
                    else
                    {
                        rp.stderrFinished = rp.stderrForced = true;
                        if (rp.stderrCtx !is null)
                            interruptFiber(rp.stderrCtx, Interrupt(InterruptKind.cancelled));
                    }
                }
                onStreamsTerminal();
            }

            void onStreamsTerminal()
            {
                if (!rp.streamsTerminal)
                    return;
                final switch (rp.tree)
                {
                case TreeState.graceArmed:
                    // The output grace ends with the output; a requested grace
                    // has nothing left to wait for once the root is resolved too.
                    if (rp.grace != GraceKind.requested || rp.rootResolved)
                        executeHardKill();
                    break;
                case TreeState.detached:
                    rp.tree = TreeState.detachedDrained;
                    ++rp.treeEpoch;
                    break;
                case TreeState.killSettled:
                    rp.tree = TreeState.drainDone;
                    break;
                case TreeState.live:
                case TreeState.waitPopulated:
                case TreeState.waited:
                case TreeState.detachedDrained:
                case TreeState.killQueued:
                case TreeState.killFailedAwaitRoot:
                case TreeState.drainDone:
                    break;
                }
            }

            void onRootObserved()
            {
                final switch (rp.tree)
                {
                case TreeState.live:
                    final switch (policy)
                    {
                    case ResidualPolicy.bounded:
                        if (rp.streamsTerminal)
                            executeHardKill();
                        else
                        {
                            rp.tree = TreeState.graceArmed;
                            rp.grace = GraceKind.natural;
                            ++rp.treeEpoch;
                            armClock(ClockKind.descendant, config.outputGrace);
                        }
                        break;
                    case ResidualPolicy.wait:
                        version (linux)
                        {
                            if (rp.residualDegraded || !rp.migrated)
                            {
                                fallbackEdge(rp.residualDegraded ? rp.residualError
                                    : IoError(EOPNOTSUPP, OpKind.none, IoErrorStage.setup,
                                        "the root never entered the run cgroup"));
                                break;
                            }
                            rp.tree = TreeState.waitPopulated;
                            ++rp.treeEpoch;
                            rp.evidenceEpoch = rp.treeEpoch;
                            rp.evidenceActive = true;
                            if (rp.evidenceCtx !is null)
                                schedP.wake(rp.evidenceCtx);
                        }
                        else
                            assert(0, "wait was refused at negotiation");
                        break;
                    case ResidualPolicy.detach:
                        rp.tree = TreeState.detached;
                        ++rp.treeEpoch;
                        if (rp.streamsTerminal)
                            rp.tree = TreeState.detachedDrained;
                        else
                            armClock(ClockKind.detachDrain, config.killDrainWindow);
                        break;
                    }
                    break;
                case TreeState.killFailedAwaitRoot:
                    settleKill();
                    break;
                case TreeState.graceArmed:
                    if (rp.grace == GraceKind.requested && rp.streamsTerminal)
                        executeHardKill(); // TERM delivered, output over, root gone
                    break;
                case TreeState.waitPopulated:
                case TreeState.waited:
                case TreeState.detached:
                case TreeState.detachedDrained:
                case TreeState.killQueued:
                case TreeState.killSettled:
                case TreeState.drainDone:
                    break;
                }
            }

            /// The one transition owner for every termination trigger.
            void requestTermination(ProcessEnd cause)
            {
                decideEnd(*rp, cause);
                stopStdinWorker();
                final switch (rp.tree)
                {
                case TreeState.live:
                case TreeState.waitPopulated:
                case TreeState.waited:
                case TreeState.detached:
                    break; // signal below
                case TreeState.graceArmed:
                    if (rp.grace == GraceKind.requested)
                        return; // first trigger wins: no re-arm, no duplicate TERM
                    break;
                case TreeState.detachedDrained:
                case TreeState.killQueued:
                case TreeState.killSettled:
                case TreeState.killFailedAwaitRoot:
                case TreeState.drainDone:
                    return; // the kill is scheduled or done: no signalling
                }
                if (rp.tree == TreeState.waitPopulated)
                {
                    rp.stopEvidence = true;
                    if (rp.evidenceCtx !is null)
                        interruptFiber(rp.evidenceCtx, Interrupt(InterruptKind.cancelled));
                }
                sendTerm(*rp);
                rp.tree = TreeState.graceArmed;
                rp.grace = GraceKind.requested;
                ++rp.treeEpoch;
                // Nothing observable remains once the root is resolved and
                // the output is over: the requested grace would only idle.
                if (rp.rootResolved && rp.streamsTerminal)
                    executeHardKill();
                else
                    armClock(ClockKind.grace, config.terminateGrace);
            }

            void processPending()
            {
                while (rp.pending != 0)
                {
                    const bits = rp.pending;
                    rp.pending = 0; // clear before processing: a re-set survives
                    if (bits & Pending.timeoutExpired)
                        requestTermination(ProcessEnd.timedOut);
                    if ((bits & Pending.graceExpired) && rp.tree == TreeState.graceArmed
                        && rp.pendingEpoch[ClockKind.grace] == rp.treeEpoch)
                        executeHardKill();
                    if ((bits & Pending.descendantExpired) && rp.tree == TreeState.graceArmed
                        && rp.grace == GraceKind.natural
                        && rp.pendingEpoch[ClockKind.descendant] == rp.treeEpoch)
                        executeHardKill();
                    if ((bits & Pending.fallbackExpired) && rp.tree == TreeState.graceArmed
                        && rp.grace == GraceKind.fallback
                        && rp.pendingEpoch[ClockKind.fallback] == rp.treeEpoch)
                        executeHardKill();
                    if ((bits & Pending.drainExpired) && rp.tree == TreeState.killSettled)
                        forceEof();
                    if ((bits & Pending.detachDrainExpired) && rp.tree == TreeState.detached)
                        forceEof();
                    if ((bits & Pending.evidenceEmpty) && rp.tree == TreeState.waitPopulated
                        && rp.evidenceEpoch == rp.treeEpoch)
                    {
                        rp.tree = TreeState.waited;
                        ++rp.treeEpoch;
                        rp.stopEvidence = true;
                    }
                    if ((bits & Pending.evidenceFailed) && rp.tree == TreeState.waitPopulated)
                        fallbackEdge(IoError(5 /* EIO */, OpKind.none, IoErrorStage.completion,
                            "cgroup populated evidence unavailable"));
                    if (bits & Pending.sampleReady)
                    {
                        ProcessEvent ev;
                        ev.kind = ProcessEventKind.sample;
                        ev.usage = rp.lastUsage;
                        invoke(ev);
                    }
                }
            }

            void recordSecondary(Throwable defect)
            {
                if (rp.secondaryDefect is null)
                    rp.secondaryDefect = defect;
                ++rp.secondaryDefectCount;
            }

            void handle(RelayMessage msg)
            {
                version (unittest)
                    if (rp.beforeHandle !is null && rp.control == ControlState.running)
                        rp.beforeHandle(msg.kind);
                final switch (msg.kind)
                {
                case RelayKind.bytes:
                    const isOut = msg.stream == ProcessStream.stdout_;
                    if (isOut ? rp.stdoutForced : rp.stderrForced)
                        break; // late bytes of a forced stream are ignored
                    const view = msg.bytes[];
                    if (rp.collect)
                    {
                        auto buf = isOut ? &rp.stdout_ : &rp.stderr_;
                        auto cut = isOut ? &rp.stdoutTruncated : &rp.stderrTruncated;
                        const cap = rp.collectCap;
                        if (cap == 0 || buf.length + view.length <= cap)
                            *buf ~= view;
                        else
                        {
                            if (buf.length < cap)
                                *buf ~= view[0 .. cap - buf.length];
                            *cut = true;
                        }
                    }
                    (isOut ? rp.stdoutFramer : rp.stderrFramer).push(view, msg.stream,
                        (ProcessStream stream, const(ubyte)[] bytes, bool terminated,
                            bool truncated) {
                            ProcessEvent ev;
                            ev.kind = ProcessEventKind.line;
                            ev.line = ProcessLine(stream, bytes, terminated, truncated);
                            invoke(ev);
                        });
                    break;
                case RelayKind.streamEof:
                    if (msg.stream == ProcessStream.stdout_ ? rp.stdoutForced : rp.stderrForced)
                        break;
                    (msg.stream == ProcessStream.stdout_ ? rp.stdoutFramer : rp.stderrFramer)
                        .flushEof(msg.stream, (ProcessStream stream, const(ubyte)[] bytes,
                            bool terminated, bool truncated) {
                            ProcessEvent ev;
                            ev.kind = ProcessEventKind.line;
                            ev.line = ProcessLine(stream, bytes, terminated, truncated);
                            invoke(ev);
                        });
                    if (msg.stream == ProcessStream.stdout_)
                        rp.stdoutFinished = true;
                    else
                        rp.stderrFinished = true;
                    onStreamsTerminal();
                    break;
                case RelayKind.readError:
                    rememberError(msg.error);
                    if (msg.stream == ProcessStream.stdout_)
                        rp.stdoutFinished = true;
                    else
                        rp.stderrFinished = true;
                    requestTermination(ProcessEnd.cancelled);
                    onStreamsTerminal();
                    break;
                case RelayKind.rootObserved:
                    onRootObserved();
                    break;
                case RelayKind.rootLost:
                    // The reap right is gone and numeric identity is not pinned:
                    // clear it now; the terminal sequence skips the reap.
                    rememberError(msg.error);
                    rp.reap = ReapOutcome.lostToExternalReaper;
                    childP.pid = -1;
                    rp.processGroup = -1;
                    requestTermination(ProcessEnd.cancelled);
                    onRootObserved();
                    break;
                case RelayKind.rootFailed:
                    rememberError(msg.error);
                    requestTermination(ProcessEnd.cancelled);
                    onRootObserved();
                    break;
                case RelayKind.workerDefect:
                    // The first primary defect wins; one arriving during the
                    // terminal or emergency phase is recorded, never rethrown
                    // — a throw there would skip the worker stop and hang
                    // the join.
                    if (rp.control != ControlState.running)
                    {
                        recordSecondary(msg.defect);
                        break;
                    }
                    throw msg.defect;
                case RelayKind.wake:
                    break;
                }
                processPending();
            }

            IoResult!RelayMessage takeRelay()
            {
                if (!rp.cancelledLatched)
                    return rp.relay.take(*schedP);
                return protect!(() => rp.relay.take(*schedP))(*schedP);
            }

            /// The sampler-finalization barrier (§13.8): before the reap.
            void finalizeSampler(FinalSampleMode mode)
            {
                final switch (rp.samplerState)
                {
                case SamplerState.notAdmitted:
                case SamplerState.skipped:
                case SamplerState.exited:
                case SamplerState.acked:
                    rp.sampler.usage.samplingDegraded |= !rp.samplerAcked;
                    return;
                case SamplerState.initializing:
                    rp.samplerState = SamplerState.skipped;
                    rp.sampler.usage.samplingDegraded = true;
                    return;
                case SamplerState.finalRequested:
                    break;
                case SamplerState.running:
                    rp.samplerState = SamplerState.finalRequested;
                    rp.finalMode = mode;
                    if (rp.samplerCtx !is null)
                        schedP.wake(rp.samplerCtx);
                    break;
                }
                // Level-triggered: the ack bit is published before its wake
                // token, so a check-then-park cannot lose an early ack.
                while (rp.samplerState == SamplerState.finalRequested)
                {
                    auto next = protect!(() => rp.relay.take(*schedP))(*schedP);
                    if (next.hasError)
                        break;
                    handle(move(next.value));
                }
                // The sampler's exit follows its ack at once; the ack is
                // the sticky bit, the state is the lifecycle.
                if (!rp.samplerAcked)
                    rp.sampler.usage.samplingDegraded = true;
            }

            /// Consumes or diagnoses the reap right (the §13.7 result table).
            void reapRoot()
            {
                if (rp.reap != ReapOutcome.notApplicable)
                    return; // consumed or proven lost already
                if (rp.observer == RootObserverState.lost)
                    return; // recorded once, at observation time
                uint retries;
                for (;;)
                {
                    auto waited = .wait(*schedP, *childP);
                    if (waited.hasValue)
                    {
                        rp.status = waited.value;
                        rp.reap = ReapOutcome.reaped;
                        rp.processGroup = -1;
                        return;
                    }
                    if (waitLostReapRight(waited.error))
                    {
                        rememberError(waited.error);
                        rp.reap = ReapOutcome.lostToExternalReaper;
                        childP.pid = -1;
                        rp.processGroup = -1;
                        return;
                    }
                    if (retryProcessError(waited.error, retries++))
                    {
                        cast(void) sleep(*schedP, 1.msecs);
                        continue;
                    }
                    // Any other in-ring error: the identity is still pinned, so
                    // the termination-critical lane consumes it.
                    auto fallback = waitPidOnLane(*schedP, childP.pid);
                    if (fallback.hasValue)
                    {
                        rp.status = fallback.value;
                        rp.reap = ReapOutcome.reaped;
                        childP.pid = -1;
                        rp.processGroup = -1;
                        return;
                    }
                    if (waitLostReapRight(fallback.error))
                    {
                        rememberError(fallback.error);
                        rp.reap = ReapOutcome.lostToExternalReaper;
                        childP.pid = -1;
                        rp.processGroup = -1;
                        return;
                    }
                    // A reap that can neither succeed nor prove loss has no
                    // ownership boundary: no ordinary return exists.
                    schedP.fatal(fallback.error);
                }
            }

            void stopWorkers()
            {
                rp.stopClock = true;
                if (rp.clockCtx !is null)
                    schedP.wake(rp.clockCtx);
                rp.stopSampler = true;
                if (rp.samplerCtx !is null)
                    schedP.wake(rp.samplerCtx);
                rp.stopEvidence = true;
                stopStdinWorker();
                cancelTree(&shield, Interrupt(InterruptKind.cancelled));
            }

            /// The one authoritative terminal sequence (§13.7), under protect.
            void terminalSequence()
            {
                rp.control = ControlState.frozen;
                ++rp.treeEpoch;
                finalizeSampler(rp.observer == RootObserverState.lost
                    ? FinalSampleMode.cgroupOnly : FinalSampleMode.full);
                reapRoot();
                stopWorkers();
            }

            /// Lane-owned root observation for the emergency path when no
            /// observer is in flight: finite WNOHANG probes with alarm backoff.
            void observeRootOnLane()
            {
                rp.observer = RootObserverState.laneOwned;
                Duration backoff = 10.msecs;
                for (;;)
                {
                    ProbeJob job = {pid: childP.pid};
                    auto ran = rp.pool.runMandatory(*schedP, &probeCall, &job);
                    if (ran.hasError)
                        schedP.fatal(ran.error);
                    final switch (job.kind)
                    {
                    case ProbeKind.observed:
                        rp.observedStatus = job.status;
                        rp.observer = RootObserverState.observed;
                        return;
                    case ProbeKind.lost:
                        rp.observer = RootObserverState.lost;
                        rp.reap = ReapOutcome.lostToExternalReaper;
                        childP.pid = -1;
                        rp.processGroup = -1;
                        return;
                    case ProbeKind.fatal:
                        schedP.fatal(IoError(job.errnoValue, OpKind.waitid,
                            IoErrorStage.completion, "root probe failed"));
                    case ProbeKind.pending:
                    case ProbeKind.retry:
                        break;
                    }
                    schedP.armAlarm(rp.probeAlarm, backoff);
                    while (!rp.probeAlarm.fired)
                        schedP.park();
                    schedP.disarmAlarm(rp.probeAlarm);
                    rp.probeAlarm.reset();
                    backoff = backoff * 2 > 1.seconds ? 1.seconds : backoff * 2;
                }
            }

            /// The pre-join emergency phase: a defect or a post-spawn admission
            /// failure. Protected as its first statement.
            void emergencyTeardown()
            {
                cast(void) protect!(() {
                    try
                        emergencyPhase();
                    catch (Throwable secondary)
                        recordSecondary(secondary);
                    // Unconditional: the join can only end once the owner
                    // has ended its shielded workers.
                    stopWorkers();
                    return 0;
                })(*schedP);
            }

            void emergencyPhase()
            {
                {
                    rp.control = ControlState.tearingDownEmergency;
                    ++rp.treeEpoch;
                    stopStdinWorker();
                    if (!rp.killIssued)
                        executeHardKill();
                    // Root observation before the sample: a delivered signal is
                    // not an observed exit.
                    final switch (rp.observer)
                    {
                    case RootObserverState.observed:
                    case RootObserverState.lost:
                    case RootObserverState.failed:
                    case RootObserverState.laneOwned:
                        break;
                    case RootObserverState.inFlight:
                        while (!rp.rootResolved)
                        {
                            auto next = rp.relay.take(*schedP);
                            if (next.hasError)
                                break;
                            if (next.value.kind == RelayKind.workerDefect)
                                continue; // a second defect: recorded, not rethrown
                            if (next.value.kind == RelayKind.rootObserved
                                || next.value.kind == RelayKind.rootLost
                                || next.value.kind == RelayKind.rootFailed)
                            {
                                if (next.value.kind == RelayKind.rootLost)
                                {
                                    rp.reap = ReapOutcome.lostToExternalReaper;
                                    childP.pid = -1;
                                    rp.processGroup = -1;
                                }
                                break;
                            }
                        }
                        break;
                    case RootObserverState.notAdmitted:
                    case RootObserverState.initializing:
                        observeRootOnLane();
                        break;
                    }
                    if (rp.observer == RootObserverState.failed)
                        rp.observer = RootObserverState.laneOwned, observeRootOnLane();
                    finalizeSampler(rp.observer == RootObserverState.lost
                        ? FinalSampleMode.cgroupOnly : FinalSampleMode.full);
                    reapRoot();
                }
            }


        }

        Ctl ctl;
        if (admissionFailed)
        {
            // A post-spawn admission failure: the scope's sweep has latched
            // on this fiber; the emergency phase is protected and owns the
            // child until its reap right is consumed or proven lost.
            rp.internalAdmissionCancel = true;
            ctl.emergencyTeardown();
            return;
        }
        if (config.timeout > Duration.zero)
            ctl.armClock(ClockKind.timeout, config.timeout);

        try
        {
            while (!rp.terminal)
            {
                auto next = ctl.takeRelay();
                if (next.hasError)
                {
                    // An outer cancellation: the run ends through the
                    // ordinary machine, protected from here on.
                    rp.cancelledLatched = true;
                    ctl.requestTermination(ProcessEnd.cancelled);
                    ctl.processPending();
                    continue;
                }
                ctl.handle(move(next.value));
            }
            cast(void) protect!(() { ctl.terminalSequence(); return 0; })(*schedP);
        }
        catch (Throwable defect)
        {
            primaryDefect = defect;
            ctl.emergencyTeardown();
        }
    })(s);

    // ── the shared post-join finalization, under protect ──────────────────
    if (admissionFailed)
        admissionError = IoError(ENOBUFS, OpKind.none, IoErrorStage.submit,
            "supervision worker unavailable");

    auto ctx = s.currentContext();
    auto sP = &s;
    auto rp3 = &run;
    cast(void) protect!(() {
        version (linux)
        {
            if (rp3.cgroup.dirCreated)
            {
                // Under `detach` the residual may legitimately outlive the
                // run: no populated wait, a truthful leak report instead.
                const populatedWait = cfg.residualPolicy == ResidualPolicy.detach
                    ? Duration.zero : 2.seconds;
                auto cleaned = cgroupCleanup(*sP, rp3.pool, rp3.cgroup, populatedWait);
                rp3.cleanupLeaked = cleaned.hasError || cleaned.value;
            }
        }
        rp3.lastUsage = rp3.sampler.usage;
        rp3.lastUsage.wallTime = MonoTime.currTime - rp3.startedAt;
        if (canPublishExited(rp3.reap, rp3.stdoutFinished, rp3.stderrFinished)
            && rp3.sink !is null && rp3.sinkDefect is null)
        {
            ProcessEvent exited;
            exited.kind = ProcessEventKind.exited;
            exited.status = rp3.status;
            exited.end = rp3.end;
            exited.reap = rp3.reap;
            try
                rp3.sink(exited);
            catch (Throwable defect)
                rp3.sinkDefect = defect;
        }
        return 0;
    })(s);

    // Latch resolution: an outer cancellation keeps first-trigger
    // precedence; the scope's own admission sweep is consumed here, and
    // only that — a shutdown/deadline/other direct interrupt is never
    // cleared merely because no ancestor reports cancelling.
    if (run.internalAdmissionCancel && ctx.interrupted
        && ctx.pendingInterrupt.kind == InterruptKind.cancelled
        && !enclosingCancelling(ctx))
        ctx.interrupted = false;

    if (primaryDefect !is null)
    {
        if (run.sinkDefect !is null && run.sinkDefect !is primaryDefect)
        {
            // The first primary wins; the sink's is recorded, not rethrown.
        }
        throw primaryDefect;
    }
    if (run.sinkDefect !is null)
        throw run.sinkDefect;
    if (admissionFailed)
        return ioErr!SupervisedProcessResult(admissionError);
    if (run.hasOperationError)
        return ioErr!SupervisedProcessResult(run.operationError);
    if (outcome.hasError)
        return ioErr!SupervisedProcessResult(ECANCELED, OpKind.none,
            IoErrorStage.completion, "supervision worker failed");

    result.end = run.end;
    result.status = run.status;
    result.reap = run.reap;
    result.usage = run.lastUsage;
    result.stdout_ = move(run.stdout_);
    result.stderr_ = move(run.stderr_);
    result.truncatedLines = run.stdoutFramer.truncatedLines
        + run.stderrFramer.truncatedLines;
    result.stdoutTruncated = run.stdoutTruncated;
    result.stderrTruncated = run.stderrTruncated;
    result.eofForced = run.eofForced;
    result.terminationDegraded = run.terminationDegraded;
    result.terminationError = run.terminationError;
    result.residualPolicyDegraded = run.residualDegraded;
    result.residualPolicyError = run.residualError;
    result.cgroupCleanupLeaked = run.cleanupLeaked;
    return ioOk(move(result));
}

/// Whether any enclosing cancel context of `f` is cancelling.
private bool enclosingCancelling(in FiberContext* f) @trusted pure nothrow @nogc
{
    for (const(CancelContext)* n = f.cancelContext; n !is null; n = n.parent)
        if (n.state == CancelContext.State.cancelling)
            return true;
    return false;
}

// ── workers ─────────────────────────────────────────────────────────────────
// Each worker is a heap object; its `run` method is the fiber body. Bodies
// relay raw completions and publish command bits — never application code.

/// Records the worker's context in its registry slot for its lifetime and
/// turns an escaping defect into a relay message.
private final class WorkerShell
{
    Run* rp;
    Sched* s;
    FiberContext** slot;
    void delegate() body;

    this(Run* rp, Sched* s, FiberContext** slot, void delegate() body)
    {
        this.rp = rp;
        this.s = s;
        this.slot = slot;
        this.body = body;
    }

    void run()
    {
        *slot = s.currentContext();
        scope (exit) *slot = null;
        try
            body();
        catch (Throwable defect)
        {
            RelayMessage msg;
            msg.kind = RelayKind.workerDefect;
            msg.defect = defect;
            cast(void) rp.relay.tryPut(move(msg));
        }
    }
}

private final class ObserverWorker
{
    Run* rp;
    Sched* s;
    ChildProcess* child;

    this(Run* rp, Sched* s, ChildProcess* child)
    {
        this.rp = rp;
        this.s = s;
        this.child = child;
    }

    void run()
    {
        if (rp.observer != RootObserverState.initializing)
            return; // the emergency owner took the observation over
        rp.observer = RootObserverState.inFlight;
        uint retries;
        for (;;)
        {
            auto observed = observeExit(*s, child.pid);
            RelayMessage msg;
            if (observed.hasValue)
            {
                rp.observedStatus = observed.value;
                rp.observer = RootObserverState.observed;
                msg.kind = RelayKind.rootObserved;
                msg.status = observed.value;
                cast(void) rp.publish(*s, move(msg));
                return;
            }
            if (retryProcessError(observed.error, retries++))
            {
                cast(void) sleep(*s, 1.msecs);
                continue;
            }
            if (waitLostReapRight(observed.error))
            {
                rp.observer = RootObserverState.lost;
                msg.kind = RelayKind.rootLost;
            }
            else
            {
                rp.observer = RootObserverState.failed;
                msg.kind = RelayKind.rootFailed;
            }
            rp.observerError = observed.error;
            msg.error = observed.error;
            cast(void) rp.publish(*s, move(msg));
            return;
        }
    }
}

private final class DrainWorker
{
    Run* rp;
    Sched* s;
    FileHandle f;
    ProcessStream stream;

    this(Run* rp, Sched* s, FileHandle f, ProcessStream stream)
    {
        this.rp = rp;
        this.s = s;
        this.f = f;
        this.stream = stream;
    }

    void run()
    {
        uint retries;
        for (;;)
        {
            SharedBuffer!(ubyte, 512) chunk;
            chunk.length = 512;
            auto got = read(f, move(chunk));
            chunk = move(got.buf);
            RelayMessage msg;
            msg.stream = stream;
            if (got.res.hasError)
            {
                if (got.res.error.errnoValue == ECANCELED)
                    return; // an owner interrupt: forced EOF or teardown
                if (retryProcessError(got.res.error, retries++))
                {
                    cast(void) sleep(*s, 1.msecs);
                    continue;
                }
                msg.kind = RelayKind.readError;
                msg.error = got.res.error;
                cast(void) rp.publish(*s, move(msg));
                return;
            }
            retries = 0;
            if (got.res.value == 0)
            {
                msg.kind = RelayKind.streamEof;
                cast(void) rp.publish(*s, move(msg));
                return;
            }
            msg.kind = RelayKind.bytes;
            msg.bytes ~= chunk[][0 .. got.res.value];
            if (!rp.publish(*s, move(msg)))
                return;
        }
    }
}

private final class StdinWorker
{
    Run* rp;
    Sched* s;
    ChildProcess* child;

    this(Run* rp, Sched* s, ChildProcess* child)
    {
        this.rp = rp;
        this.s = s;
        this.child = child;
    }

    void run()
    {
        size_t offset;
        while (offset < rp.stdinCopy.length && !rp.stopStdin)
        {
            SharedBuffer!(ubyte, 512) piece;
            const n = (rp.stdinCopy.length - offset) < 512
                ? rp.stdinCopy.length - offset : 512;
            piece ~= rp.stdinCopy[offset .. offset + n];
            auto sent = write(child.stdinW, move(piece));
            if (sent.res.hasError || sent.res.value == 0)
                break;
            offset += sent.res.value;
        }
        child.stdinW.close(); // exactly-once invalidation of the view
    }
}

private final class ClockWorker
{
    Run* rp;
    Sched* s;

    this(Run* rp, Sched* s)
    {
        this.rp = rp;
        this.s = s;
    }

    void run()
    {
        scope (exit)
            foreach (ref slot; rp.clocks)
                if (slot.armed)
                    s.disarmAlarm(slot.alarm);
        while (!rp.stopClock)
        {
            foreach (kind, ref slot; rp.clocks)
            {
                if (slot.requested && !slot.armed)
                {
                    s.armAlarm(slot.alarm, slot.after);
                    slot.armed = true;
                }
                if (slot.armed && !slot.fired && slot.alarm.fired)
                {
                    slot.fired = true;
                    slot.armed = false;
                    if (rp.control != ControlState.running)
                        continue; // terminal awareness: no late commands
                    final switch (cast(ClockKind) kind)
                    {
                    case ClockKind.timeout:
                        // The end decision is taken AT expiry, before any
                        // later trigger can be observed first.
                        decideEnd(*rp, ProcessEnd.timedOut);
                        rp.pending |= Pending.timeoutExpired;
                        break;
                    case ClockKind.grace:
                        rp.pending |= Pending.graceExpired;
                        break;
                    case ClockKind.descendant:
                        rp.pending |= Pending.descendantExpired;
                        break;
                    case ClockKind.fallback:
                        rp.pending |= Pending.fallbackExpired;
                        break;
                    case ClockKind.drain:
                        rp.pending |= Pending.drainExpired;
                        break;
                    case ClockKind.detachDrain:
                        rp.pending |= Pending.detachDrainExpired;
                        break;
                    }
                    rp.pendingEpoch[kind] = slot.epoch;
                    rp.wake();
                }
            }
            if (rp.stopClock)
                break;
            s.park();
        }
    }
}

private final class SamplerWorker
{
    Run* rp;
    Sched* s;

    this(Run* rp, Sched* s)
    {
        this.rp = rp;
        this.s = s;
    }

    bool takeOne(bool final_)
    {
        SampleJob job = {sampler: &rp.sampler,
            cgroupOnly: final_ && rp.finalMode == FinalSampleMode.cgroupOnly};
        auto ran = rp.pool.run(*s, &sampleCall, &job);
        if (ran.hasError)
        {
            rp.sampler.usage.samplingDegraded = true;
            return false;
        }
        rp.lastUsage = rp.sampler.usage;
        rp.lastUsage.wallTime = MonoTime.currTime - rp.startedAt;
        return job.merged;
    }

    void run()
    {
        scope (exit)
        {
            rp.samplerState = SamplerState.exited;
            rp.pending |= Pending.samplerExited;
            rp.wake();
        }
        if (rp.samplerState != SamplerState.initializing)
            return; // the owner decided `skipped` before we ran
        rp.samplerState = SamplerState.running;

        cast(void) takeOne(false); // the initial fold: no event, as before
        while (!rp.stopSampler && rp.samplerState == SamplerState.running)
        {
            if (rp.sampleInterval > Duration.zero)
            {
                s.armAlarm(rp.sampleAlarm, rp.sampleInterval);
                while (!rp.sampleAlarm.fired && !rp.stopSampler
                    && rp.samplerState == SamplerState.running)
                    s.park();
                s.disarmAlarm(rp.sampleAlarm);
                rp.sampleAlarm.reset();
            }
            else
                while (!rp.stopSampler && rp.samplerState == SamplerState.running)
                    s.park();
            if (rp.stopSampler || rp.samplerState != SamplerState.running)
                break;
            if (takeOne(false))
            {
                rp.pending |= Pending.sampleReady;
                rp.wake();
            }
        }
        if (rp.samplerState == SamplerState.finalRequested)
        {
            // Exactly one final sample, then the ack — the bit before the
            // wake token, so a check-then-park cannot lose it.
            cast(void) protect!(() { cast(void) takeOne(true); return 0; })(*s);
            rp.samplerAcked = true;
            rp.samplerState = SamplerState.acked;
            rp.pending |= Pending.samplerAck;
            rp.wake();
        }
    }
}

version (linux)
private final class EvidenceWorker
{
    Run* rp;
    Sched* s;

    this(Run* rp, Sched* s)
    {
        this.rp = rp;
        this.s = s;
    }

    void run()
    {
        while (!rp.stopEvidence && !rp.evidenceActive)
            s.park();
        if (rp.stopEvidence)
            return;
        const epoch = rp.evidenceEpoch;
        uint unknowns, refusals;
        Duration backoff = 5.msecs;
        while (!rp.stopEvidence)
        {
            EvidenceJob job = {run: &rp.cgroup, slice: 500.msecs};
            auto ran = rp.pool.run(*s, &evidenceCall, &job);
            if (ran.hasError)
            {
                if (ran.error.errnoValue != EAGAIN || ++refusals > 8)
                    break; // finite budget → the fallback edge
                cast(void) sleep(*s, backoff);
                backoff = backoff * 2 > 500.msecs ? 500.msecs : backoff * 2;
                continue;
            }
            if (job.evidence == TreeEvidence.empty)
            {
                rp.pending |= Pending.evidenceEmpty;
                rp.evidenceEpoch = epoch;
                rp.wake();
                return;
            }
            if (job.evidence == TreeEvidence.unknown && ++unknowns >= 3)
                break;
        }
        if (rp.stopEvidence)
            return;
        rp.pending |= Pending.evidenceFailed;
        rp.wake();
    }
}

// ── pool jobs ───────────────────────────────────────────────────────────────

private struct SampleJob
{
    TreeSampler* sampler;
    bool cgroupOnly;
    bool merged;
}

private void sampleCall(void* p) nothrow
{
    auto job = cast(SampleJob*) p;
    version (linux)
    {
        if (job.cgroupOnly)
            job.sampler.usage.samplingDegraded = true; // pid identity is gone
    }
    job.merged = job.sampler.sample();
}

/// One non-consuming `WNOHANG` probe (a finite lane job); the tagged result
/// keeps "still running" apart from an observation.
private enum ProbeKind : ubyte
{
    pending,
    observed,
    lost,
    retry,
    fatal,
}

private struct ProbeJob
{
    int pid;
    ProbeKind kind;
    ExitStatus status;
    int errnoValue;
}

private void probeCall(void* p) nothrow
{
    import core.stdc.errno : errno;
    import core.sys.posix.signal : siginfo_t;
    import core.sys.posix.sys.wait : WEXITED, WNOHANG, WNOWAIT, idtype_t, waitid;

    auto job = cast(ProbeJob*) p;
    siginfo_t info;
    const rc = waitid(idtype_t.P_PID, job.pid, &info, WEXITED | WNOWAIT | WNOHANG);
    if (rc != 0)
    {
        job.errnoValue = errno;
        job.kind = errno == ECHILD ? ProbeKind.lost
            : (errno == EINTR ? ProbeKind.retry : ProbeKind.fatal);
        return;
    }
    version (linux)
    {
        const pid = info._sifields._kill.si_pid;
        const code = info.si_code;
        const status = info._sifields._sigchld.si_status;
    }
    else
    {
        const pid = info.si_pid;
        const code = info.si_code;
        const status = info.si_status;
    }
    if (pid == 0)
    {
        job.kind = ProbeKind.pending;
        return;
    }
    enum CLD_EXITED = 1, CLD_KILLED = 2, CLD_DUMPED = 3;
    if (pid != job.pid || (code != CLD_EXITED && code != CLD_KILLED && code != CLD_DUMPED))
    {
        job.kind = ProbeKind.fatal;
        job.errnoValue = EINVAL;
        return;
    }
    job.kind = ProbeKind.observed;
    job.status = code == CLD_EXITED ? ExitStatus(false, status) : ExitStatus(true, status);
}

version (unittest)
{
    /// The pid of the last supervised root — for no-zombie postconditions.
    package int testLastSupervisedPid;
}
// ── supervised runs (SPEC §13.5–§13.8) ──────────────────────────────────────

version (unittest)
{
    import core.thread : Thread;

    import sparkles.event_horizon.sched : SchedOptions, schedOrSkip;
    import sparkles.test_runner.skip : skipTest;

    /// Event collector bound as a `ProcessEventSink`.
    private struct EventLog
    {
        ProcessEvent[] events;

        private void put(in ProcessEvent ev)
        {
            events ~= ev;
            if (ev.kind == ProcessEventKind.line)
                lineBytes ~= ev.line.bytes.dup; // the spec-mandated copy
        }

        const(ubyte)[][] lineBytes;

        /// `@trusted`: the collector provably outlives every supervised run
        /// that borrows its method (the test frame parks on `s.run`).
        ProcessEventSink sink() @trusted pure nothrow @nogc
            => &put;
    }

    /// Skips unless this is the only test thread: the shared pool's daemon
    /// workers are not test threads and do not count.
    private void requireSingleThreadedProcess() @system
    {
        foreach (t; Thread.getAll())
            if (t !is Thread.getThis() && !t.isDaemon)
                skipTest("mutates process-global descriptors/signals; run with -t 1");
    }

    /// The no-zombie postcondition: the reap right for `pid` is gone.
    private bool reapRightConsumed(int pid) @trusted
    {
        import core.stdc.errno : errno;
        import core.sys.posix.sys.wait : WNOHANG, waitpid;

        int raw;
        return waitpid(pid, &raw, WNOHANG) < 0 && errno == ECHILD;
    }
}

@("supervise.naturalExitLinesCollectAndUsage")
@safe
unittest
{
    Sched s;
    schedOrSkip(s);

    auto r = s.run(() {
        EventLog log;
        auto got = supervise(s,
            ["sh", "-c", `printf 'a\nb\n'`],
            SupervisedProcessConfig(), null, log.sink());
        assert(got.hasValue, got.hasError ? got.error.context : "");

        // Exactly one exited event, after the two framed lines.
        assert(log.events.length == 3);
        assert(log.events[0].kind == ProcessEventKind.line
            && log.lineBytes[0] == cast(const(ubyte)[]) "a"
            && log.events[0].line.terminated);
        assert(log.lineBytes[1] == cast(const(ubyte)[]) "b");
        assert(log.events[2].kind == ProcessEventKind.exited);
        assert(log.events[2].end == ProcessEnd.exited);
        assert(log.events[2].status.ok);

        // Raw collection keeps exact bytes including terminators.
        assert(got.value.stdout_[] == cast(const(ubyte)[]) "a\nb\n");
        assert(got.value.stderr_.length == 0);
        assert(got.value.end == ProcessEnd.exited);
        assert(got.value.status.ok);

        // Final accounting is always present; Linux observes the tree via
        // /proc, Darwin stubs to sampled == false until §13.8 lands there.
        assert(got.value.usage.wallTime > Duration.zero);
        assert(got.value.usage.sampleCount >= 1);
        version (linux)
            assert(got.value.usage.sampled);
        else
            assert(!got.value.usage.sampled);
    });
    assert(!r.hasError);
}

@("supervise.finalSampleOccursBeforeReap")
@safe
unittest
{
    Sched s;
    schedOrSkip(s);

    auto r = s.run(() {
        SupervisedProcessConfig cfg;
        cfg.sampleInterval = Duration.zero;
        auto got = supervise(s, ["true"], cfg);
        assert(got.hasValue, got.hasError ? got.error.context : "");
        version (linux)
            assert(got.value.usage.sampleCount >= 2,
                "initial and final pre-reap samples both see the root");
        else
            assert(!got.value.usage.sampled);
    });
    assert(!r.hasError);
}

@("supervise.internalDefectRunsTheEmergencyPhaseAndReaps")
@safe
unittest
{
    import core.time : MonoTime, seconds;

    Sched s;
    schedOrSkip(s);
    const before = MonoTime.currTime;
    auto r = s.run(() {
        // A defect in the supervisor's own handling (injected before the
        // first bytes message) enters the pre-join emergency phase: kill,
        // root observation, final sample, reap — then the rethrow.
        bool threw;
        SupervisedProcessConfig cfg;
        cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
        try
            cast(void) superviseImpl(s, ["sh", "-c",
                "echo out; echo err >&2; sleep 30"], cfg, null, null,
                (RelayKind kind) {
                    if (kind == RelayKind.bytes)
                        throw new Exception("injected supervisor defect");
                });
        catch (Exception e)
            threw = e.msg == "injected supervisor defect";
        assert(threw, "the defect is rethrown after cleanup");
        assert(reapRightConsumed(testLastSupervisedPid), "no zombie");
    });
    assert(!r.hasError);
    assert(MonoTime.currTime - before < 2.seconds,
        "the emergency phase does not strand workers or the child");
}

@("supervise.nullSinkNaturalExitIsPrompt")
@safe
unittest
{
    import core.time : MonoTime, seconds;

    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        SupervisedProcessConfig cfg;
        cfg.terminateGrace = 5.seconds;
        const before = MonoTime.currTime;
        auto got = supervise(s, ["true"], cfg, null, null);
        assert(got.hasValue, got.hasError ? got.error.context : "");
        assert(got.value.end == ProcessEnd.exited && got.value.status.ok);
        assert(MonoTime.currTime - before < 1.seconds,
            "natural exit never waits out terminateGrace");
    });
    assert(!r.hasError);
}

@("supervise.callbacksStayOnSupervisorAndDefectsStillCleanUp")
@system
unittest
{
    import core.time : MonoTime, seconds;

    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        auto supervisor = s.currentContext();
        size_t exitedCount;
        auto normal = supervise(s, ["sh", "-c", "printf 'line\\n'"],
            SupervisedProcessConfig(), null, (in ProcessEvent ev) {
                assert(s.currentContext() is supervisor,
                    "every callback runs on the original supervising fiber");
                if (ev.kind == ProcessEventKind.exited)
                    ++exitedCount;
            });
        assert(normal.hasValue && exitedCount == 1);

        foreach (throwOn; [ProcessEventKind.line, ProcessEventKind.exited])
        {
            size_t callsAfterDefect;
            bool threw;
            const script = throwOn == ProcessEventKind.line
                ? "echo started; sleep 30" : "true";
            const before = MonoTime.currTime;
            try
                cast(void) supervise(s,
                    ["sh", "-c", script],
                    SupervisedProcessConfig(), null, (in ProcessEvent ev) {
                        assert(s.currentContext() is supervisor);
                        if (callsAfterDefect != 0)
                            assert(0, "a known-failing sink was invoked again");
                        if (ev.kind == throwOn)
                        {
                            ++callsAfterDefect;
                            throw new Exception("sink defect");
                        }
                    });
            catch (Exception e)
            {
                threw = e.msg == "sink defect";
            }
            assert(threw, "the callback defect is rethrown after cleanup");
            assert(MonoTime.currTime - before < 2.seconds,
                "callback failure did not strand termination or reap");
        }

        auto after = supervise(s, ["true"]);
        assert(after.hasValue && after.value.status.ok,
            "the scheduler remains usable after callback defects");
    });
    assert(!r.hasError);
}

@("supervise.finalCallbackCannotRetriggerTermination")
@safe
unittest
{
    import core.time : msecs;
    import sparkles.event_horizon.io : sleep;

    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        // No timeout: no producer trigger exists, so a yielding final
        // callback must observe — and keep — the natural outcome, with zero
        // signal attempts (no retermination path may fire from the sink).
        int signalAttempts;
        int attemptsAtPublish = -1;
        ProcessEnd yieldedEnd;
        auto yielded = superviseImpl(s, ["true"], SupervisedProcessConfig(),
            null, (in ProcessEvent ev) {
                if (ev.kind == ProcessEventKind.exited)
                {
                    assert(!sleep(s, 150.msecs).hasError);
                    yieldedEnd = ev.end;
                    attemptsAtPublish = signalAttempts;
                }
            }, null, &signalAttempts);
        assert(yielded.hasValue);
        assert(yielded.value.end == ProcessEnd.exited
            && yieldedEnd == ProcessEnd.exited,
            "a yielding final callback cannot mutate a terminal run");
        assert(attemptsAtPublish >= 0 && signalAttempts == attemptsAtPublish,
            "no signal is sent after the final event was published");

        // With a deadline that may legitimately expire while the run is
        // still observing under parallel load, whichever trigger won before
        // the publish stays frozen: publish-time and return-time ends agree.
        signalAttempts = 0;
        ProcessEnd racedEnd;
        SupervisedProcessConfig raced;
        raced.timeout = 100.msecs;
        auto racedResult = superviseImpl(s, ["true"], raced, null,
            (in ProcessEvent ev) {
                if (ev.kind == ProcessEventKind.exited)
                {
                    assert(!sleep(s, 150.msecs).hasError);
                    racedEnd = ev.end;
                }
            }, null, &signalAttempts);
        assert(racedResult.hasValue);
        assert(racedResult.value.end == racedEnd,
            "joined producers cannot mutate the outcome after publish");

        signalAttempts = 0;
        attemptsAtPublish = -1;
        ProcessEnd thrownEnd;
        bool threw;
        try
            cast(void) superviseImpl(s, ["true"], SupervisedProcessConfig(), null,
                (in ProcessEvent ev) {
                    if (ev.kind == ProcessEventKind.exited)
                    {
                        thrownEnd = ev.end;
                        attemptsAtPublish = signalAttempts;
                        throw new Exception("final sink defect");
                    }
                }, null, &signalAttempts);
        catch (Exception e)
            threw = e.msg == "final sink defect";
        assert(threw && thrownEnd == ProcessEnd.exited);
        assert(signalAttempts == attemptsAtPublish,
            "throwing final callback only rethrows after terminal cleanup");
    });
    assert(!r.hasError);
}

@("supervise.framingMatrix")
@safe
unittest
{
    Sched s;
    schedOrSkip(s);

    auto r = s.run(() {
        // One read burst carrying: plain LF, CRLF, an empty line, and a
        // binary tail with an embedded NUL and NO terminator.
        enum src = `printf 'one\ntwo\r\n\nx\0y'`;
        EventLog log;
        auto got = supervise(s, ["sh", "-c", src], SupervisedProcessConfig(),
            null, log.sink());
        assert(got.hasValue, got.error.context);

        const(ubyte)[][] lines;
        bool[] terminatedFlags;
        foreach (i, ev; log.events)
            if (ev.kind == ProcessEventKind.line
                && ev.line.stream == ProcessStream.stdout_)
            {
                lines ~= log.lineBytes[i].dup; // retained copy, per spec
                terminatedFlags ~= ev.line.terminated;
            }
        assert(lines.length == 4, "LF/CRLF/empty/final-partial");
        assert(lines[0] == cast(const(ubyte)[]) "one" && terminatedFlags[0]);
        assert(lines[1] == cast(const(ubyte)[]) "two" && terminatedFlags[1],
            "CR stripped");
        assert(lines[2].length == 0 && terminatedFlags[2], "empty line");
        assert(lines[3] == cast(const(ubyte)[]) "x\0y" && !terminatedFlags[3],
            "embedded NUL preserved; EOF fragment unterminated");
        assert(got.value.stdout_[] == cast(const(ubyte)[]) "one\ntwo\r\n\nx\0y",
            "raw bytes keep original terminators");

        // A line split across kernel reads is invisible as chunking.
        EventLog splitLog;
        auto split = supervise(s,
            ["sh", "-c", `printf hel; sleep 0.15; printf 'lo world\n'`],
            SupervisedProcessConfig(), null, splitLog.sink());
        assert(split.hasValue);
        size_t helloLines;
        foreach (ev; splitLog.events)
            if (ev.kind == ProcessEventKind.line
                && ev.line.bytes == cast(const(ubyte)[]) "hello world")
                ++helloLines;
        assert(helloLines == 1, "split writes frame as ONE line");
    });
    assert(!r.hasError);
}

@("supervise.lineCapTruncatesOnceAndReports")
@safe
unittest
{
    Sched s;
    schedOrSkip(s);

    auto r = s.run(() {
        EventLog log;
        SupervisedProcessConfig cfg;
        cfg.maxLineBytes = 8;
        cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
        auto got = supervise(s, ["sh", "-c",
            `printf 'short\nthisisaverylongline\nend\n'`], cfg, null, log.sink());
        assert(got.hasValue, got.hasError ? got.error.context : "");

        size_t lines;
        foreach (i, ev; log.events)
            if (ev.kind == ProcessEventKind.line)
            {
                final switch (lines++)
                {
                    case 0:
                        assert(log.lineBytes[0] == cast(const(ubyte)[]) "short"
                            && ev.line.terminated && !ev.line.truncated);
                        break;
                    case 1:
                        // The head goes out once: `terminated` is false (no
                        // terminator was seen) and `truncated` tells it apart
                        // from an EOF fragment.
                        assert(log.lineBytes[1] == cast(const(ubyte)[]) "thisisav"
                            && !ev.line.terminated && ev.line.truncated);
                        break;
                    case 2:
                        assert(log.lineBytes[2] == cast(const(ubyte)[]) "end"
                            && ev.line.terminated && !ev.line.truncated);
                        break;
                }
            }
        assert(lines == 3, "the rest of the over-cap line is discarded");
        assert(got.value.truncatedLines == 1);
        // Raw collection is independent of framing: exact bytes, no cut.
        assert(got.value.stdout_[]
            == cast(const(ubyte)[]) "short\nthisisaverylongline\nend\n");
        assert(!got.value.stdoutTruncated);
    });
    assert(!r.hasError);
}

@("supervise.captureCapStopsAccumulationAndReports")
@safe
unittest
{
    Sched s;
    schedOrSkip(s);

    auto r = s.run(() {
        EventLog log;
        SupervisedProcessConfig cfg;
        cfg.maxCapturedBytes = 4;
        cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
        auto got = supervise(s, ["sh", "-c", `printf 'abcdef\n'; printf err >&2`],
            cfg, null, log.sink());
        assert(got.hasValue, got.hasError ? got.error.context : "");
        assert(got.value.stdout_[] == cast(const(ubyte)[]) "abcd",
            "collection stops exactly at the cap");
        assert(got.value.stdoutTruncated);
        assert(got.value.stderr_[] == cast(const(ubyte)[]) "err"
            && !got.value.stderrTruncated, "the cap is per stream");
        // Events are unaffected by the collection cap.
        assert(log.lineBytes[0] == cast(const(ubyte)[]) "abcdef");
        assert(got.value.truncatedLines == 0);
    });
    assert(!r.hasError);
}

@("supervise.longLineIsLinear")
@safe
unittest
{
    import core.time : MonoTime, seconds;

    Sched s;
    schedOrSkip(s);

    auto r = s.run(() {
        // 512 KiB of one line, no terminator: the quadratic rescan this
        // framer replaced took 5.6 s here; linear is tens of milliseconds.
        // The bound is generous so parallel test load cannot fail it.
        SupervisedProcessConfig cfg;
        cfg.sampleInterval = Duration.zero;
        cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
        size_t fragments, fragmentBytes;
        const before = MonoTime.currTime;
        auto got = supervise(s, ["sh", "-c",
            "head -c 524288 /dev/zero | tr '\\0' 'a'"], cfg, null,
            (in ProcessEvent ev) {
                if (ev.kind == ProcessEventKind.line)
                {
                    ++fragments;
                    fragmentBytes = ev.line.bytes.length;
                    assert(!ev.line.terminated && !ev.line.truncated);
                }
            });
        assert(got.hasValue, got.hasError ? got.error.context : "");
        assert(fragments == 1 && fragmentBytes == 524_288);
        assert(got.value.stdout_.length == 524_288);
        assert(MonoTime.currTime - before < 3.seconds, "framing must be O(n)");
    });
    assert(!r.hasError);
}

@("supervise.streamsAreIndependentMergeIsTotalOrder")
@safe
unittest
{
    Sched s;
    schedOrSkip(s);

    auto r = s.run(() {
        // Separate pipes: per-stream ORDER holds; no cross-stream claim.
        EventLog log;
        auto separate = supervise(s,
            ["sh", "-c",
            `for i in 1 2 3; do echo "o$i"; sleep 0.02; echo "e$i" 1>&2; sleep 0.02; done`],
            SupervisedProcessConfig(), null, log.sink());
        assert(separate.hasValue);
        assert(separate.value.stderr_.length > 0);
        const(char)[][] outLines;
        foreach (i, ev; log.events)
            if (ev.kind == ProcessEventKind.line)
            {
                if (ev.line.stream == ProcessStream.stdout_)
                    outLines ~= cast(const(char)[]) log.lineBytes[i].dup;
                else
                    assert((cast(const(char)[]) log.lineBytes[i])[0] == 'e');
            }
        assert(outLines == ["o1", "o2", "o3"], "per-stream order");

        // mergeStdout: one pipe, one total order, all reported as stdout_.
        ProcessConfig merged;
        merged.stderrSpec = StdioSpec(StdioMode.mergeStdout);
        EventLog mergedLog;
        auto together = supervise(s,
            ["sh", "-c", "echo o1; echo e1 1>&2; echo o2"],
            SupervisedProcessConfig(merged), null, mergedLog.sink());
        assert(together.hasValue);
        assert(together.value.stderr_.length == 0);
        assert(together.value.stdout_[]
            == cast(const(ubyte)[]) "o1\ne1\no2\n", "output order kept");
        const(char)[][] mergedOrder;
        foreach (i, ev; mergedLog.events)
            if (ev.kind == ProcessEventKind.line)
            {
                mergedOrder ~= cast(const(char)[]) mergedLog.lineBytes[i].dup;
                assert(ev.line.stream == ProcessStream.stdout_,
                    "merged lines report as stdout_");
            }
        assert(mergedOrder == ["o1", "e1", "o2"]);
    });
    assert(!r.hasError);
}

@("supervise.collectOutputControlsAccumulationOnly")
@safe
unittest
{
    Sched s;
    schedOrSkip(s);

    auto r = s.run(() {
        EventLog log;
        SupervisedProcessConfig cfg;
        cfg.collectOutput = false;
        auto got = supervise(s, ["sh", "-c", "echo streamed"], cfg, null,
            log.sink());
        assert(got.hasValue);
        assert(got.value.stdout_.length == 0, "no accumulation requested");
        assert(got.value.stderr_.length == 0);

        size_t lineEvents;
        foreach (ev; log.events)
            if (ev.kind == ProcessEventKind.line)
                ++lineEvents;
        assert(lineEvents == 1, "events still flow");
    });
    assert(!r.hasError);
}

@("supervise.stdinFeedRoundTrip")
@safe
unittest
{
    Sched s;
    schedOrSkip(s);

    auto r = s.run(() {
        auto got = supervise(s, ["cat"], SupervisedProcessConfig(),
            cast(const(ubyte)[]) "fed through supervision");
        assert(got.hasValue, got.error.context);
        assert(got.value.status.ok);
        assert(got.value.stdout_[] == cast(const(ubyte)[]) "fed through supervision",
            "stdin fed fully, then EOF so cat could exit");
    });
    assert(!r.hasError);
}

@("supervise.spawnFailureEmitsNothing")
@safe
unittest
{
    Sched s;
    schedOrSkip(s);

    auto r = s.run(() {
        EventLog log;
        auto got = supervise(s, ["/definitely-not-a-binary-eh"],
            SupervisedProcessConfig(), null, log.sink());
        assert(got.hasValue);
        assert(got.value.end == ProcessEnd.spawnFailed);
        assert(got.value.spawnError.errnoValue == 2 /* ENOENT */);
        assert(log.events.length == 0, "no child, no exited event");
    });
    assert(!r.hasError);
}

@("supervise.timeoutTermExitsTheChild")
@safe
unittest
{
    import core.time : MonoTime, msecs, seconds;

    Sched s;
    schedOrSkip(s);

    auto r = s.run(() {
        EventLog log;
        SupervisedProcessConfig cfg;
        cfg.timeout = 80.msecs;
        cfg.terminateGrace = 500.msecs; // TERM wins well before any KILL
        cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
        const before = MonoTime.currTime;
        auto got = supervise(s, ["sleep", "30"], cfg, null, log.sink());
        assert(got.hasValue, got.error.context);
        const elapsed = MonoTime.currTime - before;

        assert(got.value.end == ProcessEnd.timedOut);
        assert(got.value.status.signaled && got.value.status.code == 15,
            "SIGTERM death decoded as data");
        assert(elapsed < 2.seconds, "the deadline ended the run promptly");

        bool sawExited;
        foreach (ev; log.events)
            if (ev.kind == ProcessEventKind.exited)
            {
                sawExited = true;
                assert(ev.end == ProcessEnd.timedOut);
            }
        assert(sawExited);
    });
    assert(!r.hasError);
}

@("supervise.graceExpiryEscalatesToKill")
@safe
unittest
{
    import core.time : MonoTime, msecs, seconds;

    Sched s;
    schedOrSkip(s);

    auto r = s.run(() {
        // Ignores TERM entirely, so the grace must expire into SIGKILL.
        EventLog log;
        SupervisedProcessConfig cfg;
        cfg.timeout = 60.msecs;
        cfg.terminateGrace = 120.msecs;
        cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
        const before = MonoTime.currTime;
        auto got = supervise(s,
            ["sh", "-c", `trap '' TERM; sleep 30`], cfg, null, log.sink());
        assert(got.hasValue, got.error.context);
        const elapsed = MonoTime.currTime - before;

        assert(got.value.end == ProcessEnd.timedOut);
        assert(got.value.status.signaled && got.value.status.code == 9,
            "grace expiry escalated to SIGKILL");
        assert(elapsed >= 180.msecs, "the grace actually ran");
        assert(elapsed < 5.seconds, "and did not linger");
    });
    assert(!r.hasError);
}

@("supervise.exitedRootStillTerminatesGroupHoldingPipe")
@safe
unittest
{
    import core.time : MonoTime, msecs, seconds;

    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        SupervisedProcessConfig cfg;
        cfg.timeout = 60.msecs;
        cfg.terminateGrace = 2.seconds;
        cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
        const before = MonoTime.currTime;
        auto got = supervise(s,
            ["sh", "-c", `{ sleep 30; } & exit 0`], cfg);
        assert(got.hasValue, got.hasError ? got.error.context : "");
        assert(got.value.end == ProcessEnd.timedOut);
        assert(got.value.status.ok,
            "the exited root keeps its real successful status");
        assert(MonoTime.currTime - before < 1.seconds,
            "TERM targets the private group while root remains waitable");
    });
    assert(!r.hasError);
}

@("supervise.exitedRootDescendantIgnoringTermGetsKilledAfterGrace")
@safe
unittest
{
    import core.time : MonoTime, msecs, seconds;

    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        SupervisedProcessConfig cfg;
        cfg.timeout = 50.msecs;
        cfg.terminateGrace = 100.msecs;
        cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
        const before = MonoTime.currTime;
        auto got = supervise(s, ["sh", "-c",
            `{ trap '' TERM; while :; do sleep 30; done; } & exit 0`], cfg);
        assert(got.hasValue, got.hasError ? got.error.context : "");
        const elapsed = MonoTime.currTime - before;
        assert(got.value.end == ProcessEnd.timedOut);
        assert(got.value.status.ok, "root status is not descendant status");
        assert(elapsed >= 140.msecs, "SIGTERM-ignoring descendant reached grace");
        assert(elapsed < 2.seconds,
            "SIGKILL still targets the private group after root exit");
    });
    assert(!r.hasError);
}

@("supervise.autoReapedRootStillCleansItsProcessGroup")
@system
unittest
{
    import core.sys.posix.signal : SIGCHLD, SIG_IGN, sigaction,
        sigaction_t, sigemptyset;
    import core.time : MonoTime, msecs, seconds;

    requireSingleThreadedProcess();
    sigaction_t ignored, previous;
    ignored.sa_handler = SIG_IGN;
    sigemptyset(&ignored.sa_mask);
    assert(sigaction(SIGCHLD, &ignored, &previous) == 0);

    Sched s;
    try
        schedOrSkip(s);
    catch (Throwable defect)
    {
        cast(void) sigaction(SIGCHLD, &previous, null);
        throw defect;
    }

    bool bounded, preservedEchild;
    auto r = s.run(() {
        SupervisedProcessConfig cfg;
        cfg.timeout = 50.msecs;
        cfg.terminateGrace = 100.msecs;
        cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
        const before = MonoTime.currTime;
        auto got = supervise(s, ["sh", "-c", "sleep 30 & exit 0"], cfg);
        bounded = MonoTime.currTime - before < 2.seconds;
        preservedEchild = got.hasError && got.error.errnoValue == 10;
    });
    const restored = sigaction(SIGCHLD, &previous, null);

    assert(restored == 0);
    assert(!r.hasError);
    assert(bounded && preservedEchild,
        "ECHILD still terminates/drains the saved process group promptly");
}

@("supervise.scopeCancellationLatchesThenConverges")
@safe
unittest
{
    import core.time : seconds;
    import sparkles.event_horizon.scope_ : JoinHandle, checkCancellation,
        withScope;

    Sched s;
    schedOrSkip(s);

    SupervisedProcessResult got;
    bool sawLine, returnedCleanly, latchAfterReturn;

    auto r = s.run(() {
        auto outcome = withScope!((ref outer) {
            JoinHandle!(void) h;
            outer.fork(h, () {
                EventLog log;
                SupervisedProcessConfig cfg;
                cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
                auto supervised = supervise(s,
                    ["sh", "-c", `echo started; sleep 30`], cfg, null,
                    (in ProcessEvent ev) {
                        if (ev.kind == ProcessEventKind.line)
                        {
                            sawLine = true;
                            outer.cancel(); // the trigger under test
                        }
                    });
                assert(supervised.hasValue, supervised.error.context);
                got = supervised.value;
                returnedCleanly = true;
                latchAfterReturn = checkCancellation(s).hasError;
                return ioOk();
            });
            // The fork's join collects the latched interrupt; nothing here
            // fails the outer scope.
            auto joined = h.join(s);
        })(s);
        assert(!outcome.hasError);
    });
    assert(!r.hasError);

    assert(sawLine && returnedCleanly, "supervise ran to its own conclusion");
    assert(got.end == ProcessEnd.cancelled);
    assert(got.usage.wallTime > Duration.zero);
    assert(latchAfterReturn,
        "the caller's cancellation was delivered only AFTER cleanup "
        ~ "and the final event (SPEC §13.5)");
}

@("supervise.cancellationDrainsAndFramesFinalFragment")
@safe
unittest
{
    import sparkles.event_horizon.scope_ : JoinHandle, withScope;

    Sched s;
    schedOrSkip(s);

    foreach (collect; [true, false])
    {
        SupervisedProcessResult got;
        bool sawFinal;
        auto r = s.run(() {
            auto outcome = withScope!((ref outer) {
                JoinHandle!void h;
                outer.fork(h, () {
                    SupervisedProcessConfig cfg;
                    cfg.collectOutput = collect;
                    cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
                    auto run = supervise(s, ["sh", "-c",
                        `trap 'printf final; exit 0' TERM; echo ready; while :; do sleep 1; done`],
                        cfg, null, (in ProcessEvent ev) {
                            if (ev.kind != ProcessEventKind.line)
                                return;
                            if (ev.line.bytes == cast(const(ubyte)[]) "ready")
                                outer.cancel();
                            if (ev.line.bytes == cast(const(ubyte)[]) "final")
                            {
                                sawFinal = true;
                                assert(!ev.line.terminated,
                                    "TERM output keeps EOF-fragment framing");
                            }
                        });
                    assert(run.hasValue, run.hasError ? run.error.context : "");
                    got = move(run.value);
                    return ioOk();
                });
                cast(void) h.join(s);
            })(s);
            assert(!outcome.hasError);
        });
        assert(!r.hasError);
        assert(got.end == ProcessEnd.cancelled && sawFinal);
        if (collect)
            assert(got.stdout_[] == cast(const(ubyte)[]) "ready\nfinal");
        else
            assert(got.stdout_.length == 0 && got.stderr_.length == 0,
                "collectOutput=false never accumulates cleanup bytes");
    }
}

@("supervise.externalCancellationStillEscalatesPastTerm")
@safe
unittest
{
    import core.time : MonoTime, msecs, seconds;
    import sparkles.event_horizon.scope_ : JoinHandle, withScope;

    Sched s;
    schedOrSkip(s);
    SupervisedProcessResult got;
    const before = MonoTime.currTime;
    auto r = s.run(() {
        auto outcome = withScope!((ref outer) {
            JoinHandle!void h;
            outer.fork(h, () {
                SupervisedProcessConfig cfg;
                cfg.terminateGrace = 100.msecs;
                cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
                auto run = supervise(s, ["sh", "-c",
                    `trap '' TERM; echo ready; while :; do sleep 30; done`],
                    cfg, null, (in ProcessEvent ev) {
                        if (ev.kind == ProcessEventKind.line)
                            outer.cancel();
                    });
                assert(run.hasValue, run.hasError ? run.error.context : "");
                got = move(run.value);
                return ioOk();
            });
            cast(void) h.join(s);
        })(s);
        assert(!outcome.hasError);
    });
    assert(!r.hasError);
    assert(got.end == ProcessEnd.cancelled);
    assert(MonoTime.currTime - before >= 90.msecs);
    assert(MonoTime.currTime - before < 2.seconds,
        "reserved grace escalation survives the cancelling outer scope");
}

@("supervise.fiberExhaustionKillsDrainsAndReaps")
@safe
unittest
{
    import core.time : MonoTime, seconds;
    import sparkles.event_horizon.sched : SchedOptions;

    Sched s;
    SchedOptions opts;
    opts.maxFibers = 2; // root + first worker; later admissions must fail
    schedOrSkip(s, opts);
    const before = MonoTime.currTime;
    auto r = s.run(() {
        SupervisedProcessConfig cfg;
        cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
        auto got = supervise(s,
            ["sh", "-c", "echo out; echo err >&2; sleep 30"], cfg);
        assert(got.hasError && got.error.errnoValue == 105 /* ENOBUFS */);
    });
    assert(!r.hasError);
    assert(MonoTime.currTime - before < 2.seconds,
        "admission failure converges instead of parking forever");
}

@("supervise.waitFailureTransitionIsBounded")
@safe pure nothrow @nogc
unittest
{
    const transient = IoError(5, OpKind.waitid, IoErrorStage.completion);
    const interrupted = IoError(4, OpKind.waitid, IoErrorStage.completion);
    const noChild = IoError(10, OpKind.waitid, IoErrorStage.completion);
    assert(!waitLostReapRight(transient),
        "transient errors retain the reap right and must retry");
    assert(waitLostReapRight(noChild), "ECHILD is terminal but not success");
    assert(retryProcessError(interrupted, 0));
    assert(retryProcessError(interrupted, 7));
    assert(!retryProcessError(interrupted, 8),
        "wait/read retries are bounded before terminal fallback");
}

@("supervise.exitedRequiresRealEofAndStatus")
@system
unittest
{
    assert(!canPublishExited(ReapOutcome.notApplicable, true, true),
        "zero-initialized status is not a reap result");
    assert(!canPublishExited(ReapOutcome.reaped, false, true),
        "both drains must reach a terminal state before publication");
    assert(canPublishExited(ReapOutcome.reaped, true, true));
    assert(canPublishExited(ReapOutcome.lostToExternalReaper, true, true),
        "a lost reap right still publishes the terminal-child event");

    const interrupted = IoError(4, OpKind.read, IoErrorStage.completion);
    const again = IoError(11, OpKind.read, IoErrorStage.submit);
    const badFd = IoError(9, OpKind.read, IoErrorStage.completion);
    assert(transientProcessError(interrupted));
    assert(transientProcessError(again));
    assert(!transientProcessError(badFd),
        "permanent read errors hard-close instead of retrying forever");

    LineFramer framer;
    bool emitted;
    framer.push(cast(const(ubyte)[]) "unterminated", ProcessStream.stdout_,
        delegate(ProcessStream stream, const(ubyte)[] bytes, bool terminated,
            bool truncated) {
            emitted = true;
        });
    assert(!emitted,
        "pending bytes are emitted only by real EOF, never read error");
}

@("supervise.callbackDefectWithSaturatedOutputStillCleansUp")
@safe
unittest
{
    import core.time : MonoTime, seconds;

    Sched s;
    schedOrSkip(s);
    const before = MonoTime.currTime;
    auto r = s.run(() {
        bool threw;
        try
            cast(void) superviseImpl(s, ["sh", "-c",
                `awk 'BEGIN{for(i=0;i<10000;i++)printf "chunk-%05d\n",i}'; sleep 30`],
                SupervisedProcessConfig(), null, null,
                (RelayKind kind) {
                    if (kind == RelayKind.bytes)
                        throw new Exception("injected relay handler defect");
                });
        catch (Exception e)
            threw = e.msg == "injected relay handler defect";
        assert(threw);
    });
    assert(!r.hasError);
    assert(MonoTime.currTime - before < 2.seconds,
        "more than a relay's capacity cannot strand protected publishers");
}

@("supervise.cancelAfterBothEofStillTerminatesRoot")
@safe
unittest
{
    import core.time : MonoTime, msecs, seconds;
    import sparkles.event_horizon.io : sleep;
    import sparkles.event_horizon.scope_ : JoinHandle, withScope;

    Sched s;
    schedOrSkip(s);
    SupervisedProcessResult got;
    const before = MonoTime.currTime;
    bool ready;
    auto r = s.run(() {
        auto outcome = withScope!((ref outer) {
            JoinHandle!void h;
            outer.fork(h, () {
                SupervisedProcessConfig cfg;
                cfg.terminateGrace = 100.msecs;
                cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
                // The trap is installed BEFORE the streams close, and the
                // cancel comes after "ready": TERM is certainly ignored.
                auto run = supervise(s, ["sh", "-c",
                    `trap '' TERM; echo ready; exec 1>&- 2>&-; sleep 30`], cfg,
                    null, (in ProcessEvent ev) {
                        if (ev.kind == ProcessEventKind.line)
                            ready = true;
                    });
                assert(run.hasValue, run.hasError ? run.error.context : "");
                got = move(run.value);
                return ioOk();
            });
            while (!ready)
                assert(!sleep(s, 5.msecs).hasError);
            assert(!sleep(s, 40.msecs).hasError,
                "allow both child streams to reach EOF first");
            outer.cancel();
            cast(void) h.join(s);
        })(s);
        assert(!outcome.hasError);
    });
    assert(!r.hasError);
    assert(got.end == ProcessEnd.cancelled);
    assert(got.status.signaled && got.status.code == 9,
        "cancellation remains observable while only root exit is pending");
    assert(MonoTime.currTime - before < 2.seconds);
}

@("supervise.timeoutWinsBeforeRelayPublication")
@system
unittest
{
    Run run;
    decideEnd(run, ProcessEnd.timedOut); // decided AT expiry, before publication
    decideEnd(run, ProcessEnd.cancelled); // a later trigger only records itself
    assert(run.end == ProcessEnd.timedOut,
        "the earlier buffered timeout remains the first trigger");
}

@("supervise.cooperativeTermSuppressesKillAndGraceDelay")
@safe
unittest
{
    import core.time : MonoTime, msecs, seconds;

    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        SupervisedProcessConfig cfg;
        cfg.timeout = 60.msecs;
        cfg.terminateGrace = 3.seconds;
        cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
        const before = MonoTime.currTime;
        auto got = supervise(s, ["sh", "-c",
            `trap 'printf cooperative; exit 0' TERM; while :; do sleep 1; done`],
            cfg);
        assert(got.hasValue, got.hasError ? got.error.context : "");
        assert(got.value.end == ProcessEnd.timedOut);
        assert(got.value.status.ok,
            "the TERM handler exited normally before hard kill");
        assert(got.value.stdout_[] == cast(const(ubyte)[]) "cooperative");
        assert(MonoTime.currTime - before < 1.seconds,
            "natural exit during grace suppresses KILL and the full wait");
    });
    assert(!r.hasError);
}

version (linux)
@("supervise.repeatedRunsDoNotLeakDescriptors")
@system
unittest
{
    import core.sys.posix.dirent : closedir, opendir, readdir;

    static size_t fdCount()
    {
        auto dir = opendir("/proc/self/fd");
        assert(dir !is null);
        scope (exit) closedir(dir);
        size_t count;
        while (readdir(dir) !is null)
            ++count;
        return count;
    }

    Sched s;
    schedOrSkip(s);
    size_t before, after;
    auto r = s.run(() {
        auto warm = supervise(s, ["true"]);
        assert(warm.hasValue && warm.value.status.ok);
        before = fdCount();
        foreach (_; 0 .. 64)
        {
            auto got = supervise(s, ["sh", "-c", "printf x; printf y >&2"]);
            assert(got.hasValue && got.value.status.ok);
        }
        after = fdCount();
    });
    assert(!r.hasError);
    // Other parallel unittests share this process and may transiently own a
    // handful of descriptors. A supervision leak grows by two per run here,
    // so this tight noise allowance still catches the adversarial shape.
    assert(after <= before + 4,
        "the run loop must not retain one or more stdio fds per child");
}

@("supervise.exitBeforeEofWaitsForGrandchildren")
@safe
unittest
{
    import core.time : MonoTime, msecs;

    Sched s;
    schedOrSkip(s);

    auto r = s.run(() {
        // The root exits at once; its backgrounded subshell keeps the stdout
        // pipe open and writes 250ms later. Exited may be knowable early,
        // but the run ends only after BOTH EOFs AND the reap (§13.7).
        EventLog log;
        const before = MonoTime.currTime;
        auto got = supervise(s,
            ["sh", "-c", `{ sleep 0.25; echo late; } & exec true`],
            SupervisedProcessConfig(), null, log.sink());
        assert(got.hasValue, got.error.context);
        const elapsed = MonoTime.currTime - before;

        assert(got.value.status.ok);
        assert(got.value.end == ProcessEnd.exited);
        assert(elapsed >= 200.msecs,
            "EOF waits out the grandchild holding the pipe");

        size_t lateAt = size_t.max, exitedAt = size_t.max;
        foreach (i, ev; log.events)
        {
            if (ev.kind == ProcessEventKind.line
                && ev.line.bytes == cast(const(ubyte)[]) "late")
                lateAt = i;
            if (ev.kind == ProcessEventKind.exited)
                exitedAt = i;
        }
        assert(exitedAt != size_t.max && lateAt != size_t.max
            && lateAt < exitedAt,
            "the grandchild line precedes the single exited event");
        assert(got.value.stdout_[] == cast(const(ubyte)[]) "late\n");
    });
    assert(!r.hasError);
}

@("supervise.eofBeforeExitStillReaps")
@safe
unittest
{
    import core.time : MonoTime, msecs;

    Sched s;
    schedOrSkip(s);

    auto r = s.run(() {
        // Both pipes close immediately; the process itself lingers 250ms.
        EventLog log;
        const before = MonoTime.currTime;
        auto got = supervise(s,
            ["sh", "-c", `echo done; exec 1>&- 2>&-; sleep 0.25`],
            SupervisedProcessConfig(), null, log.sink());
        assert(got.hasValue, got.error.context);
        const elapsed = MonoTime.currTime - before;

        assert(got.value.status.ok);
        assert(got.value.end == ProcessEnd.exited);
        assert(elapsed >= 200.msecs, "the reap waited out the living child");

        size_t doneAt = size_t.max, exitedAt;
        foreach (i, ev; log.events)
            if (ev.kind == ProcessEventKind.exited)
                exitedAt = i;
            else if (ev.kind == ProcessEventKind.line
                && ev.line.bytes == cast(const(ubyte)[]) "done")
                doneAt = i;
        assert(doneAt != size_t.max && exitedAt > doneAt,
            "exited still comes last, after EOF and reap");
    });
    assert(!r.hasError);
}

@("supervise.chattyDualStreamsCannotDeadlock")
@system unittest
{
    import core.time : MonoTime, seconds;

    Sched s;
    schedOrSkip(s);

    auto r = s.run(() {
        // 200 KiB on EACH stream — far past any pipe buffer — while the
        // framing machinery does its work: parked concurrent drains make
        // the blocking-write deadlock impossible (SPEC §13.2/§13.7).
        const before = MonoTime.currTime;
        auto got = supervise(s, ["sh", "-c",
            `awk 'BEGIN{for(i=0;i<20000;i++){printf "out-%05d\n", i; printf "err-%05d\n", i > "/dev/stderr"}}'`],
            SupervisedProcessConfig(), null, null);
        assert(got.hasValue, got.hasError ? got.error.context : "");
        assert(MonoTime.currTime - before < 30.seconds);

        assert(got.value.status.ok);
        assert(got.value.stdout_.length == 10 * 20_000,
            "every stdout byte collected");
        assert(got.value.stderr_.length == 10 * 20_000,
            "every stderr byte collected — no deadlock against undrained pipes");
    });
    assert(!r.hasError);
}

@("supervise.samplesCumulativeAndCoalesced")
@safe
unittest
{
    import core.time : MonoTime, msecs;

    Sched s;
    schedOrSkip(s);

    auto r = s.run(() {
        EventLog log;
        SupervisedProcessConfig cfg;
        // Nominal cadence is 16 ticks over the 400 ms run; requiring three
        // survives an 8x sustained scheduler stall without weakening the
        // repeated-sampling property (missed instants coalesce by design,
        // SPEC §13.8 — they do not queue).
        cfg.sampleInterval = 25.msecs;
        cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
        auto got = supervise(s, ["sleep", "0.4"], cfg, null, log.sink());
        assert(got.hasValue, got.error.context);

        size_t samples;
        size_t lastCount;
        foreach (ev; log.events)
            if (ev.kind == ProcessEventKind.sample)
            {
                ++samples;
                assert(ev.usage.sampleCount > lastCount,
                    "sample counters are cumulative");
                lastCount = ev.usage.sampleCount;
                assert(ev.usage.wallTime > Duration.zero);
            }
        version (linux)
        {
            assert(samples >= 3, "interval sampling fired repeatedly");
            assert(lastCount >= samples);
            assert(got.value.usage.sampled);
            assert(got.value.usage.peakProcesses >= 1,
                "the tree sampler saw at least the root");
        }
        else
        {
            assert(samples == 0, "darwin stub emits no fabricated samples");
            assert(!got.value.usage.sampled);
        }
        assert(got.value.usage.wallTime >= 300.msecs);
    });
    assert(!r.hasError);
}

@("supervise.samplesCpuMonotonicAndTracksExitedRootsGroup")
@safe
unittest
{
    import core.time : msecs;
    import std.conv : text;

    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        EventLog log;
        SupervisedProcessConfig cfg;
        cfg.sampleInterval = 20.msecs;
        auto got = supervise(s, ["sh", "-c",
            `{ i=0; while [ $i -lt 150000 ]; do i=$((i+1)); done; sleep 0.2; } & exit 0`],
            cfg, null, log.sink());
        assert(got.hasValue, got.hasError ? text(got.error.errnoValue, " ", got.error.context) : "");

        Duration lastUser, lastSystem;
        foreach (ev; log.events)
            if (ev.kind == ProcessEventKind.sample)
            {
                assert(ev.usage.userTime >= lastUser);
                assert(ev.usage.systemTime >= lastSystem);
                lastUser = ev.usage.userTime;
                lastSystem = ev.usage.systemTime;
            }
        version (linux)
            assert(got.value.usage.peakProcesses >= 2,
                "same-group descendant remains visible after root exit");
    });
    assert(!r.hasError);
}

@("supervise.samplesAccumulateSequentialDescendantCpu")
@safe
unittest
{
    import core.time : Duration, msecs;

    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        SupervisedProcessConfig cfg;
        cfg.sampleInterval = 5.msecs;
        const worker = `awk 'BEGIN{for(i=0;i<8000000;i++) x+=i}'`;

        auto one = supervise(s, ["sh", "-c", worker], cfg);
        assert(one.hasValue, one.hasError ? one.error.context : "");
        auto two = supervise(s, ["sh", "-c", worker ~ "; " ~ worker], cfg);
        assert(two.hasValue, two.hasError ? two.error.context : "");

        version (linux)
        {
            const oneCpu = one.value.usage.userTime
                + one.value.usage.systemTime;
            const twoCpu = two.value.usage.userTime
                + two.value.usage.systemTime;
            assert(oneCpu > Duration.zero);
            assert(twoCpu > oneCpu + oneCpu / 2,
                "two sequential workers retain roughly their summed CPU");
        }
    });
    assert(!r.hasError);
}

// ── the control plane (SPEC §13.7): residual policy, telemetry, validation ──

@("supervise.config.rejectsNonFiniteOrNegativeDurations")
@safe
unittest
{
    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        SupervisedProcessConfig negative;
        negative.outputGrace = -1.msecs;
        auto a = supervise(s, ["true"], negative);
        assert(a.hasError && a.error.errnoValue == EINVAL);
        SupervisedProcessConfig infinite;
        infinite.killDrainWindow = Duration.max;
        auto b = supervise(s, ["true"], infinite);
        assert(b.hasError && b.error.errnoValue == EINVAL);
        SupervisedProcessConfig bad;
        bad.residualPolicy = cast(ResidualPolicy) 7;
        auto c = supervise(s, ["true"], bad);
        assert(c.hasError && c.error.errnoValue == EINVAL);
    });
    assert(!r.hasError);
}

@("supervise.result.reapOutcomeOnResultAndEvent")
@safe
unittest
{
    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        EventLog log;
        auto got = supervise(s, ["sh", "-c", "exit 3"], SupervisedProcessConfig(),
            null, log.sink());
        assert(got.hasValue, got.hasError ? got.error.context : "");
        assert(got.value.reap == ReapOutcome.reaped && got.value.status.code == 3);
        assert(!got.value.terminationDegraded && !got.value.eofForced);
        assert(!got.value.residualPolicyDegraded && !got.value.cgroupCleanupLeaked);
        bool sawExited;
        foreach (ev; log.events)
            if (ev.kind == ProcessEventKind.exited)
            {
                sawExited = true;
                assert(ev.reap == ReapOutcome.reaped && ev.status.code == 3);
            }
        assert(sawExited);
        assert(reapRightConsumed(testLastSupervisedPid));
    });
    assert(!r.hasError);
}

@("supervise.residual.boundedKillsAPipeClosingDaemonAtRootExit")
@safe
unittest
{
    import core.time : MonoTime, seconds;

    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        // The daemon closed its pipes: root exit + EOF hold at once, and
        // the tree is killed now — no idle wait for the output grace.
        SupervisedProcessConfig cfg;
        cfg.outputGrace = 5.seconds;
        cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
        const before = MonoTime.currTime;
        auto got = supervise(s,
            ["sh", "-c", "sleep 30 >/dev/null 2>&1 & exit 0"], cfg);
        assert(got.hasValue, got.hasError ? got.error.context : "");
        assert(got.value.end == ProcessEnd.exited && got.value.status.ok);
        assert(MonoTime.currTime - before < 1.seconds,
            "a pipe-closing daemon gets no lifetime grace");
        assert(!got.value.terminationDegraded);
    });
    assert(!r.hasError);
}

@("supervise.residual.boundedGivesAPipeHoldingDaemonTheOutputGrace")
@safe
unittest
{
    import core.time : MonoTime, msecs, seconds;

    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        SupervisedProcessConfig cfg;
        cfg.outputGrace = 150.msecs;
        cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
        const before = MonoTime.currTime;
        auto got = supervise(s, ["sh", "-c", "sleep 30 & exit 0"], cfg);
        assert(got.hasValue, got.hasError ? got.error.context : "");
        const elapsed = MonoTime.currTime - before;
        assert(got.value.end == ProcessEnd.exited && got.value.status.ok);
        assert(elapsed >= 140.msecs, "the output grace ran");
        assert(elapsed < 2.seconds, "then the hard kill closed the pipe");
        assert(!got.value.eofForced, "the kill produced a natural EOF");
    });
    assert(!r.hasError);
}

@("supervise.residual.detachForcesEofAtTheDrainWindow")
@safe
unittest
{
    import core.time : MonoTime, msecs, seconds;

    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        // Detach gives up termination ownership, not promptness: the
        // residual keeps stdout open past the window and is left alive.
        SupervisedProcessConfig cfg;
        cfg.residualPolicy = ResidualPolicy.detach;
        cfg.killDrainWindow = 100.msecs;
        cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
        const before = MonoTime.currTime;
        auto got = supervise(s, ["sh", "-c", "sleep 1 & exit 0"], cfg);
        assert(got.hasValue, got.hasError ? got.error.context : "");
        const elapsed = MonoTime.currTime - before;
        assert(got.value.end == ProcessEnd.exited && got.value.status.ok);
        assert(got.value.eofForced, "the pipe was forced closed");
        assert(elapsed >= 90.msecs && elapsed < 900.msecs,
            "returned at the drain window, before the residual exited");
        assert(reapRightConsumed(testLastSupervisedPid));
    });
    assert(!r.hasError);
}

@("supervise.residual.waitStaysUntilTheCgroupEmptiesOrIsRefused")
@safe
unittest
{
    import core.time : MonoTime, msecs, seconds;

    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        SupervisedProcessConfig cfg;
        cfg.residualPolicy = ResidualPolicy.wait;
        cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
        const before = MonoTime.currTime;
        // The daemon forks after the post-spawn migration has landed: a
        // fork that races the migration is outside the cgroup by contract
        // (§13.7), and `wait` is cgroup-scoped by definition.
        auto got = supervise(s,
            ["sh", "-c", "sleep 0.05; sleep 0.3 >/dev/null 2>&1 & exit 0"], cfg);
        if (got.hasError)
        {
            assert(got.error.errnoValue == EOPNOTSUPP,
                "without an owned cgroup, wait is refused at negotiation");
            return;
        }
        const elapsed = MonoTime.currTime - before;
        assert(got.value.end == ProcessEnd.exited && got.value.status.ok);
        assert(elapsed >= 250.msecs, "the run waited for the daemon to exit");
        assert(elapsed < 3.seconds);
        assert(!got.value.terminationDegraded && !got.value.residualPolicyDegraded);
    });
    assert(!r.hasError);
}

// ── control-plane tests (plan commit 12): clocks, sampler, telemetry ────────

@("supervise.telemetry.killOutcomeTruthTable")
@safe pure nothrow @nogc
unittest
{
    bool degraded;
    IoError error;
    const ok = KillOutcome(KillResult.delivered, 0);
    const failed = KillOutcome(KillResult.failed, 1 /* EPERM */);
    const absent = KillOutcome(KillResult.targetAbsent, ESRCH);
    const none = KillOutcome(KillResult.notAttempted, 0);

    combineKill(ok, ok, true, degraded, error);
    assert(!degraded, "both delivered");
    combineKill(ok, none, false, degraded, error);
    assert(!degraded, "cgroup not owned is not a failure");
    combineKill(ok, failed, true, degraded, error);
    assert(degraded && error.errnoValue == 1, "cgroup failure is degradation");
    combineKill(failed, ok, true, degraded, error);
    assert(degraded && error.errnoValue == 1, "pgid failure degrades even when cgroup.kill worked");
    combineKill(absent, none, false, degraded, error);
    assert(degraded && error.errnoValue == ESRCH, "ESRCH under a pinned zombie is a failure");
}

@("supervise.sampling.finalSampleBeforeReapSeesTheRootAndItsTier")
@safe
unittest
{
    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        // Final accounting only: the initial fold plus the pre-reap final
        // sample, taken while the zombie still pins /proc/<pid>.
        SupervisedProcessConfig cfg;
        cfg.sampleInterval = Duration.zero;
        auto got = supervise(s, ["sh", "-c",
            "i=0; while [ $i -lt 20000 ]; do i=$((i+1)); done"], cfg);
        assert(got.hasValue, got.hasError ? got.error.context : "");
        version (linux)
        {
            assert(got.value.usage.sampled && got.value.usage.sampleCount >= 2);
            assert(got.value.usage.peakProcesses >= 1, "the final sample saw the root");
            assert(!got.value.usage.samplingDegraded, "no sample was skipped or aborted");
            assert(got.value.usage.memoryQuality == MetricQuality.lowerBound);
            assert(got.value.usage.cpuQuality == MetricQuality.lowerBound,
                "tree CPU is a lower bound under unenforced containment");
            final switch (got.value.usage.source)
            {
            case SampleSource.cgroupFull:
            case SampleSource.cgroupMembers:
                assert(got.value.usage.cgroupCpuSource == MetricSource.cgroup
                    && got.value.usage.cgroupCpuQuality == MetricQuality.exact,
                    "the run cgroup's own counter is exact");
                break;
            case SampleSource.procScan:
                assert(got.value.usage.cgroupCpuSource == MetricSource.none);
                break;
            case SampleSource.none:
                assert(0, "Linux always has a source");
            }
        }
        else
            assert(!got.value.usage.sampled);
    });
    assert(!r.hasError);
}

@("supervise.forceEof.isANoopOnceBothStreamsFinished")
@safe
unittest
{
    import core.time : MonoTime, msecs, seconds;

    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        // Streams close at once; the root lingers. Under detach the drain
        // window arms at root exit, but both streams are already terminal:
        // nothing is forced, and the run resolves straight away.
        SupervisedProcessConfig cfg;
        cfg.residualPolicy = ResidualPolicy.detach;
        cfg.killDrainWindow = 50.msecs;
        cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
        auto got = supervise(s, ["sh", "-c", "exec 1>&- 2>&-; sleep 0.2"], cfg);
        assert(got.hasValue, got.hasError ? got.error.context : "");
        assert(got.value.end == ProcessEnd.exited && got.value.status.ok);
        assert(!got.value.eofForced, "no stream was still open to force");
    });
    assert(!r.hasError);
}

@("supervise.residual.requestedTerminationReplacesTheNaturalGrace")
@safe
unittest
{
    import core.time : MonoTime, msecs, seconds;

    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        // Root exits at once; a pipe-holding daemon would get five seconds
        // of output grace — but the timeout's requested termination
        // replaces that grace, TERM ends the daemon, and the run returns.
        SupervisedProcessConfig cfg;
        cfg.outputGrace = 5.seconds;
        cfg.timeout = 60.msecs;
        cfg.terminateGrace = 2.seconds;
        cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
        const before = MonoTime.currTime;
        auto got = supervise(s, ["sh", "-c", "sleep 30 & exit 0"], cfg);
        assert(got.hasValue, got.hasError ? got.error.context : "");
        assert(got.value.end == ProcessEnd.timedOut);
        assert(got.value.status.ok, "the root's own status is kept");
        assert(MonoTime.currTime - before < 1.seconds,
            "neither the output grace nor terminateGrace was waited out");
    });
    assert(!r.hasError);
}

@("supervise.clock.timeoutAndCancelRaceKeepOneFrozenEnd")
@safe
unittest
{
    import core.time : msecs;
    import sparkles.event_horizon.io : sleep;
    import sparkles.event_horizon.scope_ : JoinHandle, withScope;

    Sched s;
    schedOrSkip(s);
    // The two triggers land within the same instant; whichever wins is
    // the run's end at publication AND at return.
    foreach (_; 0 .. 3)
    {
        ProcessEnd published = ProcessEnd.exited;
        SupervisedProcessResult got;
        auto r = s.run(() {
            auto outcome = withScope!((ref outer) {
                JoinHandle!void h;
                outer.fork(h, () {
                    SupervisedProcessConfig cfg;
                    cfg.timeout = 30.msecs;
                    cfg.terminateGrace = 200.msecs;
                    cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
                    auto run = supervise(s, ["sleep", "30"], cfg, null,
                        (in ProcessEvent ev) {
                            if (ev.kind == ProcessEventKind.exited)
                                published = ev.end;
                        });
                    assert(run.hasValue, run.hasError ? run.error.context : "");
                    got = move(run.value);
                    return ioOk();
                });
                cast(void) sleep(s, 30.msecs);
                outer.cancel();
                cast(void) h.join(s);
            })(s);
            assert(!outcome.hasError);
        });
        assert(!r.hasError);
        assert(got.end == ProcessEnd.timedOut || got.end == ProcessEnd.cancelled);
        assert(published == got.end, "the published end is the returned end");
        assert(got.reap == ReapOutcome.reaped && got.status.signaled);
    }
}

@("supervise.residual.timeoutOverridesWait")
@safe
unittest
{
    import core.time : MonoTime, msecs, seconds;

    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        SupervisedProcessConfig cfg;
        cfg.residualPolicy = ResidualPolicy.wait;
        cfg.timeout = 100.msecs;
        cfg.terminateGrace = 2.seconds;
        cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
        const before = MonoTime.currTime;
        auto got = supervise(s,
            ["sh", "-c", "sleep 0.05; sleep 5 >/dev/null 2>&1 & exit 0"], cfg);
        if (got.hasError)
        {
            assert(got.error.errnoValue == EOPNOTSUPP);
            return;
        }
        assert(got.value.end == ProcessEnd.timedOut, "the timeout overrode the wait");
        assert(got.value.status.ok);
        assert(MonoTime.currTime - before < 1.seconds,
            "TERM ended the daemon; nothing waited for its five seconds");
        assert(!got.value.residualPolicyDegraded, "an override is not a degradation");
    });
    assert(!r.hasError);
}

@("supervise.emergency.admissionFailureLeavesNoZombie")
@safe
unittest
{
    import core.time : MonoTime, seconds;
    import sparkles.event_horizon.sched : SchedOptions;

    Sched s;
    SchedOptions opts;
    opts.maxFibers = 3; // root + observer + one drain: the second drain fails
    schedOrSkip(s, opts);
    const before = MonoTime.currTime;
    auto r = s.run(() {
        SupervisedProcessConfig cfg;
        cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
        auto got = supervise(s, ["sh", "-c", "echo out; echo err >&2; sleep 30"], cfg);
        assert(got.hasError && got.error.errnoValue == ENOBUFS);
        assert(reapRightConsumed(testLastSupervisedPid), "the emergency phase reaped");
        // The scope's own admission sweep was consumed: the caller's next
        // cancellable operation is not poisoned.
        import sparkles.event_horizon.scope_ : checkCancellation;
        assert(!checkCancellation(s).hasError, "no leaked internal cancel");
    });
    assert(!r.hasError);
    assert(MonoTime.currTime - before < 2.seconds);
}
