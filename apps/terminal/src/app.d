/**
The shell: resolve the configuration, run the terminal component.

Everything the emulator $(I is) lives in `sparkles:terminal-view`
(`TerminalView`, a `runApp` component); everything the window/font/backend
side is lives in `sparkles:ui-app`. This file parses the desktop's flags —
spellings preserved — as the configuration's highest layer (`TCF2`), and
answers `terminal config show|write` (`TCF5`).
*/
module app;

import std.getopt;

import cli : guiOptionsFrom, onExitFromFlag, viewOptionsFrom;
import settings : TerminalConfig;
import settings_load : desktopConfigPath, loadTerminalConfig, LoadedConfig;
import desktop_terminal : DesktopTerminal;
import logging : desktopStateDir;
import sparkles.terminal_view.component : TerminalViewOptions;
import sparkles.wired.json : readJSONFile;
import workspace : PaneSpec, SavedWorkspace;
import sparkles.terminal_view.notification_log : NotificationRoute;
import sparkles.terminal_view.osc_scan : Notification;
import sparkles.terminal_view.core : logBuildInfo;
import sparkles.terminal_view.log : routeTraceLog;
import sparkles.ui_app.host : RunConfig;
import sparkles.ui_app.run : RunOutcome;
import sparkles.ui_app.run_app : runApp;
import sparkles.wired.overlay : Sparse;

int main(string[] args)
{
    version (Android)
    {
        import android_app : androidMain;

        return androidMain();
    }
    else
        return desktopMain(args);
}

/// One explicitly typed flag: what it sets, and its spelling (the origin
/// `config show` reports).
private struct CliFlag
{
    Sparse!TerminalConfig overlay;
    string flag;
}

