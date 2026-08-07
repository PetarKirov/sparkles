#!/usr/bin/env dub
/+ dub.sdl:
    name "event_horizon_pty_drain"
    dependency "sparkles:event-horizon" path="../../.."
    platforms "linux"
    targetPath "build"
    // Optimised, assertions live, `debug {}` blocks out — the build every nix
    // artifact uses. Neither `debug` (which compiles those blocks in) nor
    // `release` (which deletes assert *expressions*, side effects included).
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * The M13b core, completed by M15: `apps/terminal`'s PTY drain AND reap,
 * both on the event loop.
 *
 * The terminal today spawns a shell with `forkpty`, sets the master fd
 * non-blocking, and polls it inside the raylib render loop. On event-horizon
 * the child is spawned with `spawnPty` (a `posix_spawn` session leader on a
 * fresh PTY — SPEC §13.3), the master is drained through the ring — a `read`
 * verb parks the fiber and resumes on the next chunk, no EAGAIN spin — and
 * the child is reaped with the in-ring `WAITID` (`wait` → `ExitStatus`),
 * which `forkpty` could never route through the loop.
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
import sparkles.event_horizon.io : read;
import sparkles.event_horizon.live : spawnPty, wait;
import sparkles.event_horizon.sched : Sched;

int main()
{
    Sched sched;
    if (Sched.create(sched).hasError)
    {
        writeln("SKIP: io_uring unavailable");
        return 0;
    }
    scope (exit) sched.destroy();

    SmallBuffer!(char, 256) captured;
    bool cleanExit;
    bool skipped;
    auto r = sched.run(() {
        // A short-lived command as a session leader on a fresh PTY, with a
        // preset 80×24 winsize.
        auto spawned = spawnPty(["printf", "pty-line-1\npty-line-2\n"], 80, 24);
        if (spawned.hasError)
        {
            skipped = true; // no PTY available in this sandbox
            return;
        }
        auto child = spawned.value;

        // Drain the master through the loop until the child's output ends
        // (the master reports EIO once the slave side is gone).
        for (;;)
        {
            SmallBuffer!(ubyte, 128) buf;
            buf.length = 128;
            auto got = read(child.ptyMaster, move(buf));
            buf = move(got.buf);
            if (got.res.hasError || got.res.value == 0)
                break; // EIO / clean EOF: the child is done
            captured ~= cast(const(char)[]) buf[][0 .. got.res.value];
        }

        // Reap in-ring: the fiber parks on WAITID and resumes with the
        // decoded status.
        auto st = wait(sched, child);
        assert(st.hasValue);
        cleanExit = st.value.ok;
        child.ptyMaster.close();
    });
    assert(!r.hasError);
    if (skipped)
    {
        writeln("SKIP: no PTY available");
        return 0;
    }

    // PTYs translate \n to \r\n on output; check the payload lines are there.
    const ok = cleanExit && contains(captured[], "pty-line-1")
        && contains(captured[], "pty-line-2");
    if (ok)
        writefln("ok: drained %d bytes from the PTY, child reaped in-ring", captured.length);
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
