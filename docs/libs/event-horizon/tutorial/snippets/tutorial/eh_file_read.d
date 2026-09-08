#!/usr/bin/env dub
/+ dub.sdl:
    name "tutorial_eh_file_read"
    dependency "sparkles:event-horizon" path="../../../../../.."
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.conv : to;
import std.stdio : File, writeln, stderr;
import expected : andThen;
import sparkles.event_horizon : runApplication, RootScope, Env, ioOk;

int main() @system
{
    // An anonymous temporary file keeps this Linux example self-contained.
    auto fixture = File.tmpfile();
    fixture.write("hello from a file\n");
    fixture.flush();
    auto path = "/proc/self/fd/" ~ fixture.fileno.to!string;

    auto result = runApplication((ref RootScope root, ref Env env) {
        return env.fs.readText(path, 1024).andThen!((text) {
            writeln("read ", text.length, " bytes: ", text);
            return ioOk();
        });
    });
    if (result.hasError) stderr.writeln(result.error);
    return result.hasError ? 1 : 0;
}
