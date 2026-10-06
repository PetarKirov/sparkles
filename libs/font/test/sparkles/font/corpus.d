/// Access to the bundled fonts for corpus tests (`$SPARKLES_FONTS_PATH`).
module sparkles.font.corpus;

import std.file : exists, read;
import std.path : buildPath;
import std.process : environment;

/// The bundled font directory, or null when the variable is unset.
string fontsPath() @safe
{
    return environment.get("SPARKLES_FONTS_PATH");
}

/// The bytes of bundled font `name`, or null when the corpus is unavailable.
const(ubyte)[] bundled(string name) @trusted
{
    const dir = fontsPath();
    if (dir is null)
        return null;
    const path = buildPath(dir, name);
    assert(exists(path), "bundled font missing: " ~ path);
    return cast(const(ubyte)[]) read(path);
}
