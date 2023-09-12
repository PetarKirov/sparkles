module sparkles.core_cli.test_utils;

version (unittest):

import std.path : dirName, buildNormalizedPath;

static immutable currentPath = __FILE_FULL_PATH__.dirName;

string readFromTestDir(string filename, string modulePath = __FILE_FULL_PATH__)
in (modulePath[$ - 2 .. $] == ".d")
in (modulePath[0 .. currentPath.length] == currentPath)
{
    import std.file : readText;

    const relativePath = modulePath[currentPath.length + 1 .. $ - 2];

    return currentPath
        .buildNormalizedPath("../../../test/data", relativePath, filename)
        .readText;
}
