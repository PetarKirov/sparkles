/++
Launch every windowed application and require it to come up and exit cleanly
(`--smoke-apps`).

$(B The gap this fills is not a platform, it is a verb.) `nix build .#all-desktop`
compiles hue, terminal, ui-gallery and diagram on both Linux and macOS, so a
compile error in any of them has always been caught. Nothing has ever $(I run)
one — which is how a window that aborted on startup, before it drew a single
frame, reached `main`: the crash was in a call the compiler is happy with,
`InitWindow(…, title.ptr)`, on a slice that carries no terminator.

The applications need no cooperation. `sparkles:ui-app` bounds a run from
`SPARKLES_UI_FRAMES` (`HST21`) and reports the outcome on stderr in one line;
this module launches the binary, reads that line, and decides. Nothing here is
per-application except which binaries exist and which arms they carry.

Split from `app.d` so $(LREF judgeSmokeRun) — the part with the interesting
cases, and the only part that has an opinion — is a table of unit tests rather
than something observable only by launching four processes.
+/
module smoke_apps;

import std.algorithm : canFind, startsWith;
import std.conv : to;
import std.string : indexOf, lineSplitter, strip;

/// The prefix `sparkles:ui-app` puts on every line this module reads.
enum smokeLinePrefix = "sparkles-ui-app:";

/// Which backend an application is being asked to open.
enum SmokeArm : ubyte
{
    gui, /// a window
    tui, /// a terminal, which therefore needs a pty
}

/// One launch: an arm, and the arguments that select it.
struct SmokeRun
{
    SmokeArm arm;
    immutable(string)[] args;
}

/// One application, and the launches it is expected to survive.
struct SmokeApp
{
    string name;      /// the dub sub-package and the binary's name
    string nixOutput; /// the flake output that builds it
    immutable(SmokeRun)[] runs;
}

/**
The applications this check covers.

All four of them, deliberately. Three would have been the ones that had a `nix`
package; `diagram` did not, which is exactly why it is here — an application
nothing builds is an application nothing notices breaking.

$(B The arguments are per application, not per arm.) `apps/terminal` is a raylib
terminal emulator: it has one backend, no `--gui` flag to select it, and no
terminal arm to run inside another terminal. Passing the flags the other three
take would have it exit on an argument error, which is a failure that says
nothing about whether its window comes up.
*/
immutable SmokeApp[] smokeApps = [
    SmokeApp("hue", "hue", [
        SmokeRun(SmokeArm.gui, ["--gui"]),
        SmokeRun(SmokeArm.tui, ["--tui"]),
    ]),
    SmokeApp("terminal", "terminal", [
        SmokeRun(SmokeArm.gui, []),
    ]),
    SmokeApp("ui-gallery", "ui-gallery", [
        SmokeRun(SmokeArm.gui, ["--gui"]),
        SmokeRun(SmokeArm.tui, ["--tui"]),
    ]),
    SmokeApp("diagram", "diagram", [
        SmokeRun(SmokeArm.gui, ["--gui"]),
        SmokeRun(SmokeArm.tui, ["--tui"]),
    ]),
];

/// What a launch amounted to.
enum SmokeVerdict : ubyte
{
    passed,  /// it opened, drew, and exited 0
    skipped, /// this build or this machine has no such backend
    failed,  /// anything else
}

/// ditto
struct SmokeResult
{
    SmokeVerdict verdict;
    string reason;  /// why, for a skip or a failure; empty on a pass
    string detail;  /// the child's own last words, for a skip or a failure
    ulong frames;   /// passes the run reported
    ulong painted;  /// of those, the ones that drew
}

