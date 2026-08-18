/**
Live (ring-backed) capability implementations (SPEC §10.3, §11): the
production `RingClock`/`RingNet`/`RingProc` that `LoopGroup` hands to the
root fiber as the `Env` row. They mirror the effects-side test doubles
(`TestClock`, `SimNet`, `SimProc`) exactly — any function generic over its
`Ctx` runs unmodified against either.

Loop-side module: these capabilities close over the scheduler and issue real
ring ops, so they cannot live effects-side. The subprocess spawn machinery
(SPEC §13.2–§13.3: `ChildProcess`, `spawnProcess`, `spawnPty`, `wait`)
lives here for the same reason — `proc` keeps the effects-side vocabulary.
*/
module sparkles.event_horizon.live;

version (Posix)  :  // POSIX sockets; rides the selected backend

import core.time : Duration, MonoTime;

import sparkles.event_horizon.backend.concept : canSubmitOp;
import sparkles.event_horizon.backend.select : DefaultBackend;
import sparkles.event_horizon.capability : CtxOf;
import sparkles.event_horizon.errors : IoErrorStage, IoResult, OpKind, ioErr, ioOk;
import sparkles.event_horizon.io : FileHandle, Listener, Stream, accept, connect;
import sparkles.event_horizon.net : SockAddr;
import sparkles.event_horizon.op : OpWaitid;
import sparkles.event_horizon.proc : ExitStatus, ProcessConfig, StdioMode, StdioSpec;
import sparkles.event_horizon.sched : Sched;

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

/// The live net capability: sockets, listeners, and connections over the
/// ring. `Stream`/`Listener` are the tier-B `io` handles, so the direct
/// verbs (`recv`/`send`/`accept`) apply by UFCS.
struct RingNet
{
    enum string capName = "net";

    /// The connected-stream handle type (SPEC §10.3 `isNet`).
    alias Stream = .Stream;

    /// The listening-socket handle type.
    alias Listener = .Listener;

    private Sched* _sched;

    /// Binds to the scheduler whose ring backs the socket ops.
    this(Sched* sched) @safe pure nothrow @nogc
    {
        _sched = sched;
    }

    /// Creates a TCP socket, binds it to `at`, and listens.
    IoResult!Listener listen(SockAddr at, int backlog = 128) @trusted nothrow
    {
        import core.sys.posix.netinet.in_ : sockaddr;
        import core.sys.posix.sys.socket : AF_INET, SOCK_STREAM, SOL_SOCKET,
            SO_REUSEADDR, bind, listen_ = listen, setsockopt, socket;

        const fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0)
            return ioErr!Listener(errnoNow, OpKind.none, IoErrorStage.setup,
                "socket() failed");
        int one = 1;
        cast(void) setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, one.sizeof);
        if (bind(fd, cast(sockaddr*) at.storage.ptr, at.len) != 0
            || listen_(fd, backlog) != 0)
        {
            closeFd(fd);
            return ioErr!Listener(errnoNow, OpKind.none, IoErrorStage.setup,
                "bind/listen failed");
        }
        return ioOk(Listener(fd));
    }

    /// Creates a TCP socket and connects it to `to` (parks on the ring).
    IoResult!Stream connect(SockAddr to)
    {
        import core.sys.posix.sys.socket : AF_INET, SOCK_STREAM, socket;

        const fd = (() @trusted => socket(AF_INET, SOCK_STREAM, 0))();
        if (fd < 0)
            return ioErr!Stream(errnoNow, OpKind.none, IoErrorStage.setup,
                "socket() failed");
        auto s = Stream(fd);
        auto r = .connect(s, to);
        if (r.hasError)
        {
            s.close();
            return ioErr!Stream(r.error);
        }
        return ioOk(s);
    }

    private static int errnoNow() @trusted nothrow @nogc
    {
        import core.stdc.errno : errno;

        return errno;
    }

    private static void closeFd(int fd) @trusted nothrow @nogc
    {
        import core.sys.posix.unistd : close;

        close(fd);
    }
}

// ── subprocesses (SPEC §13.2–§13.3) ─────────────────────────────────────────

/// A spawned child (SPEC §13.2): its pid and the parent ends of whichever
/// streams were piped (`FileHandle(-1)` otherwise). A PTY child's master
/// rides `ptyMaster`.
struct ChildProcess
{
    int pid = -1;       /// -1 after a successful `wait`
    FileHandle stdinW;  /// write end of the child's stdin  (piped only)
    FileHandle stdoutR; /// read end of the child's stdout  (piped only)
    FileHandle stderrR; /// read end of the child's stderr  (piped only)
    FileHandle ptyMaster; /// the PTY master (`spawnPty` only)

    /// `true` while the child is reapable.
    bool opCast(T : bool)() const @safe pure nothrow @nogc => pid > 0;

