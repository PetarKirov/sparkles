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
import examples : Example;

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

    RunExpected!void run()
    {
        if (shot.length && (gui.tui || gui.noGui))
            return failRun("--shot requires the native GUI host");
        EditorApp app;
        if (!app.useTheme(gui.theme)) return failRun("Unknown theme: " ~ gui.theme);
        app.inspector = inspector;
        app.shotPath = shot;
        if (example != Example.none) app.execute(CommandId(AppCommand.example, example));
        if (commands) app.execute(CommandId(AppCommand.palette));
        if (themes) app.execute(CommandId(AppCommand.themes));
        RunConfig config = {title: "Sparkles Editor", gui: gui, native: native, motion: true};
        if (shot.length) config.gui.gui = true;
        auto outcome = runApp(app, config);
        if (app.captureError.length) return failRun(app.captureError);
        return asRunResult(outcome, "editor");
    }
}