/**
Decides what a finished launch means, from its exit status and stderr alone.

The three outcomes are genuinely distinct and an exit status cannot tell them
apart, which is why `sparkles:ui-app` prints a line at all:

$(LIST
    $(ITEM $(B skipped) — the run said `outcome=noBackend` or `outcome=openFailed`.
        A CI runner with no display, or a build compiled without the arm. Not a
        failure: reporting one would train everyone to ignore this check.)
    $(ITEM $(B failed) — a non-zero status with no such line. The process died
        rather than declining, which is the case this whole check exists for.)
    $(ITEM $(B passed) — it reported frames, painted at least one, and exited 0.)
)

The `painted >= 1` requirement is the part worth stating: a run that exits 0
having drawn nothing has proved that the process starts, not that it renders,
and the original failure was in code reached only while creating the surface.

An application is allowed to finish $(I early) — a `--render`-style path, or one
that quits on its own — so fewer frames than requested is not a fault. More
would be, since the budget would not have been honoured.
*/
SmokeResult judgeSmokeRun(int status, const(char)[] stderrText, int requested)
    @safe
{
    SmokeResult r;

    foreach (line; stderrText.lineSplitter)
    {
        const t = line.strip;
        if (!t.startsWith(smokeLinePrefix))
            continue;
        const rest = t[smokeLinePrefix.length .. $].strip;

        if (rest.startsWith("outcome="))
        {
            const outcome = rest["outcome=".length .. $].strip;
            // `notInteractive` means the caller asked for `--html`/`--ansi`,
            // which this check never does; treat it as the harness's own bug
            // rather than quietly skipping.
            if (outcome == "noBackend" || outcome == "openFailed")
            {
                r.verdict = SmokeVerdict.skipped;
                r.reason = "no backend on this machine (" ~ outcome.idup ~ ")";
                return r;
            }
            r.verdict = SmokeVerdict.failed;
            r.reason = "unexpected outcome=" ~ outcome.idup;
            return r;
        }

        if (rest.startsWith("frames="))
        {
            if (!parseCounts(rest, r.frames, r.painted))
            {
                r.verdict = SmokeVerdict.failed;
                r.reason = "could not read the frame report: " ~ t.idup;
                return r;
            }
        }
    }

    if (status != 0)
    {
        r.verdict = SmokeVerdict.failed;
        r.reason = describeExit(status) ~ (r.frames == 0
            ? " without reaching a frame"
            : " after " ~ r.frames.to!string ~ " frames");
        return r;
    }

    if (r.frames == 0)
    {
        r.verdict = SmokeVerdict.failed;
        r.reason = "exited 0 without reporting a bounded run — is "
            ~ "SPARKLES_UI_FRAMES reaching it?";
        return r;
    }

    if (r.painted == 0)
    {
        r.verdict = SmokeVerdict.failed;
        r.reason = "ran " ~ r.frames.to!string ~ " frames without painting one";
        return r;
    }

    if (requested > 0 && r.frames > requested)
    {
        r.verdict = SmokeVerdict.failed;
        r.reason = "ran " ~ r.frames.to!string ~ " frames past a budget of "
            ~ requested.to!string;
        return r;
    }

    r.verdict = SmokeVerdict.passed;
    return r;
}

// `std.process.wait` reports a signal as its negation, and a crash arrives as a
// signal — which is exactly the case this check is for, so it must not be
// rendered as the puzzling "exited -6".
private string describeExit(int status) @safe
{
    if (status >= 0)
        return "exited " ~ status.to!string;

    const signal = -status;
    string name;
    switch (signal)
    {
        case 4:  name = " (SIGILL)";  break;
        case 6:  name = " (SIGABRT)"; break;
        case 8:  name = " (SIGFPE)";  break;
        case 9:  name = " (SIGKILL)"; break;
        case 10: name = " (SIGBUS)";  break;
        case 11: name = " (SIGSEGV)"; break;
        default: break;
    }
    return "killed by signal " ~ signal.to!string ~ name;
}

// `frames=N painted=M backend=X` → the two numbers. Deliberately tolerant about
// what follows: a future field must not turn a healthy run into a failure.
private bool parseCounts(const(char)[] rest, out ulong frames, out ulong painted)
    @safe
{
    bool haveFrames, havePainted;
    foreach (field; rest.splitOnSpaces)
    {
        const eq = field.indexOf('=');
        if (eq < 0)
            continue;
        const key = field[0 .. eq];
        const value = field[eq + 1 .. $];
        try
        {
            if (key == "frames")
            {
                frames = value.to!ulong;
                haveFrames = true;
            }
            else if (key == "painted")
            {
                painted = value.to!ulong;
                havePainted = true;
            }
        }
        catch (Exception)
            return false;
    }
    return haveFrames && havePainted;
}

private const(char)[][] splitOnSpaces(const(char)[] s) @safe
{
    import std.algorithm : filter, splitter;
    import std.array : array;

    return s.splitter(' ').filter!(f => f.length != 0).array;
}

// ---------------------------------------------------------------------------
// Tests — the whole decision, with no process launched.
// ---------------------------------------------------------------------------