    /// Signals the child. `ESRCH` after a successful `wait` — the handle
    /// nulls the pid before the kernel can recycle it, so a stale kill can
    /// never reach an unrelated process.
    IoResult!void kill(int sig = 15 /* SIGTERM */) @trusted nothrow @nogc
    {
        import core.stdc.errno : errno;
        import core.sys.posix.signal : kill_ = kill;

        if (pid <= 0)
            return ioErr!void(3 /* ESRCH */, OpKind.none, IoErrorStage.submit,
                "child already reaped");
        if (kill_(pid, sig) != 0)
            return ioErr!void(errno, OpKind.none, IoErrorStage.submit,
                "kill failed");
        return ioOk();
    }

    /// Signals the child's process group (requires
    /// `ProcessConfig.newProcessGroup` at spawn — the group id is the pid).
    IoResult!void killGroup(int sig = 15 /* SIGTERM */) @trusted nothrow @nogc
    {
        import core.stdc.errno : errno;
        import core.sys.posix.signal : kill_ = kill;

        if (pid <= 0)
            return ioErr!void(3 /* ESRCH */, OpKind.none, IoErrorStage.submit,
                "child already reaped");
        if (kill_(-pid, sig) != 0)
            return ioErr!void(errno, OpKind.none, IoErrorStage.submit,
                "killGroup failed");
        return ioOk();
    }
}

/**
Spawns `argv` (PATH-searched) per `cfg` (SPEC §13.1–§13.2): per-stream
pipes / /dev/null / borrowed fds, "KEY=value" environment, working
directory, and an optional fresh process group. `posix_spawnp`, never
`fork` — a fiber stack is the worst possible place for a fork. Spawning is
a setup-phase operation and may allocate (argv/env staging is heap-built;
the M7 4 KiB budget and its `E2BIG` are gone).
*/
IoResult!ChildProcess spawnProcess(scope const(char[])[] argv,
    in ProcessConfig cfg = ProcessConfig()) @trusted
{
    import core.stdc.errno : errno;
    import core.sys.posix.fcntl : O_RDONLY, O_WRONLY;
    import core.sys.posix.spawn : posix_spawn_file_actions_adddup2,
        posix_spawn_file_actions_addclose, posix_spawn_file_actions_addopen,
        posix_spawn_file_actions_destroy, posix_spawn_file_actions_init,
        posix_spawn_file_actions_t, posix_spawnattr_destroy,
        posix_spawnattr_init, posix_spawnattr_setflags,
        posix_spawnattr_setpgroup, posix_spawnattr_t, posix_spawnp,
        POSIX_SPAWN_SETPGROUP;
    import core.sys.posix.unistd : close;

    if (argv.length == 0)
        return ioErr!ChildProcess(22 /* EINVAL */, OpKind.none,
            IoErrorStage.submit, "empty argv");

    // Parent/child pipe ends per stream; -1 = not piped.
    int[2] inPipe = -1, outPipe = -1, errPipe = -1;
    scope (failure) closePipes(inPipe, outPipe, errPipe);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    scope (exit) posix_spawn_file_actions_destroy(&actions);

    // One stream's plumbing; returns false on pipe() failure.
    bool wire(in StdioSpec spec, int childFd, ref int[2] pipeFds, bool childReads)
    {
        final switch (spec.mode)
        {
            case StdioMode.inherit:
                return true;
            case StdioMode.pipe:
                if (!openPipe(pipeFds))
                    return false;
                const childEnd = childReads ? pipeFds[0] : pipeFds[1];
                posix_spawn_file_actions_adddup2(&actions, childEnd, childFd);
                posix_spawn_file_actions_addclose(&actions, pipeFds[0]);
                posix_spawn_file_actions_addclose(&actions, pipeFds[1]);
                return true;
            case StdioMode.nullDev:
                posix_spawn_file_actions_addopen(&actions, childFd,
                    "/dev/null", childReads ? O_RDONLY : O_WRONLY, 0);
                return true;
            case StdioMode.fd:
                posix_spawn_file_actions_adddup2(&actions, spec.fd, childFd);
                return true;
            case StdioMode.mergeStdout:
                // Valid for stderr only (checked before wiring). The stdout
                // action has already run by the time this one does, so child
                // fd 1 is whatever stdoutSpec chose — pipe, null, or a
                // borrowed fd alike.
                posix_spawn_file_actions_adddup2(&actions, 1, childFd);
                return true;
        }
    }

    if (cfg.stdinSpec.mode == StdioMode.mergeStdout
        || cfg.stdoutSpec.mode == StdioMode.mergeStdout)
        return ioErr!ChildProcess(22 /* EINVAL */, OpKind.none,
            IoErrorStage.submit, "mergeStdout is stderr-only");

    if (!wire(cfg.stdinSpec, 0, inPipe, true)
        || !wire(cfg.stdoutSpec, 1, outPipe, false)
        || !wire(cfg.stderrSpec, 2, errPipe, false))
        return ioErr!ChildProcess(24 /* EMFILE */, OpKind.none,
            IoErrorStage.submit, "pipe failed");

    if (cfg.cwd !is null)
        posix_spawn_file_actions_addchdir_np(&actions, zstring(cfg.cwd));

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    scope (exit) posix_spawnattr_destroy(&attr);
    if (cfg.newProcessGroup)
    {
        posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
        posix_spawnattr_setpgroup(&attr, 0);
    }

    auto cargv = cstrings(argv);
    // Bound to a named local rather than used as a bare `.ptr`: the slice is
    // the only thing keeping the inner `char[]`s reachable, and the child's
    // environment must survive until posix_spawnp has read it. `cargv` above
    // was already rooted this way; `cenv` was the one that was not.
    auto cenvArray = cfg.env is null ? null : cstrings(cfg.env);
    auto cenv = cfg.env is null ? environ : cenvArray.ptr;

    int pid;
    const rc = posix_spawnp(&pid, cargv[0], &actions, &attr, cargv.ptr, cenv);

    // Parent keeps only its own ends; the child-side ends close now.
    closeIf(cfg.stdinSpec, inPipe[0]);
    closeIf(cfg.stdoutSpec, outPipe[1]);
    closeIf(cfg.stderrSpec, errPipe[1]);
    if (rc != 0)
    {
        closeIf(cfg.stdinSpec, inPipe[1]);
        closeIf(cfg.stdoutSpec, outPipe[0]);
        closeIf(cfg.stderrSpec, errPipe[0]);
        return ioErr!ChildProcess(rc, OpKind.none, IoErrorStage.submit,
            "posix_spawnp failed");
    }

    ChildProcess child;
    child.pid = pid;
    child.stdinW = FileHandle(inPipe[1]);
    child.stdoutR = FileHandle(outPipe[0]);
    child.stderrR = FileHandle(errPipe[0]);
    return ioOk(child);
}

