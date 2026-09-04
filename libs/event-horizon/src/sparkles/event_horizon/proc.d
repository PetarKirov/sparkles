/**
The subprocess vocabulary and capability (SPEC §13): per-stream stdio
configuration, the exit-status shape, the `isProc` concept, and the
deterministic `SimProc` double.

Effects-side (split like `net`): this module never imports the loop, the
scheduler, or the spawn machinery — those live in `live`
(`ChildProcess`, `spawnProcess`, `spawnPty`, `wait`, `RingProc`), and
`package` re-exports both, so consumer spellings do not change.

The design premise (SPEC §13): background work in this repository is
subprocess-shaped — `git status`, a resident oracle, an LLM agent, a PTY
child. A spawned child's pipes are ordinary descriptors the ring already
reads, so "async background work" is plain fiber I/O: no second scheduler,
no worker threads, no polling.
*/
module sparkles.event_horizon.proc;

import core.time : Duration;

import sparkles.event_horizon.capability : isCapability;
import sparkles.event_horizon.errors : IoError, IoErrorStage, IoResult, OpKind,
    ioErr, ioOk;

// ── the spawn vocabulary (SPEC §13.1) ───────────────────────────────────────

/// Where one of the child's standard streams goes.
enum StdioMode : ubyte
{
    inherit, /// share the parent's descriptor (the default for stdin/stderr)
    pipe,    /// a pipe whose parent end rides the returned handle
    nullDev, /// /dev/null
    fd,      /// a caller-supplied descriptor (borrowed, not closed)

    /// stderr only: dup onto the child's stdout, so one pipe carries both
    /// streams in output order (the `Redirect.stderrToStdout` shape
    /// monitored/streaming runs need).
    mergeStdout,
}

/// One stream's destination.
struct StdioSpec
{
    StdioMode mode = StdioMode.inherit;
    int fd = -1; /// used when `mode == StdioMode.fd`
}

/// How to spawn a child (SPEC §13.1). The defaults capture stdout and
/// leave stdin/stderr shared — the "run a tool, read its output" shape.
struct ProcessConfig
{
    StdioSpec stdinSpec = StdioSpec(StdioMode.inherit);
    StdioSpec stdoutSpec = StdioSpec(StdioMode.pipe);
    StdioSpec stderrSpec = StdioSpec(StdioMode.inherit);
    const(char[])[] env = null;   /// null = inherit; entries are "KEY=value"

    /// Environment edits applied on top of $(LREF ProcessConfig.env) when that
    /// is non-null, else on top of the inherited environment (SPEC §13.1,
    /// target M19): changes apply in order, the last change for a name wins,
    /// `unset` removes. Name matching is byte-exact on POSIX.
    const(EnvironmentChange)[] envOverlay;

    const(char)[] cwd = null;     /// null = inherit
    bool newProcessGroup = false; /// `setpgid(0, 0)` in the child (kill the tree)
}

/// One environment edit (SPEC §13.1, target M19). Applied in array order:
/// a set assigns `name=value` over the base environment, an unset removes
/// `name`. Matching is byte-exact on POSIX (case-insensitive on Windows,
/// §13.9).
struct EnvironmentChange
{
    const(char)[] name;  /// non-empty; must not contain '=' or NUL
    const(char)[] value; /// ignored when `unset`; must not contain NUL
    bool unset;          /// remove `name` instead of assigning `value`
}

/// How a child ended (SPEC §13.2).
struct ExitStatus
{
    bool signaled; /// killed by a signal rather than exiting
    int code;      /// exit code, or the signal number when `signaled`

    /// Plain success: exited with code 0.
    bool ok() const @safe pure nothrow @nogc => !signaled && code == 0;
}

// ── the capability concept (SPEC §13.4) ─────────────────────────────────────

