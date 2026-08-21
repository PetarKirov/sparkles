/**
The configuration layers (`CFG2`): defaults → user file → project file →
environment, resolved in order as sparse overlays, with per-field origins
and located warnings. The CLI layer — the highest — is applied by the
caller (`cliOverlay` in `app.d`) on top of what this module returns, since
only the parsed command line knows which flags were explicitly typed.

Errors never stop hue (`CFG8`): a layer that fails to read or decode
contributes nothing, and the failure becomes a pre-rendered warning naming
the file, the position or `$`-path, and the target type. A missing file is
not a warning at all.

NOTE: no module-level `@safe:` — the decode path infers `@system`.
*/
module settings_load;

import std.file : exists;
import std.path : buildPath, dirName;

import sparkles.wired.json : JsonError, JsonStage;

import settings : HueConfig;
import settings_io : readJsoncFile;
import settings_overlay : Origin, OriginKind, Origins, Sparse, applyOverlay;

/// The name a repository pins settings under (`CFG2` layer 3).
enum projectFileName = ".hue.json";

/// Everything the rest of hue needs to know about configuration, resolved
/// once at startup.
struct LoadedConfig
{
    /// The effective value after every layer.
    HueConfig effective;

    /// Where each field's value came from (`CFG10`).
    Origins!HueConfig origins;

    /// The user file's own sparse content — `config save` rewrites THIS,
    /// never the resolved value, so env/CLI overrides can never leak into
    /// the file (`CFG11`).
    Sparse!HueConfig userOverlay;

    /// The user file's path (existing or not): `--config`, the platform
    /// config dir, or the Android data dir.
    string userFilePath;

    /// The nearest project file, `""` when none was found.
    string projectFilePath;

    /// `CFG8`: pre-rendered located load failures, in layer order.
    string[] warnings;
}

/// The default user-file location: `<configDir>/hue/config.json`, or `""`
/// when the platform config dir cannot be determined.
string defaultUserConfigPath() @safe
{
    import sparkles.core_cli.common_dirs : configDir;

    const dir = configDir();
    return dir.length ? buildPath(dir, "hue", "config.json") : null;
}

/// The nearest `.hue.json` walking up from `startDir` to the filesystem
/// root; `""` when none. `startDir` may be a file's directory or a cwd.
string findProjectFile(string startDir) @safe
{
    import std.path : absolutePath, buildNormalizedPath;

    if (!startDir.length)
        return null;
    auto dir = startDir.absolutePath.buildNormalizedPath;
    while (true)
    {
        const candidate = buildPath(dir, projectFileName);
        if (candidate.exists)
            return candidate;
        const parent = dir.dirName;
        if (parent == dir)
            return null;
        dir = parent;
    }
}

/**
Resolves layers 1–4. `explicitUserPath` is `--config`'s value (`""` = the
platform default); `walkStartDir` anchors the project-file walk (`""` skips
it — Android, or stdin input); `env` is injectable for tests and reads one
variable (`HUE_GUI_FONTSIZE` keeps winning over files, `CFG2` — the other
`HUE_GUI_*` hooks stay test hooks and override downstream, `CFG7`).
*/
LoadedConfig loadHueConfig(string explicitUserPath, string walkStartDir,
    scope const(char)[] delegate(scope const(char)[] name) @safe env)
{
    LoadedConfig lc;
    lc.userFilePath = explicitUserPath.length
        ? explicitUserPath : defaultUserConfigPath();
    lc.projectFilePath = findProjectFile(walkStartDir);

    // Layer 2: the user file.
    if (lc.userFilePath.length && lc.userFilePath.exists)
    {
        auto r = readJsoncFile!(Sparse!HueConfig)(lc.userFilePath);
        if (r.hasError)
            lc.warnings ~= renderConfigWarning(r.error);
        else
        {
            lc.userOverlay = r.value;
            applyOverlay(lc.effective, lc.origins, r.value,
                Origin(OriginKind.userFile, "file:" ~ lc.userFilePath));
        }
    }

    // Layer 3: the project file.
    if (lc.projectFilePath.length)
    {
        auto r = readJsoncFile!(Sparse!HueConfig)(lc.projectFilePath);
        if (r.hasError)
            lc.warnings ~= renderConfigWarning(r.error);
        else
            applyOverlay(lc.effective, lc.origins, r.value,
                Origin(OriginKind.projectFile, "file:" ~ lc.projectFilePath));
    }

    // Layer 4: the environment (deliberately tiny — CFG7).
    if (env !is null)
    {
        const fs = env("HUE_GUI_FONTSIZE");
        if (fs.length)
        {
            import std.conv : ConvException, to;

            Sparse!HueConfig o;
            try
                o.appearance.fonts.size = fs.to!int;
            catch (ConvException)
                lc.warnings ~= "config: HUE_GUI_FONTSIZE is not an integer: "
                    ~ fs.idup;
            if (!o.appearance.fonts.size.isNull)
                applyOverlay(lc.effective, lc.origins, o,
                    Origin(OriginKind.env, "env:HUE_GUI_FONTSIZE"));
        }
    }

    return lc;
}

