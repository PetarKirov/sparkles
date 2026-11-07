/// Desktop entry; application behavior remains in the testable component.
module app;

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

int main(string[] args) => runCli!Editor(args);

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
    @(Option("inspector", description: "Show editor diagnostics."))
    bool inspector;
    @(Option("shot", description: "Capture a native frame to PNG, then exit.", placeholder: "PATH"))
    string shot;
    @(Option("example", description: "Editable example: code, unicode, protectedText."))
    Example example;
    @(Argument("paths", description: "UTF-8 files to open in independent tabs.", optional: true))
    string[] paths;

    RunExpected!void run()
    {
        if (shot.length && (gui.tui || gui.noGui))
            return failRun("--shot requires the native GUI host");
        EditorApp app;
        scope (exit) app.dispose();
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
        RunConfig config = {title: "Sparkles Editor", gui: gui, native: native, motion: true};
        if (shot.length) config.gui.gui = true;
        auto outcome = runApp(app, config);
        if (app.captureError.length) return failRun(app.captureError);
        return asRunResult(outcome, "editor");
    }
}