/**
The proc capability: like `isNet`'s `Stream`/`Listener`, the concept names
the capability's OWN child type, so this effects-side trait never imports
the loop-side handle. `RingProc` (module `live`) satisfies it with
`Child = ChildProcess`; `SimProc` below with `Child = SimChild`.
*/
enum bool isProc(P) = isCapability!P && P.capName == "proc" && is(P.Child)
    && __traits(compiles, (ref P p, ref P.Child child) {
        IoResult!(P.Child) c = p.spawn(["true"], ProcessConfig());
        IoResult!ExitStatus st = p.wait(child);
    });

// ── the deterministic double (SPEC §13.4) ───────────────────────────────────

/// A scripted child: fixed stdout bytes and a fixed exit status.
struct SimChild
{
    int pid = -1;               /// synthetic; -1 after a successful wait
    const(ubyte)[] stdoutBytes; /// the whole scripted output
    package ExitStatus scriptedStatus;

    /// `true` while the child is reapable.
    bool opCast(T : bool)() const @safe pure nothrow @nogc => pid > 0;
}

/**
The deterministic proc double: scripted per-command stdout and exit
statuses, no process and no ring — what makes an application's "run git,
parse, decide" path a unit test. Commands are matched on `argv[0]`; an
unscripted spawn fails `ENOENT` (the same errno a missing binary produces
live).
*/
struct SimProc
{
    enum string capName = "proc";

    /// The scripted child handle type.
    alias Child = SimChild;

    /// One scripted command.
    struct Script
    {
        string command;             /// matched against argv[0]
        const(ubyte)[] stdoutBytes; /// delivered on the child handle
        ExitStatus status;          /// delivered by wait
    }

    private const(Script)[] _scripts;
    private int _nextPid = 1000;

    /// Builds the double from its script table.
    this(const(Script)[] scripts) @safe pure nothrow @nogc
    {
        _scripts = scripts;
    }

    /// Spawns a scripted child; `ENOENT` for an unscripted command.
    IoResult!SimChild spawn(scope const(char[])[] argv,
        in ProcessConfig cfg = ProcessConfig()) @safe nothrow @nogc
    {
        if (argv.length == 0)
            return ioErr!SimChild(22 /* EINVAL */, OpKind.none,
                IoErrorStage.submit, "empty argv");
        foreach (ref s; _scripts)
            if (s.command == argv[0])
                return ioOk(SimChild(_nextPid++, s.stdoutBytes, s.status));
        return ioErr!SimChild(2 /* ENOENT */, OpKind.none, IoErrorStage.submit,
            "command not scripted");
    }

    /// Reaps a scripted child: its scripted status, exactly once.
    IoResult!ExitStatus wait(ref SimChild child) @safe nothrow @nogc
    {
        if (child.pid <= 0)
            return ioErr!ExitStatus(10 /* ECHILD */, OpKind.waitid,
                IoErrorStage.submit, "no child to reap");
        child.pid = -1;
        return ioOk(child.scriptedStatus);
    }
}

static assert(isProc!SimProc);

@("proc.SimProc.scriptedRunParseDecide")
@safe nothrow
unittest
{
    // The app-shaped path: run a tool, read its output, branch on it —
    // entirely scripted, no process.
    static immutable ubyte[] porcelain = cast(immutable(ubyte)[]) " M src/app.d\n";
    static immutable SimProc.Script[] scripts = [
        {command: "git", stdoutBytes: porcelain, status: ExitStatus(false, 0)},
        {command: "false", stdoutBytes: null, status: ExitStatus(false, 1)},
    ];
    auto proc = SimProc(scripts);

    auto spawned = proc.spawn(["git", "status", "--porcelain"]);
    assert(spawned.hasValue);
    auto child = spawned.value;
    assert(child);
    const dirty = child.stdoutBytes.length > 0;
    auto st = proc.wait(child);
    assert(st.hasValue && st.value.ok);
    assert(!child, "reaped");
    assert(dirty, "the scripted porcelain output drove the decision");

    auto failing = proc.spawn(["false"]);
    assert(failing.hasValue);
    auto f = failing.value;
    auto fst = proc.wait(f);
    assert(fst.hasValue && !fst.value.ok && fst.value.code == 1);

    auto missing = proc.spawn(["not-scripted"]);
    assert(missing.hasError && missing.error.errnoValue == 2);
}

