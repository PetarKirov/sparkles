/**
The repository-wide tests of $(MREF sparkles, build_primitives, dub_manifest):
every recipe this repository tracks decodes, formats and round-trips. They
list the tracked recipes with `git ls-files` through `runGit`, which lives in
this package, so they stay here while the schema lives in
`sparkles:dub-manifest`. The module holds tests only.
*/
module sparkles.build_primitives.dub_manifest_corpus;

import std.conv : text;

import sparkles.build_primitives.dub_manifest;
import sparkles.wired.sdl : sdlDubRecipe;

@("build_primitives.dub_manifest.readDubManifest.everyRecipeInThisRepository")
@system unittest
{
    import std.algorithm.searching : endsWith;
    import std.file : exists, readText;
    import std.path : buildNormalizedPath, dirName;
    import std.string : lineSplitter;
    import sparkles.build_primitives.git_env : runGit;
    import sparkles.test_runner.skip : skipTest;

    // Every tracked recipe, standalone or embedded in a single-file package,
    // must decode: a reader that met a failure would see a package with no
    // name, subpackages, or platform restriction.
    const root = __FILE_FULL_PATH__.dirName.buildNormalizedPath("..", "..", "..", "..", "..");
    const listed = runGit(["ls-files", "*dub.sdl", "*.d"], root);
    if (listed.status != 0)
        return skipTest("not a git checkout: " ~ root);

    size_t recipes;
    foreach (file; listed.output.lineSplitter)
    {
        const path = root.buildNormalizedPath(file);
        if (!path.exists)
            continue;
        if (path.endsWith(".d"))
        {
            import sparkles.wired.sdl : locateEmbeddedRecipe;

            const embedded = locateEmbeddedRecipe(path.readText);
            if (!embedded.found || embedded.isJson)
                continue;
        }
        const manifest = readDubManifest(path);
        assert(manifest.hasValue, manifest.error.text);
        ++recipes;
    }
    assert(recipes > 100);
}

version (unittest)
{
    /// Every recipe in this repository — `dub.sdl` files and the recipes
    /// single-file packages embed — with its path and text.
    private string[2][] repositoryRecipes()
    {
        import std.algorithm.searching : endsWith;
        import std.file : exists, readText;
        import std.path : buildNormalizedPath, dirName;
        import std.string : lineSplitter;
        import sparkles.build_primitives.git_env : runGit;
        import sparkles.wired.sdl : locateEmbeddedRecipe;

        const root = __FILE_FULL_PATH__.dirName.buildNormalizedPath("..", "..", "..", "..", "..");
        const listed = runGit(["ls-files", "*dub.sdl", "*.d"], root);
        string[2][] recipes;
        if (listed.status != 0)
            return recipes;
        foreach (file; listed.output.lineSplitter)
        {
            const path = root.buildNormalizedPath(file);
            if (!path.exists)
                continue;
            const text = path.readText;
            if (path.endsWith(".d"))
            {
                const embedded = locateEmbeddedRecipe(text);
                if (!embedded.found || embedded.isJson)
                    continue;
            }
            recipes ~= [path, text];
        }
        return recipes;
    }

    /// The recipe's document: its own, or the one a `.d` host embeds.
    private auto parseRecipe(string path, string text)
    {
        import core.lifetime : move;
        import std.algorithm.searching : endsWith;
        import sparkles.wired.sdl : parseEmbeddedSdlDocument, parseSdlDocument, sdlDubRecipe;

        if (!path.endsWith(".d"))
            return parseSdlDocument!sdlDubRecipe(text, path);
        auto embedded = parseEmbeddedSdlDocument!sdlDubRecipe(text, path);
        return move(embedded.parsed);
    }
}

@("build_primitives.dub_manifest.roundTrip.format")
@system unittest
{
    import sparkles.test_runner.skip : skipTest;
    import sparkles.wired.sdl : fromSDL, parseSdlDocument, SdlString, toSDL, writeSdlDocument;

    // The canonical writer is a formatter: what it writes parses to the same
    // tree, and writing that again changes nothing. Typed, `toSDL` of a
    // decoded recipe decodes to the same value, and is stable.
    const recipes = repositoryRecipes();
    if (recipes.length == 0)
        return skipTest("not a git checkout");
    foreach (recipe; recipes)
    {
        auto parsed = parseRecipe(recipe[0], recipe[1]);
        assert(parsed.hasValue, parsed.error.text);

        SdlString once, twice;
        assert(!writeSdlDocument(parsed.document, once).hasError, recipe[0]);
        auto formatted = parseSdlDocument!sdlDubRecipe(once[]);
        assert(formatted.hasValue, recipe[0] ~ ": " ~ formatted.error.text);
        assert(!writeSdlDocument(formatted.document, twice).hasError);
        assert(once[] == twice[], recipe[0] ~ ": the formatter is not idempotent");

        const value = fromSDL!DubManifest(parsed.document.root);
        assert(value.hasValue, value.error.text);
        const encoded = toSDL(value.value);
        assert(encoded.hasValue, recipe[0] ~ ": " ~ encoded.error.text);
        const decoded = parseDubManifest(encoded.value[]);
        assert(decoded.hasValue, recipe[0] ~ ": " ~ decoded.error.text);
        assert(decoded.value == value.value, recipe[0] ~ ": toSDL does not round-trip");
        assert(toSDL(decoded.value).value[] == encoded.value[], recipe[0]);
    }
}