@("smoke_apps.judge.aCleanRunPasses")
@safe
unittest
{
    const r = judgeSmokeRun(0,
        "sparkles-ui-app: frames=3 painted=3 backend=gui\n", 3);
    assert(r.verdict == SmokeVerdict.passed);
    assert(r.frames == 3 && r.painted == 3);
}

@("smoke_apps.judge.theOriginalBugFails")
@safe
unittest
{
    // What the crash looked like: the process aborted inside window creation,
    // so it never reached a frame and never printed a report. An exit status
    // alone is all there is, and it must not be mistaken for a skip.
    const r = judgeSmokeRun(-6, "libc++abi: terminating due to uncaught "
        ~ "exception of type NSException\n", 3);
    assert(r.verdict == SmokeVerdict.failed);
    assert(r.reason.canFind("without reaching a frame"));
    // A signal is reported as one. `std.process.wait` negates it, and "exited
    // -6" reads as nonsense at the moment someone most needs the message.
    assert(r.reason.canFind("SIGABRT"), r.reason);
}

@("smoke_apps.judge.noDisplayIsASkipNotAFailure")
@safe
unittest
{
    // A runner with no window server, and a build compiled without the arm,
    // report the same way. Failing either would train everyone to ignore this.
    foreach (outcome; ["noBackend", "openFailed"])
    {
        const r = judgeSmokeRun(1,
            "sparkles-ui-app: outcome=" ~ outcome ~ "\n"
            ~ "ui-gallery: the backend would not open\n", 3);
        assert(r.verdict == SmokeVerdict.skipped, outcome);
    }
}

@("smoke_apps.judge.exitingZeroWithoutPaintingIsAFailure")
@safe
unittest
{
    // The process starting is not the claim. The failure this check exists for
    // was in code reached only while creating the surface, so a run that never
    // drew has proved nothing about it.
    const r = judgeSmokeRun(0,
        "sparkles-ui-app: frames=3 painted=0 backend=tui\n", 3);
    assert(r.verdict == SmokeVerdict.failed);
    assert(r.reason.canFind("without painting"));

    // Silence is also a failure, and names the likely cause: the harness sets
    // the budget through the environment, so a build that ignores it exits 0
    // only because the window was closed by hand — or never at all.
    const silent = judgeSmokeRun(0, "", 3);
    assert(silent.verdict == SmokeVerdict.failed);
    assert(silent.reason.canFind("SPARKLES_UI_FRAMES"));
}

@("smoke_apps.judge.finishingEarlyIsFineFinishingLateIsNot")
@safe
unittest
{
    // An application may quit on its own before the budget runs out.
    assert(judgeSmokeRun(0, "sparkles-ui-app: frames=1 painted=1 backend=gui\n",
        5).verdict == SmokeVerdict.passed);

    // Overrunning it means the budget was not honoured, which is the one
    // property the harness depends on.
    const over = judgeSmokeRun(0,
        "sparkles-ui-app: frames=9 painted=9 backend=gui\n", 5);
    assert(over.verdict == SmokeVerdict.failed);
    assert(over.reason.canFind("past a budget"));
}

@("smoke_apps.judge.readsTheReportOutOfSurroundingNoise")
@safe
unittest
{
    // stderr carries whatever the application and its libraries write. The
    // report is found by its prefix, and unknown trailing fields are ignored
    // so adding one later cannot fail a healthy run.
    const r = judgeSmokeRun(0,
        "WARNING: GLFW: something\n"
        ~ "  sparkles-ui-app: frames=2 painted=1 backend=gui vsync=on \n"
        ~ "INFO: shutting down\n", 2);
    assert(r.verdict == SmokeVerdict.passed);
    assert(r.frames == 2 && r.painted == 1);

    // A malformed report is a failure rather than a silent pass: it means the
    // contract moved and nobody updated this side.
    const bad = judgeSmokeRun(0, "sparkles-ui-app: frames=lots painted=1\n", 2);
    assert(bad.verdict == SmokeVerdict.failed);
    assert(bad.reason.canFind("could not read"));
}

