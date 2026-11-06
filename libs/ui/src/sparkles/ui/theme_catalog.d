/** Canonical theme discovery over the shared built-in registry. */
module sparkles.ui.theme_catalog;

import std.algorithm.sorting : sort;
import sparkles.ui.themes : builtinThemes;

/// Stable alphabetical names with registry aliases removed.
string[] canonicalThemeNames() @safe pure nothrow
{
    string[] names;
    foreach (name, ref theme; builtinThemes)
        if (name == theme.name) names ~= name;
    names.sort();
    return names;
}

/// Registry aliases never produce duplicate picker rows.
@("ui.themeCatalog.canonicalNames")
@safe pure nothrow unittest
{
    import std.algorithm.searching : canFind;
    import std.algorithm.sorting : isSorted;
    const names = canonicalThemeNames();
    assert(names.length == 36 && names.isSorted);
    assert(names.canFind("github-light") && names.canFind("nord"));
    assert(!names.canFind("githublight") && !names.canFind("tokyonight"));
}
