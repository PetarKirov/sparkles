/**
The Android entry (docs/specs/terminal/android.md): a NativeActivity has no
command line, no `$SHELL` and no stderr, so what `main` would parse is decided
here — from the APK's `session.conf` asset and the app's data dir.
*/
module android_app;

version (Android):

import cli : guiOptionsFrom;
import droid_terminal : DroidTerminal;
import keymap : TermCommand;
import sparkles.terminal_view.component : TerminalViewOptions;
import sparkles.terminal_view.log : routeTraceLog;
import session;
import workspace : PaneSpec;
import settings : defaultFontFamily;
import settings_load : androidConfigPath;
import sparkles.base.logger : info, LogLevel, warning;
import sparkles.ui_app.host : PointerUnit, RunConfig;
import sparkles.ui_app.run_app : runApp;

/// The logcat tag (`adb logcat -s terminal`).
enum logTag = "terminal";

/// Address `dladdr` resolves to this library. The process image is
/// `app_process`, so the build-info section is not on `/proc/self/exe`.
extern(C) void sparkles_terminal_build_anchor() @nogc nothrow {}

private string thisLibraryPath()
{
    import core.sys.posix.dlfcn : Dl_info, dladdr;
    import std.string : fromStringz;

    Dl_info info;
    if (dladdr(&sparkles_terminal_build_anchor, &info) == 0 || info.dli_fname is null)
        return null;
    return fromStringz(info.dli_fname).idup;
}

/// Android's own monospace face: the fallback when the configured font (by
/// default the one the APK bundles, nix/packages/android/terminal.nix) is
/// not there.
private enum systemFont = "DroidSansMono";