@("proc.ExitStatus.okSemantics")
@safe pure nothrow @nogc
unittest
{
    assert(ExitStatus(false, 0).ok);
    assert(!ExitStatus(false, 1).ok);
    assert(!ExitStatus(true, 9).ok, "a signaled death is never ok");
}

// ── supervised runs (SPEC §13.5–§13.8, target M19) ──────────────────────────

/// Which output stream a line came from (SPEC §13.5). With
/// `StdioMode.mergeStdout` every framed line reports `stdout_` — the merged
/// pipe is one kernel stream with one total order.
enum ProcessStream : ubyte
{
    stdout_, ///
    stderr_,
}

/// What a $(LREF ProcessEvent) carries (SPEC §13.5).
enum ProcessEventKind : ubyte
{
    line,   /// one framed line; `line` is valid
    sample, /// a cumulative resource sample; `usage` is valid
    exited, /// the final event for a created child; `status`/`end` are valid
}

/// How a supervised run ended (SPEC §13.5). The first timeout/cancel trigger
/// wins; later triggers only advance cleanup (SPEC §13.7).
enum ProcessEnd : ubyte
{
    exited,      /// the child ended on its own (any exit code is data)
    timedOut,    /// `SupervisedProcessConfig.timeout` fired first
    cancelled,   /// the surrounding scope was cancelled first
    spawnFailed, /// no child was ever created (`spawnError` is valid)
}

/// One framed output line (SPEC §13.6). The bytes are borrowed for the
/// duration of the sink call — copy to retain. The terminator is excluded;
/// `terminated == false` marks the final EOF fragment $(B and) a truncated
/// head (a line that exceeded `SupervisedProcessConfig.maxLineBytes`, told
/// apart by `truncated`).
struct ProcessLine
{
    ProcessStream stream;
    const(ubyte)[] bytes; /// callback-borrowed; line terminator excluded
    bool terminated;      /// false for the final EOF fragment and for a truncated head
    bool truncated;       /// the first `maxLineBytes` payload bytes of an over-cap line
}

/// Where a run's samples came from (SPEC §13.8).
enum SampleSource : ubyte
{
    none,          /// no tree sampler on this host
    cgroupFull,    /// owned cgroup with controller-backed peaks
    cgroupMembers, /// owned cgroup: roster + `cpu.stat`, peaks from procfs
    procScan,      /// `/proc` scan over the descendants and the process group
}

/// Which subsystem produced a metric.
enum MetricSource : ubyte
{
    none,   /// not measured
    procfs, /// `/proc/<pid>/stat` (stat, statm, children)
    cgroup, /// a cgroup v2 counter file
    rusage, /// the platform's per-process rusage call
}

/// What a metric's value is the truth about (SPEC §13.8 truth table).
enum MetricQuality : ubyte
{
    unmeasured, /// nothing was observed; the value is zero and meaningless
    exact,      /// a kernel cumulative counter over an enforced boundary
    lowerBound, /// sampled, budget-capped, or over an unenforced boundary
}

/**
Cumulative resource usage of the supervised process tree (SPEC §13.8):
peak summed RSS and peak live-process count over the run, elapsed wall time,
best-effort user/system CPU, and — in the owned cgroup tiers — the run
cgroup's own counters. Every metric carries its source and its quality, so
a consumer reads what a number is the truth about rather than guessing:
sampled peaks are lower bounds by construction; tree CPU is always a lower
bound while containment is unenforced (a same-uid descendant can leave the
cgroup unobserved); only the run cgroup's own cumulative counters, read
successfully at the final sample, are exact. Unsupported counters leave
`sampled == false` rather than fabricating zero-valued measurements;
`wallTime` is always valid.
*/
struct ProcessResourceUsage
{
    size_t peakRssBytes;
    size_t peakProcesses;
    size_t sampleCount;
    Duration wallTime;
    Duration userTime;
    Duration systemTime;
    bool sampled;