@("smoke_apps.appsCoverEveryWindowedApplication")
@safe
unittest
{
    // The list is the check's scope, so a new application must be added here
    // deliberately. `diagram` is in it because it had no nix package at all —
    // an application nothing builds is one nothing notices breaking.
    import std.algorithm : map;

    assert(smokeApps.length == 4);
    foreach (app; smokeApps)
    {
        assert(app.runs.length >= 1, app.name);
        assert(app.runs.map!(r => r.arm).canFind(SmokeArm.gui),
            app.name ~ " has no window arm");
    }

    // `terminal` is a raylib emulator: one backend, no flag to select it, and
    // no terminal arm to run inside another terminal. Handing it the other
    // three's flags would fail it on an argument error, which says nothing
    // about whether its window comes up.
    foreach (app; smokeApps)
        if (app.name == "terminal")
        {
            assert(!app.runs.map!(r => r.arm).canFind(SmokeArm.tui));
            assert(app.runs[0].args.length == 0);
        }
}

// ---------------------------------------------------------------------------
// The launcher.
// ---------------------------------------------------------------------------

import std.stdio : File;

/// How `--smoke-apps` runs.
struct SmokeOptions
{
    /// Frames to ask each run for. Small: this proves a surface comes up, not
    /// that it stays up, and every frame is wall-clock on a shared runner.
    int frames = 3;

    /// Per-launch wall-clock cap. A hang is a failure, not a job that runs
    /// until the workflow's own limit and reports nothing useful.
    int timeoutMs = 60_000;

    /// Where the binaries are, if not in one of the usual places.
    string binDir;

    /// Only these applications, by name. Empty means all of them.
    string[] only;
}

/**
Runs the whole check and returns a process exit status.

Zero when every application either passed or skipped for want of a backend.
A skip is printed as loudly as a pass, because a check that silently skipped
everywhere would look exactly like a check that works.
*/
int runSmokeApps(in SmokeOptions opt)
{
    import std.algorithm : canFind;
    import std.stdio : writefln, writeln;

    // An unknown name would otherwise select nothing and exit 0 — a check that
    // reports success having run no application at all.
    foreach (name; opt.only)
        if (!smokeApps.canFind!(a => a.name == name))
        {
            writefln("smoke: no application named `%s`", name);
            return 1;
        }

    int failures, passes, skips;

    foreach (app; smokeApps)
    {
        if (opt.only.length != 0 && !opt.only.canFind(app.name))
            continue;

        const binary = locateSmokeBinary(app, opt.binDir);
        if (binary is null)
        {
            ++failures;
            writefln("  ✗ %-12s could not find a binary — build it first "
                ~ "(nix build .#all-desktop, or dub build :%s)", app.name, app.name);
            continue;
        }

        foreach (run; app.runs)
        {
            const label = app.name ~ (run.args.length ? " " ~ run.args[0] : "");
            const r = launch(binary, run, opt);
            final switch (r.verdict)
            {
                case SmokeVerdict.passed:
                    ++passes;
                    writefln("  ✓ %-22s %s frames, %s painted",
                        label, r.frames, r.painted);
                    break;
                case SmokeVerdict.skipped:
                    ++skips;
                    writefln("  ⊘ %-22s %s", label, r.reason);
                    if (r.detail.length)
                        writefln("      %s", r.detail);
                    break;
                case SmokeVerdict.failed:
                    ++failures;
                    writefln("  ✗ %-22s %s", label, r.reason);
                    if (r.detail.length)
                        writefln("      %s", r.detail);
                    break;
            }
        }
    }

    writeln();
    writefln("smoke: %s passed, %s skipped, %s failed", passes, skips, failures);
    // Everything skipping is not a pass. It means no runner in this job can
    // open a backend, and the check is proving nothing — say so.
    if (failures == 0 && passes == 0 && skips != 0)
        writeln("smoke: nothing actually ran — no backend was available anywhere");
    return failures == 0 ? 0 : 1;
}

/**
Where an application's binary is, or `null`.

Three places, in the order that makes a local run and a CI run both work
without a flag: an explicit directory, the `all-desktop` link farm the
`nix-build` job already produces, and the `dub build` output an in-tree
iteration leaves behind.
*/
string locateSmokeBinary(in SmokeApp app, string binDir) @safe
{
    import std.file : exists;
    import std.path : buildPath;

    // In-tree, `dub build :diagram` names its target after the sub-package —
    // `sparkles_diagram` — while the nix build, whose root package IS the app,
    // produces `diagram`. Both spellings are tried rather than encoded per
    // application, since which one exists says only how it was built.
    const dubName = "sparkles_" ~ app.name;
    string[] candidates;
    if (binDir.length != 0)
        candidates ~= [buildPath(binDir, app.name), buildPath(binDir, dubName)];
    candidates ~= buildPath("result", app.nixOutput, "bin", app.name);
    candidates ~= buildPath("apps", app.name, "build", app.name);
    candidates ~= buildPath("apps", app.name, "build", dubName);

    foreach (c; candidates)
        if (c.exists)
            return c;
    return null;
}

