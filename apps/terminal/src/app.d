/**
The shell: resolve the configuration, run the terminal component.

Everything the emulator $(I is) lives in `sparkles:terminal-view`
(`TerminalView`, a `runApp` component); everything the window/font/backend
side is lives in `sparkles:ui-app`. The desktop flags are `TerminalCli`
($(MREF cli)); this file loads the build-info section and runs the window.
*/
module app;

import cli : TerminalCli, guiOptionsFrom, parsedLaunch, viewOptionsFrom;
import settings_load : loadTerminalConfig, LoadedConfig;
import desktop_terminal : DesktopTerminal;
import logging : desktopStateDir;
import sparkles.core_cli.args : CommandNode, runCli;
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

int main(string[] args)
{
    version (Android)
    {
        import android_app : androidMain;

        return androidMain();
    }
    else
    {
        // Run as `xdg-open` (the shim on every session's PATH, `TDV4`): hand the
        // file to the terminal that owns the session, or to the next xdg-open.
        import std.path : baseName;

        if (args.length && args[0].baseName == "xdg-open")
        {
            import open_request : xdgOpenShim;

            return xdgOpenShim(args);
        }
        return runCli!TerminalCli(args, (ref CommandNode!TerminalCli node) => prepareDesktop(node));
    }
}

/// The file log and the build line, after `runCli` has installed the logger.
/// `--version` returns before this. `config` does not open the log file.
private int prepareDesktop(ref CommandNode!TerminalCli node)
{
    if (node.commandSelected)
        return 0;

    import std.file : thisExePath;

    import about_page : adoptBuild, processBuild;
    import logging : installTerminalLog;

    installTerminalLog(desktopStateDir());
    adoptBuild(thisExePath);
    const name = processBuild.info.name.length ? processBuild.info.name : "sparkles:terminal";
    logBuildInfo(processBuild.info.version_, processBuild.info.commitLabel, name);
    return 0;
}

/// The window. `cli.TerminalCli.run` calls this; the unittest build excludes
/// this module, so that call stays inside the template.
int launchDesktop(ref CommandNode!TerminalCli node)
{
    import std.array : join;
    import std.file : exists, getcwd;
    import std.path : buildPath;
    import std.stdio : stderr;
    import std.string : toStringz;

    import sparkles.base.logger : warning;

    auto launch = parsedLaunch(node);
    const configPath = launch.configPath;
    const windowCols = launch.windowCols;
    const windowRows = launch.windowRows;
    const debugScreenshotAndExit = launch.debugScreenshot;
    const command = launch.command;

    auto lc = loadTerminalConfig(configPath, null);
    foreach (f; launch.flags)
        lc.applyCli(f.overlay, f.flag);
    if (launch.badExit.length)
        lc.warnings ~= "config: --exit-behavior " ~ launch.badExit ~ " is not one of "
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
