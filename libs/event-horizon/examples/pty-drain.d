#!/usr/bin/env dub
/+ dub.sdl:
    name "event_horizon_pty_drain"
    dependency "sparkles:event-horizon" path="../../.."
    platforms "linux"
    targetPath "build"
+/
/**
 * The M13b core: `apps/terminal`'s PTY drain, ported onto the event loop.
 *
 * The terminal today spawns a shell with `forkpty`, sets the master fd
 * non-blocking, and polls it inside the raylib render loop. On event-horizon
 * the same master fd is drained through the ring: a `read` verb parks the
 * fiber and resumes on the next chunk — no polling, no non-blocking EAGAIN
 * spin. This example spawns a short command under a PTY, drains its output
 * through the loop until the child exits (the master reports EIO once the
 * slave side is gone), reaps it, and verifies the captured output. (The
 * in-ring WAITID reap is shown by the agent-tooling example; forkpty here
 * owns the pid directly, so a plain waitpid on an already-dead child does.)
 *
 * The raylib window + libghostty-vt feed are unchanged in the real port;
 * this isolates the loop-side I/O so it stays CI-verifiable headlessly.
 *
 * Run with: `dub run --single pty-drain.d`
 *
 * SKIPs (exit 0) if io_uring or a PTY is unavailable.
 */
module event_horizon_pty_drain;

import core.lifetime : move;
import std.stdio : writefln, writeln;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.event_horizon.io : FileHandle, read;
import sparkles.event_horizon.sched : Sched;

extern (C) int forkpty(int* amaster, char* name, const void* termp, const void* winp);

int main()
{
    Sched sched;
    if (Sched.create(sched).hasError)
    {
        writeln("SKIP: io_uring unavailable");
        return 0;
    }
    scope (exit) sched.destroy();

    // Spawn a short-lived command under a fresh PTY.
    int masterFd;
    const pid = forkpty(&masterFd, null, null, null);
    if (pid < 0)
    {
        writeln("SKIP: forkpty failed (no PTY available)");
        return 0;
    }
    if (pid == 0)
    {
        // Child: exec the command over the PTY slave (stdin/out/err), then
        // exit. The output flows to the master the parent drains.
        import core.stdc.stdlib : exit;
        import core.sys.posix.unistd : execlp;

        execlp("printf".ptr, "printf".ptr, "pty-line-1\npty-line-2\n".ptr,
            cast(char*) null);
        exit(127); // execlp only returns on failure
    }

    // Parent: drain the master through the event loop until the child's
    // output ends, then reap it in-ring.
    SmallBuffer!(char, 256) captured;
    int exitCode = -1;
    auto r = sched.run(() @trusted {
        auto master = FileHandle(masterFd);
        for (;;)
        {
            SmallBuffer!(ubyte, 128) buf;
            buf.length = 128;
            auto got = read(master, move(buf));
            buf = move(got.buf);
            if (got.res.hasError)
                break; // EIO: the slave closed and the child is gone
            if (got.res.value == 0)
                break; // clean EOF
            captured ~= cast(const(char)[]) buf[][0 .. got.res.value];
        }
        master.close();

        // Reap the child — it has already exited (that's why the master
        // reported EOF/EIO), so a plain waitpid returns immediately. (The
        // in-ring WAITID path is demonstrated by the agent-tooling example,
        // which spawns via posix_spawn; forkpty here owns the pid directly.)
        exitCode = (() @trusted {
            import core.sys.posix.sys.wait : waitpid, WEXITSTATUS;

            int status;
            waitpid(pid, &status, 0);
            return WEXITSTATUS(status);
        })();
    });
    assert(!r.hasError);

    // PTYs translate \n to \r\n on output; check the payload lines are there.
    const ok = contains(captured[], "pty-line-1") && contains(captured[], "pty-line-2");
    if (ok)
        writefln("ok: drained %d bytes from the PTY, child exited %d",
            captured.length, exitCode);
    else
        writeln("FAILED: expected PTY output not captured");
    return ok ? 0 : 1;
}

bool contains(const(char)[] hay, const(char)[] needle) @safe
{
    if (needle.length == 0 || hay.length < needle.length)
        return false;
    foreach (i; 0 .. hay.length - needle.length + 1)
        if (hay[i .. i + needle.length] == needle)
            return true;
    return false;
}