static if (canSubmitOp!(DefaultBackend, OpWaitid))
{
    /**
    Parks until the process `pid` exits (in-ring `WAITID` over a raw pid,
    SPEC §13.2); decodes exited-vs-signaled.

    The raw-pid form exists for a child spawned by other means — `forkpty`,
    a wrapping library — where no `ChildProcess` handle exists to `wait` on
    (`sparkles:terminal-view`'s in-ring reap, TVW8). The caller still owns
    the usual reaping contract: one reap per child, no concurrent `waitpid`
    on the same pid elsewhere.
    */
    /**
    The child's exit code out of a `waitid`-filled `siginfo_t`.

    Portable because the struct is not: Linux buries `si_status` in the
    `_sifields._sigchld` union arm, while the BSDs and macOS expose it as a
    plain field. Reading the Linux spelling unconditionally is what stopped
    this module compiling the moment kqueue grew a `WAITID` lowering.
    */
    private int childStatusOf(Info)(ref const Info info) @trusted nothrow @nogc
    {
        version (linux)
            return info._sifields._sigchld.si_status;
        else
            return info.si_status;
    }

    IoResult!ExitStatus waitPid(ref Sched s, int pid) @trusted
    {
        import core.sys.posix.signal : siginfo_t;
        import core.sys.posix.sys.wait : WEXITED, idtype_t;

        if (pid <= 0)
            return ioErr!ExitStatus(10 /* ECHILD */, OpKind.waitid,
                IoErrorStage.submit, "no child to reap");

        // The siginfo out-buffer lives on this parked frame (SPEC §6.5).
        siginfo_t info;
        auto o = s.await(OpWaitid(cast(int) idtype_t.P_PID,
            cast(uint) pid, cast(void*) &info, WEXITED));
        if (o.res < 0)
            return ioErr!ExitStatus(-o.res, OpKind.waitid);

        enum CLD_EXITED = 1; // si_code: normal exit vs killed/dumped
        const code = childStatusOf(info);
        return ioOk(info.si_code == CLD_EXITED
            ? ExitStatus(false, code)
            : ExitStatus(true, code));
    }

    /// ditto — on the current fiber's scheduler, the tier-B convention
    /// `read`/`write` follow: a daemon fiber spawned through a host errand
    /// was handed no `Sched`, and this is the reap it makes.
    IoResult!ExitStatus waitPid(int pid) @trusted
    {
        auto t = Sched.tryCurrent();
        assert(t !is null, "waitPid must run on a scheduler fiber");
        return waitPid(*t.owner, pid);
    }

    /// Parks until the child exits (in-ring `WAITID`, SPEC §13.2); decodes
    /// exited-vs-signaled. Sets `pid = -1` on success.
    IoResult!ExitStatus wait(ref Sched s, ref ChildProcess child) @trusted
    {
        auto r = waitPid(s, child.pid);
        if (!r.hasError)
            child.pid = -1;
        return r;
    }
}