private int desktopMain(string[] args)
{
    import std.array : join;
    import std.file : exists, getcwd;
    import std.path : buildPath;
    import std.stdio : stderr;
    import std.string : toStringz;
    {
        import std.process : environment;
        import chrome : debugHitBoxes;

        debugHitBoxes = environment.get("SPARKLES_DEBUG_HITS", "").length > 0;
    }

    import sparkles.base.logger : warning;

    // Run as `xdg-open` (the shim on every session's PATH, `TDV4`): hand the
    // file to the terminal that owns the session, or to the next xdg-open.
    {
        import std.path : baseName;

        if (args.length && args[0].baseName == "xdg-open")
        {
            import open_request : xdgOpenShim;

            return xdgOpenShim(args);
        }
    }
    if (args.length >= 2 && args[1] == "config")
        return configCommand(args[0], args[2 .. $]);

    string configPath = desktopConfigPath();
    int windowCols = 100;
    int windowRows = 30;
    bool debugScreenshotAndExit = false;
    CliFlag[] flags;
    string[] codepointMaps, fontDirs;
    string badExit;

    void set(string flag, scope void delegate(ref Sparse!TerminalConfig) @safe apply)
    {
        CliFlag f = {flag: flag};
        apply(f.overlay);
        flags ~= f;
    }

    auto helpInfo = getopt(
        args,
        // Stop at the first non-option so a trailing command (and its own flags)
        // is left untouched: `terminal --font-size 14 -- vim file -R`.
        config.stopOnFirstNonOption,
        "config", "Configuration file (default: " ~ configPath ~ ")", &configPath,
        "font|f", "Font path or name (e.g. '/path/to/font.ttf' or 'Fira Code')",
            (string _, string v) { set("--font", (ref s) { s.appearance.font.family = v; }); },
        "font-size|s", "Font size in points (default: 13)",
            (string _, string v) {
                import std.conv : to;

                const pt = v.to!int;
                set("--font-size", (ref s) { s.appearance.font.size = pt; });
            },
        "window-width", "Initial window width in columns (default: 100)", &windowCols,
        "window-height", "Initial window height in rows (default: 30)", &windowRows,
        "scrollback-limit", "Maximum number of lines to keep in scrollback history (0 to disable, default: infinite)",
            (string _, string v) {
                import std.conv : to;

                const n = v.to!long;
                set("--scrollback-limit", (ref s) { s.behaviour.scrollback = n; });
            },
        "font-codepoint-map", "Render codepoints from a specific font (repeatable): 'U+XXXX-U+YYYY,U+ZZZZ=Family'", &codepointMaps,
        "font-dir", "Resolve fonts by scanning this directory instead of fontconfig (repeatable). Makes a build portable and its font selection deterministic: no fc-match subprocess, no dependence on the host's fontconfig configuration. Pair with the bundle from `nix build .#sparkles-fonts`.", &fontDirs,
        "exit-behavior", "On child exit: close | wait-for-key | hold | hold-on-failure (default)",
            (string _, string v) {
                import settings : OnExit;

                OnExit e;
                if (onExitFromFlag(v, e))
                    set("--exit-behavior", (ref s) { s.behaviour.onExit = e; });
                else
                    badExit = v;
            },
        "debug-take-screenshot-and-exit", "Takes a screenshot after 2 seconds and exits", &debugScreenshotAndExit
    );

    if (helpInfo.helpWanted)
    {
        defaultGetoptPrinter(
            "sparkles:terminal — a minimal terminal emulator using libghostty-vt.\n\n" ~
            "Usage: terminal [options] [-- command [args...]]\n" ~
            "       terminal config show [--changed] | write [--force] | keys\n\n" ~
            "With no command, the login shell runs interactively. With a command,\n" ~
            "the shell runs it via `-c` and then exits (e.g. `terminal -- vim file`).\n" ~
            "Settings come from the configuration file; a flag overrides it.",
            helpInfo.options);
        return 0;
    }
    if (codepointMaps.length)
        set("--font-codepoint-map", (ref s) { s.appearance.font.codepointMap = codepointMaps; });
    if (fontDirs.length)
        set("--font-dir", (ref s) { s.appearance.font.fontDir = fontDirs; });

    // Any arguments left after the options are an optional command to run in
    // the shell. A leading `--` separator is accepted and stripped.
    string[] command = args[1 .. $];
    if (command.length && command[0] == "--")
        command = command[1 .. $];

    {
        import logging : desktopStateDir, installTerminalLog;
        import sparkles.base.logger : initLogger, LogLevel;

        initLogger(LogLevel.info); // stderr, then the file and the ring
        installTerminalLog(desktopStateDir());
    }
    logBuildInfo();

    auto lc = loadTerminalConfig(configPath, null);
    foreach (f; flags)
        lc.applyCli(f.overlay, f.flag);
    if (badExit.length)
        lc.warnings ~= "config: --exit-behavior " ~ badExit ~ " is not one of "
            ~ "close, wait-for-key, hold, hold-on-failure — the flag was ignored";

    RunConfig cfg = {
        title: "sparkles:terminal",
        gui: guiOptionsFrom(lc.effective, windowCols, windowRows),
        keyRelease: true, // the terminal-grade keyboard (kitty releases)
        traceSink: &routeTraceLog, // raylib's own log joins ours (TPG7)
    };

    // Stack-pinned: the panes' delegates hold pointers into the workspace.
    DesktopTerminal app;
    // The session bus first: the portal's light/dark preference picks the
    // scheme the panes open in (`TPR13`).
    app.desktop.start(lc.effective, lc.warnings);
    auto base = viewOptionsFrom(lc.effective, systemDark: app.desktop.systemDark, lc.warnings);
    app.host.onExit = lc.effective.behaviour.onExit;
    app.host.labels = lc.effective.ui.buttonLabels;
    app.host.overlayStyle = lc.effective.ui.overlayStyle;
    app.host.notificationsConfig = lc.effective.notifications;
    app.host.tabsOpener = lc.effective.ui.tabsOpener;
    app.host.paneChrome = lc.effective.ui.paneChrome;
    app.host.linkTap = lc.effective.links.tap;
    app.host.linkLongPress = lc.effective.links.longPress;
    app.host.linkSchemes = lc.effective.links.schemes.dup;
    app.host.treeHint = "Ctrl+Shift+P  tabs and panes";
    bool shotPending = debugScreenshotAndExit;
    app.host.paneOptions = (in PaneSpec spec, bool shell) {
        // The configuration as it is now: the settings page edits it live.
        string[] reported; // at start, below
        TerminalViewOptions o = viewOptionsFrom(app.config.effective,
            systemDark: app.desktop.systemDark, reported);
        o.shellCommand = shell || !spec.command.length ? null : spec.command.toStringz;
        o.cwd = spec.cwd.length ? spec.cwd.toStringz : null;
        // The scheme the panes are in now, and the pane's notifications to the
        // desktop (`TPR11`), naming it so a click can come back to it.
        o.colors = app.desktop.currentColors;
        const id = spec.id;
        o.hooks.notify = (in Notification n, NotificationRoute route) {
            auto tv = app.host.pool.byId(id);
            app.desktop.notify(id, n, route, tv !is null ? tv.title : null);
        };
        // The debug capture belongs to the first pane only.
        o.debugScreenshotAndExit = shotPending;
        shotPending = false;
        return o;
    };
    // Every key goes through the terminal's table first (`TKM1`).
    app.keys.configure(lc.effective, lc.warnings);
    app.selection.useDesktop(lc.effective, app.keys.table);
    app.config = lc;
    app.followColors();

    // Files opened from a pane open in the app (`TDV1`–`TDV4`): the sessions
    // find this terminal's `xdg-open` first on their PATH, which forwards
    // over the per-app socket. The viewer wears the chrome's colours (`TDV7`).
    import open_request : installOpenShim, removeOpenDir, startOpenServer;
    import settings : OpenTarget;
    import workspace_host : placementFor;

    app.host.openPlacement = placementFor(lc.effective.open.target);
    app.host.creditsPath = bundledCredits();
    app.host.setViewerColors(app.chromeFg, app.chromeBg);
    string openDir;
    if (lc.effective.open.intercept && lc.effective.open.target != OpenTarget.external)
    {
        openDir = installOpenShim();
        if (openDir.length && !startOpenServer(buildPath(openDir, "open.sock")))
            lc.warnings ~= "open: files opened from a pane go to the desktop's handler";
    }
    scope (exit)
        if (openDir.length)
            removeOpenDir(openDir);

    // The last session's tabs and splits (`TSS14`), unless a command was
    // given — then that command is the session.
    app.statePath = buildPath(desktopStateDir(), "sparkles-terminal", "workspace.json");
    bool restoredSession;
    if (!command.length && lc.effective.behaviour.restore && app.statePath.exists)
    {
        auto saved = readJSONFile!SavedWorkspace(app.statePath);
        if (saved.hasError)
            lc.warnings ~= "workspace: " ~ app.statePath ~ " was not restored: "
                ~ saved.error.toString;
        else
            restoredSession = app.host.restore(saved.value);
    }
    if (!restoredSession && !app.host.start(getcwd(), command.join(" ")))
    {
        stderr.writeln("Error: could not start a pane.");
        return 1;
    }
    foreach (w; lc.warnings)
        warning(i"$(w)");
    app.host.reportConfigWarnings(lc.warnings);

    const outcome = runApp(app, cfg);

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
                cfg.gui.font, "'.");
            return 1;
    }
}

