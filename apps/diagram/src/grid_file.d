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

/**
Read `path` and apply it. A missing file is an error, not a silent skip.

$(B Every way this can fail returns `false`), including the ones `std.file`
reports by throwing: a path that exists but cannot be read, or whose bytes are
not valid UTF-8. Those used to escape as an exception — so a config file with
the wrong permissions printed a stack trace from `main` instead of the reason
this function promises to write into `error`.
*/
bool loadGridConfigFile(string path, ref GridConfig cfg, ref Palette pal,
    ref string error)
{
    import std.file : exists, FileException, readText;
    import std.utf : UTFException;

    if (!exists(path))
    {
        error = "diagram: config file not found: " ~ path;
        return false;
    }

    string text;
    try
        text = readText(path);
    catch (FileException ex)
    {
        error = "diagram: cannot read config file: " ~ ex.msg;
        return false;
    }
    catch (UTFException ex)
    {
        error = "diagram: config file is not valid UTF-8: " ~ path;
        return false;
    }
    return applyGridConfigText(text, cfg, pal, error);
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

@("diagram.grid_file.unreadableFileIsAnErrorNotAThrow")
@system unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import sparkles.ui.style : ColorScheme, defaultTwoslashPalette;

    // A directory is the portable stand-in for "exists, cannot be read as
    // text": `readText` throws, and the caller in `app.d` prints `error` — so
    // a throw here reaches the user as a stack trace instead of a sentence.
    const dir = buildPath(tempDir, "diagram-grid-file-test");
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);

    GridConfig cfg;
    auto pal = defaultTwoslashPalette(ColorScheme.dark);
    string err;
    assert(!loadGridConfigFile(dir, cfg, pal, err));
    assert(err.length > 0);
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