/**
Spawns `argv` as a session leader on a fresh PTY (SPEC §13.3): the child
acquires the slave as its controlling terminal by opening it inside the
child, after the `setsid` attribute — the reason this is
`posix_spawn`-expressible at all. The stdio specs of `cfg` are ignored:
all three streams point at the slave. The master rides `ptyMaster`.
*/
IoResult!ChildProcess spawnPty(scope const(char[])[] argv,
    ushort cols, ushort rows, in ProcessConfig cfg = ProcessConfig()) @trusted
{
    import core.stdc.errno : errno;
    import core.sys.posix.fcntl : O_NOCTTY, O_RDWR, open;
    import core.sys.posix.spawn : posix_spawn_file_actions_adddup2,
        posix_spawn_file_actions_addopen, posix_spawn_file_actions_destroy,
        posix_spawn_file_actions_init, posix_spawn_file_actions_t,
        posix_spawnattr_destroy, posix_spawnattr_init,
        posix_spawnattr_setflags, posix_spawnattr_t, posix_spawnp;
    import core.sys.posix.stdlib : grantpt, posix_openpt, ptsname, unlockpt;
    import core.sys.posix.unistd : close;

    if (argv.length == 0)
        return ioErr!ChildProcess(22 /* EINVAL */, OpKind.none,
            IoErrorStage.submit, "empty argv");

    const master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0 || grantpt(master) != 0 || unlockpt(master) != 0)
    {
        if (master >= 0)
            close(master);
        return ioErr!ChildProcess(errno ? errno : 5, OpKind.none,
            IoErrorStage.setup, "pty allocation failed");
    }
    scope (failure) close(master);

    const slavePath = ptsname(master);
    if (slavePath is null)
        return ioErr!ChildProcess(5 /* EIO */, OpKind.none,
            IoErrorStage.setup, "ptsname failed");

    // Hold the slave open across the spawn, then preset the window size.
    //
    // The order is load-bearing on macOS, which does not instantiate the tty
    // until the slave is first opened: `TIOCSWINSZ` on a master with no slave
    // yet fails with `ENOTTY`, and because the result was discarded it failed
    // silently — every child came up 0x0 instead of the requested size. Linux
    // is happy either way, so the fix costs it nothing.
    //
    // `O_NOCTTY` keeps this from becoming *our* controlling terminal; the
    // child's own open (as a fresh session leader, without O_NOCTTY) is still
    // what acquires it.
    const slaveFd = open(slavePath, O_RDWR | O_NOCTTY);
    if (slaveFd < 0)
        return ioErr!ChildProcess(errno ? errno : 5, OpKind.none,
            IoErrorStage.setup, "pty slave open failed");
    // Closed only after `posix_spawnp` has run the file actions, so the tty
    // never has zero opens between the preset and the child's own open.
    scope (exit) close(slaveFd);

    winsize ws = {ws_row: rows, ws_col: cols};
    cast(void) ioctl(master, TIOCSWINSZ, &ws);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    scope (exit) posix_spawnattr_destroy(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    scope (exit) posix_spawn_file_actions_destroy(&actions);
    // Attributes (setsid) apply before file actions, so this open — the
    // session leader's first tty, without O_NOCTTY — acquires the slave as
    // the controlling terminal.
    posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0);
    posix_spawn_file_actions_adddup2(&actions, 0, 1);
    posix_spawn_file_actions_adddup2(&actions, 0, 2);

    auto cargv = cstrings(argv);
    // Bound to a named local rather than used as a bare `.ptr`: the slice is
    // the only thing keeping the inner `char[]`s reachable, and the child's
    // environment must survive until posix_spawnp has read it. `cargv` above
    // was already rooted this way; `cenv` was the one that was not.
    auto cenvArray = cfg.env is null ? null : cstrings(cfg.env);
    auto cenv = cfg.env is null ? environ : cenvArray.ptr;

    int pid;
    const rc = posix_spawnp(&pid, cargv[0], &actions, &attr, cargv.ptr, cenv);
    if (rc != 0)
        return ioErr!ChildProcess(rc, OpKind.none, IoErrorStage.submit,
            "posix_spawnp failed");

    ChildProcess child;
    child.pid = pid;
    child.ptyMaster = FileHandle(master);
    return ioOk(child);
}

/// Propagates a resize to the PTY (SPEC §13.3); the child sees `SIGWINCH`.
IoResult!void resizePty(ref ChildProcess child, ushort cols, ushort rows)
    @trusted nothrow @nogc
{
    import core.stdc.errno : errno;

    if (child.ptyMaster.fd < 0)
        return ioErr!void(9 /* EBADF */, OpKind.none, IoErrorStage.submit,
            "not a PTY child");
    winsize ws = {ws_row: rows, ws_col: cols};
    if (ioctl(child.ptyMaster.fd, TIOCSWINSZ, &ws) != 0)
        return ioErr!void(errno, OpKind.none, IoErrorStage.submit,
            "TIOCSWINSZ failed");
    return ioOk();
}

