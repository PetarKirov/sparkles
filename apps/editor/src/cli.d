/**
The editor's command line, shared by the desktop `main` (app.d) and the
Android entry (android_entry.d); application behavior remains in the
testable component.
*/
module cli;

import sparkles.base.logger : LogLevel;
import sparkles.core_cli.args : Argument, Command, Flatten, Option, RunExpected, failRun, runCli;
import sparkles.ui_app.gui_options : GuiOptions, NativeOptions;
import sparkles.ui_app.host : RunConfig;
import sparkles.ui_app.run : asRunResult;
import sparkles.ui_app.run_app : appThemeOf, runApp;
import editor_app : EditorApp;
import commands : CommandId, AppCommand = Command;
import examples : Example;
import core.thread : Thread;
import core.time : msecs;
import std.process : environment;
import std.path : absolutePath, buildNormalizedPath, buildPath;

/// Run the editor with `args` (`args[0]` is the program name).
int run(string[] args) => runCli!Editor(args);

/// The standard host CLI with optional command/diagnostic startup views.
@(Command("editor", shortDescription: "A text editor built from the shared Sparkles libraries."))
struct Editor
{
    @(Option("log-level", description: "Log level: trace | info | warning | error | critical | off."))
    LogLevel logLevel = LogLevel.warning;

    @Flatten("GUI Options")
    GuiOptions gui;
    @Flatten("Native Window Options")
    NativeOptions native;
    @(Option("commands", description: "Open the command palette at startup."))
    bool commands;
    @(Option("themes", description: "Open the theme picker with live preview."))
    bool themes;
    @(Option("languages", description: "Open the highlighting-language picker."))
    bool languages;
    @(Option("inspector", description: "Show editor diagnostics."))
    bool inspector;
    @(Option("shot", description: "Capture a native frame to PNG, then exit.", placeholder: "PATH"))
    string shot;
    @(Option("state-dir", description: "Session archive registry (defaults to XDG_STATE_HOME/sparkles/editor).", placeholder: "PATH"))
    string stateDir;
    @(Option("no-session", description: "Do not read or write session recovery."))
    bool noSession;
    @(Option("example", description: "Editable example: code, unicode, protectedText."))
    Example example;
    @(Argument("paths", description: "UTF-8 files to open in independent tabs.", optional: true))
    string[] paths;

    RunExpected!void run()
    {
        if (shot.length && (gui.tui || gui.noGui))
            return failRun("--shot requires the native GUI host");
        EditorApp app;
        if (!app.useTheme(gui.theme)) return failRun("Unknown theme: " ~ gui.theme);
        app.inspector = inspector;
        app.shotPath = shot;
        if (example != Example.none) app.execute(CommandId(AppCommand.example, example));
        foreach (path; paths)
        {
            if (!app.openPath(path)) return failRun(app.status);
            while (app.filesBusy)
            {
                app.pollDocuments();
                if (app.filesBusy) Thread.sleep(1.msecs);
            }
            if (app.lastOpenError.length) return failRun(app.lastOpenError);
        }
        if (paths.length && !app.openPath(paths[0])) return failRun(app.status);
        if (commands) app.startupCommand = AppCommand.palette;
        if (themes) app.startupCommand = AppCommand.themes;
        if (languages) app.startupCommand = AppCommand.languages;
        if (!noSession && (!shot.length || stateDir.length))
        {
            const home = environment.get("HOME", "");
            const state = environment.get("XDG_STATE_HOME", home.length ? buildPath(home, ".local", "state") : "");
            const selected = stateDir.length ? stateDir : state.length ? buildPath(state, "sparkles", "editor") : "";
            // Desktop namespaces may live outside HOME. Android supplies its
            // private durable root through its own application entry.
            string root = "/";
            if (home.length && selected.length)
            {
                const normalizedHome = buildNormalizedPath(absolutePath(home));
                const normalizedState = buildNormalizedPath(absolutePath(selected));
                if (normalizedState == normalizedHome || (normalizedState.length > normalizedHome.length
                    && normalizedState[0 .. normalizedHome.length] == normalizedHome
                    && normalizedState[normalizedHome.length] == '/')) root = normalizedHome;
            }
            app.enableRecovery(selected, root);
        }
        RunConfig config = {title: "Sparkles Editor", gui: gui, native: native, motion: true};
        if (shot.length) config.gui.gui = true;
        auto outcome = runApp(app, config);
        if (app.captureError.length) return failRun(app.captureError);
        if (app.recoveryShutdownError.length) return failRun("Recovery checkpoint failed during shutdown: " ~ app.recoveryShutdownError);
        return asRunResult(outcome, "editor");
    }
}
