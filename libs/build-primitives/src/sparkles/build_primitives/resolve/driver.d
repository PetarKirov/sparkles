/**
The I/O seam of recipe resolution (build-graph SPEC §11): every file read,
directory listing and environment lookup resolution makes goes through a
$(LREF ResolveDriver), so resolution does no other I/O and a test can run it
over an in-memory tree ($(LREF MemoryDriver)).

Paths are absolute and normalized, `/`-separated.
*/
module sparkles.build_primitives.resolve.driver;

/// What resolution asks of the outside world.
interface ResolveDriver
{
    /// The text of the file at `path`; false when there is no such file.
    bool readText(string path, out string text) @safe;

    /// Whether `path` is a directory.
    bool isDirectory(string path) @safe;

    /// Whether `path` is a file, or a directory: anything that exists.
    bool exists(string path) @safe;

    /**
    Every file below `directory`, recursively, as absolute paths, in sorted
    order; directories themselves are not listed. Empty when `directory` is
    no directory.
    */
    string[] filesBelow(string directory) @safe;

    /// The environment variable `name`; false when it is not set.
    bool environment(string name, out string value) @safe;
}

/// A driver over the real file system and process environment.
final class SystemDriver : ResolveDriver
{
    bool readText(string path, out string text) @safe
    {
        import std.file : FileException, readText;

        try
            text = readText(path);
        catch (Exception)
            return false;
        return true;
    }

    bool isDirectory(string path) @safe
    {
        import std.file : exists, isDir;

        try
            return path.exists && path.isDir;
        catch (Exception)
            return false;
    }

    bool exists(string path) @safe
    {
        import std.file : exists;

        return path.exists;
    }

    string[] filesBelow(string directory) @safe
    {
        import std.algorithm.sorting : sort;
        import std.file : SpanMode, dirEntries;

        if (!isDirectory(directory))
            return null;
        string[] files;
        try
            foreach (entry; dirEntries(directory, SpanMode.depth, followSymlink: true))
                if (!entry.isDir)
                    files ~= entry.name;
        catch (Exception)
            return files.sort.release;
        return files.sort.release;
    }

    bool environment(string name, out string value) @safe
    {
        import std.process : environment;

        value = environment.get(name);
        return value !is null;
    }
}

/// A driver over an in-memory tree: a map from absolute file path to text,
/// and a map of environment variables.
final class MemoryDriver : ResolveDriver
{
    string[string] files;       /// absolute path → text
    string[string] variables;   /// environment

    ///
    this(string[string] files, string[string] variables = null) @safe pure nothrow
    {
        this.files = files;
        this.variables = variables;
    }

    bool readText(string path, out string text) @safe
    {
        if (auto found = path in files)
        {
            text = *found;
            return true;
        }
        return false;
    }

    bool isDirectory(string path) @safe
    {
        import std.algorithm.searching : startsWith;

        const prefix = withoutTrailingSlash(path) ~ "/";
        foreach (file; files.byKey)
            if (file.startsWith(prefix))
                return true;
        return false;
    }

    bool exists(string path) @safe
        => (withoutTrailingSlash(path) in files) !is null || isDirectory(path);

    private static string withoutTrailingSlash(string path) @safe pure nothrow @nogc
        => path.length > 1 && path[$ - 1] == '/' ? path[0 .. $ - 1] : path;

    string[] filesBelow(string directory) @safe
    {
        import std.algorithm.searching : startsWith;
        import std.algorithm.sorting : sort;

        string[] found;
        const prefix = directory ~ "/";
        foreach (file; files.byKey)
            if (file.startsWith(prefix))
                found ~= file;
        return found.sort.release;
    }

    bool environment(string name, out string value) @safe
    {
        if (auto found = name in variables)
        {
            value = *found;
            return true;
        }
        return false;
    }
}

@("build_primitives.resolve.driver.MemoryDriver.tree")
@safe unittest
{
    auto driver = new MemoryDriver(["/r/dub.sdl": "name \"r\"", "/r/src/b.d": "", "/r/src/a/c.d": ""],
        ["HOME": "/h"]);
    string text, home;
    assert(driver.readText("/r/dub.sdl", text) && text == "name \"r\"");
    assert(!driver.readText("/r/absent", text));
    assert(driver.isDirectory("/r/src") && !driver.isDirectory("/r/sr"));
    assert(driver.exists("/r/src/b.d") && !driver.isDirectory("/r/src/b.d"));
    assert(driver.filesBelow("/r/src") == ["/r/src/a/c.d", "/r/src/b.d"]);
    assert(driver.environment("HOME", home) && home == "/h" && !driver.environment("X", home));
}