@("build_primitives.dub_manifest.roundTrip.lossless")
@system unittest
{
    import std.algorithm.searching : canFind;
    import std.experimental.allocator.mallocator : Mallocator;
    import sparkles.base.buffer : UniqueBuffer;
    import sparkles.test_runner.skip : skipTest;
    import sparkles.wired.sdl : fromSDL, sdlDubRecipe, sdlEditor, updateSDL;

    // The lossless editor writes back exactly the bytes it read: with no
    // edit, and with the unchanged decoded value. A changed value decodes as
    // the change, and keeps every comment outside what it removed.
    const recipes = repositoryRecipes();
    if (recipes.length == 0)
        return skipTest("not a git checkout");
    size_t changed;
    foreach (recipe; recipes)
    {
        const host = recipe[1];
        auto parsed = parseRecipe(recipe[0], host);
        assert(parsed.hasValue, parsed.error.text);
        const decoded = fromSDL!DubManifest(parsed.document.root);
        assert(decoded.hasValue, decoded.error.text);

        string writeBack(scope void delegate(ref typeof(sdlEditor!sdlDubRecipe(parsed.document, host)))
            edit)
        {
            auto editor = sdlEditor!sdlDubRecipe(parsed.document, host);
            edit(editor);
            UniqueBuffer!char output;
            Mallocator allocator;
            const written = editor.write(output, allocator);
            assert(!written.hasError, recipe[0] ~ ": " ~ written.error.text);
            return output[].idup;
        }

        assert(writeBack((ref editor) {}) == host, recipe[0]);
        DubManifest same = cast() decoded.value;
        assert(writeBack((ref editor) => updateSDL(editor, parsed.document.root, same)) == host,
            recipe[0] ~ ": writing back the unchanged value edited it");

        // Where the comment-only lines directly above `start` begin: the
        // editor removes them with the node they describe.
        size_t attachedStart(size_t start)
        {
            import std.string : strip;

            for (;;)
            {
                size_t line = start;
                while (line > 0 && host[line - 1] != '\n')
                    line--;
                if (line == 0)
                    return start;
                size_t above = line - 1;
                while (above > 0 && host[above - 1] != '\n')
                    above--;
                const text = host[above .. line - 1].strip;
                bool commentOnly;
                foreach (comment; parsed.document.comments)
                    commentOnly |= text.length && comment.span.sliceOf(host).strip == text;
                if (!commentOnly)
                    return start;
                start = above;
            }
        }

        // The first configuration removed and a dependency inserted first:
        // a positional pairing would rewrite every element after them.
        DubManifest other = cast() decoded.value;
        other.description = "changed by the round-trip test";
        other.dependencies = DubDependency("sparkles:probe", version_: "*") ~ other.dependencies;
        size_t removedStart = size_t.max, removedEnd;
        const(char)[][] keptConfigurations;
        if (other.configurations.length)
        {
            other.configurations = other.configurations[1 .. $];
            foreach (node; parsed.document.root.byChild)
                if (node.qualifiedName.localName == "configuration")
                {
                    if (removedStart == size_t.max)
                    {
                        removedStart = attachedStart(node.extent.startOffset);
                        removedEnd = node.extent.endOffset;
                    }
                    else
                        keptConfigurations ~= node.extent.sliceOf(host);
                }
        }
        const output = writeBack((ref editor) => updateSDL(editor, parsed.document.root, other));
        auto reparsed = parseRecipe(recipe[0], output);
        assert(reparsed.hasValue, recipe[0] ~ ": " ~ reparsed.error.text);
        const back = fromSDL!DubManifest(reparsed.document.root);
        assert(back.hasValue && back.value == other, recipe[0] ~ ": the change did not round-trip");
        foreach (comment; parsed.document.comments)
            if (comment.span.startOffset < removedStart || comment.span.startOffset >= removedEnd)
                assert(output.canFind(comment.span.sliceOf(host)), recipe[0] ~ ": lost a comment");
        // Every other configuration keeps its bytes (S20).
        foreach (kept; keptConfigurations)
            assert(output.canFind(kept), recipe[0] ~ ": rewrote an unchanged configuration");
        changed++;
    }
    assert(changed > 100);
}
