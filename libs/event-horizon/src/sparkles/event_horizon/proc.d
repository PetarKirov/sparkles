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
/// `terminated == false` marks the final EOF fragment.
struct ProcessLine
{
    ProcessStream stream;
    const(ubyte)[] bytes; /// callback-borrowed; line terminator excluded
    bool terminated;      /// false only for the final EOF fragment
}

/// Cumulative resource usage of the supervised process tree (SPEC §13.8):
/// peak summed RSS and peak live-process count over the run, elapsed wall
/// time, and best-effort user/system CPU. Unsupported counters leave
/// `sampled == false` rather than fabricating zero-valued measurements;
/// `wallTime` is always valid.
struct ProcessResourceUsage
{
    size_t peakRssBytes;
    size_t peakProcesses;
    size_t sampleCount;
    Duration wallTime;
    Duration userTime;
    Duration systemTime;
    bool sampled;
}

/// One supervision event (SPEC §13.5): exactly one field is meaningful,
/// selected by `kind`. Delivered synchronously on the original supervising
/// scheduler fiber; the sink must not retain `line.bytes`.
struct ProcessEvent
{
    ProcessEventKind kind;
    ProcessLine line;           /// valid for `ProcessEventKind.line`
    ProcessResourceUsage usage; /// valid for `ProcessEventKind.sample`
    ExitStatus status;          /// valid for `ProcessEventKind.exited`
    ProcessEnd end;             /// valid for `ProcessEventKind.exited`
}

/// Knobs of one supervised run (SPEC §13.5). Zero `timeout` means no
/// deadline; zero `sampleInterval` means final accounting only.
struct SupervisedProcessConfig
{
    import core.time : Duration, msecs, seconds;

    ProcessConfig process;
    Duration timeout = Duration.zero;    /// zero = no deadline
    Duration terminateGrace = 5.seconds; /// TERM → grace → KILL
    Duration sampleInterval = 250.msecs; /// zero = final accounting only
    bool collectOutput = true;           /// accumulation only; never draining
}

/// The outcome of one supervised run (SPEC §13.5). `stdout_`/`stderr_`
/// hold the exact raw bytes including original terminators, independently
/// of the normalized line events; empty unless that stream was piped.
struct SupervisedProcessResult
{
    import sparkles.base.buffer : SharedBuffer;

    ProcessEnd end;
    ExitStatus status; /// valid once a child existed and was reaped
    ProcessResourceUsage usage;
    SharedBuffer!(ubyte, 256) stdout_;
    SharedBuffer!(ubyte, 256) stderr_;
    IoError spawnError; /// valid only for `ProcessEnd.spawnFailed`
}

/// The synchronous event callback of $(LREF sparkles.event_horizon.live.supervise)
/// (SPEC §13.5): runs on the original supervising scheduler fiber, must not retain
/// `event.line.bytes`, and reports failure by throwing — which cancels the
/// run's scope and converges on the same teardown as any other cancellation.
alias ProcessEventSink = void delegate(in ProcessEvent event);
