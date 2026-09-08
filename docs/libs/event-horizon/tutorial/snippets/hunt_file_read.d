#!/usr/bin/env dub
/+ dub.sdl:
    name "hunt_file_read"
    dependency "hunt-net" version="0.7.1"
    dependency "hunt" path=".deps/hunt"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import std.stdio : File, writeln;
import std.file : write, remove, tempDir;
import std.path : buildPath;
import core.stdc.stdlib : exit;
import std.parallelism : task, taskPool;

void main()
{
    stopStartupClock();
    runWorker({
        const directory = fixtureDirectory();
        scope(exit) { import std.file : rmdir; rmdir(directory); }
        const path = buildPath(directory, "input");
        write(path, "hello from a file\n");
        scope (exit) remove(path);

        // hunt has no async file channel because epoll cannot poll regular files.
        // In hunt applications, file I/O must either block the event loop or be
        // delegated to an OS worker threadpool (taskPool).
        auto readTask = task({
            auto f = File(path, "r");
            char[128] buf;
            auto slice = f.rawRead(buf[]);
            return slice.idup;
    });

    taskPool.put(readTask);
    string content = readTask.yieldForce();

    assert(content == "hello from a file\n");
    writeln("read ", content.length, " bytes: ", content);
    });
}

// A fresh directory prevents interference between parallel tutorial runs.
string fixtureDirectory() @trusted
{
    import core.sys.posix.stdlib : mkdtemp;
    import std.string : fromStringz;
    auto pattern = (buildPath(tempDir(), "eh-comparison-XXXXXX") ~ '\0').dup;
    auto created = mkdtemp(pattern.ptr);
    assert(created !is null);
    return fromStringz(created).idup;
}

void runWorker(void delegate() work)
{
    import hunt.util.worker.Task : Task;
    import core.thread : Thread;
    auto job = new class Task {
        override protected void doExecute() { work(); }
    };
    auto thread = new Thread(&job.execute);
    thread.start();
    thread.join();
    assert(job.isDone());
}

// Standalone-process workaround for the pinned Hunt DateTime daemon: its
// destructor stops but does not join. Join before creating application threads.
void stopStartupClock()
{
    import core.thread : Thread;
    import hunt.util.DateTime : DateTime;
    auto startupThreads = Thread.getAll();
    assert(startupThreads.length <= 2, "review startup ownership if dependencies change");
    DateTime.stopClock();
    foreach (thread; startupThreads)
        if (thread !is Thread.getThis())
        {
            assert(thread.isDaemon);
            thread.join();
        }
}