/// The run-to-completion outcome of `capture` (SPEC §13.2).
struct CapturedOutput
{
    import sparkles.base.smallbuffer : SmallBuffer;

    ExitStatus status;
    SmallBuffer!(ubyte, 256) stdout_; /// empty unless stdoutSpec piped
    SmallBuffer!(ubyte, 256) stderr_; /// empty unless stderrSpec piped
}

static if (canSubmitOp!(DefaultBackend, OpWaitid))
{
    /**
    Runs `argv` to completion (SPEC §13.2): spawn per `cfg`, feed
    `stdinBytes` (a non-null value upgrades a default `inherit` stdin to a
    pipe), drain the piped outputs **concurrently** — parked reads, so a
    chatty child can never deadlock against an undrained pipe (the hazard
    `runCaptured`'s temp files work around) — then reap.

    The scope join is the lifetime argument: the drain fibers borrow this
    frame's locals and are all joined before it returns.
    */
    IoResult!CapturedOutput capture(ref Sched s, scope const(char[])[] argv,
        in ProcessConfig cfg = ProcessConfig(),
        scope const(ubyte)[] stdinBytes = null) @trusted
    {
        import core.lifetime : move;

        import sparkles.base.smallbuffer : SmallBuffer;
        import sparkles.event_horizon.io : read, write;
        import sparkles.event_horizon.scope_ : withScope;

        scope ProcessConfig effective = cfg;
        if (stdinBytes !is null && effective.stdinSpec.mode == StdioMode.inherit)
            effective.stdinSpec = StdioSpec(StdioMode.pipe);

        auto spawned = spawnProcess(argv, effective);
        if (spawned.hasError)
            return ioErr!CapturedOutput(spawned.error);
        auto child = spawned.value;

        // Fibers capture plain locals, never `ref`/`scope` parameters (a
        // captured parameter slot outlives nothing — the tui-loop lesson).
        CapturedOutput out_;
        SmallBuffer!(ubyte, 256) stdinCopy;
        if (stdinBytes !is null)
            stdinCopy ~= stdinBytes;
        auto childP = &child;
        auto outP = &out_;
        auto stdinP = &stdinCopy;
        const feedStdin = stdinBytes !is null && child.stdinW.fd >= 0;

        static void drain(FileHandle from, SmallBuffer!(ubyte, 256)* into)
        {
            for (;;)
            {
                SmallBuffer!(ubyte, 512) chunk;
                chunk.length = 512;
                auto got = read(from, move(chunk));
                chunk = move(got.buf);
                if (got.res.hasError || got.res.value == 0)
                    return; // EOF or error: the stream is done
                *into ~= chunk[][0 .. got.res.value];
            }
        }

        auto joined = withScope!((ref sc) {
            if (childP.stdoutR.fd >= 0)
                sc.spawn(() { drain(childP.stdoutR, &outP.stdout_); });
            if (childP.stderrR.fd >= 0)
                sc.spawn(() { drain(childP.stderrR, &outP.stderr_); });
            // The body is a member fiber: feed stdin concurrently with the
            // drains, then signal EOF.
            if (feedStdin)
                cast(void) write(childP.stdinW, move(*stdinP));
            if (childP.stdinW.fd >= 0)
                childP.stdinW.close();
        })(s);

        child.stdoutR.close();
        child.stderrR.close();
        if (joined.hasError)
            return ioErr!CapturedOutput(125 /* ECANCELED */, OpKind.none,
                IoErrorStage.completion, "capture scope interrupted");

        auto st = wait(s, child);
        if (st.hasError)
            return ioErr!CapturedOutput(st.error);
        out_.status = st.value;
        return ioOk(move(out_));
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

        /// Parks until the child exits (in-ring `WAITID`).
        IoResult!ExitStatus wait(ref ChildProcess child)
            => .wait(*_sched, child);
    }

    /// The default live capability row handed to the root fiber (SPEC §11).
    alias Env = CtxOf!(RingClock, RingNet, RingProc);
}
else
{
    /// On a backend without a `WAITID` lowering (kqueue/IOCP until their
    /// O26 reap refinements land) the row carries no proc capability.
    alias Env = CtxOf!(RingClock, RingNet);
}

/// Builds the live capability row for a scheduler — the one place that
/// knows which capabilities this backend can actually field (`LoopGroup`
/// calls this; SPEC §11).
Env liveEnv(Sched* sched) @safe pure nothrow @nogc
{
    static if (canSubmitOp!(DefaultBackend, OpWaitid))
        return Env(RingClock(sched), RingNet(sched), RingProc(sched));
    else
        return Env(RingClock(sched), RingNet(sched));
}