private SmokeResult launch(string binary, in SmokeRun spec, in SmokeOptions opt)
{
    version (Posix)
    {
        const run = spec.arm == SmokeArm.tui
            ? runOnPty(binary, spec, opt)
            : runPlain(binary, spec, opt);
    }
    else
    {
        if (spec.arm == SmokeArm.tui)
        {
            SmokeResult r;
            r.verdict = SmokeVerdict.skipped;
            r.reason = "no pty on this platform";
            return r;
        }
        const run = runPlain(binary, spec, opt);
    }

    if (run.timedOut)
    {
        SmokeResult r;
        r.verdict = SmokeVerdict.failed;
        r.reason = "did not exit within " ~ (opt.timeoutMs / 1000).to!string
            ~ "s — the frame budget did not end it";
        return r;
    }

    auto r = judgeSmokeRun(run.status, run.stderrText, opt.frames);
    // A skip nobody can act on is barely better than no check. "no backend on
    // this machine" covers a headless runner, a build without the arm, and a
    // window that opened with no font — three different things to do about it,
    // so the application's own last words come along.
    if (r.verdict != SmokeVerdict.passed)
        r.detail = lastLines(run.stderrText.length != 0
            ? run.stderrText : run.stdoutText, 3);
    return r;
}

/// The last `n` non-blank lines of `text`, joined — a child's parting words.
string lastLines(const(char)[] text, size_t n) @safe
{
    import std.algorithm : filter, joiner, map;
    import std.array : array, join;
    import std.string : lineSplitter, strip;

    auto lines = text.lineSplitter
        .map!(l => l.strip.idup)
        .filter!(l => l.length != 0 && !l.startsWith(smokeLinePrefix))
        .array;
    if (lines.length > n)
        lines = lines[$ - n .. $];
    return lines.join(" · ");
}

private struct RunOutput
{
    int status;
    string stderrText;
    string stdoutText; /// raylib and GLFW report on stdout, not stderr
    bool timedOut;
}

private string[string] smokeEnv(in SmokeOptions opt)
{
    import std.process : environment;

    auto env = environment.toAA;
    env["SPARKLES_UI_FRAMES"] = opt.frames.to!string;
    return env;
}

// The window arm: no tty needed, so stdout and stderr are plain files.
private RunOutput runPlain(string binary, in SmokeRun spec, in SmokeOptions opt)
{
    import std.file : readText, remove;
    import std.path : buildPath;
    import std.process : Config, spawnProcess;
    import std.stdio : File;

    const errPath = tempPath("smoke-err");
    const outPath = tempPath("smoke-out");
    scope (exit)
    {
        tryRemove(errPath);
        tryRemove(outPath);
    }

    auto devNull = File(nullDevice, "rb");
    auto outFile = File(outPath, "wb");
    auto errFile = File(errPath, "wb");

    auto pid = spawnProcess(binary ~ spec.args, devNull, outFile, errFile,
        smokeEnv(opt), Config.none);

    RunOutput r;
    r.timedOut = !waitWithin(pid, opt.timeoutMs, r.status);
    outFile.close();
    errFile.close();
    r.stderrText = readTextOrEmpty(errPath);
    r.stdoutText = readTextOrEmpty(outPath);
    return r;
}

