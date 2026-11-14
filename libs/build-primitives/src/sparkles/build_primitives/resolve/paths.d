/**
The paths of recipe resolution: absolute, normalized and `/`-separated on
every host (see $(REF ResolveDriver, sparkles,build_primitives,resolve,driver)).

`std.path` builds a path with the host's separator, `\` on Windows, and
there calls a path absolute only with a drive. These wrap it so that what
resolution builds keeps the one separator, and a rooted path such as `/r`
counts as absolute: on Windows it names the root of the current drive.
*/
module sparkles.build_primitives.resolve.paths;

/// `path` with every separator `/`. A no-op where `/` is the only one.
string modelPath(string path) @safe pure nothrow
{
    version (Windows)
    {
        import std.array : replace;

        return path.replace('\\', '/');
    }
    else
        return path;
}

/// `std.path.buildNormalizedPath` of `parts`, `/`-separated.
string normalizedPath(const(char)[][] parts...) @safe pure nothrow
{
    import std.path : buildNormalizedPath;

    return modelPath(buildNormalizedPath(parts));
}

/// `std.path.buildPath` of `parts`, `/`-separated.
string joinedPath(const(char)[][] parts...) @safe pure nothrow
{
    import std.path : buildPath;

    return modelPath(buildPath(parts));
}

/// Whether `path` starts at a root: `/…` everywhere, and on Windows also a
/// drive's root (`C:/…`, `C:\…`) or a UNC path.
bool isAbsolutePath(scope const(char)[] path) @safe pure nothrow @nogc
{
    version (Windows)
    {
        import std.path : isRooted;

        return isRooted(path);
    }
    else
    {
        import std.path : isAbsolute;

        return isAbsolute(path);
    }
}

/**
`path` relative to the directory `base`, `/`-separated: `.` when they are
the same, with `..` for each step `base` has beyond what they share. Both
are absolute and normalized; a relative `path` is returned as it is.
*/
string relativePathTo(string path, string base) @safe pure nothrow
{
    import std.array : join;
    import std.path : filenameCmp, pathSplitter;

    if (!isAbsolutePath(path))
        return path;
    auto p = pathSplitter(path), b = pathSplitter(base);
    while (!p.empty && !b.empty && filenameCmp(p.front, b.front) == 0)
    {
        p.popFront;
        b.popFront;
    }
    string[] steps;
    for (; !b.empty; b.popFront)
        steps ~= "..";
    for (; !p.empty; p.popFront)
        steps ~= p.front;
    return steps.length ? steps.join("/") : ".";
}

///
@("build_primitives.resolve.paths.forms")
@safe pure nothrow unittest
{
    assert(normalizedPath("/r", "a/../b", "c.d") == "/r/b/c.d");
    assert(normalizedPath("/r/", "/s") == "/s");
    assert(joinedPath("/s", ".dub", "packages") == "/s/.dub/packages");
    assert(isAbsolutePath("/r") && !isAbsolutePath("r") && !isAbsolutePath("./r"));
    assert(relativePathTo("/p/src/a.d", "/p") == "src/a.d");
    assert(relativePathTo("/p", "/p") == ".");
    assert(relativePathTo("/p/x/a.d", "/p/src") == "../x/a.d");
    assert(relativePathTo("/a.d", "/p/src") == "../../a.d");
    assert(relativePathTo("a.d", "/p") == "a.d");
    version (Windows)
    {
        assert(normalizedPath(`C:\r`, `a\b.d`) == "C:/r/a/b.d");
        assert(isAbsolutePath(`C:\r`) && isAbsolutePath("C:/r") && !isAbsolutePath("C:r"));
        assert(relativePathTo("C:/p/src/a.d", "C:/p") == "src/a.d");
    }
}

/// The relative path agrees with `std.path.relativePath` where that one
/// applies, on a POSIX host.
version (Posix)
@("build_primitives.resolve.paths.relativeAgreesWithPhobos")
@safe pure unittest
{
    import std.path : relativePath;

    foreach (pair; [["/p/src/a.d", "/p"], ["/p", "/p"], ["/p/x/a.d", "/p/src"],
        ["/a.d", "/p/src"], ["/", "/p"], ["/p/q", "/"]])
        assert(relativePathTo(pair[0], pair[1]) == relativePath(pair[0], pair[1]), pair[0]);
}