int androidMain()
{
    import core.stdc.stdlib : exit;
    import std.file : exists, mkdirRecurse;
    import std.path : buildPath;

    import sparkles.android.activity : internalDataPath;
    import sparkles.android.assets : extractAssetBundle, readAssetText;
    import sparkles.android.log : installLogcatSink;

    installLogcatSink(LogLevel.info, logTag);
    {
        import logging : installTerminalLog;
        import sparkles.terminal_view.core : logBuildInfo;

        import about_page : adoptBuild, processBuild;

        // logcat, then the file (`files/state/sparkles-terminal/`) and the ring.
        // `/proc/self/exe` is `app_process`; the section is in this library.
        installTerminalLog(buildPath(internalDataPath, "state"));
        adoptBuild(thisLibraryPath());
        const name = processBuild.info.name.length ? processBuild.info.name : "sparkles:terminal";
        logBuildInfo(processBuild.info.version_, processBuild.info.commitLabel, name);
    }

    const conf = readAssetText("session.conf");
    const config = conf is null ? SessionConfig.init : parseSessionConfig(conf);
    info(i"terminal: session mode $(config.mode)");

    const paths = SessionPaths(internalDataPath, config.amSocket);
    const fontsDir = buildPath(paths.files, "fonts");
    // The viewer's grammar queries are extracted beside the fonts; their
    // parsers ship as native libraries (`TDV1`, OQ6).
    static immutable owned = ["fonts", "grammars"];
    if (!extractAssetBundle(paths.files, owned, buildPath(paths.files, "assets-ready")))
        warning(i"terminal: no font bundle — the bundled font falls back to $(systemFont)");

    try
        mkdirRecurse(paths.home);
    catch (Exception e)
        warning(i"terminal: cannot create $(paths.home): $(e.msg)");

    DroidTerminal app;
    app.oracle.dir = paths.debugDir;
    app.termuxDir = paths.termuxDir;
    app.configPath = androidConfigPath(paths.home);
    app.platform.debugDir = paths.debugDir;
    app.platform.start(); // the system scheme, before the settings use it
    // A tapped notification's pane (`TPR12`, `TSS15`); one that has closed
    // since opens the notification log instead, its entry the newest, on top.
    app.platform.focusPane = (uint pane) {
        import pages : openPage;

        if (!app.host.ws.focusPane(pane))
            openPage(app.host, TermCommand.openNotifications);
        app.host.invalidate();
    };
    // Several notifications while away: the notification log (`TPG10`, D15);
    // a debug trigger opens any page (on-device tests).
    app.platform.openPage = (TermCommand page) {
        import pages : openPage;

        openPage(app.host, page);
    };
    app.loadSettings(); // the options every pane starts from
    app.host.pollPointer = false; // touch arrives as gestures
    app.statePath = buildPath(paths.files, "state", "workspace.json");

    // The first pane is the session (`NOD4`–`NOD7`): the installer while the
    // bootstrap is missing, then its login; every later pane — a tab, a
    // split, a shell after an exit — the session's shell in its directory.
    TerminalViewOptions first;
    const installing = configureSession(app, config, paths, first);
    const bootstrapped = config.mode != SessionMode.shell;
    bool firstPending = true;
    app.host.paneOptions = (in PaneSpec spec, bool shell) {
        import std.string : toStringz;

        TerminalViewOptions o = firstPending ? first
            : sessionOptions(paths, bootstrapped && paths.login.exists);
        firstPending = false;
        o.colors = app.base.colors;
        o.policy = app.base.policy;
        o.scrollbackLimit = app.base.scrollbackLimit;
        o.hooks.notify = app.platform.notifyHook(spec.id);
        if (spec.cwd.length)
            o.cwd = spec.cwd.toStringz;
        if (!shell && spec.command.length)
        {
            o.program = "/system/bin/sh";
            o.argv = ["-sh".ptr, "-c".ptr, spec.command.toStringz, null];
        }
        return o;
    };

    // Files programs open (`termux-open`, `am start -a VIEW`) become viewer
    // panes (`TDV1`, `TDV2`): grammars from the APK's libraries and the
    // extracted queries, the credits read in place from the assets. Before the
    // restore below: a restored viewer pane (the credits) reads its file
    // through `makeDocEnv`'s asset reader, and without it found nothing.
    {
        import am_server : setOpenInApp;
        import settings : OpenTarget;
        import sparkles.doc_view.pane : DocViewEnv;
        import sparkles.syntax : GrammarRegistry;
        import workspace_host : placementFor;

        const target = app.config.effective.open.target;
        setOpenInApp(target != OpenTarget.external);
        app.host.openPlacement = placementFor(target);
        app.host.setViewerColors(app.chromeFg, app.chromeBg);
        const grammars = buildPath(paths.files, "grammars");
        app.host.creditsPath = "asset:credits/terminal.md";
        app.host.makeDocEnv = () {
            auto env = DocViewEnv.create(GrammarRegistry.fromSonames(grammars),
                (string p) => readViewerFile(p));
            // The credits' includes stay inside the bundled document (`VIW7`).
            env.pipeline.includeRoot = "asset:credits";
            return env;
        };
    }

    // The last session's tabs and splits (`TSS14`) — not while installing,
    // when the one pane is the installer.
    bool restoredSession;
    if (!installing && app.config.effective.behaviour.restore && app.statePath.exists)
    {
        import sparkles.wired.json : readJSONFile;
        import workspace : SavedWorkspace;

        auto saved = readJSONFile!SavedWorkspace(app.statePath);
        if (saved.hasError)
            warning(i"workspace: not restored: $(saved.error.toString)");
        else
            restoredSession = app.host.restore(saved.value);
    }
    if (!restoredSession)
        cast(void) app.host.start(paths.home, null);

    // The configured font (`~/.termux/font.ttf` when nix-on-droid's
    // `terminal.font` wrote one, `NOD11`; else the bundled face), searched in
    // the extracted bundle and the system's fonts; Android's own monospace
    // when the bundle is missing.
    auto gui = guiOptionsFrom(app.config.effective);
    gui.fontDir = [fontsDir, "/system/fonts"] ~ gui.fontDir;
    if (gui.font == defaultFontFamily
        && !buildPath(fontsDir, defaultFontFamily ~ "-Regular.ttf").exists)
        gui.font = systemFont;

    RunConfig cfg = {
        title: "sparkles:terminal",
        gui: gui,
        keyRelease: true, // the terminal-grade keyboard
        touchGestures: true, // taps, drags and pinches — not an emulated mouse
        pointerUnit: PointerUnit.pixels, // the key row is not on the cell grid
        traceSink: &routeTraceLog, // raylib's own log joins ours (TPG7)
    };

    // termux-am's server (NOD13): nix-on-droid's android-integration tools.
    import am_server : startAmServer;

    cast(void) startAmServer(paths.amSocket, paths.home);
    runApp(app, cfg);
    // Static druntime cannot rt_init twice, and Android reuses the process
    // across activity recreations: end the process with the activity.
    exit(0);
}

/// The first pane's options for the session `config` asks for (`NOD4`, `NOD5`,
/// `NOD7`): a plain shell, the login of an installed bootstrap, or — when the
/// bootstrap is not installed yet — the installer, followed by that login
/// (`app.next`). True while installing.
/**
The viewer's reader: `asset:<name>` is read in place from the APK (the credits,
`TPG15`); anything else from the filesystem.
*/
private string readViewerFile(string path) @system
{
    import std.algorithm.searching : startsWith;
    import std.file : readText;

    import sparkles.android.assets : readAssetText;

    if (!path.startsWith("asset:"))
        return readText(path);
    auto text = readAssetText(path["asset:".length .. $]);
    if (text is null)
        throw new Exception("not in the APK");
    return text;
}