/// One located warning line (`CFG8`): the file, the position or `$`-path,
/// the reason — and the promise that hue continued without this file. The
/// error passes by value: `toString`'s renderer does not name the file for
/// parse-stage errors, so the prefix here does, and a scoped `in` view
/// would block slicing the buffer into the appender under dip1000.
string renderConfigWarning(JsonError e) @safe
{
    import std.array : appender;

    auto w = appender!string;
    w ~= "config: ";
    if (e.filePath[].length)
    {
        w ~= e.filePath[];
        w ~= ": ";
    }
    e.toString(w);
    w ~= " — this file's settings were ignored";
    return w[];
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    // `tag` keeps the parallel-running tests out of each other's fixture.
    private string makeConfigFixture(string tag)
    {
        import std.file : mkdirRecurse, tempDir, write;
        import std.process : thisProcessID;
        import std.conv : text;

        const root = buildPath(tempDir,
            text("hue-settings-load-", tag, '-', thisProcessID));
        mkdirRecurse(buildPath(root, "repo", "sub"));
        return root;
    }
}

@("settings_load.loadHueConfig.layersAndOrigins")
@system unittest
{
    import std.file : rmdirRecurse, write;

    const root = makeConfigFixture("layers");
    scope (exit) rmdirRecurse(root);

    const userPath = buildPath(root, "config.json");
    write(userPath, "{\n" ~
        "  // hand-written user file\n" ~
        "  \"appearance\": { \"theme\": \"builtin-dark\" },\n" ~
        "  \"panes\": { \"viewer\": { \"lineNumbers\": true, } },\n" ~
        "}\n");
    write(buildPath(root, "repo", projectFileName),
        `{"panes":{"viewer":{"lineNumbers":false,"tabWidth":8}}}`);

    auto lc = loadHueConfig(userPath, buildPath(root, "repo", "sub"),
        (scope const(char)[] name) => name == "HUE_GUI_FONTSIZE" ? "20" : null);

    assert(lc.warnings.length == 0, lc.warnings.length ? lc.warnings[0] : "");
    assert(lc.projectFilePath == buildPath(root, "repo", projectFileName));

    // The CFG2 case: the project file turns OFF what the user file set to
    // its (default) on value; unset-vs-set-to-default is real.
    assert(lc.effective.panes.viewer.lineNumbers == false);
    assert(lc.effective.panes.viewer.tabWidth == 8);
    assert(lc.effective.appearance.theme == "builtin-dark");
    assert(lc.effective.appearance.fonts.size == 20); // env wins over files
    assert(lc.origins.panes.viewer.lineNumbers.kind == OriginKind.projectFile);
    assert(lc.origins.appearance.theme.kind == OriginKind.userFile);
    assert(lc.origins.appearance.fonts.size.detail == "env:HUE_GUI_FONTSIZE");

    // The user file's own overlay is preserved verbatim for `config save`.
    assert(lc.userOverlay.appearance.theme.get == "builtin-dark");
    assert(lc.userOverlay.panes.viewer.tabWidth.isNull);
}

@("settings_load.loadHueConfig.degradesLocated")
@system unittest
{
    import std.algorithm.searching : canFind;
    import std.file : rmdirRecurse, write;

    const root = makeConfigFixture("degrades");
    scope (exit) rmdirRecurse(root);

    // Missing files are not warnings; hue runs on defaults.
    auto quiet = loadHueConfig(buildPath(root, "config.json"), null, null);
    assert(quiet.warnings.length == 0);
    assert(quiet.effective == HueConfig.init);

    // A malformed user file warns with its position and is ignored —
    // hue continues with defaults (CFG8), and the project layer still
    // applies.
    const userPath = buildPath(root, "config.json");
    write(userPath, "{\n  \"panes\": nope\n}\n");
    write(buildPath(root, "repo", projectFileName),
        `{"appearance":{"theme":"builtin-light"}}`);

    auto lc = loadHueConfig(userPath, buildPath(root, "repo"), null);
    assert(lc.warnings.length == 1);
    assert(lc.warnings[0].canFind("2"), lc.warnings[0]); // the line
    assert(lc.warnings[0].canFind(userPath), lc.warnings[0]);
    assert(lc.warnings[0].canFind("ignored"));
    assert(lc.effective.appearance.theme == "builtin-light");
    assert(lc.effective.panes.viewer.tabWidth
        == HueConfig.init.panes.viewer.tabWidth);
}