// ── spawn plumbing ──────────────────────────────────────────────────────────

private:

extern (C) extern __gshared char** environ;

// glibc ≥ 2.29 / musl ≥ 1.1.24; absent from druntime's posix.spawn.
extern (C) int posix_spawn_file_actions_addchdir_np(
    void* actions, const(char)* path) nothrow @nogc;

version (linux)
    enum ulong TIOCSWINSZ = 0x5414;
else version (OSX)
    enum ulong TIOCSWINSZ = 0x8008_7467;

/**
`POSIX_SPAWN_SETSID` — a $(B per-platform) value, despite how universal the
name looks.

glibc and musl agree on `0x80`, which is why that was hardcoded. Darwin does
not: there `0x80` is `POSIX_SPAWN_START_SUSPENDED`, and `SETSID` is `0x400`
(xnu `bsd/sys/spawn.h`; the flag arrived in 10.15). So the shared constant did
not merely fail to create a session on macOS — it spawned every `spawnPty`
child $(B stopped), which is a hang rather than a wrong session: the child
never execs, the master never becomes readable, and a `wait` on it blocks
forever.

Diagnosed by resuming one: a child spawned this way reports wait status
`0x7f` (`_WSTOPPED`) and, after a `SIGCONT`, runs to completion with the exit
status its script asked for.
*/
version (OSX)
    enum POSIX_SPAWN_SETSID = 0x0400;
else
    enum POSIX_SPAWN_SETSID = 0x80; // glibc and musl agree

struct winsize
{
    ushort ws_row, ws_col, ws_xpixel, ws_ypixel;
}

extern (C) int ioctl(int fd, ulong request, ...) nothrow @nogc;

/// NUL-terminated C-string array on the GC heap (spawn may allocate).
char*[] cstrings(scope const(char[])[] items) @trusted
{
    auto ptrs = new char*[](items.length + 1);
    foreach (i, item; items)
    {
        auto z = new char[](item.length + 1);
        z[0 .. item.length] = item[];
        z[item.length] = '\0';
        ptrs[i] = z.ptr;
    }
    ptrs[items.length] = null;
    return ptrs;
}

/// One NUL-terminated C string on the GC heap.
const(char)* zstring(scope const(char)[] s) @trusted
{
    auto z = new char[](s.length + 1);
    z[0 .. s.length] = s[];
    z[s.length] = '\0';
    return z.ptr;
}

bool openPipe(ref int[2] fds) @trusted nothrow @nogc
{
    import core.sys.posix.fcntl : F_SETFD, FD_CLOEXEC, fcntl;
    import core.sys.posix.unistd : pipe;

    if (pipe(fds) != 0)
        return false;
    // Parent-held ends must not leak into OTHER spawned children; the
    // intended child's copies come from the dup2 file actions.
    cast(void) fcntl(fds[0], F_SETFD, FD_CLOEXEC);
    cast(void) fcntl(fds[1], F_SETFD, FD_CLOEXEC);
    return true;
}

void closeIf(in StdioSpec spec, int fd) @trusted nothrow @nogc
{
    import core.sys.posix.unistd : close;

    if (spec.mode == StdioMode.pipe && fd >= 0)
        close(fd);
}

void closePipes(ref int[2] a, ref int[2] b, ref int[2] c) @trusted nothrow @nogc
{
    import core.sys.posix.unistd : close;

    static void closePair(ref int[2] p) nothrow @nogc
    {
        foreach (fd; p[])
            if (fd >= 0)
                close(fd);
    }

    closePair(a);
    closePair(b);
    closePair(c);
}

version (unittest)
{
    import sparkles.event_horizon.capability : hasCaps;
    import sparkles.event_horizon.clock : isClock;
    import sparkles.event_horizon.net : isNet;
    import sparkles.event_horizon.proc : isProc;

    static assert(isClock!RingClock);
    static assert(isNet!RingNet);
    static assert(hasCaps!(Env, "clock", "net"));
    static if (canSubmitOp!(DefaultBackend, OpWaitid))
    {
        static assert(isProc!RingProc);
        static assert(hasCaps!(Env, "clock", "net", "proc"));
    }
}

// ── live subprocess tests ───────────────────────────────────────────────────

version (unittest)
{
    import core.lifetime : move;

    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.event_horizon.io : read, write;
    import sparkles.event_horizon.sched : schedOrSkip;

    /// Ring-reads `f` to EOF (or EIO — a drained PTY master) into `into`.
    private void drainInto(ref Sched s, FileHandle f,
        ref SmallBuffer!(ubyte, 512) into) @safe
    {
        SmallBuffer!(ubyte, 128) buf;
        for (;;)
        {
            buf.length = 128;
            auto got = read(f, move(buf));
            buf = move(got.buf);
            if (got.res.hasError)
            {
                assert(got.res.error.errnoValue == 5 /* EIO: pty master EOF */,
                    "unexpected read error");
                break;
            }
            if (got.res.value == 0)
                break;
            into ~= buf[][0 .. got.res.value];
        }
    }
}

