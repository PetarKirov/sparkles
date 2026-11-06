/** The repository's recipes as a test corpus, for the editing property tests
(editing SDE1, SDE2, SDE11, SDE14).

Every function is a template, so nothing here is compiled into a build that
does not call it.
*/
module sparkles.wired.sdl.test_corpus;

/// Every `dub.sdl` and every embedded recipe under `apps`, `libs` and `docs`.
package string[] repositoryRecipes()()
{
    import sparkles.wired.sdl.embedded : hasEmbeddedRecipeHeader;
    import std.algorithm.comparison : among;
    import std.algorithm.searching : canFind;
    import std.file : dirEntries, exists, readText, SpanMode;
    import std.path : baseName, buildNormalizedPath, dirName, extension, pathSplitter;

    const root = buildNormalizedPath(__FILE_FULL_PATH__.dirName, "../../../../../..");
    string[] paths;
    foreach (top; ["apps", "libs", "docs"])
    {
        const dir = buildNormalizedPath(root, top);
        if (!dir.exists)
            continue;
        foreach (entry; dirEntries(dir, SpanMode.depth))
        {
            // Components, not `/`-joined text: Windows separates with `\`.
            const path = entry.name;
            if (!entry.isFile
                || path.pathSplitter.canFind!(part => part.among(".dub", "node_modules", "build")))
                continue;
            if (path.baseName == "dub.sdl"
                || (path.extension == ".d" && hasEmbeddedRecipeHeader(readText(path))))
                paths ~= path;
        }
    }
    return paths;
}

/// Parses a recipe file, or the recipe a `.d` file embeds.
package auto parseRecipe()(scope const(char)[] text, string path)
{
    import core.lifetime : move;
    import sparkles.wired.sdl.config : sdlDubRecipe;
    import sparkles.wired.sdl.embedded : parseEmbeddedSdlDocument;
    import sparkles.wired.sdl.reader : parseSdlDocument;

    if (path[$ - 2 .. $] != ".d")
        return parseSdlDocument!sdlDubRecipe(text, path);
    auto embedded = parseEmbeddedSdlDocument!sdlDubRecipe(text, path);
    return move(embedded.parsed);
}
