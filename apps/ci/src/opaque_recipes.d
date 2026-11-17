/++
`ci check opaque-recipes`: the recipe entries no input set can hold
([design](../../../docs/specs/build-primitives/build-graph/fileset-native-workspace.md)
BGW3, BGW4), each with what it costs and what to write instead.

An opaque entry is a command, a flag that carries a path, or a path through a
variable or outside the repository. What it reads is not stated, so every
request that builds its configuration is uncertain: `--since` selects it on
every change, and a watch reruns it on every event. The check reports each
on every host this repository builds on (Linux, macOS, Windows), and fails
on one that `apps/ci/opaque-recipe-allowlist.txt` does not list with a
reason, so a new one is a decision, not an accident.
+/
module opaque_recipes;

import sparkles.build_primitives.workspace.input_sets : OpaqueDirective;
import sparkles.build_primitives.workspace.package_graph : SubPackageRecipe;

/// The platform tokens of the hosts this repository builds on.
static immutable string[][] repositoryHosts = [["linux", "posix"], ["osx", "darwin", "posix"], ["windows"]];

/// One opaque entry, as the allowlist names it and as the diagnostic says it.
struct OpaqueEntry
{
    string recipe;     /// `libs/profiling/dub.sdl`; `workspace inputs` for a stated pattern
    string entry;      /// `lflags "-L$SPARKLES_TRACY_PREFIX/lib"`
    string diagnostic; /// `writeOpaqueDiagnostic`'s line, for the first configuration found
}

/**
The opaque entries of `recipes` on every host of `hosts`, each recipe and
entry once (an entry in several configurations, or on several hosts, is one
decision), in recipe, then entry order.
*/
OpaqueEntry[] opaqueEntries(string rootName, scope const(SubPackageRecipe)[] recipes, scope const(string[])[] hosts)
    @safe
{
    import std.algorithm.sorting : sort;
    import std.array : appender;
    import sparkles.build_primitives.workspace.input_sets : inputSets, WorkspaceInputs, writeOpaqueDiagnostic;
    import sparkles.build_primitives.workspace.package_graph : buildPackageGraph, RecipeRole;

    OpaqueEntry[] entries;
    foreach (host; hosts)
    {
        auto graph = buildPackageGraph(rootName, recipes, RecipeRole.build, host);
        if (graph.hasError)
            continue;
        auto sets = inputSets(graph.value, recipes, host, WorkspaceInputs.init);
        foreach (ref o; sets.opaque)
        {
            const recipe = o.package_ < graph.value.packages.length
                ? graph.value.packages[o.package_].path ~ "/dub.sdl" : "workspace inputs";
            const entry = o.directive ~ " \"" ~ o.value ~ "\"";
            bool seen;
            foreach (ref e; entries)
                seen |= e.recipe == recipe && e.entry == entry;
            if (seen)
                continue;
            auto w = appender!string;
            writeOpaqueDiagnostic(w, graph.value, o);
            entries ~= OpaqueEntry(recipe, entry, w[]);
        }
    }
    entries.sort!((a, b) => a.recipe != b.recipe ? a.recipe < b.recipe : a.entry < b.entry);
    return entries;
}


/// An entry in a configuration for one host only is found on that host, and
/// one stated in several configurations is one entry.
@("opaqueRecipes.opaqueEntries.everyHostOnce")
@safe
unittest
{
    import std.conv : text;
    import sparkles.build_primitives.dub_manifest : parseDubManifest;

    alias recipe = (string path, string sdl) => SubPackageRecipe(path, parseDubManifest(sdl).value);

    const recipes = [recipe("libs/p", `name "p"
configuration "a" {
    preBuildCommands "make"
}
configuration "b" {
    preBuildCommands "make"
}
configuration "win" {
    platforms "windows"
    lflags "-LC:/sdk"
}`)];
    const entries = opaqueEntries("sparkles", recipes, repositoryHosts);
    assert(entries.length == 2, entries.length.text);
    assert(entries[0].recipe == "libs/p/dub.sdl" && entries[0].entry == `lflags "-LC:/sdk"`, entries[0].entry);
    assert(entries[1].entry == `preBuildCommands "make"`);
    import std.algorithm.searching : canFind;

    assert(entries[1].diagnostic.canFind("configuration `a`") && entries[1].diagnostic.canFind("runs a command"));
}
