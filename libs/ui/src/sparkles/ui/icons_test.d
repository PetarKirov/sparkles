/**
The icon table's check against the pinned Nerd Fonts release (design-system
`GLY4`). Kept apart from `sparkles.ui.icons`, which the generator rewrites, and
from `sparkles.ui.glyphs`, whose functions are all `pure`: this test reads a
file named by the environment.
*/
module sparkles.ui.icons_test;

version (unittest):

import std.traits : EnumMembers;

import sparkles.ui.icons : Icon;

@("ui.icons.tableMatchesThePinnedRelease")
@system unittest
{
    import std.conv : to;
    import std.file : readText;
    import std.json : parseJSON;
    import std.process : environment;
    import sparkles.test_runner.skip : skipTest;
    import sparkles.ui.icons : iconSourceNames, nerdFontsVersion;

    // `GLY4`: the checked-in icon table is the pinned release's own
    // `glyphnames.json`, entry for entry. A drifted table, or a release bump
    // without regenerating (`apps/ci/tools/gen-icons.d`), fails here.
    const source = environment.get("SPARKLES_NERD_FONT_GLYPHNAMES", "");
    if (source.length == 0)
        skipTest("SPARKLES_NERD_FONT_GLYPHNAMES unset (enter `nix develop`)");
    auto json = parseJSON(readText(source));
    assert(json["METADATA"]["version"].str == nerdFontsVersion,
        "regenerate the icon table for Nerd Fonts " ~ json["METADATA"]["version"].str);
    static immutable icons = [EnumMembers!Icon];
    assert(icons.length == iconSourceNames.length);
    foreach (i, icon; icons)
    {
        const entry = iconSourceNames[i] in json.object;
        assert(entry !is null, iconSourceNames[i] ~ " is not in the release");
        assert((*entry)["code"].str.to!uint(16) == cast(uint) icon,
            iconSourceNames[i] ~ " moved in the release");
    }
}
