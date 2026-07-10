#!/usr/bin/env dub
/+ dub.sdl:
    name "event_horizon_agent_tooling"
    dependency "sparkles:event-horizon" path="../../.."
    platforms "linux"
    targetPath "build"
+/
/**
 * The M7 gate: the IDE/agent-tooling primitives working together, direct
 * style, on one ring — run a subprocess, stream its output, watch a
 * directory for the file it writes, then read that file back — every wait a
 * fiber park on a CQE:
 *
 *   1. `Watcher` arms an inotify watch on a fresh temp directory.
 *   2. `spawnProcess` runs `sh -c` that prints to stdout and writes a file
 *      into the watched directory.
 *   3. Three concerns interleave as fibers: streaming the child's stdout
 *      (ring reads on the pipe), awaiting the watch event (ring read on the
 *      inotify fd), and reaping the child (in-ring `WAITID`).
 *   4. The watched file is opened, stat'ed, and read back through the ring.
 *
 * Run with: `dub run --single agent-tooling.d`
 *
 * Portability: prints a `SKIP:` line and exits 0 if `io_uring` is
 * unavailable, so it stays green in CI regardless of host kernel.
 */
module event_horizon_agent_tooling;

import core.lifetime : move;
import core.sys.linux.sys.inotify : IN_CLOSE_WRITE;
import core.sys.posix.fcntl : O_RDONLY;

import std.conv : octal;
import std.stdio : writefln;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.event_horizon.fs;
import sparkles.event_horizon.io : read;
import sparkles.event_horizon.proc;
import sparkles.event_horizon.sched : Sched;
import sparkles.event_horizon.watch;

enum dir = "/tmp/sparkles-agent-tooling-demo";

int main()
{
    Sched sched;
    auto created = Sched.create(sched);
    if (created.hasError)
    {
        writefln("SKIP: io_uring unavailable (errno %d) — %s",
            created.error.errnoValue, created.error.context);
        return 0;
    }
    scope (exit) sched.destroy();

    (() @trusted {
        import core.sys.posix.sys.stat : mkdir;

        mkdir(dir ~ "\0", octal!700);
    })();
    scope (exit) () @trusted {
        import core.stdc.stdio : remove;
        import core.sys.posix.unistd : rmdir;

        remove(dir ~ "/result.txt\0");
        rmdir(dir ~ "\0");
    }();

    Watcher watcher;
    assert(!Watcher.create(watcher).hasError);
    scope (exit) watcher.close();
    assert(watcher.addWatch(dir, IN_CLOSE_WRITE).hasValue);

    SmallBuffer!(char, 256) streamed;
    bool sawEvent;
    int exitCode = -1;

    auto r = sched.run(() {
        // The tool under supervision: talks on stdout, then drops a file
        // into the watched directory.
        auto spawned = spawnProcess(["sh", "-c",
            "echo tool starting; echo 41+1 > " ~ dir ~ "/result.txt; echo tool done"]);
        assert(spawned.hasValue);
        auto child = spawned.value;

        // Fiber 1: stream the child's stdout through the ring until EOF.
        cast(void) sched.spawn(() {
            SmallBuffer!(ubyte, 128) buf;
            for (;;)
            {
                buf.length = 128;
                auto got = read(child.stdout_, move(buf));
                buf = move(got.buf);
                if (got.res.hasError || got.res.value == 0)
                    break;
                streamed ~= cast(const(char)[]) buf[][0 .. got.res.value];
            }
        });

        // Fiber 2: park on the watch until the tool's file lands.
        cast(void) sched.spawn(() {
            auto ev = watcher.nextEvent(sched);
            assert(ev.hasValue);
            sawEvent = (ev.value.mask & IN_CLOSE_WRITE) != 0
                && ev.value.name == "result.txt";
        });

        // The root fiber: reap the child (in-ring WAITID), then read the
        // artifact back through the ring.
        auto code = wait(sched, child);
        assert(code.hasValue);
        exitCode = code.value;
        child.stdout_.close();

        auto f = openFile(sched, dir ~ "/result.txt", O_RDONLY);
        assert(f.hasValue);
        auto handle = f.value;
        Statx st;
        assert(!statxPath(sched, dir ~ "/result.txt", st).hasError);
        SmallBuffer!(ubyte, 64) content;
        content.length = 64;
        auto got = read(handle, move(content), 0);
        assert(!got.res.hasError && got.res.value == st.stx_size);
        assert(got.buf[][0 .. got.res.value] == cast(const(ubyte)[]) "41+1\n");
        assert(!closeFile(sched, handle).hasError);
    });
    assert(!r.hasError);

    assert(exitCode == 0, "the tool must exit cleanly");
    assert(sawEvent, "the watch must observe the artifact");
    assert(streamed[] == "tool starting\ntool done\n", "stdout fully streamed");

    writefln("ok: subprocess streamed + reaped, artifact watched and read back (exit %d)",
        exitCode);
    return 0;
}
