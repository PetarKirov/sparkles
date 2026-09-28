/**
The Android entry (docs/specs/terminal/android.md): a NativeActivity has no
command line, no `$SHELL` and no stderr, so what `main` would parse is decided
here — from the APK's `session.conf` asset and the app's data dir.
*/
module android_app;

version (Android):

import cli : guiOptionsFrom, TerminalCli;
import droid_terminal : DroidTerminal;
import sparkles.terminal_view.component : TerminalViewOptions;
import session;
import sparkles.base.logger : info, LogLevel, warning;
import sparkles.ui_app.host : PointerUnit, RunConfig;
import sparkles.ui_app.run_app : runApp;

/// The logcat tag (`adb logcat -s terminal`).
enum logTag = "terminal";

/// The font the APK bundles (nix/packages/android/terminal.nix) and falls
/// back from: Android's own monospace face.
private enum bundledFont = "FiraCodeNerdFontMono";
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

    const paths = SessionPaths(internalDataPath);
    const fontsDir = buildPath(paths.files, "fonts");
    static immutable owned = ["fonts"];
    if (!extractAssetBundle(paths.files, owned, buildPath(paths.files, "assets-ready")))
        warning(i"terminal: no font bundle — falling back to $(systemFont)");

    const conf = readAssetText("session.conf");
    const config = conf is null ? SessionConfig.init : parseSessionConfig(conf);
    info(i"terminal: session mode $(config.mode)");

    try
        mkdirRecurse(paths.home);
    catch (Exception e)
        warning(i"terminal: cannot create $(paths.home): $(e.msg)");

    // `~/.termux/font.ttf` wins (nix-on-droid's `terminal.font`, `NOD11`),
    // then the bundled face, then the system's.
    const termuxFont = buildPath(paths.termuxDir, "font.ttf");
    const font = termuxFont.exists ? termuxFont
        : buildPath(fontsDir, bundledFont ~ "-Regular.ttf").exists ? bundledFont
        : systemFont;

    RunConfig cfg = {
        title: "Sparkles Terminal",
        gui: guiOptionsFrom(TerminalCli(
            font: font,
            fontDirs: [fontsDir, "/system/fonts"],
        )),
        keyRelease: true, // the terminal-grade keyboard
        touchGestures: true, // taps, drags and pinches — not an emulated mouse
        pointerUnit: PointerUnit.pixels, // the key row is not on the cell grid
    };

    DroidTerminal app;
    app.oracle.dir = paths.debugDir;
    app.termuxDir = paths.termuxDir;
    configureSession(app, config, paths);
    app.loadSettings(); // after the session: the scheme applies to it

    // termux-am's server (NOD13): nix-on-droid's android-integration tools.
    import am_server : startAmServer;

    cast(void) startAmServer(paths.files, paths.home);
    runApp(app, cfg);
    app.tv.close();
    // Static druntime cannot rt_init twice, and Android reuses the process
    // across activity recreations: end the process with the activity.
    exit(0);
}

/// Point the terminal at the session `config` asks for (`NOD4`, `NOD5`,
/// `NOD7`): a plain shell, the login of an installed bootstrap, or — when the
/// bootstrap is not installed yet — the installer, followed by that login.
private void configureSession(ref DroidTerminal app, const SessionConfig config,
    const SessionPaths paths)
{
    import std.file : exists;

    if (config.mode == SessionMode.shell)
    {
        app.tv.opts = sessionOptions(paths, false);
        return;
    }
    if (paths.login.exists)
    {
        app.tv.opts = sessionOptions(paths, true);
        return;
    }

    const master = startInstaller(paths, config.bootstrapUrl);
    if (master < 0)
    {
        warning(i"terminal: cannot start the installer — starting a plain shell");
        app.tv.opts = sessionOptions(paths, false);
        return;
    }
    app.tv.opts = sessionOptions(paths, false);
    app.tv.opts.adoptMaster = master;
    app.next = sessionOptions(paths, true);
    app.hasNext = true;
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

    import installer : runInstaller;
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
            (string url, string dest, scope void delegate(long, long) nothrow progress)
                => download(url, dest, progress),
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