private bool configureSession(ref DroidTerminal app, const SessionConfig config,
    const SessionPaths paths, out TerminalViewOptions first)
{
    import std.file : exists;

    if (config.mode == SessionMode.shell)
    {
        first = sessionOptions(paths, false);
        return false;
    }
    if (paths.login.exists)
    {
        first = sessionOptions(paths, true);
        return false;
    }

    const master = startInstaller(paths, config.bootstrapUrl);
    if (master < 0)
    {
        warning(i"terminal: cannot start the installer — starting a plain shell");
        first = sessionOptions(paths, false);
        return false;
    }
    first = sessionOptions(paths, false);
    first.adoptMaster = master;
    app.next = sessionOptions(paths, true);
    app.hasNext = true;
    return true;
}

/// The options for a plain shell (`bootstrapped = false`) or the bootstrap's
/// `login` — program, argv, cwd and the whole environment.
private TerminalViewOptions sessionOptions(const SessionPaths paths, bool bootstrapped)
{
    import std.array : array;
    import std.algorithm.iteration : map;
    import std.file : mkdirRecurse;
    import std.process : environment;
    import std.string : toStringz;

    import sparkles.terminal_view.input : ExitBehavior;

    string[] parentEnv;
    foreach (key, value; environment.toAA)
        parentEnv ~= key ~ "=" ~ value;
    const env = sessionEnvironment(parentEnv, paths, bootstrapped);
    try
        mkdirRecurse(bootstrapped ? paths.tmp : paths.files ~ "/tmp");
    catch (Exception) {}
    if (!bootstrapped)
        installShellTools(paths);

    const(char)*[] envz = env.map!(e => cast(const(char)*) e.toStringz).array;
    envz ~= null;
    const(char)*[] argv = bootstrapped ? ["-login".ptr, null] : ["-sh".ptr, null];

    TerminalViewOptions o;
    o.program = bootstrapped ? paths.login.toStringz : "/system/bin/sh";
    o.argv = argv;
    o.cwd = paths.home.toStringz;
    o.env = envz;
    o.pollMouse = false; // touch arrives as gestures (DroidTerminal)
    // A failed login stays on screen: its message is the only diagnostic.
    o.exitBehavior = ExitBehavior.holdOnFailure;
    return o;
}

/// Write the plain shell's own commands (`shellTools`) into
/// `SessionPaths.shellBin`, executable; a tool already up to date is left
/// alone. A failure costs the command, never the session.
private void installShellTools(const SessionPaths paths)
{
    import std.conv : octal;
    import std.file : exists, mkdirRecurse, readText, setAttributes, write;
    import std.path : buildPath;
    import sparkles.base.logger : warning;

    foreach (tool; shellTools)
    {
        const path = buildPath(paths.shellBin, tool.name);
        try
        {
            mkdirRecurse(paths.shellBin);
            if (!path.exists || readText(path) != tool.script)
                write(path, tool.script);
            setAttributes(path, octal!755);
        }
        catch (Exception e)
            warning(i"terminal: cannot install $(path): $(e.msg)");
    }
}

/**
Open a pty and run the installer on its slave, on a thread of its own; returns
the master for the pane to adopt, or `-1`. The thread closes the slave when the
installer finishes, which is what ends the pane's installer session.
*/
private int startInstaller(const SessionPaths paths, string defaultUrl)
{
    import core.sys.posix.fcntl : O_NOCTTY, O_RDWR, open;
    import core.sys.posix.unistd : close;
    import core.thread : Thread;
    import sparkles.event_horizon.bionic : grantpt, posix_openpt, ptsname, unlockpt;

    import installer : runInstaller, withLocalFiles;
    import sparkles.android.http : download;

    const master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0)
        return -1;
    if (grantpt(master) != 0 || unlockpt(master) != 0)
    {
        close(master);
        return -1;
    }
    const slave = open(ptsname(master), O_RDWR | O_NOCTTY);
    if (slave < 0)
    {
        close(master);
        return -1;
    }

    import session : bootstrapArch;
    import sparkles.android.assets : copyAssetToFile, hasAsset;

    // A bootstrap the APK bundles (mkTerminalApk's `bootstraps`) is the
    // offline default; the prompt still accepts a URL.
    const bundledAsset = "bootstrap/bootstrap-" ~ bootstrapArch() ~ ".zip";
    const haveBundled = hasAsset(bundledAsset);

    auto t = new Thread({
        const installed = runInstaller(slave, paths, defaultUrl,
            withLocalFiles((string url, string dest, scope void delegate(long, long) nothrow progress)
                => download(url, dest, progress)),
            haveBundled
                ? (string dest, scope void delegate(long, long) nothrow progress)
                    => copyAssetToFile(bundledAsset, dest, progress)
                : null);
        info(i"terminal: installer finished, installed=$(installed)");
        close(slave);
    });
    t.isDaemon = true;
    t.start();
    return master;
}
