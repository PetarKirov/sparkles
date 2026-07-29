/**
Test-only helper: reads a golden file for the calling module.

Goldens live under `libs/ui/test/data/<module-path>/<filename>`, mirroring the
source tree — so `sparkles.ui.components.box`'s goldens are in
`test/data/components/box/`. Keeping the layout mechanical means a moved module
takes its goldens with it and nothing has to be re-pointed by hand.
*/
module sparkles.ui.test_utils;

version (unittest):

import std.path : buildNormalizedPath, dirName;

private static immutable currentPath = __FILE_FULL_PATH__.dirName;

/// Reads `filename` from the golden directory belonging to the calling module.
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
