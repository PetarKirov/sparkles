/**
Load a grid JSON document (`GRD8`). Fail closed: a missing or invalid file
leaves `cfg` / `pal` untouched and writes a reason into `error`.
*/
module grid_file;

import sparkles.ui.components.grid_backdrop : GridConfig, parseGridConfigJson,
    writeGridConfigJson;
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

/**
Writes `cfg` to `path` in the schema $(LREF loadGridConfigFile) reads (`SET5`).

$(B The same fail-closed contract, in the other direction): every way this can
fail returns a reason rather than throwing, because the caller is a settings
pane whose footer shows the reason — an exception there would leave the running
board fine and the user with a stack trace instead of a sentence.

The parent directory is created when missing: `$XDG_CONFIG_HOME/diagram/` does
not exist until something writes there, and refusing the first save because of
that would make the feature unreachable exactly once, confusingly.
*/
bool saveGridConfigFile(string path, in GridConfig cfg, ref string error) @safe
{
    import std.file : FileException, mkdirRecurse, write;
    import std.path : dirName;

    try
    {
        const dir = dirName(path);
        if (dir.length)
            mkdirRecurse(dir);
        write(path, writeGridConfigJson(cfg));
    }
    catch (FileException ex)
    {
        error = "diagram: cannot write config file: " ~ ex.msg;
        return false;
    }
    return true;
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

@("diagram.grid_file.saveRoundTripsThroughTheSameSchema")
@system unittest
{
    import std.file : rmdirRecurse, tempDir;
    import std.path : buildPath;
    import sparkles.ui.components.grid_backdrop : GridPreset, gridPreset,
        MarkKind;
    import sparkles.ui.style : ColorScheme, defaultTwoslashPalette;

    // What the pane saves is what `--config-file` loads (`SET5`/`GRD8`): one
    // schema, asserted by driving both halves rather than by comment.
    const dir = buildPath(tempDir, "diagram-grid-save-test");
    scope (exit) rmdirRecurse(dir);
    const path = buildPath(dir, "nested", "grid.json");

    auto saved = gridPreset(GridPreset.dotPaper);
    saved.minorLattice.interval = 5;
    string err;
    assert(saveGridConfigFile(path, saved, err), err);

    GridConfig loaded;
    auto pal = defaultTwoslashPalette(ColorScheme.dark);
    assert(loadGridConfigFile(path, loaded, pal, err), err);
    assert(loaded.minorStyle.markKind == MarkKind.dots);
    assert(loaded.minorLattice.interval == 5);
    assert(loaded == saved, "the schema round-trips the whole config");
}

@("diagram.grid_file.saveFailureIsAReasonNotAThrow")
@system unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;

    // A directory where the file should be: `write` throws, and the pane's
    // footer needs a sentence.
    const dir = buildPath(tempDir, "diagram-grid-save-fail");
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);

    string err;
    assert(!saveGridConfigFile(dir, GridConfig.init, err));
    assert(err.length > 0);
}