    size_t peakCgroupMemoryBytes; /// `memory.peak` (page cache included)
    size_t peakTasks;             /// `pids.peak` — tasks, not processes
    Duration cgroupUserTime;      /// CPU charged to the run cgroup
    Duration cgroupSystemTime;    /// ditto

    MetricSource memorySource;
    MetricSource processSource;
    MetricSource cpuSource;
    MetricSource cgroupMemorySource;
    MetricSource tasksSource;
    MetricSource cgroupCpuSource;

    MetricQuality memoryQuality;
    MetricQuality processQuality;
    MetricQuality cpuQuality;
    MetricQuality cgroupMemoryQuality;
    MetricQuality tasksQuality;
    MetricQuality cgroupCpuQuality;

    SampleSource source;
    bool accountingSaturated; /// a per-sample work budget was hit at least once
    bool samplingDegraded;    /// a sample was skipped, aborted, or refused
}

/// Whether the supervisor consumed the root's exit status (SPEC §13.7).
/// `exited` is the terminal-child event, not proof that THIS supervisor
/// reaped: a concurrent external reaper (a contract violation the run
/// survives) leaves `status` invalid, self-described by this field.
enum ReapOutcome : ubyte
{
    notApplicable,        /// no child existed (`spawnFailed`)
    reaped,               /// the status was consumed here; `status` is valid
    lostToExternalReaper, /// `ECHILD` after observation; `status` is invalid
}

/// What a residual tree — descendants alive after the root exited — gets
/// (SPEC §13.7). Every policy still owns the pgid; the cgroup adds recursion.
enum ResidualPolicy : ubyte
{
    /// Output grace: pipe-holding descendants get `outputGrace` after root
    /// exit; once root exit and EOF both hold, the tree is killed at once.
    bounded,
    /// Owned-cgroup tiers only: stay until EOF and the run cgroup reads
    /// recursively empty; degrades to `bounded` with telemetry.
    wait,
    /// No residual kill; pipes still open at `killDrainWindow` are forced
    /// closed; cleanup may report a leaked cgroup directory.
    detach,
}

/// The recorded outcome of one containment action (SPEC §13.7): the errno
/// travels with the kind, so a failure is never a bare flag.
struct KillOutcome
{
    KillResult kind;
    int errnoValue;
}

/// ditto
enum KillResult : ubyte
{
    notAttempted, /// no capability, or the tree was already resolved
    delivered,    /// the signal / kill write was accepted
    targetAbsent, /// `ESRCH`: nothing to signal (never treated as success)
    failed,       /// any other errno
}

/// One supervision event (SPEC §13.5): exactly one field is meaningful,
/// selected by `kind`. Delivered synchronously on the original supervising
/// scheduler fiber; the sink must not retain `line.bytes`.
struct ProcessEvent
{
    ProcessEventKind kind;
    ProcessLine line;           /// valid for `ProcessEventKind.line`
    ProcessResourceUsage usage; /// valid for `ProcessEventKind.sample`
    ExitStatus status;          /// valid for `exited` ONLY when `reap == reaped`
    ProcessEnd end;             /// valid for `ProcessEventKind.exited`
    ReapOutcome reap;           /// valid for `ProcessEventKind.exited`
}

/// Knobs of one supervised run (SPEC §13.5). Zero `timeout` means no
/// deadline; zero `sampleInterval` means final accounting only. Every
/// buffer the run keeps is bounded: `maxLineBytes` caps one framed line and
/// `maxCapturedBytes` caps each raw collection — overflow is reported in the
/// events and the result (SPEC §13.6), never silent.
struct SupervisedProcessConfig
{
    import core.time : Duration, msecs, seconds;

