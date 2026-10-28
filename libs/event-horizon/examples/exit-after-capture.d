#!/usr/bin/env dub
/+ dub.sdl:
    name "event_horizon_exit_after_capture"
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
A program that captures a child's output and then exits, in the schedule
that once crashed it at exit: `capture` starts the shared blocking pool, and
the pool's workers outlived `main`. The runtime's last collection suspends
every live thread and resumes them without waiting, then unmaps the GC heap;
a worker still leaving the suspend handler reads its `Thread`, GC memory, and
faults. Here every thread shares one CPU and the workers are `SCHED_IDLE`, so
the main thread always reaches the unmap first, and then blocks at C exit, as
a flush into a full pipe would: a worker left alive runs into the unmapped
heap. The program exits 0 only if no worker is left by then.
*/
module exit_after_capture;

import core.stdc.stdio : printf;
import core.stdc.stdlib : atexit, atoi;
import core.sys.linux.sched : CPU_ISSET, CPU_SET, cpu_set_t, sched_getaffinity,
    sched_setaffinity;
import core.sys.posix.dirent : closedir, opendir, readdir;
import core.sys.posix.sched : sched_param, sched_setscheduler;
import core.sys.posix.time : nanosleep, timespec;
import core.sys.posix.unistd : getpid;

import sparkles.event_horizon;

/// `SCHED_IDLE`, which druntime's bindings do not name.
private enum int schedIdle = 5;

/// Every thread of the process on one CPU it may use, and all but the calling one idle.
private void starveOtherThreads() @trusted
{
    cpu_set_t allowed, one;
    assert(sched_getaffinity(0, cpu_set_t.sizeof, &allowed) == 0);
    size_t cpu;
    while (!CPU_ISSET(cpu, &allowed))
        ++cpu;
    CPU_SET(cpu, &one);
    const self = getpid();
    auto dir = opendir("/proc/self/task");
    assert(dir !is null);
    scope (exit) closedir(dir);
    for (auto e = readdir(dir); e !is null; e = readdir(dir))
    {
        const tid = atoi(e.d_name.ptr);
        if (tid <= 0)
            continue;
        assert(sched_setaffinity(tid, cpu_set_t.sizeof, &one) == 0);
        sched_param idle;
        if (tid != self)
            assert(sched_setscheduler(tid, schedIdle, &idle) == 0);
    }
}

/// Runs after the runtime has terminated: the main thread sleeps, so idle threads run.
extern (C) void sleepAtExit() nothrow @nogc
{
    timespec t = {tv_sec: 0, tv_nsec: 200_000_000};
    nanosleep(&t, null);
}

void main()
{
    LoopGroup group;
    if (LoopGroup.start(group).hasError)
        assert(false, "no completion backend");

    const ran = group.run((ref RootScope sc, ref Env env) {
        auto got = capture(currentScheduler(), ["sh", "-c", "echo out"]);
        assert(got.hasValue && got.value.status.code == 0);
        return 0;
    });
    assert(ran.hasValue);
    group.shutdown();

    starveOtherThreads();
    atexit(&sleepAtExit);
    printf("captured; exiting\n");
}
