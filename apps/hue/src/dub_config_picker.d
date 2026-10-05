/**
The dub configuration picker (`LIV10`): the configurations the focused
document's recipe declares, offered through the fuzzy picker's choices
source, so live types can be pointed at the build a reader cares about —
`gpu-effects` rather than the default `library`, say.

The choices come from the recipe itself
($(MREF sparkles,build_primitives,dub_recipe)), never from `dub describe`:
a describe per candidate would be seconds, and the names are all the
picker needs. Each row previews the recipe at its configuration's
declaration. Accepting one records it in the project state
($(MREF project_state)) for the document's package only.
*/
module dub_config_picker;

import expected : err, Expected, ok;

import sparkles.build_primitives.dub_recipe : readDubRecipe;

import picker_sources : Choice, choiceFinder, ChoiceFinder, PickerTarget;
import project_state : dubBuildFor, PackageSlot, packageSlotFor;
import settings : DubBuildSettings;

/// The label of the row that clears the selection.
enum defaultChoiceLabel = "default";

/// Marks the row whose configuration is in effect.
enum currentSuffix = " (current)";

/// What opening the picker for one document needs.
struct DubConfigurationPick
{
    ChoiceFinder rows; /// `default`, then each configuration in declaration order
    PackageSlot slot;  /// where an accepted row is recorded
}

/**
The picker rows for the document at `docPath`, given the global `dub`
section: a `default` row that clears the package's selection, then every
configuration the recipe declares. The configuration in effect is marked.
An error names why there is nothing to pick from.
*/
Expected!(DubConfigurationPick, string) dubConfigurationPick(string docPath,
    const DubBuildSettings global)
{
    if (!docPath.length)
        return err!DubConfigurationPick("no document is open");
    const slot = packageSlotFor(docPath);
    if (!slot.found)
        return err!DubConfigurationPick(docPath ~ " is not in a dub package");
    const recipe = readDubRecipe(slot.recipe);
    if (!recipe.valid)
        return err!DubConfigurationPick("cannot read " ~ slot.recipe);
    if (!recipe.configurations.length)
        return err!DubConfigurationPick(slot.recipe ~ " declares no configurations");

    const current = dubBuildFor(docPath, global).build.config;
    static string mark(string label, bool isCurrent) => isCurrent ? label ~ currentSuffix : label;

    Choice[] rows;
    rows ~= Choice(mark(defaultChoiceLabel, !current.length), null,
        PickerTarget(path: slot.recipe));
    foreach (c; recipe.configurations)
        rows ~= Choice(mark(c.name, c.name == current), c.name,
            PickerTarget(path: slot.recipe, line: cast(uint) c.line));
    return ok!string(DubConfigurationPick(choiceFinder(rows), slot));
}

@("dub_config_picker.rowsFollowTheRecipe")
@system unittest
{
    import sparkles.test_utils.tmpfs : TmpFS;
    import std.path : buildPath;

    import project_state : selectDubConfiguration;

    auto t = TmpFS.create("hue-dub-config-picker");
    t.writeFileAt(".git/HEAD", "ref: refs/heads/main\n");
    t.writeFileAt("libs/ui/dub.sdl", "name \"ui\"\nconfiguration \"library\" {\n}\n"
        ~ "configuration \"gpu-effects\" {\n}\n");
    t.writeFileAt("libs/ui/src/m.d", "module m;\n");
    t.writeFileAt("libs/bare/dub.sdl", "name \"bare\"\n");
    t.writeFileAt("libs/bare/src/b.d", "module b;\n");
    const doc = t.dir.buildPath("libs", "ui", "src", "m.d");
    const recipe = t.dir.buildPath("libs", "ui", "dub.sdl");

    auto pick = dubConfigurationPick(doc, DubBuildSettings.init);
    assert(!pick.hasError, pick.hasError ? pick.error : "");
    auto rows = pick.value.rows;
    const s = rows.snapshot();
    assert(s.candidates.length == 3);
    assert(s.candidates[0].path == "default (current)");
    assert(s.candidates[1].path == "library" && s.candidates[2].path == "gpu-effects");
    assert(rows.value(0) is null && rows.value(2) == "gpu-effects");
    assert(rows.resolve(2) == PickerTarget(path: recipe, line: 4));
    assert(pick.value.slot.key == "libs/ui");

    // The global section and then the package entry decide which row is current.
    pick = dubConfigurationPick(doc, DubBuildSettings(config: "library"));
    assert(pick.value.rows.snapshot().candidates[1].path == "library (current)");
    assert(!selectDubConfiguration(pick.value.slot, "gpu-effects").hasError);
    pick = dubConfigurationPick(doc, DubBuildSettings(config: "library"));
    assert(pick.value.rows.snapshot().candidates[2].path == "gpu-effects (current)");

    // Nothing to pick from.
    assert(dubConfigurationPick("", DubBuildSettings.init).hasError);
    assert(dubConfigurationPick(t.dir.buildPath("libs", "bare", "src", "b.d"),
        DubBuildSettings.init).error == t.dir.buildPath("libs", "bare", "dub.sdl")
        ~ " declares no configurations");
}