    ProcessConfig process;
    Duration timeout = Duration.zero;    /// zero = no deadline
    Duration terminateGrace = 5.seconds; /// TERM → grace → KILL
    Duration sampleInterval = 250.msecs; /// zero = final accounting only
    bool collectOutput = true;           /// accumulation only; never draining
    size_t maxLineBytes = 1024 * 1024;   /// framer cap per line; 0 = unbounded
    size_t maxCapturedBytes = 64 * 1024 * 1024; /// per raw stream; 0 = unbounded
    ResidualPolicy residualPolicy = ResidualPolicy.bounded; /// after root exit (§13.7)
    /// `bounded` (and `wait`'s fallback): the grace for descendants still
    /// holding an output pipe after the root exited.
    Duration outputGrace = 5.seconds;
    Duration killDrainWindow = 1.seconds; /// post-kill / detach drain budget before forced EOF
}

/// The outcome of one supervised run (SPEC §13.5). `stdout_`/`stderr_`
/// hold the exact raw bytes including original terminators, independently
/// of the normalized line events; empty unless that stream was piped, and
/// cut at `maxCapturedBytes` with the matching flag set.
struct SupervisedProcessResult
{
    import sparkles.base.buffer : SharedBuffer;

    ProcessEnd end;
    ExitStatus status; /// valid only when `reap == ReapOutcome.reaped`
    ProcessResourceUsage usage;
    SharedBuffer!(ubyte, 256) stdout_;
    SharedBuffer!(ubyte, 256) stderr_;
    IoError spawnError;    /// valid only for `ProcessEnd.spawnFailed`
    size_t truncatedLines; /// lines that exceeded `maxLineBytes` (both streams)
    bool stdoutTruncated;  /// raw `stdout_` collection hit `maxCapturedBytes`
    bool stderrTruncated;  /// ditto for `stderr_`
    bool eofForced;        /// a still-open pipe was forced closed at a drain window
    bool terminationDegraded;   /// a REQUESTED hard tree kill fell below the tier's promise
    IoError terminationError;   /// the primary cause (pgid error first, else cgroup)
    bool residualPolicyDegraded; /// `wait` fell back to `bounded`
    IoError residualPolicyError; /// why
    bool cgroupCleanupLeaked;   /// the run's cgroup directory remained (removal only)
    ReapOutcome reap;           /// `status` is valid ONLY when `reap == reaped`
}

/// The synchronous event callback of $(LREF sparkles.event_horizon.live.supervise)
/// (SPEC §13.5): runs on the original supervising scheduler fiber, must not retain
/// `event.line.bytes`, and reports failure by throwing — which cancels the
/// run's scope and converges on the same teardown as any other cancellation.
alias ProcessEventSink = void delegate(in ProcessEvent event);

// ── line framing (SPEC §13.6) ───────────────────────────────────────────────

/// The line-delivery callback shape of $(LREF LineFramer): the payload is
/// borrowed for the call. `terminated` is false for the final EOF fragment
/// and for a truncated head; `truncated` tells the two apart.
alias LineEmit = void delegate(ProcessStream stream, const(ubyte)[] bytes,
    bool terminated, bool truncated);

/**
Independent incremental LF/CRLF framer for one pipe (SPEC §13.6): LF ends a
line, one immediately preceding CR is stripped, embedded NUL and invalid
UTF-8 are preserved, empty lines are events, a line may span many reads and a
read may hold many lines. EOF flushes one final `terminated == false` event
iff bytes remain.

Bounded and linear. `maxLineBytes` caps the $(I payload) bytes retained for
one line (0 = unbounded): a line that exceeds it is delivered exactly once as
its first `maxLineBytes` payload bytes with `terminated == false,
truncated == true`, the remainder of that line is discarded through its LF,
and framing resumes on the next line (the tokio `LinesCodec` contract). A CR
counts as payload only when no LF follows it — so a cap of 3 accepts
`"abc\r"` + `"\n"` as the untruncated line `"abc"`. Every byte is scanned
once (`_scanned` remembers how far the pending tail was examined), so a long
line arriving in many reads costs O(n), not O(n²), and the pending buffer
never holds more than the cap plus a trailing CR.

Effects-side and pure: no ring, no scheduler — unit-testable on its own.
*/
struct LineFramer
{
    import sparkles.base.buffer : SharedBuffer;

