/// Desktop entry; application behavior remains in the testable component.
module app;

import sparkles.base.logger : LogLevel;
import sparkles.core_cli.args : Command, Flatten, Option, RunExpected, failRun, runCli;
import sparkles.ui_app.gui_options : GuiOptions, NativeOptions;
import sparkles.ui_app.host : RunConfig;
import sparkles.ui_app.run : asRunResult;
import sparkles.ui_app.run_app : appThemeOf, runApp;
import editor_app : EditorApp;
import commands : CommandId, AppCommand = Command;

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
    @(Option("inspector", description: "Show editor diagnostics."))
    bool inspector;
    @(Option("shot", description: "Capture a native frame to PNG, then exit.", placeholder: "PATH"))
    string shot;

    RunExpected!void run()
    {
        if (shot.length && (gui.tui || gui.noGui))
            return failRun("--shot requires the native GUI host");
        EditorApp app;
        app.theme = appThemeOf(gui);
        app.inspector = inspector;
        app.shotPath = shot;
        if (commands) app.execute(CommandId(AppCommand.palette));
        RunConfig config = {title: "Sparkles Editor", gui: gui, native: native, motion: true};
        if (shot.length) config.gui.gui = true;
        return asRunResult(runApp(app, config), "editor");
    }
}
