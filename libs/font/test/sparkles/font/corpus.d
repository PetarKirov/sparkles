/// Access to the bundled fonts (`$SPARKLES_FONTS_PATH`) and the test corpus (`$SPARKLES_FONT_TEST_CORPUS`) for corpus tests.
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

/// `$SPARKLES_FONT_TEST_CORPUS`, faces tested against but not shipped, or null when unset.
string testFontsPath() @safe
{
    return environment.get("SPARKLES_FONT_TEST_CORPUS");
}

/// The bytes of test-corpus font `name`, or null when the corpus is unavailable.
const(ubyte)[] testFace(string name) @trusted
{
    const dir = testFontsPath();
    if (dir is null)
        return null;
    const path = buildPath(dir, name);
    assert(exists(path), "test-corpus font missing: " ~ path);
    return cast(const(ubyte)[]) read(path);
}