    size_t maxLineBytes;   /// payload cap per line; 0 = unbounded
    size_t truncatedLines; /// lines that exceeded `maxLineBytes`

    private SharedBuffer!(ubyte, 256) _pending;
    private size_t _scanned;  // head bytes of `_pending` already examined
    private bool _discarding; // dropping an over-cap line through its LF

    /// Feeds raw read output, emitting complete lines (and at most one
    /// truncated head per over-cap line) through `emit` — any callable of the
    /// $(LREF LineEmit) shape; attributes infer from it (a `@safe` emitter
    /// keeps the framer `@safe`).
    void push(Emit)(scope const(ubyte)[] bytes, ProcessStream stream,
        scope Emit emit)
    if (is(typeof(emit(ProcessStream.init, (const(ubyte)[]).init, true, true))))
    {
        _pending ~= bytes;
        size_t lineStart;
        size_t i = _scanned;
        while (i < _pending.length)
        {
            const b = _pending[i];
            if (_discarding)
            {
                ++i;
                if (b == '\n')
                {
                    _discarding = false;
                    lineStart = i;
                }
                continue;
            }
            if (b == '\n')
            {
                size_t end = i;
                if (end > lineStart && _pending[end - 1] == '\r')
                    --end;
                emit(stream, _pending[lineStart .. end], true, false);
                ++i;
                lineStart = i;
                continue;
            }
            if (maxLineBytes != 0)
            {
                // Payload pending for this line; a CR that a following LF
                // would strip is not payload yet.
                size_t pendingLine = i + 1 - lineStart;
                if (b == '\r')
                    --pendingLine;
                if (pendingLine > maxLineBytes)
                {
                    emit(stream, _pending[lineStart .. lineStart + maxLineBytes],
                        false, true);
                    ++truncatedLines;
                    _discarding = true; // `i` itself is part of the discard
                    ++i;
                    continue;
                }
            }
            ++i;
        }

        if (_discarding)
        {
            // Everything buffered belongs to the line being dropped.
            _pending.length = 0;
            _scanned = 0;
            return;
        }
        if (lineStart > 0)
        {
            const remain = _pending.length - lineStart;
            foreach (j; 0 .. remain)
                _pending[j] = _pending[lineStart + j];
            _pending.length = remain;
        }
        _scanned = _pending.length;
    }

    /// EOF: one final unterminated fragment iff bytes remain; nothing while
    /// an over-cap line was being discarded (its head already went out).
    void flushEof(Emit)(ProcessStream stream, scope Emit emit)
    if (is(typeof(emit(ProcessStream.init, (const(ubyte)[]).init, true, true))))
    {
        if (_discarding)
        {
            _discarding = false;
            return;
        }
        if (_pending.length)
        {
            emit(stream, _pending[], false, false);
            _pending.length = 0;
            _scanned = 0;
        }
    }
}

version (unittest)
{
    /// One emitted line, copied, for the framer tests.
    private struct FramedLine
    {
        const(ubyte)[] bytes;
        bool terminated;
        bool truncated;
    }

    private FramedLine[] frameAll(size_t cap, scope const(ubyte)[][] pushes,
        bool eof = true) @safe
    {
        FramedLine[] lines;
        LineFramer framer;
        framer.maxLineBytes = cap;
        auto emit = delegate(ProcessStream stream, const(ubyte)[] bytes,
            bool terminated, bool truncated) @safe {
            lines ~= FramedLine(bytes.dup, terminated, truncated);
        };
        foreach (chunk; pushes)
            framer.push(chunk, ProcessStream.stdout_, emit);
        if (eof)
            framer.flushEof(ProcessStream.stdout_, emit);
        return lines;
    }

    private const(ubyte)[] b(string s) @safe pure nothrow @nogc
        => cast(const(ubyte)[]) s;
}

