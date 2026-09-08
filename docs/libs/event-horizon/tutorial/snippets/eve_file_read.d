#!/usr/bin/env dub
/+ dub.sdl:
    name "eve_file_read"
    dependency "eve" repository="git+https://codeberg.org/ddn/eve.git" version="c72f75135de636987e91bcd8ec5a22d32d34a197"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.sys.posix.fcntl : O_RDONLY;
import std.file : remove, tempDir, write;
import std.path : buildPath;
import std.stdio : writeln;
import eve;

void main() @safe
{
    const directory = fixtureDirectory();
    scope(exit) { import std.file : rmdir; rmdir(directory); }
    const path = buildPath(directory, "input");
    write(path, "hello from a file\n");
    scope (exit) remove(path);

    auto loop = EventLoop.create();
    scope (exit) loop.dispose();

    auto file = AsyncFile.create();
    scope (exit) file.dispose();

    assert(file.open(loop, path, O_RDONLY) == OpenResult.OK);

    ubyte[128] buffer;
    size_t bytesRead = 0;
    string text;

    file.onRead = (ref AsyncFile f, ubyte[] data, int error) @safe {
        if (error == 0 && data !is null)
        {
            bytesRead = data.length;
            text = cast(string) data.idup; // borrowed slice
            try {
                writeln("read ", bytesRead, " bytes: ", text[0 .. $ - 1]);
            } catch (Exception error) { assert(false, error.msg); }
        }
        f.close();
        loop.stop();
    };

    assert(file.read(buffer[], 0) == FileResult.PENDING);

    loop.run();
    assert(bytesRead == 18);
    assert(text == "hello from a file\n");
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