static if (canSubmitOp!(DefaultBackend, OpWaitid)):

@("live.spawn.streamStdoutAndReap")
@safe
unittest
{
    Sched s;
    schedOrSkip(s);

    auto r = s.run(() {
        auto spawned = spawnProcess(["echo", "event", "horizon"]);
        assert(spawned.hasValue);
        auto child = spawned.value;
        assert(child.stdinW.fd < 0 && child.stderrR.fd < 0,
            "only stdout is piped by default");

        SmallBuffer!(ubyte, 512) collected;
        drainInto(s, child.stdoutR, collected);
        assert(collected[] == cast(const(ubyte)[]) "event horizon\n");

        auto st = wait(s, child);
        assert(st.hasValue && st.value.ok);
        assert(!child, "reaped");
        child.stdoutR.close();
    });
    assert(!r.hasError);
}

@("live.waitPid.reapsAForeignSpawn")
@safe
unittest
{
    // The raw-pid reap (TVW8's need): a child whose handle came from
    // elsewhere — here the pid is simply detached from its ChildProcess —
    // is reaped in-ring by pid alone, with the same exit decode.
    Sched s;
    schedOrSkip(s);

    auto r = s.run(() {
        auto spawned = spawnProcess(["sh", "-c", "exit 7"]);
        assert(spawned.hasValue);
        auto child = spawned.value;
        const pid = child.pid;
        child.pid = -1; // the handle forgets it; only the raw pid remains
        child.stdoutR.close();

        auto st = waitPid(s, pid);
        assert(st.hasValue && !st.value.signaled && st.value.code == 7);

        auto again = waitPid(s, -1);
        assert(again.hasError, "no pid is an error, not a hang");
    });
    assert(!r.hasError);
}

@("live.spawn.stdinRoundTripThroughCat")
@safe
unittest
{
    Sched s;
    schedOrSkip(s);

    auto r = s.run(() {
        ProcessConfig cfg;
        cfg.stdinSpec = StdioSpec(StdioMode.pipe);
        auto spawned = spawnProcess(["cat"], cfg);
        assert(spawned.hasValue);
        auto child = spawned.value;
        assert(child.stdinW.fd >= 0, "stdin piped on request");

        SmallBuffer!(ubyte, 64) ping;
        ping ~= cast(const(ubyte)[]) "ping through the ring";
        auto sent = write(child.stdinW, move(ping));
        assert(!sent.res.hasError);
        child.stdinW.close(); // EOF: cat exits after echoing

        SmallBuffer!(ubyte, 512) back;
        drainInto(s, child.stdoutR, back);
        assert(back[] == cast(const(ubyte)[]) "ping through the ring");

        auto st = wait(s, child);
        assert(st.hasValue && st.value.ok);
        child.stdoutR.close();
    });
    assert(!r.hasError);
}

/// `path` with every symlink resolved, or `path` itself when it cannot be —
/// the form `pwd` reports for a directory reached through a symlink.
version (unittest)
private string realPathOf(string path) @trusted
{
    import core.stdc.string : strlen;
    import core.sys.posix.stdlib : realpath;
    import std.string : toStringz;

    char[1024] buf;
    auto p = realpath(path.toStringz, buf.ptr);
    return p is null ? path : buf[0 .. strlen(p)].idup;
}

@("live.spawn.stderrCaptureAndCwd")
@safe
unittest
{
    Sched s;
    schedOrSkip(s);

    auto r = s.run(() {
        // stderr piped, stdout to /dev/null, cwd redirected: one child
        // exercises three ProcessConfig axes at once.
        ProcessConfig cfg;
        cfg.stdoutSpec = StdioSpec(StdioMode.nullDev);
        cfg.stderrSpec = StdioSpec(StdioMode.pipe);
        cfg.cwd = "/tmp";
        auto spawned = spawnProcess(["sh", "-c", "pwd; pwd >&2"], cfg);
        assert(spawned.hasValue);
        auto child = spawned.value;
        assert(child.stdoutR.fd < 0 && child.stderrR.fd >= 0);

        SmallBuffer!(ubyte, 512) err;
        drainInto(s, child.stderrR, err);
        // `pwd` reports the PHYSICAL directory, and the requested cwd need not
        // be one: /tmp is a symlink to /private/tmp on macOS. Resolving the
        // request is what makes this an assertion about `cfg.cwd` rather than
        // about the host's filesystem layout.
        const expected = realPathOf("/tmp") ~ "\n";
        assert(err[] == cast(const(ubyte)[]) expected,
            "stderr captured; stdout discarded; cwd applied");

        auto st = wait(s, child);
        assert(st.hasValue && st.value.ok);
        child.stderrR.close();
    });
    assert(!r.hasError);
}