@("proc.LineFramer.lfCrlfEmptyAndBinaryAcrossReads")
@safe
unittest
{
    // One burst: plain LF, CRLF, an empty line, and an unterminated binary
    // tail holding a NUL — then the same bytes split byte-by-byte.
    const src = b("one\ntwo\r\n\nx\0y");
    const expect = [
        FramedLine(b("one"), true, false), FramedLine(b("two"), true, false),
        FramedLine(b(""), true, false), FramedLine(b("x\0y"), false, false),
    ];
    assert(frameAll(0, [src]) == expect);
    const(ubyte)[][] bytewise;
    foreach (i; 0 .. src.length)
        bytewise ~= src[i .. i + 1];
    assert(frameAll(0, bytewise) == expect, "kernel chunking is invisible");
    assert(frameAll(0, [b("done\n")]).length == 1,
        "EOF right after a terminator emits nothing extra");
}

@("proc.LineFramer.capIsPayloadAndTrailingCrResolves")
@safe
unittest
{
    // A cap of 3: "abc\r" then "\n" is the untruncated line "abc" — the CR
    // is not payload until it turns out no LF follows it.
    assert(frameAll(3, [b("abc\r"), b("\n")])
        == [FramedLine(b("abc"), true, false)]);
    // A cap exactly at the terminator is not an overflow.
    assert(frameAll(3, [b("abc\n")]) == [FramedLine(b("abc"), true, false)]);
    // One byte over: the head goes out once, the rest of the line is
    // discarded through its LF, and framing resumes.
    assert(frameAll(3, [b("abcd"), b("ef\nxyz\n")])
        == [FramedLine(b("abc"), false, true), FramedLine(b("xyz"), true, false)]);
    // A CR at the cap boundary that is NOT followed by LF is payload.
    assert(frameAll(3, [b("abc\r"), b("d\nok\n")])
        == [FramedLine(b("abc"), false, true), FramedLine(b("ok"), true, false)]);
}

@("proc.LineFramer.discardEdgesAndCounts")
@safe
unittest
{
    // Overflow immediately followed by EOF: the head once, nothing at EOF.
    assert(frameAll(2, [b("abcdef")]) == [FramedLine(b("ab"), false, true)]);
    // EOF while discarding emits no fragment.
    assert(frameAll(2, [b("abcdef"), b("gh")]) == [FramedLine(b("ab"), false, true)]);
    // Repeated overflows on one stream each count once.
    LineFramer framer;
    framer.maxLineBytes = 2;
    size_t heads;
    auto emit = delegate(ProcessStream stream, const(ubyte)[] bytes,
        bool terminated, bool truncated) @safe {
        if (truncated)
            ++heads;
    };
    framer.push(b("aaaa\nbbbb\ncc\ndddd"), ProcessStream.stdout_, emit);
    framer.flushEof(ProcessStream.stdout_, emit);
    assert(heads == 3 && framer.truncatedLines == 3);
    // Unbounded: an over-cap-looking line is just a line.
    assert(frameAll(0, [b("abcdef\n")]) == [FramedLine(b("abcdef"), true, false)]);
}

@("proc.LineFramer.longLineIsLinear")
@system
unittest
{
    import core.time : MonoTime, seconds;

    // 2 MiB of one line in 512-byte reads: the quadratic rescan this framer
    // replaced needed ~5.6 s for a quarter of that; linear is milliseconds.
    // The bound is generous so parallel test load cannot fail it.
    ubyte[512] chunk = 'a';
    LineFramer framer;
    size_t fragments;
    auto emit = delegate(ProcessStream stream, const(ubyte)[] bytes,
        bool terminated, bool truncated) @safe {
        assert(!terminated && bytes.length == 2 * 1024 * 1024);
        ++fragments;
    };
    const before = MonoTime.currTime;
    foreach (_; 0 .. 4096)
        framer.push(chunk[], ProcessStream.stdout_, emit);
    framer.flushEof(ProcessStream.stdout_, emit);
    assert(fragments == 1);
    assert(MonoTime.currTime - before < 5.seconds, "framing must be O(n)");
}
