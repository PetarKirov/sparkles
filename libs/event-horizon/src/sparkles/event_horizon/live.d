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
import sparkles.event_horizon.cause : Cause;
import sparkles.event_horizon.errors : IoErrorStage, IoResult, OpKind, ioErr, ioOk;
import sparkles.event_horizon.io : FileHandle, Listener, Stream, accept, connect;
import sparkles.event_horizon.net : SockAddr;
import sparkles.event_horizon.op : OpWaitid;
import sparkles.event_horizon.errors : IoError;
import sparkles.event_horizon.proc : EnvironmentChange, ExitStatus, LineEmit,
    LineFramer, ProcessConfig, ProcessEnd, ProcessEvent, ProcessEventKind,
    ProcessEventSink, ProcessLine, ProcessResourceUsage, ProcessStream,
    StdioMode, StdioSpec, SupervisedProcessConfig, SupervisedProcessResult;
import sparkles.event_horizon.sched : Sched;

private:

extern (C) extern __gshared char** environ;

/// The inherited environment as borrowed slices (`environ` itself, never
/// mutated — overlays copy before editing, SPEC §13.1).
package const(char)[][] inheritedEnvironment() @trusted nothrow
{
    import core.stdc.string : strlen;

    size_t n;
    while (environ[n] !is null)
        ++n;
    auto out_ = new const(char)[][](n);
    foreach (i; 0 .. n)
        out_[i] = environ[i][0 .. strlen(environ[i])];
    return out_;
}

/// A "KEY=value" entry's name (everything before the first '=', or the whole
/// entry — an entry without '=' is inherited-name-only by convention).
package const(char)[] envNameOf(const(char)[] entry) @safe pure nothrow @nogc
{
    foreach (i, c; entry)
        if (c == '=')
            return entry[0 .. i];
    return entry;
}

/**
Validates and computes the child environment per SPEC §13.1: the base is
$(LREF ProcessConfig.env) when non-null, else the inherited environment;
`envOverlay` changes then apply in order — last change for a name wins,
`unset` removes. Name matching is byte-exact on POSIX.

An invalid edit (empty name, '=' or NUL anywhere in a name, NUL in a value)
fails with `EINVAL` $(B before any child exists). The result is null exactly
when the child should inherit unmodified (no custom base and no overlay);
otherwise it is the full replacement block handed to `posix_spawn`.
*/
package IoResult!(const(char)[][]) effectiveEnvironment(
    in ProcessConfig cfg) @safe
{
    import core.lifetime : move;

    enum EINVAL = 22;
    if (cfg.env !is null)
        foreach (entry; cfg.env)
        {
            size_t equals = size_t.max;
            foreach (i, c; entry)
            {
                if (c == '\0')
                    return ioErr!(const(char)[][])(EINVAL, OpKind.none,
                        IoErrorStage.submit,
                        "environment entry must not contain NUL");
                if (c == '=' && equals == size_t.max)
                    equals = i;
            }
            if (equals == size_t.max || equals == 0)
                return ioErr!(const(char)[][])(EINVAL, OpKind.none,
                    IoErrorStage.submit,
                    "environment entry must be nonempty KEY=value");
        }
    foreach (change; cfg.envOverlay)
    {
        if (change.name.length == 0)
            return ioErr!(const(char)[][])(EINVAL, OpKind.none,
                IoErrorStage.submit, "environment name must not be empty");
        foreach (c; change.name)
            if (c == '=' || c == '\0')
                return ioErr!(const(char)[][])(EINVAL, OpKind.none,
                    IoErrorStage.submit, "environment name must not contain"
                    ~ " '=' or NUL");
        if (!change.unset)
            foreach (c; change.value)
                if (c == '\0')
                    return ioErr!(const(char)[][])(EINVAL, OpKind.none,
                        IoErrorStage.submit,
                        "environment value must not contain NUL");
    }

    alias EnvBlock = const(char)[][];
    if (cfg.env is null && cfg.envOverlay.length == 0)
        return ioOk(EnvBlock.init);

    const(char)[][] entries;
    if (cfg.env !is null)
    {
        entries.length = cfg.env.length;
        foreach (i, e; cfg.env)
            entries[i] = e.dup;
    }
    else
        entries = inheritedEnvironment();

    foreach (change; cfg.envOverlay)
    {
        // Remove every prior spelling, including duplicates inherited from a
        // caller-supplied replacement block. A set then appends exactly one.
        size_t writeAt;
        foreach (entry; entries)
            if (envNameOf(entry) != change.name)
                entries[writeAt++] = entry;
        entries.length = writeAt;
        if (!change.unset)
        {
            entries ~= change.name ~ "=" ~ change.value;
        }
    }
    return ioOk(move(entries));
}

/// The fallback search path for a child whose environment carries no PATH:
/// what `execvp`-family implementations use (the `_CS_PATH` confstr, which
/// is `/bin:/usr/bin` wherever that confstr is unavailable to us).
private string defaultPath() @trusted nothrow
{
    import core.sys.posix.unistd : _CS_PATH, confstr;

    char[1024] buf;
    const n = confstr(_CS_PATH, buf.ptr, buf.length);
    if (n == 0 || n > buf.length)
        return "/bin:/usr/bin";
    // confstr includes the terminating NUL in its count.
    return buf[0 .. n - 1].idup;
}

/// The PATH the child will see (SPEC §13.1: "PATH lookup uses the resulting
/// environment"): the built entries when a custom environment was made,
/// the parent's otherwise; unset ⇒ `_CS_PATH`.
private string childSearchPath(scope const(char)[][] envEntries,
    bool customEnv) @trusted
{
    import core.stdc.stdlib : getenv;
    import core.stdc.string : strlen;

    if (customEnv)
    {
        foreach (entry; envEntries)
            if (entry.length >= 5 && entry[0 .. 5] == "PATH=")
                return entry[5 .. $].idup;
        return defaultPath();
    }
    auto inherited = getenv("PATH");
    return inherited is null ? defaultPath() : inherited[0 .. strlen(inherited)].idup;
}

/// Whether a candidate might exec: anything but a definite "no such file"
/// from `stat` is left for the spawn to decide, so this can only skip work,
/// never change an outcome.
private bool mightExec(scope const(char)[] probe) @trusted nothrow
{
    import core.stdc.errno : ENOENT, ENOTDIR, errno;
    import core.sys.posix.sys.stat : stat, stat_t;
    import std.string : toStringz;

    stat_t status;
    if (stat(probe.toStringz, &status) == 0)
        return true;
    return errno != ENOENT && errno != ENOTDIR;
}

/**
The child's PATH search (SPEC §13.1), driven by the spawn itself rather than
by an `access(2)` pre-check: `access` answers for the real uid while exec
answers for the effective one, and a fabricated `ENOENT` hid every other
failure. Each candidate is handed to `attempt` — a `posix_spawn` whose exec
runs in the child's cwd with the child's credentials — under execvp's rules:
`ENOENT`/`ENOTDIR` move on, `EACCES` is remembered and reported when nothing
later succeeds, and any other error ends the search. Unlike `posix_spawnp`
there is no `/bin/sh` retry on `ENOEXEC`. A name containing '/' is spawned as
spelled; an empty PATH component is the child cwd; a candidate that
definitely does not exist (in the parent's view of the child cwd) is skipped
without a spawn — a `stat` is far cheaper than a clone.

Returns the spawn's errno, 0 on success.
*/
private int spawnSearchingPath(Attempt)(const(char)[] program,
    string searchPath, const(char)[] childCwd, scope Attempt attempt)
{
    import core.stdc.errno : EACCES, ENOENT, ENOTDIR;
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : canFind;
    import std.array : array;
    import std.path : isAbsolute;

    if (program.canFind('/'))
        return attempt(program);

    // `PATH=` is exactly one empty component — `splitter` would yield none.
    auto segments = searchPath.length ? searchPath.splitter(':').array : [""];
    bool sawEacces;
    foreach (segment; segments)
    {
        // Spelled relative to the child's cwd (the exec runs after the
        // chdir file action); probed relative to the parent's.
        const childDir = segment.length ? segment : ".";
        const candidate = childDir.idup ~ "/" ~ program;
        const probe = childCwd !is null && !childDir.isAbsolute
            ? childCwd.idup ~ "/" ~ candidate
            : candidate;
        if (!mightExec(probe))
            continue;
        const rc = attempt(candidate);
        if (rc == 0)
            return 0;
        if (rc == EACCES)
        {
            sawEacces = true;
            continue;
        }
        if (rc != ENOENT && rc != ENOTDIR)
            return rc;
    }
    return sawEacces ? EACCES : ENOENT;
}

/// Names a failed spawn's cause for the error's context.
private string spawnFailureContext(int rc) @safe pure nothrow @nogc
{
    import core.stdc.errno : EACCES, ENOENT, ENOEXEC;

    switch (rc)
    {
    case ENOENT:
        return "program not found in child PATH";
    case EACCES:
        return "program found in child PATH but not executable";
    case ENOEXEC:
        return "program is not a recognised executable (no shell fallback)";
    default:
        return "posix_spawn failed";
    }
}

private IoResult!void validateSpawnStrings(scope const(char[])[] argv,
    const(char)[] cwd) @safe pure nothrow @nogc
{
    enum EINVAL = 22;
    foreach (arg; argv)
        foreach (c; arg)
            if (c == '\0')
                return ioErr!void(EINVAL, OpKind.none, IoErrorStage.submit,
                    "argv entries must not contain NUL");
    if (cwd !is null)
        foreach (c; cwd)
            if (c == '\0')
                return ioErr!void(EINVAL, OpKind.none, IoErrorStage.submit,
                    "cwd must not contain NUL");
    return ioOk();
}

