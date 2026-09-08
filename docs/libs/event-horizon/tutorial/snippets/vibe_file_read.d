#!/usr/bin/env dub
/+ dub.sdl:
    name "vibe_file_read"
    dependency "vibe-core" version="2.14.0"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import std.file : remove, tempDir, write;
import std.path : buildPath;
import std.stdio : writeln;
import vibe.core.file : FileMode, openFile;

void main()
{
    const directory = fixtureDirectory();
    scope(exit) { import std.file : rmdir; rmdir(directory); }
    const path = buildPath(directory, "input");
    write(path, "hello from a file\n");
    scope (exit) remove(path);

    auto f = openFile(path, FileMode.read);
    scope (exit) f.close();

    ubyte[128] buf;
    const len = cast(size_t) f.size;
    f.read(buf[0 .. len]);

    assert(len == 18);
    assert(cast(const(char)[]) buf[0 .. len] == "hello from a file\n");
    writeln("read ", len, " bytes: ", cast(const(char)[]) buf[0 .. len]);
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
