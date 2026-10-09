#!/usr/bin/env dub
/+ dub.sdl:
    name "tutorial_eh_file_read"
    dependency "sparkles:event-horizon" path="../../../../../.."
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.file : remove, tempDir, write;
import std.path : buildPath;
import std.process : thisProcessID;
import std.conv : to;
import std.stdio : writeln, stderr;
import expected : andThen;
import sparkles.base.vfs : OpenMode, Rights, ambientAuthority, openRoot;
import sparkles.event_horizon : runApplication, RootScope, Env, ioErr, ioOk, readText;

int main() @system
{
    const name = "eh-tutorial-" ~ thisProcessID.to!string ~ ".txt";
    write(buildPath(tempDir, name), "hello from a file\n");
    scope (exit) remove(buildPath(tempDir, name));

    auto result = runApplication((ref RootScope root, ref Env env) {
        // `env.fs` opens a directory as a capability; the file is named in it.
        auto dir = openRoot!(Rights.readOnly)(&env.fs(), tempDir, ambientAuthority());
        if (dir.hasError)
            return ioErr!void(dir);
        auto file = dir.value.openFile!(OpenMode.read)(name);
        if (file.hasError)
            return ioErr!void(file);
        return readText(file.value, 1024).andThen!((text) {
            writeln("read ", text.length, " bytes: ", text);
            return ioOk();
        });
    });
    if (result.hasError) stderr.writeln(result.error);
    return result.hasError ? 1 : 0;
}
