#!/usr/bin/env dub
/+ dub.sdl:
    name "libasync_file_read"
    dependency "libasync" version="0.9.8"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import std.file : remove, tempDir, write;
import std.path : buildPath;
import std.stdio : writeln;
import libasync;

void main()
{
    const directory = fixtureDirectory();
    scope(exit) { import std.file : rmdir; rmdir(directory); }
    const path = buildPath(directory, "input");
    write(path, "hello from a file\n");
    scope (exit) remove(path);

    auto evl = new EventLoop;
    scope (exit) { evl.exit(); evl.destroy(); }

    auto file = new shared AsyncFile(evl);
    bool done = false;
    size_t bytesRead = 0;
    string content;

    file.onReady({
        auto buf = cast(ubyte[]) file.buffer;
        bytesRead = buf.length;
        content = cast(string) buf.idup;
        done = true;
        file.kill();
    }).read(path, 18);

    while (!done)
        evl.loop();

    assert(bytesRead == 18);
    assert(content == "hello from a file\n");
    writeln("read ", bytesRead, " bytes: ", content);
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
