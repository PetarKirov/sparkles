/**
The shell: parse the CLI, run the terminal component.

Everything the emulator $(I is) lives in `sparkles:terminal-view`
(`TerminalView`, a `runApp` component); everything the window/font/backend
side is lives in `sparkles:ui-app`. This file maps the terminal's historical
flags — spellings and defaults preserved — onto the host's options and calls
$(REF runApp, sparkles,ui_app,run_app).
*/
module app;

import std.getopt;

import cli : guiOptionsFrom, TerminalCli;
import sparkles.terminal_view.component : TerminalView, TerminalViewOptions;
import sparkles.terminal_view.core : logBuildInfo;
import sparkles.terminal_view.input : parseExitBehavior;
import sparkles.ui_app.host : RunConfig;
import sparkles.ui_app.run : RunOutcome;
import sparkles.ui_app.run_app : runApp;

int main(string[] args)
{
    import std.array : join;
    import std.stdio : stderr;
    import std.string : toStringz;

    // The terminal's own vocabulary, defaults preserved (the shared-CLI
    // spellings and defaults land with the CLI3 unification, not this
    // migration — identical behavior is the gate).
    string fontOpt = "monospace";
    int fontSizePt = 13;
    int windowCols = 100;
    int windowRows = 30;
    size_t scrollbackLimit = size_t.max;
    bool debugScreenshotAndExit = false;
    string exitBehaviorOpt = "hold-on-failure";
    string[] codepointMapOpt;
    string[] fontDirOpt;

    auto helpInfo = getopt(
        args,
        // Stop at the first non-option so a trailing command (and its own flags)
        // is left untouched: `terminal --font-size 14 -- vim file -R`.
        config.stopOnFirstNonOption,
        "font|f", "Font path or name (e.g. '/path/to/font.ttf' or 'Fira Code')", &fontOpt,
        "font-size|s", "Font size in points (default: 13)", &fontSizePt,
        "window-width", "Initial window width in columns (default: 100)", &windowCols,
        "window-height", "Initial window height in rows (default: 30)", &windowRows,
        "scrollback-limit", "Maximum number of lines to keep in scrollback history (0 to disable, default: infinite)", &scrollbackLimit,
        "font-codepoint-map", "Render codepoints from a specific font (repeatable): 'U+XXXX-U+YYYY,U+ZZZZ=Family'", &codepointMapOpt,
        "font-dir", "Resolve fonts by scanning this directory instead of fontconfig (repeatable). Makes a build portable and its font selection deterministic: no fc-match subprocess, no dependence on the host's fontconfig configuration. Pair with the bundle from `nix build .#sparkles-fonts`.", &fontDirOpt,
        "exit-behavior", "On child exit: close | wait-for-key | hold | hold-on-failure (default)", &exitBehaviorOpt,
        "debug-take-screenshot-and-exit", "Takes a screenshot after 2 seconds and exits", &debugScreenshotAndExit
    );

    if (helpInfo.helpWanted)
    {
        defaultGetoptPrinter(
            "A minimal terminal emulator using libghostty-vt.\n\n" ~
            "Usage: terminal [options] [-- command [args...]]\n\n" ~
            "With no command, the login shell runs interactively. With a command,\n" ~
            "the shell runs it via `-c` and then exits (e.g. `terminal -- vim file`).",
            helpInfo.options);
        return 0;
    }

    // Any arguments left after the options are an optional command to run in
    // the shell. A leading `--` separator is accepted and stripped.
    string[] command = args[1 .. $];
    if (command.length && command[0] == "--")
        command = command[1 .. $];

    logBuildInfo();

    RunConfig cfg = {
        title: "Sparkles Terminal",
        gui: guiOptionsFrom(TerminalCli(
            font: fontOpt,
            fontSizePt: fontSizePt,
            windowCols: windowCols,
            windowRows: windowRows,
            codepointMaps: codepointMapOpt,
            fontDirs: fontDirOpt,
        )),
        keyRelease: true, // the terminal-grade keyboard (kitty releases)
    };

    // Stack-pinned: the VT effects hold a pointer into the component.
    TerminalView tv;
    tv.opts = TerminalViewOptions(
        shellCommand: command.length ? command.join(" ").toStringz : null,
        scrollbackLimit: scrollbackLimit,
        exitBehavior: parseExitBehavior(exitBehaviorOpt),
        debugScreenshotAndExit: debugScreenshotAndExit,
    );

    const outcome = runApp(tv, cfg);
    tv.close();

    final switch (outcome)
    {
        case RunOutcome.ok:
            return 0;
        case RunOutcome.notInteractive:
        case RunOutcome.noBackend:
            stderr.writeln("Error: no window to open a terminal in.");
            return 1;
        case RunOutcome.openFailed:
            stderr.writeln("Error: could not open a window or load the font '",
                fontOpt, "'.");
            return 1;
    }
}