public:

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
directory, and an optional fresh process group. `posix_spawn`, never
`fork` — a fiber stack is the worst possible place for a fork. Spawning is
a setup-phase operation and may allocate (argv/env staging is heap-built;
the M7 4 KiB budget and its `E2BIG` are gone).
*/
IoResult!ChildProcess spawnProcess(scope const(char[])[] argv,
    in ProcessConfig cfg = ProcessConfig()) @trusted
{
    import core.stdc.errno : errno;
    import core.sys.posix.fcntl : F_GETFD, F_SETFD, FD_CLOEXEC, O_RDONLY,
        O_WRONLY, fcntl;
    import core.sys.posix.spawn : posix_spawn, posix_spawn_file_actions_adddup2,
        posix_spawn_file_actions_addclose, posix_spawn_file_actions_addopen,
        posix_spawn_file_actions_destroy, posix_spawn_file_actions_init,
        posix_spawn_file_actions_t, posix_spawnattr_destroy,
        posix_spawnattr_init, posix_spawnattr_setflags,
        posix_spawnattr_setpgroup, posix_spawnattr_t,
        POSIX_SPAWN_SETPGROUP;
    import core.sys.posix.unistd : close;

    if (argv.length == 0)
        return ioErr!ChildProcess(22 /* EINVAL */, OpKind.none,
            IoErrorStage.submit, "empty argv");
    auto stringsValid = validateSpawnStrings(argv, cfg.cwd);
    if (stringsValid.hasError)
        return ioErr!ChildProcess(stringsValid.error);

    // Environment overlay (SPEC §13.1): validated before pipes or file
    // actions exist, so an invalid edit fails with no child.
    auto envBuilt = effectiveEnvironment(cfg);
    if (envBuilt.hasError)
        return ioErr!ChildProcess(envBuilt.error);
    const customEnv = cfg.env !is null || cfg.envOverlay.length > 0;
    const searchPath = childSearchPath(envBuilt.value, customEnv);

    // Parent/child pipe ends per stream; -1 = not piped.
    int[2] inPipe = -1, outPipe = -1, errPipe = -1;
    int[3] restoreFlags = [-1, -1, -1];
    scope (exit) closePipes(inPipe, outPipe, errPipe);
    scope (exit)
        foreach (fd, flags; restoreFlags)
            if (flags >= 0)
                cast(void) fcntl(cast(int) fd, F_SETFD, flags);

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
                if (childEnd != childFd)
                    posix_spawn_file_actions_adddup2(
                        &actions, childEnd, childFd);
                else
                {
                    const flags = fcntl(childEnd, F_GETFD);
                    if (flags < 0
                        || fcntl(childEnd, F_SETFD, flags & ~FD_CLOEXEC) != 0)
                        return false;
                }
                // A pipe endpoint may itself be fd 0/1/2 when the parent had
                // that descriptor closed. Never close the child target after
                // installing (or retaining) it.
                if (pipeFds[0] != childFd)
                    posix_spawn_file_actions_addclose(&actions, pipeFds[0]);
                if (pipeFds[1] != childFd)
                    posix_spawn_file_actions_addclose(&actions, pipeFds[1]);
                return true;
            case StdioMode.nullDev:
                posix_spawn_file_actions_addopen(&actions, childFd,
                    "/dev/null", childReads ? O_RDONLY : O_WRONLY, 0);
                return true;
            case StdioMode.fd:
                if (spec.fd != childFd)
                    posix_spawn_file_actions_adddup2(&actions, spec.fd, childFd);
                else
                {
                    const flags = fcntl(spec.fd, F_GETFD);
                    if (flags < 0
                        || fcntl(spec.fd, F_SETFD, flags & ~FD_CLOEXEC) != 0)
                        return false;
                    restoreFlags[childFd] = flags;
                }
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
    // environment must survive until posix_spawn has read it. `cargv` above
    // was already rooted this way; `cenv` was the one that was not.
    auto cenvArray = customEnv ? cstrings(envBuilt.value) : null;
    auto cenv = customEnv ? cenvArray.ptr : environ;

    // The child's own PATH search (§13.1): never `posix_spawnp`, whose
    // search consults the parent's PATH and retries scripts via /bin/sh.
    int pid;
    const rc = spawnSearchingPath(argv[0], searchPath, cfg.cwd,
        (const(char)[] candidate) => posix_spawn(&pid, zstring(candidate),
            &actions, &attr, cargv.ptr, cenv));

    // Parent keeps only its own ends; the child-side ends close now.
    closeIf(cfg.stdinSpec, inPipe[0]);
    inPipe[0] = -1;
    closeIf(cfg.stdoutSpec, outPipe[1]);
    outPipe[1] = -1;
    closeIf(cfg.stderrSpec, errPipe[1]);
    errPipe[1] = -1;
    if (rc != 0)
    {
        closeIf(cfg.stdinSpec, inPipe[1]);
        inPipe[1] = -1;
        closeIf(cfg.stdoutSpec, outPipe[0]);
        outPipe[0] = -1;
        closeIf(cfg.stderrSpec, errPipe[0]);
        errPipe[0] = -1;
        return ioErr!ChildProcess(rc, OpKind.none, IoErrorStage.submit,
            spawnFailureContext(rc));
    }

    ChildProcess child;
    child.pid = pid;
    child.stdinW = FileHandle(inPipe[1]);
    child.stdoutR = FileHandle(outPipe[0]);
    child.stderrR = FileHandle(errPipe[0]);
    inPipe[1] = outPipe[0] = errPipe[0] = -1;
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
    version (OSX)
    {
        // Druntime's core.sys.posix.signal.siginfo_t on Darwin is missing
        // __pad[7], resulting in 72 bytes instead of the 104 bytes Darwin libc's
        // waitid writes. Using a full 104-byte struct prevents stack corruption.
        struct SigInfo
        {
            int si_signo;
            int si_errno;
            int si_code;
            int si_pid;
            uint si_uid;
            int si_status;
            void* si_addr;
            size_t si_value;
            long si_band;
            ulong[7] __pad;
        }
        static assert(SigInfo.sizeof >= 104);
    }
    else
    {
        import core.sys.posix.signal : siginfo_t;
        alias SigInfo = siginfo_t;
    }

    private int childStatusOf(Info)(ref const Info info) @trusted nothrow @nogc
    {
        version (linux)
            return info._sifields._sigchld.si_status;
        else
            return info.si_status;
    }

    private IoResult!ExitStatus waitPidFlags(ref Sched s, int pid,
        int flags) @trusted
    {
        import core.sys.posix.sys.wait : idtype_t;

        if (pid <= 0)
            return ioErr!ExitStatus(10 /* ECHILD */, OpKind.waitid,
                IoErrorStage.submit, "no child to reap");

        // The siginfo out-buffer lives on this parked frame (SPEC §6.5).
        SigInfo info;
        auto o = s.await(OpWaitid(cast(int) idtype_t.P_PID,
            cast(uint) pid, cast(void*) &info, flags));
        if (o.res < 0)
            return ioErr!ExitStatus(-o.res, OpKind.waitid);

        enum CLD_EXITED = 1; // si_code: normal exit vs killed/dumped
        const code = childStatusOf(info);
        return ioOk(info.si_code == CLD_EXITED
            ? ExitStatus(false, code)
            : ExitStatus(true, code));
    }

    IoResult!ExitStatus waitPid(ref Sched s, int pid) @trusted
    {
        import core.sys.posix.sys.wait : WEXITED;

        return waitPidFlags(s, pid, WEXITED);
    }

    /// Waits for exit without consuming the zombie, so final accounting can
    /// inspect `/proc/<pid>` before the one real reap.
    private IoResult!ExitStatus observeExit(ref Sched s, int pid) @trusted
    {
        import core.sys.posix.sys.wait : WEXITED, WNOWAIT;

        return waitPidFlags(s, pid, WEXITED | WNOWAIT);
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
    import core.sys.posix.spawn : posix_spawn, posix_spawn_file_actions_adddup2,
        posix_spawn_file_actions_addopen, posix_spawn_file_actions_destroy,
        posix_spawn_file_actions_init, posix_spawn_file_actions_t,
        posix_spawnattr_destroy, posix_spawnattr_init,
        posix_spawnattr_setflags, posix_spawnattr_t;
    import core.sys.posix.stdlib : grantpt, posix_openpt, ptsname, unlockpt;
    import core.sys.posix.unistd : close;

    if (argv.length == 0)
        return ioErr!ChildProcess(22 /* EINVAL */, OpKind.none,
            IoErrorStage.submit, "empty argv");
    auto stringsValid = validateSpawnStrings(argv, cfg.cwd);
    if (stringsValid.hasError)
        return ioErr!ChildProcess(stringsValid.error);

    auto envBuilt = effectiveEnvironment(cfg);
    if (envBuilt.hasError)
        return ioErr!ChildProcess(envBuilt.error);
    const customEnv = cfg.env !is null || cfg.envOverlay.length > 0;
    const searchPath = childSearchPath(envBuilt.value, customEnv);

    int master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0 || grantpt(master) != 0 || unlockpt(master) != 0)
    {
        if (master >= 0)
            close(master);
        return ioErr!ChildProcess(errno ? errno : 5, OpKind.none,
            IoErrorStage.setup, "pty allocation failed");
    }
    scope (exit)
        if (master >= 0)
            close(master);

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
    // Closed only after `posix_spawn` has run the file actions, so the tty
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
    if (cfg.cwd !is null)
        posix_spawn_file_actions_addchdir_np(&actions, zstring(cfg.cwd));

    auto cargv = cstrings(argv);
    // Bound to a named local rather than used as a bare `.ptr` (see
    // `spawnProcess`); the overlay-computed block replaces it wholesale.
    auto cenvArray = customEnv ? cstrings(envBuilt.value) : null;
    auto cenv = customEnv ? cenvArray.ptr : environ;

    int pid;
    const rc = spawnSearchingPath(argv[0], searchPath, cfg.cwd,
        (const(char)[] candidate) => posix_spawn(&pid, zstring(candidate),
            &actions, &attr, cargv.ptr, cenv));
    if (rc != 0)
        return ioErr!ChildProcess(rc, OpKind.none, IoErrorStage.submit,
            spawnFailureContext(rc));

    ChildProcess child;
    child.pid = pid;
    child.ptyMaster = FileHandle(master);
    master = -1;
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
    import sparkles.base.buffer : SharedBuffer;

    ExitStatus status;
    SharedBuffer!(ubyte, 256) stdout_; /// empty unless stdoutSpec piped
    SharedBuffer!(ubyte, 256) stderr_; /// empty unless stderrSpec piped
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
        import core.sys.posix.signal : SIGKILL;

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
        auto child = spawned.value;
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
        const feedStdin = stdinBytes !is null && child.stdinW.fd >= 0;

        static void drain(CaptureDrainState* st, FileHandle from,
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
                    cast(void) st.child.kill(SIGKILL);
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
            if (childP.stdoutR.fd >= 0
                && !sc.spawn(() { drain(drainP, childP.stdoutR, &outP.stdout_); }))
                return;
            if (childP.stderrR.fd >= 0
                && !sc.spawn(() { drain(drainP, childP.stderrR, &outP.stderr_); }))
                return;
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
            if (st.error.errnoValue != ECHILD)
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
            : IoError(ECANCELED, OpKind.none, IoErrorStage.completion,
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
        import core.sys.posix.signal : SIGKILL;

        import sparkles.event_horizon.scope_ : protect;

        if (child.pid <= 0)
            return;
        auto childP = &child;
        auto sP = &s;
        protect!(() {
            cast(void) childP.kill(SIGKILL);
            auto reaped = waitPidAfterKill(*sP, childP.pid);
            if (!reaped.hasError || reaped.error.errnoValue == ECHILD)
                childP.pid = -1;
            return 0;
        })(s);
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

    // ── supervised runs (SPEC §13.5–§13.8) ─────────────────────────────

    private struct ProcessIdentity
    {
        int pid;
        ulong startTime;
    }

    private struct ProcessCpu
    {
        ulong userTicks;
        ulong systemTicks;
    }

    /** One supervised run's state, mutated only by the supervising fiber. */
    private struct SupervisionState
    {
        import sparkles.base.buffer : SharedBuffer;

        ChildProcess* child;
        int processGroup;
        bool collect;
        size_t collectCap;     /// `maxCapturedBytes`; 0 = unbounded
        bool stdoutTruncated;  /// raw collection stopped at the cap
        bool stderrTruncated;

        // Single-winner end decision (§13.7): the first timeout / cancel
        // trigger names the reported ProcessEnd; later triggers only
        // advance cleanup.
        ProcessEnd end = ProcessEnd.exited;
        bool endDecided;
        bool termSent;
        bool killSent;
        bool reaped;
        ExitStatus status; /// valid only once `reaped`

        // Raw accumulation: exact bytes including original terminators
        // (§13.6). One writer per field at any time.
        SharedBuffer!(ubyte, 256) stdout_;
        SharedBuffer!(ubyte, 256) stderr_;

        ProcessResourceUsage usage;
        MonoTime startedAt;
        ProcessCpu[ProcessIdentity] observedCpu;
        version (unittest)
            int* signalAttempts;
    }

    private enum RelayKind : ubyte
    {
        bytes,
        streamEof,
        readError,
        rootObserved,
        waitError,
        workerDefect,
        timeout,
        sampleDue,
    }

    /// Worker-to-supervisor messages. Workers never invoke application code.
    private struct RelayMessage
    {
        import sparkles.base.buffer : SharedBuffer;

        RelayKind kind;
        ProcessStream stream;
        SharedBuffer!(ubyte, 512) bytes;
        IoError error;
        Throwable defect;
    }

    private bool canPublishExited(in SupervisionState st,
        bool stdoutFinished, bool stderrFinished) @safe pure nothrow @nogc
        => st.reaped && stdoutFinished && stderrFinished;

    private bool waitLostReapRight(in IoError error)
        @safe pure nothrow @nogc
        => error.errnoValue == 10 /* ECHILD */;

    private bool transientProcessError(in IoError error)
        @safe pure nothrow @nogc
    {
        import core.stdc.errno : EAGAIN, EINTR, ENOBUFS;

        return error.errnoValue == EINTR || error.errnoValue == EAGAIN
            || error.errnoValue == ENOBUFS;
    }

    private bool retryProcessError(in IoError error, uint attempts)
        @safe pure nothrow @nogc
        => transientProcessError(error) && attempts < 8;

    /// The blocking `waitpid` fallback's job context and body: runs on the
    /// shared pool's termination-critical lane, never on the loop thread.
    private struct WaitPidJob
    {
        int pid;
        bool ok;
        ExitStatus status;
        int errnoValue;
        string context;
    }

    private void waitPidBlocking(void* p) nothrow
    {
        import core.stdc.errno : EINTR, errno;
        import core.sys.posix.sys.wait : WEXITSTATUS, WIFEXITED, WIFSIGNALED,
            WTERMSIG, waitpid;

        auto job = cast(WaitPidJob*) p;
        int raw;
        int rc;
        do
            rc = waitpid(job.pid, &raw, 0);
        while (rc < 0 && errno == EINTR);
        if (rc < 0)
        {
            job.errnoValue = errno;
            job.context = "waitpid fallback failed";
            return;
        }
        if (WIFEXITED(raw))
        {
            job.ok = true;
            job.status = ExitStatus(false, WEXITSTATUS(raw));
        }
        else if (WIFSIGNALED(raw))
        {
            job.ok = true;
            job.status = ExitStatus(true, WTERMSIG(raw));
        }
        else
        {
            job.errnoValue = 5; // EIO
            job.context = "waitpid returned no terminal status";
        }
    }

    /// The consuming `waitpid` fallback, off the scheduler thread (SPEC
    /// §13.8): a D-state child would otherwise wedge every fiber of this
    /// loop. Runs on the shared pool's termination-critical lane.
    private IoResult!ExitStatus waitPidAfterKill(ref Sched s, int pid) @trusted
    {
        import sparkles.event_horizon.blocking_pool : sharedBlockingPool;

        auto pool = sharedBlockingPool();
        if (pool.hasError)
            return ioErr!ExitStatus(pool.error);
        WaitPidJob job = {pid: pid};
        auto ran = pool.value.runMandatory(s, &waitPidBlocking, &job);
        if (ran.hasError)
            return ioErr!ExitStatus(ran.error);
        if (!job.ok)
            return ioErr!ExitStatus(job.errnoValue, OpKind.waitid,
                IoErrorStage.completion, job.context);
        return ioOk(job.status);
    }

    // The line framer (`LineFramer`/`LineEmit`) is effects-side in `proc` —
    // pure and ring-free, so its edge matrix is unit-tested there.

    /// Advances the single-winner end decision; later triggers are no-ops.
    private void decideEnd(ref SupervisionState st, ProcessEnd which)
        @safe pure nothrow @nogc
    {
        if (!st.endDecided)
        {
            st.endDecided = true;
            st.end = which;
        }
    }

    private void timeoutOccurred(ref SupervisionState st)
        @safe pure nothrow @nogc
    {
        decideEnd(st, ProcessEnd.timedOut);
    }

    private void signalGroup(ref SupervisionState st, int signal,
        ref bool sent) @trusted nothrow
    {
        import core.sys.posix.signal : kill_ = kill;

        if (sent || st.processGroup <= 0)
            return;
        sent = true;
        version (unittest)
            if (st.signalAttempts !is null)
                ++*st.signalAttempts;
        if (kill_(-st.processGroup, signal) != 0 && *st.child)
            cast(void) kill_(st.child.pid, signal);
    }

    private void signalSavedGroup(int processGroup, int signal)
        @trusted nothrow @nogc
    {
        import core.sys.posix.signal : kill_ = kill;

        if (processGroup > 0)
            cast(void) kill_(-processGroup, signal);
    }

    /// Sends the graceful termination request to the privately saved group.
    private void sendTerm(ref SupervisionState st) @trusted nothrow
    {
        import core.sys.posix.signal : SIGTERM;

        signalGroup(st, SIGTERM, st.termSent);
    }

    /// Sends the hard-kill request to the privately saved group once.
    private void sendKill(ref SupervisionState st) @trusted nothrow
    {
        import core.sys.posix.signal : SIGKILL;

        signalGroup(st, SIGKILL, st.killSent);
    }

    private void emergencyTerminateDrainReap(ref Sched s,
        ref ChildProcess child, int processGroup,
        int* signalAttempts = null) @trusted
    {
        import core.lifetime : move;
        import core.sys.posix.signal : SIGKILL;
        import core.time : msecs;

        import sparkles.base.buffer : SharedBuffer;
        import sparkles.event_horizon.io : read, sleep;
        import sparkles.event_horizon.scope_ : protect;

        // Once wait has consumed the root, this low-level pid may be reused;
        // exceptional cleanup has nothing left to signal in that case.
        if (child.pid > 0)
        {
            version (unittest)
                if (signalAttempts !is null)
                    ++*signalAttempts;
            signalSavedGroup(processGroup, SIGKILL);
        }
        child.stdinW.close();
        cast(void) protect!(() {
            void drainAndClose(ref FileHandle handle)
            {
                if (handle.fd >= 0)
                {
                    uint retries;
                    for (;;)
                    {
                        SharedBuffer!(ubyte, 512) chunk;
                        chunk.length = 512;
                        auto got = read(handle, move(chunk));
                        if (got.res.hasValue && got.res.value == 0)
                            break;
                        if (got.res.hasError)
                        {
                            if (!transientProcessError(got.res.error)
                                || retries++ >= 8)
                            {
                                break;
                            }
                            cast(void) sleep(s, 1.msecs);
                        }
                        else
                            retries = 0;
                    }
                }
                handle.close();
            }

            drainAndClose(child.stdoutR);
            drainAndClose(child.stderrR);
            uint waitRetries;
            while (child)
            {
                auto waited = .wait(s, child);
                if (waited.hasValue)
                    break;
                if (waited.error.errnoValue == 10 /* ECHILD */)
                {
                    child.pid = -1;
                    break;
                }
                if (retryProcessError(waited.error, waitRetries++))
                {
                    cast(void) sleep(s, 1.msecs);
                    continue;
                }
                auto fallback = waitPidAfterKill(s, child.pid);
                if (fallback.hasValue || fallback.error.errnoValue == 10)
                    child.pid = -1;
                break;
            }
        })(s);
    }

    version (linux)
    {
        /// Parses `/proc/<pid>/stat`'s ppid, CPU ticks, and resident pages.
        private bool parseProcStat(int pid, out int ppid, out int pgrp,
            out ulong utime, out ulong stime, out ulong startTime,
            out ulong rssPages) @trusted
        {
            import core.stdc.stdio : fclose, fgets, fopen;
            import core.stdc.string : strlen;
            import std.array : split;
            import std.conv : to;
            import std.format : format;
            import std.string : toStringz;

            auto file = fopen(format("/proc/%d/stat", pid).toStringz, "r");
            if (file is null)
                return false;
            scope (exit) fclose(file);

            char[2048] lineBuf;
            if (fgets(lineBuf.ptr, lineBuf.length, file) is null)
                return false;
            const text = lineBuf[0 .. strlen(lineBuf.ptr)];

            // comm may contain spaces and parens: split after its last ')'.
            long close_ = -1;
            foreach (i, c; text)
                if (c == ')')
                    close_ = i;
            if (close_ < 0)
                return false;
            const rest = text[close_ + 1 .. $]; // fields restart at #3

            static long parseField(const(char)[] tok)
            {
                import std.conv : ConvException;

                try
                    return to!long(tok);
                catch (ConvException _)
                    // The kernel spells some -1 fields as their unsigned
                    // wraparound (`18446744073709551615`) — notably on
                    // zombies.
                    return cast(long) to!ulong(tok);
            }

            try
            {
                // Token 0 is the state LETTER ("S"/"R"/…); later fields can
                // be negative (`tpgid = -1` without a controlling tty), so
                // everything parses signed and widens.
                long[22] f = void;
                size_t seen;
                foreach (tok; rest.split(' '))
                {
                    if (tok.length == 0)
                        continue;
                    if (seen == 0)
                    {
                        ++seen;
                        continue;
                    }
                    if (seen < f.length + 1)
                        f[seen - 1] = parseField(tok);
                    ++seen;
                }
                if (seen < 22)
                    return false;
                // With the state letter skipped, f[j] holds field j+4.
                ppid = cast(int) f[0]; // field 4
                pgrp = cast(int) f[1]; // field 5
                utime = cast(ulong) f[10]; // field 14
                stime = cast(ulong) f[11]; // field 15
                startTime = cast(ulong) f[18]; // field 22
                rssPages = cast(ulong) f[20]; // field 24
                return true;
            }
            catch (Exception _)
            {
                return false; // malformed stat line: skip this pid
            }
        }

        private __gshared size_t pageSizeCache;

        private size_t pageSize() @trusted nothrow @nogc
        {
            import core.sys.posix.unistd : _SC_PAGESIZE, sysconf;

            if (pageSizeCache == 0)
                pageSizeCache = cast(size_t) sysconf(_SC_PAGESIZE);
            return pageSizeCache;
        }

        private __gshared long clockTicksCache;

        /// `_SC_CLK_TCK`, queried once: a process-lifetime constant that
        /// every sample used to re-`sysconf`.
        private long clockTicksPerSecond() @trusted nothrow @nogc
        {
            import core.sys.posix.unistd : _SC_CLK_TCK, sysconf;

            if (clockTicksCache == 0)
                clockTicksCache = sysconf(_SC_CLK_TCK);
            return clockTicksCache;
        }

        private Duration ticksToDuration(ulong ticks, long hz)
            @safe pure nothrow @nogc
        {
            import core.time : usecs;

            if (hz <= 0)
                return Duration.zero;
            return usecs(cast(long) ticks * 1_000_000L / hz);
        }

        /**
        Walks `/proc` once and folds the root's whole descendant tree into
        `usage`: peak summed RSS, peak live-process count, cumulative
        user/system CPU over live members (best-effort, SPEC §13.8). A walk
        that cannot see the root leaves the peaks untouched.
        */
        package void sampleTreeLinux(int rootPid,
            ref ProcessResourceUsage usage,
            ref ProcessCpu[ProcessIdentity] observedCpu) @safe
        {
            import core.stdc.string : strlen;
            import core.sys.posix.dirent : closedir, dirent, opendir,
                readdir;
            import std.conv : to;

            // Raw readdir, not std.file.dirEntries: the latter stats every
            // entry and THROWS when a short-lived process vanishes between
            // getdents and stat, aborting the walk mid-stream. A vanished
            // pid here skips one tree member instead.
            auto procDir = (() @trusted => opendir("/proc"))();
            if (procDir is null)
                return;
            scope (exit) (() @trusted => closedir(procDir))();

            struct Snapshot
            {
                int ppid;
                int pgrp;
                ulong userTicks;
                ulong systemTicks;
                ulong startTime;
                ulong rssPages;
            }

            Snapshot[int] processes;
            for (;;)
            {
                auto entry = (() @trusted => readdir(procDir))();
                if (entry is null)
                    break;
                const nameLen = (() @trusted => strlen(entry.d_name.ptr))();
                const name = entry.d_name[0 .. nameLen];
                bool numeric = name.length > 0 && name.length <= 7;
                foreach (c; name)
                    if (c < '0' || c > '9')
                    {
                        numeric = false;
                        break;
                    }
                if (!numeric)
                    continue;
                int pid;
                try
                    pid = to!int(name.idup);
                catch (Exception _)
                    continue;
                int ppid;
                int pgrp;
                ulong u, s2, startTime, rss;
                if (!parseProcStat(pid, ppid, pgrp, u, s2, startTime, rss))
                    continue; // vanished or unreadable: skip this member
                processes[pid] = Snapshot(ppid, pgrp, u, s2, startTime, rss);
            }

            bool descendedFrom(int pid)
            {
                int walker = pid;
                foreach (_; 0 .. 4096)
                {
                    if (walker == rootPid)
                        return true;
                    auto next = walker in processes;
                    if (next is null || walker <= 1)
                        return false;
                    walker = next.ppid;
                }
                return false;
            }

            size_t liveCount;
            ulong rssSum, userTicks, systemTicks;
            foreach (pid, snapshot; processes)
            {
                if (!descendedFrom(pid)
                    && snapshot.pgrp != rootPid)
                    continue;
                ++liveCount;
                rssSum += snapshot.rssPages * pageSize();
                // Mutable, not const: DMD deprecates using a const AA key as
                // the lvalue of an assignment (and the build captures the
                // diagnostic into example-output verification).
                auto identity = ProcessIdentity(pid, snapshot.startTime);
                auto prior = identity in observedCpu;
                if (prior is null)
                    observedCpu[identity] = ProcessCpu(
                        snapshot.userTicks, snapshot.systemTicks);
                else
                {
                    if (snapshot.userTicks > prior.userTicks)
                        prior.userTicks = snapshot.userTicks;
                    if (snapshot.systemTicks > prior.systemTicks)
                        prior.systemTicks = snapshot.systemTicks;
                }
            }

            if (liveCount == 0)
                return; // root not visible: keep prior peaks (§13.8)

            if (rssSum > usage.peakRssBytes)
                usage.peakRssBytes = rssSum;
            if (liveCount > usage.peakProcesses)
                usage.peakProcesses = liveCount;
            ++usage.sampleCount;
            usage.sampled = true;
            foreach (cpu; observedCpu)
            {
                userTicks += cpu.userTicks;
                systemTicks += cpu.systemTicks;
            }
            const hz = clockTicksPerSecond();
            usage.userTime = ticksToDuration(userTicks, hz);
            usage.systemTime = ticksToDuration(systemTicks, hz);
        }
    }
    else
    {
        /**
        Darwin stub: SPEC §13.8 names `proc_pid_rusage` +
        `proc_listchildpids` as the eventual source. Until that lands,
        sampling reports `sampled == false` rather than fabricated numbers;
        wall time still comes from the run itself.
        */
        private void sampleTreeLinux(int, ref ProcessResourceUsage usage,
            ref ProcessCpu[ProcessIdentity] observedCpu)
            @safe
        {
        }
    }

    /** One tree sample folded into the cumulative usage, with wall time. */
    private bool takeSample(ref SupervisionState st) @safe
    {
        const before = st.usage.sampleCount;
        sampleTreeLinux(st.processGroup, st.usage, st.observedCpu);
        st.usage.wallTime = MonoTime.currTime - st.startedAt;
        // A walk that could not see the tree (just-exited root mid-teardown,
        // transient /proc race) changes no cumulative counter; reporting it
        // would repeat stale values and break cumulative monotonicity.
        return st.usage.sampleCount != before;
    }

    /**
    Runs `argv` under full supervision (SPEC §13.5–§13.7): spawn, stdin feed,
    concurrent independent line framing of both pipes (§13.6), optional raw
    collection, cumulative tree samples (§13.8), and one ownership boundary
    around timeout/cancellation teardown (§13.7).

    Guarantees:

    $(UL
        $(LI both output streams are piped (stderr via `mergeStdout` when so
            configured) so they can always be drained;)
        $(LI a fresh process group exists regardless of
            `ProcessConfig.newProcessGroup`, because TERM/KILL target the
            tree;)
        $(LI non-null `stdinBytes` upgrades an inherit stdin to a pipe, is
            fed fully, and closed for EOF;)
        $(LI spawn failure creates no child, emits no event, and returns
            `end == spawnFailed` with `spawnError`;)
        $(LI the first timeout/cancel trigger wins the reported `ProcessEnd`;
            TERM goes to the process group, KILL follows one monotonic
            grace; natural exit during grace suppresses the kill;)
        $(LI both pipes drain to EOF and the child is reaped exactly once on
            every path — including surrounding-scope cancellation, which
            latches on the caller and is delivered only after cleanup and
            the final published event (§13.5 last paragraph);)
        $(LI exactly one `exited` event, only after both EOFs and the reap;
            no callback runs after `supervise` returns;)
        $(LI a sample runs before the exit check, so a just-exited root
            stays observable; missed instants coalesce (one walk at a
            time).)
    )

    Non-zero exit is data (`status`), never an `IoError`. Worker fibers relay
    raw completions only: framing and every callback run synchronously on the
    original supervising fiber, including throughout cancellation cleanup.
    */
    IoResult!SupervisedProcessResult supervise(ref Sched s,
        scope const(char[])[] argv,
        in SupervisedProcessConfig cfg = SupervisedProcessConfig(),
        scope const(ubyte)[] stdinBytes = null,
        scope ProcessEventSink onEvent = null)
        => superviseImpl(s, argv, cfg, stdinBytes, onEvent, null);

    private alias RelayTestHook = void delegate(RelayKind kind);

    private IoResult!SupervisedProcessResult superviseImpl(ref Sched s,
        scope const(char[])[] argv,
        in SupervisedProcessConfig cfg,
        scope const(ubyte)[] stdinBytes,
        scope ProcessEventSink onEvent,
        scope RelayTestHook beforeHandle,
        int* signalAttempts = null) @trusted
    {
        import core.lifetime : move;
        import core.time : Duration, MonoTime, msecs;

        import sparkles.base.buffer : SharedBuffer;
        import sparkles.event_horizon.channel : Channel;
        import sparkles.event_horizon.io : read, sleep, write;
        import sparkles.event_horizon.scope_ : protect, withScope;

        SupervisedProcessResult result;

        // §13.7: supervise owns the group; §13.5: supervision pipes both
        // streams so they can always be drained to EOF.
        ProcessConfig spawnCfg = cfg.process;
        spawnCfg.newProcessGroup = true;
        spawnCfg.stdoutSpec = StdioSpec(StdioMode.pipe);
        spawnCfg.stderrSpec = cfg.process.stderrSpec.mode == StdioMode.mergeStdout
            ? cfg.process.stderrSpec : StdioSpec(StdioMode.pipe);
        if (stdinBytes !is null
            && spawnCfg.stdinSpec.mode == StdioMode.inherit)
            spawnCfg.stdinSpec = StdioSpec(StdioMode.pipe);



        auto spawned = spawnProcess(argv, spawnCfg);
        if (spawned.hasError)
        {
            result.end = ProcessEnd.spawnFailed;
            result.spawnError = spawned.error;
            return ioOk(move(result));
        }
        auto child = spawned.value;
        const savedGroup = child.pid;
        scope (exit)
        {
            child.stdinW.close();
            child.stdoutR.close();
            child.stderrR.close();
            child.ptyMaster.close();
        }

        try
        {
        // Fibers capture plain locals, never `ref`/`scope` parameters (the
        // tui-loop lesson; same shape as `capture`).
        SupervisionState st;
        st.child = &child;
        st.processGroup = savedGroup;
        st.collect = cfg.collectOutput;
        st.collectCap = cfg.maxCapturedBytes;
        st.startedAt = MonoTime.currTime;
        version (unittest)
            st.signalAttempts = signalAttempts;
        cast(void) takeSample(st);

        SharedBuffer!(ubyte, 256) stdinCopy;
        if (stdinBytes !is null)
            stdinCopy ~= stdinBytes;

        auto childP = &child;
        auto stP = &st;
        auto schedP = &s;
        Channel!(RelayMessage, 32) relay;
        auto relayP = &relay;
        ProcessEventSink sink = onEvent;
        Throwable sinkDefect;
        IoError operationError;
        bool hasOperationError;
        bool stdoutFinished, stderrFinished;
        bool abortWorkers, stopProducer, terminationRequested;
        bool resourceExhausted;
        MonoTime graceDeadline;
        LineFramer stdoutFramer, stderrFramer;
        stdoutFramer.maxLineBytes = cfg.maxLineBytes;
        stderrFramer.maxLineBytes = cfg.maxLineBytes;

        void rememberError(IoError error)
        {
            if (!hasOperationError)
            {
                hasOperationError = true;
                operationError = error;
            }
        }

        auto outcome = withScope!((ref sc) {
            void abortRun() nothrow
            {
                abortWorkers = true;
                relay.close();
                childP.stdinW.close();
                sendKill(*stP);
                stopProducer = true;
            }

            try
            {
            bool publish(RelayMessage msg)
            {
                if (abortWorkers)
                    return false;
                return !relayP.put(*schedP, move(msg)).hasError;
            }

            bool spawnWorker(bool daemon, void delegate() body)
            {
                void guarded()
                {
                    try
                        body();
                    catch (Throwable defect)
                    {
                        RelayMessage msg;
                        msg.kind = RelayKind.workerDefect;
                        msg.defect = defect;
                        cast(void) publish(move(msg));
                    }
                }

                const accepted = daemon
                    ? sc.spawnDaemon(&guarded)
                    : sc.spawn(&guarded);
                if (!accepted)
                    resourceExhausted = true;
                return accepted;
            }

            bool spawnDrain(FileHandle f, ProcessStream stream)
            {
                if (f.fd < 0)
                {
                    if (stream == ProcessStream.stdout_)
                        stdoutFinished = true;
                    else
                        stderrFinished = true;
                    return true;
                }
                return spawnWorker(false, () {
                    cast(void) protect!(() {
                        uint retries;
                        for (;;)
                        {
                            if (abortWorkers)
                                return;
                            SharedBuffer!(ubyte, 512) chunk;
                            chunk.length = 512;
                            auto got = read(f, move(chunk));
                            chunk = move(got.buf);
                            RelayMessage msg;
                            msg.stream = stream;
                            if (got.res.hasError)
                            {
                                if (retryProcessError(got.res.error, retries++))
                                {
                                    cast(void) sleep(*schedP, 1.msecs);
                                    continue;
                                }
                                msg.kind = RelayKind.readError;
                                msg.error = got.res.error;
                                cast(void) publish(move(msg));
                                return;
                            }
                            retries = 0;
                            if (got.res.value == 0)
                            {
                                msg.kind = RelayKind.streamEof;
                                cast(void) publish(move(msg));
                                return;
                            }
                            msg.kind = RelayKind.bytes;
                            msg.bytes ~= chunk[][0 .. got.res.value];
                            if (!publish(move(msg)))
                                return;
                        }
                    })(*schedP);
                });
            }

            cast(void) spawnDrain(childP.stdoutR, ProcessStream.stdout_);
            cast(void) spawnDrain(childP.stderrR, ProcessStream.stderr_);

            // Non-consuming exit observation remains cancellable while the
            // supervisor waits on pipes, then the supervisor performs reap.
            if (!spawnWorker(false, () {
                cast(void) protect!(() {
                    uint retries;
                    for (;;)
                    {
                        if (abortWorkers)
                            return;
                        auto observed = observeExit(*schedP, childP.pid);
                        if (observed.hasValue)
                        {
                            RelayMessage msg;
                            msg.kind = RelayKind.rootObserved;
                            cast(void) publish(move(msg));
                            return;
                        }
                        if (!retryProcessError(observed.error, retries++))
                        {
                            RelayMessage msg;
                            msg.kind = RelayKind.waitError;
                            msg.error = observed.error;
                            cast(void) publish(move(msg));
                            return;
                        }
                        cast(void) sleep(*schedP, 1.msecs);
                    }
                })(*schedP);
            }))
                resourceExhausted = true;

            // One protected producer owns timeout, grace, and sample clocks.
            // Its timeout transition precedes publication, so queue pressure
            // cannot make a later cancellation win.
            if (!spawnWorker(false, () {
                cast(void) protect!(() {
                    auto nextSample = cfg.sampleInterval > Duration.zero
                        ? MonoTime.currTime + cfg.sampleInterval
                        : MonoTime.max;
                    const timeoutAt = cfg.timeout > Duration.zero
                        ? stP.startedAt + cfg.timeout : MonoTime.max;
                    bool timeoutFired, killFired;
                    while (!stopProducer && !abortWorkers)
                    {
                        const now = MonoTime.currTime;
                        if (!timeoutFired && now >= timeoutAt)
                        {
                            timeoutFired = true;
                            timeoutOccurred(*stP);
                            childP.stdinW.close();
                            sendTerm(*stP);
                            if (!terminationRequested)
                            {
                                terminationRequested = true;
                                graceDeadline = now + cfg.terminateGrace;
                            }
                            RelayMessage msg;
                            msg.kind = RelayKind.timeout;
                            cast(void) publish(move(msg));
                        }
                        if (terminationRequested && !killFired
                            && now >= graceDeadline)
                        {
                            killFired = true;
                            sendKill(*stP);
                        }
                        if (now >= nextSample)
                        {
                            RelayMessage msg;
                            msg.kind = RelayKind.sampleDue;
                            cast(void) publish(move(msg));
                            nextSample = now + cfg.sampleInterval;
                        }
                        cast(void) sleep(*schedP, 5.msecs);
                    }
                })(*schedP);
            }))
                resourceExhausted = true;

            if (childP.stdinW.fd >= 0)
                if (!spawnWorker(false, () {
                    cast(void) protect!(() {
                        size_t offset;
                        while (offset < stdinCopy.length && !abortWorkers)
                        {
                            SharedBuffer!(ubyte, 512) piece;
                            const n = (stdinCopy.length - offset) < 512
                                ? stdinCopy.length - offset : 512;
                            piece ~= stdinCopy[offset .. offset + n];
                            auto sent = write(childP.stdinW, move(piece));
                            if (sent.res.hasError || sent.res.value == 0)
                                break;
                            offset += sent.res.value;
                        }
                        childP.stdinW.close();
                    })(*schedP);
                }))
                    resourceExhausted = true;

            void requestTermination(ProcessEnd end)
            {
                decideEnd(*stP, end);
                childP.stdinW.close();
                sendTerm(*stP);
                if (!terminationRequested)
                {
                    terminationRequested = true;
                    graceDeadline = MonoTime.currTime + cfg.terminateGrace;
                }
            }

            void invoke(ProcessEvent ev)
            {
                if (sink is null || sinkDefect !is null)
                    return;
                try
                    sink(ev);
                catch (Throwable defect)
                {
                    sinkDefect = defect;
                    sink = null;
                    requestTermination(ProcessEnd.cancelled);
                }
            }

            LineEmit emit = (stream, bytes, terminated, truncated) {
                ProcessEvent ev;
                ev.kind = ProcessEventKind.line;
                ev.line = ProcessLine(stream, bytes, terminated, truncated);
                invoke(ev);
            };

            bool streamsFinished() => stdoutFinished && stderrFinished;
            bool rootObserved;

            void handle(RelayMessage msg)
            {
                if (beforeHandle !is null)
                    beforeHandle(msg.kind);
                final switch (msg.kind)
                {
                    case RelayKind.bytes:
                        const view = msg.bytes[];
                        if (stP.collect)
                        {
                            // Raw collection stops at `maxCapturedBytes` and
                            // says so; framing below is never affected.
                            const isOut = msg.stream == ProcessStream.stdout_;
                            auto buf = isOut ? &stP.stdout_ : &stP.stderr_;
                            auto cut = isOut ? &stP.stdoutTruncated
                                : &stP.stderrTruncated;
                            const cap = stP.collectCap;
                            if (cap == 0 || buf.length + view.length <= cap)
                                *buf ~= view;
                            else
                            {
                                if (buf.length < cap)
                                    *buf ~= view[0 .. cap - buf.length];
                                *cut = true;
                            }
                        }
                        (msg.stream == ProcessStream.stdout_
                            ? stdoutFramer : stderrFramer).push(
                                view, msg.stream, emit);
                        break;
                    case RelayKind.streamEof:
                        (msg.stream == ProcessStream.stdout_
                            ? stdoutFramer : stderrFramer).flushEof(
                                msg.stream, emit);
                        if (msg.stream == ProcessStream.stdout_)
                            stdoutFinished = true;
                        else
                            stderrFinished = true;
                        break;
                    case RelayKind.readError:
                        rememberError(msg.error);
                        if (msg.stream == ProcessStream.stdout_)
                        {
                            childP.stdoutR.close();
                            stdoutFinished = true;
                        }
                        else
                        {
                            childP.stderrR.close();
                            stderrFinished = true;
                        }
                        requestTermination(ProcessEnd.cancelled);
                        break;
                    case RelayKind.rootObserved:
                        rootObserved = true;
                        break;
                    case RelayKind.waitError:
                        rememberError(msg.error);
                        if (waitLostReapRight(msg.error))
                        {
                            // SIGCHLD=SIG_IGN can consume the root behind our
                            // wait, but descendants still belong to the fresh
                            // group and may still own the output writers.
                            requestTermination(ProcessEnd.cancelled);
                            childP.pid = -1;
                        }
                        else
                        {
                            requestTermination(ProcessEnd.cancelled);
                            sendKill(*stP);
                        }
                        rootObserved = true;
                        break;
                    case RelayKind.workerDefect:
                        throw msg.defect;
                    case RelayKind.timeout:
                        break; // producer already recorded the occurrence
                    case RelayKind.sampleDue:
                        if (takeSample(*stP))
                        {
                            ProcessEvent ev;
                            ev.kind = ProcessEventKind.sample;
                            ev.usage = stP.usage;
                            invoke(ev);
                        }
                        break;
                }
            }

            if (resourceExhausted)
            {
                abortWorkers = true;
                relay.close();
                stopProducer = true;
                rememberError(IoError(105 /* ENOBUFS */, OpKind.none,
                    IoErrorStage.submit, "supervision worker unavailable"));
                childP.stdinW.close();
                sendKill(*stP);
                return;
            }

            while (!streamsFinished() || (!rootObserved && !stP.reaped))
            {
                auto next = relayP.take(*schedP);
                if (next.hasError)
                {
                    RelayMessage buffered;
                    while (relayP.tryTake(buffered))
                        handle(move(buffered));
                    requestTermination(ProcessEnd.cancelled);
                    cast(void) protect!(() {
                        while (!streamsFinished()
                            || (!rootObserved && !stP.reaped))
                        {
                            auto cleanup = relayP.take(*schedP);
                            assert(cleanup.hasValue);
                            handle(move(cleanup.value));
                        }
                    })(*schedP);
                    break;
                }
                handle(move(next.value));
            }

            if (!stP.reaped)
            {
                cast(void) takeSample(*stP);
                cast(void) protect!(() {
                    uint retries;
                    for (;;)
                    {
                        auto waited = .wait(*schedP, *childP);
                        if (waited.hasValue)
                        {
                            stP.status = waited.value;
                            stP.reaped = true;
                            break;
                        }
                        if (waitLostReapRight(waited.error))
                        {
                            rememberError(waited.error);
                            childP.pid = -1;
                            break;
                        }
                        if (retryProcessError(waited.error, retries++))
                        {
                            cast(void) sleep(*schedP, 1.msecs);
                            continue;
                        }
                        rememberError(waited.error);
                        sendKill(*stP);
                        auto fallback = waitPidAfterKill(*schedP, childP.pid);
                        if (fallback.hasValue)
                        {
                            stP.status = fallback.value;
                            stP.reaped = true;
                            childP.pid = -1;
                        }
                        else
                        {
                            rememberError(fallback.error);
                            if (waitLostReapRight(fallback.error))
                                childP.pid = -1;
                        }
                        break;
                    }
                })(*schedP);
            }

            // Terminal boundary: stop every producer, invalidate private
            // group ownership, then leave the scope so all workers join.
            stopProducer = true;
            stP.processGroup = -1;
            relay.close(); // releases any producer blocked behind stale data
            }
            catch (Throwable defect)
            {
                // Explicit catch, not scope(failure): Error unwinding may skip
                // scope guards, but workers must be released before joining.
                abortRun();
                throw defect;
            }
        })(s);

        if (resourceExhausted)
        {
            emergencyTerminateDrainReap(s, child, savedGroup, signalAttempts);
            return ioErr!SupervisedProcessResult(105 /* ENOBUFS */,
                OpKind.none, IoErrorStage.submit,
                "supervision worker unavailable");
        }

        // Scope exit joined timeout/grace/drain/wait workers. The final event
        // therefore cannot race a producer or trigger process termination.
        st.usage.wallTime = MonoTime.currTime - st.startedAt;
        if (canPublishExited(st, stdoutFinished, stderrFinished))
        {
            if (sink !is null && sinkDefect is null)
            {
                ProcessEvent exited;
                exited.kind = ProcessEventKind.exited;
                exited.status = st.status;
                exited.end = st.end;
                try
                    sink(exited);
                catch (Throwable defect)
                    sinkDefect = defect;
            }
        }

        if (sinkDefect !is null)
            throw sinkDefect;
        if (hasOperationError)
            return ioErr!SupervisedProcessResult(operationError);
        if (outcome.hasError)
            return ioErr!SupervisedProcessResult(125 /* ECANCELED */,
                OpKind.none, IoErrorStage.completion,
                "supervision worker failed");
        result.end = st.end;
        result.status = st.status;
        result.usage = st.usage;
        result.stdout_ = move(st.stdout_);
        result.stderr_ = move(st.stderr_);
        result.truncatedLines = stdoutFramer.truncatedLines
            + stderrFramer.truncatedLines;
        result.stdoutTruncated = st.stdoutTruncated;
        result.stderrTruncated = st.stderrTruncated;
        return ioOk(move(result));
    }
        catch (Throwable defect)
        {
            emergencyTerminateDrainReap(s, child, savedGroup, signalAttempts);
            throw defect;
        }
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
    import core.thread : Thread;

    import sparkles.event_horizon.capability : hasCaps;

    /// Fault injection for `capture`'s drains: a non-zero errno replaces the
    /// result of every successful read while set.
    package int testCaptureReadErrno;
    /// The pid of the child the last `capture` spawned — for the
    /// no-zombie postconditions.
    package int testLastCapturePid;
    import sparkles.event_horizon.clock : isClock;
    import sparkles.event_horizon.net : isNet;
    import sparkles.event_horizon.proc : isProc;
    import sparkles.test_runner.skip : skipTest;

    static assert(isClock!RingClock);
    static assert(isNet!RingNet);
    static assert(hasCaps!(Env, "clock", "net"));
    static if (canSubmitOp!(DefaultBackend, OpWaitid))
    {
        static assert(isProc!RingProc);
        static assert(hasCaps!(Env, "clock", "net", "proc"));
    }

    private void requireSingleThreadedProcess() @system
    {
        if (Thread.getAll().length != 1)
            skipTest("mutates process-global descriptors/signals; run with -t 1");
    }
}

// ── live subprocess tests ───────────────────────────────────────────────────

version (unittest)
{
    import core.lifetime : move;

    import sparkles.base.buffer : SharedBuffer;
    import sparkles.event_horizon.io : read, write;
    import sparkles.event_horizon.sched : schedOrSkip;

    /// Ring-reads `f` to EOF (or EIO — a drained PTY master) into `into`.
    private void drainInto(ref Sched s, FileHandle f,
        ref SharedBuffer!(ubyte, 512) into) @safe
    {
        SharedBuffer!(ubyte, 128) buf;
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

        SharedBuffer!(ubyte, 512) collected;
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

        SharedBuffer!(ubyte, 64) ping;
        ping ~= cast(const(ubyte)[]) "ping through the ring";
        auto sent = write(child.stdinW, move(ping));
        assert(!sent.res.hasError);
        child.stdinW.close(); // EOF: cat exits after echoing

        SharedBuffer!(ubyte, 512) back;
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

        SharedBuffer!(ubyte, 512) err;
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

        SharedBuffer!(ubyte, 512) out_;
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

version (unittest)
{
    /// The no-zombie postcondition: the reap right for `pid` is gone.
    private bool reapRightConsumed(int pid) @trusted
    {
        import core.stdc.errno : ECHILD, errno;
        import core.sys.posix.sys.wait : WNOHANG, waitpid;

        int raw;
        return waitpid(pid, &raw, WNOHANG) < 0 && errno == ECHILD;
    }
}

@("live.capture.readErrorEndsTheRunAndReaps")
@system
unittest
{
    import core.stdc.errno : EIO;
    import core.time : MonoTime, seconds;

    Sched s;
    schedOrSkip(s);

    testCaptureReadErrno = EIO;
    scope (exit) testCaptureReadErrno = 0;
    auto r = s.run(() {
        // A chatty child that would block on its pipe forever once nobody
        // reads: the failed read must end it, not pose as EOF.
        const started = MonoTime.currTime;
        auto got = capture(s, ["sh", "-c", "while :; do echo chatter; done"]);
        assert(got.hasError && got.error.errnoValue == EIO,
            "the read error is reported, not truncated output");
        assert(MonoTime.currTime - started < 10.seconds);
        assert(reapRightConsumed(testLastCapturePid), "no zombie");
    });
    assert(!r.hasError);
}

@("live.capture.cancellationKillsAndReaps")
@system
unittest
{
    import core.stdc.errno : ECANCELED;
    import core.time : MonoTime, msecs, seconds;

    import sparkles.event_horizon.scope_ : withDeadline;

    Sched s;
    schedOrSkip(s);

    auto r = s.run(() {
        const started = MonoTime.currTime;
        int pid;
        bool sawCancel;
        auto outcome = withDeadline!((ref sc) {
            auto got = capture(s, ["sleep", "30"]);
            sawCancel = got.hasError && got.error.errnoValue == ECANCELED;
            pid = testLastCapturePid;
            // The interrupt is delivered here, after the reap.
            return 0;
        })(s, 100.msecs);
        assert(outcome.hasError && outcome.error.isTimeout);
        assert(sawCancel, "capture reports the cancellation");
        assert(MonoTime.currTime - started < 10.seconds,
            "the child was killed, not waited out");
        assert(reapRightConsumed(pid), "no zombie");
    });
    assert(!r.hasError);
}

@("live.capture.drainAdmissionFailureReapsAndReportsEnobufs")
@system
unittest
{
    import core.stdc.errno : ENOBUFS;

    import sparkles.event_horizon.sched : SchedOptions;

    // Two fiber slots: the root and one drain. The second drain's admission
    // fails, so the run fails with ENOBUFS — and still reaps.
    Sched s;
    SchedOptions opts;
    opts.maxFibers = 2;
    schedOrSkip(s, opts);

    auto r = s.run(() {
        ProcessConfig cfg;
        cfg.stderrSpec = StdioSpec(StdioMode.pipe);
        auto got = capture(s, ["sh", "-c", "while :; do echo chatter; done"], cfg);
        assert(got.hasError && got.error.errnoValue == ENOBUFS,
            "the admission failure is the reported error");
        assert(reapRightConsumed(testLastCapturePid), "no zombie");
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

@("live.killGroup.afterWaitIsLocalEsrch")
@safe
unittest
{
    Sched s;
    schedOrSkip(s);

    auto r = s.run(() {
        ProcessConfig cfg;
        cfg.newProcessGroup = true;
        cfg.stdoutSpec = StdioSpec(StdioMode.inherit);
        auto spawned = spawnProcess(["true"], cfg);
        assert(spawned.hasValue);
        auto child = spawned.value;
        auto status = wait(s, child);
        assert(status.hasValue && status.value.ok);
        auto killed = child.killGroup();
        assert(killed.hasError && killed.error.errnoValue == 3 /* ESRCH */,
            "a reaped low-level handle never signals a reusable PGID");
    });
    assert(!r.hasError);
}

@("live.spawnPty.sessionLeaderOnTheMaster")
@safe
unittest
{
    version (OSX)
    {
        import sparkles.test_runner.skip : skipTest;

        skipTest("PTY master is not pollable via kqueue on macOS");
    }
    else
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

            SharedBuffer!(ubyte, 512) out_;
            drainInto(s, child.ptyMaster, out_);
            assert(out_[] == cast(const(ubyte)[]) "24 80\r\n",
                "the child ran on the slave with the preset winsize");

            auto st = wait(s, child);
            assert(st.hasValue && st.value.ok);
            child.ptyMaster.close();
        });
        assert(!r.hasError);
    }
}

// ── environment overlays (SPEC §13.1) ───────────────────────────────────────

@("live.env.overlaySetReplaceUnsetInherit")
@safe
unittest
{
    Sched s;
    schedOrSkip(s);

    // Pure-function matrix over effectiveEnvironment first: no child needed
    // to prove ordering, last-wins, unset, and inheritance.
    ProcessConfig cfg;
    cfg.env = cast(const(char[])[]) ["A=base", "B=base", "PATH=/bin"];
    cfg.envOverlay = cast(const(EnvironmentChange)[])([
        EnvironmentChange("C", "new"),      // set on top of the base
        EnvironmentChange("A", "over"),     // replace
        EnvironmentChange("A", "over2"),    // last change wins
        EnvironmentChange("B", null, true), // remove
        EnvironmentChange("D", "v", true),  // unset of absent: no-op
    ]);
    const built = effectiveEnvironment(cfg);
    assert(built.hasValue, built.error.context);
    const entries = built.value;
    bool has(const(char)[] entry) @safe pure nothrow @nogc
    {
        foreach (e; entries)
            if (e == entry)
                return true;
        return false;
    }
    assert(has("A=over2"), "last change for a name wins");
    assert(!has("A=base") && !has("B=base"), "unset removes");
    assert(has("C=new") && has("PATH=/bin"), "sets and replaces landed");
    assert(!has("D=v"),
        "unsetting an absent name is a no-op, not an insert");
}

@("live.env.overlayOnInheritedKeepsParentValues")
@safe
unittest
{
    Sched s;
    schedOrSkip(s);

    auto r = s.run(() {
        // One edit on top of the INHERITED environment: the parent's other
        // variables ride along untouched (§13.1's whole point vs. `env=`).
        ProcessConfig cfg;
        cfg.envOverlay = cast(const(EnvironmentChange)[])([
            EnvironmentChange("EH_PROBE", "overlay"),
        ]);
        auto got = capture(s, ["sh", "-c", "echo $EH_PROBE"], cfg);
        assert(got.hasValue, got.error.context);
        assert(got.value.stdout_[] == cast(const(ubyte)[]) "overlay\n");
        assert(got.value.status.ok);
    });
    assert(!r.hasError);
}

@("live.env.emptyReplacementStaysEmptyAndDuplicatesCollapse")
@safe
unittest
{
    // A zero-length non-null slice is a complete replacement, not inherit.
    auto storage = new const(char)[][1];
    ProcessConfig empty;
    empty.env = storage[0 .. 0];
    assert(empty.env !is null);
    auto builtEmpty = effectiveEnvironment(empty);
    assert(builtEmpty.hasValue && builtEmpty.value.length == 0);

    Sched s;
    schedOrSkip(s);
    auto ran = s.run(() {
        auto child = capture(s, ["/usr/bin/env"], empty);
        assert(child.hasValue, child.hasError ? child.error.context : "");
        assert(child.value.status.ok && child.value.stdout_.length == 0,
            "a non-null empty replacement reaches the child as empty");
    });
    assert(!ran.hasError);

    ProcessConfig duplicate;
    duplicate.env = cast(const(char[])[]) ["A=one", "A=two", "B=keep"];
    duplicate.envOverlay = cast(const(EnvironmentChange)[]) [
        EnvironmentChange("A", "final"),
    ];
    auto built = effectiveEnvironment(duplicate);
    assert(built.hasValue);
    size_t aCount;
    foreach (entry; built.value)
        if (envNameOf(entry) == "A")
        {
            ++aCount;
            assert(entry == "A=final");
        }
    assert(aCount == 1, "an overlay removes every duplicate before setting");
}

@("live.env.invalidEditsFailBeforeAnyChild")
@safe
unittest
{
    Sched s;
    schedOrSkip(s);

    static void expectEinvalid(scope const(EnvironmentChange)[] edits)
    {
        ProcessConfig cfg;
        cfg.envOverlay = edits;
        const bad = effectiveEnvironment(cfg);
        assert(bad.hasError);
        assert(bad.error.errnoValue == 22 /* EINVAL */);
        assert(bad.error.stage == IoErrorStage.submit,
            "a pre-spawn rejection is a submit-stage failure");
    }

    expectEinvalid([EnvironmentChange(null, "v", false)]); // empty name
    expectEinvalid([EnvironmentChange("na=me", "v", false)]); // '=' in name
    expectEinvalid([EnvironmentChange("na\0me", "v", false)]); // NUL in name
    expectEinvalid([EnvironmentChange("ok", "va\0l", false)]); // NUL in value

    foreach (entry; ["", "NOVALUE", "=value", "NA\0ME=value",
        "NAME=va\0lue"])
    {
        ProcessConfig replacement;
        replacement.env = [entry];
        const bad = effectiveEnvironment(replacement);
        assert(bad.hasError && bad.error.errnoValue == 22,
            "malformed replacement entries fail before spawn");
    }

    // And through the public spawner, which must not leave a child behind.
    ProcessConfig cfg;
    cfg.envOverlay = [EnvironmentChange("bad=name", "v", false)];
    const refused = spawnProcess(["true"], cfg);
    assert(refused.hasError && refused.error.errnoValue == 22);
}

@("live.spawn.rejectsNulInArgvAndCwdBeforeChild")
@safe
unittest
{
    ProcessConfig cfg;
    auto badArg = spawnProcess(["true", "bad\0tail"], cfg);
    assert(badArg.hasError && badArg.error.errnoValue == 22);

    cfg.cwd = "/tmp\0ignored";
    auto badCwd = spawnProcess(["true"], cfg);
    assert(badCwd.hasError && badCwd.error.errnoValue == 22);

    cfg.cwd = "";
    auto emptyCwd = validateSpawnStrings(["true"], cfg.cwd);
    assert(!emptyCwd.hasError, "empty cwd contains no invalid byte");
}

@("live.spawn.pipeFdCollisionKeepsChildStdinOpen")
@system
unittest
{
    import core.sys.posix.signal : SIG_IGN, SIGPIPE, sigaction,
        sigaction_t, sigemptyset;
    import core.sys.posix.unistd : STDERR_FILENO, STDIN_FILENO, STDOUT_FILENO,
        close, dup, dup2;

    requireSingleThreadedProcess();
    Sched s;
    schedOrSkip(s);

    sigaction_t ignored, previousPipe;
    ignored.sa_handler = SIG_IGN;
    sigemptyset(&ignored.sa_mask);
    assert(sigaction(SIGPIPE, &ignored, &previousPipe) == 0);

    IoResult!void runResult;
    try
    {
        runResult = s.run(() {
            void withClosedFd(int fd, scope void delegate() body)
            {
                const saved = dup(fd);
                assert(saved >= 0 && close(fd) == 0);
                try
                    body();
                catch (Throwable defect)
                {
                    cast(void) dup2(saved, fd);
                    close(saved);
                    throw defect;
                }
                assert(dup2(saved, fd) == fd);
                close(saved);
            }

            withClosedFd(STDIN_FILENO, () {
                auto got = capture(s, ["cat"], ProcessConfig(),
                    cast(const(ubyte)[]) "fd-zero-survives");
                assert(got.hasValue && got.value.status.ok);
                assert(got.value.stdout_[]
                    == cast(const(ubyte)[]) "fd-zero-survives");
            });
            withClosedFd(STDOUT_FILENO, () {
                auto got = capture(s, ["sh", "-c", "printf stdout"]);
                assert(got.hasValue && got.value.status.ok);
                assert(got.value.stdout_[] == cast(const(ubyte)[]) "stdout");
            });
            withClosedFd(STDERR_FILENO, () {
                ProcessConfig cfg;
                cfg.stdoutSpec = StdioSpec(StdioMode.nullDev);
                cfg.stderrSpec = StdioSpec(StdioMode.pipe);
                auto got = capture(s, ["sh", "-c", "printf stderr >&2"], cfg);
                assert(got.hasValue && got.value.status.ok);
                assert(got.value.stderr_[] == cast(const(ubyte)[]) "stderr");
            });
        });
    }
    catch (Throwable defect)
    {
        cast(void) sigaction(SIGPIPE, &previousPipe, null);
        throw defect;
    }
    const signalRestored = sigaction(SIGPIPE, &previousPipe, null);

    assert(signalRestored == 0);
    assert(!runResult.hasError,
        "dup2(fd, fd) must not be followed by a child close action");
}

version (unittest)
private string makeProbeDir(string marker) @system
{
    import core.sys.posix.unistd : getpid;
    import std.conv : text;
    import std.file : mkdirRecurse, tempDir, write;
    import std.path : buildPath;

    const dir = buildPath(tempDir(),
        text("eh-path-probe-", marker, "-", getpid()));
    mkdirRecurse(dir);
    {
        import std.string : toStringz;
        import core.sys.posix.sys.stat : chmod;

        const script = buildPath(dir, "ehprobe");
        write(script, "#!/bin/sh\necho from-overlay\n");
        enum uint mode755 = 493; // 0o755
        cast(void) chmod(script.toStringz, mode755);
    }
    return dir;
}

@("live.env.pathLookupUsesTheOverlayResult")
@system
unittest
{
    Sched s;
    schedOrSkip(s);

    const probeDir = makeProbeDir("lookup");
    const scriptPath = probeDir ~ "/ehprobe";
    // Unconditional: a failing assertion below must not strand the probe
    // script or its directory in the temp dir.
    scope (exit)
    {
        import std.file : remove, rmdir;

        remove(scriptPath);
        rmdir(probeDir);
    }

    auto r = s.run(() {
        // Control: without the overlay the bare name is not findable.
        const missing = capture(s, ["ehprobe"]);
        assert(missing.hasError, "the probe name must not resolve by luck");

        // With PATH overlaid onto the inherited environment, the lookup
        // runs against the RESULTING environment and finds our script.
        ProcessConfig cfg;
        cfg.envOverlay = cast(const(EnvironmentChange)[])([
            EnvironmentChange("PATH", probeDir),
        ]);
        auto found = capture(s, ["ehprobe"], cfg);
        assert(found.hasValue, found.hasError ? found.error.context : "");
        assert(found.value.status.ok);
        assert(found.value.stdout_[] == cast(const(ubyte)[]) "from-overlay\n");

        // A PATH-less environment still resolves through the `_CS_PATH`
        // fallback, so plain system tools keep working.
        ProcessConfig noPath;
        noPath.env = cast(const(char[])[]) ["EH_PROBE=x"]; // no PATH entry
        auto fallback = capture(s, ["sh", "-c", "echo fallback"], noPath);
        assert(fallback.hasValue, fallback.error.context);
        assert(fallback.value.stdout_[] == cast(const(ubyte)[]) "fallback\n");
    });
    assert(!r.hasError);
}

@("live.env.customPathMissAndChildCwdRelativeLookup")
@system
unittest
{
    import core.sys.posix.sys.stat : chmod;
    import std.file : mkdirRecurse, remove, rmdir, tempDir, write;
    import std.path : buildPath;
    import std.string : toStringz;

    Sched s;
    schedOrSkip(s);

    import core.sys.posix.unistd : getpid;
    import std.conv : text;

    const root = buildPath(tempDir(), text("eh-path-cwd-probe-", getpid()));
    const bin = buildPath(root, "bin");
    const script = buildPath(bin, "cwdprobe");
    const emptyScript = buildPath(root, "emptyprobe");
    mkdirRecurse(bin);
    write(script, "#!/bin/sh\nprintf cwd-relative\n");
    write(emptyScript, "#!/bin/sh\nprintf cwd-empty\n");
    cast(void) chmod(script.toStringz, 493 /* 0o755 */);
    cast(void) chmod(emptyScript.toStringz, 493 /* 0o755 */);
    scope (exit)
    {
        remove(script);
        remove(emptyScript);
        rmdir(bin);
        rmdir(root);
    }

    auto r = s.run(() {
        ProcessConfig excluded;
        excluded.env = cast(const(char[])[]) ["PATH=/definitely/not/here"];
        auto missing = capture(s, ["sh", "-c", "exit 0"], excluded);
        assert(missing.hasError && missing.error.errnoValue == 2,
            "a custom PATH miss must not retry through the parent PATH");

        // The cwd contains an executable with this bare name, but PATH does
        // not. Returning the bare spelling after a miss would let the child
        // chdir make it executable despite the configured PATH exclusion.
        ProcessConfig cwdExcluded;
        cwdExcluded.env = cast(const(char[])[]) ["PATH=/definitely/not/here"];
        cwdExcluded.cwd = root;
        auto cwdMiss = capture(s, ["emptyprobe"], cwdExcluded);
        assert(cwdMiss.hasError && cwdMiss.error.errnoValue == 2,
            "a PATH miss is ENOENT with no child left behind, even when cwd matches");

        ProcessConfig relative;
        relative.env = cast(const(char[])[]) ["PATH=bin"];
        relative.cwd = root;
        auto found = capture(s, ["cwdprobe"], relative);
        assert(found.hasValue, found.hasError ? found.error.context : "");
        assert(found.value.status.ok);
        assert(found.value.stdout_[] == cast(const(ubyte)[]) "cwd-relative");

        ProcessConfig emptyComponent;
        emptyComponent.env = cast(const(char[])[]) ["PATH="];
        emptyComponent.cwd = root;
        auto foundEmpty = capture(s, ["emptyprobe"], emptyComponent);
        assert(foundEmpty.hasValue,
            foundEmpty.hasError ? foundEmpty.error.context : "");
        assert(foundEmpty.value.stdout_[] == cast(const(ubyte)[]) "cwd-empty",
            "an empty PATH component resolves in the configured child cwd");
    });
    assert(!r.hasError);
}

@("live.env.pathSearchStickyEaccesAndNoShellFallback")
@system
unittest
{
    import core.stdc.errno : EACCES, ENOEXEC, ENOENT;
    import core.sys.posix.sys.stat : chmod;
    import core.sys.posix.unistd : getpid;
    import std.conv : text;
    import std.file : mkdirRecurse, remove, rmdir, tempDir, write;
    import std.path : buildPath;
    import std.string : toStringz;

    Sched s;
    schedOrSkip(s);

    const root = buildPath(tempDir(), text("eh-path-search-probe-", getpid()));
    const unexec = buildPath(root, "unexec");
    const exec = buildPath(root, "exec");
    const garbage = buildPath(root, "garbage");
    mkdirRecurse(unexec);
    mkdirRecurse(exec);
    mkdirRecurse(garbage);
    // The same name three ways: not executable, executable, and an
    // executable that is not an exec format.
    write(buildPath(unexec, "ehprobe"), "#!/bin/sh\nprintf wrong\n");
    write(buildPath(exec, "ehprobe"), "#!/bin/sh\nprintf right\n");
    write(buildPath(garbage, "ehprobe"), "\x00\x01\x02not-an-executable");
    cast(void) chmod(buildPath(unexec, "ehprobe").toStringz, 420 /* 0o644 */);
    cast(void) chmod(buildPath(exec, "ehprobe").toStringz, 493 /* 0o755 */);
    cast(void) chmod(buildPath(garbage, "ehprobe").toStringz, 493 /* 0o755 */);
    scope (exit)
    {
        foreach (dir; [unexec, exec, garbage])
        {
            remove(buildPath(dir, "ehprobe"));
            rmdir(dir);
        }
        rmdir(root);
    }

    auto r = s.run(() {
        // EACCES is sticky: a later miss does not downgrade it to ENOENT.
        ProcessConfig sticky;
        sticky.env = cast(const(char[])[])(
            ["PATH=" ~ unexec ~ ":/definitely/not/here"]);
        auto denied = capture(s, ["ehprobe"], sticky);
        assert(denied.hasError && denied.error.errnoValue == EACCES,
            "the unexecutable match is reported, not hidden as ENOENT");

        // …but EACCES does not stop the search: a later executable wins.
        ProcessConfig later;
        later.env = cast(const(char[])[])(["PATH=" ~ unexec ~ ":" ~ exec]);
        auto found = capture(s, ["ehprobe"], later);
        assert(found.hasValue, found.hasError ? found.error.context : "");
        assert(found.value.stdout_[] == cast(const(ubyte)[]) "right");

        // A miss everywhere is ENOENT.
        ProcessConfig none;
        none.env = cast(const(char[])[]) ["PATH=/definitely/not/here"];
        auto missing = capture(s, ["ehprobe"], none);
        assert(missing.hasError && missing.error.errnoValue == ENOENT);

        // No /bin/sh retry: an unrecognised format is ENOEXEC, in a custom
        // and in the inherited environment alike.
        ProcessConfig unrecognised;
        unrecognised.env = cast(const(char[])[])(["PATH=" ~ garbage]);
        auto format = capture(s, ["ehprobe"], unrecognised);
        assert(format.hasError && format.error.errnoValue == ENOEXEC,
            format.hasError ? format.error.context : "spawned garbage");
        auto direct = capture(s, [buildPath(garbage, "ehprobe")]);
        assert(direct.hasError && direct.error.errnoValue == ENOEXEC,
            "a name with a slash is spawned as spelled, still without a shell");
    });
    assert(!r.hasError);
}

// ── supervised runs (SPEC §13.5–§13.8) ──────────────────────────────────────

version (unittest)
{
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
}

@("live.supervise.naturalExitLinesCollectAndUsage")
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

@("live.supervise.finalSampleOccursBeforeReap")
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

@("live.supervise.internalDefectCleanupPrimitiveReaps")
@safe
unittest
{
    import core.time : MonoTime, seconds;

    Sched s;
    schedOrSkip(s);
    const before = MonoTime.currTime;
    auto r = s.run(() {
        ProcessConfig cfg;
        cfg.newProcessGroup = true;
        cfg.stdinSpec = StdioSpec(StdioMode.nullDev);
        cfg.stderrSpec = StdioSpec(StdioMode.pipe);
        auto spawned = spawnProcess(["sh", "-c",
            "echo out; echo err >&2; sleep 30"], cfg);
        assert(spawned.hasValue);
        auto child = spawned.value;
        const group = child.pid;
        emergencyTerminateDrainReap(s, child, group);
        assert(!child, "exceptional cleanup consumed the reap right");
        child.stdoutR.close();
        child.stderrR.close();
    });
    assert(!r.hasError);
    assert(MonoTime.currTime - before < 2.seconds,
        "internal-defect cleanup does not strand workers or the child");
}

@("live.supervise.nullSinkNaturalExitIsPrompt")
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

@("live.supervise.callbacksStayOnSupervisorAndDefectsStillCleanUp")
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

@("live.supervise.finalCallbackCannotRetriggerTermination")
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
        ProcessEnd yieldedEnd;
        auto yielded = superviseImpl(s, ["true"], SupervisedProcessConfig(),
            null, (in ProcessEvent ev) {
                if (ev.kind == ProcessEventKind.exited)
                {
                    assert(!sleep(s, 150.msecs).hasError);
                    yieldedEnd = ev.end;
                }
            }, null, &signalAttempts);
        assert(yielded.hasValue);
        assert(yielded.value.end == ProcessEnd.exited
            && yieldedEnd == ProcessEnd.exited,
            "a yielding final callback cannot mutate a terminal run");
        assert(signalAttempts == 0,
            "yielding final callback cannot signal the retired group");

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
        ProcessEnd thrownEnd;
        bool threw;
        try
            cast(void) superviseImpl(s, ["true"], SupervisedProcessConfig(), null,
                (in ProcessEvent ev) {
                    if (ev.kind == ProcessEventKind.exited)
                    {
                        thrownEnd = ev.end;
                        throw new Exception("final sink defect");
                    }
                }, null, &signalAttempts);
        catch (Exception e)
            threw = e.msg == "final sink defect";
        assert(threw && thrownEnd == ProcessEnd.exited);
        assert(signalAttempts == 0,
            "throwing final callback only rethrows after terminal cleanup");
    });
    assert(!r.hasError);
}

@("live.supervise.framingMatrix")
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

@("live.supervise.lineCapTruncatesOnceAndReports")
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

@("live.supervise.captureCapStopsAccumulationAndReports")
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

@("live.supervise.longLineIsLinear")
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

@("live.supervise.streamsAreIndependentMergeIsTotalOrder")
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

@("live.supervise.collectOutputControlsAccumulationOnly")
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

@("live.supervise.stdinFeedRoundTrip")
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

@("live.supervise.spawnFailureEmitsNothing")
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

@("live.supervise.timeoutTermExitsTheChild")
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

@("live.supervise.graceExpiryEscalatesToKill")
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

@("live.supervise.exitedRootStillTerminatesGroupHoldingPipe")
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

@("live.supervise.exitedRootDescendantIgnoringTermGetsKilledAfterGrace")
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

@("live.supervise.autoReapedRootStillCleansItsProcessGroup")
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

@("live.supervise.scopeCancellationLatchesThenConverges")
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

@("live.supervise.cancellationDrainsAndFramesFinalFragment")
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

@("live.supervise.externalCancellationStillEscalatesPastTerm")
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

@("live.supervise.fiberExhaustionKillsDrainsAndReaps")
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

@("live.supervise.waitFailureTransitionIsBounded")
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

@("live.supervise.exitedRequiresRealEofAndStatus")
@system
unittest
{
    SupervisionState st;
    assert(!canPublishExited(st, true, true),
        "zero-initialized status is not a reap result");
    st.reaped = true;
    assert(!canPublishExited(st, false, true),
        "both drains must reach a terminal state before publication");
    assert(canPublishExited(st, true, true));

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

@("live.supervise.callbackDefectWithSaturatedOutputStillCleansUp")
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

@("live.supervise.cancelAfterBothEofStillTerminatesRoot")
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
    auto r = s.run(() {
        auto outcome = withScope!((ref outer) {
            JoinHandle!void h;
            outer.fork(h, () {
                SupervisedProcessConfig cfg;
                cfg.terminateGrace = 100.msecs;
                cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
                auto run = supervise(s, ["sh", "-c",
                    `exec 1>&- 2>&-; trap '' TERM; sleep 30`], cfg);
                assert(run.hasValue, run.hasError ? run.error.context : "");
                got = move(run.value);
                return ioOk();
            });
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

@("live.supervise.timeoutWinsBeforeRelayPublication")
@safe pure nothrow @nogc
unittest
{
    SupervisionState st;
    timeoutOccurred(st); // producer records occurrence before relay.put
    decideEnd(st, ProcessEnd.cancelled); // cancelled take observed second
    assert(st.end == ProcessEnd.timedOut,
        "the earlier buffered timeout remains the first trigger");
}

@("live.supervise.cooperativeTermSuppressesKillAndGraceDelay")
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
@("live.supervise.repeatedRunsDoNotLeakDescriptors")
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

@("live.supervise.exitBeforeEofWaitsForGrandchildren")
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

@("live.supervise.eofBeforeExitStillReaps")
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

@("live.supervise.chattyDualStreamsCannotDeadlock")
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

@("live.supervise.samplesCumulativeAndCoalesced")
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

@("live.supervise.samplesCpuMonotonicAndTracksExitedRootsGroup")
@safe
unittest
{
    import core.time : msecs;

    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        EventLog log;
        SupervisedProcessConfig cfg;
        cfg.sampleInterval = 20.msecs;
        auto got = supervise(s, ["sh", "-c",
            `{ i=0; while [ $i -lt 150000 ]; do i=$((i+1)); done; sleep 0.2; } & exit 0`],
            cfg, null, log.sink());
        assert(got.hasValue, got.hasError ? got.error.context : "");

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

@("live.supervise.samplesAccumulateSequentialDescendantCpu")
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
