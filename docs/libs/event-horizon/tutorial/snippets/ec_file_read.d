#!/usr/bin/env dub
/+ dub.sdl:
    name "ec_file_read"
    dependency "eventcore" version="0.9.39"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.time : Duration;
import eventcore.core;
import std.file : remove, tempDir, stdWrite = write;
import std.path : buildPath;
import std.stdio : writeln;

void main()
{
    const directory = fixtureDirectory();
    scope(exit) { import std.file : rmdir; rmdir(directory); }
    const path = buildPath(directory, "input");
    stdWrite(path, "hello from a file\n");
    scope (exit) remove(path);

    ubyte[128] buf;
    bool done = false;

    // eventcore offloads open to a worker threadpool
    eventDriver.files.open(path, FileOpenMode.read, (FileFD f, OpenStatus status) nothrow @safe {
        assert(status == OpenStatus.ok);
        assert(f != FileFD.invalid);

        // In eventcore, reading beyond file size yields readPastEOF, so clamp buffer to size:
        const sz = cast(size_t) eventDriver.files.getSize(f);
        assert(sz == 18);

        eventDriver.files.read(f, 0, buf[0 .. sz], IOMode.all, (FileFD file, IOStatus rdStatus, size_t bytesRead) nothrow @safe {
            assert(rdStatus == IOStatus.ok);
            assert(bytesRead == 18);
            assert(cast(const(char)[]) buf[0 .. bytesRead] == "hello from a file\n");

            try writeln("read ", bytesRead, " bytes: ", cast(const(char)[]) buf[0 .. bytesRead]);
            catch (Exception error) { assert(false, error.msg); }

            eventDriver.files.close(file, (FileFD clFile, CloseStatus clStatus) nothrow @safe {
                assert(clStatus == CloseStatus.ok);
                eventDriver.files.releaseRef(clFile);
                done = true;
            });
        });
    });

    while (!done && eventDriver.core.waiterCount > 0)
        eventDriver.core.processEvents(Duration.max);

    assert(done);
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
