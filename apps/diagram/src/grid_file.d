/**
Load a grid JSON document (`GRD8`). Fail closed: a missing or invalid file
leaves `cfg` / `pal` untouched and writes a reason into `error`.
*/
module grid_file;

import sparkles.ui.components.grid_backdrop : GridConfig, parseGridConfigJson;
import sparkles.ui.style : Palette;

/// Parse `text` as grid config, applying slot overrides to `pal`.
bool applyGridConfigText(const(char)[] text, ref GridConfig cfg, ref Palette pal,
    ref string error) @safe
    => parseGridConfigJson(text, cfg, pal, error);

/// Read `path` and apply it. Missing file is an error, not a silent skip.
bool loadGridConfigFile(string path, ref GridConfig cfg, ref Palette pal,
    ref string error)
{
    import std.file : exists, readText;

    if (!exists(path))
    {
        error = "diagram: config file not found: " ~ path;
        return false;
    }
    return applyGridConfigText(readText(path), cfg, pal, error);
}

@("diagram.grid_file.failClosedOnGarbage")
@system unittest
{
    import sparkles.ui.style : ColorScheme, defaultTwoslashPalette;

    GridConfig cfg;
    auto pal = defaultTwoslashPalette(ColorScheme.dark);
    const before = pal.bgAlpha[0];
    string err;
    assert(!applyGridConfigText("{", cfg, pal, err));
    assert(err.length > 0);
    assert(pal.bgAlpha[0] == before);
}

@("diagram.grid_file.presetApplies")
@system unittest
{
    import sparkles.ui.components.grid_backdrop : AxisVisibility, MarkKind;
    import sparkles.ui.style : ColorScheme, defaultTwoslashPalette;

    GridConfig cfg;
    auto pal = defaultTwoslashPalette(ColorScheme.dark);
    string err;
    assert(applyGridConfigText(`{"preset":"dotPaper"}`, cfg, pal, err), err);
    assert(cfg.minorStyle.markKind == MarkKind.dots);
    assert(cfg.majorLattice.visibility == AxisVisibility.xy);
}