/**
The credits document (`TPG15`): beside the executable in an installed build
(`share/sparkles-terminal/credits/`, staged with its licence texts), else the
repository's `docs/credits/` for a build run from the tree — whose licence
includes then show as located errors, the texts being staged only by Nix.
*/
private string bundledCredits()
{
    import std.file : exists, thisExePath;
    import std.path : buildNormalizedPath, dirName;

    const bin = thisExePath.dirName;
    foreach (dir; ["../share/sparkles-terminal/credits", "../../../docs/credits"])
    {
        const doc = buildNormalizedPath(bin, dir, "terminal.md");
        if (doc.exists)
            return doc;
    }
    return null;
}

/// `terminal config show [--changed] [--config PATH]` and `terminal config
/// write [--force] [--config PATH]` (`TCF5`).
private int configCommand(string program, string[] rest)
{
    import std.array : appender;
    import std.file : exists, fileWrite = write, mkdirRecurse;
    import std.path : dirName;
    import std.stdio : stderr, stdout, writeln;

    import settings_io : renderConfigShow, renderStarterConfig;

    string configPath = desktopConfigPath();
    bool changed, force;
    auto args = [program] ~ rest;
    try
        getopt(args, "config", &configPath, "changed", &changed, "force", &force);
    catch (Exception e)
    {
        stderr.writeln("terminal config: ", e.msg);
        return 2;
    }
    const action = args.length >= 2 ? args[1] : "show";
    switch (action)
    {
        case "show":
            auto w = appender!string;
            renderConfigShow(w, loadTerminalConfig(configPath, null), changedOnly: changed);
            stdout.write(w[]);
            return 0;
        case "write":
            if (!configPath.length)
            {
                stderr.writeln("terminal: no config location (no config dir; pass --config)");
                return 1;
            }
            if (configPath.exists && !force)
            {
                stderr.writeln("terminal: ", configPath, " already exists — pass --force to overwrite");
                return 1;
            }
            auto w = appender!string;
            renderStarterConfig(w);
            try
            {
                mkdirRecurse(configPath.dirName);
                fileWrite(configPath, w[]);
            }
            catch (Exception e)
            {
                stderr.writeln("terminal: ", e.msg);
                return 1;
            }
            writeln("wrote ", configPath);
            return 0;
        case "keys":
            import keymap : bindingsMarkdown;

            stdout.write(bindingsMarkdown());
            return 0;
        default:
            stderr.writeln("terminal config: unknown action '", action, "' (show, write, keys)");
            return 2;
    }
}
