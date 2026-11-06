/**
The entry point: parse the shared window/font/theme CLI, run the component.

Deliberately the whole file (`DIA6`): everything with behavior lives in
`diagram_app.d`, inside the test build.
*/
module app;

import sparkles.base.logger : LogLevel;
import sparkles.core_cli.args : Command, failRun, Flatten, Option, ranOk, runCli, RunExpected;
import sparkles.ui_app.gui_options : GuiOptions, NativeOptions;
import sparkles.ui_app.host : PointerUnit, RunConfig;
import sparkles.ui_app.run : asRunResult;
import sparkles.ui_app.run_app : appThemeOf, runApp;

import grid_file : loadGridConfigFile;

import diagram_app : DiagramApp;

int main(string[] args) => runCli!Diagram(args);

/// The shared window/font/theme options, plus `--config-file` (`GRD8`).
@(Command("diagram",
    shortDescription: "A draw.io-style diagram board — infinite canvas, camera, minimap.",
))
struct Diagram
{
    @(Option("log-level", description: "Log level: trace | info | warning | error | critical | off."))
    LogLevel logLevel = LogLevel.warning;

    @Flatten("GUI Options")
    GuiOptions gui;

    @Flatten("Native Window Options")
    NativeOptions native;

    @(Option("config-file", description:
        "Load a grid JSON config at startup. Invalid file aborts.",
        placeholder: "PATH"))
    string configFile;
    @(Option("list-keys", description:
        "Print the effective key table (KBD6) and exit."))
    bool listKeys;

    /// Prints the keys, or runs the board.
    RunExpected!void run()
    {
        if (listKeys)
        {
            import std.stdio : stdout;
            import keymap : writeKeys;

            auto w = stdout.lockingTextWriter;
            writeKeys(w);
            return ranOk();
        }

        RunConfig cfg = {
            title: "diagram",
            gui: gui,
            native: native,
            motion: true, // hover affordances want bare pointer motion
            // Space+LMB pan needs key releases (`IXN3` / `INP16`): a window
            // reports them, and so does a terminal speaking the kitty
            // keyboard protocol (D44); elsewhere Space is a sticky toggle.
            keyRelease: true,
            // The GUI board hit-tests in pixels at the drawn cell size
            // (`HST18`); the terminal arm ignores the unit and keeps
            // delivering cells.
            pointerUnit: PointerUnit.pixels,
        };

        // Same theme the host uses for the page fill (`RND5`): board slots
        // resolve against it, so `--theme` reaches the nodes as well as the
        // page. The board itself is heap-only (~3 MiB — see `DiagramApp`);
        // `create` is the only way to build one, and `owner` frees it on the
        // way out.
        auto owner = DiagramApp.create(appThemeOf(gui));
        ref DiagramApp app() => owner.get();
        if (configFile.length)
        {
            string error;
            if (!loadGridConfigFile(configFile, app.world.gridConfig, app.theme.palette, error))
                return failRun(error);
        }
        // Where the settings pane's `s` writes (`SET5`). A file named on the
        // command line is the one the reader already chose; otherwise the
        // platform's own config location, so the pane is not useless on a
        // launch without flags — which, on a desktop icon or on Android, is
        // every launch.
        app.settingsPath = configFile.length ? configFile : defaultSettingsPath();
        return asRunResult(runApp(app, cfg), "diagram");
    }
}

/// `$XDG_CONFIG_HOME/diagram/grid.json`, or empty when there is no home to
/// resolve — in which case the pane says it has nowhere to save rather than
/// writing somewhere surprising.
private string defaultSettingsPath()
{
    import std.path : buildPath;
    import sparkles.core_cli.common_dirs : configDir;

    const base = configDir();
    return base.length ? buildPath(base, "diagram", "grid.json") : null;
}
