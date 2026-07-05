/**
Async subprocesses (PLAN M7): spawn via `posix_spawnp` with piped stdio,
stream the pipes through the ring, and reap the child with an in-ring
`WAITID` — no `SIGCHLD` handling, no blocking `wait`.

Loop-side module (the capability concept + test double join `live`/`Env` in
M9).
*/
module sparkles.event_horizon.proc;

version (linux)  :  // rides the linux Sched; generalizes with M10

import core.sys.posix.signal : siginfo_t;

import sparkles.event_horizon.errors;
import sparkles.event_horizon.io : FileHandle;
import sparkles.event_horizon.op;
import sparkles.event_horizon.sched : Sched;

/// A spawned child: its pid and the read end of its captured stdout.
struct ChildProcess
{
    int pid = -1;      /// the child's pid (`-1` after `wait`)
    FileHandle stdout_; /// read end of the child's stdout (owned)

    /// `true` while the child is reapable.
    bool opCast(T : bool)() const @safe pure nothrow @nogc => pid > 0;
}

/**
Spawns `argv` (PATH-searched) with stdout captured into a pipe whose read
end is returned on the handle. The write end is closed in the parent, so
the pipe reads EOF when the child exits.
*/
IoResult!ChildProcess spawnProcess(scope const(char[])[] argv) @trusted
{
    import core.stdc.stdlib : free, malloc;
    import core.sys.posix.fcntl : F_SETFD, FD_CLOEXEC, fcntl;
    import core.sys.posix.spawn : posix_spawn_file_actions_adddup2,
        posix_spawn_file_actions_addclose, posix_spawn_file_actions_destroy,
        posix_spawn_file_actions_init, posix_spawn_file_actions_t, posix_spawnp;
    import core.sys.posix.unistd : close, pipe;

    if (argv.length == 0)
        return ioErr!ChildProcess(22 /* EINVAL */, OpKind.none,
            IoErrorStage.submit, "empty argv");

    int[2] fds;
    if (pipe(fds) != 0)
        return ioErr!ChildProcess(24 /* EMFILE */, OpKind.none,
            IoErrorStage.submit, "pipe failed");

    // NUL-terminated argv on the C heap for the spawn call's duration.
    auto cargv = cast(char**) malloc((argv.length + 1) * (char*).sizeof);
    scope (exit) free(cargv);
    char[4096] argBytes = void;
    size_t used;
    foreach (i, arg; argv)
    {
        if (used + arg.length + 1 > argBytes.length)
        {
            close(fds[0]);
            close(fds[1]);
            return ioErr!ChildProcess(7 /* E2BIG */, OpKind.none,
                IoErrorStage.submit, "argv too large");
        }
        argBytes[used .. used + arg.length] = arg[];
        argBytes[used + arg.length] = '\0';
        cargv[i] = &argBytes[used];
        used += arg.length + 1;
    }
    cargv[argv.length] = null;

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    scope (exit) posix_spawn_file_actions_destroy(&actions);
    posix_spawn_file_actions_adddup2(&actions, fds[1], 1); // child stdout
    posix_spawn_file_actions_addclose(&actions, fds[0]);
    posix_spawn_file_actions_addclose(&actions, fds[1]);

    int pid;
    const rc = posix_spawnp(&pid, cargv[0], &actions, null, cargv, null);
    close(fds[1]); // parent keeps only the read end
    if (rc != 0)
    {
        close(fds[0]);
        return ioErr!ChildProcess(rc, OpKind.none, IoErrorStage.submit,
            "posix_spawnp failed");
    }
    return ioOk(ChildProcess(pid, FileHandle(fds[0])));
}

/// Parks until the child exits (in-ring `WAITID`); the exit code.
IoResult!int wait(ref Sched s, ref ChildProcess child)
{
    import core.sys.posix.sys.wait : WEXITED, idtype_t;

    if (child.pid <= 0)
        return ioErr!int(10 /* ECHILD */, OpKind.waitid, IoErrorStage.submit,
            "no child to reap");

    // The siginfo out-buffer lives on this parked frame (§6.5).
    siginfo_t info;
    auto o = s.await(OpWaitid(cast(int) idtype_t.P_PID, cast(uint) child.pid,
        (() @trusted => cast(void*) &info)(), WEXITED));
    if (o.res < 0)
        return ioErr!int(-o.res, OpKind.waitid);
    child.pid = -1;
    return ioOk((() @trusted => info._sifields._sigchld.si_status)());
}

@("proc.spawn.streamAndReap")
@safe
unittest
{
    import core.lifetime : move;

    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.event_horizon.io : read;

    Sched s;
    if (Sched.create(s).hasError)
        return; // SKIP: io_uring unavailable
    scope (exit) s.destroy();

    auto r = s.run(() {
        auto spawned = spawnProcess(["echo", "event", "horizon"]);
        assert(spawned.hasValue);
        auto child = spawned.value;

        // Stream the child's stdout through the ring until EOF.
        SmallBuffer!(ubyte, 256) collected;
        SmallBuffer!(ubyte, 64) buf;
        for (;;)
        {
            buf.length = 64;
            auto got = read(child.stdout_, move(buf));
            buf = move(got.buf);
            assert(!got.res.hasError);
            if (got.res.value == 0)
                break; // EOF: the child exited and the pipe drained
            collected ~= buf[][0 .. got.res.value];
        }
        assert(collected[] == cast(const(ubyte)[]) "event horizon\n");

        auto code = wait(s, child);
        assert(code.hasValue && code.value == 0);
        assert(!child, "reaped");

        child.stdout_.close();
    });
    assert(!r.hasError);
}

@("proc.wait.nonZeroExitCode")
@safe
unittest
{
    Sched s;
    if (Sched.create(s).hasError)
        return; // SKIP
    scope (exit) s.destroy();

    auto r = s.run(() {
        auto spawned = spawnProcess(["false"]);
        assert(spawned.hasValue);
        auto child = spawned.value;
        auto code = wait(s, child);
        assert(code.hasValue && code.value == 1);
        child.stdout_.close();
    });
    assert(!r.hasError);
}
