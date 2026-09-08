#!/usr/bin/env dub
/+ dub.sdl:
    name "tutorial_vibe_file_read"
    dependency "vibe-core" version="2.14.0"
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.conv : to;
import std.stdio : File, writeln;
import std.exception : enforce;
import vibe.core.file : FileMode, openFile;

void main() @system
{
    auto fixture = File.tmpfile();
    fixture.write("hello from a file\n");
    fixture.flush();
    auto file = openFile("/proc/self/fd/" ~ fixture.fileno.to!string, FileMode.read);
    scope(exit) file.close();
    ubyte[1024] bytes;
    const length = cast(size_t) file.size;
    enforce(length <= bytes.length, "file exceeds the example's bound");
    file.read(bytes[0 .. length]); // Default mode reads the whole requested span.
    writeln("read ", length, " bytes: ", cast(const(char)[]) bytes[0 .. length]);
}