@("live.spawn.envReplacement")
@safe
unittest
{
    Sched s;
    schedOrSkip(s);

    auto r = s.run(() {
        ProcessConfig cfg;
        static immutable const(char[])[] env =
            ["SPARKLES_PROBE=42", "PATH=/usr/bin:/bin"];
        cfg.env = env;
        auto spawned = spawnProcess(["sh", "-c", "echo $SPARKLES_PROBE"], cfg);
        assert(spawned.hasValue);
        auto child = spawned.value;

        SmallBuffer!(ubyte, 512) out_;
        drainInto(s, child.stdoutR, out_);
        assert(out_[] == cast(const(ubyte)[]) "42\n");

        auto st = wait(s, child);
        assert(st.hasValue && st.value.ok);
        child.stdoutR.close();
    });
    assert(!r.hasError);
}

@("live.capture.stdinBothStreamsAndStatus")
@safe
unittest
{
    Sched s;
    schedOrSkip(s);

    auto r = s.run(() {
        // Separate streams + stdin feed + non-zero exit, in one run: the
        // runCaptured replacement shape (SPEC §13.2).
        ProcessConfig cfg;
        cfg.stderrSpec = StdioSpec(StdioMode.pipe);
        auto got = capture(s, ["sh", "-c", "cat; printf err 1>&2; exit 3"],
            cfg, cast(const(ubyte)[]) "fed via stdin");
        assert(got.hasValue);
        assert(got.value.stdout_[] == cast(const(ubyte)[]) "fed via stdin");
        assert(got.value.stderr_[] == cast(const(ubyte)[]) "err");
        assert(!got.value.status.signaled && got.value.status.code == 3);
    });
    assert(!r.hasError);
}

@("live.capture.mergeStdoutInterleavesInOrder")
@safe
unittest
{
    Sched s;
    schedOrSkip(s);

    auto r = s.run(() {
        // One pipe carries both streams in output order — the
        // executeMonitored / runStreaming shape.
        ProcessConfig cfg;
        cfg.stderrSpec = StdioSpec(StdioMode.mergeStdout);
        auto got = capture(s,
            ["sh", "-c", "echo one; echo two 1>&2; echo three"], cfg);
        assert(got.hasValue);
        assert(got.value.status.ok);
        assert(got.value.stdout_[] == cast(const(ubyte)[]) "one\ntwo\nthree\n",
            "stderr rides the stdout pipe, in output order");
        assert(got.value.stderr_.length == 0);
    });
    assert(!r.hasError);
}

@("live.spawn.mergeStdoutIsStderrOnly")
@safe
unittest
{
    Sched s;
    schedOrSkip(s);

    auto r = s.run(() {
        ProcessConfig cfg;
        cfg.stdoutSpec = StdioSpec(StdioMode.mergeStdout);
        auto spawned = spawnProcess(["true"], cfg);
        assert(spawned.hasError, "mergeStdout on stdout must be rejected");
        assert(spawned.error.errnoValue == 22 /* EINVAL */);
    });
    assert(!r.hasError);
}

@("live.kill.waitReportsSignaled")
@safe
unittest
{
    Sched s;
    schedOrSkip(s);

    auto r = s.run(() {
        ProcessConfig cfg;
        cfg.stdoutSpec = StdioSpec(StdioMode.inherit);
        auto spawned = spawnProcess(["sleep", "30"], cfg);
        assert(spawned.hasValue);
        auto child = spawned.value;

        assert(!child.kill().hasError);
        auto st = wait(s, child);
        assert(st.hasValue);
        assert(st.value.signaled && st.value.code == 15,
            "SIGTERM death decodes as signaled, not exit code");
        assert(!st.value.ok);

        auto again = child.kill();
        assert(again.hasError && again.error.errnoValue == 3 /* ESRCH */,
            "kill after reap is refused by the handle");
    });
    assert(!r.hasError);
}

@("live.spawnPty.sessionLeaderOnTheMaster")
@safe
unittest
{
    Sched s;
    schedOrSkip(s);

    auto r = s.run(() {
        // The child sees a real controlling terminal: `tty -s` succeeds
        // only when stdin is a tty, and the winsize preset is observable.
        auto spawned = spawnPty(["sh", "-c", "stty size"], 80, 24);
        assert(spawned.hasValue);
        auto child = spawned.value;
        assert(child.ptyMaster.fd >= 0);

        SmallBuffer!(ubyte, 512) out_;
        drainInto(s, child.ptyMaster, out_);
        assert(out_[] == cast(const(ubyte)[]) "24 80\r\n",
            "the child ran on the slave with the preset winsize");

        auto st = wait(s, child);
        assert(st.hasValue && st.value.ok);
        child.ptyMaster.close();
    });
    assert(!r.hasError);
}
