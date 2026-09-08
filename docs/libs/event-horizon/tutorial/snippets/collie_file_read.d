#!/usr/bin/env dub
/+ dub.sdl:
    name "collie_file_read"
    dependency "collie" path=".deps/collie"
    dependency "kiss" path=".deps/kiss"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.thread : Thread;
import std.file : remove, tempDir, write, read;
import std.path : buildPath;
import std.stdio : writeln;
import kiss.event;
import kiss.event.task : newTask;

void main()
{
    const directory = fixtureDirectory();
    scope(exit) { import std.file : rmdir; rmdir(directory); }
    const path = buildPath(directory, "input");
    write(path, "hello from a file\n");
    scope (exit) remove(path);

    auto loop = new EventLoop();
    scope(exit) loop.dispose();
    string content;

    // Collie has no async filesystem I/O: epoll cannot poll regular files.
    // Applications must delegate disk I/O to a worker thread and post back.
    auto worker = new Thread({
        auto data = cast(string) read(path);
        loop.postTask(newTask({
            content = data;
            writeln("read ", content.length, " bytes: ", content);
            loop.stop();
        }));
    });
    worker.start();

    loop.run();
    worker.join();

    assert(content == "hello from a file\n");
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
