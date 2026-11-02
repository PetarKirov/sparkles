/**
 * The source roots of the in-binary packages, as the compiler saw them when
 * it built this binary. The runner's compile-time and extracted modes import
 * these, never its own pinned copies (process-model TRX4).
 */
module sparkles.test_runner.roots;

import sparkles.test_runner.attributes : attributesSourcePath;

/// The directory that holds `sparkles/test_runner/attributes.d`.
enum string attributesRoot = rootOf(attributesSourcePath, "sparkles/test_runner/attributes.d");

/// The directory that holds this module's package.
enum string harnessRoot = rootOf(__FILE_FULL_PATH__, "sparkles/test_runner/roots.d");

/// `path` without its trailing `tail` and the separator before it, or `"."`
/// when nothing is left.
private string rootOf(string path, string tail) @safe pure nothrow
{
    // Either separator: the compiler reports Windows paths with `\`.
    size_t i = path.length, j = tail.length;
    while (i && j)
    {
        const a = path[i - 1], b = tail[j - 1];
        if (a != b && !(b == '/' && a == '\\'))
            return path;
        --i;
        --j;
    }
    if (j)
        return path;
    while (i && (path[i - 1] == '/' || path[i - 1] == '\\'))
        --i;
    return i ? path[0 .. i] : ".";
}

@("roots.rootOf")
@safe pure nothrow
unittest
{
    assert(rootOf("/r/libs/x/src/sparkles/test_runner/a.d", "sparkles/test_runner/a.d")
        == "/r/libs/x/src");
    assert(rootOf(`C:\r\src\sparkles\test_runner\a.d`, "sparkles/test_runner/a.d") == `C:\r\src`);
    assert(rootOf("sparkles/test_runner/a.d", "sparkles/test_runner/a.d") == ".");
    assert(rootOf("libs/x/src/other.d", "sparkles/test_runner/a.d") == "libs/x/src/other.d");
}