version (Posix)
{
    // The terminal arm: `sparkles:ui-app` requires stdin AND stdout to be a
    // terminal, so both get the pty slave. stderr stays a plain file — the
    // report has to arrive uncontaminated by the escape stream it is reporting
    // on, which is the whole reason `HST21` writes it there.
    private RunOutput runOnPty(string binary, in SmokeRun spec, in SmokeOptions opt)
    {
        import core.sys.posix.fcntl : open, O_NOCTTY, O_RDWR;
        import core.sys.posix.stdlib : grantpt, posix_openpt, ptsname, unlockpt;
        import core.sys.posix.unistd : closeFd = close;
        import std.process : Config, spawnProcess;
        import std.stdio : File;
        import std.string : fromStringz;

        RunOutput r;

        const master = (() @trusted => posix_openpt(O_RDWR | O_NOCTTY))();
        if (master < 0)
        {
            r.status = -1;
            r.stderrText = smokeLinePrefix ~ " outcome=noBackend\n";
            return r;
        }
        scope (exit) () @trusted { closeFd(master); }();

        const slave = () @trusted {
            if (grantpt(master) != 0 || unlockpt(master) != 0)
                return -1;
            auto name = ptsname(master);
            return name is null ? -1 : open(name, O_RDWR | O_NOCTTY);
        }();
        if (slave < 0)
        {
            r.status = -1;
            r.stderrText = smokeLinePrefix ~ " outcome=noBackend\n";
            return r;
        }

        // A freshly opened pty has no size, and a terminal application handed
        // a 0x0 surface lays out against nothing and paints nothing — which
        // this check would report as a failure to render. Give it a real one,
        // fixed so both runners see the same thing.
        setPtySize(master, 100, 30);

        const errPath = tempPath("smoke-err");
        scope (exit) tryRemove(errPath);

        File tty;
        () @trusted { tty.fdopen(slave, "r+"); }();
        auto errFile = File(errPath, "wb");

        auto pid = spawnProcess(binary ~ spec.args, tty, tty, errFile,
            smokeEnv(opt), Config.none);
        // The parent's copy is closed as soon as the child holds one, so the
        // master sees EOF when the child exits rather than hanging on a fd
        // nobody will write to.
        tty.close();

        r.timedOut = !waitDraining(pid, master, opt.timeoutMs, r.status);
        errFile.close();
        r.stderrText = readTextOrEmpty(errPath);
        return r;
    }

    private void setPtySize(int master, ushort cols, ushort rows) @trusted
    {
        import core.sys.posix.sys.ioctl : ioctl, TIOCSWINSZ, winsize;

        winsize ws;
        ws.ws_col = cols;
        ws.ws_row = rows;
        cast(void) ioctl(master, TIOCSWINSZ, &ws);
    }

    // A terminal application fills the tty buffer within a frame or two, and a
    // full buffer blocks the writer — so the master must be read while waiting,
    // not after. The bytes themselves are the escape stream and are discarded.
    private bool waitDraining(Pid)(Pid pid, int master, int timeoutMs,
        out int status)
    {
        import core.sys.posix.poll : poll, pollfd, POLLIN;
        import core.sys.posix.unistd : read;
        import core.time : MonoTime, msecs;
        import std.process : tryWait;

        const deadline = MonoTime.currTime + timeoutMs.msecs;
        ubyte[4096] sink = void;
        while (MonoTime.currTime < deadline)
        {
            () @trusted {
                pollfd pfd;
                pfd.fd = master;
                pfd.events = POLLIN;
                if (poll(&pfd, 1, 50) > 0)
                    cast(void) read(master, sink.ptr, sink.length);
            }();

            const w = tryWait(pid);
            if (w.terminated)
            {
                status = w.status;
                return true;
            }
        }
        killAndReap(pid, status);
        return false;
    }
}

private bool waitWithin(Pid)(Pid pid, int timeoutMs, out int status)
{
    import core.thread : Thread;
    import core.time : MonoTime, msecs;
    import std.process : tryWait;

    const deadline = MonoTime.currTime + timeoutMs.msecs;
    while (MonoTime.currTime < deadline)
    {
        const w = tryWait(pid);
        if (w.terminated)
        {
            status = w.status;
            return true;
        }
        Thread.sleep(25.msecs);
    }
    killAndReap(pid, status);
    return false;
}

private void killAndReap(Pid)(Pid pid, out int status)
{
    import std.process : kill, wait;

    try
    {
        kill(pid);
        status = wait(pid);
    }
    catch (Exception)
        status = -1;
}

private string nullDevice() @safe
{
    version (Posix)
        return "/dev/null";
    else
        return "NUL";
}

private string tempPath(string stem) @safe
{
    import std.conv : to;
    import std.file : tempDir;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import std.random : uniform;

    return buildPath(tempDir,
        stem ~ "-" ~ thisProcessID.to!string ~ "-" ~ uniform(0, 1 << 24).to!string);
}

private void tryRemove(string path) @safe nothrow
{
    import std.file : exists, remove;

    try
    {
        if (path.exists)
            path.remove();
    }
    catch (Exception)
    {
    }
}

private string readTextOrEmpty(string path) @safe nothrow
{
    import std.file : readText;

    try
        return readText(path);
    catch (Exception)
        return "";
}
